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

---

## 1. 已实现能力矩阵

| 官方能力 | 代码落点 | 说明 |
| --- | --- | --- |
| 分享到会话 / 朋友圈 / 收藏 | `WeChatService.share(_:to:)` | 网页卡片（标题 ≤512B、摘要 ≤1KB、缩略图 ≤32KB 自动生成） |
| 分享菜单 UI | `WeChatShareMenu` | 文章详情「分享 → 分享到微信」，三场景磁贴 + 不可用状态提示 |
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

### 3.4 启用 Associated Domains（官方要求④ · 当前唯一阻塞项）

**实测结论（2026-09-27，两轮验证）**：把 `CODE_SIGN_ENTITLEMENTS = DesignCode/DesignCode.entitlements` 打开后，命令行构建（含关闭沙箱重试）均报
`No Accounts: Add a new account in Accounts settings` + `Provisioning profile "iOS Team Provisioning Profile: com.qinchao" doesn't include the Associated Domains capability`
→ 本机 **Xcode 未登录 Apple ID**，命令行无法向开发者门户开通/更新该能力，故工程默认**不启用**此设置（保证日常命令行构建/测试不被破坏）。

**请完成一次（二选一，之后命令行构建也会带上该能力）**：

- **方式 A（推荐）**：Xcode → Settings → **Accounts** 登录 Apple ID（Team `F2JL9GNLCC`）→ 打开 `qin/DesignCode.xcodeproj` → Target `DesignCode` → **Signing & Capabilities** → **+ Capability** → **Associated Domains** → 添加 `applinks:jl.43322.cn` → ⌘R 跑一次（Xcode 自动更新描述文件）；Build Settings 的 `CODE_SIGN_ENTITLEMENTS` 会由 Xcode 自动写入（文件已就绪，值由 `$(WECHAT_UL_HOST)` 注入）；
- **方式 B（纯 GUI 最快）**：登录账号后直接 ⌘R；若报缺能力，再按方式 A 加一次 Capability。

完成后进入「微信集成」运行**七步自检**，七步全绿即全链打通。

> 未启用前：微信**分享/登录的返回回调**无法送达本 App（微信自 SDK 1.8.6 起统一经 Universal Link 回跳），表现为微信侧返回失败或本 App 收不到 onResp。

### 3.5 自检与验收

1. App 内：「我的 → 应用设置 → 微信集成」→ **运行 Universal Link 自检（官方七步）**；
2. 七步全绿（第 5 步会短暂拉起微信，按提示返回本 App）；
3. 验收清单：
   - 文章详情 → 分享 → 分享到微信 → 好友 / 朋友圈 / 收藏，各自发送成功并看到回执横幅；
   - 「微信集成」页发起微信登录，`lastAuthCode` 出现授权码（需平台已开通登录能力）；
   - 日志中心筛选 `wechat` 域：注册 / 分享发起 / 回执 / 自检逐步均有记录。

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
| 未配置（占位） | 提示「未配置」+ 修复指引，不发起请求 | WARNING |
| 未安装微信 / 版本过低 | 分享菜单给出提示与 App Store 安装入口 | WARNING（发起时） |
| 用户取消分享/登录 | 视为正常行为，横幅「已取消」 | **INFO**（不计失败，对齐工程取消语义红线） |
| 分享成功 | 横幅「已分享到 ×××」 | INFO |
| 发送失败 / 授权拒绝 / 版本不支持 | 横幅 + 建议动作 | WARNING |
| 缩略图下载失败 | 仍可分享（无缩略图），不阻断 | WARNING |
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