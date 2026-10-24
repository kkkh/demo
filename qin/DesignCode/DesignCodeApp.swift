//
//  DesignCodeApp.swift
//  山西晋中理工学院 APP
//

import SwiftUI
import UserNotifications

@main
struct DesignCodeApp: App {
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @ObservedObject private var biometricSecurity = BiometricSecurityManager.shared
    @ObservedObject private var weChatService = WeChatService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAppReady = false
    @AppStorage("privacyConsentAccepted") private var privacyConsentAccepted: Bool = false
    @AppStorage("privacyConsentRejected") private var privacyConsentRejected: Bool = false
    @State private var showPrivacyConsent: Bool = false
    @State private var showRestrictedMode: Bool = false

    init() {
        // F1 前置：扩容 URLCache.shared（内存 80MB / 磁盘 400MB）。
        // 协议层转发会话、统一图片组件、AsyncImage 均共享此缓存，图片滚动重复下载问题由此根治
        URLCache.shared = URLCache(memoryCapacity: 80 * 1024 * 1024,
                                   diskCapacity: 400 * 1024 * 1024,
                                   diskPath: "sxjzit_shared_cache")
        // 注册自定义 URLProtocol，为学校服务器请求自动添加 Referer 头，绕过防盗链
        URLProtocol.registerClass(RefererHeaderURLProtocol.self)
        // E9 内存警告降载监听
        CacheModeManager.shared.registerMemoryWarningHandler()
        // 应用图标启动校准：以系统实际生效图标为准，修正本地持久化记录
        AppIconManager.shared.calibrateOnLaunch()
        LogManager.shared.info("ui", "App 启动", context: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "urlCache": "80MB/400MB"
        ])
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // 主界面 —— 始终渲染，SplashView 淡出后自然显示
                MainTabView()
                    .opacity(isAppReady ? 1 : 0)

                // 启动页过渡层 —— 视觉与 LaunchScreen.storyboard 完全一致
                if !isAppReady {
                    SplashView(isAppReady: $isAppReady)
                        .zIndex(1)
                }

                // 首次启动隐私同意弹窗
                if showPrivacyConsent {
                    PrivacyConsentView(
                        showConsent: $showPrivacyConsent,
                        consentAccepted: $privacyConsentAccepted,
                        onAccept: {
                            LogManager.shared.info("privacy", "用户同意隐私协议，启动应用", context: [
                                "previousState": privacyConsentRejected ? "restricted" : "first_launch"
                            ])
                            if privacyConsentRejected {
                                LogManager.shared.info("privacy", "用户从受限模式同意隐私协议，恢复正常使用", context: [
                                    "transition": "restricted_to_normal"
                                ])
                            }
                            privacyConsentRejected = false
                        },
                        onReject: {
                            LogManager.shared.warning("privacy", "用户拒绝隐私协议，进入受限模式", context: [
                                "action": "reject",
                                "next": "restricted_mode"
                            ])
                            // 停止通知轮询等数据采集行为
                            notificationManager.stopPolling()
                            privacyConsentRejected = true
                            // 隐私弹窗关闭后，展示受限模式
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    showRestrictedMode = true
                                }
                            }
                        },
                        isFromRestrictedMode: privacyConsentRejected
                    )
                    .zIndex(2)
                    .transition(.opacity)
                }

                // 受限模式 —— 拒绝隐私协议后使用
                if showRestrictedMode {
                    RestrictedModeView(
                        showRestricted: $showRestrictedMode,
                        showConsent: $showPrivacyConsent
                    )
                    .zIndex(3)
                    .transition(.opacity)
                }

                // 生物识别安全遮罩 —— 锁定 / 认证期间遮挡全部内容（防多任务预览泄露）
                if biometricSecurity.isEnabled
                    && (biometricSecurity.state == .locked || biometricSecurity.state == .authenticating)
                    && privacyConsentAccepted
                    && isAppReady
                    && !showRestrictedMode {
                    BiometricLockOverlayView()
                        .zIndex(4)
                        .transition(.opacity)
                }

                // 微信回执横幅 —— 分享/登录结果可见载体（层级低于生物识别遮罩：锁定期间自动隐藏）
                WeChatBannerOverlay()
                    .zIndex(3.5)
            }
            .task {
                // 启动动画完成后，过渡到主页（不人为延时，仅等待动画自然完成）
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0 秒
                isAppReady = true
            }
            .tint(displaySettings.themeStyle.color)
            .displayTypography(displaySettings)
            // 微信回跳处理（官方双通道：URL Scheme + Universal Link，统一交给 WeChatService 回执中枢）
            .onOpenURL { url in
                weChatService.handle(openURL: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                weChatService.handle(userActivity: activity)
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    biometricSecurity.handleDidEnterBackground()
                    // 退后台立即落盘待写日志（防进程被系统回收丢失最近 0.5s 内的记录）
                    let pending = LogManager.shared.flushPendingNow()
                    if pending == 0 {
                        LogManager.shared.debugLog("log", "退后台日志落盘完成", context: [:])
                    }
                case .active:
                    biometricSecurity.handleReturnToForeground()
                    // 回到前台时校准微信可用性（用户可能刚安装/升级微信）
                    weChatService.refreshAvailability()
                default:
                    break
                }
            }
            .task(id: isAppReady) {
                // 启动时刷新通知权限状态
                await notificationManager.refreshAuthorizationStatus()
                // 如果已授权且已启用，恢复轮询（仅当隐私已同意时）
                if privacyConsentAccepted && notificationManager.isAuthorized && notificationManager.isEnabled {
                    notificationManager.startPolling()
                }
            }
            .task(id: privacyConsentAccepted) {
                // 微信 SDK 注册（官方要求每次启动注册一次）
                // 隐私优先：仅在用户同意隐私协议后注册；拒绝（受限模式）则完全跳过，不发任何微信请求
                guard privacyConsentAccepted else {
                    LogManager.shared.debugLog("wechat", "隐私未同意，跳过微信 SDK 注册")
                    return
                }
                weChatService.registerIfNeeded(reason: "privacy_consent")
            }
            .onChange(of: isAppReady) { _, ready in
                // 启动页结束后，根据隐私状态决定显示内容
                if ready {
                    if !privacyConsentAccepted {
                        if privacyConsentRejected {
                            // 用户之前已拒绝 → 直接进入受限模式
                            LogManager.shared.info("privacy", "检测到用户之前已拒绝隐私协议，直接进入受限模式", context: [
                                "privacyConsentRejected": "true",
                                "entry": "auto_on_launch"
                            ])
                            showRestrictedModeAfterDelay()
                        } else {
                            // 首次启动 → 显示隐私同意弹窗
                            LogManager.shared.info("privacy", "首次启动，展示隐私同意弹窗", context: [
                                "entry": "first_launch"
                            ])
                            showPrivacyConsentAfterDelay()
                        }
                    } else {
                        // 用户已同意隐私协议，正常启动
                        LogManager.shared.debugLog("privacy", "用户已同意隐私协议，正常启动", context: [
                            "entry": "normal_launch",
                            "privacyConsentRejected": "\(privacyConsentRejected)"
                        ])
                    }
                }
            }
        }
    }

    @MainActor
    private func showPrivacyConsentAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒
            withAnimation(.easeInOut(duration: 0.35)) {
                showPrivacyConsent = true
            }
            LogManager.shared.info("privacy", "隐私同意弹窗已展示（首次启动）", context: [
                "trigger": "first_launch"
            ])
        }
    }

    @MainActor
    private func showRestrictedModeAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒
            withAnimation(.easeInOut(duration: 0.35)) {
                showRestrictedMode = true
            }
            LogManager.shared.info("privacy", "受限模式视图已展示（启动后自动进入）", context: [
                "trigger": "auto_on_launch",
                "privacyConsentRejected": "true"
            ])
        }
    }
}