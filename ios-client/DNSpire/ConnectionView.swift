import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var logStore: LogStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    StatusBadge(status: tunnel.status, detail: tunnel.statusDetail)
                        .padding(.top, 24)

                    actionButton

                    if !tunnel.socksAddress.isEmpty {
                        InfoCard(title: "Local SOCKS5", value: tunnel.socksAddress,
                                 systemImage: "network")
                    }

                    if let err = tunnel.lastError {
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

    @ViewBuilder
    private var actionButton: some View {
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
                        .scaleEffect(status == .connected ? 1.2 : 1.0)
                        .opacity(status == .connected ? 0.0 : 0.6)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                   value: status)
                )
            Text(label).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
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
        switch status {
        case .stopped: return .gray
        case .connected: return .green
        case .error: return .red
        default: return .orange
        }
    }

    private var icon: String {
        switch status {
        case .stopped: return "bolt.slash.fill"
        case .connected: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }
}

private struct InfoCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body).monospaced()
            }
            Spacer()
        }
        .padding()
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
