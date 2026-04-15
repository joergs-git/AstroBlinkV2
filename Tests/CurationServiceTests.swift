import XCTest
@testable import AstroTriage

/// Verifies that CurationService.buildEntry maps every relevant field from
/// ImageEntry / FrameRecord into the CuratedFrameEntry upload payload, and
/// that the JSON encoding matches the snake_case column names in the
/// public.curated_frames Supabase table. These tests catch schema drift
/// without touching the slow batch-analysis path — fast, no image I/O.
final class CurationServiceTests: XCTestCase {

    // MARK: - ImageEntry → CuratedFrameEntry

    func testBuildEntryFromImageEntry_populatesAllFields() {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/test_frame.xisf"))
        entry.date = "2026-04-14"
        entry.time = "22:47:31"
        entry.telescope = "RC12red08"
        entry.camera = "ZWO ASI6200MM Pro"
        entry.focalLength = 1964.0
        entry.pixelSizeMicrons = 3.76
        entry.target = "Heart Nebula"
        entry.canonicalTarget = "IC1805"
        entry.filter = "H"
        entry.exposure = 300.0
        entry.gain = 100
        entry.computedFWHM = 3.21
        entry.computedHFR = 2.14
        entry.computedStarCount = 14820
        entry.computedEccentricity = 0.42
        entry.noiseMedian = 0.0234
        entry.noiseMAD = 0.00218
        entry.psfFluxSum = 1_234_567.0
        entry.trailingScore = 0.07
        entry.trailingAxisRatio = 0.94
        entry.moonIllumination = 0.15
        entry.moonDistance = 82.3
        entry.bortleClass = 4.2
        entry.userConfidence = 3

        let payload = CurationService.buildEntry(from: entry, fileHash: "deadbeef1234")

        // Identity
        XCTAssertEqual(payload.file_hash, "deadbeef1234")
        XCTAssertFalse(payload.machine_hash.isEmpty, "machine_hash must be populated from MachineInfo")
        XCTAssertNotNil(payload.setup_hash)

        // Capture timestamp
        XCTAssertEqual(payload.capture_date, "2026-04-14")
        XCTAssertEqual(payload.capture_time, "22:47:31")
        XCTAssertEqual(payload.observing_night, "2026-04-14", "22:47 is pre-midnight → night keeps date")

        // Equipment
        XCTAssertEqual(payload.telescope, "RC12red08")
        XCTAssertEqual(payload.camera, "ZWO ASI6200MM Pro")
        XCTAssertEqual(payload.focal_length_mm, 1964.0)
        XCTAssertEqual(payload.pixel_size_microns, 3.76)

        // Capture parameters
        XCTAssertEqual(payload.target, "Heart Nebula")
        XCTAssertEqual(payload.canonical_target, "IC1805")
        XCTAssertEqual(payload.filter, "H")
        XCTAssertEqual(payload.exposure_s, 300.0)
        XCTAssertEqual(payload.gain, 100)

        // Computed metrics
        XCTAssertEqual(payload.computed_fwhm, 3.21)
        XCTAssertEqual(payload.computed_hfr, 2.14)
        XCTAssertEqual(payload.computed_star_count, 14820)
        XCTAssertEqual(payload.computed_eccentricity, 0.42)
        XCTAssertEqual(payload.noise_median ?? 0, 0.0234, accuracy: 1e-6)
        XCTAssertEqual(payload.noise_mad ?? 0, 0.00218, accuracy: 1e-6)
        XCTAssertEqual(payload.psf_flux, 1_234_567.0)
        XCTAssertEqual(payload.trailing_score, 0.07)
        XCTAssertEqual(payload.trailing_axis_ratio, 0.94)

        // Environment
        XCTAssertEqual(payload.moon_illumination, 0.15)
        XCTAssertEqual(payload.moon_distance, 82.3)
        XCTAssertEqual(payload.bortle_class, 4.2)

        // Ground truth
        XCTAssertEqual(payload.user_confidence, 3)

        // Meta
        XCTAssertEqual(payload.algorithm_version, kAlgorithmVersion)
    }

    /// Different cameras on the same telescope/FL must produce different setup_hash
    /// values. Guards against regressions to the "MM vs MC = same setup" trap.
    func testBuildEntryFromImageEntry_distinctCameraYieldsDistinctSetupHash() {
        var mono = ImageEntry(url: URL(fileURLWithPath: "/tmp/mono.xisf"))
        mono.telescope = "RC12red08"
        mono.camera = "ZWO ASI6200MM Pro"
        mono.focalLength = 1964.0
        mono.pixelSizeMicrons = 3.76
        mono.userConfidence = 2

        var osc = mono
        osc.camera = "ZWO ASI6200MC Pro"

        let monoPayload = CurationService.buildEntry(from: mono, fileHash: "mono-hash")
        let oscPayload = CurationService.buildEntry(from: osc, fileHash: "osc-hash")

        XCTAssertNotNil(monoPayload.setup_hash)
        XCTAssertNotNil(oscPayload.setup_hash)
        XCTAssertNotEqual(monoPayload.setup_hash, oscPayload.setup_hash,
                          "Swapping camera (same telescope/FL/pixel size) must yield a distinct setup fingerprint")
    }

    // MARK: - JSON encoding / snake_case schema contract

    /// Every key emitted by JSONEncoder must match the actual column names in
    /// the Supabase public.curated_frames table. If someone renames a Swift
    /// field and forgets the migration, this test fires. The reference set
    /// here MUST match the CREATE TABLE in
    /// supabase/migrations/20260414_create_curated_frames.sql.
    func testJSONKeysMatchSupabaseSchema() throws {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/schema.xisf"))
        entry.userConfidence = 1

        let payload = CurationService.buildEntry(from: entry, fileHash: "schema-test")
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let emittedKeys = Set(json.keys)

        // Must-have columns — these are non-nullable in the schema.
        let required: Set<String> = [
            "file_hash", "machine_hash", "user_confidence", "algorithm_version"
        ]
        XCTAssertTrue(required.isSubset(of: emittedKeys),
                      "Missing required columns: \(required.subtracting(emittedKeys))")

        // Full expected column set — every field on CuratedFrameEntry maps 1:1
        // to a column in the Supabase schema. Keep this list in sync with the
        // migration file if columns are added/removed.
        let expected: Set<String> = [
            "file_hash", "machine_hash", "setup_hash",
            "filename", "capture_date", "capture_time", "observing_night",
            "telescope", "camera", "focal_length_mm", "pixel_size_microns",
            "target", "canonical_target", "filter", "exposure_s", "gain",
            "computed_fwhm", "computed_hfr", "computed_star_count", "computed_eccentricity",
            "noise_median", "noise_mad", "psf_flux",
            "trailing_score", "trailing_axis_ratio",
            "moon_illumination", "moon_distance", "bortle_class", "twilight_phase",
            "quality_tier", "combined_z_score", "garbage_reasons",
            "user_confidence", "quality_feedback",
            "algorithm_version", "app_version"
        ]

        // JSONEncoder omits nil values by default, so we can't assert keys == expected.
        // We assert that every emitted key IS in the expected set — i.e. no stray
        // fields leaking that the Supabase schema doesn't know about.
        let unexpected = emittedKeys.subtracting(expected)
        XCTAssertTrue(unexpected.isEmpty,
                      "CurationService emitted keys not in the Supabase schema: \(unexpected). Either add the column via migration or remove the field from CuratedFrameEntry.")
    }

    /// Required fields must always be present in the JSON even when the source
    /// ImageEntry has almost nothing populated.
    func testJSONContainsRequiredFieldsWithMinimalInput() throws {
        var entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/minimal.xisf"))
        entry.userConfidence = 2

        let payload = CurationService.buildEntry(from: entry, fileHash: "min-hash")
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["file_hash"] as? String, "min-hash")
        XCTAssertEqual(json["user_confidence"] as? Int, 2)
        XCTAssertEqual(json["algorithm_version"] as? Int, kAlgorithmVersion)
        XCTAssertNotNil(json["machine_hash"])
        // setup_hash is always computed (SetupFingerprint hashes "unknown" for missing fields).
        XCTAssertNotNil(json["setup_hash"])
    }
}
