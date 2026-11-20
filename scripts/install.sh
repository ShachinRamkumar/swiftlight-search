#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target="$HOME/Applications/Swiftlight.app"
if [[ -e "$target" ]]; then
  bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
  [[ "$bundle" == com.shachin.swiftlight ]] || { echo "A different application already owns $target" >&2; exit 1; }
fi
mkdir -p "$HOME/Applications"
if [[ "$(osascript -e 'application id "com.shachin.swiftlight" is running')" == true ]]; then
  osascript -e 'tell application id "com.shachin.swiftlight" to quit'
  for attempt in {1..50}; do
    [[ "$(osascript -e 'application id "com.shachin.swiftlight" is running')" == false ]] && break
    sleep 0.2
  done
fi
ditto "build.noindex/Swiftlight.app" "$target"
codesign --verify --deep --strict "$target"
open "$target"
echo "Installed $target"
