// Eyes on the accessibility tree of the frontmost window.
//   osascript -l JavaScript tree.js            → named elements, capped
//   osascript -l JavaScript tree.js "Save"     → matches, best first
//
// Fast path: the Accessibility API, in-process (~0.3 s on a busy web page).
// Without the Accessibility permission it falls back to System Events, which
// needs only Automation but costs one Apple Event per attribute (~10+ s).
ObjC.import("AppKit");
ObjC.bindFunction("AXIsProcessTrusted", ["bool", []]);
ObjC.bindFunction("AXUIElementCreateApplication", ["id", ["int"]]);
ObjC.bindFunction("AXUIElementCopyAttributeValue", ["int", ["id", "id", "id*"]]);

const MAX_DEPTH = 12;
const MAX_NODES = 6000;
const LIST_CAP = 200;

function viaAccessibility() {
  const pid = $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  const app = $.AXUIElementCreateApplication(pid);

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

  const found = [];
  let visited = 0;
  (function walk(el, depth) {
    if (depth > MAX_DEPTH || visited++ > MAX_NODES) return;
    const name = text(attr(el, "AXTitle")) || text(attr(el, "AXDescription")) || text(attr(el, "AXValue"));
    if (name) {
      const pos = pair(attr(el, "AXPosition"));
      const size = pair(attr(el, "AXSize"));
      const enabled = attr(el, "AXEnabled");
      found.push({
        name,
        role: text(attr(el, "AXRole")).replace(/^AX/, ""),
        point: pos && size && size[0] > 0 ? [Math.round(pos[0] + size[0] / 2), Math.round(pos[1] + size[1] / 2)] : null,
        disabled: enabled !== null && ObjC.unwrap(enabled) === false,
      });
    }
    const kids = attr(el, "AXChildren");
    if (!kids) return;
    for (let i = 0; i < kids.count; i++) walk(kids.objectAtIndex(i), depth + 1);
  })(win, 0);
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
  const found = $.AXIsProcessTrusted() ? viaAccessibility() : viaSystemEvents();
  if (found === null) return "the frontmost app has no window";

  let rows = found;
  if (needle) {
    // Exact name first, then prefix, then anywhere: "Save" before "Save As…".
    const rank = (s) => {
      const n = s.name.toLowerCase();
      return n === needle ? 0 : n.startsWith(needle) ? 1 : n.includes(needle) ? 2 : -1;
    };
    rows = found
      .map((s, i) => ({ s, r: rank(s), i }))
      .filter((x) => x.r >= 0)
      .sort((a, b) => a.r - b.r || a.i - b.i)
      .map((x) => x.s);
    if (!rows.length) return `no element matching: ${argv[0]}`;
  } else if (!rows.length) {
    return "no named elements in the front window";
  }

  const line = (s) =>
    `${s.name.replace(/\s+/g, " ").slice(0, 100)}  [${s.role}]` +
    (s.point ? `  ->  ${s.point[0]} ${s.point[1]}` : "") +
    (s.disabled ? "  (disabled)" : "");

  const out = rows.slice(0, LIST_CAP).map(line);
  if (rows.length > LIST_CAP) out.push(`… ${rows.length - LIST_CAP} more — narrow it with: where <text>`);
  return out.join("\n");
}
