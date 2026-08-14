import Foundation

/// What Codex has already decided about one Browser Use origin.
enum BrowserUseOriginDecision: Equatable {
    /// "Allow" (this session) or "Always allow" (persisted) was answered before.
    case allowed
    /// "Cancel" was answered before; the call fails outright instead of asking again.
    case denied
    /// No answer on record — the next call to this origin raises Codex's prompt.
    case unknown
}

/// Codex's Browser Use asks `Allow Browser use to access <origin>?` at most once per
/// origin and persists the answer: "Always allow" appends to
/// `$CODEX_HOME/browser/config.toml`, a one-session "Allow" appends to
/// `$CODEX_HOME/browser/sessions/<threadId>.toml`. Both files share one shape:
///
/// ```toml
/// [origins]
/// allowed = ["http://127.0.0.1:5195", "https://example.com"]
/// denied = []
/// ```
///
/// CodeIsland cannot see the prompt itself (it never reaches a hook — see
/// `.omg/rules/learned/browser-use-prompt-is-origin-gated.md`), but reading these two
/// files answers the question that matters for the attention card: *can* this call
/// raise a prompt at all? An origin that is already allowed or already denied never
/// will, so a slow call to it is just a slow call.
struct BrowserUseOriginPolicy: Equatable {
    var allowed: Set<String> = []
    var denied: Set<String> = []

    static let empty = BrowserUseOriginPolicy()

    func decision(forOrigin origin: String) -> BrowserUseOriginDecision {
        guard let normalized = Self.origin(ofURL: origin) else { return .unknown }
        if denied.contains(normalized) { return .denied }
        if allowed.contains(normalized) { return .allowed }
        return .unknown
    }

    func decision(forURL url: String?) -> BrowserUseOriginDecision {
        guard let url, let origin = Self.origin(ofURL: url) else { return .unknown }
        return decision(forOrigin: origin)
    }

    /// Global answers plus the ones scoped to a single Codex thread.
    static func load(
        sessionId: String?,
        codexHome: String = ConfigInstaller.codexHome(),
        fileManager: FileManager = .default
    ) -> BrowserUseOriginPolicy {
        var policy = parse(atPath: codexHome + "/browser/config.toml", fileManager: fileManager)
        if let sessionId, !sessionId.isEmpty, !sessionId.contains("/") {
            let scoped = parse(
                atPath: codexHome + "/browser/sessions/" + sessionId + ".toml",
                fileManager: fileManager
            )
            policy.allowed.formUnion(scoped.allowed)
            policy.denied.formUnion(scoped.denied)
        }
        return policy
    }

    static func parse(atPath path: String, fileManager: FileManager = .default) -> BrowserUseOriginPolicy {
        guard fileManager.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .empty
        }
        return parse(contents)
    }

    /// Minimal reader for the one table shape these files use. Written by hand rather
    /// than pulled from a TOML library because the whole grammar in play is
    /// `[origins]` plus two arrays of quoted strings.
    static func parse(_ contents: String) -> BrowserUseOriginPolicy {
        var policy = BrowserUseOriginPolicy()
        var insideOrigins = false
        var collectingInto: WritableKeyPath<BrowserUseOriginPolicy, Set<String>>?

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if collectingInto == nil, line.hasPrefix("[") {
                insideOrigins = line.hasPrefix("[origins]")
                continue
            }
            guard insideOrigins else { continue }

            if let target = collectingInto {
                for entry in quotedStrings(in: line) {
                    if let normalized = origin(ofURL: entry) { policy[keyPath: target].insert(normalized) }
                }
                if line.contains("]") { collectingInto = nil }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            let target: WritableKeyPath<BrowserUseOriginPolicy, Set<String>>
            switch key {
            case "allowed": target = \.allowed
            case "denied": target = \.denied
            default: continue
            }

            for entry in quotedStrings(in: value) {
                if let normalized = origin(ofURL: entry) { policy[keyPath: target].insert(normalized) }
            }
            if value.contains("[") && !value.contains("]") { collectingInto = target }
        }

        return policy
    }

    /// `scheme://host[:port]`, with the scheme's default port dropped so the spelling
    /// matches what Codex writes into its allow list.
    static func origin(ofURL raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        var origin = scheme + "://" + host
        if let port = components.port, port != defaultPort(forScheme: scheme) {
            origin += ":\(port)"
        }
        return origin
    }

    private static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    private static func quotedStrings(in line: String) -> [String] {
        var results: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in line {
            if let activeQuote = quote {
                if escaping {
                    current.append(character)
                    escaping = false
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                } else if character == activeQuote {
                    results.append(current)
                    current = ""
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return results
    }

    private static func stripComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaping = false

        for character in line {
            if let activeQuote = quote {
                result.append(character)
                if escaping {
                    escaping = false
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" { quote = character }
            result.append(character)
        }
        return result
    }
}
