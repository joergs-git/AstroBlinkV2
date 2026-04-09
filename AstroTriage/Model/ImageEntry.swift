// v4.0.0
import Foundation

// Per-star quality data for problem visualization and trailing consensus analysis
struct StarDetail: Hashable {
    let x: Float          // Full-res pixel X coordinate
    let y: Float          // Full-res pixel Y coordinate
    let eccentricity: Double  // 0 = round, >0.5 = elongated
    let hfr: Double?      // Half-flux radius (nil if not measured)
    let fwhm: Double?     // Full width at half max (nil if not measured)
    // Trailing-specific metrics (from eigenvalue decomposition of 2D image moments)
    let positionAngle: Double?  // PA of elongation axis in degrees [0..180), nil if not measurable
    let axisRatio: Double?      // Minor/major eigenvalue ratio [0..1], 1 = perfectly round
}

// Core data model representing a single astro image in the session
struct ImageEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    // URL used for decoding: points to local cache for network files, same as url for local
    var decodingURL: URL

    // Session index — unique 1-based position in the loaded session (used by AIsaac and # column)
    var sessionIndex: Int = 0

    // Parsed metadata (from filename, headers, or CSV)
    var frameNumber: Int?
    var filter: String?
    var time: String?          // "23:54:58"
    var date: String?          // "2026-03-06"
    var exposure: Double?      // seconds
    var hfr: Double?
    var starCount: Int?
    var sensorTemp: Double?
    var fwhm: Double?
    var gain: Int?
    var offset: Int?
    var binning: String?       // "1x1"
    var telescope: String?
    var camera: String?
    var target: String?
    var frameType: String?     // LIGHT, FLAT, DARK, BIAS
    var focuserTemp: Double?
    var ambientTemp: Double?   // Ambient/environment temperature from AMBTEMP header
    var focusPosition: Double? // Focuser position from FOCPOS header (steps, for AF event detection)
    var mount: String?
    var bayerPattern: String?  // CFA pattern from BAYERPAT header (RGGB, GRBG, GBRG, BGGR)
    var pierSide: String?      // Pier side from PIERSIDE header (EAST or WEST)
    var rotatorAngle: Double?  // Camera rotator angle from ROTATOR header (degrees)
    var objctRA: String?       // Object RA from OBJCTRA header (e.g. "20 14 28")
    var objctDec: String?      // Object Dec from OBJCTDEC header (e.g. "+36 29 24")
    var subfolder: String      // Relative path from session root (empty if root)
    var fileSize: Int64?       // File size in bytes

    // Noise statistics (computed during prefetch from STF subsample — essentially free)
    var noiseMedian: Float?    // Background level [0,1] — median of normalized pixel values
    var noiseMAD: Float?       // Noise estimator [0,1] — 1.4826 * median absolute deviation

    // Computed star metrics (GPU star detection + CPU HFR/FWHM during prefetch)
    // These are always computed for all images to ensure per-group source consistency
    // in quality scoring. Header/filename values take display priority.
    var computedHFR: Double?        // HFR measured from image data (pixels)
    var computedFWHM: Double?       // FWHM measured from image data (pixels)
    var computedStarCount: Int?     // Number of stars measured
    var computedEccentricity: Double?  // Median star eccentricity [0..1] from 2D image moments
    var psfFluxSum: Double?            // Total estimated PSF flux (for PSFSignalWeight)
    var psfMeanFlux: Double?           // Mean PSF flux per star (resolution/seeing proxy)
    var focalLength: Double?           // From FOCALLEN header (mm) — for adaptive trailing thresholds
    var pixelSizeMicrons: Double?      // From XPIXSZ header (microns) — for arcsec/pixel computation
    var siteLatitude: Double?          // From SITELAT header — imaging site latitude
    var siteLongitude: Double?         // From SITELONG header — imaging site longitude
    var solvedRA: Double?              // Plate-solved center RA in degrees from CRVAL1 header
    var solvedDec: Double?             // Plate-solved center Dec in degrees from CRVAL2 header
    var twilightPhase: TwilightPhase?  // Sun position classification at capture time

    // Trailing analysis (computed by TrailingAnalyzer after star metrics)
    var trailingScore: Double?         // 0 = no trailing, 1 = severe trailing (consensus-weighted, FL-adaptive)
    var trailingPA: Double?            // Position angle of trailing direction (degrees, 0-180)
    var trailingAxisRatio: Double?     // Median minor/major axis ratio (1 = round, 0 = line)
    var trailingConsensus: Double?     // Fraction of stars agreeing on PA direction [0..1]

    // Star chain detection (tracking hop pattern)
    var starChainFraction: Double?     // Fraction of stars in parallel close-neighbor chains [0..1]

    // User confidence rating: 0 = unrated, 1-3 = star rating (orthogonal to quality scoring)
    var userConfidence: Int = 0

    // File identity hash (SHA256 of first 64KB) — for Frame History Database
    var fileHash: String?
    // Human-readable short ID derived from fileHash (e.g. "A3-2917")
    var shortId: String? {
        guard let hash = fileHash else { return nil }
        return Self.computeShortId(from: hash)
    }

    /// Compute human-readable short ID from file hash.
    /// Format: "XX-NNNN" (2 uppercase hex chars + 4-digit number).
    static func computeShortId(from hash: String) -> String {
        let hex = hash.uppercased()
        let prefix = String(hex.prefix(2))
        let start = hex.index(hex.startIndex, offsetBy: min(2, hex.count))
        let end = hex.index(start, offsetBy: min(4, hex.distance(from: start, to: hex.endIndex)))
        let numHex = String(hex[start..<end])
        let num = (UInt64(numHex, radix: 16) ?? 0) % 10000
        return "\(prefix)-\(String(format: "%04d", num))"
    }

    // Moon data (computed from date + site coordinates)
    var moonIllumination: Double?      // 0.0 = new moon, 1.0 = full moon
    var moonDistance: Double?          // Angular distance from target in degrees

    // Light pollution (computed from site coordinates via BortleGrid)
    var bortleClass: Double?            // Bortle 1.0 (pristine) to 9.0 (inner city), fractional

    // Canonical target name (normalized for grouping: "NGC 7000" = "NGC7000", "Orion Nebula" = "M42")
    var canonicalTarget: String?

    // Major (parent) target for sub-target association: "MEL15" → majorTarget "IC1805" (Heart Nebula)
    // nil when canonicalTarget IS the major target (most common case)
    var majorTarget: String?

    // Pixel scale for display (computed from focal length + pixel size)
    var arcsecPerPixel: Double? {
        guard let fl = focalLength, fl > 0, let px = pixelSizeMicrons, px > 0 else { return nil }
        return 206.265 * px / fl
    }

    // Per-star quality data: positions + eccentricity for problem star visualization
    // Stored during precache when star metrics are computed. Used by Compare window
    // to overlay circles on problematic stars. Coordinates are in full-res pixel space.
    var starDetails: [StarDetail]?

    // Quality breakdown (computed after header enrichment via QualityEstimator)
    // nil = group too small (<10 frames) or metrics unavailable
    // Contains: tier, combined z-score, per-metric z-scores, SNR contribution,
    // cached SNR², garbage reason, and recommendation label.
    var qualityBreakdown: QualityBreakdown?

    // Convenience accessors
    var qualityTier: QualityTier? { qualityBreakdown?.tier }
    var qualityZScore: Double? { qualityBreakdown?.combinedZScore }

    // Display helpers: prefer header/filename values, fall back to computed
    var displayHFR: Double? { hfr ?? computedHFR }
    var displayFWHM: Double? { fwhm ?? computedFWHM }
    var displayStarCount: Int? { starCount ?? computedStarCount }
    var hfrIsComputed: Bool { hfr == nil && computedHFR != nil }
    var fwhmIsComputed: Bool { fwhm == nil && computedFWHM != nil }
    var starCountIsComputed: Bool { starCount == nil && computedStarCount != nil }

    var filename: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var isXISF: Bool { fileExtension == "xisf" }
    var isFITS: Bool { ["fits", "fit", "fts"].contains(fileExtension) }

    // Triage state
    var isMarkedForDeletion: Bool = false

    // Batch modification indicator — set to true after batch rename/header edit
    var batchModified: Bool = false

    // Decoded image dimensions (populated after first decode)
    var width: Int?
    var height: Int?
    var channelCount: Int?

    // Astronomical "observing night" — the evening date of the session.
    // Images captured after midnight (00:00–11:59) belong to the previous evening's night.
    // This ensures a session from e.g. 22:00 Mar 11 to 04:00 Mar 12 is treated as one night.
    // Returns "YYYY-MM-DD" of the evening, or raw date if time is unavailable.
    var observingNight: String? {
        guard let d = date, d.count >= 10 else { return date }
        guard let t = time, t.count >= 2 else { return d }

        // Parse hour from "HH:MM:SS" or "HH:MM"
        let hourStr = String(t.prefix(2))
        guard let hour = Int(hourStr) else { return d }

        // Before noon → belongs to previous evening
        if hour < 12 {
            // Parse date and subtract one day
            let dateOnly = String(d.prefix(10))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let parsed = formatter.date(from: dateOnly),
               let prevDay = Calendar.current.date(byAdding: .day, value: -1, to: parsed) {
                return formatter.string(from: prevDay)
            }
        }
        return String(d.prefix(10))
    }

    // Sorting: combine date+time into a single comparable value
    var dateTime: String? {
        guard let d = date, let t = time else {
            return date ?? time
        }
        return "\(d) \(t)"
    }

    // Human-readable file size (e.g. "123.4 MB")
    var fileSizeFormatted: String {
        guard let size = fileSize else { return "" }
        let mb = Double(size) / (1024.0 * 1024.0)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }

    init(url: URL, subfolder: String = "") {
        self.url = url
        self.decodingURL = url
        self.subfolder = subfolder
    }
}
