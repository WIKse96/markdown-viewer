(() => {
  'use strict';

  // Bridge to the native macOS shell (absent when index.html is opened in a browser).
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge;
  const post = (msg) => native && native.postMessage(msg);

  const $ = (s) => document.querySelector(s);
  const app = $('#app');
  const source = $('#source');
  const preview = $('#preview');
  const filenameEl = $('#filename');
  const editBtn = $('#btn-edit');
  const fileInput = $('#file-input');

  const MODES = ['preview', 'split', 'code'];
  const FRONT_MATTER = /^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;

  const state = {
    md: '',
    frontMatter: '',
    base: '',          // directory of the opened file, for resolving relative images/links
    mode: 'preview',
    editing: false,
    dirty: false,
    fileName: 'bez nazwy.md',
    fileHandle: null,  // browser-only (File System Access API)
  };

  if (native) document.documentElement.classList.add('native');

  // ---------- markdown <-> html ----------

  marked.setOptions({ gfm: true, breaks: false });
  hljs.configure({ ignoreUnescapedHTML: true });

  const turndown = new TurndownService({
    headingStyle: 'atx',
    codeBlockStyle: 'fenced',
    bulletListMarker: '-',
    emDelimiter: '*',
    strongDelimiter: '**',
    hr: '---',
  });
  turndown.use(turndownPluginGfm.gfm);
  turndown.addRule('strikethrough', {
    filter: ['del', 's', 'strike'],
    replacement: (content) => '~~' + content + '~~',
  });
  // Turndown's default pads list markers to 4 columns ("-   item"); use the common "- item" style.
  turndown.addRule('listItem', {
    filter: 'li',
    replacement: (content, node, options) => {
      const parent = node.parentNode;
      let prefix = options.bulletListMarker + ' ';
      if (parent.nodeName === 'OL') {
        const start = parent.getAttribute('start');
        const index = Array.prototype.indexOf.call(parent.children, node);
        prefix = (start ? Number(start) + index : index + 1) + '. ';
      }
      content = content
        .replace(/^\n+/, '')
        .replace(/\n+$/, '\n')
        .replace(/\n/gm, '\n' + ' '.repeat(prefix.length))
        .replace(/^(\[[ x]\]) +/, '$1 ');
      return prefix + content + (node.nextSibling && !/\n$/.test(content) ? '\n' : '');
    },
  });
  turndown.keep(['kbd', 'sup', 'sub', 'u', 'mark', 'details', 'summary']);

  const splitFrontMatter = (md) => {
    const m = md.match(FRONT_MATTER);
    return m ? [m[0], md.slice(m[0].length)] : ['', md];
  };

  const slugify = (text) => text.trim().toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s/g, '-');

  function render() {
    const [fm, body] = splitFrontMatter(state.md);
    state.frontMatter = fm;
    preview.innerHTML = DOMPurify.sanitize(marked.parse(body));

    if (fm) {
      const pre = document.createElement('pre');
      pre.className = 'front-matter';
      pre.contentEditable = 'false';
      pre.textContent = fm.trim();
      preview.prepend(pre);
    }

    const seen = {};
    preview.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach((h) => {
      const slug = slugify(h.textContent);
      seen[slug] = (seen[slug] || 0) + 1;
      h.id = seen[slug] > 1 ? `${slug}-${seen[slug] - 1}` : slug;
    });

    preview.querySelectorAll('pre:not(.front-matter) code').forEach((code) => {
      const lang = (code.className.match(/language-(\S+)/) || [])[1];
      if (lang && hljs.getLanguage(lang)) hljs.highlightElement(code);
    });

    // Relative images resolve against the file's directory; the original src is kept for round-tripping.
    if (state.base) {
      preview.querySelectorAll('img[src]').forEach((img) => {
        const src = img.getAttribute('src');
        if (/^[a-z][a-z0-9+.-]*:/i.test(src) || src.startsWith('//')) return;
        img.dataset.src = src;
        img.src = new URL(src, state.base).href;
      });
    }

    syncCheckboxes();
  }

  function previewToMarkdown() {
    const clone = preview.cloneNode(true);
    clone.querySelector('pre.front-matter')?.remove();
    clone.querySelectorAll('img[data-src]').forEach((img) => img.setAttribute('src', img.dataset.src));
    const body = turndown.turndown(clone.innerHTML).trimEnd() + '\n';
    return state.frontMatter ? state.frontMatter.replace(/\r?\n?$/, '\n') + '\n' + body : body;
  }

  // ---------- state changes ----------

  function markDirty() {
    post({ type: 'dirty' });
    if (!state.dirty) {
      state.dirty = true;
      app.classList.add('dirty');
      updateTitle();
    }
  }

  function markClean() {
    state.dirty = false;
    app.classList.remove('dirty');
    updateTitle();
  }

  function updateTitle() {
    filenameEl.textContent = state.fileName;
    if (!native) document.title = (state.dirty ? '● ' : '') + state.fileName;
  }

  function reportState() {
    post({ type: 'state', mode: state.mode, editing: state.editing });
  }

  function setMode(mode) {
    if (!MODES.includes(mode)) return;
    flushPreview();
    if (state.mode === 'code' && mode !== 'code') render(); // code-only edits skip live rendering
    state.mode = mode;
    app.classList.remove(...MODES.map((m) => 'mode-' + m));
    app.classList.add('mode-' + mode);
    document.querySelectorAll('.seg button').forEach((b) => b.classList.toggle('active', b.dataset.mode === mode));
    try { localStorage.setItem('mdv.mode', mode); } catch (_) { /* storage unavailable */ }
    reportState();
  }

  function setEditing(on) {
    flushPreview();
    state.editing = on;
    app.classList.toggle('editing', on);
    editBtn.classList.toggle('active', on);
    source.readOnly = !on;
    preview.contentEditable = on ? 'true' : 'false';
    syncCheckboxes();
    if (on) (state.mode === 'code' ? source : preview).focus();
    reportState();
  }

  function syncCheckboxes() {
    preview.querySelectorAll('input[type=checkbox]').forEach((cb) => { cb.disabled = !state.editing; });
  }

  function load(text, name, base) {
    previewTimer = clearTimeout(previewTimer);
    state.md = text;
    state.base = base || '';
    if (name) state.fileName = name;
    source.value = text;
    render();
    markClean();
    document.querySelector('#preview-wrap').scrollTop = 0;
    source.scrollTop = 0;
  }

  // ---------- editing ----------

  let renderTimer = null;
  source.addEventListener('input', () => {
    state.md = source.value;
    markDirty();
    clearTimeout(renderTimer);
    if (state.mode !== 'code') renderTimer = setTimeout(render, 120);
  });

  source.addEventListener('keydown', (e) => {
    if (e.key === 'Tab' && !source.readOnly && !e.metaKey && !e.ctrlKey) {
      e.preventDefault();
      document.execCommand('insertText', false, '  ');
    }
  });

  // Preview edits are converted back to markdown lazily (debounced, or flushed before save/mode switch).
  let previewTimer = null;
  function flushPreview() {
    if (!previewTimer) return;
    previewTimer = clearTimeout(previewTimer);
    state.md = previewToMarkdown();
    source.value = state.md;
  }

  preview.addEventListener('input', () => {
    if (!state.editing) return;
    markDirty();
    clearTimeout(previewTimer);
    previewTimer = setTimeout(flushPreview, 300);
  });

  // Flush pending preview edits as soon as focus leaves the preview.
  preview.addEventListener('focusout', () => {
    if (!previewTimer) return;
    flushPreview();
  });

  preview.addEventListener('change', (e) => {
    if (!e.target.matches('input[type=checkbox]')) return;
    e.target.toggleAttribute('checked', e.target.checked); // turndown reads serialized HTML, not the property
    preview.dispatchEvent(new Event('input'));
  });

  preview.addEventListener('click', (e) => {
    const a = e.target.closest('a[href]');
    if (!a) return;
    e.preventDefault();
    if (state.editing && !e.metaKey) return; // in edit mode, ⌘-click follows links

    const href = a.getAttribute('href');
    if (href.startsWith('#')) {
      const id = decodeURIComponent(href.slice(1));
      (document.getElementById(id) || document.getElementsByName(id)[0])?.scrollIntoView({ behavior: 'smooth' });
      return;
    }
    const url = new URL(href, state.base || location.href).href;
    if (native) post({ type: 'open', url });
    else window.open(url, '_blank', 'noopener');
  });

  // ---------- toolbar & shortcuts ----------

  document.querySelectorAll('.seg button').forEach((b) => b.addEventListener('click', () => setMode(b.dataset.mode)));
  editBtn.addEventListener('click', () => setEditing(!state.editing));
  $('#btn-open').addEventListener('click', () => browserOpen());
  $('#btn-save').addEventListener('click', () => browserSave());

  // In the native app these shortcuts come from the menu bar instead.
  if (!native) {
    document.addEventListener('keydown', (e) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
      const k = e.key.toLowerCase();
      const action = { '1': () => setMode('preview'), '2': () => setMode('split'), '3': () => setMode('code'),
        e: () => setEditing(!state.editing), s: () => browserSave(), o: () => browserOpen() }[k];
      if (action && !e.shiftKey) { e.preventDefault(); action(); }
    });

    window.addEventListener('beforeunload', (e) => {
      if (state.dirty) { e.preventDefault(); e.returnValue = ''; }
    });
  }

  // ---------- browser-only file handling ----------

  async function browserOpen() {
    if (window.showOpenFilePicker) {
      try {
        const [handle] = await showOpenFilePicker({
          types: [{ description: 'Markdown', accept: { 'text/markdown': ['.md', '.markdown', '.mdown', '.mkd'] } }],
        });
        state.fileHandle = handle;
        const file = await handle.getFile();
        load(await file.text(), file.name);
      } catch (_) { /* cancelled */ }
    } else {
      fileInput.click();
    }
  }

  fileInput.addEventListener('change', async () => {
    const file = fileInput.files[0];
    if (!file) return;
    state.fileHandle = null;
    load(await file.text(), file.name);
    fileInput.value = '';
  });

  async function browserSave() {
    flushPreview();
    try {
      if (window.showSaveFilePicker) {
        if (!state.fileHandle) {
          state.fileHandle = await showSaveFilePicker({
            suggestedName: state.fileName,
            types: [{ description: 'Markdown', accept: { 'text/markdown': ['.md'] } }],
          });
          state.fileName = state.fileHandle.name;
        }
        const w = await state.fileHandle.createWritable();
        await w.write(state.md);
        await w.close();
      } else {
        const a = document.createElement('a');
        a.href = URL.createObjectURL(new Blob([state.md], { type: 'text/markdown' }));
        a.download = state.fileName;
        a.click();
        URL.revokeObjectURL(a.href);
      }
      markClean();
    } catch (_) { /* cancelled */ }
  }

  if (!native) {
    let depth = 0;
    document.addEventListener('dragenter', (e) => { e.preventDefault(); depth++; app.classList.add('dragover'); });
    document.addEventListener('dragleave', () => { if (--depth <= 0) { depth = 0; app.classList.remove('dragover'); } });
    document.addEventListener('dragover', (e) => e.preventDefault());
    document.addEventListener('drop', async (e) => {
      e.preventDefault();
      depth = 0;
      app.classList.remove('dragover');
      const file = e.dataTransfer.files[0];
      if (!file) return;
      if (state.dirty && !confirm('Masz niezapisane zmiany. Otworzyć mimo to?')) return;
      state.fileHandle = null;
      load(await file.text(), file.name);
    });
  }

  // ---------- public API for the native shell ----------

  window.mdv = {
    load: ({ text, name, base }) => load(text, name, base),
    getMarkdown: () => { flushPreview(); return state.md; },
    setMode,
    toggleEdit: () => setEditing(!state.editing),
    setFile: ({ name, base }) => {
      state.fileName = name;
      if (base !== state.base) { state.base = base; render(); }
    },
    markClean,
  };

  let savedMode = 'preview';
  try { savedMode = localStorage.getItem('mdv.mode') || 'preview'; } catch (_) { /* storage unavailable */ }
  setMode(savedMode);
  setEditing(false);
  updateTitle();
  if (!native) load('# Markdown Viewer\n\nOtwórz plik przyciskiem **Otwórz**, skrótem `⌘O` albo przeciągnij go tutaj.\n', 'bez nazwy.md');
})();
