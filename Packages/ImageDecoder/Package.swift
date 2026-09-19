// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageDecoder",
    // Shared between macOS app (AstroBlinkV2) and iOS app (AstroFileViewer).
    // The iOS project references this package via `path: ../Packages/ImageDecoder`
    // — there is intentionally no second copy under AstroFileViewer-iOS/Packages/.
    platforms: [.macOS("13.3"), .iOS("16.4")],
    products: [
        .library(name: "ImageDecoderBridge", targets: ["ImageDecoderBridge"])
    ],
    targets: [
        // libxisf: C++17 XISF reader with bundled 3rdparty (lz4, pugixml, zstd)
        //
        // zstd is vendored (3rdparty/zstd, see its README) because XISF 1.0 Revision 1
        // (September 2026) made `zstd` / `zstd+sh` standard codecs — the recommended ones,
        // and what PixInsight 1.9.5 writes. Apple ships no public libzstd, so it has to be
        // built in. HAVE_ZSTD switches libxisf's zstd paths on; ZSTD_DISABLE_ASM selects the
        // C decoder because the x86-64 assembly file is not vendored.
        .target(
            name: "libxisf",
            path: "Sources/libxisf",
            exclude: [],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("3rdparty/lz4"),
                .headerSearchPath("3rdparty/pugixml"),
                .headerSearchPath("3rdparty/zstd"),
                .headerSearchPath("include"),
                .define("LIBXISF_STATIC_LIB"),
                .define("ZSTD_DISABLE_ASM"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            ],
            cxxSettings: [
                .headerSearchPath("3rdparty/lz4"),
                .headerSearchPath("3rdparty/pugixml"),
                .headerSearchPath("3rdparty/zstd"),
                .headerSearchPath("include"),
                .define("LIBXISF_STATIC_LIB"),
                .define("HAVE_ZSTD"),
            ],
            linkerSettings: [
                .linkedLibrary("z") // system zlib
            ]
        ),

        // cfitsio: NASA FITS reader (C library) with fpack support
        .target(
            name: "cfitsio",
            path: "Sources/cfitsio",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("HAVE_UNISTD_H"),
                .define("HAVE_LONGLONG"),
                // HAVE_NET_SERVICES intentionally NOT defined — disables ROOT/XRootD,
                // HTTP, and FTP drivers which we don't need and whose init() would fail.
                //
                // _REENTRANT is macOS-only on purpose. On macOS it activates
                // cfitsio's internal FFLOCK/FFUNLOCK pthread locks so the bridge
                // can decode different files concurrently. On iOS the same flag
                // produced a driver double-registration; we serialise instead via
                // an external std::mutex inside ImageDecoderBridge.cpp (CFITSIO_LOCK).
                // Keep the two strategies in lockstep with the bridge — see the
                // top-of-file comment in ImageDecoderBridge.cpp.
                .define("_REENTRANT", .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),

        // Bridge: thin C API wrapping libxisf + cfitsio for Swift consumption
        .target(
            name: "ImageDecoderBridge",
            dependencies: ["libxisf", "cfitsio"],
            path: "Sources/ImageDecoderBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../libxisf/include"),
                .headerSearchPath("../cfitsio/include"),
                .define("LIBXISF_STATIC_LIB"),
            ]
        ),

        .testTarget(
            name: "ImageDecoderTests",
            dependencies: ["ImageDecoderBridge"],
            path: "Tests/ImageDecoderTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
