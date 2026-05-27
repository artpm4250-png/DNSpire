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

    @Published private(set) var outcomes: [UUID: Outcome] = [:]
    @Published private(set) var isRunning = false

    /// Total wall-clock budget per server probe. `nonisolated` so it can be
    /// referenced as a default argument (call-site default-arg evaluation is
    /// treated as non-isolated by Swift 6).
    nonisolated static let defaultTimeoutMs = 20_000

    /// Cap on in-flight probes. Each probe holds one host thread blocked on
    /// the synchronous gomobile call and opens UDP sockets per resolver;
    /// 4 is plenty for ranking, won't fan out resolver UDP traffic enough
    /// to look like a flood.
    nonisolated static let maxParallel = 4

    func reset() {
        outcomes = [:]
    }

    func testAll(
        servers: [ServerProfile],
        configStore: ConfigStore,
        timeoutMs: Int = ServerTestRunner.defaultTimeoutMs
    ) async {
        guard !isRunning else { return }
        guard !servers.isEmpty else { return }

        isRunning = true
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
                self?.outcomes[serverID] = result
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

    private static func categorize(_ error: Error) -> Outcome {
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
}
