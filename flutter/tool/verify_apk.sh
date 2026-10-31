#!/usr/bin/env bash
# Compare the APK on the device with the one just built.
#
# The UI dump kept showing keycaps after a successful install, which means one
# of two things: the build did not reach the device, or the device is running a
# stale copy. Hashing both sides answers that without guessing.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
PKG="dev.lexumo.lexumo"
LOCAL_APK="build/app/outputs/apk/release/app-release.apk"

ensure() {
  for _ in $(seq 1 25); do
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

LOCAL_MD5=$(md5sum "$LOCAL_APK" | cut -d' ' -f1)
echo "local   : $LOCAL_MD5  ($(stat -c%s "$LOCAL_APK") bytes)"

REMOTE_PATH=$("$ADB" -s emulator-5554 shell pm path "$PKG" 2>/dev/null | tr -d '\r' | sed 's/^package://')
echo "remote  : $REMOTE_PATH"

REMOTE_MD5=$("$ADB" -s emulator-5554 shell md5sum "$REMOTE_PATH" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
echo "remote  : $REMOTE_MD5"

if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
  echo "RESULT: device runs the freshly built APK"
else
  echo "RESULT: device is running a DIFFERENT apk"
fi
