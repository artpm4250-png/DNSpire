import Foundation
import Combine

/// Named-snapshot manager for the three independent slices of
/// [[ClientConfigDraft]]: server identity, resolver list, transport tuning.
///
/// Design (see plan `humble-hopping-rabin`):
/// `ConfigStore.draft` remains the live working state that SwiftUI Bindings
/// write into. `ProfileStore` keeps separate persisted snapshots that the
/// user can switch between (apply → overwrite draft) or capture into
/// (overwrite → draft into a profile). Connect-flow still reads `draft` —
/// profiles are invisible to it.
///
/// Stage 0 invariant: every profile list has ≥1 entry. Add/Delete arrive in
/// Stage 4 (Profiles tab); for now profiles are created only via
/// `duplicate*` or `capture*AsNew`, and never removed, so the invariant
/// holds trivially.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile]
    @Published private(set) var resolverProfiles: [ResolverProfile]
    @Published private(set) var tuningPresets: [TuningPreset]
    @Published private(set) var activeServerID: UUID
    @Published private(set) var activeResolverID: UUID
    @Published private(set) var activeTuningID: UUID

    private static let kServers = "DNSpire.profiles.servers.v1"
    private static let kResolvers = "DNSpire.profiles.resolverProfiles.v1"
    private static let kTunings = "DNSpire.profiles.tuningPresets.v1"
    private static let kActive = "DNSpire.profiles.active.v1"
    private static let kLegacyDraft = "DNSpire.configDraft.v1"

    private struct ActiveIDs: Codable {
        var server: UUID
        var resolver: UUID
        var tuning: UUID
    }

    /// Per-slice diff between the live draft and the currently-active profile
    /// of each kind. SwiftUI uses `.any` to decide whether to surface the
    /// "Save to profile" button at all, and per-slice flags to mark rows with
    /// "(modified)" suffix.
    struct Divergence {
        let server: Bool
        let resolver: Bool
        let tuning: Bool
        var any: Bool { server || resolver || tuning }
    }

    init() {
        let defaults = UserDefaults.standard
        if let loaded = Self.loadPersisted(from: defaults) {
            self.servers = loaded.servers
            self.resolverProfiles = loaded.resolverProfiles
            self.tuningPresets = loaded.tuningPresets
            self.activeServerID = loaded.activeServerID
            self.activeResolverID = loaded.activeResolverID
            self.activeTuningID = loaded.activeTuningID
            return
        }

        let seed = Self.seedDefaults(from: defaults)
        self.servers = [seed.server]
        self.resolverProfiles = [seed.resolver]
        self.tuningPresets = [seed.tuning]
        self.activeServerID = seed.server.id
        self.activeResolverID = seed.resolver.id
        self.activeTuningID = seed.tuning.id
        persist()
    }

    // MARK: - Active accessors

    var activeServer: ServerProfile {
        servers.first { $0.id == activeServerID } ?? servers[0]
    }

    var activeResolver: ResolverProfile {
        resolverProfiles.first { $0.id == activeResolverID } ?? resolverProfiles[0]
    }

    var activeTuning: TuningPreset {
        tuningPresets.first { $0.id == activeTuningID } ?? tuningPresets[0]
    }

    // MARK: - Apply (profile → draft)

    func applyServer(_ id: UUID, to draft: inout ClientConfigDraft) {
        guard let p = servers.first(where: { $0.id == id }) else { return }
        Self.writeServer(p, into: &draft)
    }

    func applyResolver(_ id: UUID, to draft: inout ClientConfigDraft) {
        guard let p = resolverProfiles.first(where: { $0.id == id }) else { return }
        Self.writeResolver(p, into: &draft)
    }

    func applyTuning(_ id: UUID, to draft: inout ClientConfigDraft) {
        guard let p = tuningPresets.first(where: { $0.id == id }) else { return }
        Self.writeTuning(p, into: &draft)
    }

    /// Force-apply the active profile for every slice. Called once at app
    /// launch so the live draft matches the persisted active selection even
    /// if the legacy draft key held stale values from before profiles
    /// existed.
    func applyActiveAll(to draft: inout ClientConfigDraft) {
        Self.writeServer(activeServer, into: &draft)
        Self.writeResolver(activeResolver, into: &draft)
        Self.writeTuning(activeTuning, into: &draft)
    }

    // MARK: - Capture as new (draft → new profile)

    @discardableResult
    func captureServerAsNew(from draft: ClientConfigDraft, name: String) -> UUID {
        let p = ServerProfile(
            name: Self.uniqueName(name, existing: servers.map(\.name)),
            domains: draft.domains,
            encryptionKey: draft.encryptionKey,
            dataEncryptionMethod: draft.dataEncryptionMethod
        )
        servers.append(p)
        persistServers()
        return p.id
    }

    @discardableResult
    func captureResolverAsNew(from draft: ClientConfigDraft, name: String) -> UUID {
        let p = ResolverProfile(
            name: Self.uniqueName(name, existing: resolverProfiles.map(\.name)),
            resolvers: draft.resolvers
        )
        resolverProfiles.append(p)
        persistResolvers()
        return p.id
    }

    @discardableResult
    func captureTuningAsNew(from draft: ClientConfigDraft, name: String) -> UUID {
        let p = TuningPreset(
            name: Self.uniqueName(name, existing: tuningPresets.map(\.name)),
            protocolType: draft.protocolType,
            listenIP: draft.listenIP,
            listenPort: draft.listenPort,
            socks5AuthEnabled: draft.socks5AuthEnabled,
            socks5User: draft.socks5User,
            socks5Pass: draft.socks5Pass,
            resolverBalancingStrategy: draft.resolverBalancingStrategy,
            logLevel: draft.logLevel,
            uploadCompressionType: draft.uploadCompressionType,
            downloadCompressionType: draft.downloadCompressionType,
            compressionMinSize: draft.compressionMinSize,
            mtuTestRetries: draft.mtuTestRetries,
            mtuTestTimeout: draft.mtuTestTimeout,
            mtuTestParallelism: draft.mtuTestParallelism,
            packetDuplicationCount: draft.packetDuplicationCount,
            setupPacketDuplicationCount: draft.setupPacketDuplicationCount,
            rxTxWorkers: draft.rxTxWorkers,
            maxPacketsPerBatch: draft.maxPacketsPerBatch,
            arqWindowSize: draft.arqWindowSize,
            systemVPNDNSResolver: draft.systemVPNDNSResolver
        )
        tuningPresets.append(p)
        persistTunings()
        return p.id
    }

    // MARK: - Overwrite active (draft → active profile, preserving id + name)

    func overwriteActiveServer(from draft: ClientConfigDraft) {
        guard let idx = servers.firstIndex(where: { $0.id == activeServerID }) else { return }
        let existing = servers[idx]
        servers[idx] = ServerProfile(
            id: existing.id,
            name: existing.name,
            domains: draft.domains,
            encryptionKey: draft.encryptionKey,
            dataEncryptionMethod: draft.dataEncryptionMethod
        )
        persistServers()
    }

    func overwriteActiveResolver(from draft: ClientConfigDraft) {
        guard let idx = resolverProfiles.firstIndex(where: { $0.id == activeResolverID }) else { return }
        let existing = resolverProfiles[idx]
        resolverProfiles[idx] = ResolverProfile(
            id: existing.id,
            name: existing.name,
            resolvers: draft.resolvers
        )
        persistResolvers()
    }

    func overwriteActiveTuning(from draft: ClientConfigDraft) {
        guard let idx = tuningPresets.firstIndex(where: { $0.id == activeTuningID }) else { return }
        let existing = tuningPresets[idx]
        tuningPresets[idx] = TuningPreset(
            id: existing.id,
            name: existing.name,
            protocolType: draft.protocolType,
            listenIP: draft.listenIP,
            listenPort: draft.listenPort,
            socks5AuthEnabled: draft.socks5AuthEnabled,
            socks5User: draft.socks5User,
            socks5Pass: draft.socks5Pass,
            resolverBalancingStrategy: draft.resolverBalancingStrategy,
            logLevel: draft.logLevel,
            uploadCompressionType: draft.uploadCompressionType,
            downloadCompressionType: draft.downloadCompressionType,
            compressionMinSize: draft.compressionMinSize,
            mtuTestRetries: draft.mtuTestRetries,
            mtuTestTimeout: draft.mtuTestTimeout,
            mtuTestParallelism: draft.mtuTestParallelism,
            packetDuplicationCount: draft.packetDuplicationCount,
            setupPacketDuplicationCount: draft.setupPacketDuplicationCount,
            rxTxWorkers: draft.rxTxWorkers,
            maxPacketsPerBatch: draft.maxPacketsPerBatch,
            arqWindowSize: draft.arqWindowSize,
            systemVPNDNSResolver: draft.systemVPNDNSResolver
        )
        persistTunings()
    }

    // MARK: - Rename

    func renameServer(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].name = trimmed
        persistServers()
    }

    func renameResolver(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = resolverProfiles.firstIndex(where: { $0.id == id }) else { return }
        resolverProfiles[idx].name = trimmed
        persistResolvers()
    }

    func renameTuning(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = tuningPresets.firstIndex(where: { $0.id == id }) else { return }
        tuningPresets[idx].name = trimmed
        persistTunings()
    }

    // MARK: - Switch active (sets active + writes its fields into draft)

    func setActiveServer(_ id: UUID, applying draft: inout ClientConfigDraft) {
        guard let p = servers.first(where: { $0.id == id }) else { return }
        activeServerID = id
        Self.writeServer(p, into: &draft)
        persistActive()
    }

    func setActiveResolver(_ id: UUID, applying draft: inout ClientConfigDraft) {
        guard let p = resolverProfiles.first(where: { $0.id == id }) else { return }
        activeResolverID = id
        Self.writeResolver(p, into: &draft)
        persistActive()
    }

    func setActiveTuning(_ id: UUID, applying draft: inout ClientConfigDraft) {
        guard let p = tuningPresets.first(where: { $0.id == id }) else { return }
        activeTuningID = id
        Self.writeTuning(p, into: &draft)
        persistActive()
    }

    // MARK: - Duplicate

    @discardableResult
    func duplicateServer(_ id: UUID) -> UUID {
        guard let src = servers.first(where: { $0.id == id }) else { return id }
        let copy = ServerProfile(
            name: Self.copyName(of: src.name, existing: servers.map(\.name)),
            domains: src.domains,
            encryptionKey: src.encryptionKey,
            dataEncryptionMethod: src.dataEncryptionMethod
        )
        let insertAt = (servers.firstIndex { $0.id == id }).map { servers.index(after: $0) } ?? servers.endIndex
        servers.insert(copy, at: insertAt)
        persistServers()
        return copy.id
    }

    @discardableResult
    func duplicateResolver(_ id: UUID) -> UUID {
        guard let src = resolverProfiles.first(where: { $0.id == id }) else { return id }
        let copy = ResolverProfile(
            name: Self.copyName(of: src.name, existing: resolverProfiles.map(\.name)),
            resolvers: src.resolvers
        )
        let insertAt = (resolverProfiles.firstIndex { $0.id == id }).map { resolverProfiles.index(after: $0) } ?? resolverProfiles.endIndex
        resolverProfiles.insert(copy, at: insertAt)
        persistResolvers()
        return copy.id
    }

    @discardableResult
    func duplicateTuning(_ id: UUID) -> UUID {
        guard let src = tuningPresets.first(where: { $0.id == id }) else { return id }
        let copy = TuningPreset(
            name: Self.copyName(of: src.name, existing: tuningPresets.map(\.name)),
            protocolType: src.protocolType,
            listenIP: src.listenIP,
            listenPort: src.listenPort,
            socks5AuthEnabled: src.socks5AuthEnabled,
            socks5User: src.socks5User,
            socks5Pass: src.socks5Pass,
            resolverBalancingStrategy: src.resolverBalancingStrategy,
            logLevel: src.logLevel,
            uploadCompressionType: src.uploadCompressionType,
            downloadCompressionType: src.downloadCompressionType,
            compressionMinSize: src.compressionMinSize,
            mtuTestRetries: src.mtuTestRetries,
            mtuTestTimeout: src.mtuTestTimeout,
            mtuTestParallelism: src.mtuTestParallelism,
            packetDuplicationCount: src.packetDuplicationCount,
            setupPacketDuplicationCount: src.setupPacketDuplicationCount,
            rxTxWorkers: src.rxTxWorkers,
            maxPacketsPerBatch: src.maxPacketsPerBatch,
            arqWindowSize: src.arqWindowSize,
            systemVPNDNSResolver: src.systemVPNDNSResolver
        )
        let insertAt = (tuningPresets.firstIndex { $0.id == id }).map { tuningPresets.index(after: $0) } ?? tuningPresets.endIndex
        tuningPresets.insert(copy, at: insertAt)
        persistTunings()
        return copy.id
    }

    // MARK: - Divergence

    func divergence(from draft: ClientConfigDraft) -> Divergence {
        Divergence(
            server: serverDiverged(from: draft),
            resolver: resolverDiverged(from: draft),
            tuning: tuningDiverged(from: draft)
        )
    }

    private func serverDiverged(from draft: ClientConfigDraft) -> Bool {
        let p = activeServer
        return p.domains != draft.domains
            || p.encryptionKey != draft.encryptionKey
            || p.dataEncryptionMethod != draft.dataEncryptionMethod
    }

    private func resolverDiverged(from draft: ClientConfigDraft) -> Bool {
        // Compare content only — `ResolverEntry.id` is excluded from
        // `CodingKeys` so a fresh decode generates a new UUID. After
        // ConfigStore and ProfileStore both decode the same legacy data on
        // first launch their resolver IDs will not match, yet the content
        // is identical. Auto-synthesized `Equatable` would flag that as
        // divergence — we must not.
        let a = activeResolver.resolvers
        let b = draft.resolvers
        guard a.count == b.count else { return true }
        for (lhs, rhs) in zip(a, b) {
            if lhs.ip != rhs.ip || lhs.port != rhs.port || lhs.enabled != rhs.enabled {
                return true
            }
        }
        return false
    }

    private func tuningDiverged(from draft: ClientConfigDraft) -> Bool {
        let p = activeTuning
        return p.protocolType != draft.protocolType
            || p.listenIP != draft.listenIP
            || p.listenPort != draft.listenPort
            || p.socks5AuthEnabled != draft.socks5AuthEnabled
            || p.socks5User != draft.socks5User
            || p.socks5Pass != draft.socks5Pass
            || p.resolverBalancingStrategy != draft.resolverBalancingStrategy
            || p.logLevel != draft.logLevel
            || p.uploadCompressionType != draft.uploadCompressionType
            || p.downloadCompressionType != draft.downloadCompressionType
            || p.compressionMinSize != draft.compressionMinSize
            || p.mtuTestRetries != draft.mtuTestRetries
            || p.mtuTestTimeout != draft.mtuTestTimeout
            || p.mtuTestParallelism != draft.mtuTestParallelism
            || p.packetDuplicationCount != draft.packetDuplicationCount
            || p.setupPacketDuplicationCount != draft.setupPacketDuplicationCount
            || p.rxTxWorkers != draft.rxTxWorkers
            || p.maxPacketsPerBatch != draft.maxPacketsPerBatch
            || p.arqWindowSize != draft.arqWindowSize
            || p.systemVPNDNSResolver != draft.systemVPNDNSResolver
    }

    // MARK: - Persistence

    private func persist() {
        persistServers()
        persistResolvers()
        persistTunings()
        persistActive()
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.kServers)
        }
    }

    private func persistResolvers() {
        if let data = try? JSONEncoder().encode(resolverProfiles) {
            UserDefaults.standard.set(data, forKey: Self.kResolvers)
        }
    }

    private func persistTunings() {
        if let data = try? JSONEncoder().encode(tuningPresets) {
            UserDefaults.standard.set(data, forKey: Self.kTunings)
        }
    }

    private func persistActive() {
        let ids = ActiveIDs(
            server: activeServerID,
            resolver: activeResolverID,
            tuning: activeTuningID
        )
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: Self.kActive)
        }
    }

    // MARK: - Migration / load

    private struct PersistedSnapshot {
        let servers: [ServerProfile]
        let resolverProfiles: [ResolverProfile]
        let tuningPresets: [TuningPreset]
        let activeServerID: UUID
        let activeResolverID: UUID
        let activeTuningID: UUID
    }

    private static func loadPersisted(from defaults: UserDefaults) -> PersistedSnapshot? {
        guard
            let activeData = defaults.data(forKey: kActive),
            let active = try? JSONDecoder().decode(ActiveIDs.self, from: activeData),
            let serversData = defaults.data(forKey: kServers),
            let servers = try? JSONDecoder().decode([ServerProfile].self, from: serversData),
            !servers.isEmpty,
            let resolversData = defaults.data(forKey: kResolvers),
            let resolverProfiles = try? JSONDecoder().decode([ResolverProfile].self, from: resolversData),
            !resolverProfiles.isEmpty,
            let tuningsData = defaults.data(forKey: kTunings),
            let tuningPresets = try? JSONDecoder().decode([TuningPreset].self, from: tuningsData),
            !tuningPresets.isEmpty
        else {
            return nil
        }
        // If the saved active IDs were orphaned (profile deleted in a future
        // version), fall back to the head of each list — preserves the
        // invariant "active points at a real profile".
        let serverID = servers.contains { $0.id == active.server } ? active.server : servers[0].id
        let resolverID = resolverProfiles.contains { $0.id == active.resolver } ? active.resolver : resolverProfiles[0].id
        let tuningID = tuningPresets.contains { $0.id == active.tuning } ? active.tuning : tuningPresets[0].id
        return PersistedSnapshot(
            servers: servers,
            resolverProfiles: resolverProfiles,
            tuningPresets: tuningPresets,
            activeServerID: serverID,
            activeResolverID: resolverID,
            activeTuningID: tuningID
        )
    }

    private struct SeedTriple {
        let server: ServerProfile
        let resolver: ResolverProfile
        let tuning: TuningPreset
    }

    /// Build initial "Default" profiles by reading the legacy
    /// `DNSpire.configDraft.v1` key — preserving anything the user already
    /// configured on the pre-profile build — or falling back to
    /// `ClientConfigDraft.default` for a fresh install.
    ///
    /// Note: the `oldDefaultPublic` resolver wipe at
    /// `ClientConfigDraft.init(from:)` still fires here because the legacy
    /// decoder is what reads the legacy key. Per-profile decoding does NOT
    /// wipe — `ResolverProfile.init(from:)` is auto-synthesized.
    private static func seedDefaults(from defaults: UserDefaults) -> SeedTriple {
        let source: ClientConfigDraft = {
            if let legacy = defaults.data(forKey: kLegacyDraft),
               let draft = try? JSONDecoder().decode(ClientConfigDraft.self, from: legacy) {
                return draft
            }
            return .default
        }()
        let server = ServerProfile(
            name: "Default",
            domains: source.domains,
            encryptionKey: source.encryptionKey,
            dataEncryptionMethod: source.dataEncryptionMethod
        )
        let resolver = ResolverProfile(name: "Default", resolvers: source.resolvers)
        let tuning = TuningPreset(
            name: "Default",
            protocolType: source.protocolType,
            listenIP: source.listenIP,
            listenPort: source.listenPort,
            socks5AuthEnabled: source.socks5AuthEnabled,
            socks5User: source.socks5User,
            socks5Pass: source.socks5Pass,
            resolverBalancingStrategy: source.resolverBalancingStrategy,
            logLevel: source.logLevel,
            uploadCompressionType: source.uploadCompressionType,
            downloadCompressionType: source.downloadCompressionType,
            compressionMinSize: source.compressionMinSize,
            mtuTestRetries: source.mtuTestRetries,
            mtuTestTimeout: source.mtuTestTimeout,
            mtuTestParallelism: source.mtuTestParallelism,
            packetDuplicationCount: source.packetDuplicationCount,
            setupPacketDuplicationCount: source.setupPacketDuplicationCount,
            rxTxWorkers: source.rxTxWorkers,
            maxPacketsPerBatch: source.maxPacketsPerBatch,
            arqWindowSize: source.arqWindowSize,
            systemVPNDNSResolver: source.systemVPNDNSResolver
        )
        return SeedTriple(server: server, resolver: resolver, tuning: tuning)
    }

    // MARK: - Field writers (single source of truth, called by apply / setActive)

    private static func writeServer(_ p: ServerProfile, into draft: inout ClientConfigDraft) {
        draft.domains = p.domains
        draft.encryptionKey = p.encryptionKey
        draft.dataEncryptionMethod = p.dataEncryptionMethod
    }

    private static func writeResolver(_ p: ResolverProfile, into draft: inout ClientConfigDraft) {
        draft.resolvers = p.resolvers
    }

    private static func writeTuning(_ p: TuningPreset, into draft: inout ClientConfigDraft) {
        draft.protocolType = p.protocolType
        draft.listenIP = p.listenIP
        draft.listenPort = p.listenPort
        draft.socks5AuthEnabled = p.socks5AuthEnabled
        draft.socks5User = p.socks5User
        draft.socks5Pass = p.socks5Pass
        draft.resolverBalancingStrategy = p.resolverBalancingStrategy
        draft.logLevel = p.logLevel
        draft.uploadCompressionType = p.uploadCompressionType
        draft.downloadCompressionType = p.downloadCompressionType
        draft.compressionMinSize = p.compressionMinSize
        draft.mtuTestRetries = p.mtuTestRetries
        draft.mtuTestTimeout = p.mtuTestTimeout
        draft.mtuTestParallelism = p.mtuTestParallelism
        draft.packetDuplicationCount = p.packetDuplicationCount
        draft.setupPacketDuplicationCount = p.setupPacketDuplicationCount
        draft.rxTxWorkers = p.rxTxWorkers
        draft.maxPacketsPerBatch = p.maxPacketsPerBatch
        draft.arqWindowSize = p.arqWindowSize
        draft.systemVPNDNSResolver = p.systemVPNDNSResolver
    }

    // MARK: - Naming helpers

    private static func uniqueName(_ base: String, existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "Untitled" : trimmed
        if !existing.contains(seed) { return seed }
        var i = 2
        while existing.contains("\(seed) (\(i))") { i += 1 }
        return "\(seed) (\(i))"
    }

    private static func copyName(of source: String, existing: [String]) -> String {
        let candidate = "\(source) (copy)"
        if !existing.contains(candidate) { return candidate }
        var i = 2
        while existing.contains("\(source) (copy \(i))") { i += 1 }
        return "\(source) (copy \(i))"
    }

    // MARK: - Preview

    static var preview: ProfileStore {
        ProfileStore()
    }
}
