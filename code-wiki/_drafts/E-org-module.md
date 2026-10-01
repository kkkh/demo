# E · 机构（院系部门）模块 —— 深度分析草稿

> 分析对象：`qin/DesignCode/` 下机构模块 7 个文件（2026-09-30 完成阶段三升级）
> 分析方法：`wc -l` 实测行数 + `grep -n` 定位类型/方法 + 定点 `read`（6 千行文件不逐段读）
> 事实口径：**所有行号均为本次 grep/read 实测**；凡参考文档（`.trae/*`、`qin/docs/*`）结论，均在正文标注来源与核实状态
> 越界声明：TabBar / NotificationManager / NetworkService / ReadStatusManager 属其他子代理范围，本文仅记录**接口面**（签名、行号、调用点），不展开其内部实现

---

## 0. 核实基线（先给数字，再给结论）

### 0.1 行数实测（`wc -l`）

| 文件 | 实测行数 | 任务给定 | 一致性 |
|---|---|---|---|
| `qin/DesignCode/OrganizationManager.swift` | 724 | 724 | ✅ |
| `qin/DesignCode/OrganizationView.swift` | 2532 | 2532 | ✅ |
| `qin/DesignCode/OrganizationDetailView.swift` | 6595 | 6595 | ✅ |
| `qin/DesignCode/OrgContentIndex.swift` | 509 | 509 | ✅ |
| `qin/DesignCode/OrgFollowStore.swift` | 166 | 166 | ✅ |
| `qin/DesignCode/OrgTheme.swift` | 144 | 144 | ✅ |
| `qin/DesignCode/OrgHaptics.swift` | 59 | 59 | ✅ |
| **合计** | **10729** | — | — |

> 说明：`read` 工具报「total 725 / 2533 / …」比 `wc -l` 多 1，因其把文件末尾换行后的空行也计入；`.wiki-draft/parts/type-index-raw.txt` 中记录的 6595/724/2532 与本表一致，两处口径统一。
> 全项目文件大小排名（`wc -l *.swift \| sort -rn` 实测）：`TabBar.swift` 13687 ＞ **`OrganizationDetailView.swift` 6595（第 2 大）** ＞ `SchoolProfileView.swift` 3559 ＞ `DisplaySettingsManager.swift` 2959 ＞ `PartySubjectView.swift` 2606（第 1 大属应用外壳子代理范围）。

### 0.2 规模数据回源结论（**重点：存在口径差**）

| 指标 | 任务/文档口径 | 源码实测 | 结论 |
|---|---|---|---|
| 机构条数 | **34 个**（`02-设计稿.md:221`；`departments-api-inventory.md` §2.5 核算 8+5+9+10+2=34） | **35 条** `OrganizationUnit`（`OrganizationManager.swift:130-175`：党委 8 / 群团 5 / 行政 9 / 教学 10 / 教辅 3） | ⚠️ **不一致**：App 静态数据多出「网络与信息中心 `wlzx`」，官网机构树无此节点（`.trae/documents/org-module-upgrade/01-现状与根因分析报告.md:108` 亦已指出；该 siteKey 请求实测必返 `code 500`） |
| 唯一站点 siteKey | 22 个（inventory §9：22 站 / 24 条机构条目去重） | **23 个**（`grep -o 'siteKey: "[a-z0-9]*"' \| sort -u`；`dzbgs` / `dwxsgzb` / `mkszy` 各被 2 条机构共用） | ⚠️ 差的 1 个即 `wlzx` |
| siteKey 已配置机构 | — | **26 条非 nil，9 条 nil**（`grep -c 'siteKey: "'` = 26；`'siteKey: nil'` = 9） | ✅ 已核实（9 条走单文章型/降级链） |
| 栏目数 | **178 个**（`departments-api-inventory.md` §3.4「22 站点 × 178 子栏目」；`02-设计稿.md:221` Hero 文案） | **源码内无此常量**；栏目在运行时由 `/dept/home2` 的 `nav` 数组动态枚举（`OrgColumnIndexBuilder.build`，`OrgContentIndex.swift:93`） | ⚠️ **未验证（需联网）**：178 为 2026-09-30 摸查文档口径，本次仅离线读码，无法复算 |
| 端点数 | **20 个**（`departments-api-inventory.md` §1「端点总表（20 个）」+ §12「每接口 curl 复现命令（20 个）」） | **机构模块实际调用 7 条 API 路径 + 1 个 HTML 校验页**（见 §8 映射表；`grep -n "NetworkService.shared.fetch"` 全量枚举） | ⚠️ **口径不同**：20 = 官网全量端点（含校长信箱/招生查询等与机构无关者）；模块自用 7 条 |
| 列表 Hero 文案 | 设计稿写「34 个机构 · 5 大类 · 178 个栏目」 | 代码实际渲染 `"\(manager.totalCount) 个机构 · \(OrganizationCategory.allCases.count) 大类 · \(manager.detailPageCount) 个官网子站"`（`OrganizationView.swift:925`）→ 运行时为「**35 个机构 · 5 大类 · 26 个官网子站**」 | ⚠️ 设计稿文案未落地；「178 个栏目」在 UI 上不存在，第三项是「官网子站数」 |

**数据来源与刷新链路（回源核实）**

```
OrganizationManager.init (OrganizationManager.swift:179)
 ├─ URLSession 配置 15s/30s + 显式注册 RefererHeaderURLProtocol      :180-185
 ├─ loadCache()  读 UserDefaults["organizationCache"]               :188 → 642-682
 │    └─ 无缓存 → departments = staticData（35 条），dataSource="预置数据" :646-651
 │    └─ 有缓存 → 合并静态 siteKey/icon（防旧缓存覆盖新静态）           :654-681
 ├─ startAutoRefresh()  30 分钟 Timer                                 :196 → 698-717
 │    └─ CacheModeManager.isCacheEnabled == true → **暂停定时远程刷新**  :702-705
 ├─ modeObserver = CacheModeManager.shared.$mode.sink → startAutoRefresh :199-203
 └─ syncTask = Task { syncFromAPI() }                                 :206-209

syncFromAPI(force:)                                                   :398-512
 ├─ 防并发：非 force 且 isLoading → 直接返回                            :400-403
 ├─ 缓存模式 + 本地缓存新鲜（<600s）→ 跳过远程                           :405-412
 ├─ NetworkService.fetchHead() → GET /common/column/head               :432
 │    └─ head.menus 非空 → updateSiteKeys(from: menus)                 :435-441
 │    └─ menus 为空 → dataSource="服务器（空菜单）"，仍标 syncSucceeded   :442-454
 ├─ validateFromPageHTML()  抓官网首页 HTML 做「名称差集」校验（**仅日志**）:457 → 515-568
 │    └─ 直连 https://www.sxjzit.edu.cn/（15s、reloadIgnoringLocalCacheData）:516-526
 │    └─ 3 条正则提名称 → newNames/removedNames 只打 INFO/WARNING 日志     :571-608
 └─ 成功且未取消 → lastFetchTime = Date()（单一赋值点）                  :505-510
```

**降级阶梯（4 级）**：内存 `departments` → UserDefaults 缓存 → `staticData`（35 条）→ UI 层 `enhancedFallbackView` 主站搜索降级（详情页内，见 §4.8）。

---

## 1. 模块全景

### 1.1 文件职责分工（阶段一/二/三分层）

| 文件 | 阶段 | 职责 | 关键类型数 |
|---|---|---|---|
| `OrganizationManager.swift` | 存量 + F5 改造 | 机构清单真值源（静态 + head API 菜单）、site_key 四层匹配、UserDefaults 缓存、30 min 定时刷新 | 4 |
| `OrganizationView.swift` | 存量 + 阶段二/三 | 列表页（Hero / Bento 焦点区 / 玻璃吸顶 chips / 五分类网格）、双模式搜索（机构本地 + 文章跨站） | 8 顶层声明 |
| `OrganizationDetailView.swift` | 阶段一/二/三 | 机构详情页（栏目全量分页链路）+ 文章详情页（WKWebView 渲染、看图桥、已读、关注）+ 子标签页 + WebView 封装 + 工具函数 | 18 顶层声明（16 类型 + 2 extension） |
| `OrgContentIndex.swift` | 阶段一（新） | 纯逻辑层：栏目类型分派 / 栏目索引构建 / 并发闸 / 看图载荷 / 媒体探针 / 分页状态机 / 单文章解析 / 首页缓存 | 11 |
| `OrgFollowStore.swift` | 阶段三 C（新） | 关注清单持久化 + 机构动态扫描纯函数（第五推送通道数据源） | 3 |
| `OrgTheme.swift` | 阶段二（新） | 「青金书院」设计令牌 + 统一按压样式 + 骨架块 | 3 |
| `OrgHaptics.swift` | 阶段二（新） | 六级（+2 结果级）振动词表 | 1 |

### 1.2 模块边界与共享契约（只增不改）

机构模块对共享文件的依赖（**签名级**，实现由其他子代理分析）：

| 依赖 | 提供方 | 机构模块用法 |
|---|---|---|
| `NetworkService.shared.fetchHead/fetchDeptHome2/fetchArticles/fetchArticleDetail/fetchHome2/fetchSchoolOrgTree/fetchDeptSiteIndex/fetchZSWArticleDetail` | `NetworkService.swift` | 8 个方法，见 §8 |
| `CacheModeManager.shared.isCacheEnabled / $mode` | `CacheModeManager.swift` | 暂停定时刷新、搜索 query 缓存开关（`OrganizationManager.swift:199,405,702`；`OrganizationView.swift:1925`） |
| `LogManager.shared.info/warning/error/debugLog` | `LogManager.swift` | 全模块埋点，域标签统一 `"organization"` |
| `ReadStatusManager.shared.isRead/markAsRead` | `ReadStatusManager.swift` | 已读光点 + 进入详情标记已读（`OrganizationDetailView.swift:3084-3090`） |
| `OrgFollowStore` / `NotificationManager.seedOrgFollowBaseline` | 本模块 → 通知模块 | 第五通道（见 §6.3） |
| `SJZImageGalleryPayload` / `FullScreenImageView` / `SJZImageViewerGeometry` | `TabBar.swift:4117 / 4240 / 4160` | 看图桥消费方（**共享组件，非本模块所有**） |
| `SJZCachedImage` / `SJZImagePrefetcher` / `SJZImageConcurrencyGate` / `ShimmerView` / `SJZRevealOnce` / `sjzScrollSuspendTrack` | 共享基建（其他子代理范围） | 图片/动效/滚动挂起 |
| `displayFont/displaySymbolFont/...` | `DisplaySettingsManager` | 全模块文本必走 `display*` 链（构建护栏强制，`OrgTheme.swift:9` 注释） |

---

## 2. OrganizationManager（724 行）深度分析

### 2.1 类型清单

| 行号 | 声明 | 说明 |
|---|---|---|
| 19 | `enum OrganizationCategory: String, CaseIterable, Identifiable, Codable` | 5 分类：党委/群团/行政/教学/教辅；`icon`(:28) / `color`(:38 → `OrgTheme.categoryColor`) / `sortOrder`(:42) |
| 55 | `struct OrganizationUnit: Identifiable, Codable, Equatable` | `id = "\(category.rawValue)_\(name)"`（:72）；`hasDetailPage = siteKey != nil`（:63）；`detailURL` 拼 `#/departments/page?site_key=`（:66-69） |
| 87 | `struct OrganizationCache: Codable` | `departments` + `fetchTime` + `dataSource` |
| 96 | `@MainActor final class OrganizationManager: ObservableObject` | 单例 `shared`（:97）；`@Published departments/isLoading/lastFetchTime/dataSource/errorMessage`（:102-110） |

### 2.2 预置静态数据合并（阶段三后仍是「静态为基、API 叠加」）

- 静态数据 `staticData: [OrganizationUnit]`（:130-175，35 条）是**永远存在的基线**。
- `loadCache()`（:642-682）读取缓存后**反向合并静态数据**：缓存里 `siteKey == nil` 而静态有值 → 用静态值（:660-663）；`icon` 不一致 → 一律以静态为准（:665-667）。日志 `"缓存合并静态 siteKey"`（:675）。
- `updateSiteKeys(from:)`（:251-384）在 API 侧再合一次静态：先按 `id` 把静态 `siteKey/icon` 补进 `departments`（:285-294），再做菜单匹配。
- **副作用记录**：`updateSiteKeys` 末尾无条件 `dataSource = "服务器"` 并 `saveCache()`（:369-370），即使 `updatedCount == 0`。

### 2.3 `updateSiteKeys` —— site_key 匹配算法（4 层，实测行号）

| 层级 | 算法 | 行号 | 日志标签 |
|---|---|---|---|
| 0 | 静态基线注入（id 相同 → 补 siteKey / 覆盖 icon） | 285-294 | — |
| 1 | **精确匹配**：`siteKeyMap[name]` | 298-308 | `site_key 精确匹配` |
| 2 | **模糊匹配**：`name.contains(menuName) \|\| menuName.contains(name)`（字典序首个命中，`break`） | 310-325 | `site_key 模糊匹配` |
| 3 | **近似匹配**：`normalizeDeptName` 后全等（`智造→制造`、`製造→制造`、去空格、lowercased） | 327-341 / 387-394 | `site_key 近似匹配` |
| 4 | **关键词匹配**：按 `" -（）()"` 切词、长度 ≥2、交集 ≥1（仅当 `siteKey == nil` 时尝试） | 343-364 | `site_key 关键词匹配` |

- 菜单 → 映射表的构建：递归 `MenuDTO`，从 `menu.path` 里 `extractSiteKey`（找 `site_key=` 子串并截到 `&`，:613-620），键为 `titleCn.trimmed`（:260-275）。
- **已知风险（源码可读出，非推测）**：
  1. 第 2 层 `for (menuName, key) in siteKeyMap` 依赖**字典遍历顺序**，命中即 `break`（:312-323）；当菜单名与机构名互为子串的候选项 >1 时结果不稳定（如「党委学生工作部（武装部）」与「学生工作处」共用 `dwxsgzb`）。第 4 层同样依赖字典序（:345-363）。
  2. `matched` 标志只覆盖第 2 层：`matched = true` 仅在「模糊命中且 key 与原值不同」时置位（:314-317），而 `break` 在「名字命中」时无条件执行（:322）→ 若模糊命中的 key 与原值相同，`matched` 仍为 false，**第 3 层会继续执行**。第 3 层自身**不置 `matched`**（:327-341），故第 4 层的 `!matched` 判断的仍是第 2 层结果；但第 4 层额外要求 `updated[i].siteKey == nil`（:344），**因此不会覆盖第 3 层已写入的非 nil 值**。
  3. 层级优先级不对称：**第 1/2/3 层可覆盖**已存在的（含静态基线）siteKey，**只有第 4 层要求原值为 nil**（:344）——「关键词匹配」是唯一的弱优先级层。

### 2.4 缓存与降级

| 项 | 实现 | 行号 |
|---|---|---|
| 缓存键 | `"organizationCache"`（UserDefaults，JSON） | 114 / 631 / 643 |
| 缓存结构 | `OrganizationCache{departments, fetchTime, dataSource}` | 87-91 / 624-639 |
| 定时刷新 | `Timer.scheduledTimer(withTimeInterval: 1800, repeats: true)` | 115 / 706-713 |
| 缓存模式联动 | `isCacheEnabled` → 暂停定时器（:702-705）；`$mode` 变化 → 重启/暂停（:199-203） | — |
| 新鲜度门槛 | 缓存模式且 `now - lastFetchTime < 600s` → 跳过远程（:405-412） | — |
| 手动刷新 | `refresh()`：`syncTask?.cancel()` → sleep 50ms → `syncFromAPI(force: true)`（:229-240） | — |
| 清缓存 | `clearCache()`：删 UserDefaults + 回静态数据 + `lastFetchTime = nil`（:685-694）；调用点 `TabBar.swift:11226`（设置页「确认清空」） | — |
| 网络错误文案 | `.timedOut→"请求超时，已使用缓存数据"` / `.notConnectedToInternet/.networkConnectionLost→"网络未连接…"` / 其余→"网络异常…"（:459-486）；**仅当 `departments` 为空才写 `errorMessage`**，有缓存时静默 WARNING（:470-478） | — |

**死代码/空实现（实测）**
- `refreshWithDebounce(source:)`（:244-246）：注释称「冷却期内不重复请求」，**函数体只有 `await refresh()`**，且全仓库**零调用点**（`OrganizationView.performRefresh:808` 直接调 `manager.refresh()`）。→ 「带防抖的刷新」当前**未落地**。
- `groupedData`（:215-220）：零调用点（列表页用自己的 `filteredGroupedData`，`OrganizationView.swift:232-243`）。
- `stopAutoRefresh()`（:720-724）：仅定义，机构模块内无调用（App 进后台未停 Timer）。

### 2.5 `columnId` 硬编码问题 —— **部分修复，未清零**

| 位置 | 内容 | 状态 |
|---|---|---|
| 全量栏目浏览链路 | 栏目 = `home2.nav` 运行时枚举（`OrgColumnIndexBuilder.build`，`OrgContentIndex.swift:93`） | ✅ **已修**（阶段一核心成果：替代旧「板块恒 8 条 + 阈值恒不触发」） |
| 文章搜索栏目 ID | `DataService.shared.articleSearchColumnEntries()` → 空则`refreshNewsColumnIdsFromHome2()`（`OrganizationView.swift:1940-1950`） | ✅ 运行时解析 |
| 降级搜索栏目 ID | `resolveMainSiteSearchColumns()`（`OrganizationDetailView.swift:171-194`）：优先 `/school/home2` 的 `news.children.{importants,updates,resports,notices}.columnId` | ✅ 动态 + ⚠️ 硬编码回退 |
| — 回退常量 | 4 个 2026-09-27 实测值（:189-192：要闻 `41cb4c84…`、资讯 `90ede729…`、党建 `10a8da2f…`、通知 `747dcb1e…`） | ⚠️ **残留硬编码**（有注释说明「官网换 ID 后可先 curl 复核再更新此处」） |
| 子站栏目索引 | `NetworkService.fetchDeptSiteIndex(siteKey:)`（`NetworkService.swift:1022`）运行时解析 nav | ✅ 运行时解析 |
| 历年分数线入口 | `scoreLineURL`（:166）内嵌 `site_id=cb3b1fe4…&column_id=6ea796a0…` | ⚠️ **残留硬编码**（工具入口，非主链路） |
| 「专业介绍」路由判定 | `child.columnId == "25d7bd39e49a468880356e302b9ccf1d"`（:1979） | ⚠️ **残留硬编码**（与标题 `contains("专业介绍")` 并列的兜底条件） |
| ZSW siteId | `private let zswSiteId = "cb3b1fe4fcdf40999b0c162015c3326d"`（:163） | ⚠️ 硬编码 site_id（**不是 column_id**；官网 /school/org 有权威值，代码未取） |

**结论**：任务关心的「columnId 硬编码问题」在**浏览/搜索主链路已修复**（栏目一律来自 `nav` 运行时解析），但仍有 **3 处硬编码常量**（分数线 URL 的 column_id、专业介绍兜底的 column_id、降级搜索的 4 个回退 column_id）与 1 处硬编码 site_id。

---

## 3. OrganizationView（2532 行）深度分析

### 3.1 类型清单（8 个顶层声明）

| 行号 | 声明 | 说明 |
|---|---|---|
| 15 | `enum OrganizationSortOrder` | 默认 / 名称 A-Z / 名称 Z-A / 按分类；`icon` 映射（:23-30） |
| 35 | `enum OrganizationSearchMode` | `.organization` / `.article`，含 `placeholder`（:48-53） |
| 58 | `struct ArticleSearchResult: Identifiable` | 10 字段：`articleId/title/description/tag/updateTime/imageUrl/siteId/columnName/orgName/relevanceScore` |
| 76 | `enum ArticleSearchScope` | 全部/要闻/资讯/党建/通知（与 `columnName` 短名对齐） |
| 88 | `enum ArticleSearchSortOrder` | 相关度 / 时间降序 / 时间升序 |
| 105 | `struct OrganizationView: View` | 主体（105-1326） |
| 1330 | `extension OrganizationView` | 文章搜索逻辑（1330-2507） |
| 2511 | `struct OrganizationCardButtonStyle: ButtonStyle` | scale 0.97 + easeInOut 0.15（**被详情页 8 处复用**：`OrganizationDetailView.swift:812,1343,1538,1571,1601,1652,2040,6278`） |

嵌套：`OrganizationView.ArticleSearchNavigation`（:164-168，`id/article/siteId`）；extension 内私有嵌套 `OrgIndexEntry`（:2117-2122）、`OrgTreeBox`（:2371-2374）。

### 3.2 列表页结构（**关于「七分区」的口径核实**）

> ⚠️ **「七分区」在源码与设计稿中均无此命名**（`grep "分区"` 仅命中设计稿 §5.1 的层级图，共 5 层：玻璃吸顶栏/Hero/Bento 焦点区/分组×5/底部）。下列「实测可数区块」为本次按 `contentView`（:427-507）代码顺序读出，供 Wiki 采用为可验证口径；如需沿用「七分区」措辞，建议标注为**本模块自定义口径**。

`contentView`（:427-507）= `ScrollView` + `LazyVStack(spacing:16, pinnedViews:[.sectionHeaders])`，实测区块：

| # | 区块 | 行号 | 关键实现 |
|---|---|---|---|
| ① | 搜索模式切换器 | 431 → 1332-1368 | 机构/文章分段；切模式清空搜索态（:331-341） |
| ② | Hero 概述 | 442 → 920-937 | 「N 个机构 · 5 大类 · M 个官网子站」+ 铜金饰线（`OrgTheme.brass` 44×2，:928-932） |
| ③ | Bento 焦点区 | 444 → 941-1073 | 1 大 2 小；`portalSiteKeys` 固定 `["jwc","tw","sxy"]`（`OrgContentIndex.swift:428`）；数据来自 `portalStats`（`@State`，:155） |
| ④ | 搜索/筛选状态栏 | 450-452 → 519-578 | 关键词 + 分类点 + 结果计数胶囊 + 清除 |
| ⑤ | 数据来源指示器 | 455 → 859-916 | 绿点=服务器 / 橙点=预置；`relative` 时间；错误行内提示（:885-894） |
| ⑥ | 名称排序提示 | 458-460 → 701-715 | 仅名称排序时出现 |
| ⑦ | 玻璃吸顶 chips + 分类区块 | 475-478（header）→ 582-627 / 468-473 → 1077-1108 | header 为 `categoryFilterChips`；每分类一个 `categorySection`，`SJZRevealOnce(key:"org.group.<分类>", delay: sortOrder*0.06)` 错峰入场（:470-472） |

- **三区仅在「默认视图」显示**：`!isSearching && !isFiltering && sortOrder == .defaultOrder` 才渲染 ②③（:441-446）——设计稿「搜索/筛选/排序时保持专注」。
- 加载态：`loadingView`（:408-423）用 `OrgSkeletonBlock` 拼 5 块骨架（详情页共用同一组件）。
- 空态两分支：`emptySearchResult`（:719-745）/ `emptyFilterResult`（:748-772）。

### 3.3 玻璃吸顶（GlassEffectContainer + 8pt 阈值）

- `categoryFilterChips`（:582-627）：`GlassEffectContainer(spacing: 8)` 包横向 chips；背景 `isScrolledPastThreshold ? .ultraThinMaterial : OrgTheme.bg.opacity(0)`（:616-620）；底部分割线高度 0/1 随阈值切换（:622-626）——注释明确「静止用实体面，省离屏渲染」。
- 阈值来源：`onScrollGeometryChange` 读 `contentOffset.y > 8`（:488-500），`withAnimation(.easeOut(0.25))` 切换。
- **首次吸顶触觉**：`if past && !glassBarHapticFired { glassBarHapticFired = true; OrgHaptics.soft() }`（:496-499）——会话内一次。
- chip 单个样式 `filterChip`（:638-675）：`.glassEffect(.regular.tint(OrgTheme.glassTint(color, active: isSelected)).interactive(), in: .capsule)`（:667-670）；分类色 12%/18% 衬底由 `OrgTheme.categoryTintOpacity` 提供；badge 显示该分类机构数（:598-603）。
- 分类切换触觉：`selectCategory` → `OrgHaptics.selection()` + `spring(0.4, 0.85)`（:630-635）。

### 3.4 Bento 焦点区

| 元素 | 行号 | 实现要点 |
|---|---|---|
| `focusBenchSection` | 941-973 | 标题「门户机构」+ `sparkles` + `brassStrong`；heroKey = `portalSiteKeys.first`，smallKeys = 其余 2 个 |
| `focusHeroCard` | 976-1034 | 40×40 图标瓦片 + 机构名 16pt bold + 分类 11pt + `chevron`；有 `stats` 时加「N 个栏目 · 最新一篇标题」；圆角 `Radius.hero`(22) + 分类色描边 + 阴影；`OrgPressStyle()` + `OrgHaptics.light()` |
| `focusSmallCard` | 1037-1073 | 34×34 瓦片 + 名称 14pt + 「N 个栏目」；圆角 `Radius.card`(18) |
| 预取 | 501-515 → `OrgHomeCache.prefetchPortals()` | `.task` 触发；**串行 3 站点**（`OrgContentIndex.swift:463-475`），缓存命中零请求；`guard portalStats.isEmpty` 保证只跑一次 |
| 统计行 | `cachedStatText` 1264-1271 | **仅缓存命中显示**「N 个栏目」（list 类栏目数）；未命中返回 nil 不留占位（设计稿请求预算 §5.1） |

> ⚠️ **实现与设计稿的偏差（实测）**：设计稿 §5.1 请求预算 ②③ 声称「其余机构统计只在进入其详情页时获取并**回填** `OrganizationManager` 缓存」「预取与详情**共用同一缓存键**，二次进入零请求」。实测 `OrganizationDetailView.loadData` **直接调 `NetworkService.shared.fetchDeptHome2`（:2225），全程不读写 `OrgHomeCache`**（`grep OrgHomeCache` 仅命中 `OrganizationView.swift:512,942,1266` 与 `OrgContentIndex.swift`）。→ ① 详情页**不回填**统计；② 列表页「N 个栏目」**只可能出现在 jwc/tw/sxy 三个门户机构**上；③ 进入详情页会**再发一次** `/dept/home2`（预取数据被浪费）。

### 3.5 分类区块与机构卡

- `categorySection`（1077-1108）：默认排序且 `units.count > 1` 时，**每组首卡升格为宽卡**（`usesWideLeadCard`，:1078-1080），其余进双列 `LazyVGrid`。
- `wideUnitCard`（1155-1195）：96×72 图标瓦片（`linearIcon` 26pt light）+ 名称 15pt bold + `cachedStatText ?? "官网子站"` + `followBadge` + `chevron`。
- `unitCard`/`cardContent`（1144-1152 / 1209-1261）：34×34 图标瓦片 + `followBadge` + 名称（搜索时走高亮）+ 缓存统计行。
- 搜索高亮：`buildHighlightedAttributedString`（1276-1304）**直写 `AttributedString.font`**，并读 `DisplaySettingsManager.typographySnapshot()` 让高亮片段跟随字号/字族（注释标明「普通护栏不可见」，:1292-1296）；铜金底 `OrgTheme.brass.opacity(dark ? 0.30 : 0.22)`（:1320）。
- 关注角标 `followBadge`（1199-1207）：`bell.fill` 9pt `brassStrong`，仅 `siteKey` 非空且 `followStore.isFollowing` 时渲染。

### 3.6 搜索：模式 / 防抖 / 双通道 / 深度检索

**机构搜索（本地，零网络）**：`filteredDepartments`（:194-229）= 分类过滤 + `name/category.rawValue` 小写包含 + 4 种排序（`.nameAsc/.nameDesc` 用 `localizedCompare`）。

**文章搜索**（`extension OrganizationView`，1330-2507）：

| 环节 | 行号 | 细节 |
|---|---|---|
| 防抖 | 313-328 | `onChange(searchText)` → 取消旧 `articleSearchTask` → `Task.sleep(500ms)` → `performArticleSearch` |
| 主体 | 1908-2111 | ① E13 query 缓存命中秒回（见下）② 栏目 ID 解析（1940-1957，双通道：`DataService` 缓存 → `refreshNewsColumnIdsFromHome2`）③ 主站 4 栏目并行 `withThrowingTaskGroup`（1963-2002） |
| 分页（主站） | 1969-1983 | `let maxPages = deep ? 8 : 4`；`size: 50`；提前终止三条件：`list.isEmpty \|\| all.count >= total \|\| (page == 1 && all.count < 50)` |
| 相关性打分 | 2017-2046 | 标题命中 +3、完全相等再 +2、前缀再 +1；描述 +1；多词命中额外 `matchedTermCount * 0.5` |
| 栏目短名 | 1885-1893 | 学校要闻→要闻 / 新闻资讯→资讯 / 党建动态→党建 / 通知公告→通知（未知保留原名）；配色 `searchColumnColor`（1896-1904） |
| 机构子站频道 | 2161-2240 | 站点清单来自 `OrganizationManager.shared.departments` 按 `siteKey` 去重（2168-2174）；**分批 8 站**（2186）；进度文案 `orgSearchProgress`（2194）；逐批**流式合入** `articleSearchResults`（2221-2223） |
| 单子站全栏目拉取 | 2246-2325 | 索引 30 min 缓存（`cachedOrgIndex`，2129-2136）→ 落空 `fetchDeptSiteIndex`（2251）；栏目按语义优先级排序（`["新闻","通知","公告","动态","要闻","工作","风采","资讯"]`，2274-2280）；**栏组分批 6**（2287）；逐栏 `total` 驱动分页（`while page <= maxPages, all.count < total, !list.isEmpty`，2302-2310） |
| 单文章型机构频道 | 2394-2468 | 机构树 30 min 缓存（`cachedOrgTree`，2379-2384）→ 并行 `fetchZSWArticleDetail(articleId:siteId:"1")`（2422）；标题 +4 / 正文 +1；`tag="机构介绍"`，`columnName="机构介绍"` |
| 深度检索入口 | 1557-1576 / 1667-1685 / 1692-1703 | 有结果时也给入口（文案「还有更早的文章？深度检索全部栏目（每栏至多 400 条）」）；触发时先清空结果再 `deep: true` |
| E13 query 缓存 | 1864-1882 / 1924-1937 | `NSLock` 保护的静态字典，键=关键词，**容量 20**（FIFO 淘汰 `keys.first`），TTL 600s，**仅 `CacheModeManager.isCacheEnabled` 且非 deep 时命中** |
| 搜索历史 | 148 / 2083-2089 | UserDefaults `"orgArticleSearchHistory"`，去重 + 最多 10 条 |
| 结果视图 | 1460-1579 | 进度胶囊（1463-1484）、排序菜单（1510-1535）、范围 chips（1604-1652）、空态（1655-1689）、结果卡（1706+，含已读光点 :727） |
| 排序/筛选 | 1582-1601 | 范围过滤 `columnName == scope.rawValue`；排序：分数降序 / `updateTime` 字符串比较 |

**「翻到底」在列表页的真实语义**：列表页**没有**触底自动加载；分页边界由「每栏 maxPages（4/8 页 = 200/400 条）+ `total` 提前终止」决定，属**有界检索**而非无限翻页。真正的「滚到底自动加载 + 翻到底锐级触觉」在机构详情页（§4.6）。

### 3.7 刷新

| 入口 | 行号 | 行为 |
|---|---|---|
| 下拉刷新 | 504-506 → `performRefresh(source: "下拉刷新")` | `.refreshable` |
| 工具栏按钮 | 776-792（`refreshButton`，`isLoading` 时转圈并 `disabled`） | `source: "按钮刷新"` |
| `performRefresh` | 796-855 | 下拉 → `OrgHaptics.soft()`（:798-800，工具栏不振动）；`await manager.refresh()`；比较 `detailPageCount` 前后差；3 类 Toast 文案（错误 / `dataSource=="服务器"` / 其他）；结果级 `success()` 或 `error()`（:840-844）；2.5s 自动隐藏（:847-854） |
| Toast | 383-404 | `ultraThinMaterial` 胶囊 + 顶部移入；`zIndex(100)` |

### 3.8 滚动与图片挂起（复用既有基建）

`.scrollBounceBehavior(.always)`（:484）+ `SJZIdleTimerRepairOnScrollStop()`（:485）+ `.sjzScrollSuspendTrack($isScrolling)`（:486）+ `.environment(\.sjzImageLoadingSuspended, isScrolling)`（:487）。

### 3.9 「查看全部机构」入口（**越界说明**）

该入口**不在本模块**：`TabBar.swift:8495`（学校概况页 `OrganizationEntryCard` 的文案）+ `:8527`（accessibilityLabel）+ `:8041/8048/8054`（`totalCount` 取 `OrganizationManager.shared.totalCount`）。本模块只是被导航的目标页（`OrganizationView`），入口卡片的视觉/交互由应用外壳子代理负责。

---

## 4. OrganizationDetailView（6595 行）深度分析

### 4.1 完整类型清单（顶层，`grep -nE "^(private |public |internal |fileprivate |@MainActor )*(final )?(struct|class|enum|extension|protocol|actor) "`）

**共 18 个顶层声明 = 16 个类型 + 2 个 extension。**

| # | 行号 | 声明 | 角色 |
|---|---|---|---|
| 1 | 20 | `enum DeptSectionType: String` | news / notice / regulations / tabs / content / calendar / link / unknown（区块类型） |
| 2 | 32 | `struct OrgSection: Identifiable` | 区块：`id/title/type/articles/children/columnId/siteId` |
| 3 | 43 | `struct OrgChildSection: Identifiable` | 子标签：+ `href`（路由线索） |
| 4 | 55 | `struct OrgArticle: Identifiable, Hashable` | 文章行模型；`readKey`（:67）= `articleId.isEmpty ? title+updateTime : articleId` |
| 5 | 73 | `struct CachedArticleDetail` | title/content/plainText/author/source/publishTime/images/timestamp |
| 6 | 87 | `final class ArticleDetailCache: @unchecked Sendable` | 单例（:88）；`NSCache` 键 `"\(siteId)_\(articleId)"`（:117-119）；`maxAge 300s`（:91）、`countLimit 100`（:94） |
| 7 | 123 | `private final class CachedArticleDetailWrapper` | NSCache 需 class 的包装（:122 注释） |
| 8 | 131 | `struct ArticleNavigation: Identifiable, Hashable` | 文章跳转包装（`id = articleId`） |
| 9 | 146 | `struct ChildSectionNavigation: Identifiable` | 子标签跳转包装 |
| 10 | 198 | `struct OrganizationDetailView: View` | **机构详情页主体（198-2847）** |
| 11 | 2854 | `struct OrganizationArticleDetailView: View` | **文章详情页（2854-4725）** |
| 12 | 4730 | `struct TimeoutError: Error, LocalizedError` | `"操作超时（N秒）"` |
| 13 | 4737 | `struct OrgBriefArticleError: Error, LocalizedError` | 简报型（各级均成功但正文空）——让调用方按 INFO 记日志 |
| 14 | 4897 | `struct OrganizationArticleWebView: UIViewRepresentable` | WKWebView 主力渲染（4897-5513） |
| 15 | 5514 | `extension Notification.Name` | `.organizationArticleWebViewProgress` / `.organizationArticleWebViewBlank` / `.organizationArticleWebViewLoaded` |
| 16 | 5525 | `struct HTMLWebView: UIViewRepresentable` | 兼容旧版（5525-5730） |
| 17 | 5733 | `extension String` | `strippingHTMLTagsFast`(:5737) / `strippingHTMLTagsOptimized`(:5808) |
| 18 | 5907 | `struct ChildSectionDetailView: View` | 子标签详情页（5907-6567，自带分页） |

**嵌套类型（缩进级，3 个）**：`OrganizationArticleDetailView.ContentLinkPreview`（:2891）、`OrganizationArticleWebView.Coordinator`（:5356，`WKNavigationDelegate + WKScriptMessageHandler`）、`HTMLWebView.HTMLWebViewCoordinator`（:5707）。

**文件级私有函数（非类型）**：`resolveMainSiteSearchColumns()`（:171，`@MainActor`）、`withTimeout`（:4746）、`fixImageURLsInHTML`（:4779）、`resolveImageURL`（:4853）、`safeURL`（:5824）、`extractImagesOptimized`（:5844）、`safeImageURL`（:5882）；文件级私有常量 `zswSiteId`（:163）、`scoreLineURL`（:166）。

### 4.2 关键区块划分（前 500 行 + 各功能段起始行）

**前 500 行（模型 + 常量 + 详情页骨架）**

| 行号 | 内容 |
|---|---|
| 1-16 | 文件头注释 + imports（SwiftUI / WebKit / UIKit） |
| 17-158 | 模型层：DeptSectionType / OrgSection / OrgChildSection / OrgArticle / CachedArticleDetail / ArticleDetailCache / Wrapper / ArticleNavigation / ChildSectionNavigation |
| 160-194 | 常量：`zswSiteId`(163)、`scoreLineURL`(166)、`resolveMainSiteSearchColumns()`(171-194) |
| 196-277 | `OrganizationDetailView` 属性区：环境(201-206)、状态(208-237)、`screenHeight/screenWidth`(240/246)、阶段一链路状态(251-266)、阶段二动效状态(268-277) |
| 279-395 | `body`：ZStack(加载/内容/降级 三分支 282-291) + Toast(295-317) + toolbar(321-325) + `navigationDestination`(**zoom 转场** 326-334) + 4 个 sheet(335-374) + admissionQueryURL onChange(375-380) + `.task`(381-387) + `.onAppear`(388-394) |
| 397-419 | `loadingView`（6 块 `OrgSkeletonBlock`） |
| 421-444 | `errorView(_:)` |
| 446-816 | **`enhancedFallbackView` 降级页**（降级文章 / 单文章入口 / 部门简介 / 信息卡） |
| 713-816 | `fallbackArticleCard(_:)` |
| 817-900 | `loadFallbackArticles()`（**降级搜索**） |
| 903-930 | `extractKeywords(from:)`（括号切分 + 9 种后缀 + 去后缀核心词，`Set` 去重） |
| 933-979 | `departmentDescription`（**硬编码 30+ 部门简介文案**，`switch unit.name`） |
| 980-1008 | `infoCard(icon:title:content:)` |
| 1009-1028 | `refreshButton` |

**功能段起始行（后续 6000 行）**

| 行号 | 段 |
|---|---|
| 1029-1079 | 阶段三 C · **关注**（`followPill` 1033 / `toggleFollow` 1058） |
| 1082-1166 | `performDetailRefresh(source:)`（刷新 + 5 类 Toast 判定） |
| 1168-1220 | `contentView`（详情页主结构 + 滚动阈值 + `.refreshable`） |
| 1222-1309 | 部门头部（`departmentHeader` 1224 / `headerStatText` 1277 / `headerBanner` 1289，视差 `offset(y: scrollOffsetY * 0.35)`） |
| 1310-1370 | 阶段一 · 工具入口行（`toolEntriesRow` 1312 / `toolEntryCard` 1323 / `routeToolEntry` 1348） |
| 1371-1430 | 阶段一 · 栏目标签（`columnChipsSection` 1373 / `columnChip` 1399） |
| 1432-1613 | 阶段一 · 栏目文章全量列表（`columnArticlesSection` 1435 / `columnProgressRow` 1462 / `columnListSkeleton` 1477 / `columnEmptyRow` 1501 / `columnErrorRow` 1517 / `columnWebFallbackRow` 1544 / `columnLoadMoreFooter` 1578） |
| 1615-1654 | 阶段一 · 单文章型机构入口卡（`singleArticleCard` 1617） |
| 1656-1895 | 阶段一 · 栏目链路数据方法（`applyColumnIndex` 1660 / `selectedColumn` 1680 / `selectColumn` 1686 / `loadPage` 1730 / `loadMoreIfNeeded` 1836 / `resolveSingleArticle` 1852 / `openSingleArticle` 1879） |
| 1897-2172 | 旧区块渲染兜底（`sectionView` 1900 / `sectionHeader` 1917 / `childTabsView` 1958 / `articleListView` 2046 / `articleCard` 2054 / `placeholderIcon` 2162） |
| 2175-2426 | **`loadData()`**（重试/超时/降级总控） |
| 2428-2722 | 区块解析（`parseSections` 2430 / `sectionTitleFromKey` 2579 / `classifySectionType` 2602 / `parseArticles` 2630 / `parseChildSections` 2655 / `formatDate` 2706） |
| 2724-2846 | `enrichSectionsWithMoreArticles()` —— **已废弃未调用**（注释 2726-2729 说明「阶段一已废弃，按只增不改原则暂留」；`grep` 确认零调用点） |
| 2854-3143 | `OrganizationArticleDetailView`：状态区(2859-2913) + `body`(2920-3143) |
| 3146-3231 | 阶段三 A · 看图与链接（`openWebImageGallery` 3149 / `openStripGallery` 3168 / `handleContentLink` 3184 / `handleGalleryPhase` 3204） |
| 3233-3726 | 加载/错误/空内容/内容视图（`contentView` 3457，含缩略图条 + WebView 双模式） |
| 3727-4223 | `loadArticleDetail(forcePlainText:)`（缓存校验 → 网络 → 短内容 ZSW 补取 → 摘要兜底） |
| 4224-4464 | 长图生成与分享（`startLongImageGeneration` 4277 / `generateLongImage` 4292 / `presentLongImageShare` 4356） |
| 4465-4628 | **`fetchArticleDetailWithFallback()`**（多 siteId 并行） |
| 4632-4724 | `searchMainSiteForArticle(title:)`（主站同标题搜索补全） |
| 4727-4769 | `TimeoutError` / `OrgBriefArticleError` / **`withTimeout`** |
| 4771-4891 | 图片 URL 预处理（`fixImageURLsInHTML` / `resolveImageURL`） |
| 4892-5513 | **`OrganizationArticleWebView`**（`buildHTMLPage` 5083 / `Coordinator` 5356 / 消息桥 5380 / 链接拦截 5397 / `didFinish` 5418） |
| 5514-5730 | `Notification.Name` + 旧版 `HTMLWebView` |
| 5731-5906 | `String` 扩展 + 图片提取工具 |
| 5907-6567 | `ChildSectionDetailView`（分页 5919 / 列表 6074 / 更多按钮 6137 / 卡片 6174 / 加载逻辑 6293） |
| 6568-6595 | `#Preview` |

### 4.3 `loadData()` —— 超时 / 重试 / 5xx-noData 跳重试（2177-2426）

| 阶段 | 行号 | 行为 |
|---|---|---|
| 无 siteKey | 2179-2195 | `isLoading=false`；**重置全部降级态**（`fallbackArticles/fallbackError/isFallbackLoading/hasAttemptedFallback`，2182-2186）；`await resolveSingleArticle()`（2188）→ 渲染 `enhancedFallbackView` + 单文章卡 |
| 有 siteKey | 2197-2204 | 每次加载前清空 `sections` 与降级态（注释「避免旧数据残留」） |
| 重试循环 | 2213 `retryLoop: for attempt in 0...2` | 最多 3 次尝试；每轮开头查 `Task.isCancelled`（2215-2221） |
| 超时保护 | 2224-2226 | `withTimeout(seconds: 12) { fetchDeptHome2(siteKey:) }` |
| ZSW siteId 强制 | 2229-2242 | `nav.first.siteId`；若为 `"1"` 且 `siteKey == "zsw"` → 强替 `zswSiteId`（2234-2242）；无 nav 时同样兜底（2252-2260） |
| 解析 | 2267 / 2282 | `sections = parseSections(from: data)`；`applyColumnIndex(from: data)` |
| 首屏栏目 | 2299-2302 | `OrgColumnIndexBuilder.defaultColumn` → `await selectColumn(firstColumn, reset: true)`（注释「不阻塞页面呈现：pager.isLoading 自带骨架态」） |
| 重试分支 | 2304-2325 | `TimeoutError` / `URLError` → `attempt < 2` 时 `Task.sleep(500ms)` 后重试；**注意：两者都用 `attempt < 2` 判断，第 3 次（attempt==2）失败即落到循环外** |
| **跳重试（关键）** | 2326-2356 | `NetworkError.badResponse(code >= 500)` → `break retryLoop`（2331-2335）；`serverError` → `break retryLoop`（2336-2340）；`noData` → `break retryLoop`（2341-2345）；其余 `default` 才重试（2346-2356）——注释「服务器端错误，重试无意义」 |
| 统一降级 | 2369-2425 | `errorMessage = nil`（注释「不清除错误会导致 body 跳过降级页」2371）；按 `lastError` 类型给文案（2373-2412；5xx/业务错误/noData **只写 WARNING 不给 errorMessage**，直接降级）；`await loadFallbackArticles()`（2418） |

### 4.4 `parseSections` 与区块解析（2430-2722）

- **首页聚合项**（`nav.first` 的 `data` 字典，2441-2478）：逐 `(key, sectionDTO)` → 类型 `classifySectionType`（2602-2628，按 `key`/`componentType` 小写包含判定）/ 标题 `titleCn ?? sectionTitleFromKey(key)`（2579-2600，18 条中文映射）/ 文章 `parseArticles` / 子块 `parseChildSections`；`articles.isEmpty && children.isEmpty` 直接跳过（2450-2455）。
- **其余 nav 项**（2481-2566）：`data` 子区块文章合并 → 若空再试 `navItem.articles`（2500-2502）；`children` 递归为**独立区块**（2505-2543，标题 `"父·子"`）；空则 `continue`（2545）。
- `parseArticles`（2630-2653）：`dto.id + title` 双非空才收；**ZSW 修正**——`unit.siteKey == "zsw"` 且 `sectionSiteId` 为 nil/"1"/空 → 替换为 `zswSiteId`（2633-2639）。
- `parseChildSections`（2655-2705）：子标签可带独立 `siteId`，优先子级（2663）；ZSW 同样强制替换并打印 INFO（2665-2673）。

### 4.5 栏目标签与首屏列表（阶段一核心）

- `applyColumnIndex`（1660-1677）：`OrgColumnIndexBuilder.build(nav:defaultSiteId:)` → 写 `columnSpecs/columnSeedTotals/toolChildren`；**清空 `pagerCache` + `selectedColumnId` + 重置 `pager`**（1665-1667）；日志含每栏 `title[kind]`。
- `selectColumn`（1686-1726）：非 list 类 → 只改选中 ID 并发请求（1687-1696）；**会话缓存命中直接复用 `pagerCache[column.id]`**（1702-1711，切回秒开）；否则 `seedTotal` 种子（1714-1716）→ `loadPage(page:1, reset:true)`。
- `columnChip`（1399-1430）：篇数取 `pagerCache[column.id]?.total ?? columnSeedTotals[column.columnId]`（1401）——**真值优先、种子兜底**；`accessibilityLabel` 带篇数（1429）。
- `columnArticlesSection`（1435-1460）**四态**：非 list → `columnWebFallbackRow`；加载中且空 → 骨架；错误且空 → 错误行；空 → 空态；否则列表 + `columnLoadMoreFooter`。
- `headerStatText`（1277-1288）：**只有当所有 list 栏目 total 都已确证**（`knownTotals.count == listColumns.count`）才追加「共 M 篇」，否则只显示「N 个栏目」——与设计稿「不猜数」一致。

### 4.6 分页（40/页 + 触底自动加载 + 翻到底触觉）

| 环节 | 行号 | 细节 |
|---|---|---|
| 页大小 | `OrgContentIndex.swift:304` | `static let pageSize = 40` |
| 单页加载 | 1730-1833 | 经 `OrgRequestGate.shared.withPermit`（1735，≤3 并发）+ `withTimeout(12s)`（1736）+ `fetchArticles(columnId:siteId:page:size:40)` |
| 防串栏 | 1762-1773 | 响应落地前比对 `selectedColumnId == column.id`；不等则整页写入 `pagerCache[column.id]`（切回秒开），**不污染当前列表** |
| 写缓存 | 1776 | `pagerCache[column.id] = pager` |
| 触觉 | 1780 / 1799 / 1824 | 加载更多到达 → `light()`（仅 `page > 1`）；翻到底 → `rigid()`（一次性，`reachedEndNotified`）；失败 → `error()` |
| 触底自动加载 | 1836-1848 | 行 `.onAppear`（1452）→ `loadMoreIfNeeded`：仅当是最后一行且 `pager.hasMore` 且非加载中 → `loadPage(nextPage)` |
| 兜底按钮 | `columnLoadMoreFooter` 1578-1613 | 手动「加载更多」 |
| 进度文案 | `columnProgressRow` 1462-1475 | `pager.progressText` = 「已显示 40 / 653」/「已显示 40」 |
| 停机判定 | `OrgPagerState`（`OrgContentIndex.swift:321-332`） | `hasMore`：total 已知按真值，未知按「上页是否满页」；`isExhausted`：total 已知且 `articles.count >= total` |
| 去重 | `OrgPagerState.apply`（`OrgContentIndex.swift:358-372`） | 按 `articleId` 集合去重后追加，返回新增数 |

### 4.7 `loadFallbackArticles` 降级搜索（817-900）

1. 幂等门：`guard !isFallbackLoading, !hasAttemptedFallback`（818）——**一次会话只尝试一次**。
2. 栏目 ID：`await resolveMainSiteSearchColumns()`（833）——优先 `/school/home2`，失败用 4 个实测回退常量（188-193）。
3. 并行拉取：4 个主站栏目 `page:1 size:30`（837-842），单栏失败只记 DEBUG（844-849）。
4. 关键词匹配：`extractKeywords(from: unit.name)`（860 / 903-930）→ 标题小写包含任一关键词（861-865）。
5. 结果落 `fallbackArticles`（867-879）；空则 `fallbackError = "未找到与「N」直接相关的文章"`（881-883）。
6. 失败兜底：`fallbackError = "搜索相关文章失败：…"`（892）。

### 4.8 `fetchArticleDetailWithFallback` —— 多 siteId 并行取最长内容（4465-4628）

**siteId 候选列表构建（4477-4486，去重后最多 5 项）**

```
[传入 siteId]
 → article.sectionSiteId（非空且 ≠ 传入）
 → zswSiteId（若 ≠ 传入）
 → "1"（若传入 ≠ "1"）
 → ""（空串兜底）
```

**并行与收集（4496-4532）**：`withTaskGroup` 每 siteId 一个子任务，各自 `withTimeout(seconds: loadTimeout)` + `fetchArticleDetail(articleId:siteId:)`；主循环 `for await` 收集，**首个「有效」结果即 `break` 提前退出**（4520-4529）。有效性判定＝`content` 非空且（`strippingHTMLTagsFast` 后非空 **或** `content.hasImageContent`（纯图片文章），4521-4527）。

> ⚠️ **与任务描述的精确化**：「5 个 siteId 并行取最长内容」需拆成两步理解——**先早退**（首个有效即停止收集，可能只等到 1 个结果），**再取最长**（把已收集到的全部成功结果按 `content.count` 降序取第 1，4585-4603）。因此「最长」只在**早退前已返回的结果集**内成立，不是严格等满 5 路再比。

**失败分类（4534-4582）**：`failedSiteIds` 记录无效 siteId；区分 `networkFailureCount`（真网络失败）与 `emptyContentCount`（成功但正文空/HTML 空壳）。

**出口（4584-4627）**
- 有有效结果 → 排序取最长 → INFO「文章详情获取成功（最长内容）」含 `usedSiteId/originalSiteId/isOriginalSiteId`（4595-4603）。
- **全部成功但正文皆空**（`networkFailureCount == 0`）→ 抛 `OrgBriefArticleError(triedSiteIds:)`（4616）——简报型文章（党建/子站常见）**按正常降级处理记 INFO**，不污染警告栏。
- 有真网络失败 → ERROR + `NetworkError.serverError("所有数据源均无法获取文章内容（已尝试 siteId: …）")`（4618-4627）。

**配套链路**
- `loadArticleDetail`（3731-4136）：① 缓存命中且内容有效（非空壳）→ 直接用（3748-3782）；② `fetchArticleDetailWithFallback()`（3787）；③ 真空 → 用 `article.description` 摘要兜底（3817-3830）；④ **短内容（stripped < 200 且非纯图）→ 单独再试 ZSW siteId**，更长则替换并预取前 3 张图（`SJZImagePrefetcher`，3886-3890）+ 写缓存（3892-3898）。
- `searchMainSiteForArticle(title:)`（4632-4724）：主站 4 栏目 `size:30` 并行 → 标题相等/互相包含匹配（4673-4679）→ 用 `siteId:"1"` 取详情（4690）→ `stripped.count > 50` 才返回（4698-4705）。

### 4.9 `withTimeout` 工具（4746-4769）

```swift
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T
```
实现＝`withThrowingTaskGroup`（4749）：子任务 A 跑实际操作，子任务 B `Task.sleep(nanos)` 后 `throw TimeoutError`；`group.next()` 取先完成者 → `group.cancelAll()`（4762）→ 返回或抛错；`nil` 兜底再抛 `TimeoutError`（4764-4766）。

**全部调用点（实测 7 处）**：`12s` → 详情页 `loadData`(1736)、栏目 `loadPage`(1736)、子标签分页(6367)；`8s` → 废弃 enrich(2773)、主站同标题补全(4689)；`loadTimeout`（实例常量）→ ZSW 短内容补取(3862)、`fetchArticleDetailWithFallback` 子任务(4504)。

### 4.10 文章详情 push + zoom 连续转场（阶段二）

| 环节 | 行号 | 说明 |
|---|---|---|
| 命名空间 | 277 | `@Namespace private var articleZoomNamespace` |
| 转场目标 | 326-334 | `navigationDestination(item: $articleNavigation)` + `.navigationTransition(.zoom(sourceID: nav.article.articleId, in: articleZoomNamespace))` |
| 转场来源 | 2159 | 行卡 `.matchedTransitionSource(id: article.articleId, in: articleZoomNamespace)`（在 `articleCard` 尾部） |
| 交互 | 注释 327 | 「移除自绘关闭按钮，系统返回键接管」（设计稿 v1.2.2） |
| 其余仍走 sheet | 335-374 / 3042-3076 | 子标签、专业介绍、分数线、微信/长图分享、看图（fullScreenCover）、官网链接预览 |

### 4.11 看图桥（阶段三 A 完整链路）

**链路**：`OrganizationArticleWebView` 注入 JS → 用户点正文图 → `postMessage` → `Coordinator.userContentController`（5380-5393）→ 取 `index/urls/alts` → `onImageTap?(index, urls, alts)`（5392）→ `openWebImageGallery`（3149-3165）→ `OrgGalleryPayloadBuilder.make`（`OrgContentIndex.swift:265-282`，纯函数）→ `OrgHaptics.light()` + `webGalleryPayload = payload`（3164）→ `.fullScreenCover(item:)`（3053-3057）→ **`FullScreenImageView`（`TabBar.swift:4240`，共享组件）**。

| 子项 | 实现 | 行号 |
|---|---|---|
| 载荷模型 | `SJZImageGalleryPayload{urls, alts, startIndex, source}` + `clampedStartIndex` 越界防护 | `TabBar.swift:4117-4151` |
| 载荷构造（本模块） | 跳过空串/非 http(s)，**落点索引重映射**（点第 N 张必开第 N 张）；alts 缺位补空串 | `OrgContentIndex.swift:265-282` |
| 1x 横滑翻页 | `pageDragOffset`（`TabBar.swift:4253`）+ `pageTurnDecision`（:4535）+ `turnPage`；`payload.count > 1` 才启用；**不是 TabView 分页** | `TabBar.swift:4248-4255 / 4533-4536` |
| 双指缩放锚点 | `SJZImageViewerGeometry.anchoredOffset`（`offset' = a − (a − offset)·k`） | `TabBar.swift:4196-4200 / 4705-4706` |
| 边界回弹 | `maxOffset`（未溢出轴为 0）→ 拖动中 `rubberBanded`（damping 0.35）→ 松手 `clamped` 落定 | `TabBar.swift:4170-4194 / 4486 / 4512` |
| 倍率 | min 1x / max 5x / 双击 2.5x | `TabBar.swift:4312-4314` |
| 缩略图条入口 | `openStripGallery`（3168-3180）：`galleryLoadedIndices.contains(index)` 才可点（失败图保留「轻点重试」）；载荷 source `organization_detail_strip` | — |
| 加载计数联动 | `handleGalleryPhase`（3204-3231）：success 收集索引 + 顶部进度条 1s 后渐隐；empty 保持显示；skipped（无图模式）不推进 | — |
| 链接拦截 | `decidePolicyFor`：`.linkActivated` → `.cancel` + `onLinkTap`（5397-5409）；`handleContentLink`（3184-3201）：http(s)→App 内 `WebViewContainer`，mailto/tel/sms→系统，其余仅 WARNING | — |
| 就绪探针 | `imageBridgeProbeJS`，`didFinish` 后**延迟 1.2s** 采样（注释：立即采样会把「有图但未就绪」误报为「无可查看图」） | 5458-5472 |
| 自测钩子 | 启动参数 `-uiTestOrgImageBridge` → `imageBridgeSelfTestJS` 自动派发一次真实点击（仅 DEBUG） | 5473-5488 / 5092-5097 |

### 4.12 已读接入（阶段三 B）

| 场景 | 行号 | 行为 |
|---|---|---|
| 已读键口径 | `OrgArticle.readKey`（67） | `articleId` 优先，空则 `title + updateTime` |
| 列表行（旧区块渲染） | 727-793 | 未读光点 6pt `OrgTheme.tint`，已读时 `scaleEffect(0.01)+opacity(0)` 收敛（占位恒定防抖动）；`accessibilityValue(isRead ? "已读" : "未读")` |
| 栏目分页列表 | 2072-2141 | 同上口径（阶段一列表行） |
| 子标签详情 | 6192-6259 | 同上 |
| 进入详情标记 | 3084-3090 | `.task` 内 `if !readManager.isRead(readKey) { markAsRead(readKey) }` + INFO 日志 |
| 搜索结果显示 | `OrganizationView.swift:727` | 搜索结果卡同样显示已读态（与全局已读库同源） |

### 4.13 关注制推送（第五通道触发点）

| 环节 | 行号 | 说明 |
|---|---|---|
| 关注 pill | 1033-1055 | `bell`/`bell.fill`；有色 `brassStrong`（已关注）/`tint`（未关注）；`OrgPressStyle(scale: 0.95)`；未配置 siteKey 的机构**不显示 pill**（1031 注释） |
| `toggleFollow` | 1058-1079 | 构造 `FollowedOrg(siteKey, name, categoryRaw, siteId: deptSiteId.isEmpty ? "1" : deptSiteId)` → `followStore.toggle` → `OrgHaptics.medium()`（1064）→ Toast（1066-1075）→ **关注成功即 `NotificationManager.shared.seedOrgFollowBaseline(for: org)`**（1076-1078，fire-and-forget） |
| 通道调度 | `NotificationManager.swift:318` | `checkAllUpdates` 里五通道串行，机构动态是第 5 条：`checkNewsUpdates / checkMailboxUpdates / checkSchoolProfileUpdates / checkPartySubjectUpdates / checkOrgFollowUpdates` |
| 通道实现 | `NotificationManager.swift:761-871` | 只遍历 `OrgFollowStore.shared.followed`（762）；**无关注 → 零请求短路**（763）；单轮最多 10 个机构（766）；每站 1 次 `/dept/home2`（776）；候选由 `OrgFollowArticleScanner.candidates` 产出（777）；冷启动首轮只登记不推送（780-785）；单轮全局推送上限 `maxNotificationsPerCheck`（774/788）；通知标识 `"org-\(articleId)"`（790）；userInfo 带 `orgArticleId/orgName/orgCategory/orgSiteId/articleTitle`（796-804）；命中同时入消息中心 `MessageCenterStore.ingest(kind: .orgUpdate)`（829-839）；`notifiedOrgArticleIds` 并集写回（856） |
| 基线播种 | `NotificationManager.swift:875-899` | 关注动作触发：把该机构当前可见文章全部登记为已通知（不推送）；并建立全局基线标记 `orgFollowBaselineEstablished`（885-887） |
| 深链回跳 | `TabBar.swift:39/82-103/288/325/398-401` | `pendingOrgArticleDeepLink` → `pendingOrgArticle` → 打开机构文章详情（消费细节属应用外壳子代理） |

### 4.14 下拉刷新（详情页）

`.refreshable`（1210-1219）：先 `OrgHaptics.soft()`（触发级）→ `await performDetailRefresh(source: "下拉刷新")` → 按 `refreshToastSuccess` 给 `success()` 或 `error()`（结果级）。`performDetailRefresh`（1082-1166）取消旧 `loadTask` 并重建（1094-1097），Toast 文案优先级：有文章数 → 有降级数据 → `errorMessage` → `fallbackError` → 「该部门暂无内容」（1104-1152）。

### 4.15 WebView 渲染层（补充）

- `buildHTMLPage`（5083-5355）：正文 HTML 包装（排版 CSS 注入、图片宽度约束、`viewport` 等）。
- 排版兜底：`didFinish` 后再注入 `latestTypographyCSS`（5431-5435，DOM 级 inline `!important`）。
- 空白检测：`document.body.innerText.trim().length > 0 || document.querySelector('body img') !== null`（5439）——**纯图片文章不误判**；空白则 post `.organizationArticleWebViewBlank`（5445-5448）。
- 视频探针：`OrgMediaProbe.videoSourceCount(in:)`（`OrgContentIndex.swift:289-296`），调用点 `OrganizationDetailView.swift:5097`，**仅日志取证不参与渲染决策**（注释 288）。
- 旧版 `HTMLWebView`（5525-5730）保留向后兼容；`extension String.strippingHTMLTagsFast`（5737，纯正则）被全模块用于内容有效性判定。

---

## 5. OrgContentIndex（509 行，阶段一新层）深度分析

### 5.1 类型清单（11 个）

| 行号 | 声明 | 职责 |
|---|---|---|
| 21 | `enum OrgColumnKind: String` | `.list` / `.webFallback` / `.calendar` |
| 49 | `struct OrgColumnSpec: Identifiable, Equatable` | `id/columnId/siteId/title/componentType/href` + `kind` 派生 |
| 64 | `enum OrgColumnIndexBuilder` | 纯函数索引构建（`build` 93 / `defaultColumn` 195） |
| 208 | `actor OrgRequestGate` | 模块内网络并发闸（≤3，FIFO） |
| 258 | `enum OrgGalleryPayloadBuilder` | 正文图 → 看图载荷 |
| 287 | `enum OrgMediaProbe` | 视频源计数（仅日志） |
| 302 | `struct OrgPagerState` | 分页状态机（纯值类型） |
| 389 | `struct SingleArticleEntry: Equatable` | 单文章型机构条目 |
| 395 | `enum OrgSingleArticleResolver` | 机构名 → article_id |
| 415 | `struct PortalStats: Equatable` | 门户机构摘要 |
| 424 | `@MainActor final class OrgHomeCache` | 首页数据内存缓存（TTL 1800s） |

### 5.2 栏目类型分派（`OrgColumnKind.classify`，33-44）

- `.list`：`news / news-important / notice / notice-small / content / download / tabs / tabs-sub / teacher / videos / electronic-book / thematic-center / recruit`（36-38）。
- `.calendar`：`calendar`（39-40）。
- `.webFallback`：**其余全部**（含 `link / opinion / "0" / 未知`）（41-42）。
- 注释记录了 2026-09-30 实测的 **52 个 home2 响应 componentType 分布**（30-32：tabs 49 / news 33 / notice 32 / opinion 26 / notice-small 24 / news-important 14 / content 11 / download 9 / link 4 / tabs-sub 4 / teacher 2 / electronic-book 2 / calendar 1 / thematic-center 1 / videos 1 / recruit 1 / `"0"` 8）。→ **该分布为文档/注释口径，本次未联网复算（未验证）**。

### 5.3 索引构建（`build`，93-192）—— 「nav 数组 = 栏目唯一真值源」

| 步骤 | 行号 | 规则 |
|---|---|---|
| 聚合项处理 | 119-139 | 标题 ∈ `aggregateTitles`（= `["首页"]`，67）→ **不下发为栏目**；遍历其 `data` 区块：取 `section.articles.total > 0` 作 `seedTotals[columnId]`（122-124，取 max）；`children.list` 递归为栏目（125-135） |
| 普通 nav 项 | 142-146 | **每项 = 一个栏目**（`column_id` 为空则丢弃，101） |
| 子导航（深层菜单） | 149-163 | `isToolTitle`（含「专业介绍/分数线/录取查询」，70-72）→ 收进 `toolChildren`；其余并入栏目，标题为空则继承父标题 |
| nav.data.children（菜单型栏目） | 166-184 | 同上分流 |
| 去重 | 97 / 101 / 188-189 | 栏目按 `columnId` 去重；工具入口按标题去重 |
| 默认选中 | 195-201 | 优先「有 total 种子且 list 类」→ 首个 list 类 → 首个栏目 |

### 5.4 请求并发闸 `OrgRequestGate`（208-249）

- `actor`，单例 `maxConcurrent: 3`（209）。
- `withPermit(_:)`（222-226）：`await acquire()` → `defer release()` → 执行。
- `acquire`（229-238）：无等待者且未满 → 直接 `active += 1`；否则 `withCheckedContinuation` 入队（FIFO）。
- `release`（241-248）：**有名额交接**——有等待者时 `resume` 下一个（`active` 不变），否则 `active -= 1`。
- 注释明确「与图片闸 `SJZImageConcurrencyGate` 相互独立（图片与数据请求预算分离）」（207）。
- **实测使用点 3 处**：`OrganizationDetailView.loadPage`（1735）、`resolveSingleArticle`（1862）、`OrgHomeCache.home`（`OrgContentIndex.swift:453`）。→ 列表页的文章搜索链路（`OrganizationView.searchOrganizationArticles/fetchOrgArticles`）**未过闸**（自行用「批 8 站 / 批 6 栏」控制并发）。

### 5.5 分页状态机 `OrgPagerState`（302-384）

`pageSize = 40`（304）；状态：`articles/total/loadedPages/lastPageCount/isLoading/isLoadingMore/errorText/reachedEndNotified`；方法：`beginLoad(reset:)` 346 / `apply(page:list:total:)` 358（去重追加，返回新增数）/ `fail(_:)` 374 / `seedTotal(_:)` 381；派生：`displayedCount` 318 / `hasMore` 321 / `isExhausted` 329 / `progressText` 335 / `nextPage` 343。

### 5.6 看图载荷 / 媒体探针 / 单文章解析 / 首页缓存

- `OrgGalleryPayloadBuilder.make`（265-282）：见 §4.11。
- `OrgMediaProbe.videoSourceCount`（289-296）：正则 `<(?:video|source)\b[^>]*\bsrc\s*=\s*["'][^"']+["']`（忽略大小写）。
- `OrgSingleArticleResolver.articleId(forOrgName:)`（397-409）：`fetchSchoolOrgTree()` → 去空格后**精确匹配（要求 `articleId != nil`）→ 包含匹配**（双向 `contains`）→ 返回 `articleId`。注释标明适用「党委组织部 / 工会 / 妇联 等 11 个」（388）。
- `OrgHomeCache`（424-509）：`portalSiteKeys = ["jwc","tw","sxy"]`（428）；`Entry{data, fetchedAt}` + `ttl 1800`（436）；`cached(siteKey:)`（438-442）；`home(siteKey:force:)`（449-458）经 `OrgRequestGate` 拉取并写入；`prefetchPortals()`（461-483）**串行**遍历 3 站点、失败只 WARNING；`stats(from:siteKey:)`（486-509）= list 栏目数 + 首页嵌套区块 `update_time` 最大者的标题/时间。

### 5.7 消费方矩阵（`grep` 实测）

| 类型 | 消费点 |
|---|---|
| `OrgColumnIndexBuilder` | `OrganizationDetailView.applyColumnIndex:1661`、`loadData:2300`；`OrganizationView.cachedStatText:1267`；`OrgHomeCache.stats:489` |
| `OrgPagerState` | `OrganizationDetailView:262/264/1667/1689/1713/1741/1763/1788` |
| `OrgRequestGate` | `OrganizationDetailView:1735/1862`；`OrgHomeCache.home:453` |
| `OrgSingleArticleResolver` | `OrganizationDetailView.resolveSingleArticle:1853` |
| `OrgGalleryPayloadBuilder` | `OrganizationArticleDetailView.openWebImageGallery:3150` |
| `OrgMediaProbe` | `OrganizationArticleWebView.buildHTMLPage:5097` |
| `OrgHomeCache` | `OrganizationView.prefetchPortals:512`、`portalSiteKeys:942`、`cachedStatText:1266` |
| `OrgColumnSpec / OrgColumnKind` | `OrganizationDetailView` 状态与 chips/列表渲染 |
| `PortalStats` | `OrganizationView.portalStats:155`、焦点卡入参 |

---

## 6. OrgFollowStore（166 行，阶段三 C）深度分析

### 6.1 类型清单（3 个）

| 行号 | 声明 | 说明 |
|---|---|---|
| 20 | `struct FollowedOrg: Codable, Equatable, Identifiable` | `siteKey`(主键) / `name` / `categoryRaw` / `siteId`（缺省 `"1"`）；`id = siteKey`；`category` 派生（未知回落 `.administrative`） |
| 39 | `@MainActor final class OrgFollowStore: ObservableObject` | 单例（40）；`@Published private(set) followed`（46）；`defaultsKey = "orgFollowedOrgs"`（42） |
| 125 | `enum OrgFollowArticleScanner` | 纯函数扫描器（`Candidate` 嵌套 127） |

### 6.2 关注存储

| 方法 | 行号 | 行为 |
|---|---|---|
| `isFollowing(siteKey:)` / `count` / `siteKeys` | 55-61 | 查询 |
| `toggle(_:)` | 67-87 | 已关注 → 移除 + persist + INFO「取消关注机构」；未关注 → append + persist + INFO「关注机构」（含 category/total） |
| `removeAll()` | 90-96 | 清空；注释：「设置面板『全部取消关注』入口；**当前无 UI 调用**，保留为运维与单测入口」（89）→ **实测无调用点** |
| `encode/decode`（`nonisolated static`） | 100-109 | JSON 字符串 ⇄ `[FollowedOrg]`；**容错解码：损坏数据一律回落 `[]`**（105-109），可单测 |
| `persist()` | 111-119 | 编码失败只 WARNING「本轮不落盘」 |

### 6.3 与 NotificationManager 第五通道的接口（契约面）

| 方向 | 接口 | 位置 |
|---|---|---|
| 本模块 → 通知 | `NotificationManager.shared.seedOrgFollowBaseline(for: org)` | 调用：`OrganizationDetailView.toggleFollow:1077` |
| 通知 → 本模块 | `OrgFollowStore.shared.followed`（只读遍历，取前 10） | `NotificationManager.swift:762,766` |
| 通知 → 本模块 | `OrgFollowArticleScanner.candidates(from:limit:)` | `NotificationManager.swift:777,878` |
| 去重集（通知侧） | `notifiedOrgArticleIds`（第五通道独立去重集）+ `orgFollowBaselineEstablished` | `NotificationManager.swift:174,184-185,767,856-858` |
| 深链（通知 → 外壳 → 本模块详情） | userInfo `orgArticleId/orgName/orgCategory/orgSiteId` → `DeepLinkPayload` → `MessageCenterStore.kind = .orgUpdate` | `NotificationManager.swift:796-839`；`MessageCenterStore.swift:43-46,774-775`；`TabBar.swift:39,82-103` |

**扫描器规则（`OrgFollowArticleScanner.candidates`，137-156）**：遍历 `data.nav` → 每项 `data` 字典的每个 section：`section.articles.list` + `section.children.list[].articles.list`（141-144）+ `item.articles.list` + `item.children[].articles.list`（146-149）→ 按 `articleId` 去重（152-153）→ **按 `updateTime` 字符串降序**（154）→ `prefix(limit)`（默认 20，137）。

---

## 7. OrgTheme / OrgHaptics

### 7.1 OrgTheme（144 行）设计令牌

| 组 | 令牌 | 行号 |
|---|---|---|
| 面 | `bg`(F7F5F0/0F141B) / `bgTop` / `surface` / `surfaceMuted` / `separator` | 20-28 |
| 文字三级 | `textPrimary` / `textSecondary` / `textTertiary`（注释给对比度 14.37/5.36/4.60，深色 16.32/8.23/5.48） | 32-34 |
| 主色/交互/点睛 | `primary`(墨蓝 1E3A66) / `tint`(交互蓝 2C5CA8) / `brass`(铜金 8F7038) / `brassStrong`(7A5F2E) | 39-45 |
| 语义 | `success` / `warning` / `danger` | 49-51 |
| 背景 | `backgroundGradient`（`bgTop → bg` 2 级） | 55-57 |
| 分类五色 | `categoryColor(_:)`：绛红/赭橙/藏青/青莲/松青（注释带 WCAG 实算值） | 61-69 |
| 衬底 | `categoryTintOpacity(scheme)` = 深 0.18 / 浅 0.12 | 72-74 |
| 几何 | `Radius`：tile 10 / row 14 / card 18 / hero 22 / capsule 999；`Spacing`：4/8/12/16/20/24/28 | 78-94 |
| 图标 | `linearIcon(_:)` 去 `.fill` 后缀 | 99-101 |
| 玻璃 | `glassTint(color, active:)` = active ? 0.28 : clear | 106-108 |
| 按压 | `OrgPressStyle`：scale 0.97 + brightness −3% + `spring(0.3, 0.85)` | 114-123 |
| 骨架 | `OrgSkeletonBlock`：`surfaceMuted` + 复用 `ShimmerView` 微光 | 128-144 |

**使用点（实测计数）**：`OrgPressStyle`/`OrgSkeletonBlock` 在 `OrganizationView.swift` 计 10 处、`OrganizationDetailView.swift` 计 9 处（`grep -c`）。`OrganizationCategory.color` 转发到 `OrgTheme.categoryColor`（`OrganizationManager.swift:38-40`）。

### 7.2 OrgHaptics（59 行）振动分级

| 级别 | 实现 | 设计稿语义（8-9 行注释） | 实测调用点 |
|---|---|---|---|
| `selection()` | `UISelectionFeedbackGenerator` | 选择｜平级切换（分类/栏目 chips、排序） | `OrganizationView:631`、`OrganizationDetailView:1405` |
| `light()` | `impact(.light)` + `prepare()` | 轻｜完成·进入（进详情/加载更多到达/打开图片） | `OrganizationView:1033,1072,1151,1194`；`OrganizationDetailView:1780,2057,3158,3173` |
| `soft()` | `impact(.soft)` + `prepare()` | 柔｜开始·触发（下拉刷新触发/吸顶首次/toast） | `OrganizationView:498,799`；`OrganizationDetailView:1212` |
| `medium()` | `impact(.medium)` | 中｜状态改变（收藏/关注/长按菜单/字号） | `OrganizationDetailView:1064`（关注） |
| `rigid()` | `impact(.rigid)` | 锐｜边界·干脆（翻到底/回弹到顶底/空态无变化） | `OrganizationDetailView:1799`（翻到底） |
| `success()` | `notificationOccurred(.success)` | 结果·成功（关注成功/刷新完成） | `OrganizationView:841`；`OrganizationDetailView:1215` |
| `warning()` | `notificationOccurred(.warning)` | 结果·注意（弱网降级提示） | **0 处**（实测无调用点，未使用） |
| `error()` | `notificationOccurred(.error)` | 结果·失败（加载/同步失败） | `OrganizationView:843`；`OrganizationDetailView:1217,1824` |

**合计 20 处调用**（列表页 9 + 详情页 11）。约束（注释 9）：模块内新增交互必须映射到词表之一，禁止裸用生成器。

---

## 8. 前端 → 接口映射表（UI 区块 ↔ NetworkService 端点 ↔ 缓存键）

### 8.1 机构模块实际调用的端点（7 条 API + 1 个 HTML 页）

| # | 端点 | NetworkService 封装 | 调用点（文件:行） | 参数 |
|---|---|---|---|---|
| 1 | `GET /common/column/head` | `fetchHead()`（`NetworkService.swift:182`） | `OrganizationManager.swift:432` | 无参 |
| 2 | `GET /dept/home2` | `fetchDeptHome2(siteKey:)`（`NetworkService.swift:964`） | `OrgContentIndex.swift:454`（`OrgHomeCache.home`）；`OrganizationDetailView.swift:2225`（`loadData`）；`NotificationManager.swift:776 / 877`（第五通道） | `site_key` |
| 3 | `GET /dept/home2`（原始 JSON 解析版） | `fetchDeptSiteIndex(siteKey:)`（`NetworkService.swift:1022`） | `OrganizationView.swift:2251`（文章搜索的栏目索引） | `site_key`；返回 `site.site_id` + 递归全栏目 |
| 4 | `GET /common/column/articles` | `fetchArticles(columnId:siteId:page:size:)`（`NetworkService.swift:192`） | 7 处：`OrganizationDetailView:1737`（栏目分页 40/页）、`:2774`（**已废弃** enrich，20/页）、`:837`（降级搜索 30/页）、`:4650`（主站同标题补全 30/页）、`:6368`（子标签分页 20/页）；`OrganizationView:1972`（主站搜索 50/页 4~8 页）、`:2295/:2303`（子站搜索 50/页） | `site_id`、`column_id`、`page`、`size` |
| 5 | `GET /common/article/detail` | `fetchArticleDetail(articleId:siteId:useCache:)`（`NetworkService.swift:199`） | 4 处：`OrganizationDetailView:1863`（单文章型，`useCache:true`）、`:3863`（短内容 ZSW 补取）、`:4505`（多 siteId 并行）、`:4690`（主站补全） | `site_id`、`article_id` |
| 5b | 同上（ZSW 变体） | `fetchZSWArticleDetail(articleId:siteId:)`（`NetworkService.swift:881`，默认站 `cb3b1fe4…`） | `OrganizationView.swift:2422`（单文章型机构频道） | 同上 |
| 6 | `GET /school/home2` | `fetchHome2()`（`NetworkService.swift:177`） | `OrganizationDetailView.swift:172`（`resolveMainSiteSearchColumns` 解析主站栏目 ID） | 无参 |
| 7 | `GET /school/org` | `fetchSchoolOrgTree()`（`NetworkService.swift:985`） | `OrgContentIndex.swift:398`（单文章型机构解析）、`OrganizationView.swift:2397`（单文章机构频道） | 无参；递归收集叶子节点 |
| 8 | `GET https://www.sxjzit.edu.cn/`（HTML，非 API） | 无封装（`urlSession.data`，`OrganizationManager.swift:526`） | `OrganizationManager.swift:515-568`（`validateFromPageHTML`，**仅日志校验**） | 15s 超时、`reloadIgnoringLocalCacheData` |

> ⚠️ 与摸查文档的差异说明：`departments-api-inventory.md` §1 的 **20 端点**为官网全量契约（含 `/school/msg`、`/common/recruit/query`、`/common/short/create` 等与机构无关项）；机构模块**实际只消费 7 条 API**。此外文档 §10「App 现有实现对照」提到的 `/college/home`（6 学院）在当前源码中**仍无调用**（`grep` 全仓无 `college/home`/`fetchCollegeHome`，仅 `OrgContentIndex.swift:12` 有注释解释「nav 为空 → 统一走 `/dept/home2`」）——即 01 报告的根因④以「改用 `/dept/home2`」方式结案，而非接入 `college/home`。

### 8.2 UI 区块 ↔ 端点 ↔ 缓存键

| UI 区块（文件:行） | 端点 | 缓存键 / 存储 | TTL / 容量 |
|---|---|---|---|
| 列表 · 数据来源指示器（`OrganizationView.swift:859`） | — | `OrganizationManager.departments`（内存） | 会话 |
| 列表 · 机构清单刷新 / 下拉刷新（`:504`、`OrganizationManager.swift:398`） | `/common/column/head` | `UserDefaults["organizationCache"]`（`OrganizationCache` JSON） | 定时 1800s；缓存模式新鲜度 600s；无 TTL 硬过期（只按新鲜度跳过远程） |
| 列表 · Bento 焦点区（`:941`） | `/dept/home2` ×3（jwc/tw/sxy） | `OrgHomeCache.entries[siteKey]`（内存） | 1800s / 无容量上限（仅 3 门户 + 详情未写入） |
| 列表 · 卡片「N 个栏目」统计（`:1264`） | （读缓存，不发起） | `OrgHomeCache.cached(siteKey:)` | 同上 |
| 详情 · 身份头/区块（`OrganizationDetailView.swift:2225`） | `/dept/home2` | `homeData`（`@State`，会话） | 会话；**未接入 `OrgHomeCache`**（见 §3.4 偏差） |
| 详情 · 栏目 chips 篇数种子（`:1661`） | （来自 home2 响应 `nav.data.*.articles.total`） | `columnSeedTotals`（`@State`） | 会话 |
| 详情 · 栏目文章分页（`:1730`） | `/common/column/articles`（size 40） | `pagerCache[columnId]`（`@State`，内存） | 会话；`pager` 为当前栏目视图 |
| 详情 · 单文章型机构（`:1852`） | `/school/org` + `/common/article/detail`（`useCache:true`） | 无独立缓存 | — |
| 文章详情 · 正文（`OrganizationArticleDetailView:3731`） | `/common/article/detail`（多 siteId） | `ArticleDetailCache`（`NSCache`，键 `"\(siteId)_\(articleId)"`） | 300s，`countLimit 100` |
| 文章详情 · 短内容补取（`:3862`） | `/common/article/detail`（ZSW siteId） | 同上（写回） | 同上 |
| 文章详情 · 主站同标题补全（`:4632`） | `/common/column/articles` ×4 + `/common/article/detail` | **不缓存** | — |
| 文章详情 · 缩略图条/看图 | —（图片走共享图片缓存/预取 `SJZImagePrefetcher`） | `galleryLoadedIndices`（`@State`） | 会话 |
| 子标签详情（`:6333`） | `/common/column/articles`（size 20，多 siteId） | 无缓存（`articles`/`currentPage` `@State`） | 会话 |
| 降级页（`:817`） | `/school/home2` → `/common/column/articles` ×4（size 30） | **不缓存**；`hasAttemptedFallback` 单次门 | 会话一次 |
| 搜索 · 主站频道（`OrganizationView.swift:1908`） | `/common/column/articles` ×栏目（size 50，≤4/8 页） | `searchQueryCache`（静态字典 + `NSLock`） | 600s / 20 条；仅缓存模式生效 |
| 搜索 · 子站栏目索引（`:2246`） | `/dept/home2`（`fetchDeptSiteIndex`） | `UserDefaults["orgSearchIndexCache"]` = `[siteKey: OrgIndexEntry]`，`version = 3` | 1800s / 最多 60 站（按 `fetchedAt` 淘汰最旧） |
| 搜索 · 单文章机构（`:2394`） | `/school/org` + `/common/article/detail` | `UserDefaults["schoolOrgTreeCache"]` = `OrgTreeBox` | 1800s |
| 搜索 · 历史（`:2083`） | — | `UserDefaults["orgArticleSearchHistory"]` | 最多 10 条 |
| 关注 pill / 列表关注角标（`:1033` / `OrganizationView.swift:1199`） | —（关注动作额外发 `/dept/home2` 播种基线） | `UserDefaults["orgFollowedOrgs"]`（JSON 字符串） | 无 TTL |
| 第五推送通道（`NotificationManager.swift:761`） | `/dept/home2` ×关注机构（≤10） | `notifiedOrgArticleIds` + `UserDefaults["orgFollowBaselineEstablished"]` | 无 TTL（去重集持久） |

### 8.3 缓存层级总览（新→旧）

```
内存 @State（sections / pager / pagerCache / portalStats）          ← 会话级，切页丢失
  └─ OrgHomeCache（内存 dictionary，1800s，siteKey 键）              ← 仅门户预取写入
      └─ ArticleDetailCache（NSCache，300s，siteId_articleId 键）    ← 文章详情
          └─ searchQueryCache（静态字典 + NSLock，600s，≤20）
              └─ UserDefaults: orgSearchIndexCache / schoolOrgTreeCache（1800s）
                  └─ UserDefaults: organizationCache（机构清单，定时 1800s 刷新）
                      └─ staticData（35 条编译期常量，最终兜底）
```
> 注：`searchQueryCache` 为进程内静态存储（`OrganizationView.swift:1867`），与 UserDefaults 层不同源，仅列在同一「降级阶梯」中便于理解。

---

## 9. 阶段升级对照：01 报告根因 → 现状（**修/未修实测**）

| # | 01 报告根因（`01-现状与根因分析报告.md` §5.2） | 现状（本次读码） | 判定 |
|---|---|---|---|
| 1 | `/dept/home2` 每板块恒 8 条 + enrich 阈值 `>= 10` 恒不触发 + 无「查看更多」 | 新增「栏目全量分页链路」：`applyColumnIndex`(1660) → `selectColumn`(1686) → `loadPage`(1730，40/页，total 驱动，逐栏翻到底)；`enrichSectionsWithMoreArticles` 标注废弃且**零调用**（2726-2730） | ✅ **已修**（换链路，非改阈值） |
| 2 | 无「查看更多/进入完整栏目」入口；nav 菜单型栏目整体未渲染 | 栏目 chips（`columnChipsSection` 1373）+ 玻璃吸顶 + 每栏真实篇数 + 触底自动加载 + 「加载更多」兜底按钮（1578） | ✅ **已修** |
| 3 | 缺「完整栏目标签 + 分页」浏览链路 | `OrgPagerState` + `OrgPagerState.pageSize=40` + `isExhausted`/`hasMore` 真值判定 + 进度行「已显示 X / Y」 | ✅ **已修** |
| 4 | 6 个学院型未接 `/college/home` | **仍未接**，但依据 2026-09-30 实测改为统一 `/dept/home2`（`OrgContentIndex.swift:11-13` 注释：`/college/home` 对全部学院站 nav 为空） | ⚠️ **以「不接入」结案**（结论已修订，非遗漏） |
| 5 | 9~10 个单文章型机构未接 `article_id`，打开即降级 | `OrgSingleArticleResolver`（`OrgContentIndex.swift:395-410`）+ `resolveSingleArticle`(1852) + `singleArticleCard`(1617) | ✅ **已修** |
| 6 | `DeptArticleDTO` 未解析 `create_time` | 本次未核对 `NetworkService` 解码层（属数据与网络子代理范围） | ❓ **未验证** |
| 7 | 静态数据多出 `wlzx`（官网 34 条 vs App 35 条） | `staticData` 仍 35 条、仍含 `wlzx`（`OrganizationManager.swift:174`） | ❌ **未修**（数据维护项） |
| 附 | columnId 硬编码 | 主链路已运行时解析；残留 3 处硬编码 column_id + 1 处硬编码 site_id（见 §2.5） | ⚠️ **部分修复** |
| 附 | 「预取与详情共用同一缓存键」「其余机构统计回填」 | 详情页不读写 `OrgHomeCache`（见 §3.4） | ❌ **未落地**（设计稿承诺 vs 实现偏差） |

**阶段二/三新增能力（01 报告未覆盖，本次实测）**：`OrgTheme` 青金书院令牌、Bento 焦点区、玻璃吸顶 8pt 阈值、`OrgHaptics` 八档词表、push+zoom 连续转场、看图桥（JS 消息桥 + 载荷式查看器）、已读接入、关注制推送第五通道、`OrgFollowStore` + `OrgFollowArticleScanner`、`OrgContentIndex` 的纯函数层（可离线单测）。

---

## 10. 未验证 / 存疑清单（**必须标注的点**）

| # | 项 | 原因 | 建议核实方式 |
|---|---|---|---|
| 1 | 178 个栏目 | 源码无该常量，需联网枚举 22 站 `home2.nav` | 复跑 `.trae` 摸查脚本或 `curl /dept/home2?site_key=<22 站>` 后按 `OrgColumnIndexBuilder.build` 规则计数 |
| 2 | 20 个端点 | 属摸查文档口径（含非机构端点）；本次已核实**模块自用 7 条** | 已给出 7 条精确清单（§8.1），如需 20 条总数请引用 `qin/docs/departments-api-inventory.md` §1 |
| 3 | 34 个机构 | 与源码 35 条冲突（多 `wlzx`） | 以 `/school/org` 实测叶子数为准；或确认是否清理 `staticData` |
| 4 | `OrgColumnKind.classify` 注释里的 52 个 home2 响应 componentType 分布（30-32） | 注释口径，未联网复算 | 复用 `qin/docs/departments-api-evidence/raw/home2_*.json`（22 份）+ 其余 30 份响应统计 |
| 5 | 「七分区布局」 | 源码/设计稿均无此命名（设计稿仅 5 层） | 已在 §3.2 给出实测 7 区块，建议 Wiki 采用可验证口径 |
| 6 | `OrgHaptics.warning()` 「弱网降级提示」 | 定义存在但**零调用点**（实测 `grep`） | 需确认是设计遗留还是待接入 |
| 7 | `refreshWithDebounce` 的「冷却期」 | 函数体无冷却、且零调用点 | 需确认是否应删除或补实现 |
| 8 | `DeptArticleDTO` 是否补 `create_time`（01 报告根因 6） | 越界（数据与网络子代理） | 由数据与网络分析交叉核对 `NetworkService.swift:1510-1524` 附近 |
| 9 | 看图查看器 `FullScreenImageView` / `SJZImageViewerGeometry` / `SJZImageGalleryPayload` 的**逐行实现** | 位于 `TabBar.swift`（应用外壳子代理范围）；本文只记录机构模块**桥接面**与几何纯函数签名 | 由应用外壳分析补全，或 Wiki 交叉引用 |
| 10 | 关注深链回跳（`pendingOrgArticleDeepLink` 消费）的完整路径 | 位于 `TabBar.swift:39/82-103/288/325/398-401` | 由应用外壳分析补全 |
| 11 | 单文章型机构「11 个」的精确名单 | 注释口径（`OrgContentIndex.swift:388`）；本次未联网核对 `/school/org` | 用 `qin/docs/departments-api-evidence/leaves.json` 复算 `article_id != nil` 的叶子数 |
| 12 | 「振动分级 20 处调用」是否有新增遗漏 | 已用 `grep -rn "OrgHaptics\."` 全仓枚举（20 处） | 若其他文件新增调用需重跑 grep |

---

## 11. 附：关键行号速查（供 Wiki 交叉引用）

**OrganizationManager.swift**：`staticData` 130-175 ｜ `refresh` 229-240 ｜ `refreshWithDebounce`（死代码）244-246 ｜ `updateSiteKeys` 251-384 ｜ `normalizeDeptName` 387-394 ｜ `syncFromAPI` 398-512 ｜ `validateFromPageHTML` 515-568 ｜ `extractDepartmentNames` 571-608 ｜ `extractSiteKey` 613-620 ｜ `saveCache` 624-639 ｜ `loadCache` 642-682 ｜ `clearCache` 685-694 ｜ `startAutoRefresh` 698-717。

**OrganizationView.swift**：`body` 250-379 ｜ `filteredDepartments` 194-229 ｜ `contentView` 427-507 ｜ `categoryFilterChips` 582-627 ｜ `orgHeroSection` 920-937 ｜ `focusBenchSection` 941-973 ｜ `focusHeroCard` 976-1034 ｜ `categorySection` 1077-1108 ｜ `followBadge` 1199-1207 ｜ `cachedStatText` 1264-1271 ｜ `performArticleSearch` 1908-2111 ｜ `searchOrganizationArticles` 2161-2240 ｜ `fetchOrgArticles` 2246-2325 ｜ `makeOrgResult` 2328-2366 ｜ `searchArticleTypeOrgs` 2394-2468。

**OrganizationDetailView.swift**：`resolveMainSiteSearchColumns` 171-194 ｜ `body`(机构) 279-395 ｜ `enhancedFallbackView` 449-816 ｜ `loadFallbackArticles` 817-900 ｜ `toggleFollow` 1058-1079 ｜ `contentView` 1170-1220 ｜ `headerStatText` 1277-1288 ｜ `columnChip` 1399-1430 ｜ `columnArticlesSection` 1435-1460 ｜ `applyColumnIndex` 1660-1677 ｜ `selectColumn` 1686-1726 ｜ `loadPage` 1730-1833 ｜ `loadMoreIfNeeded` 1836-1848 ｜ `resolveSingleArticle` 1852-1876 ｜ `loadData` 2177-2426 ｜ `parseSections` 2430-2576 ｜ `enrichSectionsWithMoreArticles`（废弃）2730-2846 ｜ `openWebImageGallery` 3149-3165 ｜ `readKey`/已读 3084-3090 ｜ `loadArticleDetail` 3731-4136 ｜ `fetchArticleDetailWithFallback` 4465-4628 ｜ `withTimeout` 4746-4769 ｜ 消息桥 5380-5393 ｜ 链接拦截 5397-5409。

**OrgContentIndex.swift**：`classify` 33-44 ｜ `build` 93-192 ｜ `defaultColumn` 195-201 ｜ `OrgRequestGate` 208-249 ｜ `OrgGalleryPayloadBuilder.make` 265-282 ｜ `OrgMediaProbe` 289-296 ｜ `OrgPagerState` 302-384 ｜ `OrgSingleArticleResolver` 397-410 ｜ `PortalStats` 415-420 ｜ `OrgHomeCache` 424-509。

---

*草稿结束。本文件所有行号均为 2026 年本次会话 grep/read 实测；参考文档结论均已标注来源与核实状态。*
