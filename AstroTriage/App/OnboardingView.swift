// First-launch onboarding screen — 4 marketing pillars, telemetry disclosure
// with inline opt-out, and links into the rest of the app surface.
// Hosted by AboutWindowController.showOnboarding().
import SwiftUI

struct OnboardingView: View {
    var dismissAction: () -> Void
    @State private var hoveredCard: Int? = nil
    @State private var hideSplash: Bool = AppSettings.loadBool(for: .hideSplash) ?? false
    // Mirrors UserDefaults — register(defaults:) seeds it true, so the box is checked unless
    // the user explicitly opts out here (or via the status-bar Community indicator later).
    @State private var communityLearning: Bool = AppSettings.defaults.bool(forKey: AppSettings.Key.communityLearning.rawValue)

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private struct Pillar {
        let icon: String
        let title: String
        let subtitle: String
        let description: String
        let detail: String    // Extra text shown on hover
        let color: Color
    }

    private let pillars: [Pillar] = [
        Pillar(
            icon: "bolt.fill",
            title: "Speed Demon",
            subtitle: "Blink. Mark. Done.",
            description: "Fastest sub-exposure culling on macOS. GPU-stretched preview in milliseconds. Keyboard-driven workflow that leaves PixInsight Blink in the dust.",
            detail: "No more waiting for WBPP to load 500 subs just to check which ones are bad. Open a folder and start culling in under 2 seconds.",
            color: .orange
        ),
        Pillar(
            icon: "chart.xyaxis.line",
            title: "Data Nerd",
            subtitle: "Your Imaging History",
            description: "Track every frame you ever shot. Per-setup quality trends, cross-session statistics, convergence analysis. Frame History DB with interactive charts.",
            detail: "Finally see how your imaging improved over months. Compare setups, find your best nights, and know exactly when you have enough integration time.",
            color: .cyan
        ),
        Pillar(
            icon: "person.3.fill",
            title: "Community Learner",
            subtitle: "Learn Together",
            description: "Anonymized quality baselines from the community. See how your setup compares. Calibration improves with every session — yours and everyone's.",
            detail: "Your RASA at f/2.2 produces different metrics than an RC at f/8. Community baselines mean the app learns what's normal for YOUR exact setup.",
            color: .green
        ),
        Pillar(
            icon: "gearshape.2.fill",
            title: "Power User",
            subtitle: "The Full Toolbox",
            description: "SmartCull 5-stage scoring, LightspeedStacker, Color Combine, AIsaac AI assistant, SSWEIGHT export, VIIRS Bortle mapping, and more.",
            detail: "From quick-stack previews in the field to full SHO color combines at home. One app replaces half your processing pipeline.",
            color: .purple
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AstroBlink & AIsaac")
                            .font(.system(size: 24, weight: .bold))
                        Text("Fast visual culling for astrophotography sessions")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                Text("v\(version) (Build \(build))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Section headline
            Text("4 reasons to use AstroBlink")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 10)

            // 4 pillar cards
            HStack(spacing: 14) {
                ForEach(Array(pillars.enumerated()), id: \.offset) { index, pillar in
                    pillarCard(pillar, index: index)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 16)

            // Divider
            Divider()
                .padding(.horizontal, 40)

            // Bottom section: author, links, buttons (from About view)
            VStack(spacing: 8) {
                // Author + tagline
                HStack(spacing: 6) {
                    Text("by joergsflow")
                        .font(.system(size: 11, weight: .medium))
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("Inspired by PixInsight's Blink & SubframeSelector")
                        .font(.system(size: 11).italic())
                        .foregroundColor(.secondary)
                }

                // Links
                HStack(spacing: 16) {
                    linkButton("GitHub", url: "https://github.com/joergs-git/AstroBlinkV2")
                    linkButton("Instagram", url: "https://www.instagram.com/joergsflow/")
                    linkButton("AstroBin", url: "https://app.astrobin.com/u/joergsflow#gallery")
                }
                .font(.system(size: 11))

                // Action buttons row
                HStack(spacing: 12) {
                    Button(action: shareApp) {
                        Label("Tell a Friend", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        ReleaseNotesWindowController.shared.show()
                    }) {
                        Label("What's New", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        if let url = URL(string: appStoreURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("App Store", systemImage: "arrow.down.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.system(size: 11))
            }
            .padding(.top, 10)

            Spacer()
                .frame(height: 12)

            // Get Started + checkboxes.
            // We deliberately do NOT use .borderedProminent here. SwiftUI's .borderedProminent
            // renders nearly invisibly inside an NSHostingView when the parent NSWindow is
            // inactive at first paint — even with NSApp.activate() and keyboardShortcut(.defaultAction)
            // applied — because its background fill follows the system controlActiveState.
            // Custom Button with an explicit accent-color background is immune to that and
            // also keeps the visual prominence on inactive show.
            VStack(spacing: 8) {
                // Telemetry disclosure with inline opt-out.
                // Default-on, but visible and one-click off so the user never has to hunt
                // for the toggle in Settings to disable it before first use.
                HStack(spacing: 6) {
                    Toggle(isOn: $communityLearning) {
                        Text("Share anonymous benchmarks and frame ratings to improve detection for everyone")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: communityLearning) { newValue in
                        AppSettings.save(newValue, for: .communityLearning)
                    }
                    Button(action: {
                        if let url = URL(string: "https://github.com/joergs-git/AstroBlinkV2/blob/main/PRIVACY.md") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Read the privacy policy on GitHub")
                }

                Button(action: dismissAction) {
                    Text("Get Started")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 90)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Toggle("Don't show on startup", isOn: $hideSplash)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .onChange(of: hideSplash) { newValue in
                        AppSettings.saveBool(newValue, for: .hideSplash)
                    }
            }
            .padding(.bottom, 16)
        }
        // Width pinned, height free so the bottom Get Started VStack can never be clipped
        // by an over-tight root frame even when the window is resized.
        .frame(minWidth: 720, idealWidth: 820, maxWidth: 1100,
               minHeight: 560, idealHeight: 640, maxHeight: 820)
    }

    private func pillarCard(_ pillar: Pillar, index: Int) -> some View {
        let isHovered = hoveredCard == index
        return VStack(spacing: 10) {
            Image(systemName: pillar.icon)
                .font(.system(size: 32))
                .foregroundColor(pillar.color)
                .frame(height: 40)

            Text(pillar.title)
                .font(.system(size: 15, weight: .bold))
                .multilineTextAlignment(.center)

            Text(pillar.subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(pillar.color)
                .multilineTextAlignment(.center)

            Text(pillar.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            // Detail text revealed on hover
            if isHovered {
                Text(pillar.detail)
                    .font(.system(size: 10, weight: .medium).italic())
                    .foregroundColor(pillar.color.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered
                    ? pillar.color.opacity(0.08)
                    : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? pillar.color.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: isHovered ? pillar.color.opacity(0.2) : .clear, radius: 8, y: 4)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            hoveredCard = hovering ? index : nil
        }
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Button(title) {
            if let link = URL(string: url) {
                NSWorkspace.shared.open(link)
            }
        }
        .buttonStyle(.link)
    }

    private func shareApp() {
        let shareText = "Check out AstroBlink — a fast astrophotography image triage & stacking tool for macOS with GPU-accelerated auto-stretch, quality scoring, and LightspeedStacker!\n\n\(appStoreURL)"
        let url = URL(string: appStoreURL)!
        let picker = NSSharingServicePicker(items: [shareText, url])
        if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}
