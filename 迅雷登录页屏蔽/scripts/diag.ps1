<#
.SYNOPSIS
    Read-only diagnostic: shows Thunder processes, Thunder windows, the login-window
    candidate, the guard state and its recent log lines.

.DESCRIPTION
    Run this when the popup keeps appearing, when Thunder has been updated to a new major
    version, or when you want to adapt XLLoginGuard to another Thunder window title.
    It changes nothing.

    Typical output of interest:
      * the line starting with "LOGIN CANDIDATE" tells you which window the guard would
        close, and which title text it matched on;
      * if the real popup is not listed as a candidate, look at the window list, then set
        TitleKeyword / ClassPrefix / MinWidth / MinHeight in guard.ini accordingly and
        restart the guard (or rerun install.ps1 with -TitleKeyword '...').

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\diag.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'XLLoginGuard')
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$loginKeyword = ([string][char]0x767B + [char]0x5F55)

$windowSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class XLWindowInfo {
    public IntPtr Handle;
    public uint ProcessId;
    public string ClassName;
    public string Title;
    public int Left, Top, Width, Height;
    public bool Visible;
}

public class XLWindowProbe {
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int L, T, R, B; }

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static List<XLWindowInfo> All() {
        var list = new List<XLWindowInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            var cls = new StringBuilder(128);
            GetClassName(h, cls, cls.Capacity);
            var title = new StringBuilder(512);
            GetWindowText(h, title, title.Capacity);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            RECT r;
            GetWindowRect(h, out r);
            list.Add(new XLWindowInfo {
                Handle = h, ProcessId = pid,
                ClassName = cls.ToString(), Title = title.ToString(),
                Left = r.L, Top = r.T, Width = r.R - r.L, Height = r.B - r.T,
                Visible = IsWindowVisible(h)
            });
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

if (-not ('XLWindowProbe' -as [type])) {
    Add-Type -TypeDefinition $windowSource
}

Write-Host '=== System ==='
Write-Host ("OS      : {0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)
Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
Write-Host ("Elevated: {0}" -f ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Write-Host ''
Write-Host '=== Thunder processes ==='
$thunder = @(Get-CimInstance Win32_Process -Filter "Name='Thunder.exe'" -ErrorAction SilentlyContinue)
if ($thunder.Count -eq 0) {
    Write-Host 'Thunder.exe is not running.'
} else {
    $thunder | ForEach-Object {
        Write-Host ("  pid={0,-6} {1}" -f $_.ProcessId, $_.ExecutablePath)
    }
}

$windows = [XLWindowProbe]::All()
$thunderPids = @{}
foreach ($p in $thunder) { $thunderPids[[uint32]$p.ProcessId] = $true }

Write-Host ''
Write-Host '=== Thunder-related windows ==='
$related = $windows | Where-Object {
    $_.Visible -and ($thunderPids.ContainsKey($_.ProcessId) -or $_.ClassName -eq 'XL_ShadowWindow')
}

if (@($related).Count -eq 0) {
    Write-Host '  (none visible)'
} else {
    $related | ForEach-Object {
        $owner = '?'
        if ($thunderPids.ContainsKey($_.ProcessId)) { $owner = 'Thunder' }
        Write-Host ("  pid={0,-6} proc={1,-8} cls={2,-22} size={3}x{4,-5} title=[{5}]" -f `
            $_.ProcessId, $owner, $_.ClassName, $_.Width, $_.Height, $_.Title)
    }
}

Write-Host ''
Write-Host '=== Login-window candidates (what the guard would close) ==='
$candidates = $related | Where-Object {
    $_.ProcessId -and
    $thunderPids.ContainsKey($_.ProcessId) -and
    $_.Title.IndexOf($loginKeyword, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $_.Width -ge 200 -and $_.Height -ge 150
}
if (@($candidates).Count -eq 0) {
    Write-Host '  none right now (normal if the popup was already closed or has not appeared)'
} else {
    $candidates | ForEach-Object {
        Write-Host ("  LOGIN CANDIDATE: pid={0} size={1}x{2} class={3} title=[{4}]" -f `
            $_.ProcessId, $_.Width, $_.Height, $_.ClassName, $_.Title)
    }
}

Write-Host ''
Write-Host '=== Thunder config files seen ==='
$configPaths = @($thunder | ForEach-Object {
    if ($_.ExecutablePath) {
        Join-Path (Split-Path -Parent $_.ExecutablePath) '..\Profiles\config.json'
    }
} | Where-Object { Test-Path (Resolve-Path $_ -ErrorAction SilentlyContinue) } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique)

if ($configPaths.Count -eq 0) {
    Write-Host '  (no Profiles\config.json found next to a running Thunder.exe)'
}
foreach ($config in $configPaths) {
    $raw = [System.IO.File]::ReadAllText($config)
    $match = [regex]::Match($raw, '"LoginWndAutoShow"\s*:\s*\{[^}]*\}')
    Write-Host ("  {0}" -f $config)
    if ($match.Success) { Write-Host ("    " + ($match.Value -replace '\s+', ' ')) }
}

Write-Host ''
Write-Host '=== Guard state ==='
$guard = @(Get-Process -Name 'XLLoginGuard' -ErrorAction SilentlyContinue)
if ($guard.Count -eq 0) {
    Write-Host '  not running'
} else {
    Write-Host ("  running: {0}" -f (($guard | ForEach-Object { "pid=$($_.Id)" }) -join ', '))
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue = (Get-ItemProperty -Path $runKey -Name 'XLLoginGuard' -ErrorAction SilentlyContinue).XLLoginGuard
Write-Host ("  autostart: {0}" -f ($(if ($runValue) { $runValue } else { '(not set)' })))
$iniPath = Join-Path $InstallDir 'guard.ini'
if (Test-Path $iniPath) {
    Write-Host ("  guard.ini: {0}" -f $iniPath)
    Get-Content $iniPath -Encoding UTF8 | Where-Object { $_ -match '^\s*[^#;\s]' } | ForEach-Object { Write-Host ("    " + $_.Trim()) }
} else {
    Write-Host '  guard.ini: (not found, using built-in defaults)'
}

$logPath = Join-Path $InstallDir 'guard.log'
Write-Host ''
Write-Host '=== guard.log (last 10 lines) ==='
if (Test-Path $logPath) {
    Get-Content $logPath -Encoding UTF8 -Tail 10 | ForEach-Object { Write-Host ("  " + $_) }
} else {
    Write-Host '  (no log yet)'
}

Write-Host ''
Write-Host 'Done (read-only, nothing was changed).'
