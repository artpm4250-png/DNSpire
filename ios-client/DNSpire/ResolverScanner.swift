import Foundation
import Combine
import DNSpireCore

/// Bulk DNS-resolver scanner backing the Scan tab. Takes a free-form text
/// blob (paste-import, or contents of a `.txt` the user shared in), normalises
/// it into `host` / `host:port` rows, and races them in parallel through
/// `DNSpireMobileProbeResolvers` — a single DNS A-query per resolver, with
/// per-row latency and a coarse error code.
///
/// Stage 4 of [[whitedns-catchup-roadmap]]. Independent of any active
/// [[ServerProfile]]: the user can scan a list scraped from a forum without
/// touching their saved profiles. Result actions are copy / share only; we
/// intentionally do NOT add a one-tap "import as resolver profile" path here
/// — that re-enters Profile-editing territory and belongs in Stage 4+ if the
/// user asks for it.
@MainActor
final class ResolverScanner: ObservableObject {
    enum Outcome: Equatable {
        case pending
        case running
        case ok(ms: Int)
        /// Per-row failure code from the Go side: "malformed" / "timeout" /
        /// "io" / "shortread" / "badreply". The raw string flows to the UI so
        /// future Go-side categories don't require a Swift change.
        case fail(reason: String)
    }

    struct Row: Identifiable, Equatable {
        let id = UUID()
        /// The raw text the user pasted, after trimming. We keep this verbatim
        /// for display ("1.1.1.1:5353") rather than reconstructing it from the
        /// normalised host/port — preserving the user's original input keeps
        /// copy/share output predictable.
        let display: String
        var outcome: Outcome
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false
    /// "example.com" by default. Exposed so a future Settings toggle can let
    /// the user point the probe at a domain they trust under their
    /// jurisdiction; for now the constant matches the Go binding default.
    @Published var controlName: String = "example.com"
    /// Raw text the user is currently editing in the Scan input pane. Hoisted
    /// out of [[ScanView]]'s local @State because Scan is now sheet-presented
    /// from HomeView's toolbar — local @State is torn down on sheet dismiss,
    /// which would lose a long paste the user is mid-edit. Storing it on the
    /// EnvironmentObject lets dismiss/re-open round-trip cleanly while a scan
    /// is still in flight.
    @Published var input: String = ""

    /// Per-request timeout for the underlying UDP DNS query. 1500 ms catches
    /// a packet loss while still keeping a 100-row scan under a minute.
    nonisolated static let defaultPerRequestTimeoutMs = 1500
    /// Hard ceiling on a single `scan()` invocation. A 200-row paste with
    /// 8-way parallelism settles well under this even with all rows timing
    /// out (200 / 8 * 1.5s ≈ 37s).
    nonisolated static let defaultTotalTimeoutMs = 60_000
    nonisolated static let defaultParallelism = 8

    /// Parse a bulk blob into the rows we'll probe. Splits on commas and
    /// newlines (same delimiters [[ResolverEntry.parseList]] uses), trims
    /// whitespace, drops empty/duplicate lines (first-occurrence wins).
    /// Does NOT validate format — the Go side reports `malformed` for rows
    /// it can't parse, which is more honest than us silently dropping them.
    static func parseLines(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in text.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let v = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            if seen.insert(v.lowercased()).inserted {
                out.append(v)
            }
        }
        return out
    }

    /// Replace the row list from a raw text blob. Resets all outcomes to
    /// `.pending`. Call this on paste-change / file-import so the live count
    /// updates immediately, before the user taps Scan.
    func ingest(text: String) {
        rows = Self.parseLines(text).map { Row(display: $0, outcome: .pending) }
    }

    func clear() {
        rows = []
    }

    /// Run a fresh scan over the current `rows`. Coalesces re-entrant calls:
    /// while one scan is in flight, taps on Scan are no-ops.
    func scan(
        perRequestTimeoutMs: Int = ResolverScanner.defaultPerRequestTimeoutMs,
        totalTimeoutMs: Int = ResolverScanner.defaultTotalTimeoutMs,
        parallelism: Int = ResolverScanner.defaultParallelism
    ) async {
        guard !isRunning else { return }
        guard !rows.isEmpty else { return }

        isRunning = true
        defer { isRunning = false }

        for i in rows.indices { rows[i].outcome = .running }
        let payload = rows.map(\.display).joined(separator: ";")
        let probeControl = controlName
        let result = await Task.detached(priority: .userInitiated) { () -> String in
            // ProbeResolvers has signature (string, error) — gomobile emits
            // the bare two-return form for single-string + error free funcs.
            var ns: NSError?
            let csv = DNSpireMobileProbeResolvers(
                payload, probeControl,
                perRequestTimeoutMs, totalTimeoutMs, parallelism,
                &ns
            )
            // The top-level error fires only on "no work to do" — surface
            // empty so every row stays `.fail(no-result)`.
            if ns != nil { return "" }
            return csv ?? ""
        }.value

        applyScanResult(csv: result)
    }

    /// Parse the `;`-separated `index|ok|latencyMs|error` rows the Go binding
    /// returns and merge them into `rows`. Index is positional — rows that
    /// the Go side dropped from the result still land back as `.fail(no-result)`
    /// instead of being left at `.running`.
    private func applyScanResult(csv: String) {
        var byIndex: [Int: Outcome] = [:]
        if !csv.isEmpty {
            for field in csv.split(separator: ";", omittingEmptySubsequences: true) {
                let parts = field.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 4,
                      let idx = Int(parts[0]),
                      let ms = Int(parts[2]) else { continue }
                let isOK = parts[1] == "1"
                let code = String(parts[3])
                if isOK {
                    byIndex[idx] = .ok(ms: ms)
                } else {
                    byIndex[idx] = .fail(reason: code.isEmpty ? "error" : code)
                }
            }
        }
        for i in rows.indices {
            rows[i].outcome = byIndex[i] ?? .fail(reason: "no-result")
        }
    }

    /// Serialise the current scan as plain text for copy/share. Two formats:
    /// `.okOnly` is one-per-line `host[:port]` (good for re-pasting into a
    /// resolver list); `.full` includes the outcome (good for debugging /
    /// sending to a friend).
    enum ExportFormat { case okOnly, full }

    func exportText(format: ExportFormat) -> String {
        switch format {
        case .okOnly:
            return rows
                .compactMap { row -> String? in
                    if case .ok = row.outcome { return row.display }
                    return nil
                }
                .joined(separator: "\n")
        case .full:
            return rows
                .map { row -> String in
                    let suffix: String
                    switch row.outcome {
                    case .pending:                  suffix = "pending"
                    case .running:                  suffix = "running"
                    case .ok(let ms):               suffix = "ok \(ms)ms"
                    case .fail(let reason):         suffix = "fail (\(reason))"
                    }
                    return "\(row.display) — \(suffix)"
                }
                .joined(separator: "\n")
        }
    }
}

extension ResolverScanner.Outcome {
    /// UI helper: 200/600ms thresholds match [[ServerTestRunner]].score —
    /// users see consistent green/yellow/red bands across both tabs.
    enum Score { case good, fair, poor }

    var score: Score? {
        guard case .ok(let ms) = self else { return nil }
        if ms < 200 { return .good }
        if ms < 600 { return .fair }
        return .poor
    }
}
