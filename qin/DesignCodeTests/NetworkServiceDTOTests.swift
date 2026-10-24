//
//  NetworkServiceDTOTests.swift
//  DesignCodeTests
//
//  测试 API DTO 解码逻辑，防止接口结构变化导致崩溃
//

import XCTest
@testable import DesignCode

final class NetworkServiceDTOTests: XCTestCase {

    let decoder = JSONDecoder()

    // MARK: - Home2DTO 完整解码测试

    func testHome2DTODecodesFromRealAPI() throws {
        // 从真实 API 获取的数据（已验证过的结构）
        let json = """
        {
            "code": 200,
            "message": "ok",
            "data": {
                "top_banners": [
                    {"videoSrc": "banner1.mp4", "posterImgSrc": "poster1", "videoTitleImgSrc": "title1"}
                ],
                "bottom_banners": {
                    "total": 4,
                    "list": [
                        {"id": "1", "title": "test", "description": "desc", "image_url": "img.jpg", "create_time": "2026-01-01", "update_time": "2026-01-01T00:00:00", "tag": "", "sort": 0}
                    ]
                },
                "achievements": {
                    "column_id": "ach_id",
                    "title_cn": "校园荣誉",
                    "title_en": "achievements",
                    "href": "",
                    "articles": {"total": 35, "list": []}
                },
                "news": {
                    "column_id": "news_id",
                    "title_cn": "新闻公告",
                    "title_en": "news",
                    "is_out": 1,
                    "href": "/",
                    "children": {
                        "importants": {
                            "column_id": "imp_id",
                            "title_cn": "学校要闻",
                            "title_en": "importants",
                            "href": "/",
                            "articles": {"total": 516, "list": []}
                        },
                        "updates": {
                            "column_id": "upd_id",
                            "title_cn": "新闻资讯",
                            "title_en": "updates",
                            "href": "/",
                            "articles": {"total": 107, "list": []}
                        },
                        "notices": {
                            "column_id": "not_id",
                            "title_cn": "通知公告",
                            "title_en": "notices",
                            "href": "/",
                            "articles": {"total": 155, "list": []}
                        },
                        "informations": {
                            "column_id": "info_id",
                            "title_cn": "信息公告",
                            "title_en": "informations",
                            "href": "/",
                            "articles": {"total": 4, "list": []}
                        },
                        "resports": {
                            "column_id": "rep_id",
                            "title_cn": "科研报告",
                            "title_en": "resports",
                            "href": "/",
                            "articles": {"total": 69, "list": []}
                        }
                    }
                },
                "video": {
                    "dynamicDigit": [{"key": "value"}, {"num": 42}],
                    "videoSrc": "video.mp4"
                },
                "teachers": {
                    "column_id": "tea_id",
                    "title_cn": "教师风采",
                    "title_en": "teachers",
                    "href": "",
                    "articles": {"total": 8, "list": []}
                },
                "videos": {
                    "column_id": "vid_id",
                    "title_cn": "映像校园",
                    "title_en": "videos",
                    "href": "",
                    "articles": {"total": 7, "list": []}
                },
                "students": {
                    "column_id": "stu_id",
                    "title_cn": "学生故事",
                    "title_en": "students",
                    "href": "",
                    "articles": {"total": 28, "list": []}
                },
                "campus": {
                    "column_id": "cam_id",
                    "title_cn": "映像校园",
                    "title_en": "campus",
                    "href": "",
                    "children": {
                        "activites": {
                            "column_id": "act_id",
                            "title_cn": "校园活动",
                            "title_en": "activites",
                            "href": "/",
                            "articles": {"total": 4, "list": []}
                        },
                        "calendar": {
                            "column_id": "cal_id",
                            "title_cn": "校历",
                            "title_en": "calendar",
                            "href": "/"
                        }
                    }
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let response = try decoder.decode(NetworkService.APIResponse<NetworkService.Home2DTO>.self, from: data)

        // 验证基础字段
        XCTAssertEqual(response.code, 200)
        XCTAssertNotNil(response.data)

        let home2 = response.data!

        // 验证 topBanners
        XCTAssertEqual(home2.topBanners?.count, 1)
        XCTAssertEqual(home2.topBanners?.first?.videoSrc, "banner1.mp4")

        // 验证 bottomBanners（是 ArticleListDTO 不是数组）
        XCTAssertEqual(home2.bottomBanners?.total, 4)
        XCTAssertEqual(home2.bottomBanners?.list?.count, 1)

        // 验证 achievements
        XCTAssertEqual(home2.achievements?.columnId, "ach_id")

        // 验证 news 及其 5 个子栏目
        XCTAssertEqual(home2.news?.columnId, "news_id")
        XCTAssertEqual(home2.news?.children?.importants?.columnId, "imp_id")
        XCTAssertEqual(home2.news?.children?.updates?.columnId, "upd_id")
        XCTAssertEqual(home2.news?.children?.notices?.columnId, "not_id")
        XCTAssertEqual(home2.news?.children?.informations?.columnId, "info_id")
        XCTAssertEqual(home2.news?.children?.resports?.columnId, "rep_id")

        // 验证 articles total
        XCTAssertEqual(home2.news?.children?.importants?.articles?.total, 516)
        XCTAssertEqual(home2.news?.children?.notices?.articles?.total, 155)

        // 验证 video（复杂结构，AnyCodable）
        XCTAssertNotNil(home2.video)
        XCTAssertEqual(home2.video?.videoSrc, "video.mp4")

        // 验证 campus（CampusBlockDTO）
        XCTAssertEqual(home2.campus?.columnId, "cam_id")
        XCTAssertEqual(home2.campus?.children?.activites?.columnId, "act_id")
        XCTAssertEqual(home2.campus?.children?.calendar?.columnId, "cal_id")

        // 验证 videos, students, teachers
        XCTAssertEqual(home2.videos?.columnId, "vid_id")
        XCTAssertEqual(home2.students?.columnId, "stu_id")
        XCTAssertEqual(home2.teachers?.columnId, "tea_id")
    }

    // MARK: - BannerDTO 测试

    func testBannerDTODecodesWithMissingFields() throws {
        // Banner 字段可能为空，应该不崩溃
        let json = """
        [
            {"videoSrc": "v.mp4", "posterImgSrc": null, "videoTitleImgSrc": null},
            {"videoSrc": null, "posterImgSrc": "p.jpg", "videoTitleImgSrc": "t.jpg"},
            {}
        ]
        """.data(using: .utf8)!

        let banners = try decoder.decode([NetworkService.BannerDTO].self, from: json)
        XCTAssertEqual(banners.count, 3)
        XCTAssertEqual(banners[0].videoSrc, "v.mp4")
        XCTAssertNil(banners[0].posterImgSrc)
        XCTAssertNil(banners[1].videoSrc)
        XCTAssertEqual(banners[1].posterImgSrc, "p.jpg")
        XCTAssertNil(banners[2].videoSrc)
    }

    // MARK: - ArticleDTO 测试

    func testArticleDTODecodesWithOldAndNewFormat() throws {
        // 新旧数据格式不同，应该都能解码
        let json = """
        [
            {
                "id": "744c0428-uuid-format",
                "title": "新格式文章",
                "description": "描述",
                "image_url": "https://example.com/img.jpg",
                "create_time": "2026-07-30 23:08:40",
                "update_time": "2026-07-30T00:00:00",
                "tag": "",
                "sort": 0,
                "href": ""
            },
            {
                "id": "4950",
                "title": "旧格式文章",
                "description": "描述",
                "image_url": "https://example.com/old.jpg",
                "create_time": "",
                "update_time": "2024-11-01T00:00:00",
                "tag": "tag",
                "sort": 10000,
                "href": ""
            }
        ]
        """.data(using: .utf8)!

        let articles = try decoder.decode([NetworkService.ArticleDTO].self, from: json)
        XCTAssertEqual(articles.count, 2)

        // 新格式
        XCTAssertEqual(articles[0].id, "744c0428-uuid-format")
        XCTAssertEqual(articles[0].sort, 0)

        // 旧格式
        XCTAssertEqual(articles[1].id, "4950")
        XCTAssertEqual(articles[1].sort, 10000)
        XCTAssertEqual(articles[1].tag, "tag")
    }

    // MARK: - ColumnDTO 测试

    func testColumnDTODecodesWithChildren() throws {
        let json = """
        {
            "column_id": "parent_id",
            "title_cn": "父栏目",
            "title_en": "parent",
            "href": "/",
            "children": {
                "child1": {"column_id": "c1", "title_cn": "子栏目1", "title_en": "child1", "href": "/"},
                "child2": {"column_id": "c2", "title_cn": "子栏目2", "title_en": "child2", "href": "/", "articles": {"total": 10, "list": []}}
            }
        }
        """.data(using: .utf8)!

        let column = try decoder.decode(NetworkService.ColumnDTO.self, from: json)
        XCTAssertEqual(column.columnId, "parent_id")
        XCTAssertEqual(column.children?.count, 2)
        XCTAssertEqual(column.children?["child1"]?.columnId, "c1")
        XCTAssertEqual(column.children?["child2"]?.articles?.total, 10)
    }

    // MARK: - CampusBlockDTO 测试

    func testCampusBlockDTODecodesWithActivites() throws {
        let json = """
        {
            "column_id": "cam_id",
            "title_cn": "映像校园",
            "title_en": "campus",
            "href": "",
            "children": {
                "activites": {
                    "column_id": "act_id",
                    "title_cn": "校园活动",
                    "title_en": "activites",
                    "href": "/",
                    "articles": {"total": 4, "list": [
                        {"id": "1", "title": "活动1", "description": "desc", "image_url": "img.jpg", "create_time": "2026-01-01", "update_time": "2026-01-01T00:00:00", "tag": "tag1", "sort": 0}
                    ]}
                },
                "calendar": {
                    "column_id": "cal_id",
                    "title_cn": "校历",
                    "title_en": "calendar",
                    "href": "/"
                }
            }
        }
        """.data(using: .utf8)!

        let campus = try decoder.decode(NetworkService.CampusBlockDTO.self, from: json)
        XCTAssertEqual(campus.columnId, "cam_id")
        XCTAssertEqual(campus.children?.activites?.columnId, "act_id")
        XCTAssertEqual(campus.children?.activites?.articles?.total, 4)
        XCTAssertEqual(campus.children?.activites?.articles?.list?.count, 1)
        XCTAssertEqual(campus.children?.calendar?.columnId, "cal_id")
    }

    // MARK: - VideoBlockDTO 测试

    func testVideoBlockDTODecodesWithComplexDynamicDigit() throws {
        // dynamicDigit 是复杂嵌套结构，不应导致解码失败
        let json = """
        {
            "dynamicDigit": [
                {"name": "item1", "value": 100},
                {"name": "item2", "nested": {"key": "val"}},
                {"name": "item3", "arr": [1, 2, 3]}
            ],
            "videoSrc": "video.mp4"
        }
        """.data(using: .utf8)!

        let video = try decoder.decode(NetworkService.VideoBlockDTO.self, from: json)
        XCTAssertEqual(video.videoSrc, "video.mp4")
        XCTAssertNotNil(video.dynamicDigit)
        XCTAssertEqual(video.dynamicDigit?.count, 3)
    }

    // MARK: - AnyCodable 测试

    func testAnyCodableHandlesAllTypes() throws {
        let json = """
        {
            "null_val": null,
            "bool_val": true,
            "int_val": 42,
            "double_val": 3.14,
            "string_val": "hello",
            "array_val": [1, 2, 3],
            "dict_val": {"key": "value"}
        }
        """.data(using: .utf8)!

        struct TestContainer: Codable {
            let nullVal: NetworkService.AnyCodable?
            let boolVal: NetworkService.AnyCodable?
            let intVal: NetworkService.AnyCodable?
            let doubleVal: NetworkService.AnyCodable?
            let stringVal: NetworkService.AnyCodable?
            let arrayVal: NetworkService.AnyCodable?
            let dictVal: NetworkService.AnyCodable?

            enum CodingKeys: String, CodingKey {
                case nullVal = "null_val"
                case boolVal = "bool_val"
                case intVal = "int_val"
                case doubleVal = "double_val"
                case stringVal = "string_val"
                case arrayVal = "array_val"
                case dictVal = "dict_val"
            }
        }

        let container = try decoder.decode(TestContainer.self, from: json)
        XCTAssertNil(container.nullVal?.value)
        XCTAssertEqual(container.boolVal?.value as? Bool, true)
        XCTAssertEqual(container.intVal?.value as? Int, 42)
        XCTAssertEqual(container.doubleVal?.value as? Double, 3.14)
        XCTAssertEqual(container.stringVal?.value as? String, "hello")
        XCTAssertNotNil(container.arrayVal?.value)
        XCTAssertNotNil(container.dictVal?.value)
    }

    // MARK: - APIResponse 测试

    func testAPIResponseRequireDataThrowsOnNilData() {
        let json = """
        {"code": 500, "message": "server error", "data": null}
        """.data(using: .utf8)!

        do {
            let response = try decoder.decode(NetworkService.APIResponse<NetworkService.Home2DTO>.self, from: json)
            _ = try response.requireData()
            XCTFail("Should have thrown")
        } catch let error as NetworkError {
            if case .serverError(let msg) = error {
                XCTAssertEqual(msg, "server error")
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 真实 API 在线测试

    func testRealAPIHome2Decoding() async throws {
        let url = URL(string: "https://gwqietap.sxjzit.edu.cn/mapi/school/home2")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            XCTFail("Invalid response")
            return
        }
        XCTAssertEqual(http.statusCode, 200, "API should return 200")

        // 核心测试：解码不能崩溃
        let apiResponse = try decoder.decode(NetworkService.APIResponse<NetworkService.Home2DTO>.self, from: data)
        let home2 = try apiResponse.requireData()

        // 验证关键数据存在
        XCTAssertNotNil(home2.topBanners, "topBanners 不应为 nil")
        XCTAssertFalse(home2.topBanners?.isEmpty ?? true, "topBanners 不应为空")
        XCTAssertNotNil(home2.news, "news 不应为 nil")
        XCTAssertNotNil(home2.news?.children?.importants, "importants 不应为 nil")
        XCTAssertNotNil(home2.news?.children?.updates, "updates 不应为 nil")
        XCTAssertNotNil(home2.news?.children?.notices, "notices 不应为 nil")
        XCTAssertNotNil(home2.news?.children?.informations, "informations 不应为 nil")
        XCTAssertNotNil(home2.news?.children?.resports, "resports 不应为 nil")
        XCTAssertNotNil(home2.achievements, "achievements 不应为 nil")
        XCTAssertNotNil(home2.videos, "videos 不应为 nil")
        XCTAssertNotNil(home2.students, "students 不应为 nil")
        XCTAssertNotNil(home2.teachers, "teachers 不应为 nil")
        XCTAssertNotNil(home2.campus, "campus 不应为 nil")
        XCTAssertNotNil(home2.campus?.children?.activites, "campus.activites 不应为 nil")

        // 验证数量合理性
        XCTAssertGreaterThan(home2.news?.children?.importants?.articles?.total ?? 0, 100, "学校要闻应超过100条")
        XCTAssertGreaterThan(home2.news?.children?.notices?.articles?.total ?? 0, 50, "通知公告应超过50条")

        print("✅ 真实 API 解码成功!")
        print("  学校要闻: \(home2.news?.children?.importants?.articles?.total ?? 0) 条")
        print("  通知公告: \(home2.news?.children?.notices?.articles?.total ?? 0) 条")
        print("  新闻资讯: \(home2.news?.children?.updates?.articles?.total ?? 0) 条")
        print("  科研报告: \(home2.news?.children?.resports?.articles?.total ?? 0) 条")
        print("  信息公告: \(home2.news?.children?.informations?.articles?.total ?? 0) 条")
    }

    // MARK: - Articles API 在线测试

    func testRealAPIArticlesDecoding() async throws {
        // 测试学校要闻列表 API
        let url = URL(string: "https://gwqietap.sxjzit.edu.cn/mapi/common/column/articles?site_id=1&column_id=41cb4c8424ac474891e1470aa2fb071b&page=1&size=5")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let response = try decoder.decode(NetworkService.APIResponse<NetworkService.ColumnDTO>.self, from: data)
        let column = try response.requireData()

        XCTAssertEqual(column.columnId, "41cb4c8424ac474891e1470aa2fb071b")
        XCTAssertGreaterThan(column.articles?.total ?? 0, 0, "学校要闻应有文章")
        XCTAssertEqual(column.articles?.list?.count, 5, "请求5条应返回5条")

        // 验证文章字段
        if let first = column.articles?.list?.first {
            XCTAssertNotNil(first.title, "文章应有标题")
            XCTAssertNotNil(first.id, "文章应有 id")
        }

        print("✅ Articles API 解码成功! total=\(column.articles?.total ?? 0)")
    }

    // MARK: - Article Detail API 在线测试

    func testRealAPIArticleDetailDecoding() async throws {
        let url = URL(string: "https://gwqietap.sxjzit.edu.cn/mapi/common/article/detail?article_id=744c042893c34adbb78ea2a799efe5cb")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let response = try decoder.decode(NetworkService.APIResponse<NetworkService.ArticleDetailDTO>.self, from: data)
        let detail = try response.requireData()

        XCTAssertNotNil(detail.title, "文章详情应有标题")
        XCTAssertNotNil(detail.content, "文章详情应有 content")
        XCTAssertTrue(detail.content?.count ?? 0 > 50, "文章详情 content 应超过50字符")

        print("✅ Article Detail API 解码成功! title=\(detail.title ?? "")")
    }
}

// MARK: - 阅读统计计算器测试（正文字数 + 预计阅读时长）

/// 口径 A：总字数 = 中文字符数 + 英文单词数；时长 = 中文/300 + 英文/220 + 图片递减耗时 + 代码块 30s
final class ReadingStatsCalculatorTests: XCTestCase {

    // MARK: 1. 纯中文短文（300 字 → 1 分钟）

    func testPureChineseArticle() {
        let text = String(repeating: "字", count: 300)
        let result = ReadingStatsCalculator.calculate(plainText: text)
        XCTAssertNotNil(result, "非空中文正文应返回结果")
        XCTAssertEqual(result?.chineseChars, 300)
        XCTAssertEqual(result?.englishWords, 0)
        XCTAssertEqual(result?.totalCount, 300)
        XCTAssertEqual(result?.minutes, 1, "300 字 / 300 字每分钟 = 1 分钟")
    }

    // MARK: 2. 纯英文短文（440 词 → 2 分钟）

    func testPureEnglishArticle() {
        let text = String(repeating: "word ", count: 440)
        let result = ReadingStatsCalculator.calculate(plainText: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.chineseChars, 0)
        XCTAssertEqual(result?.englishWords, 440)
        XCTAssertEqual(result?.totalCount, 440)
        XCTAssertEqual(result?.minutes, 2, "440 词 / 220 词每分钟 = 2 分钟")
    }

    // MARK: 3. 中英混排（不粘连：4 字 + 1 词）

    func testMixedChineseEnglishNotGlued() {
        let result = ReadingStatsCalculator.calculate(plainText: "你会说English吗")
        XCTAssertEqual(result?.chineseChars, 4, "中文字符应为 4 个（你会说吗）")
        XCTAssertEqual(result?.englishWords, 1, "English 应计为 1 个英文词")
        XCTAssertEqual(result?.totalCount, 5)
        XCTAssertEqual(result?.minutes, 1, "5 单位文本不足 1 分钟向上取整为 1")
    }

    // MARK: 4. 大量标点（字数不得虚高）

    func testPunctuationStripped() {
        let text = "你好，世界！这是一个（测试）……「样例」——开心；: \"quotes\" , . ! ? ( ) [ ] { } - / \\ | \t\n　"
        let result = ReadingStatsCalculator.calculate(plainText: text)
        XCTAssertEqual(result?.chineseChars, 14, "仅统计中文字符：你好世界这是一个测试样例开心 = 14")
        XCTAssertEqual(result?.englishWords, 1, "quotes 为唯一英文词")
        XCTAssertEqual(result?.totalCount, 15)
    }

    // MARK: 5. Markdown 含 2 代码块 + 3 图（附加耗时生效）

    func testMarkdownCodeBlocksAndImagesAffectTime() {
        let markdown = """
        # 标题

        这是一段正文，用来验证代码块与图片的附加耗时是否生效。一共一百二十个字符的话会占用一部分时间。

        ```swift
        let a = 1
        print(a)
        ```

        继续正文。

        ![图一](https://example.com/1.png)
        ![图二](https://example.com/2.png)

        ```python
        print("hello")
        ```

        结尾段落。

        ![图三](https://example.com/3.png)
        """
        let stripped = ReadingStatsCalculator.stripMarkdown(markdown)
        XCTAssertEqual(stripped.imageCount, 3, "应识别出 3 张图片")
        XCTAssertEqual(stripped.codeBlockCount, 2, "应识别出 2 个围栏代码块")
        XCTAssertFalse(stripped.text.contains("```"), "代码块内容应被剥离")
        XCTAssertFalse(stripped.text.contains("#"), "标题符号应被剥离")

        // 图片耗时：12 + 11 + 10 = 33s；代码块：30×2 = 60s；合计 93s = 1.55 分钟附加
        let result = ReadingStatsCalculator.calculate(
            plainText: stripped.text,
            imageCount: stripped.imageCount,
            codeBlockCount: stripped.codeBlockCount
        )
        XCTAssertNotNil(result)
        let textOnly = ReadingStatsCalculator.calculate(plainText: stripped.text, imageCount: 0, codeBlockCount: 0)
        let addedSeconds = (result!.rawMinutes - textOnly!.rawMinutes) * 60
        XCTAssertEqual(addedSeconds, 93.0, accuracy: 0.01, "附加耗时应为 93 秒（33s 图片 + 60s 代码块）")
    }

    // MARK: 6. 空文本 / 纯空白（返回 nil，不展示）

    func testEmptyAndWhitespaceTextReturnsNil() {
        XCTAssertNil(ReadingStatsCalculator.calculate(plainText: ""), "空文本应返回 nil")
        XCTAssertNil(ReadingStatsCalculator.calculate(plainText: "   \n\t　 "), "纯空白应返回 nil")
        XCTAssertNil(ReadingStatsCalculator.calculate(plainText: "！！！……？？"), "纯标点应返回 nil")
    }

    // MARK: 7. 超长文本（10 万字：计数正确且单趟遍历性能达标）

    func testVeryLongTextPerformance() {
        let text = String(repeating: "长文", count: 50_000)   // 10 万中文字符
        let start = CFAbsoluteTimeGetCurrent()
        let result = ReadingStatsCalculator.calculate(plainText: text)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(result?.chineseChars, 100_000, "10 万字应全额计数")
        XCTAssertEqual(result?.minutes, 334, "100000 / 300 ≈ 333.3 → 向上取整 334 分钟")
        XCTAssertLessThan(elapsed, 1.0, "10 万字单趟统计应远快于 1 秒（后台化阈值内不阻塞 UI）")
    }

    // MARK: 8. 展示文案（千分位 + 小时换算）

    func testFormatting() {
        XCTAssertEqual(ReadingStatsCalculator.formattedCount(2486), "2,486", "千分位分隔符")
        XCTAssertEqual(ReadingStatsCalculator.formattedMinutes(9), "阅读约 9 分钟")
        XCTAssertEqual(ReadingStatsCalculator.formattedMinutes(90), "阅读约 1.5 小时", "90 分钟 → 1.5 小时")
        XCTAssertEqual(ReadingStatsCalculator.formattedMinutes(120), "阅读约 2 小时", "120 分钟 → 2 小时")
    }

    // MARK: 9. 图片耗时递减边界（首图 12s，逐张 -1s，最低 3s）

    func testImageTimeDecayFloor() {
        func imageSeconds(_ count: Int) -> Double {
            var total = 0.0
            for idx in 0..<count {
                total += max(ReadingStatsCalculator.minImageSeconds,
                             ReadingStatsCalculator.firstImageSeconds - Double(idx) * ReadingStatsCalculator.imageDecaySeconds)
            }
            return total
        }
        XCTAssertEqual(imageSeconds(1), 12)
        XCTAssertEqual(imageSeconds(2), 23)
        XCTAssertEqual(imageSeconds(3), 33)
        XCTAssertEqual(imageSeconds(10), 12 + 11 + 10 + 9 + 8 + 7 + 6 + 5 + 4 + 3, "第 8 张起锁死 3 秒")
    }

    // MARK: 10. 服务链路集成（resolve：预处理 → 计算 → 缓存 → 缓存命中）

    @MainActor
    func testReadingStatsServiceResolveIntegration() async {
        // 确保开关开启，模拟真实用户默认状态
        DisplaySettingsManager.shared.readingStatsEnabled = true
        let source: ArticleReadingTextSource = .plain("这是集成测试正文，用于验证服务层完整链路：预处理、计算与缓存。")

        let first = await ReadingStatsService.resolve(cachedID: "integration-test", source: source)
        XCTAssertNotNil(first, "服务层应对非空正文返回统计结果")
        XCTAssertGreaterThan(first?.totalCount ?? 0, 0)

        // 二次调用应命中缓存（分量一致、结果一致）
        let second = await ReadingStatsService.resolve(cachedID: "integration-test", source: source)
        XCTAssertEqual(first, second, "缓存命中结果应与首次一致")
    }

    // MARK: 11. 总开关关闭时服务链路直接返回 nil（不显示）

    @MainActor
    func testReadingStatsServiceDisabled() async {
        DisplaySettingsManager.shared.readingStatsEnabled = false
        let result = await ReadingStatsService.resolve(
            cachedID: "integration-disabled",
            source: .plain("这段正文在开关关闭时不应被统计。")
        )
        XCTAssertNil(result, "总开关关闭时应返回 nil（整项不显示）")
        DisplaySettingsManager.shared.readingStatsEnabled = true   // 还原，避免影响其他用例
    }
}
