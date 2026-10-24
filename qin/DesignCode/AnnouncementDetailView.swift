//
//  AnnouncementDetailView.swift
//  山西晋中理工学院 APP — 公告详情页 & 横幅组件
//
//  公告开启：显示可点击横幅，进入详情页
//  公告关闭：柔和提示「公告未开启」
//  完整适配浅色 / 深色模式
//

import SwiftUI

// MARK: - 公告横幅（嵌入「我的」页面）

/// 公告横幅组件，根据 AnnouncementManager 状态显示开启/关闭两种 UI
struct AnnouncementBanner: View {
    @ObservedObject private var manager = AnnouncementManager.shared
    let onTap: () -> Void

    var body: some View {
        if manager.isActive {
            activeBanner
        } else {
            inactiveBanner
        }
    }

    // MARK: 开启状态 —— 可点击横幅

    private var activeBanner: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 左侧图标
                ZStack {
                    Circle()
                        .fill(Color.sjzRed.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "bell.badge.fill")
                        .displaySymbolFont(18)
                        .foregroundStyle(Color.sjzRed)
                }

                // 中间文字
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.title)
                        .displayFont(14, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("点击查看公告详情")
                        .displayFont(11)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 右侧箭头
                Image(systemName: "chevron.right")
                    .displaySymbolFont(13, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.sjzRed.opacity(0.25), lineWidth: 1)
                    )
            )
            .shadow(color: Color.sjzRed.opacity(0.08), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
    }

    // MARK: 关闭状态 —— 柔和提示

    private var inactiveBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill")
                .displaySymbolFont(12)
                .foregroundStyle(.secondary.opacity(0.5))
            Text("公告未开启")
                .displayFont(12, weight: .medium)
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.5))
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - 公告详情页

struct AnnouncementDetailView: View {
    @ObservedObject private var manager = AnnouncementManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 标题区
                    titleSection

                    Divider()

                    // 正文区
                    contentSection

                    // 底部信息
                    footerSection
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("公告详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .displaySymbolFont(18, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 标题区

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .displaySymbolFont(16)
                    .foregroundStyle(Color.sjzRed)
                Text("公告")
                    .displayFont(12, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.sjzRed, in: Capsule())
            }

            Text(manager.title)
                .displayFont(20, weight: .bold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let fetchTime = manager.lastFetchTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .displaySymbolFont(10)
                    Text("更新时间：\(formattedTime(fetchTime))")
                        .displayFont(11)
                }
                .foregroundStyle(.secondary)
            }

            // 阅读统计（正文字数 + 预计阅读时长）
            if !manager.content.isEmpty {
                ArticleReadingStatsText(cachedID: manager.title, plainText: manager.content)
            }
        }
    }

    // MARK: 正文区

    private var contentSection: some View {
        Text(manager.content)
            .displayText(size: 16, baseLineSpacing: 8)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 底部信息

    private var footerSection: some View {
        VStack(spacing: 6) {
            Divider()
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .displaySymbolFont(10)
                    .foregroundStyle(.secondary.opacity(0.4))
                Text("公告来源：超超博客")
                    .displayFont(10)
                    .foregroundStyle(.secondary.opacity(0.4))
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    // MARK: 辅助

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 预览

#Preview("公告开启 - 浅色") {
    AnnouncementDetailView()
        .preferredColorScheme(.light)
}

#Preview("公告关闭 - 深色") {
    VStack {
        AnnouncementBanner(onTap: {})
            .padding(.vertical, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}