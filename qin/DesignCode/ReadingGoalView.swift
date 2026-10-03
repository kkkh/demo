//
//  ReadingGoalView.swift
//  「园枢」阅读目标设置（2026-10-03）
//
//  沉浸式 Sheet：每日/每周目标切换 + 机械滚轮 + 氛围渐变随值微移
//  + 保存/重置（成功触觉 + 完成音效）。与现有功能零交互、可整体卸载。

import SwiftUI

struct ReadingGoalView: View {
    @ObservedObject private var goalStore = ReadingGoalStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var period: ReadingGoalPeriod = .daily
    @State private var draftDaily = 30
    @State private var draftWeekly = 180

    private var range: ClosedRange<Int> {
        period == .daily ? ReadingGoalStore.dailyRange : ReadingGoalStore.weeklyRange
    }
    private var step: Int {
        period == .daily ? 5 : 30
    }
    /// 氛围渐变偏移（随选中值在范围中的比例微移色相/透明度）
    private var atmosphereShift: Double {
        let v = period == .daily ? draftDaily : draftWeekly
        let span = Double(range.upperBound - range.lowerBound)
        return span > 0 ? Double(v - range.lowerBound) / span : 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 随滚轮值微移的氛围渐变（物理感）
                LinearGradient(
                    colors: [
                        Color.sjzAccent.opacity(0.10 + atmosphereShift * 0.12),
                        Color.sjzSkyBlue.opacity(0.06),
                        Color(.systemGroupedBackground)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    // 当前目标展示（等宽大数字）
                    currentGoalCard
                    periodTabs
                    // 机械滚轮容器
                    VStack(spacing: 8) {
                        MechanicalPicker(range: range, step: step,
                                        selection: Binding(
                                            get: { period == .daily ? draftDaily : draftWeekly },
                                            set: { v in
                                                if period == .daily { draftDaily = v } else { draftWeekly = v }
                                            }))
                            .frame(height: 300)
                        unitCaption
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.sjzCard.opacity(0.55))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 8)

                    actionRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("阅读目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .displayFont(15)
                }
            }
            .onAppear {
                period = goalStore.period
                draftDaily = goalStore.dailyMinutes
                draftWeekly = goalStore.weeklyMinutes
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var currentGoalCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "target")
                .displaySymbolFont(18, weight: .semibold)
                .foregroundStyle(Color.sjzAccent)
            Text(period == .daily ? "每日目标" : "每周目标")
                .displayFont(15, weight: .semibold)
            Spacer()
            Text("\(period == .daily ? draftDaily : draftWeekly)")
                .displayFont(40, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(Color.sjzAccent)
                .contentTransition(.numericText(value: Double(period == .daily ? draftDaily : draftWeekly)))
                .animation(reduceMotion ? nil : .snappy, value: period == .daily ? draftDaily : draftWeekly)
            Text("分钟")
                .displayFont(13, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    private var periodTabs: some View {
        HStack(spacing: 4) {
            ForEach(ReadingGoalPeriod.allCases, id: \.self) { p in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { period = p }
                } label: {
                    Text(p.rawValue)
                        .displayFont(14, weight: .semibold)
                        .foregroundStyle(period == p ? Color.sjzPrimary : .secondary)
                        .padding(.horizontal, 22).padding(.vertical, 8)
                        .background {
                            if period == p {
                                Capsule().fill(Color.sjzCard)
                                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.6))
    }

    private var unitCaption: some View {
        Text(period == .daily ? "单位：5 分钟（0–300）" : "单位：30 分钟（0–1800）")
            .displayFont(11, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                goalStore.resetToDefault()
                draftDaily = goalStore.dailyMinutes
                draftWeekly = goalStore.weeklyMinutes
            } label: {
                Label("重置默认", systemImage: "arrow.counterclockwise")
                    .displayLabelFont(14, weight: .medium)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                goalStore.setPeriod(period)
                goalStore.setDaily(draftDaily)
                goalStore.setWeekly(draftWeekly)
                HapticEngine.shared.success()
                dismiss()
            } label: {
                Label("保存目标", systemImage: "checkmark")
                    .displayLabelFont(15, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .background(Capsule().fill(Color.sjzAccent))
                    .shadow(color: Color.sjzAccent.opacity(0.35), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}
