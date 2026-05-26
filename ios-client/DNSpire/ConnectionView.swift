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
}

struct ConnectionView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var logStore: LogStore
    @EnvironmentObject var vpn: VPNManager

    @AppStorage("DNSpire.tunnelMode") private var modeRaw: String = TunnelMode.proxy.rawValue

    private var mode: TunnelMode {
        get { TunnelMode(rawValue: modeRaw) ?? .proxy }
    }

    private var modeSelection: Binding<TunnelMode> {
        Binding(
            get: { mode },
            set: { modeRaw = $0.rawValue }
        )
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
                        VPNBadge(status: vpn.status)
                            .padding(.top, 8)
                    }

                    actionButton

                    if mode == .proxy, !tunnel.socksAddress.isEmpty {
                        ProxyCard(address: tunnel.socksAddress)
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
        configStore.draft.resolvers.contains(where: { $0.enabled })
    }

    private var currentError: String? {
        mode == .proxy ? tunnel.lastError : vpn.lastError
    }

    private var modePicker: some View {
        Picker("Mode", selection: modeSelection) {
            ForEach(TunnelMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
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
                Task { await vpn.connect(configJSON: json, resolversText: resolvers) }
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
            row("Resolvers enabled",
                "\(configStore.draft.resolvers.filter { $0.enabled }.count) / \(configStore.draft.resolvers.count)")
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
            Text(label).font(.headline)
            Text("System-wide VPN").font(.caption).foregroundStyle(.secondary)
        }
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
