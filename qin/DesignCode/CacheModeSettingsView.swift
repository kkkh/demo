//
//  CacheModeSettingsView.swift
//  山西晋中理工学院 APP — 缓存模式设置页
//
//  包含：模式选择卡片（即时刷新 / 缓存模式）· 实时缓存统计面板 · 命中率仪表盘
//        节省流量统计 · 重置统计 · 清空缓存 · 完整日志埋点
//

import SwiftUI

struct CacheModeSettingsView: View {
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @ObservedObject private var dataService = DataService.shared
    @State private var showResetStatsAlert = false
    @State private var showClearCacheAlert = false
    @State private var showImageCacheClearAlert = false
    @State private var statsAppeared = false
    // E11：切回即时模式缓存过大时的清理引导
    @State private var showModeSwitchConfirm = false
    @State private var pendingMode: CacheMode?

    private var snapshot: CacheStatsSnapshot {
        cacheManager.snapshot
    }

    var body: some View {
        Form {
            modeSelectionSection
            imageFreeModeSection
            livePreviewSection
            statisticsSection
            trafficSection
            imageCacheCenterSection
            managementSection
        }
        .navigationTitle("缓存模式")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认重置统计数据？", isPresented: $showResetStatsAlert) {
            Button("取消", role: .cancel) {}
            Button("重置") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    cacheManager.resetStats()
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } message: {
            Text("将清空命中率、请求次数、节流统计等数据，重新开始统计。不会清除已缓存的文章内容。")
        }
        .alert("确认清空全部缓存？", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                withAnimation {
                    cacheManager.clearImageCache()
                    cacheManager.resetStats()
                }
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        } message: {
            Text("将清空文章详情缓存与全部图片缓存，缓存统计一并重置。下次浏览时将重新从网络加载。")
        }
        .alert("清理图片缓存后切换？", isPresented: $showModeSwitchConfirm) {
            Button("保留缓存直接切换", role: .cancel) {
                if let mode = pendingMode { applyMode(mode) }
                pendingMode = nil
            }
            Button("清理并切换") {
                cacheManager.clearImageCache()
                if let mode = pendingMode { applyMode(mode) }
                pendingMode = nil
            }
        } message: {
            Text("当前已缓存 \(ByteCountFormatter.string(fromByteCount: Int64(cacheManager.imageCacheDiskUsage), countStyle: .file)) 图片。清理可释放存储空间；切回即时刷新后每次将实时联网加载。")
        }
        .alert("确认清理图片缓存？", isPresented: $showImageCacheClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                withAnimation {
                    cacheManager.clearImageCache()
                }
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        } message: {
            Text("将释放 \(ByteCountFormatter.string(fromByteCount: Int64(cacheManager.imageCacheDiskUsage), countStyle: .file)) 空间。文章收藏、已读记录与详情缓存不受影响，图片将重新下载。")
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.6)) {
                    statsAppeared = true
                }
            }
            LogManager.shared.info("cache", "进入缓存模式设置页", context: [
                "mode": cacheManager.mode.rawValue,
                "hitRate": cacheManager.hitRatePercent
            ])
        }
    }

    // MARK: - 无图模式

    /// 无图模式设置区：全局开关 + 状态胶囊 + 跳过计数 + 说明（省流利器）
    private var imageFreeModeSection: some View {
        Section {
            Toggle(isOn: $cacheManager.imageFreeModeEnabled) {
                Label("无图模式", systemImage: "photo.on.rectangle.angled")
            }
            .tint(Color.sjzTeal)

            // 状态胶囊 + 跳过统计（直观状态提示）
            HStack(spacing: 8) {
                Image(systemName: cacheManager.imageFreeModeEnabled ? "leaf.fill" : "photo.fill")
                    .displaySymbolFont(13, weight: .semibold)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(cacheManager.imageFreeModeEnabled ? Color.sjzGreen : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cacheManager.imageFreeModeEnabled ? "无图模式已开启 · 全程省流" : "无图模式已关闭 · 完整图文")
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(cacheManager.imageFreeModeEnabled ? Color.sjzGreen : .primary)
                    Text("已累计跳过 \(cacheManager.imageFreeSkippedCount) 张图片 · 正文文字与视频不受影响")
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.vertical, 4)

            // 说明卡
            VStack(alignment: .leading, spacing: 6) {
                Label("适合弱网与省流量场景", systemImage: "wifi.slash")
                    .displayLabelFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzTeal)
                Text("开启后所有图片位置显示柔和占位，不再消耗流量；文章正文、视频播放与阅读统计等全部功能不受影响。关闭后图片自动恢复加载。")
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.sjzTeal.opacity(0.06))
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        } header: {
            Text("无图模式")
        } footer: {
            Text("无图模式优先于缓存模式生效：图片请求完全不起网络。")
        }
    }

    // MARK: - 模式选择

    /// 模式切换入口（E11：缓存过大时先确认是否清理）
    private func handleModeSelection(_ mode: CacheMode) {
        if mode == .instant, cacheManager.isCacheEnabled,
           cacheManager.imageCacheDiskUsage > 50 * 1024 * 1024 {
            pendingMode = mode
            showModeSwitchConfirm = true
            LogManager.shared.info("cache", "切换即时模式触发缓存清理引导", context: [
                "diskUsage": ByteCountFormatter.string(fromByteCount: Int64(cacheManager.imageCacheDiskUsage), countStyle: .file)
            ])
            return
        }
        applyMode(mode)
    }

    private func applyMode(_ mode: CacheMode) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            cacheManager.mode = mode
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var modeSelectionSection: some View {
        Section {
            VStack(spacing: 16) {
                ForEach(CacheMode.allCases) { mode in
                    ModeSelectionCard(
                        mode: mode,
                        isSelected: cacheManager.mode == mode,
                        onTap: {
                            handleModeSelection(mode)
                        }
                    )
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("缓存模式")
        } footer: {
            if cacheManager.isCacheEnabled {
                Text("当前为缓存模式，已浏览的内容将自动缓存到本地，再次访问秒开呈现，同时节省流量。")
            } else {
                Text("当前为即时刷新模式，每次浏览都实时加载最新数据，确保内容始终最新。")
            }
        }
    }

    // MARK: - 实时预览卡片

    private var livePreviewSection: some View {
        Section {
            VStack(spacing: 18) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(cacheManager.isCacheEnabled ? Color.sjzGreen.opacity(0.12) : Color.sjzAccent.opacity(0.12))
                            .frame(width: 60, height: 60)
                        Image(systemName: cacheManager.mode.icon)
                            .displaySymbolFont(28, weight: .medium)
                            .foregroundStyle(cacheManager.mode.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(cacheManager.mode.title)
                            .displayFont(18, weight: .semibold)
                        Text(cacheManager.mode.shortDescription)
                            .displayFont(13)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                HStack(spacing: 24) {
                    StatMiniCard(
                        icon: "target",
                        value: cacheManager.hitRatePercent,
                        label: "命中率",
                        color: snapshot.efficiencyColor
                    )
                    StatMiniCard(
                        icon: "shippingbox.fill",
                        value: "\(snapshot.cachedArticleCount)",
                        label: "已缓存",
                        color: cacheManager.isCacheEnabled ? Color.sjzGreen : Color.sjzAccent
                    )
                    StatMiniCard(
                        icon: "arrow.down.doc.fill",
                        value: cacheManager.savedTrafficFormatted,
                        label: "已节省",
                        color: Color.sjzOrange
                    )
                }
            }
            .padding(.vertical, 12)
        } header: {
            Text("实时概览")
        }
    }

    // MARK: - 详细统计

    private var statisticsSection: some View {
        Section {
            VStack(spacing: 20) {
                efficiencyGauge

                Divider()

                VStack(spacing: 12) {
                    StatRow(
                        icon: "checkmark.circle.fill",
                        label: "缓存命中",
                        value: "\(snapshot.hitCount) 次",
                        color: Color.sjzGreen,
                        opacity: statsAppeared ? 1 : 0
                    )
                    StatRow(
                        icon: "arrow.triangle.2.circlepath",
                        label: "缓存未命中",
                        value: "\(snapshot.missCount) 次",
                        color: Color.sjzOrange,
                        opacity: statsAppeared ? 1 : 0
                    )
                    StatRow(
                        icon: "photo.stack.fill",
                        label: "图片缓存命中",
                        value: "\(snapshot.imageCacheHitCount) 次",
                        color: Color.sjzGreen,
                        opacity: statsAppeared ? 1 : 0
                    )
                    StatRow(
                        icon: "photo.badge.arrow.down.fill",
                        label: "图片缓存未命中",
                        value: "\(snapshot.imageCacheMissCount) 次",
                        color: Color.sjzOrange,
                        opacity: statsAppeared ? 1 : 0
                    )
                    StatRow(
                        icon: "clock.badge.checkmark",
                        label: "本次会话",
                        value: cacheManager.sessionDuration,
                        color: .secondary,
                        opacity: statsAppeared ? 1 : 0
                    )
                    StatRow(
                        icon: "memorychip.fill",
                        label: "缓存占用",
                        value: snapshot.formattedMemory,
                        color: .secondary,
                        opacity: statsAppeared ? 1 : 0
                    )
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 8)
        } header: {
            Text("详细统计")
        } footer: {
            Text("数据自会话开始累计。命中率 = 缓存命中次数 ÷ 总请求次数。")
        }
    }

    // MARK: - 效率仪表盘

    private var efficiencyGauge: some View {
        VStack(spacing: 12) {
            HStack {
                Text("缓存效率")
                    .displayFont(15, weight: .medium)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(snapshot.efficiencyColor)
                        .frame(width: 8, height: 8)
                    Text(snapshot.efficiencyRating)
                        .displayFont(14, weight: .semibold)
                        .foregroundStyle(snapshot.efficiencyColor)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 14)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [Color.sjzGreen, Color.sjzAccent, Color.sjzOrange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(snapshot.hitRate, 1.0), height: 14)
                        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: snapshot.hitRate)
                }
                .overlay(alignment: .trailing) {
                    Text(cacheManager.hitRatePercent)
                        .displayFont(11, weight: .bold)
                        .foregroundStyle(.secondary)
                        .offset(x: 4)
                }
            }
            .frame(height: 14)

            HStack(spacing: 0) {
                Text("0%").displayFont(10).foregroundStyle(.tertiary)
                Spacer()
                Text("50%").displayFont(10).foregroundStyle(.tertiary)
                Spacer()
                Text("100%").displayFont(10).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 流量节省

    private var trafficSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.sjzOrange.opacity(0.1))
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.down.circle.fill")
                        .displaySymbolFont(22)
                        .foregroundStyle(Color.sjzOrange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("预估节省流量")
                        .displayFont(15, weight: .medium)
                    Text("基于缓存命中次数与平均文章大小估算")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(cacheManager.savedTrafficFormatted)
                    .displayFont(20, weight: .bold)
                    .foregroundStyle(Color.sjzOrange)
            }
            .padding(.vertical, 4)
        } header: {
            Text("流量节省")
        }
    }

    // MARK: - 图片缓存中心（E2）

    private var imageCacheCenterSection: some View {
        Section {
            let usage = cacheManager.imageCacheDiskUsage
            let capacity = max(cacheManager.imageCacheDiskCapacity, 1)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("图片缓存占用", systemImage: "internaldrive.fill")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file))
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(Color.sjzAccent)
                }

                ProgressView(value: Double(usage), total: Double(capacity))
                    .progressViewStyle(.linear)
                    .tint(Color.sjzAccent)

                HStack {
                    Text("缓存容量上限 \(ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .file))")
                        .displayFont(11)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showImageCacheClearAlert = true
                    } label: {
                        Text("清理图片缓存")
                            .displayFont(12, weight: .medium)
                            .foregroundStyle(Color.sjzOrange)
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("图片缓存中心")
        } footer: {
            Text("图片缓存加速滚动浏览与文章图片的二次加载。清理后图片将重新下载；系统存储紧张时 iOS 也可能自动清理。")
        }
    }

    // MARK: - 管理操作

    private var managementSection: some View {
        Section {
            Button {
                showResetStatsAlert = true
            } label: {
                HStack {
                    Label("重置统计数据", systemImage: "arrow.counterclockwise")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(12)
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }

            Button {
                showClearCacheAlert = true
            } label: {
                HStack {
                    Label("清空全部缓存", systemImage: "trash")
                        .foregroundColor(.red)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .displaySymbolFont(12)
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    cacheManager.resetAll()
                    dataService.clearArticleDetailCache()
                }
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                LogManager.shared.info("cache", "用户执行一键恢复默认缓存设置")
            } label: {
                HStack {
                    Spacer()
                    Label("恢复默认", systemImage: "arrow.uturn.backward")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        } header: {
            Text("管理")
        } footer: {
            Text("重置统计数据不会清除已缓存内容；清空缓存将清除所有文章详情缓存并重置统计。")
        }
    }
}

// MARK: - 子组件

private struct ModeSelectionCard: View {
    let mode: CacheMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isSelected ? mode.accentColor : mode.accentColor.opacity(0.1))
                        .frame(width: 50, height: 50)
                    Image(systemName: mode.icon)
                        .displaySymbolFont(22, weight: .medium)
                        .foregroundStyle(isSelected ? .white : mode.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(mode.title)
                            .displayFont(16, weight: .semibold)
                            .foregroundColor(.primary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .displaySymbolFont(16)
                                .foregroundStyle(mode.accentColor)
                        }
                    }
                    Text(mode.description)
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? mode.backgroundColor : Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSelected ? mode.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.0 : 0.98)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelected)
    }
}

private struct StatMiniCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .displaySymbolFont(16)
                .foregroundStyle(color)
                .frame(height: 22)
            Text(value)
                .displayFont(18, weight: .bold)
                .foregroundColor(.primary)
            Text(label)
                .displayFont(11)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    var opacity: Double = 1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .displaySymbolFont(13)
                .foregroundStyle(color)
                .frame(width: 20)

            Text(label)
                .displayFont(14)
                .foregroundColor(.primary)

            Spacer()

            Text(value)
                .displayFont(14, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .opacity(opacity)
        .animation(.easeOut(duration: 0.4), value: opacity)
    }
}