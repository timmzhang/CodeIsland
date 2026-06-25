import Foundation
import CodeIslandCore

struct ClaudePermissionRules {
    private let fileManager: FileManager
    private let settingsPath: String

    init(
        fileManager: FileManager = .default,
        settingsPath: String? = nil
    ) {
        self.fileManager = fileManager
        self.settingsPath = settingsPath
            ?? ProcessInfo.processInfo.environment["CODEISLAND_CLAUDE_SETTINGS_PATH"]
            ?? NSHomeDirectory() + "/.claude/settings.json"
    }

    static func isClaudeEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "claude"
    }

    static func suggestions(for event: HookEvent) -> [[String: Any]] {
        for key in ["permission_suggestions", "permissionSuggestions"] {
            if let suggestions = event.rawJSON[key] as? [[String: Any]] {
                return suggestions
            }
            if let suggestions = event.rawJSON[key] as? [Any] {
                return suggestions.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    static func alwaysAllowUpdate(for event: HookEvent) -> [String: Any]? {
        guard var update = suggestions(for: event).first else { return nil }
        update["destination"] = "userSettings"
        if isPinsCommand(event),
           var rules = update["rules"] as? [[String: Any]] {
            appendRule(
                toolName: "Bash",
                ruleContent: "pins show *",
                to: &rules
            )
            appendRule(
                toolName: "Bash",
                ruleContent: "python3 ~/.agents/skills/pins/pins.py show *",
                to: &rules
            )
            update["rules"] = rules
        }
        return update
    }

    @discardableResult
    func persistAlwaysAllowRules(for event: HookEvent) -> Bool {
        guard let update = Self.alwaysAllowUpdate(for: event),
              let rules = update["rules"] as? [[String: Any]] else {
            return false
        }

        let permissionRules = rules.compactMap(Self.permissionRuleString)
        guard !permissionRules.isEmpty else { return false }

        do {
            let existing = (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "{}\n"
            guard let data = existing.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            var permissions = root["permissions"] as? [String: Any] ?? [:]
            var allow = permissions["allow"] as? [String] ?? []
            for rule in permissionRules where !allow.contains(rule) {
                allow.append(rule)
            }
            permissions["allow"] = allow

            guard let updated = JSONMinimalEditor.setTopLevelValue(
                in: existing,
                key: "permissions",
                value: permissions
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

    private static func isPinsCommand(_ event: HookEvent) -> Bool {
        guard event.toolName == "Bash",
              let command = event.toolInput?["command"] as? String else {
            return false
        }
        return command.contains("pins show ")
            || command.contains("/skills/pins/pins.py show ")
    }

    private static func appendRule(
        toolName: String,
        ruleContent: String,
        to rules: inout [[String: Any]]
    ) {
        let exists = rules.contains {
            $0["toolName"] as? String == toolName
                && $0["ruleContent"] as? String == ruleContent
        }
        if !exists {
            rules.append([
                "toolName": toolName,
                "ruleContent": ruleContent,
            ])
        }
    }

    private static func permissionRuleString(_ rule: [String: Any]) -> String? {
        guard let toolName = rule["toolName"] as? String,
              !toolName.isEmpty,
              let ruleContent = rule["ruleContent"] as? String,
              !ruleContent.isEmpty else {
            return nil
        }
        if ruleContent.hasPrefix("\(toolName)(") {
            return ruleContent
        }
        return "\(toolName)(\(ruleContent))"
    }
}
