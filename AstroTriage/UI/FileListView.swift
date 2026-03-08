// v0.9.6
import SwiftUI
import AppKit

// NSViewRepresentable wrapping NSTableView for high-performance file list
// Supports multi-selection for bulk marking, column-order-based sorting,
// right-click context menu, night mode (red-on-black), and cache indicators
struct FileListView: NSViewRepresentable {
    @ObservedObject var viewModel: TriageViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.autoresizingMask = [.width, .height]

        // Configure columns based on ColumnDefinition
        for colDef in ColumnDefinition.allColumns where colDef.isDefaultVisible {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colDef.identifier))
            column.title = colDef.title
            column.width = colDef.defaultWidth
            column.minWidth = colDef.minWidth

            if colDef.identifier == "marked" {
                column.maxWidth = 28
                column.resizingMask = []
            } else {
                // Sort descriptor for click-to-toggle ascending/descending
                column.sortDescriptorPrototype = NSSortDescriptor(key: colDef.identifier, ascending: true)
                if colDef.identifier == "filename" {
                    column.resizingMask = [.autoresizingMask, .userResizingMask]
                } else {
                    column.resizingMask = .userResizingMask
                }
            }

            tableView.addTableColumn(column)
        }

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        // Right-click context menu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        // Observe column reorder to trigger sort-by-column-order
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: tableView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.viewModel = viewModel

        // Track night mode for cell coloring
        let nightModeChanged = coordinator.lastNightMode != viewModel.nightMode
        coordinator.lastNightMode = viewModel.nightMode

        // Update the displayed images snapshot and cached URLs (main actor context)
        coordinator.displayedImages = viewModel.hideMarked ? viewModel.visibleImages : viewModel.images
        coordinator.cachedURLs = Set(coordinator.displayedImages.filter { viewModel.isImageCached($0.url) }.map { $0.url })

        guard let tableView = coordinator.tableView else { return }

        // Apply night mode to table background
        if viewModel.nightMode {
            tableView.backgroundColor = .black
            tableView.usesAlternatingRowBackgroundColors = false
            scrollView.backgroundColor = .black
            scrollView.drawsBackground = true
        } else {
            tableView.backgroundColor = .controlBackgroundColor
            tableView.usesAlternatingRowBackgroundColors = true
            scrollView.backgroundColor = .controlBackgroundColor
            scrollView.drawsBackground = true
        }

        let newCount = coordinator.displayedImages.count
        let currentCount = tableView.numberOfRows

        if currentCount != newCount || viewModel.needsTableRefresh || nightModeChanged {
            // Preserve current multi-selection across reload
            let savedSelection = tableView.selectedRowIndexes
            tableView.reloadData()
            viewModel.needsTableRefresh = false

            // Restore saved selection if still valid
            if !savedSelection.isEmpty && savedSelection.last! < newCount {
                tableView.selectRowIndexes(savedSelection, byExtendingSelection: false)
            }
        }

        // Sync selection from viewModel only for single-select navigation
        if viewModel.hideMarked {
            if let selectedURL = viewModel.selectedImage?.url,
               let visibleIdx = viewModel.visibleImages.firstIndex(where: { $0.url == selectedURL }) {
                let currentSelection = tableView.selectedRowIndexes
                if currentSelection.count <= 1 && !currentSelection.contains(visibleIdx) {
                    tableView.selectRowIndexes(IndexSet(integer: visibleIdx), byExtendingSelection: false)
                    tableView.scrollRowToVisible(visibleIdx)
                }
            }
        } else {
            let desiredIndex = viewModel.selectedIndex
            if desiredIndex >= 0, desiredIndex < newCount {
                let currentSelection = tableView.selectedRowIndexes
                if currentSelection.count <= 1 && !currentSelection.contains(desiredIndex) {
                    tableView.selectRowIndexes(IndexSet(integer: desiredIndex), byExtendingSelection: false)
                    tableView.scrollRowToVisible(desiredIndex)
                } else if currentSelection.count <= 1 {
                    tableView.scrollRowToVisible(desiredIndex)
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var viewModel: TriageViewModel
        weak var tableView: NSTableView?
        var lastNightMode: Bool = false

        init(viewModel: TriageViewModel) {
            self.viewModel = viewModel
        }

        // Snapshot of displayed images and cached URLs, updated from main actor in updateNSView
        var displayedImages: [ImageEntry] = []
        var cachedURLs: Set<URL> = []

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedImages.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let colId = tableColumn?.identifier.rawValue,
                  row < displayedImages.count else { return nil }

            let entry = displayedImages[row]
            let isNight = viewModel.nightMode

            if colId == "marked" {
                return makeCheckboxCell(for: row, isMarked: entry.isMarkedForDeletion, in: tableView)
            }

            // For the filename column, prepend a cache indicator
            if colId == "filename" {
                return makeFilenameCellWithCacheIndicator(entry: entry, isNight: isNight, in: tableView)
            }

            // Regular text column
            let value = ColumnDefinition.value(for: colId, from: entry)
            let identifier = NSUserInterfaceItemIdentifier("Cell_\(colId)")
            let cellView: NSTableCellView

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cellView = reused
            } else {
                cellView = NSTableCellView()
                cellView.identifier = identifier
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                textField.isSelectable = true
                cellView.addSubview(textField)
                cellView.textField = textField

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                    textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                    textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            }

            cellView.textField?.stringValue = value

            // Night mode: red text; otherwise: red for marked, normal for rest
            if isNight {
                cellView.textField?.textColor = entry.isMarkedForDeletion
                    ? NSColor(red: 0.5, green: 0, blue: 0, alpha: 1)
                    : NSColor.systemRed
            } else {
                cellView.textField?.textColor = entry.isMarkedForDeletion ? .systemRed : .labelColor
            }

            return cellView
        }

        // Filename cell with tiny cache indicator checkmark
        private func makeFilenameCellWithCacheIndicator(entry: ImageEntry, isNight: Bool, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_filename_cached")
            let isCached = cachedURLs.contains(entry.url)

            let cellView: NSView
            let textField: NSTextField
            let indicator: NSTextField

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) {
                cellView = reused
                textField = reused.viewWithTag(100) as! NSTextField
                indicator = reused.viewWithTag(101) as! NSTextField
            } else {
                let container = NSView()
                container.identifier = identifier

                let ind = NSTextField(labelWithString: "")
                ind.translatesAutoresizingMaskIntoConstraints = false
                ind.font = .systemFont(ofSize: 9)
                ind.alignment = .center
                ind.tag = 101
                container.addSubview(ind)

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                tf.isSelectable = true
                tf.tag = 100
                container.addSubview(tf)

                NSLayoutConstraint.activate([
                    ind.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
                    ind.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    ind.widthAnchor.constraint(equalToConstant: 14),
                    tf.leadingAnchor.constraint(equalTo: ind.trailingAnchor, constant: 2),
                    tf.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])

                cellView = container
                textField = tf
                indicator = ind
            }

            textField.stringValue = entry.filename

            // Cache indicator
            if isCached {
                indicator.stringValue = "\u{2713}"  // Checkmark
                indicator.textColor = isNight ? NSColor(red: 0.4, green: 0, blue: 0, alpha: 1) : .systemGray
                indicator.toolTip = "Cached for instant display"
            } else {
                indicator.stringValue = ""
                indicator.toolTip = nil
            }

            // Night mode: red text
            if isNight {
                textField.textColor = entry.isMarkedForDeletion
                    ? NSColor(red: 0.5, green: 0, blue: 0, alpha: 1)
                    : NSColor.systemRed
            } else {
                textField.textColor = entry.isMarkedForDeletion ? .systemRed : .labelColor
            }

            return cellView
        }

        // Row background color for night mode
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            if viewModel.nightMode {
                let rowView = NSTableRowView()
                rowView.backgroundColor = row % 2 == 0
                    ? .black
                    : NSColor(red: 0.06, green: 0, blue: 0, alpha: 1)
                return rowView
            }
            return nil
        }

        private func makeCheckboxCell(for row: Int, isMarked: Bool, in tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("Cell_marked")

            if let reused = tableView.makeView(withIdentifier: identifier, owner: self),
               let button = reused.subviews.first as? NSButton {
                button.state = isMarked ? .on : .off
                button.tag = row
                return reused
            }

            let container = NSView()
            container.identifier = identifier

            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.state = isMarked ? .on : .off
            button.tag = row
            container.addSubview(button)

            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])

            return container
        }

        @objc private func checkboxToggled(_ sender: NSButton) {
            let row = sender.tag
            Task { @MainActor in
                if viewModel.hideMarked {
                    let visible = viewModel.visibleImages
                    guard row < visible.count else { return }
                    let url = visible[row].url
                    if let realIdx = viewModel.images.firstIndex(where: { $0.url == url }) {
                        viewModel.togglePreDelete(at: realIdx)
                    }
                } else {
                    viewModel.togglePreDelete(at: row)
                }
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRows = tableView.selectedRowIndexes

            if selectedRows.count == 1, let row = selectedRows.first {
                Task { @MainActor in
                    if viewModel.hideMarked {
                        let visible = viewModel.visibleImages
                        guard row < visible.count else { return }
                        let url = visible[row].url
                        if let realIdx = viewModel.images.firstIndex(where: { $0.url == url }) {
                            if realIdx != viewModel.selectedIndex {
                                viewModel.selectImage(at: realIdx)
                            }
                        }
                    } else if row != viewModel.selectedIndex {
                        viewModel.selectImage(at: row)
                    }
                }
            }
        }

        // MARK: - Right-Click Context Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()

            guard let tableView = tableView else { return }
            let clickedRow = tableView.clickedRow
            guard clickedRow >= 0, clickedRow < displayedImages.count else { return }

            let entry = displayedImages[clickedRow]

            let copyFilename = NSMenuItem(title: "Copy Filename", action: #selector(copyFilename(_:)), keyEquivalent: "")
            copyFilename.target = self
            copyFilename.representedObject = entry.filename
            menu.addItem(copyFilename)

            let copyPath = NSMenuItem(title: "Copy File Path", action: #selector(copyFilePath(_:)), keyEquivalent: "")
            copyPath.target = self
            copyPath.representedObject = entry.url.deletingLastPathComponent().path
            menu.addItem(copyPath)

            let copyFullPath = NSMenuItem(title: "Copy Full Path + Filename", action: #selector(copyFullPath(_:)), keyEquivalent: "")
            copyFullPath.target = self
            copyFullPath.representedObject = entry.url.path
            menu.addItem(copyFullPath)

            menu.addItem(NSMenuItem.separator())

            // Mark/Unmark option
            let markTitle = entry.isMarkedForDeletion ? "Unmark" : "Mark for Deletion"
            let markItem = NSMenuItem(title: markTitle, action: #selector(toggleMarkFromMenu(_:)), keyEquivalent: "")
            markItem.target = self
            markItem.tag = clickedRow
            menu.addItem(markItem)
        }

        @objc private func copyFilename(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func copyFilePath(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func copyFullPath(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func toggleMarkFromMenu(_ sender: NSMenuItem) {
            let row = sender.tag
            Task { @MainActor in
                if viewModel.hideMarked {
                    let visible = viewModel.visibleImages
                    guard row < visible.count else { return }
                    let url = visible[row].url
                    if let realIdx = viewModel.images.firstIndex(where: { $0.url == url }) {
                        viewModel.togglePreDelete(at: realIdx)
                    }
                } else {
                    viewModel.togglePreDelete(at: row)
                }
            }
        }

        // MARK: - Column-Order Sorting

        @objc func columnDidMove(_ notification: Notification) {
            guard let tableView = tableView else { return }

            let columnIds = (0..<tableView.numberOfColumns).compactMap { i in
                tableView.tableColumns[i].identifier.rawValue
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.viewModel.applySortByColumnOrder(columnIds)
                tableView.reloadData()

                let idx = self.viewModel.selectedIndex
                if idx >= 0 && idx < self.viewModel.images.count {
                    tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    tableView.scrollRowToVisible(idx)
                }
            }
        }

        // MARK: - Click-to-Sort (ascending/descending toggle)

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let descriptors = tableView.sortDescriptors
            guard !descriptors.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.viewModel.applySortDescriptors(descriptors)
                tableView.reloadData()

                let idx = self.viewModel.selectedIndex
                if idx >= 0 && idx < self.viewModel.images.count {
                    tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    tableView.scrollRowToVisible(idx)
                }
            }
        }
    }
}
