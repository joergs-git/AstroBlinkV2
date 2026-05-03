// In-App Messaging Service — fetches messages from Supabase, evaluates targeting,
// tracks interactions, manages entitlements. Follows BenchmarkSharing/CommunityDetectionService pattern.
//
// Privacy: Only machine_hash (anonymous hardware UUID hash) is sent. No personal data
// unless the user voluntarily provides an email address.

import Foundation

// MARK: - App Message Service

final class AppMessageService {

    static let shared = AppMessageService()

    // Cache directory: ~/Library/Application Support/AstroBlinkV2/Messages/
    private let cacheDirectory: URL
    private let fetchIntervalSeconds: TimeInterval = 86_400  // 24 hours

    // In-memory state (loaded from cache on init, refreshed from Supabase)
    private var cachedMessages: [AppMessage] = []
    private var cachedInteractions: [String: MessageInteraction] = [:]  // keyed by message_id
    private var cachedEntitlements: [DeviceEntitlement] = []
    private var lastFetchDate: Date?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("AstroBlinkV2/Messages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Load cached data immediately (so banner can show before network completes)
        loadCachedState()
    }

    // MARK: - Public API

    /// Check for messages, fetch from Supabase if stale, return highest-priority matching message.
    /// Called on app launch and periodically from TriageViewModel.
    func checkForMessages() async -> AppMessage? {
        guard SupabaseClient.isConfigured else { return nil }

        // Fetch from network if stale
        let needsFetch = lastFetchDate == nil ||
            Date().timeIntervalSince(lastFetchDate!) > fetchIntervalSeconds
        if needsFetch {
            await fetchAll()
        }

        return evaluateAndPickMessage()
    }

    /// Get all current entitlements for this device (cached).
    func currentEntitlements() -> [DeviceEntitlement] {
        cachedEntitlements.filter { $0.isValid }
    }

    /// Check if device has a specific valid entitlement.
    func hasEntitlement(_ name: String) -> Bool {
        cachedEntitlements.contains { $0.entitlement == name && $0.isValid }
    }

    /// Get entitlement value (e.g. aisaac_boost daily limit).
    func entitlementValue(_ name: String) -> String? {
        cachedEntitlements.first { $0.entitlement == name && $0.isValid }?.value
    }

    /// Record that a message was shown to the user (impression tracking).
    func recordImpression(messageId: String) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.upsertImpression(messageId: messageId)
        }
    }

    /// User dismissed the message (X button).
    func dismiss(messageId: String) async {
        let now = MessageInteraction.nowString
        await upsertInteraction(messageId: messageId, updates: [
            "dismissed_at": now,
            "last_shown_at": now
        ])
        // Update local cache
        if var interaction = cachedInteractions[messageId] {
            interaction.dismissed_at = now
            cachedInteractions[messageId] = interaction
        }
        saveCachedState()
    }

    /// User chose "later" — snooze for message's snooze_hours.
    func snooze(messageId: String) async {
        let message = cachedMessages.first { $0.id == messageId }
        let hours = message?.snooze_hours ?? 168
        let snoozedUntil = Date().addingTimeInterval(TimeInterval(hours * 3600))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snoozedString = formatter.string(from: snoozedUntil)
        let now = MessageInteraction.nowString

        await upsertInteraction(messageId: messageId, updates: [
            "snoozed_until": snoozedString,
            "action_type": "later",
            "responded_at": now,
            "last_shown_at": now
        ])
        // Update local cache
        if var interaction = cachedInteractions[messageId] {
            interaction.snoozed_until = snoozedString
            interaction.action_type = "later"
            interaction.responded_at = now
            cachedInteractions[messageId] = interaction
        }
        saveCachedState()
    }

    /// User responded with an action (yes/no, email, radio, slider, text).
    func respond(messageId: String, actionType: String, value: String?) async {
        let now = MessageInteraction.nowString
        var updates: [String: String] = [
            "action_type": actionType,
            "responded_at": now,
            "last_shown_at": now
        ]
        if let value { updates["response_value"] = value }

        await upsertInteraction(messageId: messageId, updates: updates)

        // Update local cache
        if var interaction = cachedInteractions[messageId] {
            interaction.action_type = actionType
            interaction.response_value = value
            interaction.responded_at = now
            cachedInteractions[messageId] = interaction
        }
        saveCachedState()

        // If email was submitted, refresh entitlements (trigger will have granted them)
        if actionType == "email_input" && value != nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s for trigger to execute
            await fetchEntitlements()
        }
    }

    // MARK: - Targeting Evaluation

    /// Evaluate all cached messages against targeting criteria and return the highest-priority match.
    private func evaluateAndPickMessage() -> AppMessage? {
        let context = buildTargetingContext()
        let now = Date()

        let matching = cachedMessages.filter { msg in
            evaluateTargeting(message: msg, context: context, now: now)
        }

        // Sort by priority descending, then created_at descending
        return matching.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return (a.created_at ?? "") > (b.created_at ?? "")
        }.first
    }

    private func evaluateTargeting(message msg: AppMessage, context: TargetingContext, now: Date) -> Bool {
        // Platform check
        if msg.platform != "all" && msg.platform != context.platform { return false }

        // Version check
        if let minV = msg.min_app_version {
            if SemverCompare.compare(context.appVersion, minV) == .orderedAscending { return false }
        }
        if let maxV = msg.max_app_version {
            if SemverCompare.compare(context.appVersion, maxV) == .orderedDescending { return false }
        }

        // Usage check
        if let minS = msg.min_session_count, context.sessionCount < minS { return false }
        if let minF = msg.min_frame_count, context.frameCount < minF { return false }
        if let maxF = msg.max_frame_count, context.frameCount > maxF { return false }

        // Date range
        if let starts = msg.startsAtDate, now < starts { return false }
        if let expires = msg.expiresAtDate, now > expires { return false }

        // Entitlement-based targeting
        if let req = msg.requires_entitlement, !hasEntitlement(req) { return false }
        if let exc = msg.excludes_entitlement, hasEntitlement(exc) { return false }

        // Response-based targeting
        if let reqResp = msg.requires_response_to {
            let responded = cachedInteractions[reqResp]?.responded_at != nil
            if !responded { return false }
        }
        if let excResp = msg.excludes_response_to {
            let responded = cachedInteractions[excResp]?.responded_at != nil
            if responded { return false }
        }

        // Repeat mode + interaction history
        let interaction = cachedInteractions[msg.id]

        // Currently snoozed?
        if let snoozedUntil = interaction?.snoozedUntilDate, now < snoozedUntil {
            return false
        }

        switch msg.repeat_mode {
        case "once":
            // Already responded or dismissed → don't show again
            if interaction?.responded_at != nil { return false }
            if interaction?.dismissed_at != nil { return false }

        case "always":
            // Always show within date range (dismiss hides until next check cycle)
            break

        case "interval":
            // Re-show if dismissed_at + interval hours < now
            if let dismissedAt = interaction?.dismissedAtDate,
               let intervalHours = msg.repeat_interval_hours {
                let nextShow = dismissedAt.addingTimeInterval(TimeInterval(intervalHours * 3600))
                if now < nextShow { return false }
            }

        default:
            break
        }

        return true
    }

    private struct TargetingContext {
        let appVersion: String
        let platform: String
        let sessionCount: Int
        let frameCount: Int
    }

    private func buildTargetingContext() -> TargetingContext {
        let sessionCount = AppSettings.defaults.integer(forKey: AppSettings.Key.sessionCount.rawValue)
        var frameCount = 0
        if let stats = try? FrameHistoryDatabase.shared.databaseStats() {
            frameCount = stats.frameCount
        }
        return TargetingContext(
            appVersion: MachineInfo.appVersion,
            platform: "macos",
            sessionCount: sessionCount,
            frameCount: frameCount
        )
    }

    // MARK: - Network: Fetch

    private func fetchAll() async {
        async let messages = fetchMessages()
        async let interactions = fetchInteractions()
        async let entitlements = fetchEntitlements()

        await cachedMessages = messages
        await cachedInteractions = interactions
        await cachedEntitlements = entitlements
        lastFetchDate = Date()
        saveCachedState()
    }

    private func fetchMessages() async -> [AppMessage] {
        let url = SupabaseClient.restURL(
            table: "app_messages",
            query: "select=*&is_active=eq.true&platform=in.(macos,all)&order=priority.desc"
        )
        return await fetchArray(url: url)
    }

    private func fetchInteractions() async -> [String: MessageInteraction] {
        let hash = MachineInfo.machineHash
        let url = SupabaseClient.restURL(
            table: "message_interactions",
            query: "select=*&machine_hash=eq.\(hash)"
        )
        let list: [MessageInteraction] = await fetchArray(url: url)
        var dict: [String: MessageInteraction] = [:]
        for item in list { dict[item.message_id] = item }
        return dict
    }

    @discardableResult
    private func fetchEntitlements() async -> [DeviceEntitlement] {
        let hash = MachineInfo.machineHash
        let url = SupabaseClient.restURL(
            table: "device_entitlements",
            query: "select=*&machine_hash=eq.\(hash)"
        )
        let result: [DeviceEntitlement] = await fetchArray(url: url)
        cachedEntitlements = result
        return result
    }

    private func fetchArray<T: Decodable>(url: URL?) async -> [T] {
        guard let url else { return [] }
        var request = SupabaseClient.makeRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            print("[AppMessageService] Fetch error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Network: Write

    /// UPSERT impression (increment shown_count, update last_shown_at)
    private func upsertImpression(messageId: String) async {
        let now = MessageInteraction.nowString

        if var existing = cachedInteractions[messageId] {
            // Update existing: increment shown_count, update last_shown_at
            existing.shown_count += 1
            existing.last_shown_at = now
            cachedInteractions[messageId] = existing

            await upsertInteraction(messageId: messageId, updates: [
                "shown_count": "\(existing.shown_count)",
                "last_shown_at": now
            ])
        } else {
            // New impression
            let interaction = MessageInteraction(
                id: nil,
                message_id: messageId,
                machine_hash: MachineInfo.machineHash,
                app_version: MachineInfo.appVersion,
                shown_at: now,
                shown_count: 1,
                last_shown_at: now
            )
            cachedInteractions[messageId] = interaction
            await postInteraction(interaction)
        }
        saveCachedState()
    }

    /// POST a new interaction record.
    private func postInteraction(_ interaction: MessageInteraction) async {
        // UPSERT: merge on conflict (message_id, machine_hash). Schema gained the
        // matching UNIQUE constraint in the 2026-05-03 patch-1 migration; pass
        // on_conflict explicitly so PostgREST 12+ knows which constraint to merge on.
        guard let url = SupabaseClient.restURL(
            table: "message_interactions",
            query: "on_conflict=message_id,machine_hash"
        ) else { return }
        var request = SupabaseClient.makeRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONEncoder().encode(interaction)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[AppMessageService] POST interaction failed: \(http.statusCode)")
            }
        } catch {
            print("[AppMessageService] POST interaction error: \(error.localizedDescription)")
        }
    }

    /// PATCH an existing interaction with specific field updates.
    private func upsertInteraction(messageId: String, updates: [String: String]) async {
        let hash = MachineInfo.machineHash
        guard let url = SupabaseClient.restURL(
            table: "message_interactions",
            query: "message_id=eq.\(messageId)&machine_hash=eq.\(hash)"
        ) else { return }

        var request = SupabaseClient.makeRequest(url: url, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: updates)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[AppMessageService] PATCH interaction failed: \(http.statusCode)")
            }
        } catch {
            print("[AppMessageService] PATCH interaction error: \(error.localizedDescription)")
        }
    }

    // MARK: - Disk Cache

    private var messagesCacheURL: URL { cacheDirectory.appendingPathComponent("messages.json") }
    private var interactionsCacheURL: URL { cacheDirectory.appendingPathComponent("interactions.json") }
    private var entitlementsCacheURL: URL { cacheDirectory.appendingPathComponent("entitlements.json") }
    private var stateCacheURL: URL { cacheDirectory.appendingPathComponent("fetch_state.json") }

    private func saveCachedState() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(cachedMessages) {
            try? data.write(to: messagesCacheURL, options: .atomic)
        }
        let interactionsList = Array(cachedInteractions.values)
        if let data = try? encoder.encode(interactionsList) {
            try? data.write(to: interactionsCacheURL, options: .atomic)
        }
        if let data = try? encoder.encode(cachedEntitlements) {
            try? data.write(to: entitlementsCacheURL, options: .atomic)
        }
        // Save last fetch date
        if let fetchDate = lastFetchDate {
            let state: [String: String] = ["lastFetchDate": MessageInteraction.nowString]
            if let data = try? JSONSerialization.data(withJSONObject: state) {
                try? data.write(to: stateCacheURL, options: .atomic)
            }
            _ = fetchDate  // suppress unused warning
        }
    }

    private func loadCachedState() {
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: messagesCacheURL),
           let messages = try? decoder.decode([AppMessage].self, from: data) {
            cachedMessages = messages
        }
        if let data = try? Data(contentsOf: interactionsCacheURL),
           let list = try? decoder.decode([MessageInteraction].self, from: data) {
            cachedInteractions = [:]
            for item in list { cachedInteractions[item.message_id] = item }
        }
        if let data = try? Data(contentsOf: entitlementsCacheURL),
           let entitlements = try? decoder.decode([DeviceEntitlement].self, from: data) {
            cachedEntitlements = entitlements
        }
        if let data = try? Data(contentsOf: stateCacheURL),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let dateStr = state["lastFetchDate"] {
            lastFetchDate = AppMessage.parseDate(dateStr)
        }
    }

    // MARK: - App Usage Telemetry

    /// Fire-and-forget app start ping. Writes one row to app_events table.
    /// Never blocks the app — errors are silently ignored.
    static func recordAppStart() {
        guard SupabaseClient.isConfigured else { return }

        Task.detached(priority: .utility) {
            guard var request = SupabaseClient.jsonInsertRequest(
                table: "app_events",
                withBearer: false
            ) else { return }
            request.timeoutInterval = 15

            let payload: [String: Any] = [
                "machine_hash": MachineInfo.machineHash,
                "app_version": MachineInfo.appVersion,
                "event": "app_started",
                "chip_name": MachineInfo.chipName,
                "cpu_cores": MachineInfo.cpuCores,
                "ram_gb": MachineInfo.ramGB
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (_, _) = try await URLSession.shared.data(for: request)
            } catch {
                // Silent — never impact app startup
            }
        }
    }
}
