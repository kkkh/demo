//
//  HomeModuleSettingsView.swift
//  DesignCode
//
//  首页模块管理设置页：开关控制模块显示、编辑模式拖拽排序、一键恢复默认。
//

import SwiftUI

struct HomeModuleSettingsView: View {
    @ObservedObject private var manager = HomeModuleManager.shared
    @ObservedObject private var data = DataService.shared
    @Environment(\.editMode) private var editMode
    @State private var showResetAlert = false

    private var visibleCount: Int {
        manager.visibleOrderedModules.count
    }

    var body: some View {
        List {
            Section {
                ForEach(manager.moduleOrder) { module in
                    moduleRow(module)
                }
                .onMove(perform: move)
            } header: {
                Text("首页显示模块").displayFont(13, weight: .semibold)
            } footer: {
                Text("关闭的模块将不在首页出现。点击右上角「编辑」可拖拽调整模块在首页的显示顺序。首页 Banner、数据统计、快捷入口为固定区域，当前共显示 \(visibleCount) 个模块。")
                    .displayFont(13)
            }

            Section {
                Button(role: .destructive) {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.debugLog("home_modules", "首页模块恢复默认确认弹窗弹出", context: [
                        "hiddenBefore": manager.hiddenModules.map(\.rawValue).sorted().joined(separator: ","),
                        "orderBefore": manager.moduleOrder.map(\.rawValue).joined(separator: ",")
                    ])
                    showResetAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                            .displayLabelFont(17)
                        Spacer()
                    }
                }
                .disabled(manager.isDefault)
            } footer: {
                Text(manager.isDefault ? "当前已是默认状态。" : "重新显示全部模块，并还原为默认排列顺序。")
                    .displayFont(13)
            }
        }
        .navigationTitle("首页模块管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .alert("确认恢复默认？", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {
                LogManager.shared.debugLog("home_modules", "首页模块恢复默认弹窗取消", context: [:])
            }
            Button("恢复默认", role: .destructive) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    manager.resetToDefaults()
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                LogManager.shared.debugLog("home_modules", "首页模块恢复默认弹窗确认", context: [:])
            }
        } message: {
            Text("将重新显示全部模块，并还原为默认排列顺序。")
        }
        .onChange(of: editMode?.wrappedValue.isEditing) { _, isEditing in
            LogManager.shared.debugLog("home_modules", "首页模块编辑模式切换", context: [
                "editing": "\(isEditing ?? false)"
            ])
        }
        .onAppear {
            LogManager.shared.info("home_modules", "首页模块管理页打开", context: [
                "totalModules": "\(HomeModule.allCases.count)",
                "visibleCount": "\(visibleCount)",
                "hiddenCount": "\(manager.hiddenModules.count)",
                "hiddenList": manager.hiddenModules.map(\.rawValue).sorted().joined(separator: ","),
                "isDefault": "\(manager.isDefault)"
            ])
        }
        .onDisappear {
            LogManager.shared.debugLog("home_modules", "首页模块管理页关闭", context: [
                "visibleCount": "\(visibleCount)",
                "hiddenCount": "\(manager.hiddenModules.count)",
                "order": manager.moduleOrder.map(\.rawValue).joined(separator: ",")
            ])
        }
    }

    // MARK: - 模块行

    private func moduleRow(_ module: HomeModule) -> some View {
        Toggle(isOn: visibilityBinding(for: module)) {
            HStack(spacing: 12) {
                Image(systemName: module.icon)
                    .displaySymbolFont(14, weight: .semibold)
                    .foregroundStyle(module.color)
                    .frame(width: 30, height: 30)
                    .background(module.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.title)
                        .displayFont(15, weight: .medium)
                        .foregroundStyle(manager.isVisible(module) ? Color.primary : Color.secondary)
                    Text(moduleSubtitle(module))
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Color.sjzAccent)
    }

    /// 模块副标题：校长信箱为懒加载通道（不参与全局同步），使用专属文案
    private func moduleSubtitle(_ module: HomeModule) -> String {
        if module == .principalMailbox {
            return module.dataCount > 0 ? "当前 \(module.dataCount) 封公开回复" : "校长与师生沟通的公开通道"
        }
        return module.dataCount > 0 ? "当前 \(module.dataCount) \(module.countUnit)内容" : "暂无内容，同步后自动显示"
    }

    private func visibilityBinding(for module: HomeModule) -> Binding<Bool> {
        Binding(
            get: { manager.isVisible(module) },
            set: { newValue in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    manager.setVisible(module, newValue)
                }
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            manager.moveModules(from: source, to: destination)
        }
    }
}