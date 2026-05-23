// JSON-serializable output types for read-only MCP tools.
//
// Deliberately decoupled from the app's FrameRecord / SessionRecord / AstroRoot
// types: those live in the AstroTriage target and importing them across targets
// would require extracting a shared SPM module. For V1 we trade ~150 LOC of
// model duplication for a clean target boundary; if the duplication becomes
// painful, extract into `Packages/FrameHistoryCore/`.
//
// All numeric metrics are made optional to allow rows with NULLs (frames that
// failed analysis, partial scans, etc.) to round-trip cleanly through JSON.
import Foundation

struct MCPAstroRoot: Codable {
    let id: Int64
    let path: String
    let setupTag: String?
    let nickname: String?
    let displayName: String
    let createdAt: String
    let lastUsedAt: String?
}

struct MCPSetup: Codable {
    let setupHash: String
    let nickname: String?
    let telescope: String?
    let camera: String?
    let focalLengthMm: Double?
    let frameCount: Int
    let firstNight: String?
    let lastNight: String?
}

struct MCPNightSummary: Codable {
    let night: String
    let target: String?
    let filter: String?
    let frameCount: Int
    let trashCount: Int
    let medianFWHM: Double?
    let medianHFR: Double?
    let medianStars: Int?
    let medianNoiseMAD: Double?
    let medianTrailing: Double?
    let totalIntegrationSeconds: Double
    let medianAmbientTemp: Double?
    let medianMoonIllumination: Double?
}

struct MCPSession: Codable {
    let id: String
    let observingNight: String?
    let setupHash: String?
    let telescope: String?
    let camera: String?
    let target: String?
    let frameCount: Int
    let trashCount: Int
    let deletedCount: Int
    let recordedAt: String
}

struct MCPSetupSummary: Codable {
    let setupHash: String
    let nickname: String?
    let telescope: String?
    let camera: String?
    let focalLengthMm: Double?
    let totalFrames: Int
    let sessionCount: Int
    let distinctTargets: Int
    let firstNight: String?
    let lastNight: String?
    let medianFWHM: Double?
    let medianHFR: Double?
    let trashRatePct: Double
}

struct MCPTargetIntegration: Codable {
    let filter: String
    let totalSeconds: Double
    let totalMinutes: Double
    let totalHours: Double
    let frameCount: Int
    let goodOrExcellentCount: Int
}

struct MCPFrame: Codable {
    let fileHash: String
    let shortId: String?
    let filename: String
    let filePath: String
    let observingNight: String?
    let target: String?
    let filter: String?
    let exposure: Double?
    let setupHash: String?
    let qualityTier: Int?
    let combinedZScore: Double?
    let computedFWHM: Double?
    let computedHFR: Double?
    let computedStarCount: Int?
    let trailingScore: Double?
    let garbageReasons: String?
    let wasDeleted: Bool
    let isLockedKeep: Bool
}

/// Standard wrapper for tool responses that may contain a result or a structured error.
/// Encoded as JSON in the MCP `text` content.
struct MCPToolResponse<T: Codable>: Codable {
    let ok: Bool
    let data: T?
    let error: String?

    static func success(_ data: T) -> MCPToolResponse<T> {
        .init(ok: true, data: data, error: nil)
    }

    static func failure(_ msg: String) -> MCPToolResponse<T> {
        .init(ok: false, data: nil, error: msg)
    }
}
