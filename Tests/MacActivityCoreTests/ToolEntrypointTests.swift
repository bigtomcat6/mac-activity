import Foundation
import XCTest

final class ToolEntrypointTests: XCTestCase {
    func testMainSwiftFilesDoNotAlsoDeclareMainAttribute() throws {
        let toolsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: toolsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))
        let entrypoints = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "main.swift" }
            .sorted { $0.path < $1.path }

        XCTAssertFalse(entrypoints.isEmpty, "Expected tool entrypoints under Tools")
        for entrypoint in entrypoints {
            let source = try String(contentsOf: entrypoint, encoding: .utf8)
            XCTAssertNil(
                source.range(of: #"(?m)^\s*@main\b"#, options: .regularExpression),
                "Use a top-level entry call instead of @main in \(entrypoint.path)"
            )
        }
    }
}
