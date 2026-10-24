//
//  BookmarkManager.swift
//  山西晋中理工学院 APP — 文章收藏管理
//
//  本地持久化收藏数据，支持离线访问、批量操作、图片缓存、上限管理。
//  App 重启不丢失，收藏状态实时同步。
//

import Foundation
import SwiftUI
import UserNotifications
import CryptoKit

// MARK: - 收藏管理器

@MainActor
final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()

    // MARK: 持久化键

    private let bookmarksKey = "bookmarkedArticles"
    private let maxBookmarksKey = "bookmarkMaxCount"
    private let autoCacheKey = "bookmarkAutoCacheContent"
    private let pushUpdateKey = "bookmarkPushOnUpdate"

    // MARK: 发布状态

    /// 收藏列表（按收藏时间倒序）
    @Published private(set) var bookmarks: [BookmarkItem] = []

    /// 收藏数量
    var count: Int { bookmarks.count }

    // MARK: 设置项

    /// 收藏最大条数（默认 500）
    @AppStorage("bookmarkMaxCount") var maxCount: Int = 500

    /// 收藏时自动缓存正文与图片
    @AppStorage("bookmarkAutoCacheContent") var autoCacheContent: Bool = true

    /// 收藏文章有官网原文更新时推送提醒
    @AppStorage("bookmarkPushOnUpdate") var pushOnUpdate: Bool = false

    // MARK: 收藏上限提示

    /// 是否已显示过上限提示（本次会话）
    @Published var showLimitAlert = false
    @Published var limitAlertMessage = ""

    // MARK: 图片缓存

    private let imageCache = NSCache<NSString, UIImage>()
    private let imageCacheDir: URL

    // MARK: 更新检查

    private var updateCheckTimer: Timer?
    private let updateCheckInterval: TimeInterval = 3600 // 每小时检查一次

    // MARK: 上限变更处理

    /// 当上限变更时调用，截断超出部分
    func applyMaxCountLimit() {
        guard bookmarks.count > maxCount else { return }
        bookmarks = Array(bookmarks.prefix(maxCount))
        save()
        objectWillChange.send()
    }

    /// 推送开关变更时调用
    func applyPushOnUpdateSetting() {
        if pushOnUpdate {
            startUpdateCheck()
        } else {
            stopUpdateCheck()
        }
    }

    // MARK: 初始化

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        imageCacheDir = docs.appendingPathComponent("SXJZIT_Cache/BookmarkImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageCacheDir, withIntermediateDirectories: true)

        imageCache.countLimit = 200
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB

        loadBookmarks()

        // 如果之前已开启推送，恢复定时器
        if pushOnUpdate {
            startUpdateCheck()
        }
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
        guard !isBookmarked(key) else { return }

        // 检查上限
        if bookmarks.count >= maxCount {
            limitAlertMessage = "收藏数量已达上限（\(maxCount)条），请先清理部分收藏后再添加。"
            showLimitAlert = true
            return
        }

        let bookmark = BookmarkItem(from: item)
        bookmarks.insert(bookmark, at: 0)
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "新增收藏", context: [
            "title": item.title, "articleId": item.articleId ?? "-", "total": "\(bookmarks.count)"
        ])

        // 自动缓存正文
        if autoCacheContent, let articleId = item.articleId {
            let readKey = key
            Task {
                await cacheArticleContent(forKey: readKey, articleId: articleId)
            }
        }

        // 缓存缩略图
        if let imageUrl = item.imageUrl {
            Task {
                await cacheImage(from: imageUrl)
            }
        }
    }

    /// 移除收藏
    func removeBookmark(_ key: String) {
        guard let index = bookmarks.firstIndex(where: { $0.readKey == key }) else { return }
        let removed = bookmarks[index]
        bookmarks.remove(at: index)
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "取消收藏", context: [
            "title": removed.title, "articleId": removed.articleId ?? "-", "total": "\(bookmarks.count)"
        ])

        // 清理缓存图片
        if let imageUrl = removed.imageUrl {
            removeCachedImage(for: imageUrl)
        }
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

    // MARK: 批量操作

    /// 批量移除收藏
    func removeBookmarks(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        bookmarks.removeAll { keys.contains($0.readKey) }
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "批量取消收藏", context: ["count": "\(keys.count)", "total": "\(bookmarks.count)"])
    }

    /// 清空全部收藏
    func clearAll() {
        guard !bookmarks.isEmpty else { return }
        // 清理所有缓存图片
        for bookmark in bookmarks {
            if let imageUrl = bookmark.imageUrl {
                removeCachedImage(for: imageUrl)
            }
        }
        bookmarks.removeAll()
        save()
        objectWillChange.send()
        LogManager.shared.info("favorite", "清空全部收藏", context: ["count": "\(bookmarks.count)"])
    }

    // MARK: 正文缓存

    /// 缓存文章正文内容
    private func cacheArticleContent(forKey key: String, articleId: String) async {
        guard let idx = bookmarks.firstIndex(where: { $0.readKey == key }),
              !bookmarks[idx].contentCached else { return }
        do {
            let detail = try await NetworkService.shared.fetchArticleDetail(articleId: articleId)
            let content = detail.content ?? detail.description ?? ""
            if !content.isEmpty {
                bookmarks[idx].cachedContent = content
                bookmarks[idx].contentCached = true
                save()
                objectWillChange.send()
            }
        } catch {
            print("[BookmarkManager] 缓存正文失败: \(error.localizedDescription)")
        }
    }

    /// 手动缓存指定收藏的正文
    func cacheContent(for key: String) async {
        guard let articleId = bookmarks.first(where: { $0.readKey == key })?.articleId else { return }
        await cacheArticleContent(forKey: key, articleId: articleId)
    }

    // MARK: 图片缓存

    /// 获取缓存的图片（内存 → 磁盘 两级缓存）
    func cachedImage(for url: String) -> UIImage? {
        let cacheKey = imageCacheKey(from: url)
        if let image = imageCache.object(forKey: cacheKey as NSString) {
            return image
        }
        // 尝试从磁盘加载
        let fileURL = imageCacheFileURL(for: cacheKey)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            imageCache.setObject(image, forKey: cacheKey as NSString)
            return image
        }
        return nil
    }

    /// 缓存图片（内存 + 磁盘 双写）
    func cacheImage(from urlString: String) async {
        let cacheKey = imageCacheKey(from: urlString)
        guard imageCache.object(forKey: cacheKey as NSString) == nil else { return }

        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                imageCache.setObject(image, forKey: cacheKey as NSString)
                try? data.write(to: imageCacheFileURL(for: cacheKey), options: .atomic)
            }
        } catch {
            print("[BookmarkManager] 缓存图片失败: \(error.localizedDescription)")
        }
    }

    private func removeCachedImage(for url: String) {
        let cacheKey = imageCacheKey(from: url)
        imageCache.removeObject(forKey: cacheKey as NSString)
        try? FileManager.default.removeItem(at: imageCacheFileURL(for: cacheKey))
    }

    /// 使用 SHA256 哈希生成缓存键，确保：
    /// 1. 不同 URL 100% 映射到不同键（无冲突）
    /// 2. 输出为纯十六进制字符串，不含 `/`、`+`、`=` 等特殊字符，文件路径安全
    /// 3. 固定 64 字符长度，无需截断
    private func imageCacheKey(from url: String) -> String {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalizedURL.data(using: .utf8) else {
            return url
        }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// 磁盘缓存文件路径 —— 使用 SHA256 哈希键，文件名仅含安全字符
    private func imageCacheFileURL(for key: String) -> URL {
        imageCacheDir.appendingPathComponent("\(key).img")
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
    func checkBookmarkedArticlesForUpdates() async {
        guard pushOnUpdate, !bookmarks.isEmpty else { return }

        let bookmarksWithArticleId = bookmarks.filter { $0.articleId != nil }
        guard !bookmarksWithArticleId.isEmpty else { return }

        var updatedArticles: [(BookmarkItem, String)] = []

        for bookmark in bookmarksWithArticleId.prefix(10) {
            guard let articleId = bookmark.articleId else { continue }
            do {
                let detail = try await NetworkService.shared.fetchArticleDetail(articleId: articleId)
                let newContent = detail.content ?? detail.description ?? ""
                if let cached = bookmark.cachedContent, !cached.isEmpty, newContent != cached {
                    updatedArticles.append((bookmark, bookmark.title))
                }
            } catch {
                // 单篇失败不影响其他
            }
        }

        if !updatedArticles.isEmpty {
            await sendUpdateNotifications(for: updatedArticles)
        }
    }

    private func sendUpdateNotifications(for articles: [(BookmarkItem, String)]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for (index, (bookmark, title)) in articles.prefix(3).enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "收藏文章已更新"
            content.body = "「\(title)」有新的内容更新"
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
                    subtitle: "「\(title)」有新的内容更新",
                    deepLink: DeepLinkPayload(
                        articleId: bookmark.articleId ?? "",
                        articleCategory: bookmark.category,
                        articleTitle: bookmark.title))
            } catch {
                LogManager.shared.debugLog("bookmark", "收藏更新通知发送失败", context: [
                    "readKey": bookmark.readKey,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    // MARK: 持久化

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: bookmarksKey)
    }

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let loaded = try? JSONDecoder().decode([BookmarkItem].self, from: data) else {
            bookmarks = []
            return
        }
        bookmarks = loaded
    }
}