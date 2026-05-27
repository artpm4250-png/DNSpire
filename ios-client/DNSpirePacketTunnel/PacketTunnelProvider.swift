import NetworkExtension
import DNSpireCore
import os.log

// NEPacketTunnelProvider host for the Go-side PacketTunnel. The extension
// process is started and stopped by iOS in response to NETunnelProviderManager
// commands from the main app. It has a hard 50 MB memory budget — gVisor's
// netstack is the heaviest tenant; keep packet buffers small.

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "com.dnspire.ios.tunnel", category: "provider")
    private var packetTunnel: DNSpireMobilePacketTunnel?
    private var running = false

    private let stateLock = NSLock()
    private var latestStatus: String = "stopped"
    private let logRing = LogRing(capacity: 500)
    private var verifier: Verifier?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        os_log("startTunnel", log: log, type: .info)
        recordStatus("starting")

        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfig = proto.providerConfiguration,
            let configJSON = providerConfig["configJSON"] as? String,
            !configJSON.isEmpty
        else {
            recordStatus("error:Missing providerConfiguration.configJSON")
            completionHandler(makeError(code: 1, "Missing providerConfiguration.configJSON"))
            return
        }
        let resolversText = (providerConfig["resolversText"] as? String) ?? ""
        let dnsResolver = (providerConfig["dnsResolver"] as? String) ?? "1.1.1.1:53"
        let verifyURL = providerConfig["verifyURL"] as? String

        let v = Verifier(verifyURLString: verifyURL) { [weak self] line in
            self?.logRing.append(line)
        }
        verifier = v

        let pt = DNSpireMobileNewPacketTunnel()!
        pt.setLogCallback(LogSink { [weak self] line in
            guard let self else { return }
            let text = line ?? ""
            os_log("%{public}@", log: self.log, type: .info, text)
            self.logRing.append(text)
        })
        pt.setStatusCallback(StatusSink { [weak self] state in
            guard let self else { return }
            let text = state ?? ""
            os_log("status=%{public}@", log: self.log, type: .info, text)
            self.recordStatus(text)
            self.logRing.append("[status] \(text)")
        })
        pt.setPacketCallback(PacketSink { [weak self] data in
            guard let self, let data, !data.isEmpty else { return }
            let family = (data.first ?? 0) >> 4 == 4 ? AF_INET : AF_INET6
            let nePkt = NEPacket(data: data, protocolFamily: sa_family_t(family))
            _ = self.packetFlow.writePacketObjects([nePkt])
        })
        pt.setDNSResolver(dnsResolver)
        packetTunnel = pt

        // Configure the tun interface BEFORE bringing up the Go side, so iOS
        // routes packets to us as soon as the netstack starts emitting them.
        let settings = makeTunnelSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("setTunnelNetworkSettings failed: %{public}@",
                       log: self.log, type: .error, error.localizedDescription)
                self.recordStatus("error:\(error.localizedDescription)")
                completionHandler(error)
                return
            }
            do {
                try pt.start(configJSON,
                             resolversText: resolversText,
                             scratchDir: self.scratchPath())
                self.running = true
                self.startReadLoop()
                os_log("packet tunnel up", log: self.log, type: .info)
                completionHandler(nil)
            } catch {
                os_log("packetTunnel.start failed: %{public}@",
                       log: self.log, type: .error, error.localizedDescription)
                self.recordStatus("error:\(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        running = false
        verifier?.stop()
        verifier = nil
        try? packetTunnel?.stop()
        packetTunnel = nil
        recordStatus("stopped")
        completionHandler()
    }

    /// IPC entry point. The main app sends a JSON-encoded ProviderRequest via
    /// `NETunnelProviderSession.sendProviderMessage` while the tunnel is
    /// active, and we reply with a ProviderSnapshot.
    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        let request = (try? JSONDecoder().decode(ProviderRequest.self, from: messageData))
            ?? ProviderRequest(op: "snapshot", sinceLogSeq: 0)
        if request.op == "reverify" {
            verifier?.reverify()
        }
        let snapshot = buildSnapshot(sinceLogSeq: request.sinceLogSeq ?? 0)
        let data = (try? JSONEncoder().encode(snapshot)) ?? Data()
        completionHandler?(data)
    }

    private func buildSnapshot(sinceLogSeq: Int) -> ProviderSnapshot {
        let drained = logRing.drain(since: sinceLogSeq)
        let pt = packetTunnel
        stateLock.lock()
        let status = latestStatus
        stateLock.unlock()
        let v = verifier?.snapshot() ?? (state: "", lastVerifiedAt: Int64(0))
        return ProviderSnapshot(
            status: status,
            bytesUp: pt?.bytesUp() ?? 0,
            bytesDown: pt?.bytesDown() ?? 0,
            tcpFlowsAccepted: pt?.tcpFlowsAccepted() ?? 0,
            tcpFlowsActive: pt?.tcpFlowsActive() ?? 0,
            dnsQueriesHandled: pt?.dnsQueriesHandled() ?? 0,
            logs: drained.entries,
            lastLogSeq: drained.lastSeq,
            verification: v.state,
            lastVerifiedAt: v.lastVerifiedAt,
            resolversTotal: pt?.resolversTotal() ?? 0,
            resolversActive: pt?.resolversActive() ?? 0,
            mtuSummary: pt?.mtuSummary() ?? ""
        )
    }

    private func recordStatus(_ state: String) {
        stateLock.lock()
        let prev = latestStatus
        latestStatus = state
        stateLock.unlock()
        if prev == state {
            return
        }
        if state == "connected" {
            verifier?.tunnelDidConnect()
        } else if prev == "connected" {
            verifier?.tunnelDidDisconnect()
        }
    }

    /// NEPacketTunnelNetworkSettings: claim a default route, set DNS to a
    /// public resolver (the Go side shims UDP-53 onto DNS-over-TCP via SOCKS5).
    /// IPv6 is intentionally not advertised — the upstream MasterDnsVPN
    /// channel is IPv4-only and IPv6 traffic would dead-end at gVisor.
    private func makeTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.66.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.66.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // Bypass the tunnel for the loopback so the Go runtime's own SOCKS5
        // listener (127.0.0.1:18000) stays reachable from inside this process.
        let loopback = NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0")
        ipv4.excludedRoutes = [loopback]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: 1500)
        return settings
    }

    /// readPackets is a recursive completion-handler chain: we kick off one
    /// read, write each packet into Go, then re-arm. iOS coalesces reads, so
    /// `packets` typically holds a handful at a time.
    private func startReadLoop() {
        packetFlow.readPacketObjects { [weak self] packets in
            guard let self, self.running else { return }
            guard let pt = self.packetTunnel else { return }
            for pkt in packets {
                pt.writePacket(pkt.data)
            }
            self.startReadLoop()
        }
    }

    private func scratchPath() -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("dnspire-tunnel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func makeError(code: Int, _ message: String) -> NSError {
        NSError(domain: "DNSpirePacketTunnel",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// DNSpireMobileLogCallbackProtocol / DNSpireMobileStatusCallbackProtocol /
// DNSpireMobilePacketCallbackProtocol are gomobile-generated protocols.
// Adapter classes bridge them to Swift closures.

private final class LogSink: NSObject, DNSpireMobileLogCallbackProtocol {
    let handler: (String?) -> Void
    init(handler: @escaping (String?) -> Void) { self.handler = handler }
    func onLog(_ line: String?) { handler(line) }
}

private final class StatusSink: NSObject, DNSpireMobileStatusCallbackProtocol {
    let handler: (String?) -> Void
    init(handler: @escaping (String?) -> Void) { self.handler = handler }
    func onStatus(_ state: String?) { handler(state) }
}

private final class PacketSink: NSObject, DNSpireMobilePacketCallbackProtocol {
    let handler: (Data?) -> Void
    init(handler: @escaping (Data?) -> Void) { self.handler = handler }
    func onPacket(_ data: Data?) { handler(data) }
}

/// Bounded log ring with monotonically increasing sequence numbers. The host
/// app polls `drain(since:)` to fetch new entries; older entries are evicted
/// when the buffer is full, so the app may legitimately skip seq numbers if it
/// polls too slowly.
private final class LogRing {
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [ProviderLogEntry] = []
    private var nextSeq: Int = 1

    init(capacity: Int) { self.capacity = capacity }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(ProviderLogEntry(seq: nextSeq, text: text))
        nextSeq += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func drain(since: Int) -> (entries: [ProviderLogEntry], lastSeq: Int) {
        lock.lock()
        defer { lock.unlock() }
        let fresh = entries.filter { $0.seq > since }
        let last = entries.last?.seq ?? since
        return (fresh, last)
    }
}
