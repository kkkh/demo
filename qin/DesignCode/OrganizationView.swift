//
//  OrganizationView.swift
//  山西晋中理工学院 APP — 机构设置模块
//
//  展示学校完整组织架构，按类别分组。
//  数据来源于 OrganizationManager（静态数据 + head API 动态 site_key）。
//  支持浅色/深色模式，完全独立模块。
//  支持高级搜索（分类筛选、排序、关键词高亮）、下拉刷新、刷新反馈。
//

import SwiftUI

// MARK: - 排序方式

enum OrganizationSortOrder: String, CaseIterable, Identifiable {
    case defaultOrder = "默认排序"
    case nameAsc = "名称 A-Z"
    case nameDesc = "名称 Z-A"
    case categoryOrder = "按分类"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .defaultOrder: return "list.bullet"
        case .nameAsc: return "textformat.abc"
        case .nameDesc: return "textformat.abc.dottedunderline"
        case .categoryOrder: return "rectangle.3.group"
        }
    }
}

// MARK: - 搜索模式

enum OrganizationSearchMode: String, CaseIterable, Identifiable {
    case organization = "机构"
    case article = "文章"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .organization: return "building.2"
        case .article: return "doc.text.magnifyingglass"
        }
    }

    var placeholder: String {
        switch self {
        case .organization: return "搜索机构名称、分类..."
        case .article: return "搜索文章标题、内容..."
        }
    }
}

// MARK: - 文章搜索结果模型

struct ArticleSearchResult: Identifiable {
    let id: String
    let articleId: String
    let title: String
    let description: String
    let tag: String
    let updateTime: String
    let imageUrl: String?
    let siteId: String
    let columnName: String
    /// 机构名（机构子站文章标识；主站文章为空字符串）
    let orgName: String
    /// 搜索相关性得分（标题匹配权重更高）
    let relevanceScore: Float
}

// MARK: - 搜索范围筛选

enum ArticleSearchScope: String, CaseIterable, Identifiable {
    case all = "全部栏目"
    case keyNews = "要闻"
    case information = "资讯"
    case partyBuilding = "党建"
    case notice = "通知"

    var id: String { rawValue }
}

// MARK: - 排序方式（文章搜索）

enum ArticleSearchSortOrder: String, CaseIterable, Identifiable {
    case relevance = "按相关度"
    case dateDesc = "按时间降序"
    case dateAsc = "按时间升序"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .relevance: return "target"
        case .dateDesc: return "arrow.down"
        case .dateAsc: return "arrow.up"
        }
    }
}

// MARK: - 机构设置主页

struct OrganizationView: View {
    @ObservedObject private var manager = OrganizationManager.shared
    @Environment(\.colorScheme) private var colorScheme

    // 搜索模式
    @State private var searchMode: OrganizationSearchMode = .organization

    // 搜索
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    // 分类筛选（nil 表示全部）
    @State private var selectedCategory: OrganizationCategory? = nil

    /// 搜索范围（与 searchScopes 配合使用）
    @State private var selectedCategoryScope: OrganizationCategory? = nil

    // 排序
    @State private var sortOrder: OrganizationSortOrder = .defaultOrder

    // 刷新反馈
    @State private var showRefreshToast: Bool = false
    @State private var refreshToastMessage: String = ""
    @State private var refreshToastSuccess: Bool = true

    // 文章搜索
    @State private var articleSearchResults: [ArticleSearchResult] = []
    @State private var isArticleSearching = false
    @State private var articleSearchError: String?
    @State private var articleSearchTask: Task<Void, Never>?
    /// 机构子站检索进度描述（搜索中直观状态提示；nil 表示无进行中检索）
    @State private var orgSearchProgress: String?
    /// 文章搜索导航
    @State private var articleSearchNavigation: ArticleSearchNavigation?
    /// 搜索范围筛选
    @State private var articleSearchScope: ArticleSearchScope = .all
    /// 搜索结果排序
    @State private var articleSearchSortOrder: ArticleSearchSortOrder = .relevance
    /// 搜索历史（最多保留10条，持久化到 UserDefaults）
    @State private var searchHistory: [String] = UserDefaults.standard.stringArray(forKey: "orgArticleSearchHistory") ?? []
    /// 是否显示搜索历史
    @State private var showSearchHistory: Bool = false

    /// 文章搜索导航包装
    struct ArticleSearchNavigation: Identifiable {
        let id: String
        let article: OrgArticle
        let siteId: String
    }

    // MARK: 数据计算

    /// 屏幕高度（替代已废弃的 UIScreen.main.bounds.height）
    private var screenHeight: CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return 0 }
        return scene.screen.bounds.height
    }

    /// 搜索文本（去除首尾空格）
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// 是否正在搜索
    private var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    /// 是否正在筛选分类
    private var isFiltering: Bool {
        selectedCategory != nil
    }

    /// 筛选后的机构列表
    private var filteredDepartments: [OrganizationUnit] {
        var result = manager.departments

        // 分类筛选
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }

        // 搜索筛选
        if isSearching {
            let lower = trimmedSearchText.lowercased()
            result = result.filter { unit in
                unit.name.lowercased().contains(lower) ||
                unit.category.rawValue.lowercased().contains(lower)
            }
        }

        // 排序
        switch sortOrder {
        case .defaultOrder:
            break // 保持原有顺序（按分类排序）
        case .nameAsc:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDesc:
            result.sort { $0.name.localizedCompare($1.name) == .orderedDescending }
        case .categoryOrder:
            result.sort {
                if $0.category.sortOrder != $1.category.sortOrder {
                    return $0.category.sortOrder < $1.category.sortOrder
                }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        }

        return result
    }

    /// 分组后的数据
    private var filteredGroupedData: [(OrganizationCategory, [OrganizationUnit])] {
        if sortOrder == .nameAsc || sortOrder == .nameDesc {
            // 名称排序时不分组，统一显示
            let allCategory = OrganizationCategory.partyCommittee
            return filteredDepartments.isEmpty ? [] : [(allCategory, filteredDepartments)]
        }

        return OrganizationCategory.allCases.compactMap { category in
            let units = filteredDepartments.filter { $0.category == category }
            return units.isEmpty ? nil : (category, units)
        }
    }

    /// 当前显示的名称排序模式
    private var isNameSorted: Bool {
        sortOrder == .nameAsc || sortOrder == .nameDesc
    }

    var body: some View {
        ZStack {
            Group {
                if manager.departments.isEmpty && manager.isLoading {
                    loadingView
                } else {
                    contentView
                }
            }
            .background(GradientBackground())

            // 刷新反馈 Toast
            if showRefreshToast {
                refreshToastView
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .navigationTitle("机构设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    // 排序按钮
                    sortMenu
                    // 刷新按钮
                    refreshButton
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchMode.placeholder
        )
        .searchScopes($selectedCategoryScope) {
            if searchMode == .organization {
                Text("全部").tag(nil as OrganizationCategory?)
                ForEach(OrganizationCategory.allCases) { category in
                    Text(category.rawValue)
                        .tag(category as OrganizationCategory?)
                }
            }
        }
        .onAppear {
            LogManager.shared.info("organization", "机构设置页面打开", context: [
                "count": "\(manager.totalCount)",
                "source": manager.dataSource,
                "detailPages": "\(manager.detailPageCount)"
            ])
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if searchMode == .organization {
                if !trimmed.isEmpty {
                    LogManager.shared.debugLog("organization", "机构搜索", context: [
                        "keyword": trimmed,
                        "resultCount": "\(filteredDepartments.count)"
                    ])
                }
            } else {
                // 文章搜索：防抖 500ms 后执行搜索
                articleSearchTask?.cancel()
                if trimmed.isEmpty {
                    articleSearchResults = []
                    articleSearchError = nil
                    isArticleSearching = false
                } else {
                    isArticleSearching = true
                    articleSearchError = nil
                    let keyword = trimmed
                    articleSearchTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        await performArticleSearch(keyword: keyword)
                    }
                }
            }
        }
        .onChange(of: searchMode) { _, newMode in
            // 切换搜索模式时清空搜索状态
            searchText = ""
            articleSearchResults = []
            articleSearchError = nil
            isArticleSearching = false
            articleSearchTask?.cancel()
            LogManager.shared.info("organization", "搜索模式切换", context: [
                "mode": newMode.rawValue
            ])
        }
        .onChange(of: selectedCategory) { _, newValue in
            if let cat = newValue {
                LogManager.shared.debugLog("organization", "分类筛选", context: [
                    "category": cat.rawValue,
                    "resultCount": "\(filteredDepartments.count)"
                ])
            } else {
                LogManager.shared.debugLog("organization", "分类筛选：全部")
            }
            // 同步搜索范围
            if selectedCategoryScope != newValue {
                selectedCategoryScope = newValue
            }
        }
        .onChange(of: selectedCategoryScope) { _, newValue in
            // 同步分类筛选
            if selectedCategory != newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedCategory = newValue
                }
            }
        }
        .onChange(of: sortOrder) { _, newValue in
            LogManager.shared.debugLog("organization", "排序切换", context: [
                "order": newValue.rawValue
            ])
        }
        .sheet(item: $articleSearchNavigation) { nav in
            NavigationStack {
                OrganizationArticleDetailView(
                    article: nav.article,
                    siteId: nav.siteId,
                    color: Color.sjzAccent
                )
            }
            .sjzPresentationChrome()
        }
    }

    // MARK: 刷新反馈 Toast

    private var refreshToastView: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: refreshToastSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .displaySymbolFont(14)
                    .foregroundStyle(refreshToastSuccess ? Color.green : Color.sjzOrange)
                Text(refreshToastMessage)
                    .displayFont(13, weight: .medium)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            )
            .padding(.top, 8)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.3), value: showRefreshToast)
    }

    // MARK: 加载视图

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)
            Text("加载机构数据中...")
                .displayFont(15)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 内容视图

    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // 搜索模式切换
                searchModePicker

                // 文章搜索模式：显示搜索结果
                if searchMode == .article && isSearching {
                    articleSearchResultsView
                } else if searchMode == .article && !isSearching && !searchHistory.isEmpty {
                    // 文章搜索模式：显示搜索历史
                    searchHistoryView
                } else {
                    // 机构搜索模式：显示机构列表
                    // 搜索/筛选状态栏
                    if isSearching || isFiltering {
                        searchStatusBar
                    }

                    // 分类筛选芯片
                    categoryFilterChips

                    // 数据来源指示器
                    dataSourceIndicator

                    // 排序状态提示
                    if isNameSorted && !filteredDepartments.isEmpty {
                        nameSortIndicator
                    }

                    // 分类区块
                    if filteredGroupedData.isEmpty && isSearching {
                        emptySearchResult
                    } else if filteredGroupedData.isEmpty && isFiltering {
                        emptyFilterResult
                    } else {
                        ForEach(filteredGroupedData, id: \.0.id) { category, units in
                            categorySection(category: category, units: units)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .frame(minHeight: screenHeight)
        }
        .scrollBounceBehavior(.always)
        .refreshable {
            await performRefresh(source: "下拉刷新")
        }
    }

    // MARK: 搜索/筛选状态栏

    private var searchStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(12)
                .foregroundStyle(.secondary)

            if isSearching {
                Text("搜索「\(trimmedSearchText)」")
                    .displayFont(13, weight: .medium)
                    .foregroundStyle(.secondary)
            }

            if isFiltering, let cat = selectedCategory {
                if isSearching {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .displayFont(10)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(cat.color)
                        .frame(width: 6, height: 6)
                    Text(cat.rawValue)
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(cat.color)
                }
            }

            Spacer()

            // 结果计数
            Text("\(filteredDepartments.count) 个结果")
                .displayFont(12)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )

            // 清除筛选
            if isSearching || isFiltering {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        searchText = ""
                        selectedCategory = nil
                        sortOrder = .defaultOrder
                    }
                    LogManager.shared.debugLog("organization", "清除筛选条件")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(14)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 分类筛选芯片

    private var categoryFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "全部" 芯片
                filterChip(
                    label: "全部",
                    icon: "square.grid.2x2",
                    color: Color.sjzAccent,
                    isSelected: selectedCategory == nil
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedCategory = nil
                    }
                }

                // 各分类芯片
                ForEach(OrganizationCategory.allCases) { category in
                    let count = manager.departments.filter { $0.category == category }.count
                    filterChip(
                        label: category.rawValue,
                        icon: category.icon,
                        color: category.color,
                        badge: "\(count)",
                        isSelected: selectedCategory == category
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedCategory = (selectedCategory == category) ? nil : category
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 单个筛选芯片
    private func filterChip(
        label: String,
        icon: String,
        color: Color,
        badge: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .displaySymbolFont(11, weight: .medium)
                Text(label)
                    .displayFont(12, weight: .medium)
                if let badge = badge {
                    Text(badge)
                        .displayFont(10, weight: .semibold)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? .white.opacity(0.2) : color.opacity(0.1))
                        )
                }
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? color : color.opacity(colorScheme == .dark ? 0.12 : 0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? color : color.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: 排序菜单

    private var sortMenu: some View {
        Menu {
            ForEach(OrganizationSortOrder.allCases) { order in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sortOrder = order
                    }
                } label: {
                    Label(order.rawValue, systemImage: order.icon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .displaySymbolFont(14, weight: .medium)
                .foregroundStyle(sortOrder != .defaultOrder ? Color.sjzAccent : .primary)
        }
        .contentShape(Rectangle())
    }

    // MARK: 名称排序提示

    private var nameSortIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: sortOrder.icon)
                .displaySymbolFont(11)
                .foregroundStyle(.secondary)
            Text("按\(sortOrder.rawValue)排列")
                .displayFont(11)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(filteredDepartments.count) 个机构")
                .displayFont(11)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
    }

    // MARK: 空搜索结果

    private var emptySearchResult: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .displaySymbolFont(40)
                .foregroundStyle(.tertiary)
            Text("未找到匹配「\(trimmedSearchText)」的机构")
                .displayFont(15)
                .foregroundStyle(.secondary)
            Text("请尝试其他关键词或调整筛选条件")
                .displayFont(13)
                .foregroundStyle(.tertiary)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    searchText = ""
                    selectedCategory = nil
                }
                LogManager.shared.debugLog("organization", "搜索无结果，清除条件")
            } label: {
                Text("清除筛选")
                    .displayFont(13, weight: .medium)
                    .foregroundStyle(Color.sjzAccent)
            }
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// 空筛选结果
    private var emptyFilterResult: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .displaySymbolFont(40)
                .foregroundStyle(.tertiary)
            if let cat = selectedCategory {
                Text("「\(cat.rawValue)」分类下暂无机构")
                    .displayFont(15)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedCategory = nil
                }
                LogManager.shared.debugLog("organization", "筛选无结果，重置分类")
            } label: {
                Text("显示全部")
                    .displayFont(13, weight: .medium)
                    .foregroundStyle(Color.sjzAccent)
            }
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: 刷新按钮

    private var refreshButton: some View {
        Button {
            Task {
                await performRefresh(source: "按钮刷新")
            }
        } label: {
            if manager.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
                    .displaySymbolFont(14, weight: .medium)
            }
        }
        .disabled(manager.isLoading)
        .contentShape(Rectangle())
    }

    // MARK: 刷新逻辑

    private func performRefresh(source: String) async {
        LogManager.shared.info("organization", "刷新触发", context: [
            "source": source,
            "currentSource": manager.dataSource
        ])

        let beforeCount = manager.detailPageCount

        await manager.refresh()

        // 刷新完成后显示反馈
        let afterCount = manager.detailPageCount
        let afterSource = manager.dataSource

        if let error = manager.errorMessage {
            refreshToastMessage = error
            refreshToastSuccess = false
            LogManager.shared.warning("organization", "刷新失败反馈", context: [
                "source": source,
                "error": error
            ])
        } else if afterSource == "服务器" {
            refreshToastMessage = "数据已同步（\(afterCount)个详情页）"
            refreshToastSuccess = true
            LogManager.shared.info("organization", "刷新成功反馈", context: [
                "source": source,
                "detailPages": "\(afterCount)",
                "beforePages": "\(beforeCount)"
            ])
        } else {
            refreshToastMessage = "数据已刷新（使用\(afterSource)）"
            refreshToastSuccess = true
        }

        // 显示 Toast
        withAnimation(.easeInOut(duration: 0.3)) {
            showRefreshToast = true
        }

        // 2.5 秒后自动隐藏
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRefreshToast = false
                }
            }
        }
    }

    // MARK: 数据来源指示器

    private var dataSourceIndicator: some View {
        HStack(spacing: 6) {
            // 状态指示器
            if manager.isLoading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(dataSourceColor)
                    .frame(width: 6, height: 6)
            }

            Text(dataSourceText)
                .displayFont(11)
                .foregroundStyle(.secondary)

            if let time = manager.lastFetchTime {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(time.formatted(.relative(presentation: .numeric)))
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
            }

            if let error = manager.errorMessage {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .displaySymbolFont(10)
                    .foregroundStyle(Color.sjzOrange)
                Text(error)
                    .displayFont(10)
                    .foregroundStyle(Color.sjzOrange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }

    /// 数据源状态颜色
    private var dataSourceColor: Color {
        if manager.dataSource.contains("服务器") {
            return .green
        }
        return Color.sjzOrange
    }

    /// 数据源状态文本
    private var dataSourceText: String {
        if manager.dataSource.contains("服务器") {
            if manager.dataSource.contains("空菜单") {
                return "已同步（菜单为空）"
            }
            return "已同步官网数据"
        }
        return "使用预置数据"
    }

    // MARK: 分类区块

    private func categorySection(category: OrganizationCategory, units: [OrganizationUnit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 分类标题（名称排序时简化显示）
            if !isNameSorted {
                categoryHeader(category: category, count: units.count)
            }

            // 机构卡片网格
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(units) { unit in
                    unitCard(unit, color: category.color)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 分类标题

    private func categoryHeader(category: OrganizationCategory, count: Int) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(category.color.opacity(colorScheme == .dark ? 0.2 : 0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: category.icon)
                    .displaySymbolFont(16, weight: .semibold)
                    .foregroundStyle(category.color)
            }

            Text(category.rawValue)
                .displayFont(17, weight: .bold)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(count) 个")
                .displayFont(12, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
        }
        .padding(.horizontal, 16)
    }

    // MARK: 机构卡片

    private func unitCard(_ unit: OrganizationUnit, color: Color) -> some View {
        NavigationLink {
            OrganizationDetailView(unit: unit)
        } label: {
            cardContent(unit, color: color)
        }
        .buttonStyle(OrganizationCardButtonStyle())
    }

    private func cardContent(_ unit: OrganizationUnit, color: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: unit.icon)
                    .displaySymbolFont(14, weight: .medium)
                    .foregroundStyle(color)
            }

            // 名称（支持搜索高亮）
            if isSearching {
                highlightedText(unit.name, keyword: trimmedSearchText)
                    .displayFont(13, weight: .medium)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(unit.name)
                    .displayFont(13, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .displaySymbolFont(10, weight: .semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(colorScheme == .dark ? 0.15 : 0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.15 : 0.04), radius: 8, y: 4)
        .contentShape(Rectangle())
    }

    // MARK: 搜索高亮文本

    /// 构建高亮 AttributedString（非 ViewBuilder，避免赋值语句返回值问题）
    private func buildHighlightedAttributedString(_ text: String, keyword: String) -> AttributedString {
        guard let range = text.range(of: keyword, options: .caseInsensitive) else {
            return AttributedString(text)
        }
        let before = String(text[text.startIndex..<range.lowerBound])
        let match = String(text[range])
        let after = String(text[range.upperBound..<text.endIndex])

        var result = AttributedString("")
        if !before.isEmpty {
            var beforeAttr = AttributedString(before)
            beforeAttr.foregroundColor = .primary
            result.append(beforeAttr)
        }
        var matchAttr = AttributedString(match)
        matchAttr.foregroundColor = .primary
        matchAttr.font = .system(size: 14, weight: .bold)
        result.append(matchAttr)
        if !after.isEmpty {
            var afterAttr = AttributedString(after)
            afterAttr.foregroundColor = .primary
            result.append(afterAttr)
        }
        return result
    }

    /// 在文本中高亮显示匹配的关键词
    @ViewBuilder
    private func highlightedText(_ text: String, keyword: String) -> some View {
        let lowerText = text.lowercased()
        let lowerKeyword = keyword.lowercased()

        if lowerKeyword.isEmpty || !lowerText.contains(lowerKeyword) {
            Text(text)
                .foregroundStyle(.primary)
        } else {
            let result = buildHighlightedAttributedString(text, keyword: keyword)
            Text(result)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.yellow.opacity(0.25))
                        .padding(.horizontal, -2)
                        .padding(.vertical, -1)
                )
        }
    }
}

// MARK: - 文章搜索

extension OrganizationView {

    // MARK: 搜索模式切换器

    private var searchModePicker: some View {
        HStack(spacing: 0) {
            ForEach(OrganizationSearchMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchMode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .displaySymbolFont(12, weight: .medium)
                        Text(mode.rawValue)
                            .displayFont(13, weight: .medium)
                    }
                    .foregroundStyle(searchMode == mode ? .white : .secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(searchMode == mode ? Color.sjzAccent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 16)
    }

    // MARK: 搜索历史视图

    /// 文章搜索历史记录
    private var searchHistoryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .displaySymbolFont(13)
                        .foregroundStyle(.secondary)
                    Text("搜索历史")
                        .displayFont(14, weight: .semibold)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchHistory.removeAll()
                        UserDefaults.standard.removeObject(forKey: "orgArticleSearchHistory")
                    }
                    LogManager.shared.info("organization", "搜索历史已清空")
                } label: {
                    Image(systemName: "trash")
                        .displaySymbolFont(12)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 16)

            // 搜索历史标签流
            let rows = generateHistoryRows()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { term in
                        Button {
                            searchText = term
                            isArticleSearching = true
                            articleSearchError = nil
                            let keyword = term
                            articleSearchTask = Task {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                guard !Task.isCancelled else { return }
                                await performArticleSearch(keyword: keyword)
                            }
                            LogManager.shared.info("organization", "搜索历史点击", context: [
                                "keyword": term
                            ])
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                    .displaySymbolFont(10)
                                Text(term)
                                    .displayFont(13)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(.horizontal, 16)

            // 搜索提示
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .displaySymbolFont(11)
                    .foregroundStyle(Color.sjzOrange)
                Text("输入关键词，检索全校主站栏目与全部机构子站的文章标题、内容")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    // MARK: 文章搜索结果视图

    private var articleSearchResultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 机构子站检索进度（流式检索全程直观可见：已检/总量 + 实时命中数）
            if let progress = orgSearchProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(Color.sjzTeal)
                    Text(progress)
                        .displayFont(11, weight: .medium)
                        .foregroundStyle(Color.sjzTeal)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.sjzTeal.opacity(0.1))
                )
                .overlay(Capsule().stroke(Color.sjzTeal.opacity(0.25), lineWidth: 0.5))
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 搜索状态栏
            HStack(spacing: 8) {
                if isArticleSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("搜索中...")
                        .displayFont(13)
                        .foregroundStyle(.secondary)
                } else if let error = articleSearchError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(Color.sjzOrange)
                    Text(error)
                        .displayFont(13)
                        .foregroundStyle(Color.sjzOrange)
                } else {
                    Image(systemName: "magnifyingglass")
                        .displaySymbolFont(12)
                        .foregroundStyle(.secondary)
                    Text("搜索「\(trimmedSearchText)」")
                        .displayFont(13, weight: .medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // 搜索结果计数 + 排序
                    Menu {
                        ForEach(ArticleSearchSortOrder.allCases) { order in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    articleSearchSortOrder = order
                                }
                            } label: {
                                Label(order.rawValue, systemImage: order.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: articleSearchSortOrder.icon)
                                .displaySymbolFont(10)
                            Text("\(articleSearchResults.count) 个结果")
                                .displayFont(12)
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)

            // 搜索范围筛选芯片
            if !isArticleSearching && articleSearchError == nil && !articleSearchResults.isEmpty {
                searchScopeChips
            }

            if !isArticleSearching && articleSearchError == nil && articleSearchResults.isEmpty {
                // 空结果
                searchEmptyResultView
            } else if !isArticleSearching && articleSearchError == nil {
                // 搜索结果列表
                LazyVStack(spacing: 10) {
                    ForEach(sortedAndFilteredResults) { result in
                        articleSearchResultCard(result)
                    }
                }
                .padding(.horizontal, 16)

                // 深度检索入口（有结果时同样提供：全部栏目 × 8 页，覆盖更早文章，追求 100% 覆盖）
                if !articleSearchResults.isEmpty {
                    Button {
                        triggerDeepSearch()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .displaySymbolFont(10)
                            Text("还有更早的文章？深度检索全部栏目（每栏至多 400 条）")
                                .displayFont(11)
                        }
                        .foregroundStyle(Color.sjzTeal)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.sjzTeal.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// 筛选和排序后的搜索结果
    private var sortedAndFilteredResults: [ArticleSearchResult] {
        var results = articleSearchResults
        
        // 按搜索范围筛选
        if articleSearchScope != .all {
            results = results.filter { $0.columnName == articleSearchScope.rawValue }
        }
        
        // 按排序方式排序
        switch articleSearchSortOrder {
        case .relevance:
            results.sort { $0.relevanceScore > $1.relevanceScore }
        case .dateDesc:
            results.sort { $0.updateTime > $1.updateTime }
        case .dateAsc:
            results.sort { $0.updateTime < $1.updateTime }
        }
        
        return results
    }

    /// 搜索范围筛选芯片
    private var searchScopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ArticleSearchScope.allCases) { scope in
                    let count = scope == .all
                        ? articleSearchResults.count
                        : articleSearchResults.filter { $0.columnName == scope.rawValue }.count
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            articleSearchScope = scope
                        }
                        LogManager.shared.debugLog("organization", "文章搜索范围切换", context: [
                            "scope": scope.rawValue,
                            "count": "\(count)"
                        ])
                    } label: {
                        HStack(spacing: 4) {
                            Text(scope.rawValue)
                                .displayFont(12, weight: .medium)
                            if count > 0 {
                                Text("\(count)")
                                    .displayFont(10, weight: .semibold)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule()
                                            .fill(articleSearchScope == scope
                                                ? Color.white.opacity(0.3)
                                                : Color.sjzAccent.opacity(0.1))
                                    )
                            }
                        }
                        .foregroundStyle(articleSearchScope == scope ? .white : Color.sjzAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(articleSearchScope == scope
                                    ? Color.sjzAccent
                                    : Color.sjzAccent.opacity(colorScheme == .dark ? 0.12 : 0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 空搜索结果视图
    private var searchEmptyResultView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(40)
                .foregroundStyle(.tertiary)
            Text("未找到匹配「\(trimmedSearchText)」的文章")
                .displayFont(15)
                .foregroundStyle(.secondary)
            Text("请尝试其他关键词，或深度检索全部栏目更早的文章")
                .displayFont(13)
                .foregroundStyle(.tertiary)

            // 深度检索：扩大至每栏 400 条并跳过缓存，覆盖更早文章
            Button {
                triggerDeepSearch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .displaySymbolFont(11)
                    Text("深度检索更早文章")
                        .displayFont(12, weight: .semibold)
                }
                .foregroundStyle(Color.sjzTeal)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.sjzTeal.opacity(0.12)))
                .overlay(Capsule().stroke(Color.sjzTeal.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// 触发深度检索（每栏 8 页 400 条、跳过查询缓存；覆盖全部栏目更早文章）
    private func triggerDeepSearch() {
        LogManager.shared.info("organization", "深度检索已触发", context: [
            "keyword": trimmedSearchText
        ])
        articleSearchTask?.cancel()
        articleSearchTask = Task {
            isArticleSearching = true
            articleSearchResults = []
            articleSearchError = nil
            await performArticleSearch(keyword: trimmedSearchText, deep: true)
        }
    }

    /// 文章搜索结果卡片
    private func articleSearchResultCard(_ result: ArticleSearchResult) -> some View {
        Button {
            let article = OrgArticle(
                id: result.articleId,
                title: result.title,
                description: result.description,
                imageUrl: result.imageUrl,
                updateTime: result.updateTime,
                tag: result.tag,
                articleId: result.articleId,
                sectionSiteId: result.siteId
            )
            LogManager.shared.info("organization", "文章搜索结果点击", context: [
                "articleId": result.articleId,
                "title": result.title,
                "siteId": result.siteId,
                "columnName": result.columnName
            ])
            articleSearchNavigation = ArticleSearchNavigation(
                id: result.articleId,
                article: article,
                siteId: result.siteId
            )
        } label: {
            HStack(spacing: 12) {
                // 缩略图
                if let imageUrl = result.imageUrl, !imageUrl.isEmpty,
                   imageUrl != "https://www2.sxjzit.edu.cn:8082/images/no_picture.webp" {
                    SJZCachedImage(url: URL(string: imageUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            articleSearchPlaceholder
                        default:
                            articleSearchPlaceholder
                        }
                    }
                } else {
                    articleSearchPlaceholder
                }

                VStack(alignment: .leading, spacing: 6) {
                    // 标题（高亮关键词）
                    highlightedText(result.title, keyword: trimmedSearchText)
                        .displayFont(14, weight: .medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !result.description.isEmpty {
                        highlightedText(result.description, keyword: trimmedSearchText)
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        // 栏目来源标签（按栏目分色，与全 App 分类配色一致）
                        HStack(spacing: 4) {
                            Image(systemName: "newspaper")
                                .displaySymbolFont(9)
                            Text(result.columnName)
                                .displayFont(10)
                        }
                        .foregroundStyle(Self.searchColumnColor(result.columnName))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Self.searchColumnColor(result.columnName).opacity(0.1))
                        )

                        // 机构子站文章：机构名徽标（紫色胶囊，直观区分来源）
                        if !result.orgName.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "building.2.fill")
                                    .displaySymbolFont(8)
                                Text(result.orgName)
                                    .displayFont(10)
                            }
                            .foregroundStyle(Color.sjzPurple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.sjzPurple.opacity(0.1))
                            )
                        }

                        if !result.tag.isEmpty {
                            Text(result.tag)
                                .displayFont(10)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(.quaternary)
                                )
                        }

                        // 阅读时长徽标（全文口径优先，摘要估算兜底；无缩略图卡片保持行内，规范与缩略图角标一致）
                        ReadingTimeBadgeView(cachedID: result.articleId, summary: result.description)

                        Spacer()
                        Text(formatSearchDate(result.updateTime))
                            .displayFont(10)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .displaySymbolFont(10, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.sjzAccent.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.03), radius: 6, y: 3)
        }
        .buttonStyle(OrganizationCardButtonStyle())
        .contentShape(Rectangle())
    }

    private var articleSearchPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.sjzAccent.opacity(0.12))
                .frame(width: 56, height: 56)
            Image(systemName: "doc.text.image")
                .displaySymbolFont(18)
                .foregroundStyle(Color.sjzAccent.opacity(0.4))
        }
    }

    // MARK: 文章搜索逻辑（E13 搜索 query 缓存：线程安全，进程内有效，最多 20 条）

    private static let searchCacheLock = NSLock()
    private static var searchQueryCache: [String: (Date, [ArticleSearchResult])] = [:]

    private static func searchQueryCacheEntry(_ key: String) -> (Date, [ArticleSearchResult])? {
        searchCacheLock.lock(); defer { searchCacheLock.unlock() }
        return searchQueryCache[key]
    }

    private static func storeSearchQueryCache(key: String, results: [ArticleSearchResult]) {
        searchCacheLock.lock(); defer { searchCacheLock.unlock() }
        searchQueryCache[key] = (Date(), results)
        if searchQueryCache.count > 20 {
            if let firstKey = searchQueryCache.keys.first {
                searchQueryCache.removeValue(forKey: firstKey)
            }
        }
    }

    /// 栏目全名 → 作用域短名（筛选器 rawValue 对齐；未知栏目保留原名不丢数据）
    private static func shortSearchColumnName(_ name: String) -> String {
        switch name {
        case "学校要闻": return "要闻"
        case "新闻资讯": return "资讯"
        case "党建动态": return "党建"
        case "通知公告": return "通知"
        default: return name
        }
    }

    /// 栏目标签配色（与全 App 分类色一致：要闻红 / 资讯蓝 / 党建深红 / 通知橙）
    private static func searchColumnColor(_ shortName: String) -> Color {
        switch shortName {
        case "要闻": return Color.sjzRed
        case "资讯": return Color.sjzAccent
        case "党建": return Color(hex: "B71C1C")
        case "通知": return Color.sjzOrange
        default: return Color.sjzAccent
        }
    }

    /// 执行文章搜索 - 并行搜索主站全栏目 + 全部机构子站全部栏目，按关键词匹配，计算相关性得分
    /// - Parameter deep: 深度检索（常规每栏至多 4 页 200 条；deep 时扩至 8 页 400 条并跳过缓存）
    private func performArticleSearch(keyword: String, deep: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            articleSearchResults = []
            isArticleSearching = false
            return
        }
        // 深度检索前重置机构进度
        if deep { orgSearchProgress = nil }

        LogManager.shared.info("organization", "文章搜索开始", context: [
            "keyword": trimmed,
            "deep": "\(deep)"
        ])

        // E13 搜索 query 缓存：缓存模式下同关键词 10 分钟内直接复用结果，秒回（深度检索跳过缓存）
        if !deep,
           CacheModeManager.shared.isCacheEnabled,
           let cached = Self.searchQueryCacheEntry(trimmed),
           Date().timeIntervalSince(cached.0) < 600 {
            articleSearchResults = cached.1
            articleSearchError = nil
            isArticleSearching = false
            LogManager.shared.info("organization", "搜索缓存命中，秒回结果", context: [
                "keyword": trimmed,
                "count": "\(cached.1.count)",
                "cacheAge": String(format: "%.0fs", Date().timeIntervalSince(cached.0))
            ])
            return
        }

        // 解析搜索栏目 ID（双通道：最近同步缓存 → 现场 home2 实时解析；服务端栏目 ID 会变更，严禁硬编码）
        var columnIds = DataService.shared.articleSearchColumnEntries()
        let resolveStart = Date()
        if columnIds.isEmpty {
            let fresh = await DataService.shared.refreshNewsColumnIdsFromHome2()
            columnIds = DataService.shared.articleSearchColumnEntries()
            LogManager.shared.info("organization", "文章搜索栏目 ID 解析", context: [
                "channel": fresh ? "home2实时" : "缓存",
                "columns": "\(columnIds.map(\.0).joined(separator: ","))",
                "elapsedMs": "\(Int(Date().timeIntervalSince(resolveStart) * 1000))"
            ])
        }
        guard !columnIds.isEmpty else {
            articleSearchResults = []
            articleSearchError = "搜索服务暂不可用，请返回首页刷新数据后重试"
            isArticleSearching = false
            LogManager.shared.error("organization", "文章搜索栏目 ID 解析失败，搜索中止", context: ["keyword": trimmed])
            return
        }

        let startTime = Date()

        do {
            // 并行搜索多个栏目（栏目 ID 由 home2 动态解析，服务端变更自动跟随）
            let columns = try await withThrowingTaskGroup(
                of: (String, [NetworkService.ArticleDTO]).self
            ) { group in
                for (name, colId) in columnIds {
                    group.addTask {
                        var all: [NetworkService.ArticleDTO] = []
                        let maxPages = deep ? 8 : 4
                        do {
                            for page in 1...maxPages {
                                let result = try await NetworkService.shared.fetchArticles(
                                    columnId: colId,
                                    siteId: "1",
                                    page: page,
                                    size: 50
                                )
                                let list = result.articles?.list ?? []
                                all.append(contentsOf: list)
                                let total = result.articles?.total ?? 0
                                // 提前终止：本页空 / 已取满 / 首屏即不足一页
                                if list.isEmpty || all.count >= total || (page == 1 && all.count < 50) { break }
                            }
                            return (name, all)
                        } catch {
                            await MainActor.run {
                                LogManager.shared.debugLog("organization", "文章搜索栏目失败", context: [
                                    "columnId": colId, "name": name, "error": error.localizedDescription
                                ])
                            }
                            return (name, all)
                        }
                    }
                }
                var allArticles: [(String, NetworkService.ArticleDTO)] = []
                for try await (name, articles) in group {
                    for article in articles {
                        allArticles.append((name, article))
                    }
                }
                return allArticles
            }

            // 按关键词匹配标题和描述，计算相关性得分
            let lowerKeyword = trimmed.lowercased()
            let keywords = lowerKeyword.components(separatedBy: .whitespaces).filter { $0.count >= 2 }
            // 如果没有多关键词（单字搜索），使用整个关键词
            let searchTerms = keywords.isEmpty ? [lowerKeyword] : keywords

            let matched = columns.compactMap { (columnName, dto) -> ArticleSearchResult? in
                guard let id = dto.id, let title = dto.resolvedTitle, !title.isEmpty else { return nil }

                let lowerTitle = title.lowercased()
                let lowerDesc = (dto.description ?? "").lowercased()

                // 计算相关性得分：标题匹配权重更高（3倍），描述匹配权重较低（1倍）
                var score: Float = 0
                var titleMatched = false
                var descMatched = false

                for term in searchTerms {
                    if lowerTitle.contains(term) {
                        score += 3.0  // 标题匹配高权重
                        titleMatched = true
                        // 精确匹配额外加分
                        if lowerTitle == term {
                            score += 2.0
                        }
                        // 标题开头匹配额外加分
                        if lowerTitle.hasPrefix(term) {
                            score += 1.0
                        }
                    }
                    if lowerDesc.contains(term) {
                        score += 1.0  // 描述匹配低权重
                        descMatched = true
                    }
                }

                // 多关键词匹配额外加分
                let matchedTermCount = searchTerms.filter { term in
                    lowerTitle.contains(term) || lowerDesc.contains(term)
                }.count
                if matchedTermCount > 1 {
                    score += Float(matchedTermCount) * 0.5
                }

                guard titleMatched || descMatched else { return nil }

                return ArticleSearchResult(
                    id: id,
                    articleId: id,
                    title: title,
                    description: dto.description ?? "",
                    tag: dto.tag ?? "",
                    updateTime: dto.updateTime ?? "",
                    imageUrl: dto.imageUrl,
                    siteId: "1",
                    columnName: Self.shortSearchColumnName(columnName),
                    orgName: "",
                    relevanceScore: score
                )
            }

            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            articleSearchResults = matched
            articleSearchError = nil
            isArticleSearching = false

            LogManager.shared.info("organization", "主站文章搜索完成", context: [
                "keyword": trimmed,
                "primaryMatched": "\(matched.count)",
                "primaryElapsed": "\(elapsed)ms"
            ])

            // 机构子站频道：检索全部机构子站真实文章（分批并发、结果流式合入、进度实时可见）
            let orgMatched = await searchOrganizationArticles(keyword: trimmed, deep: deep)

            // E13：缓存本次搜索结果（主站 + 机构合并结果；缓存模式下同关键词 10 分钟内直接复用）
            Self.storeSearchQueryCache(key: trimmed, results: articleSearchResults)

            // 保存搜索历史（去重，最多10条）
            if !searchHistory.contains(trimmed) {
                searchHistory.insert(trimmed, at: 0)
                if searchHistory.count > 10 {
                    searchHistory = Array(searchHistory.prefix(10))
                }
                UserDefaults.standard.set(searchHistory, forKey: "orgArticleSearchHistory")
            }

            LogManager.shared.info("organization", "文章搜索完成", context: [
                "keyword": trimmed,
                "primaryMatched": "\(matched.count)",
                "orgMatched": "\(orgMatched)",
                "totalMatched": "\(articleSearchResults.count)",
                "totalElapsed": "\(Int(Date().timeIntervalSince(startTime) * 1000))ms",
                "searchHistoryCount": "\(searchHistory.count)"
            ])
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            articleSearchError = "搜索失败，请稍后重试"
            articleSearchResults = []
            isArticleSearching = false

            LogManager.shared.error("organization", "文章搜索失败", context: [
                "keyword": trimmed,
                "error": error.localizedDescription,
                "elapsed": "\(elapsed)ms"
            ])
        }
    }

    // MARK: 机构子站搜索频道

    /// 机构子站栏目索引缓存条目（siteKey → siteId + 全栏目；30 分钟有效）
    /// version 变更强制旧缓存失效（栏目收集规则升级后立即生效）
    private struct OrgIndexEntry: Codable {
        let version: Int
        let siteId: String
        let columns: [NetworkService.DeptColumnRef]
        let fetchedAt: Date
    }

    private static let orgIndexCacheKey = "orgSearchIndexCache"
    private static let orgIndexTTL: TimeInterval = 1800
    /// 当前索引版本：v3 纳入 id-only 内容页栏目，并排除 articles 子树文章 ID 混入
    private static let orgIndexVersion = 3

    private static func cachedOrgIndex(_ siteKey: String) -> OrgIndexEntry? {
        guard let data = UserDefaults.standard.data(forKey: orgIndexCacheKey),
              let dict = try? JSONDecoder().decode([String: OrgIndexEntry].self, from: data),
              let entry = dict[siteKey],
              entry.version >= orgIndexVersion,
              Date().timeIntervalSince(entry.fetchedAt) < orgIndexTTL else { return nil }
        return entry
    }

    private static func storeOrgIndex(_ siteKey: String, _ entry: OrgIndexEntry) {
        let key = orgIndexCacheKey
        var dict: [String: OrgIndexEntry] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: OrgIndexEntry].self, from: data) {
            dict = decoded
        }
        dict[siteKey] = entry
        // 容量守卫：最多保留 60 个站点索引
        if dict.count > 60, let oldest = dict.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            dict.removeValue(forKey: oldest)
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 检索全部机构子站真实文章：
    /// - 机构清单来自 OrganizationManager（静态 siteKey 去重，仅保留有详情页的机构）；
    /// - 每机构先解析子站栏目索引（30 分钟缓存 + 运行时 home2 兜底），
    ///   全栏目检索（不设栏目数上限），每栏按 total 动态分页：
    ///   常规至多 4 页 200 条；深度检索（deep）至多 8 页 400 条；
    /// - 并发分批（每批 8 个机构）拉取并逐批流式合入搜索结果，进度实时可见。
    private func searchOrganizationArticles(keyword: String, deep: Bool) async -> Int {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        let lowerKeyword = trimmed.lowercased()
        let rawTerms = lowerKeyword.components(separatedBy: .whitespaces).filter { $0.count >= 2 }
        let terms = rawTerms.isEmpty ? [lowerKeyword] : rawTerms

        // 机构清单（静态 siteKey 去重）
        var siteEntries: [(name: String, key: String)] = []
        var seenKeys = Set<String>()
        for unit in OrganizationManager.shared.departments where unit.hasDetailPage {
            guard let key = unit.siteKey, !key.isEmpty, !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            siteEntries.append((unit.name, key))
        }
        guard !siteEntries.isEmpty else {
            LogManager.shared.warning("organization", "机构子站搜索跳过：无可用站点清单", context: ["keyword": trimmed])
            return 0
        }

        LogManager.shared.info("organization", "机构子站搜索开始", context: [
            "keyword": trimmed,
            "sites": "\(siteEntries.count)",
            "deep": "\(deep)"
        ])

        let batchSize = 8
        let maxPages = deep ? 8 : 4
        var totalOrgMatched = 0
        var knownIDs = Set(articleSearchResults.map(\.id))

        for batchStart in stride(from: 0, to: siteEntries.count, by: batchSize) {
            let batch = Array(siteEntries[batchStart..<min(batchStart + batchSize, siteEntries.count)])
            let batchRange = "\(batchStart + 1)–\(min(batchStart + batchSize, siteEntries.count))"
            orgSearchProgress = "\(deep ? "深度检索" : "检索")机构子站 \(batchRange) / \(siteEntries.count)（已命中 \(totalOrgMatched) 条）"

            let batchHits: [[(orgName: String, siteId: String, columnTitle: String, dto: NetworkService.ArticleDTO)]] =
                await withTaskGroup(of: [(orgName: String, siteId: String, columnTitle: String, dto: NetworkService.ArticleDTO)].self) { group in
                    for (orgName, siteKey) in batch {
                        group.addTask {
                            await Self.fetchOrgArticles(siteKey: siteKey, orgName: orgName, maxPages: maxPages)
                        }
                    }
                    var hits: [[(orgName: String, siteId: String, columnTitle: String, dto: NetworkService.ArticleDTO)]] = []
                    for await hit in group { hits.append(hit) }
                    return hits
                }

            // 本批匹配评分 + 去重 + 流式合入（机构名随结果透传，卡片直接展示）
            var newOnes: [ArticleSearchResult] = []
            var batchMatched = 0
            for hitList in batchHits {
                for hit in hitList {
                    guard !knownIDs.contains(hit.dto.id ?? "") else { continue }
                    if let result = Self.makeOrgResult(orgName: hit.orgName, columnTitle: hit.columnTitle, siteId: hit.siteId, dto: hit.dto, terms: terms) {
                        if let rid = hit.dto.id { knownIDs.insert(rid) }
                        batchMatched += 1
                        newOnes.append(result)
                    }
                }
            }
            if !newOnes.isEmpty {
                articleSearchResults.append(contentsOf: newOnes)
            }
            totalOrgMatched += batchMatched
        }

        // 单文章型机构频道（官方权威机构树 /school/org）：
        // 党委组织部/工会/科协等机构的内容是主站一篇介绍文章，独立补齐最后盲区
        let articleOrgHits = await searchArticleTypeOrgs(terms: terms, keyword: trimmed)
        totalOrgMatched += articleOrgHits

        orgSearchProgress = nil
        LogManager.shared.info("organization", "机构子站搜索完成", context: [
            "keyword": trimmed,
            "sitesSearched": "\(siteEntries.count)",
            "orgMatched": "\(totalOrgMatched)",
            "articleOrgMatched": "\(articleOrgHits)"
        ])
        return totalOrgMatched
    }

    /// 拉取单个机构子站全部候选文章：
    /// - 全栏目检索（不设栏目数上限，覆盖所有子栏目）；
    /// - 每栏按 total 动态分页（size 50，至多 maxPages 页），真实覆盖栏目全量文章；
    /// - 返回原始 DTO 供上层评分。
    private static func fetchOrgArticles(siteKey: String, orgName: String, maxPages: Int) async -> [(orgName: String, siteId: String, columnTitle: String, dto: NetworkService.ArticleDTO)] {
        // ① 栏目索引：30 分钟缓存优先，落空则运行时解析 home2
        var index: OrgIndexEntry?
        if let cached = cachedOrgIndex(siteKey) {
            index = cached
        } else if let fresh = try? await NetworkService.shared.fetchDeptSiteIndex(siteKey: siteKey),
                  !fresh.siteId.isEmpty {
            let entry = OrgIndexEntry(version: orgIndexVersion, siteId: fresh.siteId, columns: fresh.columns, fetchedAt: Date())
            index = entry
            storeOrgIndex(siteKey, entry)
            await MainActor.run {
                LogManager.shared.debugLog("organization", "机构子站栏目索引已解析", context: [
                    "siteKey": siteKey, "orgName": orgName,
                    "siteId": String(fresh.siteId.prefix(8)) + "…",
                    "columns": "\(fresh.columns.count)"
                ])
            }
        }
        guard let index, !index.siteId.isEmpty else {
            await MainActor.run {
                LogManager.shared.warning("organization", "机构子站索引解析失败，已跳过", context: [
                    "siteKey": siteKey, "orgName": orgName
                ])
            }
            return []
        }

        // ② 全栏目检索：按栏目名语义排序（新闻/通知/公告/动态优先展示顺序），不设栏目数上限
        let priorityKeywords = ["新闻", "通知", "公告", "动态", "要闻", "工作", "风采", "资讯"]
        let ordered = index.columns.sorted { a, b in
            let pa = priorityKeywords.firstIndex { a.title.contains($0) } ?? 99
            let pb = priorityKeywords.firstIndex { b.title.contains($0) } ?? 99
            if pa != pb { return pa < pb }
            return a.title < b.title
        }
        guard !ordered.isEmpty else { return [] }

        // ③ 逐栏动态分页拉取（首页按 total 决定后续页数，最多 maxPages 页 50 条/页）
        //    栏组流水分批（每批 6 栏）控制并发水位：全栏目纳入后每站栏目数可达 20+，
        //    避免批内 8 站同时全栏并发造成网络风暴
        var results: [(orgName: String, siteId: String, columnTitle: String, dto: NetworkService.ArticleDTO)] = []
        let columnChunkSize = 6
        for chunkStart in stride(from: 0, to: ordered.count, by: columnChunkSize) {
            let chunk = Array(ordered[chunkStart..<min(chunkStart + columnChunkSize, ordered.count)])
            await withTaskGroup(of: [(String, NetworkService.ArticleDTO)].self) { group in
                for col in chunk {
                    group.addTask {
                        var all: [NetworkService.ArticleDTO] = []
                        do {
                            let first = try await NetworkService.shared.fetchArticles(
                                columnId: col.id, siteId: index.siteId, page: 1, size: 50
                            )
                            let list = first.articles?.list ?? []
                            all.append(contentsOf: list)
                            let total = first.articles?.total ?? 0
                            var page = 2
                            while page <= maxPages, all.count < total, !list.isEmpty {
                                let next = try await NetworkService.shared.fetchArticles(
                                    columnId: col.id, siteId: index.siteId, page: page, size: 50
                                )
                                let nextList = next.articles?.list ?? []
                                if nextList.isEmpty { break }
                                all.append(contentsOf: nextList)
                                page += 1
                            }
                        } catch {
                            // 首页失败整栏无果；后续页失败保留已取数据
                        }
                        return all.map { (col.title, $0) }
                    }
                }
                for await list in group {
                    for item in list {
                        results.append((orgName: orgName, siteId: index.siteId, columnTitle: item.0, dto: item.1))
                    }
                }
            }
        }
        return results
    }

    /// 机构文章匹配评分（与主站口径一致：标题 3 分/精确 +2/前缀 +1，描述 1 分）
    private static func makeOrgResult(
        orgName: String,
        columnTitle: String,
        siteId: String,
        dto: NetworkService.ArticleDTO,
        terms: [String]
    ) -> ArticleSearchResult? {
        guard let id = dto.id, let title = dto.resolvedTitle, !title.isEmpty else { return nil }
        let lowerTitle = title.lowercased()
        let lowerDesc = (dto.description ?? "").lowercased()
        var score: Float = 0
        var hit = false
        for term in terms {
            if lowerTitle.contains(term) {
                score += 3
                hit = true
                if lowerTitle == term { score += 2 }
                if lowerTitle.hasPrefix(term) { score += 1 }
            }
            if lowerDesc.contains(term) {
                score += 1
                hit = true
            }
        }
        guard hit else { return nil }
        return ArticleSearchResult(
            id: id,
            articleId: id,
            title: title,
            description: dto.description ?? "",
            tag: dto.tag ?? "",
            updateTime: dto.updateTime ?? "",
            imageUrl: dto.imageUrl,
            siteId: siteId,
            columnName: columnTitle,
            orgName: orgName,
            relevanceScore: score
        )
    }

    // MARK: 单文章型机构频道（官方权威机构树）

    /// 机构树缓存盒（/school/org 结果，30 分钟有效）
    private struct OrgTreeBox: Codable {
        let nodes: [NetworkService.SchoolOrgNode]
        let fetchedAt: Date
    }

    private static let orgTreeCacheKey = "schoolOrgTreeCache"
    private static let orgTreeTTL: TimeInterval = 1800

    private static func cachedOrgTree() -> [NetworkService.SchoolOrgNode]? {
        guard let data = UserDefaults.standard.data(forKey: orgTreeCacheKey),
              let box = try? JSONDecoder().decode(OrgTreeBox.self, from: data),
              Date().timeIntervalSince(box.fetchedAt) < orgTreeTTL else { return nil }
        return box.nodes
    }

    private static func storeOrgTree(_ nodes: [NetworkService.SchoolOrgNode]) {
        if let data = try? JSONEncoder().encode(OrgTreeBox(nodes: nodes, fetchedAt: Date())) {
            UserDefaults.standard.set(data, forKey: orgTreeCacheKey)
        }
    }

    /// 单文章型机构频道：部分机构（党委组织部/工会/科协等）在官网不是子站，
    /// 其全部内容即主站的一篇介绍文章——按文章标题与正文全文匹配，补齐最后盲区。
    private func searchArticleTypeOrgs(terms: [String], keyword: String) async -> Int {
        var nodes = Self.cachedOrgTree()
        if nodes == nil {
            if let fresh = try? await NetworkService.shared.fetchSchoolOrgTree(), !fresh.isEmpty {
                nodes = fresh
                Self.storeOrgTree(fresh)
                LogManager.shared.info("organization", "权威机构树已解析", context: [
                    "total": "\(fresh.count)",
                    "articleTypeCount": "\(fresh.filter { $0.articleId != nil }.count)"
                ])
            }
        }
        guard let nodes, !nodes.isEmpty else {
            LogManager.shared.warning("organization", "权威机构树不可用，单文章机构检索跳过", context: [:])
            return 0
        }
        let articleOrgs = nodes.filter { $0.articleId != nil }
        guard !articleOrgs.isEmpty else { return 0 }

        orgSearchProgress = "检索单文章机构介绍（\(articleOrgs.count) 个）…"
        let lowerTerms = terms.map { $0.lowercased() }
        var knownIDs = Set(articleSearchResults.map(\.id))
        var appended = 0

        await withTaskGroup(of: (NetworkService.SchoolOrgNode, NetworkService.ArticleDetailDTO?).self) { group in
            for org in articleOrgs {
                let articleId = org.articleId ?? ""
                group.addTask {
                    let detail = try? await NetworkService.shared.fetchZSWArticleDetail(
                        articleId: articleId, siteId: "1"
                    )
                    return (org, detail)
                }
            }
            var candidates: [(name: String, articleId: String, title: String, text: String)] = []
            for await (org, detail) in group {
                guard let detail else { continue }
                let plain = (detail.content ?? "").replacingOccurrences(
                    of: "<[^>]+>", with: "", options: .regularExpression
                )
                candidates.append((org.name, org.articleId ?? "", detail.title ?? "", plain))
            }
            for c in candidates {
                guard !knownIDs.contains(c.articleId) else { continue }
                let lt = c.title.lowercased()
                let lp = c.text.lowercased()
                var score: Float = 0
                var hit = false
                for term in lowerTerms {
                    if lt.contains(term) { score += 4; hit = true }
                    if lp.contains(term) { score += 1; hit = true }
                }
                guard hit else { continue }
                knownIDs.insert(c.articleId)
                appended += 1
                let result = ArticleSearchResult(
                    id: c.articleId,
                    articleId: c.articleId,
                    title: c.title,
                    description: String(c.text.prefix(80)),
                    tag: "机构介绍",
                    updateTime: "",
                    imageUrl: nil,
                    siteId: "1",
                    columnName: "机构介绍",
                    orgName: c.name,
                    relevanceScore: score
                )
                await MainActor.run {
                    articleSearchResults.append(result)
                }
            }
        }
        return appended
    }

    /// 格式化搜索日期
    private func formatSearchDate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let f3 = DateFormatter(); f3.dateFormat = "yyyy-MM-dd"
            return [f1, f2, f3]
        }()
        for fmt in formatters {
            if let date = fmt.date(from: raw) {
                let out = DateFormatter()
                out.dateFormat = "yyyy.MM.dd"
                return out.string(from: date)
            }
        }
        return String(raw.prefix(10))
    }

    /// 生成搜索历史行布局（每行最多放3个标签）
    private func generateHistoryRows() -> [[String]] {
        let maxPerRow = 3
        var rows: [[String]] = []
        var currentRow: [String] = []
        for term in searchHistory {
            if currentRow.count >= maxPerRow {
                rows.append(currentRow)
                currentRow = [term]
            } else {
                currentRow.append(term)
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}

// MARK: - 卡片按钮样式

struct OrganizationCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 预览

#Preview("机构设置 - 浅色") {
    NavigationStack {
        OrganizationView()
    }
    .preferredColorScheme(.light)
}

#Preview("机构设置 - 深色") {
    NavigationStack {
        OrganizationView()
    }
    .preferredColorScheme(.dark)
}