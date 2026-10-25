import AppKit
import CoreText
import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct AttachmentTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "siriplus-attachments-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func textAndCodeFilesBecomeText() throws {
        let url = folder.appending(path: "notes.swift")
        try "let answer = 42".write(to: url, atomically: true, encoding: .utf8)
        let attachment = try ChatAttachment.load(from: url)
        #expect(attachment.content == .text("let answer = 42"))
        #expect(attachment.promptBlock == "<attachment name=\"notes.swift\">\nlet answer = 42\n</attachment>")
    }

    @Test func imagesBecomeJPEG() throws {
        let url = folder.appending(path: "dot.png")
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        let attachment = try ChatAttachment.load(from: url)
        let data = try #require(attachment.imageData)
        #expect(data.starts(with: [0xFF, 0xD8]))
    }

    @Test func pdfTextIsExtractedLocally() throws {
        let url = folder.appending(path: "contract.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Payment due in 30 days", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let attachment = try ChatAttachment.load(from: url)
        guard case .text(let text) = attachment.content else { Issue.record("expected text"); return }
        #expect(text.contains("Payment due in 30 days"))
    }

    @Test func binaryFilesAreRefused() throws {
        let url = folder.appending(path: "archive.zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        #expect(throws: AttachmentError.unsupported("archive.zip")) { try ChatAttachment.load(from: url) }
    }

    @Test func longTextIsCut() {
        let text = String(repeating: "a", count: ChatAttachment.textLimit + 10)
        #expect(ChatAttachment.limited(text).hasSuffix("[…]"))
        #expect(ChatAttachment.limited("short") == "short")
    }

    @Test func attachmentsTravelWithTheMessage() {
        let message = ChatMessage(role: .user, text: "Что тут?", imageJPEG: Data([9]), attachments: [
            ChatAttachment(name: "a.txt", content: .text("привет")),
            ChatAttachment(name: "b.jpg", content: .image(Data([1]))),
        ])
        let prompt = AssistantPrompts.chat(AssistantRequest(messages: [message], replyStyle: .brief, selection: ModelSelection()), language: "English")
        #expect(prompt.turns[0].images == [Data([9]), Data([1])])
        #expect(prompt.turns[0].text == "Что тут?\n\n<attachment name=\"a.txt\">\nпривет\n</attachment>")
    }
}
