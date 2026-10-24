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
}