#!/usr/bin/env bash
# Uninstall then install, and prove the new APK actually landed.
#
# A streamed `adb install` reported "Success" while the device kept running an
# older, much larger debug build — the install had silently not replaced it.
# Uninstalling first removes that ambiguity: after a clean install the package
# either exists at the new size or it does not exist at all.
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

LOCAL_SIZE=$(stat -c%s "$LOCAL_APK")
echo "local apk: $LOCAL_SIZE bytes"

echo "--- uninstall ---"
"$ADB" -s emulator-5554 uninstall "$PKG" 2>&1 | tr -d '\r' | tail -1

echo "--- install ---"
for attempt in 1 2 3; do
  ensure || continue
  OUT=$("$ADB" -s emulator-5554 install -r "$LOCAL_APK" 2>&1 | tr -d '\r' | tail -2)
  echo "attempt $attempt: $OUT"
  case "$OUT" in
    *Success*) break ;;
  esac
  sleep 4
done

echo "--- verify ---"
REMOTE=$("$ADB" -s emulator-5554 shell pm path "$PKG" 2>/dev/null | tr -d '\r' | sed 's/^package://')
if [ -z "$REMOTE" ]; then
  echo "RESULT: not installed"
  exit 1
fi
REMOTE_SIZE=$("$ADB" -s emulator-5554 shell stat -c%s "$REMOTE" 2>/dev/null | tr -d '\r')
echo "remote apk: $REMOTE_SIZE bytes"
if [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ]; then
  echo "RESULT: new build is installed"
else
  echo "RESULT: size mismatch (expected $LOCAL_SIZE)"
fi
