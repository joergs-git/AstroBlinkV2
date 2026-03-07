// v0.6.0
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

        // Tag the container so we can find the MTKView in updateNSView
        context.coordinator.mtkView = mtkView

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let mtkView = context.coordinator.mtkView,
              let renderer = mtkView.metalRenderer else { return }

        if let decoded = viewModel.currentDecodedImage {
            // Full-res path: set raw image for compute + display
            // Pass Bayer pattern for auto-debayer of OSC images
            let bayerPattern = viewModel.selectedImage?.bayerPattern
            renderer.setImage(decoded, in: mtkView, bayerPattern: bayerPattern)
        } else if viewModel.images.isEmpty {
            // No session loaded: clear display
            renderer.clearImage(in: mtkView)
        }
        // Otherwise: a cached preview is being rendered directly via setPreview(),
        // don't interfere by calling clearImage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        weak var mtkView: ZoomableMTKView?
    }
}

// Custom MTKView subclass: Photoshop-style zoom interaction
// Click on image → drag right to zoom in, drag left to zoom out
// Release → zoom level and pan position persist for all further images
// Double-click → reset to fit-to-view
class ZoomableMTKView: MTKView {
    // Strong reference — this view owns the renderer
    var metalRenderer: MetalRenderer?

    // Zoom interaction state
    private var isZoomDragging = false
    private var zoomAnchorView: NSPoint = .zero
    private var zoomStartScale: CGFloat = 1.0
    private var zoomStartPan: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

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
        window?.makeFirstResponder(self)

        guard let renderer = metalRenderer else { return }

        if event.clickCount == 2 {
            renderer.resetZoom()
            needsDisplay = true
            return
        }

        // Start zoom drag: record anchor and current state
        isZoomDragging = true
        zoomAnchorView = convert(event.locationInWindow, from: nil)
        zoomStartScale = renderer.zoomScale
        zoomStartPan = renderer.panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard isZoomDragging, let renderer = metalRenderer else { return }

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
    }

    override func mouseUp(with event: NSEvent) {
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
    }
}
