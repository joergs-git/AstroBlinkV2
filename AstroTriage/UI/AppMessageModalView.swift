// In-App Message Modal — popup presentation for messages with display_mode == "modal".
//
// Complements AppMessageBannerView (display_mode == "banner", the default and unchanged
// path). A modal is for announcements that deserve attention on launch and can carry a
// short video; the banner stays the low-friction inline channel.
//
// Both views drive the SAME AppMessageService callbacks, so targeting, repeat modes,
// snooze and impression tracking behave identically regardless of presentation.
//
// v6.9.0

import SwiftUI
import WebKit

// MARK: - Video Embed

/// Minimal WKWebView wrapper for a YouTube/Vimeo embed.
///
/// SECURITY: the URL has already passed `AppMessage.videoEmbedURL` (https + host
/// allowlist). On top of that this view refuses any navigation the embed itself tries to
/// initiate that is not the embed URL — a clicked in-player link opens in the user's real
/// browser instead of navigating our web view somewhere unexpected. No JS bridge, no data
/// store sharing with anything else in the app.
private struct VideoEmbedView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(embedURL: url) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral store: nothing the embed sets survives the popup.
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        Self.load(url, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the message (and therefore the embed) actually changed —
        // updateNSView fires on every @Published change in this app.
        guard context.coordinator.embedURL != url else { return }
        context.coordinator.embedURL = url
        Self.load(url, into: webView)
    }

    /// Load the embed inside a minimal local wrapper page rather than navigating straight
    /// to it.
    ///
    /// Loading an embed URL directly gives the web view no origin, and YouTube answers with
    /// "Error 153 — video player configuration error" instead of the player. Hosting the
    /// iframe in a document whose baseURL is the embed's own https origin fixes that, and
    /// it also keeps the player boxed in a subframe we control.
    private static func load(_ embed: URL, into webView: WKWebView) {
        // The URL already passed AppMessage.videoEmbedURL (https + host allowlist + strict
        // id charset), so it cannot carry quotes or markup — escaped anyway on principle,
        // since this string is interpolated into HTML.
        let src = embed.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")

        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body { margin:0; padding:0; height:100%; background:#000; overflow:hidden; }
          iframe { border:0; width:100%; height:100%; display:block; }
        </style></head>
        <body><iframe src="\(src)"
            allow="accelerometer; encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen></iframe></body></html>
        """

        // baseURL must be a real https origin for the embed to accept the request.
        let origin = embed.host.flatMap { URL(string: "https://\($0)/") }
        webView.loadHTMLString(html, baseURL: origin)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop playback immediately when the popup closes; otherwise audio keeps running.
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var embedURL: URL
        init(embedURL: URL) { self.embedURL = embedURL }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // A click inside the player ("Watch on YouTube", channel links, the error
            // page's buttons) must never navigate our web view — hand it to the user's
            // default browser instead. Everything else is the wrapper page and the player
            // iframe loading themselves, which is what we asked for; the embed URL already
            // passed the https + host allowlist before we ever got here.
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if let external = AppMessageLink.safe(target) {
                NSWorkspace.shared.open(external)
            }
        }
    }
}

// MARK: - Modal

struct AppMessageModalView: View {
    let message: AppMessage
    let nightMode: Bool
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    let onRespond: (String, String?) -> Void  // (actionType, value)

    // Local state for interactive controls — mirrors AppMessageBannerView.
    @State private var emailInput: String = ""
    @State private var textInput: String = ""
    @State private var selectedRadio: String? = nil
    @State private var sliderValue: Double = 3
    @State private var submitted: Bool = false

    // Night mode colors, matching the banner so both channels look like one system.
    private var accentColor: Color {
        if nightMode { return .red }
        switch message.message_type {
        case "warning":       return .orange
        case "update_nudge":  return .green
        case "feedback":      return .purple
        case "email_collect": return .blue
        default:              return .blue
        }
    }

    private var panelBg: Color {
        nightMode ? Color(red: 0.08, green: 0, blue: 0) : Color(NSColor.windowBackgroundColor)
    }
    private var fg: Color { nightMode ? .red : Color(NSColor.labelColor) }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : Color(NSColor.secondaryLabelColor) }

    /// Video is optional — a modal without media is just a bigger, blocking announcement.
    private var videoURL: URL? { message.videoEmbedURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let videoURL {
                        VStack(alignment: .trailing, spacing: 6) {
                            VideoEmbedView(url: videoURL)
                                .frame(height: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(fgDim.opacity(0.25), lineWidth: 1)
                                )

                            // Escape hatch from the small embedded player: full size,
                            // real playback controls, and it survives closing the popup.
                            if let watchURL = message.videoWatchURL {
                                Button {
                                    NSWorkspace.shared.open(watchURL)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.forward.app")
                                            .font(.system(size: 10))
                                        Text("Open in browser")
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .foregroundColor(accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("Open this video in your default browser")
                            }
                        }
                    }

                    bodyText

                    if !submitted {
                        interactiveControls
                    }
                }
                .padding(16)
            }

            Divider()

            footer
        }
        .frame(width: videoURL != nil ? 680 : 460)
        .frame(maxHeight: 720)
        .background(panelBg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: message.iconName)
                .foregroundColor(accentColor)
                .font(.system(size: 18))

            Text(message.title)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(fg)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(fgDim)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyText: some View {
        if submitted {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Thanks for your feedback!")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(fg)
            }
        } else {
            // Markdown links in the body are rendered by SwiftUI's own parser here;
            // the banner hand-parses because it must stay on a single line.
            Text(attributedBody)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(fgDim)
                .tint(accentColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var attributedBody: AttributedString {
        guard var parsed = try? AttributedString(
            markdown: message.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(message.body) }

        // SwiftUI renders markdown links as clickable, so every link the parser produced
        // goes through the same gate; a rejected one degrades to plain text.
        for run in parsed.runs where run.link != nil {
            if AppMessageLink.safe(run.link) == nil {
                parsed[run.range].link = nil
            }
        }
        return parsed
    }

    // MARK: - Interactive Controls

    @ViewBuilder
    private var interactiveControls: some View {
        let interactiveTypes = Set(["email_input", "text_input", "radio", "slider"])
        let interactiveActions = message.actions.filter { interactiveTypes.contains($0.type) }

        if !interactiveActions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(interactiveActions.enumerated()), id: \.offset) { _, action in
                    switch action.type {
                    case "email_input":
                        inputField(placeholder: action.placeholder ?? "you@example.com",
                                   text: $emailInput, width: 300)
                    case "text_input":
                        inputField(placeholder: action.placeholder ?? "Your feedback...",
                                   text: $textInput, width: 380)
                    case "radio":
                        radioView(action)
                    case "slider":
                        sliderView(action)
                    default:
                        EmptyView()
                    }
                }

                Button("Send") { submitInteractiveResponse(interactiveActions) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func inputField(placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(fg)
            .frame(width: width)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(nightMode ? Color(red: 0.12, green: 0, blue: 0) : Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4).stroke(accentColor.opacity(0.5), lineWidth: 1)
            )
    }

    private func radioView(_ action: AppMessageAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = action.label {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgDim)
            }
            ForEach(action.options ?? [], id: \.self) { option in
                Button(action: { selectedRadio = option }) {
                    HStack(spacing: 6) {
                        Image(systemName: selectedRadio == option ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundColor(selectedRadio == option ? accentColor : fgDim)
                        Text(option)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(fg)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sliderView(_ action: AppMessageAction) -> some View {
        let minVal = Double(action.min ?? 1)
        let maxVal = Double(action.max ?? 5)
        let stepVal = Double(action.step ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            if let label = action.label {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(fgDim)
            }
            HStack(spacing: 8) {
                Text("\(Int(minVal))")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(fgDim)
                Slider(value: $sliderValue, in: minVal...maxVal, step: stepVal)
                    .frame(width: 180)
                    .tint(accentColor)
                Text("\(Int(maxVal))")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(fgDim)
                Text("(\(Int(sliderValue)))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            ForEach(Array(message.actions.enumerated()), id: \.offset) { _, action in
                switch action.type {
                case "link":
                    if let url = AppMessageLink.safe(action.url) {
                        Link(action.label ?? "Open", destination: url)
                    }
                case "later":
                    Button(action.label ?? "Later") { onSnooze() }
                case "no":
                    Button(action.label ?? "No") {
                        submitted = true
                        onRespond("no", action.label ?? "no")
                        closeAfterThanks()
                    }
                case "yes":
                    Button(action.label ?? "Yes") {
                        submitted = true
                        onRespond("yes", action.label ?? "yes")
                        closeAfterThanks()
                    }
                    .keyboardShortcut(.defaultAction)
                default:
                    EmptyView()
                }
            }

            // A modal must always be closable, even if the row defines no actions at all.
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func closeAfterThanks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onDismiss() }
    }

    /// Submit the response from interactive controls. Mirrors the banner's validation so
    /// both channels accept exactly the same input.
    private func submitInteractiveResponse(_ actions: [AppMessageAction]) {
        for action in actions {
            switch action.type {
            case "email_input":
                let email = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard email.contains("@"), email.contains(".") else { return }
                submitted = true
                onRespond("email_input", email)
                closeAfterThanks()
                return
            case "text_input":
                let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                submitted = true
                onRespond("text_input", text)
                closeAfterThanks()
                return
            case "radio":
                guard let selection = selectedRadio else { return }
                submitted = true
                onRespond("radio", selection)
                closeAfterThanks()
                return
            case "slider":
                submitted = true
                onRespond("slider", "\(Int(sliderValue))")
                closeAfterThanks()
                return
            default:
                break
            }
        }
    }
}
