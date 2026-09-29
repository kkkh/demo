//
//  WeChatIntegrationViews.swift
//  山西晋中理工学院 APP — 微信集成界面（分享菜单 / 状态与自检中心 / 全局横幅）
//
//  构成：
//  · WeChatShareMenu     文章分享入口弹出的场景选择（好友 / 朋友圈 / 收藏）
//  · WeChatIntegrationView  设置页「微信集成」子页：状态总览 / 分享能力 / 自检 / 登录 / 小程序 / 配置指引
//  · WeChatBannerOverlay 全局横幅：分享与登录回执的可见载体（根视图悬浮，自动消隐）
//
//  显示设置契约：全部文本/图标走 display* 排版链；作为弹出层内容的分享菜单由调用方挂载
//  .sjzPresentationChrome()（外观 + 专注灰度跨 presentation 注入）。
//

import SwiftUI

// MARK: - 微信品牌色（文件内私有）

private extension Color {
    /// 微信品牌绿（官方 #07C160）
    static var weChatGreen: Color { Color(lightHex: "07C160", darkHex: "3FD07F") }
    /// 朋友圈绿
    static var weChatTimeline: Color { Color(lightHex: "1AAD19", darkHex: "52C95B") }
}

/// 场景品牌色
private func sceneTint(_ scene: WeChatScene) -> Color {
    switch scene {
    case .session:  return .weChatGreen
    case .timeline: return .weChatTimeline
    case .favorite: return .sjzGold
    }
}

// MARK: - 可用性徽章

/// 微信可用性徽章（设置页与状态页共用）
struct WeChatAvailabilityBadge: View {
    let availability: WeChatAvailability

    static func tint(_ availability: WeChatAvailability) -> Color {
        switch availability {
        case .ready:               return .sjzGreen
        case .unconfigured:        return .sjzOrange
        case .weChatNotInstalled:  return .sjzOrange
        case .weChatVersionTooLow: return .sjzOrange
        case .sdkNotRegistered:    return .sjzRed
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.tint(availability))
                .frame(width: 6, height: 6)
            Text(availability.shortTitle)
                .displayFont(12, weight: .medium)
                .foregroundStyle(Self.tint(availability))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Self.tint(availability).opacity(0.12), in: Capsule())
    }
}

// MARK: - 微信分享菜单（文章分享入口）

/// 微信分享菜单：文章分享入口弹出的场景选择。
/// 调用方（文章详情）使用方式：
/// ```swift
/// .sheet(item: $weChatShare) { payload in
///     WeChatShareMenu(payload: payload)
///         .sjzPresentationChrome()
/// }
/// ```
struct WeChatShareMenu: View {
    let payload: WeChatSharePayload

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WeChatService.shared
    @State private var sendingScene: WeChatScene?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if service.availability.canOperate {
                sceneRow
            } else {
                unavailableNotice
            }
            footer
        }
        .padding(.bottom, 10)
        .presentationDetents([.height(service.availability.canOperate ? 344 : 306)])
        .presentationDragIndicator(.visible)
        .onAppear {
            service.refreshAvailability()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                appeared = true
            }
            LogManager.shared.debugLog("wechat", "分享菜单展示", context: [
                "title": payload.clippedTitle,
                "availability": service.availability.rawValue,
                "hasThumb": "\((payload.thumbImageURL?.isEmpty == false) || payload.thumbImage != nil)"
            ])
        }
    }

    // MARK: 头部（文章卡片摘要）

    private var header: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text(payload.clippedTitle)
                    .displayText(size: 14, weight: .semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .displaySymbolFont(9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    Text(payload.urlHost)
                        .displayFont(11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -6)
    }

    private var thumbnail: some View {
        Group {
            if let urlString = payload.thumbImageURL, let url = URL(string: urlString), !urlString.isEmpty {
                SJZCachedImage(url: url, maxPixel: 200) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        Color.sjzLight.overlay { ProgressView().controlSize(.mini) }
                    case .skipped:
                        SJZImageFreePlaceholder(icon: "newspaper")
                    case .failure:
                        SJZImageFreePlaceholder(icon: "newspaper")
                    }
                }
            } else {
                SJZImageFreePlaceholder(icon: "newspaper")
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 场景选择（共用组件：三场景磁贴，网页卡片与长图分享共用）

    private var sceneRow: some View {
        WeChatSceneTiles(sendingScene: sendingScene, appeared: appeared) { scene in
            send(scene)
        }
    }

    /// 不可用状态（未配置 / 未安装 / 版本过低）：给出可操作提示，不隐藏入口
    private var unavailableNotice: some View {
        WeChatUnavailableNotice(appeared: appeared)
    }

    // MARK: 底注

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .displaySymbolFont(10)
                .foregroundStyle(.tertiary)
            Text("发送网页卡片：标题 + 摘要 + 链接（缩略图自动生成）")
                .displayFont(11)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if service.sdkVersion != "—" {
                Text("SDK \(service.sdkVersion)")
                    .displayFont(10)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: 发送

    private func send(_ scene: WeChatScene) {
        guard sendingScene == nil else { return }
        sendingScene = scene
        LogManager.shared.info("wechat", "分享菜单选择场景", context: [
            "scene": scene.logName,
            "title": payload.clippedTitle,
            "url": payload.urlString
        ])
        Task {
            let sent = await service.share(payload, to: scene)
            if sent {
                // 系统随即切换到微信（本页被覆盖）：先收起菜单，返回时直接回到文章
                dismiss()
            } else {
                sendingScene = nil
            }
        }
    }
}

// MARK: - 场景磁贴（网页卡片与长图分享共用）

/// 三场景磁贴（好友 / 朋友圈 / 收藏）：发送中显示进度遮罩，其余磁贴淡出禁用。
/// 网页卡片（`WXWebpageObject`）与长图（`WXImageObject`）共用同一交互与动效。
struct WeChatSceneTiles: View {
    let sendingScene: WeChatScene?
    let appeared: Bool
    let onSend: (WeChatScene) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WeChatScene.allCases) { scene in
                tile(scene)
                if scene != WeChatScene.allCases.last {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private func tile(_ scene: WeChatScene) -> some View {
        let tint = sceneTint(scene)
        let isSending = sendingScene == scene
        return Button {
            onSend(scene)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(tint.opacity(0.13))
                        .frame(width: 56, height: 56)
                    Image(systemName: scene.symbolName)
                        .displaySymbolFont(23, weight: .semibold)
                        .foregroundStyle(tint)
                    if isSending {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 56, height: 56)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(tint.opacity(isSending ? 0.45 : 0.16), lineWidth: 1)
                        .frame(width: 56, height: 56)
                )
                Text(scene.title)
                    .displayText(size: 13, weight: .medium)
                    .foregroundStyle(sendingScene == nil || isSending ? .primary : .tertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sendingScene != nil)
        .scaleEffect(isSending ? 0.96 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isSending)
    }
}

// MARK: - 不可用状态提示（网页卡片与长图分享共用）

/// 不可用状态（未配置 / 未安装 / 版本过低）：给出可操作提示，不隐藏入口
struct WeChatUnavailableNotice: View {
    @ObservedObject private var service = WeChatService.shared
    let appeared: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .displaySymbolFont(15)
                    .foregroundStyle(WeChatAvailabilityBadge.tint(service.availability))
                VStack(alignment: .leading, spacing: 6) {
                    Text(service.availability.userHint)
                        .displayText(size: 13, baseLineSpacing: 2)
                        .multilineTextAlignment(.leading)
                    if service.availability == .unconfigured {
                        Text("配置完成前，微信分享入口保持只读状态，不影响其它分享方式。")
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if !service.isWeChatInstalled, let installURL = service.weChatInstallURL {
                Link(destination: installURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .displaySymbolFont(13, weight: .semibold)
                        Text("前往 App Store 安装微信")
                            .displayFont(13, weight: .medium)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.weChatGreen, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .opacity(appeared ? 1 : 0)
    }
}

// MARK: - 长图分享到微信（WXImageObject）

/// 长图分享目标：系统分享面板（保存 / 其他 App）或微信图片消息（WXImageObject）
enum LongImageDestination {
    case system
    case weChat
}

/// 长图分享载荷（长图分享面板的输入）
struct WeChatLongImagePayload: Identifiable {
    let id = UUID()
    /// 已生成的文章长图（正文整图）
    let image: UIImage
    /// 文章标题（作为图片消息标题，≤512B 自动裁剪）
    let title: String
    /// 入口标识（日志归因，如 "news_detail" / "organization_detail"）
    let entry: String
    /// 头部预览小图（顶部裁方 200pt，构造期一次生成，与官方缩略图同一裁切核心）：
    /// 菜单头部直接绘制可能上万像素高的长图有明显开销，此处在载荷构造期收敛为小图
    let previewImage: UIImage

    init(image: UIImage, title: String, entry: String) {
        self.image = image
        self.title = title
        self.entry = entry
        self.previewImage = WeChatThumbnailProvider.topSquarePreview(
            from: image,
            side: WeChatThumbnailProvider.thumbSide
        ) ?? image
    }
}

/// 微信长图分享菜单：把已生成的文章长图作为图片消息发送到微信
/// （官方 WXImageObject；官方 iOS 手册的图片分享示例即使用 WXSceneTimeline，三场景均受支持）
struct WeChatLongImageShareMenu: View {
    let payload: WeChatLongImagePayload

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WeChatService.shared
    @State private var sendingScene: WeChatScene?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if service.availability.canOperate {
                WeChatSceneTiles(sendingScene: sendingScene, appeared: appeared) { scene in
                    send(scene)
                }
            } else {
                WeChatUnavailableNotice(appeared: appeared)
            }
            footer
        }
        .padding(.bottom, 10)
        .presentationDetents([.height(service.availability.canOperate ? 344 : 306)])
        .presentationDragIndicator(.visible)
        .onAppear {
            service.refreshAvailability()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                appeared = true
            }
            LogManager.shared.debugLog("wechat", "长图分享菜单展示", context: [
                "kind": WeChatShareKind.longImage.logName,
                "entry": payload.entry,
                "title": payload.title,
                "pixelSize": SJZImageIntegrity.pixelSizeText(of: payload.image),
                "preview": "\(Int(payload.previewImage.size.width))x\(Int(payload.previewImage.size.height))",
                "availability": service.availability.rawValue
            ])
        }
    }

    // MARK: 头部（长图预览 + 尺寸）

    private var header: some View {
        HStack(spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                Text(payload.title)
                    .displayText(size: 14, weight: .semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .displaySymbolFont(9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    Text("长图 · \(Int(payload.image.size.width)) × \(Int(payload.image.size.height))")
                        .displayFont(11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -6)
    }

    /// 长图预览：载荷构造期生成的顶部裁方小图（与缩略图同一裁切核心），弹出即显、零绘制卡顿
    private var preview: some View {
        Image(uiImage: payload.previewImage)
            .resizable()
            .scaledToFill()
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text("长图")
                    .displayFont(8, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(3)
            }
    }

    // MARK: 底注

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .displaySymbolFont(10)
                .foregroundStyle(.tertiary)
            Text("发送长图：正文整图作为图片消息发出，超 10MB 自动压缩")
                .displayFont(11)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if service.sdkVersion != "—" {
                Text("SDK \(service.sdkVersion)")
                    .displayFont(10)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: 发送

    private func send(_ scene: WeChatScene) {
        guard sendingScene == nil else { return }
        sendingScene = scene
        LogManager.shared.info("wechat", "长图分享菜单选择场景", context: [
            "kind": WeChatShareKind.longImage.logName,
            "scene": scene.logName,
            "entry": payload.entry,
            "title": payload.title,
            "pixelSize": SJZImageIntegrity.pixelSizeText(of: payload.image)
        ])
        Task {
            let sent = await service.shareImage(payload.image, title: payload.title, to: scene, entry: payload.entry)
            if sent {
                // 系统随即切换到微信（本页被覆盖）：先收起菜单，返回时直接回到文章
                dismiss()
            } else {
                sendingScene = nil
            }
        }
    }
}

// MARK: - 全局横幅（回执可见载体）

/// 全局横幅：微信分享/登录回执与状态提示的悬浮展示（根视图挂载，自动消隐，可点击关闭）
struct WeChatBannerOverlay: View {
    @ObservedObject private var service = WeChatService.shared

    private func tint(_ kind: WeChatBanner.Kind) -> Color {
        switch kind {
        case .success: return .sjzGreen
        case .info:    return .sjzAccent
        case .failure: return .sjzOrange
        }
    }

    private func icon(_ kind: WeChatBanner.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack {
            if let banner = service.banner {
                HStack(spacing: 9) {
                    Image(systemName: icon(banner.kind))
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(tint(banner.kind))
                    Text(banner.text)
                        .displayFont(14, weight: .medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(tint(banner.kind).opacity(0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        service.clearBanner(id: banner.id)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    // 3.2s 自动消隐（id 变化自动重启计时）
                    try? await Task.sleep(nanoseconds: 3_200_000_000)
                    withAnimation(.easeInOut(duration: 0.35)) {
                        service.clearBanner(id: banner.id)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: service.banner?.id)
        .allowsHitTesting(service.banner != nil)
    }
}

// MARK: - 微信集成中心（设置页子页）

/// 微信集成中心：状态总览 / 分享能力 / Universal Link 自检 / 微信登录 / 小程序 / 接入配置指引
struct WeChatIntegrationView: View {
    @ObservedObject private var service = WeChatService.shared
    @State private var didLogEntry = false

    var body: some View {
        Form {
            statusSection
            shareSection
            selfCheckSection
            authSection
            miniProgramSection
            configGuideSection
        }
        .navigationTitle("微信集成")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            service.refreshAvailability()
            guard !didLogEntry else { return }
            didLogEntry = true
            LogManager.shared.info("wechat", "微信集成中心打开", context: [
                "availability": service.availability.rawValue,
                "registered": "\(service.isRegistered)",
                "installed": "\(service.isWeChatInstalled)",
                "sdkVersion": service.sdkVersion,
                "configured": service.configuration.isPlaceholder ? "placeholder" : "configured"
            ])
        }
    }

    // MARK: 状态总览

    private var statusSection: some View {
        Section {
            HStack {
                Text("当前状态")
                    .displayFont(15)
                Spacer()
                WeChatAvailabilityBadge(availability: service.availability)
            }
            infoRow("AppID", service.configuration.maskedAppID)
            infoRow("Universal Link", service.configuration.universalLinkHost)
            infoRow("SDK 版本", service.sdkVersion)
            infoRow("微信客户端", service.isWeChatInstalled ? "已安装" : "未安装")
            HStack(spacing: 12) {
                Button {
                    let result = service.refreshAvailability()
                    LogManager.shared.info("wechat", "状态刷新（手动）", context: [
                        "availability": result.rawValue,
                        "registered": "\(service.isRegistered)",
                        "installed": "\(service.isWeChatInstalled)"
                    ])
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .displayLabelFont(14)
                if !service.isRegistered {
                    Button {
                        let ok = service.registerIfNeeded(reason: "settings_manual")
                        service.showBanner(ok ? "微信 SDK 注册成功" : "注册未成功，请检查配置", kind: ok ? .success : .failure)
                    } label: {
                        Label("重新注册", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .displayLabelFont(14)
                }
            }
        } header: {
            Text("状态总览").displayFont(13, weight: .semibold)
        } footer: {
            Text(service.availability.userHint)
                .displayFont(13)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .displayFont(15)
            Spacer()
            Text(value)
                .displayFont(13)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: 分享能力

    private var shareSection: some View {
        Section {
            Text("已接入微信分享：任意文章详情页点击分享按钮 →「分享到微信」，即可发送网页卡片（好友 / 朋友圈 / 收藏）。缩略图自动从文章配图生成，标题与摘要按微信限制自动裁剪。")
                .displayText(size: 13, baseLineSpacing: 3)
                .foregroundStyle(.secondary)
            Button {
                let ok = service.openWeChatApp()
                if !ok {
                    service.showBanner("未能打开微信（请确认已安装）", kind: .failure)
                }
            } label: {
                Label("打开微信", systemImage: "arrow.up.forward.app.fill")
            }
            .displayLabelFont(14)
            .disabled(!service.isWeChatInstalled)
        } header: {
            Text("分享能力").displayFont(13, weight: .semibold)
        } footer: {
            Text("分享回执（成功 / 取消 / 失败）会在返回本 App 后以横幅提示，并写入日志（wechat 域）。")
                .displayFont(13)
        }
    }

    // MARK: Universal Link 自检

    private var selfCheckSection: some View {
        Section {
            Button {
                Task { await service.runUniversalLinkSelfCheck() }
            } label: {
                HStack {
                    Label("运行 Universal Link 自检（官方七步）", systemImage: "checkmark.seal.fill")
                    Spacer()
                    if service.isSelfChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .displayLabelFont(14)
            .disabled(service.isSelfChecking || !service.availability.canOperate)

            if !service.selfCheckItems.isEmpty {
                ForEach(service.selfCheckItems) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .displaySymbolFont(14, weight: .semibold)
                            .foregroundStyle(item.success ? Color.sjzGreen : Color.sjzRed)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .displayFont(14, weight: .medium)
                            if !item.errorInfo.isEmpty {
                                Text(item.errorInfo)
                                    .displayFont(12)
                                    .foregroundStyle(.secondary)
                            }
                            if !item.suggestion.isEmpty {
                                Text(item.suggestion)
                                    .displayFont(12)
                                    .foregroundStyle(Color.sjzOrange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                Button("清空自检结果") {
                    service.clearSelfCheck()
                }
                .displayFont(14)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Universal Link 自检").displayFont(13, weight: .semibold)
        } footer: {
            Text("自检需已配置真实 AppID 与 Universal Link。第 5 步会短暂拉起微信，请按提示返回本 App；自检期间 SDK 自动切换为详细日志（wechat 域）。")
                .displayFont(13)
        }
    }

    // MARK: 微信登录

    private var authSection: some View {
        Section {
            Button {
                Task { _ = await service.startAuth() }
            } label: {
                Label("获取微信登录授权码", systemImage: "person.badge.key.fill")
            }
            .displayLabelFont(14)
            .disabled(!service.availability.canOperate)

            if let code = service.lastAuthCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近授权码")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .displayFont(12, design: .monospaced)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        } header: {
            Text("微信登录").displayFont(13, weight: .semibold)
        } footer: {
            Text("官方流程：客户端获取授权码（code）→ 服务端用 AppSecret 换取 access_token 与用户信息。客户端不存储任何微信用户隐私数据。")
                .displayFont(13)
        }
    }

    // MARK: 小程序跳转

    private var miniProgramSection: some View {
        Section {
            Button {
                Task {
                    _ = await service.launchMiniProgram(fallbackWebpageURL: "https://www.sxjzit.edu.cn/")
                }
            } label: {
                Label("跳转学校小程序", systemImage: "square.grid.3x3.fill")
            }
            .displayLabelFont(14)
            .disabled(!service.availability.canOperate)
            if !service.configuration.hasMiniProgram {
                Text("未配置小程序原始 ID：在构建设置填写 WECHAT_MINI_PROGRAM（gh_ 开头）后启用。")
                    .displayFont(12)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("小程序").displayFont(13, weight: .semibold)
        } footer: {
            Text("需在微信开放平台关联小程序，并拿到小程序原始 ID（gh_ 开头）。未配置时不发起任何请求。")
                .displayFont(13)
        }
    }

    // MARK: 接入配置指引

    private var configGuideSection: some View {
        Section {
            guideRow(1, "在微信开放平台（open.weixin.qq.com）注册移动应用，获得 AppID（wx 开头 18 位）")
            guideRow(2, "在 Xcode → Target → Build Settings 填写 WECHAT_APPID / WECHAT_UNIVERSAL_LINK / WECHAT_UL_HOST / WECHAT_MINI_PROGRAM")
            guideRow(3, "服务器部署 AASA 文件：https://<域名>/.well-known/apple-app-site-association（模板见 docs/wechat-integration/apple-app-site-association）")
            guideRow(4, "在微信开放平台填写同一 Universal Link，并开通「分享到微信」「微信登录」能力")
            guideRow(5, "回到本页运行自检：七步全绿即接入成功")
            if service.configuration.isPlaceholder {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(Color.sjzOrange)
                    Text("当前为占位配置：微信入口保持可见但不可用，所有操作均记录日志且不发起网络请求，其它功能不受影响。")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("接入配置指引").displayFont(13, weight: .semibold)
        } footer: {
            Text("配置仅需改动一处：构建设置（Debug 与 Release 各一份），Info.plist 与 entitlements 自动注入。")
                .displayFont(13)
        }
    }

    private func guideRow(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .displayFont(11, weight: .bold, design: .rounded)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.sjzAccent.opacity(0.85)))
            Text(text)
                .displayText(size: 13, baseLineSpacing: 2)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}