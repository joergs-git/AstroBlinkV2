// AIsaac — AI service layer
// Stage 1: Supabase Edge Function proxy to Claude API, mock fallback on error
import Foundation

@MainActor
class AIsaacService: ObservableObject {
    static let shared = AIsaacService()

    @Published var remainingQueries: Int? = nil

    private let edgeFunctionURL = "\(BenchmarkConfig.supabaseURL)/functions/v1/ask-aisaac"

    // API response model
    private struct AIsaacResponse: Codable {
        let text: String
        let remaining: Int?
        let usage: Usage?
        let error: String?
        struct Usage: Codable { let input: Int; let output: Int }
    }

    // Streaming callback — called on main thread with each text chunk
    var onStreamChunk: ((String) -> Void)?

    // Current thumbnail for vision (set by AIsaacWindowController)
    var currentThumbnailBase64: String?

    func ask(
        userMessage: String,
        preset: AIsaacPreset?,
        context: AIsaacSessionContext?,
        history: [AIsaacMessage]
    ) async -> String {
        // Build system prompt
        let aisaacModel = AIsaacWindowController.shared.model
        let imageHeaders = aisaacModel.currentImageHeaders
        let weather = aisaacModel.weatherForecast
        let currentIdx = aisaacModel.currentFrameSessionIndex
        let currentName = aisaacModel.currentFrameFilename
        let systemPrompt = AIsaacContextBuilder.buildSystemPrompt(
            context: context,
            preset: preset,
            currentImageHeaders: imageHeaders,
            weatherForecast: weather,
            currentFrameIndex: currentIdx,
            currentFrameFilename: currentName
        )

        // Build messages array (last 10 for context window management)
        var apiMessages: [[String: Any]] = []
        for msg in history.suffix(10) {
            apiMessages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.text
            ])
        }

        // Build the final user message — include thumbnail if available
        if let thumb = currentThumbnailBase64 {
            // Multimodal message with image + text
            let content: [[String: Any]] = [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": thumb
                    ]
                ],
                [
                    "type": "text",
                    "text": userMessage
                ]
            ]
            apiMessages.append(["role": "user", "content": content])
        } else {
            apiMessages.append(["role": "user", "content": userMessage])
        }

        // Grab current thumbnail and mode
        currentThumbnailBase64 = AIsaacWindowController.shared.model.currentThumbnailBase64
        let mode = AIsaacWindowController.shared.model.mode

        // Try real API call — route based on mode
        do {
            if mode == .pro, let apiKey = AIsaacKeychain.loadAPIKey() {
                return try await callClaudeDirectly(system: systemPrompt, messages: apiMessages, apiKey: apiKey)
            }
            return try await callEdgeFunction(system: systemPrompt, messages: apiMessages)
        } catch {
            // Fallback to mock on any error
            print("[AIsaac] API error: \(error.localizedDescription) — using mock response")
            try? await Task.sleep(nanoseconds: 500_000_000)
            return mockResponse(for: userMessage, preset: preset, context: context)
        }
    }

    // MARK: - Edge Function Call

    private func callEdgeFunction(system: String, messages: [[String: Any]]) async throws -> String {
        guard let url = URL(string: edgeFunctionURL) else {
            throw AIsaacError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(BenchmarkConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(MachineInfo.machineHash, forHTTPHeaderField: "x-device-id")
        request.setValue(Self.computeRollingToken(), forHTTPHeaderField: "x-aisaac-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-stream")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "system": system,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AIsaacError.networkError
        }

        if http.statusCode == 429 {
            throw AIsaacError.rateLimited("Daily limit reached")
        }

        guard (200...299).contains(http.statusCode) else {
            // Collect error body
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AIsaacError.serverError(http.statusCode, errorText)
        }

        // Check remaining from header
        if let remStr = http.value(forHTTPHeaderField: "X-Remaining"), let rem = Int(remStr) {
            remainingQueries = rem
        }

        // Check if response is SSE stream or JSON
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("text/event-stream") {
            return try await parseSSEStream(bytes)
        } else {
            // Non-streaming fallback (collect all data)
            var allData = Data()
            for try await byte in bytes { allData.append(byte) }
            let decoded = try JSONDecoder().decode(AIsaacResponse.self, from: allData)
            remainingQueries = decoded.remaining
            return decoded.text
        }
    }

    // Parse Claude SSE stream and call onStreamChunk for each text delta
    private func parseSSEStream(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var fullText = ""
        var truncated = false

        for try await line in bytes.lines {
            // SSE format: "data: {...}" or "event: ..."
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]" else { break }

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let eventType = json["type"] as? String ?? ""

            // content_block_delta contains text chunks
            if eventType == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                fullText += text
                onStreamChunk?(text)
            }

            // message_delta carries the final stop_reason — surface max_tokens truncation
            // to the user instead of ending silently mid-word
            if eventType == "message_delta",
               let delta = json["delta"] as? [String: Any],
               (delta["stop_reason"] as? String) == "max_tokens" {
                truncated = true
            }
        }

        if truncated {
            let marker = "\n\n(… response truncated at token limit — ask me to continue)"
            fullText += marker
            onStreamChunk?(marker)
        }

        return fullText
    }

    // MARK: - Direct Claude API (Pro/Opus mode — user's own key)

    private func callClaudeDirectly(system: String, messages: [[String: Any]], apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIsaacError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90  // Opus can be slower

        let body: [String: Any] = [
            "model": "claude-opus-4-20250514",
            // 8192 gives headroom for large JSON tool outputs (e.g. mark_frames on 1000+ files)
            "max_tokens": 8192,
            "system": system,
            "messages": messages,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AIsaacError.networkError
        }

        if http.statusCode == 401 {
            throw AIsaacError.serverError(401, "Invalid API key. Check your key in AIsaac settings.")
        }

        guard (200...299).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AIsaacError.serverError(http.statusCode, errorText)
        }

        remainingQueries = nil  // no limit on user's own key
        return try await parseSSEStream(bytes)
    }

    // MARK: - Rolling Token

    // Compute hourly rolling token: YYYYMMDD - currentUTCHour
    // Both app and Edge Function compute this independently — no hardcoded secret
    private static func computeRollingToken() -> String {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let dateNum = (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
        let hour = comps.hour ?? 0
        return String(dateNum - hour)
    }

    // MARK: - Errors

    enum AIsaacError: LocalizedError {
        case invalidURL
        case networkError
        case rateLimited(String)
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid service URL"
            case .networkError: return "Network error — check your connection"
            case .rateLimited(let msg): return msg
            case .serverError(let code, let msg): return "Server error \(code): \(msg)"
            }
        }
    }

    // MARK: - Mock Responses (Stage 0)

    private func mockResponse(
        for message: String,
        preset: AIsaacPreset?,
        context: AIsaacSessionContext?
    ) -> String {
        // Handle no-session and general presets first
        if let preset = preset {
            switch preset {
            case .planTonight:
                return mockWhatToShoot()
            case .gettingStarted:
                return mockGettingStarted()
            case .workflowTips:
                return mockWorkflowTips()
            case .whatsNew:
                return mockWhatsNew()
            default:
                break
            }
        }

        guard let ctx = context, ctx.totalFrames > 0 else {
            return "No session loaded yet. Open a folder with your sub-exposures (Cmd+O) and I'll be able to analyze your frames, suggest culling decisions, and help plan your next imaging night."
        }

        guard let preset = preset else {
            // Free-form question — generic helpful response
            return "That's a great question! Once I'm connected to my brain (coming in the next update), I'll be able to give you a detailed answer based on your \(ctx.totalFrames) frames of \(ctx.objects.joined(separator: ", ")). For now, try one of the preset questions below."
        }

        switch preset {
        case .qualitySummary:
            return mockQualitySummary(ctx)
        case .objectTrivia:
            return mockObjectTrivia(ctx)
        case .filterAdvice:
            return mockFilterAdvice(ctx)
        case .nearbyObjects:
            return mockNearbyObjects(ctx)
        case .smartMark:
            return mockSmartMark(ctx)
        case .gettingStarted, .workflowTips, .whatsNew, .planTonight:
            return "" // already handled above
        }
    }

    private func mockQualitySummary(_ ctx: AIsaacSessionContext) -> String {
        let qd = ctx.qualityDistribution
        let total = qd.excellent + qd.good + qd.borderline + qd.trash
        let keepPct = total > 0 ? Int(Double(qd.excellent + qd.good) / Double(total) * 100) : 0
        let integMin = Int(ctx.totalIntegrationSeconds / 60)

        return """
        **Session Quality Summary**

        You have \(ctx.totalFrames) frames across \(ctx.filters.joined(separator: ", ")) \
        with \(integMin) minutes total integration.

        \u{2022} Excellent: \(qd.excellent) frames
        \u{2022} Good: \(qd.good) frames
        \u{2022} Borderline: \(qd.borderline) frames
        \u{2022} Trash: \(qd.trash) frames

        **\(keepPct)% of your frames are keeper quality.** \
        \(qd.trash > 0 ? "You have \(qd.trash) frames to cull." : "All frames look usable!") \
        SNR retention is at \(String(format: "%.0f%%", ctx.snrRetention)).

        *[This is a preview response. Full AI analysis coming soon.]*
        """
    }

    private func mockObjectTrivia(_ ctx: AIsaacSessionContext) -> String {
        let obj = ctx.objects.first ?? "your target"
        return """
        **About \(obj)**

        I'll have detailed information about this object once I'm fully connected \
        — including distance, type, best imaging season, scientific facts, and specific \
        tips for your \(ctx.telescope ?? "telescope") setup.

        *[Full AI-powered object encyclopedia coming in the next update.]*
        """
    }

    private func mockFilterAdvice(_ ctx: AIsaacSessionContext) -> String {
        let filterList = ctx.perFilterStats.map { "\($0.filter): \($0.count) frames" }.joined(separator: ", ")
        return """
        **Filter Advice for Next Night**

        Current data: \(filterList).

        I'll analyze your filter balance and quality per channel to recommend \
        which filters need more integration time. This includes considering your \
        target type, current quality distribution, and optimal signal ratios.

        *[AI-powered filter recommendations coming in the next update.]*
        """
    }

    private func mockNearbyObjects(_ ctx: AIsaacSessionContext) -> String {
        let obj = ctx.objects.first ?? "your target"
        let fl = ctx.focalLength.map { String(format: "%.0fmm", $0) } ?? "your"
        return """
        **Objects Near \(obj)**

        With your \(fl) focal length setup, I can suggest nearby deep-sky objects \
        that fit in your field of view and are well-positioned tonight.

        I'll consider: object brightness, angular size vs your FOV, current altitude, \
        and difficulty for your imaging setup.

        *[AI-powered target suggestions coming in the next update.]*
        """
    }

    private func mockSmartMark(_ ctx: AIsaacSessionContext) -> String {
        let trash = ctx.qualityDistribution.trash
        return """
        **Smart Mark Analysis**

        I see \(trash) frames marked as trash by SmartCull. Once connected, I'll \
        review all borderline frames and suggest additional marks based on:

        \u{2022} Temporal quality trends (degrading seeing, clouds rolling in)
        \u{2022} Per-filter balance (which filters can afford to lose frames)
        \u{2022} SNR contribution vs integration loss tradeoff

        You'll always get a confirmation dialog before any files are marked.

        *[AI-powered smart marking coming in the next update.]*
        """
    }

    // MARK: - No-Session Presets

    private func mockWhatToShoot() -> String {
        let profile = AIsaacUserProfile.load()
        let setupCount = profile.equipmentSetups.count
        let objectCount = profile.imagedObjects.count
        return """
        **What to Shoot Tonight?**

        I know \(setupCount) equipment setup\(setupCount == 1 ? "" : "s") and \(objectCount) \
        previously imaged object\(objectCount == 1 ? "" : "s") from your history.

        Once I'm connected to my full brain, I'll analyze tonight's sky from your location, \
        consider moon phase, your filter set, and suggest the best targets for your equipment. \
        I'll even tell you which objects need more integration from previous sessions.

        *[AI-powered target planning coming in the next update.]*
        """
    }

    private func mockGettingStarted() -> String {
        return """
        **Getting Started with AstroBlinkV2**

        1. **Open your session** — Cmd+O to select the folder with your FITS or XISF subs
        2. **Wait for caching** — the app decodes and analyzes every frame (progress in status bar)
        3. **Review quality scores** — SmartCull automatically rates each frame (green/orange/red icons)
        4. **Blink through frames** — arrow keys to scan, Space to mark bad ones
        5. **Check borderlines** — press C on any frame to compare side-by-side with the best
        6. **Pre-delete** — Cmd+Backspace moves marked files to a staging folder (never permanent)
        7. **Stack** — select your best subs and hit LightspeedStacker for a quick preview

        **Keyboard essentials:** Space (mark), H (hide marked), K (skip marked), S (lock stretch), I (inspector), C (compare)

        *[Full AI guidance coming in the next update.]*
        """
    }

    private func mockWorkflowTips() -> String {
        return """
        **Efficient Triage Workflow**

        \u{2022} **Sort by quality first** — click the Q column header. Worst frames bubble to top.
        \u{2022} **Use filter search** — type `filter:Ha` to focus on one filter at a time.
        \u{2022} **Trust the green icons** — Excellent and Good frames are keepers. Focus your time on orange/red.
        \u{2022} **Press C on borderlines** — the Compare window shows the frame side-by-side with the best. Look at star shapes.
        \u{2022} **Check SNR retention** — the status bar shows how much signal you're losing. Stay above 90%.
        \u{2022} **Try the Autopilot** — click the quality status pill for one-click Conservative/Balanced/Aggressive auto-marking.
        \u{2022} **Round stars = keep** — even soft frames add signal in stacking. Only delete elongated stars.

        *[Full AI guidance coming in the next update.]*
        """
    }

    private func mockWhatsNew() -> String {
        return """
        **What's New in AstroBlinkV2 v4.6.0**

        \u{2022} **SmartCull Quality Engine** — 4-stage pipeline handles 99% of quality decisions automatically. \
        Validated on 1,457 frames across 6 setups.
        \u{2022} **Quality Reasoning ("Why?")** — hover any quality icon for a human-readable explanation.
        \u{2022} **Stage 3 Rescue Rules** — frames with good FWHM + acceptable noise rescued from trash. \
        Star count dips recognized as transient events.
        \u{2022} **FWHM Cross-Check** — trailing detector verifies degraded FWHM, eliminating false positives from optical coma.
        \u{2022} **Self-Calibration** — learns your equipment baseline after 30+ frames. Calibrated frames locked as KEEP.
        \u{2022} **AIsaac** — that's me! AI assistant for session analysis (you're using it right now).

        *[Full AI-powered feature walkthroughs coming in the next update.]*
        """
    }
}
