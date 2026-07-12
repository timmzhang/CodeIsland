import AppKit
import SwiftUI

/// Standalone window for the token usage report (peer of the Settings
/// window). The window is dark-only: the design palette is validated
/// against #111318 and the notch world has no light mode.
@MainActor
final class UsageStatsWindowController {
    static let shared = UsageStatsWindowController()

    /// Swap in a UsageStore-backed provider once end-to-end collection is
    /// wired into the app (the store and per-tool providers already live in
    /// CodeIslandCore); defaults to canned sample data so the window is
    /// usable and reviewable before then.
    var provider: UsageStatsProviding = SampleUsageStatsProvider()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var openObserver: NSObjectProtocol?

    /// The notch toolbar entry (UsageToolbarEntry) posts
    /// `.openUsageStatsWindow` instead of depending on this controller.
    func startObserving() {
        guard openObserver == nil else { return }
        openObserver = NotificationCenter.default.addObserver(
            forName: .openUsageStatsWindow, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                UsageStatsWindowController.shared.show()
            }
        }
    }

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let statsView = UsageStatsView(provider: provider)
        let hostingView = NSHostingView(rootView: statsView)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(880, screenW * 0.6)
        let winH = min(680, screenH * 0.75)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = L10n.shared["usage_stats_title"]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0, alpha: 1
        )
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.toolbar = nil
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Same as SettingsWindowController: revert to accessory policy on
        // close without hiding the whole app.
        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window = nil
                self?.clearCloseObserver()
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.window = window
    }
}
