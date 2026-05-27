import SwiftUI
import UIKit

private enum LogSource: String, CaseIterable, Identifiable {
    case all, ui, vpn, tunnel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:    return "All"
        case .ui:     return "UI"
        case .vpn:    return "VPN"
        case .tunnel: return "Tunnel"
        }
    }

    var icon: String {
        switch self {
        case .all:    return "tray.full"
        case .ui:     return "rectangle.on.rectangle"
        case .vpn:    return "lock.shield"
        case .tunnel: return "antenna.radiowaves.left.and.right"
        }
    }
}

private enum LogLevel {
    case error, warn, info, debug, unknown

    var color: Color {
        switch self {
        case .error:   return .red
        case .warn:    return .orange
        case .info:    return .primary
        case .debug:   return .secondary
        case .unknown: return .primary
        }
    }

    static func detect(in text: String) -> LogLevel {
        let upper = text.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") || upper.contains("PANIC") {
            return .error
        }
        if upper.contains("WARN") {
            return .warn
        }
        if upper.contains("INFO") {
            return .info
        }
        if upper.contains("DEBUG") || upper.contains("TRACE") {
            return .debug
        }
        return .unknown
    }
}

struct LogsView: View {
    @EnvironmentObject var logStore: LogStore

    @State private var search: String = ""
    @State private var selectedSource: LogSource = .all
    @State private var pinToBottom: Bool = true
    @State private var copyHint: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                logsBody
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search logs")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !exportText.isEmpty {
                        ShareLink(item: exportText, preview: SharePreview("DNSpire logs")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Menu {
                        Button(role: .destructive) { logStore.clear() } label: {
                            Label("Clear all", systemImage: "trash")
                        }
                        Toggle("Pin to bottom", isOn: $pinToBottom)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(logStore.lines.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var logsBody: some View {
        if filteredLines.isEmpty {
            ContentUnavailableView(
                logStore.lines.isEmpty ? "No logs yet" : "Nothing matches",
                systemImage: logStore.lines.isEmpty ? "doc.text" : "line.3.horizontal.decrease.circle",
                description: Text(
                    logStore.lines.isEmpty
                        ? "Connect the tunnel to see runtime output."
                        : "Try a different filter or clear the search."
                )
            )
        } else {
            ScrollViewReader { proxy in
                List(filteredLines) { line in
                    LogRow(line: line, copied: copyHint == line.id)
                        .id(line.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .contentShape(Rectangle())
                        .onTapGesture { copy(line) }
                }
                .listStyle(.plain)
                .onChange(of: logStore.lines.last?.id) { _, newID in
                    guard pinToBottom, let newID, selectedSource == .all, search.isEmpty else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogSource.allCases) { src in
                    SourceChip(
                        source: src,
                        selected: selectedSource == src,
                        count: countFor(src)
                    ) {
                        selectedSource = src
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private var filteredLines: [LogLine] {
        let lower = search.trimmingCharacters(in: .whitespaces).lowercased()
        return logStore.lines.filter { line in
            matchesSource(line, source: selectedSource) &&
            (lower.isEmpty || line.text.lowercased().contains(lower))
        }
    }

    private var exportText: String {
        guard !logStore.lines.isEmpty else { return "" }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return logStore.lines
            .map { "\(df.string(from: $0.timestamp))  \($0.text)" }
            .joined(separator: "\n")
    }

    private func countFor(_ source: LogSource) -> Int {
        guard source != .all else { return logStore.lines.count }
        return logStore.lines.lazy.filter { matchesSource($0, source: source) }.count
    }

    private func matchesSource(_ line: LogLine, source: LogSource) -> Bool {
        switch source {
        case .all:
            return true
        case .ui:
            return line.text.hasPrefix("[ui]")
        case .vpn:
            return line.text.hasPrefix("[vpn]")
        case .tunnel:
            return !line.text.hasPrefix("[ui]") && !line.text.hasPrefix("[vpn]")
        }
    }

    private func copy(_ line: LogLine) {
        UIPasteboard.general.string = line.text
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        copyHint = line.id
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                if copyHint == line.id { copyHint = nil }
            }
        }
    }
}

private struct SourceChip: View {
    let source: LogSource
    let selected: Bool
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: source.icon)
                    .font(.caption)
                Text(source.label)
                    .font(.subheadline.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(selected ? Color.white.opacity(0.25) : Color(.tertiarySystemFill))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct LogRow: View {
    let line: LogLine
    let copied: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        let (source, body) = split(line.text)
        let level = LogLevel.detect(in: line.text)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let source {
                    SourcePill(source: source)
                }
                Text(Self.timeFormatter.string(from: line.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if copied {
                    Spacer()
                    Label("Copied", systemImage: "doc.on.doc.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Text(body)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(level.color)
                .textSelection(.enabled)
        }
    }

    private func split(_ text: String) -> (String?, String) {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
            return (nil, text)
        }
        let src = String(text[text.index(after: text.startIndex)..<close])
        let rest = String(text[text.index(after: close)...]).drop(while: { $0 == " " })
        return (src, String(rest))
    }
}

private struct SourcePill: View {
    let source: String

    var body: some View {
        Text(source.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
    }

    private var color: Color {
        switch source.lowercased() {
        case "ui":     return .blue
        case "vpn":    return .purple
        default:       return .teal
        }
    }
}
