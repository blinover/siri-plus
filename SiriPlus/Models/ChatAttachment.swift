import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A file the user attached to a question. Everything is turned into what every provider accepts:
/// pictures into a JPEG image, documents into plain text read on this Mac.
struct ChatAttachment: Identifiable, Equatable, Codable, Sendable {
    enum Content: Equatable, Codable, Sendable {
        case image(Data)
        case text(String)
    }

    let id: UUID
    let name: String
    let content: Content

    init(name: String, content: Content) {
        self.id = UUID()
        self.name = name
        self.content = content
    }

    var imageData: Data? {
        if case .image(let data) = content { data } else { nil }
    }

    /// The file as a tagged block the model can quote from; nil for images, which travel separately.
    var promptBlock: String? {
        guard case .text(let text) = content else { return nil }
        return "<attachment name=\"\(name)\">\n\(text)\n</attachment>"
    }

    var symbol: String {
        switch content {
        case .image: "photo"
        case .text:
            if name.lowercased().hasSuffix(".pdf") { "doc.richtext" }
            else if let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .audiovisualContent) { "waveform" }
            else { "doc.text" }
        }
    }
}

enum AttachmentError: LocalizedError, Equatable {
    case unsupported(String)
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): String(localized: "\(name) cannot be attached: images, PDFs, text, audio and video files are supported.")
        case .unreadable(let name): String(localized: "\(name) could not be read.")
        case .empty(let name): String(localized: "\(name) has no text to analyze.")
        }
    }
}

extension ChatAttachment {
    /// Text beyond this is cut off; models still get the beginning of very long files.
    static let textLimit = 150_000

    static func load(from url: URL) throws -> ChatAttachment {
        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let jpeg = ScreenCaptureService.jpeg(cgImage) else { throw AttachmentError.unreadable(name) }
            return ChatAttachment(name: name, content: .image(jpeg))
        }

        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw AttachmentError.unreadable(name) }
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AttachmentError.empty(name) }
            return ChatAttachment(name: name, content: .text(limited(text)))
        }

        // Source code, logs, CSV, JSON and other text, including files with unknown extensions.
        guard type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || type == nil || type == .data,
              let data = try? Data(contentsOf: url) else { throw AttachmentError.unsupported(name) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else {
            throw AttachmentError.unsupported(name)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AttachmentError.empty(name) }
        return ChatAttachment(name: name, content: .text(limited(trimmed)))
    }

    static func limited(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "\n[…]" : text
    }
}
