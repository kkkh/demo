//
//  OrganizationDetailView.swift
//  山西晋中理工学院 APP — 机构详情页
//
//  在 App 内展示机构/部门的完整页面内容：
//  - 文章列表、通知公告、规章制度等区块
//  - 图片、资讯数据与官网实时同步
//  - 支持深色/浅色模式
//  - 完整日志埋点
//  - 文章详情缓存 + 异步HTML解析，杜绝主线程阻塞
//

import SwiftUI
import WebKit
import UIKit

// MARK: - 机构区块模型

/// 机构页面区块类型
enum DeptSectionType: String {
    case news           // 新闻列表
    case notice         // 通知公告
    case regulations    // 规章制度
    case tabs           // 带子标签的区块
    case content        // 内容页
    case calendar       // 日历
    case link           // 外部链接
    case unknown        // 未知类型
}

/// 机构页面区块
struct OrgSection: Identifiable {
    let id: String
    let title: String
    let type: DeptSectionType
    let articles: [OrgArticle]
    let children: [OrgChildSection]
    let columnId: String?
    let siteId: String?
}

/// 子区块（如学院概况下的学院简介、学院领导等）
struct OrgChildSection: Identifiable {
    let id: String
    let title: String
    let articles: [OrgArticle]
    let columnId: String?
    /// 子区块自身的 siteId（可能独立于父级部门）
    let siteId: String?
    /// 子区块的 href（用于路由：专业介绍→SpecialtyListView，录取查询→Safari）
    let href: String?
}

/// 机构文章
struct OrgArticle: Identifiable {
    let id: String
    let title: String
    let description: String
    let imageUrl: String?
    let updateTime: String
    let tag: String
    let articleId: String
    /// 文章所属站点的 siteId（从区块继承）
    var sectionSiteId: String?
}

// MARK: - 文章详情缓存模型

/// 缓存的文章详情数据
struct CachedArticleDetail {
    let title: String
    let content: String
    let plainText: String
    let author: String
    let source: String
    let publishTime: String
    let images: [DataService.ArticleImage]
    let timestamp: Date
}

// MARK: - 文章详情缓存管理器

/// 线程安全的文章详情内存缓存
final class ArticleDetailCache: @unchecked Sendable {
    static let shared = ArticleDetailCache()

    private let cache = NSCache<NSString, CachedArticleDetailWrapper>()
    private let maxAge: TimeInterval = 300 // 5 分钟过期

    private init() {
        cache.countLimit = 100
    }

    func get(articleId: String, siteId: String) -> CachedArticleDetail? {
        let key = cacheKey(articleId: articleId, siteId: siteId)
        guard let wrapper = cache.object(forKey: key) else { return nil }
        // 检查是否过期
        if Date().timeIntervalSince(wrapper.detail.timestamp) > maxAge {
            cache.removeObject(forKey: key)
            return nil
        }
        return wrapper.detail
    }

    func set(_ detail: CachedArticleDetail, articleId: String, siteId: String) {
        let key = cacheKey(articleId: articleId, siteId: siteId)
        cache.setObject(CachedArticleDetailWrapper(detail: detail), forKey: key)
    }

    func clear() {
        cache.removeAllObjects()
    }

    private func cacheKey(articleId: String, siteId: String) -> NSString {
        "\(siteId)_\(articleId)" as NSString
    }
}

/// NSCache 需要存储 class 类型，用 wrapper 包装 struct
private final class CachedArticleDetailWrapper {
    let detail: CachedArticleDetail
    init(detail: CachedArticleDetail) { self.detail = detail }
}

// MARK: - 文章导航标识（用于 sheet(item:) 安全状态管理）

/// 文章导航包装，确保 sheet 捕获正确的 siteId
struct ArticleNavigation: Identifiable {
    let id: String
    let article: OrgArticle
    let siteId: String
    let color: Color

    init(article: OrgArticle, siteId: String, color: Color) {
        self.id = article.articleId
        self.article = article
        self.siteId = siteId
        self.color = color
    }
}

/// 子标签导航包装
struct ChildSectionNavigation: Identifiable {
    let id: String
    let child: OrgChildSection
    let siteId: String
    let color: Color

    init(child: OrgChildSection, siteId: String, color: Color) {
        self.id = child.id
        self.child = child
        self.siteId = siteId
        self.color = color
    }
}

// MARK: - 常量

/// 招生网（ZSW）专用 siteId，用于获取完整文章内容（含图片）
private let zswSiteId = "cb3b1fe4fcdf40999b0c162015c3326d"

/// 历年分数线查询子站 URL
private let scoreLineURL = "https://www.sxjzit.edu.cn/#/list/more?type=notice&site_id=cb3b1fe4fcdf40999b0c162015c3326d&column_id=6ea796a091ff4bbc9622a5550668906f"

/// 降级搜索用主站栏目 ID 运行时解析（2026-09-27 联网实测：旧硬编码 ID 已全部失效返回 500）
/// 优先从 home2 动态取（要闻/资讯/党建/通知），失败回退当日实测现行值；官网换 ID 后动态路径自动跟进
@MainActor
private func resolveMainSiteSearchColumns() async -> [(String, String)] {
    if let home2 = try? await NetworkService.shared.fetchHome2(),
       let children = home2.news?.children {
        let resolved = [
            children.importants?.columnId.map { ("要闻", $0) },
            children.updates?.columnId.map { ("资讯", $0) },
            children.resports?.columnId.map { ("党建", $0) },
            children.notices?.columnId.map { ("通知", $0) },
        ].compactMap { $0 }
        if resolved.count == 4 {
            LogManager.shared.debugLog("organization", "降级搜索栏目 ID 动态解析成功", context: [
                "columns": resolved.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
            ])
            return resolved
        }
    }
    // 回退：2026-09-27 联网实测现行值（官网换 ID 后可先 curl 复核再更新此处）
    return [
        ("要闻", "41cb4c8424ac474891e1470aa2fb071b"),
        ("资讯", "90ede7291c1245988c0af440b782c218"),
        ("党建", "10a8da2fe65444a7a788778a3c9cd788"),
        ("通知", "747dcb1ef01449238c24bc1ba84b7a60"),
    ]
}

// MARK: - 机构详情视图

struct OrganizationDetailView: View {
    let unit: OrganizationUnit

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var homeData: NetworkService.DeptHome2DTO?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var sections: [OrgSection] = []
    @State private var articleNavigation: ArticleNavigation?
    @State private var childNavigation: ChildSectionNavigation?
    /// 专业介绍列表导航（招生就业处专用）
    @State private var showSpecialtyList = false
    /// 录取查询外链 URL（招生就业处专用）
    @State private var admissionQueryURL: URL?
    /// 历年分数线查询 WebView 显示状态（招生就业处专用）
    @State private var showScoreLine = false

    /// 部门站点 ID（从首页数据中提取）
    @State private var deptSiteId: String = "1"

    /// 降级模式：尝试从主站加载相关文章
    @State private var fallbackArticles: [OrgArticle] = []
    @State private var isFallbackLoading = false
    @State private var fallbackError: String?
    /// 防止重复触发降级加载
    @State private var hasAttemptedFallback = false

    /// 刷新反馈
    @State private var showRefreshToast: Bool = false
    @State private var refreshToastMessage: String = ""
    @State private var refreshToastSuccess: Bool = true

    /// 防并发：当前加载任务
    @State private var loadTask: Task<Void, Never>?

    /// 屏幕高度（替代已废弃的 UIScreen.main.bounds）
    private var screenHeight: CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return 0 }
        return scene.screen.bounds.height
    }

    /// 屏幕宽度（替代已废弃的 UIScreen.main.bounds）
    private var screenWidth: CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return 0 }
        return scene.screen.bounds.width
    }

    var body: some View {
        ZStack {
            Group {
                if isLoading && sections.isEmpty && !isFallbackLoading {
                    // 初始加载中：显示加载动画
                    loadingView
                } else if !sections.isEmpty {
                    // 有数据时显示完整内容
                    contentView
                } else {
                    // 无数据时统一显示降级页面（包含错误信息、降级文章、部门介绍等）
                    enhancedFallbackView
                }
            }

            // 刷新反馈 Toast
            if showRefreshToast {
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
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .navigationTitle(unit.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                refreshButton
            }
        }
        .sheet(item: $articleNavigation) { nav in
            NavigationStack {
                OrganizationArticleDetailView(
                    article: nav.article,
                    siteId: nav.siteId,
                    color: nav.color
                )
            }
            .sjzPresentationChrome()
        }
        .sheet(item: $childNavigation) { nav in
            NavigationStack {
                ChildSectionDetailView(
                    child: nav.child,
                    siteId: nav.siteId,
                    color: nav.color
                )
            }
            .sjzPresentationChrome()
        }
        .sheet(isPresented: $showSpecialtyList) {
            NavigationStack {
                SpecialtyListView()
            }
            .sjzPresentationChrome()
        }
        .sheet(isPresented: $showScoreLine) {
            NavigationStack {
                WebViewContainer(urlString: scoreLineURL)
                    .navigationTitle("历年分数线查询")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showScoreLine = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
            }
            .sjzPresentationChrome()
            .onAppear {
                LogManager.shared.info("organization", "历年分数线查询WebView打开", context: [
                    "department": unit.name,
                    "url": scoreLineURL
                ])
            }
        }
        .onChange(of: admissionQueryURL) { _, newURL in
            if let url = newURL {
                openURL(url)
                admissionQueryURL = nil
            }
        }
        .task {
            // 取消之前的加载任务，防止并发（必须在创建新任务前取消旧任务）
            loadTask?.cancel()
            let task = Task { await loadData() }
            loadTask = task
            await task.value
        }
        .onAppear {
            LogManager.shared.info("organization", "机构详情页打开", context: [
                "name": unit.name,
                "category": unit.category.rawValue,
                "siteKey": unit.siteKey ?? "nil"
            ])
        }
    }

    // MARK: 加载视图

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)
            Text("加载部门数据中...")
                .displayFont(15)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GradientBackground())
    }

    // MARK: 错误视图

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.slash")
                .displaySymbolFont(48)
                .foregroundStyle(.secondary)
            Text(msg)
                .displayFont(15)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await performDetailRefresh(source: "错误页重试") }
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
                    .displayLabelFont(14, weight: .medium)
            }
            .buttonStyle(.bordered)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(GradientBackground())
    }

    // MARK: 增强降级展示页（无独立子站或API失败的部门）

    /// 增强版降级页面 —— 即使没有独立子站，也尝试从学校主站获取相关数据
    private var enhancedFallbackView: some View {
        ScrollView {
            VStack(spacing: 24) {
                departmentHeader

                VStack(spacing: 16) {
                    // 子站加载状态提示（当有 errorMessage 且 siteKey 存在时显示）
                    if let msg = errorMessage, !msg.isEmpty, unit.siteKey != nil, !(unit.siteKey?.isEmpty ?? true) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .displaySymbolFont(16)
                                .foregroundStyle(Color.sjzOrange)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("子站数据加载失败")
                                    .displayFont(14, weight: .semibold)
                                    .foregroundStyle(.primary)
                                Text(msg)
                                    .displayFont(12)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                HStack(spacing: 10) {
                                    Button {
                                        Task { await performDetailRefresh(source: "降级页重试") }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.clockwise")
                                                .displaySymbolFont(11)
                                            Text("重试加载")
                                                .displayFont(12, weight: .medium)
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule()
                                                .fill(unit.category.color)
                                        )
                                    }
                                    .contentShape(Rectangle())
                                    
                                    if let detailURL = unit.detailURL {
                                        Link(destination: detailURL) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "safari")
                                                    .displaySymbolFont(11)
                                                Text("在官网查看")
                                                    .displayFont(12, weight: .medium)
                                            }
                                            .foregroundStyle(unit.category.color)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(
                                                Capsule()
                                                    .stroke(unit.category.color.opacity(0.4), lineWidth: 1)
                                            )
                                        }
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(unit.category.color.opacity(colorScheme == .dark ? 0.12 : 0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.sjzOrange.opacity(0.2), lineWidth: 0.5)
                        )
                    }

                    // 部门介绍
                    infoCard(
                        icon: "info.circle.fill",
                        title: "部门介绍",
                        content: departmentDescription
                    )

                    // 分类信息 + 联系方式
                    HStack(spacing: 12) {
                        infoCard(
                            icon: "building.2.fill",
                            title: "所属分类",
                            content: "\(unit.category.rawValue) · 山西晋中理工学院"
                        )
                        if unit.siteKey != nil, !(unit.siteKey?.isEmpty ?? true) {
                            infoCard(
                                icon: "link.circle.fill",
                                title: "独立子站",
                                content: "该部门拥有独立子站，应用将自动同步完整数据"
                            )
                        }
                    }

                    // 主站相关文章
                    if isFallbackLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在搜索相关部门文章...")
                                .displayFont(13)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.ultraThinMaterial)
                        )
                    } else if let fbError = fallbackError {
                        infoCard(
                            icon: "exclamationmark.triangle.fill",
                            title: "相关文章",
                            content: fbError
                        )
                    } else if !fallbackArticles.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "newspaper.fill")
                                    .displaySymbolFont(14)
                                    .foregroundStyle(unit.category.color)
                                Text("主站相关文章")
                                    .displayFont(15, weight: .semibold)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(fallbackArticles.count) 篇")
                                    .displayFont(11)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(.ultraThinMaterial)
                                    )
                            }
                            .padding(.horizontal, 16)

                            LazyVStack(spacing: 10) {
                                ForEach(fallbackArticles) { article in
                                    fallbackArticleCard(article)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    } else if unit.siteKey != nil, !(unit.siteKey?.isEmpty ?? true) {
                        // 有 siteKey 但 API 和降级搜索都未找到文章
                        infoCard(
                            icon: "magnifyingglass",
                            title: "相关文章",
                            content: "暂未找到与「\(unit.name)」相关的文章，请尝试下拉刷新或访问学校官网。"
                        )
                    }

                    // 数据来源说明
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .displaySymbolFont(13)
                                .foregroundStyle(unit.category.color)
                            Text("数据来源")
                                .displayFont(14, weight: .semibold)
                                .foregroundStyle(.primary)
                        }
                        Text(unit.siteKey != nil && !(unit.siteKey?.isEmpty ?? true)
                            ? "该部门拥有独立子站，当前可能因网络原因暂时无法访问。应用已尝试从学校主站搜索相关文章，并将在后续自动重试同步。您也可以下拉刷新或点击重试按钮手动加载。"
                            : "该部门暂无独立子站，当前显示为预置数据。应用启动后自动从学校官网同步机构信息，若该部门后续开通独立子站，应用将自动更新并显示完整内容。"
                        )
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                    )

                    // 快捷操作按钮组
                    HStack(spacing: 12) {
                        // 访问部门子站按钮（如果有 siteKey）
                        if let detailURL = unit.detailURL {
                            Link(destination: detailURL) {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                        .displaySymbolFont(13)
                                    Text("访问部门子站")
                                        .displayFont(13, weight: .medium)
                                    Image(systemName: "arrow.up.right")
                                        .displaySymbolFont(9)
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(unit.category.color)
                                )
                            }
                            .contentShape(Rectangle())
                        }
                        
                        // 访问学校官网按钮
                        Link(destination: URL(string: "https://www.sxjzit.edu.cn")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                    .displaySymbolFont(13)
                                Text("学校官网")
                                    .displayFont(13, weight: .medium)
                            }
                            .foregroundStyle(unit.category.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(unit.category.color.opacity(0.4), lineWidth: 1)
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .padding(.top, 4)

                    // 数据同步状态
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .displaySymbolFont(12)
                                .foregroundStyle(.secondary)
                            Text("数据同步状态")
                                .displayFont(12, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                        Text("应用启动时自动从学校官网同步机构数据。若该部门后续开通独立子站，应用将自动更新并显示完整内容。")
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                            .lineSpacing(3)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .background(GradientBackground())
        .refreshable {
            await performDetailRefresh(source: "降级页下拉刷新")
        }
        .task {
            await loadFallbackArticles()
        }
    }

    /// 降级文章卡片
    private func fallbackArticleCard(_ article: OrgArticle) -> some View {
        Button {
            LogManager.shared.info("organization", "降级文章点击", context: [
                "department": unit.name,
                "articleId": article.articleId,
                "title": article.title,
                "siteId": "1"
            ])
            articleNavigation = ArticleNavigation(
                article: article,
                siteId: "1",
                color: unit.category.color
            )
        } label: {
            HStack(spacing: 12) {
                if let imageUrl = article.imageUrl, !imageUrl.isEmpty,
                   !imageUrl.contains("no_picture") {
                    SJZCachedImage(url: safeURL(from: imageUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            placeholderIcon
                        default:
                            placeholderIcon
                        }
                    }
                } else {
                    placeholderIcon
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title)
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !article.description.isEmpty {
                        Text(article.description)
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack {
                        if !article.tag.isEmpty {
                            Text(article.tag)
                                .displayFont(10)
                                .foregroundStyle(unit.category.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(unit.category.color.opacity(0.1))
                                )
                        }
                        Spacer()
                        Text(formatDate(article.updateTime))
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
                    .stroke(unit.category.color.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.03), radius: 6, y: 3)
        }
        .buttonStyle(OrganizationCardButtonStyle())
        .contentShape(Rectangle())
    }

    /// 从主站加载与部门相关的文章
    private func loadFallbackArticles() async {
        guard !isFallbackLoading, !hasAttemptedFallback else { return }
        isFallbackLoading = true
        hasAttemptedFallback = true
        fallbackError = nil

        LogManager.shared.info("organization", "降级模式：尝试从主站搜索相关文章", context: [
            "name": unit.name
        ])

        do {
            // 尝试搜索主站多个栏目（并行搜索提高效率）
            let columns = try await withThrowingTaskGroup(
                of: (String, [NetworkService.ArticleDTO]).self
            ) { group in
                // 搜索多个栏目以提高命中率（栏目 ID 运行时解析——2026-09-27 实测旧硬编码 ID 已全部 500）
                let columnIds = await resolveMainSiteSearchColumns()
                for (name, colId) in columnIds {
                    group.addTask {
                        do {
                            let result = try await NetworkService.shared.fetchArticles(
                                columnId: colId,
                                siteId: "1",
                                page: 1,
                                size: 30
                            )
                            return (name, result.articles?.list ?? [])
                        } catch {
                            await LogManager.shared.debugLog("organization", "降级搜索栏目失败", context: [
                                "columnId": colId, "name": name, "error": error.localizedDescription
                            ])
                            return (name, [])
                        }
                    }
                }
                var allArticles: [NetworkService.ArticleDTO] = []
                for try await (_, articles) in group {
                    allArticles.append(contentsOf: articles)
                }
                return allArticles
            }

            // 按标题匹配部门名称
            let keywords = extractKeywords(from: unit.name)
            let matched = columns.filter { dto in
                guard let title = dto.resolvedTitle else { return false }
                let lowerTitle = title.lowercased()
                return keywords.contains { lowerTitle.contains($0) }
            }

            fallbackArticles = matched.compactMap { dto in
                guard let id = dto.id, let title = dto.resolvedTitle, !title.isEmpty else { return nil }
                return OrgArticle(
                    id: id,
                    title: title,
                    description: dto.description ?? "",
                    imageUrl: dto.imageUrl,
                    updateTime: dto.updateTime ?? "",
                    tag: dto.tag ?? "",
                    articleId: id,
                    sectionSiteId: "1"
                )
            }

            if fallbackArticles.isEmpty {
                fallbackError = "未找到与「\(unit.name)」直接相关的文章"
            }

            LogManager.shared.info("organization", "降级文章搜索完成", context: [
                "name": unit.name,
                "total": "\(columns.count)",
                "matched": "\(fallbackArticles.count)",
                "keywords": keywords.joined(separator: ", ")
            ])
        } catch {
            fallbackError = "搜索相关文章失败：\(error.localizedDescription)"
            LogManager.shared.error("organization", "降级文章搜索失败", context: [
                "name": unit.name,
                "error": error.localizedDescription
            ])
        }

        isFallbackLoading = false
    }

    /// 从部门名称提取搜索关键词（增强版）
    private func extractKeywords(from name: String) -> [String] {
        var keywords: [String] = [name.lowercased()]
        // 提取核心词（去掉括号内容）
        let parts = name.components(separatedBy: CharacterSet(charactersIn: "（）()"))
        for part in parts where part.count >= 2 {
            keywords.append(part.lowercased())
        }
        // 提取常见后缀组合
        let suffixes = ["处", "部", "室", "会", "院", "中心", "办公室", "委员会", "学院"]
        for suffix in suffixes {
            if let range = name.range(of: suffix) {
                let core = String(name[..<range.upperBound]).lowercased()
                if !keywords.contains(core) {
                    keywords.append(core)
                }
            }
        }
        // 提取不含后缀的核心词（如"保卫"、"后勤"、"网络"、"信息"）
        let coreWords = name.components(separatedBy: CharacterSet(charactersIn: "（）()处部室会院中心办公室委员会学院"))
            .filter { $0.count >= 2 }
        for word in coreWords {
            let lower = word.lowercased()
            if !keywords.contains(lower) {
                keywords.append(lower)
            }
        }
        return Array(Set(keywords))
    }

    /// 根据部门名称生成描述
    private var departmentDescription: String {
        switch unit.name {
        case "党委办公室":
            return "党委办公室是学校党委的综合办事机构，负责党委日常工作的组织协调、文秘档案、信息调研、督查督办、机要保密、信访接待等工作，是党委联系各部门和师生员工的桥梁纽带。"
        case "党委组织部":
            return "党委组织部负责学校党的组织建设、干部队伍建设、党员发展和教育管理工作，统筹协调基层党组织建设，为学校发展提供坚强的组织保证。"
        case "党委宣传部":
            return "党委宣传部负责学校思想理论建设、意识形态工作、新闻宣传、校园文化建设、精神文明创建等工作，是学校宣传思想文化工作的主阵地。"
        case "党委统战部":
            return "党委统战部负责学校统一战线工作，贯彻落实党的统战方针政策，做好民主党派、无党派人士、民族宗教、港澳台侨等工作。"
        case "纪检监察办公室":
            return "纪检监察办公室负责学校党的纪律检查工作，履行监督执纪问责职责，推进全面从严治党向纵深发展，营造风清气正的校园政治生态。"
        case "党委教师工作部":
            return "党委教师工作部负责教师思想政治工作和师德师风建设，统筹教师队伍建设规划，组织教师培训和专业发展。"
        case "思想政治教育工作部":
            return "思想政治教育工作部负责学校思想政治理论课建设和学生思想政治教育工作，推进马克思主义理论研究和宣传教育。"
        case "工会":
            return "工会是学校教职工自愿结合的群众组织，维护教职工合法权益，组织教职工参与学校民主管理和民主监督，开展教职工文化体育活动。"
        case "妇联":
            return "妇联负责学校妇女工作，维护女教职工和女学生合法权益，组织开展巾帼建功、家庭教育等活动。"
        case "科协":
            return "科协负责学校科学技术协会工作，组织学术交流、科学普及、科技咨询等活动，促进科技创新和成果转化。"
        case "关心下一代工作委员会":
            return "关心下一代工作委员会负责组织离退休老同志参与青少年思想道德建设、关爱帮扶等工作，促进青少年健康成长。"
        case "校长办公室":
            return "校长办公室是学校行政的综合办事机构，负责行政日常工作的组织协调、文秘档案、信息调研、督查督办、法律事务、对外联络等工作。"
        case "人力资源处":
            return "人力资源处负责学校人才队伍建设、人事管理、薪酬福利、社会保险等工作，为学校发展提供人才保障和智力支持。"
        case "财务与资产管理处":
            return "财务与资产管理处负责学校财务管理和资产管理工作，统筹学校经费预算、核算、监督和国有资产管理。"
        case "学生工作处":
            return "学生工作处（与学生工作部合署办公）负责学生思想政治教育、日常管理、资助育人、心理健康教育、国防教育等工作，服务学生成长成才。"
        case "招生就业处":
            return "招生就业处负责学校招生工作和毕业生就业创业指导服务，组织实施招生宣传、录取工作和就业市场开拓、就业指导服务。"
        case "后勤管理处":
            return "后勤管理处负责学校后勤保障服务工作，包括餐饮服务、物业管理、校园绿化、能源管理、维修服务等。"
        case "科研处":
            return "科研处负责学校科学研究管理工作，组织科研项目申报与管理、科研成果转化、学术交流、科研平台建设等。"
        case "保卫处":
            return "保卫处负责学校安全保卫工作，维护校园治安秩序，负责消防安全、交通安全、综合治理和突发事件应急处置。"
        case "实践教学管理中心":
            return "实践教学管理中心负责学校实践教学管理和实验室建设，统筹实验实训基地规划、校企合作实践基地建设等工作。"
        default:
            return "\(unit.name)是\(unit.category.rawValue)的重要组成部分，致力于服务学校发展大局，为师生提供优质服务保障。了解更多信息请访问学校官网。"
        }
    }

    private func infoCard(icon: String, title: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .displaySymbolFont(18)
                .foregroundStyle(unit.category.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .displayFont(15, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(content)
                    .displayFont(13)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(unit.category.color.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
        )
    }

    private var refreshButton: some View {
        Group {
            if unit.siteKey != nil && !(unit.siteKey?.isEmpty ?? true) {
                Button {
                    Task { await performDetailRefresh(source: "按钮刷新") }
                } label: {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .displaySymbolFont(14, weight: .medium)
                    }
                }
                .disabled(isLoading)
                .contentShape(Rectangle())
            }
        }
    }

    /// 刷新并显示反馈
    private func performDetailRefresh(source: String) async {
        LogManager.shared.info("organization", "部门详情刷新触发", context: [
            "name": unit.name,
            "source": source,
            "hasSections": "\(!sections.isEmpty)",
            "sectionCount": "\(sections.count)",
            "hasFallback": "\(!fallbackArticles.isEmpty)",
            "siteKey": unit.siteKey ?? "nil"
        ])

        let beforeCount = sections.reduce(0) { $0 + $1.articles.count }
        // 取消之前的加载任务，防止并发
        loadTask?.cancel()
        let task = Task { await loadData() }
        loadTask = task
        await task.value

        let afterCount = sections.reduce(0) { $0 + $1.articles.count }
        let hasFallbackData = !fallbackArticles.isEmpty
        let fallbackErr = fallbackError

        // 优先判断：有文章数据（正常加载或降级成功）
        if afterCount > 0 {
            if afterCount > beforeCount {
                refreshToastMessage = "刷新完成（新增\(afterCount - beforeCount)篇，共\(afterCount)篇）"
            } else {
                refreshToastMessage = "刷新完成（\(afterCount)篇文章）"
            }
            refreshToastSuccess = true
            LogManager.shared.info("organization", "刷新成功反馈", context: [
                "source": source,
                "detailPages": "\(afterCount)",
                "beforePages": "\(beforeCount)",
                "name": unit.name
            ])
        } else if hasFallbackData {
            // 降级成功，显示降级内容
            refreshToastMessage = "已加载降级内容（\(fallbackArticles.count)篇）"
            refreshToastSuccess = true
            LogManager.shared.info("organization", "刷新降级成功", context: [
                "source": source,
                "fallbackCount": "\(fallbackArticles.count)",
                "name": unit.name
            ])
        } else if let error = errorMessage {
            // 有明确错误信息
            refreshToastMessage = error
            refreshToastSuccess = false
            LogManager.shared.warning("organization", "刷新失败反馈", context: [
                "source": source,
                "error": error,
                "name": unit.name
            ])
        } else if let fbError = fallbackErr {
            // 降级也失败了
            refreshToastMessage = fbError
            refreshToastSuccess = false
            LogManager.shared.warning("organization", "刷新降级失败", context: [
                "source": source,
                "error": fbError,
                "name": unit.name
            ])
        } else {
            // 没有错误也没有数据，可能是子站无内容
            refreshToastMessage = "该部门暂无内容"
            refreshToastSuccess = true
            LogManager.shared.info("organization", "刷新完成（无内容）", context: [
                "source": source,
                "name": unit.name
            ])
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            showRefreshToast = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRefreshToast = false
                }
            }
        }
    }

    // MARK: 内容视图

    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                departmentHeader

                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(.vertical, 16)
            .frame(minHeight: screenHeight)
        }
        .scrollBounceBehavior(.always)
        .background(GradientBackground())
        .refreshable {
            await performDetailRefresh(source: "下拉刷新")
        }
    }

    // MARK: 部门头部

    private var departmentHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [
                                unit.category.color,
                                unit.category.color.opacity(0.6)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: unit.category.color.opacity(0.3), radius: 14, y: 8)

                Image(systemName: unit.icon)
                    .displaySymbolFont(32, weight: .medium)
                    .foregroundStyle(.white)
            }

            Text(unit.name)
                .displayFont(22, weight: .bold)
                .foregroundStyle(.primary)

            Text(unit.category.rawValue)
                .displayFont(12, weight: .medium)
                .foregroundStyle(unit.category.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(unit.category.color.opacity(colorScheme == .dark ? 0.2 : 0.12))
                )

            if let banner = homeData?.topBanners, let imgSrc = banner.imgSrc, !imgSrc.isEmpty {
                SJZCachedImage(url: safeURL(from: imgSrc)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    case .failure:
                        EmptyView()
                    default:
                        ProgressView()
                            .frame(height: 120)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }

    // MARK: 区块视图

    @ViewBuilder
    private func sectionView(_ section: OrgSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(section)

            if !section.children.isEmpty {
                childTabsView(section)
            }

            if !section.articles.isEmpty {
                articleListView(section.articles, sectionSiteId: section.siteId ?? deptSiteId)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 区块标题

    private func sectionHeader(_ section: OrgSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sectionIcon(for: section.type))
                .displaySymbolFont(14, weight: .semibold)
                .foregroundStyle(unit.category.color)

            Text(section.title)
                .displayFont(17, weight: .bold)
                .foregroundStyle(.primary)

            Spacer()

            if !section.articles.isEmpty {
                Text("\(section.articles.count) 篇")
                    .displayFont(11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
            }
        }
    }

    private func sectionIcon(for type: DeptSectionType) -> String {
        switch type {
        case .news:           return "newspaper.fill"
        case .notice:         return "bell.badge.fill"
        case .regulations:    return "doc.text.fill"
        case .tabs:           return "rectangle.stack.fill"
        case .content:        return "doc.richtext.fill"
        case .calendar:       return "calendar"
        case .link:           return "link"
        case .unknown:        return "square.grid.2x2.fill"
        }
    }

    // MARK: 子标签页视图

    private func childTabsView(_ section: OrgSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(section.children) { child in
                    childTabCard(child)
                }
            }
        }
    }

    private func childTabCard(_ child: OrgChildSection) -> some View {
        Button {
            LogManager.shared.info("organization", "子标签点击进入", context: [
                "department": unit.name,
                "child": child.title,
                "articleCount": "\(child.articles.count)",
                "columnId": child.columnId ?? "nil",
                "href": child.href ?? "nil"
            ])

            // 专业介绍：路由到 SpecialtyListView（使用 oneTwoArticles API）
            if child.title.contains("专业介绍") || child.columnId == "25d7bd39e49a468880356e302b9ccf1d" {
                LogManager.shared.info("organization", "专业介绍→路由到 SpecialtyListView", context: [
                    "columnId": child.columnId ?? "nil"
                ])
                showSpecialtyList = true
                return
            }

            // 历年分数线查询：子站 WebView 打开（必须在"查询"之前检查，避免被录取查询拦截）
            if child.title.contains("历年分数线") || child.title.contains("分数线") {
                LogManager.shared.info("organization", "历年分数线查询→WebView 打开", context: [
                    "department": unit.name,
                    "url": scoreLineURL
                ])
                showScoreLine = true
                return
            }

            // 录取查询：外链→Safari 打开
            if child.title.contains("录取查询") {
                if let href = child.href, !href.isEmpty, href != "/" {
                    let queryURL = "https://www.sxjzit.edu.cn/#/zsw-query"
                    if let url = URL(string: queryURL) {
                        LogManager.shared.info("organization", "录取查询→Safari 打开", context: [
                            "url": queryURL
                        ])
                        admissionQueryURL = url
                        return
                    }
                }
            }

            childNavigation = ChildSectionNavigation(
                child: child,
                siteId: child.siteId ?? deptSiteId,
                color: unit.category.color
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(child.title)
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !child.articles.isEmpty {
                    Text("\(child.articles.count) 项")
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(unit.category.color.opacity(colorScheme == .dark ? 0.15 : 0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(OrganizationCardButtonStyle())
        .contentShape(Rectangle())
    }

    // MARK: 文章列表视图

    private func articleListView(_ articles: [OrgArticle], sectionSiteId: String) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(articles) { article in
                articleCard(article, sectionSiteId: sectionSiteId)
            }
        }
    }

    private func articleCard(_ article: OrgArticle, sectionSiteId: String) -> some View {
        Button {
            let actualSiteId = article.sectionSiteId ?? sectionSiteId
            LogManager.shared.info("organization", "文章点击", context: [
                "department": unit.name,
                "articleId": article.articleId,
                "title": article.title,
                "siteId": actualSiteId,
                "sectionSiteId": sectionSiteId,
                "articleSiteId": article.sectionSiteId ?? "nil"
            ])
            articleNavigation = ArticleNavigation(
                article: article,
                siteId: actualSiteId,
                color: unit.category.color
            )
        } label: {
            HStack(spacing: 12) {
                if let imageUrl = article.imageUrl, !imageUrl.isEmpty,
                   !imageUrl.contains("no_picture") {
                    SJZCachedImage(url: safeURL(from: imageUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            placeholderIcon
                        default:
                            placeholderIcon
                        }
                    }
                } else {
                    placeholderIcon
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title)
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !article.description.isEmpty {
                        Text(article.description)
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if !article.tag.isEmpty {
                            Text(article.tag)
                                .displayFont(10)
                                .foregroundStyle(unit.category.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(unit.category.color.opacity(0.1))
                                )
                        }
                        Spacer()
                        Text(formatDate(article.updateTime))
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
                    .stroke(unit.category.color.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.03), radius: 6, y: 3)
        }
        .buttonStyle(OrganizationCardButtonStyle())
        .contentShape(Rectangle())
    }

    private var placeholderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(unit.category.color.opacity(0.12))
                .frame(width: 60, height: 60)
            Image(systemName: "doc.text.image")
                .displaySymbolFont(18)
                .foregroundStyle(unit.category.color.opacity(0.4))
        }
    }

    // MARK: - 文章详情 Sheet（已通过 sheet(item:) 处理，无需额外方法）

    // MARK: 数据加载

    private func loadData() async {
        // 注意：取消旧任务的操作已移至 .task 修饰符中，避免错误取消当前任务
        guard let siteKey = unit.siteKey, !siteKey.isEmpty else {
            isLoading = false
            errorMessage = nil
            // 关键修复：重置降级状态，确保降级页面的数据是最新的
            fallbackArticles = []
            fallbackError = nil
            isFallbackLoading = false
            hasAttemptedFallback = false
            LogManager.shared.info("organization", "部门无独立子站，显示降级页面", context: [
                "name": unit.name,
                "category": unit.category.rawValue
            ])
            return
        }

        isLoading = true
        errorMessage = nil
        // 关键修复：每次加载前重置 sections 和降级状态，避免旧数据残留
        sections = []
        fallbackArticles = []
        fallbackError = nil
        isFallbackLoading = false
        hasAttemptedFallback = false

        LogManager.shared.info("organization", "部门数据加载开始", context: [
            "name": unit.name,
            "siteKey": siteKey
        ])

        // 带重试的数据加载（带标签的循环，确保 break 能正确跳出）
        var lastError: Error?
        retryLoop: for attempt in 0...2 {
            // 检查是否被取消
            if Task.isCancelled {
                isLoading = false
                LogManager.shared.debugLog("organization", "部门数据加载已取消", context: [
                    "name": unit.name, "siteKey": siteKey
                ])
                return
            }

            do {
                let data = try await withTimeout(seconds: 12) {
                    try await NetworkService.shared.fetchDeptHome2(siteKey: siteKey)
                }
                homeData = data

                if let firstNav = data.nav?.first {
                    deptSiteId = firstNav.siteId ?? "1"
                    // 关键修复：招生就业处（ZSW）必须使用招生网专用 siteId
                    // 如果 API 返回的 siteId 为通用主站 "1"，则强制替换为 ZSW siteId
                    // 这是确保文章内容完整（含图片）的关键
                    if deptSiteId == "1" && siteKey == "zsw" {
                        deptSiteId = zswSiteId
                        LogManager.shared.info("organization", "招生就业处强制使用ZSW siteId", context: [
                            "name": unit.name,
                            "siteKey": siteKey,
                            "originalSiteId": firstNav.siteId ?? "nil",
                            "forcedSiteId": deptSiteId
                        ])
                    }
                    LogManager.shared.debugLog("organization", "部门站点ID提取", context: [
                        "name": unit.name,
                        "siteKey": siteKey,
                        "deptSiteId": deptSiteId,
                        "hasNavData": "\(firstNav.data != nil)",
                        "navTitle": firstNav.titleCn ?? "nil",
                        "navKeys": firstNav.data?.keys.joined(separator: ", ") ?? "nil"
                    ])
                } else {
                    // 无导航数据时，招生就业处也使用 ZSW siteId
                    if siteKey == "zsw" {
                        deptSiteId = zswSiteId
                        LogManager.shared.info("organization", "招生就业处无导航数据，使用ZSW siteId", context: [
                            "name": unit.name,
                            "siteKey": siteKey,
                            "deptSiteId": deptSiteId
                        ])
                    }
                    LogManager.shared.warning("organization", "部门无导航数据，使用默认siteId", context: [
                        "name": unit.name,
                        "siteKey": siteKey
                    ])
                }

                sections = parseSections(from: data)

                let initialArticleCount = sections.reduce(0) { $0 + $1.articles.count }
                let initialChildCount = sections.reduce(0) { $0 + $1.children.count }
                LogManager.shared.info("organization", "部门数据初始解析完成", context: [
                    "name": unit.name,
                    "siteKey": siteKey,
                    "sectionCount": "\(sections.count)",
                    "articleCount": "\(initialArticleCount)",
                    "childCount": "\(initialChildCount)",
                    "siteId": deptSiteId,
                    "attempt": "\(attempt + 1)"
                ])

                // 后台补充加载：为每个有 columnId 的 section 加载更多文章
                let enrichedCount = await enrichSectionsWithMoreArticles()

                isLoading = false

                let finalArticleCount = sections.reduce(0) { $0 + $1.articles.count }
                LogManager.shared.info("organization", "部门数据加载成功（含补充）", context: [
                    "name": unit.name,
                    "siteKey": siteKey,
                    "sectionCount": "\(sections.count)",
                    "initialArticleCount": "\(initialArticleCount)",
                    "finalArticleCount": "\(finalArticleCount)",
                    "enrichedCount": "\(enrichedCount)",
                    "childCount": "\(initialChildCount)",
                    "siteId": deptSiteId,
                    "attempt": "\(attempt + 1)"
                ])
                return
            } catch let error as TimeoutError {
                lastError = error
                if attempt < 2 {
                    LogManager.shared.warning("organization", "部门数据加载超时，准备重试", context: [
                        "name": unit.name,
                        "siteKey": siteKey,
                        "attempt": "\(attempt + 1)",
                        "error": error.localizedDescription
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch let error as URLError {
                lastError = error
                if attempt < 2 {
                    LogManager.shared.warning("organization", "部门数据加载网络失败，准备重试", context: [
                        "name": unit.name,
                        "siteKey": siteKey,
                        "attempt": "\(attempt + 1)",
                        "error": error.localizedDescription
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                lastError = error
                // 500 错误、业务错误、空数据均不重试（服务器端错误，重试无意义）
                if let networkError = error as? NetworkError {
                    switch networkError {
                    case .badResponse(let code) where code >= 500:
                        LogManager.shared.warning("organization", "部门子站500错误，跳过重试", context: [
                            "name": unit.name, "siteKey": siteKey, "statusCode": "\(code)"
                        ])
                        break retryLoop  // 跳出整个重试循环
                    case .serverError(let msg):
                        LogManager.shared.warning("organization", "部门子站业务错误，跳过重试", context: [
                            "name": unit.name, "siteKey": siteKey, "serverMessage": msg
                        ])
                        break retryLoop  // 跳出整个重试循环
                    case .noData:
                        LogManager.shared.warning("organization", "部门子站返回空数据，跳过重试", context: [
                            "name": unit.name, "siteKey": siteKey
                        ])
                        break retryLoop  // 跳出整个重试循环
                    default:
                        if attempt < 2 {
                            LogManager.shared.warning("organization", "部门数据加载异常，准备重试", context: [
                                "name": unit.name,
                                "siteKey": siteKey,
                                "attempt": "\(attempt + 1)",
                                "error": error.localizedDescription
                            ])
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                } else if attempt < 2 {
                    LogManager.shared.warning("organization", "部门数据加载异常，准备重试", context: [
                        "name": unit.name,
                        "siteKey": siteKey,
                        "attempt": "\(attempt + 1)",
                        "error": error.localizedDescription
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        // 所有重试都失败 — 统一降级处理
        isLoading = false
        errorMessage = nil  // 关键修复：不清除错误会导致 body 视图跳过降级页面

        if let err = lastError as? URLError {
            switch err.code {
            case .timedOut:
                errorMessage = "请求超时，已尝试加载降级内容"
            case .notConnectedToInternet, .networkConnectionLost:
                errorMessage = "网络未连接，已尝试加载降级内容"
            default:
                errorMessage = "网络异常，已尝试加载降级内容"
            }
        } else if lastError is TimeoutError {
            errorMessage = "请求超时，已尝试加载降级内容"
        } else if let networkError = lastError as? NetworkError {
            switch networkError {
            case .badResponse(let code):
                if code >= 500 {
                    LogManager.shared.warning("organization", "部门子站500错误，降级到主站", context: [
                        "name": unit.name,
                        "siteKey": siteKey,
                        "statusCode": "\(code)"
                    ])
                } else {
                    errorMessage = "数据加载失败，已尝试加载降级内容"
                }
            case .serverError(let msg):
                LogManager.shared.warning("organization", "部门子站业务错误，降级到主站", context: [
                    "name": unit.name,
                    "siteKey": siteKey,
                    "serverMessage": msg
                ])
            case .noData:
                LogManager.shared.warning("organization", "部门子站返回空数据，降级到主站", context: [
                    "name": unit.name,
                    "siteKey": siteKey
                ])
            default:
                errorMessage = "数据加载失败，已尝试加载降级内容"
            }
        } else {
            errorMessage = "数据加载失败，已尝试加载降级内容"
        }

        // 关键修复：所有错误情况统一触发降级加载
        fallbackArticles = []
        fallbackError = nil
        hasAttemptedFallback = false
        await loadFallbackArticles()

        LogManager.shared.error("organization", "部门数据加载最终失败", context: [
            "name": unit.name,
            "siteKey": siteKey,
            "error": lastError?.localizedDescription ?? "unknown",
            "fallbackCount": "\(fallbackArticles.count)"
        ])
    }

    // MARK: 区块解析

    private func parseSections(from data: NetworkService.DeptHome2DTO) -> [OrgSection] {
        var result: [OrgSection] = []

        guard let nav = data.nav, !nav.isEmpty else {
            LogManager.shared.debugLog("organization", "部门数据无导航项", context: [
                "name": unit.name
            ])
            return result
        }

        // 处理首页导航数据（第一个 nav 项）
        if let homeNav = nav.first, let homeData = homeNav.data, !homeData.isEmpty {
            let homeSiteId = homeNav.siteId ?? deptSiteId
            for (key, sectionDTO) in homeData {
                let sectionSiteId = sectionDTO.siteId ?? homeSiteId
                let type = classifySectionType(key: key, componentType: sectionDTO.componentType)
                let sectionTitle = sectionDTO.titleCn ?? sectionTitleFromKey(key)
                let articles = parseArticles(from: sectionDTO.articles, sectionSiteId: sectionSiteId)
                let children = parseChildSections(from: sectionDTO.children, sectionSiteId: sectionSiteId, sectionColumnId: sectionDTO.columnId)

                if articles.isEmpty && children.isEmpty {
                    LogManager.shared.debugLog("organization", "跳过空区块", context: [
                        "department": unit.name, "key": key, "type": sectionDTO.componentType ?? "nil"
                    ])
                    continue
                }

                let section = OrgSection(
                    id: key,
                    title: sectionTitle,
                    type: type,
                    articles: articles,
                    children: children,
                    columnId: sectionDTO.columnId,
                    siteId: sectionDTO.siteId ?? homeNav.siteId
                )
                result.append(section)

                LogManager.shared.debugLog("organization", "区块添加", context: [
                    "department": unit.name,
                    "key": key,
                    "title": section.title,
                    "type": "\(type)",
                    "articleCount": "\(articles.count)",
                    "childCount": "\(children.count)",
                    "siteId": section.siteId ?? "nil"
                ])
            }
        }

        // 处理其他导航项
        for navItem in nav.dropFirst() {
            let title = navItem.titleCn ?? navItem.titleEn ?? ""
            let navSiteId = navItem.siteId ?? deptSiteId

            // 收集文章：优先从 data 子区块获取，再尝试直接 articles
            var articles: [OrgArticle] = []
            var children: [OrgChildSection] = []

            if let navData = navItem.data {
                for (_, sectionDTO) in navData {
                    let sectionSiteId = sectionDTO.siteId ?? navSiteId
                    let sectionArticles = parseArticles(from: sectionDTO.articles, sectionSiteId: sectionSiteId)
                    articles.append(contentsOf: sectionArticles)

                    // 提取子标签（如学院概况下的学院简介、学院领导等）
                    let childSections = parseChildSections(from: sectionDTO.children, sectionSiteId: sectionSiteId, sectionColumnId: sectionDTO.columnId)
                    children.append(contentsOf: childSections)
                }
            }
            if articles.isEmpty {
                articles = parseArticles(from: navItem.articles, sectionSiteId: navSiteId)
            }

            // 递归处理子导航项（深层导航菜单）
            if let subNavItems = navItem.children, !subNavItems.isEmpty {
                for subNav in subNavItems {
                    let subTitle = subNav.titleCn ?? subNav.titleEn ?? ""
                    let subSiteId = subNav.siteId ?? navSiteId

                    var subArticles: [OrgArticle] = []

                    if let subData = subNav.data {
                        for (_, sectionDTO) in subData {
                            let sectionSiteId = sectionDTO.siteId ?? subSiteId
                            subArticles.append(contentsOf: parseArticles(from: sectionDTO.articles, sectionSiteId: sectionSiteId))
                        }
                    }
                    if subArticles.isEmpty {
                        subArticles = parseArticles(from: subNav.articles, sectionSiteId: subSiteId)
                    }

                    if !subArticles.isEmpty {
                        let subSection = OrgSection(
                            id: subNav.columnId ?? subTitle,
                            title: subTitle.isEmpty ? title + "·" + (subNav.path ?? "更多") : "\(title)·\(subTitle)",
                            type: classifySectionType(key: subTitle, componentType: subNav.componentType),
                            articles: subArticles,
                            children: [],
                            columnId: subNav.columnId,
                            siteId: subNav.siteId
                        )
                        result.append(subSection)

                        LogManager.shared.debugLog("organization", "子导航区块添加", context: [
                            "department": unit.name,
                            "parentTitle": title,
                            "subTitle": subSection.title,
                            "articleCount": "\(subArticles.count)",
                            "siteId": subSection.siteId ?? "nil"
                        ])
                    }
                }
            }

            if articles.isEmpty && children.isEmpty { continue }

            let type = classifySectionType(key: title, componentType: navItem.componentType)
            let section = OrgSection(
                id: navItem.columnId ?? title,
                title: title.isEmpty ? "更多内容" : title,
                type: type,
                articles: articles,
                children: children,
                columnId: navItem.columnId,
                siteId: navItem.siteId
            )
            result.append(section)

            LogManager.shared.debugLog("organization", "导航区块添加", context: [
                "department": unit.name,
                "title": section.title,
                "articleCount": "\(articles.count)",
                "childCount": "\(children.count)",
                "siteId": section.siteId ?? "nil"
            ])
        }

        LogManager.shared.debugLog("organization", "区块解析完成", context: [
            "name": unit.name,
            "sectionCount": "\(result.count)",
            "articleCount": "\(result.reduce(0) { $0 + $1.articles.count })",
            "childCount": "\(result.reduce(0) { $0 + $1.children.count })"
        ])

        return result
    }

    /// 从 key 推断友好的区块标题
    private func sectionTitleFromKey(_ key: String) -> String {
        let mappings: [String: String] = [
            "news": "新闻动态",
            "notice": "通知公告",
            "regulation": "规章制度",
            "tabs": "分类浏览",
            "content": "内容详情",
            "calendar": "日程安排",
            "link": "相关链接",
            "one": "首页概览",
            "updates": "最新动态",
            "importants": "重要通知",
            "informations": "信息发布",
            "resports": "工作报告",
            "activites": "校园活动",
            "enrollment": "招生信息",
            "enrollmentPlan": "招生计划",
            "enrollmentNews": "招生新闻",
            "applicationGuide": "报考指南",
        ]
        return mappings[key] ?? key
    }

    private func classifySectionType(key: String, componentType: String?) -> DeptSectionType {
        let lowerKey = key.lowercased()
        let lowerType = (componentType ?? "").lowercased()

        if lowerKey.contains("notice") || lowerType.contains("notice") {
            return .notice
        }
        if lowerKey.contains("news") || lowerType.contains("news") {
            return .news
        }
        if lowerKey.contains("regulation") || lowerKey.contains("regulation") {
            return .regulations
        }
        if lowerType.contains("tabs") || lowerKey.contains("tabs") {
            return .tabs
        }
        if lowerType.contains("calendar") {
            return .calendar
        }
        if lowerType.contains("content") {
            return .content
        }
        if lowerType.contains("link") {
            return .link
        }
        return .unknown
    }

    private func parseArticles(from listDTO: NetworkService.DeptArticleListDTO?, sectionSiteId: String? = nil) -> [OrgArticle] {
        guard let list = listDTO?.list else { return [] }
        // 关键修复：招生就业处（ZSW）的文章必须使用招生网专用 siteId
        let isZSW = unit.siteKey == "zsw"
        let effectiveSiteId: String?
        if isZSW && (sectionSiteId == nil || sectionSiteId == "1" || sectionSiteId?.isEmpty == true) {
            effectiveSiteId = zswSiteId
        } else {
            effectiveSiteId = sectionSiteId
        }
        return list.compactMap { dto in
            guard let id = dto.id, let title = dto.title, !title.isEmpty else { return nil }
            return OrgArticle(
                id: id,
                title: title,
                description: dto.description ?? "",
                imageUrl: dto.imageUrl,
                updateTime: dto.updateTime ?? "",
                tag: dto.tag ?? "",
                articleId: id,
                sectionSiteId: effectiveSiteId
            )
        }
    }

    private func parseChildSections(from childrenDTO: NetworkService.DeptChildrenDTO?, sectionSiteId: String? = nil, sectionColumnId: String? = nil) -> [OrgChildSection] {
        guard let list = childrenDTO?.list else { return [] }
        // 关键修复：招生就业处（ZSW）的子标签必须使用招生网专用 siteId
        // 确保子标签文章能获取完整内容（含图片）
        let isZSW = unit.siteKey == "zsw"
        return list.compactMap { child in
            guard let id = child.id, let title = child.titleCn, !title.isEmpty else { return nil }
            // 子标签可能拥有独立的 siteId，优先使用子标签的 siteId，否则使用父级区块的 siteId
            var childSiteId = child.siteId ?? sectionSiteId
            // 关键修复：招生就业处的子标签强制使用 ZSW siteId，确保图片和完整内容
            if isZSW && (childSiteId == nil || childSiteId == "1" || childSiteId?.isEmpty == true) {
                childSiteId = zswSiteId
                LogManager.shared.info("organization", "ZSW子标签强制使用招生网siteId", context: [
                    "department": unit.name,
                    "child": title,
                    "originalSiteId": child.siteId ?? "nil",
                    "forcedSiteId": zswSiteId
                ])
            }
            let articles = parseArticles(from: child.articles, sectionSiteId: childSiteId)
            LogManager.shared.debugLog("organization", "子标签解析", context: [
                "department": unit.name,
                "child": title,
                "articleCount": "\(articles.count)",
                "childSiteId": childSiteId ?? "nil",
                "childOwnSiteId": child.siteId ?? "nil",
                "parentSectionSiteId": sectionSiteId ?? "nil",
                "isZSW": "\(isZSW)"
            ])
            // 关键修复：所有部门子标签统一使用自身的id作为columnId
            // 父级区块columnId是父级区块自身的专栏ID，子标签id才是子标签有效的专栏ID
            // 旧逻辑 sectionColumnId ?? id 导致使用父级columnId，返回0篇文章 → 服务器繁忙
            let effectiveColumnId = id
            LogManager.shared.debugLog("organization", "子标签使用自身id作为columnId", context: [
                "department": unit.name,
                "child": title,
                "childId": id,
                "parentSectionColumnId": sectionColumnId ?? "nil",
                "isZSW": "\(isZSW)"
            ])
            return OrgChildSection(
                id: id,
                title: title,
                articles: articles,
                columnId: effectiveColumnId,
                siteId: childSiteId,
                href: child.href
            )
        }
    }

    private func formatDate(_ raw: String) -> String {
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

    // MARK: 文章补充加载

    /// 为每个有 columnId 的 section 加载更多文章（第 2-3 页），确保数据完整性
    /// - Returns: 新增的文章总数
    private func enrichSectionsWithMoreArticles() async -> Int {
        var enrichedCount = 0

        // 筛选需要补充加载的 section：有 columnId 且文章数量已达单页上限（10+，说明可能还有更多）
        let sectionsToEnrich = sections.enumerated().filter { idx, section in
            section.columnId != nil && !(section.columnId?.isEmpty ?? true) && section.articles.count >= 10
        }

        guard !sectionsToEnrich.isEmpty else {
            LogManager.shared.debugLog("organization", "无需补充加载文章", context: [
                "name": unit.name,
                "sectionCount": "\(sections.count)",
                "totalArticles": "\(sections.reduce(0) { $0 + $1.articles.count })"
            ])
            return 0
        }

        LogManager.shared.info("organization", "开始补充加载文章", context: [
            "name": unit.name,
            "sectionsToEnrich": "\(sectionsToEnrich.count)",
            "siteId": deptSiteId
        ])

        // 并行加载每个 section 的更多文章
        await withTaskGroup(of: (sectionIndex: Int, newArticles: [OrgArticle]).self) { group in
            for (idx, section) in sectionsToEnrich {
                guard let columnId = section.columnId else { continue }
                let sectionSiteId = section.siteId ?? deptSiteId
                let existingIds = Set(section.articles.map { $0.id })

                // 加载第 2、3 页
                for page in 2...3 {
                    let pageCopy = page
                    let columnIdCopy = columnId
                    let sectionSiteIdCopy = sectionSiteId
                    let existingIdsCopy = existingIds

                    group.addTask {
                        // 检查取消状态
                        if Task.isCancelled { return (idx, []) }

                        let startTime = Date()
                        do {
                            let result = try await withTimeout(seconds: 8) {
                                try await NetworkService.shared.fetchArticles(
                                    columnId: columnIdCopy,
                                    siteId: sectionSiteIdCopy,
                                    page: pageCopy,
                                    size: 20
                                )
                            }

                            let newArticles = (result.articles?.list ?? []).compactMap { dto -> OrgArticle? in
                                guard let id = dto.id, let title = dto.resolvedTitle, !title.isEmpty,
                                      !existingIdsCopy.contains(id) else { return nil }
                                return OrgArticle(
                                    id: id,
                                    title: title,
                                    description: dto.description ?? "",
                                    imageUrl: dto.imageUrl,
                                    updateTime: dto.updateTime ?? "",
                                    tag: dto.tag ?? "",
                                    articleId: id,
                                    sectionSiteId: sectionSiteIdCopy
                                )
                            }

                            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                            await LogManager.shared.debugLog("organization", "补充加载文章页完成", context: [
                                "name": unit.name,
                                "columnId": columnIdCopy,
                                "page": "\(pageCopy)",
                                "newCount": "\(newArticles.count)",
                                "elapsed": "\(elapsed)ms"
                            ])
                            return (idx, newArticles)
                        } catch {
                            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                            await LogManager.shared.debugLog("organization", "补充加载文章失败", context: [
                                "name": unit.name,
                                "columnId": columnIdCopy,
                                "page": "\(pageCopy)",
                                "error": error.localizedDescription,
                                "elapsed": "\(elapsed)ms"
                            ])
                            return (idx, [])
                        }
                    }
                }
            }

            // 收集结果并合并到 sections
            for await (idx, newArticles) in group {
                if !newArticles.isEmpty {
                    let existingSection = sections[idx]
                    let updatedArticles = existingSection.articles + newArticles
                    sections[idx] = OrgSection(
                        id: existingSection.id,
                        title: existingSection.title,
                        type: existingSection.type,
                        articles: updatedArticles,
                        children: existingSection.children,
                        columnId: existingSection.columnId,
                        siteId: existingSection.siteId
                    )
                    enrichedCount += newArticles.count
                }
            }
        }

        LogManager.shared.info("organization", "补充加载文章完成", context: [
            "name": unit.name,
            "enrichedCount": "\(enrichedCount)",
            "totalArticles": "\(sections.reduce(0) { $0 + $1.articles.count })"
        ])
        return enrichedCount
    }
}

// MARK: - 机构文章详情视图（WebView 主力渲染版）

/// 文章详情视图
/// 核心设计：使用 WKWebView 作为主力内容展示，彻底绕过 NSAttributedString 性能瓶颈。
/// 加载流程：缓存检查 → API 请求（12s 超时保护）→ WebView 渲染 → 完成
struct OrganizationArticleDetailView: View {
    let article: OrgArticle
    let siteId: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var detailContent: String = ""
    @State private var detailTitle: String = ""
    @State private var detailAuthor: String = ""
    @State private var detailSource: String = ""
    @State private var detailPublishTime: String = ""
    @State private var detailImages: [DataService.ArticleImage] = []
    @State private var isLoadingDetail = true
    @State private var detailError: String?
    @State private var loadStartTime: Date = Date()
    @State private var showSlowTip = false
    @State private var showPlainText = false
    /// WebView 加载完成标记
    @State private var webViewLoaded = false
    /// WebView 下载进度 0-1（estimatedProgress KVO，确定型进度条）
    @State private var webViewProgress: Double = 0
    @State private var showWebViewProgress = false
    /// 画廊计数（E1）：已成功加载的图片索引
    @State private var galleryLoadedIndices: Set<Int> = []
    @State private var showGalleryBar = false

    // 分享与收藏
    @State private var showSharePicker = false
    @State private var selectedShareFormat: ShareFormat?
    @State private var showWeChatShare = false
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @ObservedObject private var displaySettings = DisplaySettingsManager.shared

    // 长图生成
    @State private var isGeneratingLongImage = false
    /// 长图分享目标（系统分享面板 / 微信图片消息；由分享面板入口设置）
    @State private var longImageDestination: LongImageDestination = .system
    /// 微信长图分享载荷（非空 → 弹出长图分享菜单）
    @State private var weChatLongImagePayload: WeChatLongImagePayload?
    @State private var longImageError: String?

    /// 加载超时时间（秒）
    private let loadTimeout: TimeInterval = 6.0

    /// 屏幕宽度（替代已废弃的 UIScreen.main.bounds）
    private var screenWidth: CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return 0 }
        return scene.screen.bounds.width
    }

    var body: some View {
        // 关键修复：检测内容是否为空（包括HTML空壳），避免显示空白页
        let trimmedContent = detailContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedContent = trimmedContent.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
        // 关键修复：纯图片文章（如招生计划、报考指南）纯文本为空但包含 <img> 标签，不应误判为空
        // 空内容判定：HTML 完全为空，或（纯文本为空 且 不含图片标签）
        let isContentEmpty = !isLoadingDetail && detailError == nil
            && (trimmedContent.isEmpty || (strippedContent.isEmpty && !trimmedContent.hasImageContent))

        Group {
            if isLoadingDetail {
                loadingView
            } else if let error = detailError, !error.isEmpty {
                errorView(error)
            } else if isContentEmpty {
                // 内容为空：显示错误提示，提供重试和摘要选项
                emptyContentErrorView
            } else {
                contentView
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // 自定义标题视图，完整显示标题（支持动态字号和多行）
                let displayTitle = detailTitle.isEmpty ? article.title : detailTitle
                let titleLen = displayTitle.count
                Text(displayTitle)
                    .displayFont(titleLen > 30 ? 12 : (titleLen > 20 ? 13 : 15), weight: .semibold)
                    .lineLimit(titleLen > 40 ? 4 : (titleLen > 25 ? 3 : 2))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: screenWidth * 0.75)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                    LogManager.shared.debugLog("organization", "文章详情页关闭", context: [
                        "articleId": article.articleId
                    ])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(20)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // 收藏按钮
                    Button {
                        let bookmarkKey = article.articleId.isEmpty ? (article.title + article.updateTime) : article.articleId
                        let isBookmarked = bookmarkManager.isBookmarked(bookmarkKey)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            bookmarkManager.toggleBookmark(
                                articleId: article.articleId,
                                title: detailTitle.isEmpty ? article.title : detailTitle,
                                date: article.updateTime,
                                category: "机构文章",
                                summary: detailContent.isEmpty ? article.description : detailContent.strippingHTMLTagsFast(),
                                imageUrl: article.imageUrl,
                                href: nil,
                                author: detailAuthor.isEmpty ? nil : detailAuthor,
                                source: detailSource.isEmpty ? nil : detailSource
                            )
                        }
                        LogManager.shared.info("organization", "文章收藏操作", context: [
                            "articleId": article.articleId,
                            "title": article.title,
                            "action": isBookmarked ? "取消收藏" : "收藏"
                        ])
                    } label: {
                        let bookmarkKey = article.articleId.isEmpty ? (article.title + article.updateTime) : article.articleId
                        Image(systemName: bookmarkManager.isBookmarked(bookmarkKey) ? "bookmark.fill" : "bookmark")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(bookmarkManager.isBookmarked(bookmarkKey) ? Color.yellow : .primary)
                    }
                    .contentShape(Rectangle())

                    // 分享按钮
                    Button {
                        showSharePicker = true
                        LogManager.shared.info("organization", "文章分享按钮点击", context: [
                            "articleId": article.articleId,
                            "title": article.title
                        ])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .displaySymbolFont(14, weight: .medium)
                    }
                    .contentShape(Rectangle())

                    // 显示模式切换
                    if !detailContent.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showPlainText.toggle()
                            }
                            LogManager.shared.debugLog("organization", "切换显示模式", context: [
                                "articleId": article.articleId,
                                "mode": showPlainText ? "WebView" : "纯文本"
                            ])
                        } label: {
                            Image(systemName: showPlainText ? "doc.richtext" : "text.alignleft")
                                .displaySymbolFont(12, weight: .medium)
                                .foregroundStyle(color)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .confirmationDialog("选择分享格式", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享到微信") { showWeChatShare = true }
            Button("长图分享到微信") {
                longImageDestination = .weChat
                startLongImageGeneration()
            }
            Button("纯链接") { selectedShareFormat = .link }
            Button("Markdown文章") { selectedShareFormat = .markdown }
            Button("标题+正文文本") { selectedShareFormat = .fullText }
            Button("长图") {
                longImageDestination = .system
                startLongImageGeneration()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showWeChatShare) {
            WeChatShareMenu(payload: weChatSharePayload)
                .sjzPresentationChrome()
        }
        .sheet(item: $weChatLongImagePayload) { payload in
            WeChatLongImageShareMenu(payload: payload)
                .sjzPresentationChrome()
        }
        .sheet(item: $selectedShareFormat) { format in
            let articleURL = articleDetailURL
            let title = detailTitle.isEmpty ? article.title : detailTitle
            let body = detailContent.isEmpty ? article.description : detailContent.strippingHTMLTagsFast()
            ShareSheet(items: shareItemsForFormat(format, url: articleURL, title: title, body: body))
        }
        .task {
            LogManager.shared.info("organization", "文章详情页打开", context: [
                "articleId": article.articleId,
                "title": article.title,
                "siteId": siteId
            ])
            await loadArticleDetail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizationArticleWebViewLoaded)) { _ in
            withAnimation(.easeIn(duration: 0.3)) {
                webViewLoaded = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizationArticleWebViewBlank)) { _ in
            // WebView 渲染空白内容，自动切换到纯文本模式
            LogManager.shared.warning("organization", "WebView空白，自动切换纯文本", context: [
                "articleId": article.articleId
            ])
            withAnimation(.easeIn(duration: 0.3)) {
                showPlainText = true
                webViewLoaded = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .organizationArticleWebViewProgress)) { note in
            // WebView 下载进度（estimatedProgress KVO 驱动确定型进度条）
            guard let userInfo = note.userInfo,
                  let progress = userInfo["progress"] as? Double else { return }
            let done = (userInfo["done"] as? Bool) ?? false
            withAnimation(.linear(duration: 0.1)) {
                webViewProgress = progress
            }
            if !showWebViewProgress && webViewLoaded == false && progress < 1 {
                withAnimation(.easeIn(duration: 0.2)) { showWebViewProgress = true }
            }
            if done || progress >= 1 {
                LogManager.shared.debugLog("organization", "文章 WebView 下载完成", context: [
                    "articleId": article.articleId
                ])
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    withAnimation(.easeOut(duration: 0.3)) { showWebViewProgress = false }
                }
            }
        }
        .overlay {
            if isGeneratingLongImage {
                longImageLoadingOverlay
            }
        }
    }

    /// 画廊计数联动（E1）：成功计数+1；全部完成记日志并 1s 后渐隐进度条
    private func handleGalleryPhase(idx: Int, phase: SJZImagePhase) {
        switch phase {
        case .success:
            galleryLoadedIndices.insert(idx)
            if !showGalleryBar {
                withAnimation(.easeIn(duration: 0.2)) { showGalleryBar = true }
            }
            if galleryLoadedIndices.count >= detailImages.count {
                LogManager.shared.info("organization", "机构画廊图片全部加载完成", context: [
                    "articleId": article.articleId,
                    "total": "\(detailImages.count)"
                ])
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    withAnimation(.easeOut(duration: 0.3)) { showGalleryBar = false }
                }
            }
        case .empty:
            if !showGalleryBar {
                withAnimation(.easeIn(duration: 0.2)) { showGalleryBar = true }
            }
        case .failure:
            break
        case .skipped:
            // 无图模式：不推进画廊计数条（占位渲染由图片组件负责）
            break
        }
    }

    // MARK: 加载视图

    private var loadingView: some View {
        VStack(spacing: 16) {
            // 统一优雅加载态：流彩图标 + 相位文案 + 渐变进度 + 已用时
            SJZArticleLoadingView(
                phases: ["正在获取文章内容…", "正在解析图文排版…", "正在渲染呈现…"],
                accent: color
            )

            Text(article.title)
                .displayFont(13, weight: .medium)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if showSlowTip {
                VStack(spacing: 8) {
                    Text("内容较多，请耐心等待")
                        .displayFont(12)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 12) {
                        Button {
                            LogManager.shared.warning("organization", "用户取消加载", context: [
                                "articleId": article.articleId,
                                "elapsed": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))ms"
                            ])
                            detailError = "加载已取消"
                            isLoadingDetail = false
                        } label: {
                            Text("取消加载")
                                .displayFont(12)
                                .foregroundStyle(color)
                        }
                        .contentShape(Rectangle())

                        Button {
                            LogManager.shared.info("organization", "用户直接以纯文本加载", context: [
                                "articleId": article.articleId
                            ])
                            Task {
                                await loadArticleDetail(forcePlainText: true)
                            }
                        } label: {
                            Text("纯文本模式")
                                .displayFont(12)
                                .foregroundStyle(color)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if isLoadingDetail {
                    withAnimation(.easeIn(duration: 0.3)) {
                        showSlowTip = true
                    }
                    LogManager.shared.warning("organization", "文章加载缓慢，显示慢速提示", context: [
                        "articleId": article.articleId,
                        "elapsed": "\(Int(Date().timeIntervalSince(loadStartTime) * 1000))ms"
                    ])
                }
            }
        }
    }

    // MARK: 错误视图

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(44)
                .foregroundStyle(.secondary)

            Text(msg)
                .displayFont(15)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button {
                    showSlowTip = false
                    loadStartTime = Date()
                    Task { await loadArticleDetail() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .displayLabelFont(14, weight: .medium)
                }
                .buttonStyle(.bordered)
                .contentShape(Rectangle())

                if !article.description.isEmpty {
                    Button {
                        LogManager.shared.info("organization", "使用文章摘要兜底", context: [
                            "articleId": article.articleId
                        ])
                        detailContent = article.description
                        detailTitle = article.title
                        detailError = nil
                        isLoadingDetail = false
                    } label: {
                        Label("查看摘要", systemImage: "text.alignleft")
                            .displayLabelFont(14, weight: .medium)
                    }
                    .buttonStyle(.bordered)
                    .contentShape(Rectangle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: 空内容错误视图

    /// 当文章内容为空或HTML空壳时显示的视图
    private var emptyContentErrorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(44)
                .foregroundStyle(.secondary)

            Text("文章内容为空")
                .displayFont(16, weight: .semibold)
                .foregroundStyle(.primary)

            Text("该文章可能尚未发布完整内容，或数据源暂时不可用。您可以尝试以下操作：")
                .displayFont(13)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .lineSpacing(4)

            VStack(spacing: 10) {
                // 重试按钮
                Button {
                    LogManager.shared.info("organization", "空内容重试加载", context: [
                        "articleId": article.articleId,
                        "siteId": siteId
                    ])
                    showSlowTip = false
                    loadStartTime = Date()
                    ArticleDetailCache.shared.clear()
                    Task { await loadArticleDetail(forcePlainText: true) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("强制重新加载（纯文本模式）")
                    }
                    .displayFont(14, weight: .medium)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(color)
                    )
                }
                .contentShape(Rectangle())

                // 查看摘要按钮
                if !article.description.isEmpty {
                    Button {
                        LogManager.shared.info("organization", "空内容使用摘要兜底", context: [
                            "articleId": article.articleId
                        ])
                        detailContent = "<p>\(article.description)</p>"
                        detailTitle = article.title
                        detailError = nil
                        isLoadingDetail = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                            Text("查看文章摘要")
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(color.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .contentShape(Rectangle())
                }

                // 在官网查看按钮
                let articleURL = URL(string: "https://www.sxjzit.edu.cn/#/list/article?id=\(article.articleId)")
                if let url = articleURL {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                            Text("在官网查看原文")
                        }
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: 内容视图

    private var contentView: some View {
        VStack(spacing: 0) {
            // 元信息栏
            if !detailAuthor.isEmpty || !detailSource.isEmpty || !detailPublishTime.isEmpty {
                HStack(spacing: 12) {
                    if !detailAuthor.isEmpty {
                        Label(detailAuthor, systemImage: "person.fill")
                            .displayLabelFont(11)
                            .foregroundStyle(.secondary)
                    }
                    if !detailSource.isEmpty {
                        Label(detailSource, systemImage: "building.2.fill")
                            .displayLabelFont(11)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !detailPublishTime.isEmpty {
                        Text(formatDate(detailPublishTime))
                            .displayFont(11)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }

            // 阅读统计：独立于元信息栏渲染，正文可用即显示（HTML 正文或摘要兜底）
            if !detailContent.isEmpty || !article.description.isEmpty {
                HStack {
                    if detailContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ArticleReadingStatsText(
                            cachedID: article.articleId,
                            plainText: article.description
                        )
                    } else {
                        ArticleReadingStatsText(
                            cachedID: article.articleId,
                            html: detailContent,
                            knownImageCount: detailImages.isEmpty ? nil : detailImages.count
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // 图片画廊（确定型计数条 + 失败重试）
            if !detailImages.isEmpty && !showPlainText {
                VStack(spacing: 10) {
                    if showGalleryBar && detailImages.count > 1 {
                        SJZGalleryProgressBar(
                            loaded: galleryLoadedIndices.count,
                            total: detailImages.count
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.top, 10)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(detailImages.enumerated()), id: \.offset) { idx, img in
                                SJZCachedImage(url: safeURL(from: img.url), maxPixel: 600) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 200)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    case .failure:
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(.quaternary)
                                            .frame(width: 200, height: 150)
                                            .overlay {
                                                VStack(spacing: 4) {
                                                    Image(systemName: "arrow.clockwise")
                                                        .displaySymbolFont(12).foregroundStyle(.secondary)
                                                    Text("轻点重试")
                                                        .displayFont(9).foregroundStyle(.secondary)
                                                }
                                            }
                                    case .empty:
                                        if let hex = SJZAverageColorCache.colorHex(for: safeURL(from: img.url)) {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(hex: hex))
                                                .frame(width: 200, height: 150)
                                                .overlay { ProgressView().scaleEffect(0.7).tint(.white) }
                                        } else {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(.quaternary)
                                                .frame(width: 200, height: 150)
                                                .overlay { ProgressView().scaleEffect(0.8) }
                                        }
                                    case .skipped:
                                        // 无图模式：优雅静态占位（不起网络）
                                        SJZImageFreePlaceholder(icon: "photo")
                                            .frame(width: 200, height: 150)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                                .onPhaseChange { newPhase in
                                    handleGalleryPhase(idx: idx, phase: newPhase)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .background(.ultraThinMaterial)
            }

            // 主内容区
            if detailContent.isEmpty || detailContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 兜底：内容为空时使用摘要
                emptyContentView
            } else if showPlainText {
                // 纯文本模式
                ScrollView {
                    Text(detailContent.strippingHTMLTagsFast())
                        .displayFont(15)
                        .foregroundStyle(displaySettings.articleBodyColor ?? .primary)
                        .lineSpacing(8)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // WebView 主力渲染
                ZStack {
                    OrganizationArticleWebView(
                        htmlContent: detailContent,
                        title: detailTitle.isEmpty ? article.title : detailTitle,
                        typographyCSS: DisplaySettingsManager.shared.articleCSSLiveInjectionPayload
                    )
                    .opacity(webViewLoaded ? 1 : 0)

                    if !webViewLoaded {
                        VStack(spacing: 12) {
                            // 流彩渲染图标（优雅等待态）
                            Image(systemName: "doc.richtext")
                                .displaySymbolFont(30, weight: .medium)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(color)
                                .symbolEffect(.variableColor.iterative, isActive: true)
                                .shadow(color: color.opacity(0.3), radius: 5, y: 2)
                            Text("渲染文章中...")
                                .displayFont(13)
                                .foregroundStyle(.secondary)
                            // 确定型进度（彩虹渐变缓慢变换：图文较多文章加载耗时，真实百分比）
                            if showWebViewProgress, webViewProgress > 0.05 {
                                SJZPageLoadProgressBar(percent: webViewProgress, accent: color)
                            }
                            Button {
                                LogManager.shared.warning("organization", "用户切换纯文本模式", context: [
                                    "articleId": article.articleId
                                ])
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showPlainText = true
                                }
                            } label: {
                                Text("切换到纯文本")
                                    .displayFont(12)
                                    .foregroundStyle(color)
                            }
                            .contentShape(Rectangle())
                            .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemGroupedBackground))
                    }
                }
                .overlay(alignment: .top) {
                    // 顶部真实进度条（彩虹渐变缓慢变换）：WebView estimatedProgress 驱动，
                    // 图片繁多文章直观指示；完成自动打勾渐隐
                    if showWebViewProgress && webViewLoaded == false {
                        SJZPageLoadProgressBar(percent: webViewProgress, accent: color)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onAppear {
                    // WebView 加载超时保护（6 秒后自动切换纯文本）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        if !webViewLoaded {
                            LogManager.shared.warning("organization", "WebView 渲染超时，自动切换纯文本", context: [
                                "articleId": article.articleId
                            ])
                            withAnimation(.easeIn(duration: 0.3)) {
                                showPlainText = true
                            }
                        }
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    /// 空内容兜底视图
    private var emptyContentView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(40)
                .foregroundStyle(.secondary)

            Text("文章内容为空")
                .displayFont(15)
                .foregroundStyle(.secondary)

            if !article.description.isEmpty {
                Text(article.description)
                    .displayFont(14)
                    .foregroundStyle(displaySettings.articleBodyColor ?? .primary)
                    .lineSpacing(6)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    )
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 12) {
                Button {
                    LogManager.shared.info("organization", "用户点击重新加载文章", context: [
                        "articleId": article.articleId
                    ])
                    showSlowTip = false
                    loadStartTime = Date()
                    Task { await loadArticleDetail() }
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                        .displayLabelFont(14, weight: .medium)
                }
                .buttonStyle(.bordered)
                .contentShape(Rectangle())

                if !article.description.isEmpty {
                    Button {
                        LogManager.shared.info("organization", "用户使用纯文本模式重试", context: [
                            "articleId": article.articleId
                        ])
                        showSlowTip = false
                        loadStartTime = Date()
                        Task { await loadArticleDetail(forcePlainText: true) }
                    } label: {
                        Label("纯文本模式", systemImage: "text.alignleft")
                            .displayLabelFont(14, weight: .medium)
                    }
                    .buttonStyle(.bordered)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 文章详情加载（WebView 优化版）

    /// 加载文章详情
    /// - Parameter forcePlainText: 强制使用纯文本模式（跳过 WebView 渲染，适用于加载缓慢时）
    private func loadArticleDetail(forcePlainText: Bool = false) async {
        isLoadingDetail = true
        detailError = nil
        showSlowTip = false
        webViewLoaded = false
        showPlainText = forcePlainText
        loadStartTime = Date()

        LogManager.shared.info("organization", "文章详情加载开始", context: [
            "articleId": article.articleId,
            "siteId": siteId,
            "title": article.title,
            "forcePlainText": "\(forcePlainText)",
            "articleSectionSiteId": article.sectionSiteId ?? "nil"
        ])

        // 1. 先检查缓存（强制纯文本模式跳过缓存，重新请求最新数据）
        if !forcePlainText, let cached = ArticleDetailCache.shared.get(articleId: article.articleId, siteId: siteId) {
            // 关键修复：验证缓存内容是否有效（非空且非HTML空壳）
            let trimmedCache = cached.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let strippedCache = trimmedCache.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCache.isEmpty || (strippedCache.isEmpty && !trimmedCache.hasImageContent) {
                // 缓存内容为空或HTML空壳（纯图片文章的strippedCache为空但hasImageContent为true），清除缓存并重新请求
                ArticleDetailCache.shared.clear()
                LogManager.shared.warning("organization", "文章缓存内容无效，清除并重新请求", context: [
                    "articleId": article.articleId,
                    "siteId": siteId,
                    "cachedContentLength": "\(cached.content.count)",
                    "strippedLength": "\(strippedCache.count)",
                    "hasImageContent": "\(trimmedCache.hasImageContent)"
                ])
                // 继续执行网络请求（不 return）
            } else {
                // 缓存有效，使用缓存数据
                detailTitle = cached.title
                detailContent = cached.content
                detailAuthor = cached.author
                detailSource = cached.source
                detailPublishTime = cached.publishTime
                detailImages = cached.images
                isLoadingDetail = false

                let elapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
                LogManager.shared.info("organization", "文章详情缓存命中（WebView模式）", context: [
                    "articleId": article.articleId,
                    "title": cached.title,
                    "contentLength": "\(cached.content.count)",
                    "imageCount": "\(cached.images.count)",
                    "elapsed": "\(elapsed)ms"
                ])
                return
            }
        }

        // 2. 带超时保护的网络请求（支持 siteId 降级重试）
        do {
            let detail = try await fetchArticleDetailWithFallback()
            let rawContent = detail.content ?? detail.description ?? ""
            let title = detail.title ?? article.title

            let elapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
            LogManager.shared.debugLog("organization", "文章详情网络请求成功", context: [
                "articleId": article.articleId,
                "title": title,
                "contentLength": "\(rawContent.count)",
                "hasContent": "\(!rawContent.isEmpty)",
                "hasAuthor": "\(detail.author != nil && !(detail.author?.isEmpty ?? true))",
                "hasSource": "\(detail.source != nil && !(detail.source?.isEmpty ?? true))",
                "elapsed": "\(elapsed)ms"
            ])

            // 检查内容是否为空（包括HTML空壳检测，但纯图片文章除外）
            let trimmedContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let strippedContent = trimmedContent.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
            // 关键修复：纯图片文章（纯文本为空但含 <img> 标签）不应误判为空
            let isTrulyEmpty = trimmedContent.isEmpty || (strippedContent.isEmpty && !trimmedContent.hasImageContent)
            guard !isTrulyEmpty else {
                LogManager.shared.warning("organization", "文章内容为空", context: [
                    "articleId": article.articleId,
                    "siteId": siteId,
                    "elapsed": "\(elapsed)ms",
                    "hasDescription": "\(!article.description.isEmpty)",
                    "hasContent": "\(detail.content != nil)",
                    "hasDescr": "\(detail.description != nil)"
                ])
                // 尝试使用文章摘要作为兜底
                if !article.description.isEmpty {
                    detailContent = "<p>\(article.description)</p>"
                    detailTitle = title
                    detailAuthor = detail.author ?? ""
                    detailSource = detail.source ?? ""
                    detailPublishTime = detail.updateTime ?? detail.createTime ?? ""
                    detailImages = []
                    isLoadingDetail = false
                    LogManager.shared.info("organization", "内容为空，使用文章摘要兜底", context: [
                        "articleId": article.articleId,
                        "descriptionLength": "\(article.description.count)"
                    ])
                    return
                }
                detailError = "文章内容为空，请稍后重试"
                isLoadingDetail = false
                return
            }

            // 关键修复：检测内容是否异常短（少于200字符），可能是API返回了不完整数据
            // 纯图片文章（hasImageContent=true）跳过短内容检测，图片本身就是完整内容
            let isShortContent = strippedContent.count < 200 && !trimmedContent.hasImageContent
            let isVeryShortContent = strippedContent.count < 50 && !trimmedContent.hasImageContent
            let isExtremelyShortContent = strippedContent.count < 20 && !trimmedContent.hasImageContent
            if isShortContent {
                LogManager.shared.warning("organization", "文章内容异常短，尝试额外数据源", context: [
                    "articleId": article.articleId,
                    "siteId": siteId,
                    "strippedLength": "\(strippedContent.count)",
                    "descriptionLength": "\(article.description.count)",
                    "rawContentLength": "\(rawContent.count)"
                ])
                
                // 关键修复：对于短内容，优先尝试 ZSW siteId 获取完整内容
                // 不仅限于极短内容，对于任何短于200字符的内容都尝试
                if siteId != zswSiteId {
                    LogManager.shared.warning("organization", "文章内容短，尝试ZSW siteId获取完整内容", context: [
                        "articleId": article.articleId,
                        "title": article.title,
                        "currentSiteId": siteId,
                        "strippedLength": "\(strippedContent.count)"
                    ])
                    do {
                        let zswDetail = try await withTimeout(seconds: loadTimeout) {
                            try await NetworkService.shared.fetchArticleDetail(
                                articleId: article.articleId,
                                siteId: zswSiteId
                            )
                        }
                        let zswContent = zswDetail.content ?? zswDetail.description ?? ""
                        let zswStripped = zswContent.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
                        if zswStripped.count > strippedContent.count && zswStripped.count > 20 {
                            LogManager.shared.info("organization", "ZSW siteId返回更完整内容", context: [
                                "articleId": article.articleId,
                                "zswLength": "\(zswStripped.count)",
                                "originalLength": "\(strippedContent.count)"
                            ])
                            detailContent = zswContent
                            detailTitle = zswDetail.title ?? article.title
                            detailAuthor = zswDetail.author ?? ""
                            detailSource = zswDetail.source ?? ""
                            detailPublishTime = zswDetail.updateTime ?? zswDetail.createTime ?? ""
                            let images = await Task.detached(priority: .userInitiated) {
                                extractImagesOptimized(from: zswContent)
                            }.value
                            detailImages = images
                            isLoadingDetail = false
                            // E1：预取画廊前 3 张图片（并发≤4，命中即跳过）
                            if !images.isEmpty {
                                let urls = images.prefix(3).compactMap { URL(string: $0.url) }
                                Task { await SJZImagePrefetcher.prefetch(urls: urls) }
                            }
                            // 写入缓存
                            let cached = CachedArticleDetail(
                                title: detailTitle, content: zswContent,
                                plainText: zswStripped, author: detailAuthor,
                                source: detailSource, publishTime: detailPublishTime,
                                images: images, timestamp: Date()
                            )
                            ArticleDetailCache.shared.set(cached, articleId: article.articleId, siteId: siteId)
                            // 关键修复：ZSW返回完整内容后直接返回，不再继续短内容处理
                            let totalElapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
                            LogManager.shared.info("organization", "文章详情加载成功（ZSW补充）", context: [
                                "articleId": article.articleId,
                                "title": detailTitle,
                                "contentLength": "\(zswContent.count)",
                                "imageCount": "\(images.count)",
                                "elapsed": "\(totalElapsed)ms"
                            ])
                            return
                        }
                    } catch {
                        LogManager.shared.debugLog("organization", "ZSW siteId获取失败，继续补充处理", context: [
                            "articleId": article.articleId,
                            "error": error.localizedDescription
                        ])
                    }
                }
                
                // 构建补充内容：优先使用文章描述，再尝试detail中的description字段
                var supplementParts: [String] = []
                
                // 策略1：使用文章列表中的描述（通常比API返回的更完整）
                if !article.description.isEmpty && article.description.count > strippedContent.count {
                    let descStripped = article.description.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
                    if descStripped.count > strippedContent.count {
                        supplementParts.append("<p>\(article.description)</p>")
                    }
                }
                
                // 策略2：使用API返回的description字段
                if let detailDesc = detail.description, !detailDesc.isEmpty,
                   detailDesc != article.description {
                    let detailDescStripped = detailDesc.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
                    if detailDescStripped.count > strippedContent.count {
                        supplementParts.append("<p>\(detailDesc)</p>")
                    }
                }
                
                // 策略3：如果有author/source/publishTime信息，加入元数据区
                var metaInfo: [String] = []
                if let author = detail.author, !author.isEmpty {
                    metaInfo.append("作者：\(author)")
                }
                if let source = detail.source, !source.isEmpty {
                    metaInfo.append("来源：\(source)")
                }
                if let time = detail.updateTime ?? detail.createTime, !time.isEmpty {
                    metaInfo.append("时间：\(time)")
                }
                if !metaInfo.isEmpty {
                    supplementParts.append("<p style='color:#888;font-size:12px;'>\(metaInfo.joined(separator: " · "))</p>")
                }
                
                let supplemented = supplementParts.joined(separator: "\n")
                let combinedContent = "\(supplemented)\(rawContent)"
                
                if isExtremelyShortContent && supplemented.isEmpty {
                    // 内容极少且无补充：ZSW siteId已在上方尝试过，尝试从主站搜索同名文章
                    LogManager.shared.warning("organization", "文章内容极少，尝试主站搜索同标题文章", context: [
                        "articleId": article.articleId,
                        "title": article.title,
                        "strippedLength": "\(strippedContent.count)"
                    ])
                    let searchedContent = await searchMainSiteForArticle(title: article.title)
                    if let searched = searchedContent {
                        detailContent = searched
                        LogManager.shared.info("organization", "主站搜索找到完整文章", context: [
                            "articleId": article.articleId,
                            "searchedLength": "\(searched.count)"
                        ])
                    } else {
                        // 构建带有官网链接的提示
                        let articleURL = "https://www.sxjzit.edu.cn/#/list/article?id=\(article.articleId)"
                        detailContent = rawContent + """
                        <div style='margin-top:20px;padding:16px;background:#f8f9fa;border-radius:12px;border-left:4px solid #ff9800;'>
                            <p style='color:#333;font-size:14px;margin:0 0 8px 0;'>⚠️ 文章内容不完整</p>
                            <p style='color:#888;font-size:13px;margin:0 0 12px 0;'>该文章在部门子站仅显示摘要，完整内容请访问官网查看。</p>
                            <a href='\(articleURL)' style='display:inline-block;padding:8px 16px;background:#1a73e8;color:#fff;border-radius:8px;text-decoration:none;font-size:13px;'>在官网查看原文 →</a>
                        </div>
                        """
                        LogManager.shared.warning("organization", "文章内容极少，无可补充内容，已添加官网链接", context: [
                            "articleId": article.articleId,
                            "strippedLength": "\(strippedContent.count)"
                        ])
                    }
                } else if isVeryShortContent {
                    // 内容很短但有一些补充：优先使用补充内容为主
                    if !supplemented.isEmpty {
                        detailContent = supplemented + "<hr style='margin:16px 0;border:none;border-top:1px dashed #ddd;'/>" + rawContent
                    } else {
                        detailContent = rawContent + "<p style='color:#888;font-size:13px;margin-top:16px;'>⚠️ 文章内容可能不完整，建议访问官网查看原文</p>"
                    }
                    LogManager.shared.info("organization", "文章内容短但已补充", context: [
                        "articleId": article.articleId,
                        "originalLength": "\(strippedContent.count)",
                        "supplementParts": "\(supplementParts.count)"
                    ])
                } else {
                    // 内容较短（50-200字符）：补充描述
                    detailContent = combinedContent.isEmpty ? rawContent : "\(supplemented)\(rawContent)"
                    LogManager.shared.info("organization", "文章内容已补充", context: [
                        "articleId": article.articleId,
                        "originalLength": "\(strippedContent.count)",
                        "supplementParts": "\(supplementParts.count)",
                        "combinedLength": "\(combinedContent.count)"
                    ])
                }
            } else {
                detailContent = rawContent
                // 纯图片文章日志：内容由图片组成，跳过短内容检测
                if trimmedContent.hasImageContent && strippedContent.count < 50 {
                    LogManager.shared.info("organization", "纯图片文章，跳过短内容检测", context: [
                        "articleId": article.articleId,
                        "title": article.title,
                        "strippedLength": "\(strippedContent.count)",
                        "rawContentLength": "\(rawContent.count)"
                    ])
                }
            }

            // 在后台线程提取图片（轻量操作，不阻塞主线程）
            // 使用 detailContent（可能已被短内容检测补充了描述）
            let finalContent = detailContent
            let images = await Task.detached(priority: .userInitiated) {
                extractImagesOptimized(from: finalContent)
            }.value

            // 更新状态（WebView 直接渲染 HTML，无需 NSAttributedString 剥离）
            detailTitle = title
            detailAuthor = detail.author ?? ""
            detailSource = detail.source ?? ""
            detailPublishTime = detail.updateTime ?? detail.createTime ?? ""
            detailImages = images
            isLoadingDetail = false

            // 写入缓存（5分钟过期）
            let cached = CachedArticleDetail(
                title: title,
                content: finalContent,
                plainText: finalContent.strippingHTMLTagsFast(),
                author: detailAuthor,
                source: detailSource,
                publishTime: detailPublishTime,
                images: images,
                timestamp: Date()
            )
            ArticleDetailCache.shared.set(cached, articleId: article.articleId, siteId: siteId)

            let totalElapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
            LogManager.shared.info("organization", "文章详情加载成功", context: [
                "articleId": article.articleId,
                "title": title,
                "contentLength": "\(finalContent.count)",
                "imageCount": "\(images.count)",
                "hasAuthor": "\(!detailAuthor.isEmpty)",
                "hasSource": "\(!detailSource.isEmpty)",
                "elapsed": "\(totalElapsed)ms",
                "mode": forcePlainText ? "纯文本" : "WebView",
                "cached": "false"
            ])
        } catch is TimeoutError {
            let elapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
            LogManager.shared.error("organization", "文章详情加载超时", context: [
                "articleId": article.articleId,
                "siteId": siteId,
                "timeout": "\(loadTimeout)s",
                "elapsed": "\(elapsed)ms"
            ])
            // 超时后尝试使用摘要
            if !article.description.isEmpty {
                detailContent = "<p>\(article.description)</p>"
                detailTitle = article.title
                detailAuthor = ""
                detailSource = ""
                detailPublishTime = ""
                detailImages = []
                isLoadingDetail = false
                LogManager.shared.info("organization", "超时后使用文章摘要兜底", context: [
                    "articleId": article.articleId
                ])
                return
            }
            detailError = "加载超时，请检查网络后重试"
            isLoadingDetail = false
        } catch let error as URLError {
            let msg: String
            switch error.code {
            case .timedOut:
                msg = "请求超时，请检查网络后重试"
            case .notConnectedToInternet, .networkConnectionLost:
                msg = "网络未连接，请检查网络后重试"
            default:
                msg = "网络异常，请稍后重试"
            }
            detailError = msg
            isLoadingDetail = false
            let elapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
            LogManager.shared.error("organization", "文章详情加载网络失败", context: [
                "articleId": article.articleId,
                "siteId": siteId,
                "error": error.localizedDescription,
                "code": "\(error.code.rawValue)",
                "elapsed": "\(elapsed)ms"
            ])
        } catch let error as NetworkError {
            // 所有 siteId 都失败，尝试使用文章摘要兜底（兜底成功属正常降级路径，warning 级别）
            let elapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
            LogManager.shared.warning("organization", "文章详情数据源失败，使用摘要兜底", context: [
                "articleId": article.articleId,
                "siteId": siteId,
                "error": error.localizedDescription,
                "elapsed": "\(elapsed)ms"
            ])
            if !article.description.isEmpty {
                detailContent = "<p>\(article.description)</p>"
                detailTitle = article.title
                detailAuthor = ""
                detailSource = ""
                detailPublishTime = ""
                detailImages = []
                isLoadingDetail = false
                LogManager.shared.info("organization", "所有数据源失败，使用文章摘要兜底", context: [
                    "articleId": article.articleId,
                    "descriptionLength": "\(article.description.count)"
                ])
                return
            }
            detailError = "文章内容暂时无法加载，请稍后重试"
            isLoadingDetail = false
        } catch {
            detailError = "文章加载失败，请稍后重试"
            isLoadingDetail = false
            let elapsed = Int(Date().timeIntervalSince(loadStartTime) * 1000)
            LogManager.shared.error("organization", "文章详情加载异常", context: [
                "articleId": article.articleId,
                "siteId": siteId,
                "error": error.localizedDescription,
                "elapsed": "\(elapsed)ms"
            ])
        }
    }

    private func formatDate(_ raw: String) -> String {
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

    /// 文章详情页 URL（用于分享）
    private var articleDetailURL: String {
        if !article.articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(article.articleId)"
        }
        return SchoolInfo.website
    }

    /// 微信分享载荷（标题 + 正文摘要 + 链接 + 缩略图；微信限制由 WeChatService 统一裁剪）
    private var weChatSharePayload: WeChatSharePayload {
        WeChatSharePayload(
            title: detailTitle.isEmpty ? article.title : detailTitle,
            description: detailContent.isEmpty ? article.description : detailContent.strippingHTMLTagsFast(),
            urlString: articleDetailURL,
            thumbImageURL: article.imageUrl
        )
    }

    /// 根据分享格式生成分享内容
    private func shareItemsForFormat(_ format: ShareFormat, url: String, title: String, body: String) -> [Any] {
        switch format {
        case .link:
            return [URL(string: url) as Any]
        case .markdown:
            let md = """
            # \(title)

            > 来源：山西晋中理工学院

            \(body.prefix(500))

            [阅读原文](\(url))
            """
            return [md]
        case .fullText:
            let text = """
            \(title)

            来源：山西晋中理工学院

            \(body)

            原文链接：\(url)
            """
            return [text]
        case .longImage:
            return [URL(string: url) as Any]
        }
    }

    // MARK: - 长图生成加载遮罩

    private var longImageLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {} // 阻止穿透

            VStack(spacing: 16) {
                if let error = longImageError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .displaySymbolFont(36)
                        .foregroundStyle(.orange)
                    Text(error)
                        .displayFont(14)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button {
                        longImageError = nil
                        isGeneratingLongImage = false
                    } label: {
                        Text("关闭")
                            .displayFont(14, weight: .medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.2))
                            )
                    }
                    .contentShape(Rectangle())
                } else {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text("正在生成文章长图...")
                        .displayFont(14)
                        .foregroundStyle(.white)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
            )
            .padding(40)
        }
    }

    // MARK: - 长图生成

    /// 启动长图生成流程
    private func startLongImageGeneration() {
        isGeneratingLongImage = true
        longImageError = nil

        LogManager.shared.info("longimage", "开始生成长图", context: [
            "articleId": article.articleId,
            "title": detailTitle.isEmpty ? article.title : detailTitle
        ])

        Task {
            await generateLongImage()
        }
    }

    /// 异步下载文章图片并生成长图，完成后直接 present 系统分享面板
    private func generateLongImage() async {
        let articleURL = articleDetailURL
        let title = detailTitle.isEmpty ? article.title : detailTitle
        let body = detailContent.isEmpty ? article.description : detailContent.strippingHTMLTagsFast()

        // 构建元数据字符串
        var metaParts: [String] = []
        if !article.tag.isEmpty { metaParts.append(article.tag) }
        if !article.updateTime.isEmpty { metaParts.append(formatDate(article.updateTime)) }
        if !detailAuthor.isEmpty { metaParts.append("作者：\(detailAuthor)") }
        if !detailSource.isEmpty { metaParts.append("来源：\(detailSource)") }
        let metadata = metaParts.joined(separator: " · ")

        // 加载长图素材（压缩数据 + 尺寸元数据；渲染时按需缩略解码——多图文章的内存防线）
        let imageAssets = await ArticleLongImageLoader.loadAll(detailImages, tag: "organization_detail")

        // 渲染长图
        let renderer = ArticleLongImageRenderer(
            title: title,
            metadata: metadata,
            content: body,
            images: imageAssets,
            articleURL: articleURL,
            tag: "organization_detail"
        )

        await MainActor.run {
            // 长图渲染日志（含配色联动状态，便于定位输出差异）
            LogManager.shared.debugLog("longimage", "开始生成文章长图", context: [
                "textPreset": displaySettings.articleTextColorPreset.rawValue,
                "lightHex": DisplaySettingsManager.articleBodyLightHexSnapshot().hex
            ])
            let renderedImage = renderer.render()

            guard let renderedImage else {
                longImageError = "长图生成失败，请重试"
                LogManager.shared.error("longimage", "长图生成失败", context: [
                    "articleId": article.articleId
                ])
                return
            }

            isGeneratingLongImage = false

            LogManager.shared.info("longimage", "长图生成成功", context: [
                "articleId": article.articleId,
                "imageSize": "\(Int(renderedImage.size.width))x\(Int(renderedImage.size.height))"
            ])

            // 等 confirmationDialog 关闭动画完成后再 present 分享面板
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                switch longImageDestination {
                case .system:
                    presentLongImageShare(image: renderedImage, title: title)
                case .weChat:
                    // 微信图片消息（WXImageObject）：弹出场景菜单（好友 / 朋友圈 / 收藏）
                    weChatLongImagePayload = WeChatLongImagePayload(image: renderedImage, title: title, entry: "organization_detail")
                }
            }
        }
    }

    /// 直接以 UIKit 模态方式呈现 UIActivityViewController
    private func presentLongImageShare(image: UIImage, title: String) {
        // 交付前兜底校验：纯色 / 黑图绝不落盘分享（渲染层已校验；此处防编码链路异常）
        guard !SJZImageIntegrity.isLikelyBlank(image) else {
            longImageError = "长图生成异常（画布纯色），请重试"
            isGeneratingLongImage = true
            LogManager.shared.error("longimage", "长图交付校验拦截（画布纯色）", context: [
                "title": title,
                "pixel": SJZImageIntegrity.pixelSizeText(of: image)
            ])
            return
        }
        // 交付编码：分享扩展（微信等）内存与体积预算有限（约 120MB）——按「≤16MP / ≤10MB」编码，
        // 否则扩展会被系统终止（2026-09-28 现场：微信「加载中 → 闪回 App」）；产物含纯色 / 黑图校验
        guard let encoded = WeChatImageEncoder.encode(
            image,
            maxBytes: WeChatImageEncoder.systemShareMaxBytes,
            maxPixels: WeChatImageEncoder.systemShareMaxPixels
        ) else {
            longImageError = "图片编码失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图 JPEG 编码失败", context: ["title": title])
            return
        }
        let jpegData = encoded.data
        LogManager.shared.info("longimage", "长图分享文件编码完成", context: [
            "title": title,
            "pixel": "\(Int(encoded.pixelSize.width))x\(Int(encoded.pixelSize.height))",
            "quality": String(format: "%.2f", encoded.quality),
            "scale": String(format: "%.2f", encoded.scale),
            "bytes": "\(encoded.data.count)"
        ])

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(20)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sxjzit_\(safeTitle)_\(UUID().uuidString.prefix(6)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try jpegData.write(to: fileURL)
        } catch {
            longImageError = "图片保存失败"
            isGeneratingLongImage = true
            LogManager.shared.warning("longimage", "长图临时文件写入失败", context: ["title": title])
            return
        }

        LogManager.shared.debugLog("longimage", "长图文件已保存", context: [
            "path": fileURL.path,
            "sizeKB": "\(jpegData.count / 1024)"
        ])

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            longImageError = "无法获取窗口"
            isGeneratingLongImage = true
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let activityItems: [Any] = [fileURL, title]
        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .assignToContact, .addToReadingList,
            .postToFlickr, .postToVimeo, .postToTencentWeibo
        ]

        activityVC.completionWithItemsHandler = { [fileURL] _, completed, _, error in
            // 分享扩展（微信等）读取大图较慢，且本回调在「用户选择动作」时即触发——
            // 绝不能立即删除（现场：微信「加载中 → 闪回 App」）；交由共享中心延迟 5 分钟清理
            SJZShareFileCenter.scheduleCleanup(fileURL)
            if !completed {
                // 分享未完成（系统扩展可能因体积 / 尺寸限制中止）：记录可判别数据 + 给出可操作替代路径
                WeChatService.shared.showBanner("微信未完成分享，可改用「分享 → 长图分享到微信」", kind: .info)
                LogManager.shared.warning("longimage", "长图分享未完成（系统扩展可能中止）", context: [
                    "pixel": SJZImageIntegrity.pixelSizeText(of: image),
                    "bytes": "\(jpegData.count)",
                    "error": error?.localizedDescription ?? "none"
                ])
            }
            if let error = error {
                LogManager.shared.error("longimage", "长图分享失败", context: [
                    "error": error.localizedDescription
                ])
            }
            LogManager.shared.info("longimage", "长图分享完成", context: [
                "completed": "\(completed)"
            ])
        }

        topVC.present(activityVC, animated: true) {
            LogManager.shared.debugLog("longimage", "长图分享面板已呈现")
        }
    }

    /// 带降级重试的文章详情获取（并行版，提前取消优化）
    /// 同时尝试所有可用 siteId（原始 siteId、"1"、空字符串），使用第一个返回有效内容的请求
    /// 有效内容定义：HTML 非空且剥离后纯文本非空
    /// 一旦找到有效结果，立即取消其余并行请求，避免等待超时
    private func fetchArticleDetailWithFallback() async throws -> NetworkService.ArticleDetailDTO {
        LogManager.shared.debugLog("organization", "开始并行请求文章详情（智能siteId降级）", context: [
            "articleId": article.articleId,
            "inputSiteId": siteId,
            "articleSectionSiteId": article.sectionSiteId ?? "nil",
            "timeout": "\(loadTimeout)s",
            "title": article.title
        ])

        // 构建要尝试的 siteId 列表（去重，按优先级排序）
        // 优先级：传入siteId > 文章自身的sectionSiteId > ZSW招生网siteId > "1"(主站) > ""(空)
        // 关键修复：始终包含 ZSW siteId，确保招生网文章能获取完整内容（含图片）
        var siteIdsToTry: [String] = [siteId]
        if let articleSiteId = article.sectionSiteId, !articleSiteId.isEmpty, articleSiteId != siteId {
            siteIdsToTry.append(articleSiteId)
        }
        // ZSW siteId 作为高优先级降级：招生网文章使用此 siteId 才能获取完整内容
        if siteId != zswSiteId && !siteIdsToTry.contains(zswSiteId) {
            siteIdsToTry.append(zswSiteId)
        }
        if siteId != "1" && !siteIdsToTry.contains("1") { siteIdsToTry.append("1") }
        if !siteIdsToTry.contains("") { siteIdsToTry.append("") }

        LogManager.shared.debugLog("organization", "文章详情siteId尝试列表", context: [
            "articleId": article.articleId,
            "siteIds": siteIdsToTry.joined(separator: ", ")
        ])

        // 使用 throwing task group 实现提前取消
        var failedSiteIds: [String] = []

        let results = await withTaskGroup(
            of: (siteId: String, result: Result<NetworkService.ArticleDetailDTO, Error>).self
        ) { group in
            for sid in siteIdsToTry {
                let sidCopy = sid
                group.addTask {
                    if Task.isCancelled { return (sidCopy, .failure(CancellationError())) }
                    do {
                        let detail = try await withTimeout(seconds: self.loadTimeout) {
                            try await NetworkService.shared.fetchArticleDetail(
                                articleId: self.article.articleId,
                                siteId: sidCopy
                            )
                        }
                        return (sidCopy, .success(detail))
                    } catch {
                        return (sidCopy, .failure(error))
                    }
                }
            }

            var collected: [(siteId: String, result: Result<NetworkService.ArticleDetailDTO, Error>)] = []
            for await item in group {
                collected.append(item)
                if case .success(let detail) = item.result {
                    let content = (detail.content ?? detail.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        let stripped = content.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
                        // 关键修复：纯图片文章（纯文本为空但含 <img> 标签）也视为有效内容
                        if !stripped.isEmpty || content.hasImageContent {
                            break  // 找到有效结果，提前退出
                        }
                    }
                }
            }
            return collected
        }

        // 筛选有效结果
        var validResults: [(siteId: String, detail: NetworkService.ArticleDetailDTO)] = []
        // 失败分类统计：网络级失败（真错误） vs 空正文（服务端简报型数据，正常形态）
        var networkFailureCount = 0
        var emptyContentCount = 0

        for (sid, result) in results {
            switch result {
            case .success(let detail):
                let content = (detail.content ?? detail.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let stripped = content.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
                    // 关键修复：纯图片文章（纯文本为空但含 <img> 标签）也视为有效内容
                    if !stripped.isEmpty || content.hasImageContent {
                        validResults.append((sid, detail))
                        LogManager.shared.debugLog("organization", "文章详情有效结果", context: [
                            "articleId": article.articleId,
                            "siteId": sid,
                            "contentLength": "\(content.count)",
                            "strippedLength": "\(stripped.count)",
                            "hasImageContent": "\(content.hasImageContent)"
                        ])
                    } else {
                        failedSiteIds.append(sid)
                        emptyContentCount += 1
                        LogManager.shared.debugLog("organization", "文章详情HTML空壳（简报型）", context: [
                            "articleId": article.articleId,
                            "siteId": sid,
                            "rawLength": "\(content.count)"
                        ])
                    }
                } else {
                    failedSiteIds.append(sid)
                    emptyContentCount += 1
                    LogManager.shared.debugLog("organization", "文章详情内容为空（简报型）", context: [
                        "articleId": article.articleId,
                        "siteId": sid
                    ])
                }
            case .failure(let error):
                failedSiteIds.append(sid)
                networkFailureCount += 1
                LogManager.shared.warning("organization", "文章详情请求失败", context: [
                    "articleId": article.articleId,
                    "siteId": sid,
                    "error": error.localizedDescription
                ])
            }
        }

        // 返回最佳结果（最长内容）
        if !validResults.isEmpty {
            validResults.sort { a, b in
                let lenA = (a.detail.content ?? a.detail.description ?? "").count
                let lenB = (b.detail.content ?? b.detail.description ?? "").count
                return lenA > lenB
            }
            let bestResult = validResults[0]
            let bestContentLen = (bestResult.detail.content ?? bestResult.detail.description ?? "").count
            let isOriginalSiteId = bestResult.siteId == siteId

            LogManager.shared.info("organization", "文章详情获取成功（最长内容）", context: [
                "articleId": article.articleId,
                "usedSiteId": bestResult.siteId,
                "originalSiteId": siteId,
                "contentLength": "\(bestContentLen)",
                "isOriginalSiteId": "\(isOriginalSiteId)",
                "totalValidResults": "\(validResults.count)"
            ])
            return bestResult.detail
        }

        // 所有 siteId 都无有效正文：区分「网络级失败（真错误）」与「服务端简报型空正文（正常数据形态）」
        if networkFailureCount == 0 {
            // 全部数据源均成功返回但正文为空——党建/子站简报型文章常见形态，非系统故障
            LogManager.shared.info("organization", "文章详情正文为空（简报型文章），走摘要兜底", context: [
                "articleId": article.articleId,
                "title": String(article.title.prefix(24)),
                "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                "emptyCount": "\(emptyContentCount)"
            ])
        } else {
            LogManager.shared.error("organization", "文章详情所有siteId均失败", context: [
                "articleId": article.articleId,
                "title": article.title,
                "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                "failedSiteIds": failedSiteIds.joined(separator: ", "),
                "networkFailures": "\(networkFailureCount)",
                "emptyCount": "\(emptyContentCount)"
            ])
        }
        throw NetworkError.serverError("所有数据源均无法获取文章内容（已尝试 siteId: \(siteIdsToTry.joined(separator: ", "))）")
    }

    /// 从主站搜索同标题文章，获取完整内容
    /// 用于子站 API 返回内容不完整时的降级方案
    private func searchMainSiteForArticle(title: String) async -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard trimmedTitle.count > 3 else { return nil }

        LogManager.shared.info("organization", "主站搜索同标题文章", context: [
            "articleId": article.articleId,
            "title": trimmedTitle
        ])

        do {
            // 并行搜索主站多个栏目（栏目 ID 运行时解析，与降级搜索共用）
            let columns = try await withThrowingTaskGroup(
                of: (String, [NetworkService.ArticleDTO]).self
            ) { group in
                let columnIds = await resolveMainSiteSearchColumns()
                for (name, colId) in columnIds {
                    group.addTask {
                        do {
                            let result = try await NetworkService.shared.fetchArticles(
                                columnId: colId,
                                siteId: "1",
                                page: 1,
                                size: 30
                            )
                            return (name, result.articles?.list ?? [])
                        } catch {
                            return (name, [])
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

            // 按标题精确匹配（使用相似度比较）
            let lowerTitle = trimmedTitle.lowercased()
            let matched = columns.first { (_, dto) in
                guard let dtoTitle = dto.resolvedTitle?.lowercased() else { return false }
                // 完全匹配或包含匹配
                return dtoTitle == lowerTitle ||
                       dtoTitle.contains(lowerTitle) ||
                       lowerTitle.contains(dtoTitle)
            }

            if let (_, matchedDTO) = matched, let matchedArticleId = matchedDTO.id {
                LogManager.shared.info("organization", "主站搜索找到匹配文章", context: [
                    "articleId": article.articleId,
                    "matchedArticleId": matchedArticleId,
                    "matchedTitle": matchedDTO.resolvedTitle ?? "nil"
                ])

                // 使用主站 siteId "1" 获取完整文章内容
                let detail = try await withTimeout(seconds: 8) {
                    try await NetworkService.shared.fetchArticleDetail(
                        articleId: matchedArticleId,
                        siteId: "1"
                    )
                }
                let content = detail.content ?? detail.description ?? ""
                if !content.isEmpty {
                    let stripped = content.strippingHTMLTagsFast().trimmingCharacters(in: .whitespacesAndNewlines)
                    if stripped.count > 50 {
                        LogManager.shared.info("organization", "主站搜索获取完整文章成功", context: [
                            "articleId": article.articleId,
                            "matchedArticleId": matchedArticleId,
                            "contentLength": "\(content.count)",
                            "strippedLength": "\(stripped.count)"
                        ])
                        return content
                    }
                }
            }

            LogManager.shared.debugLog("organization", "主站搜索未找到匹配文章", context: [
                "articleId": article.articleId,
                "title": trimmedTitle,
                "searchedCount": "\(columns.count)"
            ])
            return nil
        } catch {
            LogManager.shared.warning("organization", "主站搜索失败", context: [
                "articleId": article.articleId,
                "title": trimmedTitle,
                "error": error.localizedDescription
            ])
            return nil
        }
    }
}

// MARK: - 超时工具

/// 超时错误
struct TimeoutError: Error, LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { "操作超时（\(Int(seconds))秒）" }
}

/// 带超时的异步操作包装
/// 将实际操作作为 TaskGroup 的子任务，确保超时后能正确取消并抛出 TimeoutError
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let nanos = UInt64(seconds * 1_000_000_000)

    return try await withThrowingTaskGroup(of: T.self) { group in
        // 实际工作任务作为 group 的子任务，确保超时后能被 group 取消
        group.addTask {
            try await operation()
        }
        // 超时任务
        group.addTask {
            try await Task.sleep(nanoseconds: nanos)
            throw TimeoutError(seconds: seconds)
        }
        // 获取第一个完成的结果（操作成功或超时错误）
        let result = try await group.next()
        // 取消所有剩余任务
        group.cancelAll()
        // 如果 result 为 nil（理论上不会发生），抛出超时
        guard let result = result else {
            throw TimeoutError(seconds: seconds)
        }
        return result
    }
}

// MARK: - 图片URL预处理

/// 预处理HTML内容中的图片URL，确保所有图片使用绝对URL
/// 修复相对路径、协议缺失、域名错误等问题
/// 在学校官网语境下，图片可能来自多个域名：
/// - www.sxjzit.edu.cn (主站)
/// - www2.sxjzit.edu.cn:8082 (备用服务器)
/// - 相对路径如 /uploads/... 或 uploads/...
private func fixImageURLsInHTML(_ html: String) -> String {
    let startTime = Date()
    let baseDomain = "http://www.sxjzit.edu.cn"
    let alternateDomain = "http://www2.sxjzit.edu.cn:8082"
    
    let pattern = #"(<img[^>]*src\s*=\s*["'])([^"']+)(["'][^>]*>)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
        return html
    }
    
    var fixedHTML = html
    var replacements: [(NSRange, String)] = []
    var imageCount = 0
    let nsString = html as NSString
    let range = NSRange(location: 0, length: nsString.length)
    
    regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
        guard let match = match,
              match.numberOfRanges >= 4,
              let urlRange = Range(match.range(at: 2), in: html) else { return }
        
        imageCount += 1
        let rawURL = String(html[urlRange])
        let fixedURL = resolveImageURL(rawURL, baseDomain: baseDomain, alternateDomain: alternateDomain)
        
        let fullRange = match.range
        let fullMatch = nsString.substring(with: fullRange)
        var newTag = fullMatch
        
        if fixedURL != rawURL {
            newTag = newTag.replacingOccurrences(
                of: "src=\"\(rawURL)\"", with: "src=\"\(fixedURL)\""
            ).replacingOccurrences(
                of: "src='\(rawURL)'", with: "src='\(fixedURL)'"
            )
        }
        
        // 性能优化：添加 loading="lazy" + decoding="async" 实现图片懒加载
        if !newTag.contains("loading="),
           let closingBracket = newTag.range(of: ">", options: .backwards) {
            newTag = newTag.replacingCharacters(in: closingBracket, with: " loading=\"lazy\" decoding=\"async\">")
        }
        
        if newTag != fullMatch {
            replacements.append((fullRange, newTag))
        }
    }
    
    for (range, newTag) in replacements.reversed() {
        fixedHTML = (fixedHTML as NSString).replacingCharacters(in: range, with: newTag)
    }
    
    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
    if !replacements.isEmpty {
        Task { @MainActor in
            LogManager.shared.info("organization", "图片URL预处理完成", context: [
            "fixedCount": "\(replacements.count)", "totalImages": "\(imageCount)",
            "elapsed": "\(elapsed)ms",
            "sampleBefore": String(replacements.first.map { (html as NSString).substring(with: $0.0).prefix(100) } ?? "none"),
            "sampleAfter": String(replacements.first?.1.prefix(100) ?? "none")
        ])
        }
    } else if imageCount > 0 {
        Task { @MainActor in
            LogManager.shared.debugLog("organization", "图片URL无需修复", context: [
            "totalImages": "\(imageCount)", "elapsed": "\(elapsed)ms"
        ])
        }
    }
    
    return fixedHTML
}

/// 解析并修复单个图片URL
private func resolveImageURL(_ rawURL: String, baseDomain: String, alternateDomain: String) -> String {
    // 跳过 data: URI 和 base64
    if rawURL.hasPrefix("data:") { return rawURL }
    
    // 跳过已经是有效绝对URL的
    if rawURL.hasPrefix("https://") || rawURL.hasPrefix("http://") {
        // 关键修复：对包含中文等非ASCII字符的URL进行percent-encoding
        // WKWebView无法直接加载含中文的URL，必须编码
        if rawURL.contains(where: { $0.unicodeScalars.contains(where: { $0.value > 127 }) }) {
            // 构建允许的字符集：保留ASCII字母数字、URL结构字符、已编码的%
            var allowed = CharacterSet.urlPathAllowed
            allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=%")
            if let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: allowed) {
                Task { @MainActor in
                    LogManager.shared.debugLog("organization", "图片URL中文编码", context: [
                        "original": rawURL,
                        "encoded": encoded
                    ])
                }
                return encoded
            }
        }
        return rawURL
    }
    
    // 处理协议相对URL (//www.sxjzit.edu.cn/...)
    if rawURL.hasPrefix("//") {
        return "http:" + rawURL
    }
    
    // 处理根相对路径 (/uploads/...)
    if rawURL.hasPrefix("/") {
        return baseDomain + rawURL
    }
    
    // 处理其他相对路径 (uploads/...)
    return baseDomain + "/" + rawURL
}

// MARK: - 文章 WebView（主力渲染）

/// 机构文章 WebView —— 主力内容渲染引擎
/// 直接渲染 HTML 内容，保持原文格式、图片、表格等完整样式
/// 支持深色/浅色模式自适应，图片自适应宽度
struct OrganizationArticleWebView: UIViewRepresentable {
    let htmlContent: String
    let title: String
    /// 排版实时重注入载荷（设置变更/字体下载完成 → 无需重载页面即覆盖 style#sjz-typography）
    let typographyCSS: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 性能优化：抑制增量渲染，等待完整HTML加载后再渲染，减少闪烁
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        // 性能优化：禁用滚动条和指示器减少渲染开销
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false

        // 确定型进度：KVO 监听 estimatedProgress，驱动顶部进度条（图片繁多文章的状态指示）
        let observation = webView.observe(\.estimatedProgress, options: [.new]) { observedWebView, _ in
            let progress = observedWebView.estimatedProgress
            NotificationCenter.default.post(
                name: .organizationArticleWebViewProgress,
                object: nil,
                userInfo: ["progress": progress]
            )
        }
        context.coordinator.retainProgressObservation(observation)
        // 初始化重注入基线：首次打开以内联样式呈现，后续变更由 updateUIView 增量覆盖
        context.coordinator.lastTypographyCSS = typographyCSS
        context.coordinator.latestTypographyCSS = typographyCSS

        let startTime = Date()
        let html = buildHTMLPage(content: htmlContent, title: title)
        let htmlElapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        LogManager.shared.debugLog("organization", "WebView HTML构建完成", context: [
            "title": title, "htmlLength": "\(html.count)", "elapsed": "\(htmlElapsed)ms"
        ])
        webView.loadHTMLString(html, baseURL: URL(string: "http://www.sxjzit.edu.cn"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 排版实时重注入（2026-09-29）：设置变更（家族/字号档/行距/字距/粗体）或字体下载完成（revision）
        // → 覆盖 <style id="sjz-typography"> + DOM 级 inline !important 强制 → 无需重载页面即时生效
        guard context.coordinator.lastTypographyCSS != typographyCSS else { return }
        context.coordinator.lastTypographyCSS = typographyCSS
        context.coordinator.latestTypographyCSS = typographyCSS
        Self.injectTypography(typographyCSS, into: webView, logTag: "机构文章",
                              probeFamily: DisplaySettingsManager.shared.articleCSSCurrentFamilyName, phase: "update")
    }

    /// 排版实时重注入 + DOM 级强制覆盖（2026-09-29 真机反馈强化）：
    /// ① 写入 style#sjz-typography（规则块含 !important 与后代全选）；
    /// ② 再把 body 的最终计算值以「inline !important」落到全部元素——inline !important 是作者层最高优先级，
    ///    可压过官网原文的元素内联样式（CMS 正文常见 `<span style="font-family:微软雅黑;font-size:20px">`）；
    /// ③ 返回探针串（命中元素/实际 font-family/字号/字重/document.fonts.check）供日志取证。
    /// JSON 编码规避引号/反斜杠转义风险；元素缺失时结果为 missing（留痕不误报）。
    static func injectTypography(_ css: String, into webView: WKWebView, logTag: String,
                                 probeFamily: String, phase: String) {
        guard let cssData = try? JSONEncoder().encode(css),
              let cssJSON = String(data: cssData, encoding: .utf8),
              let famData = try? JSONEncoder().encode(probeFamily),
              let famJSON = String(data: famData, encoding: .utf8) else { return }
        let js = """
        (function(){
          var el = document.getElementById('sjz-typography');
          if (!el) { return 'missing'; }
          el.textContent = \(cssJSON);
          var b = getComputedStyle(document.body);
          var props = ['font-family','font-size','line-height','letter-spacing','font-weight'];
          var vals = props.map(function(p){ return b.getPropertyValue(p); });
          var nodes = document.querySelectorAll('body, body *');
          for (var i = 0; i < nodes.length; i++) {
            var sn = nodes[i].style;
            if (!sn) { continue; }
            for (var j = 0; j < props.length; j++) { sn.setProperty(props[j], vals[j], 'important'); }
          }
          var probe = document.querySelector('p span, span, p, div') || document.body;
          var cs = getComputedStyle(probe);
          var fam = \(famJSON);
          return 'ok|' + probe.tagName + '|' + cs.fontFamily.slice(0, 90) + '|' + cs.fontSize + '|' + cs.fontWeight + '|check=' + document.fonts.check("16px '" + fam + "'");
        })();
        """
        webView.evaluateJavaScript(js) { result, error in
            let resultText = (result as? String) ?? "-"
            let errorText = error?.localizedDescription
            Task { @MainActor in
                if let errorText {
                    LogManager.shared.warning("organization", "WebView 排版实时重注入失败", context: [
                        "tag": logTag,
                        "phase": phase,
                        "error": errorText
                    ])
                } else {
                    LogManager.shared.info("organization", "WebView 排版已实时重注入", context: [
                        "tag": logTag,
                        "phase": phase,
                        "result": resultText,
                        "probeFamily": probeFamily,
                        "css": String(css.prefix(160))
                    ])
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 构建完整的 HTML 页面，包含优化的样式和图片加载修复
    private func buildHTMLPage(content: String, title: String) -> String {
        // 关键修复：预处理图片URL，确保所有图片使用绝对URL
        let fixedContent = fixImageURLsInHTML(content)
        // 正文配色联动显示设置：明暗双色值注入 CSS 变量（跟随系统时与原默认一致）
        let displaySettings = DisplaySettingsManager.shared
        let textLight = displaySettings.articleCSSTextLightHex
        let textDark = displaySettings.articleCSSTextDarkHex
        var injectionContext: [String: String] = [
            "preset": displaySettings.articleTextColorPreset.rawValue,
            "lightHex": textLight,
            "darkHex": textDark
        ]
        injectionContext.merge(displaySettings.articleCSSTypographyLogContext) { _, new in new }
        LogManager.shared.debugLog("organization", "机构文章网页原文配色与排版注入", context: injectionContext)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
            <title>\(title.replacingOccurrences(of: "\"", with: "\\\""))</title>
            <style>
                :root {
                    color-scheme: light dark;
                    --text-color: #\(textLight);
                    --bg-color: transparent;
                    --secondary-text: #666;
                    --border-color: #e5e5e5;
                    --link-color: #007AFF;
                    --table-bg: #f8f9fa;
                    --table-border: #dee2e6;
                    --code-bg: #f4f4f4;
                }
                @media (prefers-color-scheme: dark) {
                    :root {
                        --text-color: #\(textDark);
                        --secondary-text: #aaa;
                        --border-color: #333;
                        --link-color: #4da6ff;
                        --table-bg: #1c1c1e;
                        --table-border: #333;
                        --code-bg: #1c1c1e;
                    }
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    /* 排版联动显示设置：字体家族 / 字号档位 / 行距 / 字距 / 粗体（注入值与下方构建日志 context 一致） */
                    font-family: \(displaySettings.articleCSSFontFamily);
                    font-size: \(String(format: "%.1f", displaySettings.articleCSSFontSize))px;
                    line-height: \(String(format: "%.2f", displaySettings.articleCSSLineHeight));
                    letter-spacing: \(String(format: "%.2f", displaySettings.articleCSSLetterSpacing))px;
                    font-weight: \(displaySettings.articleCSSFontWeight);
                    padding: 16px 16px 40px;
                    color: var(--text-color);
                    background: var(--bg-color);
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                    -webkit-text-size-adjust: 100%;
                }
                img {
                    max-width: 100% !important;
                    height: auto !important;
                    border-radius: 8px;
                    margin: 16px 0;
                    display: block;
                }
                p { margin: 0 0 14px 0; }
                h1 { font-size: 1.375em; font-weight: 700; margin: 24px 0 16px 0; line-height: 1.4; }
                h2 { font-size: 1.1875em; font-weight: 600; margin: 20px 0 14px 0; line-height: 1.4; }
                h3 { font-size: 1.0625em; font-weight: 600; margin: 18px 0 12px 0; line-height: 1.4; }
                h4, h5, h6 { font-size: 1em; font-weight: 600; margin: 16px 0 10px 0; }
                ul, ol { padding-left: 20px; margin: 0 0 14px 0; }
                li { margin-bottom: 6px; }
                blockquote {
                    border-left: 3px solid var(--link-color);
                    padding: 8px 16px;
                    margin: 16px 0;
                    color: var(--secondary-text);
                    background: var(--table-bg);
                    border-radius: 0 6px 6px 0;
                }
                table {
                    width: 100%;
                    max-width: 100%;
                    border-collapse: collapse;
                    margin: 16px 0;
                    font-size: 0.875em;
                    display: block;
                    overflow-x: auto;
                    -webkit-overflow-scrolling: touch;
                }
                table th, table td {
                    border: 1px solid var(--table-border);
                    padding: 8px 12px;
                    text-align: left;
                }
                table th {
                    background: var(--table-bg);
                    font-weight: 600;
                }
                pre, code {
                    font-family: 'SF Mono', 'Menlo', 'Monaco', monospace;
                    font-size: 0.875em;
                    background: var(--code-bg);
                    border-radius: 4px;
                }
                pre {
                    padding: 12px;
                    overflow-x: auto;
                    margin: 16px 0;
                    line-height: 1.5;
                }
                code { padding: 2px 6px; }
                pre code { padding: 0; background: none; }
                a {
                    color: var(--link-color);
                    text-decoration: none;
                }
                hr {
                    border: none;
                    border-top: 1px solid var(--border-color);
                    margin: 24px 0;
                }
                video { max-width: 100%; border-radius: 8px; margin: 16px 0; }
                iframe { max-width: 100%; border-radius: 8px; margin: 16px 0; }
                /* 清除 CMS 编辑器常见冗余样式 */
                span[style*="font-size"] { font-size: inherit !important; }
                span[style*="font-family"] { font-family: inherit !important; }
                .rich_media_content { max-width: 100% !important; }
                /* 图片加载失败占位样式 */
                img.error-img { 
                    opacity: 0.3; 
                    border: 1px dashed #ccc;
                    min-height: 60px;
                    background: var(--table-bg);
                }
            </style>
            <script>
            // 图片加载失败自动修复：多策略域名替换
            document.addEventListener('DOMContentLoaded', function() {
                var imgs = document.querySelectorAll('img');
                var retryCount = {};
                imgs.forEach(function(img) {
                    img.addEventListener('error', function() {
                        var src = img.getAttribute('data-original-src') || img.src;
                        if (!img.getAttribute('data-original-src')) {
                            img.setAttribute('data-original-src', src);
                        }
                        var count = retryCount[src] || 0;
                        if (count >= 4) {
                            img.classList.add('error-img');
                            return;
                        }
                        retryCount[src] = count + 1;
                        try {
                            var url = new URL(src, window.location.href);
                            // 策略1：尝试用 www.sxjzit.edu.cn 替换其他域名
                            if (count === 0 && url.hostname !== 'www.sxjzit.edu.cn') {
                                url.hostname = 'www.sxjzit.edu.cn';
                                url.port = '';
                                img.src = url.href;
                                return;
                            }
                            // 策略2：尝试用 www2.sxjzit.edu.cn:8082 替换
                            if (count === 1) {
                                url.hostname = 'www2.sxjzit.edu.cn';
                                url.port = '8082';
                                img.src = url.href;
                                return;
                            }
                            // 策略3：尝试去掉端口，使用主站域名
                            if (count === 2) {
                                url.hostname = 'www.sxjzit.edu.cn';
                                url.port = '';
                                img.src = url.href;
                                return;
                            }
                            // 策略4：尝试将路径中的空格和特殊字符编码
                            if (count === 3) {
                                var path = url.pathname;
                                var encodedPath = encodeURI(decodeURI(path));
                                if (encodedPath !== path) {
                                    url.pathname = encodedPath;
                                    img.src = url.href;
                                    return;
                                }
                            }
                        } catch(e) {
                            // URL 解析失败，尝试简单的字符串替换
                            if (count === 0) {
                                img.src = src.replace(/\\/\\/[^\\/]+/, '//www.sxjzit.edu.cn');
                                return;
                            }
                        }
                        img.classList.add('error-img');
                    });
                    // 强制重新加载（处理缓存问题）
                    if (img.complete && img.naturalWidth === 0) {
                        img.dispatchEvent(new Event('error'));
                    }
                });
            });
            </script>
        <style id="sjz-typography">\(displaySettings.articleCSSTypographyRuleBlock)</style>
        </head>
        <body>\(fixedContent)</body>
        </html>
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        private var loadStartTime: Date?
        /// 持有 estimatedProgress KVO 观察，防止提前释放
        private var progressObservation: NSKeyValueObservation?
        /// 排版实时重注入基线（去重：值未变不重复注入；2026-09-29）
        var lastTypographyCSS: String = ""
        /// 最近一次载荷（加载完成后兜底强制覆盖与自检探针使用；2026-09-29）
        var latestTypographyCSS: String = ""

        func retainProgressObservation(_ observation: NSKeyValueObservation) {
            progressObservation?.invalidate()
            progressObservation = observation
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            loadStartTime = Date()
            LogManager.shared.debugLog("organization", "文章 WebView 开始渲染", context: [
                "url": webView.url?.absoluteString ?? "about:blank"
            ])
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 通知进度条收尾（瞬态指示，完成后渐隐）
            NotificationCenter.default.post(
                name: .organizationArticleWebViewProgress,
                object: nil,
                userInfo: ["progress": 1.0, "done": true]
            )
            let elapsed = loadStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            LogManager.shared.info("organization", "文章 WebView 渲染完成", context: [
                "url": webView.url?.absoluteString ?? "about:blank",
                "elapsed": "\(elapsed)ms"
            ])
            // 排版兜底强制 + 自检探针（初始渲染同样走 DOM 级 inline !important 覆盖；2026-09-29）
            if !latestTypographyCSS.isEmpty {
                OrganizationArticleWebView.injectTypography(
                    latestTypographyCSS, into: webView, logTag: "机构文章",
                    probeFamily: DisplaySettingsManager.shared.articleCSSCurrentFamilyName, phase: "load")
            }
            // 检测渲染内容是否为空（空白 WebView 检测）
            // 关键修复：纯图片文章（如招生计划表格图）的 innerText 为空，
            // 必须同时检测 img 标签是否存在，避免误判为空白内容
            webView.evaluateJavaScript("document.body.innerText.trim().length > 0 || document.querySelector('body img') !== null") { result, error in
                let hasContent = (result as? Bool) ?? false
                if !hasContent {
                    LogManager.shared.warning("organization", "文章 WebView 渲染空白内容", context: [
                        "url": webView.url?.absoluteString ?? "about:blank"
                    ])
                    NotificationCenter.default.post(
                        name: .organizationArticleWebViewBlank,
                        object: nil
                    )
                } else {
                    // 检查是否为纯图片内容（用于日志记录）
                    webView.evaluateJavaScript("document.body.innerText.trim().length") { textLenResult, _ in
                        let textLength = (textLenResult as? Int) ?? 0
                        LogManager.shared.debugLog("organization", "文章 WebView 内容正常", context: [
                            "textLength": "\(textLength)",
                            "isImageOnly": "\(textLength == 0)"
                        ])
                    }
                    NotificationCenter.default.post(
                        name: .organizationArticleWebViewLoaded,
                        object: nil
                    )
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LogManager.shared.error("organization", "文章 WebView 渲染失败", context: [
                "error": error.localizedDescription
            ])
            // 即使失败也通知，避免永远显示加载状态
            NotificationCenter.default.post(name: .organizationArticleWebViewLoaded, object: nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LogManager.shared.error("organization", "文章 WebView 预加载失败", context: [
                "error": error.localizedDescription
            ])
            NotificationCenter.default.post(name: .organizationArticleWebViewLoaded, object: nil)
        }
    }
}

extension Notification.Name {
    static let organizationArticleWebViewLoaded = Notification.Name("organizationArticleWebViewLoaded")
    /// WebView 渲染空白内容时发送（用于自动切换到纯文本模式）
    static let organizationArticleWebViewBlank = Notification.Name("organizationArticleWebViewBlank")
    /// WebView estimatedProgress 进度（userInfo: progress Double、done Bool）
    static let organizationArticleWebViewProgress = Notification.Name("organizationArticleWebViewProgress")
}

// MARK: - 兼容旧版 HTMLWebView（保留向后兼容）

/// 保留旧版 HTMLWebView 用于其他模块的原文浏览
struct HTMLWebView: UIViewRepresentable {
    let htmlContent: String
    let title: String
    /// 排版实时重注入载荷（与机构文章 WebView 同链；2026-09-29）
    let typographyCSS: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false

        // 初始化重注入基线：首次打开以内联样式呈现，后续变更由 updateUIView 增量覆盖
        context.coordinator.lastTypographyCSS = typographyCSS
        context.coordinator.latestTypographyCSS = typographyCSS
        let html = buildHTMLPage(content: htmlContent, title: title)
        webView.loadHTMLString(html, baseURL: URL(string: "http://www.sxjzit.edu.cn"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 排版实时重注入（与机构文章 WebView 同链；2026-09-29）
        guard context.coordinator.lastTypographyCSS != typographyCSS else { return }
        context.coordinator.lastTypographyCSS = typographyCSS
        context.coordinator.latestTypographyCSS = typographyCSS
        OrganizationArticleWebView.injectTypography(typographyCSS, into: webView, logTag: "原文浏览",
                                                    probeFamily: DisplaySettingsManager.shared.articleCSSCurrentFamilyName,
                                                    phase: "update")
    }

    func makeCoordinator() -> HTMLWebViewCoordinator {
        HTMLWebViewCoordinator()
    }

    /// 构建完整的 HTML 页面，包含优化的样式
    private func buildHTMLPage(content: String, title: String) -> String {
        // 关键修复：预处理图片URL，确保所有图片使用绝对URL
        let fixedContent = fixImageURLsInHTML(content)
        // 正文配色联动显示设置：明暗双色值注入 CSS 变量（跟随系统时与原默认一致）
        let displaySettings = DisplaySettingsManager.shared
        let textLight = displaySettings.articleCSSTextLightHex
        let textDark = displaySettings.articleCSSTextDarkHex
        var injectionContext: [String: String] = [
            "preset": displaySettings.articleTextColorPreset.rawValue,
            "lightHex": textLight,
            "darkHex": textDark
        ]
        injectionContext.merge(displaySettings.articleCSSTypographyLogContext) { _, new in new }
        LogManager.shared.debugLog("organization", "原文浏览网页配色与排版注入", context: injectionContext)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
            <title>\(title.replacingOccurrences(of: "\"", with: "\\\""))</title>
            <style>
                :root {
                    color-scheme: light dark;
                    --text-color: #\(textLight);
                    --bg-color: transparent;
                    --secondary-text: #666;
                    --border-color: #e5e5e5;
                    --link-color: #007AFF;
                    --table-bg: #f8f9fa;
                    --table-border: #dee2e6;
                    --code-bg: #f4f4f4;
                }
                @media (prefers-color-scheme: dark) {
                    :root {
                        --text-color: #\(textDark);
                        --secondary-text: #aaa;
                        --border-color: #333;
                        --link-color: #4da6ff;
                        --table-bg: #1c1c1e;
                        --table-border: #333;
                        --code-bg: #1c1c1e;
                    }
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    /* 排版联动显示设置：字体家族 / 字号档位 / 行距 / 字距 / 粗体（注入值与下方构建日志 context 一致） */
                    font-family: \(displaySettings.articleCSSFontFamily);
                    font-size: \(String(format: "%.1f", displaySettings.articleCSSFontSize))px;
                    line-height: \(String(format: "%.2f", displaySettings.articleCSSLineHeight));
                    letter-spacing: \(String(format: "%.2f", displaySettings.articleCSSLetterSpacing))px;
                    font-weight: \(displaySettings.articleCSSFontWeight);
                    padding: 16px 16px 40px;
                    color: var(--text-color);
                    background: var(--bg-color);
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                    -webkit-text-size-adjust: 100%;
                }
                img {
                    max-width: 100% !important;
                    height: auto !important;
                    border-radius: 8px;
                    margin: 16px 0;
                    display: block;
                }
                p { margin: 0 0 14px 0; }
                h1 { font-size: 1.375em; font-weight: 700; margin: 24px 0 16px 0; line-height: 1.4; }
                h2 { font-size: 1.1875em; font-weight: 600; margin: 20px 0 14px 0; line-height: 1.4; }
                h3 { font-size: 1.0625em; font-weight: 600; margin: 18px 0 12px 0; line-height: 1.4; }
                h4, h5, h6 { font-size: 1em; font-weight: 600; margin: 16px 0 10px 0; }
                ul, ol { padding-left: 20px; margin: 0 0 14px 0; }
                li { margin-bottom: 6px; }
                blockquote {
                    border-left: 3px solid var(--link-color);
                    padding: 8px 16px;
                    margin: 16px 0;
                    color: var(--secondary-text);
                    background: var(--table-bg);
                    border-radius: 0 6px 6px 0;
                }
                table {
                    width: 100%;
                    max-width: 100%;
                    border-collapse: collapse;
                    margin: 16px 0;
                    font-size: 0.875em;
                    display: block;
                    overflow-x: auto;
                    -webkit-overflow-scrolling: touch;
                }
                table th, table td {
                    border: 1px solid var(--table-border);
                    padding: 8px 12px;
                    text-align: left;
                }
                table th {
                    background: var(--table-bg);
                    font-weight: 600;
                }
                pre, code {
                    font-family: 'SF Mono', 'Menlo', 'Monaco', monospace;
                    font-size: 0.875em;
                    background: var(--code-bg);
                    border-radius: 4px;
                }
                pre {
                    padding: 12px;
                    overflow-x: auto;
                    margin: 16px 0;
                    line-height: 1.5;
                }
                code { padding: 2px 6px; }
                pre code { padding: 0; background: none; }
                a {
                    color: var(--link-color);
                    text-decoration: none;
                }
                hr {
                    border: none;
                    border-top: 1px solid var(--border-color);
                    margin: 24px 0;
                }
                video { max-width: 100%; border-radius: 8px; margin: 16px 0; }
                iframe { max-width: 100%; border-radius: 8px; margin: 16px 0; }
                span[style*="font-size"] { font-size: inherit !important; }
                span[style*="font-family"] { font-family: inherit !important; }
                .rich_media_content { max-width: 100% !important; }
            </style>
        <style id="sjz-typography">\(displaySettings.articleCSSTypographyRuleBlock)</style>
        </head>
        <body>\(fixedContent)</body>
        </html>
        """
    }

    class HTMLWebViewCoordinator: NSObject, WKNavigationDelegate {
        /// 排版实时重注入基线（去重；2026-09-29）
        var lastTypographyCSS: String = ""
        /// 最近一次载荷（加载完成后兜底强制覆盖与自检探针；2026-09-29）
        var latestTypographyCSS: String = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            LogManager.shared.debugLog("organization", "文章原文 WebView 加载完成")
            // 排版兜底强制 + 自检探针（初始渲染同样走 DOM 级 inline !important 覆盖；2026-09-29）
            if !latestTypographyCSS.isEmpty {
                OrganizationArticleWebView.injectTypography(
                    latestTypographyCSS, into: webView, logTag: "原文浏览",
                    probeFamily: DisplaySettingsManager.shared.articleCSSCurrentFamilyName, phase: "load")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LogManager.shared.error("organization", "文章原文 WebView 加载失败", context: [
                "error": error.localizedDescription
            ])
        }
    }
}

// MARK: - 快速 HTML 剥离（纯正则，无 NSAttributedString 风险）

extension String {
    /// 快速 HTML 标签剥离 —— 纯正则实现，绝不使用 NSAttributedString
    /// 避免 NSAttributedString 在大型/复杂 HTML 上卡死的问题
    /// 线程安全，可在任意队列调用
    func strippingHTMLTagsFast() -> String {
        guard !self.isEmpty else { return self }

        // 如果不包含 HTML 标签，快速返回
        if !self.contains("<") {
            return self
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
        }

        var result = self

        // 1. 移除 script/style 标签及其内容
        result = result.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )

        // 2. 替换块级标签为换行符（保留段落结构）
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
                         "</li>", "</tr>", "<br>", "<br/>", "<br />"]
        for tag in blockTags {
            result = result.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // 3. 移除所有 HTML 标签
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // 4. 解码 HTML 实体
        result = result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201c}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201d}")
            .replacingOccurrences(of: "&mdash;", with: "\u{2014}")
            .replacingOccurrences(of: "&ndash;", with: "\u{2013}")

        // 5. 清理多余空白
        result = result.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保留旧方法名以兼容其他调用方，内部使用快速实现
    func strippingHTMLTagsOptimized() -> String {
        strippingHTMLTagsFast()
    }

    /// 检查 HTML 内容是否包含图片标签（纯图片文章的有效性检测）
    /// 招生计划、报考指南等文章内容为纯 HTML 图片，纯文本长度为 0，
    /// 但仍然是有效内容，不应被误判为空
    var hasImageContent: Bool {
        range(of: "<img[\\s>]", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// 安全地创建 URL，处理中文和空格等特殊字符
/// 使用与 safeImageURL 一致的全面字符集，确保 URL 编码正确
/// - Parameter urlString: 原始 URL 字符串
/// - Returns: 编码后的 URL，如果编码失败则返回 nil
private func safeURL(from urlString: String) -> URL? {
    // 先尝试直接创建（纯 ASCII URL）
    if let url = URL(string: urlString) {
        return url
    }
    // 使用全面的字符集进行编码（与 safeImageURL 保持一致）
    var allowed = CharacterSet.urlPathAllowed
    allowed.formUnion(.urlHostAllowed)
    allowed.formUnion(.urlQueryAllowed)
    allowed.formUnion(.urlFragmentAllowed)
    allowed.insert(charactersIn: "%")
    if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowed) {
        return URL(string: encoded)
    }
    return nil
}

// MARK: - 优化的图片提取（异步安全）

/// 从 HTML 中提取图片 URL（线程安全，可后台调用）
private func extractImagesOptimized(from html: String) -> [DataService.ArticleImage] {
    var images: [DataService.ArticleImage] = []
    var seenURLs = Set<String>()
    let pattern = #"<img[^>]+src=["']([^"']+)["'][^>]*(?:alt=["']([^"']*)["'])?[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
        return images
    }
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
        guard let match = match else { return }
        let srcRange = match.range(at: 1)
        if srcRange.location != NSNotFound, let srcRange = Range(srcRange, in: html) {
            let rawUrl = String(html[srcRange])
            // 过滤本地文件路径和无效 URL
            if rawUrl.hasPrefix("file://") || rawUrl.hasPrefix("data:") || rawUrl.isEmpty { return }
            let url = safeImageURL(from: rawUrl)
            // 去重：避免同一图片多次出现
            let normalizedURL = url.lowercased()
            if seenURLs.contains(normalizedURL) { return }
            seenURLs.insert(normalizedURL)
            var alt: String? = nil
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
               let altRange = Range(match.range(at: 2), in: html) {
                alt = String(html[altRange])
            }
            images.append(DataService.ArticleImage(url: url, alt: alt))
        }
    }
    Task { @MainActor in
        LogManager.shared.debugLog("organization", "图片提取完成", context: [
        "imageCount": "\(images.count)",
        "firstImageURL": String(images.first?.url.prefix(80) ?? "none")
    ])
    }
    return images
}

/// 对图片 URL 进行安全编码
private func safeImageURL(from string: String) -> String {
    var urlString = string
    if urlString.hasPrefix("/") {
        if urlString.hasPrefix("//") {
            urlString = "https:" + urlString
        } else {
            urlString = SchoolInfo.website + urlString
        }
    } else if !urlString.contains("://") {
        urlString = SchoolInfo.website + "/" + urlString
    }
    if URL(string: urlString) != nil { return urlString }
    var allowed = CharacterSet.urlPathAllowed
    allowed.formUnion(.urlHostAllowed)
    allowed.formUnion(.urlQueryAllowed)
    allowed.formUnion(.urlFragmentAllowed)
    allowed.insert(charactersIn: "%")
    return urlString.addingPercentEncoding(withAllowedCharacters: allowed) ?? urlString
}

// MARK: - 子标签详情视图

/// 子标签详情视图 —— 展示子标签下的文章列表
/// 支持点击文章查看详情，完整日志埋点
/// 使用 sheet(item:) 替代 sheet(isPresented:) 确保状态安全
struct ChildSectionDetailView: View {
    let child: OrgChildSection
    let siteId: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var articleNavigation: ArticleNavigation?

    // MARK: 分页加载状态
    @State private var articles: [OrgArticle] = []
    @State private var currentPage = 1
    @State private var isLoadingMore = false
    @State private var hasMoreArticles = true
    @State private var loadError: String?
    @State private var totalCount = 0
    /// 非结构化加载任务句柄（对齐父视图做法：承载拉取，脱离 .refreshable 动作的取消域）
    @State private var loadTask: Task<Void, Never>?
    /// 子标签的实际 siteId（优先使用 child 自身的 siteId，否则用传入的 siteId）
    private var childSiteId: String {
        child.siteId ?? siteId
    }

    var body: some View {
        ScrollView {
            if articles.isEmpty && isLoadingMore {
                loadingView
            } else if articles.isEmpty && !isLoadingMore {
                emptyView
            } else {
                articleListView
            }
        }
        .refreshable {
            // 下拉刷新：重置并重新加载。拉取用非结构化 Task 承载，避免被 .refreshable 动作取消（对齐父视图）
            currentPage = 1
            hasMoreArticles = true
            loadError = nil
            await performLoad()
            LogManager.shared.info("organization", "子标签下拉刷新", context: [
                "child": child.title
            ])
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(child.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                    LogManager.shared.debugLog("organization", "子标签详情页关闭", context: [
                        "child": child.title
                    ])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .displaySymbolFont(20)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
        }
        .sheet(item: $articleNavigation) { nav in
            NavigationStack {
                OrganizationArticleDetailView(
                    article: nav.article,
                    siteId: nav.siteId,
                    color: nav.color
                )
            }
            .sjzPresentationChrome()
        }
        .task {
            await performLoad()
        }
        .onAppear {
            LogManager.shared.info("organization", "子标签详情页打开", context: [
                "child": child.title,
                "initialArticleCount": "\(child.articles.count)",
                "siteId": siteId,
                "columnId": child.columnId ?? "nil"
            ])
        }
    }

    // MARK: 加载视图

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.1)
            Text("加载文章中...")
                .displayFont(14)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: 空状态

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            Image(systemName: "tray")
                .displaySymbolFont(44)
                .foregroundStyle(.secondary)

            Text("暂无内容")
                .displayFont(16, weight: .medium)
                .foregroundStyle(.primary)

            if let error = loadError {
                Text(error)
                    .displayFont(13)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("该栏目暂无文章，请稍后再试")
                    .displayFont(13)
                    .foregroundStyle(.secondary)
            }

            // 在官网查看按钮
            if let detailURL = URL(string: "https://www.sxjzit.edu.cn/#/list/more?type=specialty&site_id=cb3b1fe4fcdf40999b0c162015c3326d&column_id=\(child.columnId ?? "")") {
                Link(destination: detailURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .displaySymbolFont(13)
                        Text("在官网查看「\(child.title)」")
                            .displayFont(13, weight: .medium)
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .stroke(color.opacity(0.4), lineWidth: 1)
                    )
                }
            }

            Button {
                Task {
                    loadError = nil
                    currentPage = 1
                    hasMoreArticles = true
                    await loadArticles()
                }
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
                    .displayLabelFont(13, weight: .medium)
            }
            .buttonStyle(.bordered)
            .contentShape(Rectangle())

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: 文章列表

    private var articleListView: some View {
        LazyVStack(spacing: 10) {
            // 文章总数提示
            if totalCount > 0 {
                HStack {
                    Text("共 \(totalCount) 篇文章")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("已加载 \(articles.count) 篇")
                        .displayFont(12)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
            }

            ForEach(articles) { article in
                childArticleCard(article)
            }

            // 加载更多按钮
            if hasMoreArticles {
                loadMoreButton
            } else if !articles.isEmpty && loadError == nil && !isLoadingMore {
                // 已加载全部
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(.green)
                    Text("已加载全部文章")
                        .displayFont(12)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }

            // 错误提示
            if let error = loadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(Color.sjzOrange)
                    Text(error)
                        .displayFont(12)
                        .foregroundStyle(Color.sjzOrange)
                    Button {
                        loadError = nil
                        Task { await loadMoreArticles() }
                    } label: {
                        Text("重试")
                            .displayFont(12, weight: .medium)
                            .foregroundStyle(color)
                    }
                    .contentShape(Rectangle())
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
    }

    // MARK: 加载更多按钮

    private var loadMoreButton: some View {
        Button {
            Task { await loadMoreArticles() }
        } label: {
            HStack(spacing: 8) {
                if isLoadingMore {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("加载中...")
                        .displayFont(13)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .displaySymbolFont(13)
                    Text("加载更多文章")
                        .displayFont(13, weight: .medium)
                }
            }
            .foregroundStyle(isLoadingMore ? .secondary : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(isLoadingMore)
    }

    // MARK: 文章卡片

    private func childArticleCard(_ article: OrgArticle) -> some View {
        Button {
            let actualSiteId = article.sectionSiteId ?? childSiteId
            LogManager.shared.info("organization", "子标签文章点击", context: [
                "child": child.title,
                "articleId": article.articleId,
                "title": article.title,
                "siteId": actualSiteId,
                "articleSiteId": article.sectionSiteId ?? "nil"
            ])
            articleNavigation = ArticleNavigation(
                article: article,
                siteId: actualSiteId,
                color: color
            )
        } label: {
            HStack(spacing: 12) {
                // 缩略图
                if let imageUrl = article.imageUrl, !imageUrl.isEmpty,
                   !imageUrl.contains("no_picture") {
                    SJZCachedImage(url: safeURL(from: imageUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            childPlaceholderIcon
                        default:
                            childPlaceholderIcon
                        }
                    }
                } else {
                    childPlaceholderIcon
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title)
                        .displayFont(14, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !article.description.isEmpty {
                        Text(article.description)
                            .displayFont(12)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack {
                        if !article.tag.isEmpty {
                            Text(article.tag)
                                .displayFont(10)
                                .foregroundStyle(color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(color.opacity(0.1))
                                )
                        }
                        Spacer()
                        Text(formatDate(article.updateTime))
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
                    .stroke(color.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.03), radius: 6, y: 3)
        }
        .buttonStyle(OrganizationCardButtonStyle())
        .contentShape(Rectangle())
    }

    private var childPlaceholderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.12))
                .frame(width: 56, height: 56)
            Image(systemName: "doc.text.image")
                .displaySymbolFont(16)
                .foregroundStyle(color.opacity(0.4))
        }
    }

    // MARK: 文章加载逻辑

    /// 用非结构化 Task 承载加载，防止被 SwiftUI 的 .refreshable / .task 动作取消所中断。
    /// 这是解决下拉刷新 `error=cancelled` 的关键：拉取必须在独立于刷新动作的任务中运行。
    private func performLoad() async {
        loadTask?.cancel()
        let task = Task { await loadArticles() }
        loadTask = task
        await task.value
    }

    /// 初始加载：合并已有文章 + API 加载更多
    private func loadArticles() async {
        // 仅首次加载时用初始数据填充；刷新时保留已有列表，避免 body 分支切换导致的 .refreshable 自我取消
        if articles.isEmpty {
            articles = child.articles
            LogManager.shared.debugLog("organization", "子标签初始文章加载", context: [
                "child": child.title,
                "count": "\(articles.count)"
            ])
        }

        // 如果有 columnId，从 API 加载更多文章
        guard let columnId = child.columnId, !columnId.isEmpty else {
            if articles.isEmpty {
                loadError = "该栏目暂无更多文章"
            }
            hasMoreArticles = false
            LogManager.shared.info("organization", "子标签无 columnId，仅显示初始文章", context: [
                "child": child.title,
                "articleCount": "\(articles.count)"
            ])
            return
        }

        // 始终从第1页开始加载，确保数据完整（dept/home2 可能未返回所有文章）
        await loadMoreArticles(startPage: 1)
    }

    /// 加载更多文章
    private func loadMoreArticles(startPage: Int? = nil) async {
        guard !isLoadingMore else { return }
        guard let columnId = child.columnId, !columnId.isEmpty else {
            hasMoreArticles = false
            return
        }

        isLoadingMore = true
        loadError = nil

        let page = startPage ?? (currentPage + 1)
        let startTime = Date()

        // 关键修复：构建 siteId 尝试列表，优先使用 childSiteId，然后尝试 ZSW siteId 和主站 siteId
        var siteIdsToTry: [String] = [childSiteId]
        if childSiteId != zswSiteId { siteIdsToTry.append(zswSiteId) }
        if childSiteId != "1" && !siteIdsToTry.contains("1") { siteIdsToTry.append("1") }
        // 去重
        siteIdsToTry = Array(NSOrderedSet(array: siteIdsToTry)) as! [String]

        LogManager.shared.info("organization", "子标签分页加载开始", context: [
            "child": child.title,
            "columnId": columnId,
            "page": "\(page)",
            "siteIds": siteIdsToTry.joined(separator: ", "),
            "currentCount": "\(articles.count)"
        ])

        var lastError: Error?
        var bestResult: (fetchedArticles: [OrgArticle], total: Int, usedSiteId: String)?

        for sid in siteIdsToTry {
            if Task.isCancelled { break }
            do {
                let result = try await withTimeout(seconds: 12) {
                    try await NetworkService.shared.fetchArticles(
                        columnId: columnId,
                        siteId: sid,
                        page: page,
                        size: 20
                    )
                }

                let fetchedArticles = (result.articles?.list ?? []).compactMap { dto -> OrgArticle? in
                    guard let id = dto.id, let title = dto.resolvedTitle, !title.isEmpty else { return nil }
                    return OrgArticle(
                        id: id,
                        title: title,
                        description: dto.description ?? "",
                        imageUrl: dto.imageUrl,
                        updateTime: dto.updateTime ?? "",
                        tag: dto.tag ?? "",
                        articleId: id,
                        sectionSiteId: sid
                    )
                }

                let total = result.articles?.total ?? 0

                if !fetchedArticles.isEmpty {
                    bestResult = (fetchedArticles, total, sid)
                    LogManager.shared.info("organization", "子标签siteId尝试成功", context: [
                        "child": child.title,
                        "siteId": sid,
                        "page": "\(page)",
                        "fetched": "\(fetchedArticles.count)",
                        "total": "\(total)"
                    ])
                    break
                } else {
                    LogManager.shared.warning("organization", "子标签siteId返回空结果，尝试下一个", context: [
                        "child": child.title,
                        "siteId": sid,
                        "page": "\(page)"
                    ])
                }
            } catch is CancellationError {
                // 任务被取消（页面关闭/刷新重入），静默退出，不记录为失败
            } catch let e as URLError where e.code == .cancelled {
                // 网络请求被取消，静默退出
            } catch {
                lastError = error
                LogManager.shared.warning("organization", "子标签siteId请求失败，尝试下一个", context: [
                    "child": child.title,
                    "siteId": sid,
                    "page": "\(page)",
                    "error": error.localizedDescription
                ])
            }
        }

        // 若任务被取消（页面关闭/刷新重入），静默结束，不设置错误提示
        if Task.isCancelled {
            isLoadingMore = false
            return
        }

        if let result = bestResult {
            let fetchedArticles = result.fetchedArticles
            let total = result.total
            let usedSiteId = result.usedSiteId
            totalCount = total
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            if page == 1 {
                let existingIds = Set(articles.map { $0.id })
                let newArticles = fetchedArticles.filter { !existingIds.contains($0.id) }
                articles = fetchedArticles
                LogManager.shared.info("organization", "子标签首页加载完成", context: [
                    "child": child.title,
                    "total": "\(total)",
                    "fetched": "\(fetchedArticles.count)",
                    "newAdded": "\(newArticles.count)",
                    "usedSiteId": usedSiteId,
                    "elapsed": "\(elapsed)ms"
                ])
            } else {
                let existingIds = Set(articles.map { $0.id })
                let newArticles = fetchedArticles.filter { !existingIds.contains($0.id) }
                articles.append(contentsOf: newArticles)
                LogManager.shared.info("organization", "子标签分页加载完成", context: [
                    "child": child.title,
                    "page": "\(page)",
                    "total": "\(total)",
                    "fetched": "\(fetchedArticles.count)",
                    "newAdded": "\(newArticles.count)",
                    "usedSiteId": usedSiteId,
                    "elapsed": "\(elapsed)ms"
                ])
            }

            currentPage = page
            hasMoreArticles = articles.count < total && fetchedArticles.count >= 20
            loadError = nil
        } else {
            // 所有 siteId 都返回空结果或失败
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            // 关键修复：如果所有 siteId 都返回空结果（无实际错误），标记为无更多文章
            if lastError == nil {
                LogManager.shared.info("organization", "子标签分页加载完成（所有siteId返回空结果，无更多文章）", context: [
                    "child": child.title,
                    "page": "\(page)",
                    "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                    "elapsed": "\(elapsed)ms"
                ])
                hasMoreArticles = false
                loadError = nil // 不显示错误，只是没有更多数据
            } else if lastError is TimeoutError {
                hasMoreArticles = false
                loadError = "加载超时，请稍后重试"
                LogManager.shared.error("organization", "子标签分页加载超时（所有siteId）", context: [
                    "child": child.title,
                    "page": "\(page)",
                    "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                    "elapsed": "\(elapsed)ms"
                ])
            } else if lastError is URLError {
                let urlError = lastError as! URLError
                hasMoreArticles = false
                loadError = "网络异常，请检查网络后重试"
                LogManager.shared.error("organization", "子标签分页加载网络失败（所有siteId）", context: [
                    "child": child.title,
                    "page": "\(page)",
                    "error": urlError.localizedDescription,
                    "triedSiteIds": siteIdsToTry.joined(separator: ", ")
                ])
            } else if let networkError = lastError as? NetworkError {
                switch networkError {
                case .noData:
                    // API 返回 data: null，表示该栏目无数据，非真正的加载失败
                    hasMoreArticles = false
                    loadError = nil
                    LogManager.shared.info("organization", "子标签数据为空（所有siteId返回null）", context: [
                        "child": child.title,
                        "page": "\(page)",
                        "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                        "elapsed": "\(elapsed)ms"
                    ])
                case .serverError(let msg):
                    hasMoreArticles = false
                    loadError = "服务器繁忙，请稍后重试"
                    LogManager.shared.error("organization", "子标签分页加载服务器错误（所有siteId）", context: [
                        "child": child.title,
                        "page": "\(page)",
                        "error": msg,
                        "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                        "elapsed": "\(elapsed)ms"
                    ])
                default:
                    hasMoreArticles = false
                    loadError = "加载失败，请稍后重试"
                    LogManager.shared.error("organization", "子标签分页加载异常（所有siteId）", context: [
                        "child": child.title,
                        "page": "\(page)",
                        "error": networkError.errorDescription ?? "unknown",
                        "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                        "elapsed": "\(elapsed)ms"
                    ])
                }
            } else {
                hasMoreArticles = false
                loadError = "加载失败，请稍后重试"
                LogManager.shared.error("organization", "子标签分页加载异常（所有siteId）", context: [
                    "child": child.title,
                    "page": "\(page)",
                    "error": lastError?.localizedDescription ?? "unknown",
                    "triedSiteIds": siteIdsToTry.joined(separator: ", "),
                    "elapsed": "\(elapsed)ms"
                ])
            }
        }

        isLoadingMore = false
    }

    private func formatDate(_ raw: String) -> String {
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
}

// MARK: - 预览

#Preview("机构详情 - 浅色") {
    NavigationStack {
        OrganizationDetailView(
            unit: OrganizationUnit(
                name: "教务处",
                category: .administrative,
                siteKey: "jwc",
                icon: "book.pages.fill"
            )
        )
    }
    .preferredColorScheme(.light)
}

#Preview("机构详情 - 深色") {
    NavigationStack {
        OrganizationDetailView(
            unit: OrganizationUnit(
                name: "教务处",
                category: .administrative,
                siteKey: "jwc",
                icon: "book.pages.fill"
            )
        )
    }
    .preferredColorScheme(.dark)
}