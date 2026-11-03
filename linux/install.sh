#!/bin/bash
# Instaluje Markdown Viewer dla bieżącego użytkownika (bez sudo).
#   ./linux/install.sh            -> instalacja do ~/.local
#   ./linux/install.sh --default  -> dodatkowo ustawia domyślny program dla plików .md
set -euo pipefail
cd "$(dirname "$0")"

if ! python3 -c "import gi; gi.require_version('Gtk','3.0'); gi.require_version('WebKit2','4.0'); from gi.repository import Gtk, WebKit2" 2>/dev/null; then
    echo "Brak zależności. Zainstaluj:  sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.0"; exit 1
fi

APPDIR="$HOME/.local/share/markdown-viewer"
BINDIR="$HOME/.local/bin"
mkdir -p "$APPDIR" "$BINDIR" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/512x512/apps"

rm -rf "$APPDIR/web"
cp -R ../web "$APPDIR/web"
install -m 755 markdown_viewer.py "$APPDIR/markdown_viewer.py"
install -m 644 markdown-viewer.png "$HOME/.local/share/icons/hicolor/512x512/apps/markdown-viewer.png"
printf '#!/bin/sh\nexec python3 "%s/markdown_viewer.py" "$@"\n' "$APPDIR" > "$BINDIR/markdown-viewer"
chmod 755 "$BINDIR/markdown-viewer"
sed "s|^Exec=markdown-viewer|Exec=$BINDIR/markdown-viewer|" markdown-viewer.desktop > "$HOME/.local/share/applications/markdown-viewer.desktop"

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

if [ "${1:-}" = "--default" ]; then
    xdg-mime default markdown-viewer.desktop text/markdown text/x-markdown
    echo "Ustawiono Markdown Viewer jako domyślny program dla plików .md."
fi

echo "Zainstalowano Markdown Viewer. Uruchom z menu aplikacji albo:  markdown-viewer [plik.md]"
case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "Uwaga: dodaj $BINDIR do PATH.";; esac
