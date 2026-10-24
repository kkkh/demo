//
//  MechanicalPicker.swift
//  「园枢」机械滚轮选择器（2026-10-03）
//
//  高保真 Apple 闹钟式滚轮：
//   · 原生 ScrollView + viewAligned 磁吸（每格精确吸附，天然惯性回弹）
//   · 逐格选中变化 → HapticEngine.tick（触觉+节流音效，速度自适应）
//   · 滚动停止（idle）→ 收尾咔哒（settleClick）
//   · 边界 0...上限，步进对齐，防御性 clamp
//  iOS 17+ API（项目 target 26，安全）。

import SwiftUI

struct MechanicalPicker: View {
    /// 值范围（0...上限，步进为 step 的倍数）
    let range: ClosedRange<Int>
    let step: Int
    @Binding var selection: Int

    @State private var scrollID: Int?
    @State private var lastChangeAt: TimeInterval = 0
    /// 程序化滚动目标（外部 selection 变更驱动，如切周期 Tab / 重置）；
    /// 非 nil 期间抑制触觉与 selection 回写，防止中间值污染 draft
    @State private var programmaticID: Int?

    private var values: [Int] {
        stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                // 顶部/底部留白：让首尾也能停在中线
                Color.clear.frame(height: 92)
                ForEach(values, id: \.self) { value in
                    Text("\(value)")
                        .displayFont(30, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(selection == value ? Color.sjzPrimary : .secondary.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .contentTransition(.numericText(value: Double(value)))
                        .id(value)
                }
                Color.clear.frame(height: 92)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $scrollID)
        .onChange(of: scrollID) { _, newID in
            guard let newID else { return }
            if let target = programmaticID {
                // 程序化滚动：中间值不回写、不触发触觉；到位后清除标记
                if newID == target { programmaticID = nil }
                return
            }
            let now = Date().timeIntervalSinceReferenceDate
            let interval = now - lastChangeAt
            lastChangeAt = now
            selection = min(max(newID, range.lowerBound), range.upperBound)
            HapticEngine.shared.tick(interval: interval)
        }
        // 外部值变更（切周期 Tab / 重置）驱动滚轮平滑跟随
        .onChange(of: selection) { _, newValue in
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            guard scrollID != clamped else { return }
            programmaticID = clamped
            withAnimation(.snappy) { scrollID = clamped }
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting:
                programmaticID = nil   // 用户接管滚动，取消程序化标记
            case .idle:
                HapticEngine.shared.settleClick()
            default: break
            }
        }
        .overlay(alignment: .center) {
            // 中线刻度（闹钟式上下高亮条）
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.sjzAccent.opacity(0.16))
                    .frame(width: 34, height: 56)
                Rectangle().fill(.clear)
            }
            .allowsHitTesting(false)
        }
        .accessibilityLabel("目标分钟滚轮")
        .accessibilityValue("\(selection) 分钟")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                let next = min(selection + step, range.upperBound)
                withAnimation(.snappy) { scrollID = next }
            case .decrement:
                let prev = max(selection - step, range.lowerBound)
                withAnimation(.snappy) { scrollID = prev }
            default: break
            }
        }
        .onAppear {
            // 初始定位到当前值
            scrollID = min(max(selection, range.lowerBound), range.upperBound)
        }
    }
}
