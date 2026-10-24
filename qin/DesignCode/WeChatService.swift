//
//  WeChatService.swift
//  山西晋中理工学院 APP — 微信开放平台 SDK 集成（OpenSDK 2.0.8，官方含支付版）
//
//  官方文档（本文件实现依据）：
//  · SDK 下载页     https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Downloads/iOS_Resource.html
//  · iOS 接入指南   https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/iOS.html
//  · 分享与收藏     https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Share_and_Favorites/iOS.html
//  · 微信登录       https://developers.weixin.qq.com/doc/oplatform/Mobile_App/WeChat_Login/Development_Guide.html
//  · 小程序跳转     https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Launching_a_Mini_Program/Launching_mini_program_by_app.html
//  · Universal Link https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Universal_Link.html
//
//  官方接入四要件（本文件全部实现）：
//  ① Info.plist：CFBundleURLTypes（URL Scheme = AppID 本身）+ LSApplicationQueriesSchemes
//     （weixin / weixinULAPI / weixinURLParamsAPI，须在前 50 条内）；
//  ② 启动注册：WXApi.registerApp(_:universalLink:)（主线程；本工程在用户同意隐私协议后注册）；
//  ③ 回跳处理：WXApi.handleOpenURL / handleOpenUniversalLink
//     （SwiftUI 生命周期下由 .onOpenURL / .onContinueUserActivity 送达）；
//  ④ 关联域名：DesignCode.entitlements（applinks:<域名>）+ 服务端 AASA
//     （https://<域名>/.well-known/apple-app-site-association）。
//
//  能力矩阵：分享（会话 / 朋友圈 / 收藏）、微信登录、小程序跳转、安装与版本检测、
//  Universal Link 七步自检、SDK 日志桥接（接入工程 LogManager，域 "wechat"）。
//
//  配置单点：Target 构建设置 WECHAT_APPID / WECHAT_UNIVERSAL_LINK / WECHAT_UL_HOST / WECHAT_MINI_PROGRAM
//  → Info.plist 变量注入（$(...)），改一处即全链生效。
//  未配置（占位值）时：所有入口给出「未配置」状态与日志，不发任何微信请求，不影响其它功能。
//

import Foundation
import Combine
import UIKit
import WechatOpenSDK

// MARK: - 微信分享目标场景

/// 分享目标场景。scene 取值对齐官方 WXScene 枚举（0 会话 / 1 朋友圈 / 2 收藏）；
/// 以 Int32 直传，规避 C 枚举在 Swift 中的导入类型差异。
enum WeChatScene: String, CaseIterable, Identifiable {
    case session
    case timeline
    case favorite

    var id: String { rawValue }

    /// 官方 WXScene 枚举值
    var sceneValue: Int32 {
        switch self {
        case .session:  return 0
        case .timeline: return 1
        case .favorite: return 2
        }
    }

    var title: String {
        switch self {
        case .session:  return "微信好友"
        case .timeline: return "朋友圈"
        case .favorite: return "微信收藏"
        }
    }

    var subtitle: String {
        switch self {
        case .session:  return "发送给好友或群聊"
        case .timeline: return "分享到朋友圈"
        case .favorite: return "保存到微信收藏"
        }
    }

    var symbolName: String {
        switch self {
        case .session:  return "bubble.left.and.bubble.right.fill"
        case .timeline: return "circle.hexagongrid.fill"
        case .favorite: return "bookmark.fill"
        }
    }

    var logName: String { rawValue }
}

// MARK: - 微信配置（单点：构建设置 → Info.plist 变量注入）

/// 微信开放平台配置快照。
/// 真实值只需改一处：Target 构建设置 `WECHAT_APPID` / `WECHAT_UNIVERSAL_LINK` / `WECHAT_UL_HOST` /
/// `WECHAT_MINI_PROGRAM`（Debug 与 Release 各一份），Info.plist 与 entitlements 通过 `$(...)` 自动替换。
struct WeChatConfiguration {
    /// 占位 AppID（未被替换时全链按「未配置」处理，绝不发起微信请求）
    static let placeholderAppID = "wxPLACEHOLDER0000"
    /// 占位 Universal Link
    static let placeholderUniversalLink = "https://example.com/app/"

    let appID: String
    let universalLink: String
    /// 小程序原始 ID（gh_ 开头）；缺省为空表示未配置小程序能力
    let miniProgramID: String

    /// 占位/缺失判定：任一关键项缺失或仍为占位值即视为未配置
    var isPlaceholder: Bool {
        let id = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ul = universalLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id.contains("PLACEHOLDER") { return true }
        if ul.isEmpty || !ul.lowercased().hasPrefix("https://") || ul.contains("example.com") { return true }
        return false
    }

    /// 官方 AppID 形如 wx + 16 位十六进制
    var hasValidAppIDFormat: Bool {
        let pattern = "^wx[0-9a-fA-F]{16}$"
        return appID.range(of: pattern, options: .regularExpression) != nil
    }

    /// 小程序原始 ID 是否可用（gh_ 开头且非占位）
    var hasMiniProgram: Bool {
        let id = miniProgramID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !id.contains("PLACEHOLDER") && id.hasPrefix("gh_")
    }

    /// Universal Link 主机名（日志与界面展示用）
    var universalLinkHost: String {
        URL(string: universalLink)?.host ?? "—"
    }

    /// AppID 掩码展示（设置页展示，避免长串干扰阅读）
    var maskedAppID: String {
        guard appID.count > 8 else { return appID.isEmpty ? "—" : appID }
        return "\(appID.prefix(6))…\(appID.suffix(4))"
    }

    /// 从 Info.plist 读取：URL Scheme（wx 开头）即 AppID；其余为自定义键
    static func load(bundle: Bundle = .main) -> WeChatConfiguration {
        var appID = ""
        if let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] {
            for type in urlTypes {
                guard let schemes = type["CFBundleURLSchemes"] as? [String] else { continue }
                if let wx = schemes.first(where: { $0.lowercased().hasPrefix("wx") }) {
                    appID = wx
                    break
                }
            }
        }
        let ul = (bundle.object(forInfoDictionaryKey: "WeChatUniversalLink") as? String) ?? ""
        let mini = (bundle.object(forInfoDictionaryKey: "WeChatMiniProgramID") as? String) ?? ""
        return WeChatConfiguration(appID: appID, universalLink: ul, miniProgramID: mini)
    }
}

// MARK: - 微信可用性

/// 微信能力可用性（状态机；界面与日志的统一判据）
enum WeChatAvailability: String, Equatable {
    /// 未配置（占位值未被替换）
    case unconfigured
    /// 配置已就绪但 SDK 注册失败
    case sdkNotRegistered
    /// 未安装微信
    case weChatNotInstalled
    /// 微信版本过低（不支持 OpenApi）
    case weChatVersionTooLow
    /// 全部就绪
    case ready

    /// 简短状态（设置页徽章）
    var shortTitle: String {
        switch self {
        case .unconfigured:       return "未配置"
        case .sdkNotRegistered:   return "注册失败"
        case .weChatNotInstalled: return "未安装微信"
        case .weChatVersionTooLow: return "微信版本过低"
        case .ready:              return "已就绪"
        }
    }

    /// 用户可读说明（横幅 / 卡片）
    var userHint: String {
        switch self {
        case .unconfigured:
            return "微信功能尚未配置：请在工程构建设置中填写 WECHAT_APPID 与 WECHAT_UNIVERSAL_LINK"
        case .sdkNotRegistered:
            return "微信 SDK 注册未成功，请稍后重试"
        case .weChatNotInstalled:
            return "未检测到微信，请先安装微信后使用"
        case .weChatVersionTooLow:
            return "当前微信版本过低，请升级微信后使用"
        case .ready:
            return "微信已就绪"
        }
    }

    /// 是否可执行微信操作
    var canOperate: Bool { self == .ready }
}

// MARK: - 分享载荷

/// 分享载荷：网页卡片（标题 + 摘要 + 链接 + 缩略图）
struct WeChatSharePayload: Identifiable {
    let id = UUID()
    var title: String
    var description: String
    var urlString: String
    /// 缩略图 URL（优先命中内存解码缓存，未命中才走网络）
    var thumbImageURL: String?
    /// 已在内存中的缩略图（详情页已加载图，命中即用，免二次下载）
    var thumbImage: UIImage?

    var urlHost: String { URL(string: urlString)?.host ?? urlString }

    /// 官方硬限制：标题 ≤512 字节、描述 ≤1024 字节（UTF-8）
    var clippedTitle: String {
        WeChatText.clip(title, maxBytes: 512, fallback: "园枢 · 山西晋中理工学院")
    }
    var clippedDescription: String {
        WeChatText.clip(description, maxBytes: 1024, fallback: urlString)
    }
}

/// 文本工具（官方字节级限制的唯一实现点，供测试契约断言）
enum WeChatText {
    /// 按 UTF-8 字节数裁剪（不切断多字节字符；超限截断并追加省略号）
    static func clip(_ text: String, maxBytes: Int, fallback: String = "") -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.utf8.count <= maxBytes { return trimmed }
        let ellipsisBytes = "…".utf8.count
        var result = ""
        var used = 0
        for ch in trimmed {
            let size = String(ch).utf8.count
            if used + size + ellipsisBytes > maxBytes { break }
            result.append(ch)
            used += size
        }
        return result + "…"
    }
}

// MARK: - 微信错误码（对齐官方 WXErrCode 枚举，避免 C 枚举导入差异）
//
// 官方定义：Common = -1 普通错误 / UserCancel = -2 用户取消 / SentFail = -3 发送失败 /
//          AuthDeny = -4 授权拒绝 / Unsupport = -5 微信不支持。

private enum WeChatErrCode {
    static let success: Int32 = 0
    static let common: Int32 = -1
    static let userCancel: Int32 = -2
    static let sentFail: Int32 = -3
    static let authDeny: Int32 = -4
    static let unsupport: Int32 = -5

    static func describe(_ code: Int32) -> String {
        switch code {
        case success:    return "成功"
        case common:     return "普通错误"
        case userCancel: return "用户取消"
        case sentFail:   return "发送失败"
        case authDeny:   return "授权拒绝"
        case unsupport:  return "微信不支持"
        default:         return "未知错误"
        }
    }
}

// MARK: - 全局横幅（回跳结果 / 状态提示）

/// 全局横幅：展示微信操作结果（分享回执 / 登录回执 / 状态提示），由根视图悬浮呈现并自动消隐
struct WeChatBanner: Identifiable, Equatable {
    enum Kind: String {
        case success, info, failure
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let date = Date()
}

// MARK: - Universal Link 自检结果

/// 自检单步结果（对齐官方 WXULCheckStep 七步）
struct WeChatSelfCheckItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let success: Bool
    let errorInfo: String
    let suggestion: String
}

/// 自检收集器：官方自检回调可能在任意线程、多次回调（含拉起微信后回跳），
/// 由 actor 串行收纳；`finish()` 幂等，保证 wait 与超时兜底只结算一次。
actor WeChatSelfCheckCollector {
    private var items: [Int: WeChatSelfCheckItem] = [:]
    private var continuation: CheckedContinuation<[WeChatSelfCheckItem], Never>?
    private var finished = false

    var sorted: [WeChatSelfCheckItem] { items.values.sorted { $0.id < $1.id } }

    @discardableResult
    func record(_ item: WeChatSelfCheckItem) -> [WeChatSelfCheckItem] {
        items[item.id] = item
        return sorted
    }

    func wait() async -> [WeChatSelfCheckItem] {
        if finished { return sorted }
        return await withCheckedContinuation { cont in
            if finished { cont.resume(returning: sorted) } else { continuation = cont }
        }
    }

    func finish() {
        finished = true
        let snapshot = sorted
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

// MARK: - 分享内容类型（回执归因：网页卡片 / 长图）

/// 分享内容类型：用于回执文案与日志区分（分享动作共用 onResp 归因通道）
enum WeChatShareKind: String {
    /// 网页卡片（WXWebpageObject）
    case webpage
    /// 长图（WXImageObject）
    case longImage

    var logName: String { rawValue }

    /// 发起/回执日志用词
    var noun: String { self == .webpage ? "分享" : "长图分享" }

    /// 成功横幅
    func successText(scene: WeChatScene) -> String {
        self == .webpage ? "已分享到\(scene.title)" : "长图已分享到\(scene.title)"
    }

    /// 取消横幅
    var cancelText: String { self == .webpage ? "已取消分享" : "已取消长图分享" }
}

// MARK: - 长图编码器（官方 imageData ≤10MB，逐档降质/降采样并留痕）

/// 官方约束（《分享与收藏 · iOS 开发手册》图片类型分享示例）：
/// `WXImageObject.imageData` 内容大小不超过 10MB，`thumbData` 不超过 32KB。
/// 本编码器把长图压入上限内：先按质量档位压缩，仍超限则等比降采样后重试。
@MainActor
enum WeChatImageEncoder {
    /// 官方上限：10MB（SDK 头文件注记 25M，此处按更严格的官方文档口径执行）
    /// nonisolated：默认参数在非隔离上下文求值（否则 Swift 6 语言模式下报隔离错误）
    nonisolated static let maxImageBytes = 10 * 1024 * 1024

    struct Result {
        let data: Data
        let pixelSize: CGSize
        let quality: CGFloat
        let scale: CGFloat
        /// 是否触发了降档（用于 UI 提示与日志）
        var adjusted: Bool { scale < 1.0 || quality < 0.92 }
    }

    /// 质量档位（首档与系统分享面板路径一致，保证观感统一）
    nonisolated static let qualities: [CGFloat] = [0.92, 0.8, 0.68, 0.56, 0.44]
    /// 降采样档位（1.0 为原尺寸）
    nonisolated static let scales: [CGFloat] = [1.0, 0.75, 0.6, 0.45, 0.34]
    /// 首次尝试的像素预算（40MP，与长图渲染画布上限一致）：
    /// 超过预算的大尺寸档位直接跳过——满尺寸 JPEG 尝试在超大图上既慢又占内存（叠加画布可能触发系统终止）
    nonisolated static let maxFirstAttemptPixels: Double = 40_000_000

    /// 首个满足像素预算的档位下标（纯函数，契约测试锚点）
    nonisolated static func firstScaleIndex(pixelCount: Double) -> Int {
        for (index, scale) in scales.enumerated() where pixelCount * Double(scale * scale) <= maxFirstAttemptPixels {
            return index
        }
        return scales.count - 1
    }

    static func encode(_ image: UIImage, maxBytes: Int = WeChatImageEncoder.maxImageBytes) -> Result? {
        // 必须用**像素**尺寸：image.size 是点、随自适应倍率变化（用点会低估预算与降采样倍率）
        let sourcePixels = SJZImageIntegrity.pixelSize(of: image)
        let pixelCount = Double(sourcePixels.width * sourcePixels.height)
        let startIndex = firstScaleIndex(pixelCount: pixelCount)
        if startIndex > 0 {
            LogManager.shared.info("wechat", "长图编码跳过大尺寸档位（像素预算）", context: [
                "pixel": "\(Int(pixelCount))",
                "budget": "\(Int(maxFirstAttemptPixels))",
                "startScale": String(format: "%.2f", scales[startIndex])
            ])
        }
        var lastBytes = 0
        for scale in scales[startIndex...] {
            let candidate: UIImage?
            if scale >= 1.0 {
                candidate = image
            } else {
                candidate = downscaledToPixelScale(image, scale: scale)
            }
            guard let candidate else { continue }
            // 候选图内容校验（黑图防线）：绘制失败会静默产出纯色图，且其 JPEG 极小、会骗过字节上限
            guard !SJZImageIntegrity.isLikelyBlank(candidate) else {
                LogManager.shared.warning("wechat", "长图编码候选校验未通过（纯色 / 黑图，已跳过该档位）", context: [
                    "scale": String(format: "%.2f", scale),
                    "pixel": SJZImageIntegrity.pixelSizeText(of: candidate)
                ])
                continue
            }
            for quality in qualities {
                // autoreleasepool：逐档尝试的 JPEG 编码中间缓冲及时释放（超大图峰值可观）
                guard let data = autoreleasepool(invoking: { candidate.jpegData(compressionQuality: quality) }) else { continue }
                lastBytes = data.count
                guard data.count <= maxBytes else { continue }
                // 最终交付校验：把编码后的字节缩略解码一次，确认真实存储内容不是纯色 / 黑图
                // （最后一道闸：任何阶段引入的黑图都不可能进入微信）
                guard !SJZImageIntegrity.isLikelyBlank(encodedImage: data) else {
                    LogManager.shared.warning("wechat", "长图编码产物校验未通过（纯色 / 黑图，已跳过该档位）", context: [
                        "scale": String(format: "%.2f", scale),
                        "quality": String(format: "%.2f", quality),
                        "bytes": "\(data.count)"
                    ])
                    continue
                }
                if scale < 1.0 || quality < 0.92 {
                    LogManager.shared.info("wechat", "长图已自动压缩至官方上限内", context: [
                        "scale": String(format: "%.2f", scale),
                        "quality": String(format: "%.2f", quality),
                        "bytes": "\(data.count)",
                        "limit": "\(maxBytes)",
                        "pixel": SJZImageIntegrity.pixelSizeText(of: candidate)
                    ])
                }
                return Result(data: data,
                              pixelSize: SJZImageIntegrity.pixelSize(of: candidate),
                              quality: quality,
                              scale: scale)
            }
        }
        LogManager.shared.warning("wechat", "长图压缩未达官方上限（放弃分享）", context: [
            "bytes": "\(lastBytes)",
            "limit": "\(maxBytes)"
        ])
        return nil
    }

    /// 等比降采样（**像素级**；契约测试锚点）。
    /// 教训（2026-09-28 黑图二次复现）：长图渲染产物是**自适应倍率**（`image.scale` ∈ 0.2~3.0），
    /// 若拿「点尺寸 × 系数」当像素目标，会得到比原图更大的位图 → 分配失败 → 静默黑图；
    /// 故必须按 `size × scale` 换算真实像素，再以 1:1 像素渲染。
    static func downscaledToPixelScale(_ image: UIImage, scale: CGFloat) -> UIImage? {
        let pixel = SJZImageIntegrity.pixelSize(of: image)
        let target = CGSize(width: max(1, (pixel.width * scale).rounded(.down)),
                            height: max(1, (pixel.height * scale).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 1:1 像素渲染：target 即像素尺寸
        format.opaque = true
        format.preferredRange = .standard   // 8 位/通道（16 位扩展域会使内存翻倍）
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - 分享缩略图（命中内存缓存 → 统一图片管线下载 → 压缩至 ≤32KB JPEG）

/// 官方缩略图硬限制：thumbData ≤ 64KB（历史文档 32KB），此处按更严格的 32KB 生成。
/// 取图顺序：调用方已持有的 UIImage → 内存解码缓存（列表/详情已加载图）→ 网络下载（统一图片管线）。
@MainActor
enum WeChatThumbnailProvider {
    static let maxThumbBytes = 32 * 1024
    static let hardLimitBytes = 64 * 1024
    /// 缩略图边长（200pt）：长图载荷构造期生成预览小图也会读取（故 nonisolated）
    nonisolated static let thumbSide: CGFloat = 200

    /// 生成缩略图数据；任一步失败返回 nil（分享仍可进行，仅无缩略图）
    static func thumbData(for payload: WeChatSharePayload) async -> Data? {
        if let image = payload.thumbImage, let data = compress(image) {
            LogManager.shared.debugLog("wechat", "缩略图命中内存图（详情页已加载）", context: [
                "bytes": "\(data.count)"
            ])
            return data
        }
        guard let urlString = payload.thumbImageURL, let url = URL(string: urlString) else { return nil }

        // 内存解码缓存：文章列表（720px 缩略图）与详情页（1440px 主图）双规格探测
        for pixel in [SJZImageKit.defaultThumbnailPixel, 1440, nil] as [CGFloat?] {
            let key = SJZDecodedImageCache.key(url: url, maxPixel: pixel)
            if let cached = SJZDecodedImageCache.shared.image(forKey: key), let data = compress(cached) {
                LogManager.shared.debugLog("wechat", "缩略图命中内存解码缓存", context: [
                    "pixel": pixel.map { String(Int($0)) } ?? "orig",
                    "bytes": "\(data.count)"
                ])
                return data
            }
        }

        // 网络下载：走统一图片管线（Referer 防盗链 + 缓存策略）并纳入全局并发闸（≤4）
        await SJZImageConcurrencyGate.shared.acquire()
        let image = await downloadImage(url: url)
        await SJZImageConcurrencyGate.shared.release()
        guard let image else { return nil }
        return compress(image)
    }

    /// 下载原始图（不落内存缓存，避免全尺寸图挤占解码缓存限额）
    private static func downloadImage(url: URL) async -> UIImage? {
        let started = Date()
        do {
            let request = SJZImageKit.makeRequest(url: url)
            let (data, response) = try await SJZImageKit.imageSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                LogManager.shared.warning("wechat", "缩略图下载失败", context: [
                    "url": url.lastPathComponent,
                    "status": "\((response as? HTTPURLResponse)?.statusCode ?? -1)"
                ])
                return nil
            }
            guard let image = UIImage(data: data) else {
                LogManager.shared.warning("wechat", "缩略图解码失败", context: ["bytes": "\(data.count)"])
                return nil
            }
            LogManager.shared.debugLog("wechat", "缩略图下载完成", context: [
                "ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
                "bytes": "\(data.count)"
            ])
            return image
        } catch {
            // 取消语义对齐工程红线：cancelled / CancellationError 静默处理（用户行为，不告警）
            let urlError = error as? URLError
            if urlError?.code == .cancelled || error is CancellationError || Task.isCancelled {
                LogManager.shared.debugLog("wechat", "缩略图下载取消", context: ["reason": "cancelled"])
                return nil
            }
            LogManager.shared.warning("wechat", "缩略图下载异常", context: [
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// 缩略图取图对齐方式（长图取顶部标题区比居中裁方更具辨识度）
    enum ThumbAlignment { case center, top }

    /// 由 UIImage 直接生成缩略图（长图分享路径；官方限制 ≤32KB）
    static func thumbData(from image: UIImage, alignment: ThumbAlignment = .center) -> Data? {
        let data = compress(image, alignment: alignment)
        if let data {
            LogManager.shared.debugLog("wechat", "缩略图由长图生成", context: [
                "alignment": alignment == .top ? "top" : "center",
                "bytes": "\(data.count)",
                "source": SJZImageIntegrity.pixelSizeText(of: image)
            ])
        }
        return data
    }

    /// 等比缩放 + 裁方 + JPEG 分级压缩（官方缩略图方形展示）
    static func compress(_ image: UIImage, alignment: ThumbAlignment = .center) -> Data? {
        guard let scaled = squareScaled(image, side: thumbSide, anchorTop: alignment == .top) else { return nil }
        // 缩略图内容校验：绘制失败会静默产出纯色图（黑缩略图会直接显示在微信会话列表）
        guard !SJZImageIntegrity.isLikelyBlank(scaled) else {
            LogManager.shared.warning("wechat", "缩略图绘制校验未通过（纯色 / 黑图，放弃缩略图）", context: [
                "alignment": alignment == .top ? "top" : "center"
            ])
            return nil
        }
        var quality: CGFloat = 0.82
        while quality >= 0.2 {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxThumbBytes {
                return data
            }
            quality -= 0.12
        }
        // 兜底：极限质量仍可接受则以硬上限（64KB）判定
        guard let fallback = scaled.jpegData(compressionQuality: 0.2), fallback.count <= hardLimitBytes else {
            LogManager.shared.warning("wechat", "缩略图压缩超出硬上限（放弃缩略图）", context: [
                "hardLimit": "\(hardLimitBytes)B"
            ])
            return nil
        }
        return fallback
    }

    /// 居中/顶部裁方 + 缩放核心（anchorTop：长图优先展示顶部标题区）
    /// nonisolated：长图载荷构造（非隔离上下文）复用本核心生成预览小图；UIGraphicsImageRenderer 线程安全
    nonisolated private static func squareScaled(_ image: UIImage, side: CGFloat, anchorTop: Bool) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard   // 8 位/通道（16 位扩展域会使内存翻倍）
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let originY: CGFloat = anchorTop ? 0 : (side - drawSize.height) / 2
            image.draw(in: CGRect(origin: CGPoint(x: (side - drawSize.width) / 2, y: originY), size: drawSize))
        }
    }

    /// 顶部裁方预览小图（长图分享菜单头部专用）：载荷构造期一次生成，
    /// 避免菜单直接绘制可能上万像素高的长图（弹出即显、零绘制卡顿；裁切核心与缩略图一致）
    nonisolated static func topSquarePreview(from image: UIImage, side: CGFloat) -> UIImage? {
        guard let preview = squareScaled(image, side: side, anchorTop: true),
              !SJZImageIntegrity.isLikelyBlank(preview) else { return nil }   // 纯色预览判失效 → 调用方回退原图
        return preview
    }
}

// MARK: - 微信服务（单例；WXApiDelegate 回执中枢）

@MainActor
final class WeChatService: NSObject, ObservableObject {

    static let shared = WeChatService()

    // MARK: 发布状态（界面与日志的统一事实源）

    /// SDK 是否注册成功
    @Published private(set) var isRegistered = false
    /// 配置快照
    @Published private(set) var configuration = WeChatConfiguration.load()
    /// 可用性状态
    @Published private(set) var availability: WeChatAvailability = .unconfigured
    /// SDK 版本号
    @Published private(set) var sdkVersion = "—"
    /// 微信是否安装（快照；refreshAvailability 时刷新）
    @Published private(set) var isWeChatInstalled = false
    /// 全局横幅（分享/登录回执与状态提示的可见载体）
    @Published private(set) var banner: WeChatBanner?
    /// 最近一次微信登录授权码（需服务端换取 access_token）
    @Published private(set) var lastAuthCode: String?
    /// Universal Link 自检：进行中
    @Published private(set) var isSelfChecking = false
    /// Universal Link 自检：分步结果（实时刷新）
    @Published private(set) var selfCheckItems: [WeChatSelfCheckItem] = []
    /// 最近一次分享发起的场景（回执归因用，同时供界面展示）
    @Published private(set) var lastShareScene: WeChatScene?

    // MARK: 私有状态

    /// 待回执的分享场景（onResp 归因）
    private var pendingScene: WeChatScene?
    /// 待回执的分享内容类型（网页卡片 / 长图；回执文案与日志区分）
    private var pendingShareKind: WeChatShareKind = .webpage
    /// 待回执的登录 state（防 CSRF 校验）
    private var pendingAuthState: String?
    /// 日志桥是否已挂载（SDK 会强引用 block，杜绝重复挂载）
    private var logBridgeInstalled = false
    /// 自检统计（日志汇总）
    private var selfCheckStartedAt: Date?

    private override init() {
        super.init()
        sdkVersion = WXApi.getVersion()
    }

    // MARK: - 注册（隐私同意后调用；幂等）

    /// 注册微信 SDK（官方要求每次启动调用一次；本工程在用户同意隐私协议后调用）。
    /// - Parameter reason: 触发来源（启动链 / 隐私同意 / 设置页手动重试），用于日志归因
    /// - Returns: 是否注册成功
    @discardableResult
    func registerIfNeeded(reason: String) -> Bool {
        configuration = WeChatConfiguration.load()
        sdkVersion = WXApi.getVersion()

        guard !configuration.isPlaceholder else {
            isRegistered = false
            availability = .unconfigured
            LogManager.shared.warning("wechat", "微信 SDK 未注册：配置为占位值", context: [
                "reason": reason,
                "appID": configuration.appID.isEmpty ? "(missing)" : configuration.appID,
                "universalLink": configuration.universalLink.isEmpty ? "(missing)" : configuration.universalLink,
                "fix": "Target 构建设置 WECHAT_APPID / WECHAT_UNIVERSAL_LINK / WECHAT_UL_HOST"
            ])
            return false
        }

        let ok = WXApi.registerApp(configuration.appID, universalLink: configuration.universalLink)
        isRegistered = ok
        installLogBridgeIfNeeded()
        refreshAvailability()
        LogManager.shared.info("wechat", "微信 SDK 注册\(ok ? "成功" : "失败")", context: [
            "reason": reason,
            "appID": configuration.appID,
            "ulHost": configuration.universalLinkHost,
            "appIDFormat": configuration.hasValidAppIDFormat ? "valid" : "invalid",
            "sdkVersion": sdkVersion,
            "availability": availability.rawValue
        ])
        if !configuration.hasValidAppIDFormat {
            LogManager.shared.warning("wechat", "AppID 格式异常（官方应为 wx + 16 位十六进制）", context: [
                "appID": configuration.appID
            ])
        }
        return ok
    }

    /// 刷新可用性状态机（配置 → 注册 → 安装 → 版本）
    @discardableResult
    func refreshAvailability() -> WeChatAvailability {
        if configuration.isPlaceholder {
            availability = .unconfigured
            isWeChatInstalled = false
            return availability
        }
        guard isRegistered else {
            availability = .sdkNotRegistered
            isWeChatInstalled = false
            return availability
        }
        isWeChatInstalled = WXApi.isWXAppInstalled()
        if !isWeChatInstalled {
            availability = .weChatNotInstalled
            return availability
        }
        if !WXApi.isWXAppSupport() {
            availability = .weChatVersionTooLow
            return availability
        }
        availability = .ready
        return availability
    }

    // MARK: - 回跳处理（SwiftUI 生命周期入口）

    /// 处理微信回跳（URL Scheme 通道）——由 App 的 `.onOpenURL` 调用
    @discardableResult
    func handle(openURL url: URL) -> Bool {
        let handled = WXApi.handleOpen(url, delegate: self)
        LogManager.shared.debugLog("wechat", "微信回跳（URL Scheme）", context: [
            "scheme": url.scheme ?? "-",
            "host": url.host ?? "-",
            "handled": "\(handled)"
        ])
        return handled
    }

    /// 处理微信回跳（Universal Link 通道）——由 App 的 `.onContinueUserActivity` 调用
    @discardableResult
    func handle(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return false }
        let handled = WXApi.handleOpenUniversalLink(userActivity, delegate: self)
        LogManager.shared.debugLog("wechat", "微信回跳（Universal Link）", context: [
            "url": userActivity.webpageURL?.absoluteString ?? "-",
            "handled": "\(handled)"
        ])
        return handled
    }

    // MARK: - 分享

    /// 分享网页卡片到微信（好友 / 朋友圈 / 收藏）
    /// - Returns: 是否成功把请求交给微信（用户侧发送结果由 onResp 回执，经全局横幅呈现）
    @discardableResult
    func share(_ payload: WeChatSharePayload, to scene: WeChatScene) async -> Bool {
        refreshAvailability()
        guard availability.canOperate else {
            LogManager.shared.warning("wechat", "分享未发起：微信不可用", context: [
                "scene": scene.logName,
                "availability": availability.rawValue,
                "title": payload.clippedTitle
            ])
            showBanner(availability.userHint, kind: .failure)
            return false
        }
        guard let url = URL(string: payload.urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            LogManager.shared.error("wechat", "分享未发起：链接无效", context: [
                "scene": scene.logName,
                "url": payload.urlString.isEmpty ? "(empty)" : payload.urlString
            ])
            showBanner("分享链接无效", kind: .failure)
            return false
        }

        let prepareStarted = Date()
        let message = WXMediaMessage()
        message.title = payload.clippedTitle
        message.description = payload.clippedDescription
        let webpage = WXWebpageObject()
        webpage.webpageUrl = payload.urlString
        message.mediaObject = webpage

        var thumbBytes = 0
        if let thumb = await WeChatThumbnailProvider.thumbData(for: payload) {
            message.thumbData = thumb
            thumbBytes = thumb.count
        }

        let req = SendMessageToWXReq()
        req.bText = false
        req.message = message
        req.scene = scene.sceneValue

        let sent: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            WXApi.send(req) { success in
                cont.resume(returning: success)
            }
        }

        let prepareMs = Int(Date().timeIntervalSince(prepareStarted) * 1000)
        if sent {
            pendingScene = scene
            pendingShareKind = .webpage
            lastShareScene = scene
            LogManager.shared.info("wechat", "分享已发起（等待微信回执）", context: [
                "kind": WeChatShareKind.webpage.logName,
                "scene": scene.logName,
                "title": payload.clippedTitle,
                "url": payload.urlString,
                "thumb": thumbBytes > 0 ? "\(thumbBytes)B" : "none",
                "prepareMs": "\(prepareMs)",
                "titleBytes": "\(payload.clippedTitle.utf8.count)",
                "descBytes": "\(payload.clippedDescription.utf8.count)"
            ])
        } else {
            LogManager.shared.warning("wechat", "分享发起失败（SDK 返回 false）", context: [
                "scene": scene.logName,
                "availability": availability.rawValue,
                "installed": "\(isWeChatInstalled)",
                "prepareMs": "\(prepareMs)"
            ])
            showBanner("未能唤起微信，请稍后重试", kind: .failure)
        }
        return sent
    }

    // MARK: - 长图分享（WXImageObject；官方示例即覆盖三场景，含朋友圈）

    /// 分享长图到微信（官方 WXImageObject 图片消息）
    /// - 官方约束：`imageData ≤ 10MB`、`thumbData ≤ 32KB`（超限自动降质/降采样并留痕）
    /// - Parameter entry: 入口标识（用于日志归因，如 "news_detail"）
    /// - Returns: 是否成功把请求交给微信（用户侧发送结果由 onResp 回执，经全局横幅呈现）
    @discardableResult
    func shareImage(_ image: UIImage, title: String, to scene: WeChatScene, entry: String) async -> Bool {
        refreshAvailability()
        guard availability.canOperate else {
            LogManager.shared.warning("wechat", "长图分享未发起：微信不可用", context: [
                "kind": WeChatShareKind.longImage.logName,
                "scene": scene.logName,
                "entry": entry,
                "availability": availability.rawValue
            ])
            showBanner(availability.userHint, kind: .failure)
            return false
        }
        let clipTitle = WeChatText.clip(title, maxBytes: 512, fallback: "园枢 · 山西晋中理工学院")
        let prepareStarted = Date()
        guard let encoded = WeChatImageEncoder.encode(image) else {
            LogManager.shared.error("wechat", "长图分享未发起：编码未达官方上限", context: [
                "kind": WeChatShareKind.longImage.logName,
                "scene": scene.logName,
                "entry": entry,
                "pixelSize": SJZImageIntegrity.pixelSizeText(of: image),
                "limit": "\(WeChatImageEncoder.maxImageBytes)B"
            ])
            showBanner("长图过大，未能压缩到微信限制内", kind: .failure)
            return false
        }
        let thumbData = WeChatThumbnailProvider.thumbData(from: image, alignment: .top)

        let imageObject = WXImageObject()
        imageObject.imageData = encoded.data

        let message = WXMediaMessage()
        message.title = clipTitle
        if let thumbData { message.thumbData = thumbData }
        message.mediaObject = imageObject

        let req = SendMessageToWXReq()
        req.bText = false
        req.message = message
        req.scene = scene.sceneValue

        let sent: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            WXApi.send(req) { success in
                cont.resume(returning: success)
            }
        }

        let prepareMs = Int(Date().timeIntervalSince(prepareStarted) * 1000)
        if sent {
            pendingScene = scene
            pendingShareKind = .longImage
            lastShareScene = scene
            LogManager.shared.info("wechat", "长图分享已发起（等待微信回执）", context: [
                "kind": WeChatShareKind.longImage.logName,
                "scene": scene.logName,
                "entry": entry,
                "title": clipTitle,
                "bytes": "\(encoded.data.count)",
                "pixelSize": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
                "quality": String(format: "%.2f", encoded.quality),
                "scale": String(format: "%.2f", encoded.scale),
                "thumb": thumbData.map { "\($0.count)B" } ?? "none",
                "prepareMs": "\(prepareMs)"
            ])
        } else {
            LogManager.shared.warning("wechat", "长图分享发起失败（SDK 返回 false）", context: [
                "kind": WeChatShareKind.longImage.logName,
                "scene": scene.logName,
                "entry": entry,
                "availability": availability.rawValue,
                "installed": "\(isWeChatInstalled)",
                "bytes": "\(encoded.data.count)",
                "prepareMs": "\(prepareMs)"
            ])
            showBanner("未能唤起微信，请稍后重试", kind: .failure)
        }
        return sent
    }

    // MARK: - 微信登录

    /// 发起微信登录（官方 SendAuthReq；scope 默认 snsapi_userinfo）
    /// 回执授权码经 `lastAuthCode` 发布，需由服务端换取 access_token / 用户信息。
    @discardableResult
    func startAuth(scope: String = "snsapi_userinfo") async -> Bool {
        refreshAvailability()
        guard availability.canOperate else {
            LogManager.shared.warning("wechat", "登录未发起：微信不可用", context: [
                "availability": availability.rawValue
            ])
            showBanner(availability.userHint, kind: .failure)
            return false
        }
        // state 防 CSRF：随机值 + 回执校验
        let state = "sjzit_\(UUID().uuidString.prefix(8))"
        pendingAuthState = state
        let req = SendAuthReq()
        req.scope = scope
        req.state = state

        let sent: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            WXApi.send(req) { success in
                cont.resume(returning: success)
            }
        }
        LogManager.shared.info("wechat", "微信登录请求\(sent ? "已发起" : "发起失败")", context: [
            "scope": scope,
            "state": state,
            "sdkVersion": sdkVersion
        ])
        if !sent {
            pendingAuthState = nil
            showBanner("未能唤起微信登录", kind: .failure)
        }
        return sent
    }

    // MARK: - 小程序跳转

    /// 跳转/分享小程序（WXMiniProgramObject；小程序原始 ID 由构建设置 WECHAT_MINI_PROGRAM 注入）
    @discardableResult
    func launchMiniProgram(fallbackWebpageURL: String, path: String? = nil) async -> Bool {
        refreshAvailability()
        guard availability.canOperate else {
            LogManager.shared.warning("wechat", "小程序跳转未发起：微信不可用", context: [
                "availability": availability.rawValue
            ])
            showBanner(availability.userHint, kind: .failure)
            return false
        }
        guard configuration.hasMiniProgram else {
            LogManager.shared.warning("wechat", "小程序跳转未发起：未配置小程序原始 ID", context: [
                "fix": "Target 构建设置 WECHAT_MINI_PROGRAM（gh_ 开头）"
            ])
            showBanner("尚未配置小程序原始 ID（WECHAT_MINI_PROGRAM）", kind: .failure)
            return false
        }
        guard fallbackWebpageURL.lowercased().hasPrefix("http") else {
            LogManager.shared.warning("wechat", "小程序跳转未发起：兜底链接无效", context: [
                "fallback": fallbackWebpageURL.isEmpty ? "(empty)" : fallbackWebpageURL
            ])
            return false
        }

        let message = WXMediaMessage()
        message.title = "园枢 · 山西晋中理工学院"
        message.description = "打开微信小程序继续浏览"
        let mini = WXMiniProgramObject()
        mini.webpageUrl = fallbackWebpageURL
        mini.userName = configuration.miniProgramID
        if let path, !path.isEmpty {
            mini.path = path
        } else {
            mini.path = "pages/index/index"
        }
        mini.miniProgramType = .release
        message.mediaObject = mini

        let req = SendMessageToWXReq()
        req.bText = false
        req.message = message
        req.scene = 0   // 会话（小程序跳转不支持朋友圈）

        let sent: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            WXApi.send(req) { success in
                cont.resume(returning: success)
            }
        }
        LogManager.shared.info("wechat", "小程序跳转\(sent ? "已发起" : "发起失败")", context: [
            "userName": configuration.miniProgramID,
            "path": mini.path ?? "-",
            "type": "release",
            "fallback": fallbackWebpageURL
        ])
        if !sent { showBanner("未能唤起微信小程序", kind: .failure) }
        return sent
    }

    // MARK: - 微信 App 交互

    /// 打开微信
    @discardableResult
    func openWeChatApp() -> Bool {
        let ok = WXApi.openWXApp()
        LogManager.shared.info("wechat", "打开微信 App\(ok ? "成功" : "失败")", context: [
            "installed": "\(WXApi.isWXAppInstalled())"
        ])
        return ok
    }

    /// 微信安装地址（App Store）
    var weChatInstallURL: URL? {
        URL(string: WXApi.getWXAppInstallUrl())
    }

    // MARK: - Universal Link 自检（官方七步）

    /// 运行 Universal Link 自检（官方 checkUniversalLinkReady；会短暂拉起微信，仅调试期使用）
    func runUniversalLinkSelfCheck() async {
        refreshAvailability()
        guard availability.canOperate else {
            LogManager.shared.warning("wechat", "自检未发起：微信不可用", context: [
                "availability": availability.rawValue
            ])
            showBanner(availability.userHint, kind: .failure)
            return
        }
        guard !isSelfChecking else {
            LogManager.shared.debugLog("wechat", "自检已在执行中，忽略重复请求")
            return
        }
        isSelfChecking = true
        selfCheckItems = []
        selfCheckStartedAt = Date()
        // 官方建议：自检前开启详细日志便于排查
        startLogBridge(level: .detail)
        LogManager.shared.info("wechat", "Universal Link 自检开始（七步）", context: [
            "appID": configuration.appID,
            "universalLink": configuration.universalLink,
            "ulHost": configuration.universalLinkHost,
            "sdkVersion": sdkVersion
        ])

        let collector = WeChatSelfCheckCollector()
        Self.startUniversalLinkCheck { step, result in
            let rawStep = Int(step.rawValue)
            let item = WeChatSelfCheckItem(
                id: rawStep,
                title: WeChatService.selfCheckStepTitle(rawStep),
                success: result.success,
                errorInfo: result.errorInfo,
                suggestion: result.suggestion
            )
            Task { @MainActor in
                let snapshot = await collector.record(item)
                self.selfCheckItems = snapshot
                if rawStep == WeChatService.selfCheckFinalStep {
                    await collector.finish()
                }
            }
        }

        // 超时兜底：官方自检含「拉起微信 → 返回当前 App」步骤，用户不返回时终态可能长时间缺席
        let finalItems: [WeChatSelfCheckItem] = await withTaskGroup(of: [WeChatSelfCheckItem].self) { group in
            group.addTask { await collector.wait() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await collector.finish()
                return await collector.wait()
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }

        let elapsedMs = selfCheckStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let passed = finalItems.last?.success == true && finalItems.contains { $0.id == Self.selfCheckFinalStep }
        let failedStep = finalItems.first { !$0.success }
        LogManager.shared.log(
            level: passed ? .info : .warning,
            module: "wechat",
            message: "Universal Link 自检\(passed ? "通过" : "未通过")",
            context: [
                "steps": finalItems.map { "\($0.id):\($0.success ? "ok" : "fail")" }.joined(separator: ","),
                "failedStep": failedStep.map { "\($0.id)-\($0.title)" } ?? "-",
                "errorInfo": failedStep?.errorInfo ?? "-",
                "elapsedMs": "\(elapsedMs)",
                "finished": "\(finalItems.contains { $0.id == Self.selfCheckFinalStep })"
            ]
        )
        showBanner(passed ? "Universal Link 自检通过" : (failedStep != nil ? "自检未通过：\(failedStep!.title)" : "自检超时中止，请重试"), kind: passed ? .success : .failure)
        isSelfChecking = false
        startLogBridge(level: .normal)
    }

    /// 清空自检结果
    func clearSelfCheck() {
        selfCheckItems = []
        LogManager.shared.debugLog("wechat", "自检结果已清空")
    }

    /// 官方七步标题（nonisolated：SDK 回调线程直接调用）
    nonisolated static func selfCheckStepTitle(_ step: Int) -> String {
        switch step {
        case 0: return "参数检查"
        case 1: return "系统版本检查"
        case 2: return "微信版本检查"
        case 3: return "SDK 内部操作检查"
        case 4: return "拉起微信检查"
        case 5: return "微信返回当前 App 检查"
        case 6: return "最终结果"
        default: return "步骤 \(step)"
        }
    }
    /// 官方终态步骤（WXULCheckStepFinal；nonisolated：SDK 回调线程直接比较）
    nonisolated static let selfCheckFinalStep = 6

    /// 触发官方 Universal Link 自检回调（非 async 独立入口：
    /// 官方 API 为「完成回调」形态，直接从 async 上下文调用会被提示改用异步替代，包一层保持零警告）
    private nonisolated static func startUniversalLinkCheck(_ handler: @escaping @Sendable (WXULCheckStep, WXCheckULStepResult) -> Void) {
        WXApi.checkUniversalLinkReady(handler)
    }

    // MARK: - SDK 日志桥（接入工程 LogManager，域 "wechat"）

    /// 挂载 SDK 日志桥（SDK 强引用 block；重复挂载会替换旧 block，故仅挂载一次）
    private func installLogBridgeIfNeeded() {
        guard !logBridgeInstalled else { return }
        logBridgeInstalled = true
        startLogBridge(level: .normal)
    }

    /// 切换 SDK 日志等级并桥接到 LogManager（DEBUG 级别，不进入警告栏）
    private func startLogBridge(level: WXLogLevel) {
        WXApi.startLog(by: level) { line in
            // SDK 回调线程不定：仅搬运字符串，回主线程写入日志
            let text = line
            Task { @MainActor in
                LogManager.shared.debugLog("wechat", "SDK: \(text)")
            }
        }
        LogManager.shared.debugLog("wechat", "SDK 日志桥已挂载", context: [
            "level": level == .detail ? "detail" : "normal"
        ])
    }

    // MARK: - 横幅

    /// 展示全局横幅（根视图悬浮呈现并自动消隐）
    func showBanner(_ text: String, kind: WeChatBanner.Kind) {
        banner = WeChatBanner(kind: kind, text: text)
    }

    /// 消隐横幅（由呈现层延时调用；带 id 校验避免误清新横幅）
    func clearBanner(id: UUID) {
        guard banner?.id == id else { return }
        banner = nil
    }
}

// MARK: - WXApiDelegate（SDK 回调可能在任意线程：先同步提取原语，再回主线程处理）

extension WeChatService: WXApiDelegate {

    nonisolated func onReq(_ req: BaseReq) {
        let reqType = req.type
        var title = ""
        var mediaType = ""
        if let show = req as? ShowMessageFromWXReq {
            title = show.message.title
            mediaType = String(describing: Swift.type(of: show.message.mediaObject))
        } else if let launch = req as? LaunchFromWXReq {
            title = launch.message.title
            mediaType = String(describing: Swift.type(of: launch.message.mediaObject))
        }
        let isGetMessage = req is GetMessageFromWXReq
        Task { @MainActor in
            self.handleRequest(type: reqType, title: title, mediaType: mediaType, isGetMessage: isGetMessage)
        }
    }

    nonisolated func onResp(_ resp: BaseResp) {
        // 同步提取 Sendable 原语，避免持有 SDK 自动释放对象
        let respType = resp.type
        let errCode = resp.errCode
        let errStr = resp.errStr
        var authCode: String?
        var authState: String?
        var lang: String?
        var country: String?
        if let auth = resp as? SendAuthResp {
            authCode = auth.code
            authState = auth.state
            lang = auth.lang
            country = auth.country
        } else if let share = resp as? SendMessageToWXResp {
            lang = share.lang
            country = share.country
        }
        Task { @MainActor in
            self.handleResponse(
                type: respType,
                errCode: errCode,
                errStr: errStr,
                authCode: authCode,
                authState: authState,
                lang: lang,
                country: country
            )
        }
    }

    /// iOS 16+ 剪贴板授权询问：直接放行（微信回执数据经剪贴板回传），并记录日志
    nonisolated func onNeedGrantReadPasteBoardPermission(with openURL: URL, completion: @escaping WXGrantReadPasteBoardPermissionCompletion) {
        let urlText = openURL.absoluteString
        let granted = completion()
        Task { @MainActor in
            LogManager.shared.debugLog("wechat", "SDK 请求剪贴板读取授权", context: [
                "url": urlText,
                "granted": "\(granted)"
            ])
        }
    }

    // MARK: 主线程处理

    /// 处理微信主动请求（onReq；本 App 仅应答 GetMessageFromWXReq，其余记录日志）
    private func handleRequest(type: Int32, title: String, mediaType: String, isGetMessage: Bool) {
        LogManager.shared.info("wechat", "收到微信请求 onReq", context: [
            "type": "\(type)",
            "title": title.isEmpty ? "-" : title,
            "mediaObject": mediaType.isEmpty ? "-" : mediaType,
            "action": isGetMessage ? "reply_text" : "log_only"
        ])
        guard isGetMessage else { return }
        // GetMessageFromWXReq：微信要求回传内容（从微信分享到本 App 的入口）
        let resp = GetMessageFromWXResp()
        resp.bText = true
        resp.text = "园枢 · 山西晋中理工学院：在微信中浏览校园资讯，可在「园枢」App 内查看完整内容。"
        WXApi.send(resp) { success in
            Task { @MainActor in
                LogManager.shared.debugLog("wechat", "GetMessageFromWXReq 应答已发送", context: [
                    "success": "\(success)"
                ])
            }
        }
    }

    /// 处理微信回执（onResp；分享与登录的统一归因）
    private func handleResponse(type: Int32, errCode: Int32, errStr: String, authCode: String?, authState: String?, lang: String?, country: String?) {
        let context: [String: String] = [
            "respType": "\(type)",
            "errCode": "\(errCode)",
            "errDesc": WeChatErrCode.describe(errCode),
            "errStr": errStr.isEmpty ? "-" : errStr
        ]

        if authCode != nil {
            handleAuthResponse(errCode: errCode, code: authCode, state: authState, lang: lang, country: country, context: context)
            return
        }

        guard let scene = pendingScene else {
            // 无待归因场景（如自检回跳、微信主动拉起）：仅记录
            LogManager.shared.info("wechat", "收到微信回执（无待归因场景）", context: context)
            return
        }
        let shareKind = pendingShareKind
        pendingScene = nil
        pendingShareKind = .webpage
        lastShareScene = scene

        switch errCode {
        case WeChatErrCode.success:
            LogManager.shared.info("wechat", "\(shareKind.noun)成功：已发送到\(scene.title)", context: context.merging([
                "kind": shareKind.logName,
                "scene": scene.logName
            ]) { _, new in new })
            showBanner(shareKind.successText(scene: scene), kind: .success)
        case WeChatErrCode.userCancel:
            // 取消属用户正常行为：INFO 记录，不计失败（对齐工程取消语义红线）
            LogManager.shared.info("wechat", "用户取消\(shareKind.noun)（\(scene.title)）", context: context.merging([
                "kind": shareKind.logName,
                "scene": scene.logName
            ]) { _, new in new })
            showBanner(shareKind.cancelText, kind: .info)
        case WeChatErrCode.sentFail:
            LogManager.shared.warning("wechat", "\(shareKind.noun)失败：发送失败（\(scene.title)）", context: context.merging([
                "kind": shareKind.logName,
                "scene": scene.logName
            ]) { _, new in new })
            showBanner("分享发送失败，请重试", kind: .failure)
        case WeChatErrCode.authDeny:
            LogManager.shared.warning("wechat", "\(shareKind.noun)失败：微信拒绝授权（\(scene.title)）", context: context.merging([
                "kind": shareKind.logName,
                "scene": scene.logName,
                "hint": "应用未获微信平台授权或签名不匹配"
            ]) { _, new in new })
            showBanner("微信拒绝本次分享（应用未获授权）", kind: .failure)
        case WeChatErrCode.unsupport:
            LogManager.shared.warning("wechat", "\(shareKind.noun)失败：当前微信版本不支持（\(scene.title)）", context: context.merging([
                "kind": shareKind.logName,
                "scene": scene.logName
            ]) { _, new in new })
            showBanner("当前微信版本不支持该功能", kind: .failure)
        default:
            LogManager.shared.warning("wechat", "\(shareKind.noun)返回未知结果（\(scene.title)）", context: context.merging([
                "kind": shareKind.logName,
                "scene": scene.logName
            ]) { _, new in new })
            showBanner("微信返回异常（\(errCode)），请重试", kind: .failure)
        }
    }

    /// 微信登录回执（含 state 校验）
    private func handleAuthResponse(errCode: Int32, code: String?, state: String?, lang: String?, country: String?, context: [String: String]) {
        let expected = pendingAuthState
        pendingAuthState = nil

        switch errCode {
        case WeChatErrCode.success:
            guard let code, !code.isEmpty else {
                LogManager.shared.warning("wechat", "微信登录回执缺少授权码", context: context)
                showBanner("微信登录失败：未收到授权码", kind: .failure)
                return
            }
            if let expected, let state, state != expected {
                LogManager.shared.warning("wechat", "微信登录 state 校验不通过", context: context.merging([
                    "expected": expected,
                    "received": state
                ]) { _, new in new })
                showBanner("微信登录校验失败，请重试", kind: .failure)
                return
            }
            lastAuthCode = code
            LogManager.shared.info("wechat", "微信登录成功：已获取授权码", context: context.merging([
                "codeLength": "\(code.count)",
                "lang": lang ?? "-",
                "country": country ?? "-",
                "note": "授权码需由服务端换取 access_token / 用户信息"
            ]) { _, new in new })
            showBanner("微信登录成功（授权码已获取）", kind: .success)
        case WeChatErrCode.userCancel:
            LogManager.shared.info("wechat", "用户取消微信登录", context: context)
            showBanner("已取消微信登录", kind: .info)
        case WeChatErrCode.authDeny:
            LogManager.shared.warning("wechat", "微信登录被拒绝（应用未获登录授权）", context: context.merging([
                "hint": "需在微信开放平台为应用申请「微信登录」能力"
            ]) { _, new in new })
            showBanner("微信登录被拒绝（应用未获登录授权）", kind: .failure)
        default:
            LogManager.shared.warning("wechat", "微信登录失败", context: context)
            showBanner("微信登录失败（\(errCode)）", kind: .failure)
        }
    }
}