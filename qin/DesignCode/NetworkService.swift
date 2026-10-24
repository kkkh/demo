//
//  NetworkService.swift
//  山西晋中理工学院 APP — 网络层
//

import Foundation

// MARK: - 网络配置

enum NetworkConfig {
    static let baseURL = "https://gwqietap.sxjzit.edu.cn/mapi"
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30
    static let maxRetries = 2
}

// MARK: - 网络错误

enum NetworkError: LocalizedError {
    case badURL
    case badResponse(Int)
    case decodeFailed(String)
    case timeout
    case noData
    /// 服务端返回成功但无数据（data=null）——文案由调用方提供完整可读说明
    case dataMissing(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的请求地址"
        case .badResponse(let code): return "服务器响应异常（状态码：\(code)）"
        case .decodeFailed(let msg): return "数据解析失败：\(msg)"
        case .timeout: return "网络请求超时，请检查网络连接后重试"
        case .noData: return "服务器未返回数据，请稍后重试"
        case .dataMissing(let msg): return msg
        case .serverError(let msg): return "服务器错误：\(msg)"
        }
    }
}

// MARK: - 网络服务

final class NetworkService: @unchecked Sendable {
    static let shared = NetworkService()

    private let session: URLSession
    private let cachedSession: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = NetworkConfig.requestTimeout
        config.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        // 显式注册协议层：不依赖 URLProtocol.registerClass 的全局时序
        //（App.init 属性初始化早于 init 体，提前创建的会话会漏注册 → 埋点恒 0 的历史根因）
        config.protocolClasses = [RefererHeaderURLProtocol.self]
        self.session = URLSession(configuration: config)

        let cachedConfig = URLSessionConfiguration.default
        cachedConfig.timeoutIntervalForRequest = NetworkConfig.requestTimeout
        cachedConfig.timeoutIntervalForResource = NetworkConfig.resourceTimeout
        cachedConfig.requestCachePolicy = .useProtocolCachePolicy
        cachedConfig.urlCache = URLCache(
            memoryCapacity: 10 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            diskPath: "article_detail_cache")
        cachedConfig.waitsForConnectivity = false
        cachedConfig.protocolClasses = [RefererHeaderURLProtocol.self]
        self.cachedSession = URLSession(configuration: cachedConfig)

        self.decoder = JSONDecoder()
    }

    // MARK: - GET 请求（带重试 + 指数退避）

    func get<T: Decodable>(_ path: String, params: [String: String]? = nil, as type: T.Type) async throws -> T {
        let startTime = Date()
        var lastError: Error?
        for attempt in 0...NetworkConfig.maxRetries {
            do {
                let url = try buildURL(path: path, params: params)
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = NetworkConfig.requestTimeout

                let (data, resp) = try await session.data(for: req)
                try validate(resp, data)
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                await LogManager.shared.info("network", "请求成功", context: [
                    "path": path, "method": "GET", "status": "\( (resp as? HTTPURLResponse)?.statusCode ?? 0)",
                    "elapsed": "\(elapsed)ms", "attempt": "\(attempt + 1)"
                ])
                return try decoder.decode(T.self, from: data)
            } catch {
                lastError = error
                // 请求被取消（编排接管：下拉刷新取代/页面离开/任务切换）非失败语义：
                // 不重试、不记 ERROR，直接向上传播，由调用方按取消路径处理
                if (error as? URLError)?.code == .cancelled {
                    await LogManager.shared.debugLog("network", "请求已取消（跳过重试）", context: [
                        "path": path, "attempt": "\(attempt + 1)"
                    ])
                    throw error
                }
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                if attempt < NetworkConfig.maxRetries {
                    await LogManager.shared.warning("network", "请求失败，准备重试", context: [
                        "path": path, "error": error.localizedDescription,
                        "attempt": "\(attempt + 1)", "elapsed": "\(elapsed)ms"
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt + 1))
                } else {
                    await LogManager.shared.error("network", "请求最终失败", context: [
                        "path": path, "error": error.localizedDescription,
                        "attempts": "\(NetworkConfig.maxRetries + 1)", "elapsed": "\(elapsed)ms"
                    ])
                }
            }
        }
        throw lastError ?? NetworkError.timeout
    }

    /// 通用 POST（JSON body；与 inventory §0「POST+JSON body 需带 Content-Type: application/json」一致）。
    /// 重试/取消语义与 `get` 完全一致（HTTP 恒 200 时业务码在 body，交由调用方判断）。
    func post<T: Decodable>(_ path: String, body: [String: Any]? = nil, as type: T.Type) async throws -> T {
        let startTime = Date()
        var lastError: Error?
        for attempt in 0...NetworkConfig.maxRetries {
            do {
                let url = try buildURL(path: path, params: nil)
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                if let body {
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                }
                req.timeoutInterval = NetworkConfig.requestTimeout

                let (data, resp) = try await session.data(for: req)
                try validate(resp, data)
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                await LogManager.shared.info("network", "请求成功", context: [
                    "path": path, "method": "POST", "status": "\( (resp as? HTTPURLResponse)?.statusCode ?? 0)",
                    "elapsed": "\(elapsed)ms", "attempt": "\(attempt + 1)"
                ])
                return try decoder.decode(T.self, from: data)
            } catch {
                lastError = error
                if (error as? URLError)?.code == .cancelled {
                    await LogManager.shared.debugLog("network", "请求已取消（跳过重试）", context: [
                        "path": path, "attempt": "\(attempt + 1)"
                    ])
                    throw error
                }
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                if attempt < NetworkConfig.maxRetries {
                    await LogManager.shared.warning("network", "请求失败，准备重试", context: [
                        "path": path, "error": error.localizedDescription,
                        "attempt": "\(attempt + 1)", "elapsed": "\(elapsed)ms"
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt + 1))
                } else {
                    await LogManager.shared.error("network", "请求最终失败", context: [
                        "path": path, "error": error.localizedDescription,
                        "attempts": "\(NetworkConfig.maxRetries + 1)", "elapsed": "\(elapsed)ms"
                    ])
                }
            }
        }
        throw lastError ?? NetworkError.timeout
    }

    /// 使用指定 URLSession 执行 GET 请求（用于缓存策略差异化）
    private func getWithSession<T: Decodable>(_ path: String, params: [String: String]? = nil, as type: T.Type, session: URLSession) async throws -> T {
        let startTime = Date()
        var lastError: Error?
        for attempt in 0...NetworkConfig.maxRetries {
            do {
                let url = try buildURL(path: path, params: params)
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = NetworkConfig.requestTimeout

                let (data, resp) = try await session.data(for: req)
                try validate(resp, data)
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                await LogManager.shared.info("network", "请求成功(缓存策略)", context: [
                    "path": path, "method": "GET", "status": "\( (resp as? HTTPURLResponse)?.statusCode ?? 0)",
                    "elapsed": "\(elapsed)ms", "attempt": "\(attempt + 1)"
                ])
                return try decoder.decode(T.self, from: data)
            } catch {
                lastError = error
                // 请求被取消（编排接管：下拉刷新取代/页面离开/任务切换）非失败语义：
                // 不重试、不记 ERROR，直接向上传播，由调用方按取消路径处理
                if (error as? URLError)?.code == .cancelled {
                    await LogManager.shared.debugLog("network", "请求已取消（跳过重试）", context: [
                        "path": path, "attempt": "\(attempt + 1)"
                    ])
                    throw error
                }
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                if attempt < NetworkConfig.maxRetries {
                    await LogManager.shared.warning("network", "请求失败，准备重试", context: [
                        "path": path, "error": error.localizedDescription,
                        "attempt": "\(attempt + 1)", "elapsed": "\(elapsed)ms"
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt + 1))
                } else {
                    await LogManager.shared.error("network", "请求最终失败", context: [
                        "path": path, "error": error.localizedDescription,
                        "attempts": "\(NetworkConfig.maxRetries + 1)", "elapsed": "\(elapsed)ms"
                    ])
                }
            }
        }
        throw lastError ?? NetworkError.timeout
    }

    // MARK: - 学校官网 API 方法

    /// 获取首页完整数据
    func fetchHome2() async throws -> Home2DTO {
        try await get("/school/home2", as: APIResponse<Home2DTO>.self).requireData()
    }

    /// 获取头部信息（站点信息 + 导航菜单）
    func fetchHead() async throws -> HeadDTO {
        try await get("/common/column/head", as: APIResponse<HeadDTO>.self).requireData()
    }

    /// 获取底部信息（招生电话 + 友情链接 + 社交平台）
    func fetchFoot() async throws -> FootDTO {
        try await get("/common/foot", as: APIResponse<FootDTO>.self).requireData()
    }

    /// 获取文章列表
    func fetchArticles(columnId: String, siteId: String = "1", page: Int = 1, size: Int = 20) async throws -> ColumnDTO {
        try await get("/common/column/articles", params: [
            "site_id": siteId, "column_id": columnId, "page": "\(page)", "size": "\(size)"
        ], as: APIResponse<ColumnDTO>.self).requireData()
    }

    /// 获取文章详情
    func fetchArticleDetail(articleId: String, siteId: String = "1", useCache: Bool = false) async throws -> ArticleDetailDTO {
        let session = useCache ? cachedSession : self.session
        return try await getWithSession("/common/article/detail", params: [
            "site_id": siteId, "article_id": articleId
        ], as: APIResponse<ArticleDetailDTO>.self, session: session).requireData()
    }

    /// 通过文章详情 API（href）获取完整 HTML 内容，并解析出纯文本
    func fetchArticleDetailWithHref(_ href: String) async throws -> NewsDetailDTO {
        let data = try await getRaw(href)
        // 尝试 JSON 解码
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any] {
            let title = dataDict["title"] as? String ?? ""
            let content = dataDict["content"] as? String ?? ""
            let author = dataDict["author"] as? String ?? ""
            let source = dataDict["source"] as? String ?? ""
            let createTime = dataDict["create_time"] as? String ?? ""
            let updateTime = dataDict["update_time"] as? String ?? ""
            let imageList = parseImages(from: dataDict)
            let plainText = content.strippingHTMLTags()
            return NewsDetailDTO(
                title: title,
                // create_time 为空（早期文章）时回退 update_time
                publishTime: createTime.isEmpty ? updateTime : createTime,
                author: author,
                source: source,
                fullHTMLContent: content,
                plainTextContent: plainText,
                images: imageList
            )
        }
        // 兜底：直接当作 HTML 字符串处理
        let html = String(data: data, encoding: .utf8) ?? ""
        let plainText = html.strippingHTMLTags()
        return NewsDetailDTO(
            title: "",
            publishTime: "",
            author: "",
            source: "",
            fullHTMLContent: html,
            plainTextContent: plainText,
            images: []
        )
    }

    /// 原始 GET 请求，返回 Data（用于非标准 JSON 响应）
    private func getRaw(_ path: String) async throws -> Data {
        let url = try buildURL(path: path, params: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = NetworkConfig.requestTimeout
        let (data, resp) = try await session.data(for: req)
        try validate(resp, data)
        return data
    }

    /// 解析官网短链（/s/xxx）302 重定向后的最终 URL。
    /// 党建/思政子站少量文章详情响应 href 为短链形态，真实文章 id 藏在短链跳转
    /// 目标（#/list/article?id=…）中——HEAD 请求随重定向自动跟随，response.url 即最终地址。
    func resolveShortLinkFinalURL(_ shortURL: URL) async -> URL? {
        var req = URLRequest(url: shortURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = NetworkConfig.requestTimeout
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            guard (200...399).contains(http.statusCode) else { return nil }
            guard let final = resp.url else { return nil }
            await LogManager.shared.debugLog("network", "短链解析完成", context: [
                "short": shortURL.absoluteString,
                "final": final.absoluteString,
                "status": "\(http.statusCode)"
            ])
            return final
        } catch {
            await LogManager.shared.warning("network", "短链解析失败", context: [
                "short": shortURL.absoluteString,
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// 拉取并解析为结构化 JSON 字典（/school/intro 等形态动态接口；返回 code=200 时的 data 层）
    func fetchJSONDict(path: String) async throws -> [String: Any] {
        try await fetchJSONDict(path: path, params: nil)
    }

    /// 带参数版结构化 JSON 拉取
    func fetchJSONDict(path: String, params: [String: String]?) async throws -> [String: Any] {
        let data = try await getRawData(path: path, params: params)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.decodeFailed("响应非 JSON 对象")
        }
        return json
    }

    /// 原始数据请求（带参数与校验；getRaw 的通用化）
    private func getRawData(path: String, params: [String: String]?) async throws -> Data {
        let url = try buildURL(path: path, params: params)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = NetworkConfig.requestTimeout
        let (data, resp) = try await session.data(for: req)
        try validate(resp, data)
        return data
    }

    /// 从 JSON 字典中解析图片列表
    private func parseImages(from dict: [String: Any]) -> [ImageDTO] {
        if let images = dict["images"] as? [[String: Any]] {
            return images.compactMap { img in
                ImageDTO(
                    url: img["url"] as? String ?? img["src"] as? String ?? "",
                    alt: img["alt"] as? String ?? img["description"] as? String
                )
            }
        }
        // 尝试从 content 中提取 <img> 标签
        if let content = dict["content"] as? String {
            return extractImagesFromHTML(content)
        }
        return []
    }

    /// 从 HTML 中提取 <img> 标签的 src 和 alt
    private func extractImagesFromHTML(_ html: String) -> [ImageDTO] {
        var images: [ImageDTO] = []
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
                    print("[NetworkService] Skipping local file path: \(rawUrl)")
                    return
                }
                let url = safeImageURL(from: rawUrl)
                var alt = ""
                if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
                   let altRange = Range(match.range(at: 2), in: html) {
                    alt = String(html[altRange])
                }
                images.append(ImageDTO(url: url, alt: alt.isEmpty ? nil : alt))
            }
        }
        return images
    }

    /// 对图片 URL 进行安全编码，处理中文等非 ASCII 字符，并解析相对路径为绝对 URL
    private func safeImageURL(from string: String) -> String {
        var urlString = string

        // 处理相对路径：文章详情 HTML 中的图片 URL 可能是相对路径（如 /uploads/...），
        // 需要解析为绝对 URL，否则 URLSession 无法正确加载
        if urlString.hasPrefix("/") {
            if urlString.hasPrefix("//") {
                urlString = "https:" + urlString
            } else {
                urlString = SchoolInfo.website + urlString
            }
            print("[NetworkService] Resolved relative URL: \(string) → \(urlString)")
        } else if !urlString.contains("://") {
            urlString = SchoolInfo.website + "/" + urlString
            print("[NetworkService] Resolved relative URL (no scheme): \(string) → \(urlString)")
        }

        if URL(string: urlString) != nil { return urlString }
        print("[NetworkService] URL needs encoding: \(urlString)")
        var allowed = CharacterSet.urlPathAllowed
        allowed.formUnion(.urlHostAllowed)
        allowed.formUnion(.urlQueryAllowed)
        allowed.formUnion(.urlFragmentAllowed)
        allowed.insert(charactersIn: "%")
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowed) ?? urlString
        print("[NetworkService] Encoded URL: \(encoded)")
        return encoded
    }

    // MARK: - 内部工具

    private func buildURL(path: String, params: [String: String]?) throws -> URL {
        let full: String
        if path.hasPrefix("http") {
            full = path
        } else {
            full = NetworkConfig.baseURL + (path.hasPrefix("/") ? path : "/\(path)")
        }
        guard var comps = URLComponents(string: full) else {
            throw NetworkError.badURL
        }
        if let p = params, !p.isEmpty {
            comps.queryItems = p.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw NetworkError.badURL
        }
        return url
    }

    private func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.badResponse(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NetworkError.badResponse(http.statusCode)
        }
    }
}

// MARK: - 通用 API 响应包装

extension NetworkService {
    struct APIResponse<T: Codable>: Codable {
        let code: Int?
        let message: String?
        let data: T?

        /// 安全获取 data，如果为 nil 则抛出 noData 错误
        func requireData() throws -> T {
            guard let data = data else {
                if let msg = message, !msg.isEmpty {
                    throw NetworkError.serverError(msg)
                }
                throw NetworkError.noData
            }
            return data
        }
    }
}

// MARK: - 栏目常量

extension NetworkService {
    /// 校园生活 → 校园日历 栏目 ID（官网 column_id，site_id=1）
    static let campusCalendarColumnId = "8197fe41503c4c32bce1e449d2492b2e"
}

// MARK: - API DTO

extension NetworkService {

    // MARK: 文章

    struct ArticleDTO: Codable {
        let id: String?
        let title: String?
        let titleCn: String?
        let description: String?
        let imageUrl: String?
        let createTime: String?
        let updateTime: String?
        let tag: String?
        let sort: Int?
        let href: String?

        /// 兼容 home2（title_cn）和栏目 API（title）两种字段名
        var resolvedTitle: String? { title ?? titleCn }

        enum CodingKeys: String, CodingKey {
            case id, title, description, tag, sort, href
            case titleCn = "title_cn"
            case imageUrl = "image_url"
            case createTime = "create_time"
            case updateTime = "update_time"
        }
    }

    struct ArticleDetailDTO: Codable {
        let id: String?
        let title: String?
        let description: String?
        let content: String?
        let imageUrl: String?
        let createTime: String?
        let updateTime: String?
        let tag: String?
        let author: String?
        let source: String?
        /// 文章官网原文链接（党建/思政子站文章的关键字段：
        /// 列表接口的 article id 与真正承载全文的 id 不一致，全文 id 藏在此 href 的 ?id= 参数中）
        let href: String?

        enum CodingKeys: String, CodingKey {
            case id, title, description, content, tag, author, source, href
            case imageUrl = "image_url"
            case createTime = "create_time"
            case updateTime = "update_time"
        }
    }

    // MARK: 文章图片

    struct ImageDTO: Codable {
        let url: String
        let alt: String?

        init(url: String, alt: String? = nil) {
            self.url = url
            self.alt = alt
        }
    }

    // MARK: 文章详情页完整数据

    struct NewsDetailDTO: Codable {
        let title: String
        let publishTime: String
        let author: String
        let source: String
        let fullHTMLContent: String
        let plainTextContent: String
        let images: [ImageDTO]

        init(title: String, publishTime: String, author: String, source: String, fullHTMLContent: String, plainTextContent: String, images: [ImageDTO]) {
            self.title = title
            self.publishTime = publishTime
            self.author = author
            self.source = source
            self.fullHTMLContent = fullHTMLContent
            self.plainTextContent = plainTextContent
            self.images = images
        }
    }

    struct ArticleListDTO: Codable {
        let total: Int?
        let list: [ArticleDTO]?
    }

    struct ColumnDTO: Codable {
        let columnId: String?
        let titleCn: String?
        let titleEn: String?
        let href: String?
        let articles: ArticleListDTO?
        let children: [String: ColumnDTO]?

        enum CodingKeys: String, CodingKey {
            case columnId = "column_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case href, articles, children
        }
    }

    // MARK: Banner

    struct BannerDTO: Codable {
        let videoSrc: String?
        let posterImgSrc: String?
        let videoTitleImgSrc: String?

        enum CodingKeys: String, CodingKey {
            case videoSrc = "videoSrc"
            case posterImgSrc = "posterImgSrc"
            case videoTitleImgSrc = "videoTitleImgSrc"
        }
    }

    // MARK: 新闻（含子栏目）

    struct NewsChildrenDTO: Codable {
        let importants: ColumnDTO?
        let updates: ColumnDTO?
        let notices: ColumnDTO?
        let informations: ColumnDTO?
        let resports: ColumnDTO?
    }

    struct NewsColumnDTO: Codable {
        let columnId: String?
        let titleCn: String?
        let titleEn: String?
        let children: NewsChildrenDTO?

        enum CodingKeys: String, CodingKey {
            case columnId = "column_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case children
        }
    }

    // MARK: 首页

    struct Home2DTO: Codable {
        let topBanners: [BannerDTO]?
        let bottomBanners: ArticleListDTO?
        let achievements: ColumnDTO?
        let news: NewsColumnDTO?
        let video: VideoBlockDTO?
        let teachers: ColumnDTO?
        let videos: ColumnDTO?
        let students: ColumnDTO?
        let campus: CampusBlockDTO?

        enum CodingKeys: String, CodingKey {
            case topBanners = "top_banners"
            case bottomBanners = "bottom_banners"
            case achievements, news, video, teachers, videos, students, campus
        }
    }

    /// video 字段：实际结构复杂，App 不使用，用宽松类型接收
    struct VideoBlockDTO: Codable {
        let videoSrc: String?
        // dynamicDigit 是 [[String: Any]]，Codable 不直接支持 Any，用 JSON 原始值忽略
        let dynamicDigit: [AnyCodable]?
    }

    /// 万能解码包装，接受任意 JSON 值
    struct AnyCodable: Codable {
        let value: Any?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
            } else if let b = try? container.decode(Bool.self) {
                value = b
            } else if let i = try? container.decode(Int.self) {
                value = i
            } else if let d = try? container.decode(Double.self) {
                value = d
            } else if let s = try? container.decode(String.self) {
                value = s
            } else if let a = try? container.decode([AnyCodable].self) {
                value = a.map(\.value)
            } else if let d = try? container.decode([String: AnyCodable].self) {
                value = d.mapValues(\.value)
            } else {
                value = nil
            }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    /// campus 字段实际结构：有 children（activites, calendar），无直接 articles
    struct CampusBlockDTO: Codable {
        let columnId: String?
        let titleCn: String?
        let titleEn: String?
        let href: String?
        let children: CampusChildrenDTO?
        enum CodingKeys: String, CodingKey {
            case columnId = "column_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case href, children
        }
    }

    struct CampusChildrenDTO: Codable {
        let activites: ColumnDTO?
        let calendar: ColumnDTO?
    }

    // MARK: 站点

    struct SiteDTO: Codable {
        let siteId: String?
        let titleCn: String?
        let titleEn: String?
        let domain: String?
        let logo: String?
        let description: String?
        let keywords: String?
        let themeColor: String?
        let address: String?
        let phone: String?
        let email: String?

        enum CodingKeys: String, CodingKey {
            case siteId = "site_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case domain, logo, description, keywords
            case themeColor = "theme_color"
            case address, phone, email
        }
    }

    // MARK: 菜单

    struct MenuDTO: Codable {
        let id: String?
        let parentId: String?
        let titleCn: String?
        let titleEn: String?
        let path: String?
        let children: [MenuDTO]?

        enum CodingKeys: String, CodingKey {
            case id
            case parentId = "parent_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case path, children
        }
    }

    // MARK: 头部

    struct HeadDTO: Codable {
        let site: SiteDTO?
        let menus: [MenuDTO]?
    }

    // MARK: 底部

    struct FootDTO: Codable {
        let site: SiteDTO?
        let recruitPhone: [String]?
        let links: FootLinkListDTO?
        let platforms: FootPlatformListDTO?

        enum CodingKeys: String, CodingKey {
            case site, links, platforms
            case recruitPhone = "recruit_phone"
        }
    }

    struct FootLinkListDTO: Codable {
        let total: Int?
        let list: [FootLinkDTO]?
    }

    struct FootLinkDTO: Codable {
        let name: String?
        let href: String?
    }

    struct FootPlatformListDTO: Codable {
        let total: Int?
        let list: [FootPlatformDTO]?
    }

    struct FootPlatformDTO: Codable {
        let title: String?
        let img: String?
    }

    // MARK: 招生网（ZSW）

    /// 招生网首页数据
    func fetchZSWHome2() async throws -> ZSWHome2DTO {
        try await get("/dept/home2", params: ["site_key": "zsw"], as: APIResponse<ZSWHome2DTO>.self).requireData()
    }

    /// 招生网文章列表（分页）
    /// - 注意：服务端只认 `page`/`size`——旧版传 `pageNo`/`pageSize` 会被**静默忽略**（恒返回第 1 页、默认 10 条，
    ///   表现为「加载更多」重复返回首批数据）。2026-09-30 机构接口摸查实测修复，
    ///   证据：`qin/docs/departments-api-evidence/raw/ep_article_page_*.json`（pageNo 被忽略对照）与 audit-report §7 P1。
    /// - **2026-10-01 修复**：改走 `/common/column/articles`（官网列表页同源接口）。
    ///   旧 `/common/article/page` 对招生栏目**固定只返回 12 条**（total=12、size/p 无效）——
    ///   与官网总量 21（column/articles 口径）不符，是「招生公告数量远少于官网」的根因之二。
    ///   `ZSWArticlePageDTO` 结构对齐：列接口的 data.articles.list 即全量列表。
    func fetchZSWArticlePage(siteId: String, columnId: String, page: Int = 1, size: Int = 20) async throws -> ZSWArticlePageDTO {
        try await get("/common/column/articles", params: [
            "site_id": siteId, "column_id": columnId,
            "page": "\(page)", "size": "\(size)"
        ], as: APIResponse<ZSWArticlePageDTO>.self).requireData()
    }

    struct ZSWHome2DTO: Codable {
        let site: ZSWSiteDTO?
        let nav: [ZSWNavDTO]?

        struct ZSWSiteDTO: Codable {
            let siteId: String?
            let titleCn: String?
            enum CodingKeys: String, CodingKey {
                case siteId = "site_id"
                case titleCn = "title_cn"
            }
        }

        struct ZSWNavDTO: Codable {
            let data: ZSWNavDataDTO?
        }

        struct ZSWNavDataDTO: Codable {
            let one: ZSWSectionDTO?
            let enrollmentPlan: ZSWSectionDTO?
            let notice: ZSWSectionDTO?
            let applicationGuide: ZSWGuideDTO?
            let enrollmentNews: ZSWSectionDTO?

            enum CodingKeys: String, CodingKey {
                case one, notice
                case enrollmentPlan = "enrollment-plan"
                case applicationGuide = "application-guide"
                case enrollmentNews = "enrollment-news"
            }
        }

        struct ZSWSectionDTO: Codable {
            let columnId: String?
            let siteId: String?
            let titleCn: String?
            let titleEn: String?
            let componentType: String?
            let articles: ZSWArticlesDTO?
            let children: ZSWChildrenDTO?

            enum CodingKeys: String, CodingKey {
                case columnId = "column_id"
                case siteId = "site_id"
                case titleCn = "title_cn"
                case titleEn = "title_en"
                case componentType, articles, children
            }
        }

        struct ZSWGuideDTO: Codable {
            let columnId: String?
            let children: ZSWChildrenDTO?

            enum CodingKeys: String, CodingKey {
                case columnId = "column_id"
                case children
            }
        }

        struct ZSWChildrenDTO: Codable {
            let list: [ZSWChildDTO]?
        }

        struct ZSWChildDTO: Codable {
            let id: String?
            let titleCn: String?
            let titleEn: String?
            let href: String?
            let imageUrl: String?
            let isOut: Int?
            let articles: ZSWArticlesDTO?

            enum CodingKeys: String, CodingKey {
                case id
                case titleCn = "title_cn"
                case titleEn = "title_en"
                case href
                case imageUrl = "image_url"
                case isOut = "is_out"
                case articles
            }
        }

        struct ZSWArticlesDTO: Codable {
            let total: Int?
            let list: [ZSWArticleDTO]?
        }

        struct ZSWArticleDTO: Codable {
            let id: String?
            let title: String?
            let description: String?
            let imageUrl: String?
            let updateTime: String?
            let tag: String?
            let sort: Int?

            enum CodingKeys: String, CodingKey {
                case id, title, description, tag, sort
                case imageUrl = "image_url"
                case updateTime = "update_time"
            }
        }
    }

    /// 招生网文章分页响应（兼容 `/common/column/articles` 嵌套结构 data.articles）
    struct ZSWArticlePageDTO: Codable {
        let total: Int?
        let list: [ZSWHome2DTO.ZSWArticleDTO]?
        /// 从列接口嵌套 data.articles 中提取分页数据
        var resolved: (total: Int?, list: [ZSWHome2DTO.ZSWArticleDTO]?) {
            (total, list)
        }

        // 兼容旧扁平结构（data.total/list）与列接口嵌套（data.articles.total/list）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let arts = try? c.decode(NestedArticles.self, forKey: .articles) {
                total = arts.total
                list = arts.list
            } else {
                total = try? c.decode(Int.self, forKey: .total)
                list = try? c.decode([ZSWHome2DTO.ZSWArticleDTO].self, forKey: .list)
            }
        }
        init(total: Int?, list: [ZSWHome2DTO.ZSWArticleDTO]?) {
            self.total = total; self.list = list
        }
        struct NestedArticles: Codable {
            let total: Int?
            let list: [ZSWHome2DTO.ZSWArticleDTO]?
        }
        enum CodingKeys: String, CodingKey { case total, list, articles }
        func encode(to encoder: Encoder) throws {}
    }

    /// 招生网文章详情
    func fetchZSWArticleDetail(articleId: String, siteId: String = "cb3b1fe4fcdf40999b0c162015c3326d") async throws -> ArticleDetailDTO {
        try await get("/common/article/detail", params: [
            "site_id": siteId, "article_id": articleId
        ], as: APIResponse<ArticleDetailDTO>.self).requireData()
    }

    // MARK: 专业介绍

    /// 获取专业介绍数据（学院分组 + 专业列表）
    func fetchSpecialtyData(siteId: String, columnId: String) async throws -> SpecialtyData {
        let dto = try await get("/common/column/oneTwoArticles", params: [
            "site_id": siteId, "column_id": columnId
        ], as: APIResponse<SpecialtyColumnDTO>.self).requireData()

        let colleges = (dto.children?.list ?? []).compactMap { child -> SpecialtyCollege? in
            guard let id = child.id, let titleCn = child.titleCn else { return nil }
            let majors = (child.articles?.list ?? []).compactMap { a -> SpecialtyMajor? in
                guard let aid = a.id, let title = a.title, !title.isEmpty else { return nil }
                return SpecialtyMajor(articleId: aid, title: title,
                                      description: a.description ?? "",
                                      imageUrl: a.imageUrl)
            }
            return SpecialtyCollege(id: id, titleCn: titleCn,
                                    titleEn: child.titleEn ?? "",
                                    majors: majors)
        }

        return SpecialtyData(columnId: dto.columnId ?? columnId,
                             titleCn: dto.titleCn ?? "专业介绍",
                             colleges: colleges)
    }

    // MARK: 专业介绍 DTO

    struct SpecialtyColumnDTO: Codable {
        let columnId: String?
        let titleCn: String?
        let children: SpecialtyChildrenDTO?

        enum CodingKeys: String, CodingKey {
            case columnId = "column_id"
            case titleCn = "title_cn"
            case children
        }
    }

    struct SpecialtyChildrenDTO: Codable {
        let list: [SpecialtyCollegeDTO]?
    }

    struct SpecialtyCollegeDTO: Codable {
        let id: String?
        let titleCn: String?
        let titleEn: String?
        let articles: SpecialtyArticlesDTO?

        enum CodingKeys: String, CodingKey {
            case id
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case articles
        }
    }

    struct SpecialtyArticlesDTO: Codable {
        let list: [SpecialtyMajorDTO]?
    }

    struct SpecialtyMajorDTO: Codable {
        let id: String?
        let title: String?
        let description: String?
        let imageUrl: String?

        enum CodingKeys: String, CodingKey {
            case id, title, description
            case imageUrl = "image_url"
        }
    }

    // MARK: 机构部门（dept/home2）

    /// 获取机构部门首页数据
    func fetchDeptHome2(siteKey: String) async throws -> DeptHome2DTO {
        try await get("/dept/home2", params: ["site_key": siteKey], as: APIResponse<DeptHome2DTO>.self).requireData()
    }

    /// 机构子站栏目索引条目（文章搜索用；Codable 支持本地缓存）
    struct DeptColumnRef: Codable, Hashable {
        let id: String
        let title: String
    }

    /// 官网权威机构节点（/school/org）：机构三形态——
    /// 子站型（site_key，内容为子站栏目文章）、单文章型（article_id，内容为主站一篇介绍文章）、
    /// 外链型（path 空且无两者时按机构名跳过）
    struct SchoolOrgNode: Codable, Hashable {
        let name: String
        let siteKey: String?
        let articleId: String?
        let siteId: String?
    }

    /// 拉取官网权威机构树（departments/list 页面数据源；组织形态会变更，运行时解析，严禁硬编码）
    func fetchSchoolOrgTree() async throws -> [SchoolOrgNode] {
        let data = try await getRaw("/school/org")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            throw NetworkError.decodeFailed("机构树响应结构异常")
        }
        var nodes: [SchoolOrgNode] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                let name = dict["title_cn"] as? String ?? ""
                let siteKey = dict["site_key"] as? String
                let articleId = dict["article_id"] as? String
                let siteId = dict["site_id"] as? String
                let path = dict["path"] as? String
                // 叶子机构节点：有任一内容载体即收集
                let isLeaf = ((dict["children"] as? [Any])?.isEmpty ?? true)
                if isLeaf, !name.isEmpty, (siteKey != nil || articleId != nil || path != nil) {
                    nodes.append(SchoolOrgNode(
                        name: name,
                        siteKey: (siteKey?.isEmpty ?? true) ? nil : siteKey,
                        articleId: (articleId?.isEmpty ?? true) ? nil : articleId,
                        siteId: (siteId?.isEmpty ?? true) ? nil : siteId
                    ))
                }
                for (_, value) in dict { walk(value) }
            } else if let arr = node as? [Any] {
                for item in arr { walk(item) }
            }
        }
        walk(dataDict["children"] ?? dataDict)
        return nodes
    }

    /// 拉取机构子站站点索引：site_id + 全栏目（column_id/title）递归解析（nav 任意层级，
    /// 含 data 混合字典；服务端栏目结构与 ID 会变更，统一在运行时解析，严禁硬编码）。
    /// 关键：子站内容页栏目（tab/子页）往往只有 `id` 没有 `column_id`——该 id 实测可直接
    /// 作为 column_id 查询其文章（父栏目文章为空），因此两类 ID 统一收集，确保不遗漏。
    func fetchDeptSiteIndex(siteKey: String) async throws -> (siteId: String, columns: [DeptColumnRef]) {
        let url = try buildURL(path: "/dept/home2", params: ["site_key": siteKey])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = NetworkConfig.requestTimeout
        let (data, resp) = try await session.data(for: req)
        try validate(resp, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            throw NetworkError.decodeFailed("机构子站索引响应结构异常")
        }
        let siteId = (dataDict["site"] as? [String: Any])?["site_id"] as? String ?? ""
        var columns: [DeptColumnRef] = []
        var seen = Set<String>()

        func walk(_ node: Any, _ fallbackTitle: String) {
            if let dict = node as? [String: Any] {
                let titleCN = dict["title_cn"] as? String
                let columnID = dict["column_id"] as? String
                // ① 标准栏目：有 column_id 即收集；
                // ② 内容页/子 tab 节点：仅 id + title_cn（其 id 可直接查询文章）；
                // ③ 纯文章 dict（仅 title/description，无 column_id/ title_cn）不收集——
                //    nav 树存在两棵复制目录，其中一份的文章直接躺在 data.list 下，必须排除
                if let cid = columnID, !cid.isEmpty {
                    if !seen.contains(cid) {
                        seen.insert(cid)
                        columns.append(DeptColumnRef(id: cid, title: titleCN ?? fallbackTitle))
                    }
                } else if let tcn = titleCN, !tcn.isEmpty,
                          let cid = dict["id"] as? String, !cid.isEmpty {
                    if !seen.contains(cid) {
                        seen.insert(cid)
                        columns.append(DeptColumnRef(id: cid, title: tcn))
                    }
                }
                for (key, value) in dict {
                    // 跳过 articles 子树：其中的 id 是文章 ID 而非栏目 ID
                    if key == "articles" { continue }
                    walk(value, titleCN ?? fallbackTitle)
                }
            } else if let arr = node as? [Any] {
                for item in arr { walk(item, fallbackTitle) }
            }
        }
        walk(dataDict["nav"] ?? [], "")
        return (siteId, columns)
    }

    // MARK: 党建专题通知基线指纹（轻量：每站 1 次 /dept/home2，供通知轮询变化侦测）

    /// 党建子站指纹：文章总数 + 全站最新 3 篇（id|更新时间）
    struct PartySubjectFingerprint: Sendable {
        let totalArticles: Int
        /// 全站最新文章（按更新时间升序，最多 3 条）
        let latestArticles: [(id: String, updateTime: String)]

        /// 最新 3 篇指纹串（基线比对用；无文章时为 "-"）
        var topSignature: String {
            guard !latestArticles.isEmpty else { return "-" }
            return latestArticles.map { "\($0.id)|\($0.updateTime)" }.joined(separator: ",")
        }
    }

    /// 拉取党建子站指纹：/dept/home2 单请求内含全部栏目最新文章列表，
    /// 递归收集所有 articles 块（含首页聚合子块、tabs-sub 子页），零额外请求。
    func fetchPartySubjectFingerprint(siteKey: String) async throws -> PartySubjectFingerprint {
        let root = try await fetchJSONDict(path: "/dept/home2", params: ["site_key": siteKey])
        guard let data = root["data"] as? [String: Any] else {
            throw NetworkError.decodeFailed("党建子站响应结构异常（\(siteKey)）")
        }
        let collected = Self.collectFingerprint(from: data)
        // 首页聚合子块与常规栏目块的 list 会重复收录同一篇文章：
        // 按 id 去重（保留更晚的更新时间），避免最新 3 篇被重复条目占位
        var byId: [String: String] = [:]
        for (id, ts) in collected.latest {
            if let existing = byId[id], existing >= ts { continue }
            byId[id] = ts
        }
        let sorted = byId.map { ($0.key, $0.value) }.sorted { a, b in a.1 < b.1 }
        return PartySubjectFingerprint(
            totalArticles: collected.total,
            latestArticles: Array(sorted.suffix(3))
        )
    }

    /// 递归指纹收集：任何 articles 块的 total 累加、list 条目纳入最新候选；
    /// 深度遍历 data/children/dict/value 列表，规避服务端动态结构（首页聚合子块 / tabs-sub）。
    private static func collectFingerprint(from node: Any) -> (total: Int, latest: [(String, String)]) {
        if let dict = node as? [String: Any] {
            var total = 0
            var latest: [(String, String)] = []
            if let articles = dict["articles"] as? [String: Any] {
                if let t = articles["total"] as? NSNumber {
                    total += t.intValue
                }
                if let list = articles["list"] as? [[String: Any]] {
                    for item in list {
                        let rawId = item["id"] as? String ?? (item["id"] as? NSNumber)?.stringValue
                        let ts = item["update_time"] as? String
                            ?? item["create_time"] as? String
                            ?? item["updateTime"] as? String
                        if let rawId, let ts, !rawId.isEmpty, !ts.isEmpty {
                            latest.append((rawId, ts))
                        }
                    }
                }
            }
            for (_, value) in dict {
                let sub = collectFingerprint(from: value)
                total += sub.total
                latest += sub.latest
            }
            return (total, latest)
        }
        if let array = node as? [Any] {
            var total = 0
            var latest: [(String, String)] = []
            for item in array {
                let sub = collectFingerprint(from: item)
                total += sub.total
                latest += sub.latest
            }
            return (total, latest)
        }
        return (0, [])
    }

    // MARK: 校园风光图集（学校概况模块）

    /// 校园风光图集详情：列表接口仅返回单张封面，图集全部图片承载在文章详情
    /// content 的 HTML <img> 标签中——必须解析 content 才能拿到完整图集。
    struct SceneryAlbumDetail: Sendable {
        let articleId: String
        let title: String
        /// content 剥离标签后的纯文本（图集说明文字）
        let plainText: String
        /// 图集完整图片清单（含 alt 说明）
        let images: [ImageDTO]
    }

    /// 拉取校园风光图集详情（/common/article/detail 复用，content 提图）
    func fetchSceneryAlbumDetail(articleId: String, siteId: String = "1") async throws -> SceneryAlbumDetail {
        let dto = try await fetchArticleDetail(articleId: articleId, siteId: siteId)
        let content = dto.content ?? ""
        var images = extractImagesFromHTML(content)
        // 封面兜底：content 无图时回退到详情接口的 imageUrl 单图，保证至少一图
        if images.isEmpty, let cover = dto.imageUrl, !cover.isEmpty, !cover.hasPrefix("file://") {
            images = [ImageDTO(url: safeImageURL(from: cover), alt: dto.title)]
        }
        return SceneryAlbumDetail(
            articleId: articleId,
            title: dto.title ?? "",
            plainText: content.strippingHTMLTags().trimmingCharacters(in: .whitespacesAndNewlines),
            images: images
        )
    }

    // MARK: 校长信箱（school/msg）

    /// 校长信箱留言条目（公开回复列表）
    struct MailboxMessage: Identifiable, Hashable {
        let id: Int
        /// 原始来信（标题/内容概述）
        let title: String
        /// 校方公开回复标题
        let showTitle: String
        /// 留言时间（服务端原始字符串，如 2026-08-13T00:00:00）
        let messageTime: String

        /// 规范日期文案：2026-08-13
        var dateText: String {
            messageTime.split(separator: "T").first.map(String.init) ?? messageTime
        }
    }

    /// 校长信箱页面数据快照
    struct MailboxPageData {
        let total: Int
        let messages: [MailboxMessage]
        /// 使用说明文本（"立即留言"模块正文，含电话/邮箱）
        let noticeText: String
    }

    // 校长信箱原始响应 DTO。
    // 服务端结构：data(标题层).data.message_list / leave_message_now —— 仅两层 data 嵌套，
    // 多建模一层会把 message_list 静默解码为 nil（成功返回 0 条，逻辑上"暂无数据"）。
    private struct SchoolMsgDTO: Codable {
        let data: SchoolMsgInnerDTO?
    }

    private struct SchoolMsgInnerDTO: Codable {
        let messageList: SchoolMsgListDTO?
        let leaveMessageNow: SchoolMsgTextDTO?

        enum CodingKeys: String, CodingKey {
            case messageList = "message_list"
            case leaveMessageNow = "leave_message_now"
        }
    }

    private struct SchoolMsgListDTO: Codable {
        let data: SchoolMsgListDataDTO?
    }

    private struct SchoolMsgListDataDTO: Codable {
        let total: Int?
        let list: [SchoolMsgItemDTO]?
    }

    private struct SchoolMsgItemDTO: Codable {
        let id: Int
        let title: String?
        let showTitle: String?
        let messageTime: String?

        enum CodingKeys: String, CodingKey {
            case id, title
            case showTitle = "show_title"
            case messageTime = "message_time"
        }
    }

    private struct SchoolMsgTextDTO: Codable {
        let data: String?
    }

    /// 拉取校长信箱页面数据（留言列表 + 使用说明；服务端支持 page/size 分页）
    func fetchPrincipalMailbox(page: Int, size: Int) async throws -> MailboxPageData {
        let dto: SchoolMsgDTO = try await get(
            "/school/msg",
            params: ["page": "\(page)", "size": "\(size)"],
            as: APIResponse<SchoolMsgDTO>.self
        ).requireData()

        let inner = dto.data
        let listDTO = inner?.messageList?.data
        let rawNotice = inner?.leaveMessageNow?.data ?? ""

        // 服务端文本使用 \r\n 与行首制表符，规范为 \n 并去除每行前导制表符
        let notice = rawNotice
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("\t") ? String($0.dropFirst()) : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let messages = (listDTO?.list ?? []).compactMap { item -> MailboxMessage? in
            guard let title = item.title, let showTitle = item.showTitle else { return nil }
            return MailboxMessage(
                id: item.id,
                title: title,
                showTitle: showTitle,
                messageTime: item.messageTime ?? ""
            )
        }
        return MailboxPageData(
            total: listDTO?.total ?? messages.count,
            messages: messages,
            noticeText: notice
        )
    }

    /// 校长信箱留言详情（点击信件卡片后展示；来信内容受隐私位保护）
    struct MailboxMessageDetail {
        /// 校方回复标题
        let showTitle: String
        /// 来信内容（is_show_content=0 时为服务端隐私占位文案）
        let content: String
        /// 是否公开展示来信内容（服务端隐私开关）
        let isShowContent: Bool
        /// 留言时间（服务端原始字符串）
        let messageTime: String
        /// 是否已回复（1=已回复）
        let isReplied: Int
        /// 校方回复正文
        let replyContent: String
        /// 回复时间（服务端原始字符串）
        let replyTime: String

        /// 规范日期文案：2026-08-13
        var messageDateText: String {
            messageTime.split(separator: "T").first.map(String.init) ?? messageTime
        }

        var replyDateText: String {
            replyTime.split(separator: "T").first.map(String.init) ?? replyTime
        }

        var replied: Bool { isReplied == 1 }
    }

    // 校长信箱详情原始响应 DTO（服务端字段全量蛇形命名）
    private struct SchoolMsgDetailDTO: Codable {
        let showTitle: String?
        let content: String?
        let isShowContent: String?
        let messageTime: String?
        let isReplied: Int?
        let replyContent: String?
        let replyTime: String?

        enum CodingKeys: String, CodingKey {
            case showTitle = "show_title"
            case content
            case isShowContent = "is_show_content"
            case messageTime = "message_time"
            case isReplied = "is_replied"
            case replyContent = "reply_content"
            case replyTime = "reply_time"
        }
    }

    /// 拉取校长信箱留言详情（/common/msg/detail；article_id/msg_id 均为留言 id，site_id 固定主站 1）
    func fetchMessageDetail(msgId: Int) async throws -> MailboxMessageDetail {
        let resp: APIResponse<SchoolMsgDetailDTO> = try await get(
            "/common/msg/detail",
            params: ["article_id": "\(msgId)", "site_id": "1", "msg_id": "\(msgId)"],
            as: APIResponse<SchoolMsgDetailDTO>.self
        )
        // 服务端对不存在的留言返回 code=200 + data=null + message="success"，
        // requireData 会抛出令人困惑的「服务器错误：success」——此处拦截并给出可读文案
        guard let dto = resp.data else {
            throw NetworkError.dataMissing("该信件详情暂不可用（可能已下架或超出展示期）")
        }

        return MailboxMessageDetail(
            showTitle: dto.showTitle ?? "",
            content: dto.content ?? "",
            isShowContent: dto.isShowContent == "1",
            messageTime: dto.messageTime ?? "",
            isReplied: dto.isReplied ?? 0,
            replyContent: dto.replyContent ?? "",
            replyTime: dto.replyTime ?? ""
        )
    }

    /// 机构部门首页数据
    struct DeptHome2DTO: Codable {
        let topBanners: DeptBannerDTO?
        let nav: [DeptNavItemDTO]?

        enum CodingKeys: String, CodingKey {
            case topBanners = "top_banners"
            case nav
        }
    }

    struct DeptBannerDTO: Codable {
        let titleCn: String?
        let maskSrc: String?
        let imgSrc: String?
        let href: String?

        enum CodingKeys: String, CodingKey {
            case titleCn = "title_cn"
            case maskSrc = "maskSrc"
            case imgSrc = "imgSrc"
            case href
        }
    }

    /// 导航项（首页、部门概况、教务动态等）
    struct DeptNavItemDTO: Codable {
        let columnId: String?
        let siteId: String?
        let titleCn: String?
        let titleEn: String?
        let path: String?
        let componentType: String?
        let children: [DeptNavItemDTO]?
        let data: [String: DeptSectionDTO]?
        let articles: DeptArticleListDTO?
        /// 2026-10-02 实证（马院等机构）：nav 项的 data 里可能直接含 `children` 键（DeptChildrenDTO，
        /// 形如 {"column_id":"...","children":{"total":2,"list":[...]}}），data 解码时该键会被当作
        /// DeptSectionDTO 尝试解码而失败丢弃 → 子栏目丢失。此字段在解码期单独捕获该键。
        let dataChildren: DeptChildrenDTO?

        enum CodingKeys: String, CodingKey {
            case columnId = "column_id"
            case siteId = "site_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case path, componentType, children, data, articles
        }

        /// 自定义解码：data 字典中混合了 DeptSectionDTO 对象和字符串元数据，
        /// 需要跳过非对象值避免解码失败
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            columnId = try container.decodeIfPresent(String.self, forKey: .columnId)
            siteId = try container.decodeIfPresent(String.self, forKey: .siteId)
            titleCn = try container.decodeIfPresent(String.self, forKey: .titleCn)
            titleEn = try container.decodeIfPresent(String.self, forKey: .titleEn)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            componentType = try container.decodeIfPresent(String.self, forKey: .componentType)
            children = try container.decodeIfPresent([DeptNavItemDTO].self, forKey: .children)
            articles = try container.decodeIfPresent(DeptArticleListDTO.self, forKey: .articles)

            // 自定义解码 data 字段：跳过字符串等非对象值
            var dataChildrenValue: DeptChildrenDTO?
            if container.contains(.data) {
                let dataContainer = try container.nestedContainer(keyedBy: DynamicCodingKeys.self, forKey: .data)
                var result: [String: DeptSectionDTO] = [:]
                for key in dataContainer.allKeys {
                    // data 里键名为 "children" 的 DeptChildrenDTO（马院等 nav 项结构）单独捕获
                    if key.stringValue == "children",
                       let childrenDTO = try? dataContainer.decode(DeptChildrenDTO.self, forKey: key) {
                        dataChildrenValue = childrenDTO
                        continue
                    }
                    if let section = try? dataContainer.decode(DeptSectionDTO.self, forKey: key) {
                        result[key.stringValue] = section
                    }
                }
                data = result.isEmpty ? nil : result
            } else {
                data = nil
            }
            dataChildren = dataChildrenValue
        }

        /// 标准编码（仅用于缓存，不需要特殊处理）
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(columnId, forKey: .columnId)
            try container.encodeIfPresent(siteId, forKey: .siteId)
            try container.encodeIfPresent(titleCn, forKey: .titleCn)
            try container.encodeIfPresent(titleEn, forKey: .titleEn)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encodeIfPresent(componentType, forKey: .componentType)
            try container.encodeIfPresent(children, forKey: .children)
            try container.encodeIfPresent(data, forKey: .data)
            try container.encodeIfPresent(articles, forKey: .articles)
        }
    }

    /// 动态编码键，用于遍历 data 字典
    private struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// 动态区块（首页 data 中的各个 section）
    struct DeptSectionDTO: Codable {
        let columnId: String?
        let siteId: String?
        let titleCn: String?
        let titleEn: String?
        let href: String?
        let componentType: String?
        let articles: DeptArticleListDTO?
        let children: DeptChildrenDTO?

        enum CodingKeys: String, CodingKey {
            case columnId = "column_id"
            case siteId = "site_id"
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case href, componentType, articles, children
        }
    }

    struct DeptChildrenDTO: Codable {
        let total: Int?
        let list: [DeptChildDTO]?
    }

    struct DeptChildDTO: Codable {
        let id: String?
        let titleCn: String?
        let titleEn: String?
        let isOut: Int?
        let href: String?
        let imageUrl: String?
        let siteId: String?
        let componentType: String?
        let articles: DeptArticleListDTO?
        /// 2026-10-02 实证（马院等部分机构）：子栏目文章列表可能内嵌在 `data` 键而非 `articles` 键
        /// （马院「学院简介」child：articles=null、data.total=1；信创/文法用 articles 键）。双键兼容。
        let data: DeptArticleListDTO?

        enum CodingKeys: String, CodingKey {
            case id
            case titleCn = "title_cn"
            case titleEn = "title_en"
            case isOut = "is_out"
            case href
            case imageUrl = "image_url"
            case siteId = "site_id"
            case componentType
            case articles
            case data
        }
    }

    struct DeptArticleListDTO: Codable {
        let total: Int?
        let list: [DeptArticleDTO]?
    }

    struct DeptArticleDTO: Codable, Identifiable {
        let id: String?
        let title: String?
        let description: String?
        let imageUrl: String?
        let createTime: String?
        let updateTime: String?
        let tag: String?
        let sort: Int?

        enum CodingKeys: String, CodingKey {
            case id, title, description, tag, sort
            case imageUrl = "image_url"
            case createTime = "create_time"
            case updateTime = "update_time"
        }
    }

    // MARK: - 师资（/common/teacher/page；teacher 型栏目专属，列接口对其返 500，2026-10-01 实证）

    /// 师资条目（`id` 数字型；`text` 为简介 HTML，含姓名/职称等富文本）
    struct TeacherDTO: Codable, Identifiable {
        let id: Int?
        let name: String?
        let position: String?
        let title: String?
        let text: String?
    }

    struct TeacherPageDTO: Codable {
        let total: Int?
        let list: [TeacherDTO]?
    }

    /// 师资分页（`is_leader` 必传：0=全部，1=领导；校验顺序 is_leader 先于 site_id，见 inventory §11.1-10）
    func fetchTeacherPage(siteId: String, page: Int = 1, size: Int = 40, isLeader: Int = 0) async throws -> TeacherPageDTO {
        let data = try await get("/common/teacher/page", params: [
            "site_id": siteId, "is_leader": "\(isLeader)", "page": "\(page)", "size": "\(size)"
        ], as: APIResponse<TeacherPageDTO>.self).requireData()
        return data
    }

    // MARK: - 招生录取查询（POST /common/recruit/query；idcard 需 RSA 加密——加密实现见设计稿 §8.1-5，实现期于真机取证后接入）

    /// 招生查询结果（命中 data.{name,major}；未命中 data:null；假数据 → 500）
    struct RecruitResultDTO: Codable {
        let name: String?
        let major: String?
    }

    /// 执行录取查询。`encryptedIdCard` 由 RSA 公钥加密（实现期从官网录取查询页 chunk 提取公钥，见设计稿 §8.1-5）。
    /// 合规：调用方须先弹「仅用于录取查询，提交即同意；不保存凭证」；本方法不落库、日志仅记 hash 痕迹。
    /// - Returns: 命中 → 结果；`data:null` → `nil`（未命中）；业务码非 200 → 抛 `NetworkError.serverError`。
    func queryRecruit(name: String, encryptedIdCard: String) async throws -> RecruitResultDTO? {
        let resp = try await post("/common/recruit/query", body: [
            "name": name, "idcard": encryptedIdCard
        ], as: APIResponse<RecruitResultDTO>.self)
        if let code = resp.code, code != 200 {
            throw NetworkError.serverError(resp.message ?? "查询失败")
        }
        return resp.data
    }
}

// MARK: - String 扩展：HTML 标签剥离

extension String {
    /// 去除 HTML 标签，返回纯文本。
    /// ⚠️ 纯正则实现，绝不使用 NSAttributedString(.documentType: .html)：
    /// NSAttributedString 的 HTML 解析会走 NSHTMLReader → WebKit 内部加载，
    /// 在主线程被调用时表现为 `-[NSHTMLReader _loadUsingWebKit]` 递归等待主队列，
    /// 造成主线程长时间挂起（UI 卡死，HangTracer 报 UIKit-runloop hang）。
    /// 线程安全，可在任意队列调用。
    func strippingHTMLTags() -> String {
        guard !self.isEmpty else { return self }

        // 无标签快速路径：仅做实体解码
        if !self.contains("<") {
            return Self.decodeHTMLEntities(self)
        }

        var result = self

        // 1. 移除 script/style 标签及其内容
        result = result.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )

        // 2. 块级标签 → 换行符（保留段落结构）
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
                         "</li>", "</tr>", "<br>", "<br/>", "<br />"]
        for tag in blockTags {
            result = result.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // 3. 移除剩余全部标签
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // 4. 解码 HTML 实体
        result = Self.decodeHTMLEntities(result)

        // 5. 清理多余空白
        result = result.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201c}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201d}")
            .replacingOccurrences(of: "&mdash;", with: "\u{2014}")
            .replacingOccurrences(of: "&ndash;", with: "\u{2013}")
    }
}