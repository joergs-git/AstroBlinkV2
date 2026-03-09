// v2.2.0
import Foundation

// Centralized UserDefaults wrapper for persistent app settings
// Saves user preferences (column config, slider values, toggle states) across sessions
struct AppSettings {
    static let defaults = UserDefaults.standard

    // UserDefaults keys
    enum Key: String {
        case columnOrder          // [String] — ordered column identifiers
        case visibleColumns       // [String] — which columns are shown
        case stretchStrength      // Float — last STF slider value
        case sharpening           // Float
        case contrast             // Float
        case darkLevel            // Float
        case nightMode            // Bool
        case debayerEnabled       // Bool
        case skipMarked           // Bool
        case hideMarked           // Bool
    }

    // MARK: - Save

    static func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    static func saveBool(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    static func saveFloat(_ value: Float, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    static func saveStrings(_ value: [String], for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    // MARK: - Load

    static func loadBool(for key: Key) -> Bool? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.bool(forKey: key.rawValue)
    }

    static func loadFloat(for key: Key) -> Float? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.float(forKey: key.rawValue)
    }

    static func loadStrings(for key: Key) -> [String]? {
        defaults.stringArray(forKey: key.rawValue)
    }

    // MARK: - Reset

    static func resetAll() {
        for key in [Key.columnOrder, .visibleColumns, .stretchStrength,
                    .sharpening, .contrast, .darkLevel,
                    .nightMode, .debayerEnabled, .skipMarked, .hideMarked] {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
