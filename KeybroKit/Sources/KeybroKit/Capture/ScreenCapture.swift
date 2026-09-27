import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshot of one app's front window, taken only when Generate runs. Never saved to disk.
public enum ScreenCapture {
    /// Claude downsizes anything past ~1568px anyway; smaller uploads start faster.
    static let maxDimension = 1280

    public static func frontWindow(of pid: pid_t) async -> ClaudeImage? {
        guard CGPreflightScreenCaptureAccess(), let windowID = frontWindowID(of: pid) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return ImageEncoder.jpeg(image, maxDimension: maxDimension).map { ClaudeImage(data: $0, mediaType: "image/jpeg") }
        } catch {
            return nil
        }
    }

    /// Frontmost normal window of the app. CGWindowList is ordered front to back.
    static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 80
        }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }
}

public enum ImageEncoder {
    /// Scales down so the longest side is at most `maxDimension`, then JPEG encodes.
    public static func jpeg(_ image: CGImage, maxDimension: Int, quality: Double = 0.8) -> Data? {
        let longest = max(image.width, image.height)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
