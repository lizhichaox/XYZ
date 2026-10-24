import SwiftUI
import XYZCore

/// Counts the open note while View → Show Word Count is on.
///
/// Typing reschedules the count, so a long note is counted once after a pause rather than on
/// every keystroke. The count runs off the main actor.
@MainActor
final class WordCountModel: ObservableObject {
    @Published private(set) var stats = TextStatistics()
    private var task: Task<Void, Never>?

    func update(_ text: String, immediate: Bool = false) {
        task?.cancel()
        task = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(text.utf8.count > 200_000 ? 600 : 250))
                guard !Task.isCancelled else { return }
            }
            let counted = await Task.detached(priority: .utility) {
                TextStatistics.count(text)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.stats != counted {
                self.stats = counted
            }
        }
    }
}

/// A quiet line under the note: the word count and the reading time.
struct WordCountBar: View {
    var stats: TextStatistics

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(summary)
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Color.editorBackground)
    }

    private var summary: String {
        let words = String(localized: "\(stats.total) words")
        guard stats.readingMinutes > 0 else { return words }
        return words + " · " + String(localized: "\(stats.readingMinutes) min read")
    }
}
