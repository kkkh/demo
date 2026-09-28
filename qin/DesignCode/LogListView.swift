//
//  LogListView.swift
//  山西晋中理工学院 APP — 日志查看页面
//
//  统计头部（总数/今日/今日异常/磁盘占用）· 级别×模块×关键词三维筛选（实时计数 + 高亮）·
//  日期分组列表 · 跟随最新（暂停时悬浮「N 条新日志」）· 滑动操作（复制/删除）·
//  详情卡（完整时间/上下文/JSON/分享）· 按当前筛选导出 txt/json · 三态空态 ·
//  设置入口 · 操作反馈横幅 · 全链路日志域 log。
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - 导出数据模型

/// 使用 Identifiable 模型驱动 .sheet(item:) 展示，确保数据在 sheet 展示前已完全就绪，
/// 消除 .sheet(isPresented:) 在同一次状态更新中因求值时序导致的空数据竞态问题。
private struct ExportData: Identifiable {
    let id = UUID()
    let text: String
    let fileName: String
}

// MARK: - 日志列表页面

struct LogListView: View {
    @ObservedObject private var logManager = LogManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    // MARK: 筛选

    @State private var selectedLevel: LogLevel?
    @State private var selectedModule: String?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var searchDebounceTask: Task<Void, Never>?

    // MARK: 列表状态

    @State private var expandedIds: Set<String> = []
    @State private var detailEntry: LogEntry?
    @State private var copiedId: String?
    @State private var followLatest = true
    @State private var pendingNewCount = 0
    @State private var lastSeenTopID: String?
    /// 用户是否位于列表顶部（顶部哨兵行可见性）：跟随最新仅在此状态下自动滚顶，
    /// 避免「向上翻阅历史时被新日志反复拽回顶部」的体验侵害（2026-09-28 复核修复）
    @State private var isAtTop = true
    /// 跟随滚顶节流（日志洪峰时每 0.25s 最多一次，防动画排队导致抖动）
    @State private var lastFollowScrollAt = Date.distantPast
    /// 滚顶请求计数（胶囊/开关触发；由 ScrollViewReader 内部消费）
    @State private var scrollToTopRequest = 0

    // MARK: 反馈与确认

    @State private var banner: LogBanner?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var showClearAllConfirm = false
    @State private var showClearFilteredConfirm = false
    @State private var showClearTodayConfirm = false
    @State private var showSettings = false
    @State private var exportData: ExportData?

    // MARK: 存储快照（异步统计）

    @State private var storageSnapshot: LogStorageSnapshot?

    /// 筛选结果缓存（非 Observable 引用盒：命中即复用，不触发额外视图更新）
    @StateObject private var filterCache = LogFilterCache()

    // MARK: 时间鲜活与停留

    @State private var now = Date()
    @State private var openedAt = Date()
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // MARK: 派生数据

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// 筛选结果缓存（日志实时流入时避免同一渲染帧内多次 O(n) 重算，保障滚动/流式丝滑）
    private var filteredEntries: [LogEntry] {
        let key = LogFilterKey(topID: logManager.entries.first?.id,
                               count: logManager.entries.count,
                               level: selectedLevel,
                               module: selectedModule,
                               query: trimmedQuery)
        return filterCache.result(key: key) {
            logManager.filtered(level: selectedLevel, module: selectedModule, query: trimmedQuery)
        }
    }

    private var stats: LogStats { logManager.stats() }

    private var hasActiveFilter: Bool {
        selectedLevel != nil || selectedModule != nil || isSearching
    }

    /// 日期分组（保持倒序；组内条目连续，今天/昨天/日期标头）
    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let entries: [LogEntry]
    }

    private var daySections: [DaySection] {
        var sections: [DaySection] = []
        var currentKey: String?
        var currentEntries: [LogEntry] = []
        var currentDate: Date?

        func flush() {
            guard let key = currentKey, let date = currentDate, !currentEntries.isEmpty else { return }
            sections.append(DaySection(id: key, title: dayTitle(for: date), entries: currentEntries))
        }

        for entry in filteredEntries {
            if entry.dayKey != currentKey {
                flush()
                currentKey = entry.dayKey
                currentDate = entry.timestamp
                currentEntries = []
            }
            currentEntries.append(entry)
        }
        flush()
        return sections
    }

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    private func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return Self.dayTitleFormatter.string(from: date)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            statsBar
            if let banner {
                bannerView(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            filterChips
            searchBar
            logContent
        }
        .background(Color(.systemBackground))
        .navigationTitle("应用日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) { newLogsPill }
        .sheet(isPresented: $showSettings) {
            LogSettingsView()
                .sjzPresentationChrome()
        }
        .sheet(item: $detailEntry) { entry in
            LogDetailCard(entry: entry,
                          onCopy: { copyEntry(entry, source: "detail") },
                          onDelete: {
                              deleteEntry(entry, source: "detail")
                              detailEntry = nil
                          })
                .sjzPresentationChrome()
        }
        .sheet(item: $exportData) { data in
            ExportSheetView(text: data.text, fileName: data.fileName)
                .sjzPresentationChrome()
        }
        .alert("确认清空全部日志？", isPresented: $showClearAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                let cleared = logManager.entries.count
                withAnimation(.easeInOut(duration: 0.25)) {
                    logManager.clearAll()
                }
                pendingNewCount = 0
                showBanner("已清空 \(cleared) 条日志", icon: "trash.fill", tone: .info)
            }
        } message: {
            Text("将清空全部 \(logManager.entries.count) 条日志，此操作不可恢复。")
        }
        .alert("确认清空今日日志？", isPresented: $showClearTodayConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                LogManager.shared.info("log", "清空今日日志（用户确认执行）", context: [:])
                let removed = withAnimation(.easeInOut(duration: 0.25)) {
                    logManager.removeEntries(dayKey: LogEntry.dayKeyFormatter.string(from: Date()))
                }
                showBanner("已清空今日 \(removed) 条日志", icon: "trash.fill", tone: .info)
            }
        } message: {
            Text("仅清空今天产生的日志，历史日志保留。")
        }
        .confirmationDialog("确认清空当前筛选结果？", isPresented: $showClearFilteredConfirm, titleVisibility: .visible) {
            Button("清空 \(filteredEntries.count) 条", role: .destructive) {
                LogManager.shared.info("log", "清空筛选结果（用户确认执行）", context: [
                    "level": selectedLevel?.rawValue ?? "全部",
                    "module": selectedModule ?? "全部",
                    "query": trimmedQuery
                ])
                let removed = withAnimation(.easeInOut(duration: 0.25)) {
                    logManager.removeEntries(level: selectedLevel, module: selectedModule, query: trimmedQuery)
                }
                showBanner("已清空 \(removed) 条匹配日志", icon: "trash.fill", tone: .info)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除当前筛选命中的日志，其余日志不受影响。")
        }
        .modifier(LogPageLockPolicy(reason: "sensitive_logs"))
        .onAppear {
            openedAt = Date()
            lastSeenTopID = logManager.entries.first?.id
            LogManager.shared.info("log", "日志页打开", context: [
                "total": "\(stats.total)",
                "today": "\(stats.today)",
                "issueToday": "\(stats.issueToday)",
                "errors": "\(stats.count(of: .error))",
                "warnings": "\(stats.count(of: .warning))"
            ])
            refreshStorageSnapshot()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            bannerDismissTask?.cancel()
            LogManager.shared.info("log", "日志页关闭", context: [
                "stayMs": String(format: "%.0f", Date().timeIntervalSince(openedAt) * 1000),
                "total": "\(logManager.entries.count)",
                "level": selectedLevel?.rawValue ?? "全部",
                "module": selectedModule ?? "全部"
            ])
        }
        .onReceive(minuteTimer) { tick in
            now = tick
        }
        // 新日志到达：位于顶部且开启跟随时自动滚顶；否则累计「N 条新日志」
        .onChange(of: logManager.entries.first?.id) { _, newTopID in
            guard let newTopID else {
                lastSeenTopID = nil
                pendingNewCount = 0
                return
            }
            if followLatest && isAtTop {
                lastSeenTopID = newTopID
                pendingNewCount = 0
            } else if let lastSeenTopID,
                      let index = logManager.entries.firstIndex(where: { $0.id == lastSeenTopID }) {
                pendingNewCount = index
            } else {
                pendingNewCount = 0
                lastSeenTopID = newTopID
            }
        }
        // 回到顶部：视为已读最新（清空累计并重置基线）
        .onChange(of: isAtTop) { _, atTop in
            guard atTop else { return }
            pendingNewCount = 0
            lastSeenTopID = logManager.entries.first?.id
            LogManager.shared.debugLog("log", "滚动回到顶部", context: [
                "total": "\(logManager.entries.count)"
            ])
        }
        .onChange(of: logManager.maxEntries) { _, _ in
            refreshStorageSnapshot()
        }
    }

    // MARK: 统计头部

    private var statsBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .displaySymbolFont(13, weight: .medium)
                .foregroundStyle(Color.sjzTeal)
                .accessibilityHidden(true)
            Text("共 \(stats.total) 条")
                .displayFont(12)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if stats.today > 0 {
                Text("今日 \(stats.today)")
                    .displayFont(12)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if stats.issueToday > 0 {
                Text("今日异常 \(stats.issueToday)")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.sjzOrange, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("今日异常 \(stats.issueToday) 条")
            }
            Spacer()
            followToggle
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: stats.issueToday)
    }

    /// 跟随最新开关（暂停时可累计新日志提示）
    private var followToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                followLatest.toggle()
                if followLatest {
                    pendingNewCount = 0
                    scrollToTopRequest += 1   // 恢复跟随即跳回最新
                }
            }
            LogManager.shared.info("log", "跟随最新切换", context: ["follow": "\(followLatest)"])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: followLatest ? "arrow.down.to.line.compact" : "pause.fill")
                    .displaySymbolFont(10, weight: .semibold)
                Text(followLatest ? "跟随最新" : "已暂停")
                    .displayFont(11, weight: .medium)
            }
            .foregroundStyle(followLatest ? Color.sjzAccent : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background((followLatest ? Color.sjzAccent : Color.secondary).opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(followLatest ? "跟随最新已开启，点按暂停" : "跟随最新已暂停，点按恢复")
    }

    /// 悬浮「N 条新日志」胶囊（未跟随/已翻阅历史时累计；点按恢复跟随并滚顶）
    @ViewBuilder
    private var newLogsPill: some View {
        if pendingNewCount > 0 {
            Button {
                let pending = pendingNewCount
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    followLatest = true
                    pendingNewCount = 0
                    scrollToTopRequest += 1
                }
                if let top = logManager.entries.first?.id {
                    lastSeenTopID = top
                }
                LogManager.shared.info("log", "跳转最新日志", context: ["pending": "\(pending)"])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .displaySymbolFont(12, weight: .semibold)
                    Text("\(pendingNewCount) 条新日志")
                        .displayFont(12, weight: .medium)
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.sjzAccent, in: Capsule())
                .shadow(color: Color.sjzAccent.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: 操作反馈横幅

    private func bannerView(_ banner: LogBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .displaySymbolFont(13, weight: .semibold)
            Text(banner.text)
                .displayFont(12.5, weight: .medium)
            Spacer()
        }
        .foregroundStyle(banner.tone.color)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(banner.tone.color.opacity(0.1))
        .accessibilityLabel(banner.text)
    }

    private func showBanner(_ text: String, icon: String, tone: LogBanner.Tone) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            banner = LogBanner(text: text, icon: icon, tone: tone)
        }
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeOut(duration: 0.3)) { banner = nil }
        }
    }

    // MARK: 级别筛选芯片

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "全部", count: stats.total,
                           color: Color.sjzAccent, isSelected: selectedLevel == nil) {
                    selectLevel(nil)
                }
                ForEach(LogLevel.allCases, id: \.self) { level in
                    FilterChip(label: level.displayName, count: stats.count(of: level),
                               color: level.color, isSelected: selectedLevel == level) {
                        selectLevel(selectedLevel == level ? nil : level)
                    }
                }
                Divider().frame(height: 18)
                moduleMenu
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var moduleMenu: some View {
        Menu {
            Button {
                selectModule(nil)
            } label: {
                Label("全部模块", systemImage: selectedModule == nil ? "checkmark" : "square.grid.2x2")
            }
            Divider()
            ForEach(logManager.moduleFacets(), id: \.module) { facet in
                Button {
                    selectModule(selectedModule == facet.module ? nil : facet.module)
                } label: {
                    Label("\(facet.module)（\(facet.count)）",
                          systemImage: selectedModule == facet.module ? "checkmark" : "folder")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2.fill")
                    .displaySymbolFont(10, weight: .medium)
                Text(selectedModule ?? "全部模块")
                    .displayFont(12, weight: .medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .displaySymbolFont(9, weight: .semibold)
            }
            .foregroundStyle(selectedModule == nil ? Color.secondary : Color.sjzPurple)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background((selectedModule == nil ? Color.secondary : Color.sjzPurple).opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke((selectedModule == nil ? Color.secondary : Color.sjzPurple).opacity(0.2), lineWidth: 0.5))
        }
        .accessibilityLabel(selectedModule == nil ? "模块筛选，当前全部模块" : "模块筛选，当前 \(selectedModule ?? "")")
    }

    private func selectLevel(_ level: LogLevel?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedLevel = level
        }
        LogManager.shared.info("log", "级别筛选切换", context: [
            "level": level?.rawValue ?? "全部",
            "matched": "\(logManager.filtered(level: level, module: selectedModule, query: trimmedQuery).count)"
        ])
    }

    private func selectModule(_ module: String?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedModule = module
        }
        LogManager.shared.info("log", "模块筛选切换", context: [
            "module": module ?? "全部",
            "matched": "\(logManager.filtered(level: selectedLevel, module: module, query: trimmedQuery).count)"
        ])
    }

    // MARK: 搜索框（Liquid Glass + 聚焦描边 + 防抖）

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(searchFocused ? Color.sjzAccent : .secondary)
            TextField("搜索关键词、URL、文章ID、错误码（空格分隔多条件）", text: $searchText)
                .displayFont(14)
                .focused($searchFocused)
                .submitLabel(.search)
                .onChange(of: searchText) { _, newValue in
                    searchDebounceTask?.cancel()
                    let keyword = newValue
                    searchDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                        LogManager.shared.info("log", "日志搜索执行", context: [
                            "keyword": trimmed,
                            "hits": "\(logManager.filtered(level: selectedLevel, module: selectedModule, query: trimmed).count)"
                        ])
                    }
                }
            if isSearching {
                Text("\(filteredEntries.count) 条匹配")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
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
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(
                searchFocused ? Color.sjzAccent : Color.sjzAccent.opacity(0.15),
                lineWidth: searchFocused ? 1.4 : 0.6)
        )
        .padding(.horizontal, 16).padding(.bottom, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)
        .onChange(of: searchFocused) { _, focused in
            LogManager.shared.debugLog("log", "搜索框焦点变化", context: [
                "focused": "\(focused)", "keywordLength": "\(searchText.count)"
            ])
        }
    }

    // MARK: 日志内容（日期分组 + 跟随滚顶）

    @ViewBuilder
    private var logContent: some View {
        if logManager.entries.isEmpty {
            emptyState
        } else if filteredEntries.isEmpty {
            filteredEmptyState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(daySections) { section in
                        Section {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                logRow(entry, index: index)
                            }
                        } header: {
                            daySectionHeader(section)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // 顶部判定（滚动几何，替代哨兵行）：contentOffset ≤ 60pt 视为「位于顶部」——
                // 阈值含容差（sheet 呈现/布局早期会有小幅偏移抖动，12pt 曾误判导致开页即出现「N 条新日志」胶囊）；
                // 跟随最新仅在此状态自动滚顶，翻阅历史（> 60pt）时新日志只累计悬浮胶囊
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= 60
                } action: { _, atTop in
                    if isAtTop != atTop { isAtTop = atTop }
                }
                .onChange(of: logManager.entries.first?.id) { _, newTopID in
                    // 仅在「开启跟随 + 位于顶部」时自动滚顶；并做 0.25s 节流防动画排队抖动
                    guard followLatest, isAtTop, let newTopID else { return }
                    let now = Date()
                    guard now.timeIntervalSince(lastFollowScrollAt) > 0.25 else { return }
                    lastFollowScrollAt = now
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        proxy.scrollTo(newTopID, anchor: .top)
                    }
                }
                .onChange(of: scrollToTopRequest) { _, _ in scrollToTop(proxy) }
                .onChange(of: selectedLevel) { _, _ in scrollToTop(proxy) }
                .onChange(of: selectedModule) { _, _ in scrollToTop(proxy) }
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        if let first = filteredEntries.first {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                proxy.scrollTo(first.id, anchor: .top)
            }
        }
    }

    private func daySectionHeader(_ section: DaySection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .displayFont(12, weight: .semibold)
                .foregroundStyle(.secondary)
            Text("\(section.entries.count)")
                .displayFont(10, weight: .medium)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.secondary.opacity(0.12), in: Capsule())
            Spacer()
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowBackground(Color.clear)
        .textCase(nil)
    }

    private func logRow(_ entry: LogEntry, index: Int) -> some View {
        LogRowView(entry: entry,
                   isExpanded: expandedIds.contains(entry.id),
                   isCopied: copiedId == entry.id,
                   keyword: trimmedQuery,
                   now: now,
                   onToggle: { toggleExpand(entry.id) },
                   onCopy: { copyEntry(entry, source: "row") },
                   onOpenDetail: {
                       detailEntry = entry
                       LogManager.shared.info("log", "打开日志详情", context: [
                           "level": entry.level.rawValue, "module": entry.module
                       ])
                   })
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .id(entry.id)
        .modifier(SJZRevealOnce(key: "log.row.\(entry.id)", delay: Double(min(index, 12)) * 0.03, logReveal: false))
        // 注意：swipeActions 必须位于入场动效修饰器外层——被 offset/opacity 包裹会导致滑动手势整体失效
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                copyEntry(entry, source: "swipe")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .tint(Color.sjzAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteEntry(entry, source: "swipe")
            } label: {
                Label("删除", systemImage: "trash.fill")
            }
        }
        .contextMenu {
            Button {
                copyEntry(entry, source: "menu")
            } label: {
                Label("复制本条日志", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.jsonText()
                LogManager.shared.info("log", "复制日志 JSON", context: ["module": entry.module])
                showBanner("已复制 JSON", icon: "curlybraces", tone: .success)
            } label: {
                Label("复制 JSON", systemImage: "curlybraces")
            }
            ShareLink(item: entry.detailText) {
                Label("分享本条日志", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                deleteEntry(entry, source: "menu")
            } label: {
                Label("删除本条日志", systemImage: "trash")
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 12)),
            removal: .opacity.combined(with: .offset(x: -70))))
    }

    // MARK: 空状态（三态）

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.sjzTeal.opacity(0.1))
                    .frame(width: 96, height: 96)
                Image(systemName: "doc.text.magnifyingglass")
                    .displaySymbolFont(38)
                    .foregroundStyle(Color.sjzTeal.opacity(0.45))
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            VStack(spacing: 8) {
                Text("暂无日志")
                    .displayFont(19, weight: .semibold)
                Text("App 运行过程中的操作与异常会记录在这里\n开启 DEBUG 开关可采集更详细的调试日志")
                    .displayFont(13)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Button {
                showSettings = true
            } label: {
                Label("打开日志设置", systemImage: "gearshape")
                    .displayLabelFont(13, weight: .medium)
                    .foregroundStyle(Color.sjzAccent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.sjzAccent.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isSearching ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
                .displaySymbolFont(34)
                .foregroundStyle(Color.sjzAccent.opacity(0.35))
            Text(isSearching ? "未找到匹配的日志" : filteredEmptyTitle)
                .displayFont(17, weight: .semibold)
            Text(isSearching ? "试试空格分隔多个关键词（如 error netmon）" : "可重置筛选查看全部日志")
                .displayFont(13)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                resetFilters()
            } label: {
                Label("重置筛选", systemImage: "arrow.counterclockwise")
                    .displayLabelFont(13, weight: .medium)
                    .foregroundStyle(Color.sjzAccent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.sjzAccent.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredEmptyTitle: String {
        if selectedModule != nil, selectedLevel != nil { return "该级别下没有此模块日志" }
        if selectedModule != nil { return "该模块暂无日志" }
        return "该级别暂无日志"
    }

    private func resetFilters() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedLevel = nil
            selectedModule = nil
            searchText = ""
        }
        LogManager.shared.info("log", "重置日志筛选", context: [:])
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("完成") { dismiss() }
                .displayFont(15, weight: .medium)
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                if hasActiveFilter {
                    Button {
                        resetFilters()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .displaySymbolFont(13, weight: .medium)
                            .foregroundStyle(Color.sjzAccent)
                    }
                    .accessibilityLabel("重置筛选")
                }
                Button {
                    showSettings = true
                    LogManager.shared.debugLog("log", "打开日志设置（列表入口）", context: [:])
                } label: {
                    Image(systemName: "gearshape")
                        .displaySymbolFont(14, weight: .medium)
                }
                .accessibilityLabel("日志设置")
                exportMenu
                ellipsisMenu
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Button {
                performExport(scope: .filtered, format: .text)
            } label: {
                Label("导出当前筛选（TXT）", systemImage: "doc.plaintext")
            }
            Button {
                performExport(scope: .filtered, format: .json)
            } label: {
                Label("导出当前筛选（JSON）", systemImage: "curlybraces")
            }
            Divider()
            Button {
                performExport(scope: .all, format: .text)
            } label: {
                Label("导出全部（TXT）", systemImage: "doc.plaintext")
            }
            Button {
                performExport(scope: .all, format: .json)
            } label: {
                Label("导出全部（JSON）", systemImage: "curlybraces")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .displaySymbolFont(14, weight: .medium)
        }
        .accessibilityLabel("导出日志")
    }

    private var ellipsisMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = exportTextForCurrentFilter()
                LogManager.shared.info("log", "复制当前筛选日志", context: [
                    "count": "\(filteredEntries.count)"
                ])
                showBanner("已复制 \(filteredEntries.count) 条日志", icon: "doc.on.doc.fill", tone: .success)
            } label: {
                Label("复制当前筛选", systemImage: "doc.on.doc")
            }
            .disabled(filteredEntries.isEmpty)
            Divider()
            Button(role: .destructive) {
                showClearFilteredConfirm = true
            } label: {
                Label("清空当前筛选结果…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .disabled(!hasActiveFilter || filteredEntries.isEmpty)
            Button(role: .destructive) {
                showClearTodayConfirm = true
            } label: {
                Label("清空今日日志…", systemImage: "calendar.badge.minus")
            }
            .disabled(stats.today == 0)
            Button(role: .destructive) {
                showClearAllConfirm = true
            } label: {
                Label("清空全部日志…", systemImage: "trash")
            }
            .disabled(logManager.entries.isEmpty)
            Divider()
            Button {} label: {
                Label(storageSnapshot.map { "磁盘占用 \($0.sizeText) · \($0.files) 个文件" } ?? "磁盘占用统计中…",
                      systemImage: "internaldrive")
            }
            .disabled(true)
        } label: {
            Image(systemName: "ellipsis.circle")
                .displaySymbolFont(16, weight: .medium)
        }
        .accessibilityLabel("更多操作")
    }

    // MARK: 行交互

    private func toggleExpand(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedIds.contains(id) {
                expandedIds.remove(id)
            } else {
                expandedIds.insert(id)
            }
        }
    }

    private func copyEntry(_ entry: LogEntry, source: String) {
        UIPasteboard.general.string = entry.formattedLine
        copiedId = entry.id
        LogManager.shared.info("log", "复制单条日志（\(source)）", context: [
            "level": entry.level.rawValue, "module": entry.module
        ])
        showBanner("已复制", icon: "doc.on.doc.fill", tone: .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedId == entry.id { copiedId = nil }
        }
    }

    private func deleteEntry(_ entry: LogEntry, source: String) {
        let impact = UIImpactFeedbackGenerator(style: .rigid)
        impact.impactOccurred()
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = logManager.removeEntry(id: entry.id)
        }
        expandedIds.remove(entry.id)
        LogManager.shared.info("log", "删除单条日志（\(source)）", context: [
            "level": entry.level.rawValue, "module": entry.module
        ])
        showBanner("已删除 1 条日志", icon: "trash.fill", tone: .info)
    }

    // MARK: 导出

    private enum ExportScope { case filtered, all }

    private func exportTextForCurrentFilter() -> String {
        let title = exportScopeTitle(filtered: true)
        return logManager.export(entries: filteredEntries, title: title, format: .text)
    }

    private func exportScopeTitle(filtered: Bool) -> String {
        guard filtered else { return "全部日志" }
        var parts: [String] = []
        if let level = selectedLevel { parts.append("级别=\(level.displayName)") }
        if let module = selectedModule { parts.append("模块=\(module)") }
        if isSearching { parts.append("关键词=\(trimmedQuery)") }
        return parts.isEmpty ? "全部日志" : parts.joined(separator: " · ")
    }

    private func exportTag(filtered: Bool) -> String {
        guard filtered else { return "all" }
        var parts: [String] = []
        if let level = selectedLevel { parts.append(level.rawValue) }
        if let module = selectedModule { parts.append(module) }
        if isSearching { parts.append("search") }
        return parts.isEmpty ? "all" : parts.joined(separator: "-")
    }

    private func performExport(scope: ExportScope, format: LogExportFormat) {
        let entries = scope == .filtered ? filteredEntries : logManager.entries
        guard !entries.isEmpty else {
            showBanner("没有可导出的日志", icon: "exclamationmark.circle.fill", tone: .warning)
            return
        }
        let title = exportScopeTitle(filtered: scope == .filtered)
        let text = logManager.export(entries: entries, title: title, format: format)
        let fileName = logManager.exportFileName(tag: exportTag(filtered: scope == .filtered), format: format)
        exportData = ExportData(text: text, fileName: fileName)
        LogManager.shared.info("log", "导出日志", context: [
            "scope": scope == .filtered ? "currentFilter" : "all",
            "format": format.rawValue,
            "count": "\(entries.count)",
            "fileName": fileName
        ])
        showBanner("已准备导出 \(entries.count) 条", icon: "square.and.arrow.up", tone: .success)
    }

    private func refreshStorageSnapshot() {
        Task {
            let snapshot = await logManager.storageSnapshot()
            storageSnapshot = snapshot
            LogManager.shared.debugLog("log", "存储快照刷新", context: [
                "files": "\(snapshot.files)", "bytes": "\(snapshot.totalBytes)", "size": snapshot.sizeText
            ])
        }
    }
}

// MARK: - 日志页生物锁策略

/// 生产路径挂 `.biometricLockProtected`（敏感页上锁）；
/// DEBUG 自测截图模式（启动参数 `-uiTestOpenLogs`）跳过上锁——避免系统 Face ID 弹窗遮挡取证画面。
/// 仅影响 DEBUG 构建下的显式启动参数，Release 与正常 DEBUG 路径行为不变。
private struct LogPageLockPolicy: ViewModifier {
    let reason: String

    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestOpenLogs") {
            content
        } else {
            content.biometricLockProtected(reason: reason)
        }
        #else
        content.biometricLockProtected(reason: reason)
        #endif
    }
}

// MARK: - 筛选结果缓存（引用盒：同帧多次取值只算一次）

private struct LogFilterKey: Equatable {
    let topID: String?
    let count: Int
    let level: LogLevel?
    let module: String?
    let query: String
}

private final class LogFilterCache: ObservableObject {
    private var key: LogFilterKey?
    private var entries: [LogEntry] = []

    func result(key newKey: LogFilterKey, compute: () -> [LogEntry]) -> [LogEntry] {
        if let key, key == newKey { return entries }
        let computed = compute()
        key = newKey
        entries = computed
        return computed
    }
}

// MARK: - 操作反馈横幅模型

private struct LogBanner: Equatable {
    enum Tone {
        case success, warning, info
        var color: Color {
            switch self {
            case .success: return Color.sjzGreen
            case .warning: return Color.sjzOrange
            case .info: return Color.sjzAccent
            }
        }
    }
    let text: String
    let icon: String
    let tone: Tone
}

// MARK: - 筛选标签

private struct FilterChip: View {
    let label: String
    let count: Int
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .displayFont(12, weight: isSelected ? .bold : .medium)
                Text("\(count)")
                    .displayFont(10, weight: .medium)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isSelected ? .white.opacity(0.3) : .secondary.opacity(0.15), in: Capsule())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isSelected ? color : color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(isSelected ? color : color.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(label) \(count) 条")
    }
}

// MARK: - 日志行

private struct LogRowView: View {
    let entry: LogEntry
    let isExpanded: Bool
    let isCopied: Bool
    let keyword: String
    let now: Date
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onOpenDetail: () -> Void

    private var showsToggle: Bool {
        entry.message.count > 120 || entry.contextFieldCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 顶部：级别标签 + 模块 + 相对时间
            HStack(spacing: 6) {
                Text(entry.level.rawValue)
                    .displayFont(9, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(entry.level.color, in: Capsule())

                Text(entry.module)
                    .displayFont(10, weight: .medium)
                    .foregroundStyle(entry.level.color.opacity(0.75))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(entry.displayTime)
                    .displayFont(10, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // 消息正文（关键词高亮）
            Text(logHighlighted(entry.message, keyword: keyword))
                .displayFont(13)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 3)
                .multilineTextAlignment(.leading)

            // 上下文：折叠态显示字段数胶囊；展开态显示键值明细
            if entry.contextFieldCount > 0 {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.context?.sorted(by: { $0.key < $1.key }) ?? [], id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 4) {
                                Text(key)
                                    .displayFont(9, weight: .medium)
                                    .foregroundStyle(.secondary)
                                Text(logHighlighted(value, keyword: keyword))
                                    .displayFont(9, design: .monospaced)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                    .padding(8)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .displaySymbolFont(9)
                        Text("上下文 \(entry.contextFieldCount) 个字段")
                            .displayFont(9)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.secondary.opacity(0.08), in: Capsule())
                }
            }

            // 底部操作
            HStack(spacing: 14) {
                if showsToggle {
                    Button {
                        onToggle()
                    } label: {
                        Label(isExpanded ? "收起" : "展开", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .displayLabelFont(10)
                            .foregroundStyle(entry.level.color)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    onOpenDetail()
                } label: {
                    Label("详情", systemImage: "doc.text.magnifyingglass")
                        .displayLabelFont(10)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    onCopy()
                } label: {
                    Label(isCopied ? "已复制" : "复制", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .displayLabelFont(10)
                        .foregroundStyle(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                if entry.level.isIssue {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(entry.level.color.opacity(0.05))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(entry.level.color.opacity(entry.level == .debug ? 0.08 : 0.16), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpenDetail() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.displayName)，模块 \(entry.module)，\(entry.message)，\(entry.relativeTime(now: now))")
    }
}

// MARK: - 日志详情卡

private struct LogDetailCard: View {
    let entry: LogEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(entry.level.color)
                                .frame(width: 44, height: 44)
                            Image(systemName: entry.level.icon)
                                .displaySymbolFont(18, weight: .medium)
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.level.rawValue) · \(entry.level.displayName)")
                                .displayFont(13, weight: .semibold)
                                .foregroundStyle(entry.level.color)
                            Text(entry.fullDateTime)
                                .displayFont(11)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Text(entry.relativeTime())
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                    }

                    Text(entry.module)
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(Color.sjzAccent)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.sjzAccent.opacity(0.1), in: Capsule())

                    Text(entry.message)
                        .displayFont(16, weight: .medium)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let ctx = entry.context, !ctx.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("上下文（\(ctx.count) 个字段）")
                                .displayFont(12, weight: .semibold)
                                .foregroundStyle(.secondary)
                            ForEach(ctx.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key)
                                        .displayFont(10, weight: .medium)
                                        .foregroundStyle(Color.sjzPurple)
                                    Text(value)
                                        .displayFont(11, design: .monospaced)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            onCopy()
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .displayLabelFont(13, weight: .medium)
                                .foregroundStyle(Color.sjzAccent)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.sjzAccent.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            UIPasteboard.general.string = entry.jsonText()
                            LogManager.shared.info("log", "复制日志 JSON（详情卡）", context: ["module": entry.module])
                        } label: {
                            Label("JSON", systemImage: "curlybraces")
                                .displayLabelFont(13, weight: .medium)
                                .foregroundStyle(Color.sjzPurple)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.sjzPurple.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        ShareLink(item: entry.detailText) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .displayLabelFont(13, weight: .medium)
                                .foregroundStyle(Color.sjzTeal)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.sjzTeal.opacity(0.1), in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .background(Color(.systemBackground))
            .navigationTitle("日志详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 关键词高亮（AttributedString 口径，与消息中心/收藏页一致）

private func logHighlighted(_ text: String, keyword: String) -> AttributedString {
    var attr = AttributedString(text)
    let keywords = keyword.lowercased()
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }
    guard !keywords.isEmpty else { return attr }
    let lower = text.lowercased()
    for kw in keywords {
        var searchStart = lower.startIndex
        while let range = lower.range(of: kw, range: searchStart..<lower.endIndex) {
            if let attrRange = Range(NSRange(range, in: text), in: attr) {
                attr[attrRange].foregroundColor = Color.sjzOrange
                attr[attrRange].backgroundColor = Color.sjzOrange.opacity(0.12)
            }
            searchStart = range.upperBound
        }
    }
    return attr
}

// MARK: - 导出 Sheet

private struct ExportSheetView: UIViewControllerRepresentable {
    let text: String
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}