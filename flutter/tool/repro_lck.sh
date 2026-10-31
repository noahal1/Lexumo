#!/usr/bin/env bash
# Reproduce the exact Gradle invocation `flutter run` performs.
#
# `flutter build apk` and `flutter run` both die on
#   java.io.FileNotFoundException: ...gradle-9.3.1-all.zip.lck (Access denied)
# while the same wrapper called by hand succeeds. The command line is not the
# difference (it was captured with `flutter run -v`), so this script replays that
# command under two environments to find which one breaks it:
#
#   A. the plain shell environment
#   B. the environment the `flutterc` wrapper pins (HOME/APPDATA/TMP inside the
#      workspace), because that is the only thing the wrapper changes
set -uo pipefail

WS="C:/Users/noaha/prj/lingueez-web"
cd "$WS/flutter/android"
export MSYS2_ARG_CONV_EXCL="*"

ARGS=(
  --full-stacktrace
  -Pverbose=true
  -Ptarget-platform=android-x64
  "-Ptarget=C:\\Users\\noaha\\prj\\lingueez-web\\flutter\\lib\\main.dart"
  -Pbase-application-name=android.app.Application
  -Ptrack-widget-creation=true
  -Ptree-shake-icons=false
  -Pfilesystem-scheme=org-dartlang-root
  '-Pflutter.androidSdkRoot=C:\Users\noaha\AppData\Local/Android/Sdk'
  -Pflutter.installedNdkVersions=28.2.13676358,29.0.13846066
  assembleRelease
)

echo "===== A: plain environment ====="
./gradlew.bat "${ARGS[@]}" 2>&1 | grep -E "BUILD|FileNotFoundException|lck" | head -4

echo "===== B: flutterc-pinned environment ====="
(
  export HOME="$WS/.flutter-home"
  export USERPROFILE="$WS/.flutter-home"
  export APPDATA="$WS/.flutter-home/AppData/Roaming"
  export LOCALAPPDATA="$WS/.flutter-home/AppData/Local"
  export TMP="$WS/.flutter-home/tmp"
  export TEMP="$WS/.flutter-home/tmp"
  export TMPDIR="$WS/.flutter-home/tmp"
  ./gradlew.bat "${ARGS[@]}" 2>&1 | grep -E "BUILD|FileNotFoundException|lck" | head -4
)
