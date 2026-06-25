import Foundation
import CodeIslandCore

struct TraeCNPermissionRules {
    static let allowListKey = "AI.toolcall.v2.command.allowList"

    private let fileManager: FileManager
    private let settingsPath: String

    init(
        fileManager: FileManager = .default,
        settingsPath: String = NSHomeDirectory()
            + "/Library/Application Support/Trae CN/User/settings.json"
    ) {
        self.fileManager = fileManager
        self.settingsPath = settingsPath
    }

    static func isTraeCNEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "traecn"
    }

    static func commandPrefix(for event: HookEvent) -> String? {
        guard event.toolName == "Bash",
              let command = event.toolInput?["command"] as? String,
              let tokens = CodexPermissionRules.shellPrefix(from: command, maxTokens: 2),
              !tokens.isEmpty else {
            return nil
        }
        return tokens.joined(separator: " ")
    }

    @discardableResult
    func persistAlwaysAllowRule(for event: HookEvent) -> Bool {
        guard Self.isTraeCNEvent(event),
              let prefix = Self.commandPrefix(for: event) else {
            return false
        }

        do {
            let existing = (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "{}\n"
            guard let rootData = existing.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any] else {
                return false
            }

            var allowList: [String] = []
            if let encoded = root[Self.allowListKey] as? String,
               let data = encoded.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
                allowList = decoded
            } else if let decoded = root[Self.allowListKey] as? [String] {
                allowList = decoded
            }

            guard !allowList.contains(prefix) else { return true }
            allowList.append(prefix)

            let encodedData = try JSONSerialization.data(withJSONObject: allowList)
            guard let encoded = String(data: encodedData, encoding: .utf8),
                  let updated = JSONMinimalEditor.setTopLevelValue(
                    in: existing,
                    key: Self.allowListKey,
                    value: encoded
                  ) else {
                return false
            }

            let directory = (settingsPath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try updated.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
