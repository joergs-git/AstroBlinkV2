// v1.1.0 (v5.22.1: merge root files + subfolders in one pass; PRE-DELETE auto-skip)
import Foundation

// Scans a folder for FITS/XISF files:
// - Always merges root-level image files AND subfolder content into a single list
//   (pre-v5.22.1 short-circuited to root-only when any root file was present, which
//   silently hid everything under per-filter subfolders when a stray file sat at root).
// - Calibration frames (DARK, FLAT, BIAS) are excluded by default (folder scan only).
// - PRE-DELETE / _predel folders are auto-skipped during recursion (depth > 0) BUT
//   load normally when the user explicitly picks one as the top-level rootURL
//   (e.g. to review / restore previously culled frames).
struct SessionScanner {

    static let supportedExtensions: Set<String> = ["xisf", "fits", "fit", "fts"]
    static let defaultMaxDepth = 3

    // Calibration keywords for folder-level detection (case-insensitive substring match).
    // "dark" also catches "darkflat", "masterdark", "Dark_Frames" etc.
    private static let calibrationKeywords = ["dark", "flat", "bias"]

    // PRE-DELETE folder names we auto-skip during subfolder recursion.
    // User can still explicitly open one of these as rootURL to review deleted frames.
    // Case-insensitive exact match — does not match arbitrary folders containing "delete".
    private static let preDeleteFolderNames: Set<String> = ["_predel", "pre-delete", "predelete"]

    // True iff the given folder name matches any configured PRE-DELETE name (case-insensitive).
    private static func isPreDeleteFolder(_ folderName: String) -> Bool {
        return preDeleteFolderNames.contains(folderName.lowercased())
    }

    // Check if a folder name contains any calibration keyword (case-insensitive)
    // Used for folder-level exclusion where substring matching is appropriate
    // (folders named "Dark", "FlatFrames", "BiasFrames" etc.)
    static func isFolderCalibration(_ folderName: String) -> Bool {
        let lower = folderName.lowercased()
        return calibrationKeywords.contains { lower.contains($0) }
    }

    // Check if a filename indicates a calibration frame.
    // First tries NINA filename parsing to extract the frame type token (DARK/FLAT/BIAS/LIGHT).
    // If a frame type is found:
    //   - LIGHT → NOT calibration (even if target name contains "dark"/"flat")
    //   - DARK/FLAT/BIAS → IS calibration
    // If no frame type found (non-NINA filename): fall back to keyword substring match.
    static func isFileCalibration(_ filename: String) -> Bool {
        let tokens = NINAFilenameParser.parse(filename)
        if let frameType = tokens.frameType?.uppercased() {
            // Frame type explicitly parsed → use it (avoids false positives)
            return frameType == "DARK" || frameType == "FLAT" || frameType == "BIAS"
        }
        // No frame type token found → fall back to keyword matching for non-NINA files
        let lower = filename.lowercased()
        return calibrationKeywords.contains { lower.contains($0) }
    }

    // Scan a root folder. Always recurses into subfolders AND picks up root-level
    // files — a parent folder with a stray .fits plus per-filter subdirs now yields
    // both in a single session. Calibration subfolders/frames are excluded when
    // lightsOnly is true.
    static func scan(rootURL: URL, maxDepth: Int = defaultMaxDepth, lightsOnly: Bool = true) -> [ImageEntry] {
        var entries: [ImageEntry] = []
        let fm = FileManager.default

        scanDirectory(url: rootURL, rootURL: rootURL, depth: 0, maxDepth: maxDepth, fm: fm, lightsOnly: lightsOnly, entries: &entries)

        // Default sort: date/time ascending
        entries.sort { ($0.dateTime ?? "") < ($1.dateTime ?? "") }

        return entries
    }

    // Check if a directory contains any supported image files (non-recursive)
    private static func hasImageFiles(in url: URL, fm: FileManager) -> Bool {
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        return contents.contains { item in
            let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isFile && supportedExtensions.contains(item.pathExtension.lowercased())
        }
    }

    private static func scanDirectory(url: URL, rootURL: URL, depth: Int, maxDepth: Int, fm: FileManager, lightsOnly: Bool, entries: inout [ImageEntry]) {
        guard depth <= maxDepth else { return }

        // Skip PRE-DELETE / _predel directories encountered via recursion,
        // but ALLOW them when the user explicitly opens one as the top-level
        // rootURL (depth == 0). This lets power-users review/restore culled
        // frames while keeping normal session opens free of their PRE-DELETE
        // subfolder contents.
        if depth > 0 && isPreDeleteFolder(url.lastPathComponent) { return }

        // Skip calibration folders entirely when lightsOnly is active
        // Matches any folder containing "dark", "flat", or "bias" anywhere in the name
        if lightsOnly && isFolderCalibration(url.lastPathComponent) { return }

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDirectory {
                scanDirectory(url: item, rootURL: rootURL, depth: depth + 1, maxDepth: maxDepth, fm: fm, lightsOnly: lightsOnly, entries: &entries)
            } else {
                let ext = item.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }

                // Calculate relative subfolder path
                let subfolder = relativeSubfolder(fileURL: item, rootURL: rootURL)

                // Parse filename tokens only (fast — no file I/O)
                // Headers are read in background by TriageViewModel.enrichWithHeaders()
                let tokens = NINAFilenameParser.parse(item.lastPathComponent)

                // Skip calibration frames when lightsOnly is active
                // Uses frame type token parsing (not substring match) to avoid
                // false positives on target names like "Dark Nebula"
                if lightsOnly && isFileCalibration(item.lastPathComponent) { continue }

                var entry = ImageEntry(url: item, subfolder: subfolder)
                entry.date = tokens.date
                entry.time = tokens.time
                entry.target = tokens.target
                entry.frameNumber = tokens.frameNumber
                entry.exposure = tokens.exposure
                entry.filter = tokens.filter
                entry.frameType = tokens.frameType
                entry.gain = tokens.gain
                entry.offset = tokens.offset
                entry.binning = tokens.binning
                entry.sensorTemp = tokens.sensorTemp
                entry.telescope = tokens.telescope
                entry.camera = tokens.camera
                entry.fwhm = tokens.fwhm
                entry.focuserTemp = tokens.focuserTemp
                entry.hfr = tokens.hfr
                entry.starCount = tokens.starCount

                // File size
                if let attrs = try? fm.attributesOfItem(atPath: item.path),
                   let size = attrs[.size] as? Int64 {
                    entry.fileSize = size
                }

                entries.append(entry)
            }
        }
    }

    // Calculate relative subfolder from root (e.g. "Ha/" or "OIII/subdir/")
    private static func relativeSubfolder(fileURL: URL, rootURL: URL) -> String {
        let filePath = fileURL.deletingLastPathComponent().path
        let rootPath = rootURL.path

        if filePath == rootPath {
            return ""
        }

        var relative = filePath
        if relative.hasPrefix(rootPath) {
            relative = String(relative.dropFirst(rootPath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
        }
        return relative
    }
}
