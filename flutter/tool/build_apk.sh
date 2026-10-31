#!/usr/bin/env bash
# Build the release APK.
#
# `flutter build apk` / `flutter run` cannot build on this machine: they hand
# Gradle a minimal environment (only JAVA_HOME and PATH — see flutter_tools'
# android/java.dart `environment` getter), and gradlew.bat needs HOME/USERPROFILE
# to locate ~/.gradle. Without them the wrapper computes a dists path that does
# not match the extracted distribution, falls into Install.createDist, and dies
# on `gradle-9.3.1-all.zip.lck (Access denied)` — an error that looks like a
# permission problem but is not. tool/repro_lck.sh proves the diagnosis: the same
# command line fails in a plain shell and succeeds with these variables pinned.
#
# So: pin the environment, call Gradle directly. Any extra args are forwarded
# (e.g. -Ptarget-platform=android-x64 for a 20 MB APK instead of 51 MB).
set -euo pipefail

WS="C:/Users/noaha/prj/lingueez-web"
cd "$WS/flutter/android"

export HOME="$WS/.flutter-home"
export USERPROFILE="$WS/.flutter-home"
export APPDATA="$WS/.flutter-home/AppData/Roaming"
export LOCALAPPDATA="$WS/.flutter-home/AppData/Local"
export TMP="$WS/.flutter-home/tmp"
export TEMP="$WS/.flutter-home/tmp"
export TMPDIR="$WS/.flutter-home/tmp"
export MSYS2_ARG_CONV_EXCL="*"

./gradlew.bat -Ptarget=lib/main.dart \
  -Pflutter.androidSdkRoot='C:\Users\noaha\AppData\Local/Android/Sdk' \
  assembleRelease "$@"

APK="$WS/flutter/build/app/outputs/apk/release/app-release.apk"
if [ -f "$APK" ]; then
  mkdir -p "$WS/flutter/dist"
  cp "$APK" "$WS/flutter/dist/lexumo-android-release.apk"
  echo "--- built ---"
  ls -l --time-style=+%H:%M "$WS/flutter/dist/lexumo-android-release.apk" |
    awk '{printf "dist/lexumo-android-release.apk  %s bytes  %s\n", $5, $6}'
fi
