import Foundation
import CodeIslandCore

struct CodexPermissionRules {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func isCodexEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "codex"
    }

    static func shouldDeferToCodexAutoReview(for event: HookEvent, fileManager: FileManager = .default) -> Bool {
        guard isCodexEvent(event) else { return false }

        if let reviewer = eventReviewerValue(event.rawJSON) {
            return isAutoReviewReviewer(reviewer)
        }

        let configPath = ConfigInstaller.codexHome() + "/config.toml"
        guard fileManager.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return false
        }
        return configEnablesAutoReview(contents)
    }

    static func configEnablesAutoReview(_ contents: String) -> Bool {
        var currentSection: String?
        var selectedProfile: String?
        var topLevelReviewer: String?
        var profileReviewers: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = stripTomlComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let section = tomlTableName(from: line) {
                currentSection = section
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = tomlScalarString(String(line[line.index(after: equals)...]))

            if currentSection == nil {
                if key == "profile" {
                    selectedProfile = value
                } else if key == "approvals_reviewer" {
                    topLevelReviewer = value
                }
            } else if let profileName = profileName(fromSection: currentSection),
                      key == "approvals_reviewer" {
                profileReviewers[profileName] = value
            }
        }

        if let selectedProfile,
           let profileReviewer = profileReviewers[selectedProfile] {
            return isAutoReviewReviewer(profileReviewer)
        }

        if let topLevelReviewer {
            return isAutoReviewReviewer(topLevelReviewer)
        }

        return false
    }

    static func prefixPattern(for event: HookEvent) -> [String]? {
        if let suggested = findSuggestedPrefixRule(in: event.rawJSON) {
            return suggested
        }

        guard event.toolName == "Bash",
              let command = event.toolInput?["command"] as? String else {
            return nil
        }

        return shellPrefix(from: command, maxTokens: 3)
    }

    @discardableResult
    func persistAlwaysAllowRule(for event: HookEvent) -> Bool {
        guard let pattern = Self.prefixPattern(for: event), !pattern.isEmpty else {
            return false
        }

        let rulesDirectory = ConfigInstaller.codexHome() + "/rules"
        let rulesPath = rulesDirectory + "/codeisland.rules"
        let block = Self.ruleBlock(for: pattern)
        let patternLine = Self.patternLine(for: pattern)

        do {
            try fileManager.createDirectory(atPath: rulesDirectory, withIntermediateDirectories: true)

            let existing = (try? String(contentsOfFile: rulesPath, encoding: .utf8)) ?? ""
            let sanitized = Self.sanitizedExistingRules(existing)
            if Self.containsAllowRule(patternLine: patternLine, in: sanitized) {
                if sanitized != existing {
                    try sanitized.write(toFile: rulesPath, atomically: true, encoding: .utf8)
                }
                return true
            }

            let separator = sanitized.isEmpty || sanitized.hasSuffix("\n") ? "" : "\n"
            let updated = sanitized + separator + block
            try updated.write(toFile: rulesPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func patternLine(for pattern: [String]) -> String {
        "pattern=[\(pattern.map(quotedRuleString).joined(separator: ", "))]"
    }

    private static func ruleBlock(for pattern: [String]) -> String {
        ruleBlock(patternLine: patternLine(for: pattern))
    }

    private static func ruleBlock(patternLine: String) -> String {
        """
        # Added by CodeIsland when "Always Allow" is clicked for Codex.
        prefix_rule(\(patternLine), decision="allow", justification="Allowed from CodeIsland Always Allow")

        """
    }

    private static func quotedRuleString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    private static func containsAllowRule(patternLine: String, in contents: String) -> Bool {
        contents.contains(patternLine)
            && contents.contains(#"decision="allow""#)
    }

    private static func sanitizedExistingRules(_ contents: String) -> String {
        guard !contents.isEmpty else { return contents }

        let lines = contents.components(separatedBy: .newlines)
        var seenPatterns: Set<String> = []
        var blocks: [String] = []

        for (index, line) in lines.enumerated() {
            guard let arrayExpression = patternArrayExpression(in: line) else { continue }

            let lookaheadEnd = min(index + 8, lines.count - 1)
            let window = lines[index...lookaheadEnd].joined(separator: "\n")
            let compactWindow = window.filter { !$0.isWhitespace }
            guard compactWindow.contains(#"decision="allow""#) else { continue }

            let patternLine = "pattern=\(arrayExpression)"
            guard seenPatterns.insert(patternLine).inserted else { continue }
            blocks.append(ruleBlock(patternLine: patternLine))
        }

        return blocks.joined()
    }

    private static func patternArrayExpression(in line: String) -> String? {
        guard let patternRange = line.range(of: "pattern"),
              let equalsIndex = line[patternRange.upperBound...].firstIndex(of: "="),
              let arrayStart = line[equalsIndex...].firstIndex(of: "[") else {
            return nil
        }

        var quote: Character?
        var escaping = false
        var depth = 0
        var index = arrayStart

        while index < line.endIndex {
            let char = line[index]

            if escaping {
                escaping = false
            } else if let activeQuote = quote {
                if char == "\\" {
                    escaping = true
                } else if char == activeQuote {
                    quote = nil
                }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth -= 1
                if depth == 0 {
                    return String(line[arrayStart...index])
                }
            }

            index = line.index(after: index)
        }

        return nil
    }

    private static func eventReviewerValue(_ rawJSON: [String: Any]) -> String? {
        for key in ["approvals_reviewer", "approvalsReviewer", "_approvals_reviewer"] {
            if let value = rawJSON[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func isAutoReviewReviewer(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return normalized == "auto_review" || normalized == "guardian_subagent"
    }

    private static func stripTomlComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaping = false

        for ch in line {
            if let activeQuote = quote {
                result.append(ch)
                if escaping {
                    escaping = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaping = true
                } else if ch == activeQuote {
                    quote = nil
                }
                continue
            }

            if ch == "#" {
                break
            }
            if ch == "\"" || ch == "'" {
                quote = ch
            }
            result.append(ch)
        }

        return result
    }

    private static func tomlTableName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              trimmed.hasSuffix("]"),
              !trimmed.hasPrefix("[[") else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func profileName(fromSection section: String?) -> String? {
        guard let section, section.hasPrefix("profiles.") else { return nil }
        let raw = String(section.dropFirst("profiles.".count))
        let name = tomlScalarString(raw)
        return name.isEmpty ? nil : name
    }

    private static func tomlScalarString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" || first == "'"),
              first == last else {
            return trimmed
        }

        return String(trimmed.dropFirst().dropLast())
    }

    private static func findSuggestedPrefixRule(in value: Any) -> [String]? {
        if let dictionary = value as? [String: Any] {
            for key in ["prefix_rule", "prefixRule"] {
                if let pattern = stringArray(from: dictionary[key]) {
                    return pattern
                }
            }

            for nested in dictionary.values {
                if let pattern = findSuggestedPrefixRule(in: nested) {
                    return pattern
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let pattern = findSuggestedPrefixRule(in: nested) {
                    return pattern
                }
            }
        }
        return nil
    }

    private static func stringArray(from value: Any?) -> [String]? {
        if let pattern = value as? [String], !pattern.isEmpty {
            return pattern
        }
        if let dictionary = value as? [String: Any],
           let pattern = dictionary["pattern"] as? [String],
           !pattern.isEmpty {
            return pattern
        }
        return nil
    }

    private static func shellPrefix(from command: String, maxTokens: Int) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var index = command.startIndex

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        while index < command.endIndex {
            let char = command[index]
            let next = command.index(after: index)

            if escaping {
                current.append(char)
                escaping = false
                index = next
                continue
            }

            if char == "\\" {
                escaping = true
                index = next
                continue
            }

            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                index = next
                continue
            }

            if char == "'" || char == "\"" {
                quote = char
                index = next
                continue
            }

            if char == "$", next < command.endIndex, command[next] == "(" {
                appendCurrentToken()
                break
            }

            if char == "\n" || char == "|" || char == ";" || char == "<" || char == ">" || char == "&" {
                appendCurrentToken()
                break
            }

            if char.isWhitespace {
                appendCurrentToken()
                if tokens.count >= maxTokens {
                    break
                }
            } else {
                current.append(char)
            }

            index = next
        }

        appendCurrentToken()

        let prefix = Array(tokens.prefix(maxTokens))
        guard !prefix.isEmpty, !looksLikeEnvironmentAssignment(prefix[0]) else {
            return nil
        }
        return prefix
    }

    private static func looksLikeEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="), equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
