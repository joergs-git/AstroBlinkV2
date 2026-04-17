// v3.12.0 — Side-by-side image comparison window
// v5.25.1 — Metadata redesign (BEST/SELECTED labels, metric comparison bar),
//           keyboard shortcuts (+/-, Cmd+1/2 zoom, C star toggle, 0 reset)
// "Compare with Best" opens the best-quality image from the same group (target + filter + exposure)
// next to the selected image. Zoom and pan are synchronized between both views.
import SwiftUI
import MetalKit

// MARK: - Shared zoom/pan state for synchronized views

class SyncedZoomState: ObservableObject {
    @Published var zoomScale: CGFloat = 1.0   // Start at fit-to-view
    @Published var panOffset: CGPoint = .zero
    @Published var showStarOverlay: Bool = true  // Shared toggle for C key + UI switch

    func reset() {
        zoomScale = 1.0
        panOffset = .zero
    }
}

// MARK: - Metadata for Compare View

/// Lightweight snapshot of relevant metadata for one side of the compare view
struct CompareMetadata {
    let filename: String
    let fallbackReason: String?  // nil for selected side, set for best side if fallback was used
    let filter: String?
    let exposure: Double?
    let sensorTemp: Double?
    let date: String?
    let time: String?
    let stars: Int?
    let fwhm: Double?
    let hfr: Double?
    let ecc: Double?
    let snr: Double?             // noiseMedian / noiseMAD
    let recommendation: String?  // e.g. "KEEP", "DELETE", "REVIEW"

    static func from(_ entry: ImageEntry, fallbackReason: String? = nil) -> CompareMetadata {
        let snr: Double? = {
            guard let med = entry.noiseMedian, let mad = entry.noiseMAD, mad > 0 else { return nil }
            return Double(med) / Double(mad)
        }()
        return CompareMetadata(
            filename: entry.filename,
            fallbackReason: fallbackReason,
            filter: entry.filter,
            exposure: entry.exposure,
            sensorTemp: entry.sensorTemp,
            date: entry.date,
            time: entry.time,
            stars: entry.displayStarCount,
            fwhm: entry.displayFWHM,
            hfr: entry.displayHFR,
            ecc: entry.computedEccentricity,
            snr: snr,
            recommendation: entry.qualityBreakdown?.recommendationLabel
        )
    }
}

// MARK: - Compare Window Controller

enum CompareWindowController {

    /// Open a comparison window: best image (left) vs selected image (right)
    static func open(selectedEntry: ImageEntry, bestEntry: ImageEntry,
                     device: MTLDevice, nightMode: Bool, debayerEnabled: Bool,
                     rotateSelected: Bool = false, rotateBest: Bool = false,
                     fallbackReason: String? = nil) {
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

            // Build metadata snapshots for the compare view
            let bestMeta = CompareMetadata.from(bestEntry, fallbackReason: fallbackReason)
            let selMeta = CompareMetadata.from(selectedEntry)

            // Convert star details to normalized coordinates [0,1] for overlay rendering
            // Includes PA and axis ratio for direction arrows
            let selStarProblems: [(x: CGFloat, y: CGFloat, ecc: Double, pa: Double?, axisRatio: Double?)] = {
                guard let details = selectedEntry.starDetails,
                      let w = selectedEntry.width, let h = selectedEntry.height,
                      w > 0, h > 0 else { return [] }
                return details.map { star in
                    (x: CGFloat(star.x) / CGFloat(w),
                     y: CGFloat(star.y) / CGFloat(h),
                     ecc: star.eccentricity,
                     pa: star.positionAngle,
                     axisRatio: star.axisRatio)
                }
            }()
            let selConsensusPA = selectedEntry.trailingPA

            await MainActor.run {
                let syncState = SyncedZoomState()

                // Compute initial zoom to fill panel width (each panel is ~half the screen)
                let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let panelW = (screen.width - 2) / 2.0  // minus divider, split in two
                let panelH = screen.height - 60         // approximate bottom strips height
                let imgW = CGFloat(bt.width)
                let imgH = CGFloat(bt.height)
                if imgW > 0, imgH > 0, panelW > 0, panelH > 0 {
                    let fitMin = min(panelW / imgW, panelH / imgH)
                    let fitWidth = panelW / imgW
                    if fitMin > 0 {
                        syncState.zoomScale = fitWidth / fitMin
                    }
                }

                let view = CompareView(
                    leftTexture: bt, rightTexture: st,
                    bestMeta: bestMeta,
                    selectedMeta: selMeta,
                    problemStars: selStarProblems,
                    consensusPA: selConsensusPA,
                    rotateLeft: rotateBest,
                    rotateRight: rotateSelected,
                    syncState: syncState
                )
                // Load font scale from persisted settings
                let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
                let hostingView = NSHostingView(rootView: view.environment(\.fontScale, savedScale))

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
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Compare View (side by side)

struct CompareView: View {
    let leftTexture: MTLTexture
    let rightTexture: MTLTexture
    let bestMeta: CompareMetadata
    let selectedMeta: CompareMetadata
    // Problem stars: normalized (0-1) coordinates + shape metrics for overlay on right panel
    let problemStars: [(x: CGFloat, y: CGFloat, ecc: Double, pa: Double?, axisRatio: Double?)]
    let consensusPA: Double?
    let rotateLeft: Bool
    let rotateRight: Bool
    @ObservedObject var syncState: SyncedZoomState
    @Environment(\.fontScale) private var fontScale

    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    var body: some View {
        VStack(spacing: 0) {
            // Image panels — fill all available space.
            // BEST/SELECTED labels sit inside each panel on black, above the grey strip.
            HStack(spacing: 2) {
                // Left: Best image + label
                VStack(spacing: 0) {
                    SyncedZoomableView(texture: leftTexture, syncState: syncState, rotate180: rotateLeft)
                        .id("compare-left")
                    sideLabel(meta: bestMeta,
                              label: bestMeta.fallbackReason != nil ? "BEST (\(bestMeta.fallbackReason!))" : "BEST",
                              color: bestColor)
                }

                Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 2)

                // Right: Selected image + label
                VStack(spacing: 0) {
                    SyncedZoomableView(
                        texture: rightTexture, syncState: syncState,
                        starOverlayData: problemStars,
                        consensusPA: consensusPA,
                        showStarOverlay: syncState.showStarOverlay,
                        rotate180: rotateRight
                    )
                    .id("compare-right")
                    sideLabel(meta: selectedMeta, label: "SELECTED", color: selColor)
                }
            }
            .layoutPriority(1)

            // Grey metrics strip
            metricsStrip

            // Grey controls strip
            controlsStrip
        }
        .background(Color.black)
    }

    private let bestColor = Color(red: 0.2, green: 0.8, blue: 0.3)
    private let selColor = Color.orange

    // MARK: - Side Label (inside black image panel)

    /// "BEST  Ha  300s  -20°C  2026-04-15  23:54" + filename — on black background
    private func sideLabel(meta: CompareMetadata, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: fs(13), weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Text(metaSummary(meta))
                    .font(.system(size: fs(11), design: .monospaced))
                    .foregroundColor(color.opacity(0.85))
            }
            Text(meta.filename)
                .font(.system(size: fs(11), design: .monospaced))
                .foregroundColor(Color.white.opacity(0.5))
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private func metaSummary(_ meta: CompareMetadata) -> String {
        var parts: [String] = []
        if let f = meta.filter { parts.append(f) }
        if let e = meta.exposure { parts.append(e == floor(e) ? "\(Int(e))s" : String(format: "%.1fs", e)) }
        if let t = meta.sensorTemp { parts.append(String(format: "%.0f\u{00B0}C", t)) }
        if let d = meta.date { parts.append(d) }
        if let t = meta.time { parts.append(String(t.prefix(5))) }
        return parts.joined(separator: "  ")
    }

    // MARK: - Metrics Strip (grey, one line)

    // Darker background for the metrics strip
    private let metricsBackground = Color(red: 0.12, green: 0.12, blue: 0.14)

    private var metricsStrip: some View {
        HStack(spacing: 72) {
            if let rec = selectedMeta.recommendation, !rec.isEmpty {
                recLabel(rec)
            }
            Spacer()
            metricPair("Stars", bestVal: bestMeta.stars.map { Double($0) }, selVal: selectedMeta.stars.map { Double($0) }, fmt: "%.0f")
            metricPair("FWHM", bestVal: bestMeta.fwhm, selVal: selectedMeta.fwhm, fmt: "%.2f")
            metricPair("HFR", bestVal: bestMeta.hfr, selVal: selectedMeta.hfr, fmt: "%.2f")
            metricPair("Ecc", bestVal: bestMeta.ecc, selVal: selectedMeta.ecc, fmt: "%.2f")
            snrPair
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(metricsBackground)
    }

    // MARK: - Controls Strip (grey, one line)

    private var controlsStrip: some View {
        HStack(spacing: 8) {
            Button(action: { syncState.reset() }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset")
                }
                .font(.system(size: fs(10), design: .monospaced))
            }
            .buttonStyle(.bordered).controlSize(.mini)

            if !problemStars.isEmpty {
                Toggle(isOn: $syncState.showStarOverlay) {
                    HStack(spacing: 2) {
                        Image(systemName: "circle.circle").font(.system(size: fs(10)))
                        Text("\(problemStars.count)").font(.system(size: fs(10), design: .monospaced))
                    }
                }
                .toggleStyle(.switch).controlSize(.mini)
                .tint(.red)
                .help("Show/hide star circles (C key)")
            }

            Spacer()

            Text("+/- zoom \u{2022} \u{2318}1/\u{2318}2 100%/200% \u{2022} \u{2318}0 reset \u{2022} C stars")
                .font(.system(size: fs(9), design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Metric Helpers

    // Light grey for metric labels on dark background
    private let metricLabelColor = Color(white: 0.65)

    private func metricPair(_ name: String, bestVal: Double?, selVal: Double?, fmt: String) -> some View {
        Group {
            if let bv = bestVal, let sv = selVal {
                HStack(spacing: 3) {
                    Text("\(name):")
                        .font(.system(size: fs(12), weight: .medium, design: .monospaced))
                        .foregroundColor(metricLabelColor)
                    Text(String(format: fmt, bv))
                        .font(.system(size: fs(12), weight: .bold, design: .monospaced))
                        .foregroundColor(bestColor)
                    Text("vs")
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                    Text(String(format: fmt, sv))
                        .font(.system(size: fs(12), weight: .bold, design: .monospaced))
                        .foregroundColor(selColor)
                }
            }
        }
    }

    private var snrPair: some View {
        Group {
            if let bSNR = bestMeta.snr, let sSNR = selectedMeta.snr, bSNR > 0 {
                let pct = (sSNR / bSNR) * 100.0
                HStack(spacing: 3) {
                    Text("SNR:")
                        .font(.system(size: fs(12), weight: .medium, design: .monospaced))
                        .foregroundColor(metricLabelColor)
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: fs(12), weight: .bold, design: .monospaced))
                        .foregroundColor(pct >= 95 ? bestColor : (pct >= 80 ? selColor : .red))
                }
            }
        }
    }

    private func recLabel(_ rec: String) -> some View {
        let color: Color
        if rec.hasPrefix("KEEP") { color = bestColor }
        else if rec.hasPrefix("DELETE") { color = .red }
        else if rec.hasPrefix("REVIEW") { color = selColor }
        else { color = .secondary }
        return Text("\u{2192} \(rec)")
            .font(.system(size: fs(12), weight: .bold, design: .monospaced))
            .foregroundColor(color)
    }
}

// MARK: - Synced Zoomable View (reads/writes shared zoom state)

struct SyncedZoomableView: NSViewRepresentable {
    let texture: MTLTexture
    @ObservedObject var syncState: SyncedZoomState
    // Optional star overlay data (only used for right panel in compare view)
    var starOverlayData: [(x: CGFloat, y: CGFloat, ecc: Double, pa: Double?, axisRatio: Double?)] = []
    var consensusPA: Double?
    var showStarOverlay: Bool = false
    var rotate180: Bool = false

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
        context.coordinator.rotate180 = rotate180
        mtkView.imageWidth = texture.width
        mtkView.imageHeight = texture.height
        mtkView.zoomScale = syncState.zoomScale
        mtkView.panOffset = syncState.panOffset

        // Manage star overlay: add if data present, remove if not (handles SwiftUI view reuse)
        if !starOverlayData.isEmpty {
            if mtkView.starOverlay == nil {
                mtkView.setupStarOverlay(stars: starOverlayData)
            }
            mtkView.starOverlay?.consensusPA = consensusPA
            mtkView.starOverlay?.showOverlay = showStarOverlay
            mtkView.starOverlay?.needsDisplay = true
        } else if mtkView.starOverlay != nil {
            // Remove overlay if this view shouldn't have one (SwiftUI reused it)
            mtkView.starOverlay?.removeFromSuperview()
            mtkView.starOverlay = nil
        }

        mtkView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture, rotate180: rotate180)
    }

    // Reuses the same rendering logic as ZoomableMetalTextureView.Coordinator
    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture
        var rotate180: Bool
        private var renderPipeline: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var commandQueue: MTLCommandQueue?

        init(texture: MTLTexture, rotate180: Bool = false) {
            self.texture = texture
            self.rotate180 = rotate180
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

            // UV coords: flip both U and V for 180° rotation (meridian flip)
            let (u0, u1, v0, v1): (Float, Float, Float, Float) = rotate180
                ? (1, 0, 0, 1)   // Flipped: U reversed, V reversed
                : (0, 1, 1, 0)   // Normal
            var vertices: [Float] = [
                -ndcHW + panX, -ndcHH - panY, u0, v0,
                 ndcHW + panX, -ndcHH - panY, u1, v0,
                -ndcHW + panX,  ndcHH - panY, u0, v1,
                 ndcHW + panX,  ndcHH - panY, u1, v1,
            ]
            enc.setVertexBytes(&vertices, length: vertices.count * 4, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(samp, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()

            // Refresh star overlay after Metal draw so circles track the image
            DispatchQueue.main.async {
                zv.starOverlay?.needsDisplay = true
            }
        }
    }
}

// MARK: - Star Overlay NSView (draws circles on top of MTKView using exact same coordinate system)

class StarOverlayView: NSView {
    // Star positions in normalized [0,1] image coords + shape metrics
    var stars: [(x: CGFloat, y: CGFloat, ecc: Double, pa: Double?, axisRatio: Double?)] = []
    // Consensus PA direction (degrees 0-180) — shown as a large arrow when available
    var consensusPA: Double?
    var showOverlay: Bool = true

    // These must be set to match the parent SyncedZoomMTKView's state
    weak var parentMTKView: SyncedZoomMTKView?

    // NSView default: origin at bottom-left, Y goes up (same as Metal NDC)
    // Do NOT override isFlipped — must match MTKView's coordinate system

    override func draw(_ dirtyRect: NSRect) {
        guard showOverlay, !stars.isEmpty, let parent = parentMTKView else { return }
        let viewW = bounds.width
        let viewH = bounds.height
        guard viewW > 0, viewH > 0 else { return }

        let imgW = CGFloat(parent.imageWidth)
        let imgH = CGFloat(parent.imageHeight)
        guard imgW > 0, imgH > 0 else { return }

        // Must match the Metal renderer coordinate system exactly.
        // Metal uses: ndcHW = tw * fitScale * zoom / drawableW
        // Overlay must produce same visual positions in view points.
        let drawableW = parent.currentDrawable?.texture.width ?? 0
        let bs = parent.window?.backingScaleFactor ?? 1.0
        let drawableRatio = drawableW > 0 ? CGFloat(drawableW) / viewW : 1.0
        let fitScale = min(viewW / imgW, viewH / imgH)
        let effScale = fitScale * parent.zoomScale / drawableRatio

        // Image center in NSView coords
        // Metal pan: panX_NDC = panOffset.x * bs / drawableW * 2.0
        // In view points: centerX = viewW/2 + panOffset.x * bs / drawableRatio
        let centerX = viewW / 2 + parent.panOffset.x * bs / drawableRatio
        let centerY = viewH / 2 - parent.panOffset.y * bs / drawableRatio

        for star in stars {
            // Convert normalized [0,1] to view coords
            // star.y=0 is image top → in non-flipped NSView, top = high Y
            let sx = centerX + (star.x - 0.5) * imgW * effScale
            let sy = centerY + (0.5 - star.y) * imgH * effScale

            let circleR = max(7, 12 * effScale)

            // Color by eccentricity
            let color: NSColor
            let lineW: CGFloat
            if star.ecc > 0.5 {
                color = .systemRed; lineW = 2.5
            } else if star.ecc > 0.3 {
                color = .systemOrange; lineW = 1.5
            } else {
                color = .systemGreen; lineW = 1.5
            }

            color.setStroke()
            let path = NSBezierPath(ovalIn: NSRect(
                x: sx - circleR, y: sy - circleR,
                width: circleR * 2, height: circleR * 2
            ))
            path.lineWidth = lineW
            path.stroke()

            // PA direction line — shows elongation axis through the circle
            // Only drawn for stars with measurable elongation (axisRatio < 0.85)
            if let pa = star.pa, let ar = star.axisRatio, ar < 0.85 {
                let lineLen = circleR * 1.3
                // PA is measured in degrees [0..180) from image +X axis
                // Convert to radians; NSView Y is flipped vs image Y, so negate angle
                let rad = -pa * .pi / 180.0
                let dx = lineLen * CGFloat(cos(rad))
                let dy = lineLen * CGFloat(sin(rad))

                let paLine = NSBezierPath()
                paLine.move(to: NSPoint(x: sx - dx, y: sy - dy))
                paLine.line(to: NSPoint(x: sx + dx, y: sy + dy))
                paLine.lineWidth = max(1.5, lineW * 0.8)
                color.withAlphaComponent(0.8).setStroke()
                paLine.stroke()
            }
        }

        // Consensus PA arrow — large arrow showing overall trailing direction
        // Only shown when there's a consensus direction (>30% star agreement)
        if let cpa = consensusPA {
            let arrowLen: CGFloat = 40
            let rad = -cpa * .pi / 180.0
            let arrowX = viewW - 60
            let arrowY = viewH - 40
            let dx = arrowLen * CGFloat(cos(rad))
            let dy = arrowLen * CGFloat(sin(rad))

            // Draw thick line for trailing direction
            NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
            let arrowLine = NSBezierPath()
            arrowLine.move(to: NSPoint(x: arrowX - dx * 0.5, y: arrowY - dy * 0.5))
            arrowLine.line(to: NSPoint(x: arrowX + dx * 0.5, y: arrowY + dy * 0.5))
            arrowLine.lineWidth = 3.0
            arrowLine.stroke()

            // Arrowhead
            let headLen: CGFloat = 10
            let headAngle: CGFloat = 0.4  // ~23 degrees
            let tipX = arrowX + dx * 0.5
            let tipY = arrowY + dy * 0.5
            let arrowHead = NSBezierPath()
            arrowHead.move(to: NSPoint(x: tipX, y: tipY))
            arrowHead.line(to: NSPoint(
                x: tipX - headLen * CGFloat(cos(rad - headAngle)),
                y: tipY - headLen * CGFloat(sin(rad - headAngle))
            ))
            arrowHead.move(to: NSPoint(x: tipX, y: tipY))
            arrowHead.line(to: NSPoint(
                x: tipX - headLen * CGFloat(cos(rad + headAngle)),
                y: tipY - headLen * CGFloat(sin(rad + headAngle))
            ))
            arrowHead.lineWidth = 2.5
            arrowHead.stroke()

            // Label
            let label = "Trail PA: \(Int(cpa))\u{00B0}"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemYellow,
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            ]
            (label as NSString).draw(at: NSPoint(x: arrowX - 30, y: arrowY - 25), withAttributes: attrs)
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

    // Star overlay drawn by AppKit NSView on top of Metal content
    var starOverlay: StarOverlayView?

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
        // Refresh star overlay to track zoom/pan
        starOverlay?.needsDisplay = true
    }

    func setupStarOverlay(stars: [(x: CGFloat, y: CGFloat, ecc: Double, pa: Double?, axisRatio: Double?)]) {
        let overlay = StarOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.stars = stars
        overlay.parentMTKView = self
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = .clear
        // Clip to bounds so circles don't bleed into the adjacent panel
        overlay.layer?.masksToBounds = true
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        addSubview(overlay)
        starOverlay = overlay
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

    // Cmd shortcuts must go through performKeyEquivalent (keyDown doesn't receive them reliably)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+1: Zoom to 100% true pixel
        if modifiers == .command, event.keyCode == 18 {
            let fit = fitScale()
            if fit > 0 { zoomScale = 1.0 / fit; panOffset = .zero }
            propagate(); needsDisplay = true
            return true
        }
        // Cmd+2: Zoom to 200%
        if modifiers == .command, event.keyCode == 19 {
            let fit = fitScale()
            if fit > 0 { zoomScale = 2.0 / fit; panOffset = .zero }
            propagate(); needsDisplay = true
            return true
        }
        // Cmd+0: Reset zoom to fit-to-view
        if modifiers == .command, event.keyCode == 29 {
            zoomScale = 1.0; panOffset = .zero
            propagate(); needsDisplay = true
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers

        if event.keyCode == 53 { // ESC
            window?.close()
            return
        }

        // +/= key: Zoom in
        if modifiers.isEmpty, (chars == "+" || chars == "=") {
            zoomScale = max(0.1, min(50.0, zoomScale + 0.25))
            propagate(); needsDisplay = true
            return
        }

        // - key: Zoom out
        if modifiers.isEmpty, chars == "-" {
            zoomScale = max(0.1, min(50.0, zoomScale - 0.25))
            propagate(); needsDisplay = true
            return
        }

        // C key: Toggle star circle overlay
        if modifiers.isEmpty, chars == "c" {
            DispatchQueue.main.async { [weak self] in
                self?.syncState?.showStarOverlay.toggle()
            }
            return
        }

        super.keyDown(with: event)
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
