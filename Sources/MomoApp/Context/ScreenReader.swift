import AppKit
import CoreGraphics
import Foundation
import MomoKit
import ScreenCaptureKit
import Vision

/// Reads the text on the screen with on-device OCR, so Momo can help with what the user is
/// looking at. Momo's own windows are left out of the capture.
enum ScreenReader {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must allow Momo in
    /// System Settings → Privacy & Security → Screen Recording.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures the main display and returns the text on it, top to bottom.
    static func readScreen() async throws -> String {
        guard hasPermission else {
            requestPermission()
            throw ToolError(
                "Momo needs Screen Recording permission. The user can allow it in System Settings → Privacy & Security → Screen Recording, then try again."
            )
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard
            let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first
        else {
            throw ToolError("No display to read.")
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownProcess
                || (ownBundle != nil && $0.owningApplication?.bundleIdentifier == ownBundle)
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)

        let text = try await recognizeText(in: image)
        let app = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        var header = "Screen text"
        if let app { header += " (front app: \(app))" }
        guard !text.isEmpty else { return "\(header): nothing readable is on the screen." }
        return "\(header):\n\(text.prefix(12_000))"
    }

    /// Runs Vision text recognition off the main thread.
    private static func recognizeText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations = request.results ?? []
            // Vision's origin is bottom-left; sort top to bottom, then left to right.
            return
                observations
                .sorted {
                    let lhs = $0.boundingBox
                    let rhs = $1.boundingBox
                    if abs(lhs.midY - rhs.midY) > 0.01 { return lhs.midY > rhs.midY }
                    return lhs.minX < rhs.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

extension SystemTools {
    static func readScreen() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "read_screen",
                description:
                    "Read the text currently visible on the user's screen (on-device OCR). Use it when the user asks about “this”, “what I'm looking at” or something on their screen.",
                requiresConfirmation: true),
            summary: { _ in L("Read the text on your screen") }
        ) { _ in
            try await ScreenReader.readScreen()
        }
    }
}
