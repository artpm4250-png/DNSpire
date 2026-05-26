import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore

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
                    LabeledContent("Listen IP") {
                        TextField("127.0.0.1", text: $configStore.draft.listenIP)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("Listen port") {
                        TextField("18000", value: $configStore.draft.listenPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
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

                Section("Performance") {
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
                    Stepper("Compression min size: \(configStore.draft.compressionMinSize)",
                            value: $configStore.draft.compressionMinSize,
                            in: 100...65535,
                            step: 50)
                    Stepper("MTU retries: \(configStore.draft.mtuTestRetries)",
                            value: $configStore.draft.mtuTestRetries,
                            in: 1...10)
                    LabeledContent("MTU timeout") {
                        TextField("2.0", value: $configStore.draft.mtuTestTimeout, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper("MTU parallelism: \(configStore.draft.mtuTestParallelism)",
                            value: $configStore.draft.mtuTestParallelism,
                            in: 1...128)
                    Stepper("Packet duplication: \(configStore.draft.packetDuplicationCount)",
                            value: $configStore.draft.packetDuplicationCount,
                            in: 1...8)
                    Stepper("Setup duplication: \(configStore.draft.setupPacketDuplicationCount)",
                            value: $configStore.draft.setupPacketDuplicationCount,
                            in: 1...8)
                    Stepper("RX/TX workers: \(configStore.draft.rxTxWorkers)",
                            value: $configStore.draft.rxTxWorkers,
                            in: 1...32)
                    Stepper("Batch size: \(configStore.draft.maxPacketsPerBatch)",
                            value: $configStore.draft.maxPacketsPerBatch,
                            in: 1...64)
                    Stepper("ARQ window: \(configStore.draft.arqWindowSize)",
                            value: $configStore.draft.arqWindowSize,
                            in: 1...8000,
                            step: 50)
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
            editorText = resolverText
            showingEditor = true
        } label: {
            HStack {
                Label("Edit resolvers", systemImage: "square.and.pencil")
                Spacer()
                Text("\(activeResolvers.count)")
                    .foregroundStyle(.secondary)
            }
        }

        if activeResolvers.isEmpty {
            Text("No resolvers")
                .foregroundStyle(.secondary)
        } else {
            ForEach(activeResolvers.prefix(6)) { resolver in
                Text(resolver.displayAddress)
                    .font(.subheadline)
                    .monospaced()
            }
            if activeResolvers.count > 6 {
                Text("+\(activeResolvers.count - 6)")
                    .foregroundStyle(.secondary)
            }
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
                            resolvers = ResolverEntry.parseList(editorText)
                            showingEditor = false
                        }
                    }
                }
            }
        }
    }

    private var activeResolvers: [ResolverEntry] {
        resolvers
            .filter { $0.enabled && !$0.ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var resolverText: String {
        activeResolvers.map(\.displayAddress).joined(separator: "\n")
    }
}
