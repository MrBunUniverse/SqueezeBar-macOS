import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import SqueezeBar

@MainActor
final class DroppedFileURLTests: XCTestCase {
    func testMixedNativeProvidersReachMediaGathering() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let image = folder.appendingPathComponent("photo % # café.png")
        let video = folder.appendingPathComponent("clip.mov")
        let pdf = folder.appendingPathComponent("document.pdf")
        for url in [image, video, pdf] {
            try Data().write(to: url)
        }

        let providers = [
            NSItemProvider(object: image as NSURL),
            NSItemProvider(item: video as NSURL, typeIdentifier: UTType.url.identifier),
            NSItemProvider(item: pdf.absoluteString as NSString, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(object: URL(string: "https://example.com/remote.png")! as NSURL),
            NSItemProvider(object: "/tmp/plain-text.png" as NSString)
        ]
        let urls = await load(providers)
        let expected = Set([image, video, pdf].map(\.path))
        XCTAssertEqual(Set(urls.map(\.path)), expected)
        XCTAssertEqual(Set(MediaCompressionEngine.shared.gatherMediaFiles(from: urls).map(\.path)), expected)
    }

    func testRemoteURLIsRejected() async {
        let provider = NSItemProvider(object: URL(string: "https://example.com/file.pdf")! as NSURL)
        let urls = await load([provider])
        XCTAssertTrue(urls.isEmpty)
        AppState.shared.clearFailures()
    }

    func testFileURLDeliveredAsDataIsAccepted() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-data-drop.png")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = fileURL.dataRepresentation
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }

        let urls = await load([provider])
        XCTAssertEqual(urls.map(\.path), [fileURL.path])
    }

    func testNonFileStringDeliveredAsURLIsRejected() async {
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.url.identifier, loadHandler: { completion, _, _ in
            completion?("https://example.com/a.png" as NSString, nil)
        })

        let urls = await load([provider])
        XCTAssertTrue(urls.isEmpty)
        AppState.shared.clearFailures()
    }

    private func load(_ providers: [NSItemProvider]) async -> [URL] {
        await withCheckedContinuation { continuation in
            loadDroppedFileURLs(from: providers) { urls in
                MainActor.preconditionIsolated()
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: urls)
            }
        }
    }
}
