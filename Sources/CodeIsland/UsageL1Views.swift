import SwiftUI

// MARK: - L1 usage surfaces (design: docs/design/token-usage.md, mockup: token-usage-mockup.html)

/// Shared hover state for the toolbar entry ↔ detail popover pair. The
/// popover appears after a short delay and must survive the mouse hop from
/// entry to popover body (design: p-cfj6 — the popover is the only affordance
/// telling users the entry is clickable, so it can't vanish mid-travel).
@MainActor
@Observable
final class UsagePopoverState {
    private(set) var visible = false
    private(set) var entryHovered = false
    private(set) var popoverHovered = false

    private var showTimer: Timer?
    private var hideTimer: Timer?

    /// 200ms before showing (skip accidental fly-bys), a bit longer before
    /// hiding so the entry → popover gap can be crossed without flicker.
    private static let showDelay: TimeInterval = 0.2
    private static let hideDelay: TimeInterval = 0.25

    func hoverEntry(_ hovering: Bool) {
        entryHovered = hovering
        hovering ? scheduleShow() : scheduleHide()
    }

    func hoverPopover(_ hovering: Bool) {
        popoverHovered = hovering
        hovering ? cancelHide() : scheduleHide()
    }

    func dismiss() {
        showTimer?.invalidate()
        showTimer = nil
        cancelHide()
        setVisible(false)
    }

    private func scheduleShow() {
        cancelHide()
        guard !visible, showTimer == nil else { return }
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.showTimer = nil
                if self.entryHovered { self.setVisible(true) }
            }
        }
    }

    private func scheduleHide() {
        showTimer?.invalidate()
        showTimer = nil
        guard visible, hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hideTimer = nil
                if !self.entryHovered && !self.popoverHovered { self.setVisible(false) }
            }
        }
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func setVisible(_ newValue: Bool) {
        guard visible != newValue else { return }
        withAnimation(NotchAnimation.micro) { visible = newValue }
    }
}

/// Expanded toolbar entry「今日 Token: 7K」— plain text, no arrow/underline.
/// Hovering brightens it on a subtle background block and (after a delay)
/// raises the detail popover; clicking navigates to the in-panel detail page.
@MainActor
struct UsageToolbarEntry: View {
    var model = UsageStatsModel.shared
    var popover: UsagePopoverState
    var onOpenDetail: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false

    var body: some View {
        Button {
            popover.dismiss()
            onOpenDetail()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(l10n["usage_entry_today"])
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.55))
                Text(UsageFormat.compactTokens(model.today.totalTokens))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(hovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(NotchAnimation.micro) { hovering = h }
            popover.hoverEntry(h)
        }
    }
}

/// Hover popover under the toolbar entry: today's per-tool breakdown (reuses
/// `UsageTodaySection`) plus a「查看详情 →」footer — the click affordance.
@MainActor
struct UsageHoverPopover: View {
    var popover: UsagePopoverState
    var onOpenDetail: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var linkHovered = false

    private static let linkColor = Color(usageHex: 0x4E9BF5)

    var body: some View {
        VStack(spacing: 0) {
            UsageTodaySection()

            Button {
                popover.dismiss()
                onOpenDetail()
            } label: {
                HStack {
                    Spacer()
                    Text("\(l10n["usage_view_details"]) →")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Self.linkColor.opacity(linkHovered ? 1 : 0.85))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(NotchAnimation.micro) { linkHovered = h } }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(usageHex: 0x15181E))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .onHover { popover.hoverPopover($0) }
    }
}

/// Expanded panel section「今日 Token 用量」— per-tool subtotal bars,
/// footer with cache hit rate and equivalent cost.
@MainActor
struct UsageTodaySection: View {
    var model = UsageStatsModel.shared
    @ObservedObject private var l10n = L10n.shared

    private var snapshot: UsageTodaySnapshot { model.today }

    private static let barBackground = Color(red: 0.137, green: 0.153, blue: 0.184)  // #23272f

    private var todayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title + date · scope note
            HStack(alignment: .firstTextBaseline) {
                Text(l10n["usage_today_title"])
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("\(todayLabel) · \(l10n["usage_excl_cache_reads"])")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.bottom, 6)

            // Per-tool subtotal bars — width is each tool's share of today's total
            let totalTokens = max(snapshot.perTool.map(\.tokens).reduce(0, +), 1)
            ForEach(snapshot.perTool) { usage in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageToolColor(usage.tool))
                        .frame(width: 8, height: 8)
                    Text(usageToolDisplayName(usage.tool))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 56, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Self.barBackground)
                            Capsule()
                                .fill(usageToolColor(usage.tool))
                                .frame(width: max(3, geo.size.width * CGFloat(usage.tokens) / CGFloat(totalTokens)))
                        }
                    }
                    .frame(height: 5)
                    Text(UsageFormat.compactTokens(usage.tokens))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
                .padding(.vertical, 3.5)
            }

            // Footer: cache hit rate | equivalent cost
            if snapshot.cacheHitRate != nil || snapshot.equivalentCostUSD != nil {
                HStack {
                    if let hitRate = snapshot.cacheHitRate {
                        Text("\(l10n["usage_cache_hit"]) \(UsageFormat.percent(hitRate))")
                    }
                    Spacer()
                    if let cost = snapshot.equivalentCostUSD {
                        Text("\(UsageFormat.equivalentCost(cost)) \(l10n["usage_equiv_cost"])")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 8)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 0.5)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
