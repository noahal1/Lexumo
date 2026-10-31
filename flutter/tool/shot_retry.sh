#!/usr/bin/env bash
# Capture a screenshot of the frontmost app, retrying through the emulator's
# flaky adb transport (it drops roughly once a minute on this machine).
#
# Usage: ./tool/shot_retry.sh <output.png> [attempts]
set -u

ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
SERIAL="${SERIAL:-emulator-5554}"
OUT="${1:-/tmp/shot.png}"
ATTEMPTS="${2:-10}"
export MSYS_NO_PATHCONV=1

for i in $(seq 1 "$ATTEMPTS"); do
  state=$("$ADB" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')
  if [ "$state" != "device" ]; then
    "$ADB" reconnect offline >/dev/null 2>&1
    "$ADB" start-server >/dev/null 2>&1
    sleep 3
    continue
  fi

  if "$ADB" -s "$SERIAL" exec-out screencap -p > "$OUT" 2>/dev/null; then
    size=$(wc -c < "$OUT" 2>/dev/null || echo 0)
    if [ "$size" -gt 5000 ]; then
      echo "$OUT  $size bytes  (attempt $i)"
      exit 0
    fi
  fi
  sleep 3
done

echo "shot_retry.sh: gave up after $ATTEMPTS attempts" >&2
exit 1
