import Foundation
import CodeIslandCore

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        if session.transcriptPath == nil,
           SessionSnapshot.normalizedSupportedSource(session.source) == "claude",
           let cwd = session.cwd {
            let providerSessionId = session.providerSessionId ?? sessionId
            let inferredPath = NSHomeDirectory()
                + "/.claude/projects/\(cwd.appProjectDirEncoded())/\(providerSessionId).jsonl"
            if FileManager.default.fileExists(atPath: inferredPath) {
                session.transcriptPath = inferredPath
                sessions[sessionId] = session
            }
        }

        guard let path = session.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path
        transcriptTailer.attach(sessionId: sessionId, filePath: path)
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        for permissionDecision in delta.permissionDecisions {
            _ = resolvePermissionFromTranscript(
                sessionId: delta.sessionId,
                toolUseId: permissionDecision.toolUseId,
                decision: permissionDecision.decision
            )
        }

        guard var session = sessions[delta.sessionId] else { return }
        var mutated = false

        if let prompt = delta.lastUserPrompt, session.lastUserPrompt != prompt {
            session.lastUserPrompt = prompt
            if session.recentMessages.last(where: { $0.isUser })?.text != prompt {
                session.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            mutated = true
        }
        if let reply = delta.lastAssistantMessage, session.lastAssistantMessage != reply {
            session.lastAssistantMessage = reply
            if session.recentMessages.last(where: { !$0.isUser })?.text != reply {
                session.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            mutated = true
        }

        // Claude never fires the Stop hook when the user interrupts a turn (Esc), and
        // Claude Desktop keeps its bundled `claude` engine process alive between turns,
        // so neither the hook path nor process-exit/timeout sweeps ever settle the
        // session — it stays "thinking" forever. The transcript's interrupt marker is
        // the only reliable end-of-turn signal in that case.
        if let prompt = delta.lastUserPrompt,
           prompt.hasPrefix("[Request interrupted by user"),
           session.status != .idle {
            session.status = .idle
            session.interrupted = true
            session.currentTool = nil
            session.toolDescription = nil
            mutated = true
        }

        if mutated {
            session.lastActivity = Date()
            sessions[delta.sessionId] = session
        }
    }
}
