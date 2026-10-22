import AppKit
import ScreenCaptureKit

struct ScreenSnapshot {
    let image: NSImage
    let createdAt: Date
    /// Downscaled JPEG sent to the model with the next message.
    let jpegData: Data?

    init(image: NSImage, createdAt: Date, jpegData: Data? = nil) {
        self.image = image
        self.createdAt = createdAt
        self.jpegData = jpegData
    }
}

enum ScreenCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        "Не найден доступный экран. Подключите дисплей и повторите снимок."
    }
}

@MainActor
protocol ScreenCapturing {
    func captureMainDisplay() async throws -> ScreenSnapshot
}

@MainActor
final class ScreenCaptureService: ScreenCapturing {
    func captureMainDisplay() async throws -> ScreenSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        // Keep the assistant's own UI out of the context supplied by the user.
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return ScreenSnapshot(image: NSImage(cgImage: image, size: .zero), createdAt: Date(), jpegData: Self.jpeg(image))
    }

    /// Vision input gains nothing above ~1600 px on the long side; smaller images upload faster.
    static func jpeg(_ image: CGImage, maxDimension: Int = 1600) -> Data? {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
