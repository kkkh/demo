//
//  AnnouncementManager.swift
//  山西晋中理工学院 APP — 公告模块
//
//  从固定 Docusaurus 页面解析公告状态，判定开启/关闭。
//  本地缓存 + 定时后台刷新 + 无网络时展示缓存。
//  完全独立模块，不侵入现有资讯、收藏、图片缓存逻辑。
//

import Foundation
import SwiftUI

// MARK: - 公告缓存模型

/// 本地持久化的公告快照
struct AnnouncementCache: Codable {
    let title: String
    let content: String
    let isActive: Bool
    let fetchTime: Date
}

// MARK: - 公告管理器

@MainActor
final class AnnouncementManager: ObservableObject {
    static let shared = AnnouncementManager()

    // MARK: 发布状态

    /// 公告是否启用
    @Published var isActive: Bool = false
    /// 公告标题（开启时使用）
    @Published var title: String = ""
    /// 公告正文（HTML 已转为纯文本）
    @Published var content: String = ""
    /// 最近一次成功拉取时间
    @Published var lastFetchTime: Date?
    /// 是否正在加载
    @Published var isLoading: Bool = false
    /// 错误信息（中文，供 UI 展示）
    @Published var errorMessage: String?

    // MARK: 常量

    private let targetURL = "https://www.43322.cn/blog/gonggao"
    private let cacheKey = "announcementCache"
    private let refreshInterval: TimeInterval = 1800  // 30 分钟

    // MARK: 私有

    private var refreshTimer: Timer?
    private let urlSession: URLSession

    // MARK: 初始化

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // 显式注册协议层（不依赖全局注册时序，保证网络监测埋点覆盖）
        config.protocolClasses = [RefererHeaderURLProtocol.self]
        urlSession = URLSession(configuration: config)

        // 加载本地缓存
        loadCache()

        // 启动定时刷新
        startAutoRefresh()

        // 首次拉取
        Task { await fetchAnnouncement() }
    }

    // MARK: 公开方法

    /// 手动刷新公告
    func refresh() async {
        await fetchAnnouncement()
    }

    // MARK: 网络请求

    private func fetchAnnouncement() async {
        isLoading = true
        defer { isLoading = false }   // 守卫分支提前返回也能复位（2026-09-27 修复：非 200/编码异常等路径曾致转圈永久）
        errorMessage = nil

        guard let url = URL(string: targetURL) else {
            applyFallback("无效的目标 URL")
            LogManager.shared.error("announcement", "公告请求失败：无效 URL", context: ["url": targetURL])
            return
        }

        LogManager.shared.info("announcement", "公告请求开始", context: ["url": targetURL])

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                applyFallback("服务器无响应")
                LogManager.shared.error("announcement", "公告请求失败：非 HTTP 响应")
                return
            }

            guard httpResponse.statusCode == 200 else {
                applyFallback("服务器返回 \(httpResponse.statusCode)")
                LogManager.shared.error("announcement", "公告请求失败：HTTP \(httpResponse.statusCode)")
                return
            }

            guard let html = String(data: data, encoding: .utf8) else {
                applyFallback("页面编码异常")
                LogManager.shared.error("announcement", "公告解析失败：无法解码 HTML")
                return
            }

            // 解析 HTML
            let parsedTitle = extractTitle(from: html)
            let parsedContent = extractContent(from: html)

            guard let title = parsedTitle else {
                applyFallback("未找到文章标题")
                LogManager.shared.error("announcement", "公告解析失败：未找到标题")
                return
            }

            LogManager.shared.info("announcement", "公告解析成功", context: [
                "title": title,
                "contentLength": "\(parsedContent?.count ?? 0)"
            ])

            // 业务判定：纯文本匹配
            let active = title.contains("公告开启")
            let closed = title.contains("公告关闭")

            if active {
                LogManager.shared.info("announcement", "公告判定：开启", context: ["title": title])
                self.isActive = true
                self.title = title
                self.content = parsedContent ?? "暂无正文"
                self.lastFetchTime = Date()
                self.errorMessage = nil
                saveCache()
            } else if closed {
                LogManager.shared.info("announcement", "公告判定：关闭（标题含公告关闭）", context: ["title": title])
                self.isActive = false
                self.title = ""
                self.content = ""
                self.lastFetchTime = Date()
                self.errorMessage = nil
                saveCache()
            } else {
                LogManager.shared.info("announcement", "公告判定：关闭（标题不含公告开启）", context: ["title": title])
                self.isActive = false
                self.title = ""
                self.content = ""
                self.lastFetchTime = Date()
                self.errorMessage = nil
                saveCache()
            }

        } catch let error as URLError {
            let msg: String
            switch error.code {
            case .timedOut:
                msg = "请求超时，已使用缓存数据"
            case .notConnectedToInternet, .networkConnectionLost:
                msg = "网络未连接，已使用缓存数据"
            default:
                msg = "网络异常，已使用缓存数据"
            }
            applyFallback(msg)
            LogManager.shared.error("announcement", "公告请求网络失败", context: [
                "error": error.localizedDescription,
                "code": "\(error.code.rawValue)"
            ])
        } catch {
            applyFallback("请求失败，已使用缓存数据")
            LogManager.shared.error("announcement", "公告请求异常", context: [
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: HTML 解析

    /// 从 Docusaurus HTML 中提取文章标题
    /// 匹配：<h1 itemprop="headline">标题文本</h1>
    private func extractTitle(from html: String) -> String? {
        guard let startRange = html.range(of: "<h1 itemprop=\"headline\">") else {
            return nil
        }
        let afterStart = html[startRange.upperBound...]
        guard let endRange = afterStart.range(of: "</h1>") else {
            return nil
        }
        let rawTitle = String(afterStart[..<endRange.lowerBound])
        // 去除 HTML 实体和多余空白
        return rawTitle
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 Docusaurus HTML 中提取文章正文并转为纯文本
    /// 匹配：<div id="__blog-post-container" ... itemprop="articleBody">...内容...</div>
    private func extractContent(from html: String) -> String? {
        guard let startRange = html.range(of: "id=\"__blog-post-container\"") else {
            return nil
        }
        let remainder = html[startRange.lowerBound...]

        // 找到 articleBody div 的开始标签结束位置
        guard let tagEndRange = remainder.range(of: ">") else {
            return nil
        }
        let afterTag = remainder[tagEndRange.upperBound...]

        // 提取内容直到下一个 </div>（需要正确匹配嵌套层级）
        // 由于 Docusaurus 的文章正文 div 内部还有嵌套 div，需要追踪层级
        let contentHTML = extractDivContent(from: String(afterTag))
        return htmlToPlainText(contentHTML)
    }

    /// 从 HTML 中提取首个 div 的内容（处理嵌套）
    private func extractDivContent(from html: String) -> String {
        var depth = 0
        var result = ""
        var index = html.startIndex

        while index < html.endIndex {
            // 检查 </div>
            if html[index...].hasPrefix("</div>") {
                if depth == 0 {
                    break
                }
                depth -= 1
                result.append("</div>")
                index = html.index(index, offsetBy: 6)
                continue
            }
            // 检查 <div
            if html[index...].hasPrefix("<div") {
                // 确认是 <div> 或 <div ...> 标签开始
                let remaining = html[index...]
                if let nextChar = remaining.dropFirst(4).first,
                   nextChar == ">" || nextChar == " " {
                    depth += 1
                }
            }
            result.append(html[index])
            index = html.index(after: index)
        }
        return result
    }

    /// 将 HTML 转为纯文本。
    /// ⚠️ 纯正则实现（复用全局 strippingHTMLTags），绝不用 NSAttributedString(.html)：
    /// 后者会走 NSHTMLReader → WebKit 内部加载，主线程调用时表现为
    /// `-[NSHTMLReader _loadUsingWebKit]` 递归等待主队列 → UI 卡死（HangTracer hang）。
    private func htmlToPlainText(_ html: String) -> String {
        html.strippingHTMLTags()
    }

    // MARK: 降级策略

    private func applyFallback(_ message: String) {
        // 有缓存则沿用缓存，不清空当前状态
        if let cache = loadCacheFromDisk() {
            self.isActive = cache.isActive
            self.title = cache.title
            self.content = cache.content
            self.errorMessage = message
        } else {
            // 无缓存：显示公告未开启
            self.isActive = false
            self.title = ""
            self.content = ""
            self.errorMessage = message
        }
    }

    // MARK: 缓存

    private func saveCache() {
        let cache = AnnouncementCache(
            title: title,
            content: content,
            isActive: isActive,
            fetchTime: lastFetchTime ?? Date()
        )
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func loadCache() {
        guard let cache = loadCacheFromDisk() else { return }
        self.isActive = cache.isActive
        self.title = cache.title
        self.content = cache.content
        self.lastFetchTime = cache.fetchTime
    }

    private func loadCacheFromDisk() -> AnnouncementCache? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(AnnouncementCache.self, from: data) else {
            return nil
        }
        return cache
    }

    // MARK: 定时刷新

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchAnnouncement()
            }
        }
    }

    /// 停止定时器（App 进入后台时可调用）
    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}