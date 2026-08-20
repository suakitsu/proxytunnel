param(
    [ValidateSet('Status', 'Sync', 'Restart', 'Stop', 'Activate')]
    [string]$Action = 'Status',
    [string]$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')),
    [string]$BackendBase = 'http://127.0.0.1:9191',
    [string]$Root = (Join-Path $ProjectRoot 'var\custom-pool'),
    [string]$MainProviderFile = (Join-Path $ProjectRoot 'var\main-pool\providers\v2rayn-subscription.yaml'),
    [string]$MihomoExecutable = (Join-Path $ProjectRoot 'bin\mihomo.exe'),
    [string]$TaskName = 'ProxyTunnel-Custom-Pool',
    [int]$ProxyPort = 7891,
    [int]$ControllerPort = 19092,
    [int]$RoutesPerProxyIP = 8,
    [int]$ProbeRoutesPerProxyIP = 16,
    [int]$ProbeTimeoutMs = 12000,
    [int]$ProbeConcurrency = 4,
    [string]$SelectionFile = '',
    [ValidateRange(1, 100)]
    [int]$TargetRoutes = 8,
    [string]$OutputsCsv = 'port,clash,v2rayn',
    [string]$PoolName = '默认自选池',
    [string]$CountryFilter = '',
    [string]$SourceFilter = 'proxyip',
    [string]$BuildID = '',
    [string]$ProgressFile = '',
    [string]$CancelFile = '',
    [string]$SnapshotPath = '',
    [string]$AllowedCIDR = '127.0.0.0/8'
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $Root 'config.yaml'
$StateFile = Join-Path $Root 'state.json'
$SecretFile = Join-Path $Root 'controller.secret'
$ClashExportFile = Join-Path $Root 'subscriptions\clash.yaml'
$V2rayNExportFile = Join-Path $Root 'subscriptions\v2rayn.txt'
$RuntimeProviderFile = Join-Path $Root 'subscriptions\runtime-provider.txt'
$RawURIFile = Join-Path $Root 'subscriptions\routes.txt'
$TemplateCursorFile = Join-Path $Root 'template-rotation.json'
$BuildRoot = Join-Path $Root '_build-staging'
$BuildConfigFile = Join-Path $BuildRoot 'config.yaml'
$BuildSecretFile = Join-Path $BuildRoot 'controller.secret'
$BuildRuntimeProviderFile = Join-Path $BuildRoot 'subscriptions\runtime-provider.txt'
$BuildTaskName = $TaskName + '-Build'
$BuildProxyPort = if ($ProxyPort -eq 7891) { 17892 } else { $ProxyPort + 10001 }
$BuildControllerPort = $ControllerPort + 2
$LogFile = Join-Path $ProjectRoot 'var\logs\custom-pool.log'
$safeGroupName = (($PoolName -replace '[^A-Za-z0-9_-]', '-') -replace '-+', '-').Trim('-')
if (-not $safeGroupName) { $safeGroupName = 'POOL' }
$GroupName = ('CUSTOM-' + $safeGroupName).Substring(0, [Math]::Min(48, ('CUSTOM-' + $safeGroupName).Length))
$OutputModes = @($OutputsCsv -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)

function Write-UTF8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-CustomLog {
    param([string]$Message)
    $parent = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

function ConvertTo-YamlString {
    param([AllowEmptyString()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Get-OrCreateSecret {
    if (Test-Path -LiteralPath $SecretFile) {
        $existing = (Get-Content -LiteralPath $SecretFile -Raw).Trim()
        if ($existing.Length -ge 32) {
            return $existing
        }
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $secret = ([Convert]::ToBase64String($bytes)).TrimEnd('=')
    Write-UTF8NoBom -Path $SecretFile -Content $secret
    return $secret
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-State {
    param([object]$State)
    $temporary = $StateFile + '.next-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-UTF8NoBom -Path $temporary -Content ($State | ConvertTo-Json -Depth 20)
    Move-Item -LiteralPath $temporary -Destination $StateFile -Force
}

function Test-CustomBuildCancelled {
    if (-not $CancelFile -or -not $BuildID -or -not (Test-Path -LiteralPath $CancelFile -PathType Leaf)) {
        return $false
    }
    try {
        return (Get-Content -LiteralPath $CancelFile -Raw -Encoding UTF8).Trim() -eq $BuildID
    } catch {
        return $false
    }
}

function Update-CustomBuildProgress {
    param(
        [string]$QualityPhase,
        [int]$Completed,
        [int]$Total,
        [int]$Passed,
        [string]$Message
    )
    if (-not $ProgressFile -or -not $BuildID -or -not (Test-Path -LiteralPath $ProgressFile -PathType Leaf)) {
        return
    }
    try {
        $job = Get-Content -LiteralPath $ProgressFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$job.id -ne $BuildID) { return }
        $job | Add-Member -NotePropertyName quality_phase -NotePropertyValue $QualityPhase -Force
        $job | Add-Member -NotePropertyName quality_completed -NotePropertyValue $Completed -Force
        $job | Add-Member -NotePropertyName quality_total -NotePropertyValue $Total -Force
        $job | Add-Member -NotePropertyName quality_passed -NotePropertyValue $Passed -Force
        if ($Message) { $job.message = $Message }
        $now = (Get-Date).ToString('o')
        $job | Add-Member -NotePropertyName heartbeat_at -NotePropertyValue $now -Force
        $job.updated_at = $now
        $temporary = $ProgressFile + '.manager.next-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        [IO.File]::WriteAllText($temporary, ($job | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $ProgressFile -Force
    } catch {
        Write-CustomLog ('quality progress update skipped: ' + $_.Exception.Message)
    }
}

function Get-QueryMap {
    param([string]$Query)
    $result = [ordered]@{}
    foreach ($part in @($Query.TrimStart('?') -split '&')) {
        if (-not $part) { continue }
        $pair = $part -split '=', 2
        $key = [uri]::UnescapeDataString($pair[0])
        $value = if ($pair.Count -gt 1) { [uri]::UnescapeDataString($pair[1]) } else { '' }
        $result[$key] = $value
    }
    return $result
}

function Convert-QueryMapToString {
    param([System.Collections.IDictionary]$Map)
    $parts = @()
    foreach ($key in $Map.Keys) {
        $parts += ([uri]::EscapeDataString([string]$key) + '=' + [uri]::EscapeDataString([string]$Map[$key]))
    }
    return $parts -join '&'
}

function Convert-VlessTemplate {
    param(
        [string]$Template,
        [object]$Candidate,
        [int]$CandidateIndex,
        [int]$RouteIndex,
        [int]$TemplateIndex
    )
    if ($Template -notmatch '^vless://') {
        throw 'main subscription contains an unsupported template'
    }
    $withoutFragment = ($Template -split '#', 2)[0]
    $queryIndex = $withoutFragment.IndexOf('?')
    if ($queryIndex -lt 1) {
        throw 'VLESS template does not contain query parameters'
    }
    $prefix = $withoutFragment.Substring(0, $queryIndex)
    $query = Get-QueryMap -Query $withoutFragment.Substring($queryIndex + 1)
    $query['path'] = '/proxyip=' + [string]$Candidate.node.address
    $country = ([string]$Candidate.verification.country_code).ToUpperInvariant()
    if (-not $country) { $country = 'UN' }
    $name = '{0}-CUSTOM-{1:D2}-{2:D2}' -f $country, $CandidateIndex, $RouteIndex
    return [pscustomobject]@{
        name = $name
        uri = $prefix + '?' + (Convert-QueryMapToString -Map $query) + '#' + [uri]::EscapeDataString($name)
        source = 'proxyip'
        candidate_id = [string]$Candidate.node.id
        country_code = $country
        country_name = [string]$Candidate.verification.country_name
        candidate_address = [string]$Candidate.node.address
        candidate_latency_ms = [int]$Candidate.verification.latency_ms
        template_index = $TemplateIndex
    }
}

function Convert-DirectCandidate {
    param([object]$Candidate, [int]$CandidateIndex)
    $source = ([string]$Candidate.node.source).ToLowerInvariant()
    $country = ([string]$Candidate.verification.country_code).ToUpperInvariant()
    if (-not $country) { $country = 'UN' }
    $name = '{0}-{1}-CUSTOM-{2:D2}' -f $country, $source.ToUpperInvariant(), $CandidateIndex
    $address = [string]$Candidate.node.address
    $scheme = if ($source -eq 'socks5') { 'socks' } elseif ($source -eq 'https') { 'http' } else { $source }
    return [pscustomobject]@{
        name = $name
        uri = $scheme + '://' + $address + '#' + [uri]::EscapeDataString($name)
        source = $source
        candidate_id = [string]$Candidate.node.id
        country_code = $country
        country_name = [string]$Candidate.verification.country_name
        candidate_address = $address
        candidate_latency_ms = [int]$Candidate.verification.latency_ms
    }
}

function Parse-VlessRoute {
    param([object]$Route)
    $uri = [uri][string]$Route.uri
    $query = Get-QueryMap -Query $uri.Query
    $uuid = $uri.UserInfo
    if (-not $uuid) {
        $match = [regex]::Match([string]$Route.uri, '^vless://([^@]+)@')
        if ($match.Success) { $uuid = $match.Groups[1].Value }
    }
    return [pscustomobject]@{
        name = [string]$Route.name
        type = 'vless'
        server = $uri.Host
        port = $uri.Port
        uuid = $uuid
        network = if ($query['type']) { [string]$query['type'] } else { 'ws' }
        tls = ([string]$query['security']).ToLowerInvariant() -eq 'tls'
        servername = [string]$query['sni']
        fingerprint = [string]$query['fp']
        path = [string]$query['path']
        host_header = [string]$query['host']
    }
}

function Append-ProxyYaml {
    param([System.Text.StringBuilder]$Builder, [object]$Route)
    if ($Route.source -eq 'proxyip') {
        $node = Parse-VlessRoute -Route $Route
        [void]$Builder.AppendLine('  - name: ' + (ConvertTo-YamlString $node.name))
        [void]$Builder.AppendLine('    type: vless')
        [void]$Builder.AppendLine('    server: ' + (ConvertTo-YamlString $node.server))
        [void]$Builder.AppendLine('    port: ' + [string]$node.port)
        [void]$Builder.AppendLine('    uuid: ' + (ConvertTo-YamlString $node.uuid))
        [void]$Builder.AppendLine('    network: ' + (ConvertTo-YamlString $node.network))
        [void]$Builder.AppendLine('    tls: ' + ([string]$node.tls).ToLowerInvariant())
        [void]$Builder.AppendLine('    udp: true')
        if ($node.servername) { [void]$Builder.AppendLine('    servername: ' + (ConvertTo-YamlString $node.servername)) }
        if ($node.fingerprint) { [void]$Builder.AppendLine('    client-fingerprint: ' + (ConvertTo-YamlString $node.fingerprint)) }
        [void]$Builder.AppendLine('    ws-opts:')
        [void]$Builder.AppendLine('      path: ' + (ConvertTo-YamlString $node.path))
        if ($node.host_header) {
            [void]$Builder.AppendLine('      headers:')
            [void]$Builder.AppendLine('        Host: ' + (ConvertTo-YamlString $node.host_header))
        }
        return
    }

    $address = [string]$Route.candidate_address
    $lastColon = $address.LastIndexOf(':')
    if ($lastColon -lt 1) { throw 'direct proxy candidate has no port' }
    $host = $address.Substring(0, $lastColon).Trim('[', ']')
    $port = [int]$address.Substring($lastColon + 1)
    $type = if ($Route.source -eq 'socks5') { 'socks5' } else { 'http' }
    [void]$Builder.AppendLine('  - name: ' + (ConvertTo-YamlString ([string]$Route.name)))
    [void]$Builder.AppendLine('    type: ' + $type)
    [void]$Builder.AppendLine('    server: ' + (ConvertTo-YamlString $host))
    [void]$Builder.AppendLine('    port: ' + [string]$port)
    if ($Route.source -eq 'https') { [void]$Builder.AppendLine('    tls: true') }
    if ($Route.source -eq 'socks5') { [void]$Builder.AppendLine('    udp: true') }
}

function Build-ClashConfig {
    param(
        [object[]]$Routes,
        [string]$Secret,
        [bool]$Runtime,
        [int]$RuntimeProxyPort = $ProxyPort,
        [int]$RuntimeControllerPort = $ControllerPort
    )
    $builder = New-Object System.Text.StringBuilder
    if ($Runtime) {
        [void]$builder.AppendLine('mixed-port: ' + [string]$RuntimeProxyPort)
        [void]$builder.AppendLine('allow-lan: true')
        [void]$builder.AppendLine('bind-address: "*"')
        [void]$builder.AppendLine('external-controller: "127.0.0.1:' + [string]$RuntimeControllerPort + '"')
        [void]$builder.AppendLine('secret: ' + (ConvertTo-YamlString $Secret))
        [void]$builder.AppendLine('log-level: warning')
        [void]$builder.AppendLine('tcp-concurrent: true')
        [void]$builder.AppendLine('mode: rule')
        [void]$builder.AppendLine('ipv6: false')
        [void]$builder.AppendLine('proxy-providers:')
        [void]$builder.AppendLine('  custom-subscription:')
        [void]$builder.AppendLine('    type: file')
        [void]$builder.AppendLine('    path: "./subscriptions/runtime-provider.txt"')
        [void]$builder.AppendLine('    health-check:')
        [void]$builder.AppendLine('      enable: true')
        [void]$builder.AppendLine('      url: "https://www.cloudflare.com/cdn-cgi/trace"')
        [void]$builder.AppendLine('      interval: 60')
        [void]$builder.AppendLine('      timeout: 12000')
        [void]$builder.AppendLine('proxy-groups:')
        [void]$builder.AppendLine('  - name: ' + (ConvertTo-YamlString $GroupName))
        [void]$builder.AppendLine('    type: load-balance')
        [void]$builder.AppendLine('    strategy: round-robin')
        [void]$builder.AppendLine('    url: "https://www.cloudflare.com/cdn-cgi/trace"')
        [void]$builder.AppendLine('    interval: 300')
        [void]$builder.AppendLine('    timeout: 12000')
        [void]$builder.AppendLine('    lazy: false')
        [void]$builder.AppendLine('    use:')
        [void]$builder.AppendLine('      - custom-subscription')
        [void]$builder.AppendLine('rules:')
        [void]$builder.AppendLine('  - MATCH,' + $GroupName)
        return $builder.ToString()
    } else {
        [void]$builder.AppendLine('mixed-port: 7890')
        [void]$builder.AppendLine('allow-lan: true')
        [void]$builder.AppendLine('log-level: warning')
    }
    [void]$builder.AppendLine('mode: rule')
    [void]$builder.AppendLine('ipv6: false')
    [void]$builder.AppendLine('proxies:')
    foreach ($route in $Routes) { Append-ProxyYaml -Builder $builder -Route $route }
    [void]$builder.AppendLine('proxy-groups:')
    [void]$builder.AppendLine('  - name: ' + (ConvertTo-YamlString $GroupName))
    [void]$builder.AppendLine('    type: load-balance')
    [void]$builder.AppendLine('    strategy: round-robin')
    [void]$builder.AppendLine('    url: "https://www.cloudflare.com/cdn-cgi/trace"')
    [void]$builder.AppendLine('    interval: 300')
    [void]$builder.AppendLine('    timeout: 12000')
    [void]$builder.AppendLine('    lazy: false')
    [void]$builder.AppendLine('    proxies:')
    foreach ($route in $Routes) { [void]$builder.AppendLine('      - ' + (ConvertTo-YamlString ([string]$route.name))) }
    [void]$builder.AppendLine('rules:')
    [void]$builder.AppendLine('  - MATCH,' + $GroupName)
    return $builder.ToString()
}

function Get-SelectedCandidates {
    if ($SelectionFile) {
        if (-not (Test-Path -LiteralPath $SelectionFile -PathType Leaf)) {
            throw 'pool build selection file is unavailable'
        }
        try {
            $document = Get-Content -LiteralPath $SelectionFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw 'pool build selection file is invalid'
        }
        return @($document.items | Where-Object {
            $_.selected -and $_.verification -and $_.verification.success
        })
    }
    $catalog = Invoke-RestMethod -UseBasicParsing -Uri ($BackendBase.TrimEnd('/') + '/api/catalog?source=all&page=1&page_size=10') -TimeoutSec 70
    return @($catalog.selection.items | Where-Object {
        $_.selected -and $_.verification -and $_.verification.success -and $_.verification.country_matched
    })
}

function Get-VlessTemplates {
    if (-not (Test-Path -LiteralPath $MainProviderFile)) {
        throw 'main provider cache is unavailable'
    }
    $raw = (Get-Content -LiteralPath $MainProviderFile -Raw).Trim()
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
    } catch {
        throw 'main provider cache is not a valid V2Ray subscription'
    }
    $templates = @($decoded -split "`r?`n" | Where-Object { $_ -match '^vless://' })
    if ($templates.Count -lt 1) {
        throw 'main provider has no VLESS template'
    }
    return $templates
}

function Stop-CustomTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
    }
}

function Ensure-CustomTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { return }
    $arguments = '-d "{0}" -f "{1}"' -f $Root, $ConfigFile
    $action = New-ScheduledTaskAction -Execute $MihomoExecutable -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description ('ProxyTunnel pool ' + $PoolName) | Out-Null
}

function Set-CustomPortExposure {
    param([bool]$Enabled)
    $ruleName = 'ProxyTunnel Custom Pool ' + [string]$ProxyPort + ' LAN'
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($Enabled) {
        if (-not $rule) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ProxyPort -RemoteAddress $AllowedCIDR -Profile Any | Out-Null
        } else {
            Enable-NetFirewallRule -DisplayName $ruleName | Out-Null
        }
    } elseif ($rule) {
        Disable-NetFirewallRule -DisplayName $ruleName | Out-Null
    }
}

function Restart-CustomTask {
    Ensure-CustomTask
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "scheduled task $TaskName is not installed"
    }
    Stop-CustomTask
    Start-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds(15)
    $secret = (Get-Content -LiteralPath $SecretFile -Raw).Trim()
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $ControllerPort + '/version') -Headers @{ Authorization = 'Bearer ' + $secret } -TimeoutSec 2
            return
        } catch {
            Start-Sleep -Milliseconds 350
        }
    }
    throw 'custom pool controller did not become ready'
}

function Convert-RoutesToV2RayContent {
    param([object[]]$Routes)
    $rawURIs = (($Routes | ForEach-Object { [string]$_.uri }) -join "`n") + "`n"
    return [pscustomobject]@{
        raw = $rawURIs
        encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rawURIs))
    }
}

function Set-CustomRuntime {
    param([object[]]$Routes, [string]$Secret)
    $subscription = Convert-RoutesToV2RayContent -Routes $Routes
    Write-UTF8NoBom -Path $RuntimeProviderFile -Content $subscription.encoded
    $runtimeConfig = Build-ClashConfig -Routes $Routes -Secret $Secret -Runtime $true -RuntimeProxyPort $ProxyPort -RuntimeControllerPort $ControllerPort
    $nextConfig = $ConfigFile + '.next'
    Write-UTF8NoBom -Path $nextConfig -Content $runtimeConfig
    $validationOutput = & $MihomoExecutable -t -d $Root -f $nextConfig 2>&1
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $nextConfig -Force -ErrorAction SilentlyContinue
        throw ('mihomo rejected custom pool config: ' + (($validationOutput | Out-String).Trim()))
    }
    Move-Item -LiteralPath $nextConfig -Destination $ConfigFile -Force
    Restart-CustomTask
    return $subscription
}

function Stop-IsolatedBuildRuntime {
    $task = Get-ScheduledTask -TaskName $BuildTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $BuildTaskName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        Unregister-ScheduledTask -TaskName $BuildTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Start-IsolatedBuildRuntime {
    param([object[]]$Routes, [string]$Secret)
    Stop-IsolatedBuildRuntime
    if (-not (Test-Path -LiteralPath (Join-Path $BuildRoot 'subscriptions'))) {
        New-Item -ItemType Directory -Path (Join-Path $BuildRoot 'subscriptions') -Force | Out-Null
    }
    Write-UTF8NoBom -Path $BuildSecretFile -Content $Secret
    $subscription = Convert-RoutesToV2RayContent -Routes $Routes
    Write-UTF8NoBom -Path $BuildRuntimeProviderFile -Content $subscription.encoded
    $runtimeConfig = Build-ClashConfig -Routes $Routes -Secret $Secret -Runtime $true -RuntimeProxyPort $BuildProxyPort -RuntimeControllerPort $BuildControllerPort
    Write-UTF8NoBom -Path $BuildConfigFile -Content $runtimeConfig
    $validationOutput = & $MihomoExecutable -t -d $BuildRoot -f $BuildConfigFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('mihomo rejected isolated build config: ' + (($validationOutput | Out-String).Trim()))
    }
    $arguments = '-d "{0}" -f "{1}"' -f $BuildRoot, $BuildConfigFile
    $action = New-ScheduledTaskAction -Execute $MihomoExecutable -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $BuildTaskName -Action $action -Principal $principal -Settings $settings -Description ('Temporary isolated build for ' + $PoolName) | Out-Null
    Start-ScheduledTask -TaskName $BuildTaskName
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $BuildControllerPort + '/version') -Headers @{ Authorization = 'Bearer ' + $Secret } -TimeoutSec 2
            return $subscription
        } catch {
            Start-Sleep -Milliseconds 350
        }
    }
    throw 'isolated build controller did not become ready'
}

function Wait-CustomRoutesLoaded {
    param([object[]]$Routes, [string]$Secret, [int]$TimeoutSeconds = 15, [int]$RuntimeControllerPort = $ControllerPort)
    $expectedNames = @($Routes | ForEach-Object { [string]$_.name })
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLoaded = 0
    while ((Get-Date) -lt $deadline) {
        try {
            $proxyMap = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $RuntimeControllerPort + '/proxies') -Headers @{ Authorization = 'Bearer ' + $Secret } -TimeoutSec 3
            $loadedNames = @($proxyMap.proxies.PSObject.Properties.Name)
            $lastLoaded = @($expectedNames | Where-Object { $loadedNames -contains $_ }).Count
            if ($lastLoaded -eq $expectedNames.Count) { return }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw ('custom provider loaded {0}/{1} expected routes' -f $lastLoaded, $expectedNames.Count)
}

function Get-FileSnapshot {
    param([string[]]$Paths)
    $snapshot = @{}
    foreach ($path in $Paths) {
        $snapshot[$path] = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllBytes($path) } else { $null }
    }
    return $snapshot
}

function Restore-FileSnapshot {
    param([hashtable]$Snapshot)
    foreach ($path in $Snapshot.Keys) {
        if ($null -eq $Snapshot[$path]) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            continue
        }
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($path, [byte[]]$Snapshot[$path])
    }
}

function Test-CustomRoutes {
    param(
        [object[]]$Routes,
        [string]$Secret,
        [int]$TimeoutMs = 12000,
        [int]$Concurrency = 8,
        [int]$RuntimeControllerPort = $ControllerPort,
        [scriptblock]$OnProgress = $null,
        [scriptblock]$CancelCheck = $null
    )
    if ($Routes.Count -eq 0) { return @() }
    $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, [Math]::Min(12, $Concurrency)))
    $runspacePool.Open()
    $work = @()
    $script = @'
param($ControllerPort, $Secret, $Name, $TimeoutMs)
$ErrorActionPreference = 'Stop'
$uri = 'http://127.0.0.1:' + $ControllerPort + '/proxies/' + [uri]::EscapeDataString($Name) + '/delay?url=' + [uri]::EscapeDataString('https://www.cloudflare.com/cdn-cgi/trace') + '&timeout=' + $TimeoutMs
try {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timeoutSeconds = [Math]::Max(5, [int][Math]::Ceiling(($TimeoutMs + 3000) / 1000.0))
    $response = Invoke-RestMethod -UseBasicParsing -Uri $uri -Headers @{ Authorization = 'Bearer ' + $Secret } -TimeoutSec $timeoutSeconds
    [pscustomobject]@{ name = $Name; success = ([int]$response.delay -gt 0); delay_ms = [int]$response.delay; elapsed_ms = [int]$watch.ElapsedMilliseconds; error = '' }
} catch {
    $statusCode = 0
    try { if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode } } catch {}
    [pscustomobject]@{ name = $Name; success = $false; delay_ms = 0; elapsed_ms = 0; status_code = $statusCode; error = $_.Exception.Message }
}
'@
    try {
        foreach ($route in $Routes) {
            $powershell = [PowerShell]::Create()
            $powershell.RunspacePool = $runspacePool
            [void]$powershell.AddScript($script)
            [void]$powershell.AddArgument($RuntimeControllerPort)
            [void]$powershell.AddArgument($Secret)
            [void]$powershell.AddArgument([string]$route.name)
            [void]$powershell.AddArgument($TimeoutMs)
            $work += [pscustomobject]@{ powershell = $powershell; async = $powershell.BeginInvoke(); name = [string]$route.name }
        }
        $results = @()
        $processed = New-Object 'System.Collections.Generic.HashSet[int]'
        $completed = 0
        $passed = 0
        while ($completed -lt $work.Count) {
            $madeProgress = $false
            for ($index = 0; $index -lt $work.Count; $index++) {
                if ($processed.Contains($index)) { continue }
                $item = $work[$index]
                if (-not $item.async.IsCompleted) { continue }
                $madeProgress = $true
                try {
                    $output = @($item.powershell.EndInvoke($item.async))
                    if ($output.Count -gt 0) { $result = $output[0] }
                    else { $result = [pscustomobject]@{ name = $item.name; success = $false; delay_ms = 0; elapsed_ms = 0; status_code = 0; error = 'probe returned no result' } }
                } catch {
                    $result = [pscustomobject]@{ name = $item.name; success = $false; delay_ms = 0; elapsed_ms = 0; status_code = 0; error = $_.Exception.Message }
                }
                $results += $result
                if ($result.success) { $passed++ }
                $null = $processed.Add($index)
                $completed++
                $item.powershell.Dispose()
                if ($OnProgress) { & $OnProgress $completed $Routes.Count $passed }
                if ($CancelCheck -and (& $CancelCheck)) {
                    throw [System.OperationCanceledException]::new('代理池节点检测已由用户取消')
                }
            }
            if (-not $madeProgress) {
                if ($CancelCheck -and (& $CancelCheck)) {
                    throw [System.OperationCanceledException]::new('代理池节点检测已由用户取消')
                }
                Start-Sleep -Milliseconds 100
            }
        }
        return $results
    } finally {
        foreach ($item in $work) {
            try { if (-not $item.async.IsCompleted) { $item.powershell.Stop() } } catch {}
            try { $item.powershell.Dispose() } catch {}
        }
        $runspacePool.Close()
        $runspacePool.Dispose()
    }
}

function Measure-CustomEgress {
    param([object]$PreviousEgress, [int]$RuntimeProxyPort = $ProxyPort)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $trace = & $curl --proxy ('http://127.0.0.1:' + $RuntimeProxyPort) --ssl-no-revoke --connect-timeout 5 --max-time 12 --silent --show-error 'https://www.cloudflare.com/cdn-cgi/trace' 2>$null
        if ($LASTEXITCODE -ne 0) { throw ('curl exit code ' + $LASTEXITCODE) }
        $values = @{}
        foreach ($line in @($trace)) {
            $separator = $line.IndexOf('=')
            if ($separator -gt 0) { $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1) }
        }
        if (-not $values['loc']) { throw 'trace returned no country' }
        $countryNames = @{ JP='日本'; SG='新加坡'; HK='中国香港'; TW='中国台湾'; KR='韩国'; US='美国'; CA='加拿大'; GB='英国'; DE='德国'; FR='法国'; NL='荷兰'; AU='澳大利亚'; IN='印度' }
        $countryCode = ([string]$values['loc']).ToUpperInvariant()
        $countryName = if ($countryNames.ContainsKey($countryCode)) { $countryNames[$countryCode] } else { $countryCode }
        return [pscustomobject]@{
            reachable = $true; ip = [string]$values['ip']; country_code = $countryCode; country_name = $countryName
            colo = [string]$values['colo']; latency_ms = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds); checked_at = (Get-Date).ToString('o')
        }
    } catch {
        if ($PreviousEgress -and $PreviousEgress.reachable) {
            $PreviousEgress | Add-Member -NotePropertyName last_attempt_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
            $PreviousEgress | Add-Member -NotePropertyName last_error -NotePropertyValue $_.Exception.Message -Force
            return $PreviousEgress
        }
        return [pscustomobject]@{
            reachable = $false; ip = ''; country_code = ''; country_name = ''; colo = ''
            latency_ms = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds); checked_at = (Get-Date).ToString('o'); error = $_.Exception.Message
        }
    } finally {
        $stopwatch.Stop()
    }
}

function Sync-CustomPool {
    $unsupportedOutputs = @($OutputModes | Where-Object { $_ -notin @('port', 'clash', 'v2rayn') })
    if ($unsupportedOutputs.Count -gt 0 -or $OutputModes.Count -eq 0) { throw 'invalid proxy pool output selection' }
    if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'subscriptions'))) { New-Item -ItemType Directory -Path (Join-Path $Root 'subscriptions') -Force | Out-Null }
    $secret = Get-OrCreateSecret
    $selected = @(Get-SelectedCandidates)
    if ($selected.Count -eq 0) {
        Stop-CustomTask
        $empty = [pscustomobject]@{
            version = 3; updated_at = (Get-Date).ToString('o'); proxy_port = $ProxyPort; controller_port = $ControllerPort
            pool_name = $PoolName; source_filter = $SourceFilter; country_filter = $CountryFilter; target_routes = $TargetRoutes
            outputs = $OutputModes; complete = $false; member_count = 0; route_count = 0; members = @(); routes = @(); message = ('代理池为空，端口 {0} 已停止' -f $ProxyPort)
        }
        Write-State -State $empty
        Write-UTF8NoBom -Path $RawURIFile -Content ''
        Write-UTF8NoBom -Path $V2rayNExportFile -Content ''
        Write-UTF8NoBom -Path $RuntimeProviderFile -Content ''
        Write-UTF8NoBom -Path $ClashExportFile -Content "proxies: []`n"
        Write-CustomLog $empty.message
        return $empty
    }

    $snapshotPaths = @($ConfigFile, $StateFile, $ClashExportFile, $V2rayNExportFile, $RuntimeProviderFile, $RawURIFile)
    $snapshot = Get-FileSnapshot -Paths $snapshotPaths
    $taskBefore = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $wasRunning = $taskBefore -and ([string]$taskBefore.State -eq 'Running')
    $previousState = Read-State

    $proxyIPCandidates = @($selected | Where-Object { $_.node.source -eq 'proxyip' })
    $templates = @()
    if ($proxyIPCandidates.Count -gt 0) { $templates = @(Get-VlessTemplates) }

    try {
        $probeRoutes = @()
        $candidateIndex = 0
        $templateCursor = if ($templates.Count -gt 0) { Get-Random -Minimum 0 -Maximum $templates.Count } else { 0 }
        if ($templates.Count -gt 0 -and (Test-Path -LiteralPath $TemplateCursorFile)) {
            try {
                $savedCursor = Get-Content -LiteralPath $TemplateCursorFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $templateCursor = ([int]$savedCursor.next_cursor % $templates.Count + $templates.Count) % $templates.Count
            } catch {}
        } elseif ($templates.Count -gt 0 -and $previousState -and $null -ne $previousState.next_template_cursor) {
            $templateCursor = ([int]$previousState.next_template_cursor % $templates.Count + $templates.Count) % $templates.Count
        }
        $nextTemplateCursor = $templateCursor

        $proxyGroups = @()
        foreach ($countryGroup in @($proxyIPCandidates | Group-Object { ([string]$_.verification.country_code).ToUpperInvariant() })) {
            $countryMembers = @($countryGroup.Group | Sort-Object { [int]$_.verification.latency_ms })
            for ($memberIndex = 0; $memberIndex -lt $countryMembers.Count; $memberIndex++) {
                $firstMember = $countryMembers[$memberIndex]
                $secondMember = if ($countryMembers.Count -gt 1) { $countryMembers[($memberIndex + 1) % $countryMembers.Count] } else { $firstMember }
                $proxyGroups += [pscustomobject]@{ Country = $countryGroup.Name; Members = @($firstMember, $secondMember) }
            }
        }
        $proxyProbeBudget = [Math]::Max($TargetRoutes * 3, $TargetRoutes + 20)
        if ($ProbeRoutesPerProxyIP -gt $proxyProbeBudget) { $proxyProbeBudget = $ProbeRoutesPerProxyIP }
        $perGroupProbeCount = if ($proxyGroups.Count -gt 0) { [int][Math]::Ceiling($proxyProbeBudget / [double]$proxyGroups.Count) } else { 0 }
        foreach ($group in $proxyGroups) {
            $candidateIndex++
            $first = $group.Members | Select-Object -First 1
            $addresses = @($group.Members | ForEach-Object { [string]$_.node.address } | Sort-Object -Unique)
            if ($addresses.Count -eq 1) { $addresses += $addresses[0] }
            $ids = @($group.Members | ForEach-Object { [string]$_.node.id } | Sort-Object -Unique)
            $poolCandidate = [pscustomobject]@{
                node = [pscustomobject]@{ id = ($ids -join ','); address = ($addresses -join ',') }
                verification = [pscustomobject]@{
                    country_code = [string]$first.verification.country_code
                    country_name = [string]$first.verification.country_name
                    latency_ms = [int](($group.Members | ForEach-Object { [int]$_.verification.latency_ms } | Measure-Object -Average).Average)
                }
            }
            $probeCount = [Math]::Min([Math]::Max(1, $perGroupProbeCount), $templates.Count)
            $previousTemplateIndices = @()
            if ($previousState -and $previousState.routes) {
                $previousTemplateIndices = @($previousState.routes | Where-Object {
                    ([string]$_.country_code).ToUpperInvariant() -eq ([string]$first.verification.country_code).ToUpperInvariant() -and
                    $null -ne $_.template_index -and [int]$_.template_index -ge 0 -and [int]$_.template_index -lt $templates.Count
                } | ForEach-Object { [int]$_.template_index } | Select-Object -Unique)
            }
            $rotatingTemplateIndices = @(for ($index = 0; $index -lt $probeCount; $index++) { ($nextTemplateCursor + $index) % $templates.Count })
            $templateIndices = @($previousTemplateIndices + $rotatingTemplateIndices | Select-Object -Unique)
            $routeIndex = 0
            foreach ($templateIndex in $templateIndices) {
                $routeIndex++
                $probeRoutes += Convert-VlessTemplate -Template $templates[$templateIndex] -Candidate $poolCandidate -CandidateIndex $candidateIndex -RouteIndex $routeIndex -TemplateIndex $templateIndex
            }
            $nextTemplateCursor = ($nextTemplateCursor + $probeCount) % $templates.Count
        }
        foreach ($candidate in @($selected | Where-Object { $_.node.source -ne 'proxyip' })) {
            $candidateIndex++
            $probeRoutes += Convert-DirectCandidate -Candidate $candidate -CandidateIndex $candidateIndex
        }
        if ($probeRoutes.Count -eq 0) { throw 'no custom routes were generated' }

        if ($templates.Count -gt 0) {
            Write-UTF8NoBom -Path $TemplateCursorFile -Content ([pscustomobject]@{
                next_cursor = $nextTemplateCursor; template_count = $templates.Count; advanced_at = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress)
        }

        Write-CustomLog ('quality probe started: {0} routes, cursor {1}' -f $probeRoutes.Count, $templateCursor)
        $null = Start-IsolatedBuildRuntime -Routes $probeRoutes -Secret $secret
        Wait-CustomRoutesLoaded -Routes $probeRoutes -Secret $secret -TimeoutSeconds 15 -RuntimeControllerPort $BuildControllerPort
        Start-Sleep -Milliseconds 500
        Update-CustomBuildProgress -QualityPhase 'round1' -Completed 0 -Total $probeRoutes.Count -Passed 0 -Message ('第一轮节点检测 0/{0}；现有代理池继续运行' -f $probeRoutes.Count)
        $roundOneProgress = {
            param($completed, $total, $passed)
            if ($completed -eq $total -or $completed % 5 -eq 0) {
                Update-CustomBuildProgress -QualityPhase 'round1' -Completed $completed -Total $total -Passed $passed -Message ('第一轮节点检测 {0}/{1}，通过 {2}；现有代理池继续运行' -f $completed, $total, $passed)
            }
        }
        $roundOne = @(Test-CustomRoutes -Routes $probeRoutes -Secret $secret -TimeoutMs $ProbeTimeoutMs -Concurrency $ProbeConcurrency -RuntimeControllerPort $BuildControllerPort -OnProgress $roundOneProgress -CancelCheck { Test-CustomBuildCancelled })
        $roundOnePassed = @($roundOne | Where-Object success | Sort-Object delay_ms)
        if ($roundOnePassed.Count -eq 0) {
            $statusSummary = @($roundOne | Group-Object status_code | ForEach-Object { '{0}:{1}' -f $_.Name, $_.Count }) -join ', '
            throw ('quality probe rejected all {0} routes in round one (HTTP status counts: {1})' -f $probeRoutes.Count, $statusSummary)
        }

        $retestLimit = [Math]::Min($roundOnePassed.Count, [Math]::Max($TargetRoutes * 2, $TargetRoutes + 4))
        $retestNames = @($roundOnePassed | Select-Object -First $retestLimit | ForEach-Object { [string]$_.name })
        $retestRoutes = @($probeRoutes | Where-Object { $retestNames -contains [string]$_.name })
        Start-Sleep -Seconds 3
        Update-CustomBuildProgress -QualityPhase 'round2' -Completed 0 -Total $retestRoutes.Count -Passed 0 -Message ('稳定性复检 0/{0}；通过后才会进入节点订阅' -f $retestRoutes.Count)
        $roundTwoProgress = {
            param($completed, $total, $passed)
            if ($completed -eq $total -or $completed % 5 -eq 0) {
                Update-CustomBuildProgress -QualityPhase 'round2' -Completed $completed -Total $total -Passed $passed -Message ('稳定性复检 {0}/{1}，稳定 {2}；通过后才会进入节点订阅' -f $completed, $total, $passed)
            }
        }
        $retestConcurrency = [Math]::Max(1, [Math]::Min(4, [int][Math]::Ceiling($ProbeConcurrency / 2.0)))
        $roundTwo = @(Test-CustomRoutes -Routes $retestRoutes -Secret $secret -TimeoutMs $ProbeTimeoutMs -Concurrency $retestConcurrency -RuntimeControllerPort $BuildControllerPort -OnProgress $roundTwoProgress -CancelCheck { Test-CustomBuildCancelled })
        $roundTwoPassed = @($roundTwo | Where-Object success | Sort-Object delay_ms)
        $stableNames = @($roundTwoPassed | ForEach-Object { [string]$_.name })
        if ($stableNames.Count -eq 0) { throw ('quality probe found {0} first-pass routes but none passed the stability retest' -f $roundOnePassed.Count) }

        $routes = @()
        foreach ($qualityResult in @($roundTwoPassed | Select-Object -First $TargetRoutes)) {
            $route = $probeRoutes | Where-Object { $_.name -eq $qualityResult.name } | Select-Object -First 1
            $route | Add-Member -NotePropertyName quality_delay_ms -NotePropertyValue ([int]$qualityResult.delay_ms) -Force
            $route | Add-Member -NotePropertyName quality_passed -NotePropertyValue $true -Force
            $routes += $route
        }
        $retainedCountries = @($routes | ForEach-Object { [string]$_.country_code } | Select-Object -Unique)
        $rejectedCountries = @($probeRoutes | ForEach-Object { [string]$_.country_code } | Select-Object -Unique | Where-Object { $retainedCountries -notcontains $_ })
        if ($routes.Count -eq 0) { throw 'no route passed both HTTPS quality checks' }
        Update-CustomBuildProgress -QualityPhase 'publishing' -Completed $routes.Count -Total $TargetRoutes -Passed $routes.Count -Message ('已筛出 {0}/{1} 个可切换节点，正在生成端口与订阅' -f $routes.Count, $TargetRoutes)

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        if ($snapshot[$ConfigFile]) {
            $backupDir = Join-Path $Root 'backups'
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            [System.IO.File]::WriteAllBytes((Join-Path $backupDir ('config-' + $timestamp + '.yaml')), [byte[]]$snapshot[$ConfigFile])
        }
        $null = Start-IsolatedBuildRuntime -Routes $routes -Secret $secret
        Wait-CustomRoutesLoaded -Routes $routes -Secret $secret -TimeoutSeconds 15 -RuntimeControllerPort $BuildControllerPort
        $measuredEgress = Measure-CustomEgress -PreviousEgress $(if ($previousState) { $previousState.egress } else { $null }) -RuntimeProxyPort $BuildProxyPort
        $finalSubscription = Convert-RoutesToV2RayContent -Routes $routes
        $exportConfig = Build-ClashConfig -Routes $routes -Secret '' -Runtime $false
        Write-UTF8NoBom -Path $RawURIFile -Content $finalSubscription.raw
        Write-UTF8NoBom -Path $V2rayNExportFile -Content $finalSubscription.encoded
        Write-UTF8NoBom -Path $ClashExportFile -Content $exportConfig

        $members = @($selected | ForEach-Object {
            [pscustomobject]@{
                id = [string]$_.node.id; source = [string]$_.node.source; address = [string]$_.node.address
                country_code = [string]$_.verification.country_code; country_name = [string]$_.verification.country_name
                latency_ms = [int]$_.verification.latency_ms; checked_at = [string]$_.verification.checked_at
            }
        })
        $publicRoutes = @($routes | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.name; source = [string]$_.source; candidate_id = [string]$_.candidate_id
                country_code = [string]$_.country_code; country_name = [string]$_.country_name
                candidate_address = [string]$_.candidate_address; candidate_latency_ms = [int]$_.candidate_latency_ms
                quality_delay_ms = [int]$_.quality_delay_ms; template_index = if ($null -ne $_.template_index) { [int]$_.template_index } else { -1 }
            }
        })
        $state = [pscustomobject]@{
            version = 3; updated_at = (Get-Date).ToString('o'); proxy_port = $ProxyPort; controller_port = $ControllerPort
            pool_name = $PoolName; source_filter = $SourceFilter; country_filter = $CountryFilter; build_id = $BuildID
            target_routes = $TargetRoutes; outputs = $OutputModes; complete = ($publicRoutes.Count -ge $TargetRoutes)
            member_count = $members.Count; route_count = $publicRoutes.Count; members = $members; routes = $publicRoutes
            next_template_cursor = $nextTemplateCursor
            quality = [pscustomobject]@{
                checked_at = (Get-Date).ToString('o'); probed = $probeRoutes.Count; first_passed = $roundOnePassed.Count
                retested = $retestRoutes.Count; stable_passed = $roundTwoPassed.Count; retained = $publicRoutes.Count
                rejected_countries = $rejectedCountries
            }
            message = ('{0} 已构建：{1} 个成员，从 {2} 条候选路由中保留 {3}/{4} 条双重 HTTPS 验证路由' -f $PoolName, $members.Count, $probeRoutes.Count, $publicRoutes.Count, $TargetRoutes)
        }
        $state | Add-Member -NotePropertyName egress -NotePropertyValue $measuredEgress -Force
        if ($OutputModes -contains 'port') {
            $null = Set-CustomRuntime -Routes $routes -Secret $secret
            Set-CustomPortExposure -Enabled $true
        } else {
            Stop-CustomTask
            Set-CustomPortExposure -Enabled $false
        }
        Write-State -State $state
        Write-CustomLog $state.message
        return $state
    } catch {
        $failureMessage = $_.Exception.Message
        Restore-FileSnapshot -Snapshot $snapshot
        try {
            if ($wasRunning -and (Test-Path -LiteralPath $ConfigFile)) { Restart-CustomTask } else { Stop-CustomTask }
        } catch {
            Write-CustomLog ('rollback restart failed: ' + $_.Exception.Message)
        }
        Write-CustomLog ('quality sync failed and rolled back: ' + $failureMessage)
        throw $failureMessage
    } finally {
        try { Stop-IsolatedBuildRuntime } catch { Write-CustomLog ('isolated build cleanup failed: ' + $_.Exception.Message) }
    }
}

function Activate-CustomSnapshot {
    if (-not $SnapshotPath -or -not (Test-Path -LiteralPath $SnapshotPath -PathType Container)) {
        throw '历史代理池节点快照不存在，不能直接复用'
    }
    $snapshotConfig = Join-Path $SnapshotPath 'config.yaml'
    $snapshotState = Join-Path $SnapshotPath 'state.json'
    $snapshotProvider = Join-Path $SnapshotPath 'subscriptions\runtime-provider.txt'
    if (-not (Test-Path -LiteralPath $snapshotConfig -PathType Leaf) -or
        -not (Test-Path -LiteralPath $snapshotState -PathType Leaf) -or
        -not (Test-Path -LiteralPath $snapshotProvider -PathType Leaf)) {
        throw '历史代理池节点快照不完整，不能直接复用'
    }
    $savedState = Get-Content -LiteralPath $snapshotState -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$savedState.route_count -lt 1) { throw '历史代理池节点快照为空' }
    if ([int]$savedState.proxy_port -ne $ProxyPort) { throw '历史代理池端口与当前运行端口不一致' }
    $validationOutput = & $MihomoExecutable -t -d $SnapshotPath -f $snapshotConfig 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('历史代理池配置校验失败：' + (($validationOutput | Out-String).Trim()))
    }

    $relativeFiles = @(
        'config.yaml', 'state.json', 'controller.secret',
        'subscriptions\clash.yaml', 'subscriptions\v2rayn.txt',
        'subscriptions\runtime-provider.txt', 'subscriptions\routes.txt'
    )
    $livePaths = @($relativeFiles | ForEach-Object { Join-Path $Root $_ })
    $rollback = Get-FileSnapshot -Paths $livePaths
    $taskBefore = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $wasRunning = $taskBefore -and ([string]$taskBefore.State -eq 'Running')
    try {
        Stop-CustomTask
        foreach ($relative in $relativeFiles) {
            $source = Join-Path $SnapshotPath $relative
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $destination = Join-Path $Root $relative
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        if (@($savedState.outputs) -contains 'port') {
            Restart-CustomTask
            Set-CustomPortExposure -Enabled $true
        } else {
            Set-CustomPortExposure -Enabled $false
        }
        $status = Get-CustomStatus
        $status | Add-Member -NotePropertyName message -NotePropertyValue ('已直接启用“{0}”保存的 {1} 个节点；未重新检测' -f [string]$savedState.pool_name, [int]$savedState.route_count) -Force
        Write-CustomLog $status.message
        return $status
    } catch {
        $failureMessage = $_.Exception.Message
        Restore-FileSnapshot -Snapshot $rollback
        try {
            if ($wasRunning -and (Test-Path -LiteralPath $ConfigFile)) { Restart-CustomTask } else { Stop-CustomTask }
        } catch {
            Write-CustomLog ('snapshot activation rollback restart failed: ' + $_.Exception.Message)
        }
        throw $failureMessage
    }
}

function Get-CustomStatus {
    $state = Read-State
    if (-not $state) {
        $state = [pscustomobject]@{ updated_at = $null; proxy_port = $ProxyPort; controller_port = $ControllerPort; pool_name = $PoolName; target_routes = $TargetRoutes; outputs = @(); complete = $false; member_count = 0; route_count = 0; members = @(); routes = @() }
    }
    $taskConfigured = Test-Path -LiteralPath $ConfigFile
    $controllerReachable = $false
    $proxyMap = $null
    if ((Test-Path -LiteralPath $SecretFile) -and $state.member_count -gt 0) {
        try {
            $secret = (Get-Content -LiteralPath $SecretFile -Raw).Trim()
            $headers = @{ Authorization = 'Bearer ' + $secret }
            $proxyMap = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $ControllerPort + '/proxies') -Headers $headers -TimeoutSec 2
            $controllerReachable = $true
        } catch {
            $controllerReachable = $false
        }
    }
    $taskState = if ($controllerReachable) { 'Running' } elseif ($state.member_count -gt 0) { 'Unavailable' } elseif ($taskConfigured) { 'Ready' } else { 'NotInstalled' }

    $egress = $state.egress
    if (-not $egress) {
        $egress = [pscustomobject]@{ reachable = $false; ip = ''; country_code = ''; country_name = ''; colo = ''; latency_ms = 0; checked_at = $null }
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
                $recentPositive = @($history | Select-Object -Last 3 | Where-Object { [int]$_.delay -gt 0 } | Select-Object -Last 1)
                if ($recentPositive.Count -gt 0) {
                    $delay = [int]$recentPositive[0].delay
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
        $groupCode = $_.Name
        $first = $_.Group | Select-Object -First 1
        [pscustomobject]@{ code = $groupCode; name = [string]$first.country_name; members = $_.Count; routes = @($routeStatuses | Where-Object { $_.country_code -eq $groupCode }).Count }
    })
    $total = @($routeStatuses).Count
    $availability = if ($total -gt 0) { [Math]::Round(($alive * 100.0) / $total, 1) } else { 0.0 }
    return [pscustomobject]@{
        configured = $taskConfigured; running = $controllerReachable; task_state = $taskState
        proxy_port = [int]$state.proxy_port; controller_port = [int]$state.controller_port
        updated_at = $state.updated_at; build_id = [string]$state.build_id; member_count = [int]$state.member_count; route_count = $total; node_count = $total
        alive = $alive; dead = $total - $alive; availability = $availability
        members = @($state.members); routes = $routeStatuses; countries = $countries
        pool_name = $state.pool_name; source_filter = $state.source_filter; country_filter = $state.country_filter
        target_routes = if ($null -ne $state.target_routes) { [int]$state.target_routes } else { $total }
        outputs = @($state.outputs | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ }); complete = [bool]$state.complete
        egress = $egress; quality = $state.quality
        exports = [pscustomobject]@{
            clash = if (@($state.outputs | Where-Object { $_ }).Count -eq 0 -or @($state.outputs) -contains 'clash') { '/subscriptions/custom/clash' } else { $null }
            v2rayn = if (@($state.outputs | Where-Object { $_ }).Count -eq 0 -or @($state.outputs) -contains 'v2rayn') { '/subscriptions/custom/v2rayn' } else { $null }
        }
    }
}

try {
    $result = switch ($Action) {
        'Sync' { Sync-CustomPool }
        'Activate' { Activate-CustomSnapshot }
        'Restart' { Restart-CustomTask; Get-CustomStatus }
        'Stop' { Stop-CustomTask; Get-CustomStatus }
        default { Get-CustomStatus }
    }
    [pscustomobject]@{ success = $true; action = $Action.ToLowerInvariant(); data = $result; message = if ($result.message) { [string]$result.message } elseif ($Action -eq 'Restart') { '自选代理池已重启' } elseif ($Action -eq 'Stop') { '自选代理池已停止' } else { '自选代理池状态已读取' } } | ConvertTo-Json -Depth 30 -Compress
} catch {
    Write-CustomLog ('action failed: ' + $_.Exception.Message)
    [pscustomobject]@{ success = $false; action = $Action.ToLowerInvariant(); message = $_.Exception.Message } | ConvertTo-Json -Depth 10 -Compress
    exit 1
}
