# Markdown Viewer

Lekka natywna aplikacja na macOS do czytania i edycji plików `.md` (Swift + WKWebView, ~650 KB, bez Electrona i bez zależności).

## Funkcje

- **Podgląd** (domyślnie) w stylu GitHuba, jasny/ciemny motyw wg systemu, kolorowanie składni w blokach kodu, tabele, listy zadań, front matter.
- **Kod** — surowy markdown; **Podział** — kod i podgląd obok siebie, odświeżany na żywo.
- **Edycja** (`⌘E`) — włącza edycję zarówno w kodzie, jak i bezpośrednio w podglądzie (WYSIWYG). Zmiany z podglądu są konwertowane z powrotem do markdown.
- Natywne okna dokumentów: `⌘S` / `⇧⌘S`, „Otwórz ostatnie", ostrzeżenie o niezapisanych zmianach, wiele okien.
- Linki: `#kotwice` przewijają, inne pliki `.md` otwierają się w aplikacji, `http(s)` w domyślnej przeglądarce. W trybie edycji link otwierasz `⌘`-klikiem.
- Względne obrazki (`![](img/x.png)`) są ładowane z katalogu pliku.

## Skróty

| Skrót | Akcja |
| --- | --- |
| `⌘1` / `⌘2` / `⌘3` | Podgląd / Podział / Kod |
| `⌘E` | Włącz/wyłącz edycję |
| `⌘S`, `⇧⌘S` | Zapisz, Zapisz jako |
| `⌘+` / `⌘-` / `⌘0` | Powiększ / pomniejsz / reset |

## Budowanie i instalacja

Wymaga tylko Xcode Command Line Tools (`swiftc`).

```bash
./build.sh            # → build/Markdown Viewer.app
./build.sh --install  # dodatkowo kopiuje do ~/Applications
```

Ustawienie jako domyślnej aplikacji dla `.md`: Finder → plik `.md` → *Informacje* (`⌘I`) → *Otwórz za pomocą* → Markdown Viewer → *Zmień wszystkie…*

Bez instalacji można też otworzyć `web/index.html` w przeglądarce (Chrome zapisuje plik w miejscu, inne pobierają kopię).

## Uwagi

- Pierwsza edycja w **podglądzie** przepisuje cały plik przez konwerter HTML→Markdown, więc formatowanie źródła może się lekko znormalizować (np. `*` → `-` w listach). Edycja w widoku **Kod** nie zmienia niczego poza tym, co wpiszesz.
- HTML w markdownie jest sanityzowany (DOMPurify) — skrypty z pliku się nie wykonają.

## Struktura

```
mac/main.swift     # cała aplikacja natywna (NSDocument + WKWebView + menu)
mac/Info.plist     # rejestracja typu .md
mac/make-icon.swift# generator ikony (swift mac/make-icon.swift <katalog.iconset>)
web/               # UI: index.html, app.js, app.css, vendor/ (marked, turndown, DOMPurify, highlight.js)
build.sh
```
