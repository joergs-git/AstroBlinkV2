// v5.1.3
import Foundation
import SwiftUI

// Environment key for global font scale factor (Cmd+/Cmd- adjustable)
private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

// View modifier that scales all .font(.system(size:)) calls via environment
extension View {
    /// Apply a scaled system font using the environment font scale
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(baseSize: size, weight: weight, design: design))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScale) private var fontScale
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: round(baseSize * fontScale), weight: weight, design: design))
    }
}

// Centralized settings wrapper with iCloud sync via NSUbiquitousKeyValueStore.
// All settings sync across devices automatically when iCloud is available.
// Falls back to UserDefaults-only when iCloud is unavailable.
struct AppSettings {
    static let defaults = UserDefaults.standard
    static let cloud = NSUbiquitousKeyValueStore.default

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
        case autoMeridian         // Bool — auto-rotate images across meridian flip
        case sessionCount         // Int — number of sessions opened (for App Store review prompt)
        case hideSplash           // Bool — never show splash screen on launch
        case communityLearning    // Bool — opt-in to community detection learning (default: off)
        case fontScale            // Float — UI font scale factor (1.0 = default)
    }

    // Start observing iCloud changes (call once at app launch)
    static func startCloudSync() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { notification in
            // Merge cloud changes into UserDefaults
            guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
            for key in changedKeys {
                if let value = cloud.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        cloud.synchronize()
    }

    // MARK: - Save (dual-write: UserDefaults + iCloud)

    static func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        cloud.set(value, forKey: key.rawValue)
    }

    static func saveBool(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        cloud.set(value, forKey: key.rawValue)
    }

    static func saveFloat(_ value: Float, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        cloud.set(Double(value), forKey: key.rawValue)  // NSUbiquitousKeyValueStore uses Double
    }

    static func saveStrings(_ value: [String], for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        cloud.set(value, forKey: key.rawValue)
    }

    // MARK: - Load (UserDefaults is primary, cloud merges on change notification)

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
                    .nightMode, .debayerEnabled, .skipMarked, .hideMarked,
                    .autoMeridian] {
            defaults.removeObject(forKey: key.rawValue)
            cloud.removeObject(forKey: key.rawValue)
        }
    }
}
