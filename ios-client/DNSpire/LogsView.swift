import SwiftUI
import UIKit

private enum LogSource: String, CaseIterable, Identifiable {
    case all, ui, vpn, client, tunnel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:    return "All"
        case .ui:     return "UI"
        case .vpn:    return "VPN"
        case .client: return "Client"
        case .tunnel: return "Tunnel"
        }
    }

    var icon: String {
        switch self {
        case .all:    return "tray.full"
        case .ui:     return "rectangle.on.rectangle"
        case .vpn:    return "lock.shield"
        case .client: return "network"
        case .tunnel: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Returns true if the given line belongs in this filter bucket.
    /// `.tunnel` is the catch-all for sources we don't surface as named
    /// chips (e.g. "mobile") so nothing is hidden.
    func matches(_ line: LogLine) -> Bool {
        switch self {
        case .all:    return true
        case .ui:     return line.source == "ui"
        case .vpn:    return line.source == "vpn"
        case .client: return line.source == "client"
        case .tunnel:
            guard let s = line.source else { return true }
            return s != "ui" && s != "vpn" && s != "client"
        }
    }
}

private enum LevelFilter: String, CaseIterable, Identifiable {
    case all, info, warn, error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:   return "All levels"
        case .info:  return "Info+"
        case .warn:  return "Warn+"
        case .error: return "Errors"
        }
    }

    var icon: String {
        switch self {
        case .all:   return "line.3.horizontal.decrease.circle"
        case .info:  return "info.circle"
        case .warn:  return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    func matches(_ line: LogLine) -> Bool {
        switch self {
        case .all:   return true
        case .info:  return line.level >= .info
        case .warn:  return line.level >= .warn
        case .error: return line.level == .error
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var logStore: LogStore

    @State private var search: String = ""
    @State private var selectedSource: LogSource = .all
    @State private var selectedLevel: LevelFilter = .all
    @State private var pinToBottom: Bool = true
    @State private var copyHint: UUID?
    @State private var exportFileURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                levelBar
                if logStore.isAtCap {
                    capBanner
                }
                Divider()
                logsBody
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search logs")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !logStore.lines.isEmpty {
                        Button {
                            exportFileURL = writeExportFile()
                        } label: {
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
            .sheet(item: exportFileBinding) { file in
                ShareSheet(items: [file.url])
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
                    guard pinToBottom, let newID, filtersInactive else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
        }
    }

    private var capBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Buffer full (\(logStore.maxLines) lines) — oldest entries are being dropped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogSource.allCases) { src in
                    SourceChip(
                        source: src,
                        selected: selectedSource == src,
                        count: countFor(source: src)
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

    private var levelBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LevelFilter.allCases) { lvl in
                    LevelChip(
                        filter: lvl,
                        selected: selectedLevel == lvl,
                        count: countFor(level: lvl)
                    ) {
                        selectedLevel = lvl
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    private var filteredLines: [LogLine] {
        let lower = search.trimmingCharacters(in: .whitespaces).lowercased()
        return logStore.lines.filter { line in
            selectedSource.matches(line) &&
            selectedLevel.matches(line) &&
            (lower.isEmpty || line.text.lowercased().contains(lower))
        }
    }

    private var filtersInactive: Bool {
        selectedSource == .all && selectedLevel == .all && search.isEmpty
    }

    /// Counts lines for a source chip, respecting the current level + search
    /// filters so the badge reflects what the user would actually see if they
    /// tapped the chip.
    private func countFor(source: LogSource) -> Int {
        let lower = search.trimmingCharacters(in: .whitespaces).lowercased()
        return logStore.lines.lazy.filter { line in
            source.matches(line) &&
            selectedLevel.matches(line) &&
            (lower.isEmpty || line.text.lowercased().contains(lower))
        }.count
    }

    /// Counts lines for a level chip, respecting the current source + search
    /// filters.
    private func countFor(level: LevelFilter) -> Int {
        let lower = search.trimmingCharacters(in: .whitespaces).lowercased()
        return logStore.lines.lazy.filter { line in
            selectedSource.matches(line) &&
            level.matches(line) &&
            (lower.isEmpty || line.text.lowercased().contains(lower))
        }.count
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

    /// Renders the visible buffer to a temp .log file with a timestamped name
    /// so the share sheet offers Save to Files / Mail attachment, not just a
    /// raw text snippet. Failures fall back silently — the user can still
    /// long-press individual rows to copy.
    private func writeExportFile() -> URL? {
        guard !logStore.lines.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = df.string(from: Date())
        let ts = DateFormatter()
        ts.dateFormat = "HH:mm:ss.SSS"

        let body = logStore.lines
            .map { "\(ts.string(from: $0.timestamp))  \($0.text)" }
            .joined(separator: "\n")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnspire-logs-\(stamp).log")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Wraps the optional file URL into an Identifiable for `.sheet(item:)`.
    private var exportFileBinding: Binding<ExportFile?> {
        Binding(
            get: { exportFileURL.map { ExportFile(url: $0) } },
            set: { exportFileURL = $0?.url }
        )
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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

private struct LevelChip: View {
    let filter: LevelFilter
    let selected: Bool
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: filter.icon)
                    .font(.caption)
                Text(filter.label)
                    .font(.caption.weight(.medium))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : tint)
            .background(
                Capsule().fill(selected ? tint : tint.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        switch filter {
        case .all:   return .secondary
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        }
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let source = line.source {
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
            Text(line.body)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(line.level.color)
                .textSelection(.enabled)
        }
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
        case "client": return .green
        case "mobile": return .teal
        default:       return .teal
        }
    }
}
