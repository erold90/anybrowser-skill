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
    let running = NSRunningApplication(processIdentifier: app.pid)
    let bundle = running?.bundleIdentifier ?? ""
    let frameworks = running?.bundleURL?.appendingPathComponent("Contents/Frameworks").path ?? ""
    let electron = FileManager.default.fileExists(atPath: frameworks + "/Electron Framework.framework")
        || FileManager.default.fileExists(atPath: frameworks + "/Chromium Embedded Framework.framework")
    let browser = chromium.contains(where: { bundle.hasPrefix($0) })
    // A lookup that already found its exact match doesn't need the page woken.
    let matched = stop.map { found in result.nodes.last.map(found) ?? false } ?? false
    if !result.sawWeb, !matched, browser || electron {
        // Chromium builds a page's tree only when an assistive app asks: browsers
        // listen for the attribute VoiceOver sets, Electron apps for
        // AXManualAccessibility. Chrome answers the first with an error and obeys
        // anyway, ~2 s later; asking again before then restarts the wait, and a
        // marker per process keeps windows with no page from paying it each call.
        let marker = NSTemporaryDirectory() + "macuse-web-\(app.pid)"
        let age = (try? FileManager.default.attributesOfItem(atPath: marker)[.modificationDate] as? Date)
            .flatMap { $0 }.map { -$0.timeIntervalSinceNow } ?? .infinity
        if age > 120 {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if electron { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
            FileManager.default.createFile(atPath: marker, contents: nil)
            // Wait for a page with something in it, not just an empty web area.
            let deadline = now() + 6
            while now() < deadline {
                pause(250)
                result = walk(win, stop: stop, clip: clip)
                if result.sawWeb && result.nodes.filter({ $0.inWeb }).count >= 3 { break }
            }
        }
    }
    return result.nodes
}

/// Exact name, then the needle as a whole first word ("Invia" → "Invia (⌘Enter)"),
/// then any prefix ("Inviati"), then anywhere. Invisible direction marks, which web
/// apps put around shortcuts, don't count.
func rank(_ nodes: [Node], _ needle: String) -> [Node] {
    let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
    func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !invisible.contains($0) })).lowercased()
            .trimmingCharacters(in: .whitespaces)
    }
    let n = clean(needle)
    return nodes.enumerated().compactMap { (i, node) -> (Int, Int, Node)? in
        let name = clean(node.name)
        let r: Int
        if name == n { r = 0 }
        else if name.hasPrefix(n) {
            let next = name[name.index(name.startIndex, offsetBy: n.count)...].first
            r = (next.map { !$0.isLetter && !$0.isNumber } ?? true) ? 1 : 2
        }
        else if name.contains(n) { r = 3 }
        else { return nil }
        return (r, i, node)
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
/// Waits up to MACUSE_WAIT seconds (default 2) for it to appear: the previous step
/// may still be closing a dialog or loading. Only the search repeats, never an action.
func pick(_ needle: String, fields: Bool = false, roles: Set<String>? = nil, needPoint: Bool = true) throws -> Node {
    let deadline = now() + Double(env("MACUSE_WAIT", 2))
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
                        disabled: best.disabled, inWeb: best.inWeb, on: best.on)
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

let webBundles = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"] + chromium

/// Browsers and Electron/CEF apps: pages whose text changes without telling anyone.
func isWebApp(_ pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    let bundle = app.bundleIdentifier ?? ""
    if webBundles.contains(where: { bundle.hasPrefix($0) }) { return true }
    let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks").path ?? ""
    return FileManager.default.fileExists(atPath: frameworks + "/Electron Framework.framework")
        || FileManager.default.fileExists(atPath: frameworks + "/Chromium Embedded Framework.framework")
}

/// The text a person can see on the page right now, line by line. Never wakes a
/// page tree (that can take seconds): a report must stay quick.
func visiblePageText() -> [String] {
    guard let app = focusedApp(timeout: 0.5), let win = app.element(kAXFocusedWindowAttribute),
          let o = axPoint(win.attr(kAXPositionAttribute)), let size = axSize(win.attr(kAXSizeAttribute)) else { return [] }
    let clip = CGRect(origin: o, size: size).intersection(CGDisplayBounds(CGMainDisplayID()))
    return walk(win, maxNodes: 3000, clip: clip).nodes
        .filter { $0.inWeb && ["StaticText", "Heading", "Cell", "Link"].contains($0.role) }
        .map { String(flat($0.name).prefix(100)) }
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
        s.windows = realWindows(app).count
        var focusedWindow: AXUIElement? = nil
        if let w = app.element(kAXFocusedWindowAttribute) {
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

    func changes(since b: Snap, watch: Watch, pageAdded: [String] = [], web: Bool = false) -> String {
        var parts: [String] = []
        let title = window.isEmpty ? "(untitled)" : "\"\(window)\""
        let kind = windowKind.isEmpty ? "" : " (\(windowKind))"
        let sameWindow = windowRef != nil && b.windowRef != nil && CFEqual(windowRef!, b.windowRef!)
        if pid != b.pid {
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
        if dialog != b.dialog && !dialog.isEmpty { parts.append(dialog) }
        if focus != b.focus && !focus.isEmpty && dialog.isEmpty { parts.append("focus: \(focus)") }
        if value != b.value && !value.isEmpty { parts.append("value: \"\(value)\"") }
        if selection != b.selection && !selection.isEmpty { parts.append("selected: \(selection)") }
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
func acting(_ body: () throws -> String) throws -> String {
    if env("MACUSE_SETTLE", 250) == 0 {                // fire and forget: no report
        let head = try body()
        return head.isEmpty ? "sent" : head
    }
    let before = Snap.take()
    let web = before.pid > 0 && isWebApp(before.pid)
    let pageBefore = web ? Set(visiblePageText()) : []
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
    var pageAdded: [String] = []
    func diffPage() {
        // A new page or tab is all new text: the title already says what happened.
        // So is the page coming back from behind a dialog that hid it.
        guard web, after.pid == before.pid, after.dialog.isEmpty, before.dialog.isEmpty, after.window == before.window else { pageAdded = []; return }
        let now = visiblePageText()
        var seen = Set<String>()
        pageAdded = now.filter { !pageBefore.contains($0) && !$0.isEmpty && seen.insert($0).inserted }.prefix(4).map { $0 }
    }
    diffPage()
    // Silence can just be slowness: an app still launching, a settings pane
    // loading in another process. Listen a little longer before saying so.
    if watch.events == 0 && after.changes(since: before, watch: watch, pageAdded: pageAdded, web: web).hasPrefix("→ no reaction") {
        watch.settle(first: 400, quiet: 90, max: 900)
        after = Snap.take()
        diffPage()
    }
    let report = after.changes(since: before, watch: watch, pageAdded: pageAdded, web: web)
    return head.isEmpty ? report : "\(head) \(report)"
}

// MARK: - Pointer

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// Set once anything is posted: events still in flight when the process exits are
/// dropped by the window server — a lone "move" to a point never arrived.
var postedEvents = false

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
/// jumping, at little cost. MACUSE_GLIDE=0 teleports, MACUSE_GLIDE=<ms> fixes it.
func glideDuration(_ distance: Double) -> Double {
    if let raw = ProcessInfo.processInfo.environment["MACUSE_GLIDE"], let ms = Double(raw), ms >= 0 { return distance > 2 ? ms : 0 }
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
    // A plain name goes to MACUSE_SHOTS (default: the temp folder) as <name>.png,
    // replacing the previous shot of that name; an absolute path ending in .png is used as given.
    let out: String
    if name.hasPrefix("/") {
        guard name.lowercased().hasSuffix(".png"), !name.contains("/../") else { throw Fail(message: "a shot path must be absolute and end in .png", code: 2) }
        out = name
    } else {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw Fail(message: "shot takes a plain name or an absolute .png path", code: 2) }
        let dir = ProcessInfo.processInfo.environment["MACUSE_SHOTS"] ?? NSTemporaryDirectory()
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
        throw Fail(message: "screenshot failed — grant Screen Recording (macuse check)")
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

// MARK: - Commands

let usage = """
macuse — eyes and hands for the macOS desktop

LOOK
  shot [name] [--window | --region X Y W H | --display N]
                           capture, scaled so pixels = points (origin given if not 0,0)
  where <text>             elements matching <text>, best first, with centre points
  waitfor <text> [secs]    return as soon as <text> appears (default 10 s)
  waitgone <text> [secs]   return as soon as <text> is gone
  read [--all]             the visible text in order, with field values — on a web page, the page
  ui [--all] [--page]      named elements you can see (--all: offscreen too, --page: web page only)
  apps · windows · menus <app> · pos

ACT  (each one waits for the app to react and reports what changed)
  click X Y | <name>       also dclick, rclick
  press <name>             AXPress: no pointer, works while you use the mouse
  fill <field> "text"      focus a text field by name, replace its content
  select <menu> <option>   pick an option in a pop-up menu or <select>
  type "text"              paste: instant, keeps accents and emoji
  keys "text"              real keystrokes, any characters
  key <name> · hotkey "cmd shift" s
  menu <app> <menu> [<submenu>...] <item>
  focus <app> (launches it if needed) · quit <app> · raise <window title>
  window minimize|restore|maximize|fullscreen|close [title] · window move X Y [title] · window resize W H [title]
  open <url> [app] · upload <file>
  hover X Y | <name>       rest the pointer there: hover menus, tooltips
  drag X1 Y1 X2 Y2 | <name> <name>   press, travel, release — says whether it left
  move X Y · scroll N [dx]

  do "<cmd>" "<cmd>" ...   run a sequence in one call; stops at the first failure
  do -                     the same, one step per line from stdin

  check                    report which permissions are missing
  version                  version, macOS and architecture — paste it into bug reports

Environment: MACUSE_SETTLE=ms (reaction wait, 0 = fire and forget),
             MACUSE_GLIDE=ms (pointer travel; default scales with distance, 0 = jump),
             MACUSE_WAIT=s (lookup wait), MACUSE_DEBUG=1, MACUSE_SHOTS=dir
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

    case "version", "--version":
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "macuse \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)"

    case "pos":
        let p = pointer()
        return "\(Int(p.x)) \(Int(p.y))"

    case "shot":
        let name = a.first(where: { !$0.hasPrefix("--") && Double($0) == nil }) ?? "shot"   // "shot" → $TMPDIR/shot.png
        if let i = a.firstIndex(of: "--region") {
            let x = try number(a[safe: i + 1], "x"), y = try number(a[safe: i + 2], "y")
            let w = try number(a[safe: i + 3], "width"), h = try number(a[safe: i + 4], "height")
            return try shot(name, region: CGRect(x: x, y: y, width: w, height: h))
        }
        if a.contains("--window") {
            try requireTrust("shot --window")
            guard let win = focusedApp()?.element(kAXFocusedWindowAttribute), let f = frame(win) else {
                throw Fail(message: "the frontmost app has no window")
            }
            return try shot(name, region: f)
        }
        if let i = a.firstIndex(of: "--display") {
            return try shot(name, display: Int(try number(a[safe: i + 1], "display")))
        }
        return try shot(name)

    case "windows":
        try requireTrust("windows")
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            for w in realWindows(ax) {
                let title = w.text(kAXTitleAttribute)
                guard let f = frame(w) else { continue }
                let minimized = (w.attr(kAXMinimizedAttribute) as? Bool) == true
                lines.append("\(app.localizedName ?? "?") — \"\(title)\"  at \(Int(f.minX)) \(Int(f.minY)) size \(Int(f.width))×\(Int(f.height))" + (minimized ? "  (minimized)" : ""))
            }
        }
        guard !lines.isEmpty else { throw Fail(message: "no windows") }
        return lines.joined(separator: "\n")

    case "quit":
        guard let name = a.first else { throw Fail(message: "quit needs an app name", code: 2) }
        guard let app = runningApp(name) else { return "\(name) isn't running" }
        let pid = app.processIdentifier
        return try acting {
            // Like Cmd+Q: the app may stop to ask about unsaved work — the report shows that dialog.
            app.terminate()
            if until(3, { NSRunningApplication(processIdentifier: pid) == nil || app.isTerminated }) {
                return "quit \(app.localizedName ?? name)"
            }
            return "asked \(app.localizedName ?? name) to quit — it's still open (waiting on a dialog?)"
        }

    case "window":
        // window minimize|restore|maximize|fullscreen|close [title] · window move X Y [title] · window resize W H [title]
        try requireTrust("window")
        guard let action = a.first else {
            throw Fail(message: "window needs an action: minimize, restore, close, maximize, fullscreen, move X Y, resize W H", code: 2)
        }
        var rest = Array(a.dropFirst())
        var numbers: [Double] = []
        if action == "move" || action == "resize" {
            guard rest.count >= 2, let x = Double(rest[0]), let y = Double(rest[1]) else {
                throw Fail(message: "window \(action) needs two numbers: window \(action) \(action == "move" ? "X Y" : "W H") [title]", code: 2)
            }
            numbers = [x, y]
            rest = Array(rest.dropFirst(2))
        }
        let wanted = rest.joined(separator: " ").lowercased()
        // The window: by (part of) its title across apps, or the front one.
        var target: (NSRunningApplication?, AXUIElement)? = nil
        if wanted.isEmpty {
            if let app = focusedApp(), let w = app.element(kAXFocusedWindowAttribute) {
                target = (NSRunningApplication(processIdentifier: app.pid), w)
            }
        } else {
            func search() {
                var bestRank = Int.max
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                    let ax = AXUIElementCreateApplication(app.processIdentifier)
                    AXUIElementSetMessagingTimeout(ax, 0.5)
                    for w in realWindows(ax) {
                        let t = w.text(kAXTitleAttribute).lowercased()
                        let r = t == wanted ? 0 : t.hasPrefix(wanted) ? 1 : t.contains(wanted) ? 2 : -1
                        if r >= 0 && r < bestRank { bestRank = r; target = (app, w) }
                    }
                }
            }
            search()
            // A window can be mid-transition (leaving full screen takes ~1.5 s, during
            // which it's in no list): give it the same wait a lookup by name gets.
            let deadline = now() + Double(env("MACUSE_WAIT", 2))
            while target == nil && now() < deadline {
                if CFRunLoopRunInMode(.defaultMode, 0.2, false) == .finished { pause(200) }
                search()
            }
            // Some apps (Calculator, SwiftUI) hide their windows from accessibility while
            // in the background. The window server still lists them: front that app, look again.
            if target == nil,
               let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let hit = list.first(where: { (($0[kCGWindowName as String] as? String) ?? "").lowercased().contains(wanted)
                                              && ($0[kCGWindowLayer as String] as? Int) == 0 }),
               let pid = hit[kCGWindowOwnerPID as String] as? pid_t, let app = NSRunningApplication(processIdentifier: pid) {
                app.unhide()                                           // a hidden app's windows aren't on screen at all
                app.activate(options: [])
                _ = until(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
                search()
            }
        }
        guard let (owner, win) = target else {
            throw Fail(message: wanted.isEmpty ? "the frontmost app has no window" : "no window titled like: \(rest.joined(separator: " "))")
        }
        let title = win.text(kAXTitleAttribute).isEmpty ? "(untitled)" : "\"\(win.text(kAXTitleAttribute))\""
        func where_() -> String {
            guard let f = frame(win) else { return "" }
            return " — now at \(Int(f.minX)) \(Int(f.minY)), \(Int(f.width))×\(Int(f.height))"
        }
        func set(_ attribute: String, _ value: CFTypeRef) throws {
            let r = AXUIElementSetAttributeValue(win, attribute as CFString, value)
            if r == .success { return }
            if (win.attr("AXFullScreen") as? Bool) == true && attribute != "AXFullScreen" {
                throw Fail(message: "\(title) is in full screen — window fullscreen \(rest.joined(separator: " ")) leaves it first")
            }
            throw Fail(message: "\(title) doesn't allow that (\(r.rawValue))")
        }
        switch action {
        case "minimize", "minimise":
            return try acting { try set(kAXMinimizedAttribute, kCFBooleanTrue); return "minimized \(title)" }
        case "restore":
            return try acting {
                try set(kAXMinimizedAttribute, kCFBooleanFalse)
                win.perform(kAXRaiseAction, timeout: 0.5)
                owner?.activate(options: [])
                return "restored \(title)"
            }
        case "move":
            var p = CGPoint(x: numbers[0], y: numbers[1])
            guard let v = AXValueCreate(.cgPoint, &p) else { throw Fail(message: "bad position") }
            try set(kAXPositionAttribute, v)
            pause(80)
            let kept = frame(win).map { abs($0.minX - numbers[0]) > 2 || abs($0.minY - numbers[1]) > 2 } ?? false
            return "moved \(title)" + where_() + (kept ? " — not exactly there: macOS keeps windows below the menu bar and on screen" : "")
        case "resize":
            var size = CGSize(width: numbers[0], height: numbers[1])
            guard let v = AXValueCreate(.cgSize, &size) else { throw Fail(message: "bad size") }
            try set(kAXSizeAttribute, v)
            pause(80)
            let kept = frame(win).map { abs($0.width - numbers[0]) > 2 || abs($0.height - numbers[1]) > 2 } ?? false
            return "resized \(title)" + where_() + (kept ? " — the app didn't take that size (a zoomed window, or its own limits)" : "")
        case "maximize", "maximise":
            // Not the green button: on current macOS that means full screen. Fill the
            // screen's usable area (below the menu bar, beside the Dock) instead.
            guard let screen = NSScreen.main else { throw Fail(message: "no screen") }
            let visible = screen.visibleFrame, full = CGDisplayBounds(CGMainDisplayID())
            var origin = CGPoint(x: visible.minX, y: full.height - visible.maxY)      // AppKit is bottom-up, accessibility top-down
            var size = CGSize(width: visible.width, height: visible.height)
            guard let pv = AXValueCreate(.cgPoint, &origin), let sv = AXValueCreate(.cgSize, &size) else { throw Fail(message: "bad frame") }
            try set(kAXPositionAttribute, pv)
            try set(kAXSizeAttribute, sv)
            pause(80)
            return "maximized \(title)" + where_()
        case "close":
            return try acting {
                // Cmd+W on the window brought to the front is what every app honours;
                // pressing the red button through accessibility is only the fallback
                // (TextEdit ignores it). Done when the window is gone or a sheet asks
                // about saving — the sheet is a window of its own, not a child.
                let pid = owner?.processIdentifier ?? 0
                func settled() -> Bool {
                    let ax = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(ax, 0.3)
                    let gone = !realWindows(ax).contains { CFEqual($0, win) }
                    let asking = ax.element(kAXFocusedWindowAttribute)?.role == "Sheet" || win.children.contains { $0.role == "Sheet" }
                    return gone || asking
                }
                owner?.activate(options: [.activateAllWindows])
                win.perform(kAXRaiseAction, timeout: 0.5)
                _ = until(1.5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
                try hotkey("cmd", "w")
                if !until(1, settled), let b = win.element(kAXCloseButtonAttribute) {
                    b.perform(kAXPressAction, timeout: 0.5)
                    _ = until(1, settled)
                }
                return "closed \(title)"
            }
        case "fullscreen":
            let on = (win.attr("AXFullScreen") as? Bool) ?? false
            return try acting {
                try set("AXFullScreen", on ? kCFBooleanFalse : kCFBooleanTrue)
                // The animation takes a second or two; the next step needs it finished.
                _ = until(4) { (win.attr("AXFullScreen") as? Bool) == !on && frame(win) != nil }
                pause(400)
                return "\(on ? "left" : "entered") full screen: \(title)" + where_()
            }
        default:
            throw Fail(message: "unknown window action: \(action) — minimize, restore, close, maximize, fullscreen, move X Y, resize W H", code: 2)
        }

    case "raise":
        try requireTrust("raise")
        guard let wanted = a.first?.lowercased(), !wanted.isEmpty else { throw Fail(message: "raise needs (part of) a window title", code: 2) }
        var best: (NSRunningApplication, AXUIElement, Int)? = nil
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            for w in (ax.attr(kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                let t = w.text(kAXTitleAttribute).lowercased()
                let r = t == wanted ? 0 : t.hasPrefix(wanted) ? 1 : t.contains(wanted) ? 2 : -1
                if r >= 0 && (best == nil || r < best!.2) { best = (app, w, r) }
            }
        }
        guard let (app, win, _) = best else { throw Fail(message: "no window titled like: \(a[0])") }
        if let front = focusedApp()?.element(kAXFocusedWindowAttribute), CFEqual(front, win),
           NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return "\"\(win.text(kAXTitleAttribute))\" is already in front"
        }
        return try acting {
            if (win.attr(kAXMinimizedAttribute) as? Bool) == true {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            win.perform(kAXRaiseAction, timeout: 0.5)
            app.activate(options: [])
            _ = until(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
            return "raised \"\(win.text(kAXTitleAttribute))\" of \(app.localizedName ?? "?")"
        }

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
        var nodes = try frontTree(visibleOnly: !a.contains("--all"))
        if a.contains("--page") { nodes = nodes.filter { $0.inWeb } }            // the page, without the browser around it
        let lines = dedupe(nodes.map(line))
        guard !lines.isEmpty else { throw Fail(message: "no named elements in the front window") }
        return lines.count > 200 ? (lines.prefix(200) + ["… \(lines.count - 200) more — narrow it with: where <text>"]).joined(separator: "\n")
                                 : lines.joined(separator: "\n")

    case "read":
        let nodes = try frontTree(visibleOnly: !a.contains("--all"))
        let source = nodes.contains { $0.inWeb } ? nodes.filter { $0.inWeb } : nodes
        var lines: [String] = []
        for n in source {
            let t: String
            if let v = n.value { t = "\(flat(n.name)): \"\(v)\"" }            // Name: "Grace Hopper"
            else if let on = n.on { t = "\(flat(n.name)): \(on ? "on" : "off")" }
            else if n.role == "TextArea" && n.value == nil { t = "document: \"\(String(flat(n.name).prefix(400)))\"" }   // a text area with no label is the document itself
            else if textRoles.contains(n.role) || inputRoles.contains(n.role) { t = flat(n.name) }
            else { continue }
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
        // menus TextEdit → the menu bar; menus TextEdit Format Font → that submenu's items.
        var container = bar
        for (i, title) in a.dropFirst().enumerated() {
            let items = i == 0 ? bar.children : menuItems(container)
            guard let item = items.first(where: { $0.text(kAXTitleAttribute).lowercased() == title.lowercased() })
                    ?? items.first(where: { $0.text(kAXTitleAttribute).lowercased().hasPrefix(title.lowercased()) }) else {
                throw Fail(message: "no menu \"\(title)\" — there is: \(items.map { $0.text(kAXTitleAttribute) }.filter { !$0.isEmpty }.joined(separator: ", "))")
            }
            container = item
        }
        if a.count == 1 { return bar.children.map { $0.text(kAXTitleAttribute) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        return menuItems(container).compactMap { item -> String? in
            let t = item.text(kAXTitleAttribute)
            if t.isEmpty { return nil }                    // separators
            var line = t
            if item.children.contains(where: { $0.role == "Menu" }) { line += "  ▸" }
            if (item.attr(kAXEnabledAttribute) as? Bool) == false { line += "  (disabled)" }
            if let mark = item.attr("AXMenuItemMarkChar") as? String, !mark.isEmpty { line += "  (checked)" }
            return line
        }.joined(separator: "\n")

    case "click", "dclick", "rclick":
        try requireTrust(cmd)
        let count = cmd == "dclick" ? 2 : 1
        let button: CGMouseButton = cmd == "rclick" ? .right : .left
        var coords = a
        if a.count == 1, let m = a[0].range(of: #"^-?\d+(\.\d+)?\s+-?\d+(\.\d+)?$"#, options: .regularExpression) {
            coords = a[0][m].split(whereSeparator: { $0.isWhitespace }).map(String.init)
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
        try requireUnlocked()
        while true {
            // No window at all means it isn't there either.
            let hits = rank((try? frontTree()) ?? [], needle)
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
        let hasWindow = focusedApp()?.element(kAXFocusedWindowAttribute) != nil
        return hasWindow ? "focused \(app)" : "focused \(app) — it has no window open"

    case "open":
        guard let url = a.first, url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw Fail(message: "open takes http(s) URLs only", code: 2)
        }
        return try acting {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = a.count > 1 ? ["-a", a[1], url] : [url]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw Fail(message: "could not open \(url)") }
            // The browser decides between a new tab and a new window; the report says which.
            return "opened \(url)"
        }

    case "upload":
        guard let file = a.first else { throw Fail(message: "upload needs a file path", code: 2) }
        let full = (file as NSString).expandingTildeInPath
        let abs = full.hasPrefix("/") ? full : FileManager.default.currentDirectoryPath + "/" + full
        guard FileManager.default.fileExists(atPath: abs) else { throw Fail(message: "no such file: \(file)") }
        return try acting { try upload((abs as NSString).standardizingPath) }

    case "hover":
        try requireTrust("hover")
        if a.count == 2, Double(a[0]) != nil {
            let p = try point(a, 0)
            return try acting { glide(to: p); return "hovering at \(Int(p.x)) \(Int(p.y))" }
        }
        guard let needle = a.first else { throw Fail(message: "hover needs X Y or a name", code: 2) }
        let target = try pick(needle)
        guard target.reachable else { throw Fail(message: "\(label(target)) is covered or off screen — nothing to hover") }
        let report = try acting { glide(to: target.point!); return "hovering over \(label(target))" }
        // Most things don't react to a pointer resting on them; that isn't a failure.
        return report.replacingOccurrences(of: " → no reaction seen — confirm with read (or shot) before building on it", with: "")

    case "move":
        try requireTrust("move")
        let p = try point(a, 0)
        glide(to: p)
        return ""

    case "drag":
        try requireTrust("drag")
        // drag X1 Y1 X2 Y2 · drag <name> <name> · either end may be "X Y" in one argument
        if a.count == 4, a.allSatisfy({ Double($0) != nil }) {
            let from = try point(a, 0), to = try point(a, 2)
            return try acting { drag(from, to); return "dragged \(Int(from.x)) \(Int(from.y)) → \(Int(to.x)) \(Int(to.y))" }
        }
        guard a.count == 2 else { throw Fail(message: "drag takes X1 Y1 X2 Y2, or two names: drag \"report.pdf\" \"Archive\"", code: 2) }
        func end(_ arg: String) throws -> (CGPoint, String, Node?) {
            let parts = arg.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) { return (CGPoint(x: x, y: y), "\(Int(x)) \(Int(y))", nil) }
            let node = try pick(arg)
            guard node.reachable else { throw Fail(message: "\(label(node)) is covered or off screen — scroll it into view to drag") }
            return (node.point!, label(node), node)
        }
        let (from, fromLabel, source) = try end(a[0])
        let (to, toLabel, _) = try end(a[1])
        let head = try acting { drag(from, to); return "dragged \(fromLabel) onto \(toLabel)" }
        // Did it leave? An element with the same name still in the same spot means the drop didn't take.
        guard let moved = source else { return head }
        let still = (try? frontTree())?.contains { $0.name == moved.name && $0.role == moved.role && $0.point == moved.point } ?? false
        return head + (still ? " · \"\(moved.name)\" is still where it was" : " · \"\(moved.name)\" is no longer where it was")

    case "scroll":
        try requireTrust("scroll")
        let dy = Int32(try number(a.first, "lines")), dx = Int32(a.count > 1 ? try number(a[1], "dx") : 0)
        return try acting {
            // The wheel scrolls whatever is under the pointer: bring it over the front window first.
            if let win = focusedApp()?.element(kAXFocusedWindowAttribute), let f = frame(win), !f.contains(pointer()) {
                glide(to: CGPoint(x: f.midX, y: f.midY))
                pause(30)
            }
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
            postedEvents = true
            return ""
        }

    case "check":
        var lines: [String] = []
        let held = CGEventSource.flagsState(.combinedSessionState)
        let stuck = [(CGEventFlags.maskCommand, "Cmd"), (.maskShift, "Shift"), (.maskAlternate, "Option"), (.maskControl, "Ctrl")]
            .filter { held.contains($0.0) }.map { $0.1 }
        if screenLocked() { lines.append("screen            LOCKED — unlock it, then run check again") }
        let screen = CGPreflightScreenCaptureAccess()
        lines.append("screen recording  " + (screen ? "ok" : "MISSING — System Settings > Privacy & Security > Screen Recording"))
        // Posted events can be dropped without a word, so measure one.
        let before = pointer()
        post(.mouseMoved, CGPoint(x: before.x + 1, y: before.y))
        pause(60)
        let moved = pointer().x != before.x
        post(.mouseMoved, before)
        lines.append("modifier keys     " + (stuck.isEmpty ? "none held"
            : "\(stuck.joined(separator: "+")) held — if nobody is pressing it, press and release it once, or every click becomes a \(stuck[0])-click"))
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

func finish(_ code: Int32) -> Never {
    if postedEvents { pause(25) }                     // let the window server take delivery
    exit(code)
}

do {
    let result = try execute(Array(CommandLine.arguments.dropFirst()))
    if !result.isEmpty { say(result) }
    finish(0)
} catch let f as Fail {
    warn(f.message)
    finish(f.code)
} catch {
    warn("\(error)")
    finish(1)
}
