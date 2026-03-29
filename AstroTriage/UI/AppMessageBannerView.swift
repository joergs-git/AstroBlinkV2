// In-App Message Banner — dynamic action rendering for all message types.
// Inserted between toolbar divider and main content area in ContentView.
// Night mode aware, matches existing status pill / toolbar styling.

import SwiftUI

struct AppMessageBannerView: View {
    let message: AppMessage
    let nightMode: Bool
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    let onRespond: (String, String?) -> Void  // (actionType, value)

    // Local state for interactive controls
    @State private var emailInput: String = ""
    @State private var textInput: String = ""
    @State private var selectedRadio: String? = nil
    @State private var sliderValue: Double = 3
    @State private var submitted: Bool = false

    // Night mode colors (matching ContentView)
    private var bannerBg: Color {
        if nightMode {
            return Color(red: 0.08, green: 0, blue: 0)
        }
        switch message.message_type {
        case "warning":      return Color(red: 0.95, green: 0.7, blue: 0.3).opacity(0.15)
        case "update_nudge": return Color(red: 0.3, green: 0.8, blue: 0.4).opacity(0.15)
        case "feedback":     return Color(red: 0.6, green: 0.5, blue: 0.9).opacity(0.15)
        case "email_collect": return Color(red: 0.5, green: 0.6, blue: 0.9).opacity(0.15)
        default:             return Color(red: 0.4, green: 0.7, blue: 0.95).opacity(0.15)
        }
    }

    private var accentColor: Color {
        if nightMode { return .red }
        switch message.message_type {
        case "warning":      return .orange
        case "update_nudge": return .green
        case "feedback":     return .purple
        case "email_collect": return .blue
        default:             return .blue
        }
    }

    private var fg: Color { nightMode ? .red : Color(NSColor.labelColor) }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : Color(NSColor.secondaryLabelColor) }
    private var dividerColor: Color { nightMode ? Color(red: 0.3, green: 0, blue: 0) : Color(NSColor.separatorColor) }

    var body: some View {
        if submitted {
            // Brief thank-you flash before removal
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 12))
                Text("Thanks for your feedback!")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(fg)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(bannerBg)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    onDismiss()
                }
            }
        } else {
            VStack(spacing: 0) {
                // Main content
                VStack(spacing: 4) {
                    // Row 1: Icon + title + body + action buttons + dismiss
                    HStack(spacing: 8) {
                        // Icon
                        Image(systemName: message.iconName)
                            .foregroundColor(accentColor)
                            .font(.system(size: 12))

                        // Title + body
                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.title)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(fg)
                                .lineLimit(1)

                            // Body with markdown link support
                            bodyText
                        }

                        Spacer()

                        // Simple action buttons (yes/no/link — no input needed)
                        simpleActionButtons

                        // Dismiss X
                        dismissButton
                    }

                    // Row 2: Interactive controls (email, radio, slider, text — if any)
                    interactiveControls
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(bannerBg)

                // Bottom divider
                Rectangle().fill(dividerColor).frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Body Text

    @ViewBuilder
    private var bodyText: some View {
        // Parse markdown links: [text](url)
        let parts = parseBodyLinks(message.body)
        if parts.count == 1 && parts[0].url == nil {
            Text(message.body)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
                .lineLimit(2)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if let url = part.url {
                        Link(part.text, destination: url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(accentColor)
                    } else {
                        Text(part.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(fgDim)
                    }
                }
            }
            .lineLimit(2)
        }
    }

    // MARK: - Simple Action Buttons

    @ViewBuilder
    private var simpleActionButtons: some View {
        let simpleTypes = Set(["yes", "no", "later", "link"])
        let simpleActions = message.actions.filter { simpleTypes.contains($0.type) }

        ForEach(Array(simpleActions.enumerated()), id: \.offset) { _, action in
            switch action.type {
            case "yes":
                actionButton(action.label ?? "Yes", color: .green) {
                    submitted = true
                    onRespond("yes", action.label ?? "yes")
                }
            case "no":
                actionButton(action.label ?? "No", color: .red) {
                    submitted = true
                    onRespond("no", action.label ?? "no")
                }
            case "later":
                actionButton(action.label ?? "Later", color: .gray) {
                    onSnooze()
                }
            case "link":
                if let urlStr = action.url, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        Text(action.label ?? "Open")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(accentColor, lineWidth: 1))
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Interactive Controls

    @ViewBuilder
    private var interactiveControls: some View {
        let interactiveTypes = Set(["email_input", "text_input", "radio", "slider"])
        let interactiveActions = message.actions.filter { interactiveTypes.contains($0.type) }

        if !interactiveActions.isEmpty {
            HStack(spacing: 8) {
                // Indent to align with text (past icon)
                Spacer().frame(width: 20)

                ForEach(Array(interactiveActions.enumerated()), id: \.offset) { _, action in
                    switch action.type {
                    case "email_input":
                        emailInputView(action)
                    case "text_input":
                        textInputView(action)
                    case "radio":
                        radioView(action)
                    case "slider":
                        sliderView(action)
                    default:
                        EmptyView()
                    }
                }

                // Send button for interactive inputs
                actionButton("Send", color: accentColor) {
                    submitInteractiveResponse(interactiveActions)
                }

                Spacer()
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Input Views

    private func emailInputView(_ action: AppMessageAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(action.placeholder ?? "you@example.com", text: $emailInput)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(fg)
                .frame(width: 220)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(nightMode ? Color(red: 0.12, green: 0, blue: 0) : Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(accentColor.opacity(0.5), lineWidth: 1)
                )

            // Dynamic privacy consent (from body markdown links)
            let links = parseBodyLinks(message.body)
            let hasPrivacyLink = links.contains { $0.url != nil }
            if hasPrivacyLink {
                HStack(spacing: 2) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 8))
                        .foregroundColor(fgDim)
                    ForEach(Array(links.filter { $0.url != nil }.enumerated()), id: \.offset) { _, part in
                        if let url = part.url {
                            Link(part.text, destination: url)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(accentColor.opacity(0.8))
                        }
                    }
                }
            }
        }
    }

    private func textInputView(_ action: AppMessageAction) -> some View {
        TextField(action.placeholder ?? "Your feedback...", text: $textInput)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(fg)
            .frame(width: 280)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(nightMode ? Color(red: 0.12, green: 0, blue: 0) : Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accentColor.opacity(0.5), lineWidth: 1)
            )
    }

    private func radioView(_ action: AppMessageAction) -> some View {
        HStack(spacing: 12) {
            if let label = action.label {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fgDim)
            }
            ForEach(action.options ?? [], id: \.self) { option in
                Button(action: { selectedRadio = option }) {
                    HStack(spacing: 4) {
                        Image(systemName: selectedRadio == option ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 10))
                            .foregroundColor(selectedRadio == option ? accentColor : fgDim)
                        Text(option)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(fg)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sliderView(_ action: AppMessageAction) -> some View {
        HStack(spacing: 6) {
            if let label = action.label {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(fgDim)
            }
            let minVal = Double(action.min ?? 1)
            let maxVal = Double(action.max ?? 5)
            let stepVal = Double(action.step ?? 1)
            Text("\(Int(minVal))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
            Slider(value: $sliderValue, in: minVal...maxVal, step: stepVal)
                .frame(width: 120)
                .tint(accentColor)
            Text("\(Int(maxVal))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fgDim)
            Text("(\(Int(sliderValue)))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(accentColor)
                .frame(width: 24)
        }
    }

    // MARK: - Helpers

    private func actionButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(color))
        }
        .buttonStyle(.plain)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(fgDim)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }

    /// Submit the response from interactive controls.
    private func submitInteractiveResponse(_ actions: [AppMessageAction]) {
        for action in actions {
            switch action.type {
            case "email_input":
                let email = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard email.contains("@"), email.contains(".") else { return }
                submitted = true
                onRespond("email_input", email)
                return
            case "text_input":
                let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                submitted = true
                onRespond("text_input", text)
                return
            case "radio":
                guard let selection = selectedRadio else { return }
                submitted = true
                onRespond("radio", selection)
                return
            case "slider":
                submitted = true
                onRespond("slider", "\(Int(sliderValue))")
                return
            default:
                break
            }
        }
    }

    // MARK: - Markdown Link Parser

    struct BodyPart {
        let text: String
        let url: URL?
    }

    /// Parse simple markdown links: [text](url) → array of text/link parts
    private func parseBodyLinks(_ body: String) -> [BodyPart] {
        var parts: [BodyPart] = []
        var remaining = body

        while let openBracket = remaining.range(of: "[") {
            // Add text before the link
            let prefix = String(remaining[remaining.startIndex..<openBracket.lowerBound])
            if !prefix.isEmpty { parts.append(BodyPart(text: prefix, url: nil)) }

            // Find closing bracket and opening paren
            let afterBracket = remaining[openBracket.upperBound...]
            guard let closeBracket = afterBracket.range(of: "]("),
                  let closeParen = afterBracket[closeBracket.upperBound...].range(of: ")") else {
                // Malformed link — add rest as plain text
                parts.append(BodyPart(text: String(remaining[openBracket.lowerBound...]), url: nil))
                remaining = ""
                break
            }

            let linkText = String(afterBracket[afterBracket.startIndex..<closeBracket.lowerBound])
            let linkURL = String(afterBracket[closeBracket.upperBound..<closeParen.lowerBound])
            parts.append(BodyPart(text: linkText, url: URL(string: linkURL)))
            remaining = String(afterBracket[closeParen.upperBound...])
        }

        if !remaining.isEmpty {
            parts.append(BodyPart(text: remaining, url: nil))
        }

        return parts.isEmpty ? [BodyPart(text: body, url: nil)] : parts
    }
}
