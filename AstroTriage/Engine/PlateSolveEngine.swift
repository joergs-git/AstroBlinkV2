// PlateSolveEngine — batch plate solving of loaded frames via ASTAP.
//
// Orchestrates ASTAPLocator (where is ASTAP, may we read its star database) and ASTAPSolver
// (solve one frame) across a whole session, names the object each solved frame points at,
// compares against any solve the frame already carried, and optionally writes the result back
// into the files through AstroBlink's own verified header writer.
//
// Concurrency: ASTAP is single-threaded and largely I/O bound, so frames are solved in
// parallel with a small cap. More than a handful of concurrent processes just thrashes the
// disk — and on a NAS the read, not the solve, is the bottleneck.
//
// v6.9.0 — first increment: FITS only. XISF frames are reported as skipped; they need a
// temporary FITS export, which follows next.

import Foundation

// MARK: - Per-frame result

struct SolvedFrame {
    let entry: ImageEntry
    let solution: WCSSolution
    /// The WCS the frame already carried, when it had one and was re-solved.
    let previous: WCSSolution?
    /// The catalogued object at the solved centre, when one is close enough.
    let identification: TargetIdentification?

    /// How the fresh solve differs from the frame's existing one. Nil when there was none.
    var comparison: PlateSolveComparison? {
        guard let previous else { return nil }
        return PlateSolveComparison(existing: previous, fresh: solution)
    }

    /// Whether the frame's FOCALLEN/XPIXSZ agree with the scale the solve actually measured.
    var optics: OpticsConsistency {
        OpticsConsistency(solution: solution,
                          focalLengthMM: entry.focalLength,
                          pixelSizeMicrons: entry.pixelSizeMicrons,
                          binning: entry.binning)
    }
}

// MARK: - Report

struct PlateSolveReport {
    var solved: [SolvedFrame] = []
    var skippedAlreadySolved: Int = 0
    // Entries, not bare filenames: the result table lets the user click a row to jump to
    // that frame, which needs its identity.
    var skippedUnsupported: [ImageEntry] = []
    var failed: [(entry: ImageEntry, reason: String)] = []
    var written: Int = 0
    var objectNamesWritten: Int = 0
    /// Frames whose OBJECT keyword was left alone because it already said something else.
    var objectNamesKept: [(filename: String, existing: String, identified: String)] = []
    var writeFailures: [(filename: String, reason: String)] = []
    var backupDirectory: URL?
    var duration: TimeInterval = 0

    var attempted: Int { solved.count + failed.count }

    /// Frames whose fresh solve meaningfully disagrees with the one they already had.
    var disagreements: [SolvedFrame] {
        solved.filter { $0.comparison?.isSignificant == true }
    }

    /// Frames that were re-solved and came back confirming the existing WCS.
    var confirmations: Int {
        solved.filter { $0.comparison != nil && $0.comparison?.isSignificant == false }.count
    }

    /// Frames where writing would actually change the file: either it carried no WCS at all,
    /// or the fresh solve disagrees with the one it had. Writing a confirmed frame is a no-op
    /// that still rewrites the file, so it is worth being able to skip.
    var changedFrames: [SolvedFrame] {
        solved.filter { $0.previous == nil || $0.comparison?.isSignificant == true }
    }

    /// Frames whose FOCALLEN/XPIXSZ contradict the scale the solve measured.
    var opticsMismatches: [SolvedFrame] {
        solved.filter { $0.optics.isMismatch }
    }

    /// One-line outcome, shown at the top of the result window.
    var headline: String {
        if attempted == 0 && skippedUnsupported.isEmpty && skippedAlreadySolved == 0 {
            return "Nothing to solve."
        }
        let rate = attempted > 0 ? Int((Double(solved.count) / Double(attempted)) * 100) : 0
        return "Solved \(solved.count) of \(attempted) frames (\(rate)%) in "
             + String(format: "%.1f s", duration)
    }
}

/// Which solved frames to write back. The choice is offered AFTER solving — before the run
/// there is nothing to base it on, and "only the changed ones" cannot even be expressed until
/// the comparison exists.
enum PlateSolveSaveScope {
    case all
    case changedOnly

    func frames(in report: PlateSolveReport) -> [SolvedFrame] {
        switch self {
        case .all:         return report.solved
        case .changedOnly: return report.changedFrames
        }
    }
}

// MARK: - Engine

final class PlateSolveEngine {

    /// ASTAP is single-threaded per frame; a small cap keeps the disk sequentialish.
    private let maxConcurrent = 4

    private let solver = ASTAPSolver()
    private let fm = FileManager.default

    /// Solve `entries`, reporting progress as (completed, total).
    ///
    /// Blocking — call off the main thread. `binary` and `database` come from
    /// `ASTAPLocator.readiness()`; the caller keeps the database's security scope open for
    /// the whole run, since the spawned ASTAP processes inherit it.
    ///
    /// - Parameter skipAlreadySolved: when false, frames that already carry a WCS are solved
    ///   again and the result compared against what they had.
    func solve(entries: [ImageEntry],
               binary: URL,
               database: URL,
               skipAlreadySolved: Bool = true,
               progress: @escaping (Int, Int) -> Void) -> PlateSolveReport {

        let started = Date()
        var report = PlateSolveReport()

        // Partition up front so the progress total reflects real work, not skipped frames.
        var todo: [ImageEntry] = []
        for entry in entries {
            let hasWCS = WCSSolution(existingOn: entry) != nil
            if skipAlreadySolved, hasWCS {
                report.skippedAlreadySolved += 1
                continue
            }
            let ext = entry.url.pathExtension.lowercased()
            guard ASTAPSolver.supportedExtensions.contains(ext) else {
                report.skippedUnsupported.append(entry)
                continue
            }
            todo.append(entry)
        }

        guard !todo.isEmpty else {
            report.duration = Date().timeIntervalSince(started)
            return report
        }

        let lock = NSLock()
        var completed = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .userInitiated

        for entry in todo {
            queue.addOperation { [solver] in
                let fov = ASTAPSolver.fieldOfViewDegrees(
                    heightPixels: entry.height,
                    arcsecPerPixel: entry.arcsecPerPixel,
                    binning: entry.binning
                )
                let outcome = solver.solve(url: entry.url,
                                           fovDegrees: fov,
                                           binary: binary,
                                           database: database)

                lock.lock()
                switch outcome {
                case .solved(let solution):
                    // Name the field from the SOLVED scale, not the header's — the header is
                    // exactly what may be wrong on a frame we chose to re-solve.
                    let radius = TargetIdentifier.fieldRadiusArcmin(
                        widthPixels: entry.width,
                        heightPixels: entry.height,
                        arcsecPerPixel: solution.arcsecPerPixel
                    )
                    let identification = TargetIdentifier.identify(
                        raDeg: solution.crval1,
                        decDeg: solution.crval2,
                        fieldRadiusArcmin: radius
                    )
                    report.solved.append(SolvedFrame(
                        entry: entry,
                        solution: solution,
                        previous: WCSSolution(existingOn: entry),
                        identification: identification
                    ))
                case .skippedAlreadySolved:
                    report.skippedAlreadySolved += 1
                case .unsupportedFormat:
                    report.skippedUnsupported.append(entry)
                case .failed, .timedOut:
                    report.failed.append((entry: entry, reason: outcome.shortDescription))
                }
                completed += 1
                let done = completed
                lock.unlock()

                progress(done, todo.count)
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        report.duration = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - Write-back

    /// Write solved WCS keywords into the original files.
    ///
    /// Follows the same safety contract as `BatchOperations`: a mandatory backup copy first,
    /// then the write, then a read-back verify. A file that fails any step is restored from
    /// its backup and the run continues — a partial batch never aborts the rest.
    ///
    /// `sessionRoot` must be writable; the caller is expected to have gone through
    /// `TriageViewModel.ensureWritableSessionRoot()` (reconstructed common-ancestor URLs
    /// carry no security scope — that is the NAS bug fixed in 6.5.2).
    ///
    /// - Parameter writeObjectName: also write the identified object into OBJECT. An OBJECT
    ///   that already says something different is NEVER overwritten — the user's or NINA's
    ///   own naming wins, and the discrepancy is reported instead.
    func writeBack(_ report: inout PlateSolveReport,
                   sessionRoot: URL,
                   scope: PlateSolveSaveScope = .all,
                   writeObjectName: Bool = false) {
        let frames = scope.frames(in: report)
        guard !frames.isEmpty else { return }

        // Reset the write tallies: the report is handed back to the result window, which may
        // offer another attempt, and stale counts would read as a bigger success than it was.
        report.written = 0
        report.objectNamesWritten = 0
        report.objectNamesKept.removeAll()
        report.writeFailures.removeAll()

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = sessionRoot.appendingPathComponent("_platesolve_backup_\(timestamp)")

        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            report.writeFailures.append((filename: "(backup folder)",
                                         reason: "could not create backup folder: \(error.localizedDescription)"))
            return
        }
        report.backupDirectory = backupDir

        for frame in frames {
            let url = frame.entry.url
            let backupURL = backupDir.appendingPathComponent(frame.entry.filename)

            do {
                if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
                try fm.copyItem(at: url, to: backupURL)
            } catch {
                report.writeFailures.append((filename: frame.entry.filename,
                                             reason: "backup failed: \(error.localizedDescription)"))
                continue
            }

            var pairs = Self.keywords(for: frame.solution)

            // OBJECT is only ever filled in, never overwritten.
            var writesObject = false
            if writeObjectName, let identification = frame.identification {
                let existing = BatchOperations.readHeaderValue(url: url, keyword: "OBJECT")?
                    .trimmingCharacters(in: .whitespaces)
                if let existing, !existing.isEmpty,
                   existing.caseInsensitiveCompare(identification.headerValue) != .orderedSame {
                    report.objectNamesKept.append((filename: frame.entry.filename,
                                                   existing: existing,
                                                   identified: identification.displayName))
                } else if existing?.isEmpty ?? true {
                    pairs.append(("OBJECT", identification.headerValue))
                    writesObject = true
                }
            }

            // Write the whole set in as few file rewrites as possible, then verify it in a
            // single pass. Doing either per keyword rewrites and re-parses a 116 MB XISF once
            // per keyword — fine on an SSD, gigabytes of traffic over a NAS.
            var failure = BatchOperations.writeHeaders(url: url, values: pairs)

            if failure == nil {
                // Read-back verify: a silent no-op write would otherwise look like success.
                let readBack = BatchOperations.readHeaderValues(url: url,
                                                                keywords: pairs.map(\.0))
                for (keyword, value) in pairs {
                    guard let stored = readBack[keyword.uppercased()],
                          Self.matches(written: value, readBack: stored) else {
                        failure = "\(keyword) did not read back"
                        break
                    }
                }
            }

            if let failure {
                try? fm.removeItem(at: url)
                try? fm.copyItem(at: backupURL, to: url)
                report.writeFailures.append((filename: frame.entry.filename, reason: failure))
            } else {
                report.written += 1
                if writesObject { report.objectNamesWritten += 1 }
            }
        }
    }

    /// The keywords a solved frame gains, in the exact spelling `MetadataExtractor` reads.
    static func keywords(for s: WCSSolution) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("CRVAL1", format(s.crval1)),
            ("CRVAL2", format(s.crval2)),
            ("CRPIX1", format(s.crpix1)),
            ("CRPIX2", format(s.crpix2)),
            ("CD1_1",  format(s.cd11)),
            ("CD1_2",  format(s.cd12)),
            ("CD2_1",  format(s.cd21)),
            ("CD2_2",  format(s.cd22)),
            // Mark the frame as solved, the same way ASTAP and NINA do.
            ("CTYPE1", "RA---TAN"),
            ("CTYPE2", "DEC--TAN")
        ]
        if let crota2 = s.crota2 { pairs.append(("CROTA2", format(crota2))) }
        return pairs
    }

    /// Enough digits that the CD matrix survives the round trip: its elements are ~1e-5
    /// degrees/pixel, so fixed-point formatting would quantise the plate scale away.
    private static func format(_ value: Double) -> String {
        String(format: "%.12G", value)
    }

    /// Header round-tripping reformats numbers (cfitsio may return `1.0E-05` for `1E-05`),
    /// so compare numerically where both sides are numbers, textually otherwise.
    private static func matches(written: String, readBack: String) -> Bool {
        if let a = Double(written), let b = Double(readBack) {
            let scale = max(abs(a), abs(b), 1e-12)
            return abs(a - b) <= scale * 1e-6
        }
        return written.trimmingCharacters(in: .whitespaces)
            == readBack.trimmingCharacters(in: .whitespaces)
    }
}
