// v2.0.2
import Cocoa
import QuickLookUI
import ImageDecoderBridge
import os.log

private let logger = Logger(subsystem: "com.joergsflow.AstroBlinkV2.QuickLookPreview", category: "preview")

// QuickLook preview controller for FITS and XISF astrophotography files.
// Shows an STF-stretched preview when pressing spacebar in Finder.
// Uses NSViewController + QLPreviewingController (macOS approach).
class PreviewViewController: NSViewController, QLPreviewingController {

    private var imageView: NSImageView!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        imageView = NSImageView(frame: container.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        container.addSubview(imageView)

        self.view = container
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Decode on background thread to avoid blocking QuickLook
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                handler(QuickLookError.decodeFailed)
                return
            }

            // Decode the image file via C bridge
            guard let imageData = QuickLookDecoder.decode(url: url) else {
                logger.error("Decode failed for \(url.lastPathComponent)")
                handler(QuickLookError.decodeFailed)
                return
            }
            defer { imageData.free() }

            // Calculate STF parameters for auto-stretch
            let stfParams = QuickLookSTF.calculate(
                pixels: imageData.pixels,
                width: imageData.width,
                height: imageData.height,
                channelCount: imageData.channelCount
            )

            // Bin2x for large images (>4096px) to stay within memory limits
            let previewWidth: Int
            let previewHeight: Int
            if imageData.width > 4096 || imageData.height > 4096 {
                previewWidth = imageData.width / 2
                previewHeight = imageData.height / 2
            } else {
                previewWidth = imageData.width
                previewHeight = imageData.height
            }

            // Render to CGImage using LUT-based STF stretch + parallel row processing
            guard let cgImage = QuickLookRenderer.renderToImage(
                imageData: imageData,
                stfParams: stfParams,
                targetWidth: previewWidth,
                targetHeight: previewHeight
            ) else {
                logger.error("Render failed for \(url.lastPathComponent)")
                handler(QuickLookError.renderFailed)
                return
            }

            // Display the rendered image on main thread
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: previewWidth, height: previewHeight))
            DispatchQueue.main.async {
                self.imageView.image = nsImage
                self.preferredContentSize = NSSize(width: previewWidth, height: previewHeight)
                handler(nil)
            }
        }
    }
}
