import Foundation

/// Codec for `stormdns://` profile links — the share format used by the
/// WhiteDNS Android client (`WhiteDnsProfileLinks.kt`). Carries the **server**
/// slice only: name + domain + encryption key + encryption method.
///
/// Wire format:
/// ```
/// stormdns://<base64url-without-padding(JSON)>
/// ```
/// JSON shape:
/// ```json
/// { "schema": "whitedns.profile", "version": 1,
///   "profile": { "name": "...",
///                "server": { "domain": "...",
///                            "encryption_key": "...",
///                            "encryption_method": 0…5 } } }
/// ```
/// Encode/decode rules mirror WhiteDNS exactly so links round-trip between the
/// two clients. See plan `humble-hopping-rabin` (Stage 1).
enum StormDNSProfileLink {
    static let scheme = "stormdns"
    static let schema = "whitedns.profile"
    static let version = 1

    /// Decoded payload, before it's captured into a `ServerProfile`.
    struct Imported {
        var name: String
        var domain: String
        var encryptionKey: String
        var encryptionMethod: Int
    }

    enum DecodeError: Error, LocalizedError {
        case notAStormLink
        case badBase64
        case badJSON
        case wrongSchema
        case missingDomain
        case missingKey
        case methodOutOfRange(Int)

        var errorDescription: String? {
            switch self {
            case .notAStormLink:        return "Not a stormdns:// link"
            case .badBase64:            return "Link body is not valid base64"
            case .badJSON:              return "Link contents are not valid JSON"
            case .wrongSchema:          return "Unsupported link schema or version"
            case .missingDomain:        return "Link is missing a server domain"
            case .missingKey:           return "Link is missing an encryption key"
            case .methodOutOfRange(let m): return "Encryption method \(m) is out of range (0–5)"
            }
        }
    }

    // MARK: - Codable payload

    private struct Payload: Codable {
        var schema: String
        var version: Int
        var profile: ProfileBody
    }

    private struct ProfileBody: Codable {
        var name: String?
        var server: ServerBody
    }

    private struct ServerBody: Codable {
        var domain: String
        var encryptionKey: String
        var encryptionMethod: Int

        enum CodingKeys: String, CodingKey {
            case domain
            case encryptionKey = "encryption_key"
            case encryptionMethod = "encryption_method"
        }
    }

    // MARK: - Decode

    /// Decode a single link. Tolerates surrounding whitespace, a trailing
    /// query/fragment, and either URL-safe or standard base64.
    static func decode(_ text: String) throws -> Imported {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Require the scheme prefix (case-insensitive), matching WhiteDNS.
        let prefix = "\(scheme)://"
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else {
            throw DecodeError.notAStormLink
        }
        var body = String(trimmed.dropFirst(prefix.count))

        // Strip anything from the first `?` or `#`.
        if let cut = body.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            body = String(body[..<cut])
        }
        guard !body.isEmpty else { throw DecodeError.badBase64 }

        guard let data = base64URLDecode(body) else { throw DecodeError.badBase64 }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw DecodeError.badJSON
        }

        guard payload.schema == schema, payload.version == version else {
            throw DecodeError.wrongSchema
        }

        let domain = normalizeDomain(payload.profile.server.domain)
        guard !domain.isEmpty else { throw DecodeError.missingDomain }

        let key = payload.profile.server.encryptionKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DecodeError.missingKey }

        let method = payload.profile.server.encryptionMethod
        guard (0...5).contains(method) else { throw DecodeError.methodOutOfRange(method) }

        let rawName = (payload.profile.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? domain : rawName

        return Imported(name: name, domain: domain, encryptionKey: key, encryptionMethod: method)
    }

    /// Decode multi-line input — one link per non-blank line. Returns the
    /// successful imports plus per-line failures (line index is 1-based).
    struct LineFailure {
        let line: Int
        let text: String
        let error: Error
    }

    static func decodeMany(_ text: String) -> (ok: [Imported], failed: [LineFailure]) {
        var ok: [Imported] = []
        var failed: [LineFailure] = []
        let lines = text.split(whereSeparator: \.isNewline)
        var lineNumber = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lineNumber += 1
            do {
                ok.append(try decode(line))
            } catch {
                failed.append(LineFailure(line: lineNumber, text: line, error: error))
            }
        }
        return (ok, failed)
    }

    // MARK: - Encode

    /// Build a shareable `stormdns://` link. Returns nil only if the domain is
    /// blank after normalization (caller should disable export in that case).
    static func encode(name: String, domain: String,
                       encryptionKey: String, encryptionMethod: Int) -> String? {
        let cleanDomain = normalizeDomain(domain)
        guard !cleanDomain.isEmpty else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = Payload(
            schema: schema,
            version: version,
            profile: ProfileBody(
                name: cleanName.isEmpty ? cleanDomain : cleanName,
                server: ServerBody(
                    domain: cleanDomain,
                    encryptionKey: encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    encryptionMethod: encryptionMethod
                )
            )
        )
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        return "\(scheme)://\(base64URLEncode(json))"
    }

    // MARK: - Base64URL helpers

    private static func base64URLDecode(_ body: String) -> Data? {
        // Pad to a multiple of 4.
        var padded = body
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        // Try URL-safe alphabet first.
        let urlSafe = padded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if let data = Data(base64Encoded: urlSafe) { return data }
        // Fall back to standard alphabet (body may already be standard base64).
        return Data(base64Encoded: padded)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func normalizeDomain(_ domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }
}
