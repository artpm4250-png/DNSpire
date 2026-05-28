import SwiftUI
import UIKit

/// Minimal "App preferences" sheet. Replaces the previous Settings tab; per-
/// tuning config (resolver strategy, compression, MTU, ARQ knobs, log level)
/// now lives exclusively in [[TuningPresetEditSheet]] keyed to a specific
/// preset id.
///
/// Hosts truly-global, non-per-preset controls only:
///   • Auto-pick fastest on launch — an app-level behaviour toggle.
///   • **Local proxy** — listener IP/port/SOCKS5 auth. App-wide because they
///     describe where on *this device* the proxy binds, not anything about a
///     tunnel server. Stored in [[ClientConfigDraft]] and surfaced here.
///   • Verify URL — diagnostic endpoint used by the packet-tunnel extension.
///   • Remove iOS VPN profile — a one-shot system action, not a config value.
///   • Reset draft to defaults — destructive escape hatch.
///
/// Log level intentionally NOT here — it moved into TuningPreset so a
/// "debug" tuning can be toggled per-session without shifting a global.
struct AppPreferencesSheet: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var vpn: VPNManager
    @Environment(\.dismiss) private var dismiss

    @State private var showRemoveProfileAlert = false
    @State private var showResetAlert = false

    /// Mirrors the same `@AppStorage` key written by [[DNSpireApp]]. SwiftUI
    /// keeps both views in sync via UserDefaults.
    @AppStorage("DNSpire.autoPickFastestEnabled") private var autoPickEnabled: Bool = false

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
                Section {
                    Toggle("Auto-pick fastest on launch", isOn: $autoPickEnabled)
                } header: {
                    Text("Startup")
                } footer: {
                    Text("On launch, switches the active server to the fastest profile from your last “Test all” run (results must be under 7 days old, applied only when no tunnel is active).")
                }

                Section {
                    Picker("Mode", selection: $configStore.draft.protocolType) {
                        Text("SOCKS5").tag("SOCKS5")
                        Text("TCP").tag("TCP")
                    }
                    ValidatedTextRow(
                        label: "Listen IP",
                        placeholder: "127.0.0.1",
                        text: $configStore.draft.listenIP,
                        keyboard: .URL,
                        error: ConfigStore.validateHost(configStore.draft.listenIP) ? nil : "Invalid IP or hostname"
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
                } header: {
                    Text("Local proxy")
                } footer: {
                    Text("Where the SOCKS5 listener binds in proxy mode. Same address for every server profile — only the upstream tunnel changes.")
                }

                Section {
                    ValidatedTextRow(
                        label: "Verify URL",
                        placeholder: "https://1.1.1.1/cdn-cgi/trace",
                        text: $configStore.draft.verifyURL,
                        keyboard: .URL,
                        error: isValidVerifyURL ? nil : "Must be an https:// URL"
                    )
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("HTTPS endpoint the packet-tunnel extension hits after connecting to confirm end-to-end data flow. Not bound to a profile — change once and it sticks across servers.")
                }

                if vpn.profileInstalled {
                    Section {
                        Button(role: .destructive) {
                            showRemoveProfileAlert = true
                        } label: {
                            Label("Remove VPN profile", systemImage: "trash")
                        }
                    } header: {
                        Text("System VPN")
                    } footer: {
                        Text("Deletes the DNSpire entry from iOS VPN settings. You'll be prompted for permission again the next time you enable System VPN.")
                    }
                }

                Section {
                    Button("Reset draft to defaults", role: .destructive) {
                        showResetAlert = true
                    }
                } footer: {
                    Text("Replaces your current working draft with factory defaults. Saved profiles are untouched — switching to one restores its values.")
                }
            }
            .navigationTitle("App preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Remove VPN profile?", isPresented: $showRemoveProfileAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task { await vpn.removeProfile() }
                }
            } message: {
                Text("Deletes the DNSpire entry from iOS VPN settings. You'll be prompted for permission again the next time you enable System VPN.")
            }
            .alert("Reset draft to defaults?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    configStore.draft = .default
                }
            } message: {
                Text("Your current working values will be replaced. Saved profiles remain intact.")
            }
        }
    }
}

enum ResolverBalancingOption: Int, CaseIterable, Identifiable {
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

enum CompressionOption: Int, CaseIterable, Identifiable {
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
struct ValidatedTextRow: View {
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

struct ValidatedPortRow: View {
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

struct DomainsEditor: View {
    @Binding var domains: [String]
    /// Parallel stable IDs for ForEach. `id: \.offset` on enumerated() lets
    /// SwiftUI think "the row at index 1 is still the same row" after the row
    /// above it is deleted — so focus and any half-typed text stay glued to
    /// that index and migrate onto the wrong domain. UUID per slot fixes it.
    @State private var rowIDs: [UUID] = []

    var body: some View {
        ForEach(Array(rowIDs.enumerated()), id: \.element) { idx, _ in
            HStack {
                TextField("v.example.com", text: bindingForRow(at: idx))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if domains.count > 1 {
                    Button(role: .destructive) {
                        domains.remove(at: idx)
                        rowIDs.remove(at: idx)
                    } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                }
            }
        }
        Button {
            domains.append("")
            rowIDs.append(UUID())
        } label: {
            Label("Add domain", systemImage: "plus.circle")
        }
        .onAppear { syncIDs() }
        .onChange(of: domains.count) { _, _ in syncIDs() }
    }

    /// Body re-renders between the user tapping delete and our @State catching
    /// up. Falls back to a no-op binding for the one frame where idx is out
    /// of range to avoid an index-out-of-bounds crash on `$domains[idx]`.
    private func bindingForRow(at idx: Int) -> Binding<String> {
        guard idx < domains.count else { return .constant("") }
        return $domains[idx]
    }

    /// Reconcile rowIDs to match domains.count. Pads on growth, trims on
    /// shrink — covers external mutations (loadFromStore wholesale-assigns
    /// `domains` on sheet open) that don't go through our buttons.
    private func syncIDs() {
        while rowIDs.count < domains.count { rowIDs.append(UUID()) }
        if rowIDs.count > domains.count {
            rowIDs.removeLast(rowIDs.count - domains.count)
        }
    }
}

struct ResolverEditor: View {
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

struct ResolverRow: View {
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
