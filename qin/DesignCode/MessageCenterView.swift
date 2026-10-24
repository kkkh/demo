//
//  MessageCenterView.swift
//  山西晋中理工学院 APP — 消息中心（App 内通知盒子）
//
//  我的 → 消息中心：回看全部推送事件（新闻/信箱/概况/党建/收藏更新），
//  Liquid Glass 卡片列表 + 日分组 + 分类筛选 + 本地搜索 + 三态全部已读 +
//  右滑已读/删除 + 下拉刷新（静默检测）+ 立即检查 + 诊断修复面板（长按标题 5 次）。
//

import SwiftUI
import Combine

// MARK: - 消息中心主视图

struct MessageCenterView: View {
    @ObservedObject private var store = MessageCenterStore.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    // 筛选
    private enum FilterMode: Equatable {
        case all, unread, kind(MessageKind)
    }

    @State private var filterMode: FilterMode = .all
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var searchDebounceTask: Task<Void, Never>?

    // 状态
    @State private var showDetailItem: MessageItem?      // 无深链消息的完整详情卡
    @State private var showSettings = false
    @State private var showClearMenu = false
    @State private var showRepairPanel = false
    @State private var repairPressCount = 0
    @State private var now = Date()                       // 相对时间每分钟鲜活
    @State private var markAllPhase = 0                   // 0 idle / 1 running / 2 success
    @State private var silentChecking = false
    @State private var checkResultBanner: String?         // 检测完成反馈
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var launchFailedToast: String?

    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // MARK: 数据

    private var filteredItems: [MessageItem] {
        let kind: MessageKind?
        let unreadOnly: Bool
        switch filterMode {
        case .all: kind = nil; unreadOnly = false
        case .unread: kind = nil; unreadOnly = true
        case .kind(let k): kind = k; unreadOnly = false
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.filter(keyword: keyword.isEmpty ? nil : keyword,
                            kind: kind, unreadOnly: unreadOnly)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if let bannerText = checkResultBanner {
                resultBanner(bannerText)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            searchField
            filterChips
            contentList
        }
        .background(Color(.systemBackground))
        .navigationTitle("消息中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) { MessageCenterSettingsPanel().sjzPresentationChrome() }
        .sheet(item: $showDetailItem) { item in
            MessageDetailCard(item: item)
                .sjzPresentationChrome()
        }
        .sheet(isPresented: $showRepairPanel) { repairPanel.sjzPresentationChrome() }
        .overlay {
            if let toast = launchFailedToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .displayFont(13, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 30)
                        .transition(.opacity)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            LogManager.shared.info("messageCenter", "消息中心页面打开", context: [
                "unread": "\(store.unreadCount)",
                "items": "\(store.items.count)",
                "screen": "messageCenter"
            ])
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            bannerDismissTask?.cancel()
        }
        .onReceive(minuteTimer) { _ in
            now = Date()
        }
        .onChange(of: store.launchState) { _, newState in
            guard case .failed(let reason) = newState else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                launchFailedToast = "内容暂时无法打开：\(reason)"
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { launchFailedToast = nil }
            }
        }
    }

    // MARK: 顶部横幅条

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(Color.sjzPrimary)
                // 长按 5 次触发诊断修复面板（快速修复机制入口）
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        repairPressCount += 1
                        LogManager.shared.debugLog("messageCenter", "诊断入口长按计数", context: [
                            "count": "\(repairPressCount)"
                        ])
                        if repairPressCount >= 5 {
                            repairPressCount = 0
                            showRepairPanel = true
                            LogManager.shared.info("messageCenter", "诊断修复面板已触发", context: [:])
                        }
                    })
            Text("共 \(store.items.count) 条消息")
                .displayFont(13)
                .foregroundStyle(.secondary)
            if store.unreadCount > 0 {
                Text("未读 \(store.unreadCount)")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.red, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            silentCheckButton
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    /// 立即检查按钮（三态：idle → 检测中 → 完成脉冲），观察 NotificationManager.isChecking 撞车反馈
    private var silentCheckButton: some View {
        Button {
            performSilentCheck()
        } label: {
            HStack(spacing: 6) {
                if silentChecking || NotificationManager.shared.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .displaySymbolFont(12, weight: .medium)
                }
                Text(NotificationManager.shared.isChecking && !silentChecking ? "检测中" : "立即检查")
                    .displayFont(12, weight: .medium)
            }
            .foregroundStyle(silentChecking ? Color.secondary : Color.sjzAccent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.sjzAccent.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(silentChecking || NotificationManager.shared.isChecking)
    }

    private func resultBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .displaySymbolFont(14, weight: .semibold)
                .foregroundStyle(.green)
            Text(text)
                .displayFont(12.5, weight: .medium)
                .foregroundStyle(.green)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color.green.opacity(0.1))
    }

    /// 静默检测（下拉/按钮共用）：独立 Task 防手势取消误报
    private func performSilentCheck() {
        guard !silentChecking else { return }
        silentChecking = true
        let start = Date()
        let before = store.items.count
        LogManager.shared.info("messageCenter", "手动立即检查开始（静默检测）", context: [:])
        Task { @MainActor in
            await store.silentCheckNow()
            let elapsed = Date().timeIntervalSince(start)
            let newCount = store.items.count - before
            silentChecking = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                checkResultBanner = "检查完成 · 新增 \(newCount) 条 · 耗时 \(String(format: "%.1f", elapsed))s"
            }
            LogManager.shared.info("messageCenter", "手动立即检查完成", context: [
                "newCount": "\(newCount)",
                "elapsedMs": String(format: "%.0f", elapsed * 1000)
            ])
            bannerDismissTask?.cancel()
            bannerDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                withAnimation(.easeOut(duration: 0.3)) { checkResultBanner = nil }
            }
        }
    }

    // MARK: 搜索框（Liquid Glass + 聚焦描边动画）

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(searchFocused ? Color.sjzAccent : .secondary)
            TextField("搜索消息标题与内容", text: $searchText)
                .displayFont(14)
                .focused($searchFocused)
                .submitLabel(.search)
                .onChange(of: searchText) { _, newValue in
                    searchDebounceTask?.cancel()
                    let kw = newValue
                    searchDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
                        LogManager.shared.info("messageCenter", "消息搜索执行", context: [
                            "keyword": trimmed,
                            "hitCount": "\(store.filter(keyword: trimmed.isEmpty ? nil : trimmed).count)"
                        ])
                    }
                }
            if !searchText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(14)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(
                searchFocused ? Color.sjzAccent : Color.sjzAccent.opacity(0.15),
                lineWidth: searchFocused ? 1.4 : 0.6)
        )
        .padding(.horizontal, 16).padding(.vertical, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)
        .onChange(of: searchFocused) { _, focused in
            LogManager.shared.debugLog("messageCenter", "搜索框焦点变化", context: [
                "focused": "\(focused)", "keywordLength": "\(searchText.count)"
            ])
        }
    }

    // MARK: 分类筛选芯片

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "全部", icon: "tray.full.fill", color: Color.sjzAccent,
                           badge: nil, isSelected: filterMode == .all) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { filterMode = .all }
                    LogManager.shared.debugLog("messageCenter", "筛选切换", context: ["filter": "all"])
                }
                filterChip(label: "未读", icon: "circle.fill", color: .red,
                           badge: "\(store.unreadCount)", isSelected: filterMode == .unread) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { filterMode = .unread }
                    LogManager.shared.debugLog("messageCenter", "筛选切换", context: ["filter": "unread"])
                }
                ForEach(MessageKind.allCases, id: \.self) { kind in
                    let style = MessageCenterStore.style(for: kind)
                    filterChip(label: MessageCenterStore.kindName(kind),
                               icon: style.icon, color: style.color,
                               badge: "\(store.unreadCount(of: kind))",
                               isSelected: filterMode == .kind(kind)) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            filterMode = .kind(kind)
                        }
                        LogManager.shared.debugLog("messageCenter", "筛选切换", context: [
                            "filter": kind.rawValue, "count": "\(store.filter(kind: kind).count)"
                        ])
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 仿 OrganizationView 的筛选芯片样式（原组件文件私有，此处按同款参数复刻）
    private func filterChip(label: String, icon: String, color: Color,
                            badge: String?, isSelected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .displaySymbolFont(11, weight: .medium)
                Text(label)
                    .displayFont(12, weight: .medium)
                if let badge = badge {
                    Text(badge)
                        .displayFont(10, weight: .semibold)
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : color)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected ? .white.opacity(0.2) : color.opacity(0.1)))
                }
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? color : color.opacity(colorScheme == .dark ? 0.12 : 0.08)))
            .overlay(
                Capsule().stroke(isSelected ? color : color.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容列表

    @ViewBuilder
    private var contentList: some View {
        if filteredItems.isEmpty {
            emptyState
        } else if isSearching {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        messageRow(item, index: index,
                                   highlightKeyword: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .modifier(SJZScrollActivityTracker(coordinateSpace: "messageCenterScroll") {
                    LogManager.shared.debugLog("messageCenter", "消息中心滚动方向变化", context: ["direction": $0])
                })
            }
            .coordinateSpace(name: "messageCenterScroll")
            .refreshable { await refreshBody() }
        } else {
            ScrollView {
                LazyVStack(spacing: 14, pinnedViews: []) {
                    ForEach(MessageTimeText.DayGroup.allCases, id: \.self) { group in
                        let groupItems = filteredItems.filter {
                            MessageTimeText.DayGroup.group(for: $0.timestamp) == group
                        }
                        if !groupItems.isEmpty {
                            daySection(header: group.rawValue, items: groupItems)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .modifier(SJZScrollActivityTracker(coordinateSpace: "messageCenterScroll") {
                    LogManager.shared.debugLog("messageCenter", "消息中心滚动方向变化", context: ["direction": $0])
                })
            }
            .coordinateSpace(name: "messageCenterScroll")
            .refreshable { await refreshBody() }
            .modifier(SJZIdleTimerRepairOnScrollStop())
        }
    }

    private func daySection(header: String, items: [MessageItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .displayFont(12, weight: .semibold)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            LazyVStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    messageRow(item, index: index)
                }
            }
        }
    }

    /// 下拉刷新：刷新本体与手势解耦（防 cancelled 误报）
    private func refreshBody() async {
        LogManager.shared.info("messageCenter", "下拉刷新触发静默检测", context: [:])
        let start = Date()
        let before = store.items.count
        await store.silentCheckNow()
        let elapsed = Date().timeIntervalSince(start)
        let newCount = store.items.count - before
        if !Task.isCancelled {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                checkResultBanner = "检查完成 · 新增 \(newCount) 条 · 耗时 \(String(format: "%.1f", elapsed))s"
            }
        }
        LogManager.shared.info("messageCenter", "下拉静默检测完成", context: [
            "newCount": "\(newCount)",
            "elapsedMs": String(format: "%.0f", elapsed * 1000)
        ])
    }

    // MARK: 消息行

    private func messageRow(_ item: MessageItem, index: Int, highlightKeyword: String = "") -> some View {
        let style = MessageCenterStore.style(for: item.kind)
        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            LogManager.shared.info("messageCenter", "消息行点击", context: [
                "id": item.id, "kind": item.kind.rawValue, "wasRead": "\(item.isRead)"
            ])
            if item.deepLink == nil || item.deepLink?.isEmpty == true {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    store.markRead(id: item.id)
                }
                showDetailItem = item
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                store.markRead(id: item.id)
            }
            store.launch(item: item)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(style.color)
                        .frame(width: 42, height: 42)
                    Image(systemName: style.icon)
                        .displaySymbolFont(17, weight: .medium)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if !item.isRead {
                            // 未读光点：纯状态指示器（柔光晕），交互入口统一收敛到长按菜单
                            Circle()
                                .fill(Color.sjzAccent)
                                .frame(width: 8, height: 8)
                                .shadow(color: Color.sjzAccent.opacity(0.45), radius: 4)
                                .accessibilityLabel("未读")
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(messageCenterHighlighted(item.title, keyword: highlightKeyword))
                            .displayFont(15, weight: item.isRead ? .medium : .semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(MessageTimeText.relative(item.timestamp, now: now))
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                    }
                    Text(messageCenterHighlighted(item.subtitle, keyword: highlightKeyword))
                        .displayFont(12.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.ultraThinMaterial)
                    if !item.isRead {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(style.color.opacity(0.07))
                            .transition(.opacity)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(item.isRead ? 0.04 : 0.08), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SJZRevealOnce(key: "msg.\(item.id)", delay: Double(min(index, 12)) * 0.04))
        // 注意：swipeActions 必须位于入场动效修饰器外层——
        // 若被 offset/opacity 动效包裹，滑动手势在 iOS 上会整体失效（用户上报「不能左滑」根因）
        // 右滑 = 双短词固定按钮（各自幂等 no-op）：swipe 展开内容存在陈旧快照，文案恒定为唯一稳解
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    store.markRead(id: item.id)
                }
            } label: {
                Label("已读", systemImage: "circle.fill")
            }
            .tint(Color.sjzAccent)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    store.markUnread(id: item.id)
                }
            } label: {
                Label("未读", systemImage: "circle")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                let impact = UIImpactFeedbackGenerator(style: .rigid)
                impact.impactOccurred()
                withAnimation(.easeInOut(duration: 0.25)) {
                    store.delete(id: item.id)
                }
                LogManager.shared.info("messageCenter", "消息右滑删除", context: ["id": item.id])
            } label: {
                Label("删除", systemImage: "trash.fill")
            }
        }
        .contextMenu {
            if let latest = store.items.first(where: { $0.id == item.id }), latest.isRead {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        store.markUnread(id: item.id)
                    }
                } label: {
                    Label("标记为未读", systemImage: "circle")
                }
            } else {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        store.markRead(id: item.id)
                    }
                } label: {
                    Label("标记为已读", systemImage: "circle.fill")
                }
            }
            Button {
                UIPasteboard.general.string = "\(item.title)\n\(item.subtitle)"
                LogManager.shared.info("messageCenter", "消息复制标题正文", context: ["id": item.id])
            } label: {
                Label("复制内容", systemImage: "doc.on.doc")
            }
            ShareLink(item: "\(item.title)\n\(item.subtitle)") {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(x: -80))))
    }

    // MARK: 空态（三种文案）

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.sjzLight)
                    .frame(width: 100, height: 100)
                Image(systemName: emptyStateIcon)
                    .displaySymbolFont(40)
                    .foregroundStyle(Color.sjzAccent.opacity(0.4))
            }
            VStack(spacing: 8) {
                Text(emptyStateTitle)
                    .displayFont(20, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(emptyStateSubtitle)
                    .displayFont(14)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyStateIcon: String {
        if isSearching { return "magnifyingglass" }
        if store.items.isEmpty { return "tray" }
        return "checkmark.circle"
    }

    private var emptyStateTitle: String {
        if isSearching { return "没有找到相关消息" }
        if store.items.isEmpty { return "暂无消息" }
        return "没有未读消息"
    }

    private var emptyStateSubtitle: String {
        if isSearching { return "换个关键词试试" }
        if store.items.isEmpty {
            return "官网有新内容时会记录在这里\n也可以点击右上角「立即检查」主动查看\n关闭了系统通知也能收到站内消息"
        }
        return "全部消息都已读"
    }

    // MARK: 工具栏（全部已读三态 + 齿轮菜单）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                allReadButton
                Menu {
                    Button {
                        LogManager.shared.debugLog("messageCenter", "打开设置面板", context: [:])
                        showSettings = true
                    } label: {
                        Label("消息中心设置", systemImage: "gearshape")
                    }
                    Button(role: .destructive) {
                        showClearMenu = true
                    } label: {
                        Label("清空历史…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .displaySymbolFont(16, weight: .medium)
                        .foregroundStyle(Color.sjzAccent)
                }
                .confirmationDialog("清空消息历史", isPresented: $showClearMenu, titleVisibility: .visible) {
                    Button("仅清空已读消息", role: .destructive) {
                        let impact = UIImpactFeedbackGenerator(style: .heavy)
                        impact.impactOccurred()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            store.clearHistory(scope: .readOnly)
                        }
                    }
                    Button("清空全部消息", role: .destructive) {
                        let impact = UIImpactFeedbackGenerator(style: .heavy)
                        impact.impactOccurred()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            store.clearHistory(scope: .all)
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("清空操作不可恢复，请谨慎选择。")
                }
            }
        }
    }

    /// 全部已读三态按钮（idle → running 旋转 → success 绿勾脉冲 1.6s）
    private var allReadButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            guard markAllPhase == 0, store.unreadCount > 0 else { return }
            markAllPhase = 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    store.markAllRead()
                }
                markAllPhase = 2
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                markAllPhase = 0
            }
        } label: {
            Group {
                switch markAllPhase {
                case 1:
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                case 2:
                    Image(systemName: "checkmark.seal.fill")
                        .displaySymbolFont(16, weight: .semibold)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                default:
                    Image(systemName: "checkmark.circle")
                        .displaySymbolFont(16, weight: .medium)
                        .foregroundStyle(store.unreadCount > 0 ? Color.sjzAccent : Color.gray.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: markAllPhase)
            .symbolEffect(.pulse, options: .repeating, isActive: markAllPhase == 2)
        }
        .buttonStyle(.plain)
        .disabled(store.unreadCount == 0 && markAllPhase == 0)
        .accessibilityLabel("全部标记已读")
    }

    // MARK: 诊断修复面板（长按标题 5 次）

    private var repairPanel: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .displaySymbolFont(36)
                    .foregroundStyle(Color.sjzGold)
                    .padding(.top, 20)
                Text("消息中心诊断")
                    .displayFont(20, weight: .semibold)
                Text(store.debugSnapshot)
                    .displayFont(13)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    let ok = store.repairRewrite()
                    LogManager.shared.info("messageCenter", "诊断面板执行快速修复", context: ["result": "\(ok)"])
                } label: {
                    Label("重写存储并校验", systemImage: "arrow.triangle.2.circlepath")
                        .displayLabelFont(14, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(Color.sjzPrimary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                Text("日志在「我的 → 应用日志」搜索 messageCenter 查看全链路")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .navigationTitle("快速修复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showRepairPanel = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 无深链消息的完整详情卡

/// 关键词高亮（工程既有 AttributedString 先例风格；Text+Text 拼接已废弃）
private func messageCenterHighlighted(_ text: String, keyword: String) -> AttributedString {
    var attr = AttributedString(text)
    let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !kw.isEmpty else { return attr }
    let lower = text.lowercased()
    var searchStart = lower.startIndex
    while let range = lower.range(of: kw, range: searchStart..<lower.endIndex) {
        if let attrRange = Range(NSRange(range, in: text), in: attr) {
            attr[attrRange].foregroundColor = Color.sjzOrange
        }
        searchStart = range.upperBound
    }
    return attr
}

struct MessageDetailCard: View {
    let item: MessageItem

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        let style = MessageCenterStore.style(for: item.kind)
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(style.color).frame(width: 44, height: 44)
                            Image(systemName: style.icon)
                                .displaySymbolFont(18, weight: .medium)
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MessageCenterStore.kindName(item.kind))
                                .displayFont(12, weight: .medium)
                                .foregroundStyle(style.color)
                            Text(MessageTimeText.relative(item.timestamp))
                                .displayFont(11)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(item.title)
                        .displayFont(22, weight: .bold)
                    Text(item.subtitle)
                        .displayFont(15)
                        .foregroundStyle(.secondary)
                        .lineSpacing(6)
                    HStack {
                        ShareLink(item: "\(item.title)\n\(item.subtitle)") {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .displayLabelFont(13, weight: .medium)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = "\(item.title)\n\(item.subtitle)"
                            LogManager.shared.info("messageCenter", "详情卡复制消息内容", context: ["id": item.id])
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .displayLabelFont(13, weight: .medium)
                        }
                    }
                    .foregroundStyle(Color.sjzAccent)
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("消息详情")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 消息中心设置面板

struct MessageCenterSettingsPanel: View {
    @ObservedObject private var store = MessageCenterStore.shared
    @State private var maxCount: Int = 200
    @State private var autoCheck: Bool = true
    @State private var badgeEnabled: Bool = true
    @State private var showClearConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("消息保留上限", selection: $maxCount) {
                        Text("100 条").tag(100)
                        Text("200 条").tag(200)
                        Text("500 条").tag(500)
                    }
                    .onChange(of: maxCount) { _, newValue in
                        store.maxCount = newValue
                        LogManager.shared.info("messageCenter", "设置：上限条数变更", context: ["maxCount": "\(newValue)"])
                    }
                } header: {
                    Text("存储").displayLabelFont(12)
                } footer: {
                    Text("超出上限时自动清理最早的消息（FIFO）")
                        .displayLabelFont(11)
                }

                Section {
                    Toggle("前台自动检查", isOn: $autoCheck)
                        .onChange(of: autoCheck) { _, newValue in
                            store.setAutoCheck(newValue)
                        }
                    Toggle("桌面角标显示未读数", isOn: $badgeEnabled)
                        .onChange(of: badgeEnabled) { _, newValue in
                            store.setBadgeEnabled(newValue)
                        }
                } header: {
                    Text("检查与提醒").displayLabelFont(12)
                } footer: {
                    Text("前台自动检查每 30 分钟最多执行一次；关闭系统通知也能收到站内消息")
                        .displayLabelFont(11)
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        HStack {
                            Text("清空全部消息").displayLabelFont(14)
                            Spacer()
                            Text("\(store.items.count) 条").displayLabelFont(12).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("消息中心设置")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("确认清空全部消息？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空 \(store.items.count) 条消息", role: .destructive) {
                    let impact = UIImpactFeedbackGenerator(style: .heavy)
                    impact.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        store.clearHistory(scope: .all)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清空后不可恢复，未读计数与角标将同步清零。")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                maxCount = store.maxCount
                autoCheck = store.isAutoCheckEnabled
                badgeEnabled = store.isBadgeEnabled
                LogManager.shared.info("messageCenter", "设置面板打开", context: [
                    "maxCount": "\(maxCount)", "autoCheck": "\(autoCheck)", "badge": "\(badgeEnabled)"
                ])
            }
        }
    }
}