// v3.2.0
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
                // FITS string values include single quotes (e.g., "'L'", "'2026-03-18T04:39:24'").
                // Strip whitespace and surrounding quotes so downstream code gets clean values.
                let cleanKey = key.trimmingCharacters(in: .whitespaces)
                var cleanVal = value.trimmingCharacters(in: .whitespaces)
                if cleanVal.hasPrefix("'") && cleanVal.hasSuffix("'") && cleanVal.count >= 2 {
                    cleanVal = String(cleanVal.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                }
                headerDict[cleanKey] = cleanVal
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

        // DATE-LOC (NINA local capture time) unconditionally overrides filename date.
        // DATE-OBS is fallback only — may contain unexpected values in some FITS writers.
        if let dateLoc = headers["DATE-LOC"], !dateLoc.isEmpty, dateLoc.count >= 10 {
            entry.date = String(dateLoc.prefix(10))
            if dateLoc.count >= 19, let tIndex = dateLoc.firstIndex(of: "T") {
                let timeStart = dateLoc.index(after: tIndex)
                let timeEnd = dateLoc.index(timeStart, offsetBy: 8, limitedBy: dateLoc.endIndex) ?? dateLoc.endIndex
                entry.time = entry.time ?? String(dateLoc[timeStart..<timeEnd])
            }
        } else if let dateObs = headers["DATE-OBS"], !dateObs.isEmpty, dateObs.count >= 10 {
            entry.date = entry.date ?? String(dateObs.prefix(10))
            if dateObs.count >= 19, let tIndex = dateObs.firstIndex(of: "T") {
                let timeStart = dateObs.index(after: tIndex)
                let timeEnd = dateObs.index(timeStart, offsetBy: 8, limitedBy: dateObs.endIndex) ?? dateObs.endIndex
                entry.time = entry.time ?? String(dateObs[timeStart..<timeEnd])
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

        // Focuser position (for autofocus event detection in Session Metrics chart)
        if let focPos = headers["FOCPOS"] ?? headers["FOCUSPOS"], let val = Double(focPos) {
            entry.focusPosition = val
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

        // Pier side for meridian flip detection (NINA writes PIERSIDE as EAST or WEST)
        // FITS values may be wrapped in single quotes (e.g. "'East'"), strip them
        if let pier = headers["PIERSIDE"], !pier.isEmpty {
            let cleaned = pier.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            if cleaned == "EAST" || cleaned == "WEST" {
                entry.pierSide = cleaned
            }
        }

        // Rotator angle for meridian flip fallback (when PIERSIDE unavailable)
        // ASIAIR/AM5 mounts report ROTATOR angle that changes ~180° across meridian flip
        if let rot = headers["ROTATOR"], let val = Double(rot) {
            entry.rotatorAngle = val
        }

        // WCS rotation from plate solve: CROTA2 (direct) or CD matrix (computed)
        // Used as additional meridian flip detection signal when available
        if let crota2 = headers["CROTA2"], let val = Double(crota2) {
            entry.wcsRotation = val
        } else if let cd11 = headers["CD1_1"], let cd12 = headers["CD1_2"],
                  let v11 = Double(cd11), let v12 = Double(cd12) {
            // Compute rotation from CD matrix: rotation = atan2(-CD1_2, CD1_1)
            entry.wcsRotation = atan2(-v12, v11) * 180.0 / .pi
        }

        // Full WCS plate-solve data for CD-matrix based display alignment.
        // Takes priority over star matching in DisplayAligner — exact, filter-independent,
        // ~100x faster. Every ASIAir-captured frame has this data.
        if let v = headers["CRPIX1"] { entry.wcsCRPIX1 = Double(v) }
        if let v = headers["CRPIX2"] { entry.wcsCRPIX2 = Double(v) }
        if let v = headers["CD1_1"]  { entry.wcsCD11 = Double(v) }
        if let v = headers["CD1_2"]  { entry.wcsCD12 = Double(v) }
        if let v = headers["CD2_1"]  { entry.wcsCD21 = Double(v) }
        if let v = headers["CD2_2"]  { entry.wcsCD22 = Double(v) }

        // Object coordinates for meridian flip matching (more reliable than target name)
        // Strip FITS single-quote wrappers from coordinate strings
        if let ra = headers["OBJCTRA"], !ra.isEmpty {
            entry.objctRA = ra.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        if let dec = headers["OBJCTDEC"], !dec.isEmpty {
            entry.objctDec = dec.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .whitespaces)
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
