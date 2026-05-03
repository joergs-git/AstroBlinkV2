// Single point of truth for Supabase URL building and request setup.
// All call sites should go through this helper instead of touching
// BenchmarkConfig.supabaseURL/.supabaseAnonKey directly. Key rotation
// or region migration then requires only one edit.
//
// BenchmarkConfig stays as the underlying constant store — this helper
// reads from it. The helper does not own state.

import Foundation

enum SupabaseClient {

    /// True if BenchmarkConfig has real values (not the YOUR_PROJECT placeholders).
    static var isConfigured: Bool { BenchmarkConfig.isConfigured }

    /// Build identifier sent as `X-App-Version` on every request, e.g.
    /// "AstroBlinkV2/6.0.0 (89)". Used server-side for telemetry / debugging.
    static let appVersionHeader: String = {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "AstroBlinkV2/\(version) (\(build))"
    }()

    // MARK: - URL builders

    /// Build a `/rest/v1/<table>` URL with an optional URL-encoded query string.
    /// Returns nil if the underlying config is missing or the URL is invalid.
    static func restURL(table: String, query: String? = nil) -> URL? {
        guard isConfigured else { return nil }
        var s = "\(BenchmarkConfig.supabaseURL)/rest/v1/\(table)"
        if let q = query, !q.isEmpty {
            s += s.contains("?") ? "&\(q)" : "?\(q)"
        }
        return URL(string: s)
    }

    /// Build a `/functions/v1/<name>` URL for an Edge Function.
    static func functionURL(_ name: String) -> URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(BenchmarkConfig.supabaseURL)/functions/v1/\(name)")
    }

    // MARK: - Request setup

    /// Build a URLRequest with the standard `apikey` header, an `X-Device-Id` header
    /// (the anonymous machine hash — used by RLS policies that bind rows to a device),
    /// and (optionally) a Bearer `Authorization` header for write paths.
    /// Caller is responsible for setting Content-Type / Prefer / body for the operation.
    ///
    /// The X-Device-Id header is harmless on public-read endpoints (bortle_grid, target_catalog, …)
    /// and essential on RLS-protected UPDATE paths (curated_frames, message_interactions) where
    /// the policy enforces `machine_hash = request.headers ->> 'x-device-id'`.
    static func makeRequest(url: URL, method: String = "GET", withBearer: Bool = false) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(BenchmarkConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        r.setValue(MachineInfo.machineHash, forHTTPHeaderField: "x-device-id")
        r.setValue(appVersionHeader, forHTTPHeaderField: "X-App-Version")
        if withBearer {
            r.setValue("Bearer \(BenchmarkConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    /// Convenience for JSON POSTs into a `/rest/v1/<table>` endpoint.
    /// Sets apikey + Bearer + Content-Type:application/json + Prefer header.
    /// Returns nil if the URL/config is missing.
    static func jsonInsertRequest(table: String, prefer: String = "return=minimal", withBearer: Bool = true) -> URLRequest? {
        guard let url = restURL(table: table) else { return nil }
        var r = makeRequest(url: url, method: "POST", withBearer: withBearer)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(prefer, forHTTPHeaderField: "Prefer")
        return r
    }

    /// Convenience for JSON POSTs against an Edge Function.
    /// Sets apikey + Bearer + Content-Type:application/json. Caller fills in body + extras.
    static func functionRequest(_ name: String, withBearer: Bool = true) -> URLRequest? {
        guard let url = functionURL(name) else { return nil }
        var r = makeRequest(url: url, method: "POST", withBearer: withBearer)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    // MARK: - Transport

    /// Transport-level errors surfaced by `send(...)`. Note: HTTP status codes (4xx/5xx)
    /// are NOT thrown — they are returned as `(data, response)` so callers can decide
    /// how to map them (e.g. 429 → rate-limit, 404 → empty result, 5xx → user error).
    /// Only network/decoding/cancellation level failures throw.
    enum SupabaseError: Error, LocalizedError {
        /// BenchmarkConfig still holds placeholders — Supabase URL/key not set.
        case notConfigured
        /// `URLError` from URLSession (DNS, TLS, timeout, lost connection, etc.).
        case network(URLError)
        /// Task was cancelled by the caller (Task cancellation or URLError.cancelled).
        case cancelled
        /// Server response was not an HTTPURLResponse (extremely rare).
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Supabase is not configured."
            case .network(let e): return "Network error: \(e.localizedDescription)"
            case .cancelled: return "Request was cancelled."
            case .invalidResponse: return "Server returned a non-HTTP response."
            }
        }
    }

    /// Send a Supabase request through `URLSession.shared.data(for:)` with a
    /// per-call timeout and optional retry on transient failures.
    ///
    /// **What retries:** transport errors (timeout, DNS, lost connection) and
    /// transient 5xx (502/503/504). Backoff is 200 ms, 400 ms, 800 ms (capped at 2 s).
    ///
    /// **What does NOT retry:** 4xx, non-transient 5xx (500/501/505), and
    /// `URLError.cancelled` (caller stopped the task on purpose).
    ///
    /// **Default `retries` is 0** — opt in only when the operation is idempotent.
    /// Mutating POSTs without server-side dedup should keep the default; reads,
    /// upserts (`Prefer: resolution=merge-duplicates`) and DELETEs are safe to retry.
    ///
    /// - Parameters:
    ///   - request: a request built via `makeRequest`/`jsonInsertRequest`/`functionRequest`.
    ///     Its `timeoutInterval` is overridden by `timeout`.
    ///   - timeout: per-call timeout in seconds. Default 30 s.
    ///   - retries: additional attempts after the first failure. Default 0 (no retry).
    /// - Returns: tuple of response body data and the `HTTPURLResponse` (any status code).
    /// - Throws: `SupabaseError` on transport-level failures or after retries are exhausted.
    static func send(
        _ request: URLRequest,
        timeout: TimeInterval = 30,
        retries: Int = 0
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var req = request
        req.timeoutInterval = timeout

        let maxAttempts = max(1, retries + 1)
        var attempt = 0
        var lastError: SupabaseError = .invalidResponse

        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw SupabaseError.invalidResponse
                }
                // Retry only on transient gateway-class 5xx; pass everything else through.
                if attempt < maxAttempts && isTransient5xx(http.statusCode) {
                    try await backoff(attempt: attempt)
                    continue
                }
                return (data, http)
            } catch let urlError as URLError {
                if urlError.code == .cancelled {
                    throw SupabaseError.cancelled
                }
                lastError = .network(urlError)
                if attempt < maxAttempts && isRetryable(urlError) {
                    try await backoff(attempt: attempt)
                    continue
                }
                throw lastError
            } catch let supa as SupabaseError {
                throw supa
            } catch {
                // Defensive: URLSession only throws URLError, but wrap anything else.
                throw SupabaseError.network(URLError(.unknown))
            }
        }
        throw lastError
    }

    private static func isTransient5xx(_ status: Int) -> Bool {
        status == 502 || status == 503 || status == 504
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff: 200 ms, 400 ms, 800 ms, capped at 2 s.
    private static func backoff(attempt: Int) async throws {
        let delayMs = min(2000, 200 * (1 << (attempt - 1)))
        try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
    }
}
