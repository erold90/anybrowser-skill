// anybrowser — technical audits.
//
// What Chrome's DevTools panels show — Console, Network, Issues, Performance, Security —
// read straight from the DevTools Protocol of a separate headless Chrome. No DevTools
// window to open and read, no setting changed in the user's own browser: a page is
// audited in two or three seconds, a small site in a few more.

import AppKit

// MARK: - JSON as the protocol sends it

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { (self[k] as? String) ?? "" }
    func dict(_ k: String) -> [String: Any] { (self[k] as? [String: Any]) ?? [:] }
    func num(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? 0 }
}

// MARK: - A DevTools Protocol connection

struct CDPEvent { let method: String; let params: [String: Any]; let session: String? }

/// Commands wait for their answer; events are kept, in order, for reading afterwards.
final class CDP {
    private let socket: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let lock = NSLock()
    private var lastId = 0
    private var waiting: [Int: DispatchSemaphore] = [:]
    private var answers: [Int: [String: Any]] = [:]
    private var received: [CDPEvent] = []
    private var broken = false

    init(_ url: URL) {
        urlSession = URLSession(configuration: .ephemeral)
        socket = urlSession.webSocketTask(with: url)
        socket.maximumMessageSize = 64 << 20
        socket.resume()
        listen()
    }

    private func listen() {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            guard case .success(let message) = result else {
                self.lock.lock()
                self.broken = true
                let all = Array(self.waiting.values)
                self.lock.unlock()
                all.forEach { $0.signal() }
                return
            }
            var data: Data? = nil
            switch message {
            case .string(let s): data = s.data(using: .utf8)
            case .data(let d): data = d
            @unknown default: break
            }
            if let d = data, let object = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                self.lock.lock()
                if let id = object["id"] as? Int {
                    self.answers[id] = object
                    let waiter = self.waiting[id]
                    self.lock.unlock()
                    waiter?.signal()
                } else {
                    if let method = object["method"] as? String {
                        self.received.append(CDPEvent(method: method, params: object["params"] as? [String: Any] ?? [:],
                                                      session: object["sessionId"] as? String))
                    }
                    self.lock.unlock()
                }
            }
            self.listen()
        }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: Double = 10) throws -> [String: Any] {
        lock.lock()
        if broken { lock.unlock(); throw Fail(message: "the audit browser closed the connection") }
        lastId += 1
        let id = lastId
        let waiter = DispatchSemaphore(value: 0)
        waiting[id] = waiter
        lock.unlock()
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let s = session { message["sessionId"] = s }
        let data = try JSONSerialization.data(withJSONObject: message)
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        let arrived = waiter.wait(timeout: .now() + timeout) == .success
        lock.lock()
        waiting[id] = nil
        let answer = answers.removeValue(forKey: id)
        lock.unlock()
        guard arrived, let reply = answer else { throw Fail(message: "\(method): no answer from the audit browser in \(Int(timeout)) s") }
        if let error = reply["error"] as? [String: Any] { throw Fail(message: "\(method): \(error.str("message"))") }
        return reply["result"] as? [String: Any] ?? [:]
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return received.count }

    func events(from start: Int) -> [CDPEvent] {
        lock.lock(); defer { lock.unlock() }
        return start < received.count ? Array(received[start...]) : []
    }

    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }
}

// MARK: - A headless Chrome of its own

/// Where a signed-in audit keeps its cookies (audit signin, audit --profile).
let auditProfile = home + "/Library/Application Support/anybrowser/audit-profile"

/// Chromium first — a browser apart from the user's Chrome — then Chrome, Edge, Brave.
/// ANYBROWSER_AUDIT_BROWSER names another one.
func auditBinary() throws -> String {
    let fm = FileManager.default
    if let want = ProcessInfo.processInfo.environment["ANYBROWSER_AUDIT_BROWSER"], !want.isEmpty {
        if fm.isExecutableFile(atPath: want) { return want }
        let app = want.hasSuffix(".app") ? want : "/Applications/\(want).app"
        let binary = app + "/Contents/MacOS/" + ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        if fm.isExecutableFile(atPath: binary) { return binary }
        throw Fail(message: "ANYBROWSER_AUDIT_BROWSER: no browser at \(want)", code: 2)
    }
    for dir in ["/Applications", home + "/Applications"] {
        for name in ["Chromium", "Google Chrome", "Microsoft Edge", "Brave Browser", "Google Chrome Canary"] {
            let binary = "\(dir)/\(name).app/Contents/MacOS/\(name)"
            if fm.isExecutableFile(atPath: binary) { return binary }
        }
    }
    throw Fail(message: "audit needs Chromium, Chrome, Edge or Brave installed")
}

final class Headless {
    let cdp: CDP
    let browser: String
    private let process: Process
    private let dir: String
    private let keep: Bool

    init(profile: Bool) throws {
        let binary = try auditBinary()
        let dir = profile ? auditProfile : tempDir + "anybrowser-audit-\(getpid())"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let portFile = dir + "/DevToolsActivePort"
        try? fm.removeItem(atPath: portFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Nothing a visit doesn't need: no keychain (a fresh profile asks macOS for one), no sync,
        // updates or background fetches. Measured: 0.9–1.3 s to listen, against 1.2–1.9 s without.
        process.arguments = ["--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(dir)", "--no-first-run",
                             "--no-default-browser-check", "--disable-extensions", "--mute-audio", "--hide-scrollbars",
                             "--use-mock-keychain", "--password-store=basic", "--disable-background-networking",
                             "--disable-component-update", "--disable-sync", "--disable-default-apps", "--metrics-recording-only",
                             "--disable-features=Translate,OptimizationHints,MediaRouter", "--window-size=1366,900", "about:blank"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Chrome writes the port it chose, and the browser's socket path, once it listens (~0.5 s).
        var endpoint: URL? = nil
        _ = until(15) {
            if !process.isRunning { return true }
            guard let text = try? String(contentsOfFile: portFile, encoding: .utf8) else { return false }
            let lines = text.split(separator: "\n").map(String.init)
            guard lines.count >= 2, Int(lines[0]) != nil else { return false }
            endpoint = URL(string: "ws://127.0.0.1:\(lines[0])\(lines[1])")
            return true
        }
        guard let url = endpoint else {
            if process.isRunning { process.terminate() }
            if !profile { try? fm.removeItem(atPath: dir) }
            throw Fail(message: profile
                ? "the audit browser didn't start — if the audit profile is still open (audit signin), quit that browser first"
                : "the audit browser didn't start: \(binary)")
        }
        self.cdp = CDP(url)
        self.browser = (binary as NSString).lastPathComponent
        self.process = process
        self.dir = dir
        self.keep = profile
    }

    func stop() {
        debug("audit: closing the browser")
        tryCDP(cdp, "Browser.close", timeout: 2)
        cdp.close()
        // A throwaway profile has nothing to save: don't wait for the browser to tidy up
        // (it took 5 s after one page).
        let deadline = now() + (keep ? 3 : 0.6)
        while process.isRunning && now() < deadline { pause(30) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if !keep {
            // Thousands of small files: removed by a process of their own, which outlives this one.
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", dir]
            try? rm.run()
        }
        debug("audit: browser gone")
    }
}

// MARK: - What the page measures and holds

/// Injected before any script of the page: the Core Web Vitals as the page itself sees them.
let vitalsScript = #"""
(() => {
  const ab = window.__anybrowserAudit = { lcp: 0, cls: 0, longTasks: 0, longMs: 0, shifts: {} };
  const name = n => n && n.nodeType === 1 ? n.tagName.toLowerCase() + (n.id ? '#' + n.id : '')
    + (n.classList && n.classList.length ? '.' + Array.from(n.classList).slice(0, 2).join('.') : '') : null;
  const watch = (type, each) => { try { new PerformanceObserver(list => list.getEntries().forEach(each)).observe({ type, buffered: true }); } catch (e) {} };
  watch('largest-contentful-paint', e => { ab.lcp = e.startTime; });
  watch('layout-shift', e => {
    if (e.hadRecentInput) return;
    ab.cls += e.value;
    for (const s of e.sources || []) { const k = name(s.node); if (k) ab.shifts[k] = (ab.shifts[k] || 0) + e.value; }
  });
  watch('longtask', e => { ab.longTasks++; ab.longMs += e.duration; });
})();
"""#

/// Resolves once running animations with an end have ended (infinite ones, like a pulsing dot, don't count).
let settleScript = #"""
new Promise(r => setTimeout(r, 300)).then(() => Promise.race([
  Promise.all(document.getAnimations().filter(a => {
    const t = a.effect && a.effect.getComputedTiming();
    return t && isFinite(t.endTime) && a.playState === 'running';
  }).map(a => a.finished.catch(() => null))),
  new Promise(r => setTimeout(r, 3000))
])).then(() => true)
"""#

/// Read once the page has loaded: what search engines, screen readers and a person check first.
let pageScript = #"""
(() => {
  const all = s => Array.from(document.querySelectorAll(s));
  const meta = n => document.querySelector(`meta[name="${n}" i]`)?.content ?? null;
  const prop = n => document.querySelector(`meta[property="${n}"]`)?.content ?? null;
  const nav = performance.getEntriesByType('navigation')[0] || {};
  const fcp = performance.getEntriesByName('first-contentful-paint')[0];
  const ab = window.__anybrowserAudit || {};
  const ids = all('[id]').map(e => e.id);
  const labelled = e => (e.labels && e.labels.length) || e.getAttribute('aria-label') || e.getAttribute('aria-labelledby') || e.title;
  return JSON.stringify({
    title: document.title, lang: document.documentElement.lang || null, doctype: !!document.doctype,
    description: meta('description'), robots: meta('robots'), viewport: meta('viewport'),
    canonical: document.querySelector('link[rel="canonical"]')?.href ?? null,
    icon: !!document.querySelector('link[rel~="icon"]'),
    ogTitle: prop('og:title'), ogImage: prop('og:image'),
    structured: all('script[type="application/ld+json"]').length,
    h1: all('h1').map(h => h.textContent.trim().replace(/\s+/g, ' ').slice(0, 80)),
    images: all('img').length,
    noAlt: all('img:not([alt])').map(i => i.currentSrc || i.src).slice(0, 20),
    unlabeled: all('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=reset]):not([type=image]), select, textarea')
      .filter(e => !labelled(e) && (!e.checkVisibility || e.checkVisibility())).map(e => e.name || e.id || e.type).slice(0, 20),
    namelessButtons: all('button, [role=button]').filter(b => !b.textContent.trim() && !b.getAttribute('aria-label') && !b.title).length,
    duplicateIds: [...new Set(ids.filter((id, i) => id && ids.indexOf(id) !== i))].slice(0, 10),
    links: [...new Set(all('a[href]').map(a => a.href).filter(h => /^https?:/i.test(h)).map(h => h.split('#')[0]))],
    nodes: document.getElementsByTagName('*').length,
    ttfb: nav.responseStart || null, domContentLoaded: nav.domContentLoadedEventEnd || null, load: nav.loadEventEnd || null,
    fcp: fcp ? fcp.startTime : null, lcp: ab.lcp || null, cls: ab.cls ?? null, longTasks: ab.longTasks || 0, longMs: ab.longMs || 0,
    shifts: Object.entries(ab.shifts || {}).sort((a, b) => b[1] - a[1]).slice(0, 3).map(e => e[0])
  });
})()
"""#

// MARK: - One page

struct Finding { let kind: String; let text: String }

final class NetRequest {
    var url = "", type = "", mime = ""
    var status = 0
    var headers: [String: String] = [:]
    var bytes = 0.0
    var waitMs = 0.0
    var failed: String? = nil
    var canceled = false
    var security: [String: Any] = [:]
    var redirects: [(url: String, status: Int)] = []
}

struct PageReport {
    let url: String
    var finalURL = ""
    var status = 0
    var failure: String? = nil
    var seconds = 0.0
    var errors: [Finding] = []
    var warnings: [Finding] = []
    var requests: [NetRequest] = []
    var main: NetRequest? = nil
    var info: [String: Any] = [:]
    var metrics: [String: Double] = [:]
    var cookies: [[String: Any]] = []
    var links: [String] { info["links"] as? [String] ?? [] }
    var address: String { finalURL.isEmpty ? url : finalURL }
}

func auditPage(_ cdp: CDP, session: String, url: String, wait: Double) -> PageReport {
    var report = PageReport(url: url)
    let mark = cdp.count
    let started = now()
    debug("audit: navigating to \(url)")
    do {
        let nav = try cdp.send("Page.navigate", ["url": url], session: session, timeout: wait)
        debug("audit: navigation committed")
        let error = nav.str("errorText")
        if !error.isEmpty { report.failure = error }
    } catch let f as Fail {
        report.failure = f.message
    } catch {
        report.failure = "\(error)"
    }
    var extraIssues: [[String: Any]] = []
    if report.failure == nil {
        // Loaded, then the network quiet for half a second — or only long-lived connections left.
        var loadedAt: Double? = nil
        var lastActivity = now()
        var seen = mark
        var inflight = Set<String>()
        while now() - started < wait {
            let batch = cdp.events(from: seen)
            seen += batch.count
            for e in batch where e.session == session {
                switch e.method {
                case "Page.loadEventFired": loadedAt = loadedAt ?? now()
                case "Network.requestWillBeSent": inflight.insert(e.params.str("requestId")); lastActivity = now()
                case "Network.loadingFinished", "Network.loadingFailed": inflight.remove(e.params.str("requestId")); lastActivity = now()
                default: break
                }
            }
            if let loaded = loadedAt, now() - lastActivity > 0.5, inflight.isEmpty || now() - loaded > 2 { break }
            pause(40)
        }
        debug("audit: \(loadedAt == nil ? "no load event" : "loaded"), \(inflight.count) requests still open")
        if loadedAt == nil {
            report.warnings.append(Finding(kind: "load", text: "no load event within \(Int(wait)) s — audit --wait \(Int(wait) * 2) waits longer"))
        }
        // Text still fading in measures as nearly invisible (a contrast of 1.00): let the page's
        // timed entrances start and its finite animations end first, at most 3 s.
        tryCDP(cdp, "Runtime.evaluate", ["expression": settleScript, "awaitPromise": true, "returnByValue": true], session: session, timeout: 5)
        // Checks Chrome runs only when asked: text contrast, forms.
        tryCDP(cdp, "Audits.checkContrast", ["reportAAA": false], session: session, timeout: 5)
        if let forms = try? cdp.send("Audits.checkFormsIssues", session: session, timeout: 5) {
            for details in forms["formIssues"] as? [[String: Any]] ?? [] {
                extraIssues.append(["code": "GenericIssue", "details": ["genericIssueDetails": details]])
            }
        }
        debug("audit: contrast and forms checked")
        if let r = try? cdp.send("Runtime.evaluate", ["expression": pageScript, "returnByValue": true], session: session, timeout: 10),
           let json = r.dict("result")["value"] as? String,
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            report.info = object
        }
        debug("audit: page read")
        if let m = try? cdp.send("Performance.getMetrics", session: session) {
            for metric in m["metrics"] as? [[String: Any]] ?? [] { report.metrics[metric.str("name")] = metric.num("value") }
        }
        pause(150)                                        // the checks' issues arrive as events
        debug("audit: metrics taken")
    }
    report.seconds = now() - started
    // Chrome measures text nobody can see too (a hidden screen, a panel at opacity 0): those don't count.
    let hidden = report.failure == nil ? invisibleContrastNodes(cdp, session: session, from: mark) : []
    collect(cdp.events(from: mark).filter { $0.session == session }, extraIssues, hidden: hidden, into: &report)
    if report.failure == nil,
       let c = try? cdp.send("Network.getCookies", ["urls": [report.address]], session: session) {
        report.cookies = c["cookies"] as? [[String: Any]] ?? []
    }
    return report
}

/// The low-contrast elements that aren't visible at all — hidden, or at opacity 0 themselves or
/// through an ancestor. Chrome flags them with a ratio near 1.0 (a portfolio's second screen did).
func invisibleContrastNodes(_ cdp: CDP, session: String, from mark: Int) -> Set<Int> {
    let ids = cdp.events(from: mark).filter { $0.session == session && $0.method == "Audits.issueAdded" }
        .compactMap { ($0.params.dict("issue").dict("details").dict("lowTextContrastIssueDetails")["violatingNodeId"] as? NSNumber)?.intValue }
    guard !ids.isEmpty else { return [] }
    tryCDP(cdp, "DOM.getDocument", ["depth": 0], session: session)
    // Hidden, or scrolled out of a scrolling panel: Chrome then measures it against whatever lies
    // under that spot (the portfolio's skills, below the fold of their panel, read 2.54 in both themes).
    let visible = """
        function(){
          const e = this.nodeType === 1 ? this : this.parentElement;
          if (!e) return true;
          if (e.checkVisibility && !e.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return false;
          const r = e.getBoundingClientRect();
          for (let a = e.parentElement; a && a !== document.body && a !== document.documentElement; a = a.parentElement) {
            const s = getComputedStyle(a);
            if (/(auto|scroll|hidden|clip)/.test(s.overflowY + ' ' + s.overflowX)) {
              const b = a.getBoundingClientRect();
              if (r.bottom <= b.top || r.top >= b.bottom || r.right <= b.left || r.left >= b.right) return false;
            }
          }
          return true;
        }
        """
    var hidden = Set<Int>()
    for id in Set(ids).prefix(200) {
        guard let object = tryCDP(cdp, "DOM.resolveNode", ["backendNodeId": id], session: session)?.dict("object").str("objectId"),
              !object.isEmpty,
              let answer = tryCDP(cdp, "Runtime.callFunctionOn", ["objectId": object, "functionDeclaration": visible, "returnByValue": true],
                                  session: session) else { continue }
        if answer.dict("result")["value"] as? Bool == false { hidden.insert(id) }
    }
    return hidden
}

func remoteText(_ o: [String: Any]) -> String {
    if let s = o["value"] as? String { return s }
    if let v = o["value"] { return "\(v)" }
    if let u = o["unserializableValue"] as? String { return u }
    let d = o.str("description")
    return d.isEmpty ? o.str("type") : d
}

/// " — /app.js:12:5": the first frame with a file, lines counted from 1.
func codePlace(_ trace: [String: Any], url: String = "", line: Double = -1, base: String) -> String {
    let frames = trace["callFrames"] as? [[String: Any]] ?? []
    if let f = frames.first(where: { !$0.str("url").isEmpty }) {
        return " — \(shortURL(f.str("url"), base)):\(Int(f.num("lineNumber")) + 1):\(Int(f.num("columnNumber")) + 1)"
    }
    return url.isEmpty ? "" : " — \(shortURL(url, base))" + (line >= 0 ? ":\(Int(line) + 1)" : "")
}

/// An entry of Chrome's Issues panel in one line: its kind, why, and where. True when it breaks something.
func issueFinding(_ issue: [String: Any], base: String) -> (Finding, Bool) {
    let code = issue.str("code").replacingOccurrences(of: "Issue", with: "")
    let details = issue.dict("details")
    if code == "LowTextContrast" {
        let d = details.dict("lowTextContrastIssueDetails")
        let line = String(format: "LowTextContrast: %.2f, needs %.1f — %@", d.num("contrastRatio"), d.num("thresholdAA"), d.str("violatingNodeSelector"))
        return (Finding(kind: "issue", text: clip(line, 180)), false)
    }
    func find(_ key: String, _ value: Any, _ depth: Int = 0) -> Any? {
        guard depth < 6 else { return nil }
        if let d = value as? [String: Any] {
            if let hit = d[key] { return hit }
            for v in d.values { if let hit = find(key, v, depth + 1) { return hit } }
        } else if let list = value as? [Any] {
            for v in list { if let hit = find(key, v, depth + 1) { return hit } }
        }
        return nil
    }
    func text(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let list = v as? [String], !list.isEmpty { return list.joined(separator: ", ") }
        return nil
    }
    let why = ["errorType", "violatedDirective", "cookieExclusionReasons", "cookieWarningReasons", "corsError", "type", "reason", "violationType"]
        .lazy.compactMap { text(find($0, details)) }.first ?? ""
    let cookie = (find("cookie", details) as? [String: Any]).map { " \"\($0.str("name"))\"" } ?? ""
    let url = ["insecureURL", "blockedURL", "url", "requestUrl", "documentURL"].lazy.compactMap { text(find($0, details)) }.first
    let breaks = ["MixedContent", "ContentSecurityPolicy", "Cors", "BlockedByResponse", "SharedArrayBuffer", "HeavyAd"].contains(code)
        || (code == "Cookie" && text(find("cookieExclusionReasons", details)) != nil)
    let line = [code + (why.isEmpty ? "" : ": \(why)") + cookie, url.map { shortURL($0, base) }].compactMap { $0 }.joined(separator: " — ")
    return (Finding(kind: "issue", text: clip(line, 180)), breaks)
}

let textTypes: Set<String> = ["Document", "Script", "Stylesheet", "XHR", "Fetch"]

func collect(_ events: [CDPEvent], _ extraIssues: [[String: Any]], hidden: Set<Int> = [], into r: inout PageReport) {
    var byId: [String: NetRequest] = [:]
    var order: [NetRequest] = []
    var issues = extraIssues
    var document: NetRequest? = nil
    let base = r.url
    for e in events {
        let p = e.params
        switch e.method {
        case "Network.requestWillBeSent":
            let id = p.str("requestId"), request = p.dict("request")
            if let known = byId[id], !p.dict("redirectResponse").isEmpty {
                known.redirects.append((known.url, Int(p.dict("redirectResponse").num("status"))))
                known.url = request.str("url")
            } else {
                let n = NetRequest()
                n.url = request.str("url")
                n.type = p.str("type")
                byId[id] = n
                order.append(n)
                if document == nil && n.type == "Document" { document = n }
            }
        case "Network.responseReceived":
            guard let n = byId[p.str("requestId")] else { break }
            let response = p.dict("response")
            n.status = Int(response.num("status"))
            n.mime = response.str("mimeType")
            n.headers = Dictionary((response["headers"] as? [String: Any] ?? [:]).map { ($0.key.lowercased(), "\($0.value)") },
                                   uniquingKeysWith: { first, _ in first })
            n.waitMs = response.dict("timing").num("receiveHeadersEnd")
            n.security = response.dict("securityDetails")
            if n.type.isEmpty { n.type = p.str("type") }
        case "Network.loadingFinished":
            byId[p.str("requestId")]?.bytes = p.num("encodedDataLength")
        case "Network.loadingFailed":
            guard let n = byId[p.str("requestId")] else { break }
            n.failed = p.str("blockedReason").isEmpty ? p.str("errorText") : "blocked: \(p.str("blockedReason"))"
            n.canceled = p["canceled"] as? Bool ?? false
        case "Runtime.consoleAPICalled":
            let type = p.str("type")
            guard ["error", "warning", "assert"].contains(type) else { break }
            let args = (p["args"] as? [[String: Any]] ?? []).map(remoteText).joined(separator: " ")
            let finding = Finding(kind: "console", text: clip(flat(args), 160) + codePlace(p.dict("stackTrace"), base: base))
            if type == "warning" { r.warnings.append(finding) } else { r.errors.append(finding) }
        case "Runtime.exceptionThrown":
            let d = p.dict("exceptionDetails")
            let description = d.dict("exception").str("description")
            let first = (description.isEmpty ? d.str("text") : description).components(separatedBy: "\n").first ?? ""
            r.errors.append(Finding(kind: "exception", text: clip(first, 160)
                + codePlace(d.dict("stackTrace"), url: d.str("url"), line: d["lineNumber"] == nil ? -1 : d.num("lineNumber"), base: base)))
        case "Log.entryAdded":
            let entry = p.dict("entry")
            let level = entry.str("level"), source = entry.str("source")
            // Its network lines repeat the failed requests, listed on their own below.
            guard source != "network", level == "error" || level == "warning" else { break }
            let finding = Finding(kind: source, text: clip(flat(entry.str("text")), 160) + (entry.str("url").isEmpty ? "" : " — \(shortURL(entry.str("url"), base))"))
            if level == "error" { r.errors.append(finding) } else { r.warnings.append(finding) }
        case "Audits.issueAdded":
            issues.append(p.dict("issue"))
        default:
            break
        }
    }
    r.requests = order
    r.main = document
    if let m = document { r.finalURL = m.url; r.status = m.status }
    let page = r.address
    let secure = page.lowercased().hasPrefix("https:")
    for n in order where !n.url.hasPrefix("data:") {
        let at = shortURL(n.url, page)
        if let failed = n.failed {
            // An aborted request is usually the page moving on (a prefetch, a replaced image).
            if failed.contains("ERR_ABORTED") || n.canceled { r.warnings.append(Finding(kind: "aborted", text: "\(at) (\(n.type))")) }
            else { r.errors.append(Finding(kind: "failed", text: "\(at) — \(failed) (\(n.type))")) }
            continue
        }
        if n.status >= 400 {
            let finding = Finding(kind: "\(n.status)", text: "\(at) (\(n.type))")
            // The browser asks for /favicon.ico by itself: worth adding, not a broken page.
            if n.type == "Other" && n.url.hasSuffix("/favicon.ico") { r.warnings.append(finding) } else { r.errors.append(finding) }
        }
        if secure && n.url.lowercased().hasPrefix("http:") { r.errors.append(Finding(kind: "mixed", text: "\(at) loaded over http on an https page")) }
        if n.waitMs > 1000 { r.warnings.append(Finding(kind: "slow", text: "\(at) — the server took \(millis(n.waitMs)) to answer")) }
        if n.bytes > 1_000_000 || (n.type == "Image" && n.bytes > 300_000) {
            r.warnings.append(Finding(kind: "heavy", text: "\(at) — \(size(n.bytes)) (\(n.type))"))
        }
        if textTypes.contains(n.type) && n.status == 200 && n.bytes > 20_000 && n.headers["content-encoding"] == nil {
            r.warnings.append(Finding(kind: "uncompressed", text: "\(at) — \(size(n.bytes)) sent without gzip or brotli"))
        }
    }
    var seenIssues = Set<String>()
    // Low contrast comes once per element: one line, the worst first, says it better.
    let contrast = issues.map { $0.dict("details").dict("lowTextContrastIssueDetails") }
        .filter { !$0.isEmpty && !hidden.contains(Int($0.num("violatingNodeId"))) }
    if !contrast.isEmpty {
        let worst = contrast.sorted { $0.num("contrastRatio") < $1.num("contrastRatio") }
        var selectors: [String] = []
        for d in worst where !selectors.contains(d.str("violatingNodeSelector")) { selectors.append(d.str("violatingNodeSelector")) }
        let head = String(format: "LowTextContrast: %d element%@, worst %.2f where %.1f is needed — ", selectors.count, selectors.count == 1 ? "" : "s",
                          worst[0].num("contrastRatio"), worst[0].num("thresholdAA"))
        r.warnings.append(Finding(kind: "issue", text: head + selectors.prefix(6).joined(separator: ", ") + (selectors.count > 6 ? "…" : "")))
    }
    for issue in issues where issue.dict("details").dict("lowTextContrastIssueDetails").isEmpty {
        let (finding, breaks) = issueFinding(issue, base: page)
        guard seenIssues.insert(finding.text).inserted else { continue }
        if breaks { r.errors.append(finding) } else { r.warnings.append(finding) }
    }
}

// MARK: - Addresses and sizes

func hostOf(_ u: String) -> String {
    (URL(string: u)?.host ?? "").lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
}

func sameSite(_ a: String, _ b: String) -> Bool {
    let x = hostOf(a), y = hostOf(b)
    return !x.isEmpty && (x == y || x.hasSuffix("." + y) || y.hasSuffix("." + x))
}

func pageKey(_ u: String) -> String {
    guard var c = URLComponents(string: u) else { return u }
    c.fragment = nil
    c.host = c.host?.lowercased()
    var s = c.string ?? u
    if s.hasSuffix("/") { s.removeLast() }
    return s
}

func pageLike(_ u: String) -> Bool {
    guard let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    let ext = url.pathExtension.lowercased()
    return ext.isEmpty || ["html", "htm", "php", "asp", "aspx", "jsp"].contains(ext)
}

/// A same-site address as its path ("/about"), anything else in full.
func shortURL(_ u: String, _ base: String) -> String {
    guard let a = URL(string: u), let b = URL(string: base), a.scheme == b.scheme, a.host == b.host, a.port == b.port else { return clip(u, 110) }
    var path = a.path.isEmpty ? "/" : a.path
    if let q = a.query { path += "?" + q }
    return clip(path, 110)
}

func size(_ bytes: Double) -> String {
    bytes >= 1_000_000 ? String(format: "%.1f MB", bytes / 1_000_000) : bytes >= 1000 ? "\(Int(bytes / 1000)) KB" : "\(Int(bytes)) B"
}

func millis(_ v: Double) -> String { v >= 1000 ? String(format: "%.1f s", v / 1000) : "\(Int(v)) ms" }

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }

// MARK: - The command

struct AuditOptions {
    var url = ""
    var wait = 15.0
    var mobile = false, slow = false, json = false, profile = false, dark = false
    var links = false, allLinks = false
    var crawl = 1
    var shot: String? = nil
}

func auditCommand(_ a: [String]) throws -> String {
    if a.first == "signin" { return try auditSignin(a.dropFirst().first) }
    var o = AuditOptions()
    var i = 0
    while i < a.count {
        let w = a[i]
        switch w {
        case "--mobile": o.mobile = true
        case "--slow": o.slow = true
        case "--dark": o.dark = true
        case "--json": o.json = true
        case "--profile": o.profile = true
        case "--links":
            o.links = true
            if a[safe: i + 1] == "all" { o.allLinks = true; i += 1 }
        case "--crawl":
            o.crawl = Int(try number(a[safe: i + 1], "--crawl"))
            guard (1...50).contains(o.crawl) else { throw Fail(message: "--crawl takes 1 to 50 pages", code: 2) }
            i += 1
        case "--wait":
            o.wait = try number(a[safe: i + 1], "--wait")
            i += 1
        case "--shot":
            guard let path = a[safe: i + 1], path.hasPrefix("/"), path.lowercased().hasSuffix(".png") else {
                throw Fail(message: "--shot takes an absolute path ending in .png", code: 2)
            }
            o.shot = path
            i += 1
        default:
            if w.hasPrefix("--") {
                throw Fail(message: "unknown audit option: \(w) — --mobile --slow --dark --links [all] --crawl N --wait S --shot file.png --json --profile", code: 2)
            }
            o.url = try normalizeURL(w)
        }
        i += 1
    }
    var note = ""
    if o.url.isEmpty {
        // No address: the page in front, visited afresh by the audit browser.
        guard let browser = try? targetBrowser(), let u = currentURL(browser), u.lowercased().hasPrefix("http") else {
            throw Fail(message: "audit needs an address, or a web page open in a browser", code: 2)
        }
        o.url = u
        note = "  [the page in \(browserName(browser)), visited afresh: not signed in — audit --profile for that]"
    }
    return try runAudit(o, note: note)
}

func auditSignin(_ raw: String?) throws -> String {
    guard let raw = raw else { throw Fail(message: "audit signin needs the address to sign in at", code: 2) }
    let url = try normalizeURL(raw)
    let binary = try auditBinary()
    let app = binary.components(separatedBy: "/Contents/MacOS/")[0]
    let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
    try FileManager.default.createDirectory(atPath: auditProfile, withIntermediateDirectories: true)
    try waitIfTyping()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-na", app, "--args", "--user-data-dir=\(auditProfile)", "--no-first-run", "--no-default-browser-check", url]
    try p.run()
    p.waitUntilExit()
    return "opened \(url) in \(name) with the audit profile — the user signs in there themselves (never type a password for them) "
        + "and quits \(name); then audit \(url) --profile is signed in"
}

/// A command whose failure only costs a detail of the audit: said under ANYBROWSER_DEBUG, never fatal.
@discardableResult
func tryCDP(_ cdp: CDP, _ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: Double = 10) -> [String: Any]? {
    do { return try cdp.send(method, params, session: session, timeout: timeout) } catch {
        debug("audit: \((error as? Fail)?.message ?? "\(error)")")
        return nil
    }
}

func runAudit(_ o: AuditOptions, note: String) throws -> String {
    let started = now()
    debug("audit: starting the browser")
    let chrome = try Headless(profile: o.profile)
    defer { chrome.stop() }
    debug("audit: browser up")
    let cdp = chrome.cdp
    guard let target = try cdp.send("Target.createTarget", ["url": "about:blank"])["targetId"] as? String,
          let session = try cdp.send("Target.attachToTarget", ["targetId": target, "flatten": true])["sessionId"] as? String else {
        throw Fail(message: "the audit browser gave no page to work in")
    }
    for method in ["Page.enable", "Runtime.enable", "Log.enable", "Network.enable", "Audits.enable", "Performance.enable"] {
        tryCDP(cdp,method, session: session)
    }
    // Some sites serve a headless-looking visitor something else: look like the browser it is.
    let version = (try? cdp.send("Browser.getVersion")) ?? [:]
    var agent = version.str("userAgent").replacingOccurrences(of: "HeadlessChrome", with: "Chrome")
    if o.mobile {
        let v = version.str("product").components(separatedBy: "/").last ?? "146.0.0.0"
        agent = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(v) Mobile Safari/537.36"
        tryCDP(cdp, "Emulation.setDeviceMetricsOverride", ["width": 412, "height": 915, "deviceScaleFactor": 2.625, "mobile": true], session: session)
        tryCDP(cdp, "Emulation.setTouchEmulationEnabled", ["enabled": true], session: session)
    }
    tryCDP(cdp, "Emulation.setUserAgentOverride", ["userAgent": agent], session: session)
    if o.dark {
        // A site with a dark theme has a second set of colours to check.
        tryCDP(cdp, "Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": "dark"]]], session: session)
    }
    if o.slow {
        // Lighthouse's mobile preset: slow 4G and a CPU four times slower. Chrome 146 marks the
        // old network command deprecated: rules first, the old command where rules don't exist.
        let conditions: [String: Any] = ["latency": 150, "downloadThroughput": 1_638_400 / 8, "uploadThroughput": 750_000 / 8]
        if tryCDP(cdp, "Network.emulateNetworkConditionsByRule",
                  ["offline": false, "matchedNetworkConditions": [conditions.merging(["urlPattern": ""]) { a, _ in a }]], session: session) == nil {
            tryCDP(cdp, "Network.emulateNetworkConditions", conditions.merging(["offline": false]) { a, _ in a }, session: session)
        }
        tryCDP(cdp, "Emulation.setCPUThrottlingRate", ["rate": 4], session: session)
    }
    tryCDP(cdp, "Page.addScriptToEvaluateOnNewDocument", ["source": vitalsScript], session: session)

    var pages: [PageReport] = []
    var queue = [o.url]
    var visited = Set<String>()
    while !queue.isEmpty && pages.count < o.crawl {
        let next = queue.removeFirst()
        guard visited.insert(pageKey(next)).inserted else { continue }
        let page = auditPage(cdp, session: session, url: next, wait: o.slow ? max(o.wait, 30) : o.wait)
        if pages.isEmpty, let path = o.shot, page.failure == nil,
           let shot = try? cdp.send("Page.captureScreenshot", ["format": "png"], session: session),
           let data = Data(base64Encoded: shot.str("data")) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        pages.append(page)
        if o.crawl > 1 {
            queue += page.links.filter { sameSite($0, o.url) && pageLike($0) && !visited.contains(pageKey($0)) }
        }
    }

    var broken: [(url: String, result: String, on: [String])] = []
    var checked = 0
    if o.links {
        var linkedFrom: [String: [String]] = [:]
        for p in pages { for l in p.links { linkedFrom[l, default: []].append(p.address) } }
        let audited = Set(pages.filter { $0.failure == nil }.map { pageKey($0.url) })
        let candidates = linkedFrom.keys.filter { (o.allLinks || sameSite($0, o.url)) && !audited.contains(pageKey($0)) }.sorted().prefix(300)
        checked = candidates.count
        for (url, result) in checkLinks(Array(candidates), agent: agent) {
            broken.append((url, result, linkedFrom[url] ?? []))
        }
        broken.sort { $0.url < $1.url }
    }
    let search = pages.first.map { $0.failure == nil ? searchLine($0.address, agent: agent) : "" } ?? ""
    let browser = chrome.browser
    let seconds = now() - started
    return o.json ? auditJSON(pages, broken: broken, checked: checked, browser: browser, seconds: seconds, search: search)
                  : auditText(pages, o, broken: broken, checked: checked, browser: browser, seconds: seconds, note: note, search: search)
}

/// robots.txt, and the sitemap it names or /sitemap.xml: what a search engine reads first.
func searchLine(_ address: String, agent: String) -> String {
    guard let url = URL(string: address), let scheme = url.scheme, let host = url.host else { return "" }
    let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    final class Box { var status = 0; var body = "" }
    func get(_ u: String) -> Box {
        let box = Box()
        guard let target = URL(string: u) else { return box }
        var request = URLRequest(url: target, timeoutInterval: 8)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.body = data.map { String(decoding: $0.prefix(3_000_000), as: UTF8.self) } ?? ""
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return box
    }
    var parts: [String] = []
    var named: [String] = []
    let robots = get(origin + "/robots.txt")
    // A site that answers every address with its home page (a single-page app) has no robots.txt either.
    if robots.status == 200 && !robots.body.lowercased().contains("<html") {
        var everyone = false, blocksAll = false
        for raw in robots.body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces), lower = line.lowercased()
            if lower.hasPrefix("sitemap:") { named.append(String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
            if lower.hasPrefix("user-agent:") { everyone = lower.replacingOccurrences(of: " ", with: "") == "user-agent:*" }
            if everyone && lower.replacingOccurrences(of: " ", with: "") == "disallow:/" { blocksAll = true }
        }
        parts.append(blocksAll ? "robots.txt BLOCKS every search engine from every page" : "robots.txt ok")
    } else {
        parts.append("no robots.txt")
    }
    let map = named.first ?? origin + "/sitemap.xml"
    let sitemap = get(map)
    if sitemap.status == 200 && (sitemap.body.contains("<urlset") || sitemap.body.contains("<sitemapindex")) {
        let entries = sitemap.body.components(separatedBy: "<loc>").count - 1
        parts.append("sitemap \(shortURL(map, address)) " + (sitemap.body.contains("<sitemapindex") ? "indexes \(entries) sitemaps" : "lists \(entries) addresses"))
    } else {
        parts.append(named.isEmpty ? "no sitemap (none named in robots.txt, none at /sitemap.xml)" : "the sitemap robots.txt names doesn't answer: \(map)")
    }
    // An address that doesn't exist must say so: a 200 with the home page is indexed as a copy of it
    // (Cloudflare Pages does that for every site without a 404.html).
    let missing = get(origin + "/anybrowser-no-such-page-\(Int(now()))")
    if missing.status == 200 { parts.append("missing pages answer 200 instead of 404 (a soft 404: add a 404 page)") }
    return parts.joined(separator: " · ")
}

/// Every link, HEAD first and GET when a server refuses HEAD, eight at a time.
func checkLinks(_ urls: [String], agent: String) -> [(String, String)] {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.httpAdditionalHeaders = ["User-Agent": agent]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let group = DispatchGroup()
    let gate = DispatchSemaphore(value: 8)
    let lock = NSLock()
    var bad: [(String, String)] = []
    func outcome(_ response: URLResponse?, _ error: Error?) -> String? {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "timeout"
            case .cannotFindHost, .dnsLookupFailed: return "no host"
            case .cannotConnectToHost: return "refused"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: return "TLS error"
            default: return "error \(e.code.rawValue)"
            }
        }
        if error != nil { return "error" }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return status >= 400 ? "\(status)" : nil
    }
    for u in urls {
        guard let url = URL(string: u) else { continue }
        gate.wait()
        group.enter()
        let done = { (result: String?) in
            if let r = result { lock.lock(); bad.append((u, r)); lock.unlock() }
            gate.signal()
            group.leave()
        }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        session.dataTask(with: head) { _, response, error in
            guard outcome(response, error) != nil else { done(nil); return }
            session.dataTask(with: URLRequest(url: url)) { _, response, error in done(outcome(response, error)) }.resume()
        }.resume()
    }
    group.wait()
    return bad
}

// MARK: - The report

func speedLine(_ p: PageReport) -> String {
    func v(_ k: String) -> Double? { (p.info[k] as? NSNumber)?.doubleValue }
    var parts: [String] = []
    // The network's own measure: the page's navigation timing ignores emulated latency (--slow).
    let ttfb = (p.main?.waitMs ?? 0) > 0 ? p.main?.waitMs : v("ttfb")
    if let t = ttfb { parts.append("TTFB \(millis(t))" + (t > 800 ? " (slow)" : "")) }
    if let t = v("fcp") { parts.append("FCP \(millis(t))" + (t > 1800 ? " (slow)" : "")) }
    if let t = v("lcp") { parts.append("LCP \(millis(t))" + (t > 4000 ? " (poor)" : t > 2500 ? " (slow)" : "")) }
    if let c = v("cls") {
        // Which elements moved, the most first: what to give a size to.
        let movers = (p.info["shifts"] as? [String] ?? []).joined(separator: ", ")
        let grade = c > 0.25 ? "poor" : c > 0.1 ? "high" : ""
        parts.append(String(format: "CLS %.2f", c) + (grade.isEmpty ? "" : " (\(grade)" + (movers.isEmpty ? "" : ": \(movers) moved") + ")"))
    }
    if let t = v("load") { parts.append("load \(millis(t))") }
    if let n = v("longTasks"), n > 0 { parts.append("\(Int(n)) long task\(n == 1 ? "" : "s") (\(millis(v("longMs") ?? 0)))") }
    if let n = v("nodes") { parts.append("\(Int(n)) elements" + (n > 1500 ? " (many)" : "")) }
    if let heap = p.metrics["JSHeapUsedSize"] { parts.append("JS heap \(size(heap))") }
    return parts.joined(separator: " · ")
}

func weightLine(_ p: PageReport) -> String {
    let done = p.requests.filter { $0.failed == nil && !$0.url.hasPrefix("data:") }
    let total = done.reduce(0) { $0 + $1.bytes }
    let kinds: [(String, Set<String>)] = [("scripts", ["Script"]), ("images", ["Image"]), ("styles", ["Stylesheet"]), ("fonts", ["Font"]),
                                          ("data", ["XHR", "Fetch"]), ("media", ["Media"]), ("html", ["Document"])]
    let split = kinds.compactMap { name, types -> String? in
        let bytes = done.filter { types.contains($0.type) }.reduce(0) { $0 + $1.bytes }
        return bytes >= 1000 ? "\(name) \(size(bytes))" : nil
    }
    let others = Set(p.requests.map { $0.url }.filter { !$0.hasPrefix("data:") && !hostOf($0).isEmpty && !sameSite($0, p.address) }.map(hostOf))
    var line = "\(done.count) requests, \(size(total))" + (split.isEmpty ? "" : ": " + split.joined(separator: ", "))
    if !others.isEmpty {
        line += " · \(others.count) other host\(others.count == 1 ? "" : "s"): " + others.sorted().prefix(5).joined(separator: ", ") + (others.count > 5 ? "…" : "")
    }
    return line
}

/// What the page says about itself, and what is missing or wrong in it.
func pageFacts(_ p: PageReport) -> (facts: String, problems: [String]) {
    let i = p.info
    guard !i.isEmpty else { return ("", []) }
    var facts: [String] = [], problems: [String] = []
    let title = i.str("title")
    if title.isEmpty { problems.append("no title") } else { facts.append("title \"\(clip(title, 70))\" (\(title.count) chars\(title.count > 60 ? ", long" : ""))") }
    if let d = i["description"] as? String, !d.isEmpty { facts.append("description \(d.count) chars") } else { problems.append("no meta description") }
    if let l = i["lang"] as? String, !l.isEmpty { facts.append("lang \(l)") } else { problems.append("no lang on <html>") }
    let viewport = i["viewport"] as? String ?? ""
    if viewport.isEmpty { problems.append("no viewport meta") }
    if viewport.range(of: #"user-scalable\s*=\s*(no|0)|maximum-scale\s*=\s*1(\.0+)?(\s|,|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
        problems.append("the viewport blocks zooming (\(clip(viewport, 70)))")
    }
    if i["canonical"] as? String != nil { facts.append("canonical ok") } else { problems.append("no canonical") }
    let h1 = i["h1"] as? [String] ?? []
    if h1.isEmpty { problems.append("no h1") } else if h1.count > 1 { problems.append("\(h1.count) h1") } else { facts.append("h1 \"\(clip(h1[0], 50))\"") }
    if i["doctype"] as? Bool == false { problems.append("no doctype (quirks mode)") }
    if i["icon"] as? Bool == false { problems.append("no favicon link") }
    if i["ogTitle"] as? String == nil || i["ogImage"] as? String == nil {
        problems.append("Open Graph: " + [i["ogTitle"] as? String == nil ? "no og:title" : nil, i["ogImage"] as? String == nil ? "no og:image" : nil].compactMap { $0 }.joined(separator: ", "))
    }
    let structured = (i["structured"] as? NSNumber)?.intValue ?? 0
    facts.append(structured > 0 ? "structured data \(structured)" : "no structured data")
    let noAlt = i["noAlt"] as? [String] ?? []
    if !noAlt.isEmpty { problems.append("\(noAlt.count) image\(noAlt.count == 1 ? "" : "s") without alt") }
    let unlabeled = i["unlabeled"] as? [String] ?? []
    if !unlabeled.isEmpty { problems.append("\(unlabeled.count) field\(unlabeled.count == 1 ? "" : "s") without a label (\(unlabeled.prefix(3).joined(separator: ", ")))") }
    let nameless = (i["namelessButtons"] as? NSNumber)?.intValue ?? 0
    if nameless > 0 { problems.append("\(nameless) button\(nameless == 1 ? "" : "s") without a name") }
    let duplicates = i["duplicateIds"] as? [String] ?? []
    if !duplicates.isEmpty { problems.append("duplicate ids: " + duplicates.prefix(5).joined(separator: ", ")) }
    if let robots = i["robots"] as? String, robots.lowercased().contains("noindex") { problems.append("robots: \(robots)") }
    return (facts.joined(separator: " · "), problems)
}

func securityLine(_ p: PageReport) -> String {
    guard let m = p.main, m.status > 0 else { return "" }
    var parts: [String] = []
    let https = m.url.lowercased().hasPrefix("https:")
    if https {
        var s = "https"
        let proto = m.security.str("protocol")
        if !proto.isEmpty { s += " \(proto)" }
        let validTo = m.security.num("validTo")
        if validTo > 0 {
            let days = Int((validTo - Date().timeIntervalSince1970) / 86400)
            s += ", certificate \(days) more days" + (days < 21 ? " (renew soon)" : "")
        }
        parts.append(s)
    } else if !m.url.contains("://127.0.0.1") && !m.url.contains("://localhost") {
        parts.append("not https")
    }
    var missing = (https ? ["strict-transport-security"] : []) + ["content-security-policy", "x-content-type-options", "referrer-policy"]
    missing = missing.filter { m.headers[$0] == nil }
    if m.headers["x-frame-options"] == nil && !(m.headers["content-security-policy"] ?? "").contains("frame-ancestors") {
        missing.append("x-frame-options")
    }
    if !missing.isEmpty { parts.append("missing headers: " + missing.joined(separator: ", ")) }
    let shown = ["server", "x-powered-by"].compactMap { k -> String? in
        guard let v = m.headers[k] else { return nil }
        return k == "x-powered-by" || v.rangeOfCharacter(from: .decimalDigits) != nil ? "\(k): \(v)" : nil
    }
    if !shown.isEmpty { parts.append("tells the world " + shown.joined(separator: ", ")) }
    if !p.cookies.isEmpty {
        let insecure = p.cookies.filter { $0["secure"] as? Bool != true }.count
        let noSameSite = p.cookies.filter { $0["sameSite"] == nil }.count
        let noHttpOnly = p.cookies.filter { $0["httpOnly"] as? Bool != true }.count
        var s = "\(p.cookies.count) cookie\(p.cookies.count == 1 ? "" : "s")"
        if https && insecure > 0 { s += ", \(insecure) without Secure" }
        if noHttpOnly > 0 { s += ", \(noHttpOnly) readable by scripts" }
        if noSameSite > 0 { s += ", \(noSameSite) without SameSite" }
        parts.append(s)
    }
    return parts.joined(separator: " · ")
}

/// Findings once each, with how often they came, the most repeated first.
func findingLines(_ findings: [(page: String, finding: Finding)], pageColumn: Int = 0, limit: Int = 40) -> [String] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for (page, f) in findings {
        let line = (pageColumn > 0 ? pad(page, pageColumn) : "") + pad(f.kind, 12) + f.text
        if counts[line] == nil { order.append(line) }
        counts[line, default: 0] += 1
    }
    var lines = order.prefix(limit).map { "  " + $0 + (counts[$0]! > 1 ? "  (×\(counts[$0]!))" : "") }
    if order.count > limit { lines.append("  … \(order.count - limit) more: audit --json lists them all") }
    return lines
}

func auditText(_ pages: [PageReport], _ o: AuditOptions, broken: [(url: String, result: String, on: [String])], checked: Int,
               browser: String, seconds: Double, note: String, search: String) -> String {
    guard let first = pages.first else { return "audit \(o.url): nothing audited" }
    var out: [String] = []
    let how = "\(browser) headless" + (o.mobile ? ", phone" : "") + (o.slow ? ", slow 4G + CPU ×4" : "") + (o.dark ? ", dark theme" : "")
        + (o.profile ? ", audit profile" : "")
    let base = first.address
    if pages.count == 1 {
        if let failure = first.failure { return "audit \(first.url) — the page didn't load: \(failure)\(note)" }
        let moved = pageKey(first.address) != pageKey(first.url) ? " \(first.address)" : ""
        out.append("audit \(first.url) → \(first.status)\(moved) · page \(String(format: "%.1f", first.seconds)) s · audit \(String(format: "%.1f", seconds)) s with the browser's start (\(how))\(note)")
        if o.crawl > 1 { out.append("crawl    this page links to no other page of the site: 1 page audited") }
        if let m = first.main, !m.redirects.isEmpty {
            out.append("redirects " + m.redirects.map { "\($0.status) \(shortURL($0.url, base))" }.joined(separator: " → ") + " → \(first.status)")
        }
    } else {
        out.append("audit \(o.url) — \(pages.count) pages in \(String(format: "%.1f", seconds)) s (\(how))\(note)")
        for p in pages {
            let state = p.failure.map { "failed: \($0)" }
                ?? ([p.errors.isEmpty ? nil : "\(p.errors.count) error\(p.errors.count == 1 ? "" : "s")",
                     p.warnings.isEmpty ? nil : "\(p.warnings.count) warning\(p.warnings.count == 1 ? "" : "s")"]
                    .compactMap { $0 }.joined(separator: ", "))
            out.append("  \(pad(p.failure == nil ? "\(p.status)" : "—", 4))\(pad(String(format: "%.1f s", p.seconds), 7))\(pad(shortURL(p.url, base), 40))\(state.isEmpty ? "ok" : state)")
        }
    }
    let column = pages.count > 1 ? min(32, (pages.map { shortURL($0.url, base).count }.max() ?? 0) + 2) : 0
    let errors = pages.flatMap { p in p.errors.map { (shortURL(p.url, base), $0) } }
    let warnings = pages.flatMap { p in p.warnings.map { (shortURL(p.url, base), $0) } }
    out.append("errors   \(errors.count)" + (errors.isEmpty ? "" : ":"))
    out += findingLines(errors, pageColumn: column)
    out.append("warnings \(warnings.count)" + (warnings.isEmpty ? "" : ":"))
    out += findingLines(warnings, pageColumn: column, limit: 25)
    if pages.count == 1 {
        let (facts, problems) = pageFacts(first)
        if !facts.isEmpty { out.append("page     " + facts) }
        if !problems.isEmpty { out.append("         to fix: " + problems.joined(separator: " · ")) }
    } else {
        let lines = pages.compactMap { p -> String? in
            let problems = pageFacts(p).problems
            return problems.isEmpty ? nil : "  " + pad(shortURL(p.url, base), column) + problems.joined(separator: " · ")
        }
        if !lines.isEmpty { out.append("pages, to fix:"); out += lines }
    }
    if first.failure == nil {
        let label = pages.count > 1 ? " (first page)" : ""
        out.append("speed    " + speedLine(first) + label)
        out.append("weight   " + weightLine(first) + label)
        let security = securityLine(first)
        if !security.isEmpty { out.append("security " + security) }
        if !search.isEmpty { out.append("search   " + search) }
    }
    if o.links {
        let scope = o.allLinks ? "all links" : "links on this site"
        let external = Set(pages.flatMap { $0.links }.filter { !sameSite($0, o.url) }).count
        let unchecked = o.allLinks || external == 0 ? "" : " · \(external) link\(external == 1 ? "" : "s") to other sites not checked (--links all)"
        if checked == 0 {
            out.append("links    no other \(scope) to check" + unchecked)
        } else if broken.isEmpty {
            out.append("links    \(checked) \(scope) checked: none broken" + unchecked)
        } else {
            out.append("links    \(checked) \(scope) checked: \(broken.count) broken" + unchecked)
            for b in broken.prefix(40) {
                let on = b.on.prefix(3).map { shortURL($0, base) }.joined(separator: ", ") + (b.on.count > 3 ? "…" : "")
                out.append("  \(pad(b.result, 10))\(shortURL(b.url, base))  (on \(on))")
            }
        }
    }
    if let shot = o.shot { out.append("shot     \(shot)") }
    return out.joined(separator: "\n")
}

func auditJSON(_ pages: [PageReport], broken: [(url: String, result: String, on: [String])], checked: Int, browser: String, seconds: Double,
               search: String) -> String {
    let list: [[String: Any]] = pages.map { p in
        var info = p.info
        info["links"] = nil
        var d: [String: Any] = [
            "url": p.url, "finalURL": p.finalURL, "status": p.status, "seconds": (p.seconds * 100).rounded() / 100,
            "errors": p.errors.map { ["kind": $0.kind, "text": $0.text] },
            "warnings": p.warnings.map { ["kind": $0.kind, "text": $0.text] },
            "page": info, "problems": pageFacts(p).problems, "links": p.links, "metrics": p.metrics,
            "headers": p.main?.headers ?? [:],
            "requests": p.requests.map { r -> [String: Any] in
                ["url": r.url, "type": r.type, "status": r.status, "bytes": Int(r.bytes), "waitMs": Int(r.waitMs), "failed": r.failed ?? NSNull()]
            },
            "cookies": p.cookies.map { c -> [String: Any] in
                ["name": c.str("name"), "domain": c.str("domain"), "secure": c["secure"] ?? false, "httpOnly": c["httpOnly"] ?? false,
                 "sameSite": c["sameSite"] ?? NSNull()]
            },
        ]
        if let failure = p.failure { d["failure"] = failure }
        return d
    }
    let all: [String: Any] = [
        "browser": browser, "seconds": (seconds * 100).rounded() / 100, "pages": list, "search": search,
        "links": ["checked": checked, "broken": broken.map { ["url": $0.url, "result": $0.result, "on": $0.on] }],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
