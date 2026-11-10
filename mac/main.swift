import Cocoa
import WebKit

private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

// WKUserContentController retains its handlers; this proxy breaks the document <-> web view cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument, WKScriptMessageHandler, WKNavigationDelegate {
    private var text = ""
    private var webView: WKWebView!
    private var pageLoaded = false
    private var mode = "preview"
    private var editing = false

    private static let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")!

    override init() {
        super.init()
        // The web view tracks its own undo; dirty state comes from the page via "dirty" messages.
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { false }

    // MARK: Window

    override func makeWindowControllers() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(self), name: "bridge")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = webView
        window.minSize = NSSize(width: 480, height: 320)
        window.isRestorable = false
        window.center()

        addWindowController(NSWindowController(window: window))
        webView.loadFileURL(Self.indexURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    private func pushContent() {
        guard pageLoaded else { return }
        let base = fileURL?.deletingLastPathComponent().absoluteString ?? ""
        webView.callAsyncJavaScript(
            "mdv.load({ text, name, base })",
            arguments: ["text": text, "name": displayName ?? "", "base": base],
            in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Reading & writing

    override func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
        pushContent() // no-op on first open; refreshes the page on "Revert"
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        guard pageLoaded else {
            return super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        }
        // Pull the latest markdown (pending preview edits included) before NSDocument asks for data.
        webView.evaluateJavaScript("mdv.getMarkdown()") { result, _ in
            if let markdown = result as? String { self.text = markdown }
            super.save(to: url, ofType: typeName, for: saveOperation) { error in
                if error == nil {
                    // Base directory may have changed with "Save As".
                    let base = self.fileURL?.deletingLastPathComponent().absoluteString ?? ""
                    self.webView.callAsyncJavaScript("mdv.setFile({ name, base })",
                                                      arguments: ["name": self.displayName ?? "", "base": base],
                                                      in: nil, in: .page, completionHandler: nil)
                }
                completionHandler(error)
            }
        }
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "dirty":
            updateChangeCount(.changeDone)
        case "state":
            mode = body["mode"] as? String ?? mode
            editing = body["editing"] as? Bool ?? editing
        case "open":
            if let string = body["url"] as? String, let url = URL(string: string) { open(url) }
        default:
            break
        }
    }

    private func open(_ url: URL) {
        if url.isFileURL {
            let fileURL = URL(fileURLWithPath: url.path) // drops any #fragment
            if markdownExtensions.contains(fileURL.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
            } else {
                NSWorkspace.shared.open(fileURL)
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        pushContent()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if !pageLoaded && url == Self.indexURL { return decisionHandler(.allow) }
        // Anything else (e.g. a file dropped onto the window) must not replace the page.
        if url.isFileURL && markdownExtensions.contains(url.pathExtension.lowercased()) { open(url) }
        decisionHandler(.cancel)
    }

    // MARK: View menu

    @objc func showPreview(_ sender: Any?) { webView.evaluateJavaScript("mdv.setMode('preview')") }
    @objc func showSplit(_ sender: Any?) { webView.evaluateJavaScript("mdv.setMode('split')") }
    @objc func showCode(_ sender: Any?) { webView.evaluateJavaScript("mdv.setMode('code')") }
    @objc func toggleEditing(_ sender: Any?) { webView.evaluateJavaScript("mdv.toggleEdit()") }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func resetZoom(_ sender: Any?) { webView.pageZoom = 1 }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showPreview(_:)): item.state = mode == "preview" ? .on : .off
        case #selector(showSplit(_:)): item.state = mode == "split" ? .on : .off
        case #selector(showCode(_:)): item.state = mode == "code" ? .on : .off
        case #selector(toggleEditing(_:)): item.state = editing ? .on : .off
        default: return super.validateMenuItem(item)
        }
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Launched without a file (or Dock click with no windows): show the open panel instead of an empty doc.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }
}

private func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
}

// WKWebView answers the standard find bar; the action travels in the item's tag.
private func finderItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                        _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let it = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
    it.tag = action.rawValue
    return it
}

private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = menu
    return holder
}

private func buildMainMenu() -> NSMenu {
    let appName = "Markdown Viewer"

    let recent = submenu("Otwórz ostatnie", [item("Wyczyść menu", #selector(NSDocumentController.clearRecentDocuments(_:)))])
    let setMenuName = NSSelectorFromString("_setMenuName:")
    if recent.submenu!.responds(to: setMenuName) {
        recent.submenu!.perform(setMenuName, with: "NSRecentDocumentsMenu")
    }

    let windowMenu = submenu("Okno", [
        item("Minimalizuj", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
    ])
    NSApp.windowsMenu = windowMenu.submenu

    let main = NSMenu()
    [
        submenu(appName, [
            item("O programie \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Ukryj \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Ukryj pozostałe", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Pokaż wszystkie", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Zakończ \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]),
        submenu("Plik", [
            item("Nowy", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Otwórz…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recent,
            .separator(),
            item("Zamknij", #selector(NSWindow.performClose(_:)), "w"),
            item("Zapisz", #selector(NSDocument.save(_:)), "s"),
            item("Zapisz jako…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Przywróć zapisaną wersję", #selector(NSDocument.revertToSaved(_:))),
        ]),
        submenu("Edycja", [
            item("Cofnij", Selector(("undo:")), "z"),
            item("Ponów", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Wytnij", #selector(NSText.cut(_:)), "x"),
            item("Kopiuj", #selector(NSText.copy(_:)), "c"),
            item("Wklej", #selector(NSText.paste(_:)), "v"),
            item("Zaznacz wszystko", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            finderItem("Znajdź…", .showFindInterface, "f"),
            finderItem("Znajdź następne", .nextMatch, "g"),
            finderItem("Znajdź poprzednie", .previousMatch, "g", [.command, .shift]),
        ]),
        submenu("Widok", [
            item("Podgląd", #selector(MarkdownDocument.showPreview(_:)), "1"),
            item("Podział", #selector(MarkdownDocument.showSplit(_:)), "2"),
            item("Kod", #selector(MarkdownDocument.showCode(_:)), "3"),
            .separator(),
            item("Edycja", #selector(MarkdownDocument.toggleEditing(_:)), "e"),
            .separator(),
            item("Powiększ", #selector(MarkdownDocument.zoomIn(_:)), "+"),
            item("Pomniejsz", #selector(MarkdownDocument.zoomOut(_:)), "-"),
            item("Rzeczywisty rozmiar", #selector(MarkdownDocument.resetZoom(_:)), "0"),
        ]),
        windowMenu,
    ].forEach(main.addItem)
    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSDocumentController.shared
app.setActivationPolicy(.regular)
app.run()
