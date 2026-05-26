import Foundation
import Combine

/// User-editable subset of the upstream MasterDnsVPN client config. Heavy /
/// performance-tuning knobs (worker counts, ARQ timings, MTU bounds) are kept
/// at upstream defaults — exposing them in the UI would clutter the form and
/// most users only need to fill in tunnel identity + resolvers.
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
    /// One of "DEBUG", "INFO", "WARN", "ERROR".
    var logLevel: String

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
        resolvers: ResolverEntry.defaultPublic,
        logLevel: "INFO"
    )
}

struct ResolverEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var ip: String
    var port: Int
    var enabled: Bool

    enum CodingKeys: String, CodingKey { case ip, port, enabled }

    static let defaultPublic: [ResolverEntry] = [
        .init(ip: "1.1.1.1", port: 53, enabled: true),
        .init(ip: "8.8.8.8", port: 53, enabled: true),
        .init(ip: "9.9.9.9", port: 53, enabled: true),
        .init(ip: "1.0.0.1", port: 53, enabled: true),
        .init(ip: "8.8.4.4", port: 53, enabled: true)
    ]
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
            "LOG_LEVEL": draft.logLevel,
            "MTU_TEST_RETRIES": 2,
            "MTU_TEST_TIMEOUT": 2.0
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Serialize enabled resolvers into the text format the upstream client
    /// expects in client_resolvers.txt: one entry per line, "IP" or "IP:PORT".
    func encodedResolversText() -> String {
        draft.resolvers
            .filter { $0.enabled }
            .map { $0.port == 53 ? $0.ip : "\($0.ip):\($0.port)" }
            .joined(separator: "\n")
    }

    static var preview: ConfigStore {
        let s = ConfigStore()
        s.draft.encryptionKey = "preview-shared-key"
        return s
    }
}
