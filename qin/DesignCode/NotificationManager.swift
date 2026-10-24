//
//  NotificationManager.swift
//  山西晋中理工学院 APP — 本地推送通知（学校官网更新）
//
//  无第三方 SDK，不依赖自建服务器，纯 iOS 原生 UserNotifications 实现。
//  实时抓取学校官网新闻，对比本地数据，发现新增文章推送通知。
//

import Foundation
import UserNotifications
import SwiftUI

// MARK: - 通知测试结果

/// 通知测试操作的统一结果封装（供设置页「通知测试」直观展示状态）
enum NotificationTestResult: Equatable {
    case success(String)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let m): return m
        case .failure(let m): return m
        }
    }
}

// MARK: - 通知点击 DeepLink 状态（@Published 驱动，替代 NotificationCenter 广播的不可靠订阅）

/// 待打开的文章 deep link（每次点击通知都生成新实例，id 保证 onChange 每次都触发）
struct PendingArticleDeepLink: Equatable {
    let id: UUID
    let articleId: String
    let category: String
    let title: String
    let source: String

    init(articleId: String, category: String, title: String, source: String) {
        self.id = UUID()
        self.articleId = articleId
        self.category = category
        self.title = title
        self.source = source
    }
}

/// DeepLink 处理结果（回显给通知测试页的闭环反馈）
enum DeepLinkOutcome: Equatable {
    case presented(articleId: String)   // 详情页已成功打开
    case failed(articleId: String, reason: String)  // 未能打开（含原因）

    var articleId: String {
        switch self {
        case .presented(let id): return id
        case .failed(let id, _): return id
        }
    }

    var isSuccess: Bool {
        if case .presented = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .presented: return "文章详情页已打开"
        case .failed(_, let reason): return "详情页未能打开：\(reason)"
        }
    }
}

// MARK: - 通知管理器

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    // MARK: 持久化配置

    @AppStorage("notificationEnabled") var isEnabled: Bool = false {
        didSet {
            if isEnabled { startPolling() } else { stopPolling() }
        }
    }

    @AppStorage("notificationPollingMinutes") var pollingIntervalMinutes: Int = 30 {
        didSet { restartPollingIfNeeded() }
    }

    // MARK: 发布状态

    @Published var isAuthorized: Bool = false
    /// 授权状态明细文案（供设置页与通知测试页展示）
    @Published var authorizationDetailText: String = "未知"
    @Published var lastCheckTime: Date? {
        didSet {
            if let t = lastCheckTime {
                UserDefaults.standard.set(t.timeIntervalSince1970, forKey: "notificationLastCheckTime")
            } else {
                UserDefaults.standard.removeObject(forKey: "notificationLastCheckTime")
            }
        }
    }
    @Published var isChecking: Bool = false
    @Published var lastCheckError: String?
    @Published var newArticlesFound: Int = 0

    /// 待打开的文章 DeepLink（点击通知 / 模拟点击后设置，主界面 onChange 消费）
    @Published var pendingDeepLink: PendingArticleDeepLink?
    /// 校长信箱通知点击标志（携带信件 id；主界面 onChange 接收后以 sheet 直达信件详情）
    @Published var pendingMailboxDeepLink: Int?
    /// 学校概况更新通知点击标志（主界面以 sheet 直达学校概况页）
    @Published var pendingSchoolProfileDeepLink: Bool = false
    /// 党建专题通知深链（用户点击「党建专题·有新内容」通知 → 主界面打开党建专题 sheet）
    @Published var pendingPartySubjectDeepLink: Bool = false
    /// DeepLink 处理结果（供通知测试页闭环回显）
    @Published var deepLinkOutcome: DeepLinkOutcome?
    /// 系统「标记（Badge）」许可状态文案
    @Published var badgeSettingText: String = "未知"

    // MARK: 已通知文章追踪（防重复推送）

    private var notifiedArticleIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notifiedArticleIds") ?? []) }
        set {
            // 限制最多保留 2000 条记录，防止无限增长
            let trimmed = Array(newValue.suffix(2000))
            UserDefaults.standard.set(trimmed, forKey: "notifiedArticleIds")
        }
    }

    /// 已通知的校长信箱信件 id（防重复推送；与文章独立通道）
    private var notifiedMailboxIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notifiedMailboxIds") ?? []) }
        set {
            let trimmed = Array(newValue.suffix(2000))
            UserDefaults.standard.set(trimmed, forKey: "notifiedMailboxIds")
        }
    }

    // MARK: 轮询定时器

    private var pollingTimer: Timer?
    private let maxNotificationsPerCheck = 5  // 每次最多推送 5 条，避免轰炸

    // MARK: 初始化

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        LogManager.shared.info("notification", "通知管理器初始化完成，系统通知代理已注册", context: [
            "delegate": "NotificationManager.shared"
        ])

        // 恢复上次检查时间
        if let interval = UserDefaults.standard.object(forKey: "notificationLastCheckTime") as? TimeInterval {
            lastCheckTime = Date(timeIntervalSince1970: interval)
        }

        // 启动时刷新授权状态
        Task { await refreshAuthorizationStatus() }
    }

    // MARK: 权限管理

    /// 请求通知权限
    func requestPermission() async -> Bool {
        LogManager.shared.info("notification", "请求系统通知权限", context: ["options": "alert, sound, badge"])
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            authorizationDetailText = granted ? "已授权" : "已拒绝"
            if granted && isEnabled { startPolling() }
            LogManager.shared.info("notification", "通知权限请求结果", context: ["granted": "\(granted)"])
            return granted
        } catch {
            isAuthorized = false
            LogManager.shared.error("notification", "通知权限请求异常", context: ["error": error.localizedDescription])
            return false
        }
    }

    /// 刷新当前授权状态
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        authorizationDetailText = Self.authorizationStatusDescription(settings)
        badgeSettingText = Self.badgeSettingDescription(settings.badgeSetting)
        LogManager.shared.debugLog("notification", "刷新通知授权状态", context: [
            "authorized": "\(isAuthorized)",
            "status": authorizationDetailText,
            "badgeSetting": badgeSettingText
        ])
    }

    /// 授权状态 → 可读文案
    private static func authorizationStatusDescription(_ settings: UNNotificationSettings) -> String {
        switch settings.authorizationStatus {
        case .notDetermined: return "未决定（尚未请求授权）"
        case .denied: return "已拒绝（需前往系统设置开启）"
        case .authorized: return "已授权"
        case .provisional: return "临时授权（静默试推送）"
        case .ephemeral: return "临时授权（App Clip）"
        @unknown default: return "未知状态"
        }
    }

    /// 系统「标记」许可 → 可读文案
    private static func badgeSettingDescription(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled: return "已开启"
        case .disabled: return "已关闭（角标设置将无效）"
        case .notSupported: return "设备不支持"
        @unknown default: return "未知"
        }
    }

    /// 打开系统设置（引导用户手动开启通知权限）
    func openSystemSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: 轮询控制

    func startPolling() {
        stopPolling()
        guard isEnabled, isAuthorized else { return }

        let interval = TimeInterval(pollingIntervalMinutes * 60)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates()
            }
        }
        // 首次立即检查
        Task { await checkForUpdates() }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func restartPollingIfNeeded() {
        guard isEnabled, isAuthorized else { return }
        startPolling()
    }

    // MARK: 核心：检查更新

    /// 抓取学校官网新闻，对比本地已通知记录，发现新增内容则推送通知。
    /// pushToSystem=false 时为「静默检测」（消息中心站内信语义）：仅比对、标记并写入消息中心，
    /// 不发送系统通知；独立于系统通知开关（用户未授权通知时仍可收站内消息）。
    func checkForUpdates(pushToSystem: Bool = true) async {
        guard !isChecking else { return }
        if pushToSystem {
            guard isEnabled, isAuthorized else { return }
        }

        isChecking = true
        lastCheckError = nil
        newArticlesFound = 0
        defer { isChecking = false; lastCheckTime = Date() }

        // 新闻、校长信箱、学校概况、党建专题为四条独立检测通道：任一失败均不影响其他通道
        await checkNewsUpdates(pushToSystem: pushToSystem)
        await checkMailboxUpdates(pushToSystem: pushToSystem)
        await checkSchoolProfileUpdates(pushToSystem: pushToSystem)
        await checkPartySubjectUpdates(pushToSystem: pushToSystem)
    }

    /// 新闻新文章检测（原核心逻辑）
    private func checkNewsUpdates(pushToSystem: Bool = true) async {
        do {
            // 1. 获取首页数据，拿到各栏目的 columnId
            let home2 = try await NetworkService.shared.fetchHome2()
            guard let newsChildren = home2.news?.children else {
                lastCheckError = "首页数据为空"
                return
            }

            // 2. 并行拉取各栏目最新文章（仅第一页，减少网络开销）
            var allArticles: [(category: String, id: String, title: String)] = []

            let categories: [(columnId: String?, name: String)] = [
                (newsChildren.importants?.columnId, "学校要闻"),
                (newsChildren.updates?.columnId, "新闻资讯"),
                (newsChildren.resports?.columnId, "党建动态"),
                (newsChildren.notices?.columnId, "通知公告"),
            ]

            // 并行请求各栏目
            await withTaskGroup(of: [(String, String, String)].self) { group in
                for (colId, name) in categories {
                    guard let colId = colId else { continue }
                    group.addTask {
                        do {
                            let result = try await NetworkService.shared.fetchArticles(
                                columnId: colId, page: 1, size: 10)
                            return (result.articles?.list ?? []).compactMap { a in
                                guard let id = a.id, let title = a.resolvedTitle else { return nil }
                                return (name, id, title)
                            }
                        } catch {
                            print("[NotificationManager] 栏目「\(name)」拉取失败: \(error.localizedDescription)")
                            return []
                        }
                    }
                }
                for await articles in group {
                    allArticles.append(contentsOf: articles)
                }
            }

            // 3. 对比已通知记录，找出新增文章
            let newArticles = allArticles.filter { !notifiedArticleIds.contains($0.id) }
            guard !newArticles.isEmpty else { return }

            // 4. 限制推送数量，避免轰炸
            let toNotify = Array(newArticles.prefix(maxNotificationsPerCheck))

            // 5. 发送本地通知（静默检测模式跳过发送，但同样入盒并标记）
            for (index, article) in toNotify.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = "【\(article.category)】"
                content.body = article.title
                content.sound = .default
                content.badge = nil
                content.userInfo = [
                    "articleId": article.id,
                    "articleCategory": article.category,
                    "articleTitle": article.title
                ]

                // 错开 1 秒发送，避免通知堆叠在同一秒
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(1 + index), repeats: false)
                let identifier = "news-\(article.id)"
                let request = UNNotificationRequest(
                    identifier: identifier, content: content, trigger: trigger)

                var delivered = false
                if pushToSystem {
                    do {
                        try await UNUserNotificationCenter.current().add(request)
                        delivered = true
                    } catch {
                        print("[NotificationManager] 通知发送失败: \(error.localizedDescription)")
                    }
                } else {
                    delivered = true
                    LogManager.shared.debugLog("messageCenter", "静默检测：跳过系统通知发送", context: [
                        "identifier": identifier
                    ])
                }

                // 消息中心入盒（与系统通知一一对应，仅发送成功或静默模式入盒）
                if delivered {
                    MessageCenterStore.shared.ingest(
                        kind: .news,
                        id: identifier,
                        title: "【\(article.category)】",
                        subtitle: article.title,
                        deepLink: DeepLinkPayload(
                            articleId: article.id,
                            articleCategory: article.category,
                            articleTitle: article.title))
                }
            }

            // 6. 标记为已通知
            for article in toNotify {
                notifiedArticleIds.insert(article.id)
            }

            newArticlesFound = toNotify.count
            print("[NotificationManager] 发现 \(toNotify.count) 篇新文章，已推送通知")

        } catch let error as NetworkError {
            lastCheckError = error.localizedDescription
            print("[NotificationManager] 检查失败: \(error.localizedDescription)")
        } catch {
            lastCheckError = "网络异常，请检查网络连接"
            print("[NotificationManager] 检查失败: \(error.localizedDescription)")
        }
    }

    /// 校长信箱新回复检测：拉取第一页对比本地已通知集合，发现新增则推送本地通知（点击直达信箱页）。
    /// 首次启用时仅建立基线不推送，避免把历史 12 封全部轰炸给用户。
    private func checkMailboxUpdates(pushToSystem: Bool = true) async {
        do {
            let page = try await NetworkService.shared.fetchPrincipalMailbox(page: 1, size: 20)
            let fresh = page.messages
            guard !fresh.isEmpty else { return }

            LogManager.shared.debugLog("notification", "校长信箱增量检测", context: [
                "serverTotal": "\(page.total)",
                "fetched": "\(fresh.count)",
                "known": "\(notifiedMailboxIds.count)"
            ])

            // 首次启用：建立基线（标记现有信件为已通知），不推送历史
            if notifiedMailboxIds.isEmpty {
                for message in fresh {
                    notifiedMailboxIds.insert("\(message.id)")
                }
                LogManager.shared.info("notification", "校长信箱通知基线建立（不推送历史）", context: [
                    "baselineCount": "\(fresh.count)",
                    "serverTotal": "\(page.total)"
                ])
                return
            }

            let incoming = fresh.filter { !notifiedMailboxIds.contains("\($0.id)") }
            guard !incoming.isEmpty else { return }

            let toNotify = Array(incoming.prefix(3))
            for (index, message) in toNotify.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = "校长信箱 · 新回复"
                content.body = message.showTitle
                content.sound = .default
                content.badge = nil
                content.userInfo = [
                    "mailboxId": "\(message.id)",
                    "mailboxTitle": message.showTitle,
                    "deepLink": "principalMailbox"
                ]

                // 错开 1 秒发送，避免通知堆叠在同一秒
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(1 + index), repeats: false)
                let request = UNNotificationRequest(
                    identifier: "mailbox-\(message.id)", content: content, trigger: trigger)

                var delivered = false
                if pushToSystem {
                    do {
                        try await UNUserNotificationCenter.current().add(request)
                        delivered = true
                    } catch {
                        LogManager.shared.warning("notification", "校长信箱通知发送失败", context: [
                            "mailboxId": "\(message.id)",
                            "error": error.localizedDescription
                        ])
                    }
                } else {
                    delivered = true
                }

                if delivered {
                    let boxId = "mailbox-\(message.id)"
                    MessageCenterStore.shared.ingest(
                        kind: .mailbox,
                        id: boxId,
                        title: "校长信箱 · 新回复",
                        subtitle: message.showTitle,
                        deepLink: DeepLinkPayload(
                            mailboxId: "\(message.id)",
                            mailboxTitle: message.showTitle))
                }
            }

            for message in toNotify {
                notifiedMailboxIds.insert("\(message.id)")
            }
            LogManager.shared.info("notification", "校长信箱检测到新回复并推送", context: [
                "found": "\(incoming.count)",
                "pushed": "\(toNotify.count)",
                "serverTotal": "\(page.total)"
            ])
        } catch {
            LogManager.shared.debugLog("notification", "校长信箱增量检测失败（不影响新闻通道）", context: [
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
        }
    }

    // MARK: 信箱通知模拟（调试验收：Debug 面板触发，验证 横幅→点击→直达信箱页 全链路）

    /// 学校概况更新检测：对比本地基线（领导数|风光数|合作交流条数），变化则推送通知（点击直达概况页）。
    /// 首次启用仅建立基线，不推送；旧版两段基线（领导数|风光数）静默升级为三段，不误报历史。
    private func checkSchoolProfileUpdates(pushToSystem: Bool = true) async {
        let baselineKey = "schoolProfileBaseline"
        do {
            let root = try await NetworkService.shared.fetchJSONDict(path: "/school/intro")
            guard let data = root["data"] as? [String: Any] else { return }

            let leaderCount: Int
            if let lb = data["current-leader"] as? [String: Any],
               let ld = lb["data"] as? [String: Any],
               let list = ld["list"] as? [[String: Any]] {
                leaderCount = list.count
            } else {
                leaderCount = 0
            }

            let sceneryTotal: Int
            if let cl = data["campus-life"] as? [String: Any],
               let articles = cl["articles"] as? [String: Any],
               let total = articles["total"] as? NSNumber {
                sceneryTotal = total.intValue
            } else {
                sceneryTotal = 0
            }

            // 合作交流条数 = 国际交流 + 继续教育（/school/cooperate 内联列表）+ 校企合作（栏目文章接口 total，权威计数）：
            // 内嵌列表仅含校企合作前 8 条——若只按内嵌计数，官网新增校企合作文章时基线不变、漏推送。
            // 任一子通道失败返回 -1：本轮跳过比对、不写坏基线。
            var cooperateTotal = -1
            if let coRoot = try? await NetworkService.shared.fetchJSONDict(path: "/school/cooperate"),
               let coData = coRoot["data"] as? [String: Any],
               let groups = coData["data"] as? [[String: Any]] {
                var inlineCount = 0
                for group in groups {
                    // 校企合作组跳过内嵌摘要列表，其权威计数走栏目文章接口
                    guard (group["title_en"] as? String) != "cooperation" else { continue }
                    if let inner = group["data"] as? [String: Any],
                       let list = inner["list"] as? [[String: Any]] {
                        inlineCount += list.count
                    }
                }
                if let coopDTO = try? await NetworkService.shared.fetchArticles(
                    columnId: "cc7376c390cb4aa4bc519c4858009630", page: 1, size: 8),
                    let coopTotal = coopDTO.articles?.total {
                    cooperateTotal = inlineCount + coopTotal
                }
            }
            guard cooperateTotal >= 0 else {
                LogManager.shared.debugLog("notification", "合作交流通道暂不可用（本轮跳过概况基线比对）", context: [:])
                return
            }

            let current = "\(leaderCount)|\(sceneryTotal)|\(cooperateTotal)"
            let previous = UserDefaults.standard.string(forKey: baselineKey)

            guard let previous, !previous.isEmpty else {
                // 首次：建立基线，不推送历史
                UserDefaults.standard.set(current, forKey: baselineKey)
                LogManager.shared.info("notification", "学校概况通知基线建立（不推送）", context: [
                    "baseline": current, "scope": "领导|风光|合作交流"
                ])
                return
            }

            let prevParts = previous.split(separator: "|").map(String.init)
            if prevParts.count < 3 {
                // 旧版两段基线：先静默升级为三段（合作交流纳入监测，不误报历史）
                let prevTwo = prevParts.count >= 2 ? "\(prevParts[0])|\(prevParts[1])" : previous
                let currTwo = "\(leaderCount)|\(sceneryTotal)"
                guard prevTwo != currTwo else {
                    UserDefaults.standard.set(current, forKey: baselineKey)
                    LogManager.shared.info("notification", "学校概况通知基线升级（合作交流纳入监测）", context: [
                        "baseline": current
                    ])
                    return
                }
                // 前两段确有变化：按旧语义推送
                UserDefaults.standard.set(current, forKey: baselineKey)
                let content = UNMutableNotificationContent()
                content.title = "学校概况 · 有新内容"
                content.body = "校领导或校园风光内容已更新，点击查看"
                content.sound = .default
                content.userInfo = [
                    "schoolProfileDeepLink": true,
                    "isTestNotification": false
                ]
                let request = UNNotificationRequest(
                    identifier: "school-profile-update",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
                if pushToSystem {
                    try await UNUserNotificationCenter.current().add(request)
                }
                MessageCenterStore.shared.ingest(
                kind: .schoolProfile,
                id: "schoolProfile-\(Int(Date().timeIntervalSince1970 * 1000))",
                title: "学校概况 · 有新内容",
                subtitle: "校领导或校园风光内容已更新，点击查看",
                deepLink: DeepLinkPayload(schoolProfile: true))
                LogManager.shared.info("notification", "学校概况检测到更新并推送（旧基线语义）", context: [
                    "previous": previous, "current": current, "silent": "\(!pushToSystem)"
                ])
                return
            }

            // 三段基线：逐段对比 + 精确变化文案
            var changedParts: [String] = []
            if prevParts[0] != "\(leaderCount)" { changedParts.append("校领导") }
            if prevParts[1] != "\(sceneryTotal)" { changedParts.append("校园风光") }
            if prevParts[2] != "\(cooperateTotal)" { changedParts.append("合作交流") }
            guard !changedParts.isEmpty else { return }
            UserDefaults.standard.set(current, forKey: baselineKey)

            let content = UNMutableNotificationContent()
            content.title = "学校概况 · 有新内容"
            content.body = "\(changedParts.joined(separator: "、"))内容已更新，点击查看"
            content.sound = .default
            content.userInfo = [
                "schoolProfileDeepLink": true,
                "isTestNotification": false
            ]
            let request = UNNotificationRequest(
                identifier: "school-profile-update",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            if pushToSystem {
                try await UNUserNotificationCenter.current().add(request)
            }
            MessageCenterStore.shared.ingest(
                kind: .schoolProfile,
                id: "schoolProfile-\(Int(Date().timeIntervalSince1970 * 1000))",
                title: "学校概况 · 有新内容",
                subtitle: "\(changedParts.joined(separator: "、"))内容已更新，点击查看",
                deepLink: DeepLinkPayload(schoolProfile: true))
            LogManager.shared.info("notification", "学校概况检测到更新并推送", context: [
                "previous": previous, "current": current,
                "changed": changedParts.joined(separator: "、"),
                "silent": "\(!pushToSystem)"
            ])
        } catch {
            LogManager.shared.debugLog("notification", "学校概况更新检测失败（不影响其他通道）", context: [
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
        }
    }

    // MARK: 党建专题更新检测（第四通道：双子站轻量指纹比对）

    /// 党建专题更新检测：/dept/home2 每站单请求递归收集指纹
    /// （文章总数 + 全站最新 3 篇签名），对比基线 partySubjectBaseline 变化即推送；
    /// 任一子站失败 → 本轮跳过（不写坏基线）；点击通知直达党建专题。
    private func checkPartySubjectUpdates(pushToSystem: Bool = true) async {
        let baselineKey = "partySubjectBaseline"
        do {
            var totals: [String] = []
            var tops: [String] = []
            for (key, _) in [("djgz", "党建工作"), ("mkszy", "思政专题")] {
                let fp = try await NetworkService.shared.fetchPartySubjectFingerprint(siteKey: key)
                totals.append("\(fp.totalArticles)")
                tops.append(fp.topSignature)
            }
            let current = "\(totals[0])|\(tops[0])|\(totals[1])|\(tops[1])"
            let previous = UserDefaults.standard.string(forKey: baselineKey)

            guard let previous, !previous.isEmpty else {
                // 首次：建立基线，不推送历史
                UserDefaults.standard.set(current, forKey: baselineKey)
                LogManager.shared.info("notification", "党建专题通知基线建立（不推送）", context: [
                    "baseline": current
                ])
                return
            }

            let prevParts = previous.split(separator: "|").map(String.init)
            guard prevParts.count == 4 else {
                // 旧基线结构不符：静默重建基线，不误报历史
                UserDefaults.standard.set(current, forKey: baselineKey)
                LogManager.shared.info("notification", "党建专题通知基线重建（结构不符静默升级）", context: [
                    "baseline": current
                ])
                return
            }
            guard previous != current else { return }

            UserDefaults.standard.set(current, forKey: baselineKey)
            var changed: [String] = []
            if prevParts[0] != totals[0] || prevParts[1] != tops[0] { changed.append("党建工作") }
            if prevParts[2] != totals[1] || prevParts[3] != tops[1] { changed.append("思政专题") }

            let content = UNMutableNotificationContent()
            content.title = "党建专题 · 有新内容"
            content.body = "\(changed.joined(separator: "、"))已更新，点击查看"
            content.sound = .default
            content.userInfo = [
                "partySubjectDeepLink": true,
                "isTestNotification": false
            ]
            let request = UNNotificationRequest(
                identifier: "party-subject-update",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            if pushToSystem {
                try await UNUserNotificationCenter.current().add(request)
            }
            MessageCenterStore.shared.ingest(
                kind: .partySubject,
                id: "partySubject-\(Int(Date().timeIntervalSince1970 * 1000))",
                title: "党建专题 · 有新内容",
                subtitle: "\(changed.joined(separator: "、"))已更新，点击查看",
                deepLink: DeepLinkPayload(partySubject: true))
            LogManager.shared.info("notification", "党建专题检测到更新并推送", context: [
                "previous": previous, "current": current,
                "changed": changed.joined(separator: "、"),
                "silent": "\(!pushToSystem)"
            ])
        } catch {
            LogManager.shared.debugLog("notification", "党建专题更新检测失败（不影响其他通道）", context: [
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
        }
    }

    // MARK: 信箱通知模拟（调试验收：Debug 面板触发，验证 横幅→点击→直达信箱页 全链路）

    /// 发送一封模拟校长信箱通知（固定标识符，多次模拟只保留最新一条，避免通知中心堆积）
    func sendMailboxSimulationNotification(message: NetworkService.MailboxMessage) async {
        guard isAuthorized else {
            LogManager.shared.warning("notification", "信箱模拟通知被拦截：通知权限未开启", context: [:])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "校长信箱 · 新回复（模拟）"
        content.body = message.showTitle
        content.sound = .default
        content.badge = nil
        content.userInfo = [
            "mailboxId": "\(message.id)",
            "mailboxTitle": message.showTitle,
            "deepLink": "principalMailbox",
            "isTestNotification": true
        ]
        // 统一标识符：同一次模拟链路的通知复投时替换旧记录
        let request = UNNotificationRequest(
            identifier: "mailbox-simulation",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1.5, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
            LogManager.shared.info("notification", "信箱模拟通知已排入系统", context: [
                "identifier": request.identifier,
                "mailboxId": "\(message.id)",
                "delay": "1.5s"
            ])
        } catch {
            LogManager.shared.warning("notification", "信箱模拟通知发送失败", context: [
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: 手动标记已通知（用于首次启用时跳过已有文章）

    func markExistingArticlesAsNotified() {
        let data = DataService.shared
        let allIds = data.allNews.compactMap { $0.articleId }
        for id in allIds {
            notifiedArticleIds.insert(id)
        }
        print("[NotificationManager] 已标记 \(allIds.count) 篇现有文章，下次只推送增量")
    }

    // MARK: UNUserNotificationCenterDelegate
    //
    // 重要：必须实现「完成回调版」delegate 方法，而非 async 版！
    // async 版（userNotificationCenter(_:didReceive:) async）由系统在任意后台协作队列上派发，
    // UIKit 的通知响应处理机制（快照/状态恢复 CATransaction 提交）会随回调在同一后台队列执行，
    // 触发 "Call must be made on main thread" 断言崩溃（点击通知闪退根因）。
    // 完成回调版由系统保证在主线程派发，配合内部 Task @MainActor 双保险。

    /// 前台收到通知时以横幅方式展示
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isTest = notification.request.content.userInfo["isTestNotification"] as? Bool ?? false
        // 立即回执展示选项；日志埋点异步切主线程，绝不阻塞系统回调
        completionHandler([.banner, .sound, .list])
        Task { @MainActor in
            LogManager.shared.debugLog("notification", "应用前台收到系统通知，展示横幅", context: [
                "identifier": notification.request.identifier,
                "isTest": "\(isTest)"
            ])
        }
    }

    /// 用户点击通知 → 立即回执完成回调，随后切主线程统一处理（广播给主界面延迟弹详情）
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        // 系统只要求调用回执，不要求等待处理完成
        completionHandler()
        Task { @MainActor in
            NotificationManager.shared.handleNotificationTap(
                userInfo: userInfo,
                actionIdentifier: actionIdentifier,
                source: "system_tap"
            )
        }
    }

    // MARK: 通知点击处理（didReceive 与测试模拟共用入口）

    /// 通知点击统一处理：记录日志 → 设置 @Published pendingDeepLink（主界面 onChange 接收后
    /// 在安全时机延迟弹出文章详情，绝不在系统回调同步链中直接弹窗 —— 这是点击通知闪退的根因修复）
    func handleNotificationTap(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String = UNNotificationDefaultActionIdentifier,
        source: String
    ) {
        let tapTimestamp = Date()

        // 学校概况更新通知：点击直达学校概况页
        if let profileFlag = userInfo["schoolProfileDeepLink"] as? Bool, profileFlag {
            LogManager.shared.info("notification", "学校概况通知点击响应", context: [
                "source": source,
                "action": actionIdentifier,
                "pipeline": "通知点击→App入口→学校概况页"
            ])
            MessageCenterStore.shared.markRead(kind: .schoolProfile)
            pendingSchoolProfileDeepLink = true
            return
        }

        // 党建专题更新通知：点击直达党建专题模块
        if let partyFlag = userInfo["partySubjectDeepLink"] as? Bool, partyFlag {
            LogManager.shared.info("notification", "党建专题通知点击响应", context: [
                "source": source,
                "action": actionIdentifier,
                "pipeline": "通知点击→App入口→党建专题模块"
            ])
            MessageCenterStore.shared.markRead(kind: .partySubject)
            pendingPartySubjectDeepLink = true
            return
        }

        // 校长信箱通知：独立通道（不携带 articleId），点击携带信件 id 直达对应信件详情
        if let mailboxId = userInfo["mailboxId"] as? String, !mailboxId.isEmpty {
            let mailboxTitle = userInfo["mailboxTitle"] as? String ?? ""
            LogManager.shared.info("notification", "校长信箱通知点击响应", context: [
                "source": source,
                "action": actionIdentifier,
                "mailboxId": mailboxId,
                "title": String(mailboxTitle.prefix(24)),
                "appState": appStateDescription,
                "tapTimestamp": String(format: "%.3f", tapTimestamp.timeIntervalSince1970),
                "pipeline": "通知点击→App入口→信件详情"
            ])
            MessageCenterStore.shared.markRead(id: "mailbox-\(mailboxId)")
            pendingMailboxDeepLink = Int(mailboxId)
            return
        }

        let articleId = userInfo["articleId"] as? String ?? ""
        let category = userInfo["articleCategory"] as? String ?? "学校要闻"
        let title = userInfo["articleTitle"] as? String ?? ""

        LogManager.shared.info("notification", "通知点击响应", context: [
            "source": source,
            "action": actionIdentifier,
            "articleId": articleId.isEmpty ? "(无)" : articleId,
            "category": category,
            "title": title.isEmpty ? "(无)" : String(title.prefix(24)),
            "appState": appStateDescription,
            "tapTimestamp": String(format: "%.3f", tapTimestamp.timeIntervalSince1970),
            "pipeline": "通知点击→App入口→DeepLink"
        ])

        // 无文章 ID 的通知（如纯送达测试通知）无法跳转详情，只记录日志
        guard !articleId.isEmpty else {
            LogManager.shared.warning("notification", "通知未携带 articleId，无法跳转文章详情", context: [
                "source": source
            ])
            return
        }

        if let isBookmark = userInfo["isBookmarkUpdate"] as? Bool, isBookmark {
            MessageCenterStore.shared.markRead(kind: .bookmarkUpdate, articleId: articleId)
        } else {
            MessageCenterStore.shared.markRead(id: "news-\(articleId)")
        }

        pendingDeepLink = PendingArticleDeepLink(
            articleId: articleId,
            category: category,
            title: title,
            source: source
        )
    }

    /// 当前应用运行状态的文字描述（日志上下文用）
    var appStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: return "前台活跃"
        case .inactive: return "非活跃过渡"
        case .background: return "后台"
        @unknown default: return "未知"
        }
    }

    // MARK: 通知测试（我的-应用设置-通知测试）

    /// 确保测试通知携带一篇真实文章：
    /// 本地已有同步文章直接取首篇；否则现场拉取官网要闻第一篇（并发 ≤2 请求），
    /// 保证任意时刻（含首次安装未同步）测试通知点击后都能跳转对应文章详情。
    private func ensureRealTestArticle() async -> NewsItem? {
        if let local = DataService.shared.allNews.first, local.articleId?.isEmpty == false {
            return local
        }
        do {
            let home = try await NetworkService.shared.fetchHome2()
            guard let colId = home.news?.children?.importants?.columnId else {
                LogManager.shared.debugLog("notificationTest", "兜底拉取无要闻栏目 ID", context: [:])
                return nil
            }
            let dto = try await NetworkService.shared.fetchArticles(columnId: colId, page: 1, size: 1)
            guard let item = dto.articles?.list?.first,
                  let id = item.id, !id.isEmpty else {
                LogManager.shared.debugLog("notificationTest", "兜底拉取要闻为空", context: ["columnId": colId])
                return nil
            }
            let fetched = NewsItem(
                title: item.resolvedTitle ?? "",
                date: item.updateTime ?? "",
                category: "学校要闻",
                summary: item.description ?? "",
                imageUrl: item.imageUrl,
                articleId: id
            )
            LogManager.shared.info("notificationTest", "测试文章兜底拉取成功", context: [
                "articleId": id, "title": String(fetched.title.prefix(24))
            ])
            return fetched
        } catch {
            LogManager.shared.warning("notificationTest", "测试文章兜底拉取失败", context: [
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
            return nil
        }
    }

    /// 发送一条系统测试通知（延迟送达，验证系统通知的编排与抵达链路）
    @discardableResult
    func sendTestNotification(delaySeconds: TimeInterval, useRealArticle: Bool, source: String) async -> NotificationTestResult {
        guard isAuthorized else {
            LogManager.shared.warning("notificationTest", "测试通知发送被拦截：通知权限未开启", context: [
                "source": source, "delay": "\(Int(delaySeconds))s"
            ])
            return .failure("通知权限未开启，请先在上方开启权限")
        }

        // 优先取一篇真实文章作为测试内容，点击后即可验证完整跳转链路（本地无数据时现场兜底拉取）
        let article = useRealArticle ? await ensureRealTestArticle() : nil
        let delay = max(delaySeconds, 1)
        let body: String
        let userInfo: [AnyHashable: Any]
        if let article, let id = article.articleId, !id.isEmpty {
            body = article.title
            userInfo = [
                "isTestNotification": true,
                "articleId": id,
                "articleCategory": article.category,
                "articleTitle": article.title
            ]
        } else {
            body = "这是一条测试通知，用于验证系统通知的编排、送达与展示链路。"
            userInfo = ["isTestNotification": true]
            if useRealArticle {
                LogManager.shared.warning("notificationTest", "测试通知退化为无文章模式（点击仅验证送达）", context: [
                    "source": source
                ])
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "园枢 · 通知测试"
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let identifier = "test-notification-\(UUID().uuidString.prefix(8))"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        LogManager.shared.info("notificationTest", "发送测试通知", context: [
            "source": source,
            "delay": "\(Int(delay))s",
            "identifier": identifier,
            "useRealArticle": "\(useRealArticle)",
            "articleId": userInfo["articleId"] as? String ?? "(无)"
        ])

        do {
            try await UNUserNotificationCenter.current().add(request)
            LogManager.shared.info("notificationTest", "测试通知已成功排队", context: [
                "identifier": identifier, "delay": "\(Int(delay))s", "source": source
            ])
            return .success("已排队，\(Int(delay)) 秒后送达")
        } catch {
            LogManager.shared.error("notificationTest", "测试通知发送失败", context: [
                "identifier": identifier, "source": source, "error": error.localizedDescription
            ])
            return .failure("发送失败：\(error.localizedDescription)")
        }
    }

    /// 模拟点击通知：与真实点击走完全相同的内部处理链路（日志 → 广播 → 主界面弹详情）。
    /// 文章来源与送达测试一致：本地同步数据优先，无数据时现场兜底拉取官网要闻。
    @discardableResult
    func simulateNotificationTap() async -> NotificationTestResult {
        guard let article = await ensureRealTestArticle() else {
            LogManager.shared.warning("notificationTest", "模拟点击失败：无法获取文章数据", context: [
                "reason": "allNews empty 且兜底拉取失败"
            ])
            return .failure("当前无法获取文章数据，请检查网络后重试")
        }
        guard let articleId = article.articleId, !articleId.isEmpty else {
            LogManager.shared.warning("notificationTest", "模拟点击失败：文章缺少 articleId", context: [
                "title": article.title
            ])
            return .failure("文章数据缺少 ID，无法模拟跳转")
        }

        LogManager.shared.info("notificationTest", "开始模拟通知点击", context: [
            "articleId": articleId, "title": String(article.title.prefix(24))
        ])
        handleNotificationTap(
            userInfo: [
                "articleId": articleId,
                "articleCategory": article.category,
                "articleTitle": article.title
            ],
            source: "test_simulate"
        )
        LogManager.shared.info("notificationTest", "模拟通知点击链路已触发", context: ["articleId": articleId])
        return .success("已触发跳转，即将打开文章详情…")
    }

    /// 设置 / 清除应用角标（双保险：UNUserNotificationCenter + UIApplication 同步设置，
    /// 修复部分 iOS 版本 setBadgeCount(0) 清除无效的问题）
    func setBadgeCount(_ count: Int) async -> NotificationTestResult {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        badgeSettingText = Self.badgeSettingDescription(settings.badgeSetting)
        if settings.badgeSetting == .disabled {
            LogManager.shared.warning("notificationTest", "角标更新被拦截：系统「标记」许可已关闭", context: [
                "target": "\(count)", "badgeSetting": badgeSettingText
            ])
            return .failure("系统「标记」已关闭，请到系统设置 → 通知 → 「园枢」中开启「标记」后再试")
        }

        do {
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        } catch {
            LogManager.shared.error("notificationTest", "应用角标更新失败", context: [
                "count": "\(count)", "error": error.localizedDescription
            ])
            return .failure("角标更新失败：\(error.localizedDescription)")
        }
        LogManager.shared.info("notificationTest", "应用角标已更新", context: [
            "target": "\(count)",
            "badgeSetting": badgeSettingText
        ])
        return .success(count == 0 ? "角标已清除" : "角标已设置为 \(count)")
    }
}