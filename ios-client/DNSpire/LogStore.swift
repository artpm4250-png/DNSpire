import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []

    private let maxLines = 1000

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

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date = Date()
    let text: String
}
