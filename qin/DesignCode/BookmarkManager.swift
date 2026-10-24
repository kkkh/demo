//
//  BookmarkManager.swift
//  山西晋中理工学院 APP — 文章收藏管理
//
//  本地持久化收藏数据（文件存储 · 旧版 UserDefaults 自动迁移 · 损坏自愈抢救），
//  支持离线阅读、筛选排序、批量操作、图片固化缓存、更新检测、上限管理。
//  App 重启不丢失，收藏状态实时同步；全链路日志域 favorite。
//

import Foundation
import SwiftUI
import UserNotifications
import CryptoKit

// MARK: - 收藏排序方式

enum BookmarkSortOrder: String, CaseIterable, Identifiable {
    case recentlyBookmarked   // 最近收藏（默认）
    case recentlyPublished    // 最近发布
    case recentlyViewed       // 最近阅读
    case titleAscending       // 标题顺序

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyBookmarked: return "最近收藏"
        case .recentlyPublished: return "最近发布"
        case .recentlyViewed: return "最近阅读"
        case .titleAscending: return "标题顺序"
        }
    }

    var icon: String {
        switch self {
        case .recentlyBookmarked: return "bookmark.fill"
        case .recentlyPublished: return "calendar"
        case .recentlyViewed: return "clock.arrow.circlepath"
        case .titleAscending: return "textformat.abc"
        }
    }
}

// MARK: - 收藏筛选范围

enum BookmarkFilterScope: Equatable, Identifiable {
    case all
    case unread
    case offlineReady
    case category(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .unread: return "unread"
        case .offlineReady: return "offline"
        case .category(let name): return "category:\(name)"
        }
    }
}

// MARK: - 收藏时间分组（按收藏时间）

enum BookmarkTimeGroup: String, CaseIterable {
    case today = "今天"
    case last7Days = "近 7 天"
    case earlier = "更早"

    /// 时间分组判定：自然日今天 / 近 7 天 / 更早
    static func group(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> BookmarkTimeGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 7 ? .last7Days : .earlier
    }
}

// MARK: - 正文缓存结果

enum BookmarkContentOutcome: Equatable {
    case cached      // 本次成功缓存
    case updated     // 检测到官网更新并刷新缓存
    case unchanged   // 与缓存一致，无更新
    case skipped     // 无 articleId / 已缓存 / 条目已删除
    case failed      // 网络或解析失败
}

// MARK: - 更新检查报告

struct BookmarkUpdateCheckReport: Equatable {
    let checked: Int        // 实际完成比对的篇数
    let updated: Int        // 检测到更新
    let failed: Int         // 请求失败
    let skipped: Int        // 无缓存正文可比对而跳过
    let elapsedMs: Int
}

// MARK: - 存储快照（诊断面板）

struct BookmarkStorageSnapshot {
    let total: Int              // 收藏总数
    let contentCached: Int      // 已缓存正文篇数
    let contentChars: Int       // 缓存正文总字符数
    let imageFiles: Int         // 固化图片张数
    let imageBytes: Int64       // 固化图片占用字节
    let storageFileBytes: Int64 // 存储文件字节

    /// 供诊断面板展示的多行摘要
    var summaryText: String {
        let mb = Double(imageBytes) / 1024 / 1024
        return """
        收藏总数：\(total) 篇
        正文缓存：\(contentCached) 篇 · \(contentChars) 字
        图片固化：\(imageFiles) 张 · \(String(format: "%.1f", mb)) MB
        存储文件：\(storageFileBytes / 1024) KB
        """
    }
}

// MARK: - 收藏管理器

@MainActor
final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()

    // MARK: 持久化键（旧版 UserDefaults 键保留用于一次性迁移）

    /// 旧版收藏数据键（迁移来源）
    static let legacyBookmarksKey = "bookmarkedArticles"
    private enum SettingsKeys {
        static let maxCount = "bookmarkMaxCount"
        static let autoCache = "bookmarkAutoCacheContent"
        static let pushOnUpdate = "bookmarkPushOnUpdate"
    }

    // MARK: 注入（测试隔离：独立 defaults / 目录）

    private let defaults: UserDefaults
    private let storageFileURL: URL
    private let imageCacheDir: URL

    // MARK: 发布状态

    /// 收藏列表（按收藏时间倒序）
    @Published private(set) var bookmarks: [BookmarkItem] = []

    /// 收藏数量
    var count: Int { bookmarks.count }

    // MARK: 设置项（持久化至注入 defaults；视图 $ 绑定与既有用法完全兼容）

    /// 收藏最大条数（默认 500）
    @Published var maxCount: Int {
        didSet {
            guard maxCount != oldValue else { return }
            defaults.set(maxCount, forKey: SettingsKeys.maxCount)
            LogManager.shared.info("favorite", "设置：收藏上限变更", context: ["max": "\(maxCount)"])
        }
    }

    /// 收藏时自动缓存正文与图片
    @Published var autoCacheContent: Bool {
        didSet {
            guard autoCacheContent != oldValue else { return }
            defaults.set(autoCacheContent, forKey: SettingsKeys.autoCache)
            LogManager.shared.info("favorite", "设置：自动缓存正文", context: ["enabled": "\(autoCacheContent)"])
        }
    }

    /// 收藏文章有官网原文更新时推送提醒
    @Published var pushOnUpdate: Bool {
        didSet {
            guard pushOnUpdate != oldValue else { return }
            defaults.set(pushOnUpdate, forKey: SettingsKeys.pushOnUpdate)
            LogManager.shared.info("favorite", "设置：收藏更新推送", context: ["enabled": "\(pushOnUpdate)"])
        }
    }

    // MARK: 收藏上限提示

    /// 是否已显示过上限提示（本次会话）
    @Published var showLimitAlert = false
    @Published var limitAlertMessage = ""

    // MARK: 批量缓存进度

    struct PrecacheProgress: Equatable {
        let done: Int
        let total: Int
    }

    /// 非空时表示「缓存全部正文」进行中，供列表页展示进度与取消
    @Published private(set) var precacheProgress: PrecacheProgress?
    private var precacheTask: Task<Void, Never>?

    // MARK: 图片缓存（内存 NSCache + 磁盘固化目录）

    private let imageCache = NSCache<NSString, UIImage>()
    /// 单张图片固化上限（8MB，防止异常大图撑爆缓存目录）
    private static let maxPersistedImageBytes = 8 * 1024 * 1024

    // MARK: 更新检查

    private var updateCheckTimer: Timer?
    private let updateCheckInterval: TimeInterval = 3600 // 每小时检查一次

    // MARK: 派生统计

    /// 已缓存正文的收藏数
    var contentCachedCount: Int { bookmarks.filter { $0.contentCached }.count }

    /// 待缓存正文的收藏（有 articleId 且尚未缓存）
    var precacheCandidates: [BookmarkItem] {
        bookmarks.filter { $0.articleId != nil && !$0.contentCached }
    }

    /// 收藏中出现过的分类（按数量降序，供筛选芯片动态生成）
    var categoryFacets: [(name: String, count: Int)] {
        Dictionary(grouping: bookmarks, by: \.category)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }

    /// 收藏中的未读数量（依赖已读键快照）
    func unreadCount(readKeys: Set<String>) -> Int {
        bookmarks.filter { !readKeys.contains($0.readKey) }.count
    }

    // MARK: 初始化

    init(defaults: UserDefaults = .standard,
         storageDirectory: URL? = nil,
         cacheDirectory: URL? = nil) {
        self.defaults = defaults

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let baseDir = storageDirectory ?? docs.appendingPathComponent("SXJZIT_Cache/Bookmarks", isDirectory: true)
        self.storageFileURL = baseDir.appendingPathComponent("bookmarks.json")
        self.imageCacheDir = cacheDirectory ?? docs.appendingPathComponent("SXJZIT_Cache/BookmarkImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imageCacheDir, withIntermediateDirectories: true)

        imageCache.countLimit = 200
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB

        // 设置项：区分「从未设置」与「显式设为默认值」
        maxCount = defaults.object(forKey: SettingsKeys.maxCount) != nil
            ? defaults.integer(forKey: SettingsKeys.maxCount) : 500
        autoCacheContent = defaults.object(forKey: SettingsKeys.autoCache) != nil
            ? defaults.bool(forKey: SettingsKeys.autoCache) : true
        pushOnUpdate = defaults.object(forKey: SettingsKeys.pushOnUpdate) != nil
            ? defaults.bool(forKey: SettingsKeys.pushOnUpdate) : false

        loadBookmarks()

        // 如果之前已开启推送，恢复定时器
        if pushOnUpdate {
            startUpdateCheck()
        }

        LogManager.shared.info("favorite", "收藏管理器初始化", context: [
            "count": "\(bookmarks.count)",
            "max": "\(maxCount)",
            "autoCache": "\(autoCacheContent)",
            "pushOnUpdate": "\(pushOnUpdate)"
        ])
    }

    // MARK: 上限与推送设置联动

    /// 当上限变更时调用，截断超出部分
    func applyMaxCountLimit() {
        guard bookmarks.count > maxCount else { return }
        let truncated = bookmarks.count - maxCount
        bookmarks = Array(bookmarks.prefix(maxCount))
        save()
        objectWillChange.send()
        LogManager.shared.warning("favorite", "收藏超出上限已截断", context: [
            "truncated": "\(truncated)", "max": "\(maxCount)", "total": "\(bookmarks.count)"
        ])
    }

    /// 推送开关变更时调用
    func applyPushOnUpdateSetting() {
        if pushOnUpdate {
            startUpdateCheck()
        } else {
            stopUpdateCheck()
        }
        LogManager.shared.info("favorite", "收藏更新推送定时器状态", context: [
            "running": "\(updateCheckTimer != nil)", "intervalSec": "\(Int(updateCheckInterval))"
        ])
    }

    // MARK: 收藏操作

    /// 是否已收藏
    func isBookmarked(_ key: String) -> Bool {
        bookmarks.contains { $0.readKey == key }
    }

    /// 根据 NewsItem 判断是否已收藏
    func isBookmarked(_ item: NewsItem) -> Bool {
        isBookmarked(item.readKey)
    }

    /// 添加收藏
    func addBookmark(_ item: NewsItem) {
        let key = item.readKey
        guard !isBookmarked(key) else {
            LogManager.shared.debugLog("favorite", "重复收藏已忽略", context: ["readKey": key])
            return
        }

        // 检查上限
        if bookmarks.count >= maxCount {
            limitAlertMessage = "收藏数量已达上限（\(maxCount)条），请先清理部分收藏后再添加。"
            showLimitAlert = true
            LogManager.shared.warning("favorite", "收藏上限已达", context: [
                "max": "\(maxCount)", "current": "\(bookmarks.count)", "title": item.title
            ])
            return
        }

        let bookmark = BookmarkItem(from: item)
        bookmarks.insert(bookmark, at: 0)
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "新增收藏", context: [
            "title": item.title, "articleId": item.articleId ?? "-",
            "category": item.category, "total": "\(bookmarks.count)"
        ])

        // 自动缓存正文
        if autoCacheContent, let articleId = item.articleId {
            let readKey = key
            Task {
                await cacheArticleContent(forKey: readKey, articleId: articleId, isRefreshCheck: false)
            }
        }

        // 固化缩略图（离线可用）
        if let imageUrl = item.imageUrl {
            Task {
                await cacheImage(from: imageUrl)
            }
        }
    }

    /// 移除收藏（返回是否实际移除）
    @discardableResult
    func removeBookmark(_ key: String) -> Bool {
        guard let index = bookmarks.firstIndex(where: { $0.readKey == key }) else { return false }
        let removed = bookmarks[index]
        bookmarks.remove(at: index)
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "取消收藏", context: [
            "title": removed.title, "articleId": removed.articleId ?? "-", "total": "\(bookmarks.count)"
        ])

        // 清理固化图片
        if let imageUrl = removed.imageUrl {
            removeCachedImage(for: imageUrl)
        }
        return true
    }

    /// 根据 NewsItem 移除收藏
    func removeBookmark(_ item: NewsItem) {
        removeBookmark(item.readKey)
    }

    /// 切换收藏状态
    func toggleBookmark(_ item: NewsItem) {
        if isBookmarked(item) {
            removeBookmark(item)
        } else {
            addBookmark(item)
        }
    }

    /// 根据文章基本信息切换收藏状态（用于机构文章等非 NewsItem 来源的文章）
    /// - Parameters: 文章基本信息，与 NewsItem 字段对应
    func toggleBookmark(articleId: String, title: String, date: String, category: String = "机构文章", summary: String = "", imageUrl: String? = nil, href: String? = nil, author: String? = nil, source: String? = nil, columnId: String? = nil) {
        let key = articleId.isEmpty ? title + date : articleId
        if isBookmarked(key) {
            removeBookmark(key)
            LogManager.shared.info("favorite", "机构文章取消收藏", context: [
                "articleId": articleId, "title": title
            ])
        } else {
            // 检查上限
            if bookmarks.count >= maxCount {
                limitAlertMessage = "收藏数量已达上限（\(maxCount)条），请先清理部分收藏后再添加。"
                showLimitAlert = true
                LogManager.shared.warning("favorite", "收藏上限已达", context: [
                    "max": "\(maxCount)", "current": "\(bookmarks.count)"
                ])
                return
            }
            let item = NewsItem(
                title: title,
                date: date,
                category: category,
                summary: summary.isEmpty ? title : summary,
                imageUrl: imageUrl,
                columnId: columnId,
                articleId: articleId.isEmpty ? nil : articleId,
                href: href,
                author: author,
                source: source
            )
            addBookmark(item)
        }
    }

    /// 记录文章被打开：更新最近阅读时间，并清除「内容有更新」提醒徽标
    func markViewed(_ key: String) {
        guard let index = bookmarks.firstIndex(where: { $0.readKey == key }) else { return }
        let hadUpdate = bookmarks[index].updateDetectedAt != nil
        bookmarks[index].lastViewedAt = Date()
        bookmarks[index].updateDetectedAt = nil
        save()
        objectWillChange.send()
        // 状态流转：最近阅读时间刷新（常态记录，供「最近阅读」排序对账）
        LogManager.shared.debugLog("favorite", "状态流转：最近阅读时间已更新", context: [
            "readKey": key, "hadUpdateBadge": "\(hadUpdate)"
        ])
        if hadUpdate {
            LogManager.shared.info("favorite", "状态流转：内容更新徽标已清除", context: ["readKey": key])
        }
    }

    // MARK: 批量操作

    /// 批量移除收藏（返回实际移除篇数）
    @discardableResult
    func removeBookmarks(_ keys: Set<String>) -> Int {
        guard !keys.isEmpty else { return 0 }
        let removed = bookmarks.filter { keys.contains($0.readKey) }
        guard !removed.isEmpty else { return 0 }
        bookmarks.removeAll { keys.contains($0.readKey) }
        save()
        objectWillChange.send()
        for item in removed {
            if let imageUrl = item.imageUrl {
                removeCachedImage(for: imageUrl)
            }
        }
        LogManager.shared.info("favorite", "批量取消收藏", context: [
            "requested": "\(keys.count)", "removed": "\(removed.count)", "total": "\(bookmarks.count)"
        ])
        return removed.count
    }

    /// 清空全部收藏（返回移除篇数）
    @discardableResult
    func clearAll() -> Int {
        guard !bookmarks.isEmpty else { return 0 }
        let removedCount = bookmarks.count
        for bookmark in bookmarks {
            if let imageUrl = bookmark.imageUrl {
                removeCachedImage(for: imageUrl)
            }
        }
        bookmarks.removeAll()
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "清空全部收藏", context: ["count": "\(removedCount)"])
        return removedCount
    }

    // MARK: 筛选 · 排序 · 分组（纯函数，供列表与单元测试共用）

    /// 筛选 + 排序
    /// - Parameters:
    ///   - query: 关键词（标题 / 摘要 / 分类，忽略大小写；空白视为无关键词）
    ///   - scope: 筛选范围
    ///   - sort: 排序方式
    ///   - readKeys: 已读键快照（未读筛选依赖）
    nonisolated static func filter(_ items: [BookmarkItem],
                                   query: String,
                                   scope: BookmarkFilterScope,
                                   sort: BookmarkSortOrder,
                                   readKeys: Set<String>) -> [BookmarkItem] {
        var result = items
        switch scope {
        case .all:
            break
        case .unread:
            result = result.filter { !readKeys.contains($0.readKey) }
        case .offlineReady:
            result = result.filter { $0.contentCached }
        case .category(let name):
            result = result.filter { $0.category == name }
        }

        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.summary.localizedCaseInsensitiveContains(keyword)
                    || $0.category.localizedCaseInsensitiveContains(keyword)
            }
        }

        switch sort {
        case .recentlyBookmarked:
            result.sort { $0.bookmarkDate > $1.bookmarkDate }
        case .recentlyPublished:
            result.sort { $0.date > $1.date }
        case .recentlyViewed:
            result.sort { ($0.lastViewedAt ?? .distantPast) > ($1.lastViewedAt ?? .distantPast) }
        case .titleAscending:
            result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
        return result
    }

    /// 按收藏时间分组（今天 / 近 7 天 / 更早；空组自动剔除，保持时间倒序）
    nonisolated static func groupSections(_ items: [BookmarkItem],
                                          now: Date = Date(),
                                          calendar: Calendar = .current) -> [(group: BookmarkTimeGroup, items: [BookmarkItem])] {
        var buckets: [BookmarkTimeGroup: [BookmarkItem]] = [:]
        for item in items {
            buckets[BookmarkTimeGroup.group(for: item.bookmarkDate, now: now, calendar: calendar), default: []].append(item)
        }
        return BookmarkTimeGroup.allCases.compactMap { group in
            guard let bucket = buckets[group], !bucket.isEmpty else { return nil }
            return (group, bucket)
        }
    }

    /// 内容更新判定（纯函数）：旧缓存非空且与新内容不同（去首尾空白后比对）
    nonisolated static func isMeaningfulUpdate(old: String?, new: String) -> Bool {
        guard let old, !old.isEmpty else { return false }
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return false }
        return old.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedNew
    }

    // MARK: 正文缓存

    /// 缓存 / 刷新文章正文
    /// - Parameter isRefreshCheck: true 时表示用于更新检测比对（发现变化会写入「内容有更新」徽标）
    @discardableResult
    private func cacheArticleContent(forKey key: String, articleId: String, isRefreshCheck: Bool) async -> BookmarkContentOutcome {
        guard let index = bookmarks.firstIndex(where: { $0.readKey == key }) else { return .skipped }
        // 更新检测需要旧缓存可比对；首次填充仅需未缓存
        if !isRefreshCheck && bookmarks[index].contentCached { return .skipped }

        let oldContent = bookmarks[index].cachedContent
        do {
            let detail = try await NetworkService.shared.fetchArticleDetail(articleId: articleId)
            let content = detail.content ?? detail.description ?? ""
            guard !content.isEmpty else {
                LogManager.shared.warning("favorite", "正文缓存返回空内容", context: [
                    "readKey": key, "articleId": articleId
                ])
                return .failed
            }
            guard let currentIndex = bookmarks.firstIndex(where: { $0.readKey == key }) else { return .skipped }
            let changed = Self.isMeaningfulUpdate(old: oldContent, new: content)
            bookmarks[currentIndex].cachedContent = content
            bookmarks[currentIndex].contentCached = true
            if isRefreshCheck && changed {
                bookmarks[currentIndex].updateDetectedAt = Date()
            }
            save()
            objectWillChange.send()
            if isRefreshCheck {
                if changed {
                    // 状态流转：更新徽标点亮（列表「内容有更新」胶囊的数据来源）
                    LogManager.shared.info("favorite", "状态流转：内容更新徽标点亮", context: [
                        "readKey": key, "title": bookmarks[currentIndex].title,
                        "oldChars": "\(oldContent?.count ?? 0)", "newChars": "\(content.count)"
                    ])
                }
                LogManager.shared.debugLog("favorite", "更新检测：正文比对完成", context: [
                    "readKey": key, "changed": "\(changed)", "chars": "\(content.count)"
                ])
                return changed ? .updated : .unchanged
            } else {
                LogManager.shared.info("favorite", "正文缓存完成", context: [
                    "readKey": key, "articleId": articleId,
                    "chars": "\(content.count)", "cachedTotal": "\(contentCachedCount)"
                ])
                return .cached
            }
        } catch {
            LogManager.shared.warning("favorite", "正文缓存失败", context: [
                "readKey": key, "articleId": articleId, "error": error.localizedDescription
            ])
            return .failed
        }
    }

    /// 手动缓存指定收藏的正文（列表 / 详情菜单调用）
    @discardableResult
    func cacheContent(for key: String) async -> BookmarkContentOutcome {
        guard let articleId = bookmarks.first(where: { $0.readKey == key })?.articleId else {
            LogManager.shared.debugLog("favorite", "手动缓存跳过：无 articleId", context: ["readKey": key])
            return .skipped
        }
        return await cacheArticleContent(forKey: key, articleId: articleId, isRefreshCheck: false)
    }

    /// 批量预热全部未缓存正文（顺序执行 + 进度发布 + 可取消）
    func precacheAllContent() {
        guard precacheTask == nil else { return }
        let candidates = precacheCandidates
        guard !candidates.isEmpty else {
            LogManager.shared.info("favorite", "批量缓存正文：无可缓存条目", context: [:])
            return
        }
        LogManager.shared.info("favorite", "批量缓存正文开始", context: ["total": "\(candidates.count)"])
        precacheProgress = PrecacheProgress(done: 0, total: candidates.count)
        precacheTask = Task { [weak self] in
            var cached = 0
            var failed = 0
            let start = Date()
            for (index, item) in candidates.enumerated() {
                if Task.isCancelled { break }
                let outcome = await self?.cacheContent(for: item.readKey) ?? .skipped
                if outcome == .cached { cached += 1 } else if outcome == .failed { failed += 1 }
                self?.precacheProgress = PrecacheProgress(done: index + 1, total: candidates.count)
                // 进度采样（首条 / 每 5 条 / 末条，防刷屏且状态可对账）
                let done = index + 1
                if done == 1 || done % 5 == 0 || done == candidates.count {
                    LogManager.shared.debugLog("favorite", "批量缓存进度采样", context: [
                        "done": "\(done)", "total": "\(candidates.count)",
                        "cached": "\(cached)", "failed": "\(failed)"
                    ])
                }
            }
            let cancelled = Task.isCancelled
            let elapsed = Date().timeIntervalSince(start)
            LogManager.shared.info("favorite", "批量缓存正文结束", context: [
                "cached": "\(cached)", "failed": "\(failed)", "total": "\(candidates.count)",
                "cancelled": "\(cancelled)",
                "elapsedMs": String(format: "%.0f", elapsed * 1000)
            ])
            self?.precacheProgress = nil
            self?.precacheTask = nil
        }
    }

    /// 取消批量缓存
    func cancelPrecache() {
        guard precacheTask != nil else { return }
        precacheTask?.cancel()
        precacheTask = nil
        precacheProgress = nil
        LogManager.shared.info("favorite", "批量缓存正文已取消", context: [:])
    }

    // MARK: 图片缓存（内存 → 磁盘两级；磁盘读写均在后台线程）

    /// 磁盘缓存键 —— SHA256 哈希，确保：
    /// 1. 不同 URL 100% 映射到不同键（无冲突）
    /// 2. 输出为纯十六进制字符串，不含 `/`、`+`、`=` 等特殊字符，文件路径安全
    /// 3. 固定 64 字符长度，无需截断
    nonisolated static func imageCacheKey(for url: String) -> String {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalizedURL.data(using: .utf8) else {
            return normalizedURL
        }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// 内存缓存命中查询（无 IO，主线程安全）
    func memoryCachedImage(for url: String) -> UIImage? {
        imageCache.object(forKey: Self.imageCacheKey(for: url) as NSString)
    }

    /// 读取固化图片（内存 → 磁盘；磁盘读取与降采样解码在后台线程执行）
    func loadCachedImage(for url: String) async -> UIImage? {
        let key = Self.imageCacheKey(for: url)
        if let image = imageCache.object(forKey: key as NSString) {
            return image
        }
        let fileURL = imageCacheDir.appendingPathComponent("\(key).img")
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: fileURL) }.value
        guard let data, !data.isEmpty else { return nil }
        // 缩略图口径降采样解码（360px），避免整图解码占用内存
        guard let image = await SJZImageKit.decode(data: data, maxPixel: 360) else { return nil }
        imageCache.setObject(image, forKey: key as NSString, cost: data.count)
        return image
    }

    /// 固化图片（内存 + 磁盘双写）：
    /// 优先复用共享 URLCache 中已有响应（列表管线通常已下载过，避免二次请求），
    /// 未命中再走统一图片会话下载。
    @discardableResult
    func cacheImage(from urlString: String) async -> Bool {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let url = URL(string: normalized) else { return false }
        let key = Self.imageCacheKey(for: normalized)

        // 内存已固化：直接完成
        if imageCache.object(forKey: key as NSString) != nil {
            logPersistHit(url: normalized, source: "memory")
            return true
        }

        let fileURL = imageCacheDir.appendingPathComponent("\(key).img")
        let fileExists = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: fileURL.path)
        }.value
        if fileExists {
            // 磁盘已固化：直接完成（内存缓存按离线兜底路径按需回填）
            logPersistHit(url: normalized, source: "disk")
            return true
        }

        // ① 共享 URLCache 命中：直接固化数据
        var data: Data?
        var fromURLCache = false
        if let cached = SJZImageKit.usableCachedResponse(for: SJZImageKit.makeRequest(url: url)) {
            data = cached.data
            fromURLCache = true
        } else {
            do {
                let (downloaded, _) = try await SJZImageKit.imageSession.data(from: url)
                data = downloaded
            } catch {
                if !SJZImageKit.isCancellation(error) {
                    LogManager.shared.warning("favorite", "收藏图片固化失败", context: [
                        "url": url.lastPathComponent, "error": error.localizedDescription
                    ])
                }
                return false
            }
        }
        guard let data, !data.isEmpty else { return false }
        guard data.count <= Self.maxPersistedImageBytes else {
            LogManager.shared.info("favorite", "收藏图片超过固化上限，跳过", context: [
                "url": url.lastPathComponent, "bytes": "\(data.count)"
            ])
            return false
        }

        let writeSucceeded = await Task.detached(priority: .utility) {
            do {
                try data.write(to: fileURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
        guard writeSucceeded else {
            LogManager.shared.warning("favorite", "收藏图片写入磁盘失败", context: [
                "url": url.lastPathComponent
            ])
            return false
        }
        if let image = await SJZImageKit.decode(data: data, maxPixel: 360) {
            imageCache.setObject(image, forKey: key as NSString, cost: data.count)
        }
        LogManager.shared.debugLog("favorite", "状态流转：收藏图片已固化", context: [
            "url": url.lastPathComponent,
            "source": fromURLCache ? "urlcache" : "network",
            "bytes": "\(data.count)"
        ])
        return true
    }

    /// 图片固化命中日志（按 URL 节流，列表滚动复用不刷屏）
    private func logPersistHit(url: String, source: String) {
        guard SJZImageKit.shouldLogHit("fav.persist:\(url)") else { return }
        LogManager.shared.debugLog("favorite", "状态流转：图片固化命中（免二次下载）", context: [
            "url": URL(string: url)?.lastPathComponent ?? "-", "source": source
        ])
    }

    /// 清理单张固化图片（取消收藏时调用）
    private func removeCachedImage(for url: String) {
        let key = Self.imageCacheKey(for: url)
        imageCache.removeObject(forKey: key as NSString)
        let fileURL = imageCacheDir.appendingPathComponent("\(key).img")
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 清空全部固化图片缓存（保留收藏条目；返回清理张数与字节数）
    @discardableResult
    func clearImageCache() async -> (files: Int, bytes: Int64) {
        imageCache.removeAllObjects()
        let dir = imageCacheDir
        let removed = await Task.detached(priority: .utility) { Self.removeDirectoryContents(dir) }.value
        LogManager.shared.info("favorite", "清理收藏图片缓存", context: [
            "files": "\(removed.files)", "bytes": "\(removed.bytes)"
        ])
        return removed
    }

    // MARK: 存储统计与诊断修复

    /// 存储快照（目录扫描在后台线程执行，避免主线程 IO）
    func storageSnapshot() async -> BookmarkStorageSnapshot {
        let dir = imageCacheDir
        let fileURL = storageFileURL
        let scanned = await Task.detached(priority: .utility) {
            let images = Self.scanDirectory(dir)
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            return (images.files, images.bytes, fileBytes)
        }.value
        let snapshot = BookmarkStorageSnapshot(
            total: bookmarks.count,
            contentCached: contentCachedCount,
            contentChars: bookmarks.reduce(0) { $0 + ($1.cachedContent?.count ?? 0) },
            imageFiles: scanned.0,
            imageBytes: scanned.1,
            storageFileBytes: scanned.2
        )
        // 状态流转：存储快照取数（诊断面板对账依据）
        LogManager.shared.debugLog("favorite", "存储快照", context: [
            "total": "\(snapshot.total)", "cachedContent": "\(snapshot.contentCached)",
            "contentChars": "\(snapshot.contentChars)", "imageFiles": "\(snapshot.imageFiles)",
            "imageBytes": "\(snapshot.imageBytes)", "fileBytes": "\(snapshot.storageFileBytes)"
        ])
        return snapshot
    }

    /// 诊断修复：重写存储并回读校验
    @discardableResult
    func rebuildStorage() -> Bool {
        save()
        guard let data = try? Data(contentsOf: storageFileURL),
              let decoded = try? JSONDecoder().decode([BookmarkItem].self, from: data) else {
            LogManager.shared.error("favorite", "存储重写校验失败", context: ["count": "\(bookmarks.count)"])
            return false
        }
        let ok = decoded.count == bookmarks.count
        LogManager.shared.info("favorite", "存储重写校验完成", context: [
            "ok": "\(ok)", "count": "\(decoded.count)"
        ])
        return ok
    }

    /// 目录扫描（文件数 + 总字节）
    nonisolated static func scanDirectory(_ dir: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for name in names {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            files += 1
            bytes += (attrs[.size] as? Int64) ?? 0
        }
        return (files, bytes)
    }

    /// 清空目录内容（返回清理文件数与字节数）
    nonisolated static func removeDirectoryContents(_ dir: URL) -> (files: Int, bytes: Int64) {
        let stat = scanDirectory(dir)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return (0, 0) }
        for name in names {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        return stat
    }

    // MARK: 更新检查

    private func startUpdateCheck() {
        stopUpdateCheck()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: updateCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkBookmarkedArticlesForUpdates()
            }
        }
    }

    private func stopUpdateCheck() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
    }

    /// 检查收藏文章是否有更新
    /// - Parameter manual: true 表示用户手动触发（下拉刷新），不依赖推送开关；系统通知仅在推送开关开启时发送
    /// - Returns: 检查报告（比对篇数 / 更新篇数 / 失败篇数 / 跳过篇数 / 耗时）
    @discardableResult
    func checkBookmarkedArticlesForUpdates(manual: Bool = false) async -> BookmarkUpdateCheckReport {
        let start = Date()
        func emptyReport() -> BookmarkUpdateCheckReport {
            BookmarkUpdateCheckReport(checked: 0, updated: 0, failed: 0, skipped: 0,
                                      elapsedMs: Int(Date().timeIntervalSince(start) * 1000))
        }
        guard !bookmarks.isEmpty else { return emptyReport() }
        if !manual && !pushOnUpdate { return emptyReport() }

        let targets = Array(bookmarks.filter { $0.articleId != nil }.prefix(manual ? 12 : 10))
        guard !targets.isEmpty else { return emptyReport() }

        var checked = 0
        var failed = 0
        var skipped = 0
        var updatedItems: [BookmarkItem] = []

        for bookmark in targets {
            guard let articleId = bookmark.articleId else { continue }
            // 无缓存正文时无可比对基线，跳过（仅统计）
            if bookmark.cachedContent?.isEmpty ?? true {
                skipped += 1
                continue
            }
            let outcome = await cacheArticleContent(forKey: bookmark.readKey,
                                                    articleId: articleId,
                                                    isRefreshCheck: true)
            switch outcome {
            case .updated:
                checked += 1
                if let refreshed = bookmarks.first(where: { $0.readKey == bookmark.readKey }) {
                    updatedItems.append(refreshed)
                }
            case .unchanged:
                checked += 1
            case .failed:
                failed += 1
            case .skipped, .cached:
                skipped += 1
            }
        }

        if !updatedItems.isEmpty, pushOnUpdate {
            await sendUpdateNotifications(for: updatedItems)
        }

        let report = BookmarkUpdateCheckReport(
            checked: checked, updated: updatedItems.count, failed: failed, skipped: skipped,
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000))
        LogManager.shared.info("favorite", "收藏更新检查完成", context: [
            "manual": "\(manual)", "checked": "\(report.checked)", "updated": "\(report.updated)",
            "failed": "\(report.failed)", "skipped": "\(report.skipped)", "elapsedMs": "\(report.elapsedMs)"
        ])
        return report
    }

    private func sendUpdateNotifications(for bookmarks: [BookmarkItem]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            LogManager.shared.info("favorite", "收藏更新通知未发送：未获通知授权", context: [
                "count": "\(bookmarks.count)"
            ])
            return
        }

        for (index, bookmark) in bookmarks.prefix(3).enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "收藏文章已更新"
            content.body = "「\(bookmark.title)」有新的内容更新"
            content.sound = .default
            content.userInfo = [
                "articleId": bookmark.articleId ?? "",
                "articleCategory": bookmark.category,
                "articleTitle": bookmark.title,
                "isBookmarkUpdate": true
            ]

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(1 + index), repeats: false)
            let request = UNNotificationRequest(
                identifier: "bookmark-update-\(bookmark.readKey)",
                content: content, trigger: trigger)

            do {
                try await center.add(request)
                // 消息中心入盒（第五通道：收藏更新）
                MessageCenterStore.shared.ingest(
                    kind: .bookmarkUpdate,
                    id: "bookmark-update-\(bookmark.readKey)",
                    title: "收藏文章已更新",
                    subtitle: "「\(bookmark.title)」有新的内容更新",
                    deepLink: DeepLinkPayload(
                        articleId: bookmark.articleId ?? "",
                        articleCategory: bookmark.category,
                        articleTitle: bookmark.title,
                        isBookmarkUpdate: true))
                LogManager.shared.info("favorite", "收藏更新通知已发送", context: [
                    "readKey": bookmark.readKey, "title": bookmark.title
                ])
            } catch {
                LogManager.shared.warning("favorite", "收藏更新通知发送失败", context: [
                    "readKey": bookmark.readKey,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    // MARK: 持久化（文件存储 + 旧版自动迁移 + 损坏自愈）

    private func save() {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: storageFileURL, options: .atomic)
        } catch {
            LogManager.shared.error("favorite", "收藏数据写入失败", context: [
                "count": "\(bookmarks.count)", "error": error.localizedDescription
            ])
        }
    }

    private func loadBookmarks() {
        // ① 文件存储（当前格式）
        if let data = try? Data(contentsOf: storageFileURL), !data.isEmpty {
            let decoded = Self.decodeBookmarks(from: data)
            if let items = decoded.items {
                bookmarks = items
                if decoded.skipped > 0 {
                    LogManager.shared.warning("favorite", "收藏存储部分条目损坏，已抢救恢复", context: [
                        "rescued": "\(items.count)", "skipped": "\(decoded.skipped)"
                    ])
                    save()
                }
                return
            }
            LogManager.shared.error("favorite", "收藏存储文件解析失败，尝试旧版数据恢复", context: [
                "bytes": "\(data.count)"
            ])
        }

        // ② 旧版 UserDefaults 数据（一次性迁移）
        if let legacy = defaults.data(forKey: Self.legacyBookmarksKey), !legacy.isEmpty {
            let decoded = Self.decodeBookmarks(from: legacy)
            if let items = decoded.items {
                bookmarks = items
                save()
                defaults.removeObject(forKey: Self.legacyBookmarksKey)
                LogManager.shared.info("favorite", "旧版收藏数据已迁移至文件存储", context: [
                    "count": "\(items.count)", "rescuedSkipped": "\(decoded.skipped)"
                ])
                return
            }
            LogManager.shared.error("favorite", "旧版收藏数据解析失败，已放弃", context: [
                "bytes": "\(legacy.count)"
            ])
        }

        bookmarks = []
    }

    /// 解析收藏数组：整段优先；失败时逐条抢救（保留合法条目、跳过损坏条目）
    /// - Returns: items 为 nil 表示整体不可解析；skipped 为抢救时跳过的损坏条数
    nonisolated static func decodeBookmarks(from data: Data) -> (items: [BookmarkItem]?, skipped: Int) {
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([BookmarkItem].self, from: data) {
            return (items, 0)
        }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return (nil, 0)
        }
        var items: [BookmarkItem] = []
        var skipped = 0
        for element in raw {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let item = try? decoder.decode(BookmarkItem.self, from: elementData) else {
                skipped += 1
                continue
            }
            items.append(item)
        }
        return (items, skipped)
    }
}