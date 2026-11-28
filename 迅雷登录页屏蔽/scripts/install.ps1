<#
.SYNOPSIS
    Builds, installs and starts XLLoginGuard for the current user.

.DESCRIPTION
    Copies the guard to %LOCALAPPDATA%\XLLoginGuard, writes guard.ini, registers it in
    HKCU\Software\Microsoft\Windows\CurrentVersion\Run and starts it right away.
    No administrator rights are required; nothing outside the user profile is touched.

.PARAMETER InstallDir
    Target folder. Default: %LOCALAPPDATA%\XLLoginGuard

.PARAMETER TitleKeyword
    Text that a Thunder window title must contain to be treated as the login window.
    Default: 登录

.PARAMETER ProcessName
    Executable name (without .exe) that owns the login window. Default: Thunder

.PARAMETER StartupGraceSeconds
    Windows that appear this many seconds after Thunder.exe started are always closed.
    Default: 25

.PARAMETER IdleThresholdMs
    After the grace period, close only when the desktop has been idle this long.
    Default: 1500

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'XLLoginGuard'),
    # U+767B U+5F55 = the Chinese word for "login"; spelled with escapes so this script
    # stays ASCII-only and survives any code page / BOM confusion.
    [string]$TitleKeyword = ([string][char]0x767B + [char]0x5F55),
    [string]$ProcessName = 'Thunder',
    [int]$StartupGraceSeconds = 25,
    [int]$IdleThresholdMs = 1500,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$root  = Split-Path -Parent $PSScriptRoot
$exe   = Join-Path $root 'bin\XLLoginGuard.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Write-Host '[1/5] Building guard...'
& (Join-Path $PSScriptRoot 'build.ps1') | Out-Null
if (-not (Test-Path $exe)) { throw "Build produced no exe: $exe" }

Write-Host '[2/5] Stopping previous instance (if any)...'
Get-Process -Name 'XLLoginGuard' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Host "[3/5] Installing to $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path $exe -Destination (Join-Path $InstallDir 'XLLoginGuard.exe') -Force

$ini = @(
    '# XLLoginGuard settings (UTF-8, key=value, # starts a comment)'
    "ProcessName=$ProcessName"
    "TitleKeyword=$TitleKeyword"
    'ClassPrefix=Chrome_WidgetWin'
    'MinWidth=200'
    'MinHeight=150'
    "StartupGraceSeconds=$StartupGraceSeconds"
    "IdleThresholdMs=$IdleThresholdMs"
    'PollIntervalMs=400'
)
$iniPath = Join-Path $InstallDir 'guard.ini'
[System.IO.File]::WriteAllLines($iniPath, $ini, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '[4/5] Registering autostart (HKCU Run)...'
$runValue = '"{0}"' -f (Join-Path $InstallDir 'XLLoginGuard.exe')
Set-ItemProperty -Path $runKey -Name 'XLLoginGuard' -Value $runValue -Type String

Write-Host '[5/5] Starting guard...'
if (-not $NoStart) {
    # Launch through explorer.exe so the guard never inherits an elevated token.
    Start-Process -FilePath 'explorer.exe' -ArgumentList $runValue -WindowStyle Hidden
    Start-Sleep -Seconds 1
}

$running = @(Get-Process -Name 'XLLoginGuard' -ErrorAction SilentlyContinue)
Write-Host ''
if ($running.Count -gt 0) {
    Write-Host ('Guard is running (pid {0}).' -f $running[0].Id)
} elseif ($NoStart) {
    Write-Host 'Guard installed but not started (-NoStart).'
} else {
    throw 'Guard did not start. Check Event Viewer or run it manually to see the error.'
}

Write-Host ("Log file: {0}" -f (Join-Path $InstallDir 'guard.log'))
Write-Host 'Done. The next Thunder login popup will be closed automatically.'
