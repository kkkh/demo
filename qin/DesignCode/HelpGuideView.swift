//
//  HelpGuideView.swift
//  DesignCode
//
//  使用帮助模块 UI：主页面（搜索/分类/列表）+ 文章详情（步骤/反馈/复制/相关）。
//  入口：首页「使用帮助」卡（NavigationLink push）。
//  日志域 helpGuide；视觉体系与全 App 一致（sjz 色板、胶囊卡片、spring 动效）。
//

import SwiftUI

// MARK: - 使用帮助主页面

struct HelpGuideView: View {
    @ObservedObject private var store = HelpGuideStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool

    // 搜索
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchHits: [HelpSearchHit] = []
    /// 防抖执行中标记：键入后 500ms 窗口内不展示「没有找到」空态，避免误导
    @State private var isSearching = false

    // 分类
    @State private var selectedCategory: String? = nil

    // 导航
    @State private var selectedArticle: HelpArticle?

    /// 清除阅读进度的确认弹窗（防误触，红色确认按钮 + 不可撤销提示）
    @State private var showResetConfirm = false

    /// 主页面通用状态提示（全部已读 / 进度清除反馈）
    @State private var toastText: String?

    /// 是否处于搜索态（输入非空）
    private var inSearchMode: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                headerHero
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                searchField
                    .padding(.top, 14)

                if inSearchMode {
                    searchResultsSection
                        .padding(.top, 14)
                } else {
                    categoryChips
                        .padding(.top, 16)

                    if selectedCategory == nil {
                        recentSection
                            .padding(.top, 20)
                    }

                    articleSections
                        .padding(.top, 20)
                }
                Color.clear.frame(height: 28)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("使用帮助")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        markAllReadAction()
                    } label: {
                        Label("全部标记已读", systemImage: "checkmark.circle")
                            .displayLabelFont(17)
                    }
                    .disabled(store.unreadCount == 0)

                    Button(role: .destructive) {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        showResetConfirm = true
                    } label: {
                        Label("清除阅读进度", systemImage: "arrow.counterclockwise.circle")
                            .displayLabelFont(17)
                    }
                    .disabled(store.readProgress <= 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .displaySymbolFont(16, weight: .semibold)
                        .foregroundStyle(Color.sjzAccent)
                }
                .accessibilityLabel("进度管理")

            }
        }
        .confirmationDialog("清除阅读进度", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("清除进度", role: .destructive) {
                resetReadAction()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除全部 \(store.totalArticles) 篇文章的已读标记，学习进度与首页进度环将归零。最近阅读记录不受影响。此操作不可撤销。")
        }
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: toastText)
        .onAppear {
            LogManager.shared.info("helpGuide", "使用帮助页面打开", context: [
                "totalArticles": "\(store.totalArticles)",
                "unread": "\(store.unreadCount)"
            ])
        }
        .onDisappear {
            searchTask?.cancel()
            LogManager.shared.debugLog("helpGuide", "使用帮助页面关闭", context: [:])
        }
        .sheet(item: $selectedArticle, onDismiss: {
            LogManager.shared.debugLog("helpGuide", "帮助文章详情关闭", context: [:])
        }) { article in
            NavigationStack {
                HelpArticleDetailView(article: article)
            }
            .sjzPresentationChrome()
        }
    }

    // MARK: - Hero 头卡

    private var headerHero: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(
                    colors: heroGradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "questionmark.circle.fill")
                        .displaySymbolFont(92)
                        .foregroundStyle(.white.opacity(0.14))
                        .offset(x: 8, y: -14)
                }
                .shadow(color: Color.sjzAccent.opacity(0.28), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("快速上手「园枢」")
                    .displayFont(22, weight: .bold)
                    .foregroundStyle(.white)
                Text("\(store.totalArticles) 篇指南 · 从入门到进阶，一步步带你用懂每一个功能")
                    .displayFont(12)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
            }
            .padding(.leading, 20)
            .padding(.vertical, 20)
            .padding(.trailing, 120) // 预留右下进度环空间，窄屏/大字号不重叠
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 3)
                        .frame(width: 34, height: 34)
                    Circle()
                        .trim(from: 0, to: store.readProgress <= 0 ? 0 : max(0.02, store.readProgress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 34, height: 34)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: store.readProgress)
                }
                Text("已读 \(Int(store.readProgress * 100))%")
                    .displayFont(11, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(16)
        }
        .frame(minHeight: 168)
    }

    private var heroGradientColors: [Color] {
        colorScheme == .dark
            ? [Color(hex: "1D3557"), Color.sjzAccent.opacity(0.75)]
            : [Color.sjzAccent, Color(hex: "4F8EF7")]
    }

    // MARK: - 搜索框（Liquid Glass 风格 + 聚焦描边动画）

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(13, weight: .semibold)
                .foregroundStyle(searchFocused ? Color.sjzAccent : Color.secondary)
                .animation(.easeInOut(duration: 0.2), value: searchFocused)

            TextField("搜索全部帮助内容", text: $searchText)
                .displayFont(14)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    handleSearchTextChange(newValue)
                }

            if !searchText.isEmpty {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    searchText = ""
                    searchHits = []
                    LogManager.shared.debugLog("helpGuide", "搜索框一键清空", context: [:])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(14)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("清空搜索")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.09) : .white)
                .shadow(color: .black.opacity(searchFocused ? 0.1 : 0.04),
                        radius: searchFocused ? 12 : 8,
                        y: searchFocused ? 5 : 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    searchFocused ? Color.sjzAccent.opacity(0.85) : Color.clear,
                    lineWidth: 1.6
                )
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)
        .animation(.easeInOut(duration: 0.2), value: searchText.isEmpty)
        .padding(.horizontal, 16)
        .onChange(of: searchFocused) { _, focused in
            LogManager.shared.debugLog("helpGuide", "搜索框聚焦变化", context: [
                "focused": "\(focused)",
                "keywordLength": "\(searchText.count)"
            ])
        }
    }

    /// 搜索输入处理：记录输入开始 → 500ms 防抖 → 执行搜索
    private func handleSearchTextChange(_ newValue: String) {
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let hits = store.search(trimmed)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                searchHits = hits
                isSearching = false
            }
        }
    }

    // MARK: - 搜索结果区

    @ViewBuilder
    private var searchResultsSection: some View {
        VStack(spacing: 12) {
            if isSearching && searchHits.isEmpty {
                searchingIndicator
            } else if searchHits.isEmpty {
                searchEmptyState
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(Color.sjzGreen)
                    Text("命中 \(searchHits.count) 篇")
                        .displayFont(13, weight: .semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(getCurrentKeyword())
                        .displayFont(11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)

                LazyVStack(spacing: 10) {
                    ForEach(searchHits) { hit in
                        helpArticleCard(
                            displayArticle(hit.article),
                            keyword: getCurrentKeyword()
                        )
                        .onTapGesture {
                            openArticle(hit.article, source: "search")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            openArticle(hit.article, source: "search")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if !store.searchHistory.isEmpty {
                searchHistorySection
                    .padding(.top, 6)
            }
        }
    }

    private func getCurrentKeyword() -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 搜索态读取文章的最新状态（已读标记实时反映）
    private func displayArticle(_ article: HelpArticle) -> HelpArticle {
        HelpCatalog.article(article.id) ?? article
    }

    /// 防抖窗口内的轻量搜索指示（真实可见：键入后至结果返回前，替代误导性空态）
    private var searchingIndicator: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("正在搜索「\(getCurrentKeyword())」…")
                .displayFont(13, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    /// 搜索空态引导
    private var searchEmptyState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.sjzAccent.opacity(0.14), Color.sjzTeal.opacity(0.1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 86, height: 86)
                .overlay {
                    Image(systemName: "text.magnifyingglass")
                        .displaySymbolFont(34, weight: .medium)
                        .foregroundStyle(Color.sjzAccent)
                }
                .shadow(color: Color.sjzAccent.opacity(0.2), radius: 12, y: 5)

            Text("没有找到相关内容")
                .displayFont(15, weight: .bold)
            Text("试试更短的关键词（2-4 字最佳）\n或换个说法，例如「推送」试试「通知」")
                .displayFont(12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .onAppear {
            LogManager.shared.debugLog("helpGuide", "帮助搜索空态展示", context: ["keyword": getCurrentKeyword()])
        }
    }

    /// 搜索历史条
    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索历史")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.clearSearchHistory()
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                } label: {
                    Image(systemName: "trash")
                        .displaySymbolFont(12)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("清空搜索历史")
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.searchHistory, id: \.self) { term in
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            searchText = term
                            LogManager.shared.info("helpGuide", "搜索历史点击回填", context: ["keyword": term])
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .displaySymbolFont(10)
                                Text(term)
                                    .displayFont(12)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white)
                            )
                            .overlay {
                                Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 分类 chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                categoryChip(
                    title: "全部",
                    icon: "square.grid.2x2.fill",
                    accent: Color.sjzPrimary,
                    isSelected: selectedCategory == nil
                ) {
                    selectCategory(nil)
                }

                ForEach(store.categories) { category in
                    categoryChip(
                        title: category.title,
                        icon: category.icon,
                        accent: category.accent,
                        isSelected: selectedCategory == category.id
                    ) {
                        selectCategory(category.id)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryChip(title: String, icon: String, accent: Color,
                              isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .displaySymbolFont(11, weight: .semibold)
                Text(title)
                    .displayFont(12, weight: .semibold)
            }
            .foregroundStyle(isSelected ? .white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(isSelected ? accent : (colorScheme == .dark ? Color.white.opacity(0.07) : .white))
            }
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Color.primary.opacity(0.07),
                    lineWidth: 1)
            }
            .shadow(color: accent.opacity(isSelected ? 0.3 : 0), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSelected)
    }

    private func selectCategory(_ id: String?) {
        selectedCategory = id
        LogManager.shared.info("helpGuide", "帮助分类切换", context: [
            "category": id ?? "all",
            "articleCount": id.map { "\(store.articleCount(in: $0))" } ?? "\(store.totalArticles)"
        ])
    }

    // MARK: - 最近阅读

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("最近阅读", icon: "clock.fill", accent: Color.sjzPrimary)
                .padding(.horizontal, 20)

            if store.recentArticles.isEmpty {
                // 空态引导：区块常显，让用户知道该功能存在
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .displaySymbolFont(12, weight: .semibold)
                        .foregroundStyle(Color.sjzPrimary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.sjzPrimary.opacity(0.1)))
                    Text("读过的文章会自动出现在这里，继续探索吧")
                        .displayFont(12)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.04) : .white)
                )
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.recentArticles) { article in
                            recentCard(article)
                                .onTapGesture {
                                    openArticle(article, source: "recent")
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction {
                                    openArticle(article, source: "recent")
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func recentCard(_ article: HelpArticle) -> some View {
        let category = HelpCatalog.category(of: article)
        let accent = category?.accent ?? .sjzAccent
        return VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent, accent.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: article.icon)
                        .displaySymbolFont(15, weight: .semibold)
                        .foregroundStyle(.white)
                }
            Text(article.title)
                .displayFont(13, weight: .semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 148, alignment: .leading)
            Text("\(article.readingMinutes) 分钟")
                .displayFont(10)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 172, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : .white)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        .contentShape(Rectangle())
    }

    // MARK: - 文章分区

    private var articleSections: some View {
        let categories: [HelpCategory] = {
            if let selectedCategory, let cat = store.categories.first(where: { $0.id == selectedCategory }) {
                return [cat]
            }
            return store.categories
        }()

        return ForEach(categories) { category in
            VStack(alignment: .leading, spacing: 12) {
                sectionHeaderRow(category)
                    .padding(.horizontal, 20)

                LazyVStack(spacing: 10) {
                    ForEach(HelpCatalog.articles(inCategory: category.id)) { article in
                        helpArticleCard(article, keyword: "")
                            .onTapGesture {
                                openArticle(article, source: "list")
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                openArticle(article, source: "list")
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 22)
        }
    }

    private func sectionHeaderRow(_ category: HelpCategory) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [category.accent, category.accent.opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: category.icon)
                        .displaySymbolFont(13, weight: .semibold)
                        .foregroundStyle(.white)
                }
                .shadow(color: category.accent.opacity(0.3), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .displayFont(16, weight: .bold)
                Text(category.subtitle)
                    .displayFont(11)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            countCapsule(
                text: "\(store.readCount(in: category.id))/\(store.articleCount(in: category.id)) 已读",
                accent: category.accent
            )
        }
    }

    private func sectionTitle(_ title: String, icon: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .displaySymbolFont(12, weight: .semibold)
                .foregroundStyle(accent)
            Text(title)
                .displayFont(16, weight: .bold)
            Spacer()
        }
    }

    private func countCapsule(text: String, accent: Color) -> some View {
        Text(text)
            .displayFont(11, weight: .semibold)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(accent.opacity(0.12)))
    }

    // MARK: - 文章卡片

    private func helpArticleCard(_ article: HelpArticle, keyword: String) -> some View {
        let category = HelpCatalog.category(of: article)
        let accent = category?.accent ?? .sjzAccent
        return HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent, accent.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 50, height: 50)
                .overlay {
                    Image(systemName: article.icon)
                        .displaySymbolFont(18, weight: .semibold)
                        .foregroundStyle(.white)
                }
                .shadow(color: accent.opacity(0.3), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(keyword.isEmpty ? AttributedString(article.title) : highlighted(article.title, keyword: keyword))
                    .displayFont(15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(article.summary)
                    .displayFont(12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    readingTimeCapsule(minutes: article.readingMinutes)
                    if let category {
                        Text(category.title)
                            .displayFont(10)
                            .foregroundStyle(accent)
                    }
                    Spacer()
                    if !store.isRead(article.id) {
                        Circle()
                            .fill(Color.sjzAccent)
                            .frame(width: 7, height: 7)
                            .shadow(color: Color.sjzAccent.opacity(0.5), radius: 3)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .displaySymbolFont(11)
                            .foregroundStyle(Color.sjzGreen.opacity(0.85))
                    }
                }
            }
            Image(systemName: "chevron.right")
                .displaySymbolFont(10, weight: .medium)
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : .white)
        )
        .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
        .contentShape(Rectangle())
    }

    private func readingTimeCapsule(minutes: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .displaySymbolFont(8, weight: .semibold)
            Text("\(minutes) 分钟")
                .displayFont(10, weight: .medium)
        }
        .foregroundStyle(readingTierColor(minutes))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(readingTierColor(minutes).opacity(0.12)))
    }

    private func readingTierColor(_ minutes: Int) -> Color {
        switch minutes {
        case ...4: return .sjzGreen
        case 5...9: return .sjzAccent
        case 10...19: return .sjzOrange
        default: return .sjzPurple
        }
    }

    /// 关键词橙色高亮（全部命中词；与消息中心高亮规范一致的 NSRange⇄Character 安全转换）
    private func highlighted(_ text: String, keyword: String) -> AttributedString {
        var attributed = AttributedString(text)
        for word in keyword.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }) {
            guard let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            if let attrRange = Range(range, in: attributed) {
                // 仅橙色高亮：字体由外层 displayFont 统一驱动，保证自定义字体家族与档位一致
                attributed[attrRange].foregroundColor = .sjzOrange
            }
        }
        return attributed
    }

    // MARK: - 打开文章

    /// 全部标记已读（菜单触发；状态提示 + 触觉 + 日志闭环）
    private func markAllReadAction() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        store.markAllRead()
        LogManager.shared.info("helpGuide", "工具栏全部已读触发", context: [:])
        showToast("已全部标记为已读")
    }

    /// 清除阅读进度（确认弹窗红色按钮触发；防误触恢复手段）
    private func resetReadAction() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        store.resetReadProgress()
        showToast("学习进度已清除，从未读重新开始")
    }

    /// 主页面通用状态提示
    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            toastText = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                toastText = nil
            }
        }
    }

    private func openArticle(_ article: HelpArticle, source: String) {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        // 搜索结果被真正点击时才写入搜索历史（防抖输入不污染历史），历史=用过的关键词
        if source == "search" {
            store.recordSearchHistory(getCurrentKeyword())
        }
        store.recordOpen(article)
        LogManager.shared.info("helpGuide", "帮助文章打开", context: [
            "articleId": article.id,
            "title": article.title,
            "source": source,
            "readingMinutes": "\(article.readingMinutes)"
        ])
        selectedArticle = article
    }
}

// MARK: - 文章详情页

struct HelpArticleDetailView: View {
    /// 初始文章（sheet 注入）
    private let initialArticle: HelpArticle

    /// 当前展示文章（相关阅读跳转时原地切换，滚动回顶）
    @State private var article: HelpArticle

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = HelpGuideStore.shared

    /// 反馈态度：nil 未表态；true 已点「有帮助」（触发继续学习引导）
    @State private var helpedState: Bool?
    /// 「没帮助」三招行动面板展开态
    @State private var showHelpPanel = false
    /// 面板内联搜索：关键词与结果（就地搜到答案）
    @State private var inlineKeyword = ""
    @State private var inlineHits: [HelpSearchHit] = []
    @State private var inlineTask: Task<Void, Never>?
    /// 通用状态提示（复制/分享成功后展示）
    @State private var toastText: String?

    init(article: HelpArticle) {
        self.initialArticle = article
        _article = State(initialValue: article)
    }

    private var category: HelpCategory? { HelpCatalog.category(of: article) }
    private var accent: Color { category?.accent ?? .sjzAccent }
    private var related: [HelpArticle] { HelpCatalog.related(to: article) }

    private var fullText: String {
        article.steps.map { "\($0.title)：\($0.text)" }.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader
                        .id("detailTop")
                    tagsRow
                    stepsSection
                    feedbackArea
                    if !related.isEmpty {
                        relatedSection
                    }
                    footerNote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .onChange(of: article.id) { _, _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo("detailTop", anchor: .top)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("使用帮助")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    copyFullText()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .displaySymbolFont(14, weight: .semibold)
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("复制全文")
            }
        }
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: toastText)
        .onAppear {
            LogManager.shared.info("helpGuide", "帮助详情页打开", context: [
                "articleId": article.id,
                "readingMinutes": "\(article.readingMinutes)",
                "stepCount": "\(article.steps.count)"
            ])
        }
        .onDisappear {
            // 面板内联搜索任务随页面销毁取消，避免写回已销毁视图状态
            inlineTask?.cancel()
        }
    }

    // MARK: 头部

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: article.icon)
                            .displaySymbolFont(24, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .shadow(color: accent.opacity(0.32), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 4) {
                    if let category {
                        Text(category.title)
                            .displayFont(11, weight: .semibold)
                            .foregroundStyle(accent)
                    }
                    readingMetaRow
                }
            }

            Text(article.title)
                .displayFont(22, weight: .bold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(article.summary)
                .displayFont(13)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    private var readingMetaRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .displaySymbolFont(9, weight: .semibold)
            Text("约 \(article.readingMinutes) 分钟")
                .displayFont(11, weight: .medium)
        }
        .foregroundStyle(readingTierColorForArticle)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(readingTierColorForArticle.opacity(0.12)))
    }

    private var readingTierColorForArticle: Color {
        switch article.readingMinutes {
        case ...4: return .sjzGreen
        case 5...9: return .sjzAccent
        case 10...19: return .sjzOrange
        default: return .sjzPurple
        }
    }

    // MARK: 标签

    private var tagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(article.tags, id: \.self) { tag in
                    Text("# \(tag)")
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.1)))
                }
            }
        }
    }

    // MARK: 步骤

    private var stepsSection: some View {
        VStack(spacing: 13) {
            ForEach(Array(article.steps.enumerated()), id: \.element.id) { index, step in
                stepCard(index: index, step: step)
            }
        }
    }

    private func stepCard(index: Int, step: HelpStep) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Text("\(index + 1)")
                    .displayFont(14, weight: .bold)
                    .foregroundStyle(.white)
            }
            .shadow(color: accent.opacity(0.28), radius: 5, y: 2)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .displayFont(16, weight: .bold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.text)
                    .displayFont(13)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : .white)
        )
        .shadow(color: .black.opacity(0.04), radius: 9, y: 4)
    }

    // MARK: 反馈与三招行动面板

    /// 反馈区主结构：
    /// · 未表态 → 两个问题按钮；
    /// · 已点「有帮助」→ 继续学习引导（推荐同分类下一篇，学完点亮下一段旅程）；
    /// · 点「没帮助」→ 展开三招行动面板（每条都是真实可用的出路，而非仅记录）。
    @ViewBuilder
    private var feedbackArea: some View {
        if helpedState == true {
            helpedNextSection
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("这篇解决你的问题了吗？")
                    .displayFont(14, weight: .semibold)
                    .foregroundStyle(.primary)
                HStack(spacing: 10) {
                    helpedButton
                    notHelpedButton
                }
                if showHelpPanel {
                    actionPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(15)
            .background(feedbackCardBackground)
            .shadow(color: .black.opacity(0.04), radius: 9, y: 4)
        }
    }

    private var feedbackCardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : .white)
    }

    private var helpedButton: some View {
        Button {
            markHelpful()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "hand.thumbsup.fill")
                    .displaySymbolFont(13, weight: .semibold)
                Text("有帮助")
                    .displayFont(13, weight: .semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.sjzGreen))
            .shadow(color: Color.sjzGreen.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var notHelpedButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showHelpPanel.toggle()
            }
            if showHelpPanel {
                LogManager.shared.info("helpGuide", "反馈行动面板展开（没帮助）", context: [
                    "articleId": article.id
                ])
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: showHelpPanel ? "xmark" : "hand.thumbsdown.fill")
                    .displaySymbolFont(13, weight: .semibold)
                Text(showHelpPanel ? "收起" : "没帮助")
                    .displayFont(13, weight: .semibold)
            }
            .foregroundStyle(Color.sjzOrange)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.sjzOrange.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func markHelpful() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            helpedState = true
        }
        LogManager.shared.info("helpGuide", "帮助反馈：有帮助", context: [
            "articleId": article.id,
            "title": article.title
        ])
    }

    /// 「有帮助」后的真实闭环：
/// · 已读状态真实写入本地学习进度（数据在「最近阅读/已读统计」中可见）；
/// · 展示当前分类进度（真实计数）；
/// · 推荐同分类下一篇（真实可用的下一步）。
/// 注意：本 App 无后端不上传，因此绝不用「已收到反馈」这类承诺送达的文案。
private var helpedNextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .displaySymbolFont(15, weight: .semibold)
                    .foregroundStyle(Color.sjzGreen)
                Text("本文已记入学习进度，谢谢！")
                    .displayFont(14, weight: .semibold)
                    .foregroundStyle(.primary)
            }

            // 真实进度：本分类已读/总数
            if let category {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .displaySymbolFont(10, weight: .semibold)
                    Text("本分类进度 \(store.readCount(in: category.id))/\(store.articleCount(in: category.id))")
                        .displayFont(11, weight: .semibold)
                }
                .foregroundStyle(Color.sjzGreen)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.sjzGreen.opacity(0.1)))
            }

            if let next = store.nextArticle(after: article) {
                Button {
                    switchTo(next, source: "helpfulNext")
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "arrow.right.circle.fill")
                            .displaySymbolFont(26, weight: .semibold)
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("继续学下一篇")
                                .displayFont(11, weight: .semibold)
                                .foregroundStyle(accent)
                            Text(next.title)
                                .displayFont(13.5, weight: .semibold)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .displaySymbolFont(10, weight: .medium)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent.opacity(0.09))
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } else {
                Text("本分类已全部读完——去「全部」逛逛其他分类，或点上方搜索继续探索")
                    .displayFont(12)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
        .padding(15)
        .background(feedbackCardBackground)
        .shadow(color: .black.opacity(0.04), radius: 9, y: 4)
    }

    /// 三招行动面板：每一招都导向一个真实可用的下一步
    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            // 第一招：就地搜索，换关键词立刻找答案
            VStack(alignment: .leading, spacing: 9) {
                actionTitle("第一招", "换个关键词，就地搜到答案")
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .displaySymbolFont(11, weight: .semibold)
                            .foregroundStyle(.secondary)
                        TextField("在全部帮助中搜索…", text: $inlineKeyword)
                            .displayFont(12)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .onChange(of: inlineKeyword) { _, newValue in
                                runInlineSearch(newValue)
                            }
                        if !inlineKeyword.isEmpty {
                            Button {
                                inlineKeyword = ""
                                withAnimation(.easeInOut(duration: 0.18)) { inlineHits = [] }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .displaySymbolFont(12)
                                    .foregroundStyle(.tertiary)
                            }
                            .accessibilityLabel("清空搜索")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
                    )
                }
                if !inlineHits.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(inlineHits) { hit in
                            inlineHitRow(hit.article)
                        }
                    }
                }
            }

            // 第二招：换一篇相关的继续探索
            VStack(alignment: .leading, spacing: 9) {
                actionTitle("第二招", "换一篇相关的继续探索")
                if related.isEmpty {
                    Text("暂无相关文章，试试第一招搜索")
                        .displayFont(12)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(related) { item in
                                quickRelatedChip(item)
                            }
                        }
                    }
                }
            }

            // 第三招：反馈卡——真实闭环出口（复制/分享给开发者）
            VStack(alignment: .leading, spacing: 9) {
                actionTitle("第三招", "把问题带给开发者")
                Text("生成一张反馈卡发给开发者，卡片自带文章定位信息，最快得到解答")
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                HStack(spacing: 10) {
                    Button {
                        copyFeedbackCard()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc.fill")
                                .displaySymbolFont(12, weight: .semibold)
                            Text("复制反馈卡")
                                .displayFont(12, weight: .semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    ShareLink(item: feedbackCardText) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .displaySymbolFont(12, weight: .semibold)
                            Text("分享反馈卡")
                                .displayFont(12, weight: .semibold)
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        LogManager.shared.info("helpGuide", "帮助反馈卡分享触发", context: [
                            "articleId": article.id
                        ])
                    })
                }
            }
        }
    }

    private func actionTitle(_ no: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Text(no)
                .displayFont(10, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(accent))
            Text(text)
                .displayFont(13, weight: .semibold)
                .foregroundStyle(.primary)
        }
    }

    /// 面板内联搜索：350ms 防抖，排除当前文章，最多 5 条
    private func runInlineSearch(_ newValue: String) {
        inlineTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.easeInOut(duration: 0.18)) { inlineHits = [] }
            return
        }
        inlineTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let hits = store.search(trimmed).filter { $0.article.id != article.id }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                inlineHits = Array(hits.prefix(5))
            }
            LogManager.shared.debugLog("helpGuide", "帮助内联搜索完成", context: [
                "keyword": trimmed,
                "hitCount": "\(hits.count)"
            ])
        }
    }

    /// 内联搜索结果行：紧凑样式，点击原地切换
    private func inlineHitRow(_ item: HelpArticle) -> some View {
        Button {
            switchTo(item, source: "inlineSearch")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .displaySymbolFont(11, weight: .semibold)
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(accent.opacity(0.12)))
                Text(item.title)
                    .displayFont(12, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .displaySymbolFont(9, weight: .medium)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// 相关文章快捷胶囊（面板内第二招）
    private func quickRelatedChip(_ item: HelpArticle) -> some View {
        Button {
            switchTo(item, source: "panelRelated")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .displaySymbolFont(10, weight: .semibold)
                Text(item.title)
                    .displayFont(11, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(accent.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// 反馈卡内容：自带文章定位与设备信息，开发者拿到即可定位
    private var feedbackCardText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return """
        【使用帮助反馈】园枢 v\(version)
        文章：《\(article.title)》（ID: \(article.id)）
        问题类型：内容未能解决我的疑问
        问题描述：

        设备：\(system)
        时间：\(Date().formatted(date: .numeric, time: .shortened))
        """
    }

    private func copyFeedbackCard() {
        UIPasteboard.general.string = feedbackCardText
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        showToast("反馈卡已复制，粘贴到聊天或邮件即可发送")
        LogManager.shared.info("helpGuide", "帮助反馈卡已复制", context: [
            "articleId": article.id
        ])
    }

    /// 统一的原地文章切换（相关阅读 / 内联搜索 / 继续学习共用）：重置反馈态并滚动回顶
    private func switchTo(_ newArticle: HelpArticle, source: String) {
        let fromId = article.id
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            article = newArticle
            helpedState = nil
            showHelpPanel = false
            inlineKeyword = ""
            inlineHits = []
        }
        store.recordOpen(newArticle)
        LogManager.shared.info("helpGuide", "帮助文章跳转", context: [
            "from": fromId,
            "to": newArticle.id,
            "source": source
        ])
    }

    /// 通用状态提示
    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            toastText = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                toastText = nil
            }
        }
    }

    // MARK: 相关文章

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundStyle(accent)
                Text("相关阅读")
                    .displayFont(16, weight: .bold)
            }

            VStack(spacing: 9) {
                ForEach(related) { item in
                    relatedRow(item)
                }
            }
        }
    }

    private func relatedRow(_ item: HelpArticle) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.icon)
                .displaySymbolFont(14, weight: .semibold)
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(accent.opacity(0.12)))
            Text(item.title)
                .displayFont(13, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .displaySymbolFont(9, weight: .medium)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : .white)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            switchTo(item, source: "related")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            switchTo(item, source: "related")
        }
    }

    // MARK: 脚注

    private var footerNote: some View {
        Text("内容基于当前版本「园枢 1.0」编写，随 App 更新持续修订。")
            .displayFont(11)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
    }

    // MARK: 复制

    private func copyFullText() {
        UIPasteboard.general.string = fullText
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        showToast("已复制全文")
        LogManager.shared.info("helpGuide", "帮助文章复制全文", context: [
            "articleId": article.id,
            "charCount": "\(fullText.count)"
        ])
    }
}