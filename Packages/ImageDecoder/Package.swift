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
        // libxisf: C++17 XISF reader with bundled 3rdparty (lz4, pugixml)
        // zstd is NOT included (NINA doesn't use it yet, system dependency optional)
        .target(
            name: "libxisf",
            path: "Sources/libxisf",
            exclude: [],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("3rdparty/lz4"),
                .headerSearchPath("3rdparty/pugixml"),
                .headerSearchPath("include"),
                .define("LIBXISF_STATIC_LIB"),
            ],
            cxxSettings: [
                .headerSearchPath("3rdparty/lz4"),
                .headerSearchPath("3rdparty/pugixml"),
                .headerSearchPath("include"),
                .define("LIBXISF_STATIC_LIB"),
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
