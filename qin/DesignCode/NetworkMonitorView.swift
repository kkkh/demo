//
//  NetworkMonitorView.swift
//  DesignCode
//
//  网络监测页（设置 → 网络监测）—— 2026-09-26 全面升级：
//  · Hero：实时网速大数字 + 校园网健康分大环 + 链路徽章组
//  · 雷达链路卡（sweep 扫动 + 三节点亮暗 + iOS 26 linkQuality）
//  · 实时曲线双卡（下行/上行 + 心跳点弱化 + 触摸查值 + 跟随状态机）
//  · 链路事件时间线（断网/恢复/异常，跨启动持久化）
//  · 统计卡（四格/并发/峰值/覆盖度/直方图/慢主机 TOP3/域分布）
//  · 诊断卡（双目标 5 轮 + 健康分 + 建议 + 历史对比 + 复制报告）
//  · 一键带宽测速 + 异常预警横幅 + 缓存联动 + 诚实口径脚注
//  日志域 netmon；无障碍与减弱动态效果全适配。
//

import SwiftUI
import Charts

// MARK: - 网络监测页

struct NetworkMonitorView: View {
    @ObservedObject private var monitor = SJZNetworkMonitor.shared
    @ObservedObject private var cacheManager = CacheModeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 图表坐标轴（AxisValueLabel 为 ChartContent，不接受 View 修饰器）→ 读取排版环境值交给字体工厂构造 Font
    @Environment(\.displayFontScale) private var displayFontScale
    @Environment(\.displayBold) private var displayBold
    @Environment(\.displayFontFamily) private var displayFontFamily

    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?
    /// 曲线跟随状态机：跟随 → 用户选中/拖拽 → 脱离
    @State private var chartSelectedDate: Date?
    @State private var lastInteractionLogTime = Date(timeIntervalSince1970: 0)
    @State private var refreshSuccessPulse = false

    @AppStorage(NetmonKey.samplingEnabled) private var liveSamplingEnabled: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                if let kind = monitor.anomalyKind {
                    anomalyBanner(kind)
                }
                radarLinkCard
                if monitor.heartbeatEnabled {
                    throughputCard
                    latencyCard
                } else {
                    emptyChartCard
                }
                if !monitor.linkTimeline.isEmpty {
                    timelineCard
                }
                statsCard
                probeCard
                speedTestCard
                cacheLinkCard
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("网络监测")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) { toastOverlay }
        .onAppear {
            monitor.beginLiveSampling()
            monitor.refreshNetworkIdentityPublic()
            LogManager.shared.info("netmon", "网络监测页打开", context: [
                "interface": monitor.interfaceName,
                "status": monitor.pathStatus,
                "tier": monitor.samplingTier.rawValue,
                "heartbeat": "\(monitor.heartbeatEnabled)",
                "coverage": String(format: "%.0f%%", monitor.coveragePercent * 100)
            ])
        }
        .onDisappear {
            monitor.endLiveSampling()
            LogManager.shared.debugLog("netmon", "网络监测页关闭", context: [
                "totalRequests": "\(monitor.totalRequests)"
            ])
        }
        .onChange(of: scenePhase) { _, phase in
            monitor.setSceneActive(phase == .active)
        }
        .onChange(of: liveSamplingEnabled) { _, enabled in
            monitor.setSamplingEnabledForSession(enabled)
            LogManager.shared.info("netmon", "心跳开关切换", context: ["enabled": "\(enabled)"])
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时网速")
                        .displayFont(11, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(formatKBps(monitor.instantaneousKBps))
                            .displayFont(38, weight: .heavy, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text(monitor.instantaneousKBps >= 1024 ? "MB/s" : "KB/s")
                            .displayFont(13, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text("上行 \(formatKBps(monitor.samples.last?.uploadKBps ?? 0)) · 峰值 \(formatKBps(monitor.peakKBps)) · 趋势\(trendArrow)")
                        .displayFont(10)
                        .foregroundStyle(.white.opacity(0.62))
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                healthRing
            }

            badgeRow
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: heroGradientColors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "wave.3.right.circle.fill")
                .displaySymbolFont(88)
                .foregroundStyle(.white.opacity(0.08))
                .offset(x: 12, y: -16)
        }
        .shadow(color: Color.sjzAccent.opacity(0.3), radius: 18, y: 9)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityText)
    }

    private var heroGradientColors: [Color] {
        switch healthTier {
        case .excellent: return colorScheme == .dark
            ? [Color(hex: "1D3557"), Color.sjzAccent.opacity(0.75)]
            : [Color.sjzAccent, Color(hex: "4F8EF7")]
        case .fine: return colorScheme == .dark
            ? [Color(hex: "0F4C4C"), Color.sjzTeal.opacity(0.7)]
            : [Color.sjzTeal, Color(hex: "2BAD9D")]
        case .fair: return colorScheme == .dark
            ? [Color(hex: "5A4320"), Color.sjzOrange.opacity(0.7)]
            : [Color.sjzOrange, Color.sjzGold]
        case .unknown: return colorScheme == .dark
            ? [Color(hex: "4A1B2E"), Color.sjzCoral.opacity(0.75)]
            : [Color.sjzCoral, Color.sjzRed]
        }
    }

    private enum HealthTier { case excellent, fine, fair, unknown }

    private var healthTier: HealthTier {
        guard let score = monitor.healthScore ?? monitor.lastPersistedProbe?.healthScore else { return .unknown }
        if score >= 85 { return .excellent }
        if score >= 60 { return .fine }
        return .fair
    }

    private var healthColor: Color {
        switch healthTier {
        case .excellent: return Color.sjzGreen
        case .fine: return Color.sjzTeal
        case .fair: return Color.sjzOrange
        case .unknown: return Color.sjzCoral
        }
    }

    private var healthRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 7)
                .frame(width: 92, height: 92)
            Circle()
                .trim(from: 0, to: healthRingProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 92, height: 92)
            VStack(spacing: 1) {
                Text(monitor.healthScore.map(String.init) ?? "—")
                    .displayFont(24, weight: .heavy, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(healthGradeText)
                    .displayFont(9, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .shadow(color: .white.opacity(0.2), radius: 8)
    }

    private var healthRingProgress: CGFloat {
        guard let score = monitor.healthScore, score > 0 else { return 0.02 }
        return max(0.02, CGFloat(score) / 100.0)
    }

    private var healthGradeText: String {
        if let score = monitor.healthScore {
            return SJZNetworkMonitor.gradeText(score)
        }
        return "待诊断"
    }

    private var trendArrow: String {
        switch monitor.trendDirection {
        case .rising: return "上升↑"
        case .falling: return "下降↓"
        case .stable: return "平稳→"
        }
    }

    private var badgeRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                heroBadge(dot: linkStatusColor, text: monitor.pathStatus)
                heroBadge(icon: interfaceIcon, text: monitor.interfaceName)
                heroBadge(icon: "antenna.radiowaves.left.and.right", text: "链路质量 · \(monitor.linkQualityText)")
                heroBadge(icon: "ipad.and.arrow.forward", text: ipStackText)
                heroBadge(icon: "chevron.down.circle", text: "采样 · \(monitor.samplingTier.rawValue) \(monitor.samplingTier.intervalSeconds)s")
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    heroBadge(dot: linkStatusColor, text: monitor.pathStatus)
                    heroBadge(icon: interfaceIcon, text: monitor.interfaceName)
                    heroBadge(icon: "antenna.radiowaves.left.and.right", text: "链路质量 · \(monitor.linkQualityText)")
                }
                HStack(spacing: 8) {
                    heroBadge(icon: "ipad.and.arrow.forward", text: ipStackText)
                    heroBadge(icon: "chevron.down.circle", text: "采样 · \(monitor.samplingTier.rawValue) \(monitor.samplingTier.intervalSeconds)s")
                }
            }
        }
    }

    private var ipStackText: String {
        var parts: [String] = []
        if monitor.supportsIPv4 { parts.append("IPv4") }
        if monitor.supportsIPv6 { parts.append("IPv6") }
        if monitor.supportsDNS { parts.append("DNS") }
        if monitor.isUltraConstrained { parts.append("超省") }
        return parts.isEmpty ? "协议栈未知" : parts.joined(separator: " · ")
    }

    private func heroBadge(dot: Color? = nil, icon: String? = nil, text: String) -> some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if let icon {
                Image(systemName: icon).displaySymbolFont(9, weight: .semibold)
            }
            Text(text).displayFont(10, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.16)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
    }

    private var linkStatusColor: Color {
        switch monitor.pathStatus {
        case "已连接": return Color.sjzGreen
        case "等待连接": return Color.sjzOrange
        default: return Color.sjzRed
        }
    }

    private var interfaceIcon: String {
        switch monitor.interfaceName {
        case "Wi-Fi": return "wifi"
        case "蜂窝网络": return "antenna.radiowaves.left.and.right"
        case "有线网络": return "cable.connector"
        default: return "questionmark.circle"
        }
    }

    private var heroAccessibilityText: String {
        var text = "实时网速 \(formatKBps(monitor.instantaneousKBps))"
        if let score = monitor.healthScore {
            text += "，校园网健康分 \(score) \(healthGradeText)"
        } else {
            text += "，尚未诊断"
        }
        text += "，\(monitor.pathStatus)，\(monitor.interfaceName)"
        return text
    }

    // MARK: - 异常横幅

    private func anomalyBanner(_ kind: AnomalyKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .displaySymbolFont(13)
                .foregroundStyle(Color.sjzOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .displayFont(12, weight: .semibold)
                    .foregroundStyle(.primary)
                Text("已为你保留实时监测，恢复后自动解除")
                    .displayFont(10)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.sjzOrange.opacity(0.35), lineWidth: 0.5))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityLabel(kind.title)
    }

    // MARK: - 雷达链路卡

    private var radarLinkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("链路状态", systemImage: "antenna.radiowaves.left.and.right")
                    .displayLabelFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                statusCapsule
            }

            HStack(spacing: 16) {
                radarDisc
                VStack(alignment: .leading, spacing: 8) {
                    infoLine("接口", monitor.interfaceName)
                    if monitor.pathStatus != "已连接" {
                        infoLine("原因", monitor.unsatisfiedReason)
                    }
                    infoLine("本机 IP", monitor.ipv4Address + (monitor.isCampusLAN ? " · 校园网" : ""))
                    infoLine("网关", monitor.gatewayAddress)
                    infoLine("接口数", "\(monitor.interfaceCount)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                propertyBadge(icon: "dollarsign.circle", text: "昂贵网络", active: monitor.isExpensive, color: .sjzOrange)
                propertyBadge(icon: "arrow.down.circle", text: "低数据模式", active: monitor.isConstrained, color: .sjzTeal)
                if monitor.isUltraConstrained {
                    propertyBadge(icon: "gauge.with.dots.needle.bottom.50percent", text: "超省数据", active: true, color: .sjzCoral)
                }
                Spacer()
            }

            Text("iOS 不提供信号强度接口，此处以系统链路质量与实测表现替代")
                .displayFont(9)
                .foregroundStyle(.tertiary)
        }
        .monitorCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("链路状态 \(monitor.pathStatus)，\(monitor.interfaceName)，链路质量 \(monitor.linkQualityText)，本机 IP \(monitor.ipv4Address)")
    }

    private var radarDisc: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                .frame(width: 128, height: 128)
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                .frame(width: 76, height: 76)
            Path { p in
                p.move(to: CGPoint(x: 64, y: 0)); p.addLine(to: CGPoint(x: 64, y: 128))
                p.move(to: CGPoint(x: 0, y: 64)); p.addLine(to: CGPoint(x: 128, y: 64))
            }
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)

            if monitor.pathStatus == "已连接" && (monitor.instantaneousKBps > 0 || monitor.heartbeatSucceeded > 0) {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let base = (t.truncatingRemainder(dividingBy: 2.4) / 2.4) * 360
                        Sector(startAngle: .degrees(base), endAngle: .degrees(base + 55))
                            .fill(Color.sjzAccent.opacity(0.13))
                            .frame(width: 128, height: 128)
                    }
                }
                Text("已连接")
                    .displayFont(13, weight: .semibold)
                    .foregroundStyle(.primary)
                nodeDot(offset: CGSize(width: 0, height: -46), color: radarNodeColor, pulse: true)
                nodeDot(offset: CGSize(width: 33, height: 18), color: Color.sjzTeal.opacity(0.9), pulse: false)
                nodeDot(offset: CGSize(width: -30, height: 30), color: Color.sjzGold.opacity(0.9), pulse: false)
            } else {
                Image(systemName: "wifi.slash")
                    .displaySymbolFont(22)
                    .foregroundStyle(.tertiary)
            }
            nodeLabel("网关", offset: CGSize(width: 0, height: -64))
            nodeLabel("门户", offset: CGSize(width: 44, height: 26))
            nodeLabel("图片域", offset: CGSize(width: -42, height: 40))
        }
        .frame(width: 128, height: 128)
    }

    private func nodeDot(offset: CGSize, color: Color, pulse: Bool) -> some View {
        ZStack {
            if pulse {
                Circle().fill(color.opacity(0.25)).frame(width: 18, height: 18)
                    .scaleEffect(pulseScale)
                    .animation(pulse ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: pulseScale)
                    .onAppear { if pulse { pulseScale = 1.35 } }
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .offset(offset)
    }

    @State private var pulseScale: CGFloat = 1.0

    private func nodeLabel(_ text: String, offset: CGSize) -> some View {
        Text(text)
            .displayFont(9)
            .foregroundStyle(.tertiary)
            .offset(offset)
    }

    private var radarNodeColor: Color {
        monitor.pathStatus == "已连接"
            ? (monitor.heartbeatConsecutiveFailuresPublic >= 1 ? Color.sjzOrange : Color.sjzGreen)
            : Color.sjzRed
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .displayFont(11)
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .displayFont(12, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(linkStatusColor)
                .frame(width: 7, height: 7)
                .shadow(color: linkStatusColor.opacity(0.6), radius: 3)
            Text(monitor.pathStatus)
                .displayFont(11, weight: .semibold)
                .foregroundStyle(linkStatusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(linkStatusColor.opacity(0.12)))
    }

    private func propertyBadge(icon: String, text: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).displaySymbolFont(9)
            Text(text).displayFont(10)
        }
        .foregroundStyle(active ? color : Color.secondary.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(active ? color.opacity(0.12) : Color.secondary.opacity(0.07)))
    }

    // MARK: - 实时曲线（吞吐 / 延迟）

    private var throughputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeaderRow(title: "实时吞吐", icon: "arrow.down.circle.fill",
                          trailingText: "瞬时 " + formatKBps(monitor.instantaneousKBps) + "/s")
            chartCanvas(kind: .throughput)
                .frame(height: 150)
            chartControls(kind: .throughput)
        }
        .monitorCard()
    }

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeaderRow(title: "响应延迟", icon: "timer",
                          trailingText: String(format: "平均 %.0f ms", monitor.averageLatencyMs))
            chartCanvas(kind: .latency)
                .frame(height: 150)
            chartControls(kind: .latency)
        }
        .monitorCard()
    }

    private func cardHeaderRow(title: String, icon: String, trailingText: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .displayLabelFont(13, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer()
            Text(trailingText)
                .displayFont(11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(throughputColor)
        }
    }

    private enum ChartKind { case throughput, latency }

    private func chartCanvas(kind: ChartKind) -> some View {
        // 窗口 chips 联动：钳制 [1,120]（防 UserDefaults 被外部污染 ≤0 触发 suffix 前置断言崩溃）
        let window = max(1, min(monitor.chartWindow, 120))
        let data = monitor.samples.suffix(window)
        return Chart {
            ForEach(Array(data)) { sample in
                if kind == .throughput {
                    AreaMark(
                        x: .value("时间", sample.second),
                        y: .value("吞吐", sample.throughputKBps)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [throughputColor.opacity(0.30), throughputColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    LineMark(
                        x: .value("时间", sample.second),
                        y: .value("吞吐", sample.throughputKBps)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(throughputColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    LineMark(
                        x: .value("时间", sample.second),
                        y: .value("上行", sample.uploadKBps)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.sjzTeal)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
                } else {
                    LineMark(
                        x: .value("时间", sample.second),
                        y: .value("延迟", sample.latencyMs)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(latencyColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    PointMark(
                        x: .value("时间", sample.second),
                        y: .value("延迟", sample.latencyMs)
                    )
                    .symbolSize(sample.isHeartbeat ? 8 : 14)
                    .foregroundStyle(sample.isHeartbeat ? Color.sjzGold.opacity(0.7) : latencyColor.opacity(0.4))
                }
            }
            if kind == .latency {
                // 延迟三档参考虚线（每图仅一次，不随样本循环冗余绘制）
                ForEach([100.0, 300.0, 1000.0], id: \.self) { gline in
                    RuleMark(y: .value("档线", gline))
                        .foregroundStyle(Color.primary.opacity(0.10))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
            }
            if let selected = chartSelectedDate {
                RuleMark(x: .value("选中", selected))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel()
                    .font(DisplayFontFactory.font(size: 9, scale: displayFontScale, family: displayFontFamily, bold: displayBold))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(DisplayFontFactory.font(size: 9, scale: displayFontScale, family: displayFontFamily, bold: displayBold))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXSelection(value: $chartSelectedDate)
        .chartScrollableAxes(.horizontal)
        .accessibilityLabel(kind == .throughput
                            ? "实时吞吐曲线，当前瞬时 \(formatKBps(monitor.instantaneousKBps)) 每秒，下行为蓝色、上行为青色虚线"
                            : "响应延迟曲线，平均 \(String(format: "%.0f", monitor.averageLatencyMs)) 毫秒，金色圆点为心跳采样")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: monitor.samples.count)
        .overlay {
            if chartSelectedDate != nil {
                VStack {
                    Spacer()
                    Button {
                        chartSelectedDate = nil
                        logChartInteraction("回到实时")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .displaySymbolFont(9, weight: .semibold)
                            Text("回到实时")
                                .displayFont(10, weight: .semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.sjzAccent))
                        .shadow(color: Color.sjzAccent.opacity(0.35), radius: 6, y: 2)
                    }
                    .padding(.bottom, 34)
                    .transition(.scale.combined(with: .opacity))
                }
                .allowsHitTesting(true)
            }
        }
    }

    private func chartControls(kind: ChartKind) -> some View {
        HStack(spacing: 8) {
            windowChip(30)
            windowChip(60)
            windowChip(120)
            Spacer()
            if kind == .throughput {
                HStack(spacing: 10) {
                    legendItem(color: throughputColor, text: "下行")
                    legendItem(color: Color.sjzTeal, text: "上行")
                    legendItem(color: Color.sjzGold, text: "心跳")
                }
            } else {
                Text("心跳采样以金色圆点弱化标记")
                    .displayFont(9)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private func windowChip(_ seconds: Int) -> some View {
        Button {
            monitor.setChartWindow(seconds)
        } label: {
            Text("\(seconds)s")
                .displayFont(10, weight: .semibold)
                .foregroundStyle(monitor.chartWindow == seconds ? .white : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(monitor.chartWindow == seconds ? Color.sjzAccent : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).displayFont(9).foregroundStyle(.tertiary)
        }
    }

    private var throughputColor: Color {
        let kb = monitor.currentThroughputKBps
        switch kb {
        case 300...: return Color.sjzGreen
        case 50...: return Color.sjzTeal
        case 0.1...: return Color.sjzAccent
        default: return .secondary.opacity(0.5)
        }
    }

    private var latencyColor: Color {
        switch monitor.lastLatencyMs {
        case ..<100: return Color.sjzGreen
        case ..<300: return Color.sjzTeal
        case ..<1000: return Color.sjzOrange
        default: return Color.sjzRed
        }
    }

    private var emptyChartCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.sjzLight).frame(width: 64, height: 64)
                Image(systemName: "waveform.path.ecg")
                    .displaySymbolFont(24)
                    .foregroundStyle(Color.sjzAccent.opacity(0.7))
            }
            Text("实时采样已关闭")
                .displayFont(15, weight: .semibold)
            Text("开启后页面打开即开始实时统计，3 秒内出数据")
                .displayFont(11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                liveSamplingEnabled = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").displaySymbolFont(9, weight: .semibold)
                    Text("开启实时采样").displayFont(13, weight: .semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.sjzAccent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
    }

    // MARK: - 链路事件时间线

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeaderRow(title: "链路事件", icon: "clock.arrow.circlepath",
                          trailingText: "最近 \(monitor.linkTimeline.count) 条")
            VStack(spacing: 0) {
                ForEach(Array(monitor.linkTimeline.prefix(8).enumerated()), id: \.element.id) { index, event in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(eventColor(event.kind))
                            .frame(width: 9, height: 9)
                            .shadow(color: eventColor(event.kind).opacity(0.5), radius: 3)
                        Text(SJZNetworkMonitor.timeText(event.date))
                            .displayFont(11, design: .monospaced)
                            .foregroundStyle(.secondary)
                        Text(eventTitle(event))
                            .displayFont(12)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    if index < min(monitor.linkTimeline.prefix(8).count - 1, 7) {
                        Divider().padding(.leading, 20).opacity(0.5)
                    }
                }
            }
        }
        .monitorCard()
    }

    private func eventColor(_ kind: LinkEventKind) -> Color {
        switch kind {
        case .outage: return Color.sjzRed
        case .recovery: return Color.sjzGreen
        case .anomaly: return Color.sjzOrange
        }
    }

    private func eventTitle(_ event: LinkEvent) -> String {
        switch event.kind {
        case .outage: return "断网 · \(event.interface) · \(event.reason)"
        case .recovery: return "恢复 · \(event.interface)"
        case .anomaly: return event.reason
        }
    }

    // MARK: - 统计卡

    /// 覆盖度文案：最近 2 分钟采样完整度；100% 后恒定显示「数据完整」
    private var coverageText: String {
        let p = monitor.coveragePercent
        if p >= 1 { return "数据完整" }
        return "覆盖度 \(String(format: "%.0f", p * 100))%"
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeaderRow(title: "本次运行统计", icon: "chart.bar.xaxis",
                          trailingText: coverageText)

            HStack(spacing: 10) {
                statCell(title: "总请求", value: "\(monitor.totalRequests)", color: Color.sjzAccent)
                statCell(title: "成功率", value: monitor.totalRequests > 0 ? String(format: "%.0f%%", monitor.successRate * 100) : "—", color: monitor.totalRequests > 0 ? successColor : .secondary)
                statCell(title: "总流量", value: trafficText, color: Color.sjzPurple)
                statCell(title: "平均延迟", value: monitor.totalRequests > 0 ? String(format: "%.0fms", monitor.averageLatencyMs) : "—", color: monitor.totalRequests > 0 ? latencyColor : .secondary)
            }

            // 并发指示
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .displaySymbolFont(11)
                    .foregroundStyle(concurrencyColor)
                Text("并发连接")
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(concurrencyColor)
                            .frame(width: max(6, min(1, Double(monitor.inFlightCount) / 20.0) * geo.size.width))
                    }
                }
                .frame(height: 7)
                Text("\(monitor.inFlightCount)")
                    .displayFont(12, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(concurrencyColor)
                    .frame(width: 26, alignment: .trailing)
            }

            // 延迟直方图
            histogramBlock

            // 慢主机 TOP3 与域分布
            if !monitor.slowHostsTop3.isEmpty || !monitor.domainDistribution.isEmpty {
                Divider().opacity(0.5)
                attributionBlock
            }
        }
        .monitorCard()
    }

    private var concurrencyColor: Color {
        switch monitor.inFlightCount {
        case 10...: return Color.sjzRed
        case 6...: return Color.sjzOrange
        default: return Color.sjzGreen
        }
    }

    private var successColor: Color {
        switch monitor.successRate {
        case 0.98...: return Color.sjzGreen
        case 0.9...: return Color.sjzOrange
        default: return Color.sjzRed
        }
    }

    private var trafficText: String {
        ByteCountFormatter.string(fromByteCount: monitor.totalBytes, countStyle: .file)
    }

    private var histogramBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("延迟分布（四档）")
                    .displayFont(10, weight: .semibold)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("峰值 \(formatKBps(monitor.peakKBps))/s")
                    .displayFont(9, weight: .bold)
                    .foregroundStyle(Color.sjzGold)
            }
            if monitor.totalRequests == 0 {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar").displaySymbolFont(10).foregroundStyle(.tertiary)
                    Text("暂无请求记录，直方图将在产生网络活动后呈现")
                        .displayFont(10)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 5)
            } else {
                let buckets = ["<100ms", "100-300", "300-1s", "≥1s"]
                let colors: [Color] = [.sjzGreen, .sjzTeal, .sjzOrange, .sjzRed]
                let total = max(monitor.latencyHistogram.reduce(0, +), 1)
                VStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { idx in
                        HStack(spacing: 8) {
                            Text(buckets[idx])
                                .displayFont(10)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 66, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                    Capsule()
                                        .fill(LinearGradient(colors: [colors[idx], colors[idx].opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(monitor.latencyHistogram[idx] > 0 ? 5 : 0, geo.size.width * CGFloat(monitor.latencyHistogram[idx]) / CGFloat(total)))
                                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7), value: monitor.latencyHistogram)
                                }
                            }
                            .frame(height: 8)
                            Text("\(monitor.latencyHistogram[idx])")
                                .displayFont(10)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var attributionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !monitor.slowHostsTop3.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("慢主机 TOP3")
                        .displayFont(10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(monitor.slowHostsTop3.enumerated()), id: \.element.host) { idx, item in
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .displayFont(9, weight: .bold)
                                .foregroundStyle(Color.sjzOrange)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.sjzOrange.opacity(0.12)))
                            Text(item.host)
                                .displayFont(10)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f ms", item.avgMs))
                                .displayFont(10, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if item.failures > 0 {
                                Text("失败 \(item.failures)")
                                    .displayFont(9, weight: .semibold)
                                    .foregroundStyle(Color.sjzRed)
                            }
                        }
                    }
                }
            }
            if !monitor.domainDistribution.isEmpty {
                let total = max(monitor.domainDistribution.reduce(Int64(0)) { $0 + $1.bytes }, 1)
                VStack(alignment: .leading, spacing: 7) {
                    Text("流量域分布")
                        .displayFont(10, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(monitor.domainDistribution.enumerated()), id: \.element.host) { idx, item in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(domainColor(idx))
                                    .frame(width: max(4, geo.size.width * CGFloat(item.bytes) / CGFloat(total)))
                            }
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                    HStack(spacing: 12) {
                        ForEach(Array(monitor.domainDistribution.enumerated()), id: \.element.host) { idx, item in
                            HStack(spacing: 4) {
                                Circle().fill(domainColor(idx)).frame(width: 6, height: 6)
                                Text(item.host)
                                    .displayFont(9)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func domainColor(_ idx: Int) -> Color {
        [Color.sjzAccent, Color.sjzTeal, Color.sjzGold, Color.sjzPurple, Color.sjzCoral][idx % 5]
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .displayFont(14, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .displayFont(10)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 诊断卡

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("网络诊断", systemImage: "stethoscope")
                    .displayLabelFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    monitor.runProbe()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isProbing ? "stopwatch.fill" : "play.fill")
                            .displaySymbolFont(9)
                        Text(probeButtonTitle)
                            .displayFont(12, weight: .semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(isProbing ? Color.sjzAccent.opacity(0.6) : Color.sjzAccent))
                }
                .buttonStyle(.plain)
                .disabled(isProbing || isSpeedTesting)
                .opacity((isProbing || isSpeedTesting) ? 0.7 : 1)
            }

            probeContent
        }
        .monitorCard()
        .accessibilityElement(children: .contain)
    }

    private var isProbing: Bool {
        if case .running = monitor.probeState { return true }
        return false
    }

    private var isSpeedTesting: Bool {
        if case .running = monitor.speedTestState { return true }
        return false
    }

    private var probeButtonTitle: String {
        if isProbing { return "诊断中…" }
        if case .done = monitor.probeState { return "重新诊断" }
        return "开始诊断"
    }

    @ViewBuilder
    private var probeContent: some View {
        switch monitor.probeState {
        case .idle:
            if let last = monitor.lastPersistedProbe {
                probeDoneView(last, persisted: true)
            } else {
                Text("对网关 API 与官网门户各执行 5 轮冷连接探测，输出延迟分位、丢包与分阶段耗时。仅在你点击时运行。")
                    .displayFont(11)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .running(let target, let round, let total):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).tint(Color.sjzAccent)
                    Text("探测中 · \(target.displayName) 第 \(min(round + 1, total))/\(total) 轮")
                        .displayFont(12, weight: .medium)
                        .foregroundStyle(Color.sjzAccent)
                }
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { idx in
                        Circle()
                            .fill(idx < round ? Color.sjzGreen : (idx == round ? Color.sjzOrange : Color.secondary.opacity(0.2)))
                            .frame(width: 9, height: 9)
                    }
                }
                Text(target == .gateway ? "主目标完成后将自动探测官网门户" : "副目标探测（失败不影响结果）")
                    .displayFont(10)
                    .foregroundStyle(.tertiary)
            }
        case .done(let summary):
            probeDoneView(summary, persisted: false)
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .displaySymbolFont(12)
                    .foregroundStyle(Color.sjzOrange)
                Text(message)
                    .displayFont(12)
                    .foregroundStyle(Color.sjzOrange)
                Spacer()
            }
        }
    }

    private func probeDoneView(_ summary: ProbeSummary, persisted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 评级徽章 + 健康分
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: gradeIcon(summary.healthScore))
                        .displaySymbolFont(14, weight: .semibold)
                    Text("校园网健康分 \(summary.healthScore) · \(summary.gradeText)")
                        .displayFont(12, weight: .semibold)
                }
                .foregroundStyle(gradeColor(summary.healthScore))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(gradeColor(summary.healthScore).opacity(0.12)))
                Spacer()
                if persisted {
                    Text("上次诊断 · 跨启动")
                        .displayFont(9)
                        .foregroundStyle(.tertiary)
                }
            }

            // 一致性提示
            if let consistency = consistencyHint(summary) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").displaySymbolFont(10)
                    Text(consistency)
                        .displayFont(10, weight: .medium)
                }
                .foregroundStyle(Color.sjzGold)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.sjzGold.opacity(0.12)))
            }

            // 五格指标
            HStack(spacing: 14) {
                probeStat("P50", String(format: "%.0fms", summary.gateway.p50))
                probeStat("P90", String(format: "%.0fms", summary.gateway.p90))
                probeStat("最快", String(format: "%.0fms", summary.gateway.fastest))
                probeStat("最慢", String(format: "%.0fms", summary.gateway.slowest))
                probeStat("丢包", String(format: "%.0f%%", summary.gateway.lossRate * 100))
                Spacer()
            }

            // 阶段条
            stageBar(summary.gateway)
                .frame(height: 6)
            HStack(spacing: 12) {
                stageStat("DNS", ProbeResult.stageText(summary.gateway.dnsMs), Color.sjzOrange)
                stageStat("TCP", ProbeResult.stageText(summary.gateway.tcpMs), Color.sjzTeal)
                stageStat("TLS", ProbeResult.stageText(summary.gateway.tlsMs), Color.sjzAccent)
                stageStat("首字节", ProbeResult.stageText(summary.gateway.ttfbMs), Color.sjzGreen)
                Spacer()
                if let proto = summary.gateway.protocolName {
                    Text(proto.uppercased())
                        .displayFont(9, weight: .bold)
                        .foregroundStyle(Color.sjzPurple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.sjzPurple.opacity(0.1)))
                }
                if summary.gateway.isRemoteIPv6 {
                    Text("IPv6").displayFont(9, weight: .semibold)
                        .foregroundStyle(Color.sjzTeal)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.sjzTeal.opacity(0.1)))
                }
            }

            // 副目标
            if let portal = summary.portal {
                HStack(spacing: 6) {
                    Image(systemName: "globe").displaySymbolFont(9)
                        .foregroundStyle(.secondary)
                    Text("官网门户 P90 \(String(format: "%.0f", portal.p90))ms · 丢包 \(String(format: "%.0f", portal.lossRate * 100))%")
                        .displayFont(10)
                        .foregroundStyle(.secondary)
                }
            }

            // 建议列表
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SJZNetworkMonitor.advice(for: summary.gateway, healthScore: summary.healthScore)) { advice in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: advice.icon)
                            .displaySymbolFont(12)
                            .foregroundStyle(Color.sjzAccent)
                            .padding(.top, 1)
                        Text(advice.text)
                            .displayFont(11)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .background(Color.sjzAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // 历史对比
            if monitor.probeHistory.count > 1 {
                HStack(spacing: 8) {
                    Text("历史对比")
                        .displayFont(9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(monitor.probeHistory.prefix(3).enumerated()), id: \.offset) { idx, item in
                        Text("\(item.healthScore)分")
                            .displayFont(9, weight: .bold)
                            .monospacedDigit()
                            .foregroundStyle(idx == 0 ? gradeColor(item.healthScore) : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(idx == 0 ? gradeColor(item.healthScore).opacity(0.12) : Color.primary.opacity(0.05)))
                    }
                    Spacer()
                }
            }

            // 操作行
            HStack(spacing: 10) {
                smallActionButton(icon: "doc.on.doc", title: "复制报告") {
                    copyDiagnosticReport()
                }
                smallActionButton(icon: "square.and.arrow.up", title: "导出快照") {
                    shareSnapshot()
                }
                Spacer()
            }
        }
    }

    private func smallActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).displaySymbolFont(10, weight: .semibold)
                Text(title).displayFont(11, weight: .semibold)
            }
            .foregroundStyle(Color.sjzAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.sjzAccent.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.sjzAccent.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func gradeColor(_ score: Int) -> Color {
        switch score {
        case 85...: return Color.sjzGreen
        case 60...: return Color.sjzTeal
        default: return Color.sjzOrange
        }
    }

    private func gradeIcon(_ score: Int) -> String {
        switch score {
        case 85...: return "checkmark.seal.fill"
        case 60...: return "checkmark.circle.fill"
        default: return "exclamationmark.circle.fill"
        }
    }

    private func consistencyHint(_ summary: ProbeSummary) -> String? {
        if monitor.linkQualityText == "优秀" && summary.gateway.p90 > 300 {
            return "系统链路质量显示优秀，但实测 P90 \(String(format: "%.0f", summary.gateway.p90))ms — 校园网可能拥塞"
        }
        if monitor.linkQualityText == "一般" && summary.gateway.p90 < 100 {
            return "系统链路质量一般，但实测响应很快 — 当前体验良好"
        }
        return nil
    }

    private func probeStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .displayFont(13, weight: .bold)
                .monospacedDigit()
            Text(label)
                .displayFont(9)
                .foregroundStyle(.tertiary)
        }
    }

    private func stageStat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).displayFont(9).foregroundStyle(.tertiary)
                Text(value).displayFont(11, weight: .semibold).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func stageBar(_ result: ProbeResult) -> some View {
        let stages: [(Double?, Color)] = [
            (result.dnsMs, Color.sjzOrange),
            (result.tcpMs, Color.sjzTeal),
            (result.tlsMs, Color.sjzAccent),
            (result.ttfbMs, Color.sjzGreen)
        ]
        let total = stages.compactMap(\.0).reduce(0, +)
        return GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 2) {
                ForEach(0..<stages.count, id: \.self) { idx in
                    if let ms = stages[idx].0, ms > 0, total > 0 {
                        Capsule()
                            .fill(stages[idx].1)
                            .frame(width: max(width * ms / total - 2, 2))
                    } else {
                        Color.clear.frame(width: 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func copyDiagnosticReport() {
        UIPasteboard.general.string = monitor.diagnosticReportText
        showToast("诊断报告已复制")
        LogManager.shared.info("netmon", "复制诊断报告", context: [
            "chars": "\(monitor.diagnosticReportText.count)"
        ])
    }

    private func shareSnapshot() {
        let text = monitor.diagnosticReportText
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            var top: UIViewController = root
            while let presented = top.presentedViewController { top = presented }
            top.present(av, animated: true)
        }
        LogManager.shared.info("netmon", "导出监测快照", context: ["chars": "\(text.count)"])
    }

    // MARK: - 测速卡

    private var speedTestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeaderRow(title: "带宽测速", icon: "bolt.horizontal",
                          trailingText: speedTestTrailingText)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    switch monitor.speedTestState {
                    case .idle:
                        Text("一键测量到学校服务器的真实下载带宽")
                            .displayFont(11)
                            .foregroundStyle(.secondary)
                    case .running(let progress, let mb):
                        Text("正在测量 · 已下载 \(String(format: "%.1f", mb)) MB")
                            .displayFont(11, weight: .medium)
                            .foregroundStyle(Color.sjzAccent)
                        ProgressView(value: progress)
                            .tint(LinearGradient(colors: [Color.sjzAccent, Color.sjzTeal], startPoint: .leading, endPoint: .trailing))
                    case .done(let mbps, let grade, let note):
                        HStack(spacing: 8) {
                            Text("\(String(format: "%.2f", mbps)) MB/s")
                                .displayFont(16, weight: .bold)
                                .monospacedDigit()
                                .foregroundStyle(Color.sjzAccent)
                                .contentTransition(.numericText())
                            Text(grade)
                                .displayFont(10, weight: .bold)
                                .foregroundStyle(gradeColor(speedGradeScore(grade)))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(gradeColor(speedGradeScore(grade)).opacity(0.12)))
                        }
                        if let note {
                            Text(note)
                                .displayFont(9)
                                .foregroundStyle(.tertiary)
                        }
                    case .failed(let message):
                        Text(message)
                            .displayFont(11)
                            .foregroundStyle(Color.sjzRed)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    monitor.runSpeedTest()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSpeedTesting ? "stopwatch.fill" : "bolt.fill")
                            .displaySymbolFont(11, weight: .semibold)
                        Text(isSpeedTesting ? "测量中" : "测速")
                            .displayFont(12, weight: .semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(isSpeedTesting ? Color.sjzAccent.opacity(0.55) : Color.sjzAccent))
                    .shadow(color: Color.sjzAccent.opacity(0.3), radius: 7, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(isSpeedTesting || isProbing)
            }
        }
        .monitorCard()
        .accessibilityLabel("带宽测速 \(speedTestTrailingText)")
    }

    private var speedTestTrailingText: String {
        switch monitor.speedTestState {
        case .idle: return "待测"
        case .running: return "测量中"
        case .done(let mbps, let grade, _): return "\(String(format: "%.2f", mbps)) MB/s · \(grade)"
        case .failed: return "失败"
        }
    }

    private func speedGradeScore(_ grade: String) -> Int {
        switch grade {
        case "优秀": return 88
        case "良好": return 72
        case "可用": return 58
        default: return 40
        }
    }

    // MARK: - 缓存联动

    private var cacheLinkCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SJZDesignTokens.successGradient.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: "leaf.fill")
                    .displaySymbolFont(16, weight: .semibold)
                    .foregroundStyle(Color.sjzGreen)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(optimizationHeadline)
                    .displayFont(13, weight: .semibold)
                Text("已为你节省流量 \(ByteCountFormatter.string(fromByteCount: cacheManager.savedTrafficBytes, countStyle: .file))")
                    .displayFont(11)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if monitor.heartbeatConsecutiveFailuresPublic >= 3 && monitor.pathStatus != "已连接" {
                NavigationLink {
                    CacheModeSettingsView()
                } label: {
                    Text("离线阅读")
                        .displayFont(11, weight: .semibold)
                        .foregroundStyle(Color.sjzAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.sjzAccent.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .onAppear {
                    LogManager.shared.info("netmon", "断网缓存联动卡展示", context: ["status": monitor.pathStatus])
                }
            }
        }
        .monitorCard()
    }

    private var optimizationHeadline: String {
        if cacheManager.imageFreeModeEnabled {
            return "无图模式已开启 · 省流最大化"
        }
        return "网络优化已开启 · \(cacheManager.mode == .cached ? "缓存模式" : "极速模式")"
    }

    // MARK: - 脚注

    private var footnote: some View {
        Text("统计口径：App 数据层 HTTP（学校域）；网页与视频由系统组件加载，不在此统计。健康分为估算值，仅供参考。")
            .displayFont(9)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    // MARK: - 工具栏 / Toast / 工具

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                monitor.refreshNow()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    refreshSuccessPulse = true
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { refreshSuccessPulse = false }
                }
            } label: {
                Image(systemName: refreshSuccessPulse ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath")
                    .displaySymbolFont(14, weight: .semibold)
                    .foregroundStyle(refreshSuccessPulse ? Color.sjzGreen : Color.sjzAccent)
            }
            .accessibilityLabel("手动刷新网络监测")
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
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

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { toastText = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
        }
    }

    private func formatKBps(_ kb: Double) -> String {
        if kb >= 1024 { return String(format: "%.2f", kb / 1024) }
        return String(format: "%.1f", kb)
    }

    private func logChartInteraction(_ action: String) {
        let now = Date()
        guard now.timeIntervalSince(lastInteractionLogTime) >= 2 else { return }
        lastInteractionLogTime = now
        LogManager.shared.debugLog("netmon", "图表交互", context: ["action": action])
    }
}

// MARK: - 卡片修饰符（Liquid Glass 统一风格）

private extension View {
    func monitorCard() -> some View {
        self
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

// MARK: - 流量等级条（保留既有组件）

/// 流量等级条：4 根竖条按吞吐等级点亮（诚实语义：非信号强度）
struct FlowBars: View {
    let level: Int
    var color: Color = Color.sjzGreen

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4) { idx in
                Capsule()
                    .fill(idx < level ? color : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + idx * 3))
            }
        }
        .frame(height: 13)
    }
}

// MARK: - 圆形扇区（雷达扫动扇形）

private struct Sector: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        p.move(to: center)
        p.addArc(center: center, radius: radius,
                 startAngle: startAngle - .degrees(90),
                 endAngle: endAngle - .degrees(90),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - 预览

#Preview("网络监测 - 浅色") {
    NavigationStack {
        NetworkMonitorView()
    }
    .preferredColorScheme(.light)
}

#Preview("网络监测 - 深色") {
    NavigationStack {
        NetworkMonitorView()
    }
    .preferredColorScheme(.dark)
}