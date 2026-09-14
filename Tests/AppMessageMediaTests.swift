// Tests for AppMessage media handling (v6.9.0).
//
// videoEmbedURL is a security boundary: media_url comes from a remote Supabase table and
// is handed to a WKWebView. These tests pin the https + host allowlist, the id sanitising
// and the normalisation to the privacy-preserving YouTube domain.

import XCTest
@testable import AstroTriage

final class AppMessageMediaTests: XCTestCase {

    /// Build a minimal message; only the fields under test vary.
    private func makeMessage(displayMode: String = "banner",
                             mediaURL: String? = nil,
                             mediaType: String? = nil) -> AppMessage {
        AppMessage(
            id: "test-id",
            title: "Title",
            body: "Body",
            message_type: "info",
            display_mode: displayMode,
            actions: [],
            media_url: mediaURL,
            media_type: mediaType,
            poster_url: nil,
            min_app_version: nil,
            max_app_version: nil,
            platform: "macos",
            min_session_count: nil,
            min_frame_count: nil,
            max_frame_count: nil,
            requires_entitlement: nil,
            excludes_entitlement: nil,
            requires_response_to: nil,
            excludes_response_to: nil,
            starts_at: "2026-01-01T00:00:00Z",
            expires_at: nil,
            snooze_hours: 168,
            repeat_mode: "once",
            repeat_interval_hours: nil,
            is_active: true,
            priority: 0,
            created_at: nil,
            updated_at: nil
        )
    }

    private func embed(_ url: String?, type: String? = "video") -> String? {
        makeMessage(mediaURL: url, mediaType: type).videoEmbedURL?.absoluteString
    }

    // MARK: - Accepted forms

    func testYouTubeWatchURLBecomesNoCookieEmbed() {
        XCTAssertEqual(embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                       "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    }

    func testYouTubeShortURLBecomesNoCookieEmbed() {
        XCTAssertEqual(embed("https://youtu.be/dQw4w9WgXcQ"),
                       "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    }

    func testYouTubeEmbedURLIsNormalisedToNoCookie() {
        XCTAssertEqual(embed("https://www.youtube.com/embed/dQw4w9WgXcQ"),
                       "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    }

    func testYouTubeWatchURLWithExtraQueryParamsKeepsOnlyTheID() {
        // Timestamps/playlist params are common in copy-pasted links.
        XCTAssertEqual(embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PLabc"),
                       "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    }

    func testVimeoURLBecomesPlayerEmbed() {
        XCTAssertEqual(embed("https://vimeo.com/123456789"),
                       "https://player.vimeo.com/video/123456789")
    }

    // MARK: - Rejected forms (security boundary)

    func testHTTPIsRejected() {
        // Only https may reach the web view.
        XCTAssertNil(embed("http://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testUnknownHostIsRejected() {
        XCTAssertNil(embed("https://evil.example.com/embed/dQw4w9WgXcQ"))
    }

    func testLookalikeHostIsRejected() {
        // Suffix matching would let this through; the allowlist is exact-match.
        XCTAssertNil(embed("https://youtube.com.evil.example/embed/abc"))
    }

    func testJavascriptSchemeIsRejected() {
        XCTAssertNil(embed("javascript:alert(1)"))
    }

    func testFileSchemeIsRejected() {
        XCTAssertNil(embed("file:///etc/passwd"))
    }

    func testPathTraversalInIDIsRejected() {
        // lastSegment() plus the character allowlist must defeat this.
        XCTAssertNil(embed("https://www.youtube.com/embed/../../etc/passwd"))
    }

    func testNonNumericVimeoIDIsRejected() {
        XCTAssertNil(embed("https://vimeo.com/not-a-number"))
    }

    // MARK: - Absence of media

    func testNilMediaURLYieldsNoVideo() {
        XCTAssertNil(embed(nil))
    }

    func testEmptyMediaURLYieldsNoVideo() {
        XCTAssertNil(embed("   "))
    }

    func testMediaTypeMustBeVideo() {
        // A future media_type must not be rendered as a video by an older build.
        XCTAssertNil(embed("https://youtu.be/dQw4w9WgXcQ", type: "image"))
        XCTAssertNil(embed("https://youtu.be/dQw4w9WgXcQ", type: nil))
    }

    // MARK: - Display mode

    func testIsModalOnlyForModalDisplayMode() {
        XCTAssertTrue(makeMessage(displayMode: "modal").isModal)
        XCTAssertFalse(makeMessage(displayMode: "banner").isModal)
        // Unknown values must fall back to the banner, never to a blocking popup.
        XCTAssertFalse(makeMessage(displayMode: "something_new").isModal)
    }

    // MARK: - "Open in browser" URL

    private func watch(_ url: String?, type: String? = "video") -> String? {
        makeMessage(mediaURL: url, mediaType: type).videoWatchURL?.absoluteString
    }

    func testWatchURLPrefersTheAuthoredWatchPage() {
        // The browser should land on the normal watch page, not the bare embed.
        XCTAssertEqual(watch("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                       "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testWatchURLFallsBackToEmbedWhenThatIsAllWeHave() {
        XCTAssertEqual(watch("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"),
                       "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    }

    func testWatchURLIsNilWhenTheEmbedWasRejected() {
        // Must never hand the browser a URL the embed allowlist refused.
        XCTAssertNil(watch("https://evil.example.com/embed/abc"))
        XCTAssertNil(watch("http://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(watch("javascript:alert(1)"))
        XCTAssertNil(watch(nil))
        XCTAssertNil(watch("https://youtu.be/dQw4w9WgXcQ", type: nil))
    }

    // MARK: - Link safety (action links + markdown links in the body)

    func testOnlyHTTPSLinksAreAccepted() {
        XCTAssertEqual(AppMessageLink.safe("https://example.com/a")?.absoluteString,
                       "https://example.com/a")
        // Scheme comparison is case-insensitive.
        XCTAssertNotNil(AppMessageLink.safe("HTTPS://example.com/a"))
    }

    func testNonHTTPSLinksAreRejected() {
        for unsafe in ["http://example.com",
                       "file:///etc/passwd",
                       "mailto:someone@example.com",
                       "javascript:alert(1)",
                       "ftp://example.com",
                       "x-custom-app://do-something"] {
            XCTAssertNil(AppMessageLink.safe(unsafe), "should reject \(unsafe)")
        }
    }

    func testEmptyAndNilLinksAreRejected() {
        XCTAssertNil(AppMessageLink.safe(nil as String?))
        XCTAssertNil(AppMessageLink.safe(""))
        XCTAssertNil(AppMessageLink.safe(nil as URL?))
    }

    // MARK: - Backward compatibility

    func testMessageWithoutMediaColumnsStillDecodes() throws {
        // Rows created before the media migration, and caches written by older builds,
        // carry none of the three media keys.
        let json = """
        {
          "id": "abc", "title": "T", "body": "B",
          "message_type": "info", "display_mode": "banner", "actions": [],
          "platform": "macos", "starts_at": "2026-01-01T00:00:00Z",
          "snooze_hours": 168, "repeat_mode": "once",
          "is_active": true, "priority": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppMessage.self, from: json)
        XCTAssertNil(decoded.media_url)
        XCTAssertNil(decoded.media_type)
        XCTAssertNil(decoded.videoEmbedURL)
        XCTAssertFalse(decoded.isModal)
    }
}
