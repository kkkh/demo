//
//  LogSettingsView.swift
//  山西晋中理工学院 APP — 日志设置页面
//
//  记录控制（DEBUG / 崩溃捕获，运行中即时生效）· 容量上限与保留天数 ·
//  实时存储统计（内存/磁盘/各级计数/最早最新）· 清空分档（今日/全部）·
//  一键导出（TXT/JSON）· 全链路日志域 log。
//

import SwiftUI

// MARK: - 日志设置页面

struct LogSettingsView: View {
    @ObservedObject private var logManager = LogManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: LogStorageSnapshot?
    @State private var showClearAllConfirm = false
    @State private var showClearTodayConfirm = false
    @State private var exportData: LogSettingsExportData?

    private var stats: LogStats { logManager.stats() }

    private var maxEntriesText: String {
        switch logManager.maxEntries {
        case 1000: return "1000 条"
        case 3000: return "3000 条"
        case 5000: return "5000 条"
        case 10000: return "10000 条"
        default: return "\(logManager.maxEntries) 条"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 记录控制（即时生效）
                Section {
                    Toggle(isOn: $logManager.debugEnabled) {
                        Label("DEBUG 调试日志", systemImage: "ladybug.fill")
                            .displayLabelFont(17)
                    }
                    Toggle(isOn: $logManager.crashCaptureEnabled) {
                        Label("崩溃自动捕获", systemImage: "xmark.shield.fill")
                            .displayLabelFont(17)
                    }
                } header: {
                    Text("记录控制").displayFont(13, weight: .semibold)
                } footer: {
                    Text("两个开关运行中即时生效：关闭 DEBUG 可减少冗余存储；崩溃捕获关闭后立即停止写入崩溃日志，无需重启。")
                        .displayFont(13)
                }

                // MARK: 容量与保留
                Section {
                    HStack {
                        Label("日志容量上限", systemImage: "tray.full.fill")
                            .displayLabelFont(17)
                        Spacer()
                        Picker("", selection: $logManager.maxEntries) {
                            Text("1000 条").tag(1000)
                            Text("3000 条").tag(3000)
                            Text("5000 条").tag(5000)
                            Text("10000 条").tag(10000)
                        }
                        .pickerStyle(.menu)
                        .displayFont(16)
                    }
                    HStack {
                        Label("保留天数", systemImage: "calendar.badge.clock")
                            .displayLabelFont(17)
                        Spacer()
                        Picker("", selection: $logManager.retentionDays) {
                            Text("3 天").tag(3)
                            Text("7 天").tag(7)
                            Text("14 天").tag(14)
                            Text("30 天").tag(30)
                        }
                        .pickerStyle(.menu)
                        .displayFont(16)
                    }
                } header: {
                    Text("容量与保留").displayFont(13, weight: .semibold)
                } footer: {
                    Text("达到容量上限后最早日志自动移除（FIFO）；磁盘按天分文件、单日上限 1000 条；超过保留天数的历史日志自动清理。当前内存 \(logManager.entries.count) 条 / 上限 \(maxEntriesText)。")
                        .displayFont(13)
                }

                // MARK: 存储统计
                Section {
                    LabeledContent("内存日志", value: "\(stats.total) 条")
                        .displayFont(17)
                    LabeledContent("今日新增", value: "\(stats.today) 条")
                        .displayFont(17)
                    if stats.issueToday > 0 {
                        LabeledContent("今日异常") {
                            Text("\(stats.issueToday) 条")
                                .displayFont(17, weight: .semibold)
                                .foregroundStyle(Color.sjzOrange)
                        }
                        .displayFont(17)
                    }
                    LabeledContent("级别分布", value: levelBreakdownText)
                        .displayFont(17)
                    LabeledContent("磁盘文件", value: snapshot.map { "\($0.files) 个 · \($0.sizeText)" } ?? "统计中…")
                        .displayFont(17)
                    LabeledContent("最早日志", value: stats.oldest?.formatted(.dateTime.month().day().hour().minute()) ?? "-")
                        .displayFont(17)
                    LabeledContent("最新日志", value: stats.newest?.formatted(.dateTime.month().day().hour().minute()) ?? "-")
                        .displayFont(17)
                    Button {
                        Task {
                            snapshot = await logManager.storageSnapshot()
                            LogManager.shared.info("log", "设置页刷新存储统计", context: [
                                "files": "\(snapshot?.files ?? 0)", "size": snapshot?.sizeText ?? "-"
                            ])
                        }
                    } label: {
                        Label("刷新存储统计", systemImage: "arrow.clockwise")
                            .displayLabelFont(13, weight: .medium)
                    }
                } header: {
                    Text("存储统计").displayFont(13, weight: .semibold)
                } footer: {
                    Text("日志仅存储在本地（Documents/SXJZIT_Cache/Logs），不会自动上传。")
                        .displayFont(13)
                }

                // MARK: 导出与清理
                Section {
                    Button {
                        prepareExport(scope: .all, format: .text)
                    } label: {
                        Label("导出全部日志（TXT）", systemImage: "doc.plaintext")
                            .displayLabelFont(17)
                    }
                    .disabled(logManager.entries.isEmpty)
                    Button {
                        prepareExport(scope: .all, format: .json)
                    } label: {
                        Label("导出全部日志（JSON）", systemImage: "curlybraces")
                            .displayLabelFont(17)
                    }
                    .disabled(logManager.entries.isEmpty)
                    Button(role: .destructive) {
                        showClearTodayConfirm = true
                    } label: {
                        Label("清空今日日志", systemImage: "calendar.badge.minus")
                            .displayLabelFont(17)
                    }
                    .disabled(stats.today == 0)
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Label("清空全部日志", systemImage: "trash")
                            .displayLabelFont(17)
                    }
                    .disabled(logManager.entries.isEmpty)
                } header: {
                    Text("导出与清理").displayFont(13, weight: .semibold)
                } footer: {
                    Text("导出文件可直接分享或保存；清空操作不可恢复，请谨慎选择。")
                        .displayFont(13)
                }
            }
            .navigationTitle("应用日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .displayFont(17)
                }
            }
            .sheet(item: $exportData) { data in
                LogSettingsExportSheet(text: data.text, fileName: data.fileName)
                    .sjzPresentationChrome()
            }
            .alert("确认清空全部日志？", isPresented: $showClearAllConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认清空", role: .destructive) {
                    let cleared = logManager.entries.count
                    withAnimation(.easeInOut(duration: 0.25)) {
                        logManager.clearAll()
                    }
                    LogManager.shared.info("log", "清空全部日志（设置页确认执行）", context: ["cleared": "\(cleared)"])
                    refreshSnapshot()
                }
            } message: {
                Text("将清空全部 \(logManager.entries.count) 条日志，此操作不可恢复。")
            }
            .alert("确认清空今日日志？", isPresented: $showClearTodayConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认清空", role: .destructive) {
                    LogManager.shared.info("log", "清空今日日志（设置页确认执行）", context: [:])
                    let removed = withAnimation(.easeInOut(duration: 0.25)) {
                        logManager.removeEntries(dayKey: LogEntry.dayKeyFormatter.string(from: Date()))
                    }
                    LogManager.shared.info("log", "今日日志已清空", context: ["removed": "\(removed)"])
                    refreshSnapshot()
                }
            } message: {
                Text("仅清空今天产生的日志，历史日志保留。")
            }
            .onAppear {
                refreshSnapshot()
                LogManager.shared.info("log", "日志设置页打开", context: [
                    "max": "\(logManager.maxEntries)",
                    "retentionDays": "\(logManager.retentionDays)",
                    "debug": "\(logManager.debugEnabled)",
                    "crashCapture": "\(logManager.crashCaptureEnabled)",
                    "entries": "\(logManager.entries.count)"
                ])
            }
            .onDisappear {
                LogManager.shared.debugLog("log", "日志设置页关闭", context: [
                    "max": "\(logManager.maxEntries)",
                    "retentionDays": "\(logManager.retentionDays)"
                ])
            }
        }
    }

    // MARK: 辅助

    private var levelBreakdownText: String {
        LogLevel.allCases
            .map { "\($0.displayName)\(stats.count(of: $0))" }
            .joined(separator: " · ")
    }

    private func refreshSnapshot() {
        Task {
            snapshot = await logManager.storageSnapshot()
        }
    }

    private enum ExportScope { case all }

    private func prepareExport(scope: ExportScope, format: LogExportFormat) {
        let entries = logManager.entries
        guard !entries.isEmpty else { return }
        let text = logManager.export(entries: entries, title: "全部日志", format: format)
        exportData = LogSettingsExportData(text: text,
                                           fileName: logManager.exportFileName(tag: "all", format: format))
        LogManager.shared.info("log", "导出日志（设置页）", context: [
            "format": format.rawValue, "count": "\(entries.count)"
        ])
    }
}

// MARK: - 导出数据模型（设置页）

private struct LogSettingsExportData: Identifiable {
    let id = UUID()
    let text: String
    let fileName: String
}

// MARK: - 导出 Sheet（设置页）

private struct LogSettingsExportSheet: UIViewControllerRepresentable {
    let text: String
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        return UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}