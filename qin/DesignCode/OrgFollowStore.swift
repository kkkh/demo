//
//  OrgFollowStore.swift
//  山西晋中理工学院 APP — 机构设置模块（升级 · 阶段三 C）
//
//  关注制推送的基础设施：用户「关注」的机构清单（本地持久化）+ 机构动态扫描（纯函数）。
//  - 数据面：FollowedOrg（siteKey / 名称 / 分类 / siteId），JSON 落 UserDefaults；
//  - 推送面：NotificationManager 第五检测通道「机构动态」只遍历本清单（无关注 → 零请求短路）；
//  - 去重面：关注动作触发一次性基线播种（NotificationManager.seedOrgFollowBaseline），
//           避免「刚关注即被历史文章轰炸」，此后只推真增量。
//
//  约束：文件归机构模块；共享文件（NotificationManager / MessageCenterStore / TabBar）只增不改。
//

import Foundation
import SwiftUI

// MARK: - 已关注机构

/// 已关注机构（持久化单元）
struct FollowedOrg: Codable, Equatable, Identifiable {
    /// 官网站点键（唯一主键）
    let siteKey: String
    let name: String
    /// OrganizationCategory.rawValue（深链回跳时用于分类着色）
    let categoryRaw: String
    /// 机构子站 site_id（深链文章详情的缓存区分键；缺省 "1"）
    let siteId: String

    var id: String { siteKey }

    var category: OrganizationCategory {
        OrganizationCategory(rawValue: categoryRaw) ?? .administrative
    }
}

// MARK: - 关注清单（本地持久化）

@MainActor
final class OrgFollowStore: ObservableObject {
    static let shared = OrgFollowStore()

    private let defaultsKey = "orgFollowedOrgs"
    private let defaults: UserDefaults

    /// 关注清单（followed 顺序 = 关注先后，推送遍历按此顺序）
    @Published private(set) var followed: [FollowedOrg] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        followed = Self.decode(defaults.string(forKey: defaultsKey))
    }

    // MARK: 查询

    func isFollowing(siteKey: String) -> Bool {
        followed.contains { $0.siteKey == siteKey }
    }

    var count: Int { followed.count }

    var siteKeys: [String] { followed.map(\.siteKey) }

    // MARK: 变更

    /// 关注 / 取关（返回变更后是否处于关注态）
    @discardableResult
    func toggle(_ org: FollowedOrg) -> Bool {
        if isFollowing(siteKey: org.siteKey) {
            followed.removeAll { $0.siteKey == org.siteKey }
            persist()
            LogManager.shared.info("organization", "取消关注机构", context: [
                "siteKey": org.siteKey,
                "name": org.name,
                "remaining": "\(followed.count)"
            ])
            return false
        }
        followed.append(org)
        persist()
        LogManager.shared.info("organization", "关注机构", context: [
            "siteKey": org.siteKey,
            "name": org.name,
            "category": org.categoryRaw,
            "total": "\(followed.count)"
        ])
        return true
    }

    /// 清空全部关注（设置面板「全部取消关注」入口；当前无 UI 调用，保留为运维与单测入口）
    func removeAll() {
        guard !followed.isEmpty else { return }
        let removed = followed.count
        followed.removeAll()
        persist()
        LogManager.shared.info("organization", "清空机构关注", context: ["removed": "\(removed)"])
    }

    // MARK: 持久化（编解码为纯函数，供单测）

    nonisolated static func encode(_ orgs: [FollowedOrg]) -> String? {
        guard let data = try? JSONEncoder().encode(orgs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 容错解码：损坏数据一律回落空清单（不拖垮模块）
    nonisolated static func decode(_ raw: String?) -> [FollowedOrg] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FollowedOrg].self, from: data)) ?? []
    }

    private func persist() {
        if let raw = Self.encode(followed) {
            defaults.set(raw, forKey: defaultsKey)
        } else {
            LogManager.shared.warning("organization", "关注清单编码失败，本轮不落盘", context: [
                "count": "\(followed.count)"
            ])
        }
    }
}

// MARK: - 机构动态扫描（纯函数，可单测）

/// 从 `/dept/home2` 响应扫描候补新文章（机构动态通道数据源）
enum OrgFollowArticleScanner {

    struct Candidate: Equatable {
        let articleId: String
        let title: String
        let updateTime: String
    }

    /// nav 嵌套区块内全部文章 → 按时间降序、按 articleId 去重、截断上限
    /// - Parameters:
    ///   - data: `/dept/home2` 响应
    ///   - limit: 上限（防单个机构首页嵌套过多导致通知轰炸；默认 20）
    nonisolated static func candidates(from data: NetworkService.DeptHome2DTO, limit: Int = 20) -> [Candidate] {
        var found: [Candidate] = []
        for item in data.nav ?? [] {
            for (_, section) in item.data ?? [:] {
                append(from: section.articles?.list, into: &found)
                for child in section.children?.list ?? [] {
                    append(from: child.articles?.list, into: &found)
                }
            }
            append(from: item.articles?.list, into: &found)
            for child in item.children ?? [] {
                append(from: child.articles?.list, into: &found)
            }
        }

        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.articleId).inserted }
        let sorted = unique.sorted { $0.updateTime > $1.updateTime }
        return Array(sorted.prefix(limit))
    }

    private nonisolated static func append(from list: [NetworkService.DeptArticleDTO]?,
                                           into result: inout [Candidate]) {
        for article in list ?? [] {
            guard let id = article.id, !id.isEmpty else { continue }
            result.append(Candidate(articleId: id,
                                    title: article.title ?? "",
                                    updateTime: article.updateTime ?? ""))
        }
    }
}