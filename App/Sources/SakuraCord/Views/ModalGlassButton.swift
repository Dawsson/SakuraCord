import SwiftUI

/// The capsule Liquid Glass action used in compact window-modal footers. With the
/// footer's 12-point inset, its 40-point capsule stays concentric with a 32-point panel.
struct ModalGlassButton: View {
    let symbol: String
    let label: String
    var primary = false
    /// Replaces the label with the interaction dots, keeping the button's size.
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.body.weight(.semibold))
                .opacity(isLoading ? 0 : 1)
                .overlay { if isLoading { InteractionLoadingDotsView(tone: primary ? .onFill : .content) } }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(primary ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(), in: Capsule())
        .help(label)
        .accessibilityLabel(label)
    }
}
