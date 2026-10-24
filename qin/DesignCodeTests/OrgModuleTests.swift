//
//  OrgModuleTests.swift
//  DesignCodeTests
//
//  机构设置模块（升级 · 阶段一）纯逻辑单测：
//  栏目索引构建 / 栏目类型分派 / 分页状态机 / 请求并发闸 / 工具入口路由
//
//  样本来源：2026-09-30 官网实测（jwc 教务处 nav 结构，见 departments-api-evidence/raw/home2_jwc.json）
//

import XCTest
@testable import DesignCode

final class OrgModuleTests: XCTestCase {

    // MARK: - 样本

    /// jwc 教务处的 nav 结构（实测裁剪：首页聚合 + content 型栏目 + 通知公告 + 非列表栏目）
    private static let jwcNavJSON = """
    [
      {"column_id":"e754bb10580140d5bedf530b7db5518e","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"首页","componentType":"","children":[],
       "data":{
         "news":{"column_id":"1e5c01825020441191c57a1d2ee4a06d","title_cn":"教务动态","componentType":"news",
                 "articles":{"total":245,"list":[]}},
         "notice":{"column_id":"94511e8fcb8c49b4a1ade5d2fda8a03b","title_cn":"通知公告","componentType":"notice",
                   "articles":{"total":378,"list":[]}},
         "regulations":{"column_id":"4f0ffb3878b64411ba559295b411cf1c","title_cn":"规章制度","componentType":"notice-small",
                        "articles":{"total":12,"list":[]}},
         "calendar":{"column_id":"d0fb6bbd281144eebd8f817bb38c12b0","title_cn":"校园日历","componentType":"calendar",
                     "events":{"schedule":[]}}
       }},
      {"column_id":"56452645823242098c7c1a8f6773c691","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"部门概况","componentType":"content","children":[],
       "data":{"column_id":"56452645823242098c7c1a8f6773c691","title_cn":"部门概况","componentType":"content","children":[]}},
      {"column_id":"1e5c01825020441191c57a1d2ee4a06d","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"教务动态","componentType":"news","children":[]},
      {"column_id":"94511e8fcb8c49b4a1ade5d2fda8a03b","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"通知公告","componentType":"notice","children":[]},
      {"column_id":"4f0ffb3878b64411ba559295b411cf1c","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"规章制度","componentType":"notice-small","children":[]},
      {"column_id":"a1b2c3d4000000000000000000000001","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"资料下载","componentType":"download","children":[]},
      {"column_id":"a1b2c3d4000000000000000000000002","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"联系我们","componentType":"opinion","children":[]},
      {"column_id":"a1b2c3d4000000000000000000000003","site_id":"222fa53591a3494e9c860390039b0844",
       "title_cn":"招生就业处入口","componentType":"tabs","children":[
         {"column_id":"a1b2c3d4000000000000000000000010","title_cn":"专业介绍","componentType":"tabs"},
         {"column_id":"a1b2c3d4000000000000000000000011","title_cn":"历年分数线","componentType":"link"},
         {"column_id":"a1b2c3d4000000000000000000000012","title_cn":"学院简介","componentType":"content"}
       ]}
    ]
    """

    private func decodeNav() throws -> [NetworkService.DeptNavItemDTO] {
        let data = Self.jwcNavJSON.data(using: .utf8)!
        return try JSONDecoder().decode([NetworkService.DeptNavItemDTO].self, from: data)
    }

    private func makeArticle(_ id: String, title: String = "标题") -> OrgArticle {
        OrgArticle(id: id, title: title, description: "", imageUrl: nil, updateTime: "2026-09-30",
                   tag: "", articleId: id, sectionSiteId: "s1")
    }

    // MARK: - 栏目类型分派

    func testClassifyComponentTypes() {
        for listType in ["news", "news-important", "notice", "notice-small", "content",
                         "download", "tabs", "tabs-sub", "teacher", "videos",
                         "electronic-book", "thematic-center", "recruit"] {
            XCTAssertEqual(OrgColumnKind.classify(listType), .list, "\(listType) 应为列表类")
        }
        XCTAssertEqual(OrgColumnKind.classify("calendar"), .calendar)
        for fallback in ["link", "opinion", "0", "", nil] {
            XCTAssertEqual(OrgColumnKind.classify(fallback), .webFallback, "\(fallback ?? "nil") 应为官网兜底")
        }
    }

    // MARK: - 栏目索引构建

    func testBuildColumnIndexExcludesAggregateAndSeedsTotals() throws {
        let nav = try decodeNav()
        let result = OrgColumnIndexBuilder.build(nav: nav, defaultSiteId: "fallback")

        let titles = result.columns.map(\.title)
        XCTAssertFalse(titles.contains("首页"), "首页为聚合项，不应下发为栏目")
        XCTAssertTrue(titles.contains("部门概况"))
        XCTAssertTrue(titles.contains("通知公告"))
        XCTAssertTrue(titles.contains("资料下载"))
        XCTAssertTrue(titles.contains("联系我们"))
        XCTAssertTrue(titles.contains("学院简介"), "子导航项应并入栏目")

        // total 种子（来自首页嵌套区块）
        XCTAssertEqual(result.seedTotals["1e5c01825020441191c57a1d2ee4a06d"], 245)
        XCTAssertEqual(result.seedTotals["94511e8fcb8c49b4a1ade5d2fda8a03b"], 378)
        XCTAssertEqual(result.seedTotals["4f0ffb3878b64411ba559295b411cf1c"], 12)

        // 去重：首页嵌套的通知公告与 nav 顶层通知公告同 columnId，只保留一条
        let noticeCount = result.columns.filter { $0.columnId == "94511e8fcb8c49b4a1ade5d2fda8a03b" }.count
        XCTAssertEqual(noticeCount, 1)

        // 工具入口单独收集，不进入栏目
        XCTAssertEqual(result.toolChildren.map(\.title), ["专业介绍", "历年分数线"])
        XCTAssertFalse(titles.contains("专业介绍"))
        XCTAssertFalse(titles.contains("历年分数线"))
    }

    func testBuildColumnIndexKindsAndSiteIdFallback() throws {
        let nav = try decodeNav()
        let result = OrgColumnIndexBuilder.build(nav: nav, defaultSiteId: "fallback")

        let byTitle = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["部门概况"]?.kind, .list)
        XCTAssertEqual(byTitle["联系我们"]?.kind, .webFallback)
        XCTAssertEqual(byTitle["通知公告"]?.siteId, "222fa53591a3494e9c860390039b0844")
    }

    func testDefaultColumnPrefersSeededListColumn() throws {
        let nav = try decodeNav()
        let result = OrgColumnIndexBuilder.build(nav: nav, defaultSiteId: "fallback")

        let defaultColumn = OrgColumnIndexBuilder.defaultColumn(in: result.columns, seedTotals: result.seedTotals)
        XCTAssertEqual(defaultColumn?.title, "教务动态", "默认应为「首个有 total 种子且为列表类」的栏目（nav 顺序：部门概况无种子 → 教务动态 245）")
    }

    func testToolTitleRouting() {
        XCTAssertTrue(OrgColumnIndexBuilder.isToolTitle("专业介绍"))
        XCTAssertTrue(OrgColumnIndexBuilder.isToolTitle("历年分数线查询"))
        XCTAssertTrue(OrgColumnIndexBuilder.isToolTitle("录取查询"))
        XCTAssertFalse(OrgColumnIndexBuilder.isToolTitle("学院简介"))
    }

    // MARK: - 分页状态机

    func testPagerAppendDedupeAndProgress() {
        var state = OrgPagerState()
        state.seedTotal(653)

        state.beginLoad(reset: true)
        let page1 = (1...40).map { makeArticle("a\($0)") }
        let added1 = state.apply(page: 1, list: page1, total: 653)

        XCTAssertEqual(added1, 40)
        XCTAssertEqual(state.displayedCount, 40)
        XCTAssertEqual(state.progressText, "已显示 40 / 653")
        XCTAssertTrue(state.hasMore)
        XCTAssertEqual(state.nextPage, 2)
        XCTAssertFalse(state.isExhausted)

        // 第二页含 5 条重复
        state.beginLoad(reset: false)
        let page2 = (36...75).map { makeArticle("a\($0)") }
        let added2 = state.apply(page: 2, list: page2, total: 653)

        XCTAssertEqual(added2, 35, "重复 articleId 必须去重")
        XCTAssertEqual(state.displayedCount, 75)
        XCTAssertEqual(state.nextPage, 3)
    }

    func testPagerExhaustionDetectedWithTotal() {
        var state = OrgPagerState()
        state.beginLoad(reset: true)
        state.apply(page: 1, list: [makeArticle("x1"), makeArticle("x2")], total: 2)

        XCTAssertFalse(state.hasMore, "已显示数 == total 时无更多")
        XCTAssertTrue(state.isExhausted)
    }

    func testPagerHasMoreWhenTotalUnknown() {
        var state = OrgPagerState()
        state.beginLoad(reset: true)
        state.apply(page: 1, list: (1...40).map { makeArticle("b\($0)") }, total: nil)
        XCTAssertTrue(state.hasMore, "total 未知且满页 → 推断还有更多")

        state.beginLoad(reset: false)
        state.apply(page: 2, list: (41...47).map { makeArticle("b\($0)") }, total: nil)
        XCTAssertFalse(state.hasMore, "total 未知且未满页 → 视为到底")
        XCTAssertFalse(state.isExhausted, "total 未知时不做 exhausted 判定")
    }

    func testPagerFailClearsLoadingAndKeepsArticles() {
        var state = OrgPagerState()
        state.beginLoad(reset: true)
        state.apply(page: 1, list: [makeArticle("c1")], total: 10)
        state.beginLoad(reset: false)
        state.fail("网络较慢，加载超时")

        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertEqual(state.errorText, "网络较慢，加载超时")
        XCTAssertEqual(state.displayedCount, 1, "失败不清空已加载内容")
    }

    // MARK: - 请求并发闸

    func testRequestGateCapsConcurrencyAtThree() async {
        let gate = OrgRequestGate(maxConcurrent: 3)
        let counter = OrgConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<9 {
                group.addTask {
                    await gate.withPermit {
                        await counter.enter()
                        try? await Task.sleep(nanoseconds: 15_000_000)
                        await counter.exit()
                    }
                }
            }
        }

        let peak = await counter.peak
        let current = await counter.current
        XCTAssertLessThanOrEqual(peak, 3, "并发上限必须 ≤3")
        XCTAssertEqual(current, 0, "全部完成后活跃数必须归零")
    }

    // MARK: - 正文图片查看桥（阶段三 A）

    func testGalleryPayloadRemapsTappedIndexAfterFilteringInvalidURLs() throws {
        let urls = [
            "https://a.example.com/1.jpg",
            "",                                  // 空串跳过
            "https://a.example.com/3.jpg",
            "not-a-url",                         // 非 http(s) 跳过
            "https://a.example.com/5.jpg"
        ]
        let alts = ["一", "二", "三", "四", "五"]

        let payload = try XCTUnwrap(OrgGalleryPayloadBuilder.make(index: 2, urls: urls, alts: alts))

        XCTAssertEqual(payload.count, 3, "非法 URL 必须被跳过")
        XCTAssertEqual(payload.clampedStartIndex, 1, "被点第 3 项（原始 index=2）应重映射到过滤后的第 2 项")
        XCTAssertEqual(payload.urls[1].absoluteString, "https://a.example.com/3.jpg")
        XCTAssertEqual(payload.alts[1], "三", "alt 必须与被点图同序透传")
        XCTAssertEqual(payload.source, "organization_detail")
    }

    func testGalleryPayloadRejectsEmptyOrNonHTTPInput() {
        XCTAssertNil(OrgGalleryPayloadBuilder.make(index: 0, urls: [], alts: []), "空图集必须返回 nil")
        XCTAssertNil(OrgGalleryPayloadBuilder.make(index: 0, urls: ["", "   "], alts: []), "全非法图集必须返回 nil")
        XCTAssertNil(OrgGalleryPayloadBuilder.make(index: 0, urls: ["file:///tmp/a.png"], alts: []),
                     "非 http(s) 协议（file://）必须被拒绝")
    }

    func testGalleryPayloadAltShortageFallsBackToEmptyString() throws {
        let payload = try XCTUnwrap(OrgGalleryPayloadBuilder.make(
            index: 1,
            urls: ["https://a.example.com/1.jpg", "https://a.example.com/2.jpg"],
            alts: ["唯一 alt"]
        ))
        XCTAssertEqual(payload.alts.count, payload.count, "alts 必须与 urls 等长")
        XCTAssertEqual(payload.alts[0], "唯一 alt")
        XCTAssertEqual(payload.alts[1], "", "alt 缺位补空串（VoiceOver 安全）")
    }

    func testGalleryPayloadOutOfRangeIndexFallsBackToFirst() throws {
        let payload = try XCTUnwrap(OrgGalleryPayloadBuilder.make(
            index: 99,
            urls: ["https://a.example.com/1.jpg"],
            alts: []
        ))
        XCTAssertEqual(payload.clampedStartIndex, 0, "越界索引安全回落首张（clampedStartIndex 防护）")
    }

    // MARK: - 正文视频探针（阶段三 A）

    func testVideoSourceCountMatchesVideoAndSourceTags() {
        let html = """
        <p>正文</p>
        <video src="https://a.example.com/v1.mp4" controls></video>
        <video poster="p.jpg"><source src="https://a.example.com/v2.mp4"></video>
        <audio><source src="https://a.example.com/a.mp3"></audio>
        <img src="https://a.example.com/1.jpg">
        """
        XCTAssertEqual(OrgMediaProbe.videoSourceCount(in: html), 3,
                       "video[src] 2 处 + source[src] 2 处（含 audio 内）——探针只做数量取证")
    }

    func testVideoSourceCountZeroForPlainArticle() {
        XCTAssertEqual(OrgMediaProbe.videoSourceCount(in: "<p>纯文字 <img src=\"a.jpg\"></p>"), 0)
    }

    // MARK: - 关注清单（阶段三 C）

    func testFollowedOrgEncodeDecodeRoundTrip() throws {
        let orgs = [
            FollowedOrg(siteKey: "jwc", name: "教务处",
                        categoryRaw: OrganizationCategory.administrative.rawValue, siteId: "12"),
            FollowedOrg(siteKey: "tw", name: "团委",
                        categoryRaw: OrganizationCategory.massOrg.rawValue, siteId: "1")
        ]
        let raw = try XCTUnwrap(OrgFollowStore.encode(orgs))
        let decoded = OrgFollowStore.decode(raw)
        XCTAssertEqual(decoded, orgs, "编解码必须无损往返")
        XCTAssertEqual(decoded[0].category, .administrative, "分类回解必须命中 OrganizationCategory")
    }

    func testFollowedOrgDecodeToleratesGarbage() {
        XCTAssertEqual(OrgFollowStore.decode(nil), [], "无数据 → 空清单")
        XCTAssertEqual(OrgFollowStore.decode("not json"), [], "损坏数据 → 空清单（不拖垮模块）")
        XCTAssertEqual(OrgFollowStore.decode("[{\"siteKey\":\"a\"}]"), [], "字段缺失 → 空清单")
    }

    @MainActor
    func testFollowStoreToggleAndPersistence() throws {
        let suiteName = "org-follow-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OrgFollowStore(defaults: defaults)
        let org = FollowedOrg(siteKey: "sxy", name: "商学院",
                              categoryRaw: OrganizationCategory.teaching.rawValue, siteId: "9")

        XCTAssertFalse(store.isFollowing(siteKey: "sxy"))
        XCTAssertTrue(store.toggle(org), "首次切换 = 关注")
        XCTAssertTrue(store.isFollowing(siteKey: "sxy"))
        XCTAssertEqual(store.count, 1)

        // 同一 defaults 新建实例 → 关注清单必须恢复（持久化闭环）
        let reloaded = OrgFollowStore(defaults: defaults)
        XCTAssertEqual(reloaded.followed, [org])

        XCTAssertFalse(store.toggle(org), "再次切换 = 取关")
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(OrgFollowStore(defaults: defaults).isFollowing(siteKey: "sxy"),
                       "取关同样必须落盘")
    }

    // MARK: - 机构动态扫描（阶段三 C：第五通道数据源）

    func testFollowScannerSortsByTimeDescending() throws {
        let json = """
        {"nav":[{"title_cn":"首页","data":{"hero":{"articles":{"total":2,"list":[
            {"id":"a1","title":"旧文","update_time":"2026-09-01 10:00:00"},
            {"id":"a2","title":"新文","update_time":"2026-09-30 09:00:00"}]},
            "children":{"list":[{"id":"c1","title_cn":"子栏目","articles":{"list":[
            {"id":"a3","title":"子文","update_time":"2026-09-20 08:00:00"}]}}]}}}}]}
        """
        let data = try JSONDecoder().decode(NetworkService.DeptHome2DTO.self, from: Data(json.utf8))
        let candidates = OrgFollowArticleScanner.candidates(from: data)
        XCTAssertEqual(candidates.map(\.articleId), ["a2", "a3", "a1"], "必须按 update_time 降序")
        XCTAssertEqual(candidates.first?.title, "新文", "标题必须随行透传")
    }

    func testFollowScannerDedupesAndLimits() throws {
        let json = """
        {"nav":[
          {"title_cn":"首页","data":{"a":{"articles":{"list":[
            {"id":"dup","title":"重复","update_time":"2026-09-30 09:00:00"},
            {"id":"x2","title":"第二","update_time":"2026-09-29 09:00:00"}]}}}},
          {"title_cn":"新闻","articles":{"list":[
            {"id":"dup","title":"重复副本","update_time":"2026-09-30 09:00:00"},
            {"id":"x3","title":"第三","update_time":"2026-09-28 09:00:00"}]}}
        ]}
        """
        let data = try JSONDecoder().decode(NetworkService.DeptHome2DTO.self, from: Data(json.utf8))
        let all = OrgFollowArticleScanner.candidates(from: data)
        XCTAssertEqual(all.map(\.articleId), ["dup", "x2", "x3"], "跨区块重复 id 必须去重且保序")

        let limited = OrgFollowArticleScanner.candidates(from: data, limit: 2)
        XCTAssertEqual(limited.map(\.articleId), ["dup", "x2"], "上限必须生效")
    }

    func testFollowScannerEmptyNavYieldsNoCandidates() throws {
        let data = try JSONDecoder().decode(NetworkService.DeptHome2DTO.self, from: Data("{}".utf8))
        XCTAssertTrue(OrgFollowArticleScanner.candidates(from: data).isEmpty, "空响应不得产出候补")
    }
}

// MARK: - 并发计数辅助

private actor OrgConcurrencyCounter {
    private(set) var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
    }
}