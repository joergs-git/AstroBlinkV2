// AIsaac — SwiftUI chat interface with purple theme and preset chips
import SwiftUI

// MARK: - Main View

struct AIsaacView: View {
    @ObservedObject var model: AIsaacModel

    // Purple theme colors
    private var bgGradient: LinearGradient {
        if model.nightMode {
            // Night mode: dark red-purple
            return LinearGradient(
                colors: [Color(red: 0.15, green: 0.02, blue: 0.08),
                         Color(red: 0.08, green: 0.01, blue: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.12, green: 0.04, blue: 0.22),
                     Color(red: 0.06, green: 0.02, blue: 0.12)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var accentColor: Color {
        model.nightMode ? Color(red: 0.6, green: 0.1, blue: 0.1) : .purple
    }

    private var textColor: Color {
        model.nightMode ? Color(red: 0.8, green: 0.2, blue: 0.2) : .white
    }

    private var dimTextColor: Color {
        textColor.opacity(0.5)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — always visible, click title to toggle
            headerBar
            Divider().background(accentColor.opacity(0.3))

            // Expanded: full chat area
            if !model.isCollapsed {
                expandedContent
            }

            // Preset chips — always visible
            collapsedChips

            // Input bar — always visible, typing expands
            inputBar
                .onChange(of: model.inputText) { _, newValue in
                    if !newValue.isEmpty && model.isCollapsed {
                        withAnimation(.easeInOut(duration: 0.2)) { model.isCollapsed = false }
                    }
                }
        }
        .background(bgGradient)
    }

    // MARK: - Collapsed Chips (preset buttons only, header shown above)

    private var collapsedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(model.availablePresets) { preset in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { model.isCollapsed = false }
                        model.sendPreset(preset)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 9))
                            Text(preset.shortLabel)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accentColor.opacity(0.15)))
                        .foregroundColor(accentColor.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Expanded Content (full chat)

    private var expandedContent: some View {
        VStack(spacing: 0) {

            // API key entry panel (shown when upgrading to Opus)
            if model.showAPIKeyEntry {
                VStack(alignment: .leading, spacing: 6) {
                    Text("🔑 Enter your Anthropic API key for Opus Superexpert")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textColor)
                    HStack(spacing: 2) {
                        Text("Key stored in macOS Keychain.")
                            .font(.system(size: 10))
                            .foregroundColor(dimTextColor)
                        Button("Get one at console.anthropic.com →") {
                            NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                    }
                    HStack(spacing: 6) {
                        SecureField("sk-ant-api03-...", text: $model.apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.1))
                            )
                        Button("Activate") { model.activateProMode() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                            .disabled(!model.apiKeyInput.hasPrefix("sk-ant-"))
                        Button("Cancel") { model.showAPIKeyEntry = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(dimTextColor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))

                Divider().background(accentColor.opacity(0.3))
            }

            // Chat area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Welcome message (always visible)
                        assistantBubble(model.welcomeMessage, id: "welcome")

                        // Conversation messages
                        ForEach(model.messages) { msg in
                            if msg.role == .user {
                                userBubble(msg.text, id: msg.id.uuidString)
                            } else {
                                assistantBubble(msg.text, id: msg.id.uuidString)
                            }
                        }

                        // Streaming response (live-updating text)
                        if model.isStreaming && !model.streamingText.isEmpty {
                            assistantBubble(model.streamingText, id: "streaming")
                        }

                        // Thinking indicator (dots before first chunk arrives)
                        if model.isThinking && model.streamingText.isEmpty {
                            thinkingIndicator
                                .id("thinking")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.3)) {
                        if model.isThinking {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        } else if let last = model.messages.last {
                            proxy.scrollTo(last.id.uuidString, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.isThinking) { thinking in
                    if thinking {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.streamingText) { _ in
                    // Auto-scroll as streaming text grows
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }

            Divider().background(accentColor.opacity(0.3))

            // Retry button
            if model.lastUserMessage != nil && !model.isThinking {
                HStack {
                    Spacer()
                    Button(action: { model.retryLast() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10))
                            Text("Retry")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(dimTextColor)
                    }
                    .buttonStyle(.plain)
                    .help("Retry last message")
                    .padding(.trailing, 16)
                    .padding(.vertical, 2)
                }
            }

            // Quick-reply buttons when AIsaac asks a question
            if !model.quickReplies.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.quickReplies, id: \.self) { reply in
                        Button(action: { model.sendQuickReply(reply) }) {
                            Text(reply)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundColor(.white)
                                .background(
                                    Capsule()
                                        .fill(accentColor.opacity(0.35))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            // Language switch pill
            if model.showLanguageSwitchPill {
                Button(action: { model.switchLanguageAndRepeat() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text("Switch to \(model.detectedLanguage)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundColor(.white)
                    .background(
                        Capsule()
                            .fill(accentColor.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            // AIsaac icon — sparkles with glow effect
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(accentColor)
                .shadow(color: accentColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { model.isCollapsed.toggle() } }) {
                    Text("AIsaac's AstroBlink")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(textColor)
                }
                .buttonStyle(.plain)

                // Mode indicator — tappable
                Button(action: {
                    if model.mode == .pro {
                        model.deactivateProMode()
                    } else {
                        model.showAPIKeyEntry.toggle()
                    }
                }) {
                    Text(model.mode == .pro ? "✨ Opus Superexpert" : "Free Sonnet Buddy")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(model.mode == .pro ? Color.orange : dimTextColor)
                }
                .buttonStyle(.plain)
                .help(model.mode == .pro ? "Click to switch back to free Sonnet" : "Click to activate Opus with your own API key")
            }

            Spacer()

            Text(model.sessionSummaryShort)
                .font(.system(size: 11))
                .foregroundColor(dimTextColor)

            // Clear conversation button
            if !model.messages.isEmpty {
                Button(action: { model.clearConversation() }) {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 14))
                        .foregroundColor(dimTextColor)
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
            }

            // Collapse button
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { model.isCollapsed = true } }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(dimTextColor)
            }
            .buttonStyle(.plain)
            .help("Collapse to preset chips")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Message Bubbles

    private func assistantBubble(_ text: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Small sparkles icon for assistant
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundColor(accentColor)
                .frame(width: 16, height: 16)
                .padding(.top, 4)

            Text(parseMarkdown(text))
                .font(.system(size: 12))
                .foregroundColor(textColor.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accentColor.opacity(0.15))
                )

            // Copy button beside bubble
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(dimTextColor)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
            .padding(.top, 6)

            Spacer(minLength: 20)
        }
        .id(id)
    }

    private func userBubble(_ text: String, id: String) -> some View {
        HStack {
            Spacer(minLength: 60)

            Text(text)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accentColor.opacity(0.3))
                )
        }
        .id(id)
    }

    // MARK: - Thinking Indicator

    private var thinkingIndicator: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundColor(accentColor)
                .frame(width: 16, height: 16)
                .padding(.top, 4)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(0.6)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(i) * 0.2),
                            value: model.isThinking
                        )
                        .scaleEffect(model.isThinking ? 1.2 : 0.8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(accentColor.opacity(0.15))
            )

            Spacer()
        }
    }

    // MARK: - Preset Chips

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.availablePresets) { preset in
                    Button(action: { model.sendPreset(preset) }) {
                        HStack(spacing: 4) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 10))
                            Text(preset.shortLabel)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(accentColor)
                        .background(
                            Capsule()
                                .stroke(accentColor.opacity(0.5), lineWidth: 1)
                                .background(Capsule().fill(accentColor.opacity(0.08)))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(preset.rawValue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Mic button — hold to talk
            if model.speechManager.isAuthorized {
                Button(action: {}) {
                    Image(systemName: model.speechManager.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundColor(model.speechManager.isListening ? .red : dimTextColor)
                }
                .buttonStyle(.plain)
                .help("Hold to talk")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !model.speechManager.isListening {
                                model.speechManager.startListening()
                            }
                        }
                        .onEnded { _ in
                            let text = model.speechManager.stopListening()
                            if !text.isEmpty {
                                model.inputText = text
                                model.sendMessage()
                            }
                        }
                )
            }

            TextField("Ask AIsaac...", text: $model.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                )
                .onSubmit { model.sendMessage() }

            // Voice toggle — TTS for responses
            Button(action: {
                model.voiceEnabled.toggle()
                if !model.voiceEnabled { model.speechManager.stopSpeaking() }
            }) {
                Image(systemName: model.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 14))
                    .foregroundColor(model.voiceEnabled ? accentColor : dimTextColor)
            }
            .buttonStyle(.plain)
            .help(model.voiceEnabled ? "Disable voice responses" : "Enable voice responses")

            Button(action: { model.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(
                        model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isThinking
                        ? dimTextColor
                        : accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isThinking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.25))
    }

    // MARK: - Markdown Parsing (lightweight)

    // Handles **bold**, line breaks, and basic structure
    private func parseMarkdown(_ text: String) -> AttributedString {
        // Try Apple's built-in markdown parser first (handles **bold**, bullet lists, etc.)
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            var styled = attributed
            styled.font = .system(size: 12)
            return styled
        }

        // Fallback: manual **bold** parsing
        var result = AttributedString()
        let parts = text.components(separatedBy: "**")
        for (index, part) in parts.enumerated() {
            var attr = AttributedString(part)
            if index % 2 == 1 {
                attr.font = .system(size: 12, weight: .bold)
            } else {
                attr.font = .system(size: 12)
            }
            result.append(attr)
        }
        return result
    }
}
