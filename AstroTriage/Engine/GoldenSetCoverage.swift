// Golden-set coverage reader — walks a golden-set root produced by GoldenSetExporter and reports
// how much material exists per case (and per scope × defect token), so the user can see at a glance
// whether the set is big/broad enough to tune against. Pure/read-only; no scoring.

import Foundation

enum GoldenSetCoverage {

    // Curation targets (from the golden-set spec).
    static let minGoodPerCase = 12
    static let minBadPerCase = 6

    struct CaseInfo: Identifiable {
        var id: String { name }
        let name: String
        let scope: String   // parsed from the case-name prefix
        let token: String   // "baseline" or a defect token (trail/cloud/…)
        let good: Int
        let bad: Int

        var isBaseline: Bool { token == "baseline" }
        /// Meets the per-case targets: good ≥ 12, and (baseline) or bad ≥ 6.
        var ok: Bool { good >= minGoodPerCase && (isBaseline || bad >= minBadPerCase) }
    }

    struct Report {
        let root: URL
        let cases: [CaseInfo]
        var totalGood: Int { cases.reduce(0) { $0 + $1.good } }
        var totalBad: Int { cases.reduce(0) { $0 + $1.bad } }
        var scopes: [String] { Array(Set(cases.map { $0.scope })).sorted() }
        var tokens: [String] { Array(Set(cases.map { $0.token })).sorted() }
        var isEmpty: Bool { cases.isEmpty }
    }

    private static let imageExtensions: Set<String> = ["fit", "fits", "fts", "xisf"]

    static func scan(root: URL) -> Report {
        let fm = FileManager.default
        let caseDirs = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "_manifests" && $0 != "_analysis" }
            .sorted()

        var cases: [CaseInfo] = []
        for name in caseDirs {
            let caseURL = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: caseURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let good = countImages(in: caseURL.appendingPathComponent("good"))
            let bad = countImages(in: caseURL.appendingPathComponent("PRE-DELETE"))
            guard good + bad > 0 else { continue }

            let (scope, token) = parse(caseName: name)
            cases.append(CaseInfo(name: name, scope: scope, token: token, good: good, bad: bad))
        }
        return Report(root: root, cases: cases)
    }

    private static func countImages(in dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .count
    }

    /// Parse `<scope>_<fl>mm_<filter>_<target>_<expo>s__<token>` → (scope, token).
    /// Falls back gracefully for hand-made folder names.
    static func parse(caseName: String) -> (scope: String, token: String) {
        let parts = caseName.components(separatedBy: "__")
        let token = parts.count > 1 ? parts[1] : "other"
        let base = parts[0]
        let scope = base.components(separatedBy: "_").first ?? base
        return (scope.isEmpty ? "?" : scope, token.isEmpty ? "other" : token)
    }

    /// Human-readable multi-line summary (used by the window and status/log).
    static func summaryText(_ r: Report) -> String {
        guard !r.isEmpty else { return "No golden-set cases found under \(r.root.lastPathComponent)." }
        var lines: [String] = []
        lines.append("Golden set: \(r.cases.count) case(s), \(r.totalGood) good + \(r.totalBad) bad frames")
        lines.append("Scopes: \(r.scopes.joined(separator: ", "))   Defects: \(r.tokens.filter { $0 != "baseline" }.joined(separator: ", "))")
        lines.append("")
        for c in r.cases.sorted(by: { $0.name < $1.name }) {
            let mark = c.ok ? "✓" : "⚠"
            let need = c.isBaseline
                ? (c.good < minGoodPerCase ? "  (need ≥\(minGoodPerCase) good)" : "")
                : ((c.good < minGoodPerCase ? "  (need ≥\(minGoodPerCase) good)" : "") + (c.bad < minBadPerCase ? "  (need ≥\(minBadPerCase) bad)" : ""))
            lines.append("\(mark) \(c.name): good=\(c.good) bad=\(c.bad)\(need)")
        }
        return lines.joined(separator: "\n")
    }
}
