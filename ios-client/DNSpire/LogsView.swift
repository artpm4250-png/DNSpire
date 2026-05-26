import SwiftUI

struct LogsView: View {
    @EnvironmentObject var logStore: LogStore

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(logStore.lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                            .font(.system(.footnote, design: .monospaced))
                        Text(line.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .id(line.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.plain)
                .onChange(of: logStore.lines.last?.id) { _, newID in
                    guard let newID else { return }
                    withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { logStore.clear() }
                        .disabled(logStore.lines.isEmpty)
                }
            }
            .overlay {
                if logStore.lines.isEmpty {
                    ContentUnavailableView(
                        "No logs yet",
                        systemImage: "doc.text",
                        description: Text("Connect the tunnel to see runtime output.")
                    )
                }
            }
        }
    }
}
