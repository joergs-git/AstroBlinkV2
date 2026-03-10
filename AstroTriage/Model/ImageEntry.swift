// v3.2.0
import Foundation

// Core data model representing a single astro image in the session
struct ImageEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    // URL used for decoding: points to local cache for network files, same as url for local
    var decodingURL: URL

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
    var mount: String?
    var bayerPattern: String?  // CFA pattern from BAYERPAT header (RGGB, GRBG, GBRG, BGGR)
    var pierSide: String?      // Pier side from PIERSIDE header (EAST or WEST)
    var objctRA: String?       // Object RA from OBJCTRA header (e.g. "20 14 28")
    var objctDec: String?      // Object Dec from OBJCTDEC header (e.g. "+36 29 24")
    var subfolder: String      // Relative path from session root (empty if root)
    var fileSize: Int64?       // File size in bytes

    // Noise statistics (computed during prefetch from STF subsample — essentially free)
    var noiseMedian: Float?    // Background level [0,1] — median of normalized pixel values
    var noiseMAD: Float?       // Noise estimator [0,1] — 1.4826 * median absolute deviation

    // Display helpers
    var filename: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var isXISF: Bool { fileExtension == "xisf" }
    var isFITS: Bool { ["fits", "fit", "fts"].contains(fileExtension) }

    // Triage state
    var isMarkedForDeletion: Bool = false

    // Decoded image dimensions (populated after first decode)
    var width: Int?
    var height: Int?
    var channelCount: Int?

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
