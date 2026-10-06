import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct EmojiAutocompleteList: View {
    let suggestions: [ColonAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (ColonAutocompleteSuggestion) -> Void

    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0

    var body: some View {
        ComposerAutocompletePanel(heading: "EMOJIS", cornerRadius: cornerRadius) {
            ComposerSuggestionList(
                rows: suggestions,
                selectedID: suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex].id : nil,
                keyboardSelectionRevision: keyboardSelectionRevision,
                rowHeight: { _ in 42 },
                highlight: { row in
                    if let index = suggestions.firstIndex(where: { $0.id == row.id }), index != selectedIndex { highlight(index) }
                },
                activate: select,
                content: { suggestion in
                    EmojiAutocompleteRow(
                        suggestion: suggestion,
                        isSelected: suggestions.indices.contains(selectedIndex) && suggestions[selectedIndex].id == suggestion.id,
                        select: { select(suggestion) },
                        cornerRadius: max(0, cornerRadius - 6)
                    )
                }
            )
        }
    }
}

struct ComposerAutocompletePanel<Content: View>: View {
    let heading: String
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 5)
            content()
        }
        .frame(maxWidth: .infinity)
        .commandPanelSurface(cornerRadius: cornerRadius)
    }
}
