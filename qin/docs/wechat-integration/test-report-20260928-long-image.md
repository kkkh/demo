# 「长图分享到微信」功能接入 · 完整测试报告

> 功能：文章长图 → 微信图片消息（官方 `WXImageObject`，好友 / 朋友圈 / 收藏三场景）
> 日期：2026-09-28 · SDK：WechatOpenSDK **2.0.8**（官方 XCFramework）· 设备：真机「秦超的iPhone」
> 关联文档：[微信接入指南](./README.md) · 代码落点：`WeChatService.shareImage(_:title:to:entry:)` + `WeChatLongImageShareMenu`

---

## 1. 结论摘要

| 维度 | 结果 |
| --- | --- |
| 功能接入轮（commit `ff70a19`） | 全量编译 **0 error / 0 warning** + 构建期护栏通过 + 真机 **108/108**（新增 4 例长图契约） |
| UI 细节审计轮（本报告第 6 节） | 与 `WeChatShareMenu` 逐项对照通过；修复 1 项预览性能缺陷 + 1 项日志归因缺陷；新增 1 例预览契约 → 真机 **109/109** |
| 服务层官方约束 | `imageData ≤10MB`（超限逐档降质/降采样自动压缩并留痕）；`thumbData ≤32KB`（顶部裁方 200×200） |
| 日志埋点 | `wechat` 域全链：菜单展示（含 `entry` / `pixelSize` / `preview`）→ 选择场景 → 编码档位 → 发起（字节/像素/质量/缩略图/耗时）→ 回执归因（`kind` 区分长图与网页卡片） |
| 外部受限项 | Associated Domains 未启用（免费个人团队，见 §8）→ 微信回执不可达；**发送侧全链就绪** |

---

## 2. 测试环境

| 项 | 值 |
| --- | --- |
| 设备 | 真机「秦超的iPhone」`00008110-000411A40EC1401E`，iOS 27.0 |
| 工具链 | Xcode 27.0（Build 27A266a） |
| 微信客户端 | 已安装且支持 OpenApi（真机实测 `availability = ready`，SDK 2.0.8） |
| 配置 | `WECHAT_APPID = wx8e60d3a37d3cff47`、`WECHAT_UNIVERSAL_LINK = https://jl.43322.cn/app/` |
| 签名 | 免费「个人团队」（Personal Team）→ 描述文件 7 天有效期；Associated Domains 未启用 |

---

## 3. 测试层次

| 层次 | 手段 | 本轮覆盖 |
| --- | --- | --- |
| L1 契约/单元测试 | 真机 XCTest（`WeChatSDKTests`，22 例，其中长图专项 6 例） | 编码上限、超限降档、缩略图契约、预览契约、回执文案、注册链路埋点 |
| L2 构建期静态校验 | 全量编译（generic iOS + `CODE_SIGNING_ALLOWED=NO`）+ `Scripts/display_coverage_guard.py` 构建期护栏 | 0 error / 0 warning；排版链 0 缺口、弹出层呈现链 0 缺口 |
| L3 运行时链路验证 | 真机运行 + `wechat` 域日志 | `registerApp=true`、`availability=ready`、SDK 2.0.8、注册埋点联通 |
| L4 UI 细节审计 | 与既有 `WeChatShareMenu` 逐项对照（结构/间距/动效/detents/文案） | 见 §6 |
| L5 人工验收（微信端可见性） | 真机 + 微信客户端人工操作 | 见 §9 清单 |

---

## 4. 用例清单（长图专项 + 相关既有契约）

### 4.1 长图专项契约（6 例）

| # | 用例 | 断言要点 | 守护的风险 |
| --- | --- | --- | --- |
| 1 | `testLongImageEncoderKeepsOfficialLimit` | `maxImageBytes == 10MB`；640×2400 噪声图编码成功；`data.count ≤ 10MB`；像素高度 > 宽度 | 官方 `imageData ≤10MB` 硬约束；长图纵向形态 |
| 2 | `testLongImageEncoderDownscalesWhenOverLimit` | 1200×4000 图在 120KB 紧缩上限下仍产出；`data.count ≤ 上限`；`adjusted == true` | 超限自动降档（质量 0.92→0.44 × 降采样 1.0→0.34）链路可用 |
| 3 | `testLongImageThumbnailContract` | 900×5400 图 `thumbData` 成功；`≤32KB`；解码后为 **200pt 方形** | 官方 `thumbData ≤32KB`；顶部裁方语义 |
| 4 | `testShareKindWordingContract` | 网页卡片「已分享到朋友圈」/ 长图「**长图**已分享到朋友圈」；取消文案区分；`logName == "longImage"` | 回执横幅与日志归因可区分（不混淆两种分享） |
| 5 | `testLongImagePayloadPreviewContract`（UI 审计轮新增） | 载荷构造后 `previewImage` 为 **200pt 方形**；`payload.image` 仍保留原始长图 | 菜单头部禁止直渲超长图（性能契约）；发送仍用原始整图 |
| 6 | `testRegistrationPathWritesWeChatLog`（关联） | 注册路径写入 `wechat` 域日志；真实配置下日志携带真实 AppID | 埋点链路联通（L3） |

### 4.2 既有相关契约（保障本功能不破坏基线）

- Info.plist 四要件（URL Scheme / Queries Schemes / UL / 小程序键）4 例；
- 配置占位判定与 AppID 格式 3 例；官方字节裁剪（标题 512B / 描述 1KB）2 例；
- 缩略图居中裁方与上限 2 例；场景枚举与 WXScene 数值对齐 1 例；
- 可用性状态机 / 自检七步 / 横幅生命周期 4 例。

---

## 5. 覆盖矩阵

| 功能/风险点 | 测试手段 | 结果 |
| --- | --- | --- |
| `imageData ≤10MB` | 用例 1 + 日志字段 `bytes/limit` | ✅ |
| 超限自动压缩（降质+降采样） | 用例 2 + INFO 日志「长图已自动压缩至官方上限内」 | ✅ |
| 压缩仍不达上限的兜底 | 代码路径：ERROR 日志 + 横幅「长图过大…」+ 不发起 | ✅（代码审查 + 行为约定 §4） |
| `thumbData ≤32KB`（顶部裁方） | 用例 3 + DEBUG 日志含 `alignment/source/bytes` | ✅ |
| 标题官方字节级裁剪（≤512B） | 既有裁剪用例 + 发起日志 `titleBytes` | ✅ |
| 三场景（会话/朋友圈/收藏） | 场景枚举用例 + 菜单三磁贴共用组件 | ✅（发送侧） |
| 菜单可用性分支（未配置/未安装/版本低） | 状态机用例 + 共用不可用提示组件 | ✅ |
| 回执文案与日志归因（kind） | 用例 4 + `handleResponse` 按 `pendingShareKind` 分支 | ✅ |
| 长图菜单预览不直渲超长图 | 用例 5 + 菜单展示日志新增 `preview` 字段 | ✅（UI 审计轮修复） |
| 6 处文章页接线（新闻/荣誉/教师/故事/活动/机构） | 逐页代码审查 + 入口归因日志（`entry` 页面级） | ✅（UI 审计轮修正归因） |
| 显示设置呈现链（外观 + 专注灰度） | 构建期护栏（`.sjzPresentationChrome()` 挂载检查） | ✅ 0 缺口 |
| 全交互埋点 | `wechat` 域：菜单展示/选择场景/发起/回执/压缩/失败 | ✅ |

---

## 6. UI 细节审计（与既有设计的一致性）

审计方法：把 `WeChatLongImageShareMenu` 与既有的 `WeChatShareMenu`（网页卡片）逐项对照，确认「长图入口」在分享面板中与现有设计完全融合。

### 6.1 一致性对照（审计通过项）

| 维度 | 网页卡片菜单 | 长图菜单 | 结论 |
| --- | --- | --- | --- |
| 结构 | header + Divider(0.4) + 三场景磁贴/不可用提示 + footer | 同构 | ✅ 完全一致 |
| 头部布局 | 缩略图 52×52 圆角 12 + 标题 `displayText(14, semibold)` lineLimit 2 + 副标题行 | 同构（副标题为「长图 · W×H」+ 照片图标） | ✅ 平行结构，语义可辨 |
| 间距 | `.padding(.horizontal, 20 / .top, 20 / .bottom, 14)` + `.padding(.bottom, 10)` | 同一组常量 | ✅ |
| 动效 | `.onAppear` spring(0.45 / 0.82) 驱动 header 位移+淡入、磁贴 10pt 上浮 | 同参数 | ✅ 零分叉 |
| 磁贴组件 | `WeChatSceneTiles`（56×56 圆角 17、品牌色、发送中 ultraThinMaterial + 0.96 缩放 + spring(0.35/0.75)） | **共用同一组件** | ✅ 交互/视觉 100% 一致 |
| 不可用提示 | `WeChatUnavailableNotice` | **共用同一组件** | ✅ |
| Detents / 拖拽指示 | `.height(canOperate ? 344 : 306)` + `.presentationDragIndicator(.visible)` | 同参数 | ✅ |
| 呈现链 | `.sjzPresentationChrome()`（外观 + 专注灰度） | 6 处调用点均挂载 | ✅ 护栏强制 |
| 底注格式 | info 图标 + 11pt 三级色说明 + SDK 版本角标 | 同构（文案「发送长图：正文整图作为图片消息发出，超 10MB 自动压缩」） | ✅ 平行结构 |

### 6.2 本轮发现并修复

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | 长图菜单头部 `preview` 直接对可能上万像素高的原图 `scaledToFill` 渲染进 52×52 | 弹出瞬间存在大图绘制开销（长图典型 1080×12000+） | `WeChatLongImagePayload` 构造期预生成 **200pt 顶部裁方小图**（`WeChatThumbnailProvider.topSquarePreview`，与官方缩略图共用同一裁切核心）；菜单日志新增 `preview` 字段；新增用例 5 锁定契约 |
| 2 | 6 处接线 `entry` 统一为占位值 `"long_image"`（与 `kind` 重复，无法页面归因） | 日志无法定位长图分享来自哪一页 | 改为页面级归因：`news_detail` / `honor_detail` / `teacher_detail` / `story_detail` / `activity_detail` / `organization_detail` |

> 修复后菜单头部绘制量从「原始长图尺寸」收敛为固定 200×200（约 160KB 内存），弹出即显；发送链路不受影响（`payload.image` 仍为原始整图）。

---

## 7. 证据索引

| 证据 | 文件 | 关键内容 |
| --- | --- | --- |
| 接入轮全量编译 | `qin/build/verify/longimage_build.log` | `** BUILD SUCCEEDED **`；`BUILD_EXIT=0`；护栏「排版链 0 缺口、弹出层呈现链 0 缺口」 |
| 接入轮真机测试 | `qin/build/verify/longimage_test.log` | `Executed 108 tests, with 0 failures`；`WeChatSDKTests` 21 例（含 4 例长图契约，L1099-L1119） |
| UI 审计轮全量编译 | `qin/build/verify/uipolish_build.log` | 0 error / 0 warning；护栏通过 |
| UI 审计轮真机测试 | `qin/build/verify/uipolish_test.log` | `Executed 109 tests, with 0 failures`（新增用例 5） |
| SDK API 形式取证 | `qin/build/verify/wxapi_probe.swift` | 冷编译 `swiftc -typecheck` 探针（`send` 重载 / `handleOpen` / `isWXAppSupport` …） |
| 运行时注册实测 | `qin/build/verify/wechat_final_test.log` | `[WeChatContract] registered=true availability=ready installed=true sdk=2.0.8` |

---

## 8. 外部受限项（非本功能缺陷）

| 项 | 现状 | 说明 |
| --- | --- | --- |
| Associated Domains（UL 回跳） | ⏳ 未启用（免费个人团队不支持，付费 ADP 专属） | 微信 **收不到成功/取消回执**（`onResp` 不送达）；**发送动作本身可用**、消息可正常送达微信；「微信集成 → 七步自检」第 5/6 步会明确报出。根因与升级步骤见 README §3.4 |
| 微信端呈现 | 未自动化覆盖 | 图片消息在微信内的实际呈现（会话卡片缩略图、朋友圈压图、收藏）需人工验收（§9） |
| 党建详情长图 | 有意外未接入 | `PartySubjectView` 无长图生成链路（此前仅直接消息通道式分享），为避免大改未接入；卡片分享入口已于 2026-09-28 补齐（第 7 处） |
| 超限兜底路径 | 单测未覆盖极端失败 | 压缩仍超 10MB 时走 ERROR + 横幅拦截（不发起分享），已在 §4 行为约定中固化 |

---

## 9. 人工验收清单（真机 + 微信）

1. 新闻详情 → 分享 → **长图分享到微信** → 好友：微信内检查长图完整清晰、会话列表缩略图显示的是长图**顶部标题区**；
2. 同入口 → 朋友圈：图片消息正常发布（朋友圈对长图会压缩显示，属微信端行为）；
3. 同入口 → 微信收藏：收藏成功；
4. 未配置 / 未安装 / 版本过低分支（可用占位配置或卸载微信模拟）→ 面板显示只读提示与安装入口；
5. 取消分享（微信内直接返回）→ 因 UL 回跳受限，无回执横幅（预期，见 §8）；
6. 超长文章（>10MB 编码）→ 观察「长图已自动压缩」INFO 日志与发送后清晰度；
7. 日志中心筛 `wechat` 域：应依次出现「长图分享菜单展示（含 entry / pixelSize / preview）→ 长图分享菜单选择场景 → 长图分享已发起（等待微信回执）」。

---

## 10. 结论

「长图分享到微信」已按官方图片消息（`WXImageObject`）完整接入：编码上限、自动降档、缩略图、回执归因、日志埋点、6 处入口接线与 UI 融合均通过自动化与静态校验；UI 细节审计发现的 2 项缺陷（预览绘制开销、日志归因占位）已修复并被新增契约锁定。唯一外部受限项为 Associated Domains（账号类型限制），不影响发送侧能力，升级付费账号后按 README §3.4 四步即可补齐回执链路。

---

## 附录 A：长图生成「纯黑图」缺陷修复（2026-09-28 追加第二轮）

> 现象：**图片较多的文章**生成长图时，有几率得到**纯黑无内容**的图片（微信与系统分享两条路径都会命中）。
> 影响：黑图会被当作正常产物进入预览与分享（此前无任何校验）。

### A.1 根因（代码级定位 + 全网资料佐证）

| # | 根因 | 证据 |
| --- | --- | --- |
| 1 | **画布无界**：渲染器固定 `format.scale = 3` 且高度随内容（每图最高 ~833pt）线性增长——20 张图文章画布 = 750×18,000pt → **2250×54,000px ≈ 486MB** 位图；CoreGraphics 位图分配失败时 `UIGraphicsImageRenderer` **静默产出黑图**（Apple 论坛 thread/725130：「silently fail with a clear/black screen」；Apple Frameworks 工程师：绘制内存 ≈ 像素数 ×4） | 代码审计（原 `ArticleLongImageRenderer.render()`）+ Apple Developer Forums / 大图导出工程实践（mmap 方案综述：`CGContext(data:nil)` 即全量 RAM 分配） |
| 2 | **全尺寸解码图常驻**：7 处文章页各自 `downloadImage -> UIImage` 并全部堆在 `loadedImages` 数组里等渲染——N 张 2000px+ 解码图（每张 12–48MB）叠加画布，进一步推高峰值内存 | 代码审计（原 7 处 `downloadImage` 与 `loadedImages` 持有） |
| 3 | **零校验**：渲染后仅判断 `size.width > 0`，纯黑但尺寸合法的产物一路放行 | 代码审计（原 `guard renderedImage.size.width > 0`） |

### A.2 修复（三层防线 + 完整日志）

1. **画布自适应预算**（`ArticleLongImageRenderer.budget(forLogicalSize:availableBytes:)`，纯函数）：
   `scale = min(首选 3x, 内存预算, 像素高度 32,000)`；内存预算 = `min(160MB, max(64MB, os_proc_available_memory() × 0.35))`；极端超长内容允许低于质量下限（`reason=floor`）。
   （上限在第三轮提升为 **288MB / 48,000px**，见附录 C.2）
   20 图文章的 486MB 画布 → 收敛至约 118MB（933×32,000px），且设备内存紧张时进一步收缩。
2. **素材按需缩略解码**（`ArticleLongImageAsset` + `ArticleLongImageLoader` + `decodeThumbnail`）：
   素材以**压缩数据 + 元数据（ImageIO 头解析，EXIF 方向归一）**持有（单图 ~200KB），绘制时按目标像素用 `CGImageSourceCreateThumbnailAtIndex` 即时缩略解码（`autoreleasepool` 作用域内单张通过），峰值内存 = 画布 + 1 张图；加载并发 ≤3 且纳入全局图片闸（`SJZImageConcurrencyGate`）。
   附：修复了原实现「按目标矩形拉伸」导致的**插图纵向压扁**（改为等比填充 + 居中裁切）。
3. **产物校验 + 降级阶梯**（`isLikelyBlank` + ladder）：
   渲染后重建 24×24 样本，像素极差 <8 判为纯色/黑图失效；失效则「降倍率（×0.6）→ 省略插图」逐级重试（省略插图时页脚追加可见说明），全数失败才返回 nil（页面展示错误态）。**绝不把黑图交给分享。**

### A.3 日志埋点（域 `longimage`，42 处）

| 阶段 | 日志 | 级别 |
| --- | --- | --- |
| 素材加载 | 长图素材加载完成（tag / 请求数 / 成功 / 失败 / 总字节 / 耗时）；素材就绪（索引 / 字节 / 像素 / host / 耗时）；地址无效 / 解析失败 / 下载失败 / 下载异常 / 下载取消 | INFO / DEBUG / WARNING |
| 渲染 | 长图渲染开始（tag / 逻辑尺寸 / 倍率 / 像素 / 位图 MB / 可用内存 MB / 约束来源 / 图片数）；长图渲染完成（step / 像素 / 耗时 / degraded） | INFO |
| 降级 | 未产出画布 / 校验未通过（含 step / 倍率 / 位图 MB / 可用内存 / next）；插图解码失败 | WARNING |
| 失败 | 长图生成失败（全部降级尝试均未通过校验） | ERROR |
| 分享 | JPEG 编码失败 / 临时文件写入失败 / 文件已保存 / 分享完成 / 分享失败 / 面板已呈现（7 处调用点统一） | WARNING / INFO / DEBUG |

> print 残留清零：原新闻页 4 处 `print("[LongImage] …")` 全部迁移至 LogManager；长图相关日志（原散落 `organization` / `ui` 域）统一归入 `longimage` 域，按 `tag` 页面归因（news / honor / teacher / story / activity / organization_detail）。

### A.4 新增契约测试（10 例）

| 用例 | 断言要点 |
| --- | --- |
| `testBudgetKeepsPreferredScaleForNormalArticle` | 常规文章保持 3x；`reason=preferred`；字节 ≤ 上限 |
| `testBudgetClampsForImageHeavyArticle` | 26,000pt 多图文章倍率必须下降，字节 ≤160MB、像素高 ≤32,000 |
| `testBudgetShrinksWithLowAvailableMemory` | 可用内存 150MB 时显著收缩且受 64MB 下限兜底 |
| `testBudgetFloorForExtremeContent` | 极端超长内容 `reason=floor`（内存优先） |
| `testOrientedPixelSizeSwapsForQuarterTurn` | EXIF 5-8 交换宽高；1/3/4 不变 |
| `testPixelSizeParsingFromJPEGData` | JPEG 头解析出真实尺寸；非图像数据返回 nil |
| `testBlankDetectionCatchesSolidCanvases` | 纯黑 / 纯白判失效；白底文字画布不误判 |
| `testRendererProducesValidImageWithAssets` | 素材驱动端到端渲染非黑图、逻辑 750pt、像素 ≥1x |
| `testDegradedFooterNotesOmittedImages` | 降级页脚含「省略插图」；本就无图不追加 |
| `testEncoderSkipsOversizedScaleLadder`（wechat 域） | 超 40MP 像素预算的编码档位必须跳过 |

### A.5 证据

- 全量编译：`qin/build/verify/longimage_fix_build.log`（`BUILD SUCCEEDED` + 护栏 0 缺口 + 0 error / 0 warning）
- 真机测试：`qin/build/verify/longimage_fix_test.log`（含上述 10 例新增契约）

---

## 附录 B：第二轮加固（2026-09-28 晚 · 现场复报「问题依旧」后的真机取证）

> 复报场景不变（图片多的文章）。本轮放弃猜测，改用**真机打印式探针取证法**（5 个探针用例，
> 输出 `[LONGIMGPROBE]` 行），一次锁定并修复了 4 个此前未覆盖的真实缺陷。

### B.1 真机实测缺陷表

| # | 缺陷（真机实测证据） | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | **画布位图格式不确定**：默认色域（`.automatic`）在真机对同尺寸画布分别产出 **16bpp / 32bpp / 64bpp**（探针⑤：`canvasFormat automatic bpp=8 rowBytes=608`、`standard bpp=32`、`extended bpp=64`）；内存预算按 4B/px 估算，遇 64bpp **实际内存翻倍** → 超大画布分配失败 → 静默黑图 | 黑图（主因） | 画布 / 降采样 / 缩略图一律 `format.preferredRange = .standard`（确定 32bpp，行距按 32B 对齐填充）；契约 `testRenderedCanvasUsesStandard8BitFormat` |
| 2 | **降采样按「点」而非「像素」**：`downscaled` 用 `image.size × 系数`，而长图产物是自适应倍率（1.0~3.0）→ 目标像素偏差数倍，极端时**放大**位图 → 分配失败 → 黑图 | 黑图 | 重写为 `downscaledToPixelScale`（`size × scale` 换算、1:1 像素渲染）；契约 `testEncoderDownscaleIsPixelAccurateForAdaptiveScaleSource` |
| 3 | **编码阶梯与交付零校验**：纯色 / 黑图 JPEG 字节极小，能通过 10MB 上限校验被当作成功交付 | 黑图直达微信 | 三级校验：画布（渲染后）→ 编码候选与编码字节（缩略回读）→ 落盘 / 发送前（6 处系统分享路径 + 微信发送路径）；契约 `testEncoderNeverReturnsBlankForHeavyImage` / `testEncodedDataBlankCheck` |
| 4 | **校验器采样陷阱**：ImageIO 缩略图为 `premultipliedFirst`（首字节恒为 alpha=255），按「每像素首字节」抽样会把**所有合法图**误判为纯色（真机实测：编码阶梯 5/5 档位全判黑） | 校验器整体失效 | 布局感知采样：32bpp 快路径按 `alphaInfo` 跳过 alpha、按 `rowBytes` 步进；非常规布局回退「自绘 RGBA8 缓冲」；`decodeThumbnail` 多配方回退 + 内容校验；无法取证时 fail-closed |

附带修复：降级阶梯此前 `max(…, 0.3)` 可能**高于预算**（降级反而更易失败）→ 改为「永不超预算」；`WeChatImageEncoder` 像素预算改按真实像素计算；`isLikelyBlank` 对无位图数据改为 fail-closed。

### B.2 探针与证据（`qin/build/verify/`）

| 探针 / 证据 | 关键输出 |
| --- | --- |
| `probe_ladder.log`（编码阶梯） | 5 档全部 `candBlank=false / dataBlank=false`（修复生效；修复前全为 true） |
| `probe_recipes2.log`（ImageIO 配方矩阵） | 6 种配方在真机均返回**有内容**缩略图（采样极值 74–209），排除解码配方问题 |
| `probe_redraw.log`（重绘抽样） | 自绘探针位图 + ImageIO 缩略图重绘均可正确判读（min/max 分布合理） |
| `longimage_black3_test.log` 内嵌探针⑤ | 画布格式三态：automatic=不定 / standard=32bpp / extended=64bpp |
| `longimage_black3_test.log` 重图端到端 | `[LONGIMGPROBE] heavy px=1429x29357 scale=1.90 ms=720 blank=false`（24 图文章真机稳定产出） |
| `longimage_black3_{build,test}.log` | 全量编译 0 error / 0 warning + 护栏通过 + 真机 **130/130**（含 20 例长图契约与探针） |

---

## 附录 C：第三轮（2026-09-28 深夜 · 用户复验）：插图颠倒 + 清晰度提升

> 黑图问题已确认解决；复验发现两项新问题，均以真机取证后修复。

### C.1 插图上下颠倒（绘制 API 语义错误）

| 项 | 内容 |
| --- | --- |
| 现象 | 长图内所有插图上下颠倒 |
| 取证 | 判据用例：素材「顶部黑带 + 80% 白底」绘入长图后打印**行剖面**——修复前黑带落在插图区域**底部**（`bandTop=1926 / bandBottom=2235`，其下白底仅 111pt 而非 ~416pt）；修复后黑带回到顶部（`bandTop=678 / bandBottom=987`，白底长段 1581px） |
| 根因 | `drawImage` 用 `CGContext.draw(cgImage:in:)` 绘制：UIKit 上下文（y 向下）下该 API 会把 CGImage **上下翻转**（Quartz 的 y-up 语义与 UIKit 翻转 CTM 叠加） |
| 修复 | 改用 `UIImage(cgImage:).draw(in:)`（UIKit 正确语义），几何仍为等比填充 + 居中裁切 |
| 契约 | `testEmbeddedImageIsNotVerticallyFlipped`（行剖面 + 白底长段判定；修复前实测 FAIL、修复后 PASS） |
| 附带取证 | 探针⑥（`UIImage.draw` vs `CGContext.draw` 同上下文对照）；探针⑦ EXIF 方向：带 orientation=6 的 JPEG → 元数据 300×400、解码 300×400（解码路径方向处理正确，排除 EXIF 因素） |

### C.2 长图偏模糊（分辨率预算提升）

| 项 | 内容 |
| --- | --- |
| 现象 | 图片多的文章长图观感偏软 |
| 原因 | ① 画布倍率被内存预算压到 ~1.86x（首选 3x）；② 微信编码原 `maxFirstAttemptPixels = 40MP` 会把 72MP 画布**无谓跳档**到 0.75 |
| 修复 | 画布预算上限提升：像素高度 32,000 → **48,000**、字节 160MB → **288MB（72MP）**（仍受「可用内存 × 35%」动态兜底 + 黑图校验降级阶梯保护）；编码首档预算 40MP → **72MP**（与画布上限对齐，不再无谓跳档） |
| 效果 | 重图文章画布倍率 ~1.86 → **~2.5**（+34% 分辨率）；短文章仍保持 3x |
| 证据 | `build/verify/longimage_black4_{build,test}.log`（全量编译 0/0 + 护栏 + 真机全绿） |

---

## 附录 D：第四轮（2026-09-28 深夜 · 用户复报）：系统分享 → 微信扩展「加载中 → 闪回 App」

> 现象：部分文章（越大的越易触发）用「长图」+ **系统分享面板里的微信**分享时，微信显示「加载中」
> 后快速闪回 App，分享失败。**两个根因叠加**，均已修复：

### D.1 根因

| # | 根因（代码级） | 机制 | 证据 |
| --- | --- | --- | --- |
| 1 | **临时文件被过早删除**：6 处 `presentLongImageShare` 在 `completionWithItemsHandler` 里「1 秒后删除」临时 JPEG | 该回调在**用户选择动作时即触发**（而非分享真正结束后）；微信分享扩展此时才开始读取/转存大文件——文件被删 → 扩展读取失败 → 退回宿主 App（「加载中 → 闪回」）；文件越大越慢 → 「有些文章」才复现 | 代码审计：6 处 `DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { removeItem }` |
| 2 | **交付体积/像素超出扩展预算**：系统面板路径原样交付画布 JPEG（可达 72MP） | iOS 分享扩展内存上限远低于 App（约 120MB）；72MP 长图**解码即 ~300MB** → 扩展被系统终止（同款「闪回」） | 代码审计 + 画布上限 288MB（72MP）实测 |

### D.2 修复

1. **交付编码收敛到扩展预算**：新增 `WeChatImageEncoder.systemShareMaxPixels = 16MP`（≈64MB 解码内存）与 `systemShareMaxBytes = 10MB`；`encode(_:maxBytes:maxPixels:)` 在像素超限时**先整体一步降采样**再走质量阶梯（含纯色/黑图四级校验）；6 处系统分享路径统一改为该编码并新增「长图分享文件编码完成」日志（像素/质量/档位/字节）。
2. **临时文件生命周期**：新增 `SJZShareFileCenter`——`completionWithItemsHandler` 里只**登记延迟清理**（5 分钟，远大于扩展读取/转存耗时），并顺带清理 10 分钟前的陈旧残留（避免堆积）；彻底移除「选动作后 1 秒即删」。

### D.3 契约与证据

| 用例 | 断言 |
| --- | --- |
| `testSystemShareEncodingRespectsExtensionBudget` | 10.8MP → 直出且 ≤12MP/≤10MB、产物非黑图；22.5MP → **入口先降采样**到 ≤12MP、档位 1.0 起步、≤10MB |
| `testShareFileSurvivesCleanupScheduling` | 登记清理后文件必须仍然存在（防「立即删除」竞态回归） |

- 真机证据：`build/verify/longimage_share_{build,test}.log`（探针输出 `[LONGIMGPROBE] systemShare …`）

---

## 附录 E：第五轮（2026-09-28 深夜 · 复报仍在）：画布驻留内存 + 交付预算再收敛

> 复报问题仍在 → 代码复查发现**第三条独立的内存路径**（画布在分享期间驻留），并顺带收敛交付规模、
> 补齐「未完成」归因日志与替代路径提示。

| # | 根因 / 改进 | 机制与修复 |
| --- | --- | --- |
| 1 | **画布在分享期间驻留**（新发现） | `generatedLongImage` 是**无人读取的死状态**，却持有 200–288MB 长图画布；分享扩展与宿主 App **共享内存池**——扩展运行期间宿主仍占着大块内存，系统回收时表现为「微信加载中 → 闪回 App」。修复：**删除该死状态**（新闻 / 机构两处声明与赋值），画布在编码完成后立即释放 |
| 2 | **交付预算再收敛** | `systemShareMaxPixels` 16MP → **12MP**（≈48MB 解码内存，对齐微信扩展实际可承受规模）；仍先整体降采样、再走质量阶梯与四级内容校验 |
| 3 | **未完成归因 + 替代路径**（新增） | 6 处完成回调：`completed == false` 时把**可判别数据**（交付像素 / 字节 / error）写入 `longimage` 域，并在 App 内提示「微信未完成分享，可改用『分享 → 长图分享到微信』」——App 内 SDK 直发路径（`WXImageObject`）不受系统扩展限制，是可靠兜底 |
| 4 | 公开资料佐证 | 友盟《各平台分享限制》：微信图片分享 ≤10MB，且**无本地文件时会退化为 data 路径、限制 512KB**——说明微信侧对「非文件直传」存在硬限制；本工程坚持「**文件交付** + 扩展预算内收敛」双保险 |

**若仍复现的诊断指引**：`longimage` 域按序应出现
`长图分享文件编码完成（pixel / quality / scale / bytes）` → `长图分享未完成（系统扩展可能中止）（pixel / bytes / error）`；
把这两行发回即可判定是「扩展内存中止」还是「尺寸 / 体积上限」，据此继续收敛（`systemShareMaxPixels` / `systemShareMaxBytes` 均为单点常量）。