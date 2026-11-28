<#
.SYNOPSIS
    Stops and removes XLLoginGuard (autostart entry and files).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1

.EXAMPLE
    # Remove the autostart entry and stop the guard, but keep the files and log:
    powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -KeepFiles
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'XLLoginGuard'),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

$running = @(Get-Process -Name 'XLLoginGuard' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Write-Host ('Stopped {0} guard process(es).' -f $running.Count)
}

if (Test-Path $runKey) {
    if ($null -ne (Get-ItemProperty -Path $runKey -Name 'XLLoginGuard' -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $runKey -Name 'XLLoginGuard' -ErrorAction SilentlyContinue
        Write-Host 'Removed autostart entry.'
    }
}

if ($KeepFiles) {
    Write-Host "Files kept in $InstallDir"
} elseif (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $InstallDir"
}

Write-Host 'Uninstalled.'
