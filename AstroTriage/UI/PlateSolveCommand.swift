// PlateSolveCommand — the user-facing flow for "Plate Solve Frames…".
//
// Shaped after GoldenSetExporter.runInteractive: a single entry point that checks
// preconditions, asks once, and does the work off the main thread. Results are presented by
// PlateSolveResultWindowController as a per-frame table — the outcome is comparative and
// needs scanning, which an alert cannot do.
//
// v6.9.0 — first increment: FITS only.

import AppKit

enum PlateSolveCommand {

    /// Entry point from the Window menu and from the file-list context menu. Main thread.
    ///
    /// - Parameter entries: the frames to solve. Pass nil (the menu command) to use the
    ///   highlighted rows, or the whole session when nothing is highlighted. The context menu
    ///   passes its own resolution of clicked-row-vs-selection.
    @MainActor
    static func runInteractive(viewModel: TriageViewModel, entries: [ImageEntry]? = nil) {
        // --- Is there anything to solve? ---
        let explicit = entries
        let selection = viewModel.selectedEntries
        let candidates = explicit ?? (selection.isEmpty ? viewModel.images : selection)
        guard !candidates.isEmpty else {
            alert("No frames loaded",
                  "Open a session first. Plate solving runs on the highlighted frames, or on "
                  + "the whole session when nothing is highlighted.")
            return
        }

        // --- Is ASTAP usable? Explains where to look before asking for the grant. ---
        let readiness = ASTAPLocator.shared.readinessRequestingPermissionIfNeeded()
        guard case .ready(let binary, let database) = readiness else {
            alert("Plate solving unavailable", readiness.explanation)
            return
        }

        // --- What would actually run? ---
        let supported = candidates.filter {
            ASTAPSolver.supportedExtensions.contains($0.url.pathExtension.lowercased())
        }
        let unsupported = candidates.count - supported.count
        let alreadySolved = supported.filter { WCSSolution(existingOn: $0) != nil }
        let unsolved = supported.count - alreadySolved.count

        guard !supported.isEmpty else {
            alert("Nothing to solve",
                  "None of the \(candidates.count) selected frames is a format the solver "
                  + "can read. Supported: FITS and XISF.")
            return
        }

        // --- ONE dialog. Scope and confirmation are the same decision; asking twice (first
        //     "re-solve the existing ones?", then "really solve?") was just a second gate on
        //     the answer already given. The buttons carry the scope. ---
        let scope: String
        if explicit != nil {
            scope = candidates.count == 1 ? "the selected frame" : "the selected frames"
        } else {
            scope = selection.isEmpty ? "the session" : "the highlighted frames"
        }

        var detail = ""
        if !alreadySolved.isEmpty {
            detail += "\(alreadySolved.count) of the \(supported.count) FITS frames in \(scope) "
                    + "already carry a plate solve. Re-solving them is a CHECK: AstroBlink "
                    + "compares each new solution against the stored one and flags any that "
                    + "disagree — a stale or misidentified solve shows up as a large centre "
                    + "offset.\n\n"
        } else {
            detail += "\(unsolved) frame(s) in \(scope) will be solved with ASTAP.\n\n"
        }
        if unsupported > 0 {
            detail += "\(unsupported) frame(s) in an unsupported format will be skipped — "
                    + "the solver reads FITS and XISF.\n\n"
        }
        detail += "Nothing is written yet: when the run finishes you can look at the results "
                + "and choose what to save."

        let buttons: [String]
        let title: String
        if alreadySolved.isEmpty {
            title = "Plate solve \(unsolved) frame(s)?"
            buttons = ["Solve", "Cancel"]
        } else if unsolved == 0 {
            title = "All \(alreadySolved.count) frame(s) already have a plate solve"
            buttons = ["Re-solve and Compare", "Cancel"]
        } else {
            title = "Plate solve \(supported.count) frame(s)?"
            buttons = ["Solve All and Compare (\(supported.count))",
                       "Only Unsolved (\(unsolved))",
                       "Cancel"]
        }

        let choice = ask(title, detail, buttons: buttons)
        let includeAlreadySolved: Bool
        if alreadySolved.isEmpty {
            guard choice == 0 else { return }
            includeAlreadySolved = false
        } else if unsolved == 0 {
            guard choice == 0 else { return }
            includeAlreadySolved = true
        } else {
            switch choice {
            case 0: includeAlreadySolved = true
            case 1: includeAlreadySolved = false
            default: return
            }
        }

        let work = includeAlreadySolved ? supported : supported.filter { WCSSolution(existingOn: $0) == nil }
        guard !work.isEmpty else {
            alert("Nothing to solve", "All selected FITS frames already carry a plate solve.")
            return
        }

        // --- Run off the main thread; the database scope must outlive every child process. ---
        viewModel.statusMessage = "Plate solving 0/\(work.count)…"
        let engine = PlateSolveEngine()

        // A status-bar line is too easy to miss on a run that takes minutes and shows nothing.
        PlateSolveProgressWindowController.shared.show(total: work.count) {
            engine.cancel()
        }

        Task.detached(priority: .userInitiated) {
            var report = engine.solve(
                entries: work,
                binary: binary,
                database: database,
                skipAlreadySolved: false,     // the partition above already decided this
                progress: { done, total, filename in
                    Task { @MainActor in
                        viewModel.statusMessage = "Plate solving \(done)/\(total)…"
                        PlateSolveProgressWindowController.shared
                            .update(completed: done, total: total, filename: filename)
                    }
                }
            )

            let finished = report
            await MainActor.run {
                PlateSolveProgressWindowController.shared.dismiss()
                ASTAPLocator.shared.releaseDatabase()
                viewModel.applyPlateSolveResults(finished)
                presentResults(finished,
                               unsupportedCount: unsupported,
                               viewModel: viewModel,
                               engine: engine)
            }
        }
    }

    // MARK: - Results

    /// Show the result table and wire up saving. The save decision belongs HERE, after the
    /// run: before it there is nothing to base it on, and "only the changed ones" cannot even
    /// be expressed until the comparison exists.
    ///
    /// Writing needs a writable session root. Reconstructed common-ancestor URLs carry no
    /// security scope — the NAS failure fixed in 6.5.2 — so the proven rescue is used, but
    /// only when the user actually asks to save.
    @MainActor
    private static func presentResults(_ report: PlateSolveReport,
                                       unsupportedCount: Int,
                                       viewModel: TriageViewModel,
                                       engine: PlateSolveEngine) {

        let canSave = !report.solved.isEmpty && viewModel.sessionRootURL != nil

        PlateSolveResultWindowController.shared.show(
            report: report,
            unsupportedCount: unsupportedCount,
            onSelectFrame: { id in
                let found = viewModel.navigateToEntry(id: id)
                if found {
                    // The result panel floats above the main window, so the selection change
                    // can happen out of sight. Say so in the status bar, and make sure the
                    // main window is actually the one behind the panel.
                    viewModel.statusMessage = "Showing \(viewModel.selectedImage?.filename ?? "frame")"
                    bringMainWindowForward()
                }
                return found
            },
            onSave: canSave ? { scope, writeObjectName in
                guard let root = viewModel.ensureWritableSessionRoot() else {
                    alert("Cannot write to the session folder",
                          "Nothing was saved. The solutions still apply to this session.")
                    return report
                }
                viewModel.statusMessage = "Writing WCS into files…"
                PlateSolveProgressWindowController.shared.show(total: 0, onCancel: {})
                PlateSolveProgressWindowController.shared.showWriting()
                // Off the main thread: writeBack copies, writes and verifies every file.
                var updated = report
                await Task.detached(priority: .userInitiated) {
                    engine.writeBack(&updated,
                                     sessionRoot: root,
                                     scope: scope,
                                     writeObjectName: writeObjectName)
                }.value
                PlateSolveProgressWindowController.shared.dismiss()
                viewModel.statusMessage = updated.headline
                return updated
            } : nil
        )
    }

    /// Order the main session window in front of the other normal-level windows, without
    /// stealing focus from the floating result panel the user is clicking in.
    ///
    /// Identified by exclusion rather than by title: the title carries the version string and
    /// would go stale on every release.
    @MainActor
    private static func bringMainWindowForward() {
        let utilityTitles: Set<String> = [
            "Plate Solve Results", "AIsaac's AstroBlink", "Golden Set Coverage",
            "Astrofile Locations", "Frame History", "Target Catalog"
        ]
        let main = NSApp.windows.first { window in
            window.isVisible
                && window.level == .normal
                && window.styleMask.contains(.titled)
                && !utilityTitles.contains(window.title)
        }
        main?.orderFront(nil)
    }

    // MARK: - Dialog helpers

    @MainActor
    private static func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Returns the index of the chosen button.
    @MainActor
    private static func ask(_ title: String, _ body: String, buttons: [String]) -> Int {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        for button in buttons { a.addButton(withTitle: button) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
