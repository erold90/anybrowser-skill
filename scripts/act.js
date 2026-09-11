// Hands: pointer, keyboard, clipboard and menus.
//   osascript -l JavaScript act.js <command> [args...]
//
// Every value arrives through argv and is never spliced into script source, so
// text read off the screen cannot turn into code. The pointer posts CoreGraphics
// events from this process; keys and menus go through System Events.
ObjC.import("AppKit");
ObjC.import("CoreGraphics");
ObjC.bindFunction("AXIsProcessTrusted", ["bool", []]);
ObjC.bindFunction("AXUIElementCreateApplication", ["id", ["int"]]);
ObjC.bindFunction("AXUIElementCopyAttributeValue", ["int", ["id", "id", "id*"]]);
ObjC.bindFunction("AXUIElementPerformAction", ["int", ["id", "id"]]);

const se = () => Application("System Events");

function num(v, what) {
  const n = Number(v);
  if (v === undefined || v === "" || !isFinite(n)) throw new Error(`${what} must be a number, got: ${v}`);
  return n;
}

// ---- pointer ---------------------------------------------------------------

function pointer() {
  const p = $.CGEventGetLocation($.CGEventCreate(null));
  return { x: Math.round(p.x), y: Math.round(p.y) };
}

function post(type, x, y, button, clicks) {
  const ev = $.CGEventCreateMouseEvent(null, type, { x, y }, button);
  if (clicks) $.CGEventSetIntegerValueField(ev, $.kCGMouseEventClickState, clicks);
  $.CGEventPost($.kCGHIDEventTap, ev);
}

// Without Accessibility, posted events are dropped and nothing reports it.
// Fail loudly instead, except for a plain click, which System Events can do.
function needTrust(what) {
  if (!$.AXIsProcessTrusted()) {
    throw new Error(`${what} needs the Accessibility permission — run: mac.sh check`);
  }
}

function moveTo(x, y) {
  post($.kCGEventMouseMoved, x, y, $.kCGMouseButtonLeft);
  delay(0.05);
}

function press(x, y, button, clicks) {
  if (!$.AXIsProcessTrusted()) {
    // A real pointer click reaches apps with no accessibility tree (Blender's
    // viewport, games, canvases); this fallback only reaches ones that have one.
    if (button === "left" && clicks === 1) return se().click({ at: [x, y] });
    needTrust(button === "right" ? "rclick" : "dclick");
  }
  const [down, up] = button === "right"
    ? [$.kCGEventRightMouseDown, $.kCGEventRightMouseUp]
    : [$.kCGEventLeftMouseDown, $.kCGEventLeftMouseUp];
  const b = button === "right" ? $.kCGMouseButtonRight : $.kCGMouseButtonLeft;
  moveTo(x, y);
  for (let i = 1; i <= clicks; i++) {
    post(down, x, y, b, i);
    post(up, x, y, b, i);
    if (i < clicks) delay(0.03);
  }
}

// ---- clipboard ---------------------------------------------------------------

// Copy every item in every type, so an image or rich text on the clipboard
// survives `type` instead of being flattened to plain text.
function saveClipboard(pb) {
  const items = [];
  const list = pb.pasteboardItems;
  for (let i = 0; i < list.count; i++) {
    const item = list.objectAtIndex(i);
    const types = item.types;
    const entries = [];
    for (let j = 0; j < types.count; j++) {
      const t = types.objectAtIndex(j);
      const data = item.dataForType(t);
      if (data && !data.isNil()) entries.push([t, data]);
    }
    items.push(entries);
  }
  return items;
}

function restoreClipboard(pb, items) {
  pb.clearContents;
  if (!items.length) return;
  const out = $.NSMutableArray.array;
  for (const entries of items) {
    const item = $.NSPasteboardItem.alloc.init;
    for (const [t, data] of entries) item.setDataForType(data, t);
    out.addObject(item);
  }
  pb.writeObjects(out);
}

function typeText(text) {
  const pb = $.NSPasteboard.generalPasteboard;
  const saved = saveClipboard(pb);
  pb.clearContents;
  const item = $.NSPasteboardItem.alloc.init;
  item.setStringForType($(text), $("public.utf8-plain-text"));
  // Convention honoured by clipboard managers: don't record this entry.
  item.setStringForType($(""), $("org.nspasteboard.TransientType"));
  pb.writeObjects($([item]));
  const mine = pb.changeCount;
  se().keystroke("v", { using: "command down" });
  delay(0.5);
  // If something else was copied in the meantime, leave it alone.
  if (pb.changeCount === mine) restoreClipboard(pb, saved);
}

// ---- keys --------------------------------------------------------------------

const KEYS = {
  return: 36, enter: 36, "numpad-enter": 76, tab: 48, space: 49,
  delete: 51, backspace: 51, "forward-delete": 117, esc: 53, escape: 53,
  left: 123, right: 124, down: 125, up: 126,
  "page-up": 116, "page-down": 121, home: 115, end: 119,
  f1: 122, f2: 120, f3: 99, f4: 118, f5: 96, f6: 97, f7: 98, f8: 100,
  f9: 101, f10: 109, f11: 103, f12: 111,
};

const MODS = {
  cmd: "command down", command: "command down", shift: "shift down",
  alt: "option down", opt: "option down", option: "option down",
  ctrl: "control down", control: "control down",
};

function hotkey(mods, key) {
  if (!key) throw new Error('hotkey needs modifiers and a key, e.g. hotkey "cmd shift" s');
  const using = mods.split(/\s+/).filter(Boolean).map((m) => {
    if (!MODS[m]) throw new Error(`unknown modifier: ${m}`);
    return MODS[m];
  });
  if (key in KEYS) se().keyCode(KEYS[key], { using });
  else se().keystroke(key, { using });
}

// ---- menus -------------------------------------------------------------------

function clickMenu(app, path) {
  if (path.length < 2) throw new Error("menu needs a menu and an item, e.g. menu TextEdit File New");
  Application(app).activate();
  delay(0.3);
  let menu = se().processes.byName(app).menuBars[0].menuBarItems.byName(path[0]).menus[0];
  for (let i = 1; i < path.length - 1; i++) menu = menu.menuItems.byName(path[i]).menus[0];
  menu.menuItems.byName(path[path.length - 1]).click();
}

// ---- file dialogs ------------------------------------------------------------

function frontWindow() {
  const app = $.AXUIElementCreateApplication($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
  const r = Ref();
  return $.AXUIElementCopyAttributeValue(app, $("AXFocusedWindow"), r) === 0 ? r[0] : null;
}

function identifier(el) {
  const r = Ref();
  if (!el || $.AXUIElementCopyAttributeValue(el, $("AXIdentifier"), r) !== 0) return "";
  const v = ObjC.unwrap(r[0]);
  return typeof v === "string" ? v : "";
}

// The system Open panel carries the identifier "open-panel" in every language,
// so we can check it is really there before typing a path into anything.
function upload(path) {
  needTrust("upload");
  if (identifier(frontWindow()) !== "open-panel") {
    throw new Error("no file dialog in front — click the page's upload button first");
  }
  hotkey("cmd shift", "g");          // Go to Folder
  delay(0.8);
  typeText(path);
  delay(0.3);
  se().keyCode(KEYS.return);         // go there, file selected
  delay(1);
  const panel = frontWindow();
  if (identifier(panel) === "open-panel") {
    const kids = Ref();
    $.AXUIElementCopyAttributeValue(panel, $("AXChildren"), kids);
    for (let i = 0; kids[0] && i < kids[0].count; i++) {
      const k = kids[0].objectAtIndex(i);
      if (identifier(k) === "OKButton") { $.AXUIElementPerformAction(k, $("AXPress")); break; }
    }
  }
  for (let i = 0; i < 20; i++) {
    if (identifier(frontWindow()) !== "open-panel") return `uploaded ${path}`;
    delay(0.1);
  }
  throw new Error("the file dialog is still open — take a shot to see why");
}

// ---- dispatch ------------------------------------------------------------------

function run(argv) {
  const [cmd, ...a] = argv;
  switch (cmd) {
    case "click":  press(num(a[0], "x"), num(a[1], "y"), "left", 1); return;
    case "dclick": press(num(a[0], "x"), num(a[1], "y"), "left", 2); return;
    case "rclick": press(num(a[0], "x"), num(a[1], "y"), "right", 1); return;
    case "move":   needTrust("move"); moveTo(num(a[0], "x"), num(a[1], "y")); return;
    case "pos":    { const p = pointer(); return `${p.x} ${p.y}`; }

    case "drag": {
      needTrust("drag");
      const [x1, y1, x2, y2] = [0, 1, 2, 3].map((i) => num(a[i], "coordinate"));
      moveTo(x1, y1);
      post($.kCGEventLeftMouseDown, x1, y1, $.kCGMouseButtonLeft);
      const steps = 20;
      for (let i = 1; i <= steps; i++) {
        post($.kCGEventLeftMouseDragged, x1 + ((x2 - x1) * i) / steps, y1 + ((y2 - y1) * i) / steps, $.kCGMouseButtonLeft);
        delay(0.01);
      }
      post($.kCGEventLeftMouseUp, x2, y2, $.kCGMouseButtonLeft);
      return;
    }

    case "scroll": {
      needTrust("scroll");
      const ev = $.CGEventCreateScrollWheelEvent(null, $.kCGScrollEventUnitLine, 2, num(a[0], "lines"), num(a[1] || 0, "dx"));
      $.CGEventPost($.kCGHIDEventTap, ev);
      return;
    }

    case "type":   typeText(a[0] || ""); return;
    case "keys":   se().keystroke(a[0] || ""); return;
    case "key":
      if (!(a[0] in KEYS)) throw new Error(`unknown key: ${a[0]}`);
      se().keyCode(KEYS[a[0]]);
      return;
    case "hotkey": hotkey(a[0] || "", a[1] || ""); return;

    case "upload": return upload(a[0]);
    case "menu":   clickMenu(a[0], a.slice(1)); return;
    case "menus":  return se().processes.byName(a[0]).menuBars[0].menuBarItems.name().join("\n");
    case "focus":  Application(a[0]).activate(); return;
    case "apps":   return se().processes.whose({ backgroundOnly: false }).name().sort().join("\n");

    // Diagnostics used by `check`.
    case "trusted": return String($.AXIsProcessTrusted());
    case "width":   return String($.CGDisplayBounds($.CGMainDisplayID()).size.width);
    case "probe": {
      // Measure, don't trust: move one point and read it back.
      const before = pointer();
      moveTo(before.x + 1, before.y);
      delay(0.1);
      const after = pointer();
      moveTo(before.x, before.y);
      return after.x !== before.x ? "moved" : "stuck";
    }
    case "automation":
      return se().processes.whose({ frontmost: true })[0].name();

    default: throw new Error(`unknown action: ${cmd}`);
  }
}
