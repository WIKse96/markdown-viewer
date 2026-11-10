#!/usr/bin/env python3
"""Markdown Viewer dla Linuksa: GTK3 + WebKitGTK, ten sam interfejs webowy co na macOS."""
import json
import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.0")
from gi.repository import Gio, GLib, Gtk, WebKit2  # noqa: E402

MD_EXT = {".md", ".markdown", ".mdown", ".mkd", ".mkdn"}


def find_web_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.join(here, "web"), os.path.join(here, "..", "web")):
        if os.path.isfile(os.path.join(p, "index.html")):
            return os.path.abspath(p)
    sys.exit("Nie znaleziono katalogu web/ z interfejsem.")


WEB_DIR = find_web_dir()


class Document(Gtk.ApplicationWindow):
    def __init__(self, app, path=None):
        super().__init__(application=app)
        self.path = path
        self.text = ""
        self.dirty = False
        self.loaded = False
        self.mode = "preview"
        self.editing = False
        self.set_default_size(960, 760)
        self.set_icon_name("markdown-viewer")

        if path:
            with open(path, "rb") as f:
                raw = f.read()
            try:
                self.text = raw.decode("utf-8")
            except UnicodeDecodeError:
                self.text = raw.decode("latin-1")

        ucm = WebKit2.UserContentManager()
        ucm.register_script_message_handler("bridge")
        ucm.connect("script-message-received::bridge", self.on_message)
        self.web = WebKit2.WebView.new_with_user_content_manager(ucm)
        s = self.web.get_settings()
        s.set_allow_file_access_from_file_urls(True)
        s.set_allow_universal_access_from_file_urls(True)
        self.web.connect("load-changed", self.on_load)
        self.web.connect("decide-policy", self.on_policy)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.pack_start(self.build_menu(app), False, False, 0)
        box.pack_start(self.build_search(), False, False, 0)
        box.pack_start(self.web, True, True, 0)
        self.add(box)
        self.connect("delete-event", self.on_close)
        self.update_title()
        self.web.load_uri("file://" + os.path.join(WEB_DIR, "index.html"))
        self.show_all()

    # ---- menu & shortcuts ----
    def build_menu(self, app):
        acc = Gtk.AccelGroup()
        self.add_accel_group(acc)
        bar = Gtk.MenuBar()

        def add(menu, label, key, cb):
            it = Gtk.MenuItem.new_with_label(label)
            if key:
                k, m = Gtk.accelerator_parse(key)
                it.add_accelerator("activate", acc, k, m, Gtk.AccelFlags.VISIBLE)
            it.connect("activate", lambda _w: cb())
            menu.append(it)

        def top(title):
            m = Gtk.Menu()
            h = Gtk.MenuItem.new_with_label(title)
            h.set_submenu(m)
            bar.append(h)
            return m

        f = top("Plik")
        add(f, "Nowy", "<Control>n", lambda: app.open_doc(None))
        add(f, "Otwórz…", "<Control>o", self.open_dialog)
        add(f, "Zapisz", "<Control>s", self.save)
        add(f, "Zapisz jako…", "<Control><Shift>s", self.save_as)
        add(f, "Zamknij", "<Control>w", self.close)
        add(f, "Zakończ", "<Control>q", app.quit_all)
        e = top("Edycja")
        add(e, "Znajdź…", "<Control>f", self.show_search)
        add(e, "Znajdź następne", "<Control>g", lambda: self.find.search_next())
        add(e, "Znajdź poprzednie", "<Control><Shift>g", lambda: self.find.search_previous())
        add(e, "Znajdź następne ", "F3", lambda: self.find.search_next())
        add(e, "Znajdź poprzednie ", "<Shift>F3", lambda: self.find.search_previous())
        v = top("Widok")
        add(v, "Podgląd", "<Control>1", lambda: self.js("mdv.setMode('preview')"))
        add(v, "Podział", "<Control>2", lambda: self.js("mdv.setMode('split')"))
        add(v, "Kod", "<Control>3", lambda: self.js("mdv.setMode('code')"))
        add(v, "Edycja", "<Control>e", lambda: self.js("mdv.toggleEdit()"))
        add(v, "Powiększ", "<Control>plus", lambda: self.zoom(0.1))
        add(v, "Powiększ ", "<Control>equal", lambda: self.zoom(0.1))
        add(v, "Pomniejsz", "<Control>minus", lambda: self.zoom(-0.1))
        add(v, "Rzeczywisty rozmiar", "<Control>0", lambda: self.web.set_zoom_level(1))
        return bar

    # ---- search (Ctrl+F) ----
    def build_search(self):
        self.find = self.web.get_find_controller()
        self.find.connect("found-text", lambda *_: self.entry.get_style_context().remove_class("error"))
        self.find.connect("failed-to-find-text", lambda *_: self.entry.get_style_context().add_class("error"))
        self.search_bar = Gtk.SearchBar()
        box = Gtk.Box(spacing=4)
        self.entry = Gtk.SearchEntry()
        self.entry.set_width_chars(32)
        self.entry.connect("search-changed", self.on_search_changed)
        self.entry.connect("activate", lambda _e: self.find.search_next())
        self.entry.connect("previous-match", lambda _e: self.find.search_previous())
        self.entry.connect("next-match", lambda _e: self.find.search_next())
        prev = Gtk.Button.new_from_icon_name("go-up-symbolic", Gtk.IconSize.BUTTON)
        nxt = Gtk.Button.new_from_icon_name("go-down-symbolic", Gtk.IconSize.BUTTON)
        prev.connect("clicked", lambda _b: self.find.search_previous())
        nxt.connect("clicked", lambda _b: self.find.search_next())
        for w in (self.entry, prev, nxt):
            box.pack_start(w, False, False, 0)
        self.search_bar.add(box)
        self.search_bar.connect_entry(self.entry)
        self.search_bar.connect("notify::search-mode-enabled", self.on_search_mode)
        return self.search_bar

    def show_search(self):
        self.search_bar.set_search_mode(True)
        self.entry.grab_focus()
        self.entry.select_region(0, -1)
        self.on_search_changed(self.entry)

    def on_search_changed(self, entry):
        text = entry.get_text()
        if text:
            self.find.search(text, WebKit2.FindOptions.CASE_INSENSITIVE | WebKit2.FindOptions.WRAP_AROUND, 1000)
        else:
            self.find.search_finish()
            entry.get_style_context().remove_class("error")

    def on_search_mode(self, bar, _p):
        if not bar.get_search_mode():
            self.find.search_finish()
            self.web.grab_focus()

    def zoom(self, d):
        self.web.set_zoom_level(min(3, max(0.5, self.web.get_zoom_level() + d)))

    def js(self, code, cb=None):
        self.web.run_javascript(code, None, cb, None)

    # ---- web bridge ----
    def push(self):
        if not self.loaded:
            return
        base = Gio.File.new_for_path(os.path.dirname(os.path.abspath(self.path))).get_uri() + "/" if self.path else ""
        name = os.path.basename(self.path) if self.path else "bez nazwy.md"
        self.js("mdv.load(%s)" % json.dumps({"text": self.text, "name": name, "base": base}))

    def on_load(self, _w, ev):
        if ev == WebKit2.LoadEvent.FINISHED and not self.loaded:
            self.loaded = True
            self.push()

    def on_policy(self, _w, decision, dtype):
        if dtype == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            uri = decision.get_navigation_action().get_request().get_uri()
            if not self.loaded and uri.startswith("file://" + WEB_DIR):
                decision.use()
            else:
                decision.ignore()
            return True
        return False

    def on_message(self, _m, result):
        try:
            body = json.loads(result.get_js_value().to_json(0))
        except Exception:
            return
        t = body.get("type")
        if t == "dirty":
            if not self.dirty:
                self.dirty = True
                self.update_title()
        elif t == "state":
            self.mode = body.get("mode", self.mode)
            self.editing = body.get("editing", self.editing)
        elif t == "open":
            self.open_url(body.get("url", ""))

    def open_url(self, url):
        if url.startswith("file://"):
            p = Gio.File.new_for_uri(url.split("#")[0]).get_path()
            if p and os.path.splitext(p)[1].lower() in MD_EXT:
                self.get_application().open_doc(p)
            elif p:
                Gtk.show_uri_on_window(self, "file://" + p, Gtk.get_current_event_time())
        elif url.split(":")[0].lower() in ("http", "https", "mailto"):
            Gtk.show_uri_on_window(self, url, Gtk.get_current_event_time())

    # ---- files ----
    def update_title(self):
        name = os.path.basename(self.path) if self.path else "bez nazwy.md"
        self.set_title(("● " if self.dirty else "") + name + " — Markdown Viewer")

    def open_dialog(self):
        d = Gtk.FileChooserDialog(title="Otwórz", parent=self, action=Gtk.FileChooserAction.OPEN)
        d.add_buttons("Anuluj", Gtk.ResponseType.CANCEL, "Otwórz", Gtk.ResponseType.OK)
        if d.run() == Gtk.ResponseType.OK:
            self.get_application().open_doc(d.get_filename())
        d.destroy()

    def get_markdown(self, then):
        def done(web, res, _):
            try:
                self.text = web.run_javascript_finish(res).get_js_value().to_string()
            except Exception:
                pass
            then()
        self.js("mdv.getMarkdown()", done)

    def save(self, then=None):
        if not self.path:
            return self.save_as(then)
        self.get_markdown(lambda: self.write(then))

    def save_as(self, then=None):
        d = Gtk.FileChooserDialog(title="Zapisz jako", parent=self, action=Gtk.FileChooserAction.SAVE)
        d.add_buttons("Anuluj", Gtk.ResponseType.CANCEL, "Zapisz", Gtk.ResponseType.OK)
        d.set_do_overwrite_confirmation(True)
        d.set_current_name(os.path.basename(self.path) if self.path else "bez nazwy.md")
        ok = d.run() == Gtk.ResponseType.OK
        fn = d.get_filename()
        d.destroy()
        if ok:
            self.path = fn
            self.get_markdown(lambda: self.write(then))

    def write(self, then):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(self.text)
        self.dirty = False
        self.update_title()
        base = Gio.File.new_for_path(os.path.dirname(os.path.abspath(self.path))).get_uri() + "/"
        self.js("mdv.setFile(%s); mdv.markClean()" % json.dumps({"name": os.path.basename(self.path), "base": base}))
        if then:
            then()

    def on_close(self, _w, _e):
        if not self.dirty:
            return False
        m = Gtk.MessageDialog(parent=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                              text="Zapisać zmiany?", secondary_text="Niezapisane zmiany zostaną utracone.")
        m.add_buttons("Nie zapisuj", Gtk.ResponseType.REJECT, "Anuluj", Gtk.ResponseType.CANCEL,
                      "Zapisz", Gtk.ResponseType.ACCEPT)
        r = m.run()
        m.destroy()
        if r == Gtk.ResponseType.REJECT:
            return False
        if r == Gtk.ResponseType.ACCEPT:
            self.save(then=lambda: (setattr(self, "dirty", False), self.destroy()))
        return True


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="io.github.wikse96.MarkdownViewer",
                         flags=Gio.ApplicationFlags.HANDLES_OPEN)

    def open_doc(self, path):
        Document(self, path)

    def quit_all(self):
        for w in list(self.get_windows()):
            w.close()

    def do_activate(self):
        Document(self, None)

    def do_open(self, files, _n, _hint):
        for f in files:
            if f.get_path():
                self.open_doc(f.get_path())


if __name__ == "__main__":
    GLib.set_prgname("markdown-viewer")
    GLib.set_application_name("Markdown Viewer")
    Gtk.Window.set_default_icon_name("markdown-viewer")
    sys.exit(App().run(sys.argv))
