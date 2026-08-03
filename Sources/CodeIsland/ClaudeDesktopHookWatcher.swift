import CoreServices
import Foundation
import os.log

/// Watches Claude Desktop's Cowork session store so newly-created isolated
/// CLAUDE_CONFIG_DIR directories receive CodeIsland hooks before a tool asks
/// for user input.
final class ClaudeDesktopHookWatcher {
    private static let log = Logger(subsystem: "com.codeisland", category: "ClaudeDesktopHooks")
    private let queue = DispatchQueue(label: "com.codeisland.claude-desktop-hooks", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pendingInstall: DispatchWorkItem?

    private var claudeSupportRoot: String {
        NSHomeDirectory() + "/Library/Application Support/Claude"
    }

    func start() {
        guard stream == nil,
              ConfigInstaller.isEnabled(source: "claude"),
              FileManager.default.fileExists(atPath: claudeSupportRoot)
        else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<ClaudeDesktopHookWatcher>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .scheduleInstall()
            },
            &context,
            [claudeSupportRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        scheduleInstall(delay: 0)
    }

    func stop() {
        pendingInstall?.cancel()
        pendingInstall = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func scheduleInstall(delay: TimeInterval = 0.15) {
        pendingInstall?.cancel()
        let item = DispatchWorkItem {
            let changed = ConfigInstaller.installClaudeDesktopSessionHooks()
            if !changed.isEmpty {
                Self.log.info("Installed Cowork hooks into \(changed.count) Claude Desktop session(s)")
            }
        }
        pendingInstall = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    deinit {
        stop()
    }
}
