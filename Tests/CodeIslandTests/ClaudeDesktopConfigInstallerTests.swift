import Foundation
import XCTest
@testable import CodeIsland

final class ClaudeDesktopConfigInstallerTests: XCTestCase {
    func testInstallsAndRemovesHooksInCoworkScopedClaudeConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDir = root
            .appendingPathComponent("workspace/account/local_session/.claude", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let settings = configDir.appendingPathComponent("settings.json")
        try #"{"theme":"dark"}"#.write(to: settings, atomically: true, encoding: .utf8)

        let changed = ConfigInstaller.installClaudeDesktopSessionHooks(
            sessionsRoot: root.path,
            fm: .default
        )
        XCTAssertEqual(
            changed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [settings.resolvingSymlinksInPath().path]
        )

        let data = try Data(contentsOf: settings)
        let rootObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(rootObject["theme"] as? String, "dark")
        let hooks = try XCTUnwrap(rootObject["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PermissionRequest"])

        ConfigInstaller.uninstallClaudeDesktopSessionHooks(
            sessionsRoot: root.path,
            fm: .default
        )
        let cleanedData = try Data(contentsOf: settings)
        let cleaned = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cleanedData) as? [String: Any]
        )
        XCTAssertEqual(cleaned["theme"] as? String, "dark")
        XCTAssertNil(cleaned["hooks"])
    }

    func testSkipsUnrelatedHiddenDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertTrue(ConfigInstaller.installClaudeDesktopSessionHooks(
            sessionsRoot: root.path,
            fm: .default
        ).isEmpty)
    }
}
