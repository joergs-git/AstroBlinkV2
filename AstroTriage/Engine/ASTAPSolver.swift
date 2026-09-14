// ASTAPSolver — runs ASTAP on one frame and returns the astrometric solution.
//
// Two rules shape this file, both learned by measurement rather than from the docs:
//
//  1. ASTAP HANGS FOREVER on anything it cannot process. It is a GUI application that runs
//     headless when given `-f`; when it fails (unreadable image, unreachable star database)
//     it falls back to opening its window and waits for a human. Observed twice during the
//     feasibility spike. A bare `waitUntilExit()` would therefore deadlock the caller — every
//     run gets a hard deadline and a SIGKILL.
//
//  2. ASTAP NEVER TOUCHES THE ORIGINAL. It writes its results as `<name>.ini` / `<name>.wcs`
//     sidecars next to its input, and `-update` rewrites the image in place. Both are wrong
//     here: the originals live in the user's session folders (often a read-only NAS share),
//     and littering or rewriting them is not ours to do. The frame is copied into our own
//     container first and ASTAP only ever sees that copy. Writing the solution back into the
//     original is a separate, explicit step through AstroBlink's own verified header writer.
//
// v6.9.0

import Foundation

// MARK: - Solution

/// The astrometric solution, in exactly the terms `MetadataExtractor` already reads out of
/// FITS/XISF headers — so a solved frame is indistinguishable from one that arrived solved.
struct WCSSolution: Equatable {
    let crval1: Double      // center RA, degrees
    let crval2: Double      // center Dec, degrees
    let crpix1: Double
    let crpix2: Double
    let cd11: Double
    let cd12: Double
    let cd21: Double
    let cd22: Double
    let crota2: Double?

    /// Pixel scale implied by the CD matrix, in arcsec/pixel. Handy as a sanity check
    /// against the scale derived from focal length and pixel size.
    var arcsecPerPixel: Double {
        (cd11 * cd11 + cd21 * cd21).squareRoot() * 3600.0
    }
}

// MARK: - Outcome

enum PlateSolveOutcome: Equatable {
    case solved(WCSSolution)
    case skippedAlreadySolved
    case unsupportedFormat(String)
    case failed(reason: String)
    case timedOut(seconds: Int)

    var isSolved: Bool { if case .solved = self { return true }; return false }

    var shortDescription: String {
        switch self {
        case .solved:                     return "solved"
        case .skippedAlreadySolved:       return "already had WCS"
        case .unsupportedFormat(let ext): return "unsupported format (.\(ext))"
        case .failed(let reason):         return reason
        case .timedOut(let s):            return "timed out after \(s)s"
        }
    }
}

// MARK: - Solver

final class ASTAPSolver {

    /// Formats ASTAP can read. XISF is deliberately absent: ASTAP answers
    /// `ERROR=Error reading image file.` and then hangs on its GUI. XISF frames are handled
    /// by converting to a temporary FITS first (next increment).
    static let supportedExtensions: Set<String> = ["fit", "fits", "fts"]

    /// Per-frame deadline. A hinted solve takes ~0.3 s and a blind one ~4 s, so 60 s is far
    /// beyond any legitimate run and only ever fires on the hang described above.
    var timeoutSeconds: TimeInterval = 60

    private let fm = FileManager.default

    // MARK: Entry point

    /// Solve one frame. Blocking — call off the main thread.
    ///
    /// - Parameters:
    ///   - url: the frame. Must already be readable (security scope held by the caller).
    ///   - fovDegrees: field height in degrees. Supplying it is what makes the solve take
    ///     0.3 s instead of 4.2 s; pass nil to let ASTAP search for the scale.
    func solve(url: URL,
               fovDegrees: Double?,
               binary: URL,
               database: URL) -> PlateSolveOutcome {

        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            return .unsupportedFormat(ext)
        }

        // Scratch directory inside our container — this is what ASTAP writes into.
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astap-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .failed(reason: "could not create scratch directory: \(error.localizedDescription)")
        }

        let copy = work.appendingPathComponent("frame.\(ext)")
        do {
            try fm.copyItem(at: url, to: copy)
        } catch {
            return .failed(reason: "could not read frame: \(error.localizedDescription)")
        }

        // A wrong FOV hint only costs speed, never correctness — ASTAP reports "inexact
        // scale" and solves anyway. But if the hinted attempt fails outright, retry blind
        // before giving up, since a bad FOCALLEN header is common.
        var outcome = run(image: copy, fovDegrees: fovDegrees, binary: binary, database: database)
        if case .failed = outcome, fovDegrees != nil {
            outcome = run(image: copy, fovDegrees: nil, binary: binary, database: database)
        }
        return outcome
    }

    // MARK: Process

    private func run(image: URL,
                     fovDegrees: Double?,
                     binary: URL,
                     database: URL) -> PlateSolveOutcome {

        var arguments = [
            "-f", image.path,
            "-d", database.path,
            "-wcs"                      // write the solution as sidecars, do not touch the image
        ]
        if let fovDegrees, fovDegrees > 0 {
            arguments += ["-fov", String(format: "%.4f", fovDegrees)]
            // With a scale hint a tight search radius around the header position is enough.
            arguments += ["-r", "30"]
        } else {
            arguments += ["-fov", "0"]  // let ASTAP search for the scale
            arguments += ["-r", "180"]
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // ASTAP is chatty; the pipes are drained after exit, and a hung run is killed before
        // it can ever fill them.
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failed(reason: "could not launch ASTAP: \(error.localizedDescription)")
        }

        // Rule 1: hard deadline. terminate() first, SIGKILL if it ignores that.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return .timedOut(seconds: Int(timeoutSeconds))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let iniURL = image.deletingPathExtension().appendingPathExtension("ini")
        guard let ini = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return .failed(reason: "ASTAP produced no result file")
        }
        return Self.parse(ini: ini)
    }

    // MARK: .ini parsing

    /// Parse ASTAP's result file. It is plain `KEY=value`, and its keys are exactly the WCS
    /// keywords the rest of AstroBlink already understands.
    ///
    ///     PLTSOLVD=T
    ///     CRVAL1= 8.3840512504517406E+001
    ///     CD1_1=-5.2207656483851631E-005
    ///     ...
    ///     ERROR=Error reading image file.       (on failure)
    static func parse(ini: String) -> PlateSolveOutcome {
        var values: [String: String] = [:]
        for line in ini.split(separator: "\n") {
            // Split on the FIRST '=' only: CMDLINE= and ERROR= contain further '=' and text.
            guard let sep = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<sep]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        guard values["PLTSOLVD"] == "T" else {
            if let error = values["ERROR"], !error.isEmpty {
                return .failed(reason: error)
            }
            return .failed(reason: "no solution found")
        }

        func number(_ key: String) -> Double? { values[key].flatMap(Double.init) }

        guard let crval1 = number("CRVAL1"), let crval2 = number("CRVAL2"),
              let crpix1 = number("CRPIX1"), let crpix2 = number("CRPIX2"),
              let cd11 = number("CD1_1"), let cd12 = number("CD1_2"),
              let cd21 = number("CD2_1"), let cd22 = number("CD2_2")
        else {
            // Solved but incomplete — treat as failure rather than writing a partial WCS.
            return .failed(reason: "solution was incomplete")
        }

        return .solved(WCSSolution(
            crval1: crval1, crval2: crval2,
            crpix1: crpix1, crpix2: crpix2,
            cd11: cd11, cd12: cd12, cd21: cd21, cd22: cd22,
            crota2: number("CROTA2")
        ))
    }

    // MARK: Field of view

    /// Field HEIGHT in degrees, which is what ASTAP's `-fov` expects.
    ///
    /// `ImageEntry.arcsecPerPixel` deliberately ignores binning (it feeds quality scoring and
    /// must not change), so binning is applied here: XPIXSZ is the physical pixel size, and a
    /// 2×2 binned frame covers twice the sky per stored pixel.
    static func fieldOfViewDegrees(heightPixels: Int?,
                                   arcsecPerPixel: Double?,
                                   binning: String?) -> Double? {
        guard let heightPixels, heightPixels > 0,
              let arcsecPerPixel, arcsecPerPixel > 0 else { return nil }

        let factor = binningFactor(binning)
        let degrees = Double(heightPixels) * arcsecPerPixel * factor / 3600.0

        // Outside this range the hint is more likely a broken header than a real field, and
        // a nonsense hint costs more than no hint at all.
        guard degrees > 0.01, degrees < 90 else { return nil }
        return degrees
    }

    /// "2x2" → 2. Unknown or unparseable → 1.
    static func binningFactor(_ binning: String?) -> Double {
        guard let binning else { return 1 }
        let head = binning.lowercased().split(separator: "x").first
        guard let head, let value = Double(head), value >= 1, value <= 8 else { return 1 }
        return value
    }
}
