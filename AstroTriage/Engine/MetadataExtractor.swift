// v2.2.0
import Foundation
import ImageDecoderBridge

// Unified metadata extraction from FITS/XISF headers
// Merges filename-parsed tokens with header values (header takes priority for most fields)
struct MetadataExtractor {

    // Extract headers from a file and merge with filename-parsed tokens
    static func extractAndMerge(url: URL, filenameParsed: NINAFilenameParser.ParsedTokens) -> ImageEntry {
        var entry = ImageEntry(url: url)

        // Apply filename-parsed values first (fallback)
        applyParsedTokens(&entry, from: filenameParsed)

        // Read headers and override with more authoritative values
        let headers = readHeaders(from: url)
        applyHeaders(&entry, from: headers)

        return entry
    }

    // Read raw headers from file (XISF or FITS)
    static func readHeaders(from url: URL) -> [String: String] {
        let path = url.path
        var headerDict: [String: String] = [:]

        let result: HeaderResult
        if url.pathExtension.lowercased() == "xisf" {
            result = read_xisf_headers(path)
        } else {
            result = read_fits_headers(path)
        }

        if result.success != 0, let entries = result.entries {
            for i in 0..<Int(result.count) {
                let key = withUnsafePointer(to: entries[i].key) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                let value = withUnsafePointer(to: entries[i].value) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                headerDict[key.trimmingCharacters(in: .whitespaces)] = value.trimmingCharacters(in: .whitespaces)
            }
        }

        // Free C-allocated memory (Lesson L4)
        var mutableResult = result
        free_header_result(&mutableResult)

        return headerDict
    }

    // MARK: - Apply parsed filename tokens

    private static func applyParsedTokens(_ entry: inout ImageEntry, from tokens: NINAFilenameParser.ParsedTokens) {
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
    }

    // MARK: - Apply FITS/XISF headers (overrides filename values where appropriate)

    private static func applyHeaders(_ entry: inout ImageEntry, from headers: [String: String]) {
        // Filter (header is authoritative)
        if let filter = headers["FILTER"], !filter.isEmpty {
            entry.filter = filter
        }

        // Exposure
        if let exp = headers["EXPTIME"] ?? headers["EXPOSURE"], let val = Double(exp) {
            entry.exposure = val
        }

        // Gain
        if let gain = headers["GAIN"], let val = Int(gain) {
            entry.gain = val
        }

        // Sensor temperature
        if let temp = headers["CCD-TEMP"], let val = Double(temp) {
            entry.sensorTemp = val
        }

        // FWHM (header STARFWHM - this is atmospheric FWHM, not autofocus HFR)
        if let fwhm = headers["STARFWHM"] ?? headers["FWHM"], let val = Double(fwhm) {
            entry.fwhm = val
        }

        // Target name
        if let obj = headers["OBJECT"], !obj.isEmpty {
            entry.target = obj
        }

        // Date from header (DATE-LOC or DATE-OBS)
        if let dateStr = headers["DATE-LOC"] ?? headers["DATE-OBS"], !dateStr.isEmpty {
            // Parse ISO date: "2026-03-06T23:54:58.000"
            if dateStr.count >= 10 {
                let dateOnly = String(dateStr.prefix(10))
                entry.date = entry.date ?? dateOnly
            }
            if dateStr.count >= 19, let tIndex = dateStr.firstIndex(of: "T") {
                let timeStart = dateStr.index(after: tIndex)
                let timeEnd = dateStr.index(timeStart, offsetBy: 8, limitedBy: dateStr.endIndex) ?? dateStr.endIndex
                entry.time = entry.time ?? String(dateStr[timeStart..<timeEnd])
            }
        }

        // Camera
        if let cam = headers["INSTRUME"], !cam.isEmpty {
            entry.camera = cam
        }

        // Telescope
        if let scope = headers["TELESCOP"], !scope.isEmpty {
            entry.telescope = scope
        }

        // Binning
        if let xbin = headers["XBINNING"], let val = Int(xbin) {
            entry.binning = entry.binning ?? "\(val)x\(val)"
        }

        // Offset
        if let off = headers["OFFSET"], let val = Int(off) {
            entry.offset = val
        }

        // Focuser temperature
        if let focTemp = headers["FOCTEMP"], let val = Double(focTemp) {
            entry.focuserTemp = val
        }

        // Ambient/environment temperature
        if let ambTemp = headers["AMBTEMP"] ?? headers["AMBIENT"], let val = Double(ambTemp) {
            entry.ambientTemp = val
        }

        // Mount (NINA writes various keywords)
        if let mount = headers["MOUNT"] ?? headers["MOUNTNAME"] ?? headers["MNTSNAME"], !mount.isEmpty {
            entry.mount = mount
        }

        // Bayer pattern (for debayer rendering of OSC images)
        if let bayer = headers["BAYERPAT"], !bayer.isEmpty {
            entry.bayerPattern = bayer.trimmingCharacters(in: .whitespaces).uppercased()
        }

        // Frame type from IMAGETYP or FRAME header (more reliable than filename parsing)
        // Normalize variants: "Light Frame" → "LIGHT", "Dark Frame" → "DARK", etc.
        if let imageType = headers["IMAGETYP"] ?? headers["FRAME"], !imageType.isEmpty {
            entry.frameType = normalizeFrameType(imageType)
        }
    }

    // Normalize IMAGETYP/FRAME header values to consistent short form
    static func normalizeFrameType(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if upper.contains("LIGHT") { return "LIGHT" }
        if upper.contains("DARK")  { return "DARK" }
        if upper.contains("FLAT")  { return "FLAT" }
        if upper.contains("BIAS")  { return "BIAS" }
        return upper
    }
}
