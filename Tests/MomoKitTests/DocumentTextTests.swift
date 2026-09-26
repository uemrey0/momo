import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MomoKit

private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("momo-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func png(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(red: 0.3, green: 0.8, blue: 0.7, alpha: 1)
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context?.makeImage() else { return Data() }
    return ImageData.encode(image, as: .png) ?? Data()
}

@Suite("Document text")
struct DocumentTextTests {
    @Test(
        "reads plain text, Markdown, code, JSON and CSV",
        arguments: ["notes.txt", "README.md", "main.swift", "data.json", "table.csv"])
    func plainFiles(name: String) throws {
        let url = try temporaryFile(name, Data("  Ayşe, 42\nhello  \n".utf8))
        #expect(try DocumentText.extract(from: url) == "Ayşe, 42\nhello")
    }

    @Test("reads rich text documents")
    func richText() throws {
        let attributed = NSAttributedString(string: "Meeting notes: ship on Friday")
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = try temporaryFile("notes.rtf", data)
        #expect(try DocumentText.extract(from: url) == "Meeting notes: ship on Friday")
    }

    @Test("shortens long documents with a note")
    func shortens() throws {
        let url = try temporaryFile("long.txt", Data(String(repeating: "a", count: 500).utf8))
        let text = try DocumentText.extract(from: url, limit: 100)
        #expect(text.hasPrefix(String(repeating: "a", count: 100) + "\n[… cut here"))
    }

    @Test("rejects binary and empty files")
    func rejects() throws {
        let binary = try temporaryFile("blob.bin", Data([0x00, 0x01, 0x02, 0xFF]))
        #expect(throws: ToolError.self) { try DocumentText.extract(from: binary) }
        let empty = try temporaryFile("empty.txt", Data("  \n".utf8))
        #expect(throws: ToolError.self) { try DocumentText.extract(from: empty) }
    }

    @Test("reads whole documents and explains iWork files and size limits")
    func fullText() throws {
        let long = String(repeating: "b", count: 70_000)
        let url = try temporaryFile("whole.txt", Data(long.utf8))
        #expect(try DocumentText.fullText(of: url) == long)
        #expect(throws: ToolError.self) {
            try DocumentText.fullText(of: url, maximumFileSize: 1_000)
        }
        let pages = try temporaryFile("slides.key", Data("zip".utf8))
        #expect(throws: ToolError.self) { try DocumentText.fullText(of: pages) }
    }

    @Test("recognises images by type")
    func images() throws {
        #expect(DocumentText.isImage(try temporaryFile("a.png", png(width: 2, height: 2))))
        #expect(!DocumentText.isImage(try temporaryFile("a.txt", Data("x".utf8))))
    }
}

@Suite("Image data")
struct ImageDataTests {
    @Test("keeps small PNGs as they are")
    func small() throws {
        let data = png(width: 20, height: 10)
        let prepared = try #require(ImageData.prepared(data))
        #expect(prepared.data == data)
        #expect(prepared.mimeType == "image/png")
    }

    @Test("scales large images down to the largest side vision models use")
    func large() throws {
        let prepared = try #require(ImageData.prepared(png(width: 3_000, height: 1_000)))
        let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == ImageData.maximumDimension)
    }

    @Test("rejects data that isn't an image")
    func notAnImage() {
        #expect(ImageData.prepared(Data("hello".utf8)) == nil)
    }
}
