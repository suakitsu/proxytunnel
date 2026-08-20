[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dist = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Push-Location $projectRoot
try {
    go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
    go build -trimpath -o (Join-Path $dist 'proxytunnel.exe') .\cmd\proxytunnel
    if ($LASTEXITCODE -ne 0) { throw 'Go build failed.' }
} finally {
    Pop-Location
}

Write-Host "Built: $(Join-Path $dist 'proxytunnel.exe')" -ForegroundColor Green
