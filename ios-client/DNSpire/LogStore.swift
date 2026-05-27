import Foundation
import SwiftUI

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []

    /// Hard cap on retained lines. When exceeded, oldest entries are silently
    /// dropped — the LogsView surfaces a hint so the user knows why early
    /// output disappears during long sessions.
    let maxLines = 1000

    var isAtCap: Bool { lines.count >= maxLines }

    func append(_ text: String) {
        let line = LogLine(text: text)
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() {
        lines.removeAll()
    }
}

/// Severity of a log entry. Detected once at LogLine init time so the
/// LogsView can render and filter without re-parsing per redraw.
enum LogLevel: Int, Comparable {
    case unknown = 0
    case debug
    case info
    case warn
    case error

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .error:   return "Error"
        case .warn:    return "Warn"
        case .info:    return "Info"
        case .debug:   return "Debug"
        case .unknown: return "Plain"
        }
    }

    var color: Color {
        switch self {
        case .error:   return .red
        case .warn:    return .orange
        case .info:    return .primary
        case .debug:   return .secondary
        case .unknown: return .primary
        }
    }
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date = Date()
    let text: String
    /// Optional `[source]` token from the start of the line (e.g. "ui", "vpn",
    /// "client", "mobile"). Nil when the line has no such prefix.
    let source: String?
    /// `text` with the source prefix stripped, for display in the row body.
    let body: String
    let level: LogLevel

    init(text: String) {
        self.text = text
        let (src, rest) = LogLine.splitSource(text)
        self.source = src
        self.body = rest
        self.level = LogLine.detectLevel(in: rest)
    }

    private static func splitSource(_ text: String) -> (String?, String) {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
            return (nil, text)
        }
        let src = String(text[text.index(after: text.startIndex)..<close])
        let after = text.index(after: close)
        var rest = text[after...]
        // Trim a single leading space — typical for "[src] body" — but keep
        // any further leading whitespace intact in case it's structurally
        // meaningful (e.g. indented stack frames).
        if rest.first == " " { rest = rest.dropFirst() }
        return (src, String(rest))
    }

    /// Two-pass detection: bracketed tokens like `[ERROR]` or "ERROR:" prefixes
    /// take precedence, then a word-boundary scan picks up severity words
    /// embedded mid-line. Falls back to .unknown so generic narration like
    /// "Starting MTU probe" doesn't get coloured as info just because the word
    /// "information" appears somewhere.
    private static func detectLevel(in body: String) -> LogLevel {
        if let tagged = detectTaggedLevel(body) { return tagged }
        if let prefixed = detectPrefixLevel(body) { return prefixed }
        return detectWordLevel(body)
    }

    private static func detectTaggedLevel(_ s: String) -> LogLevel? {
        // Match a leading "[LEVEL]" or "[LEVEL] something" segment.
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
        let inner = s[s.index(after: s.startIndex)..<close].uppercased()
        switch inner {
        case "ERROR", "ERR", "FATAL", "PANIC", "CRITICAL", "CRIT":
            return .error
        case "WARN", "WARNING":
            return .warn
        case "INFO", "NOTICE":
            return .info
        case "DEBUG", "TRACE", "DBG":
            return .debug
        default:
            return nil
        }
    }

    private static func detectPrefixLevel(_ s: String) -> LogLevel? {
        // Go convention: "error: failed to do X" or "WARN: x". Check up to
        // the first colon, case-insensitively.
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let prefix = s[s.startIndex..<colon].uppercased()
        // Limit to short prefixes — full sentences can contain colons too.
        guard prefix.count <= 16 else { return nil }
        switch prefix {
        case "ERROR", "FATAL", "PANIC", "FAILED":
            return .error
        case "WARN", "WARNING":
            return .warn
        case "INFO", "NOTICE":
            return .info
        case "DEBUG", "TRACE":
            return .debug
        default:
            return nil
        }
    }

    private static func detectWordLevel(_ s: String) -> LogLevel {
        // Scan whole-word matches so "Information" doesn't trigger info and
        // "warned" doesn't trigger warn. We do a single pass picking the
        // highest severity word seen.
        var best: LogLevel = .unknown
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex {
            // Skip non-letters.
            while start < scalars.endIndex, !isWordChar(scalars[start]) {
                start = scalars.index(after: start)
            }
            var end = start
            while end < scalars.endIndex, isWordChar(scalars[end]) {
                end = scalars.index(after: end)
            }
            if start < end {
                let word = String(String.UnicodeScalarView(scalars[start..<end])).uppercased()
                let lvl = severityForWord(word)
                if lvl > best { best = lvl }
                if best == .error { return best }
            }
            start = end
        }
        return best
    }

    private static func isWordChar(_ u: Unicode.Scalar) -> Bool {
        return (u.value >= 0x30 && u.value <= 0x39) // 0-9
            || (u.value >= 0x41 && u.value <= 0x5A) // A-Z
            || (u.value >= 0x61 && u.value <= 0x7A) // a-z
    }

    private static func severityForWord(_ upper: String) -> LogLevel {
        switch upper {
        case "ERROR", "ERRORS", "FATAL", "PANIC", "FAILED", "FAILURE", "CRITICAL":
            return .error
        case "WARN", "WARNING":
            return .warn
        // Intentionally NOT counting "INFO" mid-line — too many false positives
        // ("information", "informational"). Only the bracketed/prefix passes
        // above mark info-level.
        default:
            return .unknown
        }
    }
}
