//
//  DisplaySettingsManager.swift
//  山西晋中理工学院 APP — 显示设置（外观 / 排版 / 屏幕 / 自动锁定 / 辅助功能）
//
//  单一状态源：ObservableObject 单例 + UserDefaults 持久化，全部设置实时全局生效。
//  UIKit 桥接：屏幕亮度、防息屏、系统辅助功能开关监听、系统设置跳转。
//

import SwiftUI
import UIKit
import CoreText
import os

/// 阅读统计专用系统日志（Xcode 控制台 / Console.app 实时可见，便于定位显示问题）
private let readingStatsLogger = Logger(subsystem: "com.qinchao.designcode", category: "ReadingStats")

/// 毫秒级埋点时间戳工具（与 LogEntry.formattedTime 同格式 HH:mm:ss.SSS，context 内可直接阅读）。
/// 仅在主线程（@MainActor 埋点上下文）使用，DateFormatter 复用无需加锁。
private enum ReadingStatsClock {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func stamp(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

// MARK: - 外观模式

/// 外观模式（与既有 colorSchemePreference 存储键联动，避免双份状态）
enum DisplayAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色模式"
        case .dark:   return "深色模式"
        }
    }

    var resolvedColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 主题色

/// 主题色（Accent Color）：5 种预设，实时切换全局 tint
enum DisplayThemeStyle: String, CaseIterable, Identifiable {
    case blue, red, green, orange, purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:   return "品牌蓝"
        case .red:    return "热烈红"
        case .green:  return "清新绿"
        case .orange: return "活力橙"
        case .purple: return "典雅紫"
        }
    }

    /// 深浅模式自适应主题色（与全校品牌色系保持一致）
    var color: Color {
        switch self {
        case .blue:   return Color(lightHex: "1A56B8", darkHex: "5B8DEF")
        case .red:    return Color(lightHex: "C62856", darkHex: "FF6B8A")
        case .green:  return Color(lightHex: "2E7D32", darkHex: "66BB6A")
        case .orange: return Color(lightHex: "C9702E", darkHex: "FFB74D")
        case .purple: return Color(lightHex: "6B3FA0", darkHex: "B388FF")
        }
    }
}

// MARK: - 文章正文文字颜色

/// 文章正文文字颜色预设：8 种专业阅读色（深浅模式各配色值）+ 自定义自由配色
/// 「跟随系统」= 不覆盖，各渲染点保持原有语义色（现状不变）
enum ArticleTextColorPreset: String, CaseIterable, Identifiable {
    case system, ink, graphite, sepia, navy, forest, indigo, burgundy, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:   return "跟随系统"
        case .ink:      return "墨黑"
        case .graphite: return "石墨"
        case .sepia:    return "暖棕"
        case .navy:     return "藏蓝"
        case .forest:   return "松绿"
        case .indigo:   return "靛紫"
        case .burgundy: return "勃艮第"
        case .custom:   return "自定义"
        }
    }

    var subtitle: String {
        switch self {
        case .system:   return "保持原样"
        case .ink:      return "经典醒目"
        case .graphite: return "低调沉稳"
        case .sepia:    return "护眼纸感"
        case .navy:     return "理性深邃"
        case .forest:   return "自然舒缓"
        case .indigo:   return "文艺雅致"
        case .burgundy: return "复古优雅"
        case .custom:   return "自由配色"
        }
    }

    /// 浅色模式色值（nil = system / custom，需特殊处理）
    var lightHex: String? {
        switch self {
        case .system, .custom: return nil
        case .ink:      return "1A1A1A"
        case .graphite: return "4A4A55"
        case .sepia:    return "5D4037"
        case .navy:     return "1B3A5C"
        case .forest:   return "2E4A3A"
        case .indigo:   return "3F3D7A"
        case .burgundy: return "6D2E3A"
        }
    }

    /// 深色模式色值（nil = system / custom，需特殊处理）
    var darkHex: String? {
        switch self {
        case .system, .custom: return nil
        case .ink:      return "E8E8E8"
        case .graphite: return "C6C6CE"
        case .sepia:    return "CDA98F"
        case .navy:     return "9FB8D9"
        case .forest:   return "A9C4B6"
        case .indigo:   return "B5B2E8"
        case .burgundy: return "D9A5B0"
        }
    }
}

// MARK: - 阅读速度档位

/// 阅读速度档位：影响全文「预计阅读时长」换算（中文按字/分钟、英文按词/分钟）
enum ReadingSpeedTier: String, CaseIterable, Identifiable {
    case slow, standard, fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow:     return "慢速"
        case .standard: return "标准（默认）"
        case .fast:     return "快速"
        }
    }

    var subtitle: String {
        switch self {
        case .slow:     return "精细阅读 · 200 字/分"
        case .standard: return "日常阅读 · 300 字/分"
        case .fast:     return "速览阅读 · 450 字/分"
        }
    }

    /// 中文阅读速度（字/分钟）
    var chineseCharsPerMinute: Double {
        switch self {
        case .slow:     return 200
        case .standard: return 300
        case .fast:     return 450
        }
    }

    /// 英文阅读速度（词/分钟）
    var englishWordsPerMinute: Double {
        switch self {
        case .slow:     return 150
        case .standard: return 220
        case .fast:     return 300
        }
    }
}

// MARK: - 排版方案（一键套装）

/// 排版方案：一键套用 6 项排版值（字号档 / 行距 / 字距 / 粗体 / 系统字体 / 字体家族）
enum DisplaySchemePreset: String, CaseIterable, Identifiable {
    case comfortable, compact, eyeCare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfortable: return "阅读舒适"
        case .compact:     return "紧凑高效"
        case .eyeCare:     return "护眼大字"
        }
    }

    var subtitle: String {
        switch self {
        case .comfortable: return "宋体书卷气 · 从容留白"
        case .compact:     return "信息密度优先 · 一屏更多"
        case .eyeCare:     return "大号柔和圆体 · 久读不累"
        }
    }

    var icon: String {
        switch self {
        case .comfortable: return "book.pages"
        case .compact:     return "rectangle.compress.vertical"
        case .eyeCare:     return "eyeglasses"
        }
    }

    /// 方案徽章字样（卡片上直观展示核心参数）
    var shortBadgeText: String {
        switch self {
        case .comfortable: return "1.12× · 行距 1.25"
        case .compact:     return "0.94× · 行距 0.95"
        case .eyeCare:     return "1.26× · 行距 1.45"
        }
    }

    // MARK: 套用目标值（6 项，测试断言依据）

    var fontSizeTier: DisplayFontSizeTier {
        switch self {
        case .comfortable: return .large
        case .compact:     return .small
        case .eyeCare:     return .extraLarge
        }
    }

    var lineSpacing: Double {
        switch self {
        case .comfortable: return 1.25
        case .compact:     return 0.95
        case .eyeCare:     return 1.45
        }
    }

    var letterSpacing: Double {
        switch self {
        case .comfortable: return 0.2
        case .compact:     return 0
        case .eyeCare:     return 0.5
        }
    }

    var boldText: Bool {
        switch self {
        case .comfortable: return false
        case .compact:     return false
        case .eyeCare:     return true
        }
    }

    var useSystemFont: Bool {
        switch self {
        case .comfortable: return false   // 衬线
        case .compact:     return true
        case .eyeCare:     return false   // 圆润体
        }
    }

    var fontFamily: DisplayFontFamily {
        switch self {
        case .comfortable: return .songti
        case .compact:     return .system
        case .eyeCare:     return .yuanti
        }
    }
}

// MARK: - 变更历史

/// 显示设置变更记录（时间轴数据源；最近在前）
struct DisplayChangeRecord: Codable, Equatable, Identifiable {
    let id: UUID
    /// 日志字段键（appearance / theme_style / …）
    let field: String
    /// 字段中文名
    let fieldTitle: String
    /// 新值中文描述
    let value: String
    let at: Date
}

/// 历史数据纯算子（ring buffer 语义：新在前、去重、截断——离线可测）
enum DisplayHistoryOperator {
    /// 自定义颜色历史：规范化 → 置顶去重 → 截断 max
    static func pushColor(_ hex: String, into history: [String], max: Int = 6) -> [String] {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard cleaned.count == 6, UInt64(cleaned, radix: 16) != nil else { return history }
        let next = [cleaned] + history.filter { $0 != cleaned }
        return Array(next.prefix(max))
    }

    /// 变更时间轴：新记录插入头部 → 截断 max（真 FIFO）
    static func appendChange(_ record: DisplayChangeRecord, into history: [DisplayChangeRecord], max: Int = 20) -> [DisplayChangeRecord] {
        Array(([record] + history).prefix(max))
    }
}

// MARK: - 对比度自检（WCAG AA 纯函数）

/// WCAG 2.x 相对亮度与对比度计算（sRGB 线性化），供文章正文色合规自检。
/// 判定阈值：≥4.5 合规（绿）· 2.5–4.49 建议（橙）· <2.5 不合格（红）。
enum DisplayContrastChecker {

    enum ContrastLevel: String, Equatable {
        case pass, suggest, fail
    }

    /// 6 位十六进制 → sRGB 分量（0~1）；非法返回 nil
    static func hexComponents(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }

    /// WCAG 相对亮度（sRGB 线性化 + 加权）
    static func luminance(hex: String) -> Double {
        guard let (r, g, b) = hexComponents(hex) else { return 0 }
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// 对比度 = (L亮 + 0.05) / (L暗 + 0.05)，范围 1~21
    static func contrast(foregroundHex: String, backgroundHex: String) -> Double {
        let f = luminance(hex: foregroundHex)
        let b = luminance(hex: backgroundHex)
        let bright = max(f, b)
        let dark = min(f, b)
        return (bright + 0.05) / (dark + 0.05)
    }

    /// 判定等级
    static func level(for ratio: Double) -> ContrastLevel {
        if ratio >= 4.5 { return .pass }
        if ratio >= 2.5 { return .suggest }
        return .fail
    }
}

// MARK: - 字体档位

/// 字体大小档位：6 档，基于 body 缩放；「中」档跟随系统 Dynamic Type
enum DisplayFontSizeTier: String, CaseIterable, Identifiable {
    case tiny, small, medium, large, extraLarge, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny:       return "极小"
        case .small:      return "小"
        case .medium:     return "中（默认）"
        case .large:      return "大"
        case .extraLarge: return "特大"
        case .max:        return "最大"
        }
    }

    /// 相对 body 的字号缩放系数
    var scale: CGFloat {
        switch self {
        case .tiny:       return 0.85
        case .small:      return 0.94
        case .medium:     return 1.0
        case .large:      return 1.12
        case .extraLarge: return 1.26
        case .max:        return 1.40
        }
    }

    /// 「中」档返回 nil —— 不覆盖系统 Dynamic Type，其余档位映射到内容尺寸类别
    var contentSizeCategory: ContentSizeCategory? {
        switch self {
        case .tiny:       return .extraSmall
        case .small:      return .small
        case .medium:     return nil
        case .large:      return .large
        case .extraLarge: return .extraLarge
        case .max:        return .accessibilityLarge
        }
    }
}

// MARK: - 字体家族

/// 可选字体：全部为 iOS 内置**中文全字形**家族（本 App 界面以中文为主，
/// 西文字体不含中文字形会导致中文全部回退苹方、切换毫无变化——历史教训）。
/// 旧值迁移：serif/georgia→宋体、rounded→圆体、palatino→楷体、avenir→系统。
enum DisplayFontFamily: String, CaseIterable, Identifiable {
    case system, songti, kaiti, yuanti, xingkai, libian, weibei

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:  return "苹方黑体"
        case .songti:  return "宋体"
        case .kaiti:   return "楷体"
        case .yuanti:  return "圆体"
        case .xingkai: return "行楷"
        case .libian:  return "隶变"
        case .weibei:  return "魏碑"
        }
    }

    var subtitle: String {
        switch self {
        case .system:  return "系统默认 · 经典清晰"
        case .songti:  return "典雅书卷 · 久读不倦"
        case .kaiti:   return "温润手写 · 亲切自然"
        case .yuanti:  return "柔和圆润 · 舒缓护眼"
        case .xingkai: return "潇洒行云 · 笔意流动"
        case .libian:  return "古朴金石 · 庄重端方"
        case .weibei:  return "雄健碑刻 · 遒劲有力"
        }
    }

    /// 画廊真字貌示例（以各字体自身渲染，中文全字形立即可见差异）
    var sampleText: String { "园枢书卷气 晨读好时光" }

    /// 系统字体名（**PostScript 字面名**；工厂渲染、可用性实查与按需下载共用）
    /// 关键契约：系统按需下载的匹配引擎只认 PostScript 字面名——
    /// 传家族名（如 "Songti SC"）会「didBegin → didFinish 静默完成且不下载任何资产」，
    /// 表现为界面永远停在「下载中」直到看门狗复位（2026-09-27 真机 A/B 实证，历史误用家族名）。
    /// 字面名核准来源：macOS 同版本字体 CoreText 枚举 + Apple System Fonts 页 iOS 可下载清单（均一致）。
    var fontName: String {
        switch self {
        case .system:  return "PingFang SC"          // 苹方：系统恒内置（非按需下载）
        case .songti:  return "STSongti-SC-Regular"  // 宋体-简 常规
        case .kaiti:   return "STKaitiSC-Regular"    // 楷体-简 常规
        case .yuanti:  return "STYuanti-SC-Regular"  // 圆体-简 常规
        case .xingkai: return "STXingkaiSC-Light"    // 行楷-简 细（系统目录无 Regular 字面，Light 即标准字重）
        case .libian:  return "STLibianSC-Regular"   // 隶变-简 常规
        case .weibei:  return "WeibeiSC-Bold"        // 魏碑-简（系统目录仅粗体字面）
        }
    }

    /// 粗体字面名（开启「粗体文本」时优先使用真实粗体字面；nil = 无独立粗体字面，回退主字面合成加粗）
    var boldFontName: String? {
        switch self {
        case .system:  return nil
        case .songti:  return "STSongti-SC-Bold"
        case .kaiti:   return "STKaitiSC-Bold"
        case .yuanti:  return "STYuanti-SC-Bold"
        case .xingkai: return "STXingkaiSC-Bold"
        case .libian:  return nil   // iOS 可下载目录仅常规字面
        case .weibei:  return nil   // 主字面即粗体
        }
    }

    /// CSS（WebKit）家族名：CSS 按「家族名」匹配，PostScript 字面名在 WebKit 不保证命中
    /// （2026-09-29 真机反馈修复：WebView 正文此前永远默认，根因即只给了字面名）
    var cssFamilyName: String {
        switch self {
        case .system:  return "PingFang SC"
        case .songti:  return "Songti SC"
        case .kaiti:   return "Kaiti SC"
        case .yuanti:  return "Yuanti SC"
        case .xingkai: return "Xingkai SC"
        case .libian:  return "Libian SC"
        case .weibei:  return "Weibei SC"
        }
    }

    /// CSS 本地化家族名（中文名候选：部分渲染栈以本地化名注册）
    var cssLocalizedFamilyName: String {
        switch self {
        case .system:  return "苹方-简"
        case .songti:  return "宋体-简"
        case .kaiti:   return "楷体-简"
        case .yuanti:  return "圆体-简"
        case .xingkai: return "行楷-简"
        case .libian:  return "隶变-简"
        case .weibei:  return "魏碑-简"
        }
    }

    /// 按需下载字面清单（主字面 + 需要时的粗体字面；去重；system 不需要下载）
    func downloadFaceNames(includeBold: Bool) -> [String] {
        guard self != .system else { return [] }
        var faces = [fontName]
        if includeBold, let boldFace = boldFontName, boldFace != fontName {
            faces.append(boldFace)
        }
        return faces
    }

    /// 迁移历史西文字体存储值 → 中文字体家族（未知/非法值回退系统）
    static func normalized(rawValue: String) -> DisplayFontFamily {
        switch rawValue {
        case "songti", "kaiti", "yuanti", "xingkai", "libian", "weibei", "system":
            return DisplayFontFamily(rawValue: rawValue) ?? .system
        case "serif", "georgia": return .songti
        case "rounded":          return .yuanti
        case "palatino":         return .kaiti
        case "avenir":           return .system
        default:                 return .system
        }
    }
}

// MARK: - 字体可用性（系统按需下载）

/// 中文字体可用状态：iOS 内置书法字体（宋/楷/圆/行楷/隶变/魏碑）为系统级按需下载字体，
/// 即时命中仅苹方；覆盖安装会清下载状态，必须显式触发下载并在 UI 直观反馈。
/// downloading 携带系统回调的下载进度（0...100；nil = 尚未取得进度，UI 显示不确定态）
enum DisplayFontAvailability: Equatable {
    case ready
    case downloading(percent: Double?)
    case unavailable

    /// 是否就绪（UI/逻辑统一判定入口）
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - 自动锁定

/// 自动锁定档位
enum DisplayAutoLockOption: String, CaseIterable, Identifiable {
    case s30, m1, m2, m5, m10, m15, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .s30:   return "30 秒"
        case .m1:    return "1 分钟"
        case .m2:    return "2 分钟"
        case .m5:    return "5 分钟"
        case .m10:   return "10 分钟"
        case .m15:   return "15 分钟"
        case .never: return "永不"
        }
    }
}

// MARK: - 显示设置管理器

/// 显示设置管理器：所有设置实时生效、全局响应、自动持久化。
@MainActor
final class DisplaySettingsManager: ObservableObject {

    static let shared = DisplaySettingsManager()

    // MARK: 存储键

    /// 外观模式复用既有键，保证与历史设置/App 其它读取点完全联动
    static let appearanceKey = "colorSchemePreference"
    private static let accentKey      = "displayAccentStyle"
    /// 以下六键为非隔离排版快照函数直读（UserDefaults 线程安全；2026-09-29 全局覆盖）
    nonisolated private static let fontSizeKey    = "displayFontSizeTier"
    nonisolated private static let boldKey        = "displayBoldText"
    nonisolated private static let systemFontKey  = "displayUseSystemFont"
    nonisolated private static let fontFamilyKey  = "displayFontFamily"
    nonisolated private static let lineSpacingKey = "displayLineSpacing"
    nonisolated private static let trackingKey    = "displayLetterSpacing"
    private static let buttonShapeKey = "displayButtonShapes"
    private static let brightnessKey  = "displayBrightness"
    private static let autoBrightKey  = "displayAutoBrightness"
    private static let autoLockKey    = "displayAutoLock"
    private static let keepAwakeKey   = "displayKeepAwake"
    /// 以下两键为非隔离快照函数直读（UserDefaults 线程安全）
    nonisolated private static let articleTextColorKey = "displayArticleTextColorPreset"
    nonisolated private static let articleTextCustomHexKey = "displayArticleTextCustomHex"
    private static let readingStatsKey      = "displayReadingStatsEnabled"
    private static let readingCharCountKey  = "displayReadingCharCountEnabled"
    private static let readingTimeKey       = "displayReadingTimeEnabled"
    private static let readingListBadgeKey  = "displayReadingListBadgeEnabled"
    private static let readingSpeedKey      = "displayReadingSpeedTier"
    private static let grayScaleKey         = "displayGrayScaleMode"
    private static let customColorHistoryKey = "displayCustomColorHistory"
    private static let changeHistoryKey     = "displayChangeHistory"

    // MARK: 发布状态

    /// 外观模式（浅色 / 深色 / 跟随系统）
    @Published var appearanceMode: DisplayAppearanceMode {
        didSet { persist(appearanceMode.rawValue, forKey: Self.appearanceKey); log("appearance", appearanceMode.rawValue) }
    }

    /// 主题色
    @Published var themeStyle: DisplayThemeStyle {
        didSet { persist(themeStyle.rawValue, forKey: Self.accentKey); log("theme_style", themeStyle.rawValue) }
    }

    /// 字体大小档位
    @Published var fontSizeTier: DisplayFontSizeTier {
        didSet {
            persist(fontSizeTier.rawValue, forKey: Self.fontSizeKey)
            log("font_size_tier", fontSizeTier.rawValue)
            applySystemChromeAppearance(reason: "font_size_tier")
        }
    }

    /// 粗体文本（开启且使用自定义家族时顺带预热该家族的真实粗体字面——系统中文字体粗体字面独立于常规字面）
    @Published var boldTextEnabled: Bool {
        didSet {
            persist(boldTextEnabled, forKey: Self.boldKey)
            log("bold_text", "\(boldTextEnabled)")
            if boldTextEnabled && !useSystemFont && fontFamily != .system {
                ensureFontFamily(fontFamily, reason: "bold_toggle")
            }
            applySystemChromeAppearance(reason: "bold_text")
        }
    }

    /// 使用系统字体（关闭后使用所选字体家族）
    @Published var useSystemFont: Bool {
        didSet {
            persist(useSystemFont, forKey: Self.systemFontKey)
            log("use_system_font", "\(useSystemFont)")
            applySystemChromeAppearance(reason: "use_system_font")
        }
    }

    /// 字体家族（仅当关闭「使用系统字体」时作用于排版）
    @Published var fontFamily: DisplayFontFamily {
        didSet {
            persist(fontFamily.rawValue, forKey: Self.fontFamilyKey)
            log("font_family", fontFamily.rawValue)
            applySystemChromeAppearance(reason: "font_family")
        }
    }

    /// 行距系数（0.9 ~ 1.5）
    @Published var lineSpacingFactor: Double {
        didSet { persist(lineSpacingFactor, forKey: Self.lineSpacingKey) }
    }

    /// 字间距（0 ~ 2 pt）
    @Published var letterSpacingValue: Double {
        didSet { persist(letterSpacingValue, forKey: Self.trackingKey) }
    }

    /// 按钮形状（边框化按钮）
    @Published var buttonShapesEnabled: Bool {
        didSet { persist(buttonShapesEnabled, forKey: Self.buttonShapeKey); log("button_shapes", "\(buttonShapesEnabled)") }
    }

    /// 亮度（0~1；-1 表示未接管，由系统自动亮度控制）
    @Published var brightnessValue: Double {
        didSet {
            persist(brightnessValue, forKey: Self.brightnessKey)
            if !autoBrightnessEnabled && brightnessValue >= 0 {
                activeScreen?.brightness = CGFloat(brightnessValue)
            }
        }
    }

    /// 自动亮度（开启 = 系统接管）
    @Published var autoBrightnessEnabled: Bool {
        didSet {
            persist(autoBrightnessEnabled, forKey: Self.autoBrightKey)
            if autoBrightnessEnabled {
                // 交还系统控制，仅保留记录不再恢复
                brightnessValue = -1
            } else {
                // 手动接管：以当前系统亮度为起点（从上下文场景获取屏幕实例）
                if let screen = activeScreen {
                    brightnessValue = Double(screen.brightness)
                } else {
                    brightnessValue = -1
                    LogManager.shared.warning("display", "手动接管亮度时未找到可用场景屏幕，保持系统自动亮度")
                }
            }
            log("auto_brightness", "\(autoBrightnessEnabled)")
        }
    }

    /// 自动锁定（「永不」通过 isIdleTimerDisabled 真实生效；与屏幕常亮开关取或）
    @Published var autoLockOption: DisplayAutoLockOption {
        didSet {
            persist(autoLockOption.rawValue, forKey: Self.autoLockKey)
            applyIdleTimer()
            log("auto_lock", autoLockOption.rawValue)
            LogManager.shared.debugLog("display", "自动锁定联动更新 idle timer", context: [
                "idleTimerDisabled": "\(UIApplication.shared.isIdleTimerDisabled)",
                "keepAwake": "\(keepAwakeEnabled)"
            ])
        }
    }

    /// 屏幕常亮（独立于自动锁定）：开启后在本 App 前台期间阻止系统自动息屏。
    /// 经 UIApplication.isIdleTimerDisabled 真实生效；与「自动锁定=永不」逻辑或，
    /// 任一满足即常亮；两项均关闭时显式复位，杜绝残留常亮。
    @Published var keepAwakeEnabled: Bool {
        didSet {
            persist(keepAwakeEnabled, forKey: Self.keepAwakeKey)
            applyIdleTimer()
            LogManager.shared.info("display", keepAwakeEnabled ? "屏幕常亮已开启" : "屏幕常亮已关闭", context: [
                "source": "display_settings",
                "keepAwake": "\(keepAwakeEnabled)",
                "autoLock": autoLockOption.rawValue,
                "idleTimerDisabled": "\(UIApplication.shared.isIdleTimerDisabled)",
                "lowPowerMode": "\(lowPowerModeEnabled)"
            ])
            recordChange(field: "keep_awake", fieldTitle: "屏幕常亮", value: keepAwakeEnabled ? "已开启" : "已关闭")
        }
    }

    /// 统一应用空闲计时器：屏幕常亮开关 或 自动锁定「永不」任一激活，即阻止系统自动息屏。
    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwakeEnabled || autoLockOption == .never
    }

    /// 系统低电量模式状态（常亮提示联动：低电量/自适应功耗模式下系统可能强制熄屏，UI 需提示）
    @Published private(set) var lowPowerModeEnabled = false

    /// 文章正文文字颜色预设（全部渲染点即时生效：原生正文 / 机构网页原文 / 长图分享）
    @Published var articleTextColorPreset: ArticleTextColorPreset {
        didSet {
            persist(articleTextColorPreset.rawValue, forKey: Self.articleTextColorKey)
            LogManager.shared.debugLog("display", "文章正文文字颜色预设切换", context: [
                "preset": articleTextColorPreset.rawValue,
                "title": articleTextColorPreset.title,
                "lightHex": articleTextColorPreset.lightHex ?? "-",
                "darkHex": articleTextColorPreset.darkHex ?? "-"
            ])
            recordChange(field: "article_text_color", fieldTitle: "文章正文色", value: articleTextColorSummary)
        }
    }

    /// 自定义正文颜色（6 位十六进制；拖动色盘时以 0.5s 节流记录，避免日志刷屏）
    @Published var articleTextCustomHex: String {
        didSet {
            persist(articleTextCustomHex, forKey: Self.articleTextCustomHexKey)
            logCustomColorSettled()
        }
    }

    /// 自定义色日志节流时间戳
    private var lastCustomColorLogAt: Date = .distantPast

    private func logCustomColorSettled() {
        let now = Date()
        guard now.timeIntervalSince(lastCustomColorLogAt) >= 0.5 else { return }
        lastCustomColorLogAt = now
        LogManager.shared.debugLog("display", "自定义文章文字颜色变更", context: [
            "hex": articleCustomHexNormalized
        ])
    }

    // MARK: - 阅读统计设置（字数 / 时长 / 列表徽标 / 速度档位）

    /// 阅读统计总开关（关闭后正文 meta 与列表徽标均不显示）
    @Published var readingStatsEnabled: Bool {
        didSet { persist(readingStatsEnabled, forKey: Self.readingStatsKey); log("reading_stats", "\(readingStatsEnabled)") }
    }

    /// 正文字数显示开关
    @Published var readingCharCountEnabled: Bool {
        didSet { persist(readingCharCountEnabled, forKey: Self.readingCharCountKey); log("reading_char_count", "\(readingCharCountEnabled)") }
    }

    /// 预计阅读时长显示开关
    @Published var readingTimeEnabled: Bool {
        didSet { persist(readingTimeEnabled, forKey: Self.readingTimeKey); log("reading_time", "\(readingTimeEnabled)") }
    }

    /// 列表卡片阅读时长徽标开关
    @Published var readingListBadgeEnabled: Bool {
        didSet { persist(readingListBadgeEnabled, forKey: Self.readingListBadgeKey); log("reading_list_badge", "\(readingListBadgeEnabled)") }
    }

    /// 阅读速度档位（影响全文阅读时长换算，变更后已缓存结果按内容重新计算）
    @Published var readingSpeedTier: ReadingSpeedTier {
        didSet { persist(readingSpeedTier.rawValue, forKey: Self.readingSpeedKey); log("reading_speed", readingSpeedTier.rawValue) }
    }

    /// 专注灰度模式：开启后全局去饱和（根排版注入链 saturation(0)，关闭即 100% 恢复）
    @Published var grayScaleEnabled: Bool {
        didSet {
            persist(grayScaleEnabled, forKey: Self.grayScaleKey)
            log("gray_scale", "\(grayScaleEnabled)")
            LogManager.shared.info("display", grayScaleEnabled ? "专注灰度模式已开启" : "专注灰度模式已关闭", context: [
                "saturation": grayScaleEnabled ? "0" : "1",
                "source": "display_settings"
            ])
        }
    }

    /// 中文阅读速度（字/分钟）——随档位解析
    var readingCharsPerMinute: Double { readingSpeedTier.chineseCharsPerMinute }

    /// 英文阅读速度（词/分钟）——随档位解析
    var readingWordsPerMinute: Double { readingSpeedTier.englishWordsPerMinute }

    // MARK: - 系统辅助功能状态（只读监听）

    @Published private(set) var systemReduceMotion = false
    @Published private(set) var systemReduceTransparency = false
    @Published private(set) var systemDarkerColors = false
    /// VoiceOver 运行状态（新增监听，设置页辅助功能区第 5 行展示）
    @Published private(set) var systemVoiceOverRunning = false

    // MARK: - 历史（自定义色 / 变更时间轴）

    /// 自定义颜色历史（最近 6 色，新在前、去重置顶）
    @Published private(set) var customColorHistory: [String] = []
    /// 显示设置变更时间轴（最近 20 条，新在前）
    @Published private(set) var changeHistory: [DisplayChangeRecord] = []
    /// 历史持久化防抖任务（0.5s 聚合，仿 LogManager.scheduleSave）
    private var historySaveWorkItem: DispatchWorkItem?

    // MARK: - 字体可用性（系统按需下载状态）

    /// 各字体家族可用状态（system 恒 ready；下载中以 finally 状态为准）
    @Published private(set) var fontAvailability: [DisplayFontFamily: DisplayFontAvailability] = [:]
    /// 排版修订号：字体下载完成 +1，驱动全局 display* 文本重算并应用新字体
    @Published private(set) var typographyRevision = 0 {
        didSet { applySystemChromeAppearance(reason: "typography_revision") }
    }
    /// 在途下载集合（防重入）
    private var inFlightFontDownloads = Set<String>()
    /// 每次下载尝试的令牌：超时与迟到回调只作用于同一次尝试，杜绝误伤重试中的新下载（2026-09-27 完美性审查加固）
    private var fontDownloadTokens: [String: UUID] = [:]
    /// 每次尝试的最近一次系统进度回调时间（看门狗续期基准；键 = family.rawValue）
    private var fontDownloadLastProgress: [String: Date] = [:]
    /// 下载进度日志分档（每 25% 记一条，防刷屏且保留完整轨迹）
    private var fontDownloadProgressBucket: [String: Int] = [:]

    // MARK: - 初始化

    private init() {
        let d = UserDefaults.standard
        // 字体家族历史值迁移标记（init 内局部变量，日志延后到全部属性初始化完成之后）
        var didMigrateFontFamilyLegacy: String?

        appearanceMode = DisplayAppearanceMode(rawValue: d.string(forKey: Self.appearanceKey) ?? "") ?? .system
        themeStyle = DisplayThemeStyle(rawValue: d.string(forKey: Self.accentKey) ?? "") ?? .blue
        fontSizeTier = DisplayFontSizeTier(rawValue: d.string(forKey: Self.fontSizeKey) ?? "") ?? .medium
        boldTextEnabled = d.object(forKey: Self.boldKey) != nil ? d.bool(forKey: Self.boldKey) : false
        useSystemFont = d.object(forKey: Self.systemFontKey) != nil ? d.bool(forKey: Self.systemFontKey) : true
        let storedFamilyRaw = d.string(forKey: Self.fontFamilyKey) ?? ""
        let normalizedFamily = DisplayFontFamily.normalized(rawValue: storedFamilyRaw)
        fontFamily = normalizedFamily
        // 迁移历史西文字体存储值 → 立即落盘（仅用局部量，遵初始化顺序；带 didSet 的属性 init 内不可读取）
        if storedFamilyRaw != normalizedFamily.rawValue {
            d.set(normalizedFamily.rawValue, forKey: Self.fontFamilyKey)
            didMigrateFontFamilyLegacy = storedFamilyRaw
        }
        lineSpacingFactor = d.object(forKey: Self.lineSpacingKey) != nil ? d.double(forKey: Self.lineSpacingKey) : 1.0
        letterSpacingValue = d.object(forKey: Self.trackingKey) != nil ? d.double(forKey: Self.trackingKey) : 0
        buttonShapesEnabled = d.bool(forKey: Self.buttonShapeKey)

        let storedBrightness = d.object(forKey: Self.brightnessKey) as? Double
        brightnessValue = storedBrightness ?? -1
        autoBrightnessEnabled = d.object(forKey: Self.autoBrightKey) != nil ? d.bool(forKey: Self.autoBrightKey) : true
        autoLockOption = DisplayAutoLockOption(rawValue: d.string(forKey: Self.autoLockKey) ?? "") ?? .m1
        keepAwakeEnabled = d.bool(forKey: Self.keepAwakeKey)
        articleTextColorPreset = ArticleTextColorPreset(rawValue: d.string(forKey: Self.articleTextColorKey) ?? "") ?? .system
        articleTextCustomHex = d.string(forKey: Self.articleTextCustomHexKey) ?? "1A1A1A"
        readingStatsEnabled = d.object(forKey: Self.readingStatsKey) != nil ? d.bool(forKey: Self.readingStatsKey) : true
        readingCharCountEnabled = d.object(forKey: Self.readingCharCountKey) != nil ? d.bool(forKey: Self.readingCharCountKey) : true
        readingTimeEnabled = d.object(forKey: Self.readingTimeKey) != nil ? d.bool(forKey: Self.readingTimeKey) : true
        readingListBadgeEnabled = d.object(forKey: Self.readingListBadgeKey) != nil ? d.bool(forKey: Self.readingListBadgeKey) : true
        readingSpeedTier = ReadingSpeedTier(rawValue: d.string(forKey: Self.readingSpeedKey) ?? "") ?? .standard
        grayScaleEnabled = d.bool(forKey: Self.grayScaleKey)
        if let data = d.data(forKey: Self.customColorHistoryKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            customColorHistory = decoded
        }
        if let data = d.data(forKey: Self.changeHistoryKey),
           let decoded = try? JSONDecoder().decode([DisplayChangeRecord].self, from: data) {
            changeHistory = decoded
        }

        refreshSystemAccessibilityState()
        registerAccessibilityObservers()

        // 启动即恢复运行时效果（亮度接管 / 防息屏）
        applyRuntimeEffects()
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let legacy = didMigrateFontFamilyLegacy {
            LogManager.shared.info("display", "字体家族历史值迁移（西文字体→中文家族）", context: [
                "legacyRaw": legacy,
                "migrated": fontFamily.rawValue
            ])
        }
        // 字体可用性初始化 + 历史选择预热（未就绪自动触发系统下载）
        refreshFontAvailability()
        if !useSystemFont && fontFamily != .system {
            ensureFontFamily(fontFamily, reason: "startup_preheat")
        }
        // 系统渲染面（导航栏/标签栏）字体接管：启动即建立 appearance 代理，后续新建的栏继承设置字体
        applySystemChromeAppearance(reason: "startup")
        LogManager.shared.info("display", "显示设置初始化完成", context: [
            "appearance": appearanceMode.rawValue,
            "theme": themeStyle.rawValue,
            "fontTier": fontSizeTier.rawValue,
            "bold": "\(boldTextEnabled)",
            "buttonShapes": "\(buttonShapesEnabled)",
            "autoBrightness": "\(autoBrightnessEnabled)",
            "autoLock": autoLockOption.rawValue,
            "keepAwake": "\(keepAwakeEnabled)",
            "idleTimerDisabled": "\(UIApplication.shared.isIdleTimerDisabled)",
            "lowPowerMode": "\(lowPowerModeEnabled)",
            "articleTextColor": articleTextColorPreset.rawValue,
            "readingStats": "\(readingStatsEnabled)",
            "readingSpeed": readingSpeedTier.rawValue,
            "grayScale": "\(grayScaleEnabled)",
            "voiceOverRunning": "\(systemVoiceOverRunning)",
            "colorHistoryCount": "\(customColorHistory.count)",
            "changeHistoryCount": "\(changeHistory.count)"
        ])
    }

    // MARK: - 运行时效果（UIKit 桥接）

    /// 当前活跃窗口的场景屏幕（替代已弃用的 UIScreen.main）：
    /// 优先前台活跃场景 → 任意非游离场景 → 任意窗口场景
    var activeScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.screen
            ?? scenes.first(where: { $0.activationState != .unattached })?.screen
            ?? scenes.first?.screen
    }

    /// 应用持久化设置到系统运行时（启动时 / 设置变更后）
    func applyRuntimeEffects() {
        if !autoBrightnessEnabled && brightnessValue >= 0 {
            activeScreen?.brightness = CGFloat(brightnessValue)
        }
        applyIdleTimer()
        LogManager.shared.debugLog("display", "运行时效果应用（亮度/inidle timer）", context: [
            "brightnessValue": String(format: "%.2f", brightnessValue),
            "idleTimerDisabled": "\(UIApplication.shared.isIdleTimerDisabled)",
            "keepAwake": "\(keepAwakeEnabled)",
            "autoLock": autoLockOption.rawValue
        ])
    }

    /// 刷新系统辅助功能状态（含 VoiceOver）
    func refreshSystemAccessibilityState() {
        systemReduceMotion = UIAccessibility.isReduceMotionEnabled
        systemReduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        systemDarkerColors = UIAccessibility.isDarkerSystemColorsEnabled
        systemVoiceOverRunning = UIAccessibility.isVoiceOverRunning
    }

    /// 监听系统辅助功能开关变化（selector 回调 + 主线程分发，避免 Sendable 闭包转换警告）
    private func registerAccessibilityObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleAccessibilityStatusChange(_:)),
                           name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAccessibilityStatusChange(_:)),
                           name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAccessibilityStatusChange(_:)),
                           name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAccessibilityStatusChange(_:)),
                           name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAccessibilityStatusChange(_:)),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handlePowerStateChange(_:)),
                           name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    /// 系统低电量模式变化（系统主线程通知；刷新状态供常亮提示联动）
    @objc private func handlePowerStateChange(_ notification: Notification) {
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        LogManager.shared.debugLog("display", "低电量模式状态变化", context: [
            "lowPowerMode": "\(lowPowerModeEnabled)",
            "idleTimerDisabled": "\(UIApplication.shared.isIdleTimerDisabled)"
        ])
    }

    /// 系统辅助功能开关变化（这些通知均由系统在主线程发出，直接刷新 @MainActor 状态）
    @objc private func handleAccessibilityStatusChange(_ notification: Notification) {
        refreshSystemAccessibilityState()
        LogManager.shared.debugLog("display", "系统辅助功能开关变化，已刷新状态", context: [
            "name": notification.name.rawValue
        ])
    }

    /// 跳转系统设置（辅助功能 / 自动锁定等系统控制的项）
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        LogManager.shared.info("display", "跳转系统设置", context: ["target": "openSettingsURLString"])
    }

    // MARK: - 文章正文颜色解析

    /// 自定义色规范化：去杂字符、校验 6 位十六进制，非法回退墨黑
    var articleCustomHexNormalized: String {
        let cleaned = articleTextCustomHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, UInt64(cleaned, radix: 16) != nil else { return "1A1A1A" }
        return cleaned.uppercased()
    }

    /// 正文渲染色：nil = 「跟随系统」，各渲染点保持原有语义色（现状不变）；
    /// 预设色自动适配明暗模式，自定义色单色直用（所见即所得）
    var articleBodyColor: Color? {
        switch articleTextColorPreset {
        case .system: return nil
        case .custom: return Color(hex: articleCustomHexNormalized)
        default:
            guard let light = articleTextColorPreset.lightHex,
                  let dark = articleTextColorPreset.darkHex else { return nil }
            return Color(lightHex: light, darkHex: dark)
        }
    }

    /// WebView CSS 注入用浅色 hex（长图为白底渲染，同样使用浅色值）
    var articleCSSTextLightHex: String {
        switch articleTextColorPreset {
        case .system: return "1a1a1a"
        case .custom: return articleCustomHexNormalized.lowercased()
        default: return articleTextColorPreset.lightHex?.lowercased() ?? "1a1a1a"
        }
    }

    /// WebView CSS 深色模式 hex
    var articleCSSTextDarkHex: String {
        switch articleTextColorPreset {
        case .system: return "e5e5e5"
        case .custom: return articleCustomHexNormalized.lowercased()
        default: return articleTextColorPreset.darkHex?.lowercased() ?? "e5e5e5"
        }
    }

    /// 状态胶囊文案（设置页直观状态提示）
    var articleTextColorSummary: String {
        articleTextColorPreset == .system ? "跟随系统" : articleTextColorPreset.title
    }

    // MARK: - 文章 WebView 排版注入（机构子站原文页 CSS，与 SwiftUI 排版链同口径）

    /// WebView 正文 CSS 字体栈：家族名优先（CSS 规范匹配口径）+ 字面名/本地化名候选 + 系统栈兜底。
    /// 2026-09-29 真机反馈修复：此前仅注入 PostScript 字面名，WebKit 未命中 → 正文永远默认字体。
    /// 粗体不再靠切换字面（改由 font-weight !important 承担），避免破坏家族匹配。
    var articleCSSFontFamily: String {
        guard !useSystemFont, fontFamily != .system else {
            return "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Microsoft YaHei', 'Helvetica Neue', sans-serif"
        }
        let f = fontFamily
        return "'\(f.cssFamilyName)', '\(f.fontName)', '\(f.cssLocalizedFamilyName)', -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Microsoft YaHei', sans-serif"
    }

    /// 当前 WebView 排版探针家族名（document.fonts.check 用；与 articleCSSFontFamily 首候选一致）
    var articleCSSCurrentFamilyName: String {
        (!useSystemFont && fontFamily != .system) ? fontFamily.cssFamilyName : "PingFang SC"
    }

    /// WebView 正文基准字号（px）= 16 × 档位系数（与 SwiftUI 正文 `.displayText(size: 16)` 同口径）
    var articleCSSFontSize: Double { 16 * fontSizeTier.scale }

    /// WebView 正文行高（倍数）：以 1.85 为基线按行距系数平移（系数 1.0 → 1.85，与纯文本模式观感一致）
    var articleCSSLineHeight: Double { 0.85 + lineSpacingFactor }

    /// WebView 正文字间距（px，与 SwiftUI `.tracking` 同值同单位）
    var articleCSSLetterSpacing: Double { letterSpacingValue }

    /// WebView 正文粗细：开启「粗体文本」时 700，否则 400
    var articleCSSFontWeight: Int { boldTextEnabled ? 700 : 400 }

    /// WebView 排版一行式 CSS 属性表（每项 !important：压过官网原文 CMS 自带内联样式；
    /// 2026-09-29 真机反馈强化——正文此前"永远默认"即因继承规则败给内联样式）
    /// 2026-10-02 深色模式修复：追加 `color: var(--text-color) !important`，让正文文字颜色完全
    /// 跟随显示设置（浅色 #1a1a1a / 深色 #e5e5e5），压制原文 `<span style="color:rgb(0,0,0)">`
    /// 等内联色——否则深色模式下黑字黑底不可见（正文在 WebView 内，链接专属色由 buildHTMLPage 的
    /// `a { color: var(--link-color) }` 规则单独保护，本声明只作用普通正文元素）。
    var articleCSSTypographyDeclaration: String {
        String(
            format: "font-family: %@ !important; font-size: %.1fpx !important; line-height: %.2f !important; letter-spacing: %.2fpx !important; font-weight: %d !important; color: var(--text-color) !important;",
            articleCSSFontFamily,
            articleCSSFontSize,
            articleCSSLineHeight,
            articleCSSLetterSpacing,
            articleCSSFontWeight
        )
    }

    /// WebView 排版规则块（body 及全部后代，置入 style#sjz-typography）：
    /// 官网原文的字体多写在元素内联 style / <font> 上，继承不敌直接声明——必须后代全选 + !important
    var articleCSSTypographyRuleBlock: String {
        "body, body * { \(articleCSSTypographyDeclaration) }"
    }

    /// WebView 排版实时重注入载荷（含修订号注释：字体下载完成后 revision 变化 → 载荷变化 →
    /// `updateUIView` 触发重注入并强制重绘，新字面即时生效；2026-09-29 实时更新链）
    var articleCSSLiveInjectionPayload: String {
        "\(articleCSSTypographyRuleBlock) /* r\(typographyRevision) */"
    }

    /// WebView 排版注入日志上下文字典（两处模板共用，完整埋点）
    var articleCSSTypographyLogContext: [String: String] {
        [
            "family": useSystemFont ? "system" : fontFamily.rawValue,
            "tier": fontSizeTier.rawValue,
            "fontSizePx": String(format: "%.1f", articleCSSFontSize),
            "lineHeight": String(format: "%.2f", articleCSSLineHeight),
            "letterSpacingPx": String(format: "%.2f", articleCSSLetterSpacing),
            "bold": "\(boldTextEnabled)",
            "fontStack": articleCSSFontFamily
        ]
    }

    // MARK: - 非隔离快照（主线程外上下文：长图渲染器等）

    /// 从 UserDefaults 直读正文浅色 hex（线程安全），供非主线程渲染上下文解析配色
    nonisolated static func articleBodyLightHexSnapshot() -> (presetRaw: String, hex: String) {
        let presetRaw = UserDefaults.standard.string(forKey: Self.articleTextColorKey) ?? ""
        let preset = ArticleTextColorPreset(rawValue: presetRaw) ?? .system
        let hex: String
        switch preset {
        case .system:
            hex = "1a1a1a"
        case .custom:
            let raw = UserDefaults.standard.string(forKey: Self.articleTextCustomHexKey) ?? "1A1A1A"
            let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            hex = (cleaned.count == 6 && UInt64(cleaned, radix: 16) != nil ? cleaned : "1A1A1A").lowercased()
        default:
            hex = preset.lightHex?.lowercased() ?? "1a1a1a"
        }
        return (presetRaw, hex)
    }

    // MARK: - 默认 / 重置

    /// 非默认设置计数（Hero 徽章 / 设置入口摘要徽标共用；清单与 isDefault 严格一致）
    var nonDefaultChangeCount: Int {
        var count = 0
        if appearanceMode != .system { count += 1 }
        if themeStyle != .blue { count += 1 }
        if fontSizeTier != .medium { count += 1 }
        if boldTextEnabled { count += 1 }
        if !useSystemFont { count += 1 }
        if fontFamily != .system { count += 1 }
        if abs(lineSpacingFactor - 1.0) > 0.001 { count += 1 }
        if letterSpacingValue > 0.001 { count += 1 }
        if buttonShapesEnabled { count += 1 }
        if articleTextColorPreset != .system { count += 1 }
        if !autoBrightnessEnabled { count += 1 }
        if autoLockOption != .m1 { count += 1 }
        if keepAwakeEnabled { count += 1 }
        if grayScaleEnabled { count += 1 }
        if !readingStatsEnabled { count += 1 }
        if !readingCharCountEnabled { count += 1 }
        if !readingTimeEnabled { count += 1 }
        if !readingListBadgeEnabled { count += 1 }
        if readingSpeedTier != .standard { count += 1 }
        return count
    }

    /// 是否处于默认状态
    var isDefault: Bool {
        appearanceMode == .system
            && themeStyle == .blue
            && fontSizeTier == .medium
            && !boldTextEnabled
            && useSystemFont
            && fontFamily == .system
            && abs(lineSpacingFactor - 1.0) <= 0.001
            && letterSpacingValue <= 0.001
            && !buttonShapesEnabled
            && autoBrightnessEnabled
            && autoLockOption == .m1
            && !keepAwakeEnabled
            && articleTextColorPreset == .system
            && readingStatsEnabled
            && readingCharCountEnabled
            && readingTimeEnabled
            && readingListBadgeEnabled
            && readingSpeedTier == .standard
            && !grayScaleEnabled
    }

    /// 恢复全部默认值（撤销亮度接管与防息屏）
    func resetAll() {
        appearanceMode = .system
        themeStyle = .blue
        fontSizeTier = .medium
        boldTextEnabled = false
        useSystemFont = true
        fontFamily = .system
        lineSpacingFactor = 1.0
        letterSpacingValue = 0
        buttonShapesEnabled = false
        autoBrightnessEnabled = true
        brightnessValue = -1
        autoLockOption = .m1
        keepAwakeEnabled = false
        articleTextColorPreset = .system
        articleTextCustomHex = "1A1A1A"
        readingStatsEnabled = true
        readingCharCountEnabled = true
        readingTimeEnabled = true
        readingListBadgeEnabled = true
        readingSpeedTier = .standard
        grayScaleEnabled = false
        customColorHistory = []
        changeHistory = []
        persistHistories()
        applyIdleTimer()
        LogManager.shared.info("display", "恢复默认显示设置", context: ["reset": "all"])
    }

    // MARK: - 字体按需下载（系统级一次性下载，之后离线可用）

    /// 刷新全部字体家族可用状态（system 恒就绪；其余以 UIFont 实查为准；在途下载保持 downloading 进度）
    func refreshFontAvailability() {
        var states: [DisplayFontFamily: DisplayFontAvailability] = [:]
        for family in DisplayFontFamily.allCases {
            if family == .system {
                states[family] = .ready
            } else if inFlightFontDownloads.contains(family.rawValue) {
                if case .downloading(let percent) = fontAvailability[family] {
                    states[family] = .downloading(percent: percent)
                } else {
                    states[family] = .downloading(percent: nil)
                }
            } else {
                states[family] = (UIFont(name: family.fontName, size: 17) != nil) ? .ready : .unavailable
            }
        }
        fontAvailability = states
    }

    /// 停滞阈值（秒）：以「最近一次系统进度回调」为基准的看门狗——
    /// 系统仍在报进度就不判超时（行楷-简实测资产 54.7MB，慢网耗时远超 60s）；
    /// 连续无进展才复位为「未下载·可重试」（2026-09-27 由绝对时长语义升级为「无进展」语义）
    private static let fontDownloadStallSeconds: TimeInterval = 60
    /// 看门狗轮询间隔（秒）
    private static let fontDownloadWatchdogTickSeconds: UInt64 = 5

    /// 确保字体家族就绪：已就绪直接返回；未就绪触发系统按需下载（完成自动驱动全 App 字体刷新）。
    /// 请求字面 = 主字面 +（开启粗体文本时）粗体字面，一次匹配调用合并请求、合并进度
    func ensureFontFamily(_ family: DisplayFontFamily, reason: String) {
        guard family != .system else { return }
        refreshFontAvailability()
        let wantedFaces = family.downloadFaceNames(includeBold: boldTextEnabled)
        let missingFaces = wantedFaces.filter { UIFont(name: $0, size: 17) == nil }
        guard !missingFaces.isEmpty else {
            LogManager.shared.debugLog("display", "字体家族已就绪", context: [
                "family": family.rawValue,
                "faces": wantedFaces.joined(separator: ","),
                "reason": reason
            ])
            return
        }
        guard !inFlightFontDownloads.contains(family.rawValue) else {
            LogManager.shared.debugLog("display", "字体家族下载已在途，忽略重复触发", context: [
                "family": family.rawValue,
                "reason": reason
            ])
            return
        }
        let attemptToken = UUID()
        fontDownloadTokens[family.rawValue] = attemptToken
        inFlightFontDownloads.insert(family.rawValue)
        fontDownloadLastProgress[family.rawValue] = Date()
        fontDownloadProgressBucket.removeValue(forKey: family.rawValue)
        fontAvailability[family] = .downloading(percent: nil)
        LogManager.shared.info("display", "字体按需下载开始", context: [
            "family": family.rawValue,
            "title": family.title,
            "faces": missingFaces.joined(separator: ","),
            "includeBold": "\(boldTextEnabled)",
            "reason": reason
        ])
        // 系统匹配：多字面合并为一次调用（进度为合并进度；只认 PostScript 字面名，见 DisplayFontFamily.fontName 契约）
        let descriptors = missingFaces.map { face -> CTFontDescriptor in
            CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: face] as CFDictionary)
        }
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { [weak self] state, progressParameter in
            let info = (progressParameter as NSDictionary?) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleFontMatchingCallback(state: state, info: info, family: family, token: attemptToken, requestedFaces: missingFaces)
            }
            return true
        }
        // 停滞看门狗：令牌匹配才生效；连续无进展 → 终态收尾（可重试，UI 橙色徽章）
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.fontDownloadWatchdogTickSeconds * 1_000_000_000)
                guard let self, self.fontDownloadTokens[family.rawValue] == attemptToken else { return }
                let last = self.fontDownloadLastProgress[family.rawValue] ?? Date()
                guard Date().timeIntervalSince(last) > Self.fontDownloadStallSeconds else { continue }
                self.finalizeFontDownload(family: family, token: attemptToken, outcome: .stalled, diagnostic: nil)
                return
            }
        }
    }

    /// 批量确保全部家族就绪（「全部下载」入口：未就绪家族各发起一次，独立进度与独立重试）
    func ensureAllFontFamilies(reason: String) {
        let targets = DisplayFontFamily.allCases.filter { family in
            family != .system && UIFont(name: family.fontName, size: 17) == nil
        }
        guard !targets.isEmpty else {
            refreshFontAvailability()
            LogManager.shared.debugLog("display", "全部字体家族已就绪，无需批量下载", context: ["reason": reason])
            return
        }
        LogManager.shared.info("display", "字体批量下载开始", context: [
            "families": targets.map(\.rawValue).joined(separator: ","),
            "count": "\(targets.count)",
            "reason": reason
        ])
        for family in targets {
            ensureFontFamily(family, reason: reason)
        }
    }

    /// 字体匹配进度回调（主线程）：续期看门狗 → 进度/里程碑日志 → 终态收尾
    private func handleFontMatchingCallback(
        state: CTFontDescriptorMatchingState,
        info: [String: Any],
        family: DisplayFontFamily,
        token: UUID,
        requestedFaces: [String]
    ) {
        // 迟到回调（本尝试已收尾、或已有新尝试在途）一律忽略，避免误伤重试
        guard fontDownloadTokens[family.rawValue] == token else { return }
        fontDownloadLastProgress[family.rawValue] = Date()
        switch state {
        case .didBegin:
            LogManager.shared.debugLog("display", "字体匹配开始", context: [
                "family": family.rawValue,
                "faces": requestedFaces.joined(separator: ",")
            ])
        case .willBeginQuerying:
            break   // 进入查询阶段（瞬时态，无用户可感信息，避免日志噪声）
        case .willBeginDownloading:
            LogManager.shared.info("display", "字体资产开始下载", context: [
                "family": family.rawValue,
                "localizedFamily": "\(info["CTFontDescriptorMatchingLocalizedFamilyName"] ?? "-")",
                "assetCount": "\(info["CTFontDescriptorMatchingTotalAssetCount"] ?? "-")",
                "totalBytes": "\(info["CTFontDescriptorMatchingTotalAssetSize"] ?? "-")"
            ])
        case .downloading, .stalled:
            // stalled 为系统分块间隙的正常回传（与 downloading 交替出现），不视为异常
            guard let percent = info["CTFontDescriptorMatchingPercentage"] as? Double else { break }
            let rounded = percent.rounded(.down)
            if case .downloading(let current) = fontAvailability[family], let current, abs(rounded - current) < 1 {
                break   // 进度变化 <1% 不刷新 UI，防高频重渲染
            }
            fontAvailability[family] = .downloading(percent: rounded)
            let bucket = min(4, Int(rounded / 25))
            if fontDownloadProgressBucket[family.rawValue] != bucket {
                fontDownloadProgressBucket[family.rawValue] = bucket
                let eta = (info["CTFontDescriptorMatchingEstimatedSecondsRemaining"] as? Double).map { String(format: "%.0f", $0) } ?? "-"
                LogManager.shared.debugLog("display", "字体下载进度", context: [
                    "family": family.rawValue,
                    "percent": "\(Int(rounded))",
                    "downloadedBytes": "\(info["CTFontDescriptorMatchingTotalDownloadedSize"] ?? "-")",
                    "totalBytes": "\(info["CTFontDescriptorMatchingTotalAssetSize"] ?? "-")",
                    "etaSeconds": eta
                ])
            }
        case .didFinishDownloading:
            LogManager.shared.info("display", "字体资产传输完成，等待系统安装生效", context: [
                "family": family.rawValue,
                "downloadedBytes": "\(info["CTFontDescriptorMatchingTotalDownloadedSize"] ?? "-")"
            ])
        case .didMatch:
            LogManager.shared.info("display", "字体字面匹配成功", context: ["family": family.rawValue])
        case .didFailWithError:
            finalizeFontDownload(family: family, token: token, outcome: .failed, diagnostic: Self.fontMatchingDiagnostic(info))
        case .didFinish:
            // 终局：didFinish 在「匹配成功」与「无匹配静默完成（历史家族名缺陷形态）」两种情形都会回传——必须以实查判定成败
            finalizeFontDownload(family: family, token: token, outcome: .finished, diagnostic: Self.fontMatchingDiagnostic(info))
        @unknown default:
            break
        }
    }

    /// 下载终态类型（统一收尾路径）
    private enum FontDownloadOutcome {
        case finished   // 系统匹配流程正常结束（成功与否以实查判定）
        case failed     // didFailWithError
        case stalled    // 看门狗触发（连续无进度）
    }

    /// 下载终态收尾：实查自愈 / 就绪生效 / 失败与停滞复位，并归档完整日志
    private func finalizeFontDownload(
        family: DisplayFontFamily,
        token: UUID,
        outcome: FontDownloadOutcome,
        diagnostic: String?
    ) {
        guard fontDownloadTokens[family.rawValue] == token else { return }
        fontDownloadTokens.removeValue(forKey: family.rawValue)
        inFlightFontDownloads.remove(family.rawValue)
        fontDownloadLastProgress.removeValue(forKey: family.rawValue)
        fontDownloadProgressBucket.removeValue(forKey: family.rawValue)

        // 实查自愈：无论何种终态，只要主字面已落地即视为就绪（覆盖「下载完成与终态回调之间的空窗」）
        let primaryReady = UIFont(name: family.fontName, size: 17) != nil
        let boldFace = family.boldFontName
        let boldReady = boldFace.map { UIFont(name: $0, size: 17) != nil } ?? false

        switch outcome {
        case .stalled:
            if primaryReady {
                fontAvailability[family] = .ready
                typographyRevision += 1
                LogManager.shared.info("display", "字体下载停滞但实查已就绪（自愈）", context: [
                    "family": family.rawValue,
                    "boldFaceReady": boldFace == nil ? "无独立字面" : "\(boldReady)"
                ])
            } else {
                fontAvailability[family] = .unavailable
                // 状态流转（已转「可重试」态）而非待处理异常：INFO 级完整记录，警告栏只留真异常（2026-09-27 警告栏净化）；
                // 用户可操作入口由 UI 橙色徽章呈现（点击重新发起下载）
                LogManager.shared.info("display", "字体下载停滞超时，已转为可重试状态", context: [
                    "family": family.rawValue,
                    "stallSeconds": "\(Int(Self.fontDownloadStallSeconds))",
                    "action": "转为可重试（橙色徽章），点击后重新发起下载"
                ])
            }
        case .failed:
            if primaryReady {
                fontAvailability[family] = .ready
                typographyRevision += 1
            } else {
                fontAvailability[family] = .unavailable
            }
            LogManager.shared.warning("display", "字体按需下载失败（可点击重试）", context: [
                "family": family.rawValue,
                "faces": family.downloadFaceNames(includeBold: boldTextEnabled).joined(separator: ","),
                "diagnostic": diagnostic ?? "-",
                "primaryReady": "\(primaryReady)"
            ])
        case .finished:
            if primaryReady {
                fontAvailability[family] = .ready
                // 修订号 +1：驱动所有 display* 文本重建字体值，下载完成即刻全局生效
                typographyRevision += 1
                LogManager.shared.info("display", "字体按需下载完成并已全局生效", context: [
                    "family": family.rawValue,
                    "title": family.title,
                    "boldFaceReady": boldFace == nil ? "无独立字面" : "\(boldReady)",
                    "revision": "\(typographyRevision)"
                ])
            } else {
                fontAvailability[family] = .unavailable
                LogManager.shared.warning("display", "字体匹配结束但未取得字面（可点击重试）", context: [
                    "family": family.rawValue,
                    "faces": family.downloadFaceNames(includeBold: boldTextEnabled).joined(separator: ","),
                    "diagnostic": diagnostic ?? "-",
                    "hint": "PostScript 字面名或系统目录不匹配；已复位为可重试"
                ])
            }
        }
    }

    /// 系统匹配回调的诊断描述（错误 / 结果），用于失败日志取证（截断超长输出）
    private static func fontMatchingDiagnostic(_ info: [String: Any]) -> String? {
        for key in ["CTFontDescriptorMatchingError", "CTFontDescriptorMatchingResult"] {
            guard let value = info[key] else { continue }
            if let error = value as? NSError {
                return "[\(error.domain) \(error.code)] \(error.localizedDescription)"
            }
            let text = String(describing: value)
            return text.count > 300 ? String(text.prefix(300)) + "…" : text
        }
        return nil
    }

    func logSliderSettled(_ field: String, _ value: Double) {
        LogManager.shared.debugLog("display", "滑块调整完成", context: [field: String(format: "%.3f", value)])
        switch field {
        case "line_spacing":
            recordChange(field: field, fieldTitle: "行距", value: String(format: "%.2f×", value))
        case "letter_spacing":
            recordChange(field: field, fieldTitle: "字间距", value: String(format: "%.2f pt", value))
        case "brightness":
            recordChange(field: field, fieldTitle: "屏幕亮度", value: "\(Int((value * 100).rounded()))%")
        default:
            break
        }
    }

    // MARK: - 变更时间轴

    /// 时间轴记录（最近 20 条，新在前；0.5s 防抖持久化）
    func recordChange(field: String, fieldTitle: String, value: String) {
        let record = DisplayChangeRecord(id: UUID(), field: field, fieldTitle: fieldTitle, value: value, at: Date())
        changeHistory = DisplayHistoryOperator.appendChange(record, into: changeHistory)
        scheduleHistorySave()
    }

    /// 历史持久化防抖（0.5s 聚合写入，避免滑块等高频输入刷盘）
    private func scheduleHistorySave() {
        historySaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistHistories()
        }
        historySaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persistHistories() {
        if let data = try? JSONEncoder().encode(customColorHistory) {
            UserDefaults.standard.set(data, forKey: Self.customColorHistoryKey)
        }
        if let data = try? JSONEncoder().encode(changeHistory) {
            UserDefaults.standard.set(data, forKey: Self.changeHistoryKey)
        }
    }

    // MARK: - 排版方案 / 颜色历史 / 摘要

    /// 一键套用排版方案（6 项排版值；返回 Toast 文案）
    @discardableResult
    func applyScheme(_ scheme: DisplaySchemePreset) -> String {
        let before = [
            "tier": fontSizeTier.rawValue,
            "lineSpacing": String(format: "%.2f", lineSpacingFactor),
            "letterSpacing": String(format: "%.2f", letterSpacingValue),
            "bold": "\(boldTextEnabled)",
            "systemFont": "\(useSystemFont)",
            "family": fontFamily.rawValue
        ]
        fontSizeTier = scheme.fontSizeTier
        lineSpacingFactor = scheme.lineSpacing
        letterSpacingValue = scheme.letterSpacing
        boldTextEnabled = scheme.boldText
        useSystemFont = scheme.useSystemFont
        fontFamily = scheme.fontFamily
        LogManager.shared.info("display", "排版方案套用完成", context: [
            "scheme": scheme.rawValue,
            "schemeTitle": scheme.title,
            "beforeTier": before["tier"] ?? "-",
            "afterTier": fontSizeTier.rawValue,
            "beforeLineSpacing": before["lineSpacing"] ?? "-",
            "afterLineSpacing": String(format: "%.2f", lineSpacingFactor),
            "beforeLetterSpacing": before["letterSpacing"] ?? "-",
            "afterLetterSpacing": String(format: "%.2f", letterSpacingValue),
            "beforeBold": before["bold"] ?? "-",
            "afterBold": "\(boldTextEnabled)",
            "beforeSystemFont": before["systemFont"] ?? "-",
            "afterSystemFont": "\(useSystemFont)",
            "beforeFamily": before["family"] ?? "-",
            "afterFamily": fontFamily.rawValue
        ])
        // 方案引入的新家族若未就绪，触发系统下载（就绪后全 App 自动生效）
        if !useSystemFont && fontFamily != .system {
            ensureFontFamily(fontFamily, reason: "scheme_apply")
        }
        return "已套用「\(scheme.title)」方案"
    }

    /// 自定义颜色入史（去重置顶、截断 6、仅合法 6 位 hex）
    func pushCustomColor(_ hex: String) {
        let before = customColorHistory
        customColorHistory = DisplayHistoryOperator.pushColor(hex, into: customColorHistory)
        guard customColorHistory != before else { return }
        persistHistories()
        LogManager.shared.debugLog("display", "自定义颜色入史", context: [
            "hex": customColorHistory.first ?? "-",
            "count": "\(customColorHistory.count)"
        ])
    }

    func clearCustomColorHistory() {
        guard !customColorHistory.isEmpty else { return }
        let count = customColorHistory.count
        customColorHistory = []
        persistHistories()
        LogManager.shared.info("display", "自定义颜色历史已清空", context: ["cleared": "\(count)"])
    }

    func clearChangeHistory() {
        guard !changeHistory.isEmpty else { return }
        let count = changeHistory.count
        changeHistory = []
        persistHistories()
        LogManager.shared.info("display", "变更时间轴已清空", context: ["cleared": "\(count)"])
    }

    /// 当前显示配置摘要（分享用；多行中文文本）
    func shareSummaryText() -> String {
        var lines: [String] = []
        lines.append("【园枢 · 显示配置摘要】")
        lines.append("外观模式：\(appearanceMode.title)")
        lines.append("主题色：\(themeStyle.title)")
        lines.append("字体大小：\(fontSizeTier.title)")
        lines.append("粗体文本：\(boldTextEnabled ? "已开启" : "已关闭")")
        lines.append("字体样式：\(useSystemFont ? "系统默认" : fontFamily.title)")
        lines.append(String(format: "行距：%.2f×", lineSpacingFactor))
        lines.append(String(format: "字间距：%.2f pt", letterSpacingValue))
        lines.append("按钮形状：\(buttonShapesEnabled ? "已开启" : "已关闭")")
        lines.append("文章正文色：\(articleTextColorSummary)")
        if readingStatsEnabled {
            lines.append("阅读统计：已开启（\(readingSpeedTier.title)）")
        } else {
            lines.append("阅读统计：已关闭")
        }
        lines.append(autoBrightnessEnabled ? "亮度：系统自动" : "亮度：\(Int((brightnessValue * 100).rounded()))%")
        lines.append("自动锁定：\(autoLockOption.title)")
        lines.append("屏幕常亮：\(keepAwakeEnabled ? "已开启" : "已关闭")")
        lines.append("专注灰度：\(grayScaleEnabled ? "已开启" : "已关闭")")
        return lines.joined(separator: "\n")
    }

    // MARK: - 持久化与日志

    private func persist(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// 字段键 → 时间轴中文描述（未知键返回 nil，仅已知字段入轴）
    private static func changeDescription(field: String, rawValue: String) -> (title: String, text: String)? {
        switch field {
        case "appearance":
            guard let mode = DisplayAppearanceMode(rawValue: rawValue) else { return nil }
            return ("外观模式", mode.title)
        case "theme_style":
            guard let style = DisplayThemeStyle(rawValue: rawValue) else { return nil }
            return ("主题色", style.title)
        case "font_size_tier":
            guard let tier = DisplayFontSizeTier(rawValue: rawValue) else { return nil }
            return ("字体大小", tier.title)
        case "bold_text":
            return ("粗体文本", rawValue == "true" ? "已开启" : "已关闭")
        case "use_system_font":
            return ("系统字体", rawValue == "true" ? "已开启" : "已关闭")
        case "font_family":
            let family = DisplayFontFamily.normalized(rawValue: rawValue)
            return ("字体样式", family.title)
        case "button_shapes":
            return ("按钮形状", rawValue == "true" ? "已开启" : "已关闭")
        case "auto_lock":
            guard let option = DisplayAutoLockOption(rawValue: rawValue) else { return nil }
            return ("自动锁定", option.title)
        case "reading_stats":
            return ("阅读统计", rawValue == "true" ? "已开启" : "已关闭")
        case "reading_char_count":
            return ("正文字数", rawValue == "true" ? "已开启" : "已关闭")
        case "reading_time":
            return ("阅读时长", rawValue == "true" ? "已开启" : "已关闭")
        case "reading_list_badge":
            return ("列表阅读角标", rawValue == "true" ? "已开启" : "已关闭")
        case "reading_speed":
            guard let tier = ReadingSpeedTier(rawValue: rawValue) else { return nil }
            return ("阅读速度", tier.title)
        case "auto_brightness":
            return ("自动亮度", rawValue == "true" ? "已开启" : "已关闭")
        case "gray_scale":
            return ("专注灰度模式", rawValue == "true" ? "已开启" : "已关闭")
        default:
            return nil
        }
    }

    private func log(_ field: String, _ value: String) {
        LogManager.shared.debugLog("display", "显示设置变更", context: [field: value])
        if let desc = Self.changeDescription(field: field, rawValue: value) {
            recordChange(field: field, fieldTitle: desc.title, value: desc.text)
        }
    }
}

// MARK: - 环境键（全局排版注入）

private struct DisplayFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

private struct DisplayBoldKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DisplayFontFamilyEnvKey: EnvironmentKey {
    static let defaultValue = DisplayFontFamily.system
}

private struct DisplayLetterSpacingKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

private struct DisplayLineSpacingKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

private struct DisplayTypographyRevisionKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var displayFontScale: CGFloat {
        get { self[DisplayFontScaleKey.self] }
        set { self[DisplayFontScaleKey.self] = newValue }
    }

    var displayBold: Bool {
        get { self[DisplayBoldKey.self] }
        set { self[DisplayBoldKey.self] = newValue }
    }

    var displayFontFamily: DisplayFontFamily {
        get { self[DisplayFontFamilyEnvKey.self] }
        set { self[DisplayFontFamilyEnvKey.self] = newValue }
    }

    var displayLetterSpacing: Double {
        get { self[DisplayLetterSpacingKey.self] }
        set { self[DisplayLetterSpacingKey.self] = newValue }
    }

    var displayLineSpacing: Double {
        get { self[DisplayLineSpacingKey.self] }
        set { self[DisplayLineSpacingKey.self] = newValue }
    }

    var displayTypographyRevision: Int {
        get { self[DisplayTypographyRevisionKey.self] }
        set { self[DisplayTypographyRevisionKey.self] = newValue }
    }
}

// MARK: - 字体工厂

/// 显示设置字体工厂：档位缩放 + 粗体 + 家族组装。
/// 自定义家族一律走 PostScript 字面名（Font.custom / UIFont 只认字面名）；
/// 开启粗体时若该家族的真实粗体字面已就绪则直接用字面（中式字形合成加粗观感差），否则回退主字面加粗
enum DisplayFontFactory {
    static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        scale: CGFloat = 1,
        family: DisplayFontFamily = .system,
        bold: Bool = false
    ) -> Font {
        let resolvedSize = size * scale
        switch family {
        case .system:
            return .system(size: resolvedSize, weight: bold ? .bold : weight)
        default:
            if bold, let boldFace = family.boldFontName, UIFont(name: boldFace, size: resolvedSize) != nil {
                return .custom(boldFace, size: resolvedSize)
            }
            let resolvedWeight: Font.Weight = bold ? .bold : weight
            return .custom(family.fontName, size: resolvedSize).weight(resolvedWeight)
        }
    }
}

// MARK: - UIKit 字体工厂（系统渲染面专用）

/// UIKit 字体工厂：与 `DisplayFontFactory` 同源策略（PostScript 字面名 + 档位缩放 + 粗体字面优先/回退），
/// 供 **UIKit 绘制的系统渲染面** 使用——`UINavigationBar` 标题与 `UITabBar` 标签由系统绘制，
/// SwiftUI 的 `display*` 修饰器物理上无法触及（2026-09-29 全局接管；系统弹窗遵循 HIG 保持系统样式）。
enum DisplayUIFontFactory {
    static func uiFont(
        size: CGFloat,
        weight: UIFont.Weight = .regular,
        scale: CGFloat,
        family: DisplayFontFamily,
        bold: Bool
    ) -> UIFont {
        let resolved = size * scale
        switch family {
        case .system:
            return .systemFont(ofSize: resolved, weight: bold ? .bold : weight)
        default:
            if bold, let boldFace = family.boldFontName, let face = UIFont(name: boldFace, size: resolved) {
                return face
            }
            guard let base = UIFont(name: family.fontName, size: resolved) else {
                // 家族未就绪/字面名不可用：回退系统字体（与 SwiftUI 工厂一致）
                return .systemFont(ofSize: resolved, weight: bold ? .bold : weight)
            }
            let wantsBold = bold || weight.rawValue >= UIFont.Weight.semibold.rawValue
            if wantsBold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
                return UIFont(descriptor: descriptor, size: resolved)
            }
            return base
        }
    }
}

// MARK: - 排版快照（后台渲染上下文专用）

extension DisplaySettingsManager {
    /// 排版快照：从 UserDefaults 直读当前显示设置（供长图等后台渲染上下文使用，
    /// 避免跨 actor 访问 @MainActor 单例；与 `articleBodyLightHexSnapshot` 同范式）。
    struct TypographySnapshot {
        let family: DisplayFontFamily
        let scale: CGFloat
        let bold: Bool
        let lineSpacingFactor: Double
        let letterSpacing: Double
    }

    nonisolated static func typographySnapshot() -> TypographySnapshot {
        let d = UserDefaults.standard
        let useSystem = d.object(forKey: Self.systemFontKey) != nil ? d.bool(forKey: Self.systemFontKey) : true
        let family: DisplayFontFamily = useSystem
            ? .system
            : DisplayFontFamily.normalized(rawValue: d.string(forKey: Self.fontFamilyKey) ?? "")
        let tier = DisplayFontSizeTier(rawValue: d.string(forKey: Self.fontSizeKey) ?? "") ?? .medium
        let bold = d.object(forKey: Self.boldKey) != nil ? d.bool(forKey: Self.boldKey) : false
        let lineSpacing = d.object(forKey: Self.lineSpacingKey) != nil ? d.double(forKey: Self.lineSpacingKey) : 1.0
        let letterSpacing = d.object(forKey: Self.trackingKey) != nil ? d.double(forKey: Self.trackingKey) : 0
        return TypographySnapshot(
            family: family,
            scale: tier.scale,
            bold: bold,
            lineSpacingFactor: lineSpacing,
            letterSpacing: letterSpacing
        )
    }
}

// MARK: - 系统渲染面全局接管（导航栏 / 标签栏）

extension DisplaySettingsManager {
    /// 签名门控：家族/档位/粗体三要素未变化时跳过重刷（防启动期重复调用刷屏）
    private static var lastChromeSignature: String = ""

    /// 全局接管 UIKit 绘制面的字体（导航栏标题 62 处 + Tab 标签 5 枚，一处生效）：
    /// ① appearance 代理——覆盖之后新建的栏；② 场景内既有栏实例——复制现外观后仅重写字体属性
    /// （不动背景/材质，规避视觉回归）；③ 延迟补刷——SwiftUI 会在屏幕更新周期重设栏外观，变更后
    /// 0.35s/1.2s 各补一次（幂等，仅改字体）。系统弹窗（alert/确认框）由系统渲染，遵循 HIG 不接管。
    func applySystemChromeAppearance(reason: String) {
        let scale = fontSizeTier.scale
        let family = useSystemFont ? .system : fontFamily
        let bold = boldTextEnabled

        // 先解析字体、再生成签名（2026-09-29 真机日志驱动修复）：
        // 字体资产「按需下载」期间工厂会回退系统字体，下载完成后回退字体 → 目标字体；
        // 旧的「家族|档位|粗体」签名对这种就绪态变化不敏感，会把下载完成后的重刷误判为
        // 「无变化」而跳过，导致导航栏/标签栏停留在系统字体。签名纳入解析后字体名/字号即可感知。
        let titleFont = DisplayUIFontFactory.uiFont(size: 17, weight: .semibold, scale: scale, family: family, bold: bold)
        let largeFont = DisplayUIFontFactory.uiFont(size: 34, weight: .bold, scale: scale, family: family, bold: bold)
        let itemFont = DisplayUIFontFactory.uiFont(size: 10, weight: .medium, scale: scale, family: family, bold: bold)
        let signature = "\(family.rawValue)|\(String(format: "%.2f", scale))|\(bold)"
            + "|\(titleFont.fontName)@\(titleFont.pointSize)|\(largeFont.fontName)|\(itemFont.fontName)"
        guard signature != Self.lastChromeSignature || reason == "startup" else {
            LogManager.shared.debugLog("display", "系统渲染面字体无变化，跳过重刷", context: ["reason": reason])
            return
        }
        Self.lastChromeSignature = signature

        Self.applyChromeToProxies(titleFont: titleFont, largeFont: largeFont, itemFont: itemFont)
        let counts = Self.applyChromeToExistingBars(titleFont: titleFont, largeFont: largeFont, itemFont: itemFont)

        LogManager.shared.info("display", "系统渲染面字体接管已刷新", context: [
            "reason": reason,
            "family": family.rawValue,
            "scale": String(format: "%.2f", scale),
            "bold": "\(bold)",
            "navBars": "\(counts.nav)",
            "tabBars": "\(counts.tab)",
            "titleFont": titleFont.fontName,
            "titleSize": String(format: "%.1f", titleFont.pointSize),
            "mechanism": "UINavigationBarAppearance/UITabBarAppearance + 既有实例就地刷新"
        ])

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let pass1 = Self.applyChromeToExistingBars(titleFont: titleFont, largeFont: largeFont, itemFont: itemFont)
            try? await Task.sleep(nanoseconds: 850_000_000)
            let pass2 = Self.applyChromeToExistingBars(titleFont: titleFont, largeFont: largeFont, itemFont: itemFont)
            LogManager.shared.debugLog("display", "系统渲染面字体延迟补刷完成", context: [
                "reason": reason,
                "pass1Nav": "\(pass1.nav)",
                "pass2Nav": "\(pass2.nav)",
                "pass2Tab": "\(pass2.tab)"
            ])
        }
    }

    /// appearance 代理：对之后新建的栏生效（背景配置取系统默认材质，仅重写字体属性）
    private static func applyChromeToProxies(titleFont: UIFont, largeFont: UIFont, itemFont: UIFont) {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.titleTextAttributes = [.font: titleFont]
        nav.largeTitleTextAttributes = [.font: largeFont]
        let navProxy = UINavigationBar.appearance()
        navProxy.standardAppearance = nav
        navProxy.compactAppearance = nav
        navProxy.scrollEdgeAppearance = nav
        navProxy.compactScrollEdgeAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        for layout in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            layout.normal.titleTextAttributes = [.font: itemFont]
            layout.selected.titleTextAttributes = [.font: itemFont]
        }
        let tabProxy = UITabBar.appearance()
        tabProxy.standardAppearance = tab
        tabProxy.scrollEdgeAppearance = tab
    }

    /// 既有栏实例就地刷新：复制现外观（保留一切非字体配置）后仅重写字体属性
    @discardableResult
    private static func applyChromeToExistingBars(
        titleFont: UIFont,
        largeFont: UIFont,
        itemFont: UIFont
    ) -> (nav: Int, tab: Int) {
        var navCount = 0
        var tabCount = 0

        func refreshNavigationBar(_ bar: UINavigationBar) {
            let standard = bar.standardAppearance.copy()
            standard.titleTextAttributes = [.font: titleFont]
            standard.largeTitleTextAttributes = [.font: largeFont]
            bar.standardAppearance = standard

            let compact = (bar.compactAppearance ?? bar.standardAppearance).copy()
            compact.titleTextAttributes = [.font: titleFont]
            compact.largeTitleTextAttributes = [.font: largeFont]
            bar.compactAppearance = compact

            let scroll = (bar.scrollEdgeAppearance ?? bar.standardAppearance).copy()
            scroll.titleTextAttributes = [.font: titleFont]
            scroll.largeTitleTextAttributes = [.font: largeFont]
            bar.scrollEdgeAppearance = scroll

            let compactScroll = (bar.compactScrollEdgeAppearance ?? bar.standardAppearance).copy()
            compactScroll.titleTextAttributes = [.font: titleFont]
            compactScroll.largeTitleTextAttributes = [.font: largeFont]
            bar.compactScrollEdgeAppearance = compactScroll
            navCount += 1
        }

        func refreshTabBar(_ bar: UITabBar) {
            let appearance = bar.standardAppearance.copy()
            for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                layout.normal.titleTextAttributes = [.font: itemFont]
                layout.selected.titleTextAttributes = [.font: itemFont]
            }
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            tabCount += 1
        }

        func walk(_ controller: UIViewController?) {
            guard let controller else { return }
            if let nav = controller as? UINavigationController { refreshNavigationBar(nav.navigationBar) }
            if let tab = controller as? UITabBarController { refreshTabBar(tab.tabBar) }
            controller.children.forEach { walk($0) }
            walk(controller.presentedViewController)
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { walk(window.rootViewController) }
        }
        return (navCount, tabCount)
    }
}

// MARK: - 视图扩展：排版修饰器与全局注入

/// 单个文本应用显示排版（字号 × 档位缩放、粗体、家族、字距、行距）；baseLineSpacing 为默认倍率下的基础行距
private struct DisplayTextModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let baseLineSpacing: CGFloat

    @Environment(\.displayFontScale) private var scale
    @Environment(\.displayBold) private var bold
    @Environment(\.displayFontFamily) private var family
    @Environment(\.displayLetterSpacing) private var tracking
    @Environment(\.displayLineSpacing) private var lineSpacing
    @Environment(\.displayTypographyRevision) private var revision

    func body(content: Content) -> some View {
        // 读取修订号建立依赖：字体按需下载完成后 revision 变化 → 重算字体即时全局生效
        _ = revision
        return content
            .font(DisplayFontFactory.font(size: size, weight: weight, scale: scale, family: family, bold: bold))
            .tracking(CGFloat(tracking))
            .lineSpacing(baseLineSpacing + CGFloat((lineSpacing - 1.0) * size * scale))
    }
}

extension View {
    /// 按显示设置渲染文本（字号为基准 body 尺寸，随档位缩放；含动态行距与字间距，适合正文段落）
    func displayText(size: CGFloat, weight: Font.Weight = .regular, baseLineSpacing: CGFloat = 0) -> some View {
        modifier(DisplayTextModifier(size: size, weight: weight, baseLineSpacing: baseLineSpacing))
    }

    /// 将显示设置注入整个视图层级（放置在根视图上，全局即时生效）
    func displayTypography(_ manager: DisplaySettingsManager) -> some View {
        modifier(DisplayTypographyModifier(manager: manager))
    }

    /// 全 App 通用文本字体：档位缩放 + 粗体开关 + 字体家族（用户选择自定义家族时覆盖 design）
    func displayFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> some View {
        modifier(DisplayScaledFontModifier(kind: .text(size: size, weight: weight, design: design)))
    }

    /// SF Symbol 图标字体：仅随档位缩放，不应用家族与粗体，保证图标正常渲染
    func displaySymbolFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(DisplayScaledFontModifier(kind: .symbol(size: size, weight: weight)))
    }

    /// Label（含系统图标）：缩放 + 粗体，不应用自定义家族，保护 systemImage 图标
    func displayLabelFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(DisplayScaledFontModifier(kind: .label(size: size, weight: weight)))
    }
}

/// 通用缩放字体修饰器：区分文本 / 图标 / Label 三种应用策略
private struct DisplayScaledFontModifier: ViewModifier {
    enum Kind {
        case text(size: CGFloat, weight: Font.Weight, design: Font.Design?)
        case symbol(size: CGFloat, weight: Font.Weight)
        case label(size: CGFloat, weight: Font.Weight)
    }

    let kind: Kind

    @Environment(\.displayFontScale) private var scale
    @Environment(\.displayBold) private var bold
    @Environment(\.displayFontFamily) private var family
    @Environment(\.displayTypographyRevision) private var revision

    func body(content: Content) -> some View {
        // 读取修订号建立依赖：字体下载完成后全 App display* 文本自动应用新字体
        _ = revision
        return content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        switch kind {
        case .text(let size, let weight, let design):
            if family == .system {
                return .system(size: size * scale, weight: bold ? .bold : weight, design: design ?? .default)
            }
            return DisplayFontFactory.font(size: size, weight: weight, scale: scale, family: family, bold: bold)
        case .symbol(let size, let weight):
            return .system(size: size * scale, weight: weight)
        case .label(let size, let weight):
            return .system(size: size * scale, weight: bold ? .bold : weight)
        }
    }
}

/// 全局排版注入：字号档位 → sizeCategory、粗体/家族/字距/行距 → 自定义环境；按钮形状 → buttonStyle
private struct DisplayTypographyModifier: ViewModifier {
    @ObservedObject var manager: DisplaySettingsManager
    @Environment(\.sizeCategory) private var systemSizeCategory

    func body(content: Content) -> some View {
        content
            .environment(\.displayFontScale, manager.fontSizeTier.scale)
            .environment(\.displayBold, manager.boldTextEnabled)
            .environment(\.displayFontFamily, manager.useSystemFont ? .system : manager.fontFamily)
            .environment(\.displayLetterSpacing, manager.letterSpacingValue)
            .environment(\.displayLineSpacing, manager.lineSpacingFactor)
            .environment(\.displayTypographyRevision, manager.typographyRevision)
            .environment(\.sizeCategory, manager.fontSizeTier.contentSizeCategory ?? systemSizeCategory)
            .shapedButtonStyle(enabled: manager.buttonShapesEnabled)
            // 专注灰度模式：全局去饱和单点注入（系统合成器处理，关闭即 100% 恢复）
            .saturation(manager.grayScaleEnabled ? 0 : 1)
            .animation(.easeInOut(duration: 0.4), value: manager.grayScaleEnabled)
    }
}

// MARK: - 按钮形状条件注入（ViewBuilder 分支，避免无 AnyButtonStyle 的类型擦除问题）

private extension View {
    @ViewBuilder
    func shapedButtonStyle(enabled: Bool) -> some View {
        if enabled {
            buttonStyle(DisplayShapedButtonStyle())
        } else {
            self
        }
    }
}

// MARK: - 弹出层呈现链（外观 + 专注灰度，跨 presentation 统一注入）

/// 弹出层呈现链：**每个内容级 sheet / fullScreenCover 内容根都必须挂载本修饰器**（2026-09-27 全链审计固化）。
/// 原因：`.preferredColorScheme` 与 `.saturation` 属「呈现/渲染修饰器」而非环境值，
/// 根视图（MainTabView）上的注入链不会作用于 presentation 内容——外观模式与专注灰度必须在此单独注入。
/// 其余设置均为环境值（`.tint` 主题色、字号/家族/粗体/行距/字距自定义 EnvironmentKey、`.buttonStyle` 按钮形状），
/// 会自动传播进弹出层，无需重复挂载。系统分享面板属系统 UI，不在承诺范围。
struct SJZPresentationChromeModifier: ViewModifier {
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(displaySettings.appearanceMode.resolvedColorScheme)
            .saturation(displaySettings.grayScaleEnabled ? 0 : 1)
            .animation(.easeInOut(duration: 0.4), value: displaySettings.grayScaleEnabled)
    }
}

extension View {
    /// 挂载到 sheet / fullScreenCover 内容根：外观模式 + 专注灰度跨 presentation 注入（全链审计强制项）
    func sjzPresentationChrome() -> some View {
        modifier(SJZPresentationChromeModifier())
    }
}

// MARK: - 按钮形状样式（开启后为未显式指定样式的按钮添加边框胶囊形状）

struct DisplayShapedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.45))
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 文章阅读统计（正文字数 + 预计阅读时长）

/// 阅读统计计算器：纯函数、无 UI 依赖、单趟遍历。
///
/// **字数口径 A（全程一致）**：展示「全文共 X 字」= 中文字符数 + 英文单词数之和。
/// - 中文按「字」计数（CJK 统一表意文字 / 扩展 A / 假名 / 韩文 / 兼容表意文字），已剔除全部中英文标点与空白；
/// - 英文按「词」计数（CJK 字符替换为空格后切分，保证 "你会说English吗" = 4 字 + 1 词，不粘连）；
/// - 公示自洽：展示字数 ÷ 对应速度 ≈ 展示分钟（高估取向：中文 300 字/分、英文 220 词/分 均取保守值）。
///
/// 阅读时长：分钟 = 中文字数 / 速度 + 英文词数 / 速度 + 图片耗时 + 代码块耗时
/// - 图片：首张 +12s，逐张递减 1s，最低 3s（Medium 做法）；
/// - 代码块：每个 +30s（代码阅读速度约为正文一半）；向上取整，正文非空时至少 1 分钟；
/// - 超过 60 分钟转换为「约 X 小时」（X 为 0.5 步进的整数/半天数，避免小数堆砌）。
/// - 正文为空 / 纯空白：返回 nil（不展示），优先级高于「不低于 1 分钟」兜底。
enum ReadingStatsCalculator {

    struct Result: Equatable {
        let chineseChars: Int
        let englishWords: Int
        /// 展示口径总字数（= chineseChars + englishWords）
        var totalCount: Int { chineseChars + englishWords }
        /// 取整后的预计阅读分钟（正文非空时 ≥ 1）
        let minutes: Int
        /// 分钟数原文（用于调试日志）
        let rawMinutes: Double
    }

    // MARK: 阅读参数（具名常量，便于调整）

    /// 中文默认阅读速度：300 字/分钟（成人默读 300–500，取保守值，宁可高估）
    static let defaultChineseCharsPerMinute: Double = 300
    /// 英文默认阅读速度：220 词/分钟（Medium 265 / Substack 200，取中间偏保守）
    static let defaultEnglishWordsPerMinute: Double = 220
    /// 首张图片附加阅读耗时（秒）
    static let firstImageSeconds: Double = 12
    /// 图片耗时递减步长：12 → 11 → 10 …（秒）
    static let imageDecaySeconds: Double = 1
    /// 单张图片最低耗时（秒）
    static let minImageSeconds: Double = 3
    /// 每个代码块附加耗时（秒）
    static let codeBlockSeconds: Double = 30

    // MARK: - 纯文本统计（标点剔除 + 中文计数 + 英文分词，单趟遍历）

    static func countPlainText(_ text: String) -> (chinese: Int, englishWords: Int) {
        var chinese = 0
        var words = 0
        var inWord = false

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                chinese += 1
                if inWord { words += 1; inWord = false }
            } else if isLetterOrDigit(scalar) {
                inWord = true
            } else if isIntraWordPunctuation(scalar) {
                // 撇号 / 连字符 / 下划线仅能延续已有词，孤立出现不构词（如 " - " 不计）
                continue
            } else {
                // 空白 / 标点：分隔英文词
                if inWord { words += 1; inWord = false }
            }
        }
        if inWord { words += 1 }
        return (chinese, words)
    }

    /// CJK 字符判定（中文按字计数的 Unicode 范围）
    static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK 统一表意文字
             0x3400...0x4DBF,   // 扩展 A
             0x3040...0x30FF,   // 日文假名
             0xAC00...0xD7A3,   // 韩文
             0xF900...0xFAFF:   // 兼容表意文字
            return true
        default:
            return false
        }
    }

    /// 英文单词起始字符：字母与数字
    static func isLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
    }

    /// 英文词内标点：撇号 / 连字符 / 下划线（don't、long-term、hello_world 视为一个词；孤立即忽略）
    static func isIntraWordPunctuation(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return v == 0x27 || v == 0x2D || v == 0x5F
    }

    // MARK: - 时长计算

    /// 主入口：纯文本 + 图片数 + 代码块数 → 统计结果（返回 nil 表示空文本，不展示）
    static func calculate(
        plainText: String,
        imageCount: Int = 0,
        codeBlockCount: Int = 0,
        chineseCharsPerMinute: Double = defaultChineseCharsPerMinute,
        englishWordsPerMinute: Double = defaultEnglishWordsPerMinute
    ) -> Result? {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (chinese, words) = countPlainText(plainText)
        guard chinese + words > 0 else { return nil }
        guard let minutes = minutes(
            chineseChars: chinese,
            englishWords: words,
            imageCount: imageCount,
            codeBlockCount: codeBlockCount,
            chineseCharsPerMinute: chineseCharsPerMinute,
            englishWordsPerMinute: englishWordsPerMinute
        ) else { return nil }
        return Result(chineseChars: chinese, englishWords: words, minutes: minutes.minutes, rawMinutes: minutes.raw)
    }

    /// 分量级分钟数计算（缓存命中等无需重扫全文的场景；返回 nil 表示分量为空，不展示）
    static func minutes(
        chineseChars: Int,
        englishWords: Int,
        imageCount: Int = 0,
        codeBlockCount: Int = 0,
        chineseCharsPerMinute: Double = defaultChineseCharsPerMinute,
        englishWordsPerMinute: Double = defaultEnglishWordsPerMinute
    ) -> (minutes: Int, raw: Double)? {
        guard chineseChars + englishWords > 0 else { return nil }

        // 图片附加耗时（递减至最低 3 秒）
        var imageSeconds = 0.0
        for idx in 0..<max(0, imageCount) {
            imageSeconds += max(minImageSeconds, firstImageSeconds - Double(idx) * imageDecaySeconds)
        }
        let codeSeconds = Double(max(0, codeBlockCount)) * codeBlockSeconds

        let textMinutes = Double(chineseChars) / max(60, chineseCharsPerMinute)
            + Double(englishWords) / max(60, englishWordsPerMinute)
        let raw = textMinutes + (imageSeconds + codeSeconds) / 60.0
        return (max(1, Int(ceil(raw))), raw)
    }

    // MARK: - 展示文案

    /// 「X 字」千分位格式化（如 2,486 字）
    static func formattedCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// 「阅读约 Y 分钟」；≥ 70 分钟转为「约 X/Y 小时」（0.5 步进，避免过度精确）
    static func formattedMinutes(_ minutes: Int) -> String {
        if minutes < 70 {
            return "阅读约 \(minutes) 分钟"
        }
        let base = Double(minutes) / 60.0
        let rounded = (base * 2).rounded() / 2
        if rounded == rounded.rounded() {
            return "阅读约 \(Int(rounded)) 小时"
        }
        return String(format: "阅读约 %.1f 小时", rounded)
    }

    /// 列表角标紧凑时长文案：「9 分钟」；≥ 60 分钟转「1.2 小时」（0.5 步进，适配小胶囊空间）
    static func compactMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let base = Double(minutes) / 60.0
        let rounded = (base * 2).rounded() / 2
        if rounded == rounded.rounded() { return "\(Int(rounded)) 小时" }
        return String(format: "%.1f 小时", rounded)
    }

    // MARK: - 正文预处理（Markdown / HTML 剥离 + 图片与代码块计数）

    /// Markdown 剥离：移除围栏代码块（计数）、图片（计数）、标题/粗斜体/链接/引用/列表符后返回纯文本
    static func stripMarkdown(_ markdown: String) -> (text: String, imageCount: Int, codeBlockCount: Int) {
        var text = markdown
        var codeBlocks = 0
        var images = 0

        // 1. 围栏代码块 ``` ... ```
        let fencePattern = "```[\\s\\S]*?```"
        let fenceRegex = try? NSRegularExpression(pattern: fencePattern)
        if let regex = fenceRegex {
            let range = NSRange(text.startIndex..., in: text)
            codeBlocks = regex.numberOfMatches(in: text, range: range)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        // 2. 图片 ![alt](url)
        let imagePattern = "!\\[[^\\]]*\\]\\([^)]*\\)"
        let imageRegex = try? NSRegularExpression(pattern: imagePattern)
        if let regex = imageRegex {
            let range = NSRange(text.startIndex..., in: text)
            images = regex.numberOfMatches(in: text, range: range)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        // 3. 链接 [text](url) → text
        let linkPattern = "\\[([^\\]]+)\\]\\([^)]*\\)"
        let linkRegex = try? NSRegularExpression(pattern: linkPattern)
        if let regex = linkRegex {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        }
        // 4. 行首引用 > 与列表符
        let lineMarkers = try? NSRegularExpression(pattern: "(?m)^\\s{0,3}(>+\\s*|[-*+]\\s+|\\d+\\.\\s+)")
        if let regex = lineMarkers {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        // 5. 标题 #、粗斜体字符
        text = text.replacingOccurrences(of: "#", with: " ")
        text = text.replacingOccurrences(of: "*", with: " ")
        text = text.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: "`", with: " ")

        return (text, images, codeBlocks)
    }

    /// HTML 剥离：正则统计 `<img` / `<pre`（或独立 `<code` 块）数量 + 剥离标签为纯文本。
    /// 说明：富文本附件在 SwiftUI 的 AttributedString 中难以可靠枚举，采用源码正则统计；
    /// 若原始 HTML 不可得，调用方应传 nil / 纯文本并接受图片数、代码块数为 0（在调用点注释）。
    static func stripHTML(_ html: String) -> (text: String, imageCount: Int, codeBlockCount: Int) {
        let imgRegex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        let imgCount = imgRegex?.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)) ?? 0

        // 代码块：优先 <pre>（内部 <code> 不重复计）
        let preRegex = try? NSRegularExpression(pattern: "<pre\\b[^>]*>", options: [.caseInsensitive])
        let preCount = preRegex?.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)) ?? 0
        var codeCount = preCount
        if codeCount == 0 {
            let codeRegex = try? NSRegularExpression(pattern: "<code\\b[^>]*>", options: [.caseInsensitive])
            codeCount = codeRegex?.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)) ?? 0
        }

        // 剥离全部标签 → 纯文本（沿用全 App 通用剥离工具）
        let plain = html.strippingHTMLTagsFast()
        return (plain, imgCount, codeCount)
    }
}

// MARK: - 统计结果缓存（内存 + 持久化，列表徽标只读复用）

/// 阅读统计缓存：首次计算后持久化，列表卡片直接读取、不触发同步计算。
/// 缓存键为文章稳定 ID（articleId 优先，回退 title + 日期）。
/// 注意：缓存按「标准速度」口径存储原始分量（字数/内容指纹），速度档位变化时按分量重算分钟，
/// 因此档位切换不会导致旧缓存失真。
@MainActor
final class ReadingStatsCache {

    struct Entry: Codable, Equatable {
        let chineseChars: Int
        let englishWords: Int
        let imageCount: Int
        let codeBlockCount: Int
        var totalCount: Int { chineseChars + englishWords }
    }

    /// 最近一次统计结果快照（设置页「服务自检」展示用；内存 + 持久化双存）
    struct LastResolved: Codable, Equatable {
        let id: String
        let totalCount: Int
        let minutes: Int
        let at: Date
    }

    /// 诊断计数持久化结构（跨启动 / 覆盖安装保留；仅卸载重装会清零）
    struct Diagnostics: Codable {
        var mounted: Int = 0
        var resolveAttempts: Int = 0
        var lastMountedAt: Date?
        var lastResolveAt: Date?
        /// 列表徽标挂载计数与时间（每行卡片每次出现 +1）
        var badgeMounted: Int = 0
        var lastBadgeMountedAt: Date?
        /// 列表徽标摘要估算计数与时间
        var badgeComputed: Int = 0
        var lastBadgeComputedAt: Date?
    }

    static let shared = ReadingStatsCache()

    private static let storageKey = "readingStatsCache"
    private static let lastResolvedKey = "readingStatsLastResolved"
    private static let diagKey = "readingStatsDiag"
    private static let maxEntries = 500

    private var store: [String: Entry]
    /// 插入顺序队列：真 FIFO 淘汰依据（Dictionary 键集无序，不可直接作为淘汰顺序）
    private var insertionOrder: [String] = []
    private(set) var lastResolved: LastResolved?
    /// 诊断计数：跨启动持久化，设置页服务自检行展示
    private(set) var diagnostics = Diagnostics()
    private var isLoaded = false

    private init() {
        store = [:]
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            store = decoded
            insertionOrder = Array(decoded.keys)
            LogManager.shared.debugLog("reading", "阅读统计缓存已加载", context: ["entries": "\(decoded.count)"])
        } else {
            LogManager.shared.debugLog("reading", "阅读统计缓存初始化（无历史记录）")
        }
        if let data = UserDefaults.standard.data(forKey: Self.lastResolvedKey),
           let decoded = try? JSONDecoder().decode(LastResolved.self, from: data) {
            lastResolved = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.diagKey),
           let decoded = try? JSONDecoder().decode(Diagnostics.self, from: data) {
            diagnostics = decoded
        }
    }

    /// 最近统计结果描述（设置页状态胶囊；无记录返回 nil）
    var lastResolvedDescription: String? {
        loadIfNeeded()
        guard let last = lastResolved else { return nil }
        let time = last.at.formatted(date: .omitted, time: .shortened)
        return "\(ReadingStatsCalculator.formattedCount(last.totalCount)) 字 · \(ReadingStatsCalculator.formattedMinutes(last.minutes))（\(time)）"
    }

    /// 诊断计数上报（组件挂载 / 计算尝试，供设置页服务自检行展示；即时持久化）
    func recordArticleStatsMounted() {
        loadIfNeeded()
        diagnostics.mounted += 1
        diagnostics.lastMountedAt = Date()
        persistDiagnostics()
    }

    func recordResolveAttempt() {
        loadIfNeeded()
        diagnostics.resolveAttempts += 1
        diagnostics.lastResolveAt = Date()
        persistDiagnostics()
    }

    /// 列表徽标挂载计数（每次缩略图角标出现 +1，含具体时间）
    func recordBadgeMounted() {
        loadIfNeeded()
        diagnostics.badgeMounted += 1
        diagnostics.lastBadgeMountedAt = Date()
        persistDiagnostics()
    }

    /// 列表徽标摘要估算计数（含具体时间）
    func recordBadgeComputed() {
        loadIfNeeded()
        diagnostics.badgeComputed += 1
        diagnostics.lastBadgeComputedAt = Date()
        persistDiagnostics()
    }

    private func persistDiagnostics() {
        if let data = try? JSONEncoder().encode(diagnostics) {
            UserDefaults.standard.set(data, forKey: Self.diagKey)
        }
    }

    func entry(for id: String) -> Entry? {
        guard !id.isEmpty else { return nil }
        loadIfNeeded()
        return store[id]
    }

    func save(_ entry: Entry, for id: String) {
        guard !id.isEmpty else { return }
        loadIfNeeded()
        if store[id] == nil {
            insertionOrder.append(id)
        }
        store[id] = entry
        // 真 FIFO 淘汰：按插入顺序移除最旧条目（修复原实现依赖 Dictionary 无序键集的缺陷）
        if store.count > Self.maxEntries {
            let drop = store.count - Self.maxEntries
            for key in insertionOrder.prefix(drop) {
                store.removeValue(forKey: key)
            }
            insertionOrder.removeFirst(min(drop, insertionOrder.count))
        }
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        // 最近统计快照（服务自检展示 + 持久化）
        let resolved = LastResolved(id: id, totalCount: entry.totalCount, minutes: guessMinutes(for: entry), at: Date())
        lastResolved = resolved
        if let data = try? JSONEncoder().encode(resolved) {
            UserDefaults.standard.set(data, forKey: Self.lastResolvedKey)
        }
    }

    /// 快照分钟数（缓存写入时按标准速度近似；仅供状态展示，精确值由展示组件重算）
    private func guessMinutes(for entry: Entry) -> Int {
        ReadingStatsCalculator.minutes(
            chineseChars: entry.chineseChars,
            englishWords: entry.englishWords,
            imageCount: entry.imageCount,
            codeBlockCount: entry.codeBlockCount
        )?.minutes ?? 1
    }
}

// MARK: - 业务入口：取正文 → 预处理 → 计算 → 缓存（完整链路）

/// 阅读统计业务入口：负责缓存命中考量、超长文本后台计算、速度档位解析与完整日志埋点。
enum ReadingStatsService {

    /// 超过该字符数转入后台计算（10 万字符级正文不阻塞 UI）
    static let backgroundThreshold = 50_000

    /// 计算或读取统计结果：
    /// - `cachedID` 存在且缓存命中 → 用缓存分量按**当前速度档位**重算分钟（不重复扫描全文）；
    /// - 未命中 → 预处理（HTML/Markdown/纯文本）→ 计算 → 写入缓存；
    /// - 超长文本在 utility 队列计算，完成后切回主线程（本函数在主线程调用）。
    @MainActor
    static func resolve(
        cachedID: String?,
        source: ArticleReadingTextSource
    ) async -> ReadingStatsCalculator.Result? {
        ReadingStatsCache.shared.recordResolveAttempt()
        let requestStartedAt = Date()
        LogManager.shared.debugLog("reading", "统计计算请求开始", context: [
            "id": cachedID ?? "-",
            "startedAt": ReadingStatsClock.stamp(requestStartedAt),
            "attempt": "\(ReadingStatsCache.shared.diagnostics.resolveAttempts)"
        ])
        let settings = DisplaySettingsManager.shared
        guard settings.readingStatsEnabled else { return nil }

        let start = Date()

        // 1. 缓存命中：用缓存分量按当前档位重算分钟（零全文扫描）
        if let id = cachedID, !id.isEmpty, let entry = ReadingStatsCache.shared.entry(for: id) {
            guard let minutes = ReadingStatsCalculator.minutes(
                chineseChars: entry.chineseChars,
                englishWords: entry.englishWords,
                imageCount: entry.imageCount,
                codeBlockCount: entry.codeBlockCount,
                chineseCharsPerMinute: settings.readingCharsPerMinute,
                englishWordsPerMinute: settings.readingWordsPerMinute
            ) else { return nil }
            let result = ReadingStatsCalculator.Result(
                chineseChars: entry.chineseChars,
                englishWords: entry.englishWords,
                minutes: minutes.minutes,
                rawMinutes: minutes.raw
            )
            LogManager.shared.debugLog("reading", "阅读统计缓存命中", context: [
                "id": id,
                "chars": "\(entry.chineseChars)",
                "words": "\(entry.englishWords)",
                "minutes": "\(result.minutes)",
                "hitAt": ReadingStatsClock.stamp()
            ])
            return result
        }

        // 2. 预处理（纯文本 / Markdown / HTML）
        let preprocessed: (String, Int, Int)
        switch source {
        case .plain(let text, let imageCount, let codeBlockCount):
            preprocessed = (text, imageCount, codeBlockCount)
        case .markdown(let text):
            let stripped = ReadingStatsCalculator.stripMarkdown(text)
            preprocessed = (stripped.text, stripped.imageCount, stripped.codeBlockCount)
        case .html(let html, let knownImageCount):
            // 已知图片数（如详情接口返回的 images 数组）优先；否则以 <img 正则数为准（不可靠时按 0 兜底）
            let stripped = ReadingStatsCalculator.stripHTML(html)
            preprocessed = (stripped.text, knownImageCount ?? stripped.imageCount, stripped.codeBlockCount)
        }

        // 3. 超长文本 → utility 队列计算；常规文本 → 同步计算
        let result: ReadingStatsCalculator.Result?
        let textForCompute = preprocessed.0
        let imagesForCompute = preprocessed.1
        let blocksForCompute = preprocessed.2
        let cpm = settings.readingCharsPerMinute
        let wpm = settings.readingWordsPerMinute
        if textForCompute.count > backgroundThreshold {
            LogManager.shared.debugLog("reading", "超长正文转入后台统计", context: [
                "length": "\(textForCompute.count)"
            ])
            result = await Task.detached(priority: .utility) {
                ReadingStatsCalculator.calculate(
                    plainText: textForCompute,
                    imageCount: imagesForCompute,
                    codeBlockCount: blocksForCompute,
                    chineseCharsPerMinute: cpm,
                    englishWordsPerMinute: wpm
                )
            }.value
        } else {
            result = ReadingStatsCalculator.calculate(
                plainText: textForCompute,
                imageCount: imagesForCompute,
                codeBlockCount: blocksForCompute,
                chineseCharsPerMinute: cpm,
                englishWordsPerMinute: wpm
            )
        }

        // 4. 写缓存 + 日志（含耗时，供性能观测）
        if let result, let id = cachedID, !id.isEmpty {
            ReadingStatsCache.shared.save(
                .init(
                    chineseChars: result.chineseChars,
                    englishWords: result.englishWords,
                    imageCount: preprocessed.1,
                    codeBlockCount: preprocessed.2
                ),
                for: id
            )
        }
        if let result {
            let finishedAt = Date()
            LogManager.shared.info("reading", "阅读统计计算完成", context: [
                "chars": "\(result.chineseChars)",
                "words": "\(result.englishWords)",
                "images": "\(preprocessed.1)",
                "codeBlocks": "\(preprocessed.2)",
                "minutes": "\(result.minutes)",
                "startedAt": ReadingStatsClock.stamp(start),
                "finishedAt": ReadingStatsClock.stamp(finishedAt),
                "elapsedMs": "\(Int(finishedAt.timeIntervalSince(start) * 1000))"
            ])
        }
        return result
    }
}

/// 统计正文来源（业务入口统一入参）
enum ArticleReadingTextSource {
    case plain(String, imageCount: Int = 0, codeBlockCount: Int = 0)
    case markdown(String)
    case html(String, knownImageCount: Int?)
}

// MARK: - 详情页 meta 区组件（点分隔 · 字数 · 阅读时长；随设置开关显隐）

/// 文章阅读统计文本组件：详情页标题下的 meta 行使用。
/// - 展示「2,486 字 · 阅读约 9 分钟」（各部分可独立开关，均关闭或正文为空时整体不显示）；
/// - 计算由 `ReadingStatsService` 承担（缓存优先 / 超长后台化 / 完整日志），组件只负责渲染；
/// - VoiceOver 合并为单一标签（如「共 2,486 字，预计阅读 9 分钟」）。
struct ArticleReadingStatsText: View {
    private let cachedID: String
    private let source: ArticleReadingTextSource
    @ObservedObject private var settings = DisplaySettingsManager.shared
    @State private var result: ReadingStatsCalculator.Result?

    /// 纯文本正文入口（新闻 / 榜样力量 / 校园风光等详情）
    init(cachedID: String, plainText: String, imageCount: Int = 0, codeBlockCount: Int = 0) {
        self.cachedID = cachedID
        self.source = .plain(plainText, imageCount: imageCount, codeBlockCount: codeBlockCount)
    }

    /// HTML 正文入口（机构文章详情；详情接口图片数优先，缺失时按 <img 正则计）
    init(cachedID: String, html: String, knownImageCount: Int?) {
        self.cachedID = cachedID
        self.source = .html(html, knownImageCount: knownImageCount)
    }

    var body: some View {
        // 恒存锚点容器（ZStack 永远出现在视图树中）：
        // 生命周期修饰符（.task/.onAppear/.onChange）必须挂在此处。
        // 教训：若直接挂在条件 Group 上，条件为假时内容为空视图，这些修饰符永不触发，
        // 导致 result 恒为 nil，而渲染条件又依赖 result 非 nil —— 形成「永不显示」死锁。
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 0, height: 0)
            if settings.readingStatsEnabled,
               let result,
               settings.readingCharCountEnabled || settings.readingTimeEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .displaySymbolFont(10)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    if settings.readingCharCountEnabled {
                        Text("\(ReadingStatsCalculator.formattedCount(result.totalCount)) 字")
                    }
                    if settings.readingCharCountEnabled && settings.readingTimeEnabled {
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    if settings.readingTimeEnabled {
                        Text(ReadingStatsCalculator.formattedMinutes(result.minutes))
                    }
                }
                .displayFont(12)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
            }
        }
        .task(id: cachedID) {
            await refresh()
        }
        .onChange(of: settings.readingSpeedTier) { _, _ in
            // 档位变化后重算分钟（缓存分量不变，零全文扫描）
            Task { await refresh() }
        }
        .onAppear {
            // 诊断计数 + 毫秒级挂载埋点：组件真实出现在视图树（与设置页自检行联动）
            ReadingStatsCache.shared.recordArticleStatsMounted()
            LogManager.shared.debugLog("reading", "统计组件挂载", context: [
                "id": cachedID,
                "mountedAt": ReadingStatsClock.stamp(),
                "mountedCount": "\(ReadingStatsCache.shared.diagnostics.mounted)"
            ])
        }
    }

    private func refresh() async {
        let resolved = await ReadingStatsService.resolve(cachedID: cachedID, source: source)
        result = resolved
        // 系统控制台直出（Xcode 底部 Console 可过滤 category=ReadingStats），实时观测统计链路
        readingStatsLogger.info("resolve id=\(self.cachedID, privacy: .public) enabled=\(self.settings.readingStatsEnabled) charToggle=\(self.settings.readingCharCountEnabled) timeToggle=\(self.settings.readingTimeEnabled) result=\(resolved != nil ? "yes" : "NO")")
        // 渲染路径留痕：统计算出后，落一条「即将显示 / 不显示及原因」日志，与 UI 表现逐一对应
        if let resolved {
            if settings.readingCharCountEnabled || settings.readingTimeEnabled {
                LogManager.shared.debugLog("reading", "统计行即将渲染", context: [
                    "id": cachedID,
                    "totalCount": "\(resolved.totalCount)",
                    "minutes": "\(resolved.minutes)",
                    "charToggle": "\(settings.readingCharCountEnabled)",
                    "timeToggle": "\(settings.readingTimeEnabled)",
                    "listBadge": "\(settings.readingListBadgeEnabled)",
                    "renderedAt": ReadingStatsClock.stamp()
                ])
            } else {
                LogManager.shared.warning("reading", "统计已计算但字数/时长开关均关闭，行不渲染", context: ["id": cachedID])
            }
        } else {
            let textLength: Int
            switch source {
            case .plain(let text, _, _): textLength = text.count
            case .markdown(let text): textLength = text.count
            case .html(let html, _): textLength = html.count
            }
            LogManager.shared.warning("reading", "统计结果为空", context: [
                "id": cachedID,
                "sourceLength": "\(textLength)",
                "statsEnabled": "\(settings.readingStatsEnabled)"
            ])
        }
    }

    private var accessibilityText: String {
        guard let result else { return "" }
        var parts: [String] = []
        if settings.readingCharCountEnabled {
            parts.append("共 \(ReadingStatsCalculator.formattedCount(result.totalCount)) 字")
        }
        if settings.readingTimeEnabled {
            parts.append("预计阅读 \(result.minutes) 分钟")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 列表卡片阅读时长徽标（分级配色 · 缩略图右下角统一规范）

/// 阅读时长分级（角标配色分档，语义化色彩：速览绿 / 标准蓝 / 长文橙 / 深度紫）
enum ReadingDurationTier: Int, Comparable {
    case quick = 1      // ≤4 分钟
    case standard = 2   // 5–9 分钟
    case longRead = 3   // 10–19 分钟
    case deepRead = 4   // ≥20 分钟

    static func tier(forMinutes minutes: Int) -> ReadingDurationTier {
        switch minutes {
        case ...4: return .quick
        case 5...9: return .standard
        case 10...19: return .longRead
        default: return .deepRead
        }
    }

    /// 徽标底色（实心、白字高对比；sjz* 动态色随明暗模式自适应）
    var color: Color {
        switch self {
        case .quick: return Color.sjzGreen
        case .standard: return Color.sjzAccent
        case .longRead: return Color.sjzOrange
        case .deepRead: return Color.sjzPurple
        }
    }

    var title: String {
        switch self {
        case .quick: return "速览"
        case .standard: return "标准"
        case .longRead: return "长文"
        case .deepRead: return "深度"
        }
    }

    static func < (lhs: ReadingDurationTier, rhs: ReadingDurationTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 列表卡片阅读时长徽标：「⏱ 9分钟」缩略图角标。
/// ① 全文口径缓存优先（打开过该文章后由详情页写入，最准确）；
/// ② 无缓存时以列表摘要同步估算（微秒级单趟遍历，不写缓存不落盘）；
/// ③ 两者皆无则不显示。列表滚动零异步任务、零卡顿。
/// 规范全 App 统一（紧凑尺寸 · 不遮挡缩略图）：图标 8pt · 字号 10 · 圆角 Capsule ·
/// 内边距 H5.5/V2 · 实心分级色底 · 白字高对比 · 高光描边 · 柔和阴影。
struct ReadingTimeBadgeView: View {
    let cachedID: String
    /// 列表项摘要兜底文本（详情页全文口径优先级更高；nil 则维持纯缓存行为）
    var summary: String? = nil
    @ObservedObject private var settings = DisplaySettingsManager.shared
    @State private var minutes: Int?
    /// 当前分钟数据来源：cache = 全文口径缓存 / summary = 摘要估算
    @State private var source: String = "none"
    /// 日志节流键（来源+分钟拼接，值变化才记，滚动复用不刷屏）
    @State private var loggedKey: String?

    var body: some View {
        // 恒存锚点容器：生命周期修饰符必须挂在恒在视图上（教训同 ArticleReadingStatsText，
        // 条件 Group 为空时 .onAppear 永不触发，徽标将永远不刷新）
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 0, height: 0)
            if settings.readingStatsEnabled,
               settings.readingListBadgeEnabled,
               settings.readingTimeEnabled,
               let minutes {
                let tier = ReadingDurationTier.tier(forMinutes: minutes)
                HStack(spacing: 2.5) {
                    Image(systemName: "clock.fill")
                        .displaySymbolFont(8, weight: .bold)
                    Text(ReadingStatsCalculator.compactMinutes(minutes))
                        .displayFont(10, weight: .bold, design: .rounded)
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 2)
                .background(tier.color, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: tier.color.opacity(0.4), radius: 3, y: 1)
                .accessibilityLabel("预计阅读 \(minutes) 分钟（\(tier.title)）")
            }
        }
        .onAppear {
            // 每次挂载都持久化计数与时间；日志按周期采样（防滚动刷屏，计数完整可对账）
            ReadingStatsCache.shared.recordBadgeMounted()
            if ReadingStatsCache.shared.diagnostics.badgeMounted % 20 == 1 {
                LogManager.shared.debugLog("reading", "列表徽标挂载采样", context: [
                    "id": cachedID,
                    "mountedAt": ReadingStatsClock.stamp(),
                    "badgeMountedTotal": "\(ReadingStatsCache.shared.diagnostics.badgeMounted)"
                ])
            }
            refreshMinutes()
        }
        .onChange(of: settings.readingSpeedTier) { _, _ in refreshMinutes() }
    }

    /// 分钟数解析：全文缓存优先 → 摘要同步估算 → 不显示
    private func refreshMinutes() {
        if let entry = ReadingStatsCache.shared.entry(for: cachedID),
           let value = ReadingStatsCalculator.minutes(
               chineseChars: entry.chineseChars,
               englishWords: entry.englishWords,
               imageCount: entry.imageCount,
               codeBlockCount: entry.codeBlockCount,
               chineseCharsPerMinute: settings.readingCharsPerMinute,
               englishWordsPerMinute: settings.readingWordsPerMinute
           )?.minutes {
            minutes = value
            source = "cache"
        } else if let summary, !summary.isEmpty,
                  let result = ReadingStatsCalculator.calculate(
                      plainText: summary,
                      chineseCharsPerMinute: settings.readingCharsPerMinute,
                      englishWordsPerMinute: settings.readingWordsPerMinute
                  ) {
            // 摘要估算：持久化计算计数与时间（供设置页自检与跨会话观测）
            ReadingStatsCache.shared.recordBadgeComputed()
            minutes = result.minutes
            source = "summary"
        } else {
            minutes = nil
            source = "none"
        }
        logBadgeIfChanged()
    }

    /// 列表徽标日志（来源/分钟变化才记，含分级与毫秒级刷新时间）
    private func logBadgeIfChanged() {
        let key = "\(source):\(minutes.map(String.init) ?? "nil")"
        guard loggedKey != key else { return }
        loggedKey = key
        let tierTitle = minutes.map { ReadingDurationTier.tier(forMinutes: $0).title } ?? "none"
        LogManager.shared.debugLog("reading", "列表徽标刷新", context: [
            "id": cachedID,
            "minutes": minutes.map(String.init) ?? "nil",
            "source": source,
            "tier": tierTitle,
            "statsEnabled": "\(settings.readingStatsEnabled)",
            "badgeToggle": "\(settings.readingListBadgeEnabled)",
            "timeToggle": "\(settings.readingTimeEnabled)",
            "refreshedAt": ReadingStatsClock.stamp()
        ])
    }
}