//
//  OrgTheme.swift
//  山西晋中理工学院 APP — 机构设置模块（升级 · 阶段二）
//
//  模块视觉令牌（设计稿 v1.2 §1.3 / §3 / §4 / §8）：
//  「青金书院」——暖纸白 + 墨蓝 + 铜金点睛（点睛占比 ≤5%）；
//  分类五色为恒定语义色（统一降饱和，全部经 WCAG 实算 ≥4.5:1）。
//
//  约束：仅模块内使用；全部文本仍须走 display* 排版链（构建护栏强制）。
//

import SwiftUI

/// 机构模块视觉令牌
enum OrgTheme {

    // MARK: 面（哑光实体面；玻璃只用于浮动层）

    /// 页面底（暖纸白 / 曜石黑蓝）
    static var bg: Color { Color(lightHex: "F7F5F0", darkHex: "0F141B") }
    /// 页面顶（2 级渐变 6% 差）
    static var bgTop: Color { Color(lightHex: "FCFBF9", darkHex: "121924") }
    /// 卡片面
    static var surface: Color { Color(lightHex: "FFFFFF", darkHex: "171E28") }
    /// 次级面（缩略图占位 / 分组底）
    static var surfaceMuted: Color { Color(lightHex: "F1EFE9", darkHex: "1E2733") }
    /// 分割线（1px）
    static var separator: Color { Color(lightHex: "E6E2D9", darkHex: "2A3542") }

    // MARK: 文字三级（对比度：14.37 / 5.36 / 4.60，深色 16.32 / 8.23 / 5.48）

    static var textPrimary: Color { Color(lightHex: "1B2430", darkHex: "EEF1F6") }
    static var textSecondary: Color { Color(lightHex: "5C6672", darkHex: "A3AEBD") }
    static var textTertiary: Color { Color(lightHex: "667080", darkHex: "818D9C") }

    // MARK: 主色 / 交互 / 点睛

    /// 墨蓝（强调文字、选中态、描边；11.34:1）
    static var primary: Color { Color(lightHex: "1E3A66", darkHex: "9FB9E6") }
    /// 交互蓝（按钮 / 链接 / 焦点；6.02–6.56:1）
    static var tint: Color { Color(lightHex: "2C5CA8", darkHex: "86AEE8") }
    /// 铜金（大号数字 / 饰线；4.62:1 卡上）
    static var brass: Color { Color(lightHex: "8F7038", darkHex: "D8BC8A") }
    /// 铜金·小字变体（10–12pt 徽标/统计专用；5.99:1）
    static var brassStrong: Color { Color(lightHex: "7A5F2E", darkHex: "D8BC8A") }

    // MARK: 语义（三方案恒定）

    static var success: Color { Color(lightHex: "2F7D5C", darkHex: "6FC79E") }
    static var warning: Color { Color(lightHex: "96652A", darkHex: "E2A85E") }
    static var danger: Color { Color(lightHex: "B0463F", darkHex: "E58C84") }

    // MARK: 背景（替代全局 GradientBackground，模块内"同族不同纸"）

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [bgTop, bg], startPoint: .top, endPoint: .bottom)
    }

    // MARK: 分类五色（恒定语义色；图标 / 12pt 徽标 / 12%（深 18%）衬底，永不作卡片底色）

    static func categoryColor(_ category: OrganizationCategory) -> Color {
        switch category {
        case .partyCommittee: return Color(lightHex: "9E4A55", darkHex: "E3919B")   // 绛红 5.89 / 7.02
        case .massOrg:        return Color(lightHex: "96653F", darkHex: "E0AE7E")   // 赭橙 4.96 / 8.40
        case .administrative: return Color(lightHex: "4A6E9E", darkHex: "93B4DC")   // 藏青 5.23 / 7.82
        case .teaching:       return Color(lightHex: "6E5A96", darkHex: "B3A0DA")   // 青莲 5.89 / 7.15
        case .support:        return Color(lightHex: "3E7873", darkHex: "93C4BE")   // 松青 5.07 / 8.68
        }
    }

    /// 分类色衬底透明度（浅 12% / 深 18%）
    static func categoryTintOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.18 : 0.12
    }

    // MARK: 几何（4pt 网格 / 圆角 5 阶）

    enum Radius {
        static let tile: CGFloat = 10
        static let row: CGFloat = 14
        static let card: CGFloat = 18
        static let hero: CGFloat = 22
        static let capsule: CGFloat = 999
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let group: CGFloat = 28
    }

    // MARK: 图标（单体系：线性；.fill 仅作激活态变体）

    /// 线性变体（去掉 .fill 后缀；不存在的图标保持原样）
    static func linearIcon(_ name: String) -> String {
        name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
    }

    // MARK: 玻璃（仅浮动层：吸顶栏 / chips / 工具条）

    /// 玻璃染色（选中态主色/分类色 28%，常态透明）
    static func glassTint(_ color: Color, active: Bool) -> Color {
        active ? color.opacity(0.28) : .clear
    }
}

// MARK: - 统一按压反馈（设计稿 §6#7）

/// 机构模块统一按压：scale 0.97 + 亮度 -3%，spring(0.3, 0.85)
struct OrgPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

// MARK: - 骨架块（复用 ShimmerView 微光，1.8s 线性循环）

/// 骨架块：哑光底 + 微光扫过（设计稿 §5.5 加载态）
struct OrgSkeletonBlock: View {
    var height: CGFloat
    var width: CGFloat? = nil
    var cornerRadius: CGFloat = OrgTheme.Radius.row

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(OrgTheme.surfaceMuted)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                ShimmerView()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}