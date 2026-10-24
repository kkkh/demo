//
//  SchoolProfileView.swift
//  DesignCode
//
//  学校概况模块（首页资讯区新增，对应官网 aboutUs 六个板块 + 合作交流第七板块）：
//  · 学校简介（滚动统计数字 + 学科竞赛 + 办学特色）、现任领导（7 位）、识别系统（校徽/规范图与释义）、
//    学校宣传片、校歌（原站视频）、校园风光（多图画集：详情 content 承载全部图片）、合作交流（官网 /school/cooperate）
//  设计要点：
//  · 数据源为 /mapi/school/intro（六板块全量）+ 校园风光栏目 + 图集详情接口 + /mapi/school/cooperate；
//    首载一次拉全并异步预热全部图集详情（分批并发 ≤4），画廊秒开、搜索 100% 覆盖图集全文字；
//  · 全部图片支持「点击全屏 + 长按系统菜单保存到相册/分享」——保存走 Photos 写权限（addOnly），
//    分享走系统 UIActivityViewController；完整 profile 模块日志埋点。
//  · 蓝金学术主题；视频以 AVKit 内嵌播放；刷新三态横幅 + 滚动追踪。
//

import SwiftUI
import AVKit
import UIKit
import Photos

// MARK: - 滚动活动追踪（共享组件：党建专题/学校概况等模块复用）

struct SJZScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 监听命名坐标空间内的滚动偏移，方向变化时以节流方式回调（供 UI 交互日志；不阻断渲染）
struct SJZScrollActivityTracker: ViewModifier {
    let coordinateSpace: String
    let onDirectionChange: (String) -> Void

    @State private var lastOffset: CGFloat = 0
    @State private var lastLogTime: Date = .distantPast

    public func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SJZScrollOffsetKey.self,
                        value: geo.frame(in: .named(coordinateSpace)).minY
                    )
                }
            )
            .onPreferenceChange(SJZScrollOffsetKey.self) { newOffset in
                handleOffsetChange(newOffset)
            }
    }

    private func handleOffsetChange(_ newOffset: CGFloat) {
        let delta = newOffset - lastOffset
        defer { lastOffset = newOffset }
        guard abs(delta) > 2 else { return }
        let direction = delta < 0 ? "down" : "up"
        let now = Date()
        guard now.timeIntervalSince(lastLogTime) > 3 else { return }  // 3 秒节流
        lastLogTime = now
        onDirectionChange(direction)
    }
}

// MARK: - 滚动停止后空闲计时器修复（iOS 27 Beta 手势会话卡死兼容）

/// iOS 27 Beta 兼容修复：滑动手势会话结束后，系统空闲计时器偶发卡死，
/// 表现为「滑动后屏幕永不自动熄灭」（即使 App 未请求常亮）。
/// 原理：滚动停止瞬间对 isIdleTimerDisabled 做 true→false 微切换，
/// 强制系统重新评估空闲计时状态；0.12 秒的 true 对用户完全无感，
/// 且仅当 App 未主动请求常亮（用户开关关闭且自动锁定非永不）时执行。
enum SJZIdleTimerRepair {
    static func reassert(logTag: String = "display") {
        guard !UIApplication.shared.isIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            UIApplication.shared.isIdleTimerDisabled = false
            LogManager.shared.debugLog(logTag, "滚动停止后已重断言空闲计时器（iOS 27 兼容修复）", context: [:])
        }
    }
}

/// 挂载于内容滚动容器：滚动进入 .idle（停止）时执行一次重断言（3 秒节流）。
/// 使用官方 onScrollPhaseChange（iOS 18+；本工程部署目标 iOS 26）。
struct SJZIdleTimerRepairOnScrollStop: ViewModifier {
    @State private var lastRepairAt: Date = .distantPast

    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, newPhase in
            guard newPhase == .idle else { return }
            let now = Date()
            guard now.timeIntervalSince(lastRepairAt) > 3 else { return }
            lastRepairAt = now
            SJZIdleTimerRepair.reassert()
        }
    }
}

// MARK: - 官网静态素材（资源名带内容哈希；官网重新部署后需同步核对）

enum SchoolProfileAssets {
    static let base = "https://www.sxjzit.edu.cn/assets/"
    /// 校徽
    static let markLogo = base + "mark_logo-CNp53uIF.webp"
    /// 简介标题图
    static let introTitle = base + "introduction_title-D8qIA3Wf.webp"
    /// 学科竞赛横幅
    static let introBanner = base + "introduction_banner-CvBiYN_F.webp"
    /// 办学特色图 1/2
    static let feature1 = base + "introduction_feature_1-DKkcVP2a.webp"
    static let feature2 = base + "introduction_feature_2-33bPC1GP.webp"
    /// 宣传片海报/标题图
    static let videoPoster = base + "video_poster-C5oZJsDl.webp"
    static let videoTitle = base + "video_title-DpLgsyqZ.webp"
    /// 校歌海报
    static let songPoster = base + "video_poster_song-Dq9DClqV.webp"
    /// 校名横排 1-4
    static let nameRow: [String] = (1...4).map { base + "school_name_row_\($0)-" + SchoolProfileAssets.rowHash($0) + ".webp" }
    /// 校名竖排 1-4
    static let nameColumn: [String] = (1...4).map { base + "school_name_column_\($0)-" + SchoolProfileAssets.columnHash($0) + ".webp" }

    private static func rowHash(_ n: Int) -> String {
        switch n {
        case 1: return "DzHM8a6k"
        case 2: return "D61gRdaI"
        case 3: return "C3AF_Ytj"
        default: return "BR9m2NsV"
        }
    }

    private static func columnHash(_ n: Int) -> String {
        switch n {
        case 1: return "DuLMWa76"
        case 2: return "_j-U_ns_"
        case 3: return "B5CUyWd-"
        default: return "DXSA1-UU"
        }
    }
}

// MARK: - 数据模型

/// 学校概况搜索条目（六类内容统一模型）
struct ProfileSearchEntry: Identifiable {
    let id: String
    let kind: String          // 分类名（学校简介/学科竞赛/办学特色/现任领导/校园风光/合作交流）
    let kindIcon: String      // SF Symbol
    let title: String
    let detail: String        // 描述全文
    let imageURL: String?
}

/// 合作交流条目（官网 /school/cooperate 分组文章 + 校企合作栏目文章接口全量补齐）
struct CooperateEntry: Identifiable {
    let id: String            // "分组|文章ID"（全局唯一，跨组不冲突）
    let articleId: String     // 纯文章 ID（详情接口定位）
    let groupTitle: String    // 分组名（国际交流/继续教育/校企合作）
    let groupKey: String      // 分组英文键（exchange/continuing-education/cooperation）
    let title: String
    let detail: String        // content 纯文本（交换/继教内联全文；校企合作由详情接口补齐）
    let summary: String       // 列表摘要（校企合作 description）
    let imageURL: String?
    let updateTime: String
    let needsDetailFetch: Bool // 校企合作条目：正文与图集需详情接口拉取

    /// 规范日期文案：2025-03-18
    var dateText: String {
        updateTime.split(separator: "T").first.map(String.init) ?? updateTime
    }
}

// MARK: - 学校概况数据中枢

@MainActor
final class SchoolProfileStore: ObservableObject {
    static let shared = SchoolProfileStore()

    enum RefreshStatus: Equatable {
        case idle
        case refreshing
        case success(total: Int, elapsedMs: Int, at: Date)
        case failed(message: String)
    }

    // 简介统计数字（text + 数值）
    @Published private(set) var statItems: [(text: String, number: Int)] = []
    /// 简介/竞赛/特色等文字区块
    @Published private(set) var textSections: [ProfileSearchEntry] = []
    /// 现任领导
    @Published private(set) var leaders: [ProfileSearchEntry] = []
    /// 校园风光（图片文章，OrgArticle 以复用图片缓存组件）
    @Published private(set) var sceneryArticles: [OrgArticle] = []
    /// 风光图集详情缓存（articleId → 完整图集：列表接口仅给封面，详情 content 含全部图片）
    @Published private(set) var sceneryAlbums: [String: NetworkService.SceneryAlbumDetail] = [:]
    /// 风光图集预热状态（首屏拉取后异步预载全部图集，画廊秒开 + 搜索纳入全文）
    @Published private(set) var albumsPreheat: AlbumsPreheat = .idle
    /// 合作交流分组文章（官网 /school/cooperate + 校企合作栏目文章接口全量）
    @Published private(set) var cooperateEntries: [CooperateEntry] = []
    /// 校企合作详情缓存（articleId → 正文与图集：列表接口仅给摘要，正文/图集在文章详情 content）
    @Published private(set) var cooperateDetails: [String: NetworkService.SceneryAlbumDetail] = [:]
    /// 校企合作详情预热状态（首屏拉取后异步预载全部 19 条详情：详情秒开 + 搜索纳入全文）
    @Published private(set) var cooperatePreheat: AlbumsPreheat = .idle

    enum AlbumsPreheat: Equatable {
        case idle
        case preheating
        case done(loaded: Int, failed: Int)
    }
    /// 宣传片/校歌（运行时解析，静态素材兜底）
    @Published private(set) var promoVideoURL: String?
    @Published private(set) var songVideoURL: String?
    @Published private(set) var markLogoURL: String = SchoolProfileAssets.markLogo
    @Published private(set) var introBannerURL: String = SchoolProfileAssets.introBanner

    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastError: String?
    @Published private(set) var refreshStatus: RefreshStatus = .idle
    @Published private(set) var lastRefreshDate: Date?

    private var loadTask: Task<Void, Never>?
    private var refreshInFlight = false
    /// 详情缓存代际：手动刷新会清空详情缓存并 +1，旧预热任务写回前校验代际，防止陈旧数据污染新缓存
    private var cacheGeneration = 0

    private static let sceneryColumnId = "214e6c2b44984c87831d4e96eba11793"
    private static let scenerySiteId = "1"
    /// 校企合作栏目 ID（官网 /school/cooperate 中校企合作组同源栏目；栏目文章接口取全量 19 条）
    private static let cooperationColumnId = "cc7376c390cb4aa4bc519c4858009630"
    private static let cooperationSiteId = "1"

    /// 全量可搜索条目（七类合并：简介/领导/风光/合作交流）
    var allEntries: [ProfileSearchEntry] {
        textSections + leaders + sceneryEntries + cooperateSearchEntries
    }

    private var sceneryEntries: [ProfileSearchEntry] {
        sceneryArticles.map { article in
            // 图集详情预热后，将图集正文全文并入 detail——搜索可命中图集内全部文字内容
            let albumText = sceneryAlbums[article.articleId]?.plainText ?? ""
            let fullDetail = albumText.isEmpty ? article.description : article.description + "\n" + albumText
            return ProfileSearchEntry(
                id: "scenery|\(article.articleId)",
                kind: "校园风光",
                kindIcon: "photo.on.rectangle.angled",
                title: article.title,
                detail: fullDetail,
                imageURL: article.imageUrl
            )
        }
    }

    private var cooperateSearchEntries: [ProfileSearchEntry] {
        cooperateEntries.map { item in
            // 详情预热后，将校企合作正文全文并入 detail——搜索可命中合作交流全部文字内容
            let detailText = cooperateDetails[item.articleId]?.plainText ?? ""
            let fullDetail = [item.groupTitle, item.summary, item.detail, detailText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return ProfileSearchEntry(
                id: "cooperate|\(item.id)",
                kind: "合作交流",
                kindIcon: "globe.asia.australia.fill",
                title: item.title,
                detail: fullDetail,
                imageURL: item.imageURL
            )
        }
    }

    // MARK: 拉取控制

    func loadIfNeeded(force: Bool = false) {
        if hasLoaded && !force { return }
        guard loadTask == nil else {
            LogManager.shared.debugLog("profile", "拉取跳过", context: ["reason": "已有进行中任务"])
            return
        }
        loadTask = Task { await silentLoad() }
    }

    func refreshDetached(source: String) async {
        let task = Task { await refresh(source: source) }
        _ = await task.value
    }

    func refresh(source: String) async {
        guard !refreshInFlight else {
            LogManager.shared.debugLog("profile", "手动刷新跳过", context: ["reason": "刷新进行中", "source": source])
            return
        }
        refreshInFlight = true
        refreshStatus = .refreshing
        let startedAt = Date()
        LogManager.shared.info("profile", "手动刷新开始", context: ["source": source])

        if let task = loadTask {
            task.cancel()
            loadTask = nil
        }

        isLoading = true
        // 手动刷新语义 = 与官网完全同步：清空本地详情缓存（风光图集/合作详情）并推进缓存代际，
        // 官网对既有文章正文/图集的修改才能在刷新后被重新拉取；
        // 旧的在途预热任务因代际校验失效，不会把陈旧数据写回新缓存
        cacheGeneration += 1
        sceneryAlbums.removeAll()
        cooperateDetails.removeAll()
        do {
            try await performFullFetch()
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastRefreshDate = Date()
            refreshStatus = .success(total: allEntries.count, elapsedMs: elapsed, at: Date())
            LogManager.shared.info("profile", "手动刷新成功", context: [
                "source": source, "elapsedMs": "\(elapsed)", "entries": "\(allEntries.count)"
            ])
        } catch {
            if (error as? URLError)?.code == .cancelled {
                refreshStatus = .idle
                LogManager.shared.debugLog("profile", "手动刷新被取消（非失败）", context: ["source": source])
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                refreshStatus = .failed(message: message)
                LogManager.shared.error("profile", "手动刷新失败", context: ["source": source, "error": message])
            }
        }
        isLoading = false
        refreshInFlight = false
    }

    func dismissRefreshBanner() {
        if refreshStatus != .refreshing {
            refreshStatus = .idle
        }
    }

    // MARK: 搜索（本地模糊匹配：分词 AND + 标题/详情加权）

    func localSearch(keyword: String) -> [ProfileSearchEntry] {
        let terms = keyword.split(whereSeparator: { $0 == " " || $0 == "　" })
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var scored: [(entry: ProfileSearchEntry, score: Int)] = []
        for entry in allEntries {
            let titleLower = entry.title.lowercased()
            let detailLower = entry.detail.lowercased()
            let kindLower = entry.kind.lowercased()
            var score = 0
            var matched = 0
            for term in terms {
                var hit = false
                if titleLower.contains(term) { score += 5; hit = true }
                if detailLower.contains(term) { score += 2; hit = true }
                if kindLower.contains(term) { score += 1; hit = true }
                if hit { matched += 1 }
            }
            guard matched == terms.count, score > 0 else { continue }
            scored.append((entry, score))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.title < $1.entry.title }
            .map(\.entry)
    }

    // MARK: 核心拉取

    private func silentLoad() async {
        isLoading = true
        lastError = nil
        let startedAt = Date()
        LogManager.shared.info("profile", "学校概况数据拉取开始", context: [:])

        do {
            try await performFullFetch()
            hasLoaded = true
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            LogManager.shared.info("profile", "学校概况数据拉取成功", context: [
                "leaders": "\(leaders.count)",
                "scenery": "\(sceneryArticles.count)",
                "sections": "\(textSections.count)",
                "cooperate": "\(cooperateEntries.count)",
                "elapsedMs": "\(elapsed)"
            ])
        } catch {
            guard !Task.isCancelled else {
                LogManager.shared.debugLog("profile", "静默拉取已取消（由手动刷新接管）", context: [:])
                return
            }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.error("profile", "学校概况数据拉取失败", context: [
                "error": lastError ?? "(无)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        }

        isLoading = false
        loadTask = nil
    }

    private func performFullFetch() async throws {
        // ① 六板块主接口（结构化 JSON 直解析，规避动态结构 DTO）
        let root = try await NetworkService.shared.fetchJSONDict(path: "/school/intro")
        guard let data = root["data"] as? [String: Any] else {
            throw NetworkError.decodeFailed("学校概况响应结构异常")
        }

        // 学校简介：统计数字 + 文字区块
        var stats: [(text: String, number: Int)] = []
        var sections: [ProfileSearchEntry] = []
        if let si = data["school-introduction"] as? [String: Any] {
            if let statistics = si["statistics"] as? [String: Any],
               let digits = statistics["dynamicDigit"] as? [String: Any],
               let list = digits["list"] as? [[String: Any]] {
                for item in list {
                    guard let text = item["text"] as? String else { continue }
                    let number: Int
                    if let numString = item["endNumber"] as? String, let parsed = Int(numString) {
                        number = parsed
                    } else if let numValue = item["endNumber"] as? NSNumber {
                        number = numValue.intValue
                    } else {
                        continue
                    }
                    stats.append((text, number))
                }
            }
            // compete 单块
            if let compete = si["compete"] as? [String: Any],
               let entry = Self.parseSection(compete, key: "compete", kind: "学科竞赛", icon: "trophy.fill") {
                sections.append(entry)
            }
            // features 多子块字典
            if let features = si["features"] as? [String: Any] {
                for (_, value) in features {
                    guard let sub = value as? [String: Any] else { continue }
                    if let entry = Self.parseSection(sub, key: "features", kind: "办学特色", icon: "star.fill") {
                        sections.append(entry)
                    }
                }
            }
            if !sections.isEmpty {
                textSections = sections
            }
        }
        statItems = stats

        // ② 现任领导
        var leaderEntries: [ProfileSearchEntry] = []
        if let leaderBlock = data["current-leader"] as? [String: Any],
           let leaderData = leaderBlock["data"] as? [String: Any],
           let list = leaderData["list"] as? [[String: Any]] {
            for item in list {
                guard let name = item["name"] as? String,
                      let position = item["position"] as? String else { continue }
                let text = item["text"] as? String ?? ""
                let img = item["imgSrc"] as? String
                let rowId = item["id"] as? NSNumber
                let idText = rowId.map { "\($0.intValue)" } ?? name
                leaderEntries.append(ProfileSearchEntry(
                    id: "leader|\(idText)",
                    kind: "现任领导",
                    kindIcon: "person.fill",
                    title: "\(name) · \(position)",
                    detail: text,
                    imageURL: img
                ))
            }
        }
        leaders = leaderEntries

        // ③ 宣传片 / 校歌
        if let promo = data["campus-promotion-video"] as? [String: Any],
           let promoData = promo["data"] as? [String: Any],
           let videoSrc = promoData["videoSrc"] as? [String: Any],
           let href = videoSrc["href"] as? String {
            promoVideoURL = href
        }
        if let song = data["school-song"] as? [String: Any],
           let songData = song["data"] as? [String: Any],
           let videoSrc = songData["videoSrc"] as? [String: Any],
           let href = videoSrc["href"] as? String {
            songVideoURL = href
        }

        // ④ 校园风光（栏目接口分页全量，上限 4 页覆盖）
        var scenery: [OrgArticle] = []
        var page = 1
        while page <= 4 {
            let dto = try await NetworkService.shared.fetchArticles(
                columnId: Self.sceneryColumnId, siteId: Self.scenerySiteId, page: page, size: 50
            )
            let list = dto.articles?.list ?? []
            let total = dto.articles?.total ?? 0
            for item in list {
                guard let id = item.id, let title = item.resolvedTitle, !title.isEmpty else { continue }
                scenery.append(OrgArticle(
                    id: id, title: title,
                    description: item.description ?? "",
                    imageUrl: item.imageUrl,
                    updateTime: item.updateTime ?? "",
                    tag: item.tag ?? "",
                    articleId: id,
                    sectionSiteId: Self.scenerySiteId
                ))
            }
            if list.count < 50 || scenery.count >= total { break }
            page += 1
        }
        sceneryArticles = scenery
        LogManager.shared.debugLog("profile", "校园风光拉取完成", context: ["count": "\(scenery.count)"])

        // ⑤ 风光图集预热（异步并发预载全部图集详情：画廊秒开 + 搜索纳入图集全文）
        if !scenery.isEmpty {
            Task { await preheatSceneryAlbums() }
        }
        // ⑥ 合作交流（官网 /school/cooperate，分组文章；独立容错不影响主数据）
        await fetchCooperations()
    }

    // MARK: 风光图集（列表封面 → 详情图集）

    /// 获取图集详情：内存缓存优先；未命中拉详情接口并缓存（画廊 / 长按保存共享同一份数据）
    func loadSceneryAlbum(articleId: String, title: String) async -> NetworkService.SceneryAlbumDetail? {
        if let cached = sceneryAlbums[articleId] {
            LogManager.shared.debugLog("profile", "风光图集缓存命中", context: [
                "articleId": articleId, "images": "\(cached.images.count)"
            ])
            return cached
        }
        let startedAt = Date()
        LogManager.shared.info("profile", "风光图集拉取开始", context: ["articleId": articleId, "title": String(title.prefix(20))])
        do {
            let album = try await NetworkService.shared.fetchSceneryAlbumDetail(
                articleId: articleId, siteId: Self.scenerySiteId)
            sceneryAlbums[articleId] = album
            LogManager.shared.info("profile", "风光图集拉取成功", context: [
                "articleId": articleId,
                "images": "\(album.images.count)",
                "textLen": "\(album.plainText.count)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
            return album
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.warning("profile", "风光图集拉取失败", context: [
                "articleId": articleId, "error": message
            ])
            return nil
        }
    }

    /// 预热全部风光图集详情（并发 ≤4，失败静默不阻塞；供画廊秒开与全文搜索）
    func preheatSceneryAlbums() async {
        guard albumsPreheat != .preheating else {
            LogManager.shared.debugLog("profile", "风光图集预热跳过", context: ["reason": "预热进行中"])
            return
        }
        let generation = cacheGeneration
        let pending = sceneryArticles.filter { sceneryAlbums[$0.articleId] == nil }
        guard !pending.isEmpty else {
            albumsPreheat = .done(loaded: sceneryAlbums.count, failed: 0)
            return
        }
        albumsPreheat = .preheating
        let startedAt = Date()
        LogManager.shared.info("profile", "风光图集预热开始", context: ["pending": "\(pending.count)"])
        var loaded = 0
        var failed = 0
        // 分批复用 withTaskGroup：每批 4 个并发，避免一次性 10+ 请求压学校服务器
        for chunkStart in stride(from: 0, to: pending.count, by: 4) {
            let chunk = Array(pending[chunkStart..<min(chunkStart + 4, pending.count)])
            await withTaskGroup(of: (Int, NetworkService.SceneryAlbumDetail?).self) { group in
                for article in chunk {
                    let id = article.articleId
                    let title = article.title
                    group.addTask {
                        do {
                            let album = try await NetworkService.shared.fetchSceneryAlbumDetail(
                                articleId: id, siteId: "1")
                            return (0, album)
                        } catch {
                            await LogManager.shared.debugLog("profile", "风光图集预热单项失败", context: [
                                "articleId": id, "title": String(title.prefix(16)),
                                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            ])
                            return (1, nil)
                        }
                    }
                }
                for await (flag, album) in group {
                    guard generation == cacheGeneration else { continue }
                    if flag == 0, let album {
                        sceneryAlbums[album.articleId] = album
                        loaded += 1
                    } else {
                        failed += 1
                    }
                }
            }
        }
        // 代际校验：期间发生过手动刷新（缓存已清空），丢弃本轮结果，交由新预热接管
        guard generation == cacheGeneration else {
            LogManager.shared.debugLog("profile", "风光图集预热结果作废（期间已手动刷新）", context: [:])
            return
        }
        albumsPreheat = .done(loaded: loaded, failed: failed)
        LogManager.shared.info("profile", "风光图集预热完成", context: [
            "loaded": "\(loaded)", "failed": "\(failed)",
            "cacheTotal": "\(sceneryAlbums.count)",
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ])
    }

    // MARK: 合作交流（官网 /school/cooperate + 校企合作栏目文章接口全量）

    /// 拉取合作交流三大分组：
    /// ① 国际交流（8 条）/继续教育（2 条）：content 全文内联于 /school/cooperate；
    /// ② 校企合作（19 条）：内嵌列表仅 8 条摘要，全量走 /common/column/articles 分页（size=8）；
    /// ③ 异步预热全部校企合作详情（正文 + 图集），供详情秒开与全文搜索。
    /// 失败仅记 warning，保留上次成功数据，不影响概况主数据。
    private func fetchCooperations() async {
        let startedAt = Date()
        LogManager.shared.info("collaboration", "合作交流拉取开始", context: [:])

        do {
            // ① 分组骨架 + 国际交流/继续教育内联全文
            let root = try await NetworkService.shared.fetchJSONDict(path: "/school/cooperate")
            guard let data = root["data"] as? [String: Any],
                  let groups = data["data"] as? [[String: Any]] else {
                throw NetworkError.decodeFailed("合作交流响应结构异常")
            }
            var inlineEntries: [CooperateEntry] = []
            var groupsSeen = 0
            for group in groups {
                let groupTitle = group["title_cn"] as? String ?? "合作交流"
                let groupKey = group["title_en"] as? String ?? ""
                guard let inner = group["data"] as? [String: Any],
                      let list = inner["list"] as? [[String: Any]] else { continue }
                groupsSeen += 1
                // 校企合作组：跳过内嵌摘要列表（仅 8/19），完整清单走②阶段栏目文章接口
                if groupKey == "cooperation" { continue }
                for item in list {
                    let rawId = item["id"] as? String ?? (item["id"] as? NSNumber)?.stringValue
                    guard let rawId, let title = item["title"] as? String, !title.isEmpty else { continue }
                    let content = item["content"] as? String ?? ""
                    inlineEntries.append(CooperateEntry(
                        id: "\(groupTitle)|\(rawId)",
                        articleId: rawId,
                        groupTitle: groupTitle,
                        groupKey: groupKey,
                        title: title,
                        detail: content.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines),
                        summary: "",
                        imageURL: item["image_url"] as? String,
                        updateTime: item["update_time"] as? String ?? "",
                        needsDetailFetch: false
                    ))
                }
            }

            // ② 校企合作全量（栏目文章接口分页，服务端 total=19；上限 6 页兜底）
            var cooperationEntries: [CooperateEntry] = []
            var page = 1
            var cooperationTotal = 0
            while page <= 6 {
                let dto = try await NetworkService.shared.fetchArticles(
                    columnId: Self.cooperationColumnId, siteId: Self.cooperationSiteId, page: page, size: 8)
                let list = dto.articles?.list ?? []
                cooperationTotal = dto.articles?.total ?? cooperationTotal
                for item in list {
                    guard let rawId = item.id, let title = item.resolvedTitle, !title.isEmpty else { continue }
                    cooperationEntries.append(CooperateEntry(
                        id: "校企合作|\(rawId)",
                        articleId: rawId,
                        groupTitle: "校企合作",
                        groupKey: "cooperation",
                        title: title,
                        detail: "",
                        summary: item.description ?? "",
                        imageURL: item.imageUrl,
                        updateTime: item.updateTime ?? "",
                        needsDetailFetch: true
                    ))
                }
                LogManager.shared.debugLog("collaboration", "校企合作文章分页拉取", context: [
                    "page": "\(page)", "count": "\(list.count)", "acc": "\(cooperationEntries.count)"
                ])
                if list.isEmpty { break }
                if cooperationTotal > 0 && cooperationEntries.count >= cooperationTotal { break }
                page += 1
            }

            let merged = inlineEntries + cooperationEntries
            if !merged.isEmpty {
                cooperateEntries = merged
            }
            LogManager.shared.info("collaboration", "合作交流拉取成功", context: [
                "groups": "\(groupsSeen)",
                "entries": "\(merged.count)",
                "cooperation": "\(cooperationEntries.count)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.warning("collaboration", "合作交流拉取失败（保留上次数据，不影响概况主数据）", context: [
                "error": message,
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
            return
        }

        // ③ 异步预热校企合作详情（并发 ≤4，失败静默；供详情秒开与全文搜索）
        let pending = cooperateEntries.filter { $0.needsDetailFetch && cooperateDetails[$0.articleId] == nil }
        if !pending.isEmpty {
            Task { await preheatCooperationDetails(pending: pending) }
        } else {
            cooperatePreheat = .done(loaded: cooperateDetails.count, failed: 0)
        }
    }

    /// 预热校企合作详情（正文 + 图集；并发 ≤4 分批，避免一次性 19 请求压学校服务器）
    func preheatCooperationDetails(pending: [CooperateEntry]?) async {
        let targets = pending ?? cooperateEntries.filter { $0.needsDetailFetch && cooperateDetails[$0.articleId] == nil }
        guard cooperatePreheat != .preheating else {
            LogManager.shared.debugLog("collaboration", "校企合作详情预热跳过", context: ["reason": "预热进行中"])
            return
        }
        let generation = cacheGeneration
        guard !targets.isEmpty else {
            cooperatePreheat = .done(loaded: cooperateDetails.count, failed: 0)
            return
        }
        cooperatePreheat = .preheating
        let startedAt = Date()
        LogManager.shared.info("collaboration", "校企合作详情预热开始", context: ["pending": "\(targets.count)"])
        var loaded = 0
        var failed = 0
        for chunkStart in stride(from: 0, to: targets.count, by: 4) {
            let chunk = Array(targets[chunkStart..<min(chunkStart + 4, targets.count)])
            await withTaskGroup(of: (Int, NetworkService.SceneryAlbumDetail?).self) { group in
                for entry in chunk {
                    let aid = entry.articleId
                    let title = entry.title
                    group.addTask {
                        do {
                            let detail = try await NetworkService.shared.fetchSceneryAlbumDetail(
                                articleId: aid, siteId: "1")
                            return (0, detail)
                        } catch {
                            await LogManager.shared.debugLog("collaboration", "校企合作详情预热单项失败", context: [
                                "articleId": aid, "title": String(title.prefix(20)),
                                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            ])
                            return (1, nil)
                        }
                    }
                }
                for await (flag, detail) in group {
                    guard generation == cacheGeneration else { continue }
                    if flag == 0, let detail {
                        cooperateDetails[detail.articleId] = detail
                        loaded += 1
                    } else {
                        failed += 1
                    }
                }
            }
        }
        // 代际校验：期间发生过手动刷新（缓存已清空），丢弃本轮结果，交由新预热接管
        guard generation == cacheGeneration else {
            LogManager.shared.debugLog("collaboration", "校企合作详情预热结果作废（期间已手动刷新）", context: [:])
            return
        }
        cooperatePreheat = .done(loaded: loaded, failed: failed)
        LogManager.shared.info("collaboration", "校企合作详情预热完成", context: [
            "loaded": "\(loaded)", "failed": "\(failed)",
            "cacheTotal": "\(cooperateDetails.count)",
            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ])
    }

    /// 获取校企合作文章详情：内存缓存优先；未命中拉详情接口并缓存（详情页/搜索全文共享）
    func loadCooperateDetail(articleId: String, title: String) async -> NetworkService.SceneryAlbumDetail? {
        if let cached = cooperateDetails[articleId] {
            LogManager.shared.debugLog("collaboration", "校企合作详情缓存命中", context: [
                "articleId": articleId, "images": "\(cached.images.count)"
            ])
            return cached
        }
        let startedAt = Date()
        LogManager.shared.info("collaboration", "校企合作详情拉取开始", context: [
            "articleId": articleId, "title": String(title.prefix(20))
        ])
        do {
            let detail = try await NetworkService.shared.fetchSceneryAlbumDetail(
                articleId: articleId, siteId: Self.cooperationSiteId)
            cooperateDetails[articleId] = detail
            LogManager.shared.info("collaboration", "校企合作详情拉取成功", context: [
                "articleId": articleId,
                "images": "\(detail.images.count)",
                "textLen": "\(detail.plainText.count)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
            return detail
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.warning("collaboration", "校企合作详情拉取失败", context: [
                "articleId": articleId, "error": message
            ])
            return nil
        }
    }

    /// 解析文字区块（compete/features 子块）：title + article.text + 图片键
    private static func parseSection(_ block: [String: Any], key: String, kind: String, icon: String) -> ProfileSearchEntry? {
        var title = block["title"] as? String ?? ""
        var text = ""
        if let article = block["article"] as? [String: Any] {
            if let articleTitle = article["title"] as? String, !articleTitle.isEmpty {
                title = articleTitle
            }
            text = article["text"] as? String ?? ""
        } else {
            text = block["text"] as? String ?? ""
        }
        guard !title.isEmpty || !text.isEmpty else { return nil }
        let imgKey = block["imgSrc"] as? String
        let imageURL = imgKey.flatMap { introAssetURL(for: $0) }
        return ProfileSearchEntry(
            id: "section|\(key)|\(title)",
            kind: kind,
            kindIcon: icon,
            title: title,
            detail: text,
            imageURL: imageURL
        )
    }

    /// 简介区图片键 → 官网静态素材 URL（素材集中维护，见 SchoolProfileAssets）
    private static func introAssetURL(for key: String) -> String? {
        switch key {
        case "introduction_title": return SchoolProfileAssets.introTitle
        case "introduction_banner": return SchoolProfileAssets.introBanner
        case "introduction_feature_1": return SchoolProfileAssets.feature1
        case "introduction_feature_2": return SchoolProfileAssets.feature2
        default: return nil
        }
    }
}

// MARK: - 学校概况页

struct SchoolProfileView: View {
    @ObservedObject private var store = SchoolProfileStore.shared

    private enum Tab: String, CaseIterable, Identifiable {
        case introduction = "学校简介"
        case leaders = "现任领导"
        case identification = "识别系统"
        case promo = "学校宣传片"
        case song = "校歌"
        case scenery = "校园风光"
        case cooperate = "合作交流"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .introduction: return "building.columns.fill"
            case .leaders: return "person.2.fill"
            case .identification: return "seal.fill"
            case .promo: return "play.rectangle.fill"
            case .song: return "music.note"
            case .scenery: return "photo.on.rectangle.angled"
            case .cooperate: return "globe.asia.australia.fill"
            }
        }
    }

    @State private var selectedTab: Tab = .introduction
    @State private var selectedLeader: ProfileSearchEntry?
    /// 图集画廊目标（风光图集多图浏览）
    @State private var selectedSceneryAlbum: OrgArticle?
    /// 合作交流文章详情
    @State private var selectedCooperate: CooperateEntry?
    /// 全局图片全屏查看（识别系统等非 sheet 场景共用）
    @State private var fullScreenImage: ProfileFullScreenImage?
    @State private var saveToast: String?
    @State private var saveToastTask: Task<Void, Never>?
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var refreshSuccessPulse = false

    // 搜索
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchHistory: [String] =
        UserDefaults.standard.stringArray(forKey: "profileSearchHistory") ?? []
    @State private var searchLogTask: Task<Void, Never>?
    @State private var searchWasEmpty = true
    @State private var lastBottomLogTime = Date.distantPast

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var searchResults: [ProfileSearchEntry] {
        store.localSearch(keyword: trimmedSearch)
    }

    // MARK: 视图

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                tabBar
                searchSection
                if isSearching {
                    searchStatusBar
                    searchContent
                } else {
                    tabContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .coordinateSpace(name: "profileScroll")
            .modifier(SJZScrollActivityTracker(coordinateSpace: "profileScroll") { direction in
                LogManager.shared.debugLog("profile", "列表滑动方向变化", context: [
                    "direction": direction,
                    "tab": selectedTab.rawValue,
                    "searching": "\(isSearching)"
                ])
            })
        }
        .scrollDismissesKeyboard(.interactively)
        .modifier(SJZIdleTimerRepairOnScrollStop())
        .background(GradientBackground())
        .navigationTitle("学校概况")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { profileToolbar }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                refreshBanner
                if store.isLoading {
                    syncProgressCapsule
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(9)
                }
            }
            .padding(.top, 8)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.refreshStatus)
        .refreshable {
            await store.refreshDetached(source: "下拉刷新")
        }
        .sheet(item: $selectedLeader) { leader in
            NavigationStack {
                ProfileTextDetailView(entry: leader)
            }
            .sjzPresentationChrome()
        }
        .sheet(item: $selectedSceneryAlbum) { article in
            NavigationStack {
                ProfileAlbumView(article: article)
            }
            .sjzPresentationChrome()
        }
        .sheet(item: $selectedCooperate) { item in
            NavigationStack {
                ProfileCooperateDetailView(entry: item)
            }
            .sjzPresentationChrome()
        }
        .fullScreenCover(item: $fullScreenImage) { item in
            FullScreenImageView(url: item.url, title: item.title)
                .sjzPresentationChrome()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .overlay(alignment: .top) {
            if let toast = saveToast {
                Text(toast)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveToast)
        .task {
            store.loadIfNeeded()
        }
        .onAppear {
            LogManager.shared.info("profile", "学校概况页面打开", context: [
                "hasLoaded": "\(store.hasLoaded)",
                "entries": "\(store.allEntries.count)"
            ])
        }
        .onDisappear {
            LogManager.shared.info("profile", "学校概况页面离开", context: [
                "tab": selectedTab.rawValue,
                "searching": "\(isSearching)"
            ])
        }
        .onChange(of: searchText) { _, newValue in
            let trimmedNow = newValue.trimmingCharacters(in: .whitespaces)
            if searchWasEmpty && !trimmedNow.isEmpty {
                LogManager.shared.debugLog("profile", "搜索输入开始", context: ["keyword": String(trimmedNow.prefix(12))])
            }
            searchWasEmpty = trimmedNow.isEmpty
            handleSearchChange(newValue)
        }
        .onChange(of: isSearchFocused) { _, focused in
            LogManager.shared.debugLog("profile", focused ? "搜索框聚焦" : "搜索框失焦", context: [:])
        }
        .onChange(of: store.refreshStatus) { _, status in
            handleRefreshStatusChange(status)
        }
        .onChange(of: selectedTab) { _, newTab in
            LogManager.shared.info("profile", "板块切换", context: ["tab": newTab.rawValue])
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var profileToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                // 更多操作菜单：打开官网概况页（原返回键长按菜单功能迁移至此）
                Menu {
                    Button {
                        let urlString = "\(SchoolInfo.website)/#/aboutUs"
                        guard let url = URL(string: urlString) else { return }
                        LogManager.shared.info("profile", "菜单·打开官网学校概况页", context: ["url": urlString])
                        UIApplication.shared.open(url)
                    } label: {
                        Label("打开官网概况页", systemImage: "safari.fill")
                            .displayLabelFont(17)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(Color.sjzPrimary)
                }
                .accessibilityLabel("更多操作")
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.debugLog("profile", "工具栏刷新按钮点击")
                    Task { await store.refresh(source: "工具栏刷新") }
                } label: {
                    Group {
                        if store.refreshStatus == .refreshing {
                            ProgressView()
                                .tint(Color.sjzPrimary)
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
                                .foregroundStyle(Color.sjzPrimary)
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

    private func handleRefreshStatusChange(_ status: SchoolProfileStore.RefreshStatus) {
        switch status {
        case .success:
            refreshSuccessPulse = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                refreshSuccessPulse = false
                store.dismissRefreshBanner()
                LogManager.shared.debugLog("profile", "成功横幅自动隐藏", context: [:])
            }
        case .failed(let message):
            LogManager.shared.debugLog("profile", "刷新失败横幅展示", context: ["error": message])
        case .refreshing, .idle:
            break
        }
    }

    // MARK: ① 主题头卡（蓝金学术风）

    private var heroCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0B1F4B"), Color.sjzPrimary, Color.sjzAccent.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 12)
                .frame(width: 118, height: 118)
                .offset(x: 148, y: -54)

            HStack(spacing: 15) {
                SJZCachedImage(url: URL(string: store.markLogoURL)!) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.15))
                            .frame(width: 54, height: 54)
                            .overlay {
                                Image(systemName: "building.columns.fill")
                                    .displaySymbolFont(22, weight: .semibold)
                                    .foregroundStyle(.white)
                            }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("SCHOOL PROFILE")
                        .displayFont(10, weight: .bold)
                        .tracking(2)
                        .foregroundStyle(Color.sjzGold)
                    Text("学校概况")
                        .displayFont(22, weight: .heavy)
                        .foregroundStyle(.white)
                    Text("山西晋中理工学院 · 七大板块全景")
                        .displayFont(11)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer(minLength: 0)

                if store.hasLoaded {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(store.leaders.count)")
                            .displayFont(22, weight: .heavy)
                            .monospacedDigit()
                            .foregroundStyle(Color.sjzGold)
                        Text("位校领导")
                            .displayFont(9, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.sjzPrimary.opacity(0.35), radius: 20, y: 10)
    }

    // MARK: ② 板块切换

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases) { tab in
                    let selected = selectedTab == tab
                    Button {
                        LogManager.shared.debugLog("profile", "板块 tab 点击", context: [
                            "tab": tab.rawValue, "alreadySelected": "\(selected)"
                        ])
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .displaySymbolFont(11, weight: .semibold)
                            Text(tab.rawValue)
                                .displayFont(12, weight: selected ? .bold : .medium)
                        }
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(
                            Capsule().fill(selected ? Color.sjzPrimary : Color.primary.opacity(0.05))
                        )
                        .overlay {
                            if selected {
                                Capsule().strokeBorder(Color.sjzGold.opacity(0.6), lineWidth: 1)
                            } else {
                                Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: ③ 搜索区

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .displaySymbolFont(14, weight: .medium)
                    .foregroundStyle(Color.sjzPrimary)

                TextField("搜索学校概况（领导/简介/风光…）", text: $searchText)
                    .displayFont(15)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit { commitSearch() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                        LogManager.shared.debugLog("profile", "搜索词已清除", context: [:])
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
                    Capsule().strokeBorder(Color.sjzPrimary.opacity(0.55), lineWidth: 1)
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
                            LogManager.shared.info("profile", "搜索历史点击", context: ["keyword": keyword])
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
                UserDefaults.standard.set([String](), forKey: "profileSearchHistory")
                LogManager.shared.info("profile", "搜索历史已清空")
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
    private var tabContent: some View {
        if store.isLoading && !store.hasLoaded {
            skeletonList
        } else if let error = store.lastError, !store.hasLoaded {
            errorCard(error)
        } else {
            switch selectedTab {
            case .introduction: introductionTab
            case .leaders: leadersTab
            case .identification: identificationTab
            case .promo: videoTab(url: store.promoVideoURL, poster: SchoolProfileAssets.videoPoster, title: "学校宣传片", logLabel: "宣传片")
            case .song: videoTab(url: store.songVideoURL, poster: SchoolProfileAssets.songPoster, title: "校歌", logLabel: "校歌")
            case .scenery: sceneryTab
            case .cooperate: cooperateTab
            }
        }
    }

    // MARK: 学校简介（数字滚动 + 文字区块）

    private var introductionTab: some View {
        VStack(spacing: 14) {
            // 统计数据卡（数字滚动）
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(store.statItems.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        RollingNumberView(target: item.number)
                        Text(item.text)
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.sjzGold.opacity(0.25), lineWidth: 1))
                }
            }

            // 学科竞赛横幅 + 特色区块
            ForEach(store.textSections) { section in
                sectionCard(section)
            }
        }
    }

    private func sectionCard(_ section: ProfileSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: section.kindIcon)
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text(section.title)
                    .displayFont(16, weight: .bold)
                    .foregroundStyle(.primary)
                Spacer()
                Text(section.kind)
                    .displayFont(9, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.sjzPrimary.opacity(0.08)))
            }

            if let urlString = section.imageURL, let url = URL(string: urlString) {
                SJZCachedImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
            }

            if !section.detail.isEmpty {
                Text(section.detail)
                    .displayFont(13)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    // MARK: 现任领导

    private var leadersTab: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(store.leaders) { leader in
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.info("profile", "领导详情打开", context: ["title": leader.title])
                    selectedLeader = leader
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.sjzPrimary.opacity(0.08))
                            if let urlString = leader.imageURL, let url = URL(string: urlString) {
                                SJZCachedImage(url: url) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "person.fill")
                                            .displaySymbolFont(30, weight: .medium)
                                            .foregroundStyle(Color.sjzPrimary.opacity(0.4))
                                    }
                                }
                            } else {
                                Image(systemName: "person.fill")
                                    .displaySymbolFont(30, weight: .medium)
                                    .foregroundStyle(Color.sjzPrimary.opacity(0.4))
                            }
                        }
                        .frame(width: 74, height: 74)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.sjzGold.opacity(0.5), lineWidth: 1.5))

                        Text(leader.title.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? leader.title)
                            .displayFont(14, weight: .bold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let position = leader.title.split(separator: "·").dropFirst().first {
                            Text(String(position).trimmingCharacters(in: .whitespaces))
                                .displayFont(10)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 识别系统

    private var identificationTab: some View {
        VStack(spacing: 14) {
            // 校徽大图（点击全屏 · 长按保存/分享）
            SJZCachedImage(url: URL(string: store.markLogoURL)!) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 180)
                }
            }
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let url = URL(string: store.markLogoURL) {
                    fullScreenImage = ProfileFullScreenImage(url: url, title: "校徽")
                }
                LogManager.shared.debugLog("profile", "校徽全屏打开", context: [:])
            }
            .contextMenu {
                Button {
                    Task { await saveImageAndToast(urlString: store.markLogoURL, title: "校徽") }
                } label: {
                    Label("保存图片", systemImage: "square.and.arrow.down")
                        .displayLabelFont(17)
                }
                Button {
                    shareImage(urlString: store.markLogoURL, title: "校徽")
                } label: {
                    Label("分享…", systemImage: "square.and.arrow.up")
                        .displayLabelFont(17)
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.sjzGold.opacity(0.3), lineWidth: 1))

            // 校名规范图组（横排/竖排）
            identificationImageGrid(title: "校名使用规范 · 横排", urls: SchoolProfileAssets.nameRow)
            identificationImageGrid(title: "校名使用规范 · 竖排", urls: SchoolProfileAssets.nameColumn)

            // 标志释义（官网识别系统文案）
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "seal.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(Color.sjzGold)
                    Text("山西晋中理工学院标志释义")
                        .displayFont(15, weight: .bold)
                    Spacer()
                }
                Text("形状寓意解析：校徽中间设计了一个大齿轮，代表学校以工学为主的办学定位，同时代表协作精神；齿轮两侧的两个小篆字……")
                    .displayFont(13)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(6)
                Text("校徽以深蓝色为主调，蓝色代表理智，是一种非常有包容性的颜色，它能传递出专业、可信和沉稳的形象。在出现重大庆典类节日的时候，学校校徽更改为红色，象征赓续红色血脉、传承革命精神，彰显学校为党育人、为国育才的使命担当。")
                    .displayFont(13)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(6)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        }
    }

    private func identificationImageGrid(title: String, urls: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .displayFont(13, weight: .semibold)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, urlString in
                    if let url = URL(string: urlString) {
                        SJZCachedImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                                    .frame(height: 90)
                                    .frame(maxWidth: .infinity)
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                                    .frame(height: 90)
                            }
                        }
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            fullScreenImage = ProfileFullScreenImage(url: url, title: "校名规范图")
                            LogManager.shared.debugLog("profile", "校名规范图全屏打开", context: ["group": title])
                        }
                        .contextMenu {
                            Button {
                                Task { await saveImageAndToast(urlString: urlString, title: "校名规范图") }
                            } label: {
                                Label("保存图片", systemImage: "square.and.arrow.down")
                                    .displayLabelFont(17)
                            }
                            Button {
                                shareImage(urlString: urlString, title: "校名规范图")
                            } label: {
                                Label("分享…", systemImage: "square.and.arrow.up")
                                    .displayLabelFont(17)
                            }
                        }
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: 视频（宣传片/校歌）

    private func videoTab(url: String?, poster: String, title: String, logLabel: String) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .displaySymbolFont(13, weight: .semibold)
                        .foregroundStyle(Color.sjzGold)
                    Text(title)
                        .displayFont(16, weight: .bold)
                    Spacer()
                }
                if let urlString = url, let videoURL = URL(string: urlString) {
                    ProfileInlineVideo(url: videoURL)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
                        .onAppear {
                            LogManager.shared.info("profile", "\(logLabel)视频页面展示", context: ["url": urlString])
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.slash")
                            .displaySymbolFont(26, weight: .medium)
                            .foregroundStyle(Color.sjzPrimary.opacity(0.5))
                        Text("视频暂不可用")
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let posterURL = URL(string: poster) {
                    SJZCachedImage(url: posterURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            Color.clear.frame(height: 0)
                        }
                    }
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        }
    }

    // MARK: 校园风光

    private var sceneryTab: some View {
        VStack(spacing: 12) {
            if store.sceneryArticles.isEmpty && !store.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .displaySymbolFont(30, weight: .light)
                        .foregroundStyle(Color.sjzPrimary.opacity(0.5))
                    Text("暂无风光图片")
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(store.sceneryArticles) { article in
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            selectedSceneryAlbum = article
                            LogManager.shared.info("profile", "风光图集打开", context: [
                                "title": article.title, "articleId": article.articleId,
                                "albumsPreheat": "\(store.albumsPreheat)"
                            ])
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                    if let urlString = article.imageUrl, let url = URL(string: urlString) {
                                        SJZCachedImage(url: url) { phase in
                                            if case .success(let image) = phase {
                                                image.resizable().scaledToFill()
                                            } else {
                                                Image(systemName: "photo")
                                                    .displaySymbolFont(18)
                                                    .foregroundStyle(Color.sjzPrimary.opacity(0.35))
                                            }
                                        }
                                    } else {
                                        Image(systemName: "photo")
                                            .displaySymbolFont(18)
                                            .foregroundStyle(Color.sjzPrimary.opacity(0.35))
                                    }
                                }
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                HStack(spacing: 6) {
                                    Text(article.title)
                                        .displayFont(12, weight: .semibold)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    // 图集张数角标（预热后实时显数；未预热时轻提示「图集」）
                                    if let album = store.sceneryAlbums[article.articleId] {
                                        Text("\(album.images.count) 张")
                                            .displayFont(9, weight: .semibold)
                                            .foregroundStyle(Color.sjzGold)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(Color.sjzGold.opacity(0.14)))
                                            .overlay(Capsule().strokeBorder(Color.sjzGold.opacity(0.35), lineWidth: 0.5))
                                    } else {
                                        Image(systemName: "photo.stack.fill")
                                            .displaySymbolFont(9, weight: .semibold)
                                            .foregroundStyle(Color.sjzPrimary.opacity(0.7))
                                    }
                                }
                            }
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 合作交流（第七板块：三大分组全景 + 图文详情）

    /// 分组固定展示顺序（与官网 /collaboration 一致）
    private static let cooperateGroupOrder = ["国际交流", "继续教育", "校企合作"]

    private var cooperateGrouped: [String: [CooperateEntry]] {
        Dictionary(grouping: store.cooperateEntries, by: \.groupTitle)
    }

    /// 校企合作详情预热完成数（组头状态徽章用）
    private var cooperatePreheatDoneCount: Int? {
        guard case .done(let loaded, _) = store.cooperatePreheat else { return nil }
        return loaded
    }

    private var cooperateTab: some View {
        VStack(spacing: 14) {
            if store.cooperateEntries.isEmpty && !store.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "globe.asia.australia")
                        .displaySymbolFont(30, weight: .light)
                        .foregroundStyle(Color.sjzPrimary.opacity(0.5))
                    Text("暂无合作交流信息")
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text("国际交流 · 继续教育 · 校企合作")
                        .displayFont(11)
                        .foregroundStyle(.tertiary)
                    Text("下拉刷新可重新拉取最新数据")
                        .displayFont(11)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(Self.cooperateGroupOrder, id: \.self) { groupTitle in
                    if let items = cooperateGrouped[groupTitle], !items.isEmpty {
                        cooperateGroupCard(groupTitle, items)
                            .onAppear {
                                LogManager.shared.debugLog("collaboration", "合作交流分组卡展示", context: [
                                    "group": groupTitle, "count": "\(items.count)"
                                ])
                            }
                    }
                }
            }
        }
    }

    /// 分组大卡：渐变圆形图标 + 中英标题 + 计数徽章 + 详情预热状态 + 条目网格
    private func cooperateGroupCard(_ groupTitle: String, _ items: [CooperateEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    LinearGradient(
                        colors: cooperateGroupColors(groupTitle),
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: cooperateGroupIcon(groupTitle))
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: cooperateGroupColors(groupTitle).first?.opacity(0.45) ?? .clear, radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(groupTitle)
                        .displayFont(16, weight: .bold)
                        .foregroundStyle(.primary)
                    Text(cooperateGroupEnglish(groupTitle))
                        .displayFont(9, weight: .semibold)
                        .tracking(1.2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                if groupTitle == "校企合作", cooperatePreheatDoneCount != nil {
                    HStack(spacing: 5) {
                        if store.cooperatePreheat == .preheating {
                            ProgressView().scaleEffect(0.55).tint(Color.sjzGold)
                        } else {
                            Image(systemName: "doc.text.magnifyingglass")
                                .displaySymbolFont(9, weight: .semibold)
                        }
                        Text(store.cooperatePreheat == .preheating ? "详情预热中" : "全文可搜")
                            .displayFont(9, weight: .semibold)
                    }
                    .foregroundStyle(Color.sjzGold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.sjzGold.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.sjzGold.opacity(0.3), lineWidth: 0.5))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Text("\(items.count) 项")
                    .displayFont(9, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.sjzPrimary.opacity(0.08)))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(items) { item in
                    cooperateItemCard(item)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.sjzGold.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 7)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.cooperatePreheat == .preheating)
    }

    /// 条目卡片：封面（完整不裁切 · 点击全屏 · 长按保存分享）+ 标题 + 摘要/日期角标
    /// 图片统一 4:3 容器 + scaledToFit 完整呈现（长图/宽图均不裁切），
    /// 平均色淡彩衬底 + 呼吸边距，标题/摘要定高——网格行内卡片完全齐平。
    private func cooperateItemCard(_ item: CooperateEntry) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            selectedCooperate = item
            LogManager.shared.info("collaboration", "合作交流文章打开", context: [
                "group": item.groupTitle,
                "title": String(item.title.prefix(20)),
                "needsDetail": "\(item.needsDetailFetch)"
            ])
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                // 缩略图：容器比例固定 → 任意宽高比图片均完整显示、互不遮挡
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(cooperateThumbBackground(item))
                    if let urlString = item.imageURL,
                       !urlString.isEmpty,
                       !urlString.contains("no_picture"),
                       let url = URL(string: urlString) {
                        SJZCachedImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                                    .padding(7)
                                    .transition(.opacity)
                            case .empty:
                                // 平均色 blur-up 占位；无记录时微光骨架
                                if let hex = SJZAverageColorCache.colorHex(for: url) {
                                    Color(hex: hex).opacity(0.22)
                                } else {
                                    ShimmerView()
                                }
                            default:
                                cooperateThumbPlaceholder
                            }
                        }
                    } else {
                        cooperateThumbPlaceholder
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    if !item.dateText.isEmpty {
                        Text(item.dateText)
                            .displayFont(8, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    guard let urlString = item.imageURL,
                          !urlString.isEmpty,
                          !urlString.contains("no_picture"),
                          let url = URL(string: urlString) else { return }
                    fullScreenImage = ProfileFullScreenImage(url: url, title: item.title)
                    LogManager.shared.debugLog("collaboration", "合作交流封面全屏打开", context: [
                        "title": String(item.title.prefix(20))
                    ])
                }
                .contextMenu {
                    if let urlString = item.imageURL,
                       !urlString.isEmpty,
                       !urlString.contains("no_picture") {
                        Button {
                            Task { await saveCooperationImage(urlString: urlString, title: item.title) }
                        } label: {
                            Label("保存图片", systemImage: "square.and.arrow.down")
                                .displayLabelFont(17)
                        }
                        Button {
                            shareCooperationImage(urlString: urlString, title: item.title)
                        } label: {
                            Label("分享…", systemImage: "square.and.arrow.up")
                                .displayLabelFont(17)
                        }
                    }
                }

                Text(item.title)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

                let snippet = item.needsDetailFetch ? item.summary : item.detail
                if !snippet.isEmpty {
                    Text(snippet)
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 缩略图衬底：图片平均色淡彩（blur-up 质感）；无记录时中性浅底
    private func cooperateThumbBackground(_ item: CooperateEntry) -> Color {
        if let urlString = item.imageURL, !urlString.isEmpty,
           let hex = SJZAverageColorCache.colorHex(for: URL(string: urlString)) {
            return Color(hex: hex).opacity(0.18)
        }
        return Color.primary.opacity(0.05)
    }

    private var cooperateThumbPlaceholder: some View {
        ZStack {
            Color.primary.opacity(0.05)
            Image(systemName: "building.2.fill")
                .displaySymbolFont(16)
                .foregroundStyle(Color.sjzPrimary.opacity(0.35))
        }
    }

    private func cooperateGroupIcon(_ group: String) -> String {
        switch group {
        case "国际交流": return "globe.asia.australia.fill"
        case "继续教育": return "graduationcap.fill"
        default: return "building.2.fill"
        }
    }

    private func cooperateGroupColors(_ group: String) -> [Color] {
        switch group {
        case "国际交流": return [Color(hex: "2563EB"), Color(hex: "38BDF8")]
        case "继续教育": return [Color(hex: "0D9488"), Color(hex: "34D399")]
        default: return [Color.sjzPrimary, Color.sjzAccent]
        }
    }

    private func cooperateGroupEnglish(_ group: String) -> String {
        switch group {
        case "国际交流": return "INTERNATIONAL EXCHANGE"
        case "继续教育": return "CONTINUING EDUCATION"
        default: return "SCHOOL-ENTERPRISE COOPERATION"
        }
    }

    // MARK: 保存 / 分享辅助（概况页内 识别系统等图片长按菜单共用）

    @MainActor
    private func saveImageAndToast(urlString: String, title: String) async {
        LogManager.shared.info("profile", "图片保存发起", context: ["title": title])
        if let message = await ProfileImageSaveShare.saveToPhotos(urlString: urlString, logTag: "profile") {
            presentSaveToast("[保存失败] \(message)")
        } else {
            presentSaveToast("已保存到相册")
        }
    }

    private func shareImage(urlString: String, title: String) {
        LogManager.shared.info("profile", "图片分享面板展示", context: ["title": title])
        Task { @MainActor in
            shareItems = await ProfileImageSaveShare.prepareShareItems(urlString: urlString)
            guard !shareItems.isEmpty else { return }
            showShareSheet = true
        }
    }

    /// 合作交流图片长按保存（collaboration 日志域）
    @MainActor
    private func saveCooperationImage(urlString: String, title: String) async {
        LogManager.shared.info("collaboration", "图片保存发起", context: ["title": String(title.prefix(20))])
        if let message = await ProfileImageSaveShare.saveToPhotos(urlString: urlString, logTag: "collaboration") {
            presentSaveToast("[保存失败] \(message)")
        } else {
            presentSaveToast("已保存到相册")
        }
    }

    /// 合作交流图片长按分享（collaboration 日志域）
    private func shareCooperationImage(urlString: String, title: String) {
        LogManager.shared.info("collaboration", "图片分享面板展示", context: ["title": String(title.prefix(20))])
        Task { @MainActor in
            shareItems = await ProfileImageSaveShare.prepareShareItems(urlString: urlString)
            guard !shareItems.isEmpty else { return }
            showShareSheet = true
        }
    }

    private func presentSaveToast(_ text: String) {
        saveToastTask?.cancel()
        withAnimation { saveToast = text }
        saveToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { saveToast = nil }
        }
    }

    // MARK: 搜索模式

    private var searchStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(11)
                .foregroundStyle(Color.sjzPrimary)
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
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var searchContent: some View {
        if searchResults.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .displaySymbolFont(34, weight: .light)
                    .foregroundStyle(Color.sjzPrimary.opacity(0.7))
                Text("未找到匹配「\(trimmedSearch)」的内容")
                    .displayFont(14, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text("试试「领导姓名」「专业」「竞赛」等关键词")
                    .displayFont(12)
                    .foregroundStyle(.tertiary)
                Button {
                    searchText = ""
                } label: {
                    Text("清除搜索")
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(Color.sjzPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color.sjzPrimary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onAppear {
                LogManager.shared.debugLog("profile", "搜索空态展示", context: ["keyword": trimmedSearch])
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(searchResults) { entry in
                    searchResultCard(entry)
                }
                bottomSentinel
            }
        }
    }

    private func searchResultCard(_ entry: ProfileSearchEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.sjzPrimary.opacity(0.85), Color.sjzAccent.opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: entry.kindIcon)
                        .displaySymbolFont(14, weight: .semibold)
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 5) {
                highlightedText(entry.title, keyword: trimmedSearch, baseColor: .primary)
                    .displayFont(14, weight: .semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !entry.detail.isEmpty {
                    highlightedText(entry.detail, keyword: trimmedSearch, baseColor: .secondary)
                        .displayFont(12)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(entry.kind)
                    .displayFont(9, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.sjzPrimary.opacity(0.08)))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .displaySymbolFont(10, weight: .medium)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            LogManager.shared.info("profile", "搜索结果详情打开", context: [
                "kind": entry.kind, "title": String(entry.title.prefix(24))
            ])
            if entry.kind == "现任领导" {
                selectedLeader = entry
            } else if entry.kind == "校园风光" {
                // 搜索结果命中风光：按 articleId 定位图集条目，打开完整多图画廊
                let articleId = entry.id.replacingOccurrences(of: "scenery|", with: "")
                if let article = store.sceneryArticles.first(where: { $0.articleId == articleId }) {
                    selectedSceneryAlbum = article
                    LogManager.shared.debugLog("profile", "搜索结果打开风光图集画廊", context: ["articleId": articleId])
                } else if let cover = entry.imageURL {
                    selectedSceneryAlbum = OrgArticle(
                        id: entry.id, title: entry.title,
                        description: entry.detail, imageUrl: cover,
                        updateTime: "", tag: "", articleId: articleId, sectionSiteId: "1")
                    LogManager.shared.debugLog("profile", "搜索结果打开风光图集画廊（封面兜底）", context: ["articleId": articleId])
                }
            } else if entry.kind == "合作交流" {
                // 搜索结果命中合作交流：按条目 id 定位并打开图文详情
                if let item = store.cooperateEntries.first(where: { "cooperate|\($0.id)" == entry.id }) {
                    selectedCooperate = item
                    LogManager.shared.debugLog("collaboration", "搜索结果打开合作交流详情", context: [
                        "group": item.groupTitle, "articleId": item.articleId
                    ])
                } else {
                    LogManager.shared.warning("collaboration", "搜索结果未能定位合作交流条目（可能已刷新）", context: [
                        "id": entry.id
                    ])
                }
            } else {
                selectedLeader = entry
            }
        }
    }

    // MARK: 骨架 / 错误 / 横幅 / 进度

    private var skeletonList: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 120)
                    .overlay {
                        ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .displaySymbolFont(34, weight: .light)
                .foregroundStyle(Color.sjzOrange.opacity(0.8))
            Text("学校概况加载失败")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .displayFont(12)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                LogManager.shared.info("profile", "失败重试点击", context: ["error": message])
                Task { await store.refresh(source: "失败重试") }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .displayLabelFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzPrimary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var syncProgressCapsule: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Color.sjzPrimary)
                .scaleEffect(0.7)
            Text("正在同步学校概况…")
                .displayFont(11, weight: .semibold)
                .foregroundStyle(.primary)
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
                    .tint(Color.sjzPrimary)
                    .scaleEffect(0.75)
                Text("正在刷新学校概况…")
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
                    Text("刷新成功 · 同步 \(total) 项内容")
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
                        .foregroundStyle(Color.sjzPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.sjzPrimary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    store.dismissRefreshBanner()
                    LogManager.shared.debugLog("profile", "失败横幅手动关闭", context: [:])
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

    /// 触底哨兵（10 秒节流）
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 2)
            .onAppear {
                let now = Date()
                guard now.timeIntervalSince(lastBottomLogTime) > 10 else { return }
                lastBottomLogTime = now
                LogManager.shared.debugLog("profile", "列表滚动至底部区域", context: [
                    "tab": selectedTab.rawValue,
                    "searching": "\(isSearching)"
                ])
            }
    }

    // MARK: 搜索高亮

    @ViewBuilder
    private func highlightedText(_ text: String, keyword: String, baseColor: Color) -> some View {
        let terms = keyword.split(whereSeparator: { $0 == " " || $0 == "　" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if terms.isEmpty {
            Text(text)
                .foregroundColor(baseColor)
        } else if #available(iOS 15.0, *) {
            Text(profileHighlighted(text, keywords: terms, baseColor: baseColor))
        } else {
            Text(text)
                .foregroundColor(baseColor)
        }
    }

    @available(iOS 15.0, *)
    private func profileHighlighted(_ text: String, keywords: [String], baseColor: Color) -> AttributedString {
        var attr = AttributedString(text)
        var ranges: [Range<AttributedString.Index>] = []
        for keyword in keywords {
            var cursor = attr.startIndex
            while cursor < attr.endIndex,
                  let range = attr[cursor...].range(of: keyword, options: .caseInsensitive) {
                ranges.append(range)
                cursor = range.upperBound
            }
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
            LogManager.shared.debugLog("profile", "搜索已清空")
            return
        }
        let keyword = trimmed
        searchLogTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let hits = store.localSearch(keyword: keyword).count
            LogManager.shared.debugLog("profile", "概况关键词搜索", context: [
                "keyword": keyword,
                "hits": "\(hits)",
                "total": "\(store.allEntries.count)"
            ])
        }
    }

    private func commitSearch() {
        let keyword = trimmedSearch
        guard !keyword.isEmpty else { return }
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 10 { searchHistory = Array(searchHistory.prefix(10)) }
        UserDefaults.standard.set(searchHistory, forKey: "profileSearchHistory")
        isSearchFocused = false
        LogManager.shared.info("profile", "搜索提交", context: [
            "keyword": keyword,
            "hits": "\(searchResults.count)",
            "historyCount": "\(searchHistory.count)"
        ])
    }
}

// MARK: - 内联视频（宣传片/校歌；轻量 AVKit 播放器，出现即播、离开即停）

struct ProfileInlineVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if player == nil {
                    let newPlayer = AVPlayer(url: url)
                    player = newPlayer
                    newPlayer.play()
                    LogManager.shared.debugLog("profile", "视频开始播放", context: ["url": url.absoluteString])
                }
            }
            .onDisappear {
                player?.pause()
                LogManager.shared.debugLog("profile", "视频暂停（离开视图）", context: [:])
            }
    }
}

// MARK: - 数字滚动组件（学校简介统计）

/// 数字滚动（官网 DynamicDigit 同款动效）：进入视口时从 0 滚动至目标值
struct RollingNumberView: View {
    let target: Int
    @State private var display = 0
    @State private var appeared = false

    var body: some View {
        Text(Self.formatted(display))
            .displayFont(30, weight: .heavy, design: .rounded)
            .monospacedDigit()
            .foregroundStyle(LinearGradient(
                colors: [Color.sjzPrimary, Color.sjzAccent],
                startPoint: .leading, endPoint: .trailing))
            .contentTransition(.numericText())
            .onAppear {
                guard !appeared else { return }
                appeared = true
                let steps = 40
                let stepValue = max(Double(target) / Double(steps), 1)
                var current = 0.0
                Timer.scheduledTimer(withTimeInterval: 0.018, repeats: true) { timer in
                    current += stepValue
                    if current >= Double(target) {
                        display = target
                        timer.invalidate()
                    } else {
                        display = Int(current)
                    }
                    if display >= target {
                        display = target
                        timer.invalidate()
                    }
                }
            }
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - 文字详情（领导/风光图文）

struct ProfileTextDetailView: View {
    let entry: ProfileSearchEntry

    @State private var showFullScreen = false
    @State private var saveToast: String?
    @State private var saveToastTask: Task<Void, Never>?
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let urlString = entry.imageURL, let url = URL(string: urlString) {
                    SJZCachedImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 300)
                                .frame(minHeight: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .transition(.opacity)
                        } else {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 160)
                        }
                    }
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        LogManager.shared.debugLog("profile", "详情图全屏打开", context: ["title": String(entry.title.prefix(20))])
                        showFullScreen = true
                    }
                    .contextMenu {
                        Button {
                            Task { await handleSave(urlString: urlString, title: entry.title) }
                        } label: {
                            Label("保存图片", systemImage: "square.and.arrow.down")
                                .displayLabelFont(17)
                        }
                        Button {
                            handleShare(urlString: urlString, title: entry.title)
                        } label: {
                            Label("分享…", systemImage: "square.and.arrow.up")
                                .displayLabelFont(17)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.kindIcon)
                            .displaySymbolFont(14, weight: .semibold)
                            .foregroundStyle(Color.sjzGold)
                        Text(entry.title)
                            .displayFont(18, weight: .heavy)
                        Spacer()
                        Text(entry.kind)
                            .displayFont(9, weight: .semibold)
                            .foregroundStyle(Color.sjzPrimary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.sjzPrimary.opacity(0.08)))
                    }
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .displayFont(14)
                            .foregroundStyle(.primary.opacity(0.9))
                            .lineSpacing(7)
                    }
                    if entry.imageURL != nil {
                        Text("长按照片可保存或分享到系统相册与第三方应用")
                            .displayFont(10)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            }
            .padding(16)
        }
        .background(GradientBackground())
        .navigationTitle(entry.kind)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toast = saveToast {
                Text(toast)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveToast)
        .fullScreenCover(isPresented: $showFullScreen) {
            Group {
                if let urlString = entry.imageURL, let url = URL(string: urlString) {
                    FullScreenImageView(url: url, title: entry.title)
                }
            }
            .sjzPresentationChrome()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .onAppear {
            LogManager.shared.info("profile", "文字详情页打开", context: [
                "kind": entry.kind, "title": String(entry.title.prefix(24))
            ])
        }
        .onDisappear {
            saveToastTask?.cancel()
        }
    }

    // MARK: 保存 / 分享（系统级：长按菜单 + 相册写入 + 系统分享面板）

    @MainActor
    private func handleSave(urlString: String, title: String) async {
        LogManager.shared.info("profile", "图片保存发起", context: ["title": String(title.prefix(20))])
        if let message = await ProfileImageSaveShare.saveToPhotos(urlString: urlString, logTag: "profile") {
            presentToast("[保存失败] \(message)")
        } else {
            presentToast("已保存到相册")
        }
    }

    private func handleShare(urlString: String, title: String) {
        LogManager.shared.info("profile", "图片分享面板展示", context: ["title": String(title.prefix(20))])
        Task { @MainActor in
            shareItems = await ProfileImageSaveShare.prepareShareItems(urlString: urlString)
            guard !shareItems.isEmpty else { return }
            showShareSheet = true
        }
    }

    private func presentToast(_ text: String) {
        saveToastTask?.cancel()
        withAnimation { saveToast = text }
        saveToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { saveToast = nil }
        }
    }
}

// MARK: - 全屏图片项（概况页全局 fullScreenCover 载体）

struct ProfileFullScreenImage: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

// MARK: - 图片保存 / 分享基础设施（系统级：相册写权限 + UIActivityViewController）

/// 概况模块统一图片保存/分享工具：
/// · 保存：下载原始图 → Photos 写权限（addOnly，只需 Info.plist NSPhotoLibraryAddUsageDescription）
///   → PHPhotoLibrary 写入；全链路成功/失败日志；
/// · 分享：下载原始图 → 系统 UIActivityViewController（复用 TabBar 的 ShareSheet），从顶层 VC 呈现。
enum ProfileImageSaveShare {

    /// 共享下载会话（显式注册协议层——防盗链 Referer、图片缓存策略与网络监测埋点不受全局注册时序影响）
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.protocolClasses = [RefererHeaderURLProtocol.self]
        return URLSession(configuration: config)
    }()

    /// URL 安全构造：非 ASCII 自动百分号编码（与 NetworkService.safeImageURL 同语义）
    static func safeURL(from urlString: String) -> URL? {
        if let url = URL(string: urlString) { return url }
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }

    /// 下载图片原始数据（失败返回 nil）
    static func downloadImageData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            await LogManager.shared.debugLog("profile", "图片下载失败", context: [
                "url": url.lastPathComponent,
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// 保存到系统相册。返回 nil = 成功；返回 String = 失败原因（中文，供 toast）。
    @MainActor
    static func saveToPhotos(urlString: String, logTag: String) async -> String? {
        guard let url = safeURL(from: urlString) else {
            LogManager.shared.warning(logTag, "图片保存失败：地址无效", context: [:])
            return "图片地址无效"
        }
        guard let data = await downloadImageData(from: url), let image = UIImage(data: data) else {
            LogManager.shared.warning(logTag, "图片保存失败：下载或解码失败", context: ["file": url.lastPathComponent])
            return "图片下载失败，请检查网络后重试"
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            LogManager.shared.warning(logTag, "图片保存失败：相册权限被拒绝", context: ["status": "\(status.rawValue)"])
            return "未获得相册权限，请在系统设置中开启"
        case .notDetermined:
            LogManager.shared.warning(logTag, "图片保存失败：相册权限未决定", context: [:])
            return "相册权限未决定，请重试"
        @unknown default:
            LogManager.shared.warning(logTag, "图片保存失败：相册权限状态未知", context: [:])
            return "相册权限状态未知，请重试"
        }
        let startedAt = Date()

        // 修复（2026-09-24，PHPhotosErrorDomain 3302 = invalidResource）：
        // WebP 等图片来源的 UIImage 直接经 creationRequestForAsset(from:) 写入，会被 PhotoKit
        // 资源预检拒绝（3302）；统一重编码为 JPEG 字节 → 临时文件 → file-based addResource 写入，
        // 该路径经 iOS 26 官方社区验证稳定（并提示：from: UIImage 通道在 iOS 26 还会重编码丢 EXIF）。
        guard let jpegData = image.jpegData(compressionQuality: 0.92) else {
            LogManager.shared.warning(logTag, "图片保存失败：JPEG 编码失败", context: ["file": url.lastPathComponent])
            return "图片编码失败，请重试"
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sxjz_save_\(UUID().uuidString).jpg")
        do {
            try jpegData.write(to: tempURL, options: .atomic)
        } catch {
            LogManager.shared.warning(logTag, "图片保存失败：临时文件写入失败", context: [
                "file": url.lastPathComponent, "error": error.localizedDescription
            ])
            return "图片写入失败，请重试"
        }
        // move 成功后源文件被系统移走，此处清理仅覆盖失败分支（文件不存在时静默跳过）
        defer { try? FileManager.default.removeItem(at: tempURL) }

        LogManager.shared.debugLog(logTag, "图片保存准备完成（JPEG 转码 + 临时文件）", context: [
            "file": url.lastPathComponent,
            "sourceBytes": "\(data.count)",
            "jpegBytes": "\(jpegData.count)"
        ])

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .photo, fileURL: tempURL, options: options)
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        LogManager.shared.info(logTag, "图片保存成功", context: [
                            "file": url.lastPathComponent,
                            "bytes": "\(jpegData.count)",
                            "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                        ])
                        continuation.resume(returning: nil)
                    } else {
                        let reason = error?.localizedDescription ?? "未知错误"
                        let code = (error as NSError?)?.code ?? 0
                        LogManager.shared.error(logTag, "图片保存失败（相册写入）", context: [
                            "error": reason, "code": "\(code)", "file": url.lastPathComponent
                        ])
                        continuation.resume(returning: "写入相册失败：\(reason)")
                    }
                }
            }
        }
    }

    /// 准备系统分享条目：下载成功后返回 [UIImage]，失败回退 [URL]（供 SwiftUI sheet 呈现 ShareSheet）
    static func prepareShareItems(urlString: String) async -> [Any] {
        guard let url = safeURL(from: urlString) else {
            await LogManager.shared.warning("profile", "图片分享失败：地址无效", context: [:])
            return []
        }
        if let data = await downloadImageData(from: url), let image = UIImage(data: data) {
            return [image]
        }
        return [url]
    }
}

// MARK: - 校园风光图集画廊（多图：轮播 + 网格 + 全屏 + 长按保存/分享）

/// 风光图集详情页：列表封面 → 详情 content 全图集。
/// · 顶部主图轮播（全貌 fit 显示 + 页码胶囊 + 点按全屏）；
/// · 「全部图片」3 列网格，点按全屏、长按系统菜单保存/分享；
/// · 图集正文说明玻璃卡；加载/失败态完备；保存结果 toast 反馈。
struct ProfileAlbumView: View {
    let article: OrgArticle
    @ObservedObject private var store = SchoolProfileStore.shared

    @State private var album: NetworkService.SceneryAlbumDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var fullScreenItem: ProfileFullScreenImage?
    @State private var carouselIndex = 0
    @State private var saveToast: String?
    @State private var saveToastTask: Task<Void, Never>?
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    private var imageURLs: [URL] {
        (album?.images.compactMap { ProfileImageSaveShare.safeURL(from: $0.url) }) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if isLoading {
                    albumSkeleton
                } else if let error = loadError {
                    albumErrorCard(error)
                } else if let album {
                    headerCard(album)
                    if !imageURLs.isEmpty {
                        carouselCard
                        gridCard(album)
                    }
                    if !album.plainText.isEmpty {
                        textCard(album)
                    }
                }
            }
            .padding(16)
        }
        .background(GradientBackground())
        .navigationTitle("校园风光")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toast = saveToast {
                Text(toast)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveToast)
        .fullScreenCover(item: $fullScreenItem) { item in
            FullScreenImageView(url: item.url, title: item.title)
                .sjzPresentationChrome()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .task(id: article.articleId) {
            await loadAlbum()
        }
        .onDisappear {
            saveToastTask?.cancel()
        }
    }

    private func loadAlbum() async {
        if let cached = store.sceneryAlbums[article.articleId] {
            album = cached
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        let startedAt = Date()
        if let detail = await store.loadSceneryAlbum(articleId: article.articleId, title: article.title) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                album = detail
                isLoading = false
            }
            LogManager.shared.debugLog("profile", "风光图集画廊就绪", context: [
                "articleId": article.articleId,
                "images": "\(detail.images.count)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        } else {
            loadError = "图集加载失败，请检查网络后重试"
            isLoading = false
        }
    }

    // MARK: 头部卡（标题 + 张数 + 说明）

    private func headerCard(_ album: NetworkService.SceneryAlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .displaySymbolFont(14, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text(article.title)
                    .displayFont(18, weight: .heavy)
                    .foregroundStyle(.primary)
                Spacer()
                Text("共 \(album.images.count) 张")
                    .displayFont(10, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.sjzGold.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Color.sjzGold.opacity(0.35), lineWidth: 0.5))
            }
            Text("左右滑动浏览精彩瞬间；轻点任意图片全屏查看，长按可保存或分享。")
                .displayFont(11)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 主图轮播（全貌 fit）

    private var carouselCard: some View {
        VStack(spacing: 10) {
            TabView(selection: $carouselIndex) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                    SJZCachedImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                                .padding(6)
                        } else {
                            ZStack {
                                Color.primary.opacity(0.05)
                                if case .failure = phase {
                                    ProgressView().tint(Color.sjzPrimary.opacity(0.6))
                                } else {
                                    ProgressView().tint(Color.sjzPrimary.opacity(0.6))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        fullScreenItem = ProfileFullScreenImage(url: url, title: "\(article.title) · \(index + 1)/\(imageURLs.count)")
                        LogManager.shared.debugLog("profile", "图集全屏打开", context: [
                            "articleId": article.articleId, "index": "\(index)", "total": "\(imageURLs.count)"
                        ])
                    }
                    .contextMenu {
                        Button {
                            Task { await save(url: url, index: index) }
                        } label: {
                            Label("保存图片", systemImage: "square.and.arrow.down")
                                .displayLabelFont(17)
                        }
                        Button {
                            share(url: url, index: index)
                        } label: {
                            Label("分享…", systemImage: "square.and.arrow.up")
                                .displayLabelFont(17)
                        }
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { carouselIndex = index }
                        } label: {
                            Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right")
                                .displayLabelFont(17)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // 页码胶囊
            Text("\(carouselIndex + 1) / \(imageURLs.count)")
                .displayFont(11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .transition(.opacity)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.sjzGold.opacity(0.25), lineWidth: 1))
        .onChange(of: carouselIndex) { _, newIndex in
            LogManager.shared.debugLog("profile", "图集轮播翻页", context: [
                "articleId": article.articleId, "page": "\(newIndex + 1)/\(imageURLs.count)"
            ])
        }
    }

    // MARK: 全部图片网格

    private func gridCard(_ album: NetworkService.SceneryAlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text("全部图片")
                    .displayFont(14, weight: .bold)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(album.images.count)")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                    SJZCachedImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color.primary.opacity(0.05)
                                ProgressView().scaleEffect(0.6).tint(Color.sjzPrimary.opacity(0.6))
                            }
                        }
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        fullScreenItem = ProfileFullScreenImage(url: url, title: "\(article.title) · \(index + 1)/\(imageURLs.count)")
                        LogManager.shared.debugLog("profile", "图集网格图全屏打开", context: ["index": "\(index)"])
                    }
                    .contextMenu {
                        Button {
                            Task { await save(url: url, index: index) }
                        } label: {
                            Label("保存图片", systemImage: "square.and.arrow.down")
                                .displayLabelFont(17)
                        }
                        Button {
                            share(url: url, index: index)
                        } label: {
                            Label("分享…", systemImage: "square.and.arrow.up")
                                .displayLabelFont(17)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 图集说明

    private func textCard(_ album: NetworkService.SceneryAlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text("图集说明")
                    .displayFont(13, weight: .bold)
                    .foregroundStyle(.primary)
            }
            Text(album.plainText)
                .displayFont(13)
                .foregroundStyle(.primary.opacity(0.88))
                .lineSpacing(6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 加载 / 错误 / toast

    private var albumSkeleton: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 280)
                .overlay { ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 90)
                    .overlay { ShimmerView().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
            }
        }
    }

    private func albumErrorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .displaySymbolFont(32, weight: .light)
                .foregroundStyle(Color.sjzPrimary.opacity(0.7))
            Text(message)
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                LogManager.shared.info("profile", "图集加载重试", context: ["articleId": article.articleId])
                Task { await loadAlbum() }
            } label: {
                Text("重新加载")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Color.sjzPrimary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    @MainActor
    private func save(url: URL, index: Int) async {
        LogManager.shared.info("profile", "图集图片保存发起", context: [
            "articleId": article.articleId, "index": "\(index)"
        ])
        if let message = await ProfileImageSaveShare.saveToPhotos(urlString: url.absoluteString, logTag: "profile") {
            presentToast("[保存失败] \(message)")
        } else {
            presentToast("已保存到相册")
        }
    }

    private func share(url: URL, index: Int) {
        LogManager.shared.info("profile", "图集图片分享面板展示", context: [
            "articleId": article.articleId, "index": "\(index)"
        ])
        Task { @MainActor in
            shareItems = await ProfileImageSaveShare.prepareShareItems(urlString: url.absoluteString)
            guard !shareItems.isEmpty else { return }
            showShareSheet = true
        }
    }

    private func presentToast(_ text: String) {
        saveToastTask?.cancel()
        withAnimation { saveToast = text }
        saveToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { saveToast = nil }
        }
    }
}

// MARK: - 合作交流图文详情（分组徽章 + 封面 + 正文 + 图集 + 保存/分享）

/// 合作交流文章详情页：
/// · 国际交流/继续教育：正文全文内联于列表数据，进入直接渲染（封面 + 文字）；
/// · 校企合作：正文与图集承载在文章详情接口（进入即拉取，预热缓存命中秒开）；
/// · 全部图片支持「点击全屏 + 长按系统菜单保存/分享」；
/// · 完整 collaboration 域日志埋点（打开/加载/失败重试/全屏/保存/分享）。
struct ProfileCooperateDetailView: View {
    let entry: CooperateEntry
    @ObservedObject private var store = SchoolProfileStore.shared

    @State private var detail: NetworkService.SceneryAlbumDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var fullScreenItem: ProfileFullScreenImage?
    @State private var saveToast: String?
    @State private var saveToastTask: Task<Void, Never>?
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    private var coverURL: URL? {
        guard let urlString = entry.imageURL,
              !urlString.isEmpty,
              !urlString.contains("no_picture") else { return nil }
        return ProfileImageSaveShare.safeURL(from: urlString)
    }

    private var galleryURLs: [URL] {
        (detail?.images.compactMap { ProfileImageSaveShare.safeURL(from: $0.url) }) ?? []
    }

    private var bodyText: String {
        entry.needsDetailFetch ? (detail?.plainText ?? "") : entry.detail
    }

    private var groupIcon: String {
        switch entry.groupKey {
        case "exchange": return "globe.asia.australia.fill"
        case "continuing-education": return "graduationcap.fill"
        default: return "building.2.fill"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                if let coverURL {
                    coverSection(coverURL)
                }
                if entry.needsDetailFetch {
                    if isLoading && detail == nil {
                        detailSkeleton
                    } else if loadError != nil && detail == nil {
                        detailErrorCard
                    }
                }
                if !bodyText.isEmpty {
                    textCard
                }
                if !galleryURLs.isEmpty {
                    galleryCard
                }
                footerHint
            }
            .padding(16)
        }
        .background(GradientBackground())
        .navigationTitle(entry.groupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toast = saveToast {
                Text(toast)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveToast)
        .fullScreenCover(item: $fullScreenItem) { item in
            FullScreenImageView(url: item.url, title: item.title)
                .sjzPresentationChrome()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .task(id: entry.articleId) {
            await loadDetailIfNeeded()
        }
        .onAppear {
            LogManager.shared.info("collaboration", "合作交流详情页打开", context: [
                "group": entry.groupTitle,
                "title": String(entry.title.prefix(24)),
                "needsDetail": "\(entry.needsDetailFetch)"
            ])
        }
        .onDisappear {
            saveToastTask?.cancel()
            LogManager.shared.debugLog("collaboration", "合作交流详情页离开", context: [
                "articleId": entry.articleId,
                "loaded": "\(detail != nil)"
            ])
        }
    }

    // MARK: 头部卡（分组徽章 + 标题 + 日期 + 详情统计）

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: groupIcon)
                    .displaySymbolFont(14, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text(entry.title)
                    .displayFont(18, weight: .heavy)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Text(entry.groupTitle)
                    .displayFont(9, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.sjzPrimary.opacity(0.08)))
            }
            HStack(spacing: 8) {
                if !entry.dateText.isEmpty {
                    Label(entry.dateText, systemImage: "calendar")
                        .displayLabelFont(10, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                if entry.needsDetailFetch, let detail {
                    Text("正文 \(detail.plainText.count) 字 · 图集 \(detail.images.count) 张")
                        .displayFont(9, weight: .medium)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 封面（全貌显示 · 点击全屏 · 长按保存/分享）

    private func coverSection(_ url: URL) -> some View {
        SJZCachedImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 140)
                    .frame(maxHeight: 300)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 180)
                    .overlay {
                        ProgressView().tint(Color.sjzPrimary.opacity(0.6))
                    }
            }
        }
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            fullScreenItem = ProfileFullScreenImage(url: url, title: entry.title)
            LogManager.shared.debugLog("collaboration", "详情封面全屏打开", context: [
                "title": String(entry.title.prefix(20))
            ])
        }
        .contextMenu {
            Button {
                Task { await save(url: url, label: "封面") }
            } label: {
                Label("保存图片", systemImage: "square.and.arrow.down")
                    .displayLabelFont(17)
            }
            Button {
                share(url: url, label: "封面")
            } label: {
                Label("分享…", systemImage: "square.and.arrow.up")
                    .displayLabelFont(17)
            }
        }
    }

    // MARK: 正文

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text(entry.needsDetailFetch ? "合作详情" : "详细介绍")
                    .displayFont(13, weight: .bold)
                    .foregroundStyle(.primary)
            }
            Text(bodyText)
                .displayFont(13)
                .foregroundStyle(.primary.opacity(0.88))
                .lineSpacing(7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 合作图集（正文内嵌图片 · 3 列网格 · 点击全屏 · 长按保存/分享）

    private var galleryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
                Text("合作图集")
                    .displayFont(14, weight: .bold)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(galleryURLs.count) 张")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(galleryURLs.enumerated()), id: \.offset) { index, url in
                    SJZCachedImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color.primary.opacity(0.05)
                                ProgressView().scaleEffect(0.6).tint(Color.sjzPrimary.opacity(0.6))
                            }
                        }
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        fullScreenItem = ProfileFullScreenImage(
                            url: url, title: "\(entry.title) · \(index + 1)/\(galleryURLs.count)")
                        LogManager.shared.debugLog("collaboration", "合作图集全屏打开", context: [
                            "index": "\(index)", "total": "\(galleryURLs.count)"
                        ])
                    }
                    .contextMenu {
                        Button {
                            Task { await save(url: url, label: "图集\(index + 1)") }
                        } label: {
                            Label("保存图片", systemImage: "square.and.arrow.down")
                                .displayLabelFont(17)
                        }
                        Button {
                            share(url: url, label: "图集\(index + 1)")
                        } label: {
                            Label("分享…", systemImage: "square.and.arrow.up")
                                .displayLabelFont(17)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.sjzGold.opacity(0.2), lineWidth: 1))
    }

    private var footerHint: some View {
        Text("轻点图片全屏查看 · 长按保存或分享")
            .displayFont(10)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }

    // MARK: 加载 / 错误 / 保存 / 分享

    private func loadDetailIfNeeded() async {
        guard entry.needsDetailFetch else { return }
        if let cached = store.cooperateDetails[entry.articleId] {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { detail = cached }
            return
        }
        isLoading = true
        loadError = nil
        let startedAt = Date()
        if let fetched = await store.loadCooperateDetail(articleId: entry.articleId, title: entry.title) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                detail = fetched
                isLoading = false
            }
            LogManager.shared.debugLog("collaboration", "校企合作详情就绪", context: [
                "articleId": entry.articleId,
                "images": "\(fetched.images.count)",
                "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        } else {
            loadError = "详情加载失败，请检查网络后重试"
            isLoading = false
        }
    }

    private var detailSkeleton: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 70)
                .overlay { ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 90)
                .overlay { ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }

    private var detailErrorCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .displaySymbolFont(26, weight: .light)
                .foregroundStyle(Color.sjzOrange.opacity(0.8))
            Text(loadError ?? "详情加载失败")
                .displayFont(12, weight: .semibold)
                .foregroundStyle(.secondary)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                LogManager.shared.info("collaboration", "详情加载重试", context: ["articleId": entry.articleId])
                Task { await loadDetailIfNeeded() }
            } label: {
                Text("重新加载")
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzPrimary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    @MainActor
    private func save(url: URL, label: String) async {
        LogManager.shared.info("collaboration", "详情图片保存发起", context: [
            "label": label, "articleId": entry.articleId
        ])
        if let message = await ProfileImageSaveShare.saveToPhotos(urlString: url.absoluteString, logTag: "collaboration") {
            presentToast("[保存失败] \(message)")
        } else {
            presentToast("已保存到相册")
        }
    }

    private func share(url: URL, label: String) {
        LogManager.shared.info("collaboration", "详情图片分享面板展示", context: [
            "label": label, "articleId": entry.articleId
        ])
        Task { @MainActor in
            shareItems = await ProfileImageSaveShare.prepareShareItems(urlString: url.absoluteString)
            guard !shareItems.isEmpty else { return }
            showShareSheet = true
        }
    }

    private func presentToast(_ text: String) {
        saveToastTask?.cancel()
        withAnimation { saveToast = text }
        saveToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { saveToast = nil }
        }
    }
}