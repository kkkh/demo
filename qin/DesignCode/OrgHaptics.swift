//
//  OrgHaptics.swift
//  山西晋中理工学院 APP — 机构设置模块（升级 · 阶段二）
//
//  模块振动分级（设计稿 v1.2 §7：六级词表 + 全操作映射）
//  原则：
//  ① 同一操作按阶段分级（下拉刷新：触发=柔 → 完成=结果）；
//  ② 滚动中不触发；③ 危险操作先弹确认再用結果级；
//  ④ 模块内新增交互必须映射到本词表之一，禁止裸用生成器。
//

import UIKit

/// 机构模块振动分级词表
enum OrgHaptics {

    /// 选择｜平级切换：分类 chips / 栏目 chips / 排序切换
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 轻｜完成 · 进入：进入详情 / 加载更多到达 / 打开图片
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 柔｜开始 · 触发：下拉刷新触发 / 玻璃吸顶首次出现 / toast 出现
    static func soft() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 中｜状态改变：收藏 / 关注 / 长按菜单弹出 / 字号切换
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 锐｜边界 · 干脆：翻到底（无更多）/ 回弹到顶底 / 空态刷新无变化
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// 结果 · 成功：关注成功 / 刷新完成
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 结果 · 注意：弱网降级提示
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// 结果 · 失败：加载失败 / 同步失败
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}