// macuse — eyes and hands for the macOS desktop, in one native binary.
//
// Coordinates are logical points: a pixel read off `shot` is the point `click`
// takes. Everything goes through the Accessibility API and CoreGraphics events,
// in-process: no AppleScript, no helper apps, nothing to inject into.
//
// Every action waits for the app to react and says what changed, so the agent
// gets its confirmation in the same call instead of taking a screenshot.
//
// Build: swiftc -O macuse.swift -o macuse   (install.sh does it)

import AppKit
import ApplicationServices
import Carbon
import ImageIO

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
/// MACUSE_DEBUG=1: timestamps on stderr, to see where a slow step spends its time.
func debug(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["MACUSE_DEBUG"] != nil {
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
        throw Fail(message: "\(what) needs the Accessibility permission — run: macuse check")
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
}

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
let textRoles: Set<String> = ["StaticText", "Heading", "Link", "Button", "Cell", "MenuItem"]
let chromium = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

// One round trip per element instead of one per attribute.
let wanted = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
              kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
              kAXEnabledAttribute, kAXChildrenAttribute] as CFArray

func walk(_ root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 8000,
          stop: ((Node) -> Bool)? = nil, clip: CGRect? = nil) -> (nodes: [Node], sawWeb: Bool) {
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
            let node = Node(el: el, name: name, role: role, point: point, disabled: enabled == false, inWeb: inWeb)
            nodes.append(node)
            if let stop = stop, stop(node) { done = true; return }
        }
        if let kids = value(values, 8) as? [AXUIElement] {
            for k in kids { visit(k, depth + 1, inWeb) }
        }
    }
    visit(root, 0, false)
    return (nodes, sawWeb)
}

/// Named elements of the focused window. Wakes Chromium's page tree when needed.
func frontTree(stop: ((Node) -> Bool)? = nil, visibleOnly: Bool = false) throws -> [Node] {
    try requireUnlocked()
    guard AXIsProcessTrusted() else { throw Fail(message: "reading the screen needs the Accessibility permission — run: macuse check") }
    guard let app = focusedApp() else { throw Fail(message: "the frontmost app has no window") }
    guard let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else {
        throw Fail(message: "the frontmost app has no window")
    }
    var clip: CGRect? = nil
    if visibleOnly, let o = axPoint(win.attr(kAXPositionAttribute)), let sz = axSize(win.attr(kAXSizeAttribute)) {
        clip = CGRect(origin: o, size: sz).intersection(CGDisplayBounds(CGMainDisplayID()))
    }
    var result = walk(win, stop: stop, clip: clip)
    let bundle = NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier ?? ""
    if !result.sawWeb, chromium.contains(where: { bundle.hasPrefix($0) }) {
        // Chrome builds the page's tree only once an assistive app asks, with the
        // attribute VoiceOver sets. It replies with an error and does it anyway,
        // ~2 s later; asking again before then restarts the wait. A marker per
        // browser process keeps pageless windows from paying this on every call.
        let marker = NSTemporaryDirectory() + "macuse-chromium-\(app.pid)"
        let age = (try? FileManager.default.attributesOfItem(atPath: marker)[.modificationDate] as? Date)
            .flatMap { $0 }.map { -$0.timeIntervalSinceNow } ?? .infinity
        if age > 120 {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            FileManager.default.createFile(atPath: marker, contents: nil)
            let deadline = now() + 5
            while !result.sawWeb && now() < deadline {
                pause(250)
                result = walk(win, stop: stop, clip: clip)
            }
        }
    }
    return result.nodes
}

func rank(_ nodes: [Node], _ needle: String) -> [Node] {
    let n = needle.lowercased().trimmingCharacters(in: .whitespaces)
    return nodes.enumerated().compactMap { (i, node) -> (Int, Int, Node)? in
        let name = node.name.lowercased()
        let r = name == n ? 0 : name.hasPrefix(n) ? 1 : name.contains(n) ? 2 : -1
        return r < 0 ? nil : (r, i, node)
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
    if n.disabled { s += "  (disabled)" }
    return s
}

/// Best enabled match with a point; scrolls it into view when it's off screen.
/// Waits up to MACUSE_WAIT seconds (default 2) for it to appear: the previous step
/// may still be closing a dialog or loading. Only the search repeats, never an action.
func pick(_ needle: String, fields: Bool = false, roles: Set<String>? = nil, needPoint: Bool = true) throws -> Node {
    let deadline = now() + Double(env("MACUSE_WAIT", 2))
    var found: Node? = nil
    let exact = needle.lowercased().trimmingCharacters(in: .whitespaces)
    let allowed = fields ? inputRoles : roles
    let usable = { (n: Node) -> Bool in
        !n.disabled && (!needPoint || n.point != nil) && (allowed == nil || allowed!.contains(n.role))
    }
    // The first exact, usable match in tree order is what ranking would pick
    // anyway: stop reading the window there.
    let good = { (n: Node) -> Bool in usable(n) && n.name.lowercased() == exact }
    while true {
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
                        disabled: best.disabled, inWeb: best.inWeb)
        }
        best.reachable = reaches(best.point!, best.el)
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
    func settle(first: Int = env("MACUSE_SETTLE", 250), quiet: Int = 90, max: Int = 1500, until: ((Watch) -> Bool)? = nil) {
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

struct Snap {
    var pid: pid_t = 0
    var app = ""
    var window = ""
    var windowKind = ""
    var windows = 0
    var focus = ""
    var value = ""

    static func take() -> Snap {
        var s = Snap()
        // Short timeout: an app busy animating a sheet shouldn't stall the report
        // for two seconds; a field that times out just stays empty.
        guard let app = focusedApp(timeout: 0.4) else { return s }
        s.pid = app.pid
        s.app = appName(app.pid)
        s.windows = (app.attr(kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
        if let w = app.element(kAXFocusedWindowAttribute) {
            s.window = w.text(kAXTitleAttribute)
            let role = w.role, sub = stripAX(w.text(kAXSubroleAttribute)), id = w.text(kAXIdentifierAttribute)
            s.windowKind = [role == "Window" ? "" : role.lowercased(),
                            ["StandardWindow", "Unknown", ""].contains(sub) ? "" : sub.lowercased(),
                            id == "open-panel" ? "file dialog" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        if let f = app.element(kAXFocusedUIElementAttribute) {
            func named(_ e: AXUIElement) -> String {
                for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
                    let t = e.text(a); if !t.isEmpty { return String(flat(t).prefix(60)) }
                }
                return ""
            }
            let role = f.role
            let name = named(f)
            if !name.isEmpty {
                s.focus = "\(name)  [\(role)]"
            } else {
                // An unnamed group is often a dialog: say what it belongs to, or what it says.
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
            if inputRoles.contains(role), role != "SecureTextField" { s.value = String(flat(f.text(kAXValueAttribute)).prefix(80)) }
        }
        return s
    }

    func changes(since b: Snap, watch: Watch) -> String {
        var parts: [String] = []
        if pid != b.pid { parts.append("app: \(b.app) → \(app)") }
        if window != b.window || windowKind != b.windowKind || (pid != b.pid && !window.isEmpty) {
            let kind = windowKind.isEmpty ? "" : " (\(windowKind))"
            if pid == b.pid && windows > b.windows { parts.append("new window: \"\(window)\"\(kind)") }
            else { parts.append("window: \"\(window)\"\(kind)") }
        } else if pid == b.pid && windows != b.windows {
            parts.append(windows > b.windows ? "a window opened" : "a window closed")
        }
        if focus != b.focus && !focus.isEmpty { parts.append("focus: \(focus)") }
        if value != b.value && !value.isEmpty { parts.append("value: \"\(value)\"") }
        if (watch.kinds[kAXMenuOpenedNotification] ?? 0) > 0 { parts.append("menu opened") }
        // Text that changed somewhere else on screen — a status line, a counter.
        var seen = Set<String>([value])
        // Only text a person reads as a result; not toolbars updating their font menus.
        for el in watch.changed where ["StaticText", "Heading", "Cell", "Link", "Button"].contains(el.role) {
            var t = el.text(kAXValueAttribute)
            if t.isEmpty { t = el.text(kAXTitleAttribute) }
            t = String(flat(t).prefix(80))
            if !t.isEmpty && seen.insert(t).inserted && parts.count < 6 { parts.append("text: \"\(t)\"") }
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
func acting(_ body: () throws -> String) throws -> String {
    if env("MACUSE_SETTLE", 250) == 0 {                // fire and forget: no report
        let head = try body()
        return head.isEmpty ? "sent" : head
    }
    let before = Snap.take()
    let watch = Watch()
    debug("acting: before-snapshot taken")
    let head = try body()
    debug("acting: action done")
    watch.settle()
    debug("acting: settled (\(watch.events) events)")
    var after = Snap.take()
    // Something new is on screen: let it finish appearing, or the next click can
    // land while a dialog is still animating in and be silently ignored. Waiting
    // is safe; clicking again would not be.
    let windowMoved = after.pid != before.pid || after.window != before.window || after.windows != before.windows
    // Browsers hold back input on a dialog that just *appeared*; returning to a
    // window that was already there needs no wait.
    let appeared = after.windows > before.windows || (after.pid == before.pid && after.window != before.window && !after.windowKind.isEmpty)
        || (after.pid != before.pid && !after.windowKind.isEmpty)
    if appeared || (after.window != before.window && after.windows == before.windows && after.pid == before.pid && before.windowKind.isEmpty) {
        windowChangedAt = now()
    }
    if windowMoved || (after.focus != before.focus && (after.focus.hasPrefix("[Group]") || after.windowKind.contains("sheet"))) {
        pause(200)
        after = Snap.take()
    }
    // A text field's value can reach the accessibility tree a beat after the edit.
    if after.value.isEmpty, after.focus.hasSuffix("[TextField]") || after.focus.hasSuffix("[TextArea]") {
        pause(80)
        after = Snap.take()
    }
    // Silence can just be slowness: an app still launching, a settings pane
    // loading in another process. Listen a little longer before saying so.
    if watch.events == 0 && after.changes(since: before, watch: watch).hasPrefix("→ no reaction") {
        watch.settle(first: 400, quiet: 90, max: 900)
        after = Snap.take()
    }
    let report = after.changes(since: before, watch: watch)
    return head.isEmpty ? report : "\(head) \(report)"
}

// MARK: - Pointer

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 0) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if clicks > 0 { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
    e.post(tap: .cghidEventTap)
}

/// Move there — instantly, or gliding along an eased path when MACUSE_GLIDE (ms) is set.
func glide(to target: CGPoint, ms: Int = env("MACUSE_GLIDE", 0), dragging: Bool = false) {
    let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
    let from = pointer()
    let distance = hypot(target.x - from.x, target.y - from.y)
    if ms > 0 && distance > 2 {
        let steps = max(2, ms / 8)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t * t * (3 - 2 * t)                     // smoothstep: eases in and out
            post(type, CGPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e))
            pause(Double(ms) / Double(steps))
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
    glide(to: b, ms: max(env("MACUSE_GLIDE", 0), 160), dragging: true)
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

func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
    waitOutNewWindow()
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        pause(4)
    }
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
            units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            e.post(tap: .cghidEventTap)
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
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
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
    for (i, title) in path.enumerated() {
        let items = i == 0 ? bar.children : menuItems(container)
        guard let item = items.first(where: { $0.text(kAXTitleAttribute).lowercased() == title.lowercased() }) else {
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
    repeat { if condition() { return true }; pause(30) } while now() < deadline
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

func shot(_ name: String) throws -> String {
    try requireUnlocked()
    guard !name.contains("/"), !name.hasPrefix(".") else { throw Fail(message: "shot name must be a plain file name", code: 2) }
    let dir = ProcessInfo.processInfo.environment["MACUSE_SHOTS"] ?? NSTemporaryDirectory()
    let raw = (dir as NSString).appendingPathComponent("\(name)_raw.png")
    let out = (dir as NSString).appendingPathComponent("\(name).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-m", "-t", "png", raw]
    try p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: raw) }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: raw) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw Fail(message: "screenshot failed — grant Screen Recording (macuse check)")
    }
    // Retina captures at 2x: scale to the display's width in points, so one
    // pixel in the image is one point for the mouse.
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let w = Int(bounds.width), h = Int(bounds.height)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
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
    return out
}

// MARK: - Commands

let usage = """
macuse — eyes and hands for the macOS desktop

LOOK
  shot [name]              capture the main display, scaled so pixels = click points
  where <text>             elements matching <text>, best first, with centre points
  waitfor <text> [secs]    return as soon as <text> appears (default 10 s)
  waitgone <text> [secs]   return as soon as <text> is gone
  read [--all]             the visible text in order — on a web page, the page
  ui [--all]               named elements you can see (--all: offscreen too)
  apps · menus <app> · pos

ACT  (each one waits for the app to react and reports what changed)
  click X Y | <name>       also dclick, rclick
  press <name>             AXPress: no pointer, works while you use the mouse
  fill <field> "text"      focus a text field by name, replace its content
  select <menu> <option>   pick an option in a pop-up menu or <select>
  type "text"              paste: instant, keeps accents and emoji
  keys "text"              real keystrokes, any characters
  key <name> · hotkey "cmd shift" s
  menu <app> <menu> [<submenu>...] <item>
  focus <app> · open <url> [app] · upload <file>
  move X Y · drag X1 Y1 X2 Y2 · scroll N [dx]

  do "<cmd>" "<cmd>" ...   run a sequence in one call; stops at the first failure
  do -                     the same, one step per line from stdin

  check                    report which permissions are missing

Environment: MACUSE_SETTLE=ms (reaction wait, 0 = fire and forget),
             MACUSE_GLIDE=ms (animate the pointer), MACUSE_SHOTS=dir
"""

func point(_ args: [String], _ i: Int) throws -> CGPoint {
    CGPoint(x: try number(args[safe: i], "x"), y: try number(args[safe: i + 1], "y"))
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

func execute(_ args: [String]) throws -> String {
    guard let cmd = args.first else { return usage }
    let a = Array(args.dropFirst())

    switch cmd {
    case "help", "-h", "--help":
        return usage

    case "pos":
        let p = pointer()
        return "\(Int(p.x)) \(Int(p.y))"

    case "shot":
        return try shot(a.first ?? "shot")

    case "where":
        guard let needle = a.first, !needle.isEmpty else { throw Fail(message: "where needs the text to look for", code: 2) }
        let hits = rank(try frontTree(), needle)
        guard !hits.isEmpty else { throw Fail(message: "no element matching: \(needle)") }
        return dedupe(hits.map(line)).prefix(50).joined(separator: "\n")

    case "waitfor":
        guard let needle = a.first, !needle.isEmpty else { throw Fail(message: "waitfor needs the text to look for", code: 2) }
        let secs = a.count > 1 ? try number(a[1], "seconds") : 10
        let deadline = now() + secs
        while true {
            if let hits = try? rank(frontTree(), needle), !hits.isEmpty { return dedupe(hits.map(line)).prefix(10).joined(separator: "\n") }
            if now() >= deadline { throw Fail(message: "not found after \(Int(secs))s: \(needle)") }
            // Wake on the app's own notifications rather than a fixed poll.
            Watch().settle(first: 300, quiet: 40, max: 600)
        }

    case "ui":
        let lines = dedupe(try frontTree(visibleOnly: !a.contains("--all")).map(line))
        guard !lines.isEmpty else { throw Fail(message: "no named elements in the front window") }
        return lines.count > 200 ? (lines.prefix(200) + ["… \(lines.count - 200) more — narrow it with: where <text>"]).joined(separator: "\n")
                                 : lines.joined(separator: "\n")

    case "read":
        let nodes = try frontTree(visibleOnly: !a.contains("--all"))
        let source = nodes.contains { $0.inWeb } ? nodes.filter { $0.inWeb } : nodes
        var lines: [String] = []
        for n in source where textRoles.contains(n.role) {
            let t = flat(n.name)
            if !t.isEmpty && lines.last != t { lines.append(t) }
        }
        guard !lines.isEmpty else { throw Fail(message: "no readable text in the front window") }
        return lines.count > 400 ? (lines.prefix(400) + ["… \(lines.count - 400) more lines"]).joined(separator: "\n")
                                 : lines.joined(separator: "\n")

    case "apps":
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }.sorted().joined(separator: "\n")

    case "menus":
        guard let name = a.first, let app = runningApp(name) else { throw Fail(message: "no running application named: \(a.first ?? "")") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = ax.element(kAXMenuBarAttribute) else { throw Fail(message: "\(name) has no menu bar") }
        return bar.children.map { $0.text(kAXTitleAttribute) }.filter { !$0.isEmpty }.joined(separator: "\n")

    case "click", "dclick", "rclick":
        try requireTrust(cmd)
        let count = cmd == "dclick" ? 2 : 1
        let button: CGMouseButton = cmd == "rclick" ? .right : .left
        var coords = a
        if a.count == 1, let m = a[0].range(of: #"^-?\d+(\.\d+)?\s+-?\d+(\.\d+)?$"#, options: .regularExpression) {
            coords = a[0][m].split(separator: " ").map(String.init)
        }
        if coords.count == 2, Double(coords[0]) != nil {
            let p = try point(coords, 0)
            return try acting { click(p, button: button, count: count); return "" }
        }
        guard let needle = a.first else { throw Fail(message: "\(cmd) needs X Y or a name", code: 2) }
        let target = try pick(needle)
        if !target.reachable {
            // Never click a point that would land on something else.
            guard cmd == "click" else {
                throw Fail(message: "\(label(target)) is covered or off screen — a \(cmd) there would hit something else")
            }
            return try acting {
                target.el.perform(kAXPressAction, timeout: 0.3)
                return "pressed \(label(target)) through accessibility — it's covered or off screen, a click there would hit something else"
            }
        }
        return try acting {
            click(target.point!, button: button, count: count)
            return "\(cmd)ed \(label(target)) at \(Int(target.point!.x)) \(Int(target.point!.y))"
        }

    case "press":
        try requireTrust("press")
        guard let needle = a.first else { throw Fail(message: "press needs a name", code: 2) }
        let target = try pick(needle, needPoint: false)
        return try acting {
            let r = target.el.perform(kAXPressAction, timeout: 0.3)
            if r != .success && r != .cannotComplete { throw Fail(message: "\(label(target)) can't be pressed (\(r.rawValue)) — try click") }
            return "pressed \(label(target))"
        }

    case "select":
        try requireTrust("select")
        guard a.count == 2 else { throw Fail(message: "select needs a menu and an option: select \"Country\" \"Italy\"", code: 2) }
        let popup = try pick(a[0], roles: ["PopUpButton", "ComboBox", "MenuButton"], needPoint: false)
        return try acting { try choose(popup, a[1]) }

    case "waitgone":
        guard let needle = a.first, !needle.isEmpty else { throw Fail(message: "waitgone needs the text that should disappear", code: 2) }
        let secs = a.count > 1 ? try number(a[1], "seconds") : 10
        let deadline = now() + secs
        while true {
            let hits = rank(try frontTree(), needle)
            if hits.isEmpty { return "gone: \(needle)" }
            if now() >= deadline { throw Fail(message: "still there after \(Int(secs))s: \(label(hits[0]))") }
            Watch().settle(first: 300, quiet: 40, max: 600)
        }

    case "fill":
        try requireTrust("fill")
        guard a.count == 2 else { throw Fail(message: "fill needs a field name and the text: fill \"Email\" \"me@example.com\"", code: 2) }
        let field = try pick(a[0], fields: true)
        let want = a[1]
        // Letters and digits only: a field may format what it gets ("333 1234").
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let holds = { norm(field.el.text(kAXValueAttribute)) == norm(want) }
        return try acting {
            // Focus it like a person, select what's there, paste: the page gets
            // real input events, not a value set behind its back.
            func put() throws {
                if field.reachable { click(field.point!) }
                else { AXUIElementSetAttributeValue(field.el, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
                pause(60)
                try hotkey("cmd", "a")
                paste(want)
            }
            try put()
            if field.role == "SecureTextField" { return "filled \(label(field))" }
            // Safari's AutoFill can swallow the first paste into a contact field
            // (the text stays a preview and is dropped). Filling again with the
            // same text is harmless, so check and do it once more.
            if !until(0.8, holds) {
                try put()
                if !until(0.8, holds) {
                    return "filled \(label(field)) — but it shows \"\(String(flat(field.el.text(kAXValueAttribute)).prefix(60)))\""
                }
                return "filled \(label(field)) (second try: the first didn't stick)"
            }
            return "filled \(label(field))"
        }

    case "type":
        try requireTrust("type")
        return try acting { paste(a.first ?? ""); return "" }

    case "keys":
        try requireTrust("keys")
        return try acting { typeKeys(a.first ?? ""); return "" }

    case "key":
        try requireTrust("key")
        guard let name = a.first, let code = namedKeys[name.lowercased()] else {
            throw Fail(message: "unknown key: \(a.first ?? "") — keys: \(namedKeys.keys.sorted().joined(separator: " "))", code: 2)
        }
        return try acting { tap(code); return "" }

    case "hotkey":
        try requireTrust("hotkey")
        return try acting { try hotkey(a[safe: 0] ?? "", a[safe: 1] ?? ""); return "" }

    case "menu":
        try requireTrust("menu")
        guard let app = a.first else { throw Fail(message: "menu needs an app, a menu and an item", code: 2) }
        return try acting { try clickMenu(app, Array(a.dropFirst())) }

    case "focus":
        guard let app = a.first else { throw Fail(message: "focus needs an app name", code: 2) }
        try activate(app)
        return "focused \(app)"

    case "open":
        guard let url = a.first, url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw Fail(message: "open takes http(s) URLs only", code: 2)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = a.count > 1 ? ["-a", a[1], url] : [url]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Fail(message: "could not open \(url)") }
        return "opened \(url)"

    case "upload":
        guard let file = a.first else { throw Fail(message: "upload needs a file path", code: 2) }
        let full = (file as NSString).expandingTildeInPath
        let abs = full.hasPrefix("/") ? full : FileManager.default.currentDirectoryPath + "/" + full
        guard FileManager.default.fileExists(atPath: abs) else { throw Fail(message: "no such file: \(file)") }
        return try acting { try upload((abs as NSString).standardizingPath) }

    case "move":
        try requireTrust("move")
        let p = try point(a, 0)
        glide(to: p)
        return ""

    case "drag":
        try requireTrust("drag")
        let from = try point(a, 0), to = try point(a, 2)
        return try acting { drag(from, to); return "" }

    case "scroll":
        try requireTrust("scroll")
        let dy = Int32(try number(a.first, "lines")), dx = Int32(a.count > 1 ? try number(a[1], "dx") : 0)
        return try acting {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
            return ""
        }

    case "check":
        var lines: [String] = []
        if screenLocked() { lines.append("screen            LOCKED — unlock it, then run check again") }
        let screen = CGPreflightScreenCaptureAccess()
        lines.append("screen recording  " + (screen ? "ok" : "MISSING — System Settings > Privacy & Security > Screen Recording"))
        // Posted events can be dropped without a word, so measure one.
        let before = pointer()
        post(.mouseMoved, CGPoint(x: before.x + 1, y: before.y))
        pause(60)
        let moved = pointer().x != before.x
        post(.mouseMoved, before)
        lines.append("accessibility     " + (AXIsProcessTrusted() && moved ? "ok"
            : "MISSING — clicks, keys and reading the screen will fail;\n                  System Settings > Privacy & Security > Accessibility, add your terminal app, restart it"))
        return lines.joined(separator: "\n")

    case "do":
        var lines: [String] = []
        // do - : one step per line from stdin; blank lines and # comments skipped.
        var steps = a
        if a == ["-"] {
            let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            steps = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let a = steps
        for (i, step) in a.enumerated() {
            let words = try tokenize(step)
            guard let first = words.first, first != "do" else { continue }
            do {
                let started = now()
                let result = try execute(words)
                let took = Int((now() - started) * 1000)
                lines.append("[\(i + 1)] \(step)  (\(took) ms)" + (result.isEmpty ? "" : "\n    " + result.replacingOccurrences(of: "\n", with: "\n    ")))
            } catch let f as Fail {
                lines.append("[\(i + 1)] \(step)\n    FAILED: \(f.message)")
                say(lines.joined(separator: "\n"))
                throw Fail(message: "stopped at step \(i + 1) of \(a.count)", code: f.code)
            }
        }
        return lines.joined(separator: "\n")

    default:
        throw Fail(message: "unknown command: \(cmd)\n\n\(usage)")
    }
}

func dedupe(_ lines: [String]) -> [String] {
    var out: [String] = []
    for l in lines where out.last != l { out.append(l) }
    return out
}

/// Shell-style words: "double" and 'single' quotes, backslash escapes.
func tokenize(_ s: String) throws -> [String] {
    var words: [String] = [], cur = "", quote: Character? = nil, escaped = false, has = false
    for ch in s {
        if escaped { cur.append(ch); escaped = false; continue }
        if ch == "\\" && quote != "'" { escaped = true; continue }
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
            continue
        }
        if ch == "\"" || ch == "'" { quote = ch; has = true; continue }
        if ch == " " || ch == "\t" {
            if has || !cur.isEmpty { words.append(cur); cur = ""; has = false }
            continue
        }
        cur.append(ch)
    }
    if quote != nil { throw Fail(message: "unclosed quote in: \(s)", code: 2) }
    if has || !cur.isEmpty { words.append(cur) }
    return words
}

// MARK: - Main

do {
    let result = try execute(Array(CommandLine.arguments.dropFirst()))
    if !result.isEmpty { say(result) }
    exit(0)
} catch let f as Fail {
    warn(f.message)
    exit(f.code)
} catch {
    warn("\(error)")
    exit(1)
}
