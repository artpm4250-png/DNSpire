import Foundation

/// Sent by the main app to the packet-tunnel extension via
/// `NETunnelProviderSession.sendProviderMessage`.
struct ProviderRequest: Codable {
    var op: String
    /// Highest log sequence the app has already consumed; the extension only
    /// returns entries with `seq > sinceLogSeq`. Pass 0 on first poll.
    var sinceLogSeq: Int?
}

/// Snapshot returned by the extension. Counters are cumulative since the most
/// recent `startTunnel` and reset on every fresh session. New fields are
/// decoded with defaults so a host app paired with an older extension (or
/// vice-versa) doesn't crash on the wire.
struct ProviderSnapshot: Codable {
    var status: String
    var bytesUp: Int64
    var bytesDown: Int64
    var tcpFlowsAccepted: Int64
    var tcpFlowsActive: Int64
    var dnsQueriesHandled: Int64
    var logs: [ProviderLogEntry]
    var lastLogSeq: Int

    /// "" | "verifying" | "verified" | "needsAttention". Empty before the
    /// tunnel reaches `connected` for the first time, after disconnect, and
    /// in proxy mode (where the verifier doesn't run).
    var verification: String = ""
    /// Unix epoch milliseconds of the most recent successful probe. 0 if
    /// never verified in the current session.
    var lastVerifiedAt: Int64 = 0
    /// Total configured resolvers as seen by the balancer; 0 before
    /// bootstrap.
    var resolversTotal: Int = 0
    /// Resolvers currently in rotation (valid + enabled).
    var resolversActive: Int = 0

    enum CodingKeys: String, CodingKey {
        case status, bytesUp, bytesDown, tcpFlowsAccepted, tcpFlowsActive
        case dnsQueriesHandled, logs, lastLogSeq
        case verification, lastVerifiedAt, resolversTotal, resolversActive
    }

    init(status: String,
         bytesUp: Int64,
         bytesDown: Int64,
         tcpFlowsAccepted: Int64,
         tcpFlowsActive: Int64,
         dnsQueriesHandled: Int64,
         logs: [ProviderLogEntry],
         lastLogSeq: Int,
         verification: String = "",
         lastVerifiedAt: Int64 = 0,
         resolversTotal: Int = 0,
         resolversActive: Int = 0) {
        self.status = status
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.tcpFlowsAccepted = tcpFlowsAccepted
        self.tcpFlowsActive = tcpFlowsActive
        self.dnsQueriesHandled = dnsQueriesHandled
        self.logs = logs
        self.lastLogSeq = lastLogSeq
        self.verification = verification
        self.lastVerifiedAt = lastVerifiedAt
        self.resolversTotal = resolversTotal
        self.resolversActive = resolversActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        bytesUp = try c.decode(Int64.self, forKey: .bytesUp)
        bytesDown = try c.decode(Int64.self, forKey: .bytesDown)
        tcpFlowsAccepted = try c.decode(Int64.self, forKey: .tcpFlowsAccepted)
        tcpFlowsActive = try c.decode(Int64.self, forKey: .tcpFlowsActive)
        dnsQueriesHandled = try c.decode(Int64.self, forKey: .dnsQueriesHandled)
        logs = try c.decode([ProviderLogEntry].self, forKey: .logs)
        lastLogSeq = try c.decode(Int.self, forKey: .lastLogSeq)
        verification = try c.decodeIfPresent(String.self, forKey: .verification) ?? ""
        lastVerifiedAt = try c.decodeIfPresent(Int64.self, forKey: .lastVerifiedAt) ?? 0
        resolversTotal = try c.decodeIfPresent(Int.self, forKey: .resolversTotal) ?? 0
        resolversActive = try c.decodeIfPresent(Int.self, forKey: .resolversActive) ?? 0
    }
}

struct ProviderLogEntry: Codable, Equatable {
    var seq: Int
    var text: String
}
