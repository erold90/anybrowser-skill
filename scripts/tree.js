// Eyes on the accessibility tree of the frontmost window.
//   osascript -l JavaScript tree.js                → named elements, capped
//   osascript -l JavaScript tree.js "Save"         → matches, best first
//   osascript -l JavaScript tree.js "Save" pick    → "X Y<TAB>label" of the best clickable match
//   osascript -l JavaScript tree.js "Email" field  → same, but only text inputs
//   osascript -l JavaScript tree.js "" text        → the window's readable text, in order
//
// Fast path: the Accessibility API, in-process (~0.3 s on a busy web page).
// Without the Accessibility permission it falls back to System Events, which
// needs only Automation but costs one Apple Event per attribute (~10+ s).
ObjC.import("AppKit");
ObjC.bindFunction("AXIsProcessTrusted", ["bool", []]);
ObjC.bindFunction("AXUIElementCreateApplication", ["id", ["int"]]);
ObjC.bindFunction("AXUIElementCopyAttributeValue", ["int", ["id", "id", "id*"]]);
ObjC.bindFunction("AXUIElementSetAttributeValue", ["int", ["id", "id", "id"]]);

const MAX_DEPTH = 40;
const MAX_NODES = 8000;
const LIST_CAP = 200;
const TEXT_CAP = 400;

const INPUT_ROLES = ["TextField", "TextArea", "ComboBox", "SearchField", "SecureTextField"];
const TEXT_ROLES = ["StaticText", "Heading", "Link", "Button", "Cell", "MenuItem"];
// Chromium builds the page's tree only once an assistive app asks for it.
const CHROMIUM = /^(com\.google\.Chrome|com\.brave\.Browser|com\.microsoft\.edgemac|company\.thebrowser\.Browser|com\.vivaldi\.Vivaldi|com\.operasoftware\.Opera)/;

function viaAccessibility() {
  const front = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  const app = $.AXUIElementCreateApplication(front.processIdentifier);

  const attr = (el, name) => {
    const ref = Ref();
    return $.AXUIElementCopyAttributeValue(el, $(name), ref) === 0 ? ref[0] : null;
  };
  const text = (v) => {
    if (!v) return "";
    try { const s = ObjC.unwrap(v); return typeof s === "string" ? s.trim() : ""; } catch (e) { return ""; }
  };
  // AXValue has no JS bridge; its description reads "{value = x:12 y:34 ...}".
  const pair = (v) => {
    if (!v) return null;
    const m = ObjC.unwrap(v.description).match(/[xw]:(-?[\d.]+) [yh]:(-?[\d.]+)/);
    return m ? [Number(m[1]), Number(m[2])] : null;
  };

  const win = attr(app, "AXFocusedWindow") || attr(app, "AXMainWindow");
  if (!win) return null;

  function collect() {
    const found = [];
    let visited = 0, sawWeb = false;
    (function walk(el, depth, inWeb) {
      if (depth > MAX_DEPTH || visited++ > MAX_NODES) return;
      const role = text(attr(el, "AXRole")).replace(/^AX/, "");
      if (role === "WebArea") sawWeb = inWeb = true;
      // For text inputs the title or placeholder is the name; the value is what's typed.
      const name = text(attr(el, "AXTitle")) || text(attr(el, "AXDescription")) ||
        (INPUT_ROLES.includes(role) ? text(attr(el, "AXPlaceholderValue")) : "") ||
        text(attr(el, "AXValue"));
      if (name) {
        const pos = pair(attr(el, "AXPosition"));
        const size = pair(attr(el, "AXSize"));
        const enabled = attr(el, "AXEnabled");
        found.push({
          name,
          role,
          point: pos && size && size[0] > 0 ? [Math.round(pos[0] + size[0] / 2), Math.round(pos[1] + size[1] / 2)] : null,
          disabled: enabled !== null && ObjC.unwrap(enabled) === false,
          inWeb,
        });
      }
      const kids = attr(el, "AXChildren");
      if (!kids) return;
      for (let i = 0; i < kids.count; i++) walk(kids.objectAtIndex(i), depth + 1, inWeb);
    })(win, 0, false);
    return { found, sawWeb };
  }

  let { found, sawWeb } = collect();
  if (!sawWeb && CHROMIUM.test(ObjC.unwrap(front.bundleIdentifier) || "")) {
    // The attribute VoiceOver sets. Chrome answers with an error code and turns
    // its page tree on anyway, about two seconds later. Setting it again before
    // then starts the wait over, so ask and poll; a marker keeps windows with no
    // page (dialogs, panels) from paying the wait on every call. It expires, in
    // case the browser switches the mode back off when nobody asks for a while.
    const env = $.NSProcessInfo.processInfo.environment;
    const tmp = ObjC.unwrap(env.objectForKey("TMPDIR")) || "/tmp/";
    const marker = `${tmp.replace(/\/?$/, "/")}macuse-chromium-${front.processIdentifier}`;
    const fm = $.NSFileManager.defaultManager;
    const info = fm.attributesOfItemAtPathError($(marker), null);
    const age = info.isNil() ? Infinity : -info.objectForKey("NSFileModificationDate").timeIntervalSinceNow;
    if (age > 120) {
      $.AXUIElementSetAttributeValue(app, $("AXEnhancedUserInterface"), $(true));
      $("").writeToFileAtomicallyEncodingError($(marker), true, $.NSUTF8StringEncoding, null);
      for (let i = 0; i < 10 && !sawWeb; i++) {
        delay(0.5);
        ({ found, sawWeb } = collect());
      }
    }
  }
  return found;
}

function viaSystemEvents() {
  const proc = Application("System Events").processes.whose({ frontmost: true })[0];
  let win;
  try { win = proc.windows[0]; win.name(); } catch (e) { return null; }

  const found = [];
  let visited = 0;
  const label = (el) => {
    for (const get of [() => el.name(), () => el.description(), () => el.title()]) {
      try { const v = get(); if (v && v !== "missing value") return String(v).trim(); } catch (e) {}
    }
    return "";
  };
  (function walk(el, depth) {
    if (depth > 8 || visited++ > 4000) return;
    const name = label(el);
    if (name) {
      let role = "", point = null, disabled = false;
      try { role = String(el.role()).replace(/^AX/, ""); } catch (e) {}
      try {
        const [x, y] = el.position(), [w, h] = el.size();
        if (w > 0) point = [Math.round(x + w / 2), Math.round(y + h / 2)];
      } catch (e) {}
      try { disabled = el.enabled() === false; } catch (e) {}
      found.push({ name, role, point, disabled });
    }
    let kids = [];
    try { kids = el.uiElements(); } catch (e) { return; }
    for (const k of kids) walk(k, depth + 1);
  })(win, 0);
  return found;
}

function run(argv) {
  const needle = (argv[0] || "").trim().toLowerCase();
  const mode = argv[1] || "list";
  const found = $.AXIsProcessTrusted() ? viaAccessibility() : viaSystemEvents();
  if (found === null) return "the frontmost app has no window";

  const flat = (s) => s.replace(/\s+/g, " ");

  if (mode === "text") {
    // On a web page, the page — not the browser's toolbar.
    const source = found.some((s) => s.inWeb) ? found.filter((s) => s.inWeb) : found;
    const out = [];
    for (const s of source) {
      if (!TEXT_ROLES.includes(s.role)) continue;
      const t = flat(s.name);
      if (t && out[out.length - 1] !== t) out.push(t);
    }
    if (!out.length) return "no readable text in the front window";
    if (out.length > TEXT_CAP) return out.slice(0, TEXT_CAP).join("\n") + `\n… ${out.length - TEXT_CAP} more lines`;
    return out.join("\n");
  }

  let rows = found;
  if (mode === "field") rows = rows.filter((s) => INPUT_ROLES.includes(s.role));
  if (mode === "pick" || mode === "field") rows = rows.filter((s) => s.point && !s.disabled);

  if (needle) {
    // Exact name first, then prefix, then anywhere: "Save" before "Save As…".
    const rank = (s) => {
      const n = s.name.toLowerCase();
      return n === needle ? 0 : n.startsWith(needle) ? 1 : n.includes(needle) ? 2 : -1;
    };
    rows = rows
      .map((s, i) => ({ s, r: rank(s), i }))
      .filter((x) => x.r >= 0)
      .sort((a, b) => a.r - b.r || a.i - b.i)
      .map((x) => x.s);
    if (!rows.length) return `no element matching: ${argv[0]}`;
  } else if (!rows.length) {
    return "no named elements in the front window";
  }

  const label = (s) => `${flat(s.name).slice(0, 100)}  [${s.role}]`;

  if (mode === "pick" || mode === "field") {
    const best = rows[0];
    const more = rows.length > 1 ? `  (+${rows.length - 1} more)` : "";
    return `${best.point[0]} ${best.point[1]}\t${label(best)}${more}`;
  }

  const line = (s) =>
    label(s) + (s.point ? `  ->  ${s.point[0]} ${s.point[1]}` : "") + (s.disabled ? "  (disabled)" : "");
  // Toolbars often expose the same control several times over.
  const lines = rows.map(line).filter((l, i, all) => i === 0 || l !== all[i - 1]);
  const out = lines.slice(0, LIST_CAP);
  if (lines.length > LIST_CAP) out.push(`… ${lines.length - LIST_CAP} more — narrow it with: where <text>`);
  return out.join("\n");
}
