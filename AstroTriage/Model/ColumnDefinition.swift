// v3.5.0
import Foundation

// Table column metadata for NSTableView configuration
struct ColumnDefinition {
    let identifier: String
    let title: String
    let defaultWidth: CGFloat
    let minWidth: CGFloat
    let isDefaultVisible: Bool
    let isHideable: Bool

    // All available columns in default display order.
    // Order: marked, #, filter, quality, snr, fwhm, hfr, stars, exp, date, time,
    //        object, filename, type, camera, ambtemp, foctemp, temp, gain,
    //        size, subfolder
    //        (hidden: telescope, binning, offset)
    // Quality metrics (Q, SNR, FWHM, HFR, Stars) grouped together right after Filter for quick scanning.
    // Filename is intentionally after data columns — NINA filenames already encode
    // date/time/filter/etc., so putting it first makes other columns redundant for sorting.
    static let allColumns: [ColumnDefinition] = [
        ColumnDefinition(identifier: "marked",      title: "",          defaultWidth: 28,  minWidth: 28,  isDefaultVisible: true,  isHideable: false),
        ColumnDefinition(identifier: "frameNumber", title: "#",         defaultWidth: 45,  minWidth: 35,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "filter",      title: "Filter",    defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "quality",     title: "Q",         defaultWidth: 28,  minWidth: 28,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "starCount",   title: "Stars",     defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "fwhm",        title: "FWHM",      defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "hfr",         title: "HFR",       defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "snr",         title: "SNR",       defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "exposure",    title: "Exp",       defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "nightDate",   title: "Night",     defaultWidth: 85,  minWidth: 70,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "time",        title: "Time",      defaultWidth: 75,  minWidth: 60,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "target",      title: "Object",    defaultWidth: 120, minWidth: 60,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "filename",    title: "Filename",  defaultWidth: 280, minWidth: 100, isDefaultVisible: true,  isHideable: false),
        ColumnDefinition(identifier: "frameType",   title: "Type",      defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "camera",      title: "Camera",    defaultWidth: 120, minWidth: 80,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "ambientTemp", title: "Amb°C",     defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "focuserTemp", title: "Foc°C",     defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "sensorTemp",  title: "Temp",      defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "gain",        title: "Gain",      defaultWidth: 45,  minWidth: 35,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "fileSize",    title: "Size",      defaultWidth: 70,  minWidth: 50,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "subfolder",   title: "Subfolder", defaultWidth: 80,  minWidth: 50,  isDefaultVisible: true,  isHideable: true),
        // Hidden-by-default columns
        ColumnDefinition(identifier: "date",        title: "Date",      defaultWidth: 85,  minWidth: 70,  isDefaultVisible: false, isHideable: true),
        ColumnDefinition(identifier: "telescope",   title: "Telescope", defaultWidth: 80,  minWidth: 60,  isDefaultVisible: false, isHideable: true),
        ColumnDefinition(identifier: "binning",     title: "Binning",   defaultWidth: 55,  minWidth: 40,  isDefaultVisible: false, isHideable: true),
        ColumnDefinition(identifier: "offset",      title: "Offset",    defaultWidth: 50,  minWidth: 35,  isDefaultVisible: false, isHideable: true),
    ]

    // Default visible column identifiers (factory defaults)
    static let defaultVisibleColumnIds: [String] = allColumns.filter(\.isDefaultVisible).map(\.identifier)

    // Column tail: shared columns that appear after the primary metrics
    private static let columnTail: [String] = [
        "filename", "frameType", "camera",
        "ambientTemp", "focuserTemp", "sensorTemp", "gain", "fileSize", "subfolder",
        "date", "telescope", "binning", "offset"
    ]

    // Case A: Single target, multi filter — filter groups the data, quality within each filter
    // Sort: filter ASC → time DESC (chronological within each filter group)
    private static let singleTargetMultiFilter: [String] =
        ["marked", "frameNumber", "filter", "quality", "starCount", "fwhm", "hfr", "snr",
         "exposure", "nightDate", "time", "target"] + columnTail

    // Case B: Single target, single filter — all images are "the same", quality + time matter
    // Sort: time DESC (chronological through the night)
    private static let singleTargetSingleFilter: [String] =
        ["marked", "frameNumber", "quality", "starCount", "fwhm", "hfr", "snr",
         "time", "exposure", "nightDate", "filter", "target"] + columnTail

    // Case C: Multi target, multi filter — target groups first, then filter within target
    // Sort: target ASC → filter ASC → time DESC
    private static let multiTargetMultiFilter: [String] =
        ["marked", "frameNumber", "target", "filter", "quality", "starCount", "fwhm", "hfr", "snr",
         "exposure", "nightDate", "time"] + columnTail

    // Case D: Multi target, single filter — target groups, quality within each target
    // Sort: target ASC → time DESC
    private static let multiTargetSingleFilter: [String] =
        ["marked", "frameNumber", "target", "quality", "starCount", "fwhm", "hfr", "snr",
         "time", "exposure", "nightDate", "filter"] + columnTail

    /// Returns the recommended column order based on session composition
    static func recommendedColumnOrder(isMultiObject: Bool, isMultiFilter: Bool) -> [String] {
        if isMultiObject {
            return isMultiFilter ? multiTargetMultiFilter : multiTargetSingleFilter
        } else {
            return isMultiFilter ? singleTargetMultiFilter : singleTargetSingleFilter
        }
    }

    // Get the string value for a given column from an ImageEntry.
    // The "quality" column returns "" — its cell is rendered as an SF Symbol icon, not text.
    static func value(for columnId: String, from entry: ImageEntry) -> String {
        switch columnId {
        case "frameNumber": return entry.frameNumber.map { String($0) } ?? ""
        case "filter":      return entry.filter ?? ""
        case "quality":     return ""  // Icon cell; handled separately in FileListView
        case "time":        return entry.time ?? ""
        case "date":        return entry.date ?? ""
        case "nightDate":   return entry.observingNight ?? ""
        case "exposure":    return entry.exposure.map { formatExposure($0) } ?? ""
        case "hfr":         return entry.displayHFR.map { String(format: "%.2f", $0) } ?? ""
        case "starCount":   return entry.displayStarCount.map { String($0) } ?? ""
        case "sensorTemp":  return entry.sensorTemp.map { String(format: "%.1f", $0) } ?? ""
        case "fwhm":        return entry.displayFWHM.map { String(format: "%.2f", $0) } ?? ""
        case "gain":        return entry.gain.map { String($0) } ?? ""
        case "fileSize":    return entry.fileSizeFormatted
        case "subfolder":   return entry.subfolder
        case "filename":    return entry.filename
        case "target":      return entry.target ?? ""
        case "telescope":   return entry.telescope ?? ""
        case "camera":      return entry.camera ?? ""
        case "binning":     return entry.binning ?? ""
        case "offset":      return entry.offset.map { String($0) } ?? ""
        case "focuserTemp": return entry.focuserTemp.map { String(format: "%.1f", $0) } ?? ""
        case "ambientTemp": return entry.ambientTemp.map { String(format: "%.1f", $0) } ?? ""
        case "frameType":   return entry.frameType ?? ""
        case "snr":
            // SNR = median / MAD (same formula as Quality Overview)
            guard let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return "" }
            let snr = med / mad
            return String(format: "%.0f", snr)
        default:            return ""
        }
    }

    // Get a numeric value for sorting (returns nil for non-numeric / non-sortable columns)
    static func numericValue(for columnId: String, from entry: ImageEntry) -> Double? {
        switch columnId {
        case "frameNumber": return entry.frameNumber.map { Double($0) }
        case "exposure":    return entry.exposure
        case "hfr":         return entry.displayHFR
        case "starCount":   return entry.displayStarCount.map { Double($0) }
        case "sensorTemp":  return entry.sensorTemp
        case "fwhm":        return entry.displayFWHM
        case "gain":        return entry.gain.map { Double($0) }
        case "offset":      return entry.offset.map { Double($0) }
        case "focuserTemp": return entry.focuserTemp
        case "ambientTemp": return entry.ambientTemp
        case "fileSize":    return entry.fileSize.map { Double($0) }
        case "quality":     return entry.qualityZScore ?? entry.qualityTier.map { Double($0.rawValue) }
        case "snr":
            guard let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
            return Double(med / mad)
        default:            return nil
        }
    }

    // Returns true for columns that should sort descending by default when used as a sort key.
    // Numeric columns: highest value first.
    // Date/time columns: newest first (lexicographic descending works for ISO-8601 format).
    static func isDefaultDescending(_ columnId: String) -> Bool {
        switch columnId {
        case "frameNumber", "exposure", "starCount", "sensorTemp",
             "gain", "offset", "focuserTemp", "ambientTemp", "fileSize", "snr",
             "quality", "date", "nightDate", "time":
            return true
        // fwhm and hfr: lower = better → default ascending (best first)
        case "fwhm", "hfr":
            return false
        default:
            return false
        }
    }

    // Returns true if this column has numeric values (used for header click sort indicator)
    static func isNumericColumn(_ columnId: String) -> Bool {
        switch columnId {
        case "frameNumber", "exposure", "hfr", "starCount", "sensorTemp",
             "fwhm", "gain", "offset", "focuserTemp", "ambientTemp", "fileSize", "snr", "quality":
            return true
        default:
            return false
        }
    }

    // Column header tooltips — explains what each metric is, how it's computed, and why it matters
    static func headerToolTip(for columnId: String) -> String? {
        switch columnId {
        case "quality":
            return "Four-tier quality score within group (same filter + target + exposure).\nStage 1: Red if any metric catastrophically bad (< 50% of group median).\nStage 2: Weighted z-scores of stars, FWHM, HFR, noise.\nFull green = excellent, half-green = good, orange = borderline, red = garbage."
        case "snr":
            return "Signal-to-Noise Ratio.\nComputed from median pixel value / noise MAD during auto-stretch.\nHigher = cleaner signal. Affected by exposure, light pollution, clouds."
        case "fwhm":
            return "Full Width at Half Maximum of stars (arcsec).\nMeasured by GPU star detection + Gaussian fitting.\nLower = sharper stars = better seeing/focus."
        case "hfr":
            return "Half-Flux Radius of stars.\nFrom NINA filename token, CSV, or GPU star detection.\nLower = tighter stars = better focus."
        case "starCount":
            return "Total number of stars detected in the image.\nFrom NINA filename token, CSV, or GPU star detection.\nFewer stars may indicate clouds, fog, or tracking issues."
        case "filter":
            return "Active filter during capture.\nRead from FITS/XISF FILTER header keyword.\nCommon: L (Luminance), R/G/B, H (Ha), O (OIII), S (SII)."
        case "nightDate":
            return "Observing night (evening date).\nImages taken after midnight are mapped to the previous evening.\nUseful for grouping a single session that spans midnight."
        case "exposure":
            return "Exposure time in seconds.\nFrom FITS/XISF EXPTIME header or NINA filename token."
        case "sensorTemp":
            return "Camera sensor temperature (°C).\nFrom CCD-TEMP header keyword.\nLower = less thermal noise."
        case "focuserTemp":
            return "Focuser temperature (°C).\nFrom FOCTEMP header keyword.\nTemperature shifts cause focus drift."
        case "ambientTemp":
            return "Ambient/environment temperature (°C).\nFrom AMBTEMP header keyword."
        case "gain":
            return "Camera gain setting.\nFrom GAIN header keyword.\nHigher gain = more sensitivity but more read noise."
        case "frameNumber":
            return "Frame sequence number from NINA filename (#0001, #0002, ...)."
        case "filename":
            return "Full filename including NINA tokens.\nDouble-click column header to auto-resize width."
        default:
            return nil
        }
    }

    // Format exposure value: show integer if whole number, otherwise one decimal
    private static func formatExposure(_ value: Double) -> String {
        if value == value.rounded() && value >= 1 {
            return String(format: "%.0fs", value)
        } else {
            return String(format: "%.2fs", value)
        }
    }
}
