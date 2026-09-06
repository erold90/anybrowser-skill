// Walks the accessibility tree of the frontmost window.
//   osascript -l JavaScript tree.js            → every named element
//   osascript -l JavaScript tree.js "Save"     → only those matching "Save"
//
// System Events' `entire contents` returns an empty list for many apps, so we
// descend by hand instead.
function run(argv) {
  const needle = (argv[0] || "").toLowerCase();
  const se = Application("System Events");
  se.includeStandardAdditions = true;

  let proc;
  try {
    proc = se.processes.whose({ frontmost: true })[0];
  } catch (e) {
    return "cannot reach the frontmost process";
  }

  let win;
  try {
    win = proc.windows[0];
    win.name();
  } catch (e) {
    return "the frontmost process has no window";
  }

  const seen = [];
  const MAX_DEPTH = 8;
  const MAX_NODES = 4000;
  let visited = 0;

  function label(el) {
    for (const get of [() => el.name(), () => el.description(), () => el.title()]) {
      try {
        const v = get();
        if (v && v !== "missing value") return String(v);
      } catch (e) { /* attribute not supported */ }
    }
    return "";
  }

  function walk(el, depth) {
    if (depth > MAX_DEPTH || visited > MAX_NODES) return;
    visited++;

    const name = label(el);
    if (name) {
      let role = "";
      try { role = String(el.role()); } catch (e) {}
      let point = "";
      try {
        const [x, y] = el.position();
        const [w, h] = el.size();
        point = `${Math.round(x + w / 2)} ${Math.round(y + h / 2)}`;
      } catch (e) {}
      if (!needle || name.toLowerCase().indexOf(needle) !== -1) {
        seen.push({ name, role: role.replace(/^AX/, ""), point, depth });
      }
    }

    let kids = [];
    try { kids = el.uiElements(); } catch (e) { return; }
    for (const k of kids) walk(k, depth + 1);
  }

  walk(win, 0);

  if (!seen.length) {
    return needle ? `no element matching: ${argv[0]}` : "no named elements in the front window";
  }
  return seen
    .map((s) => (s.point ? `${s.name}  [${s.role}]  ->  ${s.point}` : `${s.name}  [${s.role}]`))
    .join("\n");
}
