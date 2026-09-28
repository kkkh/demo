//
//  LogManagerTests.swift
//  山西晋中理工学院 APP — 日志系统单元测试
//
//  覆盖：写入顺序与级别门控、FIFO 上限、多关键词搜索、组合筛选、模块聚合、
//  内存统计、单条/条件删除（内存 + 磁盘同步）、清空、
//  追加合并落盘保真（修复「内存裁剪截断磁盘」）、逐条抢救、崩溃日志本地日键、
//  崩溃开关快照、导出（TXT/JSON/筛选）、保留天数清理、存储快照、文件名清洗。
//
//  全部用例注入临时目录 + 独立 UserDefaults suite，互不污染。
//

import XCTest
@testable import DesignCode

@MainActor
final class LogManagerTests: XCTestCase {

    private var tempDir: URL!
    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LogTests.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)!
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        suiteDefaults.removePersistentDomain(forName: suiteName)
        // 恢复全局崩溃捕获快照，避免影响其他用例
        LogManager.crashCaptureEnabledSnapshot = true
        super.tearDown()
    }

    // MARK: 工厂与工具

    private func makeManager(maxEntries: Int = 3000,
                             retentionDays: Int = 7,
                             maxEntriesPerFile: Int = 1000) -> LogManager {
        LogManager(defaults: suiteDefaults,
                   storageDirectory: tempDir,
                   defaultRetentionDays: retentionDays,
                   defaultMaxEntries: maxEntries,
                   maxEntriesPerFile: maxEntriesPerFile)
    }

    private var todayFileURL: URL {
        tempDir.appendingPathComponent("log_\(LogEntry.dayKeyFormatter.string(from: Date())).json")
    }

    private func readDiskEntries() -> [LogEntry] {
        guard let data = try? Data(contentsOf: todayFileURL) else { return [] }
        return LogManager.decodeEntries(from: data).entries ?? []
    }

    /// 轮询等待条件成立（异步加载 / 后台清理用）
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    private func messages(from entries: [LogEntry]) -> [String] {
        entries.map(\.message)
    }

    // MARK: 写入与门控

    func testLogInsertsNewestFirst() {
        let manager = makeManager()
        manager.info("test", "第一条")
        manager.info("test", "第二条")
        manager.info("test", "第三条")
        XCTAssertEqual(manager.entries.first?.message, "第三条")
        XCTAssertEqual(manager.entries.prefix(3).map(\.message), ["第三条", "第二条", "第一条"])
    }

    func testDebugGateBlocksDebugEntries() {
        let manager = makeManager()
        manager.debugEnabled = false
        manager.debugLog("test", "调试不应落库")
        XCTAssertFalse(messages(from: manager.entries).contains("调试不应落库"))

        manager.debugEnabled = true
        manager.debugLog("test", "调试可以落库")
        XCTAssertTrue(messages(from: manager.entries).contains("调试可以落库"))
        // INFO 不受 DEBUG 开关影响
        manager.debugEnabled = false
        manager.info("test", "信息始终记录")
        XCTAssertTrue(messages(from: manager.entries).contains("信息始终记录"))
    }

    func testFIFOTrimsOldestBeyondMax() {
        let manager = makeManager(maxEntries: 50)
        for index in 1...60 {
            manager.info("flood", "T\(index)")
        }
        XCTAssertEqual(manager.entries.count, 50)
        XCTAssertEqual(manager.entries.first?.message, "T60")
        // 最早的 10 条已被淘汰
        let remaining = messages(from: manager.entries)
        XCTAssertFalse(remaining.contains("T1"))
        XCTAssertFalse(remaining.contains("T10"))
        XCTAssertTrue(remaining.contains("T11"))
    }

    // MARK: 搜索 / 筛选 / 聚合 / 统计

    func testMultiKeywordSearchAndFieldCoverage() {
        let manager = makeManager()
        manager.info("netmon", "慢请求告警", context: ["host": "www2.sxjzit.edu.cn", "latencyMs": "2083"])
        manager.warning("sync", "同步节流命中", context: ["reason": "10min"])
        manager.error("wechat", "注册失败", context: ["code": "E1001"])

        // 空格分隔多关键词 AND（message + module 组合）
        XCTAssertEqual(manager.search(query: "慢请求 netmon", in: manager.entries).count, 1)
        // 命中上下文字段
        XCTAssertEqual(manager.search(query: "latencyMs", in: manager.entries).count, 1)
        XCTAssertEqual(manager.search(query: "E1001", in: manager.entries).count, 1)
        // 命中级别名（rawValue 与中文名均可）
        XCTAssertEqual(manager.search(query: "warning", in: manager.entries).count, 1)
        XCTAssertEqual(manager.search(query: "警告", in: manager.entries).count, 1)
        // 未命中
        XCTAssertTrue(manager.search(query: "不存在的关键词", in: manager.entries).isEmpty)
        // 空查询返回原集合
        XCTAssertEqual(manager.search(query: "   ", in: manager.entries).count, manager.entries.count)
    }

    func testFilterCombination() {
        let manager = makeManager()
        manager.info("netmon", "甲条")
        manager.warning("netmon", "乙条")
        manager.warning("wechat", "丙条")

        XCTAssertEqual(manager.filtered(level: .warning, module: "netmon", query: "").count, 1)
        XCTAssertEqual(manager.filtered(level: .warning, module: nil, query: "").count, 2)
        XCTAssertEqual(manager.filtered(level: nil, module: "netmon", query: "甲").count, 1)
        XCTAssertEqual(manager.filtered(level: .info, module: "netmon", query: "乙").count, 0)
    }

    func testModuleFacetsSortedByCount() {
        let manager = makeManager()
        manager.info("alpha", "1")
        manager.info("alpha", "2")
        manager.info("beta", "1")

        let facets = manager.moduleFacets()
        XCTAssertEqual(facets.first?.module, "alpha")
        XCTAssertEqual(facets.first?.count, 2)
        XCTAssertTrue(facets.contains { $0.module == "beta" && $0.count == 1 })
    }

    func testStatsCountsTodayAndIssues() {
        let manager = makeManager()
        let before = manager.stats()
        manager.info("test", "信息")
        manager.warning("test", "警告")
        manager.error("test", "错误")
        manager.debugLog("test", "调试")

        let stats = manager.stats()
        XCTAssertEqual(stats.total, before.total + 4)
        XCTAssertEqual(stats.today, before.today + 4)
        XCTAssertEqual(stats.issueToday, before.issueToday + 2)
        XCTAssertEqual(stats.count(of: .warning), before.count(of: .warning) + 1)
        XCTAssertEqual(stats.count(of: .error), before.count(of: .error) + 1)
        XCTAssertNotNil(stats.newest)
    }

    // MARK: 删除 / 清空

    func testRemoveEntryIdempotentAndDiskPurge() async {
        let manager = makeManager()
        manager.info("test", "待删除条目")
        manager.flushPendingNow()
        XCTAssertTrue(readDiskEntries().contains { $0.message == "待删除条目" })

        guard let id = manager.entries.first(where: { $0.message == "待删除条目" })?.id else {
            XCTFail("未找到目标日志")
            return
        }
        XCTAssertTrue(manager.removeEntry(id: id))
        XCTAssertFalse(manager.removeEntry(id: id))
        XCTAssertFalse(messages(from: manager.entries).contains("待删除条目"))

        // 磁盘同样剔除（后台重写）
        let purged = await waitUntil {
            !self.readDiskEntries().contains { $0.message == "待删除条目" }
        }
        XCTAssertTrue(purged)
    }

    func testRemoveEntriesByCondition() {
        let manager = makeManager()
        manager.info("netmon", "保留我")
        manager.warning("netmon", "删除我-1")
        manager.error("wechat", "删除我-2")

        let removed = manager.removeEntries(level: nil, module: nil, query: "删除我")
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(messages(from: manager.entries).contains("保留我"))
    }

    func testClearAllWipesMemoryAndDisk() async {
        let manager = makeManager()
        manager.info("test", "A")
        manager.info("test", "B")
        manager.flushPendingNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: todayFileURL.path))

        manager.clearAll()
        // 清空后仅保留一条留痕日志
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertTrue(manager.entries.first?.message.contains("清空全部日志") ?? false)

        // 旧日志不得复活：留痕条目落盘后，磁盘不应再含 A/B
        manager.flushPendingNow()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let diskMessages = messages(from: readDiskEntries())
        XCTAssertFalse(diskMessages.contains("A"), "磁盘=\(diskMessages.joined(separator: "|"))")
        XCTAssertFalse(diskMessages.contains("B"), "磁盘=\(diskMessages.joined(separator: "|"))")
    }

    // MARK: 追加合并落盘（核心修复）

    func testAppendMergePreservesExistingDiskEntries() {
        let first = makeManager()
        first.info("test", "A1")
        first.info("test", "A2")
        first.info("test", "A3")
        first.flushPendingNow()

        let second = makeManager()
        second.info("test", "B1")
        second.info("test", "B2")
        second.flushPendingNow()

        let diskMessages = messages(from: readDiskEntries())
        for message in ["A1", "A2", "A3", "B1", "B2"] {
            XCTAssertTrue(diskMessages.contains(message), "追加合并后磁盘应保留 \(message)")
        }
    }

    func testMemoryTrimDoesNotTruncateDisk() async {
        let writer = makeManager(maxEntries: 3)
        for index in 1...5 {
            writer.info("trim", "T\(index)")
        }
        // 内存受上限约束
        XCTAssertEqual(writer.entries.count, 3)
        writer.flushPendingNow()

        // 磁盘保留全部 5 条（历史缺陷：被内存快照重写截断）
        let diskMessages = messages(from: readDiskEntries())
        for index in 1...5 {
            XCTAssertTrue(diskMessages.contains("T\(index)"), "磁盘不应因内存裁剪丢失 T\(index)")
        }

        let reader = makeManager(maxEntries: 100)
        _ = await waitUntil { reader.entries.count >= 5 }
        XCTAssertTrue(reader.entries.count >= 5,
                      "reader 条数=\(reader.entries.count)，磁盘=\(messages(from: readDiskEntries()).joined(separator: "|"))")
        XCTAssertTrue(messages(from: reader.entries).contains("T1"),
                      "reader=\(messages(from: reader.entries).joined(separator: "|"))")
    }

    func testSingleFileCapKeepsNewest() {
        let manager = makeManager(maxEntries: 100, maxEntriesPerFile: 10)
        for index in 1...15 {
            manager.info("cap", "C\(index)")
        }
        manager.flushPendingNow()

        let diskEntries = readDiskEntries()
        XCTAssertEqual(diskEntries.count, 10)
        XCTAssertTrue(messages(from: diskEntries).contains("C15"))
        XCTAssertFalse(messages(from: diskEntries).contains("C1"))
    }

    // MARK: 损坏抢救

    func testCorruptedFileRescuesValidEntries() async throws {
        // 数组内一条合法 + 一条字段类型损坏
        let validEntry = LogEntry(level: .info, module: "rescue", message: "合法条目")
        let validJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(validEntry))
        let payload: [Any] = [validJSON, ["level": 12345, "broken": true]]
        try JSONSerialization.data(withJSONObject: payload).write(to: todayFileURL)

        let manager = makeManager()
        let loaded = await waitUntil { messages(from: manager.entries).contains("合法条目") }
        XCTAssertTrue(loaded)
        // 抢救告警留痕
        XCTAssertTrue(manager.entries.contains { $0.level == .warning && $0.module == "log" && $0.message.contains("抢救") })
    }

    func testFullyCorruptedFileDoesNotBlockStartup() async throws {
        try Data("这不是合法 JSON".utf8).write(to: todayFileURL)

        let manager = makeManager()
        let logged = await waitUntil {
            manager.entries.contains { $0.module == "log" && $0.message.contains("抢救") }
        }
        XCTAssertTrue(logged, "整体损坏文件应在加载后留下告警留痕")
        // 管理器仍可正常写入
        manager.info("test", "损坏自愈后可写")
        XCTAssertTrue(messages(from: manager.entries).contains("损坏自愈后可写"))
    }

    // MARK: 崩溃日志

    func testCrashWriteUsesLocalDayKeyAndPersists() {
        _ = makeManager()
        let entry = LogEntry(level: .fatal, module: "crashCapture",
                             message: "测试崩溃写入", context: ["signal": "SIGABRT"])
        LogManager.crashWrite(entry)

        let diskEntries = readDiskEntries()
        XCTAssertTrue(diskEntries.contains { $0.id == entry.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: todayFileURL.path))
    }

    func testCrashCaptureToggleSnapshotTakesEffect() {
        let manager = makeManager()
        manager.crashCaptureEnabled = false
        XCTAssertFalse(LogManager.crashCaptureEnabledSnapshot)
        manager.crashCaptureEnabled = true
        XCTAssertTrue(LogManager.crashCaptureEnabledSnapshot)
    }

    // MARK: 导出

    func testExportTextAndJSON() throws {
        let manager = makeManager()
        manager.info("netmon", "导出目标 A", context: ["k": "v"])
        manager.error("wechat", "导出目标 B")

        let all = manager.filtered(level: nil, module: nil, query: "")
        let text = manager.export(entries: all, title: "全部日志", format: .text)
        XCTAssertTrue(text.contains("应用日志（全部日志）"))
        XCTAssertTrue(text.contains("日志总数：\(all.count) 条"))
        XCTAssertTrue(text.contains("导出目标 A"))

        let json = manager.export(entries: all, title: "全部日志", format: .json)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, all.count)
        XCTAssertEqual((object["entries"] as? [[String: Any]])?.count, all.count)

        // 按筛选导出仅含命中条目
        let filtered = manager.filtered(level: .error, module: nil, query: "")
        let filteredText = manager.export(entries: filtered, title: "级别=错误", format: .text)
        XCTAssertTrue(filteredText.contains("导出目标 B"))
        XCTAssertFalse(filteredText.contains("导出目标 A"))
    }

    func testExportFileNameSanitization() {
        let manager = makeManager()
        let name = manager.exportFileName(tag: "error netmon", format: .json)
        XCTAssertTrue(name.hasPrefix("sxjzit_logs_"))
        XCTAssertTrue(name.hasSuffix(".json"))
        XCTAssertFalse(name.contains(" "))
        XCTAssertTrue(name.contains("error"))
    }

    // MARK: 保留策略 / 存储快照

    func testRetentionDeletesExpiredDayFiles() async throws {
        // 预置 8 天前的过期日文件
        let expiredKey = LogEntry.dayKeyFormatter.string(from: Date().addingTimeInterval(-8 * 86400))
        let expiredURL = tempDir.appendingPathComponent("log_\(expiredKey).json")
        try JSONEncoder().encode([LogEntry(level: .info, module: "old", message: "过期日志")]).write(to: expiredURL)

        _ = makeManager(retentionDays: 7)
        let deleted = await waitUntil { !FileManager.default.fileExists(atPath: expiredURL.path) }
        XCTAssertTrue(deleted, "超过保留天数的日文件应被自动清理")
    }

    func testApplyRetentionKeepsRecentFiles() async throws {
        let recentKey = LogEntry.dayKeyFormatter.string(from: Date().addingTimeInterval(-2 * 86400))
        let recentURL = tempDir.appendingPathComponent("log_\(recentKey).json")
        try JSONEncoder().encode([LogEntry(level: .info, module: "recent", message: "保留日志")]).write(to: recentURL)

        _ = makeManager(retentionDays: 7)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path), "保留期内文件不应被清理")
    }

    func testStorageSnapshotCountsFiles() async {
        let manager = makeManager()
        manager.info("test", "快照目标")
        manager.flushPendingNow()

        let snapshot = await manager.storageSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.files, 1)
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertEqual(snapshot.newestDay, LogEntry.dayKeyFormatter.string(from: Date()))
    }

    func testFlushPendingNowPersistsImmediately() {
        let manager = makeManager()
        manager.info("test", "立即落盘")
        XCTAssertEqual(manager.flushPendingNow(), 0)
        XCTAssertTrue(messages(from: readDiskEntries()).contains("立即落盘"))
    }

    func testApplyMaxEntriesLimitTrimsImmediately() {
        let manager = makeManager()
        for index in 1...5 {
            manager.info("trim", "M\(index)")
        }
        let before = manager.entries.count
        XCTAssertGreaterThan(before, 3)

        manager.maxEntries = 3
        // 变更即裁剪：仅保留最新 3 条（含设置变更留痕）
        XCTAssertEqual(manager.entries.count, 3)
        XCTAssertTrue(manager.entries.contains { $0.message.contains("容量上限变更") })
        let remaining = messages(from: manager.entries)
        XCTAssertFalse(remaining.contains("M1"))
        XCTAssertFalse(remaining.contains("M2"))
        XCTAssertTrue(remaining.contains("M5"))
    }

    // MARK: 自反馈风暴抑制（2026-09-28 现场卡死防线）

    func testStormFoldSuppressesRepeatedIdenticalLogs() {
        let manager = makeManager()
        // 模拟「展示日志 → 写日志 → 再展示」自反馈：1 秒内同内容日志远超阈值
        for _ in 0..<(LogManager.stormFoldLimit * 3) {
            manager.info("storm", "重复日志")
        }
        XCTAssertEqual(messages(from: manager.entries).filter { $0 == "重复日志" }.count,
                       LogManager.stormFoldLimit,
                       "同内容日志应被折叠至窗口上限")
        XCTAssertTrue(manager.entries.contains { $0.message.contains("日志风暴抑制") },
                      "折叠应留痕告警")

        // 换一条不同内容 → 结算上一窗口的折叠统计
        manager.info("storm", "风暴结束后的新日志")
        XCTAssertTrue(manager.entries.contains { $0.message.contains("日志风暴抑制结束") },
                      "折叠结束应留痕统计")
        XCTAssertTrue(messages(from: manager.entries).contains("风暴结束后的新日志"))
    }

    // MARK: 模型辅助

    func testEntryHelpers() {
        let entry = LogEntry(level: .warning, module: "test", message: "模型校验", context: ["b": "2", "a": "1"])
        XCTAssertEqual(entry.dayKey, LogEntry.dayKeyFormatter.string(from: entry.timestamp))
        XCTAssertEqual(entry.contextFieldCount, 2)
        XCTAssertEqual(entry.level.displayName, "警告")
        XCTAssertTrue(entry.level.isIssue)
        XCTAssertTrue(entry.detailText.contains("a = 1"))
        XCTAssertTrue(entry.jsonText().contains("\"message\""))
        XCTAssertTrue(entry.relativeTime().contains("刚刚") || entry.relativeTime().contains("分钟前"))
        XCTAssertEqual(LogLevel.debug.displayName, "调试")
        XCTAssertFalse(LogLevel.info.isIssue)
    }
}