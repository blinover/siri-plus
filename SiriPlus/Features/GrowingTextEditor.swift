import SwiftUI

/// A text box that grows with what is typed up to `maxLines`, then scrolls; nothing typed is ever cut off.
/// Return sends, Shift-Return or Option-Return starts a new line.
struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    var font: Font = .body
    var maxLines = 13
    let onSubmit: () -> Void

    var body: some View {
        // The invisible text sets the height: as tall as what is typed, at most `maxLines` lines (a trailing
        // space keeps a final empty line counted). The editor lies over it, so it can never grow past that
        // height — TextEditor alone takes all the space it is offered — and scrolls inside it instead.
        Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
            .font(font)
            .lineLimit(maxLines)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(font)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        onSubmit()
                        return .handled
                    }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .allowsHitTesting(false)
                }
            }
    }
}
