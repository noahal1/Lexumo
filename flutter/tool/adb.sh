#!/usr/bin/env bash
# adb with retry, for this emulator's habit of dropping the transport.
#
# The emulator on this machine goes `offline` for a few seconds at a time
# (observed during the APK installs). A bare `adb` call then fails with
# "device offline" or "device still authorizing", which looks like a broken
# command rather than a transient transport hiccup. This wrapper waits for the
# device to come back and retries, so callers do not have to.
#
# Usage:  tool/adb.sh shell "pm list packages"
#         tool/adb.sh install path/to/app.apk
#         tool/adb.sh logcat -d -t 100
set -uo pipefail

ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
SERIAL="${SERIAL:-emulator-5554}"
ATTEMPTS="${ATTEMPTS:-6}"

# MSYS rewrites /data/local/tmp into a Windows path; adb needs the literal one.
export MSYS2_ARG_CONV_EXCL="*"
export MSYS_NO_PATHCONV=1

wait_online() {
  for _ in $(seq 1 20); do
    if "$ADB" devices 2>/dev/null | grep -q "^${SERIAL}[[:space:]]*device"; then
      return 0
    fi
    "$ADB" reconnect offline >/dev/null 2>&1 || true
    sleep 2
  done
  return 1
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  wait_online || { echo "adb.sh: ${SERIAL} never came online" >&2; exit 1; }
  out=$("$ADB" -s "$SERIAL" "$@" 2>&1)
  code=$?
  # Transient transport failures are worth retrying; a real command error is
  # not, and retrying it would only delay the report.
  if printf '%s' "$out" | grep -qE "device offline|device still authorizing|connection reset|closed"; then
    sleep 2
    continue
  fi
  printf '%s\n' "$out"
  exit "$code"
done

echo "adb.sh: giving up after ${ATTEMPTS} attempts" >&2
exit 1
