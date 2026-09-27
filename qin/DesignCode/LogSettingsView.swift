//
//  LogSettingsView.swift
//  山西晋中理工学院 APP — 日志设置页面
//
//  控制 DEBUG 开关、崩溃捕获开关、日志容量上限。
//

import SwiftUI

// MARK: - 日志设置页面

struct LogSettingsView: View {
    @ObservedObject private var logManager = LogManager.shared
    @Environment(\.dismiss) private var dismiss

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
                // MARK: DEBUG 开关
                Section {
                    Toggle(isOn: $logManager.debugEnabled) {
                        Label("DEBUG 调试日志", systemImage: "ladybug.fill")
                    }
                } footer: {
                    Text("关闭后，调试级别日志将不再记录，可减少冗余日志存储。日常使用建议关闭。")
                }

                // MARK: 崩溃捕获
                Section {
                    Toggle(isOn: $logManager.crashCaptureEnabled) {
                        Label("崩溃自动捕获", systemImage: "xmark.shield.fill")
                    }
                } footer: {
                    Text("开启后，App 发生崩溃时将自动捕获崩溃信息并写入日志。建议保持开启以便排查问题。")
                }

                // MARK: 容量上限
                Section {
                    HStack {
                        Label("日志容量上限", systemImage: "tray.full.fill")
                        Spacer()
                        Picker("", selection: $logManager.maxEntries) {
                            Text("1000 条").tag(1000)
                            Text("3000 条").tag(3000)
                            Text("5000 条").tag(5000)
                            Text("10000 条").tag(10000)
                        }
                        .pickerStyle(.menu)
                    }
                } footer: {
                    Text("达到上限后，最早日志将自动被移除（FIFO）。当前已存储 \(logManager.entries.count) 条日志。")
                }

                // MARK: 存储信息
                Section("存储信息") {
                    LabeledContent("今日日志", value: "\(todayLogCount()) 条")
                    LabeledContent("总日志数", value: "\(logManager.entries.count) 条")
                    LabeledContent("保留策略", value: "超过 7 天自动清理")
                    LabeledContent("存储位置", value: "仅本地存储，不上传")
                }
            }
            .navigationTitle("应用日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func todayLogCount() -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return logManager.entries.filter { calendar.isDate($0.timestamp, inSameDayAs: today) }.count
    }
}