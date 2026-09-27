//
//  HelpGuideStore.swift
//  DesignCode
//
//  使用帮助数据中枢：搜索（多词 AND 权重）、搜索历史、已读状态、最近阅读。
//  全部状态本地持久化（UserDefaults），日志域 helpGuide。
//

import SwiftUI
import Combine

// MARK: - 搜索命中（含相关度得分，供列表徽章展示）

struct HelpSearchHit: Identifiable, Equatable {
    let article: HelpArticle
    let score: Double

    var id: String { article.id }
}

// MARK: - 使用帮助数据中枢

@MainActor
final class HelpGuideStore: ObservableObject {

    static let shared = HelpGuideStore()

    // MARK: 持久化键

    private static let readKey = "helpGuideReadIds"
    private static let historyKey = "helpGuideSearchHistory"
    private static let recentKey = "helpGuideRecentIds"

    // MARK: 状态

    /// 已读文章 id 集合（持久化）
    @Published private(set) var readArticleIds: Set<String>

    /// 搜索历史（去重置顶，上限 10 条）
    @Published private(set) var searchHistory: [String]

    /// 最近阅读文章 id（上限 6 条，去重置顶）
    @Published private(set) var recentArticleIDs: [String]

    // MARK: 初始化

    private init() {
        let defaults = UserDefaults.standard
        // 已读集合与当前目录对账：历史残留（已从目录移除的文章）id 必须剔除，
        // 否则 readProgress 可能 >1、unreadCount 恒 0 并误禁用「全部标记已读」
        let validIDs = Set(HelpCatalog.articles.map(\.id))
        if let stored = defaults.stringArray(forKey: Self.readKey) {
            let pruned = Set(stored).intersection(validIDs)
            readArticleIds = pruned
            if pruned.count != stored.count {
                defaults.set(Array(pruned), forKey: Self.readKey)
            }
        } else {
            readArticleIds = []
        }
        searchHistory = defaults.stringArray(forKey: Self.historyKey) ?? []
        recentArticleIDs = defaults.stringArray(forKey: Self.recentKey) ?? []
    }

    // MARK: 只读统计

    /// 全部分类（目录定义）
    var categories: [HelpCategory] { HelpCatalog.categories }

    /// 全部文章
    var allArticles: [HelpArticle] { HelpCatalog.articles }

    /// 文章总数
    var totalArticles: Int { HelpCatalog.articles.count }

    /// 未读数
    var unreadCount: Int { max(0, HelpCatalog.articles.count - readArticleIds.count) }

    /// 阅读进度（0...1，供入口卡与首页进度环展示）
    var readProgress: Double {
        guard !HelpCatalog.articles.isEmpty else { return 0 }
        return Double(readArticleIds.count) / Double(HelpCatalog.articles.count)
    }

    /// 分类文章数
    func articleCount(in categoryId: String) -> Int {
        HelpCatalog.articles(inCategory: categoryId).count
    }

    /// 分类已读数
    func readCount(in categoryId: String) -> Int {
        HelpCatalog.articles(inCategory: categoryId).filter { readArticleIds.contains($0.id) }.count
    }

    /// 最近阅读文章实体（保持时间倒序）
    var recentArticles: [HelpArticle] {
        recentArticleIDs.compactMap { HelpCatalog.article($0) }
    }

    // MARK: 已读管理

    /// 是否已读
    func isRead(_ id: String) -> Bool {
        readArticleIds.contains(id)
    }

    /// 标记已读（幂等；重复标记无副作用）
    func markRead(_ id: String) {
        guard !readArticleIds.contains(id) else { return }
        readArticleIds.insert(id)
        UserDefaults.standard.set(Array(readArticleIds), forKey: Self.readKey)
        LogManager.shared.info("helpGuide", "帮助文章已读", context: ["articleId": id])
    }

    /// 全部标记已读（单次批量落盘）
    func markAllRead() {
        let newSet = Set(HelpCatalog.articles.map(\.id))
        readArticleIds = newSet
        UserDefaults.standard.set(Array(newSet), forKey: Self.readKey)
        LogManager.shared.info("helpGuide", "帮助文章全部已读", context: [
            "count": "\(newSet.count)"
        ])
    }

    /// 记录打开（标记已读 + 写入最近阅读）
    func recordOpen(_ article: HelpArticle) {
        markRead(article.id)
        recentArticleIDs.removeAll { $0 == article.id }
        recentArticleIDs.insert(article.id, at: 0)
        if recentArticleIDs.count > 6 {
            recentArticleIDs = Array(recentArticleIDs.prefix(6))
        }
        UserDefaults.standard.set(recentArticleIDs, forKey: Self.recentKey)
    }

    // MARK: 搜索

    /// 多词 AND 语义本地搜索：
    /// · 输入按空白/全角空格分词，每词都需命中；
    /// · 权重：标题 5 + 摘要 3 + 标签 2 + 步骤标题 1.5 + 步骤正文 1（命中词数累加）；
    /// · 排序：相关度总分 ↓ → 阅读时长 ↓（越短越优先）→ 目录顺序。
    func search(_ rawKeyword: String) -> [HelpSearchHit] {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return []
        }
        let words = keyword
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return []
        }
        let start = Date()

        var scored: [HelpSearchHit] = []
        for article in HelpCatalog.articles {
            let title = article.title.lowercased()
            let summary = article.summary.lowercased()
            let tags = article.tags.map { $0.lowercased() }
            var total = 0.0
            var allHit = true
            for word in words {
                let w = word.lowercased()
                var hit = false
                if title.contains(w) { total += 5; hit = true }
                if summary.contains(w) { total += 3; hit = true }
                let tagHits = tags.filter { $0.contains(w) }.count
                if tagHits > 0 { total += 2 * Double(tagHits); hit = true }
                var stepHit = false
                for step in article.steps {
                    if step.title.lowercased().contains(w) { total += 1.5; hit = true; stepHit = true }
                    if step.text.lowercased().contains(w) { total += 1; hit = true; stepHit = true }
                    if stepHit { break }
                }
                if !hit { allHit = false; break }
            }
            if allHit {
                scored.append(HelpSearchHit(article: article, score: total))
            }
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.article.readingMinutes != b.article.readingMinutes {
                return a.article.readingMinutes < b.article.readingMinutes
            }
            return a.article.id < b.article.id
        }
        LogManager.shared.info("helpGuide", "帮助搜索执行完成", context: [
            "keyword": keyword,
            "hitCount": "\(scored.count)",
            "elapsedMs": String(format: "%.0f", Date().timeIntervalSince(start) * 1000)
        ])
        return scored
    }

    /// 写入搜索历史（去重置顶，上限 10）
    func recordSearchHistory(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 10 {
            searchHistory = Array(searchHistory.prefix(10))
        }
        UserDefaults.standard.set(searchHistory, forKey: Self.historyKey)
        LogManager.shared.debugLog("helpGuide", "帮助搜索历史已写入", context: [
            "keyword": trimmed,
            "historyCount": "\(searchHistory.count)"
        ])
    }

    /// 清空搜索历史
    func clearSearchHistory() {
        searchHistory = []
        UserDefaults.standard.set(searchHistory, forKey: Self.historyKey)
        LogManager.shared.info("helpGuide", "帮助搜索历史已清空", context: [:])
    }

    /// 清除全部已读标记（「全部已读」误触后的恢复手段；最近阅读历史不受影响）
    func resetReadProgress() {
        let cleared = readArticleIds.count
        readArticleIds = []
        UserDefaults.standard.set([], forKey: Self.readKey)
        LogManager.shared.info("helpGuide", "阅读进度已清除", context: [
            "clearedCount": "\(cleared)",
            "recentKept": "\(recentArticleIDs.count)"
        ])
    }

    // MARK: 学习引导

    /// 同分类下的下一篇（用于「有帮助」后的继续学习引导；已是本分类最后一篇则返回 nil）
    func nextArticle(after article: HelpArticle) -> HelpArticle? {
        let list = HelpCatalog.articles(inCategory: article.categoryId)
        guard let idx = list.firstIndex(where: { $0.id == article.id }) else { return nil }
        guard list.indices.contains(idx + 1) else { return nil }
        return list[idx + 1]
    }
}