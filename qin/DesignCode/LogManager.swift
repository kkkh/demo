//
//  LogManager.swift
//  山西晋中理工学院 APP — 全功能日志系统
//
//  完全本地存储，隐私优先，不自动上传任何日志。
//  异步后台写入，绝对不阻塞主线程。
//  FIFO 淘汰 + 文件轮转 + 7 天自动清理。
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

    /// 毫秒级时间戳 HH:mm:ss.SSS
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    /// 完整日期时间
    var fullDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    /// 格式化单条日志
    var formattedLine: String {
        var line = "[\(formattedTime)] [\(level.rawValue)] [\(module)] \(message)"
        if let ctx = context, !ctx.isEmpty {
            let ctxStr = ctx.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            line += " | \(ctxStr)"
        }
        return line
    }
}

// MARK: - 日志管理器

@MainActor
final class LogManager: ObservableObject {
    static let shared = LogManager()

    // MARK: 持久化设置（禁止 @AppStorage + didSet，用 onChange 在视图层处理）

    @AppStorage("logDebugEnabled") var debugEnabled: Bool = true
    @AppStorage("logCrashCaptureEnabled") var crashCaptureEnabled: Bool = true
    @AppStorage("logMaxEntries") var maxEntries: Int = 3000

    // MARK: 发布状态

    /// 内存中的日志列表（最近的在前面）
    @Published private(set) var entries: [LogEntry] = []

    // MARK: 私有

    private let ioQueue = DispatchQueue(label: "com.sxjzit.log.io", qos: .utility)
    private let logsDir: URL
    private let maxEntriesPerFile = 1000
    private let retentionDays = 7
    private var savePending = false
    private var saveWorkItem: DispatchWorkItem?

    // MARK: 初始化

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logsDir = docs.appendingPathComponent("SXJZIT_Cache/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // 从磁盘加载历史日志
        loadFromDisk()

        // 清理过期日志
        performAutoCleanup()

        // 注册崩溃捕获
        if crashCaptureEnabled {
            setupCrashCapture()
        }
    }

    // MARK: 公开 API

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

        // 异步去重写入磁盘（防抖：0.5s 内合并写入）
        scheduleSave()
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

    /// 搜索日志
    func search(query: String, in entries: [LogEntry]) -> [LogEntry] {
        guard !query.isEmpty else { return entries }
        let lower = query.lowercased()
        return entries.filter { entry in
            entry.message.lowercased().contains(lower) ||
            entry.module.lowercased().contains(lower) ||
            (entry.context?.values.joined().lowercased().contains(lower) ?? false)
        }
    }

    /// 清空全部日志
    func clearAll() {
        entries.removeAll()
        // 立即写入空数组到磁盘
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.writeToDisk([])
        }
    }

    /// 导出全部日志为文本
    func exportAsText() -> String {
        let header = """
        ===========================================
        山西晋中理工学院 APP — 应用日志
        导出时间：\(Date().formatted(.dateTime.year().month().day().hour().minute().second()))
        日志总数：\(entries.count) 条
        ===========================================

        """
        return header + entries.map { $0.formattedLine }.joined(separator: "\n")
    }

    // MARK: 持久化

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let snapshot = self.entries
            self.writeToDisk(snapshot)
        }
        saveWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    nonisolated private func writeToDisk(_ snapshot: [LogEntry]) {
        // 文件轮转：按日期分文件，每个文件最多 maxEntriesPerFile 条
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: snapshot) { entry -> String in
            let comps = calendar.dateComponents([.year, .month, .day], from: entry.timestamp)
            return "\(comps.year!)-\(String(format: "%02d", comps.month!))-\(String(format: "%02d", comps.day!))"
        }

        for (dateKey, dayEntries) in grouped {
            let fileName = "log_\(dateKey).json"
            let fileURL = logsDir.appendingPathComponent(fileName)
            let capped = Array(dayEntries.prefix(maxEntriesPerFile))
            if let data = try? JSONEncoder().encode(capped) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        // 删除空日志文件对应的日期文件
        cleanEmptyFiles(activeDates: Set(grouped.keys))
    }

    private func loadFromDisk() {
        let max = self.maxEntries
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: self.logsDir, includingPropertiesForKeys: nil) else {
                return
            }

            var allEntries: [LogEntry] = []
            for file in files where file.lastPathComponent.hasPrefix("log_") && file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let dayEntries = try? JSONDecoder().decode([LogEntry].self, from: data) {
                    allEntries.append(contentsOf: dayEntries)
                }
            }

            // 按时间倒序排列，限制数量
            allEntries.sort { $0.timestamp > $1.timestamp }
            let capped = Array(allEntries.prefix(max))

            Task { @MainActor [weak self] in
                self?.entries = capped
            }
        }
    }

    nonisolated private func cleanEmptyFiles(activeDates: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("log_") && file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "log_", with: "")
            if !activeDates.contains(name) {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: 自动清理

    private func performAutoCleanup() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: self.logsDir, includingPropertiesForKeys: [.creationDateKey]) else {
                return
            }
            let cutoff = Date().addingTimeInterval(-TimeInterval(self.retentionDays * 86400))
            for file in files where file.lastPathComponent.hasPrefix("log_") {
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let creationDate = attrs[.creationDate] as? Date,
                   creationDate < cutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: 崩溃捕获

    private func setupCrashCapture() {
        // 捕获未处理的 Swift 异常（NSSetUncaughtExceptionHandler）
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "未知原因"
            let stack = exception.callStackSymbols.prefix(10).joined(separator: "\n")
            let message = "\(name): \(reason)"

            // 崩溃信息直接同步写入磁盘（此时 App 即将终止，不能用异步）
            let entry = LogEntry(
                level: .fatal,
                module: "crashCapture",
                message: message,
                context: ["stack": stack]
            )
            LogManager.shared.crashWrite(entry)
        }

        // 捕获信号（SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP）
        signal(SIGABRT) { _ in LogManager.shared.crashSignalHandler("SIGABRT") }
        signal(SIGILL)  { _ in LogManager.shared.crashSignalHandler("SIGILL") }
        signal(SIGSEGV) { _ in LogManager.shared.crashSignalHandler("SIGSEGV") }
        signal(SIGFPE)  { _ in LogManager.shared.crashSignalHandler("SIGFPE") }
        signal(SIGBUS)  { _ in LogManager.shared.crashSignalHandler("SIGBUS") }
        signal(SIGTRAP) { _ in LogManager.shared.crashSignalHandler("SIGTRAP") }
    }

    private func crashSignalHandler(_ signalName: String) {
        let entry = LogEntry(
            level: .fatal,
            module: "crashCapture",
            message: "收到信号 \(signalName)，App 即将终止",
            context: ["signal": signalName]
        )
        crashWrite(entry)
    }

    /// 同步写入崩溃日志（不依赖主线程、不依赖异步队列）
    private func crashWrite(_ entry: LogEntry) {
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let fileName = "log_\(dateStr).json"
        let fileURL = logsDir.appendingPathComponent(fileName)

        var existing: [LogEntry] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) {
            existing = decoded
        }
        existing.insert(entry, at: 0)
        if let data = try? JSONEncoder().encode(existing) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}