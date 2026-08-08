import Foundation
import CodeIslandCore

/// Display-only hint for Browser Use calls that may be blocked in Codex's own UI.
/// CodeIsland has no decision handle for these calls, so this model deliberately
/// carries only enough context to notify the user and jump back to the source session.
struct BrowserUseAttention: Equatable {
    let toolUseId: String
    let sessionId: String
    let target: String?
    let detectedAt: Date
}

enum BrowserUseAttentionDetector {
    static let toolName = "mcp__node_repl__js"
    static let attentionDelayNanoseconds: UInt64 = 2_000_000_000
    static let attentionTimeoutNanoseconds: UInt64 = 120_000_000_000

    static func candidate(for event: HookEvent, now: Date = Date()) -> BrowserUseAttention? {
        guard EventNormalizer.normalize(event.eventName) == "PreToolUse",
              CodexPermissionRules.isCodexEvent(event),
              event.toolName == toolName,
              let toolUseId = event.toolUseId,
              !toolUseId.isEmpty,
              let code = browserCode(in: event.toolInput),
              looksLikeBrowserOperation(code) else {
            return nil
        }

        return BrowserUseAttention(
            toolUseId: toolUseId,
            sessionId: event.sessionId ?? "default",
            target: firstURL(in: code),
            detectedAt: now
        )
    }

    static func looksLikeBrowserOperation(_ code: String) -> Bool {
        let normalized = code.lowercased()
        let markers = [
            "agent.browsers",
            "setupbrowserruntime",
            "getforurl(",
            "browser.tabs",
            "browser.user",
            "browser.playwright",
            ".playwright.",
            ".navigate(",
            ".goto(",
            ".screenshot("
        ]
        return markers.contains { normalized.contains($0) }
    }

    static func displayTarget(_ target: String?) -> String? {
        guard let target, let components = URLComponents(string: target),
              let host = components.host else { return target }
        var result = host
        if let port = components.port { result += ":\(port)" }
        if !components.path.isEmpty { result += components.path }
        if let query = components.percentEncodedQuery, !query.isEmpty { result += "?\(query)" }
        return result
    }

    private static func browserCode(in input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["code", "script", "javascript"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstURL(in code: String) -> String? {
        let pattern = #"https?://[^\s\"'\\)>\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: code,
                range: NSRange(code.startIndex..<code.endIndex, in: code)
              ),
              let range = Range(match.range, in: code) else { return nil }
        return String(code[range])
    }
}

extension AppState {
    func updateBrowserUseAttention(
        for event: HookEvent,
        delayNanoseconds: UInt64 = BrowserUseAttentionDetector.attentionDelayNanoseconds,
        playSound: Bool = true
    ) {
        let normalized = EventNormalizer.normalize(event.eventName)

        if normalized == "Stop" || normalized == "SessionEnd" {
            clearBrowserUseAttention(forSessionId: event.sessionId ?? "default")
            return
        }

        if normalized == "PostToolUse"
            || normalized == "PostToolUseFailure"
            || normalized == "PermissionDenied" {
            if let toolUseId = event.toolUseId, !toolUseId.isEmpty {
                clearBrowserUseAttention(toolUseId: toolUseId)
            }
            return
        }

        guard let candidate = BrowserUseAttentionDetector.candidate(for: event) else { return }
        browserUseAttentionDelayTasks[candidate.toolUseId]?.cancel()
        browserUseAttentionDelayTasks[candidate.toolUseId] = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            self.browserUseAttentionDelayTasks.removeValue(forKey: candidate.toolUseId)
            guard self.pendingToolUses[candidate.toolUseId] != nil else { return }
            self.presentBrowserUseAttention(candidate, playSound: playSound)
        }
    }

    func resolveBrowserUseAttentionFromTranscript(toolUseIds: [String]) {
        for toolUseId in toolUseIds where !toolUseId.isEmpty {
            clearBrowserUseAttention(toolUseId: toolUseId)
        }
    }

    func clearBrowserUseAttention(
        toolUseId: String,
        showNext: Bool = true
    ) {
        browserUseAttentionDelayTasks.removeValue(forKey: toolUseId)?.cancel()
        pendingToolUses.removeValue(forKey: toolUseId)
        guard browserUseAttention?.toolUseId == toolUseId else { return }

        browserUseAttention = nil
        browserUseAttentionTimeoutTask?.cancel()
        browserUseAttentionTimeoutTask = nil
        if showNext, case .browserUseAttention = surface {
            _ = showNextPending()
        }
    }

    func clearBrowserUseAttention(
        forSessionId sessionId: String,
        showNext: Bool = true
    ) {
        let candidateIds = browserUseAttentionDelayTasks.keys.filter {
            pendingToolUses[$0]?.sessionId == sessionId
        }
        for toolUseId in candidateIds {
            browserUseAttentionDelayTasks.removeValue(forKey: toolUseId)?.cancel()
            pendingToolUses.removeValue(forKey: toolUseId)
        }

        guard let visibleAttention = browserUseAttention,
              visibleAttention.sessionId == sessionId else { return }
        pendingToolUses.removeValue(forKey: visibleAttention.toolUseId)
        browserUseAttention = nil
        browserUseAttentionTimeoutTask?.cancel()
        browserUseAttentionTimeoutTask = nil
        if showNext, case .browserUseAttention = surface {
            _ = showNextPending()
        }
    }

    func dismissBrowserUseAttention() {
        guard let attention = browserUseAttention else { return }
        clearBrowserUseAttention(toolUseId: attention.toolUseId)
    }

    func openBrowserUseAttentionSession() {
        guard let attention = browserUseAttention else { return }
        if let session = sessions[attention.sessionId], !session.isRemote {
            TerminalActivator.activate(session: session, sessionId: attention.sessionId)
        } else {
            SoundManager.shared.preview("8bit_error")
        }
        clearBrowserUseAttention(toolUseId: attention.toolUseId)
    }

    private func presentBrowserUseAttention(_ attention: BrowserUseAttention, playSound: Bool) {
        // One visible hint is enough. Browser tool calls are normally serialized;
        // suppressing a second matured heuristic avoids replacing context under the user.
        guard browserUseAttention == nil else { return }
        browserUseAttention = attention
        activeSessionId = attention.sessionId

        switch surface {
        case .approvalCard, .questionCard:
            // Real interactive requests have higher priority. showNextPending() will
            // reveal this reminder after they are resolved if the Browser call is still live.
            break
        default:
            surface = .browserUseAttention(sessionId: attention.sessionId)
            if playSound {
                SoundManager.shared.handleEvent("PermissionRequest")
            }
        }

        browserUseAttentionTimeoutTask?.cancel()
        browserUseAttentionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: BrowserUseAttentionDetector.attentionTimeoutNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.browserUseAttention?.toolUseId == attention.toolUseId else { return }
            self.clearBrowserUseAttention(toolUseId: attention.toolUseId)
        }
    }
}
