// anybrowser — commands and the entry point.

import AppKit
import ApplicationServices
import Carbon

// MARK: - Commands

let usage = """
anybrowser — drive Safari, Chrome and any browser (and the rest of the Mac) without an extension

BROWSER  (the browser in front, or the one named with: use <browser>)
  tabs                     every tab of every running browser, with addresses
  tab <n | text>           switch to tab n of the front window, or the tab whose title or address matches
  tab new [address] [--window] · tab close [n | text] · private [address]
  go <address>             open it in the current tab and wait until it has loaded
  back · forward · reload · waitload [secs]
  url                      title and address of the page in front
  text [--max N]           the whole page's text, in one call
  links [text]             links with their addresses · find <kind> [text] · table [n]
                           kinds: link button field checkbox radio heading table image list landmark frame control
  js "<code>"              run JavaScript in the page (needs the browser's Allow JavaScript from Apple Events)
  source [--save file]     the page's HTML (Safari)
  history [text] [--days N] [--limit N] · bookmarks [text]    (--ui: open the browser's own window)
  bookmark ["title"]       bookmark the page in front · readinglist [address] (Safari)
  downloads [n]            newest downloads, with where each came from
  settings [text]          open the browser's settings (Chrome: searched; Safari: that pane)

LOOK
  shot [name] [--window | --element <name|@ref> | --region X Y W H | --display N]
                           capture, scaled so pixels = points (origin given if not 0,0)
  where <text>             elements matching <text>, best first, with centre points
                           listings number elements (@1, @2…): click @2, fill @1 "x" use exactly that one
  waitfor <text> [secs]    return as soon as <text> appears (default 10 s)
  waitgone <text> [secs]   return as soon as <text> is gone
  expect <text> [secs]     a check for do: passes, or stops the sequence (default 3 s)
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

  check                    permissions, and what each running browser allows
  version                  version, macOS and architecture — paste it into bug reports

Environment: ANYBROWSER_SETTLE=ms (reaction wait, 0 = fire and forget),
             ANYBROWSER_GLIDE=ms (pointer travel; default scales with distance, 0 = jump),
             ANYBROWSER_WAIT=s (lookup wait), ANYBROWSER_BROWSER=name, ANYBROWSER_DEBUG=1, ANYBROWSER_SHOTS=dir
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
        return "anybrowser \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)"

    case "pos":
        let p = pointer()
        return "\(Int(p.x)) \(Int(p.y))"

    case "shot":
        // The name is the first word that isn't a flag or a flag's value.
        var name = "shot"                                                                   // "shot" → $TMPDIR/shot.png
        var skip = 0
        for (i, w) in a.enumerated() {
            if skip > 0 { skip -= 1; continue }
            switch w {
            case "--region": skip = 4
            case "--display", "--element": skip = 1
            default: if !w.hasPrefix("--") && i >= 0 { name = w; break }
            }
            if name != "shot" { break }
        }
        if let i = a.firstIndex(of: "--element") {
            guard let target = a[safe: i + 1] else { throw Fail(message: "shot --element needs a name or a ref", code: 2) }
            try requireTrust("shot --element")
            let node = try pick(target, needPoint: false)
            guard let f = frame(node.el), f.width > 0, f.height > 0 else { throw Fail(message: "\(label(node)) has no size on screen") }
            return try shot(name, region: f.insetBy(dx: -6, dy: -6))
        }
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
            let deadline = now() + Double(env("ANYBROWSER_WAIT", 2))
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
            // A browser whose page tree was woken with AXEnhancedUserInterface animates
            // every move and resize, slowly; switch it off around the change.
            let ownerAX = AXUIElementCreateApplication(owner?.processIdentifier ?? win.pid)
            let enhanced = [kAXPositionAttribute, kAXSizeAttribute].contains(attribute)
                && (ownerAX.attr("AXEnhancedUserInterface") as? Bool) == true
            if enhanced { AXUIElementSetAttributeValue(ownerAX, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            defer { if enhanced { AXUIElementSetAttributeValue(ownerAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
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
        return numbered(hits, limit: 50, line).prefix(50).joined(separator: "\n")

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

    case "expect":
        // expect <text> [secs]: a check inside a do — passes quietly, or stops the sequence.
        guard let needle = a.first, !needle.isEmpty else { throw Fail(message: "expect needs the text that should be there", code: 2) }
        let secs = a.count > 1 ? try number(a[1], "seconds") : 3
        let deadline = now() + secs
        while true {
            if let page = pageState(), page.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return "ok: \"\(needle)\" is on the page"
            }
            if let hits = try? rank(frontTree(), needle), let first = hits.first { return "ok: \(label(first))" }
            if now() >= deadline { throw Fail(message: "expected \"\(needle)\" — not there after \(Int(secs)) s") }
            Watch().settle(first: 250, quiet: 40, max: 500)
        }

    case "ui":
        var nodes = try frontTree(visibleOnly: !a.contains("--all"))
        if a.contains("--page") { nodes = nodes.filter { $0.inWeb } }            // the page, without the browser around it
        let lines = numbered(nodes, limit: 200, line)
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
        // choose() reads the value back, so silence around it isn't doubt.
        return try acting { try choose(popup, a[1]) }
            .replacingOccurrences(of: " → no reaction seen — confirm with read (or shot) before building on it", with: "")
            .replacingOccurrences(of: " → the app reacted (1 accessibility events), nothing moved in focus", with: "")

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


    // MARK: Browser commands

    case "use":
        guard let name = a.first else { throw Fail(message: "use needs a browser: use chrome · use safari", code: 2) }
        guard let b = browserNamed(name) else { throw Fail(message: "\(name) isn't running — start it with: focus \(name)") }
        chosenBrowser = name
        return "browser commands now mean \(browserName(b))"

    case "tabs":
        return try tabsReport()

    case "tab":
        guard let sub = a.first else {
            throw Fail(message: "tab needs a number, some text, new or close: tab 2 · tab gmail · tab new example.com · tab close", code: 2)
        }
        if sub == "new" {
            let browser = try targetBrowser()
            let inWindow = a.contains("--window")
            let url = try a.dropFirst().first(where: { $0 != "--window" }).map(normalizeURL)
            let started = now()
            if family(browser) == .other {
                bringToFront(browser)
                try hotkey("cmd", inWindow ? "n" : "t")
                if let u = url { pause(200); paste(u); tap(36) }
            } else {
                _ = try Scripting.call(browser, "new", [url ?? "", inWindow ? "window" : ""])
                bringToFront(browser)
            }
            guard url != nil else { return "opened a new \(inWindow ? "window" : "tab") in \(browserName(browser))" }
            return loadedReport(inWindow ? "new window:" : "new tab:", waitLoad(browser, from: nil, seconds: 20), started)
        }
        if sub == "close" {
            let browser = try targetBrowser()
            let target: TabInfo
            if a.count > 1 {
                target = try findTab(Array(a.dropFirst()).joined(separator: " "), [browser]).1
            } else {
                guard let t = try tabList(browser).first(where: { $0.windowIndex == 1 && $0.active }) else {
                    throw Fail(message: "\(browserName(browser)) has no tab open")
                }
                target = t
            }
            if family(browser) == .other {
                try selectTab(browser, target)
                try hotkey("cmd", "w")
            } else {
                _ = try Scripting.call(browser, "close", [target.window, "\(target.index)"])
            }
            let left = ((try? tabList(browser)) ?? []).filter { $0.window == target.window }
            let now = left.first(where: { $0.active }).map { " — now showing \"\(String(flat($0.title).prefix(70)))\"" } ?? ""
            return "closed tab \(target.index) \"\(String(flat(target.title).prefix(70)))\" — \(left.count) left in that window\(now)"
        }
        let query = a.joined(separator: " ")
        let (browser, t, _) = try findTab(query, chosenBrowser != nil ? [try targetBrowser()] : runningBrowsers())
        try selectTab(browser, t)
        return "switched to \(browserName(browser)), tab \(t.index): \"\(String(flat(t.title).prefix(80)))\"" + (t.url.isEmpty ? "" : " — \(t.url)")

    case "private":
        let browser = try targetBrowser()
        let url = try a.first.map(normalizeURL)
        let started = now()
        if family(browser) == .chromium {
            _ = try Scripting.call(browser, "new", [url ?? "", "private"])
            bringToFront(browser)
        } else {
            bringToFront(browser)
            let ax = AXUIElementCreateApplication(browser.processIdentifier)
            let before = realWindows(ax).count
            try pressMenuCommand(browser, key: "n", modifiers: 1, what: "a private window")
            guard until(3, { realWindows(ax).count > before }) else { throw Fail(message: "no private window opened — take a shot") }
            if let u = url {
                pause(150)
                if family(browser) == .safari { _ = try Scripting.call(browser, "go", ["", u]) }
                else { try hotkey("cmd", "l"); paste(u); tap(36) }
            }
        }
        guard url != nil else { return "opened a private window in \(browserName(browser))" }
        return loadedReport("private window:", waitLoad(browser, from: nil, seconds: 20), started)

    case "go":
        guard let raw = a.first else { throw Fail(message: "go needs an address: go example.com", code: 2) }
        return try navigate("go", url: try normalizeURL(raw))

    case "back", "forward", "reload":
        return try navigate(cmd)

    case "waitload":
        let browser = try targetBrowser()
        let secs = a.isEmpty ? 20 : try number(a[0], "seconds")
        let started = now()
        let r = waitLoad(browser, from: nil, seconds: secs)
        guard r.done else { throw Fail(message: "still loading after \(Int(secs)) s: \(r.url)") }
        return loadedReport("loaded", r, started)

    case "url":
        let browser = try targetBrowser()
        let (win, web) = try browserPage(browser)
        let loaded = (web.attr("AXLoaded") as? Bool) ?? true
        return "\"\(String(flat(pageTitle(web, win)).prefix(100)))\" — \(axURL(web))" + (loaded ? "" : "  (still loading)")

    case "text":
        let browser = try targetBrowser()
        let (win, web) = try browserPage(browser)
        let max = a.firstIndex(of: "--max").map { i in Int((try? number(a[safe: i + 1], "--max")) ?? 12000) } ?? 12000
        guard var raw = pageText(web) else { throw Fail(message: "this page hands over no text — try read") }
        // Text without line breaks in it came from Chromium: take it line by line instead.
        if raw.count > 40, raw.filter({ $0 == "\n" }).count * 150 < raw.count, let lines = pageLines(web, limit: max + 2000) {
            raw = lines
        }
        let text = tidyText(raw)
        let head = "\"\(String(flat(pageTitle(web, win)).prefix(100)))\" — \(axURL(web))\n\n"
        if text.count <= max { return head + text }
        return head + String(text.prefix(max)) + "\n… \(text.count - max) more characters: text --max \(text.count)"

    case "links":
        let browser = try targetBrowser()
        let (_, web) = try browserPage(browser)
        let filter = a.joined(separator: " ").lowercased()
        var nodes: [Node] = []
        var urls: [String] = []
        var seen = Set<String>()
        for el in webSearch(web, "AXLinkSearchKey", limit: 2000) {
            let url = axURL(el)
            let node = walk(el, maxDepth: 0, inWeb: true).nodes.first
                ?? Node(el: el, name: "", role: "Link", point: frame(el).map { CGPoint(x: $0.midX.rounded(), y: $0.midY.rounded()) }, disabled: false, inWeb: true)
            let name = flat(node.name)
            guard filter.isEmpty || name.lowercased().contains(filter) || url.lowercased().contains(filter) else { continue }
            guard seen.insert(name + "\u{0}" + url).inserted else { continue }
            nodes.append(node)
            urls.append(url)
        }
        var i = 0
        let lines = numbered(nodes, limit: 150) { node in
            defer { i += 1 }
            var line = "\(node.name.isEmpty ? "(no text)" : String(flat(node.name).prefix(80))) — \(String(urls[i].prefix(120)))"
            if let p = node.point { line += "  ->  \(Int(p.x)) \(Int(p.y))" + (onScreen(p) ? "" : "  (offscreen)") }
            return line
        }
        guard !lines.isEmpty else { throw Fail(message: filter.isEmpty ? "no links on this page" : "no link matching: \(a.joined(separator: " "))") }
        return lines.count > 150 ? (lines.prefix(150) + ["… \(lines.count - 150) more — narrow it: links <text>"]).joined(separator: "\n")
                                 : lines.joined(separator: "\n")

    case "find":
        // find <kind> [text]: the browser's own index, by kind of element.
        let kinds = ["link": "AXLinkSearchKey", "button": "AXButtonSearchKey", "field": "AXTextFieldSearchKey",
                     "checkbox": "AXCheckBoxSearchKey", "radio": "AXRadioGroupSearchKey", "heading": "AXHeadingSearchKey",
                     "table": "AXTableSearchKey", "image": "AXGraphicSearchKey", "list": "AXListSearchKey",
                     "landmark": "AXLandmarkSearchKey", "frame": "AXFrameSearchKey", "control": "AXControlSearchKey",
                     "focusable": "AXKeyboardFocusableSearchKey", "any": "AXAnyTypeSearchKey"]
        guard let kind = a.first, let key = kinds[kind.lowercased().hasSuffix("s") ? String(kind.lowercased().dropLast()) : kind.lowercased()] else {
            throw Fail(message: "find needs a kind: \(kinds.keys.sorted().joined(separator: ", ")) — then optional text", code: 2)
        }
        let browser = try targetBrowser()
        let (_, web) = try browserPage(browser)
        let text = a.dropFirst().joined(separator: " ")
        let hits = webSearch(web, key, text: text.isEmpty ? nil : text, limit: 500)
        var nodes: [Node] = []
        for el in hits {
            var node = walk(el, maxDepth: 0, inWeb: true).nodes.first
                ?? Node(el: el, name: "", role: el.role, point: frame(el).map { CGPoint(x: $0.midX.rounded(), y: $0.midY.rounded()) },
                        disabled: false, inWeb: true)
            if node.name.isEmpty, key == "AXTableSearchKey" {
                node = Node(el: el, name: "table of \((el.attr(kAXRowsAttribute) as? [AXUIElement])?.count ?? 0) rows", role: node.role,
                            point: node.point, disabled: false, inWeb: true)
            }
            nodes.append(node)
        }
        let lines = numbered(nodes, limit: 150) { node in
            var l = line(node)
            if let v = node.value, !v.isEmpty { l += "  holds \"\(v)\"" }
            if node.role == "Link" { let url = axURL(node.el); if !url.isEmpty { l += "  — \(String(url.prefix(100)))" } }
            return l
        }
        guard !lines.isEmpty else { throw Fail(message: "no \(kind) on this page" + (text.isEmpty ? "" : " matching: \(text)")) }
        return lines.prefix(150).joined(separator: "\n")

    case "table":
        let browser = try targetBrowser()
        let (_, web) = try browserPage(browser)
        let n = a.isEmpty ? 1 : Int(try number(a[0], "table number"))
        let tables = webSearch(web, "AXTableSearchKey", limit: 50)
        guard let table = tables[safe: n - 1] else { throw Fail(message: "this page has \(tables.count) table\(tables.count == 1 ? "" : "s") — no table \(n)") }
        func cellText(_ e: AXUIElement, _ depth: Int) -> String {
            var parts: [String] = []
            for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                let t = flat(e.text(attr)); if !t.isEmpty { parts.append(t); break }
            }
            if parts.isEmpty, depth < 4 { parts = e.children.map { cellText($0, depth + 1) }.filter { !$0.isEmpty } }
            return parts.joined(separator: " ")
        }
        let rows = (table.attr(kAXRowsAttribute) as? [AXUIElement]) ?? []
        guard !rows.isEmpty else { throw Fail(message: "table \(n) exposes no rows") }
        let out = rows.prefix(200).map { row in row.children.map { String(cellText($0, 0).prefix(60)) }.joined(separator: " | ") }
        return (out + (rows.count > 200 ? ["… \(rows.count - 200) more rows"] : [])).joined(separator: "\n")

    case "js":
        guard let code = a.first else { throw Fail(message: "js needs code: js \"document.title\"", code: 2) }
        let browser = try targetBrowser()
        let result = try Scripting.call(browser, "js", ["", code])
        if let s = result as? String { return s }
        if result == nil || result is NSNull { return "(no value)" }
        if let data = try? JSONSerialization.data(withJSONObject: result!, options: [.fragmentsAllowed, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(result!)"

    case "source":
        let browser = try targetBrowser()
        guard family(browser) == .safari else {
            throw Fail(message: "only Safari hands over a page's source without running scripts — elsewhere: js \"document.documentElement.outerHTML\"")
        }
        let html = (try Scripting.call(browser, "source", [""]) as? String) ?? ""
        if let i = a.firstIndex(of: "--save"), let path = a[safe: i + 1] {
            let full = (path as NSString).expandingTildeInPath
            try html.write(toFile: full, atomically: true, encoding: .utf8)
            return "saved \(html.count) characters of HTML to \(full)"
        }
        let max = a.firstIndex(of: "--max").map { i in Int((try? number(a[safe: i + 1], "--max")) ?? 20000) } ?? 20000
        return html.count <= max ? html : String(html.prefix(max)) + "\n… \(html.count - max) more characters: source --save <file>"

    case "history", "bookmarks":
        let browser = try targetBrowser()
        if a.contains("--ui") {
            bringToFront(browser)
            return try acting {
                if cmd == "history" { try pressMenuCommand(browser, key: "y", what: "the history window") }
                else { try pressMenuCommand(browser, key: "b", modifiers: 2, what: "the bookmarks window") }
                return "opened \(browserName(browser))'s \(cmd)"
            }
        }
        var rest: [String] = []
        var days = 30.0, limit = 50
        var i = 0
        while i < a.count {
            if a[i] == "--days" { days = try number(a[safe: i + 1], "--days"); i += 2 }
            else if a[i] == "--limit" { limit = Int(try number(a[safe: i + 1], "--limit")); i += 2 }
            else { rest.append(a[i]); i += 1 }
        }
        let text = rest.joined(separator: " ")
        return cmd == "history" ? try historyReport(browser, text: text, days: days, limit: limit)
                                : try bookmarksReport(browser, text: text, limit: a.contains("--limit") ? limit : 150)

    case "bookmark":
        // Add the page showing in front, through the browser's own Add Bookmark
        // command (a script that adds one crashed Chromium).
        let browser = try targetBrowser()
        bringToFront(browser)
        let pageURL = currentURL(browser) ?? ""
        return try acting {
            try pressMenuCommand(browser, key: "d", what: "bookmarking this page")
            let fieldRoles: Set<String> = ["TextField", "ComboBox"]
            guard until(2, { fieldRoles.contains(focusedElement()?.role ?? "") }) else {
                return "asked \(browserName(browser)) to bookmark \(pageURL) — no name field took the focus; take a shot"
            }
            if let title = a.first {
                try hotkey("cmd", "a")
                paste(title)
            }
            pause(100)
            tap(36)
            return "bookmarked \(pageURL)"
        }

    case "downloads":
        let n = a.isEmpty ? 10 : Int(try number(a[0], "how many"))
        return try downloadsReport(try? targetBrowser(), count: n)

    case "settings":
        return try settingsReport(try targetBrowser(), search: a.joined(separator: " "))

    case "readinglist":
        let browser = try targetBrowser()
        guard family(browser) == .safari else { throw Fail(message: "the Reading List is Safari's") }
        let url = try a.first.map(normalizeURL) ?? (currentURL(browser) ?? "")
        guard !url.isEmpty else { throw Fail(message: "readinglist needs an address, or a page open in Safari") }
        _ = try Scripting.call(browser, "readinglist", [url])
        return "added to Safari's Reading List: \(url)"

    case "check", "doctor":
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
        // Browsers: may this terminal script them, do they run page scripts, are Safari's files readable.
        for b in runningBrowsers() where family(b) != .other {
            let name = browserName(b)
            let pad = name.padding(toLength: max(18, name.count + 2), withPad: " ", startingAt: 0)
            switch Int(automationStatus(b.bundleIdentifier ?? "")) {
            case Int(noErr):
                let js = (try? Scripting.call(b, "js", ["", "1"])) != nil ? "page scripts on (js works)"
                    : "page scripts off — only js needs them; everything else works"
                lines.append(pad + "scripting ok · " + js)
            case Int(errAEEventWouldRequireUserConsent):
                lines.append(pad + "scripting not allowed yet — the first tabs or go asks for permission on screen")
            case Int(errAEEventNotPermitted):
                lines.append(pad + "scripting DENIED — System Settings > Privacy & Security > Automation > your terminal > \(name)")
            default:
                break
            }
        }
        switch protected(home + "/Library/Safari/Bookmarks.plist") {
        case .some(true): lines.append("full disk access  off — Safari history and bookmarks are read from its own views (slower, no visit times); optional")
        case .some(false): lines.append("full disk access  ok — Safari history and bookmarks read from their files")
        case .none: break
        }
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
