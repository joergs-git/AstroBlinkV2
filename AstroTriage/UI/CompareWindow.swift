// v3.12.0 — Side-by-side image comparison window
// "Compare with Best" opens the best-quality image from the same group (target + filter + exposure)
// next to the selected image. Zoom and pan are synchronized between both views.
import SwiftUI
import MetalKit

// MARK: - Shared zoom/pan state for synchronized views

class SyncedZoomState: ObservableObject {
    @Published var zoomScale: CGFloat = 3.0   // Start at 300% zoom (centered)
    @Published var panOffset: CGPoint = .zero

    func reset() {
        zoomScale = 1.0
        panOffset = .zero
    }
}

// MARK: - Compare Window Controller

enum CompareWindowController {

    /// Open a comparison window: best image (left) vs selected image (right)
    static func open(selectedEntry: ImageEntry, bestEntry: ImageEntry,
                     device: MTLDevice, nightMode: Bool, debayerEnabled: Bool) {
        let selectedURL = selectedEntry.decodingURL
        let bestURL = bestEntry.decodingURL
        let bayerSel = debayerEnabled ? selectedEntry.bayerPattern : nil
        let bayerBest = debayerEnabled ? bestEntry.bayerPattern : nil

        Task.detached(priority: .userInitiated) {
            // Decode both images in parallel
            async let decSel = ImageDecoder.decode(url: selectedURL, device: device)
            async let decBest = ImageDecoder.decode(url: bestURL, device: device)

            guard case .success(let selDecoded) = await decSel,
                  case .success(let bestDecoded) = await decBest else { return }

            // Debayer if OSC
            var selImg = selDecoded
            if let p = bayerSel, selDecoded.channelCount == 1 {
                if let d = ImagePreviewWindowController.debayerOnGPU(image: selDecoded, pattern: p, device: device) {
                    selImg = d
                }
            }
            var bestImg = bestDecoded
            if let p = bayerBest, bestDecoded.channelCount == 1 {
                if let d = ImagePreviewWindowController.debayerOnGPU(image: bestDecoded, pattern: p, device: device) {
                    bestImg = d
                }
            }

            // Compute STF from full-res, then bin + convert
            let selSTF = STFCalculator.calculate(from: selImg)
            let bestSTF = STFCalculator.calculate(from: bestImg)

            let selResult = ImagePreviewWindowController.binAndConvert(image: selImg)
            let bestResult = ImagePreviewWindowController.binAndConvert(image: bestImg)

            // Render both to textures
            let selTex = renderFloatToTexture(
                data: selResult.data, width: selResult.width, height: selResult.height,
                channelCount: selResult.channelCount, targetBackground: 0.25,
                precomputedSTF: selSTF, device: device
            )
            let bestTex = renderFloatToTexture(
                data: bestResult.data, width: bestResult.width, height: bestResult.height,
                channelCount: bestResult.channelCount, targetBackground: 0.25,
                precomputedSTF: bestSTF, device: device
            )

            guard let st = selTex, let bt = bestTex else { return }

            // Build labels with date/time info
            let bestDateTime = [bestEntry.date, bestEntry.time].compactMap { $0 }.joined(separator: " ")
            let selDateTime = [selectedEntry.date, selectedEntry.time].compactMap { $0 }.joined(separator: " ")
            let bestLabel = "Best — \(bestEntry.filename)\n\(bestDateTime)"
            let selLabel = "Selected — \(selectedEntry.filename)\n\(selDateTime)"

            await MainActor.run {
                let syncState = SyncedZoomState()
                let view = CompareView(
                    leftTexture: bt, rightTexture: st,
                    leftLabel: bestLabel,
                    rightLabel: selLabel,
                    syncState: syncState
                )
                let hostingView = NSHostingView(rootView: view)

                // Open maximized on the main screen
                let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let window = NSWindow(
                    contentRect: screenFrame,
                    styleMask: [.titled, .closable, .resizable, .miniaturizable],
                    backing: .buffered, defer: false
                )
                window.title = "Compare: \(selectedEntry.filename) vs Best"
                window.contentView = hostingView
                window.minSize = NSSize(width: 800, height: 400)
                window.isReleasedWhenClosed = false
                window.orderFront(nil)
            }
        }
    }
}

// MARK: - Compare View (side by side)

struct CompareView: View {
    let leftTexture: MTLTexture
    let rightTexture: MTLTexture
    let leftLabel: String
    let rightLabel: String
    @ObservedObject var syncState: SyncedZoomState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Left: Best image
                VStack(spacing: 0) {
                    SyncedZoomableView(texture: leftTexture, syncState: syncState)
                    Text(leftLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                }

                // Divider
                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 2)

                // Right: Selected image
                VStack(spacing: 0) {
                    SyncedZoomableView(texture: rightTexture, syncState: syncState)
                    Text(rightLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                }
            }

            // Controls bar
            HStack {
                Button(action: { syncState.reset() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Zoom")
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Reset zoom and pan to fit-to-view")

                Spacer()

                Text("Click-drag to zoom • Scroll to pan • Double-click to reset")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .background(Color.black)
    }
}

// MARK: - Synced Zoomable View (reads/writes shared zoom state)

struct SyncedZoomableView: NSViewRepresentable {
    let texture: MTLTexture
    @ObservedObject var syncState: SyncedZoomState

    func makeNSView(context: Context) -> SyncedZoomMTKView {
        let view = SyncedZoomMTKView()
        view.device = texture.device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.syncState = syncState
        view.imageWidth = texture.width
        view.imageHeight = texture.height
        return view
    }

    func updateNSView(_ mtkView: SyncedZoomMTKView, context: Context) {
        context.coordinator.texture = texture
        mtkView.imageWidth = texture.width
        mtkView.imageHeight = texture.height
        // Sync zoom state from the shared observable
        mtkView.zoomScale = syncState.zoomScale
        mtkView.panOffset = syncState.panOffset
        mtkView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }

    // Reuses the same rendering logic as ZoomableMetalTextureView.Coordinator
    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture
        private var renderPipeline: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var commandQueue: MTLCommandQueue?

        init(texture: MTLTexture) {
            self.texture = texture
            super.init()
            let device = texture.device
            commandQueue = device.makeCommandQueue()
            if let library = device.makeDefaultLibrary(),
               let vf = library.makeFunction(name: "quad_vertex"),
               let ff = library.makeFunction(name: "quad_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vf
                desc.fragmentFunction = ff
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: sd)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let zv = view as? SyncedZoomMTKView,
                  let drawable = view.currentDrawable,
                  let pipeline = renderPipeline,
                  let queue = commandQueue,
                  let cb = queue.makeCommandBuffer(),
                  let samp = sampler else { return }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store

            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)

            let dw = Float(drawable.texture.width), dh = Float(drawable.texture.height)
            let tw = Float(texture.width), th = Float(texture.height)
            let baseFit = Float(zv.fitScale())
            let scale = baseFit * Float(zv.zoomScale)
            let ndcHW = (tw * scale) / dw, ndcHH = (th * scale) / dh
            let bs = Float(view.window?.backingScaleFactor ?? 2.0)
            let panX = Float(zv.panOffset.x) * bs / dw * 2.0
            let panY = Float(zv.panOffset.y) * bs / dh * 2.0

            var vertices: [Float] = [
                -ndcHW + panX, -ndcHH - panY, 0, 1,
                 ndcHW + panX, -ndcHH - panY, 1, 1,
                -ndcHW + panX,  ndcHH - panY, 0, 0,
                 ndcHW + panX,  ndcHH - panY, 1, 0,
            ]
            enc.setVertexBytes(&vertices, length: vertices.count * 4, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(samp, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}

// MARK: - Synced MTKView (propagates zoom/pan changes to shared state)

class SyncedZoomMTKView: MTKView {
    weak var syncState: SyncedZoomState?
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero
    var imageWidth: Int = 0
    var imageHeight: Int = 0

    private var isZoomDragging = false
    private var zoomAnchorView: NSPoint = .zero
    private var zoomStartScale: CGFloat = 1.0
    private var zoomStartPan: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    func fitScale() -> CGFloat {
        guard imageWidth > 0, imageHeight > 0 else { return 1.0 }
        let vw = bounds.width, vh = bounds.height
        guard vw > 0, vh > 0 else { return 1.0 }
        return min(vw / CGFloat(imageWidth), vh / CGFloat(imageHeight))
    }

    private func propagate() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let state = self.syncState else { return }
            state.zoomScale = self.zoomScale
            state.panOffset = self.panOffset
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            zoomScale = 1.0; panOffset = .zero
            propagate(); needsDisplay = true; return
        }
        isZoomDragging = true
        zoomAnchorView = convert(event.locationInWindow, from: nil)
        zoomStartScale = zoomScale; zoomStartPan = panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard isZoomDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - zoomAnchorView.x
        let zoomFactor = pow(2.0, dx / 200.0)
        let newScale = max(0.1, min(50.0, zoomStartScale * zoomFactor))

        let baseFit = fitScale()
        guard baseFit > 0 else { return }
        let oldEff = baseFit * zoomStartScale, newEff = baseFit * newScale
        let relX = zoomAnchorView.x - bounds.width / 2.0
        let relY = zoomAnchorView.y - bounds.height / 2.0
        let imgX = (relX - zoomStartPan.x) / oldEff
        let imgY = (relY + zoomStartPan.y) / oldEff
        panOffset.x = relX - imgX * newEff
        panOffset.y = -(relY - imgY * newEff)
        zoomScale = newScale
        propagate(); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { isZoomDragging = false }

    override func scrollWheel(with event: NSEvent) {
        guard zoomScale > 1.01 else { super.scrollWheel(with: event); return }
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        propagate(); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        let oldScale = zoomScale
        let newScale = max(0.1, min(50.0, oldScale * factor))
        let baseFit = fitScale()
        guard baseFit > 0 else { return }
        let oldEff = baseFit * oldScale, newEff = baseFit * newScale
        let relX = mouseInView.x - bounds.width / 2.0
        let relY = mouseInView.y - bounds.height / 2.0
        let imgX = (relX - panOffset.x) / oldEff
        let imgY = (relY + panOffset.y) / oldEff
        panOffset.x = relX - imgX * newEff
        panOffset.y = -(relY - imgY * newEff)
        zoomScale = newScale
        propagate(); needsDisplay = true
    }
}
