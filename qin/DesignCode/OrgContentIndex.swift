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

/// 栏目渲染种类（九形态 + 兜底，对应设计稿 v2.2 §2.1）
enum OrgColumnKind: String {
    /// 列表类：走 /common/column/articles 全量分页（news/notice/notice-small/news-important/download/electronic-book/thematic-center/tabs/tabs-sub）
    case list
    /// 单篇：content（进入即直渲正文；列接口 total=1，2026-10-01 实证）
    case content
    /// 视频：videos（列接口 total=0，改读 college/home 内嵌板块；实现期核对播放源）
    case video
    /// 师资：teacher（须走 /common/teacher/page；官网直访页为空壳，2026-10-01 实证）
    case teacher
    /// 招生查询：recruit（POST /common/recruit/query，RSA 实现期取证）
    case recruit
    /// 校园日历：calendar（/school/events + CampusCalendarStore 联动）
    case calendar
    /// 校长信箱/联系我们：opinion（/school/msg + PrincipalMailboxView 联动；判定见 classify）
    case opinion
    /// 外链：link（内嵌 Web；数据源 = nav.path 绝对 URL，2026-10-01 实证）
    case link
    /// 未知类型/空："0"/无映射 → 空态壳（官网确无列表内容）
    case webFallback

    /// componentType + 标题/path → 渲染分派
    /// 全站实测分布（178 栏目）：news 25 / notice 26 / notice-small 16 / tabs 26 / tabs-sub 4 / content 11 /
    /// download 7 / news-important 7 / opinion 10 / link 4 / teacher 2 / electronic-book 2 /
    /// calendar 1 / thematic-center 1 / videos 1 / recruit 1 / "0" 7 / 空 27
    ///
    /// - Note: 官网许多栏目 componentType 为空串，但首页聚合数据块内嵌 articles.total 给出真值可读线索。
    ///   2026-10-02 实证（信创学院）：「学院简介」componentType=""、内嵌 total=1 → 应走单篇 content；
    ///   「学院发展」total=8 → 应走列表。此时若无内嵌 total 兜底会误落 webFallback（空态壳、不发请求）。
    static func classify(_ componentType: String?, title: String? = nil, path: String? = nil,
                         embeddedTotal: Int? = nil) -> OrgColumnKind {
        let t = (componentType ?? "").trimmingCharacters(in: .whitespaces)
        switch t {
        case "content": return .content
        case "videos": return .video
        case "teacher": return .teacher
        case "recruit": return .recruit
        case "calendar": return .calendar
        case "opinion": return .opinion
        case "link": return .link
        case "news", "news-important", "notice", "notice-small", "download", "electronic-book",
             "thematic-center", "tabs", "tabs-sub":
            return .list
        default:
            break
        }
        let titleText = title ?? ""
        // 简介类栏目：标题含「简介」且内嵌有文章 → 统一单篇直渲（官网简介页即单篇正文；
        // 2026-10-02 实证：信创 total=1、文法 total=2，两院官网结构一致，App 取第一篇直渲保证同构）
        if let total = embeddedTotal {
            if total > 0 && titleText.contains("简介") {
                return .content
            }
            if total > 1 { return .list }
            if total == 1 { return .content }
        }
        // 官网 componentType 常为空：以标题 / path 二次判定（2026-10-01 实机实证）
        let pathText = path ?? ""
        // 师资形态：标题含「师资/队伍」或 path=teacher（马院「师资队伍」实证：componentType=None、
        // data 无线索，但 /common/teacher/page 返回 total=23 → 必须走 teacher 形态否则空态）
        if titleText.contains("师资") || pathText.contains("teacher") {
            return .teacher
        }
        if titleText.contains("联系") || titleText.contains("意见") || titleText.contains("反馈")
            || pathText.contains("contact") || pathText.contains("opinion") {
            return .opinion
        }
        return .webFallback
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
    /// nav 项的 path（形如 `?toIndex:home=news` / `introduction` / 外链绝对 URL），仅作官网兜底/形态线索
    let href: String?
    /// 渲染种类（构建时一次性判定，避免每帧重算）
    let kind: OrgColumnKind

    init(id: String, title: String, columnId: String, siteId: String,
         componentType: String?, href: String?, embeddedTotal: Int? = nil) {
        self.id = id
        self.title = title
        self.columnId = columnId
        self.siteId = siteId
        self.componentType = componentType
        self.href = href
        self.kind = OrgColumnKind.classify(componentType, title: title, path: href, embeddedTotal: embeddedTotal)
    }
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
                          componentType: String?, href: String?, embeddedTotal: Int? = nil) {
            guard let cid = columnId, !cid.isEmpty, !seen.contains(cid) else { return }
            seen.insert(cid)
            let resolvedTitle = title.isEmpty ? "栏目" : title
            columns.append(OrgColumnSpec(
                id: cid,
                title: resolvedTitle,
                columnId: cid,
                siteId: siteId ?? defaultSiteId,
                componentType: componentType,
                href: href,
                embeddedTotal: embeddedTotal
            ))
        }

        /// 子栏目内嵌文章数：`articles` 键缺失时回退 `data` 键（2026-10-02 实证马院等机构用 data 键）
        func childEmbeddedTotal(_ child: NetworkService.DeptChildDTO) -> Int? {
            child.articles?.total ?? child.data?.total
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
                            let embedded = childEmbeddedTotal(child)
                            if let total = embedded, total > 0 {
                                seeds[cid] = max(seeds[cid] ?? 0, total)
                            }
                            appendColumn(columnId: cid,
                                         title: child.titleCn ?? child.titleEn ?? "",
                                         siteId: child.siteId ?? siteId,
                                         componentType: child.componentType,
                                         href: child.href,
                                         embeddedTotal: embedded)
                        }
                    }
                }
                continue
            }

            // 2) 普通 nav 项 = 一个栏目（无论其 data 是否为菜单型字符串元数据）
            //    例外：nav 项 data 内含 `children` 键（tabs-sub 容器，2026-10-02 实证马院「学院概况」），
            //    自身列 total=0 只是容器壳，其子栏目才是真内容 → 跳过自身空栏目，仅下发子栏目。
            if let dataChildren = item.dataChildren, !(dataChildren.list?.isEmpty ?? true) {
                for child in dataChildren.list ?? [] {
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
                                 href: child.href,
                                 embeddedTotal: childEmbeddedTotal(child))
                }
                continue
            }
            appendColumn(columnId: item.columnId,
                         title: title,
                         siteId: item.siteId,
                         componentType: item.componentType,
                         href: item.path,
                         embeddedTotal: item.articles?.total ?? item.data?["articles"]?.articles?.total)

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
                             href: sub.path,
                             embeddedTotal: sub.articles?.total)
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
                                     href: child.href,
                                     embeddedTotal: childEmbeddedTotal(child))
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

// MARK: - 正文图片查看桥（阶段三 A：WKWebView JS → 看图载荷；纯函数可单测）

/// 正文图片点击 → `SJZImageGalleryPayload` 构造（DOM 序图集 + 落点索引重映射）
///
/// 规则（与 SJZImageGalleryPayload.make 同口径）：
/// - 跳过空串 / 非 http(s) URL，并把「被点击项」映射到过滤后的落点索引（点第 N 张必开第 N 张）
/// - alts 与 urls 同序；alts 短于 urls 时缺位补空串（供 VoiceOver）
enum OrgGalleryPayloadBuilder {

    /// - Parameters:
    ///   - index: JS 侧「可查看图集」中被点图片的索引
    ///   - urls: JS 侧 DOM 序图集（已为绝对 URL）
    ///   - alts: 与 urls 同序的 alt 文本
    ///   - source: 日志归因标识
    nonisolated static func make(index: Int, urls: [String], alts: [String],
                                 source: String = "organization_detail") -> SJZImageGalleryPayload? {
        var resolved: [URL] = []
        var resolvedAlts: [String] = []
        var start = 0
        for (position, raw) in urls.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            if position == index { start = resolved.count }
            resolved.append(url)
            resolvedAlts.append(position < alts.count ? alts[position] : "")
        }
        guard !resolved.isEmpty else { return nil }
        return SJZImageGalleryPayload(urls: resolved, alts: resolvedAlts,
                                      startIndex: start, source: source)
    }
}

// MARK: - 正文富媒体探针（阶段三 A：视频内联播放的日志取证）

enum OrgMediaProbe {
    /// 正文视频源数量（`<video src>` / `<source src>`；仅日志取证，不参与渲染决策）
    nonisolated static func videoSourceCount(in html: String) -> Int {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)<(?:video|source)\b[^>]*\bsrc\s*=\s*["'][^"']+["']"#,
            options: []
        ) else { return 0 }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.numberOfMatches(in: html, options: [], range: range)
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

// MARK: - 首页数据缓存（阶段二：预取与详情共用；TTL 30 分钟）

/// 门户机构摘要（列表页焦点区展示；篇数随栏目 chips 惰性获取真值，此处只给可得真值）
struct PortalStats: Equatable {
    let siteKey: String
    let columnCount: Int
    let latestTitle: String?
    let latestTime: String
}

/// 机构首页数据缓存（内存 TTL 30 分钟，与 `OrganizationManager.refreshInterval` 语义一致）
@MainActor
final class OrgHomeCache {
    static let shared = OrgHomeCache()

    /// 门户机构（列表页焦点区固定 3 个：教务处 / 团委 / 商学院）
    static let portalSiteKeys = ["jwc", "tw", "sxy"]

    private struct Entry {
        let data: NetworkService.DeptHome2DTO
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 1800

    func cached(siteKey: String) -> NetworkService.DeptHome2DTO? {
        guard let entry = entries[siteKey],
              Date().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.data
    }

    func store(_ data: NetworkService.DeptHome2DTO, for siteKey: String) {
        entries[siteKey] = Entry(data: data, fetchedAt: Date())
    }

    /// 取首页数据（新鲜缓存直返；否则经 OrgRequestGate 拉取并写入 —— 预取与详情共用同一缓存键）
    func home(siteKey: String, force: Bool = false) async throws -> NetworkService.DeptHome2DTO {
        if !force, let cached = cached(siteKey: siteKey) {
            return cached
        }
        let data = try await OrgRequestGate.shared.withPermit {
            try await NetworkService.shared.fetchDeptHome2(siteKey: siteKey)
        }
        store(data, for: siteKey)
        return data
    }

    /// 门户机构预取（列表页展开 = 3 请求；失败静默留痕，不阻塞列表）
    func prefetchPortals() async -> [String: PortalStats] {
        var result: [String: PortalStats] = [:]
        for siteKey in Self.portalSiteKeys {
            do {
                let data = try await home(siteKey: siteKey)
                if let stats = Self.stats(from: data, siteKey: siteKey) {
                    result[siteKey] = stats
                }
            } catch {
                LogManager.shared.warning("organization", "门户机构预取失败", context: [
                    "siteKey": siteKey,
                    "error": error.localizedDescription
                ])
            }
        }
        if !result.isEmpty {
            LogManager.shared.info("organization", "门户机构预取完成", context: [
                "count": "\(result.count)",
                "portals": result.keys.sorted().joined(separator: ",")
            ])
        }
        return result
    }

    /// 由 home2 响应提取可得真值（列表类栏目数 + 最新一篇标题/时间）
    static func stats(from data: NetworkService.DeptHome2DTO, siteKey: String) -> PortalStats? {
        let nav = data.nav ?? []
        guard !nav.isEmpty else { return nil }
        let index = OrgColumnIndexBuilder.build(nav: nav, defaultSiteId: "1")
        let columnCount = index.columns.filter { $0.kind == .list }.count

        // 最新一篇：取首页嵌套区块 articles.list 中 update_time 最大者（服务端已按时间排序，仍取最大值保证稳健）
        var latestTitle: String?
        var latestTime = ""
        for item in nav {
            guard let blockData = item.data else { continue }
            for (_, section) in blockData {
                for article in section.articles?.list ?? [] {
                    let time = article.updateTime ?? ""
                    if time > latestTime, let title = article.title, !title.isEmpty {
                        latestTime = time
                        latestTitle = title
                    }
                }
            }
        }
        return PortalStats(siteKey: siteKey, columnCount: columnCount,
                           latestTitle: latestTitle, latestTime: latestTime)
    }
}