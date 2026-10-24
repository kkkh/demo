//
//  NotificationTestView.swift
//  山西晋中理工学院 APP — 通知测试中心
//
//  完整验证系统通知链路的测试工具：权限探测、系统送达测试、前台横幅测试、
//  点击跳转链路测试、应用角标测试。全部操作已接入现有日志系统（notificationTest 模块）。
//

import SwiftUI
import UserNotifications

// MARK: - 通知测试中心

struct NotificationTestView: View {
    @ObservedObject private var notificationManager = NotificationManager.shared
    @AppStorage("notificationPermissionRequested") private var permissionRequested: Bool = false

    /// 单条测试记录
    private struct TestRecord: Identifiable {
        enum Phase {
            case pending   // 进行中（等待结果回显）
            case success
            case failure
        }

        let id = UUID()
        let time: Date
        let title: String
        var phase: Phase
        var message: String

        var isSuccess: Bool { phase == .success }
    }

    @State private var results: [TestRecord] = []
    @State private var isRefreshingAuth = false
    @State private var isRequestingPermission = false
    @State private var isSendingBanner = false
    @State private var isSendingBackground = false
    @State private var isSimulatingTap = false
    @State private var isSettingBadge = false
    @State private var pendingSimulateRecordId: UUID?
    @State private var lastHandledOutcome: DeepLinkOutcome?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Form {
            permissionSection
            deliverySection
            tapChainSection
            badgeSection
            resultsSection
        }
        .navigationTitle("通知测试")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            LogManager.shared.info("notificationTest", "进入通知测试页", context: [
                "authorized": "\(notificationManager.isAuthorized)",
                "badgeSetting": notificationManager.badgeSettingText
            ])
            refreshAuth()
            // 同步回放：若在其他页面点击通知失败，进入本页即可看到原因
            handleDeepLinkOutcome(notificationManager.deepLinkOutcome)
        }
        .onChange(of: notificationManager.deepLinkOutcome) { _, outcome in
            handleDeepLinkOutcome(outcome)
        }
        .onDisappear {
            LogManager.shared.debugLog("notificationTest", "离开通知测试页", context: [:])
        }
    }

    // MARK: - 权限探测

    private var permissionSection: some View {
        Section {
            HStack {
                Label("通知权限", systemImage: notificationManager.isAuthorized ? "checkmark.shield.fill" : "shield.slash.fill")
                    .foregroundStyle(notificationManager.isAuthorized ? Color.sjzGreen : Color.sjzOrange)
                Spacer()
                if isRefreshingAuth || isRequestingPermission {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button("刷新") {
                        refreshAuth()
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Text(notificationManager.authorizationDetailText)
                    .displayFont(13)
                    .foregroundStyle(.secondary)
                Spacer()
                if notificationManager.isAuthorized {
                    Text("已就绪")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(Color.sjzGreen)
                }
            }

            if !notificationManager.isAuthorized {
                if notificationManager.authorizationDetailText.hasPrefix("未决定") {
                    Button {
                        requestPermission()
                    } label: {
                        HStack { Spacer(); Label("请求通知权限", systemImage: "bell.badge.fill"); Spacer() }
                    }
                } else {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        LogManager.shared.info("notificationTest", "打开系统通知设置", context: [
                            "from": "permission_section"
                        ])
                        notificationManager.openSystemSettings()
                    } label: {
                        HStack { Spacer(); Label("前往系统设置开启", systemImage: "gear.badge"); Spacer() }
                    }
                }
            }
        } header: {
            Text("权限探测")
        } footer: {
            Text("只有系统通知权限开启后，任何测试通知才能被系统接受并送达。返回本页会随本次探测自动刷新状态。")
        }
    }

    // MARK: - 系统送达与横幅测试

    private var deliverySection: some View {
        Section {
            Button {
                runBannerTest()
            } label: {
                testButtonLabel(
                    icon: "rectangle.topthird.inset.filled",
                    title: "前台横幅测试",
                    subtitle: "保持 App 在前台，2 秒后以系统横幅弹出",
                    color: Color.sjzAccent,
                    isLoading: isSendingBanner,
                    isEnabled: !isSendingBanner && !isSendingBackground
                )
            }
            .disabled(isSendingBanner || isSendingBackground)

            Button {
                runBackgroundTest()
            } label: {
                testButtonLabel(
                    icon: "iphone.gen3.badge.play",
                    title: "后台 / 锁屏送达测试",
                    subtitle: "点击后立即退回桌面或锁屏，5 秒后送达",
                    color: Color.sjzTeal,
                    isLoading: isSendingBackground,
                    isEnabled: !isSendingBanner && !isSendingBackground
                )
            }
            .disabled(isSendingBanner || isSendingBackground)
        } header: {
            Text("系统送达与横幅")
        } footer: {
            Text("两次测试共用同一条真实文章（若已联网同步）。退到后台/锁屏收到后点击它，可一并验证「点击通知跳转文章详情」的完整链路。")
        }
    }

    // MARK: - 点击跳转链路测试

    private var tapChainSection: some View {
        Section {
            Button {
                simulateTap()
            } label: {
                testButtonLabel(
                    icon: "hand.tap.fill",
                    title: "模拟点击通知",
                    subtitle: "与真实点击走完全相同的内部链路，直接打开文章详情",
                    color: Color.sjzPurple,
                    isLoading: isSimulatingTap,
                    isEnabled: !isSimulatingTap
                )
            }
            .disabled(isSimulatingTap)

            if !notificationManager.isAuthorized {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("模拟链路不依赖系统权限，未授权也可测试")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("点击跳转链路")
        } footer: {
            Text("模拟链路：广播点击事件 → 主界面登记文章 → 等待前台活跃与安全解锁 → 自动打开文章详情。日志记录完整过程。")
        }
    }

    // MARK: - 角标测试

    private var badgeSection: some View {
        Section {
            HStack(spacing: 12) {
                // 关键：Form 行内多个 Button 必须逐个指定 .borderless，
                // 否则 List 会把整行点击都命中第一个按钮 —— 表现为「点清除却执行设置 1」
                Button {
                    applyBadge(1, actionTitle: "设置角标")
                } label: {
                    capsuleLabel("设置角标 1", icon: "1.circle.fill", isLoading: isSettingBadge)
                }
                .buttonStyle(.borderless)
                .disabled(isSettingBadge)

                Button {
                    applyBadge(0, actionTitle: "清除角标")
                } label: {
                    capsuleLabel("清除角标", icon: "delete.left.fill", isLoading: isSettingBadge)
                }
                .buttonStyle(.borderless)
                .disabled(isSettingBadge)

                if isSettingBadge {
                    ProgressView().scaleEffect(0.7)
                }
            }

            HStack {
                Label("系统「标记」许可", systemImage: "app.badge")
                Spacer()
                Text(notificationManager.badgeSettingText)
                    .displayFont(13)
                    .foregroundStyle(notificationManager.badgeSettingText.hasPrefix("已开启") ? Color.sjzGreen : .orange)
            }
        } header: {
            Text("应用角标")
        } footer: {
            Text("角标数字显示在桌面 App 图标右上角，设置为 0 即清除。若系统「标记」已关闭，需前往系统设置 → 通知 → 「园枢」开启「标记」后角标才能生效。")
        }
    }

    // MARK: - 测试记录

    private var resultsSection: some View {
        Section {
            if results.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "bell.and.waves.left.and.right")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("暂无测试记录")
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                ForEach(results) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            switch record.phase {
                            case .pending:
                                ProgressView()
                                    .scaleEffect(0.75)
                                    .frame(width: 15, height: 15)
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.sjzGreen)
                            case .failure:
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.sjzRed)
                            }
                        }
                        .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(record.title)
                                    .displayFont(14, weight: .medium)
                                if record.phase == .pending {
                                    Text("进行中…")
                                        .displayFont(11, weight: .medium)
                                        .foregroundStyle(Color.sjzAccent)
                                }
                            }
                            Text(record.message)
                                .displayFont(12)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.timeFormatter.string(from: record.time))
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("测试记录")
        } footer: {
            Text("全部测试操作均已写入应用日志（模块 notificationTest / notification），可在「我的 → 应用日志」中查看完整链路。")
        }
    }

    // MARK: - 共享控件

    /// 测试按钮统一外观
    private func testButtonLabel(icon: String, title: String, subtitle: String, color: Color, isLoading: Bool, isEnabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .displayFont(15, weight: .medium)
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                Text(subtitle)
                    .displayFont(12)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 胶囊小按钮
    private func capsuleLabel(_ text: String, icon: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .displayLabelFont(13, weight: .medium)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.sjzAccent.opacity(isLoading ? 0.4 : 1), in: Capsule())
        .foregroundStyle(.white)
    }

    // MARK: - 交互逻辑

    private func refreshAuth() {
        guard !isRefreshingAuth else { return }
        isRefreshingAuth = true
        LogManager.shared.info("notificationTest", "刷新通知权限状态", context: [:])
        Task {
            await notificationManager.refreshAuthorizationStatus()
            isRefreshingAuth = false
            append(result: .success("权限状态已刷新：\(notificationManager.authorizationDetailText)"), title: "权限探测")
        }
    }

    private func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        LogManager.shared.info("notificationTest", "请求系统通知权限", context: [:])
        Task {
            let granted = await notificationManager.requestPermission()
            isRequestingPermission = false
            permissionRequested = true
            append(
                result: granted
                    ? .success("系统授权成功，可以开始测试")
                    : .failure("未获得系统授权，无法接收通知"),
                title: "请求通知权限"
            )
        }
    }

    private func runBannerTest() {
        guard !isSendingBanner else { return }
        isSendingBanner = true
        LogManager.shared.info("notificationTest", "启动前台横幅测试", context: [
            "delay": "2s", "expect": "willPresent 系统横幅"
        ])
        Task {
            let result = await notificationManager.sendTestNotification(
                delaySeconds: 2, useRealArticle: true, source: "banner_test")
            isSendingBanner = false
            append(result: result, title: "前台横幅测试")
        }
    }

    private func runBackgroundTest() {
        guard !isSendingBackground else { return }
        isSendingBackground = true
        LogManager.shared.info("notificationTest", "启动后台送达测试", context: [
            "delay": "5s", "expect": "退到后台或锁屏后送达"
        ])
        Task {
            let result = await notificationManager.sendTestNotification(
                delaySeconds: 5, useRealArticle: true, source: "background_test")
            isSendingBackground = false
            append(result: result, title: "后台 / 锁屏送达测试")
        }
    }

    private func simulateTap() {
        guard !isSimulatingTap else { return }
        isSimulatingTap = true
        LogManager.shared.info("notificationTest", "启动模拟点击测试", context: ["path": "didReceive 同链路"])
        Task {
            let result = await notificationManager.simulateNotificationTap()
            isSimulatingTap = false

            if result.isSuccess {
                // 先记录「进行中」，等待 MainTabView 弹窗后通过 deepLinkOutcome 回显最终结果
                let record = TestRecord(
                    time: Date(), title: "模拟点击通知",
                    phase: .pending, message: "已触发跳转链路，等待详情页打开…")
                pendingSimulateRecordId = record.id
                insert(record)
            } else {
                append(result: result, title: "模拟点击通知")
            }
        }
    }

    /// 处理 DeepLink 结果回显：升级「进行中」记录为成功/失败；非测试页触发的失败也补记一条。
    /// 同一 outcome 只处理一次（onAppear 回放与 onChange 实时到达可能重复）
    private func handleDeepLinkOutcome(_ outcome: DeepLinkOutcome?) {
        guard let outcome, outcome != lastHandledOutcome else { return }
        lastHandledOutcome = outcome

        LogManager.shared.info("notificationTest", "DeepLink 结果回显", context: [
            "articleId": outcome.articleId,
            "success": "\(outcome.isSuccess)"
        ])

        if let pendingId = pendingSimulateRecordId,
           let index = results.firstIndex(where: { $0.id == pendingId }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                results[index].phase = outcome.isSuccess ? .success : .failure
                results[index].message = outcome.message
            }
            pendingSimulateRecordId = nil
            return
        }
        // 无匹配的进行中记录：仅失败时补记一条原因记录
        if case .failed = outcome {
            append(
                result: .failure(outcome.message),
                title: "通知详情打开失败")
        }
    }

    /// 角标操作：设置指定数值（0 = 清除）。actionTitle 由调用方语义化传入，杜绝数字与标题的映射歧义
    private func applyBadge(_ count: Int, actionTitle: String) {
        guard !isSettingBadge else { return }
        isSettingBadge = true
        LogManager.shared.info("notificationTest", "角标测试", context: [
            "target": "\(count)", "action": actionTitle
        ])
        Task {
            let result = await notificationManager.setBadgeCount(count)
            isSettingBadge = false
            append(result: result, title: actionTitle)
        }
    }

    /// 插入一条测试记录（最新在前，最多保留 20 条）
    private func insert(_ record: TestRecord) {
        LogManager.shared.info("notificationTest", "测试记录", context: [
            "item": record.title, "phase": "\(record.phase)", "message": record.message
        ])
        withAnimation(.easeInOut(duration: 0.25)) {
            results.insert(record, at: 0)
            if results.count > 20 {
                results = Array(results.prefix(20))
            }
        }
    }

    /// 追加终态测试记录（成功 / 失败）
    private func append(result: NotificationTestResult, title: String) {
        let record = TestRecord(
            time: Date(), title: title,
            phase: result.isSuccess ? .success : .failure,
            message: result.message)
        insert(record)
    }
}