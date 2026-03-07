// v0.9.4
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
            return handled ? nil : event
        }
    }

    static func remove(monitor: Any?) {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private static func handleKeyEvent(_ event: NSEvent, viewModel: TriageViewModel) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 123: // Left arrow
            if modifiers.isEmpty {
                Task { @MainActor in viewModel.navigatePrevious() }
                return true
            }

        case 124: // Right arrow
            if modifiers.isEmpty {
                Task { @MainActor in viewModel.navigateNext() }
                return true
            }

        case 49: // Space — toggle pre-delete on selected rows
            if modifiers.isEmpty {
                Task { @MainActor in
                    if let tableView = findTableView() {
                        let selectedRows = tableView.selectedRowIndexes
                        if selectedRows.count > 1 {
                            viewModel.togglePreDeleteForRows(selectedRows)
                        } else {
                            viewModel.togglePreDelete()
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

        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers else { return false }

        // S: Toggle stretch mode (auto <-> locked)
        if modifiers.isEmpty, chars == "s" {
            Task { @MainActor in viewModel.toggleStretchMode() }
            return true
        }

        // K: Toggle skip-marked during navigation
        if modifiers.isEmpty, chars == "k" {
            Task { @MainActor in viewModel.toggleSkipMarked() }
            return true
        }

        // H: Toggle hide-marked from file list
        if modifiers.isEmpty, chars == "h" {
            Task { @MainActor in viewModel.toggleHideMarked() }
            return true
        }

        // I: Toggle header inspector side panel
        if modifiers.isEmpty, chars == "i" {
            Task { @MainActor in viewModel.toggleHeaderInspector() }
            return true
        }

        // Cmd+O: Open folder
        if modifiers == .command, chars == "o" {
            Task { @MainActor in viewModel.openFolder() }
            return true
        }

        // Cmd+Z: Undo last pre-delete
        if modifiers == .command, chars == "z" {
            Task { @MainActor in viewModel.undoPreDelete() }
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
        if let tableView = view as? NSTableView { return tableView }
        for subview in view.subviews {
            if let found = findTableViewIn(view: subview) {
                return found
            }
        }
        return nil
    }
}
