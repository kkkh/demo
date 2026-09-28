# 山西晋中理工学院 App「园枢」— 架构概览（ARCHITECTURE.md）

> 本文件为**架构概览版**（对应报告版见 `项目技术全景报告.md`；权威分册为 [`docs/code-wiki/`](docs/code-wiki/README.md)，行号/签名以分册为准）。
> **基线日期：2026-09-27**（真机实测复核）。全部数字经 `wc -l` 与逐符号 grep 实测核对。

---

## 目录

1. [项目基础](#1-项目基础)
2. [目录拓扑](#2-目录拓扑)
3. [技术栈全景](#3-技术栈全景)
4. [数据架构](#4-数据架构)
5. [核心业务模块](#5-核心业务模块)
6. [路由与导航](#6-路由与导航)
7. [网络层](#7-网络层)
8. [关键执行链路](#8-关键执行链路)
9. [配置与环境](#9-配置与环境)
10. [代码规范与模式](#10-代码规范与模式)
11. [风险扫描](#11-风险扫描)
12. [工程约束附录](#12-工程约束附录)

---

## 1. 项目基础

| 项 | 结论 |
|---|---|
| **平台** | iOS 原生（iPhone + iPad，`TARGETED_DEVICE_FAMILY = "1,2"`） |
| **语言** | Swift `SWIFT_VERSION = 5.0`；实际使用 `async/await`、`@MainActor`、`withTaskGroup`、`Task.detached` |
| **UI 框架** | 纯 SwiftUI（`@main` App 生命周期），混用 UIKit / WebKit / AVKit / UserNotifications / LocalAuthentication |
| **包管理器** | **无**（无 Podfile / Package.swift / Carthage）；唯一第三方为**微信开放平台 SDK**（`Frameworks/WechatOpenSDK.xcframework`，手工挂载 + `-ObjC -all_load`），其余 100% Apple 系统框架 |
| **构建工具** | Xcode 27.0（Build 27A266a）+ `xcodebuild`，无 CI/CD |
| **App 标识** | 显示名 `园枢`（工程名沿用模板 `DesignCode`）；Bundle ID `com.qinchao`；Team `F2JL9GNLCC`；版本 `1.0 (Build 1)`（Info.plist 直写） |
| **部署目标** | ⚠️ **冲突**：project 层 `13.0`，target 层 `26.0`（target 覆盖 project，实际生效 26.0） |
| **Target** | `DesignCode`（主 App）+ `DesignCodeTests`（单元测试） |
| **代码规模** | 48 个 Swift 文件共 **59,730 行**（主 target 46 文件 57,925 行 + 测试 3 文件 1,805 行）；**108 个单元用例**（2026-09-27 真机复测 108/108 通过，日志 `build/verify/wechat_test_20260927b.log`） |
| **日志** | 自研 `LogManager`：**37 个日志域、1,089 处带域埋点**（`LogManager.shared` 调用点 1,118 处；其中 `wechat` 域 63 处）、日轮转、崩溃捕获、可导出 |

关键文件：
- `DesignCode/DesignCodeApp.swift` — `@main` 入口（190 行）：URLCache 扩容、URLProtocol 注册、隐私分流、生物识别遮罩
- `DesignCode/TabBar.swift` — 主视图集（**12,274 行**，60+ View）
- `DesignCode/Info.plist` — App 配置 / ATS / 120Hz 解锁

---

## 2. 目录拓扑

```
qin/
├── DesignCode/                         ← 全部源码（46 个 .swift，扁平无子目录）
│   ├── DesignCodeApp.swift             ← @main 入口（190 行）
│   ├── TabBar.swift                    ← 主视图集（12,274 行）：MainTabView / 五 Tab 全部
│   │                                    校园 Tab 七分区 / ZSW 招生网 / SJZ 组件族 / AppIconManager
│   ├── Models.swift                    ← 全部业务模型 + default* 兜底数据（1,591 行）
│   ├── NetworkService.swift            ← 网络层：GET 封装 + 全部 DTO（1,599 行）
│   ├── DataService.swift               ← 数据枢纽：同步/缓存/详情解析（1,246 行）
│   ├── NotificationManager.swift       ← 通知四通道轮询 + 深链（1,067 行）
│   ├── MessageCenterStore/View.swift   ← 消息中心站内信五通道（823/925 行）
│   ├── HelpContent/HelpGuideStore/HelpGuideView.swift ← 使用帮助（573/239/1,550 行，零网络）
│   ├── CampusCalendarStore/View.swift  ← 校园日历（478/1,485 行）
│   ├── SchoolProfileView.swift         ← 学校概况七板块（3,511 行，含 Store/保存工具）
│   ├── OrganizationManager/View/DetailView.swift ← 机构设置（730/2,183/5,273 行）
│   ├── PartySubjectView.swift          ← 党建专题 + 文章详情（2,566 行，含 Store/解析器/缓存）
│   ├── PrincipalMailboxView.swift      ← 校长信箱（1,787 行，含 Store）
│   ├── BookmarkManager/BookmarkListView.swift    ← 收藏 + 第五推送通道（424/513 行）
│   ├── AnnouncementManager/AnnouncementDetailView.swift ← 公告（340/226 行）
│   ├── PrivacyManager/PrivacyPolicyView/PrivacyLegalTexts.swift ← 隐私合规（449/795/265 行）
│   ├── BiometricSecurityManager/SettingsView/LockOverlayView.swift ← 生物识别锁（524/168/137 行）
│   ├── DisplaySettingsManager/DisplaySettingsView.swift ← 显示设置+阅读统计（2,382/2,227 行）
│   ├── CacheModeManager/CacheModeSettingsView.swift ← 缓存模式（455/600 行）
│   ├── HomeModuleManager/HomeModuleSettingsView.swift ← 首页 12 模块（356/146 行）
│   ├── SJZNetworkMonitor/NetworkMonitorView.swift ← 网络遥测（1,796/1,609 行）
│   ├── NotificationTestView.swift      ← 通知测试中心（501 行）
│   ├── LogManager/LogListView/LogSettingsView.swift ← 日志系统（351/393/86 行）
│   ├── ReadStatusManager.swift         ← 已读状态（70 行）
│   ├── RefererHeaderURLProtocol.swift  ← 防盗链 URLProtocol（232 行）
│   ├── SplashView.swift                ← 启动页（125 行）
│   ├── WeChatService.swift             ← 微信 SDK 集成（1,305 行：注册/分享/登录/小程序/自检/回执/日志桥）
│   ├── WeChatIntegrationViews.swift    ← 微信界面（808 行：分享菜单/集成中心/回执横幅）
│   ├── DesignCode.entitlements         ← 关联域名（Universal Link 用；免费个人团队不支持该能力，暂未启用）
│   └── Assets.xcassets / Base.lproj    ← 资源（5 套 AppIcon 含 AppIconAlt1~4）
├── Frameworks/                         ← WechatOpenSDK.xcframework（OpenSDK 2.0.8，唯一第三方）
├── DesignCode.xcodeproj/               ← Xcode 工程
├── DesignCodeTests/                    ← 单元测试 3 文件 108 用例（NetworkServiceDTOTests 650 行 / MessageCenterStoreTests 818 行 / WeChatSDKTests 337 行）
├── docs/code-wiki/                     ← ★ 权威 Wiki 分册（01~07 + README）
├── docs/wechat-integration/            ← ★ 微信接入指南 + AASA 模板
├── CODE_WIKI.md                        ← 历史合并版（头部统计已刷新，以分册为准）
├── designcode-swiftui 根：校园Tab模块升级总结报告.md（2026-09-26）
├── DesignCode_backup_20260922/         ← 2026-09-22 备份快照（勿引用）
└── build/ · .build/ · ExportOptions.plist
```

> **结构要点**：源码**未分层平铺**（单目录 46 文件），靠命名后缀区分职责：`*Service`=网络/数据、`*Manager`=管理器、`*Store`=新模块数据中枢、`*View`=视图；模型集中在 `Models.swift` 与 `NetworkService.swift`（嵌套 DTO）。唯一第三方 `WechatOpenSDK.xcframework` 位于 `Frameworks/`，经 `-ObjC -all_load` 链接。

---

## 3. 技术栈全景

| 框架 | 用途 |
|---|---|
| **SwiftUI** | 全部 UI、`@main`、`@Published/@ObservedObject` 响应式、Liquid Glass（glassEffect/GlassEffectContainer） |
| **Combine** | `ObservableObject` 状态驱动、`Timer.publish` |
| **Foundation** | `URLSession`、JSON 编解码、`FileManager`、`UserDefaults` |
| **UserNotifications** | 本地推送、badge、通知点击回调；**无 APNs** |
| **WebKit** | `WKWebView` 文章详情「查看原文」 |
| **AVKit** | `AVPlayer` 校园宣传片内联播放 |
| **CryptoKit** | SHA256（图片缓存键/收藏指纹） |
| **UIKit** | `UIImage`、`UIViewControllerRepresentable`、触觉反馈、`UIScreen` 亮度 |
| **LocalAuthentication** | Face ID / Touch ID / Optic ID 隐私锁 |
| **Network** | `NWPathMonitor` 网络状态监测（SJZNetworkMonitor 全链路遥测） |
| **Photos** | 相册保存（file-based 写入，WebP 铁律） |
| **WechatOpenSDK 2.0.8** | 唯一第三方：微信分享（会话/朋友圈/收藏）、微信登录、小程序跳转、Universal Link 自检（`Frameworks/WechatOpenSDK.xcframework`，静态库 → `-ObjC -all_load` + Security/CoreGraphics/WebKit/CFNetwork/SystemConfiguration/CoreTelephony/libz/libsqlite3/libc++） |

**自研基建**（替代第三方库）：
- 图片：`SJZCachedImage`/`SJZImageKit`（TabBar.swift L10342 起，内存 NSCache + URLCache 共享 80/400MB + 磁盘；720px/1440px 下采样；四态 phase）
- 网络：纯 `URLSession` + async/await，3 次重试指数退避
- HTML 解析：纯正则（全项目**禁止** `NSAttributedString(documentType:.html)`）
- 日志：自研 `LogManager`（37 日志域、日轮转、崩溃捕获、导出）
- 推送：无服务端条件下**官网指纹轮询**自建本地推送（新闻/信箱/概况/党建四通道 + 收藏第五通道）

---

## 4. 数据架构

### 4.1 存储选型

**无数据库、无 ORM、无 CoreData/SwiftData。** `UserDefaults`（偏好/轻量状态）+ 文件 JSON（离线缓存）+ Keychain（生物令牌）+ 硬编码静态兜底。

### 4.2 三层数据降级（核心设计）

```
① 远程 API  gwqietap.sxjzit.edu.cn/mapi      ← 优先（15s 超时 + 2 次重试）
② 本地缓存  Documents/SXJZIT_Cache/*.json    ← 网络失败回退（21 键）
③ 静态兜底  Models.swift 的 default* 常量    ← 无缓存时离线可用
```

`DataService.dataSource` 标记来源（"预置数据"/"缓存"/"服务器"）；同步完成广播 `syncDidCompleteNotification`。

### 4.3 状态管理

**轻量 MVVM + Singleton 服务层**：全部 Manager/Store 为 `@MainActor` 单例（`NetworkService` 例外，`@unchecked Sendable`）；视图 `@ObservedObject` 直连单例（无 DI、无 `@EnvironmentObject`）；跨模块一次性事件走 `NotificationCenter`（3 个名称），**深链走 `@Published` 属性**（非通知）。

### 4.4 持久化明细

| 模块 | 介质 | Key/路径 |
|---|---|---|
| DataService | 文件 JSON | `Documents/SXJZIT_Cache/*.json`（21 键：news/honors/departments/banners/videos/stories/…） |
| LogManager | 文件 JSON | `Documents/SXJZIT_Cache/Logs/log_YYYY-MM-DD.json` 日轮转 |
| MessageCenterStore | 文件 JSON | `Documents/MessageCenter/messageCenterEvents.json`（强原子写 + corrupt-时间戳 备份×5） |
| BookmarkManager | UserDefaults + 文件 | `bookmarkedArticles`；图片 `BookmarkImages/*.img`（SHA256 键） |
| ReadStatusManager | UserDefaults | `readArticleIds`（上限 5000） |
| NotificationManager | UserDefaults | `notifiedArticleIds`（2000）、`schoolProfileBaseline`（7\|10\|29）、`partySubjectBaseline`（四段指纹）、`notificationPollingMinutes`（默认 30） |
| 其他缓存 | UserDefaults | `announcementCache`/`organizationCache`/`privacy_documents_cache_{type}`/`campusCalendarCache` 等 |
| 偏好 | @AppStorage | `privacyConsentAccepted/Rejected`、`colorSchemePreference`（⚠️ 双主共享键）、`logDebugEnabled`、`bookmarkMaxCount` 等 |
| Keychain | Security | 生物识别启用令牌（`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`） |
| 内存 | NSCache/URLCache | 图片 96/40MB 双限制；URLCache.shared 80MB/400MB；详情 NSCache 按 cost |

### 4.5 数据模型全景

核心模型集中在 `Models.swift`（1,591 行）：`SchoolInfo`（含校庆日）、`Banner`、`StatItem`、`Honor`、`Department/Major`、`NewsItem`、`StudentStory`、`TeacherProfile`、`CampusVideo`、`CampusActivity`、`CampusScenery`、`CampusService`、`Facility`（+ `FacilitySection`/`FacilityInfoPair` 分区）、`TimelineEvent`、`QuickLink`、`FooterLink`、`SocialPlatform`、`BookmarkItem`、`ZSW*`、`Specialty*`。
DTO 与业务模型分离（DTO 在 `NetworkService.swift`，全 Optional + `CodingKeys` 显式映射 + `AnyCodable` 兜底）。

---

## 5. 核心业务模块

**28 个模块**（详见 [docs/code-wiki/02-主要模块职责](docs/code-wiki/02-主要模块职责.md)）：

| 层 | 模块 |
|---|---|
| 启动编排 | DesignCodeApp + SplashView（URLCache 扩容/URLProtocol 注册/图标校准/隐私三分流/生物遮罩） |
| 主框架 | MainTabView 五 Tab（首页/院系/资讯/校园/我的）+ 深链分发中枢 |
| 内容域 | 首页 12 模块 / 新闻资讯 / 院系专业 / **校园生活七大分区**（校园服务·机构入口卡·概况卡·设施详情·友情链接·关注我们）/ ZSW 招生网 / 专业介绍 |
| 自包含业务模块（2026-09-24 后模式：私有 Store 直连 NetworkService，不经 DataService） | 学校概况（七板块+合作交流）/ 党建专题（双子站+详情页）/ 校长信箱 / 消息中心（站内信五通道）/ 使用帮助（32 篇内置，零网络）/ 校园日历（复用文章接口） |
| 支撑服务 | 机构设置 / 收藏（+第五推送通道）/ 通知（四通道轮询）/ 公告 / 隐私合规 / 生物识别锁 / 显示设置 / 缓存模式 / 日志 / 网络监测 / 已读状态 / 防盗链 / App 图标切换 |
| 微信开放平台集成（2026-09-27 新增） | `WeChatService`（注册/分享/登录/小程序/自检/回执中枢/日志桥）+ `WeChatIntegrationViews`（分享菜单/集成中心/回执横幅）+ `DesignCode.entitlements`（关联域名，**受签名团队为免费「个人团队」限制暂未启用**：该能力属付费 ADP 专属，证据=真机描述文件 7 天有效期）；配置单点 4 个构建设置，指南见 [docs/wechat-integration](docs/wechat-integration/README.md) |

---

## 6. 路由与导航

**无第三方路由库**，纯 SwiftUI 原生导航：

| 机制 | 用途 |
|---|---|
| `TabView` + 5 个 `tag`（TabBar.swift L144-176） | 一级导航：首页(0)/院系(1)/资讯(2)/校园(3)/我的(4)，「我的」挂未读 `.badge` |
| `NavigationStack`（每 Tab 独立） | 二级导航栈 |
| `NavigationLink` | 列表→详情 push |
| `.sheet` | 模态：消息中心、设置页群、深链详情（L304-339：新闻/信箱/概况/党建） |
| `ZStack` 覆盖层 | 启动页/隐私弹窗/受限模式/生物锁遮罩（zIndex 1-4 分层） |
| 内部协议 | `sxjzit://campus-calendar`（校园服务第 7 项 → 校园日历） |

**通知深链**（无 URL Scheme，`Info.plist` 无 `CFBundleURLTypes`）：

```
didReceive（completionHandler 版，同步链上绝不弹 UI）
  → handleNotificationTap → 写 @Published pendingDeepLink（UUID 保证 onChange 必触发）
  → MainTabView.onChange → 等待 scenePhase == .active && !isLockEngaged（≤3s）
  → Task.sleep 让出 runloop → 按五类弹 sheet（新闻/信箱/概况/党建/收藏）
```

消息中心深链：`dismissRequest`（0.45s 关闭）→ 复用同一防闪退链路。

---

## 7. 网络层

### 7.1 配置

| 项 | 值 |
|---|---|
| 基地址 | `https://gwqietap.sxjzit.edu.cn/mapi` |
| 超时 | 请求 15s / 资源 30s |
| 重试 | 2 次（合计 3 次，指数退避 500ms×N；`URLError.cancelled` 立即传播不重试） |
| 缓存 | `cachedSession`（详情缓存策略 reloadIgnoringLocalAndRemoteCacheData）；图片响应注入 7 天 Cache-Control |

### 7.2 请求封装

单例 `NetworkService`（`@unchecked Sendable`），统一 `get<T>(_ path:params:as:)` **仅 GET**；`NetworkError` 中文 errorDescription：badURL/badResponse/decodeFailed/timeout/noData/dataMissing/serverError（7 case）。

### 7.3 鉴权

**无 Token、无登录态、无签名。** 唯一请求头定制：`RefererHeaderURLProtocol` 拦截 `*.sxjzit.edu.cn` 注入 `Referer` + 浏览器 UA（防盗链），同时为网络监测记账。

### 7.4 接口清单（全 GET，行号见分册 03/06）

`fetchHome2`（/school/home2）· `fetchHead`（/common/column/head）· `fetchFoot`（/common/foot）· `fetchArticles`（/common/column/articles）· `fetchArticleDetail`（/common/article/detail）· `fetchArticleDetailWithHref` · `fetchJSONDict`×2 · `fetchZSWHome2` / `fetchZSWArticlePage` / `fetchZSWArticleDetail`（site_key=zsw）· `fetchSpecialtyData`（oneTwoArticles）· `fetchDeptHome2` · `fetchSchoolOrgTree` · `fetchDeptSiteIndex` · `fetchPartySubjectFingerprint` · `fetchSceneryAlbumDetail` · `fetchPrincipalMailbox`（/school/msg）· `fetchMessageDetail`（/common/msg/detail）。

**关键常量**：校园日历 `campusCalendarColumnId = 8197fe41503c4c32bce1e449d2492b2e`（复用文章接口，零新接口）；招生网 siteId `cb3b1fe4fcdf40999b0c162015c3326d`；专业介绍 columnId `25d7bd39e49a468880356e302b9ccf1d`；党建 site_key `djgz`/`mkszy`。

---

## 8. 关键执行链路

### 链路① App 启动

```
DesignCodeApp.init()
  ├─ URLCache.shared 扩容（内存 80MB / 磁盘 400MB）
  ├─ URLProtocol.registerClass(RefererHeaderURLProtocol)
  ├─ CacheModeManager.registerMemoryWarningHandler()
  ├─ AppIconManager.shared.calibrateOnLaunch()
  └─ LogManager.info("ui", "App 启动")

WindowGroup → ZStack：MainTabView(0→1) / SplashView / 隐私弹窗 / 受限模式 / 生物锁遮罩
.task { 1s → isAppReady=true }  →  按 privacyConsentAccepted/Rejected 三分流
.task(id:) { 刷新通知授权；已同意+授权+启用 → startPolling() }
.onChange(scenePhase) { 退后台锁定 / 回前台认证 }
MainTabView.task { 0.5s → data.syncIfNeeded() }
```

### 链路② 数据同步

`syncIfNeeded() → doFullSync()`：并行 fetchHome2+fetchHead+fetchFoot（全失败→缓存→兜底）→ 5 栏目分页拉取 → 视频/故事/教师/活动/风光 → 院系合并 → `OrganizationManager.updateSiteKeys(menus)` → `saveCache()`（21 键）→ 后台 Task 招生网+专业介绍 → `post(syncDidCompleteNotification)`。

### 链路③ 五通道推送轮询（默认 30 分钟）

```
checkForUpdates(pushToSystem:)：
  ① 新闻   对比 notifiedArticleIds（上限 2000）
  ② 信箱   对比最新一条
  ③ 概况   对比 schoolProfileBaseline（领导数|风光数|合作条数 = 7|10|29）
  ④ 党建   对比 partySubjectBaseline（djgz/mkszy 四段指纹）
  ⑤ 收藏   BookmarkManager.checkBookmarkedArticlesForUpdates（正文 SHA256 指纹）
每次变化：系统通知（≤5 条、1s 间隔防轰炸）+ MessageCenterStore.ingest 入站内信（静默模式只入盒）
```

### 链路④ 通知点击深链

见 §6（pendingDeepLink → MainTabView.onChange → 防闪退等待 → 五类 sheet）。

---

## 9. 配置与环境

- **多环境**：无 .env / xcconfig / dev-staging-prod，全部配置硬编码在源码。
- **签名**：`CODE_SIGN_STYLE = Automatic`，`DEVELOPMENT_TEAM = F2JL9GNLCC`；`ExportOptions.plist`（method=development，含明文 teamID）。
- **ATS**：`NSAllowsArbitraryLoads = false`，仅 `sxjzit.edu.cn`（含子域）HTTP 明文放行；其余强制 HTTPS。
- **120Hz**：Info.plist `CADisableMinimumFrameDurationOnPhone = true` 解锁 ProMotion。
- **构建/运行**：真机「秦超的iPhone」（UDID `00008110-000411A40EC1401E`，iOS 27.0）；`xcodebuild -project DesignCode.xcodeproj -scheme DesignCode -destination 'platform=iOS,id=…' build|test`。详见 [docs/code-wiki/05-项目运行方式](docs/code-wiki/05-项目运行方式.md)。
- **git**：2026-09-27 已重建（`main` 分支，初始提交 `b88e430`，含 `.gitignore`）；远端双备份：GitHub `kkkh/Garden-iOS`（origin）+ Gitee `oai/garden-ios`（remote `gitee`，SSH 专用密钥）；历史备份快照保留在磁盘。

---

## 10. 代码规范与模式

- 设计模式：单例/观察者/门面（DataService）/三层降级/轻量 MVVM/防护代理（URLProtocol）。
- `@MainActor` 单例（除 `NetworkService`），中文文案与中文注释，`contentShape(Rectangle())`，按钮无 Liquid Glass Tab API。
- 新业务模块范式（2026-09-24 起）：私有 `XxxStore: ObservableObject` 直连 NetworkService + 独立 View；缓存优先 + 三态刷新状态机 + `refreshDetached` 防取消误报 + 搜索防抖 `isSearchPending`。
- 日志：新增功能必须接 `LogManager` 埋点（现有 37 域、1,089 处为基准；`wechat` 域为 2026-09-27 新增）。
- 图片：720/1440px 下采样；WebP 保存走 JPEG 重编码 + file-based 写入。
- 消息中心落盘：临时文件 + `replaceItemAt` 原子替换 + 写后读回自校验。

---

## 11. 风险扫描

| # | 级别 | 问题 | 位置 |
|---|---|---|---|
| 1 | 高 | 部署目标冲突（project 13.0 vs target 26.0） | project.pbxproj |
| 2 | 高 | `exit(0)` 强制退出（Apple 审核风险） | PrivacyPolicyView.swift |
| 3 | 中 | `cacheArticleContent` await 后复用旧 idx（并发下标越界隐患） | BookmarkManager L242 |
| 4 | 中 | `@AppStorage + didSet` 残留（didSet 不触发） | NotificationManager L92 |
| 5 | 低 | `NewsItem.id = title + date` 主键碰撞；`ZSWArticle.id` 非稳定 | Models.swift |
| 6 | 低 | 生产 `print()` 残留 | DataService L846-860、TabBar LongImage/FullScreenImage |
| 7 | 低 | `TabBar.swift` 巨型文件（**12,274 行**、60+ View，2026-09-26 校园 Tab 升级后继续增长） | — |
| 8 | 低 | 搜索 columnId 硬编码：机构降级链两处已改运行时动态解析（2026-09-27，`resolveMainSiteSearchColumns`），持续核验 | OrganizationDetailView |
| 9 | 环境 | Team ID 明文（ExportOptions.plist）；git 已于 2026-09-27 重建 | 仓库根 |
| 10 | — | 已修复（2026-09-27，五项+追加）：AnnouncementManager isLoading（defer）；**字体按需下载根治**（根因=家族名当字面名传匹配引擎→静默零下载；改 PostScript 字面名契约 + 无进展看门狗 + 终态实查自愈 + 真实粗体字面 + 进度环/全部下载 UI）；机构降级 ID（见 #8）；图片缓存直读+自愈（重复加载根治）；警告误报治理（取消静默化 + 图片并发闸 ≤4 + netmon TTFB 口径）。真机 BUILD 0/0 + 86/86 全绿 | — |
| 11 | — | 已修复（2026-09-27，显示设置全链覆盖审计）：排版链 **261 处原始字体全部接入**（137 文本 + 17 Label + 124 图标；图表 AxisValueLabel 经字体工厂）；**59 处弹出层统一 `sjzPresentationChrome()`**（外观 + 灰度一处挂载双效，替换旧 sjzGrayScale）；**机构子站 WebView CSS 排版联动**（字体栈/字号/行高/字距/粗细 + 标题 em 缩放）；收藏列表补挂阅读时长角标；**构建期护栏** `Scripts/display_coverage_guard.py`（新功能绕过即 BUILD FAILED，已注入违规实测拦截）；真机 BUILD 0/0 + 87/87 全绿 | — |

---

## 12. 工程约束附录（红线，完整 16 条见 05-项目运行方式 §5.6）

1. 构建/测试/调试**必须真机**（UDID `00008110-000411A40EC1401E`），不用模拟器。
2. 全项目**禁止** `NSAttributedString(documentType:.html)` 解析 HTML——只用纯正则。
3. 通知回调同步链禁止弹 sheet（pendingDeepLink + 等待 active && !isLockEngaged + 让出 runloop）。
4. 手动刷新必须清详情缓存 + 推进 `cacheGeneration` 代际。
5. 图片：缩略图 720px / 详情 1440px；响应注入 7 天缓存头；WebP 保存走 JPEG 重编码 file-based 写入。
6. SF Symbols 必须校验存在性（iOS 26/27 已移除 `magnifyingglass.fill` 等旧符号）。
7. 静态矢量装饰层**禁止 `drawingGroup()`**（曾致真机疑似启动黑屏）。
8. 模块退役必须处理旧值（`retiredRawValues` 静默清理）。
9. **高密度导航控件必须「预览与提交分离」**（校园设施目录轮播 v1-v3 教训：拖动只移指针，点按才提交）。
10. 需单独确认的敏感区：PrivacyPolicyView（exit(0)）、RefererHeaderURLProtocol（全局拦截）、NotificationManager delegate 区、OrganizationDetailView 下拉刷新区、project.pbxproj。
11. **显示设置必须全链覆盖（构建期强制）**：文本/图标一律走 `displayFont / displayText / displaySymbolFont / displayLabelFont / DisplayFontFactory`；每个 `.sheet / .fullScreenCover` 内容根必须挂 `.sjzPresentationChrome()`（外观 + 专注灰度；分享面板 ShareSheet 豁免）；原文 WebView CSS 必须消费 `articleCSSTypography*` 注入；违规由 `Scripts/display_coverage_guard.py` 在构建阶段直接中断（例外登记 `Scripts/display_coverage_allowlist.txt`）。

---

> **待办（人工核实）**：① 部署目标统一（建议与现网 26.0 对齐并清理 project 层 13.0）；② `exit(0)` 改为主线程渐进退出替代方案；③ 补 `.gitignore`（已于 2026-09-27 完成）；④ 恢复 git 版本管理（已于 2026-09-27 完成，main 分支）。