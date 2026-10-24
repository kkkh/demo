//
//  HapticEngine.swift
//  「园枢」机械滚轮触觉 + 音效引擎（2026-10-03）
//
//  高保真还原 Apple 闹钟式滚轮手感：
//   · 触觉：UISelectionFeedbackGenerator 逐格 + UIImpactFeedbackGenerator 按速度调强度
//   · 音效：AudioServicesPlaySystemSound(1104) 系统咔哒，与触觉同帧触发（零延迟）
//   · 节流：快速滑动时音效最小间隔 45ms（防噪音），触觉不节流（保持跟手）
//   · 收尾：滚轮静止时补一声完整「咔哒」（medium 冲击 + 音效）

import UIKit
import AudioToolbox

final class HapticEngine {
    static let shared = HapticEngine()

    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    /// 音效节流：两次「咔哒」音效最小间隔
    private let soundMinInterval: TimeInterval = 0.045
    private var lastSoundAt: TimeInterval = 0
    private var lastTickAt: TimeInterval = 0

    private init() {
        // 预热（Apple 推荐：触发前 prepare 以获得零延迟首击）
        selection.prepare()
        light.prepare()
        medium.prepare()
    }

    /// 滚轮逐格触发：触觉必定触发（跟手），音效节流
    /// - Parameter velocity: 最近两格间隔（秒），越小滑动越快
    func tick(interval: TimeInterval) {
        let now = Date().timeIntervalSinceReferenceDate

        // 速度自适应触觉强度：快→密集有力；慢→轻柔有阻力
        if interval < 0.12 {
            medium.impactOccurred(intensity: 0.85)
        } else if interval < 0.25 {
            light.impactOccurred(intensity: 0.95)
        } else {
            light.impactOccurred(intensity: 0.45)
        }

        // 音效节流：快速滑动时降低触发频率
        if now - lastSoundAt >= soundMinInterval {
            AudioServicesPlaySystemSound(1104)   // 系统短咔哒，与触觉同帧
            lastSoundAt = now
        }
        lastTickAt = now
    }

    /// 滚轮收尾：惯性停止时的最后一声清晰「咔哒」
    func settleClick() {
        let now = Date().timeIntervalSinceReferenceDate
        // 若刚 tick 过（<30ms）则视为同一咔哒，避免重复
        guard now - lastTickAt > 0.03 else { return }
        medium.impactOccurred(intensity: 1.0)
        AudioServicesPlaySystemSound(1104)
        lastSoundAt = now
        lastTickAt = now
    }

    /// 目标保存 / 达成：成功反馈（单次）
    func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)
    }
}
