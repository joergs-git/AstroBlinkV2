// CLI-only stubs — compiled ONLY into the AstroScoreCLI target.
//
// QualityEstimator+Historical.swift (Stage 1.5b) statically references FrameHistoryDatabase
// and ColorCombineEngine to BUILD historical baselines from the app's SQLite DB. Those two
// types are GUI/DB-coupled (GRDB DB access; SwiftUI-importing filter engine) and deliberately
// excluded from the headless CLI. The historical stage is never INVOKED here — the CLI scores
// each folder as its own isolated group with no historical baselines passed — so these stubs
// only need to satisfy the compiler, not do real work.
//
// This keeps the quality-critical scoring files 100% untouched (the app links the real
// FrameHistoryDatabase / ColorCombineEngine; only the CLI sees these no-op stubs), which is
// exactly the Phase-0 guarantee of "no scoring change".

import Foundation

/// No-op stand-in for the app's SQLite frame-history store. Returns no historical records, so
/// Stage 1.5b finds no baseline and does nothing — identical to a fresh install with no scan.
final class FrameHistoryDatabase {
    static let shared = FrameHistoryDatabase()
    private init() {}

    func historicalFramesByEquipment(telescope: String, camera: String) throws -> [FrameRecord] { [] }
    func historicalFramesByTarget(canonicalTarget: String) throws -> [FrameRecord] { [] }
}

/// Minimal stand-in for the filter-name canonicalizer. Identity mapping is sufficient because
/// it is only used inside the (inactive) historical baseline grouping.
enum ColorCombineEngine {
    static func canonicalFilterName(_ raw: String) -> String { raw }
}

/// No-op stand-in for the Supabase-backed community-floor service. QualityEstimator only calls
/// `meetsCommunityFloor` when a non-nil `communityBaseline` is passed; the CLI never passes one,
/// so this is never invoked. Returns false (no community lock).
final class CommunityDetectionService {
    static func meetsCommunityFloor(entry: ImageEntry, baseline: CommunityBaseline) -> Bool { false }
}
