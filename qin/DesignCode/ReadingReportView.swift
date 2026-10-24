//
//  ReadingReportView.swift
//  「园枢」阅读时光 · 日报/周报（2026-10-03 新增）
//
//  设计：克制 + 顶级。三张图表（Swift Charts 面积趋势 / 自制环形 / 24h 时段热力），
//  全部 Apple 原生实现（零第三方依赖）；Hero 背景随本地时段渐变（晨曦/日间/黄昏/深空）；
//  数字滚动 + 轻触觉 + VoiceOver 全文朗读；全文 display* 排版链；数据仅存本机。

import SwiftUI
import Charts

// MARK: - 报告页

struct ReadingReportView: View {
    @ObservedObject private var store = ReadingReportStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: ReadingReportMode = .daily
    @State private var showClearConfirm = false

    enum ReadingReportMode: String, CaseIterable {
        case daily = "日报"
        case weekly = "周报"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroCard
                    modePicker
                    if mode == .daily { dailySection } else { weeklySection }
                    privacyCard
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color.sjzLight.opacity(0.5))
            .navigationTitle("阅读时光")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        store.setEnabled(!store.enabled)
                    } label: {
                        Label(store.enabled ? "已记录" : "已暂停",
                              systemImage: store.enabled ? "record.circle.fill" : "pause.circle.fill")
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
        }
    }

    // MARK: - Hero（时段渐变 + 今日专注 + 连击）

    /// 今日专注精确文案：<1 分显示「N 秒」；否则「X 分 Y 秒」（避免「读了 89 秒只显示 1 分钟」）
    private var todayDurationText: String {
        let s = store.todaySeconds
        if s <= 0 { return "0 秒" }
        if s < 60 { return "\(s) 秒" }
        let m = s / 60, r = s % 60
        return r > 0 ? "\(m) 分 \(r) 秒" : "\(m) 分钟"
    }

    private var heroCard: some View {
        let palette = ReadingReportPalette.forNow()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(palette.greeting).displayFont(13, weight: .medium).foregroundStyle(.white.opacity(0.8))
                    Text("今日专注").displayFont(17, weight: .semibold).foregroundStyle(.white)
                }
                Spacer()
                if store.currentStreak > 0 {
                    Label("连续 \(store.currentStreak) 天", systemImage: "flame.fill")
                        .displayLabelFont(13, weight: .semibold)
                        .foregroundStyle(palette.flame)
                        .accessibilityLabel("阅读连击，连续 \(store.currentStreak) 天")
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(todayDurationText)
                    .displayFont(56, weight: .bold)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(store.todaySeconds)))
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: store.todaySeconds)
                Text("· \(store.todayArticleCount) 篇")
                    .displayFont(15, weight: .medium)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("今日专注 \(todayDurationText)，阅读 \(store.todayArticleCount) 篇")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(colors: palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "book.closed.fill")
                .displaySymbolFont(60)
                .foregroundStyle(.white.opacity(0.14))
                .rotationEffect(.degrees(12))
                .padding(.trailing, 16).padding(.top, 8)
                .accessibilityHidden(true)
        }
        .shadow(color: palette.colors.first?.opacity(0.35) ?? .clear, radius: 18, y: 10)
    }

    // MARK: - 模式切换

    private var modePicker: some View {
        Picker("报告范围", selection: $mode) {
            ForEach(ReadingReportMode.allCases, id: \.self) { m in
                Text(m.rawValue).displayFont(15, weight: .semibold)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { _, _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .accessibilityLabel("报告范围")
    }

    // MARK: - 日报

    private var dailySection: some View {
        VStack(spacing: 14) {
            categoryRingCard(title: "今日分布", sources: store.categoryMinutes())
            hourlyHeatCard(title: "今日时段", hourly: store.hourlyMinutes(week: false))
        }
    }

    // MARK: - 周报

    private var weeklySection: some View {
        VStack(spacing: 14) {
            trendCard
            weekCompareCard
            categoryRingCard(title: "本周分布", sources: store.categoryMinutes())
            hourlyHeatCard(title: "本周时段", hourly: store.hourlyMinutes(week: true))
        }
    }

    // MARK: - 图表 ①：近 7 天时长趋势（Swift Charts 面积 + 渐变）

    private var trendCard: some View {
        let days = store.recentDays(7)
        let maxVal = max(4, days.map(\.minutes).max() ?? 0)
        return ReportCard(title: "近 7 天专注趋势", caption: "分钟 / 天") {
            Chart(days) { day in
                AreaMark(
                    x: .value("日期", day.date, unit: .day),
                    y: .value("分钟", day.minutes)
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.sjzAccent.opacity(0.50), Color.sjzAccent.opacity(0.02)],
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
                    Circle().fill(Color.sjzAccent.opacity(0.18)).frame(width: 14, height: 14)
                        .overlay(Circle().fill(.white).frame(width: 7, height: 7))
                        .overlay(Circle().stroke(Color.sjzAccent, lineWidth: 2).frame(width: 7, height: 7))
                }

                // 今日高亮点 + 数值标注
                if day.key == ReadingReportStore.key(for: Date(), calendar: .current) {
                    PointMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("分钟", day.minutes)
                    )
                    .symbol {
                        ZStack {
                            Circle().fill(Color.sjzAccent.opacity(0.25)).frame(width: 22, height: 22)
                            Circle().fill(Color.sjzAccent).frame(width: 11, height: 11)
                            Circle().fill(.white).frame(width: 4, height: 4)
                        }
                    }
                    .annotation(position: .top, spacing: 6) {
                        Text("\(day.minutes)′")
                            .displayFont(12, weight: .bold)
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
            .chartYScale(domain: 0...(maxVal + 1))
            .frame(height: 175)
            .accessibilityLabel("近 7 天每日专注分钟趋势")
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
                BarMark(
                    x: .value("周", "上周"),
                    y: .value("分钟", Double(last)),
                    width: 34
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.sjzTeal.opacity(0.85), Color.sjzTeal.opacity(0.45)],
                    startPoint: .top, endPoint: .bottom))
                .cornerRadius(9, style: .continuous)

                BarMark(
                    x: .value("周", "本周"),
                    y: .value("分钟", Double(this)),
                    width: 34
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.sjzAccent, Color.sjzAccent.opacity(0.5)],
                    startPoint: .top, endPoint: .bottom))
                .cornerRadius(9, style: .continuous)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(DisplayFontFactory.font(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...(top + 1))
            .frame(height: 92)
            .overlay(alignment: .trailing) {
                if let delta = store.weekChangePercent() {
                    Label(delta >= 0 ? "↑ \(delta)%" : "↓ \(-delta)%",
                          systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .displayLabelFont(14, weight: .semibold)
                        .foregroundStyle(delta >= 0 ? Color.sjzGreen : Color.sjzOrange)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel(delta >= 0 ? "较上周增长 \(delta)%" : "较上周下降 \(-delta)%")
                } else {
                    Text("上周无数据").displayFont(12).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("本周 \(this) 分钟，上周 \(last) 分钟")
        }
    }

    // MARK: - 图表 ③：分类环形（Apple 原生 Shape 实现，无第三方）

    private func categoryRingCard(title: String, sources: [(source: String, minutes: Int)]) -> some View {
        let total = sources.reduce(0) { $0 + $1.minutes }
        return ReportCard(title: title, caption: "分钟") {
            if total <= 0 {
                HStack {
                    Spacer()
                    Text("本周还没有阅读记录，去读一篇吧")
                        .displayFont(13).foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                VStack(spacing: 16) {
                    HStack {
                        ZStack {
                            // 底环（浅色，衬托扇区）
                            Circle().stroke(Color.sjzLight.opacity(0.55), lineWidth: 22)
                            // 扇区：圆角线帽 + 2° 间隔（高级环形视觉）
                            ForEach(Array(sources.enumerated()), id: \.offset) { idx, item in
                                RingSector(
                                    startAngle: sectorStart(sources: sources, upto: idx) + 2,
                                    endAngle: sectorStart(sources: sources, upto: idx + 1) - 2
                                )
                                .stroke(
                                    paletteColor(idx),
                                    style: StrokeStyle(lineWidth: 22, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: total)
                            }
                            VStack(spacing: 2) {
                                Text("\(total)").displayFont(24, weight: .bold).foregroundStyle(.primary)
                                    .contentTransition(.numericText(value: Double(total)))
                                Text("分钟").displayFont(12).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 132, height: 132)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("分类分布，共 \(total) 分钟")
                        .accessibilityValue(sources.map { "\($0.source) \($0.minutes) 分钟" }.joined(separator: "，"))

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(sources.prefix(5).enumerated()), id: \.offset) { idx, item in
                                HStack(spacing: 8) {
                                    Circle().fill(paletteColor(idx)).frame(width: 9, height: 9)
                                    Text(item.source).displayFont(13).lineLimit(1)
                                    Spacer()
                                    Text("\(item.minutes)′").displayFont(13, weight: .medium).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
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

    // MARK: - 图表 ④：24h 时段热力（克制版 GitHub 风格）

    private func hourlyHeatCard(title: String, hourly: [Int]) -> some View {
        let maxMin = max(1, hourly.max() ?? 0)
        let peakHour = hourly.firstIndex(of: hourly.max() ?? 0) ?? -1
        return ReportCard(title: title, caption: "按小时") {
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
                                    .foregroundStyle(minutes >= 10 ? .white : .secondary)
                            )
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
        if ratio >= 0.75 { return Color.sjzAccent }                        // 高
        if ratio >= 0.4 { return Color.sjzAccent.opacity(0.72) }           // 中
        if ratio >= 0.12 { return Color.sjzSkyBlue.opacity(0.5) }          // 低
        return Color.sjzSkyBlue.opacity(0.25)                              // 极低
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

// MARK: - 报告卡片容器（高光渐变 + 精致阴影）

private struct ReportCard<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).displayFont(16, weight: .semibold)
                Spacer()
                Text(caption).displayFont(12).foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.sjzCard.opacity(0.96), Color.sjzLight.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.6))
        }
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }
}

// MARK: - 环形扇区（原生 Shape）

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
    let flame: Color
    let greeting: String

    static func forNow(_ date: Date = Date()) -> ReadingReportPalette {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<9:
            return ReadingReportPalette(colors: [Color(hex: "F2994A"), Color(hex: "EF7E5B")], flame: .white, greeting: "晨读好时光")
        case 9..<17:
            return ReadingReportPalette(colors: [Color.sjzPrimary, Color(hex: "3E6FD8")], flame: Color.sjzGold, greeting: "日间专注中")
        case 17..<19:
            return ReadingReportPalette(colors: [Color(hex: "7B4B94"), Color(hex: "C05C7C")], flame: Color.sjzGold, greeting: "黄昏慢读")
        default:
            return ReadingReportPalette(colors: [Color(hex: "0D1424"), Color(hex: "1E2A52")], flame: Color.sjzOrange, greeting: "深空夜读")
        }
    }
}
