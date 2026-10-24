//
//  PrivacyManager.swift
//  山西晋中理工学院 APP — 隐私协议管理器
//
//  核心逻辑：网络拉取最新协议 → 本地缓存 → 离线兜底文本
//  约束：禁止 @AppStorage + didSet；禁止 @Sendable Task 捕获 inout
//

import Foundation
import SwiftUI

// MARK: - 隐私文档类型

enum PrivacyDocumentType: String, CaseIterable, Identifiable {
    case terms       = "terms"
    case privacy     = "privacy-policy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms:   return "用户协议"
        case .privacy: return "隐私政策"
        }
    }

    var icon: String {
        switch self {
        case .terms:   return "doc.text.fill"
        case .privacy: return "hand.raised.fill"
        }
    }

    var url: String {
        switch self {
        case .terms:   return "https://www.43322.cn/blog/terms"
        case .privacy: return "https://www.43322.cn/blog/privacy-policy"
        }
    }

    var fallbackText: String {
        switch self {
        case .terms:   return UserAgreementText.fullText
        case .privacy: return PrivacyPolicyText.fullText
        }
    }

    var fallbackTitle: String {
        switch self {
        case .terms:   return UserAgreementText.title
        case .privacy: return PrivacyPolicyText.title
        }
    }

    var fallbackLastUpdated: String {
        switch self {
        case .terms:   return UserAgreementText.lastUpdated
        case .privacy: return PrivacyPolicyText.lastUpdated
        }
    }
}

// MARK: - 隐私文档内容模型

struct PrivacyDocument {
    let title: String
    let content: String
    let lastUpdated: String?
    let source: PrivacyDocumentSource
}

enum PrivacyDocumentSource: String {
    case online  = "online"
    case offline = "offline"
}

// MARK: - 隐私缓存模型

struct PrivacyCacheEntry: Codable {
    let content: String
    let title: String
    let lastUpdated: String?
    let fetchTime: TimeInterval
    let source: String
}

// MARK: - 隐私管理器

@MainActor
final class PrivacyManager: ObservableObject {
    static let shared = PrivacyManager()

    @Published private(set) var cachedDocuments: [PrivacyDocumentType: PrivacyDocument] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentError: String?

    private let cacheKey = "privacy_documents_cache"
    private let cacheCooldown: TimeInterval = 1800 // 30 分钟冷却
    private let requestTimeout: TimeInterval = 15.0
    private let moduleName = "privacy"

    private init() {
        loadFromCache()
    }

    // MARK: - 获取文档

    func fetchDocument(type: PrivacyDocumentType) async -> PrivacyDocument {
        // 1. 检查缓存是否在冷却期
        if let cached = cachedDocuments[type], cached.source == .online {
            if let cacheEntry = readCacheEntry(for: type) {
                let elapsed = Date().timeIntervalSince1970 - cacheEntry.fetchTime
                if elapsed < cacheCooldown {
                    LogManager.shared.info(moduleName, "缓存命中（冷却期内），跳过网络请求", context: ["type": type.rawValue, "elapsed": "\(String(format: "%.0f", elapsed))s"])
                    return cached
                }
            }
        }

        // 2. 尝试网络拉取
        isLoading = true
        currentError = nil
        LogManager.shared.info(moduleName, "开始网络拉取文档", context: ["type": type.rawValue, "url": type.url])

        let onlineResult = await fetchOnlineDocument(type: type)
        if let onlineDoc = onlineResult {
            isLoading = false
            LogManager.shared.info(moduleName, "网络拉取成功", context: ["type": type.rawValue, "source": onlineDoc.source.rawValue])
            return onlineDoc
        }

        // 3. 网络失败，尝试缓存
        if let cached = cachedDocuments[type] {
            isLoading = false
            LogManager.shared.warning(moduleName, "网络失败，使用本地缓存", context: ["type": type.rawValue, "source": cached.source.rawValue])
            return cached
        }

        // 4. 缓存也无，使用内置离线兜底文本
        isLoading = false
        let fallback = getFallbackDocument(type: type)
        LogManager.shared.warning(moduleName, "网络和缓存均失败，使用内置离线兜底文本", context: ["type": type.rawValue])
        return fallback
    }

    // MARK: - 网络拉取

    private func fetchOnlineDocument(type: PrivacyDocumentType) async -> PrivacyDocument? {
        guard let url = URL(string: type.url) else {
            LogManager.shared.error(moduleName, "URL 无效", context: ["url": type.url])
            currentError = "URL 无效"
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 设置 User-Agent 模拟浏览器，确保 Docusaurus 返回完整 HTML
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                LogManager.shared.error(moduleName, "非 HTTP 响应", context: ["type": type.rawValue])
                currentError = "服务器响应异常"
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                LogManager.shared.error(moduleName, "HTTP 状态码异常", context: ["type": type.rawValue, "status": "\(httpResponse.statusCode)"])
                currentError = "服务器返回错误（\(httpResponse.statusCode)）"
                return nil
            }

            guard let htmlString = String(data: data, encoding: .utf8) else {
                LogManager.shared.error(moduleName, "HTML 解码失败", context: ["type": type.rawValue])
                currentError = "数据解析失败"
                return nil
            }

            // 解析 Docusaurus 博客页面内容
            let parsed = parseDocusaurusContent(html: htmlString, type: type)
            if let document = parsed {
                // 缓存到本地
                saveToCache(type: type, document: document)
                return document
            } else {
                LogManager.shared.error(moduleName, "HTML 内容解析失败", context: ["type": type.rawValue])
                currentError = "内容解析失败"
                return nil
            }

        } catch let error as URLError {
            LogManager.shared.error(moduleName, "网络请求失败", context: ["type": type.rawValue, "error": error.localizedDescription])
            switch error.code {
            case .timedOut:
                currentError = "网络请求超时，请检查网络连接后重试"
            case .notConnectedToInternet, .networkConnectionLost:
                currentError = "网络连接不可用，已为您展示离线版本"
            default:
                currentError = "网络异常，已为您展示离线版本"
            }
            return nil
        } catch {
            LogManager.shared.error(moduleName, "未知错误", context: ["type": type.rawValue, "error": error.localizedDescription])
            currentError = "加载失败，已为您展示离线版本"
            return nil
        }
    }

    // MARK: - Docusaurus 内容解析

    private func parseDocusaurusContent(html: String, type: PrivacyDocumentType) -> PrivacyDocument? {
        let title = extractTitle(from: html, type: type)
        let lastUpdated = extractDate(from: html, type: type)
        let content = extractArticleContent(from: html, type: type)

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PrivacyDocument(
            title: title,
            content: content,
            lastUpdated: lastUpdated,
            source: .online
        )
    }

    private func extractTitle(from html: String, type: PrivacyDocumentType) -> String {
        // 尝试从 <h1> 标签提取
        if let h1Range = html.range(of: "<h1[^>]*>[\\s\\S]*?</h1>", options: .regularExpression) {
            let h1Content = String(html[h1Range])
            let stripped = h1Content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        // 尝试从 <title> 标签提取
        if let titleRange = html.range(of: "<title>([\\s\\S]*?)</title>", options: .regularExpression) {
            let titleContent = String(html[titleRange])
            let stripped = titleContent
                .replacingOccurrences(of: "<title>", with: "")
                .replacingOccurrences(of: "</title>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return type.fallbackTitle
    }

    private func extractDate(from html: String, type: PrivacyDocumentType) -> String? {
        // 尝试从 <time> 标签提取
        if let timeRange = html.range(of: "<time[^>]*datetime=\"([^\"]+)\"", options: .regularExpression) {
            let timeStr = String(html[timeRange])
            if let dateRange = timeStr.range(of: "datetime=\"([^\"]+)\"", options: .regularExpression) {
                let dateStr = String(timeStr[dateRange])
                    .replacingOccurrences(of: "datetime=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if dateStr.count >= 10 {
                    return String(dateStr.prefix(10))
                }
            }
        }
        // 尝试从 meta 标签提取
        if let metaRange = html.range(of: "<meta[^>]*property=\"article:published_time\"[^>]*content=\"([^\"]+)\"", options: .regularExpression) {
            let metaStr = String(html[metaRange])
            if let contentRange = metaStr.range(of: "content=\"([^\"]+)\"", options: .regularExpression) {
                let dateStr = String(metaStr[contentRange])
                    .replacingOccurrences(of: "content=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if dateStr.count >= 10 {
                    return String(dateStr.prefix(10))
                }
            }
        }
        return type.fallbackLastUpdated
    }

    private func extractArticleContent(from html: String, type: PrivacyDocumentType) -> String {
        // 使用 NSRegularExpression 进行跨行匹配
        var articleHTML = ""

        // 尝试提取 <article> 标签内的内容
        if let articleMatch = firstMatch(pattern: "<article[^>]*>([\\s\\S]*?)</article>", in: html) {
            articleHTML = articleMatch
        } else {
            // 回退到整个 body 内容
            if let bodyMatch = firstMatch(pattern: "<body[^>]*>([\\s\\S]*?)</body>", in: html) {
                articleHTML = bodyMatch
            } else {
                articleHTML = html
            }
        }

        // 移除 script 和 style 标签
        var cleaned = articleHTML.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )

        // 移除导航元素
        cleaned = cleaned.replacingOccurrences(
            of: "<nav[^>]*>[\\s\\S]*?</nav>",
            with: "",
            options: .regularExpression
        )

        // 移除 footer
        cleaned = cleaned.replacingOccurrences(
            of: "<footer[^>]*>[\\s\\S]*?</footer>",
            with: "",
            options: .regularExpression
        )

        // 将块级标签替换为换行
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "</li>", "<br>", "<br/>", "<br />"]
        for tag in blockTags {
            cleaned = cleaned.replacingOccurrences(of: tag, with: "\n")
        }

        // 移除所有剩余 HTML 标签
        cleaned = cleaned.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // 解码 HTML 实体
        cleaned = cleaned
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#x27;", with: "'")

        // 清理多余空白
        let lines = cleaned.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n\n")
    }

    /// 使用 NSRegularExpression 进行第一次匹配，返回匹配的完整字符串
    private func firstMatch(pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range) else {
            return nil
        }
        guard let range = Range(match.range, in: string) else { return nil }
        return String(string[range])
    }

    // MARK: - 缓存管理

    private func saveToCache(type: PrivacyDocumentType, document: PrivacyDocument) {
        let entry = PrivacyCacheEntry(
            content: document.content,
            title: document.title,
            lastUpdated: document.lastUpdated,
            fetchTime: Date().timeIntervalSince1970,
            source: document.source.rawValue
        )

        do {
            let data = try JSONEncoder().encode(entry)
            UserDefaults.standard.set(data, forKey: "\(cacheKey)_\(type.rawValue)")
            cachedDocuments[type] = document
            LogManager.shared.info(moduleName, "文档已缓存", context: ["type": type.rawValue, "size": "\(data.count)bytes"])
        } catch {
            LogManager.shared.error(moduleName, "缓存编码失败", context: ["type": type.rawValue, "error": error.localizedDescription])
        }
    }

    private func readCacheEntry(for type: PrivacyDocumentType) -> PrivacyCacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: "\(cacheKey)_\(type.rawValue)") else {
            return nil
        }
        do {
            return try JSONDecoder().decode(PrivacyCacheEntry.self, from: data)
        } catch {
            LogManager.shared.warning(moduleName, "缓存解码失败", context: ["type": type.rawValue, "error": error.localizedDescription])
            return nil
        }
    }

    private func loadFromCache() {
        for type in PrivacyDocumentType.allCases {
            if let entry = readCacheEntry(for: type) {
                let source: PrivacyDocumentSource = entry.source == "online" ? .online : .offline
                let doc = PrivacyDocument(
                    title: entry.title,
                    content: entry.content,
                    lastUpdated: entry.lastUpdated,
                    source: source
                )
                cachedDocuments[type] = doc
                LogManager.shared.info(moduleName, "从缓存加载文档", context: ["type": type.rawValue, "source": source.rawValue])
            }
        }
    }

    // MARK: - 离线兜底

    private func getFallbackDocument(type: PrivacyDocumentType) -> PrivacyDocument {
        return PrivacyDocument(
            title: type.fallbackTitle,
            content: type.fallbackText,
            lastUpdated: type.fallbackLastUpdated,
            source: .offline
        )
    }

    func getCachedDocument(type: PrivacyDocumentType) -> PrivacyDocument? {
        return cachedDocuments[type] ?? readCacheEntry(for: type).map { entry in
            let source: PrivacyDocumentSource = entry.source == "online" ? .online : .offline
            return PrivacyDocument(
                title: entry.title,
                content: entry.content,
                lastUpdated: entry.lastUpdated,
                source: source
            )
        }
    }

    // MARK: - 清除缓存

    func clearCache() {
        for type in PrivacyDocumentType.allCases {
            UserDefaults.standard.removeObject(forKey: "\(cacheKey)_\(type.rawValue)")
            cachedDocuments[type] = nil
        }
        LogManager.shared.info(moduleName, "隐私文档缓存已清除")
    }
}