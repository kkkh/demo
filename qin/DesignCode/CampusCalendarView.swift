//
//  CampusCalendarView.swift
//  山西晋中理工学院 APP — 校园日历（校园服务第七项）
//
//  校园日历原生模块：
//  · 列表页：渐变 Hero 头卡（同步证据/离线缓存徽章）+ Liquid Glass 搜索框（聚焦描边动画 +
//    搜索历史胶囊）+ 图标化文章卡片（官网列表图为占位图，不渲染缩略图）+ 入场 stagger +
//    骨架屏 + 分页触底加载 + 下拉刷新三态横幅 + 空态/失败重试；
//  · 搜索：本地多词 AND（Store 侧）+ 标题/摘要橙色关键词高亮（NSRange⇄Character 双域安全转换）；
//  · 详情页：标题/更新时间 + 正文大图竖排（SJZCachedImage 降采样）+ 轻点全屏（缩放拖拽）+
//    长按系统菜单「保存图片/分享」（复用 ProfileImageSaveShare + ShareSheet）+ 复制全文 +
//    保存全部图片 + 正文纯文本说明 + 无图优雅兜底；
//  · 完整日志埋点（LogManager 域 campusCalendar），「我的-应用日志」全程可追溯。
//

import SwiftUI
import UIKit

// MARK: - 校园日历列表页

struct CampusCalendarView: View {
    @ObservedObject private var store = CampusCalendarStore.shared

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var listAppeared = false
    @State private var refreshSuccessPulse = false
    @State private var toastText: String?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedArticles: [NetworkService.ArticleDTO] {
        isSearching ? store.searchResults : store.articles
    }

    private var searchWords: [String] {
        searchText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                heroCard
                searchBar
                if !isSearching { refreshBanner }
                if isSearching && (store.searchHitCount > 0 || store.isSearchPending) { hitBadge }
                contentStack
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(GradientBackground())
        .refreshable {
            await store.refreshDetached(source: "下拉刷新")
        }
        .navigationTitle("校园日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { calendarToolbar }
        .task {
            store.loadInitial()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.06)) { listAppeared = true }
            LogManager.shared.info("campusCalendar", "校园日历页面打开", context: [
                "hasLoaded": "\(store.articles.count > 0 || store.isFromCache)",
                "cachedTotal": "\(store.total)",
                "isFromCache": "\(store.isFromCache)"
            ])
        }
        .onDisappear {
            LogManager.shared.debugLog("campusCalendar", "校园日历页面关闭", context: [
                "total": "\(store.total)"
            ])
        }
        .onChange(of: searchText) { _, newValue in
            store.search(newValue)
        }
        .onChange(of: store.refreshStatus) { _, status in
            handleRefreshStatusChange(status)
        }
        .overlay(alignment: .top) { toastOverlay }
    }

    // MARK: Hero 头卡（同步证据 + 离线缓存徽章）

    private var heroCard: some View {
        ZStack {
            // 艺术装饰：两团柔光，营造渐变玻璃层次
            Circle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 140, height: 140)
                .blur(radius: 24)
                .offset(x: 140, y: -46)
            Circle()
                .fill(Color.sjzTeal.opacity(0.25))
                .frame(width: 110, height: 110)
                .blur(radius: 26)
                .offset(x: -150, y: 54)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.22))
                        Image(systemName: "calendar")
                            .displaySymbolFont(24, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("校园日历")
                            .displayFont(22, weight: .heavy)
                            .foregroundStyle(.white)
                        Text("官网实时同步 · 校历一图掌握")
                            .displayFont(11)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if !store.isFromCache { syncBadge }
                        countBadge
                        if store.isFromCache { offlineBadge }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if !store.isFromCache { syncBadge }
                        countBadge
                        if store.isFromCache { offlineBadge }
                    }
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SJZDesignTokens.accentGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: Color.sjzAccent.opacity(0.32), radius: 18, y: 9)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("校园日历，共 \(store.total) 期，\(alwaysSyncText)")
    }

    private var alwaysSyncText: String {
        guard let date = store.lastRefreshDate else { return "等待同步" }
        if store.isFromCache { return "离线缓存，同步于" + relativeSyncText(date) }
        return "已同步官网 " + relativeSyncText(date)
    }

    private func relativeSyncText(_ date: Date) -> String {
        Self.syncDateFormatter.string(from: date)
    }

    private static let syncDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private var syncBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.clockwise")
                .displaySymbolFont(10, weight: .semibold)
            Text("已同步官网")
                .displayFont(10, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.18)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }

    private var countBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.grid.2x2.fill").displaySymbolFont(9, weight: .semibold)
            Text("共 \(store.total) 期").displayFont(10, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.18)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }

    private var offlineBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "internaldrive.fill").displaySymbolFont(9, weight: .semibold)
            Text("离线缓存").displayFont(10, weight: .semibold)
        }
        .foregroundStyle(Color.sjzGold)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.sjzGold.opacity(0.18)))
        .overlay(Capsule().strokeBorder(Color.sjzGold.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: 搜索框（Liquid Glass + 聚焦渐变描边动画）

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .displaySymbolFont(14, weight: .medium)
                    .foregroundStyle(searchFocused ? Color.sjzAccent : .secondary)
                TextField("搜索校历（支持多词）", text: $searchText)
                    .displayFont(15)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .accessibilityLabel("搜索校园日历")
                if store.isSearchPending {
                    ProgressView()
                        .tint(Color.sjzAccent)
                        .scaleEffect(0.7)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                        .accessibilityLabel("正在搜索")
                }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .displaySymbolFont(14)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if searchFocused {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.sjzAccent, Color.sjzTeal],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5)
                        .shadow(color: Color.sjzAccent.opacity(0.22), radius: 9, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)

            if searchFocused && searchText.isEmpty && !store.searchHistory.isEmpty {
                searchHistoryBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: searchFocused)
    }

    private var searchHistoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.searchHistory, id: \.self) { item in
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        searchText = item
                        LogManager.shared.info("campusCalendar", "搜索历史点击回填", context: ["keyword": item])
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .displaySymbolFont(10, weight: .medium)
                                .foregroundStyle(Color.sjzTeal)
                            Text(item)
                                .displayFont(11, weight: .medium)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("搜索历史：\(item)")
                }
                Button {
                    store.clearSearchHistory()
                } label: {
                    Text("清空")
                        .displayFont(11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索历史")
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: 刷新三态横幅（直观可见状态提示）

    @ViewBuilder
    private var refreshBanner: some View {
        switch store.refreshStatus {
        case .idle:
            EmptyView()

        case .refreshing:
            HStack(spacing: 8) {
                ProgressView().tint(Color.sjzTeal).scaleEffect(0.75)
                Text("正在同步官网校历…")
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("正在同步")

        case .success(let elapsedMs, let total, _):
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(13)
                        .foregroundStyle(Color.sjzGreen)
                    Text("同步成功 · 共 \(total) 期 · \(elapsedMs)ms")
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(.primary)
                }
                Text("已与官网保持一致，最新校历随时可查")
                    .displayFont(10)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.sjzGreen.opacity(0.35), lineWidth: 0.5))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("同步成功")

        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .displaySymbolFont(13)
                    .foregroundStyle(Color.sjzCoral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步失败，正在展示本地内容")
                        .displayFont(12, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.info("campusCalendar", "失败横幅重试点击", context: [:])
                    Task { await store.refreshDetached(source: "重试") }
                } label: {
                    Text("重试")
                        .displayFont(11, weight: .semibold)
                        .foregroundStyle(Color.sjzAccent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.sjzAccent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Button {
                    store.dismissRefreshBanner()
                } label: {
                    Image(systemName: "xmark")
                        .displaySymbolFont(10, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭横幅")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.sjzCoral.opacity(0.35), lineWidth: 0.5))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("同步失败")
        }
    }

    private var hitBadge: some View {
        HStack(spacing: 6) {
            if store.isSearchPending {
                ProgressView().tint(Color.sjzOrange).scaleEffect(0.7)
                Text("正在搜索…")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .displaySymbolFont(11, weight: .semibold)
                    .foregroundStyle(Color.sjzOrange)
                Text("命中 \(store.searchHitCount) 期")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.sjzOrange.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.sjzOrange.opacity(0.35), lineWidth: 0.5))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: 内容区（骨架 / 错误 / 空态 / 列表 / 分页）

    @ViewBuilder
    private var contentStack: some View {
        if store.isLoading && store.articles.isEmpty && !store.isFromCache {
            skeletonCards
        } else if isSearching {
            if store.isSearchPending && store.searchHitCount == 0 {
                searchingCard
            } else if store.searchHitCount == 0 {
                emptyCard(
                    icon: "magnifyingglass",
                    title: "未找到相关校历",
                    subtitle: "试试更换关键词（支持多词，如「2025 校历」）")
            } else {
                articleList
            }
        } else if let error = store.lastError, store.articles.isEmpty {
            errorRetryCard(error)
        } else if store.articles.isEmpty {
            emptyCard(
                icon: "calendar.badge.exclamationmark",
                title: "校园日历暂无内容",
                subtitle: "官网发布校历后将自动同步展示，下拉可手动刷新")
        } else {
            articleList
            loadMoreFooter
        }
    }

    private var searchingCard: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.sjzOrange).scaleEffect(0.8)
            Text("正在搜索…")
                .displayFont(13, weight: .semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .transition(.opacity)
        .accessibilityLabel("正在搜索")
    }

    private var skeletonCards: some View {
        VStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("校历标题占位占位")
                            .displayFont(15, weight: .semibold)
                        Text("2025.09.01")
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("正在加载")
    }

    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.sjzLight).frame(width: 76, height: 76)
                Image(systemName: icon)
                    .displaySymbolFont(28, weight: .medium)
                    .foregroundStyle(Color.sjzAccent.opacity(0.75))
            }
            Text(title)
                .displayFont(16, weight: .semibold)
                .foregroundStyle(.primary)
            Text(subtitle)
                .displayFont(12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private func errorRetryCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.sjzCoral.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: "wifi.exclamationmark")
                    .displaySymbolFont(26, weight: .medium)
                    .foregroundStyle(Color.sjzCoral)
            }
            Text("加载失败，请检查网络")
                .displayFont(16, weight: .semibold)
                .foregroundStyle(.primary)
            Text(message)
                .displayFont(12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                LogManager.shared.info("campusCalendar", "失败重试卡点击", context: [:])
                Task { await store.refreshDetached(source: "重试") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").displaySymbolFont(11, weight: .semibold)
                    Text("重新加载").displayFont(13, weight: .semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Capsule().fill(Color.sjzAccent))
                .shadow(color: Color.sjzAccent.opacity(0.3), radius: 9, y: 4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 文章卡片列表（图标化卡片 + 关键词高亮 + 入场 stagger）

    private var articleList: some View {
        ForEach(Array(displayedArticles.enumerated()), id: \.offset) { index, article in
            NavigationLink {
                CampusCalendarDetailView(article: article)
            } label: {
                articleCard(article, index: index)
            }
            .buttonStyle(.plain)
            .opacity(listAppeared ? 1 : 0)
            .offset(y: listAppeared ? 0 : 18)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.86).delay(Double(min(index, 10)) * 0.05),
                value: listAppeared)
            .simultaneousGesture(
                TapGesture().onEnded {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.info("campusCalendar", "日历文章卡片点击", context: [
                        "articleId": article.id ?? "(无)",
                        "title": article.resolvedTitle ?? article.title ?? "(无标题)",
                        "index": "\(index)"
                    ])
                }
            )
        }
    }

    private func articleCard(_ article: NetworkService.ArticleDTO, index: Int) -> some View {
        let palette = Self.cardPalettes[index % Self.cardPalettes.count]
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [palette.0, palette.1],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "calendar")
                    .displaySymbolFont(22, weight: .semibold)
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)
            .shadow(color: palette.0.opacity(0.35), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 6) {
                Text(highlighted(article.resolvedTitle ?? article.title ?? "校园日历", words: isSearching ? searchWords : []))
                    .displayFont(15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    let dateText = CampusCalendarStore.dateText(article.createTime ?? article.updateTime)
                    if !dateText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .displaySymbolFont(9, weight: .medium)
                            Text(dateText)
                                .displayFont(10, weight: .medium)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                    if store.isRead(articleId: article.id) {
                        Text("已读")
                            .displayFont(10, weight: .semibold)
                            .foregroundStyle(Color.sjzGreen)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.sjzGreen.opacity(0.12)))
                    }
                    if let tag = article.tag, !tag.isEmpty {
                        Text(tag)
                            .displayFont(10, weight: .semibold)
                            .foregroundStyle(palette.0)
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(palette.0.opacity(0.12)))
                    }
                }

                if let desc = article.description, !desc.isEmpty {
                    Text(highlighted(desc, words: isSearching ? searchWords : []))
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .displaySymbolFont(10, weight: .medium)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("轻点查看校历详情")
    }

    private static let cardPalettes: [(Color, Color)] = [
        (Color.sjzAccent, Color.sjzIndigo),
        (Color.sjzTeal, Color.sjzSkyBlue),
        (Color.sjzGold, Color.sjzOrange),
        (Color.sjzIndigo, Color.sjzAccent),
        (Color.sjzCoral, Color.sjzGold),
    ]

    // MARK: 分页底部

    @ViewBuilder
    private var loadMoreFooter: some View {
        Group {
            if store.isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.sjzTeal).scaleEffect(0.8)
                    Text("正在加载更多…")
                        .displayFont(11)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else if store.loadMoreFailed {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    LogManager.shared.info("campusCalendar", "加载更多失败重试点击", context: [:])
                    Task { await store.loadMore() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").displaySymbolFont(10, weight: .semibold)
                        Text("加载失败，轻点重试")
                            .displayFont(11, weight: .semibold)
                    }
                    .foregroundStyle(Color.sjzAccent)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
            } else if !store.hasMore {
                HStack(spacing: 12) {
                    Rectangle().fill(.tertiary.opacity(0.4)).frame(height: 0.5)
                    Text("已经到底啦")
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                    Rectangle().fill(.tertiary.opacity(0.4)).frame(height: 0.5)
                }
                .padding(.vertical, 10)
            } else {
                Color.clear.frame(height: 40)
                    .onAppear {
                        LogManager.shared.debugLog("campusCalendar", "列表触底，触发加载更多", context: [
                            "loaded": "\(store.articles.count)", "total": "\(store.total)"
                        ])
                        Task { await store.loadMore() }
                    }
            }
        }
    }

    // MARK: 关键词橙色高亮（NSRange⇄Character 双域安全转换，与帮助中心规范一致）

    private func highlighted(_ text: String, words: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for word in words where !word.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].foregroundColor = .sjzOrange
                }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return attributed
    }

    // MARK: 工具栏 / 状态处理 / Toast

    @ToolbarContentBuilder
    private var calendarToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                LogManager.shared.info("campusCalendar", "工具栏刷新按钮点击", context: [:])
                Task { await store.refresh(source: "工具栏刷新") }
            } label: {
                Group {
                    if store.refreshStatus == .refreshing {
                        ProgressView()
                            .tint(Color.sjzTeal)
                            .scaleEffect(0.8)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    } else if refreshSuccessPulse {
                        Image(systemName: "checkmark.seal.fill")
                            .displaySymbolFont(15, weight: .semibold)
                            .foregroundStyle(Color.sjzGreen)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .displaySymbolFont(13, weight: .medium)
                            .foregroundStyle(Color.sjzTeal)
                            .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.refreshStatus == .refreshing)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: refreshSuccessPulse)
            }
            .disabled(store.refreshStatus == .refreshing || store.isLoading)
            .accessibilityLabel("刷新校园日历")
        }
    }

    private func handleRefreshStatusChange(_ status: CampusCalendarStore.RefreshStatus) {
        switch status {
        case .success:
            refreshSuccessPulse = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                refreshSuccessPulse = false
                store.dismissRefreshBanner()
            }
        case .failed(let message):
            LogManager.shared.debugLog("campusCalendar", "刷新失败横幅展示", context: ["error": message])
        case .refreshing, .idle:
            break
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzGreen)
                Text(toastText)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 8)
            .zIndex(10)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            toastText = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                toastText = nil
            }
        }
    }
}

// MARK: - 校历详情页（大图主打 + 长按保存/分享 + 复制全文）

struct CampusCalendarDetailView: View {
    let article: NetworkService.ArticleDTO
    @ObservedObject private var store = CampusCalendarStore.shared
    @Environment(\.openURL) private var openURL

    @State private var detail: NetworkService.ArticleDetailDTO?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var imageURLs: [URL] = []
    @State private var plainText = ""
    @State private var fullScreenItem: CalendarFullScreenImage?
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var toastText: String?
    @State private var lastScrollLog = Date.distantPast
    @State private var isSavingAll = false

    private var titleText: String {
        detail?.title ?? article.resolvedTitle ?? article.title ?? "校园日历"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isLoading && detail == nil {
                    detailSkeleton
                } else if let detail {
                    detailContent(detail)
                } else if let loadError {
                    detailErrorCard(loadError)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(GradientBackground())
        .navigationTitle("校历详情")
        .readingReportTrack(articleId: article.id ?? "", title: article.title ?? "", source: "校历")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: article.id) {
            await load()
        }
        .onAppear {
            LogManager.shared.info("campusCalendar", "校历详情页打开", context: [
                "articleId": article.id ?? "(无)",
                "title": titleText
            ])
        }
        .onDisappear {
            LogManager.shared.debugLog("campusCalendar", "校历详情页关闭", context: [
                "articleId": article.id ?? "(无)", "images": "\(imageURLs.count)"
            ])
        }
        .fullScreenCover(item: $fullScreenItem) { item in
            FullScreenImageView(url: item.url, title: item.title)
                .sjzPresentationChrome()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .overlay(alignment: .top) { toastOverlay }
        .simultaneousGesture(scrollDirectionGesture)
    }

    private func load() async {
        guard let articleId = article.id, !articleId.isEmpty else {
            LogManager.shared.warning("campusCalendar", "详情打开失败：文章 ID 无效", context: [
                "title": titleText
            ])
            loadError = "该文章缺少有效标识，无法加载详情"
            isLoading = false
            return
        }
        if let detail = await store.loadDetail(articleId: articleId) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                self.detail = detail
                self.imageURLs = CalendarHTMLParse.imageURLs(
                    fromHTML: detail.content ?? "",
                    fallbackImageURL: detail.imageUrl)
                self.plainText = CalendarHTMLParse.plainText(fromHTML: detail.content ?? "")
                self.isLoading = false
            }
        } else {
            loadError = "详情加载失败，请检查网络后重试"
            isLoading = false
        }
    }

    // MARK: 详情内容

    private func detailContent(_ detail: NetworkService.ArticleDetailDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // 标题卡
            VStack(alignment: .leading, spacing: 10) {
                Text(titleText)
                    .displayFont(21, weight: .heavy)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    let dateText = CampusCalendarStore.dateText(detail.updateTime ?? article.createTime)
                    if !dateText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .displaySymbolFont(10, weight: .medium)
                            Text("更新于 \(dateText)")
                                .displayFont(11, weight: .medium)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    }
                    if let tag = detail.tag, !tag.isEmpty {
                        Text(tag)
                            .displayFont(11, weight: .semibold)
                            .foregroundStyle(Color.sjzGold)
                            .lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.sjzGold.opacity(0.14)))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))

            // 操作栏
            actionBar

            // 图片区（大图主打 / 无图优雅兜底）
            if imageURLs.isEmpty {
                noImageCard
            } else {
                imagesStack
            }

            // 正文纯文本说明
            if !plainText.isEmpty {
                plainTextSection
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    actionButton(icon: "doc.on.doc", title: "复制全文") { copyFullText() }
                    if !imageURLs.isEmpty { savingAllButton }
                    if originalURL != nil { openOriginalButton }
                }
                VStack(alignment: .leading, spacing: 10) {
                    actionButton(icon: "doc.on.doc", title: "复制全文") { copyFullText() }
                    if !imageURLs.isEmpty { savingAllButton }
                    if originalURL != nil { openOriginalButton }
                }
            }
            actionHint
        }
    }

    private var actionHint: some View {
        HStack(spacing: 5) {
            Image(systemName: imageURLs.isEmpty ? "info.circle" : "hand.tap")
                .displaySymbolFont(10, weight: .medium)
                .foregroundStyle(.secondary)
            Text(imageURLs.isEmpty
                 ? "本页暂无配图，可复制全文或查看官网原文"
                 : "轻点图片全屏查看，长按可保存或分享")
                .displayFont(10)
                .foregroundStyle(.secondary)
        }
    }

    private var originalURL: URL? {
        guard let href = article.href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else {
            return nil
        }
        let candidate = href.hasPrefix("http")
            ? href
            : "https://www.sxjzit.edu.cn" + (href.hasPrefix("/") ? href : "/" + href)
        return URL(string: candidate)
    }

    private var openOriginalButton: some View {
        Button {
            guard let url = originalURL else { return }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            LogManager.shared.info("campusCalendar", "查看官网原文点击", context: [
                "articleId": article.id ?? "(无)", "url": url.absoluteString
            ])
            openURL(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "safari").displaySymbolFont(12, weight: .semibold)
                Text("查看原文").displayFont(12, weight: .semibold)
            }
            .foregroundStyle(Color.sjzTeal)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color.sjzTeal.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.sjzTeal.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("在浏览器中查看官网原文")
    }

    private var savingAllButton: some View {
        Button {
            if isSavingAll { return }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            saveAllImages()
        } label: {
            HStack(spacing: 6) {
                if isSavingAll {
                    ProgressView().tint(Color.sjzAccent).scaleEffect(0.8)
                } else {
                    Image(systemName: "square.and.arrow.down").displaySymbolFont(12, weight: .semibold)
                }
                Text(isSavingAll ? "正在保存…" : "保存全部图片")
                    .displayFont(12, weight: .semibold)
            }
            .foregroundStyle(Color.sjzAccent)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color.sjzAccent.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.sjzAccent.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isSavingAll)
        .accessibilityLabel(isSavingAll ? "正在保存全部图片" : "保存全部图片")
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).displaySymbolFont(12, weight: .semibold)
                Text(title).displayFont(12, weight: .semibold)
            }
            .foregroundStyle(Color.sjzAccent)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color.sjzAccent.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.sjzAccent.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 图片竖排（全屏 + 长按菜单）

    private var imagesStack: some View {
        VStack(spacing: 14) {
            ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                VStack(spacing: 7) {
                    SJZCachedImage(url: url, maxPixel: 1440) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        case .failure:
                            imagePlaceholder(icon: "photo.badge.exclamationmark", text: "图片加载失败")
                        case .empty:
                            imagePlaceholder(icon: "photo", text: "正在加载图片…", showsProgress: true)
                        case .skipped:
                            SJZImageFreePlaceholder(icon: "photo")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        fullScreenItem = CalendarFullScreenImage(
                            url: url,
                            title: "\(titleText) · \(index + 1)/\(imageURLs.count)")
                        LogManager.shared.info("campusCalendar", "全屏图片查看", context: [
                            "articleId": article.id ?? "(无)", "index": "\(index)",
                            "total": "\(imageURLs.count)", "file": url.lastPathComponent
                        ])
                    }
                    .contextMenu {
                        Button {
                            saveImage(at: index)
                        } label: {
                            Label("保存图片", systemImage: "square.and.arrow.down")
                                .displayLabelFont(17)
                        }
                        Button {
                            shareImage(at: index)
                        } label: {
                            Label("分享…", systemImage: "square.and.arrow.up")
                                .displayLabelFont(17)
                        }
                        Button {
                            fullScreenItem = CalendarFullScreenImage(
                                url: url,
                                title: "\(titleText) · \(index + 1)/\(imageURLs.count)")
                            LogManager.shared.info("campusCalendar", "全屏图片查看（长按菜单）", context: [
                                "articleId": article.id ?? "(无)", "index": "\(index)"
                            ])
                        } label: {
                            Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right")
                                .displayLabelFont(17)
                        }
                    }
                    .accessibilityLabel("校历图片 \(index + 1)/\(imageURLs.count)")
                    .accessibilityHint("轻点全屏查看，长按可保存或分享")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        fullScreenItem = CalendarFullScreenImage(
                            url: url,
                            title: "\(titleText) · \(index + 1)/\(imageURLs.count)")
                        LogManager.shared.info("campusCalendar", "全屏图片查看（旁白激活）", context: [
                            "articleId": article.id ?? "(无)", "index": "\(index)"
                        ])
                    }

                    if imageURLs.count > 1 {
                        Text("\(index + 1) / \(imageURLs.count)")
                            .displayFont(10, weight: .medium)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private func imagePlaceholder(icon: String, text: String, showsProgress: Bool = false) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(Color.sjzTeal)
            } else {
                Image(systemName: icon)
                    .displaySymbolFont(26)
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .displayFont(11)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var noImageCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.sjzLight).frame(width: 72, height: 72)
                Image(systemName: "photo.on.rectangle")
                    .displaySymbolFont(26, weight: .medium)
                    .foregroundStyle(Color.sjzAccent.opacity(0.7))
            }
            Text("本页暂无配图")
                .displayFont(15, weight: .semibold)
                .foregroundStyle(.primary)
            Text("官网仅发布文字版本的校历，可直接复制全文")
                .displayFont(11)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    private var plainTextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(Color.sjzTeal)
                Text("正文说明")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            Text(plainText)
                .displayFont(14)
                .foregroundStyle(.secondary)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 骨架 / 错误

    private var detailSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("校历详情标题占位占位占位")
                .displayFont(21, weight: .heavy)
            Text("更新于 2025.09.01").displayFont(11).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(height: 300)
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("正在加载详情")
    }

    private func detailErrorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.sjzCoral.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: "wifi.exclamationmark")
                    .displaySymbolFont(26, weight: .medium)
                    .foregroundStyle(Color.sjzCoral)
            }
            Text("详情加载失败")
                .displayFont(16, weight: .semibold)
                .foregroundStyle(.primary)
            Text(message)
                .displayFont(12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                LogManager.shared.info("campusCalendar", "详情失败重试点击", context: [
                    "articleId": article.id ?? "(无)"
                ])
                isLoading = true
                loadError = nil
                Task { await load() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").displaySymbolFont(11, weight: .semibold)
                    Text("重新加载").displayFont(13, weight: .semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Capsule().fill(Color.sjzAccent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: 图片动作（长按保存 / 分享 / 全量保存）

    private func saveImage(at index: Int) {
        guard imageURLs.indices.contains(index) else { return }
        let url = imageURLs[index]
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        LogManager.shared.info("campusCalendar", "长按保存发起", context: [
            "index": "\(index)", "file": url.lastPathComponent
        ])
        Task {
            if let message = await ProfileImageSaveShare.saveToPhotos(
                urlString: url.absoluteString, logTag: "campusCalendar") {
                LogManager.shared.warning("campusCalendar", "长按保存失败", context: ["reason": message])
                showToast(message)
            } else {
                LogManager.shared.info("campusCalendar", "长按保存成功", context: [
                    "index": "\(index)", "file": url.lastPathComponent
                ])
                showToast("已保存到相册")
            }
        }
    }

    private func shareImage(at index: Int) {
        guard imageURLs.indices.contains(index) else { return }
        let url = imageURLs[index]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        LogManager.shared.info("campusCalendar", "分享面板触发", context: [
            "index": "\(index)", "file": url.lastPathComponent
        ])
        Task {
            shareItems = await ProfileImageSaveShare.prepareShareItems(urlString: url.absoluteString)
            showShareSheet = true
        }
    }

    private func saveAllImages() {
        guard !imageURLs.isEmpty else {
            showToast("本页暂无图片")
            return
        }
        guard !isSavingAll else { return }
        isSavingAll = true
        LogManager.shared.info("campusCalendar", "保存全部图片发起", context: [
            "count": "\(imageURLs.count)", "articleId": article.id ?? "(无)"
        ])
        let totalCount = imageURLs.count
        Task {
            var successCount = 0
            for url in imageURLs {
                if await ProfileImageSaveShare.saveToPhotos(urlString: url.absoluteString, logTag: "campusCalendar") == nil {
                    successCount += 1
                }
            }
            isSavingAll = false
            LogManager.shared.info("campusCalendar", "保存全部图片完成", context: [
                "success": "\(successCount)", "total": "\(totalCount)"
            ])
            if successCount == totalCount {
                showToast("已保存全部 \(totalCount) 张到相册")
            } else {
                showToast("已保存 \(successCount)/\(totalCount) 张到相册")
            }
        }
    }

    private func copyFullText() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !plainText.isEmpty else {
            LogManager.shared.warning("campusCalendar", "复制全文无内容", context: [
                "articleId": article.id ?? "(无)"
            ])
            showToast("本页没有可复制的正文文字")
            return
        }
        UIPasteboard.general.string = plainText
        LogManager.shared.info("campusCalendar", "复制全文", context: [
            "chars": "\(plainText.count)", "articleId": article.id ?? "(无)"
        ])
        showToast("已复制全文到剪贴板")
    }

    // MARK: 滚动方向日志（3 秒节流，工程惯例）

    private var scrollDirectionGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                let now = Date()
                guard now.timeIntervalSince(lastScrollLog) >= 3 else { return }
                lastScrollLog = now
                let direction = value.translation.height < 0 ? "down" : "up"
                LogManager.shared.debugLog("campusCalendar", "详情滚动方向", context: ["direction": direction])
            }
    }

    // MARK: Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .displaySymbolFont(13, weight: .semibold)
                    .foregroundStyle(Color.sjzGreen)
                Text(toastText)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 8)
            .zIndex(10)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            toastText = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                toastText = nil
            }
        }
    }
}

// MARK: - 全屏图片载体

private struct CalendarFullScreenImage: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

// MARK: - 正文 HTML 纯正则解析（禁 NSAttributedString HTML 解析——工程红线）

/// 校园日历正文解析：仅用纯正则提取 <img src> 与纯文本。
/// 图片 URL 修复规则与 OrganizationDetailView.resolveImageURL 同构
/// （该函数为 file-private，本模块按需本地实现）。
private enum CalendarHTMLParse {

    static let baseDomain = "http://www.sxjzit.edu.cn"

    /// 提取正文全部图片 URL（修复 + 过滤占位图 + 去重）。
    /// content 无图且 image_url 非占位时回退使用封面图。
    static func imageURLs(fromHTML html: String, fallbackImageURL: String?) -> [URL] {
        var urls: [String] = []
        let pattern = #"<img[^>]*src\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
                guard let match = match,
                      match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else { return }
                let raw = ns.substring(with: match.range(at: 1))
                guard !isPlaceholder(raw) else { return }
                let fixed = repair(raw)
                if !urls.contains(fixed) { urls.append(fixed) }
            }
        }
        if urls.isEmpty, let fallback = fallbackImageURL, !isPlaceholder(fallback) {
            urls.append(repair(fallback))
        }
        return urls.compactMap { ProfileImageSaveShare.safeURL(from: $0) }
    }

    /// 官网占位图过滤（列表与详情统一不渲染 no_picture）
    static func isPlaceholder(_ url: String) -> Bool {
        url.lowercased().contains("no_picture.webp")
    }

    /// 图片 URL 修复：相对路径/协议缺失补全 + 非 ASCII 百分号编码
    static func repair(_ raw: String) -> String {
        if raw.hasPrefix("data:") { return raw }

        if raw.hasPrefix("https://") || raw.hasPrefix("http://") {
            if raw.contains(where: { $0.unicodeScalars.contains(where: { $0.value > 127 }) }) {
                var allowed = CharacterSet.urlPathAllowed
                allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=%")
                if let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) {
                    return encoded
                }
            }
            return raw
        }
        if raw.hasPrefix("//") { return "http:" + raw }
        if raw.hasPrefix("/") { return baseDomain + raw }
        return baseDomain + "/" + raw
    }

    /// 正文 HTML → 纯文本（script/style 剔除 + 换行还原 + 实体解码）
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "",
            options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?i)<br\\s*/?>|</p>|</div>|</h[1-6]>", with: "\n",
            options: .regularExpression)
        text = text.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(
            of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}