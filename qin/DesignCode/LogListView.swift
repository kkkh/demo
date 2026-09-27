//
//  LogListView.swift
//  山西晋中理工学院 APP — 日志查看页面
//
//  分段筛选、关键词搜索、长日志折叠展开、长按复制、
//  一键导出 .txt、一键清空（二次确认）。
//

import SwiftUI
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
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLevel: LogLevel? = nil  // nil = 全部
    @State private var searchText = ""
    @State private var expandedIds: Set<String> = []
    @State private var showClearAlert = false
    /// 导出数据：非 nil 时自动弹出分享 sheet，数据完全就绪后才触发
    @State private var exportData: ExportData? = nil
    @State private var copiedId: String?

    private var filteredEntries: [LogEntry] {
        var result = logManager.entries
        if let level = selectedLevel {
            result = result.filter { $0.level == level }
        }
        if !searchText.isEmpty {
            result = logManager.search(query: searchText, in: result)
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // 分段筛选
            levelFilterBar

            // 搜索框
            searchBar

            // 日志列表
            if filteredEntries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("确认清空全部日志？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    logManager.clearAll()
                }
            }
        } message: {
            Text("将清空全部 \(logManager.entries.count) 条日志，此操作不可恢复。")
        }
        .sheet(item: $exportData) { data in
            ExportSheetView(text: data.text, fileName: data.fileName)
                .sjzPresentationChrome()
        }
        .biometricLockProtected(reason: "sensitive_logs")
    }

    // MARK: 分段筛选

    private var levelFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "全部", count: logManager.entries.count, isSelected: selectedLevel == nil, color: .primary) {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedLevel = nil }
                }
                ForEach(LogLevel.allCases, id: \.self) { level in
                    FilterChip(
                        label: levelDisplayName(level),
                        count: logManager.entries.filter { $0.level == level }.count,
                        isSelected: selectedLevel == level,
                        color: level.color
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedLevel = selectedLevel == level ? nil : level
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索关键词、URL、文章ID、错误码...", text: $searchText)
                .displaySymbolFont(14)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: 日志列表

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                    LogRowView(
                        entry: entry,
                        isExpanded: expandedIds.contains(entry.id),
                        isCopied: copiedId == entry.id,
                        onToggle: { toggleExpand(entry.id) },
                        onCopy: { copyEntry(entry) }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden)
                    .id(entry.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: selectedLevel) { _, _ in
                if let first = filteredEntries.first {
                    withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .displaySymbolFont(48)
                .foregroundStyle(.secondary.opacity(0.4))
            Text(searchText.isEmpty ? "暂无日志" : "未找到匹配的日志")
                .displayFont(16, weight: .medium)
                .foregroundStyle(.secondary)
            if !searchText.isEmpty {
                Button("清除搜索") { searchText = "" }
                    .displayFont(13)
            }
            Spacer()
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    let text = logManager.exportAsText()
                    exportData = ExportData(text: text, fileName: "sxjzit_logs_\(dateStamp()).txt")
                } label: {
                    Label("导出全部日志", systemImage: "square.and.arrow.up")
                }
                Button {
                    copyAllToClipboard()
                } label: {
                    Label("复制全部日志", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) {
                    showClearAlert = true
                } label: {
                    Label("清空全部日志", systemImage: "trash")
                }
                .disabled(logManager.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .displaySymbolFont(16, weight: .medium)
            }
        }
    }

    // MARK: 辅助

    private func levelDisplayName(_ level: LogLevel) -> String {
        switch level {
        case .info:    return "信息"
        case .debug:   return "调试"
        case .warning: return "警告"
        case .error:   return "错误"
        case .fatal:   return "崩溃"
        }
    }

    private func toggleExpand(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedIds.contains(id) {
                expandedIds.remove(id)
            } else {
                expandedIds.insert(id)
            }
        }
    }

    private func copyEntry(_ entry: LogEntry) {
        UIPasteboard.general.string = entry.formattedLine
        copiedId = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedId == entry.id { copiedId = nil }
        }
    }

    private func copyAllToClipboard() {
        UIPasteboard.general.string = logManager.exportAsText()
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - 筛选标签

private struct FilterChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let color: Color
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
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isSelected ? color : color.opacity(0.1), in: Capsule())
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 日志行

private struct LogRowView: View {
    let entry: LogEntry
    let isExpanded: Bool
    let isCopied: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 顶部：级别标签 + 时间
            HStack(spacing: 6) {
                Text(entry.level.rawValue)
                    .displayFont(9, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(entry.level.color, in: Capsule())

                Text(entry.module)
                    .displayFont(10, weight: .medium)
                    .foregroundStyle(entry.level.color.opacity(0.7))

                Spacer()

                Text(entry.formattedTime)
                    .displayFont(10, design: .monospaced)
                    .foregroundStyle(.secondary)
            }

            // 消息正文
            Text(entry.message)
                .displayFont(13)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 3)
                .multilineTextAlignment(.leading)

            // 上下文信息
            if let ctx = entry.context, !ctx.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ctx.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 4) {
                            Text(key)
                                .displayFont(9, weight: .medium)
                                .foregroundStyle(.secondary)
                            Text(value)
                                .displayFont(9, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(8)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            // 底部操作
            if entry.message.count > 120 || (entry.context?.isEmpty == false) {
                HStack(spacing: 12) {
                    Button {
                        onToggle()
                    } label: {
                        Label(isExpanded ? "收起" : "展开", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .displayLabelFont(10)
                            .foregroundStyle(entry.level.color)
                    }
                    .contentShape(Rectangle())

                    Spacer()

                    Button {
                        onCopy()
                    } label: {
                        Label(isCopied ? "已复制" : "复制", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .displayLabelFont(10)
                            .foregroundStyle(isCopied ? .green : .secondary)
                    }
                    .contentShape(Rectangle())
                }
            } else {
                HStack {
                    Spacer()
                    Button {
                        onCopy()
                    } label: {
                        Label(isCopied ? "已复制" : "复制", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .displayLabelFont(10)
                            .foregroundStyle(isCopied ? .green : .secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button {
                onCopy()
            } label: {
                Label("复制本条日志", systemImage: "doc.on.doc")
            }
        }
    }
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