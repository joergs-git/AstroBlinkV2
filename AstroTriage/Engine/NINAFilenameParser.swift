// v0.1.0
import Foundation

// Parses NINA filename tokens to extract metadata
// Supports order-independent keyword-based extraction (Caveat C6)
// Real pattern example:
// 2026-03-06_IC1848_23-54-58_RASA_ZWO ASI6200MM Pro_LIGHT_H_300.00s_#0016__bin1x1_gain100_O50_T-10.00c__FWHM_4.15_FOCT_4.46.xisf
struct NINAFilenameParser {

    // Parse all tokens from a NINA-style filename
    static func parse(_ filename: String) -> ParsedTokens {
        var tokens = ParsedTokens()

        // Remove extension for parsing
        let name: String
        if let dotIndex = filename.lastIndex(of: ".") {
            name = String(filename[filename.startIndex..<dotIndex])
        } else {
            name = filename
        }

        tokens.date = extractDate(from: name)
        tokens.time = extractTime(from: name)
        tokens.target = extractTarget(from: name)
        tokens.frameNumber = extractFrameNumber(from: name)
        tokens.exposure = extractExposure(from: name)
        tokens.filter = extractFilter(from: name)
        tokens.frameType = extractFrameType(from: name)
        tokens.gain = extractGain(from: name)
        tokens.offset = extractOffset(from: name)
        tokens.binning = extractBinning(from: name)
        tokens.sensorTemp = extractSensorTemp(from: name)
        tokens.telescope = extractTelescope(from: name)
        tokens.camera = extractCamera(from: name)
        tokens.fwhm = extractFWHM(from: name)
        tokens.focuserTemp = extractFocuserTemp(from: name)
        tokens.hfr = extractHFR(from: name)
        tokens.starCount = extractStarCount(from: name)

        return tokens
    }

    struct ParsedTokens {
        var date: String?
        var time: String?
        var target: String?
        var frameNumber: Int?
        var exposure: Double?
        var filter: String?
        var frameType: String?
        var gain: Int?
        var offset: Int?
        var binning: String?
        var sensorTemp: Double?
        var telescope: String?
        var camera: String?
        var fwhm: Double?
        var focuserTemp: Double?
        var hfr: Double?
        var starCount: Int?
    }

    // MARK: - Individual Token Extractors

    // Date: 2026-03-06 at the start of filename
    private static func extractDate(from name: String) -> String? {
        let pattern = #"^(\d{4}-\d{2}-\d{2})"#
        return firstMatch(pattern, in: name)
    }

    // Time: HH-MM-SS (with dashes, third underscore-separated group)
    private static func extractTime(from name: String) -> String? {
        let pattern = #"_(\d{2}-\d{2}-\d{2})_"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        // Convert 23-54-58 to 23:54:58
        return match.replacingOccurrences(of: "-", with: ":")
    }

    // Target: second underscore-separated segment (after date, before time)
    private static func extractTarget(from name: String) -> String? {
        let pattern = #"^\d{4}-\d{2}-\d{2}_(.+?)_\d{2}-\d{2}-\d{2}_"#
        return firstMatch(pattern, in: name)
    }

    // Frame number: #NNNN
    private static func extractFrameNumber(from name: String) -> Int? {
        let pattern = #"#(\d{1,5})"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Int(match)
    }

    // Exposure: NNN.NNs
    private static func extractExposure(from name: String) -> Double? {
        let pattern = #"_(\d+\.?\d*)s[_#]"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Double(match)
    }

    // Filter: single letter or short string between LIGHT/FLAT/DARK_ and _NNNs
    // Must distinguish O (OIII) from O50 (Offset)
    // Pattern: _LIGHT_H_ or _LIGHT_Lextr_ etc.
    private static func extractFilter(from name: String) -> String? {
        let pattern = #"_(?:LIGHT|FLAT|DARK|BIAS)_([A-Za-z][A-Za-z0-9]*)_\d"#
        return firstMatch(pattern, in: name)
    }

    // Frame type: LIGHT, FLAT, DARK, BIAS
    private static func extractFrameType(from name: String) -> String? {
        let pattern = #"_(LIGHT|FLAT|DARK|BIAS)_"#
        return firstMatch(pattern, in: name)
    }

    // Gain: gain100, gain200 etc.
    private static func extractGain(from name: String) -> Int? {
        let pattern = #"(?i)gain(\d+)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Int(match)
    }

    // Offset: O50 (but NOT OIII or other filter names)
    // Offset is always O followed by pure digits, after gain
    private static func extractOffset(from name: String) -> Int? {
        let pattern = #"_O(\d{1,4})(?:_|$)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Int(match)
    }

    // Binning: bin1x1, bin2x2
    private static func extractBinning(from name: String) -> String? {
        let pattern = #"(?i)bin(\d+x\d+)"#
        return firstMatch(pattern, in: name)
    }

    // Sensor temp: T-10.00c, T25.5C, or _-20.0C_ (old style without T prefix)
    private static func extractSensorTemp(from name: String) -> Double? {
        let pattern = #"(?i)(?:T|_)(-?\d+\.?\d*)[cC](?:_|\.|\b)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Double(match)
    }

    // Telescope: segment after time, before camera name
    // In pattern: ..._23-54-58_RASA_ZWO ASI6200MM Pro_...
    private static func extractTelescope(from name: String) -> String? {
        let pattern = #"\d{2}-\d{2}-\d{2}_([^_]+?)_(?:ZWO|QHY|Atik|ASI|SBIG)"#
        return firstMatch(pattern, in: name)
    }

    // Camera: ZWO ASI6200MM Pro, etc.
    private static func extractCamera(from name: String) -> String? {
        let pattern = #"((?:ZWO )?ASI\d+[A-Z]+ ?[A-Za-z]*)"#
        return firstMatch(pattern, in: name)
    }

    // FWHM: FWHM_4.15 or FWHM4.15
    private static func extractFWHM(from name: String) -> Double? {
        let pattern = #"(?i)FWHM[_=]?(\d+\.?\d*)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Double(match)
    }

    // Focuser temp: FOCT_4.46 or FOCT4.46
    private static func extractFocuserTemp(from name: String) -> Double? {
        let pattern = #"(?i)FOCT[_=]?(-?\d+\.?\d*)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Double(match)
    }

    // HFR: HFR_2.34 or HFR2.34
    private static func extractHFR(from name: String) -> Double? {
        let pattern = #"(?i)HFR[_=]?(\d+\.?\d*)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Double(match)
    }

    // Star count: Stars234 or Stars_234
    private static func extractStarCount(from name: String) -> Int? {
        let pattern = #"(?i)stars?[_=]?(\d+)"#
        guard let match = firstMatch(pattern, in: name) else { return nil }
        return Int(match)
    }

    // MARK: - Regex Helper

    // Returns the first capture group match
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
