import SwiftUI

/// Edit-in-place sheet for a single [[ServerProfile]]. Holds a local `working`
/// copy so changes don't leak into [[ConfigStore.draft]] until the user taps
/// Save — at which point [[ProfileStore.updateServer]] writes them back by id
/// and, if the row is the currently-active profile, the draft is re-synced
/// via [[ProfileStore.applyServer]] so the live tunnel config stays aligned.
struct ServerProfileEditSheet: View {
    let id: UUID

    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var domains: [String]
    @State private var encryptionKey: String
    @State private var dataEncryptionMethod: Int
    @State private var loaded: Bool

    init(id: UUID) {
        self.id = id
        // Bindings need a non-empty initial value; the real values are
        // re-read from ProfileStore in .onAppear via `loadFromStore`. We
        // can't read EnvironmentObjects in init, so `loaded` gates a one-shot
        // sync before the form binds to these state values.
        _name = State(initialValue: "")
        _domains = State(initialValue: [""])
        _encryptionKey = State(initialValue: "")
        _dataEncryptionMethod = State(initialValue: 1)
        _loaded = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                Section("Domains") {
                    DomainsEditor(domains: $domains)
                }
                Section("Encryption") {
                    SecureField("Encryption key", text: $encryptionKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Method", selection: $dataEncryptionMethod) {
                        Text("None").tag(0)
                        Text("XOR").tag(1)
                        Text("ChaCha20").tag(2)
                        Text("AES-128-GCM").tag(3)
                        Text("AES-192-GCM").tag(4)
                        Text("AES-256-GCM").tag(5)
                    }
                }
            }
            .navigationTitle("Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { loadFromStore() }
        }
    }

    /// Active profiles must have at least one non-empty domain and a key —
    /// otherwise saving creates a row that can't ever drive a tunnel.
    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        let hasDomain = domains.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasDomain else { return false }
        guard !encryptionKey.isEmpty else { return false }
        return true
    }

    private func loadFromStore() {
        guard !loaded else { return }
        guard let p = profileStore.servers.first(where: { $0.id == id }) else { return }
        name = p.name
        domains = p.domains.isEmpty ? [""] : p.domains
        encryptionKey = p.encryptionKey
        dataEncryptionMethod = p.dataEncryptionMethod
        loaded = true
    }

    private func save() {
        profileStore.updateServer(
            id: id,
            name: name,
            domains: domains,
            encryptionKey: encryptionKey,
            dataEncryptionMethod: dataEncryptionMethod
        )
        if id == profileStore.activeServerID {
            profileStore.applyServer(id, to: &configStore.draft)
        }
        dismiss()
    }
}

/// Edit-in-place sheet for a [[ResolverProfile]]. Reuses the shared
/// [[ResolverEditor]] component (now living in `ConfigEditors.swift`) so the
/// bulk-edit / per-row toggle affordances are identical wherever resolvers
/// are edited.
struct ResolverProfileEditSheet: View {
    let id: UUID

    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var resolvers: [ResolverEntry]
    @State private var loaded: Bool

    init(id: UUID) {
        self.id = id
        _name = State(initialValue: "")
        _resolvers = State(initialValue: [])
        _loaded = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }
                Section("Resolvers") {
                    ResolverEditor(resolvers: $resolvers)
                }
            }
            .navigationTitle("Edit resolvers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { loadFromStore() }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadFromStore() {
        guard !loaded else { return }
        guard let p = profileStore.resolverProfiles.first(where: { $0.id == id }) else { return }
        name = p.name
        resolvers = p.resolvers
        loaded = true
    }

    private func save() {
        profileStore.updateResolver(id: id, name: name, resolvers: resolvers)
        if id == profileStore.activeResolverID {
            profileStore.applyResolver(id, to: &configStore.draft)
        }
        dismiss()
    }
}

/// Edit-in-place sheet for a [[TuningPreset]]. Hosts the Local Proxy +
/// Performance + Advanced tuning controls (now exclusively here — the old
/// global Settings tab is gone). Binds to a local `working` TuningPreset
/// instead of the live draft so Cancel discards unsaved edits atomically.
struct TuningPresetEditSheet: View {
    let id: UUID

    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var working: TuningPreset
    @State private var loaded: Bool

    init(id: UUID) {
        self.id = id
        // Placeholder values — overwritten by loadFromStore on appear. We
        // need a TuningPreset to satisfy @State; using ClientConfigDraft.default
        // as the seed avoids surprising data if loadFromStore somehow misses.
        let d = ClientConfigDraft.default
        _working = State(initialValue: TuningPreset(
            id: id,
            name: "",
            protocolType: d.protocolType,
            listenIP: d.listenIP,
            listenPort: d.listenPort,
            socks5AuthEnabled: d.socks5AuthEnabled,
            socks5User: d.socks5User,
            socks5Pass: d.socks5Pass,
            resolverBalancingStrategy: d.resolverBalancingStrategy,
            logLevel: d.logLevel,
            uploadCompressionType: d.uploadCompressionType,
            downloadCompressionType: d.downloadCompressionType,
            compressionMinSize: d.compressionMinSize,
            mtuTestRetries: d.mtuTestRetries,
            mtuTestTimeout: d.mtuTestTimeout,
            mtuTestParallelism: d.mtuTestParallelism,
            packetDuplicationCount: d.packetDuplicationCount,
            setupPacketDuplicationCount: d.setupPacketDuplicationCount,
            rxTxWorkers: d.rxTxWorkers,
            maxPacketsPerBatch: d.maxPacketsPerBatch,
            arqWindowSize: d.arqWindowSize,
            systemVPNDNSResolver: d.systemVPNDNSResolver
        ))
        _loaded = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Preset name", text: $working.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }

                Section("Local proxy") {
                    Picker("Mode", selection: $working.protocolType) {
                        Text("SOCKS5").tag("SOCKS5")
                        Text("TCP").tag("TCP")
                    }
                    ValidatedTextRow(
                        label: "Listen IP",
                        placeholder: "127.0.0.1",
                        text: $working.listenIP,
                        keyboard: .URL,
                        error: ConfigStore.validateHost(working.listenIP) ? nil : "Invalid IP or hostname"
                    )
                    ValidatedPortRow(
                        label: "Listen port",
                        placeholder: "18000",
                        value: $working.listenPort
                    )
                    Toggle("Require SOCKS5 auth", isOn: $working.socks5AuthEnabled)
                    if working.socks5AuthEnabled {
                        LabeledContent("User") {
                            TextField("user", text: $working.socks5User)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        LabeledContent("Password") {
                            SecureField("password", text: $working.socks5Pass)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section {
                    ValidatedTextRow(
                        label: "Upstream DNS",
                        placeholder: "1.1.1.1:53",
                        text: $working.systemVPNDNSResolver,
                        keyboard: .URL,
                        error: ConfigStore.validateHostPort(working.systemVPNDNSResolver)
                            ? nil : "Expected host:port (e.g. 1.1.1.1:53 or [::1]:53)"
                    )
                } header: {
                    Text("System VPN")
                } footer: {
                    Text("DNS-over-TCP target the packet-tunnel extension shims UDP-53 onto.")
                }

                Section("Performance") {
                    Picker("Resolving strategy", selection: $working.resolverBalancingStrategy) {
                        ForEach(ResolverBalancingOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    Picker("Upload compression", selection: $working.uploadCompressionType) {
                        ForEach(CompressionOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    Picker("Download compression", selection: $working.downloadCompressionType) {
                        ForEach(CompressionOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                }

                Section("Logging") {
                    Picker("Log level", selection: $working.logLevel) {
                        Text("DEBUG").tag("DEBUG")
                        Text("INFO").tag("INFO")
                        Text("WARN").tag("WARN")
                        Text("ERROR").tag("ERROR")
                    }
                }

                Section {
                    Stepper(value: $working.compressionMinSize, in: 100...65535, step: 50) {
                        LabeledContent("Compression min size") {
                            Text("\(working.compressionMinSize) B")
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
                    Stepper(value: $working.mtuTestRetries, in: 1...10) {
                        LabeledContent("Probe retries") {
                            Text("\(working.mtuTestRetries)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    LabeledContent("Probe timeout") {
                        TextField("2.0", value: $working.mtuTestTimeout, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper(value: $working.mtuTestParallelism, in: 1...128) {
                        LabeledContent("Parallelism") {
                            Text("\(working.mtuTestParallelism)")
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
                    Stepper(value: $working.packetDuplicationCount, in: 1...8) {
                        LabeledContent("Packet duplication") {
                            Text("\(working.packetDuplicationCount)×")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $working.setupPacketDuplicationCount, in: 1...8) {
                        LabeledContent("Setup duplication") {
                            Text("\(working.setupPacketDuplicationCount)×")
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
                    Stepper(value: $working.rxTxWorkers, in: 1...32) {
                        LabeledContent("RX/TX workers") {
                            Text("\(working.rxTxWorkers)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $working.maxPacketsPerBatch, in: 1...64) {
                        LabeledContent("Batch size") {
                            Text("\(working.maxPacketsPerBatch)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $working.arqWindowSize, in: 1...8000, step: 50) {
                        LabeledContent("ARQ window") {
                            Text("\(working.arqWindowSize)")
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
            .navigationTitle("Edit tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { loadFromStore() }
        }
    }

    private var canSave: Bool {
        !working.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadFromStore() {
        guard !loaded else { return }
        guard let p = profileStore.tuningPresets.first(where: { $0.id == id }) else { return }
        working = p
        loaded = true
    }

    private func save() {
        profileStore.updateTuning(id: id, with: working)
        if id == profileStore.activeTuningID {
            profileStore.applyTuning(id, to: &configStore.draft)
        }
        dismiss()
    }
}
