#!/usr/bin/env bash
# Dump the UI hierarchy and check it for keyboard-hint leftovers.
#
# The emulator on this machine drops its adb transport every minute or two, so
# every step is wrapped in a retry that restarts the server when the device
# goes offline. Failing loudly is better than silently analysing a stale dump.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
OUT="${1:-.shots/ui.xml}"

ensure_device() {
  for _ in $(seq 1 20); do
    local st
    st=$("$ADB" -s emulator-5554 get-state 2>/dev/null | tr -d '\r' | tail -1)
    if [ "$st" = "device" ]; then return 0; fi
    "$ADB" kill-server >/dev/null 2>&1
    sleep 1
    "$ADB" start-server >/dev/null 2>&1
    sleep 3
  done
  return 1
}

for attempt in 1 2 3 4 5 6; do
  ensure_device || { echo "device never came online" >&2; exit 1; }
  if "$ADB" -s emulator-5554 shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 \
     && "$ADB" -s emulator-5554 pull /sdcard/ui.xml "$OUT" >/dev/null 2>&1; then
    echo "dumped on attempt ${attempt}"
    "$ADB" -s emulator-5554 shell rm -f /sdcard/ui.xml >/dev/null 2>&1
    exit 0
  fi
  sleep 2
done

echo "could not dump the hierarchy after 6 attempts" >&2
exit 1
