[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cloudflareRoot = Join-Path $projectRoot 'cloudflare'
$sourceConfig = Join-Path $cloudflareRoot 'wrangler.jsonc'
$productionConfig = Join-Path $cloudflareRoot 'wrangler.production.jsonc'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempDirectory = Join-Path $tempRoot ('proxytunnel-cloudflare-' + [Guid]::NewGuid().ToString('N'))
$secretFile = Join-Path $tempDirectory 'secrets.json'
$cloudflareSitePath = Join-Path $projectRoot 'var\state\cloudflare-site.url'
$secretPointer = [IntPtr]::Zero
$plainSecret = $null
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Invoke-CheckedCommand {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

function Invoke-CheckedCommandWithOutput {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments)
    $captured = [Collections.Generic.List[string]]::new()
    & $FilePath @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $captured.Add($line)
        Write-Host $line
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
    return $captured.ToArray()
}

Write-Host ''
Write-Host 'ProxyTunnel Cloudflare deployment' -ForegroundColor Cyan
Write-Host 'Only one value is required: the EdgeTunnel ADMIN password.'
Write-Host 'Wrangler provisions and binds Workers KV automatically. A custom domain is optional and is not changed here.'
Write-Host ''
Write-Host 'Production impact:' -ForegroundColor Yellow
Write-Host '- creates or updates the Worker named in wrangler.jsonc;'
Write-Host '- creates a KV namespace automatically when the binding does not exist;'
Write-Host '- uploads ADMIN as an encrypted secret;'
Write-Host '- does not delete Workers, KV data, routes, domains, or other Cloudflare resources.'
$confirmation = Read-Host 'Type DEPLOY to continue; anything else exits'
if ($confirmation -cne 'DEPLOY') {
    Write-Host 'No Cloudflare changes were made.' -ForegroundColor Yellow
    exit 0
}

foreach ($command in @('node', 'npm', 'npx')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $command"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $cloudflareRoot 'node_modules\wrangler'))) {
    Push-Location $cloudflareRoot
    try { Invoke-CheckedCommand -FilePath 'npm' -Arguments @('ci') } finally { Pop-Location }
}

$secureSecret = Read-Host 'ADMIN password (12+ characters)' -AsSecureString
try {
    $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
    $plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
    if ([string]::IsNullOrWhiteSpace($plainSecret) -or $plainSecret.Length -lt 12) {
        throw 'ADMIN must contain at least 12 characters.'
    }

    New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
    [IO.File]::WriteAllText($secretFile, ((@{ ADMIN = $plainSecret } | ConvertTo-Json -Compress) + [Environment]::NewLine), $utf8NoBom)
    Copy-Item -LiteralPath $sourceConfig -Destination $productionConfig -Force

    Push-Location $cloudflareRoot
    try {
        Invoke-CheckedCommand -FilePath 'npx' -Arguments @('wrangler', 'deploy', '--dry-run', '--config', $productionConfig, '--secrets-file', $secretFile)
        & npx wrangler whoami --config $productionConfig
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Wrangler login is required; a browser window will open.' -ForegroundColor Yellow
            Invoke-CheckedCommand -FilePath 'npx' -Arguments @('wrangler', 'login')
        }
        $deploymentOutput = @(Invoke-CheckedCommandWithOutput -FilePath 'npx' -Arguments @('wrangler', 'deploy', '--strict', '--config', $productionConfig, '--secrets-file', $secretFile))
    } finally {
        Pop-Location
    }
    Write-Host 'Cloudflare Worker deployed. KV was provisioned automatically if it did not already exist.' -ForegroundColor Green
    $workerURLs = @($deploymentOutput | ForEach-Object {
        $plainLine = [regex]::Replace([string]$_, "`e\[[0-?]*[ -/]*[@-~]", '')
        [regex]::Matches($plainLine, 'https://[A-Za-z0-9.-]+\.workers\.dev') | ForEach-Object { $_.Value.TrimEnd('/') }
    } | Select-Object -Unique)
    if ($workerURLs.Count -gt 0) {
        $stateDirectory = Split-Path -Parent $cloudflareSitePath
        if (-not (Test-Path -LiteralPath $stateDirectory)) { New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null }
        [IO.File]::WriteAllText($cloudflareSitePath, ($workerURLs[-1] + [Environment]::NewLine), $utf8NoBom)
        Write-Host "Saved local connection site: $($workerURLs[-1])" -ForegroundColor Green
        Write-Host 'START.cmd will reuse this address and ask only for ADMIN.' -ForegroundColor DarkGray
    } else {
        Write-Host 'The deployment succeeded, but its public URL was not detected in Wrangler output.' -ForegroundColor Yellow
        Write-Host 'START.cmd will ask for the site address once, then remember it locally.' -ForegroundColor Yellow
    }
} finally {
    $plainSecret = $null
    if ($secretPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
    }
    if (Test-Path -LiteralPath $tempDirectory) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempDirectory)
        if (-not $resolvedTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or $resolvedTemp -eq $tempRoot) {
            throw "Refusing to clean unexpected temporary path: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
