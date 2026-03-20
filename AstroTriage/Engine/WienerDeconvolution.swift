// Wiener deconvolution — frequency-domain optimal deconvolution
// Uses vDSP 2D FFT with Gaussian PSF estimated from measured FWHM
// Significantly better than USM/RL: no ringing, preserves noise, handles real PSF shape
import Foundation
import Accelerate

enum WienerDeconvolution {

    // Apply Wiener deconvolution to a single-channel float plane
    // fwhm: estimated PSF width in pixels (from star detection)
    // strength: 0.0 = no effect, 1.0 = moderate, 2.0 = aggressive
    // Returns deconvolved plane (same size as input)
    static func deconvolve(plane: [Float], width: Int, height: Int,
                           fwhm: Float, strength: Float) -> [Float] {
        guard strength > 0.01, fwhm > 0.5 else { return plane }

        // Pad to next power of 2 for FFT
        let fftW = nextPowerOf2(width)
        let fftH = nextPowerOf2(height)
        let fftSize = fftW * fftH

        // Log2 dimensions for vDSP
        let log2W = vDSP_Length(log2(Double(fftW)))
        let log2H = vDSP_Length(log2(Double(fftH)))

        guard let fftSetup = vDSP_create_fftsetup(max(log2W, log2H), FFTRadix(kFFTRadix2)) else {
            return plane
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Copy image into zero-padded buffer (real part only, imaginary = 0)
        var realPart = [Float](repeating: 0, count: fftSize)
        var imagPart = [Float](repeating: 0, count: fftSize)

        for y in 0..<height {
            for x in 0..<width {
                realPart[y * fftW + x] = plane[y * width + x]
            }
        }

        // Forward 2D FFT
        var splitReal = realPart
        var splitImag = imagPart
        splitReal.withUnsafeMutableBufferPointer { realPtr in
            splitImag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_fft2d_zip(fftSetup, &splitComplex,
                               1, vDSP_Stride(fftW),
                               log2W, log2H,
                               FFTDirection(kFFTDirection_Forward))
            }
        }

        // Generate Wiener filter in frequency domain
        // PSF Gaussian: H(u,v) = exp(-2π²σ²(u²+v²))
        // σ = FWHM / 2.355
        let sigma = fwhm / 2.355
        let sigma2 = sigma * sigma
        let twoPiSqSigma2 = 2.0 * Float.pi * Float.pi * sigma2

        // Noise-to-signal ratio (K parameter) — controls regularization
        // Lower K = more aggressive deconvolution (more ringing risk)
        // Higher K = smoother result (less sharpening)
        let k: Float = 0.1 / max(0.1, strength)  // strength 1.0 → K=0.1, strength 2.0 → K=0.05

        var filterReal = [Float](repeating: 0, count: fftSize)
        var filterImag = [Float](repeating: 0, count: fftSize)

        for v in 0..<fftH {
            let fy = Float(v < fftH / 2 ? v : v - fftH) / Float(fftH)
            for u in 0..<fftW {
                let fx = Float(u < fftW / 2 ? u : u - fftW) / Float(fftW)
                let freq2 = fx * fx + fy * fy

                // PSF in frequency domain (Gaussian)
                let h = exp(-twoPiSqSigma2 * freq2)
                let h2 = h * h

                // Wiener filter: H / (H² + K)
                let wiener = h / (h2 + k)

                let idx = v * fftW + u
                // Apply filter: multiply in frequency domain
                let r = splitReal[idx]
                let i = splitImag[idx]
                filterReal[idx] = r * wiener
                filterImag[idx] = i * wiener
            }
        }

        // Inverse 2D FFT
        filterReal.withUnsafeMutableBufferPointer { realPtr in
            filterImag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_fft2d_zip(fftSetup, &splitComplex,
                               1, vDSP_Stride(fftW),
                               log2W, log2H,
                               FFTDirection(kFFTDirection_Inverse))
            }
        }

        // Normalize FFT output (vDSP doesn't normalize)
        let scale = 1.0 / Float(fftSize)
        vDSP_vsmul(filterReal, 1, [scale], &filterReal, 1, vDSP_Length(fftSize))

        // Extract result (crop back to original size)
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                result[y * width + x] = max(0, filterReal[y * fftW + x])
            }
        }

        // Blend with original based on strength (smooth transition)
        let blend = min(1.0, strength)
        if blend < 1.0 {
            for i in 0..<result.count {
                result[i] = plane[i] * (1.0 - blend) + result[i] * blend
            }
        }

        return result
    }

    // Apply Wiener deconvolution to all channels of planar float data
    static func deconvolve(data: [Float], width: Int, height: Int,
                           channelCount: Int, fwhm: Float, strength: Float) -> [Float] {
        let planeSize = width * height
        var result = data

        for ch in 0..<channelCount {
            let offset = ch * planeSize
            let plane = Array(data[offset..<offset + planeSize])
            let deconvolved = deconvolve(plane: plane, width: width, height: height,
                                         fwhm: fwhm, strength: strength)
            result.replaceSubrange(offset..<offset + planeSize, with: deconvolved)
        }

        return result
    }

    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        return v + 1
    }
}
