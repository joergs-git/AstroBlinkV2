// CoffeeSupportDialog.swift
//
// Friendly, randomly-scheduled "buy me a coffee" prompt.
//
// Cadence (driven by AppSettings.Key.coffeeNextPromptAt vs. sessionCount):
//   - First prompt after a random offset of 10..100 sessions from install
//   - "Yes, sure!"   → opens browser, sets coffeeThanked=true → never shown again
//   - "No thanks"    → reschedules ~50 sessions out (with small jitter)
//   - "Maybe later"  → reschedules 2 sessions out (lightweight nudge)
//
// Design: small (~64pt) circular avatar of the developer + first-person copy.
// A real face raises donation conversion meaningfully versus an anonymous logo.

import SwiftUI
import AppKit

enum CoffeeSupportDialog {

    private static let supportURL = URL(string: "https://buymeacoffee.com/joergsflow")!

    /// Decide whether the dialog should fire on this session, then present it.
    /// Safe to call from anywhere on the main thread; returns immediately if not due.
    @MainActor
    static func presentIfDue(currentSessionCount: Int, nightMode: Bool) {
        // Bail if user already donated or explicitly opted out.
        if AppSettings.defaults.bool(forKey: AppSettings.Key.coffeeThanked.rawValue) {
            return
        }

        // First call: schedule the inaugural prompt at a random session in [10, 100].
        let key = AppSettings.Key.coffeeNextPromptAt.rawValue
        let scheduled = AppSettings.defaults.object(forKey: key) as? Int
        if scheduled == nil {
            let target = currentSessionCount + Int.random(in: 10...100)
            AppSettings.defaults.set(target, forKey: key)
            return
        }

        guard let due = scheduled, currentSessionCount >= due else { return }

        present(nightMode: nightMode)
    }

    /// Force-present (no scheduling check). Reserved for future "Support" menu action.
    @MainActor
    static func presentNow(nightMode: Bool) {
        present(nightMode: nightMode)
    }

    // MARK: - Presentation

    @MainActor
    private static func present(nightMode: Bool) {
        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0

        // Hold a strong reference to the window via a static — released when closed.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 456, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Support AstroBlinkV2"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        let view = CoffeeSupportView(
            nightMode: nightMode,
            onYes: {
                NSWorkspace.shared.open(supportURL)
                markThanked()
                window.close()
            },
            onNo: {
                snooze(by: Int.random(in: 50...60), markDone: false)
                window.close()
            },
            onLater: {
                snooze(by: 2, markDone: false)
                window.close()
            }
        )
        .environment(\.fontScale, savedScale)

        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Retain until closed so it doesn't get torn down mid-interaction.
        OpenWindows.coffee = window
    }

    // MARK: - State helpers

    private static func currentSessionCount() -> Int {
        AppSettings.defaults.object(forKey: AppSettings.Key.sessionCount.rawValue) as? Int ?? 0
    }

    private static func snooze(by sessions: Int, markDone: Bool) {
        let next = currentSessionCount() + max(1, sessions)
        AppSettings.defaults.set(next, forKey: AppSettings.Key.coffeeNextPromptAt.rawValue)
        if markDone {
            AppSettings.defaults.set(true, forKey: AppSettings.Key.coffeeThanked.rawValue)
        }
    }

    private static func markThanked() {
        AppSettings.defaults.set(true, forKey: AppSettings.Key.coffeeThanked.rawValue)
    }

    // Keep window alive while open.
    private enum OpenWindows {
        static var coffee: NSWindow?
    }
}

// MARK: - SwiftUI body

private struct CoffeeSupportView: View {
    let nightMode: Bool
    let onYes: () -> Void
    let onNo: () -> Void
    let onLater: () -> Void

    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    private var fg: Color { nightMode ? .red : .primary }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }
    private var bg: Color { nightMode ? .black : Color(NSColor.windowBackgroundColor) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Small circular portrait — kept intentionally compact.
            Image("JoergPortrait")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(fgDim.opacity(0.4), lineWidth: 1)
                )
                .opacity(nightMode ? 0.75 : 1.0)

            VStack(alignment: .leading, spacing: 8) {
                Text("Hi, I'm Jörg ☕")
                    .font(.system(size: fs(14), weight: .semibold))
                    .foregroundColor(fg)

                Text("I built AstroBlinkV2 in my spare time, between long imaging nights. If it's saved you some time or just like it, fancy buying me a coffee?")
                    .font(.system(size: fs(12)))
                    .foregroundColor(fg)
                    .fixedSize(horizontal: false, vertical: true)

                // Decorative coffee cup — sized ~3× the previous bottom-right badge (18 → 54pt).
                Text("☕")
                    .font(.system(size: 54))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button(action: onYes) {
                        Text("Yes, sure!")
                            .font(.system(size: fs(12), weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button(action: onLater) {
                        Text("Maybe later")
                            .font(.system(size: fs(12)))
                    }
                    .buttonStyle(.bordered)

                    Button(action: onNo) {
                        Text("No thanks")
                            .font(.system(size: fs(12)))
                            .foregroundColor(fgDim)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(18)
        .frame(width: 456, height: 280, alignment: .topLeading)
        .background(bg)
    }
}
