import Foundation
import Combine
import DNSpireCore

/// Race a list of [[ServerProfile]] against the current resolver list and
/// surface per-server latency / failure. Drives the "Test all" affordance in
/// [[ProfileSliceSheet]] (Server slice). See plan `playful-churning-eclipse`.
///
/// Each probe calls `DNSpireMobileProbeServerDetailed` — a one-shot handshake
/// (`BootstrapLoadedConfig` → `RunInitialMTUTests` → `InitializeSession`) that
/// tears itself down and never binds the SOCKS5 listener, so probes are safe
/// to run in parallel and concurrently with a live tunnel. The "Detailed"
/// variant additionally returns a `;`-separated per-resolver row list used
/// for the drill-down view.
///
/// The runner is a long-lived `@EnvironmentObject` (see `DNSpireApp`) so that
/// outcomes survive sheet dismissals. Stable outcomes (`ok` / `timeout` /
/// `fail`) are persisted to `UserDefaults` together with the wall-clock
/// timestamp when the probe finished, so `Test all` results stay visible
/// across app launches until the user re-runs them.
@MainActor
final class ServerTestRunner: ObservableObject {
    enum Outcome: Equatable {
        case pending
        case running
        case ok(ms: Int)
        case timeout
        /// "mtu" / "handshake" / "config" — categorized by the Go side; the
        /// raw string flows to the UI badge so future categories don't
        /// require a Swift change.
        case fail(reason: String)
    }

    /// One persisted result for a server. `pending` and `running` are
    /// transient and never written to disk, so the stored outcome is always
    /// one of `ok` / `timeout` / `fail`.
    struct PersistedResult: Equatable {
        let outcome: Outcome
        let at: Date
    }

    /// Per-resolver row reported by `ProbeServerDetailed`. One row per
    /// (server-domain × resolver) pair the balancer settled on after the
    /// MTU bisect — the UI groups them by resolver before display.
    struct ResolverProbeRow: Equatable, Codable {
        let resolver: String
        let valid: Bool
        let mtuResolveMs: Int

        /// Parse the `resolver|valid|mtuResolveMs` form emitted by the Go
        /// side. Returns nil for malformed rows so an unexpected field count
        /// from a newer Go build silently downgrades to no drill-down rather
        /// than crashing the persisted decode.
        init?(field: Substring) {
            let parts = field.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            guard let mtuMs = Int(parts[2]) else { return nil }
            self.resolver = String(parts[0])
            self.valid = parts[1] == "1"
            self.mtuResolveMs = mtuMs
        }

        init(resolver: String, valid: Bool, mtuResolveMs: Int) {
            self.resolver = resolver
            self.valid = valid
            self.mtuResolveMs = mtuResolveMs
        }
    }

    @Published private(set) var outcomes: [UUID: Outcome] = [:]
    @Published private(set) var results: [UUID: PersistedResult] = [:]
    /// Per-server drill-down data from the latest probe (live or persisted).
    /// Mirrors `outcomes` for transient (`.running`) state and `results` for
    /// stable outcomes. Empty when the Go binding doesn't yet expose
    /// `ProbeServerDetailed` (the legacy `ProbeServer` path leaves it empty).
    @Published private(set) var details: [UUID: [ResolverProbeRow]] = [:]
    @Published private(set) var isRunning = false
    /// Monotonic counter incremented on each `testAll` start so the UI can
    /// reset its "Dismissed this suggestion" state whenever fresh data
    /// arrives. Compared against `dismissedEpoch`.
    @Published private(set) var runEpoch: UInt64 = 0
    @Published private(set) var dismissedEpoch: UInt64 = 0

    /// Total wall-clock budget per server probe. `nonisolated` so it can be
    /// referenced as a default argument (call-site default-arg evaluation is
    /// treated as non-isolated by Swift 6).
    nonisolated static let defaultTimeoutMs = 20_000

    /// Cap on in-flight probes. Each probe holds one host thread blocked on
    /// the synchronous gomobile call and opens UDP sockets per resolver;
    /// 4 is plenty for ranking, won't fan out resolver UDP traffic enough
    /// to look like a flood.
    nonisolated static let maxParallel = 4

    private static let persistKey = "DNSpire.ServerTestRunner.results.v1"
    private static let detailsKey = "DNSpire.ServerTestRunner.details.v1"

    init() {
        results = Self.loadPersisted()
        outcomes = results.mapValues { $0.outcome }
        details = Self.loadDetails()
    }

    func reset() {
        outcomes = [:]
        results = [:]
        details = [:]
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
        UserDefaults.standard.removeObject(forKey: Self.detailsKey)
    }

    /// Maximum age for a persisted `.ok` result to still be considered a
    /// useful hint for auto-pick. Older than this and the network conditions
    /// likely changed enough that "Test all" should run again first.
    nonisolated static let suggestionMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Lowest-latency server with a fresh `.ok` result, among the supplied
    /// candidate IDs (typically `profileStore.servers`). `nil` if no row
    /// qualifies. Used to drive the "Switch to fastest" suggestion banner.
    func fastestServerID(among candidates: [UUID]) -> (id: UUID, ms: Int)? {
        let now = Date()
        var best: (id: UUID, ms: Int)? = nil
        for id in candidates {
            guard let r = results[id] else { continue }
            guard now.timeIntervalSince(r.at) <= Self.suggestionMaxAge else { continue }
            guard case .ok(let ms) = r.outcome else { continue }
            if best == nil || ms < best!.ms {
                best = (id, ms)
            }
        }
        return best
    }

    /// Hide the suggestion banner until the next `testAll` run. The UI checks
    /// `dismissedEpoch == runEpoch` to know whether the dismiss is still
    /// in effect.
    func dismissSuggestion() {
        dismissedEpoch = runEpoch
    }

    /// Drop any persisted result whose server is no longer present in the
    /// active profile list. Called when the user deletes a server profile.
    func prune(to liveServerIDs: Set<UUID>) {
        var changed = false
        for id in results.keys where !liveServerIDs.contains(id) {
            results.removeValue(forKey: id)
            outcomes.removeValue(forKey: id)
            changed = true
        }
        var detailsChanged = false
        for id in details.keys where !liveServerIDs.contains(id) {
            details.removeValue(forKey: id)
            detailsChanged = true
        }
        if changed { persist() }
        if detailsChanged { persistDetails() }
    }

    func testAll(
        servers: [ServerProfile],
        configStore: ConfigStore,
        timeoutMs: Int = ServerTestRunner.defaultTimeoutMs
    ) async {
        guard !isRunning else { return }
        guard !servers.isEmpty else { return }

        isRunning = true
        runEpoch &+= 1
        defer { isRunning = false }

        let resolversText = configStore.encodedResolversText()
        let scratchRoot = Self.scratchRootURL()

        // Seed UI: every server starts as .pending so badges render
        // immediately rather than popping in as probes start.
        var seed: [UUID: Outcome] = [:]
        for s in servers { seed[s.id] = .pending }
        outcomes = seed

        await withTaskGroup(of: Void.self) { group in
            var iterator = servers.makeIterator()
            var inFlight = 0

            // Prime the pool up to maxParallel.
            while inFlight < Self.maxParallel, let server = iterator.next() {
                addProbe(server, into: &group, configStore: configStore,
                         resolversText: resolversText, scratchRoot: scratchRoot,
                         timeoutMs: timeoutMs)
                inFlight += 1
            }

            // Drain: each completion frees a slot for the next probe.
            while inFlight > 0 {
                _ = await group.next()
                inFlight -= 1
                if let server = iterator.next() {
                    addProbe(server, into: &group, configStore: configStore,
                             resolversText: resolversText, scratchRoot: scratchRoot,
                             timeoutMs: timeoutMs)
                    inFlight += 1
                }
            }
        }
    }

    private func addProbe(
        _ server: ServerProfile,
        into group: inout TaskGroup<Void>,
        configStore: ConfigStore,
        resolversText: String,
        scratchRoot: URL,
        timeoutMs: Int
    ) {
        let configJSON = configStore.encodedConfigJSON(serverOverride: server)
        let scratchDir = scratchRoot.appendingPathComponent(server.id.uuidString, isDirectory: true).path
        let serverID = server.id
        outcomes[serverID] = .running
        group.addTask { [weak self] in
            let probe = await Self.runProbe(
                configJSON: configJSON,
                resolversText: resolversText,
                scratchDir: scratchDir,
                timeoutMs: timeoutMs
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyProbeResult(serverID: serverID, probe: probe)
            }
        }
    }

    /// Probe a single server profile out-of-band from `testAll`. Used by the
    /// per-row "Test" affordance in `ProfileSliceSheet`. Coexists with an
    /// ongoing `testAll` (the same server's probe just gets coalesced via
    /// the `.running` guard).
    ///
    /// Unlike `testAll`, this does NOT bump `runEpoch` — a fresh single
    /// result shouldn't reset the user's "I dismissed the suggestion"
    /// state for the bulk run.
    func testOne(
        server: ServerProfile,
        configStore: ConfigStore,
        timeoutMs: Int = ServerTestRunner.defaultTimeoutMs
    ) {
        if case .running = outcomes[server.id] { return }
        let configJSON = configStore.encodedConfigJSON(serverOverride: server)
        let resolversText = configStore.encodedResolversText()
        let scratchDir = Self.scratchRootURL()
            .appendingPathComponent(server.id.uuidString, isDirectory: true).path
        let serverID = server.id
        outcomes[serverID] = .running
        Task {
            let probe = await Self.runProbe(
                configJSON: configJSON,
                resolversText: resolversText,
                scratchDir: scratchDir,
                timeoutMs: timeoutMs
            )
            await MainActor.run {
                self.applyProbeResult(serverID: serverID, probe: probe)
            }
        }
    }

    /// Single point where a probe finishes: writes the outcome, persists the
    /// outcome row, replaces or clears the per-resolver detail rows (the
    /// detail map intentionally tracks the latest probe even when it fails —
    /// failure rows are useful drill-down) and triggers both persistence
    /// stores.
    private func applyProbeResult(serverID: UUID, probe: ProbeResult) {
        outcomes[serverID] = probe.outcome
        results[serverID] = PersistedResult(outcome: probe.outcome, at: Date())
        if probe.details.isEmpty {
            details.removeValue(forKey: serverID)
        } else {
            details[serverID] = probe.details
        }
        persist()
        persistDetails()
    }

    /// Output of `runProbe`. Bundles the stable Outcome with whatever
    /// per-resolver rows the Go binding emitted — empty on failure or when
    /// running against an older mobile build that lacks `ProbeServerDetailed`.
    private struct ProbeResult {
        let outcome: Outcome
        let details: [ResolverProbeRow]
    }

    /// Detached probe: gomobile's call is synchronous, so we hand it to a
    /// background thread and only re-enter MainActor to publish the result.
    private static func runProbe(
        configJSON: String?,
        resolversText: String,
        scratchDir: String,
        timeoutMs: Int
    ) async -> ProbeResult {
        guard let configJSON, !configJSON.isEmpty else {
            return ProbeResult(outcome: .fail(reason: "config"), details: [])
        }
        return await Task.detached(priority: .userInitiated) { () -> ProbeResult in
            // ProbeServerDetailed has signature (int64, string, error) —
            // gomobile emits the raw out-param form for free funcs with more
            // than one non-error return, so we pass two out-params.
            var ms: Int64 = 0
            var detailsCSV: NSString?
            var nsError: NSError?
            let ok = DNSpireMobileProbeServerDetailed(
                configJSON, resolversText, scratchDir, timeoutMs,
                &ms, &detailsCSV, &nsError
            )
            let rows = Self.parseDetails(detailsCSV as String? ?? "")
            if ok {
                return ProbeResult(outcome: .ok(ms: Int(ms)), details: rows)
            }
            if let nsError {
                return ProbeResult(outcome: Self.categorize(nsError), details: rows)
            }
            return ProbeResult(outcome: .fail(reason: "error"), details: rows)
        }.value
    }

    nonisolated private static func parseDetails(_ csv: String) -> [ResolverProbeRow] {
        guard !csv.isEmpty else { return [] }
        return csv.split(separator: ";", omittingEmptySubsequences: true)
            .compactMap(ResolverProbeRow.init(field:))
    }

    nonisolated private static func categorize(_ error: Error) -> Outcome {
        let msg = (error as NSError).localizedDescription
        // The Go side prefixes errors with a one-word category before any
        // colon — see mobile-overlay/mobile.go:ProbeServer.
        if msg == "timeout" || msg.hasPrefix("timeout:") {
            return .timeout
        }
        if msg == "mtu" || msg.hasPrefix("mtu:") {
            return .fail(reason: "mtu")
        }
        if msg == "handshake" || msg.hasPrefix("handshake:") {
            return .fail(reason: "handshake")
        }
        if msg.hasPrefix("config:") || msg == "config" {
            return .fail(reason: "config")
        }
        return .fail(reason: "error")
    }

    private static func scratchRootURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("dnspire-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Persistence

    private func persist() {
        let payload = Self.encode(results)
        UserDefaults.standard.set(payload, forKey: Self.persistKey)
    }

    private func persistDetails() {
        let payload = Self.encodeDetails(details)
        UserDefaults.standard.set(payload, forKey: Self.detailsKey)
    }

    private static func loadDetails() -> [UUID: [ResolverProbeRow]] {
        guard let data = UserDefaults.standard.data(forKey: detailsKey),
              let decoded = try? JSONDecoder().decode([PersistedDetailRow].self, from: data) else {
            return [:]
        }
        var out: [UUID: [ResolverProbeRow]] = [:]
        for row in decoded { out[row.id] = row.rows }
        return out
    }

    private static func encodeDetails(_ details: [UUID: [ResolverProbeRow]]) -> Data {
        let rows = details.map { PersistedDetailRow(id: $0.key, rows: $0.value) }
        return (try? JSONEncoder().encode(rows)) ?? Data()
    }

    private struct PersistedDetailRow: Codable {
        let id: UUID
        let rows: [ResolverProbeRow]
    }

    private static func loadPersisted() -> [UUID: PersistedResult] {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let raw = try? JSONDecoder().decode([PersistedRow].self, from: data) else {
            return [:]
        }
        var out: [UUID: PersistedResult] = [:]
        for row in raw {
            guard let outcome = row.toOutcome() else { continue }
            out[row.id] = PersistedResult(
                outcome: outcome,
                at: Date(timeIntervalSince1970: row.atUnix)
            )
        }
        return out
    }

    private static func encode(_ results: [UUID: PersistedResult]) -> Data {
        let rows = results.map { (id, value) -> PersistedRow in
            PersistedRow.from(id: id, result: value)
        }
        return (try? JSONEncoder().encode(rows)) ?? Data()
    }

    /// On-disk row format. Kept flat and explicit so future Outcome cases
    /// land in `unknown` instead of crashing the decode for older buffers.
    private struct PersistedRow: Codable {
        let id: UUID
        let kind: String     // "ok" | "timeout" | "fail"
        let ms: Int?         // populated when kind == "ok"
        let reason: String?  // populated when kind == "fail"
        let atUnix: TimeInterval

        static func from(id: UUID, result: PersistedResult) -> PersistedRow {
            switch result.outcome {
            case .ok(let ms):
                return PersistedRow(id: id, kind: "ok", ms: ms, reason: nil,
                                    atUnix: result.at.timeIntervalSince1970)
            case .timeout:
                return PersistedRow(id: id, kind: "timeout", ms: nil, reason: nil,
                                    atUnix: result.at.timeIntervalSince1970)
            case .fail(let reason):
                return PersistedRow(id: id, kind: "fail", ms: nil, reason: reason,
                                    atUnix: result.at.timeIntervalSince1970)
            case .pending, .running:
                // Should never hit disk — guard at the caller. If it ever
                // does, drop the row by returning a recognisable sentinel.
                return PersistedRow(id: id, kind: "fail", ms: nil, reason: "stale",
                                    atUnix: result.at.timeIntervalSince1970)
            }
        }

        func toOutcome() -> Outcome? {
            switch kind {
            case "ok":
                guard let ms else { return nil }
                return .ok(ms: ms)
            case "timeout":
                return .timeout
            case "fail":
                return .fail(reason: reason ?? "error")
            default:
                return nil
            }
        }
    }
}

extension ServerTestRunner.Outcome {
    /// Coarse latency band, derived from `ok(ms)`. Other outcomes return nil
    /// — callers should render a separate "timeout" / "fail" badge for those.
    /// Thresholds picked to match the typical DNS-tunnel latency floor and
    /// the point at which a connection starts to feel sluggish on iOS.
    enum Score {
        case good, fair, poor
    }

    var score: Score? {
        guard case .ok(let ms) = self else { return nil }
        if ms < 200 { return .good }
        if ms < 600 { return .fair }
        return .poor
    }
}
