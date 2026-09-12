// anybrowser — staying on the app being worked on.
//
// Lookups and actions go to the app in front, and the user shares the Mac: between
// two steps they may bring another app forward — most often the terminal the agent
// runs in, to type to it. A check, a click or a key meant for the browser would land
// there instead (it happened: a chain went on in the terminal, `fill` wrote into it and
// `expect` passed by reading the agent's own messages). So anybrowser remembers the
// app it works on, and before each lookup or action makes sure that is the one it
// is about to touch.

import AppKit

// MARK: - The app this command runs in

func parentPid(_ pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
    return info.kp_eproc.e_ppid
}

/// The terminal, editor or desktop app the agent runs in: the nearest ancestor
/// process that is an app with windows. Under tmux or screen the ancestors end at
/// launchd, but the app that started the session is still named in the environment.
/// ANYBROWSER_HOST names it outright ("none": no such app).
let hostApp: NSRunningApplication? = {
    let env = ProcessInfo.processInfo.environment
    if let want = env["ANYBROWSER_HOST"], !want.isEmpty {
        return NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && matches($0, want) }
    }
    var pid = getppid()
    for _ in 0..<64 where pid > 1 {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        pid = parentPid(pid)
    }
    if let bundle = env["__CFBundleIdentifier"] {
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle && $0.activationPolicy == .regular }
    }
    return nil
}()

func isHost(_ pid: pid_t) -> Bool { hostApp?.processIdentifier == pid }

// MARK: - The app being worked on

/// Kept between calls, since an agent sends one command per call.
struct WorkState: Codable {
    var pid: Int32 = 0
    var name = ""
    var at = 0.0          // when a command last worked on it
    var posted = 0.0      // when anybrowser last sent input: the system's idle clock counts it too
}

let statePath = tempDir + "anybrowser-front.json"
/// Half an hour without a command, and the app worked on is forgotten.
let workLife = 30.0 * 60

func loadState() -> WorkState {
    guard let data = FileManager.default.contents(atPath: statePath),
          let s = try? JSONDecoder().decode(WorkState.self, from: data) else { return WorkState() }
    return s
}

func saveState(_ s: WorkState) {
    if let data = try? JSONEncoder().encode(s) { FileManager.default.createFile(atPath: statePath, contents: data) }
}

func workApp() -> NSRunningApplication? {
    let s = loadState()
    guard s.pid > 0, now() - s.at < workLife,
          let app = NSRunningApplication(processIdentifier: s.pid), !app.isTerminated else { return nil }
    return app
}

/// While a lookup reads the app worked on from behind another one, "the app in front"
/// means that app for the rest of the command.
var readingApp: pid_t? = nil
/// Said before the command's own report: the app was read from behind, or brought back.
var frontNote: String? = nil

enum FrontUse { case read, act }

/// Before a command that reads or acts on the app in front. An @ref among `args`
/// names its own app.
///
/// - The app worked on is in front: go ahead.
/// - The terminal the agent runs in came forward (the user typing to it): a lookup
///   reads the app from behind; an action waits for the typing to stop and brings
///   the app back.
/// - Someone brought forward another app of theirs: a lookup still reads the app
///   worked on; an action stops, since either app could be the one meant.
/// - Nothing worked on yet: the app in front is the one meant — unless it's the terminal.
func keepFront(_ use: FrontUse, _ args: [String] = []) throws {
    guard AXIsProcessTrusted(), !screenLocked(), let front = focusedApp(timeout: 0.5)?.pid else { return }
    let work = workApp()?.processIdentifier
    let ref = args.first(where: isRef).flatMap(refPid).flatMap { NSRunningApplication(processIdentifier: $0) != nil ? $0 : nil }
    let host = isHost(front)
    guard let want = ref ?? work else {
        if host { throw Fail(message: hostMessage(front)) }
        return
    }
    if want == front { return }
    // A background agent's dialog (a password prompt, a permission request) is what needs answering.
    if !host, NSRunningApplication(processIdentifier: front)?.activationPolicy != .regular { return }
    let wanted = appName(want), other = appName(front)
    // The terminal is where the user talks to the agent; any other app they bring forward is their own work.
    let theirs = !host && front != work
    if use == .read {
        readingApp = want
        frontNote = theirs ? "(reading \(wanted), where the work is — \(other) is in front now: focus \(other) to read that instead)"
                           : "(reading \(wanted) — \(other) is in front)"
        return
    }
    if theirs {
        throw Fail(message: "\(other) is in front now, not \(wanted) where anybrowser was working — someone brought it forward, so nothing was done. "
            + "To go on in \(wanted): focus \(wanted) · to work in \(other): focus \(other)")
    }
    let waited = host ? try waitForTyping(in: other, then: wanted) : 0
    guard bringBack(want) else { throw Fail(message: "\(wanted) didn't come back to the front — nothing was done; focus \(wanted)") }
    frontNote = waited >= 1 ? "(waited \(Int(waited)) s for the typing in \(other) to stop, then brought \(wanted) back to the front)"
                            : "(brought \(wanted) back to the front — \(other) had taken it)"
}

func hostMessage(_ front: pid_t) -> String {
    let host = appName(front)
    let next = appBelow(front).map { "focus \($0)" } ?? "focus <app>"
    return "\(host) is in front — the app this command runs in — so nothing was done there. Bring forward the app to work on: "
        + "\(next) · go <address> · menu <app> <menu> <item>  (to work in \(host) itself: focus \(host))"
}

/// The app with the highest window after `pid`'s: usually the one meant.
func appBelow(_ pid: pid_t) -> String? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
              let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular else { continue }
        return app.localizedName
    }
    return nil
}

/// Bringing the work forward mid-sentence would send the user's next keys into it:
/// wait until nobody has pressed a key or a button for a few seconds.
func waitForTyping(in app: String, then wanted: String) throws -> Double {
    let started = now()
    // The system's idle clock counts anybrowser's own input too: that isn't the user.
    let ours = max(loadState().posted, lastPostedAt)
    let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    while true {
        let ago = kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        if ago >= 3 || now() - ago <= ours + 0.3 { return now() - started }
        if now() - started > 45 {
            throw Fail(message: "someone kept typing in \(app) for 45 s — nothing was done, so none of their keys lands in \(wanted); try again in a moment")
        }
        pause(200)
    }
}

func bringBack(_ pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    let inFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    app.unhide()
    app.activate(options: [])
    if !until(1.5, inFront) {
        // An app can turn down a request from the background; Launch Services' reopen it takes.
        guard let url = app.bundleURL else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", url.path]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        if !until(2, inFront) { return false }
    }
    pause(120)                                          // its window becomes key a beat after the app
    return true
}

// MARK: - After a command

let lookups: Set<String> = ["where", "waitfor", "waitgone", "expect", "ui", "read"]
let frontActions: Set<String> = ["click", "dclick", "rclick", "press", "select", "fill", "type", "keys", "key", "hotkey",
                                 "upload", "hover", "drag", "scroll", "window", "open"]
let naming: Set<String> = ["focus", "menu", "raise"]
let browserMoves: Set<String> = ["go", "back", "forward", "reload", "tab", "private", "bookmark", "settings", "history", "bookmarks"]

/// A command that worked on an app makes the app in front the one worked on — an
/// action may have changed it (a link that opened Finder), and the report said so.
func rememberFront(_ cmd: String, _ a: [String]) {
    let shotOfFront = cmd == "shot" && (a.contains("--window") || a.contains("--element"))
    guard naming.contains(cmd) || lookups.contains(cmd) || frontActions.contains(cmd) || browserMoves.contains(cmd) || shotOfFront else {
        if postedEvents { notePosted() }
        return
    }
    var s = loadState()
    if readingApp == nil, let front = focusedApp(timeout: 0.3)?.pid, let app = NSRunningApplication(processIdentifier: front) {
        let counts = naming.contains(cmd)                                 // named outright: even the terminal
            || (browserMoves.contains(cmd) ? isBrowser(app) : app.activationPolicy == .regular && !isHost(front))
        if counts { s.pid = front; s.name = app.localizedName ?? "" }
    }
    if s.pid > 0 { s.at = now() }
    if postedEvents { s.posted = lastPostedAt }
    saveState(s)
}

func frontName() -> String { focusedApp(timeout: 0.5).map { appName($0.pid) } ?? "the app in front" }

func notePosted() {
    var s = loadState()
    s.posted = lastPostedAt
    saveState(s)
}

func workReport() -> [String] {
    var lines: [String] = []
    if let host = hostApp {
        lines.append("runs in           \(host.localizedName ?? "?") — never acted on unless you focus it")
    } else {
        lines.append("runs in           no app found — under tmux or ssh, name your terminal: ANYBROWSER_HOST=Terminal")
    }
    if let app = workApp() {
        let mins = Int((now() - loadState().at) / 60)
        lines.append("working in        \(app.localizedName ?? "?") (last command \(mins == 0 ? "under a minute" : "\(mins) min") ago)")
    } else {
        lines.append("working in        nothing yet — focus, menu, go or an action sets it")
    }
    return lines
}
