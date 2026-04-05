// v5.18.0
// VisualAnomalyDetector — Sends mosaic images to Claude Vision for visual anomaly detection.
// Routes through Supabase edge function first (works out of the box for all users),
// falls back to user's own Claude API key if set. No setup required.

import Foundation
import AppKit
import os.log

private let vlmLog = OSLog(subsystem: "com.astroblink", category: "VLM")

class VisualAnomalyDetector {

    private let edgeFunctionURL = "\(BenchmarkConfig.supabaseURL)/functions/v1/vlm-check"

    // MARK: - Errors

    enum DetectorError: LocalizedError {
        case noRoute           // Neither Supabase nor own key available
        case networkError(String)
        case parseError(String)
        case rateLimited(String)
        case imageTooLarge
        case apiError(Int, String)

        var errorDescription: String? {
            switch self {
            case .noRoute: return "VLM service unavailable and no API key configured."
            case .networkError(let msg): return "Network error: \(msg)"
            case .parseError(let msg): return "Failed to parse response: \(msg)"
            case .rateLimited(let msg): return msg
            case .imageTooLarge: return "Mosaic image too large for the service. Try with fewer frames."
            case .apiError(let code, let msg): return "API error \(code): \(msg)"
            }
        }
    }

    // Remaining VLM checks (from edge function response)
    var remainingChecks: Int?

    // MARK: - Analyze a single mosaic page

    /// Sends a mosaic page to Claude Vision and returns detected anomalies.
    /// Routes through Supabase first (free for all users), falls back to own API key.
    /// - Parameters:
    ///   - pageNumber: 1-based page number within this group (for multi-page context)
    ///   - totalPages: Total pages for this group
    func analyze(page: MosaicPage, pageNumber: Int = 1, totalPages: Int = 1) async throws -> [AnomalyResult] {
        let systemPrompt = buildSystemPrompt(page: page, pageNumber: pageNumber, totalPages: totalPages)
        let userPrompt = buildUserPrompt()

        // Re-compress JPEG to fit Claude's 5MB image limit (base64).
        // Display quality stays at 0.85, API gets 0.55 for smaller payload.
        // Anomaly detection only needs coarse spatial features — fine detail not needed.
        let apiJpeg = Self.compressForAPI(page: page, maxBase64Bytes: 4_800_000)
        let base64 = apiJpeg.base64EncodedString()
        os_log("API image: %.1f MB raw, %.1f MB base64", log: vlmLog, type: .info,
               Double(apiJpeg.count) / 1_048_576.0, Double(base64.count) / 1_048_576.0)
        let content: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ],
            [
                "type": "text",
                "text": userPrompt
            ]
        ]
        let messages: [[String: Any]] = [
            ["role": "user", "content": content]
        ]

        // Try Supabase edge function first (works for everyone, no setup needed)
        let responseText: String
        do {
            responseText = try await callEdgeFunction(system: systemPrompt, messages: messages)
            os_log("Supabase route succeeded, remaining: %d", log: vlmLog, type: .info, remainingChecks ?? -1)
        } catch let edgeError as DetectorError {
            if !edgeError.isFallbackEligible {
                throw edgeError // Rate limit — don't bypass via own key
            }
            // Fall back to user's own API key
            if let apiKey = AIsaacKeychain.loadAPIKey() {
                os_log("Edge failed (%{public}@), using own key", log: vlmLog, type: .info, edgeError.localizedDescription)
                responseText = try await callDirectAPI(system: systemPrompt, messages: messages, apiKey: apiKey)
            } else {
                os_log("Edge failed, no own key: %{public}@", log: vlmLog, type: .error, edgeError.localizedDescription)
                throw DetectorError.networkError(
                    "VLM edge: \(edgeError.localizedDescription ?? "unknown"). Set API key in AIsaac Settings as fallback.")
            }
        } catch {
            // Non-DetectorError (e.g. URLSession timeout) — try own key
            if let apiKey = AIsaacKeychain.loadAPIKey() {
                os_log("Network error, using own key: %{public}@", log: vlmLog, type: .info, error.localizedDescription)
                responseText = try await callDirectAPI(system: systemPrompt, messages: messages, apiKey: apiKey)
            } else {
                throw DetectorError.networkError(
                    "Network error. Check your connection or set a Claude API key in AIsaac > Settings.")
            }
        }

        return parseAnomalyResults(from: responseText)
    }

    // MARK: - Analyze all pages (sequential — each counts as 1 check for the session)

    /// Analyzes multiple mosaic pages. Auto-splits oversized pages into halves.
    func analyzeAll(
        pages: [MosaicPage],
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) async throws -> [GroupKey: [AnomalyResult]] {

        // Count pages per group for cross-page context
        var groupPageCounts: [GroupKey: Int] = [:]
        var groupPageIndex: [GroupKey: Int] = [:]
        for page in pages {
            groupPageCounts[page.group, default: 0] += 1
        }

        var results: [GroupKey: [AnomalyResult]] = [:]
        let total = pages.count

        for (idx, page) in pages.enumerated() {
            let filter = page.group.filter.isEmpty ? "?" : page.group.filter
            let pageNum = (groupPageIndex[page.group] ?? 0) + 1
            groupPageIndex[page.group] = pageNum
            let totalForGroup = groupPageCounts[page.group] ?? 1

            let pageLabel = totalForGroup > 1 ? " (page \(pageNum)/\(totalForGroup))" : ""
            onProgress?(idx, total, "Analyzing \(page.group.object) / \(filter)\(pageLabel)...")

            let anomalies = try await analyze(page: page, pageNumber: pageNum, totalPages: totalForGroup)
            // Merge anomalies for same group (from split pages)
            results[page.group, default: []].append(contentsOf: anomalies)

            let completed = idx + 1
            onProgress?(completed, total, "\(page.group.object) / \(filter) — \(anomalies.count) anomalies")
        }

        return results
    }

    // MARK: - Supabase Edge Function (works out of the box)

    private func callEdgeFunction(system: String, messages: [[String: Any]]) async throws -> String {
        guard let url = URL(string: edgeFunctionURL) else {
            throw DetectorError.networkError("Invalid edge function URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(BenchmarkConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(MachineInfo.machineHash, forHTTPHeaderField: "x-device-id")
        request.setValue(Self.computeRollingToken(), forHTTPHeaderField: "x-aisaac-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "system": system,
            "messages": messages
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let bodyMB = Double(bodyData.count) / 1_048_576.0
        os_log("Request body size: %.1f MB", log: vlmLog, type: .info, bodyMB)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            os_log("URLSession error: %{public}@", log: vlmLog, type: .error, error.localizedDescription)
            throw DetectorError.networkError("Request failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw DetectorError.networkError("No HTTP response")
        }

        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
        os_log("Edge response: %d — %{public}@", log: vlmLog, type: .info, http.statusCode, bodyPreview)

        // Parse remaining from header
        if let remStr = http.value(forHTTPHeaderField: "X-Remaining"), let rem = Int(remStr) {
            remainingChecks = rem
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            // Supabase gateway or token rejection — service-side issue, fall back silently
            throw DetectorError.apiError(http.statusCode, "VLM service auth issue — trying fallback...")
        }

        if http.statusCode == 429 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = json?["error"] as? String ?? "Daily VLM check limit reached. Try again tomorrow."
            throw DetectorError.rateLimited(msg)
        }

        if http.statusCode == 413 {
            throw DetectorError.imageTooLarge
        }

        guard (200...299).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorMsg = json?["error"] as? String ?? "Service temporarily unavailable"
            throw DetectorError.apiError(http.statusCode, errorMsg)
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw DetectorError.parseError("Invalid edge function response")
        }

        return text
    }

    // MARK: - Direct Claude API (user's own key fallback)

    private func callDirectAPI(system: String, messages: [[String: Any]], apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw DetectorError.networkError("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "claude-opus-4-20250514",
            "max_tokens": 4096,
            "system": system,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DetectorError.networkError("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DetectorError.apiError(http.statusCode, errorText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw DetectorError.parseError("Invalid response structure")
        }

        return content.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }.joined()
    }

    // MARK: - Image compression for API (fit under Claude's 5MB limit)

    /// Re-encodes the mosaic JPEG at 0.90 quality for the API.
    /// With maxTilesPerPage=25 (5x5 grid = 3200x2400px), 0.90 quality ≈ 2.5-3MB → fits under 5MB base64.
    private static func compressForAPI(page: MosaicPage, maxBase64Bytes: Int) -> Data {
        guard let nsImage = page.nsImage else { return page.jpegData }

        // If original already fits, use it (0.95 quality)
        let originalBase64Size = page.jpegData.count * 4 / 3
        if originalBase64Size <= maxBase64Bytes { return page.jpegData }

        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return page.jpegData }

        // Re-encode at 0.90 — high enough to preserve ice crystal halos and subtle anomalies
        if let jpeg = rep.representation(using: .jpeg,
                                         properties: [.compressionFactor: NSNumber(value: 0.90)]) {
            let b64Size = jpeg.count * 4 / 3
            if b64Size <= maxBase64Bytes { return jpeg }
        }

        // Fallback: 0.85 — still good quality
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: NSNumber(value: 0.85)]) ?? page.jpegData
    }

    // MARK: - Rolling token (same as AIsaacService)

    private static func computeRollingToken() -> String {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let dateNum = (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
        let hour = comps.hour ?? 0
        return String(dateNum - hour)
    }

    // MARK: - System prompt

    private func buildSystemPrompt(page: MosaicPage, pageNumber: Int = 1, totalPages: Int = 1) -> String {
        let pageInfo = totalPages > 1
            ? "This is PAGE \(pageNumber) of \(totalPages) for this filter group. " +
              "Other pages contain additional frames from the same session — analyze only the tiles visible here."
            : ""

        return """
        You are analyzing an astrophotography session mosaic for visual anomalies that \
        quantitative metrics may have missed. Each tile shows the center 80% of an \
        astronomical exposure, individually auto-stretched for visibility. Tiles are \
        numbered in the top-left corner.
        \(pageInfo)

        GRID LAYOUT: \(page.tiles.count) tiles in a \(page.gridCols)x\(page.gridRows) grid, \
        ordered chronologically left-to-right, top-to-bottom. \
        The grid has \(page.gridCols * page.gridRows) positions — \
        \(page.gridCols * page.gridRows - page.tiles.count) position(s) at the bottom-right are EMPTY \
        (dark/black padding, NOT corrupted frames — ignore them completely).

        TILE NUMBERING: Each tile is labeled with its session frame number (e.g. #28, #87), \
        NOT sequential 1-N. Use ONLY the frame numbers visible in the top-left of each tile. \
        The tile labels in this mosaic are: \(page.tiles.map { "#\($0.frameIndex)" }.joined(separator: ", "))

        SESSION CONTEXT:
        \(page.sessionContext)

        PER-TILE ANNOTATIONS:
        - Top-left: session frame number (#N) — use this number in your response
        - Top-right: capture time + moon distance (degrees)
        - Bottom-left: twilight phase (N=Night, A=Astro, Na=Nautical, C=Civil, D=Day) + pier side (E/W)
        - Bottom-edge: twilight color bar (blue=astro, orange=civil, red=daylight; none=night)

        FRAME METRICS (for numeric cross-reference):
        \(page.metricsTable)

        ANOMALY TYPES to detect (ordered by importance):
        1. ICE_CRYSTAL — THE MOST IMPORTANT anomaly. TWO manifestations:
           a) DARK SPOT/SHADOW: A dark circular area or shadow in the CENTER of the frame \
              that is NOT present in clean frames. This is ice/frost on the sensor window \
              casting a shadow. Compare tiles — if some have a dark blob in the center \
              that others don't, those are ice-affected.
           b) STAR HALOS: Bright stars with unusually large, diffuse halos/glows compared \
              to the same stars in neighboring tiles. Ice creates concentric rings around \
              bright stars.
           Look at BOTH center darkness AND star bloating. Either one = ICE_CRYSTAL.
        2. DEW — Progressive softness/glow across consecutive frames. Stars become bloated \
           and fuzzy, contrast drops. Usually gradual (worsens over time).
        3. CLOUD — Uneven illumination, gradient across part of the frame, or \
           noticeably fewer stars compared to neighbors.
        4. SATELLITE — Linear bright streak crossing the frame. Very obvious — a bright \
           line not present in neighbors.
        5. OBSTRUCTION — Dark shadow, vignetting, or blocked area that appears suddenly \
           and is NOT present in neighboring tiles. Could be dew shield, cable, etc.
        6. LIGHT_LEAK — Bright patch or gradient from one edge/corner.
        7. AMP_GLOW — Warm gradient in corners (thermal noise pattern).
        8. FOCUS_SHIFT — Stars significantly softer than neighbors (sudden, not gradual).
        9. UNKNOWN — Any other visual anomaly not in above categories.

        CRITICAL GUIDELINES:
        - ONLY reference frame numbers that appear in the tile labels listed above. \
          Do NOT invent frame numbers.
        - Empty/black grid positions at the bottom-right are padding — IGNORE them. \
          Do NOT flag them as anomalies.
        - Compare tiles RELATIVE to their neighbors. Most tiles should look similar.
        - Only flag tiles that are CLEARLY different from the majority.
        - Each tile is individually auto-stretched — brightness differences between tiles \
          are expected. Focus on SPATIAL anomalies within each tile (star halos, streaks, \
          gradients, softness) rather than overall brightness.
        - For ICE detection: zoom in mentally on the BRIGHTEST STAR in each tile. \
          If that star has a much larger glow/halo than the same star in other tiles, \
          flag it as ICE_CRYSTAL.
        - Progressive softening across many consecutive frames = likely DEW (flag first \
          frame where it becomes visible).
        - Sudden change between two consecutive frames = ice/obstruction event.
        """
    }

    // MARK: - User prompt

    private func buildUserPrompt() -> String {
        """
        Analyze this mosaic for visual anomalies. Compare each tile to its neighbors \
        and the majority. Return a JSON array of flagged frames. If no anomalies found, \
        return an empty array [].

        Format:
        [{"frame": <number>, "type": "<ANOMALY_TYPE>", "confidence": <0.0-1.0>, \
        "description": "<brief description>", "temporalNote": "<optional: progressive/sudden pattern>"}]

        Return ONLY the JSON array, no other text.
        """
    }

    // MARK: - Parse anomaly results

    private func parseAnomalyResults(from text: String) -> [AnomalyResult] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return [] }

        do {
            let results = try JSONDecoder().decode([AnomalyResult].self, from: data)
            return results.filter { $0.confidence >= 0.5 }
        } catch {
            os_log("JSON parse error: %{public}@ — raw: %{public}@", log: vlmLog, type: .error,
                   String(describing: error), String(cleaned.prefix(300)))
            return []
        }
    }
}

// MARK: - Error fallback eligibility

extension VisualAnomalyDetector.DetectorError {
    /// Rate limit errors should NOT fall back to own key (respect the limit).
    /// Network/server errors CAN fall back.
    var isFallbackEligible: Bool {
        switch self {
        case .rateLimited: return false
        case .imageTooLarge: return true  // Own key has no size limit
        case .networkError, .apiError, .parseError, .noRoute: return true
        }
    }
}
