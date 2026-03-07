#ifndef IMAGE_DECODER_BRIDGE_H
#define IMAGE_DECODER_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Decoded image result returned from decode functions
typedef struct {
    uint16_t* pixels;       // Caller-owned pixel data (uint16, row-major)
    int32_t width;
    int32_t height;
    int32_t channelCount;   // 1=mono, 3=RGB (planar: R plane, G plane, B plane)
    int success;            // 1=ok, 0=error
    char error[256];        // Error message if success==0
} DecodeResult;

// Header key-value pair
typedef struct {
    char key[80];           // FITS keyword (max 8 chars) or XISF property name
    char value[256];        // String representation of the value
} HeaderEntry;

// Header extraction result
typedef struct {
    HeaderEntry* entries;   // Array of header entries
    int32_t count;          // Number of entries
    int success;
    char error[256];
} HeaderResult;

// Decode XISF file to uint16 pixel data
DecodeResult decode_xisf(const char* path);

// Decode FITS file to uint16 pixel data (uses TUSHORT for correct BZERO handling)
DecodeResult decode_fits(const char* path);

// Extract headers from XISF file
HeaderResult read_xisf_headers(const char* path);

// Extract headers from FITS file
HeaderResult read_fits_headers(const char* path);

// Free pixel data returned by decode functions
void free_decode_result(DecodeResult* result);

// Free header entries returned by read_*_headers functions
void free_header_result(HeaderResult* result);

#ifdef __cplusplus
}
#endif

#endif // IMAGE_DECODER_BRIDGE_H
