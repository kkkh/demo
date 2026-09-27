//
//  PrincipalMailboxView.swift
//  DesignCode
//
//  校长信箱模块（首页资讯区新增）：
//  · 独立数据中枢（/mapi/school/msg），懒加载 + 分页续拉，不阻塞其他模块同步；
//  · 使用说明卡 + 联系方式卡（电话一键拨打 / 邮箱复制与发送）；
//  · 来信列表（服务端时间倒序）支持关键词即时搜索（来信 + 回复标题，命中高亮）；
//  · 搜索历史（最多 10 条持久化）、骨架屏、空态、失败重试、刷新；
//  · 完整 mailbox 模块日志埋点。
//

import SwiftUI

/// 校长信箱留言条目（NetworkService 嵌套类型简写）
typealias MailboxMessage = NetworkService.MailboxMessage
/// 校长信箱留言详情（NetworkService 嵌套类型简写）
typealias MailboxMessageDetail = NetworkService.MailboxMessageDetail

// MARK: - 校长信箱数据中枢

@MainActor
final class PrincipalMailboxStore: ObservableObject {
    static let shared = PrincipalMailboxStore()

    /// 单页请求条数（服务端支持 page/size 分页）
    private static let pageSize = 50
    /// 分页续拉页码上限（防异常数据导致无限翻页）
    private static let maxPages = 10

    @Published private(set) var messages: [MailboxMessage] = []
    @Published private(set) var total: Int = 0
    @Published private(set) var noticeText: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// 是否成功加载过（首页徽章/最近一封预览的判定依据）
    @Published private(set) var hasLoaded = false
    /// 本次检测到的新增信件 id（与本地基线对比；驱动 NEW 徽章与新增提示）
    @Published private(set) var newMessageIds: Set<Int> = []
    /// 新增信件数量
    @Published private(set) var newCount: Int = 0
    /// 模拟信件分仓（Debug 面板注入；与真实数据隔离，真实刷新不会将其覆盖）
    @Published private(set) var mockMessages: [MailboxMessage] = []

    /// 展示用全量信件（模拟置顶 + 真实数据）
    var allMessages: [MailboxMessage] {
        mockMessages + messages
    }

    private var loadTask: Task<Void, Never>?

    private init() {}

    // MARK: 联系方式（从服务端说明文本动态解析，失败时回落官网公开值）

    var phoneNumber: String {
        firstMatch(pattern: #"联系电话[：:]\s*([0-9\-]+)"#, in: noticeText) ?? "0351-3624911"
    }

    var emailAddress: String {
        firstMatch(pattern: #"邮箱[：:]\s*([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"#, in: noticeText)
            ?? "sxjzlgxydwxcb@163.com"
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: 拉取

    /// 手动刷新状态机（工具栏/下拉/重试入口的直观反馈来源）
    enum RefreshStatus: Equatable {
        case idle
        case refreshing
        case success(newCount: Int, elapsedMs: Int, at: Date)
        case failed(message: String)
    }

    @Published private(set) var refreshStatus: RefreshStatus = .idle
    /// 最近一次手动刷新完成时间（可视证据：刷新确实生效）
    @Published private(set) var lastRefreshDate: Date?
    /// 手动刷新防重入
    private var refreshInFlight = false

    /// 懒加载：成功过则跳过；loadTask 进行中则跳过（仅静默通道）
    func loadIfNeeded(force: Bool = false) {
        if hasLoaded && !force { return }
        guard loadTask == nil else {
            LogManager.shared.debugLog("mailbox", "拉取跳过", context: ["reason": "已有进行中任务"])
            return
        }
        loadTask = Task { await silentLoad(force: force) }
    }

    /// 下拉刷新专用入口：刷新本体放入独立 Task，本函数仅作为等待句柄。
    /// SwiftUI .refreshable 会随下拉手势收回/视图重建取消其任务——若刷新本体直接跑在该任务里，
    /// URLSession 会响应取消抛 URLError.cancelled，造成「刷新失败 cancelled」误报。
    /// 独立 Task 不绑定调用方生命周期：即使等待句柄被系统取消，真实刷新继续完成并正常发布状态。
    func refreshDetached(source: String) async {
        let task = Task { await refresh(source: source) }
        _ = await task.value
    }

    /// 手动刷新（工具栏/下拉/重试入口）：必定执行一次真实拉取，并发布完整状态供 UI 反馈
    func refresh(source: String) async {
        guard !refreshInFlight else {
            LogManager.shared.debugLog("mailbox", "手动刷新跳过", context: ["reason": "刷新进行中", "source": source])
            return
        }
        refreshInFlight = true
        refreshStatus = .refreshing
        let startedAt = Date()
        LogManager.shared.info("mailbox", "手动刷新开始", context: ["source": source])

        // 断开可能进行的静默加载任务，避免并发双写（旧任务取消后静默退出）
        if let task = loadTask {
            task.cancel()
            loadTask = nil
        }

        isLoading = true
        do {
            try await performFetch()
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastRefreshDate = Date()
            refreshStatus = .success(newCount: newCount, elapsedMs: elapsed, at: Date())
            LogManager.shared.info("mailbox", "手动刷新成功", context: [
                "source": source,
                "elapsedMs": "\(elapsed)",
                "newCount": "\(newCount)",
                "total": "\(total)"
            ])
        } catch {
            // 取消类错误并非刷新失败（主动断开/系统回收），不作为失败横幅展示
            if (error as? URLError)?.code == .cancelled {
                refreshStatus = .idle
                LogManager.shared.debugLog("mailbox", "手动刷新被取消（非失败，不展示失败横幅）", context: [
                    "source": source
                ])
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                refreshStatus = .failed(message: message)
                LogManager.shared.error("mailbox", "手动刷新失败", context: [
                    "source": source,
                    "error": message
                ])
            }
        }
        isLoading = false
        refreshInFlight = false
    }

    /// 隐藏刷新结果横幅（成功类横幅由 UI 延时自动调用）
    func dismissRefreshBanner() {
        if refreshStatus != .refreshing {
            refreshStatus = .idle
        }
    }

    /// 静默加载通道（懒加载/预加载）：失败仅落 lastError 供首屏错误卡展示
    private func silentLoad(force: Bool) async {
        isLoading = true
        lastError = nil
        LogManager.shared.info("mailbox", "校长信箱数据拉取开始", context: [
            "maxPages": "\(Self.maxPages)",
            "pageSize": "\(Self.pageSize)"
        ])

        do {
            try await performFetch()
            LogManager.shared.info("mailbox", "校长信箱数据拉取成功", context: [
                "total": "\(total)",
                "noticeChars": "\(noticeText.count)"
            ])
        } catch {
            guard !Task.isCancelled else {
                LogManager.shared.debugLog("mailbox", "静默拉取已取消（由手动刷新接管）", context: [:])
                return
            }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LogManager.shared.error("mailbox", "校长信箱数据拉取失败", context: [
                "error": lastError ?? "(无)",
                "hasLoaded": "\(hasLoaded)"
            ])
        }

        isLoading = false
        loadTask = nil
    }

    /// 核心拉取（分页续拉 + 赋值 + 新增检测 + 防御诊断）；失败抛错由调用通道各自处理
    private func performFetch() async throws {
        var collected: [MailboxMessage] = []
        var expectedTotal = 0
        var fetchedPages = 0
        var page = 1
        while page <= Self.maxPages {
            let data = try await NetworkService.shared.fetchPrincipalMailbox(page: page, size: Self.pageSize)
            fetchedPages += 1
            if page == 1 {
                expectedTotal = data.total
                noticeText = data.noticeText
            }
            collected.append(contentsOf: data.messages)
            // 本页不足一页或已拉满服务端总数即停止续拉
            if data.messages.count < Self.pageSize || collected.count >= expectedTotal { break }
            page += 1
        }

        messages = collected
        total = collected.count + mockMessages.count
        hasLoaded = true

        // 新增信件检测：对比本地上次基线总数（首次建立基线不提示；仅增量时高亮 NEW 徽章）
        let baselineKey = "mailboxLastKnownTotal"
        let previousTotal = UserDefaults.standard.integer(forKey: baselineKey)
        UserDefaults.standard.set(collected.count, forKey: baselineKey)
        if previousTotal > 0 && collected.count > previousTotal {
            let delta = collected.count - previousTotal
            newCount = delta
            newMessageIds = Set(collected.prefix(delta).map(\.id))
            LogManager.shared.info("mailbox", "检测到新增信件", context: [
                "previousTotal": "\(previousTotal)",
                "newTotal": "\(total)",
                "delta": "\(delta)"
            ])
        } else {
            newCount = 0
            newMessageIds = []
        }

        // 防御诊断：响应结构变化导致"成功但 0 条"时，日志必须留下可排查线索（而非静默空态）
        if collected.isEmpty && expectedTotal == 0 {
            LogManager.shared.warning("mailbox", "信箱响应无留言数据（疑似服务端结构变化）", context: [
                "fetchedPages": "\(fetchedPages)",
                "noticeChars": "\(noticeText.count)"
            ])
        }
    }

    // MARK: 调试模拟（开发验收：模拟官网新增一封信件，驱动 NEW 徽章与通知全链路）

    /// 模拟信件序号（内存计数，重启重置）
    private var mockSequence = 0

    /// 调用点：Debug 面板「模拟信箱新信」。
    /// 行为：列表顶部注入一封模拟信件 + NEW 徽章/+N 横幅 + 触发系统通知（点击直达信箱页）。
    /// 不写入持久化基线，下次真实刷新即自然还原。
    func simulateNewMail() {
        mockSequence += 1
        let mockId = 900000 + mockSequence
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let mock = MailboxMessage(
            id: mockId,
            title: "模拟来信（测试）：请校方关注学生宿舍热水供应问题",
            showTitle: "关于宿舍热水供应问题的模拟回复（通知链路测试）",
            messageTime: "\(today)T12:00:00"
        )
        mockMessages.insert(mock, at: 0)
        total = messages.count + mockMessages.count
        newCount += 1
        newMessageIds.insert(mockId)
        LogManager.shared.info("mailbox", "已注入模拟新信件（调试）", context: [
            "mockId": "\(mockId)",
            "total": "\(total)",
            "newCount": "\(newCount)"
        ])
        Task {
            await NotificationManager.shared.sendMailboxSimulationNotification(message: mock)
        }
    }
}

// MARK: - 校长信箱详情页

struct PrincipalMailboxView: View {
    @ObservedObject private var store = PrincipalMailboxStore.shared
    @Environment(\.colorScheme) private var colorScheme

    // 搜索
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchHistory: [String] =
        UserDefaults.standard.stringArray(forKey: "mailboxSearchHistory") ?? []
    @State private var searchLogTask: Task<Void, Never>?

    // 交互反馈
    @State private var toastMessage: String?
    @State private var showContactActions = false
    @State private var heroPulse = false
    /// 刷新成功瞬间的绿色对勾脉冲（工具栏按钮短暂变身反馈）
    @State private var refreshSuccessPulse = false

    // MARK: 数据计算

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    /// 按留言时间倒序（服务端已倒序，本地兜底排序保证稳定；模拟信件今日日期自然置顶）
    private var orderedMessages: [MailboxMessage] {
        store.allMessages.sorted { $0.messageTime > $1.messageTime }
    }

    /// 搜索结果：来信标题 + 回复标题关键词匹配（不区分大小写）
    private var filteredMessages: [MailboxMessage] {
        guard isSearching else { return orderedMessages }
        let keyword = trimmedSearch.lowercased()
        return orderedMessages.filter {
            $0.title.lowercased().contains(keyword) || $0.showTitle.lowercased().contains(keyword)
        }
    }

    // MARK: 视图

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                noticeCard
                if !store.noticeText.isEmpty {
                    contactCard
                }
                searchSection
                if isSearching {
                    searchStatusBar
                }
                contentSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GradientBackground())
        .navigationTitle("校长信箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { mailboxToolbar }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                refreshBanner
                if let message = toastMessage {
                    toastView(message)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .padding(.top, 8)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastMessage)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.refreshStatus)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: store.total)
        .refreshable {
            // 原生下拉刷新：独立任务执行（防手势收回取消导致误报失败），系统指示器由本闭包返回收起
            await store.refreshDetached(source: "下拉刷新")
        }
        .confirmationDialog(
            "联系方式",
            isPresented: $showContactActions,
            titleVisibility: .visible
        ) {
            Button("复制邮箱地址") { copyEmail() }
            Button("发送邮件（打开邮件 App）") { openMail() }
            Button("拨打校长信箱热线") { callPhone() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("电话：\(store.phoneNumber)\n邮箱：\(store.emailAddress)")
        }
        .task {
            store.loadIfNeeded()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                heroPulse = true
            }
            LogManager.shared.info("mailbox", "校长信箱页面打开", context: [
                "hasLoaded": "\(store.hasLoaded)",
                "cachedTotal": "\(store.total)"
            ])
        }
        .onChange(of: searchText) { _, newValue in
            handleSearchChange(newValue)
        }
        .onChange(of: store.refreshStatus) { _, status in
            handleRefreshStatusChange(status)
        }
    }

    /// 刷新状态变化 → 驱动成功脉冲与横幅自动隐藏（失败横幅保留，等待用户重试/关闭）
    private func handleRefreshStatusChange(_ status: PrincipalMailboxStore.RefreshStatus) {
        switch status {
        case .success:
            refreshSuccessPulse = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                refreshSuccessPulse = false
                store.dismissRefreshBanner()
            }
        case .failed(let message):
            LogManager.shared.debugLog("mailbox", "刷新失败横幅展示", context: ["error": message])
        case .refreshing, .idle:
            break
        }
    }

    @ToolbarContentBuilder
    private var mailboxToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                // 更多操作菜单：打开官网信箱页（原返回键长按菜单功能迁移至此）
                Menu {
                    Button {
                        let urlString = "\(SchoolInfo.website)/#/opinion"
                        guard let url = URL(string: urlString) else { return }
                        LogManager.shared.info("mailbox", "菜单·打开官网校长信箱页", context: ["url": urlString])
                        UIApplication.shared.open(url)
                    } label: {
                        Label("打开官网信箱页", systemImage: "safari.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(Color.sjzTeal)
                }
                .accessibilityLabel("更多操作")
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.debugLog("mailbox", "工具栏刷新按钮点击")
                    Task { await store.refresh(source: "工具栏刷新") }
                } label: {
                    Group {
                        if store.refreshStatus == .refreshing {
                            // 刷新中：旋转进度圈（与系统下拉指示器一致的视觉语言）
                            ProgressView()
                                .tint(Color.sjzTeal)
                                .scaleEffect(0.8)
                                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        } else if refreshSuccessPulse {
                            // 成功瞬间：绿色对勾脉冲
                            Image(systemName: "checkmark.seal.fill")
                                .displaySymbolFont(15, weight: .semibold)
                                .foregroundStyle(Color.sjzGreen)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .displaySymbolFont(13, weight: .medium)
                                .foregroundStyle(Color.sjzTeal)
                                .transition(.opacity)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.refreshStatus == .refreshing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: refreshSuccessPulse)
                }
                .disabled(store.refreshStatus == .refreshing || store.isLoading)
            }
        }
    }

    // MARK: 刷新状态横幅（顶部直观反馈：进行中 / 成功 / 失败三态）

    @ViewBuilder
    private var refreshBanner: some View {
        switch store.refreshStatus {
        case .idle:
            EmptyView()

        case .refreshing:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Color.sjzTeal)
                    .scaleEffect(0.75)
                Text("正在刷新校长信箱…")
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))

        case .success(let newCount, let elapsedMs, _):
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(Color.sjzGreen)
                    Text(newCount > 0 ? "刷新成功 · 新增 \(newCount) 封回复" : "刷新成功 · 已是最新内容")
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text("\(elapsedMs)ms")
                        .displayFont(10)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if let lastRefreshDate = store.lastRefreshDate {
                    Text("更新于 \(Self.timeText(lastRefreshDate))")
                        .displayFont(9)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .displaySymbolFont(13)
                    .foregroundStyle(Color.sjzOrange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("刷新失败")
                        .displayFont(12, weight: .bold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button {
                    LogManager.shared.debugLog("mailbox", "刷新失败横幅重试点击")
                    Task { await store.refresh(source: "横幅重试") }
                } label: {
                    Text("重试")
                        .displayFont(11, weight: .bold)
                        .foregroundStyle(Color.sjzTeal)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.sjzTeal.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    store.dismissRefreshBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            .frame(maxWidth: 400)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// 刷新时间文案（HH:mm:ss，横幅"更新于"可视证据）
    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: ① 主题头卡

    private var heroCard: some View {
        ZStack {
            // 品牌渐变底
            LinearGradient(
                colors: [Color.sjzTeal, Color.sjzAccent.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // 装饰：右上大圆环 + 左下小圆（呼吸动效）
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 14)
                .frame(width: 130, height: 130)
                .offset(x: 130, y: -46)
                .scaleEffect(heroPulse ? 1.06 : 1)
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 66, height: 66)
                .offset(x: -142, y: 58)

            HStack(spacing: 16) {
                // 渐变信封图标块
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: "envelope.open.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    .rotation3DEffect(.degrees(heroPulse ? 4 : -2), axis: (x: 0, y: 1, z: 0))

                VStack(alignment: .leading, spacing: 5) {
                    Text("倾听师生心声")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("校长信箱")
                        .displayFont(22, weight: .heavy)
                        .foregroundStyle(.white)
                    Text("共建美好校园 · 真诚沟通零距离")
                        .displayFont(11)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer(minLength: 0)

                if store.hasLoaded && store.total > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        if store.newCount > 0 {
                            Text("+\(store.newCount) 新回复")
                                .displayFont(9, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.white.opacity(0.25)))
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        Text("\(store.total)")
                            .displayFont(24, weight: .heavy)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("封公开回复")
                            .displayFont(9, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.sjzTeal.opacity(0.35), radius: 20, y: 10)
    }

    // MARK: ② 使用说明卡

    private var noticeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .displaySymbolFont(12)
                    .foregroundStyle(Color.sjzTeal)
                Text("使用说明")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if store.noticeText.isEmpty && !store.hasLoaded {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.sjzTeal)
                    Text("正在加载信箱说明…")
                        .displayFont(12)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(store.noticeText)
                    .displayFont(13)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(5)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    // MARK: ③ 联系方式卡

    private var contactCard: some View {
        VStack(spacing: 10) {
            contactRow(
                icon: "phone.fill",
                iconTint: Color.sjzGreen,
                label: "校长信箱热线",
                value: store.phoneNumber,
                actionTitle: "拨打"
            ) { callPhone() }

            Divider().padding(.leading, 50)

            contactRow(
                icon: "envelope.fill",
                iconTint: Color.sjzIndigo,
                label: "信箱邮箱",
                value: store.emailAddress,
                actionTitle: "复制"
            ) { copyEmail() }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    private func contactRow(icon: String, iconTint: Color, label: String, value: String,
                            actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [iconTint.opacity(0.9), iconTint.opacity(0.5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: icon)
                        .displaySymbolFont(14, weight: .semibold)
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                Text(value)
                    .displayFont(14, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)

            Button(action: action) {
                Text(actionTitle)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(iconTint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(iconTint.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(iconTint.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: ④ 搜索区

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .displaySymbolFont(14, weight: .medium)
                    .foregroundStyle(Color.sjzTeal)

                TextField("搜索来信与回复", text: $searchText)
                    .displayFont(15)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit { commitSearch() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .displaySymbolFont(14)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                if isSearchFocused {
                    Capsule().strokeBorder(Color.sjzTeal.opacity(0.55), lineWidth: 1)
                } else {
                    Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isSearchFocused)

            // 搜索历史（聚焦且未输入时展示）
            if isSearchFocused && !isSearching && !searchHistory.isEmpty {
                searchHistoryChips
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSearchFocused)
    }

    private var searchHistoryChips: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .displaySymbolFont(11)
                .foregroundStyle(.tertiary
                )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searchHistory, id: \.self) { keyword in
                        Button {
                            searchText = keyword
                            isSearchFocused = false
                            LogManager.shared.info("mailbox", "搜索历史点击", context: ["keyword": keyword])
                        } label: {
                            Text(keyword)
                                .displayFont(11, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                searchHistory = []
                UserDefaults.standard.set([String](), forKey: "mailboxSearchHistory")
                LogManager.shared.info("mailbox", "搜索历史已清空")
            } label: {
                Image(systemName: "trash")
                    .displaySymbolFont(11)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: ⑤ 内容区（骨架 / 错误 / 列表）

    @ViewBuilder
    private var contentSection: some View {
        if store.isLoading && store.messages.isEmpty {
            skeletonList
        } else if let error = store.lastError, store.messages.isEmpty {
            errorCard(error)
        } else if orderedMessages.isEmpty {
            emptyDataView
        } else {
            listSection
        }
    }

    private var listSection: some View {
        VStack(spacing: 10) {
            if isSearching && filteredMessages.isEmpty {
                emptySearchView
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredMessages) { message in
                        NavigationLink {
                            MailboxMessageDetailView(message: message)
                        } label: {
                            messageCard(message)
                        }
                        .buttonStyle(.plain)
                        .modifier(SJZRevealOnce(key: "mailbox.msg.\(message.id)", delay: 0.04))
                    }
                }

                // 搜索命中统计（直观可见的结果反馈）
                if isSearching {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .displaySymbolFont(10)
                            .foregroundStyle(Color.sjzTeal)
                        Text("共 \(filteredMessages.count) 封匹配信件")
                            .displayFont(11, weight: .medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.top, 2)
                }
            }
        }
    }

    // MARK: 信件卡片

    private func messageCard(_ message: MailboxMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.sjzTeal.opacity(0.9), Color.sjzAccent.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "envelope.fill")
                            .displaySymbolFont(13, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.sjzTeal.opacity(0.25), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 6) {
                    highlightedText(message.showTitle, keyword: trimmedSearch, baseColor: .primary)
                        .displayFont(15, weight: .semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 4) {
                        Text("来信：")
                            .displayFont(12, weight: .medium)
                            .foregroundStyle(.tertiary)
                        highlightedText(message.title, keyword: trimmedSearch, baseColor: .secondary)
                            .displayFont(12)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 6) {
                        Text(message.dateText)
                            .displayFont(10)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text("已公开回复")
                            .displayFont(9, weight: .semibold)
                            .foregroundStyle(Color.sjzGreen)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.sjzGreen.opacity(0.1)))
                        if store.newMessageIds.contains(message.id) {
                            Text("NEW")
                                .displayFont(9, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.sjzAccent))
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                }

                Spacer(minLength: 0)

                // 可点击查看回复内容的指示箭头
                VStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(11, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                    Image(systemName: "text.bubble.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(Color.sjzTeal.opacity(0.7))
                }
                .padding(.trailing, 2)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
    }

    /// 关键词命中高亮：iOS 15+ 使用 AttributedString 行内高亮；更早系统退化为普通文本
    @ViewBuilder
    private func highlightedText(_ text: String, keyword: String, baseColor: Color) -> some View {
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        if keyword.isEmpty {
            Text(text)
                .foregroundColor(baseColor)
        } else if #available(iOS 15.0, *) {
            Text(mailboxHighlighted(text, keyword: keyword, baseColor: baseColor))
        } else {
            Text(text)
                .foregroundColor(baseColor)
        }
    }

    /// 构造命中高亮的 AttributedString（先收集全部命中再着色，避免修改属性干扰后续查找）
    @available(iOS 15.0, *)
    private func mailboxHighlighted(_ text: String, keyword: String, baseColor: Color) -> AttributedString {
        var attr = AttributedString(text)
        var cursor = attr.startIndex
        var ranges: [Range<AttributedString.Index>] = []
        while cursor < attr.endIndex,
              let range = attr[cursor...].range(of: keyword, options: .caseInsensitive) {
            ranges.append(range)
            cursor = range.upperBound
        }
        attr.foregroundColor = baseColor
        for range in ranges {
            attr[range].foregroundColor = Color.sjzOrange
        }
        return attr
    }

    // MARK: 搜索状态栏

    private var searchStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(11)
                .foregroundStyle(Color.sjzTeal)
            Text("搜索「\(trimmedSearch)」")
                .displayFont(12, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(filteredMessages.count) 个结果")
                .displayFont(11)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.04), in: Capsule())
        }
        .padding(.horizontal, 4)
    }

    // MARK: 骨架屏

    private var skeletonList: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 180, height: 14)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 240, height: 12)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: 110, height: 10)
                        }
                    }
                    .padding(14)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
                .overlay {
                    ShimmerView().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    // MARK: 空态 / 错误态

    private var emptySearchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.sjzTeal.opacity(0.7))
            Text("未找到匹配「\(trimmedSearch)」的信件")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("试试其他关键词，如「招生」「毕业」「咨询」")
                .displayFont(12)
                .foregroundStyle(.tertiary)
            Button {
                searchText = ""
            } label: {
                Text("清除搜索")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzTeal)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzTeal.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private var emptyDataView: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.sjzTeal.opacity(0.7))
            Text("暂无公开回复信件")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("校长信箱公开回复将在此展示")
                .displayFont(12)
                .foregroundStyle(.tertiary)
            Button {
                Task { await store.refresh(source: "空态刷新") }
            } label: {
                Text("刷新")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzTeal)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzTeal.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.sjzOrange.opacity(0.8))
            Text("信箱数据加载失败")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .displayFont(12)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                LogManager.shared.info("mailbox", "失败重试点击", context: ["error": message])
                Task { await store.refresh(source: "失败重试") }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .displayLabelFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzTeal)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzTeal.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 轻提示

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .displaySymbolFont(12)
                .foregroundStyle(Color.sjzGreen)
            Text(message)
                .displayFont(12, weight: .medium)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 15).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    // MARK: 交互

    private func handleSearchChange(_ newValue: String) {
        searchLogTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            LogManager.shared.debugLog("mailbox", "搜索已清空")
            return
        }
        // 防抖 500ms 后记录命中统计（避免逐字刷日志；过滤本身即时生效）
        let keyword = trimmed
        searchLogTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let hits = orderedMessages.filter {
                $0.title.lowercased().contains(keyword.lowercased()) ||
                $0.showTitle.lowercased().contains(keyword.lowercased())
            }.count
            LogManager.shared.debugLog("mailbox", "信箱关键词搜索", context: [
                "keyword": keyword,
                "hits": "\(hits)",
                "total": "\(orderedMessages.count)"
            ])
        }
    }

    /// 提交搜索：写入搜索历史（去重、最多 10 条）
    private func commitSearch() {
        let keyword = trimmedSearch
        guard !keyword.isEmpty else { return }
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 10 { searchHistory = Array(searchHistory.prefix(10)) }
        UserDefaults.standard.set(searchHistory, forKey: "mailboxSearchHistory")
        isSearchFocused = false
        LogManager.shared.info("mailbox", "搜索提交", context: [
            "keyword": keyword,
            "hits": "\(filteredMessages.count)",
            "historyCount": "\(searchHistory.count)"
        ])
    }

    private func callPhone() {
        let phone = store.phoneNumber.replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "tel://\(phone)") else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            LogManager.shared.info("mailbox", "拨号发起", context: ["phone": store.phoneNumber])
        } else {
            showToast("当前设备无法拨打电话")
            LogManager.shared.warning("mailbox", "拨号失败", context: ["reason": "设备不支持 tel 协议"])
        }
    }

    private func copyEmail() {
        UIPasteboard.general.string = store.emailAddress
        showToast("邮箱地址已复制")
        LogManager.shared.info("mailbox", "邮箱地址已复制", context: ["email": store.emailAddress])
    }

    private func openMail() {
        guard let url = URL(string: "mailto:\(store.emailAddress)") else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            LogManager.shared.info("mailbox", "邮件撰写发起", context: ["email": store.emailAddress])
        } else {
            showToast("未安装邮件应用")
            LogManager.shared.warning("mailbox", "邮件撰写失败", context: ["reason": "未安装邮件应用"])
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }
}

// MARK: - 信件详情页（来信 + 校方回复）

struct MailboxMessageDetailView: View {
    /// 列表传入的信件基础信息（首屏立即渲染标题/时间，正文加载中占位）
    let message: MailboxMessage

    @ObservedObject private var store = PrincipalMailboxStore.shared
    @State private var detail: MailboxMessageDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?

    /// 官网校长信箱页面（留言入口）
    private static let opinionURL = URL(string: "https://www.sxjzit.edu.cn/#/opinion")

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                if let detail {
                    letterCard(detail)
                    replyCard(detail)
                } else if let errorMessage {
                    errorCard(errorMessage)
                } else {
                    skeletonCard
                }
                actionCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GradientBackground())
        .navigationTitle("信件详情")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let message = toastMessage {
                toastView(message)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastMessage)
        .task {
            await loadDetail()
        }
        .onAppear {
            LogManager.shared.info("mailbox", "信件详情页打开", context: [
                "messageId": "\(message.id)",
                "hasDetailLoaded": "\(detail != nil)"
            ])
        }
    }

    // MARK: 数据加载

    private func loadDetail() async {
        guard detail == nil else { return }

        // 模拟信件（id ≥ 900000，Debug 面板「模拟信箱新信」注入）：服务端不存在该 id，
        // 直接本地构造示意详情，保证「模拟 → 通知 → 直达详情」验收链路完整闭环
        if message.id >= 900000 {
            detail = MailboxMessageDetail(
                showTitle: message.showTitle,
                content: "（模拟来信）这是一封用于测试通知链路与详情展示的模拟来信：反映学生宿舍热水供应时段不足的问题。",
                isShowContent: true,
                messageTime: message.messageTime,
                isReplied: 1,
                replyContent: "（模拟回复）学校已收到相关反映，后勤部门将在本周内完成热水系统时段调整与检修，感谢您的监督与建议。",
                replyTime: message.messageTime
            )
            LogManager.shared.info("mailbox", "模拟信件详情本地注入（服务端无此 id）", context: [
                "messageId": "\(message.id)"
            ])
            return
        }

        isLoading = true
        errorMessage = nil
        let start = Date()
        LogManager.shared.debugLog("mailbox", "信件详情拉取开始", context: ["messageId": "\(message.id)"])
        do {
            detail = try await NetworkService.shared.fetchMessageDetail(msgId: message.id)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            LogManager.shared.info("mailbox", "信件详情拉取成功", context: [
                "messageId": "\(message.id)",
                "elapsedMs": "\(elapsed)",
                "replied": "\(detail?.replied ?? false)",
                "showContent": "\(detail?.isShowContent ?? false)",
                "replyChars": "\(detail?.replyContent.count ?? 0)"
            ])
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            LogManager.shared.error("mailbox", "信件详情拉取失败", context: [
                "messageId": "\(message.id)",
                "error": errorMessage ?? "(无)",
                "elapsedMs": "\(elapsed)"
            ])
        }
        isLoading = false
    }

    // MARK: ① 头卡（回复标题 + 状态徽章）

    private var headerCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sjzTeal, Color.sjzAccent.opacity(0.82)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 12)
                .frame(width: 110, height: 110)
                .offset(x: 150, y: -52)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // 状态徽章：已回复 / 办理中
                    if let detail, detail.replied {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .displaySymbolFont(9)
                            Text("已回复")
                                .displayFont(9, weight: .bold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.sjzGreen.opacity(0.85)))
                    } else if detail != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .displaySymbolFont(9)
                            Text("办理中")
                                .displayFont(9, weight: .bold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.sjzOrange.opacity(0.85)))
                    }
                    Text(message.dateText)
                        .displayFont(10)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }

                Text(message.showTitle)
                    .displayFont(20, weight: .heavy)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.sjzTeal.opacity(0.3), radius: 18, y: 9)
    }

    // MARK: ② 来信卡（隐私保护感知）

    private func letterCard(_ detail: MailboxMessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "envelope.fill")
                    .displaySymbolFont(12)
                    .foregroundStyle(Color.sjzTeal)
                Text("来信内容")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if detail.isShowContent {
                    Text("已公开")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(Color.sjzGreen)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.sjzGreen.opacity(0.1)))
                } else {
                    Text("隐私保护")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(Color.sjzOrange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.sjzOrange.opacity(0.1)))
                }
            }

            if detail.isShowContent && !detail.content.isEmpty {
                Text(detail.content)
                    .displayFont(14)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(6)
            } else {
                // 服务端隐私保护：来信内容不公开
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color.sjzOrange.opacity(0.75))
                    Text(detail.content.isEmpty ? "为保护个人隐私，来信内容已隐藏" : detail.content)
                        .displayFont(13)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.sjzOrange.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .displaySymbolFont(9)
                Text("来信时间 \(detail.messageDateText)")
                    .displayFont(10)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    // MARK: ③ 校方回复卡

    private func replyCard(_ detail: MailboxMessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .displaySymbolFont(12)
                    .foregroundStyle(Color.sjzIndigo)
                Text("校方回复")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if detail.replied && !detail.replyContent.isEmpty {
                Text(detail.replyContent)
                    .displayFont(14)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(6)

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .displaySymbolFont(9)
                    Text("回复时间 \(detail.replyDateText)")
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color.sjzIndigo.opacity(0.6))
                    Text("感谢您的来信，我们正在加急办理中")
                        .displayFont(13, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text("回复内容将在办理完成后第一时间公开")
                        .displayFont(11)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.sjzIndigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
    }

    // MARK: ④ 操作卡（留言入口 / 联系我们）

    private var actionCard: some View {
        VStack(spacing: 12) {
            // 前往官网留言
            Button {
                guard let url = Self.opinionURL else { return }
                UIApplication.shared.open(url)
                LogManager.shared.info("mailbox", "前往官网留言页面", context: ["url": url.absoluteString])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .displaySymbolFont(14, weight: .semibold)
                    Text("前往官网留言")
                        .displayFont(14, weight: .semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .displaySymbolFont(12)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(
                    LinearGradient(colors: [Color.sjzTeal, Color.sjzAccent],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            // 联系校长信箱
            HStack(spacing: 10) {
                Button {
                    callPhone()
                } label: {
                    Label(store.phoneNumber, systemImage: "phone.fill")
                        .displayLabelFont(12, weight: .medium)
                        .foregroundStyle(Color.sjzGreen)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.sjzGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.sjzGreen.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Button {
                    copyEmail()
                } label: {
                    Label(store.emailAddress, systemImage: "envelope.fill")
                        .displayLabelFont(12, weight: .medium)
                        .foregroundStyle(Color.sjzIndigo)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.sjzIndigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.sjzIndigo.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 加载 / 错误 / 提示

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 150, height: 14)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
                .frame(width: 200, height: 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .overlay {
            ShimmerView().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.sjzOrange.opacity(0.8))
            Text("信件内容加载失败")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .displayFont(12)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                errorMessage = nil
                Task { await loadDetail() }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .displayLabelFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzTeal)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.sjzTeal.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private func toastView(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .displaySymbolFont(12)
                .foregroundStyle(Color.sjzGreen)
            Text(message)
                .displayFont(12, weight: .medium)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 15).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    // MARK: 交互

    private func callPhone() {
        let phone = store.phoneNumber.replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "tel://\(phone)") else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            LogManager.shared.info("mailbox", "详情页拨号发起", context: ["phone": store.phoneNumber])
        } else {
            showToast("当前设备无法拨打电话")
            LogManager.shared.warning("mailbox", "详情页拨号失败", context: ["reason": "设备不支持 tel 协议"])
        }
    }

    private func copyEmail() {
        UIPasteboard.general.string = store.emailAddress
        showToast("邮箱地址已复制")
        LogManager.shared.info("mailbox", "详情页邮箱地址已复制", context: ["email": store.emailAddress])
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }
}

// MARK: - 通知深链宿主（sheet 根：自动 push 到目标信件详情）

/// 校长信箱通知点击后的 sheet 根视图：
/// 根层为信箱列表，携带信件 id 时等待数据就绪后自动 push 到对应详情（返回按钮可回到列表）。
/// 实现说明：使用 NavigationLink(isActive:) 触发 push——对比 NavigationStack path 方案，
/// 链接在视图挂载时即已注册，isActive 翻转不会因「栈尚未完全建立」而丢失导航动作（真机踩坑结论）。
struct MailboxSheetRoot: View {
    let messageID: Int?
    let onClose: () -> Void

    @ObservedObject private var store = PrincipalMailboxStore.shared
    @State private var targetMessage: MailboxMessage?
    @State private var pushDetail = false

    var body: some View {
        NavigationStack {
            PrincipalMailboxView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .displaySymbolFont(16)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // 编程触发的详情 push（官方推荐的回调式深链 API，无废弃警告；
                // 挂载稳定后翻转 isPresented 不会被栈建立时序吞掉导航动作）
                .navigationDestination(isPresented: $pushDetail) {
                    if let targetMessage {
                        MailboxMessageDetailView(message: targetMessage)
                    } else {
                        MailboxMessageMissingView(messageID: messageID ?? 0)
                    }
                }
        }
        .task {
            await routeToMessageIfNeeded()
        }
    }

    /// 等待数据可用后自动 push 目标信件详情（通知携带的 id 可能是服务端新增信件，需先完成拉取）
    private func routeToMessageIfNeeded() async {
        guard let messageID else {
            LogManager.shared.debugLog("mailbox", "信箱 sheet 打开（未携带深链目标）", context: [:])
            return
        }
        store.loadIfNeeded()
        var waited = 0
        while !store.hasLoaded && waited < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        // 待 sheet 与导航栈挂载稳定后再触发 push，避免导航动作被吞
        try? await Task.sleep(nanoseconds: 350_000_000)
        if let target = store.allMessages.first(where: { $0.id == messageID }) {
            targetMessage = target
            pushDetail = true
            LogManager.shared.info("mailbox", "通知深链直达信件详情", context: ["mailboxId": "\(messageID)"])
        } else {
            LogManager.shared.warning("mailbox", "通知深链未找到目标信件，停留在列表", context: ["mailboxId": "\(messageID)"])
        }
    }
}

/// 深链目标缺失时的防御性占位（正常流程不可达）
private struct MailboxMessageMissingView: View {
    let messageID: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge.questionmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.sjzTeal.opacity(0.7))
            Text("信件暂不可用")
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("该信件可能已下架或超出展示期（id \(messageID)）")
                .displayFont(12)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GradientBackground())
    }
}