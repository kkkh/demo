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