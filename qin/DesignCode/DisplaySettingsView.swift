//
//  DisplaySettingsView.swift
//  山西晋中理工学院 APP — 显示设置页（艺术级改造版）
//
//  包含：艺术级 Hero 实时预览（aurora 渐变 + 呼吸 + 扫光）· 外观（3 模式卡 + 5 主题图鉴）
//        排版方案（3 套一键套装）· 文字排版（6 档刻度/粗体/字体家族真字貌/行距字距 A/B 对照 + 标尺/按钮形状）
//        文章文字颜色（8 预设 + 纸面预览 + 自定义 + 颜色历史 + 随机和谐色 + WCAG 对比度自检）
//        阅读统计（字数/时长/列表徽标/速度档位）· 屏幕（亮度 + 预设 + 自动亮度）
//        自动锁定（7 档）· 屏幕常亮（idle timer 真实拦截 + 诊断卡）· 辅助功能（5 行 + 灰度专注模式）
//        最近改动时间轴（20 条）· 其他（分享摘要 + 恢复默认 + 版本）
//

import SwiftUI
import UIKit

struct DisplaySettingsView: View {
    @ObservedObject private var settings = DisplaySettingsManager.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var showResetAlert = false
    /// 服务自检刷新戳（每次进入页面 +1，强制重读诊断计数）
    @State private var selfCheckTick = 0
    /// 自定义颜色十六进制输入框文本（实时校验，合法即应用）
    @State private var customHexText = ""
    /// 页面停留计时起点（F14）
    @State private var enteredAt = Date()
    /// Session 内已曝光的 Section 集合（F14 曝光去重）
    @State private var exposedSections = Set<String>()
    /// 主题图鉴涟漪（当前涟漪扩散中的主题色）
    @State private var themeRipple: DisplayThemeStyle?
    /// 随机和谐色防连点时间戳（F10）
    @State private var lastDiceAt = Date.distantPast
    /// 方案套用计数（图标弹跳触发源）
    @State private var schemeTicker = 0
    /// 主题涟漪令牌（连点时防止旧挂起清空截断新涟漪）
    @State private var themeRippleToken = 0
    /// Toast
    @State private var toastText: String?
    @State private var toastWorkItem: DispatchWorkItem?
    /// 字体「全部下载」确认弹窗
    @State private var showFontBatchDialog = false

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version)（\(build)）"
    }

    var body: some View {
        Form {
            heroPreviewSection
            appearanceSection
            schemeSection
            typographySection
            articleTextColorSection
            readingStatsSection
            screenSection
            autoLockSection
            keepAwakeSection
            accessibilitySection
            historySection
            otherSection
        }
        .navigationTitle("显示设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            enteredAt = Date()
            selfCheckTick += 1
            LogManager.shared.debugLog("display", "显示设置页打开（服务自检刷新）", context: [
                "mounted": "\(ReadingStatsCache.shared.diagnostics.mounted)",
                "resolveAttempts": "\(ReadingStatsCache.shared.diagnostics.resolveAttempts)",
                "grayScale": "\(settings.grayScaleEnabled)"
            ])
            // Hero 慢扫光（单次 3.2s；reduceMotion 下不触发；先复位支持重进页面重扫）
            heroShineSwept = false
            if !systemReduceMotion {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 3.2).delay(0.15)) {
                        heroShineSwept = true
                    }
                }
            }
        }
        .onDisappear {
            let stay = Date().timeIntervalSince(enteredAt)
            LogManager.shared.debugLog("display", "显示设置页关闭", context: [
                "stayMs": "\(Int(stay * 1000))",
                "exposedSections": "\(exposedSections.count)"
            ])
        }
        .alert("确认恢复默认显示设置？", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    settings.resetAll()
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showToast("已恢复全部默认显示设置")
            }
        } message: {
            Text("将还原外观、字体、屏幕、锁定与排版全部默认值，并撤销亮度与防息屏接管。")
        }
        .overlay(alignment: .bottom) {
            if let toastText {
                toastCapsule(toastText)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 通用工具

    /// Session 内 Section 首次曝光埋点（去重）
    private func exposeSection(_ name: String) {
        guard !exposedSections.contains(name) else { return }
        exposedSections.insert(name)
        LogManager.shared.debugLog("display", "显示设置区块首次曝光", context: ["section": name])
    }

    private func showToast(_ text: String) {
        toastWorkItem?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            toastText = text
        }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.3)) { toastText = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func toastCapsule(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .displaySymbolFont(14, weight: .semibold)
                .foregroundStyle(settings.themeStyle.color)
            Text(text)
                .displayLabelFont(13, weight: .semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(SJZDesignTokens.capsuleStroke, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }

    // MARK: - 艺术级 Hero 实时预览（F1）

    private var heroPreviewSection: some View {
        Section {
            VStack(spacing: 16) {
                // 状态徽章行
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .displaySymbolFont(14, weight: .semibold)
                        .foregroundStyle(.white)
                    Text("所见即所得")
                        .displayFont(13, weight: .bold, design: .rounded)
                        .foregroundStyle(.white)
                    Spacer()
                    heroStatusBadge
                }

                // 全景预览：字号/粗体/家族/行距/字距/主题色 联动的「校园名场面」
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "graduationcap.fill")
                            .displaySymbolFont(22)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(LinearGradient(
                                colors: [settings.themeStyle.color, settings.themeStyle.color.opacity(0.65)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("园枢 · 校园晨读时刻")
                                .displayText(size: 15, weight: .bold)
                                .foregroundStyle(.primary)
                            Text("所有排版设置在此即时呈现")
                                .displayText(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        toneDot
                    }

                    Text("晨光落在图书馆的玻璃幕墙上，把一排排书架染成淡金色；早八的铃声还没响，林荫道上已经有三三两两的身影。")
                        .displayText(size: 13)
                        .foregroundStyle(settings.articleBodyColor ?? .primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button {
                            LogManager.shared.debugLog("display", "Hero 预览主按钮点击")
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Label("示例按钮", systemImage: "sparkles")
                                .displayLabelFont(12, weight: .semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.themeStyle.color)

                        Button {
                            LogManager.shared.debugLog("display", "Hero 预览次按钮点击")
                        } label: {
                            Text("次级操作")
                                .displayText(size: 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(settings.themeStyle.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.16 : 0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
            .background(heroAurora)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(heroShine)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
            )
            .modifier(HeroBreathModifier(enabled: !systemReduceMotion))
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } header: {
            Text("实时预览").displayFont(13, weight: .semibold)
        } footer: {
            Text("调整下方任意设置，本卡片立即以相同排版重新渲染；主题色同步驱动整页强调色。")
                .displayFont(13)
        }
    }

    /// 呼吸节律色点：随相位明暗浮动（视觉焦点锚点）
    private var toneDot: some View {
        Circle()
            .fill(settings.themeStyle.color)
            .frame(width: 9, height: 9)
            .shadow(color: settings.themeStyle.color.opacity(0.55), radius: 4)
    }

    /// 非默认项计数徽章
    private var heroStatusBadge: some View {
        let count = settings.nonDefaultChangeCount
        return HStack(spacing: 5) {
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(count > 0 ? "\(count) 项已个性化" : "全部为默认值")
                .displayFont(10, weight: .semibold, design: .rounded)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .displayNumericTransition(reduceMotion: systemReduceMotion)
    }

    /// aurora 渐变（主题色 → 辅助青 → 主题色，深浅模式分支）
    private var heroAurora: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [settings.themeStyle.color.opacity(0.55),
                       Color.sjzTeal.opacity(0.38),
                       settings.themeStyle.color.opacity(0.22)]
                    : [settings.themeStyle.color.opacity(0.30),
                       Color.sjzTeal.opacity(0.20),
                       settings.themeStyle.color.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 细噪点层：轻量质感
            LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.06 : 0.10), .clear, .white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// 慢扫光（单次 3.2s；reduceMotion 时不触发）
    private var heroShine: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, .white.opacity(0.28), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 110)
            .rotationEffect(.degrees(12))
            .offset(x: systemReduceMotion ? -200 : heroShineSwept ? proxy.size.width + 80 : -200,
                    y: 0)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    @State private var heroShineSwept = false

    /// Hero 呼吸（phaseAnimator 亮度浮动 2.4s 往复）
    private struct HeroBreathModifier: ViewModifier {
        let enabled: Bool
        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.phaseAnimator([1.0, 0.92]) { view, phase in
                    view.opacity(phase)
                } animation: { _ in .easeInOut(duration: 1.2) }
            } else {
                content
            }
        }
    }

    // MARK: - 外观（F2 模式卡 + F3 主题图鉴）

    private var appearanceSection: some View {
        Section {
            // 模式卡（3 张并排）
            HStack(spacing: 10) {
                ForEach(DisplayAppearanceMode.allCases) { mode in
                    appearanceModeCard(mode)
                }
            }
            .onAppear { exposeSection("appearance") }
            .padding(.vertical, 4)

            // 主题图鉴
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette.fill")
                        .displaySymbolFont(13, weight: .semibold)
                        .foregroundStyle(settings.themeStyle.color)
                    Text("主题图鉴")
                        .displayFont(13, weight: .semibold)
                    Spacer()
                    Text(settings.themeStyle.title)
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(settings.themeStyle.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(settings.themeStyle.color.opacity(0.1), in: Capsule())
                }
                HStack(spacing: 14) {
                    ForEach(DisplayThemeStyle.allCases) { style in
                        themeBadge(style)
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("外观").displayFont(13, weight: .semibold)
        } footer: {
            Text("主题色将应用于全局按钮、选中态与强调色，深浅模式下自动适配。")
                .displayFont(13)
        }
    }

    /// 外观模式卡（玻璃选中态 + 图标弹跳）
    private func appearanceModeCard(_ mode: DisplayAppearanceMode) -> some View {
        let isSelected = settings.appearanceMode == mode
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                settings.appearanceMode = mode
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: modeIcon(mode))
                    .displaySymbolFont(20, weight: .semibold)
                    .displayBounce(reduceMotion: systemReduceMotion, value: isSelected)
                    .foregroundStyle(isSelected ? settings.themeStyle.color : .secondary)
                    .frame(width: 50, height: 50)
                    .background(
                        (isSelected ? settings.themeStyle.color : Color.gray).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                Text(mode.title)
                    .displayFont(12, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? settings.themeStyle.color.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? settings.themeStyle.color.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CardPressStyle(reduceMotion: systemReduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.title)\(isSelected ? "，当前选中" : "")")
        .accessibilityHint("双击切换外观模式")
    }

    private func modeIcon(_ mode: DisplayAppearanceMode) -> String {
        switch mode {
        case .system: return "iphone"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// 主题图鉴徽章（渐变圆 + 选择勾 + 涟漪 + 弹跳）
    private func themeBadge(_ style: DisplayThemeStyle) -> some View {
        let isSelected = settings.themeStyle == style
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            themeRippleToken += 1
            let token = themeRippleToken
            themeRipple = style
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                settings.themeStyle = style
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard themeRippleToken == token else { return }
                withAnimation(.easeIn(duration: 0.2)) { themeRipple = nil }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [style.color, style.color.opacity(0.65)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 34, height: 34)
                        .shadow(color: style.color.opacity(0.4), radius: 6, y: 2)
                    if themeRipple == style && !systemReduceMotion {
                        Circle()
                            .stroke(.white.opacity(0.85), lineWidth: 2)
                            .frame(width: 34, height: 34)
                            .transition(.scale(scale: 1.9).combined(with: .opacity))
                    }
                    if isSelected {
                        Image(systemName: "checkmark")
                            .displaySymbolFont(12, weight: .bold)
                            .displayBounce(reduceMotion: systemReduceMotion, value: isSelected)
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(
                    Circle().stroke(isSelected ? Color.primary : .clear, lineWidth: 2)
                        .padding(-5)
                )
                Text(style.title)
                    .displayFont(10)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.title)\(isSelected ? "，当前选中" : "")")
        .accessibilityHint("双击切换全局主题色")
    }

    // MARK: - 排版方案（F4）

    private var schemeSection: some View {
        Section {
            HStack(spacing: 10) {
                ForEach(DisplaySchemePreset.allCases) { preset in
                    schemeCard(preset)
                }
            }
            .onAppear { exposeSection("scheme") }
            .padding(.vertical, 4)
        } header: {
            Text("排版方案").displayFont(13, weight: .semibold)
        } footer: {
            Text("一键切换字号、行距、字间距、粗体与字体家族；套用后下方各项同步更新，可再微调。")
                .displayFont(13)
        }
    }

    private func schemeCard(_ preset: DisplaySchemePreset) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            schemeTicker += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                showToast(settings.applyScheme(preset))
            }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: preset.icon)
                    .displaySymbolFont(17, weight: .semibold)
                    .displayBounce(reduceMotion: systemReduceMotion, options: .nonRepeating, value: "\(schemeTicker):\(preset.rawValue)")
                    .foregroundStyle(settings.themeStyle.color)
                    .frame(width: 40, height: 40)
                    .background(settings.themeStyle.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(preset.title)
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(preset.shortBadgeText)
                    .displayFont(9.5, weight: .medium, design: .rounded)
                    .foregroundStyle(settings.themeStyle.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(settings.themeStyle.color.opacity(0.09), in: Capsule())
                Text(preset.subtitle)
                    .displayFont(9.5)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SJZDesignTokens.capsuleStroke, lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CardPressStyle(reduceMotion: systemReduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preset.title)方案，\(preset.shortBadgeText)，\(preset.subtitle)")
        .accessibilityHint("双击套用该排版方案")
    }

    // MARK: - 文字排版（F5 + F6 + F7 + F19）

    private var typographySection: some View {
        Section {
            // 字号刻度卡（F7）
            fontSizeRulerCard
                .onAppear { exposeSection("typography") }

            Toggle(isOn: $settings.boldTextEnabled) {
                Label("粗体文本", systemImage: "bold")
                    .displayLabelFont(17)
            }
            .tint(settings.themeStyle.color)

            Toggle(isOn: $settings.useSystemFont) {
                Label("使用系统字体", systemImage: "textformat")
                    .displayLabelFont(17)
            }
            .tint(settings.themeStyle.color)

            // 字体家族真实字貌卡（F5）
            if !settings.useSystemFont {
                fontFamilyGallery
            }

            // 行距 A/B 对照 + 标尺（F6/F19）
            lineSpacingABCard

            // 字间距 A/B 对照 + 标尺（F6/F19）
            letterSpacingABCard

            Toggle(isOn: $settings.buttonShapesEnabled) {
                Label("按钮形状", systemImage: "rectangle.roundedtop.fill")
                    .displayLabelFont(17)
            }
            .tint(settings.themeStyle.color)
        } header: {
            Text("文字排版").displayFont(13, weight: .semibold)
        } footer: {
            Text("「中（默认）」档跟随系统文字大小；其余档位全局即时缩放。行距与字间距为相对值，作用于支持排版的文本。")
                .displayFont(13)
        }
    }

    /// 字号刻度卡：6 档滑尺 + 档位名称 + 缩放系数
    private var fontSizeRulerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("字体大小", systemImage: "textformat.size")
                    .displayFont(14)
                Spacer()
                HStack(spacing: 5) {
                    Text(settings.fontSizeTier.title)
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(settings.themeStyle.color)
                    Text(String(format: "%.2f×", settings.fontSizeTier.scale))
                        .displayFont(11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .displayNumericTransition(reduceMotion: systemReduceMotion)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(settings.themeStyle.color.opacity(0.09), in: Capsule())
            }
            Slider(
                value: Binding(
                    get: { Double(DisplayFontSizeTier.allCases.firstIndex(of: settings.fontSizeTier) ?? 2) },
                    set: { newValue in
                        let index = Int(newValue.rounded())
                        let tiers = DisplayFontSizeTier.allCases
                        let tier = tiers[min(max(index, 0), tiers.count - 1)]
                        if tier != settings.fontSizeTier {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                settings.fontSizeTier = tier
                            }
                        }
                    }
                ),
                in: 0...Double(max(DisplayFontSizeTier.allCases.count - 1, 1)),
                step: 1
            )
            .tint(settings.themeStyle.color)
            // 刻度标尺（装饰性，档位信息已由右侧胶囊与滑块值读出）
            HStack(spacing: 0) {
                ForEach(DisplayFontSizeTier.allCases) { tier in
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(settings.fontSizeTier == tier ? settings.themeStyle.color : Color.gray.opacity(0.3))
                            .frame(width: 1.5, height: settings.fontSizeTier == tier ? 8 : 5)
                        Text(tier == .medium ? "中" : String(format: "%.2f", tier.scale))
                            .displayFont(8)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            Text("极小 → 最大，六档联动全局文字；「中」档跟随系统文字大小。")
                .displayFont(10)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    /// 尚未就绪的书法字体家族（批量下载入口的显示条件与数量）
    private var fontGalleryMissingFamilies: [DisplayFontFamily] {
        DisplayFontFamily.allCases.filter { family in
            family != .system && !(settings.fontAvailability[family] ?? .unavailable).isReady
        }
    }

    /// 字体家族真字貌画廊：家族名与中文示例均以自身字体渲染（全部中文全字形）
    private var fontFamilyGallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "signature")
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(settings.themeStyle.color)
                Text("字体样式 · 中文全字形真貌")
                    .displayFont(13, weight: .semibold)
                Spacer()
                if !fontGalleryMissingFamilies.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showFontBatchDialog = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle")
                                .displaySymbolFont(10, weight: .semibold)
                            Text("全部下载")
                                .displayFont(11, weight: .medium)
                        }
                        .foregroundStyle(settings.themeStyle.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(settings.themeStyle.color.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("下载全部未就绪的书法字体，共 \(fontGalleryMissingFamilies.count) 款")
                }
                Text(settings.fontFamily.title)
                    .displayFont(11, weight: .medium)
                    .foregroundStyle(settings.themeStyle.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(settings.themeStyle.color.opacity(0.09), in: Capsule())
            }
            Text("宋/楷/圆等为系统书法字体：首次使用需联网下载（单款约 17–55 MB），一次下载后离线可用、即刻全 App 生效。")
                .displayFont(10)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(DisplayFontFamily.allCases) { family in
                    fontFamilyCell(family)
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("下载全部书法字体？", isPresented: $showFontBatchDialog, titleVisibility: .visible) {
            Button("开始下载（\(fontGalleryMissingFamilies.count) 款）") {
                settings.ensureAllFontFamilies(reason: "gallery_batch")
                showToast("已开始下载 \(fontGalleryMissingFamilies.count) 款字体，完成后自动应用")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将联网下载尚未就绪的书法字体，单款约 17–55 MB，一次下载后离线可用。")
        }
    }

    private func fontFamilyCell(_ family: DisplayFontFamily) -> some View {
        let isSelected = settings.fontFamily == family
        let state = settings.fontAvailability[family] ?? .unavailable
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                settings.fontFamily = family
            }
            settings.ensureFontFamily(family, reason: "gallery_tap")
            switch state {
            case .ready:
                showToast("字体已切换为\(family.title)")
            case .downloading(let percent):
                if let percent {
                    showToast("\(family.title)下载中（\(Int(percent))%），完成后自动应用")
                } else {
                    showToast("\(family.title)下载中，完成后自动应用")
                }
            case .unavailable:
                if family != .system {
                    showToast("\(family.title)开始下载，完成后自动应用")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    // 中文示例：以所选字体真貌渲染，切换差异立即可见
                    Text(family.sampleText)
                        .font(DisplayFontFactory.font(size: 15, weight: .semibold, family: family))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .displaySymbolFont(14)
                            .displayBounce(reduceMotion: systemReduceMotion, value: isSelected)
                            .foregroundStyle(settings.themeStyle.color)
                    }
                    // 下载状态徽章：一键直观看到字体就绪进度
                    if family != .system, isSelected || !state.isReady {
                        fontStateBadge(state, family: family)
                    }
                }
                Text(fontStateLine(family, state: state))
                    .displayFont(10)
                    .foregroundStyle(state == .unavailable && family != .system ? Color.sjzOrange : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? settings.themeStyle.color.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? settings.themeStyle.color.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.2 : 0.7)
            )
        }
        .buttonStyle(CardPressStyle(reduceMotion: systemReduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(family.title)，\(fontStateLine(family, state: state))\(isSelected ? "，当前选中" : "")")
        .accessibilityHint("双击选择该字体家族，全文即时切换；未下载字体将自动联网下载")
    }

    /// 字体状态徽章（下载中[含百分比进度环]/未下载）
    @ViewBuilder
    private func fontStateBadge(_ state: DisplayFontAvailability, family: DisplayFontFamily) -> some View {
        switch state {
        case .ready:
            EmptyView()
        case .downloading(let percent):
            if let percent {
                // 真实下载进度环（系统回调百分比；线性缓动保证丝滑不跳变）
                ZStack {
                    Circle()
                        .stroke(settings.themeStyle.color.opacity(0.16), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.04, min(1, percent / 100)))
                        .stroke(settings.themeStyle.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
                .animation(.linear(duration: 0.25), value: percent)
                .accessibilityLabel("\(family.title)字体下载中，\(Int(percent))%")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(settings.themeStyle.color)
                    .accessibilityLabel("\(family.title)字体下载中")
            }
        case .unavailable:
            Image(systemName: "arrow.down.circle")
                .displaySymbolFont(12, weight: .semibold)
                .foregroundStyle(Color.sjzOrange)
                .accessibilityLabel("\(family.title)字体未下载，点击即下载")
        }
    }

    /// 字体状态说明行
    private func fontStateLine(_ family: DisplayFontFamily, state: DisplayFontAvailability) -> String {
        if family == .system { return "\(family.title) · \(family.subtitle)" }
        switch state {
        case .ready:       return "\(family.title) · \(family.subtitle)"
        case .downloading(let percent):
            if let percent { return "\(family.title) · 字体下载中 \(Int(percent))%" }
            return "\(family.title) · 字体下载中…"
        case .unavailable: return "\(family.title) · 点击即下载（需联网）"
        }
    }

    /// 行距 A/B 对照卡 + 基线标尺（F6/F19）
    private var lineSpacingABCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("行距")
                    .displayFont(14)
                Spacer()
                Text(String(format: "%.2f", settings.lineSpacingFactor))
                    .displayFont(13, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .displayNumericTransition(reduceMotion: systemReduceMotion)
            }
            Slider(
                value: sliderBinding(get: { settings.lineSpacingFactor }, set: { settings.lineSpacingFactor = $0 }),
                in: 0.9...1.5,
                step: 0.02
            ) { editing in
                if !editing { settings.logSliderSettled("line_spacing", settings.lineSpacingFactor) }
            }
            .tint(settings.themeStyle.color)

            HStack(alignment: .top, spacing: 10) {
                // 当前值段落 + 行距基线标尺
                VStack(alignment: .leading, spacing: settings.lineSpacingFactor * 6) {
                    Text("当前")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(settings.themeStyle.color)
                    Text(abSampleText)
                        .displayText(size: 12, baseLineSpacing: 0)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 基线网格示意（条数不随值变化，间距随行距值伸缩）
                    ForEach(0..<3, id: \.self) { index in
                        Rectangle()
                            .fill(settings.themeStyle.color.opacity(0.45))
                            .frame(height: 0.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(settings.themeStyle.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                // 默认对照
                VStack(alignment: .leading, spacing: 6) {
                    Text("默认 1.00")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(abSampleText)
                        .displayText(size: 12, baseLineSpacing: 0)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(0..<3, id: \.self) { index in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(height: 0.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("行距对照：当前 \(String(format: "%.2f", settings.lineSpacingFactor))，默认 1.00")
        }
        .padding(.vertical, 4)
    }

    /// 字间距 A/B 对照卡 + 字距刻度尺（F6/F19）
    private var letterSpacingABCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("字间距")
                    .displayFont(14)
                Spacer()
                Text(String(format: "%.1f pt", settings.letterSpacingValue))
                    .displayFont(13, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .displayNumericTransition(reduceMotion: systemReduceMotion)
            }
            Slider(
                value: sliderBinding(get: { settings.letterSpacingValue }, set: { settings.letterSpacingValue = $0 }),
                in: 0...2,
                step: 0.05
            ) { editing in
                if !editing { settings.logSliderSettled("letter_spacing", settings.letterSpacingValue) }
            }
            .tint(settings.themeStyle.color)

            // 字距刻度尺：竖线间距随字间距值伸缩
            HStack(alignment: .bottom, spacing: settings.letterSpacingValue * 2) {
                ForEach(0..<16, id: \.self) { index in
                    Rectangle()
                        .fill(index % 4 == 0 ? settings.themeStyle.color.opacity(0.6) : settings.themeStyle.color.opacity(0.3))
                        .frame(width: 1, height: index % 4 == 0 ? 12 : 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(settings.themeStyle.color)
                    Text(abSampleText)
                        .displayText(size: 12)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(settings.themeStyle.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("默认 0 pt")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(abSampleText)
                        .displayText(size: 12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("字间距对照：当前 \(String(format: "%.1f", settings.letterSpacingValue)) pt，默认 0 pt")
        }
        .padding(.vertical, 4)
    }

    private let abSampleText = "阳光从高大的落地窗斜斜洒进来，把书页染成温柔的琥珀色。"

    // MARK: - 文章文字颜色（F8 纸面 + F9 历史 + F10 骰子 + F17 对比度）

    private var articleTextColorSection: some View {
        Section {
            // 纸面预览（F8）：白纸 / 深纸双面模拟
            paperPreviewCard
                .onAppear { exposeSection("article_color") }

            // 色板网格（3 列 × 3 行：8 预设 + 自定义）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                ForEach(ArticleTextColorPreset.allCases) { preset in
                    articleColorCard(preset)
                }
            }
            .padding(.vertical, 8)

            // 自定义色扩展面板（色盘 + 十六进制输入 + 骰子 + 历史）
            if settings.articleTextColorPreset == .custom {
                customColorPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // WCAG 对比度自检（F17）
            contrastCheckCard

            // 恢复默认
            if settings.articleTextColorPreset != .system {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        settings.articleTextColorPreset = .system
                    }
                    LogManager.shared.info("display", "文章文字颜色恢复跟随系统")
                } label: {
                    Label("恢复「跟随系统」", systemImage: "arrow.counterclockwise")
                        .displayLabelFont(14, weight: .medium)
                        .frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text("文章文字颜色").displayFont(13, weight: .semibold)
        } footer: {
            Text(articleColorFooterText)
                .displayFont(13)
        }
    }

    /// 纸面预览：白纸 + 深纸双面报纸阅读模拟
    private var paperPreviewCard: some View {
        HStack(spacing: 10) {
            // 白纸
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(paperPreviewLightColor).frame(width: 7, height: 7)
                    Text("白纸晨读")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                Text("深秋的午后，阳光从图书馆高大的落地窗斜斜地洒进来。")
                    .displayFont(12)
                    .foregroundStyle(paperPreviewLightColor)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(contrastText(hex: paperPreviewLightHex, backgroundHex: "FFFFFF"))
                    .displayFont(9, design: .monospaced)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5))

            // 深纸
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(paperPreviewDarkColor).frame(width: 7, height: 7)
                    Text("深纸夜读")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                Text("路灯把梧桐的影子投在石板路上，夜晚的校园安静而温柔。")
                    .displayFont(12)
                    .foregroundStyle(paperPreviewDarkColor)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(contrastText(hex: paperPreviewDarkHex, backgroundHex: "262626"))
                    .displayFont(9, design: .monospaced)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(hex: "262626"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("纸面预览：白纸正文 \(paperPreviewLightHex)，深纸正文 \(paperPreviewDarkHex)")
    }

    private var paperPreviewLightHex: String { settings.articleCSSTextLightHex }
    private var paperPreviewDarkHex: String { settings.articleCSSTextDarkHex }
    private var paperPreviewLightColor: Color { Color(hex: paperPreviewLightHex) }
    private var paperPreviewDarkColor: Color { Color(hex: paperPreviewDarkHex) }

    /// 双环境对比度文案（F17 数据源）
    private func contrastText(hex: String, backgroundHex: String) -> String {
        let ratio = DisplayContrastChecker.contrast(foregroundHex: hex, backgroundHex: backgroundHex)
        return String(format: "%.1f:1", ratio)
    }

    /// WCAG 对比度自检卡（F17）：双环境 + 绿/橙/红徽章
    private var contrastCheckCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(settings.themeStyle.color)
                Text("对比度自检 · WCAG AA")
                    .displayFont(13, weight: .semibold)
                Spacer()
                contrastStatusBadge
            }
            HStack(spacing: 8) {
                contrastEnvironmentRow(icon: "doc.text.fill", title: "白纸", fgHex: paperPreviewLightHex, bgHex: "FFFFFF")
                contrastEnvironmentRow(icon: "moon.stars.fill", title: "深纸", fgHex: paperPreviewDarkHex, bgHex: "262626")
            }
            Text("正文与纸面至少 4.5:1 对比为合规；自定义颜色越接近纸色，阅读越费力，橙色为建议、红色为不合格。")
                .displayFont(10)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(settings.themeStyle.color.opacity(0.05))
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    /// 整体判定徽章：取双环境最差等级
    private var contrastStatusBadge: some View {
        let lightLevel = DisplayContrastChecker.level(for: DisplayContrastChecker.contrast(foregroundHex: paperPreviewLightHex, backgroundHex: "FFFFFF"))
        let darkLevel = DisplayContrastChecker.level(for: DisplayContrastChecker.contrast(foregroundHex: paperPreviewDarkHex, backgroundHex: "262626"))
        let worst: DisplayContrastChecker.ContrastLevel =
            (lightLevel == .fail || darkLevel == .fail) ? .fail
            : (lightLevel == .suggest || darkLevel == .suggest) ? .suggest
            : .pass
        return HStack(spacing: 5) {
            Circle()
                .fill(contrastLevelColor(worst))
                .frame(width: 7, height: 7)
            Text(contrastLevelText(worst))
                .displayFont(11, weight: .semibold, design: .rounded)
        }
        .foregroundStyle(contrastLevelColor(worst))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(contrastLevelColor(worst).opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(contrastLevelColor(worst).opacity(0.3), lineWidth: 0.5))
        .accessibilityLabel("对比度判定：\(contrastLevelText(worst))")
    }

    private func contrastEnvironmentRow(icon: String, title: String, fgHex: String, bgHex: String) -> some View {
        let ratio = DisplayContrastChecker.contrast(foregroundHex: fgHex, backgroundHex: bgHex)
        let level = DisplayContrastChecker.level(for: ratio)
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .displaySymbolFont(11, weight: .semibold)
                .foregroundStyle(contrastLevelColor(level))
            Text(title)
                .displayFont(11, weight: .medium)
            Spacer()
            Text(String(format: "%.1f:1", ratio))
                .displayFont(11, design: .monospaced)
                .foregroundStyle(.secondary)
            Image(systemName: level == .pass ? "checkmark.circle.fill" : (level == .suggest ? "exclamationmark.circle.fill" : "xmark.octagon.fill"))
                .displaySymbolFont(12)
                .foregroundStyle(contrastLevelColor(level))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(contrastLevelColor(level).opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func contrastLevelColor(_ level: DisplayContrastChecker.ContrastLevel) -> Color {
        switch level {
        case .pass: return Color.sjzGreen
        case .suggest: return Color.sjzOrange
        case .fail: return Color.sjzRed
        }
    }

    private func contrastLevelText(_ level: DisplayContrastChecker.ContrastLevel) -> String {
        switch level {
        case .pass: return "合规"
        case .suggest: return "对比度偏低"
        case .fail: return "不合格"
        }
    }

    private var articleColorFooterText: String {
        if settings.articleTextColorPreset == .system {
            return "当前跟随系统，正文使用各页面默认语义色。选择色板后，新闻、招生与机构文章正文、网页原文及长图分享将同步换色，明暗模式自动适配。"
        }
        return "当前：\(settings.articleTextColorSummary) · 已应用于全部文章正文（新闻 / 招生 / 机构 / 网页原文 / 长图分享），明暗模式自动适配。"
    }

    /// Liquid Glass 风格状态胶囊：色点 + 当前预设 + 已生效标记
    private var articleColorStatusCapsule: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(settings.articleBodyColor ?? Color.primary.opacity(0.55))
                .frame(width: 7, height: 7)
            Text("\(settings.articleTextColorSummary) · 已生效")
                .displayFont(11, weight: .semibold, design: .rounded)
        }
        .foregroundStyle(settings.themeStyle.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(settings.themeStyle.color.opacity(0.1)))
        .overlay(Capsule().stroke(settings.themeStyle.color.opacity(0.3), lineWidth: 0.5))
    }

    /// 单张色卡：圆形色块（渐变 + 阴影）+ 选中打勾 + 色名 / 副标题
    private func articleColorCard(_ preset: ArticleTextColorPreset) -> some View {
        let isSelected = settings.articleTextColorPreset == preset
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                settings.articleTextColorPreset = preset
            }
            LogManager.shared.debugLog("display", "文章文字颜色色卡点击", context: [
                "preset": preset.rawValue, "title": preset.title
            ])
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(articleColorCardFill(preset))
                        .frame(width: 38, height: 38)
                        .shadow(color: articleColorCardAccent(preset).opacity(isSelected ? 0.45 : 0.2), radius: 6, y: 2)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .displaySymbolFont(13, weight: .bold)
                            .displayBounce(reduceMotion: systemReduceMotion, value: isSelected)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 1)
                            .transition(.scale.combined(with: .opacity))
                    } else if preset == .system {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .displaySymbolFont(12, weight: .bold)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    } else if preset == .custom {
                        Image(systemName: "paintbrush.fill")
                            .displaySymbolFont(14, weight: .semibold)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }
                .overlay(
                    Circle().stroke(isSelected ? Color.primary : .clear, lineWidth: 2)
                        .padding(-5)
                )
                Text(preset.title)
                    .displayFont(11, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(preset.subtitle)
                    .displayFont(9)
                    .foregroundStyle(.secondary.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title)，\(preset.subtitle)\(isSelected ? "，当前选中" : "")")
    }

    private func articleColorCardFill(_ preset: ArticleTextColorPreset) -> LinearGradient {
        switch preset {
        case .system:
            return LinearGradient(colors: [Color(hex: "3A3A3A"), Color(hex: "E8E8E8")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .custom:
            return LinearGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            let base = Color(lightHex: preset.lightHex ?? "1A1A1A", darkHex: preset.darkHex ?? "E8E8E8")
            return LinearGradient(colors: [base, base.opacity(0.7)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func articleColorCardAccent(_ preset: ArticleTextColorPreset) -> Color {
        switch preset {
        case .system:   return Color(hex: "6E6E76")
        case .custom:   return Color.sjzAccent
        default:        return Color(lightHex: preset.lightHex ?? "1A1A1A", darkHex: preset.darkHex ?? "E8E8E8")
        }
    }

    /// 自定义色面板：色盘选色 + 十六进制输入（实时校验）+ 随机和谐色 + 颜色历史（F9/F10）
    private var customColorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPicker(selection: customColorBinding, supportsOpacity: false) {
                Label("色盘选色", systemImage: "paintpalette.fill")
                    .displayFont(14)
            }
            .onAppear {
                // 面板出现时同步当前色值到输入框，保证与所选状态一致
                customHexText = settings.articleTextCustomHex
            }
            // 确认入史按钮（颜色定稿后一键收藏）
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                settings.pushCustomColor(settings.articleCustomHexNormalized)
                showToast("已收藏颜色 #\(settings.articleCustomHexNormalized)")
            } label: {
                Label("收藏当前颜色", systemImage: "star.fill")
                    .displayLabelFont(12, weight: .semibold)
                    .foregroundStyle(settings.themeStyle.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(settings.themeStyle.color.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "number")
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(settings.themeStyle.color)
                TextField("1A1A1A", text: $customHexText)
                    .displayFont(14, design: .monospaced)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onChange(of: customHexText) { _, newValue in
                        applyCustomHexIfValid(newValue)
                    }
                if isCustomHexValid(customHexText) {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(15)
                        .foregroundStyle(Color.sjzGreen)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .displaySymbolFont(15)
                        .foregroundStyle(Color.sjzOrange)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.05))
            )

            // 随机和谐色骰子（F10）
            HStack(spacing: 10) {
                Button {
                    let now = Date()
                    guard now.timeIntervalSince(lastDiceAt) >= 0.3 else { return }
                    lastDiceAt = now
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let hex = Self.randomHarmoniousHex()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        settings.articleTextCustomHex = hex
                    }
                    customHexText = hex
                    settings.pushCustomColor(hex)
                    showToast("随机和谐色 #\(hex)")
                    LogManager.shared.debugLog("display", "随机和谐色生成", context: ["hex": hex])
                } label: {
                    Label("随机和谐色", systemImage: "dice.fill")
                        .displayLabelFont(12, weight: .semibold)
                        .foregroundStyle(settings.themeStyle.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(settings.themeStyle.color.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                Text("同明度相邻色相 · 深色文本友好")
                    .displayFont(10)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // 颜色历史（F9）
            if !settings.customColorHistory.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("最近收藏")
                            .displayFont(12, weight: .semibold)
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            settings.clearCustomColorHistory()
                            showToast("颜色历史已清空")
                        } label: {
                            Text("清空")
                                .displayFont(11)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 14) {
                        ForEach(settings.customColorHistory, id: \.self) { hex in
                            historyColorDot(hex)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func historyColorDot(_ hex: String) -> some View {
        let isCurrent = hex == settings.articleCustomHexNormalized
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                settings.articleTextCustomHex = hex
            }
            customHexText = hex
            settings.pushCustomColor(hex)
            LogManager.shared.debugLog("display", "历史颜色复用", context: ["hex": hex])
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 30, height: 30)
                    .shadow(color: Color(hex: hex).opacity(0.4), radius: 4, y: 1)
                if isCurrent {
                    Circle()
                        .stroke(Color.primary, lineWidth: 1.5)
                        .frame(width: 37, height: 37)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("使用历史颜色 \(hex)\(isCurrent ? "，当前颜色" : "")")
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.articleCustomHexNormalized) },
            set: { newColor in
                let hex = Self.hexString(from: newColor)
                settings.articleTextCustomHex = hex
                customHexText = hex
            }
        )
    }

    /// Color → 6 位十六进制（以浅色环境解析，保证语义色提取稳定）
    private static func hexString(from color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())   // 默认浅色环境
        return String(format: "%02X%02X%02X",
                      Int((resolved.red * 255).rounded()),
                      Int((resolved.green * 255).rounded()),
                      Int((resolved.blue * 255).rounded()))
    }

    /// 随机和谐色：同明度（文本色需足够深的亮度区间）随机色相/饱和 → 6 位 hex
    private static func randomHarmoniousHex() -> String {
        let hue = Double.random(in: 0...1)
        let saturation = Double.random(in: 0.18...0.5)
        let lightness = Double.random(in: 0.24...0.40)
        return hslToHex(h: hue, s: saturation, l: lightness)
    }

    /// HSL → hex（标准换算，h/s/l ∈ 0...1）
    private static func hslToHex(h: Double, s: Double, l: Double) -> String {
        func hueChannel(_ p: Double, _ q: Double, _ tRaw: Double) -> Double {
            var t = tRaw
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let r = hueChannel(p, q, h + 1.0 / 3.0)
        let g = hueChannel(p, q, h)
        let b = hueChannel(p, q, h - 1.0 / 3.0)
        return String(format: "%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }

    private func isCustomHexValid(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return cleaned.count == 6 && UInt64(cleaned, radix: 16) != nil
    }

    private func applyCustomHexIfValid(_ text: String) {
        guard isCustomHexValid(text) else { return }
        let cleaned = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        settings.articleTextCustomHex = cleaned
        LogManager.shared.debugLog("display", "十六进制输入应用自定义颜色", context: ["hex": cleaned])
    }

    private func sliderBinding(get: @escaping () -> Double, set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }

    // MARK: - 阅读统计（正文字数 + 预计阅读时长）

    private var readingStatsSection: some View {
        Section {
            // 实时预览段落卡片（当前档位下即时演算）
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .displaySymbolFont(13, weight: .semibold)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(settings.themeStyle.color)
                    Text("阅读统计实时预览")
                        .displayFont(13, weight: .semibold)
                    Spacer()
                    readingStatsStatusCapsule
                }
                Text(readingPreviewSample)
                    .displayText(size: 14, baseLineSpacing: 4)
                    .foregroundStyle(settings.articleBodyColor ?? .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if settings.readingStatsEnabled, let preview = readingPreviewResult {
                    HStack(spacing: 6) {
                        Text("\(ReadingStatsCalculator.formattedCount(preview.totalCount)) 字")
                        Text("·").foregroundStyle(.tertiary)
                        Text(ReadingStatsCalculator.formattedMinutes(preview.minutes))
                    }
                    .displayFont(12)
                    .foregroundStyle(settings.themeStyle.color)
                    .monospacedDigit()
                    .transition(.opacity)
                } else {
                    Text("统计已关闭：正文不再显示字数与阅读时长。")
                        .displayFont(11)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(settings.themeStyle.color.opacity(0.07))
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .onAppear { exposeSection("reading_stats") }

            // 总开关
            Toggle(isOn: $settings.readingStatsEnabled) {
                Label("显示阅读统计", systemImage: "timer")
                    .displayLabelFont(17)
            }
            .tint(settings.themeStyle.color)

            // 服务自检：最近一次统计结果 + 持久化诊断计数（打开任意文章后自动更新）
            HStack(spacing: 8) {
                Image(systemName: readingStatsLastText != nil ? "checkmark.seal.fill" : "clock.badge.questionmark")
                    .displaySymbolFont(13, weight: .semibold)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(readingStatsLastText != nil ? Color.sjzGreen : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let text = readingStatsLastText {
                        Text("服务正常 · 上次统计 \(text)")
                            .lineLimit(2)
                    } else {
                        Text("服务正常 · 尚无统计记录")
                            .lineLimit(2)
                    }
                    let diag = ReadingStatsCache.shared.diagnostics
                    let mountedTime = diag.lastMountedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "从未"
                    let resolveTime = diag.lastResolveAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "从未"
                    Text("详情页组件已出现 \(diag.mounted) 次（最近 \(mountedTime)）· 计算尝试 \(diag.resolveAttempts) 次（最近 \(resolveTime)）")
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    let badgeMountedTime = diag.lastBadgeMountedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "从未"
                    let badgeComputedTime = diag.lastBadgeComputedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "从未"
                    Text("角标挂载 \(diag.badgeMounted) 次（最近 \(badgeMountedTime)）· 摘要估算 \(diag.badgeComputed) 次（最近 \(badgeComputedTime)）")
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .id(selfCheckTick)
            .displayFont(12)
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            // 细分开关：总开关开启时展示
            if settings.readingStatsEnabled {
                Toggle(isOn: $settings.readingCharCountEnabled) {
                    Label("正文字数", systemImage: "textformat.characters")
                        .displayLabelFont(17)
                }
                .tint(settings.themeStyle.color)

                Toggle(isOn: $settings.readingTimeEnabled) {
                    Label("预计阅读时长", systemImage: "clock")
                        .displayLabelFont(17)
                }
                .tint(settings.themeStyle.color)

                Toggle(isOn: $settings.readingListBadgeEnabled) {
                    Label("列表卡片阅读角标", systemImage: "rectangle.stack.badge.play")
                        .displayLabelFont(17)
                }
                .tint(settings.themeStyle.color)

                // 角标设置：分级配色实时预览（与列表缩略图角标完全同规范）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "paintpalette.fill")
                            .displaySymbolFont(13, weight: .semibold)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(settings.themeStyle.color)
                        Text(settings.readingListBadgeEnabled ? "角标设置 · 分级配色" : "角标设置 · 已关闭")
                            .displayFont(13, weight: .semibold)
                        Spacer()
                    }
                    if settings.readingListBadgeEnabled {
                        HStack(spacing: 8) {
                            ForEach(badgePreviewSamples) { sample in
                                badgePreviewCapsule(sample)
                            }
                        }
                        Text("按阅读时长自动分档着色：速览（绿）≤4 分钟 · 标准（蓝）5–9 分钟 · 长文（橙）10–19 分钟 · 深度（紫）≥20 分钟。位置、字号、圆角与内边距在所有卡片上完全一致。")
                            .displayFont(10)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    } else {
                        Text("开启后，所有文章列表卡片的缩略图右下角将显示分级配色的阅读时长角标。")
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(settings.readingListBadgeEnabled
                              ? settings.themeStyle.color.opacity(0.06)
                              : Color.secondary.opacity(0.06))
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                Picker("阅读速度", selection: $settings.readingSpeedTier) {
                    ForEach(ReadingSpeedTier.allCases) { tier in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.title)
                                .displayFont(16)
                            Text(tier.subtitle).displayFont(11).foregroundStyle(.secondary)
                        }
                        .tag(tier)
                    }
                }
                .displayFont(16)
            }
        } header: {
            Text("阅读统计").displayFont(13, weight: .semibold)
        } footer: {
            Text(readingStatsFooterText)
                .displayFont(13)
        }
    }

    private var readingStatsFooterText: String {
        guard settings.readingStatsEnabled else {
            return "开启后，文章详情页标题下方将展示「X 字 · 阅读约 Y 分钟」；曾在详情页打开过的文章，列表卡片同步显示时长徽标。"
        }
        let speedText = settings.readingSpeedTier.subtitle
        var parts = "当前：\(speedText)。"
        if settings.readingCharCountEnabled && settings.readingTimeEnabled {
            parts += "字数与阅读时长同时展示；"
        } else if settings.readingCharCountEnabled {
            parts += "仅展示正文字数；"
        } else if settings.readingTimeEnabled {
            parts += "仅展示阅读时长；"
        } else {
            parts += "两项均已关闭，正文不显示；"
        }
        parts += "列表徽标已\(settings.readingListBadgeEnabled ? "开启" : "关闭")。统计剔除标记与标点，英文按词计入。"
        return parts
    }

    /// Liquid Glass 风格状态胶囊：当前档位 + 启用状态
    private var readingStatsStatusCapsule: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(settings.readingStatsEnabled ? Color.sjzGreen : Color.gray)
                .frame(width: 7, height: 7)
            Text(settings.readingStatsEnabled ? "已启用 · \(settings.readingSpeedTier.title)" : "已关闭")
                .displayFont(11, weight: .semibold, design: .rounded)
        }
        .foregroundStyle(settings.readingStatsEnabled ? settings.themeStyle.color : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(settings.readingStatsEnabled ? settings.themeStyle.color.opacity(0.1) : Color.gray.opacity(0.1)))
        .overlay(Capsule().stroke(
            (settings.readingStatsEnabled ? settings.themeStyle.color : Color.gray).opacity(0.3),
            lineWidth: 0.5
        ))
    }

    /// 最近一次统计结果描述（服务自检行数据源；无记录返回 nil）
    private var readingStatsLastText: String? {
        ReadingStatsCache.shared.lastResolvedDescription
    }

    // MARK: 角标设置预览

    /// 分级样例数据（展示时长值与对应分级；text 即稳定身份，避免每次求值生成新 UUID）
    private struct BadgePreviewSample: Identifiable {
        var id: String { text }
        let text: String
        let tier: ReadingDurationTier
    }

    private let badgePreviewSamples: [BadgePreviewSample] = [
        .init(text: "3分钟", tier: .quick),
        .init(text: "7分钟", tier: .standard),
        .init(text: "12分钟", tier: .longRead),
        .init(text: "25分钟", tier: .deepRead)
    ]

    /// 分级样例胶囊（与列表缩略图角标完全相同规范：8pt 图标 · 10pt 字号 · Capsule · H5.5/V2 · 实心白字 · 高光 · 阴影）
    private func badgePreviewCapsule(_ sample: BadgePreviewSample) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: "clock.fill")
                .displaySymbolFont(8, weight: .bold)
            Text(sample.text)
                .displayFont(10, weight: .bold, design: .rounded)
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2)
        .background(sample.tier.color, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.5))
        .shadow(color: sample.tier.color.opacity(0.4), radius: 3, y: 1)
        .accessibilityLabel("\(sample.text) 阅读（\(sample.tier.title)）")
    }

    /// 预览示例正文（约 130 字，接近真实文章段落风格）
    private let readingPreviewSample = "清晨的校园里，梧桐叶在微风中轻轻摇曳，图书馆的玻璃幕墙映着淡金色的天光。几位同学抱着书本，沿着林荫道走向教学楼，脚步轻快而笃定。操场边，新生们正在晨练，口号声穿过操场，与远处实验楼的仪器低鸣交织成独属于校园的晨间序曲。"

    private var readingPreviewResult: ReadingStatsCalculator.Result? {
        ReadingStatsCalculator.calculate(
            plainText: readingPreviewSample,
            chineseCharsPerMinute: settings.readingCharsPerMinute,
            englishWordsPerMinute: settings.readingWordsPerMinute
        )
    }

    // MARK: - 屏幕（F11 亮度预设 + 光感太阳）

    private var screenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Label("亮度", systemImage: "sun.max.fill")
                        .displayLabelFont(17)
                    Spacer()
                    // 光感太阳：随亮度真实缩放与明暗（视觉直觉）
                    Image(systemName: brightnessSunIcon)
                        .displaySymbolFont(brightnessSunSize, weight: .semibold)
                        .foregroundStyle(brightnessSunColor)
                        .animation(systemReduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: effectiveBrightness)
                    Text(userBrightnessText)
                        .displayFont(13, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .displayNumericTransition(reduceMotion: systemReduceMotion)
                }
                Slider(
                    value: Binding(
                        get: {
                            settings.autoBrightnessEnabled
                                ? Double(settings.activeBrightness)
                                : settings.brightnessValue
                        },
                        set: { settings.brightnessValue = $0 }
                    ),
                    in: 0...1
                ) { editing in
                    if !editing { settings.logSliderSettled("brightness", settings.brightnessValue) }
                }
                .tint(settings.themeStyle.color)
                .disabled(settings.autoBrightnessEnabled)

                // 四档快捷预设（F11）
                HStack(spacing: 8) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { preset in
                        brightnessPresetCapsule(preset)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 2)
            .onAppear { exposeSection("screen") }

            Toggle(isOn: $settings.autoBrightnessEnabled) {
                Label("自动亮度", systemImage: "rays")
                    .displayLabelFont(17)
            }
            .tint(settings.themeStyle.color)
        } header: {
            Text("屏幕").displayFont(13, weight: .semibold)
        } footer: {
            Text(settings.autoBrightnessEnabled
                 ? "自动亮度开启：由系统与环境光实时调节，滑块暂停接管。点击百分比胶囊将自动关闭自动亮度并应用预设。"
                 : "自动亮度关闭：您可手动调节亮度，App 会记忆并在下次启动时恢复。")
                .displayFont(13)
        }
    }

    /// 当前生效亮度（自动亮度时读系统实时值）
    private var effectiveBrightness: Double {
        settings.autoBrightnessEnabled ? Double(settings.activeBrightness) : settings.brightnessValue
    }

    private var brightnessSunSize: CGFloat {
        14 + CGFloat(effectiveBrightness) * 12
    }

    private var brightnessSunIcon: String {
        effectiveBrightness < 0.05 ? "moon.stars.fill" : (effectiveBrightness > 0.75 ? "sun.max.fill" : "sun.max")
    }

    private var brightnessSunColor: Color {
        Color(hex: "F59E0B").opacity(0.45 + effectiveBrightness * 0.55)
    }

    /// 亮度快捷预设胶囊（点击自动关闭自动亮度并应用）
    private func brightnessPresetCapsule(_ value: Double) -> some View {
        let percent = Int((value * 100).rounded())
        let isCurrent = settings.autoBrightnessEnabled == false && abs(settings.brightnessValue - value) < 0.026
        return Button {
            // 改动前快照，保证日志 previous 如实反映切换前状态
            let wasAuto = settings.autoBrightnessEnabled
            let previousText = wasAuto ? "auto" : "\(Int((settings.brightnessValue * 100).rounded()))%"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if wasAuto {
                    settings.autoBrightnessEnabled = false
                }
                settings.brightnessValue = value
            }
            LogManager.shared.debugLog("display", "亮度快捷预设点击", context: [
                "preset": "\(percent)%",
                "previous": previousText
            ])
        } label: {
            Text("\(percent)%")
                .displayFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(isCurrent ? .white : settings.themeStyle.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isCurrent ? settings.themeStyle.color : settings.themeStyle.color.opacity(0.09))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("亮度 \(percent)%，\(isCurrent ? "当前值" : "点击应用")")
    }

    private var userBrightnessText: String {
        if settings.autoBrightnessEnabled {
            return "系统接管"
        }
        return "\(Int(settings.brightnessValue * 100))%"
    }

    // MARK: - 自动锁定

    private var autoLockSection: some View {
        Section {
            Picker("自动锁定", selection: $settings.autoLockOption) {
                ForEach(DisplayAutoLockOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .displayFont(17)
            .onAppear { exposeSection("auto_lock") }

            Button {
                settings.openSystemSettings()
            } label: {
                HStack {
                    Text("在系统设置中调整")
                        .displayFont(17)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(12)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("自动锁定").displayFont(13, weight: .semibold)
        } footer: {
            Text("「永不」将阻止设备自动息屏（阅读场景友好）；其余档位记录您的偏好，设备实际锁定时间需在系统「设置 → 显示与亮度 → 自动锁定」中调整。")
                .displayFont(13)
        }
    }

    // MARK: - 屏幕常亮

    private var keepAwakeSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "F59E0B"), Color(hex: "F97316")],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "sun.max.fill")
                        .displaySymbolFont(18, weight: .semibold)
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: Color(hex: "F59E0B").opacity(0.45), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text("屏幕常亮")
                        .displayFont(15, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text("App 使用期间保持屏幕不熄灭")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $settings.keepAwakeEnabled.animation(.spring(response: 0.35, dampingFraction: 0.8)))
                    .labelsHidden()
                    .tint(Color(hex: "F59E0B"))
                    .onChange(of: settings.keepAwakeEnabled) { _, newValue in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        LogManager.shared.debugLog("display", "屏幕常亮开关交互", context: [
                            "enabled": "\(newValue)", "from": "toggle"
                        ])
                    }
            }
            .onAppear { exposeSection("keep_awake") }

            // 实时状态胶囊（随开关与自动锁定联动变化；文案基于 iOS 实际 idle timer 状态）
            HStack(spacing: 8) {
                Image(systemName: keepAwakeStatusIcon)
                    .displaySymbolFont(11, weight: .semibold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keepAwakeStatusText)
                        .displayFont(12, weight: .medium)
                    if settings.keepAwakeEnabled && settings.lowPowerModeEnabled {
                        Text("已开启低电量模式，系统可能仍会强制熄屏")
                            .displayFont(10)
                            .foregroundStyle(Color.sjzOrange)
                    }
                }
                Spacer()
                if idleTimerDisabledNow {
                    HStack(spacing: 4) {
                        Circle().fill(Color.sjzGreen).frame(width: 6, height: 6)
                        Text("App 已拦截熄屏")
                            .displayFont(10, weight: .semibold)
                    }
                    .foregroundStyle(Color.sjzGreen)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .foregroundStyle(keepAwakeStatusColor)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(keepAwakeStatusColor.opacity(0.09), in: Capsule())
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.keepAwakeEnabled)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.autoLockOption)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.lowPowerModeEnabled)

            // 实时诊断卡：iOS 真实空闲计时器状态 + 系统侧排查指引
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .displaySymbolFont(12, weight: .semibold)
                        .foregroundStyle(Color.sjzPrimary)
                    Text("整机熄屏诊断")
                        .displayFont(13, weight: .bold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(idleTimerNowText)
                        .displayFont(10, weight: .semibold)
                        .foregroundStyle(idleTimerDisabledNow ? Color.sjzOrange : Color.sjzGreen)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((idleTimerDisabledNow ? Color.sjzOrange : Color.sjzGreen).opacity(0.1), in: Capsule())
                }
                Text(diagnosticGuidanceText)
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    LogManager.shared.info("display", "从屏幕常亮诊断跳转系统设置", context: [
                        "idleTimerDisabled": "\(UIApplication.shared.isIdleTimerDisabled)"
                    ])
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("前往系统设置排查", systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                        .displayLabelFont(12, weight: .semibold)
                        .foregroundStyle(Color.sjzPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.sjzPrimary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.sjzPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        } header: {
            Text("屏幕常亮").displayFont(13, weight: .semibold)
        } footer: {
            Text(keepAwakeFooter)
                .displayFont(13)
        }
    }

    /// iOS 真实 idle timer 状态（读系统运行时，非 App 内部推断）
    private var idleTimerDisabledNow: Bool {
        UIApplication.shared.isIdleTimerDisabled
    }

    private var idleTimerNowText: String {
        idleTimerDisabledNow ? "App 拦截中" : "App 未拦截"
    }

    private var diagnosticGuidanceText: String {
        if idleTimerDisabledNow {
            return "当前 iOS 空闲计时器确实被本 App 禁用（由屏幕常亮开关或「自动锁定=永不」带动），关闭两者后此状态会转为「App 未拦截」。"
        }
        return "App 未拦截自动熄屏。若屏幕依然常亮，请依次排查系统侧：① 设置 → 显示与亮度 → 自动锁定是否为「永不」（改为 30 秒等时间档位）；② 设置 → 辅助功能 → 面容 ID 与注视 → 关闭「注视感知功能」；③ 关闭低电量模式后重启设备。"
    }

    private var keepAwakeStatusText: String {
        if settings.keepAwakeEnabled {
            return settings.autoLockOption == .never
                ? "屏幕保持常亮（常亮开关 + 自动锁定「永不」双重生效）"
                : "屏幕保持常亮，直到退出本 App 或手动锁屏"
        }
        if settings.autoLockOption == .never {
            return "自动锁定已设为「永不」，屏幕同样保持常亮"
        }
        return "跟随系统自动息屏设置"
    }

    private var keepAwakeStatusIcon: String {
        if settings.keepAwakeEnabled {
            return "sun.max.fill"
        }
        if settings.autoLockOption == .never {
            return "clock.badge.exclamationmark"
        }
        return "moon.zzz.fill"
    }

    private var keepAwakeStatusColor: Color {
        settings.keepAwakeEnabled || settings.autoLockOption == .never ? Color(hex: "F59E0B") : .secondary
    }

    private var keepAwakeFooter: String {
        if settings.autoLockOption == .never {
            return "提示：上方「自动锁定」已选「永不」，即使关闭本开关屏幕也不会自动熄灭。请将自动锁定调回时间档位，本开关才会独立生效。"
        }
        return "开启后仅在本 App 前台期间保持常亮（阅读、预览与视频场景友好），返回桌面或锁屏后系统立即恢复正常自动熄屏；低电量模式下系统可能仍会强制熄屏。"
    }

    // MARK: - 辅助功能（F12 五项 + F18 灰度专注）

    private var accessibilitySection: some View {
        Section {
            accessibilityRow(title: "减弱动态效果", icon: "wind", enabled: systemReduceMotion, guidance: "减少界面动效与视差")
            accessibilityRow(title: "降低透明度", icon: "square.on.square.dashed", enabled: systemReduceTransparency, guidance: "减少半透明与毛玻璃效果")
            accessibilityRow(title: "增强对比度", icon: "circle.lefthalf.filled", enabled: systemContrast == .increased, guidance: "加深前景与背景的分界")
            accessibilityRow(title: "更深颜色", icon: "circlebadge.fill", enabled: settings.systemDarkerColors, guidance: "调暗整个界面色彩")
            accessibilityRow(title: "旁白（VoiceOver）", icon: "waveform", enabled: settings.systemVoiceOverRunning, guidance: "朗读屏幕内容与控件")
                .onAppear { exposeSection("accessibility") }

            // 专注灰度模式（F18）
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.grayScaleEnabled.animation(.easeInOut(duration: 0.4))) {
                    Label("专注灰度模式", systemImage: "circle.lefthalf.filled")
                        .displayLabelFont(17)
                }
                .tint(settings.themeStyle.color)
                .onChange(of: settings.grayScaleEnabled) { _, newValue in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    LogManager.shared.debugLog("display", "专注灰度模式开关交互", context: [
                        "enabled": "\(newValue)", "from": "toggle"
                    ])
                }

                HStack(spacing: 8) {
                    Image(systemName: settings.grayScaleEnabled ? "eye.fill" : "eye")
                        .displaySymbolFont(11, weight: .semibold)
                    Text(settings.grayScaleEnabled
                         ? "灰度已生效：全 App 转为灰色显示，专注文字阅读"
                         : "开启后全 App 界面与图片转为灰度（含设置页），关闭即 100% 恢复")
                        .displayFont(11)
                        .foregroundStyle(settings.grayScaleEnabled ? settings.themeStyle.color : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    (settings.grayScaleEnabled ? settings.themeStyle.color : Color.gray).opacity(0.08),
                    in: Capsule()
                )
            }
            .padding(.vertical, 4)

            Button {
                settings.openSystemSettings()
            } label: {
                HStack {
                    Label("前往系统设置", systemImage: "gearshape")
                        .displayLabelFont(17)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .displaySymbolFont(12)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("辅助功能").displayFont(13, weight: .semibold)
        } footer: {
            Text("以上开关由系统统一控制，App 实时监听并展示当前状态；开启后 App 界面将自动适配对应效果。")
                .displayFont(13)
        }
    }

    private func accessibilityRow(title: String, icon: String, enabled: Bool, guidance: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .displaySymbolFont(14, weight: .semibold)
                .foregroundStyle(enabled ? settings.themeStyle.color : .secondary)
                .frame(width: 28, height: 28)
                .background((enabled ? settings.themeStyle.color : Color.gray).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .displayFont(15)
                Text(guidance)
                    .displayFont(12)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(enabled ? "已开启" : "未开启")
                .displayFont(12, weight: .medium)
                .foregroundStyle(enabled ? settings.themeStyle.color : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            LogManager.shared.debugLog("display", "辅助功能行点击", context: ["item": title, "enabled": "\(enabled)"])
            settings.openSystemSettings()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(enabled ? "已开启" : "未开启")，\(guidance)")
        .accessibilityHint("双击前往系统设置调整")
    }

    // MARK: - 最近改动时间轴（F13）

    private var historySection: some View {
        Section {
            if settings.changeHistory.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("尚无改动记录")
                            .displayFont(13, weight: .medium)
                        Text("调整上方任意显示设置后，将在此按时间倒序展示最近 20 次变更。")
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(settings.changeHistory.enumerated()), id: \.element.id) { index, record in
                        timelineRow(record, isLast: index == settings.changeHistory.count - 1)
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    settings.clearChangeHistory()
                }
                showToast("改动记录已清空")
            } label: {
                Label("清空记录", systemImage: "trash")
                    .displayLabelFont(13, weight: .medium)
                    .foregroundStyle(settings.changeHistory.isEmpty ? .secondary : Color.sjzRed)
                    .frame(maxWidth: .infinity)
            }
            .disabled(settings.changeHistory.isEmpty)
            .onAppear { exposeSection("history") }
        } header: {
            Text("最近改动").displayFont(13, weight: .semibold)
        } footer: {
            Text("自动记录最近 20 次显示设置变更（含方案套用与亮度预设），仅存于本机。")
                .displayFont(13)
        }
    }

    /// 时间轴行：色点 + 竖线 + 字段/新值 + 相对时间
    private func timelineRow(_ record: DisplayChangeRecord, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(settings.themeStyle.color.opacity(0.85))
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.fieldTitle)
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(.primary)
                    Image(systemName: "arrow.right")
                        .displaySymbolFont(9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    Text(record.value)
                        .displayFont(12)
                        .foregroundStyle(settings.themeStyle.color)
                        .lineLimit(1)
                }
                Text(record.at.formatted(.relative(presentation: .named)))
                    .displayFont(10)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.fieldTitle)改为\(record.value)，\(record.at.formatted(.relative(presentation: .named)))")
    }

    // MARK: - 其他（F15 分享 + 恢复默认 + 版本）

    private var otherSection: some View {
        Section {
            // 分享排版摘要（F15）
            ShareLink(item: settings.shareSummaryText()) {
                HStack {
                    Label("分享我的排版配置", systemImage: "square.and.arrow.up")
                        .displayLabelFont(17)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(12)
                        .foregroundStyle(.tertiary)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                LogManager.shared.info("display", "分享排版摘要", context: [
                    "appearance": settings.appearanceMode.rawValue,
                    "theme": settings.themeStyle.rawValue,
                    "fontTier": settings.fontSizeTier.rawValue
                ])
            })

            Button(role: .destructive) {
                showResetAlert = true
            } label: {
                HStack {
                    Spacer()
                    Label("恢复默认显示设置", systemImage: "arrow.counterclockwise")
                        .displayLabelFont(17)
                    Spacer()
                }
            }
            .disabled(settings.isDefault)

            LabeledContent("应用版本", value: versionText)
                .displayFont(17)
        } header: {
            Text("其他").displayFont(13, weight: .semibold)
        } footer: {
            Text(settings.isDefault ? "当前已是默认显示设置。" : "一键还原外观、字体、屏幕与锁定的全部默认值。")
                .displayFont(13)
        }
    }
}

// MARK: - reduceMotion 动效门控辅助（本页新增动画统一门控）

/// 条件弹跳：reduceMotion 时静态直出
private struct ConditionalBounceModifier<V: Equatable>: ViewModifier {
    let reduceMotion: Bool
    let options: SymbolEffectOptions
    let value: V
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, options: options, value: value)
        }
    }
}

/// 条件数字过渡：reduceMotion 时无数值滚动过渡
private struct NumericTransitionConditionalModifier: ViewModifier {
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.contentTransition(.numericText())
        }
    }
}

private extension View {
    func displayBounce<V: Equatable>(reduceMotion: Bool, options: SymbolEffectOptions = .default, value: V) -> some View {
        modifier(ConditionalBounceModifier(reduceMotion: reduceMotion, options: options, value: value))
    }

    func displayNumericTransition(reduceMotion: Bool) -> some View {
        modifier(NumericTransitionConditionalModifier(reduceMotion: reduceMotion))
    }
}

// MARK: - 卡片按压样式（scale 0.97 回弹，reduceMotion 门控）

private struct CardPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - 扩展：实时系统亮度读取

private extension DisplaySettingsManager {
    /// 仅用于展示：自动亮度开启时读取系统当前亮度（从上下文场景获取屏幕，避免弃用的 UIScreen.main）
    var activeBrightness: CGFloat {
        activeScreen?.brightness ?? 0.5   // 兜底中位亮度：正常前台运行必有场景屏幕
    }
}