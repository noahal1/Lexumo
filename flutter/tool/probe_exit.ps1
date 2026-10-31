# Runs an exe and reports the true exit code and elapsed time.
#
# Why this exists: Start-Process -PassThru hands back a Process object whose
# ExitCode comes back $null for these short-lived GUI children, so "crashed with
# 0xC0000409" and "exited cleanly with 0" look identical (both print 0x00000000).
# Driving System.Diagnostics.Process directly keeps the native handle and gives a
# real code.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File probe_exit.ps1 `
#       -Exe path\to\app.exe -Ms 9000 [-AppData dir]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [int]$Ms = 9000,
    [string]$AppData
)

$ErrorActionPreference = 'Stop'
$exePath = (Resolve-Path $Exe).Path
$dir = Split-Path $exePath -Parent

if ($AppData) {
    New-Item -ItemType Directory -Force -Path $AppData | Out-Null
    $env:APPDATA = (Resolve-Path $AppData).Path
}
Write-Output "exe     : $exePath"
Write-Output "APPDATA : $env:APPDATA"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exePath
$psi.WorkingDirectory = $dir
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = [System.Diagnostics.Process]::Start($psi)

$exited = $proc.WaitForExit($Ms)
$sw.Stop()
$elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

if (-not $exited) {
    Write-Output "verdict : ALIVE after ${elapsed}s (window=$($proc.MainWindowHandle -ne 0))"
    $proc.Kill()
    $proc.WaitForExit()
} else {
    $raw = $proc.ExitCode
    # -band 0xFFFFFFFF keeps the sign (PowerShell -band on Int32 yields Int32), and
    # [uint32](-1073740791) throws. Adding 2^32 first puts it in range.
    $unsigned = if ($raw -lt 0) { [uint32]($raw + 4294967296) } else { [uint32]$raw }
    $hex = '0x{0:X8}' -f $unsigned
    Write-Output "verdict : EXITED after ${elapsed}s code=$raw hex=$hex"
}

Write-Output '--- stderr ---'
$errText = $proc.StandardError.ReadToEnd()
if ($errText) { ($errText -split "`n" | Select-Object -First 25) -join "`n" } else { '(empty)' }
