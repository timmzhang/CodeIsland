import Foundation

/// One assistant message's token usage extracted from a Claude Code transcript line
/// (`message.usage` on `"type":"assistant"` rows in `~/.claude/projects/**/*.jsonl`).
public struct ClaudeUsageEvent: Equatable, Sendable {
    public let sessionId: String?
    public let messageId: String
    public let requestId: String?
    public let model: String?
    public let timestamp: Date?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// True when the row belongs to a subagent turn (`isSidechain` in the transcript),
    /// so aggregation can keep the top-level vs. subagent dimension separable.
    public let isSidechain: Bool
    /// Working directory of the session (`cwd` on transcript rows) — the
    /// project dimension for Top-projects rankings. Nil when the row lacks it.
    public let cwd: String?

    public init(
        sessionId: String?,
        messageId: String,
        requestId: String?,
        model: String?,
        timestamp: Date?,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        isSidechain: Bool,
        cwd: String? = nil
    ) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.requestId = requestId
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.isSidechain = isSidechain
        self.cwd = cwd
    }

    /// Streaming and retries duplicate the same assistant message across jsonl rows —
    /// and `--resume` copies history rows into the new session file — so the logical
    /// API response is identified by `messageId + requestId`, not by row identity.
    public var dedupKey: String {
        messageId + "|" + (requestId ?? "")
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Parse a decoded transcript row into a usage event. Returns nil for rows that
    /// carry no billable usage: non-assistant rows, rows without `message.usage` or
    /// `message.id`, synthetic (client-generated error) messages, and all-zero rows.
    public static func from(line json: [String: Any], fallbackSessionId: String? = nil) -> ClaudeUsageEvent? {
        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let messageId = message["id"] as? String
        else { return nil }

        let model = message["model"] as? String
        if model == "<synthetic>" { return nil }

        let input = intValue(usage["input_tokens"])
        let output = intValue(usage["output_tokens"])
        let cacheWrite = intValue(usage["cache_creation_input_tokens"])
        let cacheRead = intValue(usage["cache_read_input_tokens"])
        guard input + output + cacheWrite + cacheRead > 0 else { return nil }

        return ClaudeUsageEvent(
            sessionId: (json["sessionId"] as? String) ?? fallbackSessionId,
            messageId: messageId,
            requestId: json["requestId"] as? String,
            model: model,
            timestamp: (json["timestamp"] as? String).flatMap(parseTimestamp),
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            isSidechain: json["isSidechain"] as? Bool ?? false,
            cwd: json["cwd"] as? String
        )
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        default: return 0
        }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}

/// Tracks which logical API responses were already counted, across the initial
/// backfill scan and the live tail. Thread-safe; share one instance between both.
public final class ClaudeUsageDeduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []

    public init() {}

    /// Returns true the first time this event's `dedupKey` is seen, false for duplicates.
    public func markSeen(_ event: ClaudeUsageEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(event.dedupKey).inserted
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }
}

/// One-shot full-history scan of Claude Code transcripts for usage backfill.
/// Lines are prefiltered on a `"usage"` byte probe so the JSON parser only runs
/// on candidate rows; files are processed with bounded concurrency.
public enum ClaudeUsageBackfill {
    public struct Summary: Equatable, Sendable {
        public var filesScanned: Int
        public var eventsEmitted: Int
        public var duplicatesSkipped: Int

        public init(filesScanned: Int = 0, eventsEmitted: Int = 0, duplicatesSkipped: Int = 0) {
            self.filesScanned = filesScanned
            self.eventsEmitted = eventsEmitted
            self.duplicatesSkipped = duplicatesSkipped
        }
    }

    public static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Every `*.jsonl` under the projects root, recursively.
    public static func transcriptFiles(under projectsRoot: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    /// Scan the whole history under `projectsRoot`, blocking until done. Deduped
    /// events are delivered per file via `onFileEvents` (called on worker threads,
    /// possibly concurrently — the handler must be thread-safe).
    public static func scan(
        projectsRoot: URL,
        concurrency: Int = 4,
        deduplicator: ClaudeUsageDeduplicator = ClaudeUsageDeduplicator(),
        onFileEvents: @escaping @Sendable (URL, [ClaudeUsageEvent]) -> Void
    ) -> Summary {
        let files = transcriptFiles(under: projectsRoot)
        guard !files.isEmpty else { return Summary() }

        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: max(1, concurrency))
        let queue = DispatchQueue.global(qos: .utility)
        let summaryLock = NSLock()
        nonisolated(unsafe) var summary = Summary(filesScanned: files.count)

        for file in files {
            gate.wait()
            group.enter()
            queue.async {
                defer {
                    gate.signal()
                    group.leave()
                }
                let result = scanFile(at: file, deduplicator: deduplicator)
                if !result.events.isEmpty {
                    onFileEvents(file, result.events)
                }
                summaryLock.lock()
                summary.eventsEmitted += result.events.count
                summary.duplicatesSkipped += result.duplicates
                summaryLock.unlock()
            }
        }

        group.wait()
        return summary
    }

    /// Scan a single transcript file. The session id falls back to the file's
    /// basename (`<sessionId>.jsonl`) when a row doesn't carry one.
    public static func scanFile(
        at url: URL,
        deduplicator: ClaudeUsageDeduplicator?
    ) -> (events: [ClaudeUsageEvent], duplicates: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }

        let fallbackSessionId = url.deletingPathExtension().lastPathComponent
        var events: [ClaudeUsageEvent] = []
        var duplicates = 0
        var fragment = Data()
        let newline: UInt8 = 0x0A

        while true {
            guard let chunk = try? handle.read(upToCount: 512 * 1024), !chunk.isEmpty else { break }
            var data = fragment + chunk
            var lineStart = data.startIndex
            var cursor = data.startIndex
            while cursor < data.endIndex {
                if data[cursor] == newline {
                    processLine(
                        data[lineStart..<cursor],
                        fallbackSessionId: fallbackSessionId,
                        deduplicator: deduplicator,
                        events: &events,
                        duplicates: &duplicates
                    )
                    lineStart = data.index(after: cursor)
                }
                cursor = data.index(after: cursor)
            }
            fragment = Data(data[lineStart..<data.endIndex])
        }
        // A transcript's final row normally ends with a newline; tolerate one that doesn't.
        if !fragment.isEmpty {
            processLine(
                fragment[...],
                fallbackSessionId: fallbackSessionId,
                deduplicator: deduplicator,
                events: &events,
                duplicates: &duplicates
            )
        }
        return (events, duplicates)
    }

    private static let usageMarker = Data(#""usage""#.utf8)

    private static func processLine(
        _ line: Data.SubSequence,
        fallbackSessionId: String,
        deduplicator: ClaudeUsageDeduplicator?,
        events: inout [ClaudeUsageEvent],
        duplicates: inout Int
    ) {
        guard !line.isEmpty else { return }
        let lineData = Data(line)
        guard lineData.range(of: usageMarker) != nil,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let event = ClaudeUsageEvent.from(line: json, fallbackSessionId: fallbackSessionId)
        else { return }

        if let deduplicator, !deduplicator.markSeen(event) {
            duplicates += 1
            return
        }
        events.append(event)
    }
}
