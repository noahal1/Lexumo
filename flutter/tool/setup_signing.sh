#!/usr/bin/env bash
# Wire up release signing, once, without ever putting the password in a shell
# history, a log, or a chat window.
#
# Why this is a script and not a checklist: the three things that go wrong here
# are all silent. A keystore left outside `android/` makes `storeFile` resolve to
# a path that does not exist (Gradle's error is about a file, not about where you
# saved it); a password with a trailing space gets trimmed by a hand-edited file
# and then fails at signing time, after a five-minute build; and a keystore
# created without `-storetype JKS` is PKCS12, which is fine, but a *hand-written*
# `key.properties` that disagrees with reality is not detected until the APK is
# half-built. So: copy, prompt, write, verify, and refuse to leave anything
# behind if the verification fails.
#
# Usage:
#
#   tool/setup_signing.sh                     # uses ../upload-keystore.jks or android/upload-keystore.jks
#   tool/setup_signing.sh --keystore <path>   # point at the file you generated
#   tool/setup_signing.sh --alias upload      # key alias (default: upload)
#   tool/setup_signing.sh --force             # overwrite an existing key.properties
#
# It never prints a password. `read -s` keeps it off the terminal, and the only
# thing written to disk is `android/key.properties`, which `android/.gitignore`
# covers by name and by `**/*.jks`.
set -euo pipefail

WS="C:/Users/noaha/prj/lingueez-web"
FLUTTER="$WS/flutter"
cd "$FLUTTER"

KEYSTORE=""
ALIAS="upload"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keystore) KEYSTORE="$2"; shift 2 ;;
    --alias) ALIAS="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "setup-signing: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "setup-signing: $*" >&2; exit 1; }

# ---------------------------------------------------------------- keystore ---
# The three places it plausibly landed: passed in, next to the project (where the
# keytool command in the docs creates it if you run it from the repo root), or
# already in `android/`.
if [ -z "$KEYSTORE" ]; then
  for candidate in \
    "$WS/upload-keystore.jks" \
    "$FLUTTER/android/upload-keystore.jks" \
    "$HOME/upload-keystore.jks"
  do
    if [ -f "$candidate" ]; then KEYSTORE="$candidate"; break; fi
  done
fi
[ -n "$KEYSTORE" ] || die "no keystore found. Generate one first:
    keytool -genkeypair -v -keystore upload-keystore.jks \\
      -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias $ALIAS
  then run this script again (or pass --keystore <path>)."
[ -f "$KEYSTORE" ] || die "keystore not found: $KEYSTORE"

TARGET="$FLUTTER/android/upload-keystore.jks"
if [ "$(cd "$(dirname "$KEYSTORE")" && pwd)/$(basename "$KEYSTORE")" != "$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")" ]; then
  echo "setup-signing: copying $(basename "$KEYSTORE") into android/"
  # `cp` rather than `mv`: the original may be the only backup, and a keystore
  # deleted because "it was moved somewhere" is the one mistake with no recovery.
  cp "$KEYSTORE" "$TARGET"
fi
echo "setup-signing: keystore -> android/$(basename "$TARGET")"

# --------------------------------------------------------------- passwords ---
if [ -f android/key.properties ] && [ "$FORCE" -eq 0 ]; then
  echo "setup-signing: android/key.properties already exists (use --force to rewrite)."
  echo
  echo "Current state:"
  sed 's/Password=.*/Password=<set>/' android/key.properties
  exit 0
fi

echo
echo "Enter the passwords you chose when creating the keystore."
echo "Nothing is echoed, and nothing is written outside android/key.properties."
echo
printf 'storePassword: '
IFS= read -r -s STORE_PASSWORD
echo
printf 'keyPassword   (press Enter if the same as storePassword): '
IFS= read -r -s KEY_PASSWORD
echo
[ -n "$KEY_PASSWORD" ] || KEY_PASSWORD="$STORE_PASSWORD"
[ -n "$STORE_PASSWORD" ] || die "empty password"

# ----------------------------------------------------------------- verify ----
# Verify before writing: a `key.properties` with a wrong password is worse than
# none, because the build gets five minutes in before failing.
KEYTOOL="$(command -v keytool || true)"
if [ -z "$KEYTOOL" ]; then
  for candidate in \
    "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
    "$(dirname "$(command -v java 2>/dev/null || echo /nonexistent)")/keytool"
  do
    if [ -x "$candidate" ]; then KEYTOOL="$candidate"; break; fi
  done
fi
[ -n "$KEYTOOL" ] || die "keytool not found (it ships with the JDK that Android Studio installs)"

echo "setup-signing: checking the password against the keystore..."
if ! "$KEYTOOL" -list -keystore "$TARGET" -storepass "$STORE_PASSWORD" -alias "$ALIAS" > /dev/null 2>&1; then
  # A wrong password and a wrong alias produce the same silence, so say both.
  die "keytool could not open the keystore with that password and alias '$ALIAS'.
  Either the password is not the one used at creation, or the key alias is
  different. List what is actually inside with:

    \"$KEYTOOL\" -list -keystore android/$(basename "$TARGET")

  and re-run with --alias <the alias it printed>."
fi
echo "setup-signing: password and alias verified"

# ------------------------------------------------------------------ write ----
# `storeFile` is resolved against `android/`, so the bare filename is right.
# Written without a trailing newline on the password lines beyond what printf
# adds: `key.properties` values are taken verbatim, and a trailing space is a
# different password.
umask 077
{
  echo "storeFile=$(basename "$TARGET")"
  printf 'storePassword=%s\n' "$STORE_PASSWORD"
  echo "keyAlias=$ALIAS"
  printf 'keyPassword=%s\n' "$KEY_PASSWORD"
} > android/key.properties

echo "setup-signing: wrote android/key.properties"
echo

# --------------------------------------------------------------- git check ---
if git -C "$WS" check-ignore -q "flutter/android/$(basename "$TARGET")" 2>/dev/null; then
  echo "setup-signing: keystore is git-ignored (good)"
else
  echo "setup-signing: WARNING: the keystore is NOT ignored by git. Check android/.gitignore." >&2
fi
if git -C "$WS" check-ignore -q flutter/android/key.properties 2>/dev/null; then
  echo "setup-signing: key.properties is git-ignored (good)"
else
  echo "setup-signing: WARNING: key.properties is NOT ignored by git." >&2
fi

cat <<EOF

Next, in this order:

  1. Back up android/$(basename "$TARGET") somewhere outside this machine and outside
     GitHub. If it is lost, no installed copy of the app can ever be updated
     again — Android refuses an update signed with a different key, and the only
     fix is asking every user to uninstall and lose their data.

  2. Put the same four values into GitHub so CI can sign too
     (Settings -> Secrets and variables -> Actions):

       base64 -w0 android/$(basename "$TARGET")    # -> ANDROID_KEYSTORE_BASE64
       ANDROID_KEYSTORE_PASSWORD                   # the storePassword above
       ANDROID_KEY_ALIAS=$ALIAS
       ANDROID_KEY_PASSWORD                        # the keyPassword above

     Run the base64 command yourself and paste its output into the secret box;
     this script deliberately does not print it.

  3. Commit, then cut the release (release.sh refuses to run on a dirty tree):

       cd "$WS" && git add -A && git commit -m "..." && git push
       cd "$WS/flutter" && ./tool/release.sh

     The APK currently in dist/ is debug-signed and older than the source, so it
     has to be rebuilt — that is what step 3 does.
EOF
