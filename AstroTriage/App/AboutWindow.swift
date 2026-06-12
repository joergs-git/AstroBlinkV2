// About / splash window controller and the SwiftUI AboutView it hosts.
// Also owns showOnboarding() because the onboarding flow reuses the same
// NSWindow slot (only one transient app-info window can be open at a time).
import SwiftUI

// MARK: - Custom About / Splash Window

class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?
    private var splashClickMonitor: Any?
    private var splashDismissed = false

    func show(asSplash: Bool) {
        // If already visible, bring to front
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        splashDismissed = false
        let hostingView = NSHostingView(rootView: AboutView(
            dismissAction: { [weak self] in self?.close() },
            isSplash: asSplash
        ))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About AstroBlink & AIsaac"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        win.makeKeyAndOrderFront(nil)
        self.window = win

        // Splash mode: auto-dismiss on click or after 6 seconds
        if asSplash {
            splashClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                // Don't dismiss when clicking the "Don't show on startup" checkbox
                if let clickedView = event.window?.contentView?.hitTest(event.locationInWindow),
                   clickedView is NSButton {
                    return event
                }
                // Dismiss splash on any other click or key press.
                // Button/link click handlers fire before this monitor,
                // so links still work — splash just closes after.
                self?.dismissSplash()
                return event
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.dismissSplash()
            }
        }
    }

    private func dismissSplash() {
        guard !splashDismissed else { return }
        splashDismissed = true
        if let monitor = splashClickMonitor {
            NSEvent.removeMonitor(monitor)
            splashClickMonitor = nil
        }
        window?.close()
    }

    func close() {
        if let monitor = splashClickMonitor {
            NSEvent.removeMonitor(monitor)
            splashClickMonitor = nil
        }
        window?.close()
    }

    /// Show the first-launch onboarding with 4 marketing pillars.
    /// Non-dismissable — user must click "Get Started".
    func showOnboarding() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: OnboardingView(
            dismissAction: { [weak self] in
                AppSettings.saveBool(true, for: .hasSeenOnboarding)
                self?.close()
            }
        ))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            // Standard window chrome: title + close (red) + miniaturize (yellow) + zoom (green).
            // Resizable enables the green zoom button; min/max sizes below pin the practical range.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to AstroBlink"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 720, height: 560)
        win.maxSize = NSSize(width: 1100, height: 820)
        // Activate the app first so the onboarding window comes up KEY (active).
        // Otherwise if another app has focus at launch the window becomes visible but
        // inactive — and SwiftUI's .borderedProminent "Get Started" button renders
        // nearly invisible in inactive windows until the user clicks to focus it.
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - About View (SwiftUI)

struct AboutView: View {
    var dismissAction: (() -> Void)?
    var isSplash: Bool = false
    @State private var shareAnchor: NSPoint = .zero
    @State private var hideSplash: Bool = AppSettings.loadBool(for: .hideSplash) ?? false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            // App icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            // App name and version
            Text("AstroBlink & AIsaac")
                .font(.system(size: 22, weight: .bold))
            Text("v\(version) (Build \(build))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Tagline
            Text("Inspired by PixInsight's Blink & SubframeSelector")
                .font(.system(size: 11).italic())
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 20)

            // Author and links
            Text("by joergsflow")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 16) {
                linkButton("GitHub", url: "https://github.com/joergs-git/AstroBlinkV2")
                linkButton("Instagram", url: "https://www.instagram.com/joergsflow/")
                linkButton("AstroBin", url: "https://app.astrobin.com/u/joergsflow#gallery")
            }
            .font(.system(size: 11))

            Divider()
                .padding(.horizontal, 20)

            // More from joergsflow — cross-promotion to the sibling apps in
            // the toolkit. This window serves as BOTH the launch splash and
            // the About panel, so one placement covers both surfaces.
            VStack(spacing: 4) {
                Text("More from joergsflow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                otherAppRow("AstroSharper", platform: "macOS",
                            appStore: "https://apps.apple.com/app/id6778564449",
                            github: "https://github.com/joergs-git/AstroSharper")
                otherAppRow("AstroFileViewer", platform: "iPhone & iPad",
                            appStore: "https://apps.apple.com/app/id6760240080",
                            github: "https://github.com/joergs-git/AstroBlinkV2")
            }

            Divider()
                .padding(.horizontal, 20)

            // Action buttons — stacked vertically for readability
            VStack(spacing: 8) {
                Button(action: shareApp) {
                    Label("Tell a Friend", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 10) {
                    Button(action: {
                        dismissAction?()
                        ReleaseNotesWindowController.shared.show()
                    }) {
                        Label("What's New", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        dismissAction?()
                        if let url = URL(string: appStoreURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("App Store", systemImage: "arrow.down.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.system(size: 12))
            .padding(.top, 2)

            if isSplash {
                Toggle("Don't show on startup", isOn: $hideSplash)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .onChange(of: hideSplash) { _, newValue in
                        AppSettings.saveBool(newValue, for: .hideSplash)
                    }
            }

            Spacer()
                .frame(height: 4)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.horizontal, 24)
        .frame(width: 360)
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Button(title) {
            if let link = URL(string: url) {
                NSWorkspace.shared.open(link)
            }
        }
        .buttonStyle(.link)
    }

    /// One sibling-app row for the "More from joergsflow" cross-promotion:
    /// app name + platform, with App Store and GitHub links. Reuses the
    /// existing `linkButton` style for visual consistency.
    private func otherAppRow(_ name: String, platform: String, appStore: String, github: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11, weight: .medium))
            Text(platform).font(.system(size: 9)).foregroundColor(.secondary)
            Spacer(minLength: 6)
            linkButton("App Store", url: appStore)
            linkButton("GitHub", url: github)
        }
        .font(.system(size: 11))
    }

    private func shareApp() {
        let shareText = "Check out AstroBlink — a fast astrophotography image triage & stacking tool for macOS with GPU-accelerated auto-stretch, quality scoring, and LightspeedStacker!\n\n\(appStoreURL)"
        let url = URL(string: appStoreURL)!
        let picker = NSSharingServicePicker(items: [shareText, url])
        // Show the share picker anchored to the key window
        if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}
