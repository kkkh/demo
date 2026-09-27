//
//  HomeModuleManager.swift
//  DesignCode
//
//  首页模块管理：控制首页各内容区块的显示/隐藏与排列顺序，配置持久化到 UserDefaults。
//

import SwiftUI

// MARK: - 首页模块定义

/// 首页可自定义的内容模块。
/// 固定区块（顶部 Banner、数据统计、快捷入口）属于品牌与导航核心，不参与管理。
enum HomeModule: String, CaseIterable, Identifiable, Hashable {
    case importantNews     // 学校要闻
    case honors            // 校园荣誉
    case notices           // 通知公告
    case helpGuide         // 使用帮助（原「招生信息」模块升级改造：招生内容保留在资讯 Tab 招生分类）
    case teacherProfiles   // 教师风采
    case videos            // 映像校园
    case studentStories    // 学生故事
    case campusActivities  // 校园活动
    case timeline          // 发展历程
    case principalMailbox  // 校长信箱
    case partySubject      // 党建专题
    case schoolProfile     // 学校概况

    var id: String { rawValue }
}

extension HomeModule {
    /// 模块显示名称
    var title: String {
        switch self {
        case .importantNews:    return "学校要闻"
        case .honors:           return "校园荣誉"
        case .notices:          return "通知公告"
        case .helpGuide: return "使用帮助"
        case .teacherProfiles:  return "教师风采"
        case .videos:           return "映像校园"
        case .studentStories:   return "学生故事"
        case .campusActivities: return "校园活动"
        case .timeline:         return "发展历程"
        case .principalMailbox: return "校长信箱"
        case .partySubject:     return "党建专题"
        case .schoolProfile:    return "学校概况"
        }
    }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .importantNews:    return "megaphone.fill"
        case .honors:           return "trophy.fill"
        case .notices:          return "bell.badge.fill"
        case .helpGuide: return "questionmark.circle.fill"
        case .teacherProfiles:  return "person.text.rectangle.fill"
        case .videos:           return "play.rectangle.fill"
        case .studentStories:   return "person.2.fill"
        case .campusActivities: return "party.popper.fill"
        case .timeline:         return "clock.arrow.2.circlepath"
        case .principalMailbox: return "envelope.open.fill"
        case .partySubject:     return "flag.fill"
        case .schoolProfile:    return "building.columns.fill"
        }
    }

    /// 模块主题色（与首页原标题栏颜色保持一致）
    var color: Color {
        switch self {
        case .importantNews:    return Color.sjzRed
        case .honors:           return Color.sjzGold
        case .notices:          return Color.sjzOrange
        case .helpGuide: return Color.sjzAccent
        case .teacherProfiles:  return Color.sjzIndigo
        case .videos:           return Color.sjzAccent
        case .studentStories:   return Color.sjzPurple
        case .campusActivities: return Color.sjzPink
        case .timeline:         return Color.sjzPrimary
        case .principalMailbox: return Color.sjzTeal
        case .partySubject:     return Color(hex: "C8102E")
        case .schoolProfile:    return Color.sjzPrimary
        }
    }

    /// 当前数据量（实时读取共享数据源，需在主线程访问）
    @MainActor
    var dataCount: Int {
        let data = DataService.shared
        switch self {
        case .importantNews:    return data.importantNews.count
        case .honors:           return data.honors.count
        case .notices:          return data.notices.count
        case .helpGuide: return HelpGuideStore.shared.totalArticles
        case .teacherProfiles:  return data.teacherProfiles.count
        case .videos:           return data.videos.count
        case .studentStories:   return data.studentStories.count
        case .campusActivities: return data.campusActivities.count
        case .timeline:         return data.timeline.count
        case .principalMailbox: return PrincipalMailboxStore.shared.total
        case .partySubject:     return PartySubjectStore.shared.totalArticles
        case .schoolProfile:    return SchoolProfileStore.shared.allEntries.count
        }
    }

    /// 数据量单位
    var countUnit: String {
        switch self {
        case .importantNews, .notices: return "条"
        case .helpGuide: return "篇"
        case .principalMailbox: return "封"
        case .partySubject: return "篇"
        case .schoolProfile: return "项"
        default: return "个"
        }
    }
}

// MARK: - 首页模块管理器

/// 首页模块管理器：单例，负责模块显示状态与顺序的发布与持久化。
/// @MainActor：全部状态与日志在主线程访问（HomeModuleManager 的日志接入 LogManager 需主线程上下文）。
@MainActor
final class HomeModuleManager: ObservableObject {
    static let shared = HomeModuleManager()

    private static let orderKey = "homeModuleOrder"
    private static let hiddenKey = "homeModuleHidden"

    /// 已退役下线的模块 rawValue（2026-09-24：合作交流/校园风光数据源中断，内容并入「学校概况」模块）：
    /// 历史存储中的这些值在加载时自动清理（info 日志），区别于普通非法值（warning 日志）
    static let retiredRawValues: Set<String> = ["campusSceneries", "bottomBanners"]

    /// 模块排列顺序（包含隐藏模块，反映用户自定义的完整顺序）
    @Published private(set) var moduleOrder: [HomeModule]

    /// 隐藏的模块集合
    @Published private(set) var hiddenModules: Set<HomeModule>

    private init() {
        let defaults = UserDefaults.standard

        // 顺序：数据缺失或损坏时回退默认；未来可能新增的模块自动补到末尾
        var order: [HomeModule] = []
        var migratedAdmissionNews = 0
        var droppedInvalidCount = 0
        var droppedDuplicateCount = 0
        if let stored = defaults.stringArray(forKey: Self.orderKey) {
            // 旧值迁移：兼容历史版本存储的 "admissionNews"（现更名为使用帮助），
            // 读取时静默替换，保证用户自定义的模块顺序与可见性不丢失
            let migrated = stored.map { raw -> String in
                if raw == "admissionNews" {
                    migratedAdmissionNews += 1
                    return "helpGuide"
                }
                return raw
            }
            let parsed = migrated.compactMap(HomeModule.init(rawValue:))
            droppedInvalidCount = migrated.count - parsed.count
            order = parsed
            // 日志：非法值详情（保留非法的原始字符串供排查）
            let invalidRaws = migrated.filter { HomeModule(rawValue: $0) == nil }
            let retiredRaws = invalidRaws.filter { Self.retiredRawValues.contains($0) }
            let trulyInvalid = invalidRaws.filter { !Self.retiredRawValues.contains($0) }
            if !retiredRaws.isEmpty {
                LogManager.shared.info("home_modules", "首页模块退役值自动清理", context: [
                    "retiredValues": retiredRaws.joined(separator: ",")
                ])
            }
            if !trulyInvalid.isEmpty {
                LogManager.shared.warning("home_modules", "首页模块配置含非法条目（已忽略）", context: [
                    "invalidValues": trulyInvalid.joined(separator: ",")
                ])
            }
            if migratedAdmissionNews > 0 {
                // 立即落盘迁移结果：避免每次启动重复迁移、重复记录迁移日志
                defaults.set(migrated, forKey: Self.orderKey)
                LogManager.shared.info("home_modules", "首页模块旧值迁移", context: [
                    "from": "admissionNews",
                    "to": "helpGuide",
                    "count": "\(migratedAdmissionNews)",
                    "persisted": "true"
                ])
            }
        }
        // 去重（保持首次出现顺序，历史存储可能含重复 rawValue）并过滤非法值
        var seen = Set<String>()
        let deduped = order.filter { raw in
            if seen.contains(raw.rawValue) { return false }
            seen.insert(raw.rawValue)
            return true
        }
        droppedDuplicateCount = order.count - deduped.count
        if droppedDuplicateCount > 0 {
            LogManager.shared.warning("home_modules", "首页模块配置含重复条目（保留首次出现）", context: [
                "droppedCount": "\(droppedDuplicateCount)"
            ])
        }
        order = deduped
        var appendedNewModules = 0
        for module in HomeModule.allCases where !order.contains(module) {
            order.append(module)
            appendedNewModules += 1
        }
        moduleOrder = order

        // 隐藏集合：非法值直接忽略，保证状态永远有效；
        // 与顺序键一致做旧值迁移：曾隐藏「招生信息」的用户升级后仍应保持隐藏「使用帮助」
        var hidden: Set<HomeModule> = []
        var hiddenInvalidCount = 0
        var hiddenMigrationCount = 0
        if let stored = defaults.stringArray(forKey: Self.hiddenKey) {
            let migrated = stored.map { raw -> String in
                if raw == "admissionNews" {
                    hiddenMigrationCount += 1
                    return "helpGuide"
                }
                return raw
            }
            let parsed = Set(migrated.compactMap(HomeModule.init(rawValue:)))
            // droppedCount 含非法 + 重复两类（Set 去重语义）
            hiddenInvalidCount = stored.count - parsed.count
            hidden = parsed
            if hiddenInvalidCount > 0 {
                let invalidRaws = migrated.filter { HomeModule(rawValue: $0) == nil }
                let retiredRaws = invalidRaws.filter { Self.retiredRawValues.contains($0) }
                let trulyInvalid = invalidRaws.filter { !Self.retiredRawValues.contains($0) }
                if !retiredRaws.isEmpty {
                    LogManager.shared.info("home_modules", "首页隐藏集合退役值自动清理", context: [
                        "retiredValues": retiredRaws.joined(separator: ",")
                    ])
                }
                if !trulyInvalid.isEmpty {
                    LogManager.shared.warning("home_modules", "首页隐藏集合含非法条目（已忽略）", context: [
                        "droppedCount": "\(hiddenInvalidCount)",
                        "invalidValues": trulyInvalid.joined(separator: ",")
                    ])
                }
            }
            if hiddenMigrationCount > 0 {
                // 立即落盘迁移结果：避免每次启动重复迁移、重复记录迁移日志
                defaults.set(parsed.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
                LogManager.shared.info("home_modules", "首页隐藏集合旧值迁移", context: [
                    "from": "admissionNews",
                    "to": "helpGuide",
                    "count": "\(hiddenMigrationCount)",
                    "persisted": "true"
                ])
            }
        }
        hiddenModules = hidden

        // 完整加载摘要：顺序 / 可见数 / 迁移与清理统计 / 是否默认状态
        LogManager.shared.info("home_modules", "首页模块配置加载完成", context: [
            "order": moduleOrder.map(\.rawValue).joined(separator: ","),
            "visibleCount": "\(visibleOrderedModules.count)",
            "hiddenCount": "\(hiddenModules.count)",
            "isDefault": "\(isDefault)",
            "migratedAdmissionNews": "\(migratedAdmissionNews)",
            "droppedInvalid": "\(droppedInvalidCount)",
            "droppedDuplicate": "\(droppedDuplicateCount)",
            "appendedNewModules": "\(appendedNewModules)"
        ])
    }

    // MARK: - 查询

    /// 模块是否在首页显示
    func isVisible(_ module: HomeModule) -> Bool {
        !hiddenModules.contains(module)
    }

    /// 首页实际渲染的模块列表（按用户顺序 + 过滤隐藏）
    var visibleOrderedModules: [HomeModule] {
        moduleOrder.filter { !hiddenModules.contains($0) }
    }

    /// 是否处于默认状态（默认顺序且全部显示）
    var isDefault: Bool {
        moduleOrder == HomeModule.allCases && hiddenModules.isEmpty
    }

    // MARK: - 修改

    /// 设置模块显示/隐藏（幂等：状态未变化时不落盘并记录 debug 日志）
    func setVisible(_ module: HomeModule, _ visible: Bool) {
        let wasVisible = isVisible(module)
        let changed: Bool
        if visible {
            changed = hiddenModules.remove(module) != nil
        } else {
            changed = hiddenModules.insert(module).inserted
        }
        if changed {
            persistHidden()
            LogManager.shared.info("home_modules", "首页模块显示切换", context: [
                "module": module.rawValue,
                "title": module.title,
                "action": visible ? "显示" : "隐藏",
                "wasVisible": "\(wasVisible)",
                "newVisibleCount": "\(visibleOrderedModules.count)",
                "newHiddenCount": "\(hiddenModules.count)"
            ])
        } else {
            LogManager.shared.debugLog("home_modules", "首页模块显示切换（状态无变化，忽略）", context: [
                "module": module.rawValue,
                "action": visible ? "显示" : "隐藏"
            ])
        }
    }

    /// 拖拽排序（List onMove 语义；记录移动前后的完整顺序对比）
    func moveModules(from source: IndexSet, to destination: Int) {
        let before = moduleOrder.map(\.rawValue).joined(separator: ",")
        moduleOrder.move(fromOffsets: source, toOffset: destination)
        persistOrder()
        LogManager.shared.info("home_modules", "首页模块排序调整", context: [
            "orderBefore": before,
            "orderAfter": moduleOrder.map(\.rawValue).joined(separator: ",")
        ])
    }

    /// 恢复默认：默认顺序 + 全部显示（记录恢复前快照）
    func resetToDefaults() {
        let orderBefore = moduleOrder.map(\.rawValue).joined(separator: ",")
        let hiddenBefore = hiddenModules.map(\.rawValue).sorted().joined(separator: ",")
        moduleOrder = HomeModule.allCases
        hiddenModules = []
        persistOrder()
        persistHidden()
        LogManager.shared.info("home_modules", "首页模块恢复默认设置", context: [
            "orderBefore": orderBefore,
            "hiddenBefore": hiddenBefore,
            "isDefaultNow": "\(isDefault)"
        ])
    }

    // MARK: - 持久化

    private func persistOrder() {
        let raw = moduleOrder.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.orderKey)
        LogManager.shared.debugLog("home_modules", "首页模块顺序落盘", context: [
            "key": Self.orderKey,
            "order": raw.joined(separator: ",")
        ])
    }

    private func persistHidden() {
        let raw = hiddenModules.map(\.rawValue).sorted()
        UserDefaults.standard.set(raw, forKey: Self.hiddenKey)
        LogManager.shared.debugLog("home_modules", "首页模块隐藏集合落盘", context: [
            "key": Self.hiddenKey,
            "hidden": raw.joined(separator: ",")
        ])
    }
}