// v1.4.0
import SwiftUI
import Metal
import MetalKit
import Photos
import UniformTypeIdentifiers

// PostParams must match Metal struct layout exactly
struct PostParams {
    var darkLevel: Float = 0.0
    var gradA: Float = 0.0
    var gradB: Float = 0.0
    var gradC: Float = 0.0
}

// View model: open a FITS/XISF file, decode, optional debayer, STF stretch, optional sharpen, display
@MainActor
class ViewerViewModel: ObservableObject {
    @Published var filename: String = ""
    @Published var statusMessage: String = "Open a FITS or XISF file"
    @Published var isLoading: Bool = false
    @Published var headers: [(key: String, value: String)] = []
    @Published var displayTexture: MTLTexture?
    @Published var imageWidth: Int = 0
    @Published var imageHeight: Int = 0
    @Published var showFilePicker: Bool = false
    @Published var isSaving: Bool = false
    @Published var saveMessage: String = ""

    // Adjustable image processing parameters (persisted via UserDefaults)
    @Published var stretchStrength: Float = 0.25 {  // TARGET_BKG [0.05..0.50]
        didSet {
            UserDefaults.standard.set(stretchStrength, forKey: "viewer_stretchStrength")
            reprocessIfNeeded()
        }
    }
    @Published var darkLevel: Float = 0.0 {         // Black point raise [0..0.5]
        didSet {
            UserDefaults.standard.set(darkLevel, forKey: "viewer_darkLevel")
            reprocessIfNeeded()
        }
    }
    @Published var sharpenAmount: Float = 0.0 {     // Unsharp mask strength [0..2]
        didSet {
            UserDefaults.standard.set(sharpenAmount, forKey: "viewer_sharpenAmount")
            reprocessIfNeeded()
        }
    }
    @Published var denoiseAmount: Float = 0.0 {     // Bilateral denoise strength [0..1]
        didSet {
            UserDefaults.standard.set(denoiseAmount, forKey: "viewer_denoiseAmount")
            reprocessIfNeeded()
        }
    }
    @Published var gradientStrength: Float = 0.0 {  // Gradient correction [0..1], 0=off
        didSet {
            UserDefaults.standard.set(gradientStrength, forKey: "viewer_gradientStrength")
            // Recompute gradient coefficients only when going from 0 to >0
            if gradientStrength > 0 && gradientCoefficients == nil {
                gradientCoefficients = nil
            }
            reprocessIfNeeded()
        }
    }
    @Published var autoRotate: Bool = true {         // Auto-rotate landscape to portrait
        didSet {
            UserDefaults.standard.set(autoRotate, forKey: "viewer_autoRotate")
            // No reprocess needed — rotation applied at display time
            objectWillChange.send()
        }
    }
    @Published var debayerEnabled: Bool = false {    // Manual debayer toggle
        didSet { reprocessFromRaw() }
    }
    @Published var bayerPatternDetected: String? = nil  // Auto-detected from header
    @Published var showAdjustments: Bool = false         // Toggle adjustments panel

    // True when any processing setting differs from factory defaults
    var hasNonDefaultSettings: Bool {
        stretchStrength != 0.25 || darkLevel != 0 || sharpenAmount != 0
        || denoiseAmount != 0 || gradientStrength != 0
    }

    // True when current image is landscape (wider than tall)
    var isLandscapeImage: Bool {
        imageWidth > imageHeight && imageWidth > 0
    }

    let device: MTLDevice?

    // Keep raw decoded data for re-processing without re-reading the file
    private var rawDecodedImage: DecodedImage?
    // Debayered RGB buffer (when debayer is active)
    private var debayeredImage: DecodedImage?
    // STF-stretched texture before post-processing (for slider re-render)
    private var stretchedTexture: MTLTexture?
    // Track if reprocess is already in flight to avoid duplicate work
    private var isReprocessing: Bool = false
    // Cached gradient plane coefficients for current image (raw, unscaled)
    private var gradientCoefficients: PostParams?

    // Important header keywords to highlight at the top
    private let priorityKeywords: Set<String> = [
        "OBJECT", "FILTER", "EXPTIME", "EXPOSURE",
        "CCD-TEMP", "GAIN", "OFFSET",
        "INSTRUME", "TELESCOP", "IMAGETYP",
        "BAYERPAT", "XBINNING", "DATE-OBS", "DATE-LOC"
    ]

    // Supported file types for the file picker
    static let supportedTypes: [UTType] = {
        var types: [UTType] = []
        if let xisf = UTType(filenameExtension: "xisf") { types.append(xisf) }
        if let fits = UTType(filenameExtension: "fits") { types.append(fits) }
        if let fit = UTType(filenameExtension: "fit") { types.append(fit) }
        if let fts = UTType(filenameExtension: "fts") { types.append(fts) }
        types.append(.data)
        return types
    }()

    init() {
        self.device = MTLCreateSystemDefaultDevice()
        // Restore persisted settings (UserDefaults returns 0 for unset keys)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "viewer_stretchStrength") != nil {
            stretchStrength = defaults.float(forKey: "viewer_stretchStrength")
        }
        darkLevel = defaults.float(forKey: "viewer_darkLevel")
        sharpenAmount = defaults.float(forKey: "viewer_sharpenAmount")
        denoiseAmount = defaults.float(forKey: "viewer_denoiseAmount")
        gradientStrength = defaults.float(forKey: "viewer_gradientStrength")
        // Auto-rotate defaults to true for new installs
        if defaults.object(forKey: "viewer_autoRotate") != nil {
            autoRotate = defaults.bool(forKey: "viewer_autoRotate")
        }
        // Migrate from old bool gradient setting
        if defaults.object(forKey: "viewer_gradientEnabled") != nil {
            if defaults.bool(forKey: "viewer_gradientEnabled") && gradientStrength == 0 {
                gradientStrength = 0.5
            }
            defaults.removeObject(forKey: "viewer_gradientEnabled")
        }
    }

    // Supported file extensions
    private static let validExtensions: Set<String> = ["xisf", "fits", "fit", "fts"]

    // Bayer pattern string to shader index mapping
    private static let bayerPatternMap: [String: Int] = [
        "RGGB": 0, "GRBG": 1, "GBRG": 2, "BGGR": 3
    ]

    func openFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Self.validExtensions.contains(ext) else {
            statusMessage = "Unsupported file: .\(ext)"
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        filename = url.lastPathComponent
        isLoading = true
        statusMessage = "Decoding..."
        headers = []
        displayTexture = nil
        rawDecodedImage = nil
        debayeredImage = nil
        stretchedTexture = nil
        gradientCoefficients = nil
        bayerPatternDetected = nil
        debayerEnabled = false

        let targetURL = url

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self, let device = self.device else { return }

            // Read headers
            let rawHeaders = MetadataExtractor.readHeaders(from: targetURL)

            // Decode image data into Metal buffer
            let result = ImageDecoder.decode(url: targetURL, device: device)

            await MainActor.run {
                // Sort: priority keywords first, then alphabetical
                let priorityKeys = self.priorityKeywords
                let sorted = rawHeaders.sorted { a, b in
                    let aP = priorityKeys.contains(a.key.uppercased())
                    let bP = priorityKeys.contains(b.key.uppercased())
                    if aP != bP { return aP }
                    return a.key < b.key
                }
                self.headers = sorted.map { (key: $0.key, value: $0.value) }

                // Detect Bayer pattern from headers
                let bayerPat = rawHeaders["BAYERPAT"]?.trimmingCharacters(in: .whitespaces).uppercased()
                if let pat = bayerPat, Self.bayerPatternMap[pat] != nil {
                    self.bayerPatternDetected = pat
                }

                switch result {
                case .success(let decoded):
                    self.imageWidth = decoded.width
                    self.imageHeight = decoded.height
                    self.rawDecodedImage = decoded

                    let channels = decoded.channelCount == 1 ? "Mono" : "RGB"
                    let bayerInfo = self.bayerPatternDetected != nil ? " (\(self.bayerPatternDetected!))" : ""
                    self.statusMessage = "\(decoded.width) x \(decoded.height) \(channels)\(bayerInfo)"

                    // Auto-enable debayer for mono CFA images
                    if decoded.channelCount == 1 && self.bayerPatternDetected != nil {
                        self.debayerEnabled = true
                    } else {
                        self.processAndDisplay()
                    }

                case .failure(let error):
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.isLoading = false
                }

                if accessing {
                    targetURL.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    // MARK: - Re-processing (stretch/sharpen changed, no re-decode needed)

    // Called when stretch strength changes — re-run STF + sharpen
    private func reprocessIfNeeded() {
        guard rawDecodedImage != nil || debayeredImage != nil else { return }
        processAndDisplay()
    }

    // Called when debayer toggle changes — need to re-debayer from raw
    private func reprocessFromRaw() {
        guard rawDecodedImage != nil else { return }
        debayeredImage = nil
        stretchedTexture = nil
        gradientCoefficients = nil
        processAndDisplay()
    }

    // MARK: - Full processing pipeline: debayer -> gradient -> STF -> denoise -> sharpen

    private func processAndDisplay() {
        guard !isReprocessing else { return }
        guard let device = device else { return }

        isReprocessing = true
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let rawImage = await self.rawDecodedImage
            let shouldDebayer = await self.debayerEnabled
            let bayerPat = await self.bayerPatternDetected
            let stretch = await self.stretchStrength
            let dark = await self.darkLevel
            let sharpen = await self.sharpenAmount
            let denoise = await self.denoiseAmount
            let gradStrength = await self.gradientStrength

            guard let rawImage = rawImage else {
                await MainActor.run {
                    self.isReprocessing = false
                    self.isLoading = false
                }
                return
            }

            // Step 1: Debayer if needed (mono CFA -> RGB)
            let imageForSTF: DecodedImage
            if shouldDebayer && rawImage.channelCount == 1,
               let patStr = bayerPat,
               let patIdx = Self.bayerPatternMap[patStr] {

                // Check if we already have debayered data cached
                if let cached = await self.debayeredImage {
                    imageForSTF = cached
                } else {
                    let debayered = self.runDebayer(raw: rawImage, pattern: patIdx, device: device)
                    if let debayered = debayered {
                        await MainActor.run { self.debayeredImage = debayered }
                        imageForSTF = debayered
                    } else {
                        imageForSTF = rawImage
                    }
                }
            } else {
                imageForSTF = rawImage
            }

            // Step 2: Compute gradient correction if strength > 0
            var postParams: PostParams
            if gradStrength > 0 {
                if let cached = await self.gradientCoefficients {
                    postParams = cached
                } else {
                    let grad = Self.computeGradient(from: imageForSTF)
                    await MainActor.run { self.gradientCoefficients = grad }
                    postParams = grad
                }
                // Scale gradient by strength * 3 (so 300% = 9x measured gradient)
                let scale = gradStrength * 3.0
                postParams.gradA *= scale
                postParams.gradB *= scale
                postParams.gradC *= scale
            } else {
                postParams = PostParams()
            }
            postParams.darkLevel = dark

            // Step 3: STF stretch (with gradient + dark applied in shader)
            let stfParamsArray = STFCalculator.calculate(from: imageForSTF, targetBackground: stretch)
            guard let stfTexture = self.runSTFStretch(image: imageForSTF, stfParams: stfParamsArray, postParams: postParams, device: device) else {
                await MainActor.run {
                    self.statusMessage = "Metal stretch error"
                    self.isReprocessing = false
                    self.isLoading = false
                }
                return
            }

            // Step 4: Denoise if amount > 0 (before sharpen — denoise first, then enhance)
            var currentTexture = stfTexture
            if denoise > 0.01 {
                currentTexture = self.runDenoise(input: currentTexture, strength: denoise, device: device) ?? currentTexture
            }

            // Step 5: Sharpen if amount > 0
            if sharpen > 0.01 {
                currentTexture = self.runSharpen(input: currentTexture, amount: sharpen, device: device) ?? currentTexture
            }

            await MainActor.run {
                self.stretchedTexture = stfTexture
                self.displayTexture = currentTexture
                self.isReprocessing = false
                self.isLoading = false
            }
        }
    }

    // MARK: - Metal Pipeline: Debayer

    nonisolated private func runDebayer(raw: DecodedImage, pattern: Int, device: MTLDevice) -> DecodedImage? {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "debayer_bilinear"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        // Output: 3-plane uint16 (R, G, B) — same dimensions as input
        let outputSize = raw.width * raw.height * 3 * MemoryLayout<UInt16>.size
        guard let outputBuffer = device.makeBuffer(length: outputSize, options: .storageModeShared),
              let commandQueue = device.makeCommandQueue(),
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

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (raw.width + 15) / 16,
            height: (raw.height + 15) / 16,
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

    // MARK: - Metal Pipeline: STF Stretch

    nonisolated private func runSTFStretch(image: DecodedImage, stfParams: [STFParams], postParams: PostParams = PostParams(), device: MTLDevice) -> MTLTexture? {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "normalize_uint16"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        // Determine bin factor: bin2 when image exceeds device max texture size
        let maxSize = 8192  // Conservative limit (iOS simulator + older devices)
        let binFactor = (image.width > maxSize || image.height > maxSize) ? 2 : 1
        let outWidth = image.width / binFactor
        let outHeight = image.height / binFactor

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outWidth,
            height: outHeight,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .shared

        guard let outTexture = device.makeTexture(descriptor: texDesc),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(image.buffer, offset: 0, index: 0)
        encoder.setTexture(outTexture, index: 0)

        var w = Int32(image.width)
        var h = Int32(image.height)
        var ch = Int32(image.channelCount)
        encoder.setBytes(&w, length: 4, index: 1)
        encoder.setBytes(&h, length: 4, index: 2)
        encoder.setBytes(&ch, length: 4, index: 3)

        var params = stfParams
        while params.count < 3 { params.append(STFParams()) }
        encoder.setBytes(&params, length: MemoryLayout<STFParams>.stride * 3, index: 4)

        var bin = Int32(binFactor)
        encoder.setBytes(&bin, length: 4, index: 5)

        var post = postParams
        encoder.setBytes(&post, length: MemoryLayout<PostParams>.size, index: 6)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (outWidth + 15) / 16,
            height: (outHeight + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outTexture
    }

    // MARK: - Gradient Computation (8x8 grid, 20th percentile + linear plane fit)

    /// Computes a linear gradient plane from raw image data.
    /// Divides image into 8x8 grid, takes 20th percentile of each cell (robust to stars),
    /// fits z = a*x + b*y + c, then mean-normalizes so only the tilt is removed.
    nonisolated private static func computeGradient(from image: DecodedImage) -> PostParams {
        let w = image.width
        let h = image.height
        let ptr = image.buffer.contents().assumingMemoryBound(to: UInt16.self)

        let planeSize = w * h
        let gridSize = 8
        let cellW = w / gridSize
        let cellH = h / gridSize
        let samplesPerCell = min(400, cellW * cellH)

        var gridX = [Float](repeating: 0, count: gridSize * gridSize)
        var gridY = [Float](repeating: 0, count: gridSize * gridSize)
        var gridZ = [Float](repeating: 0, count: gridSize * gridSize)

        for gy in 0..<gridSize {
            for gx in 0..<gridSize {
                let cellStartX = gx * cellW
                let cellStartY = gy * cellH

                var samples = [Float]()
                samples.reserveCapacity(samplesPerCell)

                // Deterministic sampling using stride through the cell
                let step = max(1, (cellW * cellH) / samplesPerCell)
                for i in stride(from: 0, to: cellW * cellH, by: step) {
                    let lx = i % cellW
                    let ly = i / cellW
                    let sx = cellStartX + lx
                    let sy = cellStartY + ly
                    guard sx < w && sy < h else { continue }

                    let idx = sy * w + sx
                    if image.channelCount == 1 {
                        samples.append(Float(ptr[idx]) / 65535.0)
                    } else {
                        // Average of RGB channels for luminance estimate
                        let r = Float(ptr[idx]) / 65535.0
                        let g = Float(ptr[planeSize + idx]) / 65535.0
                        let b = Float(ptr[2 * planeSize + idx]) / 65535.0
                        samples.append((r + g + b) / 3.0)
                    }
                }

                // 20th percentile — more robust to stars than median
                samples.sort()
                let pctIdx = max(0, min(samples.count - 1, samples.count / 5))
                let background = samples.isEmpty ? 0 : samples[pctIdx]

                let gi = gy * gridSize + gx
                gridX[gi] = (Float(gx) + 0.5) / Float(gridSize)
                gridY[gi] = (Float(gy) + 0.5) / Float(gridSize)
                gridZ[gi] = background
            }
        }

        // Least squares fit: z = a*x + b*y + c
        let n = Float(gridSize * gridSize)
        var sx: Float = 0, sy: Float = 0, sz: Float = 0
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        var sxz: Float = 0, syz: Float = 0

        for i in 0..<Int(n) {
            let x = gridX[i], y = gridY[i], z = gridZ[i]
            sx += x; sy += y; sz += z
            sxx += x * x; syy += y * y; sxy += x * y
            sxz += x * z; syz += y * z
        }

        // Solve 3x3 system using Cramer's rule
        let det = sxx * (syy * n - sy * sy)
                - sxy * (sxy * n - sy * sx)
                + sx  * (sxy * sy - syy * sx)

        guard abs(det) > 1e-10 else { return PostParams() }

        let a = (sxz * (syy * n - sy * sy)
               - sxy * (syz * n - sy * sz)
               + sx  * (syz * sy - syy * sz)) / det

        let b = (sxx * (syz * n - sy * sz)
               - sxz * (sxy * n - sy * sx)
               + sx  * (sxy * sz - syz * sx)) / det

        let c = (sxx * (syy * sz - syz * sy)
               - sxy * (sxy * sz - syz * sx)
               + sxz * (sxy * sy - syy * sx)) / det

        // Mean-normalize: remove average so only tilt remains
        let meanPlane = a * 0.5 + b * 0.5 + c
        let cNorm = c - meanPlane

        return PostParams(darkLevel: 0, gradA: a, gradB: b, gradC: cNorm)
    }

    // MARK: - Metal Pipeline: Bilateral Denoise

    nonisolated private func runDenoise(input: MTLTexture, strength: Float, device: MTLDevice) -> MTLTexture? {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "bilateral_denoise"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: input.width,
            height: input.height,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .shared

        guard let outTexture = device.makeTexture(descriptor: texDesc),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(outTexture, index: 1)

        var str = strength
        encoder.setBytes(&str, length: 4, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (input.width + 15) / 16,
            height: (input.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outTexture
    }

    // MARK: - Metal Pipeline: Unsharp Mask Sharpening

    nonisolated private func runSharpen(input: MTLTexture, amount: Float, device: MTLDevice) -> MTLTexture? {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "unsharp_mask"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: input.width,
            height: input.height,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .shaderRead]
        texDesc.storageMode = .shared

        guard let outTexture = device.makeTexture(descriptor: texDesc),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(outTexture, index: 1)

        var amt = amount
        var rad: Float = 1.0  // Reserved for future larger kernel
        encoder.setBytes(&amt, length: 4, index: 0)
        encoder.setBytes(&rad, length: 4, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (input.width + 15) / 16,
            height: (input.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outTexture
    }

    // MARK: - Save to Photos (bin2 JPEG)

    func saveToPhotos() {
        guard let texture = displayTexture else { return }
        isSaving = true
        saveMessage = ""

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let width = texture.width
            let height = texture.height
            let bytesPerRow = width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
            texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                             from: MTLRegion(origin: .init(), size: .init(width: width, height: height, depth: 1)),
                             mipmapLevel: 0)

            // BGRA -> RGBA
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let b = pixels[i]
                pixels[i] = pixels[i + 2]
                pixels[i + 2] = b
            }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let fullCGImage = context.makeImage() else {
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "Failed to create image"
                }
                return
            }

            // Bin 2x2: resize to half dimensions
            let bin2Width = width / 2
            let bin2Height = height / 2
            guard let bin2Context = CGContext(
                data: nil,
                width: bin2Width,
                height: bin2Height,
                bitsPerComponent: 8,
                bytesPerRow: bin2Width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "Failed to create bin2 context"
                }
                return
            }

            bin2Context.interpolationQuality = .high
            bin2Context.draw(fullCGImage, in: CGRect(x: 0, y: 0, width: bin2Width, height: bin2Height))

            guard let bin2CGImage = bin2Context.makeImage() else {
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "Failed to downsample"
                }
                return
            }

            let uiImage = UIImage(cgImage: bin2CGImage)

            guard let jpegData = uiImage.jpegData(compressionQuality: 0.92) else {
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "JPEG conversion failed"
                }
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: jpegData, options: nil)
                }
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "Saved \(bin2Width)x\(bin2Height) JPEG to Photos"
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if self.saveMessage.starts(with: "Saved") {
                            self.saveMessage = ""
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
