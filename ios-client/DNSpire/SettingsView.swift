import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var vpn: VPNManager

    @State private var showRemoveProfileAlert = false

    private var isValidVerifyURL: Bool {
        let v = configStore.draft.verifyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        guard let parsed = URL(string: v), parsed.scheme == "https", parsed.host?.isEmpty == false else {
            return false
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel Identity") {
                    DomainsEditor(domains: $configStore.draft.domains)
                    SecureField("Encryption key", text: $configStore.draft.encryptionKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Encryption method", selection: $configStore.draft.dataEncryptionMethod) {
                        Text("None").tag(0)
                        Text("XOR").tag(1)
                        Text("ChaCha20").tag(2)
                        Text("AES-128-GCM").tag(3)
                        Text("AES-192-GCM").tag(4)
                        Text("AES-256-GCM").tag(5)
                    }
                }

                Section("Local Proxy") {
                    Picker("Mode", selection: $configStore.draft.protocolType) {
                        Text("SOCKS5").tag("SOCKS5")
                        Text("TCP").tag("TCP")
                    }
                    ValidatedTextRow(
                        label: "Listen IP",
                        placeholder: "127.0.0.1",
                        text: $configStore.draft.listenIP,
                        keyboard: .URL,
                        error: ConfigStore.validateHost(configStore.draft.listenIP)
                            ? nil : "Invalid IP or hostname"
                    )
                    ValidatedPortRow(
                        label: "Listen port",
                        placeholder: "18000",
                        value: $configStore.draft.listenPort
                    )
                    Toggle("Require SOCKS5 auth", isOn: $configStore.draft.socks5AuthEnabled)
                    if configStore.draft.socks5AuthEnabled {
                        LabeledContent("User") {
                            TextField("user", text: $configStore.draft.socks5User)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        LabeledContent("Password") {
                            SecureField("password", text: $configStore.draft.socks5Pass)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Resolvers") {
                    ResolverEditor(resolvers: $configStore.draft.resolvers)
                }

                Section {
                    ValidatedTextRow(
                        label: "Upstream DNS",
                        placeholder: "1.1.1.1:53",
                        text: $configStore.draft.systemVPNDNSResolver,
                        keyboard: .URL,
                        error: ConfigStore.validateHostPort(configStore.draft.systemVPNDNSResolver)
                            ? nil : "Expected host:port (e.g. 1.1.1.1:53 or [::1]:53)"
                    )
                    ValidatedTextRow(
                        label: "Verify URL",
                        placeholder: "https://1.1.1.1/cdn-cgi/trace",
                        text: $configStore.draft.verifyURL,
                        keyboard: .URL,
                        error: isValidVerifyURL ? nil : "Must be an https:// URL"
                    )
                    if vpn.profileInstalled {
                        Button(role: .destructive) {
                            showRemoveProfileAlert = true
                        } label: {
                            Label("Remove VPN profile", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("System VPN")
                } footer: {
                    Text("DNS-over-TCP target the packet-tunnel extension shims UDP-53 onto. Use a resolver reachable through your DNS tunnel (e.g. 1.1.1.1:53, 8.8.8.8:53). Ignored in SOCKS5 proxy mode. Verify URL is the HTTPS endpoint the extension hits after connecting to confirm end-to-end data flow.")
                }

                Section {
                    Picker("Resolving strategy", selection: $configStore.draft.resolverBalancingStrategy) {
                        ForEach(ResolverBalancingOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    Picker("Upload compression", selection: $configStore.draft.uploadCompressionType) {
                        ForEach(CompressionOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    Picker("Download compression", selection: $configStore.draft.downloadCompressionType) {
                        ForEach(CompressionOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Resolving strategy picks which DNS resolvers to send queries through. Compression is applied to tunnel payloads larger than the threshold in Advanced.")
                }

                Section {
                    NavigationLink {
                        AdvancedTuningView()
                            .environmentObject(configStore)
                    } label: {
                        LabeledContent("Advanced tuning") {
                            Text("MTU, ARQ, duplication")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }

                Section("Logging") {
                    Picker("Log level", selection: $configStore.draft.logLevel) {
                        Text("DEBUG").tag("DEBUG")
                        Text("INFO").tag("INFO")
                        Text("WARN").tag("WARN")
                        Text("ERROR").tag("ERROR")
                    }
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        configStore.draft = .default
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Remove VPN profile?", isPresented: $showRemoveProfileAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task { await vpn.removeProfile() }
                }
            } message: {
                Text("Deletes the DNSpire entry from iOS VPN settings. You'll be prompted for permission again the next time you enable System VPN.")
            }
        }
    }
}

struct AdvancedTuningView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section {
                Stepper(value: $configStore.draft.compressionMinSize, in: 100...65535, step: 50) {
                    LabeledContent("Compression min size") {
                        Text("\(configStore.draft.compressionMinSize) B")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Compression")
            } footer: {
                Text("Payloads smaller than this are sent uncompressed regardless of the chosen algorithm.")
            }

            Section {
                Stepper(value: $configStore.draft.mtuTestRetries, in: 1...10) {
                    LabeledContent("Probe retries") {
                        Text("\(configStore.draft.mtuTestRetries)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Probe timeout") {
                    TextField("2.0", value: $configStore.draft.mtuTestTimeout, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Stepper(value: $configStore.draft.mtuTestParallelism, in: 1...128) {
                    LabeledContent("Parallelism") {
                        Text("\(configStore.draft.mtuTestParallelism)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("MTU probing")
            } footer: {
                Text("Discovery sweep run once per session to find the largest payload that survives the DNS path.")
            }

            Section {
                Stepper(value: $configStore.draft.packetDuplicationCount, in: 1...8) {
                    LabeledContent("Packet duplication") {
                        Text("\(configStore.draft.packetDuplicationCount)×")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configStore.draft.setupPacketDuplicationCount, in: 1...8) {
                    LabeledContent("Setup duplication") {
                        Text("\(configStore.draft.setupPacketDuplicationCount)×")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Duplication")
            } footer: {
                Text("Each tunnel packet (and handshake packet) is sent N times. Higher values trade bandwidth for loss resilience.")
            }

            Section {
                Stepper(value: $configStore.draft.rxTxWorkers, in: 1...32) {
                    LabeledContent("RX/TX workers") {
                        Text("\(configStore.draft.rxTxWorkers)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configStore.draft.maxPacketsPerBatch, in: 1...64) {
                    LabeledContent("Batch size") {
                        Text("\(configStore.draft.maxPacketsPerBatch)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configStore.draft.arqWindowSize, in: 1...8000, step: 50) {
                    LabeledContent("ARQ window") {
                        Text("\(configStore.draft.arqWindowSize)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Concurrency & ARQ")
            } footer: {
                Text("Worker counts shape parallelism on the wire; ARQ window is the in-flight packet ceiling before the sender stalls.")
            }
        }
        .navigationTitle("Advanced tuning")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ResolverBalancingOption: Int, CaseIterable, Identifiable {
    case roundRobinDefault = 0
    case random = 1
    case roundRobin = 2
    case leastLoss = 3
    case lowestLatency = 4
    case hybridScore = 5
    case lossThenLatency = 6
    case leastLossTopRandom = 7
    case leastLossTopRoundRobin = 8

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .roundRobinDefault:      return "Round-robin default"
        case .random:                 return "Random"
        case .roundRobin:             return "Round-robin"
        case .leastLoss:              return "Least loss"
        case .lowestLatency:          return "Lowest latency"
        case .hybridScore:            return "Hybrid score"
        case .lossThenLatency:        return "Loss then latency"
        case .leastLossTopRandom:     return "Least loss top random"
        case .leastLossTopRoundRobin: return "Least loss top round-robin"
        }
    }
}

private enum CompressionOption: Int, CaseIterable, Identifiable {
    case off = 0
    case zstd = 1
    case lz4 = 2
    case zlib = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off:  return "Off"
        case .zstd: return "ZSTD"
        case .lz4:  return "LZ4"
        case .zlib: return "ZLIB"
        }
    }
}

/// Form row with a trailing TextField that surfaces an inline validation error
/// below when `error` is non-nil. Used by Local Proxy / System VPN sections.
private struct ValidatedTextRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let keyboard: UIKeyboardType
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                TextField(placeholder, text: $text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(keyboard)
            }
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ValidatedPortRow: View {
    let label: String
    let placeholder: String
    @Binding var value: Int

    private var isValid: Bool { ConfigStore.validatePort(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                TextField(placeholder, value: $value, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            if !isValid {
                Text("Port must be between 1 and 65535")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct DomainsEditor: View {
    @Binding var domains: [String]

    var body: some View {
        ForEach(Array(domains.enumerated()), id: \.offset) { idx, _ in
            HStack {
                TextField("v.example.com", text: $domains[idx])
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if domains.count > 1 {
                    Button(role: .destructive) {
                        domains.remove(at: idx)
                    } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                }
            }
        }
        Button {
            domains.append("")
        } label: {
            Label("Add domain", systemImage: "plus.circle")
        }
    }
}

private struct ResolverEditor: View {
    @Binding var resolvers: [ResolverEntry]
    @State private var showingEditor = false
    @State private var editorText = ""

    var body: some View {
        Button {
            editorText = bulkText
            showingEditor = true
        } label: {
            HStack {
                Label("Bulk edit", systemImage: "square.and.pencil")
                Spacer()
                Text("\(activeCount)/\(resolvers.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }

        if resolvers.isEmpty {
            Text("No resolvers")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(resolvers.enumerated()), id: \.element.id) { idx, _ in
                ResolverRow(
                    resolver: $resolvers[idx],
                    onDelete: { resolvers.remove(at: idx) }
                )
            }
        }

        Button {
            resolvers.append(ResolverEntry(ip: "", port: 53, enabled: true))
        } label: {
            Label("Add resolver", systemImage: "plus.circle")
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $editorText)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        .padding(12)
                    if editorText.isEmpty {
                        Text("192.0.2.10, 192.0.2.11\n192.0.2.12")
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle("Resolvers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            resolvers = ResolverEntry.parseList(editorText, existing: resolvers)
                            showingEditor = false
                        }
                    }
                }
            }
        }
    }

    private var activeCount: Int {
        resolvers.filter { $0.enabled && ResolverEntry.isValid(host: $0.ip, port: $0.port) }.count
    }

    private var bulkText: String {
        resolvers
            .filter { !$0.ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.displayAddress)
            .joined(separator: "\n")
    }

}

private struct ResolverRow: View {
    @Binding var resolver: ResolverEntry
    let onDelete: () -> Void

    @State private var draftText: String = ""
    @State private var didLoad = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                resolver.enabled.toggle()
            } label: {
                Image(systemName: resolver.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(resolver.enabled ? Color.accentColor : Color.secondary)
                    .font(.body)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                TextField("192.0.2.10:53", text: $draftText)
                    .font(.subheadline.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .onAppear {
                        guard !didLoad else { return }
                        didLoad = true
                        draftText = initialText
                    }
                    .onChange(of: draftText) { _, new in
                        commit(new)
                    }
                if !isValid {
                    Text("Invalid address")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 4)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private var initialText: String {
        let trimmed = resolver.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return resolver.displayAddress
    }

    private var isValid: Bool {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return ResolverEntry.isValid(host: resolver.ip, port: resolver.port)
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resolver.ip = ""
            resolver.port = 53
            return
        }
        if trimmed.hasPrefix("["), let closing = trimmed.firstIndex(of: "]") {
            resolver.ip = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let rest = String(trimmed[trimmed.index(after: closing)...])
            resolver.port = rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? 53 : 53
            return
        }
        let colonCount = trimmed.filter { $0 == ":" }.count
        if colonCount == 1,
           let colon = trimmed.firstIndex(of: ":"),
           let port = Int(trimmed[trimmed.index(after: colon)...]) {
            resolver.ip = String(trimmed[..<colon])
            resolver.port = port
            return
        }
        resolver.ip = trimmed
        resolver.port = 53
    }
}
