// v3.11.0
import Foundation
import ImageDecoderBridge

// Scope of a batch operation: filename, header, both, or delete keyword
enum BatchScope: Equatable {
    case filenameOnly
    case headerOnly(keyword: String)
    case both(keyword: String)
    case deleteKeyword(keyword: String)   // Remove keyword entirely from header
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

// Specification for the dedicated, footgun-free Change Filter operation.
// Unlike BatchRenameSpec (free-text search/replace), this targets ONLY the FILTER header
// keyword (exact value) and ONLY the parsed filter token in the filename. The rest of the
// filename can never be touched.
struct ChangeFilterSpec {
    let newFilter: String        // exact new FILTER value, e.g. "L"
    let oldFilter: String?       // optional guard: only touch files whose current filter matches (case-insensitive)
    static let keyword = "FILTER"
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
            case .headerOnly, .deleteKeyword:
                newFilename = nil  // Don't rename file for header/delete scope
            case .both:
                break  // Keep both
            }

            // Header replacement or deletion
            switch spec.scope {
            case .headerOnly(let keyword), .both(let keyword):
                // Read current header value
                if let currentValue = readHeaderValue(url: entry.url, keyword: keyword) {
                    // Header values use case-insensitive matching (FITS filter names etc.)
                    let newValue = applyReplacement(to: currentValue, spec: spec, caseInsensitive: true)
                    if newValue != currentValue {
                        headerChanges.append((key: keyword, oldValue: currentValue, newValue: newValue))
                    }
                }
            case .deleteKeyword(let keyword):
                // Check if keyword exists — if so, mark for deletion
                if let currentValue = readHeaderValue(url: entry.url, keyword: keyword) {
                    headerChanges.append((key: keyword, oldValue: currentValue, newValue: "⌫ DELETE"))
                }
                newFilename = nil  // No filename change for delete operations
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
        // See executeChangeFilter: sandboxed writes into a user-granted NAS / external
        // volume need the security scope active. Re-acquire it for the whole batch.
        let scoped = sessionRoot.startAccessingSecurityScopedResource()
        defer { if scoped { sessionRoot.stopAccessingSecurityScopedResource() } }

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
                let isDelete = change.newValue == "⌫ DELETE"

                if isDelete {
                    // Delete keyword entirely from header
                    let deleteError = deleteHeader(url: currentURL, keyword: change.key)
                    if let error = deleteError {
                        try? fm.removeItem(at: currentURL)
                        try? fm.copyItem(at: backupURL, to: originalURL)
                        failed.append((url: originalURL, error: "Header delete failed: \(error)"))
                        continue
                    }
                    // Verify deletion: keyword should no longer exist
                    if readHeaderValue(url: currentURL, keyword: change.key) != nil {
                        try? fm.removeItem(at: currentURL)
                        try? fm.copyItem(at: backupURL, to: originalURL)
                        failed.append((url: originalURL, error: "Delete verification failed: '\(change.key)' still present"))
                        continue
                    }
                } else {
                    let writeError = writeHeader(url: currentURL, keyword: change.key, value: change.newValue)
                    if let error = writeError {
                        try? fm.removeItem(at: currentURL)
                        try? fm.copyItem(at: backupURL, to: originalURL)
                        failed.append((url: originalURL, error: "Header write failed: \(error)"))
                        continue
                    }

                    // Verify the write
                    if let readBack = readHeaderValue(url: currentURL, keyword: change.key) {
                        if readBack != change.newValue {
                            try? fm.removeItem(at: currentURL)
                            try? fm.copyItem(at: backupURL, to: originalURL)
                            failed.append((url: originalURL, error: "Verification failed: wrote '\(change.newValue)' but read back '\(readBack)'"))
                            continue
                        }
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

        // Clean up the backup directory ONLY when every file restored cleanly. If any restore
        // failed (disk full, permissions), keep the backups so the originals stay recoverable —
        // never delete the last copy of a file we couldn't put back.
        if errors.isEmpty {
            try? fm.removeItem(at: entry.backupDirectory)
        }

        return (restored, errors)
    }

    // MARK: - Change Filter (dedicated, token-precise)

    /// Preview a filter change without modifying anything. Reuses BatchPreviewItem so the same
    /// preview UI can render it. For each file:
    ///   - header: FILTER is written/created to the exact new value (shown unless already equal)
    ///   - filename: ONLY the located filter token is replaced (shown only when a token is found)
    /// The optional `oldFilter` guard skips files whose current filter doesn't match.
    static func previewChangeFilter(spec: ChangeFilterSpec, entries: [ImageEntry]) -> [BatchPreviewItem] {
        let keyword = ChangeFilterSpec.keyword
        var items: [BatchPreviewItem] = []

        for entry in entries {
            let originalFilename = entry.filename
            let nameNoExt = (originalFilename as NSString).deletingPathExtension
            let ext = (originalFilename as NSString).pathExtension

            // Current header FILTER (nil when the keyword is absent)
            let currentHeader = readHeaderValue(url: entry.url, keyword: keyword)
            // Filter token currently in the filename (nil when not locatable)
            let tokenInfo = NINAFilenameParser.filterTokenRange(in: nameNoExt)
            // For the guard, prefer the header value, fall back to the filename token
            let currentFilter = currentHeader ?? tokenInfo?.value

            // Guard: if an old filter is specified, skip files that don't currently match it.
            if let old = spec.oldFilter, !old.isEmpty {
                let cur = currentFilter ?? ""
                if cur.compare(old, options: .caseInsensitive) != .orderedSame {
                    items.append(BatchPreviewItem(id: entry.id, entry: entry,
                        originalFilename: originalFilename, newFilename: nil,
                        headerChanges: [], willChange: false))
                    continue
                }
            }

            var headerChanges: [(key: String, oldValue: String, newValue: String)] = []
            // Write/create the FILTER keyword unless it already holds the exact target value.
            // Comparison is case-SENSITIVE on purpose: if the header reads "ha" and the user wants
            // "Ha", we DO rewrite it to the canonical casing. (The optional oldFilter guard above is
            // case-insensitive — that only decides which files to touch, not the written value.)
            if currentHeader != spec.newFilter {
                headerChanges.append((key: keyword,
                                      oldValue: currentHeader ?? "(absent)",
                                      newValue: spec.newFilter))
            }

            // Rename ONLY the located filter token, and only if it differs from the target.
            var newFilename: String? = nil
            if let info = tokenInfo, info.value != spec.newFilter {
                let replaced = nameNoExt.replacingCharacters(in: info.range, with: spec.newFilter)
                newFilename = ext.isEmpty ? replaced : replaced + "." + ext
            }

            let willChange = newFilename != nil || !headerChanges.isEmpty
            items.append(BatchPreviewItem(id: entry.id, entry: entry,
                originalFilename: originalFilename, newFilename: newFilename,
                headerChanges: headerChanges, willChange: willChange))
        }

        return items
    }

    /// Execute a filter change with mandatory backup + read-back verification. Mirrors `execute()`'s
    /// safety contract: every file is copied to a backup dir first; any failure (backup, header
    /// write, verify, rename) restores that file from backup and continues with the next one — the
    /// batch never aborts mid-way and a file is never left partially modified.
    static func executeChangeFilter(spec: ChangeFilterSpec, entries: [ImageEntry], sessionRoot: URL) -> BatchResult {
        let fm = FileManager.default
        // Sandboxed builds must hold the security scope to create the backup folder and
        // write into a user-granted NAS / external volume. The scope acquired at session
        // load is not reliably retained for later write batches (the PRE-DELETE move
        // re-acquires it too — TriageViewModel), so re-acquire it here. start/stop are
        // balanced and nestable, so this is harmless if the scope is already active.
        let scoped = sessionRoot.startAccessingSecurityScopedResource()
        defer { if scoped { sessionRoot.stopAccessingSecurityScopedResource() } }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let backupDir = sessionRoot.appendingPathComponent("_filter_backup_\(timestamp)")

        var succeeded = 0
        var failed: [(url: URL, error: String)] = []
        var affectedURLs: [URL: URL] = [:]

        let preview = previewChangeFilter(spec: spec, entries: entries)

        // Create the backup folder up front. If this fails (e.g. no write access to the
        // volume), surface the real reason instead of letting every per-file copyItem fail
        // with a cryptic "doesn't exist" because its destination directory is missing.
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            return BatchResult(
                succeeded: 0,
                failed: preview.filter { $0.willChange }.map {
                    (url: $0.entry.url, error: "Could not create backup folder: \(error.localizedDescription)")
                },
                backupDirectory: backupDir,
                affectedURLs: [:]
            )
        }

        for item in preview where item.willChange {
            let originalURL = item.entry.url

            // Step 1: mandatory backup
            let backupURL = backupDir.appendingPathComponent(item.entry.filename)
            do {
                try fm.copyItem(at: originalURL, to: backupURL)
            } catch {
                failed.append((url: originalURL, error: "Backup failed: \(error.localizedDescription)"))
                continue
            }

            // Restores the original file from its backup (used on any failure below).
            func restoreFromBackup(_ current: URL) {
                try? fm.removeItem(at: current)
                try? fm.copyItem(at: backupURL, to: originalURL)
            }

            let currentURL = originalURL
            var fileFailed = false

            // Step 2: header write (single FILTER change) with read-back verification
            for change in item.headerChanges {
                if let writeError = writeHeader(url: currentURL, keyword: change.key, value: change.newValue) {
                    restoreFromBackup(currentURL)
                    failed.append((url: originalURL, error: "Header write failed: \(writeError)"))
                    fileFailed = true
                    break
                }
                if let readBack = readHeaderValue(url: currentURL, keyword: change.key), readBack != change.newValue {
                    restoreFromBackup(currentURL)
                    failed.append((url: originalURL, error: "Verification failed: wrote '\(change.newValue)' but read back '\(readBack)'"))
                    fileFailed = true
                    break
                }
            }
            if fileFailed { continue }

            // Step 3: filename rename (token-precise) after a verified header write
            if let newFilename = item.newFilename {
                let newURL = originalURL.deletingLastPathComponent().appendingPathComponent(newFilename)
                // Refuse to overwrite an existing different file — no silent data loss.
                if fm.fileExists(atPath: newURL.path) {
                    restoreFromBackup(currentURL)
                    failed.append((url: originalURL, error: "Rename target already exists: \(newFilename)"))
                    continue
                }
                do {
                    try fm.moveItem(at: currentURL, to: newURL)
                    affectedURLs[originalURL] = newURL
                } catch {
                    restoreFromBackup(currentURL)
                    failed.append((url: originalURL, error: "Rename failed: \(error.localizedDescription)"))
                    continue
                }
            } else {
                // Header-only change (no rename). Record an identity mapping so undo restores via the
                // full original path — subfolder-safe, unlike the flat session-root assumption in the
                // header-only branch of BatchOperations.undo.
                affectedURLs[originalURL] = originalURL
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

    // MARK: - Private helpers

    /// Apply search/replace to a string using plain text or regex.
    /// When caseInsensitive is true, matching ignores case (used for header values
    /// where FITS keywords like FILTER are case-insensitive).
    private static func applyReplacement(to input: String, spec: BatchRenameSpec, caseInsensitive: Bool = false) -> String {
        if spec.isRegex {
            var options: NSRegularExpression.Options = []
            if caseInsensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: spec.searchPattern, options: options) else {
                return input
            }
            let range = NSRange(input.startIndex..., in: input)
            return regex.stringByReplacingMatches(in: input, range: range, withTemplate: spec.replacement)
        } else {
            return input.replacingOccurrences(of: spec.searchPattern, with: spec.replacement,
                                              options: caseInsensitive ? .caseInsensitive : [])
        }
    }

    /// Read a single header keyword value from a FITS or XISF file
    private static func readHeaderValue(url: URL, keyword: String) -> String? {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        if ext == "xisf" {
            var result = read_xisf_headers(path)
            defer { free_header_result(&result) }
            guard result.success != 0, result.entries != nil else { return nil }
            for i in 0..<Int(result.count) {
                let key = withUnsafePointer(to: &result.entries[i].key) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: result.entries[i].key)) {
                        String(cString: $0)
                    }
                }
                if key.uppercased() == keyword.uppercased() {
                    return withUnsafePointer(to: &result.entries[i].value) {
                        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: result.entries[i].value)) {
                            String(cString: $0)
                        }
                    }
                }
            }
        } else {
            var result = read_fits_headers(path)
            defer { free_header_result(&result) }
            guard result.success != 0, result.entries != nil else { return nil }
            for i in 0..<Int(result.count) {
                let key = withUnsafePointer(to: &result.entries[i].key) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: result.entries[i].key)) {
                        String(cString: $0)
                    }
                }
                if key.uppercased() == keyword.uppercased() {
                    return withUnsafePointer(to: &result.entries[i].value) {
                        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: result.entries[i].value)) {
                            String(cString: $0)
                        }
                    }
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
                // Read the C error buffer safely via a stable in-place pointer.
                // The previous form `UnsafeRawPointer([result.error])` produced a
                // dangling pointer because the temporary array died before
                // String(cString:) read it.
                return withUnsafePointer(to: result.error) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { cStr in
                        String(cString: cStr)
                    }
                }
            }
            // Atomic replace: remove original, rename temp
            do {
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            } catch {
                // Leave no stray .tmp behind. The caller holds a backup copy and restores the
                // original from it on this error, so discarding the temp's new content is correct.
                try? FileManager.default.removeItem(atPath: tempPath)
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

    /// Delete a header keyword from a FITS or XISF file
    private static func deleteHeader(url: URL, keyword: String) -> String? {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        if ext == "xisf" {
            let tempPath = path + ".tmp"
            let result = delete_xisf_keyword(path, tempPath, keyword)
            if result.success == 0 {
                try? FileManager.default.removeItem(atPath: tempPath)
                return withUnsafePointer(to: result.error) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            } catch {
                // Leave no stray .tmp behind; the caller restores the original from its backup.
                try? FileManager.default.removeItem(atPath: tempPath)
                return "Atomic rename failed: \(error.localizedDescription)"
            }
            return nil
        } else {
            let result = delete_fits_keyword(path, keyword)
            if result.success == 0 {
                return withUnsafePointer(to: result.error) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
            }
            return nil
        }
    }
}
