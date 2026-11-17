import XCTest
@testable import SqueezeBar

final class OutcomeFeedbackTests: XCTestCase {
    @MainActor
    func testBatchRenamePreservesSkippedOriginalAndNumbering() throws {
        let state = AppState.shared
        let previousResults = state.recentResults
        let previousHistory = UserDefaults.standard.object(forKey: "squeezebar.historyList")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            state.recentResults = previousResults
            state.flushHistory()
            UserDefaults.standard.set(previousHistory, forKey: "squeezebar.historyList")
            try? FileManager.default.removeItem(at: directory)
        }
        let original = directory.appendingPathComponent("original.jpg")
        let output = directory.appendingPathComponent("compressed.jpg")
        try Data("original".utf8).write(to: original)
        try Data("output".utf8).write(to: output)
        var skipped = CompressionResult(originalURL: original, outputURL: original, originalSize: 8, compressedSize: 8, duration: 0, mediaType: .image)
        skipped.skipped = true
        let compressed = CompressionResult(originalURL: original, outputURL: output, originalSize: 8, compressedSize: 6, duration: 0, mediaType: .image)
        state.recentResults = [skipped, compressed]
        state.batchRenameResults(ids: [skipped.id, compressed.id], pattern: "renamed_#")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(state.recentResults[0].outputURL, original)
        XCTAssertEqual(state.recentResults[1].outputURL, directory.appendingPathComponent("renamed_1.jpg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed_1.jpg").path))
    }

    func testOldHistoryDecodes() throws {
        let result = CompressionResult(originalURL: URL(fileURLWithPath: "/tmp/a.jpg"), outputURL: URL(fileURLWithPath: "/tmp/a_min.jpg"), originalSize: 100, compressedSize: 80, duration: 1, mediaType: .image)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        json.removeValue(forKey: "skipped")
        json.removeValue(forKey: "savedFolderName")
        let old = try JSONDecoder().decode(CompressionResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.skipped)
        XCTAssertNil(old.outcomeCaption)
    }

    func testDestinationCaption() {
        let source = URL(fileURLWithPath: "/tmp/input/a.jpg")
        let output = URL(fileURLWithPath: "/tmp/Downloads/a_min.jpg")
        XCTAssertEqual(CompressionResult.destinationFolderName(source: source, output: output, customOutputFolder: nil, exportToSubfolder: false), "Downloads")
        XCTAssertNil(CompressionResult.destinationFolderName(source: source, output: source, customOutputFolder: nil, exportToSubfolder: false))
        XCTAssertNil(CompressionResult.destinationFolderName(source: source, output: output, customOutputFolder: "/tmp/custom", exportToSubfolder: false))
        XCTAssertNil(CompressionResult.destinationFolderName(source: source, output: output, customOutputFolder: nil, exportToSubfolder: true))
    }

    @MainActor
    func testUnsupportedDropReportsNothingProcessable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("unsupported".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        AppState.shared.clearFailures()
        let accepted = await MediaCompressionEngine.shared.processDroppedURLs([url])
        XCTAssertFalse(accepted)
        XCTAssertEqual(AppState.shared.failedJobs.first?.message, String(localized: "Unsupported file type"))
        AppState.shared.clearFailures()
        let silent = await MediaCompressionEngine.shared.processDroppedURLs([url], reportEmpty: false)
        XCTAssertFalse(silent)
        XCTAssertTrue(AppState.shared.failedJobs.isEmpty)
        AppState.shared.reportNoSupportedFiles(urls: [])
        XCTAssertEqual(AppState.shared.failedJobs.first?.message, String(localized: "Couldn’t read that file. Try dragging it from Finder."))
        AppState.shared.clearFailures()
    }
}
