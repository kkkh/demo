//
//  WeChatSDKTests.swift
//  山西晋中理工学院 APP — 微信开放平台 SDK 集成契约测试
//
//  覆盖（官方接入要件 + 能力契约，全部为可离线断言）：
//  · Info.plist 声明：URL Scheme（= AppID，wx 开头）/ WeChatUniversalLink /
//    WeChatMiniProgramID / LSApplicationQueriesSchemes（weixin / weixinULAPI / weixinURLParamsAPI）
//  · 配置占位判定与 AppID 格式校验（占位 = 全链禁用，不发任何微信请求）
//  · 官方字节级限制：标题 ≤512B、描述 ≤1024B（UTF-8 不切断多字节字符）
//  · 缩略图契约：居中裁方 200×200、JPEG ≤32KB（硬上限 64KB）
//  · 场景枚举与官方 WXScene 数值对齐（会话 0 / 朋友圈 1 / 收藏 2）
//  · 可用性状态机不变量、自检七步标题、横幅模型
//

import XCTest
@testable import DesignCode
import UIKit

@MainActor
final class WeChatSDKTests: XCTestCase {

    // MARK: - Info.plist 官方声明契约

    /// 官方要求①：CFBundleURLTypes 的 URL Scheme 为 AppID 本身（wx 开头）
    func testInfoPlistURLSchemeIsAppID() {
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = (urlTypes ?? []).compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
        XCTAssertFalse(schemes.isEmpty, "Info.plist 必须声明 CFBundleURLTypes（微信回跳依赖 URL Scheme）")
        let wxScheme = schemes.first { $0.lowercased().hasPrefix("wx") }
        XCTAssertNotNil(wxScheme, "微信 URL Scheme 必须为 AppID 本身（wx 开头），实际 schemes=\(schemes)")
    }

    /// 官方要求②：LSApplicationQueriesSchemes 必须包含 weixin / weixinULAPI / weixinURLParamsAPI
    func testInfoPlistQueriesSchemes() {
        let queries = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        for required in ["weixin", "weixinULAPI", "weixinURLParamsAPI"] {
            XCTAssertTrue(queries.contains(required), "LSApplicationQueriesSchemes 缺少 \(required)")
        }
        // 官方提示：微信相关 scheme 需位于前 50 条内
        if let index = queries.firstIndex(of: "weixin") {
            XCTAssertLessThan(index, 50, "weixin 必须位于 LSApplicationQueriesSchemes 前 50 条内")
        }
    }

    /// 官方要求③：Universal Link 与小程序原始 ID 通过 Info.plist 键注入（构建设置变量，改一处生效）
    func testInfoPlistUniversalLinkAndMiniProgramKeys() {
        let universalLink = Bundle.main.object(forInfoDictionaryKey: "WeChatUniversalLink") as? String
        XCTAssertNotNil(universalLink, "Info.plist 缺少 WeChatUniversalLink（$(WECHAT_UNIVERSAL_LINK) 注入）")
        XCTAssertFalse(universalLink?.isEmpty ?? true, "WeChatUniversalLink 不得为空")
        let miniProgram = Bundle.main.object(forInfoDictionaryKey: "WeChatMiniProgramID") as? String
        XCTAssertNotNil(miniProgram, "Info.plist 缺少 WeChatMiniProgramID（$(WECHAT_MINI_PROGRAM) 注入）")
    }

    /// 配置装载：Scheme 即 AppID；三项关键配置读取自 Info.plist
    func testConfigurationLoadsFromInfoPlist() {
        let config = WeChatConfiguration.load()
        XCTAssertTrue(config.appID.lowercased().hasPrefix("wx"),
                      "配置装载的 AppID 应来自 URL Scheme（wx 开头），实际=\(config.appID)")
        XCTAssertFalse(config.universalLink.isEmpty)
        XCTAssertEqual(config.maskedAppID.isEmpty, false)
    }

    // MARK: - 占位判定与格式校验

    func testPlaceholderDetection() {
        let placeholder = WeChatConfiguration(
            appID: WeChatConfiguration.placeholderAppID,
            universalLink: WeChatConfiguration.placeholderUniversalLink,
            miniProgramID: "gh_PLACEHOLDER0000"
        )
        XCTAssertTrue(placeholder.isPlaceholder, "占位 AppID / 占位域名必须判定为未配置")
        XCTAssertFalse(placeholder.hasMiniProgram, "占位小程序 ID 不得视为可用")

        let empty = WeChatConfiguration(appID: "", universalLink: "", miniProgramID: "")
        XCTAssertTrue(empty.isPlaceholder, "空配置必须判定为未配置")

        let httpLink = WeChatConfiguration(
            appID: "wx1234567890abcdef",
            universalLink: "http://sxjzit.edu.cn/app/",
            miniProgramID: ""
        )
        XCTAssertTrue(httpLink.isPlaceholder, "官方要求 Universal Link 必须为 https")

        let real = WeChatConfiguration(
            appID: "wx1234567890abcdef",
            universalLink: "https://www.sxjzit.edu.cn/app/",
            miniProgramID: "gh_abcdef123456"
        )
        XCTAssertFalse(real.isPlaceholder, "真实配置不得判定为未配置")
        XCTAssertTrue(real.hasValidAppIDFormat, "wx + 16 位十六进制应通过格式校验")
        XCTAssertTrue(real.hasMiniProgram, "gh_ 开头小程序 ID 应视为可用")
        XCTAssertEqual(real.universalLinkHost, "www.sxjzit.edu.cn")
    }

    func testAppIDFormatValidation() {
        XCTAssertTrue(WeChatConfiguration(appID: "wx0123456789abcdef", universalLink: "https://a.cn/app/", miniProgramID: "").hasValidAppIDFormat)
        XCTAssertFalse(WeChatConfiguration(appID: "wxZZZ", universalLink: "https://a.cn/app/", miniProgramID: "").hasValidAppIDFormat)
        XCTAssertFalse(WeChatConfiguration(appID: "0123456789abcdef", universalLink: "https://a.cn/app/", miniProgramID: "").hasValidAppIDFormat)
    }

    // MARK: - 官方字节级限制（标题 512B / 描述 1KB）

    func testTextClipRespectsUTF8ByteLimit() {
        let ascii = String(repeating: "a", count: 900)
        let clippedASCII = WeChatText.clip(ascii, maxBytes: 512)
        XCTAssertLessThanOrEqual(clippedASCII.utf8.count, 512)
        XCTAssertTrue(clippedASCII.hasSuffix("…"))

        let chinese = String(repeating: "晋", count: 400)   // 1200 字节
        let clippedCN = WeChatText.clip(chinese, maxBytes: 512)
        XCTAssertLessThanOrEqual(clippedCN.utf8.count, 512)
        XCTAssertTrue(clippedCN.hasSuffix("…"))
        XCTAssertFalse(clippedCN.contains("\u{FFFD}"), "裁剪不得切断多字节字符产生乱码")

        XCTAssertEqual(WeChatText.clip("短标题", maxBytes: 512), "短标题", "未超限文本原样返回")
        XCTAssertEqual(WeChatText.clip("   ", maxBytes: 512, fallback: "兜底"), "兜底", "空文本使用兜底值")
    }

    func testPayloadClippingContracts() {
        let payload = WeChatSharePayload(
            title: String(repeating: "山西晋中理工学院", count: 60),
            description: String(repeating: "校园资讯", count: 400),
            urlString: "https://www.sxjzit.edu.cn/#/list/article?id=1",
            thumbImageURL: nil
        )
        XCTAssertLessThanOrEqual(payload.clippedTitle.utf8.count, 512)
        XCTAssertLessThanOrEqual(payload.clippedDescription.utf8.count, 1024)

        let emptyTitle = WeChatSharePayload(title: "", description: "", urlString: "https://a.cn/", thumbImageURL: nil)
        XCTAssertFalse(emptyTitle.clippedTitle.isEmpty, "标题为空时必须使用兜底标题（官方要求标题非空）")
    }

    // MARK: - 缩略图契约（居中裁方 + ≤32KB JPEG）

    func testThumbnailCompressionContract() {
        let image = makeNoisyImage(width: 1600, height: 900)
        guard let data = WeChatThumbnailProvider.compress(image) else {
            XCTFail("缩略图压缩返回 nil")
            return
        }
        XCTAssertLessThanOrEqual(data.count, WeChatThumbnailProvider.maxThumbBytes,
                                 "缩略图必须 ≤32KB（官方硬限制 64KB）")
        XCTAssertLessThan(WeChatThumbnailProvider.maxThumbBytes, WeChatThumbnailProvider.hardLimitBytes)
        guard let decoded = UIImage(data: data) else {
            XCTFail("缩略图数据无法解码")
            return
        }
        XCTAssertEqual(decoded.size.width, WeChatThumbnailProvider.thumbSide, accuracy: 0.5)
        XCTAssertEqual(decoded.size.height, WeChatThumbnailProvider.thumbSide, accuracy: 0.5)
    }

    func testThumbnailCompressionHandlesPortraitImage() {
        let image = makeNoisyImage(width: 600, height: 1800)
        guard let data = WeChatThumbnailProvider.compress(image), let decoded = UIImage(data: data) else {
            XCTFail("竖图缩略图压缩失败")
            return
        }
        XCTAssertLessThanOrEqual(data.count, WeChatThumbnailProvider.maxThumbBytes)
        XCTAssertEqual(decoded.size.width, decoded.size.height, accuracy: 1.0, "缩略图必须为正方形（居中裁方）")
    }

    // MARK: - 场景映射（官方 WXScene 数值）

    func testSceneValuesMatchOfficialWXScene() {
        XCTAssertEqual(WeChatScene.session.sceneValue, 0, "WXSceneSession = 0")
        XCTAssertEqual(WeChatScene.timeline.sceneValue, 1, "WXSceneTimeline = 1")
        XCTAssertEqual(WeChatScene.favorite.sceneValue, 2, "WXSceneFavorite = 2")
        XCTAssertEqual(WeChatScene.allCases.count, 3)
        for scene in WeChatScene.allCases {
            XCTAssertFalse(scene.title.isEmpty)
            XCTAssertFalse(scene.symbolName.isEmpty)
            XCTAssertFalse(scene.subtitle.isEmpty)
        }
        XCTAssertEqual(Set(WeChatScene.allCases.map(\.logName)).count, 3, "日志场景名必须互异")
    }

    // MARK: - 可用性状态机不变量

    func testAvailabilityInvariants() {
        for availability in [WeChatAvailability.unconfigured, .sdkNotRegistered, .weChatNotInstalled, .weChatVersionTooLow, .ready] {
            XCTAssertFalse(availability.shortTitle.isEmpty)
            XCTAssertFalse(availability.userHint.isEmpty)
            XCTAssertEqual(availability.canOperate, availability == .ready, "仅 ready 状态允许发起微信操作")
        }
    }

    /// 服务单例：可用性与配置占位状态必须自洽（占位 ⇔ 未配置），且占位时不可操作
    func testServiceAvailabilityMatchesConfiguration() {
        let service = WeChatService.shared
        let availability = service.refreshAvailability()
        if service.configuration.isPlaceholder {
            XCTAssertEqual(availability, .unconfigured, "占位配置必须处于未配置状态")
            XCTAssertFalse(availability.canOperate, "未配置时不得发起任何微信操作")
        } else {
            XCTAssertNotEqual(availability, .unconfigured, "已配置时不应处于未配置状态")
        }
    }

    // MARK: - 自检七步

    func testSelfCheckStepTitles() {
        let titles = (0...WeChatService.selfCheckFinalStep).map { WeChatService.selfCheckStepTitle($0) }
        XCTAssertEqual(titles.count, 7, "官方 Universal Link 自检共七步")
        XCTAssertEqual(Set(titles).count, 7, "七步标题必须互异")
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(WeChatService.selfCheckFinalStep, 6, "WXULCheckStepFinal = 6")
        XCTAssertEqual(WeChatService.selfCheckStepTitle(99), "步骤 99", "未知步骤回退文案")
    }

    // MARK: - 横幅模型

    func testBannerModel() {
        let banner = WeChatBanner(kind: .success, text: "已分享到微信好友")
        XCTAssertEqual(banner.kind, .success)
        XCTAssertEqual(banner.text, "已分享到微信好友")
        XCTAssertNotEqual(WeChatBanner(kind: .info, text: "x"), banner, "横幅 id 唯一：内容相同也不等值")
    }

    /// 横幅生命周期：展示 → 可被指定 id 消隐 → 错误 id 不误清（回执横幅可见性契约）
    func testBannerLifecycle() {
        let service = WeChatService.shared
        service.showBanner("契约测试横幅", kind: .info)
        guard let banner = service.banner else {
            XCTFail("showBanner 后 banner 必须非空")
            return
        }
        XCTAssertEqual(banner.text, "契约测试横幅")
        service.clearBanner(id: UUID())
        XCTAssertNotNil(service.banner, "非当前 id 的消隐请求不得误清新横幅")
        service.clearBanner(id: banner.id)
        XCTAssertNil(service.banner, "当前 id 消隐后横幅必须清空")
    }

    // MARK: - 日志联通（埋点链路契约）

    /// 注册路径必须向既有日志系统写入 `wechat` 域条目（真机运行时验证埋点链路联通）
    func testRegistrationPathWritesWeChatLog() {
        let service = WeChatService.shared
        let before = LogManager.shared.entries.filter { $0.module == "wechat" }.count
        let registered = service.registerIfNeeded(reason: "contract_test")
        let after = LogManager.shared.entries.filter { $0.module == "wechat" }

        XCTAssertGreaterThan(after.count, before, "注册路径必须写入 wechat 域日志（埋点链路联通）")
        XCTAssertTrue(after.contains { $0.message.contains("注册") }, "日志须包含注册结果说明")
        XCTAssertTrue(after.allSatisfy { !$0.message.isEmpty })

        if service.configuration.isPlaceholder {
            // 占位配置的安全契约：不得注册成功、必须留 WARNING 级「占位」记录
            XCTAssertFalse(registered, "占位配置下不得报告注册成功")
            XCTAssertTrue(
                after.contains { $0.level == .warning && $0.message.contains("占位") },
                "占位配置必须留下 WARNING 级说明（含修复指引）"
            )
        }
    }

    // MARK: - 辅助

    /// 高频噪声图：纯色图 JPEG 压缩率过高，无法验证压缩链路；条纹提升熵值
    private func makeNoisyImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x: CGFloat = 0
            var i = 0
            while x < width {
                UIColor(hue: CGFloat(i % 60) / 60.0, saturation: 0.85, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: x, y: 0, width: 3, height: height))
                x += 6
                i += 7
            }
        }
    }
}