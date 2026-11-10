#!/bin/bash
rm -rf "$HOME/.local/share/markdown-viewer" "$HOME/.local/bin/markdown-viewer" \
  "$HOME/.local/share/applications/markdown-viewer.desktop" \
  "$HOME"/.local/share/icons/hicolor/*/apps/markdown-viewer.png
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "Odinstalowano Markdown Viewer."
