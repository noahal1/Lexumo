#!/usr/bin/env bash
# Build the Windows release bundle.
#
# Three things about this machine make a bare `flutter build windows` fail, and
# all three produce errors that point somewhere other than the cause:
#
#   1. nuget.exe is not on PATH. The failure is `nuget.exe not found. Please
#      install it.` from flutter_tts's CMakeLists, and without nuget the build
#      dies in 149 ms before any C++ is compiled.
#   2. The plugin symlinks cannot be created by Dart (errno 1314: the process
#      token lacks SeCreateSymbolicLinkPrivilege even with Developer Mode on).
#      `tool/prelink.cjs` pre-creates them with mklink, and flutter_plugins.dart
#      skips a link that already points at the right target.
#   3. A stale build/ directory keeps `CMAKE_INSTALL_PREFIX` at whatever it was
#      cached as. A fresh configure writes `$<TARGET_FILE_DIR:lexumo>`, but if an
#      earlier run cached an absolute path the install step copies the exe to
#      `C:/Program Files/lexumo` and dies with `file cannot create directory`.
#      Deleting build/windows is the fix, and it is cheap: the C++ side is small.
#
# Anything passed to this script is forwarded to flutter build.
set -euo pipefail

WS="C:/Users/noaha/prj/lingueez-web"
cd "$WS/flutter"

export HOME="$WS/.flutter-home"
export USERPROFILE="$WS/.flutter-home"
export APPDATA="$WS/.flutter-home/AppData/Roaming"
export LOCALAPPDATA="$WS/.flutter-home/AppData/Local"
export TMP="$WS/.flutter-home/tmp"
export TEMP="$WS/.flutter-home/tmp"
export TMPDIR="$WS/.flutter-home/tmp"
export PATH="/c/Users/noaha/Downloads:$PATH"   # nuget.exe lives here

# A running instance holds lexumo.exe open, and the link step then fails with
# LNK1104 on a file it cannot replace.
taskkill //F //IM lexumo.exe >/dev/null 2>&1 || true

# The symlink step must run after `pub get` has written
# .flutter-plugins-dependencies, and before CMake configures.
node tool/prelink.cjs
cmd //c "windows\flutter\ephemeral\_mklinks.bat" >/dev/null 2>&1 || true

# See point 3 above: a cached absolute install prefix is unrecoverable without
# this. The C++ side rebuilds in well under a minute.
rm -rf build/windows

../.flutter-sdk/flutterc build windows --release "$@"

EXE="$WS/flutter/build/windows/x64/runner/Release/lexumo.exe"
if [ -f "$EXE" ]; then
  echo "--- built ---"
  ls -l --time-style=+%H:%M "$EXE" | awk '{printf "lexumo.exe  %s bytes  %s\n", $5, $6}'
fi
