#!/usr/bin/env bash
# Grab one screenshot, retrying until adb cooperates.
#
# `exec-out screencap -p` truncates to 0 bytes whenever the adb server is
# recycled mid-stream, so this retries and writes via a temp file, only
# replacing the target once a plausible PNG (>10 KB) is on disk.
set -u
ADB="/c/Users/noaha/AppData/Local/Android/Sdk/platform-tools/adb.exe"
SER=emulator-5554
OUT=${1:?usage: shot.sh <out.png> [tapX tapY]}
X=${2:-}
Y=${3:-}

arm() {
  "$ADB" start-server >/dev/null 2>&1
  for _ in $(seq 1 25); do
    [ "$("$ADB" devices 2>/dev/null | grep "$SER" | awk '{print $2}')" = "device" ] && return 0
    sleep 2
  done
  return 1
}

if [ -n "$X" ]; then
  arm && "$ADB" -s "$SER" shell "input tap $X $Y" >/dev/null 2>&1
  sleep 3
fi

for i in 1 2 3 4 5 6; do
  arm || { sleep 3; continue; }
  tmp=$(mktemp)
  "$ADB" -s "$SER" exec-out screencap -p > "$tmp" 2>/dev/null
  size=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  if [ "$size" -gt 10000 ]; then
    mv "$tmp" "$OUT"
    echo "ok: $OUT ($size bytes, attempt $i)"
    exit 0
  fi
  rm -f "$tmp"
  sleep 4
done
echo "failed: $OUT" >&2
exit 1
