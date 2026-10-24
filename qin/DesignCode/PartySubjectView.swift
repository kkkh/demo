//
//  PartySubjectView.swift
//  DesignCode
//
//  党建专题模块（首页资讯区新增，涵盖官网两个子站）：
//  · 党建工作（site_key=djgz）：新闻速递 / 理论学习 / 基层动态
//  · 思政专题（site_key=mkszy）：新闻动态 / 经典著作 / 党建工作 / 课程建设(课程介绍·课程动态)
//    / 制度文件 / 学院概况(tab 页) 等全部栏目
//  设计要点：
//  · 首载一次性拉全两站全部栏目文章（每栏上限 4 页×50=200，远端最大栏目仅 74 篇 → 100% 覆盖），
//    浏览与搜索为本地即时过滤，结果秒回；「深度搜索」按钮对超限栏目追加 8 页×50 网络保障；
//  · 栏目/站点结构运行时动态解析（严禁硬编码栏目 ID），文章 ID 生成代际令牌防旧写入污染；
//  · 完整 party 模块日志埋点 + 刷新状态机（进行中/成功/失败三态横幅）。
//

import SwiftUI
import UIKit

// MARK: - 数据模型

/// 栏目信息（含服务端文章总数）
struct PartyColumnInfo: Identifiable, Hashable {
    let id: String
    let title: String
    var total: Int
}

/// 站点数据（站点配置来自官网头部菜单固定路由；栏目结构运行时解析）
struct PartySiteState: Identifiable {
    let key: String
    let name: String
    let siteId: String
    var columns: [PartyColumnInfo] = []
    var totalArticles: Int = 0
    var articlesByColumn: [String: [OrgArticle]] = [:]

    var id: String { key }
}

/// 文章条目（携带来源信息，供列表与搜索统一展示）
struct PartyArticleRef: Identifiable {
    let id: String
    let article: OrgArticle
    let siteKey: String
    let siteName: String
    let columnName: String
    let siteId: String

    var dateText: String {
        article.updateTime.split(separator: "T").first.map(String.init) ?? article.updateTime
    }
}

// MARK: - 滚动活动追踪（共享组件，定义见 SchoolProfileView.swift）

// MARK: - 党建专题数据中枢

@MainActor
final class PartySubjectStore: ObservableObject {
    static let shared = PartySubjectStore()

    /// 站点配置（官网头部菜单固定路由；服务端栏目结构与 ID 会变更，运行时解析）
    static let siteConfigs: [(key: String, name: String)] = [
        ("djgz", "党建工作"),
        ("mkszy", "思政专题")
    ]

    /// 常规覆盖：每栏最多 4 页 × 50 条 = 200 篇
    static let regularLimit = 200
    /// 深度覆盖：每栏最多 8 页 × 50 条 = 400 篇
    static let deepLimit = 400
    private static let pageSize = 50

    /// 手动刷新状态机（工具栏/下拉/重试入口的直观反馈来源）
    enum RefreshStatus: Equatable {
        case idle
        case refreshing
        case success(newCount: Int, elapsedMs: Int, at: Date)
        case failed(message: String)
    }

    @Published private(set) var sites: [PartySiteState] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastError: String?
    /// 同步进度文案（首载/刷新/深度搜索期间直观状态提示；nil 表示无进行中同步）
    @Published private(set) var syncProgressText: String?
    @Published private(set) var refreshStatus: RefreshStatus = .idle
    @Published private(set) var lastRefreshDate: Date?

    private var loadTask: Task<Void, Never>?
    private var refreshInFlight = false

    /// 会话级不可用栏目记忆：官网「首页」容器栏等服务端稳定返回业务 500（code=500, data=null），
    /// 前端常规栏目接口查不到其文章——记录后刷新跳过，避免重复无效请求
    private var unavailableColumnIds: Set<String> = []
    /// 上次拉取被容错跳过的栏目数（直观状态提示用）
    @Published private(set) var skippedColumnsCount: Int = 0

    /// 全量文章总数（首页徽章）
    var totalArticles: Int {
        sites.reduce(0) { $0 + $1.totalArticles }
    }

    // MARK: 站点/栏目查询

    func site(_ key: String) -> PartySiteState? {
        sites.first { $0.key == key }
    }

    /// 某站聚合文章（跨栏目，按时间倒序；浏览「全部」与本地搜索共用）
    func aggregatedArticles(siteKey: String) -> [PartyArticleRef] {
        guard let site = site(siteKey) else { return [] }
        var refs: [PartyArticleRef] = []
        for column in site.columns {
            guard let arts = site.articlesByColumn[column.id] else { continue }
            for art in arts {
                refs.append(PartyArticleRef(
                    id: "\(siteKey)|\(column.id)|\(art.articleId)",
                    article: art,
                    siteKey: siteKey,
                    siteName: site.name,
                    columnName: column.title,
                    siteId: site.siteId
                ))
            }
        }
        return refs.sorted { $0.article.updateTime > $1.article.updateTime }
    }

    /// 本地全文搜索（跨站点跨栏目模糊匹配）：
    /// · 输入按空白分词，多词为 AND 关系（每词都需命中）；
    /// · 匹配范围 = 标题（权重 5）+ 描述（权重 2）+ 标签（权重 1），命中词数累加；
    /// · 排序：相关度总分 ↓ → 发布时间 ↓。
    func localSearch(keyword: String) -> [PartyArticleRef] {
        let raw = keyword.trimmingCharacters(in: .whitespaces)
        let terms = raw.split(whereSeparator: { $0 == " " || $0 == "　" })
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var scored: [(ref: PartyArticleRef, score: Int)] = []
        for site in sites {
            for column in site.columns {
                guard let arts = site.articlesByColumn[column.id] else { continue }
                for art in arts {
                    let titleLower = art.title.lowercased()
                    let descLower = art.description.lowercased()
                    let tagLower = art.tag.lowercased()
                    var score = 0
                    var matchedTerms = 0
                    for term in terms {
                        var hit = false
                        if titleLower.contains(term) { score += 5; hit = true }
                        if descLower.contains(term) { score += 2; hit = true }
                        if !tagLower.isEmpty && tagLower.contains(term) { score += 1; hit = true }
                        if hit { matchedTerms += 1 }
                    }
                    // 多词全部命中才计入结果（AND 语义）
                    guard matchedTerms == terms.count, score > 0 else { continue }
                    scored.append((PartyArticleRef(
                        id: "\(site.key)|\(column.id)|\(art.articleId)",
                        article: art,
                        siteKey: site.key,
                        siteName: site.name,
                        columnName: column.title,
                        siteId: site.siteId
                    ), score))
                }
            }
        }
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.ref.article.updateTime > $1.ref.article.updateTime
            }
            .map(\.ref)
    }

    /// 搜索结果的两站命中分布（搜索状态栏直观展示）
    func searchHitDistribution(keyword: String) -> [(siteName: String, count: Int)] {
        let results = localSearch(keyword: keyword)
        let order = Self.siteConfigs.map(\.name)
        var counts: [String: Int] = [:]
        for ref in results {
            counts[ref.siteName, default: 0] += 1
        }
        return order
            .filter { (counts[$0] ?? 0) > 0 }
            .map { ($0, counts[$0] ?? 0) }
    }

    // MARK: 拉取控制

    /// 懒加载：成功过则跳过；进行中则跳过。深度强制由 refresh 通道执行。
    func loadIfNeeded(force: Bool = false) {
        if hasLoaded && !force { return }
        guard loadTask == nil else {
            LogManager.shared.debugLog("party", "拉取跳过", context: ["reason": "已有进行中任务"])
            return
        }
        loadTask = Task { await silentLoad() }
    }

    /// 下拉刷新专用入口：独立任务执行本体，防 SwiftUI .refreshable 任务取消误报（与信箱同款方案）
    func refreshDetached(source: String) async {
        let task = Task { await refresh(source: source) }
        _ = await task.value
    }

    /// 手动刷新：必定执行一次真实全量拉取，并发布完整状态供 UI 反馈
    func refresh(source: String) async {
        guard !refreshInFlight else {
            LogManager.shared.debugLog("party", "手动刷新跳过", context: ["reason": "刷新进行中", "source": source])
            return
        }
        refreshInFlight = true
        refreshStatus = .refreshing
        let startedAt = Date()
        LogManager.shared.info("party", "手动刷新开始", context: ["source": source])

        if let task = loadTask {
            task.cancel()
            loadTask = nil
        }

        isLoading = true
        do {
            try await performFullFetch(limit: Self.regularLimit, progress: { [weak self] text in
                self?.syncProgressText = text
            })
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastRefreshDate = Date()
            refreshStatus = .success(newCount: totalArticles, elapsedMs: elapsed, at: Date())
            LogManager.shared.info("party", "手动刷新成功", context: [
                "source": source, "elapsedMs": "\(elapsed)", "totalArticles": "\(totalArticles)"
            ])
        } catch {
            if (error as? URLError)?.code == .cancelled {
                refreshStatus = .idle
                LogManager.shared.debugLog("party", "手动刷新被取消（非失败，不展示失败横幅）", context: ["source": source])
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                refreshStatus = .failed(message: message)
                LogManager.shared.error("party", "手动刷新失败", context: ["source": source, "error": message])
            }
        }
        isLoading = false
        refreshInFlight = false
    }

    /// 深度搜索：对超常规上限的栏目追加网络深拉（8 页×50），完成后交由本地过滤
    func deepSearchSupplement(keyword: String, onComplete: @escaping ([PartyArticleRef]) -> Void) async {
        LogManager.shared.info("party", "深度搜索启动", context: ["keyword": keyword])
        do {
            try await performFullFetch(limit: Self.deepLimit, progress: { [weak self] text in
                self?.syncProgressText = text
            })
            onComplete(localSearch(keyword: keyword))
            LogManager.shared.info("party", "深度搜索补充完成", context: [
                "keyword": keyword, "totalArticles": "\(totalArticles)"
            ])
        } catch {
            LogManager.shared.error("party", "深度搜索补充失败", context: [
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
            onComplete(localSearch(keyword: keyword))
        }
    }

    /// 隐藏成功横幅（由 UI 延时自动调用；失败横幅保留等待处理）
    func dismissRefreshBanner() {
        if refreshStatus != .refreshing {
            refreshStatus = .idle
        }
    }

    // MARK: 核心拉取

    private func silentLoad() async {
        isLoading = true
        lastError = nil
        syncProgressText = "正在同步党建专题数据…"
        let startedAt = Date()
        LogManager.shared.info("party", "党建专题数据拉取开始", context: [
            "sites": "\(Self.siteConfigs.map(\.key).joined(separator: ","))",
            "limit": "\(Self.regularLimit)"
        ])

        do {
            try await performFullFetch(limit: Self.regularLimit, progress: { [weak self] text in
                self?.syncProgressText = text
            })
            hasLoaded = true
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            LogManager.shared.info("party", "党建专题数据拉取成功", context: [
                "totalArticles": "\(totalArticles)",
                "skippedColumns": "\(skippedColumnsCount)",
                "elapsedMs": "\(elapsed)",
                "columns": "\(sites.map { "\($0.name):\($0.columns.count)" }.joined(separator: ","))"
            ])
        } catch {
            guard !Task.isCancelled else {
                LogManager.shared.debugLog("party", "静默拉取已取消（由手动刷新接管）", context: [:])
                return
            }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.error("party", "党建专题数据拉取失败", context: [
                "error": lastError ?? "(无)", "hasLoaded": "\(hasLoaded)"
            ])
        }

        syncProgressText = nil
        isLoading = false
        loadTask = nil
    }

    /// 全量拉取两站全部栏目（运行时解析站点索引 → 栏目并发分页 → 组装状态）
    private func performFullFetch(limit: Int, progress: @escaping (String) -> Void) async throws {
        var newSites: [PartySiteState] = []
        var skipped = 0

        for config in Self.siteConfigs {
            progress("正在同步「\(config.name)」栏目结构…")
            let siteStartedAt = Date()
            let (siteId, columns) = try await NetworkService.shared.fetchDeptSiteIndex(siteKey: config.key)
            LogManager.shared.debugLog("party", "站点栏目解析完成", context: [
                "site": config.key, "columns": "\(columns.count)", "siteId": siteId
            ])

            let result = await fetchSiteArticles(
                siteKey: config.key,
                siteId: siteId,
                columns: columns,
                limit: limit,
                progress: { done, count in
                    progress("正在同步「\(config.name)」文章（\(done)/\(count) 栏目）…")
                }
            )
            let siteElapsed = Int(Date().timeIntervalSince(siteStartedAt) * 1000)
            LogManager.shared.debugLog("party", "站点同步完成", context: [
                "site": config.key,
                "elapsedMs": "\(siteElapsed)",
                "columns": "\(result.infos.count)",
                "grandTotal": "\(result.grandTotal)",
                "stored": "\(result.articlesByColumn.values.reduce(0) { $0 + $1.count })",
                "skipped": "\(result.skipped)"
            ])
            skipped += result.skipped
            newSites.append(PartySiteState(
                key: config.key,
                name: config.name,
                siteId: siteId,
                columns: result.infos,
                totalArticles: result.grandTotal,
                articlesByColumn: result.articlesByColumn
            ))
        }

        sites = newSites
        hasLoaded = true
        skippedColumnsCount = skipped
        syncProgressText = nil
        if skipped > 0 {
            LogManager.shared.warning("party", "本次拉取存在被容错跳过的栏目", context: [
                "skipped": "\(skipped)", "remembered": "\(unavailableColumnIds.count)"
            ])
        }
    }

    /// 单站全栏目拉取（栏目内并发分块 6 路；**单栏失败容错隔离，绝不拖垮全站**）
    private func fetchSiteArticles(
        siteKey: String,
        siteId: String,
        columns: [NetworkService.DeptColumnRef],
        limit: Int,
        progress: @escaping (Int, Int) -> Void
    ) async -> (infos: [PartyColumnInfo], articlesByColumn: [String: [OrgArticle]], grandTotal: Int, skipped: Int) {
        var infos: [PartyColumnInfo] = []
        var articlesByColumn: [String: [OrgArticle]] = [:]
        var grandTotal = 0
        var skipped = 0
        var done = 0

        // 6 路分块并发，控制瞬时并发峰值
        let chunks = stride(from: 0, to: columns.count, by: 6).map {
            Array(columns[$0..<min($0 + 6, columns.count)])
        }

        for chunk in chunks {
            await withTaskGroup(of: (NetworkService.DeptColumnRef, Int, [OrgArticle], String?).self) { group in
                for column in chunk {
                    group.addTask {
                        // 会话内已确认不可用的栏目直接跳过，刷新不重复踩坑
                        let unavailable = await MainActor.run {
                            self.unavailableColumnIds.contains(column.id)
                        }
                        guard !unavailable else {
                            return (column, 0, [], nil)
                        }
                        let result = await self.fetchColumnArticlesTolerant(
                            columnId: column.id, siteId: siteId, limit: limit
                        )
                        return (column, result.total, result.articles, result.error)
                    }
                }
                for await (column, total, articles, error) in group {
                    done += 1
                    if let error {
                        skipped += 1
                        unavailableColumnIds.insert(column.id)
                        LogManager.shared.warning("party", "栏目文章拉取失败（已容错跳过，不影响其他栏目）", context: [
                            "site": siteKey,
                            "column": column.title,
                            "columnId": column.id,
                            "error": error
                        ])
                    } else if total > 0 {
                        infos.append(PartyColumnInfo(id: column.id, title: column.title, total: total))
                        articlesByColumn[column.id] = articles
                        grandTotal += total
                    }
                }
            }
            progress(done, columns.count)
        }

        LogManager.shared.info("party", "站点文章拉取完成", context: [
            "site": siteKey,
            "columns": "\(infos.count)",
            "grandTotal": "\(grandTotal)",
            "skipped": "\(skipped)"
        ])
        return (infos, articlesByColumn, grandTotal, skipped)
    }

    /// 单栏目分页拉取（页大小 50；达到 limit 或最后一页停止）。
    /// 任何单栏错误就地捕获并返回 error 文案——**绝不向上抛错**（单个栏目不可用不代表整体失败）
    private func fetchColumnArticlesTolerant(columnId: String, siteId: String, limit: Int) async -> (total: Int, articles: [OrgArticle], error: String?) {
        var collected: [OrgArticle] = []
        var total = 0
        var page = 1
        let columnStartedAt = Date()
        while collected.count < limit {
            do {
                let dto = try await NetworkService.shared.fetchArticles(
                    columnId: columnId, siteId: siteId, page: page, size: Self.pageSize
                )
                let list = dto.articles?.list ?? []
                if page == 1 {
                    total = dto.articles?.total ?? 0
                }
                if list.isEmpty { break }
                for item in list {
                    guard let id = item.id, let title = item.resolvedTitle, !title.isEmpty else { continue }
                    collected.append(OrgArticle(
                        id: id,
                        title: title,
                        description: item.description ?? "",
                        imageUrl: item.imageUrl,
                        updateTime: item.updateTime ?? "",
                        tag: item.tag ?? "",
                        articleId: id,
                        sectionSiteId: siteId
                    ))
                }
                if list.count < Self.pageSize || collected.count >= total { break }
                page += 1
            } catch {
                // 首页容器类栏目服务端稳定返回业务 500（HTTP 200 + code=500 + data=null）→ requireData
                // 抛 serverError；此类"栏目不可用"属预期，容错跳过而非整体失败
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let columnElapsed = Int(Date().timeIntervalSince(columnStartedAt) * 1000)
                LogManager.shared.debugLog("party", "栏目拉取明细（失败容错）", context: [
                    "columnId": String(columnId.prefix(12)),
                    "fetched": "\(collected.count)",
                    "pages": "\(page)",
                    "elapsedMs": "\(columnElapsed)",
                    "error": message
                ])
                return (0, [], message)
            }
        }
        let columnElapsed = Int(Date().timeIntervalSince(columnStartedAt) * 1000)
        LogManager.shared.debugLog("party", "栏目拉取明细", context: [
            "columnId": String(columnId.prefix(12)),
            "serverTotal": "\(total)",
            "fetched": "\(collected.count)",
            "pages": "\(page)",
            "elapsedMs": "\(columnElapsed)"
        ])
        return (total, collected, nil)
    }
}

// MARK: - 党建专题页

struct PartySubjectView: View {
    @ObservedObject private var store = PartySubjectStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// 当前站点 key（默认党建工作）
    @State private var selectedSiteKey: String = PartySubjectStore.siteConfigs[0].key
    /// 当前栏目（nil = 全部）
    @State private var selectedColumnId: String?
    /// 详情弹窗
    @State private var detailArticle: PartyArticleRef?
    /// 刷新成功脉冲（工具栏对勾）
    @State private var refreshSuccessPulse = false

    // 搜索
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchHistory: [String] =
        UserDefaults.standard.stringArray(forKey: "partySearchHistory") ?? []
    @State private var searchLogTask: Task<Void, Never>?
    /// 深度搜索进行中
    @State private var isDeepSearching = false
    /// 搜索输入起点判定（空 → 非空记录"搜索输入开始"）
    @State private var searchWasEmpty = true
    /// 触底日志节流时间戳
    @State private var lastBottomLogTime = Date.distantPast

    // MARK: 数据计算

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var currentSite: PartySiteState? {
        store.site(selectedSiteKey)
    }

    /// 搜索结果（本地即时过滤；深度搜索完成后同样回落此计算）
    private var searchResults: [PartyArticleRef] {
        store.localSearch(keyword: trimmedSearch)
    }

    /// 浏览列表：全部 = 聚合按时间倒序；具体栏目 = 该栏文章
    private var browseArticles: [PartyArticleRef] {
        guard let site = currentSite else { return [] }
        if let columnId = selectedColumnId {
            guard let arts = site.articlesByColumn[columnId] else { return [] }
            let name = site.columns.first(where: { $0.id == columnId })?.title ?? ""
            return arts.map {
                PartyArticleRef(
                    id: "\(site.key)|\(columnId)|\($0.articleId)",
                    article: $0, siteKey: site.key, siteName: site.name,
                    columnName: name, siteId: site.siteId
                )
            }
            .sorted { $0.article.updateTime > $1.article.updateTime }
        }
        return store.aggregatedArticles(siteKey: site.key)
    }

    // MARK: 视图

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                siteTabs
                searchSection
                if isSearching {
                    searchStatusBar
                }
                contentSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .coordinateSpace(name: "partyScroll")
            .modifier(SJZScrollActivityTracker(coordinateSpace: "partyScroll") { direction in
                LogManager.shared.debugLog("party", "列表滑动方向变化", context: [
                    "direction": direction,
                    "site": selectedSiteKey,
                    "column": selectedColumnId ?? "全部",
                    "searching": "\(isSearching)"
                ])
            })
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GradientBackground())
        .navigationTitle("党建专题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { partyToolbar }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                refreshBanner
                if store.syncProgressText != nil {
                    syncProgressCapsule
                        .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
                        .zIndex(9)
                }
            }
            .padding(.top, 8)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.refreshStatus)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.syncProgressText)
        .refreshable {
            await store.refreshDetached(source: "下拉刷新")
        }
        .sheet(item: $detailArticle, onDismiss: {
            LogManager.shared.debugLog("party", "文章详情页已关闭", context: [:])
        }) { ref in
            NavigationStack {
                PartyArticleDetailView(ref: ref)
            }
            .sjzPresentationChrome()
        }
        .task {
            store.loadIfNeeded()
        }
        .onAppear {
            LogManager.shared.info("party", "党建专题页面打开", context: [
                "hasLoaded": "\(store.hasLoaded)",
                "cachedTotal": "\(store.totalArticles)"
            ])
        }
        .onDisappear {
            LogManager.shared.info("party", "党建专题页面离开", context: [
                "site": selectedSiteKey,
                "column": selectedColumnId ?? "全部",
                "searching": "\(isSearching)",
                "totalArticles": "\(store.totalArticles)"
            ])
        }
        .onChange(of: searchText) { _, newValue in
            let trimmedNow = newValue.trimmingCharacters(in: .whitespaces)
            if searchWasEmpty && !trimmedNow.isEmpty {
                LogManager.shared.debugLog("party", "搜索输入开始", context: [
                    "keyword": String(trimmedNow.prefix(12))
                ])
            }
            searchWasEmpty = trimmedNow.isEmpty
            handleSearchChange(newValue)
        }
        .onChange(of: isSearchFocused) { _, focused in
            LogManager.shared.debugLog("party", focused ? "搜索框聚焦" : "搜索框失焦", context: [
                "keywordLength": "\(trimmedSearch.count)"
            ])
        }
        .onChange(of: store.refreshStatus) { _, status in
            handleRefreshStatusChange(status)
        }
        .onChange(of: selectedSiteKey) { _, newKey in
            selectedColumnId = nil
            let site = store.site(newKey)
            LogManager.shared.info("party", "站点切换", context: [
                "site": newKey,
                "columns": "\(site?.columns.count ?? 0)",
                "articles": "\(site?.totalArticles ?? 0)"
            ])
        }
        .onChange(of: browseArticles.count) { _, newCount in
            // 浏览列表数据量变化（切换站点/栏目/刷新后）——记录一次渲染规模
            LogManager.shared.debugLog("party", "浏览列表渲染", context: [
                "site": selectedSiteKey,
                "column": selectedColumnId ?? "全部",
                "searching": "\(isSearching)",
                "count": "\(newCount)"
            ])
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var partyToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                // 更多操作菜单：切换站点 / 打开官网党建页（原返回键长按菜单功能迁移至此）
                Menu {
                    ForEach(PartySubjectStore.siteConfigs, id: \.key) { config in
                        Button {
                            selectedSiteKey = config.key
                            LogManager.shared.info("party", "菜单·切换站点", context: [
                                "from": selectedSiteKey, "to": config.key
                            ])
                        } label: {
                            if selectedSiteKey == config.key {
                                Label(config.name, systemImage: "checkmark")
                                    .displayLabelFont(17)
                            } else {
                                Text(config.name)
                                    .displayLabelFont(17)
                            }
                        }
                    }
                    Divider()
                    Button {
                        let urlString = "\(SchoolInfo.website)/#/departments/page?site_key=\(selectedSiteKey)&page=home"
                        guard let url = URL(string: urlString) else { return }
                        LogManager.shared.info("party", "菜单·打开官网党建页", context: [
                            "site": selectedSiteKey, "url": urlString
                        ])
                        UIApplication.shared.open(url)
                    } label: {
                        Label("打开官网党建页", systemImage: "safari.fill")
                            .displayLabelFont(17)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(Color.sjzRed)
                }
                .accessibilityLabel("更多操作")
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.debugLog("party", "工具栏刷新按钮点击")
                    Task { await store.refresh(source: "工具栏刷新") }
                } label: {
                    Group {
                        if store.refreshStatus == .refreshing {
                            ProgressView()
                                .tint(Color.sjzRed)
                                .scaleEffect(0.8)
                                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        } else if refreshSuccessPulse {
                            Image(systemName: "checkmark.seal.fill")
                                .displaySymbolFont(15, weight: .semibold)
                                .foregroundStyle(Color.sjzGreen)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .displaySymbolFont(13, weight: .medium)
                                .foregroundStyle(Color.sjzRed)
                                .transition(.opacity)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.refreshStatus == .refreshing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: refreshSuccessPulse)
                }
                .disabled(store.refreshStatus == .refreshing || store.isLoading)
            }
        }
    }

    private func handleRefreshStatusChange(_ status: PartySubjectStore.RefreshStatus) {
        switch status {
        case .success:
            refreshSuccessPulse = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                refreshSuccessPulse = false
                store.dismissRefreshBanner()
                LogManager.shared.debugLog("party", "成功横幅自动隐藏", context: [:])
            }
        case .failed(let message):
            LogManager.shared.debugLog("party", "刷新失败横幅展示", context: ["error": message])
        case .refreshing, .idle:
            break
        }
    }

    // MARK: ① 主题头卡（红色党建主题）

    private var heroCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "C8102E"), Color.sjzRed, Color.sjzOrange.opacity(0.9)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 12)
                .frame(width: 120, height: 120)
                .offset(x: 145, y: -52)

            Circle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 64, height: 64)
                .offset(x: -148, y: 56)

            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: "flag.fill")
                            .displaySymbolFont(24, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    Text("传递党的声音")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("党建专题")
                        .displayFont(22, weight: .heavy)
                        .foregroundStyle(.white)
                    Text("党建工作 · 思政专题 · 凝聚奋进力量")
                        .displayFont(11)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer(minLength: 0)

                if store.hasLoaded {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(store.totalArticles)")
                            .displayFont(24, weight: .heavy)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("篇专题文章")
                            .displayFont(9, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.sjzRed.opacity(0.35), radius: 20, y: 10)
    }

    // MARK: ② 子站切换

    private var siteTabs: some View {
        HStack(spacing: 8) {
            ForEach(PartySubjectStore.siteConfigs, id: \.key) { config in
                let selected = selectedSiteKey == config.key
                Button {
                    LogManager.shared.debugLog("party", "站点 tab 点击", context: [
                        "site": config.key, "alreadySelected": "\(selected)"
                    ])
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedSiteKey = config.key
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: config.key == "djgz" ? "hammer.fill" : "book.fill")
                            .displaySymbolFont(12, weight: .semibold)
                        Text(config.name)
                            .displayFont(14, weight: .semibold)
                        if let site = store.site(config.key), site.totalArticles > 0 {
                            Text("\(site.totalArticles)")
                                .displayFont(10, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(selected ? Color.white : Color.sjzRed)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(
                                    Capsule().fill(selected ? Color.white.opacity(0.22) : Color.sjzRed.opacity(0.1))
                                )
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        Capsule().fill(selected ? Color(hex: "C8102E") : Color.primary.opacity(0.05))
                    )
                    .overlay {
                        if selected {
                            Capsule().strokeBorder(Color.sjzRed.opacity(0.4), lineWidth: 1)
                        } else {
                            Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: ③ 搜索区

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .displaySymbolFont(14, weight: .medium)
                    .foregroundStyle(Color.sjzRed)

                TextField("搜索党建与思政专题文章…", text: $searchText)
                    .displayFont(15)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit { commitSearch() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                        LogManager.shared.debugLog("party", "搜索词已清除", context: [:])
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .displaySymbolFont(14)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                if isSearchFocused {
                    Capsule().strokeBorder(Color.sjzRed.opacity(0.55), lineWidth: 1)
                } else {
                    Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isSearchFocused)

            if isSearchFocused && !isSearching && !searchHistory.isEmpty {
                searchHistoryChips
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSearchFocused)
    }

    private var searchHistoryChips: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .displaySymbolFont(11)
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searchHistory, id: \.self) { keyword in
                        Button {
                            searchText = keyword
                            isSearchFocused = false
                            LogManager.shared.info("party", "搜索历史点击", context: ["keyword": keyword])
                        } label: {
                            Text(keyword)
                                .displayFont(11, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                searchHistory = []
                UserDefaults.standard.set([String](), forKey: "partySearchHistory")
                LogManager.shared.info("party", "搜索历史已清空")
            } label: {
                Image(systemName: "trash")
                    .displaySymbolFont(11)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: ④ 内容区

    @ViewBuilder
    private var contentSection: some View {
        if isSearching {
            searchContent
        } else if store.isLoading && !store.hasLoaded {
            skeletonList
        } else if let error = store.lastError, !store.hasLoaded {
            errorCard(error)
        } else if currentSite == nil || (store.hasLoaded && currentSite?.columns.isEmpty == true) {
            emptyDataView
        } else {
            browseContent
        }
    }

    // MARK: 浏览模式

    private var browseContent: some View {
        VStack(spacing: 10) {
            // 容错跳过提示（官网容器页无独立文章；极简静默设计不打扰浏览）
            if store.skippedColumnsCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .displaySymbolFont(9)
                    Text("已自动跳过 \(store.skippedColumnsCount) 个无独立文章的栏目（如站内首页容器）")
                        .displayFont(10)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .transition(.opacity)
            }

            columnChips

            if browseArticles.isEmpty {
                emptyColumnView
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(browseArticles) { ref in
                        articleCard(ref)
                    }
                    bottomSentinel
                }
            }
        }
    }

    /// 触底哨兵：滚动接近列表末尾时回调（10 秒节流，记录浏览深度行为）
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 2)
            .onAppear {
                let now = Date()
                guard now.timeIntervalSince(lastBottomLogTime) > 10 else { return }
                lastBottomLogTime = now
                LogManager.shared.debugLog("party", "列表滚动至底部区域", context: [
                    "site": selectedSiteKey,
                    "column": selectedColumnId ?? "全部",
                    "searching": "\(isSearching)",
                    "articleCount": "\(browseArticles.count)"
                ])
            }
    }

    /// 栏目筛选 chips（全部 + 该站全部有效栏目，含文章计数）
    private var columnChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chipButton(title: "全部", count: 0, selected: selectedColumnId == nil) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selectedColumnId = nil
                    }
                    LogManager.shared.debugLog("party", "栏目切换", context: ["column": "全部"])
                }
                ForEach(currentSite?.columns ?? []) { column in
                    chipButton(title: column.title, count: column.total,
                               selected: selectedColumnId == column.id) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            selectedColumnId = column.id
                        }
                        LogManager.shared.debugLog("party", "栏目切换", context: [
                            "column": column.title, "columnId": column.id
                        ])
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chipButton(title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .displayFont(12, weight: selected ? .bold : .medium)
                if count > 0 {
                    Text("\(count)")
                        .displayFont(9, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Color.sjzRed)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.sjzRed.opacity(0.1)))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color(hex: "C8102E") : Color.primary.opacity(0.05)))
            .overlay {
                if selected {
                    Capsule().strokeBorder(Color.sjzRed.opacity(0.4), lineWidth: 1)
                } else {
                    Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 文章卡

    private func articleCard(_ ref: PartyArticleRef) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            LogManager.shared.info("party", "文章详情打开", context: [
                "articleId": ref.article.articleId,
                "site": ref.siteName,
                "column": ref.columnName,
                "title": String(ref.article.title.prefix(24))
            ])
            detailArticle = ref
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // 缩略图（无图占位）
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.sjzRed.opacity(0.12), Color.sjzOrange.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "newspaper.fill")
                        .displaySymbolFont(16)
                        .foregroundStyle(Color.sjzRed.opacity(0.45))
                    if let urlString = ref.article.imageUrl, let url = URL(string: urlString) {
                        SJZCachedImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure, .empty, .skipped:
                                Color.clear
                            }
                        }
                        .frame(width: 92, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(width: 92, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    if isSearching {
                        highlightedText(ref.article.title, keyword: trimmedSearch, baseColor: .primary)
                            .displayFont(15, weight: .semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(ref.article.title)
                            .displayFont(15, weight: .semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if !ref.article.description.isEmpty {
                        Text(ref.article.description)
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        Text(ref.dateText)
                            .displayFont(9)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text(ref.columnName)
                            .displayFont(9, weight: .semibold)
                            .foregroundStyle(Color.sjzRed)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.sjzRed.opacity(0.08)))
                        if isSearching && ref.siteName != currentSite?.name {
                            Text(ref.siteName)
                                .displayFont(9, weight: .semibold)
                                .foregroundStyle(Color.sjzIndigo)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.sjzIndigo.opacity(0.08)))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: 搜索模式

    @ViewBuilder
    private var searchContent: some View {
        if searchResults.isEmpty {
            emptySearchView
        } else {
            VStack(spacing: 10) {
                // 深度搜索按钮（对超常规上限栏目补拉 8 页×50 的网络保障）
                deepSearchButton
                LazyVStack(spacing: 10) {
                    ForEach(searchResults) { ref in
                        articleCard(ref)
                    }
                    bottomSentinel
                }
            }
        }
    }

    private var deepSearchButton: some View {
        HStack(spacing: 8) {
            Image(systemName: "rays")
                .displaySymbolFont(11)
                .foregroundStyle(Color.sjzPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("常规检索已覆盖各栏目最新 200 篇")
                    .displayFont(11, weight: .medium)
                    .foregroundStyle(.secondary)
                Text("如需追溯到更早期文章，可启动深度检索（8 页×50/栏目）")
                    .displayFont(10)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                let keyword = trimmedSearch
                isDeepSearching = true
                LogManager.shared.info("party", "深度搜索按钮点击", context: ["keyword": keyword])
                Task {
                    await store.deepSearchSupplement(keyword: keyword) { _ in
                        Task { @MainActor in
                            isDeepSearching = false
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isDeepSearching {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.doc.fill")
                            .displaySymbolFont(10, weight: .semibold)
                    }
                    Text(isDeepSearching ? "深度检索中" : "深度检索")
                        .displayFont(11, weight: .bold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(
                    LinearGradient(colors: [Color.sjzPrimary, Color.sjzIndigo],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(isDeepSearching)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private var searchStatusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .displaySymbolFont(11)
                    .foregroundStyle(Color.sjzRed)
                Text("搜索「\(trimmedSearch)」")
                    .displayFont(12, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(searchResults.count) 个结果")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
            // 两站命中分布徽章（直观可见的覆盖反馈）
            if searchResults.count > 0 {
                HStack(spacing: 6) {
                    ForEach(store.searchHitDistribution(keyword: trimmedSearch), id: \.siteName) { item in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.siteName == "党建工作" ? Color(hex: "C8102E") : Color.sjzIndigo)
                                .frame(width: 5, height: 5)
                            Text("\(item.siteName) \(item.count) 篇")
                                .displayFont(9, weight: .semibold)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: searchResults.count)
    }

    // MARK: 同步进度 / 刷新横幅

    private var syncProgressCapsule: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Color.sjzRed)
                .scaleEffect(0.7)
            Text(store.syncProgressText ?? "同步中…")
                .displayFont(11, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    @ViewBuilder
    private var refreshBanner: some View {
        switch store.refreshStatus {
        case .idle:
            EmptyView()

        case .refreshing:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Color.sjzRed)
                    .scaleEffect(0.75)
                Text("正在刷新党建专题…")
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                removal: .move(edge: .top).combined(with: .opacity)
            ))

        case .success(let total, let elapsedMs, _):
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(Color.sjzGreen)
                        .symbolEffect(.bounce, value: store.refreshStatus)
                    Text("刷新成功 · 同步 \(total) 篇专题文章")
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text("\(elapsedMs)ms")
                        .displayFont(10)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if let date = store.lastRefreshDate {
                    Text("更新于 \(Self.timeText(date))")
                        .displayFont(9)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                removal: .move(edge: .top).combined(with: .opacity)
            ))

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .displaySymbolFont(13)
                    .foregroundStyle(Color.sjzOrange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("刷新失败")
                        .displayFont(12, weight: .bold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await store.refresh(source: "横幅重试") }
                } label: {
                    Text("重试")
                        .displayFont(11, weight: .bold)
                        .foregroundStyle(Color.sjzRed)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.sjzRed.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    store.dismissRefreshBanner()
                    LogManager.shared.debugLog("party", "失败横幅手动关闭", context: [:])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            .frame(maxWidth: 400)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: 骨架 / 空态 / 错误

    private var skeletonList: some View {
        VStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 92, height: 66)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 190, height: 14)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 240, height: 12)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 120, height: 10)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var emptySearchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(34, weight: .light)
                .foregroundStyle(Color.sjzRed.opacity(0.7))
            Text("未找到匹配「\(trimmedSearch)」的文章")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("试试其他关键词，如「党课」「思政」「学习」")
                .displayFont(12)
                .foregroundStyle(.tertiary)
            Button {
                searchText = ""
            } label: {
                Text("清除搜索")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzRed)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzRed.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .onAppear {
            LogManager.shared.debugLog("party", "搜索空态展示", context: [
                "keyword": trimmedSearch,
                "totalArticles": "\(store.totalArticles)"
            ])
        }
    }

    private var emptyColumnView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .displaySymbolFont(34, weight: .light)
                .foregroundStyle(Color.sjzRed.opacity(0.7))
            Text("该栏目暂无文章")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private var emptyDataView: some View {
        VStack(spacing: 12) {
            Image(systemName: "flag.slash")
                .displaySymbolFont(34, weight: .light)
                .foregroundStyle(Color.sjzRed.opacity(0.7))
            Text("暂无专题内容")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Button {
                Task { await store.refresh(source: "空态刷新") }
            } label: {
                Text("刷新")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzRed)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzRed.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .displaySymbolFont(34, weight: .light)
                .foregroundStyle(Color.sjzOrange.opacity(0.8))
            Text("专题数据加载失败")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .displayFont(12)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                LogManager.shared.info("party", "失败重试点击", context: ["error": message])
                Task { await store.refresh(source: "失败重试") }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .displayLabelFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzRed)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzRed.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 搜索高亮（iOS 15+ AttributedString；更早系统退化为纯文本；多词分词逐个着色）

    @ViewBuilder
    private func highlightedText(_ text: String, keyword: String, baseColor: Color) -> some View {
        let terms = keyword.split(whereSeparator: { $0 == " " || $0 == "　" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if terms.isEmpty {
            Text(text)
                .foregroundColor(baseColor)
        } else if #available(iOS 15.0, *) {
            Text(partyHighlighted(text, keywords: terms, baseColor: baseColor))
        } else {
            Text(text)
                .foregroundColor(baseColor)
        }
    }

    @available(iOS 15.0, *)
    private func partyHighlighted(_ text: String, keywords: [String], baseColor: Color) -> AttributedString {
        var attr = AttributedString(text)
        var cursor = attr.startIndex
        var ranges: [Range<AttributedString.Index>] = []
        for keyword in keywords {
            while cursor < attr.endIndex,
                  let range = attr[cursor...].range(of: keyword, options: .caseInsensitive) {
                ranges.append(range)
                cursor = range.upperBound
            }
            cursor = attr.startIndex
        }
        attr.foregroundColor = baseColor
        for range in ranges {
            attr[range].foregroundColor = Color.sjzOrange
        }
        return attr
    }

    // MARK: 交互

    private func handleSearchChange(_ newValue: String) {
        searchLogTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            LogManager.shared.debugLog("party", "搜索已清空")
            return
        }
        let keyword = trimmed
        searchLogTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let hits = store.localSearch(keyword: keyword).count
            LogManager.shared.debugLog("party", "专题关键词搜索", context: [
                "keyword": keyword,
                "hits": "\(hits)",
                "total": "\(store.totalArticles)"
            ])
        }
    }

    /// 提交搜索：写入搜索历史（去重、最多 10 条）
    private func commitSearch() {
        let keyword = trimmedSearch
        guard !keyword.isEmpty else { return }
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 10 { searchHistory = Array(searchHistory.prefix(10)) }
        UserDefaults.standard.set(searchHistory, forKey: "partySearchHistory")
        isSearchFocused = false
        LogManager.shared.info("party", "搜索提交", context: [
            "keyword": keyword,
            "hits": "\(searchResults.count)",
            "historyCount": "\(searchHistory.count)"
        ])
    }
}

// MARK: - 党建文章详情（两段式全文加载）

/// 图文混排块：正文段落 / 配图（索引 id 保证完全相同的文本段不冲突）
enum PartyRichBlock: Identifiable {
    case paragraph(Int, String)
    case image(Int, URL, alt: String?)

    var id: Int {
        switch self {
        case .paragraph(let idx, _): return idx
        case .image(let idx, _, _): return idx
        }
    }
}

/// 解析输出：混排块 + 死图统计（官网失效图片已剔除，但计数保留供 UI 提示）
struct PartyParseOutcome {
    let blocks: [PartyRichBlock]
    let deadImageCount: Int
}

/// 官网 HTML → 图文混排块序列（纯正则，全项目禁止 NSAttributedString HTML 解析）
/// 图片顺序与正文段落顺序严格保持官网排列；占位图与失效图自动剔除并计数。
enum PartyContentParser {

    /// 官网占位图判定（列表 image_url 官方便是 no_picture.webp，正文中同名占位同样剔除）
    private static func isPlaceholder(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("no_picture") || lower.hasPrefix("data:")
    }

    /// 失效图源判定：官网富文本粘贴 Word/WPS 残留的本地路径（file:///C:\…\Temp\ksohtml\wps*.png）、
    /// 盘符路径、反斜杠路径、裸文件名（无斜杠、无域名）——这些在官网与 App 中均无法访问。
    private static func isDeadImageSource(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.hasPrefix("file:") || lower.hasPrefix("data:") { return true }
        if raw.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return true }
        if raw.contains("\\") { return true }
        if !raw.contains("/") { return true }
        return false
    }

    /// 相对路径/缺失域名修复（www2.sxjzit.edu.cn:8082 图片 CDN 直接放行）
    static func resolvedImageURL(_ raw: String) -> URL? {
        var urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        if urlString.hasPrefix("//") { urlString = "https:" + urlString }
        if !urlString.hasPrefix("http") {
            if urlString.hasPrefix("/") {
                urlString = "https://www.sxjzit.edu.cn" + urlString
            } else {
                return nil
            }
        }
        return ProfileImageSaveShare.safeURL(from: urlString)
    }

    /// 解析正文 HTML 为图文混排序列（死图剔除并计数）
    static func parse(html: String) -> PartyParseOutcome {
        var blocks: [PartyRichBlock] = []
        var deadImageCount = 0
        var nextIndex = 0
        let pattern = #"<img[^>]*src\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            appendTextBlocks(from: html, into: &blocks, nextIndex: &nextIndex)
            return PartyParseOutcome(blocks: blocks, deadImageCount: 0)
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        for match in matches {
            let textRange = NSRange(location: cursor, length: match.range.location - cursor)
            if textRange.length > 0 {
                appendTextBlocks(from: ns.substring(with: textRange), into: &blocks, nextIndex: &nextIndex)
            }
            if match.numberOfRanges > 1 {
                let rawSrc = ns.substring(with: match.range(at: 1))
                if isDeadImageSource(rawSrc) || isPlaceholder(rawSrc) {
                    deadImageCount += 1
                } else if let url = resolvedImageURL(rawSrc) {
                    // 图片 alt（可选，为旁白提供描述）
                    let imgTag = ns.substring(with: match.range(at: 0)) as NSString
                    var alt: String?
                    if let altPattern = try? NSRegularExpression(pattern: #"alt\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]),
                       let altMatch = altPattern.firstMatch(in: imgTag as String, range: NSRange(location: 0, length: imgTag.length)),
                       altMatch.numberOfRanges > 1 {
                        let altText = imgTag.substring(with: altMatch.range(at: 1))
                        alt = altText.isEmpty ? nil : altText
                    }
                    blocks.append(.image(nextIndex, url, alt: alt))
                    nextIndex += 1
                } else {
                    deadImageCount += 1
                }
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            appendTextBlocks(from: ns.substring(from: cursor), into: &blocks, nextIndex: &nextIndex)
        }
        // 首尾空段清理
        while let first = blocks.first {
            if case .paragraph(_, let t) = first, t.isEmpty { blocks.removeFirst() } else { break }
        }
        return PartyParseOutcome(blocks: blocks, deadImageCount: deadImageCount)
    }

    /// 文本片段 → 按块级标签拆段并剥标签
    private static func appendTextBlocks(from raw: String, into blocks: inout [PartyRichBlock], nextIndex: inout Int) {
        let split = raw
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        for paragraph in split.components(separatedBy: "\n") {
            let text = paragraph.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(nextIndex, text))
                nextIndex += 1
            }
        }
    }
}

// MARK: - 党建文章详情缓存

/// 两段式详情加载结果内存缓存（5 分钟），键 = listId|siteId：
/// 二段解析出的真实全文 id 与官网 href 一并缓存，二开零网络毫秒直出、避免重复二段请求。
final class PartyArticleDetailCache: @unchecked Sendable {
    static let shared = PartyArticleDetailCache()

    fileprivate struct Entry {
        let title: String
        let contentHTML: String
        let blocks: [PartyRichBlock]
        let deadImageCount: Int
        let resolvedArticleId: String
        let canonicalHref: String
        let updateTime: String
        let fetchedAt: Date
    }

    private let lock = NSLock()
    private var store: [String: Entry] = [:]

    fileprivate func cached(key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = store[key] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > 300 {
            store.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    func put(key: String, title: String, contentHTML: String, blocks: [PartyRichBlock],
             deadImageCount: Int,
             resolvedArticleId: String, canonicalHref: String, updateTime: String) {
        lock.lock(); defer { lock.unlock() }
        store[key] = Entry(title: title, contentHTML: contentHTML, blocks: blocks, deadImageCount: deadImageCount,
                           resolvedArticleId: resolvedArticleId, canonicalHref: canonicalHref,
                           updateTime: updateTime, fetchedAt: Date())
    }
}

// MARK: - 党建文章详情页

/// 党建专题文章详情（党旗红主题 · 图文混排全文）。
/// 关键修复：党建工作子站列表接口的 article id 与真正承载全文的 id 不一致——
/// 用列表 id 请求详情会返回空壳（content 仅 <p><br></p>），真正的全文 id
/// 藏在详情响应 href（#/list/article?id=…）中。本视图内实现「空壳判定 →
/// href 提取真实 id → 二段取全文」链路（思政专题站列表 id 即全文 id，自动一段直达），
/// 全程不触碰机构模块（OrganizationArticleDetailView），互不影响。
struct PartyArticleDetailView: View {
    let ref: PartyArticleRef

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared

    /// 加载阶段
    private enum LoadPhase: Equatable {
        case loading
        case content
        case summary      // 摘要兜底（官网无正文时的保底呈现）
        case failed(String)
    }

    @State private var phase: LoadPhase = .loading
    @State private var blocks: [PartyRichBlock] = []
    /// 官网失效配图数（富文本粘贴本地路径等，解析时已剔除）
    @State private var deadImageCount: Int = 0
    @State private var resolvedTitle: String = ""
    @State private var resolvedUpdateTime: String = ""
    @State private var canonicalHref: String?
    @State private var resolvedArticleId: String?
    /// 两段链路阶段文案（顶部状态胶囊）
    @State private var stageText: String = "正在获取全文…"
    @State private var loadStartTime = Date()
    @State private var loadTask: Task<Void, Never>?
    /// 全屏图片
    @State private var fullScreenImage: PartyFullScreenPayload?

    /// 微信分享菜单展示状态（富卡片分享：标题 + 摘要 + 原站链接 + 封面缩略图）
    @State private var showWeChatShare = false
    /// 操作结果 toast
    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?

    private var accent = Color.sjzRed

    private var cacheKey: String { "\(ref.article.articleId)|\(ref.siteId)" }

    private var displayDate: String {
        !resolvedUpdateTime.isEmpty ? resolvedUpdateTime : ref.dateText
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    heroHeader
                    switch phase {
                    case .loading:
                        loadingSection
                    case .failed(let message):
                        failedSection(message)
                    case .summary:
                        summarySection
                    case .content:
                        contentSection
                    }
                }
                .padding(.bottom, 96)
            }
            .ignoresSafeArea(edges: .top)

            // 底部操作栏（Liquid Glass）
            if phase == .content || phase == .summary {
                bottomBar
            }

            // 操作结果 toast
            if let toastText {
                toastCapsule(toastText)
                    .zIndex(20)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .readingReportTrack(articleId: ref.article.id, title: ref.article.title, source: "党建")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    // 更多操作菜单：复制全文 / 查看官网原文（原返回键长按菜单功能迁移至此）
                    if phase == .content || phase == .summary {
                        Menu {
                            Button {
                                // 微信富卡片分享（与其余文章详情页一致：标题/摘要/缩略图自动生成）
                                showWeChatShare = true
                                LogManager.shared.info("wechat", "打开微信分享菜单", context: [
                                    "entry": "party_article_detail",
                                    "articleId": ref.article.articleId,
                                    "title": resolvedTitle.isEmpty ? ref.article.title : resolvedTitle
                                ])
                            } label: {
                                Label("分享到微信", systemImage: "bubble.left.and.bubble.right.fill")
                                    .displayLabelFont(17)
                            }
                            Button {
                                copyFullText()
                            } label: {
                                Label("复制全文", systemImage: "doc.on.doc")
                                    .displayLabelFont(17)
                            }
                            Button {
                                openOriginal()
                            } label: {
                                Label("查看官网原文", systemImage: "safari.fill")
                                    .displayLabelFont(17)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .displaySymbolFont(15, weight: .semibold)
                                .foregroundStyle(accent)
                        }
                        .accessibilityLabel("更多操作")
                    }
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(17)
                            .foregroundStyle(accent)
                    }
                    .contentShape(Rectangle())
                    .accessibilityLabel("分享")
                }
            }
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .task { await loadDetail() }
    }

    // MARK: 微信分享载荷（网页卡片：标题 + 摘要 + 原站链接 + 封面缩略图）

    private var weChatSharePayload: WeChatSharePayload {
        let title = resolvedTitle.isEmpty ? ref.article.title : resolvedTitle
        let summary = fullPlainText.isEmpty ? ref.article.description : fullPlainText
        return WeChatSharePayload(
            title: title,
            description: summary,
            urlString: shareURL.absoluteString,
            thumbImageURL: ref.article.imageUrl
        )
    }

    // MARK: 分享链接（官网原文优先，无 href 时用真实 id 构造）

    private var shareURL: URL {
        if let href = canonicalHref, let url = URL(string: href), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        let id = resolvedArticleId ?? ref.article.articleId
        return URL(string: "\(SchoolInfo.website)/#/list/article?id=\(id)") ?? URL(string: SchoolInfo.website)!
    }

    // MARK: Hero 头卡

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                // 站点徽章（党旗红徽章 + 栏目）
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: "C8102E"))
                        .frame(width: 8, height: 8)
                    Text(ref.siteName)
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    LinearGradient(colors: [Color(hex: "D63031"), Color(hex: "A61B1B")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))

                if !ref.columnName.isEmpty {
                    Text(ref.columnName)
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }

            Text(resolvedTitle.isEmpty ? ref.article.title : resolvedTitle)
                .displayFont(24, weight: .bold)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)

            HStack(spacing: 10) {
                Label(displayDate, systemImage: "calendar")
                    .displayLabelFont(12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                if phase == .content || phase == .summary {
                    ReadingTimeBadgeView(
                        cachedID: "party-\(ref.article.articleId)",
                        summary: ref.article.description
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 68)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: "8E0E0E"), Color(hex: "C8102E"), Color(hex: "8E0E0E")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "flag.fill")
                    .displaySymbolFont(96)
                    .foregroundStyle(.white.opacity(0.07))
                    .offset(x: 28, y: -30)
                    .rotationEffect(.degrees(12))
                    .allowsHitTesting(false)
            }
        )
    }

    // MARK: 加载区

    private var loadingSection: some View {
        VStack(spacing: 20) {
            SJZArticleLoadingView(
                phases: ["正在获取文章全文…", "正在解析图文排版…", "正在渲染呈现…"],
                accent: accent
            )
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .displaySymbolFont(13)
                        .foregroundStyle(accent)
                    Text(stageText)
                        .displayFont(13, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                Text("两段式全文链路 · 自动识别官网真实文章 ID")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if case .loading = phase {
                    LogManager.shared.warning("party", "文章详情加载缓慢", context: [
                        "articleId": ref.article.articleId,
                        "elapsed": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))ms"
                    ])
                }
            }
        }
    }

    // MARK: 正文区（图文混排）

    private var contentSection: some View {
        VStack(spacing: 0) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(_, let text):
                    Text(text)
                        .displayFont(16)
                        .foregroundStyle(displaySettings.articleBodyColor ?? .primary)
                        .lineSpacing(7)
                        .kerning(0.4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .textSelection(.enabled)
                case .image(_, let url, let alt):
                    articleImage(url: url, alt: alt)
                }
            }
            if !blocks.isEmpty {
                VStack(spacing: 6) {
                    ArticleReadingStatsText(
                        cachedID: "party-\(ref.article.articleId)",
                        plainText: fullPlainText,
                        imageCount: imageCount
                    )
                    HStack(spacing: 6) {
                        Text("全文共 \(paragraphCount) 段 · \(imageCount) 张配图")
                        Text("·")
                        Text("数据实时来自官网")
                    }
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                    if deadImageCount > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .displaySymbolFont(10)
                            Text("官网已失效配图 \(deadImageCount) 张（源站缺失，已自动跳过）")
                        }
                        .displayFont(11)
                        .foregroundStyle(Color.sjzOrange)
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 14)
    }

    private var paragraphCount: Int {
        blocks.filter { if case .paragraph(_, _) = $0 { return true }; return false }.count
    }

    private var imageCount: Int {
        blocks.filter { if case .image(_, _, _) = $0 { return true }; return false }.count
    }

    /// 全文纯文本（复制与阅读统计统一口径）
    private var fullPlainText: String {
        blocks.compactMap { block -> String? in
            if case .paragraph(_, let t) = block { return t }
            return nil
        }.joined(separator: "\n")
    }

    private func articleImage(url: URL, alt: String?) -> some View {
        SJZCachedImage(url: url, maxPixel: 1440) { phase in
            switch phase {
            case .success(let img):
                img.resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .empty:
                ProgressView()
                    .frame(height: 180)
            case .failure:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .displaySymbolFont(30)
                    Text("图片加载失败，轻点重试")
                        .displayFont(12)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
            case .skipped:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            LogManager.shared.info("party", "文章配图点击全屏", context: [
                "articleId": ref.article.articleId, "url": url.absoluteString
            ])
            withAnimation(.snappy(duration: 0.3)) {
                fullScreenImage = PartyFullScreenPayload(url: url, title: resolvedTitle)
            }
        }
        .contextMenu {
            // 系统级长按菜单：保存/分享（WebP 经 JPEG 重编码 file-based 写入，规避 PHPhotosErrorDomain 3302）
            Button {
                LogManager.shared.info("party", "文章配图长按保存", context: [
                    "articleId": ref.article.articleId, "url": url.absoluteString
                ])
                saveImage(url)
            } label: {
                Label("保存图片", systemImage: "square.and.arrow.down")
                    .displayLabelFont(17)
            }
            ShareLink(item: url) {
                Label("分享图片", systemImage: "square.and.arrow.up")
                    .displayLabelFont(17)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alt ?? "文章配图")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点放大查看，长按可保存或分享")
        .sheet(item: $fullScreenImage) { payload in
            FullScreenImageView(url: payload.url, title: payload.title)
                .sjzPresentationChrome()
        }
    }

    private func saveImage(_ url: URL) {
        Task {
            let result = await ProfileImageSaveShare.saveToPhotos(urlString: url.absoluteString, logTag: "party")
            if let error = result {
                showToast("图片保存失败：\(error)")
                LogManager.shared.error("party", "文章配图保存失败", context: [
                    "articleId": ref.article.articleId, "url": url.absoluteString, "error": error
                ])
            } else {
                showToast("图片已保存到相册")
                LogManager.shared.info("party", "文章配图保存成功", context: [
                    "articleId": ref.article.articleId, "url": url.absoluteString
                ])
            }
        }
    }

    // MARK: 摘要兜底区

    private var summarySection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ref.article.description.isEmpty ? "该文章暂无正文内容" : ref.article.description)
                    .displayFont(16)
                    .foregroundStyle(.secondary)
                    .lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 14)

            // 兜底引导：官网查看全文（零信息损失）
            Button {
                LogManager.shared.info("party", "摘要兜底·点击查看官网原文", context: [
                    "articleId": ref.article.articleId
                ])
                openOriginal()
            } label: {
                Label("前往官网查看完整内容", systemImage: "safari.fill")
                    .displayLabelFont(15, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [accent, Color(hex: "A61B1B")],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)

            Text("官网未提供正文时展示摘要，可从官网查看完整内容")
                .displayFont(11)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 20)
    }

    // MARK: 失败区

    private func failedSection(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(46)
                .foregroundStyle(.secondary)
            Text(message)
                .displayFont(15)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 14) {
                Button {
                    LogManager.shared.info("party", "详情失败重试", context: [
                        "articleId": ref.article.articleId
                    ])
                    retryLoad()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .displayLabelFont(14, weight: .semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                Button {
                    LogManager.shared.info("party", "详情失败·展示摘要", context: [
                        "articleId": ref.article.articleId
                    ])
                    withAnimation(.easeInOut(duration: 0.25)) { phase = .summary }
                } label: {
                    Label("查看摘要", systemImage: "text.alignleft")
                        .displayLabelFont(14, weight: .medium)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 30)
    }

    // MARK: 底部操作栏

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                actionButton(
                    title: "复制全文", icon: "doc.on.doc",
                    tint: accent
                ) {
                    copyFullText()
                }
                actionButton(
                    title: "查看原文", icon: "safari.fill",
                    tint: Color.sjzAccent
                ) {
                    openOriginal()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func actionButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .displaySymbolFont(13)
                Text(title)
                    .displayFont(13, weight: .semibold)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .contentShape(Rectangle())
    }

    private func copyFullText() {
        let text: String
        if phase == .summary {
            text = ref.article.description
        } else {
            text = blocks.compactMap { block -> String? in
                if case .paragraph(_, let t) = block { return t }
                return nil
            }.joined(separator: "\n\n")
        }
        UIPasteboard.general.string = text
        showToast("全文已复制（\(text.count) 字）")
        LogManager.shared.info("party", "文章全文复制", context: [
            "articleId": ref.article.articleId, "chars": "\(text.count)"
        ])
    }

    private func openOriginal() {
        let url = shareURL
        LogManager.shared.info("party", "文章查看官网原文", context: [
            "articleId": ref.article.articleId, "url": url.absoluteString
        ])
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            showToast("无法打开原文链接")
        }
    }

    // MARK: Toast

    private func toastCapsule(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .displayFont(13, weight: .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.black.opacity(0.82), in: Capsule())
                .padding(.bottom, 96)
        }
        .allowsHitTesting(false)
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toastText = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toastText = nil }
        }
    }

    // MARK: 详情加载（两段式全文链路）

    private func retryLoad() {
        loadStartTime = Date()
        withAnimation(.easeOut(duration: 0.2)) { phase = .loading }
        loadTask?.cancel()
        loadTask = Task { await loadDetail() }
    }

    private func loadDetail() async {
        loadStartTime = Date()
        phase = .loading

        // 0. 缓存命中直出（二开毫秒级、避免重复二段请求）
        if let entry = PartyArticleDetailCache.shared.cached(key: cacheKey) {
            apply(title: entry.title,
                  outcome: PartyParseOutcome(blocks: entry.blocks, deadImageCount: entry.deadImageCount),
                  resolvedId: entry.resolvedArticleId, href: entry.canonicalHref,
                  updateTime: entry.updateTime)
            LogManager.shared.info("party", "文章详情缓存命中直出", context: [
                "articleId": ref.article.articleId,
                "elapsedMs": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))"
            ])
            return
        }

        LogManager.shared.info("party", "文章详情加载开始", context: [
            "listArticleId": ref.article.articleId,
            "site": ref.siteKey, "siteId": ref.siteId,
            "column": ref.columnName, "title": ref.article.title
        ])

        do {
            // 1. 第一段：列表 id 请求详情
            let first = try await NetworkService.shared.fetchArticleDetail(
                articleId: ref.article.articleId, siteId: ref.siteId)
            let firstHTML = first.content ?? ""
            let firstStripped = firstHTML.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
            let firstIsShell = firstStripped.isEmpty && !firstHTML.hasImageContent

            if !firstIsShell {
                // 一段直达全文（思政专题站列表 id 即真实全文 id）
                stageText = "已获取官网全文"
                apply(title: first.title ?? ref.article.title,
                      outcome: PartyContentParser.parse(html: firstHTML),
                      resolvedId: first.id ?? ref.article.articleId,
                      href: first.href,
                      updateTime: first.updateTime ?? "")
                LogManager.shared.info("party", "文章全文获取成功（一段直达）", context: [
                    "listArticleId": ref.article.articleId, "stage": "single",
                    "contentLength": "\(firstHTML.count)",
                    "elapsedMs": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))"
                ])
                return
            }

            // 2. 空壳：从 href 提取真实全文 id
            LogManager.shared.info("party", "检测到详情空壳，启动二段全文链路", context: [
                "listArticleId": ref.article.articleId, "stage": "shell_detected"
            ])
            stageText = "已识别官网真实文章 ID，正在取全文…"

            let href = first.href ?? ""
            if let realId = Self.realArticleID(from: href), !realId.isEmpty, realId != ref.article.articleId {
                let second = try await NetworkService.shared.fetchArticleDetail(
                    articleId: realId, siteId: ref.siteId)
                let secondHTML = second.content ?? ""
                let secondStripped = secondHTML.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !secondStripped.isEmpty || secondHTML.hasImageContent else {
                    throw NetworkError.decodeFailed("官网全文仍为空")
                }
                stageText = "已同步官网全文"
                apply(title: second.title ?? ref.article.title,
                      outcome: PartyContentParser.parse(html: secondHTML),
                      resolvedId: realId, href: href,
                      updateTime: second.updateTime ?? "")
                LogManager.shared.info("party", "文章全文获取成功（二段 href 重定向）", context: [
                    "listArticleId": ref.article.articleId, "realArticleId": realId,
                    "stage": "two_stage", "contentLength": "\(secondHTML.count)",
                    "elapsedMs": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))"
                ])
                return
            }

            // 3. href 无法解析 id：短链形态（/s/xxx）经 302 重定向目标提取真实 id
            if let shortURL = URL(string: href),
               shortURL.scheme == "http" || shortURL.scheme == "https",
               shortURL.path.hasPrefix("/s/") {
                stageText = "正在解析官网短链…"
                if let finalURL = await NetworkService.shared.resolveShortLinkFinalURL(shortURL),
                   let shortRealId = Self.realArticleID(from: finalURL.absoluteString),
                   !shortRealId.isEmpty, shortRealId != ref.article.articleId {
                    let resolved = try await NetworkService.shared.fetchArticleDetail(
                        articleId: shortRealId, siteId: ref.siteId)
                    let resolvedHTML = resolved.content ?? ""
                    let resolvedStripped = resolvedHTML.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !resolvedStripped.isEmpty || resolvedHTML.hasImageContent else {
                        throw NetworkError.decodeFailed("官网全文仍为空")
                    }
                    stageText = "已同步官网全文"
                    apply(title: resolved.title ?? ref.article.title,
                          outcome: PartyContentParser.parse(html: resolvedHTML),
                          resolvedId: shortRealId, href: finalURL.absoluteString,
                          updateTime: resolved.updateTime ?? "")
                    LogManager.shared.info("party", "文章全文获取成功（短链解析二段）", context: [
                        "listArticleId": ref.article.articleId, "realArticleId": shortRealId,
                        "stage": "shortlink_two_stage", "shortHref": href,
                        "contentLength": "\(resolvedHTML.count)",
                        "elapsedMs": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))"
                    ])
                    return
                }
            }

            // 4. 摘要兜底
            LogManager.shared.warning("party", "官网无正文，降级摘要展示", context: [
                "listArticleId": ref.article.articleId, "stage": "summary_fallback",
                "href": String(href.prefix(60))
            ])
            await MainActor.run {
                resolvedTitle = ref.article.title
                phase = .summary
            }
        } catch {
            await MainActor.run {
                resolvedTitle = ref.article.title
                phase = .failed("全文获取失败，请检查网络后重试")
            }
            LogManager.shared.error("party", "文章全文获取失败", context: [
                "listArticleId": ref.article.articleId,
                "error": error.localizedDescription,
                "elapsedMs": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))"
            ])
        }
    }

    /// 从官网 href（如 https://www.sxjzit.edu.cn/#/list/article?id=6286…）提取真实文章 id
    static func realArticleID(from href: String) -> String? {
        guard let url = URL(string: href) else {
            let pattern = #"[?&#]id=([0-9a-fA-F]{16,})"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: href) else { return nil }
            return String(href[range])
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = comps.queryItems?.first(where: { $0.name == "id" })?.value
        if let id, !id.isEmpty { return id }
        // hash 路由内嵌 query（#/list/article?id=xxx）
        if let fragment = comps.fragment {
            let fragComps = URLComponents(string: "fake://x?" + fragment.split(whereSeparator: { $0 == "?" }).dropFirst().joined())
            return fragComps?.queryItems?.first(where: { $0.name == "id" })?.value
        }
        return nil
    }

    private func apply(title: String, outcome: PartyParseOutcome,
                       resolvedId: String, href: String?, updateTime: String) {
        let effectiveTitle = title.isEmpty ? ref.article.title : title
        let effectiveHref = (href?.isEmpty ?? true) ? nil : href
        PartyArticleDetailCache.shared.put(
            key: cacheKey, title: effectiveTitle,
            contentHTML: "", blocks: outcome.blocks, deadImageCount: outcome.deadImageCount,
            resolvedArticleId: resolvedId, canonicalHref: effectiveHref ?? "",
            updateTime: updateTime
        )
        if outcome.deadImageCount > 0 {
            LogManager.shared.warning("party", "正文包含官网失效配图，已剔除", context: [
                "articleId": ref.article.articleId,
                "deadImages": "\(outcome.deadImageCount)",
                "keptImages": "\(outcome.blocks.filter { if case .image(_, _, _) = $0 { return true }; return false }.count)"
            ])
        }
        withAnimation(.easeOut(duration: 0.25)) {
            self.resolvedTitle = effectiveTitle
            self.blocks = outcome.blocks
            self.deadImageCount = outcome.deadImageCount
            self.resolvedArticleId = resolvedId
            self.canonicalHref = effectiveHref
            self.resolvedUpdateTime = updateTime
            self.phase = .content
        }
    }
}

/// 全屏图片载荷（sheet(item:) 载体）
struct PartyFullScreenPayload: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}