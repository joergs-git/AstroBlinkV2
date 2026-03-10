// v3.2.0
import Metal
import MetalKit
import AppKit

// Metal renderer: compute-based STF auto-stretch + render pipeline for display
// Supports fit-to-view scaling and Photoshop-style click-drag zoom
class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let computePipeline: MTLComputePipelineState
    let debayerPipeline: MTLComputePipelineState?
    let postProcessPipeline: MTLComputePipelineState?
    let renderPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let texturePool: TexturePool

    // Post-processing params (sharpening, contrast, dark level)
    private var postProcessParams = PostProcessParamsData()
    private var postProcessActive: Bool = false
    private var postProcessOutputTexture: MTLTexture?

    // Mirror of Metal struct PostProcessParams
    struct PostProcessParamsData {
        var sharpening: Float = 0.0
        var contrast: Float = 0.0
        var darkLevel: Float = 0.0

        var isActive: Bool {
            abs(sharpening) > 0.001 || abs(contrast) > 0.001 || darkLevel > 0.001
        }
    }

    // Current image to render
    private(set) var currentImage: DecodedImage?
    private var normalizedTexture: MTLTexture?

    // Cached preview texture (pre-stretched, binned — bypass compute)
    private var cachedPreviewTexture: MTLTexture?
    private var cachedPreviewWidth: Int = 0
    private var cachedPreviewHeight: Int = 0

    // STF parameters (computed once per image, reused across redraws)
    private var currentSTFParams: [STFParams] = []
    private(set) var lockedSTFParams: [STFParams]?  // Non-nil when locked
    var isSTFLocked: Bool { lockedSTFParams != nil }
    private var stfBuffer: MTLBuffer?

    // Zoom and pan state (persists across image changes)
    var zoomScale: CGFloat = 1.0       // 1.0 = fit-to-view
    var panOffset: CGPoint = .zero     // Offset in points from centered position

    // Auto Meridian: 180° rotation via UV flip (zero GPU cost — just flips texture coordinates)
    var rotate180: Bool = false

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.texturePool = TexturePool(device: device)

        guard let library = device.makeDefaultLibrary() else {
            print("[MetalRenderer] ERROR: makeDefaultLibrary() returned nil")
            return nil
        }

        // Load compute kernel for STF normalization
        guard let computeFunc = library.makeFunction(name: "normalize_uint16"),
              let computePipe = try? device.makeComputePipelineState(function: computeFunc) else {
            print("[MetalRenderer] ERROR: Failed to create compute pipeline")
            return nil
        }
        self.computePipeline = computePipe

        // Load debayer kernel (optional — only needed for OSC cameras)
        if let debayerFunc = library.makeFunction(name: "debayer_bilinear"),
           let debayerPipe = try? device.makeComputePipelineState(function: debayerFunc) {
            self.debayerPipeline = debayerPipe
        } else {
            self.debayerPipeline = nil
        }

        // Load post-processing kernel (sharpening, contrast, dark level)
        if let postFunc = library.makeFunction(name: "post_process"),
           let postPipe = try? device.makeComputePipelineState(function: postFunc) {
            self.postProcessPipeline = postPipe
        } else {
            self.postProcessPipeline = nil
        }

        // Load render pipeline for textured quad with scaling
        guard let vertexFunc = library.makeFunction(name: "quad_vertex"),
              let fragmentFunc = library.makeFunction(name: "quad_fragment") else {
            print("[MetalRenderer] ERROR: Failed to load quad shaders")
            return nil
        }

        let renderDesc = MTLRenderPipelineDescriptor()
        renderDesc.vertexFunction = vertexFunc
        renderDesc.fragmentFunction = fragmentFunc
        renderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let renderPipe = try? device.makeRenderPipelineState(descriptor: renderDesc) else {
            print("[MetalRenderer] ERROR: Failed to create render pipeline")
            return nil
        }
        self.renderPipeline = renderPipe

        // Linear sampler for minification, nearest for magnification (pixel-accurate zoom)
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .nearest
        samplerDesc.mipFilter = .notMipmapped
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let samp = device.makeSamplerState(descriptor: samplerDesc) else {
            return nil
        }
        self.sampler = samp

        super.init()

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.autoResizeDrawable = true
        mtkView.delegate = self
    }

    // Bayer pattern map for debayer kernel index
    private static let bayerPatternMap: [String: Int] = [
        "RGGB": 0, "GRBG": 1, "GBRG": 2, "BGGR": 3
    ]

    func setImage(_ image: DecodedImage, in view: MTKView, bayerPattern: String? = nil,
                   targetBackground: Float = STFCalculator.defaultTargetBackground) {
        let isNewImage = currentImage?.buffer !== image.buffer

        // Debayer mono CFA images if Bayer pattern is provided
        let imageForProcessing: DecodedImage
        if image.channelCount == 1,
           let pattern = bayerPattern,
           let patternIndex = Self.bayerPatternMap[pattern.uppercased()],
           let debayered = runDebayer(raw: image, pattern: patternIndex) {
            imageForProcessing = debayered
        } else {
            imageForProcessing = image
        }

        self.currentImage = imageForProcessing
        self.cachedPreviewTexture = nil  // Clear preview, use full-res path
        self.postProcessOutputTexture = nil  // Force post-process recompute

        if isNewImage {
            if let locked = lockedSTFParams {
                currentSTFParams = locked
            } else {
                // Calculate STF from the (possibly debayered) image with user's stretch target
                currentSTFParams = STFCalculator.calculate(from: imageForProcessing, targetBackground: targetBackground)
            }
            updateSTFBuffer()
            normalizedTexture = nil
        }

        view.needsDisplay = true
    }

    // Run bilinear debayer on mono CFA image, returns RGB planar DecodedImage
    private func runDebayer(raw: DecodedImage, pattern: Int) -> DecodedImage? {
        guard let pipeline = debayerPipeline else { return nil }

        let outputSize = raw.width * raw.height * 3 * MemoryLayout<UInt16>.size
        guard let outputBuffer = device.makeBuffer(length: outputSize, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(raw.buffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        var w = Int32(raw.width)
        var h = Int32(raw.height)
        var pat = Int32(pattern)
        encoder.setBytes(&w, length: 4, index: 2)
        encoder.setBytes(&h, length: 4, index: 3)
        encoder.setBytes(&pat, length: 4, index: 4)

        let threadGroupSize = MTLSize(width: 32, height: 32, depth: 1)
        let threadGroups = MTLSize(
            width: (raw.width + 31) / 32,
            height: (raw.height + 31) / 32,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return DecodedImage(
            buffer: outputBuffer,
            width: raw.width,
            height: raw.height,
            channelCount: 3
        )
    }

    // Set a pre-stretched, binned preview texture for instant display.
    // Bypasses the compute pass entirely — just renders the cached texture.
    func setPreview(_ preview: CachedPreview, in view: MTKView) {
        self.cachedPreviewTexture = preview.texture
        self.cachedPreviewWidth = preview.originalWidth
        self.cachedPreviewHeight = preview.originalHeight
        self.currentImage = nil  // No raw data needed
        self.normalizedTexture = nil
        self.postProcessOutputTexture = nil  // Force post-process recompute for new image
        view.needsDisplay = true
    }

    // Lock STF: freeze current image's STF params for all subsequent images
    func lockSTF() {
        lockedSTFParams = currentSTFParams
    }

    // Unlock STF: revert to per-image auto stretch
    func unlockSTF() {
        lockedSTFParams = nil
        // Recompute for current image
        if let image = currentImage {
            currentSTFParams = STFCalculator.calculate(from: image)
            updateSTFBuffer()
            normalizedTexture = nil
        }
    }

    // Set explicit STF params (e.g. from stretch slider) and force re-render
    func setSTFParams(_ params: [STFParams]) {
        currentSTFParams = params
        updateSTFBuffer()
        normalizedTexture = nil  // Force recompute on next draw
        postProcessOutputTexture = nil  // Also re-run post-process
    }

    func clearImage(in view: MTKView) {
        self.currentImage = nil
        self.normalizedTexture = nil
        self.cachedPreviewTexture = nil
        self.postProcessOutputTexture = nil
        self.currentSTFParams = []
        view.needsDisplay = true
    }

    // Update post-processing parameters and invalidate the output texture
    func setPostProcessParams(sharpening: Float, contrast: Float, darkLevel: Float) {
        postProcessParams = PostProcessParamsData(
            sharpening: sharpening,
            contrast: contrast,
            darkLevel: darkLevel
        )
        postProcessActive = postProcessParams.isActive
        postProcessOutputTexture = nil  // Force recompute on next draw
    }

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }

    // Compute the base fit-to-view scale for current image (or cached preview)
    func fitScale(viewBounds: CGSize) -> CGFloat {
        guard viewBounds.width > 0, viewBounds.height > 0 else { return 1.0 }

        let imgW: CGFloat
        let imgH: CGFloat
        if cachedPreviewTexture != nil {
            imgW = CGFloat(cachedPreviewWidth)
            imgH = CGFloat(cachedPreviewHeight)
        } else if let image = currentImage {
            imgW = CGFloat(image.width)
            imgH = CGFloat(image.height)
        } else {
            return 1.0
        }

        return min(viewBounds.width / imgW, viewBounds.height / imgH)
    }

    // MARK: - STF Buffer Management

    private func updateSTFBuffer() {
        // Ensure we have at least 3 channels of params (pad mono to 3)
        var params = currentSTFParams
        while params.count < 3 {
            params.append(params.first ?? STFParams(c0: 0.0, mb: 0.5))
        }

        // Pack into Metal buffer: [c0_R, mb_R, c0_G, mb_G, c0_B, mb_B]
        var floatData: [Float] = []
        for p in params {
            floatData.append(p.c0)
            floatData.append(p.mb)
        }

        stfBuffer = device.makeBuffer(
            bytes: &floatData,
            length: floatData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let drawableW = drawable.texture.width
        let drawableH = drawable.texture.height
        guard drawableW > 0 && drawableH > 0 else { return }

        // Determine the display texture and image dimensions.
        // Fast path: use cached preview texture (pre-stretched, no compute needed).
        // Slow path: run STF compute shader on raw uint16 data.
        let displayTexture: MTLTexture
        let imgW: CGFloat
        let imgH: CGFloat

        if let cachedTex = cachedPreviewTexture {
            // Fast path: pre-stretched preview — zero compute
            displayTexture = cachedTex
            imgW = CGFloat(cachedPreviewWidth)
            imgH = CGFloat(cachedPreviewHeight)
        } else if let image = currentImage, let stfBuf = stfBuffer {
            // Slow path: compute STF on raw data
            let outTexture: MTLTexture
            if let cached = normalizedTexture,
               cached.width == image.width, cached.height == image.height {
                outTexture = cached
            } else {
                guard let tex = texturePool.texture(
                    width: image.width,
                    height: image.height,
                    pixelFormat: .bgra8Unorm
                ) else { return }
                outTexture = tex
            }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(computePipeline)
            encoder.setBuffer(image.buffer, offset: 0, index: 0)

            var width = Int32(image.width)
            var height = Int32(image.height)
            var channels = Int32(image.channelCount)
            encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 1)
            encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 2)
            encoder.setBytes(&channels, length: MemoryLayout<Int32>.size, index: 3)
            encoder.setBuffer(stfBuf, offset: 0, index: 4)
            encoder.setTexture(outTexture, index: 0)

            let threadgroupSize = MTLSize(width: 32, height: 32, depth: 1)
            let gridSize = MTLSize(
                width: (image.width + 31) / 32,
                height: (image.height + 31) / 32,
                depth: 1
            )
            encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            displayTexture = outTexture
            imgW = CGFloat(image.width)
            imgH = CGFloat(image.height)
            self.normalizedTexture = outTexture
        } else {
            return
        }

        // --- Post-processing pass (sharpening, contrast, dark level) ---
        let finalTexture: MTLTexture
        if postProcessActive, let postPipeline = postProcessPipeline {
            // Reuse cached post-process output if available
            if let cached = postProcessOutputTexture,
               cached.width == displayTexture.width, cached.height == displayTexture.height {
                finalTexture = cached
            } else {
                // Need to run the post-process kernel
                guard let ppOutput = texturePool.texture(
                    width: displayTexture.width,
                    height: displayTexture.height,
                    pixelFormat: .bgra8Unorm
                ) else {
                    finalTexture = displayTexture
                    // Skip post-processing if texture allocation fails
                    renderQuad(displayTexture, imgW: imgW, imgH: imgH, drawable: drawable, commandBuffer: commandBuffer, view: view)
                    return
                }

                guard let ppEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    finalTexture = displayTexture
                    renderQuad(displayTexture, imgW: imgW, imgH: imgH, drawable: drawable, commandBuffer: commandBuffer, view: view)
                    return
                }

                ppEncoder.setComputePipelineState(postPipeline)
                ppEncoder.setTexture(displayTexture, index: 0)
                ppEncoder.setTexture(ppOutput, index: 1)

                var params = postProcessParams
                ppEncoder.setBytes(&params, length: MemoryLayout<PostProcessParamsData>.size, index: 0)

                let tgSize = MTLSize(width: 32, height: 32, depth: 1)
                let gridSize = MTLSize(
                    width: (displayTexture.width + 31) / 32,
                    height: (displayTexture.height + 31) / 32,
                    depth: 1
                )
                ppEncoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
                ppEncoder.endEncoding()

                self.postProcessOutputTexture = ppOutput
                finalTexture = ppOutput
            }
        } else {
            finalTexture = displayTexture
        }

        // --- Render scaled quad to drawable ---
        renderQuad(finalTexture, imgW: imgW, imgH: imgH, drawable: drawable, commandBuffer: commandBuffer, view: view)
    }

    // Render a textured quad to the drawable with zoom/pan transform
    private func renderQuad(_ displayTexture: MTLTexture, imgW: CGFloat, imgH: CGFloat, drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer, view: MTKView) {
        let drawableW = drawable.texture.width
        let drawableH = drawable.texture.height
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
        renderPassDesc.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
        renderEncoder.setRenderPipelineState(renderPipeline)

        renderEncoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: Double(drawableW), height: Double(drawableH),
            znear: 0.0, zfar: 1.0
        ))

        let vW = CGFloat(drawableW)
        let vH = CGFloat(drawableH)

        let baseFit = min(vW / imgW, vH / imgH)
        let effectiveScale = baseFit * zoomScale

        let scaledW = imgW * effectiveScale
        let scaledH = imgH * effectiveScale

        let backingScale = view.window?.backingScaleFactor ?? 2.0
        let panPxX = panOffset.x * backingScale
        let panPxY = panOffset.y * backingScale

        let ndcHW = Float(scaledW / vW)
        let ndcHH = Float(scaledH / vH)
        let ndcOX = Float(panPxX / vW) * 2.0
        let ndcOY = Float(-panPxY / vH) * 2.0

        // UV coordinates: normal or flipped 180° for meridian flip correction
        // Rotation is just a UV swap (u→1-u, v→1-v) — zero GPU cost
        let (u0, u1, v0, v1): (Float, Float, Float, Float)
        if rotate180 {
            (u0, u1, v0, v1) = (1.0, 0.0, 0.0, 1.0)
        } else {
            (u0, u1, v0, v1) = (0.0, 1.0, 1.0, 0.0)
        }

        var vertices: [Float] = [
            -ndcHW + ndcOX, -ndcHH + ndcOY, u0, v0,
             ndcHW + ndcOX, -ndcHH + ndcOY, u1, v0,
            -ndcHW + ndcOX,  ndcHH + ndcOY, u0, v1,
             ndcHW + ndcOX,  ndcHH + ndcOY, u1, v1,
        ]

        renderEncoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
        renderEncoder.setFragmentTexture(displayTexture, index: 0)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
