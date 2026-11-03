#!/bin/bash
# Buduje build/Markdown Viewer.app. Z flagą --install kopiuje ją do ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Markdown Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -module-name MarkdownViewer mac/main.swift \
  -o "$APP/Contents/MacOS/MarkdownViewer" -framework Cocoa -framework WebKit
cp mac/Info.plist "$APP/Contents/"
cp -R web "$APP/Contents/Resources/web"
[[ -f mac/AppIcon.icns ]] && cp mac/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Zbudowano: $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Markdown Viewer.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Zainstalowano: $DEST"
fi
