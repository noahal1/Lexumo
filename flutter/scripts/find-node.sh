#!/usr/bin/env bash
# Find the centre of an element by its accessibility label, then tap it.
#
# Flutter on Android exposes every label through content-desc, so a dump is
# enough to locate a control by what it says rather than by a guessed pixel.
# `find` prints "x y" for the smallest node whose label contains the needle;
# `tap` does the same and taps it. Both retry the dump because uiautomator
# intermittently resets the adb connection on this emulator.
set -u
ADB="/c/Users/noaha/AppData/Local/Android/Sdk/platform-tools/adb.exe"
SER=emulator-5554
CACHE=/tmp/lexumo-ui.xml

arm() {
  "$ADB" start-server >/dev/null 2>&1
  for _ in $(seq 1 25); do
    [ "$("$ADB" devices 2>/dev/null | grep "$SER" | awk '{print $2}')" = "device" ] && return 0
    sleep 2
  done
  return 1
}

dump() {
  for _ in 1 2 3 4 5; do
    arm || { sleep 3; continue; }
    "$ADB" -s "$SER" shell "rm -f /sdcard/u.xml" >/dev/null 2>&1
    if "$ADB" -s "$SER" shell "uiautomator dump /sdcard/u.xml" 2>&1 | grep -q "dumped to"; then
      if "$ADB" -s "$SER" shell "cat /sdcard/u.xml" > "$CACHE" 2>/dev/null \
         && [ "$(stat -c %s "$CACHE")" -gt 2000 ]; then
        return 0
      fi
    fi
    sleep 3
  done
  return 1
}

# centre <needle> — echo "x y" for the best matching node.
#
# Flutter puts the label on a leaf node and the tap target on an ancestor, so
# a plain "smallest node" pick lands on a non-clickable text node. Prefer
# clickable matches, and among those take the smallest (the button, not the
# page-wide wrapper that also inherits the label).
centre() {
  local needle=$1 hits
  hits=$(tr '<' '\n' < "$CACHE" | grep 'content-desc="' | grep -F "$needle")
  [ -n "$hits" ] || return 1

  _pick() {
    printf '%s\n' "$1" \
      | sed -n 's/.*content-desc="[^"]*".*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
      | awk '{ x=($1+$3)/2; y=($2+$4)/2; area=($3-$1)*($4-$2); print area, x, y }' \
      | sort -n | head -1 | awk '{ printf "%d %d\n", $2, $3 }'
  }

  local clickable
  clickable=$(printf '%s\n' "$hits" | grep 'clickable="true"')
  if [ -n "$clickable" ]; then
    _pick "$clickable"
  else
    _pick "$hits"
  fi
}

# No braces in the usage message: a `}` inside `${1:?…}` closes the expansion
# early and the rest of the message gets parsed as a redirection.
cmd=${1:?usage: find-node.sh find-or-tap-or-list NEEDLE}
needle=${2:-}

dump || { echo "dump failed" >&2; exit 1; }

case "$cmd" in
  list) grep -oE 'content-desc="[^"]*"' "$CACHE" | grep -v 'content-desc=""' | sed 's/content-desc="//;s/"$//' | sed 's/&#10;/ | /g' ;;
  find)
    pos=$(centre "$needle")
    [ -n "$pos" ] || { echo "not found: $needle" >&2; exit 1; }
    echo "$pos" ;;
  tap)
    pos=$(centre "$needle")
    [ -n "$pos" ] || { echo "not found: $needle" >&2; exit 1; }
    set -- $pos
    arm && "$ADB" -s "$SER" shell "input tap $1 $2" >/dev/null 2>&1
    echo "tapped '$needle' at $1,$2"
    sleep 2 ;;
  *) echo "usage: find-node.sh {find|tap|list} <label>" >&2; exit 2 ;;
esac
