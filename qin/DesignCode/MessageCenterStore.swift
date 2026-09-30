//
//  MessageCenterStore.swift
//  山西晋中理工学院 APP — App 内消息中心（站内信）
//
//  与五通道通知系统（新闻/校长信箱/学校概况/党建专题/机构动态）及收藏更新通道联动：
//  每次成功产生系统通知时同步写入本地事件历史，用户在「我的 → 消息中心」回看全部消息，
//  点击复用 NotificationManager.handleNotificationTap 深链分发，绝不在点击同步链直接弹窗。
//
//  存储：Documents/MessageCenter/messageCenterEvents.json，变更即写；
//  损坏自愈：整体解码失败备份 .corrupt 后重建，单条损坏跳过并记 warning。
//

import Foundation
import SwiftUI
import UserNotifications

// MARK: - 消息类型

/// 消息来源通道（新增通道只需在此加一项 + 视觉映射）
enum MessageKind: String, Codable, CaseIterable {
    case news             // 新闻（要闻/资讯/党建动态/通知公告）
    case mailbox          // 校长信箱新回复
    case schoolProfile    // 学校概况更新
    case partySubject     // 党建专题更新
    case bookmarkUpdate   // 收藏文章官网更新
    case orgUpdate        // 机构动态（用户关注的机构子站更新）
}

// MARK: - 深链载荷

/// 统一的可编码深链结构：点击消息时转回 userInfo 字典，走既有 handleNotificationTap 分发
struct DeepLinkPayload: Codable, Equatable {
    var articleId: String?
    var articleCategory: String?
    var articleTitle: String?
    var mailboxId: String?
    var mailboxTitle: String?
    var schoolProfile: Bool?
    var partySubject: Bool?
    /// 收藏更新通道目的地归因（2026-09-29）：payload 自描述 + launch 侧按 kind 兜底双保险
    var isBookmarkUpdate: Bool?
    /// 机构动态通道（关注机构子站文章）：机构归因四元组（articleTitle 复用上方字段承载文章标题）
    var orgArticleId: String?
    var orgName: String?
    var orgCategory: String?
    var orgSiteId: String?

    /// 转换成 NotificationManager.handleNotificationTap 可识别的 userInfo 字典
    var asUserInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let articleId, !articleId.isEmpty {
            info["articleId"] = articleId
            info["articleCategory"] = articleCategory ?? "学校要闻"
            info["articleTitle"] = articleTitle ?? ""
        }
        if let mailboxId, !mailboxId.isEmpty {
            info["mailboxId"] = mailboxId
            info["mailboxTitle"] = mailboxTitle ?? ""
        }
        if schoolProfile == true { info["schoolProfileDeepLink"] = true }
        if partySubject == true { info["partySubjectDeepLink"] = true }
        if isBookmarkUpdate == true { info["isBookmarkUpdate"] = true }
        if let orgArticleId, !orgArticleId.isEmpty {
            info["orgArticleId"] = orgArticleId
            info["orgName"] = orgName ?? ""
            info["orgCategory"] = orgCategory ?? ""
            info["orgSiteId"] = orgSiteId ?? "1"
            info["articleTitle"] = articleTitle ?? ""
        }
        return info
    }

    var isEmpty: Bool {
        (articleId?.isEmpty ?? true)
            && (mailboxId?.isEmpty ?? true)
            && schoolProfile != true
            && partySubject != true
            && (orgArticleId?.isEmpty ?? true)
    }
}

// MARK: - 消息条目

struct MessageItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: MessageKind
    var title: String
    var subtitle: String
    let timestamp: Date
    var isRead: Bool
    let deepLink: DeepLinkPayload?
    let isTest: Bool
    var schemaVersion: Int
}

// MARK: - 容错解码（版本迁移与单条降级）

extension MessageItem {
    /// 容错解码：仅 id 必须严格；其余字段缺失/类型异常时按默认值降级，
    /// 未知 kind 降级为 .news（warning 由调用方记录）——保证旧版本数据与损坏字段不拖垮整库。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(MessageKind.self, forKey: .kind)) ?? .news
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        subtitle = (try? c.decode(String.self, forKey: .subtitle)) ?? ""
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
        isRead = (try? c.decode(Bool.self, forKey: .isRead)) ?? false
        deepLink = try? c.decodeIfPresent(DeepLinkPayload.self, forKey: .deepLink)
        isTest = (try? c.decode(Bool.self, forKey: .isTest)) ?? false
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
    }
}

// MARK: - 启动状态

/// 消息点击 → 深链投递的状态（供行内反馈与日志闭环）
enum MessageLaunchState: Equatable {
    case idle
    case launching
    case failed(String)

    var message: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

// MARK: - 消息中心 Store

@MainActor
final class MessageCenterStore: ObservableObject {

    static let shared = MessageCenterStore()

    // MARK: 持久化配置

    private let defaults: UserDefaults
    private let storageURL: URL
    private let maxCountKey = "messageCenterMaxCount"
    private let autoCheckKey = "messageCenterAutoCheck"
    private let badgeEnabledKey = "messageCenterBadgeEnabled"
    private let lastAutoCheckKey = "messageCenterLastAutoCheckTime"
    private let importDoneKey = "messageCenterImportedSystemOnce"

    /// 默认上限 200 条，超限 FIFO 截断
    var maxCount: Int {
        get {
            let v = defaults.integer(forKey: maxCountKey)
            return v > 0 ? v : 200
        }
        set {
            defaults.set(newValue, forKey: maxCountKey)
            applyMaxCountLimit()
        }
    }

    private var autoCheckEnabled: Bool {
        defaults.object(forKey: autoCheckKey) == nil
            ? true
            : defaults.bool(forKey: autoCheckKey)
    }

    private var badgeEnabled: Bool {
        defaults.object(forKey: badgeEnabledKey) == nil
            ? true
            : defaults.bool(forKey: badgeEnabledKey)
    }

    // MARK: 发布状态

    @Published private(set) var items: [MessageItem] = []
    @Published private(set) var unreadCount: Int = 0 {
        didSet {
            guard unreadCount != oldValue else { return }
            syncBadge()
        }
    }
    @Published private(set) var latestItem: MessageItem?
    @Published private(set) var launchState: MessageLaunchState = .idle
    /// 请求关闭消息中心 sheet 的信号（ProfileView onChange 消费；配合深链投递防止 sheet 叠加）
    @Published var dismissRequest: UUID?

    // MARK: 内部状态

    private var launchTask: Task<Void, Never>?
    private var badgeSyncTask: Task<Void, Never>?

    // MARK: 初始化

    /// 可注入存储目录与 UserDefaults（单测隔离用）；shared 使用默认位置
    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let dir = storageDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MessageCenter", isDirectory: true)
        self.storageURL = dir.appendingPathComponent("messageCenterEvents.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        LogManager.shared.info("messageCenter", "消息中心存储初始化完成", context: [
            "path": storageURL.lastPathComponent,
            "items": "\(items.count)",
            "unread": "\(unreadCount)"
        ])

        // 首次启动：把系统通知中心仍在架的历史通知导入（老用户升级即有历史）
        if !defaults.bool(forKey: importDoneKey) {
            defaults.set(true, forKey: importDoneKey)
            Task { @MainActor [weak self] in
                await self?.importFromDeliveredNotifications()
            }
        }
        syncBadge()
    }

    // MARK: 加载与自愈

    private func load() {
        guard let data = try? Data(contentsOf: storageURL), !data.isEmpty else {
            items = []
            recomputeUnread()
            return
        }
        let start = Date()
        // 一级：整体标准解码
        if let decoded = try? makeDecoder().decode([MessageItem].self, from: data) {
            items = decoded.sorted { $0.timestamp > $1.timestamp }
            recomputeUnread()
            finishLoad(start: start, source: "standard")
            return
        }
        // 二级：损坏自愈——原文件备份为带时间戳的 .corrupt 后逐条抢救（单条损坏跳过），
        // 保留最近 5 份现场供审计（避免固定备份名被后续损坏事件覆盖、丢失首次现场）
        let corruptURL = storageURL.deletingLastPathComponent()
            .appendingPathComponent("messageCenterEvents.corrupt-\(Self.backupTimestamp()).json")
        try? FileManager.default.copyItem(at: storageURL, to: corruptURL)
        trimCorruptBackups()
        LogManager.shared.error("messageCenter", "消息中心存储解码失败，已备份损坏文件并逐条抢救", context: [
            "fileSize": "\(data.count)",
            "backup": corruptURL.lastPathComponent,
            "elapsedMs": String(format: "%.0f", Date().timeIntervalSince(start) * 1000)
        ])
        var rescued: [MessageItem] = []
        var dropped = 0
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for (index, dict) in array.enumerated() {
                guard let itemData = try? JSONSerialization.data(withJSONObject: dict),
                      let item = try? makeDecoder().decode(MessageItem.self, from: itemData) else {
                    dropped += 1
                    LogManager.shared.warning("messageCenter", "消息中心单条数据损坏已跳过", context: [
                        "index": "\(index)"
                    ])
                    continue
                }
                rescued.append(item)
            }
        }
        items = rescued.sorted { $0.timestamp > $1.timestamp }
        recomputeUnread()
        save()
        LogManager.shared.info("messageCenter", "消息中心存储重建完成", context: [
            "rescued": "\(rescued.count)", "dropped": "\(dropped)"
        ])
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func finishLoad(start: Date, source: String) {
        LogManager.shared.debugLog("messageCenter", "消息中心已加载", context: [
            "source": source,
            "count": "\(items.count)",
            "elapsedMs": String(format: "%.1f", Date().timeIntervalSince(start) * 1000)
        ])
    }

    // MARK: 写盘

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try writeAtomically(data)
            // 写后自校验：读回解码必须成功；失败重写一次并落 warning——
            // 防御强杀/覆盖安装边界下极端竞态造成的半截落盘（2026-09-24 真机物证）
            if let saved = try? Data(contentsOf: storageURL),
               (try? makeDecoder().decode([MessageItem].self, from: saved)) == nil {
                LogManager.shared.warning("messageCenter", "消息中心写盘自校验失败，已重写", context: [
                    "bytes": "\(saved.count)"
                ])
                try writeAtomically(data)
            }
        } catch {
            LogManager.shared.error("messageCenter", "消息中心写盘失败", context: [
                "error": error.localizedDescription,
                "count": "\(items.count)"
            ])
        }
    }

    /// 强原子写盘：先写同目录临时文件，再经 replaceItem 原子替换目标
    /// （目标不存在时 moveItem；比 write(.atomic) 的隐式 rename 在容器边界场景更可控）
    private func writeAtomically(_ data: Data) throws {
        let tempURL = storageURL.deletingLastPathComponent()
            .appendingPathComponent("messageCenterEvents.json.tmp")
        try data.write(to: tempURL, options: [])
        if FileManager.default.fileExists(atPath: storageURL.path) {
            _ = try FileManager.default.replaceItemAt(storageURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: storageURL)
        }
    }

    /// 损坏备份的时间戳后缀（yyyyMMdd-HHmmss）
    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 保留最近 5 份 corrupt 现场，超出按文件名倒序清理最旧的
    private func trimCorruptBackups() {
        let dir = storageURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        let backups = files
            .filter { $0.lastPathComponent.contains("messageCenterEvents.corrupt-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(5) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: 事件写入（ingest）

    /// 通道产生通知成功后调用；isTest 一律不入盒；同 id 幂等去重
    func ingest(kind: MessageKind, id: String, title: String, subtitle: String,
                deepLink: DeepLinkPayload?, isTest: Bool = false) {
        guard !isTest else {
            LogManager.shared.debugLog("messageCenter", "测试通知不入消息中心", context: [
                "kind": kind.rawValue, "id": id
            ])
            return
        }
        guard !id.isEmpty else {
            LogManager.shared.warning("messageCenter", "ingest 收到空 id，已拒绝", context: [
                "kind": kind.rawValue
            ])
            return
        }

        if let index = items.firstIndex(where: { $0.id == id }) {
            // 同 id 已存在：仅当内容变化时更新，不新增未读
            var existing = items[index]
            let changed = existing.title != title || existing.subtitle != subtitle
            existing.title = title
            existing.subtitle = subtitle
            var deepLinkUpgraded = false
            if existing.deepLink == nil && deepLink != nil {
                deepLinkUpgraded = true
                existing = MessageItem(
                    id: existing.id, kind: existing.kind,
                    title: existing.title, subtitle: existing.subtitle,
                    timestamp: existing.timestamp, isRead: existing.isRead,
                    deepLink: deepLink, isTest: existing.isTest,
                    schemaVersion: max(existing.schemaVersion, 1))
            } else if deepLink != nil, existing.deepLink != deepLink {
                // 深链内容变化（如 articleTitle 修正）：同步刷新并落盘
                deepLinkUpgraded = true
                existing = MessageItem(
                    id: existing.id, kind: existing.kind,
                    title: existing.title, subtitle: existing.subtitle,
                    timestamp: existing.timestamp, isRead: existing.isRead,
                    deepLink: deepLink, isTest: existing.isTest,
                    schemaVersion: max(existing.schemaVersion, 1))
            }
            items[index] = existing
            latestItem = items.max(by: { $0.timestamp < $1.timestamp })
            if changed || deepLinkUpgraded { save() }
            LogManager.shared.debugLog("messageCenter", "消息已存在（去重更新）", context: [
                "id": id, "kind": kind.rawValue,
                "changed": "\(changed)", "deepLinkUpgraded": "\(deepLinkUpgraded)"
            ])
            return
        }

        let item = MessageItem(
            id: id, kind: kind, title: title, subtitle: subtitle,
            timestamp: Date(), isRead: false, deepLink: deepLink,
            isTest: false, schemaVersion: 1)
        items.append(item)
        items.sort { $0.timestamp > $1.timestamp }
        unreadCount += 1
        latestItem = items.first
        applyMaxCountLimit()
        save()
        LogManager.shared.info("messageCenter", "新消息入盒", context: [
            "id": id, "kind": kind.rawValue, "unread": "\(unreadCount)"
        ])
    }

    // MARK: FIFO 上限

    func applyMaxCountLimit() {
        guard items.count > maxCount else { return }
        let overflow = items.count - maxCount
        items = Array(items.prefix(maxCount))
        recomputeUnread()
        latestItem = items.first
        save()
        LogManager.shared.info("messageCenter", "消息中心超出上限已截断", context: [
            "evicted": "\(overflow)", "left": "\(items.count)"
        ])
    }

    // MARK: 已读管理

    /// 标记单条已读（幂等：重复调用零副作用，未读数不重复扣减）
    func markRead(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isRead else { return }
        items[index].isRead = true
        unreadCount = max(0, unreadCount - 1)
        save()
        LogManager.shared.debugLog("messageCenter", "消息已标记已读", context: ["id": id])
    }

    /// 按 kind + articleId 精确匹配最近一条未读（收藏更新通道 userInfo 无消息 id）。
    /// 精确匹配失败时保持现状（no-op）：绝不降级标记同类型其他消息，避免跨消息误标已读。
    func markRead(kind: MessageKind, articleId: String?) {
        guard let articleId, !articleId.isEmpty else { return }
        guard let index = items.firstIndex(where: {
            $0.kind == kind && $0.deepLink?.articleId == articleId && !$0.isRead
        }) else {
            LogManager.shared.debugLog("messageCenter", "按 kind+articleId 未匹配到未读消息（保持现状）", context: [
                "kind": kind.rawValue, "articleId": articleId
            ])
            return
        }
        items[index].isRead = true
        unreadCount = max(0, unreadCount - 1)
        save()
        LogManager.shared.debugLog("messageCenter", "消息已标记已读（kind+articleId 匹配）", context: [
            "kind": kind.rawValue, "articleId": articleId
        ])
    }

    /// 按 kind 标记最近一条未读（概况/党建类无单条 id）
    func markRead(kind: MessageKind) {
        guard let index = items.firstIndex(where: { $0.kind == kind && !$0.isRead }) else { return }
        items[index].isRead = true
        unreadCount = max(0, unreadCount - 1)
        save()
        LogManager.shared.debugLog("messageCenter", "消息已标记已读（kind 匹配）", context: [
            "kind": kind.rawValue
        ])
    }

    /// 标记单条未读（幂等：已未读则零副作用，未读数不重复累加）
    func markUnread(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].isRead else { return }
        items[index].isRead = false
        unreadCount += 1
        save()
        LogManager.shared.debugLog("messageCenter", "消息已标记未读", context: ["id": id])
    }

    /// 全部标记已读（单次批量写盘）
    func markAllRead() {
        let unread = items.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        let start = Date()
        for index in items.indices { items[index].isRead = true }
        unreadCount = 0
        save()
        LogManager.shared.info("messageCenter", "全部消息已标记已读", context: [
            "count": "\(unread.count)",
            "elapsedMs": String(format: "%.1f", Date().timeIntervalSince(start) * 1000)
        ])
    }

    /// 删除单条
    func delete(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasUnread = !items[index].isRead
        items.remove(at: index)
        if wasUnread { unreadCount = max(0, unreadCount - 1) }
        latestItem = items.first
        save()
        LogManager.shared.info("messageCenter", "消息已删除", context: ["id": id])
    }

    /// 清空历史（scope: all / readOnly）
    enum ClearScope { case all, readOnly }

    func clearHistory(scope: ClearScope) {
        let before = items.count
        switch scope {
        case .all:
            items.removeAll()
        case .readOnly:
            items.removeAll { $0.isRead }
        }
        recomputeUnread()
        latestItem = items.first
        save()
        LogManager.shared.info("messageCenter", "消息中心历史已清空", context: [
            "scope": scope == .all ? "all" : "readOnly",
            "removed": "\(before - items.count)"
        ])
    }

    // MARK: 计数兜底

    private func recomputeUnread() {
        unreadCount = items.filter { !$0.isRead }.count
        latestItem = items.first
    }

    // MARK: 筛选（纯函数）

    func filter(keyword: String? = nil, kind: MessageKind? = nil, unreadOnly: Bool = false) -> [MessageItem] {
        var result = items
        if let kind { result = result.filter { $0.kind == kind } }
        if unreadOnly { result = result.filter { !$0.isRead } }
        if let keyword, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            result = result.filter {
                $0.title.lowercased().contains(kw) || $0.subtitle.lowercased().contains(kw)
            }
        }
        return result
    }

    func unreadCount(of kind: MessageKind) -> Int {
        items.filter { $0.kind == kind && !$0.isRead }.count
    }

    // MARK: 视觉映射（新增通道只需在此加一项）

    static func style(for kind: MessageKind) -> (icon: String, color: Color) {
        switch kind {
        case .news: return ("newspaper.fill", .sjzAccent)
        case .mailbox: return ("envelope.open.fill", .sjzOrange)
        case .schoolProfile: return ("graduationcap.fill", .sjzPurple)
        case .partySubject: return ("flag.fill", .red)
        case .bookmarkUpdate: return ("bookmark.fill", .sjzGold)
        case .orgUpdate: return ("building.2.fill", .sjzTeal)
        }
    }

    static func kindName(_ kind: MessageKind) -> String {
        switch kind {
        case .news: return "新闻资讯"
        case .mailbox: return "校长信箱"
        case .schoolProfile: return "学校概况"
        case .partySubject: return "党建专题"
        case .bookmarkUpdate: return "收藏更新"
        case .orgUpdate: return "机构动态"
        }
    }

    // MARK: 静默检测（站内信语义：独立于系统通知开关）

    /// 手动触发（下拉刷新/立即检查按钮）：五通道检测并仅入盒、不推系统通知（机构动态无关注时零请求）
    func silentCheckNow() async {
        LogManager.shared.info("messageCenter", "静默检测启动（仅入盒不推送）", context: [:])
        await NotificationManager.shared.checkForUpdates(pushToSystem: false)
    }

    /// 前台激活节流检查（30 分钟一次；与通知轮询撞车时 checkForUpdates 内部自守卫）
    func handleSceneActive() {
        guard autoCheckEnabled else { return }
        let now = Date()
        if let last = defaults.object(forKey: lastAutoCheckKey) as? TimeInterval {
            let elapsed = now.timeIntervalSince1970 - last
            guard elapsed > 30 * 60 else {
                LogManager.shared.debugLog("messageCenter", "自动站内检查节流跳过", context: [
                    "elapsedMin": String(format: "%.0f", elapsed / 60)
                ])
                return
            }
        }
        defaults.set(now.timeIntervalSince1970, forKey: lastAutoCheckKey)
        LogManager.shared.debugLog("messageCenter", "前台自动站内检查触发", context: [
            "interval": "30min"
        ])
        Task { @MainActor [weak self] in
            await self?.silentCheckNow()
        }
    }

    /// 自动检查开关
    func setAutoCheck(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoCheckKey)
        LogManager.shared.info("messageCenter", "自动站内检查开关变更", context: [
            "enabled": "\(enabled)"
        ])
    }

    var isAutoCheckEnabled: Bool { autoCheckEnabled }

    /// 角标联动开关
    func setBadgeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: badgeEnabledKey)
        LogManager.shared.info("messageCenter", "角标联动开关变更", context: ["enabled": "\(enabled)"])
        if enabled {
            syncBadge()
        } else {
            // 关闭联动时清除桌面残留角标数字，避免与开关状态不一致
            Task { @MainActor in
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
                LogManager.shared.debugLog("messageCenter", "角标联动已关闭，桌面角标已清零", context: [:])
            }
        }
    }

    var isBadgeEnabled: Bool { badgeEnabled }

    // MARK: 角标同步

    private func syncBadge() {
        badgeSyncTask?.cancel()
        badgeSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.badgeEnabled else {
                LogManager.shared.debugLog("messageCenter", "角标联动已关闭，跳过同步", context: [:])
                return
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.badgeSetting == .enabled else {
                LogManager.shared.debugLog("messageCenter", "系统角标权限不可用，静默跳过", context: [
                    "badgeSetting": "\(settings.badgeSetting.rawValue)"
                ])
                return
            }
            try? await UNUserNotificationCenter.current().setBadgeCount(self.unreadCount)
            LogManager.shared.debugLog("messageCenter", "桌面角标已同步", context: [
                "unread": "\(self.unreadCount)"
            ])
        }
    }

    // MARK: 深链投递

    /// 投递 userInfo 归因（纯函数，测试共用）：收藏更新通道的 payload 只携带 articleId，
    /// 目的地 kind 按消息自身补齐——否则 handleNotificationTap 会按 news-{articleId} 走新闻通道标已读，
    /// 收藏更新条目无法命中（系统通知路径由 BookmarkManager 手工塞入同键；本兜底同时修复历史已落盘消息）。
    static func deliveryUserInfo(for item: MessageItem) -> [AnyHashable: Any] {
        var info = item.deepLink?.asUserInfo ?? [:]
        if item.kind == .bookmarkUpdate {
            info["isBookmarkUpdate"] = true
        }
        return info
    }

    /// 点击消息统一入口：先请求关闭消息中心（让出 sheet 动画），再走既有通知深链分发
    func launch(item: MessageItem) {
        launchTask?.cancel()
        launchState = .launching
        guard let deepLink = item.deepLink, !deepLink.isEmpty else {
            launchState = .failed("无法定位内容")
            LogManager.shared.warning("messageCenter", "消息无深链载荷，无法跳转", context: [
                "id": item.id, "kind": item.kind.rawValue
            ])
            return
        }
        let userInfo = Self.deliveryUserInfo(for: item)
        LogManager.shared.info("messageCenter", "消息点击 → 深链投递", context: [
            "id": item.id,
            "kind": item.kind.rawValue,
            "target": deepLinkTargetDescription(deepLink),
            "pipeline": "消息中心→关闭Sheet→通知深链分发"
        ])
        dismissRequest = UUID()
        launchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            NotificationManager.shared.handleNotificationTap(
                userInfo: userInfo,
                source: "message_center"
            )
            self.launchState = .idle
        }
    }

    private func deepLinkTargetDescription(_ payload: DeepLinkPayload) -> String {
        if payload.orgArticleId?.isEmpty == false { return "orgArticle(\(payload.orgArticleId!))" }
        if payload.articleId?.isEmpty == false { return "article(\(payload.articleId!))" }
        if payload.mailboxId?.isEmpty == false { return "mailbox(\(payload.mailboxId!))" }
        if payload.schoolProfile == true { return "schoolProfile" }
        if payload.partySubject == true { return "partySubject" }
        return "unknown"
    }

    // MARK: 诊断快照（消息中心页长按标题 5 次 → 修复面板展示）

    /// 存储路径 / 条目数 / 未读数 / 上限 / schema 版本 等诊断信息
    var debugSnapshot: String {
        let versions = Set(items.map(\.schemaVersion)).sorted().map(String.init).joined(separator: ",")
        return """
        存储路径：\(storageURL.path)
        条目总数：\(items.count)
        未读数量：\(unreadCount)
        上限条数：\(maxCount)
        schema 版本：\(versions.isEmpty ? "无数据" : versions)
        自动检查：\(autoCheckEnabled ? "开启" : "关闭")
        角标联动：\(badgeEnabled ? "开启" : "关闭")
        """
    }

    /// 修复面板触发的快速修复：当前内存态原子重写 + 立即回读校验
    func repairRewrite() -> Bool {
        let start = Date()
        save()
        guard let data = try? Data(contentsOf: storageURL),
              (try? makeDecoder().decode([MessageItem].self, from: data)) != nil else {
            LogManager.shared.error("messageCenter", "快速修复：重写后回读校验失败", context: [:])
            return false
        }
        LogManager.shared.warning("messageCenter", "消息中心快速修复完成（重写+回读校验）", context: [
            "count": "\(items.count)",
            "elapsedMs": String(format: "%.1f", Date().timeIntervalSince(start) * 1000)
        ])
        return true
    }

    // MARK: 系统通知历史导入（升级即有历史）

    /// 首次启动：把系统通知中心仍在架的通知导入为消息（isTest 排除、id 去重）
    private func importFromDeliveredNotifications() async {
        let center = UNUserNotificationCenter.current()
        let delivered: [UNNotification] = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
        guard !delivered.isEmpty else { return }
        var imported = 0
        for notification in delivered {
            let info = notification.request.content.userInfo
            if let isTest = info["isTestNotification"] as? Bool, isTest { continue }
            guard
                let kind = Self.kind(from: info),
                let converted = Self.convert(info: info, kind: kind, notification: notification)
            else { continue }
            if items.contains(where: { $0.id == converted.id }) { continue }
            items.append(converted)
            imported += 1
        }
        guard imported > 0 else { return }
        items.sort { $0.timestamp > $1.timestamp }
        recomputeUnread()
        applyMaxCountLimit()
        save()
        LogManager.shared.info("messageCenter", "系统通知历史导入完成", context: [
            "imported": "\(imported)", "delivered": "\(delivered.count)"
        ])
    }

    /// 从 userInfo 推断通道类型
    private static func kind(from info: [AnyHashable: Any]) -> MessageKind? {
        if info["mailboxId"] as? String != nil ||
            (info["deepLink"] as? String) == "principalMailbox" { return .mailbox }
        if info["schoolProfileDeepLink"] as? Bool == true { return .schoolProfile }
        if info["partySubjectDeepLink"] as? Bool == true { return .partySubject }
        if info["isBookmarkUpdate"] as? Bool == true { return .bookmarkUpdate }
        // 机构动态先于新闻判定：该通道同样携带 articleTitle，必须靠 orgArticleId 区分
        if info["orgArticleId"] as? String != nil { return .orgUpdate }
        if info["articleId"] as? String != nil { return .news }
        return nil
    }

    /// userInfo → MessageItem。导入语义：仍在系统通知中心 = 用户尚未处理；
    /// 24 小时内的一律记为未读（升级当天新消息正确点亮），更早的按已读归档避免历史轰炸。
    private static func convert(info: [AnyHashable: Any], kind: MessageKind,
                                notification: UNNotification) -> MessageItem? {
        let content = notification.request.content
        let importedUnread = Date().timeIntervalSince(notification.date) <= 86400
        switch kind {
        case .news, .bookmarkUpdate:
            let articleId = info["articleId"] as? String ?? ""
            guard !articleId.isEmpty else { return nil }
            let payload = DeepLinkPayload(
                articleId: articleId,
                articleCategory: info["articleCategory"] as? String ?? "学校要闻",
                articleTitle: info["articleTitle"] as? String ?? "")
            return MessageItem(
                id: "\(notification.request.identifier)", kind: kind,
                title: content.title, subtitle: content.body,
                timestamp: notification.date,
                isRead: !importedUnread, deepLink: payload, isTest: false, schemaVersion: 1)
        case .mailbox:
            let mailboxId = info["mailboxId"] as? String ?? ""
            guard !mailboxId.isEmpty else { return nil }
            return MessageItem(
                id: "\(notification.request.identifier)", kind: kind,
                title: content.title, subtitle: content.body,
                timestamp: notification.date, isRead: !importedUnread,
                deepLink: DeepLinkPayload(
                    mailboxId: mailboxId,
                    mailboxTitle: info["mailboxTitle"] as? String ?? ""),
                isTest: false, schemaVersion: 1)
        case .schoolProfile:
            return MessageItem(
                id: "\(notification.request.identifier)", kind: kind,
                title: content.title, subtitle: content.body,
                timestamp: notification.date, isRead: !importedUnread,
                deepLink: DeepLinkPayload(schoolProfile: true),
                isTest: false, schemaVersion: 1)
        case .partySubject:
            return MessageItem(
                id: "\(notification.request.identifier)", kind: kind,
                title: content.title, subtitle: content.body,
                timestamp: notification.date, isRead: !importedUnread,
                deepLink: DeepLinkPayload(partySubject: true),
                isTest: false, schemaVersion: 1)
        case .orgUpdate:
            let orgArticleId = info["orgArticleId"] as? String ?? ""
            guard !orgArticleId.isEmpty else { return nil }
            return MessageItem(
                id: "\(notification.request.identifier)", kind: kind,
                title: content.title, subtitle: content.body,
                timestamp: notification.date, isRead: !importedUnread,
                deepLink: DeepLinkPayload(
                    articleTitle: info["articleTitle"] as? String ?? "",
                    orgArticleId: orgArticleId,
                    orgName: info["orgName"] as? String ?? "",
                    orgCategory: info["orgCategory"] as? String ?? "",
                    orgSiteId: info["orgSiteId"] as? String ?? "1"),
                isTest: false, schemaVersion: 1)
        }
    }
}

// MARK: - 时间显示工具

/// 消息相对时间与日分组（今天 / 昨天 / 更早）
enum MessageTimeText {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }  // 含时钟偏差导致的负值：未来时间戳不外显为负数
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400, Calendar.current.isDate(date, inSameDayAs: now) {
            return "\(Int(seconds / 3600)) 小时前"
        }
        let formatter = DateFormatter()
        if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "昨天 \(formatter.string(from: date))"
        }
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    enum DayGroup: String, CaseIterable {
        case today = "今天", yesterday = "昨天", earlier = "更早"

        static func group(for date: Date) -> DayGroup {
            if Calendar.current.isDateInToday(date) { return .today }
            if Calendar.current.isDateInYesterday(date) { return .yesterday }
            return .earlier
        }
    }
}