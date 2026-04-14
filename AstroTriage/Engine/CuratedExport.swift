// Curated dataset export — writes every user-rated frame (userConfidence > 0)
// as CSV + JSON manifest for offline regression testing and algorithm analysis.
// Option A of the curation plan: metrics-only, no pixel copies. Regression tests
// read these files and open the original NAS/SSD images on demand.
//
// Output:
//   <destination>/curated_dataset_YYYYMMDD_HHMMSS/
//     ├── curated_dataset.csv       — flat table, one row per rated frame
//     ├── curated_manifest.json     — structured snapshot with summary + records
//     └── curated_summary.txt       — human-readable overview per setup × filter × rating
import Foundation
import AppKit

enum CuratedExport {

    // MARK: - Public entry point

    /// Show a folder picker, export curated records to a timestamped subfolder, then
    /// surface a success alert or error via the view model's status bar.
    @MainActor
    static func runInteractive(viewModel: TriageViewModel) {
        let records: [FrameRecord]
        do {
            records = try FrameHistoryDatabase.shared.curatedFrameRecords()
        } catch {
            viewModel.statusMessage = "Curated export failed: \(error.localizedDescription)"
            return
        }

        guard !records.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No curated frames yet"
            alert.informativeText = """
                Nothing to export. Enter Blind Curation (⌘⇧B), rate frames with 1/2/3, \
                and try again once you have at least one rated frame.
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Export Curated Dataset"
        panel.message = "Choose a folder to save the curated dataset into"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let parent = panel.url else { return }

        do {
            let outputFolder = try writeExport(records: records, into: parent)
            viewModel.statusMessage = "Exported \(records.count) curated frames to \(outputFolder.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
        } catch {
            viewModel.statusMessage = "Curated export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Write logic

    /// Create the timestamped subfolder and write all three output files.
    /// Returns the URL of the created folder.
    static func writeExport(records: [FrameRecord], into parent: URL) throws -> URL {
        let timestamp = timestampString()
        let folderName = "curated_dataset_\(timestamp)"
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try writeCSV(records: records, to: folder.appendingPathComponent("curated_dataset.csv"))
        try writeJSON(records: records, to: folder.appendingPathComponent("curated_manifest.json"))
        try writeSummary(records: records, to: folder.appendingPathComponent("curated_summary.txt"))

        return folder
    }

    // MARK: - CSV

    /// CSV header — matches the field order below. Keep the two in sync.
    private static let csvHeader: [String] = [
        "fileHash", "shortId", "filename", "filePath",
        "observingNight", "captureDate", "captureTime", "sessionId",
        "telescope", "camera", "focalLength", "pixelSizeMicrons", "setupHash",
        "target", "canonicalTarget", "majorTarget",
        "filter", "exposure", "gain", "offsetVal", "binning",
        "pierSide", "rotatorAngle", "mount",
        "computedFWHM", "computedHFR", "computedStarCount", "computedEccentricity",
        "noiseMedian", "noiseMAD", "psfFlux",
        "trailingScore", "trailingPA", "trailingConsensus", "trailingAxisRatio",
        "starChainFraction",
        "sensorTemp", "focuserTemp", "ambientTemp", "twilightPhase",
        "moonIllumination", "moonDistance", "bortleClass",
        "qualityTier", "combinedZScore", "garbageReasons", "isLockedKeep",
        "filterTrailingMultiplier",
        "userConfidence", "qualityFeedback", "wasDeleted",
        "algorithmVersion", "recordedAt", "width", "height"
    ]

    private static func writeCSV(records: [FrameRecord], to url: URL) throws {
        var lines: [String] = [csvHeader.joined(separator: ",")]
        lines.reserveCapacity(records.count + 1)

        for r in records {
            lines.append(csvRow(for: r))
        }

        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
    }

    /// Build one CSV row. Broken out from writeCSV and constructed additively
    /// so the Swift type-checker doesn't time out on the 54-field literal.
    private static func csvRow(for r: FrameRecord) -> String {
        var row: [String] = []
        row.reserveCapacity(csvHeader.count)

        // Identity
        row.append(r.fileHash)
        row.append(r.shortId)
        row.append(r.filename)
        row.append(r.filePath)
        row.append(r.observingNight ?? "")
        row.append(r.captureDate ?? "")
        row.append(r.captureTime ?? "")
        row.append(r.sessionId)

        // Equipment
        row.append(r.telescope ?? "")
        row.append(r.camera ?? "")
        row.append(format(r.focalLength))
        row.append(format(r.pixelSizeMicrons))
        row.append(r.setupHash ?? "")

        // Target
        row.append(r.target ?? "")
        row.append(r.canonicalTarget ?? "")
        row.append(r.majorTarget ?? "")

        // Capture parameters
        row.append(r.filter ?? "")
        row.append(format(r.exposure))
        row.append(format(r.gain))
        row.append(format(r.offsetVal))
        row.append(r.binning ?? "")
        row.append(r.pierSide ?? "")
        row.append(format(r.rotatorAngle))
        row.append(r.mount ?? "")

        // Computed metrics (pixel-derived, the ground truth inputs)
        row.append(format(r.computedFWHM))
        row.append(format(r.computedHFR))
        row.append(format(r.computedStarCount))
        row.append(format(r.computedEccentricity))
        row.append(format(r.noiseMedian))
        row.append(format(r.noiseMAD))
        row.append(format(r.psfFlux))

        // Trailing analysis
        row.append(format(r.trailingScore))
        row.append(format(r.trailingPA))
        row.append(format(r.trailingConsensus))
        row.append(format(r.trailingAxisRatio))
        row.append(format(r.starChainFraction))

        // Environment
        row.append(format(r.sensorTemp))
        row.append(format(r.focuserTemp))
        row.append(format(r.ambientTemp))
        row.append(r.twilightPhase ?? "")
        row.append(format(r.moonIllumination))
        row.append(format(r.moonDistance))
        row.append(format(r.bortleClass))

        // Algorithm results (what we're validating against)
        row.append(format(r.qualityTier))
        row.append(format(r.combinedZScore))
        row.append(r.garbageReasons ?? "")
        row.append(String(r.isLockedKeep))
        row.append(format(r.filterTrailingMultiplier))

        // Ground truth labels
        row.append(String(r.userConfidence))
        row.append(String(r.qualityFeedback))
        row.append(String(r.wasDeleted))

        // Meta
        row.append(String(r.algorithmVersion))
        row.append(r.recordedAt)
        row.append(format(r.width))
        row.append(format(r.height))

        return row.map(csvEscape).joined(separator: ",")
    }

    /// Escape a CSV field per RFC 4180: wrap in quotes and double any embedded quotes
    /// when the field contains a comma, quote, newline, or carriage return.
    private static func csvEscape(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        if !needsQuoting { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - JSON manifest

    private static func writeJSON(records: [FrameRecord], to url: URL) throws {
        let summary = buildSummary(records: records)
        let manifest = CuratedManifest(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            algorithmVersion: kAlgorithmVersion,
            appVersion: MachineInfo.appVersion,
            totalFrames: records.count,
            summary: summary,
            records: records
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Human-readable summary

    private static func writeSummary(records: [FrameRecord], to url: URL) throws {
        let summary = buildSummary(records: records)
        var lines: [String] = []
        lines.append("Curated Dataset Summary")
        lines.append("Exported: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Algorithm version: \(kAlgorithmVersion)")
        lines.append("Total rated frames: \(records.count)")
        lines.append("")
        lines.append("By star rating:")
        lines.append("  ★1 (bad):  \(summary.ratingCounts["1"] ?? 0)")
        lines.append("  ★2 (fair): \(summary.ratingCounts["2"] ?? 0)")
        lines.append("  ★3 (good): \(summary.ratingCounts["3"] ?? 0)")
        lines.append("")
        lines.append("Per setup × filter × rating:")

        // Stable ordering: setup → filter → rating
        let sortedSetups = summary.bySetupFilterRating.keys.sorted()
        for setup in sortedSetups {
            lines.append("  \(setup):")
            let byFilter = summary.bySetupFilterRating[setup] ?? [:]
            let sortedFilters = byFilter.keys.sorted()
            for filter in sortedFilters {
                let counts = byFilter[filter] ?? [:]
                let s1 = counts["1"] ?? 0
                let s2 = counts["2"] ?? 0
                let s3 = counts["3"] ?? 0
                lines.append("    \(filter): ★1=\(s1)  ★2=\(s2)  ★3=\(s3)  (total \(s1 + s2 + s3))")
            }
        }
        lines.append("")
        lines.append("Per target type (canonicalTarget):")
        let byTarget = summary.byTarget.sorted { $0.value > $1.value }
        for (target, count) in byTarget.prefix(30) {
            lines.append("  \(target): \(count)")
        }

        let text = lines.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Summary computation

    private static func buildSummary(records: [FrameRecord]) -> CuratedSummary {
        // Rating keys are stored as strings ("1"/"2"/"3") so the JSON encoder
        // can serialize them — JSON only supports string keys in objects.
        var ratingCounts: [String: Int] = [:]
        var bySetupFilterRating: [String: [String: [String: Int]]] = [:]
        var byTarget: [String: Int] = [:]

        for r in records {
            let ratingKey = String(r.userConfidence)
            ratingCounts[ratingKey, default: 0] += 1

            let focalStr = r.focalLength.map { String(format: "%.0f", $0) } ?? "?"
            let setupKey: String
            if let scope = r.telescope {
                setupKey = "\(scope) (\(focalStr)mm)"
            } else if let hash = r.setupHash {
                setupKey = String(hash.prefix(8))
            } else {
                setupKey = "unknown"
            }
            let filterKey = (r.filter?.isEmpty == false ? r.filter! : "—")
            bySetupFilterRating[setupKey, default: [:]][filterKey, default: [:]][ratingKey, default: 0] += 1

            let targetKey = (r.canonicalTarget?.isEmpty == false ? r.canonicalTarget! : (r.target ?? "—"))
            byTarget[targetKey, default: 0] += 1
        }

        return CuratedSummary(
            ratingCounts: ratingCounts,
            bySetupFilterRating: bySetupFilterRating,
            byTarget: byTarget
        )
    }

    // MARK: - Helpers

    private static func format<T: CustomStringConvertible>(_ value: T?) -> String {
        guard let value = value else { return "" }
        if let d = value as? Double {
            return d.isFinite ? String(format: "%.6g", d) : ""
        }
        return value.description
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - JSON schema

/// Top-level manifest written to curated_manifest.json
struct CuratedManifest: Codable {
    let exportedAt: String
    let algorithmVersion: Int
    let appVersion: String
    let totalFrames: Int
    let summary: CuratedSummary
    let records: [FrameRecord]
}

/// Aggregated counts for quick inspection without walking all records.
/// All keys are strings because JSON objects can only have string keys —
/// rating counts use "1"/"2"/"3" instead of Int.
struct CuratedSummary: Codable {
    let ratingCounts: [String: Int]
    /// setup → filter → rating ("1"/"2"/"3") → count
    let bySetupFilterRating: [String: [String: [String: Int]]]
    let byTarget: [String: Int]
}
