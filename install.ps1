<#
.SYNOPSIS
  Install Performance Widget for the current user: copies it to
  %LOCALAPPDATA%\PerformanceWidget\app, adds a Start Menu shortcut and starts it.

.DESCRIPTION
  No admin rights needed. Run it from a downloaded copy of the repo, or straight from
  GitHub (it then downloads the two files it needs):

    irm https://raw.githubusercontent.com/Krool/PerformanceWidget/main/install.ps1 | iex

  Running it again updates the installed copy and restarts a running widget. Your
  settings are kept.

.PARAMETER Startup
  Also start the widget when you sign in to Windows. You can turn this on or off later
  from the widget's right-click menu (Start with Windows).

.PARAMETER NoLaunch
  Install without starting the widget.
#>
param(
    [switch]$Startup,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$AppName = 'Performance Widget'
$RawBase = 'https://raw.githubusercontent.com/Krool/PerformanceWidget/main'
$Files = @('PerformanceWidget.ps1', 'uninstall.ps1')

if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set.' }
$appDir = Join-Path $env:LOCALAPPDATA 'PerformanceWidget\app'
$script = Join-Path $appDir 'PerformanceWidget.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Close a running widget first, so the new copy is the one that runs.
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'PerformanceWidget\.ps1' -and $_.CommandLine -notmatch '-Snapshot' -and $_.ProcessId -ne $PID })
foreach ($p in $running) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue; Write-Output "Closed the running widget (PID $($p.ProcessId))." }
if ($running) { Start-Sleep -Milliseconds 500 }

New-Item -ItemType Directory -Force -Path $appDir | Out-Null
$here = $PSScriptRoot
if ($here -and (Test-Path -LiteralPath (Join-Path $here 'PerformanceWidget.ps1'))) {
    foreach ($f in $Files) { Copy-Item -LiteralPath (Join-Path $here $f) -Destination (Join-Path $appDir $f) -Force }
    Write-Output "Copied to $appDir"
} else {
    # Run through `irm | iex`: there is no folder to copy from, so fetch the files.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($f in $Files) { Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/$f" -OutFile (Join-Path $appDir $f) }
    Write-Output "Downloaded to $appDir"
}
# Files from a zip or a browser download carry a "came from the internet" mark; clear it.
foreach ($f in $Files) { Unblock-File -LiteralPath (Join-Path $appDir $f) -ErrorAction SilentlyContinue }

function New-Shortcut([string]$Path) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $lnk.TargetPath = $ps
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $lnk.WorkingDirectory = $appDir
    $lnk.WindowStyle = 7   # minimized, so the console does not flash in front
    $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\perfmon.exe') + ',0'
    $lnk.Description = 'Per-core CPU, RAM, disk and network meter'
    $lnk.Save()
    Write-Output "Shortcut: $Path"
}

New-Shortcut (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk")
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
# Re-running without -Startup leaves an existing Startup shortcut alone; it may point at an
# older copy, so refresh it.
if ($Startup -or (Test-Path -LiteralPath $startupLnk)) { New-Shortcut $startupLnk }

if (-not $NoLaunch) {
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script`"") -WindowStyle Hidden
    Write-Output "Started. It opens in the bottom-right corner; right-click it for options."
}
Write-Output "Uninstall: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $appDir 'uninstall.ps1')`""
