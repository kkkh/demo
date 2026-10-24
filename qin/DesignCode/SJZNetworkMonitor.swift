//
//  SJZNetworkMonitor.swift
//  DesignCode
//
//  网络监测中枢（2026-09-26 全面升级）：
//  1. 链路感知（NWPathMonitor）+ iOS 26 linkQuality / isUltraConstrained / IPv4/IPv6/DNS；
//  2. 链路事件时间线（断网/恢复/异常，@AppStorage 持久化最近 30 条）；
//  3. 全 App 实时流量统计（URLProtocol 埋点，含上行/httpBody 估算）；
//  4. 主动心跳实时采样（页面可见 5s 起步，三档智能省电 5s/10s/30s，后台暂停）；
//  5. EMA 瞬时吞吐 / 并发 / 峰值 / 慢主机 TOP3 / 分钟级小时历史 / 今日流量（跨启动）；
//  6. 双目标网络诊断（网关 API + 官网门户，5 轮冷连接）+ 诊断历史（内存 3 + 持久 1）；
//  7. 校园网健康分（0-100）+ 优化建议生成器 + 诊断报告文本；
//  8. 一键带宽测速（HEAD 挑源 + 循环下载真实资源）。
//  日志域 netmon；全部指标随 LogManager 节流落日志。
//

import Foundation
import Network
import Combine
import SwiftUI
import Darwin

// MARK: - 持久化键

enum NetmonKey {
    static let samplingEnabled = "netmonLiveSamplingEnabled"
    static let chartWindow = "netmonChartWindowSeconds"
    static let timeline = "netmonTimelineJSON"
    static let lastProbe = "netmonLastProbeJSON"
    static func traffic(day: String) -> String { "netmonTraffic_" + day }
}

// MARK: - 线程安全记账槽（独立于 MainActor，URLProtocol 任意线程调用）

private final class NetworkMonitorLedger: @unchecked Sendable {
    static let shared = NetworkMonitorLedger()

    private let lock = NSLock()
    private var inFlight: [UInt64: (start: CFTimeInterval, bytes: Int64, host: String?, firstByte: CFTimeInterval?)] = [:]
    private var tokenCounter: UInt64 = 0
    private var bucketBytes: Int64 = 0
    private var bucketUpBytes: Int64 = 0
    private var bucketLatencySum: Double = 0
    private var bucketLatencyCount: Int = 0
    /// 探测/测速静默开关：期间挂起业务采集
    private var suspended = false

    /// 在飞请求数（锁内读）
    var inFlightCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight.count
    }

    func requestStart(host: String?) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        tokenCounter += 1
        let token = tokenCounter
        if !suspended {
            inFlight[token] = (CFAbsoluteTimeGetCurrent(), 0, host, nil)
        } else {
            // 静默期不记账（complete 时会找不到 token 而被忽略，口径一致）
        }
        if inFlight.count > 256 {
            inFlight.removeAll(keepingCapacity: true)
            if !suspended {
                DispatchQueue.main.async {
                    LogManager.shared.warning("netmon", "请求台账溢出，已重置", context: [
                        "overflowSinceToken": "\(token)"
                    ])
                }
            }
        }
        return token
    }

    /// 累计响应字节（下行）
    func addData(token: UInt64, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard var entry = inFlight[token] else { return }
        entry.bytes += Int64(bytes)
        inFlight[token] = entry
        bucketBytes += Int64(bytes)
    }

    /// 上行字节（请求体估算）
    func addUpData(token: UInt64, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard inFlight[token] != nil else { return }
        bucketUpBytes += Int64(bytes)
    }

    /// 首字节时刻（响应头到达）——TTFB 口径：准确反映链路响应，不受大文件下载时长拖累（2026-09-27）
    func markFirstByte(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = inFlight[token], entry.firstByte == nil else { return }
        entry.firstByte = CFAbsoluteTimeGetCurrent()
        inFlight[token] = entry
    }

    func complete(token: UInt64) -> (latency: Double, ttfb: Double?, bytes: Int64, host: String?)? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = inFlight.removeValue(forKey: token) else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        let latency = (now - entry.start) * 1000.0
        let ttfb = entry.firstByte.map { ($0 - entry.start) * 1000.0 }
        // 1s 桶与直方图统一 TTFB 口径（无响应头的失败请求回退总时长）
        bucketLatencySum += ttfb ?? latency
        bucketLatencyCount += 1
        return (latency, ttfb, entry.bytes, entry.host)
    }

    func abandon(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        _ = inFlight.removeValue(forKey: token)
    }

    func setSuspended(_ flag: Bool) {
        lock.lock(); defer { lock.unlock() }
        suspended = flag
        if flag {
            inFlight.removeAll(keepingCapacity: true)
            bucketBytes = 0
            bucketUpBytes = 0
            bucketLatencySum = 0
            bucketLatencyCount = 0
        }
    }

    func drainBucket() -> (bytes: Int64, upBytes: Int64, latSum: Double, latCount: Int) {
        lock.lock(); defer { lock.unlock() }
        let out = (bucketBytes, bucketUpBytes, bucketLatencySum, bucketLatencyCount)
        bucketBytes = 0
        bucketUpBytes = 0
        bucketLatencySum = 0
        bucketLatencyCount = 0
        return out
    }
}

// MARK: - 流量采样点

struct NetworkTrafficSample: Identifiable, Hashable {
    let id: Int
    let second: Date
    let throughputKBps: Double   // 下行 1s 桶
    let uploadKBps: Double       // 上行 1s 桶
    let latencyMs: Double
    let isFailure: Bool          // 心跳失败落点（断网归零）
    let isHeartbeat: Bool        // 心跳/业务区分（图例弱化）
    let inFlightCount: Int
}

// MARK: - 链路事件

enum LinkEventKind: String, Codable {
    case outage, recovery, anomaly
}

struct LinkEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: LinkEventKind
    let status: String
    let interface: String
    let reason: String

    init(kind: LinkEventKind, status: String, interface: String, reason: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.status = status
        self.interface = interface
        self.reason = reason
    }
}

// MARK: - 采样档位 / 趋势 / 覆盖 / 异常横幅

enum SamplingTier: String {
    case live = "实时"
    case saving = "省电"
    case deepSaving = "深度省电"

    var intervalSeconds: Int {
        switch self {
        case .live: return 5
        case .saving: return 10
        case .deepSaving: return 30
        }
    }
}

enum TrendDirection: String {
    case rising, stable, falling
}

enum AnomalyKind: String {
    case highLatency, unstableLink

    var title: String {
        switch self {
        case .highLatency: return "网络异常：延迟持续偏高"
        case .unstableLink: return "链路不稳定：心跳连续失败"
        }
    }
}

/// 慢请求连续观测判定（纯函数输出；契约测试锚点）
enum SlowStreakVerdict: String {
    /// 未构成异常
    case none
    /// 单一**媒体宿主**（图片镜像 / CDN）慢：TTFB 天然偏高，仅观测不打横幅
    case mediaObservation
    /// **非媒体宿主**自身连续慢：该主机的服务异常
    case hostService
    /// **多个不同宿主**同时慢：链路级异常
    case linkWide
}

// MARK: - 探测目标 / 测速 / 诊断结果

enum ProbeTarget: String, CaseIterable, Codable {
    case gateway
    case portal

    /// 集中常量：与 NetworkService 域名一致，域名变更需同步
    var urlString: String {
        switch self {
        case .gateway: return "https://gwqietap.sxjzit.edu.cn/mapi/common/column/head"
        case .portal: return "https://www.sxjzit.edu.cn/"
        }
    }

    var displayName: String {
        switch self {
        case .gateway: return "网关 API"
        case .portal: return "官网门户"
        }
    }
}

struct ProbeResult: Codable, Equatable {
    let rtts: [Double]
    let lossRate: Double
    let dnsMs: Double?
    let tcpMs: Double?
    let tlsMs: Double?
    let ttfbMs: Double?
    /// 协议版本（h2/h3/h1_1，metrics 网络协议名）
    let protocolName: String?
    /// 远端地址是否为 IPv6
    let isRemoteIPv6: Bool

    var p50: Double { Self.percentile(rtts, 0.5) }
    var p90: Double { Self.percentile(rtts, 0.9) }
    var fastest: Double { rtts.min() ?? 0 }
    var slowest: Double { rtts.max() ?? 0 }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let idx = Int(Double(s.count - 1) * p)
        return s[idx]
    }

    static func stageText(_ ms: Double?) -> String {
        ms.map { String(format: "%.0f ms", $0) } ?? "—"
    }
}

struct ProbeSummary: Codable, Equatable {
    let date: Date
    let gateway: ProbeResult
    let portal: ProbeResult?
    let healthScore: Int
    let gradeText: String
    let adviceTitles: [String]
}

enum ProbeState: Equatable {
    case idle
    case running(target: ProbeTarget, round: Int, total: Int)
    case done(ProbeSummary)
    case failed(String)
}

enum SpeedTestState: Equatable {
    case idle
    case running(progress: Double, downloadedMB: Double)
    case done(mbps: Double, grade: String, note: String?)
    case failed(String)
}

struct HealthAdvice: Identifiable, Equatable {
    let id: Int
    let icon: String
    let text: String
}

// MARK: - 分钟摘要（最近 1 小时）

struct MinuteSummary: Identifiable {
    let minute: Date
    let avgKBps: Double
    let peakKBps: Double
    var id: Date { minute }
}

// MARK: - 诊断指标委托（收集 transaction metrics 分阶段 + 协议版本）

private final class ProbeMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _metrics: URLSessionTaskMetrics?
    private var _remoteHost: String?

    var metrics: URLSessionTaskMetrics? {
        lock.lock(); defer { lock.unlock() }
        return _metrics
    }

    var remoteHost: String? {
        lock.lock(); defer { lock.unlock() }
        return _remoteHost
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        _metrics = metrics
        _remoteHost = metrics.transactionMetrics.first?.remoteAddress
    }
}

// MARK: - 网络监测中枢

@MainActor
final class SJZNetworkMonitor: ObservableObject {

    static let shared = SJZNetworkMonitor()

    // MARK: 链路状态

    @Published private(set) var pathStatus: String = "未知"
    @Published private(set) var unsatisfiedReason: String = "—"
    @Published private(set) var interfaceName: String = "—"
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConstrained: Bool = false
    /// iOS 26 链路质量（优秀/良好/一般/未知；低版本「系统未提供」）
    @Published private(set) var linkQualityText: String = "系统未提供"
    /// iOS 26 超省数据模式
    @Published private(set) var isUltraConstrained: Bool = false
    @Published private(set) var supportsIPv4: Bool = false
    @Published private(set) var supportsIPv6: Bool = false
    @Published private(set) var supportsDNS: Bool = false
    @Published private(set) var interfaceCount: Int = 0
    @Published private(set) var gatewayAddress: String = "—"
    @Published private(set) var ipv4Address: String = "—"
    @Published private(set) var isCampusLAN: Bool = false

    // MARK: 链路事件时间线

    @Published private(set) var linkTimeline: [LinkEvent] = []

    // MARK: 流量指标

    @Published private(set) var samples: [NetworkTrafficSample] = []
    @Published private(set) var totalRequests: Int = 0
    @Published private(set) var successRequests: Int = 0
    @Published private(set) var failedRequests: Int = 0
    @Published private(set) var totalBytes: Int64 = 0
    /// 上行总字节（请求体估算）
    @Published private(set) var totalUpBytes: Int64 = 0
    @Published private(set) var lastLatencyMs: Double = 0
    @Published private(set) var latencySumMs: Double = 0
    @Published private(set) var latencyHistogram: [Int] = [0, 0, 0, 0]
    /// 瞬时吞吐（EMA，大数字用）
    @Published private(set) var instantaneousKBps: Double = 0
    /// 会话峰值吞吐
    @Published private(set) var peakKBps: Double = 0
    /// 并发在飞请求数
    @Published private(set) var inFlightCount: Int = 0
    /// 趋势方向（最近 10 个有效延迟采样斜率）
    @Published private(set) var trendDirection: TrendDirection = .stable
    /// 数据覆盖度 0-1（最近 2 分钟采样占比）
    @Published private(set) var coveragePercent: Double = 0
    /// 最近 1 小时分钟摘要
    @Published private(set) var minuteSummaries: [MinuteSummary] = []

    // MARK: 心跳引擎

    @Published private(set) var samplingTier: SamplingTier = .live
    @Published private(set) var heartbeatEnabled: Bool
    @Published private(set) var liveSamplingActive: Bool = false
    @Published private(set) var heartbeatSucceeded: Int = 0
    @Published private(set) var heartbeatFailed: Int = 0
    @Published private(set) var heartbeatLastRTTMs: Double = 0
    /// 异常预警横幅（页内）
    @Published private(set) var anomalyKind: AnomalyKind?

    // MARK: 探针 / 测速 / 健康

    @Published private(set) var probeState: ProbeState = .idle
    @Published private(set) var probeHistory: [ProbeSummary] = []
    @Published private(set) var lastPersistedProbe: ProbeSummary?
    @Published private(set) var speedTestState: SpeedTestState = .idle
    /// 当前健康分（nil = 尚未诊断）
    @Published private(set) var healthScore: Int?

    // MARK: 今日流量（跨启动）

    @Published private(set) var todayDownBytes: Int64 = 0
    @Published private(set) var todayUpBytes: Int64 = 0

    // MARK: 会话元信息

    @Published private(set) var sessionStartAt: Date

    // MARK: 私有 · 心跳

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "sjz.networkmonitor.path", qos: .utility)
    private var aggregateTimer: Timer?
    private var nextSampleID: Int = 0
    private var lastThroughputLogTime = Date(timeIntervalSince1970: 0)
    private var successBatchCount = 0
    private var successBatchBytes: Int64 = 0
    private var successBatchLatencySum: Double = 0
    private var lastSlowRequestLogTime = Date(timeIntervalSince1970: 0)
    /// 失败请求告警节流（10s 窗口；断网批量失败防刷屏）
    private var lastFailureLogTime = Date(timeIntervalSince1970: 0)
    private var lastTrafficFlushTime = Date(timeIntervalSince1970: 0)
    private var lastHostStatsLogTime = Date(timeIntervalSince1970: 0)
    /// 主机归因（主线程聚合）
    private var perHostStats: [String: (bytes: Int64, latSum: Double, count: Int, failures: Int)] = [:]
    /// 心跳引擎
    private var liveSamplingTokenCount = 0
    private var sceneIsActive = true
    private var heartbeatSession: URLSession?
    private var heartbeatTickCounter = 0
    private var zeroTrafficStreakSeconds = 0
    private var heartbeatConsecutiveFailures = 0
    private var slowLatencyStreak = 0
    /// 慢请求时间窗（仅窗口内的慢请求参与判定——跨小时累积会把正常的外部慢误判为持续异常）
    private var slowRecords: [(date: Date, host: String)] = []
    /// 慢请求判定窗口（秒）
    nonisolated static let slowWindow: TimeInterval = 60
    /// 高延迟横幅冷却（秒）：同一异常不重复打扰（冷却期内再次命中只留 INFO）
    nonisolated static let bannerCooldown: TimeInterval = 300
    /// 上次高延迟横幅时间
    private var lastHighLatencyBannerTime = Date(timeIntervalSince1970: 0)
    /// 媒体宿主慢观测日志节流时间
    private var lastMediaObservationLogTime = Date(timeIntervalSince1970: 0)
    /// 媒体宿主 / 大负载的慢请求观测日志节流时间（与告警节流分离，避免互相抑制）
    private var lastSlowObservationLogTime = Date(timeIntervalSince1970: 0)

    /// 媒体宿主判定：图片镜像 / CDN 类宿主的大图 TTFB 天然偏高（实测 www2 3.99MB 图 ≈2.55s），
    /// 单宿主慢属正常观测，不得升级为「链路异常」横幅
    nonisolated static func isMediaHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value.hasPrefix("www2.") || value.contains("img") || value.contains("pic")
            || value.contains("image") || value.contains("cdn")
    }

    /// 大负载阈值（字节）：镜像站大图 / 附件类传输的 TTFB 天然偏高（现场样本 www2 9.8MB ≈ 2.08s）
    nonisolated static let bulkBytesThreshold = 1_000_000

    /// 慢请求日志分级（纯函数，契约锚点）：
    /// 媒体宿主（图片镜像 / CDN）或**大负载**（≥1MB）的慢 = **正常观测**（INFO）；
    /// 其余（小负载的 API / 页面慢）= 待处理真异常（WARNING）
    nonisolated static func isObservationalSlowRequest(host: String?, bytes: Int) -> Bool {
        if bytes >= bulkBytesThreshold { return true }
        guard let host, !host.isEmpty else { return false }   // 无宿主按异常处理（fail-closed）
        return isMediaHost(host)
    }

    /// 慢请求聚合判定（纯函数）：
    /// ① ≥2 个不同宿主同时慢 → 链路级；② 非媒体宿主累计 ≥3 条 → 该主机服务异常；
    /// ③ 仅单一媒体宿主慢 → 仅观测（不打横幅）
    nonisolated static func classifySlowStreak(hosts: [String]) -> SlowStreakVerdict {
        guard !hosts.isEmpty else { return .none }
        let distinctHosts = Set(hosts.map { $0.lowercased() })
        if distinctHosts.count >= 2 { return .linkWide }
        let host = distinctHosts.first ?? ""
        let enoughStreak = hosts.count >= 3
        if isMediaHost(host) { return enoughStreak ? .mediaObservation : .none }
        return enoughStreak ? .hostService : .none
    }
    private var lastHeartbeatAggregateLogTime = Date(timeIntervalSince1970: 0)
    private var emaThroughput: Double = 0
    /// 分钟摘要缓冲
    private var minuteSlot = -1
    private var minuteSlotSum: Double = 0
    private var minuteSlotCount = 0
    private var minuteSlotPeak: Double = 0
    /// 单飞锁
    private var probeIsRunning = false
    private var speedTestIsRunning = false
    /// 诊断历史（内存，容量 3）
    private var probeHistoryStorage: [ProbeSummary] = []
    /// 时间线持久化
    private static let timelineEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let timelineDecoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    /// 心跳/探测/测速共用 UA（nonisolated 纯常量：允许 Task 内嵌套函数等非隔离上下文安全引用，2026-09-27 消除 Swift 6 模式警告）
    private nonisolated static let probeUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    @AppStorage(NetmonKey.chartWindow) private var storedChartWindow: Int = 60
    /// 图表窗口秒数（@Published 立即驱动 UI；同时持久化 @AppStorage）
    @Published private(set) var chartWindow: Int = 60

    /// 切换采样窗口（30s/60s/120s），即时刷新图表
    func setChartWindow(_ seconds: Int) {
        let clamped = max(1, min(seconds, 120))
        guard clamped != chartWindow else { return }
        chartWindow = clamped
        storedChartWindow = clamped
        LogManager.shared.debugLog("netmon", "采样窗口切换", context: ["window": "\(clamped)s"])
    }

    // MARK: 初始化

    private init() {
        sessionStartAt = Date()
        heartbeatEnabled = UserDefaults.standard.object(forKey: NetmonKey.samplingEnabled) as? Bool ?? true
        chartWindow = storedChartWindow

        startPathMonitor()
        startAggregator()
        restoreTimeline()
        restoreLastProbe()
        rolloverTodayTrafficIfNeeded(forceLoad: true)

        let defaults = UserDefaults.standard
        if defaults.object(forKey: NetmonKey.samplingEnabled) == nil {
            defaults.set(true, forKey: NetmonKey.samplingEnabled)
            heartbeatEnabled = true
        }

        LogManager.shared.info("netmon", "网络监测中枢初始化完成", context: [
            "samplesCapacity": "120",
            "heartbeatEnabled": "\(heartbeatEnabled)",
            "timelinePersisted": "\(linkTimeline.count)",
            "lastProbeRestored": "\(lastPersistedProbe != nil)",
            "platform": UIDevice.current.systemVersion
        ])
    }

    // MARK: - 链路感知

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.apply(path: path)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func apply(path: NWPath) {
        let statusText: String
        switch path.status {
        case .satisfied: statusText = "已连接"
        case .unsatisfied: statusText = "无网络"
        case .requiresConnection: statusText = "等待连接"
        @unknown default: statusText = "未知"
        }

        let reasonText: String
        if path.status == .unsatisfied {
            switch path.unsatisfiedReason {
            case .notAvailable: reasonText = "网络不可用"
            case .cellularDenied: reasonText = "蜂窝被拒绝"
            case .wifiDenied: reasonText = "Wi-Fi 被拒绝"
            case .localNetworkDenied: reasonText = "本地网络被拒绝"
            default: reasonText = "未知原因"
            }
        } else {
            reasonText = "—"
        }

        let iface: String
        if path.usesInterfaceType(.wifi) { iface = "Wi-Fi" }
        else if path.usesInterfaceType(.cellular) { iface = "蜂窝网络" }
        else if path.usesInterfaceType(.wiredEthernet) { iface = "有线网络" }
        else if path.usesInterfaceType(.loopback) { iface = "回环" }
        else { iface = "未知" }

        // iOS 26 链路质量（低版本一律「系统未提供」）
        var qualityText = "系统未提供"
        if #available(iOS 26.0, *) {
            switch path.linkQuality {
            case .good: qualityText = "优秀"
            case .moderate: qualityText = "良好"
            case .minimal: qualityText = "一般"
            case .unknown: qualityText = "未知"
            @unknown default: qualityText = "未知"
            }
        }
        let ultraConstrained: Bool = {
            if #available(iOS 26.0, *) { return path.isUltraConstrained }
            return false
        }()

        // 网关地址（首个 IPv4 网关）
        var gateway = "—"
        for gw in path.gateways {
            if case .hostPort(let host, _) = gw, case .ipv4(let ipv4) = host {
                gateway = "\(ipv4)".replacingOccurrences(of: "%", with: "")
                break
            }
        }

        // 链路去抖：仅实质变化时记录
        let changed = pathStatus != statusText
            || interfaceName != iface
            || isExpensive != path.isExpensive
            || isConstrained != path.isConstrained
            || linkQualityText != qualityText
            || isUltraConstrained != ultraConstrained
            || supportsIPv4 != path.supportsIPv4
            || supportsIPv6 != path.supportsIPv6
            || supportsDNS != path.supportsDNS

        // 仅实质变化时写状态（NWPath 事件可能高频重复，避免无效 View 失效与身份快照刷屏）
        guard changed else { return }

        pathStatus = statusText
        unsatisfiedReason = reasonText
        interfaceName = iface
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        linkQualityText = qualityText
        isUltraConstrained = ultraConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
        interfaceCount = path.availableInterfaces.count
        gatewayAddress = gateway

        // 断网 / 恢复时间线
        if changed {
            if statusText == "无网络" {
                appendLinkEvent(.init(kind: .outage, status: statusText, interface: iface, reason: reasonText))
                LogManager.shared.warning("netmon", "链路断开", context: [
                    "status": statusText, "interface": iface, "reason": reasonText
                ])
            } else if pathStatusBeforeWasOffline {
                appendLinkEvent(.init(kind: .recovery, status: statusText, interface: iface, reason: reasonText))
                LogManager.shared.info("netmon", "链路恢复", context: [
                    "status": statusText, "interface": iface
                ])
            }
            // iOS 26 新指标变化单独记
            LogManager.shared.debugLog("netmon", "链路状态发生实质变化", context: [
                "status": statusText,
                "interface": iface,
                "reason": reasonText,
                "expensive": "\(path.isExpensive)",
                "constrained": "\(path.isConstrained)",
                "linkQuality": qualityText,
                "ultraConstrained": "\(ultraConstrained)",
                "ipv4": "\(path.supportsIPv4)",
                "ipv6": "\(path.supportsIPv6)",
                "dns": "\(path.supportsDNS)",
                "interfaceCount": "\(path.availableInterfaces.count)"
            ])
        }

        // 网络身份快照刷新（链路每次变化时取一次本机 IP）
        refreshNetworkIdentity()

        pathStatusBeforeWasOffline = statusText == "无网络"
    }

    /// 前一次链路状态是否离线（供恢复事件判定）
    private var pathStatusBeforeWasOffline = false

    /// 本机 IPv4 + 校园网网段判断（getifaddrs 正规 API，零权限）
    private var lastIdentityLogTime = Date(timeIntervalSince1970: 0)

    private func refreshNetworkIdentity() {
        guard let ip = Self.currentIPv4Address() else { return }
        let changed = ipv4Address != ip
        ipv4Address = ip
        isCampusLAN = ip.hasPrefix("10.")
            || (ip.hasPrefix("172.") && Self.ipSecondOctetInRange(ip, 16...31))
            || ip.hasPrefix("192.168.")
        // 身份快照日志 30s 节流（链路高频变化时防刷屏）
        let now = Date()
        if changed || now.timeIntervalSince(lastIdentityLogTime) >= 30 {
            lastIdentityLogTime = now
            LogManager.shared.debugLog("netmon", "网络身份快照更新", context: [
                "ipv4": ip, "gateway": gatewayAddress, "campusLAN": "\(isCampusLAN)"
            ])
        }
    }

    nonisolated static func currentIPv4Address() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let base = addr else { return nil }
        defer { freeifaddrs(base) }
        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = base
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let ifa = cur.pointee
            guard let sa = ifa.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                 &hostBuffer, socklen_t(hostBuffer.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: hostBuffer)
            guard ip != "127.0.0.1", !ip.hasPrefix("169.254.") else { continue }
            let name = ifa.ifa_name.map { String(cString: $0) } ?? ""
            // 优先物理无线/蜂窝接口；VPN（utun）等场景回退任一有效网卡
            if name.hasPrefix("en") || name.hasPrefix("pdp") {
                return ip
            }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    private static func ipSecondOctetInRange(_ ip: String, _ range: ClosedRange<Int>) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count >= 2, let second = Int(parts[1]) else { return false }
        return range.contains(second)
    }

    // MARK: - 采样聚合（1s 桶 → 120 点环形 + EMA/峰值/并发/分钟摘要/覆盖度/档位/异常）

    private func startAggregator() {
        aggregateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        aggregateTimer?.tolerance = 0.2
    }

    private func tick() {
        let bucket = NetworkMonitorLedger.shared.drainBucket()

        let now = Date()
        let downKBps = Double(bucket.bytes) / 1024.0
        let upKBps = Double(bucket.upBytes) / 1024.0
        let avgLatency = bucket.latCount > 0 ? bucket.latSum / Double(bucket.latCount) : 0

        // 上行总量累计（会话 + 今日），与上行曲线同源（审计修复：此前仅曲线有值、总量恒 0）
        totalUpBytes += bucket.upBytes
        todayUpBytes += bucket.upBytes

        // EMA 瞬时吞吐（无流量时指数衰减趋零，杜绝「停表冻结」误导）
        if bucket.bytes > 0 {
            emaThroughput = 0.35 * downKBps + 0.65 * emaThroughput
            zeroTrafficStreakSeconds = 0
        } else {
            emaThroughput *= 0.8
            zeroTrafficStreakSeconds += 1
        }
        instantaneousKBps = emaThroughput
        if downKBps > peakKBps { peakKBps = downKBps }

        // 覆盖度 = 已积累采样 / 120 槽
        coveragePercent = Double(samples.count) / 120.0
        nextSampleID += 1
        let sample = NetworkTrafficSample(
            id: nextSampleID,
            second: now,
            throughputKBps: downKBps,
            uploadKBps: upKBps,
            latencyMs: avgLatency,
            isFailure: false,
            isHeartbeat: false,
            inFlightCount: NetworkMonitorLedger.shared.inFlightCount
        )
        inFlightCount = sample.inFlightCount
        withAnimation(.easeOut(duration: 0.3)) {
            samples.append(sample)
            if samples.count > 120 {
                samples.removeFirst(samples.count - 120)
            }
        }

        // 覆盖度 = 已积累采样 / 120 槽
        coveragePercent = Double(samples.count) / 120.0

        // 趋势：最近 10 个有效延迟采样最小二乘斜率
        updateTrendDirection()

        // 分钟摘要（环形 60 槽）
        accumulateMinuteSummary(downKBps: downKBps)

        // 心跳调度（tick 计数，interval 由 tier 决定）
        heartbeatTickCounter += 1
        if liveSamplingActive && sceneIsActive && heartbeatEnabled
            && !probeIsRunning && !speedTestIsRunning
            && heartbeatTickCounter >= samplingTier.intervalSeconds {
            heartbeatTickCounter = 0
            performHeartbeat()
        }

        // 档位迁移（≥2min 无流量 → 省电；≥5min → 深度省电；有流量即回实时）
        updateSamplingTier()

        // 今日流量批写（10s）
        if now.timeIntervalSince(lastTrafficFlushTime) >= 10 {
            lastTrafficFlushTime = now
            flushTodayTraffic()
        }
        // 午夜滚动
        rolloverTodayTrafficIfNeeded(forceLoad: false)

        // 吞吐周期聚合日志（30s）
        if now.timeIntervalSince(lastThroughputLogTime) >= 30 {
            lastThroughputLogTime = now
            let recent = samples.suffix(30).map(\.throughputKBps)
            let peak = recent.max() ?? 0
            let avg30 = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
            LogManager.shared.debugLog("netmon", "吞吐周期聚合", context: [
                "currentKBps": String(format: "%.1f", downKBps),
                "emaKBps": String(format: "%.1f", emaThroughput),
                "avg30sKBps": String(format: "%.1f", avg30),
                "peak30sKBps": String(format: "%.1f", peak),
                "upKBps": String(format: "%.2f", upKBps),
                "concurrent": "\(inFlightCount)",
                "coverage": String(format: "%.0f%%", coveragePercent * 100)
            ])
        }

        // 主机归因汇总日志（30s）
        if now.timeIntervalSince(lastHostStatsLogTime) >= 30 {
            lastHostStatsLogTime = now
            logHostStatsSummary()
        }
    }

    private func updateTrendDirection() {
        let valid = samples.suffix(10).filter { $0.latencyMs > 0 }
        guard valid.count >= 4 else { trendDirection = .stable; return }
        let n = Double(valid.count)
        let xs = (0..<valid.count).map { Double($0) }
        let meanX = xs.reduce(0, +) / n
        let meanY = valid.map(\.latencyMs).reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, v) in valid.enumerated() {
            num += (xs[i] - meanX) * (v.latencyMs - meanY)
            den += (xs[i] - meanX) * (xs[i] - meanX)
        }
        let slope = den > 0 ? num / den : 0
        let new: TrendDirection
        if slope > 0.8 { new = .rising }
        else if slope < -0.8 { new = .falling }
        else { new = .stable }
        if new != trendDirection {
            trendDirection = new
            LogManager.shared.debugLog("netmon", "延迟趋势变化", context: [
                "direction": new.rawValue, "slope": String(format: "%.2f", slope)
            ])
        }
    }

    private func accumulateMinuteSummary(downKBps: Double) {
        let now = Date()
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let hourMinuteKey = (comps.hour ?? 0) * 100 + (comps.minute ?? 0)
        if hourMinuteKey != minuteSlot {
            if minuteSlot >= 0 {
                let slotDate = calendar.date(from: comps) ?? now
                minuteSummaries.append(MinuteSummary(
                    minute: slotDate,
                    avgKBps: minuteSlotCount > 0 ? minuteSlotSum / Double(minuteSlotCount) : 0,
                    peakKBps: minuteSlotPeak
                ))
                if minuteSummaries.count > 60 {
                    minuteSummaries.removeFirst(minuteSummaries.count - 60)
                }
            }
            minuteSlot = hourMinuteKey
            minuteSlotSum = 0
            minuteSlotCount = 0
            minuteSlotPeak = 0
        }
        if downKBps > 0 {
            minuteSlotSum += downKBps
            minuteSlotCount += 1
            minuteSlotPeak = max(minuteSlotPeak, downKBps)
        }
    }

    private func updateSamplingTier() {
        let newTier: SamplingTier
        if zeroTrafficStreakSeconds >= 300 {
            newTier = .deepSaving
        } else if zeroTrafficStreakSeconds >= 120 {
            newTier = .saving
        } else {
            newTier = .live
        }
        if newTier != samplingTier {
            let from = samplingTier
            samplingTier = newTier
            heartbeatTickCounter = 0
            LogManager.shared.info("netmon", "智能节能档位切换", context: [
                "from": from.rawValue, "to": newTier.rawValue,
                "trigger": zeroTrafficStreakSeconds >= 300 ? "5min_no_traffic"
                    : (zeroTrafficStreakSeconds >= 120 ? "2min_no_traffic" : "traffic_resumed"),
                "interval": "\(newTier.intervalSeconds)s"
            ])
        }
    }

    // MARK: - 心跳实时采样（热连接复用干净会话；成败都落点）

    func beginLiveSampling() {
        liveSamplingTokenCount += 1
        updateLiveSamplingState()
        if liveSamplingActive {
            LogManager.shared.info("netmon", "心跳实时采样启动", context: [
                "tier": samplingTier.rawValue, "interval": "\(samplingTier.intervalSeconds)s"
            ])
        }
    }

    func endLiveSampling() {
        guard liveSamplingTokenCount > 0 else { return }
        liveSamplingTokenCount -= 1
        updateLiveSamplingState()
        if !liveSamplingActive {
            LogManager.shared.info("netmon", "心跳实时采样停止", context: [
                "succeeded": "\(heartbeatSucceeded)", "failed": "\(heartbeatFailed)"
            ])
            teardownHeartbeatSession()
        }
    }

    /// 场景前后台门控（退后台暂停发射，防 iOS 挂起误判离线）
    func setSceneActive(_ active: Bool) {
        guard sceneIsActive != active else { return }
        sceneIsActive = active
        if !active {
            if liveSamplingActive {
                LogManager.shared.info("netmon", "心跳采样因退后台暂停", context: [:])
            }
            flushTodayTraffic()
            flushTimeline()
        } else if liveSamplingActive {
            heartbeatConsecutiveFailures = 0
            LogManager.shared.info("netmon", "心跳采样前台恢复", context: [:])
        }
    }

    private func updateLiveSamplingState() {
        let shouldRun = liveSamplingTokenCount > 0
        if shouldRun != liveSamplingActive {
            liveSamplingActive = shouldRun
            heartbeatTickCounter = 0
        }
        if shouldRun && heartbeatSession == nil {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.waitsForConnectivity = false
            config.protocolClasses = nil
            heartbeatSession = URLSession(configuration: config)
            refreshNetworkIdentity()
        }
    }

    private func teardownHeartbeatSession() {
        heartbeatSession?.invalidateAndCancel()
        heartbeatSession = nil
    }

    private func performHeartbeat() {
        guard let session = heartbeatSession,
              let url = URL(string: ProbeTarget.gateway.urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.probeUserAgent, forHTTPHeaderField: "User-Agent")
        let started = Date()
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            let ok: Bool
            var rtt = 0.0
            var byteCount = 0
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                ok = (200...299).contains(status) || status == 403 || status == 404
                rtt = Date().timeIntervalSince(started) * 1000
                byteCount = data.count
            } catch {
                ok = false
                rtt = Date().timeIntervalSince(started) * 1000
            }
            await MainActor.run {
                self.applyHeartbeatResult(ok: ok, rtt: rtt, byteCount: byteCount)
            }
        }
    }

    private func applyHeartbeatResult(ok: Bool, rtt: Double, byteCount: Int) {
        if ok {
            heartbeatSucceeded += 1
            heartbeatConsecutiveFailures = 0
            slowLatencyStreak = 0
            clearAnomalyIfResolved()
        } else {
            heartbeatFailed += 1
            heartbeatConsecutiveFailures += 1
        }
        heartbeatLastRTTMs = rtt

        // 心跳成败都落采样点：失败 throughput=0，断网曲线归零而非冻结
        // 成功点吞吐 = 响应字节 / 耗时（真实口径，无请求体上行记 0）
        let usableKBps = ok && rtt > 0 ? (Double(byteCount) / 1024.0) / (rtt / 1000.0) : 0
        nextSampleID += 1
        let sample = NetworkTrafficSample(
            id: nextSampleID,
            second: Date(),
            throughputKBps: usableKBps,
            uploadKBps: 0,
            latencyMs: ok && rtt > 0 ? rtt : 0,
            isFailure: !ok,
            isHeartbeat: true,
            inFlightCount: inFlightCount
        )
        withAnimation(.easeOut(duration: 0.3)) {
            samples.append(sample)
            if samples.count > 120 {
                samples.removeFirst(samples.count - 120)
            }
        }

        // 异常预警：心跳连败 ≥3 → 链路不稳定
        if heartbeatConsecutiveFailures >= 3 && anomalyKind == nil {
            anomalyKind = .unstableLink
            appendLinkEvent(.init(kind: .anomaly, status: "链路不稳定", interface: interfaceName,
                                  reason: "心跳连续失败 \(heartbeatConsecutiveFailures) 次"))
            LogManager.shared.warning("netmon", "异常横幅出现：心跳连续失败", context: [
                "failures": "\(heartbeatConsecutiveFailures)", "rttMs": String(format: "%.0f", rtt)
            ])
        }

        // 心跳聚合统计日志（30s）
        let now = Date()
        if now.timeIntervalSince(lastHeartbeatAggregateLogTime) >= 30 {
            lastHeartbeatAggregateLogTime = now
            LogManager.shared.debugLog("netmon", "心跳聚合统计", context: [
                "ok": "\(heartbeatSucceeded)", "fail": "\(heartbeatFailed)",
                "lastRttMs": String(format: "%.0f", rtt),
                "tier": samplingTier.rawValue,
                "sceneActive": "\(sceneIsActive)"
            ])
        }
    }

    /// 业务慢请求聚合（60s 时间窗 + 宿主归因 + 横幅冷却）：
    /// 单宿主慢不再直接升级为横幅——媒体宿主（图片镜像）TTFB 天然偏高，属正常观测；
    /// 仅「多宿主同时慢（链路级）」或「非媒体宿主自身连续慢（服务级）」才出异常横幅
    private func registerBusinessLatency(_ latency: Double, success: Bool, host: String?) {
        let now = Date()
        slowRecords.removeAll { now.timeIntervalSince($0.date) > Self.slowWindow }   // 跨小时累积会误报
        if success && latency >= 1000 {
            slowRecords.append((now, host ?? "unknown"))
            slowLatencyStreak = slowRecords.count
            let verdict = Self.classifySlowStreak(hosts: slowRecords.map { $0.host })
            switch verdict {
            case .none:
                break
            case .mediaObservation:
                // 单一媒体宿主慢：观测留痕（INFO，不打扰；慢主机归因与趋势里仍可见）
                if now.timeIntervalSince(lastMediaObservationLogTime) >= Self.slowWindow {
                    lastMediaObservationLogTime = now
                    LogManager.shared.info("netmon", "慢主机观测（媒体宿主，不计链路异常）", context: [
                        "host": host ?? "unknown",
                        "latencyMs": String(format: "%.0f", latency),
                        "streak": "\(slowRecords.count)"
                    ])
                }
            case .hostService, .linkWide:
                guard anomalyKind == nil else { break }
                guard now.timeIntervalSince(lastHighLatencyBannerTime) >= Self.bannerCooldown else {
                    LogManager.shared.info("netmon", "高延迟横幅冷却中（不重复打扰）", context: [
                        "verdict": verdict.rawValue, "host": host ?? "unknown"
                    ])
                    break
                }
                anomalyKind = .highLatency
                lastHighLatencyBannerTime = now
                appendLinkEvent(.init(kind: .anomaly, status: "延迟偏高", interface: interfaceName,
                                      reason: verdict == .linkWide
                                          ? "多个宿主首字节同时 ≥ 1s（链路级）"
                                          : "该主机连续 3 条请求首字节 ≥ 1s（服务级）"))
                LogManager.shared.warning("netmon", "异常横幅出现：延迟持续偏高", context: [
                    "host": host ?? "unknown",
                    "streak": "\(slowRecords.count)",
                    "verdict": verdict.rawValue,
                    "hosts": "\(Set(slowRecords.map { $0.host }).count)"
                ])
            }
        } else if success && latency < 500 {
            if slowLatencyStreak > 0 || !slowRecords.isEmpty {
                LogManager.shared.info("netmon", "延迟恢复，异常解除", context: [
                    "host": host ?? "unknown", "latencyMs": String(format: "%.0f", latency)
                ])
                slowLatencyStreak = 0
                slowRecords.removeAll()
                clearAnomalyIfResolved()
            }
        }
    }

    private func clearAnomalyIfResolved() {
        guard anomalyKind != nil else { return }
        if heartbeatConsecutiveFailures == 0 && slowLatencyStreak == 0 {
            let kind = anomalyKind!
            anomalyKind = nil
            LogManager.shared.info("netmon", "异常横幅消失", context: ["kind": kind.rawValue])
        }
    }

    // MARK: - URLProtocol 埋点接口（nonisolated static：任意线程安全）

    nonisolated static func tapRequestStart(host: String?) -> UInt64 {
        NetworkMonitorLedger.shared.requestStart(host: host)
    }

    nonisolated static func tapData(token: UInt64, bytes: Int) {
        NetworkMonitorLedger.shared.addData(token: token, bytes: bytes)
    }

    /// 上行字节（请求体估算；仅内存 httpBody）
    nonisolated static func tapUpload(token: UInt64, bytes: Int) {
        NetworkMonitorLedger.shared.addUpData(token: token, bytes: bytes)
    }

    /// 首字节时刻（协议层 didReceive 时调用）——netmon TTFB 口径入口（2026-09-27）
    nonisolated static func tapFirstByte(token: UInt64) {
        NetworkMonitorLedger.shared.markFirstByte(token: token)
    }

    nonisolated static func tapAbandon(token: UInt64) {
        NetworkMonitorLedger.shared.abandon(token: token)
    }

    nonisolated static func tapComplete(token: UInt64, success: Bool) {
        guard let entry = NetworkMonitorLedger.shared.complete(token: token) else { return }
        DispatchQueue.main.async {
            SJZNetworkMonitor.shared.absorbCompletion(entry: entry, success: success)
        }
    }

    /// URLProtocol 侧直取：请求体上行估算（httpBody 可安全读取；流式上行未计量）
    nonisolated static func tapUploadEstimate(for request: URLRequest, token: UInt64) {
        guard let body = request.httpBody, !body.isEmpty else { return }
        tapUpload(token: token, bytes: body.count)
    }

    private func absorbCompletion(entry: (latency: Double, ttfb: Double?, bytes: Int64, host: String?), success: Bool) {
        totalRequests += 1
        if success { successRequests += 1 } else { failedRequests += 1 }
        // 响应延迟指标统一 TTFB 口径（无响应头的失败回退总时长），避免大图下载时长被误判为「链路慢」（2026-09-27）
        let effectiveLatency = entry.ttfb ?? entry.latency
        lastLatencyMs = effectiveLatency
        latencySumMs += effectiveLatency
        totalBytes += entry.bytes
        todayDownBytes += entry.bytes
        switch effectiveLatency {
        case ..<100: latencyHistogram[0] += 1
        case ..<300: latencyHistogram[1] += 1
        case ..<1000: latencyHistogram[2] += 1
        default: latencyHistogram[3] += 1
        }

        // 主机归因（主线程聚合，安全）
        if let host = entry.host, !host.isEmpty {
            var stat = perHostStats[host] ?? (0, 0, 0, 0)
            stat.bytes += entry.bytes
            stat.latSum += effectiveLatency
            stat.count += 1
            if !success { stat.failures += 1 }
            perHostStats[host] = stat
        }

        registerBusinessLatency(effectiveLatency, success: success, host: entry.host)

        if !success {
            // 失败告警 10s 节流：断网批量失败防刷屏（失败数持续累计在 context 中）
            let now = Date()
            if now.timeIntervalSince(lastFailureLogTime) >= 10 {
                lastFailureLogTime = now
                LogManager.shared.warning("netmon", "请求失败（协议层观测）", context: [
                    "host": entry.host ?? "unknown",
                    "latencyMs": String(format: "%.0f", effectiveLatency),
                    "failedTotal": "\(failedRequests)",
                    "successRate": String(format: "%.1f%%", successRate * 100)
                ])
            }
            return
        }

        if effectiveLatency >= 1000 {
            let now = Date()
            // 分级（2026-09-28 现场：www2 9.8MB 大图 TTFB 2.08s 被记为 WARNING）：
            // 媒体宿主 / 大负载的慢属**正常观测**（INFO，60s 节流）；小负载非媒体宿主慢才是待处理真异常（WARNING，10s 节流）
            if Self.isObservationalSlowRequest(host: entry.host, bytes: Int(entry.bytes)) {
                if now.timeIntervalSince(lastSlowObservationLogTime) >= 60 {
                    lastSlowObservationLogTime = now
                    LogManager.shared.info("netmon", "慢请求观测（媒体宿主 / 大负载，属正常）", context: [
                        "host": entry.host ?? "unknown",
                        "latencyMs": String(format: "%.0f", effectiveLatency),
                        "bytes": "\(entry.bytes)",
                        "preview": ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file),
                        "sessionSlowCount": "\(latencyHistogram[3])"
                    ])
                }
            } else if now.timeIntervalSince(lastSlowRequestLogTime) >= 10 {
                lastSlowRequestLogTime = now
                LogManager.shared.warning("netmon", "慢请求告警（首字节 ≥ 1s）", context: [
                    "host": entry.host ?? "unknown",
                    "latencyMs": String(format: "%.0f", effectiveLatency),
                    "bytes": "\(entry.bytes)",
                    "sessionSlowCount": "\(latencyHistogram[3])"
                ])
            }
            return
        }

        successBatchCount += 1
        successBatchBytes += entry.bytes
        successBatchLatencySum += effectiveLatency
        if successBatchCount >= 50 {
            let avgLatency = successBatchLatencySum / Double(successBatchCount)
            LogManager.shared.debugLog("netmon", "成功请求批量统计", context: [
                "batchCount": "\(successBatchCount)",
                "batchBytes": ByteCountFormatter.string(fromByteCount: successBatchBytes, countStyle: .file),
                "avgLatencyMs": String(format: "%.0f", avgLatency)
            ])
            successBatchCount = 0
            successBatchBytes = 0
            successBatchLatencySum = 0
        }
    }

    private func logHostStatsSummary() {
        guard !perHostStats.isEmpty else { return }
        let slow = perHostStats
            .filter { $0.value.count >= 3 }
            .map { (host: $0.key, avg: $0.value.latSum / Double($0.value.count)) }
            .sorted { $0.avg > $1.avg }
            .prefix(3)
            .map { "\($0.host)=\(String(format: "%.0f", $0.avg))ms" }
        let domains = perHostStats.map { (host: $0.key, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(5)
            .map { "\($0.host)=\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" }
        LogManager.shared.debugLog("netmon", "主机归因汇总", context: [
            "slowHostsTop3": slow.joined(separator: ", "),
            "domainsTop5": domains.joined(separator: ", ")
        ])
    }

    // MARK: - 派生指标

    var successRate: Double {
        totalRequests > 0 ? Double(successRequests) / Double(totalRequests) : 1
    }

    var averageLatencyMs: Double {
        totalRequests > 0 ? latencySumMs / Double(totalRequests) : 0
    }

    var currentThroughputKBps: Double { samples.last?.throughputKBps ?? 0 }

    /// 慢主机 TOP3（≥3 请求才上榜）
    var slowHostsTop3: [(host: String, avgMs: Double, failures: Int)] {
        perHostStats
            .filter { $0.value.count >= 3 }
            .map { ($0.key, $0.value.latSum / Double($0.value.count), $0.value.failures) }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { ($0.0, $0.1, $0.2) }
    }

    /// 流量域分布（字节占比降序前 5）
    var domainDistribution: [(host: String, bytes: Int64)] {
        perHostStats.map { ($0.key, $0.value.bytes) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { ($0.0, $0.1) }
    }

    // MARK: - 一键网络诊断（双目标 + 历史 + 健康分 + 建议）

    func runProbe() {
        guard !probeIsRunning, !speedTestIsRunning else { return }
        probeIsRunning = true
        probeState = .running(target: .gateway, round: 0, total: 5)
        LogManager.shared.info("netmon", "网络诊断开始", context: [
            "targets": ProbeTarget.allCases.map(\.rawValue).joined(separator: ","),
            "roundsPerTarget": "5"
        ])

        Task { [weak self] in
            guard let self else { return }
            defer { self.probeIsRunning = false }
            NetworkMonitorLedger.shared.setSuspended(true)
            defer { NetworkMonitorLedger.shared.setSuspended(false) }

            let gatewayResult = await self.probeRound(for: .gateway)
            guard let gateway = gatewayResult else {
                self.probeState = .failed("无法连接学校服务器，请检查网络")
                LogManager.shared.warning("netmon", "网络诊断失败：网关目标全部超时", context: [:])
                return
            }
            // 副目标：官网门户（失败不阻断）
            let portal = await self.probeRound(for: .portal)

            let score = Self.healthScore(linkQualityText: self.linkQualityText,
                                         p90: gateway.p90,
                                         lossRate: gateway.lossRate,
                                         throughputKBps: self.instantaneousKBps)
            let grade = Self.gradeText(score)
            let advice = Self.advice(for: gateway, healthScore: score)
            let summary = ProbeSummary(
                date: Date(),
                gateway: gateway,
                portal: portal,
                healthScore: score,
                gradeText: grade,
                adviceTitles: advice.map(\.text)
            )

            self.healthScore = score
            self.probeHistoryStorage.insert(summary, at: 0)
            if self.probeHistoryStorage.count > 3 {
                self.probeHistoryStorage.removeLast(self.probeHistoryStorage.count - 3)
            }
            self.probeHistory = self.probeHistoryStorage
            self.lastPersistedProbe = summary
            self.persistLastProbe(summary)
            self.probeState = .done(summary)

            LogManager.shared.info("netmon", "网络诊断完成", context: [
                "gatewayP50": String(format: "%.0fms", gateway.p50),
                "gatewayP90": String(format: "%.0fms", gateway.p90),
                "portalP50": portal.map { String(format: "%.0fms", $0.p50) } ?? "n/a",
                "loss": String(format: "%.0f%%", gateway.lossRate * 100),
                "dns": ProbeResult.stageText(gateway.dnsMs),
                "tcp": ProbeResult.stageText(gateway.tcpMs),
                "tls": ProbeResult.stageText(gateway.tlsMs),
                "ttfb": ProbeResult.stageText(gateway.ttfbMs),
                "protocol": gateway.protocolName ?? "unknown",
                "healthScore": "\(score)",
                "grade": grade,
                "adviceCount": "\(advice.count)",
                "historyPersisted": "true"
            ])
        }
    }

    /// 单目标 5 轮冷连接探测（每轮全新 ephemeral 会话）
    private func probeRound(for target: ProbeTarget) async -> ProbeResult? {
        guard let probeURL = URL(string: target.urlString) else {
            return nil
        }
        var rtts: [Double] = []
        var failures = 0
        var dnsL: [Double] = []
        var tcpL: [Double] = []
        var tlsL: [Double] = []
        var ttfbL: [Double] = []
        var protocolName: String?
        var isIPv6 = false
        let rounds = 5
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.probeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.sxjzit.edu.cn/", forHTTPHeaderField: "Referer")

        for i in 0..<rounds {
            self.probeState = .running(target: target, round: i, total: rounds)
            let start = CFAbsoluteTimeGetCurrent()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.protocolClasses = nil
            config.waitsForConnectivity = false
            let collector = ProbeMetricsCollector()
            let roundSession = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
            defer { roundSession.invalidateAndCancel() }
            do {
                _ = try await roundSession.data(for: request)
                rtts.append((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
                if let tm = collector.metrics?.transactionMetrics.first {
                    if let t = tm.domainLookupStartDate, let e = tm.domainLookupEndDate,
                       let f = tm.fetchStartDate, t >= f {
                        dnsL.append(e.timeIntervalSince(t) * 1000)
                    }
                    if let t = tm.connectStartDate, let e = tm.connectEndDate { tcpL.append(e.timeIntervalSince(t) * 1000) }
                    if let t = tm.secureConnectionStartDate, let e = tm.secureConnectionEndDate { tlsL.append(e.timeIntervalSince(t) * 1000) }
                    if let t = tm.requestEndDate, let e = tm.responseStartDate { ttfbL.append(e.timeIntervalSince(t) * 1000) }
                    if protocolName == nil { protocolName = tm.networkProtocolName }
                    if let remote = collector.remoteHost, remote.contains(":") && !remote.contains(".") {
                        isIPv6 = true
                    } else if let remote = collector.remoteHost {
                        isIPv6 = remote.components(separatedBy: ":").count > 2
                    }
                }
                LogManager.shared.debugLog("netmon", "诊断探测轮次完成", context: [
                    "target": target.rawValue,
                    "round": "\(i + 1)/\(rounds)",
                    "rttMs": String(format: "%.0f", rtts.last ?? 0)
                ])
            } catch {
                failures += 1
                LogManager.shared.debugLog("netmon", "诊断探测轮次失败", context: [
                    "target": target.rawValue,
                    "round": "\(i + 1)/\(rounds)",
                    "error": (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? error.localizedDescription
                ])
            }
        }
        let lossRate = Double(failures) / Double(rounds)
        guard !rtts.isEmpty else { return nil }
        let median: ([Double]) -> Double? = { values in
            let s = values.sorted()
            guard !s.isEmpty else { return nil }
            return s[s.count / 2]
        }
        return ProbeResult(
            rtts: rtts,
            lossRate: lossRate,
            dnsMs: median(dnsL),
            tcpMs: median(tcpL),
            tlsMs: median(tlsL),
            ttfbMs: median(ttfbL),
            protocolName: protocolName,
            isRemoteIPv6: isIPv6
        )
    }

    // MARK: - 健康分与建议（纯函数，可测）

    /// 健康分 0-100：链路质量 35 + P90 30 + 丢包 20 + 吞吐 15（纯函数，任意线程可调）
    nonisolated static func healthScore(linkQualityText: String?, p90: Double, lossRate: Double, throughputKBps: Double) -> Int {
        let cq: Int
        switch linkQualityText {
        case "优秀": cq = 35
        case "良好": cq = 22
        case "一般": cq = 10
        case "未知", _:
            cq = 15  // 低版本/系统未提供 → 中性分
        }
        let p90m: Int
        switch p90 {
        case ..<100: p90m = 30
        case ..<250: p90m = 22
        case ..<500: p90m = 12
        case ..<1000: p90m = 5
        default: p90m = 0
        }
        let loss: Int
        if lossRate <= 0 { loss = 20 }
        else if lossRate <= 0.2 { loss = 14 }
        else if lossRate <= 0.5 { loss = 6 }
        else { loss = 0 }
        let tp = min(throughputKBps / 300.0, 1.0) * 15
        return min(100, max(0, cq + p90m + loss + Int(tp.rounded())))
    }

    nonisolated static func gradeText(_ score: Int) -> String {
        switch score {
        case 85...: return "优秀"
        case 70...: return "良好"
        case 50...: return "一般"
        default: return "较差"
        }
    }

    /// 优化建议生成器（规则映射，纯函数，任意线程可调）
    nonisolated static func advice(for gateway: ProbeResult, healthScore: Int) -> [HealthAdvice] {
        var out: [HealthAdvice] = []
        var id = 0
        if gateway.lossRate > 0.2 {
            out.append(HealthAdvice(id: id, icon: "location.circle",
                                    text: "丢包率 \(String(format: "%.0f", gateway.lossRate * 100))%，信号较弱，建议靠近路由器或切换网络"))
            id += 1
        }
        if gateway.p90 > 500 && (gateway.dnsMs ?? 0) < 50 {
            out.append(HealthAdvice(id: id, icon: "building.2",
                                    text: "DNS 很快但响应慢，校园网出口可能拥塞，建议错峰或切换 5G"))
            id += 1
        }
        if let tls = gateway.tlsMs, tls > 150 {
            out.append(HealthAdvice(id: id, icon: "lock.shield",
                                    text: "安全握手耗时 \(String(format: "%.0f", tls))ms，属网关防护正常开销，可忽略"))
            id += 1
        }
        if out.isEmpty && healthScore >= 85 {
            out.append(HealthAdvice(id: id, icon: "checkmark.seal",
                                    text: "链路健康，视频与图片加载无瓶颈。晚高峰（20:00-22:00）如遇卡顿可切 5G"))
        } else if out.isEmpty {
            out.append(HealthAdvice(id: id, icon: "wifi",
                                    text: "链路可用，轻微波动。持续卡顿可尝试关闭 VPN 或重启 Wi-Fi"))
        }
        return out
    }

    // MARK: - 一键带宽测速（HEAD 挑源 + 循环下载真实资源）

    func runSpeedTest() {
        guard !speedTestIsRunning, !probeIsRunning else { return }
        speedTestIsRunning = true
        speedTestState = .running(progress: 0, downloadedMB: 0)
        LogManager.shared.info("netmon", "带宽测速开始", context: [:])

        Task { [weak self] in
            guard let self else { return }
            defer { self.speedTestIsRunning = false }
            NetworkMonitorLedger.shared.setSuspended(true)
            defer { NetworkMonitorLedger.shared.setSuspended(false) }

            // 1. 候选池：真实服务器图片（banner 封面 → 新闻图），host 必须为学校域
            var candidates: [URL] = []
            let data = DataService.shared
            for banner in data.banners {
                for raw in [banner.posterImgSrc, banner.videoTitleImgSrc] where !raw.isEmpty {
                    if let url = Self.resolvableSchoolURL(raw) {
                        candidates.append(url)
                        break
                    }
                }
                if candidates.count >= 6 { break }
            }
            if candidates.count < 6 {
                for item in data.news.prefix(10) {
                    if let raw = item.imageUrl, let url = Self.resolvableSchoolURL(raw) {
                        candidates.append(url)
                    }
                    if candidates.count >= 6 { break }
                }
            }
            guard !candidates.isEmpty else {
                self.speedTestState = .failed("当前无可测资源（尚未加载学校数据）")
                LogManager.shared.warning("netmon", "带宽测速失败：无可测资源", context: [:])
                return
            }

            // 2. HEAD 取 Content-Length，剔除 < 200KB 缩略图
            var best: (url: URL, length: Int64) = (candidates[0], -1)
            for url in candidates.prefix(6) {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                req.setValue(Self.probeUserAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("https://www.sxjzit.edu.cn/", forHTTPHeaderField: "Referer")
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let len = (resp as? HTTPURLResponse)?.expectedContentLength ?? -1
                    if len > best.length { best = (url, len) }
                } catch {
                    continue
                }
            }
            let note: String? = best.length > 0 && best.length < 500_000
                ? "资源样本较小（\(ByteCountFormatter.string(fromByteCount: best.length, countStyle: .file))），结果仅供参考"
                : nil
            LogManager.shared.info("netmon", "带宽测速资源选择", context: [
                "candidates": "\(candidates.count)",
                "chosenBytes": "\(best.length)",
                "note": note ?? "none"
            ])

            // 3. 循环下载至 8MB 或 10s（干净会话 + 手工头；内存丢弃不落盘）
            // 候选轮换：失败自动切换下一候选（防单资源被 WAF 限流/404）
            let targetURLs = ([best.url] + candidates.filter { $0 != best.url }).prefix(3).map { $0 }
            var targetIndex = 0

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.protocolClasses = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }

            func makeSpeedRequest(_ url: URL) -> URLRequest {
                var req = URLRequest(url: url)
                req.setValue(Self.probeUserAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("https://www.sxjzit.edu.cn/", forHTTPHeaderField: "Referer")
                req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                return req
            }
            var req = makeSpeedRequest(targetURLs[0])

            let deadline = Date().addingTimeInterval(10)
            let elapsedStart = Date()
            var totalBytes: Int64 = 0
            var windowBytes: Int64 = 0
            var windowStart = Date()
            var peakBps: Double = 0
            var errorOccurred = false
            var errorStreak = 0
            var firstErrorText: String? = nil

            while Date() < deadline {
                guard errorStreak < 3 else { break }   // 连续失败 3 次提前止损
                let remaining = 8_000_000 - totalBytes
                if remaining <= 0 { break }
                do {
                    let (data, resp) = try await session.data(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    totalBytes += Int64(data.count)
                    errorStreak = 0
                    windowBytes += Int64(data.count)
                    let windowElapsed = Date().timeIntervalSince(windowStart)
                    if windowElapsed >= 0.5 {
                        let bps = Double(windowBytes) / windowElapsed
                        peakBps = max(peakBps, bps)
                        windowBytes = 0
                        windowStart = Date()
                    }
                    let progress = min(1, Double(totalBytes) / 8_000_000.0)
                    let mb = Double(totalBytes) / 1_000_000.0
                    self.speedTestState = .running(progress: progress, downloadedMB: mb)
                    if Int(progress * 10) != Int((progress - 0.001) * 10) {
                        LogManager.shared.debugLog("netmon", "带宽测速进度", context: [
                            "downloadedMB": String(format: "%.1f", mb),
                            "peakMBps": String(format: "%.1f", peakBps / 1_000_000.0)
                        ])
                    }
                } catch {
                    errorOccurred = true
                    errorStreak += 1
                    let detail = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? error.localizedDescription
                    if firstErrorText == nil { firstErrorText = detail }
                    LogManager.shared.debugLog("netmon", "带宽测速轮次失败", context: [
                        "streak": "\(errorStreak)",
                        "attemptedURL": targetURLs[targetIndex].lastPathComponent,
                        "error": detail
                    ])
                    // 轮换候选目标 + 300ms 退避（防单资源 403/限流持续失败）
                    targetIndex = (targetIndex + 1) % targetURLs.count
                    req = makeSpeedRequest(targetURLs[targetIndex])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }

            // 快网兜底：首个 0.5s 窗口内即下完时，峰值窗口尚未触发——以总字节/总耗时兜底
            if peakBps <= 0 && totalBytes > 0 {
                let elapsed = max(Date().timeIntervalSince(elapsedStart), 0.001)
                peakBps = Double(totalBytes) / elapsed
            }
            let finalMbps = peakBps / 1_000_000.0
            // 判定放宽：只要真实下载到数据即出结果（样本过小/部分失败以 note 诚实标注）
            guard totalBytes > 0 else {
                let message = firstErrorText.map { "测速失败：\($0)" } ?? "测速失败，请稍后重试"
                self.speedTestState = .failed(message)
                LogManager.shared.warning("netmon", "带宽测速失败", context: [
                    "downloaded": "0", "error": "\(errorOccurred)", "firstError": firstErrorText ?? "none"
                ])
                return
            }
            let grade: String
            switch finalMbps {
            case 4...: grade = "优秀"
            case 1.5...: grade = "良好"
            case 0.5...: grade = "可用"
            default: grade = "较差"
            }
            let sampleNote: String? = (best.length > 0 && best.length < 500_000) || totalBytes < 800_000
                ? "资源样本较小，结果仅供参考"
                : note
            self.speedTestState = .done(mbps: finalMbps, grade: grade, note: sampleNote)
            LogManager.shared.info("netmon", "带宽测速完成", context: [
                "mbps": String(format: "%.2f", finalMbps),
                "grade": grade,
                "downloadedMB": String(format: "%.1f", Double(totalBytes) / 1_000_000.0),
                "elapsedS": "10",
                "note": sampleNote ?? "none"
            ])
        }
    }

    /// 相对图片 URL → 绝对 URL（仅学校域；http 统一升级 https —— 干净会话受 ATS 约束，明文必失败）
    nonisolated static func resolvableSchoolURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        else if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("/") { s = "https://www.sxjzit.edu.cn" + s }
        else if !s.hasPrefix("http") { s = "https://www.sxjzit.edu.cn/" + s }
        guard let url = URL(string: s), let host = url.host, host.contains("sxjzit.edu.cn") else { return nil }
        return url
    }

    // MARK: - 手动刷新

    /// 会话内开关切换入口（View 层 @AppStorage 联动）
    func setSamplingEnabledForSession(_ enabled: Bool) {
        guard heartbeatEnabled != enabled else { return }
        heartbeatEnabled = enabled
        if !enabled {
            teardownHeartbeatSession()
        } else {
            updateLiveSamplingState()
        }
    }

    /// 心跳连续失败数（只读公开，雷达节点/联动卡用）
    var heartbeatConsecutiveFailuresPublic: Int { heartbeatConsecutiveFailures }

    /// 网络身份快照公开入口（页面打开即刷新）
    func refreshNetworkIdentityPublic() {
        refreshNetworkIdentity()
    }

    /// 工具栏手动刷新：立即一次心跳 + 网络身份快照
    func refreshNow() {
        refreshNetworkIdentity()
        if liveSamplingActive && sceneIsActive && heartbeatEnabled && !probeIsRunning && !speedTestIsRunning {
            performHeartbeat()
        } else if heartbeatSession != nil || liveSamplingActive == false {
            // 未处于实时采样时也执行一次身份刷新与即时心跳（临时干净会话）
            performOneOffHeartbeat()
        }
        LogManager.shared.info("netmon", "手动刷新触发", context: [
            "samplingActive": "\(liveSamplingActive)",
            "tier": samplingTier.rawValue
        ])
    }

    private func performOneOffHeartbeat() {
        guard let url = URL(string: ProbeTarget.gateway.urlString) else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.protocolClasses = nil
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.probeUserAgent, forHTTPHeaderField: "User-Agent")
        let started = Date()
        Task { [weak self] in
            let ok: Bool
            var rtt = 0.0
            do {
                let (_, resp) = try await session.data(for: request)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                ok = (200...299).contains(code) || code == 403 || code == 404
                rtt = Date().timeIntervalSince(started) * 1000
            } catch {
                ok = false
                rtt = Date().timeIntervalSince(started) * 1000
            }
            session.invalidateAndCancel()
            await MainActor.run {
                guard let self else { return }
                if ok {
                    self.heartbeatSucceeded += 1
                    self.heartbeatLastRTTMs = rtt
                } else {
                    self.heartbeatFailed += 1
                    self.heartbeatLastRTTMs = rtt
                }
            }
        }
    }

    // MARK: - 持久化（时间线 / 诊断 / 今日流量）

    private func appendLinkEvent(_ event: LinkEvent) {
        linkTimeline.insert(event, at: 0)
        if linkTimeline.count > 30 {
            linkTimeline.removeLast(linkTimeline.count - 30)
        }
        flushTimeline()
    }

    private func flushTimeline() {
        guard !linkTimeline.isEmpty else { return }
        if let data = try? Self.timelineEncoder.encode(linkTimeline) {
            UserDefaults.standard.set(data, forKey: NetmonKey.timeline)
            LogManager.shared.debugLog("netmon", "时间线落盘", context: ["count": "\(linkTimeline.count)"])
        }
    }

    private func restoreTimeline() {
        guard let data = UserDefaults.standard.data(forKey: NetmonKey.timeline),
              let events = try? Self.timelineDecoder.decode([LinkEvent].self, from: data) else { return }
        linkTimeline = Array(events.prefix(30))
    }

    private func persistLastProbe(_ summary: ProbeSummary) {
        if let data = try? Self.timelineEncoder.encode(summary) {
            UserDefaults.standard.set(data, forKey: NetmonKey.lastProbe)
        }
    }

    private func restoreLastProbe() {
        guard let data = UserDefaults.standard.data(forKey: NetmonKey.lastProbe),
              let summary = try? Self.timelineDecoder.decode(ProbeSummary.self, from: data) else { return }
        lastPersistedProbe = summary
        healthScore = summary.healthScore
    }

    /// 日键格式化器（静态缓存，每秒 tick 路径不做无谓重建）
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private var currentDayKey: String {
        Self.dayKeyFormatter.string(from: Date())
    }

    /// 上次流量日历日（日切检测用）
    private var lastTrafficDayKey = ""

    /// 今日流量落盘 = 总额快照覆盖（非增量叠加，防重复累加）
    private func flushTodayTraffic() {
        let key = NetmonKey.traffic(day: currentDayKey)
        UserDefaults.standard.set([Double(todayDownBytes), Double(todayUpBytes)], forKey: key)
    }

    private func rolloverTodayTrafficIfNeeded(forceLoad: Bool) {
        let key = NetmonKey.traffic(day: currentDayKey)
        if forceLoad {
            if let saved = UserDefaults.standard.object(forKey: key) as? [Double], saved.count >= 2 {
                todayDownBytes = Int64(saved[0])
                todayUpBytes = Int64(saved[1])
            }
            lastTrafficDayKey = key
            return
        }
        // 日切：先以旧键落盘最后快照，再归零内存累计（旧键保留为历史，清理时按最近 3 天）
        if lastTrafficDayKey != key {
            let oldKey = lastTrafficDayKey.isEmpty ? key : lastTrafficDayKey
            UserDefaults.standard.set([Double(todayDownBytes), Double(todayUpBytes)], forKey: oldKey)
            todayDownBytes = 0
            todayUpBytes = 0
            lastTrafficDayKey = key
            LogManager.shared.info("netmon", "今日流量日切重置", context: ["newDay": key])
        }
        cleanupExpiredTrafficKeysIfNeeded()
    }

    /// 过期日历键清理（每天最多一次，避免逐秒全量遍历 UserDefaults）
    private var lastCleanupDayKey = ""

    private func cleanupExpiredTrafficKeysIfNeeded() {
        let today = currentDayKey
        guard lastCleanupDayKey != today else { return }
        let keysToRemove = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("netmonTraffic_") && $0 != NetmonKey.traffic(day: today) }
            .sorted()
        guard keysToRemove.count > 3 else {
            lastCleanupDayKey = today
            return
        }
        var removed = 0
        for key in keysToRemove.dropLast(3) {
            UserDefaults.standard.removeObject(forKey: key)
            removed += 1
        }
        if removed > 0 {
            LogManager.shared.info("netmon", "清理过期流量日键", context: ["removed": "\(removed)"])
        }
        lastCleanupDayKey = today
    }

    // MARK: - 诊断报告文本（复制/导出快照共用）

    var diagnosticReportText: String {
        var lines: [String] = []
        lines.append("【园枢 · 网络监测报告】")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("生成时间：\(f.string(from: Date()))")
        lines.append("链路状态：\(pathStatus)（\(interfaceName)）")
        lines.append("健康分：\(healthScore.map(String.init) ?? "待诊断")")
        lines.append("成功率：\(String(format: "%.1f%%", successRate * 100)) · 平均延迟：\(String(format: "%.0f", averageLatencyMs))ms")
        lines.append("会话流量：↓ \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) ↑ \(ByteCountFormatter.string(fromByteCount: totalUpBytes, countStyle: .file))")
        lines.append("今日流量：↓ \(ByteCountFormatter.string(fromByteCount: todayDownBytes, countStyle: .file)) ↑ \(ByteCountFormatter.string(fromByteCount: todayUpBytes, countStyle: .file))")
        if let summary = probeHistory.first ?? lastPersistedProbe {
            lines.append("最近诊断：健康分 \(summary.healthScore)（\(summary.gradeText)）")
            lines.append("网关 P50 \(String(format: "%.0f", summary.gateway.p50))ms · P90 \(String(format: "%.0f", summary.gateway.p90))ms · 丢包 \(String(format: "%.0f", summary.gateway.lossRate * 100))%")
            if let portal = summary.portal {
                lines.append("门户 P90 \(String(format: "%.0f", portal.p90))ms")
            }
            lines.append("DNS \(ProbeResult.stageText(summary.gateway.dnsMs)) · TCP \(ProbeResult.stageText(summary.gateway.tcpMs)) · TLS \(ProbeResult.stageText(summary.gateway.tlsMs)) · 首字节 \(ProbeResult.stageText(summary.gateway.ttfbMs))")
            lines.append("建议：\(summary.adviceTitles.joined(separator: "；"))")
        } else {
            lines.append("尚未执行诊断，建议先点按「开始诊断」。")
        }
        if let first = linkTimeline.first {
            lines.append("最近链路事件：\(first.status) \(Self.timeText(first.date))")
        }
        lines.append("—— 由「园枢」App 网络监测生成（统计口径：App 数据层 HTTP）")
        return lines.joined(separator: "\n")
    }

    nonisolated static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}