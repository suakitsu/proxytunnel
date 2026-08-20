param(
    [Parameter(Mandatory = $true)][string]$JobID,
    [Parameter(Mandatory = $true)][string]$SpecBase64,
    [string]$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')),
    [string]$BackendBase = 'http://127.0.0.1:9191',
    [string]$StateFile = (Join-Path $ProjectRoot 'var\state\pool-build.json'),
    [string]$SelectionFile = (Join-Path $ProjectRoot 'var\state\pool-build-selection.json'),
    [string]$RotationFile = (Join-Path $ProjectRoot 'var\state\pool-build-rotation.json'),
    [string]$CancelFile = (Join-Path $ProjectRoot 'var\state\pool-build.cancel'),
    [string]$ManagerScript = (Join-Path $ProjectRoot 'scripts\windows\custom-pool-manager.ps1'),
    [string]$CustomPoolRoot = (Join-Path $ProjectRoot 'var\custom-pool'),
    [string]$CustomPoolTaskName = 'ProxyTunnel-Custom-Pool',
    [int]$ProxyPort = 7891,
    [int]$ControllerPort = 19092,
    [string]$LogFile = (Join-Path $ProjectRoot 'var\logs\pool-build-worker.log')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$powerShellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$spec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SpecBase64)) | ConvertFrom-Json

function Write-WorkerLog {
    param([string]$Message)
    $parent = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $JobID, $Message)
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.next-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-Job {
    if (-not (Test-Path -LiteralPath $StateFile)) { throw 'pool build state file is unavailable' }
    return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Update-Job {
    param([scriptblock]$Change)
    $job = Read-Job
    if ([string]$job.id -ne $JobID) { throw 'pool build job has been replaced' }
    & $Change $job
    $now = (Get-Date).ToString('o')
    $job | Add-Member -NotePropertyName heartbeat_at -NotePropertyValue $now -Force
    $job | Add-Member -NotePropertyName worker_pid -NotePropertyValue $(if ([string]$job.status -in @('queued','loading','verifying','building','cancelling')) { $PID } else { 0 }) -Force
    $job.updated_at = $now
    Write-JsonAtomic -Path $StateFile -Value $job
    return $job
}

function Test-Cancelled {
    if (-not (Test-Path -LiteralPath $CancelFile)) { return $false }
    try { return (Get-Content -LiteralPath $CancelFile -Raw -Encoding UTF8).Trim() -eq $JobID } catch { return $false }
}

function Finish-Job {
    param([string]$Status, [string]$Message, [string]$Failure = '', [int]$BuiltRoutes = 0, [string[]]$Exports = @())
    Update-Job {
        param($job)
        $job.status = $Status
        $job.phase = $Status
        $job.message = $Message
        $job.error = $Failure
        $job.built_routes = $BuiltRoutes
        $job.exports = @($Exports)
        $job.finished_at = (Get-Date).ToString('o')
        $job.previous_pool_retained = $Status -in @('failed','cancelled','interrupted')
    } | Out-Null
}

function Get-RotationDocument {
    if (Test-Path -LiteralPath $RotationFile) {
        try {
            $document = Get-Content -LiteralPath $RotationFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $document.cursors) { $document | Add-Member -NotePropertyName cursors -NotePropertyValue ([pscustomobject]@{}) -Force }
            return $document
        } catch {}
    }
    return [pscustomobject]@{ updated_at = $null; cursors = [pscustomobject]@{} }
}

function Get-RotationCursor {
    param([object]$Document, [string]$Key)
    $property = $Document.cursors.PSObject.Properties[$Key]
    if ($property) { return [int]$property.Value }
    return 0
}

function Save-RotationCursor {
    param([string]$Key, [int]$Value)
    $document = Get-RotationDocument
    $document.cursors | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    $document.updated_at = (Get-Date).ToString('o')
    Write-JsonAtomic -Path $RotationFile -Value $document
}

function Get-CatalogPage {
    param([int]$Page)
    $source = [uri]::EscapeDataString([string]$spec.source)
    $country = if ($spec.country) { [uri]::EscapeDataString([string]$spec.country) } else { 'all' }
    $uri = $BackendBase.TrimEnd('/') + '/api/catalog?source=' + $source + '&country=' + $country + '&status=all&page=' + $Page + '&page_size=100'
    return Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 75
}

function Get-CandidateWindow {
    $firstPage = Get-CatalogPage -Page 1
    $total = [int]$firstPage.total
    if ($total -lt 1) { throw '上游候选中没有符合当前来源和国家条件的节点' }
    # A single background job owns the cursor walk. Users should not need to click
    # repeatedly just because the first small window contains no healthy exits.
    $attemptLimit = [Math]::Min(200, $total)
    $key = ([string]$spec.source).ToLowerInvariant() + '|' + ([string]$spec.country).ToUpperInvariant()
    $rotation = Get-RotationDocument
    $start = (Get-RotationCursor -Document $rotation -Key $key) % $total
    if ($start -lt 0) { $start = 0 }
    $pages = @{ 1 = $firstPage }
    $nodes = @()
    for ($offset = 0; $offset -lt $attemptLimit; $offset++) {
        $index = ($start + $offset) % $total
        $page = [int][Math]::Floor($index / 100) + 1
        $within = $index % 100
        if (-not $pages.ContainsKey($page)) { $pages[$page] = Get-CatalogPage -Page $page }
        $items = @($pages[$page].items)
        if ($within -lt $items.Count) { $nodes += $items[$within] }
    }
    return [pscustomobject]@{ nodes = $nodes; total = $total; start = $start; key = $key; attempt_limit = $nodes.Count }
}

function Invoke-VerificationBatch {
    param([object[]]$Nodes)
    $payload = [pscustomobject]@{
        action = 'verify_batch'
        select_verified = $false
        candidates = @($Nodes | ForEach-Object { [pscustomobject]@{ source = [string]$_.source; id = [string]$_.id } })
    }
    return Invoke-RestMethod -UseBasicParsing -Uri ($BackendBase.TrimEnd('/') + '/api/catalog/action') -Method Post -ContentType 'application/json' -Headers @{ 'X-ProxyTunnel-Action' = 'confirmed' } -Body ($payload | ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 135
}

try {
    Write-WorkerLog ('started: source={0}; country={1}; target={2}; outputs={3}' -f $spec.source, $spec.country, $spec.target_routes, (@($spec.outputs) -join ','))
    Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
    Update-Job {
        param($job)
        $job.status = 'loading'; $job.phase = 'loading'; $job.started_at = (Get-Date).ToString('o')
        $job.message = '正在读取 Cloudflare 上游候选并计算持久轮转窗口'
    } | Out-Null

    $window = Get-CandidateWindow
    $desiredMembers = if ([string]$spec.source -in @('proxyip','all')) {
        [Math]::Min(8, [Math]::Max(2, [int][Math]::Ceiling(([int]$spec.target_routes) / 20.0)))
    } else {
        [Math]::Min([int]$spec.target_routes, $window.nodes.Count)
    }
    Update-Job {
        param($job)
        $job.status = 'verifying'; $job.phase = 'verifying'; $job.candidate_total = $window.total
        $job.window_start = $window.start; $job.attempt_limit = $window.attempt_limit; $job.desired_members = $desiredMembers
        $job.message = '正在后台验证候选；页面可以自由切换或刷新'
    } | Out-Null

    $selected = @()
    $attempted = 0
    $verified = 0
    $matched = 0
    for ($offset = 0; $offset -lt $window.nodes.Count -and $selected.Count -lt $desiredMembers; $offset += 4) {
        if (Test-Cancelled) {
            Save-RotationCursor -Key $window.key -Value (($window.start + $attempted) % $window.total)
            Finish-Job -Status 'cancelled' -Message '任务已取消，现有代理池未改变'
            Write-WorkerLog 'cancelled during candidate verification'
            exit 0
        }
        $end = [Math]::Min($offset + 3, $window.nodes.Count - 1)
        $batch = @($window.nodes[$offset..$end])
        $result = Invoke-VerificationBatch -Nodes $batch
        $batchResults = @($result.results)
        $attempted += $batchResults.Count
        foreach ($entry in $batchResults) {
            if (-not $entry.verification.success) { continue }
            $verified++
            $countryMatches = -not $spec.country -or ([string]$entry.verification.country_code).ToUpperInvariant() -eq ([string]$spec.country).ToUpperInvariant()
            if (-not $countryMatches) { continue }
            $matched++
            if ($selected.Count -lt $desiredMembers) {
                $selected += [pscustomobject]@{ node = $entry.node; selected = $true; verification = $entry.verification }
            }
        }
        $nextCursor = ($window.start + $attempted) % $window.total
        Update-Job {
            param($job)
            $job.attempted = $attempted; $job.verified = $verified; $job.country_matched = $matched
            $job.selected_members = $selected.Count; $job.next_cursor = $nextCursor
            $job.message = ('已验证 {0}/{1} 个上游出口，获得 {2}/{3} 个节点生成源' -f $attempted, $window.attempt_limit, $selected.Count, $desiredMembers)
        } | Out-Null
    }
    $nextCursor = ($window.start + $attempted) % $window.total
    Save-RotationCursor -Key $window.key -Value $nextCursor
    if ($selected.Count -lt 1) { throw '本轮没有找到符合条件的可用候选；游标已前移，下次会从新位置继续' }

    $selection = [pscustomobject]@{ version = 1; updated_at = (Get-Date).ToString('o'); spec = $spec; items = @($selected) }
    Write-JsonAtomic -Path $SelectionFile -Value $selection
    Update-Job {
        param($job)
        $job.status = 'building'; $job.phase = 'building'
        $job.message = '上游出口已验收，正在生成并检测可在 v2rayN / Clash 中切换的节点；旧代理池保持运行'
        $job | Add-Member -NotePropertyName quality_phase -NotePropertyValue 'preparing' -Force
        $job | Add-Member -NotePropertyName quality_completed -NotePropertyValue 0 -Force
        $job | Add-Member -NotePropertyName quality_total -NotePropertyValue 0 -Force
        $job | Add-Member -NotePropertyName quality_passed -NotePropertyValue 0 -Force
        $job | Add-Member -NotePropertyName build_attempt -NotePropertyValue 1 -Force
    } | Out-Null

    $managerResult = $null
    $built = 0
    $maxBuildAttempts = 3
    for ($buildAttempt = 1; $buildAttempt -le $maxBuildAttempts; $buildAttempt++) {
        Update-Job {
            param($job)
            $job.build_attempt = $buildAttempt
            $job.message = if ($buildAttempt -eq 1) { '正在生成并检测可切换节点' } else { '当前节点数不足目标，正在自动补充并复检' }
        } | Out-Null
        $managerArguments = @(
            '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ManagerScript,
            '-Action','Sync','-BackendBase',$BackendBase,'-Root',$CustomPoolRoot,'-TaskName',$CustomPoolTaskName,
            '-ProxyPort',[string]$ProxyPort,'-ControllerPort',[string]$ControllerPort,'-SelectionFile',$SelectionFile,
            '-TargetRoutes',[string]([int]$spec.target_routes),'-OutputsCsv',(@($spec.outputs) -join ','),'-PoolName',([string]$spec.name),
            '-SourceFilter',([string]$spec.source),'-BuildID',$JobID,'-ProgressFile',$StateFile,'-CancelFile',$CancelFile,
            '-ProbeConcurrency','4'
        )
        if ($spec.country) { $managerArguments += @('-CountryFilter', [string]$spec.country) }
        $managerOutput = & $powerShellExecutable @managerArguments 2>&1
        $managerResult = $null
        foreach ($line in @($managerOutput | Select-Object -Last 20)) {
            try {
                $candidate = ([string]$line).Trim() | ConvertFrom-Json
                if ($null -ne $candidate.success) { $managerResult = $candidate }
            } catch {}
        }
        if ($LASTEXITCODE -ne 0 -or -not $managerResult -or -not $managerResult.success) {
            if (Test-Cancelled) {
                Finish-Job -Status 'cancelled' -Message '节点生成已取消，取消前的可用代理池不受影响'
                Write-WorkerLog 'cancelled during node quality checks'
                exit 0
            }
            $message = if ($managerResult -and $managerResult.message) { [string]$managerResult.message } else { ($managerOutput | Out-String).Trim() }
            throw $message
        }
        $built = [int]$managerResult.data.route_count
        Update-Job {
            param($job)
            $job.built_routes = $built
            $job.message = ('已生成 {0}/{1} 个可切换节点' -f $built, [int]$spec.target_routes)
        } | Out-Null
        if ($built -ge [int]$spec.target_routes) { break }
    }
    $status = if ($built -ge [int]$spec.target_routes) { 'ready' } else { 'partial' }
    $message = if ($status -eq 'ready') { '已生成 {0} 个可在 v2rayN / Clash 中逐个切换的节点' -f $built } else { '经过 {0} 轮自动补充，已生成 {1}/{2} 个可切换节点；未用失效节点凑数' -f $maxBuildAttempts, $built, [int]$spec.target_routes }
    Finish-Job -Status $status -Message $message -BuiltRoutes $built -Exports @($managerResult.data.outputs)
    Update-Job { param($job) $job.proxy_port = [int]$managerResult.data.proxy_port; $job.previous_pool_retained = $false } | Out-Null
    Write-WorkerLog ('completed: status={0}; selectable_nodes={1}/{2}' -f $status, $built, [int]$spec.target_routes)
} catch {
    $message = $_.Exception.Message
    try { Finish-Job -Status 'failed' -Message '代理池构建失败，上一版已保留' -Failure $message } catch {}
    Write-WorkerLog ('failed: ' + $message)
    exit 1
} finally {
    try { if ((Get-Content -LiteralPath $CancelFile -Raw -ErrorAction SilentlyContinue).Trim() -eq $JobID) { Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue } } catch {}
}
