//
//  DataService.swift
//  山西晋中理工学院 APP — 数据管理（缓存 + API + 兜底）
//

import Foundation

@MainActor
final class DataService: ObservableObject {
    static let shared = DataService()

    /// 数据同步完成通知
    static let syncDidCompleteNotification = Notification.Name("DataServiceSyncDidComplete")

    // MARK: - 发布的状态

    @Published var isLoading = false
    @Published var lastError: String?
    @Published var syncErrors: [String] = []
    @Published var syncWarnings: [String] = []
    @Published var dataSource: String = "预置数据"
    @Published var syncLog: [String] = []

    @Published var banners: [Banner] = []
    @Published var bottomBanners: [Banner] = []
    @Published var stats: [StatItem] = defaultStats
    @Published var honors: [Honor] = defaultHonors
    @Published var departments: [Department] = defaultDepartments
    @Published var news: [NewsItem] = defaultNews
    /// 新闻栏目真实 column_id（同步时从 home2 动态解析；服务端栏目 ID 会变更，严禁硬编码）
    @Published private(set) var newsColumnIds: [String: String] = [:]
    @Published var videos: [CampusVideo] = []
    @Published var studentStories: [StudentStory] = []
    @Published var teacherProfiles: [TeacherProfile] = []
    @Published var campusActivities: [CampusActivity] = []
    @Published var campusSceneries: [CampusScenery] = []
    @Published var services: [CampusService] = defaultServices
    @Published var facilities: [Facility] = defaultFacilities
    @Published var timeline: [TimelineEvent] = defaultTimeline

    @Published var importantNews: [NewsItem] = []
    @Published var updateNews: [NewsItem] = []
    @Published var partyNews: [NewsItem] = []
    @Published var notices: [NewsItem] = []
    @Published var admissionNews: [NewsItem] = []
    @Published var campusNews: [NewsItem] = []
    @Published var researchReports: [NewsItem] = []
    @Published var informationNews: [NewsItem] = []

    @Published var siteInfo: SiteInfo?
    @Published var recruitPhones: [String] = []
    @Published var footerLinks: [FooterLink] = []
    @Published var socialPlatforms: [SocialPlatform] = []

    // MARK: - 招生网数据

    @Published var zswHomeData: ZSWHomeData?
    @Published var zswIsLoading = false
    /// 招生网数据最近一次远程成功拉取时间（E12 SWR 判定）
    private var lastZSWFetchTime: Date = .distantPast

    // MARK: - 专业介绍数据

    @Published var specialtyData: SpecialtyData?
    @Published var specialtyIsLoading = false

    // MARK: - 学校信息

    struct SiteInfo {
        let titleCn: String
        let titleEn: String
        let domain: String
        let logo: String?
        let themeColor: String?
        let address: String?
        let phone: String?
        let email: String?
    }

    // MARK: - 文章完整详情

    struct ArticleFullDetail {
        let title: String
        let content: String
        let plainTextContent: String
        let author: String
        let source: String
        let publishTime: String
        let images: [ArticleImage]
        let articleId: String
    }

    struct ArticleImage: Identifiable {
        var id: String { url }
        let url: String
        let alt: String?
    }

    // MARK: - 文章详情内存缓存

    final class ArticleDetailCacheEntry {
        let detail: ArticleFullDetail
        let fetchTime: Date

        init(detail: ArticleFullDetail) {
            self.detail = detail
            self.fetchTime = Date()
        }
    }

    private let articleDetailCache: NSCache<NSString, ArticleDetailCacheEntry> = {
        let cache = NSCache<NSString, ArticleDetailCacheEntry>()
        configureNSCacheLimits(cache)
        return cache
    }()

    private static func configureNSCacheLimits(_ cache: NSCache<NSString, ArticleDetailCacheEntry>) {
        if CacheModeManager.shared.isCacheEnabled {
            cache.countLimit = 200
            cache.totalCostLimit = 80 * 1024 * 1024
        } else {
            cache.countLimit = 50
            cache.totalCostLimit = 20 * 1024 * 1024
        }
    }

    func refreshCacheLimits() {
        Self.configureNSCacheLimits(articleDetailCache)
        LogManager.shared.info("data", "缓存限制已刷新", context: [
            "countLimit": "\(articleDetailCache.countLimit)",
            "totalCostLimit": ByteCountFormatter.string(fromByteCount: Int64(articleDetailCache.totalCostLimit), countStyle: .file)
        ])
    }

    func isArticleDetailCached(id: String) -> Bool {
        articleDetailCache.object(forKey: id as NSString) != nil
    }

    func isZSWArticleCached(id: String) -> Bool {
        articleDetailCache.object(forKey: "zsw_\(id)" as NSString) != nil
    }

    private(set) var cachedArticleCount: Int = 0
    private(set) var estimatedCacheMemoryBytes: Int64 = 0

    private func incrementCacheEstimate(articleId: String, cost: Int) {
        cachedArticleCount += 1
        estimatedCacheMemoryBytes += Int64(cost)
        LogManager.shared.debugLog("data", "缓存估算更新", context: [
            "count": "\(cachedArticleCount)",
            "memory": ByteCountFormatter.string(fromByteCount: estimatedCacheMemoryBytes, countStyle: .file)
        ])
    }

    // MARK: - 缓存

    private let cacheDir: URL
    private let fileManager = FileManager.default

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDir = docs.appendingPathComponent("SXJZIT_Cache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // 加载缓存
        if loadCache() {
            dataSource = "缓存"
        }
        // 加载招生网缓存
        loadZSWCache()
        // 加载专业介绍缓存
        loadSpecialtyCache()
    }

    // MARK: - 同步

    /// 同步冷却时间（秒）
    private let syncCooldown: TimeInterval = 10
    private var lastSyncTime: Date = .distantPast

    func syncIfNeeded(force: Bool = false) {
        guard !isLoading else { return }

        if !force && Date().timeIntervalSince(lastSyncTime) < syncCooldown {
            return
        }

        // F4 缓存模式联动：10 分钟内已成功同步过 → 跳过远程全量同步（本地缓存/内存数据直接使用）
        if !force, CacheModeManager.shared.isCacheEnabled,
           Date().timeIntervalSince(lastSyncTime) < 600 {
            LogManager.shared.info("data", "缓存模式：10分钟内已同步，跳过远程全量同步", context: [
                "interval": String(format: "%.0fs", Date().timeIntervalSince(lastSyncTime)),
                "dataSource": dataSource
            ])
            return
        }

        isLoading = true
        lastError = nil
        syncErrors = []
        syncWarnings = []
        lastSyncTime = Date()
        Task {
            await doFullSync()
            isLoading = false
            NotificationCenter.default.post(name: Self.syncDidCompleteNotification, object: nil)
            // E5 启动预热：同步完成后预取首屏热点图片
            await warmUpHotImagesIfNeeded()
        }
    }

    /// E5 启动预热：同步完成后预取首屏热点图片（缓存模式预热首屏缩略图+轮播，即时模式仅轮播）
    private func warmUpHotImagesIfNeeded() async {
        var urls: [URL] = []
        for banner in banners.prefix(6) {
            // 服务端 banner 数据偶发返回键名（如 "video_poster"）而非完整 URL——
            // 仅接受 http/https 绝对地址，杜绝构造非法 URL（NSURLError -1002 不支持的URL）
            if !banner.posterImgSrc.isEmpty,
               banner.posterImgSrc.hasPrefix("http://") || banner.posterImgSrc.hasPrefix("https://"),
               let u = URL(string: banner.posterImgSrc) {
                urls.append(u)
            }
        }
        if CacheModeManager.shared.isCacheEnabled {
            let hotLists = [importantNews, updateNews, partyNews, notices, admissionNews]
            for list in hotLists {
                for item in list.prefix(5) {
                    if let img = item.imageUrl, !img.isEmpty, let u = URL(string: img) {
                        urls.append(u)
                    }
                }
            }
        }
        let unique = Array(Set(urls)).prefix(20)
        guard !unique.isEmpty else { return }
        LogManager.shared.info("startup", "启动图片预热开始", context: [
            "count": "\(unique.count)",
            "cacheMode": CacheModeManager.shared.mode.rawValue
        ])
        await SJZImagePrefetcher.prefetch(urls: Array(unique))
    }

    /// 完整同步流程（永不抛出异常）
    private func doFullSync() async {
        syncLog = []
        syncLog.append("开始同步 \(Date().formatted(.dateTime.hour().minute().second()))")
        LogManager.shared.info("articleSync", "开始数据同步")

        // 1. 获取基础数据
        let home2: NetworkService.Home2DTO?
        let head: NetworkService.HeadDTO?
        let foot: NetworkService.FootDTO?

        do { home2 = try await NetworkService.shared.fetchHome2(); syncLog.append("✅ home2 成功") } catch {
            lastError = "首页数据获取失败：\(error.localizedDescription)"
            syncLog.append("❌ home2 失败: \(error.localizedDescription)")
            home2 = nil
        }
        do { head = try await NetworkService.shared.fetchHead(); syncLog.append("✅ head 成功") } catch {
            syncErrors.append("导航数据获取失败：\(error.localizedDescription)")
            syncLog.append("❌ head 失败: \(error.localizedDescription)")
            head = nil
        }
        do { foot = try await NetworkService.shared.fetchFoot(); syncLog.append("✅ foot 成功") } catch {
            syncErrors.append("底部数据获取失败：\(error.localizedDescription)")
            syncLog.append("❌ foot 失败: \(error.localizedDescription)")
            foot = nil
        }

        // 如果三个基础接口全部失败，直接回退缓存
        if home2 == nil && head == nil && foot == nil {
            if loadCache() { dataSource = "缓存" }
            return
        }

        var anyNewsUpdated = false

        // 2. Banner
        if let h2 = home2 {
            if let dto = h2.topBanners, !dto.isEmpty {
                banners = dto.map { Banner(videoSrc: $0.videoSrc ?? "", posterImgSrc: $0.posterImgSrc ?? "", videoTitleImgSrc: $0.videoTitleImgSrc ?? "") }
            }
        }

        // 3. 荣誉
        if let h2 = home2, let colId = h2.achievements?.columnId {
            let articles = await safeFetchArticles(colId, pageSize: 50, label: "校园荣誉")
            if !articles.isEmpty {
                honors = articles.compactMap { a in
                    guard let t = a.title, !t.isEmpty else { return nil }
                    return Honor(title: t, detail: a.description ?? "", icon: "trophy.fill",
                                 imageUrl: a.imageUrl, tag: a.tag, date: formatDate(a.createTime), articleId: a.id)
                }
            }
        }

        // 4. 新闻栏目（全部从 home2.news.children 取，API key 名与 title_cn 对照见下方注释）
        //  API key       title_cn    映射到
        //  importants  → 学校要闻  → importantNews
        //  updates     → 新闻资讯  → updateNews
        //  resports    → 党建动态  → partyNews     (key 名有误导性，实际是党建)
        //  notices     → 通知公告  → notices
        //  informations→ 招生信息  → admissionNews (key 名有误导性，实际是招生；服务端 API 返回 500)
        if let h2 = home2 {
            let newsColumns: [(String?, String)] = [
                (h2.news?.children?.importants?.columnId, "学校要闻"),
                (h2.news?.children?.updates?.columnId, "新闻资讯"),
                (h2.news?.children?.resports?.columnId, "党建动态"),
                (h2.news?.children?.notices?.columnId, "通知公告"),
                (h2.news?.children?.informations?.columnId, "招生信息"),
            ]

            for (optColId, name) in newsColumns {
                // 记录真实栏目 ID（供机构页文章搜索运行时复用；服务端 ID 变更时自动跟随）
                if let colId = optColId {
                    newsColumnIds[name] = colId
                }
                // 招生信息：优先使用 home2 自带 articles，不依赖 columnId
                if name == "招生信息",
                   let home2Articles = h2.news?.children?.informations?.articles?.list,
                   !home2Articles.isEmpty {
                    let items = home2Articles.compactMap { toNewsItem($0, name, columnId: optColId) }.map { item in
                        var item = item
                        item.articleId = nil  // 招生信息为静态卡片，无文章详情页
                        return item
                    }
                    if !items.isEmpty {
                        anyNewsUpdated = true
                        admissionNews = items
                        syncLog.append("招生信息: \(items.count) 条 (来自 home2)")
                    }
                    continue
                }

                guard let colId = optColId else {
                    syncLog.append("⚠️ \(name) columnId 为空")
                    continue
                }
                let articles = await safeFetchArticles(colId, pageSize: 50, label: name)
                syncLog.append("\(name): \(articles.count) 条")
                let items = articles.compactMap { toNewsItem($0, name, columnId: colId) }
                if !items.isEmpty {
                    anyNewsUpdated = true
                    switch name {
                    case "学校要闻": importantNews = items
                    case "新闻资讯": updateNews = items
                    case "党建动态": partyNews = items
                    case "通知公告": notices = items
                    case "招生信息": admissionNews = items
                    default: break
                    }
                }
            }
        }

        // 5. 合并全部新闻
        if anyNewsUpdated {
            news = importantNews + updateNews + partyNews + notices + admissionNews
        }

        // 6. 视频（并行获取文章详情，提取视频 URL）
        if let h2 = home2 {
            if let list = h2.videos?.articles?.list, !list.isEmpty {
                var videoItems: [(Int, CampusVideo)] = []
                await withTaskGroup(of: (Int, String?).self) { group in
                    for (index, a) in list.enumerated() {
                        guard let articleId = a.id, !articleId.isEmpty else { continue }
                        group.addTask {
                            let videoUrl = await Self.fetchVideoUrl(articleId: articleId)
                            return (index, videoUrl)
                        }
                    }
                    var videoUrls: [Int: String] = [:]
                    for await (index, url) in group {
                        if let url = url, !url.isEmpty {
                            videoUrls[index] = url
                        }
                    }
                    for (index, a) in list.enumerated() {
                        guard let t = a.title, !t.isEmpty else { continue }
                        videoItems.append((index, CampusVideo(
                            title: t,
                            videoUrl: videoUrls[index] ?? "",
                            thumbnailUrl: a.imageUrl,
                            description: a.description
                        )))
                    }
                }
                videos = videoItems.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }
            if let list = h2.students?.articles?.list, !list.isEmpty {
                studentStories = list.compactMap { a in
                    guard let t = a.title, !t.isEmpty else { return nil }
                    return StudentStory(title: t, summary: a.description ?? "", imageUrl: a.imageUrl, date: formatDate(a.createTime), articleId: a.id)
                }
            }
            if let list = h2.teachers?.articles?.list, !list.isEmpty {
                teacherProfiles = list.compactMap { a in
                    guard let t = a.title, !t.isEmpty else { return nil }
                    return TeacherProfile(title: t, summary: a.description ?? "", imageUrl: a.imageUrl, date: formatDate(a.createTime), articleId: a.id)
                }
            }
            // campus 现在是 CampusBlockDTO，activities 在 children.activites；
            // 注：首页「校园风光」模块已退役（2026-09-24），风光内容由「学校概况」模块承载，
            // campusSceneries 字段保留仅供数据概览/校园 Tab 兼容展示，不再参与首页同步赋值
            if let h2 = home2, let campusChildren = h2.campus?.children {
                if let list = campusChildren.activites?.articles?.list, !list.isEmpty {
                    campusActivities = list.compactMap { a in
                        guard let t = a.title, !t.isEmpty else { return nil }
                        return CampusActivity(title: t, summary: a.description ?? "", imageUrl: a.imageUrl, date: formatDate(a.createTime), englishTitle: a.tag, articleId: a.id)
                    }
                }
            }
        }

        // 7. 院系（合并 API 数据与预置数据，保留详细信息）
        if let hd = head, let menus = hd.menus {
            let apiDepts = extractDepartments(from: menus)
            if !apiDepts.isEmpty {
                // 合并：API 提供名称和顺序，预置数据提供详细信息
                departments = apiDepts.map { apiDept in
                    if let defaultDept = findMatchingDefaultDept(for: apiDept.name) {
                        return defaultDept  // 使用预置的完整数据
                    }
                    return apiDept  // API 新增的院系
                }
            }
        }

        // 8. 学校信息
        if let hd = head, let site = hd.site {
            siteInfo = SiteInfo(titleCn: site.titleCn ?? SchoolInfo.name, titleEn: site.titleEn ?? SchoolInfo.englishName,
                                domain: site.domain ?? "", logo: site.logo, themeColor: site.themeColor,
                                address: site.address, phone: site.phone, email: site.email)
        }

        // 9. 底部信息
        if let ft = foot {
            if let phones = ft.recruitPhone, !phones.isEmpty { recruitPhones = phones }
            if let list = ft.links?.list, !list.isEmpty {
                footerLinks = list.compactMap { l in
                    guard let n = l.name, !n.isEmpty else { return nil }
                    return FooterLink(name: n, href: l.href ?? "")
                }
            }
            if let list = ft.platforms?.list, !list.isEmpty {
                socialPlatforms = list.compactMap { p in
                    guard let t = p.title, !t.isEmpty else { return nil }
                    return SocialPlatform(title: t, img: p.img ?? "")
                }
            }
        }

        // 10. 机构设置数据同步（通过 head API 菜单更新 site_key）
        if let hd = head, let menus = hd.menus {
            OrganizationManager.shared.updateSiteKeys(from: menus)
            syncLog.append("✅ 机构设置 site_key 已更新")
        }

        // 11. 保存缓存
        saveCache()
        dataSource = "服务器"
        if syncErrors.isEmpty {
            lastError = nil
        } else {
            lastError = "部分栏目同步失败（\(syncErrors.count)项），其他数据已更新"
        }
        if !syncWarnings.isEmpty {
            syncLog.append("⚠️ 警告: \(syncWarnings.joined(separator: "; "))")
        }
        syncLog.append("✅ 同步完成 news=\(news.count) honors=\(honors.count) depts=\(departments.count)")
        LogManager.shared.info("articleSync", "数据同步完成", context: [
            "news": "\(news.count)", "honors": "\(honors.count)",
            "departments": "\(departments.count)", "errors": "\(syncErrors.count)"
        ])

        // 12. 招生网数据（后台加载，不阻塞主流程）
        Task { await loadZSWHomeData() }
        // 13. 专业介绍数据（独立加载，不依赖招生网数据成功）
        Task { await loadSpecialtyData() }
    }

    // MARK: - 招生网数据加载

    /// 加载招生网首页数据
    func loadZSWHomeData() async {
        zswIsLoading = true
        defer { zswIsLoading = false }

        // E12 招生网 SWR：缓存模式下本地缓存已加载且 30 分钟内刷新过 → 直接用缓存，跳过远程
        if CacheModeManager.shared.isCacheEnabled, zswHomeData != nil,
           Date().timeIntervalSince(lastZSWFetchTime) < 1800 {
            LogManager.shared.info("data", "缓存模式：招生网数据使用本地缓存，跳过远程加载", context: [
                "cacheAge": String(format: "%.0fs", Date().timeIntervalSince(lastZSWFetchTime))
            ])
            return
        }

        do {
            let dto = try await NetworkService.shared.fetchZSWHome2()
            let siteId = dto.site?.siteId ?? "cb3b1fe4fcdf40999b0c162015c3326d"
            let navData = dto.nav?.first?.data

            // 解析首页三栏目（录取查询、历年分数线、专业介绍）
            var recruitItems: [ZSWRecruitItem] = []
            if let oneChildren = navData?.one?.children?.list {
                recruitItems = oneChildren.compactMap { child in
                    guard let id = child.id, let titleCn = child.titleCn else { return nil }
                    let articles = (child.articles?.list ?? []).compactMap { a -> ZSWArticle? in
                        guard let title = a.title, !title.isEmpty else { return nil }
                        return ZSWArticle(articleId: a.id, title: title,
                                          description: a.description ?? "",
                                          imageUrl: a.imageUrl, updateTime: a.updateTime, tag: a.tag)
                    }
                    return ZSWRecruitItem(id: id, titleCn: titleCn,
                                          titleEn: child.titleEn ?? "",
                                          href: child.href ?? "", imageUrl: child.imageUrl,
                                          isOut: child.isOut == 1, articles: articles)
                }
            }

            // 解析招生计划
            var enrollmentPlan: ZSWSection?
            if let ep = navData?.enrollmentPlan, let colId = ep.columnId {
                let articles = (ep.articles?.list ?? []).compactMap { a -> ZSWArticle? in
                    guard let title = a.title, !title.isEmpty else { return nil }
                    return ZSWArticle(articleId: a.id, title: title,
                                      description: a.description ?? "",
                                      imageUrl: a.imageUrl, updateTime: a.updateTime, tag: a.tag)
                }
                enrollmentPlan = ZSWSection(id: colId, columnId: colId,
                                            titleCn: ep.titleCn ?? "招生计划",
                                            titleEn: ep.titleEn ?? "enrollment-plan",
                                            componentType: ep.componentType ?? "news",
                                            articles: articles)
            }

            // 解析招生公告
            var notices: ZSWSection?
            if let nt = navData?.notice, let colId = nt.columnId {
                let articles = (nt.articles?.list ?? []).compactMap { a -> ZSWArticle? in
                    guard let title = a.title, !title.isEmpty else { return nil }
                    return ZSWArticle(articleId: a.id, title: title,
                                      description: a.description ?? "",
                                      imageUrl: a.imageUrl, updateTime: a.updateTime, tag: a.tag)
                }
                notices = ZSWSection(id: colId, columnId: colId,
                                     titleCn: nt.titleCn ?? "招生公告",
                                     titleEn: nt.titleEn ?? "notice",
                                     componentType: nt.componentType ?? "notice",
                                     articles: articles)
            }

            // 解析报考指南子栏目
            var guideChildren: [ZSWGuideChild] = []
            if let guideChildrenList = navData?.applicationGuide?.children?.list {
                guideChildren = guideChildrenList.compactMap { child in
                    guard let id = child.id, let titleCn = child.titleCn else { return nil }
                    let articles = (child.articles?.list ?? []).compactMap { a -> ZSWArticle? in
                        guard let title = a.title, !title.isEmpty else { return nil }
                        return ZSWArticle(articleId: a.id, title: title,
                                          description: a.description ?? "",
                                          imageUrl: a.imageUrl, updateTime: a.updateTime, tag: a.tag)
                    }
                    return ZSWGuideChild(id: id, columnId: id,
                                         titleCn: titleCn,
                                         titleEn: child.titleEn ?? "",
                                         articles: articles)
                }
            }

            // 解析招生动态
            var enrollmentNews: ZSWSection?
            if let en = navData?.enrollmentNews, let colId = en.columnId {
                let articles = (en.articles?.list ?? []).compactMap { a -> ZSWArticle? in
                    guard let title = a.title, !title.isEmpty else { return nil }
                    return ZSWArticle(articleId: a.id, title: title,
                                      description: a.description ?? "",
                                      imageUrl: a.imageUrl, updateTime: a.updateTime, tag: a.tag)
                }
                enrollmentNews = ZSWSection(id: colId, columnId: colId,
                                            titleCn: en.titleCn ?? "招生动态",
                                            titleEn: en.titleEn ?? "enrollment-news",
                                            componentType: en.componentType ?? "notice",
                                            articles: articles)
            }

            let homeData = ZSWHomeData(
                siteId: siteId,
                recruitItems: recruitItems,
                enrollmentPlan: enrollmentPlan,
                notices: notices,
                guideChildren: guideChildren,
                enrollmentNews: enrollmentNews
            )
            zswHomeData = homeData
            lastZSWFetchTime = Date()
            saveZSWCache(homeData)
            syncLog.append("✅ 招生网数据加载成功")
            // 后台加载专业介绍数据
            Task { await loadSpecialtyData() }
        } catch {
            syncLog.append("⚠️ 招生网数据加载失败: \(error.localizedDescription)")
        }
    }

    /// 加载专业介绍数据（学院分组 + 专业列表）
    func loadSpecialtyData() async {
        specialtyIsLoading = true
        defer { specialtyIsLoading = false }

        let siteId = zswHomeData?.siteId ?? "cb3b1fe4fcdf40999b0c162015c3326d"
        let columnId = "25d7bd39e49a468880356e302b9ccf1d"

        // 重试最多2次，间隔1秒
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let data = try await NetworkService.shared.fetchSpecialtyData(
                    siteId: siteId, columnId: columnId
                )
                specialtyData = data
                saveSpecialtyCache(data)
                syncLog.append("✅ 专业介绍数据加载成功: \(data.colleges.count) 个学院, \(data.colleges.reduce(0) { $0 + $1.majors.count }) 个专业")
                return
            } catch {
                lastError = error
                if attempt < maxRetries {
                    LogManager.shared.warning("articleSync", "专业介绍数据加载失败，重试中", context: [
                        "attempt": "\(attempt + 1)/\(maxRetries)",
                        "error": error.localizedDescription
                    ])
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        syncLog.append("⚠️ 专业介绍数据加载失败（已重试\(maxRetries)次）: \(lastError?.localizedDescription ?? "未知错误")")
        LogManager.shared.error("articleSync", "专业介绍数据加载失败", context: [
            "error": lastError?.localizedDescription ?? "未知错误",
            "retries": "\(maxRetries)"
        ])
    }

    // MARK: 文章搜索栏目解析（机构页搜索服务）

    /// 文章搜索可用于的栏目（名称 → 真实 column_id）的有序快照。
    /// 栏目 ID 由最近一次同步从 home2 动态解析（服务端 ID 会变更，严禁硬编码）。
    func articleSearchColumnEntries() -> [(String, String)] {
        let order = ["学校要闻", "新闻资讯", "党建动态", "通知公告"]
        var entries: [(String, String)] = []
        for name in order {
            if let id = newsColumnIds[name], !id.isEmpty {
                entries.append((name, id))
            }
        }
        return entries
    }

    /// 现场拉取 home2 刷新栏目 ID（搜索缓存缺失时兜底；成功即写回供后续秒用）
    func refreshNewsColumnIdsFromHome2() async -> Bool {
        do {
            let home2 = try await NetworkService.shared.fetchHome2()
            guard let children = home2.news?.children else { return false }
            let source: [(String, NetworkService.ColumnDTO?)] = [
                ("学校要闻", children.importants),
                ("新闻资讯", children.updates),
                ("党建动态", children.resports),
                ("通知公告", children.notices),
                ("招生信息", children.informations)
            ]
            var updated = false
            for (name, col) in source {
                if let id = col?.columnId, !id.isEmpty {
                    newsColumnIds[name] = id
                    updated = true
                }
            }
            if updated {
                LogManager.shared.info("data", "文章搜索栏目 ID 已从 home2 实时解析", context: [
                    "entries": "\(articleSearchColumnEntries().map { "\($0.0)=\(String($0.1.prefix(8)))…" }.joined(separator: ","))"
                ])
            }
            return !articleSearchColumnEntries().isEmpty
        } catch {
            LogManager.shared.warning("data", "home2 栏目解析失败（搜索兜底不可用）", context: [
                "error": error.localizedDescription
            ])
            return false
        }
    }

    /// 安全拉取栏目文章（内部捕获所有错误，永不抛出）
    private func safeFetchArticles(_ columnId: String, pageSize: Int = 50, label: String) async -> [NetworkService.ArticleDTO] {
        var all: [NetworkService.ArticleDTO] = []
        var seen = Set<String>()

        for page in 1...6 {
            do {
                let result = try await NetworkService.shared.fetchArticles(columnId: columnId, page: page, size: pageSize)
                guard let list = result.articles?.list, !list.isEmpty else { break }
                for a in list {
                    let key = a.id ?? a.title ?? ""
                    if !key.isEmpty, !seen.contains(key) {
                        seen.insert(key)
                        all.append(a)
                    }
                }
                if list.count < pageSize { break }
            } catch {
                // 服务端错误（如 500、data:null）降级为警告，不阻塞其他栏目同步
                if let ne = error as? NetworkError, case .serverError = ne {
                    syncWarnings.append("「\(label)」栏目服务端暂不可用，已跳过")
                } else {
                    syncErrors.append("「\(label)」第\(page)页加载失败：\(error.localizedDescription)")
                }
                break
            }
        }
        return all
    }

    /// DTO 转 NewsItem
    private func toNewsItem(_ a: NetworkService.ArticleDTO, _ category: String, columnId: String? = nil) -> NewsItem? {
        guard let title = a.resolvedTitle, !title.isEmpty else { return nil }
        return NewsItem(title: title, date: formatDate(a.createTime),
                        category: category, summary: a.description ?? "",
                        content: a.description ?? "", imageUrl: a.imageUrl,
                        columnId: columnId, articleId: a.id, href: a.href)
    }

    // MARK: - 文章详情（按需加载）

    func loadArticleDetail(articleId: String) async throws -> String {
        let detail = try await NetworkService.shared.fetchArticleDetail(articleId: articleId)
        return detail.content ?? detail.description ?? ""
    }

    /// 加载完整文章详情（标题、内容、作者、来源、图片列表等）
    /// 优先从 NSCache 内存缓存返回，命中时零延迟即刻展示
    func loadArticleFullDetail(articleId: String) async throws -> ArticleFullDetail {
        let startTime = Date()
        let cacheKey = articleId as NSString

        if let cached = articleDetailCache.object(forKey: cacheKey) {
            let elapsed = Date().timeIntervalSince(startTime)
            let cacheAge = Date().timeIntervalSince(cached.fetchTime)
            CacheModeManager.shared.recordHit(articleId: articleId, cacheAge: cacheAge)
            LogManager.shared.info("data", "文章详情缓存命中，秒开呈现", context: [
                "articleId": articleId,
                "cacheAge": String(format: "%.0fs", cacheAge),
                "lookupTime": String(format: "%.1fms", elapsed * 1000),
                "cacheMode": CacheModeManager.shared.mode.rawValue
            ])
            return cached.detail
        }

        CacheModeManager.shared.recordMiss(articleId: articleId)
        LogManager.shared.info("data", "文章详情缓存未命中，发起网络请求", context: [
            "articleId": articleId,
            "cacheMode": CacheModeManager.shared.mode.rawValue
        ])
        let detail = try await NetworkService.shared.fetchArticleDetail(
            articleId: articleId, useCache: true)
        let result = parseArticleDetail(detail, articleId: articleId)

        let entry = ArticleDetailCacheEntry(detail: result)
        let cost = result.plainTextContent.utf8.count + result.content.utf8.count + result.images.count * 512
        articleDetailCache.setObject(entry, forKey: cacheKey, cost: cost)
        incrementCacheEstimate(articleId: articleId, cost: cost)

        let responseSize = result.content.utf8.count + result.plainTextContent.utf8.count
        CacheModeManager.shared.recordSavedTraffic(bytes: Int64(responseSize))

        let elapsed = Date().timeIntervalSince(startTime)
        LogManager.shared.info("data", "文章详情已写入缓存", context: [
            "articleId": articleId,
            "contentLength": "\(result.plainTextContent.count)",
            "imageCount": "\(result.images.count)",
            "elapsed": String(format: "%.0fms", elapsed * 1000),
            "cacheMode": CacheModeManager.shared.mode.rawValue
        ])
        return result
    }

    /// 预加载文章详情到缓存（后台线程执行，不阻塞 UI）
    /// 用于通知点击等场景：在等待 Face ID / 场景激活的间隙并行请求，实现秒开
    func preloadArticleDetail(articleId: String) {
        let cacheKey = articleId as NSString
        if articleDetailCache.object(forKey: cacheKey) != nil {
            LogManager.shared.debugLog("data", "文章详情已在缓存，跳过预加载", context: [
                "articleId": articleId
            ])
            return
        }

        let articleIdCopy = articleId
        Task.detached { [weak self] in
            guard let self = self else { return }
            let startTime = Date()
            await LogManager.shared.info("data", "后台预加载文章详情启动", context: [
                "articleId": articleIdCopy
            ])
            do {
                let detail = try await NetworkService.shared.fetchArticleDetail(
                    articleId: articleIdCopy, useCache: true)
                let result = self.parseArticleDetail(detail, articleId: articleIdCopy)
                let entry = ArticleDetailCacheEntry(detail: result)
                let keyString = articleIdCopy
                let cost = result.plainTextContent.utf8.count + result.content.utf8.count + result.images.count * 512
                await MainActor.run { [keyString, entry, cost] in
                    self.articleDetailCache.setObject(entry, forKey: keyString as NSString, cost: cost)
                }
                let elapsed = Date().timeIntervalSince(startTime)
                await LogManager.shared.info("data", "后台预加载文章详情完成", context: [
                    "articleId": articleIdCopy,
                    "elapsed": String(format: "%.0fms", elapsed * 1000),
                    "contentLength": "\(result.plainTextContent.count)"
                ])
            } catch {
                let elapsed = Date().timeIntervalSince(startTime)
                await LogManager.shared.warning("data", "后台预加载文章详情失败", context: [
                    "articleId": articleIdCopy,
                    "error": error.localizedDescription,
                    "elapsed": String(format: "%.0fms", elapsed * 1000)
                ])
            }
        }
    }

    /// 清除文章详情缓存（内存警告或手动刷新时调用）
    func clearArticleDetailCache() {
        articleDetailCache.removeAllObjects()
        LogManager.shared.info("data", "文章详情内存缓存已清空", context: [:])
    }

    /// 加载招生网文章完整详情（缓存模式优先使用 NSCache）
    func loadZSWArticleFullDetail(articleId: String, siteId: String = "cb3b1fe4fcdf40999b0c162015c3326d") async throws -> ArticleFullDetail {
        let startTime = Date()
        let cacheKey = "zsw_\(articleId)" as NSString

        if CacheModeManager.shared.isCacheEnabled,
           let cached = articleDetailCache.object(forKey: cacheKey) {
            let elapsed = Date().timeIntervalSince(startTime)
            let cacheAge = Date().timeIntervalSince(cached.fetchTime)
            CacheModeManager.shared.recordHit(articleId: "zsw_\(articleId)", cacheAge: cacheAge)
            LogManager.shared.info("data", "招生网文章详情缓存命中，秒开呈现", context: [
                "articleId": articleId,
                "cacheAge": String(format: "%.0fs", cacheAge),
                "lookupTime": String(format: "%.1fms", elapsed * 1000),
                "cacheMode": "cached"
            ])
            return cached.detail
        }

        CacheModeManager.shared.recordMiss(articleId: "zsw_\(articleId)")
        LogManager.shared.info("data", "招生网文章详情缓存未命中，发起网络请求", context: [
            "articleId": articleId,
            "cacheMode": CacheModeManager.shared.mode.rawValue
        ])
        let detail = try await NetworkService.shared.fetchZSWArticleDetail(articleId: articleId, siteId: siteId)
        let result = parseArticleDetail(detail, articleId: articleId)

        if CacheModeManager.shared.isCacheEnabled {
            let entry = ArticleDetailCacheEntry(detail: result)
            let cost = result.plainTextContent.utf8.count + result.content.utf8.count + result.images.count * 512
            articleDetailCache.setObject(entry, forKey: cacheKey, cost: cost)
            incrementCacheEstimate(articleId: "zsw_\(articleId)", cost: cost)
            let responseSize = result.content.utf8.count + result.plainTextContent.utf8.count
            CacheModeManager.shared.recordSavedTraffic(bytes: Int64(responseSize))
            LogManager.shared.info("data", "招生网文章详情已写入缓存", context: [
                "articleId": articleId,
                "contentLength": "\(result.plainTextContent.count)",
                "imageCount": "\(result.images.count)",
                "elapsed": String(format: "%.0fms", Date().timeIntervalSince(startTime) * 1000)
            ])
        }

        return result
    }

    /// 解析文章详情（纯函数，非隔离于 MainActor，可在后台线程并行执行）
    nonisolated private func parseArticleDetail(_ detail: NetworkService.ArticleDetailDTO, articleId: String) -> ArticleFullDetail {
        let rawContent = detail.content ?? detail.description ?? ""
        let plainText = rawContent.strippingHTMLTags()
        let images: [ArticleImage] = extractImages(from: rawContent)

        let displayContent: String
        if rawContent.isEmpty {
            displayContent = detail.description ?? ""
        } else {
            displayContent = rawContent
        }

        return ArticleFullDetail(
            title: detail.title ?? "",
            content: displayContent,
            plainTextContent: plainText.isEmpty ? (detail.description ?? "").strippingHTMLTags() : plainText,
            author: detail.author ?? "",
            source: detail.source ?? "",
            publishTime: detail.createTime ?? "",
            images: images,
            articleId: articleId
        )
    }

    /// 从文章详情中提取视频 URL（并行请求）
    private static func fetchVideoUrl(articleId: String) async -> String? {
        do {
            let detail = try await NetworkService.shared.fetchArticleDetail(articleId: articleId)
            let content = detail.content ?? ""
            return extractVideoUrlFromHTML(content)
        } catch {
            return nil
        }
    }

    /// 从 HTML 内容中提取 <video><source src="..."> 的视频 URL
    private static func extractVideoUrlFromHTML(_ html: String) -> String? {
        let pattern = #"<source\s+src="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           match.numberOfRanges > 1,
           let srcRange = Range(match.range(at: 1), in: html) {
            return String(html[srcRange])
        }
        return nil
    }

    /// 从 HTML 内容中提取图片列表（纯函数，非隔离于 MainActor）
    nonisolated private func extractImages(from html: String) -> [ArticleImage] {
        var images: [ArticleImage] = []
        let pattern = #"<img[^>]+src=["']([^"']+)["'][^>]*(?:alt=["']([^"']*)["'])?[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return images
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let srcRange = match.range(at: 1)
            if srcRange.location != NSNotFound, let srcRange = Range(srcRange, in: html) {
                let rawUrl = String(html[srcRange])
                // 过滤掉本地文件路径（如 file:///C:\Users\...），这些是编辑从 Word/WPS 粘贴时带入的无效路径
                if rawUrl.hasPrefix("file://") {
                    print("[DataService] Skipping local file path: \(rawUrl)")
                    return
                }
                let url = safeImageURL(from: rawUrl)
                print("[DataService] Extracted image - raw: \(rawUrl)")
                print("[DataService] Extracted image - encoded: \(url)")
                var alt: String? = nil
                if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
                   let altRange = Range(match.range(at: 2), in: html) {
                    alt = String(html[altRange])
                }
                images.append(ArticleImage(url: url, alt: alt))
            }
        }
        print("[DataService] Total images extracted: \(images.count)")
        return images
    }

    /// 对图片 URL 进行安全编码，处理中文等非 ASCII 字符，并解析相对路径为绝对 URL
    nonisolated private func safeImageURL(from string: String) -> String {
        var urlString = string

        // 处理相对路径：文章详情 HTML 中的图片 URL 可能是相对路径（如 /uploads/...），
        // 需要解析为绝对 URL，否则 URLSession 无法正确加载
        if urlString.hasPrefix("/") {
            if urlString.hasPrefix("//") {
                // 协议相对 URL: //www.sxjzit.edu.cn/path → https://www.sxjzit.edu.cn/path
                urlString = "https:" + urlString
            } else {
                // 站点相对路径: /uploads/... → https://www.sxjzit.edu.cn/uploads/...
                urlString = SchoolInfo.website + urlString
            }
            print("[DataService] Resolved relative URL: \(string) → \(urlString)")
        } else if !urlString.contains("://") {
            // 无协议的相对路径: uploads/... → https://www.sxjzit.edu.cn/uploads/...
            urlString = SchoolInfo.website + "/" + urlString
            print("[DataService] Resolved relative URL (no scheme): \(string) → \(urlString)")
        }

        // 先尝试直接用 URL(string:) 解析，如果成功则无需编码
        if URL(string: urlString) != nil {
            return urlString
        }
        print("[DataService] URL needs encoding: \(urlString)")
        // 组合所有 URL 组件允许的字符集，确保 URL 结构字符不被编码
        var allowed = CharacterSet.urlPathAllowed
        allowed.formUnion(.urlHostAllowed)
        allowed.formUnion(.urlQueryAllowed)
        allowed.formUnion(.urlFragmentAllowed)
        allowed.insert(charactersIn: "%")
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return urlString
        }
        print("[DataService] Encoded URL: \(encoded)")
        return encoded
    }

    // MARK: - 缓存操作

    private func cacheURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func saveCache() {
        save(news, for: "news")
        save(honors, for: "honors")
        save(departments, for: "departments")
        save(banners, for: "banners")
        save(bottomBanners, for: "bottom_banners")
        save(videos, for: "videos")
        save(studentStories, for: "student_stories")
        save(teacherProfiles, for: "teacher_profiles")
        save(campusSceneries, for: "campus_sceneries")
        save(campusActivities, for: "campus_activities")
        save(footerLinks, for: "footer_links")
        save(socialPlatforms, for: "social_platforms")
        save(recruitPhones, for: "recruit_phones")
        save(importantNews, for: "important_news")
        save(updateNews, for: "update_news")
        save(partyNews, for: "party_news")
        save(notices, for: "notices")
        save(admissionNews, for: "admission_news")
        save(campusNews, for: "campus_news")
        save(researchReports, for: "research_reports")
        save(informationNews, for: "information_news")
        LogManager.shared.debugLog("cache", "离线缓存写入完成", context: [
            "news": "\(news.count)", "honors": "\(honors.count)", "departments": "\(departments.count)"
        ])
    }

    private func save<T: Encodable>(_ value: T, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: cacheURL(key), options: .atomic)
    }

    @discardableResult
    private func loadCache() -> Bool {
        var loaded = false
        if let n: [NewsItem] = read("news"), !n.isEmpty { news = n; loaded = true }
        if let h: [Honor] = read("honors"), !h.isEmpty { honors = h; loaded = true }
        if let d: [Department] = read("departments"), !d.isEmpty { departments = d; loaded = true }
        if let b: [Banner] = read("banners"), !b.isEmpty { banners = b }
        if let bb: [Banner] = read("bottom_banners"), !bb.isEmpty { bottomBanners = bb }
        if let v: [CampusVideo] = read("videos"), !v.isEmpty { videos = v }
        if let s: [StudentStory] = read("student_stories"), !s.isEmpty { studentStories = s }
        if let tp: [TeacherProfile] = read("teacher_profiles"), !tp.isEmpty { teacherProfiles = tp }
        if let cs: [CampusScenery] = read("campus_sceneries"), !cs.isEmpty { campusSceneries = cs }
        if let ca: [CampusActivity] = read("campus_activities"), !ca.isEmpty { campusActivities = ca }
        if let fl: [FooterLink] = read("footer_links"), !fl.isEmpty { footerLinks = fl }
        if let sp: [SocialPlatform] = read("social_platforms"), !sp.isEmpty { socialPlatforms = sp }
        if let rp: [String] = read("recruit_phones"), !rp.isEmpty { recruitPhones = rp }
        if let im: [NewsItem] = read("important_news"), !im.isEmpty { importantNews = im }
        if let un: [NewsItem] = read("update_news"), !un.isEmpty { updateNews = un }
        if let pn: [NewsItem] = read("party_news"), !pn.isEmpty { partyNews = pn }
        if let nt: [NewsItem] = read("notices"), !nt.isEmpty { notices = nt }
        if let an: [NewsItem] = read("admission_news"), !an.isEmpty { admissionNews = an }
        if let cn: [NewsItem] = read("campus_news"), !cn.isEmpty { campusNews = cn }
        if let rr: [NewsItem] = read("research_reports"), !rr.isEmpty { researchReports = rr }
        if let inf: [NewsItem] = read("information_news"), !inf.isEmpty { informationNews = inf }
        if loaded {
            LogManager.shared.info("cache", "离线缓存加载成功", context: [
                "news": "\(news.count)", "honors": "\(honors.count)", "departments": "\(departments.count)"
            ])
        }
        return loaded
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        let url = cacheURL(key)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func clearCache() {
        let keys = ["news", "honors", "departments", "banners", "bottom_banners", "videos",
                    "student_stories", "teacher_profiles", "campus_sceneries", "campus_activities",
                    "footer_links", "social_platforms", "recruit_phones",
                    "important_news", "update_news", "party_news", "notices",
                    "admission_news", "campus_news", "research_reports", "information_news",
                    "zsw_home"]
        for key in keys {
            try? fileManager.removeItem(at: cacheURL(key))
        }
        news = defaultNews
        honors = defaultHonors
        departments = defaultDepartments
        banners = []
        bottomBanners = []
        videos = []
        studentStories = []
        teacherProfiles = []
        campusSceneries = []
        campusActivities = []
        importantNews = []
        updateNews = []
        partyNews = []
        notices = []
        admissionNews = []
        campusNews = []
        researchReports = []
        informationNews = []
        footerLinks = []
        socialPlatforms = []
        recruitPhones = []
        zswHomeData = nil
        dataSource = "预置数据"
        lastError = nil
        syncErrors = []
        LogManager.shared.info("cache", "离线缓存已清空，恢复预置数据")
    }

    // MARK: - 招生网缓存

    private func saveZSWCache(_ data: ZSWHomeData) {
        save(data, for: "zsw_home")
    }

    private func loadZSWCache() {
        if let cached: ZSWHomeData = read("zsw_home") {
            zswHomeData = cached
        }
    }

    // MARK: - 专业介绍缓存

    private func saveSpecialtyCache(_ data: SpecialtyData) {
        save(data, for: "specialty")
    }

    private func loadSpecialtyCache() {
        if let cached: SpecialtyData = read("specialty") {
            specialtyData = cached
        }
    }

    // MARK: - 计算属性

    var allNewsCategories: [(String, [NewsItem])] {
        var result: [(String, [NewsItem])] = []
        if !importantNews.isEmpty { result.append(("学校要闻", importantNews)) }
        if !updateNews.isEmpty { result.append(("新闻资讯", updateNews)) }
        if !partyNews.isEmpty { result.append(("党建动态", partyNews)) }
        if !notices.isEmpty { result.append(("通知公告", notices)) }
        if !admissionNews.isEmpty { result.append(("招生信息", admissionNews)) }
        return result
    }

    /// 合并所有分类的新闻
    var allNews: [NewsItem] {
        var combined: [NewsItem] = []
        combined += importantNews
        combined += updateNews
        combined += partyNews
        combined += notices
        combined += admissionNews
        combined += campusNews
        combined += researchReports
        combined += informationNews
        return combined
    }

    // MARK: - 工具方法

    private func formatDate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd"
            let f4 = DateFormatter(); f4.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return [f1, f2, f4]
        }()
        for fmt in formatters {
            if let date = fmt.date(from: raw) {
                let out = DateFormatter()
                out.dateFormat = "yyyy.MM.dd"
                return out.string(from: date)
            }
        }
        if let date = ISO8601DateFormatter().date(from: raw) {
            let out = DateFormatter(); out.dateFormat = "yyyy.MM.dd"
            return out.string(from: date)
        }
        return String(raw.prefix(10))
    }

    /// 模糊匹配 API 院系名称到预置数据
    private func findMatchingDefaultDept(for apiName: String) -> Department? {
        let trimmedApi = apiName.trimmingCharacters(in: .whitespaces)
        // 1. 精确匹配（忽略首尾空格）
        if let match = defaultDepartments.first(where: { $0.name.trimmingCharacters(in: .whitespaces) == trimmedApi }) {
            return match
        }
        // 2. 包含匹配（API 名称包含默认名称，或默认名称包含 API 名称）
        if let match = defaultDepartments.first(where: { $0.name.contains(trimmedApi) || trimmedApi.contains($0.name) }) {
            return match
        }
        return nil
    }

    private func extractDepartments(from menus: [NetworkService.MenuDTO]) -> [Department] {
        guard let parent = menus.first(where: {
            ($0.titleCn ?? "").contains("教学") || ($0.titleEn ?? "") == "academics"
        }), let children = parent.children, !children.isEmpty else {
            return []
        }
        return children.compactMap { menu -> Department? in
            guard let name = menu.titleCn, !name.isEmpty else { return nil }
            let en = menu.titleEn ?? ""
            let icon = pickIcon(for: name)
            let siteKey = extractSiteKey(from: menu.path)
            return Department(name: name, englishName: en, icon: icon, intro: "", siteKey: siteKey)
        }
    }

    private func extractSiteKey(from path: String?) -> String? {
        guard let path, let range = path.range(of: "site_key=") else { return nil }
        let key = String(path[range.upperBound...])
        if let ampRange = key.range(of: "&") {
            return String(key[..<ampRange.lowerBound])
        }
        return key
    }

    private func pickIcon(for name: String) -> String {
        if name.contains("智能") || name.contains("机械") || name.contains("车辆") { return "gearshape.2.fill" }
        if name.contains("信创") || name.contains("大数据") || name.contains("计算机") || name.contains("软件") { return "cpu.fill" }
        if name.contains("材料") || name.contains("环境") { return "leaf.fill" }
        if name.contains("商") || name.contains("经济") || name.contains("管理") { return "chart.bar.fill" }
        if name.contains("艺术") || name.contains("音乐") || name.contains("设计") { return "music.note" }
        if name.contains("文法") { return "text.book.closed.fill" }
        if name.contains("马克思") || name.contains("思政") { return "book.fill" }
        if name.contains("通识") { return "globe" }
        if name.contains("国际") || name.contains("交流") { return "airplane" }
        if name.contains("创新") || name.contains("创业") { return "lightbulb.fill" }
        if name.contains("教务") { return "pencil.and.list.clipboard" }
        return "building.2.fill"
    }
}