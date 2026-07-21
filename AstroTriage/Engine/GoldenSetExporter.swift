// Golden-set exporter — turns the user's in-app golden labels (ImageEntry.goldenLabel) into a
// curated calibration folder tree of file COPIES that AstroScoreCLI / GoldenMiniSetTests consume:
//
//   <root>/<CASE>__baseline/good/          good-only case (no defects labeled)
//   <root>/<CASE>__<token>/good/           good frames of the group
//   <root>/<CASE>__<token>/PRE-DELETE/     bad frames of that defect token
//
// Mirrors CuratedExport (folder + JSON manifest), but adds pixel COPIES partitioned by the exact
// scoring GroupKey so one case == one scoring group. Copies only — originals are never moved or
// deleted (Non-Negotiable Regel #1). Re-exporting merges idempotently (skips files already there),
// so curating across many sessions accumulates into one root.
//
// Not quality-critical (no scoring logic) — kAlgorithmVersion unaffected.

import Foundation
import AppKit

enum GoldenSetExporter {

    // MARK: - Interactive entry point (menu action)

    @MainActor
    static func runInteractive(viewModel: TriageViewModel) {
        let labeled = viewModel.images.filter { $0.goldenLabel != .none }
        guard !labeled.isEmpty else {
            let a = NSAlert()
            a.messageText = "No golden labels yet"
            a.informativeText = "Right-click frames → Golden Set ▸ Good / a defect, then export. "
                + "Tip: run Auto-Mark first, mark the keepers Good and tag the marked frames with their defect."
            a.addButton(withTitle: "OK"); a.runModal(); return
        }

        let panel = NSOpenPanel()
        panel.title = "Export Golden Set"
        panel.message = "Choose (or create) the golden-set ROOT folder. Frames are COPIED into it, grouped into cases."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }

        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        do {
            let result = try export(entries: labeled, into: root)
            viewModel.statusMessage = "Golden set: copied \(result.framesCopied) frame(s) into "
                + "\(result.casesWritten) case(s) — \(result.skipped) already present. See \(root.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([root])
            // Show the coverage of the whole root so the user sees whether there's enough material.
            GoldenSetCoverageWindowController.shared.show(root: root)
        } catch {
            viewModel.statusMessage = "Golden-set export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Export core

    struct ExportResult { var framesCopied = 0; var skipped = 0; var casesWritten = 0 }

    /// Group labeled entries by the exact scoring GroupKey, then per (group × defect-token) write a
    /// case folder of good/ + PRE-DELETE/ copies. Returns copy counts. Also writes a timestamped
    /// manifest under <root>/_manifests/ carrying each frame's metrics + label (for later
    /// human-label-vs-signal verification).
    static func export(entries rawEntries: [ImageEntry], into root: URL) throws -> ExportResult {
        let fm = FileManager.default
        // Match scoring's pre-filter: solar-system targets are never grouped/scored.
        let entries = rawEntries.filter { !QualityEstimator.isSolarSystemTarget($0.target) }

        // Group by the canonical scoring GroupKey (combined, not per-night) — same as MosaicGenerator.
        var groups: [GroupKey: [ImageEntry]] = [:]
        for e in entries { groups[GroupKey(entry: e, useNight: false), default: []].append(e) }

        var result = ExportResult()
        var manifestFrames: [ManifestFrame] = []

        for (key, groupEntries) in groups {
            let good = groupEntries.filter { $0.goldenLabel == .good }
            let badByToken = Dictionary(grouping: groupEntries.filter { $0.goldenLabel.isBad }) {
                $0.goldenLabel.token
            }
            let base = caseName(for: key, sample: groupEntries.first!)

            // Cases to write: one per defect token present; if none, a good-only baseline.
            var cases: [(name: String, good: [ImageEntry], bad: [ImageEntry])] = []
            if badByToken.isEmpty {
                if !good.isEmpty { cases.append(("\(base)__baseline", good, [])) }
            } else {
                for (token, bad) in badByToken { cases.append(("\(base)__\(token)", good, bad)) }
            }

            for c in cases {
                let caseDir = root.appendingPathComponent(c.name, isDirectory: true)
                let goodDir = caseDir.appendingPathComponent("good", isDirectory: true)
                let badDir = caseDir.appendingPathComponent("PRE-DELETE", isDirectory: true)
                try fm.createDirectory(at: goodDir, withIntermediateDirectories: true)
                if !c.bad.isEmpty { try fm.createDirectory(at: badDir, withIntermediateDirectories: true) }

                for e in c.good { copy(e, into: goodDir, result: &result) }
                for e in c.bad  { copy(e, into: badDir, result: &result) }
                result.casesWritten += 1

                for e in c.good { manifestFrames.append(ManifestFrame(entry: e, caseName: c.name, side: "good")) }
                for e in c.bad  { manifestFrames.append(ManifestFrame(entry: e, caseName: c.name, side: "PRE-DELETE")) }
            }
        }

        try writeManifest(frames: manifestFrames, into: root)
        return result
    }

    /// Copy one frame into a case subfolder, preserving its filename. Idempotent: if the target
    /// already exists (a prior export), it is skipped, not overwritten. Never touches the original.
    private static func copy(_ entry: ImageEntry, into dir: URL, result: inout ExportResult) {
        let dest = dir.appendingPathComponent(entry.filename)
        if FileManager.default.fileExists(atPath: dest.path) { result.skipped += 1; return }
        do { try FileManager.default.copyItem(at: entry.url, to: dest); result.framesCopied += 1 }
        catch { result.skipped += 1 }  // e.g. permission/scope failure — reported via total counts
    }

    // MARK: - Case naming (filesystem-safe, disambiguated so one folder ⊆ one GroupKey)

    /// `<scope>_<fl>mm_<filter>_<target>_<expo>s`. Encodes filter+FL+target+exposure so two distinct
    /// GroupKeys never collide into one folder name; the token is appended by the caller as `__<token>`.
    static func caseName(for key: GroupKey, sample: ImageEntry) -> String {
        let scope = sanitize(sample.telescope ?? "scope")
        let filter = sanitize(key.filter.isEmpty ? "nofilter" : key.filter)
        let target = sanitize(key.object.isEmpty ? "notarget" : key.object)
        return "\(scope)_\(key.focalLength)mm_\(filter)_\(target)_\(key.exposure)s"
    }

    /// Reduce to a filesystem- and readability-safe token: keep alphanumerics/._-, collapse the rest to '-'.
    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // collapse runs of '-' and trim
        let collapsed = mapped.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty
            ? "x" : collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    // MARK: - Manifest (metrics + label, for human-label-vs-signal verification)

    struct ManifestFrame: Codable {
        let filename, caseName, side, label: String
        let telescope, filter, target: String?
        let focalLength, exposure: Double?
        let fwhm, hfr, ecc, trailingScore, trailingConsensus: Double?
        let stars: Int?
        let noiseMedian, noiseMAD, snr: Double?

        init(entry e: ImageEntry, caseName: String, side: String) {
            filename = e.filename; self.caseName = caseName; self.side = side
            label = e.goldenLabel.token.isEmpty ? "good" : e.goldenLabel.token
            telescope = e.telescope; filter = e.filter; target = e.canonicalTarget ?? e.target
            focalLength = e.focalLength; exposure = e.exposure
            fwhm = e.computedFWHM; hfr = e.computedHFR; ecc = e.computedEccentricity
            trailingScore = e.trailingScore; trailingConsensus = e.trailingConsensus
            stars = e.computedStarCount
            noiseMedian = e.noiseMedian.map(Double.init); noiseMAD = e.noiseMAD.map(Double.init)
            if let m = e.noiseMedian, let d = e.noiseMAD, d > 0 { snr = Double(m / d) } else { snr = nil }
        }
    }

    private static func writeManifest(frames: [ManifestFrame], into root: URL) throws {
        let dir = root.appendingPathComponent("_manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd_HHmmss"
        let url = dir.appendingPathComponent("golden_export_\(f.string(from: Date())).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(frames).write(to: url, options: .atomic)
    }
}
