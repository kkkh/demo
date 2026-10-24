# F. 内容型功能模块深度分析（Code Wiki 草稿）

> 分析范围：`qin/DesignCode/` 下 9 个文件，共 **12665 行**（`wc -l` 实测）。
> 所有行号均来自 `grep -n` / `read` 实测，未使用推测值。
> 本文只覆盖分配到的 9 个文件；TabBar.swift 仅在「入口来源 / 锚点体系」处作为**只读引用**，其内部结构由应用外壳专题负责。

## 0. 规模与定位速查

| 文件 | 实测行数 | 角色 | 存储中枢 | 磁盘持久化 | 网络 |
|---|---|---|---|---|---|
| `SchoolProfileView.swift` | 3559 | 学校概况 7 分区页 + Store + 图集/合作详情 + 保存分享基础设施 | `SchoolProfileStore` (L175) | 仅搜索历史 | ✅ 5 类端点 |
| `PartySubjectView.swift` | 2606 | 党建专题两站聚合 + 正则 HTML 解析 + 两段式全文 | `PartySubjectStore` (L59) | 仅搜索历史 | ✅ 4 类端点 |
| `PrincipalMailboxView.swift` | 1788 | 校长信箱（只读信件 + 校方回复） | `PrincipalMailboxStore` (L23) | 新增基线 + 搜索历史 | ✅ 2 类端点 |
| `CampusCalendarView.swift` | 1494 | 校园日历原生列表 + 校历详情 | 复用 `CampusCalendarStore` | — | — |
| `CampusCalendarStore.swift` | 478 | 校园日历数据中枢（唯一带**列表离线缓存**的模块） | `CampusCalendarStore` (L17) | 列表缓存 + 历史 + 已读 | ✅ 2 类端点 |
| `HelpGuideView.swift` | 1552 | 使用帮助中心 + 文章详情 + 三招行动面板 | 复用 `HelpGuideStore` | — | ❌ 纯静态 |
| `HelpGuideStore.swift` | 239 | 帮助搜索 / 已读 / 最近阅读 / 搜索历史 | `HelpGuideStore` (L24) | 已读 + 历史 + 最近 | ❌ |
| `HelpContent.swift` | 593 | 内置内容目录（5 分类 / 32 篇 / 纯静态） | `HelpCatalog` (L57) | — | ❌ |
| `HomeModuleManager.swift` | 356 | 首页模块可见性与顺序管理 | `HomeModuleManager` (L124) | 顺序 + 隐藏集合 | ❌ |

九个文件形成一条清晰的能力梯度：

- **最重**：SchoolProfileView（3559 行，单文件内含 4 个页面级 View + 1 个 Store + 2 套预热管线 + 保存分享基础设施）。
- **最自洽**：CampusCalendar Store/View（唯一实现「缓存优先 → 静默刷新」双通道 + 列表落盘）。
- **最轻**：HelpContent（零网络、零异步，唯一内容事实源）。
- **最跨界**：HomeModuleManager（唯一 `@MainActor` 标注在**存储属性级**的管理器，且反向依赖 4 个业务 Store 取数）。

---

## 1. SchoolProfileView.swift（3559 行）

### 1.1 完整顶层类型清单（16 项，`grep -nE '^(modifiers)*(struct|class|enum|…)'` 实测）

| 行号 | 声明 | 说明 |
|---|---|---|
| 23 | `struct SJZScrollOffsetKey: PreferenceKey` | 滚动偏移 PreferenceKey，`defaultValue = 0` (L24) |
| 31 | `struct SJZScrollActivityTracker: ViewModifier` | 滚动方向追踪，`handleOffsetChange` (L53)；**党建专题共用**（PartySubjectView.swift L54 注释明示） |
| 72 | `enum SJZIdleTimerRepair` | iOS 27 Beta 手势会话结束后空闲计时器卡死修复，`reassert(logTag:)` (L73) |
| 85 | `struct SJZIdleTimerRepairOnScrollStop: ViewModifier` | 滚动停止时机接入修复 (L88) |
| 101 | `enum SchoolProfileAssets` | 官网静态素材 URL 表（内容哈希硬编码） |
| 144 | `struct ProfileSearchEntry: Identifiable` | 六类内容统一搜索模型（id/kind/kindIcon/title/detail/imageURL） |
| 154 | `struct CooperateEntry: Identifiable` | 合作交流条目，`id = "分组\|文章ID"`；`dateText` (L167) |
| **175** | **`final class SchoolProfileStore: ObservableObject`** | 数据中枢（`@MainActor`，L174） |
| 855 | `struct SchoolProfileView: View` | 主页面 |
| 2443 | `struct ProfileInlineVideo: View` | 轻量 AVKit 播放器（出现即播、离开即停，L2441 注释） |
| 2467 | `struct RollingNumberView: View` | 学校简介统计数字滚动，`formatted` (L2502) |
| 2511 | `struct ProfileTextDetailView: View` | 领导/文字详情（图文），保存/分享 L2631/L2640 |
| 2662 | `struct ProfileFullScreenImage: Identifiable` | 全屏图片载体 |
| 2674 | `enum ProfileImageSaveShare` | 系统级保存/分享基础设施（相册写权限 + UIActivityViewController） |
| 2808 | `struct ProfileAlbumView: View` | 校园风光图集画廊（轮播 + 网格 + 全屏） |
| 3176 | `struct ProfileCooperateDetailView: View` | 合作交流图文详情（分组徽章 + 封面 + 正文 + 图集） |

**嵌套类型**：`SchoolProfileStore.RefreshStatus` (L178)、`SchoolProfileStore.AlbumsPreheat` (L204)、`SchoolProfileView.Tab` (L858)。

### 1.2 SchoolProfileStore 职责与状态

- **单例形态**：`static let shared = SchoolProfileStore()`（L176），`@MainActor final class`（L174）。全 App 唯一实例，`SchoolProfileView` 用 `@ObservedObject`（L856）而非 `@StateObject`。
- **日志域**：`profile`（主链路）+ `collaboration`（合作交流容错链路）。

**@Published 字段（18 项）**

| 行号 | 字段 | 语义 |
|---|---|---|
| 186 | `statItems: [(text: String, number: Int)]` | 简介统计数字（注意：元组数组，**不满足 Equatable**） |
| 188 | `textSections: [ProfileSearchEntry]` | 简介/学科竞赛/办学特色文字区块 |
| 190 | `leaders` | 现任领导 |
| 192 | `sceneryArticles: [OrgArticle]` | 校园风光列表（复用 `OrgArticle` 以复用图片缓存组件，L191 注释） |
| 194 | `sceneryAlbums: [String: SceneryAlbumDetail]` | 风光图集详情缓存（articleId → 完整图集） |
| 196 | `albumsPreheat: AlbumsPreheat` | 风光预热状态 |
| 198 | `cooperateEntries` | 合作交流合并条目 |
| 200 | `cooperateDetails: [String: SceneryAlbumDetail]` | 校企合作详情缓存 |
| 202 | `cooperatePreheat` | 合作详情预热状态 |
| 210 / 211 | `promoVideoURL` / `songVideoURL` | 宣传片 / 校歌（运行时解析，静态素材兜底） |
| 212 / 213 | `markLogoURL` / `introBannerURL` | 默认值直接取 `SchoolProfileAssets` 静态常量 |
| 215–219 | `isLoading` / `hasLoaded` / `lastError` / `refreshStatus` / `lastRefreshDate` | 通用加载态 |

**非发布内部状态**：`loadTask` (L221)、`refreshInFlight` (L222)、`cacheGeneration` (L224)。

**常量**

| 行号 | 值 | 说明 |
|---|---|---|
| 226 | `sceneryColumnId = "214e6c2b44984c87831d4e96eba11793"` | 校园风光栏目 |
| 227 | `scenerySiteId = "1"` | |
| 229 | `cooperationColumnId = "cc7376c390cb4aa4bc519c4858009630"` | 校企合作栏目（官网 /school/cooperate 同源，L228 注释） |
| 230 | `cooperationSiteId = "1"` | |

### 1.3 持久化键与路径

| 键 / 路径 | 位置 | 类型 |
|---|---|---|
| `"profileSearchHistory"` | L900（读）、L1292（清空）、L2431（写） | `[String]`，硬编码字符串×3 |

> ⚠️ **本模块没有任何列表/详情磁盘缓存**。冷启动完全依赖网络；离线时 `silentLoad` 只落 `lastError`（L391），首屏渲染错误卡（`errorCard`，L2198）。与 CampusCalendarStore 的离线策略不一致。**缓存键**：内存 `sceneryAlbums` / `cooperateDetails` 字典，键为 `articleId`。

### 1.4 关键方法签名（含行为）

**拉取控制**

| 行号 | 签名 | 行为 |
|---|---|---|
| 273 | `func loadIfNeeded(force: Bool = false)` | 懒加载；`hasLoaded && !force` 直接返回；`loadTask != nil` 记 debug 日志跳过（L276） |
| 282 | `func refreshDetached(source: String) async` | 下拉刷新专用句柄：本体放独立 `Task`，规避 `.refreshable` 手势收回取消导致的 `URLError.cancelled` 误报 |
| 287 | `func refresh(source: String) async` | 手动刷新 = 与官网完全同步：`refreshInFlight` 防重入 → 取消在途 `loadTask` → **`cacheGeneration += 1` + `sceneryAlbums.removeAll()` + `cooperateDetails.removeAll()`**（L306–308）→ `performFullFetch`；`URLError.cancelled` 归为 `.idle` 不展示失败横幅（L318–320） |
| 331 | `func dismissRefreshBanner()` | 非 `.refreshing` 时置 `.idle` |

**核心拉取（`private func performFullFetch() async throws`，L402）** — 六段串行：

1. **L404** `NetworkService.shared.fetchJSONDict(path: "/school/intro")`，`root["data"]` 缺失抛 `NetworkError.decodeFailed("学校概况响应结构异常")` (L406)。
2. **L412–447 学校简介**：`school-introduction.statistics.dynamicDigit.list[]` → `statItems`（`endNumber` 兼容 `String` 与 `NSNumber` 两种类型，L419–422）；`compete` 单块 (L430) + `features` 多子块字典 (L435) → `textSections`（`parseSection`，L817）。注：`if !sections.isEmpty { textSections = sections }`（L443）——**空结果保留旧值**。
3. **L449–471 现任领导**：`current-leader.data.list[]`，`title = "\(name) · \(position)"`，id 优先 `NSNumber` 行 id 否则用姓名 (L459–460)。
4. **L473–485 视频**：`campus-promotion-video.data.videoSrc.href` → `promoVideoURL`；`school-song` 同构 → `songVideoURL`。
5. **L487–511 校园风光**：`fetchArticles(columnId: sceneryColumnId, page: 1…4, size: 50)`，`list.count < 50 || scenery.count >= total` 提前 break（上限 4 页）。
6. **L514–519**：风光非空则 `Task { await preheatSceneryAlbums() }` 异步预热；随后 `await fetchCooperations()`。

| 行号 | 签名 | 行为 |
|---|---|---|
| 525 | `func loadSceneryAlbum(articleId: String, title: String) async -> SceneryAlbumDetail?` | 内存缓存优先；未命中 `fetchSceneryAlbumDetail(articleId:siteId:)` 后回填；失败仅 warning 并返回 nil（**不抛错**） |
| 555 | `func preheatSceneryAlbums() async` | 预热全部风光图集：`.preheating` 防重入；`pending` 过滤已缓存；**`stride(by: 4)` + `withTaskGroup` 分批（并发 ≤4，L571 注释：避免一次性 10+ 请求压学校服务器）**；每次写回前校验 `generation == cacheGeneration`（L593）；末尾再校验一次，不一致则整体作废（L604–607） |
| 623 | `private func fetchCooperations() async` | 三段式：① `fetchJSONDict(path: "/school/cooperate")` 取分组骨架；`title_en == "cooperation"` 的组**跳过内嵌列表**（仅 8/19 条，L642–643）；国际交流/继续教育 `content` 内联全文（`strippingHTMLTags()`）标 `needsDetailFetch = false`；② 校企合作走 `fetchArticles(cooperationColumnId, page 1…6, size 8)` 全量（服务端 total=19）；③ `Task { await preheatCooperationDetails(pending:) }`。**整体失败仅 warning 并 `return`，保留上次数据**（L705–712） |
| 724 | `func preheatCooperationDetails(pending: [CooperateEntry]?) async` | 同风光预热结构（并发 ≤4 + 代际校验） |
| 785 | `func loadCooperateDetail(articleId: String, title: String) async -> SceneryAlbumDetail?` | 内存缓存优先；未命中 `fetchSceneryAlbumDetail`；失败 warning 返回 nil |
| 817 | `private static func parseSection(_ block:key:kind:icon:) -> ProfileSearchEntry?` | `title` + `article.text`（优先 `article.title` 覆盖），`imgSrc` 经 `introAssetURL` |
| 842 | `private static func introAssetURL(for key: String) -> String?` | 4 个图片键 → `SchoolProfileAssets`；未知键返回 nil |

**搜索（L339 `func localSearch(keyword: String) -> [ProfileSearchEntry]`）**

- 分词：`split(whereSeparator: { $0 == " " || $0 == "　" })`（**显式兼容全角空格**，L340），逐词 `lowercased()`。
- **AND 语义**：`guard matched == terms.count, score > 0`（L359）。
- 权重：标题 `+5`、`detail` `+2`、`kind` `+1`（L354–356）；同分按 `title` 升序（L363）。
- 语料 = `allEntries`（L233）= `textSections + leaders + sceneryEntries + cooperateSearchEntries`。
- **搜索结果全文由预热增强**：`sceneryEntries` (L237) 把 `sceneryAlbums[id]?.plainText` 并入 `detail`；`cooperateSearchEntries` (L253) 并入 `cooperateDetails[id]?.plainText` —— 即「预热完成度决定搜索召回率」。

### 1.5 View 层结构

**页面骨架（`body` L919）**

```
ScrollView
└─ VStack(spacing: 14)
   ├─ heroCard              L1111 ① 主题头卡（蓝金学术风）
   ├─ tabBar                L1180 ② 板块切换（7 个 Tab）
   ├─ searchSection         L1221 ③ 搜索区（含 searchHistoryChips L1266）
   └─ isSearching ?
        ├─ searchStatusBar  L2044 + searchContent L2064 ④-search
        └─ tabContent       L1306 ④-content
```

- `.coordinateSpace(name: "profileScroll")` (L935) + `SJZScrollActivityTracker` (L936) 记滑动方向日志。
- `.modifier(SJZIdleTimerRepairOnScrollStop())` (L945)；`.scrollDismissesKeyboard(.interactively)` (L944)。
- 顶部 overlay：`refreshBanner` (L2244) + `syncProgressCapsule` (L2228)，`zIndex(9)`，`.animation(.spring(0.4/0.8), value: store.refreshStatus)` (L961)。
- `.refreshable { await store.refreshDetached(source: "下拉刷新") }` (L962)；`.task { store.loadIfNeeded() }` (L1003)。

**7 个分区（`private enum Tab` L858–865）**

| Tab | 内容区行号 | 结构要点 |
|---|---|---|
| 学校简介 `introduction` | L1326 | `RollingNumberView` 数字滚动 (L2467) + `sectionCard` (L1354) 渲染 `textSections` |
| 现任领导 `leaders` | L1401 | 2 列 `LazyVGrid`，圆形头像 `74×74` + 金边；`title` 以 `·` 拆名/职（L1434/L1438）→ 点击 `selectedLeader` sheet → `ProfileTextDetailView` |
| 识别系统 `identification` | L1458 | 校徽大图 (`scaledToFit` h=180) + `contextMenu` 保存/分享 (L1479) + 校名横/竖排各 4 图 `identificationImageGrid` (L1529) + **标志释义文案硬编码在 View** (L1512–L1519) |
| 学校宣传片 `promo` / 校歌 `song` | L1577 `videoTab(url:poster:title:logLabel:)` | `ProfileInlineVideo`（AVKit，出现即播、离开即停） |
| 校园风光 `scenery` | L1631 | 2 列网格；**图集张数角标实时显数**（`store.sceneryAlbums[id]?.images.count`，L1687），未预热时退化为 `photo.stack.fill` 图标 (L1694) → 点击 `selectedSceneryAlbum` → `ProfileAlbumView` |
| 合作交流 `cooperate` | L1727 | `cooperateGrouped` (L1717) 按 `groupTitle` 分组；固定顺序 `cooperateGroupOrder = ["国际交流", "继续教育", "校企合作"]` (L1715)；`cooperateGroupCard` (L1762) + `cooperateItemCard` (L1833)；预热进度 `cooperatePreheatDoneCount` (L1722)；分组视觉辅助 `cooperateGroupIcon` (L1966) / `cooperateGroupColors` (L1974) / `cooperateGroupEnglish` (L1982) |

**导航关系（全部由主页面发起）**

| 载体 | 行号 | 目标 |
|---|---|---|
| `.sheet(item: $selectedLeader)` | L965 | `NavigationStack { ProfileTextDetailView }` + `.sjzPresentationChrome()` |
| `.sheet(item: $selectedSceneryAlbum)` | L971 | `ProfileAlbumView` |
| `.sheet(item: $selectedCooperate)` | L977 | `ProfileCooperateDetailView` |
| `.fullScreenCover(item: $fullScreenImage)` | L983 | `FullScreenImageView`（**定义在 TabBar.swift，非本文件**） |
| `.sheet(isPresented: $showShareSheet)` | L987 | `ShareSheet`（同上，外部定义） |

**子页面细节**

- `ProfileAlbumView`（L2808）：`imageURLs` (L2822) → `loadAlbum()` (L2876，先查 `store.sceneryAlbums` 再走 `loadSceneryAlbum`) → `headerCard` (L2903) / `carouselCard` (L2933，主图 `fit` 全貌) / `gridCard` (L3011，全部图片网格) / `textCard` (L3071) / `albumSkeleton` (L3095) / `albumErrorCard` (L3110)；单项 `save` (L3136) / `share` (L3147) / `presentToast` (L3158)。
- `ProfileCooperateDetailView`（L3176）：`coverURL` (L3189) / `galleryURLs` (L3196) / `bodyText` (L3200) / `groupIcon` (L3204)；`loadDetailIfNeeded()` (L3462) 优先 `store.cooperateDetails`；布局 `headerCard` (L3280) / `coverSection` (L3321) / `textCard` (L3366) / `galleryCard` (L3390，正文内嵌图 3 列网格) / `footerHint` (L3452)。
- `ProfileImageSaveShare`（L2674）：**独立 `URLSession`**（L2677）显式注册 `RefererHeaderURLProtocol` 防盗链，超时 30s/60s；`safeURL` (L2686，非 ASCII 百分号编码)、`downloadImageData` (L2693)、`saveToPhotos` (L2709，返回错误文案或 nil)、`prepareShareItems` (L2790)。

**图片加载方式（统一组件，非 AsyncImage）**

全模块 **0 处 `AsyncImage`**（`grep -c` 实测为 0）。所有图片走 `SJZCachedImage`（定义在 `TabBar.swift` L12107 附近，与 `SJZImagePhase` L12077 同构 AsyncImage 三态 + `skipped` 无图模式）：

```swift
SJZCachedImage(url: url) { phase in
    if case .success(let image) = phase { image.resizable().scaledToFill() }
    else { /* 统一优雅占位 */ }
}
```

用于：识别系统网格 (L1535)、领导头像 (L1415)、风光封面 (L1661)、详情页图片等。`DesignCodeApp.swift:24` 注释说明协议层转发会话、统一图片组件与 AsyncImage 共享同一缓存。

**动效与交互要点**

| 交互 | 行号 | 说明 |
|---|---|---|
| 触觉反馈 | 各点击分支 | `UIImpactFeedbackGenerator(style: .light).impactOccurred()` |
| 长按菜单 | L1479 等 | 「保存图片」→ `saveImageAndToast` (L1993) / 「分享…」→ `shareImage` (L2002) |
| Toast | L2032 `presentSaveToast` | 顶部胶囊，`saveToastTask` 防抖 |
| 底部 sentinel | L2352 | `bottomSentinel` + `lastBottomLogTime` 节流记录触底 |
| 搜索高亮 | L2369 `highlightedText` / L2385 `profileHighlighted` | `AttributedString` 双域着色 |
| 搜索防抖 | L2405 `handleSearchChange` | 500ms 仅用于**日志**（结果实时计算，L2413 起） |
| 搜索提交 | L2425 `commitSearch` | 去重置顶 + 上限 10 + 落盘 `profileSearchHistory` |
| 空闲计时器修复 | L72–97 | iOS 27 Beta 手势会话卡死兼容（见 §1.7） |

### 1.6 消费的 NetworkService 端点与模型

| 端点 | 调用行号 | 返回模型 |
|---|---|---|
| `fetchJSONDict(path: "/school/intro")` | 404 | `[String: Any]`（**动态结构直解析，规避动态 DTO**，L403 注释） |
| `fetchJSONDict(path: "/school/cooperate")` | 629 | `[String: Any]` |
| `fetchArticles(columnId:siteId:page:size:)` | 491（风光，size 50）、668（校企合作，size 8） | `ColumnDTO` → `articles.list[]` |
| `fetchSceneryAlbumDetail(articleId:siteId:)` | 535、580、748、797 | `NetworkService.SceneryAlbumDetail`（`articleId` / `title` / `plainText` / `images: [ImageDTO]`，NetworkService.swift L1154） |

用到的模型：`OrgArticle`（app 自有）、`NetworkService.ArticleDTO`、`NetworkService.SceneryAlbumDetail`、`NetworkError.decodeFailed`。
`fetchSceneryAlbumDetail` 内部复用 `/common/article/detail` 并从 content 提图，**content 无图时回退封面单图**（NetworkService.swift L1163–1172）——因此风光「图集」实际至少 1 图。

### 1.7 模块间依赖

**谁调用它**

| 调用方 | 位置 | 用途 |
|---|---|---|
| HomeModuleManager | `HomeModuleManager.swift:102` | `SchoolProfileStore.shared.allEntries.count` 作为 `.schoolProfile` 的 `dataCount` |
| HomeView 首页入口卡 | `TabBar.swift:1413–1484` | `NavigationLink { SchoolProfileView() }`（L1415）；`sectionHeader` 计数 L1241；领导姓名预览 L1438；`.task { loadIfNeeded() }` L1484 |
| 通知深链 sheet | `TabBar.swift:361–378` | 通知点击后 `showSchoolProfileSheet` → `NavigationStack { SchoolProfileView() + 关闭按钮 }`（L364） |
| 日志域 | `profile` | 「我的-应用日志」可按域追溯 |

**它调用谁**：`NetworkService`（5 处）、`LogManager`（域 `profile` / `collaboration`）、`SJZCachedImage` / `FullScreenImageView` / `ShareSheet` / `GradientBackground` / `sjzPresentationChrome` / `displayFont` 等（均定义在 TabBar.swift 的设计系统层）、`SJZScrollActivityTracker`（**本文件定义，被 PartySubjectView 复用**）。

### 1.8 技术债与风险点

1. **静态素材 URL 硬编码内容哈希**（`SchoolProfileAssets` L101–139，`rowHash` L122 / `columnHash` L131）：官网每次重新部署（Vite 构建产物哈希变化）全部 url 失效，L99 注释自认「官网重新部署后需同步核对」→ **无运行时兜底，无远端下发机制**。
2. **零离线缓存**：与 CampusCalendarStore 形成鲜明反差；断网冷启动 = 错误卡 + 空白（`silentLoad` L386–396 仅记 `lastError`）。
3. **搜索历史 Key 硬编码三处**（L900 / L1292 / L2431），未抽常量，改名易漏改。
4. **合作交流分组语义半硬编码**：`groupTitle == "校企合作"` 与 `groupKey == "cooperation"` 在 L643 / L677 / L715 与展示顺序 L1715 之间靠字符串耦合；官网改分组名即断链。
5. **`statItems` 为元组数组**（L186）：无法 `Equatable`，直接影响 SwiftUI diff 效率与测试可断言性。
6. **识别系统文案硬编码在 View**（L1512–L1519）而非内容层，与 HelpContent 的「内容集中」范式不一致。
7. **`textSections` 空值保护**（L443）导致「官网清空简介区块」时 UI 显示旧数据，刷新语义不彻底。
8. **预热并发固定 4 且串行分批**（L572 / L740）：19 条校企合作详情需 5 批串行；弱网下「详情秒开」承诺可能不成立。代际校验（L593/L604、L761/L772）是正确设计，但**只覆盖手动刷新**，无法感知官网单篇更新。
9. **无 TODO/FIXME/⚠️ 标记**：`grep -nE 'TODO|FIXME|⚠️|XXX|HACK'` 在本文件命中 0（全仓仅 PartySubjectView L394、PrincipalMailboxView L1709、HelpGuideView L1149 三处中文「踩坑/注意」类注释）。风险全部写在描述性注释里（如 L303–305 手动刷新语义、L571 并发上限理由）。

---

## 2. PartySubjectView.swift（2606 行）

### 2.1 完整顶层类型清单（11 项）

| 行号 | 声明 | 说明 |
|---|---|---|
| 22 | `struct PartyColumnInfo: Identifiable, Hashable` | 栏目（id/title/total） |
| 29 | `struct PartySiteState: Identifiable` | 站点状态（key/name/siteId/columns/totalArticles/articlesByColumn） |
| 41 | `struct PartyArticleRef: Identifiable` | 文章条目 + 来源信息（siteKey/siteName/columnName/siteId），`dateText` L49 |
| **59** | **`final class PartySubjectStore: ObservableObject`** | 数据中枢（`@MainActor` L58） |
| 498 | `struct PartySubjectView: View` | 主页面 |
| 1640 | `enum PartyRichBlock: Identifiable` | 图文混排块（`.paragraph(Int, String)` / `.image(Int, URL, alt:)`） |
| 1653 | `struct PartyParseOutcome` | 解析输出（blocks + deadImageCount） |
| 1660 | `enum PartyContentParser` | 纯正则 HTML → 混排块 |
| 1765 | `final class PartyArticleDetailCache: @unchecked Sendable` | 两段式详情内存缓存（5 分钟 TTL） |
| 1810 | `struct PartyArticleDetailView: View` | 文章详情 |
| 2603 | `struct PartyFullScreenPayload: Identifiable` | 全屏图片载体 |

**嵌套类型**：`PartySubjectStore.RefreshStatus` (L75)、`PartyArticleDetailCache.Entry` (L1768，`fileprivate`)、`PartyArticleDetailView.LoadPhase` (L1817)。

### 2.2 PartySubjectStore 职责与状态

- **单例**：`static let shared`（L60），`@MainActor`。日志域 `party`。
- **站点配置**（L63–66）：`[("djgz", "党建工作"), ("mkszy", "思政专题")]` —— 注释明示「服务端栏目结构与 ID 会变更，**运行时解析**」。
- **覆盖上限**：`regularLimit = 200`（4 页 × 50，L69）、`deepLimit = 400`（8 页 × 50，L71）、`pageSize = 50`（L72）。

**@Published（8 项）**：`sites` (L82)、`isLoading` (L83)、`hasLoaded` (L84)、`lastError` (L85)、`syncProgressText` (L87)、`refreshStatus` (L88)、`lastRefreshDate` (L89)、`skippedColumnsCount` (L98)。

**非发布内部状态**：`loadTask` (L91)、`refreshInFlight` (L92)、`unavailableColumnIds: Set<String>` (L96) —— **会话级不可用栏目记忆**（L94–95 注释：官网「首页」容器栏稳定返回业务 500 `code=500, data=null`，记录后刷新跳过，避免重复无效请求）。

**持久化**：Store **无任何 UserDefaults**；唯一落盘键 `"partySearchHistory"` 在 View 层（L515 读 / L957 清 / L1627 写）。**无磁盘缓存** → 冷启动必然全量网络。

### 2.3 关键方法签名

| 行号 | 签名 | 行为 |
|---|---|---|
| 107 | `func site(_ key: String) -> PartySiteState?` | 按 key 取站点 |
| 112 | `func aggregatedArticles(siteKey: String) -> [PartyArticleRef]` | 跨栏目聚合后按 `updateTime` 倒序（浏览「全部」与本地搜索共用） |
| 135 | `func localSearch(keyword: String) -> [PartyArticleRef]` | 多词 AND；权重 标题 5 / 描述 2 / 标签 1（L154–156）；`guard matchedTerms == terms.count`（L160）；排序 分数↓ → `updateTime`↓（L173–176） |
| 181 | `func searchHitDistribution(keyword: String) -> [(siteName: String, count: Int)]` | 两站命中分布，按 `siteConfigs` 顺序过滤 0 值（L188–190） |
| 196 | `func loadIfNeeded(force: Bool = false)` | 懒加载，`loadTask` 防重入 |
| 206 | `func refreshDetached(source: String) async` | 独立 Task，与信箱同款方案（L205 注释） |
| 212 | `func refresh(source: String) async` | 必定真实全量拉取（`regularLimit`）；`URLError.cancelled` 不计失败 |
| 253 | `func deepSearchSupplement(keyword: String, onComplete: @escaping ([PartyArticleRef]) -> Void) async` | **深度搜索**：以 `deepLimit = 400` 重跑 `performFullFetch`，成功后回调 `localSearch(keyword:)`；失败也回调（降级为已缓存语料，L267） |
| 272 | `func dismissRefreshBanner()` | 同上 |
| 280 | `private func silentLoad() async` | 首载 + `syncProgressText = "正在同步党建专题数据…"` |
| 319 | `private func performFullFetch(limit: Int, progress: @escaping (String) -> Void) async throws` | 两站串行：`fetchDeptSiteIndex` → `fetchSiteArticles`；`progress` 文案「正在同步「X」文章（done/count 栏目）…」；结束后写 `sites` / `skippedColumnsCount` |
| 372 | `private func fetchSiteArticles(...) async -> (infos:articlesByColumn:grandTotal:skipped:)` | **6 路分块并发**（`stride(by: 6)`，L386）；`group.addTask` 内先 `await MainActor.run { unavailableColumnIds.contains }` 跳过已知坏栏（L395–400）；单栏失败仅 warning + 记入 `unavailableColumnIds`，`grandTotal` 不计（L409–417） |
| 439 | `private func fetchColumnArticlesTolerant(columnId:siteId:limit:) async -> (total:articles:error:)` | 栏目内分页（`pageSize 50`），`collected.count >= limit` 或 `list.count < pageSize` 或 `collected >= total` 停止；**任何错误就地捕获返回 error，绝不向上抛**（L438 注释、L481） |

### 2.4 View 层结构（`body` L563）

```
ScrollView → VStack(spacing: 14)
├─ heroCard        L765  ① 红色党建主题头卡
├─ siteTabs        L832  ② 子站切换（党建工作 / 思政专题，胶囊 + 计数徽章）
├─ searchSection   L884  ③ 搜索区
├─ isSearching → searchStatusBar  L1179 搜索模式（含两站命中分布 + 深度搜索按钮）
└─ contentSection  L968  ④ 内容区 → browseContent L987
   ├─ skippedColumnsCount > 0 时的容错提示条（L989–1002，「已自动跳过 N 个无独立文章的栏目（如站内首页容器）」）
   ├─ columnChips  栏目筛选胶囊（「全部」= nil，L505）
   └─ browseArticles（L544：指定栏目 = 该栏倒序；否则 `aggregatedArticles`）→ `articleCard` L1091
```

- 站点切换 `onChange(of: selectedSiteKey)` (L654) 会重置 `selectedColumnId = nil` (L655) 并记 info 日志。
- `onChange(of: browseArticles.count)` (L663) 记录渲染规模（debug）。
- 工具栏 `partyToolbar` (L676)：**原返回键长按菜单功能迁移至此**（L680 注释）——切换站点 / 打开官网党建页。
- 空态 / 错误 / 骨架：L1421 起；`errorCard` L1528。
- 高亮：`highlightedText` L1563 / `partyHighlighted` L1579（多词分词逐个着色）。
- 同步进度胶囊 `syncProgressCapsule`（L1295 区块）用**非对称 transition**（insertion 含 scale 0.95，removal 仅位移+透明度，L597–600）。

**文章详情（`PartyArticleDetailView` L1810）**

- 关键修复（L1805–1809 注释）：**党建工作子站列表接口的 article id 与真正承载全文的 id 不一致**，用列表 id 请求详情返回空壳（content 仅 `<p><br></p>`）；真正全文 id 藏在详情响应 `href`（`#/list/article?id=…`）。思政专题站列表 id 即全文 id，自动一段直达。
- 页面区块：微信分享载荷 `weChatSharePayload` (L1943) / `shareURL` (L1956，官网原文优先，否则用真实 id 构造) / Hero 头卡 L1966 / 加载区 L2037 / 正文图文混排 L2076 / 摘要兜底 L2228 / 失败区 L2273 / 底部操作栏 `bottomBar` L2314（「复制全文」L2361 / 「查看原文」L2378）/ Toast L2390。
- 详情加载 `loadDetail()` (L2425) 四级策略：

| 级 | 行号 | 策略 |
|---|---|---|
| 0 | L2430 | `PartyArticleDetailCache.shared.cached(key: cacheKey)` 命中直出（二开毫秒级） |
| 1 | L2450 | 一段：`fetchArticleDetail(articleId: ref.article.articleId, siteId:)`；`firstStripped.isEmpty && !firstHTML.hasImageContent` 判为空壳（L2454） |
| 2 | L2479 | 二段：`Self.realArticleID(from: href)` 提取真实 id 后重取；二次判空否则抛 `NetworkError.decodeFailed("官网全文仍为空")` |
| 3 | L2501 | 短链形态 `/s/xxx`：`resolveShortLinkFinalURL` 经 302 目标提取真实 id 再取全文 |
| 4 | L2531 | 摘要兜底：`phase = .summary`（warning 日志 `summary_fallback`） |
| — | L2539 | catch → `phase = .failed("全文获取失败，请检查网络后重试")` |

- **缓存键**：`private var cacheKey: String { "\(ref.article.articleId)|\(ref.siteId)" }`（L1847）。
- `realArticleID(from:)` (L2553)：优先 `URLComponents.queryItems["id"]`，其次 **hash 路由内嵌 query**（`#/list/article?id=xxx`，用 `URLComponents(string: "fake://x?" + fragment…)` 技巧解析，L2566–2569），最后退化为正则 `[?&#]id=([0-9a-fA-F]{16,})`（L2555）。

### 2.5 PartyContentParser（纯正则，工程红线）

| 行号 | 方法 | 行为 |
|---|---|---|
| 1663 | `private static func isPlaceholder(_:)` | `no_picture` 或 `data:` 前缀 |
| 1670 | `private static func isDeadImageSource(_:)` | Word/WPS 残留：`file:` / `data:` 前缀、`^[A-Za-z]:[\\/]` 盘符、含 `\`、**不含 `/` 的裸文件名** |
| 1680 | `static func resolvedImageURL(_:)` | `//` → 补 `https:`；`/` 开头 → 拼 `https://www.sxjzit.edu.cn`；否则 nil；末端走 `ProfileImageSaveShare.safeURL` |
| 1695 | `static func parse(html:) -> PartyParseOutcome` | 正则 `<img[^>]*src=…>` 分段；图片与段落**严格保持官网顺序**；死图/占位图剔除并 `deadImageCount += 1`；`alt` 二次正则提取（L1720）；首尾空段清理（L1738） |
| 1745 | `private static func appendTextBlocks(from:into:nextIndex:)` | `</p>` / `<br>` / `<br/>` / `<br />` → `\n` 后 `strippingHTMLTags()` 拆段 |

L1658 注释明确：**「纯正则，全项目禁止 NSAttributedString HTML 解析」**。

### 2.6 PartyArticleDetailCache

- `@unchecked Sendable` + `NSLock`（L1779），`store: [String: Entry]`（L1780）。
- TTL **300 秒**：`cached(key:)` 内 `Date().timeIntervalSince(entry.fetchedAt) > 300` 则移除并返回 nil（L1785–1788）。
- 缓存内容含 `resolvedArticleId` / `canonicalHref` —— L1763–1764 注释：二开零网络毫秒直出、避免重复二段请求。

### 2.7 消费的端点与模型

| 端点 | 行号 | 模型 |
|---|---|---|
| `fetchDeptSiteIndex(siteKey:)` | 326 | `(siteId: String, columns: [NetworkService.DeptColumnRef])`（`DeptColumnRef` = id/title，NetworkService.swift L969） |
| `fetchArticles(columnId:siteId:page:size:)` | 446 | `ColumnDTO` → `OrgArticle` |
| `fetchArticleDetail(articleId:siteId:)` | 2450 / 2480 / 2508 | `ArticleDetailDTO`（`content` / `href` / `id` / `title` / `updateTime` / `imageUrl`） |
| `resolveShortLinkFinalURL(_:)` | 2505 | `URL?`（302 目标） |

### 2.8 模块间依赖

- **被调用**：`HomeModuleManager.swift:101`（`.partySubject` 的 `dataCount = PartySubjectStore.shared.totalArticles`）；`TabBar.swift:1333`（首页 `partySubjectSection` NavigationLink）；`TabBar.swift:382`（通知深链 sheet）；首页计数徽章 L1238、最近一篇预览 L1356、`.task { loadIfNeeded() }` L1403。
- **调用**：`NetworkService`（4 端点）、`LogManager`（域 `party`）、设计系统（`SJZScrollActivityTracker` **来自 SchoolProfileView.swift L31**）、`WeChatSharePayload`（外部）。
- **反向共享**：本文件 L54 仅有注释占位，说明「滚动活动追踪」组件的归属在 SchoolProfileView。

### 2.9 技术债与风险点

1. **党建文章聚合方式 = 运行时栏目发现 + 全量串行抓取**：`fetchDeptSiteIndex` 解析子站栏目 → 6 路并发分页；两站 × 每栏最多 200 篇，全量走 `sites` 内存常驻 → **常驻内存随栏目数线性增长**，且每次 `refresh` 重新全量拉取（无增量、无 If-Modified-Since）。
2. **官网容器栏稳定 500 依赖「会话级记忆」容错**（L96 / L394–400）：`unavailableColumnIds` **进程重启即忘**，每次冷启动都会重踩一次；且只在失败后记忆，首次必付代价。
3. **`performFullFetch` 中 `skipped` 计数与 `grandTotal` 语义分离**：跳过栏目的文章数不计入 `totalArticles`，首页徽章数字与官网 article 总数不等，属**有意的诚实降级**但无 UI 说明（仅 `skippedColumnsCount` 一行 tertiary 文案）。
4. **`deepSearchSupplement` 全量重拉**（L256）：一次深度搜索 = 400 篇/栏的网络成本，仅在用户点按后触发，但**无并发限制保护**（可与其他刷新竞态，`refreshInFlight` 不覆盖 deepSearch）。
5. **两段式全文链路的强耦合假设**：`realArticleID` 依赖官网 href 的 `id` 参数形态（L2555 正则要求 16+ 位十六进制），官网改路由形式即静默退化为摘要兜底（`summary_fallback` warning，L2531）。
6. **搜索历史 Key 硬编码**（`"partySearchHistory"`，L515/957/1627）。
7. **零离线缓存**：与校园日历对比鲜明；冷启动断网 = 空列表 + 错误卡。
8. L394 是本文件唯一「踩坑」类注释（会话内不可用栏目跳过）。

---

## 3. PrincipalMailboxView.swift（1788 行）

### 3.1 完整顶层类型清单（6 项，含 2 个 typealias）

| 行号 | 声明 | 说明 |
|---|---|---|
| 16 | `typealias MailboxMessage = NetworkService.MailboxMessage` | 嵌套类型简写 |
| 18 | `typealias MailboxMessageDetail = NetworkService.MailboxMessageDetail` | 同上 |
| **23** | **`final class PrincipalMailboxStore: ObservableObject`** | 数据中枢（`@MainActor` L22），**唯一 `private init() {}`（L52）** |
| 284 | `struct PrincipalMailboxView: View` | 列表页 |
| 1255 | `struct MailboxMessageDetailView: View` | 信件详情（来信 + 校方回复） |
| 1710 | `struct MailboxSheetRoot: View` | 通知深链 sheet 根 |
| 1770 | `private struct MailboxMessageMissingView: View` | 深链目标缺失防御占位 |

**嵌套类型**：`PrincipalMailboxStore.RefreshStatus` (L78)。

### 3.2 数据结构（核心问题：留言与回复）

模型定义在 **NetworkService.swift**（本文件只做 typealias）：

**`NetworkService.MailboxMessage`（NetworkService.swift L1183）** —— 列表项，3 个业务字段：

| 字段 | 类型 | 语义 |
|---|---|---|
| `id` | `Int` | 信件 id |
| `title` | `String` | **原始来信**（标题/内容概述） |
| `showTitle` | `String` | **校方公开回复标题** |
| `messageTime` | `String` | 留言时间原始串（如 `2026-08-13T00:00:00`），`dateText` (L1193) 截 `T` 前段 |

**`NetworkService.MailboxMessageDetail`（L1287）** —— 详情项，7 字段：

| 字段 | 语义 |
|---|---|
| `showTitle` | 校方回复标题 |
| `content` | **来信内容**；`is_show_content = 0` 时为服务端隐私占位文案 |
| `isShowContent: Bool` | 服务端隐私开关（L1292 注释） |
| `messageTime` / `replyTime` | 原始时间串（`messageDateText` L1304 / `replyDateText` L1308） |
| `isReplied: Int` | `1` = 已回复（`replied` 计算属性 L1312） |
| `replyContent` | 校方回复正文 |

**`NetworkService.MailboxPageData`（L1199）**：`total` / `messages` / `noticeText`（"立即留言"模块正文，含电话与邮箱）。

**服务端 DTO 层级**（L1206–1247，含一条重要排错注释）：`data(标题层).data.message_list / leave_message_now` —— **仅两层 `data` 嵌套，多建模一层会把 `message_list` 静默解码为 nil（成功返回 0 条，逻辑上"暂无数据"）**。这是明确的**历史事故预防注释**。

### 3.3 提交还是只读？ → **只读**

| 证据 | 行号 | 结论 |
|---|---|---|
| 全仓 `httpMethod` 仅出现 `GET`（NetworkService.swift L86/134/247/300/1025）与一处 `HEAD`（L260） | NetworkService.swift | **无任何 POST/PUT** |
| 「前往官网留言」按钮 `UIApplication.shared.open(Self.opinionURL)` | PrincipalMailboxView.swift L1536–1558；`opinionURL = "https://www.sxjzit.edu.cn/#/opinion"` L1266 | 留言能力**外链给官网**，App 内不承载表单 |
| 「联系校长信箱」= `callPhone()` (L1673) / `copyEmail()` (L1685) | L1562–1591 | 仅电话/邮件出口 |
| Store 无 `submit` / `post` / `send` 方法 | L23–280 全量方法列表 | 只读 |

App 内唯一「写入」是 Debug 面板的**模拟**：`simulateNewMail()` (L255) 注入 `mockMessages` + `NotificationManager.shared.sendMailboxSimulationNotification` (L277)。

### 3.4 Store 状态与持久化

- 单例 `shared` (L24)，`pageSize = 50` (L27)，`maxPages = 10` (L29)。
- **@Published（11 项）**：`messages` (L31)、`total` (L32)、`noticeText` (L33)、`isLoading` (L34)、`lastError` (L35)、`hasLoaded` (L37)、`newMessageIds: Set<Int>` (L39)、`newCount` (L41)、`mockMessages` (L43)、`refreshStatus` (L85)、`lastRefreshDate` (L87)。
- `allMessages` (L46) = `mockMessages + messages`（模拟置顶 + 真实数据；L42 注释：与真实数据隔离，真实刷新不会覆盖）。
- **持久化键**：
  - `"mailboxLastKnownTotal"` (L221–223)：新增检测基线（`UserDefaults.standard.integer`）。
  - `"mailboxSearchHistory"`：View 层硬编码（L292 读 / L834 清 / L1202 写），上限 10。
- **联系方式动态解析**（L54–73）：`phoneNumber` (L56) 用正则 `联系电话[：:]\s*([0-9\-]+)` 从 `noticeText` 提取，失败回落 `"0351-3624911"`；`emailAddress` (L60) 正则 + 回落 `"sxjzlgxydwxcb@163.com"`；`firstMatch(pattern:in:)` (L65)。

### 3.5 关键方法签名

| 行号 | 签名 | 行为 |
|---|---|---|
| 92 | `func loadIfNeeded(force: Bool = false)` | 懒加载；`loadTask` 防重入 |
| 105 | `func refreshDetached(source: String) async` | **独立 Task + 等待句柄**；L101–104 注释详述理由：`.refreshable` 随下拉手势收回取消任务 → `URLError.cancelled` 造成「刷新失败 cancelled」误报 |
| 111 | `func refresh(source: String) async` | 防重入 → 取消在途 `loadTask`（避免并发双写，L121）→ `performFetch()` → `.success(newCount:elapsedMs:at:)`；`cancelled` 归 `.idle` 不展示失败横幅（L141–145） |
| 160 | `func dismissRefreshBanner()` | 非 `.refreshing` 置 `.idle` |
| 167 | `private func silentLoad(force: Bool) async` | 静默通道，失败仅落 `lastError` |
| 198 | `private func performFetch() async throws` | **分页续拉 + 新增检测 + 防御诊断**：`while page <= maxPages` 调 `fetchPrincipalMailbox(page:size:)`；首页记录 `expectedTotal` / `noticeText`（L206–209）；`data.messages.count < pageSize \|\| collected.count >= expectedTotal` 停止（L212）；新增检测：与 `mailboxLastKnownTotal` 比较，`collected.count > previousTotal` 时 `newCount = delta`、`newMessageIds = Set(collected.prefix(delta).map(\.id))`（L224–236）；**防御诊断**：`collected.isEmpty && expectedTotal == 0` 时 warning「信箱响应无留言数据（疑似服务端结构变化）」（L239–244，注释 L238 明确「而非静默空态」） |
| 255 | `func simulateNewMail()` | Debug：`mockId = 900000 + mockSequence`（L257），注入 `mockMessages[0]`，`newCount += 1`，触发通知 |

### 3.6 View 层结构

**列表页（`body` L328）**

```
ScrollView → VStack(spacing: 14)
├─ heroCard      L574  ① 主题头卡
├─ noticeCard    L654  ② 使用说明卡（noticeText）
├─ contactCard   L692  ③ 联系方式卡（仅 noticeText 非空时，L333）
├─ searchSection L759  ④ 搜索区（含搜索历史 L797）
├─ isSearching → searchStatusBar L1005
└─ contentSection L845 ⑤ 内容区（骨架 L1026 / 错误 L1060 / 空态 / 列表 → messageCard L896）
```

- 排序：`orderedMessages` (L313) = `allMessages.sorted { $0.messageTime > $1.messageTime }`（服务端已倒序，本地兜底；模拟信件今日日期自然置顶）。
- 搜索：`filteredMessages` (L318) —— **来信标题 + 回复标题**双字段 `lowercased().contains`，非分词 AND。
- 高亮：`highlightedText` (L974) / `mailboxHighlighted` (L989)。
- 刷新横幅三态：L473；`handleRefreshStatusChange` (L402)。
- 交互：`callPhone` (L1211)、`copyEmail` (L1223)、`openMail` (L1229)、`showToast` (L1240)、`commitSearch` (L1196)。

**详情页（`MailboxMessageDetailView` L1255）**

```
headerCard L1359 ① 头卡（回复标题 + 状态徽章）
letterCard L1418 ② 来信卡（隐私保护感知）
replyCard  L1482 ③ 校方回复卡
actionCard L1534 ④ 操作卡（前往官网留言 / 联系我们）
（detail 为空时 skeletonCard L1597；错误 errorCard L1624；toast L1656）
```

- `loadDetail()` (L1312)：`guard detail == nil`；**模拟信件短路** —— `message.id >= 900000` 时本地构造示意详情（L1317–1331，保证「模拟 → 通知 → 直达详情」验收闭环）；否则 `NetworkService.shared.fetchMessageDetail(msgId:)` (L1338)。

**通知深链宿主（`MailboxSheetRoot` L1710）**

- `NavigationLink(isActive:)` 方案的注释（L1706–1709）是本文件唯一「真机踩坑结论」：*「链接在视图挂载时即已注册，isActive 翻转不会因『栈尚未完全建立』而丢失导航动作」*；但代码实际用的是 `navigationDestination(isPresented:)` (L1732)，L1730–1731 注释说明为「官方推荐的回调式深链 API，无废弃警告」。
- `routeToMessageIfNeeded()` (L1746)：`store.loadIfNeeded()` → 轮询 `hasLoaded` 至多 **40 × 100ms = 4s**（L1753–1756）→ **额外 `sleep 350ms` 等 sheet 与导航栈挂载稳定**（L1758）→ 命中则 `pushDetail = true`，否则 warning「通知深链未找到目标信件，停留在列表」（L1764）。
- 缺失占位 `MailboxMessageMissingView` (L1770)：「该信件可能已下架或超出展示期（id N）」。

### 3.7 消费的端点与模型

| 端点 | 行号 | 模型 |
|---|---|---|
| `fetchPrincipalMailbox(page:size:)` | 204 | `MailboxPageData`（NetworkService.swift L1250；内部走 `get("/school/msg", params: page/size)`，`notice` 做了 `\r\n` → `\n` 与行首 `\t` 规范化，L1261–1268；`title` 或 `showTitle` 缺失的行被 `compactMap` 丢弃，L1271） |
| `fetchMessageDetail(msgId:)` | 1338 | `MailboxMessageDetail`（NetworkService.swift L1337） |

### 3.8 模块间依赖

- **被调用**：`HomeModuleManager.swift:100`（`.principalMailbox` → `PrincipalMailboxStore.shared.total`）；`TabBar.swift:234–236`（Debug 面板「模拟信箱新信」+ `mailbox=… new=…` 状态显示）；`TabBar.swift:1251`（`principalMailboxSection` NavigationLink，L1247 注释「懒加载数据（不阻塞全局同步）」）；`TabBar.swift:356`（`MailboxSheetRoot(messageID: pendingMailboxMessageID)`）。
- **调用**：`NetworkService`、`LogManager`（域 `mailbox`）、`NotificationManager.shared.sendMailboxSimulationNotification`（L277）。

### 3.9 技术债与风险点

1. **新增检测基于「总数差」而非 id 集合**（L224–227）：`newMessageIds = Set(collected.prefix(delta))` —— 若服务端删除旧信同时新增同数量信件，`delta` 为 0，**新增提示漏报**；若列表排序变化，高亮会落在错误信件上。
2. **`total` 语义混入 mock**（L217 / L268）：`total = collected.count + mockMessages.count`，与 `schoolCore` 的「封公开回复」文案（HomeModuleSettingsView L127）叠加 mock 后会虚高。
3. **深链 4s 轮询 + 350ms 硬等待**（L1753–1758）：数字魔法常量无注释来源，弱网下仍会失败退化为「停留在列表」。
4. **`orderedMessages` 每次 body 求值都做一次 O(n log n) 排序**（L313）：非缓存计算属性，与 `filteredMessages` 叠加成两趟遍历。
5. **联系方式靠正则解析服务端富文本**（L57/L61）：官网改文案格式即静默回落硬编码电话/邮箱（`0351-3624911` / `sxjzlgxydwxcb@163.com`），无失效告警（仅回落，无 warning 日志）。
6. **DTO 层级事故注释**（NetworkService.swift L1206–1208）：明确记录「多建模一层 `data` 会静默解码为 nil → 成功返回 0 条」的历史坑；本模块的防御诊断（L238–244）是对应的二次防线 —— 属**正面案例**，建议在 Wiki 中作为「静默失败必须留日志」的范式引用。
7. 搜索历史 Key 硬编码（L292/834/1202）。
8. **无离线缓存**；`maxPages = 10` × `pageSize = 50` = 上限 500 封，超限静默截断（无 UI 提示）。

---

## 4. CampusCalendarView.swift（1494 行）+ CampusCalendarStore.swift（478 行）

### 4.1 完整顶层类型清单（4 项）

**CampusCalendarView.swift**

| 行号 | 声明 | 说明 |
|---|---|---|
| 21 | `struct CampusCalendarView: View` | 列表页 |
| 820 | `struct CampusCalendarDetailView: View` | 校历详情 |
| 1411 | `private struct CalendarFullScreenImage: Identifiable` | 全屏图片载体 |
| 1422 | `private enum CalendarHTMLParse` | 正文 HTML 纯正则解析 |

**CampusCalendarStore.swift**

| 行号 | 声明 | 说明 |
|---|---|---|
| 17 | **`final class CampusCalendarStore: ObservableObject`** | `@MainActor`（L16），唯一嵌套类型 `RefreshStatus` (L52)、`CachePayload` (L75) |

### 4.2 CampusCalendarStore

**常量与持久化键**

| 行号 | 键 / 常量 | 值 / 语义 |
|---|---|---|
| 23 | `pageSize = 20` | 单页 20 |
| 25 | `maxPages = 10` | 搜索前全量拉齐的安全页数上限；超出后仍可搜索，但仅覆盖已缓存页（L24 注释） |
| 26 | `cacheKey = "campusCalendarCache"` | **列表缓存（JSON Data）** |
| 27 | `historyKey = "campusCalendarSearchHistory"` | 搜索历史 |
| 28 | `readIdsKey = "campusCalendarReadArticleIds"` | 已读集合 |
| 66 | `detailCache: [String: ArticleDetailDTO]` | 详情**内存**缓存（键 = articleId，无 TTL、无落盘） |

**@Published（15 项）**：`articles` (L32)、`total` (L33)、`isLoading` (L34)、`isLoadingMore` (L35)、`loadMoreFailed` (L36)、`hasMore` (L37)、`lastError` (L38)、`isFromCache` (L40)、`lastRefreshDate` (L41)、`refreshStatus` (L42)、`searchResults` (L43)、`searchHitCount` (L44)、`isSearchPending` (L46)、`searchHistory` (L47)、`readIds` (L48)。

**`RefreshStatus`（L52–57）**：`idle` / `refreshing` / `success(elapsedMs: Int, total: Int, at: Date)` / `failed(message: String)` —— 三态状态机，「下拉、进入、重试的统一可视反馈」（L50 注释）。**注意带 `elapsedMs` 与 `total`，比其它模块的状态机信息更丰富**。

**`CachePayload`（L75–79）**：`{ fetchedAt: Date, total: Int, articles: [ArticleDTO] }`，`Codable`（依赖 `ArticleDTO` 可编码）。

**关键方法**

| 行号 | 签名 | 行为 |
|---|---|---|
| 82 | `private func loadCache()` | `guard articles.isEmpty`；解码 `UserDefaults.data(cacheKey)`；**命中则 `articles = payload.articles`、`total`、`page = 1`、`hasMore = articles.count < total`、`isFromCache = true`、`lastRefreshDate = payload.fetchedAt`**，info 日志含 `fetchedAt` 与 `elapsedMs`；未命中记 debug「本地缓存读取未命中」 |
| 104 | `private func saveCache()` | 编码 `CachePayload(fetchedAt: Date(), …)` 落 UserDefaults，debug 日志含 `bytes` |
| 116 | `func loadInitial(force: Bool = false)` | `hasLoaded && !force` 返回；`loadTask != nil` 记「已有进行中任务」；**`if articles.isEmpty { loadCache() }`（先展示缓存）→ `loadTask = Task { await silentLoad() }`（再静默刷新）** |
| 126 | `private func silentLoad() async` | 拉第 1 页；成功写 `total`/`page=1`/`hasMore`/`hasLoaded`/`isFromCache = false`/`lastRefreshDate`/`loadMoreFailed = false` + `saveCache()`；`Task.isCancelled` 时记 debug「静默拉取已取消（由手动刷新接管）」并 return（L152–158）；失败落 `lastError` + error 日志含 `hasLoaded` 与 `hasCache` |
| 171 | `func refreshDetached(source: String) async` | 独立 Task + `_ = await task.value` 句柄（L168 注释：独立 Task 保证不被手势收回取消误报） |
| 176 | `func refresh(source: String) async` | `refreshInFlight` 防重入 → `refreshStatus = .refreshing` → **取消在途 `loadTask` + 取消 `searchDebounceTask` 并 `isSearchPending = false`（L191–193，注释「接管在途的搜索防抖/全量拉齐，避免与刷新并发双写列表」）** → 重拉第 1 页；`URLError.cancelled` → `.idle` 且**明确不展示失败横幅**（L215–217） |
| 230 | `func dismissRefreshBanner()` | 非 `.refreshing` 置 `.idle` |
| 238 | `func loadMore() async` | 触底续拉：`guard hasMore, !isLoadingMore, !isLoading, loadTask == nil`；`nextPage = page + 1`；成功 `articles.append` + `page = nextPage` + `saveCache()`；失败 `loadMoreFailed = true`；取消时 debug |
| 279 | `func search(_ keyword: String)` | **300ms 防抖**（`Task.sleep(300_000_000)`，L294）；空输入立即清结果并 `isSearchPending = false`；非空先 `isSearchPending = true` 再起防抖 Task（L292–300） |
| 304 | `private func performSearch(_ keyword: String) async` | 语料不完整时先 `ensureFullCorpus()`（L311–318，未完成仅 warning）；分词 `components(separatedBy: .whitespaces)`；**多词 AND + 权重：标题命中 `+3`，否则描述命中 `+1`，都不命中即 `allMatched = false; break`**（L327–338）；`sorted { $0.score > $1.score }`（**Swift `sorted` 稳定，同分保持文章原始顺序**，L341 注释）；写 `searchHitCount`、`isSearchPending = false`、`commitSearchHistory`；info 日志含 `hits` / `words` / `elapsedMs` |
| 353 | `private func ensureFullCorpus() async -> Bool` | 搜索前分页全量拉齐，`fetchedPages < Self.maxPages` 保护；每页后 `saveCache()`；失败 `complete = false` + error 日志「搜索全量拉齐中断」 |
| 388 | `func commitSearchHistory(_ keyword: String)` | 去重置顶，上限 10，落盘 |
| 399 | `func clearSearchHistory()` | 清空 + 落盘 + info 日志含 `removed` 计数 |
| 408 | `func loadDetail(articleId: String) async -> ArticleDetailDTO?` | 内存缓存命中记 info「详情缓存命中」`elapsedMs: 0`；未命中 `fetchArticleDetail(articleId:)` → `detailCache[articleId] = detail` + `markRead(articleId:)`；失败 error 日志 + 返回 nil |
| 438 | `func isRead(articleId: String?) -> Bool` | nil 安全 |
| 443 | `func markRead(articleId: String)` | 幂等（`guard !readIds.contains`），落盘 |
| 453 | `static func dateText(_ raw: String?) -> String` | 官网时间串 → `yyyy.MM.dd`：依次尝试 `yyyy-MM-dd HH:mm:ss` / `yyyy-MM-dd` / `yyyy-MM-dd'T'HH:mm:ss`，再退 `ISO8601DateFormatter`，最后 `String(raw.prefix(10))` |
| 474 | `private static func logDateText(_ date: Date)` | `MM-dd HH:mm` |

### 4.3 View 层结构

**列表页（`body` L42）**

```
ScrollView → LazyVStack(spacing: 14)
├─ heroCard        L88   Hero 头卡（同步证据 + 「离线缓存」徽章）
├─ searchBar       L201  搜索框（Liquid Glass + 聚焦渐变描边动画）
├─ !isSearching → refreshBanner  L302  刷新三态横幅
├─ isSearching && (hitCount>0 || isSearchPending) → hitBadge  L393（body 条件 L48）
└─ contentStack    L415  内容区（骨架 / 错误 / 空态 / 列表 / 分页）
   ├─ 文章卡片列表  L552（图标化卡片 + 关键词高亮 + 入场 stagger）
   ├─ cardPalettes L656（卡片配色轮换）
   └─ 分页底部      L664
```

- **官网列表图为占位图，不渲染缩略图**（文件头 L7 注释 + 卡片为图标化设计）——这是与 SchoolProfileView/党建模块最大的视觉差异。
- `.refreshable { await store.refreshDetached(source: "下拉刷新") }` (L55)；`.task { store.loadInitial() }` (L61)；`onAppear` 触发 `listAppeared` 入场动画（`easeOut 0.5 + delay 0.06`，L65）。
- `onChange(of: searchText)` → `store.search(newValue)` (L77–79)；`onChange(of: store.refreshStatus)` → `handleRefreshStatusChange` (L80/L771)：success → `refreshSuccessPulse = true` → **`sleep 1.6s` → 复位 + `dismissRefreshBanner()`**（L773–779）。
- 工具栏 (L734)：`.refreshing` 显示 `ProgressView`，成功脉冲显示 `checkmark.seal.fill`，否则 `arrow.triangle.2.circlepath`；`.disabled(refreshStatus == .refreshing || isLoading)` (L767)；`accessibilityLabel("刷新校园日历")` (L768)。
- 关键词高亮 `highlightedText`/橙色高亮 (L714，注释「NSRange⇄Character 双域安全转换，与帮助中心规范一致」)。
- 滚动方向日志：3 秒节流（L1360，`lastScrollLog` L834）。
- 空态/失败重试在 L415 区块内；Toast overlay L792 / `showToast` L812。

**详情页（`CampusCalendarDetailView` L820）**

- 状态：`detail` (L825)、`isLoading`、`loadError`、`imageURLs: [URL]` (L828)、`plainText` (L829)、`fullScreenItem`、`showShareSheet`、`shareItems`、`toastText`、`lastScrollLog`、`isSavingAll` (L835)。
- `detailContent(_:)` (L909)：标题卡（`displayFont(21, weight: .heavy)` + 「更新于 \(dateText)」胶囊 + `tag` 金色胶囊）→ `actionBar` (L950) → **图片区：`imageURLs.isEmpty` 走 `noImageCard` 优雅兜底，否则 `imagesStack`**（L948–952）→ `plainTextSection`（L958 / L1196，正文纯文本说明）。
- 图片竖排 `imagesStack` (L1072)：`SJZCachedImage` 降采样 + 轻点全屏（缩放拖拽）+ 长按菜单；图片动作 L1277（长按保存 / 分享 / 全量保存 `isSavingAll`）；骨架/错误 L1219；Toast L1373。
- `CalendarHTMLParse` (L1422)：正则提取图片与纯文本；L1455 注释「图片 URL 修复：相对路径/协议缺失补全 + 非 ASCII 百分号编码」；L1417 MARK 标题即工程红线：**禁 NSAttributedString HTML 解析**。
- `dateText` 使用点：L918–923（详情「更新于」）、L604–609（卡片日期）。
- `syncDateFormatter` (L160)：`"M月d日 HH:mm"`。

### 4.4 端点与模型

| 端点 | 行号 | 模型 |
|---|---|---|
| `fetchArticles(columnId: NetworkService.campusCalendarColumnId, siteId: "1", page:, size:)` | 135（首载）/196（刷新）/249（加载更多）/360（全量拉齐） | `ColumnDTO` → `ArticleDTO`（`resolvedTitle` / `description` / `createTime` / `updateTime` / `tag` / `imageUrl`） |
| `fetchArticleDetail(articleId:)` | 418 | `ArticleDetailDTO`（`content` / `updateTime` / `tag` / `imageUrl`） |

栏目常量：`NetworkService.campusCalendarColumnId = "8197fe41503c4c32bce1e449d2492b2e"`，位于 `extension NetworkService`（**NetworkService.swift L439–441**），注释「校园生活 → 校园日历 栏目 ID（官网 column_id，site_id=1）」。

### 4.5 与 WebView 的差异（原生模块定位）

| 维度 | 校园日历（原生） | 其它校园服务 / 通用 WebView |
|---|---|---|
| 入口 | `CampusView` 校园服务网格，`service.url == "sxjzit://campus-calendar"` → `showCalendar = true`（TabBar.swift L7985）→ `.navigationDestination`（TabBar.swift L7957） | `service.url` 为 http(s) 时 `openURL(url)` **跳出 App 到浏览器**（TabBar.swift L8396–8400，注释「内部协议（sxjzit://）回调：由 CampusView 注入原生导航；其余外链服务不经过此路径」） |
| 通用 WebView | 不使用 | `WebViewContainer`（TabBar.swift L4883）/ `WebView: UIViewRepresentable`（L4965，WKWebView + `estimatedProgress` KVO）——用于文章「查看原文」等 |
| 离线能力 | ✅ UserDefaults JSON 列表缓存 + 「离线缓存」徽章 + `isFromCache` | ❌ 依赖网页 |
| 搜索 | ✅ 本地 300ms 防抖多词 AND + 分页全量拉齐 | ❌ |
| 已读 / 搜索历史 | ✅ 落盘 | ❌ |
| 日志埋点 | 域 `campusCalendar`，入口点击单独打点（TabBar.swift L8387，`entry: "campus-service-grid"`） | 域 `campusService` |

**关于「日期聚合与筛选」**：**源码中不存在日期分组/年份筛选/日历视图等实现**。`grep` 实测该文件内与日期相关的只有：`CampusCalendarStore.dateText` (Store L453)、详情「更新于」文案 (L918–923)、卡片日期 (L604–609)、`syncDateFormatter` (L160)。列表为**纯服务端时间倒序的文章流**，无本地日期聚合、无筛选条件 UI。若 Wiki 需要「按日期聚合」，应标注为**未实现**。

### 4.6 模块间依赖

- **被调用**：`HomeModuleManager` **不引用**本模块（无 `.campusCalendar` 首页模块）；`CampusCalendarStore.shared` 只被 `CampusCalendarView.swift` L22 / L822 引用（`grep -rn 'CampusCalendarStore.shared'` 排除自身文件后为 0 命中）→ **完全内聚，仅由校园生活 Tab 内部导航进入**。
- **调用**：`NetworkService`、`LogManager`（域 `campusCalendar`）、`ProfileImageSaveShare`（保存/分享复用学校概况的 `enum`，View 头部 L11 注释明示）、`SJZCachedImage`、`ShareSheet`。

### 4.7 技术债与风险点

1. **列表缓存无 TTL 校验**：`CachePayload` 存了 `fetchedAt`（L76）但 `loadCache()`（L82–102）**从不检查其时效**，只用于日志与 `lastRefreshDate` 展示 → 用户可能长期看到极旧的缓存列表，仅靠「离线缓存」徽章提示（`isFromCache` 在刷新成功前保持 true）。
2. **整表写入 UserDefaults**：`articles` 全量（含 title/description）序列化进 `UserDefaults`（L104–112）。分页越深、写入越频繁（`loadMore` / `ensureFullCorpus` 每页都 `saveCache()`），**UserDefaults 并不适合承载 MB 级 blob**。
3. **搜索会触发最多 10 页网络拉齐**（`ensureFullCorpus` L353–384）：用户在搜索框打字即可触发批量请求（300ms 防抖后），弱网/流量敏感场景需注意；失败仅 warning 后**静默降级为「仅搜已缓存页」**（L313–317），用户无从得知召回不完整。
4. **详情缓存无上限、无淘汰**（L66 `detailCache`）：会话内浏览越多占用越大，且 `refresh` 不清空（与 SchoolProfileView 的代际清理策略相反）；`markRead` 只在成功路径调用（L420），缓存命中路径**不更新已读时间**（幂等所以无害，但语义上「重读不刷新」）。
5. **`isFromCache` 语义覆盖全局**：首屏缓存命中后若用户直接进入详情并返回，`isFromCache` 仍为 true 直到刷新成功 —— 徽章文案与真实数据新鲜度可能不一致。
6. **`maxPages = 10` 的静默截断**：`total` 可能远大于 200（20×10），`hasMore` 会停在 true 但 `loadMore` 仍可继续（`loadMore` 不受 maxPages 限制）—— 而搜索受 `maxPages` 限制 → **「能翻到但搜不到」的不一致**（未验证：需实际运行确认 `total` 规模）。
7. `dateText` 每次调用都**重建 3 个 `DateFormatter` + `ISO8601DateFormatter`**（L453–471，`formatters` 为 `()` 立即执行闭包，非静态缓存）→ 列表滚动时反复创建，属**性能反模式**（对比 `syncDateFormatter` L160 是 static 缓存）。

---

## 5. HelpGuideView.swift（1552）+ HelpGuideStore.swift（239）+ HelpContent.swift（593）

### 5.1 完整顶层类型清单（6 项）

| 文件 | 行号 | 声明 | 说明 |
|---|---|---|---|
| HelpContent.swift | 14 | `struct HelpCategory: Identifiable, Hashable` | id / title / subtitle / icon / accent（主题色统一 sjz 色板） |
| HelpContent.swift | 24 | `struct HelpStep: Identifiable, Hashable` | `init(_ title:_ text:)`，`id = title`（L30） |
| HelpContent.swift | 37 | `struct HelpArticle: Identifiable, Hashable` | id / categoryId / title / summary / icon / tags / steps / relatedIDs；`readingMinutes` (L48) |
| HelpContent.swift | 57 | `enum HelpCatalog` | 内容总目录（唯一内容事实源） |
| HelpGuideStore.swift | 14 | `struct HelpSearchHit: Identifiable, Equatable` | `article` + `score`，`id = article.id` |
| HelpGuideStore.swift | 24 | **`final class HelpGuideStore: ObservableObject`** | `@MainActor`（L23），`private init()` (L47) |
| HelpGuideView.swift | 14 | `struct HelpGuideView: View` | 帮助中心主页 |
| HelpGuideView.swift | 824 | `struct HelpArticleDetailView: View` | 文章详情 |

### 5.2 HelpCatalog（内容事实源）

- **5 个分类**（L61–67）：`gettingStarted` 快速上手 / `homeReading` 首页与阅读 / `features` 特色功能 / `settings` 设置与个性化 / `faq` 常见问题。各含 `subtitle` 与 SF Symbol + `sjz*` 主题色。
- **32 篇文章**（`grep -c 'HelpArticle('` 实测 = 32；按 `categoryId` 分布：gettingStarted 6 / homeReading 7 / features 7 / settings 6 / faq 6）。
- 每篇 `steps` 为编号步骤（详情页以圆徽章逐步渲染），`relatedIDs` 驱动「相关文章」。
- `readingMinutes`（L48–51）：`steps.reduce(title.count + text.count) + title.count + summary.count` → `max(1, ceil(chars / 300))`，注释说明「与全 App 阅读统计口径一致：300 字/分钟」。
- 查询 API：`article(_:)` L576、`articles(inCategory:)` L581、`category(of:)` L586、`related(to:)` L591。
- 文件头注释（L5–6）：*「全部指南文章内置于 App（**无后端约束下的静态内容方案**）」*。

### 5.3 HelpGuideStore

- **单例** `shared` (L26)，`@MainActor`。**零网络**（无 `NetworkService` 引用）。
- **持久化键（3 个，均为 `private static let`，本模块唯一规范使用常量的 Store）**：`readKey = "helpGuideReadIds"` (L30)、`historyKey = "helpGuideSearchHistory"` (L31)、`recentKey = "helpGuideRecentIds"` (L32)。
- **@Published（3 项）**：`readArticleIds: Set<String>` (L37)、`searchHistory: [String]` (L40，上限 10)、`recentArticleIDs: [String]` (L43，上限 6)。
- **init 的目录对账（L47–63，重要历史缺陷修复）**：`validIDs = Set(HelpCatalog.articles.map(\.id))`，`pruned = Set(stored).intersection(validIDs)`，不一致则立即回写（L55–57）。L49–50 注释：*「已读集合与当前目录对账：历史残留（已从目录移除的文章）id 必须剔除，否则 **readProgress 可能 >1、unreadCount 恒 0 并误禁用「全部标记已读」**」* —— 典型的**内容目录与持久化状态版本漂移**事故。

**只读统计**：`categories` L68、`allArticles` L71、`totalArticles` L74、`unreadCount` L77（`max(0, …)` 防御）、`readProgress` L80（`Double(readIds)/Double(total)`，空目录返回 0）、`articleCount(in:)` L86、`readCount(in:)` L91、`recentArticles` L96（`compactMap` 保序）。

**读写方法**

| 行号 | 签名 | 行为 |
|---|---|---|
| 103 | `func isRead(_ id: String) -> Bool` | — |
| 108 | `func markRead(_ id: String)` | 幂等（`guard !contains`）；单条落盘；info 日志 |
| 116 | `func markAllRead()` | **单次批量落盘**（L115 注释），info 日志含 `count` |
| 126 | `func recordOpen(_ article: HelpArticle)` | `markRead` + 最近阅读去重置顶 + 上限 6 + 落盘 |
| 142 | `func search(_ rawKeyword: String) -> [HelpSearchHit]` | 见下 |
| 198 | `func recordSearchHistory(_ keyword: String)` | trim 后去重置顶，上限 10，落盘 + debug 日志 |
| 214 | `func clearSearchHistory()` | 清空 + 落盘 + info |
| 221 | `func resetReadProgress()` | 「全部已读」误触后的恢复手段（L220 注释）；**最近阅读不受影响**；info 日志含 `clearedCount` / `recentKept` |
| 234 | `func nextArticle(after article: HelpArticle) -> HelpArticle?` | 同分类下一篇（已是最后一篇返回 nil），驱动「有帮助」后的继续学习引导 |

**`search` 算法（L142–195）**

1. `trimmingCharacters(in: .whitespacesAndNewlines)`，空则返回 `[]`。
2. 分词 `components(separatedBy: .whitespaces)`（**注释声称支持全角空格**，L139，但实现里 `.whitespaces` 字符集包含全角空格 U+3000，与 SchoolProfileView 的显式 `"　"` 写法不同但等效）。
3. 逐篇、逐词累加权重（L163–176）：**标题 5 / 摘要 3 / 标签 2×命中数 / 步骤标题 1.5 / 步骤正文 1**；`stepHit` 保证每步最多计一次（L173 `break`）。
4. **AND 语义**：任一词未命中即 `allHit = false; break`（L175）。
5. 排序（L182–188）：`score` ↓ → `readingMinutes` ↑（越短越优先）→ `id` ↑（目录顺序）。
6. info 日志含 `keyword` / `hitCount` / `elapsedMs`（`String(format: "%.0f", …)`，L192）。

### 5.4 HelpGuideView 结构

**主页（`body` L43）**

```
ScrollView → LazyVStack(spacing: 0)
├─ headerHero          L146  Hero 头卡
├─ searchField         L204  Liquid Glass 搜索框（聚焦描边动画）
└─ inSearchMode ?
     ├─ searchResultsSection L288（含 searchingIndicator L348 / searchEmptyState L362 / searchHistorySection L392）
     └─ else
        ├─ categoryChips L448（selectCategory L506）
        ├─ selectedCategory == nil → recentSection L516（recentCard L561）
        └─ articleSections L596（sectionHeaderRow L628 / sectionTitle L657 / countCapsule L668 / helpArticleCard L679 / readingTimeCapsule L737 / readingTierColor L750 / highlighted L760）
```

- 背景 `Color(.systemGroupedBackground)` (L71)——**全模块唯一不用 `GradientBackground()` 的页面**。
- 工具栏 (L74)：Menu「全部标记已读」（`.disabled(store.unreadCount == 0)` L83）+「清除阅读进度」（`.disabled(store.readProgress <= 0)` L93）+ `accessibilityLabel("进度管理")` (L99)。
- 危险操作二次确认 `confirmationDialog` (L103–110)，文案明确后果与不可撤销，并强调「最近阅读记录不受影响」。
- 详情以 `.sheet(item: $selectedArticle)` (L134) 弹出，`NavigationStack { HelpArticleDetailView }` + `.sjzPresentationChrome()`。
- **搜索历史只在实际点击结果时写入**（`openArticle` L804，L807 注释：「搜索结果被真正点击时才写入搜索历史（防抖输入不污染历史），历史=用过的关键词」）——与其它三个模块「提交即记录」的策略不同，属**更精细的埋点设计**。
- `displayArticle(_:)` (L343) / `getCurrentKeyword()` (L338) 辅助。

**详情页（`HelpArticleDetailView` L824）**

区块：`detailHeader` L924 → `readingMetaRow` L963 → `tagsRow` L987 → `stepsSection` L1004（`stepCard(index:step:)` L1012，编号圆徽章）→ `feedbackArea` L1055 → `relatedSection` L1481 → `footerNote` L1531 → `copyFullText` L1543。

**反馈与「三招」行动面板（本模块最具特色的交互）**

- `feedbackArea` (L1055) 三态（L1048–1053 注释）：
  - 未表态 → 「这篇解决你的问题了吗？」+ `helpedButton` (L1083) / `notHelpedButton` (L1104)；
  - 「有帮助」→ `helpedNextSection` (L1150)（推荐同分类下一篇，`store.nextArticle`）；
  - 「没帮助」→ `showHelpPanel = true` → `actionPanel` (L1218)。
- `actionPanel` 三招（L1218–1332，每条都是真实出路而非仅记录反馈）：
  - **第一招**：就地搜索，「换个关键词，就地搜到答案」→ `runInlineSearch(_:)` (L1347) 复用 `HelpGuideStore.search`；
  - **第二招 / 第三招**：`quickRelatedChip` (L1401) 快速相关文章跳转、`copyFeedbackCard` (L1436) 复制联系方式；
  - `switchTo(_:source:)` (L1447) 支持在详情内原地换文章（不关 sheet）；`showToast` (L1467)。
- **文案红线（L1149）**：*「注意：本 App 无后端不上传，因此绝不用「已收到反馈」这类承诺送达的文案。」* —— 本模块唯一显式标注的产品/技术约束。

### 5.5 使用帮助锚点体系 +「校园亮点」被替换的历史

**事实链（均实测行号）**

| 事实 | 位置 |
|---|---|
| 首页「使用帮助锚点卡」区块 = **原「校园亮点」固定区块位置**，改造日期 **2026-09-24** | `TabBar.swift:880` MARK 注释：「使用帮助锚点卡（原「校园亮点」固定区块位置，2026-09-24 升级改造）」 |
| 锚点卡渲染条件与「首页管理」开关**联动**：`if homeModules.isVisible(.helpGuide)` | `TabBar.swift:883–886` |
| 模块循环**排除帮助模块，避免双份渲染** | `TabBar.swift:581`：`ForEach(… homeModules.visibleOrderedModules.filter { hasContent($0) && $0 != .helpGuide } …)` |
| 模块 switch 中 `.helpGuide` 分支 = **防御死码**（保留以维持 `CaseIterable` 穷举） | `TabBar.swift:1215–1219` |
| 锚点卡内容：渐变图标块 + 标题/未读徽章 + 已读百分比 + **进度环** + 继续阅读直达 | `TabBar.swift:882` 文档注释；进度环 `anchorRingProgress` L561，取值 `helpGuideStore.readProgress` (L924)、动画源 `onChange` (L938)、`.trim(from:to:)` (L1006) |
| 锚点卡展示日志**会话守卫**（仅首次记 info，避免滚动/切 Tab 刷屏） | `anchorCardAnnounceLogged` L565 / L926–933 |
| 可见性变化**双向对称**记录（挂在 body 顶层，卡片隐藏时监听仍有效） | `TabBar.swift:631–637` |
| `navigationDestination(isPresented: $showHelpCenter)` **挂在 body 顶层锚点**（条件分支内注册会在卡隐藏时失效） | `TabBar.swift:641–644` |
| 「继续阅读」直达：`helpGuideStore.recordOpen(article)` 包在 `withAnimation` 事务内（驱动续读行过渡与进度环联动） | `TabBar.swift:1060–1066`，日志 `source: "home_anchor_continue"` |
| 点击锚点卡：日志 `source: "home_anchor"` | `TabBar.swift:1048–1049` |
| `HomeModule.helpGuide` 的模块注释 = **原「招生信息」模块升级改造**（招生内容保留在资讯 Tab 招生分类） | `HomeModuleManager.swift:18` |
| 旧值迁移 `"admissionNews"` → `"helpGuide"`（顺序键与隐藏键**双键迁移**，迁移后立即落盘避免重复迁移与重复日志） | `HomeModuleManager.swift:149–184`（顺序）、`208–249`（隐藏） |

**锚点体系的完整语义**：`HelpGuideStore` 暴露的 `readProgress` / `unreadCount` / `recentArticles` 三个只读量，是首页锚点卡**唯一数据来源**；`recordOpen` 是首页「继续阅读」与帮助页打开文章**共用的写入口**（幂等，重复打开无副作用）。因此帮助模块虽零网络，却与首页存在**双向状态耦合**：
- 首页 → 帮助：锚点卡点击 / 继续阅读直达 / `isVisible(.helpGuide)` 可见性开关；
- 帮助 → 首页：`readProgress`（进度环）、`unreadCount`（未读徽章）、`recentArticles`（续读行）经 `@ObservedObject helpGuideStore` (TabBar.swift:549) 自动刷新。

### 5.6 模块间依赖

- **被调用**：`HomeModuleManager.swift:94`（`.helpGuide` → `HelpGuideStore.shared.totalArticles` 作为 `dataCount`）；`TabBar.swift:549`（`@ObservedObject`）与锚点卡全链路（L573 / L631 / L641 / L885–1066）。
- **调用**：无 `NetworkService`、无 Notification；仅 `LogManager`（域 `helpGuide`）+ 设计系统。

### 5.7 技术债与风险点

1. **内容与代码同仓同编译**：32 篇文章硬编码在 `HelpContent.swift`，改文案 = 改代码 + 重新发版；`relatedIDs` 为字符串引用，**无编译期校验**（错误 id 静默失效，`compactMap` 丢弃，`related(to:)` L591）；`HelpStep.id = title`（L30）→ **同文章内两个步骤标题相同会导致 `Identifiable` id 冲突**（SwiftUI `ForEach` 渲染风险）。
2. **`HelpCatalog.articles` 每次访问都重新 filter**：`articles(inCategory:)` (L581) 为 O(n) 线性扫描且在 `articleCount`/`readCount`/`nextArticle` 中被反复调用；32 篇规模无感知，但属可优化点。
3. **搜索历史写入时机特殊**（L804–821）：只在实际点击时记录 → 若用户在结果中点开又立刻关闭，历史已写；未点击则永不记录。这是**有意的设计选择**，但与其他三模块（SchoolProfile / Party / Mailbox 在 `commitSearch` 时写）不一致，Wiki 需并列说明以免误读为缺陷。
4. **`readArticleIds` 只做「目录对账」，不做「新增文章」处理**：新版本新增文章后，已读进度分母变大 → `readProgress` **自动下降**（用户观感是「进度倒退」），无补偿逻辑。
5. **`markAllRead` 与 `resetReadProgress` 均为不可撤销的单键操作**：虽有 confirmationDialog 与菜单二次入口，但 `markAllRead` **无二次确认**（仅 Menu 项），只能靠「清除阅读进度」恢复（且**最近阅读状态无法恢复**）。
6. **Store 的持久化键命名规范优于其他模块**（`private static let` vs 硬编码字符串），可提炼为 Wiki 的「推荐范式」对照。
7. `HelpSearchHit` 的 `score` 已计算但**在 UI 中未发现用于展示徽章**（文件头 L12 注释称「供列表徽章展示」）—— 未验证：`searchResultsSection` (L288) 内是否消费 `score` 未逐行核对。

---

## 6. HomeModuleManager.swift（356 行）

### 6.1 完整顶层类型清单（3 项）

| 行号 | 声明 | 说明 |
|---|---|---|
| 14 | `enum HomeModule: String, CaseIterable, Identifiable, Hashable` | 12 个内容模块（`CaseIterable` 顺序 = 默认顺序） |
| 31 | `extension HomeModule` | 展示元数据：`title` (L33) / `icon` (L51) / `color` (L69) / **`dataCount` (L87)** / `countUnit` (L107) |
| 124 | **`final class HomeModuleManager: ObservableObject`** | `@MainActor`（L123），`private init()` (L140) |

**12 个模块（`case rawValue`，L15–26）**：`importantNews` 学校要闻、`honors` 校园荣誉、`notices` 通知公告、`helpGuide` 使用帮助、`teacherProfiles` 教师风采、`videos` 映像校园、`studentStories` 学生故事、`campusActivities` 校园活动、`timeline` 发展历程、`principalMailbox` 校长信箱、`partySubject` 党建专题、`schoolProfile` 学校概况。

L12–13 注释明确边界：**固定区块（顶部 Banner、数据统计、快捷入口）属于品牌与导航核心，不参与管理**。

### 6.2 模块可见性管理与 `visibleOrderedModules`

**@Published（2 项，均 `private(set)`）**

| 行号 | 字段 | 语义（注释原文） |
|---|---|---|
| 135 | `moduleOrder: [HomeModule]` | 「模块排列顺序（**包含隐藏模块**，反映用户自定义的完整顺序）」 |
| 138 | `hiddenModules: Set<HomeModule>` | 隐藏的模块集合 |

**查询 API**

| 行号 | 成员 | 行为 |
|---|---|---|
| 269 | `func isVisible(_ module: HomeModule) -> Bool` | `!hiddenModules.contains(module)` |
| 274 | `var visibleOrderedModules: [HomeModule]` | **`moduleOrder.filter { !hiddenModules.contains($0) }`** —— 首页实际渲染列表；顺序 = 用户自定义顺序，隐藏项被过滤 |
| 279 | `var isDefault: Bool` | `moduleOrder == HomeModule.allCases && hiddenModules.isEmpty`（**依赖 `CaseIterable` 顺序等价于默认顺序**） |

**修改 API**

| 行号 | 签名 | 行为 |
|---|---|---|
| 286 | `func setVisible(_ module: HomeModule, _ visible: Bool)` | 用 `Set.insert().inserted` / `remove() != nil` 求变更；**幂等**：未变化时**不落盘**，仅记 `debugLog`（L304–309），变化时记 info（含 `module`/`title`/`action`/`wasVisible`/`newVisibleCount`/`newHiddenCount`） |
| 313 | `func moveModules(from source: IndexSet, to destination: Int)` | `moduleOrder.move(fromOffsets:toOffset:)`（List `onMove` 语义）→ `persistOrder()`；info 日志记录**移动前后完整顺序**（`orderBefore` / `orderAfter`） |
| 324 | `func resetToDefaults()` | 顺序 = `HomeModule.allCases`，隐藏 = 空；**记录恢复前快照**（`orderBefore` / `hiddenBefore`）+ `isDefaultNow` |

**持久化**

| 行号 | 键 | 写入内容 |
|---|---|---|
| 127 / 340 | `"homeModuleOrder"` | `moduleOrder.map(\.rawValue)`（**保持用户顺序，未排序**）+ debug 日志 |
| 128 / 349 | `"homeModuleHidden"` | `hiddenModules.map(\.rawValue).sorted()`（**排序后写入**，保证同集合落盘字节稳定）+ debug 日志 |

### 6.3 加载与降级策略（`private init()` L140–264，共 125 行）

这是全模块最复杂的一段，逐层防御：

| 步骤 | 行号 | 策略 |
|---|---|---|
| ① 顺序读取 | 148 | `defaults.stringArray(forKey: orderKey)`；缺失则 `order = []`（后续靠 ④ 补全 → 等价默认顺序） |
| ② 旧值迁移 | 151–157 | `"admissionNews"` → `"helpGuide"` 静默替换，计数 `migratedAdmissionNews`；**保证用户自定义顺序与可见性不丢失** |
| ③ 非法值分类 | 158–174 | `compactMap(HomeModule.init(rawValue:))` 丢弃非法值并计 `droppedInvalidCount`；再分两类：**退役值**（`retiredRawValues`）记 **info**「退役值自动清理」，**真非法值**记 **warning**「含非法条目（已忽略）」（区分严重级别） |
| ③b 迁移立即落盘 | 175–184 | `defaults.set(migrated, forKey: orderKey)` + info 日志带 `persisted: "true"`；注释：「避免每次启动重复迁移、重复记录迁移日志」 |
| ④ 去重 | 186–198 | `Set<String>` 保持**首次出现顺序**，`droppedDuplicateCount` > 0 时 warning「含重复条目（保留首次出现）」 |
| ⑤ 新模块补位 | 200–204 | `for module in HomeModule.allCases where !order.contains(module) { order.append(module) }` → **未来新增模块自动补到末尾**，计 `appendedNewModules` |
| ⑥ 隐藏集合迁移 | 208–250 | 与顺序键**同构的完整迁移链路**（`admissionNews` → `helpGuide`、退役值/非法值分级日志、迁移立即落盘 L242）；`Set` 去重语义下 `hiddenInvalidCount = stored.count - parsed.count` **含非法 + 重复两类**（L221 注释主动说明） |
| ⑦ 加载摘要 | 254–263 | 单条 info：`order` / `visibleCount` / `hiddenCount` / `isDefault` / `migratedAdmissionNews` / `droppedInvalid` / `droppedDuplicate` / `appendedNewModules` |

**退役模块常量（L130–132）**：`static let retiredRawValues: Set<String> = ["campusSceneries", "bottomBanners"]`。L130–131 注释原文：*「已退役下线的模块 rawValue（**2026-09-24：合作交流/校园风光数据源中断，内容并入「学校概况」模块**）：历史存储中的这些值在加载时自动清理（info 日志），区别于普通非法值（warning 日志）」* —— **这是本模块最重要的历史事故记录**，同时解释了为什么 SchoolProfileView 内部承载了「校园风光」与「合作交流」两个 Tab。

### 6.4 `dataCount` 必须主线程的约束

```swift
/// 当前数据量（实时读取共享数据源，需在主线程访问）
@MainActor
var dataCount: Int {                       // HomeModuleManager.swift:87–88
    let data = DataService.shared
    switch self {
    case .helpGuide:        return HelpGuideStore.shared.totalArticles            // L94
    case .principalMailbox: return PrincipalMailboxStore.shared.total             // L100
    case .partySubject:     return PartySubjectStore.shared.totalArticles         // L101
    case .schoolProfile:    return SchoolProfileStore.shared.allEntries.count     // L102
    default:                return data.<对应字段>.count                           // L91–99
    }
}
```

- **约束性质**：这是**编译期强制**的 Swift 并发隔离，而非运行期断言。四个外部 Store 与 `DataService` 均为 `@MainActor`（`SchoolProfileStore` L174、`PartySubjectStore` L58、`PrincipalMailboxStore` L22、`HelpGuideStore` L23），因此从非主线程访问 `dataCount` 会直接编译失败——这正是 L86 注释「需在主线程访问」的含义（**不是运行时崩溃风险，而是 API 契约**）。
- **唯一调用点**：`HomeModuleSettingsView.swift:127` 与 `:129`（`moduleSubtitle`），位于 SwiftUI `View` 的 `@MainActor` 上下文内，天然满足约束。
- **数据量单位**（`countUnit` L107–116）：`importantNews`/`notices` → 「条」，`helpGuide`/`partySubject` → 「篇」，`principalMailbox` → 「封」，`schoolProfile` → 「项」，其余 → 「个」。
- **副作用提示**：`dataCount` 是**计算属性**，每次读取都访问 5 个 Store 的属性；在 `List` 行渲染中按行调用 → 12 行 × 多次求值。当前规模无性能问题，但**跨 Store 读耦合**使得任一 Store 的 `@Published` 变化都会让 `HomeModuleSettingsView` 整体失效重绘（`@ObservedObject data = DataService.shared` L12 已订阅）。

### 6.5 与 TabBar `HomeView` 的对接

| 对接点 | 位置 | 机制 |
|---|---|---|
| HomeView 持有管理器 | `TabBar.swift:548` `@ObservedObject private var homeModules = HomeModuleManager.shared` | `@Published` 变化即驱动首页重排 |
| HomeView 持有帮助 Store | `TabBar.swift:549` `@ObservedObject private var helpGuideStore = HelpGuideStore.shared` | 锚点卡进度/未读实时刷新 |
| **模块列表渲染** | `TabBar.swift:581` `ForEach(Array(homeModules.visibleOrderedModules.filter { hasContent($0) && $0 != .helpGuide }.enumerated()), id: \.element.id)` | `visibleOrderedModules` 是首页渲染顺序**唯一来源**；额外过滤「有内容」与帮助模块（后者改由固定区锚点卡渲染） |
| 渲染预算判断 | `TabBar.swift:1158` `data.isLoading && homeModules.visibleOrderedModules…` | 加载态与可见模块数联动 |
| 可见模块数日志 | `TabBar.swift:1189` / `:1195` | 记录 `visibleModules` 与**扣除信箱/党建/概况/帮助后**的模块数（区分「同步型」与「懒加载型」模块） |
| 模块 → 视图 switch | `TabBar.swift:1200–1230+` | `.helpGuide` → `EmptyView()`（防御死码，L1216–1219） |
| 锚点卡可见性 | `TabBar.swift:886` `homeModules.isVisible(.helpGuide)` | 「首页管理」里关掉使用帮助 → 锚点卡消失 |
| 锚点卡可见性回写 | `TabBar.swift:931` | 日志记录 `visible` 值 |
| Debug 面板 | `TabBar.swift:10485` `@ObservedObject private var homeModuleManager = HomeModuleManager.shared`；`:10663` 显示 `visibleOrderedModules.count` | 开发期运维视图 |
| 设置页 | `HomeModuleSettingsView.swift`（150 行） | `@ObservedObject manager = HomeModuleManager.shared` (L11)；`ForEach(manager.moduleOrder)` **用 moduleOrder 而非 visibleOrderedModules**（L23，隐藏模块也要显示以便重新打开）；`.onMove(perform: move)` (L26)；`visibilityBinding` (L132) 带触觉 + `withAnimation(.spring(0.3/0.85))`；`move` (L144) 同上；`moduleSubtitle` (L125) 消费 `dataCount`；「恢复默认设置」按钮 (L46) + 确认弹窗（`showResetAlert` L14 / L35–42） |

**其他引用**：`HomeModuleManager.swift:256` / `:301` 自身的日志中也调用 `visibleOrderedModules`，属自洽引用。

### 6.6 技术债与风险点

1. **`isDefault` 与「新模块补位」语义冲突**（L279）：新增模块后 `moduleOrder == HomeModule.allCases` 恒为 false（老用户顺序末尾被追加），因此**老用户永远无法进入 `isDefault == true`**，除非手动「恢复默认」。`isDefault` 的实际语义是「顺序恰为枚举顺序且全部可见」，作为「默认状态」判定偏严格。
2. **`retiredRawValues` 只清不迁**：`campusSceneries` / `bottomBanners` 的历史顺序与隐藏状态**直接丢弃**（仅 info 日志留痕），与 `admissionNews` 的完整迁移形成不一致——用户若曾把「校园风光」排到首位，该偏好静默丢失。**这是 2026-09-24 模块合并的已知代价**，值得在 Wiki 中作为「模块退役流程」案例记录。
3. **隐藏集合落盘会 `sorted()` 而顺序键不排序**（L342 vs L351）：不对称但有意（集合无语义顺序）；副作用是隐藏键的写入字节与用户操作顺序无关，便于 diff，属正向设计。
4. **`dataCount` 跨 5 个 Store 的实时读**（L87–104）：HomeModuleSettingsView 的每行副标题都触发跨 Store 访问，且 `SchoolProfileStore.allEntries` 本身是**计算属性**（`textSections + leaders + sceneryEntries + cooperateSearchEntries`，SchoolProfileView L233，其中后两者为 `map` 转换，L237/L253）→ **一次 `dataCount` 求值 = 两次数组构造 + 一次拼接**。`.schoolProfile` 行在 List 中滚动时反复求值，属可优化点。
5. **`HomeModule` 的展示元数据（title/icon/color）与业务枚举耦合在同一文件**（L31–117）：新增模块需同时改 `enum` + 3 个 `switch` + `dataCount` + `countUnit`，**无编译期穷举保护遗漏的场景为零**（Swift `switch` 穷举保证了这一点，是正向设计），但文件会随模块数线性增长。
6. **`private init()` 无「重置到默认后清空 UserDefaults」路径**：`resetToDefaults` 走 `persistOrder`/`persistHidden` 写入默认值（L327–330），而非 `removeObject`——语义正确，但 UserDefaults 中永久保留键（无法区分「用户主动设默认」与「从未设置」）。
7. **无版本号字段**（no `schemaVersion`）：迁移逻辑全靠 rawValue 字符串嗅探（`"admissionNews"` / `retiredRawValues`），随历史增长会持续膨胀；L130–132 的退役集合是**唯一的结构化退役机制**，当前仅 2 项。
8. **`HomeModuleManager` 是唯一在类级 `@MainActor` 且日志接入 `LogManager` 的管理器**（L122 注释：「全部状态与日志在主线程访问（HomeModuleManager 的日志接入 LogManager 需主线程上下文）」）——与其余 Store（同样是 `@MainActor`）一致，但注释显式点出了「日志接入需要主线程上下文」这一**架构级约束**，值得在 Wiki 的「并发模型」章节引用。

---

## 7. 横向对比与共性结论

### 7.1 六个 Store/Manager 的形态对比

| 模块 | 隔离标注 | 单例 | init | @Published 数 | 磁盘缓存 | 详情缓存 | 已读 | 搜索历史 | 刷新状态机 |
|---|---|---|---|---|---|---|---|---|---|
| `SchoolProfileStore` | `@MainActor` | ✅ L176 | 默认 | 18 | ❌ | ✅ 内存（代际清理） | ❌ | ✅ View 层硬编码 | ✅ success(total,elapsedMs,at) |
| `PartySubjectStore` | `@MainActor` | ✅ L60 | 默认 | 8 | ❌ | ✅ 独立 Cache 类（5min TTL） | ❌ | ✅ View 层硬编码 | ✅ success(newCount,elapsedMs,at) |
| `PrincipalMailboxStore` | `@MainActor` | ✅ L24 | **`private init() {}`** L52 | 11 | ❌ | ❌ | ✅ 新增基线 | ✅ View 层硬编码 | ✅ success(newCount,elapsedMs,at) |
| `CampusCalendarStore` | `@MainActor` | ✅ L19 | `private init()` L68 | 15 | **✅ 列表 JSON** | ✅ 内存（无 TTL） | ✅ 落盘 | ✅ Store 内常量 | ✅ success(elapsedMs,total,at) |
| `HelpGuideStore` | `@MainActor` | ✅ L26 | `private init()` L47 | 3 | ❌（无需） | ❌（静态） | ✅ 落盘 + 目录对账 | ✅ Store 内常量 | ❌（无异步） |
| `HomeModuleManager` | `@MainActor` | ✅ L125 | `private init()` L140 | 2 | ✅ 顺序 + 隐藏 | — | — | — | ❌ |

**共性 1：全部 `@MainActor` + `static let shared` 单例 + `ObservableObject`**（6/6）。视图侧统一 `@ObservedObject private var store = X.shared`（非 `@StateObject`）——**生命周期归 App 而不归视图**，符合「内容缓存跨页面复用」的意图。
**共性 2：`RefreshStatus` 四态状态机**在 4 个网络模块中结构同源（`SchoolProfile` L178 / `PartySubject` L75 / `Mailbox` L78 / `Calendar` L52），差异仅在 `success` 关联值。`URLError.cancelled` 一律归 `.idle` 不展示失败横幅（4/4 一致）。
**共性 3：`refreshDetached(source:)` 独立 Task 模式**在 4 个网络模块中**逐字重复**（SchoolProfile L282、PartySubject L206、Mailbox L105、Calendar L171），`source` 参数仅供日志。→ **明显可抽象为协议扩展**（如 `RefreshableStore`），属跨模块重复代码。
**共性 4：`loadIfNeeded(force:)` + `loadTask` 防重入 + `hasLoaded` 短路**（4/4 网络模块），且都以 `LogManager.shared.debugLog(…, "拉取跳过", ["reason": "已有进行中任务"])` 记录——**文案完全一致**。
**共性 5：持久化键规范不统一**：`CampusCalendarStore` / `HelpGuideStore` 用 `private static let` 常量；`SchoolProfileView` / `PartySubjectView` / `PrincipalMailboxView` 在 View 层硬编码字符串（各 3 处）。→ **推荐以 HelpGuideStore L30–32 为范式**。

### 7.2 日志域分布

| 域 | 使用方 |
|---|---|
| `profile` | SchoolProfileStore 主链路 |
| `collaboration` | SchoolProfileStore 合作交流容错链路（**同一 Store 两个域**，便于按业务过滤） |
| `party` | PartySubjectStore |
| `mailbox` | PrincipalMailboxStore |
| `campusCalendar` | CampusCalendarStore + 视图 + TabBar 入口点击（`entry: "campus-service-grid"`） |
| `helpGuide` | HelpGuideStore + HelpGuideView + TabBar 锚点卡（跨文件同域） |
| `home_modules` | HomeModuleManager + HomeModuleSettingsView |

### 7.3 图片加载统一路径

- 四个 View 文件 **0 处 `AsyncImage`**（实测）；全部经 `SJZCachedImage`（TabBar.swift L12107 附近）+ `SJZImagePhase`（L12077）。
- 保存/分享统一经 `ProfileImageSaveShare`（SchoolProfileView.swift L2674）+ `ShareSheet`；校园日历**复用**该 enum（跨模块复用点）。
- 特殊策略：校园日历列表**不渲染缩略图**（官网列表图是占位图，文件头 L7 注释）；党建正文**剔除死图并计数**（`PartyParseOutcome.deadImageCount`）。

### 7.4 HTML 处理红线（两处一致声明）

| 位置 | 原文 |
|---|---|
| `PartySubjectView.swift:1658` | 「官网 HTML → 图文混排块序列（**纯正则，全项目禁止 NSAttributedString HTML 解析**）」 |
| `CampusCalendarView.swift:1417` | 「正文 HTML 纯正则解析（**禁 NSAttributedString HTML 解析——工程红线**）」 |

两处均为**纯正则 + `strippingHTMLTags()`**，与 `NetworkService` 的 `extractImagesFromHTML` 同源思路。**这是全项目级别的架构决策，建议在 Wiki 顶部单列一节。**

### 7.5 明确标注「未验证 / 不成立」的点

| 项 | 状态 |
|---|---|
| 校园日历的「**日期聚合与筛选**」 | **源码中不存在**。实测该模块无日期分组、无年份/月份筛选 UI、无日历视图；仅 `CampusCalendarStore.dateText` 做单条日期串规范化（Store L453）。若需此能力应标注为「未实现」 |
| `HelpSearchHit.score` 在 UI 中的实际用途 | **未验证**。HelpGuideStore L12 注释称「供列表徽章展示」，但未逐行核对 `searchResultsSection` (HelpGuideView L288) 是否消费该字段 |
| 「校园亮点」模块的原始实现细节 | **未验证**。仅确认 TabBar.swift L880 注释记录「原「校园亮点」固定区块位置」+ 2026-09-24 改造；原模块的字段/数据源已被移除，仓库中无残留代码可考 |
| `retiredRawValues` 中 `campusSceneries` 对应的历史 UI 结构 | **未验证**。仅知其为「校园风光」退役模块且内容并入「学校概况」（HomeModuleManager L130–131），原独立页面代码已不存在 |
| CampusCalendar 的 `total` 实际量级 | **未验证**（需运行或抓包）。影响「`maxPages=10` 截断导致能翻不能搜」这一风险的实际严重程度 |
| 各模块真机/运行时行为 | **未验证**。本次分析为**纯静态源码阅读**，未编译、未运行、未抓包 |
| 跨文件引用（TabBar.swift / NetworkService.swift / HomeModuleSettingsView.swift / DesignCodeApp.swift） | 仅按行号**只读引用**用于确认入口与模型定义；其内部结构由其他专题负责，未做完整分析 |

---

## 8. 建议的 Code Wiki 撰写要点（针对本模块群）

1. **以「数据来源分级」开篇**：本模块群形成三档内容供给——① 官网结构化 JSON（学校概况 `/school/intro`、合作交流 `/school/cooperate`、校长信箱 `/school/msg`）；② 栏目文章接口（风光/校企合作/党建各栏/校园日历）；③ **完全内置**（HelpContent 32 篇）。三档对应三种降级哲学：① 保留旧值 + 错误卡；② 预热 + 容错跳过；③ 零网络恒可用。
2. **单列「模块退役与迁移」小节**：`HomeModuleManager` 的 `admissionNews → helpGuide` 双键迁移 + `retiredRawValues` 清理，是仓库中**唯一的持久化 schema 演进机制**，且带 2026-09-24 模块合并的历史背景。
3. **单列「两条工程红线」**：纯正则 HTML 解析（禁 NSAttributedString）、深链导航必须在栈挂载稳定后触发（MailboxSheetRoot L1706–1709 + L1757–1758）。
4. **单列「静默失败必须留痕」范式**：Mailbox 的防御诊断（L238–244）、Party 的栏目容错日志（L409–417）、SchoolProfile 的退役值/非法值分级日志（HomeModuleManager L165–174）——三处都是「不打扰用户但必须可排查」的正面案例，且都有源码注释背书。
5. **抽象机会清单**（供重构建议）：`refreshDetached` 四份重复；`refreshStatus` 状态机四份重复；`commitSearchHistory` 三份重复；搜索历史键 9 处硬编码（3 模块 × 3 处）；`DateFormatter` 重建反模式（CampusCalendarStore L453）。
