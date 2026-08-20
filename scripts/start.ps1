[CmdletBinding()]
param(
    [ValidateSet('auto', 'existing', 'setup')]
    [string]$CloudflareMode = 'auto',
    [string]$SubscriptionURL = '',
    [string]$CloudflareSiteURL = '',
    [string]$MihomoPath = '',
    [switch]$NoBrowser,
    [switch]$ExitAfterReady
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $projectRoot 'config.local.json'
$executablePath = Join-Path $projectRoot 'dist\proxytunnel.exe'
$runtimeRoot = Join-Path $projectRoot 'var'
$mainPoolRoot = Join-Path $runtimeRoot 'main-pool'
$mainConfigPath = Join-Path $mainPoolRoot 'config.yaml'
$subscriptionSecretPath = Join-Path $runtimeRoot 'secrets\edgetunnel-subscription.url'
$cloudflareSitePath = Join-Path $runtimeRoot 'state\cloudflare-site.url'
$controllerSecretPath = Join-Path $runtimeRoot 'secrets\main-controller.secret'
$sessionStatePath = Join-Path $runtimeRoot 'run\local-session.json'
$gatewayScript = Join-Path $projectRoot 'scripts\windows\monitor-ui-gateway.ps1'
$dashboardUrl = 'http://127.0.0.1:9190/'
$backendUrl = 'http://127.0.0.1:9191/'
$controllerUrl = 'http://127.0.0.1:9090/version'
$deploymentGuide = 'https://www.freedidi.com/23618.html'
$mihomoDownload = 'https://github.com/MetaCubeX/mihomo/releases/latest'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$ownedProcesses = New-Object Collections.Generic.List[object]
$powerShellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

function Write-UTF8File {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function ConvertTo-MD5Hex {
    param([Parameter(Mandatory = $true)][string]$Value)
    $algorithm = [Security.Cryptography.MD5]::Create()
    try {
        $hash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        return -join @($hash | ForEach-Object { $_.ToString('x2') })
    } finally {
        $algorithm.Dispose()
    }
}

function Get-EdgeTunnelToken {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$UUID
    )
    $first = ConvertTo-MD5Hex -Value ($HostName + $UUID)
    return ConvertTo-MD5Hex -Value $first.Substring(7, 20)
}

function ConvertTo-CloudflareOrigin {
    param([Parameter(Mandatory = $true)][string]$Value)
    $parsed = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$parsed) -or -not $parsed.Host) {
        throw 'Enter the full deployed site URL, for example https://example.workers.dev or https://example.com/admin.'
    }
    $loopback = $parsed.IsLoopback -or $parsed.Host -in @('localhost', '127.0.0.1', '::1')
    if ($parsed.Scheme -ne 'https' -and -not ($parsed.Scheme -eq 'http' -and $loopback)) {
        throw 'The deployed CF ProxyTunnel site must use HTTPS.'
    }
    return $parsed.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
}

function Get-CloudflareSubscriptionFromAdmin {
    param(
        [Parameter(Mandatory = $true)][string]$Origin,
        [Parameter(Mandatory = $true)][Security.SecureString]$SecurePassword
    )
    $pointer = [IntPtr]::Zero
    $plainPassword = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw 'ADMIN password cannot be empty.' }

        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $userAgent = 'ProxyTunnel-Launcher/0.1'
        $loginResponse = Invoke-WebRequest -Uri ($Origin + '/login') -Method Post -WebSession $session `
            -UserAgent $userAgent -ContentType 'application/x-www-form-urlencoded; charset=utf-8' `
            -Body ('password=' + [Uri]::EscapeDataString($plainPassword)) -TimeoutSec 30
        try {
            $login = $loginResponse.Content | ConvertFrom-Json
        } catch {
            throw 'The CF ProxyTunnel site rejected the ADMIN password or does not expose the expected login API.'
        }
        if (-not $login.success) { throw 'The CF ProxyTunnel site rejected the ADMIN password.' }

        $configResponse = Invoke-WebRequest -Uri ($Origin + '/admin/config.json') -Method Get -WebSession $session `
            -UserAgent $userAgent -TimeoutSec 30
        try {
            $config = $configResponse.Content | ConvertFrom-Json
        } catch {
            throw 'Login succeeded, but the Worker did not return a valid EdgeTunnel configuration.'
        }
        $uuid = ([string]$config.UUID).Trim()
        $hostName = ([string]$config.HOST).Trim().ToLowerInvariant()
        if ($uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' -or -not $hostName) {
            throw 'The authenticated Worker configuration is missing HOST or UUID.'
        }
        $token = Get-EdgeTunnelToken -HostName $hostName -UUID $uuid.ToLowerInvariant()
        return $Origin + '/sub?target=clash&token=' + [Uri]::EscapeDataString($token)
    } finally {
        $plainPassword = $null
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function ConvertTo-QuotedProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Test-HttpEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$RequiredPattern = ''
    )
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Timeout = 1200
    $request.ReadWriteTimeout = 1200
    $request.AllowAutoRedirect = $false
    $response = $null
    try {
        $response = $request.GetResponse()
    } catch [Net.WebException] {
        $response = $_.Exception.Response
    }
    if ($null -eq $response) { return $false }
    try {
        if (-not $RequiredPattern) { return $true }
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { return $reader.ReadToEnd() -match $RequiredPattern } finally { $reader.Dispose() }
    } finally {
        $response.Dispose()
    }
}

function Wait-HttpEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$RequiredPattern = '',
        [Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-HttpEndpoint -Uri $Uri -RequiredPattern $RequiredPattern) { return }
        if ($Process) {
            $Process.Refresh()
            if ($Process.HasExited) { throw "Service exited before $Uri became ready (exit $($Process.ExitCode))." }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out waiting for $Uri"
}

function Wait-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(300) -and $client.Connected) {
                $client.EndConnect($async)
                return
            }
        } catch {
        } finally {
            $client.Dispose()
        }
        if ($Process) {
            $Process.Refresh()
            if ($Process.HasExited) { throw "Service exited before $HostName`:$Port became ready (exit $($Process.ExitCode))." }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for $HostName`:$Port"
}

function Wait-ProxyPoolReady {
    param(
        [Diagnostics.Process]$BackendProcess,
        [int]$TimeoutSeconds = 120
    )
    Write-Host 'Waiting for Mihomo to import at least one subscription node...' -ForegroundColor Cyan
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastMessage = 'provider is not ready'
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($BackendProcess) {
            $BackendProcess.Refresh()
            if ($BackendProcess.HasExited) { throw "Backend exited while loading the subscription (exit $($BackendProcess.ExitCode))." }
        }
        try {
            $client = New-Object Net.WebClient
            try {
                # Keep JSON parsing independent of the machine's legacy code page.
                $client.Encoding = [Text.Encoding]::UTF8
                $status = ($client.DownloadString('http://127.0.0.1:9191/api/status') | ConvertFrom-Json)
            } finally {
                $client.Dispose()
            }
            if ($status.controller_reachable -and [int]$status.runtime_nodes -gt 0) { return }
            if (-not $status.controller_reachable) {
                $lastMessage = if ($status.controller_error) { [string]$status.controller_error } else { 'Mihomo Controller is not reachable' }
            } else {
                $lastMessage = 'the subscription returned no Mihomo nodes'
            }
        } catch {
            $lastMessage = $_.Exception.Message
        }
        Start-Sleep -Seconds 1
    }
    throw "The proxy pool did not become usable within $TimeoutSeconds seconds: $lastMessage. Check the Clash subscription URL and var\logs\mihomo.stderr.log."
}

function Test-RebuildRequired {
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { return $true }
    $binaryTime = (Get-Item -LiteralPath $executablePath).LastWriteTimeUtc
    $sourceFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $projectRoot 'cmd\proxytunnel') -File -Recurse
        Get-Item -LiteralPath (Join-Path $projectRoot 'go.mod')
    )
    return $null -ne ($sourceFiles | Where-Object { $_.LastWriteTimeUtc -gt $binaryTime } | Select-Object -First 1)
}

function Stop-OwnedProcesses {
    foreach ($entry in @($ownedProcesses | Sort-Object { $_.process.Id } -Descending)) {
        $process = $entry.process
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "Unable to stop $($entry.role) PID $($process.Id): $($_.Exception.Message)"
        }
    }
}

function Start-ManagedProcess {
    param(
        [string]$Role,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$StandardOutput,
        [string]$StandardError
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $projectRoot `
        -WindowStyle Hidden -RedirectStandardOutput $StandardOutput -RedirectStandardError $StandardError -PassThru
    $ownedProcesses.Add([pscustomobject]@{ role = $Role; process = $process; executable = $FilePath })
    return $process
}

function Resolve-MihomoExecutable {
    $configuredPath = $MihomoPath.Trim()
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $localConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        if ($localConfig.mihomo_executable) { $configuredPath = [string]$localConfig.mihomo_executable }
    }
    if (-not $configuredPath) { $configuredPath = 'bin\mihomo.exe' }
    if (-not [IO.Path]::IsPathRooted($configuredPath)) {
        $configuredPath = Join-Path $projectRoot $configuredPath
    }
    return [IO.Path]::GetFullPath($configuredPath)
}

function Get-SubscriptionURL {
    if (Test-Path -LiteralPath $subscriptionSecretPath -PathType Leaf) {
        $saved = (Get-Content -Raw -LiteralPath $subscriptionSecretPath).Trim()
        if ($saved) { return $saved }
    }

    $advancedSubscription = $SubscriptionURL.Trim()
    if ($advancedSubscription) {
        $advancedURI = $null
        if (-not [Uri]::TryCreate($advancedSubscription, [UriKind]::Absolute, [ref]$advancedURI) -or $advancedURI.Scheme -ne 'https' -or -not $advancedURI.Host) {
            throw 'The advanced subscription override must be an absolute HTTPS URL.'
        }
        Write-UTF8File -Path $subscriptionSecretPath -Content ($advancedURI.AbsoluteUri + [Environment]::NewLine)
        return $advancedURI.AbsoluteUri
    }

    $selectedMode = $CloudflareMode
    if ($selectedMode -eq 'auto') {
        Write-Host ''
        Write-Host 'Choose your setup:' -ForegroundColor Cyan
        Write-Host '  1. I already have CF ProxyTunnel (quick connect)'
        Write-Host '  2. I need to deploy CF ProxyTunnel first'
        $answer = (Read-Host 'Enter 1 or 2 [1]').Trim()
        $selectedMode = if ($answer -match '^(2|n|no)$') { 'setup' } else { 'existing' }
    }

    if ($selectedMode -eq 'setup') {
        Write-Host ''
        Write-Host 'Deploy CF ProxyTunnel first, then run START.cmd again.' -ForegroundColor Yellow
        Write-Host "Deployment guide: $deploymentGuide"
        Write-Host 'Advanced option: cloudflare\DEPLOY.cmd (Wrangler)'
        if (-not $NoBrowser) { Start-Process -FilePath $deploymentGuide }
        return ''
    }

    $site = $CloudflareSiteURL.Trim()
    if (-not $site -and (Test-Path -LiteralPath $cloudflareSitePath -PathType Leaf)) {
        $site = (Get-Content -Raw -LiteralPath $cloudflareSitePath).Trim()
    }
    if (-not $site) {
        Write-Host 'The site address is remembered locally and is not a secret.' -ForegroundColor DarkGray
        $site = (Read-Host 'Deployed CF ProxyTunnel site or /admin URL').Trim()
    }
    $origin = ConvertTo-CloudflareOrigin -Value $site
    Write-Host 'Enter the same ADMIN password used during Cloudflare deployment.' -ForegroundColor Cyan
    Write-Host 'The password is used only for this login and is never written to disk.' -ForegroundColor DarkGray
    $securePassword = Read-Host 'ADMIN password' -AsSecureString
    $subscription = Get-CloudflareSubscriptionFromAdmin -Origin $origin -SecurePassword $securePassword
    Write-UTF8File -Path $cloudflareSitePath -Content ($origin + [Environment]::NewLine)
    Write-UTF8File -Path $subscriptionSecretPath -Content ($subscription + [Environment]::NewLine)
    Write-Host 'Cloudflare login succeeded; the Clash subscription was configured automatically.' -ForegroundColor Green
    return $subscription
}

function Ensure-MainPoolConfiguration {
    param([string]$Subscription, [string]$MihomoPath)

    if (-not (Test-Path -LiteralPath $MihomoPath -PathType Leaf)) {
        Write-Host ''
        Write-Host 'Mihomo is required to turn the subscription into a local proxy port.' -ForegroundColor Yellow
        Write-Host "Download: $mihomoDownload"
        Write-Host "Place or rename the executable as: $MihomoPath"
        if (-not $NoBrowser) { Start-Process -FilePath $mihomoDownload }
        return $false
    }

    if (-not (Test-Path -LiteralPath $controllerSecretPath -PathType Leaf) -or
        -not (Get-Content -Raw -LiteralPath $controllerSecretPath -ErrorAction SilentlyContinue).Trim()) {
        $bytes = New-Object byte[] 32
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($bytes) } finally { $random.Dispose() }
        $secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Write-UTF8File -Path $controllerSecretPath -Content ($secret + [Environment]::NewLine)
    } else {
        $secret = (Get-Content -Raw -LiteralPath $controllerSecretPath).Trim()
    }

    $generatedMarker = '# Generated by ProxyTunnel START.cmd'
    if (Test-Path -LiteralPath $mainConfigPath -PathType Leaf) {
        $firstLine = Get-Content -LiteralPath $mainConfigPath -TotalCount 1
        if ($firstLine -ne $generatedMarker) {
            Write-Host 'Existing custom Mihomo config preserved.' -ForegroundColor Yellow
            return $true
        }
    }

    $yamlURL = $Subscription.Replace("'", "''")
    $yamlSecret = $secret.Replace("'", "''")
    $configuration = @"
$generatedMarker
mixed-port: 7890
allow-lan: false
bind-address: '127.0.0.1'
mode: rule
log-level: warning
ipv6: false
tcp-concurrent: true
external-controller: '127.0.0.1:9090'
secret: '$yamlSecret'
profile:
  store-selected: true
  store-fake-ip: false
proxy-providers:
  default:
    type: http
    url: '$yamlURL'
    path: './providers/v2rayn-subscription.yaml'
    interval: 3600
    health-check:
      enable: true
      url: 'http://cp.cloudflare.com/generate_204'
      interval: 300
      timeout: 5000
proxy-groups:
  - name: 'PROXY'
    type: select
    use:
      - default
rules:
  - 'MATCH,PROXY'
"@
    Write-UTF8File -Path $mainConfigPath -Content ($configuration.Trim() + [Environment]::NewLine)
    return $true
}

if (Test-HttpEndpoint -Uri $dashboardUrl -RequiredPattern 'ProxyTunnel') {
    Write-Host 'ProxyTunnel is already running.' -ForegroundColor Green
    Write-Host $dashboardUrl
    if (-not $NoBrowser) { Start-Process -FilePath $dashboardUrl }
    exit 0
}

$subscription = Get-SubscriptionURL
if (-not $subscription) { exit 0 }

$firstRun = -not (Test-Path -LiteralPath $configPath -PathType Leaf)
if ($firstRun) {
    Write-Host ''
    Write-Host 'Creating a safe local configuration and building ProxyTunnel...' -ForegroundColor Cyan
    Write-Host 'No Cloudflare account or online resource will be changed.' -ForegroundColor DarkGray
    & (Join-Path $PSScriptRoot 'setup.ps1') -NonInteractive
} elseif (Test-RebuildRequired) {
    Write-Host 'Source changes detected; rebuilding ProxyTunnel...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'build.ps1')
}
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Build output is missing: $executablePath"
}

$configuration = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$allowedCIDR = if ($configuration.allowed_cidr) { [string]$configuration.allowed_cidr } else { '127.0.0.0/8' }
$listenPrefix = if ($allowedCIDR -eq '127.0.0.0/8') { 'http://127.0.0.1:9190/' } else { 'http://+:9190/' }
$mihomoPath = Resolve-MihomoExecutable
if (-not (Ensure-MainPoolConfiguration -Subscription $subscription -MihomoPath $mihomoPath)) { exit 0 }

$logsRoot = Join-Path $runtimeRoot 'logs'
$runRoot = Join-Path $runtimeRoot 'run'
foreach ($directory in @($logsRoot, $runRoot, (Join-Path $mainPoolRoot 'providers'))) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$startupSucceeded = $false
try {
    $mihomoProcess = $null
    if (-not (Test-HttpEndpoint -Uri $controllerUrl)) {
        $mihomoArguments = @(
            '-d', (ConvertTo-QuotedProcessArgument $mainPoolRoot),
            '-f', (ConvertTo-QuotedProcessArgument $mainConfigPath)
        )
        $mihomoProcess = Start-ManagedProcess -Role 'mihomo' -FilePath $mihomoPath -Arguments $mihomoArguments `
            -StandardOutput (Join-Path $logsRoot 'mihomo.stdout.log') -StandardError (Join-Path $logsRoot 'mihomo.stderr.log')
        Wait-HttpEndpoint -Uri $controllerUrl -Process $mihomoProcess -TimeoutSeconds 45
    }
    Wait-TcpPort -HostName '127.0.0.1' -Port 7890 -Process $mihomoProcess -TimeoutSeconds 45

    $backendProcess = $null
    if (-not (Test-HttpEndpoint -Uri $backendUrl -RequiredPattern 'ProxyTunnel')) {
        $backendProcess = Start-ManagedProcess -Role 'backend' -FilePath $executablePath `
            -Arguments @('-config', (ConvertTo-QuotedProcessArgument $configPath)) `
            -StandardOutput (Join-Path $logsRoot 'backend.stdout.log') -StandardError (Join-Path $logsRoot 'backend.stderr.log')
        Wait-HttpEndpoint -Uri $backendUrl -RequiredPattern 'ProxyTunnel' -Process $backendProcess
    }
    Wait-ProxyPoolReady -BackendProcess $backendProcess

    $gatewayArguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-QuotedProcessArgument $gatewayScript),
        '-ProjectRoot', (ConvertTo-QuotedProcessArgument $projectRoot),
        '-ListenPrefix', (ConvertTo-QuotedProcessArgument $listenPrefix),
        '-AllowedCIDR', (ConvertTo-QuotedProcessArgument $allowedCIDR)
    )
    $gatewayProcess = Start-ManagedProcess -Role 'gateway' -FilePath $powerShellExecutable -Arguments $gatewayArguments `
        -StandardOutput (Join-Path $logsRoot 'gateway.stdout.log') -StandardError (Join-Path $logsRoot 'gateway.stderr.log')
    Wait-HttpEndpoint -Uri $dashboardUrl -RequiredPattern 'ProxyTunnel' -Process $gatewayProcess

    $state = [ordered]@{
        started_at = [DateTime]::Now.ToString('o')
        project_root = $projectRoot
        processes = @($ownedProcesses | ForEach-Object {
            [ordered]@{ role = $_.role; pid = $_.process.Id; executable = $_.executable }
        })
    }
    Write-UTF8File -Path $sessionStatePath -Content (($state | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    $startupSucceeded = $true

    Write-Host ''
    Write-Host 'ProxyTunnel is ready for use.' -ForegroundColor Green
    Write-Host "Dashboard: $dashboardUrl"
    Write-Host 'Local proxy: http://127.0.0.1:7890'
    Write-Host 'Run STOP.cmd to stop the processes started by this launcher.' -ForegroundColor DarkGray
    if (-not $NoBrowser) { Start-Process -FilePath $dashboardUrl }
    if ($ExitAfterReady) {
        Stop-OwnedProcesses
        if (Test-Path -LiteralPath $sessionStatePath) { Remove-Item -LiteralPath $sessionStatePath -Force }
    }
} finally {
    if (-not $startupSucceeded) { Stop-OwnedProcesses }
}
