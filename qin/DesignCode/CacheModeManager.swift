//
//  CacheModeManager.swift
//  山西晋中理工学院 APP — 缓存模式管理器
//
//  单一状态源：ObservableObject 单例 + UserDefaults 持久化，全部设置实时全局生效。
//  提供即时刷新模式（默认）与缓存模式（省流量/秒开），全程日志埋点跟踪。
//

import SwiftUI
import Foundation

// MARK: - 缓存模式线程安全镜像

/// 供非主线程环境（如 RefererHeaderURLProtocol 回调队列）读取缓存模式开关。
/// CacheModeManager 本身是 @MainActor，协议回调等后台线程不能直接访问，
/// 由 mode 变化时同步写入本镜像，读取走 NSLock。
final class CacheModeMirror: @unchecked Sendable {
    static let shared = CacheModeMirror()
    private let lock = NSLock()
    private var _cacheEnabled = false
    private var _imageFreeEnabled = false

    var cacheEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _cacheEnabled
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _cacheEnabled = newValue
        }
    }

    /// 无图模式开关镜像（图片组件可从任意线程安全读取）
    var imageFreeEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _imageFreeEnabled
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _imageFreeEnabled = newValue
        }
    }

    private init() {}
}

// MARK: - 缓存模式枚举

enum CacheMode: String, CaseIterable, Identifiable {
    case instant    = "instant"
    case cached     = "cached"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: return "即时刷新"
        case .cached:  return "缓存模式"
        }
    }

    var icon: String {
        switch self {
        case .instant: return "bolt.fill"
        case .cached:  return "archivebox.fill"
        }
    }

    var description: String {
        switch self {
        case .instant:
            return "每次浏览实时加载最新内容，确保数据始终是最新的。适合网络畅通时使用。"
        case .cached:
            return "已浏览的内容将自动缓存到本地，再次访问时无需网络加载，秒开呈现。节省流量，提速明显。"
        }
    }

    var shortDescription: String {
        switch self {
        case .instant: return "实时加载 · 始终最新"
        case .cached:  return "智能缓存 · 省流量 · 秒开"
        }
    }

    var accentColor: Color {
        switch self {
        case .instant: return Color.sjzAccent
        case .cached:  return Color.sjzGreen
        }
    }

    var backgroundColor: Color {
        switch self {
        case .instant: return Color.sjzAccent.opacity(0.08)
        case .cached:  return Color.sjzGreen.opacity(0.08)
        }
    }
}

// MARK: - 缓存统计快照

struct CacheStatsSnapshot {
    let hitCount: Int
    let missCount: Int
    let totalRequests: Int
    let imageCacheHitCount: Int
    let imageCacheMissCount: Int
    let imageTotalRequests: Int
    let cachedArticleCount: Int
    let estimatedMemoryBytes: Int64

    var hitRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(hitCount) / Double(totalRequests)
    }

    var hitRatePercent: String {
        String(format: "%.1f%%", hitRate * 100)
    }

    var imageHitRate: Double {
        guard imageTotalRequests > 0 else { return 0 }
        return Double(imageCacheHitCount) / Double(imageTotalRequests)
    }

    var imageHitRatePercent: String {
        String(format: "%.1f%%", imageHitRate * 100)
    }

    var formattedMemory: String {
        if estimatedMemoryBytes < 1024 {
            return "\(estimatedMemoryBytes) B"
        } else if estimatedMemoryBytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(estimatedMemoryBytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(estimatedMemoryBytes) / (1024.0 * 1024.0))
        }
    }

    var efficiencyRating: String {
        if hitRate >= 0.8 { return "极佳" }
        if hitRate >= 0.6 { return "良好" }
        if hitRate >= 0.4 { return "一般" }
        if totalRequests == 0 { return "无数据" }
        return "偏低"
    }

    var efficiencyColor: Color {
        if hitRate >= 0.8 { return Color.sjzGreen }
        if hitRate >= 0.6 { return Color.sjzAccent }
        if hitRate >= 0.4 { return Color.sjzOrange }
        return .secondary
    }
}

// MARK: - 缓存模式管理器

@MainActor
final class CacheModeManager: ObservableObject {

    static let shared = CacheModeManager()

    // MARK: 存储键

    private static let modeKey           = "cacheMode"
    private static let hitCountKey       = "cacheHitCount"
    private static let missCountKey      = "cacheMissCount"
    private static let imgHitCountKey    = "cacheImageHitCount"
    private static let imgMissCountKey   = "cacheImageMissCount"
    private static let sessionStartKey   = "cacheSessionStart"
    private static let savedTrafficKey   = "cacheSavedTrafficBytes"
    private static let imgFreeModeKey    = "cacheImageFreeMode"
    private static let imgFreeSkipKey    = "cacheImageFreeSkippedCount"

    // MARK: 发布状态

    @Published var mode: CacheMode {
        didSet {
            persist(mode.rawValue, forKey: Self.modeKey)
            logModeChange(mode)
            DataService.shared.refreshCacheLimits()
            Self.syncMirror(mode)
            // 解码图内存缓存限额随模式切换（缓存模式更大容量）
            SJZDecodedImageCache.shared.refreshLimits(cacheEnabled: mode == .cached)
        }
    }

    /// 无图模式：开启后全局跳过静态图片加载（正文/列表/画廊统一渲染优雅占位），
    /// 视频播放与正文文字不受影响（省流利器，适合弱网场景）。
    @Published var imageFreeModeEnabled: Bool {
        didSet {
            persist(imageFreeModeEnabled, forKey: Self.imgFreeModeKey)
            CacheModeMirror.shared.imageFreeEnabled = imageFreeModeEnabled
            LogManager.shared.info("cache", imageFreeModeEnabled ? "无图模式已开启" : "无图模式已关闭", context: [
                "skippedTotal": "\(imageFreeSkippedCount)"
            ])
        }
    }

    /// 无图模式累计跳过图片数（跨会话持久化，设置页状态胶囊直观展示）
    @Published private(set) var imageFreeSkippedCount: Int = 0 {
        didSet { persist(imageFreeSkippedCount, forKey: Self.imgFreeSkipKey) }
    }

    @Published private(set) var hitCount: Int = 0 {
        didSet { persist(hitCount, forKey: Self.hitCountKey) }
    }
    @Published private(set) var missCount: Int = 0 {
        didSet { persist(missCount, forKey: Self.missCountKey) }
    }
    @Published private(set) var imageHitCount: Int = 0 {
        didSet { persist(imageHitCount, forKey: Self.imgHitCountKey) }
    }
    @Published private(set) var imageMissCount: Int = 0 {
        didSet { persist(imageMissCount, forKey: Self.imgMissCountKey) }
    }
    @Published private(set) var sessionStartTime: Date = Date()
    @Published private(set) var savedTrafficBytes: Int64 = 0

    // MARK: 初始化

    private init() {
        let d = UserDefaults.standard
        mode = CacheMode(rawValue: d.string(forKey: Self.modeKey) ?? "") ?? .instant
        imageFreeModeEnabled = d.object(forKey: Self.imgFreeModeKey) != nil ? d.bool(forKey: Self.imgFreeModeKey) : false
        imageFreeSkippedCount = d.integer(forKey: Self.imgFreeSkipKey)
        hitCount = d.integer(forKey: Self.hitCountKey)
        missCount = d.integer(forKey: Self.missCountKey)
        imageHitCount = d.integer(forKey: Self.imgHitCountKey)
        imageMissCount = d.integer(forKey: Self.imgMissCountKey)
        savedTrafficBytes = Int64(d.integer(forKey: Self.savedTrafficKey))
        // 镜像同步须在所有存储属性初始化完成后执行
        Self.syncMirror(mode)
        CacheModeMirror.shared.imageFreeEnabled = imageFreeModeEnabled

        if let saved = d.object(forKey: Self.sessionStartKey) as? Date {
            sessionStartTime = saved
        } else {
            sessionStartTime = Date()
            d.set(sessionStartTime, forKey: Self.sessionStartKey)
        }

        LogManager.shared.info("cache", "缓存模式管理器初始化完成", context: [
            "mode": mode.rawValue,
            "hitCount": "\(hitCount)",
            "missCount": "\(missCount)",
            "imageHitCount": "\(imageHitCount)",
            "imageMissCount": "\(imageMissCount)",
            "imageFreeMode": "\(imageFreeModeEnabled)",
            "imageFreeSkipped": "\(imageFreeSkippedCount)",
            "savedTraffic": ByteCountFormatter.string(fromByteCount: savedTrafficBytes, countStyle: .file)
        ])
    }

    // MARK: 便捷属性

    var isCacheEnabled: Bool {
        mode == .cached
    }

    /// 供非主线程环境（URLProtocol 回调等）读取缓存模式开关的线程安全入口
    nonisolated static var isCacheEnabledFromAnyThread: Bool {
        CacheModeMirror.shared.cacheEnabled
    }

    /// 无图模式线程安全入口（SJZCachedImage 等组件从任意线程读取）
    nonisolated static var isImageFreeModeFromAnyThread: Bool {
        CacheModeMirror.shared.imageFreeEnabled
    }

    /// 无图模式跳过一张图片（计数持久化 + 节流日志在主线程侧由调用方负责）
    func recordImageSkipped() {
        imageFreeSkippedCount += 1
    }

    /// 将当前模式同步到线程安全镜像（@MainActor 内调用）
    private static func syncMirror(_ mode: CacheMode) {
        CacheModeMirror.shared.cacheEnabled = (mode == .cached)
    }

    var totalRequests: Int {
        hitCount + missCount
    }

    var imageTotalRequests: Int {
        imageHitCount + imageMissCount
    }

    var hitRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(hitCount) / Double(totalRequests)
    }

    var hitRatePercent: String {
        String(format: "%.1f%%", hitRate * 100)
    }

    var snapshot: CacheStatsSnapshot {
        CacheStatsSnapshot(
            hitCount: hitCount,
            missCount: missCount,
            totalRequests: totalRequests,
            imageCacheHitCount: imageHitCount,
            imageCacheMissCount: imageMissCount,
            imageTotalRequests: imageTotalRequests,
            cachedArticleCount: DataService.shared.cachedArticleCount,
            estimatedMemoryBytes: DataService.shared.estimatedCacheMemoryBytes
        )
    }

    var sessionDuration: String {
        let interval = Date().timeIntervalSince(sessionStartTime)
        if interval < 60 { return "\(Int(interval)) 秒" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟" }
        return String(format: "%.1f 小时", interval / 3600)
    }

    var savedTrafficFormatted: String {
        ByteCountFormatter.string(fromByteCount: savedTrafficBytes, countStyle: .file)
    }

    // MARK: 记录方法

    func recordHit(articleId: String, cacheAge: TimeInterval? = nil) {
        hitCount += 1
        var ctx: [String: String] = ["articleId": articleId]
        if let age = cacheAge {
            ctx["cacheAge"] = String(format: "%.0fs", age)
        }
        LogManager.shared.debugLog("cache", "缓存命中", context: ctx)
    }

    func recordMiss(articleId: String) {
        missCount += 1
        LogManager.shared.debugLog("cache", "缓存未命中", context: ["articleId": articleId])
    }

    func recordImageHit(url: String) {
        imageHitCount += 1
        guard Self.imageStatShouldLog(url) else { return }
        LogManager.shared.debugLog("cache", "图片缓存命中", context: [
            "url": url.components(separatedBy: "/").last ?? url,
            "hitCount": "\(imageHitCount)"
        ])
    }

    func recordImageMiss(url: String) {
        imageMissCount += 1
        guard Self.imageStatShouldLog(url) else { return }
        LogManager.shared.debugLog("cache", "图片缓存未命中", context: [
            "url": url.components(separatedBy: "/").last ?? url
        ])
    }

    /// 图片统计日志节流：同一 URL 仅首次记录（计数始终累加，滚动不刷日志）
    private static let imageStatLogLock = NSLock()
    private static var imageStatLoggedURLs: Set<String> = []
    private static func imageStatShouldLog(_ url: String) -> Bool {
        imageStatLogLock.lock(); defer { imageStatLogLock.unlock() }
        guard !imageStatLoggedURLs.contains(url) else { return false }
        imageStatLoggedURLs.insert(url)
        if imageStatLoggedURLs.count > 600 { imageStatLoggedURLs.removeFirst() }
        return true
    }

    func recordSavedTraffic(bytes: Int64) {
        savedTrafficBytes += bytes
        UserDefaults.standard.set(Int(savedTrafficBytes), forKey: Self.savedTrafficKey)
    }

    // MARK: 重置

    func resetStats() {
        hitCount = 0
        missCount = 0
        imageHitCount = 0
        imageMissCount = 0
        savedTrafficBytes = 0
        sessionStartTime = Date()
        UserDefaults.standard.set(sessionStartTime, forKey: Self.sessionStartKey)
        UserDefaults.standard.set(0, forKey: Self.savedTrafficKey)
        LogManager.shared.info("cache", "缓存统计数据已重置", context: [
            "newSessionStart": ISO8601DateFormatter().string(from: sessionStartTime)
        ])
    }

    func resetAll() {
        resetStats()
        mode = .instant
        LogManager.shared.info("cache", "缓存模式已恢复默认（即时刷新）", context: ["reset": "all"])
    }

    // MARK: 图片缓存占用与清理（E2 缓存中心）

    /// 图片缓存当前磁盘占用（字节）
    var imageCacheDiskUsage: Int {
        URLCache.shared.currentDiskUsage
    }

    /// 图片缓存磁盘容量（字节）
    var imageCacheDiskCapacity: Int {
        URLCache.shared.diskCapacity
    }

    /// 清理全部图片缓存（URLCache + 解码图内存缓存 + 文章详情缓存），并重置相关计数
    func clearImageCache() {
        let before = URLCache.shared.currentDiskUsage
        URLCache.shared.removeAllCachedResponses()
        SJZDecodedImageCache.shared.removeAll()
        DataService.shared.clearArticleDetailCache()
        imageHitCount = 0
        imageMissCount = 0
        let freed = ByteCountFormatter.string(fromByteCount: Int64(before), countStyle: .file)
        LogManager.shared.info("cache", "图片缓存已清理", context: [
            "freed": freed,
            "diskUsage": ByteCountFormatter.string(fromByteCount: Int64(URLCache.shared.currentDiskUsage), countStyle: .file)
        ])
    }

    // MARK: 内存警告降载（E9）

    /// 注册内存警告监听：警告时清理图片内存缓存，保护进程稳定
    func registerMemoryWarningHandler() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            // 闭包位于非隔离上下文，投递主线程后调用 MainActor 单例（E9）
            Task { @MainActor in
                URLCache.shared.removeAllCachedResponses()
                SJZDecodedImageCache.shared.removeAll()
                DataService.shared.clearArticleDetailCache()
                LogManager.shared.warning("cache", "收到内存警告，已降载图片缓存", context: [
                    "diskUsage": ByteCountFormatter.string(fromByteCount: Int64(URLCache.shared.currentDiskUsage), countStyle: .file)
                ])
            }
        }
        LogManager.shared.debugLog("cache", "内存警告监听已注册")
    }

    // MARK: 持久化与日志

    private func persist(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func logModeChange(_ newMode: CacheMode) {
        LogManager.shared.info("cache", "缓存模式切换", context: [
            "mode": newMode.rawValue,
            "title": newMode.title,
            "isCacheEnabled": "\(newMode == .cached)"
        ])
    }
}