<#
.SYNOPSIS
  Remove Performance Widget: closes it, deletes its Start Menu and Startup shortcuts and
  the %LOCALAPPDATA%\PerformanceWidget folder.

.PARAMETER KeepSettings
  Keep settings.json (position and options), so a later install picks up where you left off.
#>
param([switch]$KeepSettings)

$ErrorActionPreference = 'Stop'
$AppName = 'Performance Widget'
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set.' }
$dataDir = Join-Path $env:LOCALAPPDATA 'PerformanceWidget'

$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'PerformanceWidget\.ps1' -and $_.CommandLine -notmatch '-Snapshot' -and $_.ProcessId -ne $PID })
foreach ($p in $running) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue; Write-Output "Closed the running widget (PID $($p.ProcessId))." }
if ($running) { Start-Sleep -Milliseconds 500 }

foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"),
                   (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"))) {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Output "Removed $lnk" }
}

# This script may live in the folder it deletes; step out of it first.
Push-Location ([System.IO.Path]::GetTempPath())
try {
    if (Test-Path -LiteralPath $dataDir) {
        if ($KeepSettings) {
            Get-ChildItem -LiteralPath $dataDir | Where-Object { $_.Name -ne 'settings.json' } | Remove-Item -Recurse -Force
            Write-Output "Removed the app; kept $(Join-Path $dataDir 'settings.json')"
        } else {
            Remove-Item -LiteralPath $dataDir -Recurse -Force
            Write-Output "Removed $dataDir"
        }
    }
} finally { Pop-Location }
Write-Output "$AppName is uninstalled."
