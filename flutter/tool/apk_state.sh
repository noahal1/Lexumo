#!/usr/bin/env bash
# Is the device actually running the APK we just built?
#
# The UI dump still showed keycaps after an install that reported Success, so
# one of the two sides is stale. This checks the facts that settle it: the
# device clock (a clock skew makes lastUpdateTime unreadable), the installed
# APK's size, and a fresh install's own report.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
PKG="dev.lexumo.lexumo"
LOCAL_APK="build/app/outputs/apk/release/app-release.apk"

ensure() {
  for _ in $(seq 1 30); do
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

echo "host now      : $(date '+%Y-%m-%d %H:%M:%S')"
echo "device now    : $("$ADB" -s emulator-5554 shell date '+%Y-%m-%d %H:%M:%S' 2>/dev/null | tr -d '\r')"
echo "device tz     : $("$ADB" -s emulator-5554 shell getprop persist.sys.timezone 2>/dev/null | tr -d '\r')"
echo "local apk     : $(stat -c%s "$LOCAL_APK") bytes"

REMOTE=$("$ADB" -s emulator-5554 shell pm path "$PKG" 2>/dev/null | tr -d '\r' | sed 's/^package://')
echo "remote path   : $REMOTE"
echo "remote size   : $("$ADB" -s emulator-5554 shell stat -c%s "$REMOTE" 2>/dev/null | tr -d '\r') bytes"
echo "lastUpdate    : $("$ADB" -s emulator-5554 shell dumpsys package "$PKG" 2>/dev/null | tr -d '\r' | grep -m1 lastUpdateTime)"
