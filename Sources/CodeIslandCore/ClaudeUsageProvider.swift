import Foundation

extension ClaudeUsageEvent {
    /// Normalize into the store's cross-tool shape. Rows missing optional
    /// dimensions are labeled rather than dropped — a token count with an
    /// unknown model is still spend; `now` stands in for a missing timestamp
    /// (unseen in real transcripts, but better misbucketed than lost).
    public func normalized(tool: String = ClaudeUsageProvider.toolIdentifier, now: Date = Date()) -> UsageEvent {
        UsageEvent(
            tool: tool,
            sessionId: sessionId ?? "unknown",
            model: model ?? "unknown",
            project: cwd ?? "",
            timestamp: timestamp ?? now,
            inputTokens: Int64(inputTokens),
            outputTokens: Int64(outputTokens),
            cacheReadTokens: Int64(cacheReadTokens),
            cacheWriteTokens: Int64(cacheCreationTokens),
            dedupKey: dedupKey,
            isSubagent: isSidechain
        )
    }
}

/// `UsageProvider` for Claude Code transcripts.
///
/// Backfill runs the full-history `ClaudeUsageBackfill` scan. Live increments
/// are not discovered here — the app already tails every active session's
/// transcript through `JSONLTailer`, so its delta handler forwards
/// `delta.usageEvents` into `ingest(_:)` and this provider only converts,
/// deduplicates (shared with the backfill scan), and fans out to the sink
/// registered by `startTailing`.
public final class ClaudeUsageProvider: UsageProvider, @unchecked Sendable {
    public static let toolIdentifier = "claude-code"
    public var toolName: String { Self.toolIdentifier }

    private let projectsRoot: URL
    private let concurrency: Int
    private let queue: DispatchQueue
    private let deduplicator = ClaudeUsageDeduplicator()
    private let lock = NSLock()
    private var tailSink: (([UsageEvent]) -> Void)?

    public init(
        projectsRoot: URL = ClaudeUsageBackfill.defaultProjectsRoot,
        concurrency: Int = 4,
        queue: DispatchQueue = DispatchQueue.global(qos: .utility)
    ) {
        self.projectsRoot = projectsRoot
        self.concurrency = concurrency
        self.queue = queue
    }

    public func backfill(sink: @escaping ([UsageEvent]) -> Void, completion: @escaping () -> Void) {
        queue.async { [projectsRoot, concurrency, deduplicator] in
            _ = ClaudeUsageBackfill.scan(
                projectsRoot: projectsRoot,
                concurrency: concurrency,
                deduplicator: deduplicator
            ) { _, events in
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

    /// Feed usage rows observed by the app's live transcript tailer
    /// (`ConversationTailDelta.usageEvents`). Rows already counted by the
    /// backfill scan — or by an earlier delta — are dropped here; the store's
    /// persistent dedup key remains the cross-restart safety net.
    public func ingest(_ events: [ClaudeUsageEvent]) {
        lock.lock()
        let sink = tailSink
        lock.unlock()
        guard let sink, !events.isEmpty else { return }

        let fresh = events.filter { deduplicator.markSeen($0) }
        guard !fresh.isEmpty else { return }
        sink(fresh.map { $0.normalized() })
    }
}
