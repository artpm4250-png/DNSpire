import Foundation
import NetworkExtension
import Combine

enum VPNStatus: String {
    case unknown, disabled, connecting, connected, reasserting, disconnecting, disconnected
}

/// Snapshot of the runtime state inside the packet-tunnel extension, drained
/// once per second while the tunnel is active.
struct VPNStats: Equatable {
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
    var tcpFlowsActive: Int64 = 0
    var tcpFlowsAccepted: Int64 = 0
    var dnsQueriesHandled: Int64 = 0
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
    /// True once a NETunnelProviderManager exists in the system preferences
    /// (i.e. the user has approved at least one VPN connect). Drives the
    /// "Remove profile" button visibility.
    @Published private(set) var profileInstalled: Bool = false

    private static let bundleId = "com.dnspire.ios.tunnel"

    private var manager: NETunnelProviderManager?
    private var observer: AnyObject?
    private weak var logStore: LogStore?

    private var pollTask: Task<Void, Never>?
    private var lastLogSeq: Int = 0

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
    func connect(configJSON: String, resolversText: String, dnsResolver: String) async {
        do {
            let mgr = manager ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.bundleId
            proto.serverAddress = "DNSpire"
            proto.providerConfiguration = [
                "configJSON": configJSON,
                "resolversText": resolversText,
                "dnsResolver": dnsResolver
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
                lastLogSeq = 0
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
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let req = ProviderRequest(op: "snapshot", sinceLogSeq: lastLogSeq)
        guard let body = try? JSONEncoder().encode(req) else { return }
        let snapshot: ProviderSnapshot? = await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(body) { data in
                    guard let data,
                          let decoded = try? JSONDecoder().decode(ProviderSnapshot.self, from: data)
                    else {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(returning: decoded)
                }
            } catch {
                cont.resume(returning: nil)
            }
        }
        guard let snapshot else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: ProviderSnapshot) {
        goStatus = snapshot.status
        stats = VPNStats(
            bytesUp: snapshot.bytesUp,
            bytesDown: snapshot.bytesDown,
            tcpFlowsActive: snapshot.tcpFlowsActive,
            tcpFlowsAccepted: snapshot.tcpFlowsAccepted,
            dnsQueriesHandled: snapshot.dnsQueriesHandled
        )
        if snapshot.lastLogSeq > lastLogSeq {
            lastLogSeq = snapshot.lastLogSeq
        }
        if !snapshot.logs.isEmpty, let store = logStore {
            for entry in snapshot.logs {
                store.append("[vpn] \(entry.text)")
            }
        }
        if snapshot.status.hasPrefix("error:"), lastError == nil {
            lastError = String(snapshot.status.dropFirst("error:".count))
        }
    }
}
