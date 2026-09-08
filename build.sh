#!/bin/bash
# Build Maccy.app from the command line without opening Xcode.
#
# Usage:
#   ./build.sh           Build Debug and print the app path.
#   ./build.sh --proxy   Same, but route package downloads through a local
#                        SOCKS5 proxy at 127.0.0.1:1080 (only needed when
#                        SwiftPM dependencies are not cached yet).
#   ./build.sh run       Build, quit any running Maccy, migrate data from the
#                        sandboxed Maccy's container (first run only), then
#                        launch the freshly built one.
set -euo pipefail

MODE="build"
USE_PROXY=0
for arg in "$@"; do
  case "$arg" in
    run) MODE="run" ;;
    --proxy) USE_PROXY=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# The sandboxed Maccy (Mac App Store and signed GitHub releases) keeps its
# history database inside a sandbox container, while an unsandboxed build
# reads the plain Application Support path. On first launch of this build,
# copy the old database and preferences over so history is not lost.
# Never overwrites: runs only when no database exists at the destination.
migrate_sandbox_data() {
  local container_data="$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy"
  local plain_data="$HOME/Library/Application Support/Maccy"

  if [[ ! -f "$container_data/Storage.sqlite" ]]; then
    return
  fi

  if [[ -f "$plain_data/Storage.sqlite" ]]; then
    echo "Data already exists in $plain_data; skipping sandbox data migration."
    return
  fi

  echo "Migrating Maccy history from the sandbox container..."
  mkdir -p "$plain_data"
  local file
  for file in Storage.sqlite Storage.sqlite-shm Storage.sqlite-wal; do
    if [[ -f "$container_data/$file" ]]; then
      cp "$container_data/$file" "$plain_data/"
    fi
  done

  local container_prefs="$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences/org.p0deje.Maccy.plist"
  local plain_prefs="$HOME/Library/Preferences/org.p0deje.Maccy.plist"
  if [[ -f "$container_prefs" ]]; then
    # The unsandboxed build reads the plain preferences domain, but `defaults`
    # commands resolve that domain to the container on this setup, so merge
    # the plist files directly. cfprefsd is flushed afterwards (Maccy quit).
    python3 -c '
import plistlib, sys
plain_path, container_path = sys.argv[1], sys.argv[2]
try:
    with open(plain_path, "rb") as f:
        plain = plistlib.load(f)
except FileNotFoundError:
    plain = {}
with open(container_path, "rb") as f:
    plain.update(plistlib.load(f))
with open(plain_path, "wb") as f:
    plistlib.dump(plain, f)
' "$plain_prefs" "$container_prefs" \
      || echo "Warning: could not import preferences from $container_prefs"
    killall cfprefsd 2>/dev/null || true
  fi

  echo "Migration done: history and settings copied to $plain_data."
}

# Prefer a stable self-signed "MaccyDev" code signing certificate when present
# (create once in Keychain Access: Certificate Assistant -> Create Certificate,
# Identity Type: Self-Signed Root Certificate, Certificate Type: Code Signing).
# A stable identity keeps macOS Accessibility grants valid across rebuilds;
# ad-hoc signing breaks them whenever the binary changes.
ADHOC_SIGN=1
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"MaccyDev"'; then
  XCODEBUILD=(xcodebuild
    -project Maccy.xcodeproj
    -scheme Maccy
    -configuration Debug
    CODE_SIGN_IDENTITY="MaccyDev" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=YES DEVELOPMENT_TEAM=""
  )
  ADHOC_SIGN=0
else
  XCODEBUILD=(xcodebuild
    -project Maccy.xcodeproj
    -scheme Maccy
    -configuration Debug
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  )
fi

if [[ "$USE_PROXY" == 1 ]]; then
  printf '[http]\n\tproxy = socks5h://127.0.0.1:1080\n[https]\n\tproxy = socks5h://127.0.0.1:1080\n' \
    > /tmp/maccy-git-proxy.gitconfig
  export GIT_CONFIG_GLOBAL=/tmp/maccy-git-proxy.gitconfig
  # Sparkle's binary zip downloads via the system network stack, not git,
  # so the system proxy is required as well. Always restored on exit.
  networksetup -setsocksfirewallproxy "Wi-Fi" 127.0.0.1 1080
  trap 'networksetup -setsocksfirewallproxystate "Wi-Fi" off' EXIT
fi

"${XCODEBUILD[@]}" build

BUILT=$("${XCODEBUILD[@]}" -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {print $3; exit}')
APP="$BUILT/Maccy.app"

if [[ "$ADHOC_SIGN" == 1 ]]; then
  codesign --force --deep -s - "$APP"
fi
codesign --verify --strict "$APP"

echo
echo "Built: $APP"

if [[ "$MODE" == "run" ]]; then
  osascript -e 'tell application "Maccy" to quit' 2>/dev/null || pkill -x Maccy || true
  sleep 1
  # Migration needs Maccy fully quit so the SQLite WAL files are consistent.
  migrate_sandbox_data
  open "$APP"
  echo "Launched."
else
  echo "Run:   quit the running Maccy, then: open \"$APP\""
fi
