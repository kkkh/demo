//
//  ReadingGoalStore.swift
//  「园枢」阅读目标（2026-10-03 新增）
//
//  ⚠️ 与现有阅读统计/阅读时光 100% 隔离：
//    - 独立存储键（readingGoalDailyMinutes / readingGoalWeeklyMinutes / readingGoalType）
//    - 独立单例，不触碰 ReadingReportStore 任何现有逻辑
//  - 数据仅存本机；提供重置入口；边界由 MechanicalPicker 与 Store 双重兜底。

import SwiftUI
import Combine

/// 目标周期（每日 / 每周）
enum ReadingGoalPeriod: String, Codable, CaseIterable {
    case daily = "每日"
    case weekly = "每周"
}

@MainActor
final class ReadingGoalStore: ObservableObject {
    static let shared = ReadingGoalStore()

    // 独立存储键（ReadingGoal_ 前缀语义，与 readingReport* 区分）
    private static let dailyKey = "readingGoalDailyMinutes"
    private static let weeklyKey = "readingGoalWeeklyMinutes"
    private static let typeKey = "readingGoalType"

    /// 数值边界（分钟）
    static let dailyRange = 0...300
    static let weeklyRange = 0...1800

    @Published private(set) var period: ReadingGoalPeriod {
        didSet { UserDefaults.standard.set(period.rawValue, forKey: Self.typeKey) }
    }
    @Published private(set) var dailyMinutes: Int {
        didSet { UserDefaults.standard.set(clampDaily(dailyMinutes), forKey: Self.dailyKey) }
    }
    @Published private(set) var weeklyMinutes: Int {
        didSet { UserDefaults.standard.set(clampWeekly(weeklyMinutes), forKey: Self.weeklyKey) }
    }

    private init() {
        let ud = UserDefaults.standard
        // 默认：每日 30 分钟 / 每周 180 分钟（与 Hero 进度环初始一致）
        if ud.object(forKey: Self.dailyKey) == nil { ud.set(30, forKey: Self.dailyKey) }
        if ud.object(forKey: Self.weeklyKey) == nil { ud.set(180, forKey: Self.weeklyKey) }
        dailyMinutes = clampDaily(ud.integer(forKey: Self.dailyKey))
        weeklyMinutes = clampWeekly(ud.integer(forKey: Self.weeklyKey))
        period = ReadingGoalPeriod(rawValue: ud.string(forKey: Self.typeKey) ?? "") ?? .daily
    }

    private func clampDaily(_ v: Int) -> Int { min(max(v, Self.dailyRange.lowerBound), Self.dailyRange.upperBound) }
    private func clampWeekly(_ v: Int) -> Int { min(max(v, Self.weeklyRange.lowerBound), Self.weeklyRange.upperBound) }

    /// 当前周期目标（分钟）
    var currentGoalMinutes: Int {
        period == .daily ? dailyMinutes : weeklyMinutes
    }

    func setPeriod(_ p: ReadingGoalPeriod) { period = p }
    func setDaily(_ v: Int) { dailyMinutes = clampDaily(v) }
    func setWeekly(_ v: Int) { weeklyMinutes = clampWeekly(v) }

    /// 重置为目标周期默认值
    func resetToDefault() {
        dailyMinutes = 30
        weeklyMinutes = 180
    }
}
