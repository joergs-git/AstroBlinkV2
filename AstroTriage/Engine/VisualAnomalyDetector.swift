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
        request.timeoutInterval = 180 // Extended thinking needs more time

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

    private func buildSystemPrompt(page: MosaicPage, pageNumber: Int = 1, totalPages: Int = 1) -> String {
        let pageInfo = totalPages > 1
            ? "This is PAGE \(pageNumber) of \(totalPages) for this filter group. " +
              "Other pages contain additional frames from the same session — analyze only the tiles visible here."
            : ""

        return """
        You are an expert astrophotography quality inspector analyzing a session mosaic \
        for visual anomalies that quantitative metrics may have missed. Each tile shows \
        the center 80% of an astronomical exposure, individually auto-stretched for \
        visibility. Tiles are numbered in the top-left corner.
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

        === THIS IS A CHRONOLOGICAL SEQUENCE ===
        The tiles are ordered chronologically from top-left to bottom-right. \
        This is a TIME SERIES of the same object taken over hours. Your primary task: \
        detect TRANSIENT defects that appear, persist, or worsen over the course of the \
        sequence. Walk through the tiles in chronological order and note any progressive \
        or sudden changes.

        === WHAT IS NORMAL (ignore these) ===
        - The astronomical object (nebula filaments, galaxy arms, star cluster patterns) \
          appears in ALL tiles at the same position — it is the TARGET, not an anomaly.
        - Brightness differences between tiles are expected (individual auto-stretch).
        - Point stars throughout the frame are normal.
        - Satellite trails (bright linear streaks) are handled by a separate metric \
          detector — ignore them completely.

        === WHAT TO LOOK FOR (transient optical defects) ===
        Focus on artifacts in the OPTICAL PATH that appear at some point in the sequence \
        and were NOT present in earlier frames. These are physical problems at the \
        camera-optics interface:

        1. ICE_CRYSTAL (highest priority):
           A diffuse dark shadow or circular darkening in the IMAGE CENTER that is \
           NOT part of the astronomical object. Ice/frost on the sensor window casts \
           a shadow centered on the optical axis. Key diagnostics:
           - Compare image centers chronologically: do some frames have a clear center \
             while others show a dark circular blob?
           - The shadow may appear, persist for a stretch, then DISAPPEAR (dew heater \
             cycle, temperature change). Evaluate EACH tile on its own visual evidence.
           - Only flag tiles where you can actually SEE the centered dark shadow or \
             bloated star halos. Do NOT flag tiles that look clean just because \
             neighboring tiles have ice.
           USE THE DEVIATION MAP (Image 2): A bright centered blob in the deviation map \
           confirms centered optical defects. Tiles that are mostly DARK in the deviation \
           map = clean, do not flag them.

        2. DEW — Progressive softening: stars become gradually more bloated and fuzzy \
           across consecutive frames. Contrast drops. Worsens monotonically.

        3. CLOUD — Sudden reduction in visible stars, washed-out background. May come \
           and go (unlike ice which persists).

        4. OBSTRUCTION — Dark shadow appearing suddenly from one edge (dew shield, cable).

        5. LIGHT_LEAK — Bright patch from edge/corner not present in other tiles.

        6. FOCUS_SHIFT — Stars suddenly much softer (not gradual like dew).

        === DEVIATION MAP GUIDE ===
        If Image 2 (deviation map) is provided, use it as your primary detection tool:
        - BRIGHT areas = that tile differs significantly from the group median
        - DARK areas = tile matches the median (normal)
        - Bright CENTERED blob = centered optical defect (ice/frost) — flag as ICE_CRYSTAL
        - Bright STREAK = transient artifact
        - Uniform brightness across a tile = overall brightness anomaly (cloud/transparency)
        - If MOST tiles show the same bright pattern, it means the MEDIAN itself is \
          contaminated — the FEW dark (clean) tiles are the good ones.

        === RULES ===
        - Only use frame numbers from: \(page.tiles.map { "#\($0.frameIndex)" }.joined(separator: ", "))
        - Empty grid positions (black padding) are not frames — ignore them.
        - Do NOT report SATELLITE, AMP_GLOW, or UNKNOWN.
        - Evaluate EACH tile based on what you actually see — not assumptions about \
          neighboring tiles. Ice can come and go (dew heater cycles).
        - Use the deviation map as primary evidence: bright center = flag, dark/uniform = clean.
        - Only flag tiles where the defect is VISUALLY PRESENT in that specific tile.
        """
    }

    // MARK: - User prompt

    private func buildUserPrompt() -> String {
        """
        Analyze this chronological sequence for transient optical defects. \
        Use both the original mosaic (Image 1) and the deviation map (Image 2) if provided. \
        Flag only tiles where the defect is VISUALLY PRESENT — do not flag clean tiles \
        just because they are near affected ones. Ice can appear AND disappear.

        Return a JSON array of flagged frames. If no anomalies found, return [].

        Format:
        [{"frame": <number>, "type": "<ANOMALY_TYPE>", "confidence": <0.0-1.0>, \
        "description": "<brief description>", "temporalNote": "<optional: e.g. continues from #N, progressive, sudden>"}]

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
