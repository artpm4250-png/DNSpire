import Foundation
import NetworkExtension
import Combine

enum VPNStatus: String {
    case unknown, disabled, connecting, connected, reasserting, disconnecting, disconnected
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

    private static let bundleId = "com.dnspire.ios.tunnel"

    private var manager: NETunnelProviderManager?
    private var observer: AnyObject?

    init() {
        Task { await reloadManager() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Load or create the VPN configuration. Idempotent — calling repeatedly
    /// just refreshes the cached manager and current status.
    func reloadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let mgr = managers.first ?? NETunnelProviderManager()
            self.manager = mgr
            self.observeStatusChanges(mgr)
            self.updateStatus(from: mgr.connection.status)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Install the profile (creating it on first run; updating providerConfig
    /// on subsequent runs) and start the tunnel.
    func connect(configJSON: String, resolversText: String, dnsResolver: String = "1.1.1.1:53") async {
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
            self.observeStatusChanges(mgr)
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
        guard let mgr = manager else { return }
        do {
            try await mgr.removeFromPreferences()
            self.manager = nil
            self.status = .disabled
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
        switch raw {
        case .invalid:        status = .disabled
        case .disconnected:   status = .disconnected
        case .connecting:     status = .connecting
        case .connected:      status = .connected
        case .reasserting:    status = .reasserting
        case .disconnecting:  status = .disconnecting
        @unknown default:     status = .unknown
        }
    }
}
