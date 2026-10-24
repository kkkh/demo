//
//  LogManager.swift
//  山西晋中理工学院 APP — 全功能日志系统
//
//  完全本地存储，隐私优先，不自动上传任何日志。
//  异步后台写入，绝对不阻塞主线程。
//  追加合并式落盘（新增条目按日合并进既有文件，杜绝历史「内存裁剪截断磁盘」缺陷）+
//  损坏条目逐条抢救 + 单日文件轮转 + 保留天数自动清理 + 崩溃同步落盘（本地日键一致）。
//  本模块自身全链路埋点：日志域 log（页面/筛选/搜索/导出/清空/删除/设置/存储统计/落盘）。
//

import Foundation
import SwiftUI
import os

// MARK: - 日志级别

enum LogLevel: String, Codable, CaseIterable {
    case info    = "INFO"
    case debug   = "DEBUG"
    case warning = "WARNING"
    case error   = "ERROR"
    case fatal   = "FATAL"

    var color: Color {
        switch self {
        case .info:    return Color.sjzAccent
        case .debug:   return .secondary
        case .warning: return Color.sjzOrange
        case .error:   return Color.sjzRed
        case .fatal:   return Color(lightHex: "8B0000", darkHex: "FF4444")
        }
    }

    var icon: String {
        switch self {
        case .info:    return "i.circle.fill"
        case .debug:   return "ladybug.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        case .fatal:   return "xmark.shield.fill"
        }
    }

    /// 中文显示名（筛选芯片 / 导出头 / 搜索均命中）
    var displayName: String {
        switch self {
        case .info:    return "信息"
        case .debug:   return "调试"
        case .warning: return "警告"
        case .error:   return "错误"
        case .fatal:   return "崩溃"
        }
    }

    /// 是否需要关注的级别（今日异常计数 / 状态提示）
    var isIssue: Bool {
        self == .warning || self == .error || self == .fatal
    }
}

// MARK: - 单条日志

struct LogEntry: Identifiable, Codable, Equatable {
    let id: String
    let timestamp: Date
    let level: LogLevel
    let module: String
    let message: String
    let context: [String: String]?

    init(level: LogLevel, module: String, message: String, context: [String: String]? = nil) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.level = level
        self.module = module
        self.message = message
        self.context = context
    }

    // MARK: 格式化器缓存（静态复用：列表数千行渲染不再逐行新建 DateFormatter）

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let monthDayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    /// 本地日历日键（与落盘文件命名 `log_<yyyy-MM-dd>.json` 一致）
    static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 毫秒级时间戳 HH:mm:ss.SSS
    var formattedTime: String {
        Self.timeFormatter.string(from: timestamp)
    }

    /// 完整日期时间
    var fullDateTime: String {
        Self.fullFormatter.string(from: timestamp)
    }

    /// 本地日历日键
    var dayKey: String {
        Self.dayKeyFormatter.string(from: timestamp)
    }

    /// 相对时间文案（刚刚 / N 分钟前 / N 小时前 / 昨天 HH:mm / MM-dd HH:mm）
    func relativeTime(now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(timestamp)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前" }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(timestamp) {
            return "昨天 \(Self.shortTimeFormatter.string(from: timestamp))"
        }
        return Self.monthDayFormatter.string(from: timestamp)
    }

    /// 列表展示用时间：今天 → HH:mm:ss.SSS；往日 → MM-dd HH:mm:ss（配合日期分组消除歧义）
    var displayTime: String {
        if Calendar.current.isDateInToday(timestamp) {
            return Self.timeFormatter.string(from: timestamp)
        }
        return Self.monthDayTimeFormatter.string(from: timestamp)
    }

    /// 上下文字段数（列表折叠态展示「N 个字段」）
    var contextFieldCount: Int { context?.count ?? 0 }

    /// 格式化单条日志（导出行 / 复制）
    var formattedLine: String {
        var line = "[\(formattedTime)] [\(level.rawValue)] [\(module)] \(message)"
        if let ctx = context, !ctx.isEmpty {
            let ctxStr = ctx.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            line += " | \(ctxStr)"
        }
        return line
    }

    /// 完整展示文本（详情卡复制 / 分享）
    var detailText: String {
        var lines = [
            "时间：\(fullDateTime)",
            "级别：\(level.rawValue)（\(level.displayName)）",
            "模块：\(module)",
            "内容：\(message)"
        ]
        if let ctx = context, !ctx.isEmpty {
            lines.append("上下文：")
            for (key, value) in ctx.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(key) = \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// JSON 对象（结构化导出）
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "timestamp": fullDateTime,
            "level": level.rawValue,
            "module": module,
            "message": message
        ]
        if let ctx = context, !ctx.isEmpty {
            object["context"] = ctx
        }
        return object
    }

    /// 单条 JSON 文本（复制 JSON / 结构化分享）
    func jsonText(pretty: Bool = true) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return formattedLine
        }
        return text
    }
}

// MARK: - 存储快照（磁盘维度）

struct LogStorageSnapshot {
    let files: Int
    let totalBytes: Int64
    /// 日键列表（最新在前）
    let dayKeys: [String]

    var oldestDay: String? { dayKeys.last }
    var newestDay: String? { dayKeys.first }

    /// 占用文案（KB / MB 自适应）
    var sizeText: String {
        let kb = Double(totalBytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024)
    }
}

// MARK: - 内存统计（条目维度）

struct LogStats {
    let total: Int
    let today: Int
    let issueToday: Int
    let counts: [LogLevel: Int]
    let oldest: Date?
    let newest: Date?

    func count(of level: LogLevel) -> Int { counts[level] ?? 0 }
}

// MARK: - 导出格式

enum LogExportFormat: String, CaseIterable, Identifiable {
    case text
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "文本（.txt）"
        case .json: return "结构化（.json）"
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .json: return "json"
        }
    }
}

// MARK: - 日志管理器

@MainActor
final class LogManager: ObservableObject {
    static let shared = LogManager()

    // MARK: 注入（测试隔离：独立 defaults / 目录 / 轮转参数）

    private let defaults: UserDefaults
    private let storageDir: URL
    private let maxEntriesPerFile: Int

    private enum SettingsKeys {
        static let debugEnabled = "logDebugEnabled"
        static let crashCapture = "logCrashCaptureEnabled"
        static let maxEntries = "logMaxEntries"
        static let retentionDays = "logRetentionDays"
    }

    // MARK: 持久化设置（键与旧版一致）

    // 注意：此处刻意不在声明处给默认值——Swift 中「声明处有初值的属性在 init 再赋值」会触发 didSet，
    // 导致每次启动误写设置并留下「设置变更」伪日志；统一在 init 末尾集中赋值（赋值不触发观察器）。

    /// DEBUG 级别写入开关（关闭后调试日志不再记录）
    @Published var debugEnabled: Bool {
        didSet {
            guard debugEnabled != oldValue else { return }
            defaults.set(debugEnabled, forKey: SettingsKeys.debugEnabled)
            log(level: .info, module: "log", message: "日志设置：DEBUG 写入开关变更", context: ["enabled": "\(debugEnabled)"])
        }
    }

    /// 崩溃自动捕获开关（即时生效：回调内按快照判定，无需重启）
    @Published var crashCaptureEnabled: Bool {
        didSet {
            guard crashCaptureEnabled != oldValue else { return }
            defaults.set(crashCaptureEnabled, forKey: SettingsKeys.crashCapture)
            Self.crashCaptureEnabledSnapshot = crashCaptureEnabled
            log(level: .info, module: "log", message: "日志设置：崩溃捕获开关变更", context: ["enabled": "\(crashCaptureEnabled)"])
        }
    }

    /// 内存日志容量上限（变更立即裁剪并留痕）
    @Published var maxEntries: Int {
        didSet {
            guard maxEntries != oldValue else { return }
            defaults.set(maxEntries, forKey: SettingsKeys.maxEntries)
            log(level: .info, module: "log", message: "日志设置：容量上限变更", context: ["from": "\(oldValue)", "to": "\(maxEntries)"])
            applyMaxEntriesLimit()
        }
    }

    /// 保留天数（变更立即清理过期日文件并留痕）
    @Published var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            defaults.set(retentionDays, forKey: SettingsKeys.retentionDays)
            log(level: .info, module: "log", message: "日志设置：保留天数变更", context: ["from": "\(oldValue)", "to": "\(retentionDays)"])
            applyRetention(reason: "设置变更")
        }
    }

    // MARK: 发布状态

    /// 内存中的日志列表（最近的在前面）
    @Published private(set) var entries: [LogEntry] = []

    // MARK: 私有

    private let ioQueue = DispatchQueue(label: "com.sxjzit.log.io", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?

    /// 待落盘缓冲（主线程写入；ioQueue 抽干）——线程安全盒
    private final class PendingBox: @unchecked Sendable {
        let lock = NSLock()
        var items: [LogEntry] = []
    }
    private let pendingBox = PendingBox()

    // MARK: 崩溃写入上下文（nonisolated 静态镜像：信号/异常回调线程直接可用）

    private struct CrashContext {
        let dir: URL
        let maxPerFile: Int
    }

    nonisolated(unsafe) private static var crashContext: CrashContext?

    nonisolated private static let crashFlagLock = NSLock()
    nonisolated(unsafe) private static var crashFlag = true

    /// 崩溃捕获开关的线程安全快照（异常/信号回调线程读取）
    nonisolated static var crashCaptureEnabledSnapshot: Bool {
        get {
            crashFlagLock.lock(); defer { crashFlagLock.unlock() }
            return crashFlag
        }
        set {
            crashFlagLock.lock(); defer { crashFlagLock.unlock() }
            crashFlag = newValue
        }
    }

    // MARK: 初始化

    init(defaults: UserDefaults = .standard,
         storageDirectory: URL? = nil,
         defaultRetentionDays: Int = 7,
         defaultMaxEntries: Int = 3000,
         maxEntriesPerFile: Int = 1000) {
        self.defaults = defaults
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storageDir = storageDirectory ?? docs.appendingPathComponent("SXJZIT_Cache/Logs", isDirectory: true)
        self.maxEntriesPerFile = maxEntriesPerFile
        try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)

        // 设置项读取（区分「从未设置」与「显式默认值」；init 中赋值不触发 didSet）
        debugEnabled = defaults.object(forKey: SettingsKeys.debugEnabled) != nil
            ? defaults.bool(forKey: SettingsKeys.debugEnabled) : true
        crashCaptureEnabled = defaults.object(forKey: SettingsKeys.crashCapture) != nil
            ? defaults.bool(forKey: SettingsKeys.crashCapture) : true
        maxEntries = defaults.object(forKey: SettingsKeys.maxEntries) != nil
            ? defaults.integer(forKey: SettingsKeys.maxEntries) : defaultMaxEntries
        retentionDays = defaults.object(forKey: SettingsKeys.retentionDays) != nil
            ? defaults.integer(forKey: SettingsKeys.retentionDays) : defaultRetentionDays

        Self.crashCaptureEnabledSnapshot = crashCaptureEnabled
        Self.crashContext = CrashContext(dir: self.storageDir, maxPerFile: maxEntriesPerFile)

        // 崩溃捕获始终安装处理器（写入门由线程安全快照控制）→ 开关运行中即时生效
        setupCrashCapture()

        loadFromDisk()
        applyRetention(reason: "启动")

        log(level: .info, module: "log", message: "日志管理器初始化", context: [
            "max": "\(maxEntries)",
            "retentionDays": "\(retentionDays)",
            "debug": "\(debugEnabled)",
            "crashCapture": "\(crashCaptureEnabled)"
        ])
    }

    // MARK: 公开 API：写入

    /// 记录日志（主线程安全，异步写入磁盘）
    func log(level: LogLevel, module: String, message: String, context: [String: String]? = nil) {
        // DEBUG 级别可被总开关关闭
        if level == .debug && !debugEnabled { return }

        let entry = LogEntry(level: level, module: module, message: message, context: context)

        // 在内存中追加（最新在前）
        entries.insert(entry, at: 0)

        // FIFO 淘汰：超出上限则移除最早
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        // 缓冲区累积 + 防抖落盘（0.5s 合并写入；追加合并不截断磁盘既有条目）
        pendingBox.lock.lock()
        pendingBox.items.append(entry)
        pendingBox.lock.unlock()
        scheduleFlush()
    }

    /// 便捷方法
    func info(_ module: String, _ message: String, context: [String: String]? = nil) {
        log(level: .info, module: module, message: message, context: context)
    }
    func debugLog(_ module: String, _ message: String, context: [String: String]? = nil) {
        log(level: .debug, module: module, message: message, context: context)
    }
    func warning(_ module: String, _ message: String, context: [String: String]? = nil) {
        log(level: .warning, module: module, message: message, context: context)
    }
    func error(_ module: String, _ message: String, context: [String: String]? = nil) {
        log(level: .error, module: module, message: message, context: context)
    }
    func fatal(_ module: String, _ message: String, context: [String: String]? = nil) {
        log(level: .fatal, module: module, message: message, context: context)
    }

    /// 立即同步落盘待写条目（App 退后台 / 诊断面板 / 单元测试保障用）
    /// 走 ioQueue 同步执行：与删除/清理任务严格串行，杜绝「先删后写」竞态导致已清日志复活
    @discardableResult
    func flushPendingNow() -> Int {
        var failures = 0
        ioQueue.sync {
            failures = Self.flush(box: pendingBox,
                                  dir: storageDir,
                                  maxPerFile: maxEntriesPerFile)
        }
        if failures > 0 {
            log(level: .warning, module: "log", message: "日志落盘部分失败", context: ["failedFiles": "\(failures)"])
        }
        return failures
    }

    // MARK: 公开 API：查询 / 筛选

    /// 搜索日志（空格分隔多关键词 AND；命中内容/模块/级别名/时间/上下文字段）
    func search(query: String, in entries: [LogEntry]) -> [LogEntry] {
        let keywords = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return entries }
        return entries.filter { entry in
            var haystack = entry.message + " " + entry.module + " " + entry.level.rawValue + " " + entry.level.displayName
                + " " + entry.formattedTime + " " + entry.fullDateTime
            if let ctx = entry.context {
                haystack += " " + ctx.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            }
            let lower = haystack.lowercased()
            return keywords.allSatisfy { lower.contains($0) }
        }
    }

    /// 组合筛选（级别 × 模块 × 关键词；视图与导出共用，纯函数）
    func filtered(level: LogLevel?, module: String?, query: String) -> [LogEntry] {
        var result = entries
        if let level {
            result = result.filter { $0.level == level }
        }
        if let module, !module.isEmpty {
            result = result.filter { $0.module == module }
        }
        return search(query: query, in: result)
    }

    /// 模块聚合（筛选菜单数据源；按出现次数降序）
    func moduleFacets() -> [(module: String, count: Int)] {
        Dictionary(grouping: entries, by: \.module)
            .map { (module: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.module < $1.module) }
    }

    /// 内存统计（总数 / 今日 / 今日异常 / 各级计数 / 最早最新）
    func stats() -> LogStats {
        let calendar = Calendar.current
        var counts: [LogLevel: Int] = [:]
        var today = 0
        var issueToday = 0
        for entry in entries {
            counts[entry.level, default: 0] += 1
            if calendar.isDateInToday(entry.timestamp) {
                today += 1
                if entry.level.isIssue { issueToday += 1 }
            }
        }
        return LogStats(total: entries.count,
                        today: today,
                        issueToday: issueToday,
                        counts: counts,
                        oldest: entries.last?.timestamp,
                        newest: entries.first?.timestamp)
    }

    /// 磁盘存储快照（文件数 / 占用字节 / 日键清单；目录扫描在后台线程）
    func storageSnapshot() async -> LogStorageSnapshot {
        let dir = storageDir
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return LogStorageSnapshot(files: 0, totalBytes: 0, dayKeys: [])
            }
            var bytes: Int64 = 0
            var keys: [String] = []
            for file in files where file.lastPathComponent.hasPrefix("log_") && file.pathExtension == "json" {
                if let attrs = try? fm.attributesOfItem(atPath: file.path) {
                    bytes += (attrs[.size] as? Int64) ?? 0
                }
                keys.append(file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "log_", with: ""))
            }
            keys.sort(by: >)
            return LogStorageSnapshot(files: keys.count, totalBytes: bytes, dayKeys: keys)
        }.value
    }

    // MARK: 公开 API：删除

    /// 删除单条日志（内存 + 磁盘同步剔除）
    @discardableResult
    func removeEntry(id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let removed = entries.remove(at: index)
        purgeFromDisk([removed.dayKey: [removed.id]])
        log(level: .info, module: "log", message: "删除单条日志", context: [
            "targetLevel": removed.level.rawValue,
            "targetModule": removed.module,
            "target": String(removed.message.prefix(60))
        ])
        return true
    }

    /// 条件删除（级别 / 模块 / 关键词 / 日键 组合，供「清空当前筛选」「清空今日」）
    @discardableResult
    func removeEntries(level: LogLevel? = nil, module: String? = nil, query: String = "", dayKey: String? = nil) -> Int {
        var targets = filtered(level: level, module: module, query: query)
        if let dayKey {
            targets = targets.filter { $0.dayKey == dayKey }
        }
        guard !targets.isEmpty else { return 0 }
        let ids = Set(targets.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        purgeFromDisk(Dictionary(grouping: targets, by: \.dayKey).mapValues { Set($0.map(\.id)) })
        log(level: .info, module: "log", message: "清空日志（按条件）", context: [
            "removed": "\(targets.count)",
            "level": level?.rawValue ?? "全部",
            "module": module ?? "全部",
            "query": query,
            "dayKey": dayKey ?? "-"
        ])
        return targets.count
    }

    /// 清空全部日志（内存 + 全部日文件；随后自身留一条痕迹日志）
    func clearAll() {
        let cleared = entries.count
        entries.removeAll()
        pendingBox.lock.lock()
        pendingBox.items.removeAll()
        pendingBox.lock.unlock()
        let dir = storageDir
        ioQueue.async {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("log_") && file.pathExtension == "json" {
                    try? fm.removeItem(at: file)
                }
            }
        }
        log(level: .info, module: "log", message: "清空全部日志", context: ["cleared": "\(cleared)"])
    }

    // MARK: 公开 API：导出

    /// 导出全部日志为文本（兼容旧入口）
    func exportAsText() -> String {
        exportText(entries: entries, title: "全部日志")
    }

    /// 文本导出（带元信息头）
    func exportText(entries: [LogEntry], title: String) -> String {
        let header = """
        ===========================================
        山西晋中理工学院 APP — 应用日志（\(title)）
        导出时间：\(Date().formatted(.dateTime.year().month().day().hour().minute().second()))
        日志总数：\(entries.count) 条
        最早：\(entries.last?.fullDateTime ?? "-")
        最新：\(entries.first?.fullDateTime ?? "-")
        ===========================================

        """
        return header + entries.map { $0.formattedLine }.joined(separator: "\n")
    }

    /// 结构化 JSON 导出（可被解析脚本直接消费）
    func exportJSON(entries: [LogEntry], title: String) -> String {
        let payload: [String: Any] = [
            "app": "山西晋中理工学院 APP",
            "scope": title,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "count": entries.count,
            "entries": entries.map { $0.jsonObject }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 按格式导出
    func export(entries: [LogEntry], title: String, format: LogExportFormat) -> String {
        switch format {
        case .text: return exportText(entries: entries, title: title)
        case .json: return exportJSON(entries: entries, title: title)
        }
    }

    /// 导出文件名（含筛选标签与时间戳）
    func exportFileName(tag: String, format: LogExportFormat) -> String {
        let sanitized = tag
            .replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "_-")))
            .joined()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let tagPart = sanitized.isEmpty ? "all" : sanitized
        return "sxjzit_logs_\(tagPart)_\(stamp).\(format.fileExtension)"
    }

    // MARK: 公开 API：设置联动

    /// 立即按上限裁剪内存（设置变更 / 诊断面板调用）
    func applyMaxEntriesLimit() {
        guard entries.count > maxEntries else { return }
        let removed = entries.count - maxEntries
        entries = Array(entries.prefix(maxEntries))
        log(level: .warning, module: "log", message: "日志超上限已裁剪", context: [
            "removed": "\(removed)", "max": "\(maxEntries)"
        ])
    }

    /// 应用保留天数：清理过期日文件（后台执行 + 完成留痕）
    func applyRetention(reason: String) {
        let days = retentionDays
        let dir = storageDir
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            let calendar = Calendar.current
            guard days > 0,
                  let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date())) else { return }
            var removed = 0
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("log_") && file.pathExtension == "json" {
                    let key = file.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "log_", with: "")
                    if let date = LogEntry.dayKeyFormatter.date(from: key), date < cutoff {
                        try? fm.removeItem(at: file)
                        removed += 1
                    }
                }
            }
            let removedCount = removed
            Task { @MainActor [weak self] in
                guard let self, removedCount > 0 else { return }
                self.log(level: .info, module: "log", message: "过期日志已清理", context: [
                    "removedFiles": "\(removedCount)", "retentionDays": "\(days)", "reason": reason
                ])
            }
        }
    }

    // MARK: 落盘（追加合并）

    private func scheduleFlush() {
        saveWorkItem?.cancel()
        let box = pendingBox
        let dir = storageDir
        let cap = maxEntriesPerFile
        let work = DispatchWorkItem { [weak self] in
            let failures = LogManager.flush(box: box, dir: dir, maxPerFile: cap)
            if failures > 0 {
                Task { @MainActor [weak self] in
                    self?.log(level: .warning, module: "log", message: "日志落盘部分失败", context: [
                        "failedFiles": "\(failures)"
                    ])
                }
            }
        }
        saveWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 抽干缓冲并合并写入（返回失败文件数）
    nonisolated private static func flush(box: PendingBox, dir: URL, maxPerFile: Int) -> Int {
        box.lock.lock()
        let batch = box.items
        box.items.removeAll()
        box.lock.unlock()
        guard !batch.isEmpty else { return 0 }
        return mergeWrite(batch, dir: dir, maxPerFile: maxPerFile)
    }

    /// 追加合并写入：读既有日文件 → 去重并入新条目 → 按时间倒序 → 截断单文件上限 → 原子写。
    /// 内存 FIFO 不影响磁盘既有条目（修复历史「重写截断」缺陷）；仅写有新条目的日文件（消除全量重写放大）。
    nonisolated private static func mergeWrite(_ batch: [LogEntry], dir: URL, maxPerFile: Int) -> Int {
        var failures = 0
        let grouped = Dictionary(grouping: batch, by: \.dayKey)
        for (dayKey, newEntries) in grouped {
            let fileURL = dir.appendingPathComponent("log_\(dayKey).json")
            var existing: [LogEntry] = []
            if let data = try? Data(contentsOf: fileURL) {
                existing = decodeEntries(from: data).entries ?? []
            }
            let existingIDs = Set(existing.map(\.id))
            var merged = newEntries.filter { !existingIDs.contains($0.id) }
            merged.append(contentsOf: existing)
            merged.sort { $0.timestamp > $1.timestamp }
            let capped = Array(merged.prefix(maxPerFile))
            do {
                let data = try JSONEncoder().encode(capped)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// 从磁盘剔除指定条目（单条删除 / 条件清空；按日文件重写）
    private func purgeFromDisk(_ grouped: [String: Set<String>]) {
        guard !grouped.isEmpty else { return }
        let dir = storageDir
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            var rewritten = 0
            for (dayKey, ids) in grouped {
                let fileURL = dir.appendingPathComponent("log_\(dayKey).json")
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                let remaining = (LogManager.decodeEntries(from: data).entries ?? []).filter { !ids.contains($0.id) }
                if remaining.isEmpty {
                    try? fm.removeItem(at: fileURL)
                } else if let out = try? JSONEncoder().encode(remaining) {
                    try? out.write(to: fileURL, options: .atomic)
                }
                rewritten += 1
            }
            let files = rewritten
            Task { @MainActor [weak self] in
                self?.log(level: .debug, module: "log", message: "磁盘条目剔除完成", context: [
                    "files": "\(files)", "ids": "\(grouped.values.reduce(0) { $0 + $1.count })"
                ])
            }
        }
    }

    // MARK: 加载（逐条抢救）

    private func loadFromDisk() {
        let max = maxEntries
        let dir = storageDir
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                Task { @MainActor [weak self] in
                    self?.log(level: .warning, module: "log", message: "日志目录读取失败，按空日志启动", context: [:])
                }
                return
            }

            var allEntries: [LogEntry] = []
            var rescued = 0
            var fileCount = 0
            var corruptedFiles = 0
            for file in files where file.lastPathComponent.hasPrefix("log_") && file.pathExtension == "json" {
                fileCount += 1
                guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
                let decoded = LogManager.decodeEntries(from: data)
                if decoded.entries == nil { corruptedFiles += 1 }
                allEntries.append(contentsOf: decoded.entries ?? [])
                rescued += decoded.rescued
            }

            // 按时间倒序排列，限制数量
            allEntries.sort { $0.timestamp > $1.timestamp }
            let capped = Array(allEntries.prefix(max))
            let totalOnDisk = allEntries.count
            let rescuedCount = rescued
            let fileTotal = fileCount
            let corrupted = corruptedFiles

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.entries = capped
                if rescuedCount > 0 || corrupted > 0 {
                    self.log(level: .warning, module: "log", message: "日志加载完成（含损坏条目抢救）", context: [
                        "files": "\(fileTotal)", "loaded": "\(capped.count)",
                        "totalOnDisk": "\(totalOnDisk)", "rescued": "\(rescuedCount)",
                        "corruptedFiles": "\(corrupted)"
                    ])
                } else {
                    self.log(level: .info, module: "log", message: "日志加载完成", context: [
                        "files": "\(fileTotal)", "loaded": "\(capped.count)",
                        "totalOnDisk": "\(totalOnDisk)"
                    ])
                }
            }
        }
    }

    /// 解析日志数组：整段优先；失败时逐条抢救（保留合法条目、跳过损坏条目）
    /// - Returns: entries 为 nil 表示整体不可解析；rescued 为抢救时跳过的损坏条数
    nonisolated static func decodeEntries(from data: Data) -> (entries: [LogEntry]?, rescued: Int) {
        let decoder = JSONDecoder()
        if let entries = try? decoder.decode([LogEntry].self, from: data) {
            return (entries, 0)
        }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return (nil, 0)
        }
        var entries: [LogEntry] = []
        var rescued = 0
        for element in raw {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let entry = try? decoder.decode(LogEntry.self, from: elementData) else {
                rescued += 1
                continue
            }
            entries.append(entry)
        }
        return (entries, rescued)
    }

    // MARK: 崩溃捕获（同步落盘 · 本地日键 · 开关即时生效）

    private func setupCrashCapture() {
        // 捕获未处理的 Objective-C 异常（NSSetUncaughtExceptionHandler）
        NSSetUncaughtExceptionHandler { exception in
            guard LogManager.crashCaptureEnabledSnapshot else { return }
            let message = "\(exception.name.rawValue): \(exception.reason ?? "未知原因")"
            let stack = exception.callStackSymbols.prefix(10).joined(separator: "\n")
            LogManager.crashWrite(LogEntry(
                level: .fatal,
                module: "crashCapture",
                message: message,
                context: ["type": "NSException", "stack": stack]
            ))
        }

        // 捕获信号（SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP）
        signal(SIGABRT) { _ in LogManager.handleCrashSignal("SIGABRT") }
        signal(SIGILL)  { _ in LogManager.handleCrashSignal("SIGILL") }
        signal(SIGSEGV) { _ in LogManager.handleCrashSignal("SIGSEGV") }
        signal(SIGFPE)  { _ in LogManager.handleCrashSignal("SIGFPE") }
        signal(SIGBUS)  { _ in LogManager.handleCrashSignal("SIGBUS") }
        signal(SIGTRAP) { _ in LogManager.handleCrashSignal("SIGTRAP") }
    }

    /// 信号回调入口（nonisolated：可在任意线程直接调用）
    nonisolated static func handleCrashSignal(_ signalName: String) {
        guard crashCaptureEnabledSnapshot else { return }
        crashWrite(LogEntry(
            level: .fatal,
            module: "crashCapture",
            message: "收到信号 \(signalName)，App 即将终止",
            context: ["signal": signalName]
        ))
    }

    /// 同步写入崩溃日志（不依赖主线程、不依赖异步队列；日键与常规落盘一致，可直接被加载）
    nonisolated static func crashWrite(_ entry: LogEntry) {
        guard let context = crashContext else { return }
        let fileName = "log_\(entry.dayKey).json"
        let fileURL = context.dir.appendingPathComponent(fileName)

        var existing: [LogEntry] = []
        if let data = try? Data(contentsOf: fileURL) {
            existing = decodeEntries(from: data).entries ?? []
        }
        guard !existing.contains(where: { $0.id == entry.id }) else { return }
        var merged = [entry]
        merged.append(contentsOf: existing)
        merged.sort { $0.timestamp > $1.timestamp }
        let capped = Array(merged.prefix(context.maxPerFile))
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}