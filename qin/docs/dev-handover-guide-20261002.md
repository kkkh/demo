# 「园枢」独立接手开发指南（2026-10-02）

> **用途**：让一位新开发者（或隔了很久回来的你）在最短时间内具备独立修改、排查、验收、发布「园枢」App 的能力。
> **依据**：全量通读（50 主文件 + 6 测试 + 3 配置逐行）+ code-wiki 七分册（基线 `215ea30`）。所有行号均可复现。
> **配套**：深度理解交付（会话内）、code-wiki/ 七分册、qin/PROJECT_UNDERSTANDING.md。

---

## 0. 30 分钟上手路径

1. 读 [code-wiki/README.md](../code-wiki/README.md)（速览 + 缺陷 Top10）
2. 读 [01-项目整体架构](../code-wiki/01-项目整体架构.md)（§1.5 启动流程、§1.6 六条链路必读）
3. 读 [05-项目运行方式](../code-wiki/05-项目运行方式.md)（§5.4 把 App 跑起来）
4. 看本指南 §3 架构地图 + §4 核心链路
5. 在真机上跑一次（§2 环境准备）

---

## 1. 项目本质（心智模型）

**一句话**：一个**无服务端的纯客户端信息聚合 App**——用「客户端轮询 + 本地指纹比对」替代服务端推送，用「URLProtocol 全局拦截」替代服务端遥测，用「三层降级（远程 → 本地 JSON → 静态兜底）」替代服务端高可用。

| 事实 | 值 |
|---|---|
| 名称/工程 | 「园枢」/ `DesignCode`，Bundle `com.qinchao` |
| 技术栈 | Swift 5（pbxproj 四处 `SWIFT_VERSION=5.0`）、纯 SwiftUI、iOS 26.0+ |
| 第三方依赖 | **仅 1 个**：微信开放平台 SDK 2.0.8 |
| 后端 | **无**（数据源=学校公开 API `gwqietap.sxjzit.edu.cn/mapi` + 博客 `www.43322.cn`） |
| 调试设备 | 真机「秦超的iPhone」（UDID `00008110-000411A40EC1401E`），**禁用模拟器路径** |

**最重要的三件事**：
1. 无服务端推送 = NotificationManager 5+1 通道轮询 + 基线 diff（改通知前先读 §6 铁律②）
2. 深链防崩溃调度 = @Published 状态驱动 + 错峰时序（改深链前先读 §6 铁律③）
3. 零闪烁图片管线 = SJZCachedImage init 同步查内存缓存（改图片前先读 §5.9）

---

## 2. 环境准备

### 2.1 前置
- macOS + Xcode 27（含 iOS 26 SDK）
- 实体 iPhone 连接并「信任此电脑」；`xcrun devicectl list devices` 应显示 available/paired

### 2.2 签名（**关键约束**）
- 当前为**免费个人团队**（Chao Qin），描述文件 **7 天过期**——超过 7 天必须重新构建安装，否则 App 打不开
- 免费团队**无法启用 Associated Domains** → 微信 Universal Link 不可用（分享可发、回执不可达）
- 工程 `CODE_SIGN_ENTITLEMENTS` 关闭（不生成 entitlements 签名）

### 2.3 微信配置（若换账号）
- 单点配置在 Target 构建设置：`WECHAT_APPID`（wx8e60d3a37d3cff47）、`WECHAT_UNIVERSAL_LINK`、`WECHAT_UL_HOST`（jl.43322.cn）、`WECHAT_MINI_PROGRAM`（占位）
- **禁止代码硬编码**；未配置（isPlaceholder）时微信入口只读、不发请求
- AppSecret 严禁入库（仅存 `qin/.secrets/`）

### 2.4 构建/安装/启动（一行流）
```bash
cd qin
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode -configuration Debug \
  -destination "platform=iOS,id=00008110-000411A40EC1401E" \
  -derivedDataPath build/device-dd build
xcrun devicectl device install app --device 00008110-000411A40EC1401E \
  build/device-dd/Build/Products/Debug-iphoneos/DesignCode.app
xcrun devicectl device process launch --device 00008110-000411A40EC1401E com.qinchao
```
> 真机验收一条龙另有 `qin/Scripts/device_display_verify.sh` 等 14 个脚本（见 §9）。

### 2.5 三远端
- `origin`(GitHub) / `gitee` / `cnb` 三远端同 main；推送用 `qin/Scripts/push_all.sh`（永不 force push）

---

## 3. 架构地图

```
视图层（SwiftUI）── TabBar.swift 51 个 View + 各内容页文件
    ↕ @Published / ObservableObject（33 个单例 Store）
数据层 DataService（唯一入口、三层降级、doFullSync 串行）
    ↕ 委托
网络层 NetworkService（19 方法/15 条 API、双 session、取消红线）
    ↕ URLProtocol 拦截
RefererHeaderURLProtocol（防盗链 + 图片 7 天缓存头 + 遥测 TTFB）
```

### 3.1 模块分级（精力分配）

**【核心】**：TabBar.swift(13,992) / DataService / NetworkService / 机构模块(7 文件 12,146) / NotificationManager / MessageCenterStore+View / DisplaySettingsManager+View / LogManager / 图片管线(TabBar 内)

**【支撑】**：BookmarkManager / CacheModeManager / BiometricSecurityManager / SJZNetworkMonitor / WeChatService / Models / RefererHeaderURLProtocol / SchoolProfileView / PrincipalMailboxView / PartySubjectView / CampusCalendar / Announcement / HomeModule / HelpGuide / ReadStatus / PrivacyManager

**【边缘】**：SplashView / NotificationTestView(调试) / 各设置子页 / Scripts / Assets / 测试

### 3.2 五大 Tab → 文件映射

| Tab | 根视图 | 位置 |
|---|---|---|
| 首页 | HomeView | TabBar.swift:565 |
| 院系 | DepartmentsView | TabBar.swift:7664 |
| 资讯 | NewsListView | TabBar.swift:7943 |
| 校园 | CampusView | TabBar.swift:8240 |
| 我的 | ProfileView | TabBar.swift:10154 |

---

## 4. 核心链路（接手后必须能徒手画出）

### ① 启动链路
`DesignCodeApp.swift @main` → init 同步（URLCache 80MB/400MB → 注册 URLProtocol → 内存警告 → 图标校准）→ ZStack 五层（MainTab 0/Splash 1/隐私 2/受限 3/生物锁 4/微信横幅 3.5）→ 1s 后 isAppReady → 隐私门控分流 → `privacyConsentAccepted` 后**才注册微信**(:159-167) → MainTabView `.task` 500ms 后 `data.syncIfNeeded()`(TabBar:239-242)

### ② 数据同步链路
`DataService.doFullSync`(:243) → **串行** home2/head/foot（三独立 do/catch）→ 新闻五栏目串行全量 → 视频详情并行(withTaskGroup:364) → saveCache 21 键 → 失败降级本地 JSON → 兜底静态数据

### ③ 通知深链链路
`UN 点击 → NotificationManager.handleNotificationTap(:1101) → pendingDeepLink(UUID) → TabBar.onChange(:306) → consumePendingDeepLink(:52) 预加载 → scheduleNotificationArticlePresentation(:135) 等前台+解锁≤3s → 让 350ms → sheet(item:)`
> 机构动态 4 路补发（onAppear/onChange/回前台/Face ID 解锁）+ 消息中心退场 3s 新鲜窗口 + 550ms 错峰。

### ④ 图片加载链路
`SJZCachedImage`(TabBar:12415) → init 同步查解码缓存（命中首帧直出）→ 磁盘缓存直读+坏条目清理 → 并发闸(actor≤4) → 网络（重试 1s/3s×2）→ 下采样 720px（列表）/1440px（详情）→ blur-up 平均色占位；滚动暂停(800ms 等待)

### ⑤ 文章详情链路
`列表点击 → EnhancedNewsDetailView(TabBar:3063) → DataService.fetchArticleDetail(:848) → NetworkService(:250) → 缓存策略按 useCache 切双 session → 渲染 + 阅读统计 + 已读标记 + 长图分享可选`

---

## 5. 核心模块精读要点

### 5.1 TabBar.swift（13,992 行）——最危险也最重要
- 51 View / 89 顶层声明全在此；**改它先搜全文件影响面**
- 深链中枢：`:52-195`（读懂防崩溃三件套：状态驱动/等待活跃+解锁/错峰 sleep）
- 调试面板 `showDebug`(:17, :244-295)——**无 #if DEBUG，会随 Release 出海**
- 图片管线核心：SJZCachedImage(:12415)/SJZImageKit(:12674)/解码缓存(:12901)/并发闸(:12966)
- 已知坑：5 个详情页重复代码、CampusView 死代码(:8365-8573)、深链时序硬编码

### 5.2 DataService（1,332 行）——数据唯一入口
- `doFullSync` 永不抛出；三层降级；缓存键 21 个
- **坑**：无 Task.isCancelled（下拉刷新取消会继续跑）；`clearCache()` 漏删 specialty.json

### 5.3 NetworkService（1,748 行）
- 15 条 API / 19 方法 + post + 2 fetchJSONDict 重载；DTO 全 Optional + 显式 CodingKeys
- **取消红线**：`:102/153/201` URLError.cancelled 不重试不记 ERROR（改重试逻辑必须三处同步）
- `APIResponse.code` 从不读取（仅 queryRecruit:1666 例外）
- `fetchArticleDetailWithHref`(:258) 是 dead code，别被它误导

### 5.4 NotificationManager（1,283 行）——无服务端推送
- 5+1 通道：新闻(:322)/信箱(:439)/概况指纹(:532)/党建指纹(:682)/机构动态(:761) + 收藏(BookmarkManager 事件)
- **基线先行**：首轮只登记不推送（防历史轰炸）
- **已知缺陷**：`Set.suffix(2000)` 无序裁剪(:160/169/179) 会丢新 ID——改这里优先修
- 三通道发送失败标记行为不一致（:421/:513 vs :826）

### 5.5 机构模块（最复杂业务）
- 九形态栏目 classify（OrgContentIndex:49-88）；`OrgRequestGate` actor≤3
- 文章详情「并行多 siteId 提前取消+最长择优」(:5559-5665)
- 师资列接口 500 已知；**RSA 招生查询未完成**（UI 收口官网）
- 搜索 total 驱动全量 + 200 页安全上限

### 5.6 消息中心
- 毫秒时间戳 id 防同秒冲突；导入 24h 窗口（当天未读/更早已读）；深链补全进 save 条件
- `setBadgeCount` 注释「双路径」实际只调 UN

### 5.7 显示设置（全局排版链）
- 三套出口：displayFont 家族化 / Appearance 桥 / DisplayUIFontFactory(UIKit 直绘)
- **字体下载只认 PostScript 字面名**；看门狗 60s；typographyRevision 驱动全 App 重算
- 构建护栏 `display_coverage_guard.py`：新增 UI 必须走 display* 链 + `.sjzPresentationChrome()`

### 5.8 LogManager（1,073 行）
- 40 域 / 五级 / 日轮转 / **单日 1000 条硬上限**（高活跃 3 分钟写满！）
- 验收取证必须在操作后 1~2 分钟内拉日志

### 5.9 图片管线
- 零闪烁=init 同步查缓存；并发闸≤4（发起前闸控）；坏条目自愈；取消静默

---

## 6. 工程铁律（改代码前必读）

1. **取消语义红线**：cancelled/CancellationError/Task.isCancelled 一律静默——不告警、不重试。任何新网络调用都要继承
2. **基线先行**：新通知通道必须「首轮只登记基线，不推送」，否则升级即历史轰炸
3. **`sheet(item:)` 单状态呈现**：禁用 `bool+item` 双状态（会白屏/竞态）；全屏图用 `.fullScreenCover(item:)`
4. **排版链护栏**：文本/图标一律 `displayFont/displayText/displaySymbolFont/displayLabelFont`，禁止裸 `.font(`；每个 `.sheet/.fullScreenCover` 内容根挂 `.sjzPresentationChrome()`；违反构建即失败
5. **日志域化**：新增日志必须走 LogManager 指定域（模块短名）；WARNING 只留给「待处理真异常」
6. **隐私门控**：微信注册等敏感能力必须在 `privacyConsentAccepted` 后；受限模式完全跳过
7. **图片缓存头规则**：仅 2xx + 图片 + 无 no-store 才注入 7 天缓存（URLProtocol 层自动做，别手写）
8. **HTML 转纯文本**：全项目禁止 NSAttributedString(html:)，用纯正则 `strippingHTMLTags()`
9. **深链防崩溃**：禁止在系统通知回调同步链中直接弹 sheet
10. **新功能必须接入日志**：全交互埋点（含复制/已读/滑动等）
11. **App 图标切换**：仅用户显式操作+系统确认弹窗，禁止后台切换
12. **三远端推送**：用 `push_all.sh`，永不 force push

---

## 7. 常见任务手册

### 7.1 新增一个 API
1. NetworkService 加 DTO（Optional + CodingKeys）→ 加 `fetch*` 方法（取消红线三处模板照抄）
2. 若需缓存头 → 无需改，URLProtocol 自动注入
3. 若需遥测 → 无需改，URLProtocol 自动 tap
4. 更新 code-wiki/06 接口表

### 7.2 新增一个通知通道
1. NotificationManager 加 check 方法（抄机构通道 :761-871 模式）
2. **基线先行**：加基线键 + 首轮只登记
3. 加 `notified*` 集合（**别用 Set.suffix 裁剪**，改用排序数组）
4. TabBar 加 pendingDeepLink 消费分支 + 错峰时序
5. MessageCenterStore MessageKind 加 case（若需入盒）
6. 真机验收（§9）

### 7.3 新增一个页面
1. 放哪个文件？**优先新建文件**，别往 TabBar 塞（13,992 行已是债）
2. 文本走 display* 链、弹层挂 .sjzPresentationChrome
3. 数据走 DataService/Store 单例，别裸调 NetworkService
4. 埋点日志域

### 7.4 发版流程
1. 真机全量测试（241 用例 + 验收脚本）
2. Release 构建并量体积（Debug 有 94MB dylib，Release 小一个量级）
3. **处理调试面板**：NotificationTestView/TabBar 调试面板无 #if DEBUG，发版前确认是否要包
4. 三远端推送 + 描述文件 7 天提醒

---

## 8. 故障排查手册

| 症状 | 排查顺序 | 关键位置 |
|---|---|---|
| 收不到通知 | ① 权限 isAuthorized → ② 日志 notification 域（是否检测到）→ ③ 基线键是否误初始化 → ④ notified* 集合是否被 Set.suffix 污染 → ⑤ delivered=false 是否误标 | NotificationManager:322-871 |
| 点击通知白屏/闪退 | ① 深链是否走了状态驱动（禁止回调同步链弹 sheet）→ ② 错峰时序 → ③ 消息中心退场窗口 | TabBar:52-195 |
| 图片不显示/闪 | ① 内存缓存限额（96/40MB）→ ② 滚动暂停 800ms → ③ 坏条目 → ④ 并发闸拥塞 | TabBar:12415-12985 |
| 字体「一直下载中」 | ① 是否传 PostScript 字面名（禁传家族名）→ ② 看门狗 60s 是否复位 → ③ 终态实查 | DisplaySettingsManager:1257-1476 |
| 日志找不到/太短 | 单日 1000 条上限，高活跃 3 分钟写满——操作后 1~2 分钟内拉取 | LogManager.swift |
| 微信分享回执丢失 | 免费团队无 UL → 双回跳通道都失败 → 预期行为，改配置才能修 | WeChatService:756-768 |
| 某栏目一直失败 | 师资列接口 500 已知 → 容错跳过；检查是否 teacher 型栏目 | OrgContentIndex:29 |

---

## 9. 测试与验收

### 9.1 测试结构（241 用例 / 15 类 / 6 文件）
- 覆盖：DTO 解码、日志、收藏、机构九形态、微信裁剪、消息中心、看图几何/翻页
- **4 处在线脆弱用例**（断网必挂）：NetworkServiceDTOTests:396/443/466 + MessageCenterStoreTests:886
- **核心未测**：图片管线零闪烁、深链端到端、字体状态机纯逻辑、通知指纹 diff——改动这些**必须真机验证**

### 9.2 验收脚本（qin/Scripts/，14 个）
- `device_display_verify.sh`：显示排版全链（--wait/--skip-install/--no-launch/--tests）
- `org_module_acceptance.sh` / `org_forms_acceptance.sh` / `org_visual_acceptance.sh` / `org_article_sheet_acceptance.sh` / `news_fullsync_regression.sh`：机构/新闻真机验收
- `push_all.sh` / `remote_sync_report.sh`：三远端

### 9.3 真机验证铁则
- **构建/测试/调试只针对真机**（UDID 固定），不用模拟器
- 验收取证：构建 → 安装 → 启动 → 操作 → **立即**拉沙盒日志（`devicectl device copy from`）→ 断言 → 报告
- 日志在 `Documents/SXJZIT_Cache/Logs/log_<日期>.json`，1000 条上限

---

## 10. 技术债清单（接手后优先级）

| 优先级 | 事项 | 位置 |
|---|---|---|
| P0 | 调试面板/NotificationTestView 无 `#if DEBUG`（Release 出海） | TabBar:244-295 / NotificationTestView.swift |
| P0 | `exit(0)` 违反审核 2.5.4 | PrivacyPolicyView.swift:764 |
| P0 | `Set.suffix` 无序裁剪（丢通知） | NotificationManager:160/169/179 |
| P1 | 数据层 0 处 Task.isCancelled | DataService / NetworkService |
| P1 | 三通道发送失败标记不一致 | NotificationManager:421/513 vs :826 |
| P1 | TabBar 13,992 行单文件拆分（5 详情页重复 + 死代码） | TabBar.swift |
| P1 | 深链错峰硬编码 sleep（300/350/400/550ms） | TabBar:119/184 |
| P2 | `setBadgeCount` 注释与实现不符 | NotificationManager:1259-1282 |
| P2 | 19 处 print 残留未走日志 | DataService(8)/NetworkService(5)/NotificationManager(6) |
| P2 | `clearCache` 漏删 specialty.json | DataService.swift |

---

## 11. 交接注意事项（容易踩的隐形坑）

1. **描述文件 7 天过期**：免费团队，超期 App 直接打不开，需重装
2. **微信 UL 不可达**：免费团队无 Associated Domains——分享发送可用、回执不可达，非 bug
3. **日志窗口极短**：任何取证动作要在操作后 1~2 分钟内完成
4. **`-disable-sandbox` 旗标**（pbxproj:641/689）：影响 Swift 编译器插件沙箱，行为未实测，慎动
5. **ATS 例外**：`sxjzit.edu.cn` 允许明文 HTTP（NSExceptionDomains），外链网页用 NSAllowsArbitraryLoadsInWebContent 豁免——别全局放行 ATS
6. **Swift 6 迁移已放弃**：维持 `SWIFT_VERSION=5.0`，勿再尝试（5 处 #MutableGlobalVariable 是拦路虎）
7. **未决项（接手后可查）**：queryRecruit RSA 公钥（需官网真机取证）、party「师资/首页」栏目 500 根因、微信 UL 升级付费团队后的重连验证

---

## 12. 文档维护约定

1. 改功能同步更新 code-wiki：02 模块章节 + 03 签名表 + 04 持久化键 + 07 类型索引
2. 07 为机械生成，用脚本重抽，勿手改表格
3. 新增调用链时序图放 `code-wiki/mermaid/chain-<字母>-<短名>.mmd` 并在 README 登记
4. 新发现缺陷 → 登记 code-wiki/README「已知缺陷速查」+ 本指南 §10
5. 本指南与 code-wiki 冲突时，以 code-wiki（基线对齐）+ 源码为准
