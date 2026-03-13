// v1.0.0
import Foundation

// Scans a folder for FITS/XISF files with smart subfolder logic:
// - If root has image files → only load root images, ignore subfolders
// - If root has NO image files but has subfolders → scan subfolders recursively
// - Calibration frames (DARK, FLAT, BIAS) are excluded by default (folder scan only)
struct SessionScanner {

    static let supportedExtensions: Set<String> = ["xisf", "fits", "fit", "fts"]
    static let defaultMaxDepth = 3

    // Folder names that indicate calibration frames (case-insensitive)
    private static let calibrationFolderNames: Set<String> = [
        "dark", "darks", "flat", "flats", "bias", "biases",
        "darkflat", "darkflats", "dark_flat", "dark_flats",
        "masterdark", "masterflat", "masterbias",
        "master_dark", "master_flat", "master_bias"
    ]

    // Frame types that are calibration (not lights)
    private static let calibrationFrameTypes: Set<String> = ["DARK", "FLAT", "BIAS"]

    // Scan a root folder with smart subfolder detection
    // lightsOnly: when true (default for folder open), skip calibration frames (DARK/FLAT/BIAS)
    static func scan(rootURL: URL, maxDepth: Int = defaultMaxDepth, lightsOnly: Bool = true) -> [ImageEntry] {
        var entries: [ImageEntry] = []
        let fm = FileManager.default

        // Check if root folder contains any image files directly
        let rootHasImages = hasImageFiles(in: rootURL, fm: fm)

        if rootHasImages {
            // Root has images → only scan root level, ignore subfolders
            scanDirectory(url: rootURL, rootURL: rootURL, depth: 0, maxDepth: 0, fm: fm, lightsOnly: lightsOnly, entries: &entries)
        } else {
            // Root has no images → scan subfolders recursively (e.g. per-filter folders)
            scanDirectory(url: rootURL, rootURL: rootURL, depth: 0, maxDepth: maxDepth, fm: fm, lightsOnly: lightsOnly, entries: &entries)
        }

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

        // Skip _predel directories
        if url.lastPathComponent == "_predel" { return }

        // Skip calibration folders entirely when lightsOnly is active
        if lightsOnly && calibrationFolderNames.contains(url.lastPathComponent.lowercased()) { return }

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

                // Skip calibration frames by filename token when lightsOnly is active
                if lightsOnly, let ft = tokens.frameType, calibrationFrameTypes.contains(ft) { continue }

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
