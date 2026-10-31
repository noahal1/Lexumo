#!/usr/bin/env bash
# Why won't the release APK install?
#
# The install reports "Success" and the package is then absent, which points at
# the device side rejecting it rather than the transfer failing. This collects
# the three things that would explain that: free space, whether the package
# registration survived, and the install log.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
PKG="dev.lexumo.lexumo"
LOCAL_APK="build/app/outputs/apk/release/app-release.apk"

ensure() {
  for _ in $(seq 1 40); do
    local st
    st=$("$ADB" -s emulator-5554 get-state 2>/dev/null | tr -d '\r' | tail -1)
    [ "$st" = "device" ] && return 0
    "$ADB" kill-server >/dev/null 2>&1
    sleep 1
    "$ADB" start-server >/dev/null 2>&1
    sleep 3
  done
  return 1
}

ensure || { echo "device offline" >&2; exit 1; }

echo "--- free space ---"
"$ADB" -s emulator-5554 shell df -h /data 2>/dev/null | tr -d '\r' | tail -2

echo "--- package present? ---"
"$ADB" -s emulator-5554 shell pm list packages 2>/dev/null | tr -d '\r' | grep -i lexumo || echo "(not listed)"

echo "--- install with logcat capture ---"
"$ADB" -s emulator-5554 logcat -c >/dev/null 2>&1
"$ADB" -s emulator-5554 install -r "$LOCAL_APK" 2>&1 | tr -d '\r' | tail -3
sleep 3
echo "--- installer logcat ---"
"$ADB" -s emulator-5554 logcat -d 2>/dev/null | tr -d '\r' \
  | grep -iE "PackageManager|installd|PackageInstaller|dex2oat|FATAL|INSTALL_" \
  | tail -20
