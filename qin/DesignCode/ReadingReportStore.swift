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

// MARK: - 按天预聚合（月报/年报数据源）

/// 每天一条紧凑聚合，**永久保留**，不受事件 2000 条裁剪影响——
/// 月报/年报必须从此聚合，保证一年历史不失真。
struct ReadingReportDayRollup: Codable, Equatable {
    var key: String                       // yyyy-MM-dd
    var totalSeconds: Int
    var articleCount: Int
    var categorySeconds: [String: Int]    // 分类 → 秒
    var hourlySeconds: [Int]              // 24 格，索引=小时

    static func empty(key: String) -> ReadingReportDayRollup {
        ReadingReportDayRollup(
            key: key, totalSeconds: 0, articleCount: 0,
            categorySeconds: [:], hourlySeconds: [Int](repeating: 0, count: 24))
    }
}

// MARK: - 月度/年度趋势点（月报/年报图表数据源）

struct ReadingReportMonthPoint: Identifiable, Equatable {
    var id: String { key }
    var key: String       // yyyy-MM
    var date: Date        // 当月 1 号
    var seconds: Int
    var articleCount: Int
}

// MARK: - Store（@MainActor 单例，遵循项目 Store 约定）

@MainActor
final class ReadingReportStore: ObservableObject {
    static let shared = ReadingReportStore()

    // 全新存储键（与 readingStats* 无任何交集）
    private static let enabledKey = "readingReportEnabled"
    private static let eventsKey = "readingReportEvents"
    private static let rollupsKey = "readingReportRollups"
    private static let maxEvents = 2000
    /// 按天预聚合防御性上限（约 10 年）；日常体量：一年约 65KB
    private static let maxRollupDays = 3650

    @Published private(set) var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var events: [ReadingReportEvent] = []
    @Published private(set) var rollups: [String: ReadingReportDayRollup] = [:]

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
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: Self.eventsKey),
           let decoded = try? JSONDecoder().decode([ReadingReportEvent].self, from: data) {
            events = decoded
            LogManager.shared.info("readingReport", "历史记录已加载", context: ["count": "\(decoded.count)"])
        } else {
            LogManager.shared.debugLog("readingReport", "无历史记录（首次或已清除）", context: [:])
        }
        if let rData = ud.data(forKey: Self.rollupsKey),
           let rDecoded = try? JSONDecoder().decode([String: ReadingReportDayRollup].self, from: rData) {
            rollups = rDecoded
            LogManager.shared.info("readingReport", "按天聚合已加载", context: ["days": "\(rDecoded.count)"])
        }
    }

    // MARK: - 写入（仅在阅读结算时低频调用；防抖批量写无需——单次事件粒度）

    func record(articleId: String, title: String, source: String, durationSeconds: Int) {
        guard enabled else { return }
        guard durationSeconds >= 5 else { return }   // <5s 不计（噪声过滤）
        let endedAt = Date()
        let event = ReadingReportEvent(
            articleId: articleId, title: title, source: source,
            endedAt: endedAt, durationSeconds: durationSeconds)
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)  // 先进先出裁剪（保最新）
        }
        save()
        // 同步维护按天预聚合（月报/年报数据源，永久保留）
        applyToRollup(endedAt: endedAt, source: source, durationSeconds: durationSeconds)
        saveRollups()
        LogManager.shared.debugLog("readingReport", "阅读记录已入账", context: [
            "source": source, "seconds": "\(durationSeconds)",
            "total": "\(events.count)"
        ])
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: Self.eventsKey)
    }

    private func saveRollups() {
        guard let data = try? JSONEncoder().encode(rollups) else { return }
        UserDefaults.standard.set(data, forKey: Self.rollupsKey)
    }

    /// 把一条事件并入当日预聚合（幂等：同一条事件只调用一次）
    private func applyToRollup(endedAt: Date, source: String, durationSeconds: Int) {
        let key = Self.key(for: endedAt, calendar: calendar)
        var r = rollups[key] ?? ReadingReportDayRollup.empty(key: key)
        r.totalSeconds += durationSeconds
        r.articleCount += 1
        r.categorySeconds[source, default: 0] += durationSeconds
        r.hourlySeconds[calendar.component(.hour, from: endedAt)] += durationSeconds
        rollups[key] = r
        if rollups.count > Self.maxRollupDays {
            for old in rollups.keys.sorted().prefix(rollups.count - Self.maxRollupDays) {
                rollups.removeValue(forKey: old)
            }
        }
    }

    /// 确保区间内每日预聚合存在：缺失的当天从现存事件惰性补建（老数据平滑收敛，只写缺失天）
    func ensureRollups(in interval: DateInterval) {
        var cursor = calendar.startOfDay(for: interval.start)
        let end = interval.end
        var changed = false
        while cursor < end {
            let key = Self.key(for: cursor, calendar: calendar)
            if rollups[key] == nil {
                let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
                let dayEvents = events.filter { $0.endedAt >= cursor && $0.endedAt < next }
                if !dayEvents.isEmpty {
                    var r = ReadingReportDayRollup.empty(key: key)
                    for e in dayEvents {
                        r.totalSeconds += e.durationSeconds
                        r.articleCount += 1
                        r.categorySeconds[e.source, default: 0] += e.durationSeconds
                        r.hourlySeconds[calendar.component(.hour, from: e.endedAt)] += e.durationSeconds
                    }
                    rollups[key] = r
                    changed = true
                }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        if changed { saveRollups() }
    }

    // MARK: - 隐私控制（仅影响本模块，不影响现有 readingStats*）

    func setEnabled(_ value: Bool) {
        enabled = value
        LogManager.shared.info("readingReport", "记录开关切换", context: ["enabled": "\(value)"])
    }

    func clearAll() {
        events = []
        rollups = [:]
        save()
        saveRollups()
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

    /// 本周专注秒（秒级精确，供 Hero 周进度与今日口径保持同源）
    var thisWeekSeconds: Int {
        guard let interval = weekInterval() else { return 0 }
        return events(in: interval).reduce(0) { $0 + $1.durationSeconds }
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

    /// 分类专注分布（环形图数据源，本周口径，秒级精确——与 Hero 大数字同步）
    func categoryMinutes() -> [(source: String, seconds: Int)] {
        let range: DateInterval? = weekInterval() ?? DateInterval(start: calendar.startOfDay(for: Date()), end: Date())
        guard let range else { return [] }
        var map: [String: Int] = [:]
        for e in events(in: range) {
            map[e.source, default: 0] += e.durationSeconds
        }
        return map.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// 分类专注分布（今日口径——日报环形数据源，秒级精确）
    func todayCategoryMinutes() -> [(source: String, seconds: Int)] {
        var map: [String: Int] = [:]
        for e in events(on: Date()) {
            map[e.source, default: 0] += e.durationSeconds
        }
        return map.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// 24 小时专注分布（日报=今日，周报=本周），秒级精确——热力强度与高峰判定基于真实秒数，
    /// 避免多个小时同为「1 分钟」取整时把高峰指错（如 6 点的 9 秒被当成高峰而漏掉 17 点的 93 秒）
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
        return hourly
    }

    /// 时段热力峰值详情（秒级）：返回峰值小时、总秒数，以及该小时内贡献最大的具体日期
    /// （周报跨天聚合时用于消歧，如「10-03 17 点」而非笼统的「17 点」）
    func hourlyPeak(week: Bool) -> (hour: Int, seconds: Int, day: Date)? {
        let hourly = hourlyMinutes(week: week)
        let maxRaw = hourly.max() ?? 0
        guard maxRaw > 0, let hour = hourly.firstIndex(of: maxRaw) else { return nil }
        let pool: [ReadingReportEvent]
        if week {
            guard let interval = weekInterval() else { return nil }
            pool = events(in: interval)
        } else {
            pool = events(on: Date())
        }
        var byDay: [Date: Int] = [:]
        for e in pool where calendar.component(.hour, from: e.endedAt) == hour {
            let day = calendar.startOfDay(for: e.endedAt)
            byDay[day, default: 0] += e.durationSeconds
        }
        guard let peakDay = byDay.max(by: { $0.value < $1.value })?.key else { return nil }
        return (hour, maxRaw, peakDay)
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

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - 月 / 年聚合（基于按天预聚合，永久保留）

    /// 自然月区间（当月 1 号 00:00 ~ 次月 1 号 00:00）
    func monthInterval(containing date: Date = Date()) -> DateInterval {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date.addingTimeInterval(31 * 86400)
        return DateInterval(start: start, end: end)
    }

    /// 自然年区间（1 月 1 号 00:00 ~ 次年 1 月 1 号 00:00）
    func yearInterval(containing date: Date = Date()) -> DateInterval {
        let start = calendar.date(from: calendar.dateComponents([.year], from: date)) ?? date
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? date.addingTimeInterval(366 * 86400)
        return DateInterval(start: start, end: end)
    }

    /// 区间聚合（秒 + 篇数），自动惰性补建缺失的按天预聚合
    private func aggregate(in interval: DateInterval) -> (seconds: Int, articleCount: Int) {
        ensureRollups(in: interval)
        var seconds = 0, count = 0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if let r = rollups[Self.key(for: cursor, calendar: calendar)] {
                seconds += r.totalSeconds
                count += r.articleCount
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        return (seconds, count)
    }

    var thisMonthSeconds: Int { aggregate(in: monthInterval()).seconds }
    var thisMonthArticleCount: Int { aggregate(in: monthInterval()).articleCount }
    var lastMonthSeconds: Int {
        let m = monthInterval()
        guard let s = calendar.date(byAdding: .month, value: -1, to: m.start),
              let e = calendar.date(byAdding: .month, value: -1, to: m.end) else { return 0 }
        return aggregate(in: DateInterval(start: s, end: e)).seconds
    }

    var thisYearSeconds: Int { aggregate(in: yearInterval()).seconds }
    var thisYearArticleCount: Int { aggregate(in: yearInterval()).articleCount }
    var lastYearSeconds: Int {
        let y = yearInterval()
        guard let s = calendar.date(byAdding: .year, value: -1, to: y.start),
              let e = calendar.date(byAdding: .year, value: -1, to: y.end) else { return 0 }
        return aggregate(in: DateInterval(start: s, end: e)).seconds
    }

    /// 月环比（%）：上月为 0 时返回 nil
    func monthChangePercent() -> Int? {
        let this = thisMonthSeconds, last = lastMonthSeconds
        guard last > 0 else { return nil }
        return Int((Double(this - last) / Double(last)) * 100)
    }

    /// 年同比（%）：上年为 0 时返回 nil
    func yearChangePercent() -> Int? {
        let this = thisYearSeconds, last = lastYearSeconds
        guard last > 0 else { return nil }
        return Int((Double(this - last) / Double(last)) * 100)
    }

    /// 近 n 个月趋势（含当月，旧在前）
    func monthlyTrend(_ n: Int, ending: Date = Date()) -> [ReadingReportMonthPoint] {
        let endStart = calendar.date(from: calendar.dateComponents([.year, .month], from: ending)) ?? ending
        return (0..<n).reversed().compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: endStart),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            let total = aggregate(in: DateInterval(start: monthStart, end: monthEnd))
            return ReadingReportMonthPoint(
                key: String(format: "%04d-%02d",
                            calendar.component(.year, from: monthStart),
                            calendar.component(.month, from: monthStart)),
                date: monthStart, seconds: total.seconds, articleCount: total.articleCount)
        }
    }

    /// 区间内分类分布（秒级，环形图数据源）
    func categorySeconds(in interval: DateInterval) -> [(source: String, seconds: Int)] {
        ensureRollups(in: interval)
        var map: [String: Int] = [:]
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if let r = rollups[Self.key(for: cursor, calendar: calendar)] {
                for (s, v) in r.categorySeconds { map[s, default: 0] += v }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        return map.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func monthCategory() -> [(source: String, seconds: Int)] { categorySeconds(in: monthInterval()) }
    func yearCategory() -> [(source: String, seconds: Int)] { categorySeconds(in: yearInterval()) }

    /// 月时段热力（24 格秒，由按天预聚合累加）
    func monthHourly() -> [Int] {
        let interval = monthInterval()
        ensureRollups(in: interval)
        var hourly = [Int](repeating: 0, count: 24)
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if let r = rollups[Self.key(for: cursor, calendar: calendar)] {
                for h in 0..<24 { hourly[h] += r.hourlySeconds[h] }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        return hourly
    }

    /// 月时段峰值（代表日期 = 该小时内贡献最大的某天）
    func monthHourlyPeak() -> (hour: Int, seconds: Int, day: Date)? {
        let interval = monthInterval()
        ensureRollups(in: interval)
        var hourly = [Int](repeating: 0, count: 24)
        var byHourDay: [Int: [String: Int]] = [:]
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            let key = Self.key(for: cursor, calendar: calendar)
            if let r = rollups[key] {
                for h in 0..<24 where r.hourlySeconds[h] > 0 {
                    hourly[h] += r.hourlySeconds[h]
                    byHourDay[h, default: [:]][key, default: 0] += r.hourlySeconds[h]
                }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        guard let maxSec = hourly.max(), maxSec > 0,
              let hour = hourly.firstIndex(of: maxSec),
              let dayKey = byHourDay[hour]?.max(by: { $0.value < $1.value })?.key,
              let day = Self.date(fromKey: dayKey, calendar: calendar) else { return nil }
        return (hour, maxSec, day)
    }

    /// 区间内最长连续有阅读天数
    func longestStreak(in interval: DateInterval) -> Int {
        ensureRollups(in: interval)
        var best = 0, run = 0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if (rollups[Self.key(for: cursor, calendar: calendar)]?.totalSeconds ?? 0) > 0 {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        return best
    }

    /// 区间内有阅读的天数
    func activeDays(in interval: DateInterval) -> Int {
        ensureRollups(in: interval)
        var count = 0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if (rollups[Self.key(for: cursor, calendar: calendar)]?.totalSeconds ?? 0) > 0 { count += 1 }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        return count
    }

    /// 区间日均（自然天数口径，含无阅读日）
    func avgDailySeconds(in interval: DateInterval) -> Int {
        let days = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
        guard days > 0 else { return 0 }
        return aggregate(in: interval).seconds / days
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
        // 后台超过 5 分钟：本次阅读结算（防止「挂机时长」计入），
        // 结算后立即重开计时——用户回前台继续阅读的时长不再丢失
        if let bg = backgroundedAt, Date().timeIntervalSince(bg) > 300 {
            settle()
            beginSegment()
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
