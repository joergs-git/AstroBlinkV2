// AIsaac — Floating window controller (singleton)
// Follows SessionOverviewController pattern: floating, app-level toggling
import SwiftUI
import AppKit
import Combine

class AIsaacWindowController: NSWindowController {
    static let shared = AIsaacWindowController()

    let model = AIsaacModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AIsaac's AstroBlink"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 360, height: 44)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.02, blue: 0.14, alpha: 1.0)

        // Position: right side of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 450
            let y = screenFrame.midY - 100
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        super.init(window: window)

        let hostingView = NSHostingView(rootView: AIsaacView(model: model))
        window.contentView = hostingView

        // Always float on top
        window.level = .floating

        // Resize window when model.isCollapsed changes
        model.$isCollapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] collapsed in
                self?.resizeForCollapsedState(collapsed)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func resizeForCollapsedState(_ collapsed: Bool) {
        guard let w = window else { return }
        let screen = w.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else { return }

        if collapsed {
            // Collapse: shrink to just the chip strip height, keep position/width
            let collapsedHeight: CGFloat = 150
            var frame = w.frame
            frame.origin.y += (frame.height - collapsedHeight)
            frame.size.height = collapsedHeight
            w.setFrame(frame, display: true, animate: true)
        } else {
            // Expand: 80% of screen height, anchored at current top edge
            let expandedHeight = screenFrame.height * 0.8
            var frame = w.frame
            let currentTop = frame.origin.y + frame.height
            frame.size.height = expandedHeight
            frame.origin.y = currentTop - expandedHeight
            // Clamp to screen bounds
            if frame.origin.y < screenFrame.origin.y {
                frame.origin.y = screenFrame.origin.y
            }
            w.setFrame(frame, display: true, animate: true)
        }
    }


    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // Ensure window is visible (show without toggle). Starts collapsed on first show.
    func ensureVisible() {
        if window?.isVisible != true {
            showWindow(nil)
            // Set collapsed size on first show
            if model.isCollapsed {
                resizeForCollapsedState(true)
            }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    // Toggle visibility — focus input field when opening
    func toggleWindow() {
        if let w = window, w.isVisible {
            w.orderOut(nil)
        } else {
            showWindow(nil)
            // Focus the input field after a brief delay to let SwiftUI settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.window?.makeFirstResponder(nil)
                // Find the NSTextField in the hosting view and focus it
                if let contentView = self.window?.contentView {
                    self.focusInput(in: contentView)
                }
            }
        }
    }

    func focusInput(in view: NSView) {
        for subview in view.subviews {
            if let textField = subview as? NSTextField, textField.isEditable {
                window?.makeFirstResponder(textField)
                return
            }
            focusInput(in: subview)
        }
    }

    // Lightweight state push — call frequently from ContentView .onChange handlers
    // Only triggers reactive comments when the window is visible
    func pushStateUpdate(from viewModel: TriageViewModel) {
        guard window?.isVisible == true else { return }
        model.handleStateChange(
            totalFrames: viewModel.images.count,
            isCaching: viewModel.isCaching,
            cacheProgress: viewModel.cacheProgress,
            markedCount: viewModel.images.filter { $0.isMarkedForDeletion }.count,
            isConverged: viewModel.isConverged
        )
        model.nightMode = viewModel.nightMode
    }

    // Full context rebuild — call when opening window or after major changes
    func updateContext(images: [ImageEntry], viewModel: TriageViewModel) {
        // Build session context from TriageViewModel state
        let allImages = images

        // Collect unique objects and filters
        let objects = Array(Set(allImages.compactMap { $0.target }.filter { !$0.isEmpty })).sorted()
        let filters = Array(Set(allImages.compactMap { $0.filter }.filter { !$0.isEmpty })).sorted()

        // Per-filter statistics
        var filterStats: [AIsaacSessionContext.FilterStat] = []
        let grouped = Dictionary(grouping: allImages) { $0.filter ?? "none" }
        for (filter, entries) in grouped.sorted(by: { $0.key < $1.key }) {
            let excellent = entries.filter { $0.qualityTier == .excellent }.count
            let good = entries.filter { $0.qualityTier == .good }.count
            let borderline = entries.filter { $0.qualityTier == .borderline }.count
            let trash = entries.filter { $0.qualityTier == .trash }.count
            let exposure = entries.first?.exposure ?? 0

            filterStats.append(.init(
                filter: filter, count: entries.count, exposure: exposure,
                excellent: excellent, good: good, borderline: borderline, trash: trash
            ))
        }

        // Quality distribution (totals)
        let excellent = allImages.filter { $0.qualityTier == .excellent }.count
        let good = allImages.filter { $0.qualityTier == .good }.count
        let borderline = allImages.filter { $0.qualityTier == .borderline }.count
        let trash = allImages.filter { $0.qualityTier == .trash }.count

        // Total integration
        let totalIntegration = allImages.filter { !$0.isMarkedForDeletion }
            .compactMap { $0.exposure }.reduce(0, +)

        // Equipment (first non-nil from any image)
        let telescope = allImages.first(where: { $0.telescope != nil })?.telescope
        let camera = allImages.first(where: { $0.camera != nil })?.camera
        let focalLength = allImages.first(where: { $0.focalLength != nil })?.focalLength
        let pixelSize = allImages.first(where: { $0.pixelSizeMicrons != nil })?.pixelSizeMicrons

        // Session date
        let sessionDate = allImages.first(where: { $0.date != nil })?.date

        // Marked count
        let markedCount = allImages.filter { $0.isMarkedForDeletion }.count

        // Build loading status description for AIsaac context
        let loadingStatus: String? = {
            if viewModel.isDownloading {
                let est = viewModel.downloadEstimatedSecondsRemaining.map { ", ~\($0)s remaining" } ?? ""
                return "Downloading files to local cache (\(viewModel.downloadCount)/\(viewModel.downloadTotal)\(est))"
            } else if viewModel.loadingPhase == .scanning {
                return "Scanning folder for images..."
            } else if viewModel.loadingPhase == .readingHeaders {
                let est = viewModel.headerEstimatedSecondsRemaining.map { ", ~\($0)s remaining" } ?? ""
                return "Loading file headers (\(viewModel.headerReadCount)/\(viewModel.headerReadTotal)\(est))"
            } else if viewModel.isCaching {
                let est = viewModel.cachingEstimatedSecondsRemaining.map { ", ~\($0)s remaining" } ?? ""
                return "Analyzing images (\(viewModel.cachingCount)/\(viewModel.cachingTotal)\(est)). Quality scores may be incomplete."
            }
            return nil
        }()

        model.sessionContext = AIsaacSessionContext(
            objects: objects.isEmpty ? ["unknown"] : objects,
            filters: filters.isEmpty ? ["none"] : filters,
            totalFrames: allImages.count,
            markedCount: markedCount,
            perFilterStats: filterStats,
            qualityDistribution: .init(
                excellent: excellent, good: good, borderline: borderline, trash: trash
            ),
            totalIntegrationSeconds: totalIntegration,
            telescope: telescope,
            camera: camera,
            focalLength: focalLength,
            pixelSize: pixelSize,
            siteLatitude: allImages.first(where: { $0.siteLatitude != nil })?.siteLatitude,
            siteLongitude: allImages.first(where: { $0.siteLongitude != nil })?.siteLongitude,
            sessionDate: sessionDate,
            snrRetention: viewModel.snrRetention,
            isConverged: viewModel.isConverged,
            isCaching: viewModel.isCaching,
            scoredCount: allImages.filter { $0.qualityTier != nil }.count,
            loadingStatus: loadingStatus,
            setupHash: viewModel.currentSetupFingerprint?.hash,
            frameMetrics: Self.buildFrameMetrics(from: allImages)
        )

        model.nightMode = viewModel.nightMode

        // Current frame identification
        if let selectedImage = viewModel.selectedImage {
            model.currentFrameSessionIndex = selectedImage.sessionIndex
            model.currentFrameFilename = selectedImage.filename
        } else {
            model.currentFrameSessionIndex = nil
            model.currentFrameFilename = nil
        }

        // Read FITS/XISF headers for current image (for frame-specific questions)
        if let selectedImage = viewModel.selectedImage {
            let url = selectedImage.decodingURL
            Task.detached(priority: .userInitiated) {
                let headers = MetadataExtractor.readHeaders(from: url)
                let sorted = headers.sorted { a, b in a.key < b.key }
                    .map { (key: $0.key, value: $0.value) }
                await MainActor.run {
                    self.model.currentImageHeaders = sorted
                }
            }
        }

        // Generate thumbnail of current image for Claude Vision
        updateThumbnail(viewModel: viewModel)
    }

    // Generate a small JPEG thumbnail from the current cached preview texture
    func updateThumbnail(viewModel: TriageViewModel) {
        guard let selectedImage = viewModel.selectedImage,
              let texture = viewModel.getCachedTexture(for: selectedImage.url) else {
            model.currentThumbnailBase64 = nil
            return
        }

        let w = texture.width
        let h = texture.height
        guard w > 0, h > 0 else {
            model.currentThumbnailBase64 = nil
            return
        }

        // For .private textures (GPU-only), blit to .shared first so CPU can read
        let readableTexture: MTLTexture
        if texture.storageMode == .private {
            let device = texture.device
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat, width: w, height: h, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = .shaderRead
            guard let sharedTex = device.makeTexture(descriptor: desc),
                  let queue = device.makeCommandQueue(),
                  let cmdBuf = queue.makeCommandBuffer(),
                  let blit = cmdBuf.makeBlitCommandEncoder() else {
                model.currentThumbnailBase64 = nil
                return
            }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: sharedTex, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            readableTexture = sharedTex
        } else {
            readableTexture = texture
        }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        readableTexture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        // BGRA → RGBA swap
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]
            pixels[i] = pixels[i + 2]
            pixels[i + 2] = b
        }

        // Create bitmap and scale to max 800px
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow, bitsPerPixel: 32
        ) else {
            model.currentThumbnailBase64 = nil
            return
        }
        memcpy(bitmap.bitmapData!, pixels, pixels.count)

        let maxDim: CGFloat = 800
        let scale = min(maxDim / CGFloat(w), maxDim / CGFloat(h), 1.0)
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)

        guard let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: newW, pixelsHigh: newH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            model.currentThumbnailBase64 = nil
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        bitmap.draw(in: NSRect(x: 0, y: 0, width: newW, height: newH))
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = resized.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            model.currentThumbnailBase64 = nil
            return
        }

        model.currentThumbnailBase64 = jpegData.base64EncodedString()
    }

    // Build compact per-frame metrics for AIsaac deep analysis
    private static func buildFrameMetrics(from images: [ImageEntry]) -> [AIsaacSessionContext.FrameMetric] {
        return images.enumerated().map { (idx, img) in
            let tierStr: String
            switch img.qualityTier {
            case .excellent: tierStr = "excellent"
            case .good: tierStr = "good"
            case .borderline: tierStr = "borderline"
            case .trash: tierStr = "trash"
            case .uncertain: tierStr = "uncertain"
            case .none: tierStr = "unscored"
            }
            return AIsaacSessionContext.FrameMetric(
                index: img.sessionIndex,  // use stable session index, not current sort position
                filename: img.filename,
                filter: img.filter ?? "?",
                exposure: img.exposure ?? 0,
                tier: tierStr,
                zScore: img.qualityBreakdown?.combinedZScore,
                fwhm: img.computedFWHM ?? img.fwhm.map { Double($0) },
                hfr: img.computedHFR ?? img.hfr,
                stars: img.computedStarCount ?? img.starCount,
                noise: img.noiseMAD.map { Double($0) },
                ecc: img.computedEccentricity,
                trailing: img.trailingScore,
                isMarked: img.isMarkedForDeletion,
                garbageReason: {
                    guard let reasons = img.qualityBreakdown?.garbageReasons, !reasons.isEmpty else { return nil }
                    return reasons.map { $0.rawValue }.joined(separator: " + ")
                }(),
                reasoning: img.qualityBreakdown?.reasoningText,
                twilight: img.twilightPhase?.rawValue
            )
        }
    }
}
