// v1.3.0
import SwiftUI
import Metal
import MetalKit
import Photos
import UniformTypeIdentifiers

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

    // Adjustable image processing parameters
    @Published var stretchStrength: Float = 0.25 {  // TARGET_BKG [0.05..0.50]
        didSet { reprocessIfNeeded() }
    }
    @Published var sharpenAmount: Float = 0.0 {     // Unsharp mask strength [0..2]
        didSet { reprocessIfNeeded() }
    }
    @Published var debayerEnabled: Bool = false {    // Manual debayer toggle
        didSet { reprocessFromRaw() }
    }
    @Published var bayerPatternDetected: String? = nil  // Auto-detected from header
    @Published var showAdjustments: Bool = false         // Toggle adjustments panel

    let device: MTLDevice?

    // Keep raw decoded data for re-processing without re-reading the file
    private var rawDecodedImage: DecodedImage?
    // Debayered RGB buffer (when debayer is active)
    private var debayeredImage: DecodedImage?
    // STF-stretched texture before sharpening (for sharpen-only re-render)
    private var stretchedTexture: MTLTexture?
    // Track if reprocess is already in flight to avoid duplicate work
    private var isReprocessing: Bool = false

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
    }

    // Supported file extensions
    private static let validExtensions: Set<String> = ["xisf", "fits", "fit", "fts"]

    // Bayer pattern string to shader index mapping
    nonisolated(unsafe) private static let bayerPatternMap: [String: Int] = [
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
        bayerPatternDetected = nil
        debayerEnabled = false

        // Reset adjustments to defaults for new file
        stretchStrength = 0.25
        sharpenAmount = 0.0

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
        processAndDisplay()
    }

    // MARK: - Full processing pipeline: debayer (optional) -> STF stretch -> sharpen (optional)

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
            let sharpen = await self.sharpenAmount

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

            // Step 2: STF stretch
            let stfParamsArray = STFCalculator.calculate(from: imageForSTF, targetBackground: stretch)
            guard let stfTexture = self.runSTFStretch(image: imageForSTF, stfParams: stfParamsArray, device: device) else {
                await MainActor.run {
                    self.statusMessage = "Metal stretch error"
                    self.isReprocessing = false
                    self.isLoading = false
                }
                return
            }

            // Step 3: Sharpen if amount > 0
            let finalTexture: MTLTexture
            if sharpen > 0.01 {
                finalTexture = self.runSharpen(input: stfTexture, amount: sharpen, device: device) ?? stfTexture
            } else {
                finalTexture = stfTexture
            }

            await MainActor.run {
                self.stretchedTexture = stfTexture
                self.displayTexture = finalTexture
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

    nonisolated private func runSTFStretch(image: DecodedImage, stfParams: [STFParams], device: MTLDevice) -> MTLTexture? {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "normalize_uint16"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: image.width,
            height: image.height,
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

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (image.width + 15) / 16,
            height: (image.height + 15) / 16,
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

        // Output texture (same format as input)
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
