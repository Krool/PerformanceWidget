<#
.SYNOPSIS
  End-to-end checks for PerformanceWidget.ps1, run through its -Snapshot mode.

.DESCRIPTION
  Each case starts the real script in a child PowerShell with a private LOCALAPPDATA, so
  nothing touches your settings or a running widget. The child prints a `state ...` line
  and the hover text, which the cases assert on, and writes a PNG whose size is checked.
  Runs one case at a time; about a minute, since each run samples for three seconds.

  Exit code 0 when every case passes.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'PerformanceWidget.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("perfwidget-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$failures = 0
Add-Type -AssemblyName System.Drawing

function Assert([bool]$Cond, [string]$Name, [string]$Detail = '') {
    if ($Cond) { Write-Output "  ok   $Name" }
    else { Write-Output "  FAIL $Name $Detail"; $script:failures++ }
}

function Invoke-Widget([string]$Case, $Settings = $null, [switch]$ShowAll, [string]$Fail = '') {
    $app = Join-Path $root "$Case-appdata"
    New-Item -ItemType Directory -Force -Path (Join-Path $app 'PerformanceWidget') | Out-Null
    $cfgPath = Join-Path $app 'PerformanceWidget\settings.json'
    if ($null -ne $Settings) { Set-Content -LiteralPath $cfgPath -Value $Settings -Encoding UTF8 }
    $png = Join-Path $root "$Case.png"
    $saved = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $app
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Snapshot', $png)
        if ($ShowAll) { $a += '-ShowAll' }
        if ($Fail) { $a += @('-Fail', $Fail) }
        $out = & powershell.exe @a 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $env:LOCALAPPDATA = $saved }
    $state = @{}
    $line = $out | Where-Object { $_ -like 'state *' } | Select-Object -First 1
    if ($line) { foreach ($kv in ($line.Substring(6) -split ' ')) { $p = $kv -split '=', 2; $state[$p[0]] = $p[1] } }
    $tips = @{}
    foreach ($t in ($out | Where-Object { $_ -like 'tip *' })) { if ($t -match '^tip (\S+): (.*)$') { $tips[$Matches[1]] = $Matches[2] } }
    $size = $null
    if (Test-Path -LiteralPath $png) { $img = [System.Drawing.Image]::FromFile($png); $size = $img.Size; $img.Dispose() }
    $settingsAfter = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw } else { $null }
    return @{ Out = $out; Text = ($out -join "`n"); Code = $code; State = $state; Tips = $tips; Size = $size; SettingsAfter = $settingsAfter }
}

try {
    Write-Output 'case: first run, no settings file'
    $r = Invoke-Widget 'defaults'
    Assert ($r.Code -eq 0) 'exits 0' "code=$($r.Code)`n$($r.Text)"
    Assert ($null -ne $r.Size -and $r.Size.Width -gt 0) 'writes a PNG'
    Assert ($r.State.hidden -eq 'disk,net') 'disk and network start hidden' "got '$($r.State.hidden)'"
    Assert ($r.State.interval -eq '1000' -and $r.State.compact -eq 'False' -and $r.State.locked -eq 'False') 'default interval, per-core view, unlocked'
    Assert ($r.State.opacity -eq '0.9' -and $r.State.topmost -eq 'True' -and $r.State.smoothing -eq 'Smooth') 'default opacity, on top, smoothing'
    foreach ($k in @('cpu', 'ram', 'machine', 'core0')) { Assert ($r.Tips.ContainsKey($k)) "hover text for $k" ("keys: " + ($r.Tips.Keys -join ',')) }
    Assert (-not $r.Tips.ContainsKey('disk') -and -not $r.Tips.ContainsKey('net')) 'no disk or network rows'
    Assert ($r.Tips['ram'] -match 'GB in use') 'ram hover gives GB' "got '$($r.Tips['ram'])'"
    Assert ($r.Tips['cpu'] -match 'Right-click for options') 'cpu hover points at the menu' "got '$($r.Tips['cpu'])'"
    Assert ($null -eq $r.SettingsAfter) 'a snapshot saves nothing'
    $perCore = $r.Size

    Write-Output 'case: every section shown'
    $r = Invoke-Widget 'all' -ShowAll
    Assert ($r.Code -eq 0) 'exits 0' "code=$($r.Code)`n$($r.Text)"
    Assert ($r.Tips['disk'] -match '% active') 'disk hover gives percent active' "got '$($r.Tips['disk'])'"
    Assert ($r.Tips['net'] -match 'down, .* up') 'network hover gives both directions' "got '$($r.Tips['net'])'"
    Assert ($r.State.diskfailed -eq 'False' -and $r.State.netfailed -eq 'False' -and $r.State.failed -eq '' -and $r.State.ramfailed -eq 'False') 'no error state when nothing fails' ($r.Out | Where-Object { $_ -like 'state *' })
    if ($perCore -and $r.Size) { Assert ($r.Size.Height -gt $perCore.Height) 'disk and network rows add height' "$($r.Size.Height) vs $($perCore.Height)" }
    $allSize = $r.Size

    Write-Output 'case: failed core counter, memory, disk and network reads'
    $r = Invoke-Widget 'fail' -ShowAll -Fail 'core0,ram,disk,net'   # core0 only: CI runners have two cores
    Assert ($r.Code -eq 0) 'exits 0' "code=$($r.Code)`n$($r.Text)"
    Assert ($r.State.failed -eq '0') 'core 0 reads as failed, not 0%' "got '$($r.State.failed)'"
    Assert ($r.Tips['core0'] -match 'no reading') 'failed core says no reading' "got '$($r.Tips['core0'])'"
    Assert ($r.Tips['core1'] -notmatch 'no reading') 'a working core still reads' "got '$($r.Tips['core1'])'"
    Assert ($r.Tips['cpu'] -match '1 of \d+ core counters failed') 'cpu hover counts the failures' "got '$($r.Tips['cpu'])'"
    Assert ($r.State.ramfailed -eq 'True' -and $r.Tips['ram'] -match 'no reading') 'ram reads as failed'
    Assert ($r.State.diskfailed -eq 'True' -and $r.Tips['disk'] -match 'no reading') 'disk reads as failed'
    Assert ($r.State.netfailed -eq 'True' -and $r.Tips['net'] -match 'no reading') 'network reads as failed'

    Write-Output 'case: compact view'
    $r = Invoke-Widget 'compact' -Settings '{ "Compact": true }' -ShowAll
    Assert ($r.State.compact -eq 'True') 'compact on' "got '$($r.State.compact)'"
    Assert (-not $r.Tips.ContainsKey('core0') -and $r.Tips.ContainsKey('cpu')) 'one CPU row, no core bars' ("keys: " + ($r.Tips.Keys -join ','))
    if ($allSize -and $r.Size) { Assert ($r.Size.Height -lt $allSize.Height) 'compact is shorter than per-core' "$($r.Size.Height) vs $($allSize.Height)" }

    Write-Output 'case: everything hidden'
    $r = Invoke-Widget 'empty' -Settings '{ "Hidden": ["cpu", "ram", "disk", "net"] }'
    Assert ($r.Code -eq 0) 'exits 0' "code=$($r.Code)"
    Assert ($r.Tips.ContainsKey('empty')) 'says how to bring sections back' ("keys: " + ($r.Tips.Keys -join ','))

    Write-Output 'case: settings robustness'
    $r = Invoke-Widget 'corrupt' -Settings '{ this is not json'
    Assert ($r.Code -eq 0 -and $r.State.hidden -eq 'disk,net') 'a corrupt file falls back to defaults' "code=$($r.Code) hidden='$($r.State.hidden)'"
    $r = Invoke-Widget 'showall-saved' -Settings '{ "Hidden": [] }'
    Assert ($r.State.hidden -eq '') 'an empty Hidden list shows everything' "got '$($r.State.hidden)'"
    $r = Invoke-Widget 'onestring' -Settings '{ "Hidden": "ram" }'
    Assert ($r.State.hidden -eq 'ram') 'Hidden saved as one string' "got '$($r.State.hidden)'"
    $r = Invoke-Widget 'oddtypes' -Settings '{ "Opacity": "abc", "TopMost": "false", "X": "left", "Interval": "fast", "Compact": "yes", "Locked": 1, "Smoothing": "Wobbly" }'
    Assert ($r.Code -eq 0) 'exits 0' "code=$($r.Code)`n$($r.Text)"
    Assert ($r.State.opacity -eq '0.9') 'a non-number opacity falls back to 0.9' "got '$($r.State.opacity)'"
    Assert ($r.State.topmost -eq 'False') 'TopMost "false" is false' "got '$($r.State.topmost)'"
    Assert ($r.State.interval -eq '1000') 'a non-number interval falls back to 1 s' "got '$($r.State.interval)'"
    Assert ($r.State.compact -eq 'True' -and $r.State.locked -eq 'True') '"yes" and 1 read as true'
    Assert ($r.State.smoothing -eq 'Smooth') 'an unknown smoothing falls back to Smooth' "got '$($r.State.smoothing)'"
    $r = Invoke-Widget 'limits' -Settings '{ "Opacity": 0, "Interval": 50 }'
    Assert ($r.State.opacity -eq '0.2') 'opacity 0 is raised to 0.2 so the window stays clickable' "got '$($r.State.opacity)'"
    Assert ($r.State.interval -eq '500') 'interval is at least 0.5 s' "got '$($r.State.interval)'"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Output "PerformanceWidget: $failures failure(s)"; exit 1 }
Write-Output 'PerformanceWidget: all passed'
