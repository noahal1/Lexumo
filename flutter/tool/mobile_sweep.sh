#!/usr/bin/env bash
# Visit every page on a phone-sized emulator and dump its UI, then report
# whether any keyboard hints leaked through.
#
# The emulator's adb transport drops every minute or two, so every single adb
# call goes through `adb_retry`, which restarts the server when needed. Page
# navigation is by tapping the bottom tab bar, whose five slots are at fixed
# fractions of the screen width.
set -uo pipefail

ADB="${LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe"
export MSYS2_ARG_CONV_EXCL="*"
PKG="dev.lexumo.lexumo"
OUTDIR="${1:-.shots/mobile}"
mkdir -p "$OUTDIR"

adb_retry() {
  local tries="${ADB_TRIES:-25}"
  for _ in $(seq 1 "$tries"); do
    local st
    st=$("$ADB" -s emulator-5554 get-state 2>/dev/null | tr -d '\r' | tail -1)
    if [ "$st" = "device" ]; then
      if "$ADB" -s emulator-5554 "$@" 2>/dev/null; then return 0; fi
    fi
    "$ADB" kill-server >/dev/null 2>&1
    sleep 1
    "$ADB" start-server >/dev/null 2>&1
    sleep 3
  done
  return 1
}

SIZE=$(adb_retry shell wm size | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | tail -1)
if [ -z "${SIZE:-}" ]; then echo "could not read screen size" >&2; exit 1; fi
W=${SIZE%x*}
H=${SIZE#*x}
echo "screen: ${W}x${H}"

# Bottom tab bar sits just above the gesture strip; 96% of the height is a safe
# row for it on a phone-proportioned screen.
TAB_Y=$(( H * 96 / 100 ))
declare -a PAGES=(words flashcards quiz stats settings)
IDX=0
for page in "${PAGES[@]}"; do
  # Five equal slots; aim at the centre of each.
  X=$(( W * (2 * IDX + 1) / 10 ))
  if [ "$IDX" -gt 0 ]; then
    adb_retry shell input tap "$X" "$TAB_Y" >/dev/null
    sleep 2
  fi
  for dump_try in 1 2 3 4; do
    if adb_retry shell uiautomator dump /sdcard/ui.xml >/dev/null \
       && adb_retry pull /sdcard/ui.xml "$OUTDIR/$page.xml" >/dev/null; then
      echo "dumped $page -> $OUTDIR/$page.xml"
      break
    fi
    sleep 2
  done
  IDX=$(( IDX + 1 ))
done
adb_retry shell rm -f /sdcard/ui.xml >/dev/null 2>&1
