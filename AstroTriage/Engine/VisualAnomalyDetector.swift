// v5.19.0
// VisualAnomalyDetector — Sends mosaic images to Claude Vision for visual anomaly detection.
// Routes through Supabase edge function first (works out of the box for all users),
// falls back to user's own Claude API key if set. No setup required.

import Foundation
import AppKit
import os.log

private let vlmLog = OSLog(subsystem: "com.astroblink", category: "VLM")

class VisualAnomalyDetector {

    private static let edgeFunctionName = "vlm-check"

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

        // Re-compress images to fit Claude's 5MB per-image base64 limit.
        let maxPerImage = 4_800_000
        let apiJpeg = Self.compressForAPI(page: page, maxBase64Bytes: maxPerImage)
        let base64 = apiJpeg.base64EncodedString()
        os_log("API original: %.1f MB raw, %.1f MB base64", log: vlmLog, type: .info,
               Double(apiJpeg.count) / 1_048_576.0, Double(base64.count) / 1_048_576.0)

        var content: [[String: Any]] = [
            ["type": "text", "text": "IMAGE 1 — ORIGINAL MOSAIC (chronological sequence, top-left to bottom-right):"],
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ]
        ]

        // Add deviation map if available — this is the key visual aid
        if let devData = page.deviationJpegData {
            let devCompressed = Self.compressDeviationForAPI(devData, maxBase64Bytes: maxPerImage)
            let devBase64 = devCompressed.base64EncodedString()
            os_log("API deviation: %.1f MB raw, %.1f MB base64", log: vlmLog, type: .info,
                   Double(devCompressed.count) / 1_048_576.0, Double(devBase64.count) / 1_048_576.0)
            content.append(["type": "text", "text":
                "IMAGE 2 — DEVIATION MAP (same grid layout). Each tile shows how much it " +
                "differs from the group median. BRIGHT areas = significant deviation from normal. " +
                "Dark/black = tile matches the median. A bright centered blob = centered optical " +
                "defect (ice/frost shadow). Bright streaks = transient artifacts. Any bright patch " +
                "that appears in some tiles but not others = anomaly to investigate."])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": devBase64
                ]
            ])
        }

        content.append(["type": "text", "text": userPrompt])
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
        guard var request = SupabaseClient.functionRequest(Self.edgeFunctionName) else {
            throw DetectorError.networkError("Invalid edge function URL")
        }
        request.setValue(MachineInfo.machineHash, forHTTPHeaderField: "x-device-id")
        request.setValue(Self.computeRollingToken(), forHTTPHeaderField: "x-aisaac-token")

        let body: [String: Any] = [
            "system": system,
            "messages": messages
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let bodyMB = Double(bodyData.count) / 1_048_576.0
        os_log("Request body size: %.1f MB", log: vlmLog, type: .info, bodyMB)

        // 180s timeout preserved — extended thinking needs the runway.
        // No retry: caller treats 429 (rate limit) and 413 (image too large) as
        // first-class outcomes; a blind retry would burn the daily quota.
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await SupabaseClient.send(request, timeout: 180)
        } catch {
            os_log("URLSession error: %{public}@", log: vlmLog, type: .error, error.localizedDescription)
            throw DetectorError.networkError("Request failed: \(error.localizedDescription)")
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
        request.timeoutInterval = 180 // Extended thinking needs more time

        let body: [String: Any] = [
            "model": "claude-opus-4-20250514",
            "max_tokens": 16000,
            "thinking": ["type": "enabled", "budget_tokens": 10000],
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

        // With extended thinking, response contains both "thinking" and "text" blocks.
        // Extract only "text" blocks (the JSON result), skip thinking blocks.
        let textParts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        guard !textParts.isEmpty else {
            throw DetectorError.parseError("No text content in response")
        }
        return textParts.joined()
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

    /// Compress deviation map for API. Heat map colors compress worse than grayscale.
    private static func compressDeviationForAPI(_ data: Data, maxBase64Bytes: Int) -> Data {
        let base64Size = data.count * 4 / 3
        if base64Size <= maxBase64Bytes { return data }

        guard let nsImage = NSImage(data: data),
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return data }

        // Try progressively lower quality until it fits
        for q: Float in [0.80, 0.65, 0.50, 0.35] {
            if let jpeg = rep.representation(using: .jpeg,
                                              properties: [.compressionFactor: NSNumber(value: q)]) {
                if jpeg.count * 4 / 3 <= maxBase64Bytes { return jpeg }
            }
        }
        // Last resort: scale down to 50%
        let halfW = Int(nsImage.size.width / 2)
        let halfH = Int(nsImage.size.height / 2)
        if let halfRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: halfW, pixelsHigh: halfH,
                                           bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB,
                                           bytesPerRow: halfW * 4, bitsPerPixel: 32) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: halfRep)
            nsImage.draw(in: NSRect(x: 0, y: 0, width: halfW, height: halfH))
            NSGraphicsContext.restoreGraphicsState()
            if let jpeg = halfRep.representation(using: .jpeg,
                                                  properties: [.compressionFactor: NSNumber(value: 0.70)]) {
                return jpeg
            }
        }
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: NSNumber(value: 0.30)]) ?? data
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

    // v5.18.0 prompt (replaced in v5.19.0 — kept for reference):
    // The original prompt was highly prescriptive, enumerating 6 specific defect types
    // (ICE_CRYSTAL, DEW, CLOUD, OBSTRUCTION, LIGHT_LEAK, FOCUS_SHIFT) with detailed
    // descriptions of how each manifests visually. This led to over-detection (especially
    // ice crystals) because the model actively hunted for each category even when absent.
    //
    // Key sections that were removed:
    // - "=== WHAT TO LOOK FOR (transient optical defects) ===" with 6 numbered categories
    //   1. ICE_CRYSTAL — detailed center-shadow, dew heater cycle, deviation map guidance
    //   2. DEW — progressive star bloating, contrast drop, monotonic worsening
    //   3. CLOUD — sudden star reduction, washed-out background
    //   4. OBSTRUCTION — dark shadow from edge (dew shield, cable)
    //   5. LIGHT_LEAK — bright patch from edge/corner
    //   6. FOCUS_SHIFT — sudden star softness (not gradual like dew)
    // - Detailed deviation map interpretation tied to specific defect types
    //   (e.g. "bright centered blob = ICE_CRYSTAL")
    // - Rule "Do NOT report SATELLITE, AMP_GLOW, or UNKNOWN"
    //
    // v5.19.0 approach: "find what looks different" — too vague, model focused on brightness
    // differences (twilight) instead of instrumental artifacts.
    //
    // v5.19.1 approach: INVARIANCE-BASED detection.
    // Key insight: instrumental artifacts (ice, dust, moisture) persist at the SAME PIXEL
    // POSITION across multiple frames. Transient events (satellites, meteors) do not.
    // The prompt forces the model to first check positional invariance before flagging.
    // Focus on large-scale morphology (blobs, gradients), ignore point/linear features.

    private func buildSystemPrompt(page: MosaicPage, pageNumber: Int = 1, totalPages: Int = 1) -> String {
        let pageInfo = totalPages > 1
            ? "This is PAGE \(pageNumber) of \(totalPages) for this filter group. " +
              "Other pages contain additional frames from the same session — analyze only the tiles visible here."
            : ""

        return """
        Analyze a series of astronomical RAW sub-exposures (mosaic). \
        Each tile shows the center 80% of one exposure, individually auto-stretched. \
        Goal: identify ONLY systematic instrumental artifacts.
        \(pageInfo)

        GRID LAYOUT: \(page.tiles.count) tiles in a \(page.gridCols)x\(page.gridRows) grid, \
        chronological left-to-right, top-to-bottom. \
        \(page.gridCols * page.gridRows - page.tiles.count) empty position(s) at bottom-right (padding — ignore).

        TILE NUMBERS: \(page.tiles.map { "#\($0.frameIndex)" }.joined(separator: ", "))

        SESSION CONTEXT:
        \(page.sessionContext)

        \(page.referenceTileFrameIndex.map { """
        REFERENCE TILE: #\($0) — cleanest frame (highest star count, closest to group baseline).
        """ } ?? "")

        === MANDATORY PROCEDURE ===

        STEP 1 — INVARIANCE CHECK
        Examine which structures appear at the SAME PIXEL POSITION across many or all frames. \
        Only position-invariant structures are relevant. \
        Completely ignore one-time or transient events (satellite trails, meteors, planes, cosmic rays).

        STEP 2 — CLASSIFY BY BEHAVIOR
        For each detected structure, classify strictly by:
        - Position-stable vs position-variable
        - Shape-stable vs shape-changing
        - Intensity-stable vs intensity-variable

        STEP 3 — MORPHOLOGICAL ASSESSMENT
        Evaluate ONLY large-scale, soft, or systematic patterns:
        - Round/diffuse shadows (donuts, blobs, dark spots)
        - Gradients, vignetting, panel transitions
        - Fixed shadow structures
        Ignore point-like or linear single-frame phenomena.

        STEP 4 — CAUSAL ATTRIBUTION
        Derive causes ONLY from invariance + morphology:
        - Optical path (dust, filter, sensor window, ice/frost)
        - Flat-field / calibration issues
        - Moisture / condensation film
        - Background / gradient errors
        Mark uncertain attributions as [Inference].

        STEP 5 — PRIORITIZATION
        List only dominant, recurring artifacts. \
        No per-frame detail analysis. \
        No astrophysical interpretation of the target object.

        === DEVIATION MAP (Image 2) ===
        If provided, bright areas = tile differs from group median. \
        Use to confirm invariant structures: if a blob appears bright in the deviation map \
        of MULTIPLE tiles at the same position, it is an instrumental artifact.

        === FORBIDDEN ===
        - Discussing one-time trails or transient events
        - Focusing on individual pixels, stars, or nebula details
        - Speculation without reference to positional invariance
        - Flagging brightness differences between tiles (auto-stretch artifact, not real)
        """
    }

    // MARK: - User prompt

    // v5.18.0: "Analyze for transient optical defects" — model hunted specific categories.
    // v5.19.0: "Flag tiles that look different from majority" — model flagged twilight.
    // v5.19.1: Invariance-based — only flag systematic instrumental artifacts.

    private func buildUserPrompt() -> String {
        """
        Apply the mandatory procedure above. Identify systematic instrumental artifacts \
        that persist at the same pixel position across multiple frames. \
        Use both the original mosaic (Image 1) and the deviation map (Image 2) if provided.

        For each affected frame, return a JSON entry. If no artifacts found, return [].

        Format:
        [{"frame": <number>, "type": "<short label: ICE, DUST, MOISTURE, GRADIENT, SHADOW, or custom>", \
        "confidence": <0.0-1.0>, \
        "description": "<what the artifact looks like and where in the tile>", \
        "temporalNote": "<optional: e.g. present from #N to #M, persistent, intermittent>"}]

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
