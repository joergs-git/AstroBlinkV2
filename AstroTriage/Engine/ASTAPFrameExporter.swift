// ASTAPFrameExporter — turns a frame ASTAP cannot read into one it can.
//
// ASTAP reads FITS and nothing else: handed an XISF it answers
// `ERROR=Error reading image file.` and then hangs on its GUI. AstroBlink already decodes XISF
// in-process, so the frame is decoded and written back out as a temporary single-plane FITS
// for the solver.
//
// Two reductions are applied on the way, both of which make solving cheaper without costing
// accuracy:
//
//   * COLOUR → MONO. A plate solver wants star positions, not colour. `decode_xisf` returns
//     RGB as separate planes; the green plane is used, because on a Bayer sensor green carries
//     twice the samples of red or blue and is the least noisy of the three.
//
//   * 2×2 BINNING for large frames. Halving each axis quarters the bytes written and read
//     while leaving stars several pixels across — well above what ASTAP needs to centroid.
//     The solved plate scale then refers to the binned grid, so the caller must pass the FOV
//     hint for the BINNED frame and scale CRPIX/CD back afterwards; `BinningFactor` carries
//     that factor so neither step can be forgotten.
//
// v6.9.0

import Foundation
import ImageDecoderBridge

enum ASTAPFrameExporter {

    /// A frame prepared for ASTAP, plus what has to be undone afterwards.
    struct ExportedFrame {
        let url: URL
        /// 1 = full resolution, 2 = 2×2 binned. The solved CRPIX/CD apply to the binned grid.
        let binning: Int
        let width: Int
        let height: Int
    }

    enum ExportError: LocalizedError {
        case decodeFailed(String)
        case emptyImage
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .decodeFailed(let message): return "could not decode frame: \(message)"
            case .emptyImage:                return "frame contains no pixels"
            case .writeFailed(let message):  return "could not write temporary FITS: \(message)"
            }
        }
    }

    /// Frames at least this wide or tall are binned 2×2 before solving. Below it the saving is
    /// not worth the loss of sampling on an already small frame.
    static let binningThresholdPixels = 3000

    /// Decode `source` and write a solver-ready FITS into `directory`.
    ///
    /// Blocking — call off the main thread.
    static func exportForSolving(source: URL, into directory: URL) throws -> ExportedFrame {
        var decoded = decode_xisf(source.path)
        defer { free_decode_result(&decoded) }

        guard decoded.success == 1 else {
            throw ExportError.decodeFailed(Self.message(from: decoded))
        }
        let width = Int(decoded.width)
        let height = Int(decoded.height)
        guard width > 0, height > 0, let pixels = decoded.pixels else {
            throw ExportError.emptyImage
        }

        // Colour comes back planar (R plane, then G, then B); take green.
        let planeCount = max(1, Int(decoded.channelCount))
        let planeOffset = planeCount >= 3 ? width * height : 0
        let plane = UnsafeBufferPointer(start: pixels + planeOffset, count: width * height)

        let shouldBin = max(width, height) >= binningThresholdPixels
        let output: [UInt16]
        let outWidth: Int
        let outHeight: Int
        if shouldBin {
            (output, outWidth, outHeight) = bin2x2(plane, width: width, height: height)
        } else {
            output = Array(plane)
            outWidth = width
            outHeight = height
        }

        let destination = directory.appendingPathComponent("frame.fit")
        let result = output.withUnsafeBufferPointer { buffer in
            write_fits_image_mono(destination.path, buffer.baseAddress,
                                  Int32(outWidth), Int32(outHeight))
        }
        guard result.success == 1 else {
            throw ExportError.writeFailed(Self.message(from: result))
        }

        return ExportedFrame(url: destination,
                             binning: shouldBin ? 2 : 1,
                             width: outWidth,
                             height: outHeight)
    }

    // MARK: - Binning

    /// Average each 2×2 block. Averaging rather than summing keeps the result in 16-bit range
    /// without scaling, so the written FITS needs no BZERO gymnastics.
    ///
    /// An odd last row or column is dropped: one edge pixel cannot shift an astrometric
    /// solution, and carrying a half-block would complicate every downstream coordinate.
    static func bin2x2(_ source: UnsafeBufferPointer<UInt16>,
                       width: Int, height: Int) -> ([UInt16], Int, Int) {
        let outWidth = width / 2
        let outHeight = height / 2
        var output = [UInt16](repeating: 0, count: outWidth * outHeight)

        output.withUnsafeMutableBufferPointer { out in
            for y in 0..<outHeight {
                let row0 = (y * 2) * width
                let row1 = row0 + width
                let outRow = y * outWidth
                for x in 0..<outWidth {
                    let x0 = x * 2
                    let sum = UInt32(source[row0 + x0]) + UInt32(source[row0 + x0 + 1])
                            + UInt32(source[row1 + x0]) + UInt32(source[row1 + x0 + 1])
                    out[outRow + x] = UInt16(sum / 4)
                }
            }
        }
        return (output, outWidth, outHeight)
    }

    // MARK: - Helpers

    /// Read a fixed-size C error buffer without forming a dangling pointer — the same trap
    /// documented in BatchOperations.writeHeader.
    ///
    /// Takes the concrete struct, never `Any`: boxing the imported char-array tuple into `Any`
    /// and reinterpreting its memory yields an empty string, which hides the actual error.
    private static func message(from result: WriteResult) -> String {
        var copy = result
        return withUnsafePointer(to: &copy.error) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }

    private static func message(from result: DecodeResult) -> String {
        var copy = result
        return withUnsafePointer(to: &copy.error) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}
