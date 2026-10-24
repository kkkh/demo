//
//  BookmarkManagerTests.swift
//  山西晋中理工学院 APP — 收藏管理器 / 已读状态 单元测试
//
//  覆盖：增删/去重/上限、文件存储往返、旧版 UserDefaults 迁移、
//  存储损坏逐条抢救与完全自愈、纯函数（筛选 / 排序 / 时间分组 / 更新判定）、
//  最近阅读记录与更新徽标清除、批量与清空计数、存储快照统计、
//  图片固化缓存（写入 → 读回 → 清理）、设置持久化；
//  以及已读状态管理（回退未读 / 快照 / 保序截断）。
//
//  全部用例注入临时目录 + 独立 UserDefaults suite，互不污染。
//

import XCTest
@testable import DesignCode
import UIKit

@MainActor
final class BookmarkManagerTests: XCTestCase {

    private var tempDir: URL!
    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BookmarkTests.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)!
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        suiteDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: 工厂

    private func makeManager() -> BookmarkManager {
        BookmarkManager(defaults: suiteDefaults,
                        storageDirectory: tempDir.appendingPathComponent("storage", isDirectory: true),
                        cacheDirectory: tempDir.appendingPathComponent("images", isDirectory: true))
    }

    private var storageFileURL: URL {
        tempDir.appendingPathComponent("storage/bookmarks.json")
    }

    private func makeItem(_ index: Int, category: String = "学校要闻", articleId: String? = nil) -> NewsItem {
        NewsItem(title: "测试文章\(index)", date: "2026-09-0\(index)", category: category,
                 summary: "摘要\(index)", content: "正文\(index)",
                 imageUrl: nil, articleId: articleId)
    }

    private func makeBookmark(title: String, articleId: String, cachedContent: String? = nil,
                              contentCached: Bool = false) -> BookmarkItem {
        BookmarkItem(title: title, date: "2026-01-01", category: "学校要闻", summary: "摘要",
                     articleId: articleId, cachedContent: cachedContent, contentCached: contentCached)
    }

    /// 预置存储文件（模拟上次会话落盘数据）
    private func writeStorageFile(_ items: [BookmarkItem]) throws {
        let dir = storageFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: storageFileURL)
    }

    // MARK: 增删 / 去重 / 上限

    func testAddBookmarkInsertsFrontAndDeduplicates() {
        let manager = makeManager()
        manager.addBookmark(makeItem(1))
        manager.addBookmark(makeItem(2))
        XCTAssertEqual(manager.count, 2)
        XCTAssertEqual(manager.bookmarks.first?.title, "测试文章2")
        XCTAssertTrue(manager.isBookmarked(makeItem(2)))

        // 重复收藏同一文章不得产生新条目
        manager.addBookmark(makeItem(1))
        XCTAssertEqual(manager.count, 2)
    }

    func testAddBookmarkRespectsMaxCountLimit() {
        let manager = makeManager()
        manager.maxCount = 2
        manager.addBookmark(makeItem(1))
        manager.addBookmark(makeItem(2))
        manager.addBookmark(makeItem(3))

        XCTAssertEqual(manager.count, 2)
        XCTAssertTrue(manager.showLimitAlert)
        XCTAssertTrue(manager.limitAlertMessage.contains("上限"))
        XCTAssertFalse(manager.isBookmarked(makeItem(3)))
    }

    func testRemoveBookmarksReturnsRemovedCount() {
        let manager = makeManager()
        (1...3).forEach { manager.addBookmark(makeItem($0)) }
        let keys = Set(manager.bookmarks.prefix(2).map(\.readKey))

        XCTAssertEqual(manager.removeBookmarks(keys), 2)
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.removeBookmarks(["不存在的键"]), 0)
    }

    func testClearAllReturnsCountAndEmpties() {
        let manager = makeManager()
        (1...3).forEach { manager.addBookmark(makeItem($0)) }
        XCTAssertEqual(manager.clearAll(), 3)
        XCTAssertEqual(manager.count, 0)
        XCTAssertEqual(manager.clearAll(), 0)
    }

    // MARK: 持久化 / 迁移 / 抢救

    func testPersistenceRoundTripViaFileStorage() {
        let manager = makeManager()
        (1...3).forEach { manager.addBookmark(makeItem($0)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageFileURL.path))

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.count, 3)
        XCTAssertEqual(reloaded.bookmarks.map(\.title), manager.bookmarks.map(\.title))
    }

    func testLegacyUserDefaultsMigration() throws {
        let legacy = [makeBookmark(title: "旧数据", articleId: "legacy-1")]
        suiteDefaults.set(try JSONEncoder().encode(legacy), forKey: BookmarkManager.legacyBookmarksKey)

        let manager = makeManager()
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.bookmarks.first?.title, "旧数据")
        // 迁移后落盘为新文件存储，并清除旧键
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageFileURL.path))
        XCTAssertNil(suiteDefaults.data(forKey: BookmarkManager.legacyBookmarksKey))
    }

    func testCorruptedStorageRescuesValidItems() throws {
        // 数组内一条合法 + 一条字段类型损坏 → 逐条抢救，保留合法条目
        let validJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeBookmark(title: "合法", articleId: "ok-1")))
        let payload: [Any] = [validJSON, ["title": 12345, "broken": true]]
        let dir = storageFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload).write(to: storageFileURL)

        let manager = makeManager()
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.bookmarks.first?.title, "合法")
    }

    func testCorruptedStorageFallsBackToLegacy() throws {
        let dir = storageFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("这不是合法 JSON".utf8).write(to: storageFileURL)
        suiteDefaults.set(try JSONEncoder().encode([makeBookmark(title: "迁移数据", articleId: "lg-1")]),
                          forKey: BookmarkManager.legacyBookmarksKey)

        let manager = makeManager()
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.bookmarks.first?.title, "迁移数据")
    }

    func testCompletelyCorruptedStorageYieldsEmpty() throws {
        let dir = storageFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{损坏数据}".utf8).write(to: storageFileURL)

        let manager = makeManager()
        XCTAssertEqual(manager.count, 0)
    }

    // MARK: 最近阅读 / 更新徽标

    func testMarkViewedSetsLastViewed() {
        let manager = makeManager()
        manager.addBookmark(makeItem(1))
        let key = manager.bookmarks[0].readKey
        XCTAssertNil(manager.bookmarks[0].lastViewedAt)

        manager.markViewed(key)
        XCTAssertNotNil(manager.bookmarks[0].lastViewedAt)
    }

    func testMarkViewedClearsPendingUpdateBadge() throws {
        var item = makeBookmark(title: "更新文章", articleId: "up-1", cachedContent: "旧正文", contentCached: true)
        item.updateDetectedAt = Date()
        try writeStorageFile([item])

        let manager = makeManager()
        XCTAssertTrue(manager.bookmarks[0].hasPendingUpdate)

        manager.markViewed(item.readKey)
        XCTAssertFalse(manager.bookmarks[0].hasPendingUpdate)
        XCTAssertNotNil(manager.bookmarks[0].lastViewedAt)
    }

    // MARK: 纯函数：筛选 / 排序 / 分组 / 更新判定

    func testFilterByQueryAndScope() {
        let items = [
            BookmarkItem(title: "学术讲座", date: "2026-09-01", category: "学校要闻",
                         summary: "人工智能专题", articleId: "f1"),
            BookmarkItem(title: "招生简章", date: "2026-09-02", category: "招生信息",
                         summary: "2026 年招生", articleId: "f2"),
            BookmarkItem(title: "校园活动", date: "2026-09-03", category: "院部动态",
                         summary: "运动会", articleId: "f3", cachedContent: "正文", contentCached: true)
        ]

        // 关键词命中标题
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "招生", scope: .all, sort: .recentlyBookmarked, readKeys: []).map(\.readKey),
            ["f2"])
        // 关键词命中摘要
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "人工智能", scope: .all, sort: .recentlyBookmarked, readKeys: []).map(\.readKey),
            ["f1"])
        // 未读筛选（f2 已读）
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .unread, sort: .recentlyBookmarked, readKeys: ["f2"]).map(\.readKey).sorted(),
            ["f1", "f3"])
        // 可离线筛选
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .offlineReady, sort: .recentlyBookmarked, readKeys: []).map(\.readKey),
            ["f3"])
        // 分类筛选
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .category("招生信息"), sort: .recentlyBookmarked, readKeys: []).map(\.readKey),
            ["f2"])
    }

    func testSortOrders() {
        let now = Date()
        let items = [
            BookmarkItem(title: "B 文章", date: "2026-09-02", category: "c", summary: "s",
                         articleId: "s1", bookmarkDate: now.addingTimeInterval(-100), lastViewedAt: now.addingTimeInterval(-50)),
            BookmarkItem(title: "A 文章", date: "2026-09-03", category: "c", summary: "s",
                         articleId: "s2", bookmarkDate: now.addingTimeInterval(-300)),
            BookmarkItem(title: "C 文章", date: "2026-09-01", category: "c", summary: "s",
                         articleId: "s3", bookmarkDate: now.addingTimeInterval(-200), lastViewedAt: now)
        ]

        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .all, sort: .recentlyBookmarked, readKeys: []).map(\.readKey),
            ["s1", "s3", "s2"])
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .all, sort: .recentlyPublished, readKeys: []).map(\.readKey),
            ["s2", "s1", "s3"])
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .all, sort: .recentlyViewed, readKeys: []).map(\.readKey),
            ["s3", "s1", "s2"])
        XCTAssertEqual(
            BookmarkManager.filter(items, query: "", scope: .all, sort: .titleAscending, readKeys: []).map(\.readKey),
            ["s2", "s1", "s3"])
    }

    func testTimeGroupSections() {
        let now = Date()
        let items = [
            BookmarkItem(title: "今天", date: "d", category: "c", summary: "s",
                         articleId: "g1", bookmarkDate: now),
            BookmarkItem(title: "三天前", date: "d", category: "c", summary: "s",
                         articleId: "g2", bookmarkDate: now.addingTimeInterval(-3 * 86400)),
            BookmarkItem(title: "十天前", date: "d", category: "c", summary: "s",
                         articleId: "g3", bookmarkDate: now.addingTimeInterval(-10 * 86400))
        ]

        let sections = BookmarkManager.groupSections(items, now: now)
        XCTAssertEqual(sections.map(\.group), [.today, .last7Days, .earlier])
        XCTAssertEqual(sections[0].items.map(\.readKey), ["g1"])
        XCTAssertEqual(sections[2].items.map(\.readKey), ["g3"])

        // 空分组自动剔除
        XCTAssertEqual(BookmarkManager.groupSections([items[0]], now: now).count, 1)

        // 边界：第 7 天仍属「近 7 天」，第 8 天属「更早」
        XCTAssertEqual(BookmarkTimeGroup.group(for: now.addingTimeInterval(-7 * 86400), now: now), .last7Days)
        XCTAssertEqual(BookmarkTimeGroup.group(for: now.addingTimeInterval(-8 * 86400), now: now), .earlier)
    }

    func testContentUpdateDetection() {
        XCTAssertFalse(BookmarkManager.isMeaningfulUpdate(old: nil, new: "新内容"))
        XCTAssertFalse(BookmarkManager.isMeaningfulUpdate(old: "", new: "新内容"))
        XCTAssertFalse(BookmarkManager.isMeaningfulUpdate(old: "同", new: "同"))
        XCTAssertFalse(BookmarkManager.isMeaningfulUpdate(old: "同", new: "  同  "))
        XCTAssertFalse(BookmarkManager.isMeaningfulUpdate(old: "旧", new: "   "))
        XCTAssertTrue(BookmarkManager.isMeaningfulUpdate(old: "旧", new: "新内容"))
    }

    // MARK: 统计 / 候选 / 设置

    func testStorageSnapshotCountsContent() async throws {
        try writeStorageFile([
            makeBookmark(title: "有缓存", articleId: "c1", cachedContent: "一二三四五", contentCached: true),
            makeBookmark(title: "无缓存", articleId: "c2")
        ])

        let manager = makeManager()
        let snapshot = await manager.storageSnapshot()
        XCTAssertEqual(snapshot.total, 2)
        XCTAssertEqual(snapshot.contentCached, 1)
        XCTAssertEqual(snapshot.contentChars, 5)
        XCTAssertEqual(snapshot.imageFiles, 0)
    }

    func testPrecacheCandidatesFiltering() throws {
        // 无 articleId 的收藏（机构文章兜底键）不参与正文预热
        let noArticleId = BookmarkItem(title: "无 ID", date: "2026-01-01", category: "学校要闻",
                                       summary: "摘要", articleId: nil)
        try writeStorageFile([
            makeBookmark(title: "待缓存", articleId: "p1"),
            makeBookmark(title: "已缓存", articleId: "p2", cachedContent: "正文", contentCached: true),
            noArticleId
        ])

        let manager = makeManager()
        XCTAssertEqual(manager.precacheCandidates.map(\.readKey), ["p1"])
    }

    func testSettingsPersistAcrossReload() {
        let manager = makeManager()
        manager.maxCount = 100
        manager.autoCacheContent = false

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.maxCount, 100)
        XCTAssertFalse(reloaded.autoCacheContent)
    }

    func testApplyMaxCountLimitKeepsNewest() {
        let manager = makeManager()
        (1...4).forEach { manager.addBookmark(makeItem($0)) }
        let newestKey = manager.bookmarks[0].readKey

        manager.maxCount = 2
        manager.applyMaxCountLimit()
        XCTAssertEqual(manager.count, 2)
        XCTAssertEqual(manager.bookmarks.first?.readKey, newestKey)
    }

    // MARK: 图片固化缓存

    func testImageCachePersistLoadAndClear() async throws {
        let manager = makeManager()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let pngURL = tempDir.appendingPathComponent("sample.png")
        try XCTUnwrap(image.pngData()).write(to: pngURL)

        let cached = await manager.cacheImage(from: pngURL.absoluteString)
        XCTAssertTrue(cached)

        let loaded = await manager.loadCachedImage(for: pngURL.absoluteString)
        XCTAssertNotNil(loaded)

        let snapshot = await manager.storageSnapshot()
        XCTAssertEqual(snapshot.imageFiles, 1)
        XCTAssertGreaterThan(snapshot.imageBytes, 0)

        let removed = await manager.clearImageCache()
        XCTAssertEqual(removed.files, 1)
        let afterClear = await manager.loadCachedImage(for: pngURL.absoluteString)
        XCTAssertNil(afterClear)
    }
}

// MARK: - 已读状态管理

@MainActor
final class ReadStatusManagerTests: XCTestCase {

    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReadStatusTests.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        suiteDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMarkAsReadAndUnreadRoundTrip() {
        let manager = ReadStatusManager(defaults: suiteDefaults)
        manager.markAsRead("k1")
        XCTAssertTrue(manager.isRead("k1"))
        XCTAssertEqual(manager.snapshot, ["k1"])

        manager.markAsUnread("k1")
        XCTAssertFalse(manager.isRead("k1"))
        XCTAssertTrue(manager.snapshot.isEmpty)

        // 幂等：重复回退不产生异常且保持为空
        manager.markAsUnread("k1")
        XCTAssertTrue(manager.snapshot.isEmpty)
    }

    func testPersistenceAndDeduplication() {
        let manager = ReadStatusManager(defaults: suiteDefaults)
        manager.markAsRead("a")
        manager.markAsRead("b")
        manager.markAsRead("a")   // 重复标记应被忽略

        let reloaded = ReadStatusManager(defaults: suiteDefaults)
        XCTAssertEqual(reloaded.snapshot, ["a", "b"])
    }

    func testTrimDropsOldestBeyondLimit() {
        let manager = ReadStatusManager(defaults: suiteDefaults, maxStoredIds: 3)
        for index in 1...5 {
            manager.markAsRead("k\(index)")
        }
        XCTAssertEqual(manager.snapshot, ["k3", "k4", "k5"])

        let reloaded = ReadStatusManager(defaults: suiteDefaults, maxStoredIds: 3)
        XCTAssertEqual(reloaded.snapshot, ["k3", "k4", "k5"])
    }

    func testUnreadCountInItems() {
        let manager = ReadStatusManager(defaults: suiteDefaults)
        let items = [
            NewsItem(title: "一", date: "2026-09-01", category: "c", summary: "s", articleId: "n1"),
            NewsItem(title: "二", date: "2026-09-02", category: "c", summary: "s", articleId: "n2")
        ]
        manager.markAsRead(items[0].readKey)
        XCTAssertEqual(manager.unreadCount(in: items), 1)
    }
}