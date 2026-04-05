// v5.18.0
// VisualValidationWindow — Floating window showing mosaic wallpaper + VLM anomaly detection results.
// Zoomable mosaic panel (NSScrollView with magnification), anomaly list with jump-to, re-analyze button.

import SwiftUI
import AppKit

// MARK: - Window Controller

class VisualValidationWindowController: NSWindowController {
    static let shared = VisualValidationWindowController()

    private var currentModel: VisualValidationModel?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Visual Validation — Mosaic"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 450)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Show the mosaic preview window with pages and optional anomaly results.
    func show(
        pages: [MosaicPage],
        anomalies: [GroupKey: [AnomalyResult]] = [:],
        onJumpToFrame: @escaping (Int) -> Void,
        onMarkFrames: @escaping ([Int]) -> Void,
        onUnmarkFrames: (([Int]) -> Void)? = nil,
        onAnalyze: @escaping ([MosaicPage]) -> Void
    ) {
        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let nightMode = AppSettings.loadBool(for: .nightMode) == true
        let model = VisualValidationModel(
            pages: pages, anomalies: anomalies,
            onJumpToFrame: onJumpToFrame, onMarkFrames: onMarkFrames,
            onUnmarkFrames: onUnmarkFrames, onAnalyze: onAnalyze
        )
        currentModel = model
        let view = VisualValidationContentView(model: model, nightMode: nightMode)
            .environment(\.fontScale, savedScale)
        let hostingView = NSHostingView(rootView: view)
        window?.contentView = hostingView
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Update with anomaly results after analysis completes.
    func updateAnomalies(_ anomalies: [GroupKey: [AnomalyResult]]) {
        currentModel?.anomalies = anomalies
        currentModel?.isAnalyzing = false
        currentModel?.analysisProgress = ""
        currentModel?.rebuildAnnotatedImages()
    }

    /// Update analysis progress text.
    func updateAnalysisProgress(_ text: String) {
        currentModel?.analysisProgress = text
        currentModel?.isAnalyzing = true
    }

    /// Signal analysis failure.
    func analysisFinished(error: String?) {
        currentModel?.isAnalyzing = false
        if let err = error {
            currentModel?.analysisProgress = "Error: \(err)"
        } else {
            currentModel?.analysisProgress = ""
        }
    }
}

// MARK: - View Model

class VisualValidationModel: ObservableObject {
    let pages: [MosaicPage]
    @Published var anomalies: [GroupKey: [AnomalyResult]]
    @Published var selectedPageIndex: Int = 0
    @Published var isAnalyzing: Bool = false
    @Published var analysisProgress: String = ""
    @Published var zoomToFit: Bool = true
    @Published var showOverlay: Bool = true  // Toggle red anomaly overlay on/off
    @Published var showDeviation: Bool = false // Toggle deviation map view

    let onJumpToFrame: (Int) -> Void
    let onMarkFrames: ([Int]) -> Void
    let onUnmarkFrames: (([Int]) -> Void)?
    let onAnalyze: ([MosaicPage]) -> Void

    // Tracks which entry indices were marked by this window (for Unmark)
    @Published var markedEntryIndices: Set<Int> = []

    // Manually marked tiles (frame indices marked by clicking tiles in the mosaic)
    @Published var manuallyMarkedFrames: Set<Int> = []

    // Cached annotated images (regenerated when anomalies or manual marks change)
    @Published var annotatedImages: [Int: NSImage] = [:]  // pageIndex → annotated image

    init(pages: [MosaicPage], anomalies: [GroupKey: [AnomalyResult]],
         onJumpToFrame: @escaping (Int) -> Void, onMarkFrames: @escaping ([Int]) -> Void,
         onUnmarkFrames: (([Int]) -> Void)? = nil,
         onAnalyze: @escaping ([MosaicPage]) -> Void) {
        self.pages = pages
        self.anomalies = anomalies
        self.onJumpToFrame = onJumpToFrame
        self.onMarkFrames = onMarkFrames
        self.onUnmarkFrames = onUnmarkFrames
        self.onAnalyze = onAnalyze
    }

    /// Toggle mark on a tile by clicking it in the mosaic.
    func toggleTileMark(frameIndex: Int, entryIndex: Int) {
        if manuallyMarkedFrames.contains(frameIndex) {
            manuallyMarkedFrames.remove(frameIndex)
            markedEntryIndices.remove(entryIndex)
            onUnmarkFrames?([entryIndex])
        } else {
            manuallyMarkedFrames.insert(frameIndex)
            markedEntryIndices.insert(entryIndex)
            onMarkFrames([entryIndex])
        }
        rebuildAnnotatedImages()
    }

    /// Find which tile was clicked given a point in image coordinates.
    func tileAt(imagePoint: NSPoint) -> TileMetadata? {
        guard let page = currentPage else { return nil }
        let tileW = CGFloat(page.mosaicWidth) / CGFloat(page.gridCols)
        let tileH = CGFloat(page.mosaicHeight) / CGFloat(page.gridRows)

        // Image coordinates have origin at bottom-left (Core Graphics), but tiles are
        // laid out top-to-bottom chronologically with row 0 at the TOP.
        let col = Int(imagePoint.x / tileW)
        // Flip Y: bottom-left origin → top-left row index
        let rowFromBottom = Int(imagePoint.y / tileH)
        let rowFromTop = page.gridRows - 1 - rowFromBottom
        let tileIdx = rowFromTop * page.gridCols + col

        guard col >= 0, col < page.gridCols,
              rowFromBottom >= 0, rowFromBottom < page.gridRows,
              tileIdx >= 0, tileIdx < page.tiles.count else { return nil }
        return page.tiles[tileIdx]
    }

    var currentPage: MosaicPage? {
        guard pages.indices.contains(selectedPageIndex) else { return nil }
        return pages[selectedPageIndex]
    }

    var currentAnomalies: [AnomalyResult] {
        guard let page = currentPage else { return [] }
        return anomalies[page.group] ?? []
    }

    /// The display image: deviation map, annotated version, or original
    var currentDisplayImage: NSImage? {
        if showDeviation, let devImg = currentPage?.deviationNsImage {
            return devImg
        }
        if let annotated = annotatedImages[selectedPageIndex], showOverlay {
            return annotated
        }
        return currentPage?.nsImage
    }

    var totalAnomalyCount: Int {
        anomalies.values.reduce(0) { $0 + $1.count }
    }

    var allFlaggedEntryIndices: [Int] {
        var indices: [Int] = []
        for page in pages {
            let pageAnomalies = anomalies[page.group] ?? []
            let flaggedFrameNumbers = Set(pageAnomalies.map(\.frame))
            for tile in page.tiles where flaggedFrameNumbers.contains(tile.frameIndex) {
                indices.append(tile.entryIndex)
            }
        }
        return indices
    }

    /// Rebuild annotated mosaic images with red overlays (VLM) and blue overlays (manual marks)
    func rebuildAnnotatedImages() {
        for (idx, page) in pages.enumerated() {
            let pageAnomalies = anomalies[page.group] ?? []
            let pageManualMarks = manuallyMarkedFrames
            let hasAny = !pageAnomalies.isEmpty ||
                page.tiles.contains(where: { pageManualMarks.contains($0.frameIndex) })
            if !hasAny {
                annotatedImages.removeValue(forKey: idx)
                continue
            }
            guard let original = page.nsImage else { continue }
            annotatedImages[idx] = Self.drawOverlays(
                on: original, page: page, anomalies: pageAnomalies,
                manualMarks: pageManualMarks)
        }
    }

    /// Draw overlays on tiles: red for VLM anomalies, blue for manual marks.
    private static func drawOverlays(
        on image: NSImage, page: MosaicPage, anomalies: [AnomalyResult],
        manualMarks: Set<Int>
    ) -> NSImage {
        let flaggedFrames = Dictionary(grouping: anomalies, by: \.frame)
        let size = image.size
        let result = NSImage(size: size)

        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))

        let tileW = CGFloat(page.mosaicWidth) / CGFloat(page.gridCols)
        let tileH = CGFloat(page.mosaicHeight) / CGFloat(page.gridRows)

        for (tileIdx, tile) in page.tiles.enumerated() {
            let isVLMFlagged = flaggedFrames[tile.frameIndex] != nil
            let isManuallyMarked = manualMarks.contains(tile.frameIndex)
            guard isVLMFlagged || isManuallyMarked else { continue }

            let col = tileIdx % page.gridCols
            let row = page.gridRows - 1 - (tileIdx / page.gridCols)
            let tileRect = NSRect(x: CGFloat(col) * tileW, y: CGFloat(row) * tileH,
                                  width: tileW, height: tileH)
            let inset = tileRect.insetBy(dx: 2, dy: 2)

            if isVLMFlagged {
                // VLM anomaly: red border only (no fill, no cross — keep tiles visible)
                let anomalyList = flaggedFrames[tile.frameIndex]!

                NSColor.red.withAlphaComponent(0.9).setStroke()
                let borderPath = NSBezierPath(rect: inset)
                borderPath.lineWidth = 4
                borderPath.stroke()

                // Type + confidence label
                if let first = anomalyList.first {
                    let typeShort: String
                    switch first.type {
                    case "ICE_CRYSTAL": typeShort = "ICE"
                    case "DEW":         typeShort = "DEW"
                    case "CLOUD":       typeShort = "CLD"
                    case "SATELLITE":   typeShort = "SAT"
                    case "LIGHT_LEAK":  typeShort = "LEAK"
                    case "AMP_GLOW":    typeShort = "AMP"
                    case "FOCUS_SHIFT": typeShort = "FOC"
                    case "OBSTRUCTION": typeShort = "OBS"
                    default:            typeShort = "?"
                    }

                    let confidence = String(format: "%.0f%%", first.confidence * 100)
                    let label = "\(typeShort) \(confidence)"

                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .heavy),
                        .foregroundColor: NSColor.white
                    ]
                    let str = NSAttributedString(string: label, attributes: attrs)
                    let strSize = str.size()
                    let pillW = strSize.width + 16
                    let pillH = strSize.height + 8
                    let pillX = tileRect.midX - pillW / 2
                    let pillY = tileRect.midY - pillH / 2

                    let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)
                    NSColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 0.88).setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()

                    NSColor.white.withAlphaComponent(0.6).setStroke()
                    let pillBorder = NSBezierPath(roundedRect: pillRect.insetBy(dx: -1, dy: -1),
                                                  xRadius: 7, yRadius: 7)
                    pillBorder.lineWidth = 1
                    pillBorder.stroke()

                    str.draw(at: NSPoint(x: pillX + 8, y: pillY + 4))
                }
            } else if isManuallyMarked {
                // Manual mark: blue wash + border + checkmark icon
                NSColor.systemBlue.withAlphaComponent(0.12).setFill()
                NSBezierPath(rect: tileRect).fill()

                NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
                let borderPath = NSBezierPath(rect: inset)
                borderPath.lineWidth = 4
                borderPath.stroke()

                // Blue pill with "MARKED" label in top-right area
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                let str = NSAttributedString(string: "MARKED", attributes: attrs)
                let strSize = str.size()
                let pillW = strSize.width + 12
                let pillH = strSize.height + 6
                let pillX = tileRect.maxX - pillW - 8
                let pillY = tileRect.maxY - pillH - 8

                let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)
                NSColor.systemBlue.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 5, yRadius: 5).fill()
                str.draw(at: NSPoint(x: pillX + 6, y: pillY + 3))
            }
        }

        result.unlockFocus()
        return result
    }
}

// MARK: - Zoomable NSScrollView wrapper for NSImage

struct ZoomableImageView: NSViewRepresentable {
    let nsImage: NSImage?
    @Binding var zoomToFit: Bool
    var model: VisualValidationModel?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.autoresizingMask = [.width, .height]
        scrollView.backgroundColor = NSColor(white: 0.06, alpha: 1.0)
        scrollView.drawsBackground = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone  // Show at actual size, scrollView handles zoom
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.identifier = NSUserInterfaceItemIdentifier("mosaicImageView")
        scrollView.documentView = imageView

        // Double-click to toggle fit/actual size
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)

        // Single-click on tile to toggle mark
        let singleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleClick(_:)))
        singleClick.numberOfClicksRequired = 1
        singleClick.delaysPrimaryMouseButtonEvents = false
        doubleClick.delaysPrimaryMouseButtonEvents = false
        scrollView.addGestureRecognizer(singleClick)

        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        let coordinator = context.coordinator
        coordinator.model = model

        // Update image if changed
        if let img = nsImage, imageView.image !== img {
            imageView.image = img
            let imgSize = img.size
            imageView.frame = NSRect(origin: .zero, size: imgSize)
            coordinator.imageSize = imgSize

            // Fit to view on initial load
            if zoomToFit {
                DispatchQueue.main.async {
                    coordinator.fitToView()
                }
            }
        }

        // Handle fit-to-view toggle
        if zoomToFit && !coordinator.lastZoomToFit {
            DispatchQueue.main.async {
                coordinator.fitToView()
            }
        }
        coordinator.lastZoomToFit = zoomToFit
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator {
        let parent: ZoomableImageView
        weak var scrollView: NSScrollView?
        weak var model: VisualValidationModel?
        var imageSize: NSSize = .zero
        var lastZoomToFit: Bool = true

        init(parent: ZoomableImageView) { self.parent = parent }

        func fitToView() {
            guard let scrollView = scrollView,
                  imageSize.width > 0, imageSize.height > 0 else { return }
            let visibleSize = scrollView.contentSize
            let scaleX = visibleSize.width / imageSize.width
            let scaleY = visibleSize.height / imageSize.height
            let fitScale = min(scaleX, scaleY)
            scrollView.magnification = fitScale
            scrollView.documentView?.scroll(NSPoint(
                x: (imageSize.width * fitScale - visibleSize.width) / 2,
                y: (imageSize.height * fitScale - visibleSize.height) / 2
            ))
        }

        /// Convert a click in the scroll view to image coordinates, accounting for zoom and scroll.
        private func imagePoint(from recognizer: NSGestureRecognizer) -> NSPoint? {
            guard let scrollView = scrollView,
                  let documentView = scrollView.documentView else { return nil }
            // Get click in document view coordinates (accounts for scroll + zoom)
            let pointInDoc = recognizer.location(in: documentView)
            // Document view frame is the image at actual size
            guard pointInDoc.x >= 0, pointInDoc.y >= 0,
                  pointInDoc.x <= imageSize.width, pointInDoc.y <= imageSize.height else { return nil }
            return pointInDoc
        }

        @objc func handleSingleClick(_ recognizer: NSGestureRecognizer) {
            guard let model = model,
                  let imgPt = imagePoint(from: recognizer),
                  let tile = model.tileAt(imagePoint: imgPt) else { return }
            model.toggleTileMark(frameIndex: tile.frameIndex, entryIndex: tile.entryIndex)
        }

        @objc func handleDoubleClick(_ recognizer: NSGestureRecognizer) {
            guard let scrollView = scrollView,
                  imageSize.width > 0 else { return }
            let visibleSize = scrollView.contentSize
            let fitScale = min(visibleSize.width / imageSize.width,
                               visibleSize.height / imageSize.height)

            if abs(scrollView.magnification - fitScale) < 0.01 {
                let clickPoint = recognizer.location(in: scrollView)
                scrollView.setMagnification(1.0, centeredAt: clickPoint)
                parent.zoomToFit = false
            } else {
                scrollView.magnification = fitScale
                parent.zoomToFit = true
            }
        }
    }
}

// MARK: - Main Content View

struct VisualValidationContentView: View {
    @ObservedObject var model: VisualValidationModel
    let nightMode: Bool

    var body: some View {
        HSplitView {
            // Left: Zoomable mosaic image
            mosaicPanel
                .frame(minWidth: 450)

            // Right: Group picker + anomaly list + actions
            resultPanel
                .frame(minWidth: 220, maxWidth: 320)
        }
        .frame(minWidth: 700, minHeight: 450)
        .background(nightMode ? Color(white: 0.05) : Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Mosaic Panel

    private var mosaicPanel: some View {
        VStack(spacing: 0) {
            // Group tabs (if multiple groups)
            if model.pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.pages.enumerated()), id: \.offset) { idx, page in
                            groupTab(idx: idx, page: page)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .background(nightMode ? Color(white: 0.08) : Color(NSColor.controlBackgroundColor))
                Divider()
            }

            // Zoomable mosaic image via NSScrollView (annotated version when anomalies detected)
            // Click a tile to toggle mark/unmark on the corresponding frame
            ZoomableImageView(
                nsImage: model.currentDisplayImage,
                zoomToFit: $model.zoomToFit,
                model: model
            )

            // Zoom controls + status bar
            mosaicBottomBar
        }
    }

    private func groupTab(idx: Int, page: MosaicPage) -> some View {
        let isSelected = idx == model.selectedPageIndex
        let filter = page.group.filter.isEmpty ? "?" : page.group.filter
        let target = page.group.object.isEmpty ? "Unknown" : page.group.object
        let anomalyCount = (model.anomalies[page.group] ?? []).count
        let label = "\(target) / \(filter)"

        return Button(action: { model.selectedPageIndex = idx }) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                if anomalyCount > 0 {
                    Text("\(anomalyCount)")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected
                        ? (nightMode ? Color(white: 0.2) : Color.accentColor.opacity(0.15))
                        : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var mosaicBottomBar: some View {
        HStack(spacing: 12) {
            // Fit-to-view button
            Button(action: { model.zoomToFit = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Fit to window (double-click image to toggle)")

            // Deviation map toggle
            if model.currentPage?.deviationNsImage != nil {
                Button(action: { model.showDeviation.toggle() }) {
                    Image(systemName: model.showDeviation ? "waveform.circle.fill" : "waveform.circle")
                        .font(.caption)
                        .foregroundColor(model.showDeviation ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle deviation map (bright = differs from median)")
            }

            // Overlay toggle
            if model.totalAnomalyCount > 0 || !model.manuallyMarkedFrames.isEmpty {
                Button(action: { model.showOverlay.toggle() }) {
                    Image(systemName: model.showOverlay ? "eye.fill" : "eye.slash")
                        .font(.caption)
                        .foregroundColor(model.showOverlay ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle anomaly overlay (red markers)")
            }

            if let page = model.currentPage {
                Text("\(page.tiles.count) tiles, \(page.gridCols)x\(page.gridRows)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                let sizeKB = page.jpegData.count / 1024
                Text("\(page.mosaicWidth)x\(page.mosaicHeight)px — \(sizeKB)KB")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(nightMode ? Color(white: 0.08) : Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Result Panel

    private var resultPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundColor(.orange)
                Text("Anomalies")
                    .font(.headline)
                Spacer()
                if model.totalAnomalyCount > 0 {
                    Text("\(model.totalAnomalyCount) found")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(8)
            .background(nightMode ? Color(white: 0.08) : Color(NSColor.controlBackgroundColor))

            Divider()

            if model.isAnalyzing {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.analysisProgress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.currentAnomalies.isEmpty {
                VStack(spacing: 8) {
                    if model.anomalies.isEmpty && model.analysisProgress.isEmpty {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Ready to analyze")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("Click 'Analyze' to run VLM anomaly detection on the mosaic(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if !model.analysisProgress.isEmpty {
                        // Error state
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(model.analysisProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundColor(.green)
                        Text("No anomalies detected")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("All frames look consistent")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Anomaly list
                List {
                    ForEach(Array(model.currentAnomalies.enumerated()), id: \.offset) { _, anomaly in
                        anomalyRow(anomaly)
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Action buttons
            actionButtons
        }
    }

    private func anomalyRow(_ anomaly: AnomalyResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                anomalyTypeIcon(anomaly.type)
                Text("#\(anomaly.frame)")
                    .font(.callout.bold())
                Text(anomaly.type.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Text(String(format: "%.0f%%", anomaly.confidence * 100))
                    .font(.caption)
                    .foregroundColor(anomaly.confidence > 0.8 ? .red : .orange)
            }
            Text(anomaly.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
            if let note = anomaly.temporalNote {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let page = model.currentPage,
               let tile = page.tiles.first(where: { $0.frameIndex == anomaly.frame }) {
                model.onJumpToFrame(tile.entryIndex)
            }
        }
    }

    @ViewBuilder
    private func anomalyTypeIcon(_ type: String) -> some View {
        switch type {
        case "ICE_CRYSTAL":  Image(systemName: "snowflake").foregroundColor(.cyan)
        case "DEW":          Image(systemName: "drop.fill").foregroundColor(.blue)
        case "CLOUD":        Image(systemName: "cloud.fill").foregroundColor(.gray)
        case "LIGHT_LEAK":   Image(systemName: "light.max").foregroundColor(.yellow)
        case "SATELLITE":    Image(systemName: "line.diagonal").foregroundColor(.red)
        case "AMP_GLOW":     Image(systemName: "thermometer.sun.fill").foregroundColor(.orange)
        case "FOCUS_SHIFT":  Image(systemName: "circle.dashed").foregroundColor(.purple)
        case "OBSTRUCTION":  Image(systemName: "moon.circle.fill").foregroundColor(.brown)
        default:             Image(systemName: "questionmark.circle").foregroundColor(.secondary)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Analyze / Re-analyze button
            Button(action: {
                model.isAnalyzing = true
                model.analysisProgress = "Starting analysis..."
                model.onAnalyze(model.pages)
            }) {
                Label(model.anomalies.isEmpty ? "Analyze" : "Re-analyze",
                      systemImage: "sparkle.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(model.isAnalyzing)

            if !model.currentAnomalies.isEmpty {
                Button(action: {
                    let flagged = model.allFlaggedEntryIndices
                    model.onMarkFrames(flagged)
                    model.markedEntryIndices.formUnion(flagged)
                }) {
                    Label("Mark Flagged", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            if !model.markedEntryIndices.isEmpty {
                Button(action: {
                    let toUnmark = Array(model.markedEntryIndices)
                    model.onUnmarkFrames?(toUnmark)
                    model.markedEntryIndices.removeAll()
                }) {
                    Label("Unmark", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            // Save mosaic JPEG
            Button(action: saveMosaic) {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .help("Save mosaic as JPEG")
        }
        .padding(8)
    }

    private func saveMosaic() {
        guard let page = model.currentPage else { return }
        let panel = NSSavePanel()
        let filter = page.group.filter.isEmpty ? "mosaic" : page.group.filter
        let target = page.group.object.isEmpty ? "session" : page.group.object.replacingOccurrences(of: " ", with: "_")
        panel.nameFieldStringValue = "AstroBlink_Mosaic_\(target)_\(filter).jpg"
        panel.allowedContentTypes = [.jpeg]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? page.jpegData.write(to: url)
            }
        }
    }
}

// FontScaleKey environment key defined in AppSettings.swift — reused here via .environment(\.fontScale)
