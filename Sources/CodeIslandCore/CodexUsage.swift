import Foundation

/// One request's token counters as reported by Codex (`TokenUsage` in
/// codex-rs). Unlike Claude's usage shape, `inputTokens` INCLUDES
/// `cachedInputTokens` (cached is a subset, not a sibling), and
/// `outputTokens` includes reasoning tokens; `totalTokens` = input + output.
public struct CodexTokenCounts: Equatable, Sendable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let totalTokens: Int64

    public init(inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64, totalTokens: Int64) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    /// Parse the snake_case shape found in rollout jsonl `token_count` events
    /// (`{"input_tokens":…,"cached_input_tokens":…,…}`).
    public init?(rollout dict: [String: Any]?) {
        guard let dict else { return nil }
        self.init(
            inputTokens: CodexTokenCounts.int64(dict["input_tokens"]),
            cachedInputTokens: CodexTokenCounts.int64(dict["cached_input_tokens"]),
            outputTokens: CodexTokenCounts.int64(dict["output_tokens"]),
            totalTokens: CodexTokenCounts.int64(dict["total_tokens"])
        )
    }

    /// Parse the camelCase `TokenUsageBreakdown` shape carried by app-server
    /// `thread/tokenUsage/updated` notifications.
    public init?(notification obj: [String: AnyCodableLike]?) {
        guard let obj else { return nil }
        self.init(
            inputTokens: obj["inputTokens"]?.asInt64 ?? 0,
            cachedInputTokens: obj["cachedInputTokens"]?.asInt64 ?? 0,
            outputTokens: obj["outputTokens"]?.asInt64 ?? 0,
            totalTokens: obj["totalTokens"]?.asInt64 ?? 0
        )
    }

    private static func int64(_ any: Any?) -> Int64 {
        switch any {
        case let n as Int: return Int64(n)
        case let n as Int64: return n
        case let n as NSNumber: return n.int64Value
        default: return 0
        }
    }
}

extension AnyCodableLike {
    public var asInt64: Int64? {
        switch self {
        case .int(let n): return n
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s)  // some JSON-RPC producers stringify int64
        default: return nil
        }
    }
}

/// One Codex token-count sample: from a rollout jsonl `token_count` event or
/// an app-server `thread/tokenUsage/updated` notification. Both channels
/// report the same underlying counter pair (`last` = the request that just
/// finished, cumulative session total alongside), so one event shape covers
/// backfill and live.
public struct CodexUsageEvent: Equatable, Sendable {
    public let sessionId: String
    public let model: String?
    public let timestamp: Date?
    /// Usage of the request this sample reports (`last_token_usage`).
    public let last: CodexTokenCounts
    /// Session-cumulative `total_token_usage.total_tokens` after the request.
    public let cumulativeTotalTokens: Int64

    public init(
        sessionId: String,
        model: String?,
        timestamp: Date?,
        last: CodexTokenCounts,
        cumulativeTotalTokens: Int64
    ) {
        self.sessionId = sessionId
        self.model = model
        self.timestamp = timestamp
        self.last = last
        self.cumulativeTotalTokens = cumulativeTotalTokens
    }

    /// Numeric fingerprint of (cumulative-total, last breakdown) — deliberately
    /// NOT keyed on session id or timestamp:
    /// - fork/resume copies a session's history lines (including token counts)
    ///   into the new rollout file under a new session id and REWRITES their
    ///   timestamps to the fork moment, so either would defeat dedup of copies;
    /// - the app-server live channel reports the same numbers under the thread
    ///   id, which only matches the rollout file's id for non-forked threads.
    /// Turn-start snapshot re-emissions (identical total + last) collapse onto
    /// the same key, which is desired. Genuinely distinct requests whose full
    /// fingerprint coincides across sessions are lost — accepted as rare.
    public var dedupKey: String {
        "codex|\(cumulativeTotalTokens)|\(last.inputTokens)|\(last.cachedInputTokens)|\(last.outputTokens)"
    }

    /// Parse a decoded rollout jsonl row. Returns nil for rows that carry no
    /// billable usage: non-`token_count` rows, rate-limit-only updates
    /// (`info: null`), and all-zero samples.
    public static func from(
        line json: [String: Any],
        sessionId: String,
        model: String?
    ) -> CodexUsageEvent? {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = CodexTokenCounts(rollout: info["last_token_usage"] as? [String: Any]),
              let total = CodexTokenCounts(rollout: info["total_token_usage"] as? [String: Any]),
              last.totalTokens > 0
        else { return nil }

        return CodexUsageEvent(
            sessionId: sessionId,
            model: model,
            timestamp: (json["timestamp"] as? String).flatMap(parseTimestamp),
            last: last,
            cumulativeTotalTokens: total.totalTokens
        )
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

/// Tracks which token-count samples were already counted, shared between the
/// backfill scan and the live notification channel. Thread-safe.
public final class CodexUsageDeduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []

    public init() {}

    /// Returns true the first time this event's `dedupKey` is seen, false for duplicates.
    public func markSeen(_ event: CodexUsageEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(event.dedupKey).inserted
    }
}

/// One-shot full-history scan of Codex rollout files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`) for usage
/// backfill. Lines are prefiltered on byte probes so the JSON parser only
/// runs on candidate rows; files are processed strictly oldest-first
/// (concurrency defaults to 1) so a fork's copied history always dedups
/// against the original file rather than the other way around — the copies
/// carry rewritten fork-moment timestamps, so letting them win would
/// misbucket that history. Raise `concurrency` only where that attribution
/// doesn't matter.
public enum CodexUsageBackfill {
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

    public static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    /// Every `*.jsonl` under the sessions root, sorted by path — the
    /// `YYYY/MM/DD/rollout-<timestamp>-…` layout makes that chronological.
    public static func rolloutFiles(under sessionsRoot: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Scan the whole history under `sessionsRoot`, blocking until done.
    /// Deduped events are delivered per file via `onFileEvents` (called on
    /// worker threads, possibly concurrently — the handler must be thread-safe).
    public static func scan(
        sessionsRoot: URL,
        concurrency: Int = 1,
        deduplicator: CodexUsageDeduplicator = CodexUsageDeduplicator(),
        onFileEvents: @escaping @Sendable (URL, [CodexUsageEvent]) -> Void
    ) -> Summary {
        let files = rolloutFiles(under: sessionsRoot)
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

    /// Scan a single rollout file. The session id is the FIRST `session_meta`
    /// row's id (a fork file embeds the original session's meta as its second
    /// meta row, ahead of the copied history — that one must not win), falling
    /// back to the `<uuid>` suffix of the filename. The model tracks the most
    /// recent `turn_context` row above each sample.
    public static func scanFile(
        at url: URL,
        deduplicator: CodexUsageDeduplicator?
    ) -> (events: [CodexUsageEvent], duplicates: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }

        var state = FileScanState(fallbackSessionId: sessionId(fromFilename: url))
        var events: [CodexUsageEvent] = []
        var duplicates = 0
        var fragment = Data()
        let newline: UInt8 = 0x0A

        while true {
            guard let chunk = try? handle.read(upToCount: 512 * 1024), !chunk.isEmpty else { break }
            let data = fragment + chunk
            var lineStart = data.startIndex
            var cursor = data.startIndex
            while cursor < data.endIndex {
                if data[cursor] == newline {
                    processLine(
                        data[lineStart..<cursor],
                        state: &state,
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
        // A rollout's final row normally ends with a newline; tolerate one that doesn't.
        if !fragment.isEmpty {
            processLine(
                fragment[...],
                state: &state,
                deduplicator: deduplicator,
                events: &events,
                duplicates: &duplicates
            )
        }
        return (events, duplicates)
    }

    /// `rollout-2026-04-29T15-05-17-<uuid>.jsonl` → `<uuid>`; empty when the
    /// name is too short to carry one.
    static func sessionId(fromFilename url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return stem }
        return String(stem.suffix(36))
    }

    private struct FileScanState {
        var fallbackSessionId: String
        var sessionId: String?
        var model: String?
    }

    private static let tokenCountMarker = Data(#""token_count""#.utf8)
    private static let turnContextMarker = Data(#""turn_context""#.utf8)
    private static let sessionMetaMarker = Data(#""session_meta""#.utf8)

    private static func processLine(
        _ line: Data.SubSequence,
        state: inout FileScanState,
        deduplicator: CodexUsageDeduplicator?,
        events: inout [CodexUsageEvent],
        duplicates: inout Int
    ) {
        guard !line.isEmpty else { return }
        let lineData = Data(line)

        if lineData.range(of: tokenCountMarker) != nil {
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = CodexUsageEvent.from(
                    line: json,
                    sessionId: state.sessionId ?? state.fallbackSessionId,
                    model: state.model
                  )
            else { return }
            if let deduplicator, !deduplicator.markSeen(event) {
                duplicates += 1
                return
            }
            events.append(event)
            return
        }

        if state.sessionId == nil, lineData.range(of: sessionMetaMarker) != nil {
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let id = payload["id"] as? String
            else { return }
            state.sessionId = id
            return
        }

        if lineData.range(of: turnContextMarker) != nil {
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "turn_context",
                  let payload = json["payload"] as? [String: Any],
                  let model = payload["model"] as? String, !model.isEmpty
            else { return }
            state.model = model
        }
    }
}
