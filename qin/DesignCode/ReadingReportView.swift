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

// MARK: - 报告页

struct ReadingReportView: View {
    @ObservedObject private var store = ReadingReportStore.shared
    @ObservedObject private var goalStore = ReadingGoalStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: ReadingReportMode = .daily
    @State private var showClearConfirm = false
    @State private var showGoalEditor = false
    /// Hero 目标环周期（日/周，跟随切换）
    @State private var heroPeriod: ReadingGoalPeriod = .daily
    /// 卡片错峰入场（阶段推进）
    @State private var entrance = 0

    enum ReadingReportMode: String, CaseIterable {
        case daily = "日报"
        case weekly = "周报"
        case monthly = "月报"
        case yearly = "年报"
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
                        contentSection
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
            .sheet(isPresented: $showGoalEditor) {
                ReadingGoalView().sjzPresentationChrome()
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

    // MARK: - 时段氛围背景（跟随系统深浅色，杜绝深色模式发白）

    private var ambientBackground: some View {
        let palette = ReadingReportPalette.forNow()
        let isDark = colorScheme == .dark
        return ZStack {
            LinearGradient(
                colors: isDark
                    ? [palette.colors.first?.opacity(0.22) ?? Color(hex: "141A2C"),
                       Color(hex: "111827"),
                       Color(.systemGroupedBackground)]
                    : [palette.ambientTop, palette.ambientBottom, Color(.systemGroupedBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // 顶部光晕（Hero 处聚焦；深色模式更明显）
            RadialGradient(
                colors: [palette.colors.first?.opacity(isDark ? 0.24 : 0.16) ?? .clear, .clear],
                center: .top, startRadius: 10, endRadius: 320
            )
            .ignoresSafeArea()

            // 星点：深色模式全天启用（氛围）；浅色模式仅深空时段
            if palette.starry || isDark {
                StarsField(count: isDark ? 30 : 26)
                    .ignoresSafeArea()
                    .opacity(isDark ? 0.65 : 0.55)
            }
        }
    }

    // MARK: - Hero（时段渐变 + 目标进度环 + 等宽大数字 + 连击）

    private var heroCard: some View {
        let palette = ReadingReportPalette.forNow()
        let today = store.todaySeconds
        let thisWeek = store.thisWeekSeconds
        let goalMinutes = heroPeriod == .daily ? goalStore.dailyMinutes : goalStore.weeklyMinutes
        let base = heroPeriod == .daily ? today : thisWeek
        let progress = min(1.0, Double(base) / Double(max(1, goalMinutes) * 60))
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
                // 日/周目标切换（跟随当前周期）
                HStack(spacing: 2) {
                    ForEach(ReadingGoalPeriod.allCases, id: \.self) { p in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.snappy) { heroPeriod = p }
                        } label: {
                            Text(p == .daily ? "日" : "周")
                                .displayFont(11, weight: .semibold)
                                .foregroundStyle(heroPeriod == p ? Color.sjzPrimary : .white.opacity(0.75))
                                .frame(width: 28, height: 24)
                                .background {
                                    if heroPeriod == p {
                                        Capsule().fill(.white.opacity(0.9))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(heroPeriod == p ? "\(p.rawValue)目标，已选中" : "切换至\(p.rawValue)目标")
                    }
                }
                .padding(3)
                .background(.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.6))
                .padding(.trailing, 4)
                // 目标进度环（Apple Fitness 式，点击可设定）
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
                        Text("目标 \(goalMinutes)′")
                            .displayFont(9, weight: .medium)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(width: 74, height: 74)
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showGoalEditor = true
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("今日目标完成 \(Int(progress * 100))%，点击设定阅读目标")
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(todayDurationText)
                    .displayFont(54, weight: .bold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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

            // 进度条细线 + 设定目标入口（独立于环，避免环内重叠）
            HStack(spacing: 12) {
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

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showGoalEditor = true
                } label: {
                    Label("设定目标", systemImage: "target")
                        .displayLabelFont(11, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.22), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设定阅读目标")
            }
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
                .allowsHitTesting(false)  // 纯装饰，避免拦截右下「设定目标」按钮的点击
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
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(mode == m ? Color.sjzPrimary : .secondary)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background {
                            if mode == m {
                                Capsule()
                                    .fill(Color.sjzCard)
                                    .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.6))
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

    // MARK: - 内容分区（日/周/月/年）

    @ViewBuilder
    private var contentSection: some View {
        switch mode {
        case .daily: dailySection
        case .weekly: weeklySection
        case .monthly: monthlySection
        case .yearly: yearlySection
        }
    }

    private var dailySection: some View {
        VStack(spacing: 14) {
            sectionHeader(icon: "chart.pie.fill", title: "今日分布")
                .opacity(reveal(2))
            categoryRingCard(sources: store.todayCategoryMinutes())
                .opacity(reveal(3))
            sectionHeader(icon: "clock.fill", title: "今日时段")
                .opacity(reveal(4))
            hourlyHeatCard(title: "", hourly: store.hourlyMinutes(week: false),
                           peak: store.hourlyPeak(week: false), showsDay: false)
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
            hourlyHeatCard(title: "", hourly: store.hourlyMinutes(week: true),
                           peak: store.hourlyPeak(week: true), showsDay: true)
                .opacity(reveal(5))
        }
    }

    private var monthlySection: some View {
        VStack(spacing: 14) {
            monthSummaryCard
                .opacity(reveal(2))
            monthCompareCard
                .opacity(reveal(3))
            monthTrendCard
                .opacity(reveal(4))
            sectionHeader(icon: "chart.pie.fill", title: "本月分布")
                .opacity(reveal(5))
            categoryRingCard(sources: store.monthCategory())
                .opacity(reveal(5))
            sectionHeader(icon: "clock.fill", title: "本月时段")
                .opacity(reveal(6))
            hourlyHeatCard(title: "", hourly: store.monthHourly(),
                           peak: store.monthHourlyPeak(), showsDay: true)
                .opacity(reveal(6))
        }
    }

    private var yearlySection: some View {
        VStack(spacing: 14) {
            yearSummaryCard
                .opacity(reveal(2))
            yearMonthBarsCard
                .opacity(reveal(3))
            yearCompareCard
                .opacity(reveal(4))
            sectionHeader(icon: "chart.pie.fill", title: "全年分布")
                .opacity(reveal(5))
            categoryRingCard(sources: store.yearCategory())
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
        let palette = ReadingReportPalette.forNow()
        let accent = palette.colors.first ?? Color.sjzAccent
        return ReportCard(title: "近 7 天专注趋势", caption: "分钟 / 天") {
            Chart {
                // 每日目标参考线：仅在量程内可见时绘制，避免目标远超量程时被裁剪出怪异的顶部标注
                if goalStore.dailyMinutes <= maxVal + 2 {
                    RuleMark(y: .value("目标", Double(goalStore.dailyMinutes)))
                        .foregroundStyle(Color.sjzOrange.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("目标 \(goalStore.dailyMinutes)′")
                                .displayFont(9, weight: .medium)
                                .foregroundStyle(Color.sjzOrange)
                        }
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
                        // 0 值日不画圆点：避免连续零值日多个圆点完全重叠
                        if day.minutes > 0 {
                            Circle().fill(Color.sjzAccent.opacity(0.16)).frame(width: 16, height: 16)
                                .overlay(Circle().fill(.white).frame(width: 8, height: 8))
                                .overlay(Circle().stroke(Color.sjzAccent, lineWidth: 2).frame(width: 8, height: 8))
                        }
                    }
                }

                // 今日高亮点（标注加大间距，避免与折线顶点贴近交叠）
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
                    .annotation(position: .top, spacing: 14) {
                        if today.minutes > 0 {
                            Text("\(today.minutes)′")
                                .displayFont(11, weight: .bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(accent, in: Capsule())
                                .shadow(color: accent.opacity(0.45), radius: 6, y: 3)
                        }
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
            .accessibilityLabel("近 7 天每日专注分钟趋势，目标 \(goalStore.dailyMinutes) 分钟")
            .accessibilityValue(days.map { "\($0.key) \($0.minutes) 分钟" }.joined(separator: "，"))
        }
    }

    // MARK: - 图表 ②：周期对比（本周/本月/本年通用）

    private var weekCompareCard: some View {
        compareBarsCard(title: "本周 vs 上周", caption: "分钟",
                        left: "上周", right: "本周",
                        leftValue: store.lastWeekMinutes, rightValue: store.thisWeekMinutes,
                        delta: store.weekChangePercent())
    }

    private var monthCompareCard: some View {
        compareBarsCard(title: "本月 vs 上月", caption: "分钟",
                        left: "上月", right: "本月",
                        leftValue: ReadingReportStore.displayMinutes(fromSeconds: store.lastMonthSeconds),
                        rightValue: ReadingReportStore.displayMinutes(fromSeconds: store.thisMonthSeconds),
                        delta: store.monthChangePercent())
    }

    private var yearCompareCard: some View {
        compareBarsCard(title: "本年 vs 上年", caption: "分钟",
                        left: "上年", right: "本年",
                        leftValue: ReadingReportStore.displayMinutes(fromSeconds: store.lastYearSeconds),
                        rightValue: ReadingReportStore.displayMinutes(fromSeconds: store.thisYearSeconds),
                        delta: store.yearChangePercent())
    }

    /// 通用双柱对比卡（左=上一周期，右=当前周期）
    private func compareBarsCard(title: String, caption: String,
                                 left: String, right: String,
                                 leftValue: Int, rightValue: Int,
                                 delta: Int?) -> some View {
        let top = max(1, max(leftValue, rightValue))
        return ReportCard(title: title, caption: caption) {
            Chart {
                BarMark(x: .value("周期", left), y: .value("分钟", Double(leftValue)), width: 36)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.sjzTeal.opacity(0.85), Color.sjzTeal.opacity(0.42)],
                        startPoint: .top, endPoint: .bottom))
                    .cornerRadius(10, style: .continuous)
                    .annotation(position: .top) {
                        Text("\(leftValue)")
                            .displayFont(11, weight: .semibold)
                            .foregroundStyle(Color.sjzTeal)
                    }
                BarMark(x: .value("周期", right), y: .value("分钟", Double(rightValue)), width: 36)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.sjzAccent, Color.sjzAccent.opacity(0.48)],
                        startPoint: .top, endPoint: .bottom))
                    .cornerRadius(10, style: .continuous)
                    .annotation(position: .top) {
                        Text("\(rightValue)")
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
                if let delta {
                    Label(delta >= 0 ? "↑ \(delta)%" : "↓ \(-delta)%",
                          systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .displayLabelFont(13, weight: .semibold)
                        .foregroundStyle(delta >= 0 ? Color.sjzGreen : Color.sjzOrange)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel(delta >= 0 ? "较\(left)增长 \(delta)%" : "较\(left)下降 \(-delta)%")
                }
            }
            .accessibilityLabel("\(right) \(rightValue) 分钟，\(left) \(leftValue) 分钟")
        }
    }

    // MARK: - 月/年摘要与分布卡

    /// 本月摘要（2×2 统计格）
    private var monthSummaryCard: some View {
        let minutes = ReadingReportStore.displayMinutes(fromSeconds: store.thisMonthSeconds)
        let avg = ReadingReportStore.displayMinutes(fromSeconds: store.avgDailySeconds(in: store.monthInterval()))
        return ReportCard(title: "本月专注", caption: "") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                statCell(value: "\(minutes)", unit: "分钟", icon: "timer", tint: Color.sjzAccent)
                statCell(value: "\(store.thisMonthArticleCount)", unit: "篇", icon: "doc.text.fill", tint: Color.sjzTeal)
                statCell(value: "\(avg)", unit: "日均分钟", icon: "chart.line.uptrend.xyaxis", tint: Color.sjzGold)
                statCell(value: "\(store.longestStreak(in: store.monthInterval()))", unit: "最长连续天", icon: "flame.fill", tint: Color.sjzOrange)
            }
        }
    }

    /// 年度总结（大数字 + 统计格）
    private var yearSummaryCard: some View {
        let total = store.thisYearSeconds
        let avg = ReadingReportStore.displayMinutes(fromSeconds: store.avgDailySeconds(in: store.yearInterval()))
        return ReportCard(title: "本年度总结", caption: "") {
            VStack(spacing: 16) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(formatTotalHours(total))
                        .displayFont(34, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(Color.sjzAccent)
                        .contentTransition(.numericText(value: Double(total)))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    Text("\(Calendar.current.component(.year, from: Date())) 年")
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    statCell(value: "\(store.thisYearArticleCount)", unit: "篇", icon: "doc.text.fill", tint: Color.sjzTeal)
                    statCell(value: "\(avg)", unit: "日均分钟", icon: "chart.line.uptrend.xyaxis", tint: Color.sjzGold)
                    statCell(value: "\(store.longestStreak(in: store.yearInterval()))", unit: "最长连续天", icon: "flame.fill", tint: Color.sjzOrange)
                    statCell(value: "\(store.activeDays(in: store.yearInterval()))", unit: "有阅读天数", icon: "calendar", tint: Color.sjzSkyBlue)
                }
            }
        }
    }

    private func statCell(value: String, unit: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .displaySymbolFont(13, weight: .semibold)
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .displayFont(22, weight: .bold)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit)
                    .displayFont(11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.sjzCard.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 秒 → 小时分（年报大数字）
    private func formatTotalHours(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0 分钟" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分钟"
    }

    /// 近 6 个月趋势（面积图 + 当前月高亮标注胶囊，无目标线——月报无月目标）
    private var monthTrendCard: some View {
        let points = store.monthlyTrend(6)
        let maxVal = max(4, points.map { ReadingReportStore.displayMinutes(fromSeconds: $0.seconds) }.max() ?? 0)
        let palette = ReadingReportPalette.forNow()
        let accent = palette.colors.first ?? Color.sjzAccent
        return ReportCard(title: "近 6 个月专注趋势", caption: "分钟 / 月") {
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("月", p.date, unit: .month),
                             y: .value("分钟", ReadingReportStore.displayMinutes(fromSeconds: p.seconds)))
                        .foregroundStyle(LinearGradient(
                            colors: [Color.sjzAccent.opacity(0.5), Color.sjzAccent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("月", p.date, unit: .month),
                             y: .value("分钟", ReadingReportStore.displayMinutes(fromSeconds: p.seconds)))
                        .foregroundStyle(Color.sjzAccent)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                        .symbol {
                            // 0 值月不画圆点：避免连续零值月多个圆点重叠
                            if ReadingReportStore.displayMinutes(fromSeconds: p.seconds) > 0 {
                                Circle().fill(Color.sjzAccent.opacity(0.16)).frame(width: 16, height: 16)
                                    .overlay(Circle().fill(.white).frame(width: 8, height: 8))
                                    .overlay(Circle().stroke(Color.sjzAccent, lineWidth: 2).frame(width: 8, height: 8))
                            }
                        }
                }

                // 当前月高亮点 + 标注胶囊（随时段主色；带月份标识，宽间距下清晰对应）
                if let current = points.last {
                    let minutes = ReadingReportStore.displayMinutes(fromSeconds: current.seconds)
                    PointMark(x: .value("月", current.date, unit: .month),
                              y: .value("分钟", minutes))
                        .symbol {
                            ZStack {
                                Circle().fill(Color.sjzAccent.opacity(0.25)).frame(width: 24, height: 24)
                                Circle().fill(Color.sjzAccent).frame(width: 12, height: 12)
                                Circle().fill(.white).frame(width: 4, height: 4)
                            }
                        }
                        .annotation(position: .top, spacing: 8) {
                            if minutes > 0 {
                                Text("\(monthLabel(current.date)) \(minutes)′")
                                    .displayFont(11, weight: .bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(accent, in: Capsule())
                                    .shadow(color: accent.opacity(0.45), radius: 6, y: 3)
                            }
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
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
            .frame(height: 170)
            .accessibilityLabel("近 6 个月专注分钟趋势")
            .accessibilityValue(points.map { "\($0.key) \(ReadingReportStore.displayMinutes(fromSeconds: $0.seconds)) 分钟" }.joined(separator: "，"))
        }
    }

    /// 年度 12 个月分布（柱状，当月高亮）
    private var yearMonthBarsCard: some View {
        let points = store.monthlyTrend(12)   // 旧在前，最后一个=当月
        let maxVal = max(4, points.map { ReadingReportStore.displayMinutes(fromSeconds: $0.seconds) }.max() ?? 0)
        return ReportCard(title: "月度分布", caption: "分钟 / 月") {
            Chart {
                ForEach(points) { p in
                    let minutes = ReadingReportStore.displayMinutes(fromSeconds: p.seconds)
                    let isCurrent = p.date == points.last?.date
                    BarMark(x: .value("月", p.date, unit: .month), y: .value("分钟", minutes))
                        .foregroundStyle(isCurrent
                            ? LinearGradient(colors: [Color.sjzAccent, Color.sjzAccent.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color.sjzTeal.opacity(0.8), Color.sjzTeal.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(6, style: .continuous)
                        .annotation(position: .top) {
                            if minutes > 0 {
                                Text("\(minutes)")
                                    .displayFont(10, weight: .medium)
                                    .foregroundStyle(isCurrent ? Color.sjzAccent : Color.sjzTeal)
                            }
                        }
                }
            }
            .chartXAxis {
                // 每 2 个月一个标签，避免 12 个月份标签拥挤重叠
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(DisplayFontFactory.font(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...(maxVal + 2))
            .frame(height: 160)
            .accessibilityLabel("本年度 12 个月专注分钟分布")
            .accessibilityValue(points.map { "\($0.key) \(ReadingReportStore.displayMinutes(fromSeconds: $0.seconds)) 分钟" }.joined(separator: "，"))
        }
    }

    // MARK: - 图表 ③：分类环形

    private func categoryRingCard(sources: [(source: String, seconds: Int)]) -> some View {
        let total = sources.reduce(0) { $0 + $1.seconds }
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
                                Text(compactDuration(total))
                                    .displayFont(24, weight: .bold)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .contentTransition(.numericText(value: Double(total)))
                                Text("总专注").displayFont(11).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 134, height: 134)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("分类分布，共 \(compactDuration(total))")
                        .accessibilityValue(sources.map { "\($0.source) \(compactDuration($0.seconds))" }.joined(separator: "，"))

                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { idx, item in
                                HStack(spacing: 9) {
                                    Circle().fill(paletteColor(idx)).frame(width: 8, height: 8)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                    Text(item.source).displayFont(13).lineLimit(1)
                                    Spacer()
                                    Text(compactDuration(item.seconds)).displayFont(13, weight: .medium).monospacedDigit()
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

    /// 秒 → 紧凑时长文案（与 Hero 大数字同口径，精确到秒）
    private func compactDuration(_ seconds: Int) -> String {
        if seconds <= 0 { return "0 秒" }
        if seconds < 60 { return "\(seconds) 秒" }
        let m = seconds / 60, r = seconds % 60
        return r > 0 ? "\(m) 分\(r) 秒" : "\(m) 分钟"
    }

    private func sectorStart(sources: [(source: String, seconds: Int)], upto: Int) -> Double {
        let total = max(1, sources.reduce(0) { $0 + $1.seconds })
        let acc = sources.prefix(upto).reduce(0) { $0 + $1.seconds }
        return Double(acc) / Double(total) * 360
    }

    private func paletteColor(_ index: Int) -> Color {
        let palette: [Color] = [.sjzAccent, .sjzTeal, .sjzGold, .sjzPurple, .sjzPink, .sjzSkyBlue]
        return palette[index % palette.count]
    }

    // MARK: - 图表 ④：时段热力

    private func hourlyHeatCard(title: String, hourly: [Int],
                                peak: (hour: Int, seconds: Int, day: Date)?, showsDay: Bool) -> some View {
        return ReportCard(title: title, caption: "") {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 12), spacing: 7) {
                    ForEach(0..<24, id: \.self) { hour in
                        let seconds = hourly[hour]
                        let minutes = ReadingReportStore.displayMinutes(fromSeconds: seconds)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(intensityColor(seconds: seconds, maxSec: max(1, hourly.max() ?? 0)))
                            .frame(height: 26)
                            .overlay(
                                Text("\(hour)")
                                    .displayFont(9, weight: minutes >= 10 ? .bold : .regular)
                                    .foregroundStyle(minutes >= 10 ? .white : .secondary))
                            .accessibilityLabel("\(hour) 点，专注 \(compactDuration(seconds))")
                    }
                }
                if let peak {
                    let timeText = showsDay ? "\(dayLabel(peak.day)) \(peak.hour) 点" : "\(peak.hour) 点"
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .displaySymbolFont(13, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: Color.sjzAccent.opacity(0.35), radius: 6, y: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("阅读高峰 · \(timeText)")
                                .displayFont(12, weight: .semibold)
                                .foregroundStyle(.primary)
                            Text("专注 \(compactDuration(peak.seconds))")
                                .displayFont(11, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.sjzAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.sjzAccent.opacity(0.18), lineWidth: 0.6))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("阅读高峰 \(timeText)，专注 \(compactDuration(peak.seconds))")
                }
            }
        }
    }

    /// 日期标签（中文，如「10月3日」），供周报跨天高峰消歧
    private func dayLabel(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    /// 月份标签（如「10月」），供月报趋势标注消歧
    private func monthLabel(_ date: Date) -> String {
        "\(Calendar.current.component(.month, from: date))月"
    }

    /// 热力强度：按真实秒数占比分级（93 秒与 9 秒不再同为满格）
    private func intensityColor(seconds: Int, maxSec: Int) -> Color {
        guard seconds > 0 else { return Color(.systemGray6).opacity(0.6) }
        let ratio = Double(seconds) / Double(maxSec)
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
                        colors: [Color.sjzCard.opacity(0.96), Color.sjzLight.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.8))
        }
        .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
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
