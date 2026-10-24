//
//  BookmarkListView.swift
//  山西晋中理工学院 APP — 我的收藏页面
//
//  收藏检索（关键词高亮）· 范围筛选（全部/未读/可离线/分类）· 四种排序 ·
//  收藏时间日分组 · 滑动操作（已读未读/取消收藏）· 长按菜单 · 批量管理 ·
//  下拉检查更新（官网原文变更徽标）· 离线正文/图片固化 · 存储诊断面板 ·
//  统一图片管线（缓存直出/滚动让路/离线兜底）· 全链路日志域 favorite。
//

import SwiftUI
import Combine

// MARK: - 我的收藏页面

struct BookmarkListView: View {
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @ObservedObject private var readManager = ReadStatusManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: 检索 · 筛选 · 排序

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var filterScope: BookmarkFilterScope = .all
    @State private var sortOrder: BookmarkSortOrder = .recentlyBookmarked

    // MARK: 批量管理

    @State private var isBatchMode = false
    @State private var selectedKeys: Set<String> = []

    // MARK: 跳转

    @State private var openedBookmark: BookmarkItem?

    // MARK: 反馈与确认

    @State private var banner: BookmarkBanner?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var showClearConfirm = false
    @State private var showDeleteSelectedConfirm = false
    @State private var checkingUpdates = false

    // MARK: 诊断面板

    @State private var showDiagnosePanel = false
    @State private var diagnosePressCount = 0
    @State private var storageSnapshot: BookmarkStorageSnapshot?

    // MARK: 时间鲜活（「x 分钟前收藏」）与停留时长

    @State private var now = Date()
    @State private var openedAt = Date()
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // MARK: 派生数据

    private var unreadCount: Int {
        bookmarkManager.unreadCount(readKeys: readManager.snapshot)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 可见条目（筛选 + 排序，纯函数在管理器内，便于单元测试）
    private var visibleItems: [BookmarkItem] {
        BookmarkManager.filter(bookmarkManager.bookmarks,
                               query: searchText,
                               scope: filterScope,
                               sort: sortOrder,
                               readKeys: readManager.snapshot)
    }

    /// 仅「最近收藏」排序且未搜索时按收藏时间分组（苹果 News 收藏列表口径）
    private var shouldGroupByTime: Bool {
        sortOrder == .recentlyBookmarked && !isSearching
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if let banner {
                bannerView(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !bookmarkManager.bookmarks.isEmpty {
                searchField
                filterChips
            }
            contentList
        }
        .background(Color(.systemBackground))
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isBatchMode {
                batchBar
            }
        }
        .navigationDestination(item: $openedBookmark) { bookmark in
            EnhancedNewsDetailView(news: bookmark.toNewsItem())
        }
        .alert("收藏上限", isPresented: $bookmarkManager.showLimitAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(bookmarkManager.limitAlertMessage)
        }
        .confirmationDialog("确认清空全部收藏？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空 \(bookmarkManager.count) 篇收藏", role: .destructive) {
                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()
                let removed = withAnimation(.easeInOut(duration: 0.3)) {
                    bookmarkManager.clearAll()
                }
                exitBatchMode()
                showBanner("已清空 \(removed) 篇收藏", icon: "trash.fill", tone: .info)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除全部 \(bookmarkManager.count) 篇收藏文章，此操作不可恢复。")
        }
        .confirmationDialog("确认取消收藏？", isPresented: $showDeleteSelectedConfirm, titleVisibility: .visible) {
            Button("取消收藏 \(selectedKeys.count) 篇", role: .destructive) {
                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()
                let keys = selectedKeys
                let removed = withAnimation(.easeInOut(duration: 0.3)) {
                    bookmarkManager.removeBookmarks(keys)
                }
                selectedKeys.removeAll()
                exitBatchMode()
                showBanner("已取消收藏 \(removed) 篇", icon: "bookmark.slash.fill", tone: .info)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将取消收藏选中的 \(selectedKeys.count) 篇文章。")
        }
        .sheet(isPresented: $showDiagnosePanel) {
            diagnosePanel.sjzPresentationChrome()
        }
        .onAppear {
            openedAt = Date()
            LogManager.shared.info("favorite", "收藏页打开", context: [
                "count": "\(bookmarkManager.count)",
                "unread": "\(unreadCount)",
                "cached": "\(bookmarkManager.contentCachedCount)",
                "sort": sortOrder.rawValue
            ])
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            bannerDismissTask?.cancel()
            LogManager.shared.info("favorite", "收藏页关闭", context: [
                "stayMs": String(format: "%.0f", Date().timeIntervalSince(openedAt) * 1000),
                "count": "\(bookmarkManager.count)"
            ])
        }
        .onReceive(minuteTimer) { tick in
            now = tick
        }
        .onChange(of: bookmarkManager.count) { _, newValue in
            // 收藏被清空时自动退出批量模式；清理已删除条目的选中态
            if newValue == 0, isBatchMode {
                exitBatchMode()
            }
            selectedKeys = selectedKeys.filter { bookmarkManager.isBookmarked($0) }
        }
    }

    // MARK: 顶部状态栏

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(Color.sjzGold)
                .accessibilityHidden(true)
                // 长按 5 次触发诊断面板（与消息中心同一发现机制）
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        diagnosePressCount += 1
                        LogManager.shared.debugLog("favorite", "诊断入口长按计数", context: [
                            "count": "\(diagnosePressCount)"
                        ])
                        if diagnosePressCount >= 5 {
                            diagnosePressCount = 0
                            showDiagnosePanel = true
                            LogManager.shared.info("favorite", "收藏诊断面板已触发", context: [:])
                        }
                    })
            Text("共 \(bookmarkManager.count) 篇收藏")
                .displayFont(13)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if unreadCount > 0 {
                Text("未读 \(unreadCount)")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.sjzAccent, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("未读 \(unreadCount) 篇")
            }
            if bookmarkManager.contentCachedCount > 0 {
                Label("可离线 \(bookmarkManager.contentCachedCount)", systemImage: "checkmark.icloud.fill")
                    .displayLabelFont(11, weight: .medium)
                    .foregroundStyle(Color.sjzGreen)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.sjzGreen.opacity(0.1), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            if let progress = bookmarkManager.precacheProgress {
                precacheChip(progress)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: unreadCount)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: bookmarkManager.contentCachedCount)
    }

    /// 批量缓存进度胶囊（点击可取消）
    private func precacheChip(_ progress: BookmarkManager.PrecacheProgress) -> some View {
        Button {
            bookmarkManager.cancelPrecache()
        } label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("缓存中 \(progress.done)/\(progress.total)")
                    .displayFont(11, weight: .medium)
                    .contentTransition(.numericText())
                Image(systemName: "xmark.circle.fill")
                    .displaySymbolFont(11)
            }
            .foregroundStyle(Color.sjzAccent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.sjzAccent.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("正在批量缓存正文 \(progress.done) / \(progress.total)，点按取消")
    }

    // MARK: 操作反馈横幅

    private func bannerView(_ banner: BookmarkBanner) -> some View {
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

    private func showBanner(_ text: String, icon: String, tone: BookmarkBanner.Tone) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            banner = BookmarkBanner(text: text, icon: icon, tone: tone)
        }
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) { banner = nil }
        }
    }

    // MARK: 搜索框（Liquid Glass + 聚焦描边）

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(searchFocused ? Color.sjzAccent : .secondary)
            TextField("搜索标题、摘要或分类", text: $searchText)
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
                        LogManager.shared.info("favorite", "收藏搜索执行", context: [
                            "keyword": trimmed,
                            "hitCount": "\(BookmarkManager.filter(bookmarkManager.bookmarks, query: trimmed, scope: filterScope, sort: sortOrder, readKeys: readManager.snapshot).count)"
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
        .padding(.horizontal, 16).padding(.top, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)
        .onChange(of: searchFocused) { _, focused in
            LogManager.shared.debugLog("favorite", "搜索框焦点变化", context: [
                "focused": "\(focused)", "keywordLength": "\(searchText.count)"
            ])
        }
    }

    // MARK: 筛选芯片（全部 / 未读 / 可离线 / 分类动态）

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(.all, label: "全部", icon: "tray.full.fill",
                           color: Color.sjzAccent, count: bookmarkManager.count)
                filterChip(.unread, label: "未读", icon: "circle.fill",
                           color: .red, count: unreadCount)
                filterChip(.offlineReady, label: "可离线", icon: "arrow.down.circle.fill",
                           color: Color.sjzGreen, count: bookmarkManager.contentCachedCount)
                ForEach(bookmarkManager.categoryFacets, id: \.name) { facet in
                    filterChip(.category(facet.name), label: facet.name, icon: "folder.fill",
                               color: categoryColor(facet.name), count: facet.count)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func filterChip(_ scope: BookmarkFilterScope, label: String, icon: String,
                            color: Color, count: Int) -> some View {
        let isSelected = filterScope == scope
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                filterScope = scope
            }
            LogManager.shared.info("favorite", "收藏筛选切换", context: [
                "scope": scope.id, "label": label, "matched": "\(visibleItems.count)"
            ])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .displaySymbolFont(11, weight: .medium)
                Text(label)
                    .displayFont(12, weight: .medium)
                Text("\(count)")
                    .displayFont(10, weight: .semibold)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(isSelected ? .white.opacity(0.2) : color.opacity(0.1)))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(isSelected ? color : color.opacity(0.08)))
            .overlay(Capsule().stroke(isSelected ? color : color.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 内容列表

    @ViewBuilder
    private var contentList: some View {
        let items = visibleItems
        if bookmarkManager.bookmarks.isEmpty {
            emptyState
        } else if items.isEmpty {
            filteredEmptyState
        } else {
            ScrollView {
                if shouldGroupByTime {
                    LazyVStack(spacing: 14) {
                        ForEach(BookmarkManager.groupSections(items, now: now), id: \.group) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.group.rawValue)
                                    .displayFont(12, weight: .semibold)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 4)
                                LazyVStack(spacing: 10) {
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                        bookmarkRow(item, index: index)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            bookmarkRow(item, index: index)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                bottomInfo
            }
            .refreshable { await performUpdateCheck() }
        }
    }

    // MARK: 收藏行

    private func bookmarkRow(_ item: BookmarkItem, index: Int) -> some View {
        let unread = !readManager.isRead(item.readKey)
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            if isBatchMode {
                toggleSelection(item.readKey)
            } else {
                openItem(item)
            }
        } label: {
            bookmarkRowCard(item, unread: unread, keyword: keyword)
        }
        .buttonStyle(BookmarkRowPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(rowAccessibilityLabel(item, unread: unread))
        .accessibilityAddTraits(selectedKeys.contains(item.readKey) ? .isSelected : [])
        .modifier(SJZRevealOnce(key: "fav.row.\(item.readKey)", delay: Double(min(index, 12)) * 0.04))
        // 注意：swipeActions 必须位于入场动效修饰器外层——被 offset/opacity 包裹会导致滑动手势整体失效
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isBatchMode {
                Button {
                    toggleRead(item, markRead: true)
                } label: {
                    Label("已读", systemImage: "circle.fill")
                }
                .tint(Color.sjzAccent)
                Button {
                    toggleRead(item, markRead: false)
                } label: {
                    Label("未读", systemImage: "circle")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isBatchMode {
                Button(role: .destructive) {
                    removeItem(item, source: "swipe")
                } label: {
                    Label("取消收藏", systemImage: "trash.fill")
                }
            }
        }
        .contextMenu {
            if !isBatchMode {
                Button {
                    toggleRead(item, markRead: !readManager.isRead(item.readKey))
                } label: {
                    Label(readManager.isRead(item.readKey) ? "标记为未读" : "标记为已读",
                          systemImage: readManager.isRead(item.readKey) ? "circle" : "circle.fill")
                }
                if !item.contentCached, item.articleId != nil {
                    Button {
                        cacheSingle(item)
                    } label: {
                        Label("缓存正文（离线阅读）", systemImage: "arrow.down.doc")
                    }
                }
                Button {
                    copyLink(item)
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                ShareLink(item: item.originalArticleURL) {
                    Label("分享原文链接", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    removeItem(item, source: "menu")
                } label: {
                    Label("取消收藏", systemImage: "trash")
                }
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)),
            removal: .opacity.combined(with: .offset(x: -70))))
    }

    /// 行卡片主体（缩略图 + 信息区 + 状态胶囊）
    private func bookmarkRowCard(_ item: BookmarkItem, unread: Bool, keyword: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BookmarkThumbnailView(imageUrl: item.imageUrl, category: item.category)
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    ReadingTimeBadgeView(cachedID: item.readKey, summary: item.summary)
                        .padding(4)
                }
                .overlay(alignment: .topLeading) {
                    if unread {
                        unreadDot
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    CategoryBadge(category: item.category)
                    Spacer(minLength: 4)
                    Text(relativeBookmarkTime(item.bookmarkDate, now: now))
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Text(bookmarkHighlighted(item.title, keyword: keyword))
                    .displayFont(14.5, weight: unread ? .semibold : .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(bookmarkHighlighted(item.summary, keyword: keyword))
                    .displayFont(12)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                statusChips(item)
            }
        }
        .padding(10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                if unread {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.sjzAccent.opacity(0.05))
                }
                if isBatchMode, selectedKeys.contains(item.readKey) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.sjzAccent.opacity(0.08))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(rowStrokeColor(item), lineWidth: isBatchMode && selectedKeys.contains(item.readKey) ? 1.6 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if isBatchMode {
                selectionBadge(item)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedKeys.contains(item.readKey))
    }

    /// 行描边色：批量选中强调 → 未读微光 → 常规
    private func rowStrokeColor(_ item: BookmarkItem) -> Color {
        if isBatchMode, selectedKeys.contains(item.readKey) {
            return Color.sjzAccent
        }
        return Color.primary.opacity(readManager.isRead(item.readKey) ? 0.04 : 0.08)
    }

    /// 状态胶囊行：发布日期 · 更新/缓存状态
    private func statusChips(_ item: BookmarkItem) -> some View {
        HStack(spacing: 5) {
            Text(item.date)
                .displayFont(10)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if item.hasPendingUpdate {
                miniChip(icon: "arrow.triangle.2.circlepath", text: "内容有更新", color: Color.sjzOrange)
            } else if item.contentCached {
                miniChip(icon: "checkmark.icloud.fill", text: "可离线", color: Color.sjzGreen)
            } else if bookmarkManager.autoCacheContent, item.articleId != nil {
                miniChip(icon: "icloud.slash", text: "未缓存", color: .secondary)
            }
        }
    }

    private func miniChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .displaySymbolFont(8, weight: .semibold)
            Text(text)
                .displayFont(9, weight: .medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
        .accessibilityLabel(text)
    }

    private var unreadDot: some View {
        Circle()
            .fill(Color.sjzAccent)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: Color.sjzAccent.opacity(0.5), radius: 4)
            .padding(6)
            .accessibilityHidden(true)
    }

    /// 批量选择圆标（纯状态指示，不拦截行点击）
    private func selectionBadge(_ item: BookmarkItem) -> some View {
        ZStack {
            Circle()
                .fill(selectedKeys.contains(item.readKey) ? Color.sjzAccent : Color.white.opacity(0.92))
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            if selectedKeys.contains(item.readKey) {
                Image(systemName: "checkmark")
                    .displaySymbolFont(12, weight: .bold)
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.sjzLight)
                    .frame(width: 100, height: 100)
                Image(systemName: "bookmark.slash")
                    .displaySymbolFont(40)
                    .foregroundStyle(Color.sjzAccent.opacity(0.4))
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            VStack(spacing: 8) {
                Text("暂无收藏")
                    .displayFont(20, weight: .semibold)
                    .foregroundStyle(.primary)
                Text("在文章列表或详情页点击收藏按钮\n即可将文章添加到收藏，支持离线阅读")
                    .displayFont(14)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
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
            Text(isSearching ? "没有找到相关收藏" : filteredEmptyTitle)
                .displayFont(18, weight: .semibold)
                .foregroundStyle(.primary)
            Text(isSearching ? "换个关键词试试" : "可切换上方筛选查看全部收藏")
                .displayFont(13)
                .foregroundStyle(.secondary)
            Button {
                resetFilters()
            } label: {
                Label("查看全部收藏", systemImage: "arrow.counterclockwise")
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
        switch filterScope {
        case .unread: return "没有未读收藏"
        case .offlineReady: return "还没有可离线阅读的收藏"
        case .category: return "该分类暂无收藏"
        case .all: return "没有符合条件的收藏"
        }
    }

    // MARK: 批量操作栏（底部悬浮）

    private var batchBar: some View {
        HStack(spacing: 12) {
            Button {
                toggleSelectAll()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: allVisibleSelected ? "checkmark.circle.fill" : "circle")
                        .displaySymbolFont(16)
                    Text(allVisibleSelected ? "取消全选" : "全选")
                        .displayFont(14, weight: .medium)
                }
                .foregroundStyle(Color.sjzAccent)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("已选 \(selectedKeys.count) 篇")
                .displayFont(13)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Spacer()

            Button {
                if !selectedKeys.isEmpty {
                    showDeleteSelectedConfirm = true
                }
            } label: {
                Label("取消收藏", systemImage: "trash.fill")
                    .displayLabelFont(14, weight: .semibold)
                    .foregroundStyle(selectedKeys.isEmpty ? Color.secondary : .white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(selectedKeys.isEmpty ? Color.gray.opacity(0.18) : Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedKeys.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var visibleKeys: [String] { visibleItems.map(\.readKey) }

    private var allVisibleSelected: Bool {
        !visibleKeys.isEmpty && Set(visibleKeys).isSubset(of: selectedKeys)
    }

    // MARK: 底部统计

    private var bottomInfo: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .displaySymbolFont(10)
                    .foregroundStyle(Color.sjzGold)
                Text("共 \(bookmarkManager.count) 篇收藏")
                    .displayFont(12)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if bookmarkManager.contentCachedCount > 0 {
                    statLabel(icon: "checkmark.icloud.fill", text: "可离线 \(bookmarkManager.contentCachedCount) 篇", color: Color.sjzGreen)
                }
                if unreadCount > 0 {
                    statLabel(icon: "circle.fill", text: "未读 \(unreadCount) 篇", color: Color.sjzAccent)
                }
            }
        }
        .padding(.vertical, 22)
        .animation(.easeInOut(duration: 0.25), value: bookmarkManager.contentCachedCount)
    }

    private func statLabel(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .displaySymbolFont(9)
            Text(text)
                .displayFont(11)
        }
        .foregroundStyle(color.opacity(0.85))
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isBatchMode {
                Button("完成") {
                    exitBatchMode()
                }
                .displayFont(15, weight: .medium)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                if !bookmarkManager.bookmarks.isEmpty {
                    sortMenu
                    if !isBatchMode {
                        Button {
                            enterBatchMode()
                        } label: {
                            Image(systemName: "checklist")
                                .displaySymbolFont(14, weight: .medium)
                                .foregroundStyle(Color.sjzAccent)
                        }
                        .accessibilityLabel("批量管理")
                    }
                    moreMenu
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(BookmarkSortOrder.allCases) { order in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sortOrder = order
                    }
                    LogManager.shared.info("favorite", "收藏排序切换", context: [
                        "sort": order.rawValue, "count": "\(visibleItems.count)"
                    ])
                } label: {
                    Label(order.title, systemImage: sortOrder == order ? "checkmark" : order.icon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(Color.sjzAccent)
        }
        .accessibilityLabel("排序方式")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                bookmarkManager.precacheAllContent()
            } label: {
                Label("缓存全部正文（离线预热）", systemImage: "arrow.down.doc.fill")
            }
            .disabled(bookmarkManager.precacheCandidates.isEmpty)
            Button {
                showDiagnosePanel = true
                LogManager.shared.debugLog("favorite", "打开收藏诊断面板（菜单入口）", context: [:])
            } label: {
                Label("存储诊断", systemImage: "wrench.and.screwdriver")
            }
            Divider()
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空全部收藏", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .displaySymbolFont(16, weight: .medium)
                .foregroundStyle(Color.sjzAccent)
        }
        .accessibilityLabel("更多操作")
    }

    // MARK: 诊断面板（长按标题图标 5 次 / 更多菜单进入）

    private var diagnosePanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(storageSnapshot?.summaryText ?? "正在统计存储…")
                        .displayFont(13)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    diagnoseAction(icon: "arrow.triangle.2.circlepath", title: "重写存储并校验", tint: Color.sjzPrimary) {
                        let ok = bookmarkManager.rebuildStorage()
                        showBanner(ok ? "存储校验通过" : "存储校验失败，请查看日志", icon: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", tone: ok ? .success : .warning)
                    }
                    diagnoseAction(icon: "trash", title: "清理图片缓存（保留收藏）", tint: Color.sjzOrange) {
                        Task {
                            let removed = await bookmarkManager.clearImageCache()
                            showBanner("已清理 \(removed.files) 张图片缓存", icon: "trash.fill", tone: .info)
                            storageSnapshot = await bookmarkManager.storageSnapshot()
                        }
                    }
                    diagnoseAction(icon: "arrow.down.doc.fill", title: "缓存全部未缓存正文", tint: Color.sjzGreen) {
                        bookmarkManager.precacheAllContent()
                        showDiagnosePanel = false
                    }

                    Text("日志在「我的 → 应用日志」搜索 favorite 查看收藏全链路")
                        .displayFont(11)
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
            }
            .navigationTitle("收藏诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showDiagnosePanel = false }
                }
            }
            .task {
                storageSnapshot = await bookmarkManager.storageSnapshot()
                LogManager.shared.info("favorite", "诊断面板打开", context: [
                    "total": "\(bookmarkManager.count)",
                    "cachedContent": "\(bookmarkManager.contentCachedCount)"
                ])
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func diagnoseAction(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            LogManager.shared.info("favorite", "诊断操作：\(title)", context: [:])
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .displaySymbolFont(14, weight: .medium)
                    .frame(width: 22)
                Text(title)
                    .displayFont(14, weight: .medium)
                Spacer()
                Image(systemName: "chevron.right")
                    .displaySymbolFont(11, weight: .medium)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: 行交互

    private func openItem(_ item: BookmarkItem) {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        let wasRead = readManager.isRead(item.readKey)
        bookmarkManager.markViewed(item.readKey)
        LogManager.shared.info("favorite", "打开收藏文章", context: [
            "readKey": item.readKey,
            "title": item.title,
            "wasRead": "\(wasRead)",
            "cached": "\(item.contentCached)",
            "articleId": item.articleId ?? "-"
        ])
        openedBookmark = item
    }

    private func removeItem(_ item: BookmarkItem, source: String) {
        let impact = UIImpactFeedbackGenerator(style: .rigid)
        impact.impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            bookmarkManager.removeBookmark(item.readKey)
        }
        selectedKeys.remove(item.readKey)
        LogManager.shared.info("favorite", "取消收藏（\(source)）", context: [
            "readKey": item.readKey, "title": item.title
        ])
        showBanner("已取消收藏", icon: "bookmark.slash.fill", tone: .info)
    }

    private func toggleRead(_ item: BookmarkItem, markRead: Bool) {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if markRead {
                readManager.markAsRead(item.readKey)
            } else {
                readManager.markAsUnread(item.readKey)
            }
        }
        LogManager.shared.info("favorite", markRead ? "标记收藏为已读" : "标记收藏为未读", context: [
            "readKey": item.readKey, "title": item.title
        ])
    }

    private func copyLink(_ item: BookmarkItem) {
        UIPasteboard.general.string = item.originalArticleURL
        LogManager.shared.info("favorite", "复制收藏原文链接", context: [
            "readKey": item.readKey, "url": item.originalArticleURL
        ])
        showBanner("链接已复制", icon: "doc.on.doc.fill", tone: .success)
    }

    private func cacheSingle(_ item: BookmarkItem) {
        LogManager.shared.info("favorite", "手动缓存正文开始", context: [
            "readKey": item.readKey, "articleId": item.articleId ?? "-"
        ])
        showBanner("正在缓存正文…", icon: "arrow.down.doc", tone: .info)
        Task {
            let outcome = await bookmarkManager.cacheContent(for: item.readKey)
            switch outcome {
            case .cached:
                showBanner("正文已缓存，可离线阅读", icon: "checkmark.icloud.fill", tone: .success)
            case .failed:
                showBanner("正文缓存失败，请检查网络", icon: "exclamationmark.icloud.fill", tone: .warning)
            case .skipped:
                showBanner("该收藏无需缓存", icon: "info.circle.fill", tone: .info)
            default:
                break
            }
        }
    }

    /// 下拉刷新：检查收藏文章官网原文更新（手动触发不受推送开关限制）
    private func performUpdateCheck() async {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        LogManager.shared.info("favorite", "下拉刷新：收藏更新检查开始", context: [
            "count": "\(bookmarkManager.count)"
        ])
        let report = await bookmarkManager.checkBookmarkedArticlesForUpdates(manual: true)
        checkingUpdates = false
        if report.updated > 0 {
            showBanner("发现 \(report.updated) 篇内容更新", icon: "arrow.triangle.2.circlepath", tone: .warning)
        } else if report.checked > 0 {
            showBanner("已检查 \(report.checked) 篇 · 全部为最新", icon: "checkmark.seal.fill", tone: .success)
        } else if report.skipped > 0 {
            showBanner("暂无可比对缓存，先缓存正文即可开启更新检测", icon: "info.circle.fill", tone: .info)
        } else {
            showBanner("没有可检查的文章", icon: "info.circle.fill", tone: .info)
        }
    }

    // MARK: 批量辅助

    private func toggleSelection(_ key: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if selectedKeys.contains(key) {
                selectedKeys.remove(key)
            } else {
                selectedKeys.insert(key)
            }
        }
        LogManager.shared.debugLog("favorite", "批量选择切换", context: [
            "readKey": key, "selected": "\(selectedKeys.count)"
        ])
    }

    private func toggleSelectAll() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if allVisibleSelected {
                selectedKeys.subtract(visibleKeys)
            } else {
                selectedKeys.formUnion(visibleKeys)
            }
        }
        LogManager.shared.info("favorite", allVisibleSelected ? "批量取消全选" : "批量全选", context: [
            "visible": "\(visibleKeys.count)", "selected": "\(selectedKeys.count)"
        ])
    }

    private func enterBatchMode() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isBatchMode = true
        }
        LogManager.shared.info("favorite", "进入批量管理模式", context: ["count": "\(bookmarkManager.count)"])
    }

    private func exitBatchMode() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isBatchMode = false
            selectedKeys.removeAll()
        }
        LogManager.shared.debugLog("favorite", "退出批量管理模式", context: [:])
    }

    private func resetFilters() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            filterScope = .all
            searchText = ""
        }
        LogManager.shared.info("favorite", "重置收藏筛选", context: [:])
    }

    // MARK: 辅助

    /// 行无障碍描述（读屏完整播报状态）
    private func rowAccessibilityLabel(_ item: BookmarkItem, unread: Bool) -> String {
        var parts = [item.title, item.category]
        if unread { parts.append("未读") }
        if item.hasPendingUpdate {
            parts.append("内容有更新")
        } else if item.contentCached {
            parts.append("可离线阅读")
        }
        parts.append(relativeBookmarkTime(item.bookmarkDate, now: now))
        return parts.joined(separator: "，")
    }

    /// 收藏时间相对文案
    private func relativeBookmarkTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "刚刚收藏" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前收藏" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前收藏" }
        if interval < 7 * 86_400 { return "\(Int(interval / 86_400)) 天前收藏" }
        return "\(Self.bookmarkDateFormatter.string(from: date)) 收藏"
    }

    private static let bookmarkDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

// MARK: - 操作反馈横幅模型

private struct BookmarkBanner: Equatable {
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

// MARK: - 收藏行按压样式（缩放回弹，reduceMotion 门控）

private struct BookmarkRowPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: - 关键词高亮（AttributedString 口径，与消息中心一致）

private func bookmarkHighlighted(_ text: String, keyword: String) -> AttributedString {
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

// MARK: - 收藏缩略图组件

/// 收藏缩略图：统一走全 App 图片管线 `SJZCachedImage`
/// （零闪烁缓存直出 · ImageIO 降采样 · 滚动让路 · 无图模式 · 失败自动重试），
/// 并对「取消收藏前已固化到 BookmarkImages 的图片」提供离线兜底读取。
struct BookmarkThumbnailView: View {
    let imageUrl: String?
    let category: String

    @ObservedObject private var bookmarkManager = BookmarkManager.shared

    /// 离线兜底图（管线失败时读取收藏专属固化缓存）
    @State private var fallbackImage: UIImage?
    @State private var fallbackAttempted = false

    /// 缩略图目标解码边长（104×78pt @3x ≈ 312px，取 360 保证清晰）
    private static let thumbnailPixel: CGFloat = 360

    private var parsedURL: URL? {
        guard let imageUrl,
              !imageUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: imageUrl)
    }

    private var categoryAccent: Color { categoryColor(category) }

    var body: some View {
        SJZCachedImage(url: parsedURL, maxPixel: Self.thumbnailPixel, onPhaseChange: handlePhase) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                if let fallbackImage {
                    Image(uiImage: fallbackImage).resizable().scaledToFill()
                } else {
                    shimmerPlaceholder
                }
            case .failure:
                if let fallbackImage {
                    Image(uiImage: fallbackImage).resizable().scaledToFill()
                } else {
                    failurePlaceholder
                }
            case .skipped:
                SJZImageFreePlaceholder(icon: "newspaper", tone: categoryAccent)
            }
        }
        .clipped()
        .allowsHitTesting(false)   // 缩略图为装饰层：行点击 / 滑动手势优先
        .task(id: imageUrl) {
            fallbackImage = nil
            fallbackAttempted = false
        }
    }

    /// 管线阶段回调（主线程）：失败时读固化缓存兜底；成功时回填固化（URLCache 命中时零成本）
    private func handlePhase(_ phase: SJZImagePhase) {
        guard let normalized = imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return }
        switch phase {
        case .failure:
            guard !fallbackAttempted else { return }
            fallbackAttempted = true
            Task {
                if let image = await bookmarkManager.loadCachedImage(for: normalized) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        fallbackImage = image
                    }
                    LogManager.shared.info("favorite", "缩略图离线兜底命中固化缓存", context: [
                        "url": URL(string: normalized)?.lastPathComponent ?? "-"
                    ])
                }
            }
        case .success:
            Task {
                await bookmarkManager.cacheImage(from: normalized)
            }
        default:
            break
        }
    }

    private var shimmerPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [categoryAccent.opacity(0.16), categoryAccent.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            ShimmerView()
                .opacity(0.35)
        }
    }

    private var failurePlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [categoryAccent.opacity(0.18), categoryAccent.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "newspaper.fill")
                .displaySymbolFont(24)
                .foregroundStyle(categoryAccent.opacity(0.3))
        }
    }
}

// MARK: - 预览

#Preview("浅色模式") {
    NavigationStack {
        BookmarkListView()
    }
    .preferredColorScheme(.light)
}

#Preview("深色模式") {
    NavigationStack {
        BookmarkListView()
    }
    .preferredColorScheme(.dark)
}