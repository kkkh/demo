//
//  RefererHeaderURLProtocol.swift
//  山西晋中理工学院 APP — 防盗链绕过 + 图片缓存修复
//
//  拦截发往学校服务器的请求：
//   1. 自动添加 Referer / User-Agent 头，解决 AVPlayer 等场景防盗链校验失败问题；
//   2. 修复全局图片无缓存问题（此前 .notAllowed 禁止一切缓存 + 每请求新建会话）：
//      - 共享静态 URLSession（连接复用，URLCache 随 URLCache.shared 扩容）；
//      - 缓存策略 .notAllowed → .allowed；
//      - 图片响应（Content-Type: image/*，或 URL 扩展名为常见图片格式）且服务器
//        未提供缓存头时，注入 Cache-Control: public, max-age=604800（7 天）；
//      - 缓存模式下图片请求使用 .returnCacheDataElseLoad（离线秒开），
//        即时模式使用 .useProtocolCachePolicy（遵循 HTTP 缓存语义）。
//

import Foundation

final class RefererHeaderURLProtocol: URLProtocol {
    private static let handledKey = "RefererHeaderURLProtocol.handled"
    private var dataTask: URLSessionDataTask?
    /// 网络监测台账 token（stopLoading 时幂等 abandon，防取消路径台账滞留）
    private var monitorToken: UInt64?

    // MARK: 共享会话（连接复用）

    /// 全局共享会话：所有被拦截请求复用同一连接池与 URLCache（URLCache.shared）
    /// 显式自注册（handledKey 防递归），不依赖全局注册时序
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.protocolClasses = [RefererHeaderURLProtocol.self]
        return URLSession(configuration: config)
    }()

    /// 常见图片扩展名（兜底判定，防止服务器返回怪异 Content-Type 时漏缓存）
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "jfif", "svg", "ico"
    ]

    /// 注入缓存头日志节流：每个 URL 仅首次记录，避免滚动场景日志抖动
    private static let loggedURLsLock = NSLock()
    private static var loggedURLs = Set<String>()

    // MARK: - URLProtocol Overrides

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url,
              url.scheme?.hasPrefix("http") == true,
              let host = url.host, host.contains("sxjzit.edu.cn") else {
            return false
        }
        // 避免拦截自己发出的请求造成无限递归
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest

        // 标记已处理，防止递归拦截
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        // 添加浏览器级别的 Referer 和 User-Agent，绕过防盗链校验
        mutableRequest.setValue("https://www.sxjzit.edu.cn/", forHTTPHeaderField: "Referer")
        mutableRequest.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        // 缓存模式联动：图片请求的缓存读取策略随模式切换
        if Self.isLikelyImageRequest(mutableRequest as URLRequest) {
            mutableRequest.cachePolicy = CacheModeManager.isCacheEnabledFromAnyThread
                ? .returnCacheDataElseLoad
                : .useProtocolCachePolicy
        }

        let original = mutableRequest as URLRequest

        // 网络监测埋点：请求开始契约（host 用于失败/慢请求归因）
        let monitorHost = original.url?.host
        let token = SJZNetworkMonitor.tapRequestStart(host: monitorHost)
        monitorToken = token
        // 上行估算：仅内存请求体（httpBody 可安全读取；流式上行不计量，诚实口径）
        SJZNetworkMonitor.tapUploadEstimate(for: original, token: token)

        dataTask = Self.sharedSession.dataTask(with: original) { [weak self] data, response, error in
            guard let self = self else { return }
            // 完成路径消费台账 token（避免 stopLoading 再误操作，仅保留取消路径的幂等 abandon）
            let token = self.monitorToken
            self.monitorToken = nil

            if let error = error {
                // 取消类终止不计入失败（用户滚动切换/页面退出属正常行为）
                if (error as? URLError)?.code == .cancelled {
                    if let token { SJZNetworkMonitor.tapAbandon(token: token) }
                } else {
                    if let token { SJZNetworkMonitor.tapComplete(token: token, success: false) }
                }
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response = response {
                // 首字节（响应头到达）时刻 → netmon TTFB 口径（2026-09-27：慢请求判定不受大文件下载时长拖累）
                if let token { SJZNetworkMonitor.tapFirstByte(token: token) }
                // .allowed：允许按 HTTP 语义缓存（图片经下文注入缓存头后实际入缓存）
                self.client?.urlProtocol(
                    self,
                    didReceive: Self.enhancedResponse(response, for: original),
                    cacheStoragePolicy: .allowed
                )
            }
            if let data = data {
                if let token { SJZNetworkMonitor.tapData(token: token, bytes: data.count) }
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let token { SJZNetworkMonitor.tapComplete(token: token, success: true) }
            self.client?.urlProtocolDidFinishLoading(self)

            Self.logImageResponseIfNeeded(response: response, request: original)
        }
        dataTask?.resume()
    }

    override func stopLoading() {
        if let token = monitorToken {
            monitorToken = nil
            SJZNetworkMonitor.tapAbandon(token: token)
        }
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: - 图片判定

    /// 依据 URL 特征预判是否为图片请求（扩展名、Accept 头或媒体路径段）
    private static func isLikelyImageRequest(_ request: URLRequest) -> Bool {
        let path = request.url?.path.lowercased() ?? ""
        if let ext = path.split(separator: ".").last,
           imageExtensions.contains(String(ext)) {
            return true
        }
        let accept = request.value(forHTTPHeaderField: "Accept")?.lowercased() ?? ""
        if accept.contains("image/") {
            return true
        }
        // 媒体路径特征兜底（如 /uploads/2024/12/abc 无扩展名图片）
        let components = request.url?.pathComponents.map { $0.lowercased() } ?? []
        return components.contains { mediaPathMarkers.contains($0) }
    }

    /// 媒体路径特征（兜底判定：Content-Type 缺失且 URL 无扩展名时，路径含这些段仍按图片处理）
    private static let mediaPathMarkers: Set<String> = [
        "uploads", "upload", "images", "image", "img", "pics", "pic",
        "media", "attach", "attachments", "file", "files", "photos", "picture"
    ]

    /// 依据响应特征判定是否为图片响应（Content-Type 优先，URL 扩展名与媒体路径兜底）
    private static func isImageResponse(_ response: HTTPURLResponse, for request: URLRequest) -> Bool {
        if let mime = response.mimeType?.lowercased(), mime.hasPrefix("image/") {
            return true
        }
        return isLikelyImageRequest(request)
    }

    // MARK: - 缓存头注入

    /// 图片响应且服务器未提供缓存头时注入 7 天缓存头；已有缓存头则原样保留（不覆盖服务端指令）
    private static func enhancedResponse(_ response: URLResponse, for request: URLRequest) -> URLResponse {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              isImageResponse(http, for: request) else {
            return response
        }
        let existing = (http.allHeaderFields["Cache-Control"] as? String)
            ?? (http.allHeaderFields["cache-control"] as? String) ?? ""
        // 尊重隐私指令 no-store；其余情况（缺失 / no-cache / max-age=0 等过弱指令）
        // 对图片注入 7 天缓存策略，保证滚动往返真正不复连
        guard !existing.lowercased().contains("no-store") else { return response }

        // allHeaderFields 为 [AnyHashable: Any]，需转换为 [String: String]
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                fields[keyString] = valueString
            }
        }
        fields["Cache-Control"] = "public, max-age=604800"
        if let url = http.url {
            return HTTPURLResponse(
                url: url,
                statusCode: http.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            ) ?? response
        }
        return response
    }

    // MARK: - 埋点（非主线程 → 投递到主线程写日志；每 URL 首见节流）

    private static func logImageResponseIfNeeded(response: URLResponse?, request: URLRequest) {
        guard let http = response as? HTTPURLResponse,
              isImageResponse(http, for: request),
              let urlString = request.url?.absoluteString else { return }

        let isHit: Bool = {
            guard let cached = URLCache.shared.cachedResponse(for: request),
                  let cachedHTTP = cached.response as? HTTPURLResponse else { return false }
            return (200...299).contains(cachedHTTP.statusCode)
        }()

        loggedURLsLock.lock()
        let isFirst = !loggedURLs.contains(urlString)
        if isFirst { loggedURLs.insert(urlString) }
        loggedURLsLock.unlock()

        guard isFirst else { return }

        let fileName = request.url?.lastPathComponent ?? urlString
        let cacheMode = CacheModeManager.isCacheEnabledFromAnyThread ? "cached" : "instant"
        Task { @MainActor in
            LogManager.shared.debugLog("urlProtocol", "图片响应经由协议层", context: [
                "url": fileName,
                "status": "\(http.statusCode)",
                "fromCache": "\(isHit)",
                "contentType": http.mimeType ?? "unknown",
                "cacheMode": cacheMode
            ])
        }
    }
}