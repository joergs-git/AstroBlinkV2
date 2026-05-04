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
        case hasSeenOnboarding    // Bool — true after user dismissed the first-launch onboarding
        case communityLearning    // Bool — DEPRECATED legacy master toggle. Kept for the
                                  // one-time migration in `migrateLegacyTelemetryToggle()`;
                                  // do not gate new code on it. Read the granular sub-toggles
                                  // below instead.

        // Granular telemetry sub-toggles (split from the legacy `communityLearning` key).
        // Each gates a distinct outbound traffic path so users can opt in/out per category
        // rather than all-or-nothing. Defaults: all true (matching previous behaviour for
        // existing users via `migrateLegacyTelemetryToggle()`).
        case telemetryPerformanceBenchmarks  // Bool — anonymous hardware/timing benchmarks
                                              // (BenchmarkSharing.swift, AppMessageService.recordAppStart)
        case telemetryFrameQualityRatings    // Bool — equipment + target metadata sent with
                                              // every star rating (CurationService.swift)
        case telemetryCommunityBaselines     // Bool — anonymous quality-metric aggregates for
                                              // community calibration (CommunityDetectionService.swift)
        case telemetryMigrationComplete      // Bool — set true after the one-time
                                              // legacy → granular migration runs successfully
        case fontScale            // Float — UI font scale factor (1.0 = default)
        case dismissedMessageIDs  // [String] — UUIDs of permanently dismissed in-app messages
        case snoozedMessages      // Data — encoded [String: Date] of snoozed message ID → snooze-until date
        case seenDefaultColumns   // [String] — default-visible column ids seen by user (tracks auto-migration of new columns)
        case showSessionOverviewPanel  // Bool — right-side Session Overview panel visibility (persisted across sessions & iCloud)
        case showViewerOverlay    // Bool — filter letter / time / mini-map overlay in image viewer (top-left)
        case coffeeNextPromptAt   // Int — sessionCount value at which to show the next "buy me a coffee" dialog
        case coffeeThanked        // Bool — user already donated (or said "no thanks") → never prompt again
    }

    // Register defaults for new installs (call once at app launch, before startCloudSync)
    static func registerDefaults() {
        defaults.register(defaults: [
            Key.communityLearning.rawValue: true,            // legacy master, kept for migration
            Key.telemetryPerformanceBenchmarks.rawValue: true,
            Key.telemetryFrameQualityRatings.rawValue: true,
            Key.telemetryCommunityBaselines.rawValue: true,
            Key.showViewerOverlay.rawValue:  true,           // overlay on by default; user can dismiss via ⌘⇧O
        ])
        migrateLegacyTelemetryToggle()
    }

    /// One-time migration: if the user explicitly opted out of the old monolithic
    /// `communityLearning` toggle, propagate that choice to all three new granular
    /// sub-toggles so we don't silently re-enable telemetry under the new keys.
    /// Idempotent — guarded by `telemetryMigrationComplete`.
    private static func migrateLegacyTelemetryToggle() {
        guard !defaults.bool(forKey: Key.telemetryMigrationComplete.rawValue) else { return }

        // `defaults.bool(forKey:)` returns the registered default (true) when the user
        // never wrote a value, or the explicit user value (typically false) when they
        // opted out. Either way we propagate the same value to all three sub-toggles —
        // matching the legacy "all or nothing" behaviour exactly.
        let legacy = defaults.bool(forKey: Key.communityLearning.rawValue)
        defaults.set(legacy, forKey: Key.telemetryPerformanceBenchmarks.rawValue)
        defaults.set(legacy, forKey: Key.telemetryFrameQualityRatings.rawValue)
        defaults.set(legacy, forKey: Key.telemetryCommunityBaselines.rawValue)
        defaults.set(true, forKey: Key.telemetryMigrationComplete.rawValue)
    }

    // MARK: - Telemetry helpers

    /// True when the user has opted in to all three telemetry categories — used by
    /// the status-bar master indicator and the Onboarding splash toggle.
    static var allTelemetryEnabled: Bool {
        defaults.bool(forKey: Key.telemetryPerformanceBenchmarks.rawValue) &&
        defaults.bool(forKey: Key.telemetryFrameQualityRatings.rawValue) &&
        defaults.bool(forKey: Key.telemetryCommunityBaselines.rawValue)
    }

    /// True when the user has opted out of every telemetry category.
    static var noTelemetryEnabled: Bool {
        !defaults.bool(forKey: Key.telemetryPerformanceBenchmarks.rawValue) &&
        !defaults.bool(forKey: Key.telemetryFrameQualityRatings.rawValue) &&
        !defaults.bool(forKey: Key.telemetryCommunityBaselines.rawValue)
    }

    /// Set all three telemetry sub-toggles in one shot (used by the master switch
    /// in the status-bar popover and Onboarding splash).
    static func setAllTelemetry(_ enabled: Bool) {
        save(enabled, for: .telemetryPerformanceBenchmarks)
        save(enabled, for: .telemetryFrameQualityRatings)
        save(enabled, for: .telemetryCommunityBaselines)
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
