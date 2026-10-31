#!/usr/bin/env bash
# Capture the Lexumo UI on the running emulator, one tab at a time.
#
# adb on this box drops the server whenever a shell exits, and `uiautomator
# dump` occasionally resets the connection, so every step retries and re-arms
# the server. Output goes to /tmp/lexumo-shots/<name>.xml for grep.
set -u
ADB="/c/Users/noaha/AppData/Local/Android/Sdk/platform-tools/adb.exe"
SER=emulator-5554
OUT=/tmp/lexumo-shots
mkdir -p "$OUT"

arm() {
  "$ADB" start-server >/dev/null 2>&1
  for _ in $(seq 1 25); do
    [ "$("$ADB" devices 2>/dev/null | grep "$SER" | awk '{print $2}')" = "device" ] && return 0
    sleep 2
  done
  return 1
}

# dump <name> — write the current hierarchy to $OUT/<name>.xml, retrying.
dump() {
  local name=$1 i
  for i in 1 2 3 4 5; do
    arm || { sleep 3; continue; }
    "$ADB" -s "$SER" shell "rm -f /sdcard/u.xml" >/dev/null 2>&1
    if "$ADB" -s "$SER" shell "uiautomator dump /sdcard/u.xml" 2>&1 | grep -q "dumped to"; then
      if "$ADB" -s "$SER" shell "cat /sdcard/u.xml" > "$OUT/$name.xml" 2>/dev/null; then
        [ "$(stat -c %s "$OUT/$name.xml")" -gt 2000 ] && return 0
      fi
    fi
    sleep 3
  done
  echo "FAILED to dump $name" >&2
  return 1
}

# tap <x> <y> — best effort, retried.
tap() {
  local x=$1 y=$2
  arm && "$ADB" -s "$SER" shell "input tap $x $y" >/dev/null 2>&1
  sleep 1
}

# labels <name> — print the visible text of a dump, one per line.
labels() {
  grep -oE 'content-desc="[^"]*"' "$OUT/$1.xml" \
    | grep -v 'content-desc=""' \
    | sed 's/content-desc="//;s/"$//' \
    | sed 's/&#10;/ | /g'
}

case "${1:-}" in
  words)   tap 125 2258; sleep 2; dump words ;;
  cards)   tap 332 2258; sleep 2; dump cards ;;
  quiz)    tap 540 2258; sleep 2; dump quiz ;;
  stats)   tap 747 2258; sleep 3; dump stats ;;
  settings) tap 955 2258; sleep 2; dump settings ;;
  labels)  labels "${2:?name}" ;;
  *) echo "usage: $0 {words|cards|quiz|stats|settings|labels <name>}" >&2; exit 2 ;;
esac
