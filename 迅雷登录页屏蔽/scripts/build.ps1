<#
.SYNOPSIS
    Compiles src\XLLoginGuard.cs into bin\XLLoginGuard.exe using the .NET Framework
    compiler that ships with every Windows 10/11 installation (no SDK, no NuGet).

.DESCRIPTION
    Works in Windows PowerShell 5.1 and PowerShell 7+. Requires no administrator rights.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'src\XLLoginGuard.cs'
$binDir = Join-Path $root 'bin'
$target = Join-Path $binDir 'XLLoginGuard.exe'

if (-not (Test-Path $source)) {
    throw "Source file not found: $source"
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

if ((Test-Path $target) -and -not $Force) {
    $outTime = (Get-Item $target).LastWriteTimeUtc
    if ($outTime -ge (Get-Item $source).LastWriteTimeUtc) {
        Write-Host "Up to date: $target"
        return Get-Item $target
    }
}

$candidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    throw 'Cannot find csc.exe (.NET Framework 4.x). XLLoginGuard needs .NET Framework 4.0 or newer.'
}

& $csc /nologo /target:winexe /optimize+ "/out:$target" $source
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed (csc exit code $LASTEXITCODE)."
}

Write-Host ("Built {0} ({1:N0} bytes)" -f $target, (Get-Item $target).Length)
Get-Item $target
