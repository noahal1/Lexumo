#!/usr/bin/env bash
# Screenshot each page on the phone emulator.
#
# Same adb-transport flakiness as the other tools here, so every capture retries.
# The bottom tab bar's five slots sit at 10/30/50/70/90% of the width, just above
# the gesture strip at 96% of the height.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
OUTDIR="${1:-.shots/shots}"
mkdir -p "$OUTDIR"

adb_retry() {
  for _ in $(seq 1 25); do
    local st
    st=$("$ADB" -s emulator-5554 get-state 2>/dev/null | tr -d '\r' | tail -1)
    if [ "$st" = "device" ] && "$ADB" -s emulator-5554 "$@" 2>/dev/null; then
      return 0
    fi
    "$ADB" kill-server >/dev/null 2>&1
    sleep 1
    "$ADB" start-server >/dev/null 2>&1
    sleep 3
  done
  return 1
}

SIZE=$(adb_retry shell wm size | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | tail -1)
W=${SIZE%x*}; H=${SIZE#*x}
TAB_Y=$(( H * 96 / 100 ))

shoot() {  # name index
  local name=$1 idx=$2
  if [ "$idx" -gt 0 ]; then
    adb_retry shell input tap $(( W * (2 * idx + 1) / 10 )) "$TAB_Y" >/dev/null
    sleep 2
  fi
  for _ in 1 2 3 4; do
    if adb_retry exec-out screencap -p > "$OUTDIR/$name.png"; then
      echo "$OUTDIR/$name.png ($(stat -c%s "$OUTDIR/$name.png") bytes)"
      return 0
    fi
    sleep 2
  done
  return 1
}

shoot 01-words 0
shoot 02-flashcards 1
shoot 03-quiz 2
shoot 04-stats 3
shoot 05-settings 4
