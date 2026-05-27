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
/// recent `startTunnel` and reset on every fresh session.
struct ProviderSnapshot: Codable {
    var status: String
    var bytesUp: Int64
    var bytesDown: Int64
    var tcpFlowsAccepted: Int64
    var tcpFlowsActive: Int64
    var dnsQueriesHandled: Int64
    var logs: [ProviderLogEntry]
    var lastLogSeq: Int
}

struct ProviderLogEntry: Codable, Equatable {
    var seq: Int
    var text: String
}
