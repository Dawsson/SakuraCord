import SwiftUI

struct SelectionFieldMenu<ID: Hashable & Sendable>: View {
    @Bindable var model: SelectionFieldModel<ID>
    @Binding var selection: [ID]
    @Binding var highlightedID: ID?
    let mode: SelectionFieldSelectionMode
    let configuration: SelectionFieldConfiguration
    let height: CGFloat
    let activate: (ID) -> Void
    @State private var hoveredID: ID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.results) { option in
                            SelectionFieldMenuRow(
                                option: option,
                                selected: selection.contains(option.id),
                                highlighted: (hoveredID ?? highlightedID) == option.id,
                                multiple: mode.allowsMultipleSelection,
                                enabled: canToggle(option.id),
                                action: { activate(option.id) }
                            )
                            .id(option.id)
                            .onModalHover { hovering in
                                if hovering {
                                    hoveredID = option.id
                                    highlightedID = nil
                                } else if hoveredID == option.id {
                                    hoveredID = nil
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: height)
                .overlay {
                    if model.results.isEmpty { emptyState.padding(20) }
                }
                .onChange(of: highlightedID) { _, id in
                    if let id {
                        hoveredID = nil
                        proxy.scrollTo(id)
                    }
                }
                .onChange(of: model.results.map(\.id)) { _, ids in
                    if let highlightedID, ids.contains(highlightedID) { return }
                    hoveredID = nil
                    highlightedID = model.query.isEmpty ? nil : ids.first
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            switch model.state {
            case .idle, .loading:
                ProgressView().controlSize(.small)
                Text("Searching…").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.secondary)
                Text("Couldn’t load options")
                Button("Try Again") { model.retry() }.buttonStyle(.bordered)
            case .needsMoreCharacters(let count):
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                Text("Enter at least \(count) characters").foregroundStyle(.secondary)
            case .loaded:
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                Text(model.query.isEmpty ? (model.searchesRemotely ? "Type to search options" : "No options available") : configuration.emptyTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canToggle(_ id: ID) -> Bool {
        guard model.state == .loaded else { return false }
        if selection.contains(id) {
            return true
        }
        return mode == .single || mode.maximum.map { selection.count < $0 } ?? true
    }
}

private struct SelectionFieldMenuRow<ID: Hashable & Sendable>: View {
    let option: SelectionFieldOption<ID>
    let selected: Bool
    let highlighted: Bool
    let multiple: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SelectionFieldOptionLabel(option: option, showsSubtitle: true)
                Spacer(minLength: 4)
                Image(systemName: indicator)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? SakuraCordAccentColor.color : Color.secondary.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(selected ? SakuraCordAccentColor.color.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.primary.opacity(0.18))
                        .transition(.identity)
                }
            }
            .contentShape(.rect(cornerRadius: 8))
            .opacity(enabled || selected ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: selected)
        .accessibilityLabel([option.title, option.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var indicator: String {
        if multiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "checkmark.circle.fill" : "circle"
    }

}
