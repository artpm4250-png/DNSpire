import Foundation
import Combine

/// Identity slice: who you connect to. Captured into reusable named snapshots
/// by [[ProfileStore]]; selected via the Server row in [[ProfileSelectorCard]].
struct ServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var domains: [String]
    var encryptionKey: String
    /// 0=None, 1=XOR, 2=ChaCha20, 3=AES-128-GCM, 4=AES-192-GCM, 5=AES-256-GCM.
    var dataEncryptionMethod: Int

    enum CodingKeys: String, CodingKey {
        case id, name, domains, encryptionKey, dataEncryptionMethod
    }
}

/// DNS resolver list slice. Held separately from [[ServerProfile]] so the user
/// can swap upstream resolvers without re-entering server identity.
struct ResolverProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var resolvers: [ResolverEntry]

    enum CodingKeys: String, CodingKey { case id, name, resolvers }
}

/// Transport-tuning slice: everything that shapes how the upstream Go client
/// runs the tunnel, but excludes (a) server identity (lives in [[ServerProfile]]),
/// (b) resolver list (lives in [[ResolverProfile]]), and (c) **local proxy
/// settings** (listen address / SOCKS5 auth) — those are app-wide and edited
/// from [[AppPreferencesSheet]] because they describe where on *this device*
/// the SOCKS5 listener binds, not anything about a particular server.
///
/// Lets the user keep e.g. a "fast LTE" preset (high parallelism, short ARQ
/// RTO, aggressive duplication) and a "stable Wi-Fi" preset (relaxed) against
/// the same server. Decoding is lenient: a saved preset from an older build
/// missing the post-2026-05 fields decodes with their `.default` values.
struct TuningPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var resolverBalancingStrategy: Int
    var logLevel: String
    var uploadCompressionType: Int
    var downloadCompressionType: Int
    var compressionMinSize: Int
    var mtuTestRetries: Int
    var mtuTestTimeout: Double
    var mtuTestParallelism: Int
    var packetDuplicationCount: Int
    var setupPacketDuplicationCount: Int
    var rxTxWorkers: Int
    var maxPacketsPerBatch: Int
    var arqWindowSize: Int
    var systemVPNDNSResolver: String

    // Added 2026-05: upstream MasterDNSVpn parameters previously hard-coded
    // to defaults. All ranges and labels mirror upstream `ClientConfig`
    // (internal/config/client.go).
    var minUploadMTU: Int
    var maxUploadMTU: Int
    var minDownloadMTU: Int
    var maxDownloadMTU: Int
    var autoRemoveLowMTUServers: Bool
    var streamResolverFailoverResendThreshold: Int
    var streamResolverFailoverCooldownSec: Double
    var recheckInactiveServersEnabled: Bool
    var autoDisableTimeoutServers: Bool
    var autoDisableTimeoutWindowSeconds: Double
    var baseEncodeData: Bool
    /// `0` = let upstream auto-derive from `rxTxWorkers`. Anything else is an
    /// explicit override. Matches the upstream override semantics: only
    /// non-zero values bypass `deriveRecommendedTunnelProcessWorkers`.
    var tunnelProcessWorkers: Int
    var tunnelPacketTimeoutSec: Double
    var arqInitialRTOSeconds: Double
    var arqMaxRTOSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id, name
        case resolverBalancingStrategy, logLevel
        case uploadCompressionType, downloadCompressionType, compressionMinSize
        case mtuTestRetries, mtuTestTimeout, mtuTestParallelism
        case packetDuplicationCount, setupPacketDuplicationCount
        case rxTxWorkers, maxPacketsPerBatch, arqWindowSize
        case systemVPNDNSResolver
        case minUploadMTU, maxUploadMTU, minDownloadMTU, maxDownloadMTU
        case autoRemoveLowMTUServers
        case streamResolverFailoverResendThreshold
        case streamResolverFailoverCooldownSec
        case recheckInactiveServersEnabled
        case autoDisableTimeoutServers, autoDisableTimeoutWindowSeconds
        case baseEncodeData
        case tunnelProcessWorkers
        case tunnelPacketTimeoutSec
        case arqInitialRTOSeconds, arqMaxRTOSeconds
    }

    init(
        id: UUID = UUID(),
        name: String,
        resolverBalancingStrategy: Int,
        logLevel: String,
        uploadCompressionType: Int,
        downloadCompressionType: Int,
        compressionMinSize: Int,
        mtuTestRetries: Int,
        mtuTestTimeout: Double,
        mtuTestParallelism: Int,
        packetDuplicationCount: Int,
        setupPacketDuplicationCount: Int,
        rxTxWorkers: Int,
        maxPacketsPerBatch: Int,
        arqWindowSize: Int,
        systemVPNDNSResolver: String,
        minUploadMTU: Int,
        maxUploadMTU: Int,
        minDownloadMTU: Int,
        maxDownloadMTU: Int,
        autoRemoveLowMTUServers: Bool,
        streamResolverFailoverResendThreshold: Int,
        streamResolverFailoverCooldownSec: Double,
        recheckInactiveServersEnabled: Bool,
        autoDisableTimeoutServers: Bool,
        autoDisableTimeoutWindowSeconds: Double,
        baseEncodeData: Bool,
        tunnelProcessWorkers: Int,
        tunnelPacketTimeoutSec: Double,
        arqInitialRTOSeconds: Double,
        arqMaxRTOSeconds: Double
    ) {
        self.id = id
        self.name = name
        self.resolverBalancingStrategy = resolverBalancingStrategy
        self.logLevel = logLevel
        self.uploadCompressionType = uploadCompressionType
        self.downloadCompressionType = downloadCompressionType
        self.compressionMinSize = compressionMinSize
        self.mtuTestRetries = mtuTestRetries
        self.mtuTestTimeout = mtuTestTimeout
        self.mtuTestParallelism = mtuTestParallelism
        self.packetDuplicationCount = packetDuplicationCount
        self.setupPacketDuplicationCount = setupPacketDuplicationCount
        self.rxTxWorkers = rxTxWorkers
        self.maxPacketsPerBatch = maxPacketsPerBatch
        self.arqWindowSize = arqWindowSize
        self.systemVPNDNSResolver = systemVPNDNSResolver
        self.minUploadMTU = minUploadMTU
        self.maxUploadMTU = maxUploadMTU
        self.minDownloadMTU = minDownloadMTU
        self.maxDownloadMTU = maxDownloadMTU
        self.autoRemoveLowMTUServers = autoRemoveLowMTUServers
        self.streamResolverFailoverResendThreshold = streamResolverFailoverResendThreshold
        self.streamResolverFailoverCooldownSec = streamResolverFailoverCooldownSec
        self.recheckInactiveServersEnabled = recheckInactiveServersEnabled
        self.autoDisableTimeoutServers = autoDisableTimeoutServers
        self.autoDisableTimeoutWindowSeconds = autoDisableTimeoutWindowSeconds
        self.baseEncodeData = baseEncodeData
        self.tunnelProcessWorkers = tunnelProcessWorkers
        self.tunnelPacketTimeoutSec = tunnelPacketTimeoutSec
        self.arqInitialRTOSeconds = arqInitialRTOSeconds
        self.arqMaxRTOSeconds = arqMaxRTOSeconds
    }

    init(from decoder: Decoder) throws {
        let fallback = ClientConfigDraft.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        self.resolverBalancingStrategy = try container.decodeIfPresent(Int.self, forKey: .resolverBalancingStrategy) ?? fallback.resolverBalancingStrategy
        self.logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? fallback.logLevel
        self.uploadCompressionType = try container.decodeIfPresent(Int.self, forKey: .uploadCompressionType) ?? fallback.uploadCompressionType
        self.downloadCompressionType = try container.decodeIfPresent(Int.self, forKey: .downloadCompressionType) ?? fallback.downloadCompressionType
        self.compressionMinSize = try container.decodeIfPresent(Int.self, forKey: .compressionMinSize) ?? fallback.compressionMinSize
        self.mtuTestRetries = try container.decodeIfPresent(Int.self, forKey: .mtuTestRetries) ?? fallback.mtuTestRetries
        self.mtuTestTimeout = try container.decodeIfPresent(Double.self, forKey: .mtuTestTimeout) ?? fallback.mtuTestTimeout
        self.mtuTestParallelism = try container.decodeIfPresent(Int.self, forKey: .mtuTestParallelism) ?? fallback.mtuTestParallelism
        self.packetDuplicationCount = try container.decodeIfPresent(Int.self, forKey: .packetDuplicationCount) ?? fallback.packetDuplicationCount
        self.setupPacketDuplicationCount = try container.decodeIfPresent(Int.self, forKey: .setupPacketDuplicationCount) ?? fallback.setupPacketDuplicationCount
        self.rxTxWorkers = try container.decodeIfPresent(Int.self, forKey: .rxTxWorkers) ?? fallback.rxTxWorkers
        self.maxPacketsPerBatch = try container.decodeIfPresent(Int.self, forKey: .maxPacketsPerBatch) ?? fallback.maxPacketsPerBatch
        self.arqWindowSize = try container.decodeIfPresent(Int.self, forKey: .arqWindowSize) ?? fallback.arqWindowSize
        self.systemVPNDNSResolver = try container.decodeIfPresent(String.self, forKey: .systemVPNDNSResolver) ?? fallback.systemVPNDNSResolver
        self.minUploadMTU = try container.decodeIfPresent(Int.self, forKey: .minUploadMTU) ?? fallback.minUploadMTU
        self.maxUploadMTU = try container.decodeIfPresent(Int.self, forKey: .maxUploadMTU) ?? fallback.maxUploadMTU
        self.minDownloadMTU = try container.decodeIfPresent(Int.self, forKey: .minDownloadMTU) ?? fallback.minDownloadMTU
        self.maxDownloadMTU = try container.decodeIfPresent(Int.self, forKey: .maxDownloadMTU) ?? fallback.maxDownloadMTU
        self.autoRemoveLowMTUServers = try container.decodeIfPresent(Bool.self, forKey: .autoRemoveLowMTUServers) ?? fallback.autoRemoveLowMTUServers
        self.streamResolverFailoverResendThreshold = try container.decodeIfPresent(Int.self, forKey: .streamResolverFailoverResendThreshold) ?? fallback.streamResolverFailoverResendThreshold
        self.streamResolverFailoverCooldownSec = try container.decodeIfPresent(Double.self, forKey: .streamResolverFailoverCooldownSec) ?? fallback.streamResolverFailoverCooldownSec
        self.recheckInactiveServersEnabled = try container.decodeIfPresent(Bool.self, forKey: .recheckInactiveServersEnabled) ?? fallback.recheckInactiveServersEnabled
        self.autoDisableTimeoutServers = try container.decodeIfPresent(Bool.self, forKey: .autoDisableTimeoutServers) ?? fallback.autoDisableTimeoutServers
        self.autoDisableTimeoutWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .autoDisableTimeoutWindowSeconds) ?? fallback.autoDisableTimeoutWindowSeconds
        self.baseEncodeData = try container.decodeIfPresent(Bool.self, forKey: .baseEncodeData) ?? fallback.baseEncodeData
        self.tunnelProcessWorkers = try container.decodeIfPresent(Int.self, forKey: .tunnelProcessWorkers) ?? fallback.tunnelProcessWorkers
        self.tunnelPacketTimeoutSec = try container.decodeIfPresent(Double.self, forKey: .tunnelPacketTimeoutSec) ?? fallback.tunnelPacketTimeoutSec
        self.arqInitialRTOSeconds = try container.decodeIfPresent(Double.self, forKey: .arqInitialRTOSeconds) ?? fallback.arqInitialRTOSeconds
        self.arqMaxRTOSeconds = try container.decodeIfPresent(Double.self, forKey: .arqMaxRTOSeconds) ?? fallback.arqMaxRTOSeconds
    }
}

struct ClientConfigDraft: Codable, Equatable {
    var domains: [String]
    var encryptionKey: String
    /// 0=None, 1=XOR, 2=ChaCha20, 3=AES-128-GCM, 4=AES-192-GCM, 5=AES-256-GCM.
    var dataEncryptionMethod: Int
    /// "SOCKS5" or "TCP". For local proxy mode, must be SOCKS5. App-wide:
    /// edited from [[AppPreferencesSheet]], not per-tuning preset.
    var protocolType: String
    /// App-wide local proxy listener — edited from [[AppPreferencesSheet]].
    var listenIP: String
    var listenPort: Int
    var socks5AuthEnabled: Bool
    var socks5User: String
    var socks5Pass: String
    var resolvers: [ResolverEntry]
    var resolverBalancingStrategy: Int
    /// One of "DEBUG", "INFO", "WARN", "ERROR". Single source of truth — edited
    /// from per-tuning preset only (no longer duplicated in App preferences).
    var logLevel: String
    var uploadCompressionType: Int
    var downloadCompressionType: Int
    var compressionMinSize: Int
    var mtuTestRetries: Int
    var mtuTestTimeout: Double
    var mtuTestParallelism: Int
    var packetDuplicationCount: Int
    var setupPacketDuplicationCount: Int
    var rxTxWorkers: Int
    var maxPacketsPerBatch: Int
    var arqWindowSize: Int
    /// Upstream DNS resolver the system-VPN extension shims UDP-53 traffic onto
    /// (DNS-over-TCP through SOCKS5). Ignored in local-proxy mode. Format:
    /// "host:port" or "[v6]:port".
    var systemVPNDNSResolver: String
    /// HTTPS URL the packet-tunnel extension hits after `connected` to prove the
    /// tunnel is actually carrying traffic. Must be `https://`; empty falls back
    /// to the default. See [[whitedns-catchup-roadmap]] Stage 3.
    var verifyURL: String

    // Upstream MasterDNSVpn parameters surfaced in [[TuningPresetEditSheet]]
    // (added 2026-05). Defaults mirror `defaultClientConfig()` in
    // upstream/internal/config/client.go which is already mobile-friendly.
    var minUploadMTU: Int
    var maxUploadMTU: Int
    var minDownloadMTU: Int
    var maxDownloadMTU: Int
    var autoRemoveLowMTUServers: Bool
    var streamResolverFailoverResendThreshold: Int
    var streamResolverFailoverCooldownSec: Double
    var recheckInactiveServersEnabled: Bool
    var autoDisableTimeoutServers: Bool
    var autoDisableTimeoutWindowSeconds: Double
    var baseEncodeData: Bool
    /// `0` = upstream auto-derives from `rxTxWorkers`.
    var tunnelProcessWorkers: Int
    var tunnelPacketTimeoutSec: Double
    var arqInitialRTOSeconds: Double
    var arqMaxRTOSeconds: Double

    static let `default` = ClientConfigDraft(
        domains: ["v.example.com"],
        encryptionKey: "",
        dataEncryptionMethod: 1,
        protocolType: "SOCKS5",
        listenIP: "127.0.0.1",
        listenPort: 18000,
        socks5AuthEnabled: false,
        socks5User: "master_dns_vpn",
        socks5Pass: "master_dns_vpn",
        resolvers: [],
        resolverBalancingStrategy: 2,
        logLevel: "INFO",
        uploadCompressionType: 0,
        downloadCompressionType: 0,
        compressionMinSize: 100,
        mtuTestRetries: 2,
        mtuTestTimeout: 2.0,
        mtuTestParallelism: 16,
        packetDuplicationCount: 2,
        setupPacketDuplicationCount: 2,
        rxTxWorkers: 4,
        maxPacketsPerBatch: 8,
        arqWindowSize: 600,
        systemVPNDNSResolver: "1.1.1.1:53",
        verifyURL: "https://1.1.1.1/cdn-cgi/trace",
        minUploadMTU: 38,
        maxUploadMTU: 150,
        minDownloadMTU: 100,
        maxDownloadMTU: 500,
        autoRemoveLowMTUServers: true,
        streamResolverFailoverResendThreshold: 2,
        streamResolverFailoverCooldownSec: 2.5,
        recheckInactiveServersEnabled: true,
        autoDisableTimeoutServers: true,
        autoDisableTimeoutWindowSeconds: 30.0,
        baseEncodeData: false,
        tunnelProcessWorkers: 0,
        tunnelPacketTimeoutSec: 10.0,
        arqInitialRTOSeconds: 1.0,
        arqMaxRTOSeconds: 5.0
    )

    enum CodingKeys: String, CodingKey {
        case domains, encryptionKey, dataEncryptionMethod, protocolType, listenIP, listenPort
        case socks5AuthEnabled, socks5User, socks5Pass, resolvers, resolverBalancingStrategy, logLevel
        case uploadCompressionType, downloadCompressionType, compressionMinSize
        case mtuTestRetries, mtuTestTimeout, mtuTestParallelism
        case packetDuplicationCount, setupPacketDuplicationCount
        case rxTxWorkers, maxPacketsPerBatch, arqWindowSize
        case systemVPNDNSResolver
        case verifyURL
        case minUploadMTU, maxUploadMTU, minDownloadMTU, maxDownloadMTU
        case autoRemoveLowMTUServers
        case streamResolverFailoverResendThreshold
        case streamResolverFailoverCooldownSec
        case recheckInactiveServersEnabled
        case autoDisableTimeoutServers, autoDisableTimeoutWindowSeconds
        case baseEncodeData
        case tunnelProcessWorkers
        case tunnelPacketTimeoutSec
        case arqInitialRTOSeconds, arqMaxRTOSeconds
    }

    init(domains: [String],
         encryptionKey: String,
         dataEncryptionMethod: Int,
         protocolType: String,
         listenIP: String,
         listenPort: Int,
         socks5AuthEnabled: Bool,
         socks5User: String,
         socks5Pass: String,
         resolvers: [ResolverEntry],
         resolverBalancingStrategy: Int,
         logLevel: String,
         uploadCompressionType: Int,
         downloadCompressionType: Int,
         compressionMinSize: Int,
         mtuTestRetries: Int,
         mtuTestTimeout: Double,
         mtuTestParallelism: Int,
         packetDuplicationCount: Int,
         setupPacketDuplicationCount: Int,
         rxTxWorkers: Int,
         maxPacketsPerBatch: Int,
         arqWindowSize: Int,
         systemVPNDNSResolver: String,
         verifyURL: String,
         minUploadMTU: Int,
         maxUploadMTU: Int,
         minDownloadMTU: Int,
         maxDownloadMTU: Int,
         autoRemoveLowMTUServers: Bool,
         streamResolverFailoverResendThreshold: Int,
         streamResolverFailoverCooldownSec: Double,
         recheckInactiveServersEnabled: Bool,
         autoDisableTimeoutServers: Bool,
         autoDisableTimeoutWindowSeconds: Double,
         baseEncodeData: Bool,
         tunnelProcessWorkers: Int,
         tunnelPacketTimeoutSec: Double,
         arqInitialRTOSeconds: Double,
         arqMaxRTOSeconds: Double) {
        self.domains = domains
        self.encryptionKey = encryptionKey
        self.dataEncryptionMethod = dataEncryptionMethod
        self.protocolType = protocolType
        self.listenIP = listenIP
        self.listenPort = listenPort
        self.socks5AuthEnabled = socks5AuthEnabled
        self.socks5User = socks5User
        self.socks5Pass = socks5Pass
        self.resolvers = resolvers
        self.resolverBalancingStrategy = resolverBalancingStrategy
        self.logLevel = logLevel
        self.uploadCompressionType = uploadCompressionType
        self.downloadCompressionType = downloadCompressionType
        self.compressionMinSize = compressionMinSize
        self.mtuTestRetries = mtuTestRetries
        self.mtuTestTimeout = mtuTestTimeout
        self.mtuTestParallelism = mtuTestParallelism
        self.packetDuplicationCount = packetDuplicationCount
        self.setupPacketDuplicationCount = setupPacketDuplicationCount
        self.rxTxWorkers = rxTxWorkers
        self.maxPacketsPerBatch = maxPacketsPerBatch
        self.arqWindowSize = arqWindowSize
        self.systemVPNDNSResolver = systemVPNDNSResolver
        self.verifyURL = verifyURL
        self.minUploadMTU = minUploadMTU
        self.maxUploadMTU = maxUploadMTU
        self.minDownloadMTU = minDownloadMTU
        self.maxDownloadMTU = maxDownloadMTU
        self.autoRemoveLowMTUServers = autoRemoveLowMTUServers
        self.streamResolverFailoverResendThreshold = streamResolverFailoverResendThreshold
        self.streamResolverFailoverCooldownSec = streamResolverFailoverCooldownSec
        self.recheckInactiveServersEnabled = recheckInactiveServersEnabled
        self.autoDisableTimeoutServers = autoDisableTimeoutServers
        self.autoDisableTimeoutWindowSeconds = autoDisableTimeoutWindowSeconds
        self.baseEncodeData = baseEncodeData
        self.tunnelProcessWorkers = tunnelProcessWorkers
        self.tunnelPacketTimeoutSec = tunnelPacketTimeoutSec
        self.arqInitialRTOSeconds = arqInitialRTOSeconds
        self.arqMaxRTOSeconds = arqMaxRTOSeconds
    }

    init(from decoder: Decoder) throws {
        let fallback = ClientConfigDraft.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? fallback.domains
        encryptionKey = try container.decodeIfPresent(String.self, forKey: .encryptionKey) ?? fallback.encryptionKey
        dataEncryptionMethod = try container.decodeIfPresent(Int.self, forKey: .dataEncryptionMethod) ?? fallback.dataEncryptionMethod
        protocolType = try container.decodeIfPresent(String.self, forKey: .protocolType) ?? fallback.protocolType
        listenIP = try container.decodeIfPresent(String.self, forKey: .listenIP) ?? fallback.listenIP
        listenPort = try container.decodeIfPresent(Int.self, forKey: .listenPort) ?? fallback.listenPort
        socks5AuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .socks5AuthEnabled) ?? fallback.socks5AuthEnabled
        socks5User = try container.decodeIfPresent(String.self, forKey: .socks5User) ?? fallback.socks5User
        socks5Pass = try container.decodeIfPresent(String.self, forKey: .socks5Pass) ?? fallback.socks5Pass
        resolvers = try container.decodeIfPresent([ResolverEntry].self, forKey: .resolvers) ?? fallback.resolvers
        if ResolverEntry.matchesOldDefaultPublic(resolvers) {
            resolvers = []
        }
        resolverBalancingStrategy = try container.decodeIfPresent(Int.self, forKey: .resolverBalancingStrategy) ?? fallback.resolverBalancingStrategy
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? fallback.logLevel
        uploadCompressionType = try container.decodeIfPresent(Int.self, forKey: .uploadCompressionType) ?? fallback.uploadCompressionType
        downloadCompressionType = try container.decodeIfPresent(Int.self, forKey: .downloadCompressionType) ?? fallback.downloadCompressionType
        compressionMinSize = try container.decodeIfPresent(Int.self, forKey: .compressionMinSize) ?? fallback.compressionMinSize
        mtuTestRetries = try container.decodeIfPresent(Int.self, forKey: .mtuTestRetries) ?? fallback.mtuTestRetries
        mtuTestTimeout = try container.decodeIfPresent(Double.self, forKey: .mtuTestTimeout) ?? fallback.mtuTestTimeout
        mtuTestParallelism = try container.decodeIfPresent(Int.self, forKey: .mtuTestParallelism) ?? fallback.mtuTestParallelism
        packetDuplicationCount = try container.decodeIfPresent(Int.self, forKey: .packetDuplicationCount) ?? fallback.packetDuplicationCount
        setupPacketDuplicationCount = try container.decodeIfPresent(Int.self, forKey: .setupPacketDuplicationCount) ?? fallback.setupPacketDuplicationCount
        rxTxWorkers = try container.decodeIfPresent(Int.self, forKey: .rxTxWorkers) ?? fallback.rxTxWorkers
        maxPacketsPerBatch = try container.decodeIfPresent(Int.self, forKey: .maxPacketsPerBatch) ?? fallback.maxPacketsPerBatch
        arqWindowSize = try container.decodeIfPresent(Int.self, forKey: .arqWindowSize) ?? fallback.arqWindowSize
        systemVPNDNSResolver = try container.decodeIfPresent(String.self, forKey: .systemVPNDNSResolver) ?? fallback.systemVPNDNSResolver
        verifyURL = try container.decodeIfPresent(String.self, forKey: .verifyURL) ?? fallback.verifyURL
        minUploadMTU = try container.decodeIfPresent(Int.self, forKey: .minUploadMTU) ?? fallback.minUploadMTU
        maxUploadMTU = try container.decodeIfPresent(Int.self, forKey: .maxUploadMTU) ?? fallback.maxUploadMTU
        minDownloadMTU = try container.decodeIfPresent(Int.self, forKey: .minDownloadMTU) ?? fallback.minDownloadMTU
        maxDownloadMTU = try container.decodeIfPresent(Int.self, forKey: .maxDownloadMTU) ?? fallback.maxDownloadMTU
        autoRemoveLowMTUServers = try container.decodeIfPresent(Bool.self, forKey: .autoRemoveLowMTUServers) ?? fallback.autoRemoveLowMTUServers
        streamResolverFailoverResendThreshold = try container.decodeIfPresent(Int.self, forKey: .streamResolverFailoverResendThreshold) ?? fallback.streamResolverFailoverResendThreshold
        streamResolverFailoverCooldownSec = try container.decodeIfPresent(Double.self, forKey: .streamResolverFailoverCooldownSec) ?? fallback.streamResolverFailoverCooldownSec
        recheckInactiveServersEnabled = try container.decodeIfPresent(Bool.self, forKey: .recheckInactiveServersEnabled) ?? fallback.recheckInactiveServersEnabled
        autoDisableTimeoutServers = try container.decodeIfPresent(Bool.self, forKey: .autoDisableTimeoutServers) ?? fallback.autoDisableTimeoutServers
        autoDisableTimeoutWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .autoDisableTimeoutWindowSeconds) ?? fallback.autoDisableTimeoutWindowSeconds
        baseEncodeData = try container.decodeIfPresent(Bool.self, forKey: .baseEncodeData) ?? fallback.baseEncodeData
        tunnelProcessWorkers = try container.decodeIfPresent(Int.self, forKey: .tunnelProcessWorkers) ?? fallback.tunnelProcessWorkers
        tunnelPacketTimeoutSec = try container.decodeIfPresent(Double.self, forKey: .tunnelPacketTimeoutSec) ?? fallback.tunnelPacketTimeoutSec
        arqInitialRTOSeconds = try container.decodeIfPresent(Double.self, forKey: .arqInitialRTOSeconds) ?? fallback.arqInitialRTOSeconds
        arqMaxRTOSeconds = try container.decodeIfPresent(Double.self, forKey: .arqMaxRTOSeconds) ?? fallback.arqMaxRTOSeconds
    }
}

struct ResolverEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var ip: String
    var port: Int
    var enabled: Bool

    enum CodingKeys: String, CodingKey { case ip, port, enabled }

    static let oldDefaultPublic: [ResolverEntry] = [
        .init(ip: "1.1.1.1", port: 53, enabled: true),
        .init(ip: "8.8.8.8", port: 53, enabled: true),
        .init(ip: "9.9.9.9", port: 53, enabled: true),
        .init(ip: "1.0.0.1", port: 53, enabled: true),
        .init(ip: "8.8.4.4", port: 53, enabled: true)
    ]

    var displayAddress: String {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        return port == 53 ? cleanIP : "\(cleanIP):\(port)"
    }

    /// Parse a bulk text blob into resolver entries. Trims whitespace,
    /// validates host/port, drops duplicates (first occurrence wins), and
    /// preserves the `enabled` flag of any entry whose address matches one
    /// already in `existing` (so toggling an entry off and editing the bulk
    /// text doesn't silently re-enable it).
    static func parseList(_ text: String, existing: [ResolverEntry] = []) -> [ResolverEntry] {
        var enabledByKey: [String: Bool] = [:]
        for entry in existing {
            let key = entry.canonicalKey()
            if !key.isEmpty, enabledByKey[key] == nil {
                enabledByKey[key] = entry.enabled
            }
        }
        var seen = Set<String>()
        var out: [ResolverEntry] = []
        for piece in text.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            guard let entry = parse(piece) else { continue }
            let key = entry.canonicalKey()
            if seen.contains(key) { continue }
            seen.insert(key)
            var resolved = entry
            if let prior = enabledByKey[key] {
                resolved.enabled = prior
            }
            out.append(resolved)
        }
        return out
    }

    /// Lower-cased "host:port" for dedup and enabled-flag carryover. Empty if
    /// the entry has no usable host.
    func canonicalKey() -> String {
        let host = ip.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return "" }
        return "\(host):\(port)"
    }

    static func isValid(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        // Accept anything resembling an IPv4/IPv6 literal or a DNS hostname.
        if trimmed.contains(":") {
            return trimmed.split(separator: ":").allSatisfy { seg in
                seg.allSatisfy { $0.isHexDigit || $0 == "." }
            }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func matchesOldDefaultPublic(_ resolvers: [ResolverEntry]) -> Bool {
        let current = resolvers.map { ($0.ip, $0.port, $0.enabled) }
        let old = oldDefaultPublic.map { ($0.ip, $0.port, $0.enabled) }
        return current.elementsEqual(old) { lhs, rhs in
            lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
        }
    }

    private static func parse(_ raw: String) -> ResolverEntry? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var host = value
        var port = 53

        if value.hasPrefix("["),
           let closing = value.firstIndex(of: "]") {
            host = String(value[value.index(after: value.startIndex)..<closing])
            let rest = String(value[value.index(after: closing)...])
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
        } else {
            let colonCount = value.filter { $0 == ":" }.count
            if colonCount == 1,
               let colon = value.firstIndex(of: ":"),
               let p = Int(value[value.index(after: colon)...]) {
                host = String(value[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                port = p
            }
        }

        guard isValid(host: host, port: port) else { return nil }
        return .init(ip: host, port: port, enabled: true)
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published var draft: ClientConfigDraft {
        didSet { persist() }
    }

    private let defaultsKey = "DNSpire.configDraft.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(ClientConfigDraft.self, from: data) {
            self.draft = decoded
        } else {
            self.draft = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Serialize the draft into the JSON shape the upstream Go client expects
    /// (TOML key names, uppercase). Returns nil if required fields are missing.
    ///
    /// `mtuHint`, when non-nil, narrows MIN/MAX_UPLOAD_MTU and
    /// MIN/MAX_DOWNLOAD_MTU to a band around the persisted medians (see
    /// [[MTUHintStore]] for the band width). Upstream still runs an MTU
    /// bisect, but inside a tighter window — cutting bootstrap time on a
    /// known path without skipping validation.
    func encodedConfigJSON(mtuHint: MTUHint? = nil) -> String? {
        encodedConfigJSON(
            domainsSource: draft.domains,
            encryptionKeySource: draft.encryptionKey,
            dataEncryptionMethodSource: draft.dataEncryptionMethod,
            mtuHint: mtuHint
        )
    }

    /// Probe-side variant: same upstream JSON, but server identity (domains,
    /// encryption key, encryption method) comes from a passed [[ServerProfile]]
    /// instead of the live draft. Everything else — resolvers, listener,
    /// compression, MTU knobs — still comes from the draft so the probe
    /// measures the user's *current tuning* against a candidate server.
    func encodedConfigJSON(serverOverride server: ServerProfile) -> String? {
        encodedConfigJSON(
            domainsSource: server.domains,
            encryptionKeySource: server.encryptionKey,
            dataEncryptionMethodSource: server.dataEncryptionMethod,
            mtuHint: nil
        )
    }

    private func encodedConfigJSON(
        domainsSource: [String],
        encryptionKeySource: String,
        dataEncryptionMethodSource: Int,
        mtuHint: MTUHint?
    ) -> String? {
        let cleanedDomains = domainsSource
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedDomains.isEmpty else { return nil }
        guard !encryptionKeySource.isEmpty else { return nil }

        // The Go config struct uses uppercase TOML tags (DOMAINS, ENCRYPTION_KEY,
        // ...). The JSON loader honours those same tags. See upstream:
        // internal/config/json_config.go decodeConfigJSONInto.
        var dict: [String: Any] = [
            "DOMAINS": cleanedDomains,
            "ENCRYPTION_KEY": encryptionKeySource,
            "DATA_ENCRYPTION_METHOD": dataEncryptionMethodSource,
            "PROTOCOL_TYPE": draft.protocolType,
            "LISTEN_IP": draft.listenIP,
            "LISTEN_PORT": draft.listenPort,
            "SOCKS5_AUTH": draft.socks5AuthEnabled,
            "SOCKS5_USER": draft.socks5User,
            "SOCKS5_PASS": draft.socks5Pass,
            "RESOLVER_BALANCING_STRATEGY": draft.resolverBalancingStrategy,
            "LOG_LEVEL": draft.logLevel,
            "UPLOAD_COMPRESSION_TYPE": draft.uploadCompressionType,
            "DOWNLOAD_COMPRESSION_TYPE": draft.downloadCompressionType,
            "COMPRESSION_MIN_SIZE": draft.compressionMinSize,
            "MTU_TEST_RETRIES": draft.mtuTestRetries,
            "MTU_TEST_TIMEOUT": draft.mtuTestTimeout,
            "MTU_TEST_PARALLELISM": draft.mtuTestParallelism,
            "PACKET_DUPLICATION_COUNT": draft.packetDuplicationCount,
            "SETUP_PACKET_DUPLICATION_COUNT": draft.setupPacketDuplicationCount,
            "RX_TX_WORKERS": draft.rxTxWorkers,
            "MAX_PACKETS_PER_BATCH": draft.maxPacketsPerBatch,
            "ARQ_WINDOW_SIZE": draft.arqWindowSize,
            "AUTO_REMOVE_LOW_MTU_SERVERS": draft.autoRemoveLowMTUServers,
            "STREAM_RESOLVER_FAILOVER_RESEND_THRESHOLD": draft.streamResolverFailoverResendThreshold,
            "STREAM_RESOLVER_FAILOVER_COOLDOWN": draft.streamResolverFailoverCooldownSec,
            "RECHECK_INACTIVE_SERVERS_ENABLED": draft.recheckInactiveServersEnabled,
            "AUTO_DISABLE_TIMEOUT_SERVERS": draft.autoDisableTimeoutServers,
            "AUTO_DISABLE_TIMEOUT_WINDOW_SECONDS": draft.autoDisableTimeoutWindowSeconds,
            "BASE_ENCODE_DATA": draft.baseEncodeData,
            "TUNNEL_PACKET_TIMEOUT_SECONDS": draft.tunnelPacketTimeoutSec,
            "ARQ_INITIAL_RTO_SECONDS": draft.arqInitialRTOSeconds,
            "ARQ_MAX_RTO_SECONDS": draft.arqMaxRTOSeconds
        ]

        // TUNNEL_PROCESS_WORKERS: 0 means "let upstream auto-derive". Emitting
        // it as 0 would land on the upstream override path and force the
        // post-clamp value to >= rxTxWorkers, defeating the auto-derive. Only
        // include the key when the user has set an explicit non-zero value.
        if draft.tunnelProcessWorkers > 0 {
            dict["TUNNEL_PROCESS_WORKERS"] = draft.tunnelProcessWorkers
        }

        if let hint = mtuHint {
            let band = MTUHintStore.bandwidth
            // Upstream's hard floors (internal/config/client.go defaults):
            // upload >= 38, download >= 100. Anything tighter risks tripping
            // the "MIN > MAX" validator in cfg.ValidateClient.
            let uMin = max(38, hint.uploadMedian - band)
            let uMax = max(uMin, hint.uploadMedian + band)
            let dMin = max(100, hint.downloadMedian - band)
            let dMax = max(dMin, hint.downloadMedian + band)
            dict["MIN_UPLOAD_MTU"] = uMin
            dict["MAX_UPLOAD_MTU"] = uMax
            dict["MIN_DOWNLOAD_MTU"] = dMin
            dict["MAX_DOWNLOAD_MTU"] = dMax
        } else {
            dict["MIN_UPLOAD_MTU"] = draft.minUploadMTU
            dict["MAX_UPLOAD_MTU"] = draft.maxUploadMTU
            dict["MIN_DOWNLOAD_MTU"] = draft.minDownloadMTU
            dict["MAX_DOWNLOAD_MTU"] = draft.maxDownloadMTU
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Trimmed `host:port` for the extension's DNS-over-TCP shim. Falls back to
    /// the default if the user blanked the field.
    func normalizedSystemVPNDNSResolver() -> String {
        let v = draft.systemVPNDNSResolver.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "1.1.1.1:53" : v
    }

    /// Verify URL passed to the packet-tunnel extension. Falls back to the
    /// default if blank or not an `https://` URL.
    func normalizedVerifyURL() -> String {
        let v = draft.verifyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, let parsed = URL(string: v), parsed.scheme == "https" else {
            return "https://1.1.1.1/cdn-cgi/trace"
        }
        return v
    }

    // Validators are `nonisolated` because they touch no instance state and
    // need to be callable from non-MainActor View structs (e.g. ValidatedRow's
    // computed `isValid`). Without this, Swift 5.9 errors with "call to main
    // actor-isolated static method in a synchronous nonisolated context".

    /// Whether a host string parses as an IPv4/IPv6 literal or DNS label set the
    /// upstream client will accept.
    nonisolated static func validateHost(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ResolverEntry.isValid(host: trimmed, port: 1)
    }

    nonisolated static func validatePort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    /// Validate a `host:port` (or `[v6]:port`) target — same shape the system
    /// VPN extension expects for its DNS-over-TCP resolver.
    nonisolated static func validateHostPort(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else { return false }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let rest = String(trimmed[trimmed.index(after: closing)...])
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return false }
            return ResolverEntry.isValid(host: host, port: port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return false }
        let host = String(trimmed[..<colon])
        let portStr = trimmed[trimmed.index(after: colon)...]
        guard let port = Int(portStr) else { return false }
        return ResolverEntry.isValid(host: host, port: port)
    }

    /// Serialize enabled, valid resolvers into the text format the upstream
    /// client expects in client_resolvers.txt: one entry per line, "IP" or
    /// "IP:PORT". Invalid or disabled entries are dropped.
    func encodedResolversText() -> String {
        draft.resolvers
            .filter { $0.enabled && ResolverEntry.isValid(host: $0.ip, port: $0.port) }
            .map { resolver in
                let ip = resolver.ip.trimmingCharacters(in: .whitespacesAndNewlines)
                return resolver.port == 53 ? ip : "\(ip):\(resolver.port)"
            }
            .joined(separator: "\n")
    }

    static var preview: ConfigStore {
        let s = ConfigStore()
        s.draft.encryptionKey = "preview-shared-key"
        return s
    }
}
