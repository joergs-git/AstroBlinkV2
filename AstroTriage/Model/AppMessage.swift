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

    // Optional media (v6.9.0). All three are Optional so that rows created before the
    // media migration — and message caches written by older builds — still decode.
    let media_url: String?        // YouTube / Vimeo watch, short or embed URL
    let media_type: String?       // "video" (only kind supported today), nil = none
    let poster_url: String?       // Reserved: still image shown before playback starts

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

// MARK: - Link Safety

/// Single gate for every clickable URL that originates in remote message content
/// (action links and markdown links in the body).
///
/// Message rows are authored server-side, so a link in one must never be able to hand an
/// arbitrary scheme to LaunchServices — `file:`, `mailto:` or whatever a third-party app
/// has registered. Only https passes; a rejected link degrades to plain text. (v6.9.0)
enum AppMessageLink {

    static func safe(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    static func safe(_ string: String?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return safe(URL(string: string))
    }
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

    /// True when this message should be presented as a blocking popup rather than the
    /// inline top banner. The column has existed since the original schema; until v6.9.0
    /// nothing read it and every message rendered as a banner.
    var isModal: Bool { display_mode == "modal" }

    /// Playable embed URL for `media_url`, or nil if there is no usable video.
    ///
    /// SECURITY: `media_url` arrives from a remote table, so it is never handed to a web
    /// view as-is. Only https and an explicit host allowlist are accepted; everything else
    /// (including http, file:, javascript: and any unknown host) yields nil and the message
    /// simply renders without a video. YouTube is rewritten to the -nocookie domain so a
    /// viewer is not tracked for merely reading an announcement.
    var videoEmbedURL: URL? {
        guard media_type == "video",
              let raw = media_url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased()
        else { return nil }

        // The path must match one of the known shapes EXACTLY. Picking "the last segment"
        // of an arbitrary path would silently accept a malformed URL (e.g.
        // /embed/../../etc/passwd → "passwd") and turn it into a different, valid-looking
        // embed. Anything that is not a shape we recognise is rejected outright.
        let segments = components.path.split(separator: "/").map(String.init)

        func queryItem(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        func isSafeID(_ id: String) -> Bool {
            !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        func youTubeEmbed(_ id: String) -> String? {
            isSafeID(id) ? "https://www.youtube-nocookie.com/embed/\(id)" : nil
        }

        var embed: String?
        switch host {
        case "www.youtube.com", "youtube.com", "m.youtube.com",
             "www.youtube-nocookie.com", "youtube-nocookie.com":
            if segments.count == 2, segments[0] == "embed" {
                embed = youTubeEmbed(segments[1])                    // /embed/<id>
            } else if segments == ["watch"], let id = queryItem("v") {
                embed = youTubeEmbed(id)                             // /watch?v=<id>
            }
        case "youtu.be":
            if segments.count == 1 { embed = youTubeEmbed(segments[0]) }   // /<id>
        case "vimeo.com", "www.vimeo.com", "player.vimeo.com":
            // Vimeo ids are numeric; the player domain uses /video/<id>.
            let id: String?
            if segments.count == 1 {
                id = segments[0]
            } else if segments.count == 2, segments[0] == "video" {
                id = segments[1]
            } else {
                id = nil
            }
            if let id, isSafeID(id), id.allSatisfy(\.isNumber) {
                embed = "https://player.vimeo.com/video/\(id)"
            }
        default:
            return nil
        }

        guard let embed else { return nil }
        return URL(string: embed)
    }

    /// The video's link for "open in browser", or nil when there is no usable video.
    ///
    /// Gated on `videoEmbedURL` so the https + host allowlist applies here too — this URL
    /// is handed to the user's browser, so it must clear exactly the same bar as the one we
    /// embed. Prefers the authored URL (usually a watch page, which is the friendlier thing
    /// to land on) and falls back to the embed.
    var videoWatchURL: URL? {
        guard let embed = videoEmbedURL else { return nil }
        return AppMessageLink.safe(media_url) ?? embed
    }

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
