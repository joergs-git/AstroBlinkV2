// v1.0.0
import Foundation
import ImageDecoderBridge

// Reads raw FITS/XISF header keywords from file via C bridge
struct MetadataExtractor {

    // Read raw headers from file (XISF or FITS)
    static func readHeaders(from url: URL) -> [String: String] {
        let path = url.path
        var headerDict: [String: String] = [:]

        let result: HeaderResult
        if url.pathExtension.lowercased() == "xisf" {
            result = read_xisf_headers(path)
        } else {
            result = read_fits_headers(path)
        }

        if result.success != 0, let entries = result.entries {
            for i in 0..<Int(result.count) {
                let key = withUnsafePointer(to: entries[i].key) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                let value = withUnsafePointer(to: entries[i].value) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                headerDict[key.trimmingCharacters(in: .whitespaces)] = value.trimmingCharacters(in: .whitespaces)
            }
        }

        // Free C-allocated memory
        var mutableResult = result
        free_header_result(&mutableResult)

        return headerDict
    }
}
