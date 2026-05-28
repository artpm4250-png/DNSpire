import SwiftUI
import UniformTypeIdentifiers

/// Bulk DNS-resolver scan sheet, opened from [[HomeView]]'s Tools menu.
/// Stage 4 of [[whitedns-catchup-roadmap]].
///
/// The user pastes (or imports a `.txt` of) IP / IP:PORT lines, taps Scan, and
/// gets one DNS A-query latency per line. Results are read-only here — copy /
/// share only, no path back into [[ProfileStore]]; importing into resolver
/// profiles is intentionally deferred until the user asks for it (see
/// [[ResolverScanner]] doc comment).
struct ScanView: View {
    @EnvironmentObject var scanner: ResolverScanner

    @State private var importer: Bool = false
    @State private var shareItem: ShareItem?
    @State private var copyHint: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inputPane
                Divider()
                resultPane
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            importer = true
                        } label: {
                            Label("Import .txt", systemImage: "doc.text")
                        }
                        Button(role: .destructive) {
                            scanner.input = ""
                            scanner.clear()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .disabled(scanner.input.isEmpty && scanner.rows.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(
                isPresented: $importer,
                allowedContentTypes: [.plainText, .text, .commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.text])
            }
        }
    }

    // MARK: - Input pane

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
                Text("Resolvers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(countLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $scanner.input)
                .focused($inputFocused)
                .font(.callout.monospaced())
                .frame(minHeight: 96, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(alignment: .topLeading) {
                    if scanner.input.isEmpty {
                        Text("1.1.1.1\n8.8.8.8:53\n9.9.9.9")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: scanner.input) { _, newValue in
                    scanner.ingest(text: newValue)
                }

            HStack(spacing: 8) {
                Button {
                    inputFocused = false
                    Task { await scanner.scan() }
                } label: {
                    HStack(spacing: 6) {
                        if scanner.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(scanner.isRunning ? "Scanning…" : "Scan")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(scanner.rows.isEmpty || scanner.isRunning)

                Menu {
                    Button {
                        copyToPasteboard(scanner.exportText(format: .okOnly))
                    } label: {
                        Label("Copy OK hosts", systemImage: "doc.on.doc")
                    }
                    .disabled(okCount == 0)
                    Button {
                        copyToPasteboard(scanner.exportText(format: .full))
                    } label: {
                        Label("Copy full result", systemImage: "doc.on.doc")
                    }
                    .disabled(scanner.rows.isEmpty)
                    Divider()
                    Button {
                        shareItem = ShareItem(text: scanner.exportText(format: .okOnly))
                    } label: {
                        Label("Share OK hosts", systemImage: "square.and.arrow.up")
                    }
                    .disabled(okCount == 0)
                    Button {
                        shareItem = ShareItem(text: scanner.exportText(format: .full))
                    } label: {
                        Label("Share full result", systemImage: "square.and.arrow.up")
                    }
                    .disabled(scanner.rows.isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(scanner.rows.isEmpty)
            }
        }
        .padding(12)
        .overlay(alignment: .top) {
            if copyHint {
                Text("Copied")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Result pane

    @ViewBuilder
    private var resultPane: some View {
        if scanner.rows.isEmpty {
            ContentUnavailableView(
                "No resolvers yet",
                systemImage: "magnifyingglass",
                description: Text("Paste IPs above or import a .txt file, then tap Scan.")
            )
        } else {
            List {
                Section {
                    ForEach(scanner.rows) { row in
                        ResolverScanRow(row: row)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    }
                } header: {
                    summaryHeader
                }
            }
            .listStyle(.plain)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 10) {
            summaryBadge(color: .green, label: "OK", count: okCount)
            summaryBadge(color: .orange, label: "Timeout", count: timeoutCount)
            summaryBadge(color: .red, label: "Fail", count: failCount)
            Spacer()
            if let fastest {
                Text(fastest)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }

    private func summaryBadge(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var countLabel: String {
        let n = scanner.rows.count
        if n == 0 { return "0 lines" }
        return n == 1 ? "1 line" : "\(n) lines"
    }

    private var okCount: Int {
        scanner.rows.reduce(0) { acc, row in
            if case .ok = row.outcome { return acc + 1 }
            return acc
        }
    }

    private var timeoutCount: Int {
        scanner.rows.reduce(0) { acc, row in
            if case .fail(let reason) = row.outcome, reason == "timeout" { return acc + 1 }
            return acc
        }
    }

    private var failCount: Int {
        scanner.rows.reduce(0) { acc, row in
            if case .fail(let reason) = row.outcome, reason != "timeout" { return acc + 1 }
            return acc
        }
    }

    private var fastest: String? {
        var best: (display: String, ms: Int)?
        for row in scanner.rows {
            if case .ok(let ms) = row.outcome {
                if best == nil || ms < best!.ms {
                    best = (row.display, ms)
                }
            }
        }
        guard let best else { return nil }
        return "fastest: \(best.display) (\(best.ms) ms)"
    }

    // MARK: - Actions

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.15)) { copyHint = true }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) { copyHint = false }
            }
        }
    }

    /// Read the picked file from a security-scoped URL into the input field.
    /// Files imported through the picker arrive with a coordinated-access
    /// scope that has to be claimed before reading and released after — skip
    /// this and the read silently returns an empty string in release builds.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            scanner.input = text
        }
    }
}

private struct ShareItem: Identifiable {
    let text: String
    var id: String { text }
}

private struct ResolverScanRow: View {
    let row: ResolverScanner.Row

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            Text(row.display)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            trailing
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.outcome {
        case .pending:
            Circle().fill(Color(.tertiarySystemFill)).frame(width: 8, height: 8)
        case .running:
            ProgressView().controlSize(.mini)
        case .ok:
            Circle().fill(scoreColor).frame(width: 8, height: 8)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.outcome {
        case .pending:
            Text("pending")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .running:
            Text("running")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ok(let ms):
            Text("\(ms) ms")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        case .fail(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.85))
        }
    }

    private var scoreColor: Color {
        switch row.outcome.score {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        case .none: return .gray
        }
    }
}

#Preview {
    ScanView()
        .environmentObject(ResolverScanner())
}
