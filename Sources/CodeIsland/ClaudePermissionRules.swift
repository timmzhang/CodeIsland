import Foundation
import CodeIslandCore

struct ClaudePermissionRules {
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
        return update
    }
}
