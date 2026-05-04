#include "ImageDecoderBridge.h"
#include "libxisf.h"
#include "fitsio.h"

#include <cstring>
#include <cstdlib>
#include <string>
#include <TargetConditionals.h>

// ----------------------------------------------------------------------------
// cfitsio thread safety — platform split
//
// macOS (TARGET_OS_OSX): cfitsio is compiled with _REENTRANT (see Package.swift),
// so its internal pthread locks (FFLOCK/FFUNLOCK) protect global state. Different
// files can be decoded concurrently with no extra mutex.
//
// iOS (TARGET_OS_IOS): _REENTRANT is NOT defined for cfitsio on iOS — the
// internal lock path triggered a driver double-registration on iOS where the
// FFLOCK macros expand to no-ops without _REENTRANT. We guard every cfitsio
// call with an external std::mutex instead. Cost: serialised FITS decodes on
// iOS. macOS keeps full concurrency.
//
// CFITSIO_LOCK is the single point that picks one strategy. Adding a new
// platform means defining CFITSIO_LOCK for it here.
// ----------------------------------------------------------------------------
#if TARGET_OS_OSX
    #define CFITSIO_LOCK ((void)0)
#else
    #include <mutex>
    static std::mutex cfitsio_mutex;
    #define CFITSIO_LOCK std::lock_guard<std::mutex> _cflock(cfitsio_mutex)
#endif

// ============================================================================
// XISF Decode — uses libxisf (C++17)
// Uses imageData<T>() for direct memory access (not per-pixel accessor)
// ============================================================================

extern "C" DecodeResult decode_xisf(const char* path) {
    DecodeResult result;
    memset(&result, 0, sizeof(result));

    try {
        LibXISF::XISFReader reader;
        reader.open(path);

        if (reader.imagesCount() == 0) {
            result.success = 0;
            snprintf(result.error, sizeof(result.error), "XISF file contains no images");
            return result;
        }

        // getImage returns const Image& (readPixels=true loads pixel data)
        const LibXISF::Image& image = reader.getImage(0);

        result.width = static_cast<int32_t>(image.width());
        result.height = static_cast<int32_t>(image.height());
        result.channelCount = static_cast<int32_t>(image.channelCount());

        size_t pixelCount = (size_t)result.width * result.height * result.channelCount;
        size_t byteCount = pixelCount * sizeof(uint16_t);
        // Round up to page size — MTLBuffer bytesNoCopy requires page-aligned length
        size_t pageSize = 4096;
        size_t alignedByteCount = (byteCount + pageSize - 1) & ~(pageSize - 1);
        // Page-aligned allocation enables MTLBuffer zero-copy via bytesNoCopy
        void* aligned = nullptr;
        if (posix_memalign(&aligned, pageSize, alignedByteCount) != 0 || !aligned) {
            result.success = 0;
            snprintf(result.error, sizeof(result.error), "Failed to allocate %zu bytes", byteCount);
            return result;
        }
        result.pixels = (uint16_t*)aligned;

        // Access raw pixel data via imageData<T>()
        // libxisf stores data in planar format by default
        const auto sf = image.sampleFormat();

        if (sf == LibXISF::Image::UInt16) {
            const uint16_t* src = image.imageData<uint16_t>();
            memcpy(result.pixels, src, pixelCount * sizeof(uint16_t));

        } else if (sf == LibXISF::Image::UInt32) {
            const uint32_t* src = image.imageData<uint32_t>();
            for (size_t i = 0; i < pixelCount; i++) {
                result.pixels[i] = (uint16_t)(src[i] >> 16);
            }

        } else if (sf == LibXISF::Image::Float32) {
            const float* src = image.imageData<float>();
            for (size_t i = 0; i < pixelCount; i++) {
                float v = src[i];
                if (v < 0.0f) v = 0.0f;
                if (v > 1.0f) v = 1.0f;
                result.pixels[i] = (uint16_t)(v * 65535.0f);
            }

        } else if (sf == LibXISF::Image::Float64) {
            const double* src = image.imageData<double>();
            for (size_t i = 0; i < pixelCount; i++) {
                double v = src[i];
                if (v < 0.0) v = 0.0;
                if (v > 1.0) v = 1.0;
                result.pixels[i] = (uint16_t)(v * 65535.0);
            }

        } else if (sf == LibXISF::Image::UInt8) {
            const uint8_t* src = image.imageData<uint8_t>();
            for (size_t i = 0; i < pixelCount; i++) {
                result.pixels[i] = (uint16_t)src[i] << 8;
            }

        } else {
            free(result.pixels);
            result.pixels = nullptr;
            result.success = 0;
            snprintf(result.error, sizeof(result.error), "Unsupported XISF sample format");
            return result;
        }

        reader.close();
        result.success = 1;

    } catch (const std::exception& e) {
        // Lesson L5: always catch libxisf exceptions (e.g. XML encoding issues)
        if (result.pixels) {
            free(result.pixels);
            result.pixels = nullptr;
        }
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "XISF error: %.240s", e.what());
    }

    return result;
}

// ============================================================================
// FITS Decode — uses cfitsio
// Lesson L1: MUST use TUSHORT for integer FITS to correctly handle BZERO=32768
// Float FITS (BITPIX=-32/-64): read as TFLOAT, auto-detect range, normalize
// to uint16. Handles APP, PixInsight, GraxPert float output correctly.
// ============================================================================

extern "C" DecodeResult decode_fits(const char* path) {
    DecodeResult result;
    memset(&result, 0, sizeof(result));

    CFITSIO_LOCK;  // no-op on macOS; serialises on iOS — see top-of-file rationale
    fitsfile* fptr = nullptr;
    int status = 0;

    if (fits_open_diskfile(&fptr, path, READONLY, &status)) {
        result.success = 0;
        fits_get_errstatus(status, result.error);
        return result;
    }

    // Determine pixel data type before reading
    int bitpix = 0;
    fits_get_img_type(fptr, &bitpix, &status);
    if (status) {
        // If BITPIX query fails, default to integer path (backwards compat)
        status = 0;
        bitpix = SHORT_IMG;
    }

    int naxis = 0;
    fits_get_img_dim(fptr, &naxis, &status);
    if (status || naxis < 2) {
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "Invalid FITS: naxis=%d, status=%d", naxis, status);
        fits_close_file(fptr, &status);
        return result;
    }

    long naxes[3] = {0, 0, 1};
    fits_get_img_size(fptr, 3, naxes, &status);

    result.width = (int32_t)naxes[0];
    result.height = (int32_t)naxes[1];
    result.channelCount = (naxis >= 3) ? (int32_t)naxes[2] : 1;

    size_t pixelCount = (size_t)result.width * result.height * result.channelCount;
    size_t byteCount = pixelCount * sizeof(uint16_t);
    // Round up to page size — MTLBuffer bytesNoCopy requires page-aligned length
    size_t pageSize = 4096;
    size_t alignedByteCount = (byteCount + pageSize - 1) & ~(pageSize - 1);
    // Page-aligned allocation enables MTLBuffer zero-copy via bytesNoCopy
    void* aligned = nullptr;
    if (posix_memalign(&aligned, pageSize, alignedByteCount) != 0 || !aligned) {
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "Failed to allocate %zu bytes", byteCount);
        fits_close_file(fptr, &status);
        return result;
    }
    result.pixels = (uint16_t*)aligned;

    int anynull = 0;

    if (bitpix == FLOAT_IMG || bitpix == DOUBLE_IMG) {
        // Float FITS (BITPIX=-32 or -64): typical output from Astro Pixel Processor,
        // PixInsight, GraxPert. Values usually normalized to [0,1].
        // cfitsio converts double→float automatically when TFLOAT is requested.
        float* floatBuf = (float*)malloc(pixelCount * sizeof(float));
        if (!floatBuf) {
            result.success = 0;
            snprintf(result.error, sizeof(result.error), "Float buffer alloc failed (%zu bytes)",
                     pixelCount * sizeof(float));
            free(result.pixels);
            result.pixels = nullptr;
            fits_close_file(fptr, &status);
            return result;
        }

        fits_read_img(fptr, TFLOAT, 1, (long)pixelCount, nullptr, floatBuf, &anynull, &status);

        if (!status) {
            // Auto-detect pixel value range for correct normalization:
            // [0,1] = standard normalized (APP, PI, GraxPert)
            // [0,N] where N>1 = ADU counts or other scaling
            float maxVal = 0.0f;
            for (size_t i = 0; i < pixelCount; i++) {
                if (floatBuf[i] > maxVal) maxVal = floatBuf[i];
            }

            float scale;
            if (maxVal <= 0.0f) {
                scale = 0.0f;               // All-black/empty image
            } else if (maxVal <= 1.0f) {
                scale = 65535.0f;            // Normalized [0,1] → [0,65535]
            } else {
                scale = 65535.0f / maxVal;   // Map actual range → [0,65535]
            }

            for (size_t i = 0; i < pixelCount; i++) {
                float v = floatBuf[i] * scale;
                if (v < 0.0f) v = 0.0f;
                if (v > 65535.0f) v = 65535.0f;
                result.pixels[i] = (uint16_t)(v + 0.5f);
            }
        }

        free(floatBuf);
    } else {
        // Integer FITS (BITPIX=8,16,32): use TUSHORT
        // CRITICAL (Lesson L1): Use TUSHORT, not TSHORT!
        // cfitsio automatically applies BZERO=32768 when reading as TUSHORT
        fits_read_img(fptr, TUSHORT, 1, (long)pixelCount, nullptr, result.pixels, &anynull, &status);
    }

    if (status) {
        result.success = 0;
        fits_get_errstatus(status, result.error);
        free(result.pixels);
        result.pixels = nullptr;
        fits_close_file(fptr, &status);
        return result;
    }

    fits_close_file(fptr, &status);
    result.success = 1;
    return result;
}

// ============================================================================
// Header extraction
// ============================================================================

extern "C" HeaderResult read_xisf_headers(const char* path) {
    HeaderResult result;
    memset(&result, 0, sizeof(result));

    try {
        LibXISF::XISFReader reader;
        reader.open(path);

        if (reader.imagesCount() == 0) {
            result.success = 0;
            snprintf(result.error, sizeof(result.error), "XISF file contains no images");
            return result;
        }

        // Read image without pixel data (we only need headers)
        const LibXISF::Image& image = reader.getImage(0, false);

        const auto keywords = image.fitsKeywords();
        // Allocate +2 slots for synthetic NAXIS1/NAXIS2 entries.
        // XISF stores image dimensions in the <Image> element's geometry attribute,
        // not as FITS-style keywords inside <FITSKeyword> elements — so libxisf's
        // fitsKeywords() returns everything EXCEPT NAXIS. We inject them manually
        // from image.width()/image.height() so downstream code (WCS alignment,
        // dimension-aware logic) can read them like any other header value.
        result.count = (int32_t)keywords.size() + 2;
        result.entries = (HeaderEntry*)calloc(result.count, sizeof(HeaderEntry));
        if (!result.entries) {
            result.success = 0;
            snprintf(result.error, sizeof(result.error), "Failed to allocate header entries");
            return result;
        }

        for (size_t i = 0; i < keywords.size(); i++) {
            const auto& kw = keywords[i];
            strncpy(result.entries[i].key, kw.name.c_str(), sizeof(result.entries[i].key) - 1);
            strncpy(result.entries[i].value, kw.value.c_str(), sizeof(result.entries[i].value) - 1);
        }

        // Append synthetic NAXIS1/NAXIS2 entries
        size_t n1 = keywords.size();
        size_t n2 = n1 + 1;
        strncpy(result.entries[n1].key, "NAXIS1", sizeof(result.entries[n1].key) - 1);
        snprintf(result.entries[n1].value, sizeof(result.entries[n1].value), "%d",
                 static_cast<int>(image.width()));
        strncpy(result.entries[n2].key, "NAXIS2", sizeof(result.entries[n2].key) - 1);
        snprintf(result.entries[n2].value, sizeof(result.entries[n2].value), "%d",
                 static_cast<int>(image.height()));

        reader.close();
        result.success = 1;

    } catch (const std::exception& e) {
        if (result.entries) {
            free(result.entries);
            result.entries = nullptr;
        }
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "XISF header error: %.230s", e.what());
    }

    return result;
}

extern "C" HeaderResult read_fits_headers(const char* path) {
    HeaderResult result;
    memset(&result, 0, sizeof(result));

    CFITSIO_LOCK;  // no-op on macOS; serialises on iOS — see top-of-file rationale
    fitsfile* fptr = nullptr;
    int status = 0;

    if (fits_open_diskfile(&fptr, path, READONLY, &status)) {
        result.success = 0;
        fits_get_errstatus(status, result.error);
        return result;
    }

    int nkeys = 0;
    fits_get_hdrspace(fptr, &nkeys, nullptr, &status);

    result.entries = (HeaderEntry*)calloc(nkeys, sizeof(HeaderEntry));
    if (!result.entries) {
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "Failed to allocate header entries");
        fits_close_file(fptr, &status);
        return result;
    }

    int validCount = 0;
    for (int i = 1; i <= nkeys; i++) {
        char keyname[FLEN_KEYWORD];
        char value[FLEN_VALUE];
        char comment[FLEN_COMMENT];

        if (fits_read_keyn(fptr, i, keyname, value, comment, &status)) {
            continue;
        }

        // Skip empty keys and structural keywords
        if (strlen(keyname) == 0 || strcmp(keyname, "END") == 0) continue;

        // Strip single quotes from string values
        char* v = value;
        size_t vlen = strlen(v);
        if (vlen >= 2 && v[0] == '\'') {
            v++;
            vlen -= 2;
            // Trim trailing spaces inside quotes
            while (vlen > 0 && v[vlen - 1] == ' ') vlen--;
            v[vlen] = '\0';
        }

        strncpy(result.entries[validCount].key, keyname, sizeof(result.entries[validCount].key) - 1);
        strncpy(result.entries[validCount].value, v, sizeof(result.entries[validCount].value) - 1);
        validCount++;
    }

    result.count = validCount;
    result.success = 1;
    fits_close_file(fptr, &status);
    return result;
}

// ============================================================================
// FITS header modification — uses cfitsio READWRITE mode
// ============================================================================

extern "C" WriteResult write_fits_keyword(const char* path, const char* keyword, const char* value) {
    WriteResult result;
    memset(&result, 0, sizeof(result));

    CFITSIO_LOCK;  // no-op on macOS; serialises on iOS — see top-of-file rationale
    fitsfile* fptr = nullptr;
    int status = 0;

    if (fits_open_diskfile(&fptr, path, READWRITE, &status)) {
        result.success = 0;
        fits_get_errstatus(status, result.error);
        return result;
    }

    // Update or create string keyword (cfitsio handles both cases)
    if (fits_update_key_str(fptr, keyword, value, nullptr, &status)) {
        result.success = 0;
        fits_get_errstatus(status, result.error);
        fits_close_file(fptr, &status);
        return result;
    }

    fits_close_file(fptr, &status);
    result.success = 1;
    return result;
}

// ============================================================================
// XISF header modification — uses libxisf XISFModify
// ============================================================================

extern "C" WriteResult write_xisf_keyword(const char* path, const char* save_path,
                                           const char* keyword, const char* value) {
    WriteResult result;
    memset(&result, 0, sizeof(result));

    try {
        LibXISF::XISFModify modify;
        modify.open(path);

        // Create FITSKeyword with name, value, and empty comment
        LibXISF::FITSKeyword kw;
        kw.name = keyword;
        kw.value = value;
        kw.comment = "";

        // Update keyword on first image (index 0), add=true creates if missing
        modify.updateFITSKeyword(0, kw, true);

        modify.save(save_path);
        modify.close();

        result.success = 1;

    } catch (const std::exception& e) {
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "XISF write error: %.240s", e.what());
    }

    return result;
}

// ============================================================================
// FITS header keyword deletion — removes keyword entirely
// ============================================================================

extern "C" WriteResult delete_fits_keyword(const char* path, const char* keyword) {
    WriteResult result;
    memset(&result, 0, sizeof(result));

    CFITSIO_LOCK;  // no-op on macOS; serialises on iOS — see top-of-file rationale
    fitsfile* fptr = nullptr;
    int status = 0;

    if (fits_open_diskfile(&fptr, path, READWRITE, &status)) {
        result.success = 0;
        fits_get_errstatus(status, result.error);
        return result;
    }

    // Delete keyword — cfitsio fits_delete_key removes the entire card
    if (fits_delete_key(fptr, keyword, &status)) {
        // KEY_NO_EXIST is not a fatal error — keyword was already absent
        if (status == KEY_NO_EXIST) {
            status = 0;
            result.success = 1;
        } else {
            result.success = 0;
            fits_get_errstatus(status, result.error);
            fits_close_file(fptr, &status);
            return result;
        }
    } else {
        result.success = 1;
    }

    fits_close_file(fptr, &status);
    return result;
}

// ============================================================================
// XISF header keyword deletion — removes keyword via libxisf
// ============================================================================

extern "C" WriteResult delete_xisf_keyword(const char* path, const char* save_path,
                                            const char* keyword) {
    WriteResult result;
    memset(&result, 0, sizeof(result));

    try {
        LibXISF::XISFModify modify;
        modify.open(path);

        // Remove keyword from first image (index 0)
        modify.removeFITSKeyword(0, keyword);

        modify.save(save_path);
        modify.close();

        result.success = 1;

    } catch (const std::exception& e) {
        result.success = 0;
        snprintf(result.error, sizeof(result.error), "XISF delete error: %.240s", e.what());
    }

    return result;
}

// ============================================================================
// Memory cleanup (Lesson L4: caller MUST free C-allocated memory)
// ============================================================================

extern "C" void free_decode_result(DecodeResult* result) {
    if (result && result->pixels) {
        free(result->pixels);
        result->pixels = nullptr;
    }
}

extern "C" void free_header_result(HeaderResult* result) {
    if (result && result->entries) {
        free(result->entries);
        result->entries = nullptr;
    }
}
