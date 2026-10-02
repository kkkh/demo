//
//  TabBar.swift
//  山西晋中理工学院 APP — 主标签页 + 全部视图
//

import SwiftUI
import WebKit
import AVKit
import Combine
import ImageIO
import os

// MARK: - 主标签页

struct MainTabView: View {
    @State private var selection = 0
    @State private var showDebug = false
    @ObservedObject private var data = DataService.shared
    @ObservedObject private var biometricSecurity = BiometricSecurityManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var messageCenterStore = MessageCenterStore.shared
    @AppStorage("colorSchemePreference") private var colorSchemePreference: String = "system"
    @Environment(\.scenePhase) private var scenePhase

    // 通知 DeepLink
    @State private var pendingNotificationArticle: NewsItem?
    @State private var showNotificationArticle = false
    @State private var notificationPresentationTask: Task<Void, Never>?
    /// 校长信箱通知点击 → 以 sheet 直达对应信件详情（安全调度，杜绝系统回调同步链弹窗）
    @State private var showMailboxFromNotification = false
    /// 待直达的信件 id（消费后传给 sheet 根视图）
    @State private var pendingMailboxMessageID: Int?
    /// 学校概况通知点击 → sheet 直达
    @State private var showSchoolProfileSheet = false
    /// 党建专题通知点击 → sheet 直达完整党建专题模块
    @State private var showPartySubjectSheet = false
    /// 机构动态通知点击 → sheet 直达机构子站文章详情（机构动态通道）
    /// 单状态（sheet(item:)）驱动：item 非 nil 即呈现，杜绝「isPresented=true 但 item=nil」
    /// 的竞态窗口——冷启动白屏根因（详情视图未创建 → .task 不执行 → 空容器）。
    @State private var pendingOrgArticle: PendingOrgArticleDeepLink?

    private var resolvedColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// 消费 NotificationManager.pendingDeepLink（@Published 状态驱动，替代 NotificationCenter 广播）
    /// 优化：在等待 Face ID / 场景激活的间隙并行启动文章详情预加载，实现秒开
    private func consumePendingDeepLink(_ link: PendingArticleDeepLink?) {
        guard let link else { return }
        let article = NewsItem(
            title: link.title, date: "", category: link.category,
            summary: "", articleId: link.articleId)

        let articleId = link.articleId
        DataService.shared.preloadArticleDetail(articleId: articleId)
        LogManager.shared.info("ui", "通知点击：已启动后台预加载文章详情", context: [
            "articleId": articleId, "title": link.title
        ])

        if showNotificationArticle {
            // 详情页已打开：直接替换内容，避免重复弹出
            pendingNotificationArticle = article
            notificationManager.deepLinkOutcome = .presented(articleId: link.articleId)
            LogManager.shared.info("ui", "详情页已打开，通知文章内容已更新", context: [
                "articleId": link.articleId, "source": link.source
            ])
            return
        }
        pendingNotificationArticle = article
        LogManager.shared.debugLog("ui", "收到通知打开指令，等待安全时机展示详情", context: [
            "articleId": link.articleId,
            "source": link.source,
            "scenePhase": scenePhaseText,
            "lockEngaged": "\(biometricSecurity.isLockEngaged)"
        ])
        scheduleNotificationArticlePresentation()
    }

    /// 消费 NotificationManager.pendingOrgArticleDeepLink（机构动态通道）：
    /// 等场景激活与 Face ID 解锁完成后再弹 sheet（避免详情页盖在安全遮罩之上），
    /// 与文章详情同源：绝不在系统通知回调的同步链中直接弹窗。
    /// 2026-10-02 冷启动白屏修复：消息中心点击链路（source=message_center）是先关闭
    /// 消息中心 sheet 再弹详情 sheet——若消息中心 dismiss 动画未收尾即 present 新 sheet，
    /// SwiftUI 会丢弃详情 sheet（日志特征：直达指令已打点但详情页 .task 不执行，空 container 白屏）。
    /// 修复：等 `showMessageCenter` 确认关闭（前置 sheet 判据）+ 放大错峰避开 dismiss 动画窗口。
    private func consumePendingOrgArticleDeepLink(_ request: PendingOrgArticleDeepLink?) {
        guard let request else { return }
        notificationManager.pendingOrgArticleDeepLink = nil
        let fromMessageCenter = (request.source == "message_center")
        LogManager.shared.info("ui", "收到机构动态通知打开指令", context: [
            "articleId": request.articleId,
            "org": request.orgName,
            "source": request.source,
            "scenePhase": scenePhaseText,
            "lockEngaged": "\(biometricSecurity.isLockEngaged)"
        ])
        Task { @MainActor in
            var waitCount = 0
            let consumeStart = Date()
            // 消息中心 sheet 是否已完全退场：ProfileView onDismiss 写共享时间戳（messageCenterStore）
            // 只认本次会话内的「新鲜」退场（距 consume 开始 3 秒内），防旧时间戳误判。
            let messageCenterGone: () -> Bool = {
                guard fromMessageCenter else { return true }
                guard let t = MessageCenterStore.shared.messageCenterDismissedAt else { return false }
                return t.timeIntervalSince(consumeStart) > -3
            }
            // 等待场景激活 + 解锁完成；消息中心点击场景额外等待消息中心 sheet 完全退场（onDismiss 收尾）
            while !Task.isCancelled && waitCount < 40 &&
                  (scenePhase != .active || biometricSecurity.isLockEngaged || !messageCenterGone()) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            // 错峰：覆盖前置 sheet 的 dismiss 动画收尾（系统 sheet 动画约 0.4–0.5s）+
            // 冷启动首帧 presenter 稳定余量；消息中心场景给更足窗口，其他场景维持既有节奏。
            try? await Task.sleep(nanoseconds: fromMessageCenter ? 550_000_000 : 300_000_000)
            guard !Task.isCancelled else { return }
            pendingOrgArticle = request
            LogManager.shared.info("ui", "机构动态通知 → 直达机构文章详情", context: [
                "articleId": request.articleId,
                "org": request.orgName,
                "waitedMs": "\(waitCount * 100)",
                "source": request.source,
                "fromMessageCenter": "\(fromMessageCenter)"
            ])
        }
    }

    /// 延迟调度通知文章详情弹窗 —— 修复「点击通知闪退」的核心：
    /// 等待场景激活、等 Face ID 解锁完成，并让出 runloop 周期，彻底切断系统回调同步链。
    /// 弹窗成败通过 NotificationManager.deepLinkOutcome 回显给通知测试页。
    private func scheduleNotificationArticlePresentation() {
        guard let article = pendingNotificationArticle,
              !showNotificationArticle,
              let articleId = article.articleId else { return }
        notificationPresentationTask?.cancel()
        notificationPresentationTask = Task { @MainActor in
            let scheduleStart = Date()
            LogManager.shared.info("ui", "通知详情调度启动：等待场景激活与 Face ID 解锁", context: [
                "articleId": articleId,
                "scenePhase": scenePhaseText,
                "lockEngaged": "\(biometricSecurity.isLockEngaged)"
            ])
            // 1. 冷启动点击通知时，didReceive 可能早于场景激活：先等到前台活跃
            //    同时等待 Face ID 解锁完成，避免详情页盖在安全遮罩之上
            var waitCount = 0
            while !Task.isCancelled && waitCount < 30 &&
                  (scenePhase != .active || biometricSecurity.isLockEngaged) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            let waitElapsed = Date().timeIntervalSince(scheduleStart)
            LogManager.shared.info("ui", "通知详情等待阶段完成", context: [
                "articleId": articleId,
                "waitMs": String(format: "%.0f", waitElapsed * 1000),
                "waitCount": "\(waitCount)",
                "scenePhase": scenePhaseText,
                "lockEngaged": "\(biometricSecurity.isLockEngaged)"
            ])
            // 超过 3 秒仍未满足条件 → 判定失败并回显原因（保持待展示状态，等待场景激活 / 解锁事件重新调度）
            guard !Task.isCancelled else { return }
            guard scenePhase == .active, !biometricSecurity.isLockEngaged else {
                let reason: String
                if scenePhase != .active {
                    reason = "等待应用进入前台超时"
                } else if biometricSecurity.isLockEngaged {
                    reason = "等待 Face ID 解锁超时"
                } else {
                    reason = "等待展示条件超时"
                }
                LogManager.shared.warning("ui", "通知详情等待展示超时，已暂缓", context: [
                    "articleId": articleId,
                    "scenePhase": scenePhaseText,
                    "lockEngaged": "\(biometricSecurity.isLockEngaged)",
                    "timeoutMs": String(format: "%.0f", waitElapsed * 1000)
                ])
                notificationManager.deepLinkOutcome = .failed(articleId: articleId, reason: reason)
                return
            }
            // 2. 再让出一个 runloop 周期，避免在生命周期/回调同步链中直接弹窗
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, pendingNotificationArticle != nil else { return }
            let totalScheduleElapsed = Date().timeIntervalSince(scheduleStart)
            showNotificationArticle = true
            notificationManager.deepLinkOutcome = .presented(articleId: articleId)
            LogManager.shared.info("ui", "通知文章详情页已打开", context: [
                "articleId": articleId,
                "scheduleMs": String(format: "%.0f", totalScheduleElapsed * 1000),
                "timeline": "通知点击→详情展示完成"
            ])
        }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                NavigationStack { HomeView(selection: $selection) }
                    .tabItem {
                        Label("首页", systemImage: "house.fill")
                    }
                    .tag(0)

                NavigationStack { DepartmentsView() }
                    .tabItem {
                        Label("院系", systemImage: "building.2.fill")
                    }
                    .tag(1)

                NavigationStack { NewsListView() }
                    .tabItem {
                        Label("资讯", systemImage: "newspaper.fill")
                    }
                    .tag(2)

                NavigationStack { CampusView() }
                    .tabItem {
                        Label("校园", systemImage: "map.fill")
                    }
                    .tag(3)

                NavigationStack { ProfileView() }
                    .tabItem {
                        Label("我的", systemImage: "person.fill")
                    }
                    .badge(messageCenterStore.unreadCount > 0 ? messageCenterStore.unreadCount : 0)
                    .tag(4)
            }
            .onChange(of: selection) { _, newValue in
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                let tabNames = ["首页", "院系", "资讯", "校园", "我的"]
                if newValue < tabNames.count {
                    LogManager.shared.debugLog("ui", "Tab 切换", context: ["tab": tabNames[newValue], "index": "\(newValue)"])
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                data.syncIfNeeded()
            }

            // 调试面板
            if showDebug {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("DEBUG").displayFont(12).bold()
                            Spacer()
                            Button("关闭") { showDebug = false }.displayFont(12)
                            Button("刷新") { data.syncIfNeeded(force: true) }.displayFont(12)
                            Button("模拟信箱新信") { PrincipalMailboxStore.shared.simulateNewMail() }.displayFont(12)
                        }
                        Text("mailbox=\(PrincipalMailboxStore.shared.total) new=\(PrincipalMailboxStore.shared.newCount)")
                            .displayFont(10)
                        Text("news=\(data.news.count) honors=\(data.honors.count) src=\(data.dataSource)")
                            .displayFont(10)
                        Text(verbatim: "loading=\(data.isLoading) banners=\(data.banners.count)")
                            .displayFont(10)
                        if let err = data.lastError {
                            Text("err: \(err)").displayFont(10).foregroundStyle(.orange)
                        }
                        if !data.syncErrors.isEmpty {
                            Text("syncErrors:").displayFont(9).bold()
                            ForEach(data.syncErrors, id: \.self) { e in
                                Text(e).displayFont(9).foregroundStyle(.red)
                            }
                        }
                        if !data.syncLog.isEmpty {
                            Text("--- syncLog ---").displayFont(9).bold()
                            ForEach(data.syncLog, id: \.self) { line in
                                Text(line).displayFont(9).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 350)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .transition(.move(edge: .bottom))
            }

            // 调试入口
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation { showDebug.toggle() }
                    } label: {
                        Image(systemName: "ant.fill")
                            .displaySymbolFont(11)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.top, 60).padding(.trailing, 8)
                }
                Spacer()
            }
        }
        .preferredColorScheme(resolvedColorScheme)
        .onAppear {
            // 冷启动点击通知时 didReceive 可能早于本视图出现：
            // 补消费一次挂起的 DeepLink，避免 onChange 漏接
            consumePendingDeepLink(notificationManager.pendingDeepLink)
            consumePendingOrgArticleDeepLink(notificationManager.pendingOrgArticleDeepLink)
        }
        .onChange(of: notificationManager.pendingDeepLink) { _, newLink in
            // @Published 状态驱动：登记待展示文章并排队弹窗，
            // 严禁在系统通知回调的同步链中直接弹 sheet —— 否则会触发
            // 「Call must be made on main thread」崩溃（点击通知闪退根因）。
            consumePendingDeepLink(newLink)
        }
        .onChange(of: notificationManager.pendingMailboxDeepLink) { _, messageID in
            guard let messageID else { return }
            notificationManager.pendingMailboxDeepLink = nil
            // 让出系统回调同步链后弹 sheet（沿袭通知详情防闪退处理原则）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                pendingMailboxMessageID = messageID
                showMailboxFromNotification = true
                LogManager.shared.info("ui", "通知点击 → 直达信件详情", context: ["mailboxId": "\(messageID)"])
            }
        }
        .onChange(of: notificationManager.pendingSchoolProfileDeepLink) { _, flag in
            guard flag else { return }
            notificationManager.pendingSchoolProfileDeepLink = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                showSchoolProfileSheet = true
                LogManager.shared.info("ui", "通知点击 → 打开学校概况页", context: [:])
            }
        }
        .onChange(of: notificationManager.pendingPartySubjectDeepLink) { _, flag in
            guard flag else { return }
            notificationManager.pendingPartySubjectDeepLink = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                showPartySubjectSheet = true
                LogManager.shared.info("ui", "通知点击 → 打开党建专题模块", context: [:])
            }
        }
        .onChange(of: notificationManager.pendingOrgArticleDeepLink) { _, request in
            consumePendingOrgArticleDeepLink(request)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 场景回到前台活跃后，补发一次弹窗调度（覆盖冷启动点击通知的场景）
            if newPhase == .active {
                scheduleNotificationArticlePresentation()
                // 消息中心前台自动站内检查（30 分钟节流，内部自守卫）
                messageCenterStore.handleSceneActive()
            }
        }
        .onChange(of: biometricSecurity.state) { _, newState in
            // Face ID 解锁完成后，补发一次弹窗调度（此前因安全遮罩暂缓的内容这时安全展示）
            if newState == .unlocked {
                scheduleNotificationArticlePresentation()
            }
        }
        .sheet(isPresented: $showNotificationArticle, onDismiss: {
            pendingNotificationArticle = nil
            LogManager.shared.debugLog("ui", "通知文章详情页已关闭", context: [:])
        }) {
            if let article = pendingNotificationArticle {
                NavigationStack {
                    EnhancedNewsDetailView(news: article)
                }
                .sjzPresentationChrome()
            }
        }
        .sheet(isPresented: $showMailboxFromNotification, onDismiss: {
            pendingMailboxMessageID = nil
        }) {
            MailboxSheetRoot(messageID: pendingMailboxMessageID) {
                showMailboxFromNotification = false
                LogManager.shared.debugLog("mailbox", "信箱通知页已关闭", context: [:])
            }
            .sjzPresentationChrome()
        }
        .sheet(isPresented: $showSchoolProfileSheet) {
            NavigationStack {
                SchoolProfileView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                showSchoolProfileSheet = false
                                LogManager.shared.debugLog("profile", "概况通知页已关闭", context: [:])
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .displaySymbolFont(16)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
            }
            .sjzPresentationChrome()
        }
        .sheet(isPresented: $showPartySubjectSheet) {
            NavigationStack {
                PartySubjectView()
                    .navigationTitle("党建专题")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") {
                                showPartySubjectSheet = false
                                LogManager.shared.debugLog("party", "党建专题通知页已关闭", context: [:])
                            }
                            .displayFont(17)
                        }
                    }
            }
            .sjzPresentationChrome()
        }
        .sheet(item: $pendingOrgArticle, onDismiss: {
            LogManager.shared.debugLog("ui", "机构动态文章详情页已关闭", context: [:])
        }) { request in
            // 2026-10-02 冷启动白屏修复：sheet(item:) 单状态驱动，
            // closure 的 request 为呈现快照（非可选），呈现瞬间必非 nil，
            // 详情视图必然创建 → .task 必然执行 → 不再出现空容器白屏/延迟。
            // onDismiss 触发 = pendingOrgArticle 已置 nil，视图卸载后无悬挂引用。
            NavigationStack {
                OrganizationArticleDetailView(
                    article: OrgArticle(
                        id: request.articleId,
                        title: request.title,
                        description: "",
                        imageUrl: nil,
                        updateTime: "",
                        tag: request.orgName,
                        articleId: request.articleId,
                        sectionSiteId: request.siteId),
                    siteId: request.siteId,
                    color: OrganizationCategory(rawValue: request.categoryRaw)?.color ?? .sjzAccent
                )
            }
            .sjzPresentationChrome()
        }
    }

    /// 场景阶段可读文案（日志上下文用）
    private var scenePhaseText: String {
        switch scenePhase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - 颜色扩展（自适应深色模式）

private extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0) // Fallback to black
        }
        
        self.init(red: CGFloat(r) / 255.0,
                  green: CGFloat(g) / 255.0,
                  blue: CGFloat(b) / 255.0,
                  alpha: CGFloat(a) / 255.0)
    }
}

extension Color {
    init(lightHex: String, darkHex: String) {
        self.init(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: darkHex) : UIColor(hex: lightHex)
        })
    }

    init(hex: String) {
        self.init(UIColor(hex: hex))
    }

    static var sjzPrimary:    Color { Color(lightHex: "0C1F4A", darkHex: "8AAEFF") }
    static var sjzAccent:     Color { Color(lightHex: "1A56B8", darkHex: "5B8DEF") }
    static var sjzLight:      Color { Color(lightHex: "EBF2FF", darkHex: "1A2333") }
    static var sjzGold:       Color { Color(lightHex: "C9A84C", darkHex: "E8CD6B") }
    static var sjzCard:       Color { Color(lightHex: "F8F9FC", darkHex: "1C1C1E") }
    static var sjzRed:        Color { Color(lightHex: "C62856", darkHex: "FF6B8A") }
    static var sjzTeal:       Color { Color(lightHex: "00838F", darkHex: "4DD0E1") }
    static var sjzGreen:      Color { Color(lightHex: "2E7D32", darkHex: "66BB6A") }
    static var sjzPurple:     Color { Color(lightHex: "6B3FA0", darkHex: "B388FF") }
    static var sjzOrange:     Color { Color(lightHex: "C9702E", darkHex: "FFB74D") }
    static var sjzPink:       Color { Color(lightHex: "C2185B", darkHex: "FF80AB") }
    static var sjzIndigo:     Color { Color(lightHex: "283593", darkHex: "7986CB") }
    static var sjzDeepBlue:   Color { Color(lightHex: "060D24", darkHex: "0A1628") }
    static var sjzLightBlue:  Color { Color(lightHex: "D6E4FF", darkHex: "1A2A4A") }
    static var sjzCyan:       Color { Color(lightHex: "0097A7", darkHex: "4DD0E1") }
    static var sjzSkyBlue:    Color { Color(lightHex: "42A5F5", darkHex: "42A5F5") }
    static var sjzMint:       Color { Color(lightHex: "00A896", darkHex: "4DB6AC") }
    static var sjzCoral:      Color { Color(lightHex: "E85D75", darkHex: "FF8A80") }
    static var sjzSurface:    Color { Color(lightHex: "FFFFFF", darkHex: "1C1C1E") }
    static var sjzWarmGray:   Color { Color(lightHex: "F0EDE8", darkHex: "2C2C2E") }

    // MARK: Hero Banner 专用渐变（暗色模式下保持深邃海军蓝，不随 UI 彩色变浅）
    static var sjzHeroStart: Color { Color(lightHex: "060D24", darkHex: "0A1628") }
    static var sjzHeroMid:   Color { Color(lightHex: "0C1F4A", darkHex: "152040") }
    static var sjzHeroEnd:   Color { Color(lightHex: "1A56B8", darkHex: "1E3A6E") }
}

// MARK: - 视觉辅助

struct GradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(.systemGroupedBackground), Color.sjzLight.opacity(0.3)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct ShimmerView: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.gray.opacity(0.05),
                        Color.gray.opacity(0.15),
                        Color.gray.opacity(0.05)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .mask(
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .black, .clear]),
                            startPoint: .init(x: phase, y: 0),
                            endPoint: .init(x: phase + 0.6, y: 0)
                        )
                    )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - 首页

struct HomeView: View {
    @ObservedObject private var data = DataService.shared
    @ObservedObject private var readManager = ReadStatusManager.shared
    @ObservedObject private var homeModules = HomeModuleManager.shared
    @ObservedObject private var helpGuideStore = HelpGuideStore.shared
    @Binding var selection: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var heroAppear = false
    @State private var sectionsAppear = false
    /// E10 滚动让路状态
    @State private var isScrolling = false
    /// 使用帮助锚点卡：进入帮助中心（navigationDestination 触发）
    @State private var showHelpCenter = false
    /// 使用帮助锚点卡：继续阅读直达的文章（sheet 触发）
    @State private var selectedHelpArticle: HelpArticle?
    /// 锚点卡进度环动画源（开场 0→真实进度 + 读库变化联动）
    @State private var anchorRingProgress: Double = 0
    /// 未读光点呼吸动画相位
    @State private var unreadPulse = false
    /// 锚点卡展示日志会话守卫：仅首次展示记 info，避免滚动/切 tab 反复刷屏
    @State private var anchorCardAnnounceLogged = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                heroBannerSection
                statsRowSection
                quickActionsSection
                helpGuideAnchorSection

                // 模块区：加载中且无任何内容时展示骨架屏（直观状态提示），
                // 内容就绪后按序错峰揭示（Apple News 式渐进入场，单次会话仅触发一次）
                if showHomeSkeleton {
                    homeModuleSkeleton
                        .transition(.opacity)
                } else {
                    ForEach(Array(homeModules.visibleOrderedModules.filter { hasContent($0) && $0 != .helpGuide }.enumerated()), id: \.element.id) { index, module in
                        moduleSection(module)
                            .modifier(SJZRevealOnce(key: "home.\(module.id)", delay: Double(index) * 0.07))
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: homeModules.hiddenModules)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: homeModules.moduleOrder)
                }

                Spacer().frame(height: 40)
            }
        }
        .modifier(SJZIdleTimerRepairOnScrollStop())
        .background(GradientBackground())
        .refreshable {
            await withCheckedContinuation { c in
                data.syncIfNeeded(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { c.resume() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if data.isLoading {
                // 同步状态胶囊（优雅玻璃态 + 渐变进度环）
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.sjzAccent)
                    Text("同步中…")
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
                .glassEffect()
                .padding(.trailing, 16).padding(.bottom, 16)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: data.isLoading)
        .sjzScrollSuspendTrack($isScrolling)
        .environment(\.sjzImageLoadingSuspended, isScrolling)
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { homeToolbar }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                sectionsAppear = true
            }
        }
        .onChange(of: homeModules.hiddenModules) { oldValue, newValue in
            // 使用帮助锚点卡可见性变化（挂在 body 顶层：卡片隐藏时监听仍有效，隐藏/显示双向对称记录）
            let wasHidden = oldValue.contains(.helpGuide)
            let isHidden = newValue.contains(.helpGuide)
            if wasHidden != isHidden {
                LogManager.shared.info("helpGuide", "使用帮助锚点卡显示状态变化", context: [
                    "visible": "\(!isHidden)",
                    "trigger": "home_modules_toggle"
                ])
            }
        }
        // 使用帮助锚点卡目的地：挂在 body 顶层锚点（条件分支内注册会在卡隐藏时失效）
        .navigationDestination(isPresented: $showHelpCenter) {
            HelpGuideView()
        }
        // 继续阅读直达详情：与帮助页详情同构（NavigationStack 包裹，支持复制工具栏与原地跳转）
        .sheet(item: $selectedHelpArticle) { article in
            NavigationStack {
                HelpArticleDetailView(article: article)
            }
            .sjzPresentationChrome()
        }
    }

    private var homeToolbar: some ToolbarContent {
        Group {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "graduationcap.fill")
                        .displaySymbolFont(15)
                        .foregroundStyle(Color.sjzGold)
                    Text(SchoolInfo.name)
                        .displayFont(17, weight: .semibold)
                        .foregroundStyle(Color.sjzPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    data.syncIfNeeded()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .displaySymbolFont(13, weight: .medium)
                        .foregroundStyle(Color.sjzAccent)
                        .rotationEffect(.degrees(data.isLoading ? 360 : 0))
                        .animation(data.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: data.isLoading)
                }
                .disabled(data.isLoading)
            }
        }
    }

    // MARK: - Hero Banner（静态单页，避免 ScrollView 内嵌 TabView 性能问题）

    private var heroBannerSection: some View {
        ZStack(alignment: .bottom) {
            heroSlide

            LinearGradient(
                colors: [.clear, .black.opacity(heroBottomOverlayOpacity)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: 220).allowsHitTesting(false)
        }
        .opacity(heroAppear ? 1 : 0)
        .offset(y: heroAppear ? 0 : 30)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                heroAppear = true
            }
        }
    }

    /// Hero Banner 渐变颜色 —— 浅色模式品牌海军蓝，深色模式近黑色无缝融入暗色 UI
    private var heroGradientColors: [Color] {
        colorScheme == .dark
            ? [Color(hex: "05050A"), Color(hex: "0D0F17"), Color(hex: "151A26")]
            : [Color(hex: "060D24"), Color(hex: "0C1F4A"), Color(hex: "1A56B8")]
    }

    /// 底部遮罩透明度 —— 深色模式下背景已暗，降低遮罩强度
    private var heroBottomOverlayOpacity: Double {
        colorScheme == .dark ? 0.3 : 0.7
    }

    private var heroSlide: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(LinearGradient(
                    colors: heroGradientColors,
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    HeroSlideDecoration()
                }

            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Text(SchoolInfo.name)
                        .displayFont(38, weight: .bold, design: .rounded)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    Text(SchoolInfo.englishName)
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(4)
                }

                HStack(spacing: 8) {
                    Image(systemName: "book.fill").displaySymbolFont(11)
                    Text(SchoolInfo.motto)
                        .displayFont(14, weight: .semibold)
                }
                .foregroundStyle(Color.sjzGold)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(.ultraThinMaterial.opacity(0.15), in: Capsule())
                .overlay(Capsule().stroke(Color.sjzGold.opacity(0.2), lineWidth: 1))
            }
            .padding(.bottom, 70)
        }
        .frame(height: 420).clipped()
    }

// MARK: - Hero Slide Decoration（轻量版，避免 GeometryReader 性能开销）

private struct HeroSlideDecoration: View {
    @Environment(\.colorScheme) private var colorScheme

    /// 装饰元素透明度 —— 深色模式下背景近黑，需提高装饰可见度
    private var decorationOpacity: (large: Double, small: Double, icon: Double, sparkle: Double) {
        colorScheme == .dark
            ? (0.06, 0.04, 0.06, 0.18)
            : (0.03, 0.02, 0.03, 0.12)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(decorationOpacity.large), lineWidth: 1)
                .frame(width: 300, height: 300)
            Circle()
                .stroke(.white.opacity(decorationOpacity.small), lineWidth: 1)
                .frame(width: 500, height: 500)
            Image(systemName: "graduationcap.fill")
                .displaySymbolFont(120)
                .foregroundStyle(.white.opacity(decorationOpacity.icon))
                .offset(x: 120, y: -80)
            Image(systemName: "sparkle")
                .displaySymbolFont(20)
                .foregroundStyle(Color.sjzGold.opacity(decorationOpacity.sparkle))
                .offset(x: -100, y: -50)
        }
    }
}


    // MARK: - Stats Row

    private var statsRowSection: some View {
        HStack(spacing: 10) {
            ForEach(Array(data.stats.enumerated()), id: \.element.id) { idx, stat in
                let color = statColor(stat.icon)
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.08))
                            .frame(width: 54, height: 54)
                            .overlay(
                                Circle()
                                    .stroke(
                                        LinearGradient(colors: [color.opacity(0.3), color.opacity(0.05)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        lineWidth: 1.5
                                    )
                            )
                        Image(systemName: stat.icon)
                            .displaySymbolFont(20, weight: .semibold)
                            .foregroundStyle(color)
                    }
                    Text(stat.value)
                        .displayFont(24, weight: .bold, design: .rounded)
                        .foregroundStyle(Color.sjzPrimary)
                    Text(stat.label)
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
                .scaleEffect(sectionsAppear ? 1 : 0.8)
                .opacity(sectionsAppear ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(idx) * 0.08), value: sectionsAppear)
            }
        }
        .padding(.horizontal, 16).padding(.top, 24)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
            spacing: 16
        ) {
            ForEach(Array(quickLinks.enumerated()), id: \.element.id) { idx, link in
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        switch link.title {
                        case "院系查询": selection = 1
                        case "新闻资讯": selection = 2
                        case "校园服务", "校园荣誉": selection = 3
                        case "招生就业", "学校概况": selection = 4
                        default: break
                        }
                    }
                } label: {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22)
                                .fill(LinearGradient(
                                    colors: [quickLinkColor(link.title), quickLinkColor(link.title).opacity(0.7)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 60, height: 60)
                                .shadow(color: quickLinkColor(link.title).opacity(0.35), radius: 12, y: 6)
                            Image(systemName: link.icon)
                                .displaySymbolFont(22)
                                .foregroundStyle(.white)
                        }
                        Text(link.title)
                            .displayFont(12, weight: .medium)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                .scaleEffect(sectionsAppear ? 1 : 0.6)
                .opacity(sectionsAppear ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double(idx) * 0.06), value: sectionsAppear)
            }
        }
        .padding(.horizontal, 16).padding(.top, 28)
    }

    // MARK: - 使用帮助锚点卡（原「校园亮点」固定区块位置，2026-09-24 升级改造）

    /// 使用帮助锚点卡：固定区升级横卡（渐变图标块 + 标题/未读徽章 + 已读百分比 + 进度环 + 继续阅读直达）。
    /// 渲染条件与「首页管理」开关联动（homeModules.isVisible(.helpGuide)）；模块循环已排除帮助模块避免双份渲染。
    @ViewBuilder
    private var helpGuideAnchorSection: some View {
        if homeModules.isVisible(.helpGuide) {
            VStack(spacing: 10) {
                Button {
                    openHelpCenter()
                } label: {
                    cardMain
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openHelpCenter() }

                if let recent = helpGuideStore.recentArticles.first {
                    Button {
                        openContinueReading(recent)
                    } label: {
                        continueRow(recent.title)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: helpGuideStore.recentArticleIDs)
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: homeModules.hiddenModules)
            .scaleEffect(sectionsAppear ? 1 : 0.92)
            .opacity(sectionsAppear ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.12), value: sectionsAppear)
            .onAppear {
                // 进度环开场（首次进入：0 → 真实进度一次性弹簧动画；后续值相同不再重播）
                withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) {
                    anchorRingProgress = helpGuideStore.readProgress
                }
                if !anchorCardAnnounceLogged {
                    LogManager.shared.info("helpGuide", "首页使用帮助锚点卡展示", context: [
                        "total": "\(helpGuideStore.totalArticles)",
                        "unread": "\(helpGuideStore.unreadCount)",
                        "progress": "\(Int(helpGuideStore.readProgress * 100))",
                        "visible": "\(homeModules.isVisible(.helpGuide))"
                    ])
                    anchorCardAnnounceLogged = true
                }
            }
            .onChange(of: helpGuideStore.readProgress) { _, newValue in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    anchorRingProgress = newValue
                }
            }
        }
    }

    /// 卡片主体：渐变问号图标块 + 标题行（未读徽章）+ 副标题行（已读百分比）+ 进度环 + chevron
    private var cardMain: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.sjzAccent, Color(hex: "4F8EF7")],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "questionmark.circle.fill")
                        .displaySymbolFont(20, weight: .semibold)
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.sjzAccent.opacity(0.35), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("使用帮助")
                        .displayFont(17, weight: .bold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if helpGuideStore.unreadCount > 0 {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: "FFD9C2"))
                                .frame(width: 5, height: 5)
                                .opacity(unreadPulse ? 0.35 : 1)
                                // 隐式动画驱动呼吸循环：视图移除即复位，重入重新启动（LazyVStack 复用安全）
                                .animation(
                                    unreadPulse
                                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                                        : .default,
                                    value: unreadPulse)
                                .onAppear { unreadPulse = true }
                                .onDisappear { unreadPulse = false }
                            Text("未读 \(helpGuideStore.unreadCount)")
                                .displayFont(10, weight: .bold)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            LinearGradient(colors: [Color.sjzOrange, Color.sjzRed],
                                           startPoint: .leading, endPoint: .trailing),
                            in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                Text("\(helpGuideStore.totalArticles) 篇指南 · 已读 \(Int(helpGuideStore.readProgress * 100))%")
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: helpGuideStore.unreadCount)

            Spacer(minLength: 8)

            ZStack {
                Circle()
                    .stroke(Color.sjzAccent.opacity(0.15), lineWidth: 3)
                    .frame(width: 34, height: 34)
                Circle()
                    .trim(from: 0, to: anchorRingProgress <= 0 ? 0 : max(0.02, anchorRingProgress))
                    .stroke(Color.sjzAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 34, height: 34)
            }

            Image(systemName: "chevron.right")
                .displaySymbolFont(11, weight: .medium)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// 继续阅读条：最近一篇直达（与帮助页最近阅读同一数据源）
    private func continueRow(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .displaySymbolFont(12, weight: .semibold)
                .foregroundStyle(Color.sjzAccent)
            Text("继续阅读：《\(title)》")
                .displayFont(12, weight: .medium)
                .foregroundStyle(colorScheme == .dark ? Color.primary.opacity(0.85) : Color.sjzAccent.opacity(0.9))
                .lineLimit(1)
            Spacer()
            Image(systemName: "arrow.up.left")
                .displaySymbolFont(9, weight: .medium)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.sjzAccent.opacity(0.07))
        )
        .contentShape(Rectangle())
        .accessibilityLabel("继续阅读：\(title)")
    }

    /// 打开帮助中心（触觉 + 日志闭环）
    private func openHelpCenter() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        LogManager.shared.info("helpGuide", "首页使用帮助锚点卡点击", context: [
            "source": "home_anchor",
            "total": "\(helpGuideStore.totalArticles)",
            "unread": "\(helpGuideStore.unreadCount)"
        ])
        showHelpCenter = true
    }

    /// 继续阅读直达（recordOpen 幂等：重复打开同一篇时已读标记无副作用、最近阅读重排置顶）
    private func openContinueReading(_ article: HelpArticle) {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        // 动画事务包住状态写入：驱动锚点卡续读行过渡与进度环联动
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            helpGuideStore.recordOpen(article)
        }
        LogManager.shared.info("helpGuide", "首页使用帮助最近阅读直达", context: [
            "articleId": article.id,
            "source": "home_anchor_continue"
        ])
        selectedHelpArticle = article
    }

    // MARK: - Section Header

    /// 模块标题栏：渐变色块图标 + 标题 + 内容计数胶囊 + 缓存来源徽标 + 更多入口
    private func sectionHeader(_ title: String, _ icon: String, _ color: Color,
                               count: Int = 0, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            // 渐变色块图标（App Store 现代风格）
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(
                    colors: [color.opacity(0.9), color.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: icon)
                        .displaySymbolFont(13, weight: .bold)
                        .foregroundStyle(.white)
                }
                .shadow(color: color.opacity(0.3), radius: 5, y: 2)

            Text(title)
                .displayFont(17, weight: .bold)
                .foregroundStyle(.primary)

            if count > 0 {
                Text("\(count)")
                    .displayFont(10, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(color.opacity(0.1), in: Capsule())
            }

            Spacer()

            // 数据来源徽标：本地缓存生效时可见（直观状态提示）
            if data.dataSource == "缓存" {
                HStack(spacing: 3) {
                    Image(systemName: "archivebox.fill").displaySymbolFont(8, weight: .semibold)
                    Text("离线缓存").displayFont(9, weight: .semibold)
                }
                .foregroundStyle(Color.sjzGreen)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Color.sjzGreen.opacity(0.1), in: Capsule())
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text("更多")
                            .displayFont(13, weight: .semibold)
                        Image(systemName: "chevron.right")
                            .displaySymbolFont(10, weight: .bold)
                    }
                    .foregroundStyle(color)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 32).padding(.bottom, 16)
    }

    // MARK: - 首页模块动态渲染

    /// 模块当前是否有可展示的内容
    private func hasContent(_ module: HomeModule) -> Bool {
        switch module {
        case .importantNews:    return !data.importantNews.isEmpty
        case .honors:           return !data.honors.isEmpty
        case .notices:          return !data.notices.isEmpty
        case .helpGuide:       return true // 使用帮助为本地内容入口卡常显
        case .teacherProfiles:  return !data.teacherProfiles.isEmpty
        case .videos:           return !data.videos.isEmpty
        case .studentStories:   return !data.studentStories.isEmpty
        case .campusActivities: return !data.campusActivities.isEmpty
        case .timeline:         return !data.timeline.isEmpty
        // 校长信箱为入口卡常显：内容懒加载（不参与全局同步），进入详情页/首页预加载后填充
        case .principalMailbox: return true
        // 党建专题同为懒加载入口卡常显
        case .partySubject: return true
        // 学校概况同为懒加载入口卡常显
        case .schoolProfile: return true
        }
    }

    /// 首页骨架屏条件：同步进行中且没有任何模块内容（冷启动/无缓存场景）。
    /// 校长信箱/党建专题/学校概况为常显入口卡（内容懒加载），不参与骨架屏条件判定。
    private var showHomeSkeleton: Bool {
        data.isLoading && homeModules.visibleOrderedModules
            .filter { hasContent($0) && $0 != .principalMailbox && $0 != .partySubject && $0 != .schoolProfile && $0 != .helpGuide }
            .isEmpty
    }

    /// 首页模块骨架屏（等待期间的直观状态提示，类 Apple News 骨架布局）
    private var homeModuleSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 120, height: 18)
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 120, height: 90)
                                .overlay {
                                    ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 20)
        .onAppear {
            LogManager.shared.info("ui", "首页模块骨架屏展示（等待数据）", context: [
                "dataSource": data.dataSource,
                "visibleModules": "\(homeModules.visibleOrderedModules.count)"
            ])
        }
        .onDisappear {
            if !showHomeSkeleton {
                LogManager.shared.info("ui", "首页内容渲染完成", context: [
                    "modules": "\(homeModules.visibleOrderedModules.filter { hasContent($0) && $0 != .principalMailbox && $0 != .partySubject && $0 != .schoolProfile && $0 != .helpGuide }.count)",
                    "dataSource": data.dataSource
                ])
            }
        }
    }

    /// 按模块输出「标题栏 + 内容区」（顺序由用户设置决定）
    @ViewBuilder
    private func moduleSection(_ module: HomeModule) -> some View {
        switch module {
        case .importantNews:
            sectionHeader("学校要闻", "megaphone.fill", Color.sjzRed, count: data.importantNews.count) { selection = 2 }
            importantNewsSection
        case .honors:
            sectionHeader("校园荣誉", "trophy.fill", Color.sjzGold, count: data.honors.count)
            honorsSection
        case .notices:
            sectionHeader("通知公告", "bell.badge.fill", Color.sjzOrange, count: data.notices.count)
            noticesSection
        case .helpGuide:
            // 使用帮助已升级为固定区锚点横卡（helpGuideAnchorSection，原「校园亮点」位置）；
            // ForEach 已排除该模块，此分支为防御死码（保留以维持 CaseIterable 穷举）
            EmptyView()
        case .teacherProfiles:
            sectionHeader("教师风采", "person.text.rectangle.fill", Color.sjzIndigo, count: data.teacherProfiles.count)
            teachersSection
        case .videos:
            sectionHeader("映像校园", "play.rectangle.fill", Color.sjzAccent, count: data.videos.count)
            videosSection
        case .studentStories:
            sectionHeader("学生故事", "person.2.fill", Color.sjzPurple, count: data.studentStories.count)
            storiesSection
        case .campusActivities:
            sectionHeader("校园活动", "party.popper.fill", Color.sjzPink, count: data.campusActivities.count)
            activitiesSection
        case .timeline:
            sectionHeader("发展历程", "clock.arrow.2.circlepath", Color.sjzPrimary, count: data.timeline.count)
            timelineSection
        case .principalMailbox:
            sectionHeader("校长信箱", "envelope.open.fill", Color.sjzTeal, count: PrincipalMailboxStore.shared.total)
            principalMailboxSection
        case .partySubject:
            sectionHeader("党建专题", "flag.fill", Color(hex: "C8102E"), count: PartySubjectStore.shared.totalArticles)
            partySubjectSection
        case .schoolProfile:
            sectionHeader("学校概况", "building.columns.fill", Color.sjzPrimary, count: SchoolProfileStore.shared.allEntries.count)
            schoolProfileSection
        }
    }

    // MARK: - Principal Mailbox（校长信箱入口卡）

    /// 校长信箱首页入口卡：懒加载数据（不阻塞全局同步），加载后展示最近一封与回复计数徽章
    private var principalMailboxSection: some View {
        NavigationLink {
            PrincipalMailboxView()
        } label: {
            HStack(spacing: 14) {
                // 渐变信封图标块（柔光点缀）
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.sjzTeal, Color.sjzAccent.opacity(0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "envelope.open.fill")
                            .displaySymbolFont(20, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.sjzTeal.opacity(0.35), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("倾听师生心声")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text("校长信箱")
                        .displayFont(17, weight: .bold)
                        .foregroundStyle(.primary)
                    if let latest = PrincipalMailboxStore.shared.allMessages.first {
                        Text("最近：\(latest.showTitle)")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if PrincipalMailboxStore.shared.isLoading {
                        Text("正在加载来信…")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text("师生建议与公开回复通道")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 7) {
                    if PrincipalMailboxStore.shared.total > 0 {
                        Text("\(PrincipalMailboxStore.shared.total) 封回复")
                            .displayFont(9, weight: .bold)
                            .monospacedDigit()
                            .foregroundStyle(Color.sjzTeal)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.sjzTeal.opacity(0.1)))
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.45, dampingFraction: 0.8),
                       value: PrincipalMailboxStore.shared.total)
        }
        .buttonStyle(.plain)
        .onAppear {
            // 首页曝光即懒加载（失败静默，详情页内重试）
            PrincipalMailboxStore.shared.loadIfNeeded()
            LogManager.shared.debugLog("mailbox", "首页信箱入口卡展示", context: [
                "total": "\(PrincipalMailboxStore.shared.total)"
            ])
        }
    }

    // MARK: - Party Subject（党建专题入口卡）

    /// 党建专题首页入口卡：懒加载两站全量文章（不阻塞全局同步），加载后展示文章总数与最近一篇
    private var partySubjectSection: some View {
        NavigationLink {
            PartySubjectView()
        } label: {
            HStack(spacing: 14) {
                // 红色渐变旗帜图标块（党建主题）
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(hex: "C8102E"), Color.sjzOrange.opacity(0.85)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "flag.fill")
                            .displaySymbolFont(20, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.sjzRed.opacity(0.35), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("凝聚红色力量")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text("党建专题")
                        .displayFont(17, weight: .bold)
                        .foregroundStyle(.primary)
                    if let latest = PartySubjectStore.shared.aggregatedArticles(siteKey: "djgz").first {
                        Text("最近：\(latest.article.title)")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if PartySubjectStore.shared.isLoading {
                        Text("正在同步专题文章…")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text("党建工作 · 思政专题 · 300+ 篇文章")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 7) {
                    if PartySubjectStore.shared.totalArticles > 0 {
                        Text("\(PartySubjectStore.shared.totalArticles) 篇文章")
                            .displayFont(9, weight: .bold)
                            .monospacedDigit()
                            .foregroundStyle(Color(hex: "C8102E"))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color(hex: "C8102E").opacity(0.1)))
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.45, dampingFraction: 0.8),
                       value: PartySubjectStore.shared.totalArticles)
        }
        .buttonStyle(.plain)
        .onAppear {
            // 首页曝光即懒加载（失败静默，详情页内重试）
            PartySubjectStore.shared.loadIfNeeded()
            LogManager.shared.debugLog("party", "首页党建专题入口卡展示", context: [
                "totalArticles": "\(PartySubjectStore.shared.totalArticles)"
            ])
        }
    }

    // MARK: - School Profile（学校概况入口卡）

    /// 学校概况首页入口卡：懒加载六板块数据（不阻塞全局同步），蓝金学术主题
    private var schoolProfileSection: some View {
        NavigationLink {
            SchoolProfileView()
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(hex: "0B1F4B"), Color.sjzAccent.opacity(0.85)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "building.columns.fill")
                            .displaySymbolFont(20, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.sjzPrimary.opacity(0.35), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("SCHOOL PROFILE")
                        .displayFont(10, weight: .bold)
                        .tracking(1.5)
                        .foregroundStyle(Color.sjzGold)
                    Text("学校概况")
                        .displayFont(17, weight: .bold)
                        .foregroundStyle(.primary)
                    if let leader = SchoolProfileStore.shared.leaders.first {
                        Text("领衔：\(leader.title)")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if SchoolProfileStore.shared.isLoading {
                        Text("正在同步学校概况…")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text("学校简介 · 现任领导 · 宣传片 · 校园风光")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 7) {
                    if SchoolProfileStore.shared.hasLoaded {
                        Text("\(SchoolProfileStore.shared.leaders.count) 位领导")
                            .displayFont(9, weight: .bold)
                            .monospacedDigit()
                            .foregroundStyle(Color.sjzPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.sjzPrimary.opacity(0.1)))
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(11, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.45, dampingFraction: 0.8),
                       value: SchoolProfileStore.shared.hasLoaded)
        }
        .buttonStyle(.plain)
        .onAppear {
            SchoolProfileStore.shared.loadIfNeeded()
            LogManager.shared.debugLog("profile", "首页学校概况入口卡展示", context: [
                "entries": "\(SchoolProfileStore.shared.allEntries.count)"
            ])
        }
    }

    // MARK: - Important News

    private var importantNewsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.importantNews.prefix(4).enumerated()), id: \.element.id) { idx, item in
                NavigationLink {
                    EnhancedNewsDetailView(news: item)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        newsThumbnail(item: item)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title)
                                .displayFont(15, weight: .semibold)
                                .lineLimit(2).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 8) {
                                CategoryBadge(category: item.category)
                                Text(item.date)
                                    .displayFont(11).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .displaySymbolFont(11, weight: .medium)
                            .foregroundStyle(.tertiary).padding(.top, 4)
                    }
                    .padding(16)
                    .overlay(alignment: .topLeading) {
                        if !readManager.isRead(item.readKey) {
                            Circle()
                                .fill(Color.sjzAccent)
                                .frame(width: 8, height: 8)
                                .padding(.leading, 6).padding(.top, 10)
                        }
                    }
                }
                .buttonStyle(.plain)
                if idx < min(data.importantNews.prefix(4).count - 1, 3) {
                    Divider().padding(.leading, 104)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
        .padding(.horizontal, 16)
    }

    // MARK: - Honors

    private var honorsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Array(data.honors.prefix(12))) { honor in
                    NavigationLink {
                        HonorDetailView(honor: honor)
                    } label: {
                        honorCard(honor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func honorCard(_ honor: Honor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let imgUrl = honor.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            honorPlaceholderView(honor: honor)
                        default:
                            ShimmerView().frame(width: 200, height: 140)
                        }
                    }
                    .frame(width: 200, height: 140).clipped()
                } else {
                    honorPlaceholderView(honor: honor)
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.5)],
                    startPoint: .top, endPoint: .bottom
                ).frame(height: 50)
                if let tag = honor.tag {
                    Text(tag)
                        .displayFont(9, weight: .bold)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.leading, 14).padding(.bottom, 10)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(honor.title)
                    .displayFont(13, weight: .semibold)
                    .lineLimit(2).foregroundStyle(.primary)
                if let date = honor.date {
                    Text(date).displayFont(10).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .frame(width: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
    }

    private func honorPlaceholderView(honor: Honor) -> some View {
        LinearGradient(
            colors: [honorColor(honor.icon), honorColor(honor.icon).opacity(0.15)],
            startPoint: .top, endPoint: .bottom)
        .overlay {
            Image(systemName: honor.icon)
                .displaySymbolFont(48).foregroundStyle(.white.opacity(0.15))
        }
        .frame(width: 200, height: 140)
    }

    // MARK: - Notices

    private var noticesSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.notices.prefix(3).enumerated()), id: \.element.id) { idx, item in
                NavigationLink {
                    EnhancedNewsDetailView(news: item)
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color.sjzOrange.opacity(0.08)).frame(width: 40, height: 40)
                            Image(systemName: "bell.fill")
                                .displaySymbolFont(14).foregroundStyle(Color.sjzOrange)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .displayFont(14, weight: .medium)
                                .lineLimit(1).foregroundStyle(.primary)
                            Text(item.date)
                                .displayFont(11).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .displaySymbolFont(10, weight: .medium).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .overlay(alignment: .topLeading) {
                        if !readManager.isRead(item.readKey) {
                            Circle()
                                .fill(Color.sjzAccent)
                                .frame(width: 8, height: 8)
                                .padding(.leading, 5).padding(.top, 10)
                        }
                    }
                }
                .buttonStyle(.plain)
                if idx < min(data.notices.prefix(3).count - 1, 2) {
                    Divider().padding(.leading, 66)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
        .padding(.horizontal, 16)
    }

    // MARK: - Teachers

    private var teachersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(data.teacherProfiles) { teacher in
                    teacherCard(teacher)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func teacherCard(_ teacher: TeacherProfile) -> some View {
        NavigationLink {
            TeacherDetailView(teacher: teacher)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottom) {
                    if let imgUrl = teacher.imageUrl, let url = URL(string: imgUrl) {
                        SJZCachedImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                teacherPlaceholder
                            }
                        }
                        .frame(width: 180, height: 140).clipped()
                    } else {
                        teacherPlaceholder.frame(width: 180, height: 140)
                    }
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.4)],
                        startPoint: .top, endPoint: .bottom
                    ).frame(height: 45)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(teacher.title)
                        .displayFont(13, weight: .medium).lineLimit(2)
                    Text(teacher.summary)
                        .displayFont(10).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(14)
            }
            .frame(width: 180)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var teacherPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzIndigo.opacity(0.06), Color.sjzLightBlue],
            startPoint: .top, endPoint: .bottom)
        .overlay {
            Image(systemName: "person.text.rectangle.fill")
                .displaySymbolFont(28).foregroundStyle(Color.sjzIndigo.opacity(0.1))
        }
    }

    // MARK: - Videos

    private var videosSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(data.videos) { video in
                    videoCard(video)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func videoCard(_ video: CampusVideo) -> some View {
        NavigationLink {
            VideoPlayerView(video: video)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let thumb = video.thumbnailUrl, let url = URL(string: thumb) {
                        SJZCachedImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                videoPlaceholderView
                            }
                        }
                    } else {
                        videoPlaceholderView
                    }
                    Color.black.opacity(0.1)
                    Image(systemName: "play.circle.fill")
                        .displaySymbolFont(52)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 6)
                }
                .frame(width: 270, height: 160).clipped()
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .displayFont(13, weight: .medium).lineLimit(2)
                    if let desc = video.description, !desc.isEmpty {
                        Text(desc)
                            .displayFont(10).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(14)
            }
            .frame(width: 270)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var videoPlaceholderView: some View {
        LinearGradient(
            colors: [Color.sjzAccent.opacity(0.05), Color.sjzLightBlue],
            startPoint: .top, endPoint: .bottom)
        .overlay {
            Image(systemName: "play.rectangle.fill")
                .displaySymbolFont(34).foregroundStyle(Color.sjzAccent.opacity(0.1))
        }
    }

    // MARK: - Stories

    private var storiesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(data.studentStories) { story in
                    storyCard(story)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func storyCard(_ story: StudentStory) -> some View {
        NavigationLink {
            StoryDetailView(story: story)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imgUrl = story.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            storyPlaceholderView
                        }
                    }
                    .frame(width: 230, height: 150).clipped()
                } else {
                    storyPlaceholderView.frame(width: 230, height: 150)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(story.title)
                        .displayFont(13, weight: .medium).lineLimit(2)
                    Text(story.summary)
                        .displayFont(10).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(14)
            }
            .frame(width: 230)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var storyPlaceholderView: some View {
        LinearGradient(
            colors: [Color.sjzPurple.opacity(0.05), Color.sjzLight],
            startPoint: .top, endPoint: .bottom)
        .overlay {
            Image(systemName: "person.2.fill")
                .displaySymbolFont(28).foregroundStyle(Color.sjzPurple.opacity(0.1))
        }
    }

    // MARK: - Activities

    private var activitiesSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(data.campusActivities) { activity in
                    activityCard(activity)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func activityCard(_ activity: CampusActivity) -> some View {
        NavigationLink {
            ActivityDetailView(activity: activity)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imgUrl = activity.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            activityPlaceholder
                        }
                    }
                    .frame(width: 240, height: 150).clipped()
                } else {
                    activityPlaceholder.frame(width: 240, height: 150)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(activity.title)
                        .displayFont(13, weight: .medium).lineLimit(2)
                    if let en = activity.englishTitle {
                        Text(en).displayFont(10).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let date = activity.date {
                        Text(date).displayFont(10).foregroundStyle(Color.sjzPink)
                    }
                }
                .padding(14)
            }
            .frame(width: 240)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var activityPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzPink.opacity(0.04), Color.sjzLight],
            startPoint: .top, endPoint: .bottom)
        .overlay {
            Image(systemName: "party.popper.fill")
                .displaySymbolFont(28).foregroundStyle(Color.sjzPink.opacity(0.08))
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.timeline.enumerated()), id: \.element.id) { idx, event in
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 0) {
                        Text(event.year)
                            .displayFont(12, weight: .bold, design: .rounded)
                            .foregroundStyle(Color.sjzAccent)
                        Circle()
                            .fill(Color.sjzAccent).frame(width: 12, height: 12)
                            .overlay(Circle().fill(.white).frame(width: 5, height: 5))
                            .shadow(color: Color.sjzAccent.opacity(0.3), radius: 4, y: 2)
                        if idx < data.timeline.count - 1 {
                            Rectangle().fill(Color.sjzAccent.opacity(0.12)).frame(width: 2)
                        }
                    }
                    .frame(width: 56)
                    Text(event.event)
                        .displayFont(15).foregroundStyle(.primary)
                        .padding(.bottom, idx < data.timeline.count - 1 ? 28 : 0)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func newsThumbnail(item: NewsItem) -> some View {
        Group {
            if let imgUrl = item.imageUrl, let url = URL(string: imgUrl) {
                SJZCachedImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        newsPlaceholderView(item.category)
                    default:
                        ShimmerView().frame(width: 84, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .frame(width: 84, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                newsPlaceholderView(item.category)
            }
        }
        // 统一时长角标：缩略图右下角（全文口径优先，摘要估算兜底，全 App 规范一致）
        .overlay(alignment: .bottomTrailing) {
            ReadingTimeBadgeView(cachedID: item.readKey, summary: item.summary)
                .padding(4)
        }
    }

    private func newsPlaceholderView(_ category: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(categoryColor(category).opacity(0.06))
                .frame(width: 84, height: 64)
            Image(systemName: "newspaper.fill")
                .foregroundStyle(categoryColor(category).opacity(0.2))
        }
    }

    private func statColor(_ icon: String) -> Color {
        switch icon {
        case "book.closed.fill": return Color.sjzAccent
        case "building.2.fill": return Color.sjzPurple
        case "person.3.fill": return Color.sjzTeal
        case "briefcase.fill": return Color.sjzOrange
        default: return Color.sjzAccent
        }
    }

    private func honorColor(_ icon: String) -> Color {
        switch icon {
        case "medal.fill": return Color.sjzGold
        case "rosette": return Color.sjzPurple
        case "star.fill": return Color.sjzOrange
        case "star.circle.fill": return Color.sjzAccent
        case "sparkles": return Color.sjzPink
        case "heart.fill": return Color.sjzRed
        default: return Color.sjzAccent
        }
    }
}

// MARK: - Category Badge & Colors

struct CategoryBadge: View {
    let category: String
    var body: some View {
        Text(category)
            .displayFont(10, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(categoryColor(category), in: Capsule())
    }
}

func categoryColor(_ category: String) -> Color {
    switch category {
    case "学校要闻": return Color.sjzRed
    case "新闻资讯": return Color.sjzAccent
    case "党建动态": return Color(hex: "B71C1C")
    case "通知公告": return Color.sjzOrange
    case "招生信息": return Color.sjzGreen
    case "招生": return Color(hex: "1A73E8")
    case "校园文化": return Color.sjzPurple
    default: return Color.sjzAccent
    }
}

func quickLinkColor(_ title: String) -> Color {
    switch title {
    case "院系查询": return Color.sjzAccent
    case "新闻资讯": return Color.sjzRed
    case "校园荣誉": return Color.sjzGold
    case "校园服务": return Color.sjzMint
    case "招生就业": return Color.sjzGreen
    case "学校概况": return Color.sjzPurple
    default: return Color.sjzAccent
    }
}

// MARK: - 视频播放器

struct VideoPlayerView: View {
    let video: CampusVideo
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var statusObserver: AnyCancellable?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loadFailed {
                // 加载失败：显示错误信息和重试按钮
                VStack(spacing: 24) {
                    Image(systemName: "play.slash")
                        .displaySymbolFont(48)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(errorMessage ?? "视频加载失败")
                        .displayFont(17, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("学校服务器可能限制了直接访问，\n已自动添加访问来源标识后重试。")
                        .displayFont(12)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                    Button {
                        loadVideo()
                    } label: {
                        Label("重新加载", systemImage: "arrow.clockwise")
                            .displayLabelFont(15, weight: .medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(.white.opacity(0.15), in: Capsule())
                    }
                }
                .padding(40)
            } else if isLoading {
                // 加载中
                VStack(spacing: 20) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text("正在加载视频...")
                        .displayFont(15)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(video.title)
                        .displayFont(12)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else if let player = player {
                // 播放中
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            showControls.toggle()
                        }
                    }
            }
        }
        .navigationTitle(video.title).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.black.opacity(0.8), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { loadVideo() }
        .onDisappear {
            player?.pause()
            statusObserver?.cancel()
            player = nil
            playerItem = nil
        }
    }

    private func loadVideo() {
        isLoading = true
        loadFailed = false
        errorMessage = nil
        player?.pause()
        player = nil
        playerItem = nil
        statusObserver?.cancel()

        guard let url = URL(string: video.videoUrl), !video.videoUrl.isEmpty else {
            isLoading = false
            loadFailed = true
            errorMessage = "无效的视频地址"
            LogManager.shared.error("ui", "视频地址无效", context: ["title": video.title, "url": video.videoUrl])
            return
        }

        LogManager.shared.info("ui", "开始加载视频", context: ["title": video.title, "url": video.videoUrl])

        let item = AVPlayerItem(url: url)
        playerItem = item

        // 监听播放状态
        statusObserver = item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { status in
                switch status {
                case .readyToPlay:
                    isLoading = false
                    loadFailed = false
                    player?.play()
                    LogManager.shared.info("ui", "视频就绪开始播放", context: ["title": video.title])
                case .failed:
                    isLoading = false
                    loadFailed = true
                    if let error = item.error {
                        errorMessage = "播放失败：\(error.localizedDescription)"
                    } else {
                        errorMessage = "视频加载失败，请检查网络连接"
                    }
                    LogManager.shared.error("ui", "视频加载失败", context: [
                        "title": video.title, "error": item.error?.localizedDescription ?? "未知错误"
                    ])
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }

        player = AVPlayer(playerItem: item)
    }
}

// MARK: - 分享格式枚举

enum ShareFormat: Identifiable {
    case link
    case markdown
    case fullText
    case longImage

    var id: String {
        switch self {
        case .link: return "link"
        case .markdown: return "markdown"
        case .fullText: return "fullText"
        case .longImage: return "longImage"
        }
    }
}

// MARK: - 长图素材（压缩数据 + 尺寸元数据）

/// 长图素材：压缩数据 + 像素尺寸（EXIF 方向已归一）+ 图注。
/// 体积小可常驻；渲染时按目标尺寸即时缩略解码，避免 N 张全尺寸解码图同时驻留
/// ——「图片多的文章」黑图 / 内存被杀的主要来源之一。
struct ArticleLongImageAsset {
    let data: Data
    let pixelSize: CGSize
    let alt: String?
    let sourceHost: String
}

// MARK: - 长图素材加载器（7 处文章页共用）

/// 长图素材加载器：只做「下载压缩数据 + ImageIO 头解析像素尺寸」，绝不整图解码；
/// 有界并发（受全局图片闸约束），多图文章保持原顺序返回。
@MainActor
enum ArticleLongImageLoader {
    static let logDomain = "longimage"
    /// 并发上限（避免多图文章请求风暴，同时受全局图片闸 ≤4 约束）
    static let maxConcurrent = 3

    /// 批量加载（保持原顺序；单张失败跳过并留痕，不阻断其余图片）
    static func loadAll(_ infos: [DataService.ArticleImage], tag: String) async -> [ArticleLongImageAsset] {
        guard !infos.isEmpty else { return [] }
        let started = Date()
        var results = [ArticleLongImageAsset?](repeating: nil, count: infos.count)
        await withTaskGroup(of: (Int, ArticleLongImageAsset?).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < infos.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask { (index, await load(infos[index], index: index, tag: tag)) }
            }
            for _ in 0..<min(maxConcurrent, infos.count) { enqueueNext() }
            for await (index, asset) in group {
                results[index] = asset
                enqueueNext()
            }
        }
        let assets = results.compactMap { $0 }
        let totalBytes = assets.reduce(0) { $0 + $1.data.count }
        LogManager.shared.info(logDomain, "长图素材加载完成", context: [
            "tag": tag,
            "requested": "\(infos.count)",
            "loaded": "\(assets.count)",
            "failed": "\(infos.count - assets.count)",
            "bytes": "\(totalBytes)",
            "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"
        ])
        return assets
    }

    /// 单图加载：下载 + 解析像素尺寸（不解码）
    private static func load(_ info: DataService.ArticleImage, index: Int, tag: String) async -> ArticleLongImageAsset? {
        guard let url = URL(string: info.url), url.scheme?.hasPrefix("http") == true else {
            LogManager.shared.debugLog(logDomain, "长图素材地址无效（已跳过）", context: [
                "tag": tag, "index": "\(index)", "url": info.url
            ])
            return nil
        }
        let started = Date()
        // 全局图片闸（与列表 / 全屏 / 预取共用名额，治理镜像站拥塞）
        await SJZImageConcurrencyGate.shared.acquire()
        let data = await download(url, index: index, tag: tag)
        await SJZImageConcurrencyGate.shared.release()
        guard let data else { return nil }
        guard let pixelSize = Self.pixelSize(of: data) else {
            LogManager.shared.warning(logDomain, "长图素材解析失败（无有效图像头，已跳过）", context: [
                "tag": tag, "index": "\(index)", "bytes": "\(data.count)", "file": url.lastPathComponent
            ])
            return nil
        }
        LogManager.shared.debugLog(logDomain, "长图素材就绪", context: [
            "tag": tag,
            "index": "\(index)",
            "bytes": "\(data.count)",
            "pixel": "\(Int(pixelSize.width))x\(Int(pixelSize.height))",
            "host": url.host ?? "-",
            "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"
        ])
        return ArticleLongImageAsset(data: data, pixelSize: pixelSize, alt: info.alt, sourceHost: url.host ?? "-")
    }

    /// 下载压缩数据（统一图片管线：协议层 Referer + 会话复用）
    private static func download(_ url: URL, index: Int, tag: String) async -> Data? {
        do {
            let request = SJZImageKit.makeRequest(url: url)
            let (data, response) = try await SJZImageKit.imageSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                LogManager.shared.warning(logDomain, "长图素材下载失败", context: [
                    "tag": tag, "index": "\(index)",
                    "status": "\((response as? HTTPURLResponse)?.statusCode ?? -1)",
                    "file": url.lastPathComponent
                ])
                return nil
            }
            return data
        } catch {
            // 取消语义对齐工程红线：cancelled / CancellationError 静默处理（用户切页 / 取消属正常行为，不告警）
            let urlError = error as? URLError
            if urlError?.code == .cancelled || error is CancellationError || Task.isCancelled {
                LogManager.shared.debugLog(logDomain, "长图素材下载取消", context: ["tag": tag, "index": "\(index)"])
                return nil
            }
            LogManager.shared.warning(logDomain, "长图素材下载异常", context: [
                "tag": tag, "index": "\(index)", "error": error.localizedDescription
            ])
            return nil
        }
    }

    // MARK: 像素尺寸（ImageIO 头解析；纯函数便于契约测试）

    /// 解析像素尺寸（不整图解码）；读取 EXIF 方向并归一
    nonisolated static func pixelSize(of data: Data) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return orientedPixelSize(CGSize(width: width, height: height), orientation: orientation)
    }

    /// 按 EXIF 方向归一像素尺寸：5-8 为 90°/270° 旋转 → 宽高互换（契约测试锚点）
    nonisolated static func orientedPixelSize(_ size: CGSize, orientation: UInt32) -> CGSize {
        (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }
}

// MARK: - 图像完整性校验（长图全链共用：纯色 / 黑图防线）

/// 图像产物完整性校验（长图链路的每一级产物都必须过此校验）。
/// 背景：`UIGraphicsImageRenderer` 在**画布分配或绘制失败**时会**静默返回纯黑/纯色图**
/// ——不报错、尺寸合法，且纯色 JPEG 字节极小，还能骗过微信 10MB 上限校验。
/// 因此「渲染画布 → 编码候选 → 最终 JPEG」三级产物全部要做内容校验。
enum SJZImageIntegrity {
    /// 抽样网格（32×32 = 1024 点）：足以判定纯色，超大位图零遍历成本
    private static let grid = 32
    /// 极差阈值：< 8 视为纯色（正常长图必含深色文字与白底，绝不可能是纯色画布）
    private static let rangeThreshold = 8

    /// true = 疑似纯色 / 黑图失效产物；**无法取证时按失效处理**（fail-closed：宁可重试，绝不交付黑图）
    static func isLikelyBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        return isLikelyBlank(cgImage: cgImage)
    }

    /// CGImage 版本（画布 / 编码数据缩略解码后的校验入口）
    static func isLikelyBlank(cgImage: CGImage) -> Bool {
        guard let range = channelRange(of: cgImage) else { return true }   // 无法取证 → fail-closed
        return Int(range.max) - Int(range.min) < rangeThreshold
    }

    /// 抽样通道极值（**布局感知**）：先走标准 32bpp 位图快路径（按 `alphaInfo` 跳过 alpha），
    /// 非常规布局（16 位/压缩 provider）则绘入自建 RGBA8 缓冲再抽样。
    /// 教训（2026-09-28）：ImageIO 缩略图为 `premultipliedFirst`，首字节恒为 alpha=255——
    /// 若按「首字节」抽样会把**所有合法图**误判为纯色（真机实测），必须按布局取样。
    nonisolated private static func channelRange(of cgImage: CGImage) -> (min: UInt8, max: UInt8)? {
        if let direct = directBitmapChannelRange(of: cgImage) { return direct }
        return selfDrawnChannelRange(of: cgImage)
    }

    /// 快路径：标准 32bpp 位图（4B/px；行距允许对齐填充，抽样按 rowBytes 步进）
    nonisolated private static func directBitmapChannelRange(of cgImage: CGImage) -> (min: UInt8, max: UInt8)? {
        guard cgImage.bitsPerPixel == 32,
              cgImage.bytesPerRow >= cgImage.width * 4,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let alphaFirst: Bool
        switch cgImage.alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaFirst = true
        default: alphaFirst = false
        }
        let channelOffsets = alphaFirst ? [1, 2, 3] : [0, 1, 2]
        let rowBytes = cgImage.bytesPerRow
        let length = CFDataGetLength(data)
        var minValue: UInt8 = 255
        var maxValue: UInt8 = 0
        for iy in 0..<grid {
            let y = cgImage.height * iy / grid
            for ix in 0..<grid {
                let x = cgImage.width * ix / grid
                let base = y * rowBytes + x * 4
                for offset in channelOffsets {
                    let index = base + offset
                    guard index < length else { continue }
                    minValue = min(minValue, bytes[index])
                    maxValue = max(maxValue, bytes[index])
                }
            }
        }
        return (minValue, maxValue)
    }

    /// 通用路径：把 CGImage 绘入自建 32×32 RGBA8 缓冲（布局完全可控）后抽样 RGB
    nonisolated private static func selfDrawnChannelRange(of cgImage: CGImage) -> (min: UInt8, max: UInt8)? {
        let side = 32
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var minValue: UInt8 = 255
        var maxValue: UInt8 = 0
        for index in stride(from: 0, to: buffer.count, by: 4) {
            for offset in 0..<3 {   // 跳过 alpha（第 4 字节恒为 255）
                let value = buffer[index + offset]
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
            }
        }
        return (minValue, maxValue)
    }

    /// 对**已编码图片数据**（JPEG/PNG）做缩略解码后校验（约 10ms、低内存）：
    /// 作为「最终交付前」的最后一道防线，可捕获编码阶段引入的纯色 / 黑图
    static func isLikelyBlank(encodedImage data: Data) -> Bool {
        guard let thumbnail = ArticleLongImageRenderer.decodeThumbnail(data, maxPixel: 256) else { return true }
        return isLikelyBlank(cgImage: thumbnail)
    }

    /// 真实像素尺寸：`UIImage.size` 是**点**（随 scale 变化），预算 / 日志 / 降采样必须用像素
    static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// 日志友好的像素尺寸串
    static func pixelSizeText(of image: UIImage) -> String {
        let size = pixelSize(of: image)
        return "\(Int(size.width))x\(Int(size.height))"
    }
}

// MARK: - 分享临时文件生命周期（系统分享扩展读取保障）

/// 系统分享临时文件管理。
/// 背景（2026-09-28 现场）：`UIActivityViewController.completionWithItemsHandler` 会在
/// **用户选择动作时即回调**（而非分享真正结束后）——若在其中立即删除临时文件，
/// 与分享扩展（微信等）的读取/转存发生竞态，表现为「微信加载中 → 快速闪回 App、分享失败」。
/// 约定：文件必须活过整个分享期（延迟 5 分钟清理），并在每次分享前清理更早的残留。
@MainActor
enum SJZShareFileCenter {
    /// 保留时长（秒）：远大于扩展读取 / 转存耗时
    static let retention: TimeInterval = 300
    /// 陈旧残留清理阈值（秒）
    private static let staleInterval: TimeInterval = 600

    /// 安排延迟清理（替代「选动作后 1 秒即删」的错误生命周期）；顺带清理更早的残留文件
    static func scheduleCleanup(_ url: URL) {
        cleanupStale(excluding: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + retention) {
            try? FileManager.default.removeItem(at: url)
            LogManager.shared.debugLog("longimage", "长图临时分享文件已清理", context: [
                "file": url.lastPathComponent
            ])
        }
    }

    /// 清理陈旧分享文件（保留当前正在使用的文件，避免残留堆积）
    private static func cleanupStale(excluding current: URL) {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for file in files where file.lastPathComponent.hasPrefix("sxjzit_") && file != current {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > staleInterval {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - 文章长图渲染器

/// 文章长图渲染器（白底长图：品牌头 / 标题 / 元数据 / 正文 / 插图 / 页脚）。
///
/// 黑图防线（2026-09-28 加固；现场「图片多的文章偶发纯黑图」根因修复）：
/// ① 画布自适应：原实现固定 `scale = 3` 且高度无界——多图文章位图动辄 200MB+，
///    CoreGraphics 位图分配失败时 `UIGraphicsImageRenderer` 会**静默产出黑图**；
///    现按「设备可用内存 + 像素总量 / 高度硬上限」计算渲染倍率（`budget(...)`）；
/// ② 插图按需缩略解码：素材以压缩数据持有，绘制时经 ImageIO 缩略解码到目标尺寸，
///    不再把 N 张全尺寸解码图同时驻留内存（多图文章的另一内存主因）；
/// ③ 产物校验 + 降级重试：渲染后做纯色 / 黑图校验（`isLikelyBlank`），
///    失效则「降倍率 → 省略插图」逐级重试，全链日志留痕，绝不把黑图交给分享。
struct ArticleLongImageRenderer {
    let title: String
    let metadata: String
    let content: String
    let images: [ArticleLongImageAsset]
    let articleURL: String
    /// 入口标识（日志归因，如 "news_detail" / "organization_detail"）
    var tag: String = "article"

    static let imageWidth: CGFloat = 750
    static let paddingH: CGFloat = 28
    static let contentWidth: CGFloat = imageWidth - paddingH * 2
    /// 长图字体统一走显示设置工厂（家族 + 档位缩放 + 粗体）——2026-09-29 全局覆盖：
    /// 长图产物与 App 内排版一致，不再固定系统字体（UserDefaults 快照直读，兼容后台渲染上下文）
    static func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let snapshot = DisplaySettingsManager.typographySnapshot()
        return DisplayUIFontFactory.uiFont(size: size, weight: weight, scale: snapshot.scale,
                                           family: snapshot.family, bold: snapshot.bold)
    }
    static var titleFont: UIFont { uiFont(size: 28, weight: .bold) }
    static var metaFont: UIFont { uiFont(size: 14) }
    static var bodyFont: UIFont { uiFont(size: 17) }
    static var footerFont: UIFont { uiFont(size: 12) }
    static var brandFont: UIFont { uiFont(size: 11, weight: .medium) }
    static var altFont: UIFont { uiFont(size: 11) }
    /// 正文行距：8pt × 显示设置行距系数（联动「行距」档；快照直读）
    static var lineSpacing: CGFloat { 8 * CGFloat(DisplaySettingsManager.typographySnapshot().lineSpacingFactor) }
    /// 插图最大显示高度（相对内容宽度）：超过则等比填充裁切（不再纵向压扁）
    static let imageHeightCapRatio: CGFloat = 1.2

    // MARK: 渲染预算（黑图防线①；纯函数，契约测试锚点）

    /// 首选输出倍率
    static let preferredScale: CGFloat = 3
    /// 位图高度硬上限（像素；48,000 ≈ 16,000pt 内容可达 3x）
    static let maxPixelHeight: CGFloat = 48_000
    /// 位图字节硬上限（RGBA 8 位 = 4B/px，72MP ≈ 288MB）：与后续 JPEG 编码 / 微信分享的峰值内存匹配。
    /// 取值的平衡：越大越清晰（长文可维持更高倍率），但峰值内存越高——由「可用内存 × 35%」动态兜底 + 降级阶梯保证安全。
    /// 注意：渲染器已强制 `preferredRange = .standard`（8 位/通道）——若为 16 位扩展域则实际内存翻倍
    static let maxRenderBytes = 288 * 1024 * 1024
    /// 位图字节下限（可用内存极低时仍保证可渲染）
    static let minRenderBytes = 64 * 1024 * 1024
    /// 可用内存使用比例上限（为 JPEG 编码 / 分享 / 系统留余量）
    static let memoryUseRatio = 0.35
    /// 常规质量下限（低于则属极端超长内容：内存预算优先，允许继续降）
    static let minScale: CGFloat = 0.5

    /// 渲染预算（倍率 + 像素尺寸 + 字节 + 约束来源）
    struct RenderBudget {
        let scale: CGFloat
        let pixelSize: CGSize
        let bitmapBytes: Int
        let availableBytes: UInt64
        /// 约束来源：preferred / bytes / height / floor
        let reason: String
    }

    /// 计算渲染预算：scale = min(首选倍率, 内存预算, 高度上限)
    static func budget(forLogicalSize logical: CGSize, availableBytes: UInt64) -> RenderBudget {
        let w = max(logical.width, 1)
        let h = max(logical.height, 1)
        let byteBudget: Double
        if availableBytes > 0 {
            byteBudget = min(Double(maxRenderBytes),
                             max(Double(minRenderBytes), Double(availableBytes) * memoryUseRatio))
        } else {
            byteBudget = Double(maxRenderBytes)
        }
        let scaleByBytes = (byteBudget / 4 / Double(w * h)).squareRoot()
        let scaleByHeight = Double(maxPixelHeight) / Double(h)
        let preferred = Double(preferredScale)
        var scale = min(preferred, scaleByBytes, scaleByHeight)
        var reason = "preferred"
        if scale < preferred { reason = scaleByBytes <= scaleByHeight ? "bytes" : "height" }
        if scale < Double(minScale) {
            // 极端超长内容：内存预算优先（不再保证质量下限），reason=floor 留痕
            scale = max(scale, 0.2)
            reason = "floor"
        }
        let pixelSize = CGSize(width: (w * scale).rounded(.down), height: (h * scale).rounded(.down))
        return RenderBudget(scale: CGFloat(scale),
                            pixelSize: pixelSize,
                            bitmapBytes: Int(pixelSize.width * pixelSize.height) * 4,
                            availableBytes: availableBytes,
                            reason: reason)
    }

    /// 进程可用内存（字节）；取不到返回 0（预算退回静态上限）
    static func availableMemoryBytes() -> UInt64 {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? UInt64(bytes) : 0
    }

    // MARK: 渲染（含校验与降级重试）

    /// 生成长图；全部降级尝试均未通过校验时返回 nil（调用方展示错误态，绝不交付黑图）
    @MainActor
    func render() -> UIImage? {
        let available = Self.availableMemoryBytes()
        let started = Date()
        // 降级阶梯：预算倍率 → 降倍率 → 省略插图（图片多到内存不足时仍产出可用长图）
        let ladder: [(label: String, factor: CGFloat, includeImages: Bool)] = [
            ("budget", 1.0, true),
            ("reduced", 0.6, true),
            ("noImages", 0.6, false)
        ]

        for (index, step) in ladder.enumerated() {
            let logicalSize = CGSize(width: Self.imageWidth,
                                     height: calculateTotalHeight(includeImages: step.includeImages))
            let budget = Self.budget(forLogicalSize: logicalSize, availableBytes: available)
            // 降级只会更小：永远不得超过预算倍率（否则降级反而可能触发分配失败 → 黑图）
            let scale = min(max(budget.scale * step.factor, 0.08), budget.scale)
            let pixelSize = CGSize(width: (logicalSize.width * scale).rounded(.down),
                                   height: (logicalSize.height * scale).rounded(.down))
            let bitmapMB = Int(pixelSize.width * pixelSize.height) * 4 / 1024 / 1024

            if index == 0 {
                LogManager.shared.info("longimage", "长图渲染开始", context: [
                    "tag": tag,
                    "title": String(title.prefix(24)),
                    "logical": "\(Int(logicalSize.width))x\(Int(logicalSize.height))",
                    "scale": String(format: "%.2f", scale),
                    "pixel": "\(Int(pixelSize.width))x\(Int(pixelSize.height))",
                    "bitmapMB": "\(bitmapMB)",
                    "availableMB": "\(available / 1024 / 1024)",
                    "constraint": budget.reason,
                    "images": "\(images.count)"
                ])
            }

            guard let image = renderOnce(logicalSize: logicalSize,
                                         includeImages: step.includeImages,
                                         scale: scale) else {
                LogManager.shared.warning("longimage", "长图渲染未产出画布（已降级重试）", context: [
                    "tag": tag, "step": step.label, "scale": String(format: "%.2f", scale)
                ])
                continue
            }

            if !Self.isLikelyBlank(image) {
                let cost = Int(Date().timeIntervalSince(started) * 1000)
                LogManager.shared.info("longimage", "长图渲染完成", context: [
                    "tag": tag,
                    "step": step.label,
                    "scale": String(format: "%.2f", scale),
                    "imageScale": String(format: "%.2f", image.scale),
                    "pixel": "\(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0)",
                    "bpp": "\(image.cgImage?.bitsPerPixel ?? 0)",
                    "bytesMB": "\(Int(Double((image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0)) * Double(image.cgImage?.bitsPerPixel ?? 32) / 8) / 1024 / 1024)",
                    "bitmapMB": "\(bitmapMB)",
                    "images": "\(images.count)",
                    "includedImages": step.includeImages ? "\(images.count)" : "0",
                    "degraded": "\(step.label != "budget")",
                    "ms": "\(cost)"
                ])
                return image
            }

            LogManager.shared.warning("longimage", "长图校验未通过（疑似纯色 / 黑图产物），自动降级重试", context: [
                "tag": tag,
                "step": step.label,
                "scale": String(format: "%.2f", scale),
                "pixel": "\(Int(pixelSize.width))x\(Int(pixelSize.height))",
                "bitmapMB": "\(bitmapMB)",
                "availableMB": "\(available / 1024 / 1024)",
                "next": index + 1 < ladder.count ? ladder[index + 1].label : "fail"
            ])
        }

        LogManager.shared.error("longimage", "长图生成失败（全部降级尝试均未通过校验）", context: [
            "tag": tag,
            "images": "\(images.count)",
            "availableMB": "\(available / 1024 / 1024)",
            "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"
        ])
        return nil
    }

    /// 单次渲染（不做校验）：画布未产出时返回 nil
    @MainActor
    private func renderOnce(logicalSize: CGSize, includeImages: Bool, scale: CGFloat) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // 关键（2026-09-28 黑图根因②）：强制 8 位/通道标准色域。
        // iOS 26/27 在 HDR 机型（如 XDR 屏 iPhone）上默认可能给 **16 位扩展域**位图（实测真机 64bpp），
        // 画布内存因此**翻倍**——按 4B/px 估算的预算会在超大画布上直接分配失败 → 静默黑图。
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: logicalSize, format: format)
        let image = renderer.image { ctx in
            draw(in: ctx, logicalSize: logicalSize, includeImages: includeImages, scale: scale)
        }
        guard image.cgImage != nil else { return nil }
        return image
    }

    /// 产物校验（黑图防线③）：转发共享校验器（fail-closed：无法取证按失效处理）
    static func isLikelyBlank(_ image: UIImage) -> Bool {
        SJZImageIntegrity.isLikelyBlank(image)
    }

    // MARK: 绘制

    @MainActor
    private func draw(in ctx: UIGraphicsImageRendererContext, logicalSize: CGSize, includeImages: Bool, scale: CGFloat) {
        // 白色背景
        UIColor.white.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: logicalSize.width, height: logicalSize.height))

        var y: CGFloat = 32

        // 顶部品牌标识
        let brandAttr: [NSAttributedString.Key: Any] = [
            .font: Self.brandFont,
            .foregroundColor: UIColor(white: 0.5, alpha: 1)
        ]
        let brandStr = "山西晋中理工学院 APP"
        let brandSize = (brandStr as NSString).size(withAttributes: brandAttr)
        (brandStr as NSString).draw(at: CGPoint(x: Self.paddingH, y: y), withAttributes: brandAttr)
        y += brandSize.height + 16

        // 标题
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: UIColor.black
        ]
        y += drawMultilineText(title, at: CGPoint(x: Self.paddingH, y: y),
                               width: Self.contentWidth, attributes: titleAttr, lineSpacing: 4) + 12

        // 元数据
        if !metadata.isEmpty {
            let metaAttr: [NSAttributedString.Key: Any] = [
                .font: Self.metaFont,
                .foregroundColor: UIColor(white: 0.45, alpha: 1)
            ]
            y += drawMultilineText(metadata, at: CGPoint(x: Self.paddingH, y: y),
                                   width: Self.contentWidth, attributes: metaAttr, lineSpacing: 2) + 16
        }

        // 分隔线
        UIColor(white: 0.9, alpha: 1).setFill()
        ctx.fill(CGRect(x: Self.paddingH, y: y, width: Self.contentWidth, height: 1))
        y += 20

        // 正文（段落间插入图片）
        let paragraphs = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let bodyParagraphStyle = NSMutableParagraphStyle()
        bodyParagraphStyle.lineSpacing = Self.lineSpacing
        // 正文颜色联动显示设置：白底长图固定使用浅色色值；「跟随系统」保持原默认深灰
        let bodyAttr: [NSAttributedString.Key: Any] = [
            .font: Self.bodyFont,
            .foregroundColor: Self.resolvedBodyUIColor(),
            .paragraphStyle: bodyParagraphStyle,
            .kern: DisplaySettingsManager.typographySnapshot().letterSpacing
        ]

        let drawAssets = includeImages ? images : []
        var imgIndex = 0
        for (i, para) in paragraphs.enumerated() {
            y += drawMultilineText(para, at: CGPoint(x: Self.paddingH, y: y),
                                   width: Self.contentWidth, attributes: bodyAttr, lineSpacing: Self.lineSpacing) + 10

            // 每 3 段插入一张图片（如果有的话）
            if (i + 1) % 3 == 0 && imgIndex < drawAssets.count {
                y += 8
                y += drawImage(drawAssets[imgIndex], at: CGPoint(x: Self.paddingH, y: y), scale: scale) + 12
                imgIndex += 1
            }
        }

        // 插入剩余图片
        while imgIndex < drawAssets.count {
            y += 8
            y += drawImage(drawAssets[imgIndex], at: CGPoint(x: Self.paddingH, y: y), scale: scale) + 12
            imgIndex += 1
        }

        y += 12

        // 分隔线
        UIColor(white: 0.9, alpha: 1).setFill()
        ctx.fill(CGRect(x: Self.paddingH, y: y, width: Self.contentWidth, height: 1))
        y += 20

        // 页脚
        let footerAttr: [NSAttributedString.Key: Any] = [
            .font: Self.footerFont,
            .foregroundColor: UIColor(white: 0.55, alpha: 1)
        ]
        _ = drawMultilineText(Self.footerText(articleURL: articleURL, includeImages: includeImages, imageCount: images.count),
                              at: CGPoint(x: Self.paddingH, y: y),
                              width: Self.contentWidth, attributes: footerAttr, lineSpacing: 4)
    }

    /// 页脚文案；省略插图时追加降级说明（可见告知，避免用户误以为丢图）
    nonisolated static func footerText(articleURL: String, includeImages: Bool, imageCount: Int) -> String {
        var text = "阅读原文：\(articleURL)\n由山西晋中理工学院 APP 分享"
        if !includeImages && imageCount > 0 {
            text += "\n（本篇图片较多，为保证生成成功已省略插图）"
        }
        return text
    }

    /// 长图正文颜色解析：联动显示设置（白底长图始终取浅色色值；「跟随系统」保持原默认深灰）
    /// nonisolated：从 UserDefaults 快照直读，兼容后台渲染上下文
    private static func resolvedBodyUIColor() -> UIColor {
        let snapshot = DisplaySettingsManager.articleBodyLightHexSnapshot()
        guard snapshot.presetRaw != ArticleTextColorPreset.system.rawValue else {
            return UIColor(white: 0.2, alpha: 1)
        }
        return UIColor(hex: snapshot.hex)
    }

    private func calculateTotalHeight(includeImages: Bool) -> CGFloat {
        var h: CGFloat = 32

        // 品牌标识
        let brandStr = "山西晋中理工学院 APP"
        let brandAttr: [NSAttributedString.Key: Any] = [.font: Self.brandFont]
        h += (brandStr as NSString).size(withAttributes: brandAttr).height + 16

        // 标题
        h += measureMultilineHeight(title, width: Self.contentWidth,
                                    attributes: [.font: Self.titleFont], lineSpacing: 4) + 12

        // 元数据
        if !metadata.isEmpty {
            h += measureMultilineHeight(metadata, width: Self.contentWidth,
                                        attributes: [.font: Self.metaFont], lineSpacing: 2) + 16
        }

        h += 1 + 20  // 分隔线

        // 正文段落（含插图：高度口径与绘制完全一致）
        let paragraphs = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let bodyParagraphStyle = NSMutableParagraphStyle()
        bodyParagraphStyle.lineSpacing = Self.lineSpacing
        let bodyAttr: [NSAttributedString.Key: Any] = [
            .font: Self.bodyFont,
            .paragraphStyle: bodyParagraphStyle,
            .kern: DisplaySettingsManager.typographySnapshot().letterSpacing
        ]

        let layoutAssets = includeImages ? images : []
        var imgIndex = 0
        for (i, para) in paragraphs.enumerated() {
            h += measureMultilineHeight(para, width: Self.contentWidth, attributes: bodyAttr, lineSpacing: Self.lineSpacing) + 10
            if (i + 1) % 3 == 0 && imgIndex < layoutAssets.count {
                h += 8 + imageDisplayHeight(for: layoutAssets[imgIndex].pixelSize) + 12
                imgIndex += 1
            }
        }
        while imgIndex < layoutAssets.count {
            h += 8 + imageDisplayHeight(for: layoutAssets[imgIndex].pixelSize) + 12
            imgIndex += 1
        }

        h += 12 + 1 + 20  // 分隔线

        h += measureMultilineHeight(Self.footerText(articleURL: articleURL, includeImages: includeImages, imageCount: images.count),
                                    width: Self.contentWidth,
                                    attributes: [.font: Self.footerFont], lineSpacing: 4) + 32

        return max(h, 200)
    }

    /// 插图显示高度：按内容宽度等比缩放，超过 1.2 倍内容宽度时封顶（绘制时按填充裁切，不压扁）
    private func imageDisplayHeight(for pixelSize: CGSize) -> CGFloat {
        let maxWidth = Self.contentWidth
        let ratio = pixelSize.height / max(pixelSize.width, 1)
        return min(maxWidth * ratio, maxWidth * Self.imageHeightCapRatio)
    }

    /// 绘制插图：按目标像素即时缩略解码（ImageIO）+ 等比填充居中裁切；返回占用高度（含图注）
    @MainActor
    private func drawImage(_ asset: ArticleLongImageAsset, at origin: CGPoint, scale: CGFloat) -> CGFloat {
        guard let ctx = UIGraphicsGetCurrentContext() else { return 0 }
        let maxWidth = Self.contentWidth
        let displayHeight = imageDisplayHeight(for: asset.pixelSize)
        let imgRect = CGRect(x: origin.x, y: origin.y, width: maxWidth, height: displayHeight)

        // 目标最长边像素（1.25x 冗余：填充裁切下仍足够清晰，且避免解码过大）
        let targetPixel = max(imgRect.width, imgRect.height) * max(scale, 0.5) * 1.25
        autoreleasepool {
            guard let cgImage = Self.decodeThumbnail(asset.data, maxPixel: targetPixel) else {
                LogManager.shared.warning("longimage", "长图插图解码失败（已跳过绘制）", context: [
                    "tag": tag,
                    "bytes": "\(asset.data.count)",
                    "host": asset.sourceHost
                ])
                return
            }
            ctx.saveGState()
            UIBezierPath(roundedRect: imgRect, cornerRadius: 8).addClip()
            // 等比填充 + 居中裁切（scaledToFill 语义）：修复原实现「按目标矩形拉伸」导致的纵向压扁
            let pixel = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            let fillScale = max(imgRect.width / max(pixel.width, 1), imgRect.height / max(pixel.height, 1))
            let drawSize = CGSize(width: pixel.width * fillScale, height: pixel.height * fillScale)
            let drawOrigin = CGPoint(x: imgRect.midX - drawSize.width / 2,
                                     y: imgRect.midY - drawSize.height / 2)
            // 必须用 UIImage.draw：UIKit 上下文（y 向下）下 `CGContext.draw(cgImage:)` 会把图**上下翻转**
            // （2026-09-28 真机剖面取证：素材顶部黑带被画到插图区域底部）——UIImage.draw 才是 UIKit 正确语义
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: drawOrigin, size: drawSize))
            ctx.restoreGState()
        }

        var totalHeight = displayHeight

        // 图片描述
        if let alt = asset.alt, !alt.isEmpty {
            let altAttr: [NSAttributedString.Key: Any] = [
                .font: Self.altFont,
                .foregroundColor: UIColor(white: 0.5, alpha: 1)
            ]
            totalHeight += 6 + drawMultilineText(
                alt, at: CGPoint(x: origin.x, y: origin.y + displayHeight + 6),
                width: maxWidth, attributes: altAttr, lineSpacing: 2
            )
        }

        return totalHeight
    }

    /// 从压缩数据解码「可用」的缩略图（多配方回退 + 内容校验）：
    /// ① 缩略图（带 EXIF 方向归一 + 立即解码）→ ② 去立即解码变体 → ③ 无变换变体
    /// → ④ 子采样整图兜底；每个候选都做纯色 / 黑图校验（fail-closed），
    /// 绝不把黑块画进长图，也绝不让黑图通过编码产物校验。
    nonisolated static func decodeThumbnail(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let limit = max(64, maxPixel)
        let thumbnailRecipes: [[CFString: Any]] = [
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true,   // 应用 EXIF 方向
             kCGImageSourceShouldCacheImmediately: true,
             kCGImageSourceThumbnailMaxPixelSize: limit],
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: limit],
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceThumbnailMaxPixelSize: limit]
        ]
        for recipe in thumbnailRecipes {
            if let candidate = CGImageSourceCreateThumbnailAtIndex(source, 0, recipe as CFDictionary),
               !SJZImageIntegrity.isLikelyBlank(cgImage: candidate) {
                return candidate
            }
        }
        // 兜底：子采样整图（JPEG 走 DCT 缩放，内存仍远小于全尺寸；倍率按源图换算保证清晰度）
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            let factor = max(1, Int((max(sourceWidth, sourceHeight) / limit).rounded(.down)))
            if let candidate = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: factor] as CFDictionary),
               !SJZImageIntegrity.isLikelyBlank(cgImage: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func drawMultilineText(
        _ text: String, at origin: CGPoint,
        width: CGFloat, attributes: [NSAttributedString.Key: Any],
        lineSpacing: CGFloat
    ) -> CGFloat {
        let paraStyle = (attributes[.paragraphStyle] as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paraStyle.lineBreakMode = .byWordWrapping
        paraStyle.lineSpacing = lineSpacing
        var attr = attributes
        attr[.paragraphStyle] = paraStyle

        let size = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attr, context: nil
        )
        (text as NSString).draw(in: CGRect(x: origin.x, y: origin.y, width: width, height: size.height), withAttributes: attr)
        return size.height
    }

    private func measureMultilineHeight(
        _ text: String, width: CGFloat,
        attributes: [NSAttributedString.Key: Any], lineSpacing: CGFloat
    ) -> CGFloat {
        let paraStyle = (attributes[.paragraphStyle] as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paraStyle.lineBreakMode = .byWordWrapping
        paraStyle.lineSpacing = lineSpacing
        var attr = attributes
        attr[.paragraphStyle] = paraStyle

        let size = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attr, context: nil
        )
        return size.height
    }
}

// MARK: - 系统分享面板（UIActivityViewController 封装，兼容微信等第三方应用）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // 排除不适用于文章的分享目标
        controller.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 分段加载阶段

enum LoadingPhase: Equatable, CustomStringConvertible {
    case initializing
    case checkingCache
    case fetchingNetwork
    case parsingContent
    case rendering
    case complete
    case failed

    var description: String {
        switch self {
        case .initializing: return "准备加载"
        case .checkingCache: return "查询缓存"
        case .fetchingNetwork: return "获取数据"
        case .parsingContent: return "解析内容"
        case .rendering: return "渲染页面"
        case .complete: return "加载完成"
        case .failed: return "加载失败"
        }
    }

    var iconName: String {
        switch self {
        case .initializing: return "hourglass"
        case .checkingCache: return "tray.full"
        case .fetchingNetwork: return "antenna.radiowaves.left.and.right"
        case .parsingContent: return "text.word.spacing"
        case .rendering: return "paintbrush"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .initializing, .checkingCache: return .secondary
        case .fetchingNetwork: return .blue
        case .parsingContent: return .orange
        case .rendering: return .purple
        case .complete: return .green
        case .failed: return .red
        }
    }
}

// MARK: - 增强版新闻详情

struct EnhancedNewsDetailView: View {
    let news: NewsItem
    /// 下一篇待读文章 ID（E6：进入详情时并行预取下一篇，连续阅读秒开）
    var nextArticleId: String? = nil
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoadingDetail = true
    @State private var loadError: String?
    @State private var showWebView = false
    /// 看图载荷（item 式呈现：根治「先显示第一张」的陈旧快照 + 支持左右翻页）
    @State private var imageViewerPayload: SJZImageGalleryPayload?
    @State private var contentAppear = false
    @State private var showSharePicker = false
    @State private var selectedShareFormat: ShareFormat?
    @State private var showWeChatShare = false
    @State private var webViewShowShare = false
    @State private var isGeneratingLongImage = false
    /// 长图分享目标（系统分享面板 / 微信图片消息；由分享面板入口设置）
    @State private var longImageDestination: LongImageDestination = .system
    /// 微信长图分享载荷（非空 → 弹出长图分享菜单）
    @State private var weChatLongImagePayload: WeChatLongImagePayload?
    @State private var longImageError: String?
    @State private var loadingPhase: LoadingPhase = .initializing
    @State private var loadingStartTime: Date = .now
    @State private var showLoadingProgress = false
    @State private var elapsedLoadingTime: TimeInterval = 0
    // 画廊计数 + 缓存徽标 + 弱网提示（E1/E3/E7）
    @State private var galleryLoadedIndices: Set<Int> = []
    @State private var showGalleryBar = false
    @State private var showCachedBadge = false
    @State private var slowNetworkMessage: String?
    @ObservedObject private var readManager = ReadStatusManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 头图（统一缓存组件 + 平均色渐进占位）
                if let imgUrl = news.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url, maxPixel: 900) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 280)
                                .onTapGesture {
                                    imageViewerPayload = SJZImageGalleryPayload.single(url: url, source: "header")
                                    LogManager.shared.debugLog("imageViewer", "查看图片（头图）", context: [
                                        "url": url.lastPathComponent
                                    ])
                                }
                        case .failure:
                            detailHeaderPlaceholder
                        case .empty:
                            if let hex = SJZAverageColorCache.colorHex(for: url) {
                                // 二次访问：平均色瞬时占位（blur-up 本地化）
                                Color(hex: hex).frame(height: 240)
                            } else {
                                ShimmerView()
                            }
                        case .skipped:
                            // 无图模式：优雅静态占位（不起网络）
                            SJZImageFreePlaceholder(icon: "photo.on.rectangle")
                                .frame(height: 240)
                        }
                    }
                } else {
                    detailHeaderPlaceholder
                }

                VStack(alignment: .leading, spacing: 24) {
                    // 分类和日期
                    HStack(spacing: 10) {
                        CategoryBadge(category: news.category)
                        Text(news.date).displayFont(15).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showWebView = true
                        } label: {
                            Label("原文", systemImage: "safari")
                                .displayLabelFont(12, weight: .medium)
                                .foregroundStyle(Color.sjzAccent)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.sjzAccent.opacity(0.08), in: Capsule())
                        }
                    }

                    // 标题
                    Text(news.title)
                        .displayFont(24, weight: .bold)
                        .lineSpacing(8)

                    // 阅读统计独立行：与正文渲染口径一致（纯文本优先，为空回退 HTML 剥离）
                    if let detail = fullDetail {
                        let statsText = detail.plainTextContent.isEmpty
                            ? detail.content.strippingHTMLTags()
                            : detail.plainTextContent
                        if !statsText.isEmpty {
                            ArticleReadingStatsText(
                                cachedID: news.readKey,
                                plainText: statsText,
                                imageCount: detail.images.count
                            )
                        }
                    }

                    // 作者和来源
                    if !isLoadingDetail {
                        if let author = fullDetail?.author, !author.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill").displaySymbolFont(11)
                                Text("作者：\(author)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                        if let source = fullDetail?.source, !source.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link").displaySymbolFont(11)
                                Text("来源：\(source)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                    }

                    // E3 缓存徽标（数据来自缓存时展示，2.5s 后自动淡出）
                    if showCachedBadge {
                        SJZCachedBadge()
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }

                    Divider()

                    // 分段加载状态
                    if isLoadingDetail || loadingPhase != .complete {
                        VStack(spacing: 0) {
                            // 骨架屏：模拟正文内容形状（类 Apple News 渐进加载体验）
                            ArticleSkeletonRows()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 20)

                            // 相位指示器：延迟 500ms 后出现，避免缓存命中时短暂闪烁
                            if showLoadingProgress {
                                PhasedProgressIndicator(
                                    phase: loadingPhase,
                                    elapsedTime: elapsedLoadingTime,
                                    startTime: loadingStartTime,
                                    error: loadError,
                                    onRetry: { retryLoading() }
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .onAppear {
                            loadingStartTime = Date()
                            showLoadingProgress = false
                            Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if isLoadingDetail || loadingPhase != .complete {
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        showLoadingProgress = true
                                    }
                                }
                            }
                        }
                    } else if let error = loadError {
                        // 加载失败，显示摘要和错误提示
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .displayFont(13)
                                    .foregroundStyle(.orange)
                            }
                            .padding(16)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            // 加载失败兜底摘要同样展示统计（内容可见即统计可见）
                            if !news.content.isEmpty {
                                ArticleReadingStatsText(cachedID: news.readKey, plainText: news.content)
                            }

                            Text(news.content)
                                .displayText(size: 16, baseLineSpacing: 6)
                                .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                            Button {
                                retryLoading()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("重新加载", systemImage: "arrow.clockwise")
                                        .displayLabelFont(14, weight: .medium)
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .opacity(contentAppear ? 1 : 0)
                        .offset(y: contentAppear ? 0 : 20)
                        .onAppear {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                contentAppear = true
                            }
                        }
                    } else {
                        // 正文内容
                        let content = fullDetail?.plainTextContent ?? fullDetail?.content ?? news.content
                        Text(content)
                            .displayFont(16).lineSpacing(10)
                            .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)
                            .opacity(contentAppear ? 1 : 0)
                            .offset(y: contentAppear ? 0 : 20)
                            .onAppear {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    contentAppear = true
                                }
                            }

                        // 图片画廊（确定型计数条 + 逐图进度 + 失败重试）
                        if let images = fullDetail?.images, !images.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Divider()
                                HStack(alignment: .center) {
                                    Label("新闻图片（\(images.count)张）", systemImage: "photo.on.rectangle")
                                        .displayLabelFont(14, weight: .semibold)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if showGalleryBar {
                                        SJZGalleryProgressBar(
                                            loaded: galleryLoadedIndices.count,
                                            total: images.count
                                        )
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                                            SJZCachedImage(url: URL(string: img.url), maxPixel: 480) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                case .failure:
                                                    ZStack {
                                                        Color.gray.opacity(0.08)
                                                        VStack(spacing: 4) {
                                                            Image(systemName: "arrow.clockwise")
                                                                .displaySymbolFont(12).foregroundStyle(.secondary)
                                                            Text("轻点重试")
                                                                .displayFont(9).foregroundStyle(.secondary)
                                                        }
                                                    }
                                                case .empty:
                                                    if let hex = SJZAverageColorCache.colorHex(for: URL(string: img.url)) {
                                                        Color(hex: hex).overlay {
                                                            ShimmerView().opacity(0.3)
                                                        }
                                                    } else {
                                                        ShimmerView()
                                                    }
                                                case .skipped:
                                                    // 无图模式：优雅静态占位（不起网络）
                                                    SJZImageFreePlaceholder()
                                                }
                                            }
                                            .onPhaseChange { newPhase in
                                                handleGalleryPhase(idx: idx, phase: newPhase)
                                            }
                                            .frame(width: 160, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .onTapGesture {
                                                imageViewerPayload = SJZImageGalleryPayload.make(
                                                    images: images, tappedIndex: idx, source: "grid")
                                                LogManager.shared.debugLog("imageViewer", "查看图片（图集网格）", context: [
                                                    "index": "\(idx + 1)/\(images.count)",
                                                    "url": img.url
                                                ])
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("资讯详情").navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            // E7 弱网提示（顶部滑入胶囊，3s 后自动消失）
            if let slowNetworkMessage {
                SJZSlowNetworkBanner(message: slowNetworkMessage)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: slowNetworkMessage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            bookmarkManager.toggleBookmark(news)
                        }
                    } label: {
                        Image(systemName: bookmarkManager.isBookmarked(news) ? "bookmark.fill" : "bookmark")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(bookmarkManager.isBookmarked(news) ? Color.sjzGold : .primary)
                    }
                    .contentShape(Rectangle())
                    Button {
                        showSharePicker = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(14, weight: .medium)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        // 顶部彩虹进度条：等待正文（不定型扫描）→ 正文就绪后图片画廊真实进度
        // 拆分为独立属性，降低超大视图表达式的类型检查复杂度
        .overlay(alignment: .top) { detailTopProgressBar }
        .confirmationDialog("选择分享格式", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享到微信") { showWeChatShare = true }
            Button("长图分享到微信") {
                longImageDestination = .weChat
                startLongImageGeneration()
            }
            Button("纯链接") { selectedShareFormat = .link }
            Button("Markdown文章") { selectedShareFormat = .markdown }
            Button("标题+正文文本") { selectedShareFormat = .fullText }
            Button("长图") {
                longImageDestination = .system
                startLongImageGeneration()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .sheet(item: $weChatLongImagePayload) { payload in
            WeChatLongImageShareMenu(payload: payload)
                .sjzPresentationChrome()
        }
        .sheet(item: $selectedShareFormat) { format in
            let articleURL = news.originalArticleURL
            let title = news.title
            let body = fullDetail?.plainTextContent ?? news.content
            ShareSheet(items: shareItemsForFormat(format, url: articleURL, title: title, body: body))
        }
        .sheet(isPresented: $showWebView) {
            NavigationStack {
                let articleURL = news.originalArticleURL
                WebViewContainer(urlString: articleURL)
                    .navigationTitle(news.articleId != nil ? "原文阅读" : "学校官网")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                showWebView = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .displaySymbolFont(16, weight: .medium)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                webViewShowShare = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .displaySymbolFont(14, weight: .medium)
                            }
                        }
                    }
            }
            .sjzPresentationChrome()
        }
        .sheet(isPresented: $webViewShowShare) {
            ShareSheet(items: [URL(string: news.originalArticleURL) as Any])
        }
        .fullScreenCover(item: $imageViewerPayload) { payload in
            FullScreenImageView(payload: payload, fallbackTitle: news.title)
                .sjzPresentationChrome()
        }
        .task {
            await loadDetail()
        }
        .onAppear {
            readManager.markAsRead(news)
        }
        .overlay {
            if isGeneratingLongImage {
                longImageLoadingOverlay
            }
        }
    }

    // MARK: - 长图生成加载遮罩

    private var longImageLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在生成文章长图...")
                    .displayFont(16, weight: .medium)
                    .foregroundStyle(.white)
                Text("下载图片并渲染中")
                    .displayFont(13)
                    .foregroundStyle(.white.opacity(0.7))
                if let error = longImageError {
                    VStack(spacing: 12) {
                        Text(error)
                            .displayFont(13)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("关闭") {
                            isGeneratingLongImage = false
                            longImageError = nil
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.white.opacity(0.2), in: Capsule())
                    }
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
    }

    /// 顶部彩虹进度指示：等待正文（不定型扫描）→ 图片画廊真实进度（完成自动打勾渐隐）
    @ViewBuilder
    private var detailTopProgressBar: some View {
        if isLoadingDetail {
            SJZPageLoadProgressBar(indeterminate: true)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if let images = fullDetail?.images, !images.isEmpty, showGalleryBar {
            SJZPageLoadProgressBar(
                percent: Double(galleryLoadedIndices.count) / Double(images.count),
                label: "\(galleryLoadedIndices.count)/\(images.count)"
            )
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func loadDetail() async {
        guard let articleId = news.articleId else {
            isLoadingDetail = false
            withAnimation(.easeOut(duration: 0.2)) { loadingPhase = .complete }
            LogManager.shared.info("ui", "文章详情无 articleId，跳过加载", context: ["title": news.title])
            return
        }
        if fullDetail != nil && cacheManager.isCacheEnabled {
            LogManager.shared.debugLog("ui", "缓存模式下文章详情已加载，跳过重复请求", context: [
                "articleId": articleId, "title": news.title
            ])
            return
        }
        let loadStart = Date()
        isLoadingDetail = true
        loadError = nil
        withAnimation(.easeOut(duration: 0.2)) { loadingPhase = .checkingCache }
        // E3 判定：请求前是否已有缓存
        let wasCached = DataService.shared.isArticleDetailCached(id: articleId)
        LogManager.shared.info("ui", "开始加载文章详情", context: [
            "articleId": articleId, "title": news.title,
            "fromCache": "\(wasCached)",
            "pipelineStart": String(format: "%.0fms", loadStart.timeIntervalSince(loadingStartTime) * 1000)
        ])
        do {
            let detail = try await DataService.shared.loadArticleFullDetail(articleId: articleId)
            let fetchElapsed = Date().timeIntervalSince(loadStart)
            LogManager.shared.info("ui", "文章详情获取成功，开始解析内容", context: [
                "articleId": articleId, "fetchMs": String(format: "%.0f", fetchElapsed * 1000)
            ])
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { loadingPhase = .parsingContent }
            }
            let parseStart = Date()
            let displayContent = detail.plainTextContent.isEmpty ? detail.content : detail.plainTextContent
            let parseElapsed = Date().timeIntervalSince(parseStart)
            await MainActor.run {
                fullDetail = detail
                withAnimation(.easeOut(duration: 0.2)) { loadingPhase = .rendering }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let totalElapsed = Date().timeIntervalSince(loadStart)
            let pipelineTotal = Date().timeIntervalSince(loadingStartTime)
            LogManager.shared.info("ui", "文章详情加载成功", context: [
                "articleId": articleId, "title": detail.title,
                "images": "\(detail.images.count)", "contentLength": "\(displayContent.count)",
                "fetchMs": String(format: "%.0f", fetchElapsed * 1000),
                "parseMs": String(format: "%.0f", parseElapsed * 1000),
                "totalMs": String(format: "%.0f", totalElapsed * 1000),
                "pipelineTotalMs": String(format: "%.0f", pipelineTotal * 1000)
            ])
            await MainActor.run {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    loadingPhase = .complete
                }
                isLoadingDetail = false
                elapsedLoadingTime = totalElapsed
                // E3 缓存徽标：数据来自缓存时展示，2.5s 后自动淡出
                if wasCached {
                    withAnimation(.easeIn(duration: 0.3)) { showCachedBadge = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation(.easeOut(duration: 0.4)) { showCachedBadge = false }
                    }
                }
                // E7 弱网提示：加载耗时过长时提示（内容已正常显示）
                if totalElapsed > 8 && wasCached == false {
                    slowNetworkMessage = "网络较慢，文章已加载完成"
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation(.easeOut(duration: 0.3)) { slowNetworkMessage = nil }
                    }
                }
                LogManager.shared.info("ui", "文章详情分段加载完成", context: [
                    "articleId": articleId,
                    "fromCache": "\(wasCached)",
                    "pipelineMs": String(format: "%.0f", pipelineTotal * 1000),
                    "showProgress": "\(showLoadingProgress)"
                ])
            }
            // E1：预取画廊前 3 张图片（并发≤4，命中即跳过）
            if !detail.images.isEmpty {
                let urls = detail.images.prefix(3).compactMap { URL(string: $0.url) }
                Task { await SJZImagePrefetcher.prefetch(urls: urls) }
            }
            // E6：并行预取下一篇待读文章详情
            if let nextArticleId {
                DataService.shared.preloadArticleDetail(articleId: nextArticleId)
            }
        } catch {
            let failElapsed = Date().timeIntervalSince(loadStart)
            loadError = "文章详情加载失败，请检查网络连接后重试"
            withAnimation(.easeOut(duration: 0.2)) { loadingPhase = .failed }
            LogManager.shared.error("ui", "文章详情加载失败", context: [
                "articleId": articleId, "title": news.title,
                "error": error.localizedDescription,
                "failAfterMs": String(format: "%.0f", failElapsed * 1000)
            ])
            // E7 弱网提示：失败回退摘要时给出指引
            withAnimation(.easeIn(duration: 0.3)) {
                slowNetworkMessage = "网络较慢，已为你显示文章摘要"
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) { slowNetworkMessage = nil }
            }
            await MainActor.run {
                isLoadingDetail = false
                elapsedLoadingTime = failElapsed
            }
        }
    }

    private func retryLoading() {
        Task {
            await loadDetail()
        }
    }

    /// 画廊计数联动（E1/F3）：成功计数+1；全部完成记日志并 1s 后渐隐进度条
    private func handleGalleryPhase(idx: Int, phase: SJZImagePhase) {
        switch phase {
        case .success:
            galleryLoadedIndices.insert(idx)
            if !showGalleryBar {
                withAnimation(.easeIn(duration: 0.2)) { showGalleryBar = true }
            }
            if let images = fullDetail?.images, galleryLoadedIndices.count >= images.count {
                LogManager.shared.info("ui", "资讯画廊图片全部加载完成", context: [
                    "articleId": news.articleId ?? "nil",
                    "total": "\(images.count)"
                ])
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    withAnimation(.easeOut(duration: 0.3)) { showGalleryBar = false }
                }
            }
        case .empty:
            if !showGalleryBar {
                withAnimation(.easeIn(duration: 0.2)) { showGalleryBar = true }
            }
        case .failure:
            break
        case .skipped:
            // 无图模式：不推进画廊计数条（占位渲染由图片组件负责）
            break
        }
    }

    // MARK: - 分享内容生成

    /// 微信分享载荷（标题 + 正文摘要 + 链接 + 缩略图；微信限制由 WeChatService 统一裁剪）
    private var weChatSharePayload: WeChatSharePayload {
        WeChatSharePayload(
            title: news.title,
            description: fullDetail?.plainTextContent ?? news.content,
            urlString: news.originalArticleURL,
            thumbImageURL: news.imageUrl
        )
    }

    /// 根据分享格式生成对应的分享内容数组
    /// - 纯链接：仅分享文章 URL，微信可直接识别为链接卡片
    /// - Markdown文章：生成完整 Markdown 格式文章（标题、元数据、正文、图片、原文链接）
    /// - 标题+正文文本：分享标题、正文摘要和 URL 的组合文本
    private func shareItemsForFormat(_ format: ShareFormat, url: String, title: String, body: String) -> [Any] {
        switch format {
        case .link:
            return [URL(string: url) as Any]
        case .markdown:
            let markdown = generateMarkdownContent(url: url, title: title, body: body)
            // 只分享 Markdown 纯文本，URL 已嵌入在 Markdown 内容末尾
            return [markdown]
        case .fullText:
            let summary = body.count > 200 ? String(body.prefix(200)) + "..." : body
            return ["\(title)\n\n\(summary)\n\n阅读原文：\(url)"]
        case .longImage:
            return []  // 长图通过单独流程处理
        }
    }

    // MARK: - Markdown 文章生成

    /// 生成完整 Markdown 格式文章
    private func generateMarkdownContent(url: String, title: String, body: String) -> String {
        var md = "# \(title)\n\n"

        // 元数据
        var metaParts: [String] = []
        metaParts.append("分类：\(news.category)")
        metaParts.append("日期：\(news.date)")
        if let author = fullDetail?.author, !author.isEmpty {
            metaParts.append("作者：\(author)")
        }
        if let source = fullDetail?.source, !source.isEmpty {
            metaParts.append("来源：\(source)")
        }
        md += "> \(metaParts.joined(separator: " | "))\n\n"

        md += "---\n\n"

        // 正文内容
        let paragraphs = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for para in paragraphs {
            md += "\(para)\n\n"
        }

        // 图片引用
        if let images = fullDetail?.images, !images.isEmpty {
            md += "---\n\n"
            md += "### 文章图片\n\n"
            for (i, img) in images.enumerated() {
                let alt = img.alt ?? "图片\(i + 1)"
                md += "![\(alt)](\(img.url))\n\n"
            }
        }

        md += "---\n\n"
        md += "> 原文链接：[查看原文](\(url))\n"
        md += "> 由山西晋中理工学院 APP 分享\n"

        return md
    }

    // MARK: - 长图生成

    /// 启动长图生成流程
    private func startLongImageGeneration() {
        isGeneratingLongImage = true
        longImageError = nil

        Task {
            await generateLongImage()
        }
    }

    /// 异步下载文章图片并生成长图，完成后直接 present 系统分享面板
    private func generateLongImage() async {
        let articleURL = news.originalArticleURL
        let title = news.title
        let body = fullDetail?.plainTextContent ?? news.content

        // 构建元数据字符串
        var metaParts: [String] = []
        if !news.category.isEmpty { metaParts.append(news.category) }
        if !news.date.isEmpty { metaParts.append(news.date) }
        if let author = fullDetail?.author, !author.isEmpty { metaParts.append("作者：\(author)") }
        if let source = fullDetail?.source, !source.isEmpty { metaParts.append("来源：\(source)") }
        let metadata = metaParts.joined(separator: " · ")

        // 加载长图素材（压缩数据 + 尺寸元数据；渲染时按需缩略解码——多图文章的内存防线）
        let imageAssets = await ArticleLongImageLoader.loadAll(fullDetail?.images ?? [], tag: "news_detail")

        // 渲染长图
        let renderer = ArticleLongImageRenderer(
            title: title,
            metadata: metadata,
            content: body,
            images: imageAssets,
            articleURL: articleURL,
            tag: "news_detail"
        )

        await MainActor.run {
            // 长图渲染日志（含配色联动状态，便于定位输出差异）
            LogManager.shared.debugLog("longimage", "开始生成文章长图", context: [
                "textPreset": displaySettings.articleTextColorPreset.rawValue,
                "lightHex": DisplaySettingsManager.articleBodyLightHexSnapshot().hex
            ])
            let renderedImage = renderer.render()

            guard let renderedImage else {
                // 保持 isGeneratingLongImage = true，让 overlay 显示错误信息
                longImageError = "长图生成失败，请重试"
                return
            }

            isGeneratingLongImage = false

            // 关键修复：等 confirmationDialog 关闭动画完成（约 0.35s）后再 present 分享面板
            // 否则 SwiftUI 视图层级处于过渡状态，导致 UIActivityViewController 静默失败
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                switch longImageDestination {
                case .system:
                    presentLongImageShare(image: renderedImage, title: title)
                case .weChat:
                    // 微信图片消息（WXImageObject）：弹出场景菜单（好友 / 朋友圈 / 收藏）
                    weChatLongImagePayload = WeChatLongImagePayload(image: renderedImage, title: title, entry: "news_detail")
                }
            }
        }
    }

    /// 直接以 UIKit 模态方式呈现 UIActivityViewController，
    /// 绕过 SwiftUI sheet 的嵌套问题，确保微信 Share Extension 能正确接收图片数据
    private func presentLongImageShare(image: UIImage, title: String) {
        // 使用 JPEG 压缩（质量 0.92），文件大小可控，微信兼容性最好
        // 交付前兜底校验：纯色 / 黑图绝不落盘分享（渲染层已校验；此处防编码链路异常）
        guard !SJZImageIntegrity.isLikelyBlank(image) else {
            longImageError = "长图生成异常（画布纯色），请重试"
            isGeneratingLongImage = true
            LogManager.shared.error("longimage", "长图交付校验拦截（画布纯色）", context: [
                "title": title,
                "pixel": SJZImageIntegrity.pixelSizeText(of: image)
            ])
            return
        }
        // 交付编码：分享扩展（微信等）内存与体积预算有限（约 120MB）——按「≤16MP / ≤10MB」编码，
        // 否则扩展会被系统终止（2026-09-28 现场：微信「加载中 → 闪回 App」）；产物含纯色 / 黑图校验
        guard let encoded = WeChatImageEncoder.encode(
            image,
            maxBytes: WeChatImageEncoder.systemShareMaxBytes,
            maxPixels: WeChatImageEncoder.systemShareMaxPixels
        ) else {
            longImageError = "图片编码失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图 JPEG 编码失败", context: ["title": title])
            return
        }
        let jpegData = encoded.data
        LogManager.shared.info("longimage", "长图分享文件编码完成", context: [
            "title": title,
            "pixel": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
            "quality": String(format: "%.2f", encoded.quality),
            "scale": String(format: "%.2f", encoded.scale),
            "bytes": "\(encoded.data.count)"
        ])

        // 安全文件名：截取标题前20字符，替换非法字符
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(20)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sxjzit_\(safeTitle)_\(UUID().uuidString.prefix(6)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: fileURL)
        } catch {
            longImageError = "图片保存失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图临时文件写入失败", context: ["title": title])
            return
        }

        LogManager.shared.debugLog("longimage", "长图文件已保存", context: ["file": fileURL.lastPathComponent, "sizeKB": "\(jpegData.count / 1024)"])

        // 找到最顶层的 ViewController 来呈现分享面板
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            longImageError = "无法获取窗口"
            isGeneratingLongImage = true
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // 关键：仅传递文件 URL 和标题文本，不传递 UIImage 对象
        // 微信 Share Extension 通过文件 URL 读取图片，内存中的 UIImage 无法被微信识别
        let activityItems: [Any] = [fileURL, title]

        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]

        // 分享完成或取消后清理临时文件
        activityVC.completionWithItemsHandler = { [fileURL] _, completed, _, error in
            // 分享扩展（微信等）读取大图较慢，且本回调在「用户选择动作」时即触发——
            // 绝不能立即删除（现场：微信「加载中 → 闪回 App」）；交由共享中心延迟 5 分钟清理
            SJZShareFileCenter.scheduleCleanup(fileURL)
            if !completed {
                // 分享未完成（系统扩展可能因体积 / 尺寸限制中止）：记录可判别数据 + 给出可操作替代路径
                WeChatService.shared.showBanner("微信未完成分享，可改用「分享 → 长图分享到微信」", kind: .info)
                LogManager.shared.warning("longimage", "长图分享未完成（系统扩展可能中止）", context: [
                    "pixel": SJZImageIntegrity.pixelSizeText(of: image),
                    "bytes": "\(jpegData.count)",
                    "error": error?.localizedDescription ?? "none"
                ])
            }
            if let error = error {
                LogManager.shared.error("longimage", "长图分享失败", context: ["error": error.localizedDescription])
            }
            LogManager.shared.info("longimage", "长图分享完成", context: ["completed": "\(completed)"])
        }

        topVC.present(activityVC, animated: true) {
            LogManager.shared.debugLog("longimage", "长图分享面板已呈现")
        }
    }

    private var detailHeaderPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzPrimary, Color.sjzAccent],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(height: 240)
        .overlay {
            Image(systemName: "newspaper.fill")
                .displaySymbolFont(60).foregroundStyle(.white.opacity(0.08))
        }
    }

    // MARK: - 骨架屏辅助属性
}

// MARK: - 文章内容骨架屏

private struct ArticleSkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            skeletonBar(widthMultiplier: 1.0, height: 14)
            skeletonBar(widthMultiplier: 0.92, height: 14)
            skeletonBar(widthMultiplier: 0.97, height: 14)
            skeletonBar(widthMultiplier: 0.45, height: 14)
            skeletonBar(widthMultiplier: 0.0, height: 10)
            skeletonBar(widthMultiplier: 0.88, height: 14)
            skeletonBar(widthMultiplier: 0.95, height: 14)
            skeletonBar(widthMultiplier: 0.72, height: 14)
            skeletonBar(widthMultiplier: 0.0, height: 10)
            skeletonBar(widthMultiplier: 0.91, height: 14)
            skeletonBar(widthMultiplier: 0.84, height: 14)
            skeletonBar(widthMultiplier: 0.96, height: 14)
            skeletonBar(widthMultiplier: 0.38, height: 14)
        }
    }

    private func skeletonBar(widthMultiplier: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            if widthMultiplier > 0 {
                ShimmerView()
                    .frame(width: geo.size.width * widthMultiplier, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Color.clear.frame(height: height)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 分段加载进度指示器

private struct PhasedProgressIndicator: View {
    let phase: LoadingPhase
    let elapsedTime: TimeInterval
    let startTime: Date
    let error: String?
    let onRetry: () -> Void

    @State private var appear = false
    @State private var elapsedDisplay: TimeInterval = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 当前阶段指示
            HStack(spacing: 10) {
                Image(systemName: phase.iconName)
                    .displaySymbolFont(14, weight: .semibold)
                    .foregroundStyle(phase.color)
                    .symbolEffect(.bounce, options: .repeating, value: phase == .fetchingNetwork || phase == .parsingContent)

                Text(phase.description)
                    .displayFont(14, weight: .semibold)
                    .foregroundStyle(phase.color)

                Spacer()

                // 计时器
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch")
                        .displaySymbolFont(10)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1fs", elapsedDisplay))
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // 阶段进度条
            if phase != .complete && phase != .failed {
                PhaseProgressDots(currentPhase: phase, totalPhases: 5)
                    .frame(maxWidth: .infinity)
            }

            // 快速加载提示（缓存命中时）
            if phase == .complete && elapsedTime < 0.5 {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .displaySymbolFont(10)
                        .foregroundStyle(.green)
                    Text("缓存秒开 · \(String(format: "%.0f", elapsedTime * 1000))ms")
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08), in: Capsule())
            }

            if phase == .complete && elapsedTime >= 0.5 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(10)
                        .foregroundStyle(.green)
                    Text("加载完成 · \(String(format: "%.1f", elapsedTime))s")
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08), in: Capsule())
            }

            if phase == .failed, let error = error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .displaySymbolFont(10)
                        .foregroundStyle(.red)
                    Text(error)
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .displaySymbolFont(10)
                        Text("重新加载")
                            .displayFont(12, weight: .medium)
                    }
                    .foregroundStyle(Color.sjzAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.sjzAccent.opacity(0.08), in: Capsule())
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(phase.color.opacity(0.15), lineWidth: 1)
        )
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 8)
        .onAppear {
            elapsedDisplay = elapsedTime > 0 ? elapsedTime : Date().timeIntervalSince(startTime)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appear = true
            }
        }
        .onReceive(timer) { _ in
            if phase != .complete && phase != .failed {
                elapsedDisplay = Date().timeIntervalSince(startTime)
            } else {
                elapsedDisplay = elapsedTime
            }
        }
    }
}

// MARK: - 阶段进度圆点

private struct PhaseProgressDots: View {
    let currentPhase: LoadingPhase
    let totalPhases: Int

    private var currentPhaseIndex: Int {
        switch currentPhase {
        case .initializing: return 0
        case .checkingCache: return 1
        case .fetchingNetwork: return 2
        case .parsingContent: return 3
        case .rendering: return 4
        case .complete, .failed: return totalPhases
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalPhases, id: \.self) { index in
                Circle()
                    .fill(index <= currentPhaseIndex ? currentPhase.color : Color.secondary.opacity(0.2))
                    .frame(width: 6, height: 6)
                    .scaleEffect(index == currentPhaseIndex && currentPhase != .complete ? 1.3 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: currentPhaseIndex)
            }
        }
    }
}

// MARK: - 全屏图片查看

/// 看图载荷（item 式呈现载体，2026-09-29）：根治「先显示第一张」的陈旧快照，
/// 同时承载整组图片以支持左右翻页；`source` 供日志归因（grid / header / single）。
struct SJZImageGalleryPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let alts: [String]
    let startIndex: Int
    let source: String

    var count: Int { urls.count }
    /// 落点索引（越界防护）
    var clampedStartIndex: Int { min(max(startIndex, 0), max(count - 1, 0)) }

    /// 单图载荷（头图 / 既有单图调用点）
    static func single(url: URL, source: String = "single") -> SJZImageGalleryPayload {
        SJZImageGalleryPayload(urls: [url], alts: [""], startIndex: 0, source: source)
    }

    /// 从文章图集构建：跳过非法 URL，并把「被点击项」映射到过滤后的落点索引
    nonisolated static func make(images: [DataService.ArticleImage],
                                 tappedIndex: Int,
                                 source: String) -> SJZImageGalleryPayload? {
        var urls: [URL] = []
        var alts: [String] = []
        var resolvedStart = 0
        for (index, image) in images.enumerated() {
            guard let url = URL(string: image.url) else { continue }
            if index == tappedIndex { resolvedStart = urls.count }
            urls.append(url)
            alts.append(image.alt ?? "")
        }
        guard !urls.isEmpty else { return nil }
        return SJZImageGalleryPayload(urls: urls, alts: alts,
                                      startIndex: resolvedStart, source: source)
    }
}

/// 翻页判定结果（纯函数输出，供手势与单元测试共用）
enum SJZPageTurn: Equatable {
    case next
    case previous
    case none
}

/// 全屏看图几何（纯函数，手势与单元测试共用；2026-09-29 「放大后滑动变黑」修复）
enum SJZImageViewerGeometry {
    /// 适配显示尺寸（与 `.scaledToFit()` 同口径：等比缩放至完整放入容器）
    nonisolated static func fittedSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let ratio = Swift.min(containerSize.width / imageSize.width,
                              containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    /// 可平移范围（内容溢出容器部分的一半；该轴未溢出则为 0——与照片 App 一致，不可平移）
    nonisolated static func maxOffset(displaySize: CGSize, scale: CGFloat, containerSize: CGSize) -> CGSize {
        CGSize(width: Swift.max(0, (displaySize.width * scale - containerSize.width) / 2),
               height: Swift.max(0, (displaySize.height * scale - containerSize.height) / 2))
    }

    /// 边界夹紧（无橡皮筋；松手回弹的落点）
    nonisolated static func clamped(_ offset: CGSize, maxOffset: CGSize) -> CGSize {
        CGSize(width: Swift.min(Swift.max(offset.width, -maxOffset.width), maxOffset.width),
               height: Swift.min(Swift.max(offset.height, -maxOffset.height), maxOffset.height))
    }

    /// 橡皮筋阻尼：越界部分按 damping 压缩（松手后回弹；拖动中手感“有阻力但不失控”）
    nonisolated static func rubberBanded(_ offset: CGSize, maxOffset: CGSize, damping: CGFloat = 0.35) -> CGSize {
        CGSize(width: rubberBandAxis(offset.width, limit: maxOffset.width, damping: damping),
               height: rubberBandAxis(offset.height, limit: maxOffset.height, damping: damping))
    }

    nonisolated static func rubberBandAxis(_ value: CGFloat, limit: CGFloat, damping: CGFloat) -> CGFloat {
        if value > limit { return limit + (value - limit) * damping }
        if value < -limit { return -limit + (value + limit) * damping }
        return value
    }

    /// 锚点缩放位移换算：保持锚点下内容不动
    /// （offset' = a − (a − offset)·k；a = 锚点相对容器中心，k = 新/旧倍率）
    nonisolated static func anchoredOffset(anchor: CGPoint, containerSize: CGSize,
                                           offset: CGSize, oldScale: CGFloat, newScale: CGFloat) -> CGSize {
        guard oldScale > 0, containerSize.width > 0, containerSize.height > 0 else { return offset }
        let a = CGPoint(x: anchor.x - containerSize.width / 2, y: anchor.y - containerSize.height / 2)
        let k = newScale / oldScale
        return CGSize(width: a.x - (a.x - offset.width) * k,
                      height: a.y - (a.y - offset.height) * k)
    }

    /// 倍率夹紧（1x ~ 5x）
    nonisolated static func clampedScale(_ raw: CGFloat, lowerBound: CGFloat = 1, upperBound: CGFloat = 5) -> CGFloat {
        Swift.min(Swift.max(raw, lowerBound), upperBound)
    }

    /// 翻页判定（1x 横向拖动）：位移占比 ≥18% 或甩动速度 ≥300pt/s 触发；首/末页方向自动失效
    nonisolated static func pageTurnDecision(translation: CGFloat, velocity: CGFloat,
                                             containerWidth: CGFloat,
                                             canNext: Bool, canPrevious: Bool) -> SJZPageTurn {
        guard containerWidth > 0 else { return .none }
        let distanceThreshold = containerWidth * 0.18
        let decided: SJZPageTurn
        if abs(translation) >= distanceThreshold {
            decided = translation < 0 ? .next : .previous
        } else if abs(velocity) >= 300 {
            decided = velocity < 0 ? .next : .previous
        } else {
            decided = .none
        }
        switch decided {
        case .next: return canNext ? .next : .none
        case .previous: return canPrevious ? .previous : .none
        case .none: return .none
        }
    }

    /// 翻页跟手位移：首/末页越界方向阻尼 0.35（有阻力不失控），可翻方向 1:1 跟手
    nonisolated static func dampedPageOffset(_ dx: CGFloat, canNext: Bool, canPrevious: Bool,
                                             damping: CGFloat = 0.35) -> CGFloat {
        if dx < 0 && !canNext { return dx * damping }
        if dx > 0 && !canPrevious { return dx * damping }
        return dx
    }
}

struct FullScreenImageView: View {
    /// 看图载荷（URL 组 + 落点 + 归因；单图 = count 1）
    private let payload: SJZImageGalleryPayload
    /// 内容标题（导航标题；图片无 alt 时的兜底）
    private let fallbackTitle: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: 翻页状态（多图集启用；count == 1 时全程不参与手势）

    /// 当前页索引（由载荷落点初始化，杜绝「先显示第一张」）
    @State private var pageIndex: Int
    /// 1x 横向跟手位移（翻页预览）
    @State private var pageDragOffset: CGFloat = 0
    /// 切页动画进行中（挡输入，防连翻）
    @State private var isTurningPage = false

    // MARK: 缩放/平移状态（2026-09-29 重写：绝对位移法——offset = 基底 + 累计位移，根除反复累加）

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    /// 拖动基底（手势开始瞬间的 offset）
    @State private var dragBaseOffset: CGSize = .zero
    /// 捏合基底倍率（手势开始瞬间的 scale；scale = 基底 × magnification）
    @State private var magnifyBaseScale: CGFloat = 1.0
    /// 手势进行中标志（起点捕捉与单击防误触）
    @State private var isDragging = false
    @State private var isMagnifying = false
    /// 容器尺寸（边界夹紧与锚点换算依据；onGeometryChange 测量）
    @State private var containerSize: CGSize = .zero
    /// 缩放倍率 HUD（捏合/双击时淡入，停手后自动淡出）
    @State private var showZoomHUD = false
    @State private var zoomHUDTask: Task<Void, Never>?
    /// 打开时刻（关闭日志的停留时长）
    @State private var openedAt = Date()

    /// 单图入口（19 处既有调用点零改动）
    init(url: URL, title: String) {
        let single = SJZImageGalleryPayload.single(url: url)
        self.payload = single
        self.fallbackTitle = title
        _pageIndex = State(initialValue: single.clampedStartIndex)
    }

    /// 载荷入口（文章图集：item 式呈现 + 左右翻页）
    init(payload: SJZImageGalleryPayload, fallbackTitle: String) {
        self.payload = payload
        self.fallbackTitle = fallbackTitle
        _pageIndex = State(initialValue: payload.clampedStartIndex)
    }

    // MARK: 当前页派生（含越界防护）

    private var clampedPageIndex: Int { min(max(pageIndex, 0), max(payload.count - 1, 0)) }
    private var currentURL: URL { payload.urls[clampedPageIndex] }
    private var currentTitle: String {
        let alt = payload.alts[clampedPageIndex]
        return alt.isEmpty ? fallbackTitle : alt
    }
    private var canTurnPrevious: Bool { clampedPageIndex > 0 }
    private var canTurnNext: Bool { clampedPageIndex < payload.count - 1 }
    private var pageText: String { "\(clampedPageIndex + 1) / \(payload.count)" }

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadError: String?
    /// 下载进度 0-1（nil 表示长度未知，退化为转圈）
    @State private var downloadProgress: Double?
    /// 是否来自缓存（命中则速显淡入）
    @State private var isFromCache = false

    /// 倍率范围与双击目标
    private let minZoomScale: CGFloat = 1.0
    private let maxZoomScale: CGFloat = 5.0
    private let doubleTapZoomScale: CGFloat = 2.5

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = loadedImage {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .offset(x: offset.width + pageDragOffset, y: offset.height)
                        .accessibilityLabel("图片预览：\(currentTitle)")
                        .accessibilityValue(Self.zoomText(scale))
                        .accessibilityAdjustableAction { direction in
                            handleAccessibilityZoom(direction)
                        }
                } else if let error = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .displaySymbolFont(48).foregroundStyle(.white.opacity(0.4))
                        Text("图片加载失败").displayFont(12).foregroundStyle(.white.opacity(0.5))
                        Text(error).displayFont(11).foregroundStyle(.white.opacity(0.3))
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                } else if isLoading {
                    VStack(spacing: 14) {
                        if let progress = downloadProgress {
                            // 确定型进度：渐变光环 + 微光（现代视觉，白色核心保证黑底对比度）
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 4)
                                    .frame(width: 52, height: 52)
                                Circle()
                                    .trim(from: 0, to: progress)
                                    .stroke(
                                        AngularGradient(
                                            colors: [.white, Color.sjzSkyBlue, .white],
                                            center: .center
                                        ),
                                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                    )
                                    .frame(width: 52, height: 52)
                                    .rotationEffect(.degrees(-90))
                                    .shadow(color: Color.sjzSkyBlue.opacity(0.6), radius: 6)
                                Text("\(Int(progress * 100))%")
                                    .displayFont(13, weight: .semibold, design: .rounded)
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                            }
                            .animation(.smooth(duration: 0.3), value: progress)
                            Text("下载中 \(Int(progress * 100))%")
                                .displayFont(12)
                                .foregroundStyle(.white.opacity(0.8))
                                .contentTransition(.numericText())
                        } else {
                            ProgressView().tint(.white).scaleEffect(1.5)
                        }
                    }
                }

                if showZoomHUD {
                    // 倍率 HUD 居顶（与底部页码指示互不遮挡）
                    VStack {
                        zoomHUD
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if payload.count > 1 {
                    pageIndicator
                }
            }
            // 容器测量（iOS 18+ onGeometryChange）：边界夹紧与锚点换算依据；尺寸变化后重新夹紧防越界
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                guard newSize.width > 0, newSize != containerSize else { return }
                let wasMeasured = containerSize.width > 0
                containerSize = newSize
                if wasMeasured { reclampOffset(animated: true, reason: "容器尺寸变化") }
            }
            .contentShape(Rectangle())
            .gesture(viewerGesture)
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                handleDoubleTap(at: location)
            }
            .onTapGesture(count: 1) {
                handleSingleTap()
            }
            .accessibilityAction(named: "下一张") { turnPage(1, trigger: "accessibility") }
            .accessibilityAction(named: "上一张") { turnPage(-1, trigger: "accessibility") }
            .navigationTitle(currentTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .displayFont(17)
                        .foregroundStyle(.white)
                }
            }
        }
        .task(id: currentURL) {
            // URL 变化（翻页 / 防御性变更）→ 复位缩放并重载；根治「传错图仍停在屏上」
            resetZoomForNewPage()
            await loadImage(for: currentURL)
        }
        .onAppear {
            openedAt = Date()
            LogManager.shared.info("imageViewer", "全屏图打开", context: [
                "url": currentURL.lastPathComponent,
                "title": currentTitle,
                "page": pageText,
                "source": payload.source
            ])
        }
        .onDisappear {
            zoomHUDTask?.cancel()
            LogManager.shared.info("imageViewer", "全屏图关闭", context: [
                "url": currentURL.lastPathComponent,
                "stayMs": String(format: "%.0f", Date().timeIntervalSince(openedAt) * 1000),
                "finalScale": Self.zoomText(scale),
                "page": pageText,
                "source": payload.source,
                "fromCache": "\(isFromCache)"
            ])
        }
    }

    // MARK: 手势（2026-09-29 重写：锚点缩放 + 绝对位移平移 + 边界橡皮筋/回弹）

    /// 合成手势：捏合（锚点缩放、实时夹紧）+ 拖动（绝对位移、橡皮筋阻尼）
    private var viewerGesture: some Gesture {
        let magnify = MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard containerSize.width > 0 else { return }
                if !isMagnifying {
                    isMagnifying = true
                    magnifyBaseScale = scale
                    presentZoomHUD()
                    LogManager.shared.debugLog("imageViewer", "缩放开始", context: [
                        "baseScale": Self.zoomText(scale),
                        "anchorX": String(format: "%.0f", value.startLocation.x),
                        "anchorY": String(format: "%.0f", value.startLocation.y)
                    ])
                }
                let target = SJZImageViewerGeometry.clampedScale(
                    magnifyBaseScale * value.magnification,
                    lowerBound: minZoomScale, upperBound: maxZoomScale)
                let proposed = SJZImageViewerGeometry.anchoredOffset(
                    anchor: value.startLocation, containerSize: containerSize,
                    offset: offset, oldScale: scale, newScale: target)
                scale = target
                offset = SJZImageViewerGeometry.clamped(proposed, maxOffset: maxOffset(for: target))
            }
            .onEnded { _ in
                isMagnifying = false
                finishZoomGesture()
            }

        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                // 捏合进行中不响应拖动（避免双指手势争抢位移导致抖动）
                guard !isMagnifying else { return }
                let horizontalDominant = abs(value.translation.width) > abs(value.translation.height)
                if scale > minZoomScale + 0.001 {
                    // 放大态：平移（绝对位移法；translation 本身即累计值，严禁逐帧累加）
                    if !isDragging {
                        isDragging = true
                        dragBaseOffset = offset
                    }
                    let raw = CGSize(width: dragBaseOffset.width + value.translation.width,
                                     height: dragBaseOffset.height + value.translation.height)
                    offset = SJZImageViewerGeometry.rubberBanded(raw, maxOffset: maxOffset(for: scale))
                    return
                }
                // 1x：横向跟手翻页预览（多图集；首/末页越界方向阻尼）
                guard payload.count > 1, !isTurningPage, horizontalDominant else { return }
                isDragging = true
                pageDragOffset = SJZImageViewerGeometry.dampedPageOffset(
                    value.translation.width, canNext: canTurnNext, canPrevious: canTurnPrevious)
            }
            .onEnded { value in
                let wasDragging = isDragging
                isDragging = false
                guard wasDragging else { return }
                if scale > minZoomScale + 0.001 {
                    settlePanDrag()
                } else if payload.count > 1 {
                    finishPageDrag(translation: value.translation.width, velocity: value.velocity.width)
                }
            }

        return magnify.simultaneously(with: drag)
    }

    /// 平移落定：夹紧回边界 + 越界弹簧回弹 + 状态日志（放大态专用）
    private func settlePanDrag() {
        let limit = maxOffset(for: scale)
        let settled = SJZImageViewerGeometry.clamped(offset, maxOffset: limit)
        let overshoot = hypot(offset.width - settled.width, offset.height - settled.height)
        let snappedBack = overshoot > 0.5
        if snappedBack {
            withAnimation(reduceMotion ? nil : Animation.spring(response: 0.4, dampingFraction: 0.78)) {
                offset = settled
            }
        }
        // 状态流转：拖动结束 / 越界回弹（边界夹紧后落点永远可见，杜绝「滑出屏幕只剩黑底」）
        LogManager.shared.debugLog("imageViewer", snappedBack ? "拖动越界回弹" : "拖动结束", context: [
            "scale": Self.zoomText(scale),
            "offsetX": String(format: "%.0f", settled.width),
            "offsetY": String(format: "%.0f", settled.height),
            "limitX": String(format: "%.0f", limit.width),
            "limitY": String(format: "%.0f", limit.height),
            "overshoot": String(format: "%.0f", overshoot)
        ])
    }

    // MARK: 翻页（多图集；1x 横滑跟手 → 过阈值切页 / 未过阈值弹回）

    /// 翻页落定：判定切页或弹回（判定逻辑为纯函数，见 SJZImageViewerGeometry.pageTurnDecision）
    private func finishPageDrag(translation: CGFloat, velocity: CGFloat) {
        let decision = SJZImageViewerGeometry.pageTurnDecision(
            translation: translation, velocity: velocity,
            containerWidth: containerSize.width,
            canNext: canTurnNext, canPrevious: canTurnPrevious)
        switch decision {
        case .next:
            turnPage(1, trigger: "drag")
        case .previous:
            turnPage(-1, trigger: "drag")
        case .none:
            guard pageDragOffset != 0 else { return }
            withAnimation(reduceMotion ? nil : Animation.spring(response: 0.32, dampingFraction: 0.86)) {
                pageDragOffset = 0
            }
            LogManager.shared.debugLog("imageViewer", "翻页回弹未达阈值", context: [
                "dx": String(format: "%.0f", translation),
                "threshold": String(format: "%.0f", containerSize.width * 0.18)
            ])
        }
    }

    /// 执行翻页（+1 下一张 / -1 上一张）：跟手方向滑出 → 换页重载 → 反向滑入；含触觉、日志、相邻页预取
    private func turnPage(_ delta: Int, trigger: String) {
        guard !isTurningPage, payload.count > 1 else { return }
        let target = clampedPageIndex + delta
        guard payload.urls.indices.contains(target) else { return }
        isTurningPage = true
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        let width = max(containerSize.width, 1)
        let outOffset = delta > 0 ? -width : width
        // 第一段：当前页按手势方向滑出（跟手衔接，无跳变）
        withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.16)) {
            pageDragOffset = outOffset
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 1_000_000 : 170_000_000)
            pageIndex = target
            // 第二段：新页自反方向滑入（.task(id:) 已接管重载与缩放复位）
            pageDragOffset = -outOffset
            withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.2)) {
                pageDragOffset = 0
            }
            LogManager.shared.info("imageViewer", "翻页", context: [
                "page": "\(target + 1)/\(payload.count)",
                "direction": delta > 0 ? "next" : "previous",
                "trigger": trigger,
                "source": payload.source
            ])
            prefetchAdjacentPages()
            try? await Task.sleep(nanoseconds: reduceMotion ? 1_000_000 : 210_000_000)
            isTurningPage = false
        }
    }

    /// 切页后复位缩放/位移（新页从 1x 开始；不动 pageDragOffset，避免打断滑入动画）
    private func resetZoomForNewPage() {
        scale = minZoomScale
        offset = .zero
        dragBaseOffset = .zero
        magnifyBaseScale = minZoomScale
    }

    /// 预取相邻页（±1；命中即跳过，经全局并发闸，静默失败）
    private func prefetchAdjacentPages() {
        guard payload.count > 1 else { return }
        for index in [clampedPageIndex - 1, clampedPageIndex + 1] where payload.urls.indices.contains(index) {
            let target = payload.urls[index]
            Task { await prefetchImage(target) }
        }
    }

    private func prefetchImage(_ target: URL) async {
        let key = SJZDecodedImageCache.key(url: target, maxPixel: nil)
        if SJZDecodedImageCache.shared.image(forKey: key) != nil { return }
        if let cached = SJZImageKit.usableCachedResponse(for: SJZImageKit.makeRequest(url: target)),
           let image = UIImage(data: cached.data) {
            SJZDecodedImageCache.shared.store(image, forKey: key)
            return
        }
        await SJZImageConcurrencyGate.shared.acquire()
        defer { Task { await SJZImageConcurrencyGate.shared.release() } }
        guard let (data, _) = try? await SJZImageKit.imageSession.data(for: SJZImageKit.makeRequest(url: target)),
              let image = UIImage(data: data) else { return }
        SJZDecodedImageCache.shared.store(image, forKey: key)
        if SJZImageKit.shouldLogHit("viewer.prefetch:\(target.absoluteString)") {
            LogManager.shared.debugLog("imageViewer", "相邻页预取完成", context: [
                "url": target.lastPathComponent
            ])
        }
    }

    /// 页码指示（多图集常显；玻璃胶囊 + 数值过渡）
    private var pageIndicator: some View {
        VStack {
            Spacer()
            Text(pageText)
                .displayFont(12, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .padding(.bottom, 26)
                .accessibilityLabel("第 \(clampedPageIndex + 1) 张，共 \(payload.count) 张")
        }
        .allowsHitTesting(false)
    }

    /// 当前倍率下的可平移范围（内容溢出容器部分的一半；未溢出轴为 0 → 该轴不可平移）
    private func maxOffset(for targetScale: CGFloat) -> CGSize {
        guard let image = loadedImage, containerSize.width > 0 else { return .zero }
        let fitted = SJZImageViewerGeometry.fittedSize(imageSize: image.size, containerSize: containerSize)
        return SJZImageViewerGeometry.maxOffset(displaySize: fitted, scale: targetScale, containerSize: containerSize)
    }

    /// 捏合结束：缩回 1x 复位归零；否则夹紧回边界（防内容停在屏幕外）
    private func finishZoomGesture() {
        let from = scale
        let finalScale = SJZImageViewerGeometry.clampedScale(scale, lowerBound: minZoomScale, upperBound: maxZoomScale)
        let resetToFit = finalScale <= minZoomScale + 0.01
        let finalOffset = resetToFit
            ? CGSize.zero
            : SJZImageViewerGeometry.clamped(offset, maxOffset: maxOffset(for: finalScale))
        withAnimation(reduceMotion ? nil : Animation.spring(response: 0.35, dampingFraction: 0.8)) {
            scale = finalScale
            offset = finalOffset
        }
        scheduleZoomHUDHide()
        LogManager.shared.info("imageViewer", "缩放结束", context: [
            "from": Self.zoomText(from),
            "to": Self.zoomText(finalScale),
            "resetToFit": "\(resetToFit)"
        ])
    }

    /// 双击：以双击点为锚在 1x ↔ 2.5x 切换（弹簧动画）
    private func handleDoubleTap(at location: CGPoint) {
        let zoomingOut = scale > minZoomScale + 0.01
        applyZoom(targetScale: zoomingOut ? minZoomScale : doubleTapZoomScale,
                  anchor: location,
                  source: zoomingOut ? "双击复位" : "双击放大")
    }

    /// 单击：仅在 1x 且无拖动/缩放/翻页进行中时关闭查看器（沿用既有语义，防误触）
    private func handleSingleTap() {
        guard scale <= minZoomScale + 0.01, !isDragging, !isMagnifying, !isTurningPage else { return }
        LogManager.shared.debugLog("imageViewer", "单击关闭", context: ["scale": Self.zoomText(scale)])
        dismiss()
    }

    /// 无障碍调节（VoiceOver 上下轻扫）：绕中心步进缩放
    private func handleAccessibilityZoom(_ direction: AccessibilityAdjustmentDirection) {
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        switch direction {
        case .increment:
            applyZoom(targetScale: scale * 1.5, anchor: center, source: "无障碍·放大")
        case .decrement:
            applyZoom(targetScale: scale / 1.5, anchor: center, source: "无障碍·缩小")
        default:
            break
        }
    }

    /// 统一缩放应用（双击 / 无障碍共用）：锚点换算 + 夹紧 + 弹簧动画 + HUD + 日志
    private func applyZoom(targetScale: CGFloat, anchor: CGPoint, source: String) {
        let from = scale
        let target = SJZImageViewerGeometry.clampedScale(targetScale, lowerBound: minZoomScale, upperBound: maxZoomScale)
        guard abs(target - from) > 0.001 else { return }
        var newOffset = SJZImageViewerGeometry.clamped(
            SJZImageViewerGeometry.anchoredOffset(anchor: anchor, containerSize: containerSize,
                                                  offset: offset, oldScale: from, newScale: target),
            maxOffset: maxOffset(for: target))
        if target <= minZoomScale + 0.01 { newOffset = .zero }
        presentZoomHUD()
        withAnimation(reduceMotion ? nil : Animation.spring(response: 0.38, dampingFraction: 0.78)) {
            scale = target
            offset = newOffset
        }
        scheduleZoomHUDHide()
        LogManager.shared.info("imageViewer", "缩放应用", context: [
            "source": source, "from": Self.zoomText(from), "to": Self.zoomText(target)
        ])
    }

    /// 容器尺寸变化后的重新夹紧（旋转/分屏；防越界导致内容不可见）
    private func reclampOffset(animated: Bool, reason: String) {
        guard scale > minZoomScale + 0.001 else { return }
        let settled = SJZImageViewerGeometry.clamped(offset, maxOffset: maxOffset(for: scale))
        guard settled != offset else { return }
        if animated {
            withAnimation(reduceMotion ? nil : Animation.spring(response: 0.35, dampingFraction: 0.85)) {
                offset = settled
            }
        } else {
            offset = settled
        }
        LogManager.shared.debugLog("imageViewer", "容器变化重新夹紧", context: ["reason": reason])
    }

    /// 缩放倍率 HUD（克制玻璃胶囊；捏合/双击时淡入，停手 1.4s 自动淡出）
    private var zoomHUD: some View {
        Text(Self.zoomText(scale))
            .displayFont(12, weight: .semibold, design: .rounded)
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .padding(.top, 12)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityHidden(true)
    }

    private func presentZoomHUD() {
        withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.18)) { showZoomHUD = true }
    }

    private func scheduleZoomHUDHide() {
        zoomHUDTask?.cancel()
        zoomHUDTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.28)) { showZoomHUD = false }
        }
    }

    /// 倍率文案（HUD / 无障碍 / 日志共用口径）
    private static func zoomText(_ value: CGFloat) -> String {
        String(format: "%.1f×", value)
    }

    /// 统一加载通道：缓存优先（Referer 由协议层统一注入），带下载进度与命中统计
    /// - Parameter target: 目标图片 URL（翻页/单图统一入口；URL 变化由 .task(id:) 触发重载）
    private func loadImage(for target: URL) async {
        isLoading = true
        loadError = nil
        downloadProgress = nil
        isFromCache = false

        // 解码图内存缓存直出（orig 规格，零闪烁）
        let memoryKey = SJZDecodedImageCache.key(url: target, maxPixel: nil)
        if let cached = SJZDecodedImageCache.shared.image(forKey: memoryKey) {
            isFromCache = true
            finishLoad(image: cached)
            LogManager.shared.debugLog("imageCache", "全屏图片内存缓存直出，零闪烁", context: [
                "url": target.lastPathComponent
            ])
            return
        }

        let request = SJZImageKit.makeRequest(url: target)
        let startTime = Date()

        // 缓存直读（原图不降采样，保证全屏清晰度；坏条目即时清理自愈）
        if let cached = SJZImageKit.usableCachedResponse(for: request) {
            if let image = UIImage(data: cached.data) {
                isFromCache = true
                SJZDecodedImageCache.shared.store(image, forKey: memoryKey)
                CacheModeManager.shared.recordImageHit(url: target.absoluteString)
                CacheModeManager.shared.recordSavedTraffic(bytes: Int64(cached.data.count))
                finishLoad(image: image)
                LogManager.shared.debugLog("imageCache", "全屏图片缓存命中，秒开", context: [
                    "url": target.lastPathComponent,
                    "size": ByteCountFormatter.string(fromByteCount: Int64(cached.data.count), countStyle: .file)
                ])
                return
            }
            // 解码失败不删缓存（防误删健康条目）：网络重下成功后新响应会覆盖重建该条目
            LogManager.shared.warning("imageCache", "全屏图片缓存数据不可用，回落网络加载", context: [
                "url": target.lastPathComponent,
                "action": "fallback(noRemove)"
            ])
        } else {
            LogManager.shared.debugLog("imageCache", "全屏图片开始下载", context: [
                "url": target.lastPathComponent
            ])
        }

        // 网络下载（进度上报）；并发闸与其余图片加载共享（全局 ≤4）
        await SJZImageConcurrencyGate.shared.acquire()
        defer { Task { await SJZImageConcurrencyGate.shared.release() } }
        do {
            let delegate = SJZImageDownloadDelegate()
            delegate.onProgress = { value in
                Task { @MainActor in
                    downloadProgress = value
                }
            }
            let (data, response) = try await SJZImageKit.imageSession.data(for: request, delegate: delegate)
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    loadError = "HTTP \(httpResponse.statusCode)"
                    isLoading = false
                    LogManager.shared.error("imageCache", "全屏图片 HTTP 错误", context: [
                        "url": target.lastPathComponent, "status": "\(httpResponse.statusCode)"
                    ])
                    return
                }
            }
            guard let image = UIImage(data: data) else {
                loadError = "图片数据解码失败"
                isLoading = false
                LogManager.shared.warning("imageCache", "全屏图片解码失败", context: [
                    "url": target.lastPathComponent, "dataSize": "\(data.count)"
                ])
                return
            }
            CacheModeManager.shared.recordImageMiss(url: target.absoluteString)
            SJZDecodedImageCache.shared.store(image, forKey: memoryKey)
            finishLoad(image: image)
            LogManager.shared.debugLog("imageCache", "全屏图片加载成功", context: [
                "url": target.lastPathComponent,
                "size": "\(Int(image.size.width))x\(Int(image.size.height))",
                "elapsed": String(format: "%.0fms", Date().timeIntervalSince(startTime) * 1000)
            ])
        } catch {
            // 取消类错误（关闭/切页的正常中断）：静默退出，不记 ERROR（2026-09-27 警告误报治理）
            if SJZImageKit.isCancellation(error) {
                isLoading = false
                return
            }
            loadError = error.localizedDescription
            isLoading = false
            LogManager.shared.error("imageCache", "全屏图片加载失败", context: [
                "url": target.lastPathComponent, "error": error.localizedDescription
            ])
        }
    }

    @MainActor
    private func finishLoad(image: UIImage) {
        withAnimation(.easeOut(duration: 0.3)) {
            loadedImage = image
            isLoading = false
        }
        // 加载完成轻触感反馈（成功且来自网络时）
        if !isFromCache {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }
}

// MARK: - WebView

struct WebViewContainer: View {
    let urlString: String
    /// 是否以桌面 UA 加载（外链 PC 站典型需求：知网等对移动 UA 会跳 App/空白；
    /// 仅 link 形态传入，内嵌的校园网页面保持移动 UA）
    var desktopUA: Bool = false
    /// 标签页集合：每次跨站导航（页面内「知网」「电子图书」等入口）自动新建独立页签，
    /// 各页签独立前进/后退，互不覆盖——即浏览器标签页行为。
    @State private var tabs: [WebViewTab] = []
    @State private var activeTabID: UUID?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var loadingProgress: Double = 0
    /// 浏览器导航句柄（作用于当前激活页签）
    @StateObject private var control = WebViewControl()

    private var safeURL: URL? {
        // 处理 SPA hash URL（如 https://xxx/#/path?query=value）
        // SPA hash URL 中的 # 后面的路径和参数需要保留
        if let url = URL(string: urlString) {
            return url
        }
        // 如果 URL 包含中文等非 ASCII 字符，尝试编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }

    /// 站点短名（页签标题）；www. / wap. 前缀去除
    private func hostLabel(_ url: URL) -> String {
        let host = url.host ?? "网页"
        return host.replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "wap.", with: "")
    }

    private var activeTab: WebViewTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// 新建页签并激活（跨站导航 / window.open 统一入口）
    private func openNewTab(_ url: URL) {
        // 去重：同 URL 已存在则仅切换激活，避免重复页签
        if let existing = tabs.first(where: { $0.url.absoluteString == url.absoluteString }) {
            activeTabID = existing.id
            return
        }
        let tab = WebViewTab(url: url)
        tabs.append(tab)
        activeTabID = tab.id
        loadError = nil
        LogManager.shared.info("webview", "新页签打开", context: [
            "url": String(url.absoluteString.prefix(120)),
            "tabs": "\(tabs.count)"
        ])
    }

    var body: some View {
        VStack(spacing: 0) {
            // 页签条：跨站入口（「知网」「电子图书」等）各开独立页签，点按切换、×关闭
            // 始终显示（单页签时也可见），便于页面层级透明
            ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabs) { tab in
                            let isActive = tab.id == activeTabID
                            Button {
                                activeTabID = tab.id
                                loadError = nil
                            } label: {
                                HStack(spacing: 5) {
                                    Text(hostLabel(tab.url))
                                        .displayFont(11, weight: .semibold)
                                        .lineLimit(1)
                                        .foregroundStyle(isActive ? Color.sjzAccent : .secondary)
                                    Button {
                                        closeTab(tab.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .displaySymbolFont(8, weight: .bold)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("关闭 \(hostLabel(tab.url))")
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(isActive ? Color.sjzAccent.opacity(0.12) : Color(.systemGray6))
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isActive ? [.isSelected] : [])
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(height: 30)

            // 浏览器导航条：返回 / 前进 / 刷新（作用于当前页签）
            HStack(spacing: 22) {
                Button {
                    control.back()
                } label: {
                    Image(systemName: "chevron.left")
                        .displaySymbolFont(14, weight: .semibold)
                        .foregroundStyle(control.canGoBack ? Color.primary : Color.secondary.opacity(0.4))
                }
                .disabled(!control.canGoBack)
                .accessibilityLabel("后退")

                Button {
                    control.forward()
                } label: {
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(14, weight: .semibold)
                        .foregroundStyle(control.canGoForward ? Color.primary : Color.secondary.opacity(0.4))
                }
                .disabled(!control.canGoForward)
                .accessibilityLabel("前进")

                Button {
                    control.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .displaySymbolFont(13, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("刷新")

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            ZStack {
                if let url = safeURL, !tabs.isEmpty {
                    ForEach(tabs) { tab in
                        let isActive = tab.id == activeTabID
                        WebView(url: tab.url,
                                desktopUA: desktopUA,
                                isLoading: $isLoading, loadError: $loadError, loadingProgress: $loadingProgress,
                                onNewWindow: { newURL in
                                    openNewTab(newURL)
                                },
                                control: isActive ? control : nil,
                                referenceHost: tab.url.host)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "link.badge.plus")
                            .displaySymbolFont(48)
                            .foregroundStyle(.secondary)
                        Text("无法打开链接")
                            .displayFont(17, weight: .semibold)
                        Text("链接格式无效")
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                    }
                }
                // 加载指示器
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView(value: loadingProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(Color.sjzAccent)
                            .frame(width: 200)
                        Text("正在加载...")
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                // 错误提示
                if let error = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .displaySymbolFont(40)
                            .foregroundStyle(.orange)
                        Text("加载失败")
                            .displayFont(17, weight: .semibold)
                        Text(error)
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            loadError = nil
                            isLoading = true
                            loadingProgress = 0
                        } label: {
                            Label("重新加载", systemImage: "arrow.clockwise")
                                .displayLabelFont(14, weight: .medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .onAppear {
            // 初始化首标签页（首次出现时；tabs 已由 openNewTab/外部注入者填充则跳过）
            if tabs.isEmpty, let url = safeURL {
                tabs = [WebViewTab(url: url)]
                activeTabID = tabs.first?.id
            }
        }
        .onChange(of: urlString) { _, newValue in
            // 外部切换链接（link 形态壳内在「知网」↔「电子图书」等栏目间切换）：
            // SwiftUI 会复用同一 WebViewContainer 视图身份（同 switch 分支、同位置），
            // 若仅依赖 onAppear 则 tabs 保持旧站不重载——这里按"浏览器标签页行为"
            // 重置页签为新站会话（点知网开知网页、点电子图书开电子图书页）。
            guard let newURL = Self.parsedURL(newValue) else { return }
            if tabs.first?.url == newURL { return }
            tabs = [WebViewTab(url: newURL)]
            activeTabID = tabs.first?.id
            loadError = nil
            isLoading = true
            loadingProgress = 0
            LogManager.shared.info("webview", "外链切换·页签重置", context: [
                "url": String(newURL.absoluteString.prefix(120))
            ])
        }
    }

    /// 解析外部传入链接（含中文等非 ASCII 的 URL 编码兜底）
    private static func parsedURL(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        if let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }

    /// 关闭页签：至少保留一个；关闭激活页签时激活相邻页签
    private func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), tabs.count > 1 else { return }
        tabs.remove(at: idx)
        if activeTabID == id {
            let newIndex = min(idx, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }
        loadError = nil
    }
}

// MARK: - WebViewTab（内嵌网页标签页）

/// 独立页签：每次跨站导航/新窗口打开的独立 WebView（各自前进/后退历史）
struct WebViewTab: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - WebViewControl（内嵌网页浏览器导航句柄）

/// 浏览器式前进/后退/刷新句柄：主帧 JS 导航（如电子图书页「知网/电子图书」互切）走 back/forward 往返
final class WebViewControl: ObservableObject {
    weak var webView: WKWebView?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    func attach(_ webView: WKWebView) {
        self.webView = webView
        refreshState(webView)
    }
    func refreshState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

struct WebView: UIViewRepresentable {
    let url: URL
    var desktopUA: Bool = false
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    @Binding var loadingProgress: Double
    /// 页面内 window.open / target=_blank 的新窗口回调（外层弹独立页面，不改当前页）
    var onNewWindow: ((URL) -> Void)? = nil
    /// 浏览器导航句柄（返回/前进/刷新）
    var control: WebViewControl? = nil
    /// 页签参照域（= 该页签初始 URL 的 host）：跨域导航据此开新页签；
    /// 不能用 webView.url 实时判断（JS 导航发起时 webView.url 已指向目标页，存在竞态导致永不触发）
    var referenceHost: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 站点导航常以 JS 开窗（window.open）进入子站（如超星电子图书页的「知网」入口）
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if desktopUA {
            // 桌面 UA：外链 PC 站（知网/超星等）对移动 UA 会跳转 App/渲染空白
            webView.customUserAgent = Self.desktopUserAgent
        }
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        webView.load(URLRequest(url: url))
        control?.attach(webView)
        return webView
    }

    /// 桌面 Safari UA（Safari 17 桌面）
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        /// 新窗口回调（独立页面，避免"当前页替换导致原页入口失效"）
        private let onNewWindow: (URL) -> Void
        init(_ parent: WebView) {
            self.parent = parent
            self.onNewWindow = parent.onNewWindow ?? { _ in }
        }
        // 页面内 `target=_blank` / `window.open`（如图书馆电子图书页的「知网」「超星」等入口）：
        // 委托外层弹独立页面；原页面保留可返回、其余入口仍可点击。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                onNewWindow(url)
            } else {
                LogManager.shared.warning("webview", "外链新窗口·非 http(s) 忽略", context: [
                    "url": navigationAction.request.url?.absoluteString ?? "nil"
                ])
            }
            return nil
        }
        // 导航可观测 + 跨站主帧导航 → 新页签（浏览器标签页行为）：
        // 页面内「知网」「电子图书」等跨域入口（JS 主帧跳转）各自打开独立页签，互不覆盖；
        // 同站页内导航（页内链接/翻页）留在当前页签前进。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "nil"
            let reqURL = navigationAction.request.url
            let currentURL = webView.url
            LogManager.shared.debugLog("webview", "导航请求", context: [
                "url": String(url.prefix(120)),
                "type": "\(navigationAction.navigationType.rawValue)",
                "mainFrame": "\(navigationAction.targetFrame?.isMainFrame ?? false)",
                "refHost": parent.referenceHost ?? "nil",
                "destHost": reqURL?.host ?? "nil"
            ])
            // 页签参照域跨站导航 → 新页签（浏览器标签页行为）：
            // 页面内「知网」等跨域入口（JS 主帧跳转）各自打开独立页签，互不覆盖；
            // 同域页内导航（页内链接/翻页）留在当前页签。同族登录/API 域（chaoxing 系）放行保持登录流。
            if let reqURL,
               reqURL.scheme == "http" || reqURL.scheme == "https",
               let refHost = parent.referenceHost,
               reqURL.host != refHost {
                let host = reqURL.host ?? ""
                let isAuthFlow = host.hasSuffix("chaoxing.com") || host.hasSuffix("sslibrary.com")
                if !isAuthFlow {
                    onNewWindow(reqURL)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            LogManager.shared.debugLog("webview", "导航开始", context: [
                "url": String(webView.url?.absoluteString.prefix(120) ?? "nil")
            ])
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.loadingProgress = 1.0
            parent.control?.refreshState(webView)
            LogManager.shared.info("webview", "页面加载完成", context: [
                "url": String((webView.url?.absoluteString ?? "nil").prefix(120)),
                "title": String((webView.title ?? "").prefix(40))
            ])
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.loadError = "页面加载失败：\(error.localizedDescription)"
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            // 忽略取消加载和 SPA 内部导航错误
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            parent.isLoading = false
            parent.loadError = "无法连接到服务器，请检查网络后重试"
        }
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "estimatedProgress", let webView = object as? WKWebView {
                parent.loadingProgress = webView.estimatedProgress
            }
        }
    }
}

// MARK: - 荣誉详情

struct HonorDetailView: View {
    let honor: Honor
    /// 看图载荷（item 式呈现：根治「先显示第一张」的陈旧快照 + 支持左右翻页）
    @State private var imageViewerPayload: SJZImageGalleryPayload?
    @State private var contentAppear = false
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoadingDetail = true
    @State private var loadError: String?
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var showSharePicker = false
    @State private var selectedShareFormat: ShareFormat?
    @State private var showWeChatShare = false
    @State private var isGeneratingLongImage = false
    /// 长图分享目标（系统分享面板 / 微信图片消息；由分享面板入口设置）
    @State private var longImageDestination: LongImageDestination = .system
    /// 微信长图分享载荷（非空 → 弹出长图分享菜单）
    @State private var weChatLongImagePayload: WeChatLongImagePayload?
    @State private var longImageError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let imgUrl = honor.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url, maxPixel: 1440) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 320)
                                .onTapGesture {
                                    imageViewerPayload = SJZImageGalleryPayload.single(url: url, source: "header")
                                    LogManager.shared.debugLog("imageViewer", "查看图片（头图）", context: [
                                        "url": url.lastPathComponent
                                    ])
                                }
                        case .failure:
                            honorDetailHeader
                        default:
                            ShimmerView().frame(height: 320)
                        }
                    }
                } else {
                    honorDetailHeader
                }
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(Color.sjzGold.opacity(0.08)).frame(width: 60, height: 60)
                            Image(systemName: honor.icon)
                                .displaySymbolFont(22).foregroundStyle(Color.sjzGold)
                        }
                        Text(honor.title)
                            .displayFont(22, weight: .bold)
                    }
                    if !isLoadingDetail, let detail = fullDetail {
                        let statsText = detail.plainTextContent.isEmpty
                            ? detail.content.strippingHTMLTags()
                            : detail.plainTextContent
                        if !statsText.isEmpty {
                            ArticleReadingStatsText(
                                cachedID: honor.title,
                                plainText: statsText,
                                imageCount: detail.images.count
                            )
                        }
                    }
                    if let tag = honor.tag {
                        HStack(spacing: 10) {
                            Label(tag, systemImage: "tag.fill")
                                .displayLabelFont(12, weight: .medium)
                                .foregroundStyle(Color.sjzAccent)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color.sjzAccent.opacity(0.08), in: Capsule())
                            if let date = honor.date {
                                Label(date, systemImage: "calendar")
                                    .displayLabelFont(12).foregroundStyle(.secondary)
                            }
                        }
                    }

                    // 作者和来源
                    if !isLoadingDetail, loadError == nil {
                        if let author = fullDetail?.author, !author.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill").displaySymbolFont(11)
                                Text("作者：\(author)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                        if let source = fullDetail?.source, !source.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link").displaySymbolFont(11)
                                Text("来源：\(source)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 加载状态
                    if isLoadingDetail {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("正在加载完整内容...").displayFont(12).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .displayFont(13)
                                    .foregroundStyle(.orange)
                            }
                            .padding(16)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            // 加载失败兜底摘要同样展示统计
                            if !honor.detail.isEmpty {
                                ArticleReadingStatsText(cachedID: honor.title, plainText: honor.detail)
                            }

                            Text(honor.detail)
                                .displayFont(16).lineSpacing(10)
                                .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                            Button {
                                retryLoading()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("重新加载", systemImage: "arrow.clockwise")
                                        .displayLabelFont(14, weight: .medium)
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else {
                        let content = fullDetail?.plainTextContent ?? honor.detail
                        Text(content)
                            .displayFont(16).lineSpacing(10)
                            .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                        if let images = fullDetail?.images, !images.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Divider()
                                Label("图片（\(images.count)张）", systemImage: "photo.on.rectangle")
                                    .displayLabelFont(14, weight: .semibold)
                                    .foregroundStyle(.primary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                                            SJZCachedImage(url: URL(string: img.url)) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                case .failure:
                                                    Color.gray.opacity(0.08)
                                                default:
                                                    ShimmerView()
                                                }
                                            }
                                            .frame(width: 160, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .onTapGesture {
                                                imageViewerPayload = SJZImageGalleryPayload.make(
                                                    images: images, tappedIndex: idx, source: "grid")
                                                LogManager.shared.debugLog("imageViewer", "查看图片（图集网格）", context: [
                                                    "index": "\(idx + 1)/\(images.count)",
                                                    "url": img.url
                                                ])
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .opacity(contentAppear ? 1 : 0)
                .offset(y: contentAppear ? 0 : 20)
            }
        }
        .navigationTitle("荣誉详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // 收藏按钮
                    Button {
                        let wasBookmarked = bookmarkManager.isBookmarked(bookmarkKey)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            bookmarkManager.toggleBookmark(
                                articleId: honor.articleId ?? "",
                                title: honor.title,
                                date: honor.date ?? "",
                                category: "校园荣誉",
                                summary: honorBodyText,
                                imageUrl: honor.imageUrl
                            )
                        }
                        LogManager.shared.info("ui", "荣誉收藏操作", context: [
                            "articleId": honor.articleId ?? "-",
                            "title": honor.title,
                            "action": wasBookmarked ? "取消收藏" : "收藏"
                        ])
                    } label: {
                        Image(systemName: bookmarkManager.isBookmarked(bookmarkKey) ? "bookmark.fill" : "bookmark")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(bookmarkManager.isBookmarked(bookmarkKey) ? Color.sjzGold : .primary)
                    }
                    .contentShape(Rectangle())

                    // 分享按钮
                    Button {
                        showSharePicker = true
                        LogManager.shared.info("ui", "荣誉分享按钮点击", context: [
                            "articleId": honor.articleId ?? "-",
                            "title": honor.title
                        ])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(14, weight: .medium)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .confirmationDialog("选择分享格式", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享到微信") { showWeChatShare = true }
            Button("长图分享到微信") {
                longImageDestination = .weChat
                startLongImageGeneration()
            }
            Button("纯链接") { selectedShareFormat = .link }
            Button("Markdown文章") { selectedShareFormat = .markdown }
            Button("标题+正文文本") { selectedShareFormat = .fullText }
            Button("长图") {
                longImageDestination = .system
                startLongImageGeneration()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .sheet(item: $weChatLongImagePayload) { payload in
            WeChatLongImageShareMenu(payload: payload)
                .sjzPresentationChrome()
        }
        .sheet(item: $selectedShareFormat) { format in
            ShareSheet(items: honorShareItems(format, url: honorArticleURL, title: honor.title, body: honorBodyText))
        }
        .overlay {
            if isGeneratingLongImage {
                longImageOverlay
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                contentAppear = true
            }
        }
        .task {
            await loadDetail()
        }
        .fullScreenCover(item: $imageViewerPayload) { payload in
            FullScreenImageView(payload: payload, fallbackTitle: honor.title)
                .sjzPresentationChrome()
        }
    }

    /// 荣誉收藏键：与 BookmarkManager 内部键规则一致（articleId 为空时用标题+日期）
    private var bookmarkKey: String {
        honor.articleId ?? honor.title + (honor.date ?? "")
    }

    /// 荣誉正文文本（加载完成后优先全文，否则摘要兜底）
    private var honorBodyText: String {
        if let detail = fullDetail, !detail.plainTextContent.isEmpty {
            return detail.plainTextContent
        }
        return honor.detail
    }

    /// 荣誉文章详情页 URL（用于分享）
    private var honorArticleURL: String {
        if let articleId = honor.articleId, !articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(articleId)"
        }
        return SchoolInfo.website
    }

    /// 微信分享载荷（标题 + 正文摘要 + 链接 + 缩略图；微信限制由 WeChatService 统一裁剪）
    private var weChatSharePayload: WeChatSharePayload {
        WeChatSharePayload(
            title: honor.title,
            description: honorBodyText,
            urlString: honorArticleURL,
            thumbImageURL: honor.imageUrl
        )
    }

    /// 根据分享格式生成分享内容
    private func honorShareItems(_ format: ShareFormat, url: String, title: String, body: String) -> [Any] {
        switch format {
        case .link:
            return [URL(string: url) as Any]
        case .markdown:
            var md = "# \(title)\n\n"
            if let date = honor.date, !date.isEmpty {
                md += "> 日期：\(date)\n\n"
            }
            md += "---\n\n\(body)\n\n[阅读原文](\(url))"
            return [md]
        case .fullText:
            let summary = body.count > 200 ? String(body.prefix(200)) + "..." : body
            return ["\(title)\n\n\(summary)\n\n阅读原文：\(url)"]
        case .longImage:
            return []
        }
    }

    // MARK: - 长图生成

    /// 长图生成加载遮罩（与新闻详情同款）
    private var longImageOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在生成文章长图...")
                    .displayFont(16, weight: .medium)
                    .foregroundStyle(.white)
                Text("下载图片并渲染中")
                    .displayFont(13)
                    .foregroundStyle(.white.opacity(0.7))
                if let error = longImageError {
                    VStack(spacing: 12) {
                        Text(error)
                            .displayFont(13)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("关闭") {
                            isGeneratingLongImage = false
                            longImageError = nil
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.white.opacity(0.2), in: Capsule())
                    }
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
    }

    /// 启动长图生成流程
    private func startLongImageGeneration() {
        isGeneratingLongImage = true
        longImageError = nil
        Task {
            await generateLongImage()
        }
    }

    /// 异步下载文章图片并生成长图，完成后直接 present 系统分享面板
    private func generateLongImage() async {
        let articleURL = honorArticleURL
        let title = honor.title
        let body = honorBodyText

        // 构建元数据字符串
        var metaParts: [String] = []
        metaParts.append("校园荣誉")
        if let date = honor.date, !date.isEmpty { metaParts.append(date) }
        if let author = fullDetail?.author, !author.isEmpty { metaParts.append("作者：\(author)") }
        if let source = fullDetail?.source, !source.isEmpty { metaParts.append("来源：\(source)") }
        let metadata = metaParts.joined(separator: " · ")

        // 加载长图素材（压缩数据 + 尺寸元数据；渲染时按需缩略解码——多图文章的内存防线）
        let imageAssets = await ArticleLongImageLoader.loadAll(fullDetail?.images ?? [], tag: "honor_detail")

        // 渲染长图
        let renderer = ArticleLongImageRenderer(
            title: title,
            metadata: metadata,
            content: body,
            images: imageAssets,
            articleURL: articleURL,
            tag: "honor_detail"
        )

        await MainActor.run {
            LogManager.shared.debugLog("longimage", "开始生成荣誉长图", context: [
                "title": title, "images": "\(imageAssets.count)"
            ])
            let renderedImage = renderer.render()
            guard let renderedImage else {
                // 保持 isGeneratingLongImage = true，让 overlay 显示错误信息
                longImageError = "长图生成失败，请重试"
                return
            }
            isGeneratingLongImage = false
            // 等 confirmationDialog 关闭动画完成后再 present 分享面板（避免 UIActivityViewController 静默失败）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                switch longImageDestination {
                case .system:
                    presentLongImageShare(image: renderedImage, title: title)
                case .weChat:
                    // 微信图片消息（WXImageObject）：弹出场景菜单（好友 / 朋友圈 / 收藏）
                    weChatLongImagePayload = WeChatLongImagePayload(image: renderedImage, title: title, entry: "honor_detail")
                }
            }
        }
    }

    /// 直接以 UIKit 模态方式呈现 UIActivityViewController（绕过 SwiftUI sheet 嵌套，微信分享兼容）
    private func presentLongImageShare(image: UIImage, title: String) {
        // 交付前兜底校验：纯色 / 黑图绝不落盘分享（渲染层已校验；此处防编码链路异常）
        guard !SJZImageIntegrity.isLikelyBlank(image) else {
            longImageError = "长图生成异常（画布纯色），请重试"
            isGeneratingLongImage = true
            LogManager.shared.error("longimage", "长图交付校验拦截（画布纯色）", context: [
                "title": title,
                "pixel": SJZImageIntegrity.pixelSizeText(of: image)
            ])
            return
        }
        // 交付编码：分享扩展（微信等）内存与体积预算有限（约 120MB）——按「≤16MP / ≤10MB」编码，
        // 否则扩展会被系统终止（2026-09-28 现场：微信「加载中 → 闪回 App」）；产物含纯色 / 黑图校验
        guard let encoded = WeChatImageEncoder.encode(
            image,
            maxBytes: WeChatImageEncoder.systemShareMaxBytes,
            maxPixels: WeChatImageEncoder.systemShareMaxPixels
        ) else {
            longImageError = "图片编码失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图 JPEG 编码失败", context: ["title": title])
            return
        }
        let jpegData = encoded.data
        LogManager.shared.info("longimage", "长图分享文件编码完成", context: [
            "title": title,
            "pixel": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
            "quality": String(format: "%.2f", encoded.quality),
            "scale": String(format: "%.2f", encoded.scale),
            "bytes": "\(encoded.data.count)"
        ])

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(20)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sxjzit_\(safeTitle)_\(UUID().uuidString.prefix(6)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: fileURL)
        } catch {
            longImageError = "图片保存失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图临时文件写入失败", context: ["title": title])
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            longImageError = "无法获取窗口"
            isGeneratingLongImage = true
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // 仅传递文件 URL 和标题文本（微信 Share Extension 通过文件 URL 读取图片）
        let activityItems: [Any] = [fileURL, title]
        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]
        activityVC.completionWithItemsHandler = { [fileURL] _, completed, _, error in
            // 分享扩展（微信等）读取大图较慢，且本回调在「用户选择动作」时即触发——
            // 绝不能立即删除（现场：微信「加载中 → 闪回 App」）；交由共享中心延迟 5 分钟清理
            SJZShareFileCenter.scheduleCleanup(fileURL)
            if !completed {
                // 分享未完成（系统扩展可能因体积 / 尺寸限制中止）：记录可判别数据 + 给出可操作替代路径
                WeChatService.shared.showBanner("微信未完成分享，可改用「分享 → 长图分享到微信」", kind: .info)
                LogManager.shared.warning("longimage", "长图分享未完成（系统扩展可能中止）", context: [
                    "pixel": SJZImageIntegrity.pixelSizeText(of: image),
                    "bytes": "\(jpegData.count)",
                    "error": error?.localizedDescription ?? "none"
                ])
            }
            if let error = error {
                LogManager.shared.error("ui", "荣誉长图分享失败", context: ["error": error.localizedDescription])
            } else {
                LogManager.shared.info("ui", "荣誉长图分享结束", context: ["completed": "\(completed)"])
            }
        }
        topVC.present(activityVC, animated: true)
    }

    /// 下载单张图片（统一走 SJZImageKit：缓存复用 + 进度通道 + 协议层 Referer）
    private func loadDetail() async {
        guard let articleId = honor.articleId else {
            isLoadingDetail = false
            return
        }
        if fullDetail != nil && cacheManager.isCacheEnabled {
            LogManager.shared.debugLog("ui", "缓存模式下荣誉详情已加载，跳过重复请求", context: [
                "articleId": articleId, "title": honor.title
            ])
            return
        }
        isLoadingDetail = true
        loadError = nil
        LogManager.shared.info("ui", "开始加载荣誉详情", context: ["articleId": articleId, "title": honor.title])
        do {
            let detail = try await DataService.shared.loadArticleFullDetail(articleId: articleId)
            fullDetail = detail
            LogManager.shared.info("ui", "荣誉详情加载成功", context: ["articleId": articleId, "images": "\(detail.images.count)"])
        } catch {
            loadError = "文章详情加载失败，请检查网络连接后重试"
            LogManager.shared.error("ui", "荣誉详情加载失败", context: ["articleId": articleId, "error": error.localizedDescription])
        }
        isLoadingDetail = false
    }

    private func retryLoading() {
        Task {
            await loadDetail()
        }
    }

    private var honorDetailHeader: some View {
        LinearGradient(
            colors: [Color.sjzLight, Color.sjzAccent.opacity(0.05)],
            startPoint: .top, endPoint: .bottom)
        .frame(height: 280)
        .overlay {
            Image(systemName: honor.icon)
                .displaySymbolFont(80).foregroundStyle(Color.sjzAccent.opacity(0.06))
        }
    }
}

// MARK: - 校园风光详情

struct SceneryDetailView: View {
    let scenery: CampusScenery
    @State private var showFullscreen = false
    @State private var contentAppear = false
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let imgUrl = scenery.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url, maxPixel: 1440) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 340)
                                .onTapGesture { showFullscreen = true }
                        case .failure:
                            sceneryDetailPlaceholder
                        default:
                            ShimmerView().frame(height: 340)
                        }
                    }
                } else {
                    sceneryDetailPlaceholder
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text(scenery.title)
                        .displayFont(24, weight: .bold)
                    if let desc = scenery.description, !desc.isEmpty {
                        ArticleReadingStatsText(cachedID: scenery.title, plainText: desc)
                    }
                    if let desc = scenery.description, !desc.isEmpty {
                        Divider()
                        Text(desc)
                            .displayFont(16).lineSpacing(10)
                            .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)
                    }
                }
                .padding(24)
                .opacity(contentAppear ? 1 : 0)
                .offset(y: contentAppear ? 0 : 20)
            }
        }
        .navigationTitle("校园风光").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                contentAppear = true
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            Group {
                if let imgUrl = scenery.imageUrl, let url = URL(string: imgUrl) {
                    FullScreenImageView(url: url, title: scenery.title)
                }
            }
            .sjzPresentationChrome()
        }
    }

    private var sceneryDetailPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzGreen.opacity(0.04), Color.sjzLight],
            startPoint: .top, endPoint: .bottom)
        .frame(height: 300)
        .overlay {
            Image(systemName: "photo.on.rectangle.angled")
                .displaySymbolFont(70).foregroundStyle(Color.sjzGreen.opacity(0.06))
        }
    }
}

// MARK: - 教师风采详情

struct TeacherDetailView: View {
    let teacher: TeacherProfile
    /// 看图载荷（item 式呈现：根治「先显示第一张」的陈旧快照 + 支持左右翻页）
    @State private var imageViewerPayload: SJZImageGalleryPayload?
    @State private var contentAppear = false
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoadingDetail = true
    @State private var loadError: String?
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var showSharePicker = false
    @State private var selectedShareFormat: ShareFormat?
    @State private var showWeChatShare = false
    @State private var isGeneratingLongImage = false
    /// 长图分享目标（系统分享面板 / 微信图片消息；由分享面板入口设置）
    @State private var longImageDestination: LongImageDestination = .system
    /// 微信长图分享载荷（非空 → 弹出长图分享菜单）
    @State private var weChatLongImagePayload: WeChatLongImagePayload?
    @State private var longImageError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let imgUrl = teacher.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url, maxPixel: 1440) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 340)
                                .onTapGesture {
                                    imageViewerPayload = SJZImageGalleryPayload.single(url: url, source: "header")
                                    LogManager.shared.debugLog("imageViewer", "查看图片（头图）", context: [
                                        "url": url.lastPathComponent
                                    ])
                                }
                        case .failure:
                            teacherDetailPlaceholder
                        default:
                            ShimmerView().frame(height: 340)
                        }
                    }
                } else {
                    teacherDetailPlaceholder
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text(teacher.title)
                        .displayFont(24, weight: .bold)
                    if let date = teacher.date, !date.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .displaySymbolFont(12)
                            Text(date)
                                .displayFont(14)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !isLoadingDetail, let detail = fullDetail {
                        let statsText = detail.plainTextContent.isEmpty
                            ? detail.content.strippingHTMLTags()
                            : detail.plainTextContent
                        if !statsText.isEmpty {
                            ArticleReadingStatsText(
                                cachedID: teacher.title,
                                plainText: statsText,
                                imageCount: detail.images.count
                            )
                        }
                    }

                    // 作者和来源
                    if !isLoadingDetail, loadError == nil {
                        if let author = fullDetail?.author, !author.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill").displaySymbolFont(11)
                                Text("作者：\(author)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                        if let source = fullDetail?.source, !source.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link").displaySymbolFont(11)
                                Text("来源：\(source)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 加载状态
                    if isLoadingDetail {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("正在加载完整内容...").displayFont(12).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .displayFont(13)
                                    .foregroundStyle(.orange)
                            }
                            .padding(16)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            // 加载失败兜底摘要同样展示统计
                            if !teacher.summary.isEmpty {
                                ArticleReadingStatsText(cachedID: teacher.title, plainText: teacher.summary)
                            }

                            Text(teacher.summary)
                                .displayFont(16).lineSpacing(10)
                                .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                            Button {
                                retryLoading()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("重新加载", systemImage: "arrow.clockwise")
                                        .displayLabelFont(14, weight: .medium)
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else {
                        let content = fullDetail?.plainTextContent ?? teacher.summary
                        Text(content)
                            .displayFont(16).lineSpacing(10)
                            .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                        if let images = fullDetail?.images, !images.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Divider()
                                Label("图片（\(images.count)张）", systemImage: "photo.on.rectangle")
                                    .displayLabelFont(14, weight: .semibold)
                                    .foregroundStyle(.primary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                                            SJZCachedImage(url: URL(string: img.url)) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                case .failure:
                                                    Color.gray.opacity(0.08)
                                                default:
                                                    ShimmerView()
                                                }
                                            }
                                            .frame(width: 160, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .onTapGesture {
                                                imageViewerPayload = SJZImageGalleryPayload.make(
                                                    images: images, tappedIndex: idx, source: "grid")
                                                LogManager.shared.debugLog("imageViewer", "查看图片（图集网格）", context: [
                                                    "index": "\(idx + 1)/\(images.count)",
                                                    "url": img.url
                                                ])
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .opacity(contentAppear ? 1 : 0)
                .offset(y: contentAppear ? 0 : 20)
            }
        }
        .navigationTitle("教师风采").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // 收藏按钮
                    Button {
                        let wasBookmarked = bookmarkManager.isBookmarked(bookmarkKey)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            bookmarkManager.toggleBookmark(
                                articleId: teacher.articleId ?? "",
                                title: teacher.title,
                                date: teacher.date ?? "",
                                category: "教师风采",
                                summary: teacherBodyText,
                                imageUrl: teacher.imageUrl
                            )
                        }
                        LogManager.shared.info("ui", "教师风采收藏操作", context: [
                            "articleId": teacher.articleId ?? "-",
                            "title": teacher.title,
                            "action": wasBookmarked ? "取消收藏" : "收藏"
                        ])
                    } label: {
                        Image(systemName: bookmarkManager.isBookmarked(bookmarkKey) ? "bookmark.fill" : "bookmark")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(bookmarkManager.isBookmarked(bookmarkKey) ? Color.sjzGold : .primary)
                    }
                    .contentShape(Rectangle())

                    // 分享按钮
                    Button {
                        showSharePicker = true
                        LogManager.shared.info("ui", "教师风采分享按钮点击", context: [
                            "articleId": teacher.articleId ?? "-",
                            "title": teacher.title
                        ])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(14, weight: .medium)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .confirmationDialog("选择分享格式", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享到微信") { showWeChatShare = true }
            Button("长图分享到微信") {
                longImageDestination = .weChat
                startLongImageGeneration()
            }
            Button("纯链接") { selectedShareFormat = .link }
            Button("Markdown文章") { selectedShareFormat = .markdown }
            Button("标题+正文文本") { selectedShareFormat = .fullText }
            Button("长图") {
                longImageDestination = .system
                startLongImageGeneration()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .sheet(item: $weChatLongImagePayload) { payload in
            WeChatLongImageShareMenu(payload: payload)
                .sjzPresentationChrome()
        }
        .sheet(item: $selectedShareFormat) { format in
            ShareSheet(items: teacherShareItems(format, url: teacherArticleURL, title: teacher.title, body: teacherBodyText))
        }
        .overlay {
            if isGeneratingLongImage {
                longImageOverlay
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                contentAppear = true
            }
        }
        .task {
            await loadDetail()
        }
        .fullScreenCover(item: $imageViewerPayload) { payload in
            FullScreenImageView(payload: payload, fallbackTitle: teacher.title)
                .sjzPresentationChrome()
        }
    }

    /// 教师风采收藏键：与 BookmarkManager 内部键规则一致（articleId 为空时用标题+日期）
    private var bookmarkKey: String {
        teacher.articleId ?? teacher.title + (teacher.date ?? "")
    }

    /// 教师风采正文文本（加载完成后优先全文，否则摘要兜底）
    private var teacherBodyText: String {
        if let detail = fullDetail, !detail.plainTextContent.isEmpty {
            return detail.plainTextContent
        }
        return teacher.summary
    }

    /// 教师风采文章详情页 URL（用于分享）
    private var teacherArticleURL: String {
        if let articleId = teacher.articleId, !articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(articleId)"
        }
        return SchoolInfo.website
    }

    /// 微信分享载荷（标题 + 正文摘要 + 链接 + 缩略图；微信限制由 WeChatService 统一裁剪）
    private var weChatSharePayload: WeChatSharePayload {
        WeChatSharePayload(
            title: teacher.title,
            description: teacherBodyText,
            urlString: teacherArticleURL,
            thumbImageURL: teacher.imageUrl
        )
    }

    /// 根据分享格式生成分享内容
    private func teacherShareItems(_ format: ShareFormat, url: String, title: String, body: String) -> [Any] {
        switch format {
        case .link:
            return [URL(string: url) as Any]
        case .markdown:
            var md = "# \(title)\n\n"
            if let date = teacher.date, !date.isEmpty {
                md += "> 日期：\(date)\n\n"
            }
            md += "---\n\n\(body)\n\n[阅读原文](\(url))"
            return [md]
        case .fullText:
            let summary = body.count > 200 ? String(body.prefix(200)) + "..." : body
            return ["\(title)\n\n\(summary)\n\n阅读原文：\(url)"]
        case .longImage:
            return []
        }
    }

    // MARK: - 长图生成

    /// 长图生成加载遮罩（与新闻详情同款）
    private var longImageOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在生成文章长图...")
                    .displayFont(16, weight: .medium)
                    .foregroundStyle(.white)
                Text("下载图片并渲染中")
                    .displayFont(13)
                    .foregroundStyle(.white.opacity(0.7))
                if let error = longImageError {
                    VStack(spacing: 12) {
                        Text(error)
                            .displayFont(13)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("关闭") {
                            isGeneratingLongImage = false
                            longImageError = nil
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.white.opacity(0.2), in: Capsule())
                    }
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
    }

    /// 启动长图生成流程
    private func startLongImageGeneration() {
        isGeneratingLongImage = true
        longImageError = nil
        Task {
            await generateLongImage()
        }
    }

    /// 异步下载文章图片并生成长图，完成后直接 present 系统分享面板
    private func generateLongImage() async {
        let articleURL = teacherArticleURL
        let title = teacher.title
        let body = teacherBodyText

        // 构建元数据字符串
        var metaParts: [String] = []
        metaParts.append("教师风采")
        if let date = teacher.date, !date.isEmpty { metaParts.append(date) }
        if let author = fullDetail?.author, !author.isEmpty { metaParts.append("作者：\(author)") }
        if let source = fullDetail?.source, !source.isEmpty { metaParts.append("来源：\(source)") }
        let metadata = metaParts.joined(separator: " · ")

        // 加载长图素材（压缩数据 + 尺寸元数据；渲染时按需缩略解码——多图文章的内存防线）
        let imageAssets = await ArticleLongImageLoader.loadAll(fullDetail?.images ?? [], tag: "teacher_detail")

        // 渲染长图
        let renderer = ArticleLongImageRenderer(
            title: title,
            metadata: metadata,
            content: body,
            images: imageAssets,
            articleURL: articleURL,
            tag: "teacher_detail"
        )

        await MainActor.run {
            LogManager.shared.debugLog("longimage", "开始生成教师风采长图", context: [
                "title": title, "images": "\(imageAssets.count)"
            ])
            let renderedImage = renderer.render()
            guard let renderedImage else {
                // 保持 isGeneratingLongImage = true，让 overlay 显示错误信息
                longImageError = "长图生成失败，请重试"
                return
            }
            isGeneratingLongImage = false
            // 等 confirmationDialog 关闭动画完成后再 present 分享面板（避免 UIActivityViewController 静默失败）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                switch longImageDestination {
                case .system:
                    presentLongImageShare(image: renderedImage, title: title)
                case .weChat:
                    // 微信图片消息（WXImageObject）：弹出场景菜单（好友 / 朋友圈 / 收藏）
                    weChatLongImagePayload = WeChatLongImagePayload(image: renderedImage, title: title, entry: "teacher_detail")
                }
            }
        }
    }

    /// 直接以 UIKit 模态方式呈现 UIActivityViewController（绕过 SwiftUI sheet 嵌套，微信分享兼容）
    private func presentLongImageShare(image: UIImage, title: String) {
        // 交付前兜底校验：纯色 / 黑图绝不落盘分享（渲染层已校验；此处防编码链路异常）
        guard !SJZImageIntegrity.isLikelyBlank(image) else {
            longImageError = "长图生成异常（画布纯色），请重试"
            isGeneratingLongImage = true
            LogManager.shared.error("longimage", "长图交付校验拦截（画布纯色）", context: [
                "title": title,
                "pixel": SJZImageIntegrity.pixelSizeText(of: image)
            ])
            return
        }
        // 交付编码：分享扩展（微信等）内存与体积预算有限（约 120MB）——按「≤16MP / ≤10MB」编码，
        // 否则扩展会被系统终止（2026-09-28 现场：微信「加载中 → 闪回 App」）；产物含纯色 / 黑图校验
        guard let encoded = WeChatImageEncoder.encode(
            image,
            maxBytes: WeChatImageEncoder.systemShareMaxBytes,
            maxPixels: WeChatImageEncoder.systemShareMaxPixels
        ) else {
            longImageError = "图片编码失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图 JPEG 编码失败", context: ["title": title])
            return
        }
        let jpegData = encoded.data
        LogManager.shared.info("longimage", "长图分享文件编码完成", context: [
            "title": title,
            "pixel": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
            "quality": String(format: "%.2f", encoded.quality),
            "scale": String(format: "%.2f", encoded.scale),
            "bytes": "\(encoded.data.count)"
        ])

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(20)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sxjzit_\(safeTitle)_\(UUID().uuidString.prefix(6)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: fileURL)
        } catch {
            longImageError = "图片保存失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图临时文件写入失败", context: ["title": title])
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            longImageError = "无法获取窗口"
            isGeneratingLongImage = true
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // 仅传递文件 URL 和标题文本（微信 Share Extension 通过文件 URL 读取图片）
        let activityItems: [Any] = [fileURL, title]
        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]
        activityVC.completionWithItemsHandler = { [fileURL] _, completed, _, error in
            // 分享扩展（微信等）读取大图较慢，且本回调在「用户选择动作」时即触发——
            // 绝不能立即删除（现场：微信「加载中 → 闪回 App」）；交由共享中心延迟 5 分钟清理
            SJZShareFileCenter.scheduleCleanup(fileURL)
            if !completed {
                // 分享未完成（系统扩展可能因体积 / 尺寸限制中止）：记录可判别数据 + 给出可操作替代路径
                WeChatService.shared.showBanner("微信未完成分享，可改用「分享 → 长图分享到微信」", kind: .info)
                LogManager.shared.warning("longimage", "长图分享未完成（系统扩展可能中止）", context: [
                    "pixel": SJZImageIntegrity.pixelSizeText(of: image),
                    "bytes": "\(jpegData.count)",
                    "error": error?.localizedDescription ?? "none"
                ])
            }
            if let error = error {
                LogManager.shared.error("ui", "教师风采长图分享失败", context: ["error": error.localizedDescription])
            } else {
                LogManager.shared.info("ui", "教师风采长图分享结束", context: ["completed": "\(completed)"])
            }
        }
        topVC.present(activityVC, animated: true)
    }

    /// 下载单张图片（统一走 SJZImageKit：缓存复用 + 进度通道 + 协议层 Referer）
    private func loadDetail() async {
        guard let articleId = teacher.articleId else {
            isLoadingDetail = false
            return
        }
        if fullDetail != nil && cacheManager.isCacheEnabled {
            LogManager.shared.debugLog("ui", "缓存模式下教师详情已加载，跳过重复请求", context: [
                "articleId": articleId, "title": teacher.title
            ])
            return
        }
        isLoadingDetail = true
        loadError = nil
        LogManager.shared.info("ui", "开始加载教师风采详情", context: ["articleId": articleId, "title": teacher.title])
        do {
            let detail = try await DataService.shared.loadArticleFullDetail(articleId: articleId)
            fullDetail = detail
            LogManager.shared.info("ui", "教师风采详情加载成功", context: ["articleId": articleId, "images": "\(detail.images.count)"])
        } catch {
            loadError = "文章详情加载失败，请检查网络连接后重试"
            LogManager.shared.error("ui", "教师风采详情加载失败", context: ["articleId": articleId, "error": error.localizedDescription])
        }
        isLoadingDetail = false
    }

    private func retryLoading() {
        Task {
            await loadDetail()
        }
    }

    private var teacherDetailPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzIndigo.opacity(0.06), Color.sjzLightBlue],
            startPoint: .top, endPoint: .bottom)
        .frame(height: 300)
        .overlay {
            Image(systemName: "person.text.rectangle.fill")
                .displaySymbolFont(70).foregroundStyle(Color.sjzIndigo.opacity(0.06))
        }
    }
}

// MARK: - 学生故事详情

struct StoryDetailView: View {
    let story: StudentStory
    /// 看图载荷（item 式呈现：根治「先显示第一张」的陈旧快照 + 支持左右翻页）
    @State private var imageViewerPayload: SJZImageGalleryPayload?
    @State private var contentAppear = false
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoadingDetail = true
    @State private var loadError: String?
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var showSharePicker = false
    @State private var selectedShareFormat: ShareFormat?
    @State private var showWeChatShare = false
    @State private var isGeneratingLongImage = false
    /// 长图分享目标（系统分享面板 / 微信图片消息；由分享面板入口设置）
    @State private var longImageDestination: LongImageDestination = .system
    /// 微信长图分享载荷（非空 → 弹出长图分享菜单）
    @State private var weChatLongImagePayload: WeChatLongImagePayload?
    @State private var longImageError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let imgUrl = story.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url, maxPixel: 1440) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 340)
                                .onTapGesture {
                                    imageViewerPayload = SJZImageGalleryPayload.single(url: url, source: "header")
                                    LogManager.shared.debugLog("imageViewer", "查看图片（头图）", context: [
                                        "url": url.lastPathComponent
                                    ])
                                }
                        case .failure:
                            storyDetailPlaceholder
                        default:
                            ShimmerView().frame(height: 340)
                        }
                    }
                } else {
                    storyDetailPlaceholder
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text(story.title)
                        .displayFont(24, weight: .bold)
                    if let date = story.date, !date.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .displaySymbolFont(12)
                            Text(date)
                                .displayFont(14)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !isLoadingDetail, let detail = fullDetail {
                        let statsText = detail.plainTextContent.isEmpty
                            ? detail.content.strippingHTMLTags()
                            : detail.plainTextContent
                        if !statsText.isEmpty {
                            ArticleReadingStatsText(
                                cachedID: story.title,
                                plainText: statsText,
                                imageCount: detail.images.count
                            )
                        }
                    }

                    // 作者和来源
                    if !isLoadingDetail, loadError == nil {
                        if let author = fullDetail?.author, !author.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill").displaySymbolFont(11)
                                Text("作者：\(author)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                        if let source = fullDetail?.source, !source.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link").displaySymbolFont(11)
                                Text("来源：\(source)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 加载状态
                    if isLoadingDetail {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("正在加载完整内容...").displayFont(12).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else if let error = loadError {
                        // 加载失败：显示摘要 + 错误提示 + 重试按钮
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .displayFont(13)
                                    .foregroundStyle(.orange)
                            }
                            .padding(16)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            // 加载失败兜底摘要同样展示统计
                            if !story.summary.isEmpty {
                                ArticleReadingStatsText(cachedID: story.title, plainText: story.summary)
                            }

                            Text(story.summary)
                                .displayFont(16).lineSpacing(10)
                                .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                            Button {
                                retryLoading()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("重新加载", systemImage: "arrow.clockwise")
                                        .displayLabelFont(14, weight: .medium)
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else {
                        // 完整正文内容
                        let content = fullDetail?.plainTextContent ?? story.summary
                        Text(content)
                            .displayFont(16).lineSpacing(10)
                            .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                        // 图片画廊
                        if let images = fullDetail?.images, !images.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Divider()
                                Label("图片（\(images.count)张）", systemImage: "photo.on.rectangle")
                                    .displayLabelFont(14, weight: .semibold)
                                    .foregroundStyle(.primary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                                            SJZCachedImage(url: URL(string: img.url)) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                case .failure:
                                                    Color.gray.opacity(0.08)
                                                default:
                                                    ShimmerView()
                                                }
                                            }
                                            .frame(width: 160, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .onTapGesture {
                                                imageViewerPayload = SJZImageGalleryPayload.make(
                                                    images: images, tappedIndex: idx, source: "grid")
                                                LogManager.shared.debugLog("imageViewer", "查看图片（图集网格）", context: [
                                                    "index": "\(idx + 1)/\(images.count)",
                                                    "url": img.url
                                                ])
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .opacity(contentAppear ? 1 : 0)
                .offset(y: contentAppear ? 0 : 20)
            }
        }
        .navigationTitle("学生故事").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // 收藏按钮
                    Button {
                        let wasBookmarked = bookmarkManager.isBookmarked(bookmarkKey)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            bookmarkManager.toggleBookmark(
                                articleId: story.articleId ?? "",
                                title: story.title,
                                date: story.date ?? "",
                                category: "学生故事",
                                summary: storyBodyText,
                                imageUrl: story.imageUrl
                            )
                        }
                        LogManager.shared.info("ui", "学生故事收藏操作", context: [
                            "articleId": story.articleId ?? "-",
                            "title": story.title,
                            "action": wasBookmarked ? "取消收藏" : "收藏"
                        ])
                    } label: {
                        Image(systemName: bookmarkManager.isBookmarked(bookmarkKey) ? "bookmark.fill" : "bookmark")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(bookmarkManager.isBookmarked(bookmarkKey) ? Color.sjzGold : .primary)
                    }
                    .contentShape(Rectangle())

                    // 分享按钮
                    Button {
                        showSharePicker = true
                        LogManager.shared.info("ui", "学生故事分享按钮点击", context: [
                            "articleId": story.articleId ?? "-",
                            "title": story.title
                        ])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(14, weight: .medium)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .confirmationDialog("选择分享格式", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享到微信") { showWeChatShare = true }
            Button("长图分享到微信") {
                longImageDestination = .weChat
                startLongImageGeneration()
            }
            Button("纯链接") { selectedShareFormat = .link }
            Button("Markdown文章") { selectedShareFormat = .markdown }
            Button("标题+正文文本") { selectedShareFormat = .fullText }
            Button("长图") {
                longImageDestination = .system
                startLongImageGeneration()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .sheet(item: $weChatLongImagePayload) { payload in
            WeChatLongImageShareMenu(payload: payload)
                .sjzPresentationChrome()
        }
        .sheet(item: $selectedShareFormat) { format in
            ShareSheet(items: storyShareItems(format, url: storyArticleURL, title: story.title, body: storyBodyText))
        }
        .overlay {
            if isGeneratingLongImage {
                longImageOverlay
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                contentAppear = true
            }
        }
        .task {
            await loadDetail()
        }
        .fullScreenCover(item: $imageViewerPayload) { payload in
            FullScreenImageView(payload: payload, fallbackTitle: story.title)
                .sjzPresentationChrome()
        }
    }

    /// 学生故事收藏键：与 BookmarkManager 内部键规则一致（articleId 为空时用标题+日期）
    private var bookmarkKey: String {
        story.articleId ?? story.title + (story.date ?? "")
    }

    /// 学生故事正文文本（加载完成后优先全文，否则摘要兜底）
    private var storyBodyText: String {
        if let detail = fullDetail, !detail.plainTextContent.isEmpty {
            return detail.plainTextContent
        }
        return story.summary
    }

    /// 学生故事文章详情页 URL（用于分享）
    private var storyArticleURL: String {
        if let articleId = story.articleId, !articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(articleId)"
        }
        return SchoolInfo.website
    }

    /// 微信分享载荷（标题 + 正文摘要 + 链接 + 缩略图；微信限制由 WeChatService 统一裁剪）
    private var weChatSharePayload: WeChatSharePayload {
        WeChatSharePayload(
            title: story.title,
            description: storyBodyText,
            urlString: storyArticleURL,
            thumbImageURL: story.imageUrl
        )
    }

    /// 根据分享格式生成分享内容
    private func storyShareItems(_ format: ShareFormat, url: String, title: String, body: String) -> [Any] {
        switch format {
        case .link:
            return [URL(string: url) as Any]
        case .markdown:
            var md = "# \(title)\n\n"
            if let date = story.date, !date.isEmpty {
                md += "> 日期：\(date)\n\n"
            }
            md += "---\n\n\(body)\n\n[阅读原文](\(url))"
            return [md]
        case .fullText:
            let summary = body.count > 200 ? String(body.prefix(200)) + "..." : body
            return ["\(title)\n\n\(summary)\n\n阅读原文：\(url)"]
        case .longImage:
            return []
        }
    }

    // MARK: - 长图生成

    /// 长图生成加载遮罩（与新闻详情同款）
    private var longImageOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在生成文章长图...")
                    .displayFont(16, weight: .medium)
                    .foregroundStyle(.white)
                Text("下载图片并渲染中")
                    .displayFont(13)
                    .foregroundStyle(.white.opacity(0.7))
                if let error = longImageError {
                    VStack(spacing: 12) {
                        Text(error)
                            .displayFont(13)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("关闭") {
                            isGeneratingLongImage = false
                            longImageError = nil
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.white.opacity(0.2), in: Capsule())
                    }
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
    }

    /// 启动长图生成流程
    private func startLongImageGeneration() {
        isGeneratingLongImage = true
        longImageError = nil
        Task {
            await generateLongImage()
        }
    }

    /// 异步下载文章图片并生成长图，完成后直接 present 系统分享面板
    private func generateLongImage() async {
        let articleURL = storyArticleURL
        let title = story.title
        let body = storyBodyText

        // 构建元数据字符串
        var metaParts: [String] = []
        metaParts.append("学生故事")
        if let date = story.date, !date.isEmpty { metaParts.append(date) }
        if let author = fullDetail?.author, !author.isEmpty { metaParts.append("作者：\(author)") }
        if let source = fullDetail?.source, !source.isEmpty { metaParts.append("来源：\(source)") }
        let metadata = metaParts.joined(separator: " · ")

        // 加载长图素材（压缩数据 + 尺寸元数据；渲染时按需缩略解码——多图文章的内存防线）
        let imageAssets = await ArticleLongImageLoader.loadAll(fullDetail?.images ?? [], tag: "story_detail")

        // 渲染长图
        let renderer = ArticleLongImageRenderer(
            title: title,
            metadata: metadata,
            content: body,
            images: imageAssets,
            articleURL: articleURL,
            tag: "story_detail"
        )

        await MainActor.run {
            LogManager.shared.debugLog("longimage", "开始生成学生故事长图", context: [
                "title": title, "images": "\(imageAssets.count)"
            ])
            let renderedImage = renderer.render()
            guard let renderedImage else {
                // 保持 isGeneratingLongImage = true，让 overlay 显示错误信息
                longImageError = "长图生成失败，请重试"
                return
            }
            isGeneratingLongImage = false
            // 等 confirmationDialog 关闭动画完成后再 present 分享面板（避免 UIActivityViewController 静默失败）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                switch longImageDestination {
                case .system:
                    presentLongImageShare(image: renderedImage, title: title)
                case .weChat:
                    // 微信图片消息（WXImageObject）：弹出场景菜单（好友 / 朋友圈 / 收藏）
                    weChatLongImagePayload = WeChatLongImagePayload(image: renderedImage, title: title, entry: "story_detail")
                }
            }
        }
    }

    /// 直接以 UIKit 模态方式呈现 UIActivityViewController（绕过 SwiftUI sheet 嵌套，微信分享兼容）
    private func presentLongImageShare(image: UIImage, title: String) {
        // 交付前兜底校验：纯色 / 黑图绝不落盘分享（渲染层已校验；此处防编码链路异常）
        guard !SJZImageIntegrity.isLikelyBlank(image) else {
            longImageError = "长图生成异常（画布纯色），请重试"
            isGeneratingLongImage = true
            LogManager.shared.error("longimage", "长图交付校验拦截（画布纯色）", context: [
                "title": title,
                "pixel": SJZImageIntegrity.pixelSizeText(of: image)
            ])
            return
        }
        // 交付编码：分享扩展（微信等）内存与体积预算有限（约 120MB）——按「≤16MP / ≤10MB」编码，
        // 否则扩展会被系统终止（2026-09-28 现场：微信「加载中 → 闪回 App」）；产物含纯色 / 黑图校验
        guard let encoded = WeChatImageEncoder.encode(
            image,
            maxBytes: WeChatImageEncoder.systemShareMaxBytes,
            maxPixels: WeChatImageEncoder.systemShareMaxPixels
        ) else {
            longImageError = "图片编码失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图 JPEG 编码失败", context: ["title": title])
            return
        }
        let jpegData = encoded.data
        LogManager.shared.info("longimage", "长图分享文件编码完成", context: [
            "title": title,
            "pixel": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
            "quality": String(format: "%.2f", encoded.quality),
            "scale": String(format: "%.2f", encoded.scale),
            "bytes": "\(encoded.data.count)"
        ])

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(20)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sxjzit_\(safeTitle)_\(UUID().uuidString.prefix(6)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: fileURL)
        } catch {
            longImageError = "图片保存失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图临时文件写入失败", context: ["title": title])
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            longImageError = "无法获取窗口"
            isGeneratingLongImage = true
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // 仅传递文件 URL 和标题文本（微信 Share Extension 通过文件 URL 读取图片）
        let activityItems: [Any] = [fileURL, title]
        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]
        activityVC.completionWithItemsHandler = { [fileURL] _, completed, _, error in
            // 分享扩展（微信等）读取大图较慢，且本回调在「用户选择动作」时即触发——
            // 绝不能立即删除（现场：微信「加载中 → 闪回 App」）；交由共享中心延迟 5 分钟清理
            SJZShareFileCenter.scheduleCleanup(fileURL)
            if !completed {
                // 分享未完成（系统扩展可能因体积 / 尺寸限制中止）：记录可判别数据 + 给出可操作替代路径
                WeChatService.shared.showBanner("微信未完成分享，可改用「分享 → 长图分享到微信」", kind: .info)
                LogManager.shared.warning("longimage", "长图分享未完成（系统扩展可能中止）", context: [
                    "pixel": SJZImageIntegrity.pixelSizeText(of: image),
                    "bytes": "\(jpegData.count)",
                    "error": error?.localizedDescription ?? "none"
                ])
            }
            if let error = error {
                LogManager.shared.error("ui", "学生故事长图分享失败", context: ["error": error.localizedDescription])
            } else {
                LogManager.shared.info("ui", "学生故事长图分享结束", context: ["completed": "\(completed)"])
            }
        }
        topVC.present(activityVC, animated: true)
    }

    /// 下载单张图片（统一走 SJZImageKit：缓存复用 + 进度通道 + 协议层 Referer）
    private func loadDetail() async {
        guard let articleId = story.articleId else {
            isLoadingDetail = false
            return
        }
        if fullDetail != nil && cacheManager.isCacheEnabled {
            LogManager.shared.debugLog("ui", "缓存模式下学生故事详情已加载，跳过重复请求", context: [
                "articleId": articleId, "title": story.title
            ])
            return
        }
        isLoadingDetail = true
        loadError = nil
        LogManager.shared.info("ui", "开始加载学生故事详情", context: ["articleId": articleId, "title": story.title])
        do {
            let detail = try await DataService.shared.loadArticleFullDetail(articleId: articleId)
            fullDetail = detail
            LogManager.shared.info("ui", "学生故事详情加载成功", context: ["articleId": articleId, "images": "\(detail.images.count)"])
        } catch {
            loadError = "文章详情加载失败，请检查网络连接后重试"
            LogManager.shared.error("ui", "学生故事详情加载失败", context: ["articleId": articleId, "error": error.localizedDescription])
        }
        isLoadingDetail = false
    }

    private func retryLoading() {
        Task {
            await loadDetail()
        }
    }

    private var storyDetailPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzPurple.opacity(0.05), Color.sjzLight],
            startPoint: .top, endPoint: .bottom)
        .frame(height: 300)
        .overlay {
            Image(systemName: "person.2.fill")
                .displaySymbolFont(70).foregroundStyle(Color.sjzPurple.opacity(0.06))
        }
    }
}

// MARK: - 校园活动详情

struct ActivityDetailView: View {
    let activity: CampusActivity
    /// 看图载荷（item 式呈现：根治「先显示第一张」的陈旧快照 + 支持左右翻页）
    @State private var imageViewerPayload: SJZImageGalleryPayload?
    @State private var contentAppear = false
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoadingDetail = true
    @State private var loadError: String?
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var showSharePicker = false
    @State private var selectedShareFormat: ShareFormat?
    @State private var showWeChatShare = false
    @State private var isGeneratingLongImage = false
    /// 长图分享目标（系统分享面板 / 微信图片消息；由分享面板入口设置）
    @State private var longImageDestination: LongImageDestination = .system
    /// 微信长图分享载荷（非空 → 弹出长图分享菜单）
    @State private var weChatLongImagePayload: WeChatLongImagePayload?
    @State private var longImageError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let imgUrl = activity.imageUrl, let url = URL(string: imgUrl) {
                    SJZCachedImage(url: url, maxPixel: 1440) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 340)
                                .onTapGesture {
                                    imageViewerPayload = SJZImageGalleryPayload.single(url: url, source: "header")
                                    LogManager.shared.debugLog("imageViewer", "查看图片（头图）", context: [
                                        "url": url.lastPathComponent
                                    ])
                                }
                        case .failure:
                            activityDetailPlaceholder
                        default:
                            ShimmerView().frame(height: 340)
                        }
                    }
                } else {
                    activityDetailPlaceholder
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text(activity.title)
                        .displayFont(24, weight: .bold)
                    HStack(spacing: 12) {
                        if let date = activity.date, !date.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar")
                                    .displaySymbolFont(12)
                                Text(date)
                                    .displayFont(14)
                            }
                            .foregroundStyle(.secondary)
                        }
                        if let en = activity.englishTitle, !en.isEmpty {
                            Text(en)
                                .displayFont(14)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !isLoadingDetail, let detail = fullDetail {
                        let statsText = detail.plainTextContent.isEmpty
                            ? detail.content.strippingHTMLTags()
                            : detail.plainTextContent
                        if !statsText.isEmpty {
                            ArticleReadingStatsText(
                                cachedID: activity.title,
                                plainText: statsText,
                                imageCount: detail.images.count
                            )
                        }
                    }

                    // 作者和来源
                    if !isLoadingDetail, loadError == nil {
                        if let author = fullDetail?.author, !author.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill").displaySymbolFont(11)
                                Text("作者：\(author)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                        if let source = fullDetail?.source, !source.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link").displaySymbolFont(11)
                                Text("来源：\(source)")
                            }
                            .displayFont(12).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 加载状态
                    if isLoadingDetail {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("正在加载完整内容...").displayFont(12).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .displayFont(13)
                                    .foregroundStyle(.orange)
                            }
                            .padding(16)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            // 加载失败兜底摘要同样展示统计
                            if !activity.summary.isEmpty {
                                ArticleReadingStatsText(cachedID: activity.title, plainText: activity.summary)
                            }

                            Text(activity.summary)
                                .displayFont(16).lineSpacing(10)
                                .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                            Button {
                                retryLoading()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("重新加载", systemImage: "arrow.clockwise")
                                        .displayLabelFont(14, weight: .medium)
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .background(Color.sjzAccent, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else {
                        let content = fullDetail?.plainTextContent ?? activity.summary
                        Text(content)
                            .displayFont(16).lineSpacing(10)
                            .foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                        if let images = fullDetail?.images, !images.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Divider()
                                Label("图片（\(images.count)张）", systemImage: "photo.on.rectangle")
                                    .displayLabelFont(14, weight: .semibold)
                                    .foregroundStyle(.primary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                                            SJZCachedImage(url: URL(string: img.url)) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                case .failure:
                                                    Color.gray.opacity(0.08)
                                                default:
                                                    ShimmerView()
                                                }
                                            }
                                            .frame(width: 160, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .onTapGesture {
                                                imageViewerPayload = SJZImageGalleryPayload.make(
                                                    images: images, tappedIndex: idx, source: "grid")
                                                LogManager.shared.debugLog("imageViewer", "查看图片（图集网格）", context: [
                                                    "index": "\(idx + 1)/\(images.count)",
                                                    "url": img.url
                                                ])
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .opacity(contentAppear ? 1 : 0)
                .offset(y: contentAppear ? 0 : 20)
            }
        }
        .navigationTitle("校园活动").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // 收藏按钮
                    Button {
                        let wasBookmarked = bookmarkManager.isBookmarked(bookmarkKey)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            bookmarkManager.toggleBookmark(
                                articleId: activity.articleId ?? "",
                                title: activity.title,
                                date: activity.date ?? "",
                                category: "校园活动",
                                summary: activityBodyText,
                                imageUrl: activity.imageUrl
                            )
                        }
                        LogManager.shared.info("ui", "校园活动收藏操作", context: [
                            "articleId": activity.articleId ?? "-",
                            "title": activity.title,
                            "action": wasBookmarked ? "取消收藏" : "收藏"
                        ])
                    } label: {
                        Image(systemName: bookmarkManager.isBookmarked(bookmarkKey) ? "bookmark.fill" : "bookmark")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(bookmarkManager.isBookmarked(bookmarkKey) ? Color.sjzGold : .primary)
                    }
                    .contentShape(Rectangle())

                    // 分享按钮
                    Button {
                        showSharePicker = true
                        LogManager.shared.info("ui", "校园活动分享按钮点击", context: [
                            "articleId": activity.articleId ?? "-",
                            "title": activity.title
                        ])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(14, weight: .medium)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .confirmationDialog("选择分享格式", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享到微信") { showWeChatShare = true }
            Button("长图分享到微信") {
                longImageDestination = .weChat
                startLongImageGeneration()
            }
            Button("纯链接") { selectedShareFormat = .link }
            Button("Markdown文章") { selectedShareFormat = .markdown }
            Button("标题+正文文本") { selectedShareFormat = .fullText }
            Button("长图") {
                longImageDestination = .system
                startLongImageGeneration()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .sheet(item: $weChatLongImagePayload) { payload in
            WeChatLongImageShareMenu(payload: payload)
                .sjzPresentationChrome()
        }
        .sheet(item: $selectedShareFormat) { format in
            ShareSheet(items: activityShareItems(format, url: activityArticleURL, title: activity.title, body: activityBodyText))
        }
        .overlay {
            if isGeneratingLongImage {
                longImageOverlay
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                contentAppear = true
            }
        }
        .task {
            await loadDetail()
        }
        .fullScreenCover(item: $imageViewerPayload) { payload in
            FullScreenImageView(payload: payload, fallbackTitle: activity.title)
                .sjzPresentationChrome()
        }
    }

    /// 校园活动收藏键：与 BookmarkManager 内部键规则一致（articleId 为空时用标题+日期）
    private var bookmarkKey: String {
        activity.articleId ?? activity.title + (activity.date ?? "")
    }

    /// 校园活动正文文本（加载完成后优先全文，否则摘要兜底）
    private var activityBodyText: String {
        if let detail = fullDetail, !detail.plainTextContent.isEmpty {
            return detail.plainTextContent
        }
        return activity.summary
    }

    /// 校园活动文章详情页 URL（用于分享）
    private var activityArticleURL: String {
        if let articleId = activity.articleId, !articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(articleId)"
        }
        return SchoolInfo.website
    }

    /// 微信分享载荷（标题 + 正文摘要 + 链接 + 缩略图；微信限制由 WeChatService 统一裁剪）
    private var weChatSharePayload: WeChatSharePayload {
        WeChatSharePayload(
            title: activity.title,
            description: activityBodyText,
            urlString: activityArticleURL,
            thumbImageURL: activity.imageUrl
        )
    }

    /// 根据分享格式生成分享内容
    private func activityShareItems(_ format: ShareFormat, url: String, title: String, body: String) -> [Any] {
        switch format {
        case .link:
            return [URL(string: url) as Any]
        case .markdown:
            var md = "# \(title)\n\n"
            if let date = activity.date, !date.isEmpty {
                md += "> 日期：\(date)\n\n"
            }
            md += "---\n\n\(body)\n\n[阅读原文](\(url))"
            return [md]
        case .fullText:
            let summary = body.count > 200 ? String(body.prefix(200)) + "..." : body
            return ["\(title)\n\n\(summary)\n\n阅读原文：\(url)"]
        case .longImage:
            return []
        }
    }

    // MARK: - 长图生成

    /// 长图生成加载遮罩（与新闻详情同款）
    private var longImageOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在生成文章长图...")
                    .displayFont(16, weight: .medium)
                    .foregroundStyle(.white)
                Text("下载图片并渲染中")
                    .displayFont(13)
                    .foregroundStyle(.white.opacity(0.7))
                if let error = longImageError {
                    VStack(spacing: 12) {
                        Text(error)
                            .displayFont(13)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("关闭") {
                            isGeneratingLongImage = false
                            longImageError = nil
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.white.opacity(0.2), in: Capsule())
                    }
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 40)
        }
    }

    /// 启动长图生成流程
    private func startLongImageGeneration() {
        isGeneratingLongImage = true
        longImageError = nil
        Task {
            await generateLongImage()
        }
    }

    /// 异步下载文章图片并生成长图，完成后直接 present 系统分享面板
    private func generateLongImage() async {
        let articleURL = activityArticleURL
        let title = activity.title
        let body = activityBodyText

        // 构建元数据字符串
        var metaParts: [String] = []
        metaParts.append("校园活动")
        if let date = activity.date, !date.isEmpty { metaParts.append(date) }
        if let author = fullDetail?.author, !author.isEmpty { metaParts.append("作者：\(author)") }
        if let source = fullDetail?.source, !source.isEmpty { metaParts.append("来源：\(source)") }
        let metadata = metaParts.joined(separator: " · ")

        // 加载长图素材（压缩数据 + 尺寸元数据；渲染时按需缩略解码——多图文章的内存防线）
        let imageAssets = await ArticleLongImageLoader.loadAll(fullDetail?.images ?? [], tag: "activity_detail")

        // 渲染长图
        let renderer = ArticleLongImageRenderer(
            title: title,
            metadata: metadata,
            content: body,
            images: imageAssets,
            articleURL: articleURL,
            tag: "activity_detail"
        )

        await MainActor.run {
            LogManager.shared.debugLog("longimage", "开始生成校园活动长图", context: [
                "title": title, "images": "\(imageAssets.count)"
            ])
            let renderedImage = renderer.render()
            guard let renderedImage else {
                // 保持 isGeneratingLongImage = true，让 overlay 显示错误信息
                longImageError = "长图生成失败，请重试"
                return
            }
            isGeneratingLongImage = false
            // 等 confirmationDialog 关闭动画完成后再 present 分享面板（避免 UIActivityViewController 静默失败）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                switch longImageDestination {
                case .system:
                    presentLongImageShare(image: renderedImage, title: title)
                case .weChat:
                    // 微信图片消息（WXImageObject）：弹出场景菜单（好友 / 朋友圈 / 收藏）
                    weChatLongImagePayload = WeChatLongImagePayload(image: renderedImage, title: title, entry: "activity_detail")
                }
            }
        }
    }

    /// 直接以 UIKit 模态方式呈现 UIActivityViewController（绕过 SwiftUI sheet 嵌套，微信分享兼容）
    private func presentLongImageShare(image: UIImage, title: String) {
        // 交付前兜底校验：纯色 / 黑图绝不落盘分享（渲染层已校验；此处防编码链路异常）
        guard !SJZImageIntegrity.isLikelyBlank(image) else {
            longImageError = "长图生成异常（画布纯色），请重试"
            isGeneratingLongImage = true
            LogManager.shared.error("longimage", "长图交付校验拦截（画布纯色）", context: [
                "title": title,
                "pixel": SJZImageIntegrity.pixelSizeText(of: image)
            ])
            return
        }
        // 交付编码：分享扩展（微信等）内存与体积预算有限（约 120MB）——按「≤16MP / ≤10MB」编码，
        // 否则扩展会被系统终止（2026-09-28 现场：微信「加载中 → 闪回 App」）；产物含纯色 / 黑图校验
        guard let encoded = WeChatImageEncoder.encode(
            image,
            maxBytes: WeChatImageEncoder.systemShareMaxBytes,
            maxPixels: WeChatImageEncoder.systemShareMaxPixels
        ) else {
            longImageError = "图片编码失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图 JPEG 编码失败", context: ["title": title])
            return
        }
        let jpegData = encoded.data
        LogManager.shared.info("longimage", "长图分享文件编码完成", context: [
            "title": title,
            "pixel": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
            "quality": String(format: "%.2f", encoded.quality),
            "scale": String(format: "%.2f", encoded.scale),
            "bytes": "\(encoded.data.count)"
        ])

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(20)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sxjzit_\(safeTitle)_\(UUID().uuidString.prefix(6)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: fileURL)
        } catch {
            longImageError = "图片保存失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图临时文件写入失败", context: ["title": title])
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            longImageError = "无法获取窗口"
            isGeneratingLongImage = true
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // 仅传递文件 URL 和标题文本（微信 Share Extension 通过文件 URL 读取图片）
        let activityItems: [Any] = [fileURL, title]
        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]
        activityVC.completionWithItemsHandler = { [fileURL] _, completed, _, error in
            // 分享扩展（微信等）读取大图较慢，且本回调在「用户选择动作」时即触发——
            // 绝不能立即删除（现场：微信「加载中 → 闪回 App」）；交由共享中心延迟 5 分钟清理
            SJZShareFileCenter.scheduleCleanup(fileURL)
            if !completed {
                // 分享未完成（系统扩展可能因体积 / 尺寸限制中止）：记录可判别数据 + 给出可操作替代路径
                WeChatService.shared.showBanner("微信未完成分享，可改用「分享 → 长图分享到微信」", kind: .info)
                LogManager.shared.warning("longimage", "长图分享未完成（系统扩展可能中止）", context: [
                    "pixel": SJZImageIntegrity.pixelSizeText(of: image),
                    "bytes": "\(jpegData.count)",
                    "error": error?.localizedDescription ?? "none"
                ])
            }
            if let error = error {
                LogManager.shared.error("ui", "校园活动长图分享失败", context: ["error": error.localizedDescription])
            } else {
                LogManager.shared.info("ui", "校园活动长图分享结束", context: ["completed": "\(completed)"])
            }
        }
        topVC.present(activityVC, animated: true)
    }

    /// 下载单张图片（统一走 SJZImageKit：缓存复用 + 进度通道 + 协议层 Referer）
    private func loadDetail() async {
        guard let articleId = activity.articleId else {
            isLoadingDetail = false
            return
        }
        if fullDetail != nil && cacheManager.isCacheEnabled {
            LogManager.shared.debugLog("ui", "缓存模式下校园活动详情已加载，跳过重复请求", context: [
                "articleId": articleId, "title": activity.title
            ])
            return
        }
        isLoadingDetail = true
        loadError = nil
        LogManager.shared.info("ui", "开始加载校园活动详情", context: ["articleId": articleId, "title": activity.title])
        do {
            let detail = try await DataService.shared.loadArticleFullDetail(articleId: articleId)
            fullDetail = detail
            LogManager.shared.info("ui", "校园活动详情加载成功", context: ["articleId": articleId, "images": "\(detail.images.count)"])
        } catch {
            loadError = "文章详情加载失败，请检查网络连接后重试"
            LogManager.shared.error("ui", "校园活动详情加载失败", context: ["articleId": articleId, "error": error.localizedDescription])
        }
        isLoadingDetail = false
    }

    private func retryLoading() {
        Task {
            await loadDetail()
        }
    }

    private var activityDetailPlaceholder: some View {
        LinearGradient(
            colors: [Color.sjzPink.opacity(0.04), Color.sjzLight],
            startPoint: .top, endPoint: .bottom)
        .frame(height: 300)
        .overlay {
            Image(systemName: "party.popper.fill")
                .displaySymbolFont(70).foregroundStyle(Color.sjzPink.opacity(0.06))
        }
    }
}

// MARK: - 院系

struct DepartmentsView: View {
    @ObservedObject private var data = DataService.shared
    // 横幅入场与计数滚动 / 刷新 toast
    @State private var heroAppeared = false
    @State private var countUpTriggered = false
    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?
    private let deptColors: [Color] = [
        Color.sjzPrimary, Color.sjzPurple, Color.sjzOrange, Color.sjzGreen,
        Color.sjzRed, Color.sjzTeal, Color.sjzIndigo, Color.sjzPink,
        Color(hex: "00695C"), Color(hex: "BF360C")
    ]

    /// 全学院真实统计（系部/专业总数）
    private var totalSubDepartments: Int { data.departments.reduce(0) { $0 + $1.subDepartments.count } }
    private var totalMajors: Int { data.departments.reduce(0) { $0 + $1.majors.count } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                statsHero
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                ForEach(Array(data.departments.enumerated()), id: \.element.id) { idx, dept in
                    let color = deptColors[idx % deptColors.count]
                    NavigationLink {
                        DepartmentDetailView(department: dept, color: color)
                    } label: {
                        DepartmentCard(department: dept, index: idx, color: color)
                    }
                    .buttonStyle(FacilityPressStyle(scale: 0.97))
                    .padding(.horizontal, 16)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            LogManager.shared.info("departments", "学院卡片点击", context: [
                                "name": dept.name,
                                "subDepartments": "\(dept.subDepartments.count)",
                                "majors": "\(dept.majors.count)"
                            ])
                        }
                    )
                }
            }
            .padding(.vertical, 16)
        }
        .background(GradientBackground())
        .refreshable {
            LogManager.shared.info("departments", "院系列表下拉刷新", context: [:])
            data.syncIfNeeded(force: true)
            presentToast("数据已刷新 · \(data.departments.count) 个学院")
        }
        .navigationTitle("院系设置").navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { toastOverlay }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { heroAppeared = true }
            countUpTriggered = true
            LogManager.shared.info("departments", "院系列表打开", context: [
                "count": "\(data.departments.count)",
                "subDepartments": "\(totalSubDepartments)",
                "majors": "\(totalMajors)"
            ])
        }
    }

    /// 院系统计面板：玻璃质感三段统计 + 发丝分隔线 + 计数滚动（克制优雅，高频色点缀）
    private var statsHero: some View {
        HStack(spacing: 0) {
            statCell(value: data.departments.count, unit: "学院", color: Color.sjzPrimary)
            hairlineDivider
            statCell(value: totalSubDepartments, unit: "系部", color: Color.sjzTeal)
            hairlineDivider
            statCell(value: totalMajors, unit: "专业", color: Color.sjzGold)
        }
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 14, y: 7)
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 10)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: heroAppeared)
    }

    /// 统计单元：大号数字 + 色点单位（数字 0→N 滚动计数）
    private func statCell(value: Int, unit: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Text("\(countUpTriggered ? value : 0)")
                .displayFont(24, weight: .heavy)
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(countsDown: false))
                .animation(.spring(response: 0.9, dampingFraction: 0.85), value: countUpTriggered)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(unit)
                    .displayFont(11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    // MARK: 刷新状态提示（toast）

    private func presentToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { toastText = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            Text(toastText)
                .displayFont(12, weight: .semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 24)
                .accessibilityLabel("提示：\(toastText)")
        }
    }
}

struct DepartmentDetailView: View {
    let department: Department
    let color: Color

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 30)
                            .fill(LinearGradient(
                                colors: [color, color.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 100, height: 100)
                            .shadow(color: color.opacity(0.3), radius: 18, y: 10)
                        Image(systemName: department.icon)
                            .displaySymbolFont(40).foregroundStyle(.white)
                    }
                    Text(department.name)
                        .displayFont(26, weight: .bold)
                    Text(department.englishName)
                        .displayFont(15).foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                if !department.intro.isEmpty {
                    sectionCard(title: "学院简介", icon: "info.circle.fill") {
                        Text(department.intro)
                            .displayFont(15).foregroundStyle(.secondary).lineSpacing(8)
                    }
                }

                if !department.subDepartments.isEmpty {
                    sectionCard(title: "下设系部", icon: "building.2.crop.circle.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(department.subDepartments, id: \.self) { subDept in
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(color.opacity(0.2))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Image(systemName: "building.columns.fill")
                                                .displaySymbolFont(14)
                                                .foregroundStyle(color)
                                        )
                                    Text(subDept)
                                        .displayFont(15, weight: .medium)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                if !department.majors.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("开设专业", systemImage: "book.fill")
                            .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
                        ForEach(department.majors) { major in
                            NavigationLink {
                                MajorDetailView(major: major, color: color)
                            } label: {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(major.name)
                                            .displayFont(15, weight: .semibold)
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 10) {
                                            Label(major.category, systemImage: "tag.fill")
                                            Label(major.duration, systemImage: "clock.fill")
                                        }
                                        .displayFont(10).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .displaySymbolFont(10, weight: .medium).foregroundStyle(.tertiary)
                                }
                                .padding(16)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                                .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
                            }
                            .buttonStyle(.plain).padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(department.name).navigationBarTitleDisplayMode(.inline)
    }
}

private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        Label(title, systemImage: icon).displayLabelFont(17, weight: .semibold)
        content()
    }
    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
    .padding(.horizontal, 16)
}

struct MajorDetailView: View {
    let major: Major
    let color: Color

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                VStack(spacing: 16) {
                    Text(major.name)
                        .displayFont(26, weight: .bold)
                    HStack(spacing: 16) {
                        Label(major.category, systemImage: "tag.fill")
                        Label(major.duration, systemImage: "clock.fill")
                    }
                    .displayLabelFont(15).foregroundStyle(color)
                }
                .padding(.top, 24)

                sectionCard(title: "专业介绍", icon: "book.fill") {
                    Text(major.intro)
                        .displayFont(15).foregroundStyle(.secondary).lineSpacing(8)
                }
                sectionCard(title: "就业方向", icon: "briefcase.fill") {
                    Text(major.career)
                        .displayFont(15).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 40)
        }
        .navigationTitle("专业详情").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 资讯

struct NewsListView: View {
    @ObservedObject private var data = DataService.shared
    @ObservedObject private var readManager = ReadStatusManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var selectedCategory = "全部"
    @State private var searchText = ""
    /// E10 滚动让路状态
    @State private var isScrolling = false

    private var categories: [String] {
        var cats = ["全部"]
        for (cat, items) in data.allNewsCategories where !items.isEmpty {
            cats.append(cat)
        }
        if cats.count == 1 {
            let all = Set(data.news.map(\.category))
            cats.append(contentsOf: all.sorted())
        }
        if data.zswHomeData != nil {
            cats.append("招生")
        }
        return cats
    }

    /// 是否正在搜索
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filteredNews: [NewsItem] {
        var result: [NewsItem]
        if selectedCategory == "全部" {
            result = data.news
        } else {
            result = data.news.filter { $0.category == selectedCategory }
        }
        if isSearching {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            result = result.filter { item in
                item.title.localizedCaseInsensitiveContains(query) ||
                item.summary.localizedCaseInsensitiveContains(query)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // 分类标签栏 —— 搜索时隐藏，聚焦搜索结果
            if !isSearching {
                categoryTabBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if selectedCategory == "招生" && !isSearching {
                ZSWHomeView()
            } else {
                newsListContent
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isSearching)
        .navigationTitle("新闻资讯").navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "搜索标题或摘要"
        )
    }

    // MARK: - 分类标签栏

    private var categoryTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            selectedCategory = cat
                        }
                    } label: {
                        Text(cat)
                            .displayFont(14, weight: .semibold)
                            .foregroundStyle(selectedCategory == cat ? .white : categoryColor(cat))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(
                                selectedCategory == cat
                                ? categoryColor(cat)
                                : categoryColor(cat).opacity(0.08),
                                in: Capsule()
                            )
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: - 新闻列表内容

    private var newsListContent: some View {
        Group {
            if filteredNews.isEmpty && !isSearching {
                // 无数据空状态
                VStack(spacing: 16) {
                    Image(systemName: "newspaper.fill")
                        .displaySymbolFont(48).foregroundStyle(.secondary.opacity(0.15))
                    Text("暂无数据")
                        .displayFont(15).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // 搜索结果头部
                    if isSearching {
                        searchResultHeader
                    }

                    // 新闻列表
                    if !filteredNews.isEmpty {
                        Section {
                            ForEach(Array(filteredNews.enumerated()), id: \.element.id) { index, item in
                                NavigationLink {
                                    // E6：并行预取下一篇待读文章详情，连续阅读秒开
                                    EnhancedNewsDetailView(
                                        news: item,
                                        nextArticleId: filteredNews.dropFirst(index + 1).first?.articleId
                                    )
                                } label: {
                                    newsRow(item: item, highlight: searchText)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { data.syncIfNeeded(force: true) }
                .sjzScrollSuspendTrack($isScrolling)
                .environment(\.sjzImageLoadingSuspended, isScrolling)
            }
        }
    }

    // MARK: - 搜索结果头部

    private var searchResultHeader: some View {
        Section {
            if filteredNews.isEmpty {
                // 无匹配结果
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .displaySymbolFont(40)
                        .foregroundStyle(.secondary.opacity(0.3))
                    Text("未找到「\(searchText)」相关资讯")
                        .displayFont(15).foregroundStyle(.secondary)
                    Text("请尝试其他关键词")
                        .displayFont(12).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                // 结果计数
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .displaySymbolFont(12).foregroundStyle(.secondary)
                    Text("找到 \(filteredNews.count) 条结果")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            }
        }
    }

    // MARK: - 新闻行

    private func newsRow(item: NewsItem, highlight query: String) -> some View {
        HStack(spacing: 14) {
            newsListThumbnail(item: item)
            VStack(alignment: .leading, spacing: 8) {
                if isSearching && !query.isEmpty {
                    // 搜索时高亮匹配关键词
                    highlightedTitle(item.title, query: query)
                        .displayFont(14, weight: .medium)
                        .lineLimit(2)
                } else {
                    Text(item.title)
                        .displayFont(14, weight: .medium).lineLimit(2)
                }
                HStack(spacing: 8) {
                    CategoryBadge(category: item.category)
                    Text(item.date)
                        .displayFont(11).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // 收藏按钮
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    bookmarkManager.toggleBookmark(item)
                }
            } label: {
                Image(systemName: bookmarkManager.isBookmarked(item) ? "bookmark.fill" : "bookmark")
                    .displaySymbolFont(14)
                    .foregroundStyle(bookmarkManager.isBookmarked(item) ? Color.sjzGold : .secondary)
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topLeading) {
            if !readManager.isRead(item.readKey) {
                Circle()
                    .fill(Color.sjzAccent)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 2).padding(.top, 8)
            }
        }
    }

    /// 高亮显示匹配关键词
    private func highlightedTitle(_ text: String, query: String) -> Text {
        let lowercased = text.lowercased()
        let lowerQuery = query.lowercased()
        var result = AttributedString("")
        var searchRange = lowercased.startIndex..<lowercased.endIndex
        // 高亮片段字体联动显示设置（快照直读：AttributedString 直写字体，护栏不可见；2026-09-29）
        let typography = DisplaySettingsManager.typographySnapshot()

        while let range = lowercased.range(of: lowerQuery, range: searchRange) {
            let before = String(text[searchRange.lowerBound..<range.lowerBound])
            if !before.isEmpty {
                var beforeAttr = AttributedString(before)
                beforeAttr.foregroundColor = .primary
                result.append(beforeAttr)
            }
            let match = String(text[range])
            var matchAttr = AttributedString(match)
            matchAttr.foregroundColor = Color.sjzAccent
            matchAttr.font = DisplayFontFactory.font(size: 14, weight: .bold,
                                                     scale: typography.scale,
                                                     family: typography.family, bold: typography.bold)
            result.append(matchAttr)
            searchRange = range.upperBound..<lowercased.endIndex
        }

        if searchRange.lowerBound < text.endIndex {
            let remaining = String(text[searchRange])
            var remainingAttr = AttributedString(remaining)
            remainingAttr.foregroundColor = .primary
            result.append(remainingAttr)
        }

        // 基础字体由调用点 displayFont 提供；此处高亮片段走粗体（两者均随显示设置联动）
        return Text(result)
    }

    private func newsListThumbnail(item: NewsItem) -> some View {
        Group {
            if let imgUrl = item.imageUrl, let url = URL(string: imgUrl) {
                SJZCachedImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        newsListPlaceholder(item.category)
                    default:
                        ShimmerView().frame(width: 76, height: 60).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .frame(width: 76, height: 60).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                newsListPlaceholder(item.category)
            }
        }
        // 统一时长角标：缩略图右下角（全文口径优先，摘要估算兜底，全 App 规范一致）
        .overlay(alignment: .bottomTrailing) {
            ReadingTimeBadgeView(cachedID: item.readKey, summary: item.summary)
                .padding(3)
        }
    }

    private func newsListPlaceholder(_ category: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(categoryColor(category).opacity(0.06))
                .frame(width: 76, height: 60)
            Image(systemName: "newspaper.fill")
                .displaySymbolFont(12).foregroundStyle(categoryColor(category).opacity(0.15))
        }
    }
}

// MARK: - 校园生活

struct CampusView: View {
    @ObservedObject private var data = DataService.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @State private var showCalendar = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 36) {
                servicesSection
                facilitiesSection
                organizationSection
                schoolInfoSection
                if !data.footerLinks.isEmpty { linksSection }
                if !data.socialPlatforms.isEmpty { socialSection }
            }
            .padding(.vertical, 24)
        }
        .background(GradientBackground())
        .refreshable { data.syncIfNeeded(force: true) }
        .navigationTitle("校园生活").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCalendar) { CampusCalendarView() }
    }

    // MARK: 校园服务

    private var servicesSection: some View {
        let palette = [Color.sjzMint, Color.sjzTeal, Color.sjzIndigo, Color.sjzGold, Color.sjzGreen, Color.sjzAccent]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("校园服务", systemImage: "square.grid.2x2.fill")
                    .displayLabelFont(17, weight: .semibold)
                Spacer()
                Text("\(data.services.count) 项服务")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.sjzMint.opacity(0.9)))
            }
            .padding(.horizontal, 16)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                spacing: 20
            ) {
                ForEach(Array(data.services.enumerated()), id: \.element.id) { index, service in
                    ServiceButton(service: service,
                                  index: index,
                                  accent: palette[index % palette.count]) { tappedService in
                        if tappedService.url == "sxjzit://campus-calendar" {
                            showCalendar = true
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .onAppear {
            LogManager.shared.debugLog("campusService", "校园服务列表展示", context: [
                "count": "\(data.services.count)"
            ])
        }
    }

    // MARK: 校园设施

    private var facilitiesSection: some View {
        let palette = [Color.sjzAccent, Color.sjzTeal, Color.sjzIndigo, Color.sjzGreen, Color.sjzGold]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("校园设施", systemImage: "building.2.fill")
                    .displayLabelFont(17, weight: .semibold)
                Spacer()
                Text("\(data.facilities.count) 大设施")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.sjzAccent.opacity(0.85)))
            }
            .padding(.horizontal, 16)
            ForEach(Array(data.facilities.enumerated()), id: \.element.id) { index, facility in
                NavigationLink {
                    FacilityDetailView(facility: facility)
                } label: {
                    FacilityCardLabel(facility: facility, index: index, accent: palette[index % palette.count])
                }
                .buttonStyle(FacilityPressStyle())
                .padding(.horizontal, 16)
            }
        }
        .onAppear {
            LogManager.shared.debugLog("facility", "设施列表展示", context: [
                "count": "\(data.facilities.count)"
            ])
        }
    }

    // MARK: 机构设置

    private var organizationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("机构设置", systemImage: "building.columns.fill")
                .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
            NavigationLink {
                OrganizationView()
            } label: {
                OrganizationEntryCard(totalCount: OrganizationManager.shared.totalCount)
            }
            .buttonStyle(FacilityPressStyle(scale: 0.97))
            .padding(.horizontal, 16)
            .simultaneousGesture(
                TapGesture().onEnded {
                    LogManager.shared.info("organization", "校园-机构设置入口点击", context: [
                        "totalUnits": "\(OrganizationManager.shared.totalCount)"
                    ])
                }
            )
            .onAppear {
                LogManager.shared.info("organization", "校园-机构设置入口显示", context: [
                    "totalUnits": "\(OrganizationManager.shared.totalCount)"
                ])
            }
        }
    }

    // MARK: 校园风光

    private var campusScenerySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("校园风光", systemImage: "photo.on.rectangle.angled")
                .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(data.campusSceneries) { scenery in
                        NavigationLink {
                            SceneryDetailView(scenery: scenery)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                if let imgUrl = scenery.imageUrl, let url = URL(string: imgUrl) {
                                    SJZCachedImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFill()
                                        } else {
                                            Color.sjzLight.frame(height: 180)
                                        }
                                    }
                                    .frame(width: 290, height: 180).clipped()
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(scenery.title)
                                        .displayFont(13, weight: .medium).lineLimit(1)
                                    if let desc = scenery.description, !desc.isEmpty {
                                        Text(desc)
                                            .displayFont(10).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(14)
                            }
                            .frame(width: 290)
                        }
                        .buttonStyle(.plain)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 校园活动

    private var campusActivitiesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("校园活动", systemImage: "party.popper.fill")
                .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(data.campusActivities) { activity in
                        VStack(alignment: .leading, spacing: 0) {
                            if let imgUrl = activity.imageUrl, let url = URL(string: imgUrl) {
                                SJZCachedImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Color.sjzLight.frame(height: 150)
                                    }
                                }
                                .frame(width: 240, height: 150).clipped()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(activity.title)
                                    .displayFont(13, weight: .medium).lineLimit(2)
                                if let date = activity.date {
                                    Text(date).displayFont(10).foregroundStyle(Color.sjzPink)
                                }
                            }
                            .padding(14)
                        }
                        .frame(width: 240)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 校园视频

    private var videosInCampus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("映像校园", systemImage: "play.rectangle.fill")
                .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(data.videos) { video in
                        NavigationLink {
                            VideoPlayerView(video: video)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack {
                                    if let thumb = video.thumbnailUrl, let url = URL(string: thumb) {
                                        SJZCachedImage(url: url) { phase in
                                            if case .success(let img) = phase {
                                                img.resizable().scaledToFill()
                                            } else {
                                                videoPlaceholder
                                            }
                                        }
                                    } else {
                                        videoPlaceholder
                                    }
                                    Image(systemName: "play.circle.fill")
                                        .displaySymbolFont(28).foregroundStyle(.white).shadow(radius: 4)
                                }
                                .frame(width: 270, height: 160).clipped()
                                Text(video.title)
                                    .displayFont(13, weight: .medium).lineLimit(2)
                                    .padding(14)
                            }
                            .frame(width: 270)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var videoPlaceholder: some View {
        Color.sjzLight.overlay {
            Image(systemName: "play.rectangle.fill")
                .displaySymbolFont(28).foregroundStyle(Color.sjzAccent.opacity(0.1))
        }
    }

    // MARK: 教师风采

    private var teachersInCampus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("教师风采", systemImage: "person.text.rectangle.fill")
                .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(data.teacherProfiles) { teacher in
                        VStack(alignment: .leading, spacing: 0) {
                            if let imgUrl = teacher.imageUrl, let url = URL(string: imgUrl) {
                                SJZCachedImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Color.sjzLight.frame(height: 140)
                                    }
                                }
                                .frame(width: 180, height: 140).clipped()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(teacher.title)
                                    .displayFont(13, weight: .medium).lineLimit(2)
                                Text(teacher.summary)
                                    .displayFont(10).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(14)
                        }
                        .frame(width: 180)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 学生故事

    private var storiesInCampus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("学生故事", systemImage: "person.2.fill")
                .displayLabelFont(17, weight: .semibold).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(data.studentStories) { story in
                        VStack(alignment: .leading, spacing: 0) {
                            if let imgUrl = story.imageUrl, let url = URL(string: imgUrl) {
                                SJZCachedImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Color.sjzLight.frame(height: 150)
                                    }
                                }
                                .frame(width: 230, height: 150).clipped()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(story.title)
                                    .displayFont(13, weight: .medium).lineLimit(2)
                                Text(story.summary)
                                    .displayFont(10).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(14)
                        }
                        .frame(width: 230)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: 学校概况

    private var schoolInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("学校概况", systemImage: "info.circle.fill")
                    .displayLabelFont(17, weight: .semibold)
                Spacer()
                Text("8 项档案")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(displaySettings.themeStyle.color))
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: displaySettings.themeStyle)
            }
            .padding(.horizontal, 16)
            SchoolInfoCard(phone: data.recruitPhones.first ?? SchoolInfo.phone)
                .padding(.horizontal, 16)
        }
    }

    // MARK: 友情链接

    private var linksSection: some View {
        let palette = [Color.sjzTeal, Color.sjzIndigo, Color.sjzMint, Color.sjzGold, Color.sjzGreen, Color.sjzAccent]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("友情链接", systemImage: "link")
                    .displayLabelFont(17, weight: .semibold)
                Spacer()
                Text("\(data.footerLinks.count) 个站点")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(displaySettings.themeStyle.color))
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: displaySettings.themeStyle)
            }
            .padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(Array(data.footerLinks.enumerated()), id: \.element.id) { index, link in
                    FooterLinkRow(link: link, index: index, accent: palette[index % palette.count])
                    if link.id != data.footerLinks.last?.id {
                        Divider().padding(.leading, 70).opacity(0.5)
                    }
                }
            }
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(displaySettings.themeStyle.color.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
            .padding(.horizontal, 16)
        }
        .onAppear {
            LogManager.shared.debugLog("campusLinks", "友情链接列表展示", context: [
                "count": "\(data.footerLinks.count)"
            ])
        }
    }

    // MARK: 社交平台

    private var socialSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("关注我们", systemImage: "qrcode.viewfinder")
                    .displayLabelFont(17, weight: .semibold)
                Spacer()
                Text("\(data.socialPlatforms.count) 个平台")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.sjzGold.opacity(0.95)))
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(data.socialPlatforms.enumerated()), id: \.element.id) { index, platform in
                        SocialQRCard(platform: platform, index: index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .onAppear {
            LogManager.shared.debugLog("socialFollow", "关注我们列表展示", context: [
                "count": "\(data.socialPlatforms.count)"
            ])
        }
    }
}

private struct ServiceButton: View {
    let service: CampusService
    /// 列表序号（入场错峰动效）
    let index: Int
    /// 服务主题色（渐变图标块）
    let accent: Color
    /// 内部协议（sxjzit://）回调：由 CampusView 注入原生导航；其余外链服务不经过此路径
    var onInternal: ((CampusService) -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @State private var appeared = false

    var body: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            if service.url.hasPrefix("sxjzit://") {
                LogManager.shared.info("campusService", "服务点击·内部协议", context: [
                    "service": service.name, "url": service.url
                ])
                if service.url == "sxjzit://campus-calendar" {
                    LogManager.shared.info("campusCalendar", "校园日历入口点击", context: [
                        "entry": "campus-service-grid", "url": service.url
                    ])
                }
                onInternal?(service)
            } else if let url = URL(string: service.url) {
                LogManager.shared.info("campusService", "服务点击·外链", context: [
                    "service": service.name, "url": service.url
                ])
                openURL(url)
            } else {
                LogManager.shared.error("campusService", "服务点击·无效链接", context: [
                    "service": service.name, "url": service.url
                ])
            }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            colors: [accent, accent.opacity(0.62)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 58, height: 58)
                        .shadow(color: accent.opacity(0.35), radius: 10, y: 6)
                    Image(systemName: service.icon)
                        .displaySymbolFont(22)
                        .foregroundStyle(.white)
                }
                Text(service.name)
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.primary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)
                    .delay(Double(index) * 0.05)) {
                    appeared = true
                }
            }
        }
        .buttonStyle(FacilityPressStyle(scale: 0.9))
        .accessibilityLabel(service.name)
    }
}

/// 机构设置入口横幅卡：indigo 渐变底 + 巨型机构水印 + 悬浮玻璃图标 +
/// 光晕与图标双呼吸动效 + 一次性微光扫过 + 弹簧入场（机构数实时显示）
private struct OrganizationEntryCard: View {
    let totalCount: Int
    @State private var appeared = false
    @State private var shimmerSwept = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.sjzIndigo, Color(hex: "6E4BDD"), Color.sjzTeal.opacity(0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            // 巨型机构水印（右下角淡出）
            Image(systemName: "building.columns.fill")
                .displaySymbolFont(96)
                .foregroundStyle(.white.opacity(0.10))
                .rotationEffect(.degrees(-8))
                .offset(x: 20, y: 24)
            // 一次性微光扫过（高级光效，仅入场一次）
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.30), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .rotationEffect(.degrees(18))
                    .offset(x: shimmerSwept ? geo.size.width * 1.6 : -geo.size.width * 0.8)
                    .frame(maxHeight: .infinity)
                    .animation(.easeOut(duration: 1.15).delay(0.3), value: shimmerSwept)
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 76, height: 76)
                        .phaseAnimator([false, true]) { view, phase in
                            view.scaleEffect(phase ? 1.06 : 0.9).opacity(phase ? 0.55 : 0.12)
                        } animation: { _ in
                            .easeInOut(duration: 2.6)
                        }
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.20))
                        .frame(width: 58, height: 58)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        )
                    Image(systemName: "building.columns.fill")
                        .displaySymbolFont(22)
                        .foregroundStyle(.white)
                        .phaseAnimator([false, true]) { content, phase in
                            content.offset(y: phase ? -2.5 : 2.5)
                        } animation: { _ in
                            .easeInOut(duration: 2.4)
                        }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("查看全部机构")
                        .displayFont(17, weight: .bold)
                        .foregroundStyle(.white)
                    Text("党委 · 行政 · 教学 · 教辅等 \(totalCount) 个部门")
                        .displayFont(12)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .padding(18)
        }
        .frame(minHeight: 100)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.sjzIndigo.opacity(0.35), radius: 18, y: 10)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .scaleEffect(appeared ? 1 : 0.95)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: appeared)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                appeared = true
            }
            shimmerSwept = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("查看全部机构，共 \(totalCount) 个部门")
    }
}

/// 学校概况档案卡：紫金渐变校名带（类型徽章+创办徽章+水印+微光扫过，全称 Hero 位）
/// + 逐行图标档案错峰弹入 + 地址一键复制 + 招生电话一键拨打
private struct SchoolInfoCard: View {
    let phone: String
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @State private var appeared = false
    @State private var shimmerSwept = false
    @State private var addressCopied = false

    /// 当前显示设置主题色（深浅模式自适应，实时联动「显示设置」）
    private var themeBase: Color {
        displaySettings.themeStyle.color
    }

    private struct InfoRowItem {
        let label: String
        let icon: String
        let value: String
        let accentHex: String
    }

    private var items: [InfoRowItem] {
        [
            InfoRowItem(label: "学校类型", icon: "checkmark.seal.fill", value: SchoolInfo.type, accentHex: "C8A24B"),
            InfoRowItem(label: "主管部门", icon: "building.2.fill", value: SchoolInfo.affiliation, accentHex: "8E5BC9"),
            InfoRowItem(label: "创办时间", icon: "clock.fill", value: SchoolInfo.foundedYear + "年", accentHex: "3A9D5C"),
            InfoRowItem(label: "转设时间", icon: "arrow.triangle.2.circlepath", value: SchoolInfo.convertedYear + "年", accentHex: "0E9AA7"),
            InfoRowItem(label: "校庆日", icon: "sparkles", value: SchoolInfo.anniversary, accentHex: "E07B39"),
            InfoRowItem(label: "前身", icon: "books.vertical.fill", value: SchoolInfo.predecessor, accentHex: "4C6EF5"),
            InfoRowItem(label: "学校地址", icon: "mappin.and.ellipse", value: SchoolInfo.address, accentHex: "C8102E"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    rowContent(item, index: index)
                    Divider().padding(.leading, 58).opacity(0.5)
                }
                phoneRow
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(themeBase.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: themeBase.opacity(0.18), radius: 18, y: 9)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .scaleEffect(appeared ? 1 : 0.97)
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: appeared)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: displaySettings.themeStyle)
        .onChange(of: displaySettings.themeStyle) { _, newValue in
            LogManager.shared.debugLog("schoolInfo", "显示设置联动·主题色", context: ["theme": newValue.rawValue])
        }
        .onChange(of: displaySettings.fontSizeTier) { _, newValue in
            LogManager.shared.debugLog("schoolInfo", "显示设置联动·字体档位", context: ["tier": newValue.rawValue])
        }
        .onChange(of: displaySettings.boldTextEnabled) { _, newValue in
            LogManager.shared.debugLog("schoolInfo", "显示设置联动·粗体文本", context: ["enabled": "\(newValue)"])
        }
        .onChange(of: displaySettings.buttonShapesEnabled) { _, newValue in
            LogManager.shared.debugLog("schoolInfo", "显示设置联动·按钮形状", context: ["enabled": "\(newValue)"])
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
            shimmerSwept = true
            LogManager.shared.info("schoolInfo", "学校概况档案卡展示", context: [
                "rows": "8",
                "theme": displaySettings.themeStyle.rawValue,
                "fontTier": displaySettings.fontSizeTier.rawValue,
                "bold": "\(displaySettings.boldTextEnabled)",
                "buttonShapes": "\(displaySettings.buttonShapesEnabled)"
            ])
        }
    }

    // MARK: 头部：渐变校名带

    private var header: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [themeBase, themeBase.opacity(0.78), themeBase.opacity(0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "building.columns.fill")
                .displaySymbolFont(88)
                .foregroundStyle(.white.opacity(0.10))
                .rotationEffect(.degrees(-8))
                .offset(x: 16, y: 18)
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.28), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.55)
                    .rotationEffect(.degrees(16))
                    .offset(x: shimmerSwept ? geo.size.width * 1.7 : -geo.size.width * 0.9)
                    .frame(maxHeight: .infinity)
                    .animation(.easeOut(duration: 1.2).delay(0.25), value: shimmerSwept)
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 66, height: 66)
                        .phaseAnimator([false, true]) { view, phase in
                            view.scaleEffect(phase ? 1.08 : 0.9).opacity(phase ? 0.5 : 0.12)
                        } animation: { _ in
                            .easeInOut(duration: 2.6)
                        }
                    Image(systemName: "graduationcap.fill")
                        .displaySymbolFont(26)
                        .foregroundStyle(.white)
                        .phaseAnimator([false, true]) { content, phase in
                            content.offset(y: phase ? -2.5 : 2.5)
                        } animation: { _ in
                            .easeInOut(duration: 2.4)
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(SchoolInfo.name)
                        .displayFont(19, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .tracking(displaySettings.letterSpacingValue)
                        .lineSpacing(3 * displaySettings.lineSpacingFactor)
                    HStack(spacing: 8) {
                        Text(SchoolInfo.type)
                            .displayFont(10, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 3.5)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.7))
                        if !SchoolInfo.foundedYear.isEmpty {
                            Text("\(SchoolInfo.foundedYear) 年创办")
                                .displayFont(10, weight: .medium)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                Spacer(minLength: 6)
            }
            .padding(18)
        }
        .frame(minHeight: 118)
    }

    // MARK: 档案行

    @ViewBuilder
    private func rowContent(_ item: InfoRowItem, index: Int) -> some View {
        if item.label == "学校地址" {
            Button {
                copyAddress()
            } label: {
                infoRow(item, index: index) {
                    Image(systemName: addressCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .displaySymbolFont(13)
                        .foregroundStyle(addressCopied ? Color.sjzGreen : themeBase)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .background {
                if displaySettings.buttonShapesEnabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(themeBase.opacity(0.06))
                }
            }
            .overlay {
                if displaySettings.buttonShapesEnabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(themeBase.opacity(0.4), lineWidth: 1)
                }
            }
            .padding(.horizontal, 8)
            .buttonStyle(FacilityPressStyle(scale: 0.98))
        } else {
            infoRow(item, index: index) { EmptyView() }
        }
    }

    private func infoRow<T: View>(_ item: InfoRowItem, index: Int, @ViewBuilder trailing: @escaping () -> T) -> some View {
        let color = Color(hex: item.accentHex)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 30, height: 30)
                Image(systemName: item.icon)
                    .displaySymbolFont(12)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .displayFont(10, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(item.value)
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(
            .spring(response: 0.5, dampingFraction: 0.78).delay(Double(index) * 0.05),
            value: appeared
        )
    }

    private func copyAddress() {
        UIPasteboard.general.string = SchoolInfo.address
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        LogManager.shared.info("schoolInfo", "复制学校地址", context: ["address": SchoolInfo.address])
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { addressCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.3)) { addressCopied = false }
        }
    }

    // MARK: 招生电话行（一键拨打）

    private var phoneRow: some View {
        Button {
            callPhone()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(hex: "2B7A5F").opacity(0.12)).frame(width: 30, height: 30)
                    Image(systemName: "phone.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(Color(hex: "2B7A5F"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("招生电话")
                        .displayFont(10, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text(phone)
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text("拨打")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: "2B7A5F")))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.78).delay(Double(items.count) * 0.05),
                value: appeared
            )
        }
        .background {
            if displaySettings.buttonShapesEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(themeBase.opacity(0.06))
            }
        }
        .overlay {
            if displaySettings.buttonShapesEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(themeBase.opacity(0.4), lineWidth: 1)
            }
        }
        .padding(.horizontal, 8)
        .buttonStyle(FacilityPressStyle(scale: 0.98))
    }

    private func callPhone() {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else {
            LogManager.shared.error("schoolInfo", "拨打招生电话失败", context: ["phone": phone])
            return
        }
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        LogManager.shared.info("schoolInfo", "拨打招生电话", context: ["phone": phone])
        UIApplication.shared.open(url)
    }
}

/// 友情链接行：主题渐变地球图标 + 站点名 + 真实域名副题 + 箭头胶囊，左侧滑入错峰弹入
private struct FooterLinkRow: View {
    let link: FooterLink
    let index: Int
    let accent: Color
    @Environment(\.openURL) private var openURL
    @State private var appeared = false

    /// 链接真实域名（来自官网数据，无主机时隐藏副题）
    private var hostText: String? {
        guard let url = URL(string: link.href), let host = url.host else { return nil }
        return host
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [accent, accent.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 42, height: 42)
                        .shadow(color: accent.opacity(0.3), radius: 8, y: 4)
                    Image(systemName: "globe")
                        .displaySymbolFont(16)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.name)
                        .displayFont(14, weight: .semibold)
                        .foregroundStyle(.primary)
                    if let host = hostText {
                        Text(host)
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward.app")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(accent.opacity(0.12)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : -18)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.78)
                    .delay(Double(index) * 0.06)) {
                    appeared = true
                }
            }
        }
        .buttonStyle(FacilityPressStyle(scale: 0.975))
        .accessibilityLabel("打开友情链接：\(link.name)")
    }

    private func handleTap() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        LogManager.shared.info("campusLinks", "友情链接点击", context: [
            "name": link.name, "href": link.href
        ])
        if let url = URL(string: link.href) {
            openURL(url)
        } else {
            openURL(URL(string: "https://www.sxjzit.edu.cn")!)
        }
    }
}

/// 豪华二维码卡：金色渐变浮雕相框 + 一次性金光扫过 + 错峰弹入 + 点按保存到相册（保存中转圈/成功绿勾/失败红字）
private struct SocialQRCard: View {
    let platform: SocialPlatform
    let index: Int
    @State private var appeared = false
    @State private var shimmerSwept = false
    @State private var saving = false
    @State private var statusText: String?

    var body: some View {
        Button {
            saveQR()
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    // 金色渐变相框
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.sjzGold, Color.sjzGold.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: Color.sjzGold.opacity(0.35), radius: 14, y: 8)
                    // 白色内芯（保障二维码识别对比度）
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white)
                        .padding(4)
                    if let url = URL(string: platform.img), !platform.img.isEmpty {
                        SJZCachedImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFit()
                            } else {
                                Color.sjzLight
                            }
                        }
                        .padding(10)
                    } else {
                        Image(systemName: "qrcode")
                            .displaySymbolFont(48)
                            .foregroundStyle(Color.sjzGold)
                    }
                    // 一次性金光扫过（浮雕玻璃光效）
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.5), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .rotationEffect(.degrees(18))
                            .offset(x: shimmerSwept ? geo.size.width * 1.8 : -geo.size.width * 0.8)
                            .frame(maxHeight: .infinity)
                            .animation(.easeOut(duration: 1.1).delay(0.25), value: shimmerSwept)
                            .blendMode(.screen)
                    }
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if saving {
                        ProgressView()
                            .tint(Color.sjzGold)
                            .scaleEffect(1.2)
                    }
                    if statusText == "已保存" {
                        Image(systemName: "checkmark.circle.fill")
                            .displaySymbolFont(36)
                            .foregroundStyle(Color.sjzGreen)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 148, height: 148)
                Text(platform.title)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.sjzGold.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(Color.sjzGold.opacity(0.4), lineWidth: 1))
                if let status = statusText, status != "已保存" {
                    Text(status)
                        .displayFont(10)
                        .foregroundStyle(Color.sjzRed)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 148)
                } else {
                    Text("扫码关注 · 点按保存")
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                }
            }
            .scaleEffect(appeared ? 1 : 0.7)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.75)
                    .delay(Double(index) * 0.07)) {
                    appeared = true
                }
                shimmerSwept = true
            }
        }
        .buttonStyle(FacilityPressStyle(scale: 0.94))
        .accessibilityLabel("保存「\(platform.title)」二维码到相册")
    }

    private func saveQR() {
        guard !saving else { return }
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        LogManager.shared.info("socialFollow", "二维码保存触发", context: [
            "platform": platform.title, "img": platform.img
        ])
        saving = true
        statusText = nil
        Task {
            let error = await ProfileImageSaveShare.saveToPhotos(urlString: platform.img, logTag: "socialFollow")
            saving = false
            if let error {
                LogManager.shared.warning("socialFollow", "二维码保存失败反馈", context: [
                    "platform": platform.title, "error": error
                ])
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { statusText = error }
            } else {
                LogManager.shared.info("socialFollow", "二维码保存成功反馈", context: [
                    "platform": platform.title
                ])
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { statusText = "已保存" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeOut(duration: 0.3)) { statusText = nil }
                }
            }
        }
    }
}

/// 院系卡：主题渐变图标 + 光晕/悬浮双呼吸 + 系部/专业徽章 + 主题色箭头胶囊 + 错峰弹入
private struct DepartmentCard: View {
    let department: Department
    let index: Int
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: 76, height: 76)
                    .phaseAnimator([false, true]) { view, phase in
                        view.scaleEffect(phase ? 1.05 : 0.92).opacity(phase ? 0.5 : 0.12)
                    } animation: { _ in
                        .easeInOut(duration: 2.6)
                    }
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [color, color.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .shadow(color: color.opacity(0.32), radius: 14, y: 8)
                Image(systemName: department.icon)
                    .displaySymbolFont(24)
                    .foregroundStyle(.white)
                    .phaseAnimator([false, true]) { content, phase in
                        content.offset(y: phase ? -2 : 2)
                    } animation: { _ in
                        .easeInOut(duration: 2.2)
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(department.name)
                    .displayFont(16, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(department.englishName)
                    .displayFont(11).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if !department.subDepartments.isEmpty {
                        badge("\(department.subDepartments.count) 个系部", filled: false)
                    }
                    if !department.majors.isEmpty {
                        badge("\(department.majors.count) 个专业", filled: true)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .displaySymbolFont(12, weight: .semibold)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(Circle().fill(color.opacity(0.12)))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(color.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: color.opacity(0.10), radius: 16, y: 8)
        // 仅首次入场错峰动画；同一会话内滚动复用不再重播，杜绝列表滚动粗糙感
        .modifier(SJZRevealOnce(key: "dept-card-\(department.name)", delay: Double(index) * 0.06))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(department.name)，\(department.subDepartments.count) 个系部，\(department.majors.count) 个专业")
    }

    private func badge(_ text: String, filled: Bool) -> some View {
        Text(text)
            .displayFont(10, weight: .bold)
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(filled ? color.opacity(0.85) : color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.8))
    }
}

struct FacilityDetailView: View {
    let facility: Facility
    @State private var contentAppear = false

    // 分区目录轮播当前位置（scrollPosition 绑定，与正文滚动双向同步）
    @State private var wheelPosition: Int? = 0
    /// 目录舞台宽度（全出血轮播两侧留白计算）
    @State private var stageWidth: CGFloat = 390

    // 滚动与阅读状态（iOS 18+ ScrollGeometry 官方滚动跟踪，驱动目录高亮/进度条/回顶按钮）
    @State private var scrollProgress: Double = 0
    @State private var currentSectionIndex = 0
    @State private var sectionMinYs: [Int: CGFloat] = [:]
    @State private var showBackTop = false
    @State private var sectionPillVisible = false
    @State private var progressMidLogged = false
    @State private var progressFullLogged = false

    // 状态提示（toast）
    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?

    /// 分区主题色内置调色板（无自定义 accentHex 时按下标轮换）
    private static let palette: [String] = ["3A9D5C", "2A6FDB", "C8A24B", "E07B39", "8E5BC9", "6B7280"]

    private func accent(for index: Int) -> Color {
        guard let sections = facility.sections, index < sections.count else { return Color.sjzAccent }
        let hex = sections[index].accentHex ?? Self.palette[index % Self.palette.count]
        return Color(hex: hex)
    }

    private var sectionTitles: [String] {
        facility.sections?.map(\.title) ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // 头部：渐变图标块 + 光晕呼吸 + 设施名
                    heroHeader
                        .id("facilityTop")

                    // 总述
                    sectionCard(title: "简介", icon: "info.circle.fill") {
                        Text(facility.desc)
                            .displayFont(15).foregroundStyle(.secondary).lineSpacing(8)
                    }
                    .opacity(contentAppear ? 1 : 0)
                    .offset(y: contentAppear ? 0 : 14)

                    // 分区目录（快速导航条：点击定位、滚动自动高亮）
                    if sectionTitles.count > 1 {
                        sectionIndexChips(proxy: proxy)
                            .id("facilityDirectory")
                            .opacity(contentAppear ? 1 : 0)
                            .offset(y: contentAppear ? 0 : 12)
                    }

                    // 分区卡片（复杂设施：按分区逐卡展示；含 stagger 渐入）
                    if let sections = facility.sections {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            facilitySectionCard(section, index: index)
                                .id("facilitySec-\(index)")
                                .onGeometryChange(for: CGFloat.self) { geo in
                                    geo.frame(in: .named("facilityScroll")).minY
                                } action: { minY in
                                    sectionMinYs[index] = minY
                                }
                                .opacity(contentAppear ? 1 : 0)
                                .scaleEffect(contentAppear ? 1 : 0.96)
                                .offset(y: contentAppear ? 0 : 16)
                                .animation(
                                    .spring(response: 0.55, dampingFraction: 0.75)
                                        .delay(Double(index) * 0.06),
                                    value: contentAppear
                                )
                        }
                    } else {
                        // 经典样式：详细信息绿勾列表（无分区数据的设施自动回退，视觉与旧版一致）
                        sectionCard(title: "详细信息", icon: "list.bullet.rectangle") {
                            ForEach(facility.details, id: \.self) { detail in
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.sjzGreen).displaySymbolFont(14)
                                    Text(detail).displayFont(15)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .opacity(contentAppear ? 1 : 0)
                        .offset(y: contentAppear ? 0 : 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
                .coordinateSpace(name: "facilityScroll")
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: contentAppear)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(facility.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // 顶部阅读进度条：滚动比例实时可见
            .overlay(alignment: .top) { readingProgressBar }
            // 顶部悬浮分区定位胶囊：目录滚出屏幕后仍可随时看到当前位置
            .overlay(alignment: .top) { sectionPositionPill(proxy: proxy) }
            // 右下角悬浮「回到顶部」
            .overlay(alignment: .bottomTrailing) { backToTopButton(proxy: proxy) }
            // 底部状态提示（toast）
            .overlay(alignment: .bottom) { toastOverlay }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geo in
                handleScrollGeometry(geo)
            }
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    contentAppear = true
                }
                LogManager.shared.info("facility", "设施详情打开", context: [
                    "facility": facility.name,
                    "sections": "\(facility.sections?.count ?? 0)",
                    "details": "\(facility.details.count)"
                ])
            }
            .onDisappear {
                LogManager.shared.debugLog("facility", "设施详情关闭", context: [
                    "facility": facility.name,
                    "progress": "\(Int(scrollProgress * 100))%"
                ])
            }
        }
    }

    // MARK: - 头部

    private var heroHeader: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.sjzAccent.opacity(0.16))
                    .frame(width: 134, height: 134)
                    .phaseAnimator([false, true]) { view, phase in
                        view.scaleEffect(phase ? 1.0 : 0.85).opacity(phase ? 0.5 : 0.0)
                    } animation: { _ in
                        .easeInOut(duration: 2.6)
                    }
                RoundedRectangle(cornerRadius: 30)
                    .fill(LinearGradient(
                        colors: [Color.sjzAccent, Color.sjzAccent.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .shadow(color: Color.sjzAccent.opacity(0.3), radius: 18, y: 10)
                Image(systemName: facility.icon)
                    .displaySymbolFont(40).foregroundStyle(.white)
                    // 悬浮呼吸动效：图标在垂直方向缓缓起伏，营造轻盈的场馆气质
                    .phaseAnimator([false, true]) { content, phase in
                        content.offset(y: phase ? -3 : 3)
                    } animation: { _ in
                        .easeInOut(duration: 2.2)
                    }
            }
            Text(facility.name)
                .displayFont(26, weight: .bold)
        }
        .padding(.top, 24)
        .opacity(contentAppear ? 1 : 0)
        .offset(y: contentAppear ? 0 : 14)
        .scaleEffect(contentAppear ? 1 : 0.9)
    }

    // MARK: - 分区目录

    private func sectionIndexChips(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：标题 + 渐变页码胶囊 + 左右步进（对称节奏）
            HStack(spacing: 8) {
                Label("分区目录", systemImage: "list.number")
                    .displayFont(12, weight: .semibold).foregroundStyle(.secondary)
                Spacer()
                Button {
                    jumpToSection(currentSectionIndex - 1, proxy: proxy, source: "step")
                } label: {
                    Image(systemName: "chevron.backward")
                        .displaySymbolFont(10, weight: .semibold)
                        .foregroundStyle(currentSectionIndex > 0 ? Color.sjzAccent : Color(.tertiaryLabel))
                }
                .buttonStyle(FacilityPressStyle(scale: 0.85))
                .disabled(currentSectionIndex <= 0)
                Text("\((wheelPosition ?? 0) + 1) / \(sectionTitles.count)")
                    .displayFont(12, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 5)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color.sjzAccent, Color.sjzTeal],
                            startPoint: .leading, endPoint: .trailing))
                            .shadow(color: Color.sjzAccent.opacity(0.28), radius: 6, y: 3)
                    )
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: wheelPosition)
                Button {
                    jumpToSection(currentSectionIndex + 1, proxy: proxy, source: "step")
                } label: {
                    Image(systemName: "chevron.forward")
                        .displaySymbolFont(10, weight: .semibold)
                        .foregroundStyle(currentSectionIndex < sectionTitles.count - 1 ? Color.sjzAccent : Color(.tertiaryLabel))
                }
                .buttonStyle(FacilityPressStyle(scale: 0.85))
                .disabled(currentSectionIndex >= sectionTitles.count - 1)
            }
            .padding(.horizontal, 16)

            // 全出血玻璃轮播：卡片滑至屏幕边缘、选中卡居中，杂志式聚焦
            GlassEffectContainer(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(sectionTitles.enumerated()), id: \.offset) { index, title in
                            carouselCard(index: index, title: title, proxy: proxy)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, wheelSidePadding)
                    .padding(.vertical, 16)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $wheelPosition)
            }
            .onChange(of: currentSectionIndex) { _, newIndex in
                guard wheelPosition != newIndex else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    wheelPosition = newIndex
                }
            }

            // 页码指示点：当前分区 = 主题色胶囊，其余 = 页点
            sectionDots
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, -16) // 抵消页面边距，实现全出血舞台
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { width in
            stageWidth = max(0, width)
        }
    }

    /// 轮播两侧留白：保证首尾卡片也能吸附到屏幕中央
    private var wheelSidePadding: CGFloat {
        max(24, (stageWidth - 136) / 2)
    }

    /// 页码指示点（当前分区胶囊带其主题色）
    private var sectionDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<sectionTitles.count, id: \.self) { index in
                let color = accent(for: index)
                if index == (wheelPosition ?? 0) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [color, color.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: 20, height: 6)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: wheelPosition)
    }

    /// 轮播卡片：Liquid Glass 底 + 分区主题色染色 + 交互液态反馈，选中态放大、未选中态收敛
    private func carouselCard(index: Int, title: String, proxy: ScrollViewProxy) -> some View {
        // 激活态跟随轮盘位置：拖动浏览时卡片即时反馈，确认后与正文位置一致
        let active = index == (wheelPosition ?? 0)
        let color = accent(for: index)
        return Button {
            jumpToSection(index, proxy: proxy, source: "carousel")
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .displayFont(11, weight: .heavy).monospacedDigit()
                    .foregroundStyle(active ? Color.black.opacity(0.5) : color)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(active ? Color.white.opacity(0.55) : color.opacity(0.16))
                    )
                Text(title)
                    .displayFont(13, weight: .bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(active ? Color.primary : color.opacity(0.95))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 136, alignment: .leading)
            .frame(minHeight: 64, alignment: .center)
            .glassEffect(
                .regular.tint(active ? color.opacity(0.5) : Color.clear).interactive(),
                in: .rect(cornerRadius: 20)
            )
            .scaleEffect(active ? 1.0 : 0.88)
            .opacity(active ? 1.0 : 0.72)
            .shadow(color: active ? color.opacity(0.35) : .clear, radius: 12, y: 8)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: active)
        }
        .buttonStyle(.plain)
    }

    /// 分区跳转统一入口（目录胶囊与上/下步进共用，日志区分来源）
    private func jumpToSection(_ index: Int, proxy: ScrollViewProxy, source: String) {
        guard facility.sections?.indices.contains(index) == true else { return }
        let title = sectionTitles[index]
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        LogManager.shared.info("facility", "分区目录跳转", context: [
            "facility": facility.name, "section": title, "index": "\(index)", "source": source
        ])
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            proxy.scrollTo("facilitySec-\(index)", anchor: .top)
        }
    }

    // MARK: - 滚动状态处理

    private func handleScrollGeometry(_ geo: ScrollGeometry) {
        let offset = geo.contentOffset.y
        let maxOffset = max(1, geo.contentSize.height - geo.containerSize.height)
        scrollProgress = min(1, max(0, Double(offset) / Double(maxOffset)))

        // 当前分区：所有 minY <= 阅读位置阈值的最后一个分区
        if let sections = facility.sections {
            var current = 0
            for (index, _) in sections.enumerated() {
                if let minY = sectionMinYs[index], minY <= offset + 140 {
                    current = index
                }
            }
            if current != currentSectionIndex { currentSectionIndex = current }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showBackTop = offset > 620
            sectionPillVisible = offset > 540
        }
        // 轮盘若停留在预览位置未确认，正文一经滚动即回同步到正文当前分区
        if wheelPosition != currentSectionIndex {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                wheelPosition = currentSectionIndex
            }
        }
        // 阅读进度里程碑日志（50% / 100% 各记一次）
        if scrollProgress >= 0.5 && !progressMidLogged {
            progressMidLogged = true
            LogManager.shared.debugLog("facility", "阅读进度里程碑", context: [
                "facility": facility.name, "progress": "50%"
            ])
        }
        if scrollProgress >= 0.999 && !progressFullLogged {
            progressFullLogged = true
            LogManager.shared.debugLog("facility", "阅读进度里程碑", context: [
                "facility": facility.name, "progress": "100%"
            ])
        }
    }

    // MARK: - 顶部阅读进度条

    private var readingProgressBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(
                    colors: [Color.sjzAccent, Color.sjzTeal],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: max(0, CGFloat(scrollProgress) * geo.size.width))
        }
        .frame(height: 2.5)
        .opacity(scrollProgress > 0.003 ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: scrollProgress)
    }

    // MARK: - 顶部悬浮分区定位胶囊

    @ViewBuilder
    private func sectionPositionPill(proxy: ScrollViewProxy) -> some View {
        if sectionPillVisible, let sections = facility.sections, currentSectionIndex < sections.count {
            let color = accent(for: currentSectionIndex)
            let title = sectionTitles[currentSectionIndex]
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                LogManager.shared.info("facility", "分区定位胶囊点击", context: [
                    "facility": facility.name, "section": title
                ])
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    proxy.scrollTo("facilityDirectory", anchor: .top)
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text("\(currentSectionIndex + 1)/\(sectionTitles.count)")
                        .displayFont(11, weight: .bold).monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(title)
                        .displayFont(11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.sjzAccent.opacity(0.16), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
            .buttonStyle(FacilityPressStyle(scale: 0.95))
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("当前分区：\(title)")
        }
    }

    // MARK: - 回到顶部

    @ViewBuilder
    private func backToTopButton(proxy: ScrollViewProxy) -> some View {
        if showBackTop {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                LogManager.shared.info("facility", "回到顶部", context: ["facility": facility.name])
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo("facilityTop", anchor: .top)
                }
            } label: {
                Image(systemName: "arrow.up")
                    .displaySymbolFont(15, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.sjzAccent)
                            .shadow(color: Color.sjzAccent.opacity(0.4), radius: 10, y: 5)
                    )
            }
            .buttonStyle(FacilityPressStyle(scale: 0.92))
            .transition(.scale.combined(with: .opacity))
            .padding(.trailing, 18)
            .padding(.bottom, 24)
            .accessibilityLabel("回到顶部")
        }
    }

    // MARK: - 工具栏菜单（复制全文 / 重播入场动画）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    copyFullText()
                } label: {
                    Label("复制全文", systemImage: "doc.on.doc")
                        .displayLabelFont(17)
                }
                Button {
                    replayEntrance()
                } label: {
                    Label("重播入场动画", systemImage: "arrow.counterclockwise")
                        .displayLabelFont(17)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .displaySymbolFont(16, weight: .semibold)
                    .foregroundStyle(Color.sjzAccent)
            }
            .accessibilityLabel("更多操作")
        }
    }

    private func copyFullText() {
        let text = facilityMarkdownText
        UIPasteboard.general.string = text
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        LogManager.shared.info("facility", "复制全文", context: [
            "facility": facility.name, "characters": "\(text.count)"
        ])
        presentToast("全文已复制 · \(text.count) 字")
    }

    private var facilityMarkdownText: String {
        var lines: [String] = ["# \(facility.name)", "", facility.desc, ""]
        if let sections = facility.sections {
            for (i, section) in sections.enumerated() {
                let subtitle = section.subtitle.map { "（\($0)）" } ?? ""
                lines.append("## \(i + 1). \(section.title)\(subtitle)")
                lines.append(section.desc)
                if let pairs = section.infoPairs, !pairs.isEmpty {
                    lines.append(pairs.map { "- \($0.label)：\($0.value)" }.joined(separator: "\n"))
                }
                if !section.highlights.isEmpty {
                    lines.append(section.highlights.map { "- \($0)" }.joined(separator: "\n"))
                }
                lines.append("")
            }
        } else if !facility.details.isEmpty {
            lines.append("详细信息：")
            lines.append(facility.details.map { "- \($0)" }.joined(separator: "\n"))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func replayEntrance() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        LogManager.shared.info("facility", "重播入场动画", context: ["facility": facility.name])
        withAnimation(.easeOut(duration: 0.18)) { contentAppear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                contentAppear = true
            }
            presentToast("入场动画已重播")
        }
    }

    // MARK: - 状态提示（toast）

    private func presentToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { toastText = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            Text(toastText)
                .displayFont(12, weight: .semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 24)
                .accessibilityLabel("提示：\(toastText)")
        }
    }

    /// 分区卡片：编号徽章 + 标题/副题胶囊 + 描述 + 主题色高亮要点区
    private func facilitySectionCard(_ section: FacilitySection, index: Int) -> some View {
        let color = accent(for: index)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.13))
                        .frame(width: 36, height: 36)
                    Text("\(index + 1)")
                        .displayFont(15, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title)
                        .displayFont(17, weight: .bold)
                        .foregroundStyle(.primary)
                    if let subtitle = section.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .displayFont(11, weight: .medium)
                            .foregroundStyle(color.opacity(0.95))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.1), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            Text(section.desc)
                .displayFont(14)
                .foregroundStyle(.secondary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            // 键值指标区（规则/数据类信息：标签—数值成对展示）
            if let pairs = section.infoPairs, !pairs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(pairs.enumerated()), id: \.element.id) { pairIndex, pair in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(pair.label)
                                .displayFont(13)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(pair.value)
                                .displayFont(13, weight: .semibold)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 9)
                        if pairIndex < pairs.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            if !section.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(section.highlights, id: \.self) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .displaySymbolFont(13)
                                .foregroundStyle(color)
                                .padding(.top, 2)
                            Text(item)
                                .displayFont(13)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(color.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }
}

/// 按压动效按钮样式：轻按下沉 + 微缩，松手弹簧回弹（设施列表/目录胶囊/回顶按钮共用）
private struct FacilityPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 设施列表卡：主题渐变图标 + 双行简介 + 分区数徽章 + 错峰弹入
private struct FacilityCardLabel: View {
    let facility: Facility
    let index: Int
    let accent: Color
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 60, height: 60)
                    .shadow(color: accent.opacity(0.35), radius: 10, y: 6)
                Image(systemName: facility.icon)
                    .displaySymbolFont(24)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(facility.name)
                    .displayFont(15, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(facility.desc)
                    .displayFont(12).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            countChip
            Image(systemName: "chevron.right")
                .displaySymbolFont(10, weight: .medium).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(accent.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)
                .delay(Double(index) * 0.07)) {
                appeared = true
            }
        }
    }

    private var countChip: some View {
        let sectionCount = facility.sections?.count
        let text = sectionCount.map { "\($0) 分区" } ?? "\(facility.details.count) 项"
        return Text(text)
            .displayFont(10, weight: .semibold)
            .foregroundStyle(accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.12)))
    }
}

private struct InfoRow: View {
    let label: String; let value: String
    var body: some View {
        HStack {
            Text(label).displayFont(15).foregroundStyle(.secondary)
            Spacer()
            Text(value).displayFont(15).foregroundStyle(.primary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 16)
        }
    }
}

// MARK: - 我的

struct ProfileView: View {
    @ObservedObject private var data = DataService.shared
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showBookmarks = false
    @State private var showLogs = false
    @State private var showMessageCenter = false
    @State private var showAnnouncementDetail = false
    @ObservedObject private var messageCenterStore = MessageCenterStore.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @ObservedObject private var bookmarkReadManager = ReadStatusManager.shared
    // 日志入口采用快照式（onAppear 读取 + 关闭日志页后刷新）：
    // LogManager 为全 App 高频写入对象，直接观察会导致日志洪峰期「我的」页整页重渲染
    @State private var logEntrySubtitle = "查看日志、排查问题"
    @AppStorage("colorSchemePreference") private var colorSchemePreference: String = "system"
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.openURL) private var openURL

    private var resolvedColorScheme: ColorScheme {
        switch colorSchemePreference {
        case "light": return .light
        case "dark": return .dark
        default: return systemColorScheme  // 跟随系统时，使用实际系统设置
        }
    }

    /// 收藏中的未读数（入口状态直观可见）
    private var bookmarkUnreadCount: Int {
        bookmarkManager.unreadCount(readKeys: bookmarkReadManager.snapshot)
    }

    /// 收藏入口副标题：总数 + 未读提示
    private var bookmarkEntrySubtitle: String {
        let total = bookmarkManager.count
        guard total > 0 else { return "收藏文章，支持离线阅读与更新提醒" }
        let unread = bookmarkUnreadCount
        return unread > 0 ? "已收藏 \(total) 篇 · \(unread) 篇未读" : "已收藏 \(total) 篇文章"
    }

    /// 日志入口副标题快照：总量 + 今日新增 + 今日异常（状态直观可见，且不观察高频对象）
    private func refreshLogEntrySubtitle() {
        let stats = LogManager.shared.stats()
        guard stats.total > 0 else {
            logEntrySubtitle = "运行记录与崩溃日志，仅存本机"
            return
        }
        var parts = ["共 \(stats.total) 条"]
        if stats.today > 0 { parts.append("今日 \(stats.today)") }
        if stats.issueToday > 0 { parts.append("异常 \(stats.issueToday)") }
        logEntrySubtitle = parts.joined(separator: " · ")
    }

    #if DEBUG
    /// 实机自测渲染截图（仅 DEBUG + `-uiTestOpenLogs`）：把当前主窗口画面写入 Documents，
    /// 供 `devicectl device copy from` 回读后人工/模型视觉复核真机渲染效果
    private func captureSelfTestScreenshot(_ name: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        LogManager.shared.info("log", "自测截图开始", context: ["name": name, "scenes": "\(scenes.count)"])
        guard let scene = scenes.first else {
            LogManager.shared.warning("log", "自测截图失败：无窗口场景", context: ["name": name])
            return
        }
        let windows = scene.windows
        var topVC = windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windows.first?.rootViewController
        var depth = 0
        while let presented = topVC?.presentedViewController {
            topVC = presented
            depth += 1
        }
        LogManager.shared.info("log", "自测截图窗口清单", context: [
            "name": name, "windows": "\(windows.count)",
            "keyWindow": "\(windows.contains(where: { $0.isKeyWindow }))",
            "presentDepth": "\(depth)"
        ])
        let captureView: UIView
        if let topView = topVC?.view, depth > 0 {
            // sheet 等 presentation 由最上层容器承载：直接捕获其视图，避免漏掉弹出层内容
            captureView = topView
        } else if let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first {
            captureView = window
        } else {
            LogManager.shared.warning("log", "自测截图失败：无可用窗口", context: ["name": name])
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: captureView.bounds)
        let image = renderer.image { _ in
            captureView.drawHierarchy(in: captureView.bounds, afterScreenUpdates: false)
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            LogManager.shared.warning("log", "自测截图失败：编码失败", context: ["name": name])
            return
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfTest_\(name).jpg")
        do {
            try data.write(to: url, options: .atomic)
            LogManager.shared.info("log", "自测截图已保存", context: ["name": name, "bytes": "\(data.count)"])
        } catch {
            LogManager.shared.warning("log", "自测截图失败：写入失败", context: ["name": name, "error": error.localizedDescription])
        }
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                profileHeader
                AnnouncementBanner(onTap: { showAnnouncementDetail = true })
                menuCards
                dataStatusBadge
                if !data.recruitPhones.isEmpty { contactSection }
                if !data.footerLinks.isEmpty { linksPreview }
                versionInfo
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(resolvedColorScheme).sjzPresentationChrome() }
        .sheet(isPresented: $showAbout) { AboutView().preferredColorScheme(resolvedColorScheme).sjzPresentationChrome() }
        .sheet(isPresented: $showBookmarks) {
            NavigationStack { BookmarkListView() }.preferredColorScheme(resolvedColorScheme).sjzPresentationChrome()
        }
        .sheet(isPresented: $showLogs) {
            NavigationStack { LogListView() }.preferredColorScheme(resolvedColorScheme).sjzPresentationChrome()
        }
        .sheet(isPresented: $showAnnouncementDetail) {
            AnnouncementDetailView().preferredColorScheme(resolvedColorScheme).sjzPresentationChrome()
        }
        .sheet(isPresented: $showMessageCenter, onDismiss: {
            // onDismiss 在收起动画完成后触发：记录退场时刻，供机构动态通道 consume 轮询判据
            messageCenterStore.messageCenterDismissedAt = Date()
            LogManager.shared.debugLog("messageCenter", "消息中心页已关闭", context: [:])
        }) {
            NavigationStack { MessageCenterView() }.preferredColorScheme(resolvedColorScheme).sjzPresentationChrome()
        }
        .onChange(of: messageCenterStore.dismissRequest) { _, requestId in
            // 消息中心内点击消息 → 先关闭自身 sheet，让出收起动画后再走通知深链分发（防 sheet 叠加）
            guard requestId != nil else { return }
            messageCenterStore.dismissRequest = nil
            showMessageCenter = false
            LogManager.shared.debugLog("messageCenter", "消息中心深链投递：已请求关闭消息中心", context: [:])
        }
        .onAppear {
            refreshLogEntrySubtitle()
            #if DEBUG
            // 实机自测钩子（仅 DEBUG）：`devicectl device process launch <UDID> com.qinchao -uiTestOpenLogs`
            // 自动打开日志页 + 心跳探针 + 风暴样本，验证「页面打开后主线程持续存活、风暴防线生效」
            if ProcessInfo.processInfo.arguments.contains("-uiTestOpenLogs") {
                LogManager.shared.info("log", "实机自测：自动打开日志页", context: [:])
                showLogs = true
                Task { @MainActor in
                    // 渲染截图取证（真机画面）：页面打开 / 稳定后 / 风暴后各一张
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    captureSelfTestScreenshot("a_open")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    captureSelfTestScreenshot("b_settled")
                    for sample in 1...55 {
                        LogManager.shared.debugLog("log", "自测风暴样本", context: ["index": "\(sample)"])
                    }
                    LogManager.shared.info("log", "实机自测：风暴样本注入完成（55 条同内容）", context: [:])
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    captureSelfTestScreenshot("c_afterStorm")
                    for beat in 1...3 {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        LogManager.shared.info("log", "实机自测心跳 \(beat)/3", context: ["beat": "\(beat)"])
                    }
                }
            }
            #endif
        }
        .onChange(of: showLogs) { _, isPresented in
            // 日志页关闭后刷新入口状态快照
            if !isPresented { refreshLogEntrySubtitle() }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.sjzPrimary, Color.sjzAccent],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 112, height: 112)
                    .shadow(color: Color.sjzPrimary.opacity(0.35), radius: 20, y: 12)
                Image(systemName: "graduationcap.fill")
                    .displaySymbolFont(52).foregroundStyle(.white)
            }

            Text(SchoolInfo.name)
                .displayFont(24, weight: .bold).foregroundStyle(Color.sjzPrimary)
            Text(SchoolInfo.motto)
                .displayFont(14, weight: .medium)
                .foregroundStyle(Color.sjzGold)
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
        .background(
            LinearGradient(
                colors: [Color.sjzLight, Color.sjzLight.opacity(0.1)],
                startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 30)
        )
        .padding(.horizontal, 16)
    }

    private var menuCards: some View {
        VStack(spacing: 0) {
            MenuCard(
                icon: "bell.badge.fill",
                title: "消息中心",
                subtitle: messageCenterStore.latestItem.map {
                    "\(messageCenterStore.unreadCount > 0 ? "\(messageCenterStore.unreadCount) 条未读 · " : "")\($0.title)"
                } ?? "官网新内容会记录在这里",
                color: Color.sjzPrimary,
                action: { showMessageCenter = true },
                badge: messageCenterStore.unreadCount > 0 ? messageCenterStore.unreadCount : nil
            )
            Divider().padding(.leading, 60)
            MenuCard(
                icon: "bookmark.fill",
                title: "我的收藏",
                subtitle: bookmarkEntrySubtitle,
                color: Color.sjzGold
            ) {
                LogManager.shared.info("favorite", "收藏入口点击（我的页）", context: [
                    "count": "\(bookmarkManager.count)",
                    "unread": "\(bookmarkUnreadCount)"
                ])
                showBookmarks = true
            }
            Divider().padding(.leading, 60)
            AboutEntryCell { showAbout = true }
            Divider().padding(.leading, 60)
            MenuCard(
                icon: "gearshape.fill",
                title: "应用设置",
                subtitle: "缓存管理与设置",
                color: .gray
            ) { showSettings = true }
            Divider().padding(.leading, 60)
            MenuCard(
                icon: "terminal.fill",
                title: "应用日志",
                subtitle: logEntrySubtitle,
                color: Color.sjzTeal
            ) {
                let stats = LogManager.shared.stats()
                LogManager.shared.info("log", "日志入口点击（我的页）", context: [
                    "total": "\(stats.total)", "today": "\(stats.today)",
                    "issueToday": "\(stats.issueToday)"
                ])
                showLogs = true
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
        .padding(.horizontal, 16)
    }

    private var dataStatusBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(dataSourceColor).frame(width: 10, height: 10)
            Text("数据来源：\(data.dataSource)")
                .displayFont(11).foregroundStyle(.secondary)
            if data.isLoading {
                ProgressView().scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var dataSourceColor: Color {
        switch data.dataSource {
        case "服务器": return .green
        case "缓存": return .orange
        default: return .gray
        }
    }

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("联系方式", systemImage: "phone.fill")
                .displayLabelFont(12).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(data.recruitPhones, id: \.self) { phone in
                        Button {
                            if let url = URL(string: "tel://\(phone)") {
                                openURL(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "phone.fill").displaySymbolFont(11)
                                Text(phone).displayFont(12, weight: .medium)
                            }
                            .foregroundStyle(Color.sjzAccent)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.sjzLight, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var linksPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("友情链接", systemImage: "link")
                .displayLabelFont(12).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(data.footerLinks.prefix(6)) { link in
                        Link(destination: URL(string: link.href) ?? URL(string: "https://www.sxjzit.edu.cn")!) {
                            Text(link.name)
                                .displayFont(11, weight: .medium)
                                .foregroundStyle(Color.sjzAccent)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.sjzLight, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var versionInfo: some View {
        VStack(spacing: 10) {
            Text("山西晋中理工学院")
                .displayFont(17, weight: .semibold).foregroundStyle(Color.sjzPrimary)
            Text("校园移动应用 · v1.0")
                .displayFont(12).foregroundStyle(.secondary)
            Text("数据实时同步自学校官网")
                .displayFont(11).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

/// 「我的」学校概况豪华入口行：黄金徽章图标（光晕呼吸）+ 主题标题，保持菜单列表节奏
private struct AboutEntryCell: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.sjzGold.opacity(0.14))
                        .frame(width: 52, height: 52)
                        .phaseAnimator([false, true]) { view, phase in
                            view.scaleEffect(phase ? 1.06 : 0.92).opacity(phase ? 0.5 : 0.12)
                        } animation: { _ in
                            .easeInOut(duration: 2.6)
                        }
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(
                            colors: [Color.sjzGold, Color.sjzAccent.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 46, height: 46)
                        .shadow(color: Color.sjzGold.opacity(0.35), radius: 10, y: 6)
                    Image(systemName: "graduationcap.fill")
                        .displaySymbolFont(17)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("学校概况")
                        .displayFont(15, weight: .semibold).foregroundStyle(.primary)
                    Text("了解山西晋中理工学院")
                        .displayFont(12).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .displaySymbolFont(11, weight: .semibold)
                    .foregroundStyle(Color.sjzGold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .displayFont(15)
        .buttonStyle(FacilityPressStyle(scale: 0.98))
        .simultaneousGesture(
            TapGesture().onEnded {
                LogManager.shared.info("about", "我的-学校概况入口点击", context: [:])
            }
        )
    }
}

private struct MenuCard: View {
    let icon: String; let title: String; let subtitle: String
    let color: Color; let action: () -> Void
    var badge: Int? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(color).frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .displaySymbolFont(17).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .displayFont(15, weight: .medium).foregroundStyle(.primary)
                    Text(subtitle)
                        .displayFont(12).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let badge = badge, badge > 0 {
                    Text(badge >= 99 ? "99+" : "\(badge)")
                        .displayFont(10, weight: .bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color.red, Color.red.opacity(0.8)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .accessibilityLabel("\(badge) 条未读消息")
                }
                Image(systemName: "chevron.right")
                    .displaySymbolFont(12, weight: .medium).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 学校概况

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = DataService.shared
    @State private var contentAppear = false
    @State private var shimmerSwept = false
    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    heroHeader
                    VStack(spacing: 0) {
                        InfoRow(label: "学校类型", value: SchoolInfo.type)
                        InfoRow(label: "主管部门", value: SchoolInfo.affiliation)
                        InfoRow(label: "创办时间", value: SchoolInfo.foundedYear + "年")
                        InfoRow(label: "转设时间", value: SchoolInfo.convertedYear + "年")
                        InfoRow(label: "前身", value: SchoolInfo.predecessor)
                        InfoRow(label: "校庆日", value: SchoolInfo.anniversary)
                        InfoRow(label: "学校地址", value: SchoolInfo.address)
                        InfoRow(label: "招生电话", value: data.recruitPhones.first ?? SchoolInfo.phone)
                        InfoRow(label: "官方网站", value: "www.sxjzit.edu.cn")
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
                    .padding(.horizontal, 16)
                    .modifier(SJZRevealOnce(key: "about-info-rows", delay: 0.18))

                    VStack(alignment: .leading, spacing: 14) {
                        Label("学校简介", systemImage: "text.justify").displayLabelFont(17, weight: .semibold)
                        Text(SchoolInfo.description)
                            .displayFont(15).foregroundStyle(.secondary).lineSpacing(8)
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
                    .padding(.horizontal, 16)
                    .modifier(SJZRevealOnce(key: "about-desc", delay: 0.3))
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("学校概况").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            copyProfile()
                        } label: {
                            Label("复制学校档案", systemImage: "doc.on.doc")
                                .displayLabelFont(17)
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .displaySymbolFont(15, weight: .semibold)
                            .foregroundStyle(Color.sjzGold)
                    }
                    .accessibilityLabel("复制学校档案")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .displayFont(17)
                }
            }
            .overlay(alignment: .bottom) { toastOverlay }
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { contentAppear = true }
                shimmerSwept = true
                LogManager.shared.info("about", "学校概况页打开", context: [:])
            }
            .onDisappear {
                LogManager.shared.debugLog("about", "学校概况页关闭", context: [:])
            }
        }
    }

    /// 头部：金蓝渐变校徽（光晕/悬浮双呼吸）+ 一次性微光扫过 + 校训金边胶囊 + 弹簧入场
    private var heroHeader: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.sjzGold.opacity(0.16))
                    .frame(width: 132, height: 132)
                    .phaseAnimator([false, true]) { view, phase in
                        view.scaleEffect(phase ? 1.08 : 0.9).opacity(phase ? 0.5 : 0.12)
                    } animation: { _ in
                        .easeInOut(duration: 2.6)
                    }
                RoundedRectangle(cornerRadius: 30)
                    .fill(LinearGradient(
                        colors: [Color.sjzPrimary, Color.sjzGold.opacity(0.9)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .shadow(color: Color.sjzPrimary.opacity(0.3), radius: 18, y: 10)
                Image(systemName: "graduationcap.fill")
                    .displaySymbolFont(40).foregroundStyle(.white)
                    .phaseAnimator([false, true]) { content, phase in
                        content.offset(y: phase ? -3 : 3)
                    } animation: { _ in
                        .easeInOut(duration: 2.2)
                    }
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .rotationEffect(.degrees(18))
                        .offset(x: shimmerSwept ? geo.size.width * 1.8 : -geo.size.width * 0.8)
                        .frame(maxHeight: .infinity)
                        .animation(.easeOut(duration: 1.15).delay(0.3), value: shimmerSwept)
                        .blendMode(.screen)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
            Text(SchoolInfo.name)
                .displayFont(26, weight: .bold)
            Text(SchoolInfo.englishName)
                .displayFont(15).foregroundStyle(.secondary)
            Text(SchoolInfo.motto)
                .displayFont(13, weight: .semibold)
                .foregroundStyle(Color.sjzGold)
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background(Color.sjzLight, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.sjzGold.opacity(0.35), lineWidth: 1))
        }
        .padding(.top, 24)
        .opacity(contentAppear ? 1 : 0)
        .offset(y: contentAppear ? 0 : 14)
        .scaleEffect(contentAppear ? 1 : 0.92)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: contentAppear)
    }

    /// 复制完整学校档案（12 项）到剪贴板
    private func copyProfile() {
        let text = """
        学校全称：\(SchoolInfo.name)
        英文名：\(SchoolInfo.englishName)
        校训：\(SchoolInfo.motto)
        学校类型：\(SchoolInfo.type)
        主管部门：\(SchoolInfo.affiliation)
        创办时间：\(SchoolInfo.foundedYear)年
        转设时间：\(SchoolInfo.convertedYear)年
        前身：\(SchoolInfo.predecessor)
        校庆日：\(SchoolInfo.anniversary)
        学校地址：\(SchoolInfo.address)
        招生电话：\(data.recruitPhones.first ?? SchoolInfo.phone)
        官方网站：www.sxjzit.edu.cn
        """
        UIPasteboard.general.string = text
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        LogManager.shared.info("about", "复制学校档案", context: ["characters": "\(text.count)"])
        presentToast("学校档案已复制 · \(text.count) 字")
    }

    private func presentToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { toastText = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            Text(toastText)
                .displayFont(12, weight: .semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 24)
                .accessibilityLabel("提示：\(toastText)")
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = DataService.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var readManager = ReadStatusManager.shared
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @ObservedObject private var logManager = LogManager.shared
    @ObservedObject private var homeModuleManager = HomeModuleManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    @ObservedObject private var biometricManager = BiometricSecurityManager.shared
    @ObservedObject private var cacheModeManager = CacheModeManager.shared
    @ObservedObject private var weChatService = WeChatService.shared
    // 网络监测入口行采用快照式（@State + onAppear 读取 + 5s 节流刷新）：
    // 避免 @ObservedObject 因每秒采样发布导致整个设置表单频繁重算
    @State private var networkEntryInterface: String = "—"
    @State private var networkEntryStatus: String = "未知"
    @State private var networkEntryHealthScore: Int?
    @State private var networkEntryQuality: String = "系统未提供"
    @State private var networkEntryThroughput: String = "—"
    @State private var networkEntryTimer: Timer?

    /// 网络状态指示色（设置页链路状态行）
    private var networkStatusColor: Color {
        switch networkEntryStatus {
        case "已连接": return Color.sjzGreen
        case "等待连接": return Color.sjzOrange
        default: return Color.sjzRed
        }
    }

    /// 健康分指示色
    private var networkEntryHealthColor: Color {
        guard let score = networkEntryHealthScore else { return .secondary }
        switch score {
        case 85...: return Color.sjzGreen
        case 60...: return Color.sjzTeal
        default: return Color.sjzOrange
        }
    }

    /// 入口行快照刷新：读取监测中枢当前状态（页面可见期间 5s 一次）
    private func refreshNetworkEntrySnapshot(initial: Bool) {
        let monitor = SJZNetworkMonitor.shared
        networkEntryInterface = monitor.interfaceName
        networkEntryStatus = monitor.pathStatus
        networkEntryHealthScore = monitor.healthScore ?? monitor.lastPersistedProbe?.healthScore
        networkEntryQuality = monitor.linkQualityText
        let kb = monitor.instantaneousKBps
        networkEntryThroughput = kb >= 1024
            ? String(format: "%.2f MB/s", kb / 1024)
            : String(format: "%.1f KB/s", kb)
        if initial {
            LogManager.shared.debugLog("netmon", "设置页网络监测入口快照", context: [
                "interface": networkEntryInterface,
                "status": networkEntryStatus,
                "health": networkEntryHealthScore.map(String.init) ?? "pending",
                "quality": networkEntryQuality
            ])
        }
    }

    private func startNetworkEntryTimer() {
        stopNetworkEntryTimer()
        networkEntryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                self.refreshNetworkEntrySnapshot(initial: false)
            }
        }
        networkEntryTimer?.tolerance = 0.5
    }

    private func stopNetworkEntryTimer() {
        networkEntryTimer?.invalidate()
        networkEntryTimer = nil
    }
    @ObservedObject private var appIconManager = AppIconManager.shared
    @State private var showClearAlert = false
    @State private var showMarkAllReadAlert = false
    @State private var showClearBookmarksAlert = false
    @State private var showLogSettings = false
    @State private var showPrivacyPolicy = false
    @State private var isRequestingPermission = false
    @AppStorage("notificationPermissionRequested") private var permissionRequested: Bool = false

    private var lastCheckText: String {
        if let t = notificationManager.lastCheckTime {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "上次检查：\(formatter.string(from: t))"
        }
        return "尚未检查"
    }

    private var pollingIntervalText: String {
        switch notificationManager.pollingIntervalMinutes {
        case 15: return "15 分钟"
        case 30: return "30 分钟"
        case 60: return "1 小时"
        case 120: return "2 小时"
        default: return "\(notificationManager.pollingIntervalMinutes) 分钟"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 显示设置
                Section {
                    NavigationLink {
                        DisplaySettingsView()
                    } label: {
                        Label("显示设置", systemImage: "paintbrush.pointed.fill")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("外观 · 字号 · 主题色")
                            .displayFont(15)
                        Spacer()
                        HStack(spacing: 6) {
                            Text(displaySettings.appearanceMode.title)
                                .displayFont(12)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .displayFont(12)
                                .foregroundStyle(.tertiary)
                            Text(displaySettings.fontSizeTier.title)
                                .displayFont(12)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .displayFont(12)
                                .foregroundStyle(.tertiary)
                            Text(displaySettings.themeStyle.title)
                                .displayFont(12)
                                .foregroundStyle(.secondary)
                            if displaySettings.nonDefaultChangeCount > 0 {
                                Text("\(displaySettings.nonDefaultChangeCount)")
                                    .displayFont(10, weight: .bold, design: .rounded)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(displaySettings.themeStyle.color))
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                } header: {
                    Text("显示设置").displayFont(13, weight: .semibold)
                } footer: {
                    Text("外观模式、主题色、文字排版、屏幕亮度、自动锁定与辅助功能。")
                        .displayFont(13)
                }

                // MARK: 应用图标
                Section {
                    NavigationLink {
                        AppIconSettingsView()
                    } label: {
                        HStack {
                            Label("应用图标", systemImage: "app.badge")
                                .displayLabelFont(15)
                            Spacer()
                            Text(appIconManager.currentDisplayName)
                                .displayFont(13)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("应用图标").displayFont(13, weight: .semibold)
                } footer: {
                    Text("在经典主图标与多套专属配色之间一键切换，主屏幕、聚焦搜索与系统设置同步生效。")
                        .displayFont(13)
                }

                // MARK: 首页管理
                Section {
                    NavigationLink {
                        HomeModuleSettingsView()
                    } label: {
                        Label("首页模块管理", systemImage: "square.grid.2x2.fill")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("当前显示模块")
                            .displayFont(15)
                        Spacer()
                        Text("\(homeModuleManager.visibleOrderedModules.count) 个")
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("首页管理").displayFont(13, weight: .semibold)
                } footer: {
                    Text("按需显示或隐藏首页内容模块，并可自定义排列顺序。")
                        .displayFont(13)
                }

                // MARK: 微信集成
                Section {
                    NavigationLink {
                        WeChatIntegrationView()
                    } label: {
                        HStack {
                            Label("微信集成", systemImage: "bubble.left.and.bubble.right.fill")
                                .displayLabelFont(15)
                            Spacer()
                            WeChatAvailabilityBadge(availability: weChatService.availability)
                        }
                    }
                    HStack {
                        Text("分享 · 登录 · 小程序")
                            .displayFont(15)
                        Spacer()
                        Text(weChatService.configuration.isPlaceholder ? "待配置" : "已配置")
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("微信集成").displayFont(13, weight: .semibold)
                } footer: {
                    Text("将文章分享到微信好友 / 朋友圈 / 收藏，支持微信登录授权与小程序跳转；状态总览与 Universal Link 自检见子页。")
                        .displayFont(13)
                }

                // MARK: 安全中心
                Section {
                    NavigationLink {
                        BiometricSettingsView()
                    } label: {
                        Label("Face ID 解锁", systemImage: "faceid")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("冷启动 · 后台返回 · 敏感页面")
                            .displayFont(15)
                        Spacer()
                        Text(biometricManager.isEnabled ? "已开启" : "未开启")
                            .displayFont(13)
                            .foregroundStyle(biometricManager.isEnabled ? Color.sjzGreen : .secondary)
                    }
                } header: {
                    Text("安全中心").displayFont(13, weight: .semibold)
                } footer: {
                    Text("启用后面容 / 指纹验证将自动保护应用，锁定策略与降级机制可自定义。")
                        .displayFont(13)
                }

                // MARK: 学校官网更新通知
                Section {
                    if !notificationManager.isAuthorized {
                        // 未授权
                        VStack(spacing: 10) {
                            if permissionRequested {
                                // 已请求过但被拒绝：只能引导去系统设置
                                HStack {
                                    Label("通知权限已拒绝", systemImage: "bell.slash.fill")
                                        .displayLabelFont(15)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button("前往系统设置") {
                                        notificationManager.openSystemSettings()
                                    }
                                    .displayFont(13, weight: .medium)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.sjzAccent, in: Capsule())
                                    .foregroundStyle(.white)
                                }
                                Text("请在系统设置中打开「通知」→「允许通知」")
                                    .displayFont(12)
                                    .foregroundStyle(.secondary)
                            } else {
                                // 首次：弹出系统授权弹窗
                                HStack {
                                    Label("通知权限未开启", systemImage: "bell.slash.fill")
                                        .displayLabelFont(15)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    if isRequestingPermission {
                                        ProgressView()
                                    } else {
                                        Button("开启通知") {
                                            isRequestingPermission = true
                                            Task {
                                                let granted = await notificationManager.requestPermission()
                                                isRequestingPermission = false
                                                permissionRequested = true
                                                if !granted {
                                                    // 用户点了"不允许"，展示二次引导
                                                }
                                            }
                                        }
                                        .displayFont(13, weight: .medium)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Color.sjzAccent, in: Capsule())
                                        .foregroundStyle(.white)
                                    }
                                }
                            }
                        }
                    } else {
                        // 已授权：显示开关
                        Toggle(isOn: $notificationManager.isEnabled.animation()) {
                            Label("学校官网更新通知", systemImage: "bell.badge.fill")
                                .displayLabelFont(15)
                        }
                        .onChange(of: notificationManager.isEnabled) { _, newValue in
                            if newValue {
                                // 首次启用时，标记现有文章为已通知，避免推送历史文章
                                notificationManager.markExistingArticlesAsNotified()
                            }
                        }
                    }

                    // 通知测试中心
                    NavigationLink {
                        NotificationTestView()
                    } label: {
                        Label("通知测试", systemImage: "bell.and.waves.left.and.right.fill")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("权限 · 送达 · 横幅 · 点击跳转 · 角标")
                            .displayFont(15)
                        Spacer()
                        Text(notificationManager.isAuthorized ? "就绪" : "未授权")
                            .displayFont(13)
                            .foregroundStyle(notificationManager.isAuthorized ? Color.sjzGreen : .orange)
                    }

                    if notificationManager.isEnabled && notificationManager.isAuthorized {
                        // 轮询间隔
                        Picker("检查间隔", selection: $notificationManager.pollingIntervalMinutes) {
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("1 小时").tag(60)
                            Text("2 小时").tag(120)
                        }
                        .displayFont(15)

                        // 状态信息
                        HStack {
                            if notificationManager.isChecking {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.6)
                                    Text("正在检查...")
                                }
                            } else {
                                Text(lastCheckText)
                            }
                            Spacer()
                            if notificationManager.lastCheckError != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .displaySymbolFont(12).foregroundStyle(.orange)
                            }
                        }
                        .displayFont(13)
                        .foregroundStyle(.secondary)

                        // 上次检查错误
                        if let error = notificationManager.lastCheckError {
                            Text(error)
                                .displayFont(12)
                                .foregroundStyle(.orange)
                        }

                        // 立即检查按钮
                        Button {
                            Task { await notificationManager.checkForUpdates() }
                        } label: {
                            HStack {
                                Spacer()
                                Label("立即检查更新", systemImage: "arrow.clockwise")
                                    .displayFont(15)
                                Spacer()
                            }
                        }
                        .disabled(notificationManager.isChecking)
                    }
                } header: {
                    Text("官网上新通知").displayFont(13, weight: .semibold)
                } footer: {
                    if notificationManager.isAuthorized && notificationManager.isEnabled {
                        Text("App 将每隔\(pollingIntervalText)自动检查学校官网新闻更新，发现新文章时推送通知。每次最多推送 5 条。")
                            .displayFont(13)
                    } else if notificationManager.isAuthorized {
                        Text("开启上方开关，App 将自动检查学校官网新闻更新并推送通知。")
                            .displayFont(13)
                    } else {
                        Text("点击「开启通知」将弹出系统授权弹窗，允许后即可接收更新推送。")
                            .displayFont(13)
                    }
                }

                // MARK: 文章管理
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未读文章")
                                .displayFont(15)
                            Text("\(readManager.unreadCount(in: data.allNews)) 篇")
                                .displayFont(13)
                                .foregroundStyle(readManager.unreadCount(in: data.allNews) > 0 ? Color.sjzAccent : .secondary)
                        }
                        Spacer()
                        Button {
                            showMarkAllReadAlert = true
                        } label: {
                            Label("全部已读", systemImage: "checkmark.circle.fill")
                                .displayLabelFont(13, weight: .medium)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(readManager.unreadCount(in: data.allNews) > 0 ? Color.sjzAccent : Color.gray.opacity(0.3), in: Capsule())
                                .foregroundStyle(readManager.unreadCount(in: data.allNews) > 0 ? .white : .secondary)
                        }
                        .disabled(readManager.unreadCount(in: data.allNews) == 0)
                    }
                } header: {
                    Text("文章管理").displayFont(13, weight: .semibold)
                } footer: {
                    Text("进入文章详情自动标记已读，一键清空所有未读标记。")
                        .displayFont(13)
                }

                // MARK: 收藏设置
                Section {
                    // 收藏同步缓存开关
                    Toggle(isOn: $bookmarkManager.autoCacheContent) {
                        Label("收藏时自动缓存正文", systemImage: "arrow.down.doc.fill")
                            .displayLabelFont(15)
                    }

                    // 收藏上限
                    HStack {
                        Label("收藏上限", systemImage: "tray.full.fill")
                            .displayLabelFont(15)
                        Spacer()
                        Picker("", selection: $bookmarkManager.maxCount) {
                            Text("100 条").tag(100)
                            Text("300 条").tag(300)
                            Text("500 条").tag(500)
                            Text("1000 条").tag(1000)
                        }
                        .pickerStyle(.menu)
                        .displayFont(15)
                    }

                    // 收藏推送开关
                    Toggle(isOn: $bookmarkManager.pushOnUpdate) {
                        Label("收藏文章更新推送", systemImage: "bell.badge.fill")
                            .displayLabelFont(15)
                    }

                    // 收藏统计
                    HStack {
                        Text("已收藏")
                            .displayFont(15)
                        Spacer()
                        Text("\(bookmarkManager.count) 篇")
                            .displayFont(13)
                            .foregroundStyle(bookmarkManager.count > 0 ? Color.sjzGold : .secondary)
                    }

                    if bookmarkManager.count > 0 {
                        // 一键清空收藏
                        Button {
                            showClearBookmarksAlert = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("清空全部收藏", systemImage: "trash")
                                    .displayLabelFont(15)
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("收藏设置").displayFont(13, weight: .semibold)
                } footer: {
                    if bookmarkManager.autoCacheContent {
                        Text("开启后，收藏文章时将自动缓存正文与图片，支持离线阅读。")
                            .displayFont(13)
                    }
                    if bookmarkManager.pushOnUpdate {
                        Text("收藏的文章在官网原文更新时，将推送通知提醒。")
                            .displayFont(13)
                    }
                }

                // MARK: 网络监测
                Section {
                    NavigationLink {
                        NetworkMonitorView()
                    } label: {
                        Label("网络监测", systemImage: "network")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("链路状态")
                            .displayFont(15)
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(networkStatusColor)
                                .frame(width: 7, height: 7)
                            Text(networkEntryInterface)
                                .displayFont(13)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // 网络监测入口行（快照式 5s 节流刷新：避免每秒采样触发大表单重算，
                    // 页面可见期间定时读取一次最新链路/健康分/吞吐）
                    HStack {
                        Text("健康分 · 吞吐")
                            .displayFont(15)
                        Spacer()
                        HStack(spacing: 8) {
                            if let health = networkEntryHealthScore {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(networkEntryHealthColor)
                                        .frame(width: 7, height: 7)
                                    Text("\(health)")
                                        .displayFont(13, weight: .semibold)
                                        .monospacedDigit()
                                        .foregroundStyle(networkEntryHealthColor)
                                }
                            } else {
                                Text("待诊断")
                                    .displayFont(13)
                                    .foregroundStyle(.tertiary)
                            }
                            if networkEntryQuality != "系统未提供" {
                                Text(networkEntryQuality)
                                    .displayFont(10, weight: .semibold)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.sjzAccent.opacity(0.1)))
                                    .foregroundStyle(Color.sjzAccent)
                            }
                            Text(networkEntryThroughput)
                                .displayFont(13)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onAppear {
                        refreshNetworkEntrySnapshot(initial: true)
                        startNetworkEntryTimer()
                    }
                    .onDisappear {
                        stopNetworkEntryTimer()
                    }
                } header: {
                    Text("网络调试").displayFont(13, weight: .semibold)
                } footer: {
                    Text("实时吞吐、响应延迟、会话统计、带宽测速与健康诊断；数据仅在本机内存中聚合，不上传。")
                        .displayFont(13)
                }

                // MARK: 缓存模式
                Section {
                    NavigationLink {
                        CacheModeSettingsView()
                    } label: {
                        Label("缓存模式", systemImage: "tray.full.fill")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("当前模式")
                            .displayFont(15)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(cacheModeManager.mode.accentColor)
                                .frame(width: 8, height: 8)
                            Text(cacheModeManager.mode.title)
                                .displayFont(13, weight: .semibold)
                                .foregroundStyle(cacheModeManager.mode.accentColor)
                        }
                    }
                    HStack {
                        Text("缓存命中率")
                            .displayFont(15)
                        Spacer()
                        Text(cacheModeManager.hitRatePercent)
                            .displayFont(13, weight: .semibold)
                            .foregroundStyle(cacheModeManager.isCacheEnabled ? Color.sjzGreen : .secondary)
                    }
                    HStack {
                        Text("已节省流量")
                            .displayFont(15)
                        Spacer()
                        Text(cacheModeManager.savedTrafficFormatted)
                            .displayFont(13, weight: .medium)
                            .foregroundStyle(Color.sjzOrange)
                    }
                } header: {
                    Text("缓存模式").displayFont(13, weight: .semibold)
                } footer: {
                    if cacheModeManager.isCacheEnabled {
                        Text("缓存模式已开启，已浏览内容将被自动缓存，再次访问秒开呈现，有效节省流量。")
                            .displayFont(13)
                    } else {
                        Text("即时刷新模式，每次浏览实时加载最新内容。切换至缓存模式可获得更流畅的浏览体验。")
                            .displayFont(13)
                    }
                }

                // MARK: 应用日志
                Section {
                    NavigationLink {
                        LogSettingsView()
                    } label: {
                        Label("应用日志", systemImage: "terminal.fill")
                            .displayLabelFont(15)
                    }
                    HStack {
                        Text("今日日志")
                            .displayFont(15)
                        Spacer()
                        Text("\(todayLogCount()) 条")
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("总日志数")
                            .displayFont(15)
                        Spacer()
                        Text("\(logManager.entries.count) 条")
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("应用日志").displayFont(13, weight: .semibold)
                } footer: {
                    Text("日志仅存储在本地，不会自动上传。超过 \(logManager.retentionDays) 天的旧日志将自动清理，保留天数与容量上限可在日志设置中调整。")
                        .displayFont(13)
                }

                // MARK: 数据管理
                Section {
                    Button("清空缓存并恢复预置数据", role: .destructive) {
                        showClearAlert = true
                    }
                    .displayFont(15)
                } header: {
                    Text("数据管理").displayFont(13, weight: .semibold)
                }

                // MARK: 数据概览
                Section {
                    LabeledContent("新闻资讯", value: "\(data.news.count) 条")
                        .displayFont(15)
                    LabeledContent("学校荣誉", value: "\(data.honors.count) 条")
                        .displayFont(15)
                    LabeledContent("院系设置", value: "\(data.departments.count) 个")
                        .displayFont(15)
                    LabeledContent("校园视频", value: "\(data.videos.count) 个")
                        .displayFont(15)
                    LabeledContent("学生故事", value: "\(data.studentStories.count) 个")
                        .displayFont(15)
                    LabeledContent("教师风采", value: "\(data.teacherProfiles.count) 个")
                        .displayFont(15)
                    LabeledContent("校园风光", value: "\(data.campusSceneries.count) 个")
                        .displayFont(15)
                    LabeledContent("校园活动", value: "\(data.campusActivities.count) 个")
                        .displayFont(15)
                    LabeledContent("Banner", value: "\(data.banners.count) 个")
                        .displayFont(15)
                    LabeledContent("友情链接", value: "\(data.footerLinks.count) 个")
                        .displayFont(15)
                    LabeledContent("社交平台", value: "\(data.socialPlatforms.count) 个")
                        .displayFont(15)
                } header: {
                    Text("数据概览").displayFont(13, weight: .semibold)
                }

                // MARK: 隐私与协议
                Section {
                    Button {
                        LogManager.shared.info("settings", "点击隐私与协议入口")
                        showPrivacyPolicy = true
                    } label: {
                        HStack {
                            Label("隐私与协议", systemImage: "lock.shield.fill")
                                .displayLabelFont(15)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .displaySymbolFont(12)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                    .contentShape(Rectangle())
                } header: {
                    Text("隐私与协议").displayFont(13, weight: .semibold)
                } footer: {
                    Text("查看用户协议与隐私政策，了解您的权利与我们的承诺。")
                        .displayFont(13)
                }

                // MARK: 关于
                Section {
                    HStack {
                        Text("学校名称").displayFont(15)
                        Spacer(); Text(SchoolInfo.name).displayFont(15).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("学校官网").displayFont(15)
                        Spacer()
                        Link("www.sxjzit.edu.cn", destination: URL(string: SchoolInfo.website)!)
                            .displayFont(15)
                    }
                    HStack {
                        Text("招生电话").displayFont(15)
                        Spacer()
                        Text(data.recruitPhones.first ?? SchoolInfo.phone).displayFont(15).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("关于").displayFont(13, weight: .semibold)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .task {
                // 每次进入设置页时刷新通知授权状态（用户可能从系统设置返回）
                await notificationManager.refreshAuthorizationStatus()
                if notificationManager.isAuthorized { permissionRequested = false }
            }
            .onChange(of: bookmarkManager.maxCount) { _, _ in
                bookmarkManager.applyMaxCountLimit()
            }
            .onChange(of: bookmarkManager.pushOnUpdate) { _, _ in
                bookmarkManager.applyPushOnUpdateSetting()
            }
            .onAppear {
                // 网络监测入口行快照：进页读一次当前链路状态（不做实时订阅，
                // 避免每秒采样触发大表单重算）
                let monitor = SJZNetworkMonitor.shared
                networkEntryInterface = monitor.interfaceName
                networkEntryStatus = monitor.pathStatus
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .displayFont(17)
                }
            }
            .alert("确认清空缓存？", isPresented: $showClearAlert) {
                Button("取消", role: .cancel) {}
                Button("确认清空", role: .destructive) { data.clearCache() }
            } message: {
                Text("清空后将恢复为预置数据，下次打开APP会重新从学校官网同步。")
            }
            .alert("确认标记全部已读？", isPresented: $showMarkAllReadAlert) {
                Button("取消", role: .cancel) {}
                Button("全部已读") {
                    readManager.markAllAsRead()
                }
            } message: {
                Text("将当前所有文章标记为已读状态，未读蓝点将全部消失。")
            }
            .alert("确认清空全部收藏？", isPresented: $showClearBookmarksAlert) {
                Button("取消", role: .cancel) {}
                Button("确认清空", role: .destructive) {
                    bookmarkManager.clearAll()
                }
            } message: {
                Text("将移除全部 \(bookmarkManager.count) 篇收藏文章，此操作不可恢复。")
            }
            .sheet(isPresented: $showPrivacyPolicy) {
                NavigationStack {
                    PrivacyPolicyHomeView()
                }
                .sjzPresentationChrome()
            }
        }
    }

    private func todayLogCount() -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return logManager.entries.filter { calendar.isDate($0.timestamp, inSameDayAs: today) }.count
    }
}

// MARK: - 招生网首页

struct ZSWHomeView: View {
    @ObservedObject private var data = DataService.shared
    @State private var selectedGuideTab = 0
    

    var body: some View {
        ScrollView {
            if data.zswIsLoading && data.zswHomeData == nil {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在加载招生信息...").displayFont(12).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 80)
            } else if let home = data.zswHomeData {
                VStack(spacing: 24) {
                    // 1. 首页三栏目（录取查询、历年分数线、专业介绍）
                    if !home.recruitItems.isEmpty {
                        zswRecruitSection(items: home.recruitItems)
                    }

                    // 2. 招生计划
                    if let plan = home.enrollmentPlan, !plan.articles.isEmpty {
                        zswSection(plan, icon: "doc.text.fill", color: Color(hex: "1A73E8"))
                    }

                    // 3. 招生公告
                    if let notices = home.notices, !notices.articles.isEmpty {
                        zswSection(notices, icon: "megaphone.fill", color: Color.sjzOrange)
                    }

                    // 4. 报考指南（含4个子栏目）
                    if !home.guideChildren.isEmpty {
                        zswGuideSection(children: home.guideChildren, selectedTab: $selectedGuideTab)
                    }

                    // 5. 招生动态
                    if let enews = home.enrollmentNews, !enews.articles.isEmpty {
                        zswSection(enews, icon: "sparkles", color: Color.sjzPurple)
                    }
                }
                .padding(.bottom, 40)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "tray").displaySymbolFont(48).foregroundStyle(.secondary.opacity(0.15))
                    Text("招生信息加载失败").displayFont(15).foregroundStyle(.secondary)
                    Button("重新加载") {
                        Task { await data.loadZSWHomeData() }
                    }
                    .displayFont(14, weight: .medium)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color(hex: "1A73E8"), in: Capsule())
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 80)
            }
        }
        .refreshable { await data.loadZSWHomeData() }
    }

    // MARK: - 首页三栏目

    private func zswRecruitSection(items: [ZSWRecruitItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷入口").displayFont(18, weight: .bold).padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        if !item.articles.isEmpty {
                            // 有文章列表（历年分数线）：导航到列表页，禁用分页
                            NavigationLink {
                                ZSWArticleListView(
                                    title: item.titleCn,
                                    siteId: data.zswHomeData?.siteId ?? "",
                                    columnId: item.id,
                                    articles: item.articles,
                                    disablePagination: true
                                )
                            } label: {
                                recruitCard(item: item)
                            }
                            .buttonStyle(.plain)
                        } else if let url = URL(string: item.href), item.href.hasPrefix("http") {
                            // 有外部链接（录取查询）：打开 Safari
                            Link(destination: url) {
                                recruitCard(item: item)
                            }
                            .displayFont(13)
                            .buttonStyle(.plain)
                        } else {
                            // 专业介绍：导航到APP内专业介绍列表页
                            NavigationLink {
                                SpecialtyListView()
                            } label: {
                                recruitCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func recruitCard(item: ZSWRecruitItem) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: "1A73E8").opacity(0.06))
                    .frame(width: 110, height: 110)

                if isZSWImageSupported(item.imageUrl), let url = zswSafeURL(from: item.imageUrl!) {
                    SJZCachedImage(url: url, maxPixel: 180) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(width: 60, height: 60)
                        default:
                            Image(systemName: "doc.text.magnifyingglass")
                                .displaySymbolFont(32).foregroundStyle(Color(hex: "1A73E8").opacity(0.3))
                        }
                    }
                } else {
                    Image(systemName: "doc.text.magnifyingglass")
                        .displaySymbolFont(32).foregroundStyle(Color(hex: "1A73E8").opacity(0.3))
                }
            }

            Text(item.titleCn)
                .displayFont(13, weight: .medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(width: 110)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 通用栏目

    private func zswSection(_ section: ZSWSection, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(section.titleCn, systemImage: icon)
                    .displayLabelFont(18, weight: .bold)
                    .foregroundStyle(color)
                Spacer()
                if section.articles.count > 5 {
                    NavigationLink {
                        ZSWArticleListView(
                            title: section.titleCn,
                            siteId: data.zswHomeData?.siteId ?? "",
                            columnId: section.columnId,
                            articles: section.articles
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看更多").displayFont(12)
                            Image(systemName: "chevron.right").displaySymbolFont(10)
                        }
                        .foregroundStyle(color)
                    }
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(section.articles.prefix(8).enumerated()), id: \.element.id) { idx, article in
                        NavigationLink {
                            ZSWArticleDetailView(article: article, siteId: data.zswHomeData?.siteId ?? "")
                        } label: {
                            zswArticleCard(article: article, color: color)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func zswArticleCard(article: ZSWArticle, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 图片
            ZStack {
                if isZSWImageSupported(article.imageUrl), let url = zswSafeURL(from: article.imageUrl!) {
                    SJZCachedImage(url: url, maxPixel: 600) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            cardPlaceholder(color: color)
                        }
                    }
                } else {
                    cardPlaceholder(color: color)
                }
            }
            .frame(width: 200, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // 文字
            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .displayFont(13, weight: .medium)
                    .lineLimit(2).foregroundStyle(.primary)
                if let date = article.updateTime {
                    Text(formatZSWDate(date))
                        .displayFont(11).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 10)
        }
        .frame(width: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }

    /// 图片加载失败或不支持时的占位符
    private func cardPlaceholder(color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .fill(color.opacity(0.06))
            Image(systemName: "photo")
                .displaySymbolFont(32)
                .foregroundStyle(color.opacity(0.2))
        }
    }

    // MARK: - 报考指南（Tab 切换）

    private func zswGuideSection(children: [ZSWGuideChild], selectedTab: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("报考指南", systemImage: "book.fill")
                .displayLabelFont(18, weight: .bold)
                .foregroundStyle(Color(hex: "1A73E8"))
                .padding(.horizontal, 16)

            // Tab 栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                selectedTab.wrappedValue = idx
                            }
                        } label: {
                            Text(child.titleCn)
                                .displayFont(13, weight: selectedTab.wrappedValue == idx ? .semibold : .regular)
                                .foregroundStyle(selectedTab.wrappedValue == idx ? .white : Color(hex: "1A73E8"))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(
                                    selectedTab.wrappedValue == idx
                                    ? Color(hex: "1A73E8")
                                    : Color(hex: "1A73E8").opacity(0.08),
                                    in: Capsule()
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // 当前 Tab 内容
            if selectedTab.wrappedValue < children.count {
                let child = children[selectedTab.wrappedValue]
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(child.articles.enumerated()), id: \.element.id) { idx, article in
                            NavigationLink {
                                ZSWArticleDetailView(article: article, siteId: data.zswHomeData?.siteId ?? "")
                            } label: {
                                zswArticleCard(article: article, color: Color(hex: "1A73E8"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

// MARK: - 招生网文章列表

struct ZSWArticleListView: View {
    let title: String
    let siteId: String
    let columnId: String
    let articles: [ZSWArticle]
    var disablePagination: Bool = false
    @State private var allArticles: [ZSWArticle] = []
    @State private var isLoading = false
    @State private var currentPage = 0
    @State private var totalCount = 0
    @State private var hasMorePages = true

    init(title: String, siteId: String, columnId: String, articles: [ZSWArticle], disablePagination: Bool = false) {
        self.title = title
        self.siteId = siteId
        self.columnId = columnId
        self.articles = articles
        self.disablePagination = disablePagination
        _hasMorePages = State(initialValue: !disablePagination)
    }

    var body: some View {
        List {
            ForEach(allArticles.isEmpty ? articles : allArticles) { article in
                NavigationLink {
                    ZSWArticleDetailView(article: article, siteId: siteId)
                } label: {
                    HStack(spacing: 14) {
                        zswListThumbnail(article: article)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(article.title)
                                .displayFont(14, weight: .medium).lineLimit(2)
                            if let date = article.updateTime {
                                Text(formatZSWDate(date))
                                    .displayFont(11).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            if !disablePagination && hasMorePages && !isLoading {
                HStack {
                    Spacer()
                    Button("加载更多") {
                        Task { await loadMore() }
                    }
                    .displayFont(14)
                    Spacer()
                }
                .padding(.vertical, 12)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task {
            if allArticles.isEmpty {
                allArticles = articles
                if !disablePagination {
                    await loadMore()
                }
            }
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let nextPage = currentPage + 1
            let dto = try await NetworkService.shared.fetchZSWArticlePage(
                siteId: siteId, columnId: columnId,
                page: nextPage, size: 20
            )
            totalCount = dto.total ?? 0
            // 分页留痕（2026-09-30 修复 pageNo 失效后，页号/累计/总量可对账）
            LogManager.shared.debugLog("ui", "招生网列表加载更多", context: [
                "page": "\(nextPage)", "size": "20",
                "got": "\(dto.list?.count ?? 0)", "total": "\(totalCount)"
            ])
            let newArticles = (dto.list ?? []).compactMap { a -> ZSWArticle? in
                guard let title = a.title, !title.isEmpty else { return nil }
                return ZSWArticle(articleId: a.id, title: title,
                                  description: a.description ?? "",
                                  imageUrl: a.imageUrl, updateTime: a.updateTime, tag: a.tag)
            }
            // 去重
            let existingIds = Set(allArticles.map { $0.articleId })
            let uniqueNew = newArticles.filter { article in
                guard let aid = article.articleId else { return true }
                return !existingIds.contains(aid)
            }
            if !uniqueNew.isEmpty {
                allArticles.append(contentsOf: uniqueNew)
            }
            currentPage = nextPage
            hasMorePages = allArticles.count < totalCount && !newArticles.isEmpty
        } catch {
            hasMorePages = false
        }
    }

    private func zswListThumbnail(article: ZSWArticle) -> some View {
        Group {
            if isZSWImageSupported(article.imageUrl), let url = zswSafeURL(from: article.imageUrl!) {
                SJZCachedImage(url: url, maxPixel: 210) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color(hex: "1A73E8").opacity(0.06)
                    }
                }
                .frame(width: 70, height: 54).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "1A73E8").opacity(0.06))
                        .frame(width: 70, height: 54)
                    Image(systemName: "doc.text.fill")
                        .displaySymbolFont(12).foregroundStyle(Color(hex: "1A73E8").opacity(0.15))
                }
            }
        }
        // 统一时长角标：缩略图右下角（全文口径优先，摘要估算兜底，全 App 规范一致）
        .overlay(alignment: .bottomTrailing) {
            ReadingTimeBadgeView(cachedID: article.articleId ?? article.title, summary: article.description)
                .padding(3)
        }
    }
}

// MARK: - 招生网文章详情

struct ZSWArticleDetailView: View {
    let article: ZSWArticle
    let siteId: String
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    /// 看图载荷（item 式呈现：根治「先显示第一张」的陈旧快照 + 支持左右翻页）
    @State private var imageViewerPayload: SJZImageGalleryPayload?
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared
    // 画廊计数（E1/F3）：已成功加载的图片索引集合，驱动确定型进度条
    @State private var galleryLoadedIndices: Set<Int> = []
    @State private var showGalleryBar = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 头图
                if isZSWImageSupported(article.imageUrl), let url = zswSafeURL(from: article.imageUrl!) {
                    SJZCachedImage(url: url, maxPixel: 900) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 280)
                                .onTapGesture {
                                    imageViewerPayload = SJZImageGalleryPayload.single(url: url, source: "header")
                                    LogManager.shared.debugLog("imageViewer", "查看图片（头图）", context: [
                                        "url": url.lastPathComponent
                                    ])
                                }
                        default:
                            if let hex = SJZAverageColorCache.colorHex(for: url) {
                                // 二次访问：以平均色瞬时占位（blur-up 本地化），消除白闪
                                Color(hex: hex).frame(height: 240)
                            } else {
                                detailHeaderPlaceholder
                            }
                        }
                    }
                } else {
                    detailHeaderPlaceholder
                }

                VStack(alignment: .leading, spacing: 24) {
                    // 标题
                    Text(fullDetail?.title ?? article.title)
                        .displayFont(22, weight: .bold)

                    // 日期和元信息
                    HStack(spacing: 16) {
                        if let date = fullDetail?.publishTime, !date.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar").displaySymbolFont(12)
                                Text(formatZSWDate(date))
                            }
                        } else if let date = article.updateTime {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar").displaySymbolFont(12)
                                Text(formatZSWDate(date))
                            }
                        }
                        if let author = fullDetail?.author, !author.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill").displaySymbolFont(11)
                                Text(author)
                            }
                        }
                        if let source = fullDetail?.source, !source.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link").displaySymbolFont(11)
                                Text(source)
                            }
                        }
                        if let detail = fullDetail {
                            let statsText = detail.plainTextContent.isEmpty
                                ? detail.content.strippingHTMLTags()
                                : detail.plainTextContent
                            if !statsText.isEmpty {
                                ArticleReadingStatsText(
                                    cachedID: article.articleId ?? article.title,
                                    plainText: statsText,
                                    imageCount: detail.images.count
                                )
                            }
                        }
                    }
                    .displayFont(12)
                    .foregroundStyle(.secondary)

                    Divider()

                    // 加载状态（骨架屏 + 统一优雅加载组件）
                    if isLoading {
                        VStack(alignment: .leading, spacing: 0) {
                            ArticleSkeletonRows()
                                .padding(.bottom, 20)
                            SJZArticleLoadingView(
                                phases: ["正在获取完整内容…", "正在解析图片与排版…", "即将呈现…"],
                                accent: Color(hex: "1A73E8")
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text(error).displayFont(13).foregroundStyle(.orange)
                            }
                            .padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                            if !article.description.isEmpty {
                                // 加载失败兜底摘要同样展示统计
                                ArticleReadingStatsText(
                                    cachedID: article.articleId ?? article.title,
                                    plainText: article.description
                                )
                                Text(article.description)
                                    .displayFont(16).lineSpacing(10).foregroundStyle(displaySettings.articleBodyColor ?? .secondary)
                            }

                            Button {
                                Task { await loadDetail() }
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("重新加载", systemImage: "arrow.clockwise")
                                        .displayLabelFont(14, weight: .medium)
                                    Spacer()
                                }
                                .foregroundStyle(.white).padding(.vertical, 12)
                                .background(Color(hex: "1A73E8"), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    } else if let detail = fullDetail {
                        // 正文
                        Text(detail.plainTextContent.isEmpty ? detail.content.strippingHTMLTags() : detail.plainTextContent)
                            .displayFont(16).lineSpacing(10).foregroundStyle(displaySettings.articleBodyColor ?? .secondary)

                        // 图片画廊（带确定型计数条：全部加载完成后 1s 自动渐隐）
                        if !detail.images.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .center) {
                                    Text("图片").displayFont(16, weight: .semibold)
                                    Spacer()
                                    if showGalleryBar {
                                        SJZGalleryProgressBar(
                                            loaded: galleryLoadedIndices.count,
                                            total: detail.images.count
                                        )
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                .padding(.top, 8)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                                    ForEach(Array(detail.images.enumerated()), id: \.offset) { idx, img in
                                        if let url = URL(string: img.url) {
                                            SJZCachedImage(url: url, maxPixel: 300) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                        .frame(width: 100, height: 100)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                                        .onTapGesture {
                                                            imageViewerPayload = SJZImageGalleryPayload.make(
                                                                images: detail.images, tappedIndex: idx, source: "grid")
                                                            LogManager.shared.debugLog("imageViewer", "查看图片（图集网格）", context: [
                                                                "index": "\(idx + 1)/\(detail.images.count)",
                                                                "url": img.url
                                                            ])
                                                        }
                                                case .failure:
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(Color.secondary.opacity(0.1))
                                                        .frame(width: 100, height: 100)
                                                case .empty:
                                                    ZStack {
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .fill(Color.secondary.opacity(0.1))
                                                            .frame(width: 100, height: 100)
                                                        ShimmerView().clipShape(RoundedRectangle(cornerRadius: 10))
                                                    }
                                                case .skipped:
                                                    // 无图模式：优雅静态占位（不起网络）
                                                    SJZImageFreePlaceholder()
                                                        .frame(width: 100, height: 100)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                                }
                                            }
                                            .onPhaseChange { newPhase in
                                                handleGalleryPhase(idx: idx, phase: newPhase)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // 无articleId，显示摘要
                        Text(article.description)
                            .displayFont(16).lineSpacing(10).foregroundStyle(displaySettings.articleBodyColor ?? .secondary)
                    }
                }
                .padding(24)
            }
        }
        // 顶部彩虹进度条：等待正文（不定型扫描）→ 正文就绪后图片画廊真实进度
        // 拆分为独立属性，降低超大视图表达式的类型检查复杂度
        .overlay(alignment: .top) { zswTopProgressBar }
        .navigationTitle("文章详情").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $imageViewerPayload) { payload in
            FullScreenImageView(payload: payload, fallbackTitle: fullDetail?.title ?? article.title)
                .sjzPresentationChrome()
        }
        .task {
            await loadDetail()
        }
    }

    /// 顶部彩虹进度指示：等待正文（不定型扫描）→ 招生网图片画廊真实进度（完成自动打勾渐隐）
    @ViewBuilder
    private var zswTopProgressBar: some View {
        if isLoading {
            SJZPageLoadProgressBar(indeterminate: true)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if let detail = fullDetail, !detail.images.isEmpty, showGalleryBar {
            SJZPageLoadProgressBar(
                percent: Double(galleryLoadedIndices.count) / Double(detail.images.count),
                label: "\(galleryLoadedIndices.count)/\(detail.images.count)"
            )
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func loadDetail() async {
        guard let articleId = article.articleId else {
            isLoading = false
            LogManager.shared.debugLog("ui", "招生网文章无 articleId，跳过加载", context: ["title": article.title])
            return
        }
        if fullDetail != nil && cacheManager.isCacheEnabled {
            LogManager.shared.debugLog("ui", "缓存模式下招生网文章详情已加载，跳过重复请求", context: [
                "articleId": articleId, "title": article.title
            ])
            return
        }
        isLoading = true
        loadError = nil
        LogManager.shared.info("ui", "开始加载招生网文章详情", context: ["articleId": articleId, "title": article.title, "siteId": siteId])
        do {
            fullDetail = try await DataService.shared.loadZSWArticleFullDetail(
                articleId: articleId, siteId: siteId
            )
            LogManager.shared.info("ui", "招生网文章详情加载成功", context: [
                "articleId": articleId, "title": fullDetail?.title ?? "",
                "images": "\(fullDetail?.images.count ?? 0)"
            ])
            // E1：预取画廊前 3 张图片（并发≤4，命中即跳过）
            if let detail = fullDetail, !detail.images.isEmpty {
                let urls = detail.images.prefix(3).compactMap { URL(string: $0.url) }
                Task { await SJZImagePrefetcher.prefetch(urls: urls) }
            }
        } catch {
            loadError = "文章详情加载失败，请检查网络连接后重试"
            LogManager.shared.error("ui", "招生网文章详情加载失败", context: [
                "articleId": articleId, "title": article.title, "error": error.localizedDescription
            ])
        }
        isLoading = false
    }

    /// 画廊计数联动：图片成功→计数+1；全部完成→记录日志并 1s 后渐隐进度条
    private func handleGalleryPhase(idx: Int, phase: SJZImagePhase) {
        switch phase {
        case .success:
            galleryLoadedIndices.insert(idx)
            if !showGalleryBar {
                withAnimation(.easeIn(duration: 0.2)) { showGalleryBar = true }
            }
            if let detail = fullDetail, galleryLoadedIndices.count >= detail.images.count {
                LogManager.shared.info("ui", "招生网画廊图片全部加载完成", context: [
                    "articleId": article.articleId ?? "nil",
                    "total": "\(detail.images.count)"
                ])
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    withAnimation(.easeOut(duration: 0.3)) { showGalleryBar = false }
                }
            }
        case .empty:
            if !showGalleryBar {
                withAnimation(.easeIn(duration: 0.2)) { showGalleryBar = true }
            }
        case .failure:
            break
        case .skipped:
            // 无图模式：不推进画廊计数条（占位渲染由图片组件负责）
            break
        }
    }

    private var detailHeaderPlaceholder: some View {
        LinearGradient(
            colors: [Color(hex: "1A73E8").opacity(0.04), Color(hex: "1A73E8").opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 200)
        .overlay {
            Image(systemName: "doc.text.fill")
                .displaySymbolFont(60).foregroundStyle(Color(hex: "1A73E8").opacity(0.06))
        }
    }
}

// MARK: - 招生网工具函数

/// 检测图片 URL 是否为有效图片（过滤无图片占位符）
private func isZSWImageSupported(_ urlString: String?) -> Bool {
    guard let urlString else { return false }
    let lower = urlString.lowercased()
    // 无图片占位符
    if lower.contains("no_picture") { return false }
    return true
}

/// 安全创建 URL，处理中文和空格等非 ASCII 字符
private func zswSafeURL(from string: String) -> URL? {
    if let url = URL(string: string) {
        return url
    }
    // 百分号编码非 ASCII 字符，同时保留 URL 结构字符
    var allowed = CharacterSet.urlQueryAllowed
    allowed.insert(charactersIn: "#%")
    guard let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed) else {
        return nil
    }
    return URL(string: encoded)
}

// MARK: - 统一缓存图片组件（全 App 共享：缓存模式联动 / 下载进度 / 降采样 / 渐进呈现 / 自动重试）

/// 滚动中暂停图片加载的环境键（E10：滚动帧率优先）
struct SJZScrollSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 为 true 时新图片加载会等待滚动静止后再开始（E10 滚动让路）
    var sjzImageLoadingSuspended: Bool {
        get { self[SJZScrollSuspendedKey.self] }
        set { self[SJZScrollSuspendedKey.self] = newValue }
    }
}

/// 滚动状态跟踪修饰器（iOS 18+ 使用 onScrollPhaseChange；低版本不启用，零影响）
struct SJZScrollSuspendModifier: ViewModifier {
    @Binding var suspended: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                suspended = (newPhase != .idle)
            }
        } else {
            content
        }
    }
}

extension View {
    /// 跟踪滚动状态到 Binding（E10 滚动让路的列表侧接入）
    func sjzScrollSuspendTrack(_ suspended: Binding<Bool>) -> some View {
        modifier(SJZScrollSuspendModifier(suspended: suspended))
    }
}

/// 图片加载阶段（与 AsyncImagePhase 对齐，便于机械化替换）
enum SJZImagePhase {
    /// 加载中（progress 非 nil 时为 0-1 下载进度，nil 表示长度未知）
    case empty(progress: Double?)
    case success(Image)
    case failure
    /// 无图模式跳过加载（不占用网络，统一渲染优雅占位）
    case skipped
}

/// 无图模式统一占位：静态柔和渐变 + 图像图标（无动画省电省流，明暗自适应）
struct SJZImageFreePlaceholder: View {
    var icon: String = "photo"
    var tone: Color = Color.sjzTeal

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [tone.opacity(0.1), Color.secondary.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: icon)
                .displaySymbolFont(15, weight: .medium)
                .foregroundStyle(tone.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 统一图片加载器视图。
/// - 与 AsyncImage 三态闭包同构；所有页面图片统一经此加载：
///   缓存命中预判统计、缓存模式联动、下载进度、ImageIO 降采样、平均色渐进占位、失败自动重试。
/// - `.task(id: SJZLoadToken)` 驱动，视图复用/换 URL 自动重启，Task.isCancelled 防护。
struct SJZCachedImage<Content: View>: View {
    let url: URL?
    /// 目标最大显示边长（点→像素近似）。>0 启用 ImageIO 降采样；nil 使用原图（全屏查看等场景）
    let maxPixel: CGFloat?
    /// 阶段变化回调（主线程），用于画廊计数条等外部状态
    var onPhaseChange: ((SJZImagePhase) -> Void)?

    @ViewBuilder let content: (SJZImagePhase) -> Content

    @State private var phase: SJZImagePhase = .empty(progress: nil)
    @State private var attempt = 0
    @ObservedObject private var cacheManager = CacheModeManager.shared
    /// E10 滚动让路：滚动中暂停开始新加载，帧率优先
    @Environment(\.sjzImageLoadingSuspended) private var loadingSuspended

    init(url: URL?,
         maxPixel: CGFloat? = SJZImageKit.defaultThumbnailPixel,
         onPhaseChange: ((SJZImagePhase) -> Void)? = nil,
         @ViewBuilder content: @escaping (SJZImagePhase) -> Content) {
        self.url = url
        self.maxPixel = maxPixel
        self.onPhaseChange = onPhaseChange
        self.content = content
        // 零闪烁关键：视图初始化即同步查解码图内存缓存，命中则首帧直接出图，
        // 滚动回收重建时不再出现任何占位帧。
        // 无图模式：初始化即短路为优雅占位，完全不起网络。
        let initialPhase: SJZImagePhase
        if SJZImageKit.isImageFreeModeFromAnyThread {
            initialPhase = .skipped
        } else if let url,
                  let cachedImage = SJZDecodedImageCache.shared.image(
                      forKey: SJZDecodedImageCache.key(url: url, maxPixel: maxPixel)) {
            initialPhase = .success(Image(uiImage: cachedImage))
        } else {
            initialPhase = .empty(progress: nil)
        }
        self._phase = State(initialValue: initialPhase)
    }

    var body: some View {
        content(phase)
            .contentShape(Rectangle())
            .overlay {
                // 失败态透明遮罩承接"轻点重试"，仅失败时存在，
                // 成功态不拦截任何手势（外部全屏点击等正常生效）
                if case .failure = phase {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            attempt += 1
                            LogManager.shared.debugLog("imageCache", "用户轻点重试图片", context: [
                                "url": url?.lastPathComponent ?? "nil"
                            ])
                        }
                }
            }
            .task(id: SJZLoadToken(url: url, attempt: attempt, freeMode: SJZImageKit.isImageFreeModeFromAnyThread)) {
                await load()
            }
    }

    /// 手动重试（失败态由外层"轻点重试"触发）
    func retry() {
        attempt += 1
    }

    // MARK: 加载管线

    private func load() async {
        guard let url else {
            phase = .failure
            onPhaseChange?(.failure)
            LogManager.shared.warning("imageCache", "图片 URL 无效", context: [:])
            return
        }
        guard !Task.isCancelled else { return }

        // 无图模式短路：完全不起网络，渲染优雅占位。
        // 计数持久化（主线程侧）+ 节流日志（每 URL 仅首见），供设置页状态胶囊直观展示。
        if SJZImageKit.isImageFreeModeFromAnyThread {
            phase = .skipped
            onPhaseChange?(.skipped)
            let logKey = "free:\(url.absoluteString)"
            if SJZImageKit.shouldLogHit(logKey) {
                Task { @MainActor in
                    CacheModeManager.shared.recordImageSkipped()
                    LogManager.shared.info("imageCache", "图片跳过加载（无图模式）", context: [
                        "url": url.lastPathComponent,
                        "skippedTotal": "\(CacheModeManager.shared.imageFreeSkippedCount)"
                    ])
                }
            } else {
                Task { @MainActor in
                    CacheModeManager.shared.recordImageSkipped()
                }
            }
            return
        }

        // ① 解码图内存缓存直出（零闪烁）：命中即同步渲染，不出现占位帧、不重复解码
        let memoryKey = SJZDecodedImageCache.key(url: url, maxPixel: maxPixel)
        if let memoryImage = SJZDecodedImageCache.shared.image(forKey: memoryKey) {
            finishSuccess(image: memoryImage, url: url, startTime: .now, hit: true, fromMemory: true, dataSize: 0, memoryKey: memoryKey)
            return
        }

        // E10 滚动让路：滚动中暂停开始新加载（最多等待 800ms），静止后恢复
        if loadingSuspended {
            var waitedMs = 0
            while loadingSuspended && waitedMs < 800 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitedMs += 100
                if Task.isCancelled { return }
            }
        }

        phase = .empty(progress: nil)
        onPhaseChange?(.empty(progress: nil))

        let request = SJZImageKit.makeRequest(url: url)
        let startTime = Date()

        // ① 缓存直读（预判与读取一次完成；坏条目即时清理自愈，杜绝重复「预判命中→回落」）
        if let cached = SJZImageKit.usableCachedResponse(for: request) {
            LogManager.shared.debugLog("imageCache", "缓存命中预判", context: [
                "url": url.lastPathComponent
            ])
            if let image = await SJZImageKit.decode(data: cached.data, maxPixel: maxPixel) {
                finishSuccess(image: image, url: url, startTime: startTime, hit: true, dataSize: cached.data.count, memoryKey: memoryKey)
                return
            }
            // 解码失败不删缓存（防误删健康条目/不可解码内容）：网络重下成功后新响应会覆盖重建该条目
            LogManager.shared.warning("imageCache", "缓存命中但数据不可用，回落到网络加载", context: [
                "url": url.lastPathComponent,
                "action": "fallback(noRemove)"
            ])
        }

        // ② 网络加载（下载进度上报）+ 失败自动重试：指数退避 1s/3s，最多 2 次（E8）
        // 并发闸：全局最多 4 张图片同时下载（镜像站拥塞治理；发起前闸控 → URLSession 无排队、TTFB 不含排队时延）
        await SJZImageConcurrencyGate.shared.acquire()
        defer { Task { await SJZImageConcurrencyGate.shared.release() } }
        for retry in 0...2 {
            if Task.isCancelled { return }
            do {
                let delegate = SJZImageDownloadDelegate()
                delegate.onProgress = { value in
                    if let onPhaseChange {
                        Task { @MainActor in
                            onPhaseChange(.empty(progress: value))
                        }
                    }
                    Task { @MainActor in
                        guard case .empty = phase else { return }
                        phase = .empty(progress: value)
                    }
                }
                let (data, _) = try await SJZImageKit.imageSession.data(for: request, delegate: delegate)
                if let image = await SJZImageKit.decode(data: data, maxPixel: maxPixel) {
                    finishSuccess(image: image, url: url, startTime: startTime, hit: false, dataSize: data.count, memoryKey: memoryKey)
                    return
                }
                LogManager.shared.warning("imageCache", "图片解码失败", context: [
                    "url": url.lastPathComponent,
                    "dataSize": "\(data.count)"
                ])
                if retry >= 2 {
                    enterFailure(url: url, error: SJZImageError.decodeFailed)
                } else {
                    try? await Task.sleep(nanoseconds: retry == 0 ? 1_000_000_000 : 3_000_000_000)
                }
            } catch {
                // 取消类错误（滚动/切页的正常中断）：静默退出，不告警、不重试（2026-09-27 警告误报治理）
                if SJZImageKit.isCancellation(error) { return }
                LogManager.shared.warning("imageCache", "图片网络加载失败，自动重试", context: [
                    "url": url.lastPathComponent,
                    "error": error.localizedDescription,
                    "retry": "\(retry)"
                ])
                if retry >= 2 {
                    enterFailure(url: url, error: error)
                } else {
                    try? await Task.sleep(nanoseconds: retry == 0 ? 1_000_000_000 : 3_000_000_000)
                }
            }
        }
    }

    @MainActor
    private func enterFailure(url: URL, error: Error) {
        phase = .failure
        onPhaseChange?(.failure)
        LogManager.shared.error("imageCache", "图片加载最终失败", context: [
            "url": url.lastPathComponent,
            "error": error.localizedDescription
        ])
    }

    @MainActor
    private func finishSuccess(image: UIImage, url: URL, startTime: Date,
                               hit: Bool, fromMemory: Bool = false,
                               dataSize: Int, memoryKey: String) {
        let elapsed = Date().timeIntervalSince(startTime)
        // 解码结果入内存缓存（供后续滚动直出；内存命中路径不重复写入）
        if !fromMemory {
            SJZDecodedImageCache.shared.store(image, forKey: memoryKey)
        }
        // 后台计算平均色，供二次访问渐进占位（blur-up 本地化）
        let cacheImage = image
        Task.detached(priority: .utility) {
            let hex = SJZAverageColorCache.computeAverageHex(cacheImage)
            if !hex.isEmpty {
                await MainActor.run {
                    SJZAverageColorCache.store(hex, for: url)
                }
            }
        }
        // 缓存命中（内存/磁盘）直接呈现不淡入；仅网络加载淡入（滚动无闪烁）
        if hit {
            phase = .success(Image(uiImage: image))
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                phase = .success(Image(uiImage: image))
            }
        }
        onPhaseChange?(.success(Image(uiImage: image)))
        if hit {
            cacheManager.recordImageHit(url: url.absoluteString)
            if !fromMemory {
                cacheManager.recordSavedTraffic(bytes: Int64(dataSize))
            }
            if SJZImageKit.shouldLogHit(memoryKey) {
                LogManager.shared.debugLog("imageCache", fromMemory ? "内存缓存直出，零闪烁" : "图片缓存命中，秒开呈现", context: [
                    "url": url.lastPathComponent,
                    "elapsed": String(format: "%.0fms", elapsed * 1000)
                ])
            }
        } else {
            cacheManager.recordImageMiss(url: url.absoluteString)
            LogManager.shared.debugLog("imageCache", "图片网络加载成功", context: [
                "url": url.lastPathComponent,
                "size": ByteCountFormatter.string(fromByteCount: Int64(dataSize), countStyle: .file),
                "elapsed": String(format: "%.0fms", elapsed * 1000),
                "downsample": maxPixel.map { "\(Int($0))px" } ?? "original"
            ])
        }
    }
}

/// 链式设置阶段回调（供画廊计数条等外部状态使用）
extension SJZCachedImage {
    func onPhaseChange(_ action: @escaping (SJZImagePhase) -> Void) -> SJZCachedImage<Content> {
        var copy = self
        copy.onPhaseChange = action
        return copy
    }
}

/// 图片加载工具集（非隔离，供组件 / 预取器 / 协议层以外的任意线程使用）
enum SJZImageKit {

    /// 缩略图默认降采样边长（卡片类图片统一 720px，内存占用降至 ~1MB 级，
    /// 使解码图内存缓存可容纳数百张，滚动往返不再互相挤掉而闪现）
    static let defaultThumbnailPixel: CGFloat = 720

    /// 无图模式线程安全入口（转发 CacheModeManager 跨线程镜像，缓存读取同步短路）
    static var isImageFreeModeFromAnyThread: Bool {
        CacheModeManager.isImageFreeModeFromAnyThread
    }

    // MARK: 命中日志节流（同一 URL 仅首见记录，滚动复用不刷日志）

    private static let hitLogLock = NSLock()
    private static var hitLoggedURLs: Set<String> = []

    static func shouldLogHit(_ key: String) -> Bool {
        hitLogLock.lock(); defer { hitLogLock.unlock() }
        guard !hitLoggedURLs.contains(key) else { return false }
        hitLoggedURLs.insert(key)
        if hitLoggedURLs.count > 600 { hitLoggedURLs.removeFirst() }
        return true
    }

    /// 共享下载会话（进度走 delegate；缓存走 URLCache.shared；显式注册协议层保证防盗链/缓存/埋点不受全局注册时序影响）
    static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120
        // 注：真实连接由协议层 RefererHeaderURLProtocol.sharedSession 建立，本会话的 per-host 设置不生效；
        // 图片下载并发统一由 SJZImageConcurrencyGate（≤4）在发起前闸控（2026-09-27 拥塞治理）
        config.requestCachePolicy = .useProtocolCachePolicy
        config.protocolClasses = [RefererHeaderURLProtocol.self]
        return URLSession(configuration: config)
    }()

    /// 构建统一图片请求：缓存读取策略随缓存模式切换
    static func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // 15s 为「等待数据中断」超时（inactivity）：传输中数据持续到达不受影响；
        // 连接被服务器挂起时 15s 判死快速换道重试，替代旧值 30s×3 次最多干等 94s 的体验（2026-09-27 拥塞治理）
        request.timeoutInterval = 15
        request.cachePolicy = CacheModeManager.isCacheEnabledFromAnyThread
            ? .returnCacheDataElseLoad
            : .useProtocolCachePolicy
        return request
    }

    /// 读取并校验「可用」缓存响应（2xx 且数据体非空）——预判与读取合为一次，避免二次请求。
    /// 索引存在但数据体缺失/损坏的半失效条目（App 重装、进程被强杀等场景后可能出现）会即时清理自愈，
    /// 杜绝后续每次进入都重复「预判命中 → 读不出 → 回落网络」（2026-09-27 重复加载修复）。
    @MainActor
    static func usableCachedResponse(for request: URLRequest) -> CachedURLResponse? {
        guard let cached = URLCache.shared.cachedResponse(for: request),
              let http = cached.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        guard !cached.data.isEmpty else {
            URLCache.shared.removeCachedResponse(for: request)
            LogManager.shared.debugLog("imageCache", "缓存条目数据体缺失，已清理自愈", context: [
                "url": request.url?.lastPathComponent ?? ""
            ])
            return nil
        }
        return cached
    }

    /// 判定取消类错误（任务取消 / URLError.cancelled / CancellationError）——取消属正常中断而非失败：
    /// 不告警、不退避、不重试（对齐工程红线：cancelled 一律不重试不记错，2026-09-27 警告误报治理）
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        return Task.isCancelled
    }

    /// 单图解码像素护栏（E4）：超过该像素数的原图强制降采样，防内存峰值
    static let memoryGuardPixelCount = 40_000_000

    /// 解码 + 降采样（后台线程执行，避免主线程解码大图卡顿）
    static func decode(data: Data, maxPixel: CGFloat?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let effectiveMax: CGFloat?
            if let maxPixel, maxPixel > 0 {
                effectiveMax = maxPixel
            } else {
                effectiveMax = nil
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return UIImage(data: data)
            }
            // E4 护栏：未指定降采样但原图过大时，强制限制到 4096
            var limit: CGFloat? = effectiveMax
            if limit == nil {
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Double,
                   let h = props[kCGImagePropertyPixelHeight] as? Double,
                   w * h > Double(memoryGuardPixelCount) {
                    limit = 4096
                }
            }
            guard let limit else {
                return UIImage(data: data)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

/// 加载任务标识：URL / 重试次数 / 无图模式开关任一变化都会重启加载
/// （无图模式切换后视图自动回到正确状态：开启→占位，关闭→恢复真实加载）
struct SJZLoadToken: Hashable {
    let url: URL?
    let attempt: Int
    let freeMode: Bool
}

/// 图片加载错误
enum SJZImageError: Error {
    case decodeFailed
    var localizedDescription: String { "图片数据解码失败" }
}

/// 下载进度委托（data(for:delegate:) 专用，注意不能实现完成回调版委托方法）
final class SJZImageDownloadDelegate: NSObject, URLSessionDataDelegate {
    var onProgress: ((Double) -> Void)?
    private var lastPercent = -1

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let expected = dataTask.countOfBytesExpectedToReceive
        guard expected > 0 else {
            onProgress?(0)
            return
        }
        let percent = Int(Double(dataTask.countOfBytesReceived) / Double(expected) * 100)
        if percent != lastPercent {
            lastPercent = percent
            onProgress?(Double(percent) / 100.0)
        }
    }
}

// MARK: - 平均色缓存（本地化 blur-up：二次访问以近似色调占位，消除白闪）

enum SJZAverageColorCache {
    private static let lock = NSLock()
    private static var store: [String: String] = [:]
    private static let maxEntries = 300

    /// 读取已加载图片的平均色（hex），无记录返回 nil
    static func colorHex(for url: URL?) -> String? {
        guard let url else { return nil }
        lock.lock(); defer { lock.unlock() }
        return store[url.absoluteString]
    }

    static func store(_ hex: String, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        store[url.absoluteString] = hex
        if store.count > maxEntries {
            // 简单 FIFO 淘汰（Dictionary 无序遍历，仅控制上限防膨胀）
            let dropCount = store.count - maxEntries
            for key in store.keys.prefix(dropCount) {
                store.removeValue(forKey: key)
            }
        }
    }

    /// 计算平均色（后台线程）：8×8 降采样后取 RGBA 均值
    static func computeAverageHex(_ image: UIImage) -> String {
        let size = CGSize(width: 8, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let sampled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = sampled.cgImage,
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return "" }
        let bytesPerPixel = max(cg.bitsPerPixel / 8, 4)
        let bytesPerRow = cg.bytesPerRow
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return "" }
        var rSum = 0, gSum = 0, bSum = 0, count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                rSum += Int(ptr[offset])
                gSum += Int(ptr[offset + 1])
                bSum += Int(ptr[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return "" }
        return String(format: "%02X%02X%02X", rSum / count, gSum / count, bSum / count)
    }
}

// MARK: - 解码图内存缓存（滚动零闪烁的关键：命中即直出，无占位帧、无重复解码）

/// 已解码 UIImage 的内存缓存条目（cost 按像素字节计费）
private final class SJZDecodedImageBox: NSObject {
    let image: UIImage
    init(image: UIImage) { self.image = image }
}

/// 解码图内存缓存：
/// - NSCache：Apple 官方内存缓存（线程安全、内存压力自动淘汰）
/// - OSAllocatedUnfairLock（iOS 16+）：现代 Swift 同步原语守护限额状态
/// - 按「URL + 目标降采样边长」分键：同图不同规格各自缓存，杜绝分辨率串味
/// - 缓存模式联动双档限额（缓存模式 96MB/600 张，即时模式 40MB/200 张）
final class SJZDecodedImageCache: @unchecked Sendable {
    static let shared = SJZDecodedImageCache()

    private struct LimitState {
        var countLimit: Int
        var totalCostLimit: Int
    }

    private let cache = NSCache<NSString, SJZDecodedImageBox>()
    private let limits: OSAllocatedUnfairLock<LimitState>

    private init() {
        let enabled = CacheModeManager.isCacheEnabledFromAnyThread
        let initial = LimitState(
            countLimit: enabled ? 600 : 200,
            totalCostLimit: enabled ? 96 * 1024 * 1024 : 40 * 1024 * 1024
        )
        self.limits = OSAllocatedUnfairLock(initialState: initial)
        cache.countLimit = initial.countLimit
        cache.totalCostLimit = initial.totalCostLimit
    }

    /// 生成缓存键：规格 + URL（不同降采样目标各自独立缓存）
    static func key(url: URL, maxPixel: CGFloat?) -> String {
        let variant = maxPixel.map { "\(Int($0))" } ?? "orig"
        return "\(variant)::\(url.absoluteString)"
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func store(_ image: UIImage, forKey key: String) {
        let pixelBytes = max(
            Int(image.size.width * image.scale * image.size.height * image.scale * 4),
            2048
        )
        cache.setObject(SJZDecodedImageBox(image: image), forKey: key as NSString, cost: pixelBytes)
    }

    /// 缓存模式切换时刷新限额（@MainActor 调用）
    func refreshLimits(cacheEnabled: Bool) {
        let newLimits = LimitState(
            countLimit: cacheEnabled ? 600 : 200,
            totalCostLimit: cacheEnabled ? 96 * 1024 * 1024 : 40 * 1024 * 1024
        )
        limits.withLock { $0 = newLimits }
        cache.countLimit = newLimits.countLimit
        cache.totalCostLimit = newLimits.totalCostLimit
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// 当前总成本上限（字节）
    var totalCostLimitBytes: Int {
        limits.withLock { $0.totalCostLimit }
    }
}

// MARK: - 图片下载并发闸（全局 ≤4）

/// 全局图片下载并发闸：抑制学校镜像站在大图文批量拉取时的限流/挂起；
/// 因在**发起前**闸控，URLSession 不产生排队，TTFB 统计不含排队时延（2026-09-27 拥塞治理 + 审计加固）。
actor SJZImageConcurrencyGate {
    static let shared = SJZImageConcurrencyGate()
    private let limit = 4
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

// MARK: - 智能预取器（E1/E5/E6 共用）

@MainActor
enum SJZImagePrefetcher {

    /// 预取一批图片 URL：命中的跳过，未命中的并发≤maxConcurrent 下载
    /// 判存升级为「可用性判存」（2xx 且数据体非空）：半失效条目主动清理并纳入预取，顺带自愈（2026-09-27）
    static func prefetch(urls: [URL], maxConcurrent: Int = 4) async {
        let valid = urls.filter { url in
            let request = SJZImageKit.makeRequest(url: url)
            guard let cached = URLCache.shared.cachedResponse(for: request),
                  let http = cached.response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return true }   // 无缓存 → 需预取
            if cached.data.isEmpty {
                URLCache.shared.removeCachedResponse(for: request)           // 半失效条目：清理自愈并预取
                LogManager.shared.debugLog("cache", "预取清理失效缓存条目", context: [
                    "url": url.lastPathComponent
                ])
                return true
            }
            return false                                                     // 可用缓存 → 跳过
        }
        guard !valid.isEmpty else {
            LogManager.shared.debugLog("cache", "预取跳过：全部已缓存", context: ["count": "\(urls.count)"])
            return
        }
        let startTime = Date()
        var fetched = 0
        LogManager.shared.info("cache", "图片预取任务启动", context: [
            "total": "\(valid.count)"
        ])
        let batches = stride(from: 0, to: valid.count, by: maxConcurrent).map {
            Array(valid[$0..<min($0 + maxConcurrent, valid.count)])
        }
        for batch in batches {
            let batchFetched = await withTaskGroup(of: Bool.self) { group in
                for url in batch {
                    group.addTask(priority: .utility) {
                        await SJZImageConcurrencyGate.shared.acquire()
                        defer { Task { await SJZImageConcurrencyGate.shared.release() } }
                        let delegate = SJZImageDownloadDelegate()
                        let request = SJZImageKit.makeRequest(url: url)
                        do {
                            _ = try await SJZImageKit.imageSession.data(for: request, delegate: delegate)
                            return true
                        } catch {
                            // 预取失败静默忽略，正式加载时仍会重试
                            return false
                        }
                    }
                }
                var okCount = 0
                for await result in group {
                    if result { okCount += 1 }
                }
                return okCount
            }
            fetched += batchFetched
        }
        let elapsed = Date().timeIntervalSince(startTime)
        LogManager.shared.info("cache", "图片预取完成", context: [
            "fetched": "\(fetched)",
            "skipped": "\(urls.count - valid.count)",
            "elapsed": String(format: "%.0fms", elapsed * 1000)
        ])
    }
}

// MARK: - 视觉设计令牌（新组件统一配色：现代渐变体系 + 一致层级规格）

/// 新组件视觉令牌：渐变强调色、统一尺寸与描边规格（明暗模式随 sjz* 动态色自动适配）
enum SJZDesignTokens {
    /// 加载/强调渐变：校徽蓝 → 明快青（现代科技感主色）
    static let accentGradient = LinearGradient(
        colors: [Color.sjzAccent, Color.sjzTeal],
        startPoint: .leading, endPoint: .trailing
    )
    /// 完成态渐变：沉稳绿 → 青绿（成功语义，柔和不过饱和）
    static let successGradient = LinearGradient(
        colors: [Color.sjzGreen, Color(lightHex: "43A047", darkHex: "66BB6A")],
        startPoint: .leading, endPoint: .trailing
    )
    /// 警示渐变：暖橙 → 珊瑚（弱网/提示语义，醒目不失柔和）
    static let warningGradient = LinearGradient(
        colors: [Color.sjzOrange, Color.sjzCoral],
        startPoint: .leading, endPoint: .trailing
    )
    /// 胶囊高光描边：顶部亮、底部消散，模拟玻璃反光层级
    static let capsuleStroke = LinearGradient(
        colors: [.white.opacity(0.4), .white.opacity(0.06), .clear],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - 页面级彩虹进度条（真实进度 + 色相旋转渐变，详情页顶部悬浮）

/// 顶部悬浮加载进度条（图片繁多文章的真实进度指示）：
/// - 真实百分比驱动（WebView estimatedProgress / 画廊 loaded/total）；
/// - 八彩光谱渐变 + hueRotation 3.2s 线性循环，形成「五颜六色缓慢随机变换」的时尚动效；
/// - 完成（≥99.5%）自动切换成功渐变 + bounce 打勾；
/// - 玻璃胶囊 + 高光描边 + 柔和阴影（与 SJZ 视觉令牌体系一致）。
struct SJZPageLoadProgressBar: View {
    /// 真实进度 0-1（不定型模式忽略）
    var percent: Double = 0
    /// 进度文案（nil 则默认百分比 / 完成态「全部就绪」）
    var label: String? = nil
    var accent: Color = Color.sjzAccent
    /// 不定型扫描模式（详情加载中无总量时：彩虹棒往返滑动 + 色相循环）
    var indeterminate: Bool = false
    @State private var hue: Double = 0
    /// 扫描棒横向位移（不定型模式往返动画）
    @State private var scanX: CGFloat = 0

    private var clamped: Double { min(max(percent, 0), 1) }
    private var done: Bool { !indeterminate && clamped >= 0.995 }

    /// 八彩光谱（色相均匀分布，hueRotation 旋转即「五颜六色随机变换」）
    private static let spectrum: [Color] = (0..<8).map {
        Color(hue: Double($0) / 8.0, saturation: 0.8, brightness: 0.92)
    }

    private var rainbowFill: LinearGradient {
        LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 120, height: 5)
                if indeterminate {
                    // 不定型：30pt 彩虹棒在轨道内往返滑动（easeInOut 1.15s）
                    Capsule()
                        .fill(rainbowFill)
                        .hueRotation(.degrees(hue))
                        .frame(width: 30, height: 5)
                        .offset(x: scanX)
                        .shadow(color: accent.opacity(0.35), radius: 3, y: 1)
                } else {
                    Capsule()
                        .fill(done
                              ? SJZDesignTokens.successGradient
                              : rainbowFill)
                        .hueRotation(.degrees(done ? 0 : hue))
                        .frame(width: max(120 * clamped, done ? 120 : 0), height: 5)
                        .shadow(
                            color: done ? Color.sjzGreen.opacity(0.35) : accent.opacity(0.35),
                            radius: 3, y: 1
                        )
                }
            }
            Image(systemName: done ? "checkmark.circle.fill" : (indeterminate ? "arrow.triangle.2.circlepath" : "photo.stack.fill"))
                .displaySymbolFont(11, weight: .semibold)
                .foregroundStyle(done ? Color.sjzGreen : accent)
                .symbolEffect(.bounce, value: done)
                .symbolEffect(.variableColor.iterative, isActive: !done)
            Text(indeterminate ? (label ?? "加载中…") : (label ?? (done ? "全部就绪" : "\(Int(clamped * 100))%")))
                .displayFont(11, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(done ? Color.sjzGreen : .primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .glassEffect()
        .shadow(color: accent.opacity(0.18), radius: 10, y: 3)
        .animation(.smooth(duration: 0.35), value: clamped)
        .onAppear {
            LogManager.shared.debugLog("imageCache", "页面加载进度条展示", context: [
                "mode": indeterminate ? "indeterminate" : "determinate",
                "percent": String(format: "%.1f%%", clamped * 100)
            ])
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                hue = 360
            }
            if indeterminate {
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    scanX = 90
                }
            }
        }
        .onChange(of: done) { _, isDone in
            if isDone {
                LogManager.shared.debugLog("imageCache", "页面加载进度条完成", context: [:])
            }
        }
    }
}

// MARK: - 画廊计数条（HIG：确定型进度、瞬态展示；渐变轨道 + 平滑动画 + Liquid Glass）

struct SJZGalleryProgressBar: View {
    let loaded: Int
    let total: Int

    private var isDone: Bool { loaded >= total }
    private var ratio: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(loaded) / Double(total), 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 74, height: 5)
                Capsule()
                    .fill(isDone ? SJZDesignTokens.successGradient : SJZDesignTokens.accentGradient)
                    .frame(width: max(74 * ratio, isDone ? 74 : 0), height: 5)
                    .shadow(
                        color: isDone ? Color.sjzGreen.opacity(0.35) : Color.sjzAccent.opacity(0.35),
                        radius: 3, y: 1
                    )
            }
            Image(systemName: isDone ? "checkmark.circle.fill" : "photo.fill")
                .displaySymbolFont(11, weight: .semibold)
                .foregroundStyle(isDone ? Color.sjzGreen : Color.sjzAccent)
                .symbolEffect(.bounce, value: isDone)
            Text(isDone ? "全部就绪" : "\(loaded)/\(total)")
                .displayFont(12, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(isDone ? Color.sjzGreen : Color.primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .glassEffect()
        .animation(.smooth(duration: 0.4), value: loaded)
    }
}

// MARK: - 弱网提示胶囊（E7）

struct SJZSlowNetworkBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .displaySymbolFont(12, weight: .semibold)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
            Text(message)
                .displayFont(13, weight: .medium)
                .foregroundStyle(Color.sjzOrange)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(SJZDesignTokens.warningGradient.opacity(0.12), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .glassEffect()
    }
}

// MARK: - 缓存徽标（E3）

struct SJZCachedBadge: View {
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox.fill")
                .displaySymbolFont(9, weight: .semibold)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
            Text("已缓存 · 秒开")
                .displayFont(11, weight: .semibold)
        }
        .foregroundStyle(AnyShapeStyle(SJZDesignTokens.successGradient))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SJZDesignTokens.successGradient.opacity(0.14), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .glassEffect()
        .onAppear { appeared = true }
    }
}

// MARK: - 文章加载态组件（大内容加载的优雅等待体验：流彩图标 + 相位文案 + 渐变进度 + 已用时）

struct SJZArticleLoadingView: View {
    let phases: [String]
    var accent: Color = Color.sjzAccent
    @State private var phaseIndex = 0
    @State private var startTime = Date()
    @State private var active = false

    private var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, Color.sjzTeal], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(spacing: 14) {
            // 流彩图标（iOS 17 variableColor 特效，层级渲染+微光）
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(34, weight: .medium)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
                .symbolEffect(.variableColor.iterative, isActive: active)
                .shadow(color: accent.opacity(0.35), radius: 6, y: 2)

            // 相位文案（平滑轮换：获取 → 解析 → 渲染）
            ZStack {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    Text(phase)
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.secondary)
                        .opacity(index == phaseIndex ? 1 : 0)
                        .offset(y: index == phaseIndex ? 0 : (index > phaseIndex ? 14 : -14))
                }
            }
            .frame(height: 22)
            .clipped()

            // 不确定型渐变进度条（恒动，直观传达"仍在进行"）
            ProgressView()
                .progressViewStyle(.linear)
                .tint(accentGradient)
                .frame(width: 170)

            // 已用时计数（确定型信息，等待不焦虑）
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text("已用时 \(String(format: "%.1fs", context.date.timeIntervalSince(startTime)))")
                    .displayFont(10)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
        )
        .glassEffect()
        .onAppear {
            active = true
            startTime = Date()
            guard phases.count > 1 else { return }
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    withAnimation(.smooth(duration: 0.45)) {
                        phaseIndex = (phaseIndex + 1) % phases.count
                    }
                }
            }
        }
    }
}

// MARK: - 单次错峰揭示（首页模块渐进入场，Apple News 式）

/// 会话级揭示登记（跨视图实例去重；非泛型枚举规避 static 存储限制）
enum SJZRevealRegistry {
    private static let lock = NSLock()
    private static var revealedKeys: Set<String> = []

    /// 首次消费返回 true（触发入场动画）；重复出现返回 false（直接可见）
    static func consume(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !revealedKeys.contains(key) else { return false }
        revealedKeys.insert(key)
        if revealedKeys.count > 200 { revealedKeys.removeFirst() }
        return true
    }
}

/// 内容首次出现时以弹簧动画错峰入场；同一会话内再次滚动到该区域不再重播。
/// - Note: `logReveal` 默认为 true；**「展示日志本身」的页面（应用日志）必须传 false**——
///   否则揭示日志会变成列表里的新行、新行再触发揭示日志，形成自反馈风暴拖死主线程（2026-09-28 现场实证）。
struct SJZRevealOnce: ViewModifier {
    let key: String
    let delay: Double
    /// 是否记录揭示日志（默认 true；日志类页面必须关闭）
    var logReveal: Bool = true
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 26)
            .onAppear {
                guard !shown else { return }
                if SJZRevealRegistry.consume(key) {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay)) {
                        shown = true
                    }
                    if logReveal {
                        LogManager.shared.debugLog("ui", "模块首次错峰入场", context: ["key": key])
                    }
                } else {
                    shown = true
                }
            }
    }
}

private func formatZSWDate(_ raw: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = formatter.date(from: raw) {
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: date)
    }
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let date = formatter.date(from: raw) {
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: date)
    }
    // 截取前10位
    if raw.count >= 10 {
        return String(raw.prefix(10)).replacingOccurrences(of: "-", with: ".")
    }
    return raw
}

// MARK: - 专业介绍列表

struct SpecialtyListView: View {
    @ObservedObject private var data = DataService.shared
    @State private var isLoading = false

    var body: some View {
        Group {
            if data.specialtyIsLoading || isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在加载专业介绍...").displayFont(12).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let specialtyData = data.specialtyData, !specialtyData.colleges.isEmpty {
                List {
                    ForEach(specialtyData.colleges) { college in
                        NavigationLink {
                            SpecialtyCollegeDetailView(college: college)
                        } label: {
                            HStack(spacing: 14) {
                                // 学院图标
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(hex: "1A73E8").opacity(0.08))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: specialtyIcon(for: college.titleCn))
                                        .displaySymbolFont(20)
                                        .foregroundStyle(Color(hex: "1A73E8"))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(college.titleCn)
                                        .displayFont(16, weight: .semibold)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Image(systemName: "book.closed.fill")
                                            .displaySymbolFont(10)
                                            .foregroundStyle(.secondary)
                                        Text("\(college.majors.count) 个专业")
                                            .displayFont(13)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .displaySymbolFont(12, weight: .semibold)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .navigationTitle("专业介绍")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "text.book.closed")
                        .displaySymbolFont(48)
                        .foregroundStyle(.tertiary)
                    Text("暂无专业介绍数据")
                        .displayFont(16)
                        .foregroundStyle(.secondary)
                    Button("重新加载") {
                        Task {
                            isLoading = true
                            await data.loadSpecialtyData()
                            isLoading = false
                        }
                    }
                    .displayFont(14)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color(hex: "1A73E8").opacity(0.1))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("专业介绍")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            if data.specialtyData == nil || data.specialtyData?.colleges.isEmpty == true {
                isLoading = true
                await data.loadSpecialtyData()
                isLoading = false
            }
        }
    }

    private func specialtyIcon(for name: String) -> String {
        if name.contains("信创") || name.contains("大数据") || name.contains("计算机") { return "cpu.fill" }
        if name.contains("智能") || name.contains("制造") || name.contains("车辆") { return "gearshape.2.fill" }
        if name.contains("商") || name.contains("经济") || name.contains("管理") { return "chart.bar.fill" }
        if name.contains("材料") || name.contains("环境") { return "leaf.fill" }
        if name.contains("文法") { return "text.book.closed.fill" }
        if name.contains("艺术") || name.contains("音乐") { return "music.note" }
        return "building.2.fill"
    }
}

// MARK: - 学院专业详情

struct SpecialtyCollegeDetailView: View {
    let college: SpecialtyCollege
    @State private var selectedMajor: SpecialtyMajor?
    @State private var fullDetail: DataService.ArticleFullDetail?
    @State private var isLoadingDetail = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 学院头部
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(hex: "1A73E8").opacity(0.08))
                            .frame(width: 72, height: 72)
                        Image(systemName: specialtyIcon)
                            .displaySymbolFont(32)
                            .foregroundStyle(Color(hex: "1A73E8"))
                    }
                    Text(college.titleCn)
                        .displayFont(22, weight: .bold)
                    Text("共 \(college.majors.count) 个本科专业")
                        .displayFont(14)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

                Divider().padding(.horizontal, 16)

                // 专业列表
                VStack(spacing: 0) {
                    ForEach(Array(college.majors.enumerated()), id: \.element.id) { index, major in
                        Button {
                            selectedMajor = major
                            fullDetail = nil
                            loadError = nil
                        } label: {
                            HStack(spacing: 14) {
                                // 序号
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: "1A73E8").opacity(0.1))
                                        .frame(width: 36, height: 36)
                                    Text("\(index + 1)")
                                        .displayFont(14, weight: .semibold)
                                        .foregroundStyle(Color(hex: "1A73E8"))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(major.title)
                                        .displayFont(15, weight: .medium)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(major.description)
                                        .displayFont(13)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .displaySymbolFont(12, weight: .semibold)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)

                        if index < college.majors.count - 1 {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle(college.titleCn)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedMajor) { major in
            NavigationStack {
                SpecialtyMajorDetailView(major: major)
            }
            .sjzPresentationChrome()
        }
    }

    private var specialtyIcon: String {
        if college.titleCn.contains("信创") || college.titleCn.contains("大数据") || college.titleCn.contains("计算机") { return "cpu.fill" }
        if college.titleCn.contains("智能") || college.titleCn.contains("制造") || college.titleCn.contains("车辆") { return "gearshape.2.fill" }
        if college.titleCn.contains("商") || college.titleCn.contains("经济") || college.titleCn.contains("管理") { return "chart.bar.fill" }
        if college.titleCn.contains("材料") || college.titleCn.contains("环境") { return "leaf.fill" }
        if college.titleCn.contains("文法") { return "text.book.closed.fill" }
        if college.titleCn.contains("艺术") || college.titleCn.contains("音乐") { return "music.note" }
        return "building.2.fill"
    }
}

// MARK: - 专业详情弹窗

struct SpecialtyMajorDetailView: View {
    let major: SpecialtyMajor
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = DataService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 头部
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(hex: "1A73E8").opacity(0.08))
                            .frame(width: 72, height: 72)
                        Image(systemName: "book.fill")
                            .displaySymbolFont(32)
                            .foregroundStyle(Color(hex: "1A73E8"))
                    }
                    Text(major.title)
                        .displayFont(20, weight: .bold)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

                Divider()

                // 专业描述
                VStack(alignment: .leading, spacing: 10) {
                    Label("专业介绍", systemImage: "text.alignleft")
                        .displayLabelFont(16, weight: .semibold)
                        .foregroundStyle(Color(hex: "1A73E8"))

                    Text(major.description)
                        .displayFont(15)
                        .foregroundStyle(.secondary)
                        .lineSpacing(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 40)
        }
        .navigationTitle("专业详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") {
                    dismiss()
                }
                .displayFont(17)
            }
        }
    }
}

#if DEBUG
#Preview {
    MainTabView()
}
#endif

// MARK: - 应用图标切换（Alternate App Icons）

/// 备选图标条目：key 为 Asset 集合名（nil = 主图标「默认」）
struct AppIconItem: Identifiable, Equatable {
    let key: String?              // nil = 主图标
    let displayName: String       // 展示名
    let subtitle: String          // 风格副标题
    let previewImageName: String  // 设置页网格预览图（imageset 名）

    var id: String { key ?? "primary" }
}

/// 应用图标切换错误
enum AppIconSwitchError: LocalizedError {
    case unsupported
    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前设备或系统版本不支持切换应用图标"
        }
    }
}

/// 应用图标管理器：系统 alternate icon 的读取 / 切换 / 启动校准，选择持久化。
/// setAlternateIconName 一律在主线程发起（系统确认弹窗要求）；其 completion 不在主队列，
/// 回调内统一切回主线程再刷新状态与派发外部回调，失败时不改动本地记录（选中态自然回滚）。
@MainActor
final class AppIconManager: ObservableObject {

    static let shared = AppIconManager()

    /// 本地持久化键（"" 表示主图标）
    private static let selectionKey = "appIconSelection"

    /// 可选图标集合（Asset 名必须与 build setting / Contents.json 完全一致）
    static let availableIcons: [AppIconItem] = [
        AppIconItem(key: nil, displayName: "默认", subtitle: "经典深蓝", previewImageName: "IconPreviewPrimary"),
        AppIconItem(key: "AppIconAlt1", displayName: "星夜", subtitle: "深空紫调", previewImageName: "IconPreviewAlt1"),
        AppIconItem(key: "AppIconAlt2", displayName: "晨曦", subtitle: "暖橙金辉", previewImageName: "IconPreviewAlt2"),
        AppIconItem(key: "AppIconAlt3", displayName: "极简", subtitle: "冰感浅底", previewImageName: "IconPreviewAlt3"),
        AppIconItem(key: "AppIconAlt4", displayName: "金典", subtitle: "黑金尊享", previewImageName: "IconPreviewAlt4"),
    ]

    // MARK: 发布状态

    /// 切换进行中（防连点 / 显示进度）
    @Published private(set) var isSwitching = false
    /// 最近一次切换失败信息（内联提示；成功或重新发起后清空）
    @Published private(set) var lastErrorMessage: String?
    /// 系统实际生效图标的响应式快照（nil = 主图标）；切换成功后或启动校准时更新，
    /// 保证选择页始终展示系统真实状态而非本地缓存值
    @Published private(set) var activeIconName: String?

    // MARK: 系统能力

    /// 设备是否支持切换应用图标
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }

    /// 本地持久化选择（"" = 默认；失败不改写，保证重启后与系统一致）
    private var persistedSelection: String {
        get { UserDefaults.standard.string(forKey: Self.selectionKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.selectionKey) }
    }

    /// 当前展示名（设置页入口副标题）
    var currentDisplayName: String {
        guard let name = activeIconName else { return "默认" }
        return Self.availableIcons.first(where: { $0.key == name })?.displayName ?? "自定义"
    }

    /// 选择页出现时刷新：直接读取系统当前生效值（保证首屏展示真实状态而非本地缓存）
    func refreshFromSystem() {
        activeIconName = UIApplication.shared.alternateIconName
    }

    private init() {}

    // MARK: - 启动校准

    /// App 启动时调用：以系统实际值为准；若本地记录不一致则写回
    /// （覆盖卸载重装、系统重置等场景，避免 UI 与实际图标不符）
    func calibrateOnLaunch() {
        activeIconName = UIApplication.shared.alternateIconName
        let system = activeIconName ?? ""
        let stored = persistedSelection
        if system != stored {
            persistedSelection = system
            LogManager.shared.info("appicon", "启动校准：以系统实际值为准修正本地记录", context: [
                "previous": stored.isEmpty ? "primary" : stored,
                "actual": system.isEmpty ? "primary" : system
            ])
        } else {
            LogManager.shared.debugLog("appicon", "启动校准：系统与本地一致", context: [
                "icon": system.isEmpty ? "primary" : system
            ])
        }
    }

    // MARK: - 切换

    /// 切换图标：name == nil 恢复主图标；与当前相同直接返回；失败回调错误且不改本地记录
    func setIcon(_ name: String?, completion: ((Error?) -> Void)? = nil) {
        guard supportsAlternateIcons else {
            let error = AppIconSwitchError.unsupported
            lastErrorMessage = error.localizedDescription
            LogManager.shared.warning("appicon", "设备不支持切换应用图标", context: [
                "target": name ?? "primary"
            ])
            completion?(error)
            return
        }
        guard activeIconName != name else {
            LogManager.shared.debugLog("appicon", "目标图标与当前系统图标相同，跳过切换", context: [
                "target": name ?? "primary"
            ])
            completion?(nil)
            return
        }
        let target = name ?? ""
        isSwitching = true
        lastErrorMessage = nil
        LogManager.shared.info("appicon", "发起应用图标切换", context: [
            "target": target.isEmpty ? "primary" : target
        ])
        UIApplication.shared.setAlternateIconName(name) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isSwitching = false
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                    LogManager.shared.error("appicon", "应用图标切换失败", context: [
                        "target": target.isEmpty ? "primary" : target,
                        "error": error.localizedDescription
                    ])
                    completion?(error)
                } else {
                    self.persistedSelection = target
                    self.activeIconName = target.isEmpty ? nil : target
                    LogManager.shared.info("appicon", "应用图标切换成功", context: [
                        "target": target.isEmpty ? "primary" : target
                    ])
                    completion?(nil)
                }
            }
        }
    }
}

// MARK: - 应用图标选择页

/// 应用图标选择页：3 列网格 + 选中态 + 切换失败回滚提示 + 无障碍 + 不支持说明
struct AppIconSettingsView: View {
    @ObservedObject private var manager = AppIconManager.shared

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader

                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(AppIconManager.availableIcons) { item in
                        iconCell(item)
                    }
                }
                .padding(.horizontal, 20)

                if let message = manager.lastErrorMessage, !message.isEmpty {
                    errorBanner(message)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                footer
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入页面时刷新系统实际值，保证首屏展示真实生效图标（而非本地缓存）
            manager.refreshFromSystem()
            LogManager.shared.debugLog("appicon", "打开应用图标选择页", context: [
                "supportsAlternateIcons": "\(manager.supportsAlternateIcons)",
                "current": manager.activeIconName ?? "primary"
            ])
        }
    }

    // MARK: 状态头（含切换进行指示）

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge")
                .displaySymbolFont(15, weight: .semibold)
                .foregroundStyle(Color.sjzAccent)
            Text("当前：\(manager.currentDisplayName)")
                .displayFont(14, weight: .semibold)
            Spacer()
            if manager.isSwitching {
                ProgressView()
                    .controlSize(.small)
                Text("切换中…")
                    .displayFont(12)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.sjzAccent.opacity(0.08)))
        .overlay(Capsule().stroke(Color.sjzAccent.opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, 20)
    }

    // MARK: 单格预览

    private func iconCell(_ item: AppIconItem) -> some View {
        let isSelected = (item.key == manager.activeIconName)
        return Button {
            guard !manager.isSwitching else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                manager.setIcon(item.key)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(item.previewImageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    isSelected ? Color.sjzAccent : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2.5 : 1
                                )
                        )
                        .shadow(
                            color: isSelected ? Color.sjzAccent.opacity(0.35) : Color.black.opacity(0.08),
                            radius: isSelected ? 7 : 3,
                            y: 2
                        )
                        .scaleEffect(isSelected ? 1.06 : 1.0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .displaySymbolFont(18, weight: .bold)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.sjzAccent)
                            .background(Circle().fill(Color(.systemBackground)).padding(2))
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(item.displayName)
                    .displayFont(13, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                Text(item.subtitle)
                    .displayFont(10)
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(manager.isSwitching || !manager.supportsAlternateIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("图标：\(item.displayName)\(isSelected ? "，当前使用中" : "")")
        .accessibilityHint("轻点切换为此图标")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 错误提示（切换失败内联展示；条目选中态由系统实际值驱动，自然回滚）

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .displayFont(13)
                .foregroundStyle(.orange)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !manager.supportsAlternateIcons {
                Text("当前设备不支持切换应用图标。")
                    .displayFont(13)
                    .foregroundStyle(.orange)
            }
            Text("切换时系统会弹出确认；新图标将同步显示在主屏幕、聚焦搜索与系统设置中。")
                .displayFont(12)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
