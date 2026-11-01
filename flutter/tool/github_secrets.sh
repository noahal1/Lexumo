#!/usr/bin/env bash
# Prepare the four GitHub Actions secrets, one at a time, so each value can be
# pasted into the browser form without ever passing through a shell history, a
# log file, or a chat window.
#
# Why a script: three of the four values are short and one is a 3 KB base64 blob.
# Pasting a 3 KB blob by hand is where a line wrap gets in, and a wrapped
# base64 decodes to a corrupt keystore — which `base64 -d` in CI accepts without
# complaint and `keytool` then fails to open, five minutes into a build, with an
# error about a password.
#
# This script never prints a value: each one goes to the clipboard in turn and
# the terminal only names it. It does not upload anything and needs no network.
#
# Usage:
#
#   tool/github_secrets.sh            # walk all four, one at a time
#   tool/github_secrets.sh --name     # only the secret names, in order
#   tool/github_secrets.sh --one ANDROID_KEY_ALIAS   # just one
set -euo pipefail

WS="C:/Users/noaha/prj/lingueez-web"
FLUTTER="$WS/flutter"
cd "$FLUTTER"

die() { echo "secrets: $*" >&2; exit 1; }

if [ "${1:-}" = "--name" ]; then
  cat <<'EOF'
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
EOF
  exit 0
fi

ONLY=""
if [ "${1:-}" = "--one" ]; then
  ONLY="${2:-}"
  case "$ONLY" in
    ANDROID_KEYSTORE_BASE64|ANDROID_KEYSTORE_PASSWORD|ANDROID_KEY_ALIAS|ANDROID_KEY_PASSWORD) ;;
    *) die "--one takes one of: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD" ;;
  esac
fi

[ -f android/upload-keystore.jks ] || die "android/upload-keystore.jks not found. Run tool/setup_signing.sh first."
[ -f android/key.properties ] || die "android/key.properties not found. Run tool/setup_signing.sh first."

# Read the three short values out of key.properties without echoing the file.
# Values are taken verbatim — a trailing space in a password is part of it, which
# is exactly the mistake this file is prone to and why it is not trimmed here.
prop() {
  node -e '
    const fs = require("fs");
    const want = process.argv[1];
    for (const line of fs.readFileSync("android/key.properties", "utf8").split(/\r?\n/)) {
      const i = line.indexOf("=");
      if (i < 0) continue;
      if (line.slice(0, i).trim() === want) {
        process.stdout.write(line.slice(i + 1));
        process.exit(0);
      }
    }
    process.exit(1);
  ' "$1"
}

ALIAS=$(prop keyAlias) || die "keyAlias missing from android/key.properties"
STORE_PASSWORD=$(prop storePassword) || die "storePassword missing from android/key.properties"
KEY_PASSWORD=$(prop keyPassword) || die "keyPassword missing from android/key.properties"
[ -n "$ALIAS" ] || die "keyAlias is empty"

REPO=$(git -C "$WS" remote get-url origin | sed -E 's#.*github\.com[:/]([^/]+)/(.+?)(\.git)?$#\1/\2#')
URL="https://github.com/${REPO}/settings/secrets/actions"

# Every value goes through the clipboard, never across the terminal. The point of
# this script is that a password which is never printed cannot end up in a
# scrollback buffer, a screenshot, or a terminal multiplexer's history — and the
# user only ever needs it in the browser form, which the clipboard reaches.
#
# `clip.exe` is present on every Windows install; on other systems fall back to
# printing, because a copy that cannot be made is worse than a visible password.
CLIP=""
for candidate in clip.exe pbcopy xclip wl-copy; do
  if command -v "$candidate" > /dev/null 2>&1; then CLIP="$candidate"; break; fi
done

# Copies stdin to the clipboard. Returns non-zero when there is no clipboard.
copy_to_clipboard() {
  case "$CLIP" in
    clip.exe) clip.exe ;;
    pbcopy) pbcopy ;;
    xclip) xclip -selection clipboard ;;
    wl-copy) wl-copy ;;
    *) return 1 ;;
  esac
}

# Puts one secret on the clipboard and waits for the user to save it. Shows only
# the name, the length and a masked preview: enough to confirm the right value
# was copied, not enough to leak it.
offer_secret() {
  local name="$1" value="$2" note="$3"
  [ -z "$ONLY" ] || [ "$ONLY" = "$name" ] || return 0
  echo "=== ${name} ==============================================="
  echo
  [ -n "$note" ] && { echo "$note"; echo; }
  if printf '%s' "$value" | copy_to_clipboard 2>/dev/null; then
    echo "  [on your clipboard: ${#value} characters]"
  else
    echo "  no clipboard tool found; the value is:"
    echo
    echo "  ${value}"
    echo
  fi
  echo "  In GitHub: \"New repository secret\", name ${name}, paste, save."
  echo
  read -r -p "  Press Enter once it is saved... " _
  echo
}

[ -n "$ONLY" ] || {
  echo "Open this page and add four secrets, one at a time:"
  echo
  echo "  $URL"
  echo
  echo "Use \"New repository secret\" for each. Names are case-sensitive."
  echo
}

# `-w0` disables wrapping. Without it GNU base64 breaks lines at 76 characters
# and the keystore decodes to garbage on the runner — which `base64 -d` accepts
# without complaint and `keytool` then rejects, five minutes into a build.
offer_secret ANDROID_KEYSTORE_BASE64 \
  "$(base64 -w0 android/upload-keystore.jks)" \
  "The keystore, base64-encoded on one line. This is the long one; it is on the
clipboard so no line wrap can get in."

offer_secret ANDROID_KEYSTORE_PASSWORD "$STORE_PASSWORD" \
  "The storePassword from android/key.properties."

offer_secret ANDROID_KEY_ALIAS "$ALIAS" \
  "The keyAlias from android/key.properties."

if [ "$KEY_PASSWORD" = "$STORE_PASSWORD" ]; then
  offer_secret ANDROID_KEY_PASSWORD "$KEY_PASSWORD" \
    "Same value as ANDROID_KEYSTORE_PASSWORD, as your keystore was created."
else
  offer_secret ANDROID_KEY_PASSWORD "$KEY_PASSWORD" \
    "The keyPassword from android/key.properties."
fi

# ------------------------------------------------------------------ check ----
[ -n "$ONLY" ] && exit 0

cat <<EOF

=== Done. Verify on the secrets page ==================================

  $URL

You should see exactly these four names:

  ANDROID_KEYSTORE_BASE64
  ANDROID_KEYSTORE_PASSWORD
  ANDROID_KEY_ALIAS
  ANDROID_KEY_PASSWORD

A secret added under a slightly different name is invisible to the workflow:
GitHub does not fail an unknown \`secrets.X\` reference, it substitutes an empty
string, and the job then fails at "Write the signing properties" with a message
about a missing keystore. That is why the names above are the only thing this
script guarantees.

Check the base64 one before spending a build on it. This decodes the secret the
same way CI will, so a wrapped or truncated paste shows up here instead of five
minutes into a runner:

  base64 -d <<< "<paste what you saved>" | head -c 4 | xxd

It must start with \\xfe\\xed\\xfe\\xed (a JKS magic number). Anything else means
the paste was altered; re-copy it with tool/github_secrets.sh --one ANDROID_KEYSTORE_BASE64.

Then cut the first release:

  cd $FLUTTER
  git -C $WS status --porcelain      # release.sh refuses a dirty tree
  ./tool/release.sh
  git -C $WS tag -a v0.1.0+1 -m "0.1.0 (1)" && git -C $WS push origin v0.1.0+1

Pushing the tag runs .github/workflows/release.yml, which builds, signs, checks
the certificate is not the debug one, and publishes both assets.
EOF
