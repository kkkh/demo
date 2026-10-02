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
import UIKit

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
    /// 铜金·小字变体（10–12pt 徽标/统计专用；5.99:1，v2.2 §1.4 Color.brass24）
    static var brassStrong: Color { Color(lightHex: "7A5F2E", darkHex: "D8BC8A") }
    /// 铜金·饰线（分隔/档案纸 2pt 细线用途；比 brass 更亮保证饰线醒目，v2.2 §3.5②）
    static var brassRule: Color { Color(lightHex: "9A7B42", darkHex: "D8BC8A") }

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

    // MARK: 几何（4pt 网格 / 圆角 5 阶；v2.2 §1.2/§1.4 增补）

    enum Radius {
        static let tile: CGFloat = 10
        static let row: CGFloat = 14
        static let card: CGFloat = 18
        /// 九形态内容壳圆角（v2.2 §3.5⑤ Radius.shell18）
        static let shell: CGFloat = 18
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
        /// 区块间距 24（ScrollView 内；v2.2 §1.2 Space.screen24）
        static let screen: CGFloat = 24
        static let group: CGFloat = 28
    }

    // MARK: 阴影（v2.2 §1.2/§1.4：常态无阴影；仅浮动层与选中项）

    /// 浮动层阴影色（浅=墨蓝 10%，深=黑 35%；避免深色死黑）
    static var floatShadowColor: Color {
        Color(lightHex: "1E3A66", darkHex: "000000")
    }
    static let floatShadowRadius: CGFloat = 24
    static let floatShadowY: CGFloat = 8
    /// 选中项（chips）阴影色（tint 30%；设计稿 §3.5③）
    static var chipShadowColor: Color {
        Color(lightHex: "2C5CA8", darkHex: "86AEE8")
    }
    static let chipShadowRadius: CGFloat = 14
    static let chipShadowY: CGFloat = 6

    // MARK: 动效令牌（v2.2 §1.4 Motion.* / §4 参数表）

    enum Motion {
        /// 栏目 chips 选中切换（响应 0.5s / 阻尼 0.8；设计稿 §4#2）
        static let chipsIn = Animation.spring(response: 0.5, dampingFraction: 0.8)
        /// 新行 stagger 间隔（30ms；设计稿 §4#3）
        static let stagger: TimeInterval = 0.03
        /// 图片淡入（0.2s；设计稿 §4#6）
        static let imageFadeIn: TimeInterval = 0.2
        /// 玻璃吸顶出现（0.25s ease-out；设计稿 §4#9）
        static let glassIn = Animation.easeOut(duration: 0.25)
        /// 列表 y 向涌入位移（切换栏目时 6pt；设计稿 §4#2）
        static let columnInOffset: CGFloat = 6
    }

    // MARK: 图标（单体系：线性；.fill 仅作激活态变体；v2.2 §1.5）

    /// 线性变体（去掉 .fill 后缀；不存在的图标保持原样）
    static func linearIcon(_ name: String) -> String {
        name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
    }

    /// 图标单点探测：SF Symbol 存在则用之，否则回退 fallback（v2.2 §1.5 合法性兜底，禁散弹）
    static func symbol(_ preferred: String, fallback: String) -> String {
        UIImage(systemName: preferred) != nil ? preferred : fallback
    }

    /// 九形态语义图标（v2.2 §1.5 语义映射表；经 symbol() 探测兜底）
    static func kindSymbol(_ kind: OrgColumnKind, fallback: String = "doc.text") -> String {
        switch kind {
        case .list:         return symbol("doc.text", fallback: fallback)
        case .content:      return symbol("doc.richtext", fallback: fallback)
        case .video:        return symbol("play.rectangle", fallback: fallback)
        case .teacher:      return symbol("person.text.rectangle", fallback: fallback)
        case .recruit:      return symbol("doc.text.magnifyingglass", fallback: fallback)
        case .calendar:     return symbol("calendar", fallback: fallback)
        case .opinion:      return symbol("envelope", fallback: fallback)
        case .link:         return symbol("globe", fallback: fallback)
        case .webFallback:  return symbol("tray", fallback: fallback)
        }
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

// MARK: - 空态线稿插画（v2.2 §1.5④：轻描线 · 单色墨蓝描边 · 场景微化）

/// 空态插画种类：空书架（栏目类空态）/ 断线（无网）/ 折叠纸（错误态）
enum OrgArtKind {
    case shelfEmpty
    case wifiBroken
    case paperTorn
}

/// 轻描线空态插画（Canvas 矢量：2pt 圆头线条；墨蓝主描边 + 次级淡描边；
/// 非二进制资源 → 天然深浅自适应、零 Assets 维护）
struct OrgEmptyArt: View {
    var kind: OrgArtKind = .shelfEmpty
    var width: CGFloat = 120
    var height: CGFloat = 96

    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color {
        OrgTheme.primary.opacity(colorScheme == .dark ? 0.58 : 0.50)
    }

    private var inkSoft: Color {
        OrgTheme.primary.opacity(colorScheme == .dark ? 0.30 : 0.26)
    }

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            switch kind {
            case .shelfEmpty: Self.drawShelf(into: &context, size: size, stroke: stroke)
            case .wifiBroken: Self.drawWifi(into: &context, size: size, stroke: stroke)
            case .paperTorn: Self.drawPaper(into: &context, size: size, stroke: stroke)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    // MARK: 空书架（三围板 + 横板三层 + 零星书脊）

    private static func drawShelf(into context: inout GraphicsContext, size: CGSize, stroke: StrokeStyle) {
        // 外框（三层书架）
        var frame = Path()
        frame.move(to: CGPoint(x: 10, y: 18))
        frame.addLine(to: CGPoint(x: 110, y: 18))
        frame.addLine(to: CGPoint(x: 110, y: 86))
        frame.addLine(to: CGPoint(x: 10, y: 86))
        frame.closeSubpath()
        context.stroke(frame, with: .color(OrgTheme.primary.opacity(0.55)), style: stroke)

        // 两块横板 → 三层
        for y in [CGFloat(40), CGFloat(63)] {
            var shelf = Path()
            shelf.move(to: CGPoint(x: 10, y: y))
            shelf.addLine(to: CGPoint(x: 110, y: y))
            context.stroke(shelf, with: .color(OrgTheme.primary.opacity(0.45)), style: stroke)
        }

        // 零星书脊（空荡感：三层分别 2 / 2 / 1 本，右侧留白）
        let books: [(CGFloat, CGFloat, CGFloat)] = [(18, 24, 16), (28, 24, 16),     // 层1
                                                    (82, 46, 17), (92, 46, 17),    // 层2
                                                    (50, 68, 18)]                  // 层3
        for (x, y, h) in books {
            var spine = Path()
            spine.move(to: CGPoint(x: x, y: y))
            spine.addLine(to: CGPoint(x: x, y: y + h))
            context.stroke(spine, with: .color(OrgTheme.primary.opacity(0.4)), style: stroke)
        }
    }

    // MARK: 断线（wifi 三弧 + 断裂口）

    private static func drawWifi(into context: inout GraphicsContext, size: CGSize, stroke: StrokeStyle) {
        let center = CGPoint(x: 72, y: 46)
        for radius in [CGFloat(8), 18, 28] {
            var arc = Path()
            arc.addArc(center: center, radius: radius,
                       startAngle: .degrees(210), endAngle: .degrees(-30), clockwise: false)
            context.stroke(arc, with: .color(OrgTheme.primary.opacity(0.55)), style: stroke)
        }
        // 断点（小方点）+ 裂口短线（右下）
        var dot = Path(ellipseIn: CGRect(x: 66, y: 68, width: 6, height: 6))
        context.fill(dot, with: .color(OrgTheme.primary.opacity(0.55)))
        var crack = Path()
        crack.move(to: CGPoint(x: 96, y: 30))
        crack.addLine(to: CGPoint(x: 92, y: 38))
        crack.move(to: CGPoint(x: 88, y: 44))
        crack.addLine(to: CGPoint(x: 84, y: 52))
        context.stroke(crack, with: .color(OrgTheme.primary.opacity(0.45)), style: stroke)
    }

    // MARK: 折叠纸（纸页 + 折角 + 正文错行）

    private static func drawPaper(into context: inout GraphicsContext, size: CGSize, stroke: StrokeStyle) {
        let paper = Path { p in
            p.move(to: CGPoint(x: 28, y: 18))
            p.addLine(to: CGPoint(x: 62, y: 18))
            p.addLine(to: CGPoint(x: 78, y: 34))
            p.addLine(to: CGPoint(x: 78, y: 66))
            p.addLine(to: CGPoint(x: 28, y: 66))
            p.closeSubpath()
        }
        context.stroke(paper, with: .color(OrgTheme.primary.opacity(0.55)), style: stroke)

        // 折角线
        var fold = Path()
        fold.move(to: CGPoint(x: 62, y: 18))
        fold.addLine(to: CGPoint(x: 62, y: 34))
        fold.addLine(to: CGPoint(x: 78, y: 34))
        context.stroke(fold, with: .color(OrgTheme.primary.opacity(0.35)), style: stroke)

        // 正文行：一段错位（错误语义）+ 两段完整
        let soft = OrgTheme.primary.opacity(0.3)
        var line1 = Path()
        line1.move(to: CGPoint(x: 36, y: 44))
        line1.addLine(to: CGPoint(x: 68, y: 44))
        context.stroke(line1, with: .color(soft), style: stroke)
        var line2a = Path()
        line2a.move(to: CGPoint(x: 36, y: 52))
        line2a.addLine(to: CGPoint(x: 50, y: 52))
        var line2b = Path()
        line2b.move(to: CGPoint(x: 56, y: 52))
        line2b.addLine(to: CGPoint(x: 66, y: 52))
        context.stroke(line2a, with: .color(soft), style: stroke)
        context.stroke(line2b, with: .color(soft), style: stroke)
    }
}

/// 机构线性徽章：分类色 12%（深 18%）衬底 + 24px 线性符号（SF Symbols weight=.medium）
/// - 由 `OrgTheme.symbol(_:fallback:)` 单点探测后的合法命名驱动，禁止散弹硬编码
/// - 徽章本体哑光（非玻璃），符合 §1.3「内容区禁用玻璃」
struct OrgBadge: View {
    /// 首选符号名（线性；.fill 由 linearIcon 剥离）
    var symbolName: String
    /// 分类语义色
    var color: Color
    /// 徽章边长（默认 40；题头用 48）
    var size: CGFloat = 40
    /// 图标点尺寸（默认 24）
    var iconSize: CGFloat = 24
    /// 呼吸动效开关（下拉刷新/同步角标用，§3.5③）
    var isPulsing: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.opacity(OrgTheme.categoryTintOpacity(colorScheme)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: OrgTheme.linearIcon(symbolName))
                    .displaySymbolFont(iconSize, weight: .medium)
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: isPulsing)
            }
            .accessibilityHidden(true)
    }
}