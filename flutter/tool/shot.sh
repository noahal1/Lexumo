#!/usr/bin/env bash
# Capture a screenshot from the emulator, surviving this machine's habit of
# dropping the adb transport between commands.
#
# Usage:  tool/shot.sh .shots/12-words.png [package.to.launch]
set -uo pipefail

OUT="${1:?output png path}"
PKG="${2:-}"
ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
SERIAL="${SERIAL:-emulator-5554}"

export MSYS2_ARG_CONV_EXCL="*"
export MSYS_NO_PATHCONV=1

"$ADB" start-server >/dev/null 2>&1

# The transport flaps; keep poking until a real shell round-trip succeeds.
ready=0
for _ in $(seq 1 40); do
  if "$ADB" -s "$SERIAL" shell true >/dev/null 2>&1; then ready=1; break; fi
  "$ADB" start-server >/dev/null 2>&1
  "$ADB" reconnect offline >/dev/null 2>&1 || true
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  echo "shot.sh: device never answered a shell round-trip" >&2
  exit 1
fi

if [ -n "$PKG" ]; then
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true
  sleep 5
fi

# One retry loop around the actual capture: the transport can drop between the
# ping above and the screencap below.
for _ in $(seq 1 10); do
  "$ADB" -s "$SERIAL" shell "screencap -p /data/local/tmp/shot.png" >/dev/null 2>&1 || { sleep 2; continue; }
  if "$ADB" -s "$SERIAL" pull /data/local/tmp/shot.png "$OUT" >/dev/null 2>&1; then
    if [ -s "$OUT" ]; then
      echo "shot.sh: wrote $OUT ($(wc -c < "$OUT") bytes)"
      exit 0
    fi
  fi
  sleep 2
done

echo "shot.sh: capture failed after retries" >&2
exit 1
