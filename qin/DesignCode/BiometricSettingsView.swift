//
//  BiometricSettingsView.swift
//  山西晋中理工学院 APP — Face ID 解锁设置页
//
//  包含：总开关（关闭需二次认证）、锁定策略、能力状态、首次启用引导、说明与日志埋点。
//

import SwiftUI

struct BiometricSettingsView: View {
    @ObservedObject private var security = BiometricSecurityManager.shared
    @State private var showDisableAlert = false
    @State private var isEnabling = false
    @State private var enableErrorMessage: String?

    var body: some View {
        Form {
            mainSection
            policySection
            infoSection
        }
        .navigationTitle("Face ID 解锁")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认关闭 Face ID 解锁？", isPresented: $showDisableAlert) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) {
                Task { await performDisable() }
            }
        } message: {
            Text("关闭前需要再次验证您的身份。关闭后冷启动、后台返回与敏感页面将不再要求解锁。")
        }
    }

    // MARK: - 主开关区

    private var mainSection: some View {
        Section {
            Toggle(isOn: securityBinding) {
                Label("启用 Face ID 解锁", systemImage: security.capability.icon)
            }
            .tint(Color.sjzAccent)
            .disabled(isEnabling)

            if security.isEnabled {
                HStack(spacing: 8) {
                    Circle().fill(Color.sjzGreen).frame(width: 8, height: 8)
                    Text(stateTitle)
                        .displayFont(13)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        security.requestLock(reason: "manual_lock_button")
                        LogManager.shared.debugLog("biometric", "设置页手动锁定")
                    } label: {
                        Text("立即锁定")
                            .displayFont(13, weight: .medium)
                    }
                    .disabled(security.state != .unlocked)
                }

                if security.consecutiveFailures > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .displaySymbolFont(12)
                            .foregroundStyle(.orange)
                        Text("本次累计失败 \(security.consecutiveFailures) 次，满 5 次将自动改用设备密码")
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Label("设备能力", systemImage: "cpu")
                Spacer()
                Text(security.capability.title)
                    .displayFont(13)
                    .foregroundStyle(security.capability.isUsable ? Color.secondary : Color.orange)
            }

            if enableErrorMessage != nil {
                Text(enableErrorMessage!)
                    .displayFont(12)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("功能开关")
        } footer: {
            if !security.capability.isUsable {
                Text("当前设备暂不具备生物识别条件。真机请在「系统设置 → 面容 ID 与密码」中录入；模拟器请使用 Xcode 菜单 Features → Face ID → Enrolled 注册。")
            } else {
                Text("关闭开关需要二次身份认证，防止他人在您解锁手机后关闭保护。")
            }
        }
    }

    // MARK: - 锁定策略

    private var policySection: some View {
        Section {
            Picker("后台返回锁定", selection: $security.lockPolicy) {
                ForEach(BiometricLockPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .disabled(!security.isEnabled)
        } header: {
            Text("锁定策略")
        } footer: {
            Text("App 退到后台超过设定时间再次进入时，将重新要求身份认证。「立即锁定」每次返回后台均需认证。")
        }
    }

    // MARK: - 说明

    private var infoSection: some View {
        Section {
            LabeledContent("认证方式", value: security.capability.isUsable ? security.capability.title : "设备密码")
            LabeledContent("降级机制", value: "5 次失败自动转密码")
            LabeledContent("密钥存储", value: "Keychain（本机）")
        } header: {
            Text("安全说明")
        } footer: {
            Text("认证由系统 Secure Enclave 完成，App 无法获取任何生物特征数据。启用令牌与设备密码绑定并仅存本机，换机或抹除后需重新启用。")
        }
    }

    // MARK: - 交互逻辑

    private var stateTitle: String {
        switch security.state {
        case .inactive:       return "已关闭"
        case .locked:         return "已锁定"
        case .authenticating: return "验证中"
        case .unlocked:       return "已解锁"
        }
    }

    private var securityBinding: Binding<Bool> {
        Binding(
            get: { security.isEnabled },
            set: { newValue in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if newValue {
                    Task { await performEnable() }
                } else {
                    showDisableAlert = true
                }
            }
        )
    }

    private func performEnable() async {
        await MainActor.run { isEnabling = true }
        let errorMessage = await security.enableWithGuidedFlow()
        await MainActor.run {
            enableErrorMessage = errorMessage
            if errorMessage != nil {
                LogManager.shared.warning("biometric", "设置页启用失败", context: ["message": errorMessage ?? ""])
            }
            isEnabling = false
        }
    }

    private func performDisable() async {
        _ = await security.disableWithConfirmation()
    }
}