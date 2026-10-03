//
//  ReadingReportView.swift
//  「园枢」阅读时光 · 日报/周报（2026-10-03 顶级视觉版）
//
//  设计语言：对标 Apple Fitness / 微信读书 / App Store 设计大奖——
//  · 时段氛围背景（晨曦/日间/黄昏/深空渐变 + 深空星点）
//  · Hero 玻璃拟态 + 顶部光晕 + 目标进度环（Apple Fitness 式）
//  · 等宽大数字（SF Mono）+ 数字滚动 + 轻触觉
//  · 自定义胶囊模式切换、卡片错峰入场、目标参考线
//  · 全部 Apple 原生（Swift Charts + Shape），零第三方依赖

import SwiftUI
import Charts

// MARK: - 阅读目标（每日专注分钟）

enum ReadingReportGoals {
    /// 每日阅读目标（分钟）——未来可做成设置项
    static let dailyMinutes = 30
}

// MARK: - 报告页

struct ReadingReportView: View {
    @ObservedObject private var store = ReadingReportStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: ReadingReportMode = .daily
    @State private var showClearConfirm = false
    /// 卡片错峰入场（阶段推进）
    @State private var entrance = 0

    enum ReadingReportMode: String, CaseIterable {
        case daily = "日报"
        case weekly = "周报"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 时段氛围背景（全页渐变 + 深空星点）
                ambientBackground

                ScrollView {
                    VStack(spacing: 18) {
                        heroCard
                            .opacity(reveal(0))
                        modeCapsule
                            .opacity(reveal(1))
                        if mode == .daily { dailySection } else { weeklySection }
                        privacyCard
                            .opacity(reveal(6))
                        footnote
                            .opacity(reveal(6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("阅读时光")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        store.setEnabled(!store.enabled)
                    } label: {
                        Label(store.enabled ? "记录中" : "已暂停",
                              systemImage: store.enabled ? "dot.radiowaves.left.and.right" : "pause.circle.fill")
                            .displayLabelFont(13, weight: .medium)
                            .foregroundStyle(store.enabled ? Color.sjzGreen : Color.sjzOrange)
                    }
                }
            }
            .confirmationDialog("清除全部阅读记录？",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    store.clearAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("阅读时光的全部记录将永久删除，不可恢复（不影响现有阅读统计）")
                    .displayFont(13)
            }
            .task {
                // 入场错峰：逐张卡片渐入
                if !reduceMotion {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(.easeOut(duration: 0.35)) { entrance = 7 }
                } else {
                    entrance = 7
                }
            }
        }
    }

    /// 错峰显示：index 前的卡片渐入
    private func reveal(_ index: Int) -> Double {
        reduceMotion || entrance >= index ? 1 : 0
    }

    // MARK: - 时段氛围背景

    private var ambientBackground: some View {
        let palette = ReadingReportPalette.forNow()
        return ZStack {
            LinearGradient(
                colors: [
                    palette.ambientTop,
                    palette.ambientBottom,
                    Color(.systemGroupedBackground)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // 顶部光晕（Hero 处聚焦）
            RadialGradient(
                colors: [palette.colors.first?.opacity(0.16) ?? .clear, .clear],
                center: .top, startRadius: 10, endRadius: 320
            )
            .ignoresSafeArea()

            // 深空时段：星点装饰
            if palette.starry {
                StarsField(count: 26)
                    .ignoresSafeArea()
                    .opacity(0.55)
            }
        }
    }

    // MARK: - Hero（时段渐变 + 目标进度环 + 等宽大数字 + 连击）

    private var heroCard: some View {
        let palette = ReadingReportPalette.forNow()
        let today = store.todaySeconds
        let progress = min(1.0, Double(today) / Double(ReadingReportGoals.dailyMinutes * 60))
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(palette.greeting)
                        .displayFont(13, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("阅读时光")
                        .displayFont(22, weight: .bold)
                        .foregroundStyle(.white)
                }
                Spacer()
                // 目标进度环（Apple Fitness 式）
                ZStack {
                    Circle().stroke(.white.opacity(0.22), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(
                                colors: [.white.opacity(0.95), palette.ringEnd],
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: progress)
                        .shadow(color: palette.ringEnd.opacity(0.6), radius: 6)
                    VStack(spacing: 1) {
                        Text("\(Int(progress * 100))%")
                            .displayFont(13, weight: .bold)
                            .foregroundStyle(.white)
                        Text("目标 \(ReadingReportGoals.dailyMinutes)′")
                            .displayFont(9, weight: .medium)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(width: 74, height: 74)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("今日目标完成 \(Int(progress * 100))%")
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(todayDurationText)
                    .displayFont(54, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(store.todaySeconds)))
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: store.todaySeconds)
                Text("· \(store.todayArticleCount) 篇")
                    .displayFont(14, weight: .medium)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if store.currentStreak > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .displaySymbolFont(12)
                            .foregroundStyle(palette.flame)
                        Text("\(store.currentStreak) 天连击")
                            .displayFont(12, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.6))
                    .shadow(color: palette.flame.opacity(0.5), radius: 8)
                    .accessibilityLabel("阅读连击，连续 \(store.currentStreak) 天")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("今日专注 \(todayDurationText)，阅读 \(store.todayArticleCount) 篇")

            // 进度条细线（进度环的线性版本，强化层次）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 5)
                    Capsule()
                        .fill(palette.ringEnd)
                        .frame(width: max(0, geo.size.width * progress), height: 5)
                        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: palette.colors,
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white.opacity(0.08)))            // 玻璃高光层
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)) // 描边
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "book.closed.fill")
                .displaySymbolFont(88)
                .foregroundStyle(.white.opacity(0.10))
                .rotationEffect(.degrees(12))
                .offset(x: 10, y: 14)
                .accessibilityHidden(true)
        }
        .shadow(color: palette.colors.first?.opacity(0.38) ?? .clear, radius: 22, y: 12)
    }

    /// 今日专注精确文案
    private var todayDurationText: String {
        let s = store.todaySeconds
        if s <= 0 { return "0 秒" }
        if s < 60 { return "\(s) 秒" }
        let m = s / 60, r = s % 60
        return r > 0 ? "\(m) 分 \(r) 秒" : "\(m) 分钟"
    }

    // MARK: - 模式切换（自定义胶囊）

    private var modeCapsule: some View {
        HStack(spacing: 4) {
            ForEach(ReadingReportMode.allCases, id: \.self) { m in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { mode = m }
                } label: {
                    Text(m.rawValue)
                        .displayFont(14, weight: .semibold)
                        .foregroundStyle(mode == m ? Color.sjzPrimary : .secondary)
                        .padding(.horizontal, 26).padding(.vertical, 9)
                        .background {
                            if mode == m {
                                Capsule().fill(Color.sjzCard)
                                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.6))
    }

    // MARK: - 内容分区

    private var dailySection: some View {
        VStack(spacing: 14) {
            sectionHeader(icon: "chart.pie.fill", title: "今日分布")
                .opacity(reveal(2))
            categoryRingCard(sources: store.categoryMinutes())
                .opacity(reveal(3))
            sectionHeader(icon: "clock.fill", title: "今日时段")
                .opacity(reveal(4))
            hourlyHeatCard(title: "", hourly: store.hourlyMinutes(week: false))
                .opacity(reveal(5))
        }
    }

    private var weeklySection: some View {
        VStack(spacing: 14) {
            trendCard
                .opacity(reveal(2))
            weekCompareCard
                .opacity(reveal(3))
            sectionHeader(icon: "chart.pie.fill", title: "本周分布")
                .opacity(reveal(4))
            categoryRingCard(sources: store.categoryMinutes())
                .opacity(reveal(4))
            sectionHeader(icon: "clock.fill", title: "本周时段")
                .opacity(reveal(5))
            hourlyHeatCard(title: "", hourly: store.hourlyMinutes(week: true))
                .opacity(reveal(5))
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .displaySymbolFont(12, weight: .semibold)
                .foregroundStyle(Color.sjzAccent)
            Text(title)
                .displayFont(15, weight: .semibold)
                .foregroundStyle(.primary)
            Rectangle().fill(Color.sjzAccent.opacity(0.25)).frame(height: 1)
        }
    }

    // MARK: - 图表 ①：近 7 天趋势（面积 + 目标参考线）

    private var trendCard: some View {
        let days = store.recentDays(7)
        let maxVal = max(4, days.map(\.minutes).max() ?? 0)
        return ReportCard(title: "近 7 天专注趋势", caption: "分钟 / 天") {
            Chart {
                // 每日目标参考线（30 分钟）
                RuleMark(y: .value("目标", Double(ReadingReportGoals.dailyMinutes)))
                    .foregroundStyle(Color.sjzOrange.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("目标 \(ReadingReportGoals.dailyMinutes)′")
                            .displayFont(9, weight: .medium)
                            .foregroundStyle(Color.sjzOrange)
                    }

                ForEach(days) { day in
                    AreaMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("分钟", day.minutes)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [Color.sjzAccent.opacity(0.52), Color.sjzAccent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("分钟", day.minutes)
                    )
                    .foregroundStyle(Color.sjzAccent)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                    .symbol {
                        Circle().fill(Color.sjzAccent.opacity(0.16)).frame(width: 16, height: 16)
                            .overlay(Circle().fill(.white).frame(width: 8, height: 8))
                            .overlay(Circle().stroke(Color.sjzAccent, lineWidth: 2).frame(width: 8, height: 8))
                    }
                }

                // 今日高亮点
                if let today = days.last, today.key == ReadingReportStore.key(for: Date(), calendar: .current) {
                    PointMark(
                        x: .value("日期", today.date, unit: .day),
                        y: .value("分钟", today.minutes)
                    )
                    .symbol {
                        ZStack {
                            Circle().fill(Color.sjzAccent.opacity(0.25)).frame(width: 24, height: 24)
                            Circle().fill(Color.sjzAccent).frame(width: 12, height: 12)
                            Circle().fill(.white).frame(width: 4, height: 4)
                        }
                    }
                    .annotation(position: .top, spacing: 6) {
                        Text("\(today.minutes)′")
                            .displayFont(11, weight: .bold)
                            .foregroundStyle(Color.sjzAccent)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(DisplayFontFactory.font(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(.quaternary.opacity(0.5))
                    AxisValueLabel().font(DisplayFontFactory.font(size: 10)).foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: 0...(maxVal + 2))
            .frame(height: 180)
            .accessibilityLabel("近 7 天每日专注分钟趋势，目标 \(ReadingReportGoals.dailyMinutes) 分钟")
            .accessibilityValue(days.map { "\($0.key) \($0.minutes) 分钟" }.joined(separator: "，"))
        }
    }

    // MARK: - 图表 ②：周对比

    private var weekCompareCard: some View {
        let this = store.thisWeekMinutes
        let last = store.lastWeekMinutes
        let top = max(1, max(this, last))
        return ReportCard(title: "本周 vs 上周", caption: "分钟") {
            Chart {
                BarMark(x: .value("周", "上周"), y: .value("分钟", Double(last)), width: 36)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.sjzTeal.opacity(0.85), Color.sjzTeal.opacity(0.42)],
                        startPoint: .top, endPoint: .bottom))
                    .cornerRadius(10, style: .continuous)
                    .annotation(position: .top) {
                        Text("\(last)")
                            .displayFont(11, weight: .semibold)
                            .foregroundStyle(Color.sjzTeal)
                    }
                BarMark(x: .value("周", "本周"), y: .value("分钟", Double(this)), width: 36)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.sjzAccent, Color.sjzAccent.opacity(0.48)],
                        startPoint: .top, endPoint: .bottom))
                    .cornerRadius(10, style: .continuous)
                    .annotation(position: .top) {
                        Text("\(this)")
                            .displayFont(11, weight: .bold)
                            .foregroundStyle(Color.sjzAccent)
                    }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(DisplayFontFactory.font(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...(top + 2))
            .frame(height: 100)
            .overlay(alignment: .trailing) {
                if let delta = store.weekChangePercent() {
                    Label(delta >= 0 ? "↑ \(delta)%" : "↓ \(-delta)%",
                          systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .displayLabelFont(13, weight: .semibold)
                        .foregroundStyle(delta >= 0 ? Color.sjzGreen : Color.sjzOrange)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel(delta >= 0 ? "较上周增长 \(delta)%" : "较上周下降 \(-delta)%")
                }
            }
            .accessibilityLabel("本周 \(this) 分钟，上周 \(last) 分钟")
        }
    }

    // MARK: - 图表 ③：分类环形

    private func categoryRingCard(sources: [(source: String, minutes: Int)]) -> some View {
        let total = sources.reduce(0) { $0 + $1.minutes }
        return ReportCard(title: "", caption: "") {
            if total <= 0 {
                HStack {
                    Spacer()
                    Text("还没有阅读记录，去读一篇吧")
                        .displayFont(13).foregroundStyle(.secondary)
                        .padding(.vertical, 26)
                    Spacer()
                }
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 20) {
                        ZStack {
                            Circle().stroke(Color.sjzLight.opacity(0.6), lineWidth: 22)
                            ForEach(Array(sources.enumerated()), id: \.offset) { idx, item in
                                RingSector(
                                    startAngle: sectorStart(sources: sources, upto: idx) + 2,
                                    endAngle: sectorStart(sources: sources, upto: idx + 1) - 2
                                )
                                .stroke(paletteColor(idx), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: total)
                            }
                            VStack(spacing: 2) {
                                Text("\(total)").displayFont(25, weight: .bold).monospacedDigit()
                                    .contentTransition(.numericText(value: Double(total)))
                                Text("分钟").displayFont(12).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 134, height: 134)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("分类分布，共 \(total) 分钟")
                        .accessibilityValue(sources.map { "\($0.source) \($0.minutes) 分钟" }.joined(separator: "，"))

                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { idx, item in
                                HStack(spacing: 9) {
                                    Circle().fill(paletteColor(idx)).frame(width: 8, height: 8)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                    Text(item.source).displayFont(13).lineLimit(1)
                                    Spacer()
                                    Text("\(item.minutes)′").displayFont(13, weight: .medium).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.leading, 2)
                    }
                }
            }
        }
    }

    private func sectorStart(sources: [(source: String, minutes: Int)], upto: Int) -> Double {
        let total = max(1, sources.reduce(0) { $0 + $1.minutes })
        let acc = sources.prefix(upto).reduce(0) { $0 + $1.minutes }
        return Double(acc) / Double(total) * 360
    }

    private func paletteColor(_ index: Int) -> Color {
        let palette: [Color] = [.sjzAccent, .sjzTeal, .sjzGold, .sjzPurple, .sjzPink, .sjzSkyBlue]
        return palette[index % palette.count]
    }

    // MARK: - 图表 ④：时段热力

    private func hourlyHeatCard(title: String, hourly: [Int]) -> some View {
        let maxMin = max(1, hourly.max() ?? 0)
        let peakHour = hourly.firstIndex(of: hourly.max() ?? 0) ?? -1
        return ReportCard(title: title, caption: "") {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 12), spacing: 7) {
                    ForEach(0..<24, id: \.self) { hour in
                        let minutes = hourly[hour]
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(intensityColor(minutes: minutes, maxMin: maxMin))
                            .frame(height: 26)
                            .overlay(
                                Text("\(hour)")
                                    .displayFont(9, weight: minutes >= 10 ? .bold : .regular)
                                    .foregroundStyle(minutes >= 10 ? .white : .secondary))
                            .accessibilityLabel("\(hour) 点，\(minutes) 分钟")
                    }
                }
                if peakHour >= 0 {
                    Label("阅读高峰 \(peakHour) 点 · \(hourly[peakHour]) 分钟",
                          systemImage: "sparkles")
                        .displayLabelFont(12, weight: .medium)
                        .foregroundStyle(Color.sjzAccent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.sjzAccent.opacity(0.1), in: Capsule())
                        .accessibilityLabel("阅读高峰 \(peakHour) 点，\(hourly[peakHour]) 分钟")
                }
            }
        }
    }

    private func intensityColor(minutes: Int, maxMin: Int) -> Color {
        guard minutes > 0 else { return Color(.systemGray6).opacity(0.6) }
        let ratio = Double(minutes) / Double(maxMin)
        if ratio >= 0.75 { return Color.sjzAccent }
        if ratio >= 0.4 { return Color.sjzAccent.opacity(0.72) }
        if ratio >= 0.12 { return Color.sjzSkyBlue.opacity(0.5) }
        return Color.sjzSkyBlue.opacity(0.25)
    }

    // MARK: - 隐私与口径

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { store.enabled },
                set: { store.setEnabled($0) }
            )) {
                Label("记录阅读时长", systemImage: "eye.fill")
                    .displayLabelFont(15)
            }
            .onChange(of: store.enabled) { _, _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showClearConfirm = true
            } label: {
                Label("清除全部阅读记录", systemImage: "trash.fill")
                    .displayLabelFont(15)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("口径说明：时长为「实际停留时间」，切后台自动暂停，单次不足 5 秒不计；仅存本机，不联网、不上报。")
                .displayFont(12)
                .foregroundStyle(.secondary)
            Text("与文章徽标的「估算阅读时长」相互独立，互不影响。")
                .displayFont(12)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 深空星点（原生 Canvas）

private struct StarsField: View {
    let count: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.2)) { _ in
            Canvas { ctx, size in
                for i in 0..<count {
                    let x = Double((i * 37) % 100) / 100 * size.width
                    let y = Double((i * 71) % 100) / 100 * size.height * 0.6
                    let twinkle = sin(Double(i) + Date().timeIntervalSinceReferenceDate) > 0 ? 0.85 : 0.35
                    let r = Double((i % 3) + 1) * 0.8
                    let rect = CGRect(x: x, y: y, width: r, height: r)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(twinkle)))
                }
            }
        }
    }
}

// MARK: - 报告卡片容器（玻璃拟态 + 渐变描边）

private struct ReportCard<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                HStack {
                    Text(title).displayFont(16, weight: .semibold)
                    Spacer()
                    Text(caption).displayFont(12).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.sjzCard.opacity(0.94), Color.sjzLight.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.8))
        }
        .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
    }
}

// MARK: - 环形扇区

private struct RingSector: Shape {
    var startAngle: Double
    var endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false)
        return path
    }
}

// MARK: - 时段调色板（晨曦 / 日间 / 黄昏 / 深空）

private struct ReadingReportPalette {
    let colors: [Color]
    let ambientTop: Color
    let ambientBottom: Color
    let ringEnd: Color
    let flame: Color
    let greeting: String
    let starry: Bool

    static func forNow(_ date: Date = Date()) -> ReadingReportPalette {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<9:
            return ReadingReportPalette(
                colors: [Color(hex: "F2994A"), Color(hex: "E96A55")],
                ambientTop: Color(hex: "F6E7D5"), ambientBottom: Color(hex: "FBF6EF"),
                ringEnd: Color(hex: "FFD166"), flame: .white, greeting: "晨读好时光", starry: false)
        case 9..<17:
            return ReadingReportPalette(
                colors: [Color.sjzPrimary, Color(hex: "3E6FD8")],
                ambientTop: Color(hex: "E8EEFB"), ambientBottom: Color(hex: "F5F8FE"),
                ringEnd: Color.sjzAccent, flame: Color.sjzGold, greeting: "日间专注中", starry: false)
        case 17..<19:
            return ReadingReportPalette(
                colors: [Color(hex: "7B4B94"), Color(hex: "C05C7C")],
                ambientTop: Color(hex: "EFDEEF"), ambientBottom: Color(hex: "FBF4F7"),
                ringEnd: Color(hex: "FF9E7D"), flame: Color.sjzGold, greeting: "黄昏慢读", starry: false)
        default:
            return ReadingReportPalette(
                colors: [Color(hex: "0D1424"), Color(hex: "1E2A52")],
                ambientTop: Color(hex: "121A30"), ambientBottom: Color(hex: "0A0E18"),
                ringEnd: Color.sjzAccent.opacity(0.9), flame: Color.sjzOrange, greeting: "深空夜读", starry: true)
        }
    }
}
