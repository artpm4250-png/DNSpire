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

/// Edit-in-place sheet for a [[TuningPreset]]. Hosts upstream transport
/// knobs only — local-proxy listener (protocolType / listenIP / port /
/// socks5 auth) is app-wide and edited from [[AppPreferencesSheet]]; server
/// identity lives in [[ServerProfileEditSheet]]. Binds to a local `working`
/// TuningPreset so Cancel discards unsaved edits atomically.
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
            systemVPNDNSResolver: d.systemVPNDNSResolver,
            minUploadMTU: d.minUploadMTU,
            maxUploadMTU: d.maxUploadMTU,
            minDownloadMTU: d.minDownloadMTU,
            maxDownloadMTU: d.maxDownloadMTU,
            autoRemoveLowMTUServers: d.autoRemoveLowMTUServers,
            streamResolverFailoverResendThreshold: d.streamResolverFailoverResendThreshold,
            streamResolverFailoverCooldownSec: d.streamResolverFailoverCooldownSec,
            recheckInactiveServersEnabled: d.recheckInactiveServersEnabled,
            autoDisableTimeoutServers: d.autoDisableTimeoutServers,
            autoDisableTimeoutWindowSeconds: d.autoDisableTimeoutWindowSeconds,
            baseEncodeData: d.baseEncodeData,
            tunnelProcessWorkers: d.tunnelProcessWorkers,
            tunnelPacketTimeoutSec: d.tunnelPacketTimeoutSec,
            arqInitialRTOSeconds: d.arqInitialRTOSeconds,
            arqMaxRTOSeconds: d.arqMaxRTOSeconds
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
                    Stepper(value: $working.minUploadMTU, in: 38...4096, step: 2) {
                        LabeledContent("Min upload") {
                            Text("\(working.minUploadMTU) B")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $working.maxUploadMTU, in: max(working.minUploadMTU, 38)...4096, step: 2) {
                        LabeledContent("Max upload") {
                            Text("\(working.maxUploadMTU) B")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $working.minDownloadMTU, in: 100...4096, step: 10) {
                        LabeledContent("Min download") {
                            Text("\(working.minDownloadMTU) B")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $working.maxDownloadMTU, in: max(working.minDownloadMTU, 100)...4096, step: 10) {
                        LabeledContent("Max download") {
                            Text("\(working.maxDownloadMTU) B")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Toggle("Auto-remove low-MTU servers", isOn: $working.autoRemoveLowMTUServers)
                } header: {
                    Text("MTU range")
                } footer: {
                    Text("Bounds the probe's bisect search. A learned MTUHint can narrow these further at connect time; defaults match upstream's mobile-tuned floors.")
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
                    Stepper(value: $working.tunnelProcessWorkers, in: 0...64) {
                        LabeledContent("Process workers") {
                            Text(working.tunnelProcessWorkers == 0 ? "auto" : "\(working.tunnelProcessWorkers)")
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
                    LabeledContent("ARQ initial RTO") {
                        TextField("1.0", value: $working.arqInitialRTOSeconds, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("ARQ max RTO") {
                        TextField("5.0", value: $working.arqMaxRTOSeconds, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Packet timeout") {
                        TextField("10.0", value: $working.tunnelPacketTimeoutSec, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Concurrency & ARQ")
                } footer: {
                    Text("Process workers = 0 lets upstream auto-derive from RX/TX count. ARQ RTO bounds the per-packet retransmit backoff.")
                }

                Section {
                    Stepper(value: $working.streamResolverFailoverResendThreshold, in: 1...256) {
                        LabeledContent("Failover threshold") {
                            Text("\(working.streamResolverFailoverResendThreshold)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    LabeledContent("Failover cooldown") {
                        TextField("2.5", value: $working.streamResolverFailoverCooldownSec, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Recheck inactive resolvers", isOn: $working.recheckInactiveServersEnabled)
                    Toggle("Auto-disable timing-out resolvers", isOn: $working.autoDisableTimeoutServers)
                    if working.autoDisableTimeoutServers {
                        LabeledContent("Disable window") {
                            TextField("30", value: $working.autoDisableTimeoutWindowSeconds, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Resolver resilience")
                } footer: {
                    Text("Controls how aggressively the balancer abandons a struggling resolver and whether disabled resolvers get re-probed.")
                }

                Section {
                    Toggle("Base-encode payloads", isOn: $working.baseEncodeData)
                } header: {
                    Text("Encoding")
                } footer: {
                    Text("Encodes DNS payloads in a printable form. Increases bytes-on-the-wire — only useful with restrictive resolvers that mangle raw binary.")
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
