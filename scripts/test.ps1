[CmdletBinding()]
param(
    [switch]$IncludeCloudflare
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cloudflareRoot = Join-Path $projectRoot 'cloudflare'

Push-Location $projectRoot
try {
    $goFiles = @(
        '.\cmd\proxytunnel\main.go',
        '.\cmd\proxytunnel\catalog.go',
        '.\cmd\proxytunnel\main_test.go',
        '.\cmd\proxytunnel\catalog_test.go'
    )
    $formatDiff = @(& gofmt -d @goFiles)
    if ($LASTEXITCODE -ne 0) { throw 'gofmt validation failed.' }
    if ($formatDiff.Count -gt 0) {
        $formatDiff | Write-Output
        throw 'Go files are not formatted. Run gofmt before committing.'
    }
    go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go vet failed.' }

    $parseErrors = @()
    Get-ChildItem @('.\scripts\*.ps1', '.\scripts\windows\*.ps1') | ForEach-Object {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        $parseErrors += $errors
    }
    if ($parseErrors.Count -gt 0) {
        $parseErrors | ForEach-Object { Write-Error $_.Message }
        throw 'PowerShell syntax validation failed.'
    }

    Push-Location $cloudflareRoot
    try {
        npm run build:worker
        if ($LASTEXITCODE -ne 0) { throw 'Worker security patch generation failed.' }
        node --check .\worker\admin-ui.js
        if ($LASTEXITCODE -ne 0) { throw 'Worker admin UI syntax validation failed.' }
        node --check .\worker\generated\edgetunnel.js
        if ($LASTEXITCODE -ne 0) { throw 'Generated Worker syntax validation failed.' }

        if ($IncludeCloudflare) {
            npm run cf:dry-run
            if ($LASTEXITCODE -ne 0) { throw 'Wrangler dry-run failed.' }
        }
    } finally {
        Pop-Location
    }
} finally {
    Pop-Location
}

Write-Host 'ProxyTunnel validation passed.' -ForegroundColor Green
