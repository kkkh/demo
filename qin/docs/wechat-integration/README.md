# 微信开放平台（WeChat OpenSDK）接入指南 · 园枢 iOS

> 依据官方文档实现：[SDK 下载页](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Downloads/iOS_Resource.html) ·
> [iOS 接入指南](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/iOS.html) ·
> [分享与收藏](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Share_and_Favorites/iOS.html) ·
> [微信登录](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/WeChat_Login/Development_Guide.html) ·
> [小程序跳转](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Launching_a_Mini_Program/Launching_mini_program_by_app.html) ·
> [Universal Link](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Universal_Link.html)
>
> SDK 版本：**OpenSDK 2.0.8（官方 XCFramework，含支付能力）**，位于 `qin/Frameworks/WechatOpenSDK.xcframework`

---

## 0. 配置单点（TL;DR）

代码已全部就绪，**只需填写 4 个构建设置**（`Debug` 与 `Release` 各一份），Info.plist 与 entitlements 通过 `$(...)` 自动注入：

| 构建设置 | 当前值 | 含义 | 说明 |
| --- | --- | --- | --- |
| `WECHAT_APPID` | `wx8e60d3a37d3cff47` ✅ 已落地 | 移动应用 AppID（同时作为 URL Scheme） | 与微信开放平台后台一致 |
| `WECHAT_UNIVERSAL_LINK` | `https://jl.43322.cn/app/` ✅ 已落地 | Universal Link | 必须与后台填写值完全一致 |
| `WECHAT_UL_HOST` | `jl.43322.cn` ✅ 已落地 | 关联域名（entitlements 用） | `applinks:jl.43322.cn` |
| `WECHAT_MINI_PROGRAM` | `gh_PLACEHOLDER0000` ⏳ 待填 | 小程序原始 ID（仅小程序跳转需要） | 未填则小程序入口只读提示 |

> 应用官网 / Bundle ID（iPhone 与测试同为 `com.qinchao`）/ Team：`https://jl.43322.cn` · `F2JL9GNLCC`
> **AppSecret 不入库**：仅存本机 `qin/.secrets/wechat-credentials.env`（已被 `.gitignore` 排除），只用于**服务端**换取 access_token，客户端不得接触。
> **外部状态（2026-09-28）**：AppID / Universal Link / 域名 ✅ 已落地；AASA ✅ 已部署且 Apple CDN 已收录；**唯一缺项 = Associated Domains 能力**，受限于签名团队为免费「个人团队」（需付费 ADP，详见 §3.4）——影响面：分享/登录的 UL 回跳与回执不可达（发送动作本身可用）。

---

## 1. 已实现能力矩阵

| 官方能力 | 代码落点 | 说明 |
| --- | --- | --- |
| 分享到会话 / 朋友圈 / 收藏 | `WeChatService.share(_:to:)` | 网页卡片（标题 ≤512B、摘要 ≤1KB、缩略图 ≤32KB 自动生成） |
| 分享菜单 UI | `WeChatShareMenu` | 文章详情「分享 → 分享到微信」，三场景磁贴 + 不可用状态提示（**7 处入口**：新闻 / 荣誉 / 教师 / 故事 / 活动 / 机构 / 党建文章详情，2026-09-28 补齐党建详情） |
| **长图分享到微信** | `WeChatService.shareImage(_:title:to:entry:)` + `WeChatLongImageShareMenu` | **WXImageObject 图片消息**（正文整图，官方示例即覆盖三场景含朋友圈）：`imageData ≤10MB`（超限自动降质/降采样并留痕）、`thumbData ≤32KB`（缩略图锚定长图顶部标题区）；分享面板新增「长图分享到微信」入口（**6 处**：新闻 / 荣誉 / 教师 / 故事 / 活动 / 机构）；菜单头部预览为载荷构造期生成的 **200pt 顶部裁方小图**（防超长图直渲），`entry` 页面级归因（news/honor/teacher/story/activity/organization_detail）；**编码候选与编码字节均过 `SJZImageIntegrity` 内容校验（纯色 / 黑图一律拦截并降档重试）**——完整测试报告见 [test-report-20260928-long-image.md](./test-report-20260928-long-image.md)（附录 B：黑图两轮根治取证） |
| 微信登录 | `WeChatService.startAuth(scope:)` | `SendAuthReq` + state 防 CSRF；回执授权码经 `lastAuthCode` 发布 |
| 小程序跳转 | `WeChatService.launchMiniProgram(...)` | `WXMiniProgramObject`（未配置原始 ID 时自动禁用并提示） |
| 回跳处理（双通道） | `handle(openURL:)` / `handle(userActivity:)` | 由 `DesignCodeApp` 的 `.onOpenURL` / `.onContinueUserActivity` 送达 |
| Universal Link 自检（七步） | `runUniversalLinkSelfCheck()` | 官方 `checkUniversalLinkReady`，逐步结果 UI + 30s 超时兜底 |
| SDK 日志桥 | `startLogBridge(level:)` | 官方 `startLog(by:logBlock:)` → 工程 `LogManager`（`wechat` 域，DEBUG 级） |
| 安装 / 版本检测 | `refreshAvailability()` | `isWXAppInstalled` / `isWXAppSupport` / `getVersion` |
| 结果可见反馈 | `WeChatBannerOverlay` | 分享/登录回执横幅（成功 / 取消 / 失败），3.2s 自动消隐 |
| 状态与自检中心 | `WeChatIntegrationView` | 「我的 → 应用设置 → 微信集成」 |

**隐私优先**：SDK 仅在用户**同意隐私协议后**注册（`DesignCodeApp.task(id: privacyConsentAccepted)`）；拒绝（受限模式）时完全跳过。

---

## 2. 官方四要件对照

| 官方要求 | 工程落点 | 状态 |
| --- | --- | --- |
| ① `CFBundleURLTypes`（Scheme = AppID 本身） | `Info.plist` → `$(WECHAT_APPID)` | ✅ 已声明（契约测试覆盖） |
| ① `LSApplicationQueriesSchemes`：`weixin` / `weixinULAPI` / `weixinURLParamsAPI`（前 50 条内） | `Info.plist` | ✅ 已声明 |
| ② 启动注册 `registerApp(_:universalLink:)`（主线程） | `WeChatService.registerIfNeeded(reason:)` | ✅ 隐私同意后调用 |
| ③ 回跳 `handleOpenURL` / `handleOpenUniversalLink` | `WeChatService` + `DesignCodeApp` | ✅ 双通道 |
| ④ 关联域名 `applinks:<域名>` + 服务端 AASA | `DesignCode/DesignCode.entitlements`（已备好，**默认未启用**，见 §3.4） | ⏳ 需真实域名后开启 |
| 链接依赖 | `OTHER_LDFLAGS = -ObjC -all_load` + Security / CoreGraphics / WebKit / CFNetwork / SystemConfiguration / CoreTelephony / libz / libsqlite3 / libc++ | ✅ 已配置 |

---

## 3. 配置步骤

### 3.1 微信开放平台侧（已完成）

已在 [微信开放平台](https://open.weixin.qq.com/) 注册移动应用，后台与本工程一致：

| 后台字段 | 填写值 |
| --- | --- |
| 应用官网 | `https://jl.43322.cn` |
| AppID | `wx8e60d3a37d3cff47` |
| iPhone Bundle ID | `com.qinchao` |
| 测试 Bundle ID | `com.qinchao` |
| Universal Link | `https://jl.43322.cn/app/` |

还需在后台确认/开通能力：**分享到微信**、**微信登录**（登录需开发者资质审核）。

### 3.2 Xcode 侧（单点配置）

Xcode → Target `DesignCode` → Build Settings → 搜索 `WECHAT_`，按 §0 表格替换 4 个值（Debug / Release 各一份）。

### 3.3 服务器 AASA 部署（域名 `jl.43322.cn` · 腾讯 EdgeOne Pages）

**现状（2026-09-27 复核）**：✅ **AASA 已部署且 Apple CDN 已收录**——直连 200 且内容与本工程完全一致；`https://app-site-association.cdn-apple.com/a/v1/jl.43322.cn` 已返回同一 JSON（这是 iOS 设备实际读取的副本，UL 解析链路已具备）。⏳ `/app/` 落地页仍 404（可选，建议补上）。

**已验证的 AASA 内容**（本仓库 [`deploy/.well-known/apple-app-site-association`](./deploy/.well-known/apple-app-site-association) / [`well-known/apple-app-site-association`](./well-known/apple-app-site-association)）：

```json
{ "applinks": { "apps": [], "details": [ { "appID": "F2JL9GNLCC.com.qinchao", "paths": ["/app/*"] } ] } }
```

- `appID` = `TeamID.BundleID` = `F2JL9GNLCC.com.qinchao`（与真机签名 Team / Bundle ID 一致）；
- `paths` 覆盖 `/app/*`（与 `WECHAT_UNIVERSAL_LINK` 的路径一致）。

**可选收尾两项**：

1. `/app/` 落地页：把 [`deploy/app/index.html`](./deploy/app/index.html) 部署到 `/app/`（UL 命中时展示友好页面而非 404）；
2. `Content-Type` 建议设为 `application/json`（当前 EdgeOne 返回 `application/octet-stream`；iOS 实际读 Apple CDN 副本，故不影响 UL 解析，但按 Apple 规范建议在 EdgeOne 规则里补一个响应头）。

**校验命令**：

```bash
# 直连 + 内容
curl -sI https://jl.43322.cn/.well-known/apple-app-site-association | head -5
curl -s  https://jl.43322.cn/.well-known/apple-app-site-association | python3 -m json.tool
# Apple CDN（设备实际读取的副本）
curl -s  https://app-site-association.cdn-apple.com/a/v1/jl.43322.cn | python3 -m json.tool
# 落地页（可选）
curl -sI https://jl.43322.cn/app/ | head -3
```

### 3.4 启用 Associated Domains（官方要求④ · 受账号类型限制，当前未启用）

**根因（2026-09-28 现场核实，非配置/代码问题）**：本工程当前签名的团队是**免费「个人团队」（Personal Team）**，而 **Associated Domains 属于 Apple Developer Program（付费 ADP）专属能力** → 免费团队无法启用，也无法通过改配置绕过。

| 现场证据 | 内容 |
| --- | --- |
| Xcode → Target → Signing & Capabilities | Team = **「Chao Qin (Personal Team)」**；证书 `Apple Development: 56967916@qq.com (K6Z3LTPM79)`；Bundle ID `com.qinchao` |
| 真机安装包描述文件 `DesignCode.app/embedded.mobileprovision` | 创建 `2026-09-27 07:28:59` → 过期 `2026-10-04 07:28:59`（**恰好 7 天**，免费个人团队特征；付费团队为 1 年）；Entitlements 仅 `application-identifier` / `team-identifier` / `get-task-allow` |
| [Apple 官方：开发者账户概览](https://developer.apple.com/cn/help/account/basics/about-your-developer-account/) | 账号未关联开发者计划时 Xcode 显示为「私人团队」：App ID / 设备 / 描述文件 **7 天后过期**（最多 10 个 App ID、3 台设备） |
| [Apple 官方：支持的功能 (iOS)](https://developer.apple.com/cn/help/account/reference/supported-capabilities-ios) | 预置描述文件可用能力**取决于计划会员资格**（Associated Domain 为 ADP 能力） |

**当前默认策略：保持不启用**（`CODE_SIGN_ENTITLEMENTS` 关闭）——保证日常命令行构建/测试不被破坏；开启后 CLI 构建会报
`Provisioning profile "iOS Team Provisioning Profile: com.qinchao" doesn't include the Associated Domains capability`，且免费团队无法通过门户开通（`No Accounts` 在 CLI 侧属次要现象）。

**升级到付费账号后的完成步骤（唯一解法）**：

1. Xcode → Settings → **Accounts** 添加已加入 Apple Developer Program 的 Apple ID；
2. Target `DesignCode` → Signing & Capabilities → **Team 切换到付费团队**（App ID `com.qinchao` 将在该团队下重新注册）；
3. **+ Capability → Associated Domains** → 添加 `applinks:jl.43322.cn`（或把 `CODE_SIGN_ENTITLEMENTS` 指向已就绪的 `DesignCode/DesignCode.entitlements`，值由 `$(WECHAT_UL_HOST)` 注入）；
4. ⌘R 让 Xcode 更新描述文件 → 进入「微信集成 → 七步自检」，第 5/6 步应转为通过。

> **未启用期间的可预期表现**：微信**分享/登录的返回回调无法送达本 App**（SDK 1.8.6+ 统一经 Universal Link 回跳）——分享动作本身可以发起、消息可正常送达微信，但需在微信中手动返回，且收不到成功/取消回执（`wechat` 域不会出现对应 onResp 记录）；「七步自检」会在第 5/6 步明确报出该限制。
> **附带事实（与微信无关）**：免费个人团队描述文件 7 天到期 → 每 7 天需重新构建安装一次，否则 App 会因描述文件过期而无法打开。

### 3.5 自检与验收

1. App 内：「我的 → 应用设置 → 微信集成」→ **运行 Universal Link 自检（官方七步）**；
2. 七步全绿（第 5 步会短暂拉起微信，按提示返回本 App）；
3. 验收清单：
   - 文章详情 → 分享 → 分享到微信 → 好友 / 朋友圈 / 收藏，各自发送成功并看到回执横幅；
   - 「微信集成」页发起微信登录，`lastAuthCode` 出现授权码（需平台已开通登录能力）；
   - 日志中心筛选 `wechat` 域：注册 / 分享发起 / 回执 / 自检逐步均有记录。
4. **专项测试报告**：[长图分享到微信 · 完整测试报告](./test-report-20260928-long-image.md)（2026-09-28；含契约用例明细、覆盖矩阵、UI 细节审计对照表、证据索引与人工验收清单）。

**已完成的工程验证（2026-09-27；先占位配置、后真实配置各一轮）**

| 验证项 | 结果 | 证据 |
| --- | --- | --- |
| 全量编译（含 SDK 静态库链接 `-ObjC -all_load`） | 0 error / 0 warning | `build/verify/wechat_fullbuild_real.log`（真实配置轮） |
| 显示设置构建期护栏 | 通过（排版链 0 缺口、弹出层 0 缺口） | 同上（Run Script 阶段输出） |
| 真机签名构建（Associated Domains 未启用） | BUILD SUCCEEDED（两轮均通过） | `build/verify/wechat_device_build_real.log` 等 |
| 真机单元测试 | **104/104 通过（0 失败）**，两轮均全绿 | `build/verify/wechat_test_real.log`（真实配置轮，含 WeChatSDKTests 17 例） |
| 日志埋点联通（真机运行断言） | 通过：注册路径写入 `wechat` 域 LogEntry（真实 AppID 下同样成立） | `WeChatSDKTests.testRegistrationPathWritesWeChatLog` |
| Info.plist 变量注入实测 | 真实值注入正确：`CFBundleURLSchemes = wx8e60d3a37d3cff47`、`WeChatUniversalLink = https://jl.43322.cn/app/`、`WeChatMiniProgramID`（占位）、`LSApplicationQueriesSchemes` | 构建产物 `DesignCode.app/Info.plist` |
| **真机 SDK 注册实测**（2026-09-27 最终轮） | `WXApi.registerApp` 返回 **true**；可用性状态机 = **ready**（已注册 + 微信已安装 + 版本支持 OpenApi）；SDK 2.0.8；`placeholder=false` | `build/verify/wechat_final_test.log` L1082 `[WeChatContract] registered=true availability=ready installed=true sdk=2.0.8 …` |
| Associated Domains（entitlements） | 尚未启用：CLI 自动签名无法开通该能力（`No Accounts` + 描述文件缺能力）→ 需 Xcode GUI 一次性操作，见 §3.4 | `build/verify/wechat_device_build_ad2.log`（开启后两轮失败记录） |

> 提示：App 日志以 **1000 条/文件** 滚动（高频图片/缓存 DEBUG 日志约 3 分钟即填满窗口），启动时刻的注册日志可能已被窗口挤出文件——排查微信问题时请看 App 内「我的 → 应用日志」（内存保留最多 3000 条，可筛 `wechat` 域）。

---

## 4. 行为约定

| 场景 | 行为 | 日志级别 |
| --- | --- | --- |
| 已配置但缺 Associated Domains（**当前状态**） | 分享可发起、消息可送达微信；**收不到回执**（无 onResp），登录授权码同理不可达；七步自检第 5/6 步报错 | 自检 WARNING（含 errorInfo/suggestion） |
| 未配置（占位） | 提示「未配置」+ 修复指引，不发起请求 | WARNING |
| 未安装微信 / 版本过低 | 分享菜单给出提示与 App Store 安装入口 | WARNING（发起时） |
| 用户取消分享/登录 | 视为正常行为，横幅「已取消」 | **INFO**（不计失败，对齐工程取消语义红线） |
| 分享成功 | 横幅「已分享到 ×××」 | INFO |
| 发送失败 / 授权拒绝 / 版本不支持 | 横幅 + 建议动作 | WARNING |
| 缩略图下载失败 | 仍可分享（无缩略图），不阻断 | WARNING |
| **长图分享：超 10MB 自动压缩** | 按质量档（0.92→0.44）与降采样档（1.0→0.34）逐档尝试至满足官方上限，成功即留痕（scale/quality/bytes） | INFO |
| **长图分享：压缩仍不达上限** | 不发起分享，横幅「长图过大，未能压缩到微信限制内」并记录像素尺寸与上限 | ERROR |
| **长图分享回执** | 成功「长图已分享到×××」/ 取消「已取消长图分享」；日志含 `kind=longImage` + `entry` + 字节数/像素/质量/缩略图字节/准备耗时 | INFO（取消不计失败） |
| **长图生成：图片极多 / 内存紧张** | 画布自动降倍率（内存预算 ∩ 高度上限）；仍失效则降级为「省略插图」（图尾可见注明）；**绝不产出黑图** | WARNING（降级路径全程留痕 `longimage` 域） |
| 自检超时（30s 无终态） | 中止并提示重试，已收集步骤保留 | WARNING |

---

## 5. 日志排查（域 `wechat`）

| 关键日志 | 位置 | 说明 |
| --- | --- | --- |
| `微信 SDK 注册成功/失败` | `WeChatService.swift` | 含 appID、ulHost、appIDFormat、sdkVersion、availability |
| `微信 SDK 未注册：配置为占位值` | 同上 | 含修复指引（构建设置名） |
| `分享菜单展示` / `分享菜单选择场景` | `WeChatIntegrationViews.swift` | 点击链路起点 |
| `分享已发起（等待微信回执）` | `WeChatService.swift` | 含 scene、字节数、缩略图大小、准备耗时 |
| `分享成功：已发送到×××` / `用户取消分享` | 同上 | 回执归因（onResp） |
| `微信登录请求已发起` / `微信登录成功：已获取授权码` | 同上 | 含 state、scope、language |
| `Universal Link 自检开始（七步）` / `自检通过/未通过` | 同上 | 含逐步结果串、失败步骤、errorInfo、耗时 |
| `SDK: <原始日志>` | 同上 | SDK 日志桥（DEBUG 级，自检期间切换 detail） |
| `微信回跳（URL Scheme / Universal Link）` | 同上 | 含 handled 结果 |

> 全部日志仅本地存储（工程日志系统约定），不上传任何数据。

---

## 6. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| 构建报 `Provisioning profile ... doesn't include the Associated Domains capability`；Xcode 里 Team 显示为「Personal Team」 | **免费个人团队不支持该能力**（付费 ADP 专属）；不要试图通过改 pbxproj 绕过，按 §3.4 升级账号后切换团队并添加能力 |
| 分享发出后本 App 收不到回执 / 微信返回失败 | 同上：Associated Domains 未启用 → UL 回跳不可达；先跑七步自检确认第 5/6 步状态 |
| 分享返回 `errCode = -4（授权拒绝）` | 微信开放平台未开通「分享到微信」能力，或 **Bundle ID / 签名与后台不一致**；核对后台配置 |
| 分享返回 `errCode = -1（普通错误）` | 常见于 Universal Link 校验不通过；先跑七步自检，按 `errorInfo` / `suggestion` 修复 |
| 自检第 3 步失败（微信版本检查） | 微信版本过低或未安装；升级微信 |
| 自检第 5 步失败（拉起微信检查） | Universal Link 未生效：检查 AASA 是否 200 + `application/json`、`appID` 是否为 `F2JL9GNLCC.com.qinchao`、paths 是否含 `/app/*`、是否被重定向 |
| 自检第 6 步失败（回跳当前 App） | Associated Domains 未启用（§3.4），或 AASA 未被系统拉取（重装 App / 等待收敛） |
| 分享菜单提示「未配置」 | `WECHAT_APPID` / `WECHAT_UNIVERSAL_LINK` 仍为占位值（§0） |
| 真机构建失败：`No Accounts` / `Provisioning profile doesn't include Associated Domains` | 启用 Associated Domains 后当前描述文件不含该能力；在 Xcode GUI 登录账号并让自动签名更新描述文件（或暂时关闭 §3.4） |
| 微信登录返回 `code` 但无法拿用户信息 | 官方流程要求**服务端**用 AppSecret 换取 access_token（客户端不做，属预期） |

---

## 7. 合规说明

隐私政策「四、信息的共享与披露 → 4.3 第三方 SDK 清单（微信开放平台 SDK）」已列明：SDK 名称、提供方、使用目的、可能处理的信息、共享方式与《微信隐私保护指引》链接。相关文本见 `DesignCode/PrivacyLegalTexts.swift`。

---

## 8. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-09-27 | 首次接入：OpenSDK 2.0.8 XCFramework、分享/登录/小程序/自检全链、设置页集成中心、契约测试、本指南 |
| 2026-09-27 | **真实配置落地**：AppID `wx8e60d3a37d3cff47`、UL `https://jl.43322.cn/app/`、域名 `jl.43322.cn` 写入构建设置（Debug/Release）；构建产物 Info.plist 实测注入正确；全量编译 0/0 + 真机 104/104 通过（`build/verify/wechat_test_real.log`）；AASA 部署物料生成（[`deploy/`](./deploy)），实测域名侧尚未部署（404）；AppSecret 仅存本机 `qin/.secrets/`（gitignore），不入仓库 |
| 2026-09-28 | **根因定位（现场核实）**：签名团队为免费「个人团队」（Team 显示 Personal Team；真机描述文件 7 天有效期），**Associated Domains 属付费 ADP 能力** → 按「保持现状」处理：`CODE_SIGN_ENTITLEMENTS` 保持关闭，限制、证据与升级步骤写入 §3.4；同时复核：AASA 已部署且 Apple CDN 已收录，真机 `registerApp=true / availability=ready` |
| 2026-09-28 | **长图分享到微信（WXImageObject）**：分享面板新增「长图分享到微信」入口（6 处文章页），复用既有长图生成链路（加载/错误覆盖层不变）→ `WeChatLongImageShareMenu` 三场景发送；`WeChatImageEncoder` 保证 `imageData ≤10MB`（逐档降质/降采样留痕）、缩略图锚定长图顶部 ≤32KB；回执按 `WeChatShareKind` 区分文案与 `kind` 日志；抽公共组件 `WeChatSceneTiles` / `WeChatUnavailableNotice`（两菜单共用，动效一致）；真机 108/108（新增 4 例长图契约），全量编译 0/0（`build/verify/longimage_*.log`） |
| 2026-09-28 | **完整复核 + 补齐入口**：① 配置契约复核（xcframework 四段挂载 / `-ObjC -all_load` / 8 系统框架 / 产物 Info.plist 实测）/ 接线点复核（隐私门控注册、双通道回跳、WXApiDelegate、SDK 日志桥）/ **SDK API 形式冷编译取证**（`swiftc -typecheck` 对官方头，EXIT=0，探针 `build/verify/wxapi_probe.swift`）；② 新增第 7 处微信分享入口：**党建文章详情**（`PartySubjectView`，此前仅系统分享面板）；③ 真机：全量编译 0/0 + 护栏通过 + 104/104（`build/verify/audit2_*.log`）；④ 日志域基准刷新：`wechat` 51→52 处、全工程 1,077→1,078 处 |
| 2026-09-28 | **长图分享 UI 细节审计 + 专项测试报告**：与 `WeChatShareMenu` 逐项对照（结构 / 间距 / 动效 / detents / 文案平行结构）确认融合；修复 ① 菜单头部直渲超长图 → 载荷构造期 **200pt 顶部裁方预览小图**（与官方缩略图同一裁切核心，新增契约用例 `testLongImagePayloadPreviewContract` 锁定）；② `entry` 占位值 → **页面级归因**（6 页）；新增 [完整测试报告](./test-report-20260928-long-image.md)；真机 **109/109** + 全量编译 0/0 + 护栏通过（`build/verify/uipolish_*.log`） |
| 2026-09-28 | **长图生成「纯黑图」缺陷修复**（图片多的文章偶发黑图）：根因=渲染器固定 3x + 高度无界（多图文章位图 200MB+，分配失败时 `UIGraphicsImageRenderer` 静默产出黑图）与 7 处页面全尺寸解码图常驻；修复=画布预算自适应（内存∩高度上限，`budget(...)`）+ 素材按需缩略解码（`ArticleLongImageAsset` / `ImageIO` 缩略）+ 产物黑图校验与「降倍率→省略插图」降级阶梯（页脚可见说明）；附带修复插图纵向压扁、WeChat 编码档位像素预算跳过、print 残留清零、日志统一 `longimage` 域；新增 10 例契约；真机 **119/119** + 全量编译 0/0 + 护栏通过（`build/verify/longimage_fix_*.log`），详见[测试报告附录 A](./test-report-20260928-long-image.md#附录-a长图生成纯黑图缺陷修复2026-09-28-追加第二轮) |
| 2026-09-28 | **长图黑图第二轮回溯修复**（复报「问题依旧」→ 真机探针取证）：① 画布位图色域不确定（`.automatic` 真机产出 16/32/64bpp 不定，64bpp 时内存翻倍）→ 全链 `preferredRange = .standard`（确定 32bpp），新增画布格式契约；② 编码降采样按「点」而非像素计算（自适应倍率下可放大位图）→ 重写为像素级 `downscaledToPixelScale`；③ 编码阶梯与交付零校验（黑图 JPEG 极小、能过 10MB 校验）→ 画布/编码候选/编码字节/落盘四级校验（`SJZImageIntegrity`，布局感知 + fail-closed）；④ 修复降级阶梯可能高于预算；新增 10 例契约与 5 个真机探针；真机 **130/130** + 全量编译 0/0 + 护栏通过（`build/verify/longimage_black3_*.log`），详见[测试报告附录 B](./test-report-20260928-long-image.md) |
| 2026-09-28 | **长图第三轮**（复验：插图颠倒 + 偏模糊）：① **插图上下颠倒**根因=`CGContext.draw(cgImage:)` 在 UIKit 上下文（y 向下）会翻转图片（探针铁证：`UIImageDraw top=1.00/bottom=0.00` vs `CGContextDraw top=0.00/bottom=1.00`）→ 改用 `UIImage(cgImage:).draw(in:)`，新增行剖面判据契约（修复前 FAIL / 修复后 PASS）；② **清晰度**：画布预算 160MB/32,000px → **288MB/48,000px**、编码首档 40MP → **72MP**（重图文章倍率 1.90 → **2.56**，+34%）；真机 **133/133** + 全量编译 0/0 + 护栏通过（`build/verify/longimage_black4_*.log`），详见[测试报告附录 C](./test-report-20260928-long-image.md) |