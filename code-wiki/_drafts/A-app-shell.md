# A · 应用外壳与导航层 — 深度分析草稿

> **分析范围（本文件唯一负责）**
> `qin/DesignCode/DesignCodeApp.swift`、`SplashView.swift`、`TabBar.swift`、`Info.plist`、`DesignCode.entitlements`
> **方法**：全部行号来自 `grep -n` / `read` 实测，未验证项单独标注「⚠未验证」。
> **行号基准**：仓库当前工作副本（`TabBar.swift` 13687 行 / 631,088 B）。

---

## 0. 摘要（TL;DR）

| 结论 | 依据 |
|---|---|
| 外壳是**单 Scene + 单 WindowGroup + ZStack 五层覆盖**结构，`MainTabView` 常驻渲染、`SplashView` 之上做淡出遮挡，用 `isAppReady` 一个布尔量做启动分流 | `DesignCodeApp.swift:40-196` |
| **全项目零 `@EnvironmentObject`**（`grep` 命中 0）：所有跨视图状态靠 **56 处 `@ObservedObject … .shared` 单例** + 少量 `@AppStorage` 直连 | `TabBar.swift` 内 `@ObservedObject`×56、`@StateObject`×0；全仓 `@EnvironmentObject`×0 |
| 真正的「环境注入」只有两条：`.displayTypography(displaySettings)`（排版/灰度根注入）与每处 presentation 的 `.sjzPresentationChrome()`（外观+灰度补注入） | `DesignCodeApp.swift:121`；`DisplaySettingsManager.swift:2068-2081`、`2105-2121` |
| Tab 栏是**经典 `.tabItem` + `.tag`**（5 个 tab），**没有自定义 TabBar 组件**；选中态由 `selection` 承担，且被首页快捷入口反向改写（4 处） | `TabBar.swift:180-211`、`844-847`、`1207` |
| 通知深链不是 URL Scheme，而是 **5 个 `@Published` 待办槽 + `onChange` 消费 + 延迟调度**；`MainTabView` 里 5 条 `onChange` 一一对应 5 类目的地 | `TabBar.swift:287-341`；`NotificationManager.swift:998-1107` |
| 点击通知防闪退的核心是 `scheduleNotificationArticlePresentation()`：**等待场景 active + Face ID 解锁 → 再 sleep 350ms → 才弹 sheet**，绝不在系统回调同步链弹窗 | `TabBar.swift:113-176` |
| `TabBar.swift` 是「主 Tab + 全部视图」的巨型单文件：**87 条顶层声明**（62 struct / 15 enum / 4 class / 1 actor / 5 extension），其中 `: View` 结构体 51 个 | 见 §6 全量清单 |
| 图片零闪烁管线（本文件最大技术资产）：**解码图内存缓存（NSCache）+ URLCache 磁盘缓存 + 全局并发闸 ≤4 + 智能预取 + 坏条目自愈 + 滚动让路** | `TabBar.swift:12110-12752` |
| 无全局 Alert/Toast/HUD 基础设施：3 处 `.alert` 全在 `SettingsView` 内；toast 只在 `DepartmentsView`(7363-7498) 与 `FacilityDetailView`(9133-9659) 各写一套；唯一 HUD 是 `FullScreenImageView` 的缩放倍率胶囊 | `TabBar.swift:11224/11230/11238`、`7363-7498`、`9133-9659`、`4270-4764` |

---

## 1. 文件清单与规模

| 文件 | 行数 | 字节 | 角色 |
|---|---|---|---|
| `qin/DesignCode/DesignCodeApp.swift` | 223（`wc -l`；末行无换行，编辑器计 224 行） | 11,052 | `@main` 入口、启动编排、隐私门控、场景生命周期 |
| `qin/DesignCode/SplashView.swift` | 125（编辑器 126 行） | 4,129 | 启动过渡层（与 `LaunchScreen.storyboard` 视觉对齐） |
| `qin/DesignCode/TabBar.swift` | **13,687** | 631,088 | 主 Tab + 60+ 视图 + 共享组件（全项目最大文件） |
| `qin/DesignCode/Info.plist` | 95 | 2,999 | 展示名「园枢」、URL Scheme、ATS 例外、FaceID/相册文案、微信三键 |
| `qin/DesignCode/DesignCode.entitlements` | 17 | 900 | 仅 Associated Domains（微信 Universal Link） |

同目录相关但**不属本文件**：`Base.lproj/LaunchScreen.storyboard`（`UILaunchStoryboardName` 指向）、`Assets.xcassets/splash_icon.imageset`。

---

## 2. `DesignCodeApp.swift` 深度分析

### 2.1 `@main` 与属性包装器（L9-20）

```swift
9:  @main
10: struct DesignCodeApp: App {
11:     @ObservedObject private var notificationManager = NotificationManager.shared
12:     @ObservedObject private var displaySettings = DisplaySettingsManager.shared
13:     @ObservedObject private var biometricSecurity = BiometricSecurityManager.shared
14:     @ObservedObject private var weChatService = WeChatService.shared
15:     @Environment(\.scenePhase) private var scenePhase
16:     @State private var isAppReady = false
17:     @AppStorage("privacyConsentAccepted") private var privacyConsentAccepted: Bool = false
18:     @AppStorage("privacyConsentRejected") private var privacyConsentRejected: Bool = false
```

要点：
- 入口结构体**不使用 `@StateObject`**，四个全局管理器都是 `@ObservedObject` + `.shared`（与全项目风格一致）。
- 这四个 `.shared` 的首次访问发生在属性初始化期，**早于 `init()` 方法体**——即 `NotificationManager.shared` 的单例构造（其 `init` 里做了 `UNUserNotificationCenter.current().delegate = self`，`NotificationManager.swift:196`）在 `DesignCodeApp.init()` 之前完成。
- 隐私状态用两个独立 `@AppStorage` 键表达三态：未表态 / 已同意 / 已拒绝（`privacyConsentAccepted` 与 `privacyConsentRejected` 可同时为 false）。

### 2.2 `init()` 初始化顺序（L22-38，严格 5 步）

| 序 | 行号 | 动作 | 目的 |
|---|---|---|---|
| 1 | 25-27 | `URLCache.shared = URLCache(memoryCapacity: 80MB, diskCapacity: 400MB, diskPath: "sxjzit_shared_cache")` | 放大系统级磁盘/内存缓存；协议层转发会话、`SJZCachedImage`、`AsyncImage` 共享 |
| 2 | 29 | `URLProtocol.registerClass(RefererHeaderURLProtocol.self)` | 为学校服务器请求自动补 `Referer`/`User-Agent` 绕过防盗链（实现见 `RefererHeaderURLProtocol.swift:18`，234 行） |
| 3 | 31 | `CacheModeManager.shared.registerMemoryWarningHandler()` | 内存警告降载（实现 `CacheModeManager.swift:425`） |
| 4 | 33 | `AppIconManager.shared.calibrateOnLaunch()` | 启动校准：以系统实际 `alternateIconName` 为准修正本地记录 |
| 5 | 34-37 | `LogManager.shared.info("ui", "App 启动", …)` | 启动埋点（version + urlCache 规格） |

顺序设计意图：**缓存与协议必须最先就绪**，否则后续任何网络/图片请求都会走到未被 Referer 包装的会话上。

### 2.3 `WindowGroup` 内 ZStack 层级表（L41-114）

| zIndex | 行号 | 视图 | 显示条件 |
|---|---|---|---|
| 0（默认） | 44-45 | `MainTabView().opacity(isAppReady ? 1 : 0)` | **始终渲染**（先建树，避免启动后首帧空窗） |
| 1 | 48-51 | `SplashView(isAppReady: $isAppReady)` | `!isAppReady` |
| 2 | 54-88 | `PrivacyConsentView(showConsent:consentAccepted:onAccept:onReject:isFromRestrictedMode:)` | `showPrivacyConsent` |
| 3 | 91-98 | `RestrictedModeView(showRestricted:showConsent:)` | `showRestrictedMode` |
| 3.5 | 112-113 | `WeChatBannerOverlay()` | 常驻（层级低于生物遮罩 → 锁定时自动被盖） |
| 4 | 101-109 | `BiometricLockOverlayView()` | `biometricSecurity.isEnabled && (state == .locked \|\| .authenticating) && privacyConsentAccepted && isAppReady && !showRestrictedMode` |

生物遮罩的五条件合取是**隐私顺序**的体现：未同意隐私 → 不弹 Face ID；启动页未结束 → 不弹；受限模式 → 不弹。

### 2.4 `isAppReady` 启动分流

- L115-119 `.task`：`Task.sleep(1.0s)` → `isAppReady = true`（注释明确「不人为延时，仅等待启动动画自然完成」，但存在 1.0s 固定等待）。
- L146-158 `.task(id: isAppReady)`：刷新通知授权状态 → 条件满足则恢复轮询（`privacyConsentAccepted && isAuthorized && isEnabled`）→ `#if DEBUG` 自测钩子。
- L168-194 `.onChange(of: isAppReady)`：**启动后的隐私分流**——`!accepted && rejected` → 0.5s 后进受限模式；`!accepted && !rejected` → 0.5s 后弹隐私弹窗；`accepted` → 正常启动（仅日志）。
- 延时封装：`showPrivacyConsentAfterDelay()` L198-209、`showRestrictedModeAfterDelay()` L211-222（均 `@MainActor` + `Task.sleep(0.5s)` + `withAnimation(.easeInOut(0.35))`）。

### 2.5 隐私同意门控（三条独立路径）

| 触发 | 行号 | 行为 |
|---|---|---|
| 用户点「同意」 | 58-68 | 记日志（区分 `restricted_to_normal` 与 `first_launch`）→ `privacyConsentRejected = false` |
| 用户点「拒绝」 | 69-83 | `notificationManager.stopPolling()` → `privacyConsentRejected = true` → `asyncAfter(0.35s)` 动画展示受限模式 |
| 微信 SDK 注册 | 159-167 | `.task(id: privacyConsentAccepted)`：`guard privacyConsentAccepted else { 记 debug 日志并 return }` → 只有同意后才 `registerIfNeeded(reason: "privacy_consent")` |

另有 UI 文案侧门控：`PrivacyConsentView(..., isFromRestrictedMode: privacyConsentRejected)`（L84）。

### 2.6 `scenePhase` 处理（L129-145）

| 阶段 | 行号 | 动作 |
|---|---|---|
| `.background` | 131-137 | `biometricSecurity.handleDidEnterBackground()`；`LogManager.shared.flushPendingNow()` 立即落盘待写日志（防进程回收丢最近 0.5s） |
| `.active` | 138-141 | `biometricSecurity.handleReturnToForeground()`；`weChatService.refreshAvailability()`（用户可能刚装/升级微信） |
| default | 142-143 | break |

### 2.7 通知 delegate 绑定（**不在本文件**，重要澄清）

- `DesignCodeApp.swift` **没有**出现 `UNUserNotificationCenter.current().delegate = …`。
- 绑定发生在单例初始化内：`NotificationManager.swift:196`（类声明 `final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate` 在 `NotificationManager.swift:105`）。
- 触发时机：`DesignCodeApp.swift:11` 的属性包装器首次访问 `.shared`，即**早于 `init()` 方法体**（见 §2.1）。因此「通知 delegate 晚绑定」的隐患不存在，但也意味着**无法从 App 入口看到绑定关系**，排查时须跳到 `NotificationManager`。

### 2.8 DeepLink / URL 入口处理（L122-128）

| 入口 | 行号 | 处理 |
|---|---|---|
| `.onOpenURL` | 123-125 | `weChatService.handle(openURL: url)` —— URL Scheme 通道 |
| `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` | 126-128 | `weChatService.handle(userActivity: activity)` —— Universal Link 通道 |

两条微信回跳通道统一交给 `WeChatService` 回执中枢（官方要求双通道）。**注意**：`TabBar.swift` 的 5 类通知深链走的是 `NotificationManager` 的 `@Published` 状态，与这里的 URL 深链是**两套独立体系**（详见 §9）。

### 2.9 DEBUG 自测钩子（L153-157）

```
153: #if DEBUG
154: // devicectl device process launch <UDID> com.qinchao -- -uiTestBookmarkDeepLink
156: await BookmarkDeepLinkSelfTest.runIfRequested()
157: #endif
```
- 实现：`BookmarkManager.swift:1222`（`enum BookmarkDeepLinkSelfTest`）。
- 作用：触发收藏更新并走完双路径深链归因，回执落盘供 `Scripts/bookmark_deeplink_selftest.py` 取回。
- 另一处 DEBUG 钩子在 `TabBar.swift:9995-10000`（`-uiTestOpenLogs` 自动打开日志页 + `9904` 截图取证），**不在本文件**。

### 2.10 body 修饰器链全清单

| 行号 | 修饰器 | 说明 |
|---|---|---|
| 120 | `.tint(displaySettings.themeStyle.color)` | 主题色（环境值，自动穿透到 presentation） |
| 121 | `.displayTypography(displaySettings)` | **排版 + 灰度根注入**（`DisplaySettingsManager.swift:2008` 定义，`2065-2083` 实现） |
| 123-125 | `.onOpenURL` | 微信 URL Scheme |
| 126-128 | `.onContinueUserActivity` | 微信 Universal Link |
| 129-145 | `.onChange(of: scenePhase)` | 生命周期 |
| 146-158 | `.task(id: isAppReady)` | 通知授权刷新 + 轮询恢复 + DEBUG 钩子 |
| 159-167 | `.task(id: privacyConsentAccepted)` | 微信 SDK 注册门控 |
| 168-194 | `.onChange(of: isAppReady)` | 隐私分流 |

---

## 3. `SplashView.swift` 分析

| 项 | 行号 | 说明 |
|---|---|---|
| 类型声明 | 16 | `struct SplashView: View`，唯一对外接口 `@Binding var isAppReady: Bool` |
| 配色 | 27-31 | 浅色品牌海军蓝 `060D24→0C1F4A→1A56B8`；深色近黑 `05050A→0D0F17→151A26`（无缝融入暗色 UI） |
| 背景 | 36-41 | `LinearGradient` + `ignoresSafeArea()`，注释声明与 `LaunchScreen.storyboard` 完全一致 |
| 内容 | 44-90 | 校徽 `splash_icon`(80×80) → 校名「山西晋中理工学院」→ 校训「谨信博学 经世致用」→ 英文名 → `SINCE 2002` |
| 入场动画 | 95-104 | 图标 `spring(0.6, 0.7)` 缩放 0.8→1.0；文字 `easeOut(0.5).delay(0.15)` 渐显 + scale 0.92→1.0 |
| 淡出 | 105-112 | `onChange(of: isAppReady)`：`opacity→0`、`scale→1.05`、`easeInOut(0.35)` |
| 预览 | 118-125 | `#Preview("浅色模式")` / `#Preview("深色模式")` |

字体走自有注入：`.displayFont(28, weight: .bold)`（非系统 `Text` 默认字体），说明启动页也已接入 `DisplaySettingsManager` 的排版环境。

---

## 4. `MainTabView`（`TabBar.swift:15-431`）

### 4.1 Tab 结构（L180-211，经典 `.tabItem`，共 5 个）

| tag | 行号 | 根视图 | 图标 | 标签 | 备注 |
|---|---|---|---|---|---|
| 0 | 181-185 | `NavigationStack { HomeView(selection: $selection) }` | `house.fill` | 首页 | 唯一接收 `selection` 绑定 |
| 1 | 187-191 | `NavigationStack { DepartmentsView() }` | `building.2.fill` | 院系 | |
| 2 | 193-197 | `NavigationStack { NewsListView() }` | `newspaper.fill` | 资讯 | |
| 3 | 199-203 | `NavigationStack { CampusView() }` | `map.fill` | 校园 | |
| 4 | 205-210 | `NavigationStack { ProfileView() }` | `person.fill` | 我的 | `.badge(messageCenterStore.unreadCount > 0 ? unreadCount : 0)`（L209） |

- **结论：使用经典 `.tabItem` + `.tag`，不存在自定义 TabBar 组件**（全文件 `.tabItem` 出现 5 次，均在 182-206；无 `TabViewStyle` 自定义、无自定义底部栏结构）。
- Tab 切换副作用（L212-219）：轻触觉反馈 `UIImpactFeedbackGenerator(.light)` + 日志 `tabNames = ["首页","院系","资讯","校园","我的"]`。
- 首屏数据（L220-223）：`.task` 延迟 0.5s 后 `data.syncIfNeeded()`。
- 反向改写 tab 的 4+1 处：`HomeView` 快捷入口 `844-847`（院系查询→1、新闻资讯→2、校园服务/校园荣誉→3、招生就业/学校概况→4）、`1207`（「学校要闻」区块标题 → `selection = 2`）。
- `selection` 声明在 L16（`@State private var selection = 0`），通过 `@Binding var selection: Int`（L550）下传首页。

### 4.2 状态与订阅（L16-39）

- `@State`：`selection`(16)、`showDebug`(17)、`pendingNotificationArticle: NewsItem?`(26)、`showNotificationArticle`(27)、`notificationPresentationTask: Task<Void,Never>?`(28)、`showMailboxFromNotification`(30)、`pendingMailboxMessageID: Int?`(32)、`showSchoolProfileSheet`(33)、`showPartySubjectSheet`(36)、`showOrgArticleFromNotification`(38)、`pendingOrgArticle: PendingOrgArticleDeepLink?`(39)。
- `@ObservedObject`（4 个单例）：`DataService.shared`(18)、`BiometricSecurityManager.shared`(19)、`NotificationManager.shared`(20)、`MessageCenterStore.shared`(21)。
- `@AppStorage("colorSchemePreference")`(22) → `resolvedColorScheme`(41-47)：`"light"/"dark"/默认 nil`。
- `@Environment(\.scenePhase)`(23)；辅助 `scenePhaseText`(423-430) 供日志。

### 4.3 `pendingDeepLink` 调度机制（核心，L49-176 + L284-341）

**五通道总表**

| # | 目的地 | 源 `@Published`（NotificationManager） | 消费点（TabBar.swift） | 承载 `@State` | 呈现 |
|---|---|---|---|---|---|
| 1 | 文章详情 | `pendingDeepLink: PendingArticleDeepLink?`（NM:140） | `consumePendingDeepLink`（51-80）；绑定 `onAppear:287`、`onChange:290-295` | `pendingNotificationArticle`(26) | `.sheet` 342-352 |
| 2 | 校长信箱信件 | `pendingMailboxDeepLink: Int?`（NM:142） | 内联 `onChange` 296-306 | `pendingMailboxMessageID`(32) | `.sheet` 353-361 |
| 3 | 学校概况 | `pendingSchoolProfileDeepLink: Bool`（NM:144） | 内联 `onChange` 307-315 | `showSchoolProfileSheet`(33) | `.sheet` 362-379 |
| 4 | 党建专题 | `pendingPartySubjectDeepLink: Bool`（NM:146） | 内联 `onChange` 316-324 | `showPartySubjectSheet`(36) | `.sheet` 380-396 |
| 5 | 机构动态文章 | `pendingOrgArticleDeepLink: PendingOrgArticleDeepLink?`（NM:148） | `consumePendingOrgArticleDeepLink`（85-111）；绑定 `onAppear:288`、`onChange:325-327` | `pendingOrgArticle`(39) | `.sheet` 397-419 |

**`consumePendingDeepLink`（L51-80）确切逻辑**
1. `guard let link`（52）→ 组装 `NewsItem(title:date:"":category:summary:"":articleId:)`（53-55）；
2. **并行预加载**：`DataService.shared.preloadArticleDetail(articleId:)`（58）+ 日志（59-61）——利用等待 Face ID/场景激活的间隙秒开；
3. 若 sheet 已打开（`showNotificationArticle == true`，63）：**原地替换内容** `pendingNotificationArticle = article` → 回执 `.presented`（66）→ `return`（避免重复弹出）；
4. 否则登记待展示（72）→ debug 日志携带 `scenePhase` / `lockEngaged`（73-78）→ `scheduleNotificationArticlePresentation()`（79）。

**`scheduleNotificationArticlePresentation`（L116-176）确切时序**

| 阶段 | 行号 | 逻辑 |
|---|---|---|
| 前置守卫 | 117-119 | 需 `pendingNotificationArticle != nil`、`!showNotificationArticle`、`articleId` 非空 |
| 取消旧任务 | 120 | `notificationPresentationTask?.cancel()`（单飞，防重复调度） |
| 主循环等待 | 130-135 | 每 100ms 轮询，**最多 30 次（≈3s）**，条件：`scenePhase != .active \|\| biometricSecurity.isLockEngaged` |
| 超时判定 | 146-163 | 仍不满足 → 按原因分类（"等待应用进入前台超时" / "等待 Face ID 解锁超时" / "等待展示条件超时"）→ 回执 `deepLinkOutcome = .failed(articleId:reason:)`（161）→ **保持待展示状态**，等 scenePhase/biometric 事件重新调度 |
| 让出 runloop | 165 | `Task.sleep(350ms)`，注释：避免在生命周期/回调同步链中弹窗 |
| 弹出 | 166-168 | 二次校验 `!Task.isCancelled, pendingNotificationArticle != nil` → `showNotificationArticle = true` |
| 回执 | 169-174 | `deepLinkOutcome = .presented(articleId:)` + `timeline` 日志 |

**补发调度点**（关键设计：多处「重新调度」入口）
- `onAppear` L284-289：冷启动点击通知时 `didReceive` 可能早于视图出现 → 补消费 `pendingDeepLink` 与 `pendingOrgArticleDeepLink`；
- `onChange(of: scenePhase)` L328-335：`newPhase == .active` → 重新 `scheduleNotificationArticlePresentation()` + `messageCenterStore.handleSceneActive()`（30 分钟节流的站内检查）；
- `onChange(of: biometricSecurity.state)` L336-341：`newState == .unlocked` → 重新调度。

**其他三通道的「让出同步链」手法**：机构动态（95-110）先置 `pendingOrgArticleDeepLink = nil` 再 `Task{ @MainActor }` 同样 100ms×30 轮询 + 300ms settle；信箱/概况/党建（300-324）统一 `Task{ @MainActor }` + `sleep(400ms)` 后置 flag。

**回执类型** `DeepLinkOutcome`（`NotificationManager.swift:78`，`.presented/.failed`）供通知测试页回显成败。

### 4.4 sheet / fullScreenCover 呈现点

**`MainTabView` 自身 5 处（全部 `.sheet`，无 fullScreenCover）**：342（文章详情，`NavigationStack{EnhancedNewsDetailView}`）、353（`MailboxSheetRoot`）、362（`NavigationStack{SchoolProfileView}` + 自定义关闭按钮）、380（`NavigationStack{PartySubjectView}`）、397（`NavigationStack{OrganizationArticleDetailView(article:siteId:color:)}`，用 `OrganizationCategory(rawValue:)?.color ?? .sjzAccent` 还原机构主题色）。**5 处全部挂 `.sjzPresentationChrome()`**（350/360/378/395/417）。

**全文件 38 处呈现点**（`.sheet` 31 + `.fullScreenCover` 7），明细见附录 A。其中内容级呈现点均挂 chrome，**唯一豁免的 6 处是系统分享面板**（`ShareSheet(items:)`，L3397/3431/5278/5913/6478/7047），与 `DisplaySettingsManager.swift:2104` 的承诺「系统分享面板属系统 UI，不在承诺范围」一致。

### 4.5 注入链（本层最重要的架构事实）

1. **环境对象注入：不存在。** 全仓 `grep '@EnvironmentObject'` = 0 命中；`TabBar.swift` 无 `.environmentObject(...)`。跨视图共享一律 `XxxManager.shared` + `@ObservedObject`（`TabBar.swift` 内 `@ObservedObject` 出现 **56** 次，`@StateObject` **0** 次）。
2. **真正的 `.environment` 注入只有 1 个自定义键、2 处使用**：
   - 键定义 `SJZScrollSuspendedKey`（12043-12045，默认 `false`）+ `EnvironmentValues.sjzImageLoadingSuspended`（12047-12053）；
   - 注入点：`HomeView` L621、`NewsListView` L7777 —— `.environment(\.sjzImageLoadingSuspended, isScrolling)`（配合 `.sjzScrollSuspendTrack($isScrolling)` L620 / L7776 的 iOS 18 `onScrollPhaseChange` 跟踪）。
3. **外观模式注入（两处）**：
   - 根：`MainTabView` L283 `.preferredColorScheme(resolvedColorScheme)`（本地 `@AppStorage` 读值，**不是** `DisplaySettingsManager.appearanceMode`）；
   - presentation 补注入：`.sjzPresentationChrome()`（`DisplaySettingsManager.swift:2105-2121`）内部用 `displaySettings.appearanceMode.resolvedColorScheme` + `.saturation(...)`。
   - 二者口径**不同源**（一个读 `colorSchemePreference`、一个读 `appearanceMode`）——见 §10 风险 R2。
4. **专注灰度「双注入」机制**（`DisplaySettingsManager.swift`）：
   - 根注入：`.displayTypography(displaySettings)`（`DesignCodeApp.swift:121`）→ `DisplayTypographyModifier.body` 内 `.saturation(manager.grayScaleEnabled ? 0 : 1)` + `.animation(.easeInOut(0.4))`（2079-2081）；
   - presentation 注入：`.sjzPresentationChrome()` → `.preferredColorScheme(...)` + `.saturation(...)` + 同款动画（2108-2113）；
   - 原因（源码注释 2100-2104）：`.preferredColorScheme` 与 `.saturation` 属**渲染/呈现修饰器而非环境值**，根视图注入链不会传播进 sheet/fullScreenCover，因此必须逐 presentation 单独挂载——这是「全链审计强制项」。
   - `TabBar.swift` 内共 **32 处** `.sjzPresentationChrome()` 调用。
   - 灰度开关本体：`DisplaySettingsManager.swift:798-806`（`grayScaleEnabled`）、UI 在 `DisplaySettingsView.swift:2043-2062`。
5. **排版注入**：`.displayTypography` 一次注入 7 个环境键（`displayFontScale` / `displayBold` / `displayFontFamily` / `displayLetterSpacing` / `displayLineSpacing` / `displayTypographyRevision` / `sizeCategory`）+ `.shapedButtonStyle` + 灰度（2071-2081）。

### 4.6 全局 Alert / Toast / HUD 现状

- **`.alert` 仅 3 处，且全在 `SettingsView`**：11224「确认清空缓存？」、11230「确认标记全部已读？」、11238「确认清空全部收藏？」。**没有 App 级 alert 中枢**。
- **无全局 Toast 组件**：`toastText` + `toastTask` 在每个视图内重复声明，共两套实现——`DepartmentsView`（状态 7366-7367、`presentToast` 7475-7484、`toastOverlay` 7486-7498）、`FacilityDetailView`（状态 9134-9135、触发 9607/9642、`presentToast` 9648-9657、`toastOverlay` 9659+）。`EnhancedNewsDetailView` 无 toast，改用加载遮罩 `longImageLoadingOverlay`(3453) 与 `detailTopProgressBar`(3491)。
- **HUD**：`FullScreenImageView` 内部缩放倍率 HUD（`showZoomHUD` 4271、`zoomHUDTask` 4272、渲染 4736-4750、`presentZoomHUD` 4751-4754、`scheduleZoomHUDHide` 4755-4762，停手 1.4s 自动淡出）。
- 全局浮层替代品：`MainTabView` 内置**调试面板 + 调试入口**（`showDebug`，226-281：`ant.fill` 悬浮按钮、`ultraThinMaterial` 卡片、`PrincipalMailboxStore.simulateNewMail()`、`syncLog` 展示）——注意**未包在 `#if DEBUG` 内**（全文件 `#if DEBUG` 仅 9904 / 9995 / 13371 三处），属可见的调试后门（见风险 R4）。

### 4.7 状态管理方式与结论

| 维度 | 现状 |
|---|---|
| 状态载体 | `@State`（视图内）+ `@ObservedObject … .shared`（56 处）+ `@AppStorage`（少量，如 22、`privacyConsentAccepted`）；**无 `@StateObject`、无 `@EnvironmentObject`、无 ViewModel 层** |
| 数据流 | 单向但「共享单例直读」；跨模块通信用 `@Published` + `onChange`（深链）与 `NotificationCenter` 的替代品（源码注释：`@Published` 状态驱动替代 NotificationCenter 广播，L49） |
| 异步 | 一律 `Task { @MainActor in … }` + `Task.sleep` 显式让出 runloop；长任务用 `Task` 句柄可取消（`notificationPresentationTask` L28/L120） |
| Tab 栏实现 | **经典 `.tabItem` + `.tag` + `.badge`**，非自定义 TabBar；无 `.tabViewStyle`、无自绘底栏 |
| 视图传参 | 以 `let` 值类型为主（`news`/`honor`/`facility`/`department`…），靠单例补数据 |

---

## 5. `Info.plist` 与 `DesignCode.entitlements`

### 5.1 Info.plist（95 行）

| 键 | 行号 | 值 / 作用 |
|---|---|---|
| `CADisableMinimumFrameDurationOnPhone` | 5-6 | `true`（120Hz ProMotion 解锁） |
| `CFBundleDisplayName` | 9-10 | **园枢** |
| `CFBundleLocalizations` | 17-22 | `zh-Hans` / `en` / `Base` |
| `CFBundleShortVersionString` / `CFBundleVersion` | 27-28 / 42-43 | `1.0` / `1` |
| `CFBundleURLTypes` | 29-41 | 单一 URL Scheme = `$(WECHAT_APPID)`，`CFBundleURLName = weixin`（微信回跳） |
| `LSApplicationQueriesSchemes` | 44-49 | `weixin` / `weixinULAPI` / `weixinURLParamsAPI` |
| `NSAppTransportSecurity` | 52-66 | `NSAllowsArbitraryLoads = false`；仅对 `sxjzit.edu.cn` 开 `NSExceptionAllowsInsecureHTTPLoads` + `NSIncludesSubdomains`（**HTTP 例外被限制在单域**，是安全亮点） |
| `NSFaceIDUsageDescription` | 67-68 | 生物识别解锁说明（强调数据不出安全芯片） |
| `NSPhotoLibraryAddUsageDescription` | 69-70 | 仅写入相册（保存校园图/校徽），明示不读取 |
| `UILaunchStoryboardName` | 71-72 | `LaunchScreen`（与 `SplashView` 视觉对齐的另一半） |
| `UIRequiredDeviceCapabilities` | 73-76 | `arm64` |
| `UISupportedInterfaceOrientations` | 77-82 | 竖屏 + 左/右横屏（**无 `PortraitUpsideDown`**） |
| `UISupportedInterfaceOrientations~ipad` | 83-89 | 四方向 |
| `WeChatMiniProgramID` / `WeChatUniversalLink` | 90-93 | `$(WECHAT_MINI_PROGRAM)` / `$(WECHAT_UNIVERSAL_LINK)` |

**注意**：Info.plist 中**没有** `CFBundleIcons` / `CFBundleAlternateIcons` 段（应用图标切换依赖 Xcode 的 alternate app icon 构建设置，见 §8 ⚠未验证）。

### 5.2 DesignCode.entitlements（17 行）

- 仅一项能力：`com.apple.developer.associated-domains` = `applinks:$(WECHAT_UL_HOST)`（L14-17）。
- 注释（L4-12）说明：域名须与「微信开放平台 Universal Link」及服务器 AASA（`https://<域名>/.well-known/apple-app-site-association`）完全一致；只需改构建设置 `WECHAT_UL_HOST`，本文件自动替换。
- 未申请任何推送 entitlement（无 `aps-environment`）——与「本地通知轮询」的实现路线一致（`NotificationManager` 侧确认，超出本文件范围）。

---

## 6. `TabBar.swift` 全量类型清单（**本次最重要产出**）

**总计 87 条顶层声明**（86 个唯一名称：`SJZCachedImage` 有「主声明 + 同文件扩展」两处）：

| 类别 | 数量 |
|---|---|
| `struct` | 62（其中 `: View` **51**、`ViewModifier`/`ButtonStyle`/`Representable` 5） |
| `enum` | 15 |
| `final class` | 4 |
| `actor` | 1 |
| `extension` | 5（`UIColor` / `Color` / `EnvironmentValues` / `View` / `SJZCachedImage`） |

> 与其他 agent 共享的 `parts/type-index-raw.txt` 相比，本表**多出 5 条 extension**（435 / 460 / 12047 / 12070 / 12360），该索引未收录扩展声明，建议合并时补齐。

### 6.1 外壳 / 导航 / 视觉基础（6）

| 行号 | 类型 | 职责 |
|---|---|---|
| 15 | `struct MainTabView: View` | 主 Tab 容器；5 tab、5 条深链 `onChange`、5 处 sheet、调试面板（420 行） |
| 435 | `private extension UIColor` | `convenience init(hex:)` 十六进制色 |
| 460 | `extension Color` | `init(lightHex:darkHex:)` 动态双色 + 品牌语义色（`sjzAccent`/`sjzTeal`/`sjzGold`/`sjzPrimary`/`sjzLight`/`sjzRed` 等，40 行） |
| 500 | `struct GradientBackground: View` | 全局滚动背景（systemGroupedBackground + sjzLight 渐变） |
| 510 | `struct ShimmerView: View` | 通用微光扫过（`@State phase`，35 行） |
| 12753 | `enum SJZDesignTokens` | 视觉令牌：`accentGradient` / `successGradient` / 胶囊描边等 |

### 6.2 首页（4）

| 行号 | 类型 | 职责 |
|---|---|---|
| 545 | `struct HomeView: View` | 首页根（`@Binding selection`）；`heroBannerSection`→`statsRowSection`→`quickActionsSection`→`helpGuideAnchorSection`→动态模块区（567-591）；骨架 `homeModuleSkeleton`(1164)；模块渲染 `moduleSection`(1204)；`hasContent`(1135)；`showHomeSkeleton`(1157)；快捷入口改 tab（844-847）；`.sjzScrollSuspendTrack`(620) |
| 755 | `private struct HeroSlideDecoration: View` | Hero 装饰层轻量版（避免 GeometryReader；暗色自适应透明度） |
| 1985 | `struct CategoryBadge: View` | 分类徽章（按 `category` 着色） |
| 2023 | `struct VideoPlayerView: View` | `AVPlayer` 视频播放器（`player`/`playerItem` 状态 + 生命周期） |

### 6.3 资讯 / 文章详情 / 分享长图（13）

| 行号 | 类型 | 职责 |
|---|---|---|
| 2158 | `enum ShareFormat: Identifiable` | 分享格式：`link` / `markdown` / `fullText`（+ longImage，见 3397 分支） |
| 2179 | `struct ArticleLongImageAsset` | 长图素材：压缩 `data` + `pixelSize` + `alt`（不整图解码） |
| 2191 | `@MainActor enum ArticleLongImageLoader` | 长图素材加载器：`maxConcurrent = 3`、`loadAll(_:tag:)` 保序返回、`pixelSize(of:)` ImageIO 头解析、`orientedPixelSize` |
| 2313 | `enum SJZImageIntegrity` | 产物完整性校验：`isLikelyBlank(_:)` 三载（UIImage/CGImage/Data），32×32 网格采样 + `rangeThreshold = 8` 判纯色/黑图 |
| 2430 | `@MainActor enum SJZShareFileCenter` | 分享临时文件生命周期：`retention = 300s`、`staleInterval = 600s`、`scheduleCleanup` / `cleanupStale` |
| 2476 | `struct ArticleLongImageRenderer` | 长图渲染器（503 行）：`budget(...)` 渲染倍率预算（`preferredScale 3`、`maxPixelHeight 48_000`、`maxRenderBytes 288MB`、`memoryUseRatio 0.35`）、`render()` 降级阶梯（降倍率→省略插图）、`renderOnce`、`draw(in:)` 品牌头/标题/元数据/正文/插图/页脚、`decodeThumbnail` |
| 2979 | `struct ShareSheet: UIViewControllerRepresentable` | `UIActivityViewController` 封装（兼容微信） |
| 2997 | `enum LoadingPhase: Equatable, CustomStringConvertible` | 分段加载阶段：`initializing`→`checkingCache`→`fetchingNetwork`→… |
| 3044 | `struct EnhancedNewsDetailView: View` | **增强版新闻详情**（879 行）：`loadDetail`(3506)、`LoadingPhase` 驱动、`galleryLoadedIndices` 画廊进度、`showCachedBadge`、`slowNetworkMessage`、`handleGalleryPhase`(3626)、Markdown 生成(3687)、长图生成(3730)、`WeChatShareMenu`/`WeChatLongImageShareMenu`/`ShareSheet`/`FullScreenImageView` 四类呈现 |
| 3923 | `private struct ArticleSkeletonRows` | 文章骨架行（`skeletonBar(widthMultiplier:height:)`） |
| 3958 | `private struct PhasedProgressIndicator` | 分段加载进度指示（`Timer.publish(0.1s)` 计时文案 + 渐变环，127 行） |
| 4085 | `private struct PhaseProgressDots` | 阶段进度圆点（`LoadingPhase` 索引映射） |
| 7640 | `struct NewsListView: View` | 资讯 tab 根（297 行）：分类标签栏(7709)、列表、搜索、新闻行(7816)、`.sjzScrollSuspendTrack`(7776) |

### 6.4 详情页族 / 内容页（14）

| 行号 | 类型 | 职责 |
|---|---|---|
| 4883 | `struct WebViewContainer: View` | WKWebView 容器 + 加载态/错误态 |
| 4965 | `struct WebView: UIViewRepresentable` | `WKWebView` 桥接（含 `Coordinator: WKNavigationDelegate` @4989） |
| 5019 | `struct HonorDetailView: View` | 荣誉详情（573 行，含长图生成 5351） |
| 5592 | `struct SceneryDetailView: View` | 校园风光详情（`showFullscreen` 单图全屏） |
| 5665 | `struct TeacherDetailView: View` | 教师风采详情（562 行，长图 5986） |
| 6227 | `struct StoryDetailView: View` | 学生故事详情（565 行，长图 6551） |
| 6792 | `struct ActivityDetailView: View` | 校园活动详情（569 行，长图 7120） |
| 9115 | `struct FacilityDetailView: View` | 设施详情（649 行）：`wheelPosition` 分区目录轮播（9327-9400 全出血玻璃轮播 + `carouselCard`）、滚动进度条、悬浮定位胶囊、回顶、toast |
| 7361 | `struct DepartmentsView: View` | 院系 tab 根（横幅入场/计数滚动/刷新 toast） |
| 7501 | `struct DepartmentDetailView: View` | 院系详情 |
| 7605 | `struct MajorDetailView: View` | 专业详情（小视图 35 行） |
| 11264 | `struct ZSWHomeView: View` | 招生网首页（287 行；三栏目 11323、通用栏目 11402、报考指南 Tab 11494） |
| 11551 / 11697 | `struct ZSWArticleListView` / `ZSWArticleDetailView` | 招生网文章列表 / 详情 |

### 6.5 校园 / 卡片组件族（10）

| 行号 | 类型 | 职责 |
|---|---|---|
| 7937 | `struct CampusView: View` | 校园 tab 根（430 行）：14 个 section —— `servicesSection`(7962)、`facilitiesSection`(8001)、`organizationSection`(8034)、`campusScenerySection`(8062)、`campusActivitiesSection`(8107)、`videosInCampus`(8146)、`videoPlaceholder`(8189)、`teachersInCampus`(8198)、`storiesInCampus`(8236)、`schoolInfoSection`(8274)、`linksSection`(8295)、`socialSection`(8336)、日历入口 `showCalendar`(7940) |
| 8367 | `private struct ServiceButton` | 校园服务按钮（`service`/`index`/`accent`） |
| 8437 | `private struct OrganizationEntryCard` | 机构设置入口横幅卡（indigo 渐变 + 水印 + 呼吸动效 + 微光扫过 + 弹簧入场） |
| 8533 | `private struct SchoolInfoCard` | 学校概况档案卡（298 行：校名带 + 档案行 8686 + 招生电话一键拨打 8763 + 地址复制） |
| 8831 | `private struct FooterLinkRow` | 友情链接行（左侧滑入错峰） |
| 8909 | `private struct SocialQRCard` | 二维码卡（点按保存到相册：转圈/绿勾/红字三态） |
| 9039 | `private struct DepartmentCard` | 院系卡（主题渐变图标 + 双呼吸 + 徽章） |
| 9764 | `private struct FacilityPressStyle: ButtonStyle` | 按压动效样式（下沉 0.97 + 弹簧回弹，多处共用） |
| 9775 | `private struct FacilityCardLabel` | 设施列表卡 |
| 9835 | `private struct InfoRow` | 标签-值行（17 行） |

> 说明：`AboutEntryCell`(10197) 与 `MenuCard`(10248) 虽属组件族，但语义归属「我的」页，统一列于 §6.9，此处不重复计数。

### 6.6 全屏看图族（4）

| 行号 | 类型 | 职责 |
|---|---|---|
| 4117 | `struct SJZImageGalleryPayload: Identifiable` | 看图载荷（item 式，根治「先显示第一张」陈旧快照）：`urls`/`alts`/`startIndex`/`source`；`single(url:)`、`make(images:tappedIndex:source:)`（跳过非法 URL 并重映射落点）、`clampedStartIndex` |
| 4153 | `enum SJZPageTurn: Equatable` | 翻页判定 `.next/.previous/.none`（纯函数输出，供测试） |
| 4160 | `enum SJZImageViewerGeometry` | 看图几何纯函数：`fittedSize` / `maxOffset` / `clamped` / `clampedScale` / `anchoredOffset` / `pageTurnDecision`（80 行） |
| 4240 | `struct FullScreenImageView: View` | 全屏看图（643 行）：`MagnifyGesture`+`DragGesture`（4445-4509）、锚点缩放与绝对位移平移、橡皮筋回弹 `settlePanDrag`(4510)、翻页 `finishPageDrag`(4534)/`turnPage`(4557)、`resetZoomForNewPage`(4591)、相邻页预取 `prefetchAdjacentPages`(4599)、缩放 HUD、`loadedImage/isLoading/loadError/downloadProgress/isFromCache` 自管加载态 |

### 6.7 图片缓存管线（**零闪烁核心**，17）

| 行号 | 类型 | 职责 |
|---|---|---|
| 12043 | `struct SJZScrollSuspendedKey: EnvironmentKey` | 滚动暂停图片加载的环境键（E10 帧率优先），默认 `false` |
| 12047 | `extension EnvironmentValues` | `sjzImageLoadingSuspended` 读写 |
| 12056 | `struct SJZScrollSuspendModifier: ViewModifier` | iOS 18+ `onScrollPhaseChange` 跟踪滚动态，低版本零影响 |
| 12070 | `extension View` | `.sjzScrollSuspendTrack(_:)` |
| 12078 | `enum SJZImagePhase` | 与 `AsyncImagePhase` 对齐：`.empty(progress: Double?)` / `.success(Image)` / `.failure` / `.skipped` |
| 12088 | `struct SJZImageFreePlaceholder: View` | 无图模式统一占位（静态渐变 + 图标，省电省流） |
| 12110 | `struct SJZCachedImage<Content: View>: View` | **统一图片加载器**（250 行）：URL + `maxPixel` 降采样 + 三态闭包；`init` 同步查内存缓存决定首帧（12136-12146）；`.task(id: SJZLoadToken)` 驱动（12166）；失败态透明遮罩承接轻点重试（12155-12163） |
| 12360 | `extension SJZCachedImage` | 链式 `.onPhaseChange(_:)`（供画廊计数条） |
| 12369 | `enum SJZImageKit` | 工具集（119 行）：`defaultThumbnailPixel = 720`、`imageSession`(12394)、`makeRequest`(12405，15s inactivity 超时 + 缓存策略随模式)、`usableCachedResponse`(12420，**坏条目清理自愈**)、`isCancellation`(12436，取消不告警不重试)、`memoryGuardPixelCount = 40_000_000`(12445)、`decode`(12448，ImageIO 降采样 + E4 护栏强制 4096) |
| 12488 | `struct SJZLoadToken: Hashable` | 加载任务标识（url + attempt + freeMode），驱动重启 |
| 12495 | `enum SJZImageError: Error` | `decodeFailed` |
| 12501 | `final class SJZImageDownloadDelegate: NSObject, URLSessionDataDelegate` | 下载进度委托（百分比节流上报） |
| 12528 | `enum SJZAverageColorCache` | 平均色缓存（`maxEntries = 300` + NSLock）：8×8 重绘采样求均值 → blur-up 占位 |
| 12586 | `private final class SJZDecodedImageBox: NSObject` | NSCache 条目（cost 按像素字节计费） |
| 12596 | `final class SJZDecodedImageCache: @unchecked Sendable` | **解码图内存缓存**：NSCache + `OSAllocatedUnfairLock` 守护限额；键 = URL + 降采样边长；**双档限额**（缓存模式 96MB/600 张，即时模式 40MB/200 张）；`refreshLimits` / `removeAll` / `totalCostLimitBytes` |
| 12661 | `actor SJZImageConcurrencyGate` | 全局图片下载并发闸 `limit = 4`（发起前闸控：URLSession 不排队，TTFB 不含排队时延） |
| 12685 | `@MainActor enum SJZImagePrefetcher` | 智能预取：可用性判存（2xx 且数据非空）→ 半失效条目清理自愈并纳入预取 → 分批（`maxConcurrent = 4`）并发 → 汇总日志 |

### 6.8 进度 / 状态 / 揭示动画（7）

| 行号 | 类型 | 职责 |
|---|---|---|
| 12783 | `struct SJZPageLoadProgressBar: View` | 顶部悬浮真实进度条（八彩光谱 + `hueRotation` 3.2s 循环，≥99.5% 切成功渐变 + bounce 打勾） |
| 12876 | `struct SJZGalleryProgressBar: View` | 画廊计数条（`loaded`/`total`，HIG 确定型进度 + `isDone`） |
| 12921 | `struct SJZSlowNetworkBanner: View` | 弱网提示胶囊（E7） |
| 12944 | `struct SJZCachedBadge: View` | 缓存徽标（E3） |
| 12968 | `struct SJZArticleLoadingView: View` | 文章加载态（`phases` 相位文案轮播 + 渐变进度 + 已用时） |
| 13043 | `enum SJZRevealRegistry` | 会话级揭示登记（NSLock + `Set<String>`，跨视图实例去重） |
| 13060 | `struct SJZRevealOnce: ViewModifier` | 首次出现弹簧错峰入场；`logReveal` 默认 true（日志页必须传 false，防自反馈风暴） |

### 6.9 我的 / 设置 / 关于（5）

| 行号 | 类型 | 职责 |
|---|---|---|
| 9852 | `struct ProfileView: View` | 我的 tab 根（345 行）：`profileHeader`(10027)、`AnnouncementBanner`(9960)、`menuCards`(10058)、`dataStatusBadge`(10112)、`contactSection`(10133)、`linksPreview`(10161)、`versionInfo`(10183)；**6 处 sheet**（9970-9985）；DEBUG 截图 9904-… |
| 10197 | `private struct AboutEntryCell` | 「我的」学校概况豪华入口行（黄金徽章 + 光晕呼吸） |
| 10248 | `private struct MenuCard` | 「我的」菜单卡（`badge: Int?` 支持角标、`subtitle`） |
| 10294 | `struct AboutView: View` | 关于页（184 行） |
| 10478 | `struct SettingsView: View` | 设置总入口（786 行）：显示设置(10584)、应用图标(10630)、首页管理(10651)、微信集成(10674)、安全中心(10701)、学校官网更新通知(10724)、文章管理(10870)、收藏设置(10899)、网络监测(10965)、缓存模式(11036)、应用日志(11085)、数据管理(11116)、数据概览(11126)、隐私与协议(11154)、关于(11178)；3 处 `.alert`(11224/11230/11238) |

### 6.10 专业介绍（3）

| 行号 | 类型 | 职责 |
|---|---|---|
| 13108 | `struct SpecialtyListView: View` | 专业介绍列表（102 行） |
| 13210 | `struct SpecialtyCollegeDetailView: View` | 学院专业详情（`selectedMajor` sheet @13289） |
| 13310 | `struct SpecialtyMajorDetailView: View` | 专业详情弹窗 |

### 6.11 应用图标（4）

| 行号 | 类型 | 职责 |
|---|---|---|
| 13380 | `struct AppIconItem: Identifiable, Equatable` | 备选图标条目（`key: String?`，nil = 主图标） |
| 13390 | `enum AppIconSwitchError: LocalizedError` | `.unsupported` |
| 13403 | `@MainActor final class AppIconManager: ObservableObject` | 图标管理器（124 行），见 §8 |
| 13527 | `struct AppIconSettingsView: View` | 3 列网格选择页（状态头 13570、单格预览 13595、内联错误 13657） |

---

## 7. 共享 UI 组件族详解

### 7.1 `SJZCachedImage` 图片缓存管线（零闪烁核心）

**两级缓存 + 三条命中路径**（`load()` L12178-12296）：

| 阶段 | 行号 | 机制 |
|---|---|---|
| 0 初始化直出 | 12136-12146 | `init` 内**同步**查 `SJZDecodedImageCache`（键 = URL + maxPixel），命中则 `State(initialValue: .success(...))` → **首帧即出图**，滚动回收重建无占位帧；无图模式直接 `.skipped` |
| ① 内存命中 | 12210-12214 | `SJZDecodedImageCache.image(forKey:)` → `finishSuccess(fromMemory: true)`（不再回写、不淡入） |
| ①′ 磁盘命中 | 12233-12246 | `SJZImageKit.usableCachedResponse`（2xx 且数据非空）→ `decode` 成功即呈现；解码失败**不删缓存**（防误删健康条目），回落网络由新响应覆盖 |
| ② 网络加载 | 12248-12295 | 并发闸 → `SJZImageDownloadDelegate` 百分比进度 → `decode`；失败重试 **1s / 3s 指数退避最多 2 次**（`for retry in 0...2`）；取消类错误静默退出 |

- **无图模式短路**（12189-12207）：完全不起网络 + `CacheModeManager.shared.recordImageSkipped()` 计数（每 URL 仅首见记日志）。
- **滚动让路 E10**（12217-12224）：`loadingSuspended` 时最多等 800ms（100ms 步进），静止后恢复。
- **缓存模式联动**（12121 `@ObservedObject cacheManager`）：缓存开启 → `returnCacheDataElseLoad`；关闭 → `useProtocolCachePolicy`（12410-12412）；内存限额双档（12596 类注释）。
- **降采样**：默认 720px（12373）；`maxPixel: nil` 走原图但受 E4 护栏（>4000 万像素强制 4096，12445/12459-12468），`ImageIO` 缩略解码在 `Task.detached(priority: .userInitiated)` 执行（12449）。
- **blur-up 渐进占位**：成功后 `Task.detached(priority: .utility)` 算平均色入 `SJZAverageColorCache`（12319-12326），二次访问以近似色调占位消除白闪。
- **呈现差异**：命中（内存/磁盘）**不淡入**；网络加载才 `withAnimation(.easeOut(0.3))`（12327-12334）。
- **统计与日志**：命中记 `recordImageHit` + 省流量 `recordSavedTraffic(bytes:)`；未命中记 `recordImageMiss`；命中日志按 key 去重节流（`SJZImageKit.shouldLogHit`，12385-12393 / 12341）。
- **自愈**：`usableCachedResponse` 对「索引存在但数据体为空/损坏」的半失效条目即时 `removeCachedResponse`（12424-12430）；预取器同样清理并重新纳入预取（12695-12701）。
- **失败 UX**：透明遮罩承接「轻点重试」`attempt += 1`（12155-12163），仅失败态存在、成功态不拦截外部手势。

### 7.2 长图（分享长图）组件族

链路：`ArticleLongImageLoader`（下载压缩数据 + ImageIO 头解析尺寸，有界并发 3，保序）→ `ArticleLongImageRenderer`（`budget` 倍率预算 → `render` 降级阶梯 → `renderOnce`/`draw`）→ `SJZImageIntegrity.isLikelyBlank`（三级产物校验：渲染画布 / 编码候选 / 最终 JPEG）→ `SJZShareFileCenter`（临时文件保活 300s + 清理 600s 以上的陈旧文件，防与微信扩展读取竞态）→ `ShareSheet` / `WeChatLongImageShareMenu`（`WeChatIntegrationViews.swift:365`）。

关键防线（源码注释 2476-2484、2506-2568）：
- 画布自适应：`preferredScale 3`、`maxPixelHeight 48_000`、`maxRenderBytes 288MB`、`memoryUseRatio 0.35`、`minScale 0.5`，用 `os_proc_available_memory()`（`availableMemoryBytes()`，2564-2571）算可用内存；
- 插图按需缩略解码（`decodeThumbnail` 2904，绝不 N 张全尺寸驻留）；
- 失效降级：降倍率 → 省略插图逐级重试，全链日志留痕，绝不把黑图交给分享。

### 7.3 全屏看图组件族

`SJZImageGalleryPayload`（item 式载荷，支持整组翻页）→ `FullScreenImageView`（缩放/平移/翻页/橡皮筋/HUD/相邻预取）→ 几何纯函数 `SJZImageViewerGeometry` + 翻页判定 `SJZPageTurn`（与单元测试共用）。呈现点：`EnhancedNewsDetailView`(3434)、`HonorDetailView`(5294)、`TeacherDetailView`(5929)、`StoryDetailView`(6494)、`ActivityDetailView`(7063)、`FacilityDetailView`(11909)。

### 7.4 骨架屏 / 占位 / 进度 / 状态

| 名称 | 行号 | 归属 |
|---|---|---|
| `ShimmerView` | 510 | 通用微光 |
| `ArticleSkeletonRows` | 3923 | 文章骨架 |
| `homeModuleSkeleton` | 1164 | 首页模块骨架 |
| `SJZImageFreePlaceholder` | 12088 | 无图模式占位 |
| `SJZArticleLoadingView` | 12968 | 文章加载态 |
| `PhasedProgressIndicator` | 3958 | 分段加载进度 |
| `PhaseProgressDots` | 4085 | 阶段圆点 |
| `SJZPageLoadProgressBar` | 12783 | 页级彩虹进度条 |
| `SJZGalleryProgressBar` | 12876 | 画廊计数条 |
| `SJZSlowNetworkBanner` | 12921 | 弱网提示 |
| `SJZCachedBadge` | 12944 | 缓存徽标 |
| `SJZRevealOnce` / `SJZRevealRegistry` | 13060 / 13043 | 错峰揭示 |

### 7.5 图表

**结论：`TabBar.swift` 内不存在图表组件**——`grep 'Chart|图表|BarChart|PieChart|Sparkline'` 零命中；唯一的 Canvas/绘制型能力是 `ArticleLongImageRenderer.draw(in:)`（离屏 UIKit 绘制）与 `SJZImageIntegrity` 的采样回读，均非数据可视化。进度类可视化由 §7.4 的进度条/环形承担。

### 7.6 Banner / 轮播

| 组件 | 行号 | 事实 |
|---|---|---|
| 首页 Hero Banner | 683-751 | **静态单页**，源码注释明确「避免 ScrollView 内嵌 TabView 性能问题」；`heroSlide` 只有渐变背景 + `HeroSlideDecoration` + 校名/英文名/校训，`frame(height: 420)`；`data.banners` 仅在调试面板与设置概览里以计数出现（240 / 11144） |
| 设施详情分区轮播 | 9327-9400 | 真正的横向轮播：全出血 `ScrollView` + `scrollPosition` 绑定（9119/9121）+ 两侧留白 `9363` + `carouselCard`(9390) + Liquid Glass 主题色染色 + 选中放大 |

**因此「Banner 轮播组件」在本文件并不存在**：首页走静态 Hero，唯一的轮播实现在设施详情页内联（非独立类型）。

### 7.7 设计令牌与视觉效果

`SJZDesignTokens`（12753，`accentGradient`/`successGradient`/描边规格）；`glassEffect` 在文件内出现 7 次（Liquid Glass 风格胶囊/卡片）；`Color` 扩展（460）提供 `sjz*` 语义色并随明暗自适应。

---

## 8. `AppIconManager`（应用图标切换）

**位置**：`TabBar.swift:13377-13522`（`MARK: - 应用图标切换（Alternate App Icons）`），选择页 `AppIconSettingsView` 13527-13687 尾部。

| 能力 | 行号 | 逻辑 |
|---|---|---|
| 可选集合 | 13411-13417 | 5 项：`nil`（默认/经典深蓝）、`AppIconAlt1`（星夜）、`AppIconAlt2`（晨曦）、`AppIconAlt3`（极简）、`AppIconAlt4`（金典），各带 `previewImageName`（`IconPreviewPrimary/Alt1…Alt4`，资源已存在于 `Assets.xcassets`） |
| 发布状态 | 13422-13427 | `isSwitching`（防连点）、`lastErrorMessage`、`activeIconName`（系统实际生效值快照） |
| 能力探测 | 13432 | `UIApplication.shared.supportsAlternateIcons` |
| 持久化 | 13408 / 13435-13438 | `UserDefaults` 键 `appIconSelection`（`""` = 主图标），**失败不改写** → 选中态自然回滚 |
| 启动校准 | 13457-13472 | `calibrateOnLaunch()`：读系统值，与本地不一致则写回 + info 日志（覆盖卸载重装/系统重置） |
| 首屏真实状态 | 13447-13449 | `refreshFromSystem()` 直接读 `alternateIconName` |
| 切换 | 13477-13521 | ① 不支持 → 报错返回；② 目标 == 当前 → 直接成功回调（跳过）；③ `isSwitching = true` → `UIApplication.shared.setAlternateIconName(name)` → **completion 内 `Task { @MainActor in }` 切主线程**：失败只记错误、成功才 `persistedSelection = target` + `activeIconName` 更新 |
| 展示名 | 13441-13444 | `currentDisplayName`（设置页副标题；未知 key 回落「自定义」） |

调用点：`DesignCodeApp.swift:33`（启动校准）、`SettingsView` 的「应用图标」段（10630 附近）、选择页 13527+。
⚠未验证：备选图标名是否已在 Xcode 构建设置（`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` / `CFBundleIcons`）登记——`Info.plist` 内**无** `CFBundleAlternateIcons` 段，需查 `project.pbxproj`（本次未纳入范围）。

---

## 9. 深链（DeepLink）体系：五类目的地如何路由

**两套互不相干的体系**：
1. **微信回跳**（`DesignCodeApp.swift:123-128`，URL Scheme + Universal Link）→ `WeChatService`；
2. **本地通知点击深链**（本仓库主用法）→ `NotificationManager` 的 5 个 `@Published` 槽 → `MainTabView` 消费。

**统一入口**：`NotificationManager.handleNotificationTap(userInfo:actionIdentifier:source:)`（`NotificationManager.swift:998-1107`），按 `userInfo` 键**优先级顺序** `return` 短路：

| 优先级 | 判定键 | 行号(NM) | 写入槽 | MainTabView 消费 | 目的地视图 |
|---|---|---|---|---|---|
| 1 | `schoolProfileDeepLink == true` | 1006-1014 | `pendingSchoolProfileDeepLink = true` | `onChange` 307-315（sleep 400ms） | `SchoolProfileView`（sheet 362） |
| 2 | `partySubjectDeepLink == true` | 1018-1027 | `pendingPartySubjectDeepLink = true` | `onChange` 316-324（sleep 400ms） | `PartySubjectView`（sheet 380） |
| 3 | `orgArticleId: String` 非空 | 1030-1053 | `pendingOrgArticleDeepLink = PendingOrgArticleDeepLink(...)` | `consumePendingOrgArticleDeepLink` 85-111（100ms×30 轮询场景+解锁 → 300ms） | `OrganizationArticleDetailView`（sheet 397，含 `siteId`/`categoryRaw` 归因色） |
| 4 | `mailboxId: String` 非空 | 1056-1070 | `pendingMailboxDeepLink = Int(mailboxId)` | `onChange` 296-306（sleep 400ms） | `MailboxSheetRoot(messageID:)`（sheet 353） |
| 5（兜底） | `articleId: String` | 1072-1106 | `pendingDeepLink = PendingArticleDeepLink(articleId:category:title:source:)` | `consumePendingDeepLink` 51-80 + 调度 116-176 | `EnhancedNewsDetailView`（sheet 342） |

配套细节：
- 每条通道在 NM 内先 `MessageCenterStore.shared.markRead(...)`（1012/1024/1044/1067/1096-1099），未读角标与 `.badge`（TabBar:209）联动；
- 无 `articleId` 的纯送达通知只记 warning 不跳转（1088-1093）；
- `isBookmarkUpdate == true` 时改走收藏更新已读（1095-1099）——DEBUG 自测 `BookmarkDeepLinkSelfTest`（`BookmarkManager.swift:1222`）走这条；
- 成败回执 `DeepLinkOutcome`（NM:78）由 MainTabView 在 `.presented`(66/169) 与 `.failed`(161) 处回写，供通知测试页展示；
- **防闪退三原则**（贯穿 51-176 与 296-324）：① 从不在系统回调同步链弹窗；② 一律等待 `scenePhase == .active` 且 `!isLockEngaged`；③ 弹窗前额外 sleep 300-400ms 让出 runloop。

---

## 10. 关键结论与风险提示

- **C1 单文件巨石**：`TabBar.swift` 13,687 行承载 87 个声明、51 个 View；外壳（`MainTabView`）仅占 15-431 行，**其余 97% 是内容视图**。文件切分是首要可维护性债。
- **C2 无依赖注入层**：0 个 `@EnvironmentObject`、56 处 `.shared` 直连、0 个 `@StateObject` → 预览/测试替换困难；`#Preview` 全文件仅 1 处且 `#if DEBUG` 包裹（13371-13375）。
- **R1 隐私门控边界正确但耦合入口**：隐私三态由 `AppStorage` 双键 + 视图内 flag 表达，逻辑正确；风险在于状态机散落在 `.onChange(of: isAppReady)`（168-194）与两个 `asyncAfter`/`Task.sleep` 延时函数里，无单一权威。
- **R2 外观模式双源**：根注入读 `@AppStorage("colorSchemePreference")`（TabBar:22/283），presentation 注入读 `DisplaySettingsManager.shared.appearanceMode`（`DisplaySettingsManager.swift:2110`）。若两处取值口径不一致，会出现「主界面浅色 / 弹出页深色」的分裂。⚠未验证：`DisplaySettingsManager` 是否把 `colorSchemePreference` 作为 `appearanceMode` 的唯一写入方（属「日志与显示设置」agent 范围）。
- **R3 固定延时**：启动 1.0s（`DesignCodeApp.swift:117`）、隐私/受限模式前置 0.5s（`DesignCodeApp.swift:201/214`）、MainTabView 首屏同步 0.5s（TabBar:221）、深链让出 300/350/400ms 若干 —— 仅 `MainTabView`(1-431) 内 `Task.sleep` 即 8 处；低端机/冷启动下是潜在时序脆弱点（深链调度有 3s 上限兜底 + 事件补发，属可接受）。
- **R4 调试面板常驻**：`MainTabView` 的 `ant.fill` 调试入口与面板（226-281）**未被 `#if DEBUG` 包裹**，含 `simulateNewMail()` 与 `syncLog` 展示，Release 构建下仍可见可点。
- **R5 chrome 审计成立**：38 处呈现点中 32 处显式挂 `.sjzPresentationChrome()`，其余 6 处全为系统分享面板（豁免有据）。这是本层少见的「有明确不变量 + 有源码注释固化」的工程实践。
- **R6 通知深链 5 通道竞态**：同一次点击若 `userInfo` 同时含多键，按优先级短路（NM:998-1107），语义确定；但 5 个槽位彼此独立，若极短时间内连点多条通知，后到的会覆盖前一个未消费槽（`pendingDeepLink` 为可选单值）——⚠未验证：`MessageCenterView` 侧是否有排队/串行化（属「通知与收藏」agent 范围）。

---

## 11. 未验证 / 待补清单

| # | 项 | 原因 |
|---|---|---|
| U1 | 备选应用图标是否已在构建设置登记（`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`）；`Info.plist` 无 `CFBundleAlternateIcons` 段 | 需查 `project.pbxproj`，超出本次文件范围 |
| U2 | `DisplaySettingsManager.appearanceMode` 与 `@AppStorage("colorSchemePreference")` 的同步关系（R2） | 属「日志与显示设置」agent 文件 |
| U3 | `RefererHeaderURLProtocol` 的完整实现与 `AVPlayer` 防盗链场景 | 属「数据/网络层」agent（本文件仅记录 `DesignCodeApp.swift:29` 注册点） |
| U4 | `NotificationManager` 五槽位的竞态与串行化（R6） | 属「通知与收藏」agent |
| U5 | Icon 资源 `AppIconAlt1-4.appiconset` / `IconPreview*.imageset` 的实际像素规格与是否完整 | 未逐个解析 `Contents.json` |
| U6 | `SplashView` 与 `LaunchScreen.storyboard` 视觉是否逐像素一致（源码注释声称一致） | 需真机/模拟器截图比对，本次为静态分析 |
| U7 | `SettingsView` 内部 15 个分区的行为细节 | 属「设置类视图」agent（本文件仅在类型清单中登记 10478-11262 及分区行号） |
| U8 | `MainTabView` 的 1.0s 启动等待是否会与 `SplashView` 淡出动画（0.35s）叠加出白屏空档 | 需真机录制验证 |

---

## 附录 A：`TabBar.swift` 呈现点全量清单（38 处）

| 行号 | 修饰器 | 宿主 | 内容 | chrome |
|---|---|---|---|---|
| 342 | sheet | MainTabView | `NavigationStack{EnhancedNewsDetailView}`（通知文章） | ✅ 350 |
| 353 | sheet | MainTabView | `MailboxSheetRoot`（通知信件） | ✅ 360 |
| 362 | sheet | MainTabView | `NavigationStack{SchoolProfileView}` | ✅ 378 |
| 380 | sheet | MainTabView | `NavigationStack{PartySubjectView}` | ✅ 395 |
| 397 | sheet | MainTabView | `NavigationStack{OrganizationArticleDetailView}` | ✅ 417 |
| 646 | sheet(item) | HomeView | `NavigationStack{HelpArticleDetailView}` | ✅ 650 |
| 3389 | sheet | EnhancedNewsDetailView | `WeChatShareMenu` | ✅ 3391 |
| 3393 | sheet(item) | 同上 | `WeChatLongImageShareMenu` | ✅ 3395 |
| 3397 | sheet(item) | 同上 | `ShareSheet`（系统面板） | 豁免 |
| 3403 | sheet | 同上 | `WebViewContainer`（原文阅读） | ✅ 3429 |
| 3431 | sheet | 同上 | `ShareSheet`（系统面板） | 豁免 |
| 3434 | fullScreenCover(item) | 同上 | `FullScreenImageView` | ✅ 3436 |
| 5270 / 5274 / 5278 / 5294 | sheet ×3 + cover | HonorDetailView | 微信分享 / 长图 / 系统 / 看图 | 除 5278 外 ✅ |
| 5641 | fullScreenCover | SceneryDetailView | 单图全屏 | ✅ 5647 |
| 5905 / 5909 / 5913 / 5929 | 同 Honor 模式 | TeacherDetailView | 同上 | 除 5913 外 ✅ |
| 6470 / 6474 / 6478 / 6494 | 同上 | StoryDetailView | 同上 | 除 6478 外 ✅ |
| 7039 / 7043 / 7047 / 7063 | 同上 | ActivityDetailView | 同上 | 除 7047 外 ✅ |
| 9970 | sheet | ProfileView | `SettingsView` | ✅（同行） |
| 9971 | sheet | ProfileView | `AboutView` | ✅（同行） |
| 9972 | sheet | ProfileView | `BookmarkListView` | ✅ 9973 |
| 9975 | sheet | ProfileView | `LogListView` | ✅ 9976 |
| 9978 | sheet | ProfileView | `AnnouncementDetailView` | ✅ 9979 |
| 9981 | sheet | ProfileView | `MessageCenterView` | ✅ 9984 |
| 11246 | sheet | SettingsView | 隐私政策 | ✅ 11250 |
| 11909 | fullScreenCover(item) | FacilityDetailView | `FullScreenImageView` | ✅ 11911 |
| 13289 | sheet(item) | SpecialtyCollegeDetailView | `SpecialtyMajorDetailView` | ✅ 13293 |

（另：`MainTabView` 调试面板 226-281 为条件浮层，非 presentation。）

## 附录 B：行号快速索引（外壳关键锚点）

| 主题 | 锚点 |
|---|---|
| `@main` / init 5 步 | `DesignCodeApp.swift:9` / `22-38` |
| ZStack 层级 | `DesignCodeApp.swift:42-114` |
| isAppReady 分流 | `DesignCodeApp.swift:115-119`、`146-158`、`168-194` |
| 隐私门控 | `DesignCodeApp.swift:17-20`、`54-98`、`159-167` |
| scenePhase | `DesignCodeApp.swift:129-145` |
| 微信回跳 | `DesignCodeApp.swift:122-128` |
| DEBUG 钩子 | `DesignCodeApp.swift:153-157` → `BookmarkManager.swift:1222` |
| TabView 五 tab | `TabBar.swift:180-211` |
| 深链消费/调度 | `TabBar.swift:51-80`、`85-111`、`113-176` |
| 深链绑定点 | `TabBar.swift:284-341` |
| 5 处深链 sheet | `TabBar.swift:342-419` |
| 外观/灰度双注入 | `TabBar.swift:283` + `DisplaySettingsManager.swift:2008`、`2065-2083`、`2105-2121` |
| 图片管线 | `TabBar.swift:12110-12752`（组件 12110 / 工具 12369 / 内存缓存 12596 / 闸 12661 / 预取 12685） |
| 长图族 | `TabBar.swift:2191`、`2313`、`2430`、`2476` |
| 看图族 | `TabBar.swift:4117`、`4153`、`4160`、`4240` |
| AppIconManager | `TabBar.swift:13377-13522`；选择页 13527+；启动校准调用 `DesignCodeApp.swift:33` |
| 唯一 Preview | `TabBar.swift:13371-13375`（`#if DEBUG`） |
