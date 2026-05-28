import Foundation

/// `Verifier` proves the packet tunnel is actually carrying traffic by
/// firing an HTTPS request from inside the extension process after the
/// tunnel reports `connected`. The request is matched by the default
/// route we installed (NEPacketTunnelNetworkSettings.includedRoutes) so
/// it traverses tun → gVisor → SOCKS5 → upstream resolver before its
/// SYN ever reaches the wire — a 2xx within deadline is end-to-end
/// proof of life, not just `SessionReady=true`.
///
/// Concurrency: callers are `recordStatus` (extension thread) and the
/// IPC handler (one of NetworkExtension's queues), so all mutable
/// state is behind a single NSLock. The URLSession callbacks land on
/// the session's own queue; we re-enter the lock from there too.
///
/// The verifier never blocks its callers — `tunnelDidConnect`,
/// `tunnelDidDisconnect`, and `reverify` just mutate state and arm
/// timers/tasks.
final class Verifier {

    enum State: String {
        case idle
        case verifying
        case verified
        case needsAttention
    }

    /// Telemetry sink. The extension wires this to `LogRing.append`
    /// so verifier lines show up in the Logs sheet next to upstream
    /// client output.
    typealias LogSink = (String) -> Void

    private let verifyURL: URL
    private let log: LogSink

    private let lock = NSLock()
    private var state: State = .idle
    private var lastVerifiedAt: Date?
    private var currentTask: URLSessionTask?
    private var retryWorkItem: DispatchWorkItem?
    private var periodicTimer: DispatchSourceTimer?
    /// Token bumped on every cancel so a late URLSession completion
    /// from a previous attempt is ignored.
    private var generation: Int = 0
    private var isConnected: Bool = false

    /// 8s upper bound per attempt; the URLSession config also enforces
    /// it as `timeoutIntervalForResource`.
    private static let attemptDeadline: TimeInterval = 8
    /// Delay before the single retry after a failed first attempt.
    private static let retryDelay: TimeInterval = 5
    /// Re-verify cadence while in `.verified` — 5 minutes is cheap
    /// (8s of HTTPS per 300s ≈ <3% overhead) and catches silent rot.
    private static let periodicInterval: TimeInterval = 300
    /// Brief debounce on `connected` so a quick `mtu_testing ↔ connected`
    /// flap doesn't fire two probes.
    private static let connectDebounce: TimeInterval = 0.5
    /// Default endpoint — Cloudflare's 1.1.1.1 trace path. Tiny body,
    /// HTTPS-only, served globally. Overridable per-tunnel.
    static let defaultVerifyURL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.attemptDeadline
        cfg.timeoutIntervalForResource = Self.attemptDeadline
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    init(verifyURLString: String?, log: @escaping LogSink) {
        if let raw = verifyURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let parsed = URL(string: raw),
           parsed.scheme == "https" {
            self.verifyURL = parsed
        } else {
            self.verifyURL = Self.defaultVerifyURL
        }
        self.log = log
    }

    func snapshot() -> (state: String, lastVerifiedAt: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let ms = lastVerifiedAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return (state.rawValue, ms)
    }

    /// Called from `PacketTunnelProvider.recordStatus` when the Go
    /// status callback transitions to `"connected"`. Idempotent —
    /// repeated invocations while already verifying/verified are
    /// no-ops.
    func tunnelDidConnect() {
        lock.lock()
        if isConnected {
            lock.unlock()
            return
        }
        isConnected = true
        let nextGen = bumpGenerationLocked()
        cancelTimersLocked()
        currentTask?.cancel()
        currentTask = nil
        state = .verifying
        let debounce = Self.connectDebounce
        lock.unlock()

        log("[verify] connected — probing \(verifyURL.host ?? "?") in \(Int(debounce * 1000))ms")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.fireAttempt(generation: nextGen)
        }
    }

    /// Called on any status change away from `connected`. Cancels
    /// in-flight work and resets state. Multiple calls coalesce.
    func tunnelDidDisconnect() {
        lock.lock()
        if !isConnected && state == .idle && currentTask == nil && retryWorkItem == nil && periodicTimer == nil {
            lock.unlock()
            return
        }
        isConnected = false
        _ = bumpGenerationLocked()
        cancelTimersLocked()
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        lastVerifiedAt = nil
        lock.unlock()
    }

    /// User-triggered re-verify via the IPC `reverify` op. Restarts
    /// the probe regardless of current state, provided the tunnel is
    /// connected.
    func reverify() {
        lock.lock()
        guard isConnected else {
            lock.unlock()
            return
        }
        let nextGen = bumpGenerationLocked()
        cancelTimersLocked()
        currentTask?.cancel()
        currentTask = nil
        state = .verifying
        lock.unlock()

        log("[verify] manual re-verify requested")
        fireAttempt(generation: nextGen)
    }

    func stop() {
        lock.lock()
        _ = bumpGenerationLocked()
        cancelTimersLocked()
        currentTask?.cancel()
        currentTask = nil
        isConnected = false
        state = .idle
        lastVerifiedAt = nil
        lock.unlock()
        session.invalidateAndCancel()
    }

    // MARK: - Internals

    /// Caller must hold `lock`.
    private func bumpGenerationLocked() -> Int {
        generation &+= 1
        return generation
    }

    /// Caller must hold `lock`.
    private func cancelTimersLocked() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        periodicTimer?.cancel()
        periodicTimer = nil
    }

    private func fireAttempt(generation gen: Int) {
        lock.lock()
        guard isConnected, gen == generation else {
            lock.unlock()
            return
        }
        lock.unlock()

        var req = URLRequest(url: verifyURL)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = Date()

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.handleResult(generation: gen,
                              elapsed: Date().timeIntervalSince(start),
                              data: data,
                              response: response,
                              error: error)
        }

        lock.lock()
        if gen != generation || !isConnected {
            lock.unlock()
            task.cancel()
            return
        }
        currentTask = task
        lock.unlock()
        task.resume()
    }

    private func handleResult(generation gen: Int,
                              elapsed: TimeInterval,
                              data: Data?,
                              response: URLResponse?,
                              error: Error?) {
        lock.lock()
        guard gen == generation else {
            lock.unlock()
            return
        }
        guard isConnected else {
            lock.unlock()
            return
        }
        currentTask = nil

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && (200..<300).contains(status) && (data?.isEmpty == false)

        if ok {
            state = .verified
            lastVerifiedAt = Date()
            schedulePeriodicLocked()
            let ms = Int(elapsed * 1000)
            lock.unlock()
            log("[verify] ok in \(ms)ms (HTTP \(status))")
            return
        }

        let reason: String
        if let error = error {
            reason = error.localizedDescription
        } else if status != 0 {
            reason = "HTTP \(status)"
        } else {
            reason = "empty response"
        }

        // First failure → schedule one retry; on retry failure → settle in needsAttention.
        if state == .verifying && retryWorkItem == nil {
            let nextGen = bumpGenerationLocked()
            let item = DispatchWorkItem { [weak self] in
                self?.fireAttempt(generation: nextGen)
            }
            retryWorkItem = item
            lock.unlock()
            log("[verify] attempt failed (\(reason)); retrying in \(Int(Self.retryDelay))s")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.retryDelay, execute: item)
            return
        }

        state = .needsAttention
        schedulePeriodicLocked()
        lock.unlock()
        log("[verify] failed (\(reason)) — needs attention")
    }

    /// Caller must hold `lock`. Arms the 5-minute re-verify timer so a
    /// stale tunnel eventually drops out of `.verified` (or recovers
    /// out of `.needsAttention`).
    private func schedulePeriodicLocked() {
        periodicTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.periodicInterval, repeating: Self.periodicInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.isConnected else {
                self.lock.unlock()
                return
            }
            let nextGen = self.bumpGenerationLocked()
            self.state = .verifying
            self.lock.unlock()
            self.log("[verify] periodic re-probe")
            self.fireAttempt(generation: nextGen)
        }
        periodicTimer = timer
        timer.resume()
    }
}
