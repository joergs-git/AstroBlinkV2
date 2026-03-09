// v2.2.0
import Foundation

// Table column metadata for NSTableView configuration
struct ColumnDefinition {
    let identifier: String
    let title: String
    let defaultWidth: CGFloat
    let minWidth: CGFloat
    let isDefaultVisible: Bool
    let isHideable: Bool

    // All available columns in default display order
    // Order: checkbox, #, filename, object, date, time, type, camera, filter, exp, ambtemp, foctemp, temp, gain, size, fwhm, hfr, stars, subfolder
    static let allColumns: [ColumnDefinition] = [
        ColumnDefinition(identifier: "marked",      title: "",          defaultWidth: 28,  minWidth: 28,  isDefaultVisible: true,  isHideable: false),
        ColumnDefinition(identifier: "frameNumber", title: "#",         defaultWidth: 45,  minWidth: 35,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "filename",    title: "Filename",  defaultWidth: 280, minWidth: 100, isDefaultVisible: true,  isHideable: false),
        ColumnDefinition(identifier: "target",      title: "Object",    defaultWidth: 120, minWidth: 60,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "date",        title: "Date",      defaultWidth: 85,  minWidth: 70,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "time",        title: "Time",      defaultWidth: 75,  minWidth: 60,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "frameType",   title: "Type",      defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "camera",      title: "Camera",    defaultWidth: 120, minWidth: 80,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "filter",      title: "Filter",    defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "exposure",    title: "Exp",       defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "ambientTemp", title: "Amb°C",     defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "focuserTemp", title: "Foc°C",     defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "sensorTemp",  title: "Temp",      defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "gain",        title: "Gain",      defaultWidth: 45,  minWidth: 35,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "fileSize",    title: "Size",      defaultWidth: 70,  minWidth: 50,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "fwhm",        title: "FWHM",      defaultWidth: 55,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "hfr",         title: "HFR",       defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "starCount",   title: "Stars",     defaultWidth: 50,  minWidth: 40,  isDefaultVisible: true,  isHideable: true),
        ColumnDefinition(identifier: "subfolder",   title: "Subfolder", defaultWidth: 80,  minWidth: 50,  isDefaultVisible: true,  isHideable: true),
        // Hidden-by-default columns
        ColumnDefinition(identifier: "telescope",   title: "Telescope",   defaultWidth: 80,  minWidth: 60, isDefaultVisible: false, isHideable: true),
        ColumnDefinition(identifier: "binning",     title: "Binning",     defaultWidth: 55,  minWidth: 40, isDefaultVisible: false, isHideable: true),
        ColumnDefinition(identifier: "offset",      title: "Offset",      defaultWidth: 50,  minWidth: 35, isDefaultVisible: false, isHideable: true),
    ]

    // Default visible column identifiers (factory defaults)
    static let defaultVisibleColumnIds: [String] = allColumns.filter(\.isDefaultVisible).map(\.identifier)

    // Get the string value for a given column from an ImageEntry
    static func value(for columnId: String, from entry: ImageEntry) -> String {
        switch columnId {
        case "frameNumber": return entry.frameNumber.map { String($0) } ?? ""
        case "filter":      return entry.filter ?? ""
        case "time":        return entry.time ?? ""
        case "date":        return entry.date ?? ""
        case "exposure":    return entry.exposure.map { formatExposure($0) } ?? ""
        case "hfr":         return entry.hfr.map { String(format: "%.2f", $0) } ?? ""
        case "starCount":   return entry.starCount.map { String($0) } ?? ""
        case "sensorTemp":  return entry.sensorTemp.map { String(format: "%.1f", $0) } ?? ""
        case "fwhm":        return entry.fwhm.map { String(format: "%.2f", $0) } ?? ""
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
        default:            return ""
        }
    }

    // Get a numeric value for sorting (returns nil for non-numeric columns)
    static func numericValue(for columnId: String, from entry: ImageEntry) -> Double? {
        switch columnId {
        case "frameNumber": return entry.frameNumber.map { Double($0) }
        case "exposure":    return entry.exposure
        case "hfr":         return entry.hfr
        case "starCount":   return entry.starCount.map { Double($0) }
        case "sensorTemp":  return entry.sensorTemp
        case "fwhm":        return entry.fwhm
        case "gain":        return entry.gain.map { Double($0) }
        case "offset":      return entry.offset.map { Double($0) }
        case "focuserTemp": return entry.focuserTemp
        case "ambientTemp": return entry.ambientTemp
        case "fileSize":    return entry.fileSize.map { Double($0) }
        default:            return nil
        }
    }

    // Returns true if this column has numeric values (for default descending sort)
    static func isNumericColumn(_ columnId: String) -> Bool {
        switch columnId {
        case "frameNumber", "exposure", "hfr", "starCount", "sensorTemp",
             "fwhm", "gain", "offset", "focuserTemp", "ambientTemp", "fileSize":
            return true
        default:
            return false
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
