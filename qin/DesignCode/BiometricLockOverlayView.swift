//
//  BiometricLockOverlayView.swift
//  山西晋中理工学院 APP — 生物识别安全遮罩
//
//  职责：
//   1. 全屏安全遮罩：锁定期间遮挡敏感内容（防多任务 App 切换器截图泄露），配套 .privacySensitive()
//   2. 锁定 UI：验证按钮 / 失败提示 / 去系统设置引导 / 验证中进度
//   3. .biometricLockProtected()：敏感页面进入时自动请求上锁
//

import SwiftUI

// MARK: - 全局锁定遮罩

struct BiometricLockOverlayView: View {
    @ObservedObject private var security = BiometricSecurityManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 遮罩背景：随深浅模式；前景内容被完全遮挡，杜绝多任务预览泄露
            if colorScheme == .dark {
                Rectangle()
                    .fill(Color(hex: "0B0D14"))
                    .ignoresSafeArea()
            } else {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color(hex: "0C1F4A"), Color(hex: "1A56B8")],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .ignoresSafeArea()
            }

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial.opacity(0.15))
                            .frame(width: 104, height: 104)
                        Image(systemName: security.capability.icon)
                            .displaySymbolFont(44)
                            .foregroundStyle(.white)
                    }
                    VStack(spacing: 8) {
                        Text(SchoolInfo.name)
                            .displayFont(26, weight: .bold)
                            .foregroundStyle(.white)
                        Text("身份验证")
                            .displayFont(15)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                VStack(spacing: 14) {
                    if security.state == .authenticating {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.1)
                        Text("正在验证身份…")
                            .displayFont(14)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        if let error = security.lastErrorMessage {
                            Text(error)
                                .displayFont(13)
                                .foregroundStyle(.white.opacity(0.95))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                .transition(.opacity)
                        }
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            Task { await security.authenticate() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "faceid")
                                    .displaySymbolFont(16, weight: .semibold)
                                Text(security.capability.isUsable ? "使用 \(security.capability.title) 解锁" : "使用设备密码解锁")
                                    .displayFont(15, weight: .semibold)
                            }
                            .foregroundStyle(Color(hex: "0C1F4A"))
                            .padding(.horizontal, 28).padding(.vertical, 14)
                            .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            security.openSystemSettings()
                        } label: {
                            Label("前往系统设置", systemImage: "gearshape")
                                .displayLabelFont(13)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Text("解锁前内容已加密遮挡 · 连续 5 次失败自动改用设备密码")
                    .displayFont(11)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 32)
        }
        .privacySensitive()
        .animation(.easeInOut(duration: 0.25), value: security.lastErrorMessage)
    }
}

// MARK: - 敏感页面锁定修饰器

/// 挂到敏感页面：进入时若功能启用且未锁定，自动请求上锁（遮罩由根视图统一呈现）
private struct BiometricPageProtectionModifier: ViewModifier {
    @ObservedObject private var security = BiometricSecurityManager.shared
    let reason: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                if security.needsLockRequest {
                    security.requestLock(reason: reason)
                }
            }
    }
}

extension View {
    /// 标记页面为敏感页面：进入时触发锁定（配合全局遮罩）
    func biometricLockProtected(reason: String = "sensitive_page") -> some View {
        modifier(BiometricPageProtectionModifier(reason: reason))
    }
}