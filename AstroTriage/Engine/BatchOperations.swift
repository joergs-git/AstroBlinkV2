// v3.11.0
import Foundation
import ImageDecoderBridge

// Scope of a batch operation: filename, header, or both
enum BatchScope: Equatable {
    case filenameOnly
    case headerOnly(keyword: String)
    case both(keyword: String)
}

// Specification for a batch rename/header edit operation
struct BatchRenameSpec {
    let searchPattern: String    // Plain text or regex pattern
    let replacement: String      // Replacement string
    let isRegex: Bool            // Whether searchPattern is a regex
    let scope: BatchScope
}

// Preview item showing what would change for one file
struct BatchPreviewItem: Identifiable {
    let id: UUID
    let entry: ImageEntry
    let originalFilename: String
    let newFilename: String?              // nil = no filename change
    let headerChanges: [(key: String, oldValue: String, newValue: String)]
    let willChange: Bool
}

// Result of a batch operation
struct BatchResult {
    let succeeded: Int
    let failed: [(url: URL, error: String)]
    let backupDirectory: URL
    let affectedURLs: [URL: URL]          // originalURL → newURL (for renamed files)
}

// Undo entry for a batch operation
struct BatchUndoEntry {
    let backupDirectory: URL
    let result: BatchResult
    let timestamp: Date
}

// MARK: - BatchOperations

struct BatchOperations {

    // MARK: - Preview

    /// Preview what would change without modifying anything.
    /// For header scope, reads current header values to show old→new.
    static func preview(spec: BatchRenameSpec, entries: [ImageEntry]) -> [BatchPreviewItem] {
        var items: [BatchPreviewItem] = []

        for entry in entries {
            let originalFilename = entry.filename
            var newFilename: String? = nil
            var headerChanges: [(key: String, oldValue: String, newValue: String)] = []

            // Filename replacement
            if spec.scope == .filenameOnly || spec.scope != .filenameOnly {
                let filenameWithoutExt = (originalFilename as NSString).deletingPathExtension
                let ext = (originalFilename as NSString).pathExtension

                let replaced = applyReplacement(to: filenameWithoutExt, spec: spec)
                if replaced != filenameWithoutExt {
                    newFilename = replaced + "." + ext
                }
            }

            // Only apply filename change for filenameOnly or both scope
            switch spec.scope {
            case .filenameOnly:
                break  // newFilename already computed above
            case .headerOnly:
                newFilename = nil  // Don't rename file for header-only scope
            case .both:
                break  // Keep both
            }

            // Header replacement
            switch spec.scope {
            case .headerOnly(let keyword), .both(let keyword):
                // Read current header value
                if let currentValue = readHeaderValue(url: entry.url, keyword: keyword) {
                    let newValue = applyReplacement(to: currentValue, spec: spec)
                    if newValue != currentValue {
                        headerChanges.append((key: keyword, oldValue: currentValue, newValue: newValue))
                    }
                }
            case .filenameOnly:
                break
            }

            let willChange = newFilename != nil || !headerChanges.isEmpty
            items.append(BatchPreviewItem(
                id: entry.id,
                entry: entry,
                originalFilename: originalFilename,
                newFilename: newFilename,
                headerChanges: headerChanges,
                willChange: willChange
            ))
        }

        return items
    }

    // MARK: - Execute

    /// Execute the batch operation with mandatory backup.
    /// Returns a result that can be used for undo.
    static func execute(spec: BatchRenameSpec, entries: [ImageEntry], sessionRoot: URL) -> BatchResult {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let backupDir = sessionRoot.appendingPathComponent("_batch_backup_\(timestamp)")

        // Create backup directory
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        var succeeded = 0
        var failed: [(url: URL, error: String)] = []
        var affectedURLs: [URL: URL] = [:]

        let preview = preview(spec: spec, entries: entries)

        for item in preview where item.willChange {
            let entry = item.entry
            let originalURL = entry.url

            // Step 1: Backup the original file
            let backupURL = backupDir.appendingPathComponent(entry.filename)
            do {
                try fm.copyItem(at: originalURL, to: backupURL)
            } catch {
                failed.append((url: originalURL, error: "Backup failed: \(error.localizedDescription)"))
                continue
            }

            var currentURL = originalURL

            // Step 2: Header modification (before rename, since URL hasn't changed yet)
            for change in item.headerChanges {
                let writeError = writeHeader(url: currentURL, keyword: change.key, value: change.newValue)
                if let error = writeError {
                    // Restore from backup
                    try? fm.removeItem(at: currentURL)
                    try? fm.copyItem(at: backupURL, to: originalURL)
                    failed.append((url: originalURL, error: "Header write failed: \(error)"))
                    continue
                }

                // Verify the write
                if let readBack = readHeaderValue(url: currentURL, keyword: change.key) {
                    if readBack != change.newValue {
                        // Restore from backup
                        try? fm.removeItem(at: currentURL)
                        try? fm.copyItem(at: backupURL, to: originalURL)
                        failed.append((url: originalURL, error: "Verification failed: wrote '\(change.newValue)' but read back '\(readBack)'"))
                        continue
                    }
                }
            }

            // Step 3: Filename rename (after header write)
            if let newFilename = item.newFilename {
                let newURL = originalURL.deletingLastPathComponent().appendingPathComponent(newFilename)
                do {
                    try fm.moveItem(at: currentURL, to: newURL)
                    currentURL = newURL
                    affectedURLs[originalURL] = newURL
                } catch {
                    // Restore from backup
                    try? fm.removeItem(at: currentURL)
                    try? fm.copyItem(at: backupURL, to: originalURL)
                    failed.append((url: originalURL, error: "Rename failed: \(error.localizedDescription)"))
                    continue
                }
            }

            succeeded += 1
        }

        return BatchResult(
            succeeded: succeeded,
            failed: failed,
            backupDirectory: backupDir,
            affectedURLs: affectedURLs
        )
    }

    // MARK: - Undo

    /// Restore all files from the backup directory.
    static func undo(entry: BatchUndoEntry) -> (restored: Int, errors: [String]) {
        let fm = FileManager.default
        var restored = 0
        var errors: [String] = []

        // Reverse renamed files first
        for (originalURL, newURL) in entry.result.affectedURLs {
            do {
                if fm.fileExists(atPath: newURL.path) {
                    try fm.removeItem(at: newURL)
                }
                let backupURL = entry.backupDirectory.appendingPathComponent(originalURL.lastPathComponent)
                if fm.fileExists(atPath: backupURL.path) {
                    try fm.copyItem(at: backupURL, to: originalURL)
                    restored += 1
                }
            } catch {
                errors.append("Failed to restore \(originalURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Restore header-only modifications (files that weren't renamed)
        if let contents = try? fm.contentsOfDirectory(at: entry.backupDirectory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
            for backupFile in contents {
                let originalURL = entry.backupDirectory
                    .deletingLastPathComponent()  // session root
                    .appendingPathComponent(backupFile.lastPathComponent)

                // Skip if already restored (was renamed)
                if entry.result.affectedURLs.keys.contains(where: { $0.lastPathComponent == backupFile.lastPathComponent }) {
                    continue
                }

                // Only restore if the file wasn't renamed (header-only change)
                if fm.fileExists(atPath: originalURL.path) {
                    do {
                        try fm.removeItem(at: originalURL)
                        try fm.copyItem(at: backupFile, to: originalURL)
                        restored += 1
                    } catch {
                        errors.append("Failed to restore \(backupFile.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Clean up backup directory
        try? fm.removeItem(at: entry.backupDirectory)

        return (restored, errors)
    }

    // MARK: - Private helpers

    /// Apply search/replace to a string using plain text or regex
    private static func applyReplacement(to input: String, spec: BatchRenameSpec) -> String {
        if spec.isRegex {
            guard let regex = try? NSRegularExpression(pattern: spec.searchPattern) else {
                return input
            }
            let range = NSRange(input.startIndex..., in: input)
            return regex.stringByReplacingMatches(in: input, range: range, withTemplate: spec.replacement)
        } else {
            return input.replacingOccurrences(of: spec.searchPattern, with: spec.replacement)
        }
    }

    /// Read a single header keyword value from a FITS or XISF file
    private static func readHeaderValue(url: URL, keyword: String) -> String? {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        if ext == "xisf" {
            var result = read_xisf_headers(path)
            defer { free_header_result(&result) }
            guard result.success != 0 else { return nil }
            for i in 0..<result.count {
                let key = String(cString: &result.entries[Int(i)].key.0)
                if key.uppercased() == keyword.uppercased() {
                    return String(cString: &result.entries[Int(i)].value.0)
                }
            }
        } else {
            var result = read_fits_headers(path)
            defer { free_header_result(&result) }
            guard result.success != 0 else { return nil }
            for i in 0..<result.count {
                let key = String(cString: &result.entries[Int(i)].key.0)
                if key.uppercased() == keyword.uppercased() {
                    return String(cString: &result.entries[Int(i)].value.0)
                }
            }
        }

        return nil
    }

    /// Write a header keyword to a FITS or XISF file
    private static func writeHeader(url: URL, keyword: String, value: String) -> String? {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        if ext == "xisf" {
            // XISF: write to temp file, then atomic rename
            let tempPath = path + ".tmp"
            let result = write_xisf_keyword(path, tempPath, keyword, value)
            if result.success == 0 {
                // Clean up temp file on failure
                try? FileManager.default.removeItem(atPath: tempPath)
                return String(cString: UnsafeRawPointer([result.error]).assumingMemoryBound(to: CChar.self))
            }
            // Atomic replace: remove original, rename temp
            do {
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            } catch {
                return "Atomic rename failed: \(error.localizedDescription)"
            }
            return nil
        } else {
            // FITS: cfitsio writes in-place (backup is already made by caller)
            let result = write_fits_keyword(path, keyword, value)
            if result.success == 0 {
                return withUnsafePointer(to: result.error) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { cStr in
                        String(cString: cStr)
                    }
                }
            }
            return nil
        }
    }
}
