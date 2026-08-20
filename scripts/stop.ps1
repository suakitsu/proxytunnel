[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$statePath = Join-Path $projectRoot 'var\run\local-session.json'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host 'No ProxyTunnel launcher session is recorded.' -ForegroundColor Yellow
    exit 0
}

$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
foreach ($entry in @($state.processes) | Sort-Object pid -Descending) {
    $process = Get-Process -Id ([int]$entry.pid) -ErrorAction SilentlyContinue
    if (-not $process) { continue }

    $metadata = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f [int]$entry.pid) -ErrorAction SilentlyContinue
    $expected = [string]$entry.executable
    $matches = $false
    if ($entry.role -eq 'gateway') {
        $matches = $metadata -and $metadata.CommandLine -and $metadata.CommandLine.IndexOf('monitor-ui-gateway.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
    } elseif ($metadata -and $metadata.ExecutablePath) {
        $matches = [IO.Path]::GetFullPath($metadata.ExecutablePath).Equals([IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $matches) {
        Write-Warning "PID $($entry.pid) no longer belongs to the recorded $($entry.role) process; it was not stopped."
        continue
    }
    Stop-Process -Id ([int]$entry.pid) -Force
    Write-Host "Stopped $($entry.role) (PID $($entry.pid))."
}

Remove-Item -LiteralPath $statePath -Force
Write-Host 'ProxyTunnel stopped.' -ForegroundColor Green
