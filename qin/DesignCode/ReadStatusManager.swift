//
//  ReadStatusManager.swift
//  山西晋中理工学院 APP — 文章已读/未读状态管理
//
//  纯本地 UserDefaults 持久化，无需网络请求。
//  进入文章详情自动标记已读，列表显示未读蓝点指示器；
//  支持回退标记未读（收藏页等场景），持久化保持插入顺序，
//  超限时精确淘汰最早记录（而非随机丢失）。
//

import Foundation
import SwiftUI

// MARK: - 已读状态管理器

@MainActor
final class ReadStatusManager: ObservableObject {
    static let shared = ReadStatusManager()

    private let defaultsKey = "readArticleIds"
    private let maxStoredIds: Int

    /// 注入存储（测试隔离；默认标准 UserDefaults）
    private let defaults: UserDefaults

    private var _readIds: Set<String> = []
    /// 已读键插入顺序：持久化顺序稳定，超限时精确淘汰最早记录
    private var _order: [String] = []

    init(defaults: UserDefaults = .standard, maxStoredIds: Int = 5000) {
        self.defaults = defaults
        self.maxStoredIds = maxStoredIds
        let stored = defaults.stringArray(forKey: defaultsKey) ?? []
        // 去重保序（历史数据可能存在重复项）
        var seen = Set<String>()
        _order = stored.filter { seen.insert($0).inserted }
        _readIds = seen
    }

    // MARK: 查询

    func isRead(_ key: String) -> Bool {
        _readIds.contains(key)
    }

    /// 全部已读键快照（供收藏页「未读」筛选等只读场景使用）
    var snapshot: Set<String> { _readIds }

    /// 未读数量
    func unreadCount(in items: [NewsItem]) -> Int {
        items.filter { !isRead($0.readKey) }.count
    }

    // MARK: 标记已读

    func markAsRead(_ key: String) {
        guard !_readIds.contains(key) else { return }
        _readIds.insert(key)
        _order.append(key)
        trimIfNeeded()
        persist()
        objectWillChange.send()
    }

    /// 标记单篇文章已读
    func markAsRead(_ item: NewsItem) {
        markAsRead(item.readKey)
    }

    /// 回退标记未读（移除已读记录；用于收藏页「标记为未读」等场景）
    func markAsUnread(_ key: String) {
        guard _readIds.contains(key) else { return }
        _readIds.remove(key)
        _order.removeAll { $0 == key }
        persist()
        objectWillChange.send()
    }

    // MARK: 全部已读

    /// 将当前所有文章标记为已读
    func markAllAsRead() {
        let allIds = DataService.shared.allNews.map { $0.readKey }
        var added = false
        for id in allIds where !_readIds.contains(id) {
            _readIds.insert(id)
            _order.append(id)
            added = true
        }
        guard added else { return }
        trimIfNeeded()
        persist()
        objectWillChange.send()
    }

    // MARK: 持久化

    /// 超限裁剪：按插入顺序淘汰最早的记录（保证最新已读状态永不丢失）
    private func trimIfNeeded() {
        guard _order.count > maxStoredIds else { return }
        let overflow = _order.count - maxStoredIds
        let removed = _order.prefix(overflow)
        _order.removeFirst(overflow)
        for key in removed { _readIds.remove(key) }
    }

    private func persist() {
        defaults.set(_order, forKey: defaultsKey)
    }
}