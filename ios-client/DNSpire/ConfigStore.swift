import Foundation
import Combine

struct ClientConfigDraft: Codable, Equatable {
    var domains: [String]
    var encryptionKey: String
    /// 0=None, 1=XOR, 2=ChaCha20, 3=AES-128-GCM, 4=AES-192-GCM, 5=AES-256-GCM.
    var dataEncryptionMethod: Int
    /// "SOCKS5" or "TCP". For local proxy mode, must be SOCKS5.
    var protocolType: String
    var listenIP: String
    var listenPort: Int
    var socks5AuthEnabled: Bool
    var socks5User: String
    var socks5Pass: String
    var resolvers: [ResolverEntry]
    var resolverBalancingStrategy: Int
    /// One of "DEBUG", "INFO", "WARN", "ERROR".
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
        systemVPNDNSResolver: "1.1.1.1:53"
    )

    enum CodingKeys: String, CodingKey {
        case domains, encryptionKey, dataEncryptionMethod, protocolType, listenIP, listenPort
        case socks5AuthEnabled, socks5User, socks5Pass, resolvers, resolverBalancingStrategy, logLevel
        case uploadCompressionType, downloadCompressionType, compressionMinSize
        case mtuTestRetries, mtuTestTimeout, mtuTestParallelism
        case packetDuplicationCount, setupPacketDuplicationCount
        case rxTxWorkers, maxPacketsPerBatch, arqWindowSize
        case systemVPNDNSResolver
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
         systemVPNDNSResolver: String) {
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
    func encodedConfigJSON() -> String? {
        let cleanedDomains = draft.domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedDomains.isEmpty else { return nil }
        guard !draft.encryptionKey.isEmpty else { return nil }

        // The Go config struct uses uppercase TOML tags (DOMAINS, ENCRYPTION_KEY,
        // ...). The JSON loader honours those same tags. See upstream:
        // internal/config/json_config.go decodeConfigJSONInto.
        let dict: [String: Any] = [
            "DOMAINS": cleanedDomains,
            "ENCRYPTION_KEY": draft.encryptionKey,
            "DATA_ENCRYPTION_METHOD": draft.dataEncryptionMethod,
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
            "ARQ_WINDOW_SIZE": draft.arqWindowSize
        ]

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

    /// Whether a host string parses as an IPv4/IPv6 literal or DNS label set the
    /// upstream client will accept.
    static func validateHost(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ResolverEntry.isValid(host: trimmed, port: 1)
    }

    static func validatePort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    /// Validate a `host:port` (or `[v6]:port`) target — same shape the system
    /// VPN extension expects for its DNS-over-TCP resolver.
    static func validateHostPort(_ raw: String) -> Bool {
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
