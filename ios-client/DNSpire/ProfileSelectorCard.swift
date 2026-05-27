import SwiftUI

/// One of the three independent profile slices managed by [[ProfileStore]].
/// Used by [[ProfileSelectorCard]] to drive which sheet is presented and by
/// [[ProfileSliceSheet]] to know which list / mutators to operate on.
enum ProfileSliceKind: String, Identifiable {
    case server, resolver, tuning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server:   return "Server profiles"
        case .resolver: return "Resolver profiles"
        case .tuning:   return "Tuning presets"
        }
    }

    var label: String {
        switch self {
        case .server:   return "Server"
        case .resolver: return "Resolvers"
        case .tuning:   return "Tuning"
        }
    }

    var icon: String {
        switch self {
        case .server:   return "server.rack"
        case .resolver: return "antenna.radiowaves.left.and.right"
        case .tuning:   return "slider.horizontal.3"
        }
    }
}

/// Replaces the old static "Configuration" summary in ConnectionView with a
/// tappable card that surfaces the three active profile names and a
/// "(modified)" marker per slice when the live draft diverges from the
/// active profile.
struct ProfileSelectorCard: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore

    @State private var presented: ProfileSliceKind?

    var body: some View {
        let divergence = profileStore.divergence(from: configStore.draft)
        VStack(spacing: 0) {
            header
            divider
            row(.server,
                name: profileStore.activeServer.name,
                modified: divergence.server)
            divider
            row(.resolver,
                name: profileStore.activeResolver.name,
                modified: divergence.resolver)
            divider
            row(.tuning,
                name: profileStore.activeTuning.name,
                modified: divergence.tuning)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(item: $presented) { kind in
            ProfileSliceSheet(slice: kind)
                .environmentObject(configStore)
                .environmentObject(profileStore)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Active profiles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func row(_ kind: ProfileSliceKind, name: String, modified: Bool) -> some View {
        Button {
            presented = kind
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(kind.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if modified {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("modified")
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Auto-pick fastest

/// Banner-style suggestion shown above the connection action button when a
/// recent `Test all` revealed a faster server than the currently-active
/// profile (or the active profile's last probe failed and a working one is
/// available). One tap switches; an `xmark` dismisses until the next probe
/// pass.
///
/// Renders nothing when the user is connected/connecting (changing the
/// active server underneath a live tunnel would tear it down — not what
/// you want for an unsolicited suggestion) or when the active server is
/// already the fastest.
struct FastestServerSuggestionBanner: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var testRunner: ServerTestRunner

    let connectionBusy: Bool

    var body: some View {
        if let pick = suggestion {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Faster server available")
                        .font(.subheadline.weight(.semibold))
                    Text(pick.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Switch") {
                    profileStore.setActiveServer(pick.id, applying: &configStore.draft)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    testRunner.dismissSuggestion()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct Pick {
        let id: UUID
        let body: String
    }

    private var suggestion: Pick? {
        guard !connectionBusy else { return nil }
        guard testRunner.dismissedEpoch != testRunner.runEpoch else { return nil }

        let candidates = profileStore.servers.map(\.id)
        guard let best = testRunner.fastestServerID(among: candidates) else { return nil }
        let activeID = profileStore.activeServerID
        if best.id == activeID { return nil }

        guard let bestName = profileStore.servers.first(where: { $0.id == best.id })?.name else { return nil }
        let activeMs: Int? = {
            guard let r = testRunner.results[activeID], case .ok(let ms) = r.outcome else { return nil }
            return ms
        }()
        let body: String
        if let activeMs {
            // Only suggest if "best" is meaningfully faster — guard against
            // jitter promoting a 1ms difference into a banner.
            guard activeMs - best.ms >= 30 else { return nil }
            body = "\(bestName) — \(best.ms) ms · current \(activeMs) ms"
        } else {
            body = "\(bestName) — \(best.ms) ms · current server has no recent result"
        }
        return Pick(id: best.id, body: body)
    }
}

// MARK: - Slice sheet

/// Modal list of profiles for one slice. Tapping a non-active row prompts to
/// switch (which overwrites the corresponding draft fields). The Actions
/// section exposes "Duplicate active" (creates a copy) and "Rename active"
/// (inline alert). Add/Delete arrive in Stage 4.
struct ProfileSliceSheet: View {
    let slice: ProfileSliceKind

    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var testRunner: ServerTestRunner
    @Environment(\.dismiss) private var dismiss

    private struct PendingSwitch: Identifiable {
        let id: UUID
        let name: String
    }

    @State private var pendingSwitch: PendingSwitch?
    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @State private var shareLink: ShareLinkItem?
    @State private var importing = false

    private struct ShareLinkItem: Identifiable {
        let id = UUID()
        let url: String
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items, id: \.id) { item in
                        row(id: item.id, name: item.name)
                            .modifier(ServerRowProbeActions(
                                slice: slice,
                                onProbe: { probeOne(id: item.id) }
                            ))
                    }
                }
                Section {
                    Button {
                        duplicateActive()
                    } label: {
                        Label("Duplicate active", systemImage: "doc.on.doc")
                    }
                    Button {
                        renamingID = activeID
                        renameText = activeName
                    } label: {
                        Label("Rename active", systemImage: "pencil")
                    }
                    if slice == .server {
                        Button {
                            Task {
                                await testRunner.testAll(
                                    servers: profileStore.servers,
                                    configStore: configStore
                                )
                            }
                        } label: {
                            Label(testRunner.isRunning ? "Testing…" : "Test all",
                                  systemImage: "speedometer")
                        }
                        .disabled(testRunner.isRunning)
                        Button {
                            exportActiveServer()
                        } label: {
                            Label("Share as link", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!canExportActiveServer)
                        Button {
                            importing = true
                        } label: {
                            Label("Import from link…", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .navigationTitle(slice.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Switch to “\(pendingSwitch?.name ?? "")”?",
                isPresented: Binding(
                    get: { pendingSwitch != nil },
                    set: { if !$0 { pendingSwitch = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Switch") {
                    if let p = pendingSwitch {
                        performSwitch(to: p.id)
                    }
                    pendingSwitch = nil
                }
                Button("Cancel", role: .cancel) { pendingSwitch = nil }
            } message: {
                Text("Your current working values will be replaced with the ones saved in this profile.")
            }
            .alert(
                "Rename",
                isPresented: Binding(
                    get: { renamingID != nil },
                    set: { if !$0 { renamingID = nil } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Save") { performRename() }
                Button("Cancel", role: .cancel) { renamingID = nil }
            }
            .sheet(isPresented: $importing) {
                StormDNSImportSheet()
                    .environmentObject(profileStore)
            }
            .sheet(item: $shareLink) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private struct Item { let id: UUID; let name: String }

    private var items: [Item] {
        switch slice {
        case .server:
            return profileStore.servers.map { Item(id: $0.id, name: $0.name) }
        case .resolver:
            return profileStore.resolverProfiles.map { Item(id: $0.id, name: $0.name) }
        case .tuning:
            return profileStore.tuningPresets.map { Item(id: $0.id, name: $0.name) }
        }
    }

    private var activeID: UUID {
        switch slice {
        case .server:   return profileStore.activeServerID
        case .resolver: return profileStore.activeResolverID
        case .tuning:   return profileStore.activeTuningID
        }
    }

    private var activeName: String {
        switch slice {
        case .server:   return profileStore.activeServer.name
        case .resolver: return profileStore.activeResolver.name
        case .tuning:   return profileStore.activeTuning.name
        }
    }

    private func row(id: UUID, name: String) -> some View {
        let isActive = id == activeID
        return Button {
            guard !isActive else { return }
            pendingSwitch = PendingSwitch(id: id, name: name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.body)
                Image(systemName: slice.icon)
                    .font(.caption)
                    .foregroundStyle(.tint.opacity(0.7))
                    .frame(width: 18)
                Text(name)
                    .foregroundStyle(.primary)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer()
                if slice == .server {
                    serverBadge(for: id)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Prefer the transient `outcomes` map (covers `.pending` / `.running`
    /// during a probe pass) and fall back to the persisted `results` so
    /// previous-run scores stay visible across sheet dismissals and launches.
    @ViewBuilder
    private func serverBadge(for id: UUID) -> some View {
        if let live = testRunner.outcomes[id] {
            outcomeBadge(live, persistedAt: testRunner.results[id]?.at)
        } else if let stored = testRunner.results[id] {
            outcomeBadge(stored.outcome, persistedAt: stored.at)
        }
    }

    @ViewBuilder
    private func outcomeBadge(_ outcome: ServerTestRunner.Outcome, persistedAt: Date?) -> some View {
        switch outcome {
        case .pending:
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .ok(let ms):
            HStack(spacing: 6) {
                if let persistedAt {
                    Text(Self.relativeAge(persistedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text("\(ms) ms")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(scoreTint(outcome.score).opacity(0.15))
                    .foregroundStyle(scoreTint(outcome.score))
                    .clipShape(Capsule())
            }
        case .timeout:
            Text("timeout")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        case .fail(let reason):
            Text(reason)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        }
    }

    private func scoreTint(_ score: ServerTestRunner.Outcome.Score?) -> Color {
        switch score {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        case nil:   return .secondary
        }
    }

    /// Compact "12s" / "4m" / "2h" / "3d" age — fits in the row without
    /// wrapping. We don't need full DateComponentsFormatter overhead here.
    private static func relativeAge(_ at: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(at)))
        if secs < 60   { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }

    private func performSwitch(to id: UUID) {
        switch slice {
        case .server:   profileStore.setActiveServer(id, applying: &configStore.draft)
        case .resolver: profileStore.setActiveResolver(id, applying: &configStore.draft)
        case .tuning:   profileStore.setActiveTuning(id, applying: &configStore.draft)
        }
    }

    private func probeOne(id: UUID) {
        guard slice == .server,
              let server = profileStore.servers.first(where: { $0.id == id }) else { return }
        testRunner.testOne(server: server, configStore: configStore)
    }

    private var canExportActiveServer: Bool {
        StormDNSProfileLink.encode(
            name: profileStore.activeServer.name,
            domain: profileStore.activeServer.domains.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "",
            encryptionKey: profileStore.activeServer.encryptionKey,
            encryptionMethod: profileStore.activeServer.dataEncryptionMethod
        ) != nil
    }

    private func exportActiveServer() {
        let s = profileStore.activeServer
        let domain = s.domains.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        guard let link = StormDNSProfileLink.encode(
            name: s.name,
            domain: domain,
            encryptionKey: s.encryptionKey,
            encryptionMethod: s.dataEncryptionMethod
        ) else { return }
        shareLink = ShareLinkItem(url: link)
    }

    private func duplicateActive() {
        let newID: UUID
        switch slice {
        case .server:   newID = profileStore.duplicateServer(activeID)
        case .resolver: newID = profileStore.duplicateResolver(activeID)
        case .tuning:   newID = profileStore.duplicateTuning(activeID)
        }
        // Stay on the same active profile — Duplicate produces a sibling
        // copy, it doesn't switch into it. The user can tap the new row to
        // switch explicitly. (`newID` returned for callers that want to
        // chain a switch, e.g. import flows in Stage 1.)
        _ = newID
    }

    private func performRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = renamingID else {
            renamingID = nil
            return
        }
        switch slice {
        case .server:   profileStore.renameServer(id: id, to: trimmed)
        case .resolver: profileStore.renameResolver(id: id, to: trimmed)
        case .tuning:   profileStore.renameTuning(id: id, to: trimmed)
        }
        renamingID = nil
    }
}

// MARK: - Save to profile

/// Renders only when the live draft has diverged from at least one active
/// profile. Shows a checkbox per diverged slice, defaulted on, plus a Save
/// button that overwrites the chosen active profiles from the draft.
struct SaveToProfileButton: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var profileStore: ProfileStore

    @State private var saveServer = true
    @State private var saveResolver = true
    @State private var saveTuning = true

    var body: some View {
        let div = profileStore.divergence(from: configStore.draft)
        if div.any {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Unsaved changes")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Save") { save(div: div) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!hasAnySelection(div: div))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if div.server {
                        sliceToggle(
                            icon: ProfileSliceKind.server.icon,
                            label: "Server",
                            target: profileStore.activeServer.name,
                            isOn: $saveServer
                        )
                    }
                    if div.resolver {
                        sliceToggle(
                            icon: ProfileSliceKind.resolver.icon,
                            label: "Resolvers",
                            target: profileStore.activeResolver.name,
                            isOn: $saveResolver
                        )
                    }
                    if div.tuning {
                        sliceToggle(
                            icon: ProfileSliceKind.tuning.icon,
                            label: "Tuning",
                            target: profileStore.activeTuning.name,
                            isOn: $saveTuning
                        )
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onChange(of: div.server) { _, new in if !new { saveServer = true } }
            .onChange(of: div.resolver) { _, new in if !new { saveResolver = true } }
            .onChange(of: div.tuning) { _, new in if !new { saveTuning = true } }
        }
    }

    private func sliceToggle(icon: String, label: String, target: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                    .font(.body)
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(target)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hasAnySelection(div: ProfileStore.Divergence) -> Bool {
        (div.server && saveServer)
            || (div.resolver && saveResolver)
            || (div.tuning && saveTuning)
    }

    private func save(div: ProfileStore.Divergence) {
        if div.server && saveServer {
            profileStore.overwriteActiveServer(from: configStore.draft)
        }
        if div.resolver && saveResolver {
            profileStore.overwriteActiveResolver(from: configStore.draft)
        }
        if div.tuning && saveTuning {
            profileStore.overwriteActiveTuning(from: configStore.draft)
        }
    }
}

// MARK: - stormdns:// import

/// Paste-area sheet for importing one or more `stormdns://` server links.
/// Each valid line becomes a new (non-active) server profile via
/// [[ProfileStore.captureServerAsNew]]; invalid lines are listed with reasons.
struct StormDNSImportSheet: View {
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var result: ImportResult?

    private struct ImportResult {
        let importedNames: [String]
        let failures: [String]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Paste one or more stormdns:// links")
                } footer: {
                    Text("Each line is imported as a separate server profile.")
                }

                if let result {
                    Section("Result") {
                        if !result.importedNames.isEmpty {
                            Label("Imported \(result.importedNames.count)", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                            ForEach(result.importedNames, id: \.self) { name in
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(result.failures, id: \.self) { failure in
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Import server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { performImport() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func performImport() {
        let parsed = StormDNSProfileLink.decodeMany(text)
        var names: [String] = []
        for item in parsed.ok {
            var draft = ClientConfigDraft.default
            draft.domains = [item.domain]
            draft.encryptionKey = item.encryptionKey
            draft.dataEncryptionMethod = item.encryptionMethod
            profileStore.captureServerAsNew(from: draft, name: item.name)
            names.append(item.name)
        }
        let failures = parsed.failed.map { f in
            "Line \(f.line): \((f.error as? StormDNSProfileLink.DecodeError)?.errorDescription ?? f.error.localizedDescription)"
        }
        if names.isEmpty && failures.isEmpty {
            result = ImportResult(importedNames: [], failures: ["No valid links found"])
        } else {
            result = ImportResult(importedNames: names, failures: failures)
        }
    }
}

// MARK: - Per-row probe affordances

/// Attaches a trailing swipe action and a long-press context menu to a
/// server-slice row. Renders nothing for resolver/tuning slices — those
/// don't have a meaningful per-row probe yet.
///
/// Lives as a `ViewModifier` rather than chained `.swipeActions` directly on
/// the row so the slice-kind gate is in one place and the row helper stays
/// agnostic to which slice it's drawing.
private struct ServerRowProbeActions: ViewModifier {
    let slice: ProfileSliceKind
    let onProbe: () -> Void

    func body(content: Content) -> some View {
        if slice == .server {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        onProbe()
                    } label: {
                        Label("Test", systemImage: "speedometer")
                    }
                    .tint(.accentColor)
                }
                .contextMenu {
                    Button {
                        onProbe()
                    } label: {
                        Label("Test this server", systemImage: "speedometer")
                    }
                }
        } else {
            content
        }
    }
}
