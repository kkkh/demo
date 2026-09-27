# 校园 Tab 新增「校园日历」原生模块 — 实施计划

## Context（背景与目标）

用户要求在「校园」Tab 的「校园服务」模块（现有 6 个外链服务）中追加第七个「校园日历」入口，打开**原生**校园日历页面；要求图片支持系统级长按保存/分享、官网更新后 App 同步收到、UI 艺术品级、完整日志埋点、不影响其他模块。

**官网调研结论（真实浏览器抓包核实，100% 确认）**：
- 入口：官网「校园生活 → 校园日历」；栏目真实 column_id = `8197fe41503c4c32bce1e449d2492b2e`（与用户提供的链接一致）、site_id=1
- 内容形态：文章列表栏目（当前 total=1：《2025-2026学年第一学期校历》），**正文是一张校历大图（webp）**，列表 image_url 为占位图
- API（base 与工程 NetworkConfig.baseURL 相同 `https://gwqietap.sxjzit.edu.cn/mapi`，无鉴权）：
  - 列表 `/common/column/articles?site_id=1&column_id=<id>&page=&size=` → `data.articles.{total,list:[{id,title,description,image_url,create_time,...}]}`
  - 详情 `/common/article/detail?article_id=` → `data.{title,update_time,content(HTML,img=校历大图),image_url}`
  - 搜索 `/common/search?key_words=&p=&s=` → `data.{total,list:[{id,title,description}],hasNextPage,...}`
- 图片域 `www2.sxjzit.edu.cn:8082`（正文 http），ATS/Referer 工程已覆盖 ✓

## 决策

1. 「校园服务」追加第七项 `CampusService(name:"校园日历", icon:"calendar", url:"sxjzit://campus-calendar")`；ServiceButton 识别内部协议 `sxjzit://` 走原生 push（CampusCalendarView），其余继续外链 openURL——不触碰其他六项行为。
2. 新增 2 文件：CampusCalendarStore.swift（数据中枢）+ CampusCalendarView.swift（列表页+详情页）；pbxproj 四段注册（ID 实现时 grep 防撞，建议 DC00009F/A0/A1/A2-22D74F5700D209BE 系）。
3. 网络层复用源码级核实过的现有能力：
   - `NetworkService.fetchArticles(columnId:siteId:page:size:)`（L187，siteId 默认 "1"）与 `fetchArticleDetail(articleId:siteId:)`（L194）**直接复用**；list 元素类型= `NetworkService.ArticleDTO`（L412 已核实，含 id/title/resolvedTitle/description/imageUrl/createTime）
   - **搜索采用本地全量匹配**（不新增 /common/search 接口）：该搜索 API 是**全站**搜索、无栏目限定参数，返回全校文章与「校园日历」语境不符；本栏目数据量小（分页全量拉齐后 title/description 本地匹配），100% 可用、可橙色高亮、离线可搜——与帮助中心多词匹配同构
   - columnId 常量加 NetworkService 扩展集中管理
4. 本地缓存：列表 JSON 落盘（UserDefaults key campusCalendarCache，含拉取时间戳）+ 冷启动先展示缓存再静默刷新（缓存来源显示「离线缓存」徽章，工程惯例）；详情缓存内存字典 + 已读落盘
5. 图片长按保存/分享**直接复用** SchoolProfileView L2627 的 `ProfileImageSaveShare`（`saveToPhotos(urlString:logTag:) async -> String?`、`prepareShareItems(urlString:) async -> [Any]`）+ TabBar L2389 `ShareSheet`；不重构 profile 模块（红线：不影响其他模块）。
6. 详情正文 HTML 用**纯正则**提取 `<img src>`（工程红线：禁 NSAttributedString HTML 解析）。⚠️ 复核修正：`fixImageURLsInHTML`/`resolveImageURL`（OrganizationDetailView L3785-3896）是 **file-private 函数，不可跨文件复用**——须在 CampusCalendarView.swift 内实现同构私有纯函数（约 30 行），规则照搬：① `data:` 跳过；② http/https 绝对 URL 含非 ASCII 时 percent-encode；③ `//` 协议相对 → `http:` 前缀；④ `/xxx` 根相对 → `http://www.sxjzit.edu.cn` 拼接；⑤ 其余相对 → `baseDomain + "/" + raw`；⑥ 过滤占位图 `no_picture.webp`。**详情页布局以大图主打**（该栏目正文可能仅含一张校历大图、无长文本），标题/更新时间/大图/操作栏（复制·保存·分享）
7. **推送不接入**：栏目无稳定增量基线（total 语义不稳、正文为大图、时间字段不保证单调），增量比对不可靠；同步策略 = 进入页面自动静默刷新 + 下拉刷新 + 失败重试，`lastRefreshDate` 透出「已同步官网最新」可视证据，与校长信箱/学校概况三态惯例一致。

## 文件级改动

### 1. 新建 CampusCalendarStore.swift（@MainActor 单例，日志域 campusCalendar）
- `articles/[NetworkService.ArticleDTO]`、`total`、`isLoading`、`hasMore`、`lastError`、`refreshStatus`（三态）、`lastRefreshDate`、本地缓存读取/写入
- `loadInitial(force:)`（列表第一页，先缓存后刷新）、`loadMore()`（分页追加）、`search(keyword)`（**本地多词 AND 匹配** title/description + 权重排序，300ms 防抖，橙色高亮词返回）
- 搜索历史 UserDefaults key `campusCalendarSearchHistory`（去重置顶 ≤10）与清空
- `loadDetail(articleId:)` 详情缓存字典 + 命中日志
- 全部沉底/耗时日志：列表开始/成功(含 elapsedMs,page,total)/失败、分页三态、搜索 8 环节、详情三态

### 2. 新建 CampusCalendarView.swift
- 列表页：Liquid Glass 搜索框（聚焦描边动画，仿 PrincipalMailboxView）+ 文章卡片（**图标化卡片**：日历渐变图标块+标题+日期；因本栏目列表 image_url 官方即占位图 no_picture.webp，**不渲染列表缩略图**，避免丑占位）+ 分页触底加载（到底显示「已经到底」小字）+ 下拉刷新三态横幅（下拉刷新本体独立 Task 防取消误报——工程教训）+ 空态/失败重试卡 + 入场 stagger（spring+0.05 递增）+ 骨架屏 redacted
- 搜索：本地多词 AND 匹配 + 橙色关键词高亮（AttributedString，NSRange⇄Character 双域转换——工程红线）+ 搜索结果徽章（命中 N 篇）
- 详情页：标题/更新时间 + 正文 `<img>` 正则提取后多张大图 `SJZCachedImage(maxPixel: 1440)` 竖排 + 点击 `FullScreenImageView`（缩放拖拽）+ `.contextMenu` 系统级长按菜单（保存图片/分享 → ProfileImageSaveShare + ShareSheet + toast）+ 全文复制 + 打开失败重试；**正文无图兜底**（无 img 且 image_url 非占位时用 image_url，否则「本页暂无配图」优雅空态）
- 两页 onAppear/onDisappear 日志；详情滚动方向节流日志（3 秒，工程惯例）
- 所有字号/符号 .displayFont/.displaySymbolFont；深色自适应；VoiceOver label

### 3. NetworkService.swift
- **零新接口**：列表/详情复用既有 fetchArticles/fetchArticleDetail
- `extension NetworkService { static let campusCalendarColumnId = "..." }` 常量集中管理

### 4. Models.swift
- `defaultServices` 末尾追加校园日历项（icon 用合法的 `"calendar"`，已存在校验）

### 5. TabBar.swift
- `ServiceButton`（L5738，private struct，现有 `@Environment(\.openURL)`）：加参数 `var onInternal: ((CampusService) -> Void)? = nil`；action 头部 `if service.url.hasPrefix("sxjzit://") { onInternal?(service); 触觉+info 日志「校园日历入口点击」 } else { 原 openURL 分支原样 }`（复核确认：该改法对现有六项外链零影响）
- `CampusView`（L5325）：加 `@State private var showCalendar = false`；调用点 L5356 `ServiceButton(service: service, onInternal: { service in if service.url == "sxjzit://campus-calendar" { showCalendar = true } })`；body 顶层 ScrollView 加 `.navigationDestination(isPresented: $showCalendar) { CampusCalendarView() }`（复核确认：CampusView 位于 TabBar L165 `NavigationStack { CampusView() }` 内，push 可用）

### 6. pbxproj
- 四段注册 2 个新文件。复核确认：ID `DC00009F/A0/A1/A2-22D74F5700D209BE`（及 09E/09D 备用）全文件无碰撞 ✓；锚点：PBXBuildFile 段（参照 L55-57）／PBXFileReference 段（参照 L119-121）／主 group children（参照 L198/205）／Sources phase（参照 L363/370）。文件 path 与已注册文件同目录（qin/DesignCode 平铺）。

## 日志埋点清单（域 campusCalendar，约 25 处）
入口点击 / 页面开闭 / 列表拉取开始·成功(耗时|page|total)·失败 / 加载更多三态 / 刷新来源(source=下拉|进入|重试) 与三态横幅 / 搜索：输入开始·防抖执行·完成(命中数|耗时)·空态·聚焦失焦·历史写入·历史点击回填·一键清空 / 详情打开·加载开始·成功·失败 / 全屏图片查看 / 长按保存发起·成功·失败(原因) / 分享面板触发 / 复制全文 / 滚动方向(3 秒节流)

## 验证
1. 真机 `xcodebuild test`（set -o pipefail）→ ** TEST SUCCEEDED ** + 51/51 全绿 + 0 代码警告。**不新增在线用例**：工程教训——在线测试硬编码标题/ID/阈值，官网内容年度替换必断（校园日历文章一年一换）；本模块覆盖依赖日志闭环（campusCalendar 约 25 处埋点）+ 手动验收。
2. 手动验收：入口点击触觉+push；列表骨架→数据→空态（占位图优雅显示）；分页到底「已经到底」提示；下拉刷新三态横幅；本地搜索多词命中+橙色高亮+历史≤10 去重置顶；冷启动离线显示缓存+「离线缓存」徽章；详情校历大图正确显示（www2:8082 真机可加载）、点击全屏缩放拖拽、长按保存进相册/分享面板可用、复制全文；返回后其他六个服务项行为不变；「我的→应用日志」按 campusCalendar 域全程可溯
3. 边界：搜索无命中空态、分页越界不崩、断网失败重试卡、正文无文字仅图仍完美排版、深色模式/大字号不裁切

## 复核结论（v4 · 全部集成点代码级核实，无遗留差异）

- Models：`defaultServices` L680-687 六项确认，末尾追加第七项即全局生效（`DataService.services = defaultServices`，DataService.swift L37，无网络覆盖逻辑 ✓）
- NetworkService：`fetchArticles` L188 / `fetchArticleDetail` L195 签名确认直接复用；`ArticleDTO` L412（id/title/titleCn/description/imageUrl/createTime/updateTime/tag/sort/href + resolvedTitle）、`ArticleDetailDTO` L436（title/content/imageUrl/updateTime）、`ColumnDTO` L495（articles.total/list）字段齐备 ✓；extension 2 处（L387 APIResponse、L408 DTO），columnId 常量新增第三个 extension
- TabBar：`NavigationStack { CampusView() }` L165（push 可用）／CampusView L5325 body 顶层 L5328-5343／ServiceButton L5738（@Environment(\.openURL) 唯一边界）／调用点 L5356 ✓；`ShareSheet` L2389 ✓；`SJZCachedImage` L7587 `init(url:maxPixel:onPhaseChange:content:)`（maxPixel 1440 ✓）／`FullScreenImageView(url:title:)` L3472（自带 NavigationStack+缩放拖拽）✓；`"calendar"` SF Symbol 全工程已多处使用（L3886/4169/4627/7223…）✓
- SchoolProfileView：`ProfileImageSaveShare` L2627（`saveToPhotos(urlString:logTag:) @MainActor async -> String?`、`prepareShareItems(urlString:) async -> [Any]`、`safeURL(from:)`）确认可跨文件复用，logTag 传 "campusCalendar" ✓
- 高亮：`HelpGuideView.highlighted` L757 为 private 实例方法——CampusCalendarView 内同构复制（NSRange⇄Character 双域安全 + .sjzOrange）
- 三态惯例：`PrincipalMailboxView.RefreshStatus` L78（idle/refreshing/success/failed）确认同构；下拉刷新独立 Task 防取消误报（工程教训遵守）
- 日志：`LogManager.shared.info/debugLog/warning/error(module, message, context)` L155-164 签名确认 ✓
- pbxproj：目标 ID 无碰撞、四段锚点行号确认 ✓
- ⚠️ 唯一修正：OrganizationDetailView 的 `fixImageURLsInHTML`/`resolveImageURL` 为 file-private，不可跨文件复用 → 本地同构私有纯函数实现（规则已写入决策第 6 条）

**结论：方案完美，可开始实施。**