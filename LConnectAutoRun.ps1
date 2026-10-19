<#
.SYNOPSIS
    At boot, invisibly: make sure the L-Connect service is running, let L-Connect 3
    push your saved lighting/fan/LCD profiles to the hardware, then close the app.
    The service is never stopped - it runs the fan curves.

.USAGE
    Install:   double-click Install.cmd (approve the admin prompt). That's it.
    Remove:    double-click Uninstall.cmd.

    Command-line equivalents (the script asks for admin itself):
        powershell -ExecutionPolicy Bypass -File .\LConnectAutoRun.ps1 -Install
        powershell -ExecutionPolicy Bypass -File .\LConnectAutoRun.ps1 -Install -ApplySeconds 40
        powershell -ExecutionPolicy Bypass -File .\LConnectAutoRun.ps1 -Uninstall

    Install also:
      - turns off L-Connect's and OpenRGB's own "start with Windows" entries
        (re-checked every boot, in case L-Connect turns them back on)
      - keeps the L-Connect service alive: Windows restarts it if it crashes, and your
        profiles are re-applied (hidden) whenever the service restarts mid-session
      - gates OpenRGB.exe: it may only run while the L-Connect app is open, and is
        stopped when the app closes. Any other time it is blocked from launching.
    Uninstall turns all of that back on.

    Log: C:\ProgramData\LConnectAutoRun\autorun.log
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Diagnose,               # test the OpenRGB gate and write findings to the log
    [switch]$Reapply,                # set by the service-restart task: re-push profiles mid-session
    [int]$ApplySeconds = 25,         # how long L-Connect stays open to apply settings
    [int]$ServiceSettleSeconds = 10, # extra wait after the service starts, before the app opens
    [string]$LConnectPath = ""       # leave blank to auto-detect
)

$ErrorActionPreference = 'Continue'
$TaskName     = 'L-Connect Apply and Exit'
$ReapplyTask  = 'L-Connect Reapply After Service Restart'
$OldOpenTask  = 'L-Connect Open'       # from an earlier version; removed on install/uninstall
$OldShortcut  = 'Open L-Connect.lnk'   # from an earlier version; removed on install/uninstall
$InstallDir   = Join-Path $env:ProgramData 'LConnectAutoRun'
$InstalledPs1 = Join-Path $InstallDir 'LConnectAutoRun.ps1'
$LogFile      = Join-Path $InstallDir 'autorun.log'
$StateFile    = Join-Path $InstallDir 'disabled-startup.json'
$WatcherFile  = Join-Path $InstallDir 'disabled-watcher.json'
$GatedName    = 'OpenRGBGated.exe'     # copy of OpenRGB.exe the gate runs (name avoids "Connect")
$Match        = @('*L-Connect*', '*LConnect*')

function Write-Log([string]$Message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch {}
}

function Limit-Log {
    try {
        if ((Get-Item $LogFile -ErrorAction Stop).Length -gt 512KB) {
            $keep = Get-Content $LogFile -Tail 300
            Set-Content -Path $LogFile -Value $keep
        }
    } catch {}
}

function Wait-ForEnter {
    Write-Host ''
    Read-Host 'Press Enter to close' | Out-Null
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LConnectName([string]$Text) {
    foreach ($m in $Match) { if ($Text -like $m) { return $true } }
    return $false
}

# Autostart entries to turn off: L-Connect's plus the bundled OpenRGB
function Test-AutostartName([string]$Text) {
    return (Test-LConnectName $Text) -or ($Text -like '*OpenRGB*')
}

function Find-Exe {
    param([string]$Explicit, [string[]]$Candidates, [string]$Pattern, [string[]]$Exclude)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    foreach ($c in $Candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) |
             Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        $hit = Get-ChildItem -Path $r -Filter $Pattern -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
               Where-Object { $n = $_.Name; -not ($Exclude | Where-Object { $n -like $_ }) } |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-LConnect {
    Find-Exe -Explicit $LConnectPath -Pattern 'L-Connect*.exe' `
        -Exclude @('*unins*', '*uninstall*', '*service*', '*watch*', '*update*') `
        -Candidates @(
            (Join-Path $env:ProgramFiles 'L-Connect 3\L-Connect 3.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'L-Connect 3\L-Connect 3.exe')
        )
}

# The bundled OpenRGB.exe: look inside the L-Connect folder first, then Program Files
function Find-OpenRGB {
    $lc = Find-LConnect
    if ($lc) {
        $hit = Get-ChildItem -Path (Split-Path $lc) -Filter 'OpenRGB.exe' -Recurse -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    Find-Exe -Pattern 'OpenRGB.exe' -Exclude @() -Candidates @()
}

function Get-LConnectServices {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { (Test-LConnectName $_.Name) -or (Test-LConnectName $_.DisplayName) }
}

function Test-Watcher($Svc) {
    foreach ($m in @('*watcher*', '*watchdog*')) {
        if ($Svc.Name -like $m -or $Svc.DisplayName -like $m) { return $true }
    }
    return $false
}

# Earlier versions disabled the service watcher; put it back the way it was.
function Restore-Watcher {
    if (-not (Test-Path $WatcherFile)) { return }
    foreach ($w in (Get-Content $WatcherFile -Raw | ConvertFrom-Json)) {
        Set-Service -Name $w.Name -StartupType $w.StartType -ErrorAction SilentlyContinue
        if ($w.StartType -eq 'Automatic') { Start-Service -Name $w.Name -ErrorAction SilentlyContinue }
        Write-Host "Restored service watcher: $($w.Name) ($($w.StartType))"
    }
    Remove-Item $WatcherFile -Force
}

# The app's processes only, never the service's or watcher's (so we don't mistake
# them for the app, or kill them)
function Get-LConnectProcesses {
    $svcPids = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { (Test-LConnectName $_.Name) -or (Test-LConnectName $_.DisplayName) } |
        ForEach-Object { $_.ProcessId })
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { (Test-LConnectName $_.ProcessName) -and
                       ($_.ProcessName -notlike '*service*') -and
                       ($_.ProcessName -notlike '*watch*') -and
                       ($svcPids -notcontains $_.Id) }
}

# Make sure the service is up before the app is launched, otherwise the app opens
# without loading its profiles.
function Start-LConnectService([int]$SettleSeconds) {
    $svcs = @(Get-LConnectServices | Where-Object { -not (Test-Watcher $_) })
    if (-not $svcs) { Write-Log 'No L-Connect service found.'; return }
    $started = $false
    foreach ($svc in $svcs) {
        if ($svc.StartType -eq 'Disabled') {
            Write-Log "Service '$($svc.Name)' is set to Disabled in services.msc, so it can't start. Set it to Automatic."
            continue
        }
        if ($svc.Status -ne 'Running') {
            Write-Log "Starting service: $($svc.Name)"
            Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
            $started = $true
        }
        try {
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
            Write-Log "Service running: $($svc.Name)"
        } catch {
            Write-Log "Service '$($svc.Name)' did not reach Running within 60 s."
        }
    }
    if ($started -and $SettleSeconds -gt 0) {
        Write-Log "Giving the service $SettleSeconds s to finish starting..."
        Start-Sleep -Seconds $SettleSeconds
    }
}

# ---- L-Connect's and OpenRGB's autostart entries (the same switches as Task Manager > Startup apps)
$Approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$RunSources = @(
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKCU:\$Approved\Run" },
    @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$Approved\Run" },
    @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$Approved\Run32" }
)
$FolderSources = @(
    @{ Dir = [Environment]::GetFolderPath('Startup');       Approved = "HKCU:\$Approved\StartupFolder" },
    @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$Approved\StartupFolder" }
)

function Set-StartupApproved([string]$ApprovedKey, [string]$Name, [bool]$Enabled) {
    # 12-byte value: first byte 2 = enabled, 3 = disabled
    $bytes = [byte[]](@($(if ($Enabled) { 2 } else { 3 })) + (,0 * 11))
    if (-not (Test-Path $ApprovedKey)) { New-Item -Path $ApprovedKey -Force | Out-Null }
    New-ItemProperty -Path $ApprovedKey -Name $Name -PropertyType Binary -Value $bytes -Force | Out-Null
}

function Disable-LConnectAutostart {
    $changed = @()
    foreach ($src in $RunSources) {
        if (-not (Test-Path $src.Key)) { continue }
        $props = Get-ItemProperty -Path $src.Key
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ((Test-AutostartName $p.Name) -or (Test-AutostartName ([string]$p.Value))) {
                Set-StartupApproved $src.Approved $p.Name $false
                $changed += @{ Kind = 'Approved'; Key = $src.Approved; Name = $p.Name }
                Write-Log "Turned off startup entry: $($p.Name)"
            }
        }
    }
    foreach ($src in $FolderSources) {
        if (-not ($src.Dir -and (Test-Path $src.Dir))) { continue }
        foreach ($f in Get-ChildItem -Path $src.Dir -File -ErrorAction SilentlyContinue) {
            if (Test-AutostartName $f.Name) {
                Set-StartupApproved $src.Approved $f.Name $false
                $changed += @{ Kind = 'Approved'; Key = $src.Approved; Name = $f.Name }
                Write-Log "Turned off startup shortcut: $($f.Name)"
            }
        }
    }
    foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        if ($t.TaskName -in @($TaskName, $ReapplyTask, $OldOpenTask) -or $t.State -eq 'Disabled') { continue }
        if ((Test-AutostartName $t.TaskName) -or ($t.Actions | Where-Object { Test-AutostartName ([string]$_.Execute) })) {
            Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-Null
            $changed += @{ Kind = 'Task'; Name = $t.TaskName; Path = $t.TaskPath }
            Write-Log "Turned off startup task: $($t.TaskName)"
        }
    }
    # Merge with what earlier runs recorded, so Uninstall can restore everything
    $old = @()
    if (Test-Path $StateFile) { $raw = Get-Content $StateFile -Raw; if ($raw) { $old = @($raw | ConvertFrom-Json) } }
    $all = @(@($old) + @($changed | ForEach-Object { [pscustomobject]$_ }) | Sort-Object Kind, Key, Name -Unique)
    if ($all) { ConvertTo-Json -InputObject $all -Depth 3 | Set-Content -Path $StateFile }
    elseif (-not (Test-Path $StateFile)) { Write-Host "No L-Connect/OpenRGB startup entries found (nothing to turn off)." }
}

function Restore-LConnectAutostart {
    if (-not (Test-Path $StateFile)) { return }
    $raw = Get-Content $StateFile -Raw
    $items = if ($raw) { $raw | ConvertFrom-Json } else { @() }
    foreach ($c in $items) {
        if ($c.Kind -eq 'Approved') { Set-StartupApproved $c.Key $c.Name $true; Write-Host "Turned back on: $($c.Name)" }
        if ($c.Kind -eq 'Task') {
            Enable-ScheduledTask -TaskName $c.Name -TaskPath $c.Path -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Turned back on: $($c.Name)"
        }
    }
    Remove-Item $StateFile -Force
}

# ---- OpenRGB gate.
# Windows "Image File Execution Options" makes every launch of OpenRGB.exe run the gate
# instead. The gate is a tiny windowless program compiled on this PC at install (so it
# works whether a 32- or 64-bit program launches OpenRGB, and nothing flashes). It starts
# a copy of OpenRGB (OpenRGBGated.exe, a name the redirect doesn't apply to) only while
# the L-Connect app is open, and stops it when the app closes.
$GateExe     = Join-Path $InstallDir 'OpenRGBGate.exe'
$OldGatePs1  = Join-Path $InstallDir 'OpenRGBGate.ps1'   # from an earlier version
$IfeoKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\OpenRGB.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\OpenRGB.exe'
)
$GateDebugger = "`"$GateExe`""

$GateSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// Written by LConnectAutoRun. Windows runs this instead of OpenRGB.exe.
// OpenRGB may only run while the L-Connect app is open; it is stopped when the app closes.
public static class OpenRGBGate
{
    const string GatedName = "OpenRGBGated.exe";
    static readonly string LogFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "LConnectAutoRun\\autorun.log");

    static void Log(string message)
    {
        try { File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  [gate] " + message + Environment.NewLine); }
        catch { }
    }

    // The L-Connect app is open (its service and watcher don't count)
    static bool IsLConnectAppOpen()
    {
        foreach (Process p in Process.GetProcesses())
        {
            string n = p.ProcessName.ToLowerInvariant();
            if ((n.Contains("l-connect") || n.Contains("lconnect")) && !n.Contains("service") && !n.Contains("watch"))
                return true;
        }
        return false;
    }

    // Splits a program path off the front of a command line; returns the rest
    static string SplitExe(string s, out string exe)
    {
        s = s.TrimStart();
        int next;
        if (s.StartsWith("\""))
        {
            int q = s.IndexOf('"', 1);
            if (q < 0) { exe = s.Trim('"'); return ""; }
            exe = s.Substring(1, q - 1);
            next = q + 1;
        }
        else
        {
            int e = s.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
            int sp = s.IndexOf(' ');
            next = e >= 0 ? e + 4 : (sp >= 0 ? sp : s.Length);
            exe = s.Substring(0, next);
        }
        return next >= s.Length ? "" : s.Substring(next).Trim();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessBasicInfo
    {
        public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, ParentProcessId;
    }

    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr process, int infoClass, ref ProcessBasicInfo info, int size, out int returned);

    static string Launcher()
    {
        try
        {
            ProcessBasicInfo info = new ProcessBasicInfo();
            int returned;
            if (NtQueryInformationProcess(Process.GetCurrentProcess().Handle, 0, ref info, Marshal.SizeOf(info), out returned) != 0)
                return "?";
            int pp = info.ParentProcessId.ToInt32();
            try { return Process.GetProcessById(pp).ProcessName + ".exe (pid " + pp + ")"; }
            catch { return "pid " + pp; }
        }
        catch { return "?"; }
    }

    static bool IsAlive(Process p)
    {
        try { return !p.HasExited; }
        catch { return Process.GetProcessesByName(Path.GetFileNameWithoutExtension(GatedName)).Length > 0; }
    }

    public static int Main()
    {
        string self, exe;
        string rest = SplitExe(Environment.CommandLine, out self);   // skip ourselves
        rest = SplitExe(rest, out exe);                              // the OpenRGB.exe that was asked for
        if (exe.Length == 0) { Log("Called without a program path."); return 1; }

        string who = Launcher();
        if (!IsLConnectAppOpen())
        {
            Log("Blocked OpenRGB launch from " + who + " (L-Connect app not open)");
            return 0;
        }
        Log("OpenRGB launch from " + who + " allowed (L-Connect app open). Args: " + rest);

        // Keep the copy current (L-Connect updates replace OpenRGB.exe). Needs admin;
        // without it, use the existing copy.
        string dir = Path.GetDirectoryName(exe);
        string gated = Path.Combine(dir, GatedName);
        try
        {
            FileInfo src = new FileInfo(exe), dst = new FileInfo(gated);
            if (src.Exists && (!dst.Exists || dst.Length != src.Length || dst.LastWriteTimeUtc != src.LastWriteTimeUtc))
            {
                File.Copy(exe, gated, true);
                Log("Refreshed " + GatedName);
            }
        }
        catch (Exception ex)
        {
            if (!File.Exists(gated))
            {
                Log("Can't run OpenRGB: " + GatedName + " is missing (" + ex.Message + "). Reboot once to recreate it.");
                return 1;
            }
        }

        // Reuse a copy that's already running rather than starting a second one
        Process p;
        Process[] running = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(GatedName));
        if (running.Length > 0)
        {
            p = running[0];
            Log(GatedName + " already running (pid " + p.Id + "); waiting on it");
        }
        else
        {
            ProcessStartInfo psi = new ProcessStartInfo(gated, rest);
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            try { p = Process.Start(psi); }
            catch (Exception ex) { Log("Failed to start " + gated + ": " + ex.Message); return 1; }
            Log("Started " + GatedName + " (pid " + p.Id + ")");
        }

        // Stay alive while OpenRGB runs (whoever launched it may be waiting on us);
        // stop it when L-Connect closes
        while (IsAlive(p))
        {
            if (!IsLConnectAppOpen())
            {
                Log("L-Connect closed: stopping OpenRGB.");
                try { p.Kill(); } catch { }
                break;
            }
            Thread.Sleep(3000);
        }
        return 0;
    }
}
'@

# Compile the gate program (a fresh PowerShell does it, so a rebuild never clashes
# with an already-loaded copy)
function Build-OpenRGBGate {
    Get-Process -Name 'OpenRGBGate' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $GateExe -Force -ErrorAction SilentlyContinue
    $src = Join-Path $env:TEMP 'OpenRGBGate.cs'
    Set-Content -Path $src -Value $GateSource -Encoding UTF8
    $cmd = "Add-Type -Path '$src' -OutputAssembly '$GateExe' -OutputType WindowsApplication"
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1
    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if (Test-Path $GateExe) { Write-Log "Built $GateExe"; return $true }
    Write-Log "Couldn't build the OpenRGB gate: $out"
    return $false
}

# Build the gate if needed, refresh the OpenRGB copy, and point OpenRGB.exe launches at
# the gate. Safe to run repeatedly (install and every boot).
function Set-OpenRGBGate([switch]$Quiet, [switch]$Rebuild) {
    Remove-Item -LiteralPath $OldGatePs1 -Force -ErrorAction SilentlyContinue
    if ($Rebuild -or -not (Test-Path $GateExe)) {
        if (-not (Build-OpenRGBGate)) {
            Write-Host 'OpenRGB stays blocked (the gate could not be built). See the log: C:\ProgramData\LConnectAutoRun\autorun.log' -ForegroundColor Yellow
        }
    }
    # Even if the build failed, point launches at the gate: a missing gate just means "blocked"
    foreach ($k in $IfeoKeys) {
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        New-ItemProperty -Path $k -Name 'Debugger' -Value $GateDebugger -PropertyType String -Force | Out-Null
    }
    $orgb = Find-OpenRGB
    if ($orgb) {
        $dst = Join-Path (Split-Path $orgb) $GatedName
        $s = Get-Item -LiteralPath $orgb
        $d = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue
        if (-not $d -or $d.Length -ne $s.Length -or $d.LastWriteTimeUtc -ne $s.LastWriteTimeUtc) {
            try { Copy-Item -LiteralPath $orgb -Destination $dst -Force -ErrorAction Stop; Write-Log "Prepared $dst" }
            catch { Write-Log "Couldn't copy OpenRGB to $dst (in use?). It will be retried next boot." }
        }
    } elseif (-not $Quiet) {
        Write-Log 'OpenRGB.exe not found yet; the gate will still block it, and set itself up when found.'
    }
    # A plain OpenRGB.exe that's already running bypassed the gate - stop it
    Get-Process -Name 'OpenRGB' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host 'OpenRGB now only runs while the L-Connect app is open.' }
}

function Remove-OpenRGBGate {
    foreach ($k in $IfeoKeys) {
        if (-not (Test-Path $k)) { continue }
        Remove-ItemProperty -Path $k -Name 'Debugger' -ErrorAction SilentlyContinue
        if (-not (Get-Item $k).Property -and -not (Get-ChildItem $k)) { Remove-Item $k -Force }
    }
    foreach ($n in @('OpenRGBGate', [IO.Path]::GetFileNameWithoutExtension($GatedName))) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    $orgb = Find-OpenRGB
    if ($orgb) { Remove-Item -LiteralPath (Join-Path (Split-Path $orgb) $GatedName) -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $GateExe, $OldGatePs1 -Force -ErrorAction SilentlyContinue
    Write-Host 'OpenRGB is no longer gated.'
}

# An earlier version locked this folder down so tightly that the installer couldn't
# update its own files ("Access ... is denied"). Take ownership back and reset every
# file here to the folder's normal inherited permissions. Harmless on a healthy folder.
function Repair-InstallDir {
    if (-not (Test-Path $InstallDir)) { return }
    & takeown.exe /f $InstallDir /r /d y 2>&1 | Out-Null
    & icacls.exe $InstallDir /reset /t /q 2>&1 | Out-Null
}

# The gate runs with whatever rights launched OpenRGB (possibly a non-elevated token),
# so let ordinary users append to the log. Nothing else in the folder is opened up.
function Initialize-Log {
    if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
    & icacls.exe $LogFile /grant '*S-1-5-32-545:M' /Q 2>&1 | Out-Null
}

# If the L-Connect service crashes, Windows restarts it (5 s, 5 s, then 30 s)
function Set-ServiceRecovery {
    foreach ($svc in Get-LConnectServices | Where-Object { -not (Test-Watcher $_) }) {
        & sc.exe failure $svc.Name reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
        Write-Host "Service $($svc.Name) will restart itself if it crashes."
    }
}

# Whenever the L-Connect service stops or starts mid-session, re-apply the profiles
# (hidden, same as at boot). Without this, a service restart leaves the fans on the
# hub's default curve until the next reboot.
function Register-ReapplyTask($Settings, $Principal, [string[]]$BaseArgs) {
    $svc = Get-LConnectServices | Where-Object { -not (Test-Watcher $_) } | Select-Object -First 1
    if (-not $svc) { Write-Host 'No L-Connect service found; skipping the service-restart task.'; return }
    $name = [Security.SecurityElement]::Escape($svc.DisplayName)
    $xpath = "*[System[Provider[@Name='Service Control Manager'] and EventID=7036]] and *[EventData[Data[@Name='param1']='$name']]"
    $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName MSFT_TaskEventTrigger
    $trigger = New-CimInstance -CimClass $cls -ClientOnly
    $trigger.Enabled = $true
    $trigger.Delay = 'PT20S'
    $trigger.Subscription = "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">$xpath</Select></Query></QueryList>"
    $args2 = $BaseArgs + '-Reapply'
    Register-ScheduledTask -TaskName $ReapplyTask -Force -Settings $Settings -Trigger $trigger `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($args2 -join ' ')) `
        -Principal $Principal -ErrorAction Stop | Out-Null
    Write-Host "Profiles will be re-applied automatically if '$($svc.DisplayName)' restarts."
}

function Remove-OldVersionLeftovers {
    Unregister-ScheduledTask -TaskName $OldOpenTask -Confirm:$false -ErrorAction SilentlyContinue
    @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) |
        Where-Object { $_ } | ForEach-Object { Join-Path $_ $OldShortcut } |
        Where-Object { Test-Path $_ } | Remove-Item -Force
}

# ---- Install/Uninstall need admin: ask for it instead of failing
if (($Install -or $Uninstall -or $Diagnose) -and -not (Test-Admin)) {
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Install)      { $fwd += '-Install' }
    if ($Uninstall)    { $fwd += '-Uninstall' }
    if ($Diagnose)     { $fwd += '-Diagnose' }
    if ($PSBoundParameters.ContainsKey('ApplySeconds'))         { $fwd += @('-ApplySeconds', $ApplySeconds) }
    if ($PSBoundParameters.ContainsKey('ServiceSettleSeconds')) { $fwd += @('-ServiceSettleSeconds', $ServiceSettleSeconds) }
    if ($LConnectPath) { $fwd += @('-LConnectPath', "`"$LConnectPath`"") }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList ($fwd -join ' ') -ErrorAction Stop }
    catch { Write-Host 'Admin permission was declined, so nothing was changed.'; Start-Sleep -Seconds 4 }
    exit
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# ---------------------------------------------------------------- diagnose
if ($Diagnose) {
    Add-Type -Namespace LCAR -Name Native -MemberDefinition '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool IsWow64Process(IntPtr hProcess, out bool wow64);'
    function Get-Bitness($ProcId) {
        try { $w = $false; [void][LCAR.Native]::IsWow64Process((Get-Process -Id $ProcId).Handle, [ref]$w); if ($w) { '32-bit' } else { '64-bit' } }
        catch { 'bitness ?' }
    }
    function Write-Procs([string]$Title) {
        Write-Log $Title
        Get-CimInstance Win32_Process | Where-Object {
            $_.Name -match 'Connect|OpenRGB' -or ($_.CommandLine -match 'OpenRGBGate') } |
        ForEach-Object {
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)").Name
            Write-Log ("  {0} pid={1} {2} parent={3} cmd={4}" -f $_.Name, $_.ProcessId, (Get-Bitness $_.ProcessId), $parent, $_.CommandLine)
        }
    }

    Write-Log '----- diagnose -----'
    Write-Log "Windows: $([Environment]::OSVersion.VersionString) build $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild)"
    foreach ($k in $IfeoKeys) {
        Write-Log "IFEO $($k.Split('\')[2]): $((Get-ItemProperty -Path $k -Name Debugger -ErrorAction SilentlyContinue).Debugger)"
    }
    Write-Log "Expected : $GateDebugger"
    Write-Log "Gate program: $(Test-Path $GateExe)"
    $orgb = Find-OpenRGB
    Write-Log "OpenRGB.exe: $orgb"
    if ($orgb) { Write-Log "Gated copy present: $(Test-Path (Join-Path (Split-Path $orgb) $GatedName))" }
    $appOpen = [bool](Get-LConnectProcesses)
    Write-Log "L-Connect app open: $appOpen"
    if (-not $appOpen) { Write-Host 'Note: L-Connect is not open, so the tests should show OpenRGB being blocked.' -ForegroundColor Yellow }
    Write-Procs 'Processes now:'

    if ($orgb) {
        Write-Log 'Test 1: launching OpenRGB.exe from a 64-bit process...'
        try { Start-Process -FilePath $orgb -ErrorAction Stop } catch { Write-Log "  Test 1 error: $($_.Exception.Message)" }
        Start-Sleep -Seconds 8
        Write-Procs 'Processes after test 1:'

        $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $ps32) {
            Write-Log 'Test 2: launching OpenRGB.exe from a 32-bit process...'
            $out = & $ps32 -NoProfile -Command "Start-Process -FilePath '$orgb'" 2>&1
            if ($out) { Write-Log "  Test 2 error: $out" }
            Start-Sleep -Seconds 8
            Write-Procs 'Processes after test 2:'
        }
    }
    Write-Log '----- diagnose done -----'
    Write-Host ''
    Write-Host 'Done. The results are in C:\ProgramData\LConnectAutoRun\autorun.log'
    Wait-ForEnter
    exit 0
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Repair-InstallDir
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $ReapplyTask -Confirm:$false -ErrorAction SilentlyContinue
    Remove-OldVersionLeftovers
    Restore-LConnectAutostart
    Restore-Watcher
    Remove-OpenRGBGate
    Remove-Item -LiteralPath $InstalledPs1 -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Removed. L-Connect and OpenRGB will start with Windows again. Log left at $LogFile."
    Wait-ForEnter
    exit 0
}

# ---------------------------------------------------------------- install
if ($Install) {
    Repair-InstallDir
    if ($PSCommandPath -ne $InstalledPs1) {
        try { Copy-Item -Path $PSCommandPath -Destination $InstalledPs1 -Force -ErrorAction Stop }
        catch {
            Write-Host "Couldn't copy the script into $InstallDir : $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'Nothing else was changed.'
            Wait-ForEnter
            exit 1
        }
    }
    Initialize-Log

    $argList = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                 '-File', "`"$InstalledPs1`"", '-ApplySeconds', $ApplySeconds, '-ServiceSettleSeconds', $ServiceSettleSeconds)
    if ($LConnectPath) { $argList += @('-LConnectPath', "`"$LConnectPath`"") }

    $user     = "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

    # S4U = runs as you at boot, before logon, in a background session with no window,
    # without storing your password (and it uses your saved L-Connect profiles)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'   # give USB devices time to come up
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName $TaskName -Force -Settings $settings -Trigger $trigger `
            -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')) `
            -Principal $principal -ErrorAction Stop | Out-Null
        Register-ReapplyTask $settings $principal $argList
    } catch {
        Write-Host "Couldn't create the boot task: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Nothing else was changed.'
        Wait-ForEnter
        exit 1
    }

    Remove-OldVersionLeftovers
    Disable-LConnectAutostart
    Restore-Watcher        # an earlier version disabled it; it restarts the service if it dies
    Set-ServiceRecovery
    Set-OpenRGBGate -Rebuild

    # An earlier version stopped the service; bring it back now so the fans calm down
    Start-LConnectService 0

    Write-Host ""
    Write-Host "Installed. From the next boot, L-Connect applies your profiles invisibly and closes itself."
    Write-Host "The L-Connect service keeps running for the fans. Open L-Connect normally any time;"
    Write-Host "OpenRGB runs while it's open and stops when you close it."
    Wait-ForEnter
    exit 0
}

# ---------------------------------------------------------------- boot run
Limit-Log

# Only one apply at a time (boot and service-restart runs can coincide)
$applyMutex = New-Object Threading.Mutex($false, 'Global\LConnectAutoRunApply')
try { $gotMutex = $applyMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) { Write-Log 'Another apply run is in progress; skipping this one.'; exit 0 }

if ($Reapply) {
    Write-Log '----- reapply (L-Connect service restarted) -----'
    if (Get-LConnectProcesses) { Write-Log 'L-Connect app is open, so it handles the profiles; nothing to do.'; exit 0 }
} else {
    Write-Log '----- run start -----'
}
if (-not (Test-Admin)) { Write-Log 'Not elevated: starting the service may fail. Use Install.cmd.' }

# 0. Re-apply: keep L-Connect / OpenRGB from starting on their own (L-Connect may re-add
#    them) and keep the OpenRGB gate in place (L-Connect updates may replace OpenRGB.exe)
Disable-LConnectAutostart
Set-OpenRGBGate -Quiet

# 1. Service first, and wait until it's ready (the app needs it to load profiles)
Start-LConnectService $ServiceSettleSeconds

# 2. Launch L-Connect hidden if it isn't already running
$lconnect = Find-LConnect
if (-not (Get-LConnectProcesses)) {
    if ($lconnect) {
        Write-Log "Launching: $lconnect"
        Start-Process -FilePath $lconnect -WindowStyle Hidden
    } else {
        Write-Log 'L-Connect 3 not found. Reinstall with -LConnectPath "C:\path\to\L-Connect 3.exe".'
    }
} else {
    Write-Log 'L-Connect already running; reusing it.'
}

# 3. Give it time to detect devices and push profiles (OpenRGB is allowed meanwhile)
Write-Log "Waiting $ApplySeconds s for profiles to apply..."
Start-Sleep -Seconds $ApplySeconds

# 4. Close the app (polite close first, then force anything left in the tray).
#    The service is left running - it handles the fan curves.
foreach ($p in Get-LConnectProcesses) { try { [void]$p.CloseMainWindow() } catch {} }
Start-Sleep -Seconds 5
foreach ($p in Get-LConnectProcesses) {
    Write-Log "Closing app process: $($p.ProcessName) ($($p.Id))"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}

# 5. The gate stops OpenRGB within a few seconds of the app closing; clean up anything left
Start-Sleep -Seconds 4
foreach ($name in @([IO.Path]::GetFileNameWithoutExtension($GatedName), 'OpenRGB')) {
    foreach ($p in Get-Process -Name $name -ErrorAction SilentlyContinue) {
        Write-Log "Closing OpenRGB ($($p.ProcessName) $($p.Id))"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Log '----- run done -----'
