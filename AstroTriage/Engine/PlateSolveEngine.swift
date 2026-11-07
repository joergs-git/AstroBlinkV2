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
//
// v6.12.0 — a save may REPLACE a differing OBJECT (the backup copy is what makes that safe) and
// rename the files by a user-given A→B replacement; every touched file is recorded for undo.

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
    /// Frames whose OBJECT said something else and was replaced by the identified name. Until
    /// 6.11.4 the existing name always won; since 6.12.0 the user's choice wins, because the
    /// backup copy taken before every write is the safety net the old rule stood in for.
    var objectNamesReplaced: [(filename: String, existing: String, identified: String)] = []
    /// Files renamed by the A→B filename replacement (6.12.0).
    var renamed: Int = 0
    /// Every file this save touched: URL before → URL after (identical for a header-only
    /// write). Feeds the entry relocation in the view model and the shared batch undo stack.
    var affectedURLs: [URL: URL] = [:]
    /// The OBJECT value written per frame, so the view model can adopt it as the entry's
    /// target without re-reading headers.
    var objectWritten: [ImageEntry.ID: String] = [:]
    var writeFailures: [(filename: String, reason: String)] = []
    var backupDirectory: URL?
    var duration: TimeInterval = 0
    /// True when the user stopped the run; the frames not reached are simply absent.
    var wasCancelled = false

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
            return wasCancelled ? "Cancelled before any frame was solved." : "Nothing to solve."
        }
        let rate = attempted > 0 ? Int((Double(solved.count) / Double(attempted)) * 100) : 0
        var base = "Solved \(solved.count) of \(attempted) frames (\(rate)%) in "
                 + String(format: "%.1f s", duration)
        // Name the frames that were never attempted. Without this a run over 381 frames where
        // 375 already carried a solve reported "6 of 6 (100%)" and read as if the other 375
        // had been forgotten.
        if skippedAlreadySolved > 0 {
            base += " · \(skippedAlreadySolved) skipped, already solved"
        }
        // Say so plainly: the frames never reached are simply absent from the table, and a
        // silently short list would read as "these were all there were".
        return wasCancelled ? base + " — CANCELLED, remaining frames not solved" : base
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

// MARK: - Write options (6.12.0)

/// "Replace A with B in the filename" — plain text, case-sensitive, every occurrence.
struct FilenameReplacement: Equatable {
    var search: String
    var replacement: String

    /// A rename needs something to look for, must change the name, and may not introduce a path
    /// separator (that would be a move, not a rename). An empty search string would match
    /// everywhere — the classic `"".replace` footgun.
    var isUsable: Bool {
        !search.isEmpty && search != replacement && !replacement.contains("/")
    }
}

/// What a save writes: which frames, whether the identified object goes into OBJECT, and an
/// optional filename replacement. Decided in the result window, after the run.
struct PlateSolveWriteOptions {
    var scope: PlateSolveSaveScope = .all
    var writeObjectName: Bool = true
    var rename: FilenameReplacement?
}

// MARK: - Pre-save preview (6.12.0)

extension PlateSolveReport {
    /// One frame whose OBJECT the save would set: the value the entry carries now (from the
    /// header, else the filename) and the identified name that replaces it.
    struct ObjectChange {
        let frame: SolvedFrame
        let existing: String
        let new: String
    }

    /// An existing → new pair and how many frames share it.
    struct ObjectPair {
        let existing: String
        let new: String
        var count: Int
    }

    /// Frames in `scope` whose OBJECT would be written. Uses the header-enriched entry value and
    /// no file access — the write itself re-reads the header, so this is the preview the save
    /// bar shows, not the decision.
    func objectChanges(in scope: PlateSolveSaveScope) -> [ObjectChange] {
        scope.frames(in: self).compactMap { frame in
            guard let identification = frame.identification else { return nil }
            let existing = (frame.entry.target ?? "").trimmingCharacters(in: .whitespaces)
            guard existing.caseInsensitiveCompare(identification.headerValue) != .orderedSame else { return nil }
            return ObjectChange(frame: frame, existing: existing, new: identification.headerValue)
        }
    }

    /// The most frequent existing → new pair among `changes` (frames with an empty OBJECT have
    /// nothing to replace and are left out): the preview's example and the prefill of the rename
    /// fields. Ties go to the alphabetically first pair.
    static func dominantPair(of changes: [ObjectChange]) -> ObjectPair? {
        var pairs: [String: ObjectPair] = [:]
        for change in changes where !change.existing.isEmpty {
            let key = change.existing.lowercased() + "→" + change.new.lowercased()
            pairs[key, default: ObjectPair(existing: change.existing, new: change.new, count: 0)].count += 1
        }
        return pairs.values.max { a, b in
            a.count != b.count ? a.count < b.count : (a.existing + a.new) > (b.existing + b.new)
        }
    }

    /// Frames in `scope` the A→B replacement would rename, with their new names.
    func renamePreview(in scope: PlateSolveSaveScope,
                       replacement: FilenameReplacement) -> [(frame: SolvedFrame, newName: String)] {
        scope.frames(in: self).compactMap { frame in
            PlateSolveEngine.renamedFilename(for: frame, replacement: replacement).map { (frame, $0) }
        }
    }
}

// MARK: - Engine

final class PlateSolveEngine {

    /// ASTAP is single-threaded per frame; a small cap keeps the disk sequentialish.
    private let maxConcurrent: Int
    /// The interactive command runs at user-initiated priority; the on-load background solve
    /// (6.11.0) drops to utility with two processes so culling stays responsive.
    private let qualityOfService: QualityOfService

    private let solver = ASTAPSolver()

    init(maxConcurrent: Int = 4, qualityOfService: QualityOfService = .userInitiated) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.qualityOfService = qualityOfService
    }
    private let fm = FileManager.default

    /// Set by `cancel()` from the main thread and read by every worker. Guarded rather than
    /// atomic-by-hope: it is written while up to four operations are reading it.
    private let cancelLock = NSLock()
    private var isCancelled = false

    /// Stop the run. Frames already in flight finish (ASTAP is a separate process and killing
    /// it mid-solve buys nothing); nothing further is started.
    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }

    private var cancelRequested: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return isCancelled
    }

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
               progress: @escaping (Int, Int, String) -> Void) -> PlateSolveReport {

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
        queue.qualityOfService = qualityOfService

        for entry in todo {
            queue.addOperation { [solver] in
                // Queued work that has not started yet is dropped on cancel; the frames simply
                // do not appear in the report.
                guard !self.cancelRequested else { return }

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

                progress(done, todo.count, entry.filename)
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        report.wasCancelled = cancelRequested
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
    /// - Parameter options: which frames, whether to name the object in OBJECT, and an optional
    ///   filename replacement. OBJECT is written whenever the header does not already carry the
    ///   identified name — a DIFFERENT existing name is replaced (6.12.0; the backup copy is what
    ///   makes that safe, and every replacement is listed in the report). The rename applies only
    ///   to frames `renamedFilename(for:replacement:)` accepts, after the header write has
    ///   verified, under the Change Filter contract: an existing target is never overwritten and
    ///   any failure restores the frame from its backup.
    func writeBack(_ report: inout PlateSolveReport,
                   sessionRoot: URL,
                   options: PlateSolveWriteOptions = PlateSolveWriteOptions()) {
        let frames = options.scope.frames(in: report)
        guard !frames.isEmpty else { return }

        // Reset the write tallies: the report is handed back to the result window, which may
        // offer another attempt, and stale counts would read as a bigger success than it was.
        report.written = 0
        report.objectNamesWritten = 0
        report.objectNamesReplaced.removeAll()
        report.renamed = 0
        report.affectedURLs.removeAll()
        report.objectWritten.removeAll()
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
        // Frames whose file moved during this save, so the report's own entries can follow.
        var relocations: [ImageEntry.ID: URL] = [:]

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

            // OBJECT: written when the header does not already carry the identified name. A
            // DIFFERENT existing name is replaced — the backup copy taken above is the safety
            // net. Until 6.11.4 the old name always won, which left five NGC 6888 frames
            // labelled M45 after a save that reported it had named the object.
            var objectValue: String?
            var replacedExisting: String?
            if options.writeObjectName, let identification = frame.identification {
                let existing = BatchOperations.readHeaderValue(url: url, keyword: "OBJECT")?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if existing.caseInsensitiveCompare(identification.headerValue) != .orderedSame {
                    pairs.append(("OBJECT", identification.headerValue))
                    objectValue = identification.headerValue
                    if !existing.isEmpty { replacedExisting = existing }
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

            // Rename only after the header write verified, so a frame is never left half done.
            // A failed move leaves the file at `url`, which the restore below covers.
            var finalURL = url
            if failure == nil, let replacement = options.rename,
               let newName = Self.renamedFilename(for: frame, replacement: replacement) {
                let target = url.deletingLastPathComponent().appendingPathComponent(newName)
                if fm.fileExists(atPath: target.path) {
                    failure = "rename target already exists: \(newName)"
                } else {
                    do {
                        try fm.moveItem(at: url, to: target)
                        finalURL = target
                    } catch {
                        failure = "rename failed: \(error.localizedDescription)"
                    }
                }
            }

            if let failure {
                try? fm.removeItem(at: url)
                try? fm.copyItem(at: backupURL, to: url)
                report.writeFailures.append((filename: frame.entry.filename, reason: failure))
            } else {
                report.written += 1
                report.affectedURLs[url] = finalURL
                if finalURL != url {
                    report.renamed += 1
                    relocations[frame.entry.id] = finalURL
                }
                if let objectValue, let identification = frame.identification {
                    report.objectNamesWritten += 1
                    report.objectWritten[frame.entry.id] = objectValue
                    if let replacedExisting {
                        report.objectNamesReplaced.append((filename: frame.entry.filename,
                                                           existing: replacedExisting,
                                                           identified: identification.displayName))
                    }
                }
            }
        }

        // Let the report's own frames follow what is now on disk, so the result table and a
        // later preview see the current names.
        if !relocations.isEmpty || !report.objectWritten.isEmpty {
            report.solved = report.solved.map { frame in
                let newURL = relocations[frame.entry.id]
                let newTarget = report.objectWritten[frame.entry.id]
                guard newURL != nil || newTarget != nil else { return frame }
                return SolvedFrame(entry: frame.entry.relocated(to: newURL ?? frame.entry.url,
                                                                newTarget: newTarget),
                                   solution: frame.solution,
                                   previous: frame.previous,
                                   identification: frame.identification)
            }
        }
    }

    /// The filename a frame gets from the A→B replacement, or nil when the rename does not apply
    /// to it: no identification, A absent from the name, a name that would not change — or the
    /// frame actually IS the object A names (by `TargetCatalog.canonicalName`), so a folder of
    /// 30 real M45 frames plus 5 frames of NGC 6888 mislabelled "M45" renames only the five.
    /// Independent of whether OBJECT changes in this save: a rename forgotten the first time
    /// still works on the second run, when the header is already correct.
    static func renamedFilename(for frame: SolvedFrame, replacement: FilenameReplacement) -> String? {
        guard replacement.isUsable, let identification = frame.identification else { return nil }
        let identified = identification.headerValue
        let searched = replacement.search.trimmingCharacters(in: .whitespaces)
        if searched.caseInsensitiveCompare(identified) == .orderedSame
            || TargetCatalog.canonicalName(searched).caseInsensitiveCompare(identified) == .orderedSame {
            return nil
        }
        let name = frame.entry.filename
        guard name.contains(replacement.search) else { return nil }
        let renamed = name.replacingOccurrences(of: replacement.search, with: replacement.replacement)
        return renamed == name ? nil : renamed
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
