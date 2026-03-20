// AIsaac — In-app AI assistant for astrophotography session analysis
// Stage 0: UI skeleton with mock responses
import Foundation

// MARK: - Chat Message

struct AIsaacMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()

    enum Role {
        case user
        case assistant
    }
}

// MARK: - Preset Types (inspirational question chips)

enum AIsaacPreset: String, CaseIterable, Identifiable {
    // Session-aware presets (ordered by usage frequency)
    case qualitySummary = "Quality Summary"
    case smartMark = "Smart Mark"
    case filterAdvice = "Filter Advice"
    case objectTrivia = "About This Object"
    case nearbyObjects = "Nearby Objects"
    case planTonight = "Plan Tonight"
    // No-session presets (general help)
    case gettingStarted = "Getting Started"
    case workflowTips = "Workflow Tips"
    case whatsNew = "What's New?"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .qualitySummary: return "chart.bar.doc.horizontal"
        case .smartMark:      return "hand.thumbsdown"
        case .filterAdvice:   return "camera.filters"
        case .objectTrivia:   return "star.circle"
        case .nearbyObjects:  return "map"
        case .planTonight:    return "moon.stars"
        case .gettingStarted: return "arrow.right.circle"
        case .workflowTips:   return "lightbulb"
        case .whatsNew:       return "sparkle"
        }
    }

    var shortLabel: String {
        switch self {
        case .qualitySummary: return "Quality Summary"
        case .smartMark:      return "Smart Mark"
        case .filterAdvice:   return "Filter Advice"
        case .objectTrivia:   return "About This Object"
        case .nearbyObjects:  return "Nearby Objects"
        case .planTonight:    return "Plan Tonight"
        case .gettingStarted: return "Getting Started"
        case .workflowTips:   return "Workflow Tips"
        case .whatsNew:       return "What's New?"
        }
    }

    // User-facing prompt text sent as user message
    func userPrompt(context: AIsaacSessionContext?) -> String {
        let obj = context?.objects.first ?? "this object"
        switch self {
        case .qualitySummary:
            return "Give me a quality summary of this session."
        case .smartMark:
            return "Analyze my frames and suggest which ones to mark for deletion."
        case .filterAdvice:
            return "What filters should I improve for \(obj) on my next night?"
        case .objectTrivia:
            return "Tell me interesting facts about \(obj)."
        case .nearbyObjects:
            return "What deep-sky objects are close to \(obj) that I could image with my setup?"
        case .planTonight:
            return "Plan my imaging session for tonight: targets, filters, exposure times, number of subs, and start/end times."
        case .gettingStarted:
            return "How do I use AstroBlinkV2 to triage my imaging session?"
        case .workflowTips:
            return "What's the most efficient workflow for culling my subs?"
        case .whatsNew:
            return "What are the latest features in AstroBlinkV2?"
        }
    }
}

// MARK: - Session Context (built from TriageViewModel)

struct AIsaacSessionContext {
    let objects: [String]
    let filters: [String]
    let totalFrames: Int
    let markedCount: Int
    let perFilterStats: [FilterStat]
    let qualityDistribution: QualityDist
    let totalIntegrationSeconds: Double
    let telescope: String?
    let camera: String?
    let focalLength: Double?
    let pixelSize: Double?
    let siteLatitude: Double?
    let siteLongitude: Double?
    let sessionDate: String?
    let snrRetention: Double
    let isConverged: Bool
    let isCaching: Bool
    let scoredCount: Int  // frames with quality scores computed

    // Per-frame metrics for deep analysis (compact representation)
    let frameMetrics: [FrameMetric]

    struct FrameMetric {
        let index: Int
        let filename: String
        let filter: String
        let exposure: Double
        let tier: String        // "excellent", "good", "borderline", "trash", "unscored"
        let zScore: Double?
        let fwhm: Double?
        let hfr: Double?
        let stars: Int?
        let noise: Double?      // noiseMAD
        let ecc: Double?        // eccentricity
        let trailing: Double?   // trailing score
        let isMarked: Bool
        let garbageReason: String?
        let reasoning: String?
    }

    struct FilterStat {
        let filter: String
        let count: Int
        let exposure: Double
        let excellent: Int
        let good: Int
        let borderline: Int
        let trash: Int
    }

    struct QualityDist {
        let excellent: Int
        let good: Int
        let borderline: Int
        let trash: Int
    }
}

// MARK: - Model

@MainActor
class AIsaacModel: ObservableObject {
    // AIsaac mode: free Sonnet or pro Opus with user's own API key
    enum AIsaacMode: String {
        case free = "free"     // Sonnet via Edge Function (rate limited)
        case pro = "pro"       // Opus via direct API (user's own key)
    }

    @Published var mode: AIsaacMode = AIsaacKeychain.hasAPIKey ? .pro : .free
    @Published var showAPIKeyEntry: Bool = false
    @Published var apiKeyInput: String = ""

    @Published var messages: [AIsaacMessage] = []
    @Published var inputText: String = ""
    @Published var isThinking: Bool = false
    @Published var streamingText: String = ""  // incremental text during streaming
    @Published var isStreaming: Bool = false
    @Published var voiceEnabled: Bool = false  // TTS for responses
    @Published var currentThumbnailBase64: String?  // JPEG thumbnail of current image for Claude Vision
    @Published var currentImageHeaders: [(key: String, value: String)] = []  // FITS/XISF headers for current image

    let speechManager = AIsaacSpeechManager()
    @Published var showPresets: Bool = true
    @Published var sessionContext: AIsaacSessionContext?
    @Published var nightMode: Bool = false

    // Callback for Smart Mark: provides indices and reason, expects confirmation
    var onMarkRequested: (([Int], String) -> Void)?

    // App control callbacks — wired from ContentView to TriageViewModel
    var onNavigateToImage: ((Int) -> Void)?             // selectImage(at:)
    var onNavigateToFilter: ((String) -> Void)?         // filterText = "filter:X"
    var onNavigateToFirst: (() -> Void)?                // navigateToFirst()
    var onNavigateToLast: (() -> Void)?                 // navigateToLast()
    var onOpenCompare: (() -> Void)?                    // compare current with best
    var onOpenFolder: (() -> Void)?                     // openFolder()
    var onSetFilter: ((String) -> Void)?                // set search filter text
    var onStartStack: (() -> Void)?                     // startQuickStackV2()
    var onStackFrames: (([Int]) -> Void)?               // select specific frames then stack
    var onSetLanguage: ((String) -> Void)?              // save preferred language
    var onHideMarked: (() -> Void)?                     // hideMarked toggle
    var onShowOnlyMarked: (() -> Void)?                 // showOnlyMarked toggle
    var onShowAll: (() -> Void)?                        // reset hide/show filters
    var onSkipMarked: (() -> Void)?                     // toggle skip marked during nav
    var onMarkCurrent: (() -> Void)?                    // toggle mark on current image
    var onMarkFrames: (([Int]) -> Void)?                // mark specific frames for pre-delete
    var onNightMode: (() -> Void)?                      // toggle night mode
    var onHighlightFrames: (([Int]) -> Void)?           // select/highlight rows in file list (shift-click style)
    var onViewFrame: ((Int) -> Void)?                   // navigate to and display a specific frame
    var onOpenPreview: (([Int]) -> Void)?               // open image preview window(s) (double-click equivalent)
    var onRefreshContext: (() -> Void)?                  // refresh session context before each query

    // Quick-reply buttons shown when AIsaac asks a question
    @Published var quickReplies: [String] = []

    // Last user message for retry
    @Published var lastUserMessage: String?
    @Published var lastUserPreset: AIsaacPreset?

    // Show "switch language" pill after AIsaac detects location
    @Published var showLanguageSwitchPill: Bool = false
    @Published var detectedLanguage: String = ""        // e.g. "German", "Dutch"
    @Published var detectedLanguageCode: String = ""    // e.g. "de", "nl"

    // Track state transitions for reactive comments
    private var lastKnownFrameCount: Int = 0
    private var lastKnownCachingState: Bool = false
    private var lastKnownCachingDone: Bool = false
    private var lastKnownMarkedCount: Int = 0
    private var hasGreetedSession: Bool = false

    // State change comments — witty, contextual, brief
    private static let sessionLoadedComments = [
        "Nice, %d frames just landed! Let's see what the sky had for dinner tonight.",
        "Alright, %d frames loaded — time to separate the gems from the space junk.",
        "%d subs? Challenge accepted. Let's find the keepers.",
        "Oh, %d frames! That's a serious night of photon collecting. Let's dig in.",
    ]

    private static let cachingStartedComments = [
        "Pre-caching in progress — the CPU is sweating like hell counting pixels. Hang tight.",
        "Crunching numbers... every star is being interrogated right now.",
        "GPU is warming up — give it a moment to stretch all those photons.",
        "Analyzing frames... this is where the magic happens behind the scenes.",
    ]

    private static let cachingDoneComments = [
        "All frames analyzed! Quality scores are in — check the Q column.",
        "Done! Every frame has been measured, scored, and judged. Tap 'Quality Summary' for the full picture.",
        "Caching complete. Your session is fully loaded — let's triage.",
    ]

    private static let markingComments: [(threshold: Int, comment: String)] = [
        (5, "You've marked %d frames so far — cleaning house!"),
        (20, "%d frames marked. You're on a culling spree."),
        (50, "%d marked! That's some serious quality control."),
    ]

    // Called by AIsaacWindowController when app state changes
    func handleStateChange(
        totalFrames: Int,
        isCaching: Bool,
        cacheProgress: Double,
        markedCount: Int,
        isConverged: Bool
    ) {
        // Don't show static/mock reactive comments when conversation is active
        // (they feel out of place once the user is talking to the real AI)
        if !messages.isEmpty { return }

        // Session just loaded (frames appeared)
        if totalFrames > 0 && lastKnownFrameCount == 0 && !hasGreetedSession {
            hasGreetedSession = true
            let template = Self.sessionLoadedComments.randomElement()!
            let comment = String(format: template, totalFrames)
            postStateComment(comment)
        }

        // Caching started
        if isCaching && !lastKnownCachingState {
            let comment = Self.cachingStartedComments.randomElement()!
            postStateComment(comment)
        }

        // Caching finished
        if !isCaching && lastKnownCachingState && cacheProgress >= 0.99 && !lastKnownCachingDone {
            lastKnownCachingDone = true
            let comment = Self.cachingDoneComments.randomElement()!
            postStateComment(comment)
        }

        // Marking milestones
        for milestone in Self.markingComments {
            if markedCount >= milestone.threshold && lastKnownMarkedCount < milestone.threshold {
                let comment = String(format: milestone.comment, markedCount)
                postStateComment(comment)
                break
            }
        }

        // Convergence reached
        if isConverged && markedCount > lastKnownMarkedCount && markedCount > 0 {
            // Only announce once when convergence is first achieved
            if lastKnownMarkedCount == 0 || !lastKnownCachingDone {
                // skip — too early
            }
        }

        lastKnownFrameCount = totalFrames
        lastKnownCachingState = isCaching
        lastKnownMarkedCount = markedCount
    }

    // Generate context-aware quick-reply buttons based on response content
    func updateQuickReplies(for response: String) {
        let lower = response.lowercased()

        // Mark/delete questions
        if (lower.contains("markieren") || lower.contains("mark") || lower.contains("löschen") || lower.contains("delete")) &&
           (lower.contains("soll") || lower.contains("shall") || lower.contains("want") || lower.contains("?")) {
            quickReplies = ["Yes, mark them", "No, leave them", "Show me first"]
            return
        }

        // Language choice
        if lower.contains("deutsch") && (lower.contains("english") || lower.contains("englisch")) {
            quickReplies = ["Deutsch", "English"]
            return
        }

        // After quality summary — offer follow-up actions
        if lower.contains("quality") || lower.contains("qualität") || lower.contains("ausgezeichnet") || lower.contains("excellent") {
            quickReplies = ["Mark trash for me", "Show worst frames", "Filter advice"]
            return
        }

        // After filter analysis — offer next steps
        if lower.contains("filter") && (lower.contains("empfehl") || lower.contains("recommend") || lower.contains("mehr daten") || lower.contains("more data")) {
            quickReplies = ["Plan tonight", "Show filter details", "Nearby objects"]
            return
        }

        // Compare/view questions
        if lower.contains("vergleichen") || lower.contains("compare") || lower.contains("anschauen") || lower.contains("look at") {
            quickReplies = ["Yes, compare", "Skip", "Show next"]
            return
        }

        // General yes/no question
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") {
            // Try to extract meaningful options from the question
            if lower.contains("weiter") || lower.contains("continue") || lower.contains("next") {
                quickReplies = ["Yes, continue", "No, that's enough"]
            } else if lower.contains("detail") || lower.contains("genauer") || lower.contains("closer") {
                quickReplies = ["Yes, show details", "No thanks"]
            } else {
                quickReplies = ["Yes", "No"]
            }
            return
        }

        quickReplies = []
    }

    // Send a quick reply
    func sendQuickReply(_ text: String) {
        quickReplies = []
        inputText = text
        sendMessage()
    }

    func postStateComment(_ text: String) {
        // Don't interrupt while user is typing or AI is thinking
        guard !isThinking else { return }
        messages.append(AIsaacMessage(role: .assistant, text: text))
    }

    // Reset state tracking (e.g. when a new session is loaded)
    func resetStateTracking() {
        lastKnownFrameCount = 0
        lastKnownCachingState = false
        lastKnownCachingDone = false
        lastKnownMarkedCount = 0
        hasGreetedSession = false
    }

    // Whether a session with images is loaded
    var hasSession: Bool {
        guard let ctx = sessionContext else { return false }
        return ctx.totalFrames > 0
    }

    // Welcome message adapts to session state
    var welcomeMessage: String {
        if let ctx = sessionContext, ctx.totalFrames > 0 {
            let obj = ctx.objects.joined(separator: ", ")
            return "Hello! I'm AIsaac. I see you're working on \(obj) — \(ctx.totalFrames) frames across \(ctx.filters.count) filter\(ctx.filters.count == 1 ? "" : "s"). How can I help?"
        }
        return "Hello! I'm AIsaac, your astrophotography assistant. No session loaded yet — open a folder with your subs to unlock full analysis. In the meantime, ask me anything about the app or astrophotography!"
    }

    // Short summary for window header
    var sessionSummaryShort: String {
        guard let ctx = sessionContext else { return "No session" }
        let obj = ctx.objects.prefix(3).joined(separator: ", ")
        return "\(obj) \u{2022} \(ctx.totalFrames) frames"
    }

    // Available presets filtered by context
    var availablePresets: [AIsaacPreset] {
        guard let ctx = sessionContext, ctx.totalFrames > 0 else {
            // No session — show planning + general help presets
            var noSessionPresets: [AIsaacPreset] = []
            if AIsaacUserProfile.load().equipmentSetups.count > 0 {
                noSessionPresets.append(.planTonight)
            }
            noSessionPresets.append(contentsOf: [.gettingStarted, .workflowTips, .whatsNew])
            return noSessionPresets
        }
        // Session loaded — ordered by usage frequency
        var presets: [AIsaacPreset] = [.qualitySummary, .smartMark]
        if ctx.filters.count > 1 {
            presets.append(.filterAdvice)
        }
        if !ctx.objects.isEmpty && ctx.objects.first != "unknown" {
            presets.append(.objectTrivia)
            presets.append(.nearbyObjects)
        }
        presets.append(.planTonight)
        return presets
    }

    // Send a preset question
    func sendPreset(_ preset: AIsaacPreset) {
        let text = preset.userPrompt(context: sessionContext)

        messages.append(AIsaacMessage(role: .user, text: text))
        showPresets = false
        isThinking = true

        Task {
            let response = await AIsaacService.shared.ask(
                userMessage: text,
                preset: preset,
                context: sessionContext,
                history: messages
            )
            isThinking = false
            // Strip command blocks from displayed text
            let displayText = Self.stripCommandBlocks(response)
            messages.append(AIsaacMessage(role: .assistant, text: displayText))
            parseAndExecuteCommands(response)
            if voiceEnabled { speechManager.speak(displayText) }
            updateQuickReplies(for: displayText)
            showPresets = true
        }
    }

    // Send free-form message
    // Retry last message
    func retryLast() {
        guard let lastMsg = lastUserMessage else { return }
        inputText = lastMsg
        sendMessage()
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        lastUserMessage = text
        lastUserPreset = nil

        // Refresh context right before query so data is current
        onRefreshContext?()

        messages.append(AIsaacMessage(role: .user, text: text))
        showPresets = false
        streamingText = ""
        isStreaming = true
        isThinking = true

        // Wire streaming callback
        AIsaacService.shared.onStreamChunk = { [weak self] chunk in
            DispatchQueue.main.async {
                self?.isThinking = false  // stop dots after first chunk
                self?.streamingText += chunk
            }
        }

        Task {
            let response = await AIsaacService.shared.ask(
                userMessage: text,
                preset: nil,
                context: sessionContext,
                history: messages
            )
            AIsaacService.shared.onStreamChunk = nil
            isThinking = false
            isStreaming = false
            // Use streamed text if available, otherwise full response
            let fullText = streamingText.isEmpty ? response : streamingText
            streamingText = ""
            let displayText = Self.stripCommandBlocks(fullText)
            messages.append(AIsaacMessage(role: .assistant, text: displayText))
            parseAndExecuteCommands(fullText)
            if voiceEnabled { speechManager.speak(displayText) }
            updateQuickReplies(for: displayText)
            showPresets = true
        }
    }

    // Switch language and repeat last response
    func switchLanguageAndRepeat() {
        showLanguageSwitchPill = false

        // Save preference
        var profile = AIsaacUserProfile.load()
        profile.preferredLanguage = detectedLanguageCode
        profile.save()

        // Ask AIsaac to repeat in the preferred language
        let text = "Please switch to \(detectedLanguage) and repeat your last answer."
        messages.append(AIsaacMessage(role: .user, text: text))
        showPresets = false
        isThinking = true

        Task {
            let response = await AIsaacService.shared.ask(
                userMessage: text,
                preset: nil,
                context: sessionContext,
                history: messages
            )
            isThinking = false
            // Strip command blocks from displayed text
            let displayText = Self.stripCommandBlocks(response)
            messages.append(AIsaacMessage(role: .assistant, text: displayText))
            parseAndExecuteCommands(response)
            if voiceEnabled { speechManager.speak(displayText) }
            updateQuickReplies(for: displayText)
            showPresets = true
        }
    }

    // Detect language from coordinates and show pill
    func detectLanguageFromLocation() {
        guard let ctx = sessionContext,
              let lat = ctx.siteLatitude, let lon = ctx.siteLongitude else { return }
        // Already has a saved preference — don't ask again
        let profile = AIsaacUserProfile.load()
        if profile.preferredLanguage != nil { return }

        // Simple country detection from coordinates (rough bounding boxes)
        let lang: (name: String, code: String)?
        if lat > 47 && lat < 55 && lon > 5.5 && lon < 15.5 { lang = ("German", "de") }
        else if lat > 50.5 && lat < 53.7 && lon > 3.2 && lon < 7.3 { lang = ("Dutch", "nl") }
        else if lat > 41 && lat < 51.5 && lon > -5.5 && lon < 8.3 { lang = ("French", "fr") }
        else if lat > 36 && lat < 44 && lon > -10 && lon < -6 { lang = ("Portuguese", "pt") }
        else if lat > 36 && lat < 44 && lon > -10 && lon < 4 { lang = ("Spanish", "es") }
        else if lat > 36 && lat < 47 && lon > 6 && lon < 19 { lang = ("Italian", "it") }
        else if lat > 55 && lat < 70 && lon > 4 && lon < 30 { lang = ("Swedish", "sv") }
        else { lang = nil }

        if let lang = lang, lang.code != "en" {
            detectedLanguage = lang.name
            detectedLanguageCode = lang.code
            showLanguageSwitchPill = true
        }
    }

    // Strip ```command``` blocks from displayed text so user doesn't see raw JSON
    private static func stripCommandBlocks(_ text: String) -> String {
        let pattern = "```command\\s*\\n?\\{[^`]+\\}\\s*\\n?```\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Parse and execute command blocks from AIsaac responses
    func parseAndExecuteCommands(_ response: String) {
        // Look for ```command ... ``` blocks
        let pattern = "```command\\s*\\n?(\\{[^`]+\\})\\s*\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return }
        let range = NSRange(response.startIndex..., in: response)

        regex.enumerateMatches(in: response, range: range) { match, _, _ in
            guard let match = match,
                  let jsonRange = Range(match.range(at: 1), in: response) else { return }
            let jsonStr = String(response[jsonRange])
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = json["action"] as? String else { return }
            let params = json["params"] as? [String: Any]

            executeCommand(action: action, params: params)
        }
    }

    // Resolve 1-based session # to array index (handles sorted/filtered lists)
    var resolveSessionIndex: ((Int) -> Int?)? // maps session# → array index

    private func executeCommand(action: String, params: [String: Any]?) {
        switch action {
        case "navigate", "view":
            if let sessionNum = params?["index"] as? Int,
               let arrayIdx = resolveSessionIndex?(sessionNum) {
                onNavigateToImage?(arrayIdx)
            }
        case "navigate_first":
            onNavigateToFirst?()
        case "navigate_last":
            onNavigateToLast?()
        case "filter":
            if let text = params?["text"] as? String {
                onSetFilter?(text)
            }
        case "clear_filter":
            onSetFilter?("")
        case "compare":
            onOpenCompare?()
        case "open_folder":
            onOpenFolder?()
        case "stack":
            onStartStack?()
        case "hide_marked":
            onHideMarked?()
        case "show_only_marked":
            onShowOnlyMarked?()
        case "show_all":
            onShowAll?()
        case "skip_marked":
            onSkipMarked?()
        case "mark_current":
            onMarkCurrent?()
        case "mark_frames":
            if let sessionNums = params?["indices"] as? [Int] {
                let arrayIndices = sessionNums.compactMap { resolveSessionIndex?($0) }
                if !arrayIndices.isEmpty { onMarkFrames?(arrayIndices) }
            }
        case "highlight":
            if let sessionNums = params?["indices"] as? [Int] {
                let arrayIndices = sessionNums.compactMap { resolveSessionIndex?($0) }
                if !arrayIndices.isEmpty { onHighlightFrames?(arrayIndices) }
            }
        case "stack_frames":
            if let sessionNums = params?["indices"] as? [Int] {
                let arrayIndices = sessionNums.compactMap { resolveSessionIndex?($0) }
                if arrayIndices.count >= 3 { onStackFrames?(arrayIndices) }
            }
        case "open_preview":
            if let sessionNums = params?["indices"] as? [Int] {
                let arrayIndices = sessionNums.compactMap { resolveSessionIndex?($0) }
                if !arrayIndices.isEmpty { onOpenPreview?(arrayIndices) }
            } else if let sessionNum = params?["index"] as? Int,
                      let arrayIdx = resolveSessionIndex?(sessionNum) {
                onOpenPreview?([arrayIdx])
            }
        case "night_mode":
            onNightMode?()
        default:
            break
        }
    }

    // Switch to pro mode with user's API key
    func activateProMode() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.hasPrefix("sk-ant-") else { return }
        if AIsaacKeychain.saveAPIKey(key) {
            mode = .pro
            apiKeyInput = ""
            showAPIKeyEntry = false
            postStateComment("🌟 Opus Superexpert activated! Your own API key is stored securely in macOS Keychain.")
        }
    }

    // Switch back to free mode
    func deactivateProMode() {
        AIsaacKeychain.deleteAPIKey()
        mode = .free
        postStateComment("Switched back to free Sonnet mode.")
    }

    // Clear conversation history
    func clearConversation() {
        messages.removeAll()
        showPresets = true
    }
}
