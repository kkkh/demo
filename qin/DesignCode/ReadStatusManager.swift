//
//  ReadStatusManager.swift
//  山西晋中理工学院 APP — 文章已读/未读状态管理
//
//  纯本地 UserDefaults 持久化，无需网络请求。
//  进入文章详情自动标记已读，列表显示未读蓝点指示器。
//

import Foundation
import SwiftUI

// MARK: - 已读状态管理器

@MainActor
final class ReadStatusManager: ObservableObject {
    static let shared = ReadStatusManager()

    private let defaultsKey = "readArticleIds"
    private let maxStoredIds = 5000

    private var _readIds: Set<String> = []

    private init() {
        _readIds = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    // MARK: 查询

    func isRead(_ key: String) -> Bool {
        _readIds.contains(key)
    }

    /// 未读数量
    func unreadCount(in items: [NewsItem]) -> Int {
        items.filter { !isRead($0.readKey) }.count
    }

    // MARK: 标记已读

    func markAsRead(_ key: String) {
        guard !_readIds.contains(key) else { return }
        _readIds.insert(key)
        save()
        objectWillChange.send()
    }

    /// 标记单篇文章已读
    func markAsRead(_ item: NewsItem) {
        markAsRead(item.readKey)
    }

    // MARK: 全部已读

    /// 将当前所有文章标记为已读
    func markAllAsRead() {
        let allIds = DataService.shared.allNews.map { $0.readKey }
        let newIds = Set(allIds)
        let added = newIds.subtracting(_readIds)
        guard !added.isEmpty else { return }
        _readIds.formUnion(newIds)
        save()
        objectWillChange.send()
    }

    // MARK: 持久化

    private func save() {
        let trimmed = Array(_readIds.suffix(maxStoredIds))
        UserDefaults.standard.set(trimmed, forKey: defaultsKey)
    }
}