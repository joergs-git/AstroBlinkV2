// Golden-set coverage reader — walks a golden-set root produced by GoldenSetExporter and reports
// how much material exists per case, so the user can see whether the set is big/broad enough to
// tune against. Read-only.
//
// A case == one scoring GroupKey (folder `<scope>_<fl>_<filter>_<target>_<expo>s`), with good/ +
// PRE-DELETE/. Good frames are shared across the group's defects (written once), so a case is NOT
// per-defect. The per-defect breakdown of the bad frames is read from the export manifests.

import Foundation

enum GoldenSetCoverage {

    // Curation targets (from the golden-set spec).
    static let minGoodPerCase = 12
    static let minBadPerCase = 6

    struct CaseInfo: Identifiable {
        var id: String { name }
        let name: String
        let scope: String            // parsed from the case-name prefix
        let good: Int
        let bad: Int
        let defects: [String: Int]   // token → count of bad frames (from manifest); may be empty

        /// A good-only baseline (no bad frames labeled for this group).
        var isBaseline: Bool { bad == 0 }
        /// Meets the per-case targets: good ≥ 12, and (baseline) or bad ≥ 6.
        var ok: Bool { good >= minGoodPerCase && (isBaseline || bad >= minBadPerCase) }
        /// "trail 4 · dark 5 · gradient 10" — the defect mix, or "" if unknown / baseline.
        var defectSummary: String {
            defects.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        }
    }

    struct Report {
        let root: URL
        let cases: [CaseInfo]
        var totalGood: Int { cases.reduce(0) { $0 + $1.good } }
        var totalBad: Int { cases.reduce(0) { $0 + $1.bad } }
        var scopes: [String] { Array(Set(cases.map { $0.scope })).sorted() }
        /// All distinct defect tokens seen across the set.
        var defects: [String] { Array(Set(cases.flatMap { $0.defects.keys })).sorted() }
        var isEmpty: Bool { cases.isEmpty }
        /// Groups that have bad frames but no good baseline — cannot be scored until good frames are added.
        var casesMissingGood: [CaseInfo] { cases.filter { $0.good == 0 && $0.bad > 0 } }
    }

    private static let imageExtensions: Set<String> = ["fit", "fits", "fts", "xisf"]

    static func scan(root: URL) -> Report {
        let fm = FileManager.default
        let tokenByFile = manifestTokens(root: root)   // filename → defect token, from manifests

        let caseDirs = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "_manifests" && $0 != "_analysis" }
            .sorted()

        var cases: [CaseInfo] = []
        for name in caseDirs {
            let caseURL = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: caseURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let goodFiles = imageFiles(in: caseURL.appendingPathComponent("good"))
            let badFiles = imageFiles(in: caseURL.appendingPathComponent("PRE-DELETE"))
            guard goodFiles.count + badFiles.count > 0 else { continue }

            // Per-defect breakdown of the bad frames (from manifest; "?" if not recorded).
            var defects: [String: Int] = [:]
            for f in badFiles { defects[tokenByFile[f] ?? "?", default: 0] += 1 }

            let scope = name.components(separatedBy: "_").first ?? name
            cases.append(CaseInfo(name: name, scope: scope.isEmpty ? "?" : scope,
                                  good: goodFiles.count, bad: badFiles.count, defects: defects))
        }
        return Report(root: root, cases: cases)
    }

    private static func imageFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    /// Minimal decode of the export manifests → filename → defect token (bad frames only).
    /// Later manifests win on collisions (a re-labeled/re-exported frame).
    private struct ManifestRow: Codable { let filename: String; let side: String; let label: String }
    private static func manifestTokens(root: URL) -> [String: String] {
        let dir = root.appendingPathComponent("_manifests")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()   // sorted → newest (timestamped) last, wins
        var map: [String: String] = [:]
        for f in files {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let rows = try? JSONDecoder().decode([ManifestRow].self, from: data) else { continue }
            for r in rows where r.side == "PRE-DELETE" { map[r.filename] = r.label }
        }
        return map
    }

    /// Human-readable multi-line summary (used by the window and status/log).
    static func summaryText(_ r: Report) -> String {
        guard !r.isEmpty else { return "No golden-set cases found under \(r.root.lastPathComponent)." }
        var lines: [String] = []
        lines.append("Golden set: \(r.cases.count) case(s), \(r.totalGood) good + \(r.totalBad) bad frames")
        lines.append("Scopes: \(r.scopes.joined(separator: ", "))   Defects: \(r.defects.joined(separator: ", "))")
        lines.append("")
        for c in r.cases.sorted(by: { $0.name < $1.name }) {
            let mark = c.ok ? "✓" : "⚠"
            let mix = c.defectSummary.isEmpty ? "" : "  [\(c.defectSummary)]"
            lines.append("\(mark) \(c.name): good=\(c.good) bad=\(c.bad)\(mix)")
        }
        return lines.joined(separator: "\n")
    }
}
