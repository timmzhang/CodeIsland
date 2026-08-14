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

/// Whether a pending Browser Use call can raise Codex's origin prompt, and how long
/// to wait before assuming it did.
enum BrowserUseAttentionTrigger: Equatable {
    /// The origin is already allowed or already denied — Codex answers from its own
    /// records and never prompts, so a call that runs long is just running long.
    case settledOrigin
    /// The call names an origin with no answer on record; a prompt is expected.
    case undecidedOrigin
    /// No URL in the code, so the origin can't be resolved ahead of the call. Only a
    /// duration well past any normal browser call is evidence of anything.
    case unresolvedOrigin
}

enum BrowserUseAttentionDetector {
    static let toolName = "mcp__node_repl__js"
    /// Long enough for a quick call to finish on its own, short enough that a real
    /// prompt is surfaced while the user is still looking at the screen.
    static let undecidedOriginDelayNanoseconds: UInt64 = 2_000_000_000
    /// Measured against this user's own Codex rollouts: 1% of browser calls without a
    /// URL run past 8s, versus 25% past 2s. A blocked call waits indefinitely, so
    /// trading latency for silence costs nothing here.
    static let unresolvedOriginDelayNanoseconds: UInt64 = 10_000_000_000
    static let attentionTimeoutNanoseconds: UInt64 = 120_000_000_000

    static func delayNanoseconds(for trigger: BrowserUseAttentionTrigger) -> UInt64? {
        switch trigger {
        case .settledOrigin: return nil
        case .undecidedOrigin: return undecidedOriginDelayNanoseconds
        case .unresolvedOrigin: return unresolvedOriginDelayNanoseconds
        }
    }

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
    /// How Codex would answer this call's origin right now.
    ///
    /// Reads `$CODEX_HOME/browser/…` through `browserUseOriginPolicyProvider`, keyed by
    /// the Codex thread id — session-scoped answers live in a per-thread file.
    func browserUseAttentionTrigger(for candidate: BrowserUseAttention) -> BrowserUseAttentionTrigger {
        guard let target = candidate.target,
              let origin = BrowserUseOriginPolicy.origin(ofURL: target) else {
            return .unresolvedOrigin
        }
        let policy = browserUseOriginPolicyProvider(codexThreadId(forSessionId: candidate.sessionId))
        switch policy.decision(forOrigin: origin) {
        case .allowed, .denied: return .settledOrigin
        case .unknown: return .undecidedOrigin
        }
    }

    /// Browser Use's per-session origin file is named by the Codex thread id, which is
    /// what hook events carry directly and what `codexapp:` sessions wrap.
    private func codexThreadId(forSessionId sessionId: String) -> String {
        if let providerSessionId = sessions[sessionId]?.providerSessionId, !providerSessionId.isEmpty {
            return providerSessionId
        }
        if sessionId.hasPrefix(AppState.codexAppSessionPrefix) {
            return String(sessionId.dropFirst(AppState.codexAppSessionPrefix.count))
        }
        return sessionId
    }

    func updateBrowserUseAttention(
        for event: HookEvent,
        delayNanoseconds: UInt64? = nil,
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
        let trigger = browserUseAttentionTrigger(for: candidate)
        guard let resolvedDelay = delayNanoseconds
                ?? BrowserUseAttentionDetector.delayNanoseconds(for: trigger) else { return }

        browserUseAttentionDelayTasks[candidate.toolUseId]?.cancel()
        browserUseAttentionDelayTasks[candidate.toolUseId] = Task { @MainActor [weak self] in
            if resolvedDelay > 0 {
                try? await Task.sleep(nanoseconds: resolvedDelay)
            }
            guard !Task.isCancelled, let self else { return }
            self.browserUseAttentionDelayTasks.removeValue(forKey: candidate.toolUseId)
            guard self.pendingToolUses[candidate.toolUseId] != nil else { return }
            // Re-read the origin files: the user may have answered "Allow" or "Always
            // allow" while we were waiting, which settles the origin and means the
            // prompt this card would point at is already gone.
            guard self.browserUseAttentionTrigger(for: candidate) != .settledOrigin else { return }
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
