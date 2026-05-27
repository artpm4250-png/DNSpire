import Foundation
import Combine

/// Persisted MTU snapshot for a single server profile. Captured after the
/// upstream balancer settles on a stable per-connection MTU; replayed on the
/// next connect to narrow `MIN_UPLOAD_MTU/MAX_UPLOAD_MTU` (and the download
/// counterparts) around the previous median.
///
/// Saved in UserDefaults rather than per-profile `ServerProfile` storage so a
/// stale hint can't accidentally ride a `stormdns://` export — it's an
/// observation about this device's path to the server, not part of server
/// identity.
struct MTUHint: Codable, Equatable {
    var uploadMedian: Int
    var downloadMedian: Int
    var savedAt: Date
}

@MainActor
final class MTUHintStore: ObservableObject {
    @Published private(set) var hints: [UUID: MTUHint] = [:]

    /// Drop hints older than 7 days at lookup time — the path can shift
    /// (carrier swap, new Wi-Fi) and an ancient hint risks confining the next
    /// probe to a window that no longer fits.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Half-width of the band around the persisted median. The upstream
    /// MTU bisect tolerates a few bytes either way, but narrower than this
    /// has empirically thrown false "no valid connection" results on lossy
    /// links during testing.
    static let bandwidth: Int = 10

    private let defaultsKey = "DNSpire.mtuHints.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([UUID: MTUHint].self, from: data) {
            self.hints = decoded
        }
    }

    /// Returns the hint for `serverID` if present and not stale. Stale entries
    /// are kept on disk (they may become valid again if the user re-connects
    /// from a similar path); only the read path filters them.
    func hint(for serverID: UUID) -> MTUHint? {
        guard let h = hints[serverID] else { return nil }
        if Date().timeIntervalSince(h.savedAt) > Self.maxAge { return nil }
        return h
    }

    /// Persist a fresh measurement. Skipped if values are non-positive or if
    /// the saved hint is identical and was written less than 60s ago —
    /// prevents the per-second snapshot poll from churning UserDefaults.
    func record(serverID: UUID, uploadMedian: Int, downloadMedian: Int) {
        guard uploadMedian > 0, downloadMedian > 0 else { return }
        if let existing = hints[serverID],
           existing.uploadMedian == uploadMedian,
           existing.downloadMedian == downloadMedian,
           Date().timeIntervalSince(existing.savedAt) < 60 {
            return
        }
        hints[serverID] = MTUHint(
            uploadMedian: uploadMedian,
            downloadMedian: downloadMedian,
            savedAt: Date()
        )
        persist()
    }

    /// Drop hints for servers that no longer exist in [[ProfileStore]]. Called
    /// from `DNSpireApp.task` alongside the equivalent prune in
    /// [[ServerTestRunner]].
    func prune(to ids: Set<UUID>) {
        let before = hints.count
        hints = hints.filter { ids.contains($0.key) }
        if hints.count != before { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hints) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
