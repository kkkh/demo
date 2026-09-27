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

| 构建设置 | 当前占位值 | 含义 | 示例 |
| --- | --- | --- | --- |
| `WECHAT_APPID` | `wxPLACEHOLDER0000` | 移动应用 AppID（同时作为 URL Scheme） | `wx1234567890abcdef` |
| `WECHAT_UNIVERSAL_LINK` | `https://example.com/app/` | Universal Link（微信开放平台填写的同一个） | `https://www.sxjzit.edu.cn/app/` |
| `WECHAT_UL_HOST` | `example.com` | 关联域名（entitlements 用） | `www.sxjzit.edu.cn` |
| `WECHAT_MINI_PROGRAM` | `gh_PLACEHOLDER0000` | 小程序原始 ID（仅小程序跳转需要） | `gh_abcdef123456` |

> 占位值下：微信入口可见但不可用，所有点击给出「未配置」提示与日志（`wechat` 域），**不发任何微信请求**，不影响其它功能。

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

### 3.1 微信开放平台侧

1. 在 [微信开放平台](https://open.weixin.qq.com/) → 管理中心 → 移动应用 → 创建/进入应用；
2. 填写 **iOS Bundle ID**：`com.qinchao`；
3. 填写 **Universal Link**：`https://<你的域名>/app/`（必须 https、且与 App 配置完全一致）；
4. 申请开通所需能力：**分享到微信**、**微信登录**（登录需开发者资质审核）；
5. 记录 **AppID**（`wx` 开头 18 位）。

### 3.2 Xcode 侧（单点配置）

Xcode → Target `DesignCode` → Build Settings → 搜索 `WECHAT_`，按 §0 表格替换 4 个值（Debug / Release 各一份）。

### 3.3 服务器 AASA 部署

1. 将 [`apple-app-site-association`](./apple-app-site-association) 上传至服务器根目录的 `.well-known` 子目录：

   ```
   https://<你的域名>/.well-known/apple-app-site-association
   ```

2. 要求（Apple 官方）：
   - **必须是 HTTPS**，且返回 `Content-Type: application/json`；
   - **不得重定向**（301/302 会导致校验失败）；
   - **不得携带 `.json` 后缀**；
   - `appID` 格式为 `TeamID.BundleID`（本工程：`F2JL9GNLCC.com.qinchao`）；
   - `paths` 必须覆盖 `/app/*`（微信 Universal Link 回跳路径）。
3. 校验：

   ```bash
   curl -sI https://<你的域名>/.well-known/apple-app-site-association | head -3
   curl -s  https://<你的域名>/.well-known/apple-app-site-association | python3 -m json.tool
   ```

> Apple 校验收敛需要时间（首次安装/更新后由系统拉取，可用 `swcutil` 或重装 App 触发）。

### 3.4 启用 Associated Domains（官方要求④）

本工程默认**未**启用该能力（CI/真机签名使用的描述文件不含 Associated Domains，启用会导致构建失败）。拿到真实域名后：

1. Xcode → Target → **Signing & Capabilities** → **+ Capability** → **Associated Domains**；
2. 添加 `applinks:<你的域名>`（或直接在 Build Settings 打开 `CODE_SIGN_ENTITLEMENTS = DesignCode/DesignCode.entitlements`，该文件已就绪，值由 `$(WECHAT_UL_HOST)` 注入）；
3. 确保开发者账号（Team `F2JL9GNLCC`）的 App ID 已勾选 **Associated Domains** 能力；
4. 重新构建并在设备上安装。

### 3.5 自检与验收

1. App 内：「我的 → 应用设置 → 微信集成」→ **运行 Universal Link 自检（官方七步）**；
2. 七步全绿（第 5 步会短暂拉起微信，按提示返回本 App）；
3. 验收清单：
   - 文章详情 → 分享 → 分享到微信 → 好友 / 朋友圈 / 收藏，各自发送成功并看到回执横幅；
   - 「微信集成」页发起微信登录，`lastAuthCode` 出现授权码（需平台已开通登录能力）；
   - 日志中心筛选 `wechat` 域：注册 / 分享发起 / 回执 / 自检逐步均有记录。

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