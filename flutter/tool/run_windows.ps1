# Launches a built Flutter Windows exe, waits, and reports what really happened.
#
# Why this exists: launching the exe from bash reports bogus exit codes (127 when
# the process group is odd, 143 from `timeout`), so "the app crashed" and "the
# harness misfired" look identical. PowerShell's Start-Process gives the true
# exit code, and polling the main window handle separates "never drew a window"
# from "drew one and then died".
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/run_windows.ps1 `
#       -Exe build\windows\x64\runner\Release\lexumo.exe -Seconds 8
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [int]$Seconds = 8,
    # Redirects the data folder into the workspace: the sandbox denies writes
    # under the real %APPDATA%, so an unredirected run cannot save and looks
    # broken for the wrong reason.
    [string]$AppData,
    [switch]$KeepAlive
)

$ErrorActionPreference = 'Stop'
$exePath = (Resolve-Path $Exe).Path
$dir = Split-Path $exePath -Parent

$env:APPDATA = if ($AppData) { $AppData } else { Join-Path (Split-Path $dir -Parent) '' }
if ($AppData) {
    New-Item -ItemType Directory -Force -Path $AppData | Out-Null
    $env:APPDATA = (Resolve-Path $AppData).Path
}

Write-Output "exe     : $exePath"
Write-Output "APPDATA : $env:APPDATA"

$p = Start-Process -FilePath $exePath -WorkingDirectory $dir -PassThru `
    -RedirectStandardOutput (Join-Path $env:TEMP 'winrun.out') `
    -RedirectStandardError (Join-Path $env:TEMP 'winrun.err')

$sawWindow = $false
$elapsed = 0
while ($elapsed -lt $Seconds) {
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
    $p.Refresh()
    if ($p.HasExited) { break }
    if (-not $sawWindow -and $p.MainWindowHandle -ne 0) {
        $sawWindow = $true
        Write-Output "window  : drew one after ${elapsed}s (title='$($p.MainWindowTitle)')"
    }
}

$p.Refresh()
if ($p.HasExited) {
    $code = $p.ExitCode
    $hex = '0x{0:X8}' -f ($code -band 0xFFFFFFFF)
    Write-Output "verdict : EXITED after ${elapsed}s  code=$code ($hex)"
} else {
    Write-Output "verdict : ALIVE after ${elapsed}s (window=$sawWindow)"
    if (-not $KeepAlive) { $p.Kill(); Write-Output "         killed by harness" }
}

Write-Output '--- stderr ---'
if (Test-Path (Join-Path $env:TEMP 'winrun.err')) {
    Get-Content (Join-Path $env:TEMP 'winrun.err') | Select-Object -First 40
}
