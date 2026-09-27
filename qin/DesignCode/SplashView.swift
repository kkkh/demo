//
//  SplashView.swift
//  山西晋中理工学院 APP — 启动过渡层
//
//  设计说明：
//  - 视觉与 LaunchScreen.storyboard 完全一致，确保无缝过渡
//  - 深蓝色背景 + 校徽图标 + 学校名称 + 校训 + 英文名 + 年份
//  - 不人为延时，App 初始化完成后立即淡出到主页
//  - 支持深浅色模式自适应
//

import SwiftUI

// MARK: - 启动页视图

struct SplashView: View {
    /// 当 App 初始化完成时，外部设置为 true 触发淡出过渡
    @Binding var isAppReady: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var opacity: Double = 1.0
    @State private var scale: Double = 0.92
    @State private var textOpacity: Double = 0.0
    @State private var iconScale: Double = 0.8

    /// 渐变颜色 —— 浅色模式品牌海军蓝，深色模式近黑色无缝融入暗色 UI
    private var heroGradientColors: [Color] {
        colorScheme == .dark
            ? [Color(hex: "05050A"), Color(hex: "0D0F17"), Color(hex: "151A26")]
            : [Color(hex: "060D24"), Color(hex: "0C1F4A"), Color(hex: "1A56B8")]
    }

    var body: some View {
        ZStack {
            // 深蓝色渐变背景 —— 与 LaunchScreen.storyboard 完全一致，支持深浅色自适应
            LinearGradient(
                colors: heroGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // 内容层
            VStack(spacing: 0) {
                Spacer()

                // 校徽图标
                Image("splash_icon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .scaleEffect(iconScale)
                    .shadow(color: .white.opacity(0.15), radius: 20, y: 8)

                Spacer().frame(height: 24)

                // 学校名称
                Text("山西晋中理工学院")
                    .displayFont(28, weight: .bold)
                    .foregroundColor(.white)
                    .tracking(2)

                Spacer().frame(height: 12)

                // 校训
                Text("谨信博学  经世致用")
                    .displayFont(16, weight: .medium)
                    .foregroundColor(.white.opacity(0.7))
                    .tracking(4)

                Spacer().frame(height: 12)

                // 英文名称
                Text("SHANXI JINZHONG INSTITUTE OF TECHNOLOGY")
                    .displayFont(11, weight: .light)
                    .foregroundColor(.white.opacity(0.5))
                    .tracking(1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 40)

                Spacer()

                // 底部年份
                Text("SINCE 2002")
                    .displayFont(12, weight: .light)
                    .foregroundColor(.white.opacity(0.35))
                    .tracking(3)
                    .padding(.bottom, 40)
            }
            .opacity(textOpacity)
            .scaleEffect(scale)
        }
        .opacity(opacity)
        .onAppear {
            // 入场动画：图标轻微弹入，文字渐显
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                textOpacity = 1.0
                scale = 1.0
            }
        }
        .onChange(of: isAppReady) { _, ready in
            guard ready else { return }
            // App 初始化完成 → 淡出过渡到主页
            withAnimation(.easeInOut(duration: 0.35)) {
                opacity = 0.0
                scale = 1.05
            }
        }
    }
}

// MARK: - 预览

#Preview("浅色模式") {
    SplashView(isAppReady: .constant(false))
        .preferredColorScheme(.light)
}

#Preview("深色模式") {
    SplashView(isAppReady: .constant(false))
        .preferredColorScheme(.dark)
}