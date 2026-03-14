// v3.2.0
import SwiftUI

// Global keyboard event handler for navigation and triage shortcuts
// Uses NSEvent.addLocalMonitorForEvents for key repeat support
struct KeyboardHandler {

    static func install(viewModel: TriageViewModel) -> Any? {
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't intercept if a text field is focused
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView {
                return event
            }

            let handled = handleKeyEvent(event, viewModel: viewModel)
            if handled {
                // Reclaim table focus so selection highlight stays visible
                // and subsequent key events work without needing a mouse click
                ensureTableFocus()
            }
            return handled ? nil : event
        }
    }

    // Give the NSTableView first responder status so keyboard navigation
    // works regardless of what the user last clicked (sliders, buttons, etc.)
    private static func ensureTableFocus() {
        guard let window = NSApp.keyWindow,
              let tableView = findTableView() else { return }
        if window.firstResponder !== tableView {
            window.makeFirstResponder(tableView)
        }
    }

    static func remove(monitor: Any?) {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private static func handleKeyEvent(_ event: NSEvent, viewModel: TriageViewModel) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Function keys (Page Up/Down, Home, End, arrows) have .function flag set —
        // treat .function alone as "no modifier" for these navigation keys
        let noModifiers = modifiers.isEmpty || modifiers == .function

        switch event.keyCode {
        case 123: // Left arrow
            if noModifiers {
                Task { @MainActor in viewModel.navigatePrevious() }
                return true
            }

        case 124: // Right arrow
            if noModifiers {
                Task { @MainActor in viewModel.navigateNext() }
                return true
            }

        case 49: // Space — toggle pre-delete on selected rows
            if modifiers.isEmpty {
                Task { @MainActor in
                    if let tableView = findTableView() {
                        let selectedRows = tableView.selectedRowIndexes
                        guard !selectedRows.isEmpty else { return }

                        // Map visible table rows to real image indices
                        let isFiltered = viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty
                        if isFiltered {
                            let visible = viewModel.visibleImages
                            var realIndices = IndexSet()
                            for row in selectedRows where row < visible.count {
                                if let realIdx = viewModel.images.firstIndex(where: { $0.url == visible[row].url }) {
                                    realIndices.insert(realIdx)
                                }
                            }
                            if !realIndices.isEmpty {
                                viewModel.togglePreDeleteForRows(realIndices)
                            }
                        } else if selectedRows.count > 1 {
                            viewModel.togglePreDeleteForRows(selectedRows)
                        } else if let row = selectedRows.first, row < viewModel.images.count {
                            viewModel.togglePreDelete(at: row)
                        }
                    } else {
                        viewModel.togglePreDelete()
                    }
                }
                return true
            }

        case 51: // Backspace (Delete key)
            // Cmd+Backspace: Move marked files to PRE-DELETE folder
            if modifiers == .command {
                Task { @MainActor in viewModel.moveMarkedToPreDelete() }
                return true
            }

        case 116: // Page Up — jump to first image
            if noModifiers {
                Task { @MainActor in viewModel.navigateToFirst() }
                return true
            }

        case 121: // Page Down — jump to last image
            if noModifiers {
                Task { @MainActor in viewModel.navigateToLast() }
                return true
            }

        case 115: // Home — jump to first image
            if noModifiers {
                Task { @MainActor in viewModel.navigateToFirst() }
                return true
            }

        case 119: // End — jump to last image
            if noModifiers {
                Task { @MainActor in viewModel.navigateToLast() }
                return true
            }

        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers else { return false }

        // K: Toggle skip-marked during navigation
        if modifiers.isEmpty, chars == "k" {
            Task { @MainActor in viewModel.toggleSkipMarked() }
            return true
        }

        // H: Cycle view filter — all → hide marked → only marked → all
        if modifiers.isEmpty, chars == "h" {
            Task { @MainActor in viewModel.cycleViewFilter() }
            return true
        }

        // I: Toggle header inspector side panel
        if modifiers.isEmpty, chars == "i" {
            Task { @MainActor in viewModel.toggleHeaderInspector() }
            return true
        }

        // N: Toggle night mode (red-on-black for dark-adapted vision)
        if modifiers.isEmpty, chars == "n" {
            Task { @MainActor in viewModel.toggleNightMode() }
            return true
        }

        // D: Toggle debayer for OSC images
        if modifiers.isEmpty, chars == "d" {
            Task { @MainActor in viewModel.toggleDebayer() }
            return true
        }

        // C: Compare with Best (open side-by-side comparison with best frame in group)
        if modifiers.isEmpty, chars == "c" {
            Task { @MainActor in viewModel.compareWithBest() }
            return true
        }

        // S: Toggle Lock STF (freeze exact stretch params from current image)
        if modifiers.isEmpty, chars == "s" {
            Task { @MainActor in viewModel.toggleLockSTF() }
            return true
        }

        // Cmd+O: Open folder
        if modifiers == .command, chars == "o" {
            Task { @MainActor in viewModel.openFolder() }
            return true
        }

        // Cmd+M: Move marked files to user-selected folder
        if modifiers == .command, chars == "m" {
            Task { @MainActor in viewModel.moveMarkedToFolder() }
            return true
        }

        // Cmd+Z: Undo last pre-delete
        if modifiers == .command, chars == "z" {
            Task { @MainActor in viewModel.undoPreDelete() }
            return true
        }

        // +/= key: Zoom in by 20% (re-focus table after zoom so arrow keys keep working)
        if modifiers.isEmpty, (chars == "+" || chars == "=") {
            Task { @MainActor in
                viewModel.zoomIn()
                ensureTableFocus()
            }
            return true
        }

        // - key: Zoom out by 20%
        if modifiers.isEmpty, chars == "-" {
            Task { @MainActor in
                viewModel.zoomOut()
                ensureTableFocus()
            }
            return true
        }

        // 0 key: Reset zoom to fit-to-view
        if modifiers.isEmpty, chars == "0" {
            Task { @MainActor in
                viewModel.resetZoom()
                ensureTableFocus()
            }
            return true
        }

        return false
    }

    // Find the NSTableView in the key window's view hierarchy
    private static func findTableView() -> NSTableView? {
        guard let window = NSApp.keyWindow else { return nil }
        return findTableViewIn(view: window.contentView)
    }

    private static func findTableViewIn(view: NSView?) -> NSTableView? {
        guard let view = view else { return nil }
        // Only match the file list table, not inspector or other NSTableViews
        if let tableView = view as? NSTableView,
           tableView.identifier == NSUserInterfaceItemIdentifier("fileListTable") {
            return tableView
        }
        for subview in view.subviews {
            if let found = findTableViewIn(view: subview) {
                return found
            }
        }
        return nil
    }
}
