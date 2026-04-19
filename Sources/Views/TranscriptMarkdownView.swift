import SwiftUI

struct TranscriptMarkdownView: View, Equatable {
    let content: TranscriptMessage.Content

    var body: some View {
        Text(verbatim: content.text)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
