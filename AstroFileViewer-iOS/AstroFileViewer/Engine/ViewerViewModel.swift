// v1.1.0
import SwiftUI
import Metal
import MetalKit
import Photos
import UniformTypeIdentifiers

// Simple view model: open a FITS/XISF file, decode, STF stretch, display
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

    let device: MTLDevice?

    // Important header keywords to highlight at the top
    private let priorityKeywords: Set<String> = [
        "OBJECT", "FILTER", "EXPTIME", "EXPOSURE",
        "CCD-TEMP", "GAIN", "OFFSET",
        "INSTRUME", "TELESCOP", "IMAGETYP",
        "BAYERPAT", "XBINNING", "DATE-OBS", "DATE-LOC"
    ]

    // Supported file types for the file picker
    // Include .data as fallback so users can browse all files if UTIs aren't registered yet
    static let supportedTypes: [UTType] = {
        var types: [UTType] = []
        if let xisf = UTType(filenameExtension: "xisf") { types.append(xisf) }
        if let fits = UTType(filenameExtension: "fits") { types.append(fits) }
        if let fit = UTType(filenameExtension: "fit") { types.append(fit) }
        if let fts = UTType(filenameExtension: "fts") { types.append(fts) }
        // Always include .data so users can pick any file if custom UTIs fail
        types.append(.data)
        return types
    }()

    init() {
        self.device = MTLCreateSystemDefaultDevice()
    }

    // Supported file extensions
    private static let validExtensions: Set<String> = ["xisf", "fits", "fit", "fts"]

    func openFile(url: URL) {
        // Validate file extension
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

                switch result {
                case .success(let decoded):
                    self.imageWidth = decoded.width
                    self.imageHeight = decoded.height
                    let channels = decoded.channelCount == 1 ? "Mono" : "RGB"
                    self.statusMessage = "\(decoded.width) x \(decoded.height) \(channels)"
                    self.stretchAndDisplay(decoded: decoded, device: device)

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

    // STF stretch on GPU: normalize_uint16 kernel → BGRA8 texture
    private func stretchAndDisplay(decoded: DecodedImage, device: MTLDevice) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // Calculate STF parameters (per-channel)
            let stfParamsArray = STFCalculator.calculate(from: decoded)

            // Create compute pipeline
            guard let library = device.makeDefaultLibrary(),
                  let function = library.makeFunction(name: "normalize_uint16"),
                  let pipeline = try? await device.makeComputePipelineState(function: function) else {
                await MainActor.run {
                    self.statusMessage = "Metal pipeline error"
                    self.isLoading = false
                }
                return
            }

            // Output texture (BGRA8)
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: decoded.width,
                height: decoded.height,
                mipmapped: false
            )
            texDesc.usage = [.shaderWrite, .shaderRead]
            texDesc.storageMode = .shared

            guard let outTexture = device.makeTexture(descriptor: texDesc),
                  let commandQueue = device.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                await MainActor.run {
                    self.statusMessage = "Metal command error"
                    self.isLoading = false
                }
                return
            }

            // Match the shader signature: buffer(0)=pixels, texture(0)=output,
            // buffer(1)=width, buffer(2)=height, buffer(3)=channelCount, buffer(4)=stfParams
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(decoded.buffer, offset: 0, index: 0)
            encoder.setTexture(outTexture, index: 0)

            var w = Int32(decoded.width)
            var h = Int32(decoded.height)
            var ch = Int32(decoded.channelCount)
            encoder.setBytes(&w, length: 4, index: 1)
            encoder.setBytes(&h, length: 4, index: 2)
            encoder.setBytes(&ch, length: 4, index: 3)

            // STF params array (up to 3 channels)
            var params = stfParamsArray
            while params.count < 3 { params.append(STFParams()) }
            encoder.setBytes(&params, length: MemoryLayout<STFParams>.stride * 3, index: 4)

            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadGroups = MTLSize(
                width: (decoded.width + 15) / 16,
                height: (decoded.height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            await MainActor.run {
                self.displayTexture = outTexture
                self.isLoading = false
            }
        }
    }

    // MARK: - Save to Photos (bin2 JPEG)

    // Convert display texture to bin2 JPEG and save to Photos library
    func saveToPhotos() {
        guard let texture = displayTexture else { return }
        isSaving = true
        saveMessage = ""

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // Read BGRA pixels from texture
            let width = texture.width
            let height = texture.height
            let bytesPerRow = width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
            texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                             from: MTLRegion(origin: .init(), size: .init(width: width, height: height, depth: 1)),
                             mipmapLevel: 0)

            // BGRA → RGBA
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let b = pixels[i]
                pixels[i] = pixels[i + 2]
                pixels[i + 2] = b
            }

            // Create full-size CGImage
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

            // High-quality interpolation for bin2 downsample
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

            // Convert to JPEG data (quality 0.92 — good balance of size vs quality)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.92) else {
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "JPEG conversion failed"
                }
                return
            }

            // Save to Photos library
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: jpegData, options: nil)
                }
                await MainActor.run {
                    self.isSaving = false
                    self.saveMessage = "Saved \(bin2Width)×\(bin2Height) JPEG to Photos"
                    // Auto-clear message after 3 seconds
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
