import SwiftUI
import UIKit

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
        case .proxy:     return "Local SOCKS5 listener — point apps at it manually."
        case .systemVPN: return "All device traffic through the Network Extension."
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
    @EnvironmentObject var profileStore: ProfileStore
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
                VStack(spacing: 18) {
                    modePicker

                    if mode == .proxy {
                        StatusBadge(
                            status: tunnel.status,
                            detail: tunnel.statusDetail,
                            isProxyReady: tunnel.isProxyReady
                        )
                            .padding(.top, 4)
                    } else {
                        VPNBadge(
                            status: vpn.status,
                            goStatus: vpn.goStatus,
                            verification: vpn.verification,
                            onRetryTap: { vpn.requestReverify() }
                        )
                            .padding(.top, 4)
                    }

                    if !isCurrentlyRunning {
                        SaveToProfileButton()
                    }

                    actionButton

                    if !canConnect, !isCurrentlyRunning {
                        MissingFieldsCard(items: missingFields)
                    }

                    if mode == .proxy, !tunnel.socksAddress.isEmpty {
                        ProxyCard(address: tunnel.socksAddress)
                    }

                    if mode == .systemVPN, vpn.status == .connected || vpn.status == .reasserting {
                        LiveTunnelCard(
                            stats: vpn.stats,
                            goStatus: vpn.goStatus,
                            lastSnapshotAt: vpn.lastSnapshotAt
                        )
                    }

                    if let err = currentError {
                        ErrorCard(message: err)
                    }

                    ProfileSelectorCard()

                    Spacer(minLength: 16)
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

    /// True if either backend is doing work. Used to lock the mode picker so
    /// the user can't switch tabs underneath a live tunnel.
    private var isAnyTunnelBusy: Bool {
        let proxyBusy = tunnel.status != .stopped && tunnel.status != .error
        let vpnBusy = vpn.status == .connected ||
                      vpn.status == .connecting ||
                      vpn.status == .reasserting ||
                      vpn.status == .disconnecting
        return proxyBusy || vpnBusy
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
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(TunnelMode.allCases) { m in
                    ModeSegment(
                        mode: m,
                        selected: mode == m,
                        locked: isAnyTunnelBusy && mode != m
                    ) {
                        guard !isAnyTunnelBusy else { return }
                        modeRaw = m.rawValue
                    }
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemFill))
            )
            Text(isAnyTunnelBusy ? "Disconnect to switch modes." : mode.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 12)
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
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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
                let verifyURL = configStore.normalizedVerifyURL()
                Task { await vpn.connect(configJSON: json, resolversText: resolvers, dnsResolver: dns, verifyURL: verifyURL) }
            }
        } label: {
            Text(active ? "Disconnect" : "Enable System VPN")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(active ? .red : .accentColor)
        .disabled(!active && !canConnect)
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
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                )
                .overlay(
                    Circle().stroke(color.opacity(0.3), lineWidth: 6)
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
    let verification: VerificationState
    let onRetryTap: () -> Void

    /// Heartbeat for the "Verified · Xs ago" relative-time string; otherwise
    /// the line would freeze on whatever the apply() snapshot saw.
    @State private var now: Date = Date()

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                )
                .overlay(
                    Circle().stroke(color.opacity(0.35), lineWidth: 6)
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
            verificationChip
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
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

    @ViewBuilder
    private var verificationChip: some View {
        switch verification {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Verifying…").font(.caption2).foregroundStyle(.orange)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())
        case .verified(let at):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2).foregroundStyle(.green)
                Text("Verified · \(relativeAge(of: at))")
                    .font(.caption2).foregroundStyle(.green)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.green.opacity(0.12))
            .clipShape(Capsule())
        case .needsAttention:
            Button(action: onRetryTap) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                    Text("Probe failed — tap to retry")
                        .font(.caption2).foregroundStyle(.red)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func relativeAge(of date: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date).rounded()))
        if s < 1 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return "\(h)h ago"
    }
}

private struct ResolverStatePane: View {
    let total: Int
    let active: Int
    let goStatus: String

    var body: some View {
        HStack(spacing: 14) {
            chip(color: .green, label: "active", value: active)
            chip(color: .secondary, label: "inactive", value: inactive)
            if pending > 0 {
                chip(color: .orange, label: "pending", value: pending)
            }
            Spacer(minLength: 0)
            if total == 0 {
                Text("loading…").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// During `mtu_testing` the balancer hasn't decided which resolvers will be
    /// in rotation yet — we surface those as "pending" rather than misleadingly
    /// labelling them inactive. Once the upstream loop settles, leftover slots
    /// are genuinely disabled and slot into `inactive`.
    private var pending: Int {
        let go = goStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if go == "mtu_testing" || go == "session_init" || go == "starting" {
            return max(0, total - active)
        }
        return 0
    }

    private var inactive: Int {
        max(0, total - active - pending)
    }

    private func chip(color: Color, label: String, value: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value)").font(.subheadline.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ProxyCard: View {
    let address: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local SOCKS5")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(address)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = address
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.success)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

private struct LiveTunnelCard: View {
    let stats: VPNStats
    let goStatus: String
    let lastSnapshotAt: Date?

    @State private var prevSample: (stats: VPNStats, at: Date)?
    @State private var upRate: Double = 0
    @State private var downRate: Double = 0
    /// Heartbeat that re-renders the "Updated Xs ago" footer once per second
    /// without depending on stats actually changing — the whole point is to
    /// notice when stats *stop* changing.
    @State private var now: Date = Date()

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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(.tint)
                Text("Live tunnel").font(.headline)
                Spacer()
                liveness
            }

            HStack(spacing: 12) {
                throughput(
                    symbol: "arrow.up",
                    tint: .accentColor,
                    total: Self.totalFormatter.string(fromByteCount: stats.bytesUp),
                    rate: upRate
                )
                throughput(
                    symbol: "arrow.down",
                    tint: .green,
                    total: Self.totalFormatter.string(fromByteCount: stats.bytesDown),
                    rate: downRate
                )
            }

            Divider()

            HStack(spacing: 0) {
                miniStat(label: "TCP", value: "\(stats.tcpFlowsActive)", sub: "of \(stats.tcpFlowsAccepted)")
                miniStat(label: "DNS", value: "\(stats.dnsQueriesHandled)", sub: "queries")
                miniStat(label: "Resolvers", value: "\(stats.resolversActive)", sub: "of \(stats.resolversTotal)")
            }

            Divider()

            ResolverStatePane(
                total: stats.resolversTotal,
                active: stats.resolversActive,
                goStatus: goStatus
            )
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: stats) { _, new in
            recomputeRate(with: new)
        }
        .onAppear {
            prevSample = (stats, Date())
            now = Date()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
    }

    private var ageSeconds: Int? {
        guard let last = lastSnapshotAt else { return nil }
        return max(0, Int(now.timeIntervalSince(last).rounded()))
    }

    @ViewBuilder
    private var liveness: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(livenessColor)
                .frame(width: 6, height: 6)
            Text(livenessText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var livenessText: String {
        guard let age = ageSeconds else { return "waiting" }
        if age <= 1 { return "live" }
        return "\(age)s ago"
    }

    private var livenessColor: Color {
        guard let age = ageSeconds else { return .secondary }
        return age <= 3 ? .green : .orange
    }

    private func throughput(symbol: String, tint: Color, total: String, rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(total)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            Text(rateText(rate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.08))
        )
    }

    private func miniStat(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func rateText(_ rate: Double) -> String {
        let bytes = Int64(rate.rounded())
        if bytes <= 0 { return "idle" }
        return "\(Self.rateFormatter.string(fromByteCount: bytes))/s"
    }
}

private struct ModeSegment: View {
    let mode: TunnelMode
    let selected: Bool
    /// True when the other mode is currently active — tapping does nothing and
    /// the segment renders dimmed with a lock glyph so the user understands why.
    var locked: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: locked ? "lock.fill" : mode.icon)
                    .font(.caption.weight(.semibold))
                Text(shortLabel)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Color.white : (locked ? Color.secondary : Color.primary))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor : Color.clear)
                    .shadow(color: selected ? Color.accentColor.opacity(0.25) : .clear,
                            radius: 4, y: 1)
            )
            .opacity(locked ? 0.55 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    private var shortLabel: String {
        switch mode {
        case .proxy:     return "Proxy"
        case .systemVPN: return "VPN"
        }
    }
}

private struct MissingFieldsCard: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Configuration needed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text("Open Settings to fill in the following before connecting:")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.orange)
                        Text(item).font(.caption)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
