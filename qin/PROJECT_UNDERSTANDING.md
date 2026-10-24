# 项目理解档案

最后更新：2026-09-27（真机复测复核）｜已推进到：阶段 1-4 完成、阶段 5 档案已生成；文档体系已重建为 docs/code-wiki 分册；git 仓库已重建｜下次从这里继续：拿到新功能需求后进入设计开发

> 勘误（2026-09-27）：本文正文行号为 2026-09-22 快照，已核实的偏移示例：`exit(0)` L760→L763、TabBar 深链调度 L71→L82、BookmarkManager idx L243-252→L242 区、DisplaySettingsManager `applyRuntimeEffects` L329→L855、`performArticleSearch` L1422→L1559；其余行号一律以 `docs/code-wiki/` 分册（2026-09-27 基线）为准。

## 一、核心记忆区（每次对话必读）

**是什么**：「园枢」——山西晋中理工学院校园信息聚合 iOS App（Xcode 工程名 DesignCode）。纯 SwiftUI + 系统框架，零第三方依赖、无后端。用户=师生家长。数据源=学校公开 API `gwqietap.sxjzit.edu.cn/mapi` + 开发者博客 `www.43322.cn/blog`（公告/协议文本）。"做成"=学校数据可靠同步展示、离线可用、辅助功能稳定、能过 App Store 审核。

**当前进度**：源码 56,356 行（46 文件，主 target 44 文件 54,977 行）已全量通读；文档体系重建为 `docs/code-wiki/` 八分册（2026-09-27 基线）；真机验证闭环完成（历史：11 用例全绿 → 2026-09-26 83 用例全绿；**2026-09-27 真机复测 83/83 通过**，日志 `build/verify/retest_20260927b.log`）。下一步=重建 git + 拿到新功能需求后进入设计开发。

**锁死的决定**（原因）：① 只真机调试（iPhone iOS 27.0，UDID `00008110-000411A40EC1401E`），不用模拟器（用户指定）；② 经典 `.tabItem`，禁用 iOS 26 Liquid Glass Tab（曾卡顿）；③ 通知 delegate 只用完成回调版，禁用 async 版（async 版后台队列派发→点击通知主线程崩溃）；④ 三层数据降级不可破坏：远程→本地 JSON→静态兜底；⑤ 中文错误文案+中文注释，按钮必加 `contentShape(Rectangle())`。

**红线与禁忌（绝对不能碰的文件/写法）**：
- 禁写 `@AppStorage + didSet`、`@Sendable Task` 捕获 `inout`
- 禁在通知回调同步链中弹 sheet（走 pendingDeepLink 延迟调度，TabBar.swift L82）
- 改动需先单独确认的文件：[PrivacyPolicyView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyPolicyView.swift)（L763 有 `exit(0)` 审核红线）、[PrivacyLegalTexts.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/PrivacyLegalTexts.swift)（与实现矛盾，改法未定）、[project.pbxproj](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode.xcodeproj/project.pbxproj)（`-disable-sandbox`、部署目标 13/26 不一致）、[RefererHeaderURLProtocol.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift)（全局网络拦截）、NotificationManager delegate 区（闪退根因区）、OrganizationDetailView 下拉刷新区（已修，回归敏感）
- git 仓库：2026-09-27 已在 `~/Downloads/designcode-swiftui` 重建（main 分支，初始提交 b88e430；远端双备份：origin = GitHub 私有仓 kkkh/Garden-iOS、gitee = Gitee 镜像 oai/garden-ios，均已推送；原 `~/Pictures` 主仓库悬空指针已移除；构建产物/备份快照/Xcode 用户态已入 .gitignore）

**风格与协作**：改动前先出方案文档并确认（根因优先，不搞模糊正确）；所有代码注释中文；任何功能点接 LogManager 埋点（模块短名）；回复要点式、行号/出处必备。

**已知坑**：BookmarkManager.swift L242 区 `await` 后复用 idx 下标越界；LogManager.swift L218-275 `cleanEmptyFiles` 与"保留 7 天"注释矛盾；搜索 columnId 三处硬编码（OrganizationView L1441-1446、OrganizationDetailView L737-742/L3497-3502）；生产 `print` 残留（DataService L846-860、TabBar LongImage/FullScreenImage；全库实测 32 处/5 文件）。（2026-09-27 修复：机构降级搜索失效 ID → 运行时动态解析；AnnouncementManager isLoading → defer 复位；字体下载 → 60s 超时兜底；均经真机 83/83 终验。）

## 二、架构地图

**分层**：SwiftUI 视图（主 target 44 文件平铺，无子目录）→ `@MainActor` 单例群（NetworkService 为 `@unchecked Sendable`；核心类关系图见 docs/code-wiki/03 §3.0）→ 持久化（UserDefaults/Keychain/NSCache/`Documents/SXJZIT_Cache/` 文件 JSON + `Documents/MessageCenter/`）。视图直连单例，无 DI、无协议层。

**分级**：
- 核心：DataService、NetworkService、Models、TabBar 主链路（MainTabView/HomeView/NewsListView/EnhancedNewsDetailView）、OrganizationView/OrganizationDetailView
- 支撑：12 个 Manager + 各自视图
- 边缘：DesignCodeApp 编排、RefererHeaderURLProtocol、Splash、plist/pbxproj、测试

**"找 XX 看哪"（文件→函数）**：
- 启动/隐私分流 → DesignCodeApp.swift `body`(L29)、`onChange(isAppReady)`(L125)
- 通知点击弹详情 → TabBar.swift `consumePendingDeepLink`(L37)、`scheduleNotificationArticlePresentation`(L71)
- 数据同步 → DataService.swift `syncIfNeeded`(L176)、`doFullSync`(L196)、`safeFetchArticles`(L592)
- 文章详情解析/缓存 → DataService.swift `loadArticleFullDetail`(L639)、`parseArticleDetail`(L781)、`extractImages`(L832)
- 网络/DTO → NetworkService.swift `get`(L72)、`fetchHome2`(L154)、`fetchArticleDetail`(L176 双 session)、`fetchDeptHome2`(L875)、`safeImageURL`(L280)
- 模型/兜底 → Models.swift `SchoolInfo`(L10)、`NewsItem.originalArticleURL`(L406)、`default*`(L51-727)
- 首页模块控制 → HomeModuleManager.swift `visibleOrderedModules`(L156) + TabBar `HomeView.body`(L402)
- 新闻详情 → TabBar.swift `EnhancedNewsDetailView.loadDetail`(L2293)
- 机构详情/降级 → OrganizationDetailView.swift `loadData`(L1371)、`fetchArticleDetailWithFallback`(L3336)、`parseSections`(L1615)、`withTimeout`(L3593)
- 机构搜索 → OrganizationView.swift `performArticleSearch`(L1422)、防抖(L292)
- site_key 匹配 → OrganizationManager.swift `updateSiteKeys`(L245)、`syncFromAPI`(L392)
- 收藏/图片 → BookmarkManager.swift `addBookmark`(L112)、`cacheArticleContent`(L242 ⚠️)、`imageCacheKey`(L310)
- 通知 → NotificationManager.swift `checkForUpdates`(L245)、`handleNotificationTap`(L404)
- 显示/排版 → DisplaySettingsManager.swift `applyRuntimeEffects`(L329)、`displayText`(L520)、`DisplayFontFactory`(L475)
- 生物识别 → BiometricSecurityManager.swift `authenticate`(L328)、`performEvaluation`(L365)、Keychain(L500)
- 日志 → LogManager.swift `log`(L136)、`writeToDisk`(L218 ⚠️)、`crashWrite`(L337)
- 隐私降级 → PrivacyManager.swift `fetchDocument`(L108)
- 公告 → AnnouncementManager.swift `fetchAnnouncement`(L82，标题判定 L135)
- 测试 → NetworkServiceDTOTests.swift（22 用例：8 离线 + 3 在线 + 11 阅读统计）；MessageCenterStoreTests.swift（61 用例：消息中心 24 + 首页模块 5 + 校园日历 3 + 网络监测逻辑 10 + 显示设置逻辑 19）

## 三、实现要点

**核心调用链**（入口→存储）：
① 冷启动：`DesignCodeApp.init` 注册 URLProtocol → 1s 后 `isAppReady` → 按隐私状态分流 → `MainTabView.task` 0.5s `syncIfNeeded` → `doFullSync`（并行 home2+head+foot → 荣誉/5 新闻栏目分页 → 视频 TaskGroup 并行提取 → 院系合并预置数据 → `updateSiteKeys` → 写 21 个 JSON 缓存 → 后台加载 ZSW/专业）。
② 通知→详情：didReceive（回调版）→ 立即回执 → `handleNotificationTap` 设 `pendingDeepLink`（新 UUID）→ 等 `active && !isLockEngaged`（≤3s）→ +350ms → sheet 详情。
③ 机构详情：`loadData`（12s 超时、3 试重试、5xx/noData 跳重试）→ `parseSections` → 第 2-3 页补充 → 失败降级 `loadFallbackArticles`（4 栏目并行搜关键词）；文章详情 5 个 siteId 并行取最长内容。

**数据流**：产出=API → DTO（全 Optional+CodingKeys）→ 业务模型（Models.swift）→ `@Published` 单例 → 视图；落盘=UserDefaults（设置/收藏/已读/快照）+ 文件 JSON（同步缓存 21 键）+ Logs 日轮转 + Keychain（生物令牌）。

**设计意图（为什么）**：三层降级=学校 API 不稳的容灾；双 URLSession=列表实时、详情可缓存；遍地 `Task.isCancelled` + 非结构化 Task 承载拉取=FIX_PLAN"下拉刷新被自身取消"事故的教训固化；公告开关靠标题字符串判定=零后端远控；缓存与 `staticData` 合并 siteKey=旧缓存升级路径。

## 四、隐性知识

- **约定**：UserDefaults 布尔用 `object(forKey:) != nil ? bool : default` 区分未设置；枚举存 rawValue；Key 全 `private static let`；`*Service`=网络、`*Manager`=管理、模型集中 Models.swift；日志模块短名（ui/data/network/cache/privacy/notification/favorite/organization/biometric/display/articleSync/notificationTest…）。
- **隐式依赖/顺序**：CacheModeManager 先于 DataService.refreshCacheLimits 可用；`HomeModule.dataCount` 必须主线程；ZSW 详情仅缓存模式写 NSCache；隐私同意是通知轮询前提；`colorSchemePreference` 与 DisplaySettingsManager 共享同一存储键。
- **技术债**：print 残留（DataService L846-860、TabBar 两处）、columnId 魔法串 ×3、`cleanEmptyFiles` 语义矛盾、`cacheArticleContent` idx 越界隐患、`loadTask` 无 onDisappear 取消；测试无 skip、无注释掉的用例；3 个在线测试绑定真实数据量断言（学校数据变化会挂）。

## 五、风险与未决

**致命缺口**：① git 状态（已于 2026-09-27 重建）；② 隐私文本三矛盾（"不申请 Face ID" vs 实现申请；"全 HTTPS" vs ATS 放行 HTTP 且图片被改 http；"缓存 LRU/日志 7 天" vs 实际）；③ 审核高危 `exit(0)`、`-disable-sandbox`、部署目标 13/26 不一致。

**尚未确认**：用户背景 6 项（部署/发布、环境数、外部依赖额度、团队、分支策略、历史包袱）始终留空；测试文件"要闻" columnId `41cb4c…` 与搜索用 `f9730c…` 对不上；`cleanEmptyFiles` 是 bug 还是有意简化；全景报告行数失真原因；FIX_PLAN 改动已逐字确认落地但实施时间不可考。

**我无法验证的部分（诚实）**：学校 API 与 43322.cn 的真实响应时序/限流/字段漂移；线上真实数据规模下的性能与并发（正则解析、HTML 剥离均未实测）；Face ID 对话框与 scenePhase 的运行时交互时序；真机单测是否全绿（正在跑）；真实用户设备上的通知横幅/角标行为。