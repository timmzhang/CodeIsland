import Foundation

extension CodexUsageEvent {
    /// Normalize into the store's cross-tool shape, aligning counter semantics
    /// with Claude's: Claude reports input EXCLUDING cache reads while Codex's
    /// `inputTokens` includes `cachedInputTokens`, so the cached part is
    /// subtracted out of input and reported as cache reads. Codex never
    /// reports cache writes (OpenAI prompt caching is implicit and unbilled
    /// as a separate counter), so that stays 0 rather than nil-like fudging.
    public func normalized(tool: String = CodexUsageProvider.toolIdentifier, now: Date = Date()) -> UsageEvent {
        UsageEvent(
            tool: tool,
            sessionId: sessionId,
            model: model ?? "unknown",
            timestamp: timestamp ?? now,
            inputTokens: max(0, last.inputTokens - last.cachedInputTokens),
            outputTokens: last.outputTokens,
            cacheReadTokens: last.cachedInputTokens,
            cacheWriteTokens: 0,
            dedupKey: dedupKey,
            isSubagent: false
        )
    }
}

/// `UsageProvider` for Codex.
///
/// Backfill scans the rollout files under `~/.codex/sessions`. Live
/// increments arrive as app-server `thread/tokenUsage/updated` notifications
/// — the app's Codex message handler forwards them into
/// `ingestTokenUsage(params:)` — and both channels report the same counter
/// pairs, so the shared deduplicator (plus the store's persistent keys)
/// keeps them from double-counting each other.
///
/// Live coverage note: only Codex Desktop threads emit app-server
/// notifications. Codex CLI sessions are picked up by the next backfill run.
public final class CodexUsageProvider: UsageProvider, @unchecked Sendable {
    public static let toolIdentifier = "codex"
    public var toolName: String { Self.toolIdentifier }

    private let sessionsRoot: URL
    private let concurrency: Int
    private let queue: DispatchQueue
    private let deduplicator = CodexUsageDeduplicator()
    private let lock = NSLock()
    private var tailSink: (([UsageEvent]) -> Void)?
    /// threadId → model, fed by `thread/settings/updated` notifications and by
    /// the backfill scan (a resumed thread keeps its rollout session id, so the
    /// file's model attributes live events that arrive before any settings
    /// notification does).
    private var threadModels: [String: String] = [:]

    public init(
        sessionsRoot: URL = CodexUsageBackfill.defaultSessionsRoot,
        concurrency: Int = 1,  // strictly oldest-first, see CodexUsageBackfill
        queue: DispatchQueue = DispatchQueue.global(qos: .utility)
    ) {
        self.sessionsRoot = sessionsRoot
        self.concurrency = concurrency
        self.queue = queue
    }

    public func backfill(sink: @escaping ([UsageEvent]) -> Void, completion: @escaping () -> Void) {
        queue.async { [sessionsRoot, concurrency, deduplicator] in
            _ = CodexUsageBackfill.scan(
                sessionsRoot: sessionsRoot,
                concurrency: concurrency,
                deduplicator: deduplicator
            ) { [weak self] _, events in
                if let last = events.last, let model = last.model {
                    // Seed only: a live settings notification may already have
                    // recorded a fresher model than this historical file's.
                    self?.noteThreadModel(threadId: last.sessionId, model: model, overwrite: false)
                }
                sink(events.map { $0.normalized() })
            }
            completion()
        }
    }

    public func startTailing(sink: @escaping ([UsageEvent]) -> Void) {
        lock.lock()
        tailSink = sink
        lock.unlock()
    }

    public func stopTailing() {
        lock.lock()
        tailSink = nil
        lock.unlock()
    }

    /// Feed a `thread/tokenUsage/updated` notification's params. Samples the
    /// backfill scan (or an earlier notification) already counted are dropped
    /// here; the store's persistent dedup key remains the cross-restart
    /// safety net.
    public func ingestTokenUsage(params: [String: AnyCodableLike], now: Date = Date()) {
        guard let threadId = params["threadId"]?.asString,
              let usage = params["tokenUsage"]?.asObject,
              let last = CodexTokenCounts(notification: usage["last"]?.asObject),
              let total = CodexTokenCounts(notification: usage["total"]?.asObject),
              last.totalTokens > 0
        else { return }

        lock.lock()
        let sink = tailSink
        let model = threadModels[threadId]
        lock.unlock()
        guard let sink else { return }

        let event = CodexUsageEvent(
            sessionId: threadId,
            model: model,
            timestamp: now,
            last: last,
            cumulativeTotalTokens: total.totalTokens
        )
        guard deduplicator.markSeen(event) else { return }
        sink([event.normalized(now: now)])
    }

    /// Feed a `thread/settings/updated` notification's params, keeping the
    /// per-thread model current for usage attribution.
    public func noteThreadSettings(params: [String: AnyCodableLike]) {
        guard let threadId = params["threadId"]?.asString,
              let model = params["threadSettings"]?.asObject?["model"]?.asString,
              !model.isEmpty
        else { return }
        noteThreadModel(threadId: threadId, model: model, overwrite: true)
    }

    private func noteThreadModel(threadId: String, model: String, overwrite: Bool) {
        lock.lock()
        if overwrite || threadModels[threadId] == nil {
            threadModels[threadId] = model
        }
        lock.unlock()
    }
}
