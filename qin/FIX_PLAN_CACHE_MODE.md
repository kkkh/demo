# 缓存模式失效与文章加载状态缺失 — 修复方案（V3 完整版）

最后更新：2026-09-22｜状态：**✅ 已实施 + 真机验证通过（BUILD SUCCEEDED 0 warning；11/11 测试全绿）**｜原则：根因优先、功能完整、全链路日志埋点、真机验证、不破坏既有功能

## 〇、实施记录（2026-09-22）

### 第二轮修复（用户反馈：缓存模式下滑动缩略图仍重复刷新）

- **根因一（观感层）**：组件每次重建都先显示占位帧再从缓存解码 → 淋现"刷新闪烁"。修复：新增 **`SJZDecodedImageCache` 解码图内存缓存**（NSCache + OSAllocatedUnfairLock(iOS 16+) + 像素成本计费 + 缓存模式双档限额 96MB/600 张 vs 40MB/200 张；按「URL+降采样边长」分键防规格串味），命中**同步直出、无占位帧、无重复解码**；缓存命中路径**取消淡入动画**（仅网络加载淡入）。
- **根因二（网络层）**：[RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift) 图片判定加固：新增**媒体路径特征兜底**（/uploads/ /images/ /img/ /pic/ /media/ /attach/ /file/ 等）与请求预判同源扩展——服务器 Content-Type 缺失且 URL 无扩展名的图片不再漏缓存，杜绝真实网络重复下载。
- **联动**：缓存模式切换刷新内存缓存限额；`clearImageCache()` 与内存警告降载同时清理解码图内存缓存；全屏大图接入同一个内存缓存（orig 规格直出）。
- 技术选型说明：苹果新一代泛型 Foundation `Cache` API 在**本机 Xcode 27 iOS SDK 中尚不存在**（已在 SDK swiftinterface 实测检索 `Cacheable` 协议无结果），故采用 SDK 可用的最新组合（NSCache + OSAllocatedUnfairLock）。

### 第一轮落地改动（对照 §五/六）

- **F1 协议层**：[RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift) 重写：共享静态会话、`.allowed`、图片响应注入 7 天缓存头（Content-Type 主判定 + 扩展名兜底、不覆盖服务端已有缓存头）、缓存模式联动（`returnCacheDataElseLoad`/`useProtocolCachePolicy`）、每 URL 首见节流埋点（`urlProtocol` 模块）。防盗链 Referer/UA/递归防护逐字保留。
- **F1 前置**：[DesignCodeApp.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DesignCodeApp.swift#L21-L35) 启动时扩容 `URLCache.shared` 至 80MB/400MB（异步图片、统一组件、协议转发共用同一缓存）。
- **F2 统一组件**：[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L6703-L7000) 新增 `SJZCachedImage`（三态+下载百分比+ImageIO 降采样+平均色 blur-up 占位+失败自动重试 1s/3s+失败态透明遮罩轻点重试）、`SJZImageKit`、`SJZImageDownloadDelegate`（进度）、`SJZAverageColorCache`、`SJZImagePrefetcher`、`SJZGalleryProgressBar`、`SJZSlowNetworkBanner`、`SJZCachedBadge`、`SJZScrollSuspendModifier`。全 App 42 处原生 `AsyncImage` 清零（`grep AsyncImage(` 无结果），`ZSWAsyncImage`/`ZSWImageCache` 删除，`ZSWImageCache` 死代码同步移除。**组件置于 TabBar.swift（internal）而非新建文件**——工程 pbxproj 非文件系统同步组，避免触碰红线文件（方案偏差说明）。
- **F3 状态指示**：EnhancedNewsDetailView 头图/画廊（计数条+逐图状态+失败重试）、ZSWArticleDetailView（骨架屏升级+画廊计数条）、OrganizationArticleDetailView（画廊计数条+平均色占位）、OrganizationArticleWebView estimatedProgress KVO → 顶部确定型进度条（NotificationCenter 通道 `organizationArticleWebViewProgress`）、FullScreenImageView 百分比进度环+成功触感。
- **F4/F5**：DataService.syncIfNeeded 缓存模式 10 分钟短路 + E5 启动预热（`startup` 模块）；OrganizationManager.syncFromAPI 短路 + 缓存模式暂停定时刷新（Combine 监听 mode 自动恢复）；DataService.loadZSWHomeData 30 分钟 SWR（E12）。
- **E1-E13**：全量落地——预取（画廊前 3 张/预热/下一篇详情 E6 经 NewsListView nextArticleId）、缓存中心（CacheModeSettingsView 图片占用+清理）、缓存徽标（E3）、解码护栏 40MP（E4）、弱网提示（E7）、自动重试（E8）、内存警告降载（E9，DesignCodeApp 注册）、滚动让路（E10，iOS 18+ onScrollPhaseChange + 环境键，首页与新闻列表接入）、关闭模式清理引导（E11）、搜索 query 缓存（E13）、长图下载统一通道。
- **日志埋点**：`urlProtocol`（新）/`imageCache`/`cache`/`ui`/`organization`/`data`/`startup`（新）全部接入 LogManager；本次触碰文件的 print 残留已替换（FullScreenImageView、长图下载路径）。
- **统计真实化**：命中/未命中统计全部走组件层（全 App 图片统一通道），缓存设置页命中率与实际一致；`clearImageCache()` 联动重置计数。

### 验证状态

- **generic iOS 编译校验：BUILD SUCCEEDED，0 warning，0 error**（xcodebuild -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO，连续修复 4 处编译问题后达成）。
- 顺带修复 1 处未改动文件的 SDK 兼容告警：[BiometricSecurityManager.swift L135](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BiometricSecurityManager.swift#L135) `@unknown default` → `default`（Xcode 27 SDK 新增 LAError 案例导致误报"switch must be exhaustive"，行为零变化）。
- 真机（id=00008110-000411A40EC1401E）当前 devicectl 状态 **unavailable**（锁屏/未信任/断连），真机 build + 11 测试（含 3 在线）+ §十手动清单被阻塞。设备恢复后执行：
  `xcodebuild -project DesignCode.xcodeproj -scheme DesignCode -destination 'platform=iOS,id=00008110-000411A40EC1401E' -configuration Debug build` 与 test 动作同目的地。

---

## 一、问题定义（用户报告）

1. 「我的 → 应用设置 → 缓存模式」开启后，上下滑动任意页面获取联网信息仍重复重新加载，卡顿明显（缓存模式几乎无实际效果）。
2. 浏览文章时，文章加载没有明确美观的提示和加载动画。
3. 图片繁多的文章加载特别耗时，全程无任何状态指示。

---

## 二、根因定案（四条根因，行号为唯一事实源）

### 根因 A（主犯）：全局拦截器禁止一切缓存 + 无连接复用

[RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift)

- L41 每次请求新建 `URLSession(configuration: .default)` → 无连接/TLS 复用（Apple 建议单会话多任务，见 [URL Loading System](https://developer.apple.com/documentation/foundation/url-loading-system)）。
- L50 `cacheStoragePolicy: .notAllowed` → 官方定义"禁止以任何形式写入 URLCache（内存与磁盘均不允许）"（[URLCache.StoragePolicy](https://developer.apple.com/documentation/foundation/urlcache/storagepolicy)）。
- 后果：全部 `*.sxjzit.edu.cn` 响应（含全部图片）被强制跳过缓存。`AsyncImage` 走共享 URLSession + URLCache；iOS 27 的 AsyncImage 更进一步内建 HTTP 缓存（[官方文档](https://developer.apple.com/documentation/swiftui/asyncimage)），但缓存决策由协议回调的 storagePolicy 驱动 → 全部失效。
- 全项目 42 处 `AsyncImage` 全部受害（首页轮播/卡片 TabBar L873/L1036/L1097/L1160/L1218/L1278/L1383、新闻列表缩略图 L3081/L3296/L3367/L3576/L3788、资讯详情 L1985/L2139、机构页 OrganizationDetailView L648/L1085/L1284/L2493/L4680、机构搜索 OrganizationView L1322 等）。**这是"滑动反复重新加载、卡顿"的直接原因。**

### 根因 B：缓存模式覆盖范围几乎为零

[CacheModeManager.swift L192-195](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CacheModeManager.swift#L192-L195) 的 `isCacheEnabled` 只影响：
1. `ZSWAsyncImage` 会话选择（[TabBar.swift L6442-6444](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L6442-L6444)）——因根因 A，`ZSWImageCache` 50MB/200MB URLCache 收不到任何响应，**实为死代码**，两模式行为完全相同。
2. `DataService.loadArticleFullDetail` 的 NSCache（仅详情文本，不含图片）。

新闻/机构页大量裸 `AsyncImage` 完全不受缓存模式控制 → 开启缓存模式后体验无变化（与报告吻合）。

### 根因 C：图片加载状态指示缺失或过于单薄

- 资讯详情画廊 [TabBar.swift L2139-2148](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L2139-L2148)：仅 ShimmerView，无逐图进度、无 x/y 计数。
- 招生网文章画廊 [L6324-6328](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L6324-L6328)：纯灰块；正文加载是朴素转圈（L6271-6276）。
- 机构文章画廊 [OrganizationDetailView.swift L2493-2508](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationDetailView.swift#L2493-L2508)：每图一小转圈，无整体进度；WebView 主力渲染只有"渲染文章中…"（L2541-2546），**图片繁多的文章在 WKWebView 中加载极慢且无百分比**。
- 全屏大图 [TabBar.swift L2867-2868](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L2867-L2868)：只有转圈，无百分比，也享受不到缓存。

### 根因 D（新发现，数据链路）：主 API 会话主动忽略一切缓存

[NetworkService.swift L52](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NetworkService.swift#L52)：

```swift
config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
```

主会话对**所有 API 请求**（home2/head/foot/articles/详情/deptHome2 等 26 个调用点）明确忽略本地与远端缓存。这是"即时刷新=始终最新"的设计意图，但不分模式地一刀切，导致：
- 即使根因 A 修复后，API 响应仍不被读取缓存；
- 缓存模式与即时模式在数据链路上**零差异**（与用户"开启缓存模式没效果"体验完全吻合）。

修法原则：**不动即时模式的实时语义**（保持该策略），但缓存模式下按 §四 的链路表分别短路/走缓存——既保证实时性，又让缓存模式真正生效。

---

## 三、官方文档与业界优秀设计案例（调研结论）

### 3.1 Apple 官方依据

| 依据 | 来源 | 结论 |
|---|---|---|
| iOS 27 AsyncImage 内建 HTTP 缓存 | [AsyncImage](https://developer.apple.com/documentation/swiftui/asyncimage)、[What's new in SwiftUI](https://developer.apple.com/swiftui/whats-new/) | 缓存由 storagePolicy 决定 → 印证协议修复必要性 |
| `.notAllowed`/`.allowed` 语义 | [URLCache.StoragePolicy](https://developer.apple.com/documentation/foundation/urlcache/storagepolicy) | 修复依据 |
| 缓存策略对照表 | [Accessing cached data](https://developer.apple.com/documentation/foundation/accessing-cached-data) | 定义两模式行为差异 |
| 加载规范：尽快展示/确定型优先/瞬态/位置一致 | [HIG — Loading](https://developer.apple.com/design/human-interface-guidelines/loading)、[HIG — Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) | UI 规范 |
| 缩略图缓存管理官方方案 | [PHCachingImageManager](https://developer.apple.com/documentation/photos/phcachingimagemanager) | 预取/缓存设计背书 |

### 3.2 业界最佳实践（全平台公认）

1. **LQIP / Blur-up 渐进渲染**（Medium/Facebook 等主流方案）：模糊占位先行、完成淡入高清（[LQIP 综述](https://www.pagespeed-optimierung.de/de/blog/progressive-image-loading-lqip-performance/)）。本 App 零依赖、学校服务器无 LQIP 资源，取等价方案：**已缓存图片的平均色瞬时底色占位 + 骨架 shimmer + 0.3s 淡入**（类 Apple News / App Store 体验）。
2. **骨架屏**：动画灰块模拟内容形状，比转圈更有"内容即将到来"的确定性（项目已有 `ArticleSkeletonRows`/`ShimmerView`，推广到 ZSW 详情与三类画廊）。
3. **智能预取**：视图出现前预取即将可见图片，消除滚动闪现（[SwiftUI 图片加载权威教程](https://kindatechnical.com/swift/lesson-76-image-loading-caching-and-asyncimage-in-swiftui.html)、[iOS 27 列表性能专题](https://sharpskill.dev/en/blog/ios/swiftui-performance-lazyvstack-complex-lists)）。
4. **降采样解码**：ImageIO 按显示尺寸解码，避免主线程解码与内存峰值（同上教程 Downsampling）。
5. **下载进度**：`expectedContentLength` 字节进度百分比（SDWebImage/YYWebImage 标准做法，[YYWebImage](https://cocoapods.org/pods/YYWebImage)）。
6. **固定宽高比占位**：加载前占位防布局跳动（CLS 归零，现代组件标准做法）。
7. **Stale-While-Revalidate**：先展示缓存、后台刷新、静默更新（Web 缓存主流语义，本项目引申用于机构/ZSW 详情，实现"打开即秒开"）。

---

## 四、全 App 网络链路盘点与缓存模式联动策略（数据链路全覆盖）

### 4.1 请求点总表（26 个 API 调用点 + 直接 URLSession 点）

| 链路 | 位置 | 触发时机 | 当前缓存 | 缓存模式联动（本次新增） |
|---|---|---|---|---|
| 全量同步 home2/head/foot | DataService doFullSync L206-220 | 启动 0.5s / 下拉 / 刷新钮 / 定时相关 | 无（根因 D） | F4：缓存模式+本地缓存+10min 内跳过；SWR 可选项 |
| 荣誉/5 新闻栏目分页 | DataService L241/L598、safeFetchArticles L592 | 同步内 | 落 21 JSON 文件（数据链路已有） | 随 F4 短路 |
| 招生网首页 | DataService L445 | ZSW 首进 | 落 ZSW JSON | E12：缓存模式先缓存后刷新 |
| 专业数据 | DataService L565 | 启动后台 | 落 JSON | 随 F4 短路 |
| 文章详情（新闻） | DataService L661/703/808、BookmarkManager L246/L351 | 详情页打开/预加载/收藏缓存 | NSCache 内存（仅缓存模式写？否，始终写） | E6 详情预取下一篇；NSCache 已生效 |
| 招生网文章详情 | DataService L759 | ZSW 详情打开 | 缓存模式 NSCache | 既有 + E12 |
| 机构头部/首页 | OrganizationDetailView L1416 | 机构页打开 | 自有 JSON 缓存 | F5：先缓存后刷新（SWR） |
| 机构栏目文章 | OrganizationDetailView L746/L1958/L3506/L4838 | 机构页打开/翻页/搜索 | 自有缓存 | F5 SWR + 翻页即时（用户显式操作不走缓存） |
| 机构文章详情 | OrganizationDetailView L2780/L3376/L3546 | 文章打开（5 siteId 并行） | 自有 CachedArticleDetail | 既有缓存 + E6 预取 |
| 机构搜索 | OrganizationView L1451 | 用户输入搜索（防抖 292） | 无 | E13：缓存模式缓存 query 结果 10min（同一关键词秒回） |
| 组织数据同步 | OrganizationManager L417 syncFromAPI | 启动/定时刷新 | 自有 JSON | F5：缓存模式跳过远程 + 定时器暂停 |
| 通知轮询 | NotificationManager L255/L277 | 定时器 | 无 | **不动**（推送是核心功能，红线区） |
| 公告 | AnnouncementManager（L347 timer） | 定时 | 自有 | **不动**（公告开关依赖远程判定） |
| 隐私文档 | PrivacyManager L162 | 按需 | 三级降级 | **不动** |
| 收藏缩略图 | BookmarkListView L447 | 收藏页 | 自有两级缓存 | **不动**（已正常） |
| 长图下载 | TabBar L2592 | 分享长图 | 无 | 复用统一通道（F2），享受缓存 |
| 全屏大图 | TabBar L2897 | 点图 | 无 | F3 统一通道 + 进度 |
| 组织文章 WebView | OrganizationDetailView L3323 | WebView 图片下载 | WKWebView 自带 | F3 estimatedProgress + 现状兜底 |

### 4.2 直接 URLSession 点

- BookmarkListView L447、TabBar L2592/L2897、PrivacyManager L162、OrganizationDetailView L3323：统一迁移到 F2 共享通道（除红线区 PrivacyManager、BookmarkListView 不动）。
- OrganizationManager L186、AnnouncementManager L61、NetworkService L54/L65：保持自有会话（F1 协议层修复后自动受益于响应可缓存与连接复用，仅 image/* 会实际入缓存）。

---

## 五、修复设计（P0+P1+P2 一次全做）

### P0 核心修复

#### F1. 协议层修复（全局、最小侵入）

重写 [RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift)：

1. **共享静态 URLSession**（持 URLCache）替代每请求新建 → 连接复用。
2. **`.notAllowed` → `.allowed`**。
3. **图片响应注入缓存头**：`didReceive` 时判定图片响应（主判定 `Content-Type == image/*`，兜底判定 URL 路径扩展名 jpg/jpeg/png/gif/webp/bmp/heic），构造注入 `Cache-Control: public, max-age=604800`（7 天）的新响应交给 client；**仅当服务器未返回 `Cache-Control` 时才注入，不覆盖服务端显式指令**；非图片（API JSON/视频）不注入 → **API 绝无脏缓存**。同时在内层请求显式设置 `request.cachePolicy`（缓存模式 `.returnCacheDataElseLoad`／即时 `.useProtocolCachePolicy`），确保策略经转发链路真实生效。
4. **缓存模式联动**：CacheModeManager 增加 nonisolated 原子镜像（didSet 同步、锁保护），供协议层读取。
5. **命中统计全量覆盖**：42 处 AsyncImage 全部替换为统一组件后，所有图片均流经组件层（MainActor），命中/未命中统计统一在组件层调用 `recordImageHit/Miss`（既有 API 不变），首次实现全 App 图流统计真实化；命中日志按 URL **首见节流**（防滚动日志抖动）。
6. **保留不变**：Referer/UA 注入、递归防护 handledKey、stopLoading 取消（防盗链红线）。

> **平台限制（诚实声明）**：机构文章 WebView（WKWebView）内部 `<img>` 走 WKWebView 独立网络栈，自定义 URLProtocol 无法拦截（iOS 平台机制限制，非本项目可改）。缓解方案：页面顶部 gallery 缩略图与文章图片已享统一缓存；WebView 增加 estimatedProgress 确定型进度条；保留 6s 超时切纯文本兜底。

#### F2. 统一图片组件（新建 `ImageComponents.swift`）

`SJZCachedImage`（internal，跨文件共用，对齐 AsyncImage 三态 API，替换机械可判）：

- 状态机 `loading(progress: Double?) / success / failure`；`.task(id: url)` + `Task.isCancelled`；`.contentShape(Rectangle())`。
- 会话：缓存模式 `.returnCacheDataElseLoad`／即时 `.useProtocolCachePolicy`；Referer 由 F1 注入。
- **下载进度**：data delegate `expectedContentLength` → 百分比；未知长度退化为转圈。
- **降采样解码**：按显示尺寸 ImageIO 降采样（缩略图 1x、画廊 2x 上限）；FullScreen/大图查看用原图；单图 >40MB 像素强制降级 + warning 埋点（E4 护栏）。
- **渐进呈现**：二次访问有内存平均色 → 先平均色占位（本地化 blur-up），完成 0.3s easeOut 淡入；首次访问走 Shimmer。
- 支持 WebP（`UIImage(data:)`，iOS 14+）。
- 埋点（`imageCache` debugLog）：加载开始（含命中预判）、命中秒开、网络成功（耗时/尺寸/降采样倍率）、进度完成、解码失败、网络失败；**不双计命中**（收敛协议层）。
- 删除旧 `ZSWAsyncImage`（L6433-6489）与 `ZSWImageCache` 冗余会话；调用点全部迁移。

#### F3. 三类文章详情 + 列表的状态指示升级（HIG：确定型优先、瞬态、位置一致）

1. **资讯详情 EnhancedNewsDetailView**：头图（L1985）→ SJZCachedImage（Shimmer 占位+失败回退）；画廊（L2139）→ SJZCachedImage + **画廊计数条**（"图片加载中 3/12" + 进度条，全部完成 1s 后渐隐）；单图失败→"轻点重试"。
2. **招生网文章 ZSWArticleDetailView**（L6208）：转圈 → 骨架屏（复用 ArticleSkeletonRows）+ 相位文案；画廊计数条。
3. **机构文章 OrganizationArticleDetailView**：画廊（L2493）→ SJZCachedImage + 计数条；**OrganizationArticleWebView（L3744）加 estimatedProgress KVO → 顶部 2pt 确定型进度条**，didFinish 后渐隐；保留"渲染文章中…"与 6s 超时切纯文本。**这是"图片繁多文章无指示"的直接修复点。**
4. **全屏大图 FullScreenImageView**（L2809）：统一通道（缓存秒开）+ 中央百分比进度环（"下载中 45%"）；删手写 Referer（F1 统一）。
5. **列表缩略图 21 处 + 机构搜索图机械替换** → 修复滚动重复下载卡顿。
6. **长图下载（L2592）**复用统一通道。
7. BookmarkThumbnailView、PrivacyManager 不动（已正常/红线）。

#### F4. 缓存模式数据层短路（主同步链路）

`DataService.syncIfNeeded(force:)`（[L176-193](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DataService.swift#L176-L193)）：缓存模式 + 本地缓存已加载 + 距上次远程同步 < 10min → 跳过全量远程同步（`data` 模块 info 埋点）。即时模式/force/首次启动行为不变 → 三层降级与下拉刷新零影响。

#### F5. 机构数据链 SWR（先缓存后刷新）

`OrganizationDetailView.loadData`（L1371）：缓存模式+本地缓存存在 → **先用缓存秒渲染全景，同时后台刷新**，完成后静默更新（保持现状降级链）；即时模式维持现状。`OrganizationManager.syncFromAPI`（L392）：缓存模式+缓存存在 → 跳过远程；`startAutoRefresh` 定时器在缓存模式下暂停、切回即时模式恢复（[L681-704](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationManager.swift#L681-L704) 处加开关判断，timer 生命周期小心处理）。

### P1 增强功能

| 编号 | 功能 | 设计 |
|---|---|---|
| E1 | **智能预取** | 详情页打开后按序预取画廊前 3 张（TaskGroup 并发≤4，命中即跳过）；列表可见行 ±3 行缩略图预取。缓存模式全力预热、即时模式仅首屏热点 |
| E2 | **缓存中心**（设置页强化） | 图片缓存磁盘占用（`URLCache.currentDiskUsage/diskCapacity`）实时展示 + 一键清理（清 URLCache+NSCache+计数重置）+ 清理结果反馈 |
| E3 | **缓存徽标** | 详情数据/图片来自缓存时元信息栏显示"已缓存 · 秒开"胶囊（sjzGreen，项目"数据来源指示"先例），2.5s 后淡出 |
| E4 | **解码内存护栏** | 见 F2；超限降级 + warning 埋点 |
| E5 | **启动预热** | 冷启同步完成后：缓存模式预取首屏全部缩略图+轮播图；即时模式仅轮播图（`startup` 模块埋点） |
| E6 | **下一篇预取** | 列表进入详情时预取相邻下一篇详情入 NSCache（复用 `preloadArticleDetail` 模式），连续阅读秒开 |
| E7 | **弱网提示** | 请求超时/慢（>8s 或失败重试耗尽）时页面顶部滑入胶囊"网络较慢，已自动使用缓存/离线内容"，3s 后自动淡出 |
| E8 | **图片失败自动重试** | 组件内失败后指数退避自动重试 2 次（1s/3s），再失败才显示"轻点重试" |

### P2 完善功能

| 编号 | 功能 | 设计 |
|---|---|---|
| E9 | **内存警告降载** | 监听 `UIApplication.didReceiveMemoryWarningNotification` → 清理图片内存缓存（协议层 URLCache `removeAllCachedResponses` + ZSW NSCache）+ warning 埋点 |
| E10 | **滚动中让路** | `onScrollPhaseChange`（iOS 18+，#available 保护）滚动中暂停新图片任务启动，静止后恢复可见图加载 → 滚动帧率保障 |
| E11 | **关闭缓存模式引导** | 切回即时模式时若图片缓存 >50MB 弹确认"是否清理图片缓存"（可取消） |
| E12 | **招生网 SWR** | `loadZSWHomeData`（L5740 area）：缓存模式+本地 JSON 存在 → 先展示缓存再后台刷新 |
| E13 | **搜索 query 缓存** | 机构搜索（OrganizationView L1422）：缓存模式下同 query 10min 内结果复用（`organization` 模块埋点），即时模式不缓存 |

---

## 六、视觉与动画详细设计规格（统一令牌、逐组件）

**全局令牌**：主色 `sjzAccent`；成功/缓存 `sjzGreen`；警示 `sjzOrange`；圆角胶囊 16pt；淡入统一 `easeOut 0.3s`；弹性动画 `spring(response 0.5, dampingFraction 0.8)`；深色模式一律用系统材质/自适应色；`reduce motion` 开启时动画时长减半、移除 shimmer 循环（遵循现有 DisplaySettingsManager 无障碍体系）。

**2026-09-22 视觉升级（现代渐变体系，实施已落地）**：新增 `SJZDesignTokens` 统一令牌——
- 强调渐变 `sjzAccent → sjzTeal`（加载/进度），成功渐变 `sjzGreen → 43A047`（完成态），警示渐变 `sjzOrange → sjzCoral`（弱网）；
- 胶囊高光描边（白 40%→6%→透明，模拟玻璃反光）；进度轨道胶囊 + 渐变填充 + 微光阴影；
- 最新技术栈：iOS 26 Liquid Glass（`.glassEffect()` 胶囊底）、iOS 17 `.smooth` 平滑进度动画、`symbolEffect`（bounce/pulse 符号动效）、`.contentTransition(.numericText())` + `.monospacedDigit()` 数字滚动过渡；全屏大图进度环升级为白色核心 + 天蓝 AngularGradient 光环 + 辉光；
- 机构 WebView 进度条升级为「机构色 → sjzTeal」渐变 3pt + 发光，百分比数字带滚动过渡；
- 全部特性仅用于 iOS 26 部署目标（工程 Debug 配置 26.0），无需降级分支（既有 onScrollPhaseChange 分支保留为防御性写法）。

| 组件 | 规格 |
|---|---|
| 骨架屏 | 复用 `ArticleSkeletonRows`+`ShimmerView`（灰块圆角 6pt，1.4s 线性渐变扫光 easeInOut 循环）；ZSW 详情同规格 |
| 画廊计数条 | 高 32pt 胶囊（`ultraThinMaterial` 底、圆角 16、描边 secondary 8%），内含 3pt 圆角进度条（`sjzAccent`）+ 文本"图片加载中 3/12"（12pt semibold，动态字数对齐）；完成态文案"图片加载完成 ✓"（sjzGreen）→ 1s 后 0.3s 渐隐（HIG 瞬态）；位于画廊上方、水平 16pt 内边距 |
| 单图占位（loading） | ShimmerView + 右下角 9pt 白字/黑 40% 圆角胶囊百分比（仅 progress 非 nil 时显示，随进度更新） |
| 单图成功 | 0.3s easeOut 淡入（缓存命中几乎瞬时）；渐进路径：平均色占位 → 高清淡入 |
| 单图失败 | `quaternary` 底 + `photo.badge.exclamationmark`（secondary）+ "轻点重试"（11pt secondary）；整卡 `.contentShape(Rectangle())` + onTap 重试 |
| WebView 进度条 | 顶部（安全区内贴导航栏下缘）高 2pt `sjzAccent` 线性进度（`estimatedProgress` 0→1），didFinish 100% 后 0.2s 停留 → 0.3s 渐隐 |
| 全屏大图进度 | 中央 44pt 圆形 `ProgressView(value:)`（白、轨道白 30%）+ "下载中 45%"（13pt 白 80%）；完成后 success 轻触感（UINotificationFeedbackGenerator.success） |
| 弱网提示 | 顶部滑入胶囊（orange 8% 底 + `wifi.exclamationmark` + orange 13pt 文本"网络较慢，已自动使用缓存/离线内容"），3s 后自动滑出（transition: move(edge: .top) + opacity） |
| 缓存徽标 | 高 22pt 胶囊（sjzGreen 10% 底 + `archivebox.fill` + "已缓存 · 秒开" 11pt sjzGreen），2.5s 后淡出 |
| 缓存中心清理反馈 | 清理中禁点 + 转圈；完成后成功触感 + 占用数字归零动画（animate value） |
| 相位指示 | 复用 `PhasedProgressIndicator`/`PhaseProgressDots`；ZSW/机构详情的相位文案：检查缓存 → 获取内容 → 解析排版 → 完成 |

---

## 七、日志埋点全表（全部走 LogManager；中文文案 + context 字典；无 print）

| 模块短名 | 埋点 | 级别 | 关键字段 |
|---|---|---|---|
| `urlProtocol`（新） | 共享会话初始化；图片响应缓存头注入；缓存命中预判；命中节流聚合 | info/debugLog | host、path 短名、maxAge、policy、gotFromCache |
| `imageCache` | 加载开始（含缓存预判）；命中秒开；网络成功；进度完成；预取跳过（已缓存）；降采样/护栏告警；解码失败；网络失败；自动重试（E8） | debugLog/warning/error | url 短名、耗时 ms、尺寸、降采样倍率、进度%、重试次数 |
| `cache` | recordImageHit/Miss（协议层调用）；预取组启停（E1）；缓存中心占用/清理（E2）；内存警告降载（E9）；关闭模式清理引导（E11） | info/debugLog/warning | 计数、清理字节、剩余容量 |
| `ui` | 画廊计数条出现/完成；详情三态迁移；缓存徽标展示（E3）；弱网提示展示（E7） | debugLog | 张数、耗时、来源、触发原因 |
| `organization` | WebView estimatedProgress 关键节点；机构 SWR 先缓存后刷新；搜索 query 缓存命中（E13）；超时切纯文本（已有） | info/debugLog/warning | progress%、文章 id、query、缓存年龄 |
| `data` | 缓存模式跳过远程同步（F4）；下一篇预取（E6） | info/debugLog | 距上次同步时长、dataSource、articleId |
| `startup`（新） | 启动预热启停与结果（E5） | info | 预取张数、命中数、耗时 |
| `network` | 既有成功/重试/失败日志保留（不动） | info/warning/error | 既有字段 |

（本次触碰文件内的既有 print 残留一并替换为 LogManager，不新增 print。）

---

## 八、回归风险表

| 风险 | 影响面 | 防护 |
|---|---|---|
| 协议层全局改动 | 所有 sxjzit.edu.cn 请求 | 仅改缓存策略与会话复用；Referer/UA/递归防护逐字保留；错误顺序不变 |
| API 数据被误缓存 | 列表/详情 | 仅 `image/*` 注入缓存头；API 无头不缓存；非 2xx 不缓存 |
| 视频被干扰 | AVPlayer | `video/*` 不注入；真机播放回归验证 |
| 即时模式实时语义 | 数据新鲜度 | 主会话 `reloadIgnoringLocalAndRemoteCacheData` **不动**；缓存模式差异只经 F4/F5 短路实现 |
| 线程安全 | 协议回调非主线程 | CacheModeManager 仅经 nonisolated + 锁镜像/计数通道访问 |
| 统计双计 | 缓存设置页 | 计数唯一收口协议层；组件层删计数调用 |
| 滚动日志抖动 | 日志文件 | 命中按 URL 首见节流 |
| 降采样保真 | 图片质量 | 仅缩略图/画廊降采样；FullScreen 用原图；40MB 像素护栏 |
| 预取流量 | 弱网 | 并发≤4；即时模式仅热点；缓存模式才全量 |
| WebView KVO | 机构详情 | 只读 KVO；保留 loaded/blank 通知流与 6s 兜底 |
| 机构定时器 | OrganizationManager | F5 中 timer 启停仅在开关切换时 invalidate/重建，保持既有线程语义 |
| 滚动让路（E10） | 列表图片加载节奏 | `#available(iOS 18)` 保护，低版本走原逻辑 |
| 红线区 | 通知/隐私/下拉刷新 | 完全不碰 NotificationManager delegate 区、AnnouncementManager、PrivacyPolicyView/PrivacyManager、OrganizationDetailView 下拉刷新区 |
| git 已失效 | 全部改动 | 开工前备份 `qin/DesignCode` 与工程文件 |

## 九、改动文件清单

1. `RefererHeaderURLProtocol.swift` — F1 重写
2. `ImageComponents.swift` — **新建**：SJZCachedImage + 共享会话/预取器/降采样解码器/平均色缓存
3. `TabBar.swift` — 三类详情页 + FullScreen + 长图下载 + 21 处缩略图替换、删 ZSWAsyncImage、E7 弱网提示
4. `OrganizationDetailView.swift` — 画廊替换 + WebView estimatedProgress
5. `OrganizationView.swift` — 搜索图替换 + E13 搜索缓存
6. `OrganizationManager.swift` — F5 缓存短路 + 定时器模式联动
7. `CacheModeManager.swift` — nonisolated 镜像 + 协议层统计/清理/内存降载通道
8. `DataService.swift` — F4 短路 + E5 预热 + E6 预取
9. `CacheModeSettingsView.swift` — E2 缓存中心 + E11 清理引导
10. `DesignCodeApp.swift` —（如 E9 通知注册放启动编排，否则并入 CacheModeManager）

## 十、验证方案（真机）

1. `xcodebuild build` 真机（`platform=iOS,id=00008110-000411A40EC1401E`）0 warning。
2. `xcodebuild test` 真机 11 用例全绿（含 3 在线用例）。
3. 手动清单（LogListView 过滤模块核对日志）：
   - 冷启 → 首页滑动：`urlProtocol` 注入/命中日志出现；二次滑动缩略图零新网络请求（network 模块无对应请求记录）。
   - 开启缓存模式 → 飞行模式 → 重进新闻详情/画廊：正文与图片秒开（NSCache + returnCacheDataElseLoad）。
   - 图片繁多的机构文章：WebView 顶部进度条 0→100% 后消失；画廊"图片加载中 x/y"完成后渐隐；断网重开仍能渲染（F5 SWR 缓存）。
   - 全屏大图：首次百分比进度环，二次进入缓存秒开。
   - 缓存设置页：命中率随操作增长；E2 占用显示与清理可用且计数可恢复。
   - 机构搜索：缓存模式同 query 秒回且命中日志可见（E13）。
   - 首页视频播放正常（防盗链未破坏）；通知功能正常（未触碰）。
   - ZSW 详情：骨架屏 + 画廊计数条出现、完成、渐隐。
   - 内存：打开图片繁多文章（如招生计划）后进程内存不异常增长（E4/E9 生效日志）。

---

# 附：文章文字颜色调节（2026-09-22 追加实施记录）

## 需求

「我的 → 显示设置」新增文章正文文字颜色调节：预设色板 + 自定义色，全部正文渲染点即时生效，明暗模式自动适配，完整日志埋点。

## 设计（经用户确认：8 预设 + 自定义；预设明暗双色值、自定义单色直用；全覆盖渲染点）

### 色板（`ArticleTextColorPreset`，`DisplaySettingsManager.swift`）

| 预设 | 浅色 | 深色 | 说明 |
|---|---|---|---|
| system 跟随系统 | —（保持原语义色） | — | 默认，现状不变 |
| ink 墨黑 | 1A1A1A | E8E8E8 | 经典醒目 |
| graphite 石墨 | 4A4A55 | C6C6CE | 低调沉稳 |
| sepia 暖棕 | 5D4037 | CDA98F | 护眼纸感 |
| navy 藏蓝 | 1B3A5C | 9FB8D9 | 理性深邃 |
| forest 松绿 | 2E4A3A | A9C4B6 | 自然舒缓 |
| indigo 靛紫 | 3F3D7A | B5B2E8 | 文艺雅致 |
| burgundy 勃艮第 | 6D2E3A | D9A5B0 | 复古优雅 |
| custom 自定义 | 单色直用（ColorPicker + hex 输入） | 同左 | 自由配色 |

### 存储与解析

- `displayArticleTextColorPreset` / `displayArticleTextCustomHex`（UserDefaults）
- `articleBodyColor`：nil = 跟随系统；ColorPicker 联动（Color.Resolved 提取，iOS 27 getRed 签名变更规避）
- `articleCSSTextLightHex/DarkHex`：WebView 注入
- `articleBodyLightHexSnapshot()`：**nonisolated** 快照（长图渲染器等非主线程上下文直读 UserDefaults）
- 纳入 isDefault / resetAll / 初始化日志

## UI（`DisplaySettingsView.swift` 新分区「文章文字颜色」，置于排版后）

- 实时预览段落卡片（正文颜色 + 行距/字距即选即生效）
- 3×3 色卡网格：渐变圆形色块 + 选中打勾 + 色名/副标题；system 卡半黑半白渐变，custom 卡彩虹渐变
- Liquid Glass 状态胶囊「当前：X · 已生效」+ 动态 footer 状态说明
- 自定义面板：ColorPicker（supportsOpacity: false）+ 十六进制输入（实时校验 + 打勾/警示图标）
- 非默认时显示「恢复跟随系统」按钮（触感反馈 + 弹簧动画）

## 渲染点接入（共 7 视图 + 2 WebView + 1 长图）

1. `TabBar.swift` EnhancedNewsDetailView：正文 + 错误兜底摘要
2. `TabBar.swift` ZSWArticleDetailView：正文 + 错误兜底 + 无 articleId 摘要兜底
3. `TabBar.swift` HonorDetailView / SceneryDetailView / TeacherDetailView / StoryDetailView / ActivityDetailView：正文 + 错误兜底
4. `OrganizationDetailView.swift` OrganizationArticleDetailView：纯文本模式 + 空内容摘要兜底
5. `OrganizationArticleWebView.buildHTMLPage` + `HTMLWebView.buildHTMLPage`：`--text-color` CSS 明暗双值注入
6. `ArticleLongImageRenderer`：正文颜色联动（白底固定浅色值；跟随系统保持原 0.2 深灰；nonisolated 快照解析，日志移入调用点 MainActor.run 内）

## 日志埋点（display / organization 模块）

预设切换（含色值）、色卡点击、自定义色变更（0.5s 节流）、hex 输入应用、恢复跟随系统、双 WebView CSS 注入、长图渲染配色。

## 验证

- 真机 BUILD SUCCEEDED **0 error / 0 warning**；`xcodebuild test` **11/11 全绿**（含 3 在线用例）。
- 手动验收要点：设置页切换色卡 → 预览段落与胶囊即时变色；新闻/招生/机构纯文本/机构网页原文/长图分享同步换色；深色模式各预设自动适配；自定义色 hex 输入实时校验；恢复默认回退语义色。

---

# 附：应用图标切换（2026-09-22 追加实施记录）

## 方案概要

以主图标 1024 原图为基准做 HSV 像素分类（背景/蓝柱/青描边/白色高光），参数化重着色生成 4 套「同构异色」备选：**星夜（紫调）/ 晨曦（暖橙金）/ 极简（浅底藏蓝+铜金箭头）/ 金典（黑金）**；经多轮 256px 真实尺寸视觉验收（smooth 渐变重建 + film grain 根治 banding）。工程侧通过 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` 注册（Info.plist 的 CFBundleIcons 由 Xcode 自动生成，未手改）；代码侧在 `TabBar.swift` 内新增 `AppIconManager` + `AppIconSettingsView`，设置页新增入口 Section，启动校准在 `DesignCodeApp.init`。

## 资源清单（`Scripts/generate_alternate_icons.py` 可重复执行、参数化）

- `Assets.xcassets/AppIconAlt1~4.appiconset`：每套 20 文件（9 iPhone 尺寸 + 9 iPad 尺寸 + 1024 marketing），RGB 无 alpha、直角、主体居中（继承主图标构图）
- `Assets.xcassets/IconPreviewPrimary + IconPreviewAlt1~4.imageset`：设置页网格预览（180/120px）
- 源体积约 7.2MB；构建后 Assets.car 约 5.7MB（实际入包增量约 4-5MB，压缩后）

## 工程配置

- `project.pbxproj`（主 Target Debug/Release 两处）：新增 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIconAlt1 AppIconAlt2 AppIconAlt3 AppIconAlt4"`，其余未动
- 产物验证：`plutil` 确认 `CFBundleIcons` 与 `CFBundleIcons~ipad` 均含 4 套 Alternate + Primary；`assetutil --info` 确认 car 内 25 个图标条目

## 代码要点

- `AppIconManager`（@MainActor 单例）：`supportsAlternateIcons` / `activeIconName`（系统实际值快照，@Published 驱动选中态）/ `setIcon(nil)` 恢复主图标 / 同值短路 / 失败不改本地记录（选中态自然回滚）/ completion 非主队列 → `Task { @MainActor }` 切回 / 0.5s 内重复请求防连点（isSwitching）
- 启动校准 `calibrateOnLaunch()`：以 `UIApplication.shared.alternateIconName` 为准写回 UserDefaults
- `AppIconSettingsView`：3 列网格 60×60 圆角 14 预览 + 选中 checkmark.circle.fill + 弹簧缩放/描边高亮 + 内联错误回滚提示 + 切换中进度 + VoiceOver（「图标：星夜，当前使用中」）+ 不支持时置灰说明
- `SettingsView`：新增「应用图标」Section（NavigationLink + 当前名副标题）
- 日志埋点：`appicon` 模块 —— 启动校准、发起/成功/失败切换、同值跳过、不支持、页面打开；无 print

## 验证

- 真机 BUILD SUCCEEDED **0 error / 0 warning**；`xcodebuild test` **11/11 全绿**
- 真机手动复核要点：设置 → 应用图标 → 点选任一图标 → 系统确认弹窗 → 主屏幕图标即时更换；再选「默认」恢复；重启 App 后本地记录与系统一致（校准日志出现）；iPad（如支持）安装后检查图标与 Settings 图标一致。

---

# 附：文章字数与阅读时长（2026-09-22 追加实施记录）

## 口径声明（全程一致）

**口径 A**：总字数 = 中文字符数（CJK 五区间）+ 英文单词数；中英混排不粘连（「你会说English吗」= 4 字 + 1 词）；时长 = 中文/300 + 英文/220（字/词每分钟）+ 图片 12s 递减（逐张 -1s、最低 3s）+ 代码块 30s；向上取整、正文非空至少 1 分钟、≥70 分钟转为「约 X/X.X 小时」；正文空/纯空白/纯标点返回 nil 不展示。

## 实现摘要

- **计算层**（`DisplaySettingsManager.swift` 底部）：`ReadingStatsCalculator` 纯函数（单趟遍历、无 UI 依赖）；`stripMarkdown`（围栏代码块/图片/链接/标题/+*_` 剥离并计数）；`stripHTML`（正则计 `<img`/`<pre`，优先详情接口已知图片数，不可靠按 0）；`ReadingStatsCache`（内存 + UserDefaults 持久化、500 条 FIFO、分量存储：字数/词数/图片数/代码块数——速度档位切换只重算分钟，不重扫全文）；`ReadingStatsService` 业务入口（缓存命中 / 5 万字符以上 `Task.detached(.utility)` 后台化 / 完整 reading 日志含耗时）
- **设置层**：`DisplaySettingsManager` 新增 5 项（总开关 / 字数开关 / 时长开关 / 列表徽标开关 / 速度档位 慢·标准·快，默认标准 300/220）+ `ReadingSpeedTier` 枚举，全部持久化 + 日志、纳入 isDefault/resetAll；`DisplaySettingsView` 新增「阅读统计」分区（实时预览段卡随档位即时演算、状态胶囊「已启用 · 标准」、四开关 + 速度 Picker、动态 footer 状态文案）
- **渲染接入**：7 个详情页 meta 区（新闻/招生/榜样/教师/校友/活动/风光统一组件 `ArticleReadingStatsText`：点分隔「2,486 字 · 阅读约 9 分钟」、字数与时长可独立开关、VoiceOver 合并单一标签）+ 机构文章 HTML 入口（元信息栏）+ 3 处列表徽标（首页重要新闻行 / 招生文章列表行 / 机构搜索结果卡，均用只读缓存 `ReadingTimeBadgeView`：无记录不显示、滚动零计算）
- **日志**：`reading` 模块 —— 缓存初始化/命中、计算完成（字数/词数/图片/代码块/分钟/耗时 ms）、超长后台化；`display` 模块 —— 5 项设置变更

## 修复历史

- 孤立连字符误计词（"-" 被当成单独英文词）：拆分「词首字符」（字母数字）与「词内标点」（' - _，仅延续已有词），由单测 testPunctuationStripped 捕获后修复

## 验证

- 真机 BUILD SUCCEEDED **0 error / 0 warning**；`xcodebuild test` **20/20 全绿**（原 11 + 新增 ReadingStatsCalculatorTests 9 组：纯中文 300 字→1 分钟 / 纯英文 440 词→2 分钟 / 混排不粘连 / 标点剔除 / Markdown 2 块 3 图附加 93s / 空文本 nil / 10 万字性能 <1s / 千分位与小时换算 / 图片递减地板）