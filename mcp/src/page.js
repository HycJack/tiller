// Everything the browser tools do inside a page, as one function of an
// operation and its argument: `read` lists the page, `locate`, `focus` and
// `select` act on an element by ref or CSS selector, `settle` waits for the
// page to react to input, and `observe` reads the visible part for run_task.
//
// Refs live in the page, kept against the element itself rather than written
// into the DOM, so an element keeps its ref across reads and a re-rendered one
// gets a new ref. Each ref also keeps the element's role and name when last
// read, and acting on a ref whose element has since become something else
// fails instead of clicking the wrong thing.
//
// Name, role and visibility rules follow jev-ultrafast's snapshot.js
// (https://github.com/browser-use/jev-ultrafast, MIT).
(op, arg) => {
  let T = window.__tillerRefs;
  if (!T) {
    T = { ids: new WeakMap(), nodes: new Map(), guards: new Map(), next: 1 };
    Object.defineProperty(window, '__tillerRefs', { value: T });
  }
  const clean = s => String(s ?? '').replace(/\s+/g, ' ').trim();
  const refOf = e => {
    let id = T.ids.get(e);
    if (!id) {
      id = String(T.next++);
      T.ids.set(e, id);
    }
    T.nodes.set(id, e);
    return id;
  };

  const ROLES = ['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
    'menuitemradio', 'option', 'combobox', 'listbox', 'textbox', 'searchbox', 'spinbutton', 'slider', 'treeitem'];
  const SELECTOR = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [contenteditable=""], ' +
    '[contenteditable=true], [onclick], ' + ROLES.filter(r => r !== 'listbox').map(r => `[role=${r}]`).join(', ');
  const roleOf = e => {
    const explicit = e.getAttribute('role');
    if (ROLES.includes(explicit)) return explicit;
    const tag = e.tagName;
    if (tag === 'A') return 'link';
    if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
    if (tag === 'SELECT') return e.multiple || e.size > 1 ? 'listbox' : 'combobox';
    if (tag === 'TEXTAREA' || e.isContentEditable) return 'textbox';
    if (tag === 'INPUT') {
      const type = e.type;
      if (type === 'checkbox' || type === 'radio') return type;
      if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
      if (type === 'search') return 'searchbox';
      if (type === 'number') return 'spinbutton';
      if (type === 'range') return 'slider';
      if (e.list) return 'combobox';
      if (['text', 'email', 'url', 'tel', 'password'].includes(type)) return 'textbox';
      return type;
    }
    return explicit || null;
  };
  // Fields whose content is a value the user typed, not part of their name.
  const editable = e => ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName) || e.isContentEditable;
  const textOf = e => clean(e.innerText ?? e.textContent);
  const nameOf = e => {
    const labelledBy = (e.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)
      .map(id => document.getElementById(id)).filter(Boolean).map(textOf).filter(Boolean).join(' ');
    const labels = [...(e.labels || [])].map(textOf).filter(Boolean).join(' ');
    const buttonValue = e.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(e.type) ? e.value : '';
    return clean(labelledBy || e.getAttribute('aria-label') || labels || buttonValue || e.getAttribute('alt') ||
      (editable(e) ? '' : textOf(e)) || e.querySelector('img[alt]')?.alt || e.getAttribute('title') ||
      e.getAttribute('placeholder') || '').slice(0, 100);
  };
  // What a ref must still be when it is acted on. A field's name doesn't
  // count for a contenteditable one, whose text is its value.
  const guardOf = e => JSON.stringify([e.tagName, roleOf(e), e.isContentEditable ? '' : nameOf(e)]);
  const describe = e => `${roleOf(e) || e.tagName.toLowerCase()} ${JSON.stringify(nameOf(e))}`;
  const shown = e => {
    if (e.closest('[inert], [aria-hidden="true"]')) return false;
    // Styled checkboxes and radios are often transparent under their label,
    // and still work.
    const quiet = e.tagName === 'INPUT' && (e.type === 'checkbox' || e.type === 'radio');
    return e.checkVisibility({ checkOpacity: !quiet, checkVisibilityCSS: true });
  };
  const usable = e => !e.matches(':disabled') && !e.closest('[aria-disabled="true"]');
  // Whether something else is on top of the element at (x, y). Its own label
  // doesn't count: a click there reaches it.
  const covered = (e, x, y) => {
    const hit = document.elementFromPoint(x, y);
    return !!hit && hit !== e && !e.contains(hit) && ![...(e.labels || [])].some(l => l.contains(hit));
  };

  const find = target => {
    // run_task passes the URL it decided on: a page that has moved on since
    // is not the one the decision was about.
    if (target.url != null && target.url !== location.href) return { error: 'the page changed; read it again' };
    if (target.selector != null) {
      const e = document.querySelector(target.selector);
      return e ? { e } : { error: `no element matches ${target.selector}` };
    }
    const ref = String(target.ref);
    const e = T.nodes.get(ref);
    if (!e || !e.isConnected) {
      return { error: Number(ref) < T.next
        ? `ref ${ref} is no longer on the page; call read_page again`
        : `no element has ref ${ref}; call read_page first` };
    }
    const was = T.guards.get(ref);
    if (was !== undefined && was !== guardOf(e)) {
      return { error: `ref ${ref} changed since it was read, it is now ${describe(e)}; call read_page again` };
    }
    return { e };
  };

  const item = (e, ref, rect) => {
    const tag = e.tagName.toLowerCase();
    const it = { ref, tag, text: nameOf(e) };
    const role = roleOf(e);
    if (tag === 'input') it.type = e.type;
    if (role) it.role = role;
    if (tag === 'a') it.href = e.href;
    // A password field's value never goes into the result; `filled` says
    // whether it holds anything.
    if (tag === 'input' && e.type === 'password') {
      it.filled = !!e.value;
    } else if (tag === 'select') {
      it.value = [...e.selectedOptions].map(o => clean(o.label)).join(', ');
      const options = [...e.options];
      it.options = options.slice(0, 100).map(o => {
        const option = { label: clean(o.label) };
        if (o.value !== option.label) option.value = o.value;
        if (o.selected) option.selected = true;
        if (o.disabled || o.closest('optgroup[disabled]')) option.disabled = true;
        return option;
      });
      if (options.length > 100) it.more_options = options.length - 100;
    } else if ((tag === 'input' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file'].includes(e.type)) ||
               tag === 'textarea') {
      it.value = String(e.value).slice(0, 200);
    } else if (e.isContentEditable) {
      it.value = textOf(e).slice(0, 200);
    }
    if (e.readOnly || e.getAttribute('aria-readonly') === 'true') it.readonly = true;
    if (tag === 'input' && (e.type === 'checkbox' || e.type === 'radio')) it.checked = e.checked;
    for (const key of ['checked', 'selected', 'expanded', 'pressed']) {
      const value = e.getAttribute('aria-' + key);
      if (value !== null && !(key in it)) it[key] = value === 'true' ? true : value === 'false' ? false : value;
    }
    if (rect.bottom < 0 || rect.top > innerHeight) it.offscreen = true;
    return it;
  };

  const inView = r => r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;

  // Text in the viewport only: what a person sees without scrolling.
  const visibleText = max => {
    const words = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), range = document.createRange();
    let node, length = 0;
    while ((node = walker.nextNode()) && length < max) {
      const value = node.textContent.trim(), parent = node.parentElement;
      if (!value || !parent || parent.closest('script, style, noscript, template') || !shown(parent)) continue;
      range.selectNodeContents(node);
      if (inView(range.getBoundingClientRect())) {
        words.push(value);
        length += value.length + 1;
      }
    }
    return words.join('\n');
  };

  const read = ({ max = 20000, viewport = false, limit = 400 }) => {
    for (const [id, e] of T.nodes) if (!e.isConnected) { T.nodes.delete(id); T.guards.delete(id); }
    const elements = [];
    let more = 0;
    if (document.body) for (const e of document.querySelectorAll(SELECTOR)) {
      const rect = e.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0 || !usable(e) || !shown(e)) continue;
      if (viewport && !inView(rect)) continue;
      if (elements.length >= limit) { more++; continue; }
      const ref = refOf(e);
      T.guards.set(ref, guardOf(e));
      elements.push(item(e, ref, rect));
    }
    const full = !document.body ? '' : viewport ? visibleText(max + 1) : document.body.innerText;
    const page = { url: location.href, title: document.title, text: full.slice(0, max), truncated: full.length > max, elements };
    if (more) page.more_elements = more;
    if (viewport) {
      const height = document.documentElement.scrollHeight;
      page.scroll = { y: Math.round(scrollY), height, viewport: innerHeight, width: innerWidth };
    }
    return page;
  };

  if (op === 'read') return read(arg);

  if (op === 'locate') {
    // Scrolls the element to the middle of the viewport and returns its
    // center in viewport coordinates, which is what DevTools mouse events
    // use. The scroll is instant even on pages with CSS smooth scrolling.
    const { e, error } = find(arg.target);
    if (error) return { error };
    if (arg.scroll !== false) e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const rect = e.getBoundingClientRect();
    const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
    const hit = document.elementFromPoint(x, y);
    return { x, y, covered: covered(e, x, y), editable: editable(e) };
  }

  if (op === 'focus') {
    // Focuses the field and selects its content, so typed text replaces it
    // unless `append` is set. A click on some fields replaces them with
    // another, or opens one, as a search box that opens a dialog with its own
    // input: then the field that has focus now takes the text.
    let { e, error } = find(arg.target);
    let moved = false;
    const active = document.activeElement;
    if ((error || !shown(e) || !editable(e)) && active && active !== e && active !== document.body && editable(active)) {
      e = active;
      moved = true;
    } else if (error) {
      return { error };
    }
    if (arg.scroll !== false) e.scrollIntoView({ block: 'center', behavior: 'instant' });
    e.focus();
    if (arg.append) {
      if (typeof e.setSelectionRange === 'function' && typeof e.value === 'string') {
        try { e.setSelectionRange(e.value.length, e.value.length); } catch {}
      }
    } else if (typeof e.select === 'function') {
      e.select();
    } else if (e.isContentEditable) {
      const range = document.createRange();
      range.selectNodeContents(e);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    return { moved };
  }

  if (op === 'select') {
    const { e, error } = find(arg.target);
    if (error) return { error };
    if (e.tagName !== 'SELECT') {
      return { error: `that is ${describe(e)}, not a <select>; click it to open it, then click the option` };
    }
    const wanted = clean(arg.option), lower = wanted.toLowerCase();
    const options = [...e.options].filter(o => !o.disabled && !o.closest('optgroup[disabled]'));
    const option = options.find(o => o.value === arg.option) ||
      options.find(o => clean(o.label) === wanted) ||
      options.find(o => clean(o.label).toLowerCase() === lower) ||
      (matches => matches.length === 1 ? matches[0] : null)(options.filter(o => clean(o.label).toLowerCase().includes(lower)));
    if (!option) {
      return { error: `no enabled option of ${describe(e)} matches ${JSON.stringify(arg.option)}; options: ` +
        options.slice(0, 30).map(o => JSON.stringify(clean(o.label))).join(', ') };
    }
    if (arg.scroll !== false) e.scrollIntoView({ block: 'center', behavior: 'instant' });
    e.focus();
    if (e.multiple) option.selected = true;
    else e.value = option.value;
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    return { selected: clean(option.label), value: option.value };
  }

  if (op === 'settle') {
    // After input, gives the page two frames, at most 50 ms, to react. After
    // typing into a combobox, waits for its suggestions instead, at most
    // 200 ms, so the next read sees them.
    const target = arg.target || {};
    const field = target.selector != null ? document.querySelector(target.selector)
      : target.ref != null ? T.nodes.get(String(target.ref)) : null;
    const suggesting = arg.typed && (field?.getAttribute('role') === 'combobox' || field?.getAttribute('aria-autocomplete') ||
      document.activeElement?.getAttribute('role') === 'combobox');
    return new Promise(resolve => {
      let frames = 0, done = false;
      const finish = () => { if (!done) { done = true; resolve(true); } };
      setTimeout(finish, suggesting ? 200 : 50);
      const ready = () => {
        if (done) return;
        const box = field?.isConnected ? field : document.activeElement;
        const ids = (box?.getAttribute('aria-controls') || box?.getAttribute('aria-owns') || '').split(/\s+/).filter(Boolean);
        const roots = ids.length ? ids.map(id => document.getElementById(id)).filter(Boolean) : [document];
        if (++frames >= 2 && (!suggesting || roots.some(root =>
          [...root.querySelectorAll('[role=option]')].some(o => inView(o.getBoundingClientRect()) && shown(o))))) finish();
        else requestAnimationFrame(ready);
      };
      requestAnimationFrame(ready);
    });
  }

  if (op === 'observe') {
    // What run_task decides on: the visible text and controls, and a marker
    // that changes when what they mean changes, to tell a stale decision.
    const page = read({ max: 6000, viewport: true, limit: 250 });
    // Only what a click can reach: centered in the viewport and not under
    // another element, such as a dialog's backdrop.
    page.elements = page.elements.filter(it => {
      const e = T.nodes.get(it.ref), r = e.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      return x >= 0 && y >= 0 && x < innerWidth && y < innerHeight && !covered(e, x, y);
    });
    const marker = JSON.stringify([location.href, page.text, page.scroll.y, innerWidth, innerHeight,
      page.elements.map(({ offscreen, ...rest }) => rest)]);
    let hash = 2166136261;
    for (let i = 0; i < marker.length; i++) hash = Math.imul(hash ^ marker.charCodeAt(i), 16777619);
    page.marker = (hash >>> 0).toString(16) + ':' + marker.length;
    return page;
  }

  return { error: `unknown page operation ${op}` };
}
