# 通知、消息中心与收藏 —— 深度分析草稿

> 分析范围：`qin/DesignCode/` 下 5 个文件（约 3954 行，`wc -l` 实测）。
> 行号一律来自 `grep -n` / `read` 实测，未标注的行号不得引用。
> 行数口径：`wc -l` 与 `read` 工具报告值相差 1（文件末行无换行符）。本文统一用 `wc -l`：NotificationManager **1282**、MessageCenterStore **870**、BookmarkManager **1354**、ReadStatusManager **109**、AnnouncementManager **339**。

| 文件 | wc -l | 角色 | 日志域 |
|---|---|---|---|
| `NotificationManager.swift` | 1282 | 官网指纹轮询 + 本地比对 + 系统通知 + 深链分发 | `notification` / `notificationTest` / `messageCenter` |
| `MessageCenterStore.swift` | 870 | App 内消息中心（站内信）事件库 | `messageCenter` |
| `BookmarkManager.swift` | 1354 | 收藏、离线正文固化、图片固化、更新检测 | `favorite` |
| `ReadStatusManager.swift` | 109 | 已读/未读标记（纯本地） | 无（不写日志） |
| `AnnouncementManager.swift` | 339 | 开发者博客驱动的公告开关 | `announcement` |

---

## 0. 核心结论速览

1. **这是一套「无服务端、无 APNs、无第三方 SDK」的自建推送体系**：把学校官网当作数据源，用「抓取 → 本地指纹/集合比对 → `UNUserNotificationCenter` 本地通知」模拟服务端推送。全链路只依赖 `URLSession` + `UserNotifications` + `CryptoKit`。
2. **通道数量的实测校正（重要）**：本任务前提描述的「四通道 + 收藏第五通道」是**早期口径**，当前代码已演进为 **`NotificationManager` 内 5 条通道 + `BookmarkManager` 1 条通道 = 6 条**：
   - `NotificationManager.checkForUpdates` 串行调用 5 条：新闻、信箱、概况、党建、**机构动态**（`NotificationManager.swift:313-318`，注释自称「五条独立检测通道」）。
   - 收藏更新是**第 6 条**，实现在 `BookmarkManager`（`BookmarkManager.swift:976-1083`），**不在** `checkForUpdates` 里。
   - 且代码内部存在**命名冲突**：`NotificationManager.swift:753` 把机构动态标为「第五通道」，而 `BookmarkManager.swift:1062` 把收藏更新也标为「第五通道」。写 Wiki 时应统一为「5 + 1」并显式说明这处历史命名重叠。
3. **消息中心是通知的「影子账本」**：每条系统通知发送成功后，同步 `ingest` 一条 `MessageItem`（`NotificationManager.swift:406-417`），二者以 **id 一一配对**（`news-{id}` / `mailbox-{id}` / `org-{id}` / `bookmark-update-{readKey}`）。
4. **静默检测语义≠系统静默推送**：代码里的「静默」指 `pushToSystem: false`，即**只入盒、不发系统通知**（`NotificationManager.swift:299-301`），与 APNs 的 `content-available` 静默推送无关。项目**未使用** `BGTaskScheduler`、**Info.plist 无 `UIBackgroundModes`** —— 无任何后台唤醒能力。
5. **收藏的更新检测复用「正文缓存」本身作为指纹**，不额外存 hash（`BookmarkManager.swift:546-551, 576-578`）。
6. **任务点名的 `await` 后复用 `idx` 越界隐患，当前实现已修复**（`BookmarkManager.swift:573` 在 `await` 之后**重新解析下标**）。详见 §3.6。

---

## 1. NotificationManager.swift（1282 行）

### 1.1 「官网指纹轮询 + 本地比对」的整体设计

无服务端意味着**没有推送触发源**，所以把「服务端 → 客户端」的推送模型倒转为「客户端 → 服务端拉取 + 客户端本地 diff」：

| 通道 | 指纹/比对方式 | 基线或去重键 | 首次基线策略 |
|---|---|---|---|
| 新闻 | 文章 id 集合 diff（各栏目第一页 10 条） | `notifiedArticleIds`（上限 2000） | 用户开启开关时调 `markExistingArticlesAsNotified()` |
| 信箱 | 信件 id 集合 diff（第一页 20 条） | `notifiedMailboxIds`（上限 2000） | `notifiedMailboxIds.isEmpty` → 只登记不推送 |
| 概况 | 三整数指纹字符串 `领导数\|风光数\|合作交流数` | `schoolProfileBaseline` | 基线不存在 → 只建立不推送 |
| 党建 | 双子站四元组 `总数\|top3签名\|总数\|top3签名` | `partySubjectBaseline` | 同上；旧结构不符则静默重建 |
| 机构动态 | 关注机构 `/dept/home2` nav 嵌套区块文章 id 集合 | `notifiedOrgArticleIds`（上限 3000）+ `orgFollowBaselineEstablished` 布尔 | 冷启动首轮只登记；新关注由 `seedOrgFollowBaseline` 播种 |
| 收藏更新 | **正文文本本身**作为指纹（`isMeaningfulUpdate`） | 无独立集合；靠 `updateDetectedAt` 徽标状态 | 无缓存正文 → 跳过（`skipped`） |

设计要点：**每条通道都独立 try/catch，任一失败不影响其余**（`NotificationManager.swift:313` 注释 + 各通道末尾 `catch` 只记 debugLog）。这是「一份不稳定的校园官网 API」下的必要韧性设计。

### 1.2 五通道调度入口

`checkForUpdates(pushToSystem:)`（`302-319`）：

1. `guard !isChecking else { return }`（`303`）—— **重入守卫**，同时防住「定时轮询」与「消息中心静默检测」撞车（`MessageCenterStore.swift:576` 注释明确依赖这一点）。
2. `pushToSystem == true` 时再要求 `isEnabled && isAuthorized`（`304-306`）；**`false` 时不受系统通知开关限制**，这正是站内信独立于通知权限的关键。
3. `defer { isChecking = false; lastCheckTime = Date() }`（`311`）—— 无论成功失败都刷新检查时间，`lastCheckTime` 的 `didSet`（`126-134`）顺带持久化到 `notificationLastCheckTime`。
4. 依次 `await` 五条通道（`314-318`）——**串行**，不并发（见 §1.8 关于定时器阻塞的讨论）。

### 1.3 通道一：新闻（`322-435`）

1. `fetchHome2()` 取 `news.children` 的 4 个 `columnId`：学校要闻 / 新闻资讯 / 党建动态 / 通知公告（`334-339`）。
2. 用 `withTaskGroup` **并行**拉 4 个栏目第一页（`size: 10`，`342-362`），单栏目失败仅打印并返回空数组（`353-356`）。
3. `allArticles.filter { !notifiedArticleIds.contains($0.id) }` 求新增（`365`），空则返回。
4. `prefix(maxNotificationsPerCheck)` = 每次最多 5 条（`369`，常量在 `190`）。
5. 逐条构造 `UNMutableNotificationContent`（`373-382`）：标题 `【分类】`、正文文章标题、`userInfo` 携带 `articleId/articleCategory/articleTitle`；`content.badge = nil`（`377`）——**刻意不设角标**，角标统一由消息中心未读数驱动（§2.9）。
6. 触发器错峰：`UNTimeIntervalNotificationTrigger(timeInterval: 1 + index)`（`385-386`），标识符 `news-{articleId}`（`387`）。
7. `pushToSystem` 为真才 `center.add`；否则 `delivered = true` 跳过发送但仍入盒（`392-404`）。
8. `delivered` 为真才 `MessageCenterStore.ingest(kind: .news, id: "news-{id}", ...)`（`407-417`）——**「系统通知成功」与「入盒」是同一判定**。
9. 最后统一写入 `notifiedArticleIds`（`421-423`），`newArticlesFound = toNotify.count`（`425`，注意：**只有新闻通道会更新这个 @Published 计数**）。

### 1.4 通道二：校长信箱（`439-526`）

- 取第一页 20 条（`441`）。
- **历史保护**：`notifiedMailboxIds.isEmpty` 时把当前 20 条全部登记为已通知并 `return`，不推送（`452-461`），注释说明是为了避免「把历史 12 封全部轰炸给用户」（`438`）。
- 增量 `filter` 后 `prefix(3)`（`463-466`）——信箱上限比新闻更保守（3）。
- `userInfo` 键为 `mailboxId`/`mailboxTitle`/`deepLink: "principalMailbox"`（`473-477`）；标识符 `mailbox-{id}`。
- 发送失败记 `warning`（`491-494`），并入盒判定同新闻。
- 整通道 catch 仅 `debugLog`，注释「不影响新闻通道」（`521-525`）。

### 1.5 通道三：学校概况（`532-675`）——三段指纹与静默升级

- 基线键 `schoolProfileBaseline`（`533`）。
- 三个子指标：`current-leader.data.list.count`（领导数，`538-545`）、`campus-life.articles.total`（风光数，`547-554`）、**合作交流数**（`556-581`）。
- 合作交流数是本文件最"考古"的一段：
  - 内联列表计数需**跳过 `title_en == "cooperation"` 的校企合作组**（`566`），因其内嵌列表只有前 8 条；
  - 校企合作的权威计数改走栏目文章接口 `cc7376c390cb4aa4bc519c4858009630` 的 `total`（`572-575`）；
  - 任一子请求失败 → `cooperateTotal = -1` → **本轮跳过比对、不写坏基线**（`578-581`）。这是很好的「宁可不报，不可误报」范式。
- 首次运行建立三段基线不推送（`586-593`）。
- **旧版两段基线静默升级**（`595-634`）：`prevParts.count < 3` 时，若前两段未变则直接把基线升级为三段并 return（不误报）；若前两段确有变化则**按旧语义推送**（`607-633`）。这段是「跨版本基线迁移」的完整实现，建议在 Wiki 中单列。
- 三段基线逐段对比产出**精确变化文案**（`637-640`）：如「校领导、合作交流内容已更新，点击查看」（`646`）。
- 通知标识符固定 `school-profile-update`（`618`/`653`）—— 复用同一标识符意味着**后续通知替换前一条**，天然防堆积。
- 入盒 id 用毫秒时间戳：`schoolProfile-{ms}`（`626`/`661`）—— 与固定通知标识符**不一致**，因此同一次"概况更新"若连续触发会累积多条消息中心条目（见 §7 存疑点）。

### 1.6 通道四：党建专题（`682-751`）——双子站轻量指纹

- 基线键 `partySubjectBaseline`（`683`）。
- 遍历两个子站 `("djgz", "党建工作")`、`("mkszy", "思政专题")`，各调一次 `fetchPartySubjectFingerprint(siteKey:)`（`687-691`，实现在 `NetworkService.swift:1088`）。
- 指纹四元组 `总数|top3签名|总数|top3签名`（`692`）。
- 结构校验 `prevParts.count == 4` 不满足则**静默重建基线不误报**（`705-712`）。
- 变化归因到具体子站（`717-718`），通知标识符固定 `party-subject-update`，入盒 id `partySubject-{ms}`。

### 1.7 通道五：机构动态（`761-899`）——唯一与用户行为挂钩的通道

这是全套体系里设计最精细的一条：

- **零请求短路**：`OrgFollowStore.shared.followed` 为空直接 return（`762-763`）。
- **单轮巡检上限 10 个机构**（`766`），`maxNotificationsPerCheck` 跨机构共用（`774`），超出预算的新文章**登记为已通知避免下轮重复轰炸**（`843-845`）。
- **冷启动基线**（`780-785`）：`orgFollowBaselineEstablished` 为假时只登记不推送。
- **关注动作播种**：`seedOrgFollowBaseline(for:)`（`875-899`）由机构详情页关注成功回调触发（`OrganizationDetailView.swift:1077`），把该机构当前文章全部登记，并把全局基线标记置真（`885-887`），注释解释了为何必须同时置真：否则关注后第一轮仍按冷启动「只登记不推送」，会**吞掉这一窗口内的真新增**（`883-884`）。这是一个很典型的「基线状态机」陷阱，值得在 Wiki 里点出。
- **并集写回**（`854-856`）：写回时用 `notifiedOrgArticleIds.union(known)` 而非直接覆盖，避免轮询期间 `seedOrgFollowBaseline` 刚播种的基线被整集覆盖。
- `userInfo` 携带机构归因四元组 `orgArticleId/orgName/orgCategory/orgSiteId` + `articleTitle`（`796-804`），标识符 `org-{articleId}`。
- 单机构失败只跳过该机构（`846-851`）。

### 1.8 轮询间隔、定时器与「后台策略」

- 间隔配置：`@AppStorage("notificationPollingMinutes")` 默认 **30 分钟**（`117`），`didSet` 触发 `restartPollingIfNeeded()`；UI 选项为 15 / 30 / 60 / 120 分钟（`TabBar.swift:10808-10813`）。
- 开关：`@AppStorage("notificationEnabled")` 默认 **false**（`111`），`didSet` 直接启停轮询（`112-114`）。
- `startPolling()`（`273-285`）：先 `stopPolling()` 清旧定时器 → `guard isEnabled, isAuthorized` → `Timer.scheduledTimer(repeats: true)`，回调内 `Task { @MainActor [weak self] in await self?.checkForUpdates() }`（**weak self + 显式切主 actor**）→ 末尾**立即执行一次首次检查**（`284`）。
- `stopPolling()`（`287-290`）：`invalidate()` + 置 nil。
- `restartPollingIfNeeded()`（`292-295`）。
- **后台策略 = 没有后台策略**（实测结论）：
  - 全仓库无 `BGTaskScheduler` / `BGAppRefresh`（grep 为空）；
  - `DesignCode/Info.plist` **无 `UIBackgroundModes` 键**；
  - `stopPolling()` 的调用点只有 `isEnabled` 的 `didSet`（`113`）与 `startPolling()` 自身（`274`）——**App 进后台不停止轮询，回前台也无补偿逻辑**（`DesignCodeApp.swift:129-145` 的 `scenePhase` 分支只处理生物识别与日志落盘）。
  - 实际效果：iOS 挂起进程后 `Timer` 不再触发，回前台后因 fire date 已过而补触发一次。补漏主要靠 `MessageCenterStore.handleSceneActive()` 的 30 分钟节流静默检测（`MessageCenterStore.swift:577-596`，由 `TabBar.swift:333` 在 `scenePhase == .active` 时调用）。
- **潜在阻塞**：五通道在一个定时器回调里串行 await（`314-318`），若官网接口慢，单轮耗时可能接近分钟级；`isChecking` 重入守卫会把此时到达的静默检测**直接丢弃**（`303`），即「静默检测被无声跳过」——见 §7 存疑点。

### 1.9 `UNUserNotificationCenter` 使用方式

| 用途 | 位置 | 说明 |
|---|---|---|
| delegate 注册 | `196` | `init` 中 `UNUserNotificationCenter.current().delegate = self` |
| 权限申请 | `216` | `requestAuthorization(options: [.alert, .sound, .badge])` |
| 权限查询 | `231-234` | `notificationSettings()`，`authorized \|\| provisional` 均算已授权；同时取 `badgeSetting` |
| 发通知 | `394` / `488` / `622` / `657` / `733` / `813` / `926` / `1212` | 全部走 `UNNotificationRequest` + `UNTimeIntervalNotificationTrigger` |
| 角标 | `1270` | `setBadgeCount(count)`（仅测试面板调用） |
| 前台展示 | `959-973` | `willPresent` → 回执 `[.banner, .sound, .list]` |
| 点击响应 | `976-992` | `didReceive` |

要点：
- **全部为本地通知**，无 `UNNotificationServiceExtension`、无远程推送注册（无 `registerForRemoteNotifications`）。
- `content.badge` 在新闻（`377`）、信箱（`472`）、机构（`795`）、信箱模拟（`913`）里显式置 `nil`；**概况与党建通道完全没设 badge**。角标唯一来源是消息中心未读数（§2.9）。
- 通知标识符策略：新闻/信箱/机构用**实体 id**（幂等，同文重推自动替换）；概况/党建/信箱模拟用**固定串**（单条覆盖）；测试用**随机 UUID 前缀**（`1199`）。

### 1.10 delegate 为何用「完成回调版」而非 async 版（`950-992`）

代码注释（`951-956`）给出的完整历史原因，逐字要点：

1. async 版 `userNotificationCenter(_:didReceive:) async` **由系统在任意后台协作队列上派发**；
2. UIKit 的通知响应处理机制（快照 / 状态恢复 `CATransaction` 提交）会**随回调在同一后台队列**执行；
3. 触发 `"Call must be made on main thread"` 断言崩溃 —— 注释明确指认为**「点击通知闪退根因」**；
4. 完成回调版**由系统保证在主线程派发**，配合内部 `Task { @MainActor ... }` 形成双保险。

实现细节（`976-992`）：
- 方法标注 `nonisolated`（`976`），因为类本身是 `@MainActor`；
- `completionHandler()` **在处理任何业务逻辑之前立即回执**（`984`，注释「系统只要求调用回执，不要求等待处理完成」）；
- 随后 `Task { @MainActor in NotificationManager.shared.handleNotificationTap(...) }`（`985-991`）；
- `willPresent`（`959-973`）同理：先 `completionHandler([...])`（`966`），日志埋点放异步主线程，注释「绝不阻塞系统回调」（`965`）。

> ⚠️ 标注：上述崩溃因果是**代码注释的声明**，本次分析仅静态阅读，未在真机复现验证。

### 1.11 `handleNotificationTap` 与 `pendingDeepLink` 的交接（`998-1107`）

这是「通知点击 → UI 弹窗」的解耦枢纽。核心思路（`996-997` 注释）：**绝不在系统回调同步链中直接弹窗**，只设置 `@Published` 状态，由主界面 `onChange` 在安全时机消费。

分发顺序（**顺序即优先级，务必按序理解**）：

1. `schoolProfileDeepLink == true`（`1006-1015`）→ `markRead(kind: .schoolProfile)` → `pendingSchoolProfileDeepLink = true` → return。
2. `partySubjectDeepLink == true`（`1018-1027`）→ `markRead(kind: .partySubject)` → `pendingPartySubjectDeepLink = true` → return。
3. `orgArticleId` 非空（`1030-1053`）→ `markRead(id: "org-{id}")` → 构造 `PendingOrgArticleDeepLink`（含 `articleId/title/orgName/categoryRaw/siteId/source`）→ return。
4. `mailboxId` 非空（`1056-1070`）→ `markRead(id: "mailbox-{id}")` → `pendingMailboxDeepLink = Int(mailboxId)` → return。
5. 兜底按文章处理（`1072-1107`）：取 `articleId/articleCategory/articleTitle`；**空 `articleId` 只记 warning 不跳转**（`1088-1093`）。
6. 收藏归因（`1095-1099`）：`isBookmarkUpdate == true` → `markRead(kind: .bookmarkUpdate, articleId:)`；否则 `markRead(id: "news-{articleId}")`。
7. `pendingDeepLink = PendingArticleDeepLink(...)`（`1101-1106`）。

`PendingArticleDeepLink` / `PendingOrgArticleDeepLink`（`36-75`）**都含 `let id = UUID()`**，注释说明「每次点击通知都生成新实例，id 保证 `onChange` 每次都触发」（`35`）——这是绕开「相同值不触发 `onChange`」的实用技巧。

消费侧：`TabBar` 对 5 个 `pending*` 各挂一个 `onChange` —— `pendingDeepLink`（`TabBar.swift:290`）、`pendingMailboxDeepLink`（`:296`）、`pendingSchoolProfileDeepLink`（`:307`）、`pendingPartySubjectDeepLink`（`:316`）、`pendingOrgArticleDeepLink`（`:325`）；统一经 `scheduleNotificationArticlePresentation()`（定义 `TabBar.swift:116`）在 `scenePhase == .active`（`:331`）与生物识别解锁后（`:339`）**补发调度**，以覆盖冷启动点击通知的场景。
`deepLinkOutcome`（`78-100`）是回显给「通知测试页」的闭环反馈枚举，**生产路径未设置**，仅测试相关流程使用。

### 1.12 权限申请时机（隐私同意是前提）

- `requestPermission()`（`213-227`）**唯一调用点**是设置页的「开启通知」按钮（`TabBar.swift:10760`），由用户主动点击触发，非启动自动弹窗。
- 成功且 `isEnabled` 时顺带 `startPolling()`（`219`）。
- App 级自动恢复轮询的**门禁是隐私同意**：`DesignCodeApp.swift:146-152` 在启动任务里先 `refreshAuthorizationStatus()`，仅当 `privacyConsentAccepted && isAuthorized && isEnabled` 才 `startPolling()`（`150-151`）——注释「仅当隐私已同意时」。
- 隐私同意本身由 `@AppStorage("privacyConsentAccepted")` / `privacyConsentRejected` 控制（`DesignCodeApp.swift:17-18`），拒绝后进入**受限模式**（`90` 起），因此「设置页 → 开启通知」这条路径在受限模式下不可达。**隐私同意是事实上的前置条件，而非代码里对 `requestPermission` 的显式 guard**（该函数内不检查隐私状态）。
- 权限文案映射齐全：`authorizationStatusDescription`（`243-252`，含 `.provisional` → 「临时授权（静默试推送）」）与 `badgeSettingDescription`（`255-262`）。
- 注意：代码**从不请求 `.provisional`**（`216` 只要三个基础项），但文案里保留了 provisional 分支，属于防御性写法。
- `openSystemSettings()`（`265-269`）用 `UIApplication.openNotificationSettingsURLString` 直达通知设置页。

### 1.13 `@Published` 字段清单（`121-152`）

| 字段 | 行 | 用途 |
|---|---|---|
| `isAuthorized: Bool` | 123 | 授权态（`authorized \|\| provisional`） |
| `authorizationDetailText: String` | 125 | 授权明细文案 |
| `lastCheckTime: Date?` | 126-134 | 带持久化 `didSet`（键 `notificationLastCheckTime`） |
| `isChecking: Bool` | 135 | 检测中（消息中心「立即检查」按钮观察它做撞车反馈） |
| `lastCheckError: String?` | 136 | 错误（**仅新闻通道会写**，`327`/`429`/`432`） |
| `newArticlesFound: Int` | 137 | 本轮新增数（**仅新闻通道写**，`425`） |
| `pendingDeepLink: PendingArticleDeepLink?` | 140 | 文章深链 |
| `pendingMailboxDeepLink: Int?` | 142 | 信箱深链（信件 id） |
| `pendingSchoolProfileDeepLink: Bool` | 144 | 概况深链 |
| `pendingPartySubjectDeepLink: Bool` | 146 | 党建深链 |
| `pendingOrgArticleDeepLink: PendingOrgArticleDeepLink?` | 148 | 机构深链 |
| `deepLinkOutcome: DeepLinkOutcome?` | 150 | 测试闭环回显 |
| `badgeSettingText: String` | 152 | 系统「标记」许可文案 |

另有 2 个 `@AppStorage`：`isEnabled`（111）、`pollingIntervalMinutes`（117）。

### 1.14 测试与维护入口

- `sendMailboxSimulationNotification(message:)`（`904-937`）：模拟信箱通知，固定标识符 `mailbox-simulation`（`922`）保证多次模拟只留最新一条；`isAuthorized` 为假直接拦截（`905-908`）。调用点 `PrincipalMailboxView.swift:277`。
- `ensureRealTestArticle()`（`1124-1158`）：本地无文章时现场拉要闻第一篇兜底，保证「首次安装未同步」也能验证点击跳转（注释 `1121-1123`）。
- `sendTestNotification(delaySeconds:useRealArticle:source:)`（`1162-1223`）：`delay = max(delaySeconds, 1)`，返回 `NotificationTestResult`。
- `simulateNotificationTap()`（`1228-1255`）：与真实点击**共用** `handleNotificationTap`（`1245-1252`），`source: "test_simulate"`。
- `setBadgeCount(_:)`（`1259-1282`）：先查 `badgeSetting`，`.disabled` 时返回中文引导文案；仅 `NotificationTestView.swift:483` 调用。
- `markExistingArticlesAsNotified()`（`941-948`）：开关首次启用时把现有文章全部登记（`TabBar.swift:10785` 调用，挂在该开关的 `onChange` 上）。

---

## 2. MessageCenterStore.swift（870 行）

### 2.1 数据模型

- **`MessageKind`（`20-27`）6 个枚举值**：`news` / `mailbox` / `schoolProfile` / `partySubject` / `bookmarkUpdate` / `orgUpdate`。注释「新增通道只需在此加一项 + 视觉映射」（`19`）。
- **`DeepLinkPayload`（`32-80`）**：统一可编码深链结构。关键设计：
  - `asUserInfo`（`49-71`）把它转回 `handleNotificationTap` 能识别的 `userInfo` 字典 —— **消息中心与系统通知共用同一条深链分发链路**；
  - `isBookmarkUpdate`（`41`）注释点明是「payload 自描述 + launch 侧按 kind 兜底双保险」（2026-09-29 加入）；
  - `orgArticleId/orgName/orgCategory/orgSiteId`（`43-46`）承载机构归因四元组，`articleTitle` 复用于机构文章标题；
  - `isEmpty`（`73-79`）**注意：不包含 `isBookmarkUpdate` 判断** —— 但因收藏更新 payload 必带 `articleId`，实际不会误判为空。
- **`MessageItem`（`84-94`）**：`id/kind/title/subtitle/timestamp/isRead/deepLink/isTest/schemaVersion`。`schemaVersion` 供版本迁移。
- **容错解码 `init(from:)`（`98-113`）**：`id` 严格必需，其余全部 `try?` 降级（未知 `kind` → `.news`，缺失时间 → `Date()`，缺失 `schemaVersion` → 1）。注释说明目的是「旧版本数据与损坏字段不拖垮整库」（`100`）。
- `MessageLaunchState`（`118-127`）：`idle/launching/failed(String)`。

### 2.2 持久化：路径、格式、原子写、两级自愈

- **路径**：`Documents/MessageCenter/messageCenterEvents.json`（`195-197`），目录在 `init` 里 `createDirectory`（`198`）。
- **格式**：`[MessageItem]` 的 JSON 数组，`dateEncodingStrategy = .iso8601`（`285`）/ `dateDecodingStrategy = .iso8601`（`268`）。
- **强原子写** `writeAtomically`（`307-316`）：先写同目录 `messageCenterEvents.json.tmp`，再 `replaceItemAt`；目标不存在则 `moveItem`。注释解释为何不用 `write(.atomic)`：「比 `write(.atomic)` 的隐式 rename 在容器边界场景更可控」（`305-306`）。
- **写后自校验**（`288-296`）：写完立即读回并尝试解码，失败则重写一次并落 `warning`。注释指向「强杀/覆盖安装边界下极端竞态造成的半截落盘（2026-09-24 真机物证）」。
- **二级加载自愈** `load()`（`218-264`）：
  1. 一级：整体标准解码成功 → 按 `timestamp` 倒序 → 完成（`226-231`）；
  2. 二级：把原文件**复制为 `messageCenterEvents.corrupt-{yyyyMMdd-HHmmss}.json`**（`234-236`），再用 `JSONSerialization` 逐条抢救，单条失败 `dropped += 1` 并记 warning（`245-257`），最后 `save()` 重建。
  3. `trimCorruptBackups()`（`326-336`）只保留**最近 5 份**现场，注释说明是「避免固定备份名被后续损坏事件覆盖、丢失首次现场」（`232-233`）。
- `finishLoad`（`272-278`）记录来源与耗时。

### 2.3 事件写入 `ingest`（`341-404`）——去重与上限

入参：`kind/id/title/subtitle/deepLink?/isTest`。规则：

1. `isTest == true` 一律**不入盒**（`343-348`）；
2. 空 `id` 拒绝并 warning（`349-354`）；
3. **同 id 幂等去重**（`356-389`）：
   - 已存在时**不新增、不加未读**，仅当 `title/subtitle` 变化才更新；
   - 深链升级两种情形：原来 `nil` 现在有值（`363-370`）、或深链内容变化（`371-380`），二者都重建 `MessageItem` 并标记 `deepLinkUpgraded`；
   - 仅在 `changed || deepLinkUpgraded` 时落盘（`383`）。
4. 新条目：`timestamp = Date()`、`isRead = false`、`schemaVersion = 1`，`items.sort` 后 `unreadCount += 1`、`latestItem = items.first`，再 `applyMaxCountLimit()` + `save()`（`391-400`）。

**上限（FIFO）**：`applyMaxCountLimit()`（`408-418`）取 `items.prefix(maxCount)` 截断（数组已按时间倒序，故丢的是最旧的），`maxCount` 默认 **200**（`147-156`，键 `messageCenterMaxCount`），set 时自动触发截断。

### 2.4 未读数计算

- **增量维护 + 兜底重算**：正常路径在 `ingest`/`markRead`/`markUnread`/`delete` 里 `unreadCount ± 1`（均带 `max(0, ...)` 或幂等 guard）；`recomputeUnread()`（`520-523`）在加载、截断、清空时全量重算（`items.filter { !$0.isRead }.count`）。
- `unreadCount` 的 `didSet`（`173-178`）在**值真正变化**时调用 `syncBadge()` —— 这是角标联动的唯一触发点。
- 分类未读：`unreadCount(of kind:)`（`540-542`）。

### 2.5 已读 / 未读 / 删除 / 清空

| 操作 | 行 | 匹配策略 |
|---|---|---|
| `markRead(id:)` | `423-430` | 精确 id，幂等（已读直接 return） |
| `markRead(kind:articleId:)` | `434-450` | `kind + deepLink.articleId + 未读`，**匹配失败保持现状（no-op）**；注释强调「绝不降级标记同类型其他消息，避免跨消息误标已读」（`432-433`） |
| `markRead(kind:)` | `453-461` | 按 kind 标最近一条未读（概况/党建类无单条 id） |
| `markUnread(id:)` | `464-471` | 幂等 |
| `markAllRead()` | `474-485` | 单次批量写盘，记录条数与耗时 |
| `delete(id:)` | `488-496` | 删除并校正未读、刷新 `latestItem` |
| `clearHistory(scope:)` | `499-516` | `ClearScope.all` / `.readOnly`，随后 `recomputeUnread` |

筛选纯函数 `filter(keyword:kind:unreadOnly:)`（`527-538`）：关键词对 `title/subtitle` 做 `lowercased().contains`，空白关键词视为无关键词。

### 2.6 与 NotificationManager 的「通知-入盒配对」

配对契约（`NotificationManager` 侧发起，`MessageCenterStore.ingest` 接收）：

| 通道 | 系统通知 identifier | 消息中心 id | 配对点 |
|---|---|---|---|
| 新闻 | `news-{articleId}` | 同左 | `NotificationManager.swift:387/409` |
| 信箱 | `mailbox-{messageId}` | 同左 | `488/504` |
| 概况 | `school-profile-update` | `schoolProfile-{ms}` | `618/626`、`653/661`（**不一致**） |
| 党建 | `party-subject-update` | `partySubject-{ms}` | `729/737`（**不一致**） |
| 机构 | `org-{articleId}` | 同左 | `790/831` |
| 收藏 | `bookmark-update-{readKey}` | 同左 | `BookmarkManager.swift:1057/1065` |

**关键契约**：只有 `delivered`（系统通知发送成功或静默模式）才入盒（`407-417`、`500-510`、`826-831`、`BookmarkManager.swift:1060-1072`）。机构通道注释明确写了「发送失败：保留未通知态，下轮重推（对齐新闻通道契约）」（`825-826`）。

**反向配对（点击回写已读）**：`handleNotificationTap` 按 4 种方式回标已读 —— `markRead(kind: .schoolProfile)`（`1012`）、`markRead(kind: .partySubject)`（`1024`）、`markRead(id: "org-{id}")`（`1044`）、`markRead(id: "mailbox-{id}")`（`1067`）、`markRead(kind: .bookmarkUpdate, articleId:)`（`1096`）、`markRead(id: "news-{id}")`（`1098`）。

**收藏通道的归因兜底**：`deliveryUserInfo(for:)`（`655-661`）——若 `item.kind == .bookmarkUpdate` 就强行补 `info["isBookmarkUpdate"] = true`。注释解释：收藏 payload 只带 `articleId`，若不补，`handleNotificationTap` 会按 `news-{articleId}` 走新闻通道标已读，**收藏条目永远命中不了**；这个兜底同时修复了历史已落盘消息（`652-654`）。

### 2.7 「串行同步」的准确表述

源码中**没有** `DispatchQueue`、`actor` 或串行队列实现（全文实测）。所谓串行来自两处结构性保证：

1. `MessageCenterStore` 是 `@MainActor final class`（`131-132`），所有 `@Published`/写盘点都在主 actor 上执行，天然原子；
2. 上游 `NotificationManager.checkForUpdates` 用 `await` **串行**跑五条通道（`NotificationManager.swift:313-318`），因此 `ingest` 调用也是串行的，不存在并发写同一 JSON 文件的竞态。

> 若要写「串行同步」，应表述为「主 actor 串行化 + 上游通道串行 await」，而非队列/actor 级的显式串行化设计。

### 2.8 静默检测与前台节流

- `silentCheckNow()`（`571-574`）：调 `NotificationManager.shared.checkForUpdates(pushToSystem: false)` —— **只入盒不推系统通知**；注释「五通道检测」（`570`）。调用点：`MessageCenterView.swift:214`（立即检查按钮）、`410`（下拉刷新）。
- ⚠️ **收藏更新通道不在此列**（`checkForUpdates` 不含 `BookmarkManager` 通道），所以「立即检查 / 下拉刷新 / 前台自动检查」**都不会触发收藏更新检测**；收藏通道只由自身 1 小时定时器或列表页手动触发（§3.5）。
- `handleSceneActive()`（`577-596`）：`autoCheckEnabled`（默认 true，`158-162`，键 `messageCenterAutoCheck`）为真时，用 `messageCenterLastAutoCheckTime` 做 **30 分钟节流**，通过后异步触发 `silentCheckNow()`。
- `setAutoCheck(_:)`（`599-604`）/ `isAutoCheckEnabled`（`606`）。

### 2.9 角标同步（`627-648`）

1. `syncBadge()` 先 `badgeSyncTask?.cancel()`（`628`）——**防抖**；
2. `Task.sleep(300ms)`（`630`）后检查取消与开关；
3. `badgeEnabled` 为假跳过（`632-635`）；
4. 每次**实时查询** `settings.badgeSetting == .enabled`，不可用则静默跳过（`636-642`）；
5. `setBadgeCount(unreadCount)`（`643`）。

`setBadgeEnabled(_:)`（`609-621`）：关闭时**主动清零桌面角标**（`616-619`），避免与开关状态不一致。开关默认 true（`164-168`，键 `messageCenterBadgeEnabled`）。
注意：这里**不复用** `NotificationManager.setBadgeCount`（那个带 UI 文案返回，仅供测试面板）。

### 2.10 深链投递 `launch(item:)`（`664-691`）

1. `launchTask?.cancel()`（`665`）、`launchState = .launching`；
2. `deepLink` 为空/`isEmpty` → `launchState = .failed("无法定位内容")` 并 warning（`667-673`）；
3. 经 `deliveryUserInfo(for:)` 生成 `userInfo`（`674`）；
4. `dismissRequest = UUID()`（`681`）—— 请求关闭消息中心 sheet（`TabBar.swift:9986-9989` 消费并置 nil），**让出 sheet 动画**；
5. `Task.sleep(450ms)` 后调 `NotificationManager.shared.handleNotificationTap(userInfo:source: "message_center")`（`682-688`），然后 `launchState = .idle`。

`deepLinkTargetDescription`（`693-700`）按 `orgArticle > article > mailbox > schoolProfile > partySubject > unknown` 优先级生成日志目标串。

### 2.11 诊断面板与修复

- `debugSnapshot`（`705-716`）：输出**存储路径 / 条目总数 / 未读 / 上限 / schema 版本集合 / 自动检查 / 角标联动**。入口：消息中心页长按标题 5 次（`702` 注释）。
- `repairRewrite()`（`719-732`）：当前内存态原子重写 + 立即回读校验，失败返回 false。

### 2.12 系统通知历史导入（`737-839`）

首次启动一次（`importDoneKey = "messageCenterImportedSystemOnce"`，`144`/`207-212`）：

- `getDeliveredNotifications` 用 `withCheckedContinuation` 包装成 async（`739-743`）——**注意这里没有用 async 版系统 API，也回避了 §1.10 的线程问题**；
- 跳过 `isTestNotification`（`748`）、按 `id` 去重（`753`）；
- `kind(from:)`（`768-778`）**判定顺序有讲究**：`mailboxId`/`deepLink=="principalMailbox"` → `schoolProfileDeepLink` → `partySubjectDeepLink` → `isBookmarkUpdate` → **`orgArticleId` 先于 `articleId`**（注释：机构通道同样携带 `articleTitle`，必须靠 `orgArticleId` 区分，`774`）→ `articleId`；
- `convert(info:kind:notification:)`（`782-839`）：**导入语义 = 24 小时内记为未读，更早的按已读归档**（`785` + 注释 `780-781`），避免升级当天历史轰炸。

### 2.13 `@Published` 清单

| 字段 | 行 | 备注 |
|---|---|---|
| `items: [MessageItem]` | 172 | `private(set)`，按 timestamp 倒序 |
| `unreadCount: Int` | 173-178 | `private(set)`，`didSet` 触发 `syncBadge()` |
| `latestItem: MessageItem?` | 179 | `private(set)` |
| `launchState: MessageLaunchState` | 180 | `private(set)` |
| `dismissRequest: UUID?` | 182 | 可写，供 `TabBar` 关闭 sheet |

### 2.14 视觉映射与时间工具

- `style(for:)`（`546-555`）：6 通道 → (SF Symbol, 颜色) 元组，如 `.orgUpdate → ("building.2.fill", .sjzTeal)`。
- `kindName(_:)`（`557-566`）：中文名，如 `.bookmarkUpdate → "收藏更新"`。
- `MessageTimeText`（`845-871`）：`relative(_:now:)` 相对时间（**注意 `seconds < 60` 统一返回「刚刚」，注释说明是为容纳时钟偏差导致的负值**，`848`）；`DayGroup`（今天/昨天/更早）分组。

---

## 3. BookmarkManager.swift（1354 行）

### 3.1 存储格式与路径

| 内容 | 路径/键 | 行 |
|---|---|---|
| 收藏数据（当前格式） | `Documents/SXJZIT_Cache/Bookmarks/bookmarks.json` | `247-248` |
| 旧版收藏（一次性迁移源） | `UserDefaults` 键 `bookmarkedArticles` | `129` |
| 固化图片目录 | `Documents/SXJZIT_Cache/BookmarkImages/{sha256}.img` | `249`、`769`、`793` |
| 设置：上限 | `bookmarkMaxCount` | `131` |
| 设置：自动缓存 | `bookmarkAutoCacheContent` | `132` |
| 设置：更新推送 | `bookmarkPushOnUpdate` | `133` |

- 目录可注入（`storageDirectory` / `cacheDirectory`，`240-251`），`DocumentDirectory` 取不到时回退 `NSTemporaryDirectory()`（`245-246`）——测试隔离友好。
- **写盘** `save()`（`1087-1096`）：`JSONEncoder().encode(bookmarks)` + `data.write(to:options:.atomic)`。**比 MessageCenterStore 的 tmp+replace 方案简单**（两者强度不同，值得在 Wiki 中对比）。
- **加载** `loadBookmarks()`（`1098-1142`）三级：
  1. 文件存在 → `decodeBookmarks` → 成功即用；`skipped > 0` 记 warning 并回写；`reconcileContentFlags()` 有修正也回写（`1100-1117`）；
  2. 文件解析整体失败 → 回退读**旧版 UserDefaults** `bookmarkedArticles`，迁移成功后 `removeObject` 清源（`1123-1139`）；
  3. 都失败 → 空数组（`1141`）。
- `decodeBookmarks`（`1168-1187`）：整段优先，失败则 `JSONSerialization` 逐条抢救，返回 `(items, skipped)`。
- **无 schemaVersion 字段**（对比 `MessageItem` 有），版本演进靠 `Codable` 默认值 + 容错解码。

### 3.2 `BookmarkItem` 模型（定义在 `Models.swift:1470-1564`，非本文件）

- 字段：`title/date/category/summary/imageUrl/articleId/href/author/source/columnId` + `bookmarkDate` + **可变状态四件套** `cachedContent`、`contentCached`、`lastViewedAt`、`updateDetectedAt`（`Models.swift:1483-1488`）。
- `id` = `readKey`（`Models.swift:1471`）。
- **`readKey` = `articleId ?? title + date`**（`Models.swift:1500`）——与 `NewsItem.readKey`（`Models.swift:399`，`articleId ?? id`）**不同**，也与机构文章的 `readKey`（`OrganizationDetailView.swift:67`，`articleId.isEmpty ? title + updateTime : articleId`）不同。三处口径需在 Wiki 中并列说明。
- `hasCachedContent`（`Models.swift:1495-1497`）：**以 `cachedContent` 实际内容判定，不信任 `contentCached` 标志位** —— 这是本模块「单一事实源」设计的基石，注释明确「标志位与内容不一致时由管理器自愈修正」。
- `hasPendingUpdate`（`Models.swift:1491`）：`updateDetectedAt != nil`。
- `originalArticleURL`（`Models.swift:1502-1516`）：href 绝对 → 相对拼域名 → `articleId` 造 `#/list/article?id=` → 首页兜底。

### 3.3 增删改查

| 操作 | 行 | 要点 |
|---|---|---|
| `isBookmarked(_ key:)` / `(_ item:)` | `308-315` | 以 `readKey` 比对 |
| `addBookmark(_ item:)` | `318-358` | 重复静默忽略；**上限检查在插入前**，超限置 `showLimitAlert`/`limitAlertMessage` 并 return（`326-333`）；`insert(at: 0)` 保持倒序；随后 fire-and-forget 自动缓存正文（`345-350`，受 `autoCacheContent` 门控）与固化缩略图（`353-357`） |
| `removeBookmark(_ key:)` | `362-377` | 同时 `removeCachedImage` 清理固化图片（`373-375`）；`@discardableResult` 返回是否实际移除 |
| `removeBookmark(_ item:)` | `380-382` | 转发 |
| `toggleBookmark(_ item:)` | `385-391` | 分流 |
| `toggleBookmark(articleId:title:date:...)` | `395-426` | 面向机构文章等非 `NewsItem` 来源；**key = `articleId.isEmpty ? title + date : articleId`**（`396`） |
| `markViewed(_ key:)` | `429-443` | 刷新 `lastViewedAt` 并**清除 `updateDetectedAt` 徽标**；分别埋点「最近阅读时间已更新」（debug）与「内容更新徽标已清除」（info，仅在原先有徽标时） |
| `removeBookmarks(_ keys: Set)` | `449-465` | 批量，返回实际移除数，逐个清图 |
| `clearAll()` | `469-482` | 清空全部并清图 |

**上限**：`maxCount` 默认 **500**（`257-258`）。`didSet`（`153-159`）**只落盘、不截断**；截断由 `applyMaxCountLimit()`（`282-291`，`prefix(maxCount)` + 回写）完成，而它的触发点在**视图层**：`TabBar.swift:11205-11207` 的 `.onChange(of: bookmarkManager.maxCount) { bookmarkManager.applyMaxCountLimit() }`。

> ⚠️ **与 `NotificationManager` 的不一致（实测）**：`NotificationManager` 的设置联动写在**模型内部的 `didSet`**（`112-114` 启停轮询、`118` 重启定时器）；`BookmarkManager` 则把联动外包给**设置页视图的 `onChange`**（`maxCount → applyMaxCountLimit`，`TabBar.swift:11205`；`pushOnUpdate → applyPushOnUpdateSetting`，`TabBar.swift:11208-11210`）。后果：任何非设置页路径修改 `maxCount`/`pushOnUpdate` 都不会生效截断或启停定时器。行为正确性依赖调用方自觉。

### 3.4 检索 / 筛选 / 排序 / 分组（`nonisolated static` 纯函数）

`filter(_:query:scope:sort:readKeys:)`（`492-529`）：

1. **范围** `BookmarkFilterScope`（`46-60`）：`.all` / `.unread`（依赖传入的 `readKeys` 已读快照）/ `.offlineReady`（`hasCachedContent`）/ `.category(name)`（`505-507`）；
2. **关键词**：对 `title/summary/category` 做 `localizedCaseInsensitiveContains`，空白视为无关键词（`509-516`）；
3. **排序** `BookmarkSortOrder`（`17-42`）4 种：`recentlyBookmarked`（`bookmarkDate` 降序）/ `recentlyPublished`（`date` 字符串降序）/ `recentlyViewed`（`lastViewedAt ?? .distantPast` 降序）/ `titleAscending`（`localizedCompare`）（`518-527`）。

`groupSections(_:now:calendar:)`（`532-543`）：按 `BookmarkTimeGroup`（今天/近 7 天/更早，`64-75`）分桶，**空组自动剔除**且保持时间倒序。

派生统计（`207-236`，注释「判定源加固」）：`contentCachedCount`（以 `hasCachedContent` 为准）、`precacheCandidates`、`precacheAvailability`（三元组，菜单三态判定的唯一数据源）、`categoryFacets`（分类计数降序，供筛选芯片动态生成）、`unreadCount(readKeys:)`。

### 3.5 更新检测（内容指纹）

- **定时器**：`updateCheckTimer`，间隔 `3600s`（`204-205`）；`startUpdateCheck()`（`958-965`）用 `Timer.scheduledTimer` + `Task { @MainActor }`；启动条件为 `pushOnUpdate` 为真 —— `init` 里恢复（`267-269`），设置变更由 `applyPushOnUpdateSetting()`（`294-303`）启停，后者的调用点在视图层（`TabBar.swift:11208-11210`，见 §3.3 的不一致说明）。
- **指纹 = 正文文本本身**：`isMeaningfulUpdate(old:new:)`（`546-551`）——旧缓存非空且与去首尾空白后的新内容不同即视为"有更新"。**没有额外的 hash/version 字段**，缓存正文同时充当离线内容与比对基线。
- `checkBookmarkedArticlesForUpdates(manual:)`（`976-1030`）流程：
  1. `bookmarks` 空 → 空报告（`982`）；非手动且 `pushOnUpdate == false` → 空报告（`983`）；
  2. 目标 = 有 `articleId` 的前 **12（手动）/ 10（自动）** 条（`985`）；
  3. 逐条：无缓存正文 → `skipped`（`996-999`）；否则调 `cacheArticleContent(..., isRefreshCheck: true)`，按 `BookmarkContentOutcome`（`79-86`：`cached/updated/unchanged/skipped/failed/cancelled`）计数（`1000-1015`）；
  4. `updatedItems` 非空**且** `pushOnUpdate` 才发通知（`1018-1020`）；
  5. 返回 `BookmarkUpdateCheckReport`（`90-96`：checked/updated/failed/skipped/elapsedMs），并埋点（`1025-1028`）。
- **发通知** `sendUpdateNotifications`（`1032-1083`）：
  - 先查 `authorizationStatus`，未授权直接返回（`1034-1040`）；
  - **最多 3 条**（`1042`），标识符 `bookmark-update-{readKey}`，`userInfo` 带 `isBookmarkUpdate: true`（`1047-1052`）；
  - 发送成功才 `ingest(kind: .bookmarkUpdate, ...)`（`1060-1072`）并记 info。
- **失败重试**：`cacheArticleContent` 的 catch 里用 `SJZImageKit.isCancellation(error)` 区分「取消」与「真失败」——取消静默（debug），真失败 warning（`601-613`），注释称「取消语义红线」（`602`）。

### 3.6 `cacheArticleContent` —— `await` 后下标复用隐患核实（**结论：已修复**）

`cacheArticleContent(forKey:articleId:isRefreshCheck:)`（`558-614`）逐行核实：

| 行 | 代码 | 安全性 |
|---|---|---|
| `559` | `guard let index = bookmarks.firstIndex(...)` | 取下标 |
| `561` | `if !isRefreshCheck && bookmarks[index].hasCachedContent { return .skipped }` | **await 之前**读，安全 |
| `563` | `let oldContent = bookmarks[index].cachedContent` | **await 之前**读，安全 |
| `565` | `let detail = try await NetworkService.shared.fetchArticleDetail(...)` | ⚠️ **挂起点**：期间 `bookmarks` 可能被增删改（取消收藏/清空/批量截断） |
| **`573`** | **`guard let currentIndex = bookmarks.firstIndex(where: { $0.readKey == key }) else { return .skipped }`** | ✅ **重新解析下标**——这正是修复点 |
| `575-579` | `bookmarks[currentIndex].cachedContent = content` / `.contentCached = true` / `.updateDetectedAt = Date()` | 用 `currentIndex` 写入，安全 |
| `586-587` | 日志读 `bookmarks[currentIndex].title` | 安全 |

**核实结论**：历史隐患（`await` 之后继续用第 559 行的 `index` 写入数组）**在当前实现中已经不存在**。修复形态是：**所有挂起点之后一律重新 `firstIndex` 定位；定位失败（条目已被删除）返回 `.skipped` 而非崩溃**。同时在 `checkBookmarkedArticlesForUpdates`（`1006`）与 `precacheAllContent`（`656`，走 `cacheContent(for:)` 内部重新取 `articleId`）里也都不复用旧下标。

> 附带观察：第 `562-563` 行在 `await` 前读 `oldContent` 是**必要**的——若在 `await` 后读，会读到被并发刷新覆盖的新值，`isMeaningfulUpdate` 将恒为 false。当前位置正确。

### 3.7 固化缓存（离线预热）

**正文侧**（`689-742`）：

- `offlineContentStats`（`692-697`）：篇数 / 字符数 / **UTF-8 字节**，注释强调口径与 `hasCachedContent` 严格一致（`691`）。
- `clearAllContent()`（`701-703`）与 `clearAllContent(keepingLatest:)`（`707-711`）：后者按 `bookmarkDate` 倒序保留前 N 篇。
- 公共实现 `performContentClear(shouldKeep:)`（`714-742`）：**先把进行中的批量缓存取消**（`715-717`，注释「避免与清理写入交叉」），再逐条清 `cachedContent = nil` + `contentCached = false`，返回清理数与释放字节。

**图片侧**（`744-883`）两级缓存：

1. 内存 `NSCache<NSString, UIImage>`：`countLimit = 200`、`totalCostLimit = 50MB`（`253-254`）；
2. 磁盘：`{sha256}.img` 文件。

- `loadCachedImage(for:)`（`764-776`）：内存 → `Task.detached(.utility)` 读盘 → `SJZImageKit.decode(maxPixel: 360)` **降采样解码** → 回填内存（`cost: data.count`）。
- `cacheImage(from:)`（`782-853`）流程：
  1. URL 归一化 + 构造，失败返回 false（`783-784`）；
  2. **内存命中即完成**（`788-791`）；**磁盘命中即完成**（`793-801`），只记节流命中日志（`logPersistHit`，`856-861`，用 `SJZImageKit.shouldLogHit` 按 URL 节流）；
  3. **优先复用共享 `URLCache`**：`SJZImageKit.usableCachedResponse(...)` 命中则直接用其 `data`，避免二次下载（`806-808`）；未命中才 `SJZImageKit.imageSession.data(from:)`（`811`）；
  4. 单张上限 `maxPersistedImageBytes = 8MB`（`200`/`823-828`），超限跳过并记 info；
  5. `Task.detached(.utility)` 原子写盘（`830-843`）；
  6. 解码 360px 回填内存（`844-846`）。
- `removeCachedImage(for:)`（`864-871`）：内存 + 后台磁盘删除，取消收藏 / 批量移除 / 清空时调用（`374`、`458`、`473`）。
- `clearImageCache()`（`875-883`）：清内存 + 后台清目录，返回 (files, bytes)。

### 3.8 `imageCacheKey`（`750-756`）

```swift
nonisolated static func imageCacheKey(for url: String) -> String
```
- 输入先 `trimmingCharacters(in: .whitespacesAndNewlines)` 归一化（`751`）；
- `CryptoKit` 的 `SHA256.hash(data:)` 输出 64 字符纯十六进制（`755`）；
- 注释列出三条理由（`746-749`）：① 不同 URL 无冲突；② 无 `/`、`+`、`=` 等路径不安全字符；③ 定长 64 无需截断。
- 依赖：`import CryptoKit`（`BookmarkManager.swift:14`）——**这是本模块唯一的外部框架依赖，且是系统框架（非第三方）**。

### 3.9 批量缓存与进度反馈（`627-687`）

`precacheAllContent()`：
1. 已有任务在跑 → 记 info 后忽略（`628-631`）——**单飞保护**；
2. 先记「批量缓存可用性评估」日志（`635-640`，字段与 `precacheAvailability` 同源，便于对账）；
3. 无候选 → 记 info 返回（`641-646`）；
4. `precacheProgress = PrecacheProgress(done: 0, total:)`（`648`）——`@Published`，驱动列表页进度条；
5. `precacheTask = Task { ... }`（`649`）内**顺序 for 循环**，每次 `Task.isCancelled` 检查（`655`）；
6. `cacheContent(for: item.readKey)`（`656`）——走公开入口，内部重新取 `articleId`（`618-624`），**不缓存旧的 item 下标**；
7. 逐条更新 `precacheProgress`（`658`）；
8. **进度采样日志**：首条 / 每 5 条 / 末条（`659-666`），注释「防刷屏且状态可对账」；
9. 结束后一次性汇总日志（`670-674`，含 `cancelled` 与 `cancelledItems`），`precacheProgress = nil`、`precacheTask = nil`（`675-676`）。

`cancelPrecache()`（`681-687`）：`cancel()` + 清 `precacheTask`/`precacheProgress`。

> 注意：`precacheTask`/`precacheProgress` 的清理写在 `Task` 闭包末尾（`675-676`），若任务在 `for` 中被 `cancel()`，循环因 `Task.isCancelled` 而 `break`（`655`），仍会走到末尾清理（`668-676`）——路径是闭合的。但 `cancelPrecache()` 本身也置 nil（`684-685`），两条路径都在主 actor 上，无竞态。

### 3.10 深链归因（payload 自描述 + launch 兜底）

这是收藏通道最容易踩坑的地方，代码用了**双保险**：

1. **系统通知路径（自描述）**：`sendUpdateNotifications` 在 `userInfo` 里手工塞 `isBookmarkUpdate: true`（`1047-1052`）。这样 `handleNotificationTap` 的第 6 步（`NotificationManager.swift:1095-1099`）能把已读回标到 `.bookmarkUpdate` 而不是 `news-{id}`。
2. **消息中心路径（payload 自描述）**：`DeepLinkPayload.isBookmarkUpdate = true`（`1068-1072`），`asUserInfo` 会转出同键（`MessageCenterStore.swift:62`）。
3. **`launch` 侧兜底（按 kind 补齐）**：`MessageCenterStore.deliveryUserInfo(for:)`（`655-661`）在 `kind == .bookmarkUpdate` 时**无论如何都补上** `isBookmarkUpdate = true` —— 注释明确此举「同时修复历史已落盘消息」（`654`），即早期入库、payload 里没带该标志的旧数据也能正确归因。

**回归验证设施**：`BookmarkDeepLinkSelfTest`（`1222-1354`，`#if DEBUG`）用启动参数 `-uiTestBookmarkDeepLink`（`1224`）跑完整闭环：重建自测收藏 → `debugInjectStaleBaseline` 注入哨兵旧基线（`1195-1207`）→ 打开 `pushOnUpdate` → 真实更新检测 → 定位入盒消息 → **分别走 `system_tap`（`1309`）与 `message_center`（`1320`）两条深链路径** → 还原开关 → 回执落盘 `Documents/bookmark_deeplink_selftest_done.json`（`1344-1348`）→ `LogManager.flushPendingNow()` 确保宿主能取到日志（`1352`）。宿主脚本 `Scripts/bookmark_deeplink_selftest.py`（注释 `1219`）。这是本仓库「可验证性」做得最好的一处。

### 3.11 诊断面板

`BookmarkStorageSnapshot`（`100-118`）：`total` / `contentCached` / `contentChars` / `imageFiles` / `imageBytes` / `storageFileBytes`，`summaryText`（`109-117`）输出人类可读摘要（含 MB/KB 换算）。
`storageSnapshot()`（`888-911`）：**目录扫描与文件大小全在 `Task.detached(.utility)`**，避免主线程 IO；随后状态用内存态拼装。
`rebuildStorage()`（`915-927`）：重写 + 回读校验 + **条数一致性比对**（`decoded.count == bookmarks.count`）。
`scanDirectory`（`930-943`）/ `removeDirectoryContents`（`946-954`）：只统计 `.typeRegular` 文件。

### 3.12 状态流转埋点

统一前缀「状态流转：」集中在 `favorite` 域，共 5 处：

| 埋点 | 行 |
|---|---|
| 最近阅读时间已更新（debug，含 `hadUpdateBadge`） | `437-439` |
| 内容更新徽标已清除（info，仅原先有徽标时） | `441` |
| 内容更新徽标点亮（info，含新旧字符数） | `585-588` |
| 收藏图片已固化（debug，含来源 `urlcache`/`network`） | `847-851` |
| 图片固化命中（debug，节流） | `858-860` |

另在 `storageSnapshot` 里有一条「存储快照」debug（`905-909`，注释「诊断面板对账依据」）。
`markViewed`（`429-443`）是「更新徽标」的唯一清除入口，与 `cacheArticleContent`（`578`）的点亮入口成对。

---

## 4. ReadStatusManager.swift（109 行）

- `@MainActor final class`，`static let shared`（`16-18`）。
- **存储键 `readArticleIds`，值为 `[String]` 数组**（`20`/`108`），存的是**有序插入序列**而非 `Set` —— 这是为了「超限精确淘汰最早」（注释 `27`）。
- 双结构：`_readIds: Set<String>`（O(1) 查询）+ `_order: [String]`（持久化顺序）（`26-28`）。
- `init(defaults:maxStoredIds:)`（`30-38`）：**可注入 `UserDefaults`（测试隔离）**，`maxStoredIds` 默认 **5000**；加载时用 `seen.insert($0).inserted` **去重保序**（`34-37`），注释「历史数据可能存在重复项」。
- 查询：`isRead(_ key:)`（`42-44`）、`snapshot: Set<String>`（`47`，供收藏页「未读」筛选等只读场景）、`unreadCount(in items: [NewsItem])`（`50-52`，按 `readKey` 过滤）。
- 标记：`markAsRead(_ key:)`（`56-63`，幂等 guard + `trimIfNeeded` + `persist` + `objectWillChange.send()`）、`markAsRead(_ item: NewsItem)`（`66-68`，转发 `item.readKey`）、**`markAsUnread(_ key:)`（`71-77`，回退标记未读，用于收藏页「标记为未读」）**、`markAllAsRead()`（`82-94`，来源是 `DataService.shared.allNews`，`83`）。
- **超限裁剪** `trimIfNeeded()`（`99-105`）：`overflow = _order.count - maxStoredIds`，淘汰 `_order.prefix(overflow)` 并从 `_readIds` 同步移除 —— 注释「保证最新已读状态永不丢失」。
  - ⚠️ **注意：`markAsUnread` 只移除键、不重新追加顺序**（`74`），因此「已读 → 标记未读 → 再次已读」会让该键排到队尾，属可接受行为，但意味着顺序语义是"最近一次从未读转为已读的时间"。
- `objectWillChange.send()` 手动触发（`62`/`76`/`93`）—— 因为 `_readIds`/`_order` 是普通私有属性而非 `@Published`，这是**手动变更通知**的写法。**没有 `@Published` 字段**。

**键设计与联动（实测）**：

- 键 = 各模型的 `readKey`，三处口径不同：`NewsItem.readKey = articleId ?? id`（`Models.swift:399`）、`BookmarkItem.readKey = articleId ?? title + date`（`Models.swift:1500`）、机构文章 `articleId.isEmpty ? title + updateTime : articleId`（`OrganizationDetailView.swift:67`）。
- 与列表红点/未读的联动点：`TabBar.swift:3442`（`markAsRead(news)`）、`OrganizationDetailView.swift:3085`（`markAsRead(readKey)`）、`BookmarkListView.swift:18`（观察 `snapshot` 做「未读」筛选）、`TabBar.swift:11233`（`markAllAsRead()`）、`TabBar.swift:10876-10890`（设置页展示 `unreadCount(in: data.allNews)`）、`TabBar.swift:9880`（`bookmarkManager.unreadCount(readKeys: bookmarkReadManager.snapshot)`）。
- **无键冲突**（实测）：`HelpGuideStore` 用的是 `helpGuideReadIds`（`HelpGuideStore.swift:30`），与本模块的 `readArticleIds` 不同名，两者的 `readArticleIds` 属性只是同名不同源。

---

## 5. AnnouncementManager.swift（339 行）

### 5.1 「零后端远控」开关的本质

- 抓取源固定为开发者 Docusaurus 博客：`https://www.43322.cn/blog/gonggao`（`46`）。
- **开关判定 = 标题字符串包含**（`138-139`）：
  ```swift
  let active = title.contains("公告开启")
  let closed = title.contains("公告关闭")
  ```
- 因此**改公告 = 改博客文章标题**，无需发版、无需后端接口。这是「零后端远控」的最简形态。
- ✅ **外部实测验证（本次分析执行）**：该 URL 现在 HTTP 200，原始 HTML 同时存在 `<h1 itemprop="headline">公告开启` 与 `id="__blog-post-container"` —— **`extractTitle`（`195`）与 `extractContent`（`216`）的两个解析锚点均与线上页面匹配**，当前会判定为「开启」并解析出正文。

### 5.2 抓取与解析

`fetchAnnouncement()`（`84-188`）：

1. `isLoading = true`（`85`）；
2. **`defer { isLoading = false }`（`86`）** —— 注释（`86`）明确记录这是 **2026-09-27 的修复**：「非 200/编码异常等路径曾致转圈永久」。下面连续 5 个 `guard ... return`（`89`/`104`/`110`/`116`/`126`）是当初漏掉复位的分支，`defer` 一次性覆盖全部提前返回路径。
3. 请求配置：`timeoutInterval = 15`、`cachePolicy = .reloadIgnoringLocalCacheData`（`99-100`）；会话在 `init` 里配置 `timeoutIntervalForRequest = 15` / `ForResource = 30`，并**显式注册 `RefererHeaderURLProtocol`**（`58-63`），注释「不依赖全局注册时序，保证网络监测埋点覆盖」（`61`）。
4. 逐级守卫：非 `HTTPURLResponse` → 「服务器无响应」（`104-108`）；非 200 → 「服务器返回 {code}」（`110-114`）；UTF-8 解码失败 → 「页面编码异常」（`116-120`）；无标题 → 「未找到文章标题」（`126-130`）。
5. 三分支判定（`141-165`）：
   - `active` → `isActive = true`，写 title/content，保存缓存；
   - `closed`（含"公告关闭"）→ 清空并保存；
   - **else（两者都不含）→ 与 closed 完全相同的清空逻辑（`157-165`，代码重复）**。
6. 错误分支（`167-187`）：`URLError` 按 `.timedOut` / `.notConnectedToInternet` / `.networkConnectionLost` / default 分别给中文文案，统一走 `applyFallback`。

`extractTitle`（`194-211`）：`<h1 itemprop="headline">` 到 `</h1>` 之间取文本，并手工替换 5 种 HTML 实体（`&amp; &lt; &gt; &quot; &#39;`，`205-209`）+ trim。
`extractContent`（`215-231`）：定位 `id="__blog-post-container"` → 找该标签的 `>` → `extractDivContent`。
`extractDivContent`（`234-263`）：**手写深度计数器**处理嵌套 `<div>`，`depth == 0` 遇到 `</div>` 终止（`241-249`），`<div` 后跟 `>` 或空格才计深度（`251-258`）——避免把 `<divx>` 之类误判。
`htmlToPlainText`（`269-271`）：**只做纯正则 `strippingHTMLTags()`**（实现在 `NetworkService.swift:1536`）。注释（`265-268`）给出重要历史原因：**绝不用 `NSAttributedString(.html)`** —— 后者走 `NSHTMLReader` → WebKit 内部加载，主线程调用时表现为 `-[NSHTMLReader _loadUsingWebKit]` 递归等待主队列 → UI 卡死（HangTracer hang）。

### 5.3 缓存与降级

- `AnnouncementCache`（`16-21`）：`title/content/isActive/fetchTime`，`Codable`。
- 缓存键 `announcementCache`，值是 **JSON `Data` 存进 `UserDefaults`**（`301`：`UserDefaults.standard.set(data, forKey:)`；`314` 读）。
- `saveCache()`（`293-303`）/ `loadCache()`（`305-311`，启动即加载，含 `lastFetchTime`）/ `loadCacheFromDisk()`（`313-319`）。
- **降级策略** `applyFallback(_ message:)`（`275-289`）：
  - 有缓存 → 沿用缓存的 `isActive/title/content`，**只把错误写进 `errorMessage`**（不清空当前状态）；
  - 无缓存 → `isActive = false` + 空标题正文 + 错误文案（「显示公告未开启」）。
- 定时刷新 `startAutoRefresh()`（`323-333`）：`refreshTimer?.invalidate()` 后 `Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true)`，`refreshInterval = 1800`（30 分钟，`48`），回调 `Task { @MainActor [weak self] }`；`init` 中先 `loadCache()` 再 `startAutoRefresh()` 再**立即首拉**（`66-72`）。
- `stopAutoRefresh()`（`336-339`）注释写「App 进入后台时可调用」——
  ⚠️ **实测：全仓库无任何调用点**（grep 仅命中定义处）。属于**预留但未接线的接口**；与 §1.8 一样，本项目实际上没有后台策略。

### 5.4 `@Published` 清单

`isActive`（32）、`title`（34）、`content`（36）、`lastFetchTime`（38）、`isLoading`（40）、`errorMessage`（42）—— 共 6 个。
消费侧：`AnnouncementDetailView.swift:16` 与 `:101` 两个视图各自 `@ObservedObject private var manager = AnnouncementManager.shared`。

---

## 6. 模块间依赖关系图

### 6.1 调用图（箭头 = 「调用/读取」）

```
                        ┌──────────────────────────────┐
                        │  NetworkService (共享单例)     │
                        │  fetchHome2 / fetchArticles   │
                        │  fetchPrincipalMailbox        │
                        │  fetchJSONDict                │
                        │  fetchPartySubjectFingerprint  │
                        │  fetchDeptHome2               │
                        │  fetchArticleDetail           │
                        └───────────▲───────▲──────────┘
                                    │       │
        ┌───────────────────────────┘       └────────────────┐
        │                                                     │
┌───────┴────────────────────────┐              ┌─────────────┴──────────────┐
│ NotificationManager  (@MainActor)│              │ BookmarkManager (@MainActor)│
│  · 5 通道指纹轮询                 │              │  · 收藏 CRUD / 离线正文固化   │
│  · UNUserNotificationCenter      │              │  · SHA256 图片固化(CryptoKit)│
│  · handleNotificationTap 深链枢纽 │              │  · 1h 更新检测(正文指纹)      │
└──┬──────────┬──────────┬────────┘              └───┬────────────────┬───────┘
   │          │          │                           │                │
   │ ingest    │ handle   │ 读 OrgFollowStore         │ ingest          │ handleNotificationTap
   │ (5 通道)  │ Tap      │ / OrgFollowArticleScanner │ (bookmarkUpdate)│ (仅 DEBUG 自测)
   ▼          ▼          ▼                           ▼                │
┌─────────────────────────────────────────────────────────────┐       │
│ MessageCenterStore (@MainActor)  ←── launch(item:) ──────────┼───────┘
│  · messageCenterEvents.json 事件库                            │
│  · 未读数 / 角标 syncBadge ──► UNUserNotificationCenter        │
│  · deliveryUserInfo: 收藏归因兜底                              │
│  · silentCheckNow / handleSceneActive ──► NotificationManager  │
└─────────────────────────────────────────────────────────────┘
             ▲                                        ▲
             │ 只读 items (未读/筛选)                   │ handleSceneActive()
             │                                        │
   ┌─────────┴──────────┐                   ┌─────────┴──────────┐
   │ MessageCenterView   │                   │ TabBar / DesignCodeApp│
   └─────────────────────┘                   └────────────────────┘

┌─────────────────────────┐        ┌──────────────────────────────┐
│ ReadStatusManager        │        │ AnnouncementManager           │
│  · UserDefaults 已读键集  │        │  · 博客页面解析 → 开关         │
│  · 被 TabBar/BookmarkList│        │  · UserDefaults 缓存 JSON     │
│    /Organization* 观察    │        │  · 仅 AnnouncementDetailView  │
│  · 依赖 DataService.allNews│       │    消费                       │
└─────────────────────────┘        └──────────────────────────────┘
```

**外部依赖（本 5 文件引用到的、定义在别处的符号）**：

| 被引用符号 | 定义位置 | 引用处 |
|---|---|---|
| `NetworkService`（含 `fetchPartySubjectFingerprint`） | `NetworkService.swift`（:1088） | `NotificationManager.swift:325,347,441,535,560,572,688,776,877`；`BookmarkManager.swift:565` |
| `OrgFollowStore` / `FollowedOrg` | `OrgFollowStore.swift:20,39` | `NotificationManager.swift:762,875` |
| `OrgFollowArticleScanner.candidates(from:)` | `OrgFollowStore.swift:125` | `NotificationManager.swift:777,878` |
| `MessageCenterStore` / `DeepLinkPayload` | `MessageCenterStore.swift` | `NotificationManager.swift:408,502,624,659,735,829,1012,1024,1044,1067,1096,1098`；`BookmarkManager.swift:1063` |
| `NotificationManager.handleNotificationTap` | `NotificationManager.swift:998` | `MessageCenterStore.swift:685`；`BookmarkManager.swift:1309`（DEBUG） |
| `DataService.allNews` | 数据层 | `NotificationManager.swift:942,1125`；`ReadStatusManager.swift:83` |
| `LogManager` | 日志层 | 全部 5 文件（域：`notification`/`messageCenter`/`favorite`/`announcement`/`notificationTest`） |
| `SJZImageKit`（`imageSession`/`decode`/`usableCachedResponse`/`isCancellation`/`shouldLogHit`/`makeRequest`） | `TabBar.swift:12369,12448` | `BookmarkManager.swift:603,773,806,811,844,857` |
| `String.strippingHTMLTags()` | `NetworkService.swift:1536` | `AnnouncementManager.swift:270` |
| `RefererHeaderURLProtocol` | `RefererHeaderURLProtocol.swift:18` | `AnnouncementManager.swift:62` |
| `SHA256` | `CryptoKit`（系统框架） | `BookmarkManager.swift:755` |

**四个 Manager 之间没有互相直接持有**，全部通过 `static let shared` 单例 + 单向调用解耦；唯一的双向关系是 `NotificationManager ↔ MessageCenterStore`（前者 `ingest`，后者 `silentCheckNow`/`launch` → `handleNotificationTap`），但**不构成循环持有**。

### 6.2 共享存储键总表（`UserDefaults` / `@AppStorage`）

| 键 | 类型 | 归属 | 定义行 | 外部读写点 |
|---|---|---|---|---|
| `notificationEnabled` | Bool | NotificationManager | `111` | `TabBar`（设置页 Toggle） |
| `notificationPollingMinutes` | Int | NotificationManager | `117` | `TabBar.swift:10808` |
| `notificationLastCheckTime` | TimeInterval | NotificationManager | `129/131/202` | — |
| `notifiedArticleIds` | [String] ≤2000 | NotificationManager | `157/161` | — |
| `notifiedMailboxIds` | [String] ≤2000 | NotificationManager | `167/170` | — |
| `notifiedOrgArticleIds` | [String] ≤3000 | NotificationManager | `176/180` | — |
| `orgFollowBaselineEstablished` | Bool | NotificationManager | `185` | — |
| `schoolProfileBaseline` | String `a\|b\|c` | NotificationManager | `533` | — |
| `partySubjectBaseline` | String `a\|b\|c\|d` | NotificationManager | `683` | — |
| `messageCenterMaxCount` | Int（默认 200） | MessageCenterStore | `140` | — |
| `messageCenterAutoCheck` | Bool（默认 true） | MessageCenterStore | `141` | — |
| `messageCenterBadgeEnabled` | Bool（默认 true） | MessageCenterStore | `142` | — |
| `messageCenterLastAutoCheckTime` | TimeInterval | MessageCenterStore | `143` | — |
| `messageCenterImportedSystemOnce` | Bool | MessageCenterStore | `144` | — |
| `bookmarkedArticles` | Data（旧版，迁移后删除） | BookmarkManager | `129` | — |
| `bookmarkMaxCount` | Int（默认 500） | BookmarkManager | `131` | — |
| `bookmarkAutoCacheContent` | Bool（默认 true） | BookmarkManager | `132` | — |
| `bookmarkPushOnUpdate` | Bool（默认 false） | BookmarkManager | `133` | — |
| `readArticleIds` | [String] ≤5000 | ReadStatusManager | `20` | — |
| `announcementCache` | Data(JSON) | AnnouncementManager | `47` | — |
| `privacyConsentAccepted` / `privacyConsentRejected` | Bool | DesignCodeApp | `DesignCodeApp.swift:17-18` | **门禁 NotificationManager 轮询恢复**（`:150`） |

> 键名冲突实测结论：**无冲突**。`HelpGuideStore` 的 `helpGuideReadIds`（`HelpGuideStore.swift:30`）与 `readArticleIds` 不同名，尽管两者都有名为 `readArticleIds` 的属性。

### 6.3 共享文件路径总表

| 路径 | 归属 | 定义行 |
|---|---|---|
| `Documents/MessageCenter/messageCenterEvents.json` | MessageCenterStore | `195-197` |
| `Documents/MessageCenter/messageCenterEvents.json.tmp` | 原子写临时文件 | `308-309` |
| `Documents/MessageCenter/messageCenterEvents.corrupt-{ts}.json`（保留 5 份） | 损坏备份 | `234-236`、`326-336` |
| `Documents/SXJZIT_Cache/Bookmarks/bookmarks.json` | BookmarkManager | `247-248` |
| `Documents/SXJZIT_Cache/BookmarkImages/{sha256}.img` | 固化图片 | `249`、`769`、`793` |
| `Documents/bookmark_deeplink_selftest_done.json` | DEBUG 自测回执 | `1344-1345` |

---

## 7. 未验证 / 存疑点（务必在 Wiki 中标注）

**已由本次分析外部验证的**：
- ✅ `https://www.43322.cn/blog/gonggao` 当前 HTTP 200，原始 HTML 同时包含 `itemprop="headline">公告开启` 与 `id="__blog-post-container"`，与 `extractTitle`（`195`）/ `extractContent`（`216`）的解析锚点一致，当前判定为「开启」。

**未验证（本次仅静态阅读代码，未编译、未真机运行）**：
1. **async 版 delegate 导致主线程崩溃**（`NotificationManager.swift:951-956` 注释）—— 属代码注释声明，未独立复现；注释描述的 `-[NSHTMLReader _loadUsingWebKit]` 卡死（`AnnouncementManager.swift:266-268`）同理。
2. **「首次启用仅建立基线，避免把历史 12 封全部轰炸」中「12 封」的具体数字**（`NotificationManager.swift:438` 注释）—— 未核对线上信箱真实条数。
3. **`notifiedArticleIds` 的「上限 2000」语义**：`get` 返回 `Set<String>`（`157`），`set` 做 `Array(newValue.suffix(2000))`（`160`）——**`Set` 无序，`suffix(2000)` 保留的不是"最新 2000 条"而是一个哈希序上的任意子集**。三个集合（`160`/`169`/`179`）写法相同。代码意图（"防止无限增长"）能达到，但"保留最近"的隐含语义**无法保证**。这是静态语义层面的确定结论，但**其对推送准确性的实际影响程度未实测**。
4. **`markExistingArticlesAsNotified()` 的读写放大**（`941-948`）：每次 `.insert()` 都触发「读 stringArray → 拷贝 → 写回」一遍，文章数为 N 时是 O(N) 次 `UserDefaults` 读写 + N 次数组拷贝。未实测在真实 N 下的耗时。同问题存在于 `421-423`（≤5 次，可忽略）。
5. **`handleSceneActive` 的静默检测可能被丢弃**：`checkForUpdates` 的 `guard !isChecking else { return }`（`303`）会让与定时轮询撞车的静默检测**无声跳过**，且不更新 `messageCenterLastAutoCheckTime` 之外的补偿机制（实际上 `handleSceneActive` 在触发前就已写入时间戳，`589`）→ **撞车一次就白等 30 分钟**。逻辑链已核实，实际发生频率未测。
6. **`BookmarkManager` 的设置联动依赖视图层 `onChange`**：`applyMaxCountLimit()` 的**唯一**调用点是 `TabBar.swift:11205-11207`，`applyPushOnUpdateSetting()` 的唯一调用点是 `TabBar.swift:11208-11210`（模型内部 `didSet` 不做联动，`153-159`/`171-177`）。因此「设置页之外修改 `maxCount` 或 `pushOnUpdate`」不会截断数据、也不会启停更新检测定时器 —— 这与 `NotificationManager` 把联动内聚在 `didSet`（`112-114`/`118`）的写法不一致。已核实当前唯一入口就是设置页，故**暂无实际 bug**，但属易碎耦合。
7. **概况/党建通道的「通知 identifier 固定、入盒 id 用毫秒时间戳」不一致**（`618` vs `626`；`729` vs `737`）：系统通知会互相覆盖（只留最新一条），但消息中心会**累积多条**同类消息。是否有意为之未从注释确认。
8. **收藏更新通道不参与「立即检查 / 前台自动检查」**（§2.8，因 `checkForUpdates` 不含该通道）：这是结构性事实，但**是否有意设计**未有注释说明。
9. **`AnnouncementManager.stopAutoRefresh()` 无调用点**（`336-339`）：注释说「App 进入后台时可调用」，实际未接线，定时器在前台常驻。
10. **`AnnouncementManager` 三分支中 else 与 closed 分支代码完全重复**（`149-156` vs `157-165`）—— 纯代码质量观察，无功能影响。
11. **`BookmarkItem` 无 `schemaVersion`**（对比 `MessageItem` 有，`MessageCenterStore.swift:93`）：收藏数据的版本迁移能力弱于消息中心。
12. **两处 `save()` 强度不一致**：`BookmarkManager.save()` 用 `write(.atomic)`（`1090`），`MessageCenterStore.writeAtomically()` 用 tmp + `replaceItemAt`（`307-316`）。后者注释声称「容器边界场景更可控」，但**收藏数据文件未采用该方案**，且收藏文件里包含更贵的离线正文。
13. **`Timer.scheduledTimer` 未加入 `.common` RunLoop mode**：`NotificationManager.swift:278`、`BookmarkManager.swift:960`、`AnnouncementManager.swift:325` 三处均用默认 mode，用户长按/滚动跟踪期间定时器不触发。影响面未实测。
14. **`silentCheckNow` 的日志文案「五通道检测」**（`MessageCenterStore.swift:570`）与实际 5 条通道一致，但**不含收藏通道**—— 若 Wiki 要宣称"消息中心覆盖全部推送通道"，此处为反例。

---

## 8. 设计评价与可提炼的「模式」

**值得写入 Wiki 的正面模式**：

1. **基线先行（baseline-first）**：所有集合/指纹类通道在"首次见到数据"时**只登记不推送**，把"历史数据"与"新增数据"在时间轴上切开（`NotificationManager.swift:452-461`、`586-593`、`695-702`、`780-785`）。这是无服务端轮询下避免"升级即轰炸"的通用解法。
2. **基线结构变更的静默升级**：概况的两段→三段（`595-634`）、党建的结构不符重建（`705-712`）——**宁可漏报一次，也不误报历史**。
3. **并集写回去重集**（`854-856`）：跨异步边界修改共享集合时用 `union` 合并而非整集覆盖，防"读到旧快照 → 写回 → 丢掉并发新增"。
4. **单一事实源（single source of truth）**：`hasCachedContent` 以实际内容为准，标志位失真由 `reconcileContentFlags()`（`1148-1164`）在加载时自愈并回写。
5. **深链的 payload 自描述 + 消费侧兜底**（§3.10）：跨版本数据也能正确归因，且兜底同时"修复历史消息"。
6. **给危险断言配可执行回归**：`BookmarkDeepLinkSelfTest`（`1222-1354`）+ 启动参数 + 回执落盘 + 宿主脚本，把"点击通知闪退"这类难复现问题变成可无人值守验收的用例。
7. **「绝不在系统回调同步链里做 UI」**：`handleNotificationTap` 只改 `@Published`，UI 侧 `onChange` 消费（`NotificationManager.swift:996-997`），配合 `pendingXxx` 全部带 `UUID` 保证 `onChange` 必触发（`36-50`）。
8. **`defer` 复位 loading**：`AnnouncementManager.swift:86` 一次性覆盖 5 个提前返回分支，注释保留了 bug 的日期与症状，可作"为什么用 defer"的教学案例。

**可改进项（已在 §7 编号列出，此处按优先级排序）**：

- P0：`Set.suffix(n)` 语义错误（§7.3）—— 若真需要"保留最新"，应改为有序数组 + 尾部截断（参考 `ReadStatusManager` 的 `_order` 设计，`ReadStatusManager.swift:27-28`/`99-105`，**同一个仓库里已有正确范式**）。
- P1：收藏上限调小后不裁剪（§7.6）；静默检测被丢弃且无补偿（§7.5）。
- P2：`markExistingArticlesAsNotified` 的 O(N) 次 UserDefaults 读写（§7.4）；收藏 `save()` 原子性弱于消息中心（§7.12）。
- P3：文档层面的「第五通道」命名冲突（§0.2）、`stopAutoRefresh` 死代码（§7.9）、重复分支（§7.10）。
