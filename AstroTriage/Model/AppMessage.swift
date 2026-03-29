// In-App Messaging models — Codable structs for Supabase REST API
// Matches the app_messages, message_interactions, device_entitlements tables

import Foundation

// MARK: - App Message

struct AppMessage: Codable, Identifiable {
    let id: String
    let title: String
    let body: String
    let message_type: String      // info, warning, update_nudge, feedback, email_collect
    let display_mode: String      // banner, modal
    let actions: [AppMessageAction]

    // Targeting
    let min_app_version: String?
    let max_app_version: String?
    let platform: String          // macos, ios, all
    let min_session_count: Int?
    let min_frame_count: Int?
    let max_frame_count: Int?

    // Conditional targeting
    let requires_entitlement: String?
    let excludes_entitlement: String?
    let requires_response_to: String?
    let excludes_response_to: String?

    // Scheduling
    let starts_at: String
    let expires_at: String?
    let snooze_hours: Int

    // Repeat behavior
    let repeat_mode: String       // once, always, interval
    let repeat_interval_hours: Int?

    // Control
    let is_active: Bool
    let priority: Int

    let created_at: String?
    let updated_at: String?
}

// MARK: - Message Action (JSONB array element)

struct AppMessageAction: Codable {
    let type: String              // dismiss, yes, no, later, email_input, text_input, radio, slider, link

    // Common
    let label: String?

    // For email_input / text_input
    let placeholder: String?

    // For radio
    let options: [String]?

    // For slider
    let min: Int?
    let max: Int?
    let step: Int?

    // For link
    let url: String?
}

// MARK: - Message Interaction (per device per message)

struct MessageInteraction: Codable, Identifiable {
    var id: String?
    let message_id: String
    let machine_hash: String
    let app_version: String
    let shown_at: String?
    var shown_count: Int
    var last_shown_at: String?
    var responded_at: String?
    var action_type: String?
    var response_value: String?
    var dismissed_at: String?
    var snoozed_until: String?
}

// MARK: - Device Entitlement

struct DeviceEntitlement: Codable {
    let machine_hash: String
    let entitlement: String
    let value: String?
    let granted_at: String?
    let expires_at: String?
}

// MARK: - Helpers

extension AppMessage {

    /// Parse ISO8601 date string (Supabase format)
    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        // Fallback without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    var startsAtDate: Date? { Self.parseDate(starts_at) }
    var expiresAtDate: Date? { Self.parseDate(expires_at) }

    /// SF Symbol name based on message type
    var iconName: String {
        switch message_type {
        case "warning":      return "exclamationmark.triangle.fill"
        case "update_nudge": return "arrow.up.circle.fill"
        case "feedback":     return "hand.thumbsup.fill"
        case "email_collect": return "envelope.fill"
        default:             return "info.circle.fill"
        }
    }
}

extension MessageInteraction {

    var snoozedUntilDate: Date? { AppMessage.parseDate(snoozed_until) }
    var dismissedAtDate: Date? { AppMessage.parseDate(dismissed_at) }

    /// Current ISO8601 timestamp string
    static var nowString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

extension DeviceEntitlement {

    var expiresAtDate: Date? { AppMessage.parseDate(expires_at) }

    /// Check if entitlement is currently valid (not expired)
    var isValid: Bool {
        guard let expires = expiresAtDate else { return true }  // NULL = permanent
        return Date() < expires
    }
}

// MARK: - Semver Comparison

enum SemverCompare {
    /// Compare two semver strings. Returns .orderedAscending if a < b, etc.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<Swift.max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }
}
