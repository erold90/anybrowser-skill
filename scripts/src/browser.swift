// anybrowser — the browser layer: tabs, navigation, page text and links, history,
// bookmarks, downloads and settings, with no extension and no debugging port.
//
// Each thing comes from wherever a browser answers fastest and most exactly:
// tabs and URLs from its scripting dictionary (Apple Events, in-process), history
// and bookmarks from the files it keeps them in, the page itself from the
// accessibility tree — including the search index VoiceOver's rotor uses, which
// finds an element on a heavy page in milliseconds instead of a walk of seconds.

import AppKit
import ApplicationServices
import OSAKit
import SQLite3

// MARK: - Which browser

let browserBundles = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
                      "org.mozilla.nightly", "app.zen-browser.zen", "com.kagi.kagimacOS"] + chromium

enum Family { case safari, chromium, other }

func family(_ app: NSRunningApplication) -> Family {
    let bundle = app.bundleIdentifier ?? ""
    if bundle.hasPrefix("com.apple.Safari") { return .safari }
    if chromium.contains(where: { bundle.hasPrefix($0) }) { return .chromium }
    return .other
}

func isBrowser(_ app: NSRunningApplication) -> Bool {
    let bundle = app.bundleIdentifier ?? ""
    return app.activationPolicy == .regular && browserBundles.contains { bundle.hasPrefix($0) }
}

/// Set by `use <browser>` (inside a `do`) or ANYBROWSER_BROWSER.
var chosenBrowser: String? = ProcessInfo.processInfo.environment["ANYBROWSER_BROWSER"].flatMap { $0.isEmpty ? nil : $0 }

/// Running browsers: the app in front first, then by how high their windows sit.
func runningBrowsers() -> [NSRunningApplication] {
    CFRunLoopRunInMode(.defaultMode, 0, true)
    let apps = NSWorkspace.shared.runningApplications.filter(isBrowser)
    var order: [pid_t] = []
    if let front = NSWorkspace.shared.frontmostApplication { order.append(front.processIdentifier) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let pid = w[kCGWindowOwnerPID as String] as? pid_t, !order.contains(pid) { order.append(pid) }
    }
    func place(_ a: NSRunningApplication) -> Int { order.firstIndex(of: a.processIdentifier) ?? Int.max }
    return apps.sorted { place($0) < place($1) }
}

/// "chrome" is Google Chrome, "edge" Microsoft Edge: a browser answers to part of its name.
func browserNamed(_ want: String) -> NSRunningApplication? {
    let w = want.lowercased()
    let running = NSWorkspace.shared.runningApplications.filter(isBrowser)
    return running.first { matches($0, want) } ?? running.first { ($0.localizedName ?? "").lowercased().contains(w) }
}

/// The browser the browser commands mean: the chosen one, else the one in front
/// or nearest the top.
func targetBrowser() throws -> NSRunningApplication {
    if let want = chosenBrowser, !want.isEmpty {
        guard let app = browserNamed(want) else { throw Fail(message: "\(want) isn't running — start it with: focus \(want)") }
        try refuseGecko(app.processIdentifier)
        return app
    }
    // The browser in front, or nearest the top — but never Firefox, which can't be driven.
    guard let first = runningBrowsers().first(where: { !isGecko($0.processIdentifier) }) else {
        if runningBrowsers().contains(where: { isGecko($0.processIdentifier) }) {
            throw Fail(message: "only Firefox is running, which anybrowser can't drive — start Safari or a Chromium browser (Chrome, Brave, Edge)")
        }
        throw Fail(message: "no browser is running — start one with: focus Safari")
    }
    return first
}

func browserName(_ app: NSRunningApplication) -> String { app.localizedName ?? app.bundleIdentifier ?? "the browser" }

// MARK: - Scripting (Apple Events through JavaScript for Automation, in-process)

/// Every value reaches the script as an argument, never pasted into its source.
let browserScript = #"""
function run(argv) {
  const op = argv[0], app = Application(argv[1]), safari = argv[2] === "safari", p = argv.slice(3);
  function windows() {
    const out = [];
    for (const w of app.windows()) { try { if (w.tabs.length > 0) out.push(w); } catch (e) {} }
    return out;
  }
  function win(id) {
    const all = windows();
    if (!all.length) throw new Error("no-window");
    if (!id) return all[0];
    for (const w of all) if (String(w.id()) === id) return w;
    throw new Error("window-gone");
  }
  const tab = w => safari ? w.currentTab : w.activeTab;
  const minimized = w => { try { return safari ? w.miniaturized() : w.minimized(); } catch (e) { return false; } };
  switch (op) {
    case "tabs":
      return JSON.stringify(windows().map(w => {
        let active = 0, mode = "";
        try { active = safari ? w.currentTab.index() : w.activeTabIndex(); } catch (e) {}
        try { if (!safari) mode = w.mode(); } catch (e) {}
        return { id: String(w.id()), active, mode, minimized: minimized(w),
                 titles: safari ? w.tabs.name() : w.tabs.title(), urls: w.tabs.url() };
      }));
    case "select": {
      const w = win(p[0]), i = Number(p[1]);
      if (minimized(w)) { if (safari) w.miniaturized = false; else w.minimized = false; }
      if (safari) w.currentTab = w.tabs[i - 1]; else w.activeTabIndex = i;
      w.index = 1;
      return "true";
    }
    case "new": {
      const url = p[0] || "";
      if (p[1] === "private") {
        const w = app.Window({ mode: "incognito" }).make();
        if (url) w.activeTab.url = url;
        return "true";
      }
      const all = windows();
      if (!all.length || p[1] === "window") {
        if (safari) app.Document().make(); else app.Window().make();
        if (url) tab(windows()[0]).url = url;
        return "true";
      }
      const w = all[0];
      w.tabs.push(url ? app.Tab({ url }) : app.Tab());
      if (safari) w.currentTab = w.tabs[w.tabs.length - 1];
      return "true";
    }
    case "close":
      win(p[0]).tabs[Number(p[1]) - 1].close();
      return "true";
    case "go": {
      const t = tab(win(p[0])), was = t.url();
      t.url = p[1];
      return JSON.stringify(was);
    }
    case "reload": {
      const t = tab(win(p[0])), was = t.url();
      if (safari) t.url = was; else t.reload();
      return JSON.stringify(was);
    }
    case "back": case "forward": {
      const t = tab(win(p[0])), was = t.url();
      if (op === "back") t.goBack(); else t.goForward();
      return JSON.stringify(was);
    }
    case "js": {
      const w = win(p[0]);
      const r = safari ? app.doJavaScript(p[1], { in: w.currentTab }) : app.execute(w.activeTab, { javascript: p[1] });
      return JSON.stringify(r === undefined ? null : r);
    }
    case "source":
      return JSON.stringify(win(p[0]).currentTab.source());
    case "readinglist":
      app.addReadingListItem(p[0]);
      return "true";
  }
  throw new Error("unknown operation " + op);
}
"""#

enum Scripting {
    static var compiled: OSAScript? = nil
    static var busy = false

    /// Run one operation of the browser script against a running browser.
    static func call(_ browser: NSRunningApplication, _ op: String, _ params: [String] = []) throws -> Any? {
        let name = browserName(browser)
        guard family(browser) != .other else {
            throw Fail(message: "\(name) takes no scripts — its pages still work with click, fill, read, where and text")
        }
        // Addressing a browser that has quit would launch it again.
        guard !browser.isTerminated else { throw Fail(message: "\(name) isn't running") }
        if compiled == nil {
            guard let language = OSALanguage(forName: "JavaScript") else { throw Fail(message: "JavaScript for Automation is missing on this Mac") }
            let script = OSAScript(source: browserScript, language: language)
            var error: NSDictionary?
            guard script.compileAndReturnError(&error) else { throw Fail(message: "internal: the browser script didn't compile: \(error ?? [:])") }
            compiled = script
            // A browser stuck on a dialog doesn't answer, and an Apple Event waits two
            // minutes by default. Give up long before that.
            DispatchQueue.global().async {
                while true {
                    sleep(1)
                    if busy && now() - callStarted > 20 {
                        warn("the browser didn't answer in 20 s — a dialog open in it, or a permission prompt waiting? take a shot")
                        exit(1)
                    }
                }
            }
        }
        let args = [op, browser.bundleIdentifier ?? "", family(browser) == .safari ? "safari" : "chromium"] + params
        var error: NSDictionary?
        busy = true
        callStarted = now()
        let result = compiled!.executeHandler(withName: "run", arguments: [args], error: &error)
        busy = false
        guard let result = result else { throw scriptFailure(error, browser, op) }
        guard let text = result.stringValue, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static var callStarted = 0.0
}

func scriptFailure(_ error: NSDictionary?, _ browser: NSRunningApplication, _ op: String) -> Fail {
    let number = (error?[OSAScriptErrorNumberKey] as? NSNumber)?.intValue ?? 0
    let message = ((error?[OSAScriptErrorMessageKey] as? String) ?? "").replacingOccurrences(of: "Error: ", with: "")
    let name = browserName(browser)
    switch number {
    case -1743:
        return Fail(message: "\(name) refuses to be controlled by this terminal — System Settings > Privacy & Security > Automation > (your terminal app) > turn on \(name)")
    case -1744:
        return Fail(message: "macOS is asking whether this terminal may control \(name) — answer the prompt on screen, then run it again")
    case -1712:
        return Fail(message: "\(name) didn't answer in time — is a dialog open in it? take a shot")
    case -600, -609:
        return Fail(message: "\(name) isn't running")
    default: break
    }
    if message.contains("no-window") { return Fail(message: "\(name) has no window open — tab new <url> opens one") }
    if message.contains("window-gone") { return Fail(message: "that window of \(name) has closed — run tabs again") }
    if op == "js" && message.contains("JavaScript") {
        if family(browser) == .safari {
            return Fail(message: """
                Safari runs scripts in pages only with "Allow JavaScript from Apple Events" on: Safari > Settings > Advanced > \
                "Show features for web developers", then Develop > Allow JavaScript from Apple Events. It lets any app allowed \
                to control Safari run code in your signed-in pages — ask the user before turning it on. Without it: text, links, read, where.
                """)
        }
        return Fail(message: """
            \(name) runs scripts in pages only with View > Developer > Allow JavaScript from Apple Events on. It lets any app \
            allowed to control \(name) run code in your signed-in pages — ask the user before turning it on. Without it: text, links, read, where.
            """)
    }
    return Fail(message: "\(name): \(message.isEmpty ? "script error" : message) (\(number))")
}

/// Can this process send Apple Events to the browser? Asks nobody.
func automationStatus(_ bundle: String) -> OSStatus {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
    guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
    return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
}

// MARK: - The page, through accessibility

/// The page in a browser window: the first web area under it, looking only through
/// the groups that can hold one — toolbars, tab strips and sidebars are skipped.
func webArea(in window: AXUIElement) -> AXUIElement? {
    let pass: Set<String> = ["AXGroup", "AXSplitGroup", "AXTabGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown"]
    var queue = [window]
    var i = 0
    while i < queue.count && i < 400 {
        let e = queue[i]
        i += 1
        AXUIElementSetMessagingTimeout(e, 0.5)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, [kAXRoleAttribute, kAXChildrenAttribute] as CFArray,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let v = raw as [AnyObject]?, v.count == 2 else { continue }
        let role = (v[0] as? String) ?? ""
        if role == "AXWebArea" { return e }
        if i == 1 || pass.contains(role), let kids = v[1] as? [AXUIElement] { queue += kids }
    }
    return nil
}

/// Chromium builds a page's tree only when an assistive app asks: browsers listen
/// for the attribute VoiceOver sets, Electron apps for AXManualAccessibility. Chrome
/// answers the first with an error and obeys anyway, ~2 s later; asking again
/// before then restarts the wait, so a marker per process remembers the ask.
/// True when it has just asked and the page needs a moment.
@discardableResult
func wakeWebTree(_ app: AXUIElement, pid: pid_t) -> Bool {
    let running = NSRunningApplication(processIdentifier: pid)
    let bundle = running?.bundleIdentifier ?? ""
    let frameworks = running?.bundleURL?.appendingPathComponent("Contents/Frameworks").path ?? ""
    let electron = FileManager.default.fileExists(atPath: frameworks + "/Electron Framework.framework")
        || FileManager.default.fileExists(atPath: frameworks + "/Chromium Embedded Framework.framework")
    guard electron || chromium.contains(where: { bundle.hasPrefix($0) }) else { return false }
    let marker = tempDir + "anybrowser-web-\(pid)"
    let age = (try? FileManager.default.attributesOfItem(atPath: marker)[.modificationDate] as? Date)
        .flatMap { $0 }.map { -$0.timeIntervalSinceNow } ?? .infinity
    guard age > 120 else { return false }
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    if electron { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
    FileManager.default.createFile(atPath: marker, contents: nil)
    return true
}

/// Gecko browsers (Firefox and its kin). anybrowser can't drive them: no scripting dictionary for
/// tabs and addresses, and their accessibility engine, once woken, stalls reading the page (a plain
/// `read` on a Firefox window hung for minutes, 12/9). Recognised only so the tool says so and stops,
/// instead of hanging. Use Safari or a Chromium browser (Chrome, Brave, Edge).
let geckoBundles = ["org.mozilla.firefox", "org.mozilla.nightly", "org.mozilla.firefoxdeveloperedition",
                    "app.zen-browser.zen", "org.torproject.torbrowser"]

func isGecko(_ pid: pid_t) -> Bool {
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    return geckoBundles.contains { bundle.hasPrefix($0) }
}

func refuseGecko(_ pid: pid_t) throws {
    if isGecko(pid) {
        throw Fail(message: "\(appName(pid)) can't be driven — Firefox has no scripting for tabs and addresses, and "
            + "its accessibility stalls reading the page. Use Safari, or a Chromium browser (Chrome, Brave, Edge).")
    }
}

/// The browser's front window — it needn't be the app in front.
func browserWindow(_ browser: NSRunningApplication) throws -> (app: AXUIElement, window: AXUIElement) {
    try requireTrust("reading the page")
    try refuseGecko(browser.processIdentifier)
    let app = AXUIElementCreateApplication(browser.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) ?? realWindows(app).first else {
        throw Fail(message: "\(browserName(browser)) has no window open — tab new <url> opens one")
    }
    return (app, win)
}

/// The page showing in the browser's front window, woken first if it's Chromium.
func browserPage(_ browser: NSRunningApplication) throws -> (window: AXUIElement, web: AXUIElement) {
    let (app, win) = try browserWindow(browser)
    if let web = webArea(in: win) { return (win, web) }
    if wakeWebTree(app, pid: browser.processIdentifier) {
        let deadline = now() + 6
        while now() < deadline {
            pause(150)
            if let web = webArea(in: win) { return (win, web) }
        }
    }
    throw Fail(message: "no web page in the front window of \(browserName(browser)) — a start page, an empty tab or a settings window")
}

func axURL(_ e: AXUIElement) -> String {
    guard let v = e.attr("AXURL") else { return "" }
    if let u = v as? URL { return u.absoluteString }
    return (v as? String) ?? ""
}

/// The element under a window with this accessibility identifier (or identifier
/// prefix, for Safari's "BrowserView?IsPageLoaded=…"), not looking inside pages.
func identified(_ root: AXUIElement, _ id: String, depth: Int = 8) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var i = 0
    while i < queue.count && i < 600 {
        let (e, d) = queue[i]
        i += 1
        AXUIElementSetMessagingTimeout(e, 0.5)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, [kAXIdentifierAttribute, kAXRoleAttribute, kAXChildrenAttribute] as CFArray,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let v = raw as [AnyObject]?, v.count == 3 else { continue }
        if let ident = v[0] as? String, ident == id || ident.hasPrefix(id + "?") { return e }
        if (v[1] as? String) == "AXWebArea" || d >= depth { continue }
        for k in (v[2] as? [AXUIElement]) ?? [] { queue.append((k, d + 1)) }
    }
    return nil
}

/// A page's title as the page gives it (a Chrome window's title adds the profile and group).
func pageTitle(_ web: AXUIElement, _ window: AXUIElement) -> String {
    for a in [kAXTitleAttribute, kAXDescriptionAttribute] { let t = web.text(a); if !t.isEmpty { return t } }
    return window.text(kAXTitleAttribute)
}

/// All of a page's text in one call, through the text markers screen readers use
/// (a few ms, where a walk over the elements takes up to seconds).
func pageText(_ web: AXUIElement) -> String? {
    AXUIElementSetMessagingTimeout(web, 3)
    guard let start = web.attr("AXStartTextMarker"), let end = web.attr("AXEndTextMarker") else { return nil }
    var range: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(web, "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                                                     [start, end] as CFArray, &range) == .success, let r = range else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(web, "AXStringForTextMarkerRange" as CFString, r, &out) == .success else { return nil }
    return out as? String
}

/// A page's text line by line, as laid out. Chromium hands the whole text over
/// without the breaks between blocks ("NameEmail"); walking it a line at a time
/// keeps them. Stops past `limit` characters.
func pageLines(_ web: AXUIElement, limit: Int, within element: AXUIElement? = nil) -> String? {
    AXUIElementSetMessagingTimeout(web, 2)
    func param(_ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(web, name as CFString, arg, &out) == .success ? out : nil
    }
    guard var marker = (element ?? web).attr("AXStartTextMarker") else { return nil }
    // Where the element's text ends, as an index into the page's text.
    let endIndex = element.flatMap { $0.attr("AXEndTextMarker") }.flatMap { param("AXIndexForTextMarker", $0) as? NSNumber }?.intValue
    var lines: [String] = []
    var total = 0
    for _ in 0..<50_000 {
        guard let range = param("AXLineTextMarkerRangeForTextMarker", marker) else { break }
        let text = (param("AXStringForTextMarkerRange", range) as? String) ?? ""
        lines.append(text)
        total += text.count + 1
        if total > limit { break }
        guard let end = param("AXNextLineEndTextMarkerForTextMarker", marker),
              let next = param("AXNextTextMarkerForTextMarker", end), !CFEqual(next, marker) else { break }
        if let e = endIndex, let i = param("AXIndexForTextMarker", next) as? NSNumber, i.intValue >= e { break }
        marker = next
    }
    return lines.joined(separator: "\n")
}

/// The page's main content — its <main> landmark, else its first <article> — so
/// reading an article skips menus, contents lists and footers.
func mainContent(_ web: AXUIElement) -> AXUIElement? {
    if let main = webSearch(web, "AXLandmarkSearchKey", limit: 40).first(where: { $0.text(kAXSubroleAttribute) == "AXLandmarkMain" }) {
        return main
    }
    // Only a real <article>: a browser that doesn't know the search key answers with anything.
    return webSearch(web, "AXArticleSearchKey", limit: 3).first { $0.text(kAXSubroleAttribute) == "AXDocumentArticle" }
}

/// The text of one element of the page: the text-marker range the element covers.
func elementText(_ web: AXUIElement, _ element: AXUIElement) -> String? {
    var range: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(web, "AXTextMarkerRangeForUIElement" as CFString, element, &range) == .success,
          let r = range else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(web, "AXStringForTextMarkerRange" as CFString, r, &out) == .success else { return nil }
    return out as? String
}

/// Blank runs squeezed, object placeholders (images, controls) dropped.
func tidyText(_ text: String) -> String {
    var out: [String] = []
    for raw in text.replacingOccurrences(of: "\u{FFFC}", with: " ").components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { if let last = out.last, !last.isEmpty { out.append("") } }
        else { out.append(flat(line)) }
    }
    return joinPriceFragments(out).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A price laid out in pieces — "€", "19", ",", "99" on lines of their own (Ryanair in
/// Safari) — reads as one: "€ 19,99".
func joinPriceFragments(_ lines: [String]) -> [String] {
    let currency: Set<String> = ["€", "$", "£", "¥", "CHF", "EUR", "USD", "GBP"]
    var out: [String] = []
    for line in lines {
        guard !line.isEmpty, let i = out.lastIndex(where: { !$0.isEmpty }), out.count - 1 - i <= 1 else { out.append(line); continue }
        let last = out[i]
        let digits = line.allSatisfy { $0.isNumber }
        var glued: String? = nil
        if currency.contains(last) && line.first?.isNumber == true { glued = last + " " + line }
        else if (line == "," || line == ".") && last.last?.isNumber == true { glued = last + line }
        else if digits && (last.hasSuffix(",") || last.hasSuffix(".")) && last.dropLast().last?.isNumber == true { glued = last + line }
        if let g = glued {
            out.removeSubrange((i + 1)...)
            out[i] = g
        } else {
            out.append(line)
        }
    }
    return out
}

/// The browser's own element search, by kind and text: AXLinkSearchKey,
/// AXButtonSearchKey, AXTextFieldSearchKey, AXHeadingSearchKey, AXAnyTypeSearchKey…
func webSearch(_ web: AXUIElement, _ key: String, text: String? = nil, limit: Int = 500) -> [AXUIElement] {
    var predicate: [String: Any] = ["AXSearchKey": key, "AXResultsLimit": limit, "AXDirection": "AXDirectionNext", "AXVisibleOnly": false]
    if let t = text, !t.isEmpty { predicate["AXSearchText"] = t }
    AXUIElementSetMessagingTimeout(web, 2)
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString,
                                                     predicate as CFDictionary, &out) == .success else { return [] }
    return (out as? [AXUIElement]) ?? []
}

/// Is this element inside an alert or a dialog drawn over the page?
func insideDialog(_ element: AXUIElement) -> Bool {
    var e: AXUIElement? = element
    for _ in 0..<4 {
        guard let cur = e else { break }
        let sub = cur.text(kAXSubroleAttribute)
        if cur.role == "Sheet" || cur.role == "Dialog" || sub.contains("Dialog") || sub.contains("Alert") { return true }
        e = cur.element(kAXParentAttribute)
    }
    return false
}

/// The fast way to find an element by name on a web page in front: ask the
/// browser's search index instead of walking the tree. Only a confident answer
/// counts — the exact name, or the text as its whole first word; anything vaguer,
/// or a dialog over the page, goes to the full walk, which also sees the browser's
/// own buttons.
func webPick(_ needle: String, _ usable: (Node) -> Bool) -> Node? {
    guard let app = focusedApp(timeout: 1), isWebApp(app.pid),
          let win = app.element(kAXFocusedWindowAttribute) else { return nil }
    if win.children.contains(where: { $0.role == "Sheet" }) { return nil }
    if let f = app.element(kAXFocusedUIElementAttribute), insideDialog(f) { return nil }
    guard let web = webArea(in: win) else { return nil }
    let hits = webSearch(web, "AXAnyTypeSearchKey", text: needle, limit: 250)
    debug("webPick: \(hits.count) hits for \(needle)")
    let nodes = hits.compactMap { walk($0, maxDepth: 0, inWeb: true).nodes.first }.filter(usable)
    guard let best = rank(nodes, needle).first, let s = score(best.name, needle), s <= 1 else { return nil }
    return best
}

/// The page showing before an action, to tell when it has been left.
struct PageMark { let web: AXUIElement?; let url: String?; var loaded: Bool? = nil; var window: AXUIElement? = nil }

func pageMark(_ browser: NSRunningApplication) -> PageMark { pageMark(pid: browser.processIdentifier) }

func pageMark(pid: pid_t) -> PageMark {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute), let web = webArea(in: win) else {
        return PageMark(web: nil, url: nil)
    }
    return PageMark(web: web, url: axURL(web), loaded: web.attr("AXLoaded") as? Bool, window: win)
}

/// Chromium's page elements carry a node id of their own; WebKit's don't.
func isChromiumWeb(_ web: AXUIElement) -> Bool { web.attr("ChromeAXNodeId") != nil }

/// Safari says a page is loading on its web view's identifier
/// ("BrowserView?IsPageLoaded=false…") from the moment a navigation starts — the
/// page itself keeps saying "loaded" until the new one commits, a second or more later.
func safariLoading(_ window: AXUIElement) -> Bool {
    identified(window, "BrowserView", depth: 5)?.text(kAXIdentifierAttribute).contains("IsPageLoaded=false") ?? false
}

/// Has the page in front started to change since `mark`: Safari loading, the page
/// torn down or replaced (Chromium), another address, or loading under way?
func navigationStarted(pid: pid_t, since mark: PageMark) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let win = app.element(kAXFocusedWindowAttribute) else { return false }
    // Another window in front — a file dialog, an alert, a new window — isn't the page navigating.
    if let w = mark.window, !CFEqual(w, win) { return false }
    if safariLoading(win) { return true }
    // No page at all: Chromium tears the old one down while navigating; Safari
    // simply shows one of its own views (bookmarks, history, start page) instead.
    guard let web = webArea(in: win) else { return mark.web.map(isChromiumWeb) ?? false }
    if let m = mark.web, !CFEqual(m, web) { return true }
    if let u = mark.url, axURL(web) != u { return true }
    // A page that never finishes loading (a stream, a long poll) isn't a navigation.
    return (web.attr("AXLoaded") as? Bool) == false && mark.loaded != false
}

/// Moved on without leaving: the same document under a new address — a #fragment, a
/// single-page app's pushState (Gmail, GitHub, Google Voli). Nothing loads.
func sameDocument(pid: pid_t, since mark: PageMark) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let m = mark.web, let win = app.element(kAXFocusedWindowAttribute), let web = webArea(in: win) else { return false }
    return CFEqual(m, web) && !safariLoading(win) && (web.attr("AXLoaded") as? Bool) != false
}

/// New content arriving after an in-place move: wait until the page's text holds still.
func settleText(_ seconds: Double = 3) {
    var last = pageState()?.text ?? ""
    var still = now()
    let deadline = now() + seconds
    while now() < deadline {
        pause(120)
        let text = pageState()?.text ?? ""
        if text != last { last = text; still = now() } else if now() - still >= 0.4 { break }
    }
}

/// Wait for the page in the browser's front window to finish loading. With a mark
/// taken before the action, first for that page to be left: its address changes,
/// its web area is replaced (a reload builds a new one), or loading visibly starts.
/// `scripted` is the address the script saw, for when accessibility had no page yet.
func waitLoad(_ browser: NSRunningApplication, from mark: PageMark?, scripted: String? = nil, seconds: Double,
              opening: Bool = false, stopOnDialog: Bool = false) -> (done: Bool, url: String, title: String) {
    let pid = browser.processIdentifier
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    let start = now()
    var left = mark == nil
    var url = "", title = ""
    var woke = false
    let markTitle = mark.flatMap { m in m.web.flatMap { w in m.window.map { pageTitle(w, $0) } } }
    while now() - start < seconds {
        // A click that starts a download shows a permission dialog instead of loading a page.
        if stopOnDialog, let win = app.element(kAXFocusedWindowAttribute), looksLikeDialog(win, kind: "") {
            return (false, "__dialog__", "")
        }
        if let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) {
            if !woke { woke = true; wakeWebTree(app, pid: pid) }
            let pending = safariLoading(win)
            if let web = webArea(in: win) {
                url = axURL(web)
                title = pageTitle(web, win)
                // A page without a <title> is named by its address, and the window keeps the old one a moment.
                if let old = mark?.url ?? scripted, title == old, url != old { title = url }
                let loaded = (web.attr("AXLoaded") as? Bool) ?? true
                let busy = (web.attr("AXElementBusy") as? Bool) ?? false
                if !left, let m = mark {
                    if let before = m.url ?? scripted, !url.isEmpty, url != before { left = true }
                    else if let w = m.web, !CFEqual(w, web) { left = true }
                    else if pending { left = true }
                    else if !loaded || now() - start > 1.5 { left = true }
                }
                // Safari's own flag first: until it clears, the page shown may still be the old one.
                // A tab asked to open an address shows the new-tab page first: that isn't the page wanted.
                if left && !pending && loaded && !busy && !url.isEmpty && !(opening && blankPage(url)) {
                    // A single-page app changes its address before its title: give the title a moment.
                    if let m = mark?.web, CFEqual(m, web), let old = markTitle, title == old {
                        _ = until(1) { pageTitle(web, win) != old }
                        title = pageTitle(web, win)
                    }
                    return (true, url, title)
                }
            }
        }
        pause(30)
    }
    return (false, url, title)
}

func seconds(_ since: Double) -> String { String(format: "%.1f s", now() - since) }

/// A browser's own empty page, shown while an address is on its way.
func blankPage(_ url: String) -> Bool {
    let u = url.lowercased()
    return u.isEmpty || u == "about:blank" || u.hasPrefix("chrome://new") || u.hasPrefix("edge://newtab") || u.hasPrefix("brave://newtab")
        || u.hasPrefix("favorites://") || u.hasPrefix("safari-resource:")
}

// MARK: - Menu commands by shortcut

/// A menu command found by its keyboard shortcut instead of its title, which
/// changes with the language: ⌘, is Settings in every language. `modifiers` as
/// accessibility counts them: 0 ⌘ alone, 1 +shift, 2 +option, 4 +control.
func menuCommand(_ pid: pid_t, key: String, modifiers: Int = 0) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let bar = app.element(kAXMenuBarAttribute) else { return nil }
    for top in bar.children.dropFirst() {                    // the Apple menu has none of these
        for item in menuItems(top) {
            if item.text("AXMenuItemCmdChar").lowercased() == key.lowercased(),
               ((item.attr("AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0) == modifiers {
                return item
            }
        }
    }
    // The app menu (Settings…) sits first after the Apple menu, and is included above.
    return nil
}

func pressMenuCommand(_ browser: NSRunningApplication, key: String, modifiers: Int = 0, what: String, trustEnabled: Bool = true) throws {
    guard let item = menuCommand(browser.processIdentifier, key: key, modifiers: modifiers) else {
        throw Fail(message: "\(browserName(browser)) has no menu command for \(what)")
    }
    // A closed menu's enabled state can be stale (Safari greys Forward until the
    // menu is next shown): for those, press anyway and judge by the result.
    if trustEnabled, (item.attr(kAXEnabledAttribute) as? Bool) == false {
        throw Fail(message: "\(what) isn't available in \(browserName(browser)) right now (\"\(item.text(kAXTitleAttribute))\" is disabled)")
    }
    item.perform(kAXPressAction, timeout: 0.5)
}

func bringToFront(_ browser: NSRunningApplication) {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier { return }
    try? waitIfTyping(for: browser.processIdentifier)
    browser.activate(options: [])
    _ = until(1.5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier }
}

// MARK: - Tabs

struct TabInfo { let window: String; let windowIndex: Int; let index: Int; let title: String; let url: String; let active: Bool; let mode: String }

func tabList(_ browser: NSRunningApplication) throws -> [TabInfo] {
    try refuseGecko(browser.processIdentifier)
    if family(browser) == .other {
        // No scripting: the tab bar of each window, titles only.
        let app = AXUIElementCreateApplication(browser.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        var out: [TabInfo] = []
        for (wi, w) in realWindows(app).enumerated() {
            let tabs = tabBar(w)
            if tabs.isEmpty {
                out.append(TabInfo(window: "\(wi + 1)", windowIndex: wi + 1, index: 1, title: w.text(kAXTitleAttribute), url: "", active: true, mode: ""))
            }
            for (ti, t) in tabs.enumerated() {
                out.append(TabInfo(window: "\(wi + 1)", windowIndex: wi + 1, index: ti + 1, title: t.title, url: "", active: t.selected, mode: ""))
            }
        }
        return out
    }
    guard let windows = try Scripting.call(browser, "tabs") as? [[String: Any]] else { return [] }
    var out: [TabInfo] = []
    for (wi, w) in windows.enumerated() {
        let titles = (w["titles"] as? [Any]) ?? [], urls = (w["urls"] as? [Any]) ?? []
        let active = (w["active"] as? Int) ?? 0
        var mode = (w["mode"] as? String) ?? ""
        if mode == "normal" { mode = "" }
        if (w["minimized"] as? Bool) == true { mode = mode.isEmpty ? "minimized" : mode + ", minimized" }
        for i in 0..<titles.count {
            out.append(TabInfo(window: (w["id"] as? String) ?? "", windowIndex: wi + 1, index: i + 1,
                               title: (titles[i] as? String) ?? "", url: (urls[safe: i] as? String) ?? "",
                               active: i + 1 == active, mode: mode))
        }
    }
    return out
}

/// Windows anybrowser opened (tab new --window, private), so a listing can say
/// which are the agent's own and which are the user's.
let openedPath = tempDir + "anybrowser-opened.json"

func openedWindows() -> Set<String> {
    guard let data = FileManager.default.contents(atPath: openedPath),
          let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(list)
}

func rememberFrontWindow(_ browser: NSRunningApplication) {
    guard family(browser) != .other, let tabs = try? tabList(browser), let front = tabs.first?.window, !front.isEmpty else { return }
    var list = Array(openedWindows())
    list.append("\(browser.bundleIdentifier ?? "")#\(front)")
    if let data = try? JSONEncoder().encode(Array(list.suffix(50))) { FileManager.default.createFile(atPath: openedPath, contents: data) }
}

func tabLine(_ t: TabInfo) -> String {
    let title = t.title.isEmpty ? "(untitled)" : String(flat(t.title).prefix(80))
    let url = t.url.isEmpty ? "" : " — " + String(t.url.prefix(110)) + (t.url.count > 110 ? "…" : "")
    return "\(t.index)\(t.active ? "*" : " ") \(title)\(url)"
}

func tabsReport(mineOnly: Bool = false) throws -> String {
    let browsers = chosenBrowser.map { _ in [try? targetBrowser()].compactMap { $0 } } ?? runningBrowsers()
    if chosenBrowser != nil && browsers.isEmpty { _ = try targetBrowser() }        // says which isn't running
    guard !browsers.isEmpty else { throw Fail(message: "no browser is running — start one with: focus Safari") }
    var lines: [String] = []
    for b in browsers {
        var tabs: [TabInfo]
        do { tabs = try tabList(b) } catch let f as Fail { lines.append("\(browserName(b)) — \(f.message)"); continue }
        if mineOnly {
            let mine = openedWindows()
            tabs = tabs.filter { mine.contains("\(b.bundleIdentifier ?? "")#\($0.window)") }
            if tabs.isEmpty { continue }
        }
        let windows = Set(tabs.map { $0.windowIndex }).count
        lines.append("\(browserName(b)) — \(windows) window\(windows == 1 ? "" : "s"), \(tabs.count) tab\(tabs.count == 1 ? "" : "s")")
        let opened = openedWindows()
        var lastWindow = 0
        let grouped = windows > 1 || tabs.contains { !$0.mode.isEmpty || opened.contains("\(b.bundleIdentifier ?? "")#\($0.window)") }
        for t in tabs {
            if t.windowIndex != lastWindow {
                lastWindow = t.windowIndex
                var notes: [String] = []
                if !t.mode.isEmpty { notes.append(t.mode) }
                if opened.contains("\(b.bundleIdentifier ?? "")#\(t.window)") { notes.append("opened by anybrowser") }
                if grouped { lines.append("  window \(t.windowIndex)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")) }
            }
            lines.append((grouped ? "    " : "  ") + tabLine(t))
        }
    }
    if mineOnly && lines.isEmpty { return "no window opened by anybrowser is open" }
    return lines.joined(separator: "\n")
}

/// A tab by number (in the front window) or by words from its title or address.
/// Tabs matching words from their title or address, best first (0 = the whole title).
func matchingTabs(_ query: String, _ browsers: [NSRunningApplication]) -> [(score: Int, browser: NSRunningApplication, tab: TabInfo)] {
    var out: [(score: Int, browser: NSRunningApplication, tab: TabInfo)] = []
    for b in browsers {
        guard let tabs = try? tabList(b) else { continue }
        for t in tabs {
            let s = [score(t.title, query), score(t.url, query).map { $0 + 4 },
                     t.url.lowercased().contains(query.lowercased()) ? 6 : nil].compactMap { $0 }.min()
            if let s = s { out.append((s, b, t)) }
        }
    }
    return out.sorted { $0.score < $1.score }
}

/// A tab by number (in the front window) or by words from its title or address.
func findTab(_ query: String, _ browsers: [NSRunningApplication]) throws -> (NSRunningApplication, TabInfo, [TabInfo]) {
    if let n = Int(query) {
        let b = try targetBrowser()
        let tabs = try tabList(b)
        let front = tabs.filter { $0.windowIndex == 1 }
        guard let t = front.first(where: { $0.index == n }) else {
            throw Fail(message: "the front window of \(browserName(b)) has \(front.count) tab\(front.count == 1 ? "" : "s") — no tab \(n)")
        }
        return (b, t, tabs)
    }
    guard let found = matchingTabs(query, browsers).first else { throw Fail(message: "no tab matching: \(query) — tabs lists them") }
    return (found.browser, found.tab, (try? tabList(found.browser)) ?? [])
}

func selectTab(_ browser: NSRunningApplication, _ t: TabInfo) throws {
    if family(browser) == .other {
        let app = AXUIElementCreateApplication(browser.processIdentifier)
        let windows = realWindows(app)
        guard let w = windows[safe: t.windowIndex - 1] else { throw Fail(message: "that window has closed") }
        func radios(_ e: AXUIElement, _ depth: Int) -> [AXUIElement] {
            guard depth <= 5 else { return [] }
            return e.children.flatMap { c -> [AXUIElement] in c.role == "RadioButton" ? [c] : radios(c, depth + 1) }
        }
        guard let button = radios(w, 0).first(where: { $0.text(kAXTitleAttribute) == t.title }) else { throw Fail(message: "tab not found in the tab bar") }
        w.perform(kAXRaiseAction, timeout: 0.5)
        button.perform(kAXPressAction, timeout: 0.5)
    } else {
        _ = try Scripting.call(browser, "select", [t.window, "\(t.index)"])
    }
    bringToFront(browser)
}

// MARK: - Navigation

func normalizeURL(_ raw: String) throws -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    let lower = s.lowercased()
    if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") {
        throw Fail(message: "go doesn't run javascript: addresses — js \"<code>\" does, when the browser allows it", code: 2)
    }
    if lower.hasPrefix("localhost") || s.range(of: #"^\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) != nil { return "http://" + s }
    if s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil { return s }
    if !s.contains(" "), s.contains(".") { return "https://" + s }
    throw Fail(message: "go takes an address (example.com, https://…), not: \(s)", code: 2)
}

func loadedReport(_ verb: String, _ r: (done: Bool, url: String, title: String), _ started: Double) -> String {
    let title = r.title.isEmpty ? "(untitled)" : "\"\(String(flat(r.title).prefix(90)))\""
    if r.done { return "\(verb) \(title) — \(r.url)  (\(seconds(started)))" }
    return "\(verb) \(title) — \(r.url) — still loading after \(seconds(started)); waitload waits longer"
}

/// The address in front, from accessibility, without waking or waiting for a page.
func currentURL(_ browser: NSRunningApplication) -> String? {
    let app = AXUIElementCreateApplication(browser.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute), let web = webArea(in: win) else { return nil }
    return axURL(web)
}

func navigate(_ op: String, url: String? = nil) throws -> String {
    let browser = try targetBrowser()
    let started = now()
    // go with no window open: open one, so a macro or a first command doesn't fail on "no window".
    if op == "go", family(browser) != .other {
        let ax = AXUIElementCreateApplication(browser.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        if realWindows(ax).isEmpty {
            try waitIfTyping(for: browser.processIdentifier)
            _ = try Scripting.call(browser, "new", [url!, "window"])
            bringToFront(browser)
            rememberFrontWindow(browser)
            return loadedReport("opened \(browserName(browser)):", waitLoad(browser, from: nil, seconds: 20, opening: true), started)
                + gateNote(pid: browser.processIdentifier)
        }
    }
    let mark = pageMark(browser)
    var before: String? = mark.url
    switch (op, family(browser)) {
    case ("go", .other):
        bringToFront(browser)
        try hotkey("cmd", "l")
        paste(url!)
        tap(36)
    case ("back", .safari), ("forward", .safari):
        // Safari's toolbar buttons carry fixed identifiers and a live enabled state
        // (the menu's goes stale until the menu is shown).
        let (_, win) = try browserWindow(browser)
        guard let button = identified(win, op == "back" ? "BackButton" : "ForwardButton") else {
            throw Fail(message: "Safari's \(op) button isn't in the toolbar — hotkey cmd [ / cmd ]")
        }
        if (button.attr(kAXEnabledAttribute) as? Bool) == false {
            return "\(op): nothing to go \(op) to — still on \(mark.url ?? "this page")"
        }
        bringToFront(browser)
        button.perform(kAXPressAction, timeout: 0.5)
    case ("reload", .other), ("back", .other), ("forward", .other):
        bringToFront(browser)
        switch op {
        case "reload": try pressMenuCommand(browser, key: "r", what: "reload")
        case "back": try pressMenuCommand(browser, key: "[", what: "back", trustEnabled: false)
        default: try pressMenuCommand(browser, key: "]", what: "forward", trustEnabled: false)
        }
    default:
        // The script says which address the tab is leaving.
        let scripted = try Scripting.call(browser, op, op == "go" ? ["", url!] : [""]) as? String
        if before == nil { before = scripted }
        bringToFront(browser)
    }
    let result = waitLoad(browser, from: mark, scripted: before, seconds: 20)
    let verb = ["go": "loaded", "reload": "reloaded", "back": "back to", "forward": "forward to"][op] ?? op
    if (op == "back" || op == "forward"), let b = before, result.url == b {
        return "\(op): nothing to go \(op) to — still on \(b)"
    }
    return loadedReport(verb, result, started) + gateNote(pid: browser.processIdentifier)
}

// MARK: - Walls only the user passes

/// " · ⚠ …" when the page in the front window stops the agent: a bot check, a CAPTCHA, a sign-in.
func gateNote(pid: pid_t) -> String {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let win = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute), let web = webArea(in: win),
          let gate = pageGate(web, title: win.text(kAXTitleAttribute)) else { return "" }
    return " · ⚠ " + gate
}

func pageGate(_ web: AXUIElement, title: String) -> String? {
    let heading = (web.text(kAXTitleAttribute) + " " + title).lowercased()
    let text = String((pageText(web) ?? "").prefix(6000)).lowercased()
    // A bot check stands in for the whole page, with little else on it.
    let checks = ["just a moment", "un momento", "verify you are human", "verifica di essere un essere umano", "verifica che tu sia umano",
                  "checking your browser", "attention required", "press & hold", "tieni premuto", "are you a robot"]
    if checks.contains(where: { heading.contains($0) || (text.count < 1500 && text.contains($0)) }) {
        return "a bot check stands before the page: waitgone it for a few seconds; if it stays, only the user can pass it"
    }
    for frameElement in webSearch(web, "AXFrameSearchKey", limit: 12) {
        let label = (frameElement.text(kAXTitleAttribute) + " " + frameElement.text(kAXDescriptionAttribute)).lowercased()
        if ["recaptcha", "hcaptcha", "turnstile", "security challenge", "sfida di sicurezza", "captcha"].contains(where: { label.contains($0) }) {
            return "a CAPTCHA is on the page: only the user answers it — ask them, then waitfor what comes after"
        }
    }
    if text.contains("non sono un robot") || text.contains("i'm not a robot") {
        return "a CAPTCHA is on the page: only the user answers it — ask them, then waitfor what comes after"
    }
    if webSearch(web, "AXAnyTypeSearchKey", text: "SPID", limit: 30).contains(where: { ["Link", "Button"].contains($0.role) }) {
        return "sign-in with SPID or CIE: the user does it, on their phone — then waitfor the page that follows"
    }
    // A web password field reads as a plain TextField (Safari and Chromium both), so it can't be
    // told apart here. The "never type a password" rule covers it at fill time instead.
    return nil
}

// MARK: - Files a browser keeps

let home = FileManager.default.homeDirectoryForCurrentUser.path

/// nil: no such file · true: macOS keeps it from this process (Full Disk Access) · false: readable
func protected(_ path: String) -> Bool? {
    let fd = open(path, O_RDONLY)
    if fd >= 0 { close(fd); return false }
    return errno == EPERM || errno == EACCES ? true : nil
}

func needsFullDiskAccess(_ what: String) -> Fail {
    Fail(message: """
        Safari keeps its \(what) where only apps with Full Disk Access can read. Either give your terminal app \
        Full Disk Access (System Settings > Privacy & Security > Full Disk Access, then restart it), or read them \
        in Safari itself: \(what == "history" ? "history --ui" : "bookmarks --ui").
        """)
}

/// Command-line arguments of another process — to find the profile folder a
/// browser was started with (--user-data-dir).
func processArguments(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = MemoryLayout<Int32>.size
    while i < size && buffer[i] != 0 { i += 1 }             // the executable's path
    while i < size && buffer[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buffer[i] != 0 { i += 1 }
        args.append(String(decoding: buffer[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

let chromiumDataDirs: [String: String] = [
    "com.google.Chrome": "Google/Chrome", "com.google.Chrome.beta": "Google/Chrome Beta",
    "com.google.Chrome.dev": "Google/Chrome Dev", "com.google.Chrome.canary": "Google/Chrome Canary",
    "org.chromium.Chromium": "Chromium", "com.brave.Browser": "BraveSoftware/Brave-Browser",
    "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta", "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly",
    "com.microsoft.edgemac": "Microsoft Edge", "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
    "com.microsoft.edgemac.Dev": "Microsoft Edge Dev", "com.microsoft.edgemac.Canary": "Microsoft Edge Canary",
    "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "com.operasoftware.Opera",
    "company.thebrowser.Browser": "Arc/User Data",
]

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// The profile folder a Chromium browser is using: the one it was started with,
/// else the last one used.
func chromiumProfile(_ browser: NSRunningApplication) throws -> String {
    let args = processArguments(browser.processIdentifier)
    var base: String
    if let a = args.first(where: { $0.hasPrefix("--user-data-dir=") }) {
        base = String(a.dropFirst("--user-data-dir=".count))
    } else if let rel = chromiumDataDirs[browser.bundleIdentifier ?? ""] {
        base = home + "/Library/Application Support/" + rel
    } else {
        throw Fail(message: "don't know where \(browserName(browser)) keeps its profile")
    }
    if let a = args.first(where: { $0.hasPrefix("--profile-directory=") }) { return base + "/" + a.dropFirst("--profile-directory=".count) }
    let last = ((readJSON(base + "/Local State")?["profile"] as? [String: Any])?["last_used"] as? String) ?? "Default"
    return base + "/" + last
}

func sqliteRows(_ path: String, _ sql: String, _ binds: [Any]) throws -> [[Any?]] {
    guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
    var db: OpaquePointer?
    // immutable: read the file as it is, without the browser's lock (it keeps it open).
    guard sqlite3_open_v2("file:\(encoded)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw Fail(message: "could not open \(path)")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw Fail(message: "could not read \(path): \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, b) in binds.enumerated() {
        if let s = b as? String { sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient) }
        else if let n = b as? Int64 { sqlite3_bind_int64(stmt, Int32(i + 1), n) }
        else if let n = b as? Double { sqlite3_bind_double(stmt, Int32(i + 1), n) }
    }
    var rows: [[Any?]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [Any?] = []
        for c in 0..<sqlite3_column_count(stmt) {
            switch sqlite3_column_type(stmt, c) {
            case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, c))
            case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, c))
            case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, c)))
            default: row.append(nil)
            }
        }
        rows.append(row)
    }
    return rows
}

let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

func historyReport(_ browser: NSRunningApplication, text: String, days: Double, limit: Int, countOnly: Bool = false) throws -> String {
    let needle = text.lowercased()
    var rows: [(Date, String, String, Int64)] = []
    switch family(browser) {
    case .chromium:
        let path = try chromiumProfile(browser) + "/History"
        guard FileManager.default.fileExists(atPath: path) else { throw Fail(message: "\(browserName(browser)) has no history file at \(path)") }
        // Chrome counts microseconds since 1601.
        let since = Int64((Date().timeIntervalSince1970 - days * 86400 + 11_644_473_600) * 1_000_000)
        let sql = """
            SELECT url, title, last_visit_time, visit_count FROM urls
            WHERE hidden = 0 AND last_visit_time > ?1 AND (?2 = '' OR instr(lower(url), ?2) > 0 OR instr(lower(title), ?2) > 0)
            ORDER BY last_visit_time DESC LIMIT ?3
            """
        for r in try sqliteRows(path, sql, [since, needle, Int64(limit)]) {
            let t = Double((r[2] as? Int64) ?? 0) / 1_000_000 - 11_644_473_600
            rows.append((Date(timeIntervalSince1970: t), (r[1] as? String) ?? "", (r[0] as? String) ?? "", (r[3] as? Int64) ?? 0))
        }
    case .safari:
        let path = home + "/Library/Safari/History.db"
        if protected(path) == true { return try safariListView(browser, bookmarks: false, text: text, limit: limit, countOnly: countOnly) }
        // Safari counts seconds since 2001.
        let since = Date().timeIntervalSince1970 - days * 86400 - 978_307_200
        let sql = """
            SELECT i.url, v.title, MAX(v.visit_time), i.visit_count FROM history_visits v JOIN history_items i ON i.id = v.history_item
            WHERE v.visit_time > ?1 AND (?2 = '' OR instr(lower(i.url), ?2) > 0 OR instr(lower(ifnull(v.title, '')), ?2) > 0)
            GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT ?3
            """
        for r in try sqliteRows(path, sql, [since, needle, Int64(limit)]) {
            let t = ((r[2] as? Double) ?? Double((r[2] as? Int64) ?? 0)) + 978_307_200
            rows.append((Date(timeIntervalSince1970: t), (r[1] as? String) ?? "", (r[0] as? String) ?? "", (r[3] as? Int64) ?? 0))
        }
    case .other:
        throw Fail(message: "history of \(browserName(browser)) isn't supported — open its history window and read it")
    }
    guard !rows.isEmpty else {
        return "nothing in \(browserName(browser))'s history" + (text.isEmpty ? "" : " matching \"\(text)\"") + " in the last \(Int(days)) days"
    }
    if countOnly {
        return "\(rows.count)\(rows.count >= limit ? "+" : "") page\(rows.count == 1 ? "" : "s") visited in the last \(Int(days)) days" + (text.isEmpty ? "" : " matching \"\(text)\"")
    }
    return rows.map { r in
        let title = r.1.isEmpty ? "(untitled)" : String(flat(r.1).prefix(80))
        return "\(stamp.string(from: r.0))  \(title) — \(String(r.2.prefix(120)))" + (r.3 > 1 ? "  (\(r.3) visits)" : "")
    }.joined(separator: "\n")
}

/// Without Full Disk Access, Safari's history and bookmarks are read from its own
/// views (⌘Y, ⌥⌘B): an outline whose rows hold a title and an address. The view is
/// closed again if this opened it.
func safariListView(_ browser: NSRunningApplication, bookmarks: Bool, text: String, limit: Int, countOnly: Bool = false) throws -> String {
    let key = bookmarks ? "b" : "y", mods = bookmarks ? 2 : 0
    let what = bookmarks ? "bookmarks" : "history"
    let app = AXUIElementCreateApplication(browser.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    func outline() -> AXUIElement? {
        guard let win = app.element(kAXFocusedWindowAttribute) else { return nil }
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var i = 0
        while i < queue.count && i < 300 {
            let (e, d) = queue[i]; i += 1
            let role = e.role
            if role == "Outline" { return e }
            if role == "WebArea" || d >= 7 { continue }
            for k in e.children { queue.append((k, d + 1)) }
        }
        return nil
    }
    bringToFront(browser)
    var opened = false
    if outline() == nil {
        try pressMenuCommand(browser, key: key, modifiers: mods, what: "Safari's \(what) view")
        opened = true
        guard until(3, { outline() != nil }) else { throw Fail(message: "Safari's \(what) view didn't open — take a shot") }
        pause(150)
    }
    defer { if opened { try? pressMenuCommand(browser, key: key, modifiers: mods, what: "closing the \(what) view", trustEnabled: false) } }
    guard let view = outline() else { throw Fail(message: "Safari's \(what) view has no list") }
    AXUIElementSetMessagingTimeout(view, 3)
    func rowTexts(_ row: AXUIElement) -> [String] {
        var texts: [String] = []
        func collect(_ e: AXUIElement, _ d: Int) {
            if d > 3 { return }
            for c in e.children {
                if c.role == "StaticText" || c.role == "TextField" {
                    let t = flat(c.text(kAXValueAttribute).isEmpty ? c.text(kAXTitleAttribute) : c.text(kAXValueAttribute))
                    texts.append(t)
                } else { collect(c, d + 1) }
            }
        }
        collect(row, 0)
        return texts
    }
    // Folders start collapsed: open them (a few levels deep) so their bookmarks are rows too.
    if bookmarks {
        for _ in 0..<4 {
            var opened = 0
            for row in (view.attr(kAXRowsAttribute) as? [AXUIElement]) ?? [] {
                let texts = rowTexts(row)
                if !texts.contains(where: { $0.contains("://") || $0.hasPrefix("blob:") }), (row.attr("AXDisclosing") as? Bool) == false,
                   AXUIElementSetAttributeValue(row, "AXDisclosing" as CFString, kCFBooleanTrue) == .success {
                    opened += 1
                }
            }
            if opened == 0 { break }
            pause(80)
        }
    }
    let rows = (view.attr(kAXRowsAttribute) as? [AXUIElement]) ?? []
    let needle = text.lowercased()
    var lines: [String] = []
    var folders: [(level: Int, name: String)] = []           // the open folders (or days) above this row
    var printed = ""
    var count = 0
    for row in rows {
        let texts = rowTexts(row).filter { !$0.isEmpty }
        guard !texts.isEmpty else { continue }
        let level = (row.attr("AXDisclosureLevel") as? NSNumber)?.intValue ?? 0
        let url = texts.first { $0.contains("://") || $0.hasPrefix("blob:") } ?? ""
        let title = texts.first { $0 != url } ?? ""
        folders.removeAll { $0.level >= level }
        if url.isEmpty {
            folders.append((level, title))                        // a day, or a folder ("Preferiti", "12 elementi")
            continue
        }
        guard needle.isEmpty || (title + " " + url).lowercased().contains(needle) else { continue }
        count += 1
        if countOnly { continue }
        if count > limit { break }
        let path = folders.map { $0.name }.joined(separator: " › ")
        if path != printed { printed = path; if !path.isEmpty { lines.append("— \(path)") } }
        lines.append("\(title.isEmpty ? "(untitled)" : String(title.prefix(80))) — \(String(url.prefix(120)))")
    }
    guard count > 0 else { return "nothing in Safari's \(what)" + (text.isEmpty ? "" : " matching \"\(text)\"") }
    if countOnly { return "\(count) \(bookmarks ? "bookmark" : "page")\(count == 1 ? "" : "s")" + (text.isEmpty ? "" : " matching \"\(text)\"") }
    return lines.joined(separator: "\n") + "\n(read from Safari's \(what) view — with Full Disk Access it comes straight from the file\(bookmarks ? "" : ", with times")) "
}

struct Bookmark { let folder: String; let title: String; let url: String }

func bookmarks(_ browser: NSRunningApplication) throws -> [Bookmark] {
    var out: [Bookmark] = []
    switch family(browser) {
    case .chromium:
        let path = try chromiumProfile(browser) + "/Bookmarks"
        guard let roots = readJSON(path)?["roots"] as? [String: Any] else { return [] }
        func visit(_ node: [String: Any], _ folder: String) {
            let name = (node["name"] as? String) ?? ""
            if (node["type"] as? String) == "url" {
                out.append(Bookmark(folder: folder, title: name, url: (node["url"] as? String) ?? ""))
            } else {
                let path = folder.isEmpty ? name : "\(folder) › \(name)"
                for child in (node["children"] as? [[String: Any]]) ?? [] { visit(child, path) }
            }
        }
        for key in ["bookmark_bar", "other", "synced"] { if let r = roots[key] as? [String: Any] { visit(r, "") } }
    case .safari:
        let path = home + "/Library/Safari/Bookmarks.plist"
        if protected(path) == true { throw needsFullDiskAccess("bookmarks") }
        guard let root = NSDictionary(contentsOfFile: path) as? [String: Any] else { return [] }
        let names = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"]
        func visit(_ node: [String: Any], _ folder: String) {
            let type = (node["WebBookmarkType"] as? String) ?? ""
            if type == "WebBookmarkTypeLeaf" {
                let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String) ?? ""
                out.append(Bookmark(folder: folder, title: title, url: (node["URLString"] as? String) ?? ""))
            } else if type == "WebBookmarkTypeList" {
                var name = (node["Title"] as? String) ?? ""
                name = names[name] ?? name
                let path = folder.isEmpty ? name : (name.isEmpty ? folder : "\(folder) › \(name)")
                for child in (node["Children"] as? [[String: Any]]) ?? [] { visit(child, path) }
            }
        }
        visit(root, "")
    case .other:
        throw Fail(message: "bookmarks of \(browserName(browser)) aren't supported — open its bookmarks window and read it")
    }
    return out
}

func bookmarksReport(_ browser: NSRunningApplication, text: String, limit: Int, countOnly: Bool = false) throws -> String {
    if family(browser) == .safari, protected(home + "/Library/Safari/Bookmarks.plist") == true {
        return try safariListView(browser, bookmarks: true, text: text, limit: limit, countOnly: countOnly)
    }
    let all = try bookmarks(browser)
    let n = text.lowercased()
    let hits = n.isEmpty ? all : all.filter { ($0.title + " " + $0.url + " " + $0.folder).lowercased().contains(n) }
    guard !hits.isEmpty else {
        return all.isEmpty ? "\(browserName(browser)) has no bookmarks" : "no bookmark matching \"\(text)\" among \(all.count)"
    }
    if countOnly { return "\(hits.count) bookmark\(hits.count == 1 ? "" : "s")" + (text.isEmpty ? "" : " matching \"\(text)\"") }
    var lines = hits.prefix(limit).map { b in
        "\(b.folder.isEmpty ? "" : b.folder + " › ")\(b.title.isEmpty ? "(untitled)" : String(flat(b.title).prefix(70))) — \(String(b.url.prefix(110)))"
    }
    if hits.count > limit { lines.append("… \(hits.count - limit) more — narrow it: bookmarks <text>") }
    return lines.joined(separator: "\n")
}

func whereFrom(_ path: String) -> String? {
    let name = "com.apple.metadata:kMDItemWhereFroms"
    let size = getxattr(path, name, nil, 0, 0, 0)
    guard size > 0 else { return nil }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
    guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
    return list.first
}

/// What came down last: the download folder, newest first, with where each file
/// came from (macOS records it on every download, whichever browser saved it).
/// Where the browser saves downloads: Chrome's own setting, else the user's Downloads.
func downloadFolder(_ browser: NSRunningApplication?) -> String {
    if let b = browser, family(b) == .chromium, let profile = try? chromiumProfile(b),
       let dir = (readJSON(profile + "/Preferences")?["download"] as? [String: Any])?["default_directory"] as? String, !dir.isEmpty {
        return dir
    }
    return home + "/Downloads"
}

func addedDate(_ u: URL) -> Date {
    let v = try? u.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
    return v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
}

let partialDownload: Set<String> = ["crdownload", "download", "part"]

/// Wait for the download just started to finish: the newest file of the last minute whose
/// half-done form (.crdownload, Safari's .download, .part) is gone and whose size holds still.
func waitDownload(_ browser: NSRunningApplication?, seconds: Double) throws -> String {
    let folder = downloadFolder(browser)
    let since = Date().addingTimeInterval(-60)
    let deadline = now() + seconds
    var candidate: URL? = nil
    var lastSize = -1
    var stillSince = now()
    var partial: [URL] = []
    while now() < deadline {
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                     includingPropertiesForKeys: [.addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey],
                     options: [.skipsHiddenFiles])) ?? []
        let recent = items.filter { addedDate($0) >= since }
        partial = recent.filter { partialDownload.contains($0.pathExtension.lowercased()) }
        let done = recent.filter { !partialDownload.contains($0.pathExtension.lowercased()) }.sorted { addedDate($0) > addedDate($1) }
        if partial.isEmpty, let file = done.first {
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if file == candidate && bytes == lastSize {
                if now() - stillSince >= 0.8 {
                    let from = whereFrom(file.path).map { " from \(String($0.prefix(100)))" } ?? ""
                    return "downloaded \(file.lastPathComponent) (\(size(Double(bytes)))) into \(folder)\(from)"
                }
            } else {
                candidate = file
                lastSize = bytes
                stillSince = now()
            }
        }
        pause(250)
    }
    if let p = partial.first { throw Fail(message: "still downloading after \(Int(seconds)) s: \(p.lastPathComponent) — waitdownload \(Int(seconds) * 2) waits longer") }
    throw Fail(message: "no download in \(folder) in the last minute — click the download first; a browser may be asking where to save or whether to allow it (take a shot)")
}

func downloadsReport(_ browser: NSRunningApplication?, count: Int) throws -> String {
    let folder = downloadFolder(browser)
    let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
    let items: [URL]
    do {
        items = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    } catch {
        throw Fail(message: "can't list \(folder) — macOS may be asking whether this terminal may read Downloads")
    }
    func added(_ u: URL) -> Date {
        let v = try? u.resourceValues(forKeys: Set(keys))
        return v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
    }
    let sorted = items.map { ($0, added($0)) }.sorted { $0.1 > $1.1 }.prefix(count)
    guard !sorted.isEmpty else { return "\(folder) is empty" }
    let sizes = ByteCountFormatter()
    var lines = ["in \(folder):"]
    for (u, date) in sorted {
        let v = try? u.resourceValues(forKeys: Set(keys))
        var line = "\(stamp.string(from: date))  \(u.lastPathComponent)"
        let ext = u.pathExtension.lowercased()
        if ext == "crdownload" || ext == "download" || ext == "part" { line += "  (still downloading)" }
        else if v?.isDirectory != true, let s = v?.fileSize { line += "  \(sizes.string(fromByteCount: Int64(s)))" }
        if let from = whereFrom(u.path) { line += "  from \(String(from.prefix(100)))" }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

// MARK: - Settings

func settingsReport(_ browser: NSRunningApplication, search: String) throws -> String {
    switch family(browser) {
    case .safari:
        bringToFront(browser)
        try pressMenuCommand(browser, key: ",", what: "Settings")
        let app = AXUIElementCreateApplication(browser.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        func settingsWindow() -> AXUIElement? {
            guard let w = app.element(kAXFocusedWindowAttribute) else { return nil }
            return w.children.contains(where: { $0.role == "Toolbar" }) && webArea(in: w) == nil ? w : nil
        }
        guard until(3, { settingsWindow() != nil }), let win = settingsWindow() else {
            throw Fail(message: "Safari's settings window didn't open — take a shot")
        }
        let toolbar = win.children.first { $0.role == "Toolbar" }
        let panes = (toolbar?.children ?? []).filter { $0.role == "Button" }
        let names = panes.map { $0.text(kAXTitleAttribute) }.filter { !$0.isEmpty }
        if !search.isEmpty {
            let ranked = panes.compactMap { p -> (Int, AXUIElement)? in score(p.text(kAXTitleAttribute), search).map { ($0, p) } }
            guard let pane = ranked.min(by: { $0.0 < $1.0 })?.1 else {
                throw Fail(message: "Safari settings has no pane \"\(search)\" — panes: \(names.joined(separator: ", "))")
            }
            pane.perform(kAXPressAction, timeout: 0.5)
            _ = until(1.5) { win.text(kAXTitleAttribute).lowercased() == pane.text(kAXTitleAttribute).lowercased() }
        }
        return "Safari settings, pane \"\(win.text(kAXTitleAttribute))\" — panes: \(names.joined(separator: ", ")) · read shows its options"
    case .chromium:
        var url = "chrome://settings/"
        if !search.isEmpty, let q = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { url += "?search=" + q }
        let started = now()
        _ = try Scripting.call(browser, "new", [url])
        bringToFront(browser)
        let r = waitLoad(browser, from: nil, seconds: 10)
        return loadedReport("opened settings", r, started) + " · read shows what's there"
    case .other:
        bringToFront(browser)
        try pressMenuCommand(browser, key: ",", what: "Settings")
        return "asked \(browserName(browser)) for its settings — read shows them"
    }
}
