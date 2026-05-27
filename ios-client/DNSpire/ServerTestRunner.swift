import Foundation
import Combine
import DNSpireCore

/// Race a list of [[ServerProfile]] against the current resolver list and
/// surface per-server latency / failure. Drives the "Test all" affordance in
/// [[ProfileSliceSheet]] (Server slice). See plan `playful-churning-eclipse`.
///
/// Each probe calls `DNSpireMobileProbeServer` — a one-shot handshake
/// (`BootstrapLoadedConfig` → `RunInitialMTUTests` → `InitializeSession`) that
/// tears itself down and never binds the SOCKS5 listener, so probes are safe
/// to run in parallel and concurrently with a live tunnel.
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

    @Published private(set) var outcomes: [UUID: Outcome] = [:]
    @Published private(set) var results: [UUID: PersistedResult] = [:]
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

    init() {
        results = Self.loadPersisted()
        outcomes = results.mapValues { $0.outcome }
    }

    func reset() {
        outcomes = [:]
        results = [:]
        UserDefaults.standard.removeObject(forKey: Self.persistKey)
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
        if changed { persist() }
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
            let result = await Self.runProbe(
                configJSON: configJSON,
                resolversText: resolversText,
                scratchDir: scratchDir,
                timeoutMs: timeoutMs
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.outcomes[serverID] = result
                self.results[serverID] = PersistedResult(outcome: result, at: Date())
                self.persist()
            }
        }
    }

    /// Detached probe: gomobile's call is synchronous, so we hand it to a
    /// background thread and only re-enter MainActor to publish the result.
    private static func runProbe(
        configJSON: String?,
        resolversText: String,
        scratchDir: String,
        timeoutMs: Int
    ) async -> Outcome {
        guard let configJSON, !configJSON.isEmpty else {
            return .fail(reason: "config")
        }
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            // gomobile bound this free function in its raw out-param form
            // (Bool return + Int64*/NSError* out-params) rather than as a
            // throwing wrapper. Both forms exist for methods on classes, but
            // for package-level funcs with (int64, error) return only the
            // raw form is generated — call it positionally.
            var ms: Int64 = 0
            var nsError: NSError?
            let ok = DNSpireMobileProbeServer(
                configJSON, resolversText, scratchDir, timeoutMs,
                &ms, &nsError
            )
            if ok {
                return .ok(ms: Int(ms))
            }
            if let nsError {
                return Self.categorize(nsError)
            }
            return .fail(reason: "error")
        }.value
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
