// v1.5.0 — TIFF decoder via ImageIO. No new C dependency.
// Handles 8/16-bit integer and 32-bit float TIFF, mono and RGB(A).
// Output matches the existing libxisf / cfitsio decoders:
//   - planar uint16 buffer in MTLStorageModeShared (zero-copy)
//   - 1=mono, 3=RGB. Alpha is dropped.
//   - Multi-page TIFFs: page 0 only.
//
// Float-range auto-detection mirrors the FITS v5.14.0 logic
// (Packages/ImageDecoder/Sources/ImageDecoderBridge): values whose magnitude
// peaks at <= 1.5 are treated as normalized [0,1] and scaled by 65535;
// otherwise the float is assumed to be a pre-scaled DN value and clamped.
//
// TIFFs carry no FITS headers, so MetadataExtractor returns an empty dict
// for these files. Filename-token parsing still applies if the user keeps
// NINA-style filenames after exporting from PixInsight, GraxPert, etc.

import Foundation
import Metal
import ImageIO
import CoreGraphics

enum TIFFDecoder {

    static func decode(url: URL, device: MTLDevice) -> Result<DecodedImage, ImageDecoder.DecoderError> {
        // ImageIO supports 8/16/32-bit TIFF natively, including LZW/Deflate
        // compression and tiled layouts. kCGImageSourceShouldAllowFloat keeps
        // 32-bit float pixel data intact (otherwise CG quantizes to 8-bit).
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .failure(.decodeFailed("Could not open TIFF: \(url.lastPathComponent)"))
        }
        let opts: CFDictionary = [
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, opts) else {
            return .failure(.decodeFailed("Could not read TIFF page 0"))
        }

        let width = image.width
        let height = image.height
        let bpc = image.bitsPerComponent
        let bpp = image.bitsPerPixel
        let bitmapInfo = image.bitmapInfo
        let alpha = image.alphaInfo

        guard width > 0, height > 0 else {
            return .failure(.decodeFailed("TIFF has zero dimensions"))
        }
        guard bpc > 0, bpp > 0, bpp % bpc == 0 else {
            return .failure(.decodeFailed("Invalid TIFF pixel format (\(bpc)bpc, \(bpp)bpp)"))
        }
        guard alpha != .alphaOnly else {
            return .failure(.decodeFailed("TIFF has only an alpha channel"))
        }

        let totalChannels = bpp / bpc
        // RGB+alpha or gray+alpha: keep only color channels for astro use.
        let outputChannels: Int
        let colorChannelCount: Int
        switch totalChannels {
        case 1, 2: outputChannels = 1; colorChannelCount = 1
        case 3, 4: outputChannels = 3; colorChannelCount = 3
        default:
            return .failure(.decodeFailed("Unsupported TIFF channel layout (\(totalChannels) channels)"))
        }

        // CG bitmap-info encodes alpha position. ARGB / XRGB layouts put the
        // alpha or skip-byte first, so the color channels start at index 1.
        let alphaIsFirst = (alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst)
        let colorOffset = alphaIsFirst ? 1 : 0

        let isFloat = bitmapInfo.contains(.floatComponents)
        // Big-endian raw pixel data is rare on iOS but legal — swap if reported.
        let byteOrder = bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let needsSwap16 = (byteOrder == CGBitmapInfo.byteOrder16Big.rawValue)

        guard let cfData = image.dataProvider?.data,
              let srcBytes = CFDataGetBytePtr(cfData) else {
            return .failure(.decodeFailed("TIFF data provider returned no bytes"))
        }
        let srcLength = CFDataGetLength(cfData)
        let bytesPerRow = image.bytesPerRow
        guard srcLength >= bytesPerRow * height else {
            return .failure(.decodeFailed("TIFF pixel buffer truncated"))
        }

        let pixelCount = width * height
        let outBytes = pixelCount * outputChannels * MemoryLayout<UInt16>.size
        guard let buffer = device.makeBuffer(length: outBytes, options: .storageModeShared) else {
            return .failure(.metalBufferFailed)
        }
        let outPtr = buffer.contents().bindMemory(
            to: UInt16.self,
            capacity: pixelCount * outputChannels
        )

        // UnsafeRawPointer is the right tool for typed reads from
        // memory we did not allocate — `load(fromByteOffset:as:)` does
        // not bind the region, avoiding strict-aliasing pitfalls of
        // assumingMemoryBound / withMemoryRebound on shared buffers.
        let raw = UnsafeRawPointer(srcBytes)

        switch (bpc, isFloat) {
        case (32, true):
            convertFloat32(
                raw: raw, bytesPerRow: bytesPerRow,
                width: width, height: height,
                totalChannels: totalChannels,
                colorOffset: colorOffset, colorChannelCount: colorChannelCount,
                out: outPtr, planeSize: pixelCount
            )
        case (16, false):
            convertUInt16(
                raw: raw, bytesPerRow: bytesPerRow,
                width: width, height: height,
                totalChannels: totalChannels,
                colorOffset: colorOffset, colorChannelCount: colorChannelCount,
                needsSwap: needsSwap16,
                out: outPtr, planeSize: pixelCount
            )
        case (8, false):
            convertUInt8(
                raw: raw, bytesPerRow: bytesPerRow,
                width: width, height: height,
                totalChannels: totalChannels,
                colorOffset: colorOffset, colorChannelCount: colorChannelCount,
                out: outPtr, planeSize: pixelCount
            )
        default:
            return .failure(.decodeFailed("Unsupported TIFF bit depth: \(bpc)bpc \(isFloat ? "float" : "int")"))
        }

        return .success(DecodedImage(
            buffer: buffer,
            width: width,
            height: height,
            channelCount: outputChannels
        ))
    }

    // MARK: - Conversions

    // 32-bit float → uint16. Range auto-detect mirrors decode_fits v5.14.0:
    // sample peak magnitude on a stride; <=1.5 means normalized [0,1] (PixInsight,
    // GraxPert linear); >1.5 means pre-scaled DN values, just clamp at 65535.
    private static func convertFloat32(
        raw: UnsafeRawPointer, bytesPerRow: Int,
        width: Int, height: Int,
        totalChannels: Int,
        colorOffset: Int, colorChannelCount: Int,
        out: UnsafeMutablePointer<UInt16>, planeSize: Int
    ) {
        // Sample ~64 rows × ~64 floats per row to peak-detect the data range.
        // Cheaper than scanning every pixel; accurate enough for the
        // [0,1] vs DN distinction we care about.
        let rowSampleStride = max(1, height / 64)
        let colSampleStride = max(1, (width * totalChannels) / 64)
        var maxMag: Float = 0
        var y = 0
        while y < height {
            let rowBase = y * bytesPerRow
            var i = 0
            while i < width * totalChannels {
                let m = abs(raw.load(fromByteOffset: rowBase + i * 4, as: Float.self))
                if m > maxMag { maxMag = m }
                i += colSampleStride
            }
            y += rowSampleStride
        }
        let scale: Float = (maxMag <= 1.5) ? 65535.0 : 1.0

        for y in 0..<height {
            let rowBase = y * bytesPerRow
            for x in 0..<width {
                let pixBase = rowBase + (x * totalChannels + colorOffset) * 4
                for ch in 0..<colorChannelCount {
                    let f = raw.load(fromByteOffset: pixBase + ch * 4, as: Float.self) * scale
                    let clamped = max(0, min(65535, f))
                    out[ch * planeSize + y * width + x] = UInt16(clamped)
                }
            }
        }
    }

    // 16-bit integer → uint16 (passthrough, with optional byte-swap for big-endian).
    private static func convertUInt16(
        raw: UnsafeRawPointer, bytesPerRow: Int,
        width: Int, height: Int,
        totalChannels: Int,
        colorOffset: Int, colorChannelCount: Int,
        needsSwap: Bool,
        out: UnsafeMutablePointer<UInt16>, planeSize: Int
    ) {
        for y in 0..<height {
            let rowBase = y * bytesPerRow
            for x in 0..<width {
                let pixBase = rowBase + (x * totalChannels + colorOffset) * 2
                for ch in 0..<colorChannelCount {
                    var v = raw.load(fromByteOffset: pixBase + ch * 2, as: UInt16.self)
                    if needsSwap { v = v.byteSwapped }
                    out[ch * planeSize + y * width + x] = v
                }
            }
        }
    }

    // 8-bit integer → uint16. Replicate high+low byte (`v << 8 | v`) so a
    // saturated 8-bit pixel maps to 65535, not 65280 — keeps STF math sane.
    private static func convertUInt8(
        raw: UnsafeRawPointer, bytesPerRow: Int,
        width: Int, height: Int,
        totalChannels: Int,
        colorOffset: Int, colorChannelCount: Int,
        out: UnsafeMutablePointer<UInt16>, planeSize: Int
    ) {
        for y in 0..<height {
            let rowBase = y * bytesPerRow
            for x in 0..<width {
                let pixBase = rowBase + (x * totalChannels + colorOffset)
                for ch in 0..<colorChannelCount {
                    let v = UInt16(raw.load(fromByteOffset: pixBase + ch, as: UInt8.self))
                    out[ch * planeSize + y * width + x] = (v << 8) | v
                }
            }
        }
    }
}
