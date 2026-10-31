#!/usr/bin/env bash
# Dump the frontmost UI's text labels, retrying through the emulator's flaky
# adb transport (it drops roughly once a minute on this machine).
#
# Usage: ./tool/ui_text.sh [attempts]
set -u

ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
SERIAL="${SERIAL:-emulator-5554}"
ATTEMPTS="${1:-8}"
export MSYS_NO_PATHCONV=1

for i in $(seq 1 "$ATTEMPTS"); do
  state=$("$ADB" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')
  if [ "$state" != "device" ]; then
    echo "[$i] state=$state, reconnecting" >&2
    "$ADB" reconnect offline >/dev/null 2>&1
    "$ADB" start-server >/dev/null 2>&1
    sleep 4
    continue
  fi

  if ! "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/ui_dump.xml >/dev/null 2>&1; then
    echo "[$i] dump failed, retrying" >&2
    sleep 4
    continue
  fi

  if "$ADB" -s "$SERIAL" shell cat /sdcard/ui_dump.xml > /tmp/ui_dump.xml 2>/dev/null; then
    if [ -s /tmp/ui_dump.xml ]; then
      grep -oE 'text="[^"]*"' /tmp/ui_dump.xml | sed 's/^text="//; s/"$//' | grep -v '^$'
      exit 0
    fi
  fi
  sleep 4
done

echo "ui_text.sh: gave up after $ATTEMPTS attempts" >&2
exit 1
