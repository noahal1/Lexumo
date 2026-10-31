#!/usr/bin/env bash
# Restart the app and dump its UI hierarchy, then report what it found.
#
# Written as a file because the emulator drops its adb transport constantly and
# the retry loop is long enough that inlining it invites quoting mistakes.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
PKG="dev.lexumo.lexumo"
OUT="${1:-.shots/ui.xml}"

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

echo "--- installed apk ---"
"$ADB" -s emulator-5554 shell pm path "$PKG" 2>/dev/null | tr -d '\r'
echo "--- restart ---"
"$ADB" -s emulator-5554 shell am force-stop "$PKG" >/dev/null 2>&1
"$ADB" -s emulator-5554 shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 7

echo "--- dump ---"
ok=0
for _ in $(seq 1 6); do
  ensure || continue
  if "$ADB" -s emulator-5554 shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 \
     && "$ADB" -s emulator-5554 pull /sdcard/ui.xml "$OUT" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" = 1 ] || { echo "dump failed" >&2; exit 1; }
echo "wrote $OUT"
