import SwiftUI

enum TunnelMode: String, CaseIterable, Identifiable {
    case proxy, systemVPN

    var id: String { rawValue }

    var label: String {
        switch self {
        case .proxy:     return "SOCKS5 Proxy"
        case .systemVPN: return "System-wide VPN"
        }
    }

    var subtitle: String {
        switch self {
        case .proxy:     return "Local listener at 127.0.0.1 — point apps at it manually."
        case .systemVPN: return "Captures all traffic through the iOS Network Extension."
        }
    }

    var icon: String {
        switch self {
        case .proxy:     return "network"
        case .systemVPN: return "lock.shield.fill"
        }
    }
}

struct ConnectionView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var logStore: LogStore
    @EnvironmentObject var vpn: VPNManager

    @AppStorage("DNSpire.tunnelMode") private var modeRaw: String = TunnelMode.proxy.rawValue

    private var mode: TunnelMode {
        TunnelMode(rawValue: modeRaw) ?? .proxy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    modePicker

                    if mode == .proxy {
                        StatusBadge(
                            status: tunnel.status,
                            detail: tunnel.statusDetail,
                            isProxyReady: tunnel.isProxyReady
                        )
                            .padding(.top, 8)
                    } else {
                        VPNBadge(status: vpn.status, goStatus: vpn.goStatus)
                            .padding(.top, 8)
                    }

                    actionButton

                    if !canConnect, !isCurrentlyRunning {
                        MissingFieldsCard(items: missingFields)
                    }

                    if mode == .proxy, !tunnel.socksAddress.isEmpty {
                        ProxyCard(address: tunnel.socksAddress)
                    }

                    if mode == .systemVPN, vpn.status == .connected || vpn.status == .reasserting {
                        TrafficCard(stats: vpn.stats)
                    }

                    if let err = currentError {
                        ErrorCard(message: err)
                    }

                    summarySection

                    Spacer(minLength: 24)
                }
                .padding(.horizontal)
            }
            .navigationTitle("DNSpire")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var canConnect: Bool {
        !configStore.draft.encryptionKey.isEmpty &&
        !configStore.draft.domains.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } &&
        !configStore.encodedResolversText().isEmpty
    }

    private var isCurrentlyRunning: Bool {
        switch mode {
        case .proxy:
            return tunnel.status != .stopped && tunnel.status != .error
        case .systemVPN:
            return vpn.status == .connected || vpn.status == .connecting || vpn.status == .reasserting
        }
    }

    private var missingFields: [String] {
        var out: [String] = []
        if configStore.draft.encryptionKey.isEmpty {
            out.append("Encryption key")
        }
        let hasDomain = !configStore.draft.domains.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if !hasDomain { out.append("At least one domain") }
        if configStore.encodedResolversText().isEmpty {
            out.append("At least one enabled resolver")
        }
        return out
    }

    private var currentError: String? {
        mode == .proxy ? tunnel.lastError : vpn.lastError
    }

    private var modePicker: some View {
        VStack(spacing: 10) {
            ForEach(TunnelMode.allCases) { m in
                ModeCard(mode: m, selected: mode == m) {
                    modeRaw = m.rawValue
                }
            }
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch mode {
        case .proxy:     proxyActionButton
        case .systemVPN: systemActionButton
        }
    }

    @ViewBuilder
    private var proxyActionButton: some View {
        let isRunning = tunnel.status != .stopped && tunnel.status != .error
        Button {
            if isRunning {
                tunnel.stop()
            } else {
                guard let json = configStore.encodedConfigJSON() else {
                    logStore.append("[ui] cannot start: required fields missing")
                    return
                }
                let resolvers = configStore.encodedResolversText()
                tunnel.start(configJSON: json, resolversText: resolvers)
            }
        } label: {
            Text(isRunning ? "Disconnect" : "Connect")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRunning ? .red : .accentColor)
        .disabled(!isRunning && !canConnect)
    }

    @ViewBuilder
    private var systemActionButton: some View {
        let active = vpn.status == .connected ||
                     vpn.status == .connecting ||
                     vpn.status == .reasserting
        Button {
            if active {
                vpn.disconnect()
            } else {
                guard let json = configStore.encodedConfigJSON() else {
                    logStore.append("[ui] cannot start: required fields missing")
                    return
                }
                let resolvers = configStore.encodedResolversText()
                let dns = configStore.normalizedSystemVPNDNSResolver()
                Task { await vpn.connect(configJSON: json, resolversText: resolvers, dnsResolver: dns) }
            }
        } label: {
            Text(active ? "Disconnect" : "Enable System VPN")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? .red : .accentColor)
        .disabled(!active && !canConnect)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Configuration")
            row("Domains", configStore.draft.domains.joined(separator: ", "))
            row("Encryption", encryptionLabel(configStore.draft.dataEncryptionMethod))
            row("Mode", configStore.draft.protocolType)
            row("Resolvers", "\(enabledResolverCount)")
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var enabledResolverCount: Int {
        configStore.draft.resolvers.filter {
            $0.enabled && ResolverEntry.isValid(host: $0.ip, port: $0.port)
        }.count
    }

    private func encryptionLabel(_ method: Int) -> String {
        switch method {
        case 0: return "None"
        case 1: return "XOR"
        case 2: return "ChaCha20"
        case 3: return "AES-128-GCM"
        case 4: return "AES-192-GCM"
        case 5: return "AES-256-GCM"
        default: return "Unknown (\(method))"
        }
    }
}

private struct StatusBadge: View {
    let status: TunnelStatus
    let detail: String
    let isProxyReady: Bool

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(.white)
                )
                .overlay(
                    Circle().stroke(color.opacity(0.3), lineWidth: 8)
                        .scaleEffect(isProxyReady ? 1.2 : 1.0)
                        .opacity(isProxyReady ? 0.0 : 0.6)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                   value: isProxyReady)
                )
            Text(label).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        if isProxyReady {
            return "Proxy ready"
        }
        switch status {
        case .stopped: return "Disconnected"
        case .starting: return "Starting…"
        case .mtuTesting: return "Probing MTU…"
        case .sessionInit: return "Initializing session…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .error: return "Error"
        }
    }

    private var color: Color {
        if isProxyReady {
            return .green
        }
        switch status {
        case .stopped: return .gray
        case .connected: return .green
        case .error: return .red
        default: return .orange
        }
    }

    private var icon: String {
        if isProxyReady {
            return "checkmark"
        }
        switch status {
        case .stopped: return "bolt.slash.fill"
        case .connected: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }
}

private struct VPNBadge: View {
    let status: VPNStatus
    let goStatus: String

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(.white)
                )
                .overlay(
                    Circle().stroke(color.opacity(0.35), lineWidth: 8)
                        .scaleEffect(isInFlight ? 1.25 : 1.0)
                        .opacity(isInFlight ? 0.0 : 0.6)
                        .animation(
                            isInFlight
                                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                                : .default,
                            value: isInFlight
                        )
                )
            Text(label).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isInFlight: Bool {
        status == .connecting || status == .reasserting || status == .disconnecting
    }

    private var label: String {
        switch status {
        case .connected:     return "Connected"
        case .connecting:    return "Connecting…"
        case .reasserting:   return "Reasserting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected:  return "Disconnected"
        case .disabled:      return "Profile not installed"
        case .unknown:       return "Unknown"
        }
    }

    private var detail: String {
        let go = goStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !go.isEmpty else { return "System-wide VPN" }
        if go.hasPrefix("error:") {
            return String(go.dropFirst("error:".count))
        }
        switch go {
        case "starting":      return "Bootstrapping…"
        case "mtu_testing":   return "Probing MTU…"
        case "session_init":  return "Initializing session…"
        case "connected":     return "Tunnel up"
        case "reconnecting":  return "Reconnecting…"
        case "stopped":       return "Stopped"
        default:              return go
        }
    }

    private var color: Color {
        switch status {
        case .connected:                  return .green
        case .connecting, .reasserting:   return .orange
        case .disconnecting:              return .orange
        default:                          return .gray
        }
    }

    private var icon: String {
        switch status {
        case .connected:                                                 return "checkmark"
        case .connecting, .reasserting, .disconnecting:                  return "arrow.triangle.2.circlepath"
        default:                                                         return "bolt.slash.fill"
        }
    }
}

private struct ProxyCard: View {
    let address: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local SOCKS5").font(.caption).foregroundStyle(.secondary)
                    Text(address).font(.body).monospaced()
                }
                Spacer()
            }
            Divider()
            row("Host", host)
            row("Port", port)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var parts: [Substring] {
        address.split(separator: ":", maxSplits: 1)
    }

    private var host: String {
        String(parts.first ?? "127.0.0.1")
    }

    private var port: String {
        parts.count > 1 ? String(parts[1]) : "18000"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced()
        }
        .font(.subheadline)
    }
}

private struct ErrorCard: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline)
            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TrafficCard: View {
    let stats: VPNStats

    @State private var prevSample: (stats: VPNStats, at: Date)?
    @State private var upRate: Double = 0
    @State private var downRate: Double = 0

    private static let totalFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .binary
        return f
    }()

    private static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .binary
        f.includesUnit = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.title2)
                Text("Traffic").font(.headline)
                Spacer()
            }
            Divider()
            HStack(alignment: .top) {
                metric(
                    systemImage: "arrow.up",
                    label: "Up",
                    value: Self.totalFormatter.string(fromByteCount: stats.bytesUp),
                    rate: upRate
                )
                Spacer()
                metric(
                    systemImage: "arrow.down",
                    label: "Down",
                    value: Self.totalFormatter.string(fromByteCount: stats.bytesDown),
                    rate: downRate
                )
            }
            Divider()
            row("Active TCP", "\(stats.tcpFlowsActive)")
            row("Total TCP", "\(stats.tcpFlowsAccepted)")
            row("DNS queries", "\(stats.dnsQueriesHandled)")
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: stats) { _, new in
            recomputeRate(with: new)
        }
        .onAppear {
            prevSample = (stats, Date())
        }
    }

    private func recomputeRate(with new: VPNStats) {
        let now = Date()
        defer { prevSample = (new, now) }
        guard let prev = prevSample else { return }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0.05 else { return }
        let dUp = max(0, new.bytesUp - prev.stats.bytesUp)
        let dDown = max(0, new.bytesDown - prev.stats.bytesDown)
        upRate = Double(dUp) / dt
        downRate = Double(dDown) / dt
    }

    private func metric(systemImage: String, label: String, value: String, rate: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body).monospacedDigit()
                Text(rateText(rate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func rateText(_ rate: Double) -> String {
        let bytes = Int64(rate.rounded())
        if bytes <= 0 { return "idle" }
        return "\(Self.rateFormatter.string(fromByteCount: bytes))/s"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}

private struct ModeCard: View {
    let mode: TunnelMode
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.accentColor : Color(.tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: mode.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MissingFieldsCard: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.orange)
                Text("Configuration needed")
                    .font(.headline)
                Spacer()
            }
            Text("Open Settings to fill in the following before connecting:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.orange)
                        Text(item).font(.subheadline)
                    }
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
