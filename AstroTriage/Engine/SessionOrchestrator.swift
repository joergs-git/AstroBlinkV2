// Session-lifecycle orchestrator extracted from TriageViewModel.
//
// Will own the methods that load images into a session, drive header
// enrichment, kick off scoring + SNR-retention recomputation, and hand
// mosaic generation to the VLM check. This is the second slice toward
// smaller, more focused state holders (PlaybackController was first).
//
// The orchestrator does NOT own @Published UI state. It mutates the
// host's state through a narrow SessionHost protocol so existing
// SwiftUI bindings continue to work unchanged while the methods are
// migrated step by step.
//
// Step 1: skeleton + protocol seam only. No behavior moved yet —
// validates the host-protocol pattern compiles and lifetime is sane.
import Foundation

/// State and actions on TriageViewModel that the SessionOrchestrator
/// needs to read, mutate, or invoke. Class-bound so the orchestrator
/// can hold the host weakly and avoid a retain cycle (host owns the
/// orchestrator strongly).
///
/// The surface starts narrow and grows in subsequent slices as more
/// methods migrate. Anything still living on TriageViewModel that the
/// orchestrator needs to touch goes through here.
@MainActor
protocol SessionHost: AnyObject {
    // Session identity / state
    var images: [ImageEntry] { get set }
    var sessionRootURL: URL? { get set }
    var currentSessionId: String { get set }
    var communityBaseline: CommunityBaseline? { get set }
    var currentSetupFingerprint: SetupFingerprint? { get }

    // Loading status
    var isLoading: Bool { get set }
    var loadingPhase: TriageViewModel.LoadingPhase { get set }
    var statusMessage: String { get set }
    var needsTableRefresh: Bool { get set }
    var needsScrollToTop: Bool { get set }
    var hasOSCImages: Bool { get set }

    // Session-load actions performed on the host
    func selectImage(at index: Int)
    func assignSessionIndices()
    func displayCurrentImage()
    func focusTableAfterDelay()
    func triggerApplyAll()
    func checkForReviewPrompt()
}

@MainActor
final class SessionOrchestrator {
    /// Back-reference to the owner. Weak: the host owns this orchestrator
    /// strongly via `let orchestrator: SessionOrchestrator`.
    weak var host: SessionHost?

    // Long-lived dependencies the orchestrator drives directly. Held
    // strongly here once methods migrate; for now they're injected so
    // the wiring in TriageViewModel.init() is established up front.
    private let prefetchCache: PrefetchCache?
    private let benchmarkStats: BenchmarkStats
    private let benchmarkService: BenchmarkService
    private let sessionCache: SessionCache
    private let sessionOverviewModel: SessionOverviewModel
    private let displayAligner: DisplayAligner

    init(
        prefetchCache: PrefetchCache?,
        benchmarkStats: BenchmarkStats,
        benchmarkService: BenchmarkService,
        sessionCache: SessionCache,
        sessionOverviewModel: SessionOverviewModel,
        displayAligner: DisplayAligner
    ) {
        self.prefetchCache = prefetchCache
        self.benchmarkStats = benchmarkStats
        self.benchmarkService = benchmarkService
        self.sessionCache = sessionCache
        self.sessionOverviewModel = sessionOverviewModel
        self.displayAligner = displayAligner
    }

    /// Wire up the back-reference after the host has finished its own
    /// initialization. Called once from TriageViewModel.init().
    func attach(host: SessionHost) {
        self.host = host
    }
}
