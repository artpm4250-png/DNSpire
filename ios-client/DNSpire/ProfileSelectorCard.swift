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

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func row(_ kind: ProfileSliceKind, name: String, modified: Bool) -> some View {
        Button {
            presented = kind
        } label: {
            HStack(spacing: 8) {
                Text(kind.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(name)
                    .foregroundStyle(.primary)
                if modified {
                    Text("(modified)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @Environment(\.dismiss) private var dismiss

    private struct PendingSwitch: Identifiable {
        let id: UUID
        let name: String
    }

    @State private var pendingSwitch: PendingSwitch?
    @State private var renamingID: UUID?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items, id: \.id) { item in
                        row(id: item.id, name: item.name)
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
            HStack {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func performSwitch(to id: UUID) {
        switch slice {
        case .server:   profileStore.setActiveServer(id, applying: &configStore.draft)
        case .resolver: profileStore.setActiveResolver(id, applying: &configStore.draft)
        case .tuning:   profileStore.setActiveTuning(id, applying: &configStore.draft)
        }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .foregroundStyle(.orange)
                    Text("Working values changed")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                if div.server {
                    Toggle("Server → \(profileStore.activeServer.name)", isOn: $saveServer)
                        .font(.caption)
                }
                if div.resolver {
                    Toggle("Resolvers → \(profileStore.activeResolver.name)", isOn: $saveResolver)
                        .font(.caption)
                }
                if div.tuning {
                    Toggle("Tuning → \(profileStore.activeTuning.name)", isOn: $saveTuning)
                        .font(.caption)
                }
                Button {
                    save(div: div)
                } label: {
                    Text("Save to profile")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!hasAnySelection(div: div))
            }
            .padding()
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onChange(of: div.server) { _, new in if !new { saveServer = true } }
            .onChange(of: div.resolver) { _, new in if !new { saveResolver = true } }
            .onChange(of: div.tuning) { _, new in if !new { saveTuning = true } }
        }
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
