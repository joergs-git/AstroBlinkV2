// v3.2.0
import SwiftUI
import MetalKit

// NSViewRepresentable wrapping MTKView for Metal-rendered image display
// Supports Photoshop-style zoom: click and drag right/left to zoom in/out
struct ImageViewerView: NSViewRepresentable {
    @ObservedObject var viewModel: TriageViewModel
    @Binding var renderer: MetalRenderer?

    func makeNSView(context: Context) -> NSView {
        // Plain container view — NOT NSScrollView which intercepts mouse events
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizingMask = [.width, .height]

        let mtkView = ZoomableMTKView()
        mtkView.wantsLayer = true
        mtkView.layer?.backgroundColor = NSColor.black.cgColor
        mtkView.autoresizingMask = [.width, .height]
        mtkView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mtkView)
        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: container.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if let metalRenderer = MetalRenderer(mtkView: mtkView) {
            mtkView.metalRenderer = metalRenderer
            DispatchQueue.main.async {
                self.renderer = metalRenderer
            }
        }

        // Zoom percentage overlay (bottom-right corner)
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        mtkView.zoomLabel = label

        // ── Floating viewer overlay (top-left) ──
        // Filter letter (very large, semi-transparent) → time (medium) → mini-map.
        // All overlays are layered ABOVE the MTKView but marked to ignore mouse
        // events so zoom/pan interaction on the image continues to work through
        // them. Visibility is driven by viewModel.showViewerOverlay in updateNSView.
        let overlay = ViewerOverlayContainer()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = !viewModel.showViewerOverlay
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            overlay.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.5),
        ])
        context.coordinator.overlay = overlay

        // Live viewport indicator — MTKView fires onViewportChanged after every
        // zoom / pan change. Weak capture so the overlay can't keep the MTKView
        // alive if the view hierarchy goes away first.
        mtkView.onViewportChanged = { [weak overlay] normRect in
            overlay?.updateViewportIndicator(normalizedRect: normRect)
        }

        // Tag the container so we can find the MTKView in updateNSView
        context.coordinator.mtkView = mtkView

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let mtkView = context.coordinator.mtkView,
              let renderer = mtkView.metalRenderer else { return }

        // Keep zoom overlay current (image changes affect fitScale)
        mtkView.updateZoomLabel()

        if let decoded = viewModel.currentDecodedImage {
            // Full-res path: set raw image for compute + display
            // Only pass Bayer pattern when debayer is enabled — otherwise show mono
            let bayerPattern = viewModel.debayerEnabled ? viewModel.selectedImage?.bayerPattern : nil
            renderer.setImage(decoded, in: mtkView, bayerPattern: bayerPattern,
                              targetBackground: viewModel.stretchStrength)
        } else if viewModel.images.isEmpty {
            // No session loaded: clear display
            renderer.clearImage(in: mtkView)
        }
        // Otherwise: a cached preview is being rendered directly via setPreview(),
        // don't interfere by calling clearImage

        // Refresh the floating overlay (filter letter, time, mini-map) from the
        // currently selected image. Cheap — labels are just NSTextField updates
        // and the mini-map only re-renders when the source URL actually changes.
        context.coordinator.overlay?.apply(
            isVisible: viewModel.showViewerOverlay,
            entry: viewModel.selectedImage,
            renderer: renderer
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        weak var mtkView: ZoomableMTKView?
        weak var overlay: ViewerOverlayContainer?
    }
}

// MARK: - Floating viewer overlay (top-left)
//
// Lives above the MTKView in the same container. Layout in viewport space so
// zoom/pan do not move it. Three stacked pieces:
//   • Filter letter — very large, bold, semi-transparent
//   • Time (HH:MM:SS) — smaller, same colour as the filter letter
//   • Mini-map NSImageView — ~200pt max side, aspect-preserving
//
// Mouse events are ignored so the MTKView underneath continues to receive
// click-drag zoom + Option-drag pan uninterrupted.
final class ViewerOverlayContainer: NSView {

    private let filterLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 68, weight: .heavy)  // 30% smaller than prior 96pt
        l.textColor = NSColor.white.withAlphaComponent(0.55)
        l.isBezeled = false
        l.drawsBackground = false
        l.isEditable = false
        l.alignment = .left
        l.lineBreakMode = .byClipping
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Time + observing-night date (e.g. "22:31:58  ·  2026-03-15"). Single
    /// label so the date naturally wraps with the time at small widths.
    private let timeLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        l.textColor = NSColor.white.withAlphaComponent(0.60)
        l.isBezeled = false
        l.drawsBackground = false
        l.isEditable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let thumbnailView: NSImageView = {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageFrameStyle = .none
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        v.layer?.borderWidth = 1
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Thin dashed rectangle laid over the mini-map to show which sub-region
    /// of the full image is currently visible in the main viewer. Updated on
    /// every zoom / pan change via ZoomableMTKView.onViewportChanged. Hidden
    /// when the whole image is visible (zoomScale ≤ 1.0 + centered pan).
    /// CALayer.borderWidth doesn't support dashes, so we back the view with
    /// a CAShapeLayer and stroke a dashed rectangle path.
    private let viewportIndicator: DashedRectView = {
        let v = DashedRectView()
        v.strokeColor = NSColor.white.withAlphaComponent(0.95)
        v.lineWidth = 1.5
        v.lineDashPattern = [2, 1]
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()
    /// Last received normalized viewport rect (0..1 in both axes, top-left
    /// origin). Cached so we can reposition the indicator when the thumbnail
    /// view's bounds change (e.g. aspect update after a new thumbnail loads).
    private var lastViewportRect: CGRect?

    /// Current user confidence rating mirrored from the image entry. Shown
    /// directly below the mini-map so the user can confirm their last 1/2/3
    /// keystroke stuck without glancing back at the file list. Uses the same
    /// "1-star = outline (garbage marker), 2-3 star = filled" convention as
    /// the file list's userConfidence column.
    private let ratingLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        l.textColor = NSColor.white.withAlphaComponent(0.75)
        l.isBezeled = false
        l.drawsBackground = false
        l.isEditable = false
        l.alignment = .left
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Used to decide whether the mini-map needs re-rendering on the next update.
    private var lastThumbnailKey: String?

    // Target longest-side dimension in points. Chosen to be visually "~5%" of
    // typical full-res sensor images without ever dominating the viewport.
    static let thumbnailMaxDimension: CGFloat = 200
    // Placeholder to reserve a fixed footprint while the Metal readback happens.
    private var thumbnailHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(filterLabel)
        addSubview(timeLabel)
        addSubview(thumbnailView)
        // Indicator is a child of the thumbnail so it naturally clips at the
        // thumbnail border and sits in the thumbnail's own coordinate space.
        // We set its frame manually (not via constraints) on every viewport
        // update — layout anchors would force a full layout pass per drag tick.
        thumbnailView.addSubview(viewportIndicator)
        addSubview(ratingLabel)
        let thumbH = thumbnailView.heightAnchor.constraint(equalToConstant: Self.thumbnailMaxDimension)
        self.thumbnailHeightConstraint = thumbH
        NSLayoutConstraint.activate([
            filterLabel.topAnchor.constraint(equalTo: topAnchor),
            filterLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            timeLabel.topAnchor.constraint(equalTo: filterLabel.bottomAnchor, constant: -4),
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            thumbnailView.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 10),
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnailView.widthAnchor.constraint(lessThanOrEqualToConstant: Self.thumbnailMaxDimension),
            thumbH,

            ratingLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 8),
            ratingLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            ratingLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ratingLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // Let every mouse event fall through to the MTKView underneath so zoom / pan
    // continue to work even when the overlay covers the click point.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Update the mini-map viewport indicator from a normalized visible rect
    /// (0..1 in both axes, top-left origin). Hides the indicator when the
    /// whole image is visible — drawing a border around the full thumbnail
    /// adds visual noise with no information.
    func updateViewportIndicator(normalizedRect: CGRect) {
        lastViewportRect = normalizedRect
        repositionViewportIndicator()
    }

    private func repositionViewportIndicator() {
        guard let norm = lastViewportRect else { viewportIndicator.isHidden = true; return }

        // Full-image viewport → hide (no cropping happening).
        let fullImage = norm.width > 0.995 && norm.height > 0.995
        if fullImage {
            viewportIndicator.isHidden = true
            return
        }

        let tb = thumbnailView.bounds
        guard tb.width > 0, tb.height > 0 else { viewportIndicator.isHidden = true; return }

        // AppKit uses bottom-left origin for view coordinates; the normalized
        // rect uses top-left (image space), so flip Y.
        let x = norm.minX * tb.width
        let y = tb.height - (norm.maxY * tb.height)
        let w = norm.width * tb.width
        let h = norm.height * tb.height
        viewportIndicator.frame = CGRect(x: x, y: y, width: w, height: h).integral
        viewportIndicator.isHidden = false
    }

    /// Update contents for the currently selected frame. Cheap when the same
    /// frame is re-applied — the mini-map only regenerates when the source URL
    /// or texture identity changes.
    func apply(isVisible: Bool, entry: ImageEntry?, renderer: MetalRenderer?) {
        self.isHidden = !isVisible
        guard isVisible, let entry = entry else {
            filterLabel.stringValue = ""
            timeLabel.stringValue = ""
            thumbnailView.image = nil
            ratingLabel.attributedStringValue = NSAttributedString(string: "")
            lastThumbnailKey = nil
            return
        }

        // Filter: prefer the full name as-shown in the UI (e.g. "Ha", "L", "OIII")
        // and render it big. A single-letter fallback handles unknown/empty values.
        let filterText: String = {
            let f = (entry.filter ?? "").trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? "—" : f
        }()
        filterLabel.stringValue = filterText

        // Time · observing-night date — e.g. "22:31:58  ·  2026-03-15". The
        // observing-night convention (ImageEntry.observingNight) handles the
        // post-midnight "the 03:00 frame belongs to the previous evening" case.
        let timeStr = (entry.time ?? "").trimmingCharacters(in: .whitespaces)
        let nightStr = (entry.observingNight ?? "").trimmingCharacters(in: .whitespaces)
        switch (timeStr.isEmpty, nightStr.isEmpty) {
        case (false, false): timeLabel.stringValue = "\(timeStr)  ·  \(nightStr)"
        case (false, true):  timeLabel.stringValue = timeStr
        case (true,  false): timeLabel.stringValue = nightStr
        case (true,  true):  timeLabel.stringValue = ""
        }

        // Rating: mirror the file list convention — 1★ renders as outline (☆)
        // which flags the frame as garbage, 2/3★ render as filled (★). Unrated
        // (0) shows nothing rather than a muted placeholder so the overlay
        // stays visually calm until the user actually rates.
        ratingLabel.attributedStringValue = Self.ratingString(userConfidence: entry.userConfidence)

        // Mini-map: regenerate from renderer's current display texture only when
        // the frame (URL) actually changed. Metal readback is cheap from the
        // preview texture but we still avoid doing it on every redraw.
        let key = entry.url.path
        if key != lastThumbnailKey, let renderer = renderer,
           let thumb = renderer.renderThumbnail(maxDimension: Self.thumbnailMaxDimension) {
            thumbnailView.image = thumb
            // Adjust reserved height to the actual thumbnail aspect so we don't
            // leave a square placeholder on wide sensors.
            thumbnailHeightConstraint?.constant = thumb.size.height
            lastThumbnailKey = key
            // Re-layout the viewport indicator against the new thumbnail bounds
            // on the next runloop tick (AppKit needs a pass to update bounds).
            DispatchQueue.main.async { [weak self] in self?.repositionViewportIndicator() }
        } else if key != lastThumbnailKey {
            // New frame but renderer hasn't produced a displayable texture yet.
            // Clear the stale thumbnail so we don't associate it with the wrong frame.
            thumbnailView.image = nil
            lastThumbnailKey = nil
        }
    }

    /// Build the star-rating display string.
    /// - 0 (unrated) → empty
    /// - 1 star     → ☆ (outline, the "garbage" marker, matching the file list convention)
    /// - 2/3 stars  → ★★ / ★★★ (filled)
    /// Monochrome white so the overlay stays visually calm and doesn't compete
    /// with the filter letter.
    private static func ratingString(userConfidence: Int) -> NSAttributedString {
        guard (1...3).contains(userConfidence) else { return NSAttributedString(string: "") }
        let glyph: String = (userConfidence == 1) ? "☆"
            : String(repeating: "★", count: userConfidence)
        return NSAttributedString(string: glyph, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            .font: NSFont.systemFont(ofSize: 32, weight: .bold),
            .kern: 4,  // breathing room between glyphs
        ])
    }
}

// Custom MTKView subclass: Photoshop-style zoom interaction
// Click on image → drag right to zoom in, drag left to zoom out
// Release → zoom level and pan position persist for all further images
// Double-click → reset to fit-to-view
class ZoomableMTKView: MTKView {
    // Strong reference — this view owns the renderer
    var metalRenderer: MetalRenderer?

    // Zoom label overlay (bottom-right corner, shows true pixel zoom %)
    weak var zoomLabel: NSTextField?

    /// Notified whenever the zoom or pan state changes — used by the top-left
    /// viewer overlay to reposition its mini-map viewport indicator rectangle.
    /// The rect is in normalized image coordinates (0..1, top-left origin).
    /// A full-image rect `CGRect(x:0, y:0, width:1, height:1)` means nothing
    /// is cropped and the indicator should be hidden.
    var onViewportChanged: ((CGRect) -> Void)?

    // Zoom interaction state
    private var isZoomDragging = false
    private var zoomAnchorView: NSPoint = .zero
    private var zoomStartScale: CGFloat = 1.0
    private var zoomStartPan: CGPoint = .zero

    // Option+drag pan mode (like Photoshop hand tool)
    private var isPanDragging = false
    private var panDragStart: NSPoint = .zero
    private var panStartOffset: CGPoint = .zero

    /// Update the zoom percentage overlay. Shows true pixel zoom (fitScale × zoomScale).
    func updateZoomLabel() {
        guard let renderer = metalRenderer, let label = zoomLabel else { return }
        let fitScale = renderer.fitScale(viewBounds: bounds.size)
        let trueZoom = fitScale * renderer.zoomScale * 100
        if abs(renderer.zoomScale - 1.0) < 0.005 {
            label.stringValue = String(format: "Fit (%.0f%%)", trueZoom)
        } else {
            label.stringValue = String(format: "%.0f%%", trueZoom)
        }
        notifyViewportChanged()
    }

    /// Compute the visible-image sub-region in normalized image coords and
    /// forward it to the mini-map viewport indicator. See onViewportChanged.
    private func notifyViewportChanged() {
        guard let cb = onViewportChanged, let renderer = metalRenderer else { return }
        // Image pixel dimensions — prefer the decoded image; fall back to the
        // cached preview metadata which records the original (pre-bin) size.
        let imgW: CGFloat
        let imgH: CGFloat
        if let img = renderer.currentImage {
            imgW = CGFloat(img.width); imgH = CGFloat(img.height)
        } else if renderer.cachedPreviewWidth > 0, renderer.cachedPreviewHeight > 0 {
            imgW = CGFloat(renderer.cachedPreviewWidth)
            imgH = CGFloat(renderer.cachedPreviewHeight)
        } else {
            return
        }

        let viewW = bounds.width
        let viewH = bounds.height
        guard viewW > 0, viewH > 0, imgW > 0, imgH > 0 else { return }

        let fitScale = renderer.fitScale(viewBounds: bounds.size)
        let effScale = fitScale * renderer.zoomScale
        guard effScale > 0 else { return }

        // Visible fraction of the image along each axis. Clamp to 1.0 — when
        // zoomed out past fit-scale, the viewport shows letterbox bars, not
        // more of the image than exists.
        let fracW = min(1.0, viewW / (imgW * effScale))
        let fracH = min(1.0, viewH / (imgH * effScale))

        // Viewport center in normalized image coords (top-left origin).
        // Pan convention (cross-checked against MetalRenderer.renderQuad):
        //   • panOffset.x applied as `+panPxX / vW * 2` to NDC → positive
        //     panOffset.x shifts image RIGHT → viewport sees content LEFT of
        //     image center → centerX shifts < 0.5. Hence the `-` term.
        //   • panOffset.y applied as `-panPxY / vH * 2` to NDC → positive
        //     panOffset.y shifts image DOWN on screen (Metal NDC +Y is up)
        //     → viewport sees content ABOVE image center → in top-left-origin
        //     image coords centerY shifts < 0.5 too. Same `-` sign as X.
        var centerX = 0.5 - renderer.panOffset.x / (imgW * effScale)
        var centerY = 0.5 - renderer.panOffset.y / (imgH * effScale)

        // Clamp center so the indicator stays inside the thumbnail even if
        // the user has panned the image partially out of the view.
        let halfW = fracW / 2
        let halfH = fracH / 2
        centerX = min(1 - halfW, max(halfW, centerX))
        centerY = min(1 - halfH, max(halfH, centerY))

        let rect = CGRect(x: centerX - halfW, y: centerY - halfH,
                          width: fracW, height: fracH)
        cb(rect)
    }

    // Don't steal first responder from the table — keyboard handler uses
    // a local event monitor that works regardless of focus
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: - Photoshop-style click-drag zoom

    override func mouseDown(with event: NSEvent) {
        guard let renderer = metalRenderer else { return }

        if event.clickCount == 2 {
            renderer.resetZoom()
            needsDisplay = true
            updateZoomLabel()
            return
        }

        // Option+click: start pan drag (hand tool)
        if event.modifierFlags.contains(.option) {
            isPanDragging = true
            panDragStart = convert(event.locationInWindow, from: nil)
            panStartOffset = renderer.panOffset
            NSCursor.closedHand.set()
            return
        }

        // Start zoom drag: record anchor and current state
        isZoomDragging = true
        zoomAnchorView = convert(event.locationInWindow, from: nil)
        zoomStartScale = renderer.zoomScale
        zoomStartPan = renderer.panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer = metalRenderer else { return }

        // Spacebar+drag: pan the image
        if isPanDragging {
            let current = convert(event.locationInWindow, from: nil)
            renderer.panOffset.x = panStartOffset.x + (current.x - panDragStart.x)
            renderer.panOffset.y = panStartOffset.y + (current.y - panDragStart.y)
            needsDisplay = true
            // Also refresh the mini-map viewport indicator live (no zoom
            // change → zoom label stays the same, but notifyViewportChanged
            // fires from inside updateZoomLabel).
            updateZoomLabel()
            return
        }

        guard isZoomDragging else { return }

        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - zoomAnchorView.x

        // Horizontal drag controls zoom: right = zoom in, left = zoom out
        // ~200 pixels of drag = 2x zoom change
        let zoomFactor = pow(2.0, dx / 200.0)
        let newScale = max(0.1, min(50.0, zoomStartScale * zoomFactor))

        // Compute pan to keep the anchor pixel stationary during zoom
        let viewBounds = bounds.size
        let baseFit = renderer.fitScale(viewBounds: viewBounds)
        guard baseFit > 0 else { return }

        let oldEffective = baseFit * zoomStartScale
        let newEffective = baseFit * newScale

        // Anchor position relative to view center
        let relX = zoomAnchorView.x - viewBounds.width / 2.0
        let relY = zoomAnchorView.y - viewBounds.height / 2.0

        // Image-space coordinate under anchor at old zoom
        let imgX = (relX - zoomStartPan.x) / oldEffective
        let imgY = (relY + zoomStartPan.y) / oldEffective

        // New pan to keep that image point under the anchor
        renderer.panOffset.x = relX - imgX * newEffective
        renderer.panOffset.y = -(relY - imgY * newEffective)
        renderer.zoomScale = newScale

        needsDisplay = true
        updateZoomLabel()
    }

    override func mouseUp(with event: NSEvent) {
        if isPanDragging {
            isPanDragging = false
            NSCursor.arrow.set()
            return
        }
        isZoomDragging = false
    }

    // Scroll wheel: pan when zoomed in
    override func scrollWheel(with event: NSEvent) {
        guard let renderer = metalRenderer, renderer.zoomScale > 1.01 else {
            super.scrollWheel(with: event)
            return
        }

        renderer.panOffset.x += event.scrollingDeltaX
        renderer.panOffset.y += event.scrollingDeltaY
        needsDisplay = true
        updateZoomLabel()  // keep the mini-map viewport indicator in sync
        needsDisplay = true
    }

    // Trackpad pinch-to-zoom
    override func magnify(with event: NSEvent) {
        guard let renderer = metalRenderer else { return }

        let mouseInView = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        let oldScale = renderer.zoomScale
        let newScale = max(0.1, min(50.0, oldScale * factor))

        let viewBounds = bounds.size
        let baseFit = renderer.fitScale(viewBounds: viewBounds)
        guard baseFit > 0 else { return }

        let oldEffective = baseFit * oldScale
        let newEffective = baseFit * newScale

        let relX = mouseInView.x - viewBounds.width / 2.0
        let relY = mouseInView.y - viewBounds.height / 2.0

        let imgX = (relX - renderer.panOffset.x) / oldEffective
        let imgY = (relY + renderer.panOffset.y) / oldEffective

        renderer.panOffset.x = relX - imgX * newEffective
        renderer.panOffset.y = -(relY - imgY * newEffective)
        renderer.zoomScale = newScale

        needsDisplay = true
        updateZoomLabel()
    }
}

// MARK: - DashedRectView
//
// Small NSView subclass backed by a CAShapeLayer that strokes a dashed
// rectangle along its bounds. CALayer.borderWidth does not support dashes,
// so this is the minimum cost to get a dashed outline. The shape layer's
// path is rebuilt whenever bounds change (so resizing keeps the rect tight
// against the view edges).
final class DashedRectView: NSView {
    var strokeColor: NSColor = .white {
        didSet { shape.strokeColor = strokeColor.cgColor }
    }
    var lineWidth: CGFloat = 1.5 {
        didSet { shape.lineWidth = lineWidth; updatePath() }
    }
    /// [dash, gap, dash, gap, …] lengths in points. `[2, 1]` = 2pt on, 1pt off.
    var lineDashPattern: [NSNumber] = [2, 1] {
        didSet { shape.lineDashPattern = lineDashPattern }
    }

    private let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        shape.fillColor = NSColor.clear.cgColor
        shape.strokeColor = strokeColor.cgColor
        shape.lineWidth = lineWidth
        shape.lineDashPattern = lineDashPattern
        layer?.addSublayer(shape)
        updatePath()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        updatePath()
    }

    private func updatePath() {
        // Inset by half a line-width so the dashed stroke draws fully inside
        // the bounds rectangle (default stroke is centered on the path).
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        shape.frame = bounds
        shape.path = CGPath(rect: rect, transform: nil)
    }
}
