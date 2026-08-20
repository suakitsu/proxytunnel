param(
    [string]$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')),
    [string]$ListenPrefix = 'http://+:9190/',
    [string]$BackendBase = 'http://127.0.0.1:9191',
    [string]$StaticFile = (Join-Path $ProjectRoot 'cmd\proxytunnel\web\index.html'),
    [string]$LogoFile = (Join-Path $ProjectRoot 'cmd\proxytunnel\web\logo.svg'),
    [string]$LogPath = (Join-Path $ProjectRoot 'var\logs\gateway.log'),
    [string]$AllowedCIDR = '127.0.0.0/8',
    [string]$ProxyUrl = 'http://127.0.0.1:7890',
    [string]$CustomPoolManager = (Join-Path $ProjectRoot 'scripts\windows\custom-pool-manager.ps1'),
    [string]$CustomPoolRoot = (Join-Path $ProjectRoot 'var\custom-pool'),
    [string]$CandidateRotationStateFile = (Join-Path $ProjectRoot 'var\state\candidate-rotation.json'),
    [string]$PoolBuildWorker = (Join-Path $ProjectRoot 'scripts\windows\pool-build-worker.ps1'),
    [string]$PoolBuildStateFile = (Join-Path $ProjectRoot 'var\state\pool-build.json'),
    [string]$PoolProfileFile = (Join-Path $ProjectRoot 'var\state\pool-profiles.json'),
    [string]$PoolSnapshotRoot = (Join-Path $ProjectRoot 'var\snapshots'),
    [string]$PoolBuildSelectionFile = (Join-Path $ProjectRoot 'var\state\pool-build-selection.json'),
    [string]$PoolBuildRotationFile = (Join-Path $ProjectRoot 'var\state\pool-build-rotation.json'),
    [string]$PoolBuildCancelFile = (Join-Path $ProjectRoot 'var\state\pool-build.cancel'),
    [string]$CustomPoolTaskName = 'ProxyTunnel-Custom-Pool',
    [int]$CustomPoolProxyPort = 7891,
    [int]$CustomPoolControllerPort = 19092,
    [int]$MaxConcurrentRequests = 12,
    [System.Net.HttpListenerContext]$RequestContext = $null,
    [switch]$RequestWorker,
    [hashtable]$SharedState = $null
)

$ErrorActionPreference = 'Stop'
$script:GatewayVersion = '0.1.0-alpha.1'
$script:PowerShellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ($null -eq $SharedState) {
    $SharedState = [hashtable]::Synchronized(@{
        previousDownload = $null
        previousUpload = $null
        previousRateAt = $null
        egress = [pscustomobject]@{
            reachable = $false
            country_code = ''
            country_name = ''
            colo = ''
            latency_ms = 0
            checked_at = $null
        }
        nextEgressSampleAt = [datetime]::MinValue
        egressSampleInProgress = $false
        catalogRequestCache = [hashtable]::Synchronized(@{})
        catalogOperationGate = [System.Threading.SemaphoreSlim]::new(2, 2)
        poolBuildGate = [System.Threading.SemaphoreSlim]::new(1, 1)
    })
}

function Write-GatewayLog {
    param([string]$Message)
    $parent = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

function Test-LanAddress {
    param([System.Net.IPAddress]$Address)
    if ([System.Net.IPAddress]::IsLoopback($Address)) {
        return $true
    }
    if ($Address.IsIPv4MappedToIPv6) {
        $Address = $Address.MapToIPv4()
    }
    $parts = $AllowedCIDR.Split('/', 2)
    if ($parts.Count -ne 2) { return $false }
    $network = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$network)) { return $false }
    if ($network.IsIPv4MappedToIPv6) { $network = $network.MapToIPv4() }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
    $addressBytes = $Address.GetAddressBytes()
    $networkBytes = $network.GetAddressBytes()
    if ($addressBytes.Length -ne 4 -or $networkBytes.Length -ne 4) { return $false }
    $wholeBytes = [Math]::Floor($prefix / 8)
    $remainingBits = $prefix % 8
    for ($index = 0; $index -lt $wholeBytes; $index++) {
        if ($addressBytes[$index] -ne $networkBytes[$index]) { return $false }
    }
    if ($remainingBits -gt 0) {
        $mask = [byte](256 - [Math]::Pow(2, 8 - $remainingBits))
        if (($addressBytes[$wholeBytes] -band $mask) -ne ($networkBytes[$wholeBytes] -band $mask)) { return $false }
    }
    return $true
}

function Send-Bytes {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Bytes
    )
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Referrer-Policy'] = 'same-origin'
    $response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:"
    $response.ContentLength64 = $Bytes.Length
    if ($Bytes.Length -gt 0) {
        $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
    $response.OutputStream.Close()
}

function Send-Text {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Text
    )
    Send-Bytes -Context $Context -StatusCode $StatusCode -ContentType $ContentType -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Send-Json {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [object]$Value
    )
    Send-Text -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Text ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Start-NDJsonResponse {
    param([System.Net.HttpListenerContext]$Context)
    $response = $Context.Response
    $response.StatusCode = 200
    $response.ContentType = 'application/x-ndjson; charset=utf-8'
    $response.SendChunked = $true
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Referrer-Policy'] = 'same-origin'
}

function Send-NDJsonLine {
    param(
        [System.Net.HttpListenerContext]$Context,
        [object]$Value
    )
    $line = ($Value | ConvertTo-Json -Depth 20 -Compress) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Flush()
}

function Get-RequestBody {
    param([System.Net.HttpListenerRequest]$Request)
    if (-not $Request.HasEntityBody) {
        return ''
    }
    # RFC 8259 JSON is UTF-8. HttpListener otherwise falls back to the Windows
    # ANSI code page when fetch() sends application/json without a charset,
    # which corrupts Chinese text and can even turn a multibyte byte into '"'.
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $utf8, $true, 4096)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Get-CountryName {
    param([string]$Code)
    $names = @{
        US = '美国'; CA = '加拿大'; GB = '英国'; DE = '德国'; FR = '法国'; NL = '荷兰'
        JP = '日本'; SG = '新加坡'; HK = '中国香港'; TW = '中国台湾'; KR = '韩国'
        AU = '澳大利亚'; IN = '印度'; CH = '瑞士'; FI = '芬兰'; SE = '瑞典'; PL = '波兰'
        BR = '巴西'; RU = '俄罗斯'; ES = '西班牙'; IT = '意大利'; IE = '爱尔兰'
    }
    $normalized = [string]$Code
    $normalized = $normalized.Trim().ToUpperInvariant()
    if ($names.ContainsKey($normalized)) {
        return $names[$normalized]
    }
    if ($normalized) {
        return $normalized
    }
    return '未知'
}

function Update-EgressSample {
    $shouldSample = $false
    [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
    try {
        if (-not [bool]$SharedState.egressSampleInProgress -and (Get-Date) -ge [datetime]$SharedState.nextEgressSampleAt) {
            $SharedState.egressSampleInProgress = $true
            $SharedState.nextEgressSampleAt = (Get-Date).AddMinutes(5)
            $shouldSample = $true
        }
    } finally {
        [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
    }
    if (-not $shouldSample) { return }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $output = & $curl --proxy $ProxyUrl --ssl-no-revoke --connect-timeout 8 --max-time 12 --silent --show-error 'https://www.cloudflare.com/cdn-cgi/trace' 2>$null
        $exitCode = $LASTEXITCODE
        $stopwatch.Stop()
        if ($exitCode -ne 0) {
            throw "curl exit code $exitCode"
        }
        $values = @{}
        foreach ($line in $output) {
            $separator = $line.IndexOf('=')
            if ($separator -gt 0) {
                $key = $line.Substring(0, $separator)
                if ($key -in @('loc', 'colo')) {
                    $values[$key] = $line.Substring($separator + 1)
                }
            }
        }
        if (-not $values['loc']) {
            throw 'Cloudflare trace did not return a country code'
        }
        $sample = [pscustomobject]@{
            reachable = $true
            country_code = $values['loc'].ToUpperInvariant()
            country_name = Get-CountryName $values['loc']
            colo = [string]$values['colo']
            latency_ms = [int][math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            checked_at = (Get-Date).ToString('o')
        }
    } catch {
        $stopwatch.Stop()
        $sample = [pscustomobject]@{
            reachable = $false
            country_code = ''
            country_name = ''
            colo = ''
            latency_ms = [int][math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            checked_at = (Get-Date).ToString('o')
        }
        Write-GatewayLog ("egress sample failed: " + $_.Exception.Message)
    } finally {
        [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
        try {
            $SharedState.egress = $sample
            $SharedState.egressSampleInProgress = $false
        } finally {
            [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
        }
    }
}

function Add-StatusEnhancements {
    param([object]$Status)
    $now = Get-Date
    $download = [double]$Status.download_total
    $upload = [double]$Status.upload_total
    $downloadBps = 0.0
    $uploadBps = 0.0
    [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
    try {
        if ($null -ne $SharedState.previousRateAt) {
            $seconds = ($now - [datetime]$SharedState.previousRateAt).TotalSeconds
            if ($seconds -gt 0) {
                $downloadBps = [math]::Max(0, ($download - [double]$SharedState.previousDownload) / $seconds)
                $uploadBps = [math]::Max(0, ($upload - [double]$SharedState.previousUpload) / $seconds)
            }
        }
        $SharedState.previousDownload = $download
        $SharedState.previousUpload = $upload
        $SharedState.previousRateAt = $now
    } finally {
        [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
    }

    Update-EgressSample

    $Status | Add-Member -NotePropertyName platform_version -NotePropertyValue $script:GatewayVersion -Force
    $Status | Add-Member -NotePropertyName download_bps -NotePropertyValue $downloadBps -Force
    $Status | Add-Member -NotePropertyName upload_bps -NotePropertyValue $uploadBps -Force
    $Status | Add-Member -NotePropertyName egress -NotePropertyValue $SharedState.egress -Force
    return $Status
}

function Invoke-BackendJson {
    param(
        [string]$PathAndQuery,
        [int]$TimeoutSec = 15
    )
    return Invoke-RestMethod -UseBasicParsing -Uri ($BackendBase.TrimEnd('/') + $PathAndQuery) -TimeoutSec $TimeoutSec
}

function Invoke-BackendRaw {
    param(
        [string]$PathAndQuery,
        [string]$Method,
        [string]$Body,
        [string]$ConfirmedHeader,
        [int]$TimeoutMS = 50000
    )
    $url = $BackendBase.TrimEnd('/') + $PathAndQuery
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = $Method
    $request.Timeout = $TimeoutMS
    $request.ReadWriteTimeout = $TimeoutMS
    $request.AllowAutoRedirect = $false
    $request.Accept = 'application/json'
    if ($ConfirmedHeader) {
        $request.Headers['X-ProxyTunnel-Action'] = $ConfirmedHeader
    }
    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    }
    $response = $null
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -eq $response) {
            throw
        }
    }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try {
            $responseBody = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            ContentType = if ($response.ContentType) { $response.ContentType } else { 'application/json; charset=utf-8' }
            Body = $responseBody
        }
    } finally {
        $response.Dispose()
    }
}

function Get-CandidateSelectionLimit {
    param([string]$Source)
    switch ($Source.ToLowerInvariant()) {
        'proxyip' { return 8 }
        'socks5' { return 1 }
        'http' { return 1 }
        'https' { return 1 }
        default { return 0 }
    }
}

function Get-CandidateSelectionCounts {
    $catalog = Invoke-BackendJson -PathAndQuery '/api/catalog?source=all&page=1&page_size=10' -TimeoutSec 70
    $counts = @{ proxyip = 0; socks5 = 0; http = 0; https = 0 }
    foreach ($entry in @($catalog.selection.items)) {
        $source = ([string]$entry.node.source).ToLowerInvariant()
        if ($counts.ContainsKey($source)) {
            $counts[$source] = [int]$counts[$source] + 1
        }
    }
    return $counts
}

function Read-CandidateRotationState {
    if (-not (Test-Path -LiteralPath $CandidateRotationStateFile)) {
        return [pscustomobject]@{ updated_at = $null; cursors = @() }
    }
    try {
        $document = Get-Content -LiteralPath $CandidateRotationStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $document.cursors) {
            $document | Add-Member -NotePropertyName cursors -NotePropertyValue @() -Force
        }
        return $document
    } catch {
        Write-GatewayLog ('candidate rotation state was reset: ' + $_.Exception.Message)
        return [pscustomobject]@{ updated_at = $null; cursors = @() }
    }
}

function Write-CandidateRotationState {
    param([object]$Document)
    $parent = Split-Path -Parent $CandidateRotationStateFile
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Document.updated_at = (Get-Date).ToString('o')
    $temporary = $CandidateRotationStateFile + '.next-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.File]::WriteAllText($temporary, ($Document | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $CandidateRotationStateFile -Force
}

function Get-RotatingCatalogCandidates {
    param(
        [string]$Source,
        [string]$Country,
        [int]$MaximumAttempts,
        [hashtable]$SelectedIDs
    )
    $pageSize = 100
    $encodedSource = [uri]::EscapeDataString($Source)
    $encodedCountry = [uri]::EscapeDataString($Country)
    $pages = @{}
    $first = Invoke-BackendJson -PathAndQuery "/api/catalog?source=$encodedSource&country=$encodedCountry&page=1&page_size=$pageSize" -TimeoutSec 70
    $pages[1] = $first
    $total = [int]$first.total
    if ($total -lt 1) {
        return [pscustomobject]@{ candidates = @(); total = 0; start = 0; next = 0; scanned = 0; cycle = 0 }
    }

    $key = $Source.ToLowerInvariant() + '|' + $Country.ToUpperInvariant()
    $document = Read-CandidateRotationState
    $cursorEntry = @($document.cursors | Where-Object { $_.key -eq $key } | Select-Object -First 1)
    if ($cursorEntry.Count -gt 0) {
        $start = [int]$cursorEntry[0].cursor
        $cycle = [int]$cursorEntry[0].cycle
    } else {
        $start = Get-Random -Minimum 0 -Maximum $total
        $cycle = 0
    }
    if ($start -lt 0 -or $start -ge $total) { $start = 0 }

    $candidates = @()
    $scanned = 0
    while ($candidates.Count -lt $MaximumAttempts -and $scanned -lt $total) {
        $absolute = ($start + $scanned) % $total
        $page = [int][Math]::Floor($absolute / $pageSize) + 1
        $index = $absolute % $pageSize
        if (-not $pages.ContainsKey($page)) {
            $pages[$page] = Invoke-BackendJson -PathAndQuery "/api/catalog?source=$encodedSource&country=$encodedCountry&page=$page&page_size=$pageSize" -TimeoutSec 70
        }
        $items = @($pages[$page].items)
        if ($index -lt $items.Count) {
            $candidate = $items[$index]
            if ($candidate -and -not $SelectedIDs.ContainsKey([string]$candidate.id)) {
                $candidates += $candidate
            }
        }
        $scanned++
    }

    $next = ($start + $scanned) % $total
    if ($start + $scanned -ge $total) { $cycle++ }
    $newEntry = [pscustomobject]@{
        key = $key; source = $Source.ToLowerInvariant(); country = $Country.ToUpperInvariant()
        cursor = $next; cycle = $cycle; total = $total; last_started_at = (Get-Date).ToString('o')
        last_window_start = $start; last_window_size = $scanned
    }
    $remaining = @($document.cursors | Where-Object { $_.key -ne $key })
    $document.cursors = @($remaining + $newEntry)
    Write-CandidateRotationState -Document $document

    return [pscustomobject]@{
        candidates = $candidates; total = $total; start = $start; next = $next
        scanned = $scanned; cycle = $cycle
    }
}

function Invoke-CandidateVerificationGroup {
    param([object[]]$Candidates)
    $jobs = @()
    foreach ($candidate in $Candidates) {
        $jobs += Start-Job -ScriptBlock {
            param($BaseUrl, $Source, $CandidateID)
            $requestBody = @{ action = 'verify'; source = $Source; id = $CandidateID } | ConvertTo-Json -Compress
            try {
                $response = Invoke-RestMethod `
                    -UseBasicParsing `
                    -Method Post `
                    -Uri ($BaseUrl.TrimEnd('/') + '/api/catalog/action') `
                    -Headers @{ 'X-ProxyTunnel-Action' = 'confirmed' } `
                    -ContentType 'application/json' `
                    -Body $requestBody `
                    -TimeoutSec 65
                [pscustomobject]@{
                    source = $Source
                    id = $CandidateID
                    success = [bool]$response.success
                    verification = $response.verification
                    message = [string]$response.message
                }
            } catch {
                [pscustomobject]@{
                    source = $Source
                    id = $CandidateID
                    success = $false
                    verification = $null
                    message = $_.Exception.Message
                }
            }
        } -ArgumentList $BackendBase, ([string]$candidate.source).ToLowerInvariant(), ([string]$candidate.id)
    }
    if ($jobs.Count -eq 0) {
        return @()
    }
    $null = Wait-Job -Job $jobs -Timeout 70
    foreach ($job in $jobs) {
        if ($job.State -notin @('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
    }
    $results = @($jobs | Receive-Job -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            source = [string]$_.source
            id = [string]$_.id
            success = [bool]$_.success
            verification = $_.verification
            message = [string]$_.message
        }
    })
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    return $results
}

function Select-VerifiedCandidate {
    param(
        [string]$Source,
        [string]$CandidateID
    )
    $body = @{ action = 'select'; source = $Source; id = $CandidateID; selected = $true } | ConvertTo-Json -Compress
    return Invoke-RestMethod `
        -UseBasicParsing `
        -Method Post `
        -Uri ($BackendBase.TrimEnd('/') + '/api/catalog/action') `
        -Headers @{ 'X-ProxyTunnel-Action' = 'confirmed' } `
        -ContentType 'application/json' `
        -Body $body `
        -TimeoutSec 25
}

function Assert-CandidateReference {
    param([object]$Candidate)
    $source = ([string]$Candidate.source).ToLowerInvariant()
    $id = [string]$Candidate.id
    if ((Get-CandidateSelectionLimit $source) -lt 1 -or $id -notmatch '^[a-z0-9-]{10,80}$') {
        throw [System.ArgumentException]::new('批量请求中包含无效候选节点')
    }
    return [pscustomobject]@{ source = $source; id = $id }
}

function Get-CatalogRequestKey {
    param([object]$Payload)
    $action = [string]$Payload.action
    if ($action -eq 'auto_select') {
        return 'auto|' + ([string]$Payload.source).ToLowerInvariant() + '|' + ([string]$Payload.country).ToUpperInvariant() + '|' + [string]([int]$Payload.count)
    }
    if ($action -eq 'verify_batch') {
        $references = @($Payload.candidates | ForEach-Object {
            (([string]$_.source).ToLowerInvariant() + ':' + ([string]$_.id))
        } | Sort-Object -Unique)
        return 'batch|' + [string]([bool]$Payload.select_verified) + '|' + ($references -join ',')
    }
    return ''
}

function Get-CachedCatalogResult {
    param([string]$Key)
    $cutoff = (Get-Date).AddMinutes(-2)
    $cache = [hashtable]$SharedState.catalogRequestCache
    [System.Threading.Monitor]::Enter($cache.SyncRoot)
    try {
        foreach ($existingKey in @($cache.Keys)) {
            if ($cache[$existingKey].created_at -lt $cutoff) {
                $cache.Remove($existingKey)
            }
        }
        if ($Key -and $cache.ContainsKey($Key)) {
            return $cache[$Key].result
        }
    } finally {
        [System.Threading.Monitor]::Exit($cache.SyncRoot)
    }
    return $null
}

function Set-CachedCatalogResult {
    param([string]$Key, [object]$Result)
    if ($Key) {
        $cache = [hashtable]$SharedState.catalogRequestCache
        [System.Threading.Monitor]::Enter($cache.SyncRoot)
        try {
            $cache[$Key] = [pscustomobject]@{ created_at = Get-Date; result = $Result }
        } finally {
            [System.Threading.Monitor]::Exit($cache.SyncRoot)
        }
    }
}

function Publish-CatalogProgress {
    param([scriptblock]$Callback, [object]$Progress)
    if (-not $Callback) { return }
    try {
        & $Callback $Progress
    } catch {
        # A disconnected browser must not abort the server-side validation task.
    }
}

function Invoke-CatalogBatchAction {
    param([object]$Payload, [scriptblock]$ProgressCallback = $null)
    $operationGate = [System.Threading.SemaphoreSlim]$SharedState.catalogOperationGate
    if (-not $operationGate.Wait(0)) { throw [System.InvalidOperationException]::new('已有多个节点验证任务在运行，请稍后再试') }
    try {
    $action = [string]$Payload.action
    if ($action -eq 'verify_batch') {
        $candidateInput = @($Payload.candidates)
        if ($candidateInput.Count -lt 1 -or $candidateInput.Count -gt 20) {
            throw [System.ArgumentException]::new('批量验证每次必须选择 1–20 个候选节点')
        }
        $seen = @{}
        $candidates = @()
        foreach ($candidate in $candidateInput) {
            $normalized = Assert-CandidateReference $candidate
            $key = $normalized.source + ':' + $normalized.id
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $candidates += $normalized
            }
        }
        $selectionCounts = Get-CandidateSelectionCounts
        $results = @()
        Publish-CatalogProgress -Callback $ProgressCallback -Progress ([pscustomobject]@{
            phase = 'verifying'; attempted = 0; total = $candidates.Count; verified = 0; failed = 0
            country_matched = 0; selected = 0; requested = if ([bool]$Payload.select_verified) { $candidates.Count } else { 0 }
        })
        for ($offset = 0; $offset -lt $candidates.Count; $offset += 4) {
            $last = [math]::Min($offset + 3, $candidates.Count - 1)
            $results += @(Invoke-CandidateVerificationGroup -Candidates @($candidates[$offset..$last]))
            $progressVerified = @($results | Where-Object { $_.success }).Count
            $progressMatched = @($results | Where-Object { $_.success -and $_.verification -and $_.verification.country_matched }).Count
            Publish-CatalogProgress -Callback $ProgressCallback -Progress ([pscustomobject]@{
                phase = 'verifying'; attempted = $results.Count; total = $candidates.Count; verified = $progressVerified
                failed = $results.Count - $progressVerified; country_matched = $progressMatched; selected = 0
                requested = if ([bool]$Payload.select_verified) { $candidates.Count } else { 0 }
            })
        }
        $verified = @($results | Where-Object { $_.success }).Count
        $failed = $candidates.Count - $verified
        $countryMatched = @($results | Where-Object { $_.success -and $_.verification -and $_.verification.country_matched }).Count
        $selected = 0
        $capacitySkipped = 0
        if ([bool]$Payload.select_verified) {
            foreach ($result in $results) {
                if (-not $result.success -or -not $result.verification -or -not $result.verification.country_matched) {
                    continue
                }
                $source = ([string]$result.source).ToLowerInvariant()
                $limit = Get-CandidateSelectionLimit $source
                if ([int]$selectionCounts[$source] -ge $limit) {
                    $capacitySkipped++
                    continue
                }
                try {
                    $null = Select-VerifiedCandidate -Source $source -CandidateID ([string]$result.id)
                    $selectionCounts[$source] = [int]$selectionCounts[$source] + 1
                    $selected++
                } catch {
                    $capacitySkipped++
                }
            }
        }
        $message = "批量验证完成：$verified 个成功，$failed 个失败"
        if ([bool]$Payload.select_verified) {
            $message += "，$selected 个加入自选"
            if ($capacitySkipped -gt 0) {
                $message += "，$capacitySkipped 个因来源上限或状态变化未加入"
            }
        }
        Write-GatewayLog $message
        return [pscustomobject]@{
            success = $verified -gt 0
            message = $message
            attempted = $candidates.Count
            verified = $verified
            failed = $failed
            country_matched = $countryMatched
            selected = $selected
            capacity_skipped = $capacitySkipped
            results = $results
        }
    }
    if ($action -eq 'auto_select') {
        $source = ([string]$Payload.source).ToLowerInvariant()
        $country = ([string]$Payload.country).ToUpperInvariant()
        $count = [int]$Payload.count
        $limit = Get-CandidateSelectionLimit $source
        if ($limit -lt 1 -or $country -notmatch '^[A-Z]{2}$' -or $count -lt 1 -or $count -gt $limit) {
            throw [System.ArgumentException]::new("$($source.ToUpperInvariant()) 每次可自动加入 1–$limit 个节点")
        }
        $selectionCounts = Get-CandidateSelectionCounts
        $capacity = $limit - [int]$selectionCounts[$source]
        if ($count -gt $capacity) {
            throw [System.InvalidOperationException]::new("$($source.ToUpperInvariant()) 自选还可加入 $capacity 个，请先移出不需要的节点")
        }
        $catalog = Invoke-BackendJson -PathAndQuery '/api/catalog?source=all&page=1&page_size=10' -TimeoutSec 70
        $selectedIDs = @{}
        foreach ($entry in @($catalog.selection.items)) {
            if ($entry.selected -and $entry.node.id) {
                $selectedIDs[[string]$entry.node.id] = $true
            }
        }
        $maximumAttempts = if ($source -eq 'proxyip') { 40 } else { 20 }
        $rotation = Get-RotatingCatalogCandidates -Source $source -Country $country -MaximumAttempts $maximumAttempts -SelectedIDs $selectedIDs
        $candidates = @($rotation.candidates)
        if ($candidates.Count -eq 0) {
            throw [System.ArgumentException]::new('该来源没有符合国家条件且尚未自选的候选节点')
        }
        $results = @()
        $matched = 0
        $selected = 0
        Publish-CatalogProgress -Callback $ProgressCallback -Progress ([pscustomobject]@{
            phase = 'verifying'; attempted = 0; total = $candidates.Count; verified = 0; failed = 0
            country_matched = 0; selected = 0; requested = $count; candidate_total = [int]$rotation.total
            window_start = [int]$rotation.start; next_cursor = [int]$rotation.next; rotation_cycle = [int]$rotation.cycle
        })
        for ($offset = 0; $offset -lt $candidates.Count -and $selected -lt $count; $offset += 4) {
            $last = [math]::Min($offset + 3, $candidates.Count - 1)
            $group = @($candidates[$offset..$last] | ForEach-Object { [pscustomobject]@{ source = $source; id = [string]$_.id } })
            $groupResults = @(Invoke-CandidateVerificationGroup -Candidates $group)
            $results += $groupResults
            foreach ($result in $groupResults) {
                if ($selected -ge $count) { break }
                if ($result.success -and $result.verification -and ([string]$result.verification.country_code).ToUpperInvariant() -eq $country) {
                    $matched++
                    try {
                        $null = Select-VerifiedCandidate -Source $source -CandidateID ([string]$result.id)
                        $selected++
                    } catch {
                        Write-GatewayLog ("candidate auto-select failed: " + $_.Exception.Message)
                    }
                }
            }
            $progressVerified = @($results | Where-Object { $_.success }).Count
            Publish-CatalogProgress -Callback $ProgressCallback -Progress ([pscustomobject]@{
                phase = 'verifying'; attempted = $results.Count; total = $candidates.Count; verified = $progressVerified
                failed = $results.Count - $progressVerified; country_matched = $matched; selected = $selected; requested = $count
                candidate_total = [int]$rotation.total; window_start = [int]$rotation.start
                next_cursor = [int]$rotation.next; rotation_cycle = [int]$rotation.cycle
            })
        }
        $verified = @($results | Where-Object { $_.success }).Count
        $displayStart = [int]$rotation.start + 1
        $displayNext = [int]$rotation.next + 1
        $message = "自动自选完成：从候选池第 $displayStart 个开始，尝试 $($results.Count) 个，$matched 个可用且国家一致，加入 $selected/$count 个；下次从第 $displayNext 个继续"
        Write-GatewayLog $message
        return [pscustomobject]@{
            success = $selected -gt 0
            complete = $selected -eq $count
            message = $message
            attempted = $results.Count
            verified = $verified
            country_matched = $matched
            selected = $selected
            requested = $count
            candidate_total = [int]$rotation.total
            window_start = [int]$rotation.start
            next_cursor = [int]$rotation.next
            rotation_cycle = [int]$rotation.cycle
        }
    }
    throw [System.ArgumentException]::new('不支持的批量候选操作')
    } finally {
        $null = $operationGate.Release()
    }
}

function Invoke-CustomPoolManager {
    param(
        [ValidateSet('Status', 'Sync', 'Restart', 'Stop', 'Activate')][string]$Action,
        [string]$SnapshotPath = ''
    )
    if (-not (Test-Path -LiteralPath $CustomPoolManager)) {
        throw '自选代理池管理脚本尚未安装'
    }
    $arguments = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$CustomPoolManager,
        '-Action',$Action,'-BackendBase',$BackendBase,'-Root',$CustomPoolRoot,'-TaskName',$CustomPoolTaskName,
        '-ProxyPort',[string]$CustomPoolProxyPort,'-ControllerPort',[string]$CustomPoolControllerPort
    )
    if ($SnapshotPath) { $arguments += @('-SnapshotPath', $SnapshotPath) }
    $output = & $script:PowerShellExecutable @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if ($jsonLine.Count -lt 1) {
        throw '自选代理池管理脚本没有返回状态'
    }
    try {
        $result = $jsonLine[0] | ConvertFrom-Json
    } catch {
        throw '自选代理池返回了无效状态'
    }
    if ($exitCode -ne 0 -or -not $result.success) {
        throw ([string]$result.message)
    }
    return $result
}

function Get-CustomPoolStatusDirect {
    $stateFile = Join-Path $CustomPoolRoot 'state.json'
    $configFile = Join-Path $CustomPoolRoot 'config.yaml'
    $secretFile = Join-Path $CustomPoolRoot 'controller.secret'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        try { $state = [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $state = $null }
    }
    if (-not $state) {
        $state = [pscustomobject]@{
            updated_at = $null; proxy_port = 7891; controller_port = 19092
            pool_name = '默认自选池'; source_filter = ''; country_filter = ''; target_routes = 0
            outputs = @('port','clash','v2rayn'); complete = $false
            member_count = 0; route_count = 0; members = @(); routes = @(); quality = $null; egress = $null
        }
    }

    $controllerPort = if ([int]$state.controller_port -gt 0) { [int]$state.controller_port } else { 19092 }
    $controllerReachable = $false
    $proxyMap = $null
    if ((Test-Path -LiteralPath $secretFile) -and [int]$state.member_count -gt 0) {
        try {
            $secret = (Get-Content -LiteralPath $secretFile -Raw).Trim()
            $proxyMap = Invoke-RestMethod -UseBasicParsing -Uri ("http://127.0.0.1:$controllerPort/proxies") -Headers @{ Authorization = 'Bearer ' + $secret } -TimeoutSec 2
            $controllerReachable = $true
        } catch {
            $controllerReachable = $false
        }
    }

    $routeStatuses = @()
    $alive = 0
    foreach ($route in @($state.routes)) {
        $qualityDelay = if ($null -ne $route.quality_delay_ms) { [int]$route.quality_delay_ms } else { 0 }
        $delay = $qualityDelay
        $runtimeAlive = $controllerReachable -and $qualityDelay -gt 0
        if ($proxyMap -and $proxyMap.proxies) {
            $property = $proxyMap.proxies.PSObject.Properties[[string]$route.name]
            if ($property) {
                $history = @($property.Value.history)
                $recent = @($history | Select-Object -Last 3 | Where-Object { [int]$_.delay -gt 0 } | Select-Object -Last 1)
                if ($recent.Count -gt 0) {
                    $delay = [int]$recent[0].delay
                    $runtimeAlive = $true
                } elseif ($history.Count -gt 0) {
                    $runtimeAlive = $false
                }
            }
        }
        if ($runtimeAlive) { $alive++ }
        $routeStatuses += [pscustomobject]@{
            name = [string]$route.name; source = [string]$route.source; candidate_id = [string]$route.candidate_id
            country_code = [string]$route.country_code; country_name = [string]$route.country_name
            candidate_address = [string]$route.candidate_address; candidate_latency_ms = [int]$route.candidate_latency_ms
            alive = $runtimeAlive; delay_ms = $delay; quality_delay_ms = $qualityDelay
        }
    }

    $countries = @($state.members | Group-Object country_code | ForEach-Object {
        $code = $_.Name
        $first = $_.Group | Select-Object -First 1
        [pscustomobject]@{
            code = $code; name = [string]$first.country_name; members = $_.Count
            routes = @($routeStatuses | Where-Object { $_.country_code -eq $code }).Count
        }
    })
    $total = $routeStatuses.Count
    $egress = if ($state.egress) { $state.egress } else { [pscustomobject]@{ reachable = $false; ip = ''; country_code = ''; country_name = ''; colo = ''; latency_ms = 0; checked_at = $null } }
    $outputs = @($state.outputs | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($outputs.Count -eq 0 -and [int]$state.member_count -gt 0) { $outputs = @('port','clash','v2rayn') }
    $portEnabled = $outputs -contains 'port'
    $taskState = if ($controllerReachable -and $portEnabled) { 'Running' } elseif ([int]$state.member_count -gt 0 -and -not $portEnabled) { 'ExportOnly' } elseif ([int]$state.member_count -gt 0) { 'Unavailable' } elseif (Test-Path -LiteralPath $configFile) { 'Ready' } else { 'NotInstalled' }
    return [pscustomobject]@{
        configured = Test-Path -LiteralPath $configFile; running = ($controllerReachable -and $portEnabled); task_state = $taskState
        proxy_port = if ([int]$state.proxy_port -gt 0) { [int]$state.proxy_port } else { 7891 }; controller_port = $controllerPort
        updated_at = $state.updated_at; build_id = [string]$state.build_id; member_count = [int]$state.member_count; route_count = $total; node_count = $total
        alive = $alive; dead = $total - $alive; availability = if ($total -gt 0) { [Math]::Round(($alive * 100.0) / $total, 1) } else { 0.0 }
        pool_name = if ($state.pool_name) { [string]$state.pool_name } else { '默认自选池' }
        source_filter = [string]$state.source_filter; country_filter = [string]$state.country_filter
        target_routes = if ($null -ne $state.target_routes) { [int]$state.target_routes } else { $total }
        outputs = $outputs; complete = [bool]$state.complete
        members = @($state.members); routes = $routeStatuses; countries = $countries; egress = $egress; quality = $state.quality
        exports = [pscustomobject]@{
            clash = if ($outputs -contains 'clash') { '/subscriptions/custom/clash' } else { $null }
            v2rayn = if ($outputs -contains 'v2rayn') { '/subscriptions/custom/v2rayn' } else { $null }
        }
    }
}

function Add-CustomPoolSyncResult {
    param([object]$Result)
    try {
        $customResult = Invoke-CustomPoolManager -Action Sync
        $Result | Add-Member -NotePropertyName custom_pool -NotePropertyValue $customResult.data -Force
        if ($customResult.message) {
            $Result.message = ([string]$Result.message).TrimEnd('。') + '；' + [string]$customResult.message
        }
    } catch {
        $customFailure = [pscustomobject]@{ success = $false; message = $_.Exception.Message }
        $Result | Add-Member -NotePropertyName custom_pool -NotePropertyValue $customFailure -Force
        $Result.message = ([string]$Result.message).TrimEnd('。') + '；自选清单已保存，但 7891 同步失败：' + $_.Exception.Message
        Write-GatewayLog ('custom pool sync after catalog action failed: ' + $_.Exception.Message)
    }
    return $Result
}

function Test-SameOrigin {
    param([System.Net.HttpListenerRequest]$Request)
    $origin = $Request.Headers['Origin']
    if (-not $origin) {
        return $true
    }
    try {
        $originUri = [uri]$origin
        return $originUri.Scheme -eq $Request.Url.Scheme -and $originUri.Host -eq $Request.Url.Host -and $originUri.Port -eq $Request.Url.Port
    } catch {
        return $false
    }
}

function Write-PoolBuildJsonAtomic {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.gateway.next-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-PoolProfileStore {
    return [pscustomobject]@{
        version = 1
        updated_at = ''
        profiles = @()
    }
}

function Get-PoolProfileStore {
    if (-not (Test-Path -LiteralPath $PoolProfileFile -PathType Leaf)) {
        return New-PoolProfileStore
    }
    try {
        $store = Get-Content -LiteralPath $PoolProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $store.PSObject.Properties['profiles']) {
            $store | Add-Member -NotePropertyName profiles -NotePropertyValue @()
        }
        $store.profiles = @($store.profiles)
        return $store
    } catch {
        Write-GatewayLog ('pool profile store read failed; using an empty store: ' + $_.Exception.Message)
        return New-PoolProfileStore
    }
}

function Save-PoolProfileStore {
    param([object]$Store)
    $Store.updated_at = (Get-Date).ToString('o')
    $Store.profiles = @($Store.profiles | Sort-Object -Property last_used_at -Descending | Select-Object -First 100)
    Write-PoolBuildJsonAtomic -Path $PoolProfileFile -Value $Store
}

function ConvertTo-PoolProfileJobResult {
    param([object]$Job)
    return [pscustomobject]@{
        job_id = [string]$Job.id
        status = [string]$Job.status
        phase = [string]$Job.phase
        message = [string]$Job.message
        error = [string]$Job.error
        attempted = [int]$Job.attempted
        verified = [int]$Job.verified
        country_matched = [int]$Job.country_matched
        selected_members = [int]$Job.selected_members
        built_routes = [int]$Job.built_routes
        quality_phase = if ($Job.PSObject.Properties['quality_phase']) { [string]$Job.quality_phase } else { '' }
        quality_completed = if ($Job.PSObject.Properties['quality_completed']) { [int]$Job.quality_completed } else { 0 }
        quality_total = if ($Job.PSObject.Properties['quality_total']) { [int]$Job.quality_total } else { 0 }
        quality_passed = if ($Job.PSObject.Properties['quality_passed']) { [int]$Job.quality_passed } else { 0 }
        updated_at = [string]$Job.updated_at
        finished_at = [string]$Job.finished_at
    }
}

function Register-PoolProfileBuild {
    param([object]$Job)
    $store = Get-PoolProfileStore
    $name = [string]$Job.spec.name
    $profile = @($store.profiles | Where-Object { [string]::Equals([string]$_.name, $name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    if ($profile.Count -gt 0) {
        $profile = $profile[0]
    } else {
        $profile = [pscustomobject]@{
            id = 'pool-group-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
            name = $name
            spec = $null
            created_at = (Get-Date).ToString('o')
            updated_at = ''
            last_used_at = ''
            build_count = 0
            activation_count = 0
            last_result = $null
            last_snapshot = $null
        }
        $store.profiles = @($store.profiles) + $profile
    }
    $profile.name = $name
    if (-not $profile.PSObject.Properties['activation_count']) { $profile | Add-Member -NotePropertyName activation_count -NotePropertyValue 0 }
    if (-not $profile.PSObject.Properties['last_snapshot']) { $profile | Add-Member -NotePropertyName last_snapshot -NotePropertyValue $null }
    $profile.spec = $Job.spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $profile.updated_at = (Get-Date).ToString('o')
    $profile.last_used_at = $profile.updated_at
    $profile.build_count = [int]$profile.build_count + 1
    $profile.last_result = ConvertTo-PoolProfileJobResult -Job $Job
    Save-PoolProfileStore -Store $store
    return $profile
}

function Get-PoolSnapshotDirectory {
    param([string]$ProfileID, [string]$JobID)
    if ($ProfileID -notmatch '^pool-group-[a-z0-9]+$' -or $JobID -notmatch '^pool-[0-9]+-[a-z0-9]+$') {
        throw '代理池快照标识无效'
    }
    return Join-Path (Join-Path $PoolSnapshotRoot $ProfileID) $JobID
}

function Save-PoolProfileSnapshot {
    param([object]$Profile, [object]$Job)
    $profileID = [string]$Profile.id
    $jobID = [string]$Job.id
    $destination = Get-PoolSnapshotDirectory -ProfileID $profileID -JobID $jobID
    $metadataFile = Join-Path $destination 'snapshot.json'
    if (Test-Path -LiteralPath $metadataFile -PathType Leaf) {
        return Get-Content -LiteralPath $metadataFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $liveStateFile = Join-Path $CustomPoolRoot 'state.json'
    if (-not (Test-Path -LiteralPath $liveStateFile -PathType Leaf)) { throw '当前代理池状态不存在，不能保存历史节点' }
    $liveState = Get-Content -LiteralPath $liveStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$liveState.build_id -ne $jobID) { throw '当前运行节点与待保存构建任务不一致' }
    if ([int]$liveState.route_count -lt 1) { throw '当前代理池没有可保存的节点' }

    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $destination + '.next-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $relativeFiles = @(
        'config.yaml', 'state.json', 'controller.secret',
        'subscriptions\clash.yaml', 'subscriptions\v2rayn.txt',
        'subscriptions\runtime-provider.txt', 'subscriptions\routes.txt'
    )
    foreach ($relative in $relativeFiles) {
        $source = Join-Path $CustomPoolRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $target = Join-Path $temporary $relative
        $targetParent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetParent)) { New-Item -ItemType Directory -Path $targetParent -Force | Out-Null }
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    $metadata = [pscustomobject]@{
        profile_id = $profileID; job_id = $jobID; saved_at = (Get-Date).ToString('o')
        node_count = [int]$liveState.route_count; country = [string]$liveState.country_filter
        outputs = @($liveState.outputs); pool_name = [string]$liveState.pool_name
    }
    Write-PoolBuildJsonAtomic -Path (Join-Path $temporary 'snapshot.json') -Value $metadata
    Move-Item -LiteralPath $temporary -Destination $destination
    Write-GatewayLog ('pool snapshot saved: profile={0}; job={1}; nodes={2}' -f $profileID, $jobID, [int]$metadata.node_count)
    return $metadata
}

function Sync-PoolProfileJobResult {
    param([object]$Job)
    if (-not [string]$Job.id) { return }
    $store = Get-PoolProfileStore
    $profileID = if ($Job.PSObject.Properties['profile_id']) { [string]$Job.profile_id } else { '' }
    $profile = $null
    if ($profileID) {
        $profile = @($store.profiles | Where-Object { [string]$_.id -eq $profileID } | Select-Object -First 1)
    }
    if (-not $profile -or $profile.Count -eq 0) {
        $profile = @($store.profiles | Where-Object { $_.last_result -and [string]$_.last_result.job_id -eq [string]$Job.id } | Select-Object -First 1)
    }
    if (-not $profile -or $profile.Count -eq 0) { return }
    $profile = $profile[0]
    if (-not $profile.PSObject.Properties['activation_count']) { $profile | Add-Member -NotePropertyName activation_count -NotePropertyValue 0 }
    if (-not $profile.PSObject.Properties['last_snapshot']) { $profile | Add-Member -NotePropertyName last_snapshot -NotePropertyValue $null }
    $changed = $false
    $currentUpdated = if ($profile.last_result) { [string]$profile.last_result.updated_at } else { '' }
    $currentStatus = if ($profile.last_result) { [string]$profile.last_result.status } else { '' }
    if ($currentUpdated -ne [string]$Job.updated_at -or $currentStatus -ne [string]$Job.status) {
        $profile.updated_at = if ([string]$Job.updated_at) { [string]$Job.updated_at } else { (Get-Date).ToString('o') }
        $profile.last_result = ConvertTo-PoolProfileJobResult -Job $Job
        $changed = $true
    }
    if ([string]$Job.status -in @('ready','partial') -and [int]$Job.built_routes -gt 0 -and
        (-not $profile.last_snapshot -or [string]$profile.last_snapshot.job_id -ne [string]$Job.id)) {
        try {
            $profile.last_snapshot = Save-PoolProfileSnapshot -Profile $profile -Job $Job
            $changed = $true
        } catch {
            Write-GatewayLog ('pool snapshot save deferred: ' + $_.Exception.Message)
        }
    }
    if ($changed) { Save-PoolProfileStore -Store $store }
}

function Get-PoolProfilesResponse {
    $job = Get-PoolBuildJob
    Sync-PoolProfileJobResult -Job $job
    $store = Get-PoolProfileStore
    $profiles = @($store.profiles | Sort-Object -Property last_used_at -Descending)
    $activeBuildID = ''
    $liveStateFile = Join-Path $CustomPoolRoot 'state.json'
    if (Test-Path -LiteralPath $liveStateFile -PathType Leaf) {
        try { $activeBuildID = [string](Get-Content -LiteralPath $liveStateFile -Raw -Encoding UTF8 | ConvertFrom-Json).build_id } catch {}
    }
    $activeProfile = @($profiles | Where-Object { $_.last_snapshot -and [string]$_.last_snapshot.job_id -eq $activeBuildID } | Select-Object -First 1)
    return [pscustomobject]@{
        profiles = $profiles
        total = $profiles.Count
        retention_limit = 100
        active_job_id = if (Test-PoolBuildActive ([string]$job.status)) { [string]$job.id } else { '' }
        active_profile_id = if ($activeProfile.Count -gt 0) { [string]$activeProfile[0].id } else { '' }
        updated_at = [string]$store.updated_at
    }
}

function Activate-PoolProfile {
    param([string]$ProfileID)
    $currentJob = Get-PoolBuildJob
    if (Test-PoolBuildActive ([string]$currentJob.status)) {
        throw [InvalidOperationException]::new('当前正在创建节点，请完成或取消后再切换历史代理池')
    }
    Sync-PoolProfileJobResult -Job $currentJob
    $store = Get-PoolProfileStore
    $profile = @($store.profiles | Where-Object { [string]$_.id -eq $ProfileID } | Select-Object -First 1)
    if ($profile.Count -lt 1) { throw [ArgumentException]::new('历史代理池分组不存在') }
    $profile = $profile[0]
    if (-not $profile.last_snapshot -or -not [string]$profile.last_snapshot.job_id) {
        throw [InvalidOperationException]::new('这个历史分组还没有保存可直接复用的节点，请先重新检测一次')
    }
    $snapshotPath = Get-PoolSnapshotDirectory -ProfileID ([string]$profile.id) -JobID ([string]$profile.last_snapshot.job_id)
    if (-not (Test-Path -LiteralPath (Join-Path $snapshotPath 'snapshot.json') -PathType Leaf)) {
        throw [InvalidOperationException]::new('这个历史分组的节点快照不存在，请重新检测生成')
    }

    $liveBuildID = ''
    $liveStateFile = Join-Path $CustomPoolRoot 'state.json'
    if (Test-Path -LiteralPath $liveStateFile -PathType Leaf) {
        try { $liveBuildID = [string](Get-Content -LiteralPath $liveStateFile -Raw -Encoding UTF8 | ConvertFrom-Json).build_id } catch {}
    }
    $now = (Get-Date).ToString('o')
    if ($liveBuildID -eq [string]$profile.last_snapshot.job_id) {
        $profile.last_used_at = $now
        Save-PoolProfileStore -Store $store
        return [pscustomobject]@{ success = $true; message = ('“{0}”已经在使用，无需重新检测或重启' -f [string]$profile.name); profile_id = [string]$profile.id; node_count = [int]$profile.last_snapshot.node_count; already_active = $true }
    }

    $managerResult = Invoke-CustomPoolManager -Action Activate -SnapshotPath $snapshotPath
    if (-not $profile.PSObject.Properties['activation_count']) { $profile | Add-Member -NotePropertyName activation_count -NotePropertyValue 0 }
    $profile.activation_count = [int]$profile.activation_count + 1
    $profile.last_used_at = $now
    $profile.updated_at = $now
    $profile | Add-Member -NotePropertyName last_activation_at -NotePropertyValue $now -Force
    Save-PoolProfileStore -Store $store
    return [pscustomobject]@{ success = $true; message = [string]$managerResult.message; profile_id = [string]$profile.id; node_count = [int]$profile.last_snapshot.node_count; already_active = $false; data = $managerResult.data }
}

function New-IdlePoolBuildJob {
    return [pscustomobject]@{
        id = ''; profile_id = ''; status = 'idle'; phase = ''; message = ''; error = ''; spec = [pscustomobject]@{ name = ''; source = ''; country = ''; target_routes = 0; outputs = @() }
        created_at = ''; started_at = ''; updated_at = ''; heartbeat_at = ''; finished_at = ''; worker_pid = 0; candidate_total = 0; window_start = 0; next_cursor = 0
        attempt_limit = 0; attempted = 0; verified = 0; country_matched = 0; selected_members = 0; desired_members = 0
        built_routes = 0; proxy_port = 0; exports = @(); previous_pool_retained = $true
        quality_phase = ''; quality_completed = 0; quality_total = 0; quality_passed = 0; build_attempt = 0
    }
}

function Get-PoolBuildWorkerProcess {
    param([object]$Job)
    if (-not [string]$Job.id) { return $null }
    try {
        $processes = @()
        $workerPID = if ($Job.PSObject.Properties['worker_pid']) { [int]$Job.worker_pid } else { 0 }
        if ($workerPID -gt 0) {
            $processes = @(Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $workerPID) -ErrorAction Stop)
        } else {
            $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') })
        }
        $jobPattern = [regex]::Escape([string]$Job.id)
        $workerPattern = [regex]::Escape([IO.Path]::GetFileName($PoolBuildWorker))
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if ($commandLine -match $jobPattern -and $commandLine -match $workerPattern) {
                return $process
            }
        }
    } catch {
        Write-GatewayLog ('pool build process check failed: ' + $_.Exception.Message)
    }
    return $null
}

function Get-PoolBuildJob {
    if (-not (Test-Path -LiteralPath $PoolBuildStateFile)) { return New-IdlePoolBuildJob }
    try {
        $job = Get-Content -LiteralPath $PoolBuildStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return New-IdlePoolBuildJob
    }
    if (-not $job.PSObject.Properties['worker_pid']) { $job | Add-Member -NotePropertyName worker_pid -NotePropertyValue 0 }
    if (-not $job.PSObject.Properties['heartbeat_at']) { $job | Add-Member -NotePropertyName heartbeat_at -NotePropertyValue ([string]$job.updated_at) }
    if (-not (Test-PoolBuildActive ([string]$job.status))) { return $job }

    $lastSignal = Get-Date
    $signalText = if ([string]$job.heartbeat_at) { [string]$job.heartbeat_at } elseif ([string]$job.updated_at) { [string]$job.updated_at } else { [string]$job.created_at }
    try { $lastSignal = [DateTimeOffset]::Parse($signalText).LocalDateTime } catch {}
    $age = (Get-Date) - $lastSignal
    $worker = Get-PoolBuildWorkerProcess -Job $job
    $reason = ''
    if ($null -eq $worker -and ([string]$job.status -ne 'queued' -or $age.TotalSeconds -gt 45)) {
        $reason = '后台工作进程已经退出'
    } elseif ($null -ne $worker -and $age.TotalMinutes -gt 20) {
        $reason = '后台工作进程超过 20 分钟没有心跳'
        try {
            Stop-Process -Id ([int]$worker.ProcessId) -Force -ErrorAction Stop
            Write-GatewayLog ('terminated stale pool build worker: job={0}; pid={1}' -f [string]$job.id, [int]$worker.ProcessId)
        } catch {
            Write-GatewayLog ('stale pool build worker termination failed: ' + $_.Exception.Message)
        }
    }
    if ($reason) {
        $now = (Get-Date).ToString('o')
        $job.status = 'interrupted'; $job.phase = 'interrupted'; $job.error = $reason
        $job.message = '后台任务已中断，上一版代理池保持运行；现在可以重新提交'
        $job.worker_pid = 0; $job.heartbeat_at = $now; $job.updated_at = $now; $job.finished_at = $now
        $job.previous_pool_retained = $true
        Write-PoolBuildJsonAtomic -Path $PoolBuildStateFile -Value $job
        Write-GatewayLog ('recovered stale pool build job: job={0}; reason={1}' -f [string]$job.id, $reason)
    }
    return $job
}

function Test-PoolBuildActive {
    param([string]$Status)
    return $Status -in @('queued','loading','verifying','building','cancelling')
}

function Get-PoolBuildStatus {
    $job = Get-PoolBuildJob
    Sync-PoolProfileJobResult -Job $job
    return [pscustomobject]@{
        job = $job
        capabilities = [pscustomobject]@{ max_nodes = 100; max_routes = 100; sources = @('proxyip','socks5','http','https','all'); outputs = @('port','clash','v2rayn'); async = $true }
    }
}

function ConvertTo-WindowsProcessArgument {
    param([string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-PoolBuild {
    param([object]$Payload)
    $gate = [System.Threading.SemaphoreSlim]$SharedState.poolBuildGate
    if (-not $gate.Wait(0)) { throw [InvalidOperationException]::new('已有代理池构建请求正在提交') }
    try {
    $current = Get-PoolBuildJob
    if (Test-PoolBuildActive ([string]$current.status)) { throw [InvalidOperationException]::new('已有代理池构建任务正在运行') }
    Sync-PoolProfileJobResult -Job $current
    if (-not (Test-Path -LiteralPath $PoolBuildWorker -PathType Leaf)) { throw '代理池后台工作脚本尚未安装' }
    if (-not (Test-Path -LiteralPath $CustomPoolManager -PathType Leaf)) { throw '代理池质量构建脚本尚未安装' }

    $name = ([string]$Payload.name).Trim()
    if (-not $name) { $name = '默认自选池' }
    if ($name.Length -gt 40) { throw [ArgumentException]::new('代理池名称最多 40 个字符') }
    $source = ([string]$Payload.source).Trim().ToLowerInvariant()
    if ($source -notin @('proxyip','socks5','http','https','all')) { throw [ArgumentException]::new('请选择有效的候选来源') }
    $country = ([string]$Payload.country).Trim().ToUpperInvariant()
    if ($country -eq 'ALL') { $country = '' }
    if ($country -and $country -notmatch '^[A-Z]{2}$') { throw [ArgumentException]::new('出口国家格式无效') }
    $target = [int]$Payload.target_routes
    if ($target -lt 1 -or $target -gt 100) { throw [ArgumentException]::new('可切换节点数量必须在 1–100 之间') }
    $outputs = @($Payload.outputs | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if ($outputs.Count -lt 1 -or @($outputs | Where-Object { $_ -notin @('port','clash','v2rayn') }).Count -gt 0) { throw [ArgumentException]::new('请至少选择端口、Clash、V2RayN 中的一种有效输出') }

    $now = (Get-Date).ToString('o')
    $jobID = 'pool-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $spec = [pscustomobject]@{ name = $name; source = $source; country = $country; target_routes = $target; outputs = @($outputs) }
    $job = New-IdlePoolBuildJob
    $job.id = $jobID; $job.status = 'queued'; $job.phase = 'queued'; $job.spec = $spec
    $job.message = '任务已进入服务器后台；关闭弹窗或刷新页面不会中断'; $job.created_at = $now; $job.updated_at = $now; $job.heartbeat_at = $now
    Write-PoolBuildJsonAtomic -Path $PoolBuildStateFile -Value $job
    try {
        $profile = Register-PoolProfileBuild -Job $job
        $job.profile_id = [string]$profile.id
        Write-PoolBuildJsonAtomic -Path $PoolBuildStateFile -Value $job
    } catch {
        Write-GatewayLog ('pool profile registration failed; build will continue: ' + $_.Exception.Message)
    }
    Remove-Item -LiteralPath $PoolBuildCancelFile -Force -ErrorAction SilentlyContinue

    $specJson = $spec | ConvertTo-Json -Depth 8 -Compress
    $specBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($specJson))
    $workerLog = Join-Path (Split-Path -Parent $LogPath) 'pool-build-worker.log'
    $arguments = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PoolBuildWorker,
        '-JobID',$jobID,'-SpecBase64',$specBase64,'-BackendBase',$BackendBase,
        '-StateFile',$PoolBuildStateFile,'-SelectionFile',$PoolBuildSelectionFile,'-RotationFile',$PoolBuildRotationFile,'-CancelFile',$PoolBuildCancelFile,
        '-ManagerScript',$CustomPoolManager,'-CustomPoolRoot',$CustomPoolRoot,'-CustomPoolTaskName',$CustomPoolTaskName,
        '-ProxyPort',[string]$CustomPoolProxyPort,'-ControllerPort',[string]$CustomPoolControllerPort,'-LogFile',$workerLog
    )
    try {
        $argumentLine = (@($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath $script:PowerShellExecutable -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
        Write-GatewayLog ('pool build worker started: job={0}; pid={1}' -f $jobID, $process.Id)
    } catch {
        $job.status = 'failed'; $job.phase = 'failed'; $job.error = $_.Exception.Message; $job.message = '后台任务启动失败，现有代理池未改变'; $job.finished_at = (Get-Date).ToString('o'); $job.updated_at = $job.finished_at
        Write-PoolBuildJsonAtomic -Path $PoolBuildStateFile -Value $job
        throw
    }
    return $job
    } finally {
        $null = $gate.Release()
    }
}

function Cancel-PoolBuild {
    $job = Get-PoolBuildJob
    if (-not (Test-PoolBuildActive ([string]$job.status))) { throw [InvalidOperationException]::new('当前没有可取消的构建任务') }
    $parent = Split-Path -Parent $PoolBuildCancelFile
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($PoolBuildCancelFile, [string]$job.id, (New-Object Text.UTF8Encoding($false)))
    $job.status = 'cancelling'; $job.message = '已提交取消请求，正在结束当前节点检测；现有代理池继续运行'; $job.updated_at = (Get-Date).ToString('o')
    Write-PoolBuildJsonAtomic -Path $PoolBuildStateFile -Value $job
    return $job
}

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)
    $request = $Context.Request
    if (-not (Test-LanAddress $request.RemoteEndPoint.Address)) {
        Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'LAN access only' }
        return
    }

    $path = $request.Url.AbsolutePath
    if ($request.HttpMethod -eq 'GET' -and $path -in @('/', '/index.html')) {
        if (-not (Test-Path -LiteralPath $StaticFile)) {
            Send-Json -Context $Context -StatusCode 503 -Value @{ error = 'UI file is unavailable' }
            return
        }
        Send-Bytes -Context $Context -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Bytes ([System.IO.File]::ReadAllBytes($StaticFile))
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -in @('/favicon.svg', '/logo.svg')) {
        if (-not (Test-Path -LiteralPath $LogoFile -PathType Leaf)) {
            Send-Json -Context $Context -StatusCode 503 -Value @{ error = 'Logo file is unavailable' }
            return
        }
        Send-Bytes -Context $Context -StatusCode 200 -ContentType 'image/svg+xml; charset=utf-8' -Bytes ([System.IO.File]::ReadAllBytes($LogoFile))
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/healthz') {
        Send-Json -Context $Context -StatusCode 200 -Value @{ status = 'ok'; gateway = $script:GatewayVersion; backend = $BackendBase }
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/custom-pool') {
        Send-Json -Context $Context -StatusCode 200 -Value (Get-CustomPoolStatusDirect)
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/pool-build') {
        Send-Json -Context $Context -StatusCode 200 -Value (Get-PoolBuildStatus)
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/pool-profiles') {
        Send-Json -Context $Context -StatusCode 200 -Value (Get-PoolProfilesResponse)
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -in @('/subscriptions/custom/clash', '/subscriptions/custom/v2rayn')) {
        $customState = Get-CustomPoolStatusDirect
        $requiredOutput = if ($path.EndsWith('/clash')) { 'clash' } else { 'v2rayn' }
        if (@($customState.outputs).Count -gt 0 -and @($customState.outputs) -notcontains $requiredOutput) {
            Send-Json -Context $Context -StatusCode 404 -Value @{ error = ('当前代理池未启用 ' + $requiredOutput + ' 输出') }
            return
        }
        $file = if ($path.EndsWith('/clash')) { Join-Path $CustomPoolRoot 'subscriptions\clash.yaml' } else { Join-Path $CustomPoolRoot 'subscriptions\v2rayn.txt' }
        if (-not (Test-Path -LiteralPath $file)) {
            Send-Json -Context $Context -StatusCode 404 -Value @{ error = '自选代理池尚未生成订阅' }
            return
        }
        $contentType = if ($path.EndsWith('/clash')) { 'application/yaml; charset=utf-8' } else { 'text/plain; charset=utf-8' }
        Send-Bytes -Context $Context -StatusCode 200 -ContentType $contentType -Bytes ([System.IO.File]::ReadAllBytes($file))
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
        $status = Add-StatusEnhancements (Invoke-BackendJson '/api/status')
        Send-Json -Context $Context -StatusCode 200 -Value $status
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/catalog') {
        $result = Invoke-BackendRaw -PathAndQuery ($request.Url.PathAndQuery) -Method 'GET' -Body '' -ConfirmedHeader '' -TimeoutMS 70000
        if ($result.StatusCode -ne 200) {
            Send-Text -Context $Context -StatusCode $result.StatusCode -ContentType $result.ContentType -Text $result.Body
            return
        }
        $catalog = $result.Body | ConvertFrom-Json
        if (-not $catalog.capabilities) {
            $catalog | Add-Member -NotePropertyName capabilities -NotePropertyValue ([pscustomobject]@{})
        }
        $catalog.capabilities | Add-Member -NotePropertyName batch_verify_max -NotePropertyValue 20 -Force
        $catalog.capabilities | Add-Member -NotePropertyName auto_select -NotePropertyValue $true -Force
        $catalog.capabilities | Add-Member -NotePropertyName validation_concurrency -NotePropertyValue 4 -Force
        $catalog.capabilities | Add-Member -NotePropertyName operation_progress -NotePropertyValue 'ndjson' -Force
        $catalog.capabilities | Add-Member -NotePropertyName duplicate_window_seconds -NotePropertyValue 120 -Force
        Send-Json -Context $Context -StatusCode 200 -Value $catalog
        return
    }

    if ($request.HttpMethod -eq 'GET' -and $path -in @('/api/history', '/api/actions', '/api/probe', '/api/country-ports', '/api/cloudflare-config')) {
        $result = Invoke-BackendRaw -PathAndQuery ($request.Url.PathAndQuery) -Method 'GET' -Body '' -ConfirmedHeader ''
        Send-Text -Context $Context -StatusCode $result.StatusCode -ContentType $result.ContentType -Text $result.Body
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/action') {
        if (-not (Test-SameOrigin $request) -or $request.Headers['X-ProxyTunnel-Action'] -ne 'confirmed') {
            Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Second confirmation is required' }
            return
        }
        if ($request.ContentLength64 -gt 4096) {
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Request body is too large' }
            return
        }
        $body = Get-RequestBody $request
        $payload = $body | ConvertFrom-Json
        if ($payload.action -notin @('healthcheck', 'refresh', 'restart')) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Unsupported action' }
            return
        }
        $result = Invoke-BackendRaw -PathAndQuery '/api/action' -Method 'POST' -Body $body -ConfirmedHeader 'confirmed'
        Send-Text -Context $Context -StatusCode $result.StatusCode -ContentType $result.ContentType -Text $result.Body
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/pool-profiles') {
        if (-not (Test-SameOrigin $request) -or $request.Headers['X-ProxyTunnel-Action'] -ne 'confirmed') {
            Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Second confirmation is required' }
            return
        }
        if ($request.ContentLength64 -gt 4096) {
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Request body is too large' }
            return
        }
        try {
            $payload = (Get-RequestBody $request) | ConvertFrom-Json
            if ([string]$payload.action -ne 'activate') {
                Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Unsupported pool profile action' }
                return
            }
            $result = Activate-PoolProfile -ProfileID ([string]$payload.profile_id)
            Send-Json -Context $Context -StatusCode 200 -Value $result
        } catch [System.ArgumentException] {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = $_.Exception.Message }
        } catch [System.InvalidOperationException] {
            Send-Json -Context $Context -StatusCode 409 -Value @{ error = $_.Exception.Message }
        } catch {
            Write-GatewayLog ('pool profile activation failed: ' + $_.Exception.Message)
            Send-Json -Context $Context -StatusCode 500 -Value @{ error = '历史代理池切换失败'; detail = $_.Exception.Message }
        }
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/pool-build') {
        if (-not (Test-SameOrigin $request) -or $request.Headers['X-ProxyTunnel-Action'] -ne 'confirmed') {
            Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Second confirmation is required' }
            return
        }
        if ($request.ContentLength64 -gt 16384) {
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Request body is too large' }
            return
        }
        $body = Get-RequestBody $request
        try {
            $payload = $body | ConvertFrom-Json
            if ([string]$payload.action -eq 'build') {
                $job = Start-PoolBuild -Payload $payload
                Send-Json -Context $Context -StatusCode 202 -Value @{ success = $true; message = $job.message; job = $job }
            } elseif ([string]$payload.action -eq 'cancel') {
                $job = Cancel-PoolBuild
                Send-Json -Context $Context -StatusCode 202 -Value @{ success = $true; message = $job.message; job = $job }
            } else {
                Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Unsupported pool build action' }
            }
        } catch [System.ArgumentException] {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = $_.Exception.Message }
        } catch [System.InvalidOperationException] {
            Send-Json -Context $Context -StatusCode 409 -Value @{ error = $_.Exception.Message }
        } catch {
            Write-GatewayLog ('pool build request failed: ' + $_.Exception.Message)
            Send-Json -Context $Context -StatusCode 500 -Value @{ error = '代理池后台任务启动失败'; detail = $_.Exception.Message }
        }
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/custom-pool') {
        if (-not (Test-SameOrigin $request) -or $request.Headers['X-ProxyTunnel-Action'] -ne 'confirmed') {
            Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Second confirmation is required' }
            return
        }
        if ($request.ContentLength64 -gt 4096) {
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Request body is too large' }
            return
        }
        $body = Get-RequestBody $request
        $payload = $body | ConvertFrom-Json
        $managerAction = switch ([string]$payload.action) {
            'sync' { 'Sync' }
            'restart' { 'Restart' }
            'stop' { 'Stop' }
            default { '' }
        }
        if (-not $managerAction) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Unsupported custom pool action' }
            return
        }
        $result = Invoke-CustomPoolManager -Action $managerAction
        Send-Json -Context $Context -StatusCode 200 -Value @{ success = $true; message = $result.message; data = $result.data }
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -in @('/api/probe', '/api/speed', '/api/country-ports')) {
        if (-not (Test-SameOrigin $request) -or $request.Headers['X-ProxyTunnel-Action'] -ne 'confirmed') {
            Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Second confirmation is required' }
            return
        }
        if ($request.ContentLength64 -gt 16384) {
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Request body is too large' }
            return
        }
        $body = Get-RequestBody $request
        $result = Invoke-BackendRaw -PathAndQuery $path -Method 'POST' -Body $body -ConfirmedHeader 'confirmed'
        Send-Text -Context $Context -StatusCode $result.StatusCode -ContentType $result.ContentType -Text $result.Body
        return
    }

    if ($request.HttpMethod -eq 'POST' -and $path -in @('/api/catalog/action', '/api/cloudflare-config')) {
        if (-not (Test-SameOrigin $request) -or $request.Headers['X-ProxyTunnel-Action'] -ne 'confirmed') {
            Send-Json -Context $Context -StatusCode 403 -Value @{ error = 'Second confirmation is required' }
            return
        }
        $maxBodySize = if ($path -eq '/api/cloudflare-config') { 524288 } else { 32768 }
        if ($request.ContentLength64 -gt $maxBodySize) {
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Request body is too large' }
            return
        }
        $body = Get-RequestBody $request
        if ($path -eq '/api/catalog/action') {
            $payload = $body | ConvertFrom-Json
            if ($payload.action -in @('verify_batch', 'auto_select')) {
                $requestKey = Get-CatalogRequestKey -Payload $payload
                $cachedResult = Get-CachedCatalogResult -Key $requestKey
                $useProgressStream = $request.Headers['X-ProxyTunnel-Progress'] -eq 'stream'
                if ($useProgressStream) {
                    Start-NDJsonResponse -Context $Context
                    try {
                        if ($cachedResult) {
                            $batchResult = $cachedResult | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                            $batchResult | Add-Member -NotePropertyName deduplicated -NotePropertyValue $true -Force
                            $batchResult.message = '已阻止重复提交；' + [string]$batchResult.message
                        } else {
                            Send-NDJsonLine -Context $Context -Value @{ type = 'progress'; data = @{ phase = 'preparing'; attempted = 0; total = 0; verified = 0; failed = 0; country_matched = 0; selected = 0; requested = [int]$payload.count } }
                            $streamContext = $Context
                            $progressCallback = {
                                param($progress)
                                Send-NDJsonLine -Context $streamContext -Value @{ type = 'progress'; data = $progress }
                            }.GetNewClosure()
                            $batchResult = Invoke-CatalogBatchAction -Payload $payload -ProgressCallback $progressCallback
                            $batchResult | Add-Member -NotePropertyName deduplicated -NotePropertyValue $false -Force
                            $batchResult | Add-Member -NotePropertyName request_id -NotePropertyValue ([string]$payload.request_id) -Force
                            Set-CachedCatalogResult -Key $requestKey -Result $batchResult
                        }
                        Send-NDJsonLine -Context $Context -Value @{ type = 'result'; data = $batchResult }
                    } catch [System.ArgumentException] {
                        try { Send-NDJsonLine -Context $Context -Value @{ type = 'error'; status = 400; message = $_.Exception.Message } } catch {}
                    } catch [System.InvalidOperationException] {
                        try { Send-NDJsonLine -Context $Context -Value @{ type = 'error'; status = 409; message = $_.Exception.Message } } catch {}
                    } catch {
                        Write-GatewayLog ('catalog progress stream failed: ' + $_.Exception.Message)
                        try { Send-NDJsonLine -Context $Context -Value @{ type = 'error'; status = 500; message = '候选任务执行失败' } } catch {}
                    } finally {
                        try { $Context.Response.OutputStream.Close() } catch {}
                    }
                    return
                }
                try {
                    if ($cachedResult) {
                        $batchResult = $cachedResult | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                        $batchResult | Add-Member -NotePropertyName deduplicated -NotePropertyValue $true -Force
                        $batchResult.message = '已阻止重复提交；' + [string]$batchResult.message
                    } else {
                        $batchResult = Invoke-CatalogBatchAction -Payload $payload
                        $batchResult | Add-Member -NotePropertyName deduplicated -NotePropertyValue $false -Force
                        $batchResult | Add-Member -NotePropertyName request_id -NotePropertyValue ([string]$payload.request_id) -Force
                        Set-CachedCatalogResult -Key $requestKey -Result $batchResult
                    }
                    Send-Json -Context $Context -StatusCode 200 -Value $batchResult
                } catch [System.ArgumentException] {
                    Send-Json -Context $Context -StatusCode 400 -Value @{ error = $_.Exception.Message }
                } catch [System.InvalidOperationException] {
                    Send-Json -Context $Context -StatusCode 409 -Value @{ error = $_.Exception.Message }
                }
                return
            }
        }
        $result = Invoke-BackendRaw -PathAndQuery $path -Method 'POST' -Body $body -ConfirmedHeader 'confirmed'
        Send-Text -Context $Context -StatusCode $result.StatusCode -ContentType $result.ContentType -Text $result.Body
        return
    }

    Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Not found' }
}

if ($RequestWorker) {
    if ($null -eq $RequestContext) { throw 'RequestWorker requires RequestContext' }
    try {
        Handle-Request $RequestContext
    } catch {
        Write-GatewayLog ("request failed: " + $_.Exception.Message)
        try {
            if ($RequestContext.Response.OutputStream.CanWrite) {
                Send-Json -Context $RequestContext -StatusCode 502 -Value @{ error = 'Monitor backend request failed' }
            }
        } catch {
            # The client may already have closed the connection.
        }
    }
    return
}

$MaxConcurrentRequests = [Math]::Max(2, [Math]::Min(32, $MaxConcurrentRequests))
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($ListenPrefix)
$listener.IgnoreWriteExceptions = $true
$listener.Start()
$runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrentRequests)
$runspacePool.Open()
$activeRequests = [System.Collections.ArrayList]::new()
$scriptPath = [IO.Path]::GetFullPath($PSCommandPath)
Write-GatewayLog "gateway started; listen=$ListenPrefix backend=$BackendBase concurrency=$MaxConcurrentRequests"

function Complete-RequestRunspaces {
    param([switch]$StopOutstanding)
    for ($index = $activeRequests.Count - 1; $index -ge 0; $index--) {
        $entry = $activeRequests[$index]
        if (-not $StopOutstanding -and -not $entry.Async.IsCompleted) { continue }
        try {
            if ($StopOutstanding -and -not $entry.Async.IsCompleted) {
                $entry.PowerShell.Stop()
            } else {
                $null = $entry.PowerShell.EndInvoke($entry.Async)
            }
        } catch {
            Write-GatewayLog ('request runspace failed: ' + $_.Exception.Message)
            try {
                if ($entry.Context.Response.OutputStream.CanWrite) {
                    Send-Json -Context $entry.Context -StatusCode 502 -Value @{ error = 'Monitor gateway request failed' }
                }
            } catch {}
        } finally {
            $entry.PowerShell.Dispose()
            $activeRequests.RemoveAt($index)
        }
    }
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        Complete-RequestRunspaces
        if ($activeRequests.Count -ge ($MaxConcurrentRequests * 4)) {
            Send-Json -Context $context -StatusCode 503 -Value @{ error = 'Monitor gateway is busy; retry shortly' }
            continue
        }

        $powerShell = [PowerShell]::Create()
        $powerShell.RunspacePool = $runspacePool
        $null = $powerShell.AddCommand($scriptPath)
        $parameters = [ordered]@{
            ProjectRoot = $ProjectRoot; ListenPrefix = $ListenPrefix; BackendBase = $BackendBase
            StaticFile = $StaticFile; LogoFile = $LogoFile; LogPath = $LogPath; AllowedCIDR = $AllowedCIDR
            ProxyUrl = $ProxyUrl; CustomPoolManager = $CustomPoolManager; CustomPoolRoot = $CustomPoolRoot
            CandidateRotationStateFile = $CandidateRotationStateFile; PoolBuildWorker = $PoolBuildWorker
            PoolBuildStateFile = $PoolBuildStateFile; PoolProfileFile = $PoolProfileFile; PoolSnapshotRoot = $PoolSnapshotRoot
            PoolBuildSelectionFile = $PoolBuildSelectionFile; PoolBuildRotationFile = $PoolBuildRotationFile
            PoolBuildCancelFile = $PoolBuildCancelFile; CustomPoolTaskName = $CustomPoolTaskName
            CustomPoolProxyPort = $CustomPoolProxyPort; CustomPoolControllerPort = $CustomPoolControllerPort
            MaxConcurrentRequests = $MaxConcurrentRequests; RequestContext = $context; RequestWorker = $true; SharedState = $SharedState
        }
        foreach ($name in $parameters.Keys) { $null = $powerShell.AddParameter($name, $parameters[$name]) }
        try {
            $async = $powerShell.BeginInvoke()
            $null = $activeRequests.Add([pscustomobject]@{ PowerShell = $powerShell; Async = $async; Context = $context })
        } catch {
            $powerShell.Dispose()
            Write-GatewayLog ('request dispatch failed: ' + $_.Exception.Message)
            try { Send-Json -Context $context -StatusCode 503 -Value @{ error = 'Monitor gateway could not dispatch request' } } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Complete-RequestRunspaces -StopOutstanding
    $runspacePool.Close()
    $runspacePool.Dispose()
    Write-GatewayLog 'gateway stopped'
}
