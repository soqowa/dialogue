import XCTest
@testable import Dialog

final class ImportTests: XCTestCase {
    func testNestedFoldersAndDuplicateBasenamesKeepPathsAndSkipDependencies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["a/index.ts", "b/index.ts", "node_modules/package/index.js", ".git/config", "README", "image.png"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("content".utf8).write(to: url)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        let result = MaterialImport.collect([root])
        XCTAssertEqual(result.files.count, 3)
        XCTAssertTrue(result.files.contains { $0.path == root.lastPathComponent + "/a/index.ts" })
        XCTAssertTrue(result.files.contains { $0.path == root.lastPathComponent + "/b/index.ts" })
        XCTAssertTrue(result.files.contains { $0.path.hasSuffix("/README") })
        XCTAssertTrue(result.errors.isEmpty)
    }
}
