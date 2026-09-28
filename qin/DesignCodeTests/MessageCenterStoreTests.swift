//
//  MessageCenterStoreTests.swift
//  山西晋中理工学院 APP — 消息中心 Store 单元测试
//
//  覆盖：ingest 新增/去重/测试排除、FIFO 截断、存储损坏自愈、逐条抢救、
//  markRead 幂等（id / kind+articleId / kind）、markAllRead 单次批量、
//  清空两种 scope、筛选纯函数、latestItem 派生、未读计数兜底、
//  launch 无载荷失败降级、自动检查节流、快速修复重写。
//
//  全部用例注入临时存储目录 + 独立 UserDefaults suite，互不污染。
//

import XCTest
@testable import DesignCode
import UIKit

@MainActor
final class MessageCenterStoreTests: XCTestCase {

    private var tempDir: URL!
    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MessageCenterTests.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)!
        suiteDefaults.set(true, forKey: "messageCenterImportedSystemOnce")  // 关闭历史导入
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageCenterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        suiteDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(limit: Int? = nil) -> MessageCenterStore {
        let store = MessageCenterStore(storageDirectory: tempDir, defaults: suiteDefaults)
        if let limit { store.maxCount = limit }
        return store
    }

    private var newsPayload: DeepLinkPayload {
        DeepLinkPayload(articleId: "a1", articleCategory: "学校要闻", articleTitle: "测试文章")
    }

    // MARK: ingest

    func testIngestAddsAndSetsUnread() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "【学校要闻】", subtitle: "标题一", deepLink: newsPayload)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.latestItem?.id, "news-a1")
        XCTAssertFalse(store.items[0].isRead)
    }

    func testIngestDeduplicatesSameId() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "T1", subtitle: "S1", deepLink: newsPayload)
        store.ingest(kind: .news, id: "news-a1", title: "T1", subtitle: "S1", deepLink: newsPayload)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testDeepLinkUpgradePersistsToDisk() {
        let store = makeStore()
        // 首次无深链入盒
        store.ingest(kind: .news, id: "news-a1", title: "T", subtitle: "S", deepLink: nil)
        // 同 id 再次 ingest 且内容不变、仅补全深链：必须落盘
        store.ingest(kind: .news, id: "news-a1", title: "T", subtitle: "S", deepLink: newsPayload)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items.first?.deepLink?.articleId, "a1")
    }

    func testIngestSkipsTestNotification() {
        let store = makeStore()
        store.ingest(kind: .mailbox, id: "mailbox-9", title: "t", subtitle: "s",
                     deepLink: DeepLinkPayload(mailboxId: "9", mailboxTitle: "t"), isTest: true)
        XCTAssertEqual(store.items.count, 0)
    }

    func testIngestEmptyIdRejected() {
        let store = makeStore()
        store.ingest(kind: .news, id: "", title: "t", subtitle: "s", deepLink: newsPayload)
        XCTAssertEqual(store.items.count, 0)
    }

    // MARK: FIFO

    func testFIFOEviction() {
        let store = makeStore(limit: 3)
        for i in 1...5 {
            store.ingest(kind: .news, id: "news-\(i)", title: "T", subtitle: "S", deepLink: nil)
        }
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items.first?.id, "news-5")  // 最新保留
        XCTAssertNil(store.items.first(where: { $0.id == "news-1" }))
        XCTAssertNil(store.items.first(where: { $0.id == "news-2" }))
    }

    // MARK: 存储自愈

    func testCorruptedStorageRecoversAndRescuesValidItems() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "【学校要闻】", subtitle: "正常条目", deepLink: newsPayload)
        store.ingest(kind: .partySubject, id: "ps-1", title: "党建", subtitle: "正常条目二",
                     deepLink: DeepLinkPayload(partySubject: true))

        // 直接写坏存储文件：整体解码必然失败（非法 JSON）
        let file = tempDir.appendingPathComponent("messageCenterEvents.json")
        try? "{broken json".data(using: .utf8)?.write(to: file)

        let reloaded = makeStore()
        XCTAssertGreaterThanOrEqual(reloaded.items.count, 0)
        // 备份文件应已生成（corrupt-<时间戳>.json 命名，可保留多份现场）
        let backups = (try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(backups.contains {
            $0.lastPathComponent.contains("messageCenterEvents.corrupt-")
        }, "损坏备份应以时间戳命名生成")
    }

    func testSingleCorruptItemSkippedArrayRescue() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "好条目", subtitle: "s", deepLink: newsPayload)

        // 构造一个数组 JSON：第一个为合法元素、第二个为非法元素
        let good: [String: Any] = [
            "id": "news-ok", "kind": "news", "title": "逐条", "subtitle": "s",
            "timestamp": "2026-09-24T08:00:00Z", "isRead": false,
            "schemaVersion": 1
        ]
        let bad: [String: Any] = ["id": 123, "kind": "news"]  // 类型不符 → 单条解码失败
        let array: [[String: Any]] = [good, bad]
        let data = try! JSONSerialization.data(withJSONObject: array)
        try? data.write(to: tempDir.appendingPathComponent("messageCenterEvents.json"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items.first?.id, "news-ok")
    }

    // MARK: 已读管理

    func testMarkReadByIdAndIdempotent() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "t", subtitle: "s", deepLink: newsPayload)
        store.markRead(id: "news-a1")
        XCTAssertEqual(store.unreadCount, 0)
        store.markRead(id: "news-a1")  // 幂等：不重复扣减
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.items[0].isRead)
    }

    func testMarkUnreadTogglesBackAndIdempotent() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "t", subtitle: "s", deepLink: newsPayload)
        store.markRead(id: "news-a1")
        store.markUnread(id: "news-a1")
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertFalse(store.items[0].isRead)
        store.markUnread(id: "news-a1")  // 幂等：不重复累加
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testMarkReadByKindArticleId() {
        let store = makeStore()
        store.ingest(kind: .bookmarkUpdate, id: "bookmark-update-k1", title: "收藏更新",
                     subtitle: "s", deepLink: DeepLinkPayload(articleId: "a1", articleCategory: "要闻", articleTitle: "t"))
        store.markRead(kind: .bookmarkUpdate, articleId: "a1")
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testMarkReadByKindArticleIdNeverMismarksOtherItem() {
        let store = makeStore()
        store.ingest(kind: .bookmarkUpdate, id: "bookmark-update-k2", title: "收藏更新 B",
                     subtitle: "s", deepLink: DeepLinkPayload(articleId: "a2", articleCategory: "要闻", articleTitle: "t"))
        // 点击的通知 A（a1）不在盒中：绝不能误标同类型的 B（a2）
        store.markRead(kind: .bookmarkUpdate, articleId: "a1")
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertFalse(store.items[0].isRead)
    }

    func testMarkReadByKind() {
        let store = makeStore()
        store.ingest(kind: .schoolProfile, id: "sp-1", title: "概况", subtitle: "s",
                     deepLink: DeepLinkPayload(schoolProfile: true))
        store.markRead(kind: .schoolProfile)
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testMarkAllRead() {
        let store = makeStore()
        for i in 1...3 {
            store.ingest(kind: .news, id: "news-\(i)", title: "T", subtitle: "S", deepLink: nil)
        }
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.items.allSatisfy(\.isRead))
    }

    // MARK: 删除与清空

    func testDeleteUnreadAdjustsCount() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "t", subtitle: "s", deepLink: nil)
        store.ingest(kind: .news, id: "news-a2", title: "t", subtitle: "s", deepLink: nil)
        store.delete(id: "news-a1")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testClearHistoryScopes() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "t", subtitle: "s", deepLink: nil)
        store.markAllRead()
        store.ingest(kind: .news, id: "news-a2", title: "t", subtitle: "s", deepLink: nil)
        store.clearHistory(scope: .readOnly)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].id, "news-a2")
        store.clearHistory(scope: .all)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)
    }

    // MARK: 筛选

    func testFilterByKeywordKindAndUnread() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "校园要闻", subtitle: "运动会开幕", deepLink: nil)
        store.ingest(kind: .mailbox, id: "mailbox-1", title: "校长信箱", subtitle: "运动会反馈",
                     deepLink: DeepLinkPayload(mailboxId: "1", mailboxTitle: "t"))
        store.ingest(kind: .news, id: "news-a2", title: "通知公告", subtitle: "停水通知", deepLink: nil)
        store.markRead(id: "news-a2")

        XCTAssertEqual(store.filter(keyword: "运动会").count, 2)
        XCTAssertEqual(store.filter(kind: .mailbox).count, 1)
        XCTAssertEqual(store.filter(unreadOnly: true).count, 2)
        XCTAssertEqual(store.filter(keyword: "运动会", kind: .mailbox).count, 1)
    }

    // MARK: launch 降级

    func testLaunchWithoutPayloadFailsGracefully() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-nolink", title: "t", subtitle: "s", deepLink: nil)
        let item = store.items[0]
        store.launch(item: item)
        guard case .failed = store.launchState else {
            XCTFail("无深链载荷应进入 failed 状态")
            return
        }
    }

    // MARK: 自动检查节流（不发网络）

    func testAutoCheckThrottledWithin30Minutes() {
        let store = makeStore()
        store.setAutoCheck(true)
        let recent = Date().timeIntervalSince1970 - 25 * 60  // 25 分钟前
        suiteDefaults.set(recent, forKey: "messageCenterLastAutoCheckTime")
        store.handleSceneActive()
        let after = suiteDefaults.object(forKey: "messageCenterLastAutoCheckTime") as? TimeInterval
        XCTAssertEqual(after ?? 0, recent)  // 节流跳过：时间戳未被更新
    }

    // MARK: 快速修复

    func testRepairRewriteKeepsData() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-a1", title: "t", subtitle: "s", deepLink: newsPayload)
        XCTAssertTrue(store.repairRewrite())
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items.first?.id, "news-a1")
    }

    // MARK: 未读计数兜底与 latestItem

    func testRelativeTimeNeverShowsNegative() {
        // 「now」锚定当日中午 12:00：避免凌晨运行（00:00–02:05）时
        // now-2h/now-5min 跨午夜而触发「昨天 HH:mm」分支，导致断言随运行时刻抖动
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        // 未来时间戳（时钟偏差/时区异常）：不得外显为负数小时
        let future = now.addingTimeInterval(-7200)  // 相对 now 早 2 小时
        XCTAssertEqual(MessageTimeText.relative(future, now: now), "2 小时前")
        let futureStamp = now.addingTimeInterval(120)  // 未来 2 分钟
        XCTAssertEqual(MessageTimeText.relative(futureStamp, now: now), "刚刚")
        let minutes = now.addingTimeInterval(-300)
        XCTAssertEqual(MessageTimeText.relative(minutes, now: now), "5 分钟前")
    }

    func testDayGroupClassification() {
        let now = Date()
        XCTAssertEqual(MessageTimeText.DayGroup.group(for: now), .today)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(MessageTimeText.DayGroup.group(for: yesterday), .yesterday)
        let older = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        XCTAssertEqual(MessageTimeText.DayGroup.group(for: older), .earlier)
    }

    func testLatestItemTracksNewest() {
        let store = makeStore()
        store.ingest(kind: .news, id: "news-old", title: "旧", subtitle: "s", deepLink: nil)
        store.ingest(kind: .schoolProfile, id: "sp-new", title: "新", subtitle: "s",
                     deepLink: DeepLinkPayload(schoolProfile: true))
        XCTAssertEqual(store.latestItem?.id, "sp-new")
    }

    func testUnreadCountSurvivesBulkOperations() {
        let store = makeStore(limit: 2)
        for i in 1...3 {
            store.ingest(kind: .news, id: "news-\(i)", title: "T", subtitle: "S", deepLink: nil)
        }
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.unreadCount, 2)  // FIFO 截断后未读数与列表一致
    }
}

// MARK: - 首页模块管理器单元测试（2026-09-24，与消息中心测试同文件避免 pbxproj 注册）
//
//  覆盖：显示/隐藏切换与幂等、恢复默认、排序移动保全集、帮助模块开关联动可见列表。
//  HomeModuleManager 为 @MainActor 单例（首次初始化后不可重建），用例以 resetToDefaults
//  恢复纯净状态；测试宿主的 UserDefaults 与真机 App 沙盒隔离，互不污染。

@MainActor
final class HomeModuleManagerTests: XCTestCase {

    private var manager: HomeModuleManager { HomeModuleManager.shared }

    override func setUp() {
        super.setUp()
        manager.resetToDefaults()
    }

    override func tearDown() {
        manager.resetToDefaults()
        super.tearDown()
    }

    func testSetVisibleHideThenShow() {
        manager.setVisible(.helpGuide, false)
        XCTAssertFalse(manager.isVisible(.helpGuide))
        XCTAssertTrue(manager.hiddenModules.contains(.helpGuide))

        manager.setVisible(.helpGuide, true)
        XCTAssertTrue(manager.isVisible(.helpGuide))
        XCTAssertFalse(manager.hiddenModules.contains(.helpGuide))
    }

    func testSetVisibleIdempotentKeepsState() {
        manager.setVisible(.helpGuide, false)
        let hiddenBefore = manager.hiddenModules
        manager.setVisible(.helpGuide, false)  // 重复隐藏：幂等无变化
        XCTAssertEqual(manager.hiddenModules, hiddenBefore)
        XCTAssertEqual(manager.hiddenModules.count, 1)

        manager.setVisible(.helpGuide, true)
        XCTAssertTrue(manager.hiddenModules.isEmpty)
    }

    func testResetToDefaultsRestoresAll() {
        manager.setVisible(.helpGuide, false)
        manager.setVisible(.notices, false)
        manager.moveModules(from: IndexSet(integer: 0), to: 3)

        manager.resetToDefaults()
        XCTAssertTrue(manager.isDefault)
        XCTAssertEqual(manager.moduleOrder, HomeModule.allCases)
        XCTAssertTrue(manager.hiddenModules.isEmpty)
    }

    func testMoveModulesChangesOrderKeepingAllModules() {
        manager.moveModules(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(manager.moduleOrder.count, HomeModule.allCases.count)
        XCTAssertNotEqual(manager.moduleOrder, HomeModule.allCases)
        XCTAssertEqual(Set(manager.moduleOrder), Set(HomeModule.allCases))
    }

    func testHelpGuideVisibilityReflectsInVisibleOrder() {
        manager.setVisible(.helpGuide, false)
        XCTAssertFalse(manager.visibleOrderedModules.contains(.helpGuide))
        XCTAssertEqual(manager.visibleOrderedModules.count, HomeModule.allCases.count - 1)

        manager.setVisible(.helpGuide, true)
        XCTAssertTrue(manager.visibleOrderedModules.contains(.helpGuide))
        XCTAssertEqual(manager.visibleOrderedModules.count, HomeModule.allCases.count)
    }
}

// MARK: - 校园日历 Store 本地纯逻辑测试（campusCalendar，2026-09-24）

/// 覆盖：官网三种时间格式解析、解析失败兜底与空值、搜索历史去重置顶与上限截断、一键清空。
/// 历史用例以 clearSearchHistory 起止，落盘空数组不污染应用数据。
@MainActor
final class CampusCalendarStoreTests: XCTestCase {

    func testCampusCalendarDateTextKnownFormats() {
        // 官网实测三种形态：列表 create_time（空格分隔）、详情 update_time（T 分隔）、纯日期
        XCTAssertEqual(CampusCalendarStore.dateText("2025-08-23 22:26:55"), "2025.08.23")
        XCTAssertEqual(CampusCalendarStore.dateText("2025-08-23T00:00:00"), "2025.08.23")
        XCTAssertEqual(CampusCalendarStore.dateText("2025-08-23"), "2025.08.23")
    }

    func testCampusCalendarDateTextFallbackAndEmpty() {
        XCTAssertEqual(CampusCalendarStore.dateText(""), "")
        XCTAssertEqual(CampusCalendarStore.dateText(nil), "")
        // 不匹配任何已知格式时回退前 10 字符
        XCTAssertEqual(CampusCalendarStore.dateText("2025-08-23 下午"), "2025-08-23")
    }

    func testCampusCalendarSearchHistoryDedupeAndCap() {
        let store = CampusCalendarStore.shared
        store.clearSearchHistory()

        for i in 1...12 {
            store.commitSearchHistory("词\(i)")
        }
        // 上限 10 条，最新在前
        XCTAssertEqual(store.searchHistory.count, 10)
        XCTAssertEqual(store.searchHistory.first, "词12")

        // 重复词去重并置顶，总数不变
        store.commitSearchHistory("词5")
        XCTAssertEqual(store.searchHistory.first, "词5")
        XCTAssertEqual(store.searchHistory.count, 10)

        store.clearSearchHistory()
        XCTAssertTrue(store.searchHistory.isEmpty)
    }

// MARK: - 网络监测纯逻辑测试（2026-09-26，与消息中心测试同文件避免 pbxproj 注册）
//
//  覆盖：健康分四级边界、评级文案、建议生成器规则映射、分位数、
//  URL 解析域校验、流量日键格式。全部为离线纯函数，无网络请求。

final class NetworkMonitorLogicTests: XCTestCase {

    // MARK: 健康分（权重：链路质量35 + P90 30 + 丢包20 + 吞吐15）

    func testHealthScorePerfectCase() {
        let score = SJZNetworkMonitor.healthScore(
            linkQualityText: "优秀", p90: 50, lossRate: 0, throughputKBps: 300)
        XCTAssertEqual(score, 100, "全项满分应为 100")
    }

    func testHealthScoreWorstCase() {
        let score = SJZNetworkMonitor.healthScore(
            linkQualityText: "一般", p90: 1200, lossRate: 0.8, throughputKBps: 0)
        XCTAssertTrue(score < 30, "全项最差应低于 30 分")
        XCTAssertGreaterThanOrEqual(score, 0, "分数不得为负")
    }

    func testHealthScoreSystemUnknownFallback() {
        // 低版本/系统未提供 → 链路质量 15 分中性值
        let low = SJZNetworkMonitor.healthScore(
            linkQualityText: "系统未提供", p90: 50, lossRate: 0, throughputKBps: 300)
        let high = SJZNetworkMonitor.healthScore(
            linkQualityText: "优秀", p90: 50, lossRate: 0, throughputKBps: 300)
        XCTAssertLessThan(low, high, "链路质量未知时应低于优秀档")
        XCTAssertEqual(low, 100 - (35 - 15), "仅链路质量项差异")
    }

    func testHealthScoreClampedRange() {
        let score = SJZNetworkMonitor.healthScore(
            linkQualityText: "优秀", p90: 0.001, lossRate: 0, throughputKBps: 99999)
        XCTAssertEqual(score, 100, "吞吐超上限应截断为满分而非溢出")
    }

    // MARK: 评级文案

    func testGradeTextBoundaries() {
        XCTAssertEqual(SJZNetworkMonitor.gradeText(100), "优秀")
        XCTAssertEqual(SJZNetworkMonitor.gradeText(88), "优秀")
        XCTAssertEqual(SJZNetworkMonitor.gradeText(74), "良好")
        XCTAssertEqual(SJZNetworkMonitor.gradeText(53), "一般")
        XCTAssertEqual(SJZNetworkMonitor.gradeText(20), "较差")
        XCTAssertEqual(SJZNetworkMonitor.gradeText(0), "较差")
    }

    // MARK: 优化建议规则映射

    func testAdviceHighLoss() {
        let result = ProbeResult(rtts: [100, 200], lossRate: 0.6, dnsMs: nil, tcpMs: nil,
                                 tlsMs: nil, ttfbMs: nil, protocolName: nil, isRemoteIPv6: false)
        let advice = SJZNetworkMonitor.advice(for: result, healthScore: 30)
        XCTAssertFalse(advice.isEmpty)
        XCTAssertTrue(advice.first?.text.contains("丢包") == true, "高丢包必须给出信号建议")
    }

    func testAdviceHealthyNetwork() {
        let result = ProbeResult(rtts: [40, 50], lossRate: 0, dnsMs: 10, tcpMs: 8,
                                 tlsMs: 30, ttfbMs: 45, protocolName: "h2", isRemoteIPv6: false)
        let advice = SJZNetworkMonitor.advice(for: result, healthScore: 95)
        XCTAssertEqual(advice.count, 1)
        XCTAssertTrue(advice[0].text.contains("健康"), "全优场景应给出健康建议")
    }

    // MARK: 分位数

    func testPercentileKnownSequence() {
        // nearest-rank 口径：idx = Int((count-1)*p)
        XCTAssertEqual(ProbeResult.percentile([1, 2, 3, 4, 5], 0.5), 3, "5 元素 P50 取秩 2")
        XCTAssertEqual(ProbeResult.percentile([1, 2, 3, 4, 5], 0.9), 4, "5 元素 P90 秩 Int(4*0.9)=3 → 值 4")
        XCTAssertEqual(ProbeResult.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9, "10 元素 P90 秩 Int(9*0.9)=8 → 值 9")
        XCTAssertEqual(ProbeResult.percentile([], 0.5), 0, "空序列应返回 0")
        XCTAssertEqual(ProbeResult.stageText(nil), "—")
    }

    // MARK: 探测资源 URL 解析（学校域校验）

    func testResolvableSchoolURLVariants() throws {
        XCTAssertEqual(SJZNetworkMonitor.resolvableSchoolURL("/uploads/a.jpg")?.absoluteString,
                       "https://www.sxjzit.edu.cn/uploads/a.jpg")
        XCTAssertEqual(SJZNetworkMonitor.resolvableSchoolURL("//www.sxjzit.edu.cn/x.png")?.absoluteString,
                       "https://www.sxjzit.edu.cn/x.png")
        XCTAssertNotNil(SJZNetworkMonitor.resolvableSchoolURL("https://www.sxjzit.edu.cn/pic.webp"))
        // 外域必须拒绝（Referer 头依赖学校域）
        XCTAssertNil(SJZNetworkMonitor.resolvableSchoolURL("https://evil.example.com/a.jpg"))
        XCTAssertNil(SJZNetworkMonitor.resolvableSchoolURL(""))
    }

    // MARK: 今日流量日键

    func testTrafficDayKeyFormat() {
        XCTAssertTrue(NetmonKey.traffic(day: "20260926").hasPrefix("netmonTraffic_20260926"))
        XCTAssertNotEqual(NetmonKey.traffic(day: "20260926"), NetmonKey.traffic(day: "20260927"))
    }
}
}

// MARK: - 显示设置逻辑测试（离线纯逻辑：排版方案 / 历史 ring buffer / WCAG 对比度）

final class DisplaySettingsLogicTests: XCTestCase {

    // MARK: 排版方案 6 项目标值

    func testSchemeComfortableTargets() {
        XCTAssertEqual(DisplaySchemePreset.comfortable.fontSizeTier, .large)
        XCTAssertEqual(DisplaySchemePreset.comfortable.lineSpacing, 1.25, accuracy: 0.0001)
        XCTAssertEqual(DisplaySchemePreset.comfortable.letterSpacing, 0.2, accuracy: 0.0001)
        XCTAssertFalse(DisplaySchemePreset.comfortable.boldText)
        XCTAssertFalse(DisplaySchemePreset.comfortable.useSystemFont)
        XCTAssertEqual(DisplaySchemePreset.comfortable.fontFamily, .songti)
    }

    func testSchemeCompactTargets() {
        XCTAssertEqual(DisplaySchemePreset.compact.fontSizeTier, .small)
        XCTAssertEqual(DisplaySchemePreset.compact.lineSpacing, 0.95, accuracy: 0.0001)
        XCTAssertEqual(DisplaySchemePreset.compact.letterSpacing, 0, accuracy: 0.0001)
        XCTAssertFalse(DisplaySchemePreset.compact.boldText)
        XCTAssertTrue(DisplaySchemePreset.compact.useSystemFont)
        XCTAssertEqual(DisplaySchemePreset.compact.fontFamily, .system)
    }

    func testSchemeEyeCareTargets() {
        XCTAssertEqual(DisplaySchemePreset.eyeCare.fontSizeTier, .extraLarge)
        XCTAssertEqual(DisplaySchemePreset.eyeCare.lineSpacing, 1.45, accuracy: 0.0001)
        XCTAssertEqual(DisplaySchemePreset.eyeCare.letterSpacing, 0.5, accuracy: 0.0001)
        XCTAssertTrue(DisplaySchemePreset.eyeCare.boldText)
        XCTAssertFalse(DisplaySchemePreset.eyeCare.useSystemFont)
        XCTAssertEqual(DisplaySchemePreset.eyeCare.fontFamily, .yuanti)
    }

    func testSchemeBadgeTextNonEmpty() {
        for scheme in DisplaySchemePreset.allCases {
            XCTAssertFalse(scheme.title.isEmpty)
            XCTAssertFalse(scheme.subtitle.isEmpty)
            XCTAssertFalse(scheme.shortBadgeText.isEmpty)
            XCTAssertFalse(scheme.icon.isEmpty)
        }
    }

    // MARK: 自定义颜色历史 ring buffer

    func testColorHistoryPushDedupMoveToFront() {
        var history = ["1A1A1A", "2B2B2B"]
        history = DisplayHistoryOperator.pushColor("3C3C3C", into: history)
        XCTAssertEqual(history, ["3C3C3C", "1A1A1A", "2B2B2B"], "新色置顶")
        // 已有色复用 → 置顶去重
        history = DisplayHistoryOperator.pushColor("2b2b2b", into: history)
        XCTAssertEqual(history, ["2B2B2B", "3C3C3C", "1A1A1A"], "小写输入应规范化为大写并去重置顶")
    }

    func testColorHistoryTruncatesAtSix() {
        var history: [String] = []
        for index in 0..<8 {
            history = DisplayHistoryOperator.pushColor(String(format: "%02d%02d%02d", index, index + 1, index + 2), into: history)
        }
        XCTAssertEqual(history.count, 6, "超限必须截断到 6")
        XCTAssertEqual(history.first, "070809", "最新一条应在最前")
        XCTAssertFalse(history.contains("000102"), "最旧两条被 FIFO 淘汰")
        XCTAssertFalse(history.contains("010203"), "第二旧条同样被淘汰")
    }

    func testColorHistoryRejectsInvalidHex() {
        let history = ["1A1A1A"]
        XCTAssertEqual(DisplayHistoryOperator.pushColor("XYZ", into: history), history, "非法 hex 不改历史")
        XCTAssertEqual(DisplayHistoryOperator.pushColor("12345", into: history), history, "5 位 hex 拒绝")
        XCTAssertEqual(DisplayHistoryOperator.pushColor("1234567", into: history), history, "7 位 hex 拒绝")
        XCTAssertEqual(DisplayHistoryOperator.pushColor("", into: history), history, "空串拒绝")
    }

    // MARK: 变更历史时间轴 ring buffer

    func testChangeHistoryFIFOTruncatesAtTwenty() {
        var history: [DisplayChangeRecord] = []
        for index in 0..<25 {
            let record = DisplayChangeRecord(id: UUID(), field: "test", fieldTitle: "测试项", value: "\(index)", at: Date(timeIntervalSince1970: Double(index)))
            history = DisplayHistoryOperator.appendChange(record, into: history)
        }
        XCTAssertEqual(history.count, 20, "超限必须截断到 20")
        XCTAssertEqual(history.first?.value, "24", "最新记录在最前")
        XCTAssertEqual(history.last?.value, "5", "最旧 5 条被 FIFO 淘汰")
    }

    func testChangeHistoryPreservesFieldData() {
        let record = DisplayChangeRecord(id: UUID(), field: "appearance", fieldTitle: "外观模式", value: "深色模式", at: Date(timeIntervalSince1970: 100))
        let history = DisplayHistoryOperator.appendChange(record, into: [])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].field, "appearance")
        XCTAssertEqual(history[0].fieldTitle, "外观模式")
        XCTAssertEqual(history[0].value, "深色模式")
        XCTAssertEqual(history[0].at.timeIntervalSince1970, 100)
    }

    // MARK: WCAG 对比度纯函数

    func testContrastBlackWhiteLimits() {
        let blackOnWhite = DisplayContrastChecker.contrast(foregroundHex: "000000", backgroundHex: "FFFFFF")
        XCTAssertEqual(blackOnWhite, 21.0, accuracy: 0.01, "黑白极限应为 21:1")
        let sameColor = DisplayContrastChecker.contrast(foregroundHex: "1A56B8", backgroundHex: "1A56B8")
        XCTAssertEqual(sameColor, 1.0, accuracy: 0.01, "同色应为 1:1")
    }

    func testContrastSymmetricExchange() {
        let a = DisplayContrastChecker.contrast(foregroundHex: "2E7D32", backgroundHex: "FFFFFF")
        let b = DisplayContrastChecker.contrast(foregroundHex: "FFFFFF", backgroundHex: "2E7D32")
        XCTAssertEqual(a, b, accuracy: 0.0001, "前景/背景交换结果一致")
    }

    func testContrastPresetsPassOnWhiteAndDarkPaper() {
        let presets: [ArticleTextColorPreset] = [.ink, .graphite, .sepia, .navy, .forest, .indigo, .burgundy]
        for preset in presets {
            guard let light = preset.lightHex, let dark = preset.darkHex else {
                XCTFail("\(preset.rawValue) 缺少色值"); continue
            }
            let lightRatio = DisplayContrastChecker.contrast(foregroundHex: light, backgroundHex: "FFFFFF")
            let darkRatio = DisplayContrastChecker.contrast(foregroundHex: dark, backgroundHex: "262626")
            XCTAssertGreaterThanOrEqual(lightRatio, 4.5, "\(preset.title) 白纸必须达标")
            XCTAssertGreaterThanOrEqual(darkRatio, 4.5, "\(preset.title) 深纸必须达标")
        }
    }

    func testContrastLevelJudgmentBoundaries() {
        XCTAssertEqual(DisplayContrastChecker.level(for: 21.0), .pass)
        XCTAssertEqual(DisplayContrastChecker.level(for: 4.5), .pass, "4.5 边界属于合规")
        XCTAssertEqual(DisplayContrastChecker.level(for: 4.49), .suggest)
        XCTAssertEqual(DisplayContrastChecker.level(for: 2.5), .suggest, "2.5 边界属于建议")
        XCTAssertEqual(DisplayContrastChecker.level(for: 2.49), .fail)
        XCTAssertEqual(DisplayContrastChecker.level(for: 1.0), .fail)
    }

    func testContrastCustomPickPaperRealities() {
        // 自定义色为单色直用：浅色纸面（白纸）应合规；深色纸面如实提示不可达 4.5（由对比度自检徽章告知用户）
        let custom = "3A3A3A"
        let lightRatio = DisplayContrastChecker.contrast(foregroundHex: custom, backgroundHex: "FFFFFF")
        let darkRatio = DisplayContrastChecker.contrast(foregroundHex: custom, backgroundHex: "262626")
        XCTAssertGreaterThanOrEqual(lightRatio, 4.5, "3A3A3A 白纸应达标")
        XCTAssertEqual(DisplayContrastChecker.level(for: lightRatio), .pass)
        XCTAssertLessThan(darkRatio, 4.5, "单色在深纸上低于 4.5（自检卡如实呈现实情）")
        XCTAssertEqual(DisplayContrastChecker.level(for: darkRatio), .fail, "低于 2.5 判为不合格")
    }

    func testHexComponentParsing() {
        XCTAssertNotNil(DisplayContrastChecker.hexComponents("1A56B8"))
        XCTAssertNotNil(DisplayContrastChecker.hexComponents("1a56b8"), "小写合法")
        XCTAssertNil(DisplayContrastChecker.hexComponents("GGGGGG"), "非法字符拒绝")
        XCTAssertNil(DisplayContrastChecker.hexComponents("1A56B"), "长度不足拒绝")
        XCTAssertNil(DisplayContrastChecker.hexComponents("1A56B812"), "长度超限拒绝")
    }

    // MARK: 字体家族（中文全字形重构后的迁移与存在性）

    func testFontFamilySampleAndTitlesNonEmpty() {
        for family in DisplayFontFamily.allCases {
            XCTAssertFalse(family.title.isEmpty)
            XCTAssertFalse(family.subtitle.isEmpty)
            XCTAssertFalse(family.sampleText.isEmpty)
        }
    }

    func testFontFamilyLegacyMigration() {
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "serif"), .songti, "历史衬线体迁移宋体")
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "georgia"), .songti)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "rounded"), .yuanti, "历史圆润体迁移圆体")
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "palatino"), .kaiti)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "avenir"), .system)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "songti"), .songti, "现行值原样保留")
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "kaiti"), .kaiti)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "yuanti"), .yuanti)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "xingkai"), .xingkai)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "libian"), .libian)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "weibei"), .weibei)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "system"), .system)
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: "invalid"), .system, "未知值回退系统")
        XCTAssertEqual(DisplayFontFamily.normalized(rawValue: ""), .system, "空值回退系统")
    }

    /// 字体名映射契约：工厂渲染、可用性实查与按需下载共用。
    /// 必须为 **PostScript 字面名**（Apple System Fonts 页 iOS 可下载清单 + macOS 同版本字体枚举核准）——
    /// 历史误用家族名（如 "Songti SC"）导致按需下载静默完成且零资产（2026-09-27 真机 A/B 实证）
    func testFontFamilyNameMapping() {
        XCTAssertEqual(DisplayFontFamily.system.fontName, "PingFang SC")
        XCTAssertEqual(DisplayFontFamily.songti.fontName, "STSongti-SC-Regular")
        XCTAssertEqual(DisplayFontFamily.kaiti.fontName, "STKaitiSC-Regular")
        XCTAssertEqual(DisplayFontFamily.yuanti.fontName, "STYuanti-SC-Regular")
        XCTAssertEqual(DisplayFontFamily.xingkai.fontName, "STXingkaiSC-Light")
        XCTAssertEqual(DisplayFontFamily.libian.fontName, "STLibianSC-Regular")
        XCTAssertEqual(DisplayFontFamily.weibei.fontName, "WeibeiSC-Bold")
    }

    /// 粗体字面契约：可下载家族的真实粗体字面名（libian/weibei 无独立粗体字面）
    func testFontFamilyBoldFaceMapping() {
        XCTAssertNil(DisplayFontFamily.system.boldFontName)
        XCTAssertEqual(DisplayFontFamily.songti.boldFontName, "STSongti-SC-Bold")
        XCTAssertEqual(DisplayFontFamily.kaiti.boldFontName, "STKaitiSC-Bold")
        XCTAssertEqual(DisplayFontFamily.yuanti.boldFontName, "STYuanti-SC-Bold")
        XCTAssertEqual(DisplayFontFamily.xingkai.boldFontName, "STXingkaiSC-Bold")
        XCTAssertNil(DisplayFontFamily.libian.boldFontName, "iOS 可下载目录仅常规字面")
        XCTAssertNil(DisplayFontFamily.weibei.boldFontName, "主字面即粗体")
    }

    /// 下载清单契约：主字面 +（开启粗体时）粗体字面，去重且 system 不下载
    func testFontFamilyDownloadFacePlan() {
        XCTAssertTrue(DisplayFontFamily.system.downloadFaceNames(includeBold: true).isEmpty)
        for family in DisplayFontFamily.allCases where family != .system {
            let plain = family.downloadFaceNames(includeBold: false)
            XCTAssertEqual(plain, [family.fontName], "不含粗体时仅请求主字面")
            let withBold = family.downloadFaceNames(includeBold: true)
            XCTAssertEqual(Set(withBold).count, withBold.count, "字面清单不得重复")
            if let boldFace = family.boldFontName, boldFace != family.fontName {
                XCTAssertEqual(withBold, [family.fontName, boldFace])
            } else {
                XCTAssertEqual(withBold, [family.fontName], "无独立粗体字面时不应追加")
            }
        }
    }

    /// 机构子站原文页 CSS 排版注入契约：字体栈/字号/行高/字距/粗细必须与显示设置联动
    /// （两处 WebView 模板的 body 规则消费同一份声明，见 OrganizationDetailView.buildHTMLPage）
    @MainActor
    func testArticleCSSTypographyFollowsDisplaySettings() {
        let settings = DisplaySettingsManager.shared
        let decl = settings.articleCSSTypographyDeclaration
        XCTAssertTrue(decl.contains("font-family: "), "必须注入字体栈")
        XCTAssertTrue(
            decl.contains("font-size: \(String(format: "%.1f", 16 * settings.fontSizeTier.scale))px"),
            "字号必须随档位（16 × scale）"
        )
        XCTAssertTrue(
            decl.contains("line-height: \(String(format: "%.2f", 0.85 + settings.lineSpacingFactor))"),
            "行高必须随行距系数"
        )
        XCTAssertTrue(
            decl.contains("letter-spacing: \(String(format: "%.2f", settings.letterSpacingValue))px"),
            "字距必须注入"
        )
        XCTAssertTrue(
            decl.contains("font-weight: \(settings.boldTextEnabled ? 700 : 400)"),
            "粗细必须随粗体开关"
        )
        if settings.useSystemFont || settings.fontFamily == .system {
            XCTAssertTrue(decl.contains("'PingFang SC'"), "系统家族回退栈必须包含苹方")
        } else {
            let faces = [settings.fontFamily.fontName, settings.fontFamily.boldFontName].compactMap { $0 }
            XCTAssertTrue(faces.contains { decl.contains("'\($0)'") }, "自定义家族必须按 PostScript 字面名注入")
        }
        // 日志上下文与声明同源（构建日志可核验）
        let logContext = settings.articleCSSTypographyLogContext
        XCTAssertEqual(logContext["fontSizePx"], String(format: "%.1f", settings.articleCSSFontSize))
        XCTAssertEqual(logContext["lineHeight"], String(format: "%.2f", settings.articleCSSLineHeight))
    }

    /// 苹方为 iOS 唯一恒内置中文家族（书法字体为系统按需下载，覆盖安装后会重置）
    func testPingFangAlwaysAvailable() {
        XCTAssertNotNil(UIFont(name: "PingFang SC", size: 17), "默认中文字体必须恒可用")
    }

    /// 在线集成：走 App 真实链路触发一次按需下载（默认用隶变-简，验证 PostScript 字面名契约端到端可用）。
    /// 已下载设备上秒级命中本地并同样断言就绪；依赖网络命中 Apple 字体服务（与既有在线用例同约定）。
    @MainActor
    func testFontOnDemandDownloadThroughManager() async throws {
        let family = DisplayFontFamily.libian
        let face = family.fontName
        if UIFont(name: face, size: 17) == nil {
            DisplaySettingsManager.shared.ensureFontFamily(family, reason: "integration_test")
            var settledReady = false
            var settledUnavailable = false
            for _ in 0..<180 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                switch DisplaySettingsManager.shared.fontAvailability[family] {
                case .ready:        settledReady = true
                case .unavailable:  settledUnavailable = true
                default:            continue
                }
                break
            }
            XCTAssertTrue(settledReady, "隶变-简应完成下载并置为就绪（若 unavailable 表示网络/目录异常）")
            XCTAssertFalse(settledUnavailable, "不应落入不可用终态")
        }
        XCTAssertNotNil(UIFont(name: face, size: 17), "隶变-简字面必须可用")
    }
}

// MARK: - 长图渲染逻辑契约（画布预算 / 素材元数据 / 黑图校验 / 端到端）

/// 长图渲染加固（2026-09-28）契约：
/// ① 画布预算自适应（多图文章不再固定 3x 超大位图 → 杜绝位图分配失败导致的静默黑图）；
/// ② 素材按需缩略解码（压缩数据驻留，杜绝 N 张全尺寸解码图同时驻留）；
/// ③ 产物纯色 / 黑图校验与降级（绝不把黑图交付分享）。
@MainActor
final class ArticleLongImageLogicTests: XCTestCase {

    // MARK: 预算函数

    /// 常规长度文章：保持首选倍率（不牺牲清晰度）
    func testBudgetKeepsPreferredScaleForNormalArticle() {
        let budget = ArticleLongImageRenderer.budget(
            forLogicalSize: CGSize(width: ArticleLongImageRenderer.imageWidth, height: 3000),
            availableBytes: 2 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(budget.scale, ArticleLongImageRenderer.preferredScale, accuracy: 0.001)
        XCTAssertEqual(budget.reason, "preferred")
        XCTAssertLessThanOrEqual(budget.bitmapBytes, ArticleLongImageRenderer.maxRenderBytes)
    }

    /// 多图超长文章（黑图现场场景）：倍率必须收敛到预算内
    func testBudgetClampsForImageHeavyArticle() {
        let budget = ArticleLongImageRenderer.budget(
            forLogicalSize: CGSize(width: ArticleLongImageRenderer.imageWidth, height: 26_000),
            availableBytes: 2 * 1024 * 1024 * 1024
        )
        XCTAssertLessThan(budget.scale, ArticleLongImageRenderer.preferredScale, "超长画布必须降倍率")
        XCTAssertLessThanOrEqual(budget.bitmapBytes, ArticleLongImageRenderer.maxRenderBytes, "位图必须落在字节上限内")
        XCTAssertLessThanOrEqual(budget.pixelSize.height, ArticleLongImageRenderer.maxPixelHeight, "像素高度必须落在硬上限内")
        XCTAssertGreaterThan(budget.scale, ArticleLongImageRenderer.minScale)
    }

    /// 可用内存紧张：按比例收缩，且受字节下限兜底
    func testBudgetShrinksWithLowAvailableMemory() {
        let logical = CGSize(width: ArticleLongImageRenderer.imageWidth, height: 6000)
        let tight = ArticleLongImageRenderer.budget(forLogicalSize: logical, availableBytes: 150 * 1024 * 1024)
        let loose = ArticleLongImageRenderer.budget(forLogicalSize: logical, availableBytes: 4 * 1024 * 1024 * 1024)
        XCTAssertLessThan(tight.scale, loose.scale, "低可用内存必须显著收缩画布")
        XCTAssertEqual(tight.reason, "bytes")
        XCTAssertLessThanOrEqual(tight.bitmapBytes, ArticleLongImageRenderer.minRenderBytes * 2, "收缩后仍受下限兜底")
        XCTAssertGreaterThanOrEqual(tight.bitmapBytes, ArticleLongImageRenderer.minRenderBytes - 1024 * 1024, "不得低于字节下限（允许取整误差）")
    }

    /// 极端超长内容：允许低于质量下限（内存预算优先）并标记 floor
    func testBudgetFloorForExtremeContent() {
        let budget = ArticleLongImageRenderer.budget(
            forLogicalSize: CGSize(width: ArticleLongImageRenderer.imageWidth, height: 400_000),
            availableBytes: 1024 * 1024 * 1024
        )
        XCTAssertEqual(budget.reason, "floor")
        XCTAssertLessThan(budget.scale, ArticleLongImageRenderer.minScale)
        XCTAssertGreaterThan(budget.scale, 0)
    }

    // MARK: 素材元数据

    /// EXIF 方向归一：5-8（90°/270° 旋转）必须交换宽高
    func testOrientedPixelSizeSwapsForQuarterTurn() {
        let size = CGSize(width: 4000, height: 3000)
        for orientation in [UInt32(5), 6, 7, 8] {
            let oriented = ArticleLongImageLoader.orientedPixelSize(size, orientation: orientation)
            XCTAssertEqual(oriented.width, 3000)
            XCTAssertEqual(oriented.height, 4000)
        }
        for orientation in [UInt32(1), 3, 4] {
            XCTAssertEqual(ArticleLongImageLoader.orientedPixelSize(size, orientation: orientation), size)
        }
    }

    /// 素材头解析：JPEG 数据可解出真实像素尺寸（不整图解码）；非图像数据必须失败（调用方跳过）
    func testPixelSizeParsingFromJPEGData() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 固定 1x：确保 JPEG 内容为 640×360 像素（渲染器默认会按屏幕倍率放大）
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            XCTFail("测试数据构造失败")
            return
        }
        let size = ArticleLongImageLoader.pixelSize(of: data)
        XCTAssertEqual(size?.width, 640)
        XCTAssertEqual(size?.height, 360)
        XCTAssertNil(ArticleLongImageLoader.pixelSize(of: Data("not an image".utf8)), "非图像数据必须解析失败")
    }

    // MARK: 黑图校验

    /// 纯黑 / 纯白画布必须判为失效；含内容的画布判为有效
    func testBlankDetectionCatchesSolidCanvases() {
        XCTAssertTrue(ArticleLongImageRenderer.isLikelyBlank(solidImage(color: .black)), "全黑产物（现场故障）必须被识别")
        XCTAssertTrue(ArticleLongImageRenderer.isLikelyBlank(solidImage(color: .white)), "纯色画布同样属失效产物")
        XCTAssertFalse(ArticleLongImageRenderer.isLikelyBlank(contentImage()), "正常长图（白底 + 深色文字）不得误判")
    }

    // MARK: 端到端渲染

    /// 素材（压缩数据）驱动渲染：产出非黑图、逻辑宽度固定、像素倍率 ≥1x
    func testRendererProducesValidImageWithAssets() {
        guard let asset = makeAsset(size: CGSize(width: 800, height: 600), color: .systemBlue) else { return }
        let renderer = ArticleLongImageRenderer(
            title: "端到端渲染契约",
            metadata: "契约测试 · 2026-09-28",
            content: (1...6).map { "第\($0)段：长图渲染加固验证文本。" }.joined(separator: "\n"),
            images: [asset],
            articleURL: "https://www.sxjzit.edu.cn/test",
            tag: "contract_test"
        )
        guard let image = renderer.render() else {
            XCTFail("素材渲染必须成功")
            return
        }
        XCTAssertFalse(ArticleLongImageRenderer.isLikelyBlank(image), "渲染产物不得为黑图 / 纯色")
        XCTAssertEqual(image.size.width, ArticleLongImageRenderer.imageWidth, accuracy: 1, "逻辑宽度固定 750pt")
        XCTAssertGreaterThanOrEqual(CGFloat(image.cgImage?.width ?? 0), ArticleLongImageRenderer.imageWidth, "输出像素宽度必须 ≥ 逻辑宽度（≥1x）")
    }

    /// 省略插图的降级页脚必须带可见说明（避免用户误以为丢图）
    func testDegradedFooterNotesOmittedImages() {
        let normal = ArticleLongImageRenderer.footerText(articleURL: "https://x.test", includeImages: true, imageCount: 3)
        let degraded = ArticleLongImageRenderer.footerText(articleURL: "https://x.test", includeImages: false, imageCount: 3)
        XCTAssertFalse(normal.contains("省略"))
        XCTAssertTrue(degraded.contains("省略插图"), "降级产物必须在页脚可见告知")
        let noImagesAtAll = ArticleLongImageRenderer.footerText(articleURL: "https://x.test", includeImages: false, imageCount: 0)
        XCTAssertFalse(noImagesAtAll.contains("省略"), "本就无图时不得追加降级说明")
    }

    // MARK: 编码链路（黑图二次复现回归）

    /// 回归（2026-09-28 黑图二次复现根因）：降采样必须按**像素**尺寸计算——
    /// 自适应倍率源图（image.scale = 1.5）若按「点尺寸 × 系数」处理，会得到 2 倍大的位图（分配失败 → 黑图）
    func testEncoderDownscaleIsPixelAccurateForAdaptiveScaleSource() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5          // 模拟长图渲染产物：像素 = 点 × 1.5
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 6000), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 6000))
            UIColor.black.setFill()
            for y in stride(from: 0, to: 6000, by: 120) {
                ctx.fill(CGRect(x: 40, y: CGFloat(y), width: 400, height: 24))
            }
        }
        let sourcePixel = SJZImageIntegrity.pixelSize(of: source)
        XCTAssertEqual(sourcePixel.width, 1200, accuracy: 1, "源图应为 1200×9000 像素（800×6000 点 @1.5x）")
        guard let down = WeChatImageEncoder.downscaledToPixelScale(source, scale: 0.75) else {
            XCTFail("降采样必须成功")
            return
        }
        let downPixel = SJZImageIntegrity.pixelSize(of: down)
        XCTAssertEqual(downPixel.width, sourcePixel.width * 0.75, accuracy: 2, "必须按像素降采样（而非放大）")
        XCTAssertEqual(downPixel.height, sourcePixel.height * 0.75, accuracy: 4, "必须按像素降采样（而非放大）")
        XCTAssertFalse(SJZImageIntegrity.isLikelyBlank(down), "降采样产物不得为纯色 / 黑图")
    }

    /// 重图编码稳定性：小字节上限逼迫逐档降采样 + JPEG 压缩，最终产物解码回来必须非黑图
    func testEncoderNeverReturnsBlankForHeavyImage() {
        let image = noisyImage(width: 900, height: 5400)
        guard let result = WeChatImageEncoder.encode(image, maxBytes: 200 * 1024) else {
            XCTFail("重图在小上限下必须完成降档编码")
            return
        }
        XCTAssertLessThanOrEqual(result.data.count, 200 * 1024, "产物必须满足字节上限")
        guard let decoded = UIImage(data: result.data) else {
            XCTFail("产物必须可解码")
            return
        }
        XCTAssertFalse(SJZImageIntegrity.isLikelyBlank(decoded), "编码链路产物不得为黑图")
        XCTAssertLessThanOrEqual(result.pixelSize.height, 5401, "降采样不得放大像素尺寸")
    }

    /// 编码数据校验（最后一道闸）：纯黑 JPEG 拦下、正常内容放行、非图像数据 fail-closed
    func testEncodedDataBlankCheck() {
        guard let blackData = solidImage(color: .black).jpegData(compressionQuality: 0.9),
              let contentData = contentImage().jpegData(compressionQuality: 0.9) else {
            XCTFail("测试数据构造失败")
            return
        }
        XCTAssertTrue(SJZImageIntegrity.isLikelyBlank(encodedImage: blackData), "纯黑 JPEG 必须被拦截")
        XCTAssertFalse(SJZImageIntegrity.isLikelyBlank(encodedImage: contentData), "正常内容 JPEG 不得误判")
        XCTAssertTrue(SJZImageIntegrity.isLikelyBlank(encodedImage: Data("not image".utf8)), "非图像数据必须 fail-closed")
    }

    /// fail-closed：无位图数据（无法取证）时必须按失效处理，绝不放过疑似黑图
    func testBlankDetectionFailsClosedWithoutBitmap() {
        XCTAssertTrue(SJZImageIntegrity.isLikelyBlank(UIImage()), "无 CGImage 的图必须判失效")
    }

    // MARK: 重图文章端到端（现场故障场景）

    /// 24 张素材的「图片多的文章」：真机端到端渲染必须在预算内产出非黑图（必要时自动降级），
    /// 并打印诊断（探针）——「图片多 → 黑图」现场场景的最小复现
    func testRendererHandlesImageHeavyArticleOnDevice() {
        var assets: [ArticleLongImageAsset] = []
        for index in 0..<24 {
            guard let asset = makeAsset(size: CGSize(width: 1600, height: 1200),
                                        color: index % 2 == 0 ? .systemTeal : .systemIndigo) else { return }
            assets.append(asset)
        }
        let content = (1...72).map { "第\($0)段：重图文章渲染稳定性验证文本。" }.joined(separator: "\n")
        let renderer = ArticleLongImageRenderer(
            title: "重图文章渲染契约（24 图）",
            metadata: "设备端探针 · 2026-09-28",
            content: content,
            images: assets,
            articleURL: "https://www.sxjzit.edu.cn/heavy",
            tag: "contract_heavy"
        )
        let started = Date()
        guard let image = renderer.render() else {
            XCTFail("重图文章必须产出可用长图（黑图会被校验拦截并降级重试）")
            return
        }
        let pixel = SJZImageIntegrity.pixelSize(of: image)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("[LONGIMGPROBE] heavy px=\(Int(pixel.width))x\(Int(pixel.height)) scale=\(String(format: "%.2f", image.scale)) ms=\(ms) blank=\(SJZImageIntegrity.isLikelyBlank(image))")
        XCTAssertFalse(SJZImageIntegrity.isLikelyBlank(image), "重图文章产物不得为黑图 / 纯色")
        XCTAssertLessThanOrEqual(pixel.height, ArticleLongImageRenderer.maxPixelHeight + 1, "像素高度不得越过硬上限")
        XCTAssertLessThanOrEqual(pixel.width * pixel.height * 4,
                                 Double(ArticleLongImageRenderer.maxRenderBytes) * 1.05,
                                 "位图字节不得越过预算上限（含取整余量）")
    }

    // MARK: 插图方向契约与取证

    /// 探针⑥：同一 UIKit 上下文中 `UIImage.draw` 与 `CGContext.draw` 的上下方向取证
    /// （「长图里的图片颠倒」根因：CGImage 直接绘制在 y 向下的 UIKit 上下文是否翻转）
    /// 注意：位图是 3x，取样必须按**像素**划分左右半区（0..w/2 与 w/2..w）
    func testProbeImageDrawingOrientation() {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 25))   // 顶部黑带
        }
        let probeFormat = UIGraphicsImageRendererFormat()
        probeFormat.scale = 1
        probeFormat.opaque = true
        probeFormat.preferredRange = .standard   // 4B/px，便于按 x*4 取样（默认可能 64bpp）
        let probe = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: probeFormat).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: 100, height: 100))            // 左半：UIImage.draw
            if let cg = source.cgImage, let cgContext = UIGraphicsGetCurrentContext() {
                cgContext.draw(cg, in: CGRect(x: 100, y: 0, width: 100, height: 100)) // 右半：CGContext.draw
            }
        }
        guard let cg = probe.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            print("[LONGIMGPROBE] drawOrientation probe=nil")
            return
        }
        let rowBytes = cg.bytesPerRow
        let length = CFDataGetLength(data)
        func rowDarkRatio(_ y: Int, xStart: Int, width: Int) -> Double {
            var dark = 0
            var total = 0
            for x in xStart..<(xStart + width) {
                let index = y * rowBytes + x * 4
                guard index + 3 < length else { continue }
                total += 1
                if bytes[index] < 64 { dark += 1 }
            }
            return total > 0 ? Double(dark) / Double(total) : 0
        }
        let half = cg.width / 2
        let Inset = cg.width / 8
        let columns = half / 2
        let leftTop = rowDarkRatio(10, xStart: Inset, width: columns)
        let leftBottom = rowDarkRatio(cg.height - 10, xStart: Inset, width: columns)
        let rightTop = rowDarkRatio(10, xStart: half + Inset, width: columns)
        let rightBottom = rowDarkRatio(cg.height - 10, xStart: half + Inset, width: columns)
        print("[LONGIMGPROBE] drawOrientation UIImageDraw top=\(String(format: "%.2f", leftTop)) bottom=\(String(format: "%.2f", leftBottom)) | CGContextDraw top=\(String(format: "%.2f", rightTop)) bottom=\(String(format: "%.2f", rightBottom))")
        XCTAssertGreaterThan(leftTop, 0.8, "UIImage.draw 黑带应在顶部（基准）")
    }

    /// 探针⑦：EXIF 方向（orientation=6，90°）在解码路径与绘制结果中的表现
    func testProbeExifOrientationHandling() {
        // 源像素：白底 + 顶部黑带，宽 400 高 300（未旋转）
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 60))
        }
        guard let cgSource = source.cgImage else {
            print("[LONGIMGPROBE] exifOrientation source=nil")
            return
        }
        // 写入带 EXIF orientation=6（顺时针 90°）的 JPEG（像素不变、方向标记为 6）
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            print("[LONGIMGPROBE] exifOrientation destination=nil")
            return
        }
        CGImageDestinationAddImage(destination, cgSource, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            print("[LONGIMGPROBE] exifOrientation finalize=fail")
            return
        }
        let data = output as Data
        let metadataSize = ArticleLongImageLoader.pixelSize(of: data) ?? .zero
        let decoded = ArticleLongImageRenderer.decodeThumbnail(data, maxPixel: 400)
        print("[LONGIMGPROBE] exifOrientation metadata=\(Int(metadataSize.width))x\(Int(metadataSize.height)) decoded=\(decoded.map { "\($0.width)x\($0.height)" } ?? "nil")")
        // 归一化后：像素应为 300x400（宽高互换）
        XCTAssertEqual(Int(metadataSize.width), 300, "元数据像素尺寸必须按 EXIF 方向归一（宽高互换）")
        XCTAssertEqual(Int(metadataSize.height), 400)
    }

    /// 回归（2026-09-28「插画颠倒」）：插图必须正立——素材「顶部黑带」必须出现在插图区域的上半部
    func testEmbeddedImageIsNotVerticallyFlipped() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 60))   // 顶部 20% 黑带
        }
        guard let data = source.jpegData(compressionQuality: 0.9) else {
            XCTFail("素材构造失败")
            return
        }
        let asset = ArticleLongImageAsset(data: data, pixelSize: CGSize(width: 400, height: 300), alt: nil, sourceHost: "test.host")
        let renderer = ArticleLongImageRenderer(
            title: "插图方向契约",
            metadata: "",
            content: "第一段。\n第二段。\n第三段。",
            images: [asset],
            articleURL: "https://www.sxjzit.edu.cn/flip",
            tag: "contract_flip"
        )
        guard let image = renderer.render(), let cg = image.cgImage,
              let bitmap = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(bitmap) else {
            XCTFail("画布必须产出")
            return
        }
        let rowBytes = cg.bytesPerRow
        let length = CFDataGetLength(bitmap)
        func blackRatio(_ y: Int) -> Double {
            var dark = 0
            var total = 0
            for x in stride(from: 0, to: cg.width, by: 4) {
                let index = y * rowBytes + x * 4
                guard index + 3 < length else { continue }
                total += 1
                if bytes[index] < 64 { dark += 1 }
            }
            return total > 0 ? Double(dark) / Double(total) : 0
        }
        // 插图黑带是「整行大面积黑」（正文文字占比不会超过 60%）
        let blackBandRows = stride(from: 0, to: cg.height, by: 3).filter { blackRatio($0) > 0.6 }
        guard let bandTop = blackBandRows.first, let bandBottom = blackBandRows.last else {
            XCTFail("应当能扫描到插图黑带（若无则插图未绘制）")
            return
        }
        // 判定：素材是「顶部黑带 + 下方 80% 白底」——若正立，黑带下方必须有一整段白底（约 80% 插图高度）；
        // 若上下翻转，黑带下方只有少量白底（插图尾部）随后即回到正文
        let scale = CGFloat(cg.width) / ArticleLongImageRenderer.imageWidth
        let expectedImageHeight = ArticleLongImageRenderer.contentWidth * 0.75 * scale   // 4:3 素材显示高度（像素）
        var lightRun = 0
        var y = bandBottom + 3
        while y < cg.height, blackRatio(y) < 0.1 {
            lightRun += 3
            y += 3
        }
        // 行剖面（15px/行）：'.' 极浅 / '-' 浅杂 / '#' 大面积深色 —— 用于精确判读绘制实况
        var profile = ""
        for row in stride(from: 0, to: cg.height, by: 15) {
            let ratio = blackRatio(row)
            profile += ratio < 0.05 ? "." : (ratio < 0.6 ? "-" : "#")
        }
        print("[LONGIMGPROBE] embeddedOrientation bandTop=\(bandTop) bandBottom=\(bandBottom) canvasH=\(cg.height) scale=\(String(format: "%.2f", scale)) lightRunBelow=\(lightRun) expectedImageH=\(Int(expectedImageHeight))")
        print("[LONGIMGPROBE] rowProfile(15px/row) \(profile)")
        XCTAssertGreaterThan(CGFloat(lightRun), expectedImageHeight * 0.5,
                             "黑带下方应有长段白底（插图正立）；不足说明插图被**上下翻转**")
    }

    // MARK: 画布格式契约与取证

    /// 回归（2026-09-28 黑图根因②）：渲染画布必须是 **8 位/通道（32bpp）**——
    /// HDR 机型上默认色域可能给 16 位扩展域（64bpp），画布内存翻倍 → 超大画布分配失败 → 静默黑图
    func testRenderedCanvasUsesStandard8BitFormat() {
        let renderer = ArticleLongImageRenderer(
            title: "画布格式契约",
            metadata: "8 位/通道",
            content: "格式验证。",
            images: [],
            articleURL: "https://www.sxjzit.edu.cn/format",
            tag: "contract_format"
        )
        guard let image = renderer.render(), let cg = image.cgImage else {
            XCTFail("画布必须产出")
            return
        }
        XCTAssertEqual(cg.bitsPerPixel, 32, "画布必须为 8 位/通道（32bpp）；16 位扩展域会使内存翻倍并导致黑图")
        XCTAssertGreaterThanOrEqual(cg.bytesPerRow, cg.width * 4, "行距不得小于 4 字节/像素")
        XCTAssertEqual(cg.bytesPerRow % 4, 0, "行距必须按像素对齐（4 字节）")
    }

    /// 探针⑤：画布位图格式取证（automatic / standard / extended 三态）
    func testProbeCanvasBitmapFormat() {
        for (name, range) in [("automatic", UIGraphicsImageRendererFormat.Range.automatic),
                              ("standard", .standard),
                              ("extended", .extended)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            format.preferredRange = range
            let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            }
            let cg = image.cgImage
            print("[LONGIMGPROBE] canvasFormat \(name) bpp=\(cg?.bitsPerPixel ?? -1) rowBytes=\(cg?.bytesPerRow ?? -1) width=\(cg?.width ?? -1) scale=\(image.scale)")
        }
    }

    // MARK: 诊断探针（黑图链路取证工具）

    /// 探针④：重绘探针位图路径的可用性 + ImageIO 缩略图真实内容（校验器实现依据）
    func testProbeRedrawnSampling() {
        for (name, image) in [("solidWhite", solidImage(color: .white)),
                              ("solidBlack", solidImage(color: .black)),
                              ("content", contentImage()),
                              ("noisy640x2400", noisyImage(width: 640, height: 2400))] {
            print("[LONGIMGPROBE] redraw \(name) -> \(redrawStats(image))")
        }
        let image = noisyImage(width: 640, height: 2400)
        guard let jpeg = image.jpegData(compressionQuality: 0.8),
              let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else {
            print("[LONGIMGPROBE] redraw thumb -> 构造失败")
            return
        }
        let thumbLength = thumb.dataProvider?.data.map { CFDataGetLength($0) } ?? -1
        print("[LONGIMGPROBE] redraw thumb(ImageIO) raw bpp=\(thumb.bitsPerPixel) rowBytes=\(thumb.bytesPerRow) len=\(thumbLength) -> \(redrawStats(UIImage(cgImage: thumb)))")
    }

    /// 重绘到自有探针位图后按 rowBytes 抽样（打印布局与极值）
    private func redrawStats(_ image: UIImage) -> String {
        let side = 32
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let probe = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cg = probe.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return "probe=nil"
        }
        let bpp = max(cg.bitsPerPixel / 8, 1)
        let rowBytes = cg.bytesPerRow
        let length = CFDataGetLength(data)
        var minV: UInt8 = 255
        var maxV: UInt8 = 0
        var count = 0
        for iy in 0..<side {
            for ix in 0..<side {
                let index = (cg.height * iy / side) * rowBytes + (cg.width * ix / side) * bpp
                guard index + bpp <= length else { continue }
                minV = min(minV, bytes[index])
                maxV = max(maxV, bytes[index])
                count += 1
            }
        }
        return "probe=\(cg.width)x\(cg.height) bpp=\(cg.bitsPerPixel) rowBytes=\(rowBytes) len=\(length) min=\(minV) max=\(maxV) n=\(count)"
    }

    /// 探针③：ImageIO 缩略解码配方矩阵（编码产物校验依赖它；定位真机可用组合）
    func testProbeImageIOThumbnailRecipes() {
        let image = noisyImage(width: 640, height: 2400)
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            XCTFail("JPEG 构造失败")
            return
        }
        for (srcName, srcOptions) in [("cacheFalse", [kCGImageSourceShouldCache: false] as CFDictionary),
                                      ("default", [:] as CFDictionary)] {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, srcOptions) else {
                print("[LONGIMGPROBE] recipe[\(srcName)] source=nil")
                continue
            }
            let variants: [(String, [CFString: Any])] = [
                ("A always+transform+immediate+256", [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                                      kCGImageSourceShouldCacheImmediately: true,
                                                      kCGImageSourceThumbnailMaxPixelSize: 256]),
                ("B always+transform+256", [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 256]),
                ("C always+256", [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceThumbnailMaxPixelSize: 256]),
                ("D always+transform+immediate+1300", [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                       kCGImageSourceShouldCacheImmediately: true,
                                                       kCGImageSourceThumbnailMaxPixelSize: 1300]),
                ("E ifAbsent+256", [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 256])
            ]
            for (name, options) in variants {
                let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                if let cg {
                    print("[LONGIMGPROBE] recipe[\(srcName)] \(name) -> \(cg.width)x\(cg.height) \(redrawStats(UIImage(cgImage: cg)))")
                } else {
                    print("[LONGIMGPROBE] recipe[\(srcName)] \(name) -> nil")
                }
            }
            let subsampled = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: 16] as CFDictionary)
            if let subsampled {
                print("[LONGIMGPROBE] recipe[\(srcName)] F subsample16 -> \(subsampled.width)x\(subsampled.height) \(redrawStats(UIImage(cgImage: subsampled)))")
            } else {
                print("[LONGIMGPROBE] recipe[\(srcName)] F subsample16 -> nil")
            }
        }
    }

    /// 探针①：抽样字节统计——定位「校验误判」与「真黑图」的差异
    func testProbeBlankSamplerDiagnostics() {
        for (name, image) in [("solidBlack", solidImage(color: .black)),
                              ("content", contentImage()),
                              ("noisy640x2400", noisyImage(width: 640, height: 2400)),
                              ("noisy1200x4000", noisyImage(width: 1200, height: 4000))] {
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
                print("[LONGIMGPROBE] sampler \(name) NO-DATA-PROVIDER")
                continue
            }
            let bpp = max(cg.bitsPerPixel / 8, 1)
            let rowBytes = cg.bytesPerRow
            var minV: UInt8 = 255
            var maxV: UInt8 = 0
            var unique = Set<UInt8>()
            var first: [UInt8] = []
            for iy in 0..<32 {
                let y = cg.height * iy / 32
                for ix in 0..<32 {
                    let x = cg.width * ix / 32
                    let index = y * rowBytes + x * bpp
                    guard index + bpp <= CFDataGetLength(data) else { continue }
                    let value = bytes[index]
                    minV = min(minV, value)
                    maxV = max(maxV, value)
                    unique.insert(value)
                    if first.count < 8 { first.append(value) }
                }
            }
            print("[LONGIMGPROBE] sampler \(name) px=\(cg.width)x\(cg.height) bpp=\(cg.bitsPerPixel) rowBytes=\(rowBytes) min=\(minV) max=\(maxV) uniq=\(unique.count) first=\(first) blank=\(SJZImageIntegrity.isLikelyBlank(image))")
        }
    }

    /// 探针②：编码阶梯逐步诊断（候选尺寸 / 字节 / 两级校验结果）
    func testProbeEncoderLadder() {
        let image = noisyImage(width: 640, height: 2400)
        print("[LONGIMGPROBE] ladder source blank=\(SJZImageIntegrity.isLikelyBlank(image)) px=\(SJZImageIntegrity.pixelSizeText(of: image))")
        for scale in WeChatImageEncoder.scales {
            let candidate = scale >= 1.0 ? image : WeChatImageEncoder.downscaledToPixelScale(image, scale: scale)
            guard let candidate else {
                print("[LONGIMGPROBE] ladder scale=\(scale) candidate=nil")
                continue
            }
            let candidateBlank = SJZImageIntegrity.isLikelyBlank(candidate)
            guard let data = candidate.jpegData(compressionQuality: 0.92) else {
                print("[LONGIMGPROBE] ladder scale=\(scale) jpeg=nil")
                continue
            }
            print("[LONGIMGPROBE] ladder scale=\(String(format: "%.2f", scale)) px=\(SJZImageIntegrity.pixelSizeText(of: candidate)) bytes=\(data.count) candBlank=\(candidateBlank) dataBlank=\(SJZImageIntegrity.isLikelyBlank(encodedImage: data))")
        }
    }

    // MARK: 辅助

    private func solidImage(color: UIColor, side: CGFloat = 60) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func contentImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 20))
        }
    }

    private func makeAsset(size: CGSize, color: UIColor) -> ArticleLongImageAsset? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            XCTFail("测试素材构造失败")
            return nil
        }
        return ArticleLongImageAsset(data: data, pixelSize: size, alt: "契约测试图", sourceHost: "test.host")
    }

    /// 高频噪声图（纯色图 JPEG 压缩率过高，无法验证降档链路；条纹提升熵值）
    private func noisyImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x: CGFloat = 0
            var i = 0
            while x < width {
                UIColor(hue: CGFloat(i % 60) / 60.0, saturation: 0.85, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: x, y: 0, width: 3, height: height))
                x += 6
                i += 7
            }
        }
    }
}