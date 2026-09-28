# 「园枢」山西晋中理工学院 APP — Code Wiki

> **App 名称**：园枢（工程/目录名保留旧模板 `DesignCode`）
> **平台**：iOS 原生（iPhone + iPad）
> **开发语言**：Swift（Swift 5.0 配置，实际使用 `async/await`、`@MainActor`、`withTaskGroup` 等 Swift 5.5+ 特性）
> **UI 框架**：SwiftUI（`@main` App 生命周期），混用 UIKit / WebKit / AVKit / Swift Charts
> **架构模式**：轻量 MVVM + Singleton 服务层 + 观察者（`@Published` / `@ObservedObject`）；新业务模块（校长信箱/党建专题/学校概况）采用**模块内私有 Store + 视图**的自包含模式
> **依赖**：唯一第三方为**微信开放平台 SDK**（官方 XCFramework 2.0.8，静态库，`-ObjC -all_load` 链接；2026-09-27 接入），其余 100% Apple 系统框架，无 SPM / CocoaPods
> **持久化**：UserDefaults + 文件 JSON 缓存（`Documents/SXJZIT_Cache/`）+ Keychain + 硬编码静态兜底数据
> **网络**：URLSession + async/await，仅 GET
> **代码规模**：48 个 Swift 源文件（主 target 46 + 测试 3），**59,730 行**（主 target 57,925 + 测试 1,805；TabBar.swift 12,274、OrganizationDetailView.swift 5,338、SchoolProfileView.swift 3,511、PartySubjectView.swift 2,566、DisplaySettingsManager.swift 2,382、DisplaySettingsView.swift 2,227、OrganizationView.swift 2,183、SJZNetworkMonitor.swift 1,796、PrincipalMailboxView.swift 1,787、NetworkMonitorView.swift 1,609、NetworkService.swift 1,599、Models.swift 1,591、WeChatService.swift 1,095、WeChatIntegrationViews.swift 628——2026-09-27 wc -l 实测）+ 三个测试文件 **108 个单元用例**
> **文档更新日期**：2026-09-27（头部统计刷新；覆盖 2026-09-26 夜三波改造：**网络监测扩建**（八能力/47 处 netmon 埋点）、**显示设置艺术级重构**（F1–F19/字体体系/灰度跨页/对比度自检）、中文字体按需下载与专注灰度 44 处挂载；以及 **2026-09-27 微信开放平台 SDK 集成**（分享/登录/小程序/自检全链，`wechat` 域 63 处埋点，2026-09-28 补齐党建分享入口））。真机复测：2026-09-27 构建 + 108/108 用例通过（日志 `build/verify/wechat_test_20260927b.log`）
> **注意**：本文件为历史合并版，正文行号与模块细节基于 2026-09-24/25 快照（仅头部统计已于 2026-09-27 刷新）；**最新权威版本是 [`docs/code-wiki/`](docs/code-wiki/README.md) 分册（2026-09-27 基线，含 37 个日志域总表与全部新行号）**，冲突处以分册为准。

---

## 目录

1. [项目整体架构](#1-项目整体架构)
2. [文件与模块总览](#2-文件与模块总览)
3. [应用入口与启动流程](#3-应用入口与启动流程)
4. [核心服务层（Manager/Service/Store）](#4-核心服务层managerservicestore)
5. [视图层](#5-视图层)
6. [数据模型与静态兜底数据](#6-数据模型与静态兜底数据)
7. [网络层与 API 清单](#7-网络层与-api-清单)
8. [关键执行链路](#8-关键执行链路)
9. [持久化明细](#9-持久化明细)
10. [依赖关系总图](#10-依赖关系总图)
11. [项目运行方式](#11-项目运行方式)
12. [工程约定与注意事项](#12-工程约定与注意事项)

---

## 1. 项目整体架构

### 1.1 架构分层

```
┌────────────────────────────────────────────────────────────────────┐
│                         视图层 (Views)                              │
│  DesignCodeApp（ZStack 编排：主界面/启动页/隐私弹窗/受限模式/锁屏遮罩）│
│  MainTabView（5 Tab）→ HomeView / DepartmentsView / NewsListView /  │
│  CampusView / ProfileView + 各详情页 + 独立设置页（缓存/显示/生物/    │
│  首页模块/通知测试/日志/收藏/机构/公告/隐私/网络监测）                 │
│  自包含业务模块：SchoolProfileView / PartySubjectView /             │
│  PrincipalMailboxView（各自携带私有 Store）                         │
└───────────────────────────────┬────────────────────────────────────┘
                                │ @ObservedObject 直接引用单例
┌───────────────────────────────▼────────────────────────────────────┐
│                    服务层 (Services / Managers / Stores)            │
│  DataService           数据聚合、同步、缓存、降级（旧数据域枢纽）      │
│  NetworkService        网络请求、DTO 定义、JSON 容错解码              │
│  LogManager            日志记录/轮转/导出/崩溃捕获（被所有模块调用）    │
│  SJZNetworkMonitor     全 App 网络遥测中枢（链路/吞吐/延迟/诊断）※新   │
│  CacheModeManager      缓存模式 + 命中率统计                         │
│  DisplaySettingsManager 外观/主题/字体/亮度/锁定/文章文字颜色/阅读统计  │
│  AppIconManager        应用图标切换（alternate icons + 启动校准）     │
│  BiometricSecurityManager Face/Touch/Optic ID 安全锁                │
│  HomeModuleManager     首页 12 个内容模块显隐与排序（2026-09-24 终版）│
│  NotificationManager   官网更新四通道轮询 → 本地推送 + DeepLink（※四通道+收藏第五通道）│
│  BookmarkManager       收藏 + 正文/图片缓存                           │
│  AnnouncementManager   公告拉取/解析/判定                            │
│  OrganizationManager   机构数据 + site_key 匹配                     │
│  PrivacyManager        隐私协议文档三级降级                           │
│  ReadStatusManager     文章已读/未读状态                             │
│  RefererHeaderURLProtocol 自定义 URLProtocol 防盗链绕过 + 网络监测埋点 │
│  SchoolProfileStore    学校概况数据中枢（七板块 + 校企合作全量详情）※新  │
│  PartySubjectStore     党建/思政专题数据中枢（双子站全量拉取）※新      │
│  PrincipalMailboxStore 校长信箱数据中枢（分页/基线/刷新状态机）※新     │
│  MessageCenterStore    消息中心数据中枢（五通道消息盒/自愈存储）※新      │
│  HelpGuideStore        使用帮助数据中枢（32 篇内置指南/加权搜索）※新    │
│  CampusCalendarStore   校园日历数据中枢（列表/缓存/本地搜索）※新       │
│  图片/阅读/统计子体系（组件级，TabBar.swift 底部）                 │
│  │ SJZCachedImage 统一图片组件 · SJZImageKit 加载工具集              │
│  │ SJZImagePrefetcher 预取 · SJZAverageColorCache 平均色占位          │
│  │ SJZArticleLoadingView 文章加载态 · SJZRevealOnce 错峰入场          │
│  │ SJZPageLoadProgressBar/GalleryProgressBar 页面加载进度条          │
│  │ ReadingStatsCalculator/Cache/Service 字数与阅读时长引擎           │
│  │ ArticleReadingStatsText/ReadingTimeBadgeView 统计渲染组件         │
└───────────────────────────────┬────────────────────────────────────┘
                                │
┌───────────────────────────────▼────────────────────────────────────┐
│                      数据层 (Models / Persistence)                  │
│  Models.swift   → 全部业务模型 + default* 全局常量兜底数据            │
│  UserDefaults   → 偏好设置、收藏、已读、缓存统计、模块排序、搜索历史等  │
│  Keychain       → 生物识别启用令牌（kSecAttrAccessibleWhenPasscode…）│
│  文件系统       → Documents/SXJZIT_Cache/*.json 与 Logs/ 日志文件     │
│  URLCache.shared → 扩容 80MB 内存 / 400MB 磁盘（App init 中统一配置）│
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 源码组织

源码**未分层**：全部 Swift 文件平铺在 `DesignCode/` 目录下，仅靠命名后缀区分职责——`*Service`（网络）、`*Manager`（管理器）、`*Store`（新模块数据中枢）、`*View`（视图）、模型集中在 `Models.swift` 与 `NetworkService.swift`（嵌套 DTO）。

> 架构演进说明（2026-09-24）：校长信箱/党建专题/学校概况/消息中心/使用帮助/校园日历六个新业务模块**不再经过 DataService 门面**，而是模块文件内私有的 `*Store: ObservableObject` 直接调用 `NetworkService` 拉数、本地维护搜索/刷新状态。理由：各模块数据形态特殊（单接口全量/动态字典解析/多级分页/本地缓存优先），独立 Store 隔离更彻底、互不影响。

### 1.3 设计模式

| 模式 | 具体体现 |
|------|---------|
| 单例 | 所有 Manager/Service/Store 通过 `static let shared` 提供全局唯一实例 |
| 观察者 | `@Published` 属性 + 视图层 `@ObservedObject` 驱动 UI 更新 |
| 门面 | `DataService` 聚合旧数据域（首页/招生/专业）；新三模块独立 Store 直连 NetworkService |
| 三层降级 | 远程 API → 本地 JSON 缓存 → 静态兜底 `default*`，保证 100% 离线可用 |
| 状态机 | `BiometricSecurityManager.LockState`：inactive → locked → authenticating → unlocked；三新模块统一 `RefreshStatus`：idle → refreshing → success/failed |
| 装饰器（ViewModifier） | `displayTypography` / `displayText` / `biometricLockProtected` / `SJZRevealOnce` / `SJZScrollActivityTracker`（滚动方向追踪，定义于 SchoolProfileView.swift，internal 共享）全局注入 |
| URLProtocol 扩展 | `RefererHeaderURLProtocol` 透明注入防盗链请求头 + 7 天图片缓存头 + 网络监测台账埋点 |
| 异步优先 | 网络全 `async/await`；日志异步防抖写入；图片异步两级缓存；机构/党建搜索并发批处理（`withTaskGroup`）流式合入 |

### 1.4 状态管理方案

- **无** `@EnvironmentObject` 注入、**无**第三方状态库，视图直接引用单例（`@ObservedObject private var x = XManager.shared`）。
- 配置类持久化一律走 `@AppStorage` 或 Manager 自管 `@Published` + `didSet` 落盘。
- 跨层一次性事件（通知点击 → 主界面弹详情）已改为 `@Published` 状态驱动（`pendingDeepLink` / `pendingMailboxDeepLink` / `pendingSchoolProfileDeepLink` / `pendingPartySubjectDeepLink` / `pendingMessageCenterDeepLink`，新实例 UUID 保证 onChange 必触发），避免系统回调同步链崩溃。

---

## 2. 文件与模块总览

### 2.1 入口与主视图

| 文件 | 行数 | 职责 |
|------|------|------|
| [DesignCodeApp.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DesignCodeApp.swift) | 190 | `@main` 入口：扩容 URLCache、注册 URLProtocol、图标启动校准、内存警告降载、启动流程、隐私弹窗/受限模式/生物锁遮罩编排 |
| [TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift) | 9107 | 主 TabBar + 全部主界面视图（60+ 个 View，详见 §5）+ 底部 SJZ 图片组件族 + AppIconManager/AppIconSettingsView |
| [SplashView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/SplashView.swift) | 125 | 启动过渡页（与 LaunchScreen 视觉一致） |

### 2.2 服务与管理模块

| 文件 | 行数 | 职责 |
|------|------|------|
| [Models.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/Models.swift) | 951 | 全部业务模型 + 13 组 `default*` 静态兜底数据 |
| [NetworkService.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NetworkService.swift) | 1565 | 网络层：请求封装、重试、DTO 体系（60+ 嵌套类型）、机构树/子站索引/校长信箱/党建指纹等接口 |
| [DataService.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DataService.swift) | 1246 | 数据管理：同步、缓存、文章详情解析、招生网/专业数据（旧数据域） |
| [LogManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/LogManager.swift) | 351 | 日志系统：分级、轮转、导出、崩溃捕获 |
| [SJZNetworkMonitor.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/SJZNetworkMonitor.swift) | 562 | **※新**：网络监测中枢——链路感知、全 App 流量统计、延迟聚合、一键网络诊断（零侵入，经 URLProtocol 埋点） |
| [CacheModeManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CacheModeManager.swift) | 455 | 缓存模式（即时刷新/缓存模式）+ 命中率统计 |
| [DisplaySettingsManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DisplaySettingsManager.swift) | 1785 | 外观/主题/字体/亮度/锁定的既有域 + **文章文字颜色** + **阅读统计**（枚举/状态/计算器/缓存/服务/渲染组件共居此文件底部） |
| [BiometricSecurityManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BiometricSecurityManager.swift) | 524 | Face/Touch/Optic ID 锁定状态机 + Keychain 启用令牌 |
| [HomeModuleManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HomeModuleManager.swift) | 356 | 首页 **12 个**内容模块显隐与排序（2026-09-24：校园风光/合作交流退役、招生卡由使用帮助 helpGuide 取代） |
| [NotificationManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NotificationManager.swift) | 1067 | 本地推送 + **四通道官网轮询**（新闻/校长信箱/学校概况/党建专题）+ 收藏更新第五通道（BookmarkManager）+ 五类 DeepLink + 通知测试 |
| [BookmarkManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BookmarkManager.swift) | 424 | 收藏管理 + 正文/图片两级缓存 + 收藏更新通知（第五通道） |
| [AnnouncementManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/AnnouncementManager.swift) | 338 | 公告拉取/解析/开启判定 |
| [OrganizationManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationManager.swift) | 728 | 机构数据管理 + site_key 四级匹配 |
| [PrivacyManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyManager.swift) | 449 | 隐私协议文档管理（三级降级） |
| [ReadStatusManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/ReadStatusManager.swift) | 70 | 文章已读/未读状态 |
| [RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift) | 218 | 自定义 URLProtocol：防盗链 Referer 注入 + 图片 7 天缓存头 + 网络监测台账埋点 |
| [Scripts/generate_alternate_icons.py](file:///Users/qinchao/Downloads/designcode-swiftui/qin/Scripts/generate_alternate_icons.py) | 340 | （非编译资源）备选图标生成脚本：HSV 分类重着色、参数化 4 套 palette、全套尺寸输出 |

### 2.3 独立视图模块（业务视图文件）

| 文件 | 行数 | 职责 |
|------|------|------|
| [OrganizationDetailView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationDetailView.swift) | 5268 | 机构详情页（区块渲染、文章列表/详情、专业介绍、分数线、独立详情缓存）+ 双 WebView 正文 CSS 注入 |
| [OrganizationView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationView.swift) | 2182 | 机构设置页（5 分类卡片 + **机构子站全栏目深度文章搜索**，※2026-09-23 重构） |
| [PrincipalMailboxView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrincipalMailboxView.swift) | 1768 | **※新**：校长信箱模块（Store + 主视图 + 信件详情 + Sheet 根容器） |
| [SchoolProfileView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/SchoolProfileView.swift) | 3482 | **※新**：学校概况模块（七板块 + 合作交流三组全景图文画廊 + 全文搜索 + 滚动追踪器 + 内联视频 + 数字滚动动画） |
| [PartySubjectView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PartySubjectView.swift) | 1597 | **※新**：党建专题模块（党建工作 djgz / 思政专题 mkszy 双子站聚合 + 加权搜索） |
| [MessageCenterStore.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/MessageCenterStore.swift) | 823 | **※新**：消息中心数据中枢（五通道消息盒、幂等 ingest、损坏自愈存储、双层角标联动） |
| [MessageCenterView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/MessageCenterView.swift) | 924 | **※新**：消息中心页面（日分组列表、滑动手势、搜索高亮、深链详情卡、诊断修复面板） |
| [HelpContent.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HelpContent.swift) | 587 | **※新**：使用帮助内置内容（5 分类 32 篇指南，三级结构 HelpCategory/HelpArticle/HelpStep） |
| [HelpGuideStore.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HelpGuideStore.swift) | 239 | **※新**：使用帮助数据中枢（多词 AND 加权搜索、已读/最近阅读、本地内容直读） |
| [HelpGuideView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HelpGuideView.swift) | 1549 | **※新**：使用帮助主页面 + 详情页（本地内容零网络、关键词高亮、学习进度环） |
| [CampusCalendarStore.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CampusCalendarStore.swift) | 478 | **※新**：校园日历数据中枢（官网校园日历栏目、本地缓存优先、多词 AND 搜索、详情缓存已读） |
| [CampusCalendarView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CampusCalendarView.swift) | 1484 | **※新**：校园日历列表页（渐变 Hero/搜索/图标化卡片/刷新三态）+ 校历详情页（大图主打、长按保存/分享、复制全文、查看原文） |
| [DisplaySettingsView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DisplaySettingsView.swift) | 1090 | 显示设置页（外观/排版/**文章文字颜色**/**阅读统计**/屏幕/自动锁定/辅助功能） |
| [NetworkMonitorView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NetworkMonitorView.swift) | 779 | **※新**：网络监测页（链路/吞吐/延迟/会话统计/一键诊断/Chart 图表） |
| [PrivacyPolicyView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyPolicyView.swift) | 792 | 隐私协议主页/文档详情/首次同意弹窗/受限模式 |
| [CacheModeSettingsView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CacheModeSettingsView.swift) | 600 | 缓存模式设置页（模式选择、统计、流量、管理） |
| [BookmarkListView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BookmarkListView.swift) | 513 | 收藏列表（搜索、批量删除、缩略图） |
| [NotificationTestView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NotificationTestView.swift) | 501 | 通知测试页（发测试通知、模拟点击、角标管理、DeepLink 结果闭环） |
| [LogListView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/LogListView.swift) | 393 | 日志查看页（分级筛选、搜索、导出、清空，受生物锁保护） |
| [PrivacyLegalTexts.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyLegalTexts.swift) | 265 | 用户协议与隐私政策的离线兜底全文 |
| [AnnouncementDetailView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/AnnouncementDetailView.swift) | 226 | 公告详情页（Banner + 正文 + 数据来源指示 + 阅读统计） |
| [BiometricSettingsView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BiometricSettingsView.swift) | 168 | Face ID 解锁设置页（开关/策略/能力状态/引导） |
| [BiometricLockOverlayView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BiometricLockOverlayView.swift) | 137 | 全屏安全遮罩 + `.biometricLockProtected()` 敏感页修饰器 |
| [HomeModuleSettingsView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HomeModuleSettingsView.swift) | 146 | 首页模块管理页（开关、拖拽排序、恢复默认，覆盖 12 模块） |
| [LogSettingsView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/LogSettingsView.swift) | 86 | 日志设置页（DEBUG 开关、容量上限、存储信息） |

### 2.4 测试

| 文件 | 行数 | 职责 |
|------|------|------|
| [MessageCenterStoreTests.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCodeTests/MessageCenterStoreTests.swift) | 432 | 三个测试类共 **32 用例**：① `MessageCenterStoreTests` 24 例（ingest 新增/去重/测试排除、FIFO 截断、存储损坏自愈与逐条抢救、markRead 幂等、清空两 scope、相对时间/日分组、深链持久化）；② `HomeModuleManagerTests` 5 例（显隐幂等、排序保全集、恢复默认、helpGuide 联动）；③ `CampusCalendarStoreTests` 3 例（官网时间格式解析/兜底空值/搜索历史去重置顶 ≤10） |
| [NetworkServiceDTOTests.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCodeTests/NetworkServiceDTOTests.swift) | 650 | 两个测试类共 **22 用例**：DTO 解码回归（`NetworkServiceDTOTests` 11 例：真实 API + 缺字段/新旧格式/混合类型容错）+ 阅读统计算法与链路（`ReadingStatsCalculatorTests` 11 例：中文/英文/混排/标点/Markdown/空文本/10 万字性能/格式化/图片递减/服务集成/开关联动） |

> 测试总数 **54 例 / 54 全绿**（真机，2026-09-24）。工程惯例：**不新增在线用例**——在线测试硬编码官网标题/ID/阈值，官网内容年度替换必断；新模块覆盖依赖日志闭环 + 本地纯逻辑用例 + 手动验收。新 Store 用例追加在既有测试文件内（避免 pbxproj 注册）。

---

## 3. 应用入口与启动流程

### 3.1 DesignCodeApp（[DesignCodeApp.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DesignCodeApp.swift)）

`@main struct DesignCodeApp: App`，`WindowGroup` 内以 `ZStack` 分层编排 5 个视图层级：

| 层级 | 视图 | 触发条件 |
|------|------|---------|
| zIndex 0 | `MainTabView()` | 常驻，`isAppReady` 前 opacity 0 |
| zIndex 1 | `SplashView` | `!isAppReady` |
| zIndex 2 | `PrivacyConsentView` | 首次启动 / 受限模式重新弹 |
| zIndex 3 | `RestrictedModeView` | 用户拒绝隐私协议 |
| zIndex 4 | `BiometricLockOverlayView` | 生物识别已启用且处于 locked/authenticating |

**关键行为**：

- `init()`（L21-L37）：
  1. **F1 前置扩容 `URLCache.shared`**（内存 80MB / 磁盘 400MB，`diskPath: "sxjzit_shared_cache"`）——协议层会话、统一图片组件、AsyncImage 共享此缓存；
  2. `URLProtocol.registerClass(RefererHeaderURLProtocol.self)`；
  3. **E9 内存警告降载**：`CacheModeManager.shared.registerMemoryWarningHandler()`；
  4. **App 图标启动校准** `AppIconManager.shared.calibrateOnLaunch()`（以系统实际生效图标修正本地记录）；
  5. 启动日志（含版本与 urlCache 配置）。
- `.task`：sleep 1s → `isAppReady = true`（等待启动动画自然完成，非人为延时）。
- `.onChange(of: isAppReady)`：按隐私状态分流 —— 已同意 → 正常；未同意未拒绝 → 0.5s 后弹隐私同意；曾拒绝 → 0.5s 后直接进受限模式。
- `.onChange(of: scenePhase)`：`.background` → `handleDidEnterBackground()`；`.active` → `handleReturnToForeground()`（生物锁）。
- `.task(id: isAppReady)`：刷新通知授权状态；已同意且有权限则 `startPolling()`。
- 根节点级配置：`.tint(displaySettings.themeStyle.color)` + `.displayTypography(displaySettings)`。
- 拒绝隐私协议时：停止通知轮询，0.35s 后进入受限模式。

### 3.2 MainTabView（[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L15-L363)）

经典 `.tabItem` 5 标签页（刻意规避 iOS 26 Liquid Glass `Tab(value:role:)` 造成的卡顿）：

| Tag | 标签 | 视图 | 图标 |
|-----|------|------|------|
| 0 | 首页 | `HomeView(selection:)` | house.fill |
| 1 | 院系 | `DepartmentsView()` | building.2.fill |
| 2 | 资讯 | `NewsListView()` | newspaper.fill |
| 3 | 校园 | `CampusView()` | map.fill |
| 4 | 我的 | `ProfileView()` | person.fill |

**特性**：

- 每 Tab 独立 `NavigationStack`；
- Tab 切换触发轻触觉反馈 + 日志埋点；
- `.task`：启动 0.5s 后 `data.syncIfNeeded()`；
- 内置 Debug 面板（右上角蚂蚁图标触发，展示 news/honors/数据源/syncLog）；
- **五类通知/消息 DeepLink 消费**（`consumePendingDeepLink` + `scheduleNotificationArticlePresentation`，见 §8 链路③）：文章（`pendingDeepLink` → sheet 详情）、校长信箱（`pendingMailboxDeepLink` → `MailboxSheetRoot` 直达信件详情）、学校概况（`pendingSchoolProfileDeepLink` → SchoolProfileView sheet）、党建专题（`pendingPartySubjectDeepLink` → 完整 PartySubjectView sheet）、消息中心（`pendingMessageCenterDeepLink` → 直达消息详情卡）；均等待场景 active + Face ID 解锁完成后让出 runloop（延迟 350ms）再弹，弹窗结果回写 `deepLinkOutcome` 供通知测试页闭环；
- `.preferredColorScheme` 由 `colorSchemePreference`（复用 `DisplaySettingsManager` 同一存储键）驱动。

---

## 4. 核心服务层（Manager/Service/Store）

### 4.1 DataService — 数据枢纽（[DataService.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DataService.swift)）

**类型**：`@MainActor final class DataService: ObservableObject` 单例。

**范围**：聚合旧数据域（首页/招生/专业/院系/文章详情）。2026-09-23 新增的校长信箱、党建专题、学校概况三模块**不经过本类**，由各自 Store 直连 NetworkService。

**发布状态**：

- 同步状态：`isLoading` / `lastError` / `syncErrors` / `syncWarnings` / `dataSource`（“预置数据/缓存/服务器”）/ `syncLog`
- 基础数据：`banners` / `bottomBanners` / `stats` / `honors` / `departments` / `news` / `videos` / `studentStories` / `teacherProfiles` / `campusActivities` / `campusSceneries` / `services` / `facilities` / `timeline`
- 分类新闻（8 列）：`importantNews` / `updateNews` / `partyNews` / `notices` / `admissionNews` / `campusNews` / `researchReports` / `informationNews`
- 站点信息：`siteInfo` / `recruitPhones` / `footerLinks` / `socialPlatforms`
- 招生网/专业介绍：`zswHomeData` / `zswIsLoading` / `specialtyData` / `specialtyIsLoading`

**关键方法**：

| 方法 | 说明 |
|------|------|
| `syncIfNeeded(force:)` | 同步入口：常规 10s 冷却 + **缓存模式下距上次同步 <10 分钟直接短路**（不触网秒开）；`force: true` 绕过 |
| `doFullSync()` | 完整同步（并行 home2+head+foot → 各栏目分页 → 视频/故事/教师/活动/风光 → 院系合并 → OrganizationManager.updateSiteKeys → 落缓存 → 后台加载招生网/专业）；永不抛异常，逐接口 do-catch |
| `loadZSWHomeData()` / `loadSpecialtyData()` | 招生网 / 专业介绍独立加载（可重试） |
| `loadArticleDetail(articleId:)` / `loadArticleFullDetail(articleId:)` | 文章详情（HTML 解析 → 纯文本/图片提取/URL 编码） |
| `loadZSWArticleFullDetail(articleId:siteId:)` | 招生网文章详情（siteId 默认 `cb3b1fe4fcdf40999b0c162015c3326d`） |
| `preloadArticleDetail(articleId:)` | 详情预加载（通知点击时并行秒开） |
| `clearArticleDetailCache()` / `clearCache()` | 清内存/磁盘缓存并恢复默认数据 |
| `refreshCacheLimits()` | 按 CacheMode 切换 NSCache 限额（cache 模式 200 条/80MB，即时模式 50 条/20MB），由 CacheModeManager 联动调用 |

**文章详情内存缓存**：`NSCache<NSString, ArticleDetailCacheEntry>`（含 `fetchTime`），ZSW 详情用 `zsw_` 前缀键。

### 4.2 NetworkService — 网络层（[NetworkService.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NetworkService.swift)）

**类型**：`final class NetworkService: @unchecked Sendable` 单例。

**配置**（`NetworkConfig` L10）：基地址 `https://gwqietap.sxjzit.edu.cn/mapi`、请求超时 15s、资源超时 30s、缓存策略 `reloadIgnoringLocalAndRemoteCacheData`。

**核心方法（全量清单，GET）**：

| 方法 | 端点 | 用途 |
|------|------|------|
| `get(_:params:as:)` | 任意 | 唯一通用 GET 封装（2 次重试、指数退避 500ms×N；**URLError.cancelled 不重试、不记 ERROR、仅 debug 日志，立即传播**） |
| `fetchHome2()` | `/school/home2` | 首页全量 |
| `fetchHead()` | `/common/column/head` | 站点 + 导航菜单 |
| `fetchFoot()` | `/common/foot` | 底部信息 + 友情链接 |
| `fetchArticles(columnId:siteId:page:size:)` | `/common/column/articles` | 文章分页（默认 siteId "1"；机构子站/党建子站均复用此接口） |
| `fetchArticleDetail(articleId:siteId:useCache:)` | `/common/article/detail` | 文章详情（单文章型机构介绍文亦用此接口） |
| `fetchArticleDetailWithHref(_:)` | 文章 href | 非标准 JSON→HTML 兜底解析 |
| `fetchJSONDict(path:params:)` | 任意 | **※新**：动态形态 JSON 原样返回字典（`/school/intro` 学校概况等无稳定 DTO 的接口） |
| `fetchZSWHome2()` | `/dept/home2?site_key=zsw` | 招生网首页 |
| `fetchZSWArticlePage(siteId:columnId:pageNo:pageSize:)` | `/common/article/page` | 招生网文章分页（pageNo/pageSize 参数） |
| `fetchZSWArticleDetail(articleId:siteId:)` | `/common/article/detail` | 招生网文章详情 |
| `fetchSpecialtyData(siteId:columnId:)` | `/common/column/oneTwoArticles` | 专业介绍 |
| `fetchDeptHome2(siteKey:)` | `/dept/home2` | 机构部门首页 |
| `fetchSchoolOrgTree()` | **※新** `/school/org` | 官网权威机构树（departments/list 页面数据源）：递归解析叶子机构节点——三形态：子站型（site_key）/ 单文章型（article_id）/ 外链型；**运行时解析，严禁硬编码** |
| `fetchDeptSiteIndex(siteKey:)` | **※新** `/dept/home2` | 机构子站栏目索引：递归解析 nav 收集 (site_id, [DeptColumnRef])；**双通道**——标准栏目取 column_id，内容页/子 tab 节点取 id（可直接查询其文章）；跳过 `articles` 子树（文章 ID 非栏目 ID）；排除纯文章 dict |
| `fetchPrincipalMailbox(page:size:)` | **※新** `/school/msg` | 校长信箱公开回复分页 |
| `fetchMessageDetail(msgId:)` | **※新** `/common/msg/detail` | 信件详情 |

**私有工具**：`getRaw` / `getRawData`（原始数据）、`parseImages` / `extractImagesFromHTML`（图片提取，过滤 `file://`）、`safeImageURL(from:)`（相对路径转绝对 + 非 ASCII 编码）、`buildURL`、`validate`（HTTP 状态/空数据校验）。

**DTO 体系小结**（全部字段 Optional + 显式 CodingKeys，防 null 崩溃，均嵌套于 NetworkService 内）：

- 基础：`APIResponse<T>`（`requireData()` 空 data 抛错）、`ArticleDTO`、`ArticleDetailDTO`、`ImageDTO`、`NewsDetailDTO`、`ArticleListDTO`、`ColumnDTO`、`BannerDTO`、`NewsChildrenDTO`、`NewsColumnDTO`、`Home2DTO`、`VideoBlockDTO`（自定义 encode）、`AnyCodable`、`CampusBlockDTO`、`CampusChildrenDTO`、`SiteDTO`、`MenuDTO`、`HeadDTO`、`FootDTO`、`FootLinkListDTO`/`FootLinkDTO`、`FootPlatformListDTO`/`FootPlatformDTO`；
- 招生/专业：`ZSWHome2DTO`（含嵌套 `ZSWSiteDTO`/`ZSWNavDTO`/`ZSWNavDataDTO`/`ZSWSectionDTO`/`ZSWGuideDTO`/`ZSWChildrenDTO`/`ZSWChildDTO`/`ZSWArticlesDTO`/`ZSWArticleDTO`）、`ZSWArticlePageDTO`、`SpecialtyColumnDTO`/`SpecialtyChildrenDTO`/`SpecialtyCollegeDTO`/`SpecialtyArticlesDTO`/`SpecialtyMajorDTO`；
- 机构：`DeptHome2DTO`/`DeptBannerDTO`/`DeptNavItemDTO`（`DynamicCodingKeys` 跳过混合类型数据字典）/`DeptSectionDTO`/`DeptChildrenDTO`/`DeptChildDTO`/`DeptArticleListDTO`/`DeptArticleDTO`；
- **※新机构搜索**：`DeptColumnRef`（id/title，Codable 支持本地缓存）、`SchoolOrgNode`（name/siteKey/articleId/siteId）；
- **※新校长信箱**：`MailboxMessage`（id/title/showTitle/messageTime + dateText 派生）、`MailboxPageData`（双层 data 嵌套解析）、`MailboxMessageDetail`（信件详情 + 回复列表）；
- `ArticleFullDetail`、`MailboxPageData`/`MailboxMessageDetail` 等业务侧引用需 `NetworkService.xxx` 限定（或文件级 internal typealias）。

**错误处理**（`NetworkError` L19-L40，7 个 case，中文 `errorDescription`）：`badURL` / `badResponse(Int)` / `decodeFailed` / `timeout` / `noData` / `dataMissing` / `serverError`。

### 4.3 LogManager — 日志系统（[LogManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/LogManager.swift)）

**类型**：`@MainActor final class LogManager: ObservableObject` 单例。

- **级别**（`LogLevel`）：`info` / `debugLog` / `warning` / `error` / `fatal`，每级独立颜色标签。
- **入口方法**：`info(_:_:context:)`、`debugLog`、`warning`、`error`、`fatal`；`search(query:in:)` 全文搜索；`clearAll()`；`exportAsText()` 导出 txt。
- **存储**：内存 `entries: [LogEntry]`（最新在前）；磁盘 `Documents/SXJZIT_Cache/Logs/log_YYYY-MM-DD.json` 按日轮转。
- **容量**：默认 3000 条，可选 1000/3000/5000/10000；FIFO 淘汰；0.5s 防抖异步写入；7 天自动清理。
- **崩溃捕获**：`NSSetUncaughtExceptionHandler` + 信号捕获（SIGABRT/SIGILL/SIGSEGV/SIGFPE/SIGBUS/SIGTRAP），崩溃时同步写盘。
- **日志模块标识一览**（2026-09-23 现状）：`ui` / `network` / `cache` / `imageCache` / `bookmark` / `notification` / `announcement` / `org` / `privacy` / `biometric` / `display` / `appicon` / `home` / `party` / `profile` / `mailbox` / `netmon` / `sync` 等，覆盖全部交互链路。

### 4.4 SJZNetworkMonitor — 网络监测中枢（※新，[SJZNetworkMonitor.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/SJZNetworkMonitor.swift)）

**类型**：`final class SJZNetworkMonitor: ObservableObject` 单例（主线程）+ 私有 `NetworkMonitorLedger`（线程安全台账）。**会话级数据，不持久化。**

- **零侵入埋点**：`RefererHeaderURLProtocol` 在每个请求生命周期调用 `tapRequestStart / tapData / tapComplete / tapAbandon`；cancelled 请求走 abandon 不计失败、协议层观测的失败落 warning、延迟 ≥1s 记「慢请求告警」。
- **链路感知**：`NWPathMonitor` → 中文链路状态（已连接/无网络/等待连接/未知）+ 接口类型（WiFi/蜂窝）+ 昂贵网络/低数据模式徽章。
- **聚合**：1 秒桶 → 最近 2 分钟 **120 点环形缓冲** `samples: [NetworkTrafficSample]`（吞吐/延迟/请求数）；每 30 点周期输出吞吐统计日志。
- **会话统计**：总请求、成功率、总流量、平均延迟、延迟四档直方图（<200ms / 200-500 / 500-1000 / ≥1000）。
- **一键诊断**（`runProbe()`，`probeIsRunning` 防连点重入）：对 `https://gwqietap.sxjzit.edu.cn/mapi/common/column/head` **5 轮**探测 → `ProbeState`（idle → running(progress) → done/failed）→ `ProbeResult`：RTT P50/P90/最快/最慢、丢包率、**DNS/TCP/TLS/首字节分阶段耗时中位数**；全部超时 → 失败提示。
- 日志模块 `netmon`：初始化/链路变化/周期聚合/慢请求/诊断全程。

### 4.5 CacheModeManager — 缓存模式（[CacheModeManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CacheModeManager.swift)）

**类型**：`@MainActor` 单例。

- `CacheMode`：`instant`（即时刷新，默认）/ `cached`（缓存模式，省流量秒开）。
- **无图模式**（`imageFreeModeEnabled`，键 `cacheImageFreeMode`）：全局跳过静态图片加载渲染占位（视频不受影响），跳过计数 `cacheImageFreeSkippedCount` 跨会话持久化；消费点：SJZCachedImage（TabBar L7512/L7541/L7564，经 `SJZImageKit.isImageFreeModeFromAnyThread` 直读镜像）、缓存设置页开关、网络监测页缓存联动卡。
- **线程安全镜像** `CacheModeMirror`（NSLock 保护的 cacheEnabled/imageFreeEnabled 两把开关）：@MainActor 单例禁止后台线程直读，模式变化时同步写镜像，供 URLProtocol 回调、图片组件等任意线程读取（`isCacheEnabledFromAnyThread`/`isImageFreeModeFromAnyThread`）。
- 切换 `mode` 时全局联动：`DataService.refreshCacheLimits()` + `SJZDecodedImageCache.refreshLimits()`。
- **缓存模式下的三处行为切换**：① `DataService.syncIfNeeded` 距上次同步 <10 分钟直接短路；② `SJZImageKit.makeRequest` 图片请求转 `returnCacheDataElseLoad`；③ `RefererHeaderURLProtocol` 同步采用缓存优先策略。`isCacheEnabledFromAnyThread` 非隔离直读快照供任意线程判定。
- **内存警告降载**：`registerMemoryWarningHandler()`（App init 调用）监听内存警告清解码缓存。
- **统计**：命中/未命中数、图片命中/未命中、节省流量字节、会话起始，全部持久化；`CacheStatsSnapshot`：命中率、效率评级、格式化内存；`resetStats()` / `resetAll()`。

### 4.6 DisplaySettingsManager — 显示设置（[DisplaySettingsManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DisplaySettingsManager.swift)）

**类型**：`@MainActor` 单例。所有设置 `didSet` 即持久化 + 日志 + 全局实时生效。

| 设置 | 枚举/类型 | 说明 |
|------|-----------|------|
| `appearanceMode` | system/light/dark | 复用旧键 `colorSchemePreference`，与 MainTabView 联动 |
| `themeStyle` | blue/red/green/orange/purple | 5 种深浅自适应品牌色，注入根 `.tint` |
| `fontSizeTier` | tiny~max 6 档 | 缩放系数 0.85~1.40，「中」档不覆盖系统 Dynamic Type |
| `boldTextEnabled` / `useSystemFont` / `fontFamily` | Bool / system,songti,kaiti,yuanti,xingkai,libian,weibei | 粗体与 7 款中文全字形字体家族（书法字体为系统按需下载，见 §4.6 字面名契约与下载状态机） |
| `lineSpacingFactor` / `letterSpacingValue` | 0.9~1.5 / 0~2pt | 行距与字间距 |
| `buttonShapesEnabled` | Bool | 未显式指定样式的按钮加胶囊边框 |
| `brightnessValue` / `autoBrightnessEnabled` | Double / Bool | UIKit 桥接屏幕亮度（scene 安全获取 `UIScreen`），接管/交还系统 |
| `autoLockOption` | 30s~15m/never | 通过 `isIdleTimerDisabled` 真实生效 |
| `articleTextColorPreset` / `articleTextCustomHex` | system+7 预设+custom / 6 位 hex | 文章正文文字颜色（§4.15），命中/未命中键直读快照供非主线程渲染 |
| `readingStatsEnabled` / `readingCharCountEnabled` / `readingTimeEnabled` / `readingListBadgeEnabled` | Bool × 4 | 阅读统计总开关与细项开关（§4.16），默认全开 |
| `readingSpeedTier` | slow/standard/fast | 阅读速度档位：中文 200/300/450 字/分，英文 150/220/300 词/分 |

**字体按需下载机制（2026-09-27 根治版）**：

- **字面名契约**：`DisplayFontFamily.fontName` 必须是 **PostScript 字面名**——`STSongti-SC-Regular` / `STKaitiSC-Regular` / `STYuanti-SC-Regular` / `STXingkaiSC-Light` / `STLibianSC-Regular` / `WeibeiSC-Bold`（苹方 `PingFang SC` 恒内置）；`boldFontName` 为家族真实粗体字面（宋/楷/圆/行楷有，隶变/魏碑无独立字面）。**系统匹配引擎只认字面名**——历史误用家族名（如 `"Songti SC"`）会 `didBegin → didFinish` 静默完成且零资产（真机 A/B 实证，表现为界面永远停在「下载中」）。
- **状态机**：`DisplayFontAvailability`（`ready` / `downloading(percent:)` / `unavailable`）＋令牌制防重入（`fontDownloadTokens`）＋**无进展看门狗**（每 5s 轮询，以「最近一次系统进度回调」为基准，连续 60s 无进度才复位为可重试——大字体慢网可远超 60s 总时长）。
- **终态一律实查自愈**：`finalizeFontDownload`（finished / failed / stalled 三路）以 `UIFont(name:)` 实查判定成败，迟到落地也自愈为就绪并 `typographyRevision += 1` 驱动全 App 字体重算。
- **粗体字面**：开启「粗体文本」时把家族真实粗体字面并入**同一次**匹配调用（合并进度）；`DisplayFontFactory` 优先用真实粗体字面（无则回退主字面合成加粗）；`boldTextEnabled.didSet` 触发 `bold_toggle` 预热。
- **UI**：画廊三态徽章（进度环百分比 / 不确定转圈 / 橙色可重试箭头）+「全部下载」批量入口（`ensureAllFontFamilies`，带体积确认弹窗）。实测资产体积：行楷-简 54.7MB、隶变-简 21.6MB、魏碑-简 17.4MB。
- **埋点全链**：`字体按需下载开始（faces/includeBold/reason）→ 字体资产开始下载（localizedFamily/字节数）→ 字体下载进度（每 25% 分档：百分比/字节/ETA）→ 字体资产传输完成 → 字体字面匹配成功 → 字体按需下载完成并已全局生效（revision/boldFaceReady）`；失败/停滞为 `warning`（含诊断描述）与 `INFO` 状态流转。

**显示设置全链覆盖（2026-09-27 全库审计固化，构建期强制）**：

| 设置 | 生效机制 | 覆盖面（审计结论） |
|------|---------|------------------|
| 字号档位 / 字体家族 / 粗体 / 字距 / 行距 | 自定义 EnvironmentKey + `display*` 修饰器（环境值，自动穿透弹出层） | **全库 0 处原始字体**：137 处文本 + 17 处 Label + 124 处图标已全部接入（图标一律 `displaySymbolFont` 随档位缩放；图表 `AxisValueLabel` 为 ChartContent，经 `DisplayFontFactory.font` 构造 Font 注入） |
| 外观模式（浅/深/跟随） | `preferredColorScheme`（呈现修饰器，**不跨 presentation**） | 根部（MainTabView）+ 全部 59 处 sheet/fullScreenCover 经 `sjzPresentationChrome()` 注入 |
| 专注灰度 | `.saturation`（渲染修饰器，**不跨 presentation**） | 同上（与外观合并为统一 chrome 修饰器，一处挂载双效） |
| 主题色 | 根 `.tint`（环境值） | 全 App 自动穿透（含弹出层） |
| 按钮形状 | `.buttonStyle`（环境值） | 全 App 自动穿透（含弹出层） |
| 正文文字颜色 | 渲染点三路 | 主文章纯文本（`foregroundStyle(articleBodyColor)`）+ 机构子站原文 WebView（明暗双 hex 注入 CSS 变量）+ 长图分享渲染（非主线程快照 hex） |
| 原文页排版（WebView） | CSS 注入 | 机构子站两处模板：字体栈/字号（16px × 档位）/行高（0.85+行距系数）/字距/粗细全部联动显示设置；标题改 em 随基准缩放；构建日志「机构文章网页原文配色与排版注入」 |
| 阅读统计 | 计算器 + 展示组件 | 详情页 `ArticleReadingStatsText`（10 处）+ 列表徽标 `ReadingTimeBadgeView`（6 处：要闻/校园动态/招生/机构搜索/党建/收藏）；学校概况板块属图片/品牌/相册卡（不适用）；子开关（字数/时长/列表徽标）与速度档位全链消费 |
| 亮度 / 自动锁定 / 屏幕常亮 | UIKit 全局 | `UIScreen.brightness` / `isIdleTimerDisabled`（与全局状态无关的渲染点不存在） |

- **防回归护栏**：`Scripts/display_coverage_guard.py` 接入 Xcode Run Script 构建阶段（详见 §11.2）——新增功能若绕过排版链或漏挂弹出层呈现链，**构建直接失败**并给出修复指引与例外登记入口。

**系统无障碍监听**：@objc selector 监听 reduceMotion/reduceTransparency/darkerColors 变化通知。

**全局注入机制**：自定义 `EnvironmentKey` × 5 + `DisplayTypographyModifier`；视图 API `displayText(size:weight:baseLineSpacing:)`、`displayFont`、`displaySymbolFont`（图标仅缩放不换字体）、`displayLabelFont`；`DisplayFontFactory.font(...)` 组装最终字体。

### 4.7 BiometricSecurityManager — 生物识别安全（[BiometricSecurityManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BiometricSecurityManager.swift)）

- **状态机**（`LockState`）：`inactive` → `locked` → `authenticating` → `unlocked`。
- **锁定三触发**：冷启动（启用即 locked）、后台返回（`BiometricLockPolicy`：immediate/1min/5min，含 Face ID 对话框关闭误判保护）、敏感页面进入（`.biometricLockProtected()`）。
- **能力探测**：Face ID / Touch ID / Optic ID / 降级路径（模拟器/未录入/不支持/未设密码，分类中文提示）。
- **认证降级链**：生物识别 → 连续失败 5 次自动转 deviceOwnerAuthentication（设备密码）→ `biometryLockout` 或 `userFallback` 时转密码；密码成功后系统自动重置生物识别锁定。
- **持久化分工**：UserDefaults 存 `isEnabled` / `lockPolicy`（非敏感）；Keychain 存启用令牌（`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`）。
- **关键方法**：`handleReturnToForeground()` / `handleDidEnterBackground()` / `requestLock(reason:)` / `authenticate(reason:)` / `enableWithGuidedFlow()` / `disableWithConfirmation()` / `refreshCapability()` / `openSystemSettings()`。
- `isLockEngaged`：锁定保护期间为 true，供通知弹窗调度、遮罩判定使用。

### 4.8 HomeModuleManager — 首页模块管理（[HomeModuleManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HomeModuleManager.swift)）

**类型**：单例（@MainActor，2026-09-24）。管理首页 **12 个内容模块**的显隐与排序（Banner/统计/快捷入口/帮助锚点卡为固定品牌区块，不参与管理）。

- `HomeModule` 12 例（2026-09-24 终版）：importantNews（要闻）· honors（荣誉）· notices（公告）· **helpGuide（使用帮助，原招生卡 admissionNews 升级迁移）** · teacherProfiles（教师）· videos（映像）· studentStories（故事）· campusActivities（活动）· timeline（历程）· principalMailbox（校长信箱）· partySubject（党建专题）· schoolProfile（学校概况）。**已退役**：campusSceneries（校园风光）/ bottomBanners（合作交流）——数据链早已断裂、内容完整承载于学校概况模块，退役值时自动静默清理（`retiredRawValues` 静态集）。
- 每例含标题/图标/主题色/单位（条/封/篇/项）/实时数据量：旧模块读 DataService；新模块懒加载读各自 Store。
- 常显入口型模块（校长信箱/党建专题/学校概况，`hasContent` 恒 true）**从首页骨架屏条件中排除**（否则冷启动骨架屏永不显示）。
- `moduleOrder` + `hiddenModules` 双状态持久化（`homeModuleOrder` / `homeModuleHidden`）；旧键自动迁移（admissionNews→helpGuide 隐藏/顺序双通道迁移并立即落盘）；非法值过滤、新模块自动补末尾。
- 方法：`isVisible(_:)`、`visibleOrderedModules`、`setVisible(_:_:)`、`moveModules(from:to:)`、`resetToDefaults()`、`isDefault`。日志域 `home_modules`。

### 4.9 NotificationManager — 通知系统（[NotificationManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NotificationManager.swift)）

**类型**：`@MainActor final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate` 单例。纯原生 UserNotifications，无第三方 SDK、无 APNs。

- **配置**：`@AppStorage("notificationEnabled")`（开关）、`@AppStorage("notificationPollingMinutes")`（15/30/60/120 分钟，默认 30）。
- **四通道轮询**（`checkForUpdates` L258 → 依次执行，某通道失败不拖垮其他通道）：
  1. `checkNewsUpdates()` L273：fetchHome2 取 4 个栏目 columnId（要闻/资讯/党建/通知）→ `withTaskGroup` 并行拉各栏第一页 → 对比 `notifiedArticleIds`（上限 2000）→ 每次最多 5 条、错开 1 秒发送防轰炸；
  2. `checkMailboxUpdates()` L368：`fetchPrincipalMailbox` 拉第一页 → 对比基线 `mailboxLastKnownTotal` → **首次仅建立基线不推历史**，后续新增信件推送（带 `mailboxId`）；
  3. `checkSchoolProfileUpdates()` L443：`fetchJSONDict("/school/intro")` + `/school/cooperate` → 对比三段基线 `schoolProfileBaseline`（存「领导数|风光数|合作交流条数」；旧两段基线静默升级不误报）→ 变化推送「学校概况·有新内容」（文案精确到变化板块）；
  4. `checkPartySubjectUpdates()`（※2026-09-24）：`fetchPartySubjectFingerprint(siteKey:)` 对 djgz/mkszy 每站 1 次 `/dept/home2` 递归收集指纹（总 total + 最新 3 篇 id|time 签名，**必须按 id 去重**——首页聚合子块与栏目块重复收录同一文章）→ 对比四段基线 `partySubjectBaseline`（`djgzTotal|djgzTop3|mkszyTotal|mkszyTop3`）→ 推送「党建专题·有新内容」。
- **第五通道（独立于 NotificationManager，※2026-09-24）**：`BookmarkManager.checkBookmarkedArticlesForUpdates` + `sendUpdateNotifications`——收藏文章正文指纹比对，更新时推送收藏更新通知（≤3 条），消息中心 `MessageKind.bookmarkUpdate` 对应入盒。
- **五类 DeepLink（点击通知目的地，@Published 驱动）**：
  - `pendingDeepLink: PendingArticleDeepLink?`（文章详情）；
  - `pendingMailboxDeepLink: Int?`（信件 id → 直达 `MailboxSheetRoot` 详情）；
  - `pendingSchoolProfileDeepLink: Bool`（true → 打开 SchoolProfileView sheet）；
  - `pendingPartySubjectDeepLink: Bool`（true → 完整 PartySubjectView sheet）；
  - `pendingMessageCenterDeepLink`（消息中心详情卡直达）。
- **DeepLink 处理**（`handleNotificationTap` L602）：系统回调（完成回调版 delegate，**不可用 async 版**，否则后台队列派发触发主线程断言崩溃）→ 立即 `completionHandler()` → `Task @MainActor` → 设置对应 @Published 状态 → MainTabView.onChange 延迟调度弹 sheet（见 §8 链路③）。
- **通知测试 API**：`sendTestNotification(delaySeconds:useRealArticle:source:)`、`simulateNotificationTap()`（与真实点击同链路）、`sendMailboxSimulationNotification(message:)`、`setBadgeCount(_:)`（双保险：UNUserNotificationCenter + 系统“标记”许可检查）。
- 状态发布：`isAuthorized` / `authorizationDetailText` / `badgeSettingText` / `lastCheckTime` / `isChecking` / `lastCheckError` / `newArticlesFound` / 五类 pendingDeepLink / `deepLinkOutcome`。
- 首次启用可用 `markExistingArticlesAsNotified()` 避免历史洪水。

### 4.10 BookmarkManager — 收藏系统（[BookmarkManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/BookmarkManager.swift)）

- 收藏/取消/切换、批量删除、清空；默认上限 500 条（可配）。
- 正文自动缓存（可选开关）；收藏更新检查（每小时比对最新内容，可推送通知）。
- **图片缓存**：内存 `NSCache`（200 条/50MB）+ 磁盘 `BookmarkImages/*.img`；缓存键 SHA256（CryptoKit），避免 URL 路径冲突。
- 持久化：UserDefaults JSON（`bookmarkedArticles`）。

### 4.11 AnnouncementManager — 公告模块（[AnnouncementManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/AnnouncementManager.swift)）

- 数据源：Docusaurus 页面 `https://www.43322.cn/blog/gonggao`（独立请求，不经过 NetworkService）。
- 判定：标题含“公告开启” → 展示；含“公告关闭”或其他 → 不展示。
- 降级：网络成功 → 本地缓存 → “公告未开启”。
- 刷新：30 分钟定时后台刷新 + 手动刷新；`AnnouncementCache` 落 UserDefaults。

### 4.12 OrganizationManager — 机构模块（[OrganizationManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationManager.swift)）

- 数据三来源：静态预置 5 类机构（党委 8 / 群团 5 / 行政 9 / 教学 10 / 教辅 3，`OrganizationCategory` 枚举）→ head API 菜单提取 `site_key` → **官网权威机构树 `/school/org`（`NetworkService.fetchSchoolOrgTree`）校验机构名与三形态**（子站型/单文章型/外链型）。
- **site_key 四级匹配**：精确匹配 → 模糊匹配（包含关系）→ 近似匹配（“智造/制造”类差异）→ 关键词匹配；命中后落 `organizationCache`。
- 30 分钟自动刷新（`refreshInterval = 1800`）；`syncFromAPI(force:)`、`updateSiteKeys(from:)`、`clearCache()`。

配套视图见 §5.2（OrganizationView 全栏目深度搜索 / OrganizationDetailView 区块渲染）。

### 4.13 PrivacyManager — 隐私管理（[PrivacyManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyManager.swift)）

- 文档类型：`terms`（用户协议）/ `privacy-policy`（隐私政策），均位于 `https://www.43322.cn/blog/*`。
- **三级降级**：网络拉取 → 本地缓存（`privacy_documents_cache_{type}`，30 分钟冷却）→ 内置离线全文（[PrivacyLegalTexts.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyLegalTexts.swift)）。
- `fetchDocument(type:)` 返回 `(PrivacyDocument, PrivacyDocumentSource)`，源标记联网/缓存/离线供 UI 展示。

### 4.14 ReadStatusManager — 已读状态（[ReadStatusManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/ReadStatusManager.swift)）

- 纯本地 UserDefaults（`readArticleIds`，上限 5000）。
- `isRead(_:)` / `markAsRead(_:)`（NewsItem 与 key 双入口）/ `markAllAsRead()` / `unreadCount(in:)`（列表未读蓝点）。

### 4.15 RefererHeaderURLProtocol — 防盗链绕过（[RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift)）

- `canInit`：仅拦截 host 含 `sxjzit.edu.cn` 且未被 `handledKey` 标记的请求（防递归）。
- `startLoading`：注入 `Referer: https://www.sxjzit.edu.cn/` + 浏览器级 `User-Agent`，解决 AVPlayer 播放学校视频防盗链无限加载问题。
- **共享会话**：静态 `sharedSession`（资源超时 120s）复用连接池与 `URLCache.shared`。
- **缓存策略按模式**：缓存模式下图片请求 `.returnCacheDataElseLoad`，即时模式 `.useProtocolCachePolicy`。
- **图片缓存头注入**：对 Content-Type 为 `image/*` 或 URL 扩展名为图片格式（jpg/jpeg/png/gif/webp/bmp/heic/jfif/svg/ico）且服务器未提供缓存头的响应注入 `Cache-Control: public, max-age=604800`（7 天）；服务端 `no-cache`/`max-age=0` 也强制 7 天（`no-store` 除外）；注入日志按 URL 节流仅首见。
- **网络监测埋点**（※新）：请求开始/数据/完成/放弃四事件同步到 `SJZNetworkMonitor` 台账。

### 4.16 文章文字颜色域（[DisplaySettingsManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DisplaySettingsManager.swift) 内，见 §2.2）

`ArticleTextColorPreset`：`system`（跟随系统=保持各页原有语义色）· ink 墨黑 · graphite 石墨 · sepia 暖棕(护眼) · navy 藏蓝 · forest 松绿 · indigo 靛紫 · burgundy 勃艮第 · custom 自定义（ColorPicker + 16 进制输入，实测时校验）。每个预设含**浅色/深色双色值**（`lightHex`/`darkHex`），自定义色单色直用。

| API | 说明 |
|-----|------|
| `articleBodyColor: Color?` | nil=跟随系统；预设 `Color(lightHex:darkHex:)` 明暗自适应；custom 用 `Color(hex:)` |
| `articleCSSTextLightHex/DarkHex` | 双 WebView CSS `--text-color` 注入值 |
| `articleCustomHexNormalized` | 自定义 hex 去杂字符 + 校验 + 非法回退 |
| `articleBodyLightHexSnapshot()` | **nonisolated** 快照（UserDefaults 直读）：长图渲染器等非主线程上下文配色解析 |

渲染接入点：全部详情页正文 + 错误兜底摘要；机构双 WebView（OrganizationArticleWebView / HTMLWebView）`--text-color` 明暗双值注入；长图白底固定浅色值。设置页 `articleTextColorSection`：实时预览段卡 + 3×3 色卡网格（选中打勾/触感反馈/弹簧动画）+ 状态胶囊 + 恢复默认。

### 4.17 阅读统计域（字数 + 阅读时长，见 §2.2 | UI 于 [DisplaySettingsView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/DisplaySettingsView.swift)）

**口径（全程一致）**：口径 A —— 展示位数 = 中文字符数（CJK 五区间）+ 英文词数（字母数字起始，撇号/连字符/下划线仅延续已有词）；表达式：「X 字 · 阅读约 Y 分钟」。

**时长公式**：中文/速度 + 英文/速度 + 图片（首张 12s，逐张 -1s，最低 3s）+ 代码块 30s/个；向上取整；正文非空至少 1 分钟；≥70 分钟转「约 X 小时」；空文本/纯空白/纯标点返回 nil。

| 类型 | 说明 |
|------|------|
| `ReadingStatsCalculator` | 纯函数：`countPlainText`（单趟遍历）、CJK/词边界判定、`calculate(plainText:imageCount:codeBlockCount:速度:)`、`minutes(...)` 分量级折算、`stripMarkdown`（围栏代码块/图片计数）、`stripHTML`（`<img`/`<pre>` 计数）、`formattedCount`/`formattedMinutes` |
| `ReadingStatsCache` | @MainActor 单例：内存 + UserDefaults（`readingStatsCache`，JSON，500 条 FIFO），条目存**原始分量**——速度档位变化只重算分钟不重扫全文 |
| `ReadingStatsService` | 业务入口 `resolve(cachedID:source:)`：缓存命中 → 预处理 → >5 万字符 `Task.detached(.utility)` 后台化 → 写缓存 + `reading` 模块日志 |
| `ArticleReadingStatsText` | 详情页组件：点分隔「2,486 字 · 阅读约 9 分钟」；字数/时长可独立开关；`.task(id:)` 计算；VoiceOver 合并 |
| `ReadingTimeBadgeView` | 列表徽标：**只读缓存**（“⏱ N 分钟”胶囊），无记录不显示、滚动零计算；统一尺寸：8pt 图标、10pt 文本、H5.5/V2 内边距；分层颜色编码（≤4 分钟绿 / 5-9 蓝 / 10-19 橙 / ≥20 紫） |

### 4.18 AppIconManager — 应用图标切换（[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L8681-L8988)）

**类型**：`@MainActor final class AppIconManager: ObservableObject` 单例。封装系统 alternate icon 能力（iOS 10.3+ `UIApplication.setAlternateIconName`）。

| API | 说明 |
|-----|------|
| `availableIcons: [AppIconItem]` | 5 项：默认(nil) + `AppIconAlt1 星夜` / `Alt2 晨曦` / `Alt3 极简` / `Alt4 金典` |
| `supportsAlternateIcons` | 设备能力探测；不支持时选择页置灰 + 说明文案 |
| `activeIconName` | 系统实际生效图标响应式快照（@Published；`refreshFromSystem()` 进页即校准） |
| `setIcon(_:completion:)` | 主线程发起（系统确认弹窗要求）；同值短路；`isSwitching` 防连点；失败不改本地记录（选中态自然回滚）；completion 非主队列 → `Task { @MainActor }` 切回 |
| `calibrateOnLaunch()` | 启动校准：以 `UIApplication.shared.alternateIconName` 为准修正 UserDefaults；在 `DesignCodeApp.init` 调用 |

资源与工程：4 套 `AppIconAlt1~4.appiconset`（各 20 文件，RGB 无 alpha 直角）+ 5 个 `IconPreview*.imageset`；由 [Scripts/generate_alternate_icons.py](file:///Users/qinchao/Downloads/designcode-swiftui/qin/Scripts/generate_alternate_icons.py) 参数化生成；工程侧 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIconAlt1 AppIconAlt2 AppIconAlt3 AppIconAlt4"`。日志模块 `appicon`。**铁律**：仅用户显式操作 + 系统确认弹窗时切换，禁止后台/自动切换。

### 4.19 PrincipalMailboxStore — 校长信箱数据中枢（※新，[PrincipalMailboxView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrincipalMailboxView.swift#L23-L283)）

**类型**：@MainActor 单例。数据接口 `fetchPrincipalMailbox(page:size:)`（`/school/msg`，pageSize=50、maxPages=10 懒加载分页续拉）+ `fetchMessageDetail(msgId:)`（`/common/msg/detail`）。

- **RefreshStatus 状态机**：idle → refreshing → success/failed（与党建/概况模块同一形态）。
- `loadIfNeeded(force:)` 懒加载；`refresh(source:)` 手动刷新必定真实拉取（跳过防重入）；`refreshDetached(source:)` 将刷新本体与下拉手势任务解耦，**URLError.cancelled 识别为「被打断」（debug 日志）而非失败**。
- `performFetch()`：分页收集 `messageList` → 与基线 `mailboxLastKnownTotal`（UserDefaults）比对，记录新增；解析 `noticeText` 使用说明（正则提取电话/邮箱/办公点）。
- `silentLoad(force:)`：首页入口卡数据懒加载（最近一封预览 + 回复计数徽章）。
- `simulateNewMail()`：开发用模拟来信（模拟数据与真实数据分仓存储，防深链目标丢失）。
- 业务交互：拨号/复制邮箱/发邮件/跳官网 `https://www.sxjzit.edu.cn/#/opinion`。
- 日志模块 `mailbox`：拉取开始/成功/失败（含耗时/页数）、页面打开、搜索、历史操作、拨号/复制/发信等完整链路。

### 4.20 SchoolProfileStore — 学校概况数据中枢（※新，[SchoolProfileView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/SchoolProfileView.swift#L140-L636)）

**类型**：@MainActor 单例。七板块聚合：
- 学校简介 `school-introduction`（动态统计数字 `statistics/dynamicDigit`（endNumber 为字符串需兼容解析）、学科竞赛、办学特色）；
- 现任领导 `current-leader`（7 位，头像完整 URL）；
- 识别系统（校徽 `mark_logo`、校名规范图组 + 释义）；
- 学校宣传片 `campus-promotion-video`（advert.mp4 + 海报）；
- 校歌 `school-song`（song.mp4 + 海报）；
- 校园风光（栏目 `214e6c2b` 分页文章 + 图集详情预载）；
- **合作交流**（第七板块）：`/school/cooperate` 三组骨架（国际交流 8 条 / 继续教育 2 条 content 全文内联）；**校企合作（19 条）**走 `/common/column/articles`（columnId `cc7376c3`，size=8 分页 3 页取全，内嵌列表仅 8 条）+ `/common/article/detail` 正文/图集（复用 `fetchSceneryAlbumDetail`：content 提图 + 封面兜底）。`preheatCooperationDetails` 并发 ≤4 预热全部详情 → 详情秒开 + 搜索纳入全文；`cooperateDetails` 缓存 + `cooperatePreheat` 状态供 UI 徽章展示。

- **刷新体系**：`loadIfNeeded` / `refresh(source:)` / `refreshDetached(source:)` + RefreshStatus 状态机（与校长信箱同构，cancelled 不误报）。
- **本地搜索**：七类内容合并且按空格分词 AND 匹配，标题/正文/分类加权打分排序，生成 `ProfileSearchEntry`（校企合作详情预热后正文全文并入 detail）。
- **静态素材**（`SchoolProfileAssets` L65 集中常量）：校徽、校名规范图、视频海报路径带内容哈希（随官网部署变化，需集中维护并定期核对）。
- 日志模块 `profile` + `collaboration`：页面生命周期、板块切换、搜索全流程（聚焦/输入/防抖/提交/历史/空态）、详情打开/加载/重试、分组卡展示、封面全屏、长按保存/分享、预热开始/单项失败/完成、滚动方向（3s 节流）/触底（10s 哨兵节流）、刷新四来源状态机。

### 4.21 PartySubjectStore — 党建专题数据中枢（※新，[PartySubjectView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PartySubjectView.swift#L58-L496)）

**类型**：@MainActor 单例。双子站聚合：
- `siteConfigs`：党建工作（site_key=**djgz**，新闻速递/理论学习/基层动态）+ 思政专题（site_key=**mkszy**，新闻动态/经典著作/党建工作/课程建设）；
- 数据规模口径：**djgz 4 栏目 139 篇 + mkszy 12 栏目 161 篇 = 300 篇**；单栏目最大 74 篇 → 每栏常规 4 页×50=**200 条（regularLimit）**全覆盖，深度检索 **400 条（deepLimit）**；
- `fetchDeptSiteIndex(siteKey:)` 双通道收集栏目索引（column_id 直收 + 内容页/子 tab 节点 id）→ `fetchColumnArticlesTolerant(columnId:siteId:limit:)` 单栏容错隔离（**每栏独立 try-catch + warning 日志**，失败栏目只影响自己）——服务端稳定 500 的容器型栏目（党建工作·首页、思政专题·首页、思政专题·师资队伍）不拖垮全站；
- **搜索**：`localSearch(keyword:)` 多词 AND（空格/全角空格分词），匹配范围=标题（权重 5）+ 描述（权重 2）+ 标签（权重 1），按相关度总分→时间排序；`searchHitDistribution` 两站命中分布；`deepSearchSupplement` 深度拉取补充服务端未覆盖文章（`PartyArticleRef` 标题/描述/标签/链接/来源站）；
- 刷新：`refresh(source:)` 四来源状态机（首次进入/下拉/工具栏/横幅重试）+ `refreshDetached` 防 cancelled 误报；
- 搜索历史：`partySearchHistory`（UserDefaults，去重置顶、上限 10 条）。
- 日志模块 `party`：页面生命周期 → 站点/栏目导航 → 搜索全流程 → 详情打开/关闭 → 数据结构解析 → 栏目级明细 → 站点级耗时汇总 → 刷新四来源状态机 → 容错与横幅生命周期全覆盖。

### 4.22 MessageCenterStore — 消息中心数据中枢（※2026-09-24 上线，[MessageCenterStore.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/MessageCenterStore.swift)）

**类型**：@MainActor 单例。五通道站内信消息盒（新闻 news / 校长信箱 mailbox / 学校概况 profile / 党建专题 partySubject / 收藏更新 bookmarkUpdate）。

- **站内信语义**：`NotificationManager.checkForUpdates(pushToSystem:)` 静默检测模式（5 处 add 短路 + 仅入盒不推送），独立于系统通知开关；入口=下拉刷新/立即检查按钮/前台 30min 自动检查（`messageCenterAutoCheck`）。
- **入职/幂等**：`ingest(kind:id:title:subtitle:deepLink:isTest:)` 同 id 幂等去重、isTest 一律不入盒；毫秒时间戳 id（聚合类消息避免同秒冲突）；概况/党建聚合消息按 kind 幂等。
- **存储与自愈**（`Documents/MessageCenter/messageCenterEvents.json`）：MessageItem 自定义 `init(from:)` 容错解码（缺字段默认值、未知 kind 降级 .news）；整体解码失败 → **备份为 `messageCenterEvents.corrupt-<时间戳>.json`（保留最近 5 份）→ 逐条抢救（单条损坏跳过记 warning）→ 重建写回**；写盘为**强原子写**（临时文件 + `replaceItemAt` 原子替换）+ **写后读回自校验**（失败自动重写）——2026-09-24 真机物证驱动的存储加固。
- **已读与角标**：`markRead(id:)` / `markRead(kind:)`（聚合类型按最新一条已读）/ `markAllRead`；`unreadCount.didSet → syncBadge`（300ms 防抖）→ `setBadgeCount` 双层角标（「我的」Tab `.badge` + 桌面角标）。
- **删除/清空**：右滑单条删除；清空分 all / readOnly 两 scope（均需红色确认弹窗）。
- 日志模块 `messageCenter` 约 30 处埋点；`MessageKind` 枚举、`MessageItem`、`DayGroup`（今天/昨天/更早日分组）、`relative(_:now:)` 相对时间（60s 内「刚刚」、未来时间戳不外显负数）均定义于本文件（测试直接复用）。

### 4.23 HelpGuideStore — 使用帮助数据中枢（※2026-09-24 上线，[HelpGuideStore.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HelpGuideStore.swift)）

**类型**：@MainActor 单例。内容为**内置本地数据**（[HelpContent.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HelpContent.swift) 5 分类 32 篇指南），**零网络、100% 可用**。

- 三级结构：`HelpCategory`（快速上手 6 / 首页与阅读 6 / 特色功能 7 / 设置与个性化 6 / 常见问题 6）→ `HelpArticle`（含 readingMinutes 按 300 字/分钟）→ `HelpStep`。
- **搜索**：多词 AND 加权（标题 5 / 摘要 3 / 标签 2 / 步骤标题 1.5 / 正文 1），搜索历史 `helpGuideSearchHistory`（10 条）；关键词橙色高亮（NSRange⇄Character 双域安全，未命中返回无样式 AttributedString）。
- **进度**：已读 `helpGuideReadIds`、最近阅读 `helpGuideRecentIds`（≤6）、`recordOpen` 阅读进度（动画事务内写，驱动首页锚点卡进度环）。
- 首页锚点卡（TabBar `helpGuideAnchorSection`）：渐变问号图标 + 未读徽章（呼吸光点）+ 已读百分比 + 34pt 进度环 + 继续阅读直达；日志域 `helpGuide`。
- 红线：详情页相关文章跳转用 `@State article` 原地切换 + `ScrollViewReader` 滚回顶（勿用 dismiss+通知方案）。

### 4.24 CampusCalendarStore — 校园日历数据中枢（※2026-09-24 上线，[CampusCalendarStore.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CampusCalendarStore.swift)）

**类型**：@MainActor 单例。校园服务第七项「校园日历」，数据源=官网校园生活-校园日历栏目（columnId 常量 `NetworkService.campusCalendarColumnId = 8197fe41503c4c32bce1e449d2492b2e`，**零新接口**，复用 `fetchArticles`/`fetchArticleDetail`）。

- **列表**：`loadInitial(force:)` 冷启动先读本地缓存（`campusCalendarCache`，含时间戳）再静默刷新；`isFromCache` 驱动「离线缓存」徽章；`loadMore()` 分页触底续拉；`refresh(source:)` 四来源（下拉/工具栏/重试/进入）三态状态机 + `refreshDetached` 防取消误报（**刷新会显式接管取消搜索防抖任务，防并发双写列表**）。
- **搜索（本地全量）**：多词 AND（标题权重 3 / 摘要权重 1）+ 300ms 防抖（`isSearchPending` 供 UI「正在搜索…」指示）+ 搜索前分页全量拉齐（maxPages 10 保护）；历史 `campusCalendarSearchHistory`（去重置顶 ≤10）。
- **详情**：内存缓存字典 + 已读 `campusCalendarReadArticleIds` 落盘；文章 ID 无效直接失败（不用标题兜底）。
- 时间工具 `dateText(_:)` 解析官网三种格式（空格/T 分隔/纯日期 → `yyyy.MM.dd`，兜底前 10 字符）。
- 日志域 `campusCalendar` 约 30 处埋点（入口点击/页面开闭/列表与刷新三态/缓存命中/搜索全流程/详情三态/全屏/长按保存/分享/复制全文/滚动方向 3s 节流）。

---

## 5. 视图层

### 5.1 TabBar.swift 视图清单（9,107 行，60+ 个 View）

> 注：行号为 2026-09-23/24 grep 快照，以符号名为准。底部承载 SJZ 图片/动画组件族（见 §5.3）与 AppIconManager/AppIconSettingsView（§4.18）。

| 视图 | 行号 | 职责 |
|------|------|------|
| `MainTabView` | L15 | 5 Tab 主容器 + 五类通知 DeepLink 消费（见 §3.2） |
| `extension Color` | L364 | 主题色扩展（sjz* 色板） |
| `GradientBackground` / `ShimmerView` | L404 / L414 | 通用装饰组件（渐变背景 / 微光扫过，骨架屏复用） |
| `HomeView` | L449 | 首页：Hero Banner/统计/快捷入口/帮助锚点卡 + 按 `HomeModuleManager.visibleOrderedModules` 渲染 12 个可管理模块；**冷启动骨架屏 `homeModuleSkeleton`（L890）**（常显入口卡除外）、同步状态胶囊、`SJZRevealOnce` 错峰入场（0.07s 递延）、滚动让路 |
| `HeroSlideDecoration` | L624 | Hero 幻灯片装饰 |
| 首页模块分发/入口卡 | L929-L1040+ | `@ViewBuilder` 模块分发 + **helpGuide 使用帮助锚点卡**（L803-L980：渐变问号图标、未读呼吸光点、已读百分比、34pt 进度环、继续阅读直达）+ **校长信箱入口卡**（渐变信封图标、最近一封预览、「N 封回复」徽章）+ 党建/学校概况入口卡 |
| `CategoryBadge` | L1859 | 分类标签组件 |
| `VideoPlayerView` | L1897 | AVPlayer 封装（防盗链依赖） |
| `ShareFormat` / `ArticleLongImageRenderer` / `ShareSheet` | L2032 / L2050 / L2327 | 文章长图分享渲染 + 系统分享面板 |
| `LoadingPhase` | L2345 | 详情加载阶段状态 |
| `EnhancedNewsDetailView` | L2392 | 文章详情：WebView 与纯文本双模式、骨架行（L3218）、超时保护、分享、收藏、已读标记、阅读统计 |
| `PhasedProgressIndicator` / `PhaseProgressDots` | L3253 / L3380 | 分阶段进度指示组件 |
| `FullScreenImageView` | L3410 | 全屏图片查看器（原图 1440px 上限） |
| `WebViewContainer` / `WebView` | L3628 / L3710 | WKWebView 封装（6s 超时、2s 慢加载警告） |
| `HonorDetailView` | L3764 | 荣誉详情 |
| `SceneryDetailView` | L4002 | 风光详情 |
| `TeacherDetailView` | L4072 | 教师详情 |
| `StoryDetailView` | L4299 | 学生故事详情 |
| `ActivityDetailView` | L4529 | 活动详情 |
| `DepartmentsView` | L4763 | 院系列表（横向分类标签） |
| `DepartmentDetailView` / `MajorDetailView` | L4832 / L4936 | 院系详情 / 专业详情 |
| `NewsListView` | L4971 | 资讯列表（搜索、分类筛选、已读未读） |
| `CampusView` / `FacilityDetailView` | L5263 / L5704 | 校园页（校园服务 7 项：六项外链 + **校园日历内部协议分流** `sxjzit://campus-calendar` → push CampusCalendarView）/ 设施详情 |
| `ProfileView` | L5764 | 我的页（**消息中心第一张卡**（双层角标 99+）/收藏/机构/日志/公告/设置/关于入口，sheet 呈现） |
| `AboutView` | L5991 | 关于页 |
| `SettingsView` | L6060 | 设置页：显示设置、应用图标、首页模块、Face ID、通知测试、缓存模式、隐私协议、**网络监测（L6421-L6445，网络调试区）** 等入口 |
| `ZSWHomeView` | L6647 | 招生网首页（三栏目 + 招生计划/公告/动态/指南） |
| `ZSWArticleListView` / `ZSWArticleDetailView` | L6933 / L7074 | 招生网文章列表 / 详情 |
| `SpecialtyListView` / `SpecialtyCollegeDetailView` / `SpecialtyMajorDetailView` | L8411 / L8513 / L8612 | 专业介绍列表（学院分组）/ 学院专业详情 / 单个专业详情 |

> `ProfileView` 中的 sheet：SettingsView / AboutView / BookmarkListView / LogListView 定义于 TabBar.swift；OrganizationView 以 NavigationLink 进入；AnnouncementDetailView 独立 sheet 呈现；校长信箱/学校概况支持 sheet 呈现（通知深链）。

### 5.2 独立视图模块要点

| 视图 | 要点 |
|------|------|
| `OrganizationView`（[OrganizationView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationView.swift)） | 5 分类卡片网格；搜索双模式：机构搜索（本地）+ **机构子站文章深度搜索（※2026-09-23 重构）**：官网权威机构树（`/school/org`）→ 子站栏目索引（`fetchDeptSiteIndex` 双通道）→ 并发分批（**每批 8 个机构** `withTaskGroup`）流式合入结果，实时进度胶囊「检索机构子站 X–Y / N（已命中 M 条）」；分页策略常规 **4 页×50=200 条** + 深度 **8 页×50=400 条**；单文章型机构（党委组织部等 10 个）拉介绍文章详情并全文匹配；索引缓存 `orgSearchIndexCache`/机构树缓存 `orgTreeCache`（UserDefaults）；搜索历史 `orgArticleSearchHistory`；结果来源徽章 |
| `OrganizationDetailView`（[OrganizationDetailView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationDetailView.swift)） | 机构区块渲染：简介、文章列表、子栏目导航、专业介绍、历年分数线；页内线程安全 NSCache 详情缓存；加载/错误/降级状态；文章详情接入 `SJZArticleLoadingView` + `ArticleReadingStatsText` + `SJZCachedImage`；日志埋点 |
| `PrincipalMailboxView`（※新） | `PrincipalMailboxView`（L284）：Liquid Glass 搜索框（聚焦描边动画）、搜索历史（10 条持久化+点击回填+一键清空）、命中高亮、命中计数胶囊、空态引导、下拉刷新、**工具栏三态动画**（触觉反馈→旋转进度圈→绿色对勾脉冲）、顶部状态横幅（刷新中/成功含新增回复数/失败可重试）；`MailboxMessageDetailView`（L1235）：来信/回复双卡、全文高亮、拨号/复制/发信；`MailboxSheetRoot`（L1690）：sheet 根容器（通知深链直达信件详情，id 路由 + 缺失兜底） |
| `SchoolProfileView`（※新） | 蓝金学术风（深蓝 0B1F4B + sjzGold）：六板块胶囊 tab 切换（学校简介/现任领导/识别系统/学校宣传片/校歌/校园风光）；`RollingNumberView`（L1595）数字滚动动效；`ProfileInlineVideo`（L1571）内联 AVKit（出现即播、离开即停）；风光图片网格 + 大图详情；搜索：Liquid Glass 搜索框 + 分段高亮 + 来源徽章 + 历史（`profileSearchHistory`）+ 空态；刷新三态与横幅同校长信箱体系；`SJZScrollActivityTracker`（L29，internal 共享滚动方向追踪器，供各模块复用） |
| `PartySubjectView`（※新） | 党旗红视觉基调：双站点 chips（djgz 锤子图标 / mkszy 书本图标）切换、栏目侧栏/胶囊导航、文章卡片（标题/描述/标签/时间/来源站色点）；搜索：Liquid Glass 搜索框 + 多词 AND 加权 + 高亮 + **两站命中分布徽章「党建工作N篇·思政专题M篇」**（站点色圆点）+ 历史（`partySearchHistory`）+ 空态引导；深度检索补充拉取；单栏失败错误卡（不影响已成功栏目）；刷新三态 + 横幅 |
| `MessageCenterView`（※2026-09-24，[MessageCenterView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/MessageCenterView.swift)） | 我的页第一张卡入口：五通道消息盒日分组列表（今天/昨天/更早，相对时间每分钟刷新）；**右滑「已读/未读」两固定图标按钮（幂等）+ 左滑红色删除 + 长按菜单（标记/复制/分享）+ 点击消未读开详情**（swipeActions 状态快照陈旧问题——用固定图标按钮而非动态文案从机制上解决）；行前蓝色光点未读指示；搜索关键词橙色高亮（NSRange⇄Character 双域）；详情卡复制/分享完整埋点；顶部工具：全部已读三态按钮（`.symbolEffect(.pulse)`）+ 立即检查 + 清空（分 all/readOnly 两 scope 红色确认）；长按铃铛 5 次 → 诊断修复面板（debugSnapshot + repairRewrite）；防抖「正在搜索」指示 |
| `HelpGuideView`（※2026-09-24，[HelpGuideView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/HelpGuideView.swift)） | 主页面（分类卡片 + 搜索 + 最近阅读）+ 详情页（步骤化指南 + 复制全文 + 有帮助/没帮助反馈 + 相关阅读原地切换滚回顶 + 全部已读）；搜索多词 AND 加权 + 橙色高亮 + 历史 + 防抖「正在搜索…」指示；阅读时间徽章四档配色（≤4 绿/5-9 蓝/10-19 橙/≥20 紫）；入口=首页锚点卡（HiddenModules 联动出入场） |
| `CampusCalendarView`（※2026-09-24，[CampusCalendarView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/CampusCalendarView.swift)） | 列表页：渐变 Hero 头卡（「已同步官网+时间」证据 / 共 N 期 / 「离线缓存」徽章，ViewThatFits 防大字号溢出）+ Liquid Glass 搜索框（聚焦渐变描边动画 + 搜索历史胶囊 + onSubmit 收键盘）+ 图标化卡片（五色渐变轮换；官网列表图为占位图故不渲染缩略图）+ 入场 stagger + 骨架 redacted + 分页到底「已经到底啦」+ 下拉刷新三态横幅 + 空态/失败重试卡 + 「正在搜索…」防抖指示；详情页：标题/更新时间卡 + 操作栏（复制全文/保存全部图片（isSavingAll 转圈禁用态）/查看官网原文（href 条件显示））+ 正文大图竖排（SJZCachedImage 1440）轻点全屏（缩放拖拽）+ **长按系统菜单保存/分享** + 无图优雅兜底 + 滚动方向日志（3s 节流）；VoiceOver：卡片组合、图片 isButton+accessibilityAction 旁白可全屏 |
| `NetworkMonitorView`（※新，[NetworkMonitorView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NetworkMonitorView.swift)） | 链路状态卡（接口图标/中文状态/信号流量等级/断开原因/昂贵网络/低数据模式徽章）；实时吞吐与延迟卡（120 点曲线）；会话统计卡（总请求/成功率/总流量/平均延迟 + 四档直方图）；一键诊断卡（进度/评分/P50/P90/最快/最慢/丢包/分阶段耗时）；图表：**iOS 16+ `Chart`，低版本 fallback 自绘折线**（含空态提示与轴标签）；`FlowBars` 流量条装饰 |
| `BookmarkListView` | 搜索、批量删除、`BookmarkThumbnailView` 图片缩略图（命中 BookmarkManager 两级缓存） |
| `LogListView` / `LogSettingsView` | 级别分段筛选、关键词搜索、颜色编码、长按复制、导出 txt、清空二次确认；受 `biometricLockProtected` 敏感页保护；DEBUG 开关、容量上限、存储信息 |
| `NotificationTestView` | 阶段化测试流程：发送测试通知（可选真实文章/校长信箱模拟）、模拟点击通知、角标设置/清除、授权状态明细、**五类 DeepLink 结果闭环回显** |
| `CacheModeSettingsView` | 模式选择卡片（实时预览）、命中率/统计、节省流量、缓存管理分区 |
| `DisplaySettingsView` | 实时预览区 + 外观/文字排版（含文章文字颜色 3×3 色卡）/屏幕/自动锁定/辅助功能/其他设置分区 |
| `BiometricSettingsView` / `BiometricLockOverlayView` | 总开关（关闭需二次认证）、锁定策略 Picker、设备能力状态、立即锁定；全屏渐变遮罩 + 认证按钮/进度/错误提示 + 系统设置引导；`.privacySensitive()` 防多任务预览泄露 |
| `HomeModuleSettingsView` | 12 模块开关列表 + List onMove 拖拽排序 + 恢复默认（helpGuide 等板块副标题文案） |
| `PrivacyPolicyHomeView` / `PrivacyDocumentView` / `PrivacyConsentView` / `RestrictedModeView` | 协议入口卡片、文档加载状态机（来源标识）、首次启动同意弹窗、受限模式 |
| `AnnouncementDetailView` | `AnnouncementBanner` 头图 + 正文 + 数据来源指示 + 阅读统计 |

### 5.3 SJZ 图片/动画组件族（[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L7418-L8410)，全 App 共享）

统一图片管线核心设计目标：**缓存模式联动、滚动往返零闪烁、秒开体验**。

| 类型 | 行号 | 职责 |
|------|------|------|
| `SJZScrollSuspendedKey` + `sjzImageLoadingSuspended` 环境键 | L7418 | 滚动中为 true（滚动让路：帧率优先） |
| `SJZScrollSuspendModifier` + `.sjzScrollSuspendTrack(_:)` | L7431 | iOS 18+ `onScrollPhaseChange` 追踪滚动态到 Binding；低版本零影响 |
| `SJZImagePhase` | L7453 | 加载阶段 `empty(progress:)/success/failure`，与 AsyncImagePhase 对齐便于机械替换 |
| `SJZImageFreePlaceholder` | L7463 | 免费占位渐变（无版权风险） |
| `SJZCachedImage` | L7485 | **统一图片加载器**（AsyncImage 三段闭包同构）：① 视图初始化**同步**查解码缓存，命中首帧直出零闪烁；② `.task(id: SJZLoadToken)` 换 URL/重试自动重启；③ 缓存模式联动请求策略；④ 下载进度回调；⑤ 失败透明遮罩「轻点重试」；⑥ 滚动中等待静止（≤800ms）再启加载 |
| `SJZImageKit` | L7743 | 工具集：`defaultThumbnailPixel = 720`（缩略图统一降采样）；命中日志节流（同 URL 仅首见）；共享下载会话（资源超时 120s）；`makeRequest` 缓存策略随缓存模式切换；`cachedExpectation` 缓存预判；`memoryGuardPixelCount = 40M` 像素护栏（超限强制 4096 降采样）；`decode` 后台线程 ImageIO 降采样；`isImageFreeModeFromAnyThread`（L7750，无图模式直读） |
| `SJZDecodedImageCache` | L7944 | **独立类型**（非嵌套）：解码图内存缓存 `NSCache`（线程安全、内存压力自动淘汰）+ `OSAllocatedUnfairLock` 守护限额；按「URL+降采样边长」分键；像素计费（w×h×scale²×4）；双档限额：缓存模式 600 张/96MB ↔ 即时模式 200 张/40MB（`refreshLimits` 随模式切换）；`removeAll()` |
| `SJZLoadToken` / `SJZImageError` | L7836 / L7843 | 加载任务标识（URL + attempt）/ 解码失败错误 |
| `SJZAverageColorCache` | L7876 | 平均色缓存（300 条 hex 字典）：二次访问以近似色调占位，blur-up 消除白闪 |
| `SJZImagePrefetcher` | L8008 | 智能预取：命中跳过、未命中并发 ≤4 分批下载（`withTaskGroup`），失败静默；命中/跳过/耗时日志 |
| `SJZDesignTokens` | L8062 | 视觉令牌：accent/success/warning 三组渐变 + `capsuleStroke` 玻璃高光描边 |
| `SJZPageLoadProgressBar` | L8092 | **页面加载进度条**：两种模式——初始进入的不确定彩虹扫描（无总数据）+ 图片加载的确定彩虹渐变带色调旋转（真实百分比） |
| `SJZGalleryProgressBar` | L8185 | 画廊计数条：确定型进度 + 渐变轨道 + 数字滚动动画 + Liquid Glass |
| `SJZSlowNetworkBanner` | L8230 | 弱网提示胶囊（wifi.exclamationmark 脉冲图标） |
| `SJZCachedBadge` | L8253 | 「已缓存 · 秒开」徽标（缓存命中即时反馈，bounce 入场） |
| `SJZArticleLoadingView` | L8277 | 文章大内容加载态：流彩图标（iOS 17 `symbolEffect(.variableColor.iterative)`）+ 相位文案 1.3s 轮换（获取→解析→渲染）+ 恒动渐变进度条 + 已用时计数 |
| `SJZRevealRegistry` / `SJZRevealOnce` | L8352 / L8367 | 会话级错峰揭示登记（200 键上限、NSLock）/ 首次出现弹簧入场、重复出现直接可见 |

**三级缓存结构**：`URLCache.shared`（HTTP 磁盘缓存 80/400MB，RefererHeaderURLProtocol 注入 7 天头）→ 解码图内存缓存（SJZImageKit 内）→ `SJZAverageColorCache`（色调占位）。加载顺序：解码内存同步命中 → 缓存预判 → `returnCacheDataDontLoad` 读盘 → 网络下载（指数退避 1s/3s 自动重试 ≤2 次）。

**渲染接入**：机构详情页、机构文章详情、新闻详情缩略图、首页模块卡片、风光/教师/故事/活动/荣誉详情 hero（1440px）、全屏查看（1440px）、收藏缩略图、学校概况风光网格等全部图片入口统一经 `SJZCachedImage`。

---

## 6. 数据模型与静态兜底数据

**文件**：[Models.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/Models.swift)（968 行）

### 6.1 SchoolInfo 学校信息枚举

静态常量集中营：`name`、`englishName`、`motto`（谨信博学 · 经世致用）、`address`、`foundedYear`、`type`（民办全日制普通本科）、`affiliation`、`predecessor`（中北大学信息商务学院）、`website`、`phone`、`recruitPhones`、`email`、`campusArea`、`buildingArea`、`libraryBooks`、`studentCount`、`majorCount`、`departmentCount`、`description`（学校简介长文）等。

### 6.2 业务模型（均 `Identifiable, Codable`）

| 模型 | 说明 |
|------|------|
| `Banner` / `StatItem` / `Honor` | 首页 Banner（videoSrc/posterImgSrc）/ 统计指标 / 校园荣誉 |
| `Department` / `Major` | 院系与专业（派生计算主键） |
| `NewsItem` | 新闻（含 `readKey`、`articleId`、`href`） |
| `StudentStory` / `TeacherProfile` | 学生故事 / 教师风采 |
| `CampusVideo` / `CampusActivity` / `CampusScenery` | 校园视频 / 活动 / 风光 |
| `CampusService` / `Facility` / `TimelineEvent` | 校园服务 / 设施 / 发展历程 |
| `QuickLink` / `MediaLink` / `FooterLink` / `SocialPlatform` | 快捷入口 / 特色媒体 / 底部链接 / 社交平台 |
| `ZSWArticle` / `ZSWSection` / `ZSWGuideChild` / `ZSWRecruitItem` / `ZSWHomeData` | 招生网模型族 |
| `BookmarkItem` | 收藏（含 cachedContent/contentCached） |
| `SpecialtyMajor` / `SpecialtyCollege` / `SpecialtyData` | 专业介绍模型族 |

### 6.3 静态兜底数据（全局 `let default*` 常量）

`defaultBanners` / `defaultStats` / `defaultHonors` / `defaultDepartments`（含完整专业列表）/ `defaultNews` / `defaultStudentStories` / `defaultTeacherProfiles` / `defaultVideos` / `defaultCampusActivities` / `defaultCampusSceneries` / `defaultServices`（**2026-09-24 增第七项「校园日历」**：`CampusService(name:"校园日历", icon:"calendar", url:"sxjzit://campus-calendar")`——内部协议由 CampusView/ServiceButton 分流为原生页面，其余六项继续外链）/ `defaultFacilities` / `defaultTimeline`。

> DataService 初始化时先用默认数据填充，`loadCache()` / `loadZSWCache()` / `loadSpecialtyCache()` 命中则覆盖并标记 `dataSource = "缓存"`，同步成功后标记 `"服务器"`。新三模块（信箱/党建/概况）服务端结构动态，**无静态兜底**，失败时展示本地缓存/错误卡 + 重试（信箱另有基线缓存）。

---

## 7. 网络层与 API 清单

```
基地址     https://gwqietap.sxjzit.edu.cn/mapi
请求超时   15s；资源超时 30s
重试       2 次（合计 3 次，指数退避 500ms×N）；URLError.cancelled 立即传播不重试
缓存策略   reloadIgnoringLocalAndRemoteCacheData（服务层默认）
鉴权       无（公开只读接口；唯一定制头为防盗链 Referer/UA）
```

### 7.1 接口清单（全 GET + Query）

| 方法 | 端点 | 用途 |
|------|------|------|
| `fetchHome2` | `/school/home2` | 首页全量 |
| `fetchHead` | `/common/column/head` | 站点 + 菜单（党建专题子项 site_key 亦由此来） |
| `fetchFoot` | `/common/foot` | 底部信息 |
| `fetchArticles` | `/common/column/articles` | 文章分页（page/size；主站/机构子站/党建子站/校园风光通用） |
| `fetchArticleDetail` | `/common/article/detail` | 文章详情（主站/招生网/单文章型机构通用） |
| `fetchArticleDetailWithHref` | 任意 href | 非标准 JSON 的 HTML 兜底 |
| `fetchJSONDict` | 任意（如 `/school/intro`） | **※新**：动态字典解析 |
| `fetchZSWHome2` | `/dept/home2?site_key=zsw` | 招生网首页 |
| `fetchZSWArticlePage` | `/common/article/page` | 招生网分页（pageNo/pageSize） |
| `fetchZSWArticleDetail` | `/common/article/detail` | 招生网详情 |
| `fetchSpecialtyData` | `/common/column/oneTwoArticles` | 专业介绍 |
| `fetchDeptHome2` | `/dept/home2` | 机构部门首页 |
| `fetchSchoolOrgTree` | **※新** `/school/org` | 官网权威机构树（机构三形态） |
| `fetchDeptSiteIndex` | **※新** `/dept/home2` | 机构/党建子站栏目索引（双通道收集） |
| `fetchPrincipalMailbox` | **※新** `/school/msg` | 校长信箱公开回复分页（page/size） |
| `fetchMessageDetail` | **※新** `/common/msg/detail` | 信件详情（msgId；后端必填 article_id+site_id+msg_id 三参数，404/400 会逐条提示） |
| `fetchPartySubjectFingerprint` | **※2026-09-24** `/dept/home2?site_key=` | 党建/思政子站指纹（total + 最新 3 篇 id\|time，通知轮询第四通道） |
| **独立直连**（不经 NetworkService） | `https://www.43322.cn/blog/gonggao|terms|privacy-policy` | 公告 / 隐私协议 |

### 7.2 特殊处理

- 招生网专用 `siteId = cb3b1fe4fcdf40999b0c162015c3326d`；专业介绍 `columnId = 25d7bd39e49a468880356e302b9ccf1d`（DataService）。
- 学校概况风光栏目 `columnId = 214e6c2b`（SchoolProfileStore）。
- **校园日历栏目 `columnId = 8197fe41503c4c32bce1e449d2492b2e`**（`NetworkService.campusCalendarColumnId`，2026-09-24 实测：total=1《2025-2026学年第一学期校历》，正文单张 6.38MB 校历大图 webp；列表 `image_url` 官方便是 `no_picture.webp` 占位图 → 列表卡片图标化不渲染缩略图；图片 302 → `https://www2.sxjzit.edu.cn`（协议层内部自动跟随，最终 200 可达）；正文无 href → 详情「查看原文」按钮条件隐藏）。
- **图片保存到相册铁律（2026-09-24 真机复现）**：WebP 图经 `creationRequestForAsset(from: UIImage)` 写入会触发 **PHPhotosErrorDomain 3302（invalidResource）**——必须 JPEG 重编码（0.92）→ 临时文件 → `PHAssetCreationRequest.addResource(with: .photo, fileURL:)`（shouldMoveFile）file-based 写入，见 `ProfileImageSaveShare.saveToPhotos`。
- 校长信箱 `/school/msg` 响应仅**两层 data 嵌套**（data.标题层.data.message_list）——DTO 多建一层会导致 message_list 静默解码为 nil（表现为“成功返回 0 条”的空态且刷新无效）；"/common/msg/detail" 为非 `/school/msg/detail`。
- 党建专题 service端稳定 500 的容器型栏目需单栏容错隔离。
- 图片 URL：相对路径拼 `https://www.sxjzit.edu.cn`，非 ASCII 自动百分号编码，过滤 `file://`（Word/WPS 粘贴带入）。
- DTO 全 Optional + 显式 CodingKeys；`DeptNavItemDTO` 用 `DynamicCodingKeys` 跳过混合类型数据字典；`VideoBlockDTO` 自定义 encode。
- 官网静态素材（校徽 `mark_logo`、校名规范图、视频海报）位于 `/assets/` 且文件名带内容哈希，随前端部署变化——集中维护于 `SchoolProfileAssets` 并在官网重新部署后核对。

---

## 8. 关键执行链路

### 链路① App 启动

```
DesignCodeApp.init() → URLCache 扩容(80/400MB) → 注册 URLProtocol
  → 内存警告降载 Handler → AppIconManager 启动校准 → 启动日志
WindowGroup ZStack: MainTabView(opacity 0) + SplashView + [隐私弹窗] + [受限模式] + [锁屏遮罩]
.task: sleep 1s → isAppReady = true → Splash 淡出
onChange(isAppReady): 分流隐私状态 → 首次弹同意 / 曾拒绝进受限 / 正常进入
.task(id: isAppReady): 刷通知授权 → 已同意+已授权+已启用 → startPolling()
MainTabView.task: sleep 0.5s → data.syncIfNeeded()
```

### 链路② 数据同步

```
syncIfNeeded() [10s 冷却；缓存模式<10分钟短路] → doFullSync() [逐接口 do-catch 永不抛]
  ├─ 并行 fetchHome2 + fetchHead + fetchFoot（三者全失败 → loadCache 回退）
  ├─ Banner / 荣誉 / 8 列新闻（safeFetchArticles 分页直到 <50 或空）
  ├─ 视频（并行提取 <video><source>）/ 学生故事 / 教师风采 / 活动 / 风光
  ├─ 院系（extractDepartments + defaultDepartments 合并）
  ├─ 站点信息 / 底部链接 / 社交平台
  ├─ OrganizationManager.updateSiteKeys(menus)（site_key 回调更新）
  ├─ saveCache() → Documents/SXJZIT_Cache/*.json
  └─ 后台 Task: loadZSWHomeData() + loadSpecialtyData()
  → 结束广播 syncDidCompleteNotification
```

### 链路③ 通知点击 → 目的地（五类 DeepLink，防崩溃设计）

```
didReceive（完成回调版，主线程派发）→ completionHandler() 立即回执
  → Task @MainActor → handleNotificationTap（按 userInfo 分类路由）
      ├─ 文章类 → pendingDeepLink = 新实例
      ├─ 信箱类 → pendingMailboxDeepLink = mailboxId
      └─ 概况类 → pendingSchoolProfileDeepLink = true
  → MainTabView.onChange → consumePendingDeepLink
      ├─ 并行 preloadArticleDetail（详情秒开）
      └─ scheduleNotificationArticlePresentation（Task：轮询等待
         scenePhase == .active && !isLockEngaged，最长 3s → 超时回写
         deepLinkOutcome.failed；满足后 +350ms 让出 runloop → 弹 sheet：
         文章详情 / MailboxSheetRoot(id 路由直达信件) / SchoolProfileView sheet）
```

### 链路④ 生物识别锁定

```
冷启动（已启用）: init → state = .locked → 根视图出现 BiometricLockOverlayView
后台返回: handleDidEnterBackground 记时 → handleReturnToForeground
         （立即/超窗口）→ lock(reason: "background_return")
         （含 Face ID 对话框关闭误判保护：解锁 1.5s 内跳过）
敏感页进入: .biometricLockProtected().onAppear → needsLockRequest → requestLock
解锁: authenticate() → performEvaluation（生物识别 → 5 次失败/锁定转
      deviceOwnerAuthentication 密码）→ success → unlocked → 遮罩消失
```

### 链路⑤ 显示设置全局生效

```
DisplaySettingsManager（@Published didSet 持久化）→ 根视图 displayTypography
  → DisplayTypographyModifier → 5 个自定义 EnvironmentKey + sizeCategory 覆盖
  → 全 App 文本经 displayText/displayFont/displaySymbolFont/displayLabelFont
     → DisplayFontFactory 组装（档位×粗体×家族×字距×行距）
主题色: themeStyle.color → .tint 根级注入；外观: appearanceMode → preferredColorScheme
运行时: brightnessValue → activeScreen.brightness；autoLockOption → isIdleTimerDisabled
```

### 链路⑥ 统一图片加载（SJZCachedImage 管线，零闪烁核心）

```
视图 init 同步查解码缓存（命中 → 首帧直出，无占位帧）
.task(id: SJZLoadToken) → load()
  ├─ 解码缓存再查（miss → 继续）
  ├─ 滚动让路：loadingSuspended 时等待静止（≤800ms）
  ├─ 缓存预判 cachedExpectation → 命中则 returnCacheDataDontLoad 读盘直出
  │   └─ 数据不可用 → 回落网络
  ├─ 网络下载（SJZImageDownloadDelegate 进度 → phase .empty(progress:)）
  │   └─ 失败指数退避 1s/3s 重试 ≤2 次 → 全部失败 phase = .failure（轻点重试）
  └─ 成功：ImageIO 降采样解码（后台线程）→ 像素计费写入解码缓存
      → 顺带记录平均色（SJZAverageColorCache）→ phase = .success
      → finishSuccess 埋点（命中/未命中/耗时/imageCache 日志，命中日志按 URL 节流）
```

### 链路⑦ 应用图标切换

```
App 启动 DesignCodeApp.init → AppIconManager.calibrateOnLaunch()
设置页 AppIconSettingsView.onAppear → refreshFromSystem()（选中态再校准）
用户点击色卡 → setIcon(name) [isSwitching 防连点]
  → UIApplication.setAlternateIconName → 系统确认弹窗（仅用户显式确认才生效）
  → 成功：更新 activeIconName + 持久化 + appicon 日志
  → 失败：本地记录不变（选中态自然回滚）+ 中文错误提示
```

### 链路⑧ 机构子站深度文章搜索（※2026-09-23 重构，[OrganizationView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationView.swift)）

```
performArticleSearch(keyword, deep) [500ms 防抖]
  ├─ 本地缓存查询（orgSearchQueryCache 命中直出）
  └─ 未命中 → searchOrganizationArticles
      ├─ 机构树获取：fetchSchoolOrgTree()（缓存 orgTreeCache / 网络）
      ├─ 子站型机构：并发分批（每批 8 个，withTaskGroup）
      │   └─ fetchOrgArticles(siteKey, maxPages=deep?8:4)
      │       ├─ fetchDeptSiteIndex(siteKey) 双通道栏目索引（缓存 orgSearchIndexCache）
      │       │   ├─ 标准栏目 column_id 直收
      │       │   └─ 内容页/子 tab 节点 id（可直接查文章）
      │       └─ 逐栏动态分页 size=50 拉到 total/maxPages 上限
      │           → 全文匹配（标题+正文）→ 流式合入结果
      ├─ 单文章型机构（党委组织部等 10 个）：withTaskGroup 拉
      │   fetchArticleDetail(articleId) 详情全文匹配
      ├─ 实时进度胶囊「检索机构子站 x–y / N（已命中 M 条）」
      └─ 结果去重排序 → makeOrgResult（来源徽章）→ 缓存本次结果
```

### 链路⑨ 四通道通知轮询 + 收藏第五通道（※新）

```
checkForUpdates() [isChecking 防重入] → 依次：
  ├─ checkNewsUpdates：4 栏目并行首屏 → notifiedArticleIds 对比 →
  │   每次 ≤5 条错开 1s 发送（防轰炸）
  ├─ checkMailboxUpdates：/school/msg 首页 → baseline=mailboxLastKnownTotal：
  │   首次仅记基线不推送；新增信件 → 推送（携带 mailboxId）
  └─ checkSchoolProfileUpdates：/school/intro + /school/cooperate → 三段基线
      schoolProfileBaseline（领导数|风光数|合作交流条数）变化 → 推送「学校概况·有新内容」
      （文案精确到变化板块；旧两段基线静默升级，合作交流通道失败时本轮跳过比对）
└─ checkPartySubjectUpdates：/dept/home2?site_key=djgz|mkszy 每站单请求递归收集指纹
      （总数+最新3篇 id|time 签名，按 id 去重）→ partySubjectBaseline 四段变化 → 推送
      「党建专题·有新内容」（文案精确到子站）；点击深链 pendingPartySubjectDeepLink →
      TabBar sheet 直达完整 PartySubjectView
第五通道（独立轮询，不入 NotificationManager）：
  BookmarkManager.checkBookmarkedArticlesForUpdates → 收藏文章正文指纹比对
  → 更新时 sendUpdateNotifications（≤3 条）→ 消息中心 MessageKind.bookmarkUpdate 入盒
任一通道失败只影响自身（独立 try-catch + warning/error 日志）
```

### 链路⑩ 网络监测数据流（※新）

```
全 App 请求（sxjzit.edu.cn 域）→ RefererHeaderURLProtocol
  → tapRequestStart/tapData/tapComplete/tapAbandon → NetworkMonitorLedger（线程安全台账）
  → 1s 聚合桶 → 120 点环形缓冲 → SJZNetworkMonitor @Published（吞吐/延迟曲线）
  → NWPathMonitor 链路状态（中文状态/接口类型/昂贵网络/低数据）
  → NetworkMonitorView：链路卡/实时卡（Chart 或自绘）/会话统计卡
  → runProbe()：5 轮探测 gwqietap → ProbeState → RTT 分位/丢包/分阶段诊断卡
```

---

## 9. 持久化明细

| 模块 | 介质 | Key / 路径 |
|------|------|------------|
| 全局网络缓存 | URLCache | `URLCache.shared` 80MB 内存 / 400MB 磁盘（`sxjzit_shared_cache`） |
| DataService 数据缓存 | 文件 JSON | `Documents/SXJZIT_Cache/*.json`（news/honors/departments/videos/zsw_home/specialty 等） |
| DataService 详情内存缓存 | NSCache | 即时 50 条/20MB ↔ 缓存模式 200 条/80MB |
| BookmarkManager | UserDefaults + 文件 | `bookmarkedArticles`；图片 `BookmarkImages/*.img`（SHA256 键） |
| ReadStatusManager | UserDefaults | `readArticleIds`（上限 5000） |
| NotificationManager | UserDefaults | `notificationEnabled`、`notificationPollingMinutes`、`notifiedArticleIds`（2000）、`schoolProfileBaseline`（领导数\|风光数） |
| PrincipalMailboxStore | UserDefaults | `mailboxLastKnownTotal`（新增信件基线）、`mailboxSearchHistory`（10 条） |
| SchoolProfileStore | UserDefaults | `profileSearchHistory`（10 条）、`schoolProfileBaseline`（通知基线） |
| PartySubjectStore | UserDefaults | `partySearchHistory`（10 条）、`partySubjectBaseline`（四段通知指纹基线） |
| MessageCenterStore（※新） | 文件 JSON + UserDefaults | `Documents/MessageCenter/messageCenterEvents.json`（强原子写 replaceItemAt + 写后自校验）、损坏备份 `messageCenterEvents.corrupt-<时间戳>.json`（保留最近 5 份）、`messageCenterAutoCheck`/`messageCenterSearchHistory`/`messageCenterReadIds` |
| HelpGuideStore（※新） | UserDefaults | `helpGuideSearchHistory`（10 条）、`helpGuideReadIds`、`helpGuideRecentIds`（≤6） |
| CampusCalendarStore（※新） | UserDefaults | `campusCalendarCache`（列表 JSON + 拉取时间戳）、`campusCalendarSearchHistory`（10 条）、`campusCalendarReadArticleIds` |
| OrganizationView 搜索 | UserDefaults | `orgArticleSearchHistory`（历史）、`orgSearchIndexCache`（子站栏目索引）、`orgTreeCache`（机构树）、搜索查询结果缓存 |
| LogManager | 文件 JSON | `Documents/SXJZIT_Cache/Logs/log_YYYY-MM-DD.json`；容量 1000-10000 可配 |
| AnnouncementManager | UserDefaults | `announcementCache` |
| OrganizationManager | UserDefaults | `organizationCache` |
| PrivacyManager | UserDefaults | `privacy_documents_cache_{type}` |
| CacheModeManager | UserDefaults | `cacheMode`、`cacheHitCount` 等统计键 7 个 |
| DisplaySettingsManager | UserDefaults | `colorSchemePreference`（联动旧键）、`displayAccentStyle`、`displayFontSizeTier` 等 12 个键 + 文章颜色键 + 阅读统计 4 开关/速度档 |
| ReadingStatsCache | 内存 + UserDefaults | `readingStatsCache`（JSON，500 条 FIFO，存原始分量） |
| 解码图缓存 | 内存 NSCache | 缓存模式 600 张/96MB ↔ 即时模式 200 张/40MB；像素计费；嵌套于 SJZImageKit |
| SJZAverageColorCache | 内存字典 | url → 平均色 hex，300 条上限 |
| SJZRevealRegistry | 内存 Set | 会话级入场揭示键，200 条上限 |
| SJZNetworkMonitor | 无持久化 | 会话级 120 点环形缓冲（最近 2 分钟） |
| BiometricSecurityManager | UserDefaults + Keychain | 开关/策略存 UserDefaults；启用令牌存 Keychain（`com.qinchao.DesignCode.biometric`，WhenPasscodeSetThisDeviceOnly） |
| HomeModuleManager | UserDefaults | `homeModuleOrder`、`homeModuleHidden` |
| 全局偏好 | UserDefaults | `privacyConsentAccepted`、`privacyConsentRejected`、`logDebugEnabled` 等 |

---

## 10. 依赖关系总图

```
DesignCodeApp
├── URLCache 扩容 + URLProtocol.registerClass(RefererHeaderURLProtocol)
├── SJZNetworkMonitor（经 URLProtocol 埋点，零侵入）
├── SplashView
├── MainTabView（TabBar.swift）
│   ├── HomeView ── HomeModuleManager.visibleOrderedModules（12 模块渲染控制）
│   │   ├── DataService.shared（旧数据域模块数据源）
│   │   ├── PrincipalMailboxStore / PartySubjectStore / SchoolProfileStore（新 3 卡）
│   │   ├── ReadStatusManager.shared（未读蓝点）
│   │   └── VideoPlayerView / 各详情页 / EnhancedNewsDetailView
│   ├── DepartmentsView → DepartmentDetailView → MajorDetailView
│   ├── NewsListView → EnhancedNewsDetailView
│   ├── CampusView → VideoPlayerView / SceneryDetailView / FacilityDetailView
│   └── ProfileView
│       ├── OrganizationView → OrganizationDetailView
│       ├── BookmarkListView / LogListView / AnnouncementDetailView
│       └── SettingsView → DisplaySettingsView / HomeModuleSettingsView /
│           BiometricSettingsView / NotificationTestView / CacheModeSettingsView /
│           NetworkMonitorView / PrivacyPolicyHomeView
│
├── 服务层（全部单例）
│   ├── DataService ──→ NetworkService（旧数据域唯一网络入口）
│   │   ├──→ OrganizationManager.updateSiteKeys（同步回调）
│   │   └──→ CacheModeManager（NSCache 限额联动）
│   ├── PrincipalMailboxStore ──→ NetworkService（/school/msg、/common/msg/detail）※新
│   ├── PartySubjectStore ──→ NetworkService（/dept/home2 索引、/common/column/articles）※新
│   ├── SchoolProfileStore ──→ NetworkService（/school/intro、风光栏目/图集、/school/cooperate、校企合作栏目/详情）※新
│   ├── MessageCenterStore ──→ 五通道（NotificationManager + BookmarkManager 注入消息；独立文件存储）※2026-09-24
│   ├── HelpGuideStore ──→ HelpContent（内置本地数据，零网络）※2026-09-24
│   ├── CampusCalendarStore ──→ NetworkService（/common/column/articles、/common/article/detail，campusCalendarColumnId）※2026-09-24
│   ├── NotificationManager ──→ NetworkService（fetchHome2/fetchArticles
│   │                            /fetchPrincipalMailbox/fetchJSONDict/fetchPartySubjectFingerprint 四通道）
│   ├── BookmarkManager ──→ NetworkService（正文缓存）+ ReadStatusManager
│   ├── AnnouncementManager ── 独立 URLSession（43322.cn）
│   ├── PrivacyManager ── 独立 URLSession + PrivacyLegalTexts 兜底
│   ├── BiometricSecurityManager ── LocalAuthentication + Keychain
│   ├── DisplaySettingsManager ── UIKit（UIScreen/UIApplication/UIAccessibility）
│   ├── HomeModuleManager ──→ DataService + 三新 Store（数据量统计）
│   ├── SJZNetworkMonitor ←── RefererHeaderURLProtocol（埋点）
│   ├── ReadStatusManager / CacheModeManager / LogManager ── 独立
│   └── 全模块 ──→ LogManager.shared（日志埋点）
│
└── 数据层
    ├── Models.swift（模型 + default* 兜底）
    ├── UserDefaults（全局偏好 + 各模块状态 + 搜索历史 + 基线）
    ├── Keychain（生物识别启用令牌）
    ├── Documents/SXJZIT_Cache/（数据缓存 + 日志文件）
    └── URLCache.shared（80MB/400MB 共享 HTTP 缓存）
```

**依赖方向约束**：视图 → 服务层 → 数据层单向；服务层横向耦合仅：DataService → NetworkService、DataService → OrganizationManager、DataService ↔ CacheModeManager、六个新 Store → NetworkService（HelpGuideStore 例外：零网络读本地 HelpContent）、NotificationManager → NetworkService、MessageCenterStore ← NotificationManager/BookmarkManager（消息注入）、RefererHeaderURLProtocol → SJZNetworkMonitor，其余 Manager 互不依赖。

---

## 11. 项目运行方式

### 11.1 硬件与系统要求

| 项 | 要求 | 依据 |
|----|------|------|
| Mac | Apple Silicon 或 Intel（Xcode 支持范围内） | — |
| 操作系统 | macOS，版本随所装 Xcode 要求 | — |
| Xcode | **15 及以上**；当前构建产物使用 **iOS 26.x SDK**（iphonesimulator27.0）编译，建议与目标 SDK 匹配；本机开发环境为 **Xcode 27.0（Build 27A266a，2026-09-27 复核）** | pbxproj / build 产物 |
| Swift 语言 | `SWIFT_VERSION = 5.0`；代码实际使用 `async/await`、`@MainActor`、`withTaskGroup`，运行时需 Swift 5.5+ 编译器 | project.pbxproj |
| 最低系统版本 | ⚠️ project 层 `13.0`，target 层 `26.0`（target 覆盖 project，**实际生效 iOS 26.0**）——两处不一致，需人工统一 | project.pbxproj |
| 设备 | iPhone + iPad（`TARGETED_DEVICE_FAMILY = "1,2"`）；真机必须 `arm64`。**本项目的调试/验收设备为真机“秦超的iPhone”（iOS 27.0，UDID 00008110-000411A40EC1401E），不使用模拟器** | pbxproj / Info.plist |
| 签名 | `CODE_SIGN_STYLE = Automatic`，Team `F2JL9GNLCC` | pbxproj |

### 11.2 构建设置详解（[project.pbxproj](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode.xcodeproj/project.pbxproj)）

#### Target 层构建阶段：显示设置覆盖护栏（Run Script，2026-09-27 全链审计新增）

| 项 | 值 |
|----|-----|
| 阶段名 | `显示设置覆盖护栏`（置于 Sources 之前，先于编译执行） |
| 脚本 | `python3 "$SRCROOT/Scripts/display_coverage_guard.py"`（`alwaysOutOfDate = 1`，每次构建必跑） |
| 规则一 | `DesignCode/*.swift` 禁止原始字体写法（必须走 `displayFont / displayText / displaySymbolFont / displayLabelFont / DisplayFontFactory.font`） |
| 规则二 | 每个 `.sheet / .fullScreenCover` 内容必须挂载 `.sjzPresentationChrome()`（系统分享面板 `ShareSheet` 自带豁免） |
| 例外 | `Scripts/display_coverage_allowlist.txt`（`font:文件\|片段 # 理由` / `presentation:文件\|片段 # 理由`），空文件 = 100% 覆盖 |
| 失败行为 | 打印违规清单 + 修复指引，退出码 65 → 构建中断（新增功能无法绕过显示设置） |

#### Project 层（Debug 与 Release 共享：`SDKROOT = iphoneos`、全组 CLANG_WARN_* 警告开启；以下为差异项）

| 设置项 | Debug | Release |
|--------|-------|---------|
| `SWIFT_OPTIMIZATION_LEVEL` | `-Onone` | `-O` |
| `SWIFT_COMPILATION_MODE` | 默认（incremental） | `wholemodule` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG` | — |
| `GCC_PREPROCESSOR_DEFINITIONS` | `DEBUG=1` | — |
| `ONLY_ACTIVE_ARCH` | `YES` | 默认 NO |
| `DEBUG_INFORMATION_FORMAT` | 默认（dwarf） | `dwarf-with-dsym` |
| `ENABLE_NS_ASSERTIONS` | 默认 YES | `NO` |
| `VALIDATE_PRODUCT` | — | `YES` |

#### Target `DesignCode` 层（Debug 与 Release 相同）

| 设置项 | 值 | 说明 |
|--------|-----|------|
| `IPHONEOS_DEPLOYMENT_TARGET` | `26.0` | ⚠️ 覆盖 project 层 13.0 |
| `SWIFT_VERSION` | `5.0` | 语言模式 |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.qinchao` | Bundle ID |
| `INFOPLIST_FILE` | `DesignCode/Info.plist` | 使用实体 plist |
| `INFOPLIST_KEY_CFBundleDisplayName` | `园枢` | 构建时注入显示名 |
| `TARGETED_DEVICE_FAMILY` | `"1,2"` | iPhone + iPad |
| `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` | `AppIconAlt1 AppIconAlt2 AppIconAlt3 AppIconAlt4` | 备选图标（三处一致铁律） |
| `ENABLE_PREVIEWS` | `YES` | SwiftUI 预览 |
| `LD_RUNPATH_SEARCH_PATHS` | `@executable_path/Frameworks` | 动态库查找路径 |
| `OTHER_SWIFT_FLAGS` | `$(inherited) -disable-sandbox` | ⚠️ **禁用 App 沙箱**（非默认，见 11.8） |
| `CODE_SIGN_STYLE` / `DEVELOPMENT_TEAM` | `Automatic` / `F2JL9GNLCC` | 自动签名 |

#### Target `DesignCodeTests` 层

- `GENERATE_INFOPLIST_FILE = YES`、Bundle ID `com.qinchao.tests`；
- `BUNDLE_LOADER` + `TEST_HOST` 指向 `DesignCode.app/DesignCode`（宿主 App 单元测试）；
- 部署目标同为 `26.0`，签名同 Team。

### 11.3 Target 与 Scheme

| 项 | 内容 |
|----|------|
| Targets | ① `DesignCode`（`com.apple.product-type.application`）② `DesignCodeTests`（`com.apple.product-type.bundle.unit-test`） |
| Scheme | ⚠️ **仓库内无任何 `.xcscheme` 文件**：`xcshareddata/xcschemes/` 不存在，两个 `xcuserdata/*/xcschemes/` 仅有 `xcschememanagement.plist`（其中把 DesignCode/DesignCodeTests 标记为 `^#shared#^_` 即"意图共享"）。GUI 打开工程后 Xcode 会自动重新生成 scheme 方可运行；纯命令行/CI 环境（不先打开 GUI）下 `xcodebuild -scheme DesignCode` 会因找不到 scheme 而失败——clone 后需先在 Xcode 打开一次，或补提交共享 scheme 文件 |

### 11.4 签名与导出配置（[ExportOptions.plist](file:///Users/qinchao/Downloads/designcode-swiftui/qin/ExportOptions.plist)）

- `method = development`；`teamID = F2JL9GNLCC`（⚠️ 明文提交，入库前注意脱敏）；`compileBitcode = false`；`stripSwiftSymbols = true`；`thinning = <none>`。
- **无 entitlements 文件**、**无远程推送证书**——通知为本地通知，不依赖 APNs。

### 11.5 系统框架依赖

| 类别 | 框架 | 说明 |
|------|------|------|
| 显式链接 | `AppIntents.framework`（Weak） | pbxproj 中唯一列出的框架，弱链接 |
| 自动链接 | SwiftUI、Combine、Foundation、UIKit、WebKit、AVKit/AVFoundation、Network（NWPathMonitor）、UserNotifications、LocalAuthentication、Security（Keychain）、CryptoKit（SHA256） | Xcode 默认自动链接 |
| 第三方依赖 | **零** | 无 Podfile / Package.swift / Carthage |

### 11.6 构建与运行

**Xcode GUI**：

1. 打开 [DesignCode.xcodeproj](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode.xcodeproj)；
2. 选择 Scheme `DesignCode` → 目标设备（本项目约定：真机“秦超的iPhone”，iOS 27.0 / UDID 00008110-000411A40EC1401E）；
3. `Cmd + R` 构建运行；`Cmd + U` 运行单元测试（或选 Scheme `DesignCodeTests`）。

**命令行（xcodebuild / xcrun）**：

```bash
# 真机构建（本项目约定设备；需签名 Team 可用）
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
  -configuration Debug -destination 'id=00008110-000411A40EC1401E' build

# 模拟器通用构建（仅供验证编译）
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build

# 运行单元测试（本项目约定：真机；当前 54 用例全绿）
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
  -configuration Debug -destination 'id=00008110-000411A40EC1401E' test
```

### 11.7 Info.plist 配置要点（[Info.plist](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/Info.plist)）

| 键 | 值 / 行为 |
|----|-----------|
| `CFBundleDisplayName` / `INFOPLIST_KEY_CFBundleDisplayName` | `园枢`（双通道注入，构建设置优先） |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.0` / `1` |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads = false`；仅 `sxjzit.edu.cn`（含子域）放行 HTTP 明文 |
| `NSFaceIDUsageDescription` | 生物识别用途声明（合规必需） |
| `UILaunchStoryboardName` | `LaunchScreen`（静态启动图，SplashView 做无缝过渡） |
| `UIRequiredDeviceCapabilities` | `arm64` |
| 方向 | iPhone：竖屏 + 左右横屏；`~ipad`：全 4 方向 |
| 深链/推送 | 无 `CFBundleURLTypes`、无 APNs 配置 |

### 11.8 运行环境特殊注意事项

1. **`-disable-sandbox` 编译旗标**（`OTHER_SWIFT_FLAGS`）：非常规设置，可能为规避沙箱写入限制所加；⚠️ 上线前必须评估移除（App Store 审核风险）。
2. **部署目标不一致**：project 层 13.0 / target 层 26.0，实际生效 26.0，与代码中 `if #available` 假设需对齐。
3. **`exit(0)` 调用**：[PrivacyPolicyView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyPolicyView.swift)，Apple 明确禁止主动退出，审核高风险。
4. **模拟器 vs 真机差异**：生物识别模块在模拟器需经 Xcode 菜单 `Features → Face ID → Enrolled` 注册；通知需真机验证横幅/角标行为。本项目交付验收约定以真机为准。
5. **首次运行隐私流程**：全新安装会进入隐私同意弹窗/受限模式，测试前如需跳过可提前把 `privacyConsentAccepted` 置真。
6. **构建产物与缓存目录**：`build/`、`.build/`（独立 SPM 调试产物）不应入库，建议补 `.gitignore`。

### 11.9 关键配置常量汇总

| 配置项 | 值 | 位置 |
|--------|-----|------|
| API 基地址 | `https://gwqietap.sxjzit.edu.cn/mapi` | NetworkService.swift（NetworkConfig） |
| 官网域名 | `https://www.sxjzit.edu.cn` | Models.swift |
| 招生网 siteId | `cb3b1fe4fcdf40999b0c162015c3326d` | DataService / NetworkService |
| 专业介绍 columnId | `25d7bd39e49a468880356e302b9ccf1d` | DataService.swift |
| 学校概况风光 columnId | `214e6c2b` | SchoolProfileView.swift |
| 校企合作 columnId | `cc7376c3`（`cc7376c390cb4aa4bc519c4858009630`，19 篇） | SchoolProfileView.swift（cooperationColumnId） |
| **校园日历 columnId** | `8197fe41503c4c32bce1e449d2492b2e`（复用 fetchArticles/fetchArticleDetail，siteId "1"） | NetworkService.swift（campusCalendarColumnId） |
| 党建/思政 site_key | `djgz`（党建工作）/ `mkszy`（思政专题） | PartySubjectView.swift / 官网 head 菜单 |
| 公告/协议站 | `https://www.43322.cn/blog/gonggao|terms|privacy-policy` | AnnouncementManager / PrivacyManager |
| 官网校长信箱页 | `https://www.sxjzit.edu.cn/#/opinion` | PrincipalMailboxView.swift |
| 诊断探测目标 | `https://gwqietap.sxjzit.edu.cn/mapi/common/column/head`（5 轮） | SJZNetworkMonitor.swift |
| 缓存目录 | `Documents/SXJZIT_Cache/` | DataService.swift |
| URLCache 容量 | 80MB 内存 / 400MB 磁盘 | DesignCodeApp.swift |
| 校验真机 | 秦超的iPhone，iOS 27.0，UDID 00008110-000411A40EC1401E | 项目约定 |

---

## 12. 工程约定与注意事项

### 12.1 必守约束（历史开发经验沉淀，含 2026-09-23 新教训）

1. **iOS 26 API 规避**：使用经典 `.tabItem`，不用 Liquid Glass `Tab(value:role:)`（曾致卡顿）。
2. **通知 delegate 必须用完成回调版**（`withCompletionHandler`），**禁用 async 版**——async 版在后台协作队列派发，点击通知触发主线程断言崩溃。
3. **通知点击不直接弹窗**：走 `pendingDeepLink`/`pendingMailboxDeepLink`/`pendingSchoolProfileDeepLink` + 延迟调度（等场景 active + Face ID 解锁 + 让出 runloop 350ms），切断系统回调同步链。
4. **数据三层降级**：远程 API → 本地缓存 → 静态兜底，任何网络失败不得导致白屏。
5. **网络容错**：15s 超时 + 2 次重试 + 资源 30s 超时；单栏目/单通道失败不影响整体；`URLError.cancelled` 一律不重试、不记 ERROR（仅 debug 日志），防止下拉刷新接管取消静默拉取误报失败。
6. **SwiftUI `.refreshable` 防取消误报**：刷新本体必须放独立 Task（`refreshDetached`）与手势任务解耦，识别 cancelled 为「被打断」而非失败。
7. **中文错误信息**：所有面向用户的错误文案必须是中文。
8. **contentShape(Rectangle())**：所有按钮与交互元素必备（触摸热区）。
9. **防盗链**：视频请求由 RefererHeaderURLProtocol 注入 Referer/UA。
10. **图片 URL**：相对转绝对、非 ASCII 编码、过滤 `file://`；缓存键用 SHA256。
11. **通知防轰炸**：每次最多 5 条、间隔 1 秒；信箱/概况通道**首次只建基线不推历史**。
12. **WebView 超时保护**：6s 超时、2s 慢加载警告；纯图片文章检测需同时看 `hasImageContent`。
13. **生物识别持久化分工**：开关/策略存 UserDefaults，启用令牌存 Keychain（WhenPasscodeSetThisDeviceOnly）。
14. **禁止模式**：`@AppStorage + didSet`（didSet 不可靠，但通知开关处已存在此模式，新代码勿仿效）；`@Sendable Task` 捕获 `inout` 参数。
15. **显示设置联动**：外观模式必须复用 `colorSchemePreference` 键；主题色注入根 `.tint`；新 UI 文本一律用 `displayText/displayFont` 系列修饰器。
16. **图片必须走 SJZCachedImage**：禁止裸 AsyncImage；缩略图统一 720px 降采样，详情 hero 用 1440px；解码图缓存键必须含规格，杜绝分辨率串味。
17. **缓存命中日志节流**：同一 URL 仅记录首见命中，滚动复用以精确计数代替刷屏。
18. **模块入场动画**：首页模块用 `SJZRevealOnce` 会话级去重 + 0.07s 递增延迟，滚动往返不得重播入场动画。
19. **App 图标铁律**：只能用户主动点击（系统确认弹窗）切换；资源 1024×1024 PNG、sRGB、无 alpha、直角；`AppIconAlt1~4` 名称三处严格一致；启动校准 `calibrateOnLaunch`。
20. **服务端动态结构的接口**（`/school/intro`、`/school/org`、`/dept/home2` nav、`/school/msg`）：必须在**运行时解析，严禁硬编码 ID/树形结构**；改版 DTO 前先用真实抓包 JSON 跑独立解码脚本验证层级——校长信箱两层 data 嵌套多建一层曾致 message_list 静默 nil（表现为“成功 0 条”空态且刷新无效），“成功但 0 条”的静默失败必须落 warning 日志（携带 page/notice 长度等线索）。
21. **单栏容错隔离**：党建/机构多栏目拉取必须每栏独立 try-catch（失败栏只影响自己，记 warning），服务端稳定 500 的容器型栏目不拖垮全站。
22. **常显入口型首页模块**（hasContent 恒 true 的校长信箱/党建/概况）必须从首页骨架屏条件中排除，否则冷启动骨架屏永不显示。
23. **生命周期修饰符挂载**：SwiftUI 的 `.task`/`.onAppear` 必须附加到持久锚点视图（例如带 `Color.clear` 的 ZStack），避免条件隐藏的 Group 导致修饰符永不执行。
24. **模拟/调试数据分仓**：与真实数据分仓存储（如信箱 simulateNewMail），否则懒加载/刷新会把内存模拟数据覆盖导致深链目标丢失。
25. **深链 push 用 `navigationDestination(isPresented:)`**（官方推荐），禁用 `NavigationStack(path:)` 编程 push（栈未挂载稳定时导航动作会被吞，表现为点了没反应）。
26. **机构搜索结果分页上限**：常规 4 页×50=200 条、深度 8 页×50=400 条，按服务端 total 动态分页（只拉最新 30 条的历史教训：老文章搜不到）。
27. **新三模块数据源约定**：信箱/党建/概况各自独立 Store 直连 NetworkService（不新增 DataService 门面方法），互不影响；SearchHistory 键分别为 `mailboxSearchHistory`/`partySearchHistory`/`profileSearchHistory`/`orgArticleSearchHistory`。
28. **图片保存到相册（2026-09-24 真机复现铁律）**：WebP 等格式 UIImage 经 `creationRequestForAsset(from:)` 写入必触发 **PHPhotosErrorDomain 3302（invalidResource）**——统一 JPEG 重编码 → 临时文件 → `PHAssetCreationRequest.addResource(.photo, fileURL:)` file-based 写入（`ProfileImageSaveShare`）。
29. **消息中心存储强原子写（2026-09-24 物证）**：文件 JSON 持久化必须「临时文件 + `replaceItemAt` 原子替换 + 写后读回自校验（失败重写）」；损坏备份用时间戳命名保留最近 5 份（固定名会被后续事件覆盖丢失首次现场）。
30. **SF Symbols 7 符号校验**：iOS 26/27 运行时已移除 `magnifyingglass.fill` 等旧符号（真机渲染为空）——新增符号前必须校验存在性，优先用 `sparkle.magnifyingglass`（iOS 15+ 兼容）。
31. **Swift 字符串 API 陷阱**：`String.ranges(of:options:)` 无 options 重载（编译解析到泛型无参版报 extra argument）——多词全命中高亮用 `range(of:options:range:)` while 循环推进 searchRange。
32. **搜索防抖空态防御**：防抖窗口内旧结果为空时不得显示「未找到」空态——需 `isSearchPending` 状态 +「正在搜索…」轻量指示（helpGuide/消息中心/校园日历同款）。
33. **静态矢量装饰层禁止 `drawingGroup()`**（2026-09-24 曾致真机疑似启动黑屏挂起）：iOS 26/27 Liquid Glass 合成下预光栅化与实时材质混用不可靠。
34. **120Hz 解锁**：Info.plist 必须含 `CADisableMinimumFrameDurationOnPhone = true`（官方文档：缺该键 iPhone ProMotion 滚动锁 60Hz）。
35. **模块退役必须处理旧值**：HomeModuleManager 退役值静态集 `retiredRawValues` + init 区分日志级别静默清理（warning 会反复触发）；helpGuide 相关文章模块总数文案与枚举成员数强耦合。

### 12.2 已知风险（修复前须知）

| 严重度 | 问题 | 位置 |
|--------|------|------|
| 高 | 部署目标 project(13.0)/target(26.0) 不一致 | project.pbxproj |
| 高 | `exit(0)` 强制退出（Apple 审核风险） | PrivacyPolicyView.swift |
| 高 | `OTHER_SWIFT_FLAGS = -disable-sandbox` 禁用 App 沙箱 | project.pbxproj |
| 中 | `@AppStorage + didSet`（违反自身约束） | NotificationManager.swift |
| 已修复 | ~~AnnouncementManager 网络失败时 `isLoading` 未复位（公告页转圈卡死）~~ → **已修复（2026-09-27：defer 复位，全部守卫分支覆盖）** | AnnouncementManager.fetchAnnouncement |
| 中 | Team ID 明文入库 | ExportOptions.plist |
| 低 | 巨型文件：TabBar 9,107 行（主界面+组件族+图标管理多职责）、OrganizationDetailView 5,268 行、OrganizationView 2,182 行——后续可考虑拆分 |
| 低 | 生产残留 `print()`、`ZSWArticle.id = articleId ?? UUID()` 非稳定 id、`NewsItem.id` 主键碰撞 | 多处 |
| 低 | LogManager「保留 7 天」伪语义（活跃日期快照驱动，爆量时 1-3 天即删）；crashCaptureEnabled 开关运行期无效 | LogManager.swift |
| 低 | 官网静态素材路径带内容哈希（`SchoolProfileAssets`），官网重新部署后需核对，否则校徽/海报 404 | SchoolProfileView.swift |
| 低 | SJZNetworkMonitor 为会话级不持久化（历史监测曲线重启即失） | SJZNetworkMonitor.swift |
| 低 | 消息中心删除日志误名「右滑删除」（实为左滑） | MessageCenterView.swift |

> 已修复（历史）：RefererHeaderURLProtocol 曾每请求新建 URLSession 导致无连接复用、URLCache 禁用导致图片不缓存——现已改共享静态会话 + 统一扩容 URLCache（80/400MB）+ 图片 7 天缓存头（见 §4.15）；机构搜索硬编码栏目 ID / 仅拉 30 条 / 缺内容页栏目 → 已改官网机构树 + 子站索引双通道 + 动态分页（§5.2）。

> **2026-09-27 修复（五项，真机 83/83 终验）**：① 机构降级搜索 4 个已失效硬编码栏目 ID（联网实测 500）→ `resolveMainSiteSearchColumns()` 运行时动态解析（OrganizationDetailView 两调用点共用，旧 ID 全库清零）；② AnnouncementManager `isLoading` 转圈卡死 → `defer` 复位（见上表）；③ 字体下载悬挂（实机日志实证）→ 60s 超时兜底 + 跨尝试令牌竞态防护（DisplaySettingsManager.ensureFontFamily，超时后二次实查自愈）；④ **图片「重复加载」根治**（实机日志时间线定案：URLCache 半失效条目 × 旧流程「预判→读不出→回落」每次进入重复代偿）→ 缓存读取改**直读+自愈**（`usableCachedResponse` 预判与读取一次完成、空数据体条目即时清理、解码失败安全回落不误删），全屏图同构改造，预取器升级为可用性判存并顺带自愈（消灭「预判命中→读不出」双击模式）；⑤ **警告误报治理**（67 条警告解剖：59 条图片「自动重试」里 30 条实为「取消被当失败」）→ 图片取消静默化（cancelled 不告警/不重试，对齐红线）+ 图片下载**全局并发闸 ≤4**（actor 发起前闸控，镜像站拥塞治理且 TTFB 不含排队）+ inactivity 超时 30s→15s 快速换道；netmon 慢请求/延迟指标全面改 **TTFB 口径**（大文件下载时长不再误判「链路慢」）；顺手清零 Swift 6 跨隔离既有警告（probeUserAgent nonisolated）。证据：`build/verify/retest_20260927_fix.log`、`retest_20260927_imgfix.log`、`retest_20260927_warnfix.log`。**实机复测（净化终版）**：警告 **67 → 3**——59 条图片「自动重试」误报归零（取消静默化生效，图片类警告清零）、超时告警归零；字体下载超时由 warning 降为 **INFO 状态流转**（已转「可重试」态、UI 橙色徽章承载可操作入口，日志级别语义分级：warning 只留待处理真异常）；余 2 条为 www2 真实慢观测（3.99MB 大图 TTFB 2.55s，属正常外部观测，按 TTFB 口径保留）。证据：`build/verify/retest_20260927_polish.log`（全量 0 error/0 warning + 真机 83/83）。

### 12.3 文档与工程卫生

- `README.md` 仍为原 DesignCode 模板内容（过时）；**本 CODE_WIKI.md 为权威参考**；`ARCHITECTURE.md`（项目技术全景报告）、`PROJECT_UNDERSTANDING.md`、`DEBUG_REPORT.md`、`FIX_PLAN*.md` 为过程性补充文档。
- `DesignCode_backup_20260922/` 为 2026-09-22 的完整快照备份（非编译目标，**不要**在其中改代码）；`build/`、`.build/` 为构建产物。
- 建议补 `.gitignore` 排除 `build/`、`.build/`、`xcuserdata`；Team ID 明文在 `ExportOptions.plist`，提交前注意脱敏。

---

> 本文档基于对源代码（39 个 Swift 文件 + 2 个测试文件，54 个单元用例）的全量静态分析生成，覆盖至 2026-09-24。行号引用可能随后续重构漂移，以文件内符号名为准。

---

## 附：2026-09-23 卡死事故记录（根因与修复）

- **现象**：前台 UI 卡死 9~10 秒（HangTracer 双报告：bug_type 222 @17:06、328 @17:13），锁屏后被 Jetsam 杀（bug_type 309，SIGKILL）。
- **根因**：`String.strippingHTMLTags()` 与 `AnnouncementManager.htmlToPlainText` 使用 `NSAttributedString(.documentType: .html)`——NSHTMLReader 经 WebKit 内部加载，主线程调用时递归等待主队列（`__NSThreadPerformPerform` ↔ `-[NSHTMLReader _loadUsingWebKit]` 死循环），主线程采样 100% 卡死。
- **修复**：strippingHTMLTags() 重写为纯正则（去 script/style → 块级标签换行 → 去标签 → 实体解码 → 空白清理，线程安全）；AnnouncementManager 复用之；DataService 启动预热增加 banner.posterImgSrc 的 http/https 前缀校验（服务端偶发返回键名 "video_poster" 造成 NSURLError -1002）。
- **工程红线**：全项目禁止 `NSAttributedString(data:options:[.documentType:.html])`，HTML→纯文本一律走纯正则 `strippingHTMLTags()`。