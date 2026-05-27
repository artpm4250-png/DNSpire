import Foundation
import NetworkExtension
import Combine

enum VPNStatus: String {
    case unknown, disabled, connecting, connected, reasserting, disconnecting, disconnected
}

/// Post-connect verification state derived from the packet-tunnel extension's
/// `Verifier` snapshot. `.idle` means the verifier hasn't run yet for this
/// session — either we never reached `connected`, or we disconnected. Set by
/// [[VPNManager]] from each polled [[ProviderSnapshot]].
enum VerificationState: Equatable {
    case idle
    case verifying
    case verified(at: Date)
    case needsAttention
}

/// Snapshot of the runtime state inside the packet-tunnel extension, drained
/// once per second while the tunnel is active.
struct VPNStats: Equatable {
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
    var tcpFlowsActive: Int64 = 0
    var tcpFlowsAccepted: Int64 = 0
    var dnsQueriesHandled: Int64 = 0
    var resolversTotal: Int = 0
    var resolversActive: Int = 0
    var mtu: MTUSummary? = nil
}

/// Per-connection upload/download MTU summary parsed from the CSV the
/// packet-tunnel extension forwards from `Tunnel.MTUSummary()`. `nil` until
/// the balancer has settled on at least one valid connection.
struct MTUSummary: Equatable {
    var uploadMin: Int
    var uploadMedian: Int
    var uploadMax: Int
    var downloadMin: Int
    var downloadMedian: Int
    var downloadMax: Int
    var sampleCount: Int

    /// Parse the "uMin,uMed,uMax,dMin,dMed,dMax,sample" CSV form. Returns
    /// `nil` for empty input or any malformed row — older extensions that
    /// don't yet emit the field land here and the UI just hides the panel.
    init?(csv: String) {
        let parts = csv.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 7 else { return nil }
        guard let uMin = Int(parts[0]), let uMed = Int(parts[1]), let uMax = Int(parts[2]),
              let dMin = Int(parts[3]), let dMed = Int(parts[4]), let dMax = Int(parts[5]),
              let sample = Int(parts[6]) else { return nil }
        guard sample > 0 else { return nil }
        self.uploadMin = uMin
        self.uploadMedian = uMed
        self.uploadMax = uMax
        self.downloadMin = dMin
        self.downloadMedian = dMed
        self.downloadMax = dMax
        self.sampleCount = sample
    }
}

/// VPNManager wraps NETunnelProviderManager: it installs the system VPN
/// profile that points at our packet-tunnel extension and starts/stops the
/// tunnel. Config (encryption key, domains, resolvers) is shipped to the
/// extension via NETunnelProviderProtocol.providerConfiguration on every
/// start — no App Group setup required.
@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var status: VPNStatus = .unknown
    @Published private(set) var lastError: String?
    @Published private(set) var goStatus: String = ""
    @Published private(set) var stats: VPNStats = .init()
    /// Live verification state pulled off the extension snapshot. `.idle` until
    /// the packet tunnel reaches `connected` for the first time, and reset to
    /// `.idle` on disconnect / removeProfile.
    @Published private(set) var verification: VerificationState = .idle
    /// Timestamp of the last successfully-decoded snapshot from the packet-tunnel
    /// extension. Nil between connects. Surfaced in the TrafficCard footer so a
    /// frozen card immediately tells the user whether IPC is dead or the
    /// extension is reporting genuine zeros.
    @Published private(set) var lastSnapshotAt: Date?
    /// True once a NETunnelProviderManager exists in the system preferences
    /// (i.e. the user has approved at least one VPN connect). Drives the
    /// "Remove profile" button visibility.
    @Published private(set) var profileInstalled: Bool = false

    /// Server profile ID associated with the current session, captured from
    /// the call site at `connect(...)`. Nil between sessions. Used to route
    /// the per-snapshot MTU observation back into [[MTUHintStore]] without
    /// VPNManager needing direct access to [[ProfileStore]].
    @Published private(set) var activeSessionServerID: UUID?
    /// True when [[ConnectionView]] resolved a non-stale [[MTUHint]] for the
    /// active server and passed it to `connect(...)`. Surfaced as a small bolt
    /// glyph in the LiveTunnelCard header so the user can tell why bootstrap
    /// felt faster on a familiar server.
    @Published private(set) var mtuHintApplied: Bool = false

    private static let bundleId = "com.dnspire.ios.tunnel"

    private var manager: NETunnelProviderManager?
    private var observer: AnyObject?
    private weak var logStore: LogStore?
    private weak var mtuHintStore: MTUHintStore?

    private var pollTask: Task<Void, Never>?
    private var lastLogSeq: Int = 0
    private var firstSnapshotLogged: Bool = false
    /// Consecutive `pollOnce` cycles that did not produce a snapshot. Used to
    /// rate-limit the "[vpn] IPC silent" diagnostic — the poll loop fires once
    /// per second so we only log every 10th miss to avoid flooding.
    private var ipcMissStreak: Int = 0

    init() {
        Task { await reloadManager() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Wires log sink so extension log lines surface in the main app's Logs
    /// tab while the tunnel is active. Called once from DNSpireApp.task.
    func attach(logStore: LogStore) {
        self.logStore = logStore
    }

    /// Wires the MTU hint store. Called once from DNSpireApp.task. The
    /// extension-snapshot apply path writes hints back through this; the
    /// connect path reads from it. Held weakly to keep the store the single
    /// owner.
    func attach(mtuHintStore: MTUHintStore) {
        self.mtuHintStore = mtuHintStore
    }

    /// Load or create the VPN configuration. Idempotent — calling repeatedly
    /// just refreshes the cached manager and current status.
    func reloadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let existing = managers.first
            let mgr = existing ?? NETunnelProviderManager()
            self.manager = mgr
            self.profileInstalled = existing != nil
            self.observeStatusChanges(mgr)
            self.updateStatus(from: mgr.connection.status)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Install the profile (creating it on first run; updating providerConfig
    /// on subsequent runs) and start the tunnel.
    func connect(
        configJSON: String,
        resolversText: String,
        dnsResolver: String,
        verifyURL: String,
        serverID: UUID? = nil,
        mtuHintApplied: Bool = false
    ) async {
        do {
            let mgr = manager ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.bundleId
            proto.serverAddress = "DNSpire"
            proto.providerConfiguration = [
                "configJSON": configJSON,
                "resolversText": resolversText,
                "dnsResolver": dnsResolver,
                "verifyURL": verifyURL
            ]
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "DNSpire"
            mgr.isEnabled = true

            try await mgr.saveToPreferences()
            // saveToPreferences sometimes invalidates the in-memory copy; reload.
            try await mgr.loadFromPreferences()

            self.manager = mgr
            self.profileInstalled = true
            self.observeStatusChanges(mgr)
            self.lastLogSeq = 0
            self.stats = .init()
            self.verification = .idle
            self.lastSnapshotAt = nil
            self.firstSnapshotLogged = false
            self.ipcMissStreak = 0
            self.activeSessionServerID = serverID
            self.mtuHintApplied = mtuHintApplied
            try mgr.connection.startVPNTunnel()
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            self.status = .disabled
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    /// Ask the extension to re-run the post-connect HTTPS probe. No-op if the
    /// tunnel isn't up. Used by the "tap to retry" affordance in
    /// [[ConnectionView]]'s VPNBadge when verification settles in
    /// `.needsAttention`.
    func requestReverify() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let req = ProviderRequest(op: "reverify", sinceLogSeq: lastLogSeq)
        guard let body = try? JSONEncoder().encode(req) else { return }
        try? session.sendProviderMessage(body) { [weak self] data in
            guard let self, let data,
                  let decoded = try? JSONDecoder().decode(ProviderSnapshot.self, from: data) else { return }
            Task { @MainActor in self.apply(decoded) }
        }
    }

    /// Remove the VPN profile entirely (the user can also do this from
    /// Settings → VPN). Useful when the user wants to revoke permission.
    func removeProfile() async {
        guard let mgr = manager, profileInstalled else { return }
        do {
            try await mgr.removeFromPreferences()
            self.manager = nil
            self.profileInstalled = false
            self.status = .disabled
            self.goStatus = ""
            self.stats = .init()
            self.verification = .idle
            self.lastSnapshotAt = nil
            self.firstSnapshotLogged = false
            self.ipcMissStreak = 0
            self.activeSessionServerID = nil
            self.mtuHintApplied = false
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    private func observeStatusChanges(_ mgr: NETunnelProviderManager) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: mgr.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateStatus(from: mgr.connection.status)
            }
        }
    }

    private func updateStatus(from raw: NEVPNStatus) {
        let next: VPNStatus
        switch raw {
        case .invalid:        next = .disabled
        case .disconnected:   next = .disconnected
        case .connecting:     next = .connecting
        case .connected:      next = .connected
        case .reasserting:    next = .reasserting
        case .disconnecting:  next = .disconnecting
        @unknown default:     next = .unknown
        }
        status = next
        managePollLoop(for: next)
    }

    private func managePollLoop(for status: VPNStatus) {
        let active = status == .connecting || status == .connected || status == .reasserting
        if active {
            startPollingIfNeeded()
        } else {
            stopPolling()
            if status == .disconnected || status == .disabled {
                goStatus = ""
                stats = .init()
                verification = .idle
                lastLogSeq = 0
                lastSnapshotAt = nil
                firstSnapshotLogged = false
                ipcMissStreak = 0
                activeSessionServerID = nil
                mtuHintApplied = false
            }
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            // Should not happen for a packet-tunnel manager — surface once, then
            // stay quiet to avoid log spam if the user is staring at this.
            noteIPCMiss(reason: "connection is not NETunnelProviderSession")
            return
        }
        let req = ProviderRequest(op: "snapshot", sinceLogSeq: lastLogSeq)
        guard let body = try? JSONEncoder().encode(req) else {
            noteIPCMiss(reason: "failed to encode snapshot request")
            return
        }
        let outcome: (snapshot: ProviderSnapshot?, reason: String) = await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(body) { data in
                    guard let data else {
                        cont.resume(returning: (nil, "provider returned nil"))
                        return
                    }
                    do {
                        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
                        cont.resume(returning: (decoded, ""))
                    } catch {
                        cont.resume(returning: (nil, "decode failed: \(error.localizedDescription)"))
                    }
                }
            } catch {
                cont.resume(returning: (nil, "sendProviderMessage threw: \(error.localizedDescription)"))
            }
        }
        if let snapshot = outcome.snapshot {
            apply(snapshot)
        } else {
            noteIPCMiss(reason: outcome.reason)
        }
    }

    /// Rate-limited diagnostic: emit once on first miss, then every 10s while
    /// misses continue. Keeps the Logs tab readable when the extension is
    /// genuinely down (otherwise we'd append one line per poll = 1/sec).
    private func noteIPCMiss(reason: String) {
        ipcMissStreak += 1
        if ipcMissStreak == 1 || ipcMissStreak % 10 == 0 {
            logStore?.append("[vpn] snapshot unavailable (\(ipcMissStreak)x): \(reason)")
        }
    }

    private func apply(_ snapshot: ProviderSnapshot) {
        ipcMissStreak = 0
        lastSnapshotAt = Date()
        goStatus = snapshot.status
        stats = VPNStats(
            bytesUp: snapshot.bytesUp,
            bytesDown: snapshot.bytesDown,
            tcpFlowsActive: snapshot.tcpFlowsActive,
            tcpFlowsAccepted: snapshot.tcpFlowsAccepted,
            dnsQueriesHandled: snapshot.dnsQueriesHandled,
            resolversTotal: snapshot.resolversTotal,
            resolversActive: snapshot.resolversActive,
            mtu: MTUSummary(csv: snapshot.mtuSummary)
        )
        if let mtu = stats.mtu, let serverID = activeSessionServerID {
            mtuHintStore?.record(
                serverID: serverID,
                uploadMedian: mtu.uploadMedian,
                downloadMedian: mtu.downloadMedian
            )
        }
        verification = mapVerification(snapshot.verification, lastVerifiedAtMs: snapshot.lastVerifiedAt)
        if snapshot.lastLogSeq > lastLogSeq {
            lastLogSeq = snapshot.lastLogSeq
        }
        if !snapshot.logs.isEmpty, let store = logStore {
            for entry in snapshot.logs {
                store.append("[vpn] \(entry.text)")
            }
        }
        if !firstSnapshotLogged {
            firstSnapshotLogged = true
            logStore?.append(
                "[vpn] first snapshot: status=\(snapshot.status) " +
                "up=\(snapshot.bytesUp) down=\(snapshot.bytesDown) " +
                "tcp=\(snapshot.tcpFlowsActive)/\(snapshot.tcpFlowsAccepted) " +
                "dns=\(snapshot.dnsQueriesHandled)"
            )
        }
        if snapshot.status.hasPrefix("error:"), lastError == nil {
            lastError = String(snapshot.status.dropFirst("error:".count))
        }
    }

    private func mapVerification(_ raw: String, lastVerifiedAtMs: Int64) -> VerificationState {
        switch raw {
        case "verifying":
            return .verifying
        case "verified":
            let when = lastVerifiedAtMs > 0
                ? Date(timeIntervalSince1970: TimeInterval(lastVerifiedAtMs) / 1000.0)
                : Date()
            return .verified(at: when)
        case "needsAttention":
            return .needsAttention
        default:
            return .idle
        }
    }
}
