import SwiftUI
import Charts

/// L2 stats window content: 4 summary tiles, day/week stacked bar chart,
/// tool × model detail table. Visuals follow docs/design/token-usage-mockup.html;
/// the window is dark-only (the palette is validated against #111318).
struct UsageStatsView: View {
    let provider: UsageStatsProviding

    enum Granularity {
        case day, week
    }

    @State private var snapshot: UsageStatsSnapshot?
    @State private var granularity: Granularity
    @ObservedObject private var l10n = L10n.shared

    /// `initialSnapshot`/`initialGranularity` bypass async loading — for
    /// previews and offscreen rendering.
    init(
        provider: UsageStatsProviding,
        initialSnapshot: UsageStatsSnapshot? = nil,
        initialGranularity: Granularity = .day
    ) {
        self.provider = provider
        _snapshot = State(initialValue: initialSnapshot)
        _granularity = State(initialValue: initialGranularity)
    }

    // Palette (dark-only, from the mockup).
    static let windowBG = Color(usageHex: 0x111318)
    private let cardBG = Color(usageHex: 0x181C23)
    private let cardBorder = Color(usageHex: 0x2A303C)
    private let ink = Color(usageHex: 0xE8EAED)
    private let ink2 = Color(usageHex: 0x9AA0AA)
    private let ink3 = Color(usageHex: 0x6B7280)
    private let good = Color(usageHex: 0x0CA30C)
    private let segSelectedBG = Color(usageHex: 0x2C3340)
    private let rowDivider = Color(usageHex: 0x1E232C)
    private let shareTrack = Color(usageHex: 0x23272F)

    var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    content(snapshot)
                        .padding(20)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Self.windowBG)
        .preferredColorScheme(.dark)
        .task {
            if snapshot == nil {
                snapshot = try? await provider.loadSnapshot()
            }
        }
    }

    private var buckets: [UsageBucket] {
        guard let snapshot else { return [] }
        return granularity == .day ? snapshot.daily : snapshot.weekly
    }

    private func content(_ snapshot: UsageStatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            headerRow
            tiles(snapshot.summary)
            UsageChartCard(
                buckets: buckets,
                title: l10n[granularity == .day ? "usage_chart_daily" : "usage_chart_weekly"],
                totalLabel: l10n[granularity == .day ? "usage_total_day" : "usage_total_week"]
            )
            detailTable(snapshot)
            Text(l10n["usage_footnote"])
                .font(.system(size: 10))
                .foregroundStyle(ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    // MARK: Header (segmented control + range label)

    private var headerRow: some View {
        HStack {
            HStack(spacing: 2) {
                segButton(l10n["usage_seg_day"], .day)
                segButton(l10n["usage_seg_week"], .week)
            }
            .padding(2)
            .background(cardBG, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(cardBorder, lineWidth: 1))

            Spacer()

            if provider.isSampleData {
                Text(l10n["usage_sample_badge"])
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(usageHex: 0xC98500))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(usageHex: 0xC98500).opacity(0.5), lineWidth: 1))
            }

            Text(rangeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ink3)
        }
    }

    private var rangeLabel: String {
        // Axis labels may carry a weekday suffix ("07-05 六"); the range
        // label shows dates only.
        let labels = buckets.map { $0.label.split(separator: " ").first.map(String.init) ?? $0.label }
        guard let first = labels.first, let last = labels.last else { return "" }
        // Week labels are bucket start dates; the mockup shows "近 8 周 · 至 <last>".
        if granularity == .week {
            return String(format: l10n["usage_range_weeks"], labels.count, last)
        }
        return "\(first) → \(last)"
    }

    private func segButton(_ title: String, _ value: Granularity) -> some View {
        let selected = granularity == value
        return Button {
            granularity = value
        } label: {
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .fontWeight(selected ? .bold : .regular)
                .foregroundStyle(selected ? ink : ink2)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(selected ? segSelectedBG : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Summary tiles

    private func tiles(_ summary: UsageSummary) -> some View {
        HStack(spacing: 10) {
            tile(key: l10n["usage_tile_today"]) {
                Text(UsageTokenFormat.abbreviated(summary.todayTokens, millionDecimals: 2))
            } detail: {
                if let delta = summary.todayDeltaVsYesterday {
                    let up = delta >= 0
                    Text("\(up ? "▲" : "▼") \(Int((abs(delta) * 100).rounded()))% ")
                        .foregroundStyle(up ? good : Color(usageHex: 0xD64545))
                    + Text(l10n["usage_delta_vs_yesterday"])
                }
            }
            tile(key: l10n["usage_tile_cost"]) {
                Text(summary.equivalentCostToday.map(UsageTokenFormat.cost) ?? "—")
            } detail: {
                if let week = summary.costWeekToDate {
                    Text(String(format: l10n["usage_week_cumulative"], UsageTokenFormat.cost(week)))
                }
            }
            tile(key: l10n["usage_tile_cache"]) {
                Text(summary.cacheHitRate.map(UsageTokenFormat.percent) ?? "—")
            } detail: {
                Text(String(
                    format: l10n["usage_cache_rw"],
                    UsageTokenFormat.abbreviated(summary.cacheReadTokens),
                    UsageTokenFormat.abbreviated(summary.cacheWriteTokens)
                ))
            }
            tile(key: l10n["usage_tile_sessions"]) {
                Text("\(summary.activeSessions)")
            } detail: {
                Text(String(format: l10n["usage_tools_in_use"], summary.activeToolCount))
            }
        }
    }

    private func tile(
        key: String,
        @ViewBuilder value: () -> Text,
        @ViewBuilder detail: () -> Text?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(ink3)
            value()
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(ink)
            Group {
                if let detail = detail() {
                    detail
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(ink3)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBG, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(cardBorder, lineWidth: 1))
    }

    // MARK: Detail table

    private let detailColumns = ["usage_col_input", "usage_col_output", "usage_col_cache_write", "usage_col_cache_read", "usage_col_cost", "usage_col_share"]

    private func detailTable(_ snapshot: UsageStatsSnapshot) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                headerCell(l10n["usage_col_tool"], leading: true)
                ForEach(detailColumns, id: \.self) { key in
                    headerCell(l10n[key], leading: false)
                }
            }
            divider(cardBorder)
            ForEach(Array(snapshot.detailRows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    toolCell(row)
                    numberCell(UsageTokenFormat.abbreviated(row.input))
                    numberCell(UsageTokenFormat.abbreviated(row.output))
                    numberCell(row.cacheWrite > 0 ? UsageTokenFormat.abbreviated(row.cacheWrite) : "—")
                    numberCell(row.cacheRead > 0 ? UsageTokenFormat.abbreviated(row.cacheRead) : "—")
                    numberCell(row.cost.map(UsageTokenFormat.cost) ?? "—")
                    shareCell(row)
                }
                if index < snapshot.detailRows.count - 1 {
                    divider(rowDivider)
                }
            }
            divider(cardBorder)
            GridRow {
                Text(l10n["usage_row_total"])
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                    .gridColumnAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                totalCell(UsageTokenFormat.abbreviated(snapshot.detailTotalInput))
                totalCell(UsageTokenFormat.abbreviated(snapshot.detailTotalOutput))
                totalCell(UsageTokenFormat.abbreviated(snapshot.detailTotalCacheWrite))
                totalCell(UsageTokenFormat.abbreviated(snapshot.detailTotalCacheRead))
                totalCell(snapshot.detailTotalCost.map(UsageTokenFormat.cost) ?? "—")
                Text("")
            }
        }
        .background(cardBG, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(cardBorder, lineWidth: 1))
    }

    private func divider(_ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
            .gridCellColumns(7)
    }

    private func headerCell(_ text: String, leading: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(ink3)
            .gridColumnAlignment(leading ? .leading : .trailing)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    private func toolCell(_ row: UsageDetailRow) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(row.tool.color)
                .frame(width: 8, height: 8)
            Text(row.toolName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ink)
            Text(row.model)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ink2)
        }
        .gridColumnAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func numberCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(ink)
            .gridColumnAlignment(.trailing)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func totalCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(ink)
            .gridColumnAlignment(.trailing)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    private func shareCell(_ row: UsageDetailRow) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(shareTrack)
            Capsule()
                .fill(row.tool.color)
                .frame(width: max(2, 64 * row.share))
        }
        .frame(width: 64, height: 5)
        .gridColumnAlignment(.trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Chart card

private struct UsageChartCard: View {
    let buckets: [UsageBucket]
    let title: String
    let totalLabel: String

    @State private var hover: HoverInfo?

    struct HoverInfo {
        let segment: UsageChartSegment
        let location: CGPoint
    }

    private let cardBG = Color(usageHex: 0x181C23)
    private let cardBorder = Color(usageHex: 0x2A303C)
    private let ink = Color(usageHex: 0xE8EAED)
    private let ink2 = Color(usageHex: 0x9AA0AA)
    private let ink3 = Color(usageHex: 0x6B7280)
    private let gridLine = Color(usageHex: 0x232833)
    private let baseLine = Color(usageHex: 0x39404D)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                Spacer()
                legend
            }
            chart
                .frame(height: 230)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(cardBG, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(cardBorder, lineWidth: 1))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(UsageTool.allCases) { tool in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tool.color)
                        .frame(width: 9, height: 9)
                    Text(tool.displayName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(ink2)
                }
            }
        }
    }

    private var segments: [UsageChartSegment] {
        UsageChartBuilder.segments(for: buckets)
    }

    private var chart: some View {
        let segments = self.segments
        return Chart {
            ForEach(segments) { segment in
                BarMark(
                    x: .value("bucket", segment.bucketLabel),
                    yStart: .value("start", segment.yStart),
                    yEnd: .value("end", segment.yEnd),
                    width: .ratio(0.52)
                )
                .foregroundStyle(segment.tool.color)
                .cornerRadius(segment.isTop ? 4 : 1.5)
                .annotation(position: .top, spacing: 5) {
                    if segment.isTop {
                        Text(UsageTokenFormat.abbreviated(segment.bucketTotal))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(ink2)
                    }
                }
            }
        }
        .chartXScale(domain: buckets.map(\.label))
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(ink3)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle((value.as(Double.self) ?? 1) == 0 ? baseLine : gridLine)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(UsageTokenFormat.abbreviated(Int(v)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(ink3)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hover = hoverInfo(at: location, proxy: proxy, geo: geo, segments: segments)
                        case .ended:
                            hover = nil
                        }
                    }
                if let hover {
                    tooltip(hover, in: geo.size)
                }
            }
        }
    }

    private func hoverInfo(
        at location: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy,
        segments: [UsageChartSegment]
    ) -> HoverInfo? {
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let origin = geo[plotAnchor].origin
        let relative = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard let label = proxy.value(atX: relative.x, as: String.self),
              let yValue = proxy.value(atY: relative.y, as: Double.self)
        else { return nil }
        guard let segment = segments.first(where: {
            $0.bucketLabel == label && yValue >= $0.yStart && yValue <= $0.yEnd
        }) else { return nil }
        return HoverInfo(segment: segment, location: location)
    }

    private func tooltip(_ hover: HoverInfo, in size: CGSize) -> some View {
        let segment = hover.segment
        let width: CGFloat = 150
        var x = hover.location.x + 14
        if x + width > size.width { x = hover.location.x - width - 14 }
        let y = max(10, hover.location.y - 14)
        return VStack(alignment: .leading, spacing: 3) {
            Text(segment.bucketLabel)
                .foregroundStyle(ink3)
            HStack {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(segment.tool.color)
                        .frame(width: 7, height: 7)
                    Text(segment.tool.displayName)
                        .foregroundStyle(ink)
                }
                Spacer(minLength: 14)
                Text(UsageTokenFormat.abbreviated(segment.value))
                    .bold()
                    .foregroundStyle(ink)
            }
            HStack {
                Text(totalLabel)
                Spacer(minLength: 14)
                Text(UsageTokenFormat.abbreviated(segment.bucketTotal))
            }
            .foregroundStyle(ink3)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minWidth: width, alignment: .leading)
        .background(Color(usageHex: 0x0B0D11), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(usageHex: 0x363D4A), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .position(x: x + width / 2, y: y)
        .allowsHitTesting(false)
    }
}
