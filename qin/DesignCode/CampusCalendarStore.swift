//
//  CampusCalendarStore.swift
//  山西晋中理工学院 APP — 校园日历数据中枢
//
//  校园服务第七项「校园日历」数据层：
//  · 官网校园生活-校园日历栏目（column_id 固定常量）文章列表 + 详情，直接复用 NetworkService
//    fetchArticles/fetchArticleDetail，零新接口；
//  · 冷启动「本地缓存优先展示 → 静默刷新」双通道 + 下拉刷新三态状态机（独立 Task 防取消误报）；
//  · 本地多词 AND 搜索（300ms 防抖 + 搜索前分页全量拉齐 + 权重排序）+ 搜索历史（去重置顶 ≤10）；
//  · 详情内存缓存 + 已读落盘；
//  · 全链路沉底/耗时日志（LogManager 域 campusCalendar），「我的-应用日志」可全程追溯。
//

import Foundation

@MainActor
final class CampusCalendarStore: ObservableObject {

    static let shared = CampusCalendarStore()

    // MARK: - 常量

    private static let pageSize = 20
    /// 搜索前全量拉齐的安全页数上限（超出后仍可搜索，但仅覆盖已缓存页）
    private static let maxPages = 10
    private static let cacheKey = "campusCalendarCache"
    private static let historyKey = "campusCalendarSearchHistory"
    private static let readIdsKey = "campusCalendarReadArticleIds"

    // MARK: - 发布状态

    @Published private(set) var articles: [NetworkService.ArticleDTO] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreFailed = false
    @Published private(set) var hasMore = true
    @Published private(set) var lastError: String?
    /// 当前展示内容是否来自本地离线缓存（刷新成功前显示「离线缓存」徽章）
    @Published private(set) var isFromCache = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var refreshStatus: RefreshStatus = .idle
    @Published private(set) var searchResults: [NetworkService.ArticleDTO] = []
    @Published private(set) var searchHitCount = 0
    /// 防抖窗口内的搜索执行中指示（UI 显示「正在搜索…」，杜绝结果未更新的错觉）
    @Published private(set) var isSearchPending = false
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var readIds: Set<String> = []

    // MARK: - 刷新状态机（三态：空闲/进行中/成功/失败——下拉、进入、重试的统一可视反馈）

    enum RefreshStatus: Equatable {
        case idle
        case refreshing
        case success(elapsedMs: Int, total: Int, at: Date)
        case failed(message: String)
    }

    // MARK: - 内部状态

    private var page = 1
    private var hasLoaded = false
    private var refreshInFlight = false
    private var loadTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var detailCache: [String: NetworkService.ArticleDetailDTO] = [:]

    private init() {
        searchHistory = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
        readIds = Set(UserDefaults.standard.stringArray(forKey: Self.readIdsKey) ?? [])
    }

    // MARK: - 本地列表缓存

    private struct CachePayload: Codable {
        let fetchedAt: Date
        let total: Int
        let articles: [NetworkService.ArticleDTO]
    }

    /// 读取本地缓存并发布（无缓存时静默返回）
    private func loadCache() {
        guard articles.isEmpty else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              !payload.articles.isEmpty else {
            LogManager.shared.debugLog("campusCalendar", "本地缓存读取未命中", context: [:])
            return
        }
        let startedAt = Date()
        articles = payload.articles
        total = payload.total
        page = 1
        hasMore = articles.count < total
        isFromCache = true
        lastRefreshDate = payload.fetchedAt
        LogManager.shared.info("campusCalendar", "本地缓存读取命中", context: [
            "count": "\(payload.articles.count)",
            "fetchedAt": Self.logDateText(payload.fetchedAt),
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ])
    }

    private func saveCache() {
        let payload = CachePayload(fetchedAt: Date(), total: total, articles: articles)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            LogManager.shared.debugLog("campusCalendar", "本地缓存已写入", context: [
                "count": "\(articles.count)", "bytes": "\(data.count)"
            ])
        }
    }

    // MARK: - 首次加载 / 静默刷新（先缓存后刷新）

    func loadInitial(force: Bool = false) {
        if hasLoaded && !force { return }
        guard loadTask == nil else {
            LogManager.shared.debugLog("campusCalendar", "拉取跳过", context: ["reason": "已有进行中任务"])
            return
        }
        if articles.isEmpty { loadCache() }
        loadTask = Task { await silentLoad() }
    }

    private func silentLoad() async {
        isLoading = true
        lastError = nil
        let startedAt = Date()
        LogManager.shared.info("campusCalendar", "列表拉取开始", context: [
            "page": "1", "pageSize": "\(Self.pageSize)", "source": isFromCache ? "缓存后静默刷新" : "首次加载"
        ])

        do {
            let data = try await NetworkService.shared.fetchArticles(
                columnId: NetworkService.campusCalendarColumnId,
                siteId: "1", page: 1, size: Self.pageSize)
            let list = data.articles?.list ?? []
            total = data.articles?.total ?? list.count
            articles = list
            page = 1
            hasMore = articles.count < total
            hasLoaded = true
            isFromCache = false
            lastRefreshDate = Date()
            loadMoreFailed = false
            saveCache()
            LogManager.shared.info("campusCalendar", "列表拉取成功", context: [
                "count": "\(list.count)", "total": "\(total)", "hasMore": "\(hasMore)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        } catch {
            guard !Task.isCancelled else {
                LogManager.shared.debugLog("campusCalendar", "静默拉取已取消（由手动刷新接管）", context: [:])
                isLoading = false
                loadTask = nil
                return
            }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.error("campusCalendar", "列表拉取失败", context: [
                "error": lastError ?? "(无)", "hasLoaded": "\(hasLoaded)", "hasCache": "\(!articles.isEmpty)"
            ])
        }
        isLoading = false
        loadTask = nil
    }

    // MARK: - 手动刷新（下拉/工具栏/重试；独立 Task 保证不被手势收回取消误报）

    /// 下拉刷新专用入口：刷新本体放入独立 Task，本函数仅作为等待句柄
    func refreshDetached(source: String) async {
        let task = Task { await refresh(source: source) }
        _ = await task.value
    }

    func refresh(source: String) async {
        guard !refreshInFlight else {
            LogManager.shared.debugLog("campusCalendar", "手动刷新跳过", context: ["reason": "刷新进行中", "source": source])
            return
        }
        refreshInFlight = true
        refreshStatus = .refreshing
        let startedAt = Date()
        LogManager.shared.info("campusCalendar", "手动刷新开始", context: ["source": source])

        if let task = loadTask {
            task.cancel()
            loadTask = nil
        }
        // 接管在途的搜索防抖/全量拉齐，避免与刷新并发双写列表
        searchDebounceTask?.cancel()
        isSearchPending = false
        LogManager.shared.debugLog("campusCalendar", "刷新已接管并取消搜索侧任务", context: ["source": source])

        do {
            let data = try await NetworkService.shared.fetchArticles(
                columnId: NetworkService.campusCalendarColumnId,
                siteId: "1", page: 1, size: Self.pageSize)
            let list = data.articles?.list ?? []
            total = data.articles?.total ?? list.count
            articles = list
            page = 1
            hasMore = articles.count < total
            hasLoaded = true
            isFromCache = false
            lastRefreshDate = Date()
            loadMoreFailed = false
            saveCache()
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            refreshStatus = .success(elapsedMs: elapsed, total: total, at: Date())
            LogManager.shared.info("campusCalendar", "手动刷新成功", context: [
                "source": source, "total": "\(total)", "count": "\(list.count)", "elapsedMs": "\(elapsed)"
            ])
        } catch {
            if (error as? URLError)?.code == .cancelled {
                refreshStatus = .idle
                LogManager.shared.debugLog("campusCalendar", "手动刷新被取消（非失败，不展示失败横幅）", context: ["source": source])
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                refreshStatus = .failed(message: message)
                LogManager.shared.error("campusCalendar", "手动刷新失败", context: [
                    "source": source, "error": message
                ])
            }
        }
        refreshInFlight = false
    }

    /// 隐藏刷新结果横幅（成功类横幅由 UI 延时自动调用）
    func dismissRefreshBanner() {
        if refreshStatus != .refreshing {
            refreshStatus = .idle
        }
    }

    // MARK: - 分页加载更多（触底续拉）

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, loadTask == nil else { return }
        let nextPage = page + 1
        isLoadingMore = true
        loadMoreFailed = false
        let startedAt = Date()
        LogManager.shared.info("campusCalendar", "加载更多开始", context: [
            "page": "\(nextPage)", "loaded": "\(articles.count)", "total": "\(total)"
        ])

        do {
            let data = try await NetworkService.shared.fetchArticles(
                columnId: NetworkService.campusCalendarColumnId,
                siteId: "1", page: nextPage, size: Self.pageSize)
            let list = data.articles?.list ?? []
            articles.append(contentsOf: list)
            total = data.articles?.total ?? total
            page = nextPage
            hasMore = articles.count < total
            saveCache()
            LogManager.shared.info("campusCalendar", "加载更多成功", context: [
                "added": "\(list.count)", "loaded": "\(articles.count)", "total": "\(total)",
                "hasMore": "\(hasMore)", "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        } catch {
            guard !Task.isCancelled else {
                LogManager.shared.debugLog("campusCalendar", "加载更多已取消", context: ["page": "\(nextPage)"])
                isLoadingMore = false
                return
            }
            loadMoreFailed = true
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.error("campusCalendar", "加载更多失败", context: [
                "page": "\(nextPage)", "error": message
            ])
        }
        isLoadingMore = false
    }

    // MARK: - 本地搜索（多词 AND + 权重排序 + 300ms 防抖）

    func search(_ keyword: String) {
        searchDebounceTask?.cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        LogManager.shared.debugLog("campusCalendar", "搜索输入", context: [
            "keyword": trimmed, "length": "\(trimmed.count)"
        ])
        guard !trimmed.isEmpty else {
            isSearchPending = false
            searchResults = []
            searchHitCount = 0
            LogManager.shared.debugLog("campusCalendar", "搜索清空，恢复全部列表", context: [:])
            return
        }
        isSearchPending = true
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else {
                LogManager.shared.debugLog("campusCalendar", "搜索防抖被替换（新输入到达）", context: [:])
                return
            }
            await self?.performSearch(trimmed)
        }
    }

    /// 防抖后执行：确保全量语料 → 多词 AND 匹配 → 权重排序 → 记录历史
    private func performSearch(_ keyword: String) async {
        let startedAt = Date()
        LogManager.shared.info("campusCalendar", "搜索防抖执行开始", context: [
            "keyword": keyword, "loaded": "\(articles.count)", "total": "\(total)"
        ])

        // 语料不完整时先全量拉齐剩余分页（保证搜索覆盖官网全部校历文章）
        if articles.count < total && hasMore {
            let complete = await ensureFullCorpus()
            if !complete {
                LogManager.shared.warning("campusCalendar", "搜索全量拉齐未完成，仅搜索已缓存文章", context: [
                    "loaded": "\(articles.count)", "total": "\(total)"
                ])
            }
        }

        let words = keyword.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var scored: [(article: NetworkService.ArticleDTO, score: Int)] = []
        for article in articles {
            let title = article.resolvedTitle ?? article.title ?? ""
            let desc = article.description ?? ""
            var score = 0
            var allMatched = true
            for word in words {
                let inTitle = title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                let inDesc = desc.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                if inTitle {
                    score += 3
                } else if inDesc {
                    score += 1
                } else {
                    allMatched = false
                    break
                }
            }
            if allMatched { scored.append((article, score)) }
        }
        // 权重降序（稳定：同分保持文章原始顺序）
        searchResults = scored.sorted { $0.score > $1.score }.map { $0.article }
        searchHitCount = searchResults.count
        isSearchPending = false
        commitSearchHistory(keyword)
        LogManager.shared.info("campusCalendar", "搜索执行完成", context: [
            "keyword": keyword, "hits": "\(searchHitCount)", "words": "\(words.count)",
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ])
    }

    /// 搜索前的分页全量拉齐（受 maxPages 上限保护）
    private func ensureFullCorpus() async -> Bool {
        var complete = true
        var fetchedPages = 0
        while articles.count < total && hasMore && fetchedPages < Self.maxPages {
            fetchedPages += 1
            do {
                let next = page + 1
                let data = try await NetworkService.shared.fetchArticles(
                    columnId: NetworkService.campusCalendarColumnId,
                    siteId: "1", page: next, size: Self.pageSize)
                let list = data.articles?.list ?? []
                articles.append(contentsOf: list)
                total = data.articles?.total ?? total
                page = next
                hasMore = articles.count < total
                saveCache()
            } catch {
                complete = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                LogManager.shared.error("campusCalendar", "搜索全量拉齐中断", context: [
                    "page": "\(page + 1)", "error": message
                ])
                break
            }
        }
        if fetchedPages > 0 {
            LogManager.shared.info("campusCalendar", "搜索全量拉齐结束", context: [
                "fetchedPages": "\(fetchedPages)", "loaded": "\(articles.count)", "total": "\(total)"
            ])
        }
        return complete
    }

    // MARK: - 搜索历史（去重置顶 ≤10，UserDefaults 落盘）

    func commitSearchHistory(_ keyword: String) {
        var list = searchHistory.filter { $0 != keyword }
        list.insert(keyword, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        searchHistory = list
        UserDefaults.standard.set(list, forKey: Self.historyKey)
        LogManager.shared.debugLog("campusCalendar", "搜索历史写入", context: [
            "keyword": keyword, "count": "\(list.count)"
        ])
    }

    func clearSearchHistory() {
        let count = searchHistory.count
        searchHistory = []
        UserDefaults.standard.set([String](), forKey: Self.historyKey)
        LogManager.shared.info("campusCalendar", "搜索历史一键清空", context: ["removed": "\(count)"])
    }

    // MARK: - 详情（内存缓存 + 已读落盘）

    func loadDetail(articleId: String) async -> NetworkService.ArticleDetailDTO? {
        if let cached = detailCache[articleId] {
            LogManager.shared.info("campusCalendar", "详情缓存命中", context: [
                "articleId": articleId, "elapsedMs": "0"
            ])
            return cached
        }
        let startedAt = Date()
        LogManager.shared.info("campusCalendar", "详情加载开始", context: ["articleId": articleId])
        do {
            let detail = try await NetworkService.shared.fetchArticleDetail(articleId: articleId)
            detailCache[articleId] = detail
            markRead(articleId: articleId)
            LogManager.shared.info("campusCalendar", "详情加载成功", context: [
                "articleId": articleId,
                "contentChars": "\(detail.content?.count ?? 0)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
            return detail
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.error("campusCalendar", "详情加载失败", context: [
                "articleId": articleId, "error": message
            ])
            return nil
        }
    }

    // MARK: - 已读状态（落盘，返回列表可显示「已读」）

    func isRead(articleId: String?) -> Bool {
        guard let articleId else { return false }
        return readIds.contains(articleId)
    }

    func markRead(articleId: String) {
        guard !readIds.contains(articleId) else { return }
        readIds.insert(articleId)
        UserDefaults.standard.set(Array(readIds), forKey: Self.readIdsKey)
        LogManager.shared.debugLog("campusCalendar", "文章标记已读", context: ["articleId": articleId])
    }

    // MARK: - 工具

    /// 官网时间串 → 展示串（yyyy.MM.dd；无法解析时取前 10 字符）
    static func dateText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd"
            let f3 = DateFormatter(); f3.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return [f1, f2, f3]
        }()
        for fmt in formatters {
            if let date = fmt.date(from: raw) {
                let out = DateFormatter(); out.dateFormat = "yyyy.MM.dd"
                return out.string(from: date)
            }
        }
        if let date = ISO8601DateFormatter().date(from: raw) {
            let out = DateFormatter(); out.dateFormat = "yyyy.MM.dd"
            return out.string(from: date)
        }
        return String(raw.prefix(10))
    }

    private static func logDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}