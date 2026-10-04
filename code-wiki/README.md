# 「园枢」山西晋中理工学院 App — Code Wiki

> **基线**：Git 提交 `6fc702e`（2026-10-04，`main` 分支）——本轮（2026-10-04）在 `215ea30`（2026-10-02）之上做**增量核验与同步**：阅读时光（日/周/月/年报表 + 目标 + 分享战报）、链路 J、七分册口径刷新（详见「本轮增量」）。
> **生成方式**：以源码为唯一事实源，全部结论经 `wc -l` / `grep -n` / `read` 逐符号实测；文档内所有行号均可复现。
> **源码根目录**：`qin/DesignCode/`（Xcode 工程名 `DesignCode`，App 显示名「园枢」）

---

## 这套文档是什么

一份**从源码逆向生成**的完整工程档案，覆盖 5 个必需维度 + 2 个增强分册：

| 你想要的 | 对应分册 |
|---|---|
| 项目整体架构 | [01-项目整体架构](01-项目整体架构.md) |
| 主要模块职责 | [02-主要模块职责](02-主要模块职责.md) |
| 关键类与函数说明 | [03-关键类与函数参考](03-关键类与函数参考.md) |
| 依赖关系 | [04-依赖关系](04-依赖关系.md) |
| 项目运行方式 | [05-项目运行方式](05-项目运行方式.md) |
| （增强）接口契约与调用链 | [06-接口契约与调用链](06-接口契约与调用链.md) |
| （增强）全量类型与符号索引 | [07-附录-类型与符号索引](07-附录-类型与符号索引.md) |

---

## 文档导航

| # | 分册 | 内容概要 |
|---:|---|---|
| 1 | [01-项目整体架构](01-项目整体架构.md) | 项目定位、技术栈、实测规模、三层架构、目录结构、**启动流程**、**7 条关键执行链路**（含 Mermaid 时序）、**14 条设计决策记录（ADR）**、非功能性设计、**技术债清单** |
| 2 | [02-主要模块职责](02-主要模块职责.md) | **31 个模块**逐一说明：职责、边界、文件与行数、关键类型、数据流、存储键、技术债。含机构模块（12,147 行）、通知体系（5+1 通道）与**阅读时光（2,645 行，2026-10-03 新增 / 2026-10-04 分享改造）**的深度拆解 |
| 3 | [03-关键类与函数参考](03-关键类与函数参考.md) | 核心类关系图、按领域分组的**关键类与方法签名 + 精确行号**、**13 段非平凡算法伪代码**、符号检索速查 |
| 4 | [04-依赖关系](04-依赖关系.md) | 依赖总图、**模块依赖矩阵**、**95 个 UserDefaults 键全表**、文件路径总表、内存缓存与 Keychain、**数据一致性规则**、耦合风险清单、外部依赖 |
| 5 | [05-项目运行方式](05-项目运行方式.md) | 环境要求、工程结构、Info.plist / entitlements / 导出配置、**构建命令**、**测试套件（255 例）**、**14 个自动化脚本**、真机安装调试、三远端备份、构建产物、常见任务、排障、**12 条工程红线** |
| 6 | [06-接口契约与调用链](06-接口契约与调用链.md) | 网络层契约、**15 条 API 路径 + 完整方法签名**（含 `teacher/page` 与 POST `recruit/query`）、DTO 约定、**10 条函数级调用链时序图**（含 2026-10-03 链路 J 阅读时光）、模块间契约（含 §6.5.6 隔离契约）、错误处理与降级、兼容策略 |
| 7 | [07-附录-类型与符号索引](07-附录-类型与符号索引.md) | **426 个顶层声明**按文件索引（含行号）、测试索引、**35 个单例清单**、**42 个日志域总表** |

---

## 一页速览

### 这是什么项目

| 项 | 内容 |
|---|---|
| 名称 | **园枢** — 山西晋中理工学院第三方 iOS App |
| 工程名 | `DesignCode`（Bundle ID `com.qinchao`） |
| 技术栈 | **纯 SwiftUI** + 系统框架；Swift 5；iOS 26.0+（实际生效值） |
| 第三方依赖 | **仅 1 个**：微信开放平台 SDK 2.0.8（XCFramework 静态库） |
| 数据来源 | 学校公开 API `https://gwqietap.sxjzit.edu.cn/mapi`（GET 为主 + 1 条 POST 招生查询）+ 开发者博客 `www.43322.cn` |
| 后端 | **无**。无服务端、无账号体系、无自有推送服务 |
| 调试设备 | 「秦超的iPhone」iPhone 13 Pro Max，UDID `00008110-000411A40EC1401E`（2026-10-04 实测 **`available`**，可实跑） |
| 远端备份 | 三远端：`origin`(GitHub) / `gitee`(Gitee) / `cnb`(腾讯 CNB) |

### 一句话架构

> 一个**无服务端的纯客户端信息聚合 App**——用**客户端轮询 + 本地指纹比对**替代服务端推送，用 **`URLProtocol` 全局拦截**替代服务端遥测，用**三层降级**（远程 → 本地 JSON → 静态兜底）替代服务端高可用。

### 实测规模

| 指标 | 数值 |
|---|---:|
| 主 target | **56 文件 / 71,392 行** |
| 测试 target | **6 文件 / 4,510 行** |
| **代码总计** | **62 文件 / 75,902 行** |
| 顶层声明 | **426**（397 类型 + 29 extension） |
| 单元测试用例 | **255**（16 个测试类，**2026-10-04 真机全量实跑 255/255 通过**） |
| 单例（`static let shared =`） | **35** |
| `LogManager` 调用点 | **1,422**（**1,405 处字面量域埋点 / 42 个日志域**） |
| UserDefaults 键 | **95** |
| API 路径 | **15**（19 方法 + 2 个 `fetchJSONDict` 重载 + 通用 `post()`） |
| 最大文件 | `TabBar.swift` **14,027 行**（89 个顶层声明、51 个 View） |
| 新增模块（2026-10-03） | **阅读时光**：6 文件 / 2,645 行（Store+View+目标+滚轮+触觉；2026-10-04 分享改造 +312） |

### 五大 Tab

`首页` · `院系` · `资讯` · `校园` · `我的`

### 最值得先读的四件事

1. **无服务端推送体系**（[02 §2.13](02-主要模块职责.md)）——`NotificationManager` 内 5 条检测通道（新闻 / 校长信箱 / 学校概况 / 党建专题 / 机构动态）+ `BookmarkManager` 第 6 条（收藏更新），全部靠「官网指纹 + 本地集合 diff」，配合「基线先行」策略避免升级即轰炸。
2. **通知深链防崩溃调度**（[01 §1.6 链路②](01-项目整体架构.md)）——历史事故「点击通知闪退」的根因是**在系统通知回调同步链中弹 sheet**；现方案是 `@Published` 状态驱动 + 等待前台活跃与 Face ID 解锁（≤3s）+ 再让出 350ms runloop 周期。
3. **零闪烁图片管线**（[02 §2.28](02-主要模块职责.md)）——`SJZCachedImage` 在 `init` 同步查内存缓存实现首帧直出，配两级缓存 + `actor` 并发闸（≤4）+ 解码缓存双档限额 + 坏条目自愈 + blur-up 占位。
4. **纯本机的「阅读时光」**（[02 §2.31](02-主要模块职责.md)、[06 §6.4 链路 J](06-接口契约与调用链.md)）——真实停留口径（进入→离开、后台暂停、单次 <5s 不计）、13 处一行挂载、事件 FIFO 2000 + **按天 rollup 永久保留**（月报/年报不失真）、与显示设置的「阅读统计」（估算口径）**100% 隔离**（[06 §6.5.6](06-接口契约与调用链.md)）。

---

## 阅读路径建议

| 角色 | 建议路径 |
|---|---|
| **第一次接触本项目** | [01](01-项目整体架构.md) 速览 → [02](02-主要模块职责.md) 模块总览表 → [05 §5.4](05-项目运行方式.md) 把 App 跑起来 |
| **要改某个功能** | [07](07-附录-类型与符号索引.md) 定位类型 → [03](03-关键类与函数参考.md) 看方法签名 → [02](02-主要模块职责.md) 对应模块章节看边界与技术债 |
| **要接入/改接口** | [06 §6.2](06-接口契约与调用链.md) 端点清单 → [06 §6.4](06-接口契约与调用链.md) 调用链 → [04 §4.8](04-依赖关系.md) 网络拓扑 |
| **要做发布/审核** | [05 §5.12](05-项目运行方式.md) 工程红线 → [01 §1.10](01-项目整体架构.md) 技术债与风险 → [02 §2.21](02-主要模块职责.md) 隐私合规 |
| **要重构** | [01 §1.10](01-项目整体架构.md) 技术债 → [04 §4.6](04-依赖关系.md) 耦合风险 → [03 §3.10](03-关键类与函数参考.md) 算法伪代码 |

---

## 文档约定

| 标注 | 含义 | 对应证据等级（product-doc-writing） |
|---|---|---|
| `[实测]` | 本轮已在源码 / 工程文件中直接验证（`grep` / `read` / `wc`） | `[Data-backed]` |
| `[推断]` | 由代码结构归纳，非文档明示 | `[Expert judgment]` |
| `[未验证]` | 无法从仓库确认（需联网、真机、抓包或产品决策） | `[Hypothesis]`（发布前必须确认） |
| ⚠️ | 已知缺陷或风险，附准确行号 | —（诊断标注） |
| 🔴 / 🟠 / 🟡 / 🟢 | 风险严重度：高 / 中 / 低 / 提示 | —（诊断标注） |

**行号口径**：标注为当轮实测的行号指**基线提交 `6fc702e`（2026-10-04）** 时刻的源码；分册中未重核的旧章节行号承自 `904d75f` / `215ea30` 基线（各册页脚有说明）。改动后请以**符号名检索**（见 [07](07-附录-类型与符号索引.md)）而非行号为准。

**行数口径**：一律使用 `wc -l`（注意：部分文件末行无换行符，编辑器显示值可能比 `wc -l` 多 1）。

**复现方式**：

```bash
cd qin/DesignCode      && wc -l *.swift | tail -1    # 主 target 总行数
cd qin/DesignCodeTests && wc -l *.swift | tail -1    # 测试总行数
grep -oh 'LogManager\.shared\.' qin/DesignCode/*.swift | wc -l   # 日志调用点
```

---

## 已知重要缺陷速查（Top 10）

> 完整清单见 [01 §1.10](01-项目整体架构.md) 与 [04 §4.6](04-依赖关系.md)。

| # | 严重度 | 问题 | 位置 |
|---:|---|---|---|
| 1 | 🔴 | `exit(0)` 主动退出进程（违反审核指南 2.5.4） | `PrivacyPolicyView.swift:764` |
| 2 | 🔴 | 隐私文本声明「不申请 Face ID / 相册」与 `Info.plist` 及实现矛盾 | `PrivacyLegalTexts.swift:219` |
| 3 | 🔴 | 测试工具与调试面板随 Release 出海（无 `#if DEBUG`） | `NotificationTestView.swift`、`TabBar.swift:245-301`（面板/入口）/`:11131`（通知测试入口） |
| 4 | 🔴 | `CODE_SIGN_ENTITLEMENTS` 全工程 0 命中 → Associated Domains 未生效，微信 Universal Link 断链 | `project.pbxproj` |
| 5 | 🔴 | 部署目标不一致（工程级 13.0 / target 级 26.0） | `project.pbxproj:565/619` vs `:640/688/732/748` |
| 6 | 🟠 | `Set.suffix(n)` 语义错误——去重集保留的不是「最新 N 条」 | `NotificationManager.swift:160/169/179` |
| 7 | 🟠 | 每次图片缓存命中同步写 UserDefaults，且有 11 个观察者 → 滚动期写放大 | `CacheModeManager.swift:341/214/445-447` |
| 8 | 🟠 | 数据层无取消路径（0 处 `Task.isCancelled`，Task 句柄未保存） | `DataService.swift` / `NetworkService.swift` |
| 9 | 🟠 | `clearCache()` 漏删 `specialty.json`，估算计数器只增不减 | `DataService.swift` |
| 10 | 🟡 | 生产 `print()` 残留 19 处 | `DataService`(8) / `NetworkService`(5) / `NotificationManager`(6) |

---

## 本轮增量（2026-10-04，基线 `215ea30` → `6fc702e`）

本套文档随**阅读时光模块**（2026-10-03/04）做增量核验与同步（`git diff 215ea30..HEAD` 实测：主 target 净 **+2,381 行**，16 个文件含工程/测试共 +2,611 −6）。主要变更：

| 变更 | 位置 | 说明 |
|---|---|---|
| **阅读时光（新模块，2,333 行）** | `ReadingReportStore.swift`(619) / `ReadingReportView.swift`(1,282) / `ReadingGoalStore.swift`(72) / `ReadingGoalView.swift`(181) / `MechanicalPicker.swift`(108) / `HapticEngine.swift`(71) | 真实停留时长采集、日/周/月/年四模式报表（Swift Charts：趋势/对比/分类环/时段热力）、目标设定（机械滚轮 + 触觉音效）、分享战报（1200×630 离屏）、隐私控制（开关 + 一键清除）——纯本机、零网络 |
| **采集挂载点（13 处）** | `TabBar.swift` 7 处（:3359/:5517/:5942/:6154/:6720/:7290/:12248）+ 公告/校历/机构/党建/概况·合作 6 处 | 一行 `.readingReportTrack(...)`：进入计时、后台暂停（>300s 结算）、离开结算、<5s 不计 |
| **我的页入口** | `TabBar.swift:10411`（副标题 `readingReportEntrySubtitle` :10203；sheet :10296） | 「今日 N 分钟 · 连续 N 天」实时副标题 + `ReadingReportView` |
| **数据设计：事件 + 按天 rollup** | `ReadingReportStore.swift` | 事件上限 2000 条 FIFO；按天预聚合**永久保留**（3650 天上限，约 65KB/年）→ 月报/年报不受裁剪影响；`ensureRollups` 惰性补建缺失天 |
| **隐私文本** | `PrivacyLegalTexts.swift:266-272` | 新增「十一、阅读数据（阅读时光）说明」：仅存本机、可关闭/清除、与阅读统计独立；原「十一、合规声明」顺延为「十二」 |
| **测试** | `MessageCenterStoreTests.swift`（+200 行） | 新增 `ReadingReportTests`（:1822，**13 例**）：阈值/开关/FIFO/预聚合/连击/展示口径/清除等（静态 241 → 254） |
| **触觉与滚轮组件** | `HapticEngine.swift`、`MechanicalPicker.swift` | 全库首个可复用触觉音效引擎（tick/settleClick/success，音效节流 45ms）+ 磁吸滚轮（程序化滚动抑制中间格触觉） |
| **Wiki 增量** | 本目录 7 分册 | 02 §2.31 / 03 §3.7.8 + 3.10 ⑬ / 04 键表 +7（88→95）/ 05 测试 254 / 06 链路 J + §6.5.6 / 07 机械重生成（425 声明 / 35 单例 / 42 域）/ mermaid `chain-J` |

> **追补（2026-10-04 晚 · 阅读时光分享改造，独立增量）**：`readingReport` 域 7→**20 处**、`wechat` 66→**68 处**、字面量埋点 1,390→**1,405**、`LogManager.shared.*` 1,407→**1,422**、主 target 71,080→**71,392 行**、测试 254→**255 例**（4,496→**4,510 行**）、`ReadingReportView` 1,282→**1,588** / `ReadingReportStore` 619→**625**（模块合计 2,333→**2,645 行**）、顶层声明 425→**426**（新增 `ReadingReportShareMenu`）、真机全量实跑 **255/255 通过**。七分册内联数字已按此口径同步；文章侧共享文件 `WeChatIntegrationViews.swift` 零改动（物理隔离）。

## 上轮增量（2026-10-02，基线 `904d75f` → `215ea30`）

本套文档随机构模块改造做了**增量核验与同步**（`git diff 904d75f..HEAD` 实测 13 文件 / +2,425 −386）。主要变更：

| 变更 | 位置 | 说明 |
|---|---|---|
| **机构栏目九形态**（原 4 态 → 9 态） | `OrgContentIndex.swift` / `OrganizationDetailView.swift` | `OrgColumnKind` 扩为 `list / content / video / teacher / recruit / calendar / opinion / link / webFallback`；`classify()` 新增 `title/path/embeddedTotal` 二次判定；`OrgColumnSpec.kind` 构建期一次性判定；`OrganizationDetailView` 渲染 switch 分发九形态壳（单篇直渲 / 视频封面卡 / 师资表单分页 / 招生查询 / 日历·信箱联动 / 外链内嵌 / 空态） |
| **机构子站栏目全量** | `OrgContentIndex.swift` | `data.children` 键捕获（tabs-sub 容器）、子栏目 `articles`/`data` 双键兼容、简介类栏目按内嵌 total 分派单篇 |
| **视觉 v2.2 令牌** | `OrgTheme.swift` | 新增 `brassRule`、`Radius.shell`、`Space.screen`、阴影/动效令牌、`symbol()` 图标单点探测、`kindSymbol()` 九形态语义图标、`OrgBadge` 线性徽章、`OrgEmptyArt` Canvas 空态插画（空书架/断线/折叠纸） |
| **机构首页视觉** | `OrganizationDetailView.swift` | 档案式题头（OrgBadge 48 + 同步角标 + 铜金饰线）、头图静态化（移除视差，`resolverBannerImgSrc` 学院/部门/党委三档官网静态横幅）、列表节奏模型（逢 4 行大图卡 ↔ 铜金日期徽章文字卡）、`OrgArticle.createTime` |
| **机构深链单状态化** | `TabBar.swift` `:413` / `NotificationManager.swift:53` | 机构动态通知 sheet 由「bool + item」双状态改为 `sheet(item:)` 驱动；`PendingOrgArticleDeepLink` 加 `Identifiable`；冷启动白屏修复（消息中心来源等待 sheet 完全退场 + 550ms 错峰） |
| **WebView 标签页浏览器** | `TabBar.swift` `:4903` 起 | `WebViewContainer` 重构：页签条 + 导航条（后退/前进/刷新）、`WebViewTab` / `WebViewControl`、`desktopUA`（外链 PC 站）、跨站导航自动开新页签（`referenceHost`）、`window.open` 委托（`createWebViewWith`）；`Info.plist` 增 `NSAllowsArbitraryLoadsInWebContent` |
| **师资 / 招生接口** | `NetworkService.swift` | 新增 `fetchTeacherPage()`（`/common/teacher/page`，行外嵌套 `TeacherDTO/TeacherPageDTO`）与 `queryRecruit()`（POST `/common/recruit/query`，`RecruitResultDTO`，RSA 加密待真机取证）；新增通用 `post()`（`:126`） |
| **招生网全量覆盖** | `NetworkService.swift:812` / `DataService.swift` | `fetchZSWArticlePage` 由 `/common/article/page` 改走 `/common/column/articles`（修复「招生公告远少于官网」），DTO 兼容嵌套/扁平两结构；`DataService` 新增 `fetchFullZSWArticles` + `safeFetchArticles` total 驱动翻页 |
| **机构搜索全量** | `OrganizationView.swift` | 深度检索/子站检索由「固定 4/8 页」改为**按服务端 total 动态翻页全量覆盖**（200 页安全上限） |
| **深色模式修复** | `DisplaySettingsManager.swift:1084` / `OrganizationDetailView.swift` | WebView 排版 CSS 追加 `color: var(--text-color) !important`；`body a` 链接色提权保护 |
| **机构数据治理** | `OrganizationManager.swift:664` | 「思想政治教育工作部」→「思想政治教育工作部党支部」（siteKey 置 nil，article_id 语义）；删除「网络与信息中心」；旧缓存 siteKey 按名称兜底纠正 |
| **测试** | `OrgModuleTests.swift` | 九形态 classify、二次判定负样本、`createTime` 解码、师资分页解码等新增用例（静态 237 → 241） |

## 与本仓库其他文档的关系

| 文档 | 关系 |
|---|---|
| `qin/docs/code-wiki/`（7 分册，2026-09-29 基线） | **上一版 Wiki**。本套（`code-wiki/`）为其继任者，基于当前源码独立重新核验生成，并修正了若干历史口径（详见下文「修正的既有口径」） |
| `qin/README.md` | 工程主页 README（2026-10-02 大幅更新，+314 行）；`qin/docs/dev-handover-guide-20261002.md` 为**开发者交接指南**（287 行，含环境/构建/调试/注意事项），与本 Wiki 互补 |
| `qin/CODE_WIKI.md`、`qin/CODE_WIKI_副本.md` | 更早的单文件合并版，历史快照 |
| `qin/ARCHITECTURE.md`、`qin/项目技术全景报告.md` | 历史架构文档，行号可能失真 |
| `qin/PROJECT_UNDERSTANDING.md` | **项目理解档案**（隐性知识、锁死的决定、红线），与本 Wiki 互补，建议一并阅读 |
| `.trae/documents/`、`.trae/specs/` | 各模块**上游规格书与设计稿**（校园日历 / 显示设置 / 使用帮助 / 消息中心 / 网络监测 / 机构升级） |
| `qin/docs/departments-api-inventory.md` + `departments-api-evidence/` | 机构设置页接口**全量摸查与原始报文取证**（89KB + 200+ JSON） |
| `qin/docs/wechat-integration/` | 微信接入文档与 AASA 部署材料 |
| `code-wiki/mermaid/` | [06 §6.4](06-接口契约与调用链.md) 的 **10 条调用链时序图 Mermaid 源码**（A–J，逐字同步，J 为 2026-10-03 阅读时光新增）与目录索引 |

---

## 本轮修正的既有口径

本套文档在重新核验中发现并修正了流传于旧文档中的若干不准确表述：

| 旧口径 | **本轮实测结论** |
|---|---|
| 「`@StateObject` 仅 1 处」 | 实测 **2 处**（`LogListView.swift:71` 的 `LogFilterCache` + `TabBar.swift:4917` 的 `WebViewControl`——后者由 2026-10-01 WebView 标签页重构引入，上一版口径漏计） |
| 「单例 33 / 日志域 40 / 键 88 / 字面量埋点 1,383」 | 2026-10-04 实测 **35 / 42 / 95 / 1,405**（阅读时光新增 3 单例、1 域、7 键；域计数含仅 `module:` 出现的 `crashCapture`；1,422 个 `LogManager.shared.*` 调用点，含 2026-10-04 分享改造 +15） |
| 「`@ObservedObject` 113 处」 | 实测 **116 处**（`TabBar` 仍 56 处；阅读时光两视图新增 3 处） |
| 「241 用例」 | 静态计数 **255**（`ReadingReportTests` 14 例 = 2026-10-03 新增 13 + 2026-10-04 分享改造 1）；2026-10-04 真机全量实跑 **255/255 通过**（`device_tests_20261004_isolation.xcresult`；同日 11:20 另有 254/254 基线） |
| 「四通道通知 + 收藏第五通道」 | **`NotificationManager` 内 5 条 + `BookmarkManager` 1 条 = 5+1 条**；且代码内 `:753` 与 `BookmarkManager.swift:1062` 各自都自称「第五通道」，属历史命名冲突 |
| 「`doFullSync` 并行拉 home2/head/foot」 | **串行** `do/catch`；唯一并行处是视频详情 `withTaskGroup`（`DataService.swift:364-388`） |
| 「测试 target 也有 `-disable-sandbox`」 | **仅主 target**（`pbxproj:641/689`）；测试 target 没有 |
| 「三种缓存模式」 | **2 个枚举例**（`instant` / `cached`）+ **1 个正交布尔**（`imageFreeModeEnabled`），无图模式优先 |
| 「网络监测支持上传/下载测速」 | **上传测速未实现**；`runSpeedTest`（`:1523-1693`）仅下载 |
| 「`cleanEmptyFiles` 与保留 7 天注释矛盾」 | 当前 `LogManager` 中**已不存在**，现存备份（`DesignCode_backup_20260926_display/_fonts`）亦无——旧版函数已彻底移除 |
| 「机构 34 个 / 22 个 site_key」 | 旧文档的「35 条机构 / 23 个唯一 site_key」为**首版基线 `904d75f`** 口径；**2026-10-02 已删 `wlzx` 并改名思政部** → 现为 **34 条 / 22 个唯一 site_key**（`siteKey` 非 nil 24、nil 10） |
| 「机构模块用到 20 个端点」 | **实际只用 8 条 API + 1 个 HTML 校验页**（2026-10-01 增 `teacher/page`）；20 是摸查文档的官网全量 |
| 「校园日历支持日期聚合与筛选」 | **源码中不存在**；仅 `dateText`（`:453`）对单条日期做规范化 |
| 「机构升级已实现预取与详情共用缓存」 | **未落地**——详情页全程不读写 `OrgHomeCache` |
| 「显示设置文件内有 19 项」 | F1–F19 是**全工程**特性编号；该文件为 **18 项 / 12 个 Section**（F1–F15 + F17–F19；**F16 全库无编号标注，代码中不存在**） |
| 「`cacheArticleContent` 有 `await` 后下标越界隐患」 | **已修复**（`BookmarkManager.swift:573` 在挂起点后重新 `firstIndex` 定位） |
| 「237 用例全绿」 | 237 是首版基线**静态计数**；2026-10-02 重构后静态计数为 **241**；最近有日志证据的实跑为 **195/195**（2026-09-29），`OrgModuleTests` 在验证日志中 0 命中 |
| 「隐私文本三处矛盾」笼统表述 | 已定位到具体行：`PrivacyLegalTexts.swift:219`（权限清单不实）、`:224`（宣称「所有网络请求 HTTPS」而 `Info.plist:58-64` 对 `sxjzit.edu.cn` 放行明文 HTTP——是否构成不实取决于学校接口**实际 scheme**，[未验证]）；而 `:140`「不收集生物特征数据」表述**本身正确** |

---

## 文档维护

1. **新增功能**时同步更新：[02](02-主要模块职责.md) 模块章节、[03](03-关键类与函数参考.md) 签名表、[04 §4.4](04-依赖关系.md) 持久化键表、[07](07-附录-类型与符号索引.md) 类型索引。
2. [07](07-附录-类型与符号索引.md) 为**机械生成**，源码增删类型后应重新生成，不要手工编辑表格（生成命令见该册末「维护约定」）。
3. 本目录为**当前权威版本**；与 `qin/CODE_WIKI.md`、`qin/ARCHITECTURE.md`、`qin/docs/code-wiki/` 冲突时，**以本目录为准**。

### 关于 `_drafts/`

`_drafts/` 目录保存了生成本套文档时的**中间分析草稿**（8 个按领域划分的深度分析文件，约 750KB），比正式分册包含更多细节（例如每模块的完整「未验证/存疑点」清单、更细的分文件表格）。

- 它是**工作产物，不是交付物**，措辞与体例未经统一，个别口径已被正式分册修正（见上文「本轮修正的既有口径」）。
- **阅读本 Wiki 时请以 7 个正式分册为准**；需要追溯某条结论的原始分析过程时再查阅 `_drafts/`。
- 如不需要，可直接删除整个 `_drafts/` 目录，不影响正式分册的完整性。
