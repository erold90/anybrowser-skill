// anybrowser — eyes and hands for browsers and the rest of the macOS desktop.
//
// Coordinates are logical points: a pixel read off `shot` is the point `click`
// takes. Everything goes through the Accessibility API and CoreGraphics events,
// in-process: no helper apps, nothing to inject into. (browser.swift adds what
// browsers answer to scripts and keep in files.)
//
// Every action waits for the app to react and says what changed, so the agent
// gets its confirmation in the same call instead of taking a screenshot.
//
// Build: swiftc -O src/*.swift -o anybrowser   (anybrowser.sh does it on first use)

import AppKit
import ApplicationServices
import Carbon
import ImageIO

let version = "0.3.0"

// MARK: - Errors and output

struct Fail: Error { let message: String; var code: Int32 = 1 }

func say(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
func warn(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func number(_ s: String?, _ what: String) throws -> Double {
    guard let s = s, let v = Double(s), v.isFinite else { throw Fail(message: "\(what) must be a number, got: \(s ?? "nothing")", code: 2) }
    return v
}

func env(_ name: String, _ fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[name], let v = Int(raw), v >= 0 else { return fallback }
    return v
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }

let launched = CFAbsoluteTimeGetCurrent()
/// ANYBROWSER_DEBUG=1: timestamps on stderr, to see where a slow step spends its time.
func debug(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["ANYBROWSER_DEBUG"] != nil {
        warn(String(format: "  %6.0f ms  ", (CFAbsoluteTimeGetCurrent() - launched) * 1000) + s())
    }
}
func pause(_ ms: Double) { if ms > 0 { usleep(useconds_t(ms * 1000)) } }

// MARK: - Accessibility helpers

extension AXUIElement {
    func attr(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }
    func text(_ name: String) -> String {
        guard let s = attr(name) as? String else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func element(_ name: String) -> AXUIElement? {
        guard let v = attr(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    var children: [AXUIElement] { (attr(kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    var role: String { stripAX(text(kAXRoleAttribute)) }
    var pid: pid_t { var p: pid_t = 0; AXUIElementGetPid(self, &p); return p }
    @discardableResult func perform(_ action: String, timeout: Float = 0.5) -> AXError {
        AXUIElementSetMessagingTimeout(self, timeout)
        return AXUIElementPerformAction(self, action as CFString)
    }
}

func stripAX(_ s: String) -> String { s.hasPrefix("AX") ? String(s.dropFirst(2)) : s }

func axPoint(_ v: CFTypeRef?) -> CGPoint? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

func axSize(_ v: CFTypeRef?) -> CGSize? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

/// A locked screen swallows every click and hides every window behind loginwindow;
/// without this, each command would fail as "not found" for the wrong reason.
func screenLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? Bool) == true
}

func requireUnlocked() throws {
    if screenLocked() { throw Fail(message: "the screen is locked — nothing can be seen or clicked until the user unlocks it") }
}

func requireTrust(_ what: String) throws {
    try requireUnlocked()
    if !AXIsProcessTrusted() {
        throw Fail(message: "\(what) needs the Accessibility permission — run: anybrowser check")
    }
}

/// The app in front. NSWorkspace answers in 0.2 ms but can be stale inside one
/// run, so its answer is confirmed with the app's own AXFrontmost; when that says
/// no, the on-screen window list decides (always current, ~60 ms). The
/// accessibility server's focused-application attribute failed for every app we
/// measured, so it is only the last resort.
func focusedApp(timeout: Float = 2) -> AXUIElement? {
    func element(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }
    if let pid = readingApp { return element(pid) }    // a lookup reading the work from behind another app
    CFRunLoopRunInMode(.defaultMode, 0, true)          // let NSWorkspace catch up on activations
    if let front = NSWorkspace.shared.frontmostApplication {
        let app = element(front.processIdentifier)
        if (app.attr(kAXFrontmostAttribute) as? Bool) != false { return app }
    }
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
       let top = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
       let owner = top[kCGWindowOwnerPID as String] as? pid_t {
        return element(owner)
    }
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.5)
    return sys.element(kAXFocusedApplicationAttribute).map { element($0.pid) }
}

func appName(_ pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
}

func onScreen(_ p: CGPoint) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).contains { CGDisplayBounds($0).contains(p) }
}

// MARK: - The element tree

struct Node {
    let el: AXUIElement
    let name: String
    let role: String
    let point: CGPoint?
    let disabled: Bool
    let inWeb: Bool
    var reachable = true          // a click at `point` lands on this element
    var on: Bool? = nil           // checkboxes, radio buttons, switches: ticked or not
    var value: String? = nil      // what a field holds or a pop-up shows, when it has a label of its own
}

let toggleRoles: Set<String> = ["CheckBox", "RadioButton", "Switch", "ToggleButton"]

/// Would a click at `p` land on `target`? Ask the system what is at that point —
/// across all apps, so a covering window, banner or dialog counts — and accept the
/// target itself, anything inside it, or a close container (a link around its text).
func reaches(_ p: CGPoint, _ target: AXUIElement) -> Bool {
    guard onScreen(p) else { return false }
    var hit: AXUIElement?
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.5)
    guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &hit) == .success, let h = hit else {
        return true                                       // can't tell: trust the frame
    }
    var e: AXUIElement? = h
    for _ in 0..<10 {
        guard let cur = e else { break }
        if CFEqual(cur, target) { return true }
        e = cur.element(kAXParentAttribute)
    }
    var t = target.element(kAXParentAttribute)
    for _ in 0..<3 {
        guard let cur = t else { break }
        if CFEqual(cur, h) { return true }
        t = cur.element(kAXParentAttribute)
    }
    return false
}

let inputRoles: Set<String> = ["TextField", "TextArea", "ComboBox", "SearchField", "SecureTextField"]
let textRoles: Set<String> = ["StaticText", "Heading", "Link", "Button", "Cell", "MenuItem", "TextArea"]
let chromium = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium",
                "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                "company.thebrowser.dia", "ai.perplexity.comet"]

// One round trip per element instead of one per attribute.
let wanted = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
              kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
              kAXEnabledAttribute, kAXChildrenAttribute] as CFArray

func walk(_ root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 8000,
          stop: ((Node) -> Bool)? = nil, clip: CGRect? = nil, inWeb startInWeb: Bool = false) -> (nodes: [Node], sawWeb: Bool) {
    var nodes: [Node] = []
    var visited = 0
    var sawWeb = false
    var done = false

    func value(_ values: [AnyObject], _ i: Int) -> CFTypeRef? {
        guard i < values.count else { return nil }
        let v = values[i]
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }
    func str(_ v: CFTypeRef?) -> String { ((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func visit(_ el: AXUIElement, _ depth: Int, _ inWebIn: Bool) {
        if done || depth > maxDepth || visited >= maxNodes { return }
        visited += 1
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, wanted, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as [AnyObject]? else { return }
        let role = stripAX(str(value(values, 0)))
        var inWeb = inWebIn
        if role == "WebArea" { sawWeb = true; inWeb = true }
        var name = str(value(values, 1))
        if name.isEmpty { name = str(value(values, 2)) }
        if name.isEmpty, inputRoles.contains(role) { name = str(value(values, 4)) }
        if name.isEmpty { name = str(value(values, 3)) }
        let origin = axPoint(value(values, 5)), size = axSize(value(values, 6))
        // Reading only what's visible: a subtree whose frame misses the window is skipped whole.
        if let clip = clip, let o = origin, let sz = size, sz.width > 0, sz.height > 0,
           !CGRect(origin: o, size: sz).intersects(clip) { return }
        if !name.isEmpty {
            var point: CGPoint? = nil
            if let p = origin, let s = size, s.width > 0 {
                point = CGPoint(x: (p.x + s.width / 2).rounded(), y: (p.y + s.height / 2).rounded())
            }
            let enabled = value(values, 7) as? Bool
            var node = Node(el: el, name: name, role: role, point: point, disabled: enabled == false, inWeb: inWeb)
            if toggleRoles.contains(role), let state = value(values, 3) as? NSNumber { node.on = state.intValue != 0 }
            if inputRoles.contains(role) || role == "PopUpButton", role != "SecureTextField" {
                let held = str(value(values, 3))
                if held != name { node.value = String(flat(held).prefix(120)) }
            }
            nodes.append(node)
            if let stop = stop, stop(node) { done = true; return }
        }
        if let kids = value(values, 8) as? [AXUIElement] {
            for k in kids { visit(k, depth + 1, inWeb) }
        }
    }
    visit(root, 0, startInWeb)
    return (nodes, sawWeb)
}

/// Named elements of the focused window. Wakes Chromium's page tree when needed.
func frontTree(stop: ((Node) -> Bool)? = nil, visibleOnly: Bool = false) throws -> [Node] {
    try requireUnlocked()
    guard AXIsProcessTrusted() else { throw Fail(message: "reading the screen needs the Accessibility permission — run: anybrowser check") }
    guard let app = focusedApp() else { throw Fail(message: "the frontmost app has no window") }
    guard let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else {
        throw Fail(message: "the frontmost app has no window")
    }
    var clip: CGRect? = nil
    if visibleOnly, let o = axPoint(win.attr(kAXPositionAttribute)), let sz = axSize(win.attr(kAXSizeAttribute)) {
        clip = CGRect(origin: o, size: sz).intersection(CGDisplayBounds(CGMainDisplayID()))
    }
    var result = walk(win, stop: stop, clip: clip)
    // A lookup that already found its exact match doesn't need the page woken.
    let matched = stop.map { found in result.nodes.last.map(found) ?? false } ?? false
    if !result.sawWeb, !matched, wakeWebTree(app, pid: app.pid) {
        // Wait for a page with something in it, not just an empty web area.
        let deadline = now() + 6
        while now() < deadline {
            pause(250)
            result = walk(win, stop: stop, clip: clip)
            if result.sawWeb && result.nodes.filter({ $0.inWeb }).count >= 3 { break }
        }
    }
    return result.nodes
}

/// Invisible direction marks, which web apps put around shortcuts, don't count.
let invisibleMarks = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

func cleanName(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !invisibleMarks.contains($0) })).lowercased()
        .trimmingCharacters(in: .whitespaces)
}

/// How well a name matches: 0 exact, 1 the needle as its whole first word
/// ("Invia" → "Invia (⌘Enter)"), 2 any prefix ("Inviati"), 3 anywhere, nil not at all.
func score(_ name: String, _ needle: String) -> Int? {
    let n = cleanName(needle), c = cleanName(name)
    guard !n.isEmpty else { return nil }
    if c == n { return 0 }
    if c.hasPrefix(n) {
        let next = c[c.index(c.startIndex, offsetBy: n.count)...].first
        return (next.map { !$0.isLetter && !$0.isNumber } ?? true) ? 1 : 2
    }
    return c.contains(n) ? 3 : nil
}

func rank(_ nodes: [Node], _ needle: String) -> [Node] {
    nodes.enumerated().compactMap { (i, node) -> (Int, Int, Node)? in
        score(node.name, needle).map { ($0, i, node) }
    }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
}

func flat(_ s: String) -> String {
    s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

func label(_ n: Node) -> String { "\(String(flat(n.name).prefix(100)))  [\(n.role)]" }

func line(_ n: Node) -> String {
    var s = label(n)
    if let p = n.point {
        s += "  ->  \(Int(p.x)) \(Int(p.y))"
        if !onScreen(p) { s += "  (offscreen)" }
    }
    if let on = n.on { s += on ? "  (on)" : "  (off)" }
    if n.disabled { s += "  (disabled)" }
    return s
}

/// Best enabled match with a point; scrolls it into view when it's off screen.
/// Waits up to ANYBROWSER_WAIT seconds (default 2) for it to appear: the previous step
/// may still be closing a dialog or loading. Only the search repeats, never an action.
func pick(_ needle: String, fields: Bool = false, roles: Set<String>? = nil, needPoint: Bool = true) throws -> Node {
    let deadline = now() + Double(env("ANYBROWSER_WAIT", 2))
    var found: Node? = nil
    let exact = needle.lowercased().trimmingCharacters(in: .whitespaces)
    let allowed = fields ? inputRoles : roles
    // Containers share their names with what they hold (a browser window is titled
    // like its tab): clicking one lands in its middle, on whatever is there.
    let containers: Set<String> = ["Window", "WebArea", "Application", "ScrollArea", "SplitGroup", "Sheet", "TabGroup"]
    let usable = { (n: Node) -> Bool in
        !n.disabled && (!needPoint || n.point != nil) && (allowed == nil || allowed!.contains(n.role))
            && !containers.contains(n.role)
    }
    // The first exact, usable match in tree order is what ranking would pick
    // anyway: stop reading the window there.
    let good = { (n: Node) -> Bool in usable(n) && n.name.lowercased() == exact }
    if isRef(needle) {
        let node = try resolveRef(needle)
        if node.disabled { throw Fail(message: "\(label(node)) is disabled") }
        if let allowed = allowed, !allowed.contains(node.role) { throw Fail(message: "\(needle) is a \(node.role), not what this command works on") }
        found = node
    }
    while found == nil {
        // On a web page the browser's own search answers in milliseconds.
        if let fast = webPick(needle, usable) { found = fast; break }
        let nodes = ((try? frontTree(stop: good)) ?? []).filter(usable)
        found = rank(nodes, needle).first
        if found != nil || now() >= deadline { break }
        Watch().settle(first: 150, quiet: 40, max: 300)
    }
    guard var best = found else { throw Fail(message: "no element matching: \(needle)") }
    if needPoint, let p = best.point, !reaches(p, best.el) {
        // Off screen or covered: ask for it to be scrolled into view, then look again.
        best.el.perform("AXScrollToVisible")
        pause(200)
        if let pos = axPoint(best.el.attr(kAXPositionAttribute)), let size = axSize(best.el.attr(kAXSizeAttribute)) {
            best = Node(el: best.el, name: best.name, role: best.role,
                        point: CGPoint(x: (pos.x + size.width / 2).rounded(), y: (pos.y + size.height / 2).rounded()),
                        disabled: best.disabled, inWeb: best.inWeb, on: best.on)
        }
        best.reachable = reaches(best.point!, best.el)
    }
    return best
}

// MARK: - References

/// Listings number what they show (@1, @2…) so the next command can name exactly
/// that element, even among several with the same name. A ref is remembered by what
/// finds it again — app, role, name, page id, position — not by a pointer, so it
/// survives the page re-rendering, and is gone when the element is.
struct Ref: Codable { let pid: Int32; let role: String; let name: String; let dom: String; let x: Double; let y: Double; let web: Bool }

/// Where what lasts between calls is kept: TMPDIR, which NSTemporaryDirectory ignores
/// (the tests keep theirs apart with it), else the user's temporary folder.
let tempDir: String = {
    guard let t = ProcessInfo.processInfo.environment["TMPDIR"], !t.isEmpty else { return NSTemporaryDirectory() }
    return t.hasSuffix("/") ? t : t + "/"
}()

let refsPath = tempDir + "anybrowser-refs.json"

func numbered(_ nodes: [Node], limit: Int, _ format: (Node) -> String) -> [String] {
    var refs: [Ref] = []
    var lines: [String] = []
    var last = ""
    for n in nodes {
        let body = format(n)
        if body == last { continue }
        last = body
        if refs.count >= limit { lines.append(body); continue }       // counted, not numbered
        AXUIElementSetMessagingTimeout(n.el, 0.3)
        refs.append(Ref(pid: n.el.pid, role: n.role, name: n.name, dom: n.inWeb ? n.el.text("AXDOMIdentifier") : "",
                        x: Double(n.point?.x ?? -1), y: Double(n.point?.y ?? -1), web: n.inWeb))
        lines.append("@\(refs.count) " + body)
    }
    if let data = try? JSONEncoder().encode(refs) { FileManager.default.createFile(atPath: refsPath, contents: data) }
    return lines
}

func isRef(_ s: String) -> Bool { s.hasPrefix("@") && Int(s.dropFirst()) != nil }

/// The app a ref was listed in.
func refPid(_ token: String) -> pid_t? {
    guard let n = Int(token.dropFirst()), let data = FileManager.default.contents(atPath: refsPath),
          let refs = try? JSONDecoder().decode([Ref].self, from: data), let ref = refs[safe: n - 1] else { return nil }
    return ref.pid
}

func resolveRef(_ token: String) throws -> Node {
    guard let n = Int(token.dropFirst()), let data = FileManager.default.contents(atPath: refsPath),
          let refs = try? JSONDecoder().decode([Ref].self, from: data), let ref = refs[safe: n - 1] else {
        throw Fail(message: "no element \(token) — refs come from the last ui, where, find or links", code: 2)
    }
    try requireUnlocked()
    guard let app = focusedApp(), app.pid == ref.pid else {
        throw Fail(message: "\(token) was listed in another app than the one in front now — bring it back, or list again")
    }
    var candidates: [Node] = []
    if ref.web, let win = app.element(kAXFocusedWindowAttribute), let web = webArea(in: win) {
        candidates = webSearch(web, "AXAnyTypeSearchKey", text: ref.name, limit: 200).compactMap { walk($0, maxDepth: 0, inWeb: true).nodes.first }
    }
    if !candidates.contains(where: { $0.role == ref.role && $0.name == ref.name }) { candidates = (try? frontTree()) ?? [] }
    let same = candidates.filter { $0.role == ref.role && $0.name == ref.name }
    let byDom = ref.dom.isEmpty ? [] : same.filter { $0.el.text("AXDOMIdentifier") == ref.dom }
    let pool = byDom.isEmpty ? same : byDom
    func distance(_ node: Node) -> Double {
        guard let p = node.point, ref.x >= 0 else { return .infinity }
        return hypot(Double(p.x) - ref.x, Double(p.y) - ref.y)
    }
    guard let best = pool.min(by: { distance($0) < distance($1) }) else {
        throw Fail(message: "\(token) (\(flat(ref.name).prefix(60)) [\(ref.role)]) isn't there any more — list again")
    }
    return best
}

// MARK: - Watching for the effect of an action

final class Watch {
    var events = 0
    var last = now()
    var kinds: [String: Int] = [:]
    var changed: [AXUIElement] = []           // elements whose value or title changed
    private var observer: AXObserver?
    private let app: AXUIElement?

    static let notifications = [
        kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXMainWindowChangedNotification,
        kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXTitleChangedNotification,
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXSheetCreatedNotification,
        kAXUIElementDestroyedNotification, kAXSelectedTextChangedNotification, kAXApplicationDeactivatedNotification,
        kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification,
        kAXSelectedRowsChangedNotification, kAXSelectedCellsChangedNotification, kAXRowCountChangedNotification,
    ]

    init() {
        app = focusedApp()
        guard let app = app else { return }
        let callback: AXObserverCallback = { _, element, note, refcon in
            guard let refcon = refcon else { return }
            let w = Unmanaged<Watch>.fromOpaque(refcon).takeUnretainedValue()
            w.events += 1
            w.last = now()
            let name = note as String
            w.kinds[name, default: 0] += 1
            if (name == kAXValueChangedNotification || name == kAXTitleChangedNotification), w.changed.count < 12 {
                w.changed.append(element)
            }
        }
        guard AXObserverCreate(app.pid, callback, &observer) == .success, let observer = observer else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in Watch.notifications { AXObserverAddNotification(observer, app, n as CFString, me) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Spin until the app goes quiet after reacting, or gives no sign at all.
    func settle(first: Int = env("ANYBROWSER_SETTLE", 250), quiet: Int = 90, max: Int = 1500, until: ((Watch) -> Bool)? = nil) {
        if first == 0 { return }
        let start = now()
        while true {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
            let elapsed = (now() - start) * 1000
            if let until = until, until(self) { pause(30); break }
            if elapsed >= Double(max) { break }
            if events == 0 { if elapsed >= Double(first) { break } }
            else if (now() - last) * 1000 >= Double(quiet) { break }
        }
    }

    deinit {
        if let observer = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}

/// Windows that are windows. Safari's link-preview bar (507×20) comes and goes in
/// the AXWindows list and used to read as a window opening or closing.
func realWindows(_ app: AXUIElement) -> [AXUIElement] {
    ((app.attr(kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { w in
        // Finder lists its desktop among its windows; it isn't one.
        if w.role == "ScrollArea" { return false }
        guard let size = axSize(w.attr(kAXSizeAttribute)) else { return true }
        return size.width >= 150 && size.height >= 60
    }
}

/// What is selected in a list, table or icon view that has the focus: "bozza.txt".
func selectionNames(_ view: AXUIElement) -> [String] {
    func label(_ e: AXUIElement, _ depth: Int) -> String {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute] { let t = e.text(a); if !t.isEmpty { return t } }
        if ["TextField", "StaticText"].contains(e.role) { let t = e.text(kAXValueAttribute); if !t.isEmpty { return t } }
        guard depth < 3 else { return "" }
        for c in e.children { let t = label(c, depth + 1); if !t.isEmpty { return t } }
        return ""
    }
    AXUIElementSetMessagingTimeout(view, 0.3)
    let picked = (view.attr(kAXSelectedRowsAttribute) as? [AXUIElement])
        ?? (view.attr(kAXSelectedChildrenAttribute) as? [AXUIElement]) ?? []
    return picked.prefix(3).map { String(flat(label($0, 0)).prefix(50)) }.filter { !$0.isEmpty }
}

/// A browser window's tabs: Safari's "TabBar" group, Chrome's tab group — each tab a
/// radio button. Empty when a window shows no tab bar.
func tabBar(_ window: AXUIElement) -> [(title: String, selected: Bool)] {
    func search(_ e: AXUIElement, _ depth: Int) -> [(title: String, selected: Bool)]? {
        guard depth <= 4 else { return nil }
        for child in e.children {
            AXUIElementSetMessagingTimeout(child, 0.3)
            let isBar = child.text(kAXIdentifierAttribute).hasPrefix("TabBar") || child.role == "TabGroup"
            if isBar {
                let tabs = child.children.filter { $0.role == "RadioButton" }
                    .map { (title: $0.text(kAXTitleAttribute), selected: ($0.attr(kAXValueAttribute) as? NSNumber)?.intValue == 1) }
                if !tabs.isEmpty { return tabs }
            }
            if ["Group", "SplitGroup", "Toolbar"].contains(child.role), let found = search(child, depth + 1) { return found }
        }
        return nil
    }
    return search(window, 0) ?? []
}

/// The words and buttons of a small dialog — an alert inside a page, a sheet, an
/// alert window. Nil for anything bigger than a dialog.
func dialogSummary(_ container: AXUIElement) -> String? {
    var texts: [String] = [], buttons: [String] = []
    var visited = 0
    var tooBig = false
    func visit(_ e: AXUIElement, _ depth: Int) {
        if tooBig || depth > 14 { return }                             // Chrome nests an alert's text 12 deep
        visited += 1
        if visited > 60 { tooBig = true; return }
        AXUIElementSetMessagingTimeout(e, 0.3)
        let role = e.role
        if depth > 0 && role == "WebArea" { tooBig = true; return }      // a whole page is not a dialog
        if role == "Button" {
            let t = e.text(kAXTitleAttribute).isEmpty ? e.text(kAXDescriptionAttribute) : e.text(kAXTitleAttribute)
            if !t.isEmpty { buttons.append(t) }
        } else if ["StaticText", "TextArea", "Heading"].contains(role) {
            // Safari puts an alert's words in the value, Chrome in the title.
            var t = flat(e.text(kAXValueAttribute))
            if t.isEmpty { t = flat(e.text(kAXTitleAttribute)) }
            if t.isEmpty { t = flat(e.text(kAXDescriptionAttribute)) }
            if !t.isEmpty && !texts.contains(t) { texts.append(t) }
        }
        for k in e.children { visit(k, depth + 1) }
    }
    visit(container, 0)
    debug("dialogSummary: visited \(visited) tooBig \(tooBig) buttons \(buttons) texts \(texts.prefix(3))")
    guard !tooBig, (1...4).contains(buttons.count), !texts.isEmpty else { return nil }
    let words = String(texts.joined(separator: " — ").prefix(120))
    return "dialog: \"\(words)\" — buttons: \(buttons.joined(separator: ", "))"
}

/// A sheet, a dialog, or a window small enough to be an alert. A document window
/// is none of these, even though its tab bar has a few buttons and some text.
func looksLikeDialog(_ w: AXUIElement, kind: String) -> Bool {
    if kind.contains("file dialog") { return false }
    if kind.contains("sheet") || kind.contains("dialog") { return true }
    guard let size = axSize(w.attr(kAXSizeAttribute)) else { return false }
    return size.width < 640 && size.height < 360
}


/// Browsers and Electron/CEF apps: pages whose text changes without telling anyone.
func isWebApp(_ pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    let bundle = app.bundleIdentifier ?? ""
    if browserBundles.contains(where: { bundle.hasPrefix($0) }) { return true }
    let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks").path ?? ""
    return FileManager.default.fileExists(atPath: frameworks + "/Electron Framework.framework")
        || FileManager.default.fileExists(atPath: frameworks + "/Chromium Embedded Framework.framework")
}

/// The page in front and all its text, taken in a few milliseconds through text
/// markers — cheap enough to take before and after every action. Never wakes a
/// page tree (that can take seconds): a report must stay quick.
struct PageState { let web: AXUIElement; let text: String }

func pageState() -> PageState? {
    guard let app = focusedApp(timeout: 0.5), let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute),
          let web = webArea(in: win), let text = pageText(web) else { return nil }
    return PageState(web: web, text: text)
}

/// New text on the page after an action: a status line, an error, a result.
/// WebKit's text has its line breaks: compare lines. Chromium's comes glued
/// ("NameEmail"): find the stretch that changed, then read just those lines.
func pageChanges(_ before: PageState, _ after: PageState) -> [String] {
    guard CFEqual(before.web, after.web), before.text != after.text else { return [] }
    let clean = { (s: String) in flat(s.replacingOccurrences(of: "\u{FFFC}", with: " ")) }
    if !isChromiumWeb(after.web) {
        let old = Set(before.text.components(separatedBy: .newlines).map(clean))
        var seen = Set<String>()
        return after.text.components(separatedBy: .newlines).map(clean)
            .filter { !$0.isEmpty && !old.contains($0) && seen.insert($0).inserted }.prefix(4).map { String($0.prefix(100)) }
    }
    let a = Array(before.text.utf16), b = Array(after.text.utf16)
    var p = 0
    while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
    var q = 0
    while q < a.count - p && q < b.count - p && a[a.count - 1 - q] == b[b.count - 1 - q] { q += 1 }
    guard b.count - q > p else { return [] }                    // only removed text
    func param(_ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(after.web, name as CFString, arg, &out) == .success ? out : nil
    }
    guard var marker = param("AXTextMarkerForIndex", NSNumber(value: p)) else { return [] }
    var lines: [String] = []
    for _ in 0..<8 {
        guard let range = param("AXLineTextMarkerRangeForTextMarker", marker) else { break }
        let line = clean((param("AXStringForTextMarkerRange", range) as? String) ?? "")
        if !line.isEmpty && !before.text.contains(line) && !lines.contains(line) { lines.append(String(line.prefix(100))) }
        if lines.count >= 4 { break }
        guard let end = param("AXNextLineEndTextMarkerForTextMarker", marker),
              let next = param("AXNextTextMarkerForTextMarker", end), !CFEqual(next, marker) else { break }
        if let index = param("AXIndexForTextMarker", next) as? NSNumber, index.intValue >= b.count - q { break }
        marker = next
    }
    return lines
}

struct Snap {
    var pid: pid_t = 0
    var app = ""
    var window = ""
    var windowRef: AXUIElement? = nil
    var windowKind = ""
    var windows = 0
    var focus = ""
    var value = ""
    var dialog = ""
    var selection = ""
    var tabs: [(title: String, selected: Bool)] = []

    static func take() -> Snap {
        var s = Snap()
        // Short timeout: an app busy animating a sheet shouldn't stall the report
        // for two seconds; a field that times out just stays empty.
        guard let app = focusedApp(timeout: 0.4) else { return s }
        s.pid = app.pid
        s.app = appName(app.pid)
        // Floating bits with no window role of their own (Chrome's "Translate this
        // page?" bubble) come and go by themselves: they count only while they
        // have the focus — an alert does, a bubble doesn't.
        let front = app.element(kAXFocusedWindowAttribute)
        s.windows = realWindows(app).filter { w in
            w.text(kAXSubroleAttribute) != "AXUnknown" || (front.map { CFEqual($0, w) } ?? false)
        }.count
        var focusedWindow: AXUIElement? = nil
        if let w = front {
            focusedWindow = w
            s.windowRef = w
            s.window = w.text(kAXTitleAttribute)
            if w.role == "ScrollArea" && w.text(kAXTitleAttribute).isEmpty { s.window = "the desktop" }
            s.tabs = tabBar(w)
            let role = w.role, sub = stripAX(w.text(kAXSubroleAttribute)), id = w.text(kAXIdentifierAttribute)
            s.windowKind = [role == "Window" || role == "ScrollArea" ? "" : role.lowercased(),
                            ["StandardWindow", "Unknown", ""].contains(sub) ? "" : sub.lowercased(),
                            id == "open-panel" ? "file dialog" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        func named(_ e: AXUIElement) -> String {
            for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
                let t = e.text(a); if !t.isEmpty { return String(flat(t).prefix(60)) }
            }
            return ""
        }
        if let f = app.element(kAXFocusedUIElementAttribute) {
            let role = f.role
            let name = named(f)
            if !name.isEmpty {
                s.focus = "\(name)  [\(role)]"
            } else {
                var context = ""
                var e: AXUIElement? = f
                for _ in 0..<4 where context.isEmpty {
                    e = e?.element(kAXParentAttribute)
                    if let e = e { context = named(e) }
                }
                if context.isEmpty, let first = f.children.first(where: { !$0.text(kAXValueAttribute).isEmpty }) {
                    context = String(flat(first.text(kAXValueAttribute)).prefix(60))
                }
                s.focus = context.isEmpty ? "[\(role)]" : "[\(role)] in \"\(context)\""
            }
            if inputRoles.contains(role), role != "SecureTextField" {
                s.value = String(flat(f.text(kAXValueAttribute)).prefix(80))
                var range = CFRange()
                if let r = f.attr(kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID(),
                   AXValueGetValue(r as! AXValue, .cfRange, &range), range.length > 0 {
                    let picked = flat(f.text(kAXSelectedTextAttribute))
                    s.selection = picked.count <= 40 && !picked.isEmpty ? "\"\(picked)\"" : "\(range.length) characters of text"
                }
            }
            if ["Outline", "Table", "List", "Browser", "Grid"].contains(role) {
                let names = selectionNames(f)
                if !names.isEmpty { s.selection = names.map { "\"\($0)\"" }.joined(separator: ", ") }
            }
            // An alert drawn by the browser takes the focus into a group whose subrole
            // says dialog (Safari: AXDialog). A plain group — a Gmail message card with
            // Reply and React buttons — is not one, however dialog-like it looks.
            var e: AXUIElement? = f
            for _ in 0..<3 {
                guard let cur = e else { break }
                let sub = cur.text(kAXSubroleAttribute)
                if cur.role == "Sheet" || cur.role == "Dialog" || sub.contains("Dialog") || sub.contains("Alert") {
                    if let d = dialogSummary(cur) { s.dialog = d }
                    break
                }
                e = cur.element(kAXParentAttribute)
            }
        }
        // A sheet or an alert window: say what it asks.
        if s.dialog.isEmpty, let w = focusedWindow, looksLikeDialog(w, kind: s.windowKind) {
            s.dialog = dialogSummary(w) ?? ""
        }
        return s
    }

    func changes(since b: Snap, watch: Watch, pageAdded: [String] = [], web: Bool = false, loaded: String? = nil) -> String {
        var parts: [String] = []
        let title = window.isEmpty ? "(untitled)" : "\"\(window)\""
        let kind = windowKind.isEmpty ? "" : " (\(windowKind))"
        let sameWindow = windowRef != nil && b.windowRef != nil && CFEqual(windowRef!, b.windowRef!)
        let fileDialog = windowKind.contains("file dialog")
        if let loaded = loaded, pid == b.pid, windows == b.windows {
            parts.append(loaded)                                  // the new page's title and address say it all
        } else if pid != b.pid {
            parts.append("app: \(b.app) → \(app)")
            parts.append(windows == 0 ? "no window open" : "window: \(title)\(kind)")
        } else if windows > b.windows {
            parts.append("new window: \(title)\(kind)")
        } else if windows < b.windows {
            parts.append(windows == 0 ? "window closed — no window open" : "window closed — now in \(title)\(kind)")
        } else if sameWindow && window != b.window {
            parts.append("now showing \(title)")              // a tab switched, closed or navigated
        } else if window != b.window || windowKind != b.windowKind {
            parts.append("window: \(title)\(kind)")
        }
        // Only against a tab bar that was visible before: a sheet hides it, and its
        // return isn't a tab opening.
        if pid == b.pid && tabs.count > b.tabs.count && !b.tabs.isEmpty {
            // A link that opens a tab, maybe behind the current one.
            let before = Set(b.tabs.map { $0.title })
            for t in tabs where !before.contains(t.title) && parts.count < 6 {
                parts.append("new tab: \"\(t.title)\"" + (t.selected ? "" : " (in the background)"))
            }
        } else if pid == b.pid && tabs.count < b.tabs.count && !b.tabs.isEmpty {
            parts.append("tab closed")
        }
        if let loaded = loaded, !(pid == b.pid && windows == b.windows) { parts.append(loaded) }
        if dialog != b.dialog && !dialog.isEmpty { parts.append(dialog) }
        if fileDialog {
            // What the panel has selected inside itself is noise: say what comes next.
            parts.append("pick the file with: upload <path>")
        } else {
            if focus != b.focus && !focus.isEmpty && dialog.isEmpty { parts.append("focus: \(focus)") }
            if value != b.value && !value.isEmpty { parts.append("value: \"\(value)\"") }
            if selection != b.selection && !selection.isEmpty { parts.append("selected: \(selection)") }
        }
        // Only a menu still showing counts: select opens and closes one on its way.
        if (watch.kinds[kAXMenuOpenedNotification] ?? 0) > 0,
           menuWindowOpen(pid) || (focusedApp(timeout: 0.3)?.children.contains { $0.role == "Menu" } ?? false) {
            parts.append("menu open")
        }
        var seen = Set<String>([value, window, b.window])
        if !pageAdded.isEmpty {
            // New text on the page: a status line, an error, a result.
            for t in pageAdded where seen.insert(t).inserted && parts.count < 6 { parts.append("page: \"\(t)\"") }
        } else if pid == b.pid && !web {
            // Native apps announce text changes; keep the ones in the window in front.
            // (In a browser the page diff above is the channel: its notifications
            // come from the address bar and the file dialog.)
            for el in watch.changed {
                AXUIElementSetMessagingTimeout(el, 0.3)
                // Plain text only: buttons and cells retitle themselves (column headers,
                // style menus) without anything a person would call a result.
                guard ["StaticText", "Heading"].contains(el.role), parts.filter({ $0.hasPrefix("changed:") }).count < 2 else { continue }
                if let w = el.element(kAXWindowAttribute), let front = windowRef, !CFEqual(w, front) { continue }
                var t = el.text(kAXValueAttribute)
                if t.isEmpty { t = el.text(kAXTitleAttribute) }
                t = String(flat(t).prefix(80))
                if !t.isEmpty && seen.insert(t).inserted && parts.count < 6 { parts.append("changed: \"\(t)\" [\(el.role)]") }
            }
        }
        if parts.isEmpty {
            return watch.events > 0 ? "→ the app reacted (\(watch.events) accessibility events), nothing moved in focus"
                                    : "→ no reaction seen — confirm with read (or shot) before building on it"
        }
        return "→ " + parts.joined(separator: " · ")
    }
}

/// When the last step saw a window appear or change. Browsers ignore clicks on a
/// dialog for about half a second after showing it (Chrome's protection against
/// accidental confirmation), so the next click waits that out.
var windowChangedAt = 0.0

/// Run an action, let the app react, and report what changed.
/// `mayNavigate`: the action can load a page (a link, a button, Return) — look a
/// little longer for a navigation to start, and if one does, wait for the page.
func acting(mayNavigate: Bool = false, _ body: () throws -> String) throws -> String {
    if env("ANYBROWSER_SETTLE", 250) == 0 {                // fire and forget: no report
        let head = try body()
        return head.isEmpty ? "sent" : head
    }
    let before = Snap.take()
    let web = before.pid > 0 && isWebApp(before.pid)
    let pageBefore = web ? pageState() : nil
    let mark = web ? pageMark(pid: before.pid) : nil
    let watch = Watch()
    debug("acting: before-snapshot taken")
    let head = try body()
    debug("acting: action done")
    watch.settle()
    debug("acting: settled (\(watch.events) events)")
    var after = Snap.take()
    // Browsers hold back input on a dialog that just *appeared*: the next click
    // waits that out. Returning to a window that was already there, or a page
    // retitling itself after a navigation, needs no wait.
    let appeared = after.windows > before.windows
        || (after.window != before.window && !after.windowKind.isEmpty)
        || (after.pid != before.pid && !after.windowKind.isEmpty)
        || (!after.dialog.isEmpty && after.dialog != before.dialog)
    if appeared { windowChangedAt = now() }
    // Something new is on screen: let it finish appearing before looking again.
    if appeared || after.pid != before.pid || after.windows != before.windows {
        pause(200)
        after = Snap.take()
    }
    // A window that just appeared may be an alert: say what it asks (a big
    // window or a page is never summarised, so this costs nothing there).
    let otherWindow = after.windowRef != nil && (before.windowRef == nil || !CFEqual(after.windowRef!, before.windowRef!))
    if otherWindow || after.windows > before.windows, after.dialog.isEmpty, let w = after.windowRef, looksLikeDialog(w, kind: after.windowKind) {
        after.dialog = dialogSummary(w) ?? ""
    }
    // A text field's value can reach the accessibility tree a beat after the edit.
    if after.value.isEmpty, after.focus.hasSuffix("[TextField]") || after.focus.hasSuffix("[TextArea]") {
        pause(80)
        after = Snap.take()
    }
    // A page that went away or started loading: wait for the new one and say what it is.
    var loaded: String? = nil
    if web, let m = mark, m.web != nil, after.pid == before.pid, after.dialog.isEmpty {
        var started = navigationStarted(pid: before.pid, since: m)
        if !started && mayNavigate {
            // Stop looking as soon as the page shows a result of its own: nothing is loading.
            let pageAnswered = { pageBefore.map { b in pageState().map { $0.text != b.text } ?? false } ?? false }
            _ = until(0.45) { navigationStarted(pid: before.pid, since: m) || pageAnswered() }
            started = navigationStarted(pid: before.pid, since: m)
        }
        if started, let app = NSRunningApplication(processIdentifier: before.pid) {
            let t0 = now()
            let r = waitLoad(app, from: m, seconds: 12)
            loaded = loadedReport("loaded", r, t0).replacingOccurrences(of: "; waitload waits longer", with: " — waitload waits longer")
            after = Snap.take()
        }
    }
    // A window caught between two titles reads as untitled for a moment.
    if loaded == nil, after.pid == before.pid, after.window.isEmpty, !before.window.isEmpty {
        pause(150)
        after = Snap.take()
    }
    var pageAdded: [String] = []
    func diffPage() {
        // A new page or tab is all new text: the title already says what happened.
        // So is the page coming back from behind a dialog that hid it.
        guard web, after.pid == before.pid, after.dialog.isEmpty, before.dialog.isEmpty, after.window == before.window else { pageAdded = []; return }
        guard let b = pageBefore, let now = pageState() else { pageAdded = []; return }
        pageAdded = pageChanges(b, now)
    }
    if loaded == nil { diffPage() }
    // Silence can just be slowness: an app still launching, a settings pane
    // loading in another process. Listen a little longer before saying so.
    if loaded == nil && watch.events == 0 && after.changes(since: before, watch: watch, pageAdded: pageAdded, web: web).hasPrefix("→ no reaction") {
        watch.settle(first: 400, quiet: 90, max: 900)
        after = Snap.take()
        diffPage()
    }
    let report = after.changes(since: before, watch: watch, pageAdded: pageAdded, web: web, loaded: loaded)
    return head.isEmpty ? report : "\(head) \(report)"
}

// MARK: - Pointer

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// Set once anything is posted: events still in flight when the process exits are
/// dropped by the window server — a lone "move" to a point never arrived.
var postedEvents = false { didSet { if postedEvents { lastPostedAt = now() } } }
/// When input was last sent: the system's idle clock can't tell it from the user's.
var lastPostedAt = 0.0

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 0) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    // A new event copies whatever modifiers the system thinks are held; a click must
    // never turn into a Cmd-click because of an earlier shortcut.
    e.flags = []
    if clicks > 0 { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
    e.post(tap: .cghidEventTap)
    postedEvents = true
}

/// How long a move takes. By default it scales with distance — 25 ms for a short
/// hop, ~110 ms across the screen — so the pointer travels like a hand rather than
/// jumping, at little cost. ANYBROWSER_GLIDE=0 teleports, ANYBROWSER_GLIDE=<ms> fixes it.
func glideDuration(_ distance: Double) -> Double {
    if let raw = ProcessInfo.processInfo.environment["ANYBROWSER_GLIDE"], let ms = Double(raw), ms >= 0 { return distance > 2 ? ms : 0 }
    return distance > 2 ? min(110, 25 + distance * 0.07) : 0
}

/// Move there along an eased path at ~240 events per second, on an absolute
/// schedule so sleep jitter doesn't stretch the move.
func glide(to target: CGPoint, ms: Double? = nil, dragging: Bool = false) {
    let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
    let from = pointer()
    let distance = hypot(target.x - from.x, target.y - from.y)
    let duration = ms ?? glideDuration(distance)
    if duration > 0 {
        let steps = max(2, Int(duration / 4.2))
        let start = now()
        for i in 1..<steps {
            let t = Double(i) / Double(steps)
            let e = t * t * (3 - 2 * t)                     // smoothstep: eases in and out
            post(type, CGPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e))
            let due = start + duration / 1000 * t
            let wait = (due - now()) * 1000
            if wait > 0 { pause(wait) }
        }
    }
    post(type, target)
}

func waitOutNewWindow() {
    let since = now() - windowChangedAt
    if since < 0.6 { pause((0.6 - since) * 1000) }
}

func click(_ p: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
    waitOutNewWindow()
    let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    glide(to: p)
    pause(12)                                          // let hover state catch up
    for i in 1...count {
        post(down, p, button, clicks: Int64(i))
        pause(8)
        post(up, p, button, clicks: Int64(i))
        if i < count { pause(40) }
    }
}

func drag(_ a: CGPoint, _ b: CGPoint) {
    glide(to: a)
    pause(20)
    post(.leftMouseDown, a)
    pause(40)
    glide(to: b, ms: max(glideDuration(hypot(b.x - a.x, b.y - a.y)), 160), dragging: true)
    pause(40)
    post(.leftMouseUp, b)
}

// MARK: - Keyboard

let namedKeys: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "numpad-enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "forward-delete": 117, "esc": 53, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "page-up": 116, "page-down": 121, "home": 115, "end": 119,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
]

/// Character → key on the *current* layout, so cmd+z is cmd+z on AZERTY too.
/// Built on first use: top-level globals would run at every launch.
enum Layout { static let keys: [Character: (CGKeyCode, Bool)] = {
    var map: [Character: (CGKeyCode, Bool)] = [:]
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
        for code in 0..<128 {
            for shift in [false, true] {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, let c = String(utf16CodeUnits: chars, count: 1).first, map[c] == nil {
                    map[c] = (CGKeyCode(code), shift)
                }
            }
        }
    }
    return map
}() }

/// Modifier keys, pressed and released around a shortcut like a hand would.
let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
    (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55), (.maskSecondaryFn, 63),
]

/// A key press. Modifiers go down first and come up last, as real key events:
/// setting a flag on the key alone left the system believing Cmd was still held,
/// and every later click arrived as a Cmd-click (Safari selected two tabs).
func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
    waitOutNewWindow()
    var held: CGEventFlags = []
    func send(_ key: CGKeyCode, _ down: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        e.flags = held
        e.post(tap: .cghidEventTap)
        pause(3)
    }
    for m in modifierKeys where flags.contains(m.flag) { held.insert(m.flag); send(m.key, true) }
    send(code, true)
    send(code, false)
    for m in modifierKeys.reversed() where flags.contains(m.flag) { held.remove(m.flag); send(m.key, false) }
    postedEvents = true
}

func modifiers(_ spec: String) throws -> CGEventFlags {
    var flags: CGEventFlags = []
    for m in spec.lowercased().split(separator: " ") {
        switch m {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: throw Fail(message: "unknown modifier: \(m)", code: 2)
        }
    }
    return flags
}

func hotkey(_ mods: String, _ key: String) throws {
    guard !key.isEmpty else { throw Fail(message: "hotkey needs modifiers and a key, e.g. hotkey \"cmd shift\" s", code: 2) }
    var flags = try modifiers(mods)
    if let code = namedKeys[key.lowercased()] { tap(code, flags: flags); return }
    guard key.count == 1, let c = key.lowercased().first, let (code, shift) = Layout.keys[c] ?? Layout.keys[key.first!] else {
        throw Fail(message: "no key produces \"\(key)\" on this keyboard layout", code: 2)
    }
    if shift { flags.insert(.maskShift) }
    tap(code, flags: flags)
}

/// Real keystrokes carrying Unicode, one character at a time: accents and emoji
/// intact, and the page sees a person typing.
func typeKeys(_ text: String) {
    for ch in text {
        if ch == "\n" || ch == "\r" { tap(36); continue }
        if ch == "\t" { tap(48); continue }
        // A character the keyboard has goes as that key — SwiftUI apps like
        // Calculator read key codes and ignore bare Unicode. Anything else
        // (emoji, symbols off the layout) goes as Unicode.
        if let (code, shift) = Layout.keys[ch] {
            tap(code, flags: shift ? .maskShift : [])
            pause(6)
            continue
        }
        let units = Array(String(ch).utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            e.post(tap: .cghidEventTap)
            postedEvents = true
        }
        pause(6)
    }
}

// MARK: - Clipboard

func paste(_ text: String) {
    let pb = NSPasteboard.general
    // Keep every item in every type, so an image or rich text survives.
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pb.writeObjects([item])
    let mine = pb.changeCount

    let watch = Watch()
    try? hotkey("cmd", "v")
    // The app reads the clipboard when it handles the keystroke; a value change
    // tells us it did. Without one, give it a moment.
    watch.settle(first: 250, quiet: 60, max: 900) { w in
        (w.kinds[kAXValueChangedNotification] ?? 0) + (w.kinds[kAXSelectedTextChangedNotification] ?? 0) > 0
    }
    if pb.changeCount == mine {
        pb.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let i = NSPasteboardItem()
            for (t, d) in entries { i.setData(d, forType: t) }
            return i
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// MARK: - Apps, menus, dialogs

/// Match an app by what a person or an agent would call it: its localized name
/// ("Impostazioni di Sistema"), its bundle's file name ("System Settings"), or
/// its bundle identifier.
func matches(_ app: NSRunningApplication, _ name: String) -> Bool {
    let n = name.lowercased()
    return app.localizedName?.lowercased() == n
        || app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == n
        || app.bundleIdentifier?.lowercased() == n
}

func runningApp(_ name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { matches($0, name) }
}

func activate(_ name: String) throws {
    if let app = runningApp(name) {
        app.activate(options: [.activateAllWindows])
    } else {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Fail(message: "no application named: \(name)") }
    }
    // Activation arrives as a notification: spin the run loop so it's seen.
    let deadline = now() + 8
    while now() < deadline {
        if CFRunLoopRunInMode(.defaultMode, 0.05, false) == .finished { pause(50) }
        if let front = NSWorkspace.shared.frontmostApplication, matches(front, name) { return }
    }
    throw Fail(message: "\(name) did not come to the front")
}

func menuItems(_ container: AXUIElement) -> [AXUIElement] {
    // A menu bar item holds one AXMenu, whose children are the items.
    let kids = container.children
    if kids.count == 1, kids[0].role == "Menu" { return kids[0].children }
    return kids
}

func clickMenu(_ appNameArg: String, _ path: [String]) throws -> String {
    guard path.count >= 2 else { throw Fail(message: "menu needs a menu and an item, e.g. menu TextEdit File New", code: 2) }
    try activate(appNameArg)
    guard let app = focusedApp(), let bar = app.element(kAXMenuBarAttribute) else { throw Fail(message: "\(appNameArg) has no menu bar") }
    var container = bar
    // "Save As…" typed as "Save As..." or "save as" is the same item; an exact
    // title still wins over a prefix.
    func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    for (i, title) in path.enumerated() {
        let items = i == 0 ? bar.children : menuItems(container)
        let want = norm(title)
        guard let item = items.first(where: { norm($0.text(kAXTitleAttribute)) == want })
                ?? items.first(where: { !want.isEmpty && norm($0.text(kAXTitleAttribute)).hasPrefix(want) }) else {
            let names = items.map { $0.text(kAXTitleAttribute) }.filter { !$0.isEmpty }
            throw Fail(message: "no menu item \"\(title)\" — there is: \(names.joined(separator: ", "))")
        }
        if i == path.count - 1 {
            if (item.attr(kAXEnabledAttribute) as? Bool) == false { throw Fail(message: "menu item \"\(title)\" is disabled") }
            // A command that opens a modal dialog keeps AXPress from returning;
            // a short timeout lets us move on and watch for the dialog instead.
            item.perform(kAXPressAction, timeout: 0.3)
        } else {
            container = item
        }
    }
    return "chose \(path.joined(separator: " > "))"
}

/// The system Open panel: a window or a sheet whose identifier is "open-panel"
/// in every language.
func openPanel() -> AXUIElement? {
    guard let app = focusedApp() else { return nil }
    var windows: [AXUIElement] = []
    if let w = app.element(kAXFocusedWindowAttribute) { windows.append(w) }
    windows += (app.attr(kAXWindowsAttribute) as? [AXUIElement]) ?? []
    for w in windows {
        if w.text(kAXIdentifierAttribute) == "open-panel" { return w }
        if let sheet = w.children.first(where: { $0.text(kAXIdentifierAttribute) == "open-panel" }) { return sheet }
    }
    return nil
}

func focusedElement() -> AXUIElement? { focusedApp()?.element(kAXFocusedUIElementAttribute) }

/// Poll a condition every 30 ms; true if it held before the deadline.
func until(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = now() + seconds
    repeat {
        if condition() { return true }
        // Spin the run loop while waiting, so activations and accessibility
        // notifications land; with nothing to serve it returns at once, so sleep.
        if CFRunLoopRunInMode(.defaultMode, 0.03, false) == .finished { pause(30) }
    } while now() < deadline
    return false
}

func upload(_ path: String) throws -> String {
    try requireTrust("upload")
    // Check the dialog is really there before typing a path into anything.
    guard let panel = openPanel() else { throw Fail(message: "no file dialog in front — click the page's upload button first") }
    debug("upload: panel found")
    try hotkey("cmd shift", "g")                                      // Go to Folder
    let fieldRoles: Set<String> = ["TextField", "ComboBox"]
    guard until(2, { fieldRoles.contains(focusedElement()?.role ?? "") }) else {
        throw Fail(message: "Go to Folder did not open — take a shot to see why")
    }
    debug("upload: Go to Folder field focused")
    // A system panel, not a web page: set the field directly — no clipboard, no
    // waiting for keystrokes. Paste only if the field refuses.
    if let field = focusedElement(),
       AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFString) != .success
        || !until(0.3, { field.text(kAXValueAttribute) == path }) {
        try hotkey("cmd", "a")
        paste(path)
        _ = until(1.5) { (focusedElement()?.text(kAXValueAttribute) ?? "") == path }
    }
    debug("upload: path in the field")
    tap(36)                                                            // go there: the file gets selected
    _ = until(2) { !fieldRoles.contains(focusedElement()?.role ?? "") }
    debug("upload: Go to Folder closed")
    // The Open button turns on once the panel has selected the file.
    func okButton() -> AXUIElement? {
        (openPanel() ?? panel).children.first { $0.text(kAXIdentifierAttribute) == "OKButton" }
    }
    if openPanel() != nil {
        guard until(2, { (okButton()?.attr(kAXEnabledAttribute) as? Bool) == true }), let ok = okButton() else {
            throw Fail(message: "no file selected for \(path) — take a shot to see why")
        }
        debug("upload: Open enabled")
        ok.perform(kAXPressAction, timeout: 0.3)
        debug("upload: Open pressed")
    }
    guard until(3, { openPanel() == nil }) else { throw Fail(message: "the file dialog is still open — take a shot to see why") }
    debug("upload: panel gone")
    return "uploaded \(path)"
}

/// Is a pop-up menu window showing for this app? Visible in the window list even
/// when accessibility can't see the menu (Safari's <select>), in any language.
func menuWindowOpen(_ pid: pid_t) -> Bool {
    let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == level }
}

/// Pick an option in a pop-up menu or <select>, confirmed by reading its value back.
/// Native pop-ups and Chrome open a menu accessibility can see: press the item.
/// Safari's menu is invisible to it: type the option's name into the open menu and
/// confirm with Return — sent only when a menu window is really showing, because
/// Return anywhere else could submit a form.
func choose(_ popup: Node, _ option: String) throws -> String {
    let want = option.lowercased()
    let pid = popup.el.pid
    func current() -> String {
        for attribute in [kAXValueAttribute, kAXTitleAttribute] {
            let t = popup.el.text(attribute)
            if !t.isEmpty && t.lowercased() != popup.name.lowercased() { return t }
        }
        return popup.el.text(kAXValueAttribute)
    }
    func picked() -> Bool { current().lowercased() == want || current().lowercased().hasPrefix(want) }
    func name(_ e: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            let t = e.text(attribute); if !t.isEmpty { return t }
        }
        return ""
    }
    func visibleMenu() -> AXUIElement? {
        popup.el.children.first { $0.role == "Menu" } ?? focusedApp()?.children.first { $0.role == "Menu" }
    }
    func typeIntoOpenMenu(_ text: String, until ok: () -> Bool) -> Bool {
        guard menuWindowOpen(pid) else { return false }
        typeKeys(text)
        pause(120)
        if menuWindowOpen(pid) { tap(36) }
        return until(1.0, ok)
    }
    func menuOpen() -> Bool { visibleMenu() != nil || menuWindowOpen(pid) }
    func closeMenu() { if until(0.2, { !menuOpen() }) == false { tap(53); _ = until(0.5, { !menuOpen() }) } }
    let original = current()
    let done = { () -> String in
        closeMenu()
        return "selected \"\(current())\" in \(label(popup))"
    }
    if picked() { return "\"\(current())\" was already selected in \(label(popup))" }

    // A <select> on a web page takes type-ahead while it has the focus and its menu
    // is closed: focus it, type the option, check the value — no menu to open and
    // wait on. Only when its browser is in front, so the keys can't land elsewhere.
    // Browsers join keys typed within a second into one search ("TeamPro"): let the
    // previous one expire first.
    let typeAhead = NSTemporaryDirectory() + "anybrowser-typeahead"
    if popup.inWeb, focusedApp(timeout: 0.3)?.pid == pid,
       AXUIElementSetAttributeValue(popup.el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
       until(0.3, { (popup.el.attr(kAXFocusedAttribute) as? Bool) == true }) {
        if let last = (try? FileManager.default.attributesOfItem(atPath: typeAhead)[.modificationDate]) as? Date {
            let since = -last.timeIntervalSinceNow
            if since < 1.1 { pause((1.1 - since) * 1000) }
        }
        typeKeys(option)
        FileManager.default.createFile(atPath: typeAhead, contents: nil)
        if until(0.5, picked) { return done() }
        if menuOpen() { tap(53) }
    }

    var options: [String] = []
    popup.el.perform(kAXPressAction, timeout: 0.3)
    if until(0.6, { visibleMenu() != nil || menuWindowOpen(pid) }) {
        if let menu = visibleMenu() {
            let items = menu.children.filter { $0.role == "MenuItem" }.map { ($0, name($0)) }
            options = items.map { $0.1 }.filter { !$0.isEmpty }
            let match = items.first { $0.1.lowercased() == want } ?? items.first { $0.1.lowercased().hasPrefix(want) }
                ?? items.first { $0.1.lowercased().contains(want) }
            if let (item, _) = match {
                item.perform(kAXPressAction, timeout: 0.3)
                if until(1.0, picked) { return done() }
            }
        }
        if typeIntoOpenMenu(option, until: picked) { return done() }
        if menuOpen() { tap(53) }
    }
    // The menu didn't open from accessibility: open it with a real click.
    if let p = popup.point, reaches(p, popup.el) {
        click(p)
        if until(0.8, menuOpen), typeIntoOpenMenu(option, until: picked) { return done() }
        if menuOpen() { tap(53) }
    }
    // A failed attempt must not leave a different option selected: put it back.
    var note = ""
    if !original.isEmpty && current() != original {
        popup.el.perform(kAXPressAction, timeout: 0.3)
        if until(0.6, menuOpen), typeIntoOpenMenu(original, until: { current() == original }) {
            note = " (left at \"\(original)\")"
        } else {
            note = " — and it now shows \"\(current())\" instead of \"\(original)\""
        }
        closeMenu()
    }
    let known = options.isEmpty ? "" : " — there is: \(options.joined(separator: ", "))"
    throw Fail(message: "could not select \"\(option)\" in \(label(popup))\(note)\(known)")
}

// MARK: - Screenshot

/// Capture the screen, a window or a region, scaled so one pixel is one point.
/// A capture that doesn't start at 0,0 says where it starts: add that origin to a
/// pixel's coordinates to get the point to click.
func shot(_ name: String, region: CGRect? = nil, display: Int? = nil) throws -> String {
    try requireUnlocked()
    // A plain name goes to ANYBROWSER_SHOTS (default: the temp folder) as <name>.png,
    // replacing the previous shot of that name; an absolute path ending in .png is used as given.
    let out: String
    if name.hasPrefix("/") {
        guard name.lowercased().hasSuffix(".png"), !name.contains("/../") else { throw Fail(message: "a shot path must be absolute and end in .png", code: 2) }
        out = name
    } else {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw Fail(message: "shot takes a plain name or an absolute .png path", code: 2) }
        let dir = ProcessInfo.processInfo.environment["ANYBROWSER_SHOTS"] ?? NSTemporaryDirectory()
        out = (dir as NSString).appendingPathComponent("\(name).png")
    }
    let raw = out + ".raw.png"

    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    var area = CGDisplayBounds(CGMainDisplayID())
    var arguments = ["-x", "-t", "png"]
    if let r = region {
        area = r.integral
        arguments += ["-R", "\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))"]
    } else if let d = display {
        guard d >= 1 && d <= Int(count) else { throw Fail(message: count == 1 ? "there is one display: --display 1" : "there are \(count) displays: --display 1…\(count)", code: 2) }
        area = CGDisplayBounds(ids[d - 1])
        arguments += ["-D", "\(d)"]
    } else {
        arguments += ["-m"]
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = arguments + [raw]
    try p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: raw) }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: raw) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw Fail(message: "screenshot failed — grant Screen Recording (anybrowser check)")
    }
    // Retina captures at 2x: scale to the area's size in points, so one pixel in
    // the image is one point for the mouse.
    let w = Int(area.width), h = Int(area.height)
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw Fail(message: "could not scale the screenshot")
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let scaled = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) else {
        throw Fail(message: "could not write \(out)")
    }
    CGImageDestinationAddImage(dest, scaled, nil)
    CGImageDestinationFinalize(dest)
    if area.origin == .zero { return out }
    return "\(out)  (\(w)×\(h) starting at \(Int(area.minX)) \(Int(area.minY)) — add that to a pixel to get the point to click)"
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let o = axPoint(el.attr(kAXPositionAttribute)), let s = axSize(el.attr(kAXSizeAttribute)) else { return nil }
    return CGRect(origin: o, size: s)
}

