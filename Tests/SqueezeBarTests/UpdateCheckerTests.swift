import XCTest
import PDFKit
@testable import SqueezeBar

final class UpdateCheckerTests: XCTestCase {
    func testVersions() {
        XCTAssertTrue(ReleaseVersion("v1.2.10")! > ReleaseVersion("1.2.9")!)
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"))
        for value in ["", "1..2", "1.2-beta", "-1", "v", "1. 2"] { XCTAssertNil(ReleaseVersion(value)) }
    }

    @MainActor func testSelectionCadenceAndErrors() async throws {
        let name = "UpdateTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        var tag = "v1.2.10"
        var draft = false
        var prerelease = false
        var status = 200
        var link = "https://github.com/MrBunUniverse/SqueezeBar-macOS/releases/tag/v1.2.10"
        let checker = UpdateChecker(defaults: defaults, version: "1.2.9", transport: { request in
            calls += 1
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": link, "draft": draft, "prerelease": prerelease])
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        await checker.check(manual: false)
        XCTAssertEqual(calls, 0)
        await checker.check(manual: true)
        XCTAssertEqual(checker.release?.tag_name, tag)
        checker.dismiss()
        XCTAssertNil(checker.bannerRelease)
        defaults.set(true, forKey: "automaticUpdateChecks")
        checker.automatic = true
        await checker.check(manual: false)
        XCTAssertEqual(calls, 1)
        await checker.check(manual: true)
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(checker.bannerRelease)
        for value in ["1.2.9", "1.2.8"] {
            tag = value
            await checker.check(manual: true)
            XCTAssertNil(checker.release)
        }
        tag = "2.0"
        draft = true
        await checker.check(manual: true)
        XCTAssertNil(checker.release)
        draft = false; prerelease = true
        await checker.check(manual: true)
        XCTAssertNil(checker.release)
        prerelease = false
        for bad in ["http://github.com/MrBunUniverse/SqueezeBar-macOS/releases/tag/v2", "https://evil.example/releases/tag/v2", "https://github.com/other/repo/releases/tag/v2"] {
            link = bad
            await checker.check(manual: true)
            XCTAssertTrue(checker.feedback!.contains("Couldn’t"))
        }
        link = "https://github.com/MrBunUniverse/SqueezeBar-macOS/releases/tag/v2"
        tag = "broken"
        await checker.check(manual: true)
        XCTAssertTrue(checker.feedback!.contains("Couldn’t"))
        status = 403
        await checker.check(manual: true)
        XCTAssertTrue(checker.feedback!.contains("Couldn’t"))
        let count = calls
        await checker.check(manual: false)
        XCTAssertEqual(calls, count)
    }

    @MainActor func testFailureThrottleExpiryAndConcurrentRequests() async {
        let name = "UpdateTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "automaticUpdateChecks")
        var date = Date()
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, version: "1.0", now: { date }, transport: { _ in
            calls += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            throw URLError(.timedOut)
        })
        async let first: Void = checker.check(manual: false)
        async let second: Void = checker.check(manual: false)
        _ = await (first, second)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(checker.feedback)
        await checker.check(manual: false)
        XCTAssertEqual(calls, 1)
        date = date.addingTimeInterval(86401)
        await checker.check(manual: false)
        XCTAssertEqual(calls, 2)
        await checker.check(manual: true)
        XCTAssertEqual(calls, 3)
        XCTAssertNotNil(checker.feedback)
        checker.automatic = false
        date = date.addingTimeInterval(86401)
        await checker.check(manual: false)
        XCTAssertEqual(calls, 3)
    }

    func testBugReport() {
        let url = UpdateChecker.bugReportURL(version: "1.2 & 3", system: "macOS test")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.host, "github.com")
        let body = parts.queryItems!.first!.value!
        XCTAssertTrue(body.contains("1.2 & 3"))
        XCTAssertTrue(body.contains("Expected behavior"))
        XCTAssertFalse(body.contains(NSHomeDirectory()))
    }

    func testPDFPageFailureDoesNotWritePartialDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 20, height: 30), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        XCTAssertTrue(document.write(to: input))
        let compressor = AcceleratedPDFCompressor(pageProvider: { doc, index in index == 1 ? nil : doc.page(at: index) })
        XCTAssertThrowsError(try compressor.compressPDF(from: input, to: output, config: CompressionConfiguration()) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try AcceleratedPDFCompressor().compressPDF(from: input, to: output, config: CompressionConfiguration()) { _ in }
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 2)
    }
}
