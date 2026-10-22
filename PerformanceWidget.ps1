<#
.SYNOPSIS
  Performance Widget: a small always-on-top window with one bar per logical core, a RAM
  bar, and optional disk and network rows.

.DESCRIPTION
  Per-core load comes from the "% Processor Utility" counter (the number Task Manager
  shows) through long-lived PerformanceCounter objects; RAM from GlobalMemoryStatusEx;
  disk from PhysicalDisk "% Idle Time"; network from the Network Interface byte counters.
  Sampling, smoothing, easing and painting all run in a small C# form compiled at
  startup, so animating costs about as much as not animating. Hidden sections are not
  sampled at all.

  Drag with the left button to move it. Double-click switches between per-core bars and
  the compact view. Hover any bar or row for what it means. Right-click for every option.
  Position and options persist in %LOCALAPPDATA%\PerformanceWidget\settings.json.

.PARAMETER Snapshot
  Build the window off screen, sample for a few seconds, save a PNG to this path and
  exit. Used by the tests and for the README screenshot; no window is left open.

.PARAMETER ShowAll
  With -Snapshot, draw every section regardless of what is hidden.

.PARAMETER Fail
  With -Snapshot only: inject failures to check the error states. A comma list of
  coreN (that core's counter throws), ram, disk and net.
#>
param(
    [string]$Snapshot = '',
    [switch]$ShowAll,    # with -Snapshot: ignore hidden sections
    [string]$Fail = ''   # with -Snapshot: "core0,ram"; one string, since -File does not split arrays
)

$Version = '1.0.0'
$RepoUrl = 'https://github.com/Krool/PerformanceWidget'
$AppName = 'Performance Widget'

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$settingsDir = Join-Path $env:LOCALAPPDATA 'PerformanceWidget'
$settingsPath = Join-Path $settingsDir 'settings.json'

# The shortcut runs hidden, so a failure at startup would otherwise vanish without a word.
trap {
    $msg = ($_ | Out-String)
    try {
        if (-not (Test-Path -LiteralPath $settingsDir)) { New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null }
        Add-Content -LiteralPath (Join-Path $settingsDir 'error.log') -Value ("{0} {1}" -f (Get-Date -Format s), $msg)
    } catch { }
    if ($Snapshot) { [Console]::Error.WriteLine($msg) }
    else { try { [void][System.Windows.Forms.MessageBox]::Show("$AppName stopped: $($_.Exception.Message)`n`nDetails: %LOCALAPPDATA%\PerformanceWidget\error.log", $AppName) } catch { } }
    exit 1
}

Add-Type -Namespace PerformanceWidget -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][PerformanceWidget.Native]::SetProcessDPIAware()

# One widget per user session. Snapshot runs (tests) skip it, so they never make a real
# launch exit as a duplicate.
if (-not $Snapshot) {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\PerformanceWidget', [ref]$created)
    if (-not $created) { return }
}

# ---------------------------------------------------------------- settings

$Cfg = @{
    X = $null; Y = $null; Opacity = 0.9; TopMost = $true; Smoothing = 'Smooth'
    Hidden = @('disk', 'net'); Interval = 1000; Compact = $false; Locked = $false
}
try {
    if (Test-Path -LiteralPath $settingsPath) {
        $loaded = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        foreach ($k in @($Cfg.Keys)) {
            $p = $loaded.PSObject.Properties[$k]
            # Test the property, not the value: an empty Hidden list is a real choice.
            if ($p -and ($null -ne $p.Value -or $k -eq 'Hidden')) { $Cfg[$k] = $p.Value }
        }
    }
} catch { }
$Cfg.Hidden = @($Cfg.Hidden | Where-Object { $_ } | ForEach-Object { [string]$_ })
# Hand edits: opacity must be a number the window can still be clicked at; "false" is false.
$op = $Cfg.Opacity -as [double]
$Cfg.Opacity = if ($null -eq $op) { 0.9 } else { [math]::Min(1.0, [math]::Max(0.2, $op)) }
$Intervals = @(500, 1000, 2000, 5000)
$iv = $Cfg.Interval -as [int]
$Cfg.Interval = if ($null -eq $iv) { 1000 } else { [math]::Min(5000, [math]::Max(500, $iv)) }
function ConvertTo-Bool($v, [bool]$Default) {
    if ($null -eq $v) { return $Default }
    if (@($false, 'false', 0, '0', 'no', 'off') -contains $v) { return $false }
    if (@($true, 'true', 1, '1', 'yes', 'on') -contains $v) { return $true }
    return $Default
}
$Cfg.TopMost = ConvertTo-Bool $Cfg.TopMost $true
$Cfg.Compact = ConvertTo-Bool $Cfg.Compact $false
$Cfg.Locked = ConvertTo-Bool $Cfg.Locked $false
if (@('Off', 'Smooth', 'Calm') -notcontains $Cfg.Smoothing) { $Cfg.Smoothing = 'Smooth' }
if (($Cfg.X -as [int]) -eq $null -or ($Cfg.Y -as [int]) -eq $null) { $Cfg.X = $null; $Cfg.Y = $null }

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $settingsDir)) { New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null }
        $o = [ordered]@{}
        foreach ($k in @('X', 'Y', 'Opacity', 'TopMost', 'Smoothing', 'Hidden', 'Interval', 'Compact', 'Locked')) { $o[$k] = $Cfg[$k] }
        $o.Hidden = @($Cfg.Hidden)
        ([pscustomobject]$o | ConvertTo-Json) | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- counters

function New-CoreCounters {
    # "Processor Information" instances are "group,index" plus "_Total" and "group,_Total".
    # Fall back to the older "Processor" category if Utility is missing.
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('Processor Information')
        $names = $cat.GetInstanceNames() | Where-Object { $_ -notmatch '_Total' } |
            Sort-Object { [int]($_ -split ',')[0] }, { [int]($_ -split ',')[1] }
        $list = foreach ($n in $names) { New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Utility', $n, $true) }
        if ($list) { return @($list) }
    } catch { }
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('Processor')
        $names = $cat.GetInstanceNames() | Where-Object { $_ -ne '_Total' } | Sort-Object { [int]$_ }
        return @(foreach ($n in $names) { New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', $n, $true) })
    } catch {
        # A broken counter registry (what `lodctr /R` repairs): the CPU header says so in red.
        return @()
    }
}

$counters = New-CoreCounters
foreach ($pc in $counters) { try { [void]$pc.NextValue() } catch { } }   # first read is always 0
# Smoothing: weight of each new sample (lower = calmer). Off also skips the easing.
$SmoothAlpha = @{ Off = 1.0; Smooth = 0.5; Calm = 0.25 }

# ---------------------------------------------------------------- window

# Sampling, easing and painting are compiled C#: a PowerShell Paint handler costs about
# 15 ms of CPU a frame, so easing at 20 fps from script would burn a fifth of a core.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PerformanceWidget {
public class View : Form {
    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX {
        public uint dwLength; public uint dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

    readonly PerformanceCounter[] counters;
    readonly double[] targets, loads, from;   // targets: averaged samples; loads: drawn; from: loads when the ease began
    readonly bool[] failed;                   // this sample's read threw; drawn hatched, left out of the average
    double ramTarget, ramLoad, ramFrom, ramUsedGb, ramTotalGb;
    bool ramFailed;
    PerformanceCounter disk;                  // opened the first time the disk row is shown
    double diskTarget, diskLoad, diskFrom;
    bool diskFailed, diskTried;
    PerformanceCounter[] netRx = new PerformanceCounter[0], netTx = new PerformanceCounter[0];
    readonly Stopwatch netAge = new Stopwatch();
    double rxBits, txBits;                    // smoothed bits per second
    bool netFailed, netOpened, netCatOk;
    int netAdapters;
    readonly Stopwatch easeClock = new Stopwatch();
    const double EaseMs = 350;          // each sample eases in over this long, then nothing repaints
    public double Alpha = 0.5;          // weight of each new sample; 1 = raw
    public bool Ease = true;
    public bool Compact;                // one horizontal CPU bar instead of a bar per core
    public bool Locked;                 // dragging does nothing
    public bool GrowUp, GrowLeft;       // keep the bottom / right edge fixed when the size changes
    public readonly HashSet<int> ForceFail = new HashSet<int>();   // -Snapshot -Fail only
    public bool ForceRamFail, ForceDiskFail, ForceNetFail;
    public readonly HashSet<string> Hidden = new HashSet<string>();
    public event EventHandler Changed;  // the window moved or the view changed

    readonly float scale;
    readonly Timer sample = new Timer(), anim = new Timer(), hover = new Timer();
    readonly ToolTip tip = new ToolTip();
    readonly Font fMain = new Font("Segoe UI", 7.5f, FontStyle.Regular);
    readonly Font fBold = new Font("Segoe UI", 7.5f, FontStyle.Bold);
    const int Pad = 6, TextH = 13, BarH = 36, Gap = 2, ThinH = 4, RowH = 14, SecGap = 5, RamW = 10, RamGap = 6, LabelW = 28, ValueW = 30;
    readonly int n, barW, innerW;
    int formW;
    // Hover regions, in pixels; later entries are more specific and win.
    readonly List<KeyValuePair<string, Rectangle>> tips = new List<KeyValuePair<string, Rectangle>>();

    static readonly Color Bg = Color.FromArgb(24, 26, 30), Track = Color.FromArgb(44, 47, 54),
        Grid = Color.FromArgb(60, 64, 72), Text1 = Color.FromArgb(220, 223, 228), Dim = Color.FromArgb(140, 146, 156),
        Low = Color.FromArgb(80, 190, 120), Mid = Color.FromArgb(230, 180, 60), High = Color.FromArgb(230, 80, 70),
        Ram = Color.FromArgb(110, 160, 230), Disk = Color.FromArgb(180, 140, 230), Net = Color.FromArgb(90, 190, 200);

    public View(PerformanceCounter[] counters, float scale) {
        this.counters = counters; this.scale = scale;
        n = counters.Length; targets = new double[n]; loads = new double[n]; from = new double[n]; failed = new bool[n];
        barW = Math.Max(3, Math.Min(8, (144 - (n - 1) * Gap) / Math.Max(1, n)));
        innerW = Math.Max(0, n * barW + (n - 1) * Gap);
        formW = WidthFor(false);
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        BackColor = Bg;
        Width = Px(formW);
        sample.Interval = 1000; sample.Tick += (s, e) => SampleNow();
        anim.Interval = 50; anim.Tick += (s, e) => Step();
        hover.Tick += (s, e) => ShowTip();
        ReadRam(1.0); ramLoad = ramTarget;
    }

    int WidthFor(bool compact) { return compact ? 150 : Math.Max(150, innerW + RamGap + RamW + 2 * Pad); }

    int Px(double v) { return (int)Math.Round(v * scale); }

    public int Interval {
        get { return sample.Interval; }
        set { sample.Interval = Math.Max(250, value); }
    }

    bool Shown_(string s) { return !Hidden.Contains(s); }

    void ReadRam(double a) {
        var m = new MEMORYSTATUSEX(); m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        ramFailed = ForceRamFail || !GlobalMemoryStatusEx(ref m) || m.ullTotalPhys == 0;
        if (ramFailed) return;
        ramTotalGb = m.ullTotalPhys / 1073741824.0;
        ramUsedGb = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
        ramTarget += a * (100.0 * ramUsedGb / ramTotalGb - ramTarget);
    }

    void ReadDisk(double a) {
        if (!diskTried) {
            diskTried = true;
            try { disk = new PerformanceCounter("PhysicalDisk", "% Idle Time", "_Total", true); disk.NextValue(); } catch { disk = null; }
        }
        diskFailed = true;
        if (ForceDiskFail || disk == null) return;
        try {
            double busy = 100.0 - Math.Max(0.0, Math.Min(100.0, disk.NextValue()));
            diskTarget += a * (busy - diskTarget); diskFailed = false;
        } catch { }
    }

    void OpenNet() {
        foreach (var c in netRx) c.Dispose();
        foreach (var c in netTx) c.Dispose();
        netRx = new PerformanceCounter[0]; netTx = new PerformanceCounter[0]; netAdapters = 0;
        netOpened = true; netCatOk = false; netAge.Restart();
        try {
            string[] names = new PerformanceCounterCategory("Network Interface").GetInstanceNames();
            netCatOk = true;
            var rx = new List<PerformanceCounter>(); var tx = new List<PerformanceCounter>();
            foreach (string name in names) {
                try {
                    var r = new PerformanceCounter("Network Interface", "Bytes Received/sec", name, true);
                    var t = new PerformanceCounter("Network Interface", "Bytes Sent/sec", name, true);
                    r.NextValue(); t.NextValue();
                    rx.Add(r); tx.Add(t);
                } catch { }
            }
            netRx = rx.ToArray(); netTx = tx.ToArray(); netAdapters = netRx.Length;
        } catch { }
    }

    void ReadNet(double a) {
        // Adapters come and go (VPN, Wi-Fi off, a dock): re-list them every 30 s or after a failed read.
        if (!netOpened || netAge.Elapsed.TotalSeconds > 30) OpenNet();
        netFailed = true;
        if (ForceNetFail) return;
        double rx = 0, tx = 0; int ok = 0; bool broken = false;
        for (int i = 0; i < netRx.Length; i++) {
            try { rx += netRx[i].NextValue(); tx += netTx[i].NextValue(); ok++; } catch { broken = true; }
        }
        if (broken) netOpened = false;
        if (!netCatOk || (ok == 0 && netRx.Length > 0)) return;
        rxBits += a * (rx * 8 - rxBits); txBits += a * (tx * 8 - txBits);
        netFailed = false;
    }

    public void StartSampling() { sample.Start(); }

    public void SampleNow() {
        // A read that throws marks that core failed for this sample instead of reading 0%
        // (an idle core); the next sample tries again. Hidden sections are not read.
        if (Shown_("cpu")) {
            for (int i = 0; i < n; i++) {
                failed[i] = true;
                if (ForceFail.Contains(i)) continue;
                try { double raw = Math.Min(100.0, counters[i].NextValue()); targets[i] += Alpha * (raw - targets[i]); failed[i] = false; } catch { }
            }
        }
        if (Shown_("ram")) ReadRam(Alpha);
        if (Shown_("disk")) ReadDisk(Alpha);
        if (Shown_("net")) ReadNet(Alpha);
        if (!Ease) { Settle(); return; }
        Array.Copy(loads, from, n); ramFrom = ramLoad; diskFrom = diskLoad;
        easeClock.Restart();
        anim.Start();
    }

    public void Settle() { anim.Stop(); Array.Copy(targets, loads, n); ramLoad = ramTarget; diskLoad = diskTarget; Invalidate(); }

    void Step() {
        // A fixed-length ease-out after each sample, then stop, so an idle widget does
        // not repaint between samples.
        double t = Math.Min(1.0, easeClock.Elapsed.TotalMilliseconds / EaseMs);
        double k = 1 - (1 - t) * (1 - t) * (1 - t);
        for (int i = 0; i < n; i++) loads[i] = from[i] + (targets[i] - from[i]) * k;
        ramLoad = ramFrom + (ramTarget - ramFrom) * k;
        diskLoad = diskFrom + (diskTarget - diskFrom) * k;
        Invalidate();
        if (t >= 1) anim.Stop();
    }

    // Size follows the visible sections and the view. A window in the lower half keeps its
    // bottom edge; one in the right half keeps its right edge.
    public void Relayout() {
        formW = WidthFor(Compact);
        int w = Px(formW), h = Render(null);
        if (h == Height && w == Width) { Invalidate(); return; }
        int bottom = Bottom, rightEdge = Right;
        Size = new Size(w, h);
        if (GrowUp) Top = bottom - h;
        if (GrowLeft) Left = rightEdge - w;
        Invalidate();
    }

    static Color LoadColor(double v) { return v >= 85 ? High : v >= 50 ? Mid : Low; }

    // Averages count only the cores that read this sample.
    void CpuTotals(out double total, out int ok) {
        total = 0; ok = 0;
        for (int i = 0; i < n; i++) if (!failed[i]) { total += loads[i]; ok++; }
    }

    void Tip(string key, int x0, int y0, int x1, int y1) {
        tips.Add(new KeyValuePair<string, Rectangle>(key, Rectangle.FromLTRB(x0, y0, x1, y1)));
    }

    static string Rate(double bits) {
        if (bits < 1e6) return string.Format("{0:0} Kbps", bits / 1e3);
        if (bits < 1e7) return string.Format("{0:0.0} Mbps", bits / 1e6);
        if (bits < 1e9) return string.Format("{0:0} Mbps", bits / 1e6);
        return string.Format("{0:0.0} Gbps", bits / 1e9);
    }

    // One pass lays out and (with g) draws; returns the height. Positions are in
    // unscaled units; every edge is converted with Px once so bar bottoms never wobble.
    int Render(Graphics g) {
        tips.Clear();
        int y = Pad;
        int right = formW - Pad;
        SolidBrush br = null, brDim = null, track = null, brWarn = null;
        HatchBrush hatch = null;
        if (g != null) {
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            br = new SolidBrush(Text1); brDim = new SolidBrush(Dim); track = new SolidBrush(Track); brWarn = new SolidBrush(High);
            hatch = new HatchBrush(HatchStyle.BackwardDiagonal, High, Track);
        }
        bool any = false;
        try {
            bool showCpu = Shown_("cpu"), showRam = Shown_("ram");
            double total; int ok; CpuTotals(out total, out ok);
            double avg = ok > 0 ? total / ok : 0;

            if (!Compact && (showCpu || showRam)) {
                // Per-core view: the core bars, then the RAM bar on the right, all growing up
                // from the same pixel row.
                any = true;
                bool cores = showCpu && n > 0;
                int blockW = (cores ? innerW : 0) + (cores && showRam ? RamGap : 0) + (showRam ? RamW : 0);
                int coreX = (formW - blockW) / 2, ramX = coreX + (cores ? innerW + RamGap : 0);
                int split = showCpu && showRam ? Px(formW * 0.6) : Px(formW);

                if (showCpu) {
                    string head = n == 0 ? "CPU unavailable" : ok == 0 ? "CPU --" : string.Format("CPU {0:0}%", avg);
                    if (g != null) {
                        g.DrawString(head, fBold, ok == 0 ? brWarn : br, Px(Pad - 1), Px(y - 1));
                        if (n > 0) {
                            float hw = g.MeasureString(head, fBold).Width;
                            string sub = ok < n ? string.Format("{0} failed", n - ok) : string.Format("{0:0.0}/{1}", total / 100.0, n);
                            g.DrawString(sub, fMain, ok < n ? brWarn : brDim, Px(Pad - 1) + hw, Px(y - 1));
                        }
                    }
                    Tip("cpu", 0, Px(y - 2), split, Px(y + TextH));
                }
                if (showRam) {
                    if (g != null) DrawRight(g, ramFailed ? "RAM --" : string.Format("RAM {0:0}%", ramLoad), ramFailed ? brWarn : brDim, right, y);
                    Tip("ram", showCpu ? split : 0, Px(y - 2), Px(formW), Px(y + TextH));
                }
                y += TextH;

                int barTop = Px(y), barBottom = Px(y + BarH);
                for (int i = 0; cores && i < n; i++) {
                    int x = Px(coreX + i * (barW + Gap)), w = Px(coreX + i * (barW + Gap) + barW) - x;
                    Tip("core" + i, x, barTop, Px(coreX + (i + 1) * (barW + Gap)), barBottom);
                    if (g == null) continue;
                    if (failed[i]) { g.FillRectangle(hatch, x, barTop, w, barBottom - barTop); continue; }
                    g.FillRectangle(track, x, barTop, w, barBottom - barTop);
                    double v = Math.Max(0, Math.Min(100, loads[i]));
                    int hpx = (int)Math.Round((barBottom - barTop) * v / 100.0);
                    if (hpx > 0) using (var fill = new SolidBrush(LoadColor(v))) g.FillRectangle(fill, x, barBottom - hpx, w, hpx);
                }
                if (showRam) {
                    int x = Px(ramX), w = Px(ramX + RamW) - x;
                    Tip("ram", x - Px(RamGap / 2), barTop, Px(ramX + RamW + RamGap / 2), barBottom);
                    if (g != null) {
                        if (ramFailed) g.FillRectangle(hatch, x, barTop, w, barBottom - barTop);
                        else {
                            g.FillRectangle(track, x, barTop, w, barBottom - barTop);
                            double v = Math.Max(0, Math.Min(100, ramLoad));
                            int hpx = (int)Math.Round((barBottom - barTop) * v / 100.0);
                            if (hpx > 0) using (var fill = new SolidBrush(v >= 85 ? High : Ram)) g.FillRectangle(fill, x, barBottom - hpx, w, hpx);
                        }
                    }
                }
                if (g != null) using (var gridPen = new Pen(Grid)) {
                    int mid = (barTop + barBottom) / 2;
                    g.DrawLine(gridPen, Px(coreX), mid, Px(coreX + blockW) - 1, mid);
                }
                y += BarH;
                if (cores) {
                    y += 3;
                    if (g != null) DrawThin(g, track, avg, ok == 0 ? Track : LoadColor(avg), coreX, coreX + innerW, y);
                    Tip("machine", Px(coreX), Px(y - 3), Px(coreX + innerW), Px(y + ThinH + 3));
                    y += ThinH;
                }
                y += SecGap;
            } else if (Compact) {
                if (showCpu) {
                    any = true;
                    string val = n == 0 ? "n/a" : ok == 0 ? "--" : string.Format("{0:0}%", avg);
                    Row(g, "cpu", "CPU", val, ok == 0, avg, ok == 0 ? Track : LoadColor(avg), ok == 0 && n > 0 ? hatch : null, track, br, brDim, brWarn, ref y);
                }
                if (showRam) {
                    any = true;
                    Row(g, "ram", "RAM", ramFailed ? "--" : string.Format("{0:0}%", ramLoad), ramFailed, ramLoad, ramLoad >= 85 ? High : Ram, ramFailed ? hatch : null, track, br, brDim, brWarn, ref y);
                }
            }

            if (Shown_("disk")) {
                any = true;
                Row(g, "disk", "Disk", diskFailed ? "--" : string.Format("{0:0}%", diskLoad), diskFailed, diskLoad, diskLoad >= 85 ? High : Disk, diskFailed ? hatch : null, track, br, brDim, brWarn, ref y);
            }

            if (Shown_("net")) {
                any = true;
                Tip("net", 0, Px(y - 2), Px(formW), Px(y + RowH));
                if (g != null) {
                    g.DrawString("Net", fBold, br, Px(Pad - 1), Px(y - 1));
                    if (netFailed) g.DrawString("--", fMain, brWarn, Px(Pad + LabelW), Px(y - 1));
                    else using (var bn = new SolidBrush(Net)) {
                        // Down arrow and received rate at the left, up arrow and sent rate at the right.
                        g.DrawString("\u2193 " + Rate(rxBits), fMain, bn, Px(Pad + LabelW), Px(y - 1));
                        DrawRight(g, "\u2191 " + Rate(txBits), bn, right, y);
                    }
                }
                y += RowH + SecGap - 2;
            }

            if (!any) {
                if (g != null) g.DrawString("all hidden: right-click", fMain, brDim, Px(Pad - 1), Px(y));
                Tip("empty", 0, Px(y - 2), Px(formW), Px(y + RowH));
                y += RowH + SecGap;
            }
        } finally {
            if (g != null) { br.Dispose(); brDim.Dispose(); track.Dispose(); brWarn.Dispose(); hatch.Dispose(); }
        }
        return Px(y - SecGap + Pad);
    }

    // A label, a horizontal bar and a value: the compact CPU and RAM rows, and the disk row.
    void Row(Graphics g, string key, string label, string value, bool bad, double pct, Color c, Brush failFill,
             Brush track, Brush br, Brush brDim, Brush brWarn, ref int y) {
        Tip(key, 0, Px(y - 2), Px(formW), Px(y + RowH));
        if (g != null) {
            g.DrawString(label, fBold, br, Px(Pad - 1), Px(y - 1));
            int x0 = Pad + LabelW, x1 = formW - Pad - ValueW;
            int top = y + 4;
            if (failFill != null) g.FillRectangle(failFill, Px(x0), Px(top), Px(x1) - Px(x0), Px(top + ThinH + 2) - Px(top));
            else DrawThin(g, track, pct, c, x0, x1, top, ThinH + 2);
            DrawRight(g, value, bad ? brWarn : brDim, formW - Pad, y);
        }
        y += RowH + SecGap - 2;
    }

    void DrawRight(Graphics g, string s, Brush b, int right, int y) {
        float w = g.MeasureString(s, fMain).Width;
        g.DrawString(s, fMain, b, Px(right + 1) - w, Px(y - 1));
    }

    void DrawThin(Graphics g, Brush track, double pct, Color c, int x, int xEnd, int y, int hUnits = ThinH) {
        int x0 = Px(x), x1 = Px(xEnd), top = Px(y), h = Px(y + hUnits) - top;
        g.FillRectangle(track, x0, top, x1 - x0, h);
        int w = (int)Math.Round((x1 - x0) * Math.Max(0, Math.Min(100, pct)) / 100.0);
        if (w > 0) using (var b = new SolidBrush(c)) g.FillRectangle(b, x0, top, w, h);
    }

    protected override void OnPaint(PaintEventArgs e) { Render(e.Graphics); }

    // ------------------------------------------------------------ hover text

    string MoveHint { get { return Locked ? "Position is locked (right-click > Lock position)." : "Drag to move. Double-click to switch views. Right-click for options."; } }

    public string TipFor(string key) {
        double total; int ok; CpuTotals(out total, out ok);
        if (key.StartsWith("core")) {
            int i = int.Parse(key.Substring(4));
            if (failed[i]) return string.Format("Core {0}: no reading\nIts counter failed this sample, so it is left out of the CPU average. It tries again next sample.", i);
            return string.Format("Core {0}: {1:0}%\nLoad on one logical core (% Processor Utility, the number Task Manager shows). Green under 50%, amber under 85%, red above.", i, loads[i]);
        }
        switch (key) {
            case "cpu":
                if (n == 0) return "CPU: no counters\nWindows could not open the processor performance counters. Run lodctr /R from an admin prompt, then restart the widget.";
                return string.Format("CPU {0:0}%: {1:0.0} of {2} logical cores busy\nAverage over every core.{3}\n{4}",
                    ok > 0 ? total / ok : 0, total / 100.0, ok,
                    ok < n ? string.Format("\n{0} of {1} core counters failed this sample and are left out (hatched red).", n - ok, n) : "",
                    MoveHint);
            case "machine":
                return string.Format("Whole machine: {0:0}%\nThe average of every core as one bar.", ok > 0 ? total / ok : 0);
            case "ram":
                if (ramFailed) return "RAM: no reading\nThe memory query failed. It tries again next sample.";
                return string.Format("RAM {0:0}%: {1:0.0} of {2:0.0} GB in use\nPhysical memory. Blue, red from 85%.\n{3}", ramLoad, ramUsedGb, ramTotalGb, MoveHint);
            case "disk":
                if (diskFailed) return "Disk: no reading\nThe PhysicalDisk counter is unavailable or failed. It tries again next sample.";
                return string.Format("Disk {0:0}% active\nShare of time the physical disks were busy (100% minus idle time), averaged across disks.", diskLoad);
            case "net":
                if (netFailed) return "Network: no reading\nThe Network Interface counters are unavailable or failed. It tries again next sample.";
                return string.Format("Network: {0} down, {1} up\nSum over {2} network adapter{3}. A virtual adapter (VPN, Hyper-V switch) can count the same traffic twice.",
                    Rate(rxBits), Rate(txBits), netAdapters, netAdapters == 1 ? "" : "s");
            case "empty": return "Every section is hidden. Right-click > Show all.";
        }
        return "";
    }

    public string[] TipKeys() {
        var seen = new List<string>();
        foreach (var t in tips) if (!seen.Contains(t.Key)) seen.Add(t.Key);
        return seen.ToArray();
    }

    public string FailedCores() {
        var s = new List<string>();
        for (int i = 0; i < n; i++) if (failed[i]) s.Add(i.ToString());
        return string.Join(",", s.ToArray());
    }
    public bool RamFailed { get { return ramFailed; } }
    public bool DiskFailed { get { return diskFailed; } }
    public bool NetFailed { get { return netFailed; } }

    string tipKey; Point tipAt; bool tipShown;

    string TipKeyAt(Point p) {
        for (int i = tips.Count - 1; i >= 0; i--) if (tips[i].Value.Contains(p)) return tips[i].Key;
        return null;
    }

    void HoverAt(Point p) {
        string k = TipKeyAt(p);
        if (k == tipKey) return;
        bool was = tipShown;
        HideTip();
        tipKey = k;
        if (k == null) return;
        tipAt = p;
        hover.Interval = was ? 60 : 450;   // moving along the bars swaps the text quickly
        hover.Start();
    }

    void HideTip() { hover.Stop(); if (tipShown) tip.Hide(this); tipShown = false; tipKey = null; }

    void ShowTip() {
        hover.Stop();
        if (tipKey == null || pressed) return;
        string text = Wrap(TipFor(tipKey), 60);
        if (text.Length == 0) return;
        // Below the cursor, or above it when that would leave the screen.
        Size sz = TextRenderer.MeasureText(text, SystemFonts.StatusFont);
        sz = new Size(sz.Width + Px(12), sz.Height + Px(10));
        Point s = PointToScreen(new Point(tipAt.X + Px(12), tipAt.Y + Px(18)));
        Rectangle wa = Screen.FromPoint(s).WorkingArea;
        if (s.Y + sz.Height > wa.Bottom) s.Y = PointToScreen(tipAt).Y - sz.Height - Px(6);
        if (s.X + sz.Width > wa.Right) s.X = Math.Max(wa.Left, wa.Right - sz.Width);
        tip.Show(text, this, PointToClient(s), 30000);
        tipShown = true;
    }

    static string Wrap(string text, int width) {
        var sb = new System.Text.StringBuilder();
        foreach (string line in text.Split('\n')) {
            if (sb.Length > 0) sb.Append('\n');
            int col = 0; bool first = true;
            foreach (string w in line.Split(' ')) {
                if (!first && col + 1 + w.Length > width) { sb.Append('\n'); col = 0; }
                else if (!first) { sb.Append(' '); col++; }
                sb.Append(w); col += w.Length; first = false;
            }
        }
        return sb.ToString();
    }

    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); HideTip(); }

    // ------------------------------------------------------------ drag and double-click

    Point downScreen, formStart; bool pressed, dragging;
    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        HideTip();
        if (e.Button != MouseButtons.Left || Locked) return;
        pressed = true; dragging = false; downScreen = Cursor.Position; formStart = Location;
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        if (!pressed) { HoverAt(e.Location); return; }
        // A lost mouse-up (right-click mid-press, Win+L, a UAC prompt) must not leave the
        // window following a cursor with no button down.
        if ((e.Button & MouseButtons.Left) == 0) { pressed = false; dragging = false; return; }
        int dx = Cursor.Position.X - downScreen.X, dy = Cursor.Position.Y - downScreen.Y;
        if (!dragging && Math.Abs(dx) + Math.Abs(dy) > 4) dragging = true;
        if (dragging) Location = new Point(formStart.X + dx, formStart.Y + dy);
    }
    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left || !pressed) return;
        pressed = false;
        bool moved = dragging;
        dragging = false;
        if (moved && Changed != null) Changed(this, EventArgs.Empty);
    }
    protected override void OnMouseDoubleClick(MouseEventArgs e) {
        base.OnMouseDoubleClick(e);
        if (e.Button != MouseButtons.Left) return;
        Compact = !Compact;
        Relayout();
        if (Changed != null) Changed(this, EventArgs.Empty);
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        sample.Stop(); anim.Stop(); hover.Stop(); tip.Dispose();
        foreach (var c in counters) c.Dispose();
        foreach (var c in netRx) c.Dispose();
        foreach (var c in netTx) c.Dispose();
        if (disk != null) disk.Dispose();
        base.OnFormClosed(e);
    }
}
}
'@

$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$scale = $g0.DpiX / 96.0
$g0.Dispose()

$form = New-Object PerformanceWidget.View(([System.Diagnostics.PerformanceCounter[]]$counters), ([float]$scale))
$form.Text = $AppName
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.TopMost = [bool]$Cfg.TopMost
$form.Opacity = [double]$Cfg.Opacity
$form.Compact = [bool]$Cfg.Compact
$form.Locked = [bool]$Cfg.Locked
$form.Interval = [int]$Cfg.Interval
if (-not ($Snapshot -and $ShowAll)) { foreach ($h in $Cfg.Hidden) { [void]$form.Hidden.Add([string]$h) } }

function Set-Smoothing([string]$Mode) {
    $a = $SmoothAlpha[$Mode]; if (-not $a) { $a = 0.5 }
    $form.Alpha = $a
    $form.Ease = ($Mode -ne 'Off')
}
Set-Smoothing ([string]$Cfg.Smoothing)

function Update-Anchor {
    $scr = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.GrowUp = ($form.Top + $form.Height / 2) -gt ($scr.Top + $scr.Height / 2)
    $form.GrowLeft = ($form.Left + $form.Width / 2) -gt ($scr.Left + $scr.Width / 2)
}

function Set-OnScreen {
    # Keep the whole window inside the working area of the screen it is on.
    $scr = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $x = [math]::Max($scr.Left, [math]::Min($form.Left, $scr.Right - $form.Width))
    $y = [math]::Max($scr.Top, [math]::Min($form.Top, $scr.Bottom - $form.Height))
    if ($x -ne $form.Left -or $y -ne $form.Top) { $form.Location = New-Object System.Drawing.Point($x, $y) }
}

function Save-Window {
    $Cfg.X = $form.Left; $Cfg.Y = $form.Top
    $Cfg.Hidden = @($form.Hidden)
    $Cfg.Compact = [bool]$form.Compact
    Save-Settings
}

function Update-Layout {
    Update-Anchor
    $form.Relayout()
    if (-not $Snapshot) { Set-OnScreen }
    Save-Window
}

function Reset-Position {
    # Read the layout now, not at startup: docking or a resolution change moves it.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - 16), ($wa.Bottom - $form.Height - 16))
}

# Start with Windows: a shortcut in the user's Startup folder, the same one install.ps1 -Startup makes.
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
function Set-StartWithWindows([bool]$On) {
    if (-not $On) { if (Test-Path -LiteralPath $startupLnk) { Remove-Item -LiteralPath $startupLnk -Force }; return }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLnk)
    $lnk.TargetPath = $ps
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle = 7   # minimized, so the console does not flash in front
    $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\perfmon.exe') + ',0'
    $lnk.Description = 'Per-core CPU, RAM, disk and network meter'
    $lnk.Save()
}

# ---------------------------------------------------------------- right-click menu

function New-Item2([string]$Text, [scriptblock]$OnClick) {
    $i = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    if ($OnClick) { $i.add_Click($OnClick) }
    return $i
}

$Sections = [ordered]@{ cpu = 'CPU'; ram = 'RAM'; disk = 'Disk'; net = 'Network' }
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showAllItem = New-Item2 'Show all' { $form.Hidden.Clear(); Update-Layout }
[void]$menu.Items.Add($showAllItem)
$secItems = @{}
foreach ($key in $Sections.Keys) {
    $item = New-Item2 $Sections[$key] {
        param($s, $e)
        if ($form.Hidden.Contains($s.Tag)) { [void]$form.Hidden.Remove($s.Tag) } else { [void]$form.Hidden.Add($s.Tag) }
        Update-Layout
    }
    $item.Tag = $key
    $secItems[$key] = $item
    [void]$menu.Items.Add($item)
}
$coreItem = New-Item2 'Per-core bars' { $form.Compact = -not $form.Compact; Update-Layout }
[void]$menu.Items.Add($coreItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$ivMenu = New-Item2 'Update interval' $null
foreach ($ms in $Intervals) {
    $item = New-Item2 ('{0} s' -f ($ms / 1000)) { param($s, $e) $Cfg.Interval = [int]$s.Tag; $form.Interval = [int]$s.Tag; Save-Settings }
    $item.Tag = $ms
    [void]$ivMenu.DropDownItems.Add($item)
}
[void]$menu.Items.Add($ivMenu)
$smMenu = New-Item2 'Smoothing' $null
foreach ($mode in @('Off', 'Smooth', 'Calm')) {
    [void]$smMenu.DropDownItems.Add((New-Item2 $mode { param($s, $e) $Cfg.Smoothing = $s.Text; Set-Smoothing $s.Text; Save-Settings }))
}
[void]$menu.Items.Add($smMenu)
$opMenu = New-Item2 'Opacity' $null
foreach ($pct in @(100, 90, 75, 60, 40)) {
    $item = New-Item2 "$pct%" { param($s, $e) $form.Opacity = [double]$s.Tag; $Cfg.Opacity = [double]$s.Tag; Save-Settings }
    $item.Tag = $pct / 100.0
    [void]$opMenu.DropDownItems.Add($item)
}
[void]$menu.Items.Add($opMenu)
$topItem = New-Item2 'Always on top' { $Cfg.TopMost = -not $Cfg.TopMost; $form.TopMost = $Cfg.TopMost; Save-Settings }
[void]$menu.Items.Add($topItem)
$lockItem = New-Item2 'Lock position' { $Cfg.Locked = -not $Cfg.Locked; $form.Locked = $Cfg.Locked; Save-Settings }
[void]$menu.Items.Add($lockItem)
$startItem = New-Item2 'Start with Windows' {
    try { Set-StartWithWindows (-not (Test-Path -LiteralPath $startupLnk)) }
    catch { [void][System.Windows.Forms.MessageBox]::Show("Could not change the Startup shortcut: $($_.Exception.Message)", $AppName) }
}
[void]$menu.Items.Add($startItem)
$resetItem = New-Item2 'Reset position' { Reset-Position; Update-Anchor; Save-Window }
[void]$menu.Items.Add($resetItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$aboutItem = New-Item2 "About $AppName" {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "$AppName $Version`n`nPer-core CPU, RAM, disk and network bars for Windows.`nSettings: $settingsPath`n`n$RepoUrl`n`nOpen the project page?",
        "About $AppName", 'YesNo', 'Information')
    if ($r -eq 'Yes') { Start-Process $RepoUrl }
}
[void]$menu.Items.Add($aboutItem)
[void]$menu.Items.Add((New-Item2 'Exit' { $form.Close() }))
$menu.add_Opening({
    # Ticks reflect the current state each time the menu opens.
    foreach ($key in $secItems.Keys) { $secItems[$key].Checked = -not $form.Hidden.Contains($key) }
    $coreItem.Checked = -not $form.Compact
    foreach ($it in $ivMenu.DropDownItems) { $it.Checked = ([int]$it.Tag -eq $form.Interval) }
    foreach ($it in $smMenu.DropDownItems) { $it.Checked = ($it.Text -eq $Cfg.Smoothing) }
    foreach ($it in $opMenu.DropDownItems) { $it.Checked = ([math]::Abs([double]$it.Tag - $form.Opacity) -lt 0.01) }
    $topItem.Checked = [bool]$Cfg.TopMost
    $lockItem.Checked = [bool]$Cfg.Locked
    $startItem.Checked = Test-Path -LiteralPath $startupLnk
    $showAllItem.Enabled = $form.Hidden.Count -gt 0
})
$form.ContextMenuStrip = $menu
$form.add_Changed({ Update-Anchor; if (-not $Snapshot) { Set-OnScreen }; Save-Window })

# ---------------------------------------------------------------- start

$form.Relayout()

# Restore the saved spot if it is still on a screen. Monitors left of or above the
# primary have negative coordinates, so any number is a valid saved spot.
$onScreen = $false
try {
    if ($null -ne $Cfg.X -and $null -ne $Cfg.Y) {
        $sx = [int]$Cfg.X; $sy = [int]$Cfg.Y
        $pt = New-Object System.Drawing.Point(($sx + 10), ($sy + 10))
        foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) { if ($scr.WorkingArea.Contains($pt)) { $onScreen = $true } }
    }
} catch { $onScreen = $false }
if ($onScreen) { $form.Location = New-Object System.Drawing.Point($sx, $sy); Set-OnScreen } else { Reset-Position }

if ($Snapshot) {
    # Sample, render to a bitmap, exit. Nothing is saved.
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.GrowUp = $false; $form.GrowLeft = $false
    foreach ($f in ($Fail -split ',')) {
        if ($f -match '^core(\d+)$') { [void]$form.ForceFail.Add([int]$Matches[1]) }
        elseif ($f -eq 'ram') { $form.ForceRamFail = $true }
        elseif ($f -eq 'disk') { $form.ForceDiskFail = $true }
        elseif ($f -eq 'net') { $form.ForceNetFail = $true }
    }
    $form.Show()
    for ($k = 0; $k -lt 3; $k++) { Start-Sleep -Milliseconds 1000; $form.SampleNow() }
    $form.Settle()
    $form.Relayout()
    [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($Snapshot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ("snapshot {0}x{1} -> {2}" -f $form.Width, $form.Height, $Snapshot)
    # One parseable line for the tests.
    Write-Output ("state hidden={0} opacity={1} topmost={2} interval={3} compact={4} locked={5} smoothing={6} failed={7} ramfailed={8} diskfailed={9} netfailed={10} width={11} height={12}" -f (@($form.Hidden) -join ','), $form.Opacity, $form.TopMost, $form.Interval, $form.Compact, $form.Locked, $Cfg.Smoothing, $form.FailedCores(), $form.RamFailed, $form.DiskFailed, $form.NetFailed, $form.Width, $form.Height)
    # Every hover region and its text, one line each.
    foreach ($k in $form.TipKeys()) { Write-Output ("tip {0}: {1}" -f $k, ($form.TipFor($k) -replace "`n", ' | ')) }
    $form.Close()
    return
}

Update-Anchor
$form.StartSampling()
$form.add_FormClosed({ Save-Window; try { $mutex.ReleaseMutex() } catch { } })
[System.Windows.Forms.Application]::Run($form)
