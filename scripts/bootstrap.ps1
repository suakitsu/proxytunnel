[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cloudflareRoot = Join-Path $projectRoot 'cloudflare'

foreach ($command in @('git', 'go', 'node', 'npm')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $command"
    }
}

git -C $projectRoot submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize Git submodules.' }

Push-Location $projectRoot
try {
    go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
} finally {
    Pop-Location
}

Push-Location $cloudflareRoot
try {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    npm run cf:dry-run
    if ($LASTEXITCODE -ne 0) { throw 'Wrangler dry-run failed.' }
} finally {
    Pop-Location
}

Write-Host 'ProxyTunnel development environment is ready.' -ForegroundColor Green
