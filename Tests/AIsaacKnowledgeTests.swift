import XCTest
@testable import AstroTriage

/// Validates that AIsaac's system prompt and context stay in sync with app logic.
/// This test catches knowledge drift — when detection rules, garbage reasons, or
/// quality pipeline stages change but AIsaac's prompt isn't updated to match.
final class AIsaacKnowledgeTests: XCTestCase {

    // MARK: - System Prompt Coverage

    /// Every GarbageReason enum case must be documented in AIsaac's system prompt.
    /// When a new garbage reason is added, this test forces updating the prompt.
    /// Uses distinctive keyword per reason (not exact rawValue) to allow natural language.
    func testAllGarbageReasonsDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge.lowercased()

        // Map each GarbageReason to a distinctive keyword that must appear in the prompt
        let reasonKeywords: [(GarbageReason, String)] = [
            (.noData, "no signal"),
            (.noStars, "zero stars"),
            (.decenteredTarget, "decentered"),
            (.lowSNR, "low snr"),
            (.highFWHM, "high fwhm"),
            (.highHFR, "high hfr"),
            (.elongated, "elongat"),
            (.starCountAnomaly, "doubled stars"),
            (.backgroundAnomaly, "background anomal"),
            (.trackingHop, "tracking hop"),
            (.twilightExposure, "twilight"),
        ]

        for (reason, keyword) in reasonKeywords {
            XCTAssertTrue(
                prompt.contains(keyword),
                "AIsaac system prompt missing garbage reason \(reason): keyword \"\(keyword)\" not found. " +
                "Update AIsaacContextBuilder.appKnowledge when adding new GarbageReason cases."
            )
        }
    }

    /// All 4 quality tiers must be documented in the prompt.
    func testAllQualityTiersDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge

        let tiers = ["Excellent", "Good", "Borderline", "Trash"]
        for tier in tiers {
            XCTAssertTrue(prompt.contains(tier),
                          "AIsaac prompt missing quality tier: \(tier)")
        }
    }

    /// All TwilightPhase categories must be documented in the prompt.
    func testAllTwilightPhasesDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge.lowercased()

        // Keywords that must appear for each twilight phase
        let phaseKeywords = ["night", "astro twilight", "nautical", "civil", "daylight"]
        for keyword in phaseKeywords {
            XCTAssertTrue(prompt.contains(keyword),
                          "AIsaac prompt missing twilight phase keyword: \"\(keyword)\"")
        }
    }

    /// Key quality pipeline concepts must be mentioned in the prompt.
    func testKeyConceptsDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge

        let concepts = [
            "Stage 1",          // Garbage detection
            "Stage 2",          // Z-score ranking
            "Stage 3",          // Rescue rules
            "Stage 4",          // Sanity check
            "FL-adaptive",      // or "focal-length-adaptive"
            "baseline",         // FL baseline for eccentricity
            "consensus",        // Trailing consensus
            "multiple",         // Multiple garbage reasons
            "plate-solved",     // Decentered target needs plate solve
            "SSWEIGHT",         // Quality weight export
            "calibration",      // Self-calibration
        ]

        for concept in concepts {
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains(concept),
                          "AIsaac prompt missing key concept: \"\(concept)\"")
        }
    }

    /// User guide section must cover all major app features.
    func testUserGuideCoversAllFeatures() {
        let prompt = AIsaacContextBuilder.appKnowledge.lowercased()

        let features = [
            "stretch mode",         // Auto vs Locked stretch
            "pre-delete",           // Pre-delete workflow
            "compare view",         // C key comparison
            "header inspector",     // I key
            "night mode",           // N key
            "debayer",              // D key for OSC
            "culling autopilot",    // Auto-mark popover
            "color combine",        // Mono filter stacking
            "lightspeedstacker",    // GPU stacking
            "quicklook",            // Finder preview
            "context menu",         // Right-click
            "preview window",       // Double-click floating window
            "multi-select",         // Shift/Cmd-click
            "recommended workflow", // Best practices
        ]

        for feature in features {
            XCTAssertTrue(prompt.contains(feature),
                          "AIsaac USER GUIDE missing feature: \"\(feature)\"")
        }
    }

    /// Filter-aware trailing penalty must be documented in the prompt.
    func testFilterAwareTrailingDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge.lowercased()

        XCTAssertTrue(prompt.contains("filter-aware"),
                      "AIsaac prompt must mention 'filter-aware' trailing penalty")
        XCTAssertTrue(prompt.contains("narrowband") && prompt.contains("0.3"),
                      "AIsaac prompt must document narrowband trailing multiplier 0.3")
        XCTAssertTrue(prompt.contains("luminance") && prompt.contains("1.0"),
                      "AIsaac prompt must document luminance trailing multiplier 1.0")
    }

    /// New features (v5.7.0+) must be documented in AIsaac's knowledge.
    func testNewFeaturesDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge.lowercased()

        let features = [
            "frame history database",   // Frame History DB
            "archive scanner",          // NAS/archive scanning
            "history chart",            // Chart window
            "bortle",                   // Bortle sky quality
            "target cluster",           // Target name normalization
            "moon%",                    // Moon illumination column
            "moondist",                 // Moon distance column
            "algorithm version",        // Algorithm versioning
            "icloud",                   // iCloud backup
        ]

        for feature in features {
            XCTAssertTrue(prompt.contains(feature),
                          "AIsaac prompt missing v5.7.0 feature: \"\(feature)\"")
        }
    }

    /// v5.14.0 target-aware scoring features must be documented in AIsaac's knowledge.
    func testTargetAwareScoringDocumentedInPrompt() {
        let prompt = AIsaacContextBuilder.appKnowledge.lowercased()

        let concepts = [
            "target-aware",         // Target-aware quality scoring
            "target type",          // Type-based weights
            "mad floor",            // Practical significance floor
            "planet",               // Planet exclusion
            "solar system",         // Solar system exclusion
            "fov fill",             // FOV fill ratio modulation
        ]

        for concept in concepts {
            XCTAssertTrue(prompt.contains(concept),
                          "AIsaac prompt missing v5.14.0 concept: \"\(concept)\"")
        }
    }

    // MARK: - Frame Data Completeness

    /// The per-frame CSV header in AIsaac context must include all metric columns.
    func testFrameDataHeaderComplete() {
        let prompt = AIsaacContextBuilder.appKnowledge

        // The CSV header is defined in buildPerFrameSection — check it indirectly
        // by verifying the prompt mentions all metrics AIsaac needs
        let metrics = ["FWHM", "HFR", "SNR", "MAD", "Eccentricity", "Trailing", "twilight"]
        for metric in metrics {
            XCTAssertTrue(prompt.localizedCaseInsensitiveContains(metric),
                          "AIsaac prompt missing metric explanation: \"\(metric)\"")
        }
    }
}
