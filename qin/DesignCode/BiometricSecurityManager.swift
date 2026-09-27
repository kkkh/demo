//
//  BiometricSecurityManager.swift
//  山西晋中理工学院 APP — Face ID / Touch ID / Optic ID 生物识别安全模块
//
//  职责：
//   1. 状态机：锁定（含冷启动/后台返回/敏感页面三触发）→ 认证中 → 已解锁
//   2. 能力探测与优雅降级（无硬件 / 模拟器 / 未录入 / 锁定）
//   3. LAError 全 case 友好中文提示 + 系统设置引导
//   4. 持久化分工：UserDefaults 存开关与策略（非敏感），Keychain 存启用令牌（设备密码门控、防备份迁移）
//
//  技术选型：
//   - LAPolicy.deviceOwnerAuthentication：生物识别失败后系统允许使用设备密码，满足「5 次失败自动降级」；
//     生物识别被系统锁定（LAError.biometryLockout）时切换到该策略即可用密码重置。
//   - Keychain 采用 kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly：
//     设备未设置密码时写入失败 → 自然实现「首次启用引导设置设备密码」；
//     ThisDeviceOnly 不随备份迁移 → 换机后必须重新注册，符合安全预期。
//

import Foundation
import SwiftUI
import LocalAuthentication
import Security

// MARK: - 锁定策略

/// 后台返回锁定策略
enum BiometricLockPolicy: String, CaseIterable, Identifiable {
    case immediate
    case oneMinute
    case fiveMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediate:  return "立即锁定"
        case .oneMinute:  return "1 分钟后"
        case .fiveMinutes: return "5 分钟后"
        }
    }

    var window: TimeInterval {
        switch self {
        case .immediate:  return 0
        case .oneMinute:  return 60
        case .fiveMinutes: return 300
        }
    }
}

// MARK: - 生物识别能力

/// 设备生物识别能力
enum BiometricCapability: Equatable {
    case faceID
    case touchID
    case opticID
    case none(SimulatorHint)

    enum SimulatorHint: Equatable {
        case simulator
        case notEnrolled
        case notAvailable
        case passcodeNotSet
    }

    var title: String {
        switch self {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none(.simulator):    return "模拟器（未注册面容）"
        case .none(.notEnrolled):  return "未录入生物识别"
        case .none(.notAvailable): return "设备不支持生物识别"
        case .none(.passcodeNotSet): return "未设置设备密码"
        }
    }

    var icon: String {
        switch self {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "eye.fill"
        case .none:    return "lock.slash"
        }
    }

    var isUsable: Bool {
        if case .none = self { return false }
        return true
    }

    var needsSystemSettings: Bool {
        switch self {
        case .none(.notEnrolled), .none(.passcodeNotSet): return true
        default: return false
        }
    }
}

// MARK: - 认证结果

enum BiometricAuthOutcome {
    case success
    case cancelled                       // 用户主动取消（不提示错误）
    case failed(message: String, goSystemSettings: Bool, isBiometricMatchFailure: Bool)

    static func from(error: Error) -> BiometricAuthOutcome {
        guard let la = error as? LAError else {
            return .failed(message: "身份验证失败：\(error.localizedDescription)", goSystemSettings: false, isBiometricMatchFailure: false)
        }
        switch la.code {
        case .userCancel, .systemCancel, .appCancel:
            return .cancelled
        case .authenticationFailed:
            return .failed(message: "识别未通过，请再试一次", goSystemSettings: false, isBiometricMatchFailure: true)
        case .userFallback:
            return .cancelled   // 用户选择使用设备密码（应由 performEvaluation 降级处理，此处兜底）
        case .biometryNotEnrolled:
            return .failed(message: "尚未录入面容 / 指纹，请先在系统设置中完成录入", goSystemSettings: true, isBiometricMatchFailure: false)
        case .biometryLockout:
            return .failed(message: "生物识别已因多次失败被锁定，请使用设备密码解锁", goSystemSettings: false, isBiometricMatchFailure: true)
        case .biometryNotAvailable:
            return .failed(message: "此设备不支持生物识别", goSystemSettings: false, isBiometricMatchFailure: false)
        case .passcodeNotSet:
            return .failed(message: "设备未设置密码，请先前往系统设置设置设备密码", goSystemSettings: true, isBiometricMatchFailure: false)
        case .notInteractive:
            return .failed(message: "无法显示认证界面，请稍后重试", goSystemSettings: false, isBiometricMatchFailure: false)
        case .invalidContext:
            return .failed(message: "认证上下文已失效，请重试", goSystemSettings: false, isBiometricMatchFailure: false)
        case .biometryDisconnected:
            return .failed(message: "生物识别配件已断开连接，请重新连接", goSystemSettings: false, isBiometricMatchFailure: false)
        case .biometryNotPaired:
            return .failed(message: "尚未配对生物识别配件，请前往系统设置配对", goSystemSettings: true, isBiometricMatchFailure: false)
        default:
            // Xcode 27 SDK 新增 LAError 案例的兜底（已知案例行为不变，新案例走通用失败文案）
            return .failed(message: "身份验证失败（\(la.code.rawValue)），请稍后重试", goSystemSettings: false, isBiometricMatchFailure: false)
        }
    }
}

// MARK: - 管理器

/// 生物识别安全管理器：单例状态机，冷启动 / 后台返回 / 敏感页面统一经由此处锁定与解锁。
@MainActor
final class BiometricSecurityManager: ObservableObject {

    static let shared = BiometricSecurityManager()

    // MARK: 锁定状态机

    enum LockState: Equatable {
        case inactive       // 功能未启用（不锁）
        case locked         // 已锁定，等待认证
        case authenticating // 认证进行中
        case unlocked       // 已解锁
    }

    // MARK: 存储键

    private static let enabledKey     = "biometricEnabled"
    private static let policyKey      = "biometricLockPolicy"
    private static let lastUnlockKey  = "biometricLastUnlockAt"
    private static let keychainService = "com.qinchao.DesignCode.biometric"
    private static let keychainAccount = "enrollment-token"

    // MARK: 发布状态

    @Published private(set) var state: LockState = .inactive
    @Published private(set) var capability: BiometricCapability = .none(.notAvailable)
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var consecutiveFailures = 0

    /// 是否处于安全保护中（已启用且正处于锁定 / 认证状态）
    /// 供通知弹窗调度等场景判断：保护期间不应把内容盖在安全遮罩之上
    var isLockEngaged: Bool {
        isEnabled && (state == .locked || state == .authenticating)
    }

    /// 是否启用（UserDefaults，实时持久化）
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                if state == .inactive || isLaunchUnlockPending {
                    state = .locked
                    isLaunchUnlockPending = false
                }
                LogManager.shared.info("biometric", "Face ID 解锁已启用", context: ["policy": lockPolicy.rawValue])
            } else {
                state = .inactive
                BiometricKeychain.deleteToken(service: Self.keychainService, account: Self.keychainAccount)
                LogManager.shared.info("biometric", "Face ID 解锁已关闭")
            }
        }
    }

    /// 锁定策略
    @Published var lockPolicy: BiometricLockPolicy {
        didSet {
            UserDefaults.standard.set(lockPolicy.rawValue, forKey: Self.policyKey)
            LogManager.shared.debugLog("biometric", "锁定策略变更", context: ["policy": lockPolicy.rawValue])
        }
    }

    /// 冷启动解锁待处理标记（启用后首个锁定时机）
    private var isLaunchUnlockPending = false
    private var lastBackgroundAt: Date?
    private var lastUnlockTime: Date?

    // MARK: - 初始化

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) != nil
            ? UserDefaults.standard.bool(forKey: Self.enabledKey) : false
        lockPolicy = BiometricLockPolicy(
            rawValue: UserDefaults.standard.string(forKey: Self.policyKey) ?? ""
        ) ?? .immediate
        if isEnabled {
            // 冷启动默认锁定
            lastErrorMessage = nil
            state = .locked
            isLaunchUnlockPending = false
        } else {
            state = .inactive
        }
        refreshCapability()
        LogManager.shared.info("biometric", "安全模块初始化", context: [
            "enabled": "\(isEnabled)",
            "policy": lockPolicy.rawValue,
            "capability": capability.title,
            "state": state == .locked ? "locked" : "inactive"
        ])
    }

    // MARK: - 能力探测

    /// 探测当前设备生物识别能力（Face ID / Touch ID / Optic ID / 降级路径）
    func refreshCapability() {
        let context = LAContext()
        var error: NSError?
        let canBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if canBiometrics {
            switch context.biometryType {
            case .faceID:  capability = .faceID
            case .touchID: capability = .touchID
            case .opticID: capability = .opticID
            default:       capability = .none(.notAvailable)
            }
        } else {
            let la = error as? LAError
            switch la?.code {
            case .biometryNotEnrolled, .none:
                // 模拟器：无法区分未录入与无硬件时，若环境为模拟器则给出专门提示
                #if targetEnvironment(simulator)
                capability = .none(.simulator)
                #else
                capability = .none(.notEnrolled)
                #endif
            case .passcodeNotSet:
                capability = .none(.passcodeNotSet)
            default:
                capability = .none(.notAvailable)
            }
        }
        LogManager.shared.debugLog("biometric", "能力探测", context: ["capability": capability.title])
    }

    // MARK: - 锁定判定

    /// 敏感页面进入时是否应上锁（仅已解锁状态下才需要）
    var needsLockRequest: Bool {
        isEnabled && state == .unlocked
    }

    /// 后台返回触发：按锁定策略判定是否重新上锁
    func handleReturnToForeground() {
        guard isEnabled else { return }
        let leaveTime = lastBackgroundAt
        lastBackgroundAt = nil
        guard state != .authenticating else {
            LogManager.shared.debugLog("biometric", "认证进行中，跳过后台返回锁定判定")
            return
        }
        guard let leaveTime else {
            LogManager.shared.debugLog("biometric", "未记录进入后台时间，跳过锁定判定（可能为 Face ID 对话框关闭触发）")
            return
        }
        if let unlockTime = lastUnlockTime, Date().timeIntervalSince(unlockTime) < 1.5 {
            LogManager.shared.debugLog("biometric", "刚完成解锁（\(String(format: "%.2f", Date().timeIntervalSince(unlockTime)))秒前），跳过 Face ID 对话框关闭触发的后台返回锁定")
            return
        }
        let elapsed = Date().timeIntervalSince(leaveTime)
        if lockPolicy == .immediate || elapsed > lockPolicy.window || state == .locked {
            if state != .locked {
                lock(reason: "background_return", elapsed: elapsed)
            }
        }
    }

    /// 进入后台：记录时间（供返回时窗口判定）
    func handleDidEnterBackground() {
        guard isEnabled, state != .authenticating else {
            LogManager.shared.debugLog("biometric", "认证进行中，跳过记录后台时间")
            return
        }
        lastBackgroundAt = Date()
        LogManager.shared.debugLog("biometric", "进入后台，锁定计时开始", context: ["policy": lockPolicy.rawValue])
    }

    /// 敏感页面请求锁定
    func requestLock(reason: String) {
        guard isEnabled, state == .unlocked else { return }
        lock(reason: reason, elapsed: nil)
    }

    private func lock(reason: String, elapsed: TimeInterval?) {
        state = .locked
        lastErrorMessage = nil
        LogManager.shared.info("biometric", "已上锁", context: [
            "reason": reason,
            "elapsed": elapsed.map { String(format: "%.1f", $0) } ?? "manual"
        ])
    }

    // MARK: - 认证主入口

    /// 发起解锁认证。success 时置 unlocked 并清零失败计数。
    func authenticate(reason: String = "验证身份以解锁「园枢」") async {
        guard isEnabled, state == .locked else { return }
        state = .authenticating
        lastErrorMessage = nil
        LogManager.shared.debugLog("biometric", "开始身份认证", context: ["reason": reason])

        let outcome: BiometricAuthOutcome = await performEvaluation(reason: reason)

        switch outcome {
        case .success:
            state = .unlocked
            lastUnlockTime = Date()
            consecutiveFailures = 0
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastUnlockKey)
            LogManager.shared.info("biometric", "身份认证成功，已解锁")
        case .cancelled:
            state = .locked
            LogManager.shared.debugLog("biometric", "用户取消认证")
        case .failed(let message, let goSettings, let isMatchFailure):
            state = .locked
            lastErrorMessage = message
            if isMatchFailure {
                consecutiveFailures += 1
                LogManager.shared.warning("biometric", "认证失败", context: [
                    "attempt": "\(consecutiveFailures)",
                    "message": message
                ])
            } else {
                LogManager.shared.warning("biometric", "认证错误", context: ["message": message])
            }
            if goSettings {
                await MainActor.run { NotificationCenter.default.post(name: .biometricNeedsSystemSettings, object: message) }
            }
        }
    }

    /// 底层评估：失败次数达到 5 次或系统锁定后，自动降级到设备密码策略
    private func performEvaluation(reason: String) async -> BiometricAuthOutcome {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var evaluateError: NSError?

        // 生物识别已锁定或连续失败 5 次：直接走设备密码策略（密码解锁成功后生物识别锁定随之重置）
        let usePasscodeRoute = consecutiveFailures >= 5
        let policy: LAPolicy = usePasscodeRoute ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics

        guard context.canEvaluatePolicy(policy, error: &evaluateError) else {
            // 生物识别路由不可用（未录入/不支持/密码未设）：全部降级到设备密码路由
            let fallback = LAContext()
            var fallbackError: NSError?
            guard fallback.canEvaluatePolicy(.deviceOwnerAuthentication, error: &fallbackError) else {
                if let la = evaluateError as? LAError ?? fallbackError as? LAError {
                    return BiometricAuthOutcome.from(error: la)
                }
                return .failed(message: "设备暂不支持身份验证", goSystemSettings: true, isBiometricMatchFailure: false)
            }
            LogManager.shared.debugLog("biometric", "生物识别不可用，降级设备密码", context: [
                "biometry": "\(context.biometryType.rawValue)",
                "route": "deviceOwnerAuthentication"
            ])
            do {
                try await fallback.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return .success
            } catch {
                return BiometricAuthOutcome.from(error: error)
            }
        }

        do {
            try await context.evaluatePolicy(policy, localizedReason: reason)
            return .success
        } catch {
            // 用户点击"使用密码"：降级到设备密码策略
            if let laError = error as? LAError, laError.code == .userFallback {
                LogManager.shared.debugLog("biometric", "用户选择使用设备密码，降级认证")
                let passcodeContext = LAContext()
                do {
                    try await passcodeContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                    return .success
                } catch {
                    return BiometricAuthOutcome.from(error: error)
                }
            }
            let outcome = BiometricAuthOutcome.from(error: error)
            // .biometryLockout → 降级到设备密码（系统提示在密码解锁后自动解除生物识别锁定）
            if case .failed(let message, _, _) = outcome, (error as? LAError)?.code == .biometryLockout {
                LogManager.shared.warning("biometric", "生物识别系统锁定，降级设备密码", context: ["message": message])
                let passcodeContext = LAContext()
                do {
                    try await passcodeContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "使用设备密码解锁并重置 Face ID")
                    return .success
                } catch {
                    return BiometricAuthOutcome.from(error: error)
                }
            }
            return outcome
        }
    }

    // MARK: - 首次启用（引导密码 + 注册）

    /// 尝试启用：引导设备密码（Keychain 门控）→ 认证通过后写入启用令牌并开启
    func enableWithGuidedFlow() async -> String? {
        refreshCapability()
        guard capability.isUsable else {
            let hint = capability.needsSystemSettings
                ? "\(capability.title)，请先前往系统设置完成配置"
                : "\(capability.title)，暂无法启用 Face ID 解锁"
            LogManager.shared.warning("biometric", "启用被拒：能力不可用", context: ["capability": capability.title])
            return hint
        }
        // Keychain 门控：设备未设置密码时写入失败 → 引导设置密码
        guard BiometricKeychain.saveToken(service: Self.keychainService, account: Self.keychainAccount) else {
            LogManager.shared.warning("biometric", "启用被拒：设备密码未设置")
            return "检测到设备尚未设置密码，请先前往系统设置设置设备密码"
        }
        let outcome = await performEvaluation(reason: "开启 Face ID 解锁前，请先验证身份")
        switch outcome {
        case .success:
            isEnabled = true
            state = .locked
            LogManager.shared.info("biometric", "首次启用流程完成，已开启并进入锁定状态")
            return nil
        case .cancelled:
            BiometricKeychain.deleteToken(service: Self.keychainService, account: Self.keychainAccount)
            LogManager.shared.debugLog("biometric", "用户取消启用流程")
            return nil
        case .failed(let message, _, _):
            BiometricKeychain.deleteToken(service: Self.keychainService, account: Self.keychainAccount)
            return message
        }
    }

    /// 关闭（需二次认证）：仅认证通过后才真正关闭
    func disableWithConfirmation() async -> Bool {
        LogManager.shared.info("biometric", "请求关闭 Face ID 解锁（二次认证）")
        let outcome = await performEvaluation(reason: "关闭 Face ID 解锁需要验证您的身份")
        switch outcome {
        case .success:
            isEnabled = false
            state = .inactive
            lastErrorMessage = nil
            LogManager.shared.info("biometric", "二次认证通过，Face ID 解锁已关闭")
            return true
        case .cancelled:
            LogManager.shared.debugLog("biometric", "用户取消关闭操作")
            return false
        case .failed(let message, _, _):
            lastErrorMessage = message
            LogManager.shared.warning("biometric", "关闭操作的二次认证失败", context: ["message": message])
            return false
        }
    }

    /// 跳转系统设置
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        LogManager.shared.info("biometric", "跳转系统设置", context: ["trigger": "biometric_setup"])
    }
}

// MARK: - 系统设置引导通知

extension Notification.Name {
    /// 生物识别需要用户前往系统设置（未录入 / 未设密码）
    static let biometricNeedsSystemSettings = Notification.Name("biometricNeedsSystemSettings")
}

// MARK: - Keychain 令牌

/// 启用令牌存取：WhenPasscodeSetThisDeviceOnly —— 无密码设备写入失败；不随备份迁移。
private enum BiometricKeychain {

    static func saveToken(service: String, account: String) -> Bool {
        let token = UUID().uuidString + "-" + UUID().uuidString
        guard let data = token.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func deleteToken(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}