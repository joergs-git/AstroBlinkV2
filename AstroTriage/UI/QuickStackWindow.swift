// v4.4.0
import SwiftUI
import MetalKit
import Accelerate
import UniformTypeIdentifiers

// LightspeedStacker views: progress panel, result view, image preview.
// Shared utilities: renderFloatToTexture, StarCrossShape, ZoomableTextureMTKView,
// ZoomableMetalTextureView, MetalTextureView, ImagePreviewView, ImagePreviewWindowController.

// MARK: - Shared Rendering

// Converts raw float data to GPU texture with STF stretch, post-processing, denoise, deconvolution
func renderFloatToTexture(
    data: [Float], width: Int, height: Int,
    channelCount: Int, targetBackground: Float,
    sharpening: Float = 0, contrast: Float = 0, darkLevel: Float = 0,
    saturation: Float = 1.0, linkedStretch: Bool = false,
    denoise: Float = 0, deconvolve: Float = 0, useRL: Bool = false,
    precomputedSTF: [STFParams]? = nil,
    device: MTLDevice
) -> MTLTexture? {
    let planeSize = width * height

    // Compute STF params per channel (matches STFCalculator: 5% subsample)
    func computeSTF(channelOffset: Int) -> (c0: Float, mb: Float) {
        let sampleCount = max(1000, Int(Float(planeSize) * 0.05))
        let sampleStride = max(1, planeSize / sampleCount)
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        for i in stride(from: 0, to: planeSize, by: sampleStride) {
            samples.append(data[channelOffset + i] / 65535.0)
        }
        vDSP_vsort(&samples, vDSP_Length(samples.count), 1)
        let median = samples[samples.count / 2]
        var devs = samples
        let negMed = -median
        vDSP_vsadd(devs, 1, [negMed], &devs, 1, vDSP_Length(devs.count))
        vDSP_vabs(devs, 1, &devs, 1, vDSP_Length(devs.count))
        vDSP_vsort(&devs, vDSP_Length(devs.count), 1)
        let mad = 1.4826 * devs[devs.count / 2]
        let c0 = max(Float(0.0), min(Float(1.0), median + (-1.25) * mad))
        let mb: Float
        if targetBackground <= 0.001 {
            mb = 0.5
        } else {
            let mNorm = max(Float(0.001), min(Float(0.999), (median - c0) / max(1.0 - c0, 0.001)))
            mb = mNorm * (1 - targetBackground) / (mNorm * (1 - 2 * targetBackground) + targetBackground)
        }
        return (c0, mb)
    }

    // Use precomputed STF params (from full-res data) only when stretch slider
    // is at default (0.25). When user adjusts stretch, recompute with new target.
    let usePrecomputed = precomputedSTF != nil && abs(targetBackground - 0.25) < 0.01

    let stfR: (c0: Float, mb: Float)
    if usePrecomputed, let pre = precomputedSTF, !pre.isEmpty {
        stfR = (pre[0].c0, pre[0].mb)
    } else {
        stfR = computeSTF(channelOffset: 0)
    }

    let c0: Float
    let mb: Float
    let stfG: (c0: Float, mb: Float)
    let stfB: (c0: Float, mb: Float)

    if linkedStretch || channelCount < 3 {
        c0 = stfR.c0
        mb = stfR.mb
        stfG = stfR
        stfB = stfR
    } else {
        c0 = stfR.c0
        mb = stfR.mb
        if usePrecomputed, let pre = precomputedSTF, pre.count >= 3 {
            stfG = (pre[1].c0, pre[1].mb)
            stfB = (pre[2].c0, pre[2].mb)
        } else {
            stfG = computeSTF(channelOffset: planeSize)
            stfB = computeSTF(channelOffset: 2 * planeSize)
        }
    }

    // GPU path: upload float data to MTLBuffer, run restretch_float kernel
    let dataByteCount = data.count * MemoryLayout<Float>.size
    guard let inputBuffer = data.withUnsafeBufferPointer({ ptr in
        device.makeBuffer(bytes: ptr.baseAddress!, length: dataByteCount, options: .storageModeShared)
    }) else { return nil }

    // Output texture
    let texDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
    )
    texDesc.usage = [.shaderRead, .shaderWrite]
    guard let outputTex = device.makeTexture(descriptor: texDesc) else { return nil }

    // Pack params struct (must match RestretchParams in Metal shader)
    struct RestretchParams {
        var c0: Float
        var mb: Float
        var darkLevel: Float
        var contrast: Float
        var sharpening: Float
        var width: Int32
        var height: Int32
        var channelCount: Int32
        var saturation: Float
        var c0_g: Float
        var mb_g: Float
        var c0_b: Float
        var mb_b: Float
    }

    var params = RestretchParams(
        c0: c0, mb: mb,
        darkLevel: darkLevel, contrast: contrast, sharpening: sharpening,
        width: Int32(width), height: Int32(height), channelCount: Int32(channelCount),
        saturation: saturation,
        c0_g: stfG.c0, mb_g: stfG.mb,
        c0_b: stfB.c0, mb_b: stfB.mb
    )

    guard let library = device.makeDefaultLibrary(),
          let function = library.makeFunction(name: "restretch_float"),
          let pipeline = try? device.makeComputePipelineState(function: function),
          let queue = device.makeCommandQueue(),
          let cmdBuf = queue.makeCommandBuffer(),
          let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setTexture(outputTex, index: 0)
    encoder.setBytes(&params, length: MemoryLayout<RestretchParams>.size, index: 1)

    let tg = MTLSize(width: 32, height: 32, depth: 1)
    let grid = MTLSize(width: (width + 31) / 32, height: (height + 31) / 32, depth: 1)
    encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    encoder.endEncoding()
    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()

    // Helper: create a scratch texture matching output dimensions
    func makeScratchTex() -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: td)
    }

    var currentResult: MTLTexture = outputTex

    // ── Pass A: Two-pass denoise (bilateral + chrominance) ──
    if denoise > 0.01 {
        let effectiveStrength = min(denoise, 1.0)

        struct DenoiseParams {
            var strength: Float; var width: Int32; var height: Int32; var radius: Int32
        }

        if let denoiseFunc = library.makeFunction(name: "bilateral_denoise"),
           let denoisePipe = try? device.makeComputePipelineState(function: denoiseFunc),
           let chromaFunc = library.makeFunction(name: "chroma_denoise"),
           let chromaPipe = try? device.makeComputePipelineState(function: chromaFunc),
           let texA = makeScratchTex(), let texB = makeScratchTex() {

            // Bilateral (pixel noise)
            let lumRadius: Int32 = denoise > 1.0 ? 7 : (denoise > 0.5 ? 5 : 3)
            var p1 = DenoiseParams(strength: effectiveStrength,
                                   width: Int32(width), height: Int32(height), radius: lumRadius)
            if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                e.setComputePipelineState(denoisePipe)
                e.setTexture(currentResult, index: 0); e.setTexture(texA, index: 1)
                e.setBytes(&p1, length: MemoryLayout<DenoiseParams>.size, index: 0)
                e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
            }

            // Chrominance (color patches)
            let chromaRadius: Int32 = denoise > 1.0 ? 7 : 5
            var p2 = DenoiseParams(strength: min(denoise * 1.5, 1.0),
                                   width: Int32(width), height: Int32(height), radius: chromaRadius)
            if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                e.setComputePipelineState(chromaPipe)
                e.setTexture(texA, index: 0); e.setTexture(texB, index: 1)
                e.setBytes(&p2, length: MemoryLayout<DenoiseParams>.size, index: 0)
                e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
            }
            currentResult = texB
        }
    }

    // ── Pass B: Deconvolution (USM or Richardson-Lucy) ──
    if deconvolve > 0.01 {
        if useRL {
            // Richardson-Lucy iterative deconvolution
            // PSF sigma scales with slider: 0.8–2.0 pixels (typical seeing blur)
            // Iterations scale: 5–20 based on strength
            struct RLParams {
                var psfSigma: Float; var psfRadius: Int32; var width: Int32; var height: Int32
            }

            let psfSigma: Float = 0.8 + deconvolve * 0.6  // 0.8–2.0
            let psfRadius = Int32(ceil(3.0 * psfSigma))
            let iterations = min(20, max(5, Int(deconvolve * 10)))

            if let ratioFunc = library.makeFunction(name: "rl_compute_ratio"),
               let ratioPipe = try? device.makeComputePipelineState(function: ratioFunc),
               let updateFunc = library.makeFunction(name: "rl_update_estimate"),
               let updatePipe = try? device.makeComputePipelineState(function: updateFunc),
               let ratioTex = makeScratchTex(),
               let estA = makeScratchTex(), let estB = makeScratchTex() {

                var rlp = RLParams(psfSigma: psfSigma, psfRadius: psfRadius,
                                   width: Int32(width), height: Int32(height))

                // Copy current result to initial estimate
                if let cb = queue.makeCommandBuffer(), let enc = cb.makeBlitCommandEncoder() {
                    enc.copy(from: currentResult, to: estA)
                    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                }

                let observed = currentResult
                var curEst = estA
                var newEst = estB

                for _ in 0..<iterations {
                    // Step 1: ratio = observed / convolve(estimate, PSF)
                    if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                        e.setComputePipelineState(ratioPipe)
                        e.setTexture(observed, index: 0)
                        e.setTexture(curEst, index: 1)
                        e.setTexture(ratioTex, index: 2)
                        e.setBytes(&rlp, length: MemoryLayout<RLParams>.size, index: 0)
                        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                        cb.commit(); cb.waitUntilCompleted()
                    }
                    // Step 2: estimate *= convolve(ratio, PSF)
                    if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                        e.setComputePipelineState(updatePipe)
                        e.setTexture(curEst, index: 0)
                        e.setTexture(ratioTex, index: 1)
                        e.setTexture(newEst, index: 2)
                        e.setBytes(&rlp, length: MemoryLayout<RLParams>.size, index: 0)
                        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                        cb.commit(); cb.waitUntilCompleted()
                    }
                    swap(&curEst, &newEst)
                }
                currentResult = curEst
            }
        } else {
            // Multi-scale unsharp mask (fast approximation)
            struct SharpenParams {
                var amount: Float; var radius: Float; var width: Int32; var height: Int32
            }

            if let sharpFunc = library.makeFunction(name: "unsharp_mask_lum"),
               let sharpPipe = try? device.makeComputePipelineState(function: sharpFunc),
               let pingTex = makeScratchTex(), let pongTex = makeScratchTex() {

                let scales: [(radius: Float, factor: Float)] = [
                    (1.5, 1.0), (3.0, 0.6), (5.0, 0.3)
                ]
                var src = currentResult
                var dst = pingTex

                for (i, scale) in scales.enumerated() {
                    var sp = SharpenParams(amount: deconvolve * scale.factor, radius: scale.radius,
                                           width: Int32(width), height: Int32(height))
                    if let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
                        e.setComputePipelineState(sharpPipe)
                        e.setTexture(src, index: 0); e.setTexture(dst, index: 1)
                        e.setBytes(&sp, length: MemoryLayout<SharpenParams>.size, index: 0)
                        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tg); e.endEncoding()
                        cb.commit(); cb.waitUntilCompleted()
                    }
                    if i < scales.count - 1 {
                        src = dst; dst = (src === pingTex) ? pongTex : pingTex
                    }
                }
                currentResult = dst
            }
        }
    }

    return currentResult
}

// Small cross shape for marking detected stars in the mini preview
struct StarCrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX, cy = rect.midY
        let half = min(rect.width, rect.height) / 2
        path.move(to: CGPoint(x: cx - half, y: cy))
        path.addLine(to: CGPoint(x: cx + half, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - half))
        path.addLine(to: CGPoint(x: cx, y: cy + half))
        return path
    }
}

// Zoomable MTKView for Quick Stack result: Photoshop-style click-drag zoom,
// scroll-wheel pan, trackpad pinch, double-click reset to fit.
class ZoomableTextureMTKView: MTKView {
    var textureCoordinator: ZoomableMetalTextureView.Coordinator?

    // Zoom state (self-contained, no dependency on MetalRenderer)
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero
    var imageWidth: Int = 0
    var imageHeight: Int = 0

    private var isZoomDragging = false
    private var zoomAnchorView: NSPoint = .zero
    private var zoomStartScale: CGFloat = 1.0
    private var zoomStartPan: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    // Fit scale: how much to scale image to fit the view
    func fitScale() -> CGFloat {
        guard imageWidth > 0, imageHeight > 0 else { return 1.0 }
        let vw = bounds.width
        let vh = bounds.height
        guard vw > 0, vh > 0 else { return 1.0 }
        return min(vw / CGFloat(imageWidth), vh / CGFloat(imageHeight))
    }

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }

    // MARK: - Photoshop-style click-drag zoom

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoom()
            needsDisplay = true
            return
        }
        isZoomDragging = true
        zoomAnchorView = convert(event.locationInWindow, from: nil)
        zoomStartScale = zoomScale
        zoomStartPan = panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard isZoomDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - zoomAnchorView.x

        // Horizontal drag: right = zoom in, left = zoom out (~200px = 2x)
        let zoomFactor = pow(2.0, dx / 200.0)
        let newScale = max(0.1, min(50.0, zoomStartScale * zoomFactor))

        let viewBounds = bounds.size
        let baseFit = fitScale()
        guard baseFit > 0 else { return }

        let oldEffective = baseFit * zoomStartScale
        let newEffective = baseFit * newScale

        let relX = zoomAnchorView.x - viewBounds.width / 2.0
        let relY = zoomAnchorView.y - viewBounds.height / 2.0

        let imgX = (relX - zoomStartPan.x) / oldEffective
        let imgY = (relY + zoomStartPan.y) / oldEffective

        panOffset.x = relX - imgX * newEffective
        panOffset.y = -(relY - imgY * newEffective)
        zoomScale = newScale

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isZoomDragging = false
    }

    // Scroll wheel: pan when zoomed in
    override func scrollWheel(with event: NSEvent) {
        guard zoomScale > 1.01 else {
            super.scrollWheel(with: event)
            return
        }
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        needsDisplay = true
    }

    // Trackpad pinch-to-zoom
    override func magnify(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        let oldScale = zoomScale
        let newScale = max(0.1, min(50.0, oldScale * factor))

        let viewBounds = bounds.size
        let baseFit = fitScale()
        guard baseFit > 0 else { return }

        let oldEffective = baseFit * oldScale
        let newEffective = baseFit * newScale

        let relX = mouseInView.x - viewBounds.width / 2.0
        let relY = mouseInView.y - viewBounds.height / 2.0

        let imgX = (relX - panOffset.x) / oldEffective
        let imgY = (relY + panOffset.y) / oldEffective

        panOffset.x = relX - imgX * newEffective
        panOffset.y = -(relY - imgY * newEffective)
        zoomScale = newScale

        needsDisplay = true
    }
}

// SwiftUI wrapper for the zoomable texture view (used in Quick Stack result window)
struct ZoomableMetalTextureView: NSViewRepresentable {
    let texture: MTLTexture

    func makeNSView(context: Context) -> ZoomableTextureMTKView {
        let view = ZoomableTextureMTKView()
        view.device = texture.device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.textureCoordinator = context.coordinator
        view.imageWidth = texture.width
        view.imageHeight = texture.height
        return view
    }

    func updateNSView(_ mtkView: ZoomableTextureMTKView, context: Context) {
        context.coordinator.texture = texture
        mtkView.imageWidth = texture.width
        mtkView.imageHeight = texture.height
        mtkView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }

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
               let vertexFunc = library.makeFunction(name: "quad_vertex"),
               let fragmentFunc = library.makeFunction(name: "quad_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFunc
                desc.fragmentFunction = fragmentFunc
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let zoomView = view as? ZoomableTextureMTKView,
                  let drawable = view.currentDrawable,
                  let pipeline = renderPipeline,
                  let queue = commandQueue,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let samp = sampler else { return }

            let renderPassDesc = MTLRenderPassDescriptor()
            renderPassDesc.colorAttachments[0].texture = drawable.texture
            renderPassDesc.colorAttachments[0].loadAction = .clear
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            renderPassDesc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
            encoder.setRenderPipelineState(pipeline)

            let dw = Float(drawable.texture.width)
            let dh = Float(drawable.texture.height)
            let tw = Float(texture.width)
            let th = Float(texture.height)

            // Fit-to-view base scale, then apply zoom + pan
            let baseFit = Float(zoomView.fitScale())
            let scale = baseFit * Float(zoomView.zoomScale)

            let ndcHW = (tw * scale) / dw
            let ndcHH = (th * scale) / dh

            // Pan offset in NDC (convert from points to drawable pixels for Retina)
            let backingScale = Float(view.window?.backingScaleFactor ?? 2.0)
            let panX = Float(zoomView.panOffset.x) * backingScale / dw * 2.0
            let panY = Float(zoomView.panOffset.y) * backingScale / dh * 2.0

            var vertices: [Float] = [
                -ndcHW + panX, -ndcHH - panY, 0.0, 1.0,
                 ndcHW + panX, -ndcHH - panY, 1.0, 1.0,
                -ndcHW + panX,  ndcHH - panY, 0.0, 0.0,
                 ndcHW + panX,  ndcHH - panY, 1.0, 0.0,
            ]

            encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samp, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// NSViewRepresentable wrapper to display a MTLTexture in SwiftUI using MTKView
struct MetalTextureView: NSViewRepresentable {
    let texture: MTLTexture

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = texture.device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.texture = texture
        mtkView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }

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
               let vertexFunc = library.makeFunction(name: "quad_vertex"),
               let fragmentFunc = library.makeFunction(name: "quad_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFunc
                desc.fragmentFunction = fragmentFunc
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pipeline = renderPipeline,
                  let queue = commandQueue,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let samp = sampler else { return }

            let renderPassDesc = MTLRenderPassDescriptor()
            renderPassDesc.colorAttachments[0].texture = drawable.texture
            renderPassDesc.colorAttachments[0].loadAction = .clear
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            renderPassDesc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
            encoder.setRenderPipelineState(pipeline)

            let dw = Float(drawable.texture.width)
            let dh = Float(drawable.texture.height)
            let tw = Float(texture.width)
            let th = Float(texture.height)

            // Fit-to-view scaling
            let scale = min(dw / tw, dh / th)
            let ndcHW = (tw * scale) / dw
            let ndcHH = (th * scale) / dh

            var vertices: [Float] = [
                -ndcHW, -ndcHH, 0.0, 1.0,
                 ndcHW, -ndcHH, 1.0, 1.0,
                -ndcHW,  ndcHH, 0.0, 0.0,
                 ndcHW,  ndcHH, 1.0, 0.0,
            ]

            encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samp, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - Quick Stack V2 Views
// These mirror QuickStackProgressView and StackResultView but use QuickStackEngineV2

struct QuickStackV2ProgressView: View {
    @ObservedObject var engine: QuickStackEngineV2
    let nightMode: Bool
    var onDismiss: () -> Void

    @Environment(\.fontScale) private var fontScale
    private func fs(_ base: CGFloat) -> CGFloat { round(base * fontScale) }

    // Track stack start time to compute duration for benchmark
    @State private var stackStartDate = Date()

    private var fg: Color { nightMode ? .red : .primary }
    private var fgDim: Color { nightMode ? .red.opacity(0.7) : .secondary }
    private var bg: Color { nightMode ? .black : Color(NSColor.windowBackgroundColor) }

    // Preview size respecting image aspect ratio (max 200px on longest side)
    private var previewSize: CGSize {
        let maxDim: CGFloat = 200
        let w = CGFloat(engine.sourceWidth)
        let h = CGFloat(engine.sourceHeight)
        guard w > 0, h > 0 else { return CGSize(width: maxDim, height: maxDim) }
        let scale = maxDim / max(w, h)
        return CGSize(width: round(w * scale), height: round(h * scale))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "square.3.layers.3d.down.right")
                    .font(.system(size: fs(16), weight: .semibold))
                    .foregroundColor(fg)
                Text("BETA: LightspeedStacker")
                    .font(.system(size: fs(14), weight: .semibold, design: .monospaced))
                    .foregroundColor(fg)
                Spacer()

                if engine.phase != .done && engine.phase != .failed && engine.phase != .idle {
                    Button(action: {
                        engine.cancel()
                        onDismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: fs(14)))
                            .foregroundColor(fgDim)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel stacking")
                }
            }

            // BETA notice — quick preview only, not a replacement for professional stacking.
            Text("Quick preview only — not a replacement for professional stacking (WBPP, PixInsight, etc.)")
                .font(.system(size: fs(10), weight: .medium, design: .monospaced))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: previewSize.width, height: previewSize.height)

                if let texture = engine.miniPreviewTexture {
                    MetalTextureView(texture: texture)
                        .frame(width: previewSize.width, height: previewSize.height)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(nightMode ? .red : nil)
                        Text("Preparing...")
                            .font(.system(size: fs(11), design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }

                if engine.phase == .detecting && !engine.detectedStarPositions.isEmpty {
                    ForEach(0..<engine.detectedStarPositions.count, id: \.self) { i in
                        let pos = engine.detectedStarPositions[i]
                        StarCrossShape()
                            .stroke(Color(red: 0.3, green: 0.6, blue: 1.0), lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                            .position(x: pos.x, y: pos.y)
                    }
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipped()
            .cornerRadius(4)

            // Interpolation mode selector (visible while not stacking)
            if engine.phase == .idle || engine.phase == .decoding || engine.phase == .detecting {
                HStack(spacing: 6) {
                    Text("Interpolation:")
                        .font(.system(size: fs(10), design: .monospaced))
                        .foregroundColor(fgDim)
                    Picker("", selection: $engine.interpolationMode) {
                        ForEach(QuickStackEngineV2.InterpolationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .controlSize(.mini)
                    .help("Bilinear: fast, uses 4 pixels (2x2). Good with 15+ frames.\nLanczos-3: sharper, uses 36 pixels (6x6). Better for few frames or large dithers.")
                }
            }

            Text(engine.phase.rawValue)
                .font(.system(size: fs(11), weight: .medium, design: .monospaced))
                .foregroundColor(fg)

            if engine.phase == .aligning || engine.phase == .stacking {
                Text("Layer \(engine.currentLayer) / \(engine.totalLayers)")
                    .font(.system(size: fs(10), design: .monospaced))
                    .foregroundColor(fgDim)
            }

            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .tint(nightMode ? .red : .accentColor)

            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: fs(11), design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }

            if engine.phase == .done {
                Button(action: { openResultWindow() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: fs(12)))
                        Text("Open Result (\(engine.resultWidth)x\(engine.resultHeight))")
                            .font(.system(size: fs(12), weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if engine.phase == .done || engine.phase == .failed {
                Button("Close") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(fg)
            }
        }
        .padding(16)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bg.opacity(0.95))
                .shadow(radius: 8)
        )
        .onChange(of: engine.phase) { newPhase in
            if newPhase == .done {
                openResultWindow()
            }
        }
    }

    private func openResultWindow() {
        guard engine.resultTexture != nil else { return }

        let stackMs = Int(Date().timeIntervalSince(stackStartDate) * 1000)
        let savedScale = AppSettings.loadFloat(for: .fontScale).map { CGFloat($0) } ?? 1.0
        let resultView = StackResultViewV2(engine: engine, nightMode: nightMode, stackTimeMs: stackMs)
        let hostingView = NSHostingView(rootView: resultView.environment(\.fontScale, savedScale))
        let maxDim: CGFloat = 1200
        let scale = min(maxDim / CGFloat(engine.resultWidth), maxDim / CGFloat(engine.resultHeight), 1.0)
        let winW = max(1100, CGFloat(engine.resultWidth) * scale + 40)
        let winH = CGFloat(engine.resultHeight) * scale + 80

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 900, height: 400)
        window.title = "LightspeedStacker Result — \(engine.resultWidth)x\(engine.resultHeight)"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
}

enum DeconvMode: String, CaseIterable { case usm = "USM", rl = "RL", wiener = "Wiener" }

