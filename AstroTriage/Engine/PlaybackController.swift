// Auto-blink playback controller — owns the timer, the index list, and the
// current position. Doesn't know about ImageEntry or visibility filters; the
// owner (TriageViewModel) builds the index list and is notified via onAdvance
// when it's time to switch to the next frame.
//
// Extracted from TriageViewModel as the first slice toward smaller, more
// focused state holders. Keeps `isPlaying` and `delaySeconds` as @Published
// so SwiftUI bindings (Play/Pause toggle, delay slider) can drive it directly
// once the owner exposes the controller; for now the owner mirrors them.
import Foundation

@MainActor
final class PlaybackController: ObservableObject {

    /// Active playback flag. Mirrors timer state. SwiftUI views bind to this
    /// (or to the matching @Published mirror on the owning view model).
    @Published var isPlaying: Bool = false

    /// Seconds between frame advances. Picked up on the next scheduled fire,
    /// so changing this mid-playback adapts smoothly without restarting.
    @Published var delaySeconds: Double = 0.1

    /// Called when the timer advances to the next frame. The Int is the
    /// owner-provided index into the original array — the controller is
    /// agnostic to what that index points at.
    var onAdvance: ((Int) -> Void)?

    private var timer: Timer?
    private(set) var indices: [Int] = []
    private(set) var position: Int = 0

    /// Begin auto-blinking through the given index list.
    /// `startAt` selects the initial position inside the list (use the index
    /// into `indices`, not the original array index).
    func start(indices: [Int], startAt position: Int = 0) {
        guard !indices.isEmpty else { return }
        self.indices = indices
        self.position = max(0, min(position, indices.count - 1))
        isPlaying = true
        scheduleNext()
    }

    /// Stop the timer and clear all playback state.
    func stop() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        indices = []
        position = 0
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advance() }
        }
    }

    private func advance() {
        guard isPlaying, !indices.isEmpty else { return }
        position = (position + 1) % indices.count
        onAdvance?(indices[position])
        scheduleNext()
    }
}
