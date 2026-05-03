// v2.2.0
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        tableView.identifier = NSUserInterfaceItemIdentifier("fileListTable")
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.autoresizingMask = [.width, .height]

        // Load persisted visible columns, or use defaults
        let savedVisibleIds = AppSettings.loadStrings(for: .visibleColumns)
        var visibleIds: Set<String> = savedVisibleIds.map { Set($0) }
            ?? Set(ColumnDefinition.allColumns.filter(\.isDefaultVisible).map(\.identifier))

        // Auto-migrate: when new columns are added with isDefaultVisible=true, they should
        // appear for existing users too. Merge any default-visible columns not yet in the
        // saved set (tracked via sentinel key to avoid re-adding after user hides them).
        if savedVisibleIds != nil {
            let seenDefaults = Set(AppSettings.loadStrings(for: .seenDefaultColumns) ?? [])
            let currentDefaults = Set(ColumnDefinition.allColumns.filter(\.isDefaultVisible).map(\.identifier))
            let newDefaults = currentDefaults.subtracting(seenDefaults)
            if !newDefaults.isEmpty {
                visibleIds.formUnion(newDefaults)
                AppSettings.saveStrings(Array(visibleIds), for: .visibleColumns)
                AppSettings.saveStrings(Array(currentDefaults), for: .seenDefaultColumns)
            }
        } else {
            // First-run user: record current defaults as seen
            let currentDefaults = Set(ColumnDefinition.allColumns.filter(\.isDefaultVisible).map(\.identifier))
            AppSettings.saveStrings(Array(currentDefaults), for: .seenDefaultColumns)
        }

        // Configure columns based on ColumnDefinition (respecting saved visibility)
        for colDef in ColumnDefinition.allColumns where visibleIds.contains(colDef.identifier) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colDef.identifier))
            column.title = colDef.title
            column.headerToolTip = ColumnDefinition.headerToolTip(for: colDef.identifier)
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
        tableView.doubleAction = #selector(Coordinator.tableViewDoubleClick(_:))
        tableView.target = context.coordinator

        // Right-click context menu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        // Column header right-click menu for show/hide columns (alphabetical)
        let headerMenu = NSMenu(title: "Columns")
        let hideableColumns = ColumnDefinition.allColumns
            .filter(\.isHideable)
            .sorted { ($0.title.isEmpty ? $0.identifier : $0.title) < ($1.title.isEmpty ? $1.identifier : $1.title) }
        for colDef in hideableColumns {
            let item = NSMenuItem(
                title: colDef.title.isEmpty ? colDef.identifier : colDef.title,
                action: #selector(Coordinator.toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.target = context.coordinator
            item.representedObject = colDef.identifier
            item.state = visibleIds.contains(colDef.identifier) ? .on : .off
            headerMenu.addItem(item)
        }
        tableView.headerView?.menu = headerMenu

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

        // Track font scale changes — update row height and force reload
        let fontScaleChanged = coordinator.lastFontScale != viewModel.fontScale
        coordinator.lastFontScale = viewModel.fontScale

        // Update the displayed images snapshot: apply hide/show-only-marked + column filter
        let isFiltered = viewModel.hideMarked || viewModel.showOnlyMarked || !viewModel.filterText.isEmpty
        coordinator.displayedImages = isFiltered ? viewModel.visibleImages : viewModel.images
        coordinator.cachedURLs = Set(coordinator.displayedImages.filter { viewModel.isImageCached($0.url) }.map { $0.url })
        coordinator.rotatedURLs = Set(coordinator.displayedImages.filter { viewModel.shouldRotateForMeridian($0) }.map { $0.url })
        coordinator.updateMetricRanges()

        guard let tableView = coordinator.tableView else { return }

        // Apply pending column reorder (triggered after header enrichment for single/multi-object)
        if let newOrder = viewModel.pendingColumnOrder {
            viewModel.pendingColumnOrder = nil
            reorderTableColumns(tableView, to: newOrder)
            viewModel.applySortByColumnOrder(newOrder)
            coordinator.displayedImages = isFiltered ? viewModel.visibleImages : viewModel.images
            coordinator.updateMetricRanges()
            tableView.reloadData()
        }

        // Apply pending bulk column visibility change (Blind Curation enter/exit).
        // Persist only when NOT in blind mode, so the blind-set doesn't overwrite
        // the user's normal layout in AppSettings.
        if let newVisibility = viewModel.pendingColumnVisibility {
            viewModel.pendingColumnVisibility = nil
            applyColumnVisibility(to: tableView, visibleIds: newVisibility)
            if !viewModel.isBlindCurationMode {
                let visibleIds = tableView.tableColumns.map { $0.identifier.rawValue }
                AppSettings.saveStrings(visibleIds, for: .visibleColumns)
            }
            coordinator.displayedImages = isFiltered ? viewModel.visibleImages : viewModel.images
            coordinator.updateMetricRanges()
            tableView.reloadData()
        }

        // Re-sort after quality scores become available (once per session)
        // Always uses recommended order for sort (not saved column layout — that's visual only)
        if viewModel.needsQualityResort {
            viewModel.needsQualityResort = false
            let uniqueTargets = Set(viewModel.images.compactMap { $0.target?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let uniqueFilters = Set(viewModel.images.compactMap { $0.filter?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let order = ColumnDefinition.recommendedColumnOrder(
                isMultiObject: uniqueTargets.count > 1, isMultiFilter: uniqueFilters.count > 1
            )
            viewModel.applySortByColumnOrder(order)
            coordinator.displayedImages = isFiltered ? viewModel.visibleImages : viewModel.images
            coordinator.updateMetricRanges()
            tableView.reloadData()
        }

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

        // Apply font scale to row height
        if fontScaleChanged {
            tableView.rowHeight = round(22 * viewModel.fontScale)
        }

        let newCount = coordinator.displayedImages.count
        let currentCount = tableView.numberOfRows

        if currentCount != newCount || viewModel.needsTableRefresh || nightModeChanged || fontScaleChanged {
            // Detect initial load (table was empty, now has rows) to grab keyboard focus
            let wasEmpty = currentCount == 0

            // Re-snapshot images (sort may have changed order since top-of-function snapshot)
            coordinator.displayedImages = isFiltered ? viewModel.visibleImages : viewModel.images
            coordinator.updateMetricRanges()
            let newCountRefreshed = coordinator.displayedImages.count

            let forcesSingle = viewModel.needsForceSingleSelection

            // When row count is unchanged (soft refresh for cache checkmarks, quality icons, etc.),
            // only reload the currently visible rows to avoid scroll position disruption.
            // Full reloadData() during rapid arrow-key navigation causes visible stutter because
            // it destroys and rebuilds all cell views, resetting the scroll clip view.
            if currentCount == newCountRefreshed && !forcesSingle && !nightModeChanged {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                let visibleRange = tableView.rows(in: tableView.visibleRect)
                if visibleRange.length > 0 {
                    let visibleRows = IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length))
                    let allColumns = IndexSet(0..<tableView.numberOfColumns)
                    tableView.reloadData(forRowIndexes: visibleRows, columnIndexes: allColumns)
                    // Re-apply selection since reloadData clears it for reloaded rows
                    let selection = tableView.selectedRowIndexes
                    if !selection.isEmpty {
                        tableView.selectRowIndexes(selection, byExtendingSelection: false)
                    }
                }
                NSAnimationContext.endGrouping()
            } else {
                // Full reload needed: row count changed, force-single, or night mode toggle
                let savedSelection = forcesSingle ? IndexSet() : tableView.selectedRowIndexes
                let scrollView = tableView.enclosingScrollView
                let savedScrollOrigin = scrollView?.contentView.bounds.origin
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                tableView.reloadData()
                if forcesSingle { viewModel.needsForceSingleSelection = false }

                if !savedSelection.isEmpty && savedSelection.last! < newCountRefreshed {
                    tableView.selectRowIndexes(savedSelection, byExtendingSelection: false)
                }
                // Restore scroll position to prevent jump from full reload + re-select
                if let origin = savedScrollOrigin {
                    scrollView?.contentView.scroll(to: origin)
                    scrollView?.reflectScrolledClipView(scrollView!.contentView)
                }
                NSAnimationContext.endGrouping()
            }
            viewModel.needsTableRefresh = false

            // Handle programmatic multi-row selection from AIsaac
            if let highlightRows = viewModel.pendingHighlightRows {
                tableView.selectRowIndexes(highlightRows, byExtendingSelection: false)
                if let first = highlightRows.first {
                    tableView.scrollRowToVisible(first)
                }
                viewModel.pendingHighlightRows = nil
            }

            // After first load, make file list the first responder for arrow key navigation
            if wasEmpty && newCount > 0 {
                tableView.window?.makeFirstResponder(tableView)
            }
        }

        // Scroll to top on new session load
        if viewModel.needsScrollToTop {
            viewModel.needsScrollToTop = false
            if newCount > 0 {
                tableView.scrollRowToVisible(0)
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }

        // Sync selection from viewModel — map to visible index when filtering.
        // Disable scroll animation during programmatic changes to prevent flicker
        // when holding arrow keys (rapid key repeat fights NSTableView's scroll animation).
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        if isFiltered {
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
                if currentSelection.count <= 1 {
                    if !currentSelection.contains(desiredIndex) {
                        tableView.selectRowIndexes(IndexSet(integer: desiredIndex), byExtendingSelection: false)
                        tableView.scrollRowToVisible(desiredIndex)
                    }
                }
            }
        }
        NSAnimationContext.endGrouping()
    }

    // Reorder existing table columns to match the given order (without adding/removing columns)
    private func reorderTableColumns(_ tableView: NSTableView, to order: [String]) {
        let currentIds = tableView.tableColumns.map { $0.identifier.rawValue }
        // Build a position map from the desired order
        var positionMap: [String: Int] = [:]
        for (i, id) in order.enumerated() {
            positionMap[id] = i
        }
        // Sort current column indices by desired position
        let sortedIds = currentIds.sorted { a, b in
            (positionMap[a] ?? Int.max) < (positionMap[b] ?? Int.max)
        }
        // Move columns to their new positions
        for (targetIndex, id) in sortedIds.enumerated() {
            if let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) {
                if currentIndex != targetIndex {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        }
    }

    /// Bulk column-visibility change: remove columns not in `visibleIds`, add
    /// any missing columns from the definition, and resync header-menu checkmarks.
    /// Used by Blind Curation enter/exit to swap the visible column set atomically
    /// instead of calling toggleColumnVisibility per column.
    private func applyColumnVisibility(to tableView: NSTableView, visibleIds: Set<String>) {
        // Remove columns not in the target set
        let columnsToRemove = tableView.tableColumns.filter { !visibleIds.contains($0.identifier.rawValue) }
        for col in columnsToRemove {
            tableView.removeTableColumn(col)
        }

        // Add missing columns in the order they appear in ColumnDefinition.allColumns
        // (preserves the canonical left-to-right order for the blind set)
        let existingIds = Set(tableView.tableColumns.map { $0.identifier.rawValue })
        for colDef in ColumnDefinition.allColumns
            where visibleIds.contains(colDef.identifier) && !existingIds.contains(colDef.identifier) {
            let identifier = NSUserInterfaceItemIdentifier(colDef.identifier)
            let column = NSTableColumn(identifier: identifier)
            column.title = colDef.title
            column.headerToolTip = ColumnDefinition.headerToolTip(for: colDef.identifier)
            column.width = colDef.defaultWidth
            column.minWidth = colDef.minWidth
            if colDef.identifier == "marked" {
                column.maxWidth = 28
                column.resizingMask = []
            } else {
                column.sortDescriptorPrototype = NSSortDescriptor(key: colDef.identifier, ascending: true)
                column.resizingMask = colDef.identifier == "filename"
                    ? [.autoresizingMask, .userResizingMask]
                    : .userResizingMask
            }
            tableView.addTableColumn(column)
        }

        // Resync header right-click menu checkmarks
        if let headerMenu = tableView.headerView?.menu {
            for item in headerMenu.items {
                if let colId = item.representedObject as? String {
                    item.state = visibleIds.contains(colId) ? .on : .off
                }
            }
        }
    }

}

// Custom row view that draws a muted selection highlight instead of bright blue
// Fixes red-on-blue readability issue for marked rows
class TriageRowView: NSTableRowView {
    var isNightMode: Bool = false

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            if isNightMode {
                NSColor(calibratedRed: 0.25, green: 0.0, blue: 0.0, alpha: 1.0).setFill()
            } else {
                // Darker muted blue that contrasts well with both red and white text
                NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.45, alpha: 1.0).setFill()
            }
            dirtyRect.fill()
        }
    }
}
