# G · 设置类与系统能力视图 — 深度分析草稿

> 范围：18 个文件，`qin/DesignCode/` 下。全部行号与字符串字面量均以 `grep -n` / `read` 实测，非推断。
> 行数口径：下表 `wc -l` 实测。部分文件 `read` 报的 total 比 `wc -l` 大 1，原因是文件末尾无换行符（`wc -l` 只数换行），非内容差异。
> 生成时间基线：工作区快照（`DisplaySettingsView.swift` 2320 行、`NetworkMonitorView.swift` 1619 行、`WeChatService.swift` 1396 行）。

| # | 文件 | wc -l | 顶层类型数 | 组 |
|---|---|---|---|---|
| 1 | `WeChatService.swift` | 1396 | 14 | A 微信 |
| 2 | `WeChatIntegrationViews.swift` | 828 | 12 | A 微信 |
| 3 | `BiometricSecurityManager.swift` | 524 | 6 | B 生物识别 |
| 4 | `BiometricSettingsView.swift` | 178 | 1 | B 生物识别 |
| 5 | `BiometricLockOverlayView.swift` | 137 | 3 | B 生物识别 |
| 6 | `PrivacyManager.swift` | 449 | 4 | C 隐私合规 |
| 7 | `PrivacyPolicyView.swift` | 796 | 5 | C 隐私合规 |
| 8 | `PrivacyLegalTexts.swift` | 276 | 2 | C 隐私合规 |
| 9 | `LogListView.swift` | 1355 | 10 | D 日志 |
| 10 | `LogSettingsView.swift` | 273 | 3 | D 日志 |
| 11 | `NetworkMonitorView.swift` | 1619 | 3 | E 网络监测 |
| 12 | `DisplaySettingsView.swift` | 2320 | 6 | F 显示/缓存/首页 |
| 13 | `CacheModeSettingsView.swift` | 611 | 4 | F 显示/缓存/首页 |
| 14 | `HomeModuleSettingsView.swift` | 149 | 1 | F 显示/缓存/首页 |
| 15 | `BookmarkListView.swift` | 1675 | 4 | G 收藏/消息/通知 |
| 16 | `MessageCenterView.swift` | 939 | 3 | G 收藏/消息/通知 |
| 17 | `NotificationTestView.swift` | 509 | 1 | G 收藏/消息/通知 |
| 18 | `AnnouncementDetailView.swift` | 226 | 2 | G 收藏/消息/通知 |
| | **合计** | **14260** | **84** | |

### 全库最高优先级红线（先看这里）

| 级别 | 位置 | 问题 |
|---|---|---|
| 🔴 P0 | `PrivacyPolicyView.swift:764` | `exit(0)` 主动杀进程（App Store 审核指南 2.5.4 明令禁止） |
| 🔴 P0 | `PrivacyLegalTexts.swift:219` vs `Info.plist:67-68` | 隐私政策声明「不申请 Face ID / Touch ID」，实际申请并启用 |
| 🟠 P1 | `NotificationTestView.swift`（整文件）+ `TabBar.swift:10792` | 测试工具无 `#if DEBUG`，随 Release 出海并对用户可见 |
| 🟠 P1 | `WeChatService.swift:1255-1263` vs `PrivacyLegalTexts.swift:143` | 隐私文本声明「不读取剪切板」，实现为 SDK 剪贴板授权直接放行 |
| 🟠 P1 | `PrivacyManager.swift:36-37` | 隐私政策与用户协议托管在开发者个人博客 `www.43322.cn`，非学校官方域名 |
| 🟡 P2 | `Info.plist:58-64` | ATS 例外域 `sxjzit.edu.cn` 允许明文 HTTP（`NSExceptionAllowsInsecureHTTPLoads=true`） |
| 🟡 P2 | `BiometricSecurityManager.swift:503-515` | Keychain `SecItemAdd` 未处理 `errSecDuplicateItem`，令牌残留即误报「未设置密码」 |
| 🟡 P2 | `BiometricSecurityManager.swift:172` | `consecutiveFailures` 不持久化，杀进程重开即可重置 5 次降级门槛 |
| 🟡 P2 | `CacheModeManager.swift:207-217 / 340-355` | **每次图片缓存命中/未命中都同步写 UserDefaults，且触发全 App 11 个观察视图失效**（滚动期性能隐患，详见 F 组） |
| 🟢 P3 | `BiometricLockOverlayView.swift:104` | 文案「解锁前内容已加密遮挡」——实为视觉遮挡，措辞夸大安全承诺 |

---

## A · 微信开放平台接入

### `WeChatService.swift`（1396 行）

#### 1. 顶层类型清单（14）

| 行号 | 类型 | 职责 |
|---|---|---|
| 39 | `enum WeChatScene: String, CaseIterable, Identifiable` | 分享目标场景（session 会话 / timeline 朋友圈 / favorite 收藏）；`sceneValue: Int32`（L47-53）以整数直传官方 `WXScene`，规避 C 枚举导入类型差异 |
| 87 | `struct WeChatConfiguration` | 配置快照；`placeholderAppID`（L89）、`placeholderUniversalLink`（L91）、`isPlaceholder`（L99）、`hasValidAppIDFormat`（L108）、`hasMiniProgram`（L114）、`universalLinkHost`（L120）、`maskedAppID`（L125）、`static func load(bundle:)`（L131） |
| 151 | `enum WeChatAvailability: String, Equatable` | 可用性状态机（unconfigured / sdkNotRegistered / weChatNotInstalled / weChatVersionTooLow / ready）；`shortTitle`（L164）、`userHint`（L175）、`canOperate`（L191） |
| 197 | `struct WeChatSharePayload: Identifiable` | 网页卡片载荷；`urlHost`（L207）、`clippedTitle`（L210）、`clippedDescription`（L213） |
| 219 | `enum WeChatText` | 字节按需裁剪，`clip(_:maxBytes:fallback:)`（L221） |
| 243 | `private enum WeChatErrCode` | 官方错误码对齐；`describe(_:)`（L251） |
| 267 | `struct WeChatBanner: Identifiable, Equatable` | 全局横幅模型（kind / text / date） |
| 281 | `struct WeChatSelfCheckItem: Identifiable, Equatable` | Universal Link 自检单步结果 |
| 291 | `actor WeChatSelfCheckCollector` | 自检结果并发收集器；`sorted`（L296）、`record`（L299）、`wait`（L304）、`finish`（L311） |
| 322 | `enum WeChatShareKind: String` | 回执归因（webpage / longImage）；`noun`（L331）、`successText(scene:)`（L334）、`cancelText`（L339） |
| 348 | `enum WeChatImageEncoder`（`@MainActor`） | 长图编码器：逐档降质 / 降采样并留痕 |
| 495 | `enum WeChatThumbnailProvider`（`@MainActor`） | 缩略图：内存缓存 → 统一图片管线 → ≤32KB JPEG |
| 639 | `final class WeChatService: NSObject, ObservableObject`（`@MainActor`） | 单例回执中枢 |
| 1204 | `extension WeChatService: WXApiDelegate` | SDK 回调桥接 |

#### 2. 单例形态 · @Published · 持久化

- 单例：`static let shared = WeChatService()`（L641）；`private override init()`（L679-682）在 init 内读 `WXApi.getVersion()`。
- `@Published private(set)` 全部 11 项：`isRegistered` L646、`configuration` L648（初值即 `WeChatConfiguration.load()`）、`availability` L650、`sdkVersion` L652、`isWeChatInstalled` L654、`banner` L656、`lastAuthCode` L658、`isSelfChecking` L660、`selfCheckItems` L662、`lastShareScene` L664。
- 私有非发布状态：`pendingScene` L669、`pendingShareKind` L671、`pendingAuthState` L673、`logBridgeInstalled` L675、`selfCheckStartedAt` L677。
- **持久化：本文件零 UserDefaults / 零文件写入。** 配置唯一来源是 `Info.plist`（`WeChatConfiguration.load` L131-145 读 `CFBundleURLTypes` → `CFBundleURLSchemes` 中 `wx` 前缀者作为 AppID，再读自定义键 `WeChatUniversalLink` / `WeChatMiniProgramID`）。
- 配置注入链（单点）：Target 构建设置 → `Info.plist` 变量替换。实测 `qin/DesignCode.xcodeproj/project.pbxproj:646-649`（Debug）与 `:694-697`（Release）：
  `WECHAT_APPID = wx8e60d3a37d3cff47`、`WECHAT_UL_HOST = jl.43322.cn`、`WECHAT_UNIVERSAL_LINK = "https://jl.43322.cn/app/"`、`WECHAT_MINI_PROGRAM = gh_PLACEHOLDER0000`。
- `Info.plist`：L29-38 `CFBundleURLTypes`（L35 `weixin`，L38 Scheme = `$(WECHAT_APPID)`）；L44-48 `LSApplicationQueriesSchemes` = `weixin` / `weixinULAPI` / `weixinURLParamsAPI`；L90-93 `WeChatMiniProgramID` / `WeChatUniversalLink`。
- `DesignCode.entitlements`：`com.apple.developer.associated-domains` = `applinks:$(WECHAT_UL_HOST)`。
- **SDK 接入方式：XCFramework 二进制依赖**（非 SPM / 非 CocoaPods）。实测 `project.pbxproj:62`（PBXBuildFile）、`:134`（`WechatOpenSDK.xcframework`，`lastKnownFileType = wrapper.xcframework`）、`:157`（Frameworks 阶段）、`:285`（工程组）。源码 `import WechatOpenSDK`（`WeChatService.swift:33`）。头文件注释标注版本为 **OpenSDK 2.0.8（官方含支付版）**（L3）。

#### 3. 关键方法签名 + 行号 + 行为

- `L690 @discardableResult func registerIfNeeded(reason: String) -> Bool` — 幂等注册。先重载配置与版本；`isPlaceholder` 则直接置 `.unconfigured` 并 warning 返回 false（L694-704，**绝不发起微信请求**）；否则 `WXApi.registerApp(appID, universalLink:)`（L706）→ 挂日志桥 → `refreshAvailability()` → 结构化日志（含 `appIDFormat`、`ulHost`、`sdkVersion`）。AppID 格式不符时追加 warning（L718-722）。
- `L728 @discardableResult func refreshAvailability() -> WeChatAvailability` — 四级状态机：占位 → `.unconfigured`；未注册 → `.sdkNotRegistered`；`!WXApi.isWXAppInstalled()` → `.weChatNotInstalled`；`!WXApi.isWXAppSupport()` → `.weChatVersionTooLow`；否则 `.ready`。
- `L756 @discardableResult func handle(openURL url: URL) -> Bool` — URL Scheme 回跳，`WXApi.handleOpen(url, delegate: self)`，记 scheme/host/handled。
- `L768 @discardableResult func handle(userActivity: NSUserActivity) -> Bool` — Universal Link 回跳，先校验 `activityType == NSUserActivityTypeBrowsingWeb` 再 `WXApi.handleOpenUniversalLink`。
- `L783 @discardableResult func share(_ payload: WeChatSharePayload, to scene: WeChatScene) async -> Bool` — 网页卡片。可用性门控 → URL scheme 必须 http/https（L794-802）→ 构造 `WXMediaMessage` + `WXWebpageObject` → 缩略图（`WeChatThumbnailProvider.thumbData`，L813）→ `WXApi.send` 包 `withCheckedContinuation`（L823-827）→ 成功则登记 `pendingScene`/`pendingShareKind = .webpage`，失败给横幅。日志含 `prepareMs`、`titleBytes`、`descBytes`。
- `L863 @discardableResult func shareImage(_ image: UIImage, title: String, to scene: WeChatScene, entry: String) async -> Bool` — 长图分享（`WXImageObject`）。标题按 **512 字节**裁剪（L875）；`WeChatImageEncoder.encode` 失败即横幅「长图过大」（L877-887）；缩略图 `alignment: .top`（L888）；成功登记 `.longImage`。日志含 `bytes` / `pixelSize` / `quality` / `scale`（L914-925）。
- `L946 @discardableResult func startAuth(scope: String = "snsapi_userinfo") async -> Bool` — 微信登录。**state 防 CSRF**：`"sjzit_" + UUID().uuidString.prefix(8)`（L956），存入 `pendingAuthState`；失败清空。授权码只落 `lastAuthCode`（L1376），注释明确「需由服务端换取 access_token / 用户信息」。
- `L983 @discardableResult func launchMiniProgram(fallbackWebpageURL: String, path: String? = nil) async -> Bool` — 小程序跳转；`hasMiniProgram` 与兜底链接前缀双重门控（L992-1004）。
- `L1044 func openWeChatApp() -> Bool`、`L1053 var weChatInstallURL: URL?`（App Store 安装引导）。
- `L1060 func runUniversalLinkSelfCheck() async` — 官方 **七步**自检（`WXApi.checkUniversalLinkReady`，L1162），`selfCheckFinalStep = 6`（L1157），结果经 actor 收集并按 `id` 排序。
- `L1068 installLogBridgeIfNeeded()` 主体在 L1168；`L1175 startLogBridge(level:)` 把 SDK 日志桥到 `LogManager.shared.debugLog("wechat", "SDK: \(text)")`（L1180，DEBUG 级别不进警告栏），`logBridgeInstalled` 守卫杜绝重复挂载（L1169）。
- `L1191 showBanner(_:kind:)` / `L1196 clearBanner(id:)`（带 id 校验避免误清新横幅）。
- `L1206 nonisolated func onReq(_ req: BaseReq)` — 仅应答 `GetMessageFromWXReq`，回文案见 L1280；其余 `log_only`（L1274）。
- `L1223 nonisolated func onResp(_ resp: BaseResp)` — **先同步提取 Sendable 原语**（type/errCode/errStr + SendAuthResp 的 code/state/lang/country），再 `Task { @MainActor in ... }` 回主线程（L1241-1251）。
- `L1255 nonisolated func onNeedGrantReadPasteBoardPermission(with:completion:)` — iOS 16+ 剪贴板授权询问，**直接 `completion()` 放行**（L1257）。
- `L1269 handleRequest(type:title:mediaType:isGetMessage:)`；`L1291 handleResponse(...)` 分享回执按 `WeChatErrCode` 五分支归因；`L1357 handleAuthResponse(...)` 登录回执含 **state 校验**（L1368-1375，不匹配即横幅「校验失败」）。
- 长图编码关键档位（`WeChatImageEncoder`）：`maxImageBytes = 10MB`（L351）、`qualities = [0.92, 0.8, 0.68, 0.56, 0.44]`（L363）、`scales = [1.0, 0.75, 0.6, 0.45, 0.34]`（L365）、`maxFirstAttemptPixels = 72_000_000`（L369）、`systemShareMaxPixels = 12_000_000`（L374）、`systemShareMaxBytes = 10MB`（L375）；`firstScaleIndex(pixelCount:budget:)`（L378）为纯函数契约锚点；`encode(_:maxBytes:maxPixels:)`（L388）内部三处留痕日志（L402 先降采样、L412 跳过档位、L451 自动压缩）。

#### 4. 与其它模块的依赖

- **出向**：`LogManager.shared`（域 `"wechat"`，全文件高频）；`SJZImageIntegrity`（`pixelSize(of:)` L392、`pixelSizeText(of:)` L882、`isLikelyBlank(candidate:)` L428、`isLikelyBlank(encodedImage:)` L442）；`WeChatThumbnailProvider` 内部走统一图片管线取 `thumbImageURL`（L502-570）；`UIKit`。
- **入向**（桥接点，均在 `DesignCodeApp.swift`）：
  - L123-125 `.onOpenURL { weChatService.handle(openURL: url) }`
  - L126-128 `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { weChatService.handle(userActivity: activity) }`
  - L159-167 `.task(id: privacyConsentAccepted)` → 未同意则 `debugLog` 后 return；同意才 `registerIfNeeded(reason: "privacy_consent")`
  - L112 `WeChatBannerOverlay()` 挂在根 ZStack，`zIndex(3.5)`（**层级低于生物识别遮罩，锁定期间自动隐藏**，L111 注释）
  - L141 回前台 `.active` 时 `refreshAvailability()`
- **无 AppDelegate / 无 SceneDelegate**：全库 grep `UIApplicationDelegate|UIWindowSceneDelegate|@UIApplicationMain|UIApplicationDelegateAdaptor` **零命中**，纯 SwiftUI 生命周期（`@main struct DesignCodeApp: App`，`DesignCodeApp.swift:9-10`）。分享/登录回跳全部由 `.onOpenURL` + `.onContinueUserActivity` 双通道送达。
- **消费方**：`TabBar.swift`（5 处文章详情：L3390/5271/5906/6471/7040 分享菜单、L3794/5445/6080/6645/7214 长图载荷构造、L10489 观察 service、L10677 集成中心入口、L10683 可用性徽章）、`OrganizationDetailView.swift`（L3039/3043、L4349、L4182 注释）。
- **测试**：`qin/DesignCodeTests/WeChatSDKTests.swift`。

#### 5. 技术债 / 风险 / 红线

- **✅ AppSecret 未入库（已实测验证）**：全库 `grep -rnE 'AppSecret|appSecret|app_secret|secret'` 仅命中 3 处，且**全部是文档/注释文本，无任何键值**：`WeChatIntegrationViews.swift:758`（UI 说明文案）、`qin/docs/wechat-integration/README.md:26`、`qin/docs/code-wiki/05-项目运行方式.md:66`。真实凭据仅在本机 `qin/.secrets/wechat-credentials.env`（变量名实测：`WECHAT_APPID` / `WECHAT_APPSECRET` / `WECHAT_UNIVERSAL_LINK` / `WECHAT_BUNDLE_ID` / `DEVELOPMENT_TEAM` / `APP_SITE`）。该文件被 `.gitignore:19`（`qin/.secrets/`）+ L18（`.secrets/`）+ L20（`*appsecret*`）三重排除，`git check-ignore -v` 实测确认命中。`git ls-files | grep -i secret` 为空 → **未被跟踪**。
  - 残留风险（P2）：`qin/.secrets/wechat-credentials.env` 实体文件存在于工作区磁盘，且仓库根另有 2 个快照目录（`DesignCode_backup_20260926_display`、`DesignCode_backup_20260926_fonts`）——若以「整目录打包」方式分发工作区，凭据会一并外泄。`.gitignore:20` 的 `*appsecret*` 规则与文件名 `wechat-credentials.env` **不匹配**，仅靠目录规则兜底。
  - AppID `wx8e60d3a37d3cff47` 已随 `project.pbxproj:646/694` 入库。AppID 属公开标识符（客户端本就持有），非机密；但会暴露应用身份，属可接受的常规做法。
- 🔴 **P1 剪贴板口径冲突**：`WeChatService.swift:1255-1263` 对 iOS 16+ 剪贴板授权询问**无条件放行**并记 `granted`；而 `PrivacyLegalTexts.swift:143` 明确写「（6）剪切板数据：本应用不读取您的剪贴板内容」。实现侧不主动读取（由 SDK 消费回执），但「不读取」的表述与「主动授予 SDK 读取权限」之间存在解释空间，属审核/法务表述风险。建议改为「微信回执经系统剪贴板回传，本应用不主动读取剪贴板内容」。
- **黑图防线（2026-09-28 历史事故二次复现）**：L473 注释「教训（2026-09-28 黑图二次复现）：长图渲染产物是**自适应倍率**（`image.scale` ∈ 0.2~3.0）」；L391 强调「必须用**像素**尺寸：`image.size` 是点、随自适应倍率变化（用点会低估预算与降采样倍率）」。三重闸：候选图校验（L428）、编码产物缩略解码校验（L442）、`autoreleasepool` 逐档释放（L437）。任何阶段的黑图都不可能进入微信（L440-441 注释）。
- 🟠 **系统分享内存预算（2026-09-28 现场修复）**：L371-375 注释「分享扩展（微信等）内存上限远低于 App（约 120MB）——72MP 长图解码即 ~300MB，扩展会被系统终止（表现为「微信加载中 → 闪回 App」）」，故 `systemShareMaxPixels = 12MP`（≈48MB 解码内存）。
- **官方硬约束**：`imageData ≤ 10MB`、`thumbData ≤ 32KB`（L492 注释：「官方缩略图硬限制：thumbData ≤ 64KB（历史文档 32KB），此处按更严格的 32KB 生成」）。SDK 头文件注记 25M，实现取更严的 10MB（L349-350）。
- **取消语义工程红线**：L554「取消语义对齐工程红线：cancelled / CancellationError 静默处理（用户行为，不告警）」；L1322「取消属用户正常行为：INFO 记录，不计失败（对齐工程取消语义红线）」。
- **小程序未启用**：`WECHAT_MINI_PROGRAM = gh_PLACEHOLDER0000`（`project.pbxproj:647/695`）→ `hasMiniProgram` 为 false，`launchMiniProgram` 恒定走「未配置」分支。UI 保留入口但不可用（见 `WeChatIntegrationViews.swift:777`）。
- **AASA 未部署**：`WeChatService.swift:19-20` 要求服务端 `https://<域名>/.well-known/apple-app-site-association`；仓库文档自述实测「域名侧尚未部署（404）」（`qin/docs/wechat-integration/README.md:230`）。→ Universal Link 回跳在真实环境**可能不通**，分享/登录回执链路存在实测盲区（文档声称真机 104/104 通过，但自检第 5 步会拉起微信，属半自动验证）。
- 自检副作用：L1059 注释「官方 checkUniversalLinkReady；会短暂拉起微信，仅调试期使用」——但入口在 Release 也可达（`WeChatIntegrationViews.swift:678-731` 自检卡无 DEBUG 门控），用户可触发。

---

### `WeChatIntegrationViews.swift`（828 行）

#### 1. 顶层类型清单（12）

| 行号 | 类型 | 职责 |
|---|---|---|
| 18 | `private extension Color` | 微信品牌色（`sceneTint` 辅助函数在 L26） |
| 37 | `struct WeChatAvailabilityBadge: View` | 可用性徽章（`availability` L38） |
| 75 | `struct WeChatShareMenu: View` | 文章分享入口（三场景网页卡片） |
| 222 | `struct WeChatSceneTiles: View` | 三场景磁贴（网页卡片与长图共用） |
| 286 | `struct WeChatUnavailableNotice: View` | 不可用态提示（共用） |
| 334 | `enum LongImageDestination` | 长图去向：`.system`（系统分享面板）/ `.weChat`（WXImageObject） |
| 340 | `struct WeChatLongImagePayload: Identifiable` | 长图载荷 |
| 365 | `struct WeChatLongImageShareMenu: View` | 长图分享菜单 |
| 500 | `struct WeChatBannerOverlay: View` | 全局回执横幅浮层 |
| 565 | `struct WeChatIntegrationView: View` | 集成中心（设置页子页） |

#### 2. 单例形态 · @Published · 持久化

- **本文件无单例、无 `@Published`、无持久化写入**，全部为 `@ObservedObject private var service = WeChatService.shared`：L79（ShareMenu）、L287（UnavailableNotice）、L369（LongImageShareMenu）、L501（BannerOverlay）、L566（IntegrationView）。
- 局部状态：`sendingScene: WeChatScene?`（L80、L370）、`appeared`（L81、L371）、`didLogEntry`（L567）。
- `WeChatLongImagePayload.previewImage`（L350）在 `init`（L352-360）内一次性生成：`WeChatThumbnailProvider.topSquarePreview(from:side:)`；L348-349 注释说明理由——「菜单头部直接绘制可能上万像素高的长图有明显开销，此处在载荷构造期收敛为小图」。

#### 3. 关键方法签名 + 行号 + 行为

- `L198 private func send(_ scene: WeChatScene)`（ShareMenu）— `sendingScene` 重入守卫 → 记日志 → `Task { await service.share(...) }`；成功即 `dismiss()`（L210，注释：「系统随即切换到微信（本页被覆盖）：先收起菜单，返回时直接回到文章」），失败复位 `sendingScene`。
- `L475 private func send(_ scene: WeChatScene)`（LongImageShareMenu）— 同上，改调 `service.shareImage(payload.image, title:entry:)`（L486）；日志额外带 `pixelSize` 与 `entry`。
- **长图分享流程（三按钮/两条路径）**：
  1. 长图**生成**不在本文件 —— 由各文章详情页负责（`TabBar.swift:3794/5445/6080/6645/7214`、`OrganizationDetailView.swift:4349` 构造 `WeChatLongImagePayload`），本文件只做载荷与菜单。
  2. **微信路径**：`WeChatLongImageShareMenu`（L365）→ `WeChatSceneTiles`（L378）→ `send`（L475）→ `WeChatService.shareImage`（`WeChatService.swift:863`）。
  3. **系统路径**：`LongImageDestination.system`（L335）不在本文件的菜单内实现；消费方在各详情页（`TabBar.swift:3061/5035/5681/6243/6808`、`OrganizationDetailView.swift:2906` 各自持有 `@State longImageDestination: LongImageDestination = .system`）。→ **本文件的长图菜单只覆盖微信三场景，没有「保存到相册」按钮**；相册写入能力由 `Info.plist:69-70` 的 `NSPhotoLibraryAddUsageDescription` 支撑，实现位于本文件之外。
- 子视图组成：`header` L112（文章卡片摘要）/ L407（长图预览 + 尺寸 `长图 · WxH` L419）；`thumbnail` L139；`sceneRow` L164；`unavailableNotice` L171；`footer` L177/L454；`preview` L435；`WeChatSceneTiles.tile(_:)` L242；`WeChatBannerOverlay.tint(_:)` L503 / `icon(_:)` L511 / `body` L519。
- 集成中心分区：`statusSection` L596（含重试注册按钮 L609 与刷新 L621）、`infoRow` L638、`shareSection` L653、`selfCheckSection` L678（运行自检 L681「清空自检结果」L718）、`authSection` L734（发起登录 L737、最近授权码 L746）、`miniProgramSection` L765（跳转 L768）、`configGuideSection` L791、`guideRow` L816。

#### 4. 与其它模块的依赖

- `WeChatService.shared`（唯一强依赖，5 个视图各自观察）。
- `WeChatAvailability` / `WeChatScene` / `WeChatSharePayload` / `WeChatBanner` / `WeChatLongImagePayload`（本文件定义）/ `WeChatThumbnailProvider`（跨文件调用 L356）。
- `LogManager.shared`（域 `wechat`）。
- 全局设计系统：`displayFont` / `displaySymbolFont` / `displayLabelFont` / `SJZCachedImage` / `Color.sjzPrimary` / `sjzAccent`。

#### 5. 技术债 / 风险 / 红线

- `L220` 注释：「三场景磁贴（好友 / 朋友圈 / 收藏）：发送中显示进度遮罩，其余磁贴淡出禁用。」→ 并发发送由 UI 层 `sendingScene` 守卫，Service 层无互斥（`pendingScene` 单值，理论上一旦并发会互相覆盖归因；UI 已挡住）。
- `L758` 文案与实现一致（「客户端不存储任何微信用户隐私数据」），但**未披露剪贴板通道**（同 A 组 P1 红线）。
- 长图菜单**缺少「保存到相册」**入口：用户若只想存图，必须走各详情页的 `.system` 分支，入口分裂在两个文件族。属体验/一致性债。
- `WeChatAvailabilityBadge`（L37）仅 1 处消费（`TabBar.swift:10683`），属低频组件。

---

## B · 生物识别与安全

### `BiometricSecurityManager.swift`（524 行）

#### 1. 顶层类型清单（6）

| 行号 | 类型 | 职责 |
|---|---|---|
| 27 | `enum BiometricLockPolicy: String, CaseIterable, Identifiable` | 后台返回锁定策略 immediate / oneMinute / fiveMinutes；`window: TimeInterval`（L42-48）→ 0 / 60 / 300 |
| 54 | `enum BiometricCapability: Equatable` | faceID / touchID / opticID / `none(SimulatorHint)`；`SimulatorHint`（L60-65）= simulator / notEnrolled / notAvailable / passcodeNotSet；`title` L67、`icon` L79、`isUsable` L88、`needsSystemSettings` L93 |
| 103 | `enum BiometricAuthOutcome` | success / cancelled / `failed(message:goSystemSettings:isBiometricMatchFailure:)`；`static func from(error:)`（L108-139）全覆盖 LAError，含 Xcode 27 SDK 新 case 兜底（L136-137） |
| 146 | `final class BiometricSecurityManager: ObservableObject`（`@MainActor`） | 单例状态机 |
| 493 | `extension Notification.Name` | `biometricNeedsSystemSettings`（L495） |
| 501 | `private enum BiometricKeychain` | 启用令牌存取 |

#### 2. 单例形态 · @Published · 持久化（**本模块持久化分工最清晰**）

- 单例：`static let shared = BiometricSecurityManager()`（L148）+ `private init()`（L213-234）。
- 嵌套状态机：`enum LockState: Equatable`（L152-157）= `inactive`（功能未启用，不锁）/ `locked` / `authenticating` / `unlocked`。
- `@Published private(set)`：`state` L169、`capability` L170、`lastErrorMessage` L171、`consecutiveFailures` L172。
- `@Published`（可写，带 `didSet`）：`isEnabled` L181（didSet L182-195）、`lockPolicy` L199（didSet L200-203）。
- 派生只读：`isLockEngaged` L176-178（`isEnabled && (state == .locked || state == .authenticating)`，供通知弹窗调度判断「保护期间不应把内容盖在安全遮罩之上」）；`needsLockRequest` L272-274（`isEnabled && state == .unlocked`）。
- 私有：`isLaunchUnlockPending` L207、`lastBackgroundAt` L208、`lastUnlockTime` L209。
- **持久化键（实测字面量）**：
  | 键/服务 | 行号 | 值 | 载体 |
  |---|---|---|---|
  | `enabledKey` | L161 | `"biometricEnabled"` | UserDefaults |
  | `policyKey` | L162 | `"biometricLockPolicy"` | UserDefaults |
  | `lastUnlockKey` | L163 | `"biometricLastUnlockAt"` | UserDefaults（L342 写时间戳） |
  | `keychainService` | L164 | `"com.qinchao.DesignCode.biometric"` | Keychain |
  | `keychainAccount` | L165 | `"enrollment-token"` | Keychain |
- 头注释（L9）明确分工：「UserDefaults 存开关与策略（非敏感），Keychain 存启用令牌（设备密码门控、防备份迁移）」；Keychain 可访问性 = `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`（L511）。

#### 3. 关键方法签名 + 行号 + 行为（含锁屏状态机与 scenePhase 交互）

- `L213 private init()` — 读 UserDefaults 恢复 `isEnabled`（L214-215 用 `object(forKey:) != nil` 区分「从未设置」与 false）与 `lockPolicy`（L216-218，非法 rawValue 回落 `.immediate`）；`isEnabled` 则冷启动直置 `.locked`（L219-223）；`refreshCapability()`；结构化启动日志（L228-233）。
- `L239 func refreshCapability()` — `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`；成功按 `biometryType` 映射 faceID/touchID/opticID（L244-249）；失败按 LAError 细分，且 `#if targetEnvironment(simulator)` 给模拟器专门提示（L255-259）。
- `L277 func handleReturnToForeground()` — **后台返回触发**。守卫：未启用 return；`state == .authenticating` 跳过（L281-284）；`lastBackgroundAt` 为空跳过（L285-288，注释：「可能为 Face ID 对话框关闭触发」）；**解锁后 1.5s 宽限**（L289-292，注释：「跳过 Face ID 对话框关闭触发的后台返回锁定」）；最后按 `lockPolicy == .immediate || elapsed > window || state == .locked` 判定重锁（L294-298）。
- `L302 func handleDidEnterBackground()` — 记录 `lastBackgroundAt`；`state == .authenticating` 时跳过记录（L303-306）。
- `L312 func requestLock(reason: String)` — 敏感页面请求上锁，仅 `state == .unlocked` 时生效。→ `L317 private func lock(reason:elapsed:)` 置 `.locked`、清错误、记 INFO（`elapsed` 空则记 `"manual"`）。
- `L329 func authenticate(reason: String = "验证身份以解锁「园枢」") async` — 认证主入口。门控 `isEnabled && state == .locked`（L330）；置 `.authenticating` → `performEvaluation` → 成功置 `.unlocked`、清 `consecutiveFailures`、写 `lastUnlockKey`（L338-343）；取消回 `.locked`（L344-346）；失败置 `.locked` + `lastErrorMessage`，`isMatchFailure` 才累加 `consecutiveFailures`（L347-358）；`goSettings` 时 post `NotificationCenter` 通知（L359-361）。
- `L366 private func performEvaluation(reason: String) async -> BiometricAuthOutcome` — **降级矩阵**：
  - `consecutiveFailures >= 5` → 直接用 `.deviceOwnerAuthentication`（设备密码）策略（L372-373）。
  - 生物识别路由不可用 → 整体降级设备密码（L375-395）。
  - `LAError.userFallback`（用户点「使用密码」）→ 降级设备密码（L402-411）。
  - `LAError.biometryLockout`（系统锁定）→ 降级设备密码（L414-423，注释 L413「系统提示在密码解锁后自动解除生物识别锁定」）。
  - `localizedCancelTitle = "取消"`（L368）。
- `L431 func enableWithGuidedFlow() async -> String?` — 首次启用：`refreshCapability` → 能力不可用返回中文提示（L433-439）→ **Keychain 门控**（L441-444，写入失败即引导设置设备密码）→ `performEvaluation` → 成功 `isEnabled = true` + `state = .locked`（L448-449）；取消/失败均 `deleteToken` 回滚（L453、L457）。
- `L463 func disableWithConfirmation() async -> Bool` — **二次认证**后才关闭（L465）；成功走 `isEnabled = false`（触发 didSet 删令牌）。
- `L484 func openSystemSettings()` — `UIApplication.openSettingsURLString`。
- Keychain：`L503 static func saveToken(service:account:) -> Bool` — 生成 `UUID().uuidString + "-" + UUID().uuidString` 令牌，`SecItemAdd`，`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`；`L517 static func deleteToken(service:account:)` — `SecItemDelete`。
- **scenePhase 交互（实测桥接点）**：`DesignCodeApp.swift:129-145` `.onChange(of: scenePhase)` —— `.background` → `biometricSecurity.handleDidEnterBackground()`（L132）+ `LogManager.shared.flushPendingNow()`（L134）；`.active` → `biometricSecurity.handleReturnToForeground()`（L139）+ `weChatService.refreshAvailability()`（L141）。
- 遮罩挂载：`DesignCodeApp.swift:106` `BiometricLockOverlayView()`。

#### 4. 与其它模块的依赖

- `LocalAuthentication`（`LAContext` / `LAPolicy` / `LAError`）、`Security`（`SecItemAdd` / `SecItemDelete`）、`SwiftUI`（仅为 `UIApplication.openSettingsURLString` 引入）、`Foundation`。
- `LogManager.shared`（域 `"biometric"`）。
- **入向**：`DesignCodeApp.swift:13`（`@ObservedObject`）、`:106`（遮罩）、`:132/:139`（scenePhase）；`TabBar.swift:19`（根视图观察）、`:10487`（设置页观察）；`BiometricSettingsView.swift:11`；`BiometricLockOverlayView.swift:16/120`。
- **出向（页面保护）**：`extension View.biometricLockProtected(reason:)`（`BiometricLockOverlayView.swift:135`）**全库仅 1 个消费方** —— `LogListView.swift:989/992`（经 `LogPageLockPolicy`）。→ 见下「敏感页覆盖不足」。

#### 5. 技术债 / 风险 / 红线

- 🔴 **P0 隐私文本矛盾（与实现直接冲突）**：`PrivacyLegalTexts.swift:219` 写「5.3 本应用不申请以下权限：相机、麦克风、相册读写、通讯录、日历、运动与健康、HomeKit、蓝牙、**Face ID / Touch ID**。」但实现侧：`Info.plist:67-68` 声明 `NSFaceIDUsageDescription`；`BiometricSecurityManager.swift:242` 调 `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`；`BiometricSettingsView.swift:22` 标题「Face ID 解锁」、L39「启用 Face ID 解锁」；遮罩 L82「使用 Face ID 解锁」。→ **App Store 审核指南 5.1.1（隐私政策必须准确描述数据实践）+ 2.3.1（元数据准确）风险**；国内《个人信息保护法》第 17 条告知义务同样不满足（未告知即申请生物识别权限）。
  - 注：同文件 L140「（3）生物识别信息：本应用不收集指纹、面部识别等生物特征数据」**表述正确**（数据不出 Secure Enclave，App 拿不到），与 L219 不冲突。**需要修的是 L219 的权限清单**，而非 L140。
- 🟡 **P2 Keychain 令牌重复写入未处理**：`saveToken`（L503-515）只调 `SecItemAdd`，**未先删除旧项、也未处理 `errSecDuplicateItem`**。一旦令牌已存在，`saveToken` 返回 false → `enableWithGuidedFlow` L441-444 会**误报「检测到设备尚未设置密码，请先前往系统设置设置设备密码」**（错误归因，用户被导向错误操作）。
  - 可复现路径分析：正常「启用→关闭」经 `isEnabled` didSet（L192）会删除令牌，看似自洽；但 `enableWithGuidedFlow` 在 L441 写令牌与 L453/L457 回滚之间存在窗口，**进程若在该窗口内被杀（或崩溃），令牌即残留**，下次启用必然命中冲突。此路径为静态推理，**未做真机复现验证（未验证）**。
  - 修法：`saveToken` 内先 `SecItemDelete` 再 `SecItemAdd`（或改用 `SecItemUpdate`/`SecItemAdd` 组合），并区分「未设密码」与「重复项」两类失败。
- 🟡 **P2 失败计数不持久化**：`consecutiveFailures`（L172）为纯内存状态，无 UserDefaults 落盘。冷启动后归零 → 用户可通过「连续失败 4 次 → 杀进程重开」永久规避 L372-373 的 5 次降级门槛，使 `.deviceOwnerAuthenticationWithBiometrics` 策略的尝试次数不受本 App 约束（仅受系统 `biometryLockout` 约束）。属**安全弱化**，需评估是否持久化。
- 🟡 **P2 敏感页保护覆盖极窄**：`biometricLockProtected` 全库仅 `LogListView` 一处消费。收藏列表、消息中心、隐私文档、微信集成中心、显示设置等均**未挂载**。当前实际保护面 = 冷启动 + 后台返回 + 日志页三项。`BiometricLockOverlayView.swift:8` 头注释声称「敏感页面进入时自动请求上锁」，与覆盖现状存在落差。
- 🟢 **P3 安全承诺措辞夸大**：`BiometricLockOverlayView.swift:104` 文案「解锁前内容已加密遮挡 · 连续 5 次失败自动改用设备密码」——实现是 `Rectangle` 全屏视觉遮挡 + `.privacySensitive()`（L111），**未做任何内容加密**。建议改为「解锁前内容已遮蔽」。
- **反模式（未违规但同类）**：`isEnabled`（L181）与 `lockPolicy`（L199）用 `@Published` + `didSet` 承担持久化与状态迁移副作用。`PrivacyManager.swift:6` 与 `PrivacyPolicyView.swift:6` 都明确写了「禁止 @AppStorage + didSet」的工程约束；此处用的是 `@Published` 而非 `@AppStorage`，**不构成违规**，但 didSet 内做日志 + 状态机迁移 + Keychain 删除，副作用耦合度偏高，且在 SwiftUI 双向绑定下 didSet 触发时序难以完全控制。
- **无截屏/录屏防护**：`.privacySensitive()`（L111）只影响系统级敏感内容呈现（App 切换器快照），**不阻止用户主动截屏或录屏**。若日志页含敏感 URL/错误码，截屏可外泄。属设计边界，非缺陷，但应在文档中明确。
- **门控策略注释与实现一致**：头注释（L11-16）解释 `LAPolicy.deviceOwnerAuthentication` 选型理由与 `WhenPasscodeSetThisDeviceOnly` 的「换机后必须重新注册」安全预期，实现与注释完全对应，属本模块质量亮点。

---

### `BiometricSettingsView.swift`（178 行）

#### 1. 顶层类型清单（1）

| 行号 | 类型 | 职责 |
|---|---|---|
| 10 | `struct BiometricSettingsView: View` | Face ID 解锁设置页 |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例；`L11 @ObservedObject private var security = BiometricSecurityManager.shared`。
- 局部 `@State`：`showDisableAlert` L12、`isEnabling` L13、`enableErrorMessage` L14。
- **本文件零持久化写入**，全部经 Manager（键见上表）。

#### 3. 关键方法签名 + 行号 + 行为

- `L16 var body` — `Form` 三分区：`mainSection`（L18）+ `policySection`（L19）+ `infoSection`（L20）；`.navigationTitle("Face ID 解锁")` L22；关闭确认 alert L24-31（文案 L30：「关闭前需要再次验证您的身份。关闭后冷启动、后台返回与敏感页面将不再要求解锁。」）。
- `L36 private var mainSection` — 总开关用自定义 `securityBinding`（L38）+ `.tint(Color.sjzAccent)`，`isEnabling` 期间禁用（L43）；已启用时展示状态圆点 + `stateTitle`（L45-51）与「立即锁定」按钮（L52-60，调 `security.requestLock(reason: "manual_lock_button")` L54，`state != .unlocked` 时禁用）；失败计数提示（L63-72，文案「本次累计失败 N 次，满 5 次将自动改用设备密码」）；设备能力行（L75-82）；错误文案（L84-88）；footer 按能力分两套文案（L92-98）。
- `L104 private var policySection` — `Picker("后台返回锁定", selection: $security.lockPolicy)`（L106）遍历 `BiometricLockPolicy.allCases`；未启用时禁用（L112）。
- `L123 private var infoSection` — 三行 `LabeledContent`：认证方式（L125）、降级机制「5 次失败自动转密码」（L127）、密钥存储「Keychain（本机）」（L129）；footer 说明 Secure Enclave（L134）。
- `L141 private var stateTitle: String` — inactive/locked/authenticating/unlocked → 已关闭/已锁定/验证中/已解锁。
- `L150 private var securityBinding: Binding<Bool>` — 开 → `Task { await performEnable() }`；关 → **不直接改值**，而是 `showDisableAlert = true`（L158），把真正关闭推迟到二次认证。
- `L164 private func performEnable() async` — 置 `isEnabling` → `await security.enableWithGuidedFlow()` → 回写 `enableErrorMessage` 并记 warning 日志。
- `L176 private func performDisable() async` — `_ = await security.disableWithConfirmation()`。

#### 4. 与其它模块的依赖

- `BiometricSecurityManager.shared`（唯一）；`LogManager.shared`（域 `biometric`）；`BiometricLockPolicy`；设计系统 `displayFont` / `displayLabelFont` / `displaySymbolFont` / `Color.sjzAccent` / `Color.sjzGreen`。
- 入口：`TabBar.swift:10704`（「我的 → 应用设置」）。

#### 5. 技术债 / 风险 / 红线

- 🟢 **P3 强制解包**：`L85 Text(enableErrorMessage!)` —— 外层 L84 已用 `if enableErrorMessage != nil` 守卫，**当前安全**，但属可改进写法（`if let`）。
- **关闭流程设计正确**：L158 不直接把 Binding 置 false，避免「切换开关即关闭」绕过二次认证；真正关闭在 `performDisable`（L176）经 `disableWithConfirmation` 二次认证。属安全亮点。
- 文案一致性：L22/L39/L50 用「Face ID」统称，但 `capability.title` 在 Touch ID / Optic ID 设备上会显示对应名称（L79、L125），**标题与内容在非 Face ID 设备上不自洽**（例如 Touch ID 设备看到标题「Face ID 解锁」）。属国际化/命名债。

---

### `BiometricLockOverlayView.swift`（137 行）

#### 1. 顶层类型清单（3）

| 行号 | 类型 | 职责 |
|---|---|---|
| 15 | `struct BiometricLockOverlayView: View` | 全局锁定遮罩 |
| 119 | `private struct BiometricPageProtectionModifier: ViewModifier` | 敏感页进入即请求上锁 |
| 133 | `extension View` | 对外暴露 `biometricLockProtected(reason:)`（L135） |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例 / 无 @Published / 无持久化。`L16 @ObservedObject private var security = BiometricSecurityManager.shared`；`L17 @Environment(\.colorScheme)`；`L120 @ObservedObject`（Modifier 内）。

#### 3. 关键方法签名 + 行号 + 行为

- `L19 var body` — 全屏 `ZStack`：背景按 `colorScheme` 二分（深色 `Color(hex: "0B0D14")` L24；浅色 `LinearGradient` L28-30，`ignoresSafeArea()`）；内容区 `VStack(spacing: 28)`：能力图标圆环（L38-45，尺寸 104）、`SchoolInfo.name`（L47）+「身份验证」（L50）、状态区分支（L56-100）；底部固定说明文案（L104）；`.privacySensitive()`（L111）；`animation(..., value: security.lastErrorMessage)`（L112）。
- 状态分支（L57-99）：`security.state == .authenticating` → `ProgressView` +「正在验证身份…」（L58-63）；否则展示 `security.lastErrorMessage`（L65-74）、主解锁按钮（L75-89，`Task { await security.authenticate() }` L77，文案按 `capability.isUsable` 二选一 L82）、「前往系统设置」（L91-98，`security.openSystemSettings()`）。
- `BiometricPageProtectionModifier.body`（L123-130）— `content.onAppear { if security.needsLockRequest { security.requestLock(reason: reason) } }`。**遮罩本身不在 Modifier 内呈现**，由根视图统一挂载（L8 注释「遮罩由根视图统一呈现」）。
- `L135 func biometricLockProtected(reason: String = "sensitive_page") -> some View`。

#### 4. 与其它模块的依赖

- `BiometricSecurityManager.shared`、`SchoolInfo.name`、设计系统 `displayFont` / `displaySymbolFont` / `displayLabelFont` / `Color(hex:)`。
- **消费方**：`DesignCodeApp.swift:106`（根 ZStack 挂载遮罩）；`LogListView.swift:989/992`（`biometricLockProtected`，经 `LogPageLockPolicy` L980-995）。
- **零 UserDefaults**。

#### 5. 技术债 / 风险 / 红线

- 🟢 **P3 措辞**：L104「解锁前内容已加密遮挡」——实为视觉遮挡，非加密（同 B 组 P3）。
- **DEBUG 自测旁路**：`LogListView.swift:986` 在 `#if DEBUG` 下检查启动参数 `-uiTestOpenLogs` 以跳过上锁（L985-993），注释（L977-979）明确「仅影响 DEBUG 构建下的显式启动参数，Release 与正常 DEBUG 路径行为不变」。属合理设计，但**意味着存在绕过生物锁的代码路径**——虽被编译期隔离，若 `#if DEBUG` 误配（例如 Release 配置里残留 `DEBUG` 标志）即成真实漏洞。建议加构建期护栏。
- Modifier 用 `onAppear` 而非 `task`/`onChange`：页面被 TabView 预加载时 `onAppear` 可能早于用户实际可见（**未验证**该工程是否存在此场景），理论上会造成「未真正查看即上锁」。

---

## C · 隐私合规

### `PrivacyManager.swift`（449 行）

#### 1. 顶层类型清单（4）

| 行号 | 类型 | 职责 |
|---|---|---|
| 14 | `enum PrivacyDocumentType: String, CaseIterable, Identifiable` | `terms = "terms"` / `privacy = "privacy-policy"`；`title` L20、`icon` L27、**`url` L34-39**、`fallbackText` L41、`fallbackTitle` L48、`fallbackLastUpdated` L55 |
| 65 | `struct PrivacyDocument` | title / content / lastUpdated / source |
| 72 | `enum PrivacyDocumentSource: String` | `online = "online"` / `offline = "offline"` |
| 79 | `struct PrivacyCacheEntry: Codable` | content / title / lastUpdated / fetchTime / source |
| 90 | `final class PrivacyManager: ObservableObject`（`@MainActor`） | 单例管理器 |

#### 2. 单例形态 · @Published · 持久化

- 单例：`L91 static let shared = PrivacyManager()`；`L102 private init()` → `loadFromCache()`。
- `@Published private(set)`：`cachedDocuments: [PrivacyDocumentType: PrivacyDocument]` L93、`isLoading` L94、`currentError` L95。
- 常量：`cacheKey = "privacy_documents_cache"` L97、`cacheCooldown = 1800`（30 分钟）L98、`requestTimeout = 15.0` L99、`moduleName = "privacy"` L100。
- **持久化键（UserDefaults，JSON 编码）**：`"privacy_documents_cache_terms"` 与 `"privacy_documents_cache_privacy-policy"`（由 L382/L391/L445 的 `"\(cacheKey)_\(type.rawValue)"` 拼出，实测 rawValue 见 L15-16）。
- **网络端点（个人博客）**：`L36` `"https://www.43322.cn/blog/terms"`；`L37` `"https://www.43322.cn/blog/privacy-policy"`。
- 工程约束（头注释 L6）：「禁止 @AppStorage + didSet；禁止 @Sendable Task 捕获 inout」——本文件实际用 `UserDefaults.standard` 直调，未用 @AppStorage，**合规**。

#### 3. 关键方法签名 + 行号 + 行为

- `L108 func fetchDocument(type: PrivacyDocumentType) async -> PrivacyDocument` — **四级降级**：① 缓存命中且 `source == .online` 且距 `fetchTime` < 30 分钟 → 直接返回（L110-118）；② 网络拉取（L125-130）；③ 网络失败回落缓存（L133-137）；④ 缓存也无 → 内置离线文本（L140-143）。全程结构化日志。
- `L148 private func fetchOnlineDocument(type:) async -> PrivacyDocument?` — `URLRequest` 设 15s 超时、`.reloadIgnoringLocalCacheData`（L156-157）；**伪装 User-Agent**（L159：`"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)"`，注释 L158「确保 Docusaurus 返回完整 HTML」）；校验非 HTTP 响应（L164）、状态码 200（L170）、UTF-8 解码（L176）；URLError 细分文案（L196-203）。
- `L214 private func parseDocusaurusContent(html:type:) -> PrivacyDocument?` — 空内容即返回 nil（L219-221）。
- `L231 extractTitle(from:type:)` — `<h1>` → `<title>` → 兜底标题。
- `L255 extractDate(from:type:)` — `<time datetime="...">` → `<meta property="article:published_time" content="...">` → 兜底日期；取前 10 字符。
- `L283 extractArticleContent(from:type:)` — `<article>` → `<body>` → 整页；剔 script/style/nav/footer（L300-323）；块级标签换行（L326-329）；剥剩余标签（L332-336）；**手工解码 8 个 HTML 实体**（L339-347）；按行 trim + 过滤空行 + 双换行 join（L350-353）。
- `L357 private func firstMatch(pattern:in:) -> String?` — `NSRegularExpression` + `.dotMatchesLineSeparators` 包装。
- `L371 saveToCache(type:document:)` / `L390 readCacheEntry(for:)` / `L402 loadFromCache()` / `L420 getFallbackDocument(type:)` / `L429 getCachedDocument(type:)`（内存优先，回落 UserDefaults）/ `L443 clearCache()`。

#### 4. 与其它模块的依赖

- **强依赖 `PrivacyLegalTexts.swift`**：`fallbackText`（L41-46）/`fallbackTitle`（L48-53）/`fallbackLastUpdated`（L55-60）三处直接引用 `UserAgreementText` 与 `PrivacyPolicyText`。
- `LogManager.shared`（域 `privacy`）；`Foundation` / `SwiftUI`。
- **消费方**：`PrivacyPolicyView.swift:14`（HomeView）、`:152`（DocumentView）。

#### 5. 技术债 / 风险 / 红线

- 🟠 **P1 协议托管在个人博客**：`L36-37` 指向 `www.43322.cn`（开发者个人 Docusaurus 博客），**非学校官方域名 `www.sxjzit.edu.cn`**。风险：① App Store 审核要求隐私政策 URL 由开发者稳定控制，个人域名可用性/续费/所有权变更均不可控；② 高校主体应用的合规文本挂在个人域名，法务与品牌风险显著；③ 该域名同时承载公告抓取源（`AnnouncementManager.swift:46` `"https://www.43322.cn/blog/gonggao"`）与法律文本，**单点故障**：域名失效将同时打断公告与协议。
- 🟠 **P1 正则解析第三方 HTML 脆弱性**：`parseDocusaurusContent` 系列（L214-354）完全依赖博客 DOM 结构（`<article>`、`__blog-post-container` 风格约定、`<h1>`/`<time>`/`<meta>`）。博客主题升级即静默失效 → 回落到 `PrivacyLegalTexts` 离线文本。**失败是静默的**（仅 warning 日志，UI 无提示，`sourceIndicator` 会显示「离线」但用户未必理解后果）。无内容结构变化的监控/告警。
- 🟡 **P2 UserDefaults 存长文本**：`saveToCache`（L371-388）把整篇协议 HTML→纯文本后的内容 `JSONEncoder` 后写入 UserDefaults。UserDefaults 面向小配置项，承载长文本既影响启动读取耗时，也无容量管理。协议文本增长后风险上升。
- 🟡 **P2 实体解码不完整**：L339-347 只处理 8 个实体（`&amp; &lt; &gt; &quot; &apos; &#39; &nbsp; &#x27;`），**未处理数字实体（如 `&#8217;`、`&#x2F;`）与中文常见实体**，会残留 `&#...;` 于展示文本。
- **`@MainActor` 上做正则解析**：`extractArticleContent`（L283）在 `@MainActor` 类内、以 `String.replacingOccurrences(options: .regularExpression)` 对整篇 HTML 做 10+ 轮全量正则替换（L300-336）。大页面（博客含内联样式/脚本）在主线程可能造成可感知卡顿。**未做性能实测（未验证）**。
- 无重试策略 / 无退避：网络失败直接降级（L132-143），下次进入页面才重试（受 30 分钟冷却与 `cachedDocuments[type].source == .online` 双重条件影响——**注意：若缓存来自 offline 来源，L110 条件不成立，会每次进页都重新发起网络请求**，属行为不一致的小瑕疵）。

---

### `PrivacyPolicyView.swift`（796 行）

#### 1. 顶层类型清单（5）

| 行号 | 类型 | 职责 |
|---|---|---|
| 13 | `struct PrivacyPolicyHomeView: View` | 隐私主页（文档卡片列表） |
| 149 | `struct PrivacyDocumentView: View` | 文档详情页（在线/缓存/离线三态） |
| 372 | `struct PrivacyConsentView: View` | 首次启动隐私同意弹窗 |
| 618 | `struct ScalingButtonStyle: ButtonStyle` | 按压缩放按钮样式（`makeBody` L619） |
| 632 | `struct RestrictedModeView: View` | 拒绝隐私协议后的受限模式 |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、无 @Published。`L14`/`L152` `@ObservedObject private var privacyManager = PrivacyManager.shared`。
- `@Binding`（关键，同意门控的实际读写口）：`PrivacyConsentView` L373 `showConsent`、L374 `consentAccepted`；`RestrictedModeView` L633 `showRestricted`、L634 `showConsent`。
- 闭包注入：`onAccept` L375、`onReject` L376；`isFromRestrictedMode: Bool = false` L377。
- 局部 `@State`：L15 `selectedDocument`、L16 `navigationDocument`（HomeView）；L153 `document`、L154 `loadState`（DocumentView）；L379/380 `showTerms`/`showPrivacy`（ConsentView）。
- **持久化键在 `DesignCodeApp.swift`**（不在本文件）：`L17 @AppStorage("privacyConsentAccepted")`、`L18 @AppStorage("privacyConsentRejected")`。
- 本文件同样带「禁止 @AppStorage + didSet」约束注释（L6），且**确实未用 @AppStorage**，改用 `@Binding` 向上传递，**合规**。

#### 3. 关键方法签名 + 行号 + 行为

- `L18 var body`（HomeView）— 顶部说明 `headerSection`（L43）+ 文档卡片 `documentCards`（L67）→ `documentCard(for:)`（L75）+ 图标三件套 `iconView` L120 / `iconBackgroundColor` L132 / `iconForegroundColor` L139。
- `L163 var body`（DocumentView）— 三态：`loadingView`（L206）、`errorView(_:)`（L318）、`documentContentView(_:)`（L225）；`sourceIndicator(source:)`（L254，展示 online/offline 来源）、`divider` L295、`updateDateLabel(_:)` L303。
- `L193 private func loadDocument() async` — 调 `privacyManager.fetchDocument(type:)` 并驱动 `loadState`；`L361 private func retry() async`。
- **同意门控链路（实测）**：
  - 弹窗接受：`L465 consentAccepted = true` → `L466 showConsent = false` → `L468 onAccept()`。
  - 弹窗拒绝：`L500 consentAccepted = false` → `L501 showConsent = false` → `L503 onReject()`。
  - `DesignCodeApp.swift:58-67` `onAccept`：记 INFO 日志（`previousState` = restricted/first_launch），若此前已拒绝则复位 `privacyConsentRejected = false`（L67）。
  - `DesignCodeApp.swift:76` `onReject`：置 `privacyConsentRejected = true`。
  - `DesignCodeApp.swift:168-189` 启动页结束后按 `privacyConsentAccepted`/`privacyConsentRejected` 决定：受限模式（L178 `showRestrictedModeAfterDelay()`）或同意弹窗（L184 `showPrivacyConsentAfterDelay()`）或正常启动。
  - **门控的真实效力**：`DesignCodeApp.swift:159-167` —— 微信 SDK 注册被 `privacyConsentAccepted` 硬门控；`:150-152` 通知轮询亦仅在已同意时恢复；`:103` 主界面渲染条件含 `privacyConsentAccepted`。
- `L572 private func agreementLink(...)` — 弹窗内两个协议查看入口（`showTerms`/`showPrivacy` L379-380）。
- `L636 var body`（RestrictedModeView）— 受限模式页；重试入口「查看并同意」（L733-755）→ 延迟 0.35s 后 `showConsent = true`（L728-731）。
- 🔴 `L759-764` **`exit(0)`**（详见下）。

#### 4. 与其它模块的依赖

- `PrivacyManager.shared`、`PrivacyDocumentType`、`PrivacyDocument`、`PrivacyDocumentSource`；`LogManager.shared`（域 `privacy`）；`GradientBackground()`（设计系统）。
- **入向**：`DesignCodeApp.swift:55-86`（`PrivacyConsentView`）、`DesignCodeApp.swift:220` 附近（`RestrictedModeView`）。
- 无其它 Manager 依赖，耦合面窄，属本组最干净的文件。

#### 5. 技术债 / 风险 / 红线

- 🔴 **P0 `exit(0)` —— App Store 审核红线**
  - **准确行号：`PrivacyPolicyView.swift:764`**。全库 grep `exit(` 仅此一处命中。
  - 上下文（L758-777）：
    ```
    758:                    // 退出应用按钮
    759:                    Button {
    760:                        LogManager.shared.warning("privacy", "受限模式中用户选择退出应用", context: [
    761:                            "action": "exit_app",
    762:                            "from": "restricted_mode"
    763:                        ])
    764:                        exit(0)
    765:                    } label: {
    766:                        Text("退出应用")
    ```
    位于 `RestrictedModeView`（L632）的 `body`（L636）内，是「用户拒绝隐私协议后」页面上的第二个按钮，前一个按钮是「查看并同意」（L737）。
  - **风险定性**：Apple **App Store 审核指南 2.5.4** 明确要求「Apps should never quit programmatically」（应用不得自行退出）；人机界面指南同样禁止 `exit(0)`。该行为在**任何**代码路径上被发现都足以构成拒审理由，即便它只在用户拒绝协议后才可达。附带风险：`exit(0)` 不执行正常终止流程，可能丢日志/损坏落盘数据（此工程日志有 `flushPendingNow` 机制，但 `exit` 不触发 `scenePhase` 回调）。
  - **矛盾点（值得在 Wiki 中点名）**：`L629-631` 的注释自称「符合 Apple 5.1.1 合规要求 —— 不强制同意，但限制核心功能使用」。**「不强制同意」的设计方向正确**（提供受限模式而非死循环弹窗，这确实优于强制同意），但**实现手段 `exit(0)` 直接违反 2.5.4**，与注释的自我合规认定冲突。
  - **建议修法**：把「退出应用」改为「留在受限模式」或引导至系统设置/关闭说明页；若必须提供退出感，用 `UIApplication.shared.perform(#selector(NSXPCConnection.suspend))` 之类的**非退出**手段亦不被鼓励——最稳妥是彻底移除该按钮，保留「查看并同意」单一出口 + 说明「您可随时从后台关闭应用」。

- 🟡 **P2 同意状态可绕过 UI 直接篡改**：门控判据是 `@AppStorage("privacyConsentAccepted")`（`DesignCodeApp.swift:17`），即 UserDefaults。真机非越狱环境下用户无法直接改写，风险低；但**该状态与「同意」的法律含义绑定，却无时间戳/版本号记录**——协议更新（`PrivacyLegalTexts.swift:110` 更新日期 2026-09-27）后**不会重新征求同意**。`PrivacyLegalTexts.swift:259-260` 声称「更新后的隐私政策将在应用内以弹窗或公告方式通知您」，但代码层无「协议版本变更 → 重新弹窗」逻辑。→ **合规缺口**：政策实质变更后继续沿用旧同意，不满足《个人信息保护法》第 14 条「重新取得同意」要求。
- 🟡 **P2 无「撤回同意」入口**：`PrivacyLegalTexts.swift:238` 承诺「7.5 撤回同意权：您可在应用设置中撤回对通知权限的授权」——只覆盖通知权限；**隐私协议本身的同意无撤回入口**（受限模式只在「从未同意/首次拒绝」时进入）。承诺与能力不匹配。
- **受限模式双 Binding 设计**：`showRestricted`（L633）+ `showConsent`（L634）双绑定，`onDisappear` 日志用 `showConsent ? "consent_dialog" : "exit"`（L793）推断去向——**该推断在用户直接杀进程时不成立**（onDisappear 不触发），日志语义不够严谨。
- 无深链/无分享，攻击面小。

---

### `PrivacyLegalTexts.swift`（276 行）

#### 1. 顶层类型清单（2）

| 行号 | 类型 | 职责 |
|---|---|---|
| 13 | `enum UserAgreementText` | 用户协议离线全文；`lastUpdated = "2026-08-09"`（L14）、`title = "用户协议"`（L16）、`fullText`（L19-104） |
| 109 | `enum PrivacyPolicyText` | 隐私政策离线全文；`lastUpdated = "2026-09-27"`（L110）、`title = "隐私政策"`（L112）、`fullText`（L115-275） |

#### 2. 单例形态 · @Published · 持久化

- **纯静态常量枚举，无实例、无单例、无 @Published、无持久化**。被 `PrivacyManager.fallbackText/fallbackTitle/fallbackLastUpdated`（L41-60）消费。

#### 3. 关键内容区块 + 行号（文本即"方法"）

| 行号 | 内容 |
|---|---|
| 19-104 | 用户协议全文 |
| 22-23 | 更新日期/生效日期 2026年8月9日 |
| 29 | 一、协议范围与适用 |
| 48 | **2.2 信息内容来源声明**：学校官网 `www.sxjzit.edu.cn` + 开发者自建博客 `www.43322.cn` |
| 96 | 开发者博客 `https://www.43322.cn` |
| 118-119 | 隐私政策更新/生效日期 2026年9月27日 |
| 125-145 | 一、我们收集的信息（1.1 设备信息 L129-131；1.2 应用使用信息 L133-135；**1.3 明确不收集的信息 L137-145**） |
| 139 | 不收集位置信息 |
| 140 | **不收集生物识别信息**（表述准确） |
| 143 | **不读取剪切板**（与实现有张力，见 A 组 P1） |
| 145 | 不收集 IDFA / IDFV / UDID |
| 147-163 | 二、信息的存储（2.1 存储位置 L149-150；2.2 存储内容 L152-157；2.3 存储期限 L159-163，日志保留 7 天 L161） |
| 193-204 | **4.3 第三方 SDK 清单（微信开放平台 SDK）**（L197 名称、L199 目的、L200 可能处理的信息、L201 共享方式、L202 指向 `https://privacy.qq.com`、L204 声明无其他第三方 SDK） |
| 206-219 | 五、权限说明（5.1 网络 L210-212；5.2 通知 L214-217；**5.3 不申请权限清单 L219**） |
| 221-228 | 六、数据安全 |
| 230-239 | 七、您的权利（7.1-7.6） |
| 241-246 | 八、未成年人保护 |
| 248-255 | 九、联系我们（L252 开发者博客、L253 学校官网） |
| 257-264 | 十、隐私政策更新 |
| 266-275 | 十一、合规声明（L269-273 列 PIPL/网安法/数安法/认定方法/Apple 审核指南；L275 自称符合 Apple 隐私标签且不收集链接到身份的数据） |

#### 4. 与其它模块的依赖

- 仅 `import Foundation`。**零出向依赖**。被 `PrivacyManager` 引用（L43-44、L50-51、L57-58）。

#### 5. 技术债 / 风险 / 红线

- 🔴 **P0 `L219` 与实现直接矛盾**（详见 B 组 P0）。原文：
  「5.3 本应用不申请以下权限：相机、麦克风、相册读写、通讯录、日历、运动与健康、HomeKit、蓝牙、**Face ID / Touch ID**。」
  实际申请项：`Info.plist:67-68` `NSFaceIDUsageDescription`；`BiometricSecurityManager.swift:242` 生物识别策略评估。**同时** `Info.plist:69-70` 声明 `NSPhotoLibraryAddUsageDescription`（相册**写入**），而 L219 写「不申请……相册读写」——虽「写入」≠「读写」，但表述上易被审核判定不一致（建议改为「相册写入（仅保存图片，不读取相册内容）」，与 plist 文案 L70 对齐）。→ **L219 一句同时与 Face ID 和相册两项实现冲突**。
- 🟠 **P1 协议更新机制无代码支撑**：L259「更新后的隐私政策将在应用内以弹窗或公告方式通知您」+ L260「重大变更显著位置提示」——代码中**无版本比对逻辑**（`DesignCodeApp.swift` 只有 `privacyConsentAccepted` 布尔值，无 acceptedVersion）。属**承诺未实现**。
- 🟠 **P1 L252 联系方式仅为个人博客**：隐私政策「九、联系我们」只给开发者博客 `https://www.43322.cn` 与学校官网，**无邮箱、无电话、无实体地址**。国内合规实践中，个人信息保护负责人联系方式属必备项；Apple 审核也可能要求可用的联系方式。属合规缺口。
- 🟡 **P2 文本与代码的维护性风险**：隐私文本是硬编码 Swift 多行字符串（L19-104、L115-275），与实现（Info.plist 权限、SDK 清单、存储路径、保留天数）**无任何自动化一致性校验**。L161 写「应用日志默认保留 7 天」需与 `LogManager.retentionDays` 默认值一致；L204 写「未嵌入任何其他第三方 SDK」需与依赖清单一致——目前全靠人工同步。本 P0 矛盾（L219）正是这类漂移的实例。**建议引入契约测试**：解析 plist 权限键与 Swift 源码 SDK 引用，断言与文本清单一致。
- **正面评价**：L193-204 的第三方 SDK 清单披露**质量高于多数同类应用**（含 SDK 名称、提供方、使用目的、处理信息、共享方式、隐私指引链接），且明确「仅在您主动点击时交互」。L204「不涉及用户画像、个性化广告或任何形式的用户追踪」与 L275「不收集任何链接到用户身份的数据」内部自洽。
- **语料真实性**：头注释（L6）声明「如实匹配本 App 真实能力，不编造任何不存在的数据采集行为」。经与 Info.plist + 各 Manager 比对，**除 L219 权限清单外，其余声明与实现基本吻合**（无位置、无通讯录、无 IDFA、无账号体系，均与源码一致）。

---

## D · 日志

### `LogListView.swift`（1355 行）

#### 1. 顶层类型清单（10）

| 行号 | 类型 | 职责 |
|---|---|---|
| 19 | `private struct ExportData: Identifiable` | 导出数据模型；注释 L17-18 说明用 `.sheet(item:)` 而非 `.sheet(isPresented:)` 以**消除同帧求值时序导致的空数据竞态** |
| 27 | `struct LogListView: View` | 日志查看页主视图 |
| 980 | `private struct LogPageLockPolicy: ViewModifier` | 生产路径挂生物锁；DEBUG 自测截图模式旁路 |
| 999 | `private struct LogFilterKey: Equatable` | 筛选缓存键（topID / count / level / module / query） |
| 1007 | `private final class LogFilterCache: ObservableObject` | 筛选结果引用盒（同帧多次取值只算一次） |
| 1022 | `private struct LogBanner: Equatable` | 操作反馈横幅模型（`Tone` 枚举） |
| 1040 | `private struct FilterChip: View` | 筛选标签芯片 |
| 1071 | `private struct LogRowView: View` | 日志行（含展开、滑动操作） |
| 1201 | `private struct LogDetailCard: View` | 日志详情卡 |
| 1343 | `private struct ExportSheetView: UIViewControllerRepresentable` | `UIActivityViewController` 包装 |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、**无 @Published**（全部状态在 `LogManager.shared`：L28 `@ObservedObject private var logManager = LogManager.shared`）。
- `@StateObject private var filterCache = LogFilterCache()`（L71）。
- `@Environment`：`accessibilityReduceMotion` L29、`dismiss` L30。
- **本文件零持久化写入**。日志落盘路径由 LogManager 决定，UI 展示于 `LogSettingsView.swift:126` 注释：`Documents/SXJZIT_Cache/Logs`。

#### 3. 关键方法签名 + 行号 + 行为

**三维筛选（级别 × 模块 × 关键词）**
- 状态：`selectedLevel: LogLevel?` L34、`selectedModule: String?` L35、`searchText` L36、`searchDebounceTask` L38。
- 判据：`hasActiveFilter` L101-103（三维任一非空）；`trimmedQuery` L81-83；`isSearching` L85。
- UI：`filterChips` L407-425（「全部」+ 各级别，`selectLevel(selectedLevel == level ? nil : level)` 实现点选切换 L417）；`moduleMenu` L427-461（模块菜单，选项来自 `logManager` 模块集合，选中即记日志含 `matched` 计数 L479）；`searchBar` L485-539（Liquid Glass + 聚焦描边 + 防抖，占位符 L490 提示「空格分隔多条件」）。
- 动作：`selectLevel(_:)` L463-471、`selectModule(_:)` L473-481（均记 INFO + `matched` 计数）、`resetFilters()` L755-762。
- **缓存**：`filteredEntries` L88-97 —— 用 `(topID, count, level, module, query)` 组 key，命中即复用；注释 L87「日志实时流入时避免同一渲染帧内多次 O(n) 重算，保障滚动/流式丝滑」。`LogFilterCache.result(key:compute:)` L1011-1017。

**日期分组**
- **非 `Dictionary(grouping:)`**，而是手动线性分段（保持倒序、组内连续）：`DaySection` L106-110（id/title/entries）+ `daySections` L112-134（内嵌 `flush()`，单趟 O(n)）。
- 标题：`dayTitleFormatter` L136-140（`"yyyy年MM月dd日"`）+ `dayTitle(for:)` L142-147 → 今天 / 昨天 / 具体日期。
- Section 头：`daySectionHeader(_:)` L597-609（标题 + 条数胶囊）。渲染：`List` + `ForEach(daySections)` L551-561。

**跟随最新**
- 状态：`followLatest = true` L45、`pendingNewCount` L46、`lastSeenTopID` L47、`isAtTop = true` L50、`lastFollowScrollAt` L52、`scrollToTopRequest` L54。
- 触发链：`.onChange(of: logManager.entries.first?.id)` L572-581 —— **双条件守卫** `guard followLatest, isAtTop`（L574）+ **0.25s 节流**（L576，注释 L51：「日志洪峰时每 0.25s 最多一次，防动画排队导致抖动」）；新日志计数 `pendingNewCount` 由 L258-273 维护。
- **顶部判定（关键技术决策）**：`onScrollGeometryChange` L567-571，`contentOffset.y <= 60` 视为置顶。注释 L564-566 说明：**「阈值含容差（sheet 呈现/布局早期会有小幅偏移抖动，12pt 曾误判导致开页即出现「N 条新日志」胶囊）」**——从哨兵行改为滚动几何，是一次明确的缺陷修复记录。
- 暂停/恢复：`followToggle` L319-345（恢复跟随时 `pendingNewCount = 0` + `scrollToTopRequest += 1`）；`newLogsPill` L346-377；`scrollToTop(_:)` L589-595。

**详情卡**
- `LogDetailCard`（L1201-1317）；行内展开 `expandedIds` L42（`toggleExpand` L883-891）；`LogRowView`（L1071-1198，`showsToggle` L1081）；关键词高亮 `logHighlighted(_:keyword:)` L1320-1338（`AttributedString` 口径，与消息中心/收藏页统一）；复制 L893-903（`copiedId` L44）；删除 L905-916。
- `detailEntry` L43 驱动详情卡呈现。

**导出（含按当前筛选导出）**
- `private enum ExportScope { case filtered, all }` L920。
- `exportScopeTitle(filtered:)` L927-934 —— 标题由三维筛选拼装（`级别=… · 模块=… · 关键词=…`）。
- `exportTag(filtered:)` L936-943 —— 文件名标签（`level-module-search`，缺省 `all`）。
- `performExport(scope:format:)` L945-962 —— 空集给 warning 横幅；调 `logManager.export(entries:title:format:)` + `logManager.exportFileName(tag:format:)`；置 `exportData` 驱动 sheet；日志含 `scope`/`format`/`count`/`fileName`。
- `exportTextForCurrentFilter()` L922-925；`ExportSheetView` L1343-1355（`UIActivityViewController`）；菜单 `exportMenu` L798-831。

**实时统计**
- `stats: LogStats { logManager.stats() }` L99（**每次 body 求值都调一次**，实现体在 LogManager）。
- `statsBar` L285-316：共 N 条（L291）、今日 N（L296，仅 >0 显示）、今日异常 N（L302，橙色胶囊）；数字用 `.contentTransition(.numericText())`（L294/299）。
- 存储快照**异步**：`storageSnapshot` L68 + `refreshStorageSnapshot()` L964-972（`Task { await logManager.storageSnapshot() }`，注释 L66「存储快照（异步统计）」）。

**空态与确认**
- 三态空态：`emptyState` L686-721（无日志）、`filteredEmptyState` L722-748（筛选无结果）、`filteredEmptyTitle` L749-754（按已选维度给差异化文案，L750「该级别下没有此模块日志」）。
- 三个清空确认：`showClearAllConfirm` L60、`showClearFilteredConfirm` L61、`showClearTodayConfirm` L62；清空动作调 `logManager.removeEntries(level:module:query:)`（L217，按当前筛选）。
- `showSettings` L63 → `LogSettingsView`；`ellipsisMenu` L832-880；`toolbarContent` L767-797。

**生物锁策略**
- `LogPageLockPolicy`（L980-995）：`#if DEBUG` 下检查启动参数 `-uiTestOpenLogs` → 命中则**不挂锁**（L986-988），否则 `content.biometricLockProtected(reason:)`（L989）；`#else` 分支直接挂锁（L992）。注释 L977-979 界定「仅影响 DEBUG 构建下的显式启动参数，Release 与正常 DEBUG 路径行为不变」。
- 时间鲜活：`now` L75 + `minuteTimer` L77（`Timer.publish(every: 60, ...)`）；停留时长 `openedAt` L76。

#### 4. 与其它模块的依赖

- `LogManager.shared`（唯一强依赖）：`entries`、`filtered(level:module:query:)`（L95/L479/L503）、`stats()`（L99）、`removeEntries(level:module:query:)`（L217）、`export(entries:title:format:)`（L924/L952）、`exportFileName(tag:format:)`（L953）、`storageSnapshot()`（L966）。
- `LogLevel`、`LogEntry`、`LogStats`、`LogStorageSnapshot`、`LogExportFormat`（均定义于 `LogManager.swift`）。
- `BiometricSecurityManager`（经 `biometricLockProtected`，L989/992）。
- `LogSettingsView`（L63 触发）、`UniformTypeIdentifiers`（L13）、`Combine`（L12，Timer publisher）。
- **自反馈风暴防线不在本文件** —— 实现位于 `LogManager.swift:447`（同 module+message 1 秒内高频重复折叠）、`L470-537`（MARK「日志风暴抑制（自反馈防线）」），`L474` 注释「全局 1 秒窗口内的记录上限（**跨键防线**：防「多键交替」型自反馈绕过同键折叠；契约测试锚点）」，`L490` 注释「① 全局速率防线（跨键）：任何日志风暴（含多键交替自反馈）都被限速」，抑制/结束横幅文案见 L523/L537。**历史事故原文**（`TabBar.swift:13059`）：「否则揭示日志会变成列表里的新行、新行再触发揭示日志，形成自反馈风暴拖死主线程（2026-09-28 现场实证）。」契约测试：`qin/DesignCodeTests/LogManagerTests.swift:431-452`（含「跨键交替型自反馈（每轮换不同 message）由全局速率防线兜底」L452）。

#### 5. 技术债 / 风险 / 红线

- 🟡 **P2 缓存失效策略偏弱**：`LogFilterKey`（L999-1005）含 `topID` + `count`。日志洪峰时**每来一条新日志 key 即变**，缓存每次失效 → `filtered()` 每帧 O(n)。防线实际依赖 LogManager 的限速（`LogManager.swift:474`），**属跨模块耦合的隐式保障**：若他人放宽 LogManager 限速，本页会退化。建议 key 增加时间窗（如 100ms 内不重算）。
- 🟡 **P2 `daySections` 二次 O(n) 全量遍历**：`filteredEntries`（L88）已是 O(n)（缓存后 0 次），`daySections`（L112-134）在其上再走一趟全量并**构建全部 Section 数组**。列表已用 `List` 惰性渲染行，但**分组数组本身全量构建**。万条级日志下为可感知开销。**未做性能实测（未验证）**。
- 🟡 **P2 导出在主线程同步拼接**：`performExport`（L945）内 `logManager.export(...)` 同步生成整份文本（`exportData` 直接赋值，L954）。大日志量导出会阻塞主线程。`storageSnapshot` 已改用 `Task`（L964），导出路径**未做同样处理**，属不一致。
- **`stats` 每次 body 求值调用**（L99）—— **已实测核实：`LogManager.stats()`（`LogManager.swift:635-659`）内部有记忆化**（`let key = "\(entries.first?.id ?? "-")|\(entries.count)"`，L636；命中 `statsCache` 即返回，L637）。故正常情况为 O(1)。
  - ⚠️ **但缓存键与 `LogFilterKey` 同构**（`topID | count`）→ **每来一条新日志 key 即变**，`stats()` 与 `filtered()` 会在同一次 body 求值中**各自做一次 O(n) 全量遍历**（`stats()` 遍历全部 `entries` 统计 level 分布 + 今日/今日异常，L641-654）。两者叠加，洪峰期每帧潜在开销为 2×O(n)。
  - → 结论修正：这不是「未记忆化」缺陷，而是**记忆化键选择无法抵御持续流入**。真正的防线是 `LogManager` 的风暴限速（`LogManager.swift:474`）。与 `LogFilterKey` 属**同一设计模式的两处实例**，建议一并评估改为「时间窗 key」。
- **无 `#if DEBUG` 门控的启动参数读取**：`LogPageLockPolicy`（L985）在 Release 下整段被 `#if` 剔除，无风险（写法正确，作为正面示例）。
- 反馈横幅任务管理：`bannerDismissTask`（L59）在 `showBanner`（L394-404）内重建，需确认旧任务被取消以免悬挂（**未逐行验证**）。
- **正面**：L17-18 的 `ExportData` 竞态注释、L48-50 的滚动几何阈值修复注释（含「12pt 曾误判」的量化信息）、L51 的节流说明——本文件注释质量高，历史缺陷均有据可查。

---

### `LogSettingsView.swift`（273 行）

#### 1. 顶层类型清单（3）

| 行号 | 类型 | 职责 |
|---|---|---|
| 14 | `struct LogSettingsView: View` | 日志设置页 |
| 254 | `private struct LogSettingsExportData: Identifiable` | 设置页导出数据模型 |
| 262 | `private struct LogSettingsExportSheet: UIViewControllerRepresentable` | `UIActivityViewController` 包装（`makeUIViewController` L266） |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例 / 无 @Published。`L15 @ObservedObject private var logManager = LogManager.shared`；`L16 @Environment(\.dismiss)`。
- 局部 `@State`：`snapshot` L18、`showClearAllConfirm` L19、`showClearTodayConfirm` L20、`exportData` L21。
- **本文件零持久化写入**——但**四个设置项都通过 `$logManager.*` 双向绑定直写 LogManager 的 @Published**（这是本文件最关键的架构特征）：
  - `$logManager.debugEnabled`（L40 Toggle）
  - `$logManager.crashCaptureEnabled`（L44 Toggle）
  - `$logManager.maxEntries`（L61 Picker：1000/3000/5000/10000，L62-65）
  - `$logManager.retentionDays`（L74 Picker：3/7/14/30 天，L75-78）
- 实际持久化落在 `LogManager`（`LogManager.swift:289` `private let defaults: UserDefaults`，`init(defaults:storageDirectory:)` L395，**可注入以便单测隔离**）。

#### 3. 关键方法签名 + 行号 + 行为

- `L23 private var stats: LogStats { logManager.stats() }`；`L25 private var maxEntriesText: String`（上限文案）。
- `L35 var body` — 分区：记录控制（L40-51，含说明「两个开关运行中即时生效：关闭 DEBUG 可减少冗余存储；崩溃捕获关闭后立即停止写入崩溃日志，无需重启」L51）、容量与保留（L61-86，说明 L86「达到容量上限后最早日志自动移除（FIFO）；磁盘按天分文件、**单日上限 1000 条**；超过保留天数的历史日志自动清理。当前内存 N 条 / 上限 …」）、存储统计（L98-126，**L126「日志仅存储在本地（Documents/SXJZIT_Cache/Logs），不会自动上传」**）、导出与清理（L161-163）。
- 清空确认文案：全清 L190「将清空全部 N 条日志，此操作不可恢复」；今日 L203「仅清空今天产生的日志，历史日志保留」。
- `L226 private var levelBreakdownText: String` — 级别分布文案。
- `L232 private func refreshSnapshot()` — 异步取存储快照。
- `L240 private func prepareExport(scope:format:)` — 组装 `LogSettingsExportData`。

#### 4. 与其它模块的依赖

- `LogManager.shared`（唯一强依赖，且**通过 Binding 直接改写其 @Published 属性**——双向绑定跨模块，属隐式契约）。
- `LogStorageSnapshot`、`LogStats`、`LogExportFormat`、`LogManager.ExportScope`。
- 入口：由 `LogListView.swift:63` 的 `showSettings` / `ellipsisMenu`（L832-880）触发。

#### 5. 技术债 / 风险 / 红线

- **`$logManager.maxEntries` 直写（L61）**：Picker 的 selection 直接绑到 Manager 的 `@Published var maxEntries`。若 Manager 用 `didSet` 落盘 + 触发裁剪，则**每次拖动/切换都会立刻裁剪并对 `entries` 做全量处理**。Picker 只有 4 个离散档位，风险可控；但属「UI 直接驱动持久化副作用」的模式，与 `PrivacyManager.swift:6` 的工程约束精神（避免 didSet 承担持久化）相悖。**属同类反模式的第二例（第一例见 `BiometricSecurityManager.swift:181/199`）**。
- 🟢 **P3 存储路径只写在注释里（已实测确认风险成立）**：L126 的 `Documents/SXJZIT_Cache/Logs` 是**说明文案**，非代码常量。实测 `LogManager.swift:404` 的 `storageDir = storageDirectory ?? docs.appendingPathComponent("SXJZIT_Cache/Logs", isDirectory: true)` —— **当前两者一致 ✅**，但路径若在 LogManager 中变更，此处文案**不会同步**，会向用户展示错误路径。建议改为从 LogManager 读取常量插值。
- ✅ **容量/保留默认值已实测对账（文案与实现一致）**：
  - L86 文案「单日上限 1000 条」↔ `LogManager.swift:400` `maxEntriesPerFile: Int = 1000` ✅
  - L61 Picker 档位含 3000 ↔ `LogManager.swift:399` `defaultMaxEntries: Int = 3000` ✅（3000 即默认值）
  - L74 Picker 档位含 7 天 ↔ `LogManager.swift:398` `defaultRetentionDays: Int = 7` ✅
  - L61/L74 四个设置项均经 `$logManager.*` 绑定，落盘由 `LogManager.swift:325-340` 的 didSet 完成，键为 `SettingsKeys.maxEntries = "logMaxEntries"`（L296）与 `SettingsKeys.retentionDays = "logRetentionDays"`（L297）。
- 🟢 **P3 `maxEntriesPerFile` 不可配**：单日文件上限 1000 条（L400）是 `init` 参数但**未在设置页暴露**，仅作为文案说明（L86）。属有意设计（磁盘文件粒度与 UI 内存上限分离），文案已正确区分「内存」与「磁盘按天分文件」，表述清晰。
- 本文件已**正确使用 `LogManager` 的注入式 `defaults`** 设计（`LogManager.swift:395`），测试友好；但设置页本身无测试（UI 层）。

---

## E · 网络监测

### `NetworkMonitorView.swift`（1619 行）

#### 1. 顶层类型清单（3 + 1 私有扩展）

| 行号 | 类型 | 职责 |
|---|---|---|
| 21 | `struct NetworkMonitorView: View` | 网络监测页主视图 |
| 1551 | `private extension View` | `monitorCard()` 卡片修饰符（L1552） |
| 1570 | `struct FlowBars: View` | 流量等级条（**非 private**，可复用） |
| 1588 | `private struct Sector: Shape` | 雷达扫动扇形（`path(in:)` L1592） |

> `import Charts`（L17）—— 本文件是全库**唯一**使用 Swift Charts 的视图。

#### 2. 单例形态 · @Published · 持久化

- **本文件零 @Published**——所有指标状态在 `SJZNetworkMonitor.shared`（L22）。
- 观察：`@ObservedObject private var monitor = SJZNetworkMonitor.shared` L22、`cacheManager = CacheModeManager.shared` L23。
- `@Environment`：`scenePhase` L24、`colorScheme` L25、`accessibilityReduceMotion` L26、`displayFontScale` L29、`displayBold` L30、`displayFontFamily` L31、`displayTypographyRevision` L32。
- `@State`：`toastText` L34、`toastTask` L35、`chartSelectedDate` L37、`lastInteractionLogTime` L38、`refreshSuccessPulse` L39、`pulseScale` L435。
- **持久化（唯一一处 `@AppStorage`）**：`L41 @AppStorage(NetmonKey.samplingEnabled) private var liveSamplingEnabled: Bool = true`。
- 其余持久化键（定义在 `SJZNetworkMonitor.swift:25-31`，实测字面量）：
  | 键 | 行号 | 值 |
  |---|---|---|
  | `samplingEnabled` | L26 | `"netmonLiveSamplingEnabled"` |
  | `chartWindow` | L27 | `"netmonChartWindowSeconds"` |
  | `timeline` | L28 | `"netmonTimelineJSON"` |
  | `lastProbe` | L29 | `"netmonLastProbeJSON"` |
  | `traffic(day:)` | L30 | `"netmonTraffic_" + day`（按日分键，L1865 清理非今日键） |

#### 3. 关键方法签名 + 行号 + 行为（八能力逐项落地核查）

> 结论：**八项能力全部有真实实现，无占位**。逐项证据如下。

| # | 能力 | UI 分区（行号） | 数据/方法（行号） | 落地结论 |
|---|---|---|---|---|
| 1 | **状态** | `heroCard` L103-153；`radarLinkCard` L338-379 | `heroGradientColors` L154；`healthTier` L173；`healthColor` L180；`healthRing` L189；`healthRingProgress` L213；`healthGradeText` L218；`trendArrow` L225；`badgeRow` L233；`ipStackText` L256；`heroBadge` L265；`linkStatusColor` L282；`interfaceIcon` L290；`heroAccessibilityText` L299；`radarDisc` L380；`nodeDot` L422；`nodeLabel` L437；`radarNodeColor` L444；`infoLine` L450；`statusCapsule` L463；`propertyBadge` L478 | ✅ 真实：链路状态/接口/IP/网关/`isExpensive`/`isConstrained`/`linkQualityText`/IPv4/IPv6/DNS/接口数 + iOS 26 linkQuality |
| 2 | **流量** | `statsCard` L794-1000；`histogramBlock` L862；`attributionBlock` L915 | `trafficText` L858（`ByteCountFormatter`）；`domainColor` L980；`statCell` L984 | ✅ 真实：总流量/上下行/请求数/成功失败/峰值/并发/覆盖度 + 延迟四档直方图 + 流量域分布 |
| 3 | **延迟** | `latencyCard` L502-512（标题「响应延迟」L504） | `chartCanvas(kind:)` L528（`.latency` 分支，`LineMark` L564/L571）；`chartControls` L641；`windowChip` L662；`throughputColor` L683；`latencyColor` L693；`emptyChartCard` L702 | ✅ 真实：`Chart` 折线 + 心跳点弱化 + 触摸查值 + 延迟三档参考虚线（注释 L578「每图仅一次，不随样本循环冗余绘制」）+ 无障碍描述（L611 含平均值） |
| 4 | **体检** | `healthRing` L189-212（校园网健康分大环） | `HealthTier` L171（excellent/fine/fair/unknown）；`healthGradeText` L218（`"待诊断"` L222）；`consistencyHint` L1265 | ✅ 真实：健康分由 `SJZNetworkMonitor` 诊断输出驱动；`heroAccessibilityText` L304 含「尚未诊断」态 |
| 5 | **测速** | `speedTestCard` L1343-1409（「带宽测速」L1345） | `isSpeedTesting` L1041；`speedTestTrailingText` L1410；`speedGradeScore` L1419；按钮「测速/测量中」L1393 | ✅ 真实：一键带宽测速，用户点击触发 |
| 6 | **慢请求** | 慢主机 TOP3：L833-834 区块 + L917-935 渲染（`Text("慢主机 TOP3")` L919，`ForEach(monitor.slowHostsTop3)` L922） | `SJZNetworkMonitor.slowHostsTop3`；`SlowStreakVerdict`（`SJZNetworkMonitor.swift:211`）；`classifySlowStreak(hosts:)`（`:482`）；业务慢请求聚合（`:1068`，**60s 时间窗 + 宿主归因 + 横幅冷却**）；慢请求时间窗（`:446-448`） | ✅ 真实，且**做过误报根治**：`:1082` 单一媒体宿主慢 → INFO 观测不打扰；`:1220` 「慢请求观测（媒体宿主 / 大负载，属正常）」 |
| 7 | **历史** | `timelineCard` L739-768（链路事件时间线）；「上次诊断 · 跨启动」L1114；「历史对比」L1198-1229 | `eventColor` L769；`eventTitle` L777；`LinkEvent`（`SJZNetworkMonitor.swift:161`）；`MinuteSummary`（`:304`，最近 1 小时分钟摘要）；持久化 `NetmonKey.timeline` / `NetmonKey.lastProbe` | ✅ 真实：断网/恢复/异常事件**跨启动持久化**（`SJZNetworkMonitor.swift:1792/1798` 读写 `netmonTimelineJSON`；`:1805/1810` 读写 `netmonLastProbeJSON`）+ 今日流量按日分键（`:1832/1837/1865`） |
| 8 | **诊断** | `probeCard` L1004-1340（「网络诊断」L1007） | `isProbing` L1036；`probeButtonTitle` L1046（诊断中…/重新诊断/开始诊断）；`probeContent` L1053；`probeDoneView(_:persisted:)` L1098；`smallActionButton` L1230；`gradeColor` L1249；`gradeIcon` L1257；`probeStat` L1275；`stageStat` L1286；`stageBar(_:)` L1296；`copyDiagnosticReport()` L1321；`shareSnapshot()` L1329 | ✅ 真实：**双目标各 5 轮冷连接探测**（文案 L1059「对网关 API 与官网门户各执行 5 轮冷连接探测，输出延迟分位、丢包与分阶段耗时。**仅在你点击时运行**。」）+ 健康分/建议/历史对比/复制报告 |

**其它组件**
- `anomalyBanner(_:)` L312（异常预警横幅，`AnomalyKind`）；`coverageText` L788；`concurrencyColor` L842；`successColor` L850；`cacheLinkCard` L1430（缓存联动，L1443「已为你节省流量 …」）；`optimizationHeadline` L1469；`footnote` L1478（诚实口径）；`toolbarContent` L1490；`toastOverlay` L1513；`showToast(_:)` L1526；`formatKBps(_:)` L1536（**自实现 KB/s 格式化，未用 `ByteCountFormatter`**）；`logChartInteraction(_:)` L1541（含 `lastInteractionLogTime` L38 节流）。
- 绘图：`FlowBars` L1570-1585（L1569 注释**「流量等级条：4 根竖条按吞吐等级点亮（诚实语义：非信号强度）」**）；`Sector` L1588-1604（`Shape`，雷达扇区）；`monitorCard()` L1552（Liquid Glass 统一卡片风格）。

#### 4. 与其它模块的依赖

- `SJZNetworkMonitor.shared`（`SJZNetworkMonitor.swift`，1918 行，本模块中枢）——`@Published` 全在彼处（实测 `:346-390+`：`pathStatus` L346、`unsatisfiedReason` L347、`interfaceName` L348、`isExpensive` L349、`isConstrained` L350、`linkQualityText` L352、`isUltraConstrained` L354、`supportsIPv4/6/DNS` L355-357、`interfaceCount` L358、`gatewayAddress` L359、`ipv4Address` L360、`isCampusLAN` L361、`linkTimeline` L365、`samples` L369、`totalRequests` L370、`successRequests` L371、`failedRequests` L372、`totalBytes` L373、`totalUpBytes` L375、`lastLatencyMs` L376、`latencySumMs` L377、`latencyHistogram` L378、`instantaneousKBps` L380、`peakKBps` L382、`inFlightCount` L384、`trendDirection` L386、`coveragePercent` L388、`minuteSummaries` L390）。
- `CacheModeManager.shared`（节省流量联动）；`Charts`；`displayFont*` 系列 + `displayTypographyRevision`（排版联动）。
- `URLProtocol` 记账：`NetworkMonitorLedger`（`SJZNetworkMonitor.swift:36`，`static let shared`，独立于 MainActor，供 URLProtocol 任意线程调用）；`SJZNetworkMonitorDiagnostics`（`:311`，收集 `URLSessionTaskMetrics` 分阶段 + 协议版本，`urlSession(_:task:didFinishCollecting:)` L328）。
- `ProbeTarget`（`:224`）/ `ProbeResult`（`:244`，含 `p50` L256 / `p90` L257 / `fastest` L258 / `slowest` L259）/ `ProbeSummary`（`:273`）/ `ProbeState`（`:282`）/ `SpeedTestState`（`:289`）/ `HealthAdvice`（`:296`）。

#### 5. 技术债 / 风险 / 红线

- **隐私姿态良好**：诊断/测速均**用户显式点击才运行**（L1059 明文声明），无常驻探测；`scenePhase`（L24）已注入但**未在本文件内用于暂停采样**（采样启停由 `@AppStorage(NetmonKey.samplingEnabled)` L41 手动控制）→ 若 App 退后台仍采样，会耗电（**该行为未在本文件验证，需查 SJZNetworkMonitor 的后台处理 → 未验证**）。
- 🟡 **P2 `formatKBps` 自实现**（L1536）：与 `attributionBlock`/`trafficText`（L858 用 `ByteCountFormatter`）**两套单位口径并存**，易出现「KB/s」与「KB」混排的观感不一致。建议统一。
- 🟡 **P2 单文件 1619 行、单 struct 承载体量**：`NetworkMonitorView` 有 **80+ 私有 computed property / 方法**（实测 L101-L1548），全部挂在同一个 `struct` 上。子组件仅 `FlowBars` / `Sector` 两个被抽出，其余（Hero、雷达、双曲线、时间线、统计、诊断、测速、缓存联动）均为计算属性内联。**可维护性债显著**：无法对单块做预览隔离，`body`（L43-100）虽只 12 行但展开面极大。
- **`chartCanvas`（L528-640）单函数 113 行**，内含 4 个 `ForEach`/`Chart` 分支与参考线绘制；`probeDoneView`（L1098-1229）**单函数 132 行**。属超长函数，重构候选。
- **诚实口径（正面）**：L1569 明确「非信号强度」；L11「诚实口径脚注」；L1059「仅在你点击时运行」；L611 无障碍描述含真实平均值。本文件在**避免夸大**上属工程正面案例，与 `BiometricLockOverlayView.swift:104`（夸大措辞）形成对比。
- 无障碍与减弱动效：`accessibilityReduceMotion`（L26）+ `heroAccessibilityText`（L299）+ 多处 `.accessibilityLabel`（L407 等），覆盖较全。
- 无 `#if DEBUG` 内容；无敏感信息落盘（测量数据全在 UserDefaults 的 JSON 键中，均为性能指标，无 URL 全文）。

---

## F · 显示 / 缓存 / 首页设置

### `DisplaySettingsView.swift`（2320 行）

#### 1. 顶层类型清单（6）

| 行号 | 类型 | 职责 |
|---|---|---|
| 16 | `struct DisplaySettingsView: View` | 显示设置主视图（12 Section） |
| 2268 | `private struct ConditionalBounceModifier<V: Equatable>: ViewModifier` | reduceMotion 门控的 symbol bounce |
| 2282 | `private struct NumericTransitionConditionalModifier: ViewModifier` | reduceMotion 门控的数字过渡 |
| 2293 | `private extension View` | `displayBounce(reduceMotion:options:value:)` L2294、`displayNumericTransition(reduceMotion:)` L2298 |
| 2305 | `private struct CardPressStyle: ButtonStyle` | 卡片按压（scale 0.97 回弹，reduceMotion 门控；`makeBody` L2307） |
| 2316 | `private extension DisplaySettingsManager` | `activeBrightness`（L2318，读 `UIScreen` 实时亮度） |

> `DisplaySettingsManager` 本体**不在本文件**，位于 `DisplaySettingsManager.swift:569`（2692 行级大文件）。

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、**无 @Published**（全部在 Manager）。`L17 @ObservedObject private var settings = DisplaySettingsManager.shared`。
- `@Environment`（系统能力镜像，L18-21）：`accessibilityReduceMotion`、`accessibilityReduceTransparency`、`colorSchemeContrast`、`colorScheme`。
- `@State`（16 项，L22-43 + L305）：`showResetAlert` L22、`selfCheckTick` L24、`customHexText` L26、`enteredAt` L28（**F14 埋点**）、`exposedSections` L30（**F14 曝光去重**）、`themeRipple` L32、`lastDiceAt` L34、`schemeTicker` L36、`themeRippleToken` L38、`toastText` L40、`toastWorkItem` L41、`showFontBatchDialog` L43、`heroShineSwept` L305（L306）。
- **本文件零持久化写入**。Manager 侧键（实测 `DisplaySettingsManager.swift:576-600`）：
  `appearanceKey="colorSchemePreference"` L576、`accentKey="displayAccentStyle"` L577、`fontSizeKey="displayFontSizeTier"` L579、`boldKey="displayBoldText"` L580、`systemFontKey="displayUseSystemFont"` L581、`fontFamilyKey="displayFontFamily"` L582、`lineSpacingKey="displayLineSpacing"` L583、`trackingKey="displayLetterSpacing"` L584、`buttonShapeKey="displayButtonShapes"` L585、`brightnessKey="displayBrightness"` L586、`autoBrightKey="displayAutoBrightness"` L587、`autoLockKey="displayAutoLock"` L588、`keepAwakeKey="displayKeepAwake"` L589、`articleTextColorKey="displayArticleTextColorPreset"` L591、`articleTextCustomHexKey="displayArticleTextCustomHex"` L592、`readingStatsKey="displayReadingStatsEnabled"` L593、`readingCharCountKey="displayReadingCharCountEnabled"` L594、`readingTimeKey="displayReadingTimeEnabled"` L595、`readingListBadgeKey="displayReadingListBadgeEnabled"` L596、`readingSpeedKey="displayReadingSpeedTier"` L597、`grayScaleKey="displayGrayScaleMode"` L598、`customColorHistoryKey="displayCustomColorHistory"` L599、`changeHistoryKey="displayChangeHistory"` L600。
  另有 `ReadingStatsCache` 三键（同文件 L2427-2429）：`storageKey="readingStatsCache"`、`lastResolvedKey="readingStatsLastResolved"`、`diagKey="readingStatsDiag"`。
- Manager 的 `@Published` 共 **30 项**（实测 `DisplaySettingsManager.swift`）：可写 20 项（`appearanceMode` L605、`themeStyle` L610、`fontSizeTier` L615、`boldTextEnabled` L624、`useSystemFont` L636、`fontFamily` L645、`lineSpacingFactor` L654、`letterSpacingValue` L659、`buttonShapesEnabled` L664、`brightnessValue` L669、`autoBrightnessEnabled` L679、`autoLockOption` L699、`keepAwakeEnabled` L714、`articleTextColorPreset` L738、`articleTextCustomHex` L752、`readingStatsEnabled` L774、`readingCharCountEnabled` L779、`readingTimeEnabled` L784、`readingListBadgeEnabled` L789、`readingSpeedTier` L794、`grayScaleEnabled` L799）+ `private(set)` 9 项（`lowPowerModeEnabled` L735、`systemReduceMotion` L818、`systemReduceTransparency` L819、`systemDarkerColors` L820、`systemVoiceOverRunning` L822、`customColorHistory` L827、`changeHistory` L829、`fontAvailability` L836、`typographyRevision` L838）。
  另有派生只读 `nonDefaultChangeCount`（`DisplaySettingsManager.swift:1146`，被 L250 与本文件的 hero 徽章、以及 `TabBar.swift:10612` 的 F16 摘要行消费）。

#### 3. 关键方法签名 + 行号 + 行为（12 Section / F 编号映射）

`L52 var body` — `Form` 顺序（L53-64）：`heroPreviewSection` → `appearanceSection` → `schemeSection` → `typographySection` → `articleTextColorSection` → `readingStatsSection` → `screenSection` → `autoLockSection` → `keepAwakeSection` → `accessibilitySection` → `historySection` → `otherSection`。`.navigationTitle("显示设置")` L65。`onAppear` L66-84（自检刷新 + Hero 扫光复位，reduceMotion 门控 L77-83）；`onDisappear` L85-91（停留时长 + 曝光 section 数）；恢复默认 alert L92-104；toast overlay L105-113。

| Section | 行号 | F 编号 | 预览/交互组件 |
|---|---|---|---|
| **Hero 实时预览** | `heroPreviewSection` L153 | **F1** | `toneDot` L241、`heroStatusBadge` L249（非默认项计数）、`heroAurora` L266、`heroShine` L289（3.2s 单次慢扫光） |
| **外观** | `appearanceSection` L324 | **F2 / F3** | `appearanceModeCard(_:)` L367、`modeIcon(_:)` L407、`themeBadge(_:)` L416（3 模式卡 + 5 主题图鉴 + 涟漪） |
| **排版方案** | `schemeSection` L470 | **F4** | `schemeCard(_:)` L487（3 套一键套装） |
| **文字排版** | `typographySection` L536 | **F5 / F6 / F7 / F19** | `fontSizeRulerCard` L579（6 档刻度尺）、`fontFamilyGallery` L647 + `fontFamilyCell(_:)` L705（真字貌）、`fontStateBadge(state:family:)` L774、`fontStateLine(family:state:)` L807、`lineSpacingABCard` L819、`letterSpacingABCard` L886、`fontGalleryMissingFamilies` L640 |
| **文章文字颜色** | `articleTextColorSection` L955 | **F8 / F9 / F10 / F17** | `paperPreviewCard` L1001（白纸/深纸双面）、`contrastCheckCard` L1065（WCAG 自检）、`contrastStatusBadge` L1095、`contrastEnvironmentRow` L1117、`contrastLevelColor` L1140、`contrastLevelText` L1148、`articleColorCard(_:)` L1180、`customColorPanel` L1257、`historyColorDot(_:)` L1371（最近 6 色）、`customColorBinding` L1398、`isCustomHexValid` L1448、`applyCustomHexIfValid` L1453、`articleColorFooterText` L1156、`articleColorStatusCapsule` L1164 |
| **阅读统计** | `readingStatsSection` L1466 | — | `readingStatsFooterText` L1626、`readingStatsStatusCapsule` L1646、`readingStatsLastText` L1665、**角标设置预览** `badgePreviewCapsule(_:)` L1686（`BadgePreviewSample`）、`readingPreviewResult` L1706 |
| **屏幕** | `screenSection` L1716 | **F11** | `effectiveBrightness` L1776、`brightnessSunSize` L1780、`brightnessSunIcon` L1784、`brightnessSunColor` L1788、`brightnessPresetCapsule(_:)` L1793（25/50/75/100%）、`userBrightnessText` L1825 |
| **自动锁定** | `autoLockSection` L1834 | — | 7 档（30s~永不） |
| **屏幕常亮** | `keepAwakeSection` L1867 | — | `idleTimerDisabledNow` L1984、`idleTimerNowText` L1988、`diagnosticGuidanceText` L1992、`keepAwakeStatusText/Icon/Color` L1999/2011/2021、`keepAwakeFooter` L2025 |
| **辅助功能** | `accessibilitySection` L2034 | **F12 / F18** | `accessibilityRow(title:icon:enabled:guidance:)` L2097（5 行 + 灰度专注） |
| **最近改动时间轴** | `historySection` L2129 | **F13** | `timelineRow(_:isLast:)` L2177（20 条 ring buffer） |
| **其他** | `otherSection` L2220 | **F15** | ShareLink 摘要 + 恢复默认 + 版本号 `versionText` L45 |
| （页面埋点） | `exposeSection(_:)` L118 | **F14** | `enteredAt` L28 + `exposedSections` L30 |

**通用工具**：`exposeSection(_:)` L118（曝光去重入 `exposedSections`）、`showToast(_:)` L124（`toastWorkItem` 管理）、`toastCapsule(_:)` L136。

#### 「十九项 UI」的准确口径（**重要更正**）

- 源码与工程文档使用 **F1–F19 特性编号**（`qin/docs/code-wiki/02-主要模块职责.md:320-332` 逐行对应；`01-项目整体架构.md:143` 明确「DisplaySettingsView.swift … **12 Section，F1–F19**」）。
- **实测：本文件只覆盖 18 个编号** —— F1、F2、F3、F4、F5、F6、F7、F8、F9、F10、F11、F12、F13、F14、F15、F17、F18、F19。全库 `grep -rn 'F16'` 在 `qin/DesignCode/` 下**零命中**。
- **F16 不在本文件，而在 `TabBar.swift`**：`.trae/documents/display-settings-revamp-spec.md:42` 定义「F16 | SettingsView 摘要行升级 | 「外观 · 字号 · 主题色」+ 非默认计数徽章」；实测实现位于 `TabBar.swift:10593`（`Text("外观 · 字号 · 主题色")`）+ `TabBar.swift:10612-10613`（`displaySettings.nonDefaultChangeCount` 徽章）+ `TabBar.swift:10626`（副标题）。
- ✅ **结论**：所谓「显示设置十九项 UI」= **F1–F19 全工程特性编号**，其中 **18 项在本文件的 12 个 Section 内**，**第 19 项（F16）是「我的 → 应用设置」入口的摘要行**，跨文件落在 `TabBar`。
  👉 **建议 Wiki 措辞**：「显示设置页以 12 个 Section 组织 F1–F15、F17–F19 共 18 项能力；第 19 项 F16（设置入口摘要行 + 非默认项徽章）实现在 TabBar 的设置入口，不在本文件」——避免读者按「本文件含 19 项」去数 Section 而对不上。

#### 4. 与其它模块的依赖

- `DisplaySettingsManager.shared`（唯一状态源，30 个 @Published + 23 个持久化键）。
- 辅助纯函数类型（跨文件）：`DisplayThemeStyle`、`DisplayAppearanceMode`、`DisplaySchemePreset`、`DisplayFontSizeTier`、`DisplayFontFamily`、`DisplayFontAvailability`、`ArticleTextColorPreset`、`DisplayAutoLockOption`、`ReadingSpeedTier`、`DisplayChangeRecord`、`DisplayContrastChecker`（`ContrastLevel`）、`ReadingStatsCalculator`（`Result`）、`ReadingStatsCache.shared`（L70-74、L1706）、`DisplayHistoryOperator`、`BadgePreviewSample`、`SJZImageFreePlaceholder`（`CacheModeSettingsView` 同族）。
- `LogManager.shared`（域 `"display"`，L69/L88 等）。
- `UIKit`（brightness / idleTimer / 触感）。

#### 5. 技术债 / 风险 / 红线

- 🟠 **P1 单 struct 2320 行**：`DisplaySettingsView` 一个 struct 承载 **12 个 Section、130+ 私有 computed property / 方法**（实测 L45-L2262）。子组件只抽出 4 个真正独立的 `ViewModifier` / `ButtonStyle`。**可维护性债为本组最高**：任何一处排版调整都需在大文件内长距定位，无法做单 Section 的 SwiftUI Preview 隔离。
- 🟡 **P2 无 `#if DEBUG` 门控的自检计数**：L24 `selfCheckTick` + L70 日志 `ReadingStatsCache.shared.diagnostics`（`mounted` / `resolveAttempts`）**在 Release 也会记录并上报日志**。属诊断信息泄漏到生产日志（低敏感，但日志页用户可见）。同类：L88-90 的停留时长与曝光 section 数。
- 🟢 **P3 Hero 扫光动画时序**：L77-83 用 `DispatchQueue.main.async` + `withAnimation(.easeOut(duration: 3.2).delay(0.15))`。在页面被快速关闭时，动画仍会执行（无取消）——`heroShineSwept` 在 `onAppear` 已复位（L77），**未发现实际缺陷**，但属「提交后不可撤」的动画模式（**未做泄漏实测**）。
- **reduceMotion 门控一致性好（正面）**：本文件新增动画统一经 `ConditionalBounceModifier`（L2268）/ `NumericTransitionConditionalModifier`（L2282）门控，并在 L2265 注释明确「本页新增动画统一门控」。同类做法在全库其他文件不普遍（如 `NetworkMonitorView` 用 `reduceMotion ? nil :` 内联三元），属本文件更规范。
- **无强制解包**：实测 `grep -nE '[a-zA-Z\)\]]!([.,\)]|$)'` 零命中 —— 2320 行无 `!` 强解，工程质量良好（对比 `BiometricSettingsView.swift:85`）。
- **`@State` 数量偏多（16 项）**：L22-43 + L305。其中 `lastDiceAt` L34（骰子防连点）、`themeRippleToken` L38（涟漪 token 递增）、`schemeTicker` L36 属「手动动画触发器」模式，在 SwiftUI 中易出现状态不同步。**未发现明确缺陷，但属脆弱模式**。
- 🟡 **P2 灰度模式（F18）的全局性**：`grayScaleEnabled` 由 Manager 持有（`DisplaySettingsManager.swift:799`），`onAppear` 日志中读 `settings.grayScaleEnabled`（L73）。灰度跨页生效依赖 `sjzPresentationChrome()` 挂载（仓库文档自述实测 **62 处真实挂载**，`qin/docs/code-wiki/07-全量深度分析总文档.md:7`）——**本文件不负责挂载**，但灰度开关的「全局生效」承诺依赖那 62 处不遗漏，属跨文件强耦合。**该 62 处未在本次范围内逐一核验 → 未验证**。
- 🟢 **P3 亮度读取 API 选型正确（正面，已实测纠正）**：`activeBrightness`（L2318-2320）实现为 `activeScreen?.brightness ?? 0.5`，且 L2317 注释明示「**从上下文场景获取屏幕，避免弃用的 `UIScreen.main`**」，兜底 0.5 中位亮度并注明「正常前台运行必有场景屏幕」。→ 本文件**未使用**已软弃用的 `UIScreen.main`，此前的 API 债担忧不成立。属本工程在多场景适配上的正面案例。

---

### `CacheModeSettingsView.swift`（611 行）

#### 1. 顶层类型清单（4）

| 行号 | 类型 | 职责 |
|---|---|---|
| 11 | `struct CacheModeSettingsView: View` | 缓存模式设置页 |
| 509 | `private struct ModeSelectionCard: View` | 模式选择卡片 |
| 562 | `private struct StatMiniCard: View` | 统计小卡 |
| 585 | `private struct StatRow: View` | 统计行（`opacity` L590 可调） |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、无 @Published。`L12 @ObservedObject private var cacheManager = CacheModeManager.shared`、`L13 @ObservedObject private var dataService = DataService.shared`。
- 局部 `@State`：`showResetStatsAlert` L14、`showClearCacheAlert` L15、`showImageCacheClearAlert` L16、`statsAppeared` L17、`showModeSwitchConfirm` L19、`pendingMode: CacheMode?` L20。
- 派生：`snapshot: CacheStatsSnapshot` L22。**本文件零持久化写入**。
- Manager 侧键（实测 `CacheModeManager.swift:167-175`）：`modeKey="cacheMode"`、`hitCountKey="cacheHitCount"`、`missCountKey="cacheMissCount"`、`imgHitCountKey="cacheImageHitCount"`、`imgMissCountKey="cacheImageMissCount"`、`sessionStartKey="cacheSessionStart"`、`savedTrafficKey="cacheSavedTrafficBytes"`、`imgFreeModeKey="cacheImageFreeMode"`、`imgFreeSkipKey="cacheImageFreeSkippedCount"`。
- Manager `@Published`（`CacheModeManager.swift`）：`mode` L179、`imageFreeModeEnabled` L192、`imageFreeSkippedCount` L203、`hitCount` L207、`missCount` L210、`imageHitCount` L213、`imageMissCount` L216、`sessionStartTime` L219、`savedTrafficBytes` L220。
- **注意：`CacheModeManager.swift` 内有第二个单例** `CacheModeMirror.shared`（L18）——用于线程安全的镜像记账（`imageStatLogLock` NSLock L358），属「双单例」设计。

#### 3. 关键方法签名 + 行号 + 行为

- `L26 var body` — 分区：无图模式 `imageFreeModeSection` L101、模式选择 `modeSelectionSection` L176、实时预览 `livePreviewSection` L205、详细统计 `statisticsSection` L259、效率仪表盘 `efficiencyGauge` L323、流量节省 `trafficSection` L377、图片缓存中心 `imageCacheCenterSection` L408（注释标注 **E2**）、管理操作 `managementSection` L452。
- `L156 private func handleModeSelection(_ mode: CacheMode)` — 需确认才切换：置 `pendingMode` 并弹 `showModeSwitchConfirm`。
- `L169 private func applyMode(_ mode: CacheMode)` — 真正切换。
- 重置统计 / 清空缓存 / 清空图片缓存三个 alert（L14-16）。

#### 4. 与其它模块的依赖

- `CacheModeManager.shared`（+ `CacheModeMirror`）、`DataService.shared`（数据层，用于清空缓存）；`CacheMode`、`CacheStatsSnapshot`。
- `CacheModeManager.registerMemoryWarningHandler()` 在 `DesignCodeApp.swift:31` 注册（E9 内存警告降载），本文件只做 UI。
- 入口：`TabBar` 设置页（未在本次范围逐一核实具体行号）。

#### 5. 技术债 / 风险 / 红线

- **模式切换有二次确认**（L156-175）——设计正确，避免误切换导致缓存策略突变。
- 🟡 **P2 双单例（`CacheModeManager.shared` + `CacheModeMirror.shared`）**：状态源分裂风险。`CacheModeMirror`（L18）承担跨线程记账，`CacheModeManager`（L163）承担主状态。UI 只观察后者（L12）。若镜像与主状态出现偏差，UI 展示的命中率/流量节省会与实际不符。**未验证两者同步机制 → 未验证**。
- 🔴 **P1 计数写入路径存在滚动期性能隐患（本次新发现，证据完整）**
  - 写入链：`@Published private(set) var hitCount`（L207）带 `didSet { persist(hitCount, forKey: Self.hitCountKey) }`（L208）；`imageHitCount` L213-215、`imageMissCount` L216-217、`missCount` L210-211、`imageFreeSkippedCount` L203-204 同样带 didSet；`persist(_:forKey:)`（L445-447）就是裸的 `UserDefaults.standard.set(value, forKey: key)`，**无合并、无节流、无防抖**。
  - 触发链：`recordImageHit(url:)`（L340-347）第一行即 `imageHitCount += 1`（L341）→ didSet → **同步 `UserDefaults.set`**；紧接的 `guard Self.imageStatShouldLog(url)`（L342）**只节流日志，不节流计数**（L357 注释明示「计数始终累加，滚动不刷日志」）。`recordImageMiss`（L349-355）同构。调用点实测：`TabBar.swift:4796`（命中）、`TabBar.swift:4845`（未命中）——**均在图片管线的滚动热路径上**。另 `recordSavedTraffic(bytes:)`（L370-372）直接在函数体内 `UserDefaults.standard.set(Int(savedTrafficBytes), ...)`，连 didSet 都不经过。
  - **放大效应**：`CacheModeManager.shared` 在全库有 **11 个 `@ObservedObject` 观察者**（实测 `grep -rn 'CacheModeManager.shared'` 共 38 处命中，其中 `@ObservedObject` 声明 11 处：`TabBar.swift:3076 / 5027 / 5673 / 6235 / 6800 / 10488 / 11705 / 12121`、`NetworkMonitorView.swift:23`、`CacheModeSettingsView.swift:12`）。每次 `@Published` 变更 → **11 个视图全部失效重算**。
  - **净效果**：用户滚动文章列表时，**每一个缩略图缓存命中都会引发「一次主线程 UserDefaults 写 + 11 个视图失效」**。这与工程在别处（`LogManager` 风暴限速、`LogListView` 结果缓存、`SJZNetworkMonitor` 路径事件去抖）体现的性能意识形成明显落差，属**遗漏的同类问题**。
  - **建议修法**：① 计数改为内存累加 + 定时/退后台批量落盘（对齐 `LogManager.flushPendingNow()` 的思路）；② 或给 `persist` 加 0.5~1s 合并窗口；③ 最低成本方案：把高频的 `imageHitCount` / `imageMissCount` 从 `@Published` 中剥离为独立轻量镜像（`CacheModeMirror` L18 已是为此存在的结构，直接复用即可），使 UI 只订阅低频的 `mode` / `savedTrafficBytes`。
  - **风险等级说明**：**未做真机 Instruments 实测**，性能影响量级为静态推理；但「每命中必写 UserDefaults」与「11 个观察者」两项事实均已由源码行号确证。

---

### `HomeModuleSettingsView.swift`（149 行）

#### 1. 顶层类型清单（1）

| 行号 | 类型 | 职责 |
|---|---|---|
| 10 | `struct HomeModuleSettingsView: View` | 首页模块管理设置页 |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、无 @Published。`L11 manager = HomeModuleManager.shared`、`L12 data = DataService.shared`、`L13 @Environment(\.editMode)`。
- 局部 `@State`：`showResetAlert` L14。派生：`visibleCount` L16（`manager.visibleOrderedModules.count`）。
- **本文件零持久化写入**。Manager 键（实测 `HomeModuleManager.swift:127-128`）：`orderKey="homeModuleOrder"`、`hiddenKey="homeModuleHidden"`（写入点 L342、L351）。
- Manager `@Published private(set)`：`moduleOrder: [HomeModule]` L135、`hiddenModules: Set<HomeModule>` L138。
- **遗留值迁移**：`HomeModuleManager.swift:132` `static let retiredRawValues: Set<String> = ["campusSceneries", "bottomBanners"]` —— 两个已下线模块的 rawValue 保留用于读取旧配置时过滤。

#### 3. 关键方法签名 + 行号 + 行为

- `L20 var body` — 列表 + 编辑模式；`.onMove` 拖拽排序；`showResetAlert` 恢复默认。
- `L103 private func moduleRow(_ module: HomeModule) -> some View` — 单模块行。
- `L125 private func moduleSubtitle(_ module: HomeModule) -> String` — 副标题文案。
- `L132 private func visibilityBinding(for module: HomeModule) -> Binding<Bool>` — 构造可见性 Binding（**不直接绑定 Set，而是经 Manager 方法**，写法优于 `LogSettingsView` 的直写 `$logManager.*`）。
- `L144 private func move(from source: IndexSet, to destination: Int)` — 拖拽排序落库。

#### 4. 与其它模块的依赖

- `HomeModuleManager.shared`（唯一状态源）、`DataService.shared`（L12，用于模块可用性/内容判断）、`HomeModule`、`EditMode`。
- 入口：`TabBar` 设置页。

#### 5. 技术债 / 风险 / 红线

- **本组最规范的文件**：149 行、`visibilityBinding` 经 Manager 方法（L132）而非直接改写 `@Published` 集合、无强制解包、无 DEBUG 泄漏、无隐藏手势。
- 🟢 **P3 `DataService` 为未使用依赖（已实测确认）**：L12 声明 `@ObservedObject private var data = DataService.shared`，但 `grep -n 'data\.' HomeModuleSettingsView.swift` **零命中** —— 该观察者从未被读取。**后果不只是冗余**：它让本页订阅了 `DataService` 的全部 `@Published`，`DataService` 是数据层高频发布者，会造成本页无谓重渲染。**建议删除 L12。**
- 遗留 rawValue（`campusSceneries` / `bottomBanners`）长期保留在 `retiredRawValues`：属正确的向后兼容做法，但**无清理时限**，会永久留在代码中。

---

## G · 收藏 / 消息 / 通知 / 公告

### `BookmarkListView.swift`（1675 行）

#### 1. 顶层类型清单（4）

| 行号 | 类型 | 职责 |
|---|---|---|
| 16 | `struct BookmarkListView: View` | 我的收藏页主视图 |
| 1512 | `private struct BookmarkBanner: Equatable` | 操作反馈横幅模型（`Tone`） |
| 1530 | `private struct BookmarkRowPressStyle: ButtonStyle` | 行按压样式（缩放回弹，reduceMotion 门控；`makeBody` L1532） |
| 1561 | `struct BookmarkThumbnailView: View` | 收藏缩略图（**非 private**，可复用） |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、**无 @Published**。`L17 bookmarkManager = BookmarkManager.shared`、`L18 readManager = ReadStatusManager.shared`（L1565 缩略图内再次观察 bookmarkManager）。
- `@Environment(\.accessibilityReduceMotion)` L19。
- `@State`（23 项，L23-65）：`searchText` L23、`searchDebounceTask` L25、`filterScope: BookmarkFilterScope = .all` L26、`sortOrder: BookmarkSortOrder = .recentlyBookmarked` L27、`isBatchMode` L31、`selectedKeys: Set<String>` L32、`openedBookmark: BookmarkItem?` L36、`banner` L40、`bannerDismissTask` L41、`showClearConfirm` L42、`showDeleteSelectedConfirm` L43、`checkingUpdates` L44、`precacheBaselineCachedCount` L46、`showDiagnosePanel` L50、`diagnosePressCount` L51、`storageSnapshot` L52、`showOfflineCenter` L56、`showClearContentConfirm` L57、`showKeepLatestConfirm` L58、`offlineCleared: (count: Int, bytes: Int)?` L60、`now` L64、`openedAt` L65。
- 派生：`unreadCount` L70、`precacheAvailability` L75、`isSearching` L79、`visibleItems` L84、`shouldGroupByTime` L93、`emptyStateSignature` L98、`groupSectionSignature` L105。
- **本文件零持久化写入**。Manager 键/路径（实测 `BookmarkManager.swift`）：
  - `legacyBookmarksKey = "bookmarkedArticles"`（L129，**旧版 UserDefaults 键，保留用于一次性迁移**，迁移逻辑 L1123、L1173）
  - `storageFileURL` = `Documents/<baseDir>/bookmarks.json`（L248）
  - `imageCacheDir`（L251，`BookmarkImages` 固化缓存目录）
  - 深链自测回执：`Documents/bookmark_deeplink_selftest_done.json`（L1345，L1218 注释说明宿主脚本经 `devicectl` 取回）
- Manager `@Published`（`BookmarkManager.swift`）：`bookmarks` L145、`maxCount` L153、`autoCacheContent` L162、`pushOnUpdate` L171、`showLimitAlert` L182、`limitAlertMessage` L183、`precacheProgress` L193。
- 头注释（`BookmarkManager.swift:5`）：「本地持久化收藏数据（**文件存储 · 旧版 UserDefaults 自动迁移 · 损坏自愈抢救**）」。

#### 3. 关键方法签名 + 行号 + 行为

**列表与检索**
- `L114 var body`；`L240 headerBar`（顶部状态栏）；`L294 precacheChip(_:)`（预缓存进度）；`L343 searchField`（Liquid Glass + 聚焦描边）；`L395 filterChips`（「全部 / 未读 / 可离线 / 分类动态」注释 L393）+ `filterChip(_:label:icon:...)` L413。
- **列表渲染（`contentList` L448-486）**：`ScrollView` + **双层 `LazyVStack`**；`shouldGroupByTime` 时按 `BookmarkManager.groupSections(items, now:)` 分时间组（L458），否则平铺。
  - ⚠️ **无分页 / 无增量加载**：一次性把 `visibleItems`（L84）全量交给 `LazyVStack`。行视图虽惰性，但**数据数组与分组结构全量构建**。规模由 `BookmarkManager.maxCount` 约束——**已实测默认值 = 500 条**（`BookmarkManager.swift:257-258`：`maxCount = defaults.object(forKey: ...) != nil ? defaults.integer(...) : 500`），超出即截断（L283-289，超出时记 `truncated` / `max` / `total` 日志）。**500 条上限使无分页风险可控**，不构成缺陷。
- 行组件：`bookmarkRow(_:index:)` L489、`bookmarkRowCard(_:unread:keyword:)` L576、`rowStrokeColor(_:)` L646、`statusChips(_:)` L654、`miniChip(icon:text:color:)` L670、`unreadDot` L683、`selectionBadge(_:)` L694。
- 空态：`emptyState` L713、`filteredEmptyState` L740、`filteredEmptyTitle` L767；**空态日志** `logEmptyState(_:trigger:)` L1440（用 `emptyStateSignature` L98 去重，避免重复记录）。

**批量管理**
- `batchBar` L778（底部悬浮）；`visibleKeys` L821（`visibleItems.map(\.readKey)`）；`allVisibleSelected` L823。
- `toggleSelection(_:)` L1388、`toggleSelectAll()` L1401、`enterBatchMode()` L1414、`exitBatchMode()` L1423。

**行交互**
- `openItem(_:)` L1292、`removeItem(_:source:)` L1310、`toggleRead(_:markRead:)` L1323（联动 `ReadStatusManager`）、`copyLink(_:)` L1338、`cacheSingle(_:)` L1346（单条离线缓存）、**`performUpdateCheck()` L1367**（收藏更新检查）。

**离线中心（正文缓存管理）**
- `showOfflineCenter` L56 驱动；三个确认：清空正文 `showClearContentConfirm` L57、仅保留最新 `showKeepLatestConfirm` L58；结果 `offlineCleared` L60。**离线中心的清空实现不在本文件**（由 BookmarkManager 提供），本文件只做入口与确认。

**缩略图（`BookmarkThumbnailView` L1561）**
- 头注释 L1558-1560：「统一走全 App 图片管线 `SJZCachedImage`（零闪烁缓存直出 · ImageIO 降采样 · 滚动让路 · 无图模式 · 失败自动重试），并对「取消收藏前已固化到 BookmarkImages 的图片」提供**离线兜底读取**」。
- `thumbnailPixel = 360` L1572（注释 L1571：「104×78pt @3x ≈ 312px，取 360 保证清晰」）；`parsedURL` L1574；`categoryAccent` L1580。
- `L1583` 渲染：`SJZCachedImage(url:maxPixel:onPhaseChange:)`，四相分支 —— `.success` 直出（L1585）、`.empty` → 兜底图或 shimmer（L1587-1592）、`.failure` → 兜底图或失败占位（L1593-1598）、`.skipped` → `SJZImageFreePlaceholder`（L1599-1601）；`.allowsHitTesting(false)` L1604（注释：「缩略图为装饰层：行点击 / 滑动手势优先」）。
- `L1605-1608` `.task(id: imageUrl)` 复位兜底状态；`L1612 handlePhase(_:)` —— **失败时读固化缓存兜底；成功时回填固化**（注释 L1611：「URLCache 命中时零成本」）。

#### 4. 与其它模块的依赖

- `BookmarkManager.shared`（收藏数据 + 预缓存进度 + 离线中心）、`ReadStatusManager.shared`（未读状态）、`BookmarkFilterScope`、`BookmarkSortOrder`、`BookmarkItem`、`BookmarkStorageSnapshot`、`SJZCachedImage` / `SJZImagePhase` / `SJZImageFreePlaceholder`（统一图片管线）、`categoryColor(_:)`、`bookmarkHighlighted(_:keyword:)` L1541（AttributedString 高亮，注释 L1539「与消息中心一致」）、`LogManager.shared`（域 `favorite`——文档自述原 `bookmark` 域已合并）。
- `NotificationManager`（收藏更新深链，经 `isBookmarkUpdate` kind，属跨模块协作，实现不在本文件）。
- 深链自测（DEBUG）：`BookmarkDeepLinkSelfTest.runIfRequested()`（`DesignCodeApp.swift:156` 调用）。

#### 5. 技术债 / 风险 / 红线

- 🟠 **P1 隐藏诊断面板（阈值已实测 = 5 次）**：`diagnosePressCount` L51 + `showDiagnosePanel` L50；触发逻辑 L251-257（`diagnosePressCount += 1` → **`if diagnosePressCount >= 5`** → 归零并展示面板），每次点击均记日志含 `count`。同类隐藏入口：`MessageCenterView.swift:36` `repairPressCount` + `:35 showRepairPanel`，触发逻辑 `:141-147`（**同为 `>= 5`**，注释 `:722` 明示「诊断修复面板（长按标题 5 次）」）。**性质**：无 `#if DEBUG` 门控的隐藏手势入口在 Release 可用，属审核与安全双重风险（可被用于触发数据修复/清空操作）。**建议至少加 DEBUG 门控或改为设置页内显式入口。**
  - 附：两处阈值均为 5 次，且有 `count` 日志留痕，**设计上可观测**（属正面），问题在**是否应随 Release 出海**。
- 🟡 **P2 无分页**（见上）：数据结构全量构建。受 `maxCount` 限制，风险中等。
- 🟡 **P2 文件存储 + 自愈抢救的复杂度**：`BookmarkManager` 承担「文件存储 + 旧版 UserDefaults 迁移 + 损坏自愈抢救」三重职责（`:5` 注释）。本文件作为 UI 只是消费者，但 `storageSnapshot`（L52）等诊断 UI 的存在说明**数据损坏是已知真实问题类别**。属数据层风险，不属于本文件缺陷，但 Wiki 应交叉引用。
- **正面**：`logEmptyState`（L1440）用 signature 去重避免空态日志刷屏；`emptyStateSignature`（L98）/`groupSectionSignature`（L105）为显式去重设计；缩略图的「管线失败 → 固化缓存兜底」是**双层容错**，注释 L1611 说明成功路径回填固化缓存使 URLCache 命中时零成本。
- **`@State` 23 项**偏多，其中 6 项仅服务于三个确认弹窗 + 离线中心，可考虑用枚举驱动单一路由状态收敛。
- **`offlineCleared` 为元组 `(count: Int, bytes: Int)?`**（L60）：SwiftUI `@State` 持有元组导致 `Equatable` 比较受限，属小瑕疵（注释已标注用途）。

---

### `MessageCenterView.swift`（939 行）

#### 1. 顶层类型清单（3）

| 行号 | 类型 | 职责 |
|---|---|---|
| 15 | `struct MessageCenterView: View` | 消息中心主视图 |
| 792 | `struct MessageDetailCard: View` | 无深链消息的完整详情卡（`body` L795） |
| 851 | `struct MessageCenterSettingsPanel: View` | 消息中心设置面板 |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、**无 @Published**。`L16 store = MessageCenterStore.shared`、`L17 notificationManager = NotificationManager.shared`、`L18 colorScheme`、`L19 dismiss`。
- 局部 `@State`（L26-42）：`filterMode: FilterMode = .all` L26、`searchText` L27、`searchFocused` L28、`searchDebounceTask` L29、`showDetailItem: MessageItem?` L32、`showSettings` L33、`showClearMenu` L34、`showRepairPanel` L35、`repairPressCount` L36、`now` L37（相对时间每分钟鲜活）、`markAllPhase` L38（0 idle / 1 running / 2 success）、`silentChecking` L39、`checkResultBanner` L40、`bannerDismissTask` L41、`launchFailedToast` L42。
- 派生：`filteredItems` L48、`isSearching` L61。
- **分类筛选**：`private enum FilterMode: Equatable { case all, unread, kind(MessageKind) }` L22-24。
- **持久化（Store 侧，实测 `MessageCenterStore.swift`）**：
  | 键 | 行号 | 值 |
  |---|---|---|
  | `maxCountKey` | L140 | `"messageCenterMaxCount"` |
  | `autoCheckKey` | L141 | `"messageCenterAutoCheck"` |
  | `badgeEnabledKey` | L142 | `"messageCenterBadgeEnabled"` |
  | `lastAutoCheckKey` | L143 | `"messageCenterLastAutoCheckTime"` |
  | `importDoneKey` | L144 | `"messageCenterImportedSystemOnce"` |
  - **文件存储**：`Documents/MessageCenter/messageCenterEvents.json`（`MessageCenterStore.swift:9` 注释 + L197 `storageURL`）。**原子写**：`.tmp` + `replaceItemAt`（L309-314）。**损坏自愈**：`messageCenterEvents.corrupt-<时间戳>.json` 备份（L235-236）。**旧系统消息一次性导入**：`importDoneKey`（L207-208）。
- Store `@Published private(set)`：`items` L172、`unreadCount` L173、`latestItem` L179、`launchState: MessageLaunchState` L180、`dismissRequest: UUID?` L182。
- Store 可注入（L191-192 注释「可注入存储目录与 UserDefaults（单测隔离用）」）。

#### 3. 关键方法签名 + 行号 + 行为

- `L67 var body`；`L131 headerBar`（顶部横幅条）；`L170 silentCheckButton`（静默检查）；`L192 resultBanner(_:)`；**`L207 performSilentCheck()`**（手动触发一次静默检查）；`L235 searchField`；`L286 filterChips` + `L319 filterChip(label:icon:color:...)`。
- `L350 contentList`；`L391 daySection(header:items:)`（**按天分组**，与 LogListView 的 Section 手法不同：此处为 `header: String` + items）；`L406 refreshBody()`。
- `L426 messageRow(_:index:highlightKeyword:)`（关键词高亮，参数默认值 `""`）。
- 空态三文案：`emptyState` L585、`emptyStateIcon` L611、`emptyStateTitle` L617、`emptyStateSubtitle` L623。
- 工具栏：`toolbarContent` L634、**`allReadButton` L681（三态：idle/running/success，`markAllPhase` L38 驱动）**。
- **诊断修复面板**：`repairPanel` L724（长按标题 5 次进入，注释 L722）。
- `MessageDetailCard`（L792-848）；高亮函数 `messageCenterHighlighted(_:keyword:)` L777-791（注释 L776 归入详情卡段）。
- **设置面板 `MessageCenterSettingsPanel`（L851-938）**：
  - 局部 `@State`：`maxCount = 200` L853、`autoCheck = true` L854、`badgeEnabled = true` L855、`showClearConfirm` L856。
  - `L863 Picker("消息保留上限", ...)` + `L869-871 .onChange` → `store.maxCount = newValue` + 日志 `"messageCenter"` / `"设置：上限条数变更"`。
  - `L881 Toggle("前台自动检查", isOn: $autoCheck)` + `.onChange` L883。
  - `L886 Toggle("桌面角标显示未读数", isOn: $badgeEnabled)` + `.onChange` L888。
  - `L931-935 onAppear` 从 store 回读三项（`store.maxCount` / `store.isAutoCheckEnabled` / `store.isBadgeEnabled`）并记日志。
  - ⚠️ **实现细节**：面板用**本地 @State + onChange 回写 store**（L869/L883/L888），而非直接绑定 `$store.*`。这是**比 `LogSettingsView` 更稳妥的模式**（避免直写 Manager 的 @Published），但需注意 `onAppear` 回读（L931）与 `onChange` 回写之间存在**短暂的状态双源窗口**。

#### 4. 与其它模块的依赖

- `MessageCenterStore.shared`（数据 + 设置三项）、`NotificationManager.shared`（权限状态、停靠、`deepLinkOutcome`、`launchState`）。
- `MessageItem`、`MessageKind`、`MessageLaunchState`、`DeepLinkOutcome`。
- `LogManager.shared`（域 `messageCenter` / `notification`）。
- 深链协作：`NotificationManager.pendingDeepLink` 等（`NotificationManager.swift:140-150`）。
- 入口：`TabBar`（消息中心 Tab / 齿轮菜单）。

#### 5. 技术债 / 风险 / 红线

- 🟠 **P1 诊断修复面板**（`repairPressCount` L36 + `repairPanel` L724，注释明示「长按标题 5 次」）：与 `BookmarkListView` 的隐藏诊断面板同类问题 —— **无 DEBUG 门控，Release 可用**。且此处名为「修复」，可能触发数据写入/修复操作，风险高于纯只读诊断。
- 🟡 **P2 设置面板状态双源**：见上（L853-855 本地 @State ↔ store）。若面板打开期间 store 被外部修改（如自动检查改写 `lastAutoCheckTime`），本地值不会同步 → 用户看到旧值并可能在 onChange 时把旧值回写覆盖。**实际触发条件较窄（需外部并发修改同一字段）→ 风险低，但属可消除的模式债**。
- 🟡 **P2 `messageCenterEvents.json` 的完整性策略**：Store 侧有原子写（L309-314）+ 损坏备份（L235-236）+ 一次性导入标记（L207）。设计完整，但**本文件作为 UI 无任何数据校验**（如 items 与 unreadCount 一致性）。
- ✅ **`unreadCount` 的 didSet 已实测（解决疑点）**：`MessageCenterStore.swift:173-178` —— `didSet { guard unreadCount != oldValue else { return }; syncBadge() }`。即**未读数变化即同步桌面角标**，且用 `oldValue` 比较做了幂等守卫。设计正确（无重复角标请求），但需注意 `syncBadge()` 属系统 API 调用，**高频未读变化会触发高频角标同步**；本次未见节流（**同步频率取决于消息流入速率，实际风险低 → 未做实测**）。
- **正面**：`allReadButton` 三态（L38 + L681）避免了「全部已读」的重复点击竞态；`silentCheckButton`（L170）+ `checkResultBanner`（L40）+ `bannerDismissTask`（L41）有完整反馈闭环；`filterMode` 用带关联值的枚举（L22-24）而非多个布尔，表达力好。

---

### `NotificationTestView.swift`（509 行）

#### 1. 顶层类型清单（1 + 1 嵌套）

| 行号 | 类型 | 职责 |
|---|---|---|
| 14 | `struct NotificationTestView: View` | 通知测试中心 |
| 20 | `private struct TestRecord: Identifiable`（**嵌套于 struct 内**） | 单条测试记录；`enum Phase { pending, success, failure }` L21-25；`isSuccess` L32 |

> 头注释（L4-5）：「完整验证系统通知链路的测试工具：权限探测、系统送达测试、前台横幅测试、点击跳转链路测试、应用角标测试。全部操作已接入现有日志系统（notificationTest 模块）。」

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、无 @Published。`L15 notificationManager = NotificationManager.shared`。
- **`L16 @AppStorage("notificationPermissionRequested") private var permissionRequested: Bool = false`** —— 本文件唯一的持久化键（实测字面量 `"notificationPermissionRequested"`）。
- 局部 `@State`（L35-44）：`results: [TestRecord]` L35、`isRefreshingAuth` L36、`isRequestingPermission` L37、`isSendingBanner` L38、`isSendingBackground` L39、`isSimulatingTap` L40、`isSettingBadge` L41、`pendingSimulateRecordId: UUID?` L42、`lastHandledOutcome: DeepLinkOutcome?` L43。
- 静态 `timeFormatter` L46-50（`"HH:mm:ss"`）。

#### 3. 关键方法签名 + 行号 + 行为（测试用例清单）

`L51 var body` — 五分区：

| 分区 | 行号 | 用例 | 调用的 Manager 方法 |
|---|---|---|---|
| **权限探测** | `permissionSection` L80 | 状态展示（L83 图标随 `isAuthorized`）+「请求通知权限」L115 +「前往系统设置开启」L125 | `refreshAuthorizationStatus()`（L375）；`requestPermission()`（L386）；`openSystemSettings()`（L123） |
| **系统送达与横幅** | `deliverySection` L139 | 前台横幅测试 + 后台送达测试（文案 L171「两次测试共用同一条真实文章…退到后台/锁屏收到后点击它，可一并验证「点击通知跳转文章详情」的完整链路」） | `sendTestNotification(delaySeconds:useRealArticle:source:)`（L405 / L419）→ `NotificationManager.swift:1162` |
| **点击跳转链路** | `tapChainSection` L178 | 模拟点击（L199「模拟链路不依赖系统权限，未授权也可测试」；L207 说明：广播点击事件 → 主界面登记文章 → 等待前台活跃与安全解锁 → 自动打开文章详情） | `simulateNotificationTap()`（L431）→ `NotificationManager.swift:1228` |
| **应用角标** | `badgeSection` L214 | 「设置角标 1」L222 +「清除角标」L230；系统「标记」许可状态行 L241 | `setBadgeCount(_:)`（L483）→ `NotificationManager.swift:1259` |
| **测试记录** | `resultsSection` L258 | 记录列表（空态 L267「暂无测试记录」+「进行中…」L299） | `insert(_:)` L490；`append(result:title:)` L503 |

- 共享控件：`testButtonLabel(icon:title:subtitle:color:isLoading:isEnabled:)` L328、`capsuleLabel(_:icon:isLoading:)` L356。
- 交互逻辑：`refreshAuth()` L370、`requestPermission()` L381、`runBannerTest()` L398、`runBackgroundTest()` L412、`simulateTap()` L426、`handleDeepLinkOutcome(_:)` L449、`applyBadge(_:actionTitle:)` L476。
- **通知触发的真正实现位置**：本文件**不直接创建 `UNNotificationRequest`**（实测 `grep UNTimeInterval|UNCalendar|UNNotificationRequest` 在本文件零命中）。触发器全部在 `NotificationManager.swift`：`UNTimeIntervalNotificationTrigger` 出现在 **L385、L480、L620、L655、L731、L807、L924**，**全部 `repeats: false`**（L620/L655/L731 为 `timeInterval: 1`；L924 为 `1.5`）→ **无重复/常驻定时通知**，符合测试工具定位。

#### 4. 与其它模块的依赖

- `NotificationManager.shared`（权限、测试发送、模拟点击、角标）；`UserNotifications`（L9 import）；`DeepLinkOutcome`；`LogManager.shared`（域 `notificationTest` / `notification`，L320 文案声明）。
- 入口：`TabBar.swift:10792`（`NavigationLink { NotificationTestView() }`，label「通知测试」）。

#### 5. 技术债 / 风险 / 红线

- 🟠 **P1 测试工具随 Release 出海（已实测确认）**
  - **实测**：`grep -n '#if DEBUG\|#endif' NotificationTestView.swift` **零命中** → 整文件无编译期隔离。
  - **入口未隔离**：`TabBar.swift:10792` 的 `NavigationLink { NotificationTestView() }` 位于最近的 `#if DEBUG` 块（`TabBar.swift:9995-10019`）**之外**，实测该行前最近的 `#endif` 在 L10019，L10792 处无 DEBUG 包裹。
  - **后果**：Release 用户可在「我的 → 应用设置 → 通知测试」看到该页，并能：① 反复触发 `requestPermission()`（系统权限弹窗最多弹一次，但状态可被反复刷新）；② 手动设置/清除桌面角标（`setBadgeCount`）；③ 触发模拟深链点击（`simulateNotificationTap`），可能**在无真实通知的情况下把用户带到某篇文章**，造成困惑；④ 该页被截图/录屏后可能被误认为「App 有测试后门」，**构成 App Store 审核指南 2.3.1（隐藏/未完成功能）与 4.2（最低功能性）风险**。
  - **建议修法**：把 `TabBar.swift:10792` 的入口包进 `#if DEBUG`；或整文件加 `#if DEBUG`。（同族问题见 `BookmarkListView` / `MessageCenterView` 的隐藏手势面板。）
- 🟢 **P3 `permissionRequested`（L16）确实被使用（已实测纠正）**：`grep -n permissionRequested NotificationTestView.swift` 命中 L16（声明）与 **L388 `permissionRequested = true`**（在 `requestPermission()` 内，用户点「请求通知权限」后置位）。**非未使用状态**。用途为记录「本机历史上是否请求过权限」，用于 UI 区分「未决定」与「已拒绝」两种未授权态（配合 L111 `notificationManager.authorizationDetailText.hasPrefix("未决定")` 判断）——设计合理。
- 🟡 **P2 未使用变量命名易误导**：`permissionRequested` 是 `@AppStorage` 持久化键 `"notificationPermissionRequested"`，但**同一语义在 `NotificationManager.authorizationDetailText` 中又被派生一次**（L99/L111/L377）。两处状态源可能不同步（例如用户在系统设置中改权限后，`permissionRequested` 仍为 true）——属轻微双源，实际影响为提示文案可能不准。
- **正面**：模拟链路不依赖系统权限（L199 明确），使测试在未授权环境下仍可跑通；`TestRecord.Phase`（L21-25）三态建模清晰；`pendingSimulateRecordId`（L42）实现「发起 → 回执」的记录关联，避免结果错配。
- **无重复通知风险（已实测确认）**：`NotificationManager.swift` 内所有 `UNTimeIntervalNotificationTrigger`（L385、L480、L620、L655、L731、L807、L924）**全部 `repeats: false`**（L620/L655/L731 为 `timeInterval: 1`，L924 为 `1.5`）→ 无常驻定时器，测试完毕无需清理机制。

---

### `AnnouncementDetailView.swift`（226 行）

#### 1. 顶层类型清单（2）

| 行号 | 类型 | 职责 |
|---|---|---|
| 15 | `struct AnnouncementBanner: View` | 公告横幅（嵌入「我的」页面） |
| 100 | `struct AnnouncementDetailView: View` | 公告详情页 |

#### 2. 单例形态 · @Published · 持久化

- 无自有单例、无 @Published。`L16`（Banner）与 `L101`（Detail）均为 `@ObservedObject private var manager = AnnouncementManager.shared`；`L102 @Environment(\.dismiss)`。
- **本文件零持久化写入**（无 @State 声明实测：`grep '@State'` 在该文件仅用于 Banner/Detail 的 `@State` 前导？实测 `grep -nE '@State '` 无独立命中于本文件类型清单之外 —— 该文件状态全部来自 manager）。
- 数据来源在 `AnnouncementManager.swift`：`targetURL = "https://www.43322.cn/blog/gonggao"`（L46）；HTML 解析锚点 `id="__blog-post-container"`（L214-216）。

#### 3. 关键方法签名 + 行号 + 行为

- **`AnnouncementBanner`（L15-96）**：`L19 var body`；`L29 activeBanner`（开启状态 —— 可点击横幅）；`L79 inactiveBanner`（关闭状态 —— 柔和提示）。用途注释 L12：「公告横幅（嵌入「我的」页面）」。
- **`AnnouncementDetailView`（L100-226）**：`L104 var body`；`L140 titleSection`（标题区）；**`L178 contentSection`（正文区）**；`L187 footerSection`（底部信息）；`L205 formattedTime(_:)`（时间格式化）；`L212` 预览段（`#Preview`）。
- **正文渲染（L178-183）实测**：
  ```swift
  private var contentSection: some View {
      Text(manager.content)
          .displayText(size: 16, baseLineSpacing: 8)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
  }
  ```
  → **纯 `Text` 展示 `manager.content` 字符串，非硬编码示例内容**，内容来自 `AnnouncementManager` 的网络抓取（`https://www.43322.cn/blog/gonggao`），由 `AnnouncementManager` 从 `<div id="__blog-post-container">` 内提取正文。**渲染方式为纯文本**（不解析 Markdown/HTML 结构，无富文本、无内嵌图片支持）。
- **来源标注（L187-199）**：footer 显示 `Text("公告来源：超超博客")`（L194）+ `checkmark.shield.fill` 图标（L191）。

#### 4. 与其它模块的依赖

- `AnnouncementManager.shared`（`content` / 时间 / 状态）；`displayText(size:baseLineSpacing:)` / `displayFont` / `displaySymbolFont`（设计系统）；`GradientBackground()`。
- **数据源**：`www.43322.cn/blog/gonggao`（`AnnouncementManager.swift:46`）—— **与隐私协议同域名**（见 C 组 P1 单点故障风险）。
- 入口：「我的」页面嵌入（`AnnouncementBanner`）。

#### 5. 技术债 / 风险 / 红线

- 🟠 **P1 公告源同属个人博客**：`AnnouncementManager.swift:46` 的 `https://www.43322.cn/blog/gonggao` 与隐私协议（`PrivacyManager.swift:36-37`）**同域**。横幅文案「公告来源：超超博客」（L194）对用户是**透明披露**（正面做法），但该域名同时承载法律文本 → 域名可用性风险的后果被放大（见 C 组）。
- 🟡 **P2 正文纯文本渲染**：`Text(manager.content)`（L179）+ `.fixedSize(horizontal: false, vertical: true)` —— 长公告会**一次性全量布局**（`fixedSize` 垂直方向强制完整尺寸计算），无分页/懒加载。若公告极长（校园公告常见数千字），首次渲染可能在主线程造成可感知开销。**未做性能实测 → 未验证**。
  - 另：正文无 Markdown/HTML 结构还原能力（`AnnouncementManager` 已剥离标签），公告中的列表、加粗、表格、图片**全部退化为纯文本行**。属内容表达能力债（非缺陷）。
- 🟢 **P3 `AnnouncementBanner` 承担「关闭状态」渲染**（`inactiveBanner` L79）：横幅组件同时表达「有公告」与「已关闭」两态，命名（Banner）与职责（含关闭态提示）略不匹配，但实现清晰。
- **正面**：无强制解包；无 DEBUG 泄漏；无隐藏手势；来源标注透明（L194）。

---

## 交叉汇总

### 单例清单（本组 18 文件涉及）

| 单例 | 定义行 | 观察者数（本组内） |
|---|---|---|
| `WeChatService.shared` | `WeChatService.swift:641` | 5 |
| `BiometricSecurityManager.shared` | `BiometricSecurityManager.swift:148` | 3 |
| `PrivacyManager.shared` | `PrivacyManager.swift:91` | 2 |
| `LogManager.shared` | `LogManager.swift`（跨组） | 2 |
| `SJZNetworkMonitor.shared` | `SJZNetworkMonitor.swift:342` | 1 |
| `CacheModeManager.shared` | `CacheModeManager.swift:163` | 2 |
| `CacheModeMirror.shared` | `CacheModeManager.swift:18` | 0（内部） |
| `DataService.shared` | 跨组 | 2 |
| `HomeModuleManager.shared` | `HomeModuleManager.swift:125` | 1 |
| `BookmarkManager.shared` | `BookmarkManager.swift` | 2 |
| `ReadStatusManager.shared` | 跨组 | 1 |
| `MessageCenterStore.shared` | `MessageCenterStore.swift:134` | 2 |
| `NotificationManager.shared` | `NotificationManager.swift:107` | 2 |
| `AnnouncementManager.shared` | `AnnouncementManager.swift` | 2 |
| `DisplaySettingsManager.shared` | `DisplaySettingsManager.swift:569` | 1 |
| `ReadingStatsCache.shared` | `DisplaySettingsManager.swift`（~L2427 段） | 1 |

**本组 18 个文件里只有 3 个文件定义了 `@Published`**：`WeChatService.swift`（11）、`BiometricSecurityManager.swift`（6）、`PrivacyManager.swift`（3）。**其余 15 个文件是纯视图，状态全在 Manager** —— 这是本工程的一致架构约定（单例 Manager + `@ObservedObject`），也是「视图文件行数极大但状态极少」的原因。

### 反模式：`@Published`/`@AppStorage` + `didSet` 承担持久化

工程内两处文件显式写入禁令（`PrivacyManager.swift:6`、`PrivacyPolicyView.swift:6`：「禁止 @AppStorage + didSet；禁止 @Sendable Task 捕获 inout」）。实测违规情况：

| 位置 | 模式 | 判定 |
|---|---|---|
| `PrivacyManager.swift` / `PrivacyPolicyView.swift` | 用 `UserDefaults.standard` 直调 / `@Binding` | ✅ 合规 |
| `BiometricSecurityManager.swift:181 / :199` | `@Published` + `didSet`（写 UserDefaults + Keychain + 状态机迁移） | ⚠️ 非 `@AppStorage`，**不构成字面违规**，但属同类反模式 |
| `LogSettingsView.swift:40/44/61/74` | `$logManager.{debugEnabled,crashCaptureEnabled,maxEntries,retentionDays}` 双向绑定直写 Manager | ⚠️ 同类反模式第二例 |
| `MessageCenterView.swift:853-855 + :869/883/888` | 本地 `@State` + `onChange` 回写 Store | ✅ **更稳妥的模式**（对照参考） |
| `HomeModuleSettingsView.swift:132` | 经 Manager 方法构造 Binding | ✅ 最规范 |

### 文件规模分布（维护性排序）

| 文件 | 行数 | 结构体数 | 单 struct 承载方法/属性数（估算） | 维护性评级 |
|---|---|---|---|---|
| `DisplaySettingsView.swift` | 2320 | 1 主 + 5 辅助类型 | **130+** | 🔴 最差 |
| `NetworkMonitorView.swift` | 1619 | 1 主 + 2 子 View | **80+** | 🔴 差 |
| `BookmarkListView.swift` | 1675 | 1 主 + 3 辅助 | **60+** | 🟠 偏差 |
| `WeChatService.swift` | 1396 | 14 | —（类型分工清晰） | 🟢 良好 |
| `LogListView.swift` | 1355 | 10 | 40+（已抽 LogRowView/LogDetailCard/FilterChip） | 🟡 中 |
| `MessageCenterView.swift` | 939 | 3 | 40+（已抽 MessageDetailCard/SettingsPanel） | 🟡 中 |
| `CacheModeSettingsView.swift` | 611 | 4 | 20+ | 🟢 良好 |
| `HomeModuleSettingsView.swift` | 149 | 1 | 6 | 🟢 最佳 |

### 显式历史事故 / 现场修复记录（源码注释原文位置）

| 位置 | 日期标注 | 事故与修法 |
|---|---|---|
| `WeChatService.swift:371-375` | 2026-09-28 现场修复 | 系统分享面板扩展内存上限（~120MB）远低于 App；72MP 长图解码 ~300MB → 扩展被系统终止（「微信加载中 → 闪回 App」）→ 引入 `systemShareMaxPixels = 12MP` |
| `WeChatService.swift:473` | 2026-09-28 黑图二次复现 | 长图渲染产物为**自适应倍率**（`image.scale` ∈ 0.2~3.0）→ 必须用像素尺寸而非点 |
| `WeChatService.swift:554 / :1322` | — | 取消语义工程红线：cancelled / CancellationError 静默处理，不计失败 |
| `LogListView.swift:48-50` | 2026-09-28 复核修复 | 「向上翻阅历史时被新日志反复拽回顶部」→ 引入 `isAtTop` 判定 |
| `LogListView.swift:564-566` | — | 顶部判定阈值 **12pt 曾误判**（开页即出现「N 条新日志」胶囊）→ 改为 60pt 容差 |
| `LogManager.swift:447/470-537` | 2026-09-28 现场卡死防线 | 自反馈风暴：「展示日志 → 写日志 → 再展示」递归拖死主线程 → 同键 1s 折叠 + **跨键全局限速**（防多键交替绕过） |
| `TabBar.swift:13059` | 2026-09-28 现场实证 | 揭示日志变成列表新行 → 新行再触发揭示日志 → 自反馈风暴 |
| `SJZNetworkMonitor.swift:446-448 / :1068-1085 / :1220` | — | **慢请求误报根治**：跨小时累积会把正常外部慢误判为持续异常 → 60s 时间窗 + 媒体宿主归因（INFO 不打扰）+ 横幅冷却 |
| `SJZNetworkMonitor.swift`（备份版 `:252`） | — | 「路径事件风暴刷屏」→ 仅在链路实质变化时记日志 |
| `DisplaySettingsManager.swift` / 文档 | 2026-09-26 夜 | 显示设置艺术级重构（F1–F19） |
| `qin/docs/code-wiki/07-全量深度分析总文档.md:7` | 2026-09-29 | 收藏更新深链归因修复（双路径 `isBookmarkUpdate` kind 精确已读 + `deliveryUserInfo` 兜底，195/195 真机全绿） |

**观察**：`2026-09-28` 是本工程的事故密集日（日志风暴、长图黑图、系统分享闪回、跟随最新体验侵害同日修复）。Wiki 可将其归纳为「性能与交付稳定性攻坚日」。

### 隐私/合规声明与实现的逐条对账

| 声明位置 | 声明内容 | 实现核验 | 判定 |
|---|---|---|---|
| `PrivacyLegalTexts.swift:139` | 不访问地理位置 | 全库无 `CLLocation` / 定位权限键 | ✅ 一致 |
| `PrivacyLegalTexts.swift:140` | 不收集生物特征数据 | 仅本地 `LAContext`，数据不出 Secure Enclave | ✅ 一致 |
| `PrivacyLegalTexts.swift:141` | 不访问通讯录/通话记录 | 无序言 | ✅ 一致 |
| `PrivacyLegalTexts.swift:142` | 除收藏缓存外不访问相册 | `Info.plist:69-70` `NSPhotoLibraryAddUsageDescription`（仅写入，文案已声明「仅写入，不读取」） | ✅ 一致 |
| **`PrivacyLegalTexts.swift:143`** | **不读取剪切板** | **`WeChatService.swift:1255-1263` 无条件放行 SDK 剪贴板授权** | ⚠️ **口径张力（P1）** |
| `PrivacyLegalTexts.swift:144` | 服务器端不记录浏览历史 | 无账号体系、无上报端点（除博客抓取） | ✅ 一致 |
| `PrivacyLegalTexts.swift:145` | 不收集 IDFA/IDFV/UDID | 全库无 `ASIdentifierManager` / `identifierForVendor` | ✅ 一致（**未全库穷尽核验 → 未验证**） |
| `PrivacyLegalTexts.swift:161` | 日志默认保留 7 天 | 需与 `LogManager.retentionDays` 默认值一致 | ⚠️ **未见自动化校验 → 未验证** |
| `PrivacyLegalTexts.swift:193-204` | 第三方 SDK 仅微信开放平台 | pbxproj 实测仅 `WechatOpenSDK.xcframework` 一个二进制依赖 | ✅ 一致 |
| **`PrivacyLegalTexts.swift:219`** | **不申请 Face ID / Touch ID** | **`Info.plist:67-68` + `BiometricSecurityManager.swift:242` + Face ID 设置页** | 🔴 **矛盾（P0）** |
| `PrivacyLegalTexts.swift:219` | 不申请「相册读写」 | `NSPhotoLibraryAddUsageDescription`（仅写入） | ⚠️ 措辞易误判（建议与 plist 文案对齐） |
| `PrivacyLegalTexts.swift:224` | 所有网络请求通过 HTTPS 加密传输 | `Info.plist:58-64` 对 `sxjzit.edu.cn` 开明文 HTTP 例外 | 🔴 **直接矛盾（P2，需确认该校域名请求是否走 HTTP）** |
| `PrivacyLegalTexts.swift:238` | 可在设置中撤回通知权限授权 | 存在通知开关（`TabBar.swift:10780` 附近） | ✅ 一致 |
| `PrivacyLegalTexts.swift:238` | （隐含）可撤回隐私协议同意 | 无撤回入口 | ⚠️ **承诺未覆盖（P2）** |
| `PrivacyLegalTexts.swift:259-260` | 政策更新将弹窗/公告通知 | 无版本比对逻辑 | 🟠 **承诺未实现（P1）** |
| `PrivacyLegalTexts.swift:275` | 符合 Apple 隐私标签要求 | 含 Face ID 未声明矛盾 | 🔴 受 P0 影响 |

**⚠️ 新增发现（P2）**：`PrivacyLegalTexts.swift:224`「（1）网络传输：所有网络请求通过 HTTPS 加密传输」与 `Info.plist:52-66` 的 ATS 例外（`sxjzit.edu.cn` 允许 `NSExceptionAllowsInsecureHTTPLoads`）**存在冲突**。需要确认 `DataService` / `NetworkService` 对 `sxjzit.edu.cn` 的请求是否实际使用 `http://`；若使用，则声明不实；若不用，该 ATS 例外应移除以消除审核问询点。**本次未核验数据层的 URL scheme → 未验证**。

### App Store 审核风险清单（按拒审概率排序）

1. 🔴 **`PrivacyPolicyView.swift:764` `exit(0)`** —— 审核指南 2.5.4 明令禁止程序化退出。**最高风险**，且极易被审核员在实际操作中触发（拒绝协议 → 受限模式 → 页面正中央就有「退出应用」按钮）。
2. 🔴 **`PrivacyLegalTexts.swift:219` 权限声明与实现矛盾** —— 指南 5.1.1（隐私政策准确性）+ 2.3.1。同时构成国内 PIPL 告知不实。
3. 🟠 **`NotificationTestView.swift` 无 DEBUG 门控** —— 指南 2.3.1（隐藏功能）+ 4.2（最低功能性）。测试工具面向用户可见。
4. 🟠 **`PrivacyManager.swift:36-37` 隐私政策托管个人博客** —— 指南 5.1.1 要求隐私政策 URL 稳定且由开发者控制；个人域名 + 无联系方式（`PrivacyLegalTexts.swift:252`）会增加问询概率。
5. 🟡 **`Info.plist:58-64` ATS 明文 HTTP 例外** —— 需在审核备注中说明必要性；若不必要应移除。
6. 🟡 **`BookmarkListView.swift:50-51` / `MessageCenterView.swift:35-36` 隐藏诊断入口** —— 指南 2.3.1 风险（未文档化的隐藏功能）。
7. 🟢 **`WeChatService.swift:1059` Universal Link 自检会拉起微信** —— Release 可达，非违规但应评估用户体验。

### 未验证点汇总（本次分析未能确证，需后续核验）

> 说明：初稿中 9 项疑点已通过定向核查**落实或纠正**（见文末「核查补记」）；以下为**仍然未验证**的项。

1. **`BiometricKeychain.saveToken` 的 `errSecDuplicateItem` 实际可复现性**（`BiometricSecurityManager.swift:503-515`）：静态推理出「写令牌窗口内进程被杀 → 令牌残留 → 下次启用误报未设密码」路径，**未做真机复现**。
2. **`LogListView` 反馈横幅任务是否泄漏**：`bannerDismissTask`（L59）在 `showBanner`（L394-404）内重建，未见显式 `cancel()`（未逐行核实）。
3. **`NetworkMonitorView` 退后台是否暂停采样**：`scenePhase`（L24）已注入但本文件未使用；后台采样行为需查 `SJZNetworkMonitor` 的后台处理（关乎耗电）。
4. **`displaySettings` 灰度模式 62 处 `sjzPresentationChrome()` 挂载是否无遗漏**：仓库文档自述为 62 处真实挂载，本次未逐一核验。
5. **`CacheModeManager` 与 `CacheModeMirror` 双单例的同步机制**：UI 只观察前者，镜像偏差会导致指标展示失真。
6. **`CacheModeManager` 计数写入的性能影响量级**：写入路径与 11 个观察者的事实已确证，但「用户可感知卡顿」需 Instruments 实测。
7. **`BookmarkListView` 隐藏诊断面板内可执行的操作清单**（是否含破坏性操作）。
8. **`PrivacyLegalTexts.swift:161`「日志保留 7 天」与默认值已对账一致（`LogManager.swift:398` = 7）✅**；但**用户修改 `retentionDays` 后，隐私文本不会同步** —— 属文本静态化问题，非未验证项，列为已知缺口。
9. **`DataService` / `NetworkService` 对 `sxjzit.edu.cn` 的实际请求 scheme（http 或 https）**：决定 `PrivacyLegalTexts.swift:224` 与 `Info.plist:58-64` ATS 例外是否构成实质性声明不实。**（优先级最高的未验证项）**
10. **`PrivacyManager` 在 offline 来源缓存下的重复网络请求行为**：`fetchDocument`（L110）的冷却判断要求 `cached.source == .online`，offline 缓存会每次进页都重新请求——需确认是否为有意设计。
11. **`WeChatService` AASA 实际部署状态**：`qin/docs/wechat-integration/README.md:230` 自述「域名侧尚未部署（404）」，需实测 `https://jl.43322.cn/.well-known/apple-app-site-association` 当前是否可用。Universal Link 回跳是微信登录/分享回执的必需通道，若 AASA 未部署则**生产环境回执链路可能完全不通**（本地 URL Scheme 通道仍可用，故症状会表现为「部分场景回执缺失」）。
12. **`MessageCenterStore.syncBadge()` 的调用频率与实际开销**（未做实测）。
13. **`AnnouncementDetailView` 长公告一次性 `fixedSize` 布局的渲染开销**（未做实测）。

### 核查补记（初稿疑点的落实与纠正）

| # | 初稿标注 | 核查手段 | 结论 |
|---|---|---|---|
| 1 | `LogManager.stats()` 是否记忆化 | 读 `LogManager.swift:635-659` | ✅ **已记忆化**（`topID\|count` 键 + `statsCache`）；但键同构于 `LogFilterKey`，洪峰期仍 O(n) → 结论已改写 |
| 2 | `MessageCenterStore.unreadCount` didSet 内容 | 读 `MessageCenterStore.swift:173-178` | ✅ `guard != oldValue` + `syncBadge()`，设计正确 |
| 3 | `HomeModuleSettingsView` 的 `DataService` 是否未用 | `grep -n 'data\.'` | ✅ **确认未使用**（零命中），且造成无谓重渲染 → 升格为可执行建议 |
| 4 | `NotificationTestView.permissionRequested` 是否未用 | `grep -n permissionRequested` | ❌ **初稿判断错误** —— L388 有赋值，**确实在用** → 已纠正 |
| 5 | `BookmarkManager.maxCount` 默认值 | 读 `BookmarkManager.swift:257-258` | ✅ **500**（键 `bookmarkMaxCount`，L131）→ 无分页风险可控 |
| 6 | 展示诊断面板触发阈值 | `grep -n diagnosePressCount\|repairPressCount` | ✅ 两处**均为 5 次**（`BookmarkListView:255`、`MessageCenterView:145`） |
| 7 | `activeBrightness` 是否用弃用的 `UIScreen.main` | 读 `DisplaySettingsView.swift:2316-2320` | ❌ **初稿担忧不成立** —— 显式用 `activeScreen` 并注释「避免弃用的 `UIScreen.main`」→ 已改为正面评价 |
| 8 | `CacheModeManager` 计数写入频率 | 读 `CacheModeManager.swift:203-217 / 340-355 / 445-447` + 观察者计数 | 🔴 **发现新问题** —— 每次图片命中/未命中同步写 UserDefaults + 11 个观察者失效 → 新增 P1 条目 |
| 9 | 「日志保留 7 天」等文案与实现是否一致 | 读 `LogManager.swift:395-405` | ✅ **三项全部一致**（retentionDays=7、maxEntries=3000、maxEntriesPerFile=1000、storageDir=`SXJZIT_Cache/Logs`） |

