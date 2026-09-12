// anybrowser — macros: a chain that worked, kept under a name and run again with other values.
//
//   macro save flight-ryanair 'go "https://…originIata={from}&destinationIata={to}&dateOut={date}"' 'click "No, grazie"' 'text'
//   macro run flight-ryanair from=BDS to=BGY date=2026-10-15
//
// The second time the same job costs one call and no thinking about names.

import Foundation

/// ANYBROWSER_MACROS moves them (the tests keep theirs apart).
let macroDir = ProcessInfo.processInfo.environment["ANYBROWSER_MACROS"] ?? home + "/Library/Application Support/anybrowser/macros"

func macroPath(_ name: String) throws -> String {
    guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$"#, options: .regularExpression) != nil else {
        throw Fail(message: "a macro name is letters, digits, dots, dashes and underscores: \(name)", code: 2)
    }
    return macroDir + "/\(name).txt"
}

/// The {names} a macro's steps wait for, in order of first use.
func placeholders(_ steps: [String]) -> [String] {
    let re = try! NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
    var seen: [String] = []
    for s in steps {
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range(at: 1), in: s), !seen.contains(String(s[r])) { seen.append(String(s[r])) }
        }
    }
    return seen
}

func saveMacro(_ name: String, _ steps: [String]) throws -> String {
    let path = try macroPath(name)
    for s in steps { _ = try tokenize(s) }           // a step that can't be read fails now, not at the next run
    try FileManager.default.createDirectory(atPath: macroDir, withIntermediateDirectories: true)
    let values = placeholders(steps)
    let body = "# anybrowser macro \(name)" + (values.isEmpty ? "" : " — values: " + values.joined(separator: " ")) + "\n"
        + steps.joined(separator: "\n") + "\n"
    try body.write(toFile: path, atomically: true, encoding: .utf8)
    return "saved macro \(name) (\(steps.count) step\(steps.count == 1 ? "" : "s"))"
        + (values.isEmpty ? " · run it with: macro run \(name)" : " · run it with: macro run \(name) " + values.map { "\($0)=…" }.joined(separator: " "))
}

func loadMacro(_ name: String) throws -> [String] {
    let path = try macroPath(name)
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw Fail(message: "no macro named \(name) — macro list shows them")
    }
    return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

func macroCommand(_ a: [String]) throws -> String {
    let help = "macro save <name> \"<step>\"… · macro run <name> [key=value…] · macro list · macro show <name> · macro delete <name>"
    guard let sub = a.first else { throw Fail(message: help, code: 2) }
    switch sub {
    case "save":
        guard let name = a[safe: 1], a.count >= 3 else { throw Fail(message: "macro save needs a name and at least one step", code: 2) }
        var steps = Array(a.dropFirst(2))
        if steps == ["-"] {
            let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            steps = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        return try saveMacro(name, steps)

    case "run":
        guard let name = a[safe: 1] else { throw Fail(message: "macro run needs a name: macro list shows them", code: 2) }
        var values: [String: String] = [:]
        for pair in a.dropFirst(2) {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { throw Fail(message: "values go as key=value, not: \(pair)", code: 2) }
            values[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        let steps = try loadMacro(name)
        let missing = placeholders(steps).filter { values[$0] == nil }
        guard missing.isEmpty else {
            throw Fail(message: "macro \(name) needs: " + missing.map { "\($0)=…" }.joined(separator: " "), code: 2)
        }
        // A value goes in as text: quotes and backslashes inside it can't end the step's own quoting.
        let filled = steps.map { step in
            values.reduce(step) { s, kv in
                s.replacingOccurrences(of: "{\(kv.key)}", with: kv.value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))
            }
        }
        return try execute(["do"] + filled)

    case "list":
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: macroDir)) ?? []).filter { $0.hasSuffix(".txt") }.sorted()
        guard !files.isEmpty else { return "no macros yet — do --save <name> … keeps a chain that worked" }
        return files.compactMap { file -> String? in
            let name = String(file.dropLast(4))
            guard let steps = try? loadMacro(name) else { return nil }
            let values = placeholders(steps)
            return "\(name)  (\(steps.count) step\(steps.count == 1 ? "" : "s"))" + (values.isEmpty ? "" : "  values: " + values.joined(separator: " "))
        }.joined(separator: "\n")

    case "show":
        guard let name = a[safe: 1] else { throw Fail(message: "macro show needs a name", code: 2) }
        return try loadMacro(name).enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n")

    case "delete":
        guard let name = a[safe: 1] else { throw Fail(message: "macro delete needs a name", code: 2) }
        let path = try macroPath(name)
        guard FileManager.default.fileExists(atPath: path) else { throw Fail(message: "no macro named \(name)") }
        try FileManager.default.removeItem(atPath: path)
        return "deleted macro \(name)"

    default:
        throw Fail(message: help, code: 2)
    }
}
