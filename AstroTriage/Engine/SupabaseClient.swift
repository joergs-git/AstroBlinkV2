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
}
