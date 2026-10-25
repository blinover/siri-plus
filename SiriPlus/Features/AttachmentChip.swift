import AppKit
import SwiftUI

/// A pending attachment with a thumbnail or a file icon, and a button that removes it.
struct AttachmentChip: View {
    let attachment: ChatAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let data = attachment.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: attachment.symbol)
            }
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// A file whose speech is still being recognized.
struct ProcessingChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help("Recognizing speech…")
    }
}
