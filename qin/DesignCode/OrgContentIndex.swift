//
//  OrgContentIndex.swift
//  山西晋中理工学院 APP — 机构设置模块（升级 · 阶段一）
//
//  机构内容索引与分页状态机（模块内新增，纯逻辑、可离线单测）：
//  - 栏目真值源：/dept/home2 响应的 nav 数组（每项即一个栏目；首页为聚合项）
//  - 栏目类型分派：列表类走 /common/column/articles 全量分页；非列表类走官网兜底
//  - 请求并发闸 OrgRequestGate（≤3，与图片闸 SJZImageConcurrencyGate 独立）
//  - 分页状态机 OrgPagerState（纯值类型：去重追加 / total 真值 / 翻到底判定）
//
//  依据（2026-09-30 实测，见 .trae/documents/org-module-upgrade/02-设计稿.md v1.2）：
//  - /college/home 对全部学院站 nav 为空 → 学院与部门统一走 /dept/home2
//  - nav 项顶层无 articles；total 需从首页嵌套区块种子或分页响应的 data.articles.total 获取
//

import Foundation

// MARK: - 栏目类型（渲染分派）

/// 栏目渲染种类
enum OrgColumnKind: String {
    /// 列表类：走 /common/column/articles 全量分页
    case list
    /// 非列表类：空态 + 官网兜底入口（link / opinion / 未知类型）
    case webFallback
    /// 校园日历：专属板块（阶段二接入；阶段一按 webFallback 呈现）
    case calendar

    /// componentType → 渲染分派
    /// 全站实测分布（52 个 home2 响应）：tabs 49 / news 33 / notice 32 / opinion 26 / notice-small 24 /
    /// news-important 14 / content 11 / download 9 / link 4 / tabs-sub 4 / teacher 2 / electronic-book 2 /
    /// calendar 1 / thematic-center 1 / videos 1 / recruit 1 / "0" 8
    static func classify(_ componentType: String?) -> OrgColumnKind {
        let t = (componentType ?? "").trimmingCharacters(in: .whitespaces)
        switch t {
        case "news", "news-important", "notice", "notice-small", "content", "download",
             "tabs", "tabs-sub", "teacher", "videos", "electronic-book", "thematic-center", "recruit":
            return .list
        case "calendar":
            return .calendar
        default:
            return .webFallback
        }
    }
}

// MARK: - 栏目规格

struct OrgColumnSpec: Identifiable, Equatable {
    /// columnId（稳定主键）
    let id: String
    let title: String
    let columnId: String
    let siteId: String
    let componentType: String?
    /// nav 项的 path（形如 `?toIndex:home=news` / `introduction`），仅作官网兜底线索
    let href: String?

    var kind: OrgColumnKind { OrgColumnKind.classify(componentType) }
}

// MARK: - 栏目索引构建（纯函数）

enum OrgColumnIndexBuilder {

    /// 聚合项标题（首页板块不是栏目本身，其嵌套区块才是真栏目）
    static let aggregateTitles: Set<String> = ["首页"]

    /// 特殊工具入口标题（保留原有交互路由：专业介绍 / 历年分数线 / 录取查询）
    static func isToolTitle(_ title: String) -> Bool {
        title.contains("专业介绍") || title.contains("分数线") || title.contains("录取查询")
    }

    struct ToolChild: Equatable {
        let title: String
        let columnId: String?
        let siteId: String?
        let href: String?
    }

    struct Result: Equatable {
        let columns: [OrgColumnSpec]
        /// 首页嵌套区块的 total 种子（columnId → total）：chips 首屏即可显示真实篇数
        let seedTotals: [String: Int]
        /// 特殊工具入口（专业介绍 / 历年分数线 / 录取查询）
        let toolChildren: [ToolChild]
    }

    /// 从 home2 的 nav 构建栏目索引
    /// - Parameters:
    ///   - nav: `/dept/home2` 的导航数组
    ///   - defaultSiteId: 兜底 site_id（nav 项缺失时使用）
    static func build(nav: [NetworkService.DeptNavItemDTO], defaultSiteId: String) -> Result {
        var columns: [OrgColumnSpec] = []
        var seeds: [String: Int] = [:]
        var tools: [ToolChild] = []
        var seen = Set<String>()

        func appendColumn(columnId: String?, title: String, siteId: String?,
                          componentType: String?, href: String?) {
            guard let cid = columnId, !cid.isEmpty, !seen.contains(cid) else { return }
            seen.insert(cid)
            let resolvedTitle = title.isEmpty ? "栏目" : title
            columns.append(OrgColumnSpec(
                id: cid,
                title: resolvedTitle,
                columnId: cid,
                siteId: siteId ?? defaultSiteId,
                componentType: componentType,
                href: href
            ))
        }

        for item in nav {
            let title = item.titleCn ?? item.titleEn ?? ""
            let siteId = item.siteId ?? defaultSiteId

            // 1) 聚合项（首页）：采集 total 种子与子栏目，不下发为栏目
            if aggregateTitles.contains(title) {
                if let data = item.data {
                    for (_, section) in data {
                        if let cid = section.columnId, let total = section.articles?.total, total > 0 {
                            seeds[cid] = max(seeds[cid] ?? 0, total)
                        }
                        for child in section.children?.list ?? [] {
                            guard let cid = child.id, !cid.isEmpty else { continue }
                            if let total = child.articles?.total, total > 0 {
                                seeds[cid] = max(seeds[cid] ?? 0, total)
                            }
                            appendColumn(columnId: cid,
                                         title: child.titleCn ?? child.titleEn ?? "",
                                         siteId: child.siteId ?? siteId,
                                         componentType: child.componentType,
                                         href: child.href)
                        }
                    }
                }
                continue
            }

            // 2) 普通 nav 项 = 一个栏目（无论其 data 是否为菜单型字符串元数据）
            appendColumn(columnId: item.columnId,
                         title: title,
                         siteId: item.siteId,
                         componentType: item.componentType,
                         href: item.path)

            // 3) 子导航项（深层菜单）：工具入口单独收集，其余并入栏目
            for sub in item.children ?? [] {
                let subTitle = sub.titleCn ?? sub.titleEn ?? ""
                if isToolTitle(subTitle) {
                    tools.append(ToolChild(title: subTitle,
                                           columnId: sub.columnId,
                                           siteId: sub.siteId ?? siteId,
                                           href: sub.path))
                    continue
                }
                appendColumn(columnId: sub.columnId,
                             title: subTitle.isEmpty ? title : subTitle,
                             siteId: sub.siteId ?? siteId,
                             componentType: sub.componentType,
                             href: sub.path)
            }

            // 4) nav 项 data 内的 children（菜单型栏目）：工具入口 / 子栏目
            if let data = item.data {
                for (_, section) in data {
                    for child in section.children?.list ?? [] {
                        let childTitle = child.titleCn ?? child.titleEn ?? ""
                        if isToolTitle(childTitle) {
                            tools.append(ToolChild(title: childTitle,
                                                   columnId: child.id,
                                                   siteId: child.siteId ?? siteId,
                                                   href: child.href))
                            continue
                        }
                        appendColumn(columnId: child.id,
                                     title: childTitle,
                                     siteId: child.siteId ?? siteId,
                                     componentType: child.componentType,
                                     href: child.href)
                    }
                }
            }
        }

        // 工具入口去重（按标题）
        var toolSeen = Set<String>()
        let uniqueTools = tools.filter { toolSeen.insert($0.title).inserted }

        return Result(columns: columns, seedTotals: seeds, toolChildren: uniqueTools)
    }

    /// 默认选中栏目：优先「有 total 种子且属于列表类」的首个，其次首个列表类，最后首个栏目
    static func defaultColumn(in columns: [OrgColumnSpec], seedTotals: [String: Int]) -> OrgColumnSpec? {
        let listColumns = columns.filter { $0.kind == .list }
        if let seeded = listColumns.first(where: { (seedTotals[$0.columnId] ?? 0) > 0 }) {
            return seeded
        }
        return listColumns.first ?? columns.first
    }
}

// MARK: - 请求并发闸（≤3，模块内独立）

/// 机构模块网络并发闸：焦点预取 / 分页 / 详情三路发起前统一准入。
/// 与图片闸 `SJZImageConcurrencyGate` 相互独立（图片与数据请求预算分离）。
actor OrgRequestGate {
    static let shared = OrgRequestGate(maxConcurrent: 3)

    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = maxConcurrent
    }

    /// 当前活跃并发数（诊断用）
    var activeCount: Int { active }

    func withPermit<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    /// 准入：无等待者且未满 → 直接进入；否则排队（FIFO，保证公平与上限严格）
    private func acquire() async {
        if waiters.isEmpty && active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // 被唤醒即接棒：计数由 release 交接，此处不再自增
    }

    /// 释放：有等待者则**交接**名额（active 不变），否则递减
    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active -= 1
        }
    }
}

// MARK: - 分页状态机（纯值类型）

/// 栏目分页状态：去重追加 / total 真值 / 翻到底判定
struct OrgPagerState {
    /// 每页条数（阶段一固定 40，服务端 size 无上限）
    static let pageSize = 40

    private(set) var articles: [OrgArticle] = []
    private(set) var total: Int?
    private(set) var loadedPages = 0
    /// 最近一页返回条数（total 未知时用于推断是否还有更多）
    private(set) var lastPageCount = 0
    var isLoading = false
    var isLoadingMore = false
    var errorText: String?
    /// 是否已翻到底并触发过边界提示（避免重复触觉/提示）
    var reachedEndNotified = false

    /// 已显示条数
    var displayedCount: Int { articles.count }

    /// 是否还有更多：total 已知按真值；未知时以「最近一页是否满页」推断
    var hasMore: Bool {
        if isLoading || isLoadingMore { return false }
        if loadedPages == 0 { return true }
        if let total { return articles.count < total }
        return lastPageCount >= Self.pageSize
    }

    /// 是否已经翻到底（total 已知且已全部加载）
    var isExhausted: Bool {
        guard let total, loadedPages > 0 else { return false }
        return articles.count >= total
    }

    /// 进度文案：「已显示 40 / 653」
    var progressText: String {
        if let total {
            return "已显示 \(articles.count) / \(total)"
        }
        return "已显示 \(articles.count)"
    }

    /// 下一次请求的页码（1 基）
    var nextPage: Int { loadedPages + 1 }

    /// 开始加载（reset = 首屏/切栏目；否则加载更多）
    mutating func beginLoad(reset: Bool) {
        errorText = nil
        if reset {
            isLoading = true
        } else {
            isLoadingMore = true
        }
    }

    /// 应用一页响应
    /// - Returns: 新增条数（按 articleId 去重后）
    @discardableResult
    mutating func apply(page: Int, list: [OrgArticle], total: Int?) -> Int {
        isLoading = false
        isLoadingMore = false
        if let total { self.total = total }

        var existing = Set(articles.map { $0.articleId })
        var added = 0
        for article in list where existing.insert(article.articleId).inserted {
            articles.append(article)
            added += 1
        }
        loadedPages = max(loadedPages, page)
        lastPageCount = list.count
        return added
    }

    mutating func fail(_ message: String) {
        isLoading = false
        isLoadingMore = false
        errorText = message
    }

    /// 目标条数（用于种子 total 先于分页返回时展示进度）
    mutating func seedTotal(_ total: Int) {
        if self.total == nil { self.total = total }
    }
}

// MARK: - 单文章型机构解析（运行时解析，严禁硬编码）

/// 单文章型机构全文条目（无独立子站的机构：党委组织部 / 工会 / 妇联 等 11 个）
struct SingleArticleEntry: Equatable {
    let articleId: String
    let title: String
    let updateTime: String
}

enum OrgSingleArticleResolver {
    /// 依据机构名从官网机构树解析 article_id（单文章型机构 / 双配型机构）
    static func articleId(forOrgName name: String) async -> String? {
        guard let nodes = try? await NetworkService.shared.fetchSchoolOrgTree() else { return nil }
        let target = name.replacingOccurrences(of: " ", with: "")
        // 精确匹配优先，其次包含匹配（官网机构名可能含括号后缀，如「党委学生工作部(武装部)」）
        if let exact = nodes.first(where: { $0.name.replacingOccurrences(of: " ", with: "") == target && $0.articleId != nil }) {
            return exact.articleId
        }
        return nodes.first(where: {
            guard let aid = $0.articleId, !aid.isEmpty else { return false }
            let nodeName = $0.name.replacingOccurrences(of: " ", with: "")
            return nodeName.contains(target) || target.contains(nodeName)
        })?.articleId
    }
}