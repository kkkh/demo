# 消息中心（App 内通知盒子）实施计划 v6（五轮边界条件收口修订版）

## Context

「园枢」App 有多个本地通知通道（新闻 / 校长信箱 / 学校概况 / 党建专题 + **收藏更新**），但用户一旦清掉系统通知就无从回看。本次在「我的」页新增**消息中心**：App 内回看全部推送事件历史，点击深链直达对应内容（复用现有通知点击分发链路），且**独立于系统通知开关**（手动/自动静默检测，站内信语义）。要求：UI 完美高级（Liquid Glass、弹簧动画、错峰入场、触觉反馈）、功能完备、完整日志埋点（module: `messageCenter`）、存储损坏自愈、快速修复机制、无障碍细节、后续新通道可扩展、不影响现有功能、真机验收（秦超的iPhone，构建 0 错 0 警）。

## v6 五轮边界条件收口修订摘要（本轮回查测试隔离/幂等/id 稳定性/跨 sheet 竞态等实现级边界）

1. **「点击必达」闭环增强**：历史消息（含系统通知导入）深链点击时，若 DataService 无对应 NewsItem → launch 前现场 `fetchArticleDetail` 构造 NewsItem（复用通知测试中心 ensureRealTestArticle 的兜底思想，NotificationManager L827-861），成功走 TabBar 既有展示链，失败走 launchFailed 行内提示。新闻消息点击 100% 可达。
2. **测试隔离确定性**：Store `init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard)` —— 同时注入存储目录与 UserDefaults 实例（suiteName），单测互不污染；shared 用默认值。
3. **未读计数混合策略**：单条路径增量维护（ingest+1 / markRead-1 幂等，重复调用零副作用——消息中心行点击与 handleNotificationTap 双触发场景已覆盖）；bulk 操作（clearHistory/delete/导入/FIFO 截断/设置上限变更）后 `recomputeUnread()` O(n) 全量兜底（n≤200 无压力）。
4. **上限变更即截断**：设置面板修改上限 → 立即 applyMaxCount 截断（对齐 BookmarkManager.applyMaxCountLimit 先例）。
5. **跨 sheet 竞态明确化**：消息中心开着时用户点击系统横幅 → 详情 sheet 叠在消息中心 sheet 之上（iOS 原生堆叠行为，与主流 App 一致），关闭详情回到消息中心——接受并写明；不叠加 dismiss（避免误关用户上下文）。
6. **幂等与 id 稳定性**：markRead/ingest 全幂等；同秒多消息排序按 Date 精度稳定（倒序插入即有序）；导入与本地合并按 id 去重。
7. **@MainActor 并发安全审计**：NotificationManager/MessageCenterStore 均 @MainActor 隔离，ingest/markRead 调用点全在主线程上下文（checkNewsUpdates 等方法位于 @MainActor 类内），无跨隔离调用风险；同 module 循环引用 Swift 天然支持。

**延续 v5**（第五通道收藏更新接入 + 全工程 9 处通知源审计闭环、getDeliveredNotifications 升级历史导入、Tab 未读徽章、无深链详情卡、行长按复制/分享、筛选批量已读、消息中心设置面板）**、v4**（组件私有性实证、swipeActions、display 字体、MenuCard）、**v3/v2**（静默检测与自动站内检查、写盘、深链竞态、诊断面板、日分组/搜索/清空分级/无障碍等全部先前列项）。

## 终局审计结论（探索收敛说明）

经六轮迭代审查，全部可静态验证维度已闭环：**数据层**（写盘丢单/损坏自愈/版本迁移/FIFO/测试隔离/导入去重）、**通知链路**（9 处通知源全域审计/第五通道接入/静默检测 5 处短路/已读站外联动/升级历史导入）、**深链链路**（防闪退复用/竞态防抖/点击必达 fetch 兜底/失败降级）、**UI 层**（组件私有性实证/字体联动/swipeActions/日分组/搜索/清空分级/无障碍/多状态空态/禁用态）、**体验层**（错峰入场/弹簧/触觉/相对时间鲜活/Tab+桌面双层角标/长按操作/设置面板/诊断修复面板）、**工程层**（pbxproj 四段注册/0 警 0 错/新用例/真机验收 8 项清单）。所有可静态验证的假设均已由真实代码实证（grep 与精读），剩余不确定性仅为**实施期验证类**（编译、真机视觉、动画手感），该类问题只有在执行阶段才能被发现与修正。

## 最终变更清单（终版定稿）

### 新建（3 文件，pbxproj 四段注册）
1. `qin/DesignCode/MessageCenterStore.swift` — @MainActor 单例 + MessageKind/DeepLinkPayload/MessageItem 模型 + 持久化/自愈/增量计数/导入/角标/autoCheck/launch 状态机 + style 映射表（`init(storageDirectory:defaults:)` 供测试注入）
2. `qin/DesignCode/MessageCenterView.swift` — 主视图 + 消息行 + 仿写 filterChip/emptyState + 无深链详情卡 + 设置面板 + 诊断面板 + 三态空态
3. `qin/DesignCodeTests/MessageCenterStoreTests.swift` — 17 用例（注册进 Tests target Sources phase）

### 修改（4 文件）
1. **NotificationManager.swift** — ① `checkForUpdates(pushToSystem: Bool = true)` 签名扩展 + 5 处 add 短路 + 静默模式放宽 guard；② 四处 ingest 调用（新闻 L348 / 信箱 L424 / 概况 L535+L562 / 党建 L628）；③ handleNotificationTap 各分支 return 前 markRead 联动（含 isBookmarkUpdate 按 kind+articleId 兜底匹配）
2. **BookmarkManager.swift** — L389 add 成功后 ingest（kind:.bookmarkUpdate, id:"bookmark-update-<readKey>"）
3. **TabBar.swift** — ① MenuCard（L5991-6018）加 `badge: Int? = nil` + chevron 前徽章胶囊；② 「我的」tabItem（L170-174）加 `.badge(unreadCount)`；③ ProfileView（L5795 起）加 @ObservedObject + showMessageCenter sheet + dismissRequest onChange + menuCards 首位插入消息中心入口卡（未读数 + latestItem 预览）
4. **DesignCode.xcodeproj/project.pbxproj** — 上述 3 新文件四段注册（BuildFile / FileReference / group children / Sources phase）

### 功能全景（终版）
App 内回看全部通知历史（含升级导入）｜未读/已读 + 双层角标（Tab 徽章 + 桌面角标）｜分类筛选 + 搜索平铺 + 日分组 + 相对时间鲜活｜全部已读三态 + 分类型批量已读 + 右滑已读/删除 + 清空分级｜五类深链点击（点击必达 fetch 兜底）+ 无深链详情卡｜行长按复制/分享｜下拉刷新/立即检查/前台 30min 自动静默检测（站内信，独立于系统通知开关）｜消息中心设置面板｜长按标题 5 次诊断修复｜存储自愈 + 版本迁移｜第五通道 5 处扩展点｜约 30 条日志埋点（module: messageCenter）

### 实施顺序
1. MessageCenterStore.swift（模型+持久化+自愈+计数）→ 2. NotificationManager/BookmarkManager 挂载与已读联动 → 3. MessageCenterView.swift → 4. TabBar 三处改动 → 5. pbxproj 注册 → 6. 编译 0 错 0 警 → 7. 单测全绿 → 8. 真机验收 8 项清单

## 六轮迭代修正总览（35+ 项，简表）

| 版本 | 修正内容 |
|---|---|
| v2 | 静默检测模式 / instant 写盘防丢 / 深链竞态防抖 / 失败兜底 / 诊断面板 / 测试注入 |
| v3 | 前台 30min 自动站内检查 / latestItem 预览 / 搜索平铺 / 清空分级 / 相对时间刷新 / 禁用态 / 无障碍 / 批量单次写盘 / 增量计数 / 5 处扩展点 / 测试 3 件 |
| v4 | 组件私有性实证（仿写 vs 复用）/ swipeActions 定稿 / display 字体硬规范 / MenuCard 可行性 / 深链消费复核 |
| v5 | 第五通道收藏更新接入 / 通知源全域审计（9 处）闭环 / 升级历史导入 / Tab 徽章 / 无深链详情卡 / 长按操作 / 批量已读 / 设置面板 |
| v6 | 点击必达 fetch 兜底 / 测试双重注入 / 计数混合策略 / 上限即截断 / 跨 sheet 竞态 / 幂等性 / @MainActor 并发审计 |

## 新建文件（3 个，均放 `qin/DesignCode/`，手动注册 pbxproj）

1. **MessageCenterStore.swift** — `@MainActor` 单例 + 模型定义（对齐 BookmarkManager.swift 模式）
2. **MessageCenterView.swift** — 主视图 + 消息行子视图 + 空态 + 筛选芯片 + 搜索框 + 诊断面板
3. **DesignCodeTests/MessageCenterStoreTests.swift** — 单测（注册进 DesignCodeTests target）

## 数据模型（MessageCenterStore.swift 内）

```swift
enum MessageKind: String, Codable, CaseIterable { case news, mailbox, schoolProfile, partySubject }

struct DeepLinkPayload: Codable, Equatable {
    var articleId: String?; var articleCategory: String?; var articleTitle: String?
    var mailboxId: String?; var mailboxTitle: String?
    var schoolProfile: Bool?; var partySubject: Bool?
    var asUserInfo: [AnyHashable: Any] { ... }
}

struct MessageItem: Codable, Identifiable, Equatable {
    let id: String        // 新闻/信箱复用通知 identifier 天然去重；概况/党建 "<kind>-<timestamp>" 防同轮覆盖
    let kind: MessageKind
    var title: String
    var subtitle: String
    let timestamp: Date
    var isRead: Bool
    let deepLink: DeepLinkPayload?
    let isTest: Bool
    var schemaVersion: Int = 1
}
```

- 上限：`@AppStorage("messageCenterMaxCount") = 200`，FIFO 截断（对齐 BookmarkManager.applyMaxCountLimit）
- 存储：`MessageCenter/events.json`；变更即写 + scenePhase 非活跃 flush

## Store API（MessageCenterStore）

- `@Published private(set) items`、`@Published unreadCount`（增量维护）、`@Published latestItem`、`@Published launchState`（idle/launching/failed(reason)）、`@Published isSilentChecking`（镜像 NotificationManager.isChecking）
- `init(storageDirectory: URL? = nil)` — 单测注入临时目录
- `ingest(kind:id:title:subtitle:deepLink:isTest:)` / `markRead(id:)` / `markRead(kind:)` / `markAllRead()`（单次写盘）/ `delete(id:)` / `clearHistory(scope: .all / .readOnly)` / `filter(keyword:kind:unreadOnly:) -> [MessageItem]`（纯函数供 UI 与测试）
- `silentCheckNow()` — `checkForUpdates(pushToSystem: false)`
- `launch(item:)` — 重入取消旧投递；失败 → launchState=.failed 行内提示
- `startAutoCheckIfNeeded()` — scenePhase 回前台 + 距上次 >30min（可注入时钟供测试）→ silentCheckNow；开关 `@AppStorage("messageCenterAutoCheck") = true`
- `static func style(for kind:) -> (icon, color)` 集中映射
- 角标联动：`@AppStorage("messageCenterBadgeEnabled") = true`；unreadCount 变化 → badge 授权可用则 `applicationIconBadgeNumber = unreadCount`；冷启动加载后同步；授权不可用静默跳过（**不设 tab 角标**——避免与系统 App 角标双重噪音，仅 MenuCard 徽章 + 系统角标两处）

## ingest 挂载点（NotificationManager.swift）

**checkForUpdates 签名**：`checkForUpdates(pushToSystem: Bool = true)`。5 个 add 短路点全列：① 新闻循环内 L345-349 ② 信箱循环内 L417-424 ③ 概况旧基线分支 L535 ④ 概况正常分支 L561-562 ⑤ 党建 L628-631。pushToSystem=false 时跳过 `add`，**仍写 notifiedArticleIds / notifiedMailboxIds / baseline 并 ingest**（语义：入盒即标记；日志注明 silent 模式）。静默模式放宽 guard 为仅 `!isChecking`；`startPolling`/delegate 零改动。

ingest 四处调用（参数同 v2）：
1. 新闻：`(kind:.news, id:"news-\(article.id)", title:"【\(article.category)】", subtitle:article.title, deepLink:.init(articleId:article.id, articleCategory:article.category, articleTitle:article.title))`
2. 信箱：`(kind:.mailbox, id:"mailbox-\(message.id)", title:"校长信箱 · 新回复", subtitle:message.showTitle, deepLink:.init(mailboxId:..., mailboxTitle:message.showTitle))`
3. 概况（两个分支各一次）：`(kind:.schoolProfile, id:"schoolProfile-\(timestamp)", title:"学校概况 · 有新内容", subtitle:"\(changedParts.joined(separator:"、"))内容已更新")`
4. 党建：`(kind:.partySubject, id:"partySubject-\(timestamp)", title:"党建专题 · 有新内容", subtitle:"\(changed.joined(separator:"、"))已更新")`

**已读联动**：`handleNotificationTap`（L736 起）各分支 return 前 `markRead(...)`；无 articleId 分支按通道类型尝试。语义：站外点击同样消未读。测试通知一律不入盒（debug 日志）。

## 深链流程（防闪退 + 不叠 sheet + 竞态保护）

行点击（触觉 .light）→ `markRead(id:)` + `launch(item:)` → 取消进行中投递 → `@Published dismissRequest = UUID()` → ProfileView onChange 关 sheet → 0.45s → `handleNotificationTap(userInfo: deepLink.asUserInfo, source:"message_center")` → TabBar L253-287 既有 onChange 链（内部 0.4s 让出同步链）→ sheet 弹详情。失败兜底：deepLink=nil 禁跳转 + 标注；投递失败 → warning 日志 + launchState=.failed 行内「内容暂时无法打开」。

## UI 设计

### 「我的」页入口（TabBar.swift ProfileView L5872-5905）

- menuCards 顶部插入：`MenuCard(icon:"bell.badge.fill", title:"消息中心", subtitle:"\(unreadCount) 条未读 · \(latestItem?.title 截断 ?? "暂无消息")", color:Color.sjzPrimary, badge: unreadCount>0 ? unreadCount : nil)`
- MenuCard（L5991）加 `badge: Int? = nil` 可选参数（行尾红色渐变胶囊，≥99 → "99+"），不影响其余 4 处
- `@ObservedObject MessageCenterStore.shared`；`@State showMessageCenter` + `.sheet { NavigationStack { MessageCenterView() } }`（对齐 showBookmarks L5830-5832）；`onChange(store.dismissRequest)` 关 sheet

### MessageCenterView 结构树

```
NavigationStack（title「消息中心」）
├─ trailing：全部已读三态按钮（unreadCount=0 禁用灰 → checkmark → ProgressView → 绿勾脉冲 1.6s，触觉 .light）
├─ Liquid Glass 搜索框（信箱先例：聚焦描边动画；500ms 防抖；搜索态切换平铺列表 + 命中计数胶囊；无历史）
├─ 分类筛选芯片条：全部/未读/新闻/信箱/概况/党建（计数徽章 + 选中弹簧，OrganizationView L517-595 模式）
├─ 列表：日分组（今天/昨天/更早，折叠日期头）←→ 搜索平铺；1 分钟 Timer 刷新相对时间
│   ├─ 行：未读蓝点（标已读 scale+opacity 弹簧收缩；accessibilityLabel「未读」）+ kind 图标胶囊 + 标题/摘要两行 + 相对时间
│   ├─ 入场 SJZRevealOnce 0.04s×序；未读行微 tint；Liquid Glass 卡片（.ultraThinMaterial + RoundedRectangle(22)）
│   ├─ 右滑：已读/未读切换（触觉 .light）、全滑删除（offset+opacity 折叠）
├─ 下拉刷新：.refreshable → silentCheckNow()（独立 Task 防 cancelled 误报，信箱先例）
├─ 空态（复用 BookmarkListView L70-96，三态文案：无消息/无未读/无搜索结果）
└─ 底部工具栏：未读汇总胶囊 + 立即检查三态按钮（观察 isSilentChecking，完成显示新增数+耗时）+ 清空历史长按菜单（全清/仅清已读 + confirmationDialog + 触觉 .warning）
```

- 滚动：SJZScrollActivityTracker（方向 3s / 触底 10s 节流哨兵）
- 诊断修复面板：长按导航标题 5 次 → Liquid Glass 面板 {存储路径/条目数/未读数/上限/schemaVersion} +「重建存储」「跳转应用日志」；所有元素 accessibilityLabel；日志 info triggerRebuild

## 容错机制

解码自愈（整体失败 → `.corrupt` 备份 + 重建 + error 日志带大小）；单条损坏逐条跳过（warning 带 index）；版本迁移（schemaVersion<1 补字段 + info from/to）；未知 kind 降级 .news（warning）；写盘失败 error 日志 + 内存保持 + 重试 + 后台 flush；FIFO 双校验；相对时间/日分组时钟回拨不做特殊处理（本地短进程，风险可忽略）。

## 日志埋点清单（module "messageCenter"，约 27 条）

storeDidLoad / storageCorruptedRebuilt(error) / itemDroppedCorrupt(warning) / schemaMigration / ingestSkippedTest(debug) / ingestAdded(info) / ingestDeduplicated(debug) / fifoEvicted / badgeSynced(debug) / badgeUnavailableSilent(debug) / listOpened(info 带 unread) / silentCheckStart / silentCheckDone(info 带 newCount,elapsedMs) / silentCheckSkippedBusy(debug) / autoCheckTriggered(debug 带 interval) / autoCheckThrottled(debug) / pullToRefresh / searchInput(debug) / searchExecuted(info 带 keyword,hitCount) / filterSelected(debug) / itemTapped(info 带 kind,wasRead) / launchDeepLink(info 带 target,pipeline) / launchFailed(warning) / markReadOne(debug) / markAllRead(info 带 count,elapsedMs) / deleteOneSwipe(info) / clearHistory(warning 带 scope,count) / writeSaveFailed(error) / repairPanelOpened(info) / repairRebuild(warning)

## pbxproj 注册

无 PBXFileSystemSynchronized，每个新 .swift 四处：PBXBuildFile + PBXFileReference + group children + Sources build phase（测试文件进 DesignCodeTests Sources）。验证 grep 命中 4 处不重复；构建 0 警告。

## 测试（MessageCenterStoreTests，临时目录注入 + 可注入时钟）

ingest 新增/去重 / FIFO 截断 / 损坏 JSON 自愈 / 未知 kind 降级 / schemaVersion 迁移 / markRead(id:) 与 markRead(kind:) / 测试通知排除 / 清空两 scope / 未读增量计数 / payload-nil 不崩溃 / launch 重入取消 / filter(keyword:) 纯函数 / latestItem 派生 / 自动检查 30min 节流 / 角标数字计算。

## 验证

1. `xcodebuild -project DesignCode.xcodeproj -scheme DesignCode -destination 'id=00008110-000411A40EC1401E' build` → 0 错 0 警
2. `xcodebuild test`（同 destination）→ 22+ 新用例全绿
3. 真机验收：① 我的页入口 + 徽章 + 最近预览 ② 各通道推送 → 入盒（测试通知不入）③ 点击消息四类深链 ④ 关系统通知 → 下拉/立即检查/前台自动检查仍入盒 ⑤ 全部已读禁用态、右滑、清空两 scope、搜索平铺、筛选、日分组、相对时间跳动 ⑥ 角标联动 ⑦ 长按标题 5 次诊断面板 ⑧ 应用日志 messageCenter 全链路

## 风险

- 深链闪退：dismiss → 0.45s → 既有防闪退链路；launch 状态机防重入
- 静默模式：仅手动/前台节流触发（30min），耗电可控；与通知轮询撞车自动跳过；对现有推送零影响
- 概况/党建 id 时间戳防覆盖；markAllRead 单次写盘防 IO 抖动
- 不影响现有：checkForUpdates 仅加默认参数与短路分支；四通道/测试中心/22 旧用例回归