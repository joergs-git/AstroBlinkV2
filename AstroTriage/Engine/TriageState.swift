// Selection / filter / column-state holder extracted from TriageViewModel.
//
// The plan in launch-readiness-2026-05.md flagged this slice as the
// riskiest because it touches @Published storage that SwiftUI bindings
// depend on. The pragmatic resolution: keep TriageViewModel as the
// observed object the views bind to, but factor the storage for the
// pure UI state (selection, hide/skip/show-only filters, column-order
// hints, quality-resort flag) onto this class. The view model exposes
// forwarding computed properties of the same name, and forwards the
// sub-object's `objectWillChange` so views observing the view model
// repaint when state changes.
//
// Properties that have a SwiftUI `$viewModel.foo` projection binding
// (currently only `filterText`) intentionally stay on TriageViewModel
// because computed properties cannot expose a Binding-projection. If
// a future change needs to move filterText too, the call site can
// switch to `Binding(get:set:)` or a `@Published` mirror.
//
// Final slice of Patch 2.
import Foundation
import Combine

@MainActor
final class TriageState: ObservableObject {

    /// Selected row in the file table. -1 = nothing selected.
    @Published var selectedIndex: Int = -1

    /// Hide marked-for-deletion frames from the file list (UI filter).
    @Published var hideMarked: Bool = false

    /// Inverted view: show ONLY marked frames (e.g. to review what'll be deleted).
    @Published var showOnlyMarked: Bool = false

    /// Skip marked frames during arrow-key navigation.
    @Published var skipMarked: Bool = false

    /// Pending column order set after session-overview-driven auto-reorder.
    /// Consumed by FileListView.updateNSView and cleared after applying.
    @Published var pendingColumnOrder: [String]?

    /// Pending column visibility set in / out of Blind Curation mode.
    /// Consumed by FileListView.updateNSView and cleared after applying.
    @Published var pendingColumnVisibility: Set<String>?

    /// Flag consumed by FileListView when quality scores update — triggers a
    /// re-sort by the current column order. Set by recomputeQualityScores
    /// and reset by the table coordinator after applying.
    @Published var needsQualityResort: Bool = false
}
