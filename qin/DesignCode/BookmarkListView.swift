//
//  BookmarkListView.swift
//  山西晋中理工学院 APP — 我的收藏页面
//
//  支持列表浏览、批量取消收藏、空状态提示、离线可用。
//  适配浅色/深色模式，与现有 App 风格统一。
//

import SwiftUI

// MARK: - 我的收藏页面

struct BookmarkListView: View {
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @ObservedObject private var readManager = ReadStatusManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isBatchMode = false
    @State private var selectedKeys: Set<String> = []
    @State private var showClearAllAlert = false
    @State private var showDeleteSelectedAlert = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        Group {
            if bookmarkManager.bookmarks.isEmpty {
                emptyState
            } else {
                bookmarkContent
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("确认清空全部收藏？", isPresented: $showClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    bookmarkManager.clearAll()
                    isBatchMode = false
                    selectedKeys.removeAll()
                }
            }
        } message: {
            Text("将移除全部 \(bookmarkManager.count) 篇收藏文章，此操作不可恢复。")
        }
        .alert("确认取消收藏？", isPresented: $showDeleteSelectedAlert) {
            Button("取消", role: .cancel) {}
            Button("确认取消", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    bookmarkManager.removeBookmarks(selectedKeys)
                    selectedKeys.removeAll()
                    isBatchMode = false
                }
            }
        } message: {
            Text("将取消收藏选中的 \(selectedKeys.count) 篇文章。")
        }
        .alert("收藏上限", isPresented: $bookmarkManager.showLimitAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(bookmarkManager.limitAlertMessage)
        }
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
            }
            VStack(spacing: 8) {
                Text("暂无收藏")
                    .displayFont(20, weight: .semibold)
                    .foregroundStyle(.primary)
                Text("在文章列表或详情页点击收藏按钮\n即可将文章添加到收藏")
                    .displayFont(14)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 收藏内容

    private var bookmarkContent: some View {
        VStack(spacing: 0) {
            // 批量模式工具栏
            if isBatchMode {
                batchToolbar
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(bookmarkManager.bookmarks) { bookmark in
                        bookmarkCard(bookmark)
                            .id(bookmark.readKey)  // 视图级身份隔离：杜绝 LazyVGrid 跨卡片串数据
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // 底部信息
                bottomInfo
            }
        }
    }

    // MARK: 批量操作工具栏

    private var batchToolbar: some View {
        HStack(spacing: 0) {
            // 全选/取消全选
            Button {
                if selectedKeys.count == bookmarkManager.bookmarks.count {
                    selectedKeys.removeAll()
                } else {
                    selectedKeys = Set(bookmarkManager.bookmarks.map { $0.readKey })
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedKeys.count == bookmarkManager.bookmarks.count
                          ? "checkmark.circle.fill" : "circle")
                        .displaySymbolFont(16)
                    Text(selectedKeys.count == bookmarkManager.bookmarks.count ? "取消全选" : "全选")
                        .displayFont(14, weight: .medium)
                }
                .foregroundStyle(Color.sjzAccent)
            }

            Spacer()

            Text("已选 \(selectedKeys.count) 篇")
                .displayFont(13)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                if !selectedKeys.isEmpty {
                    showDeleteSelectedAlert = true
                }
            } label: {
                Label("取消收藏", systemImage: "trash")
                    .displayLabelFont(14, weight: .medium)
                    .foregroundColor(selectedKeys.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(
                        selectedKeys.isEmpty
                        ? Color.gray.opacity(0.15)
                        : Color.red.opacity(0.12),
                        in: Capsule()
                    )
            }
            .disabled(selectedKeys.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 收藏卡片

    @ViewBuilder
    private func bookmarkCard(_ bookmark: BookmarkItem) -> some View {
        let cardContent = bookmarkCardBody(bookmark)

        if isBatchMode {
            cardContent
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleSelection(bookmark.readKey)
                        }
                }
        } else {
            NavigationLink {
                EnhancedNewsDetailView(news: bookmark.toNewsItem())
            } label: {
                cardContent
            }
            .buttonStyle(.plain)
        }
    }

    /// 卡片主体内容（不含交互层）
    private func bookmarkCardBody(_ bookmark: BookmarkItem) -> some View {
        VStack(spacing: 0) {
            // 缩略图
            BookmarkThumbnailView(imageUrl: bookmark.imageUrl, category: bookmark.category)

            // 信息区
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    CategoryBadge(category: bookmark.category)
                    Spacer()
                    Text(bookmark.date)
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                }

                Text(bookmark.title)
                    .displayFont(13, weight: .semibold)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text(bookmark.summary)
                    .displayFont(11)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                // 缓存状态
                if bookmarkManager.autoCacheContent {
                    HStack(spacing: 4) {
                        Image(systemName: bookmark.contentCached ? "checkmark.icloud.fill" : "icloud.slash")
                            .displaySymbolFont(9)
                        Text(bookmark.contentCached ? "已缓存" : "未缓存")
                            .displayFont(9)
                    }
                    .foregroundStyle(bookmark.contentCached ? Color.sjzGreen : .secondary)
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .overlay(alignment: .topLeading) {
            // 未读蓝点
            if !readManager.isRead(bookmark.readKey) {
                Circle()
                    .fill(Color.sjzAccent)
                    .frame(width: 8, height: 8)
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            // 批量选择 / 取消收藏按钮
            if isBatchMode {
                ZStack {
                    Circle()
                        .fill(selectedKeys.contains(bookmark.readKey) ? Color.sjzAccent : Color.white.opacity(0.9))
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    if selectedKeys.contains(bookmark.readKey) {
                        Image(systemName: "checkmark")
                            .displaySymbolFont(12, weight: .bold)
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
                .allowsHitTesting(false)  // 不拦截父级卡片点击
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        bookmarkManager.removeBookmark(bookmark.readKey)
                    }
                } label: {
                    Image(systemName: "bookmark.fill")
                        .displaySymbolFont(12)
                        .foregroundStyle(Color.sjzGold)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                }
                .padding(8)
            }
        }
    }

    // MARK: 底部信息

    private var bottomInfo: some View {
        HStack(spacing: 4) {
            Image(systemName: "bookmark.fill")
                .displaySymbolFont(10)
                .foregroundStyle(Color.sjzGold)
            Text("共 \(bookmarkManager.count) 篇收藏")
                .displayFont(12)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isBatchMode {
                Button("完成") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isBatchMode = false
                        selectedKeys.removeAll()
                    }
                }
                .displayFont(15, weight: .medium)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                if !bookmarkManager.bookmarks.isEmpty {
                    if !isBatchMode {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isBatchMode = true
                            }
                        } label: {
                            Image(systemName: "checklist")
                                .displaySymbolFont(14, weight: .medium)
                        }
                    }
                    Button {
                        showClearAllAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .displaySymbolFont(14, weight: .medium)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: 辅助方法

    private func toggleSelection(_ key: String) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "学校要闻": return Color.sjzRed
        case "新闻资讯": return Color.sjzAccent
        case "党建动态": return Color.sjzRed
        case "通知公告": return Color.sjzOrange
        case "招生信息": return Color.sjzGreen
        case "院部动态": return Color.sjzPurple
        case "招生就业": return Color.sjzTeal
        default: return Color.sjzAccent
        }
    }
}

// MARK: - 收藏缩略图组件

/// 收藏缩略图组件：使用 .task(id:) 驱动异步图片加载，确保 LazyVGrid 视图复用时
/// 每张卡片加载各自独立的封面图，彻底杜绝串图问题。
///
/// 设计原则（参考 Apple Photos / News / App Store 最佳实践）：
/// 1. .task(id:) 是 Apple 官方推荐的异步操作随身份变化而重启的方式（WWDC 2022-2024）
/// 2. @State 驱动的显式状态机消除 AsyncImage 内部缓存的模糊性
/// 3. 统一 4:3 宽高比 + scaledToFill + clipped，确保所有缩略图尺寸一致，杜绝错乱
/// 4. 图片加载成功后通过 opacity 动画淡入，避免突兀的闪现
/// 5. 后台异步填充 BookmarkManager 缓存供离线使用
/// 6. 检测 Task 取消状态，避免视图已复用后仍更新旧状态
struct BookmarkThumbnailView: View {
    let imageUrl: String?
    let category: String

    @ObservedObject private var bookmarkManager = BookmarkManager.shared

    @State private var loadedImage: UIImage?
    @State private var phase: LoadPhase = .loading

    /// 统一的缩略图宽高比 —— 4:3，与 Apple News / App Store 卡片一致
    private static let thumbnailAspectRatio: CGFloat = 4.0 / 3.0

    private enum LoadPhase {
        case loading, success, failure
    }

    var body: some View {
        Group {
            switch phase {
            case .success:
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(Self.thumbnailAspectRatio, contentMode: .fill)
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                } else {
                    placeholderView
                }
            case .failure:
                placeholderView
            case .loading:
                ShimmerView()
                    .aspectRatio(Self.thumbnailAspectRatio, contentMode: .fill)
            }
        }
        .clipped()
        .task(id: imageUrl) {
            await loadImage()
        }
    }

    // MARK: 图片加载

    private func loadImage() async {
        // 空 URL 直接显示占位图
        guard let imgUrl = imageUrl,
              !imgUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: imgUrl) else {
            withAnimation(.easeInOut(duration: 0.2)) {
                loadedImage = nil
                phase = .failure
            }
            return
        }

        // 优先从 BookmarkManager 两级缓存（内存 + 磁盘）读取
        if let cached = bookmarkManager.cachedImage(for: imgUrl) {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                loadedImage = cached
                phase = .success
            }
            return
        }

        // 重置状态，避免展示旧视图数据
        loadedImage = nil
        phase = .loading

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let image = UIImage(data: data) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    loadedImage = image
                    phase = .success
                }
                // 后台填充缓存，供离线场景使用
                Task {
                    await bookmarkManager.cacheImage(from: imgUrl)
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    phase = .failure
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                phase = .failure
            }
        }
    }

    // MARK: 占位图

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(
                    colors: [categoryColor(category).opacity(0.2), categoryColor(category).opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "newspaper.fill")
                .displaySymbolFont(28)
                .foregroundStyle(categoryColor(category).opacity(0.3))
        }
        .aspectRatio(Self.thumbnailAspectRatio, contentMode: .fill)
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "学校要闻": return Color.sjzRed
        case "新闻资讯": return Color.sjzAccent
        case "党建动态": return Color.sjzRed
        case "通知公告": return Color.sjzOrange
        case "招生信息": return Color.sjzGreen
        case "院部动态": return Color.sjzPurple
        case "招生就业": return Color.sjzTeal
        default: return Color.sjzAccent
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