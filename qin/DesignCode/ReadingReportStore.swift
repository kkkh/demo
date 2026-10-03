//
//  ReadingReportStore.swift
//  「园枢」阅读时光 · 日报/周报（2026-10-03 新增）
//
//  ⚠️ 与现有「阅读统计」（DisplaySettingsManager.ReadingStats*，估算口径）100% 隔离：
//    - 独立存储键（readingReportEnabled / readingReportEvents，与 readingStats* 无关）
//    - 独立日志域（readingReport）
//    - 独立 UI 入口（「我的 → 阅读时光」，ReportingReportView）
//    - 语义差异：本模块记录「真实停留时长」（进入→离开、后台暂停、单次 <5s 不计），
//      与现有徽章的「估算阅读时长」（字数/速度推算）口径不同，二者平行运行互不覆盖。
//  - 可整体卸载：删除本文件 + 各详情视图的 .readingReportTrack 一行 + ProfileView 入口卡片。
//  - 合规：数据仅存本机（无任何上报）；提供独立开关与一键清除；时长小于 5 秒不采集。
//
//  日期边界一律用 Calendar / DateComponents（禁 86400 秒加减法），天然规避跨天/跨时区。

import SwiftUI
import Combine

// MARK: - 事件模型（真实阅读停留记录）

struct ReadingReportEvent: Codable, Equatable {
    var articleId: String
    var title: String
    var source: String        // 新闻/荣誉/教师/故事/活动/机构/党建/招生
    var endedAt: Date         // 本次阅读结算时间（离开/暂停/超后台阈值）
    var durationSeconds: Int  // 真实停留秒数（>=5 才入库）
}

// MARK: - 单日聚合（报告图表数据源）

struct ReadingReportDay: Identifiable, Equatable {
    var id: String { key }
    var key: String           // yyyy-MM-dd（本地时区）
    var date: Date            // startOfDay
    var minutes: Int
    var articleCount: Int
}

// MARK: - Store（@MainActor 单例，遵循项目 Store 约定）

@MainActor
final class ReadingReportStore: ObservableObject {
    static let shared = ReadingReportStore()

    // 全新存储键（与 readingStats* 无任何交集）
    private static let enabledKey = "readingReportEnabled"
    private static let eventsKey = "readingReportEvents"
    private static let maxEvents = 2000

    @Published private(set) var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var events: [ReadingReportEvent] = []

    private var loaded = false

    private init() {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.enabledKey) == nil {
            ud.set(true, forKey: Self.enabledKey)   // 默认开启（可关）
        }
        enabled = ud.bool(forKey: Self.enabledKey)
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.eventsKey),
              let decoded = try? JSONDecoder().decode([ReadingReportEvent].self, from: data) else {
            LogManager.shared.debugLog("readingReport", "无历史记录（首次或已清除）", context: [:])
            return
        }
        events = decoded
        LogManager.shared.info("readingReport", "历史记录已加载", context: ["count": "\(decoded.count)"])
    }

    // MARK: - 写入（仅在阅读结算时低频调用；防抖批量写无需——单次事件粒度）

    func record(articleId: String, title: String, source: String, durationSeconds: Int) {
        guard enabled else { return }
        guard durationSeconds >= 5 else { return }   // <5s 不计（噪声过滤）
        let event = ReadingReportEvent(
            articleId: articleId, title: title, source: source,
            endedAt: Date(), durationSeconds: durationSeconds)
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)  // 先进先出裁剪（保最新）
        }
        save()
        LogManager.shared.debugLog("readingReport", "阅读记录已入账", context: [
            "source": source, "seconds": "\(durationSeconds)",
            "total": "\(events.count)"
        ])
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: Self.eventsKey)
    }

    // MARK: - 隐私控制（仅影响本模块，不影响现有 readingStats*）

    func setEnabled(_ value: Bool) {
        enabled = value
        LogManager.shared.info("readingReport", "记录开关切换", context: ["enabled": "\(value)"])
    }

    func clearAll() {
        events = []
        save()
        LogManager.shared.info("readingReport", "全部阅读记录已清除", context: ["kept": "0"])
    }

    // MARK: - 聚合（全部用 Calendar，禁 86400 加减法）

    private var calendar: Calendar { .current }

    private func events(in interval: DateInterval) -> [ReadingReportEvent] {
        events.filter { interval.contains($0.endedAt) }
    }

    /// 指定日期当天的记录
    func events(on day: Date) -> [ReadingReportEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return events.filter { $0.endedAt >= start && $0.endedAt < end }
    }

    /// 今日专注分钟 + 篇数
    var todayMinutes: Int { minutes(on: Date()) }
    var todaySeconds: Int { events(on: Date()).reduce(0) { $0 + $1.durationSeconds } }
    var todayArticleCount: Int { events(on: Date()).count }

    /// 展示用分钟：任何正秒数至少计 1 分钟（避免「读了却显示 0 分钟」的体验断点）
    static func displayMinutes(fromSeconds seconds: Int) -> Int {
        seconds > 0 ? max(1, seconds / 60) : 0
    }

    func minutes(on day: Date) -> Int {
        Self.displayMinutes(fromSeconds: events(on: day).reduce(0) { $0 + $1.durationSeconds })
    }

    /// 近 n 天逐日聚合（含今天，昨天在前）
    func recentDays(_ n: Int, ending: Date = Date()) -> [ReadingReportDay] {
        let todayStart = calendar.startOfDay(for: ending)
        return (0..<n).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            let dayEvents = events(on: day)
            return ReadingReportDay(
                key: Self.key(for: day, calendar: calendar),
                date: day,
                minutes: Self.displayMinutes(fromSeconds: dayEvents.reduce(0) { $0 + $1.durationSeconds }),
                articleCount: dayEvents.count)
        }
    }

    /// 自然周区间（周一~周日，随系统历法 firstWeekday）
    func weekInterval(containing date: Date = Date()) -> DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: date)
    }

    /// 本周专注分钟
    var thisWeekMinutes: Int {
        guard let interval = weekInterval() else { return 0 }
        return Self.displayMinutes(fromSeconds: events(in: interval).reduce(0) { $0 + $1.durationSeconds })
    }

    /// 上周专注分钟（本周起始往前推 7 天）
    var lastWeekMinutes: Int {
        guard let interval = weekInterval(),
              let lastStart = calendar.date(byAdding: .day, value: -7, to: interval.start),
              let lastEnd = calendar.date(byAdding: .day, value: -7, to: interval.end) else { return 0 }
        return Self.displayMinutes(fromSeconds: events.filter { $0.endedAt >= lastStart && $0.endedAt < lastEnd }
            .reduce(0) { $0 + $1.durationSeconds })
    }

    /// 连续阅读天数（streak）：自今天（或昨天）向前，逐日存在 >=1 分钟记录
    var currentStreak: Int {
        let todayStart = calendar.startOfDay(for: Date())
        // 今天有记录则从今天起算；否则从昨天起算（今天还没读不打断连击）
        let anchor = minutes(on: todayStart) >= 1 ? 0 : 1
        var streak = 0
        var offset = anchor
        while let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) {
            if minutes(on: day) >= 1 { streak += 1; offset += 1 } else { break }
        }
        return streak
    }

    /// 分类分钟分布（环形图数据源）
    func categoryMinutes() -> [(source: String, minutes: Int)] {
        let range: DateInterval? = weekInterval() ?? DateInterval(start: calendar.startOfDay(for: Date()), end: Date())
        guard let range else { return [] }
        var map: [String: Int] = [:]
        for e in events(in: range) {
            map[e.source, default: 0] += e.durationSeconds
        }
        return map.map { ($0.key, Self.displayMinutes(fromSeconds: $0.value)) }.sorted { $0.minutes > $1.minutes }
    }

    /// 24 小时专注分布（日报=今日，周报=本周），热力格数据源
    func hourlyMinutes(week: Bool) -> [Int] {
        var hourly = [Int](repeating: 0, count: 24)
        var pool: [ReadingReportEvent]
        if week {
            guard let interval = weekInterval() else { return hourly }
            pool = events(in: interval)
        } else {
            pool = events(on: Date())
        }
        for e in pool {
            let hour = calendar.component(.hour, from: e.endedAt)
            hourly[hour] += e.durationSeconds
        }
        return hourly.map { Self.displayMinutes(fromSeconds: $0) }
    }

    /// 周对比变化率（%）：上周为 0 时返回 nil
    func weekChangePercent() -> Int? {
        let this = thisWeekMinutes, last = lastWeekMinutes
        guard last > 0 else { return nil }
        return Int((Double(this - last) / Double(last)) * 100)
    }

    static func key(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

// MARK: - 可插拔采集器（挂到任一详情视图一行即生效；与现有统计零交互）

struct ReadingReportTrack: ViewModifier {
    let articleId: String
    let title: String
    let source: String

    @Environment(\.scenePhase) private var scenePhase
    @State private var accumulated: TimeInterval = 0
    @State private var segmentStart: Date?
    @State private var backgroundedAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear { beginSegment() }
            .onDisappear { settle() }
            .onChange(of: articleId) { _, _ in
                // 同一视图实例就地换文（连续阅读/切换场景）：立即结算旧文并开启新计时，
                // 让「篇数」跟随当前文章即时 +1
                settle()
                beginSegment()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    resumeFromBackground()
                case .background:
                    pauseSegment()
                default:
                    // .inactive 是瞬时态（下拉通知中心/来电横幅/App 切换预览），
                    // 不暂停——避免「明明在读却少计时」的体验偏差
                    break
                }
            }
    }

    private func beginSegment() {
        guard segmentStart == nil else { return }
        segmentStart = Date()
    }

    private func pauseSegment() {
        guard let start = segmentStart else { return }
        accumulated += Date().timeIntervalSince(start)
        segmentStart = nil
        backgroundedAt = Date()
    }

    private func resumeFromBackground() {
        guard segmentStart == nil else { return }
        guard accumulated > 0 else { return }
        // 后台超过 5 分钟：本次阅读结算（防止「挂机时长」计入）
        if let bg = backgroundedAt, Date().timeIntervalSince(bg) > 300 {
            settle()
        } else {
            segmentStart = Date()
        }
    }

    private func settle() {
        defer {
            accumulated = 0
            segmentStart = nil
            backgroundedAt = nil
        }
        let finalSeconds = accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
        guard finalSeconds >= 5 else { return }
        ReadingReportStore.shared.record(
            articleId: articleId, title: title, source: source,
            durationSeconds: Int(finalSeconds))
    }
}

extension View {
    /// 阅读时光采集器：进入开始计时、切后台暂停（>5 分钟结算）、离开结算；<5s 不计。
    /// 一行挂载，与现有阅读统计零交互。
    func readingReportTrack(articleId: String, title: String, source: String) -> some View {
        modifier(ReadingReportTrack(articleId: articleId, title: title, source: source))
    }
}
