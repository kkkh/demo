//
//  OrganizationManager.swift
//  山西晋中理工学院 APP — 机构设置模块
//
//  管理学校完整组织架构数据：
//  - 静态数据作为基础（党委/群团/行政/教学/教辅）
//  - head API 菜单动态更新 site_key
//  - 解析机构页面 HTML 作为数据校验
//  - 本地缓存 + 30 分钟定时刷新
//  - 完全独立模块，不侵入现有资讯、收藏、图片缓存逻辑
//

import Foundation
import SwiftUI
import Combine

// MARK: - 机构分类

enum OrganizationCategory: String, CaseIterable, Identifiable, Codable {
    case partyCommittee  = "党委机构"
    case massOrg         = "群团机构"
    case administrative  = "行政机构"
    case teaching        = "教学机构"
    case support         = "教辅机构"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .partyCommittee: return "flag"
        case .massOrg:        return "person.3"
        case .administrative: return "building.2"
        case .teaching:       return "graduationcap"
        case .support:        return "books.vertical"
        }
    }

    var color: Color {
        OrgTheme.categoryColor(self)
    }

    var sortOrder: Int {
        switch self {
        case .partyCommittee: return 0
        case .massOrg:        return 1
        case .administrative: return 2
        case .teaching:       return 3
        case .support:        return 4
        }
    }
}

// MARK: - 机构单元

struct OrganizationUnit: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let category: OrganizationCategory
    var siteKey: String?
    var icon: String

    /// 是否有可点击的部门页面
    var hasDetailPage: Bool { siteKey != nil }

    /// 构造部门页面 URL
    var detailURL: URL? {
        guard let key = siteKey else { return nil }
        return URL(string: "https://www.sxjzit.edu.cn/#/departments/page?site_key=\(key)")
    }

    init(name: String, category: OrganizationCategory, siteKey: String?, icon: String) {
        self.id = "\(category.rawValue)_\(name)"
        self.name = name
        self.category = category
        self.siteKey = siteKey
        self.icon = icon
    }

    /// 更新 siteKey（从 API 菜单动态获取）
    mutating func updateSiteKey(_ key: String?) {
        self.siteKey = key
    }
}

// MARK: - 机构缓存模型

struct OrganizationCache: Codable {
    let departments: [OrganizationUnit]
    let fetchTime: Date
    let dataSource: String
}

// MARK: - 机构管理器

@MainActor
final class OrganizationManager: ObservableObject {
    static let shared = OrganizationManager()

    // MARK: 发布状态

    /// 机构列表
    @Published var departments: [OrganizationUnit] = []
    /// 是否正在加载
    @Published var isLoading = false
    /// 最近一次成功拉取时间
    @Published var lastFetchTime: Date?
    /// 数据来源描述
    @Published var dataSource: String = "预置数据"
    /// 错误信息
    @Published var errorMessage: String?

    // MARK: 常量

    private let cacheKey = "organizationCache"
    private let refreshInterval: TimeInterval = 1800  // 30 分钟
    private let targetURL = "https://www.sxjzit.edu.cn/#/departments/list"

    // MARK: 私有

    private var refreshTimer: Timer?
    /// 缓存模式变更监听（F5：暂停/恢复定时刷新）
    private var modeObserver: AnyCancellable?
    private let urlSession: URLSession
    /// 防并发：当前正在执行的同步任务
    private var syncTask: Task<Void, Never>?

    // MARK: 静态基础数据

    /// 完整机构设置静态数据，来源于学校官网
    private let staticData: [OrganizationUnit] = [
        // MARK: 党委机构
        OrganizationUnit(name: "党委办公室", category: .partyCommittee, siteKey: "dzbgs", icon: "building.columns.fill"),
        OrganizationUnit(name: "党委组织部", category: .partyCommittee, siteKey: nil, icon: "person.2.badge.gearshape.fill"),
        OrganizationUnit(name: "党委宣传部", category: .partyCommittee, siteKey: nil, icon: "megaphone.fill"),
        OrganizationUnit(name: "党委统战部", category: .partyCommittee, siteKey: nil, icon: "hand.raised.fill"),
        OrganizationUnit(name: "纪检监察办公室", category: .partyCommittee, siteKey: nil, icon: "shield.checkered"),
        OrganizationUnit(name: "党委教师工作部", category: .partyCommittee, siteKey: nil, icon: "person.text.rectangle.fill"),
        OrganizationUnit(name: "党委学生工作部（武装部）", category: .partyCommittee, siteKey: "dwxsgzb", icon: "studentdesk"),
        OrganizationUnit(name: "思想政治教育工作部", category: .partyCommittee, siteKey: "mkszy", icon: "lightbulb.fill"),

        // MARK: 群团机构
        OrganizationUnit(name: "团委", category: .massOrg, siteKey: "tw", icon: "flag.2.crossed.fill"),
        OrganizationUnit(name: "工会", category: .massOrg, siteKey: nil, icon: "heart.fill"),
        OrganizationUnit(name: "妇联", category: .massOrg, siteKey: nil, icon: "figure.2.arms.open"),
        OrganizationUnit(name: "科协", category: .massOrg, siteKey: nil, icon: "flask.fill"),
        OrganizationUnit(name: "关心下一代工作委员会", category: .massOrg, siteKey: nil, icon: "figure.2.and.child.holdinghands"),

        // MARK: 行政机构
        OrganizationUnit(name: "校长办公室", category: .administrative, siteKey: "dzbgs", icon: "crown.fill"),
        OrganizationUnit(name: "人力资源处", category: .administrative, siteKey: "rlzyc", icon: "person.badge.key.fill"),
        OrganizationUnit(name: "财务与资产管理处", category: .administrative, siteKey: "cwc", icon: "yensign.circle.fill"),
        OrganizationUnit(name: "教务处", category: .administrative, siteKey: "jwc", icon: "book.pages.fill"),
        OrganizationUnit(name: "学生工作处", category: .administrative, siteKey: "dwxsgzb", icon: "person.2.badge.gearshape.fill"),
        OrganizationUnit(name: "招生就业处", category: .administrative, siteKey: "zsw", icon: "doc.text.magnifyingglass"),
        OrganizationUnit(name: "后勤管理处", category: .administrative, siteKey: "hqglc", icon: "wrench.and.screwdriver.fill"),
        OrganizationUnit(name: "科研处", category: .administrative, siteKey: "kyc", icon: "atom"),
        OrganizationUnit(name: "保卫处", category: .administrative, siteKey: "dwbwb", icon: "shield.checkered"),

        // MARK: 教学机构
        OrganizationUnit(name: "信创与大数据学院", category: .teaching, siteKey: "xcdsj", icon: "cpu.fill"),
        OrganizationUnit(name: "智能制造与车辆学院", category: .teaching, siteKey: "znzzcl", icon: "gearshape.2.fill"),
        OrganizationUnit(name: "商学院", category: .teaching, siteKey: "sxy", icon: "chart.bar.fill"),
        OrganizationUnit(name: "材料与环境学院", category: .teaching, siteKey: "clhj", icon: "leaf.fill"),
        OrganizationUnit(name: "文法学院", category: .teaching, siteKey: "wfxy", icon: "text.book.closed.fill"),
        OrganizationUnit(name: "艺术学院", category: .teaching, siteKey: "ysxy", icon: "paintpalette.fill"),
        OrganizationUnit(name: "马克思主义学院", category: .teaching, siteKey: "mkszy", icon: "book.fill"),
        OrganizationUnit(name: "通识教育学院", category: .teaching, siteKey: "tsxuey", icon: "globe.desk.fill"),
        OrganizationUnit(name: "国际交流与继续教育学院", category: .teaching, siteKey: "gjjljxjy", icon: "globe.asia.australia.fill"),
        OrganizationUnit(name: "创新创业学院", category: .teaching, siteKey: "scxy", icon: "lightbulb.max.fill"),

        // MARK: 教辅机构
        OrganizationUnit(name: "图书馆", category: .support, siteKey: "tsg", icon: "books.vertical.fill"),
        OrganizationUnit(name: "实践教学管理中心", category: .support, siteKey: "sjjxglzx", icon: "hammer.fill"),
        OrganizationUnit(name: "网络与信息中心", category: .support, siteKey: "wlzx", icon: "network"),
    ]

    // MARK: 初始化

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // 显式注册协议层（不依赖全局注册时序，保证网络监测埋点覆盖）
        config.protocolClasses = [RefererHeaderURLProtocol.self]
        urlSession = URLSession(configuration: config)

        // 加载本地缓存
        if loadCache() {
            LogManager.shared.info("organization", "机构缓存加载成功", context: [
                "count": "\(departments.count)",
                "source": dataSource
            ])
        }

        // 启动定时刷新
        startAutoRefresh()

        // 缓存模式联动：模式切换时重启/暂停定时刷新（F5）
        modeObserver = CacheModeManager.shared.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.startAutoRefresh()
            }

        // 首次拉取（使用防并发机制）
        syncTask = Task { [weak self] in
            guard let self = self else { return }
            await self.syncFromAPI()
        }
    }

    // MARK: 公开方法

    /// 按类别分组的数据
    var groupedData: [(OrganizationCategory, [OrganizationUnit])] {
        OrganizationCategory.allCases.compactMap { category in
            let units = departments.filter { $0.category == category }
            return units.isEmpty ? nil : (category, units)
        }
    }

    /// 总机构数
    var totalCount: Int { departments.count }

    /// 有详情页的机构数
    var detailPageCount: Int { departments.filter(\.hasDetailPage).count }

    /// 手动刷新（强制刷新，绕过 isLoading 检查）
    func refresh() async {
        // 取消之前的同步任务，防止并发
        syncTask?.cancel()
        // 短暂等待让取消生效
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.syncFromAPI(force: true)
        }
        syncTask = task
        await task.value
    }

    /// 带防抖的手动刷新（供 UI 下拉刷新调用）
    /// 冷却期内不重复请求，避免频繁网络调用
    func refreshWithDebounce(source: String) async {
        await refresh()
    }

    // MARK: 数据同步

    /// 从 head API 菜单数据更新 site_key（由 DataService 在同步完成后调用）
    func updateSiteKeys(from menus: [NetworkService.MenuDTO]) {
        LogManager.shared.info("organization", "开始从 head API 菜单更新 site_key", context: [
            "menuCount": "\(menus.count)"
        ])

        var updatedCount = 0
        var siteKeyMap: [String: String] = [:]

        // 递归遍历所有菜单，提取部门名称和 site_key 的映射
        func extractSiteKeys(from menus: [NetworkService.MenuDTO]) {
            for menu in menus {
                // 从 path 中提取 site_key
                if let name = menu.titleCn, let path = menu.path, !path.isEmpty {
                    if let key = extractSiteKey(from: path) {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        siteKeyMap[trimmedName] = key
                    }
                }
                // 递归处理子菜单
                if let children = menu.children, !children.isEmpty {
                    extractSiteKeys(from: children)
                }
            }
        }
        extractSiteKeys(from: menus)

        LogManager.shared.debugLog("organization", "从菜单提取 site_key 映射", context: [
            "mappingCount": "\(siteKeyMap.count)",
            "keys": siteKeyMap.keys.joined(separator: ", ")
        ])

        // 关键修复：以静态数据为基准（确保 siteKey 和 icon 始终最新），再叠加 API 更新
        var updated = departments
        // 先将静态数据中的 siteKey 和 icon 合并到 departments 中
        for i in updated.indices {
            if let staticUnit = staticData.first(where: { $0.id == updated[i].id }) {
                if updated[i].siteKey == nil && staticUnit.siteKey != nil {
                    updated[i].siteKey = staticUnit.siteKey
                }
                if updated[i].icon != staticUnit.icon {
                    updated[i].icon = staticUnit.icon
                }
            }
        }
        for i in updated.indices {
            let name = updated[i].name.trimmingCharacters(in: .whitespaces)

            // 1. 精确匹配
            if let key = siteKeyMap[name] {
                if updated[i].siteKey != key {
                    updated[i].siteKey = key
                    updatedCount += 1
                    LogManager.shared.debugLog("organization", "site_key 精确匹配", context: [
                        "name": name, "siteKey": key
                    ])
                }
                continue
            }

            // 2. 模糊匹配：菜单名包含在机构名中，或机构名包含在菜单名中
            var matched = false
            for (menuName, key) in siteKeyMap {
                if name.contains(menuName) || menuName.contains(name) {
                    if updated[i].siteKey != key {
                        updated[i].siteKey = key
                        updatedCount += 1
                        matched = true
                        LogManager.shared.debugLog("organization", "site_key 模糊匹配", context: [
                            "name": name, "menuName": menuName, "siteKey": key
                        ])
                    }
                    break
                }
            }
            if matched { continue }

            // 3. 智能近似匹配：处理"智造"vs"制造"等常见差异
            let normalizedName = normalizeDeptName(name)
            for (menuName, key) in siteKeyMap {
                let normalizedMenu = normalizeDeptName(menuName)
                if normalizedName == normalizedMenu {
                    if updated[i].siteKey != key {
                        updated[i].siteKey = key
                        updatedCount += 1
                        LogManager.shared.debugLog("organization", "site_key 近似匹配", context: [
                            "name": name, "menuName": menuName, "siteKey": key
                        ])
                    }
                    break
                }
            }

            // 4. 关键词匹配：提取名称中的关键词进行匹配
            if !matched && updated[i].siteKey == nil {
                for (menuName, key) in siteKeyMap {
                    let menuKeywords = menuName.components(separatedBy: CharacterSet(charactersIn: " -（）()"))
                        .filter { $0.count >= 2 }
                    let nameKeywords = name.components(separatedBy: CharacterSet(charactersIn: " -（）()"))
                        .filter { $0.count >= 2 }
                    let commonKeywords = Set(menuKeywords).intersection(Set(nameKeywords))
                    if commonKeywords.count >= 1 {
                        if updated[i].siteKey != key {
                            updated[i].siteKey = key
                            updatedCount += 1
                            matched = true
                            LogManager.shared.debugLog("organization", "site_key 关键词匹配", context: [
                                "name": name, "menuName": menuName, "siteKey": key,
                                "commonKeywords": commonKeywords.joined(separator: ", ")
                            ])
                        }
                        break
                    }
                }
            }
        }

        // 更新数据源标记（lastFetchTime 由调用方 syncFromAPI 统一设置）
        departments = updated
        dataSource = "服务器"
        saveCache()

        if updatedCount > 0 {
            LogManager.shared.info("organization", "site_key 更新完成", context: [
                "updatedCount": "\(updatedCount)",
                "totalCount": "\(departments.count)",
                "detailPages": "\(detailPageCount)"
            ])
        } else {
            LogManager.shared.info("organization", "site_key 无变化，同步时间已更新", context: [
                "totalCount": "\(departments.count)",
                "detailPages": "\(detailPageCount)"
            ])
        }
    }

    /// 规范化部门名称，处理常见差异（如"智造"vs"制造"、"学院 "vs"学院"）
    private func normalizeDeptName(_ name: String) -> String {
        return name
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "智造", with: "制造")
            .replacingOccurrences(of: "製造", with: "制造")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    /// 从 head API 同步机构数据
    /// - Parameter force: 强制刷新，绕过 isLoading 检查和冷却期
    func syncFromAPI(force: Bool = false) async {
        // 防并发：非强制模式下，如果正在加载则跳过
        guard force || !isLoading else {
            LogManager.shared.debugLog("organization", "同步跳过：正在加载中")
            return
        }
        // F5 缓存模式联动：本地缓存存在且新鲜（10 分钟内）→ 跳过远程同步
        if !force, CacheModeManager.shared.isCacheEnabled, !departments.isEmpty,
           let last = lastFetchTime, Date().timeIntervalSince(last) < 600 {
            LogManager.shared.info("organization", "缓存模式：机构数据使用本地缓存，跳过远程同步", context: [
                "cacheAge": String(format: "%.0fs", Date().timeIntervalSince(last)),
                "source": dataSource
            ])
            return
        }
        // 检查是否被取消（重置 isLoading 防止状态残留）
        if Task.isCancelled {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        LogManager.shared.info("organization", "机构数据同步开始", context: [
            "currentCount": "\(departments.count)",
            "currentSource": dataSource,
            "lastFetchTime": "\(lastFetchTime?.description ?? "nil")"
        ])

        var syncSucceeded = false

        do {
            // 1. 获取 head API 菜单数据
            let head = try await NetworkService.shared.fetchHead()
            // 检查是否被取消（例如用户快速多次下拉刷新）
            if Task.isCancelled { isLoading = false; return }
            if let menus = head.menus {
                updateSiteKeys(from: menus)
                syncSucceeded = true
                LogManager.shared.info("organization", "机构数据同步成功（head API）", context: [
                    "count": "\(departments.count)",
                    "detailPages": "\(detailPageCount)"
                ])
            } else {
                LogManager.shared.warning("organization", "head API 返回空菜单，使用现有数据")
                errorMessage = nil
                if dataSource != "服务器" {
                    dataSource = "服务器（空菜单）"
                }
                saveCache()
                syncSucceeded = true
                LogManager.shared.info("organization", "同步时间已更新（空菜单）", context: [
                    "count": "\(departments.count)",
                    "detailPages": "\(detailPageCount)"
                ])
            }

            // 2. 尝试解析机构页面 HTML 作为数据校验
            await validateFromPageHTML()

        } catch let error as URLError {
            let msg: String
            switch error.code {
            case .timedOut:
                msg = "请求超时，已使用缓存数据"
            case .notConnectedToInternet, .networkConnectionLost:
                msg = "网络未连接，已使用缓存数据"
            default:
                msg = "网络异常，已使用缓存数据"
            }
            // 只有 departments 为空时才显示错误，有缓存数据时静默处理
            if departments.isEmpty {
                errorMessage = msg
            } else {
                LogManager.shared.warning("organization", "数据同步网络失败（有缓存，静默）", context: [
                    "error": error.localizedDescription,
                    "code": "\(error.code.rawValue)",
                    "cacheCount": "\(departments.count)"
                ])
            }
            // 网络失败时使用缓存或静态数据
            if departments.isEmpty {
                departments = staticData
                dataSource = "预置数据"
                LogManager.shared.info("organization", "网络失败，回退静态数据", context: [
                    "count": "\(departments.count)"
                ])
            }
        } catch {
            // 只有 departments 为空时才显示错误
            if departments.isEmpty {
                errorMessage = "数据同步失败，已使用缓存数据"
            } else {
                LogManager.shared.warning("organization", "数据同步异常（有缓存，静默）", context: [
                    "error": error.localizedDescription,
                    "cacheCount": "\(departments.count)"
                ])
            }
            if departments.isEmpty {
                departments = staticData
                dataSource = "预置数据"
            }
        }

        // 关键修复：仅在同步成功且未被取消时更新 lastFetchTime
        // 单一赋值点，消除竞争条件，确保时间显示准确一致
        if syncSucceeded && !Task.isCancelled {
            lastFetchTime = Date()
            LogManager.shared.debugLog("organization", "lastFetchTime 更新", context: [
                "time": "\(lastFetchTime?.description ?? "nil")"
            ])
        }
        isLoading = false
    }

    /// 从机构页面 HTML 校验数据完整性
    private func validateFromPageHTML() async {
        guard let url = URL(string: "https://www.sxjzit.edu.cn/") else {
            LogManager.shared.warning("organization", "校验跳过：无效 URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                LogManager.shared.warning("organization", "页面校验跳过：响应异常")
                return
            }

            // 从 HTML 中提取机构名称列表
            let parsedNames = extractDepartmentNames(from: html)
            if parsedNames.isEmpty {
                LogManager.shared.debugLog("organization", "页面校验：未提取到机构名称")
                return
            }

            // 对比静态数据，检查是否有缺失
            let staticNames = Set(staticData.map { $0.name.trimmingCharacters(in: .whitespaces) })
            let newNames = parsedNames.subtracting(staticNames)
            let removedNames = staticNames.subtracting(parsedNames)

            if !newNames.isEmpty {
                LogManager.shared.info("organization", "页面校验：发现新增机构", context: [
                    "newDepartments": newNames.joined(separator: ", ")
                ])
            }
            if !removedNames.isEmpty {
                LogManager.shared.warning("organization", "页面校验：静态数据中机构在页面未找到", context: [
                    "missing": removedNames.joined(separator: ", ")
                ])
            }
            if newNames.isEmpty && removedNames.isEmpty {
                LogManager.shared.debugLog("organization", "页面校验：数据完整一致", context: [
                    "count": "\(parsedNames.count)"
                ])
            }

        } catch {
            LogManager.shared.debugLog("organization", "页面校验网络异常", context: [
                "error": error.localizedDescription
            ])
        }
    }

    /// 从 HTML 中提取机构名称
    private func extractDepartmentNames(from html: String) -> Set<String> {
        var names = Set<String>()
        // 匹配机构设置页面中的机构名称（在 <h2> 或列表项中）
        let patterns = [
            #"<h2[^>]*>([^<]+)</h2>"#,
            #"<li[^>]*>([^<]+)</li>"#,
            #"<a[^>]*href=["']/#/departments/page\?site_key=[^"']*["'][^>]*>([^<]+)</a>"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
                guard let match = match,
                      match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: html) else { return }
                let rawName = String(html[nameRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                // 过滤掉明显不是机构名称的内容
                if !rawName.isEmpty,
                   !rawName.hasPrefix("<"),
                   !rawName.contains("http"),
                   rawName.count > 2,
                   rawName.count < 50 {
                    names.insert(rawName)
                }
            }
        }

        return names
    }

    // MARK: 工具方法

    /// 从 URL path 中提取 site_key
    private func extractSiteKey(from path: String) -> String? {
        guard let range = path.range(of: "site_key=") else { return nil }
        let key = String(path[range.upperBound...])
        if let ampRange = key.range(of: "&") {
            return String(key[..<ampRange.lowerBound])
        }
        return key
    }

    // MARK: 缓存

    private func saveCache() {
        let cache = OrganizationCache(
            departments: departments,
            fetchTime: lastFetchTime ?? Date(),
            dataSource: dataSource
        )
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            LogManager.shared.debugLog("organization", "缓存写入成功", context: [
                "count": "\(departments.count)",
                "source": dataSource
            ])
        } else {
            LogManager.shared.error("organization", "缓存编码失败")
        }
    }

    @discardableResult
    private func loadCache() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(OrganizationCache.self, from: data) else {
            // 无缓存：使用静态数据
            departments = staticData
            dataSource = "预置数据"
            LogManager.shared.info("organization", "无缓存数据，加载静态数据", context: [
                "count": "\(departments.count)"
            ])
            return false
        }

        // 关键修复：将静态数据中的 siteKey 和 icon 合并到缓存数据中
        // 防止旧缓存（siteKey 为 nil）覆盖新版本静态数据中已配置的 siteKey
        var merged = cache.departments
        var mergedCount = 0
        for i in merged.indices {
            if let staticUnit = staticData.first(where: { $0.id == merged[i].id }) {
                if merged[i].siteKey == nil && staticUnit.siteKey != nil {
                    merged[i].siteKey = staticUnit.siteKey
                    mergedCount += 1
                }
                // 同时修复 icon（确保静态数据中的新图标被使用）
                if merged[i].icon != staticUnit.icon {
                    merged[i].icon = staticUnit.icon
                }
            }
        }
        departments = merged
        dataSource = cache.dataSource
        lastFetchTime = cache.fetchTime

        if mergedCount > 0 {
            LogManager.shared.info("organization", "缓存合并静态 siteKey", context: [
                "mergedCount": "\(mergedCount)",
                "totalCount": "\(departments.count)",
                "detailPages": "\(detailPageCount)"
            ])
        }
        return true
    }

    /// 清空缓存并恢复静态数据
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        departments = staticData
        dataSource = "预置数据"
        lastFetchTime = nil
        errorMessage = nil
        LogManager.shared.info("organization", "缓存已清空，恢复静态数据", context: [
            "count": "\(departments.count)"
        ])
    }

    // MARK: 定时刷新

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // 缓存模式联动：暂停定时远程刷新（数据以本地缓存为准）；切回即时模式自动恢复
        if CacheModeManager.shared.isCacheEnabled {
            LogManager.shared.info("organization", "缓存模式下定时刷新已暂停")
            return
        }
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncFromAPI()
            }
        }
        LogManager.shared.info("organization", "定时刷新已启动", context: [
            "interval": "\(Int(refreshInterval / 60))分钟"
        ])
    }

    /// 停止定时器（App 进入后台时可调用）
    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        LogManager.shared.info("organization", "定时刷新已停止")
    }
}