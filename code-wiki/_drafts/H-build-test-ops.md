# H · 构建、测试与运维（深度分析草稿）

> 分析对象：`/Users/qinchao/Downloads/designcode-swiftui`（仓库根）
> 主源码：`qin/DesignCode/`（50 个 `.swift`）｜工程：`qin/DesignCode.xcodeproj/project.pbxproj`（766 行）
> 本机实测环境（本次会话亲自执行）：**Xcode 27.0 (27A266a)** ｜ **macOS 27.0 (26A428)** ｜ `xcrun devicectl` **642.16** ｜ `python3` **3.14.7**（含 Pillow 12.3.0 / numpy 2.5.3）
> 约定真机：**iPhone「秦超的iPhone」，UDID `00008110-000411A40EC1401E`，机型 iPhone 13 Pro Max (iPhone14,3)**；本次核查时 `devicectl list devices` 状态为 **`unavailable`（未连接/未解锁）**
> 事实来源全部为 `grep -n` / `read` / `ls` / 本地实跑；凡未能取证的一律标注 **`[未验证]`**。

---

## H.0 关键结论速览

| # | 结论 | 证据 |
|---|---|---|
| 1 | 工程只有 **2 个 target**：`DesignCode`（App）、`DesignCodeTests`（单元测试 bundle）；**1 个 scheme `DesignCode`**（未共享，仅 `xcuserdata`） | `xcodebuild -list` 实跑输出 |
| 2 | `SDKROOT = iphoneos` 只写在 **project 层**；target 层不覆盖 | pbxproj L545 / L598 |
| 3 | **部署目标 13/26 冲突依然存在**：project 层 Debug=L541、Release=L595 均为 `13.0`；App 与测试 target 均为 `26.0`。**生效值是 26.0**（target 覆盖 project，构建日志实证 `-target arm64-apple-ios26.0`，SDK 为 iPhoneOS27.0） | pbxproj + `build/verify/org_build_20260930_163940.log` L24（SDK）/ L670（target） |
| 4 | `-disable-sandbox` **只在主 target 的 Debug/Release 各一份**（L641 / L689）；**测试 target 没有**此设置 | `grep -n OTHER_SWIFT_FLAGS` 仅命中 2 处 |
| 5 | `CODE_SIGN_ENTITLEMENTS` **全工程未设置** → `DesignCode.entitlements` 只被"引用于分组"，**从未参与签名**。后果：`applinks:jl.43322.cn` 不生效，微信 Universal Link 回跳不可达 | `grep -in entitlement` 仅 2 处（FileReference + group child）；实跑 `grep -n CODE_SIGN_ENTITLEMENTS` **0 命中** |
| 6 | 构建期有 **1 个 Run Script 阶段「显示设置覆盖护栏」**，位于 `buildPhases` **首位**（先于 Sources），`alwaysOutOfDate = 1` → 每次构建都跑；失败即中断构建 | pbxproj L296-L301 / L377-L395；构建日志 L42-L43、L666 |
| 7 | 文件组织是 **经典 `PBXGroup` + 显式 `PBXFileReference`/`PBXBuildFile`**，**没有使用 `fileSystemSynchronizedGroups`**（`grep` 0 命中）→ 新增 `.swift` 必须手工四段注册 pbxproj | pbxproj PBBuildFile/FileReference/Group/Sources 段 |
| 8 | 磁盘 50 个 `.swift` 与 App target Sources 阶段 **50 条一一对应，无孤儿文件**；测试 6 个文件亦齐全 | 逐文件比对脚本实跑 |
| 9 | 单元测试 **静态总用例数 = 237**（15 个 `XCTestCase` 类，6 个文件）。**最近一次真机实跑记录是 195 例 / 0 失败**（2026-09-29 14:57），**237 例尚无实跑证据**（后加的 42 例：OrgModule 22 + 消息中心 17 + 收藏 3） | `grep -c 'func test'` 逐文件求和；`build/verify/device_tests_20260929_145712.log` |
| 10 | 有 **3 条真实在线测试**会真实命中 `https://gwqietap.sxjzit.edu.cn`（`URLSession.shared`，无 mock），学校数据变动/断网即挂（断言含 `list.count == 5`、`total > 100`） | `NetworkServiceDTOTests.swift` L396/L443/L466 |
| 11 | 测试宿主与真实日志隔离已落地：`LogManager.shared = LogManager(persistsToDisk: !LogManager.isRunningTests)`，`isRunningTests` 由环境变量 `XCTestConfigurationFilePath` 或 `NSClassFromString("XCTestCase")` 判定 → **共享实例仅驻内存** | `DesignCode/LogManager.swift` L276-L281 |
| 12 | `Info.plist` **没有 `UIBackgroundModes`**（0 命中）→ 无后台模式声明；ATS 仅放行 `sxjzit.edu.cn` 子域，且 `NSAllowsArbitraryLoads = false` | `plutil` 键枚举 + `grep -c UIBackgroundModes` |
| 13 | 三远端齐备：`origin`(GitHub) / `gitee`(SSH) / `cnb`(HTTPS+令牌)，分支 `main`，tag `v1.0`；最近一次同步报告判定 **PASS** | `git remote -v` 实跑；`qin/docs/remote-sync/remote_sync_verification_20260929.md` L6 |
| 14 | `qin/build/` 全目录被 `.gitignore` 覆盖；构建产物分散在 `device-dd/`（真机脚本）、`DerivedData-selftest/`（深链自测）、`verify/`（报告）三处 | 根 `.gitignore` L9-L12；脚本内 `DERIVED`/`DD_PATH` 变量 |

---

## H.1 工程与 Target（`project.pbxproj`）

### H.1.1 头部元信息

| 键 | 值 | 行 |
|---|---|---|
| `archiveVersion` | `1` | L3 |
| `objectVersion` | **`54`**（Xcode 13+ 格式；不是 70+，所以**无** `PBXFileSystemSynchronizedRootGroup`） | L5 |
| `compatibilityVersion` | `"Xcode 9.3"` | L344 |
| `LastUpgradeCheck` / `LastSwiftUpdateCheck` | `1100`（Xcode 11.0 时代创建，此后未做工程升级迁移） | L334-L335 |
| `ORGANIZATIONNAME` | `Mithun`（沿袭上游 DesignCode 模板） | L336 |
| `developmentRegion` | `"zh-Hans"` | L345 |
| `knownRegions` | `zh-Hans`, `en`, `Base` | L347-L351 |
| `TargetAttributes.DesignCode.CreatedOnToolsVersion` | `11.0` | L339 |

### H.1.2 Target 一览

| Target | PBX ID | productType | 产物 | Build Phases（顺序即执行顺序） | 依赖 |
|---|---|---|---|---|---|
| `DesignCode` | `ABE07CBA22D74F5700D209BE` | `com.apple.product-type.application` | `DesignCode.app` | ①**显示设置覆盖护栏**(Run Script) → ②Sources → ③Frameworks → ④Resources | 无 |
| `DesignCodeTests` | `DC00008300000000000001` | `com.apple.product-type.bundle.unit-test` | `DesignCodeTests.xctest` | ①Sources → ②Frameworks（**无 Resources 阶段**） | `PBXTargetDependency` → `DesignCode`（经 `PBXContainerItemProxy`，`proxyType = 1`） |

- 测试 target 的 `PBXContainerItemProxy`（L73-L80）：`containerPortal` = 工程对象，`remoteGlobalIDString = ABE07CBA22D74F5700D209BE`，`remoteInfo = DesignCode`。

### H.1.3 三套 Build Configuration 全量对照（Debug / Release）

工程共 6 个 `XCBuildConfiguration`：project ×2、App target ×2、Tests target ×2。三个 `XCConfigurationList` 的 `defaultConfigurationName` **都是 `Release`**（L743/L752/L761）—— 即不指定 `-configuration` 时 xcodebuild 走 Release。

**A. project 层**（`ABE07CCD` Debug / `ABE07CCE` Release）

| 设置 | Debug | Release |
|---|---|---|
| `SDKROOT` | `iphoneos` | `iphoneos` |
| `IPHONEOS_DEPLOYMENT_TARGET` | **`13.0`** | **`13.0`** |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG` | —（未设置） |
| `SWIFT_OPTIMIZATION_LEVEL` | `-Onone` | `-O` |
| `GCC_OPTIMIZATION_LEVEL` | `0` | — |
| `GCC_PREPROCESSOR_DEFINITIONS` | `DEBUG=1`, `$(inherited)` | — |
| `ENABLE_TESTABILITY` | `YES` | —（即 NO） |
| `ONLY_ACTIVE_ARCH` | `YES` | — |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` | （Release 段未列，Xcode 默认 `dwarf-with-dsym`） |
| `VALIDATE_PRODUCT` | — | `YES` |
| `COPY_PHASE_STRIP` | `NO` | — |
| `MTL_ENABLE_DEBUG_INFO` / `MTL_FAST_MATH` | `INCLUDE_SOURCE` / `YES` | — |
| 其余 | 全套 `CLANG_WARN_*` / `GCC_WARN_*` 强化告警、`CLANG_ENABLE_MODULES=YES`、`CLANG_ENABLE_OBJC_ARC=YES`、`CLANG_CXX_LANGUAGE_STANDARD="gnu++14"`、`CLANG_CXX_LIBRARY="libc++"`、`GCC_C_LANGUAGE_STANDARD=gnu11`、`ALWAYS_SEARCH_USER_PATHS=NO` | 同左 |

**B. App target `DesignCode`**（`ABE07CD0` Debug / `ABE07CD1` Release）—— 两份**完全一致**：

| 设置 | 值 |
|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | **`com.qinchao`**（无反向域名后缀，全部小写，非典型但合法） |
| `PRODUCT_NAME` | `$(TARGET_NAME)` |
| `DEVELOPMENT_TEAM` | **`F2JL9GNLCC`**（code-wiki 05 记为免费「个人团队 / Personal Team」，7 天描述文件有效期 `[未验证]`——本机无法从 CLI 取证团队类型） |
| `CODE_SIGN_STYLE` | `Automatic` |
| `CODE_SIGN_IDENTITY` / `CODE_SIGNING_REQUIRED` / `CODE_SIGNING_ALLOWED` / `PROVISIONING_PROFILE_SPECIFIER` | **均未设置**（走 Xcode 自动签名默认） |
| `CODE_SIGN_ENTITLEMENTS` | **未设置**（见 H.3） |
| `IPHONEOS_DEPLOYMENT_TARGET` | **`26.0`** |
| `INFOPLIST_FILE` | `DesignCode/Info.plist` |
| `GENERATE_INFOPLIST_FILE` | 未设置（→ 用 `INFOPLIST_FILE`，因此 `INFOPLIST_KEY_CFBundleDisplayName = 园枢` 实为**空转设置**：`INFOPLIST_KEY_*` 仅在 `GENERATE_INFOPLIST_FILE=YES` 时生效） |
| `SWIFT_VERSION` | `5.0` |
| `TARGETED_DEVICE_FAMILY` | `"1,2"`（iPhone + iPad） |
| `OTHER_SWIFT_FLAGS` | `"$(inherited) -disable-sandbox"`（**非默认**，见下） |
| `ENABLE_PREVIEWS` | `YES` |
| `DEVELOPMENT_ASSET_PATHS` | `"DesignCode/Preview\ Content"` |
| `ASSETCATALOG_COMPILER_APPICON_NAME` | `AppIcon` |
| `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` | `"AppIconAlt1 AppIconAlt2 AppIconAlt3 AppIconAlt4"` |
| `LD_RUNPATH_SEARCH_PATHS` | `$(inherited)`, `@executable_path/Frameworks` |
| `OTHER_LDFLAGS` | `$(inherited)`, `-ObjC`, `-all_load`, `-framework Security`, `-framework CoreGraphics`, `-framework WebKit`, `-framework CFNetwork`, `-framework SystemConfiguration`, `-framework CoreTelephony`, `-lz`, `-lsqlite3`, `-lc++` |
| **微信 user-defined 设置** | `WECHAT_APPID = wx8e60d3a37d3cff47`；`WECHAT_MINI_PROGRAM = gh_PLACEHOLDER0000`；`WECHAT_UL_HOST = jl.43322.cn`；`WECHAT_UNIVERSAL_LINK = "https://jl.43322.cn/app/"` |

> `OTHER_SWIFT_FLAGS` 位置：**L641（App Debug）与 L689（App Release）**。
> `-disable-sandbox` 是 `swift-frontend`/`swift-driver` 的旗标，语义是关闭 Swift 编译期插件/宏的沙箱。**注意与 `ENABLE_USER_SCRIPT_SANDBOXING` 无关**——后者全工程 `grep` **0 命中**（即 Run Script 沙箱为默认关闭，护栏脚本才能 `python3` 读源码目录）。构建日志可见其被真实透传：`export OTHER_SWIFT_FLAGS=' -disable-sandbox'`，`swiftc … -DDEBUG -disable-sandbox …`。
> ⚠️ 既有文档（`qin/docs/code-wiki/05-项目运行方式.md` L19）称"主 target 与测试 target 各一份"——**与 pbxproj 不符**，测试 target 无此设置。

**C. Tests target `DesignCodeTests`**（`DC000084` Debug / `DC000085` Release）—— 两份**完全一致**：

| 设置 | 值 |
|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | **`com.qinchao.tests`** |
| `PRODUCT_NAME` | `$(TARGET_NAME)` |
| `DEVELOPMENT_TEAM` | `F2JL9GNLCC` |
| `CODE_SIGN_STYLE` | `Automatic` |
| `IPHONEOS_DEPLOYMENT_TARGET` | `26.0` |
| `SWIFT_VERSION` | `5.0` |
| `TARGETED_DEVICE_FAMILY` | `"1,2"` |
| `GENERATE_INFOPLIST_FILE` | **`YES`**（测试 bundle 无独立 Info.plist 文件） |
| `TEST_HOST` | `"$(BUILT_PRODUCTS_DIR)/DesignCode.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/DesignCode"` |
| `BUNDLE_LOADER` | `"$(TEST_HOST)"` |

> `TEST_HOST` + `BUNDLE_LOADER` 共同决定：**这是"应用内嵌宿主"式单测**（host application tests），测试进程会把 `DesignCode.app` 作为宿主启动 —— 这正是 H.6.4「测试宿主共享单例必须驻内存」问题的根因。

### H.1.4 部署目标 13 / 26 冲突 —— **仍然存在**

```
$ grep -n IPHONEOS_DEPLOYMENT_TARGET qin/DesignCode.xcodeproj/project.pbxproj
541:  IPHONEOS_DEPLOYMENT_TARGET = 13.0;   # project / Debug
595:  IPHONEOS_DEPLOYMENT_TARGET = 13.0;   # project / Release
616:  IPHONEOS_DEPLOYMENT_TARGET = 26.0;   # App target / Debug
664:  IPHONEOS_DEPLOYMENT_TARGET = 26.0;   # App target / Release
708:  IPHONEOS_DEPLOYMENT_TARGET = 26.0;   # Tests target / Debug
724:  IPHONEOS_DEPLOYMENT_TARGET = 26.0;   # Tests target / Release
```

- **未修复**。project 层的 `13.0` 是"死设置"（被 target 层覆盖），但会让 Xcode GUI 的工程级"Minimum Deployments"显示为 13.0，易误判。
- **实际生效 = `26.0`**，构建日志铁证：`-target arm64-apple-ios26.0`、`-sdk …/iPhoneOS27.0.sdk`。
- 含义：**只能装在 iOS 26+ 设备上**。约定真机 iPhone 13 Pro Max 运行 iOS 27.0（README/文档口径 `[未验证]`）。
- 与 `README.md` L52「目标 iOS: iOS 17+」、L73「Deployment Target: iOS 17.0」**直接矛盾**——README 已过期。

### H.1.5 链接的 Framework

`PBXFrameworksBuildPhase`（App target）：

| 条目 | 类型 | 属性 | 说明 |
|---|---|---|---|
| `AppIntents.framework` | `wrapper.framework`，`sourceTree = SDKROOT`，`path = System/Library/Frameworks/AppIntents.framework` | **`ATTRIBUTES = (Weak,)`（弱链接）** | 文件引用被放在名为 **`Recovered References`** 的兜底分组里（说明曾有引用丢失被 Xcode 恢复） |
| `WechatOpenSDK.xcframework` | `wrapper.xcframework`，`sourceTree = "<group>"`，实际路径 `qin/Frameworks/WechatOpenSDK.xcframework` | 强链接 | 见 H.5 |

- **没有 `PBXCopyFilesBuildPhase`（Embed Frameworks）** —— 这是正确的：`WechatOpenSDK.xcframework` 内是**静态库**（`ar archive`），无需嵌入，靠 `-ObjC -all_load` 把 Objective-C 分类/类拉进最终二进制。
- 其余系统库通过 `OTHER_LDFLAGS` 的 `-framework` 隐式链接，不出现在 Frameworks 阶段。
- 测试 target 的 `PBXFrameworksBuildPhase` **files 为空**（靠 `BUNDLE_LOADER` + `@testable import DesignCode` 拿到符号）。

### H.1.6 Run Script 构建阶段：显示设置覆盖护栏

```text
DC0000A0000000000000A001 /* 显示设置覆盖护栏 */ = {
    isa = PBXShellScriptBuildPhase;
    alwaysOutOfDate = 1;                 # ← 「Based on dependency analysis」未勾选
    buildActionMask = 2147483647;
    files = (); inputFileListPaths = (); inputPaths = ();
    name = "显示设置覆盖护栏";
    outputFileListPaths = (); outputPaths = ();
    runOnlyForDeploymentPostprocessing = 0;
    shellPath = /bin/bash;
    shellScript = "python3 \"$SRCROOT/Scripts/display_coverage_guard.py\"\n";
};
```

要点：

1. **位于 App target `buildPhases` 数组第一位** → 先跑护栏，再编译源码。护栏不通过 → 构建中断，源码一行都不会编。
2. `alwaysOutOfDate = 1` → 每次构建都执行（构建日志显式提示：*"will be run during every build because the option to run the script phase 'Based on dependency analysis' is unchecked"*）。
3. 依赖 `python3`（系统 Python）。`$SRCROOT` 由 Xcode 注入 = `qin/`；脚本内部 `SRCROOT = os.environ.get('SRCROOT', …)`，脱离 Xcode 手工跑时自动回退到脚本上两级目录。
4. **只挂在 App target 上**，测试 target 无此阶段。
5. **本机实跑护栏（脱离 Xcode，2026-10-01）**：

   ```bash
   $ cd /Users/qinchao/Downloads/designcode-swiftui/qin
   $ python3 Scripts/display_coverage_guard.py
   ✅ 显示设置覆盖护栏通过：排版链 0 缺口、弹出层呈现链 0 缺口、UIKit 直连 0 缺口、裸文本 0 缺口
   $ echo $?
   0
   ```

   即**当前工作树护栏为绿**；`build/verify/org_build_20260930_163940.log` L666 亦捕获到同样的通过标记，且同日志 `BUILD SUCCEEDED` 出现 1 次。

6. 护栏**四条规则**（`Scripts/display_coverage_guard.py` 文件头 L6-L20）：
   - 规则一（排版链）：禁止绕过显示设置的原始字体写法，必须用 `displayFont` / `displayText` / `displaySymbolFont` / `displayLabelFont` / `DisplayFontFactory.font`。
   - 规则二（弹出层）：每个 `.sheet` / `.fullScreenCover` 内容必须挂 `.sjzPresentationChrome()`（判定窗口 80 行**且剔除注释行**；系统 `ShareSheet` 内置豁免）。
   - 规则三（UIKit / AttributedString 直连字体）：禁止 `.font = .system` / `.systemFont(` / `.boldSystemFont(` / `.italicSystemFont(` / `UIFont(name:`。
   - 规则四（裸文本零容忍）：复用 `display_baretext_audit.py` 的**语句级**审计（构造自身修饰链 + 尾随闭包 + 祖先容器覆盖 + 调用点覆盖），命中即中断构建。
   - 例外登记：`Scripts/display_coverage_allowlist.txt`，语法 `font:|presentation:|uikit:|baretext:` + `文件名.swift|匹配片段 # 理由`。当前**仅 2 条例外**（均 `uikit:DisplaySettingsManager.swift|…`，即 `DisplayUIFontFactory` 工厂本体与 `UIFont(name:)` 字体存在性探测）。
   - `display_coverage_guard.py` 通过 `sys.path.insert(0, 脚本目录)` 后 `import display_baretext_audit`（L36-L37），所以两者必须同目录、且 `Scripts/__pycache__/` 是这条依赖链的副产物（已被 `.gitignore` 的 `__pycache__/` 覆盖）。

### H.1.7 文件引用与分组方式

- **纯经典模式**：`PBXBuildFile`（L10-L69）+ `PBXFileReference`（L84-L148）+ `PBXGroup`（L171-L289）+ `PBXSourcesBuildPhase`（L398-L469）。
- **`grep -n fileSystemSynchronized` → 0 命中**；`objectVersion = 54` 亦不支持。**没有 `PBXFileSystemSynchronizedRootGroup`**，因此新增文件不会被自动纳入编译。
- 分组树：

  ```
  (root, 无 name)  ABE07CB2
  ├─ DesignCode            path = DesignCode      ← 55 个子项（50 .swift + Assets.xcassets + LaunchScreen.storyboard + Info.plist + DesignCode.entitlements + Preview Content）
  │   └─ Preview Content   path = "Preview Content" → Preview Assets.xcassets
  ├─ DesignCodeTests       path = DesignCodeTests ← 6 个测试 .swift
  ├─ Frameworks            path = Frameworks      ← WechatOpenSDK.xcframework
  ├─ Products                                      ← DesignCode.app / DesignCodeTests.xctest
  └─ Recovered References  name = "Recovered References" ← AppIntents.framework
  ```

- `LaunchScreen.storyboard` 是唯一 `PBXVariantGroup`（Base → `Base.lproj/LaunchScreen.storyboard`）。
- **一致性核对（本次实跑）**：`DesignCode/*.swift` 磁盘 50 个；App Sources 阶段 `in Sources` 条目 50 条；逐文件脚本核对**零 MISSING**。测试 6/6 对齐。
- **运维含义**：新增 `.swift` 必须在 pbxproj 打**四处**补丁（`PBXBuildFile` + `PBXFileReference` + 所属 `PBXGroup.children` + `PBXSourcesBuildPhase.files`），且 PBX ID 需先 grep 防撞（24 位十六进制）。这就是 `docs/code-wiki/05` §5.8 建议"测试用例追加进既有测试文件而非新建文件"的原因。

### H.1.8 Scheme（可复现性缺口）

```
$ xcodebuild -project DesignCode.xcodeproj -list
Information about project "DesignCode":
    Targets:
        DesignCode
        DesignCodeTests
    Build Configurations:
        Debug
        Release
    If no build configuration is specified and -scheme is not passed then "Release" is used.
    Schemes:
        DesignCode
```

- **工程级** `DesignCode.xcodeproj/xcshareddata/`（放共享 scheme 的位置）**不存在**！scheme 只存在于用户态：
  - `xcuserdata/qinchao.xcuserdatad/xcschemes/xcschememanagement.plist`
  - `xcuserdata/mythxn.xcuserdatad/xcschemes/xcschememanagement.plist`
- （对照：**workspace 级** `project.xcworkspace/xcshareddata/` 存在且已入库，内含 `IDEWorkspaceChecks.plist` 与空目录 `swiftpm/configuration/` —— 与 scheme 无关。）
- 由于 `xcuserdata/` 被 `.gitignore` 排除，**新克隆的仓库没有共享 scheme**。xcodebuild 目前仍能列出 `DesignCode`（Xcode 会自动创建/推断 scheme），但这是**隐式依赖**：CI 或全新机器上若 `-scheme DesignCode` 报 "scheme not found"，需要先在 Xcode 里打开工程一次（勾选 Shared）或手写 `xcshareddata/xcschemes/DesignCode.xcscheme`。`[部分未验证]`（本机有 xcuserdata，无法复现新克隆场景）。

---

## H.2 `qin/DesignCode/Info.plist` 全键值

文件 2999 字节 / 95 行。**顶层键共 23 个**（`plutil -convert json` 枚举，按字母序）：

| 键 | 值 | 备注 |
|---|---|---|
| `CADisableMinimumFrameDurationOnPhone` | `true` | 解锁 ProMotion 120Hz（工程红线之一） |
| `CFBundleDevelopmentRegion` | `$(DEVELOPMENT_LANGUAGE)` | 由 `developmentRegion = zh-Hans` 注入 |
| `CFBundleDisplayName` | **`园枢`** | 硬编码在 plist（build setting 里那份 `INFOPLIST_KEY_CFBundleDisplayName` 是空转，见 H.1.3） |
| `CFBundleExecutable` | `$(EXECUTABLE_NAME)` | |
| `CFBundleIdentifier` | `$(PRODUCT_BUNDLE_IDENTIFIER)` | → `com.qinchao` |
| `CFBundleInfoDictionaryVersion` | `6.0` | |
| `CFBundleLocalizations` | `[zh-Hans, en, Base]` | |
| `CFBundleName` | `$(PRODUCT_NAME)` | → `DesignCode` |
| `CFBundlePackageType` | `$(PRODUCT_BUNDLE_PACKAGE_TYPE)` | → `APPL` |
| `CFBundleShortVersionString` | **`1.0`**（硬编码，未接 `MARKETING_VERSION`；工程里也没有 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 设置） | 见风险 |
| `CFBundleURLTypes` | `[{ CFBundleTypeRole = Editor; CFBundleURLName = weixin; CFBundleURLSchemes = [ $(WECHAT_APPID) ] }]` | 运行时 scheme = `wx8e60d3a37d3cff47` |
| `CFBundleVersion` | **`1`**（硬编码） | |
| `LSApplicationQueriesSchemes` | **`[weixin, weixinULAPI, weixinURLParamsAPI]`**（3 项） | 微信 SDK 端点探测白名单 |
| `LSRequiresIPhoneOS` | `true` | |
| **`NSAppTransportSecurity`** | `{ NSAllowsArbitraryLoads = false; NSExceptionDomains = { sxjzit.edu.cn = { NSExceptionAllowsInsecureHTTPLoads = true; NSIncludesSubdomains = true } } }` | **仅**放行 `sxjzit.edu.cn` 及其子域的 HTTP（用于 `http://www2.sxjzit.edu.cn:8082/` 图片 CDN，配合 `RefererHeaderURLProtocol`） |
| `NSFaceIDUsageDescription` | 「使用 Face ID / Touch ID 解锁「园枢」，保护冷启动、后台返回与敏感页面时的隐私内容。生物特征数据由系统安全芯片处理，App 不会获取或存储。」 | |
| `NSPhotoLibraryAddUsageDescription` | 「用于将校园风光、现任领导、校徽校名等图片保存到您的系统相册（仅写入，不读取相册内容）。」 | **仅 Add**（写入），无 `NSPhotoLibraryUsageDescription`（不读取） |
| `UILaunchStoryboardName` | `LaunchScreen` | 对应 `Base.lproj/LaunchScreen.storyboard` |
| `UIRequiredDeviceCapabilities` | `[arm64]` | |
| `UISupportedInterfaceOrientations` | `[Portrait, LandscapeLeft, LandscapeRight]` | |
| `UISupportedInterfaceOrientations~ipad` | `[Portrait, PortraitUpsideDown, LandscapeLeft, LandscapeRight]` | |
| `WeChatMiniProgramID` | `$(WECHAT_MINI_PROGRAM)` | → `gh_PLACEHOLDER0000`（占位） |
| `WeChatUniversalLink` | `$(WECHAT_UNIVERSAL_LINK)` | → `https://jl.43322.cn/app/` |

**关键缺失 / 注意点：**

1. **`UIBackgroundModes` 完全不存在**（`grep -c` = 0）。App 无任何后台模式声明（无 `fetch`、无 `remote-notification`）。因此后台通知依赖 `NotificationManager` 的**前台轮询**（默认 30 分钟，见 code-wiki 05 §5.5）而非系统静默推送；息屏/被杀后不会有 `BGAppRefresh`。这是运维上必须知道的边界。
2. **ATS 例外域与微信 UL 域不一致**：ATS 例外只写了 `sxjzit.edu.cn`，而微信配置的 `WECHAT_UL_HOST = jl.43322.cn`（`https://`，本身不需要 ATS 例外）。但 `CFBundleURLTypes` 里没有任何 `jl.43322.cn`/`applinks` 相关条目——UL 完全依赖 entitlements（而 entitlements 未接线，见 H.3），所以**微信回跳链路当前是断的**。
3. 无 `NSUserTrackingUsageDescription`、无 `NSMicrophoneUsageDescription`、无 `NSCameraUsageDescription`、无 `NSLocationWhenInUseUsageDescription`、无 `NSPhotoLibraryUsageDescription`、无 `NSContactsUsageDescription`——与"仅写入相册 + FaceID"的隐私面一致。
4. `CFBundleShortVersionString` / `CFBundleVersion` 均为硬编码（`1.0` / `1`），**未使用 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`**（pbxproj 中这两个键 0 命中）→ 每次发版必须手改 plist。
5. 键名 `WeChatMiniProgramID` / `WeChatUniversalLink` 是**自定义键**（非 Apple 标准），由 `WeChatService` 读取。

---

## H.3 `qin/DesignCode/DesignCode.entitlements` —— **声明存在但从未生效**

文件内容（900 字节，仅 1 个能力）：

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:$(WECHAT_UL_HOST)</string>   <!-- → applinks:jl.43322.cn -->
</array>
```

文件头顶部有一段中文注释，说明该文件与构建设置 `WECHAT_UL_HOST` 联动、AASA 必须部署在 `https://<域名>/.well-known/apple-app-site-association`。

**但：**

```
$ grep -in "entitlement" qin/DesignCode.xcodeproj/project.pbxproj
139:  DC0000B5000000000000B005 /* DesignCode.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = DesignCode.entitlements; sourceTree = "<group>"; };
247:          DC0000B5000000000000B005 /* DesignCode.entitlements */,     ← 只是 DesignCode 分组的 children

$ grep -n "CODE_SIGN_ENTITLEMENTS" qin/DesignCode.xcodeproj/project.pbxproj
（0 命中）
```

→ **`CODE_SIGN_ENTITLEMENTS` 在 6 个 `XCBuildConfiguration` 里一个都没设**。该文件纯粹是"躺在工程导航器里"，**不参与任何签名**，`applinks:jl.43322.cn` 从未写进描述文件。

**这是刻意为之（有记录的取舍）**，`qin/docs/code-wiki/05-项目运行方式.md` L71 记载：签名团队是免费「个人团队」，Associated Domains 属付费 ADP 专属能力；一旦打开 `CODE_SIGN_ENTITLEMENTS`，CLI 构建即报
`Provisioning profile doesn't include the Associated Domains capability`。
**后果**：微信分享/登录的 Universal Link 回跳与回执不可达（发送动作本身可用）。升级付费账号后的修复路径 = 在 App target Debug/Release **两处**加 `CODE_SIGN_ENTITLEMENTS = DesignCode/DesignCode.entitlements`。

> **本任务的一项结论修正**：既有文档称"故 `CODE_SIGN_ENTITLEMENTS` 保持关闭"——用词为"关闭"，易被读成"设置为空/NO"。事实是**该键根本不存在**，语义上等价于未启用，但排查时不要去找一个不存在的设置项。

其余能力：**DesignCode.entitlements 只有这 1 项**。无 `aps-environment`（推送）、无 `com.apple.developer.usernotifications.*`、无 Keychain Sharing、无 App Groups、无 HealthKit/iCloud。→ 本地通知（`UNUserNotificationCenter`）与 Keychain（生物识别 token）都在**无需 entitlement** 的默认能力范围内，所以没有对应键是正确的。

---

## H.4 `qin/ExportOptions.plist`（导出配置）

```xml
<key>method</key>            <string>development</string>
<key>teamID</key>            <string>F2JL9GNLCC</string>
<key>compileBitcode</key>    <false/>
<key>destination</key>       <string>export</string>
<key>stripSwiftSymbols</key> <true/>
<key>thinning</key>          <string>&lt;none&gt;</string>
```

- `method = development` → 产出**开发分发**（ad-hoc / development 签名）IPA，不是 `app-store` / `ad-hoc` / `enterprise`。
- `teamID = F2JL9GNLCC` 与 pbxproj 的 `DEVELOPMENT_TEAM` 一致。
- `compileBitcode = false`（bitcode 已被 Apple 废弃，此处正确）。
- `stripSwiftSymbols = true`（剥离 Swift 符号，减小体积；会让部分符号化崩溃日志失真）。
- `thinning = <none>` → **不做 app thinning**，IPA 内含全部架构/资源切片。
- 仓库内**没有** App Store 上传脚本、没有 `altool`/`notarytool`/`xcrun altool` 调用、没有 TestFlight 配置、**没有任何 CI 配置文件**（`.github/workflows`、`.gitlab-ci.yml`、`Jenkinsfile`、`fastlane/` 均不存在）→ 构建/测试/导出**全部为本机手工执行**。
- 一键导出命令（未在脚本中出现，按 `ExportOptions.plist` 语义补全，**`[未验证]`**）：

  ```bash
  cd /Users/qinchao/Downloads/designcode-swiftui/qin
  xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/verify/DesignCode.xcarchive \
    -allowProvisioningUpdates archive
  xcodebuild -exportArchive -archivePath build/verify/DesignCode.xcarchive \
    -exportOptionsPlist ExportOptions.plist -exportPath build/verify/export
  ```

---

## H.5 `qin/Frameworks/WechatOpenSDK.xcframework`

### 结构（`find . -maxdepth 3`）

```
WechatOpenSDK.xcframework/                        （14 MB 总计）
├── Info.plist                                    （1220 B，XCFramework 清单）
├── PrivacyInfo.xcprivacy                         （461 B，隐私清单）
├── README.txt                                    （4737 B，官方版本变更日志）
├── ios-arm64/
│   └── WechatOpenSDK.framework/
│       ├── WechatOpenSDK                          ← 静态库（ar archive）
│       ├── Headers/  { WechatAuthSDK.h, WechatOpenSDK.h, WXApi.h, WXApiObject.h }
│       ├── Info.plist
│       └── Modules/module.modulemap
└── ios-arm64_x86_64-simulator/
    └── WechatOpenSDK.framework/ （同构；WechatOpenSDK 为 x86_64 + arm64 双架构 ar）
```

### 支持架构（`Info.plist` 实读 + `file` 实读）

| LibraryIdentifier | SupportedPlatform | Variant | SupportedArchitectures | `file` 判定 |
|---|---|---|---|---|
| `ios-arm64` | `ios` | — | `arm64` | `Mach-O universal binary with 1 architecture … [arm64: current ar archive]` |
| `ios-arm64_x86_64-simulator` | `ios` | `simulator` | `arm64`, `x86_64` | `Mach-O universal binary with 2 architectures: [x86_64: current ar archive] [arm64]` |

- `CFBundlePackageType = XFWK`，`XCFrameworkFormatVersion = 1.0`，两 slice 的 `BinaryPath` 均为 `WechatOpenSDK.framework/WechatOpenSDK`。
- 内层 framework `Info.plist`：`CFBundleIdentifier = com.tencent.WechatOpenSDK`，`CFBundleShortVersionString = 1.0`（**注意：内层版本号无意义**），`MinimumOSVersion = 12.0`。
- **SDK 真实版本从 `README.txt` 首行判定：`SDK2.0.8`**（"增加助手 app 跳转公众号主页支持"）。README 同时是把 H.1.3 里那一串 `OTHER_LDFLAGS` 的**来源依据**逐条记录下来的官方说明（SDK1.5 起要求 `SystemConfiguration` + `libz` + `libsqlite3`；SDK1.6 起要求 `CoreTelephony`；SDK1.7.4 起要求 `CFNetwork` + `-Objc -all_load`；SDK1.6 起要求 `LSApplicationQueriesSchemes`）。

### 如何被链接

1. **工程引用方式**：普通 `PBXFileReference`（`lastKnownFileType = wrapper.xcframework`，`path = WechatOpenSDK.xcframework`，`sourceTree = "<group>"`），挂在 `PBXGroup "Frameworks"`（`path = Frameworks`）下 → 解析为 `qin/Frameworks/WechatOpenSDK.xcframework`。**不是** `XCSwiftPackageProductDependency`，**不是** CocoaPods/Carthage，**没有** `project.xcworkspace/xcshareddata/swiftpm/`。
2. **编译期**：加入 App target 的 `PBXFrameworksBuildPhase.files`（`DC0000A1000000000000A002`），**强链接**。
3. **链接期**：因为是**静态库**，需要 `OTHER_LDFLAGS` 的 `-ObjC -all_load` 才能把 Objective-C 分类与未被显式引用的类拉进产物；系统依赖库（Security / CoreGraphics / WebKit / CFNetwork / SystemConfiguration / CoreTelephony / libz / libsqlite3 / libc++）由 `OTHER_LDFLAGS` 补齐。
4. **运行期**：**无 Embed 阶段**（静态库已并入可执行文件）。`LD_RUNPATH_SEARCH_PATHS` 里的 `@executable_path/Frameworks` 是 Xcode 模板默认值，与微信 SDK 无关。
5. **Swift 侧调用**：Swift 文件（`WeChatService.swift` / `WeChatIntegrationViews.swift`）通过 `Modules/module.modulemap` 以 `import WechatOpenSDK` 使用。
6. **模拟器可用性**：slice 覆盖 `arm64` + `x86_64` 模拟器 → 理论上模拟器可编译；但项目约定**只跑真机**（见 H.8.1）。
7. **隐私清单**：`PrivacyInfo.xcprivacy` 随 xcframework 走；App 侧**没有**自己的 `PrivacyInfo.xcprivacy`（`glob **/PrivacyInfo.xcprivacy` 在 `qin/DesignCode/` 下 0 命中）`[未验证：App Store 提交是否需要自有隐私清单]`。

---

## H.6 单元测试套件（`qin/DesignCodeTests/`）

### H.6.1 总览（**总用例数 = 237**）

| 文件 | 字节 | 行 | `XCTestCase` 类（用例数） | 功能性域 | 真实网络 |
|---|---|---|---|---|---|
| `BookmarkManagerTests.swift` | 22,333 | 503 | `BookmarkManagerTests` (**23**) + `ReadStatusManagerTests` (**4**) | 收藏增删去重/上限、文件存储往返、UserDefaults 迁移、损坏抢救与自愈、筛选排序时间分组纯函数、最近阅读与更新徽标、批量/清空计数、图片固化缓存、设置持久化；已读回退/快照/保序截断 | ❌ 无 |
| `LogManagerTests.swift` | 22,968 | 513 | `LogManagerTests` (**29**) | 写入顺序与级别门控、FIFO 上限、多关键词搜索、组合筛选、模块聚合、内存统计、单条/条件删除（内存+磁盘同步）、清空、追加合并落盘保真、逐条抢救、崩溃日志本地日键、崩溃开关快照、TXT/JSON/筛选导出、保留天数清理、存储快照、文件名清洗 | ❌ 无 |
| `MessageCenterStoreTests.swift` | 95,789 | 1,816 | `MessageCenterStoreTests` (**29**)、`HomeModuleManagerTests` (**5**)、`CampusCalendarStoreTests` (**3**)、`NetworkMonitorLogicTests` (**12**)、`DisplaySettingsLogicTests` (**23**)、`ArticleLongImageLogicTests` (**25**)、`SJZImageViewerGeometryTests` (**11**)、`SJZImageViewerPagingTests` (**6**) = **114** | 消息中心 ingest 去重/测试排除、FIFO 截断、损坏自愈、markRead 幂等与 markAllRead、清空两 scope、筛选纯函数、latestItem、未读兜底、启动无载荷降级、深链归因、自动检查节流、快速修复重写；**以及**首页模块可见性、校园日历历史、网络监测判定（宿主归因/慢请求分级）、显示设置（家族/档位/外观/灰度/迁移映射/字号解析）、长图渲染（内存预算/像素上限/降采样/编码上限/页脚文案/黑图防御）、看图器几何契约（绝对位移/边界夹紧/阻尼/锚点缩放）与翻页契约 | ❌ 无（含 WKWebView 之外的纯逻辑 `URL` 字符串处理，不发起请求） |
| `NetworkServiceDTOTests.swift` | 27,487 | 650 | `NetworkServiceDTOTests` (**11**) + `ReadingStatsCalculatorTests` (**11**) = **22** | API DTO 解码（Home2/Banner/Article/Column/Campus/Video/AnyCodable/APIResponse.requireData 抛错）、阅读统计（中文字数/英文词数/时长口径） | ✅ **3 条在线**（见 H.6.3） |
| `OrgModuleTests.swift` | 18,392 | 384 | `OrgModuleTests` (**22**) | 机构模块纯逻辑：栏目索引构建、栏目类型分派、分页状态机、请求并发闸、工具入口路由（样本来源：2026-09-30 官网实测 jwc 教务处 nav 结构，见 `qin/docs/departments-api-evidence/raw/home2_jwc.json`） | ❌ 无（样本以字面量内联） |
| `WeChatSDKTests.swift` | 20,183 | 358 | `WeChatSDKTests` (**23**) | 微信集成契约：Info.plist 声明（URL Scheme = AppID、`WeChatUniversalLink`、`WeChatMiniProgramID`、3 条 `LSApplicationQueriesSchemes`）、占位判定与 AppID 格式、官方字节限制（标题 ≤512B / 描述 ≤1024B 且不切断多字节）、缩略图 200×200 居中裁方 + JPEG ≤32KB、长图 ≤10MB 自动降档、菜单预览 200pt、回执文案归因、`WXScene` 数值对齐、可用性状态机、自检七步标题、横幅模型 | ❌ 无（全部为可离线断言） |
| **合计** | **207,152** | **4,224** | **15 个类** | — | **3 条在线** |

**计数方法（可复现）：**

```bash
cd /Users/qinchao/Downloads/designcode-swiftui/qin/DesignCodeTests
grep -c 'func test' *.swift | awk -F: '{s+=$2; print} END {print "TOTAL="s}'
# BookmarkManagerTests.swift:27
# LogManagerTests.swift:29
# MessageCenterStoreTests.swift:114
# NetworkServiceDTOTests.swift:22
# OrgModuleTests.swift:22
# WeChatSDKTests.swift:23
# TOTAL=237
```

> `func test` 计数 = XCTest 实际执行的 `test*` 方法数 —— 已逐类核对：`awk` 按 `class …: XCTestCase` 分段统计，各文件分段和与 `grep -c` 完全吻合（27/29/114/22/22/23），**无 `func testHelper` 之类误计**（本仓库未见非 `test` 前缀的辅助方法被计入）。
> 异步用例（`func test…async`）：Bookmark 2、Log 10、MessageCenter 1、DTO 5、Org 1、WeChat 0 —— 共 **19 条**。无 `XCTSkip` / `XCTExpectFailure`（`grep` 0 命中），即**没有"自动跳过"的软失败通道**：环境不满足就是硬失败。

### H.6.2 每个文件的定位与"能不能信"

| 文件 | 定位 | 复跑稳定性 |
|---|---|---|
| `LogManagerTests` | 日志子系统**契约测试**，含 H.6.4 的隔离契约 | 高（全离线、注入临时目录） |
| `BookmarkManagerTests` | 收藏 + 已读**存储层契约**（含损坏自愈、逐条抢救这类"防灾"用例） | 高 |
| `MessageCenterStoreTests` | 体量最大的"**多模块纯逻辑总仓**"：8 个类横跨消息中心/首页模块/日历/网络监测/显示/长图/看图器。它是 `SJZImageViewerGeometry`×`MagnifyGesture` 手势层重写、长图黑图两轮根治、netmon 媒体宿主误报修复的**回归网** | 高（但**类名与文件名的错配**是维护陷阱：改显示设置要来这里找 `DisplaySettingsLogicTests`） |
| `NetworkServiceDTOTests` | DTO 解码**防崩网** + 阅读统计口径 | **中：3 条在线用例是唯一的不稳定源** |
| `OrgModuleTests` | 机构模块阶段一纯逻辑（样本=官网实测快照） | 高（**样本内联**，官网改版不会自动挂——代价是"样本与线上漂移"无告警） |
| `WeChatSDKTests` | 微信接入**要件契约**（把官方文档的字节级限制固化成断言） | 高（读 Info.plist + 纯函数） |

### H.6.3 ⚠️ 真实网络依赖（在线测试会随学校数据变化而挂）

`NetworkServiceDTOTests.swift` 尾部有专门的 `// MARK: - 真实 API 在线测试` 分区，**3 条**用例直连学校 API（`URLSession.shared`，无 mock、无 `URLProtocol` 拦截）：

| 用例 | 行 | 端点 | 脆弱断言 |
|---|---|---|---|
| `testRealAPIHome2Decoding()` | L396 | `https://gwqietap.sxjzit.edu.cn/mapi/school/home2`（`timeoutInterval = 30`） | `statusCode == 200`；`topBanners` **非空**；13 个字段非 nil；**`importants.articles.total > 100`**、**`notices.articles.total > 50`** |
| `testRealAPIArticlesDecoding()` | L443 | `…/mapi/common/column/articles?site_id=1&column_id=41cb4c8424ac474891e1470aa2fb071b&page=1&size=5` | `columnId` 精确相等；`total > 0`；**`list.count == 5`** |
| `testRealAPIArticleDetailDecoding()` | L466 | `…/mapi/common/article/detail?article_id=744c042893c34adbb78ea2a799efe5cb` | `title`/`content` 非 nil；`content.count > 50` |

**为什么必然会挂（运维要点）：**

1. `total > 100`、`total > 50`、`list.count == 5` 这类**数量断言**绑定的是"当前学校 CMS 里的存量数据"。栏目被清理、文章被下架、分页 size 被服务端改、`column_id` 变更 → 断言即红。
2. `article_id=744c…` 是**硬编码的单篇文章 ID**，文章一旦被删除/下线就直接 404/数据为 nil。
3. 依赖 DNS/网络可达 `gwqietap.sxjzit.edu.cn`；断网、校园网限制、证书变更、超时（30s）都会失败。
4. 反向也危险：**这些用例实际上在往「应用日志」外发真实请求**（测试宿主 App 里跑），会污染 netmon 遥测口径。
5. 判定策略建议（运维层）：
   - 只想验证"代码没坏" → **跳过在线用例**：
     ```bash
     xcodebuild test -project DesignCode.xcodeproj -scheme DesignCode \
       -destination 'platform=iOS,id=00008110-000411A40EC1401E' \
       -allowProvisioningUpdates \
       -skip-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIHome2Decoding \
       -skip-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIArticlesDecoding \
       -skip-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIArticleDetailDecoding
     ```
     或按类跳过：`-skip-testing:DesignCodeTests/NetworkServiceDTOTests`（会连带跳过 11 条离线 DTO 用例，不推荐）。
   - 反向只跑在线冒烟：`-only-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIHome2Decoding`。
   - 已实测到的最稳做法：**先在 Safari/curl 确认 `https://gwqietap.sxjzit.edu.cn/mapi/school/home2` 返回 200 且 `data.news.children.importants.articles.total > 100`**，再跑全量。

### H.6.4 测试宿主与真实日志的隔离（"共享实例仅驻内存"）

**机制（源码实证 `qin/DesignCode/LogManager.swift` L272-L284）：**

```swift
/// 共享实例：测试宿主（XCTest）中自动切换为「仅驻内存」——
/// 不读/不写真实日志文件，杜绝单元用例故意构造的错误路径（损坏存储 / 超限 / 空 id 等）
/// 污染用户在「应用日志」里看到的真实日志内容。
/// （2026-09-28 真机日志复核实证：日志页 4 条 ERROR 的字节数与测试夹具逐一吻合，真实存储完好）
static let shared = LogManager(persistsToDisk: !LogManager.isRunningTests)

/// 是否运行在 XCTest 宿主（测试环境中共享实例仅驻内存）
nonisolated static let isRunningTests: Bool = {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}()

/// 是否持久化到磁盘（共享实例在测试宿主下为 false；注入初始化默认 true，测试可断言落盘行为）
let persistsToDisk: Bool
```

- **双信号判定**：环境变量 `XCTestConfigurationFilePath`（XCTest 注入）**或** `NSClassFromString("XCTestCase") != nil`（XCTest 框架已加载）。两者取或 —— 兼容 XCTest 与 Swift Testing/自定义 runner 的差异。默认参数 `persistsToDisk: Bool = true`（L400）。
- **三处落盘入口全部被 `persistsToDisk` 闸住**：L420（写盘前判断）、L573（`guard persistsToDisk else { return 0 }`）、L822 / L854（两个清理入口 `guard`）。
- **契约测试**：`LogManagerTests.swift` L492-L496

  ```swift
  /// 生产日志隔离：XCTest 宿主下共享实例必须仅驻内存（不得把用例故意构造的
  /// 错误路径写入真实日志文件，污染用户「应用日志」），注入实例保持标准落盘能力
  XCTAssertTrue(LogManager.isRunningTests, "XCTest 宿主应被识别")
  XCTAssertFalse(LogManager.shared.persistsToDisk, "测试宿主下共享实例必须仅驻内存")
  ```

- **其余三个 Store 的隔离靠"注入"而非"驻内存"**：`BookmarkManagerTests` / `LogManagerTests` / `MessageCenterStoreTests` 的 `setUp` 都注入**临时目录 + 独立 `UserDefaults(suiteName:)`**，`tearDown` 清理 `suiteName`（`MessageCenterStoreTests.swift` L24/L34、L391/L396）。文件头注释统一声明："全部用例注入临时目录 + 独立 UserDefaults suite，互不污染。"
- **人肉验证法（code-wiki 05 §5.8 记录，本机未复跑）** `[未验证]`：真机跑完单测后立刻拉日志，看"测试时间窗内是否出现新条目"——无新条目即隔离生效。
- **残留风险（值得写进 wiki 的坑）**：隔离只覆盖了 `LogManager.shared` 这一个共享实例。其他 `@MainActor` 单例（`BookmarkManager.shared`、`MessageCenterStore.shared`、`ReadStatusManager.shared`、`DisplaySettingsManager.shared`…）在测试宿主里**默认仍指向真实 Documents/UserDefaults**；它们之所以没出问题，是因为用例都走了**注入实例**。**新增用例若直接碰 `Xxx.shared` 的写路径，就会真的写进用户沙盒** —— 这是本套测试的隐性纪律。

### H.6.5 237 vs 195：实跑证据链

| 时间 | 日志 | 结果 |
|---|---|---|
| 2026-09-28 07:46 | `build/verify/final_audit_test.log` | `Executed 104 tests, with 0 failures` — `Test Suite 'All tests' passed` |
| 2026-09-28 15:19 | `build/verify/log_module_full_test.log` | **190 / 0** — passed |
| 2026-09-29 09:16 | `build/verify/bookmark_deeplink_fix_test.log` | **195 / 0** — passed |
| 2026-09-29 14:57 | `build/verify/device_tests_20260929_145712.log` | **195 / 0**，`Test Suite 'DesignCodeTests.xctest' passed at 2026-09-29 14:57:46.745`，`Test Suite 'All tests' passed`；总耗时 6.089s（6.149s） |
| 2026-09-30 16:40 | `build/verify/org_build_20260930_163940.log` | `BUILD SUCCEEDED` ×1，护栏通过（**但这是 build，不是 test**） |

- **全仓库对 `Executed 237` 的搜索 0 命中**；对 `OrgModuleTests` 的日志搜索 **0 命中** → **包含 22 条机构用例与后加的 17+3 条在内的 237 例，从未在设备上跑过**。
- 差值构成：`237 − 195 = 42` = OrgModuleTests 22 + MessageCenterStoreTests 新增 17（97→114）+ BookmarkManagerTests 新增 3（24→27）。与 `qin/docs/code-wiki/05` L48 的分项（消息中心系 97 + DTO/阅读统计 22 + 微信 23 + 收藏/已读 24 + 日志 29 = 195）严丝合缝。
- **给 wiki 的表述建议**：写"静态 237 例；最近一次全量真机实跑为 195/195（2026-09-29 14:57）；237 例待补一次全量实跑"。不要直接抄 195 当现状。
- **首次跑 237 例的注意**：`MessageCenterStoreTests` 114 例里有 `DisplaySettingsLogicTests`（23 例，碰 `DisplaySettingsManager` 的迁移映射与字号解析）与 `ArticleLongImageLogicTests`（25 例，长图渲染预算），它们都不依赖网络但可能依赖真机字体可用性 —— **建议同期跑一次 `python3 qin/Scripts/display_baretext_audit.py` 与显示验证脚本作为交叉证据**。

---

## H.7 `qin/Scripts/` 全量清单

### `ls -la qin/Scripts/`（完整列全，含权限）

```
drwxr-xr-x@  4 qinchao  staff    128  9月 29 13:56 __pycache__
-rw-r--r--@  1 qinchao  staff   9213  9月 29 10:24 bookmark_deeplink_selftest.py
-rw-r--r--@  1 qinchao  staff  16975  9月 29 09:56 deeplink_forensics.py
-rwxr-xr-x@  1 qinchao  staff  17694  9月 29 14:56 device_display_verify.sh
-rw-r--r--@  1 qinchao  staff   9868  9月 29 13:44 display_baretext_audit.py
-rw-r--r--@  1 qinchao  staff   1273  9月 29 13:56 display_coverage_allowlist.txt
-rw-r--r--@  1 qinchao  staff   7649  9月 29 13:55 display_coverage_guard.py
-rw-r--r--@  1 qinchao  staff  15218  9月 22 15:39 generate_alternate_icons.py
-rwxr-xr-x@  1 qinchao  staff  47662  9月 30 16:50 org_module_acceptance.sh
-rwxr-xr-x@  1 qinchao  staff   4547  9月 29 10:56 push_all.sh
-rwxr-xr-x@  1 qinchao  staff   6007  9月 29 11:24 remote_sync_report.sh
```

- **共 10 个文件 + 1 个 `__pycache__` 目录**：4 个 `.sh`（**均 `755` 可执行**）+ 5 个 `.py`（**均 `644`，必须 `python3 xxx.py` 调用，不能 `./xxx.py`**）+ 1 个 `display_coverage_allowlist.txt`（护栏例外清单，非脚本）。
- `__pycache__/` 是 `display_coverage_guard.py import display_baretext_audit` 的副产物，已被根 `.gitignore` 的 `__pycache__/` / `*.pyc` 覆盖。
- **`Scripts/display_baretext_baseline.json` 不存在**（`display_baretext_audit.py` L32 期待的基线快照）。→ `python3 display_baretext_audit.py --baseline` 走 `if os.path.exists(BASELINE_PATH)` 的"无基线"分支（首次生成/退化行为），**不是**"新增位置即失败"的严格护栏。构建期护栏（`display_coverage_guard.py`）**不依赖**该文件（它只调 `audit_file`），因此**构建不受影响**。

### 脚本总表

| 脚本 | 语言/权限 | 一句话用途 | 依赖工具 | 主要产物 | 可复跑性 |
|---|---|---|---|---|---|
| `device_display_verify.sh` | bash / 755 | 真机「构建→安装→启动→观察窗→拉日志→结构化校验→Markdown 报告」闭环，验证**显示设置全局覆盖** | `xcodebuild`、`xcrun devicectl`、`python3` | `build/verify/device_build_<ts>.log`、`device_display_verify_<ts>.md`、`device-logs-<ts>/`、`device_tests_<ts>.log`（`--tests`） | **高**（幂等；每次带时间戳；`--dry-run` 无副作用） |
| `org_module_acceptance.sh` | bash / 755 | 真机**机构模块阶段一~三** 13 条交互验收 + 5 条代码静态契约，含"持久化旁证"抗日志 1000 条上限 | `xcodebuild`、`xcrun devicectl`、`python3`、`curl`（`--dry-run` 打印参照数据命令） | `build/verify/org_build_<ts>.log`、`org_acceptance_<ts>.md`、`org_acceptance_ref_<ts>.json`、`org-acceptance-logs-<ts>/` | **高**（用例级 `--only`、`--report-only` 考古、状态型旁证使其不依赖日志窗口） |
| `push_all.sh` | bash / 755 | 三远端（origin/gitee/cnb）**一键推送**分支 + tags，逐远端预检、失败不中断、结束汇总一致性核验 | `git`、凭据（Gitee SSH `~/.ssh/id_ed25519_gitee`；CNB HTTPS 令牌存 macOS Keychain，用户名固定 `cnb`） | stdout 汇总；**永不 force push** | **高**（`--dry-run` 只预检；`--only cnb` 单远端重试；`--branch` / `--no-tags`） |
| `remote_sync_report.sh` | bash / 755 | 生成**三远端同步验证报告**（实时采集，非手写），判定三远端 `refs/heads/main == 本地 HEAD` | `git`、`push_all.sh`（内部调 `--dry-run`） | `qin/docs/remote-sync/remote_sync_verification_<YYYYMMDD>.md`（**同日重跑覆盖**） | **高**（只读；`--push` 追加实推取证） |
| `deeplink_forensics.py` | python3 / 644 | 从真机拉 `Documents/SXJZIT_Cache/Logs/log_*.json`，按**固定证据链**判定「收藏更新深链归因」A/B 双路径，出 PASS/FAIL/N-A | `python3`、`xcrun devicectl`（`--dir` 模式完全离线） | 报告 + `build/verify/forensics_pull/` | **高**（`--selftest` 内置合成样本自检，`--dir` 离线复算，`--last-minutes N` / `--all` 时间窗） |
| `bookmark_deeplink_selftest.py` | python3 / 644 | **无人值守**跑通「哨兵基线 → 真实更新检测（通知+入盒）→ 模拟系统通知点击 + 消息中心条目点击 → 回执落盘」，再复用 `deeplink_forensics` 判定 | `python3`、`xcodebuild`、`xcrun devicectl`、**设备需可访问学校 API** | `build/verify/bookmark_deeplink_selftest_marker.json`、`…_report.txt`；DerivedData 落 `build/DerivedData-selftest` | **中**（`--skip-build` 快路径、`--timeout N`；回执 `finishedAt` 新鲜度校验防上一轮残留；**锁屏会静默失败**） |
| `display_baretext_audit.py` | python3 / 644 | **裸文本语句级审计**：找"文本构造但附近无 `display*` 排版链"的位置（显示设置无法全局覆盖的根因类别） | `python3` | 汇总报告 / `--list` 逐处清单 / `--baseline` 与基线比对。**`display_baretext_baseline.json` 缺失** | **高**（只读；`--baseline` 因缺基线文件而退化） |
| `display_coverage_guard.py` | python3 / 644 | **构建期四规则护栏**（排版链 / 弹出层 / UIKit 直连 / 裸文本零容忍），是 Run Script 阶段的唯一内容 | `python3`（**import 同目录 `display_baretext_audit`**） | stdout 通过/违规清单；退出码 0/1 | **高**（本机实跑 exit 0；只读，支持 `SRCROOT` 环境变量） |
| `generate_alternate_icons.py` | python3 / 644 | 以主图标为基准按 HSV 像素分类重着色，生成 4 套备选图标 `AppIconAlt1~4`（星夜/晨曦/极简/金典） | `python3` + **numpy + Pillow**（本机 3.14.7 已装 12.3.0 / 2.5.3） | 写入 `DesignCode/Assets.xcassets/**appiconset` | **高**（参数化可重跑；`--preview /tmp/out` 预览） |

### H.7.1 `device_display_verify.sh` 细节

```
用法：
  Scripts/device_display_verify.sh                 # 全流程（默认观察窗 30s）
  Scripts/device_display_verify.sh --wait 90       # 观察窗 90s（现场切换字体取证）
  Scripts/device_display_verify.sh --skip-install  # 不构建安装，仅启动+取证
  Scripts/device_display_verify.sh --no-launch     # 仅拉取日志并校验
  Scripts/device_display_verify.sh --tests         # 追加真机全量单元测试（-only-testing:DesignCodeTests）
  Scripts/device_display_verify.sh --install-only  # 只构建+安装，两阶段流程
  Scripts/device_display_verify.sh --dry-run       # 只做设备预检与计划打印
  Scripts/device_display_verify.sh --device <UDID> # 覆盖设备
  -h|--help                                        # 打印文件头 2..30 行
```

- 关键变量：`DEVICE_ID=00008110-000411A40EC1401E`（可 `--device` 覆盖）、`BUNDLE_ID=${BUNDLE_ID:-com.qinchao}`、`DERIVED=$ROOT/qin/build/device-dd`、`APP_PATH=$DERIVED/Build/Products/Debug-iphoneos/DesignCode.app`、`VERIFY_DIR=$ROOT/qin/build/verify`。
- 判定口径（4 项）：**[硬性]** 存在「系统渲染面字体接管已刷新」；**[硬性]** `display` 域 `ERROR/FATAL = 0`；**[信息]** 观察窗内发生过设置切换（`font_size_tier` / `font_family` / `typography_revision` 等 reason）；**[信息]** 打开过 WebView → 存在「WebView 排版已实时重注入」。
- 退出码：`2`=设备预检失败、`1`=构建/安装/启动/拉日志/硬性校验失败、`0`=通过（信息项未触发仍为 0，但会打印 ⚠️）。
- **最新实跑证据**：`build/verify/device_display_verify_20260930_155559.md` — 4 项硬性全绿（接管刷新 7 条、目标家族 `STSongti-SC-Bold`、WebView 重注入 7 条、display 域异常 0 条），报告注明"其它域异常 10 条（信息性，不参与判定）"。

### H.7.2 `org_module_acceptance.sh` 细节

```
用法：
  Scripts/org_module_acceptance.sh                  # 全流程（默认观察窗 180s）
  Scripts/org_module_acceptance.sh --guided         # 逐步模式：每步回车确认
  Scripts/org_module_acceptance.sh --bridge-selftest # 自动看图桥自测（窗口缩至 45s）
  Scripts/org_module_acceptance.sh --skip-install   # 不构建安装
  Scripts/org_module_acceptance.sh --report-only    # 仅拉日志断言（考古模式）
  Scripts/org_module_acceptance.sh --only A1,B1,C1  # 只跑指定用例
  Scripts/org_module_acceptance.sh --org tw         # 关注用例目标机构 siteKey（默认 kyc 科研处）
  Scripts/org_module_acceptance.sh --wait 300       # 观察窗秒数
  Scripts/org_module_acceptance.sh --list           # 列出用例后退出
  Scripts/org_module_acceptance.sh --install-only
  Scripts/org_module_acceptance.sh --dry-run
  Scripts/org_module_acceptance.sh --device <UDID>
```

- **用例清单共 13 条**（脚本内 `CASES` heredoc，`grep -c '^[A-D][0-9]|'` = 13）：`A1` 正文图片→全屏看图器、`A2` 缩略图条→看图器、`A3` 正文链接→App 内浏览器、`A4` 视频零预载、`B1` 进入文章→标记已读、`B2` 阅读时长角标、`C1` 关注→基线播种、`C2` 取关、`C3` 静默检测→入盒、`C4` 系统通知→冷启动深链、`C5` 消息中心条目→深链、`D0` 模块无 ERROR、`D1` 显示设置联动。
- **另有 5 条代码静态契约** `S1`~`S5`（看图桥注册/卸载成对、`.linkActivated` 链接拦截、`preload=none` 视频零预载、第五通道单轮全局上限+并集写回、`OrgArticle.readKey` 已读键唯一口径）由脚本内 `add(False, "S1", …)` 断言补入 → **报告共 18 行**。
  > 脚本文件头注释写"覆盖阶段三设施接入的 12 条验收用例"、"S1~S4 代码静态契约"，与实际 13 条 + S1~S5 **不一致**（注释滞后，非功能缺陷）。
- **抗日志窗口设计（重要运维知识）**：App 日志**单日上限 1000 条**，高活跃约 3 分钟写满；脚本除日志外还拉取两份**持久化铁证**并按优先级回落：
  1. `Library/Preferences/com.qinchao.plist` → `orgFollowedOrgs` / `orgFollowBaselineEstablished` / `notifiedOrgArticleIds`
  2. `Documents/MessageCenter/messageCenterEvents.json` → `kind=orgUpdate` 条目（含 `isRead` ⇒ 用户点击过）
  判定优先级：**日志命中优先（含时间戳），否则回落持久化旁证并在报告中标注「持久化旁证」**。
- 其他已知约束（脚本头部"勿改"清单）：日志文件**最新在前**落盘 → 断言前必须按时间升序排序；bash 3.2 下 `$VAR` 紧接全角字符必须写 `${VAR}`。
- **最新实跑证据**：`build/verify/org_acceptance_20260930_165016.md`（考古模式）— 硬性 A1/B1/C1/D0 全绿；`C3/C4/C5` 靠持久化旁证通过（关注清单 2 个、`orgFollowBaselineEstablished=true`、去重集 41 条、`orgUpdate` 条目 1 条已读）；`A2/A3/A4/C2` 为「⬜ 未触发」（非缺陷，属条件用例）。

### H.7.3 `push_all.sh` 策略要点

- 远端集合硬编码 `REMOTES=(origin gitee cnb)`，白名单校验 `ALLOWED=" origin gitee cnb "`。
- 逐远端顺序：**预检（`git ls-remote`）→ 推送分支 → 推送 tags**；**任一远端失败不中断其余**，结束时打印 `FAILED[]` 汇总并给出凭据修复提示。
- **永不 force push**；分支显式写 `git push "$R" "HEAD:refs/heads/$BRANCH"` 防误推（避免 `push.default` 行为差异）。
- 无参数 = 推送当前分支 + **全部 tags**；`--no-tags` 关闭；`--only <remote>` 单远端重试；`--branch <name>` 覆盖分支。
- 退出码：`0`=全部成功 ｜ `1`=存在失败（逐远端列出）｜ `2`=用法或环境错误（非 Git 仓库 / detached HEAD 未指定 `--branch` / 未知远端）。
- CNB 令牌失效时的官方修复（脚本尾部原样提示）：

  ```bash
  printf "protocol=https\nhost=cnb.cool\nusername=cnb\npassword=<新令牌>\n\n" | git credential-osxkeychain store
  ```

### H.7.4 `remote_sync_report.sh` 要点

- 判定：三远端 `git ls-remote <r> refs/heads/main` 的 SHA **全部等于**本地 `git rev-parse HEAD` **且** `push_all.sh --dry-run` 退出码为 0 → `PASS`，否则 `FAIL`。
- 采集项：`git --version`、分支/HEAD 全短哈希、`git status -sb` 首行、最近提交、`git remote -v` 表格、`credential.helper`、`~/.ssh/id_ed25519_gitee` 存在性、tag 数、各远端 `ls-remote` 前 6 行。
- 输出：`qin/docs/remote-sync/remote_sync_verification_<YYYYMMDD>.md`（**同日重跑覆盖**）；`--out <file>` 自定义；`--push` 追加一次实推并纳入证据。
- 退出码：`0`=PASS ｜ `1`=FAIL ｜ `2`=用法或环境错误。
- **现存报告**：`qin/docs/remote-sync/remote_sync_verification_20260929.md`，L6 判定 **✅ PASS**。

### H.7.5 两个 Python 深链脚本的退出码语义

| 脚本 | 退出码 |
|---|---|
| `deeplink_forensics.py` | `0`=通过（至少一条 PASS 且无 FAIL/WARN）｜`1`=存在 FAIL/WARN｜`2`=窗口内无可判定事件｜`3`=执行错误 |
| `bookmark_deeplink_selftest.py` | `0`=触发成功且 A/B 双路径 PASS｜`1`=存在 FAIL/回执失败｜`2`=触发成功但证据链不全｜`3`=构建/安装/启动失败 |

`deeplink_forensics.py` 前置条件：**真机「日志设置」需打开 DEBUG 记录**（kind 分支日志为 debug 级，否则 A/B 项无法取证）；默认分析最近 180 分钟（`DEFAULT_WINDOW_MIN = 180.0`），证据链相邻环节最大间隔 `LINK_WINDOW_SEC = 5.0`；默认拉取目标 `qin/build/verify/forensics_pull`；日期换算用 `REF_EPOCH_OFFSET = 978307200.0`（Apple 2001 参考秒 → Unix 秒）。
`bookmark_deeplink_selftest.py` 依赖 App 内启动参数 `-uiTestBookmarkDeepLink`（**必须带 `--` 分隔符**）；DerivedData 专用 `qin/build/DerivedData-selftest`；单文件 `devicectl copy from` 的 `--destination` **必须是文件路径**（给目录会报 `Is a directory`）。

---

## H.8 真机构建与测试的**确切命令行**

### H.8.1 设备约定

| 项 | 值 |
|---|---|
| 设备名 | **秦超的iPhone** |
| UDID | **`00008110-000411A40EC1401E`** |
| 机型 | **iPhone 13 Pro Max（`iPhone14,3`）**，physical |
| 目的地域串 | `platform=iOS,id=00008110-000411A40EC1401E` |
| 通用真机串（不绑设备） | `generic/platform=iOS` |
| Bundle ID | `com.qinchao`（测试 bundle `com.qinchao.tests`） |
| 约定 | **不使用模拟器**做验收/调试 |
| **本次核查时状态** | `xcrun devicectl list devices` → `State = unavailable`（未连接或未解锁）。**所有真机脚本会在设备预检处 `exit 1`**，需先插线解锁 |

### H.8.2 可直接复制执行的命令（全部在仓库根或 `qin/` 下执行）

```bash
# ── 0) 环境自检 ────────────────────────────────────────────────
xcodebuild -version                 # 期望：Xcode 27.0 / Build 27A266a
sw_vers                             # 期望：macOS 27.0 / 26A428
xcrun devicectl --version           # 期望：642.16
python3 --version                   # 期望：3.14.7（护栏脚本依赖）
xcodebuild -project /Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode.xcodeproj -list
xcrun devicectl list devices        # 必须看到 UDID + connected

# ── 1) 构建期护栏单跑（不需要设备、不需要签名，秒级）────────────
cd /Users/qinchao/Downloads/designcode-swiftui/qin
python3 Scripts/display_coverage_guard.py     # 期望：✅ … 0 缺口；退出码 0
python3 Scripts/display_baretext_audit.py     # 裸文本汇总（可选，--list 逐处清单）

# ── 2) 仅验证编译通过（关闭签名，不碰设备，CI 友好）────────────
cd /Users/qinchao/Downloads/designcode-swiftui/qin
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/device-dd \
  CODE_SIGNING_ALLOWED=NO build

# ── 3) 真机构建（自动签名，必须 -allowProvisioningUpdates）──────
cd /Users/qinchao/Downloads/designcode-swiftui/qin
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
  -configuration Debug \
  -destination 'platform=iOS,id=00008110-000411A40EC1401E' \
  -derivedDataPath build/device-dd \
  -allowProvisioningUpdates build
# 产物：build/device-dd/Build/Products/Debug-iphoneos/DesignCode.app

# ── 4) 安装 / 启动 / 拉日志（devicectl）─────────────────────────
cd /Users/qinchao/Downloads/designcode-swiftui
xcrun devicectl device install app \
  --device 00008110-000411A40EC1401E \
  qin/build/device-dd/Build/Products/Debug-iphoneos/DesignCode.app

xcrun devicectl device process launch \
  --device 00008110-000411A40EC1401E --terminate-existing com.qinchao

# 带启动参数（注意：必须有 `--` 分隔符；仅 DEBUG 构建生效；锁屏会静默不生效）
xcrun devicectl device process launch \
  --device 00008110-000411A40EC1401E --terminate-existing com.qinchao -- -uiTestOpenLogs

# 带环境变量（devicectl 传环境变量最稳的写法）
xcrun devicectl device process launch \
  --device 00008110-000411A40EC1401E --terminate-existing \
  -e '{"SJZ_ORG_IMAGE_BRIDGE_SELFTEST":"1"}' com.qinchao

# 拉取 App 沙盒日志（日志页排障核心手段）
xcrun devicectl device copy from \
  --device 00008110-000411A40EC1401E \
  --domain-type appDataContainer --domain-identifier com.qinchao \
  --source "Documents/SXJZIT_Cache/Logs" \
  --destination qin/build/verify/manual-pull-$(date +%Y%m%d_%H%M%S)

# 拉取持久化旁证（UserDefaults，用于 org 验收/基线核验）
xcrun devicectl device copy from \
  --device 00008110-000411A40EC1401E \
  --domain-type appDataContainer --domain-identifier com.qinchao \
  --source "Library/Preferences/com.qinchao.plist" \
  --destination qin/build/verify/manual-pull/com.qinchao.plist

# ── 5) 真机跑全量单元测试（237 例；⚠️ 含 3 条在线用例）─────────
cd /Users/qinchao/Downloads/designcode-swiftui/qin
xcodebuild test -project DesignCode.xcodeproj -scheme DesignCode \
  -destination 'platform=iOS,id=00008110-000411A40EC1401E' \
  -derivedDataPath build/device-dd \
  -allowProvisioningUpdates \
  -only-testing:DesignCodeTests \
  | tee build/verify/device_tests_$(date +%Y%m%d_%H%M%S).log | tail -40
# 判定关键字：TEST SUCCEEDED / "Test Suite 'DesignCodeTests.xctest' passed" / "Executed N tests, with 0 failures"

# ── 6) 跳过 3 条在线用例的稳定跑法 ──────────────────────────────
xcodebuild test -project DesignCode.xcodeproj -scheme DesignCode \
  -destination 'platform=iOS,id=00008110-000411A40EC1401E' \
  -derivedDataPath build/device-dd -allowProvisioningUpdates \
  -skip-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIHome2Decoding \
  -skip-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIArticlesDecoding \
  -skip-testing:DesignCodeTests/NetworkServiceDTOTests/testRealAPIArticleDetailDecoding

# ── 7) 四条一键闭环脚本（推荐日常使用）─────────────────────────
cd /Users/qinchao/Downloads/designcode-swiftui
bash qin/Scripts/device_display_verify.sh --dry-run          # 先看计划
bash qin/Scripts/device_display_verify.sh --wait 90          # 显示覆盖全流程 + 现场取证
bash qin/Scripts/device_display_verify.sh --skip-install --tests   # 复用已装构建 + 追加全量单测
bash qin/Scripts/org_module_acceptance.sh --list             # 列 13 条用例
bash qin/Scripts/org_module_acceptance.sh --bridge-selftest   # 机构模块自动验收（窗口 45s）
bash qin/Scripts/org_module_acceptance.sh --report-only       # 考古：只拉日志判定
python3 qin/Scripts/deeplink_forensics.py --selftest          # 深链判定逻辑离线自检
python3 qin/Scripts/deeplink_forensics.py --last-minutes 600  # 真机拉取 + 分析
python3 qin/Scripts/bookmark_deeplink_selftest.py --skip-build # 收藏深链无人值守验证

# ── 8) 备份与同步 ─────────────────────────────────────────────
cd /Users/qinchao/Downloads/designcode-swiftui
bash qin/Scripts/push_all.sh --dry-run          # 三远端预检（不推送）
bash qin/Scripts/push_all.sh                    # 推送当前分支 + 全部 tags 到 origin/gitee/cnb
bash qin/Scripts/push_all.sh --only cnb          # 单远端重试
bash qin/Scripts/remote_sync_report.sh           # 生成三远端一致性验证报告
```

**可直接复制的"全链冒烟"最小串**（从零到有证据，~3 分钟）：

> ⚠️ 第一行的 `grep` 只校验 UDID **存在**，不校验 `connected`；**本次核查时该设备状态为 `unavailable`**，若真机未连接/未解锁，此串会在第 6 步 `install` 处失败——**请先插线解锁，并把第一行换成下面这行**：
> ```bash
> xcrun devicectl list devices | grep 00008110-000411A40EC1401E | grep -q connected
> ```

```bash
cd /Users/qinchao/Downloads/designcode-swiftui/qin \
 && xcrun devicectl list devices | grep 00008110-000411A40EC1401E \
 && python3 Scripts/display_coverage_guard.py \
 && xcodebuild -project DesignCode.xcodeproj -scheme DesignCode -configuration Debug \
      -destination 'platform=iOS,id=00008110-000411A40EC1401E' \
      -derivedDataPath build/device-dd -allowProvisioningUpdates build \
      > build/verify/smoke_build.log 2>&1 \
 && grep -q "BUILD SUCCEEDED" build/verify/smoke_build.log \
 && grep -q "显示设置覆盖护栏通过" build/verify/smoke_build.log \
 && xcrun devicectl device install app --device 00008110-000411A40EC1401E \
      build/device-dd/Build/Products/Debug-iphoneos/DesignCode.app \
 && echo "✅ 护栏 + 构建 + 安装 全通"
```

**踩坑清单（构建/测试命令相关，全部有据）：**

1. **CLI 下自动签名必须带 `-allowProvisioningUpdates`**，否则报 `No profiles for 'com.qinchao'` 且构建即失败（四个脚本 + code-wiki 05 一致记载）。首次或描述文件过期时，用 Xcode GUI 打开工程跑一次可刷新。
2. **`devicectl process launch` 传启动参数必须有 `--` 分隔符**（`… com.qinchao -- -uiTestOpenLogs`），且**仅 DEBUG 构建生效**；**锁屏时启动会静默不生效**（不报错但 App 不响应参数）→ 重试等待解锁。
3. **`devicectl copy from` 拉目录 vs 拉单文件**：目录 → `--destination` 给目录；单文件 → `--destination` **必须是文件路径**（给目录报 `Is a directory`）。
4. **测试 target 无 Resources 阶段**，`GENERATE_INFOPLIST_FILE = YES`，所以测试 bundle 没有可放测试资源的宿主；需要 fixture 只能内联字符串（现有 6 个文件全部如此）。
5. **`-derivedDataPath` 决定产物路径**：`build/device-dd/Build/Products/Debug-iphoneos/DesignCode.app`。不给 `-derivedDataPath` 会落到 `~/Library/Developer/Xcode/DerivedData/DesignCode-<hash>/`（历史构建日志里存在该路径，例如 `DesignCode-dwzkqjjscvdrydccbhrbssszssxj`）。
6. **不指定 `-configuration` 时默认 `Release`**（三个 config list 的 `defaultConfigurationName = Release`）→ 想要 Debug 必须显式写。
7. **GUI 首次运行会依次弹「启动页(1s) → 隐私同意弹窗 → 数据同步（首页 0.5s 后触发）」**，未点同意前不会注册微信、不会发起网络请求（微信红线①）。

---

## H.9 三远端备份配置

### H.9.1 `git remote -v`（**在仓库根实跑**）

```
cnb	    https://cnb.cool/43322/Garden-iOS.git (fetch)
cnb	    https://cnb.cool/43322/Garden-iOS.git (push)
gitee	git@gitee.com:oai/garden-ios.git (fetch)
gitee	git@gitee.com:oai/garden-ios.git (push)
origin	https://github.com/kkkh/Garden-iOS.git (fetch)
origin	https://github.com/kkkh/Garden-iOS.git (push)
```

| remote | 平台 | URL | 协议/凭据 |
|---|---|---|---|
| `origin` | GitHub（私有仓 `kkkh/Garden-iOS`） | `https://github.com/kkkh/Garden-iOS.git` | HTTPS + macOS Keychain 凭据助手 |
| `gitee` | Gitee（镜像 `oai/garden-ios`） | `git@gitee.com:oai/garden-ios.git` | **SSH**，密钥 `~/.ssh/id_ed25519_gitee` |
| `cnb` | 腾讯 CNB 云原生构建（`43322/Garden-iOS`） | `https://cnb.cool/43322/Garden-iOS.git` | HTTPS + 个人访问令牌，**用户名固定 `cnb`**，凭据存 macOS Keychain |

- 当前分支 **`main`**，与 `origin/main` 同步中（`git status -sb` → `## main...origin/main`）。
- 最近提交：`904d75f 2026-09-30 test(org-module): 验收脚本抗日志窗口（状态型持久化旁证）+ 探针采样时机修正`。
- tags：**1 个（`v1.0`）**。
- 历史备份目录（**保留在磁盘、不入库，`.gitignore` 排除了 `DesignCode_backup_*/`**）：根 `DesignCode_backup_20260926_display/`、`DesignCode_backup_20260926_fonts/`，`qin/DesignCode_backup_20260922/`、`qin/DesignCode_backup_20260926_netmon/`。**不要在其中改代码或编译**。

### H.9.2 `push_all.sh` 策略摘要

1. **目标集合固定三远端**：`REMOTES=(origin gitee cnb)`，`--only` 走白名单校验。
2. **逐远端三段式**：可达性/认证预检（`git ls-remote`）→ 推送分支 → 推送 tags。**失败隔离**：单远端失败只记入 `FAILED[]`，继续下一个。
3. **永不 force push**；`git push "$R" "HEAD:refs/heads/$BRANCH"` 显式 refspec（防 `push.default` 差异与误推）。
4. 默认推**当前分支 + 全部 tags**；`--no-tags`、`--branch <name>` 可覆盖；detached HEAD 未指定 `--branch` 时 `exit 2`。
5. 成功路径结束时打印**远端一致性核验**（逐远端 `git ls-remote` 的 8 位短哈希）。
6. `--dry-run` 会真做预检（能暴露凭据/网络问题）但不推送 —— 因此可安全作为 `remote_sync_report.sh` 的判定输入。
7. 退出码 `0/1/2`；失败时打印 gitee SSH 与 cnb Keychain 的具体修复提示（含 `git credential-osxkeychain store` 一行命令）。

---

## H.10 运行环境要求、`.gitignore`、构建产物目录

### H.10.1 环境要求（本机实测值 + 项目约束）

| 项 | 要求 / 实测 | 依据 |
|---|---|---|
| macOS | **27.0（26A428）** 实测；实质要求＝能装 Xcode 27 的系统 | `sw_vers` |
| Xcode | **27.0（27A266a）** 实测；**必须 ≥ 27**（因为 target 部署目标 26.0 需要 iOS 26+ SDK 才能解析，工程链接 `AppIntents.framework`） | `xcodebuild -version` |
| iOS SDK | **iPhoneOS27.0.sdk**（构建日志实证） | `build/verify/org_build_20260930_163940.log` L24；`build/verify/device_build_20260930_155559.log` L24/L38 |
| 部署目标 | **iOS 26.0**（生效值）；卡在 project 层的 `13.0` 是死设置 | H.1.4 |
| 真机 | **必需**。约定 iPhone 13 Pro Max「秦超的iPhone」UDID `00008110-000411A40EC1401E`，运行 **iOS 27.0**（`[未验证]`，未从设备取 `ProductVersion`） | 设备约定 |
| 签名 | Apple ID **自动签名**，`DEVELOPMENT_TEAM = F2JL9GNLCC`；CLI 必须 `-allowProvisioningUpdates` | pbxproj + 脚本 |
| 工具链 | `xcrun devicectl` ≥ 642.16（脚本全程用 `devicectl device install/process launch/copy from`，**未用已废弃的 `ios-deploy`/`instruments`**）；`python3` ≥ 3（系统 Python 即可，护栏脚本无三方依赖）；`numpy` + `Pillow` 仅 `generate_alternate_icons.py` 需要 | 脚本 `grep` |
| 网络 | 需可达 `gwqietap.sxjzit.edu.cn`（API）、`www.sxjzit.edu.cn` / `www2.sxjzit.edu.cn:8082`（官网与图片 CDN）、`www.43322.cn`（公告/协议源）、`jl.43322.cn`（微信 UL/AASA 目录）；中文字体（宋/楷/圆/行楷/隶变/魏碑）**按需下载还需可达 Apple 字体服务器** | code-wiki 05 §5.1 + `Info.plist` ATS + pbxproj `WECHAT_UL_HOST` |
| 三方依赖 | **几乎为零**：无 CocoaPods（无 `Podfile`/`Podfile.lock`）、无 Carthage（无 `Cartfile`）、无 SwiftPM 依赖（无 `Package.swift`；`project.xcworkspace/xcshareddata/swiftpm/configuration/` 是**空目录**，全仓库无 `Package.resolved`）。唯一外部二进制＝`Frameworks/WechatOpenSDK.xcframework`（静态库，随仓库入库 14 MB） | `ls` / `find` 核对 |
| CI/CD | **完全没有**（无 `.github/workflows`、`.gitlab-ci.yml`、`Jenkinsfile`、`fastlane/`、`.travis.yml`） | `glob` |
| 文档口径提醒 | 根 `README.md` L67「Xcode 15+ / iOS 17+」、L73「Deployment Target: iOS 17.0」、L89「当前 54 用例全绿」**全部过期**，不可信 | H.1.4 / H.6.5 |

### H.10.2 `.gitignore`（仓库根，24 行，唯一一份——`qin/` 下无独立 `.gitignore`）

```gitignore
# ---- macOS 系统文件 ----
.DS_Store
.AppleDouble

# ---- Xcode 用户态与构建产物 ----
xcuserdata/
qin/build/
qin/.build/
DerivedData/
*.xcresult

# ---- 历史备份快照（保留在磁盘、不入库；此后以 Git 作为回滚源）----
DesignCode_backup_*/

# ---- 密钥/凭据（严禁入库；微信 AppSecret 等仅存本机）----
.secrets/
qin/.secrets/
*appsecret*

# ---- Python 工具产物（Scripts/ 下取证与护栏脚本的运行残留）----
__pycache__/
*.pyc
```

**运维含义：**

- `qin/build/` **整体**被忽略 → 所有 `verify/` 报告、`device-dd/` DerivedData、`DerivedData-selftest/`、拉取的设备日志都**不进版本库**。这意味着**证据文件不会随仓库传播**，跨机器/跨人复现必须重跑脚本。
- `xcuserdata/` 被忽略 → **scheme 不进仓库**（H.1.8 的可复现性缺口）。
- `.secrets/`、`qin/.secrets/`、`*appsecret*` 被忽略 → `qin/.secrets/wechat-credentials.env`（738 B，`-rw-r--r--`）**仅存本机**，内含键名（值未读取、不写入本文档）：`WECHAT_APPID`、`WECHAT_APPSECRET`、`WECHAT_UNIVERSAL_LINK`、`WECHAT_BUNDLE_ID`、`DEVELOPMENT_TEAM`、`APP_SITE`。**注意：`grep` 全 `Scripts/` 未发现任何脚本引用该文件**——它纯粹是人工/服务端换 token 用，App 构建与测试链路**不读取它**（即：删掉它不影响构建）。
- **未被忽略的敏感面**：`Info.plist` 与 pbxproj 里的 `WECHAT_APPID = wx8e60d3a37d3cff47`、`WECHAT_UL_HOST = jl.43322.cn` 是**明文入库**的（AppID/UL 本属公开信息，AppSecret 才是机密，处置正确）。
- **未忽略但也未入库的可疑物**：`qin/DesignCode/.DS_Store`（12 KB）被 `.gitignore` 的 `.DS_Store` 覆盖；`qin/CODE_WIKI_副本.md`（124 KB）、`qin/preview.gif`（23.5 MB）、`qin/FIX_PLAN_CACHE_MODE.md`（42 KB）等历史文档在库内。

### H.10.3 `qin/build/` 各子目录用途（`du -sh` 实测）

| 子目录/文件 | 大小 | 用途（**依据脚本变量或内容实读**） |
|---|---|---|
| `device-dd/` | **421 MB** | **真机脚本专用 DerivedData**。`device_display_verify.sh` 与 `org_module_acceptance.sh` 的 `DERIVED="$ROOT/qin/build/device-dd"`；产物 `Build/Products/Debug-iphoneos/DesignCode.app`；含 `TestResults/`（`--tests` 跑出的 `.xcresult`）、`Index.noindex/`、`Logs/`、`ModuleCache.noindex/`、`SDKExplicitPrecompiledModules/`、`SDKStatCaches.noindex/`、`CompilationCache.noindex/`、`info.plist` |
| `DerivedData-selftest/` | **370 MB** | **`bookmark_deeplink_selftest.py` 专用 DerivedData**（`DD_PATH`），与真机脚本隔离，避免互相踢掉增量缓存。**无 `TestResults/`** |
| `verify/` | **242 MB** / **161 项** | **所有证据与报告的集中落盘地**：`device_build_<ts>.log`、`org_build_<ts>.log`、`device_tests_<ts>.log`、`*_test.log`（历史单测日志）、`device_display_verify_<ts>.md`、`org_acceptance_<ts>.md`、`org_acceptance_ref_<ts>.json`、`device-logs-<ts>/`、`org-acceptance-logs-<ts>/`、`forensics_pull/`、`selftest_marker/`、`bookmark_deeplink_selftest_*.{json,txt}`、`*.xcarchive`/`export`（如手工导出） |
| `msgcenter/` | **313 MB** | 早期「消息中心」开发期的 DerivedData 快照（含 `TestResults/`、`Index.noindex/`）；**当前脚本均不引用** → 可安全删除回收 |
| `SDKExplicitPrecompiledModules/` | 101 MB | 工程根级 DerivedData 残留（Xcode 显式模块预编译缓存），非脚本创建 |
| `SDKStatCaches.noindex/` | 1.5 MB | SDK stat 缓存 |
| `Build/` | 12 MB | 旧式 `xcodebuild` 产物目录（仅 `Intermediates.noindex/` + `Products/`） |
| `Logs/` | 68 KB | 旧式构建/测试日志（`Build/`、`Launch/`、`Localization/`、`Package/`、`Test/`） |
| `ModuleCache.noindex/` | 9.9 MB | Clang 模块缓存 |
| `CompilationCache.noindex/` | 28 KB | 编译缓存 |
| `tools/font_convert.py` | 8 KB | 字体转换工具（历史遗留，非脚本目录内 —— 注意 `qin/Scripts/` 才是脚本区） |
| `info.plist` | 400 B | **旧 DerivedData 根标记**。实读内容：`LastAccessedDate = 2026-08-05T05:09:57Z`，`WorkspacePath = /Users/qinchao/.trae-cn/worktrees/designcode-swiftui/fix-liquid-menu-freeze-0ppQuz/DesignCode.xcodeproj` → 证明该目录曾被当作 DerivedData 根，且来自 **.trae 工作树**（不是当前工作树） |
| `font_convert_report.txt` | 0 B | 空文件，字体转换残留 |
| `.DS_Store` | 8 KB | macOS 噪音 |

**清理建议（释放 ~800 MB，全部被 gitignore，删除安全）：**

```bash
cd /Users/qinchao/Downloads/designcode-swiftui/qin/build
rm -rf msgcenter Build Logs ModuleCache.noindex CompilationCache.noindex SDKExplicitPrecompiledModules SDKStatCaches.noindex
# 保留：device-dd/（增量构建快）、DerivedData-selftest/、verify/（证据）
# 注意：device-dd 与 DerivedData-selftest 各自 400 MB 上下，如需彻底回收也可删除（下次构建会重建，代价是首次全量编译）
```

（以上 `rm -rf` 为**建议命令，本次未执行**。）

---

## H.11 「照着就能跑起来并验证」标准作业流程（SOP）

```text
前置：macOS + Xcode 27 + 一台 iOS 26+ iPhone + USB 线 + Apple ID 自动签名可用
```

| 步 | 动作 | 期望结果 / 判定 | 耗时 |
|---|---|---|---|
| 1 | `git clone` 后 `cd designcode-swiftui`；确认 `git remote -v` 有三个远端 | 三行 ×2（fetch/push） | — |
| 2 | 打开 `qin/DesignCode.xcodeproj`（GUI 一次），确认 scheme `DesignCode` 可用；如提示升级工程设置，**不要**改部署目标 | scheme 列表出现 `DesignCode` | 1 min |
| 3 | 插线、解锁、信任本机 → `xcrun devicectl list devices \| grep 00008110-000411A40EC1401E` | 行末 `connected` | 1 min |
| 4 | `cd qin && python3 Scripts/display_coverage_guard.py` | `✅ 显示设置覆盖护栏通过：… 0 缺口`，`$? = 0` | 5 s |
| 5 | `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | `** BUILD SUCCEEDED **`（不碰签名/设备，先排语法错） | 2-5 min |
| 6 | `xcodebuild … -destination 'platform=iOS,id=<UDID>' -derivedDataPath build/device-dd -allowProvisioningUpdates build` | `** BUILD SUCCEEDED **`；日志里同时出现 `显示设置覆盖护栏通过` | 2-6 min |
| 7 | `xcrun devicectl device install app --device <UDID> build/device-dd/Build/Products/Debug-iphoneos/DesignCode.app` | `App installed` | 30 s |
| 8 | `xcrun devicectl device process launch --device <UDID> --terminate-existing com.qinchao` | 手机亮起 → 启动页 1s → **隐私同意弹窗** → 数据同步 | 30 s |
| 9 | 在手机上点「同意」→ 首页 0.5s 后开始拉数据 | 首页有 banner / 校园统计数据；「我的 → 应用日志」可见 `netmon`、`display` 域日志 | 1 min |
| 10 | `xcodebuild test … -only-testing:DesignCodeTests -allowProvisioningUpdates` | `Test Suite 'All tests' passed` + `Executed 237 tests, with 0 failures`（**首次跑 237，务必记录实际数字**） | 3-5 min |
| 11 | `bash qin/Scripts/device_display_verify.sh --skip-install --wait 60` | 报告 `qin/build/verify/device_display_verify_<ts>.md` 4 项硬性 ✅ | 3 min |
| 12 | `bash qin/Scripts/org_module_acceptance.sh --skip-install --bridge-selftest` | 报告 `org_acceptance_<ts>.md`：A1/B1/C1/D0 硬性 ✅ | 3 min |
| 13 | `bash qin/Scripts/push_all.sh --dry-run && bash qin/Scripts/remote_sync_report.sh` | 三远端预检通过；报告判定 **PASS** | 1 min |

---

## H.12 风险、不一致与待验证清单

### H.12.1 运维级风险（按影响排序）

| 级 | 事项 | 位置 / 证据 | 影响 |
|---|---|---|---|
| 高 | **`CODE_SIGN_ENTITLEMENTS` 未设置** → Associated Domains 从未生效 | `grep -n CODE_SIGN_ENTITLEMENTS` 0 命中；`DesignCode.entitlements` 只有 group 引用 | 微信 UL 回跳/回执不可达（分享发送本身可用）。**根因是免费个人团队无该能力**，非疏漏；升级付费账号后需在 App target Debug/Release **两处**补 `CODE_SIGN_ENTITLEMENTS` |
| 高 | 部署目标 **project 13.0 / target 26.0** 冲突 | pbxproj L541/L595 vs L616/L664/L708/L724 | GUI 工程级"Minimum Deployments"误导；修法＝统一两处 |
| 高 | **3 条在线单测**绑定学校 CMS 存量数据 | `NetworkServiceDTOTests.swift` L396/443/466 | 断网/文章下架/栏目变更 → 全量测试变红，与代码质量无关；必须用 `-skip-testing:` 隔离 |
| 高 | **237 例尚无全量实跑记录**（最近 195/195，2026-09-29） | `build/verify/` 无 `Executed 237`、无 `OrgModuleTests` 字样 | 42 条新用例（含 `DisplaySettingsLogicTests` 23、`ArticleLongImageLogicTests` 25、`OrgModuleTests` 22）的真实通过状态未知 |
| 中 | **无共享 scheme** | `xcshareddata/` 不存在，仅 `xcuserdata/**/xcschemes`（被忽略） | 新克隆/CI 上 `-scheme DesignCode` 可能找不到 |
| 中 | **无任何 CI** | 无 workflows / fastlane / Jenkinsfile | 构建、测试、验收、备份全靠本机手工；护栏虽在构建期强制，但**没人构建就不会跑** |
| 中 | `Info.plist` **无 `UIBackgroundModes`** | `grep -c UIBackgroundModes` = 0 | 无后台刷新/静默推送；App 不在前台时"机构动态检测"不会发生，依赖用户主动打开（`NotificationManager` 30 分钟轮询仅在前台） |
| 中 | 版本号硬编码 `1.0` / `1` | `Info.plist` L27-L28、L42-L43；pbxproj 无 `MARKETING_VERSION` | 每次发版手改两处 plist，易漏 |
| 中 | `Scripts/display_baretext_baseline.json` **缺失** | `display_baretext_audit.py` L32 | `--baseline` 严格护栏模式退化；构建期护栏不受影响（不读该文件） |
| 中 | `-disable-sandbox` 编译旗标 | pbxproj L641/L689 | 非默认旗标，关闭 Swift 编译插件沙箱；上线前建议评估移除（既有文档亦列为中风险） |
| 中 | `build/msgcenter/` 等 **~800 MB 死缓存** | `du -sh qin/build/*` | 磁盘占用；无脚本引用，可删 |
| 低 | `INFOPLIST_KEY_CFBundleDisplayName = 园枢` **空转** | pbxproj L615/L663（app target `GENERATE_INFOPLIST_FILE` 未设） | 显示名实际由 `Info.plist` 的 `CFBundleDisplayName` 决定；两处并存易误改 |
| 低 | `AppIntents.framework` 落在 `Recovered References` 分组且**弱链接** | pbxproj L156、L261-L268 | 弱链接意味着 iOS 16 以下运行时会缺符号 —— 但部署目标 26.0 使其不成问题 |
| 低 | `org_module_acceptance.sh` 文件头注释滞后 | 头注"12 条用例 / S1~S4" vs 实际 13 条 + S1~S5 | 阅读误导，非功能缺陷 |
| 低 | 根 `README.md` 整体过期 | L52/L67/L73/L89（iOS 17+ / Xcode 15+ / 54 用例） | 新人生成错误预期 |
| 低 | `pbxproj` 备份文件**已入库且未被忽略** | `qin/DesignCode.xcodeproj/project.pbxproj.bak_20260922`（31,870 B）；`git ls-files` 确认已追踪，`git check-ignore -v` 退出码 1（未被忽略） | 历史快照进库；建议删除或加 ignore 规则 |
| 环境 | 自研日志 **单日上限 1000 条**（高活跃约 3 分钟写满） | `org_module_acceptance.sh` 头注 | 现场排障必须**操作完成后立即拉日志**，否则证据被挤出（两个验收脚本已用"持久化旁证"兜底） |

### H.12.2 本文档标注为「未验证」的点

1. **`DEVELOPMENT_TEAM = F2JL9GNLCC` 是免费「个人团队」** —— 来自 code-wiki 05 §5.3 的现场记录，CLI 无法取证团队类型；`[未验证]`。
2. **约定真机运行 iOS 27.0** —— 未从设备读取 `ProductVersion`（设备当前 `unavailable`）；`[未验证]`。
3. **`ExportOptions.plist` 的 archive/exportArchive 命令** —— 仓库内无对应脚本，命令按 plist 语义补全，未实际执行；`[未验证]`。
4. **新克隆仓库缺少共享 scheme 会导致 `-scheme DesignCode` 失败** —— 本机存在 `xcuserdata`，无法复现新克隆场景；`[未验证]`。
5. **`LoginManager`/字体下载依赖的 Apple 字体服务器可达性** —— 未做网络探测；`[未验证]`。
6. **App Store 提交是否需要自有 `PrivacyInfo.xcprivacy`** —— App 侧无该文件（仅微信 xcframework 自带一份）；`[未验证]`。
7. **237 例的实际通过结果** —— 无实跑记录；仅静态计数为 237（`grep -c 'func test'` 求和）。**本任务明确未运行设备测试**（设备 `unavailable`，且真机测试需解锁与签名交互）。
8. **`device_display_verify.sh --tests` 的 `-only-testing:DesignCodeTests` 是否覆盖全部 6 个文件** —— 依据 scheme 推断为是（测试 target 的 Sources 阶段含全部 6 文件），未实跑验证；`[未验证]`。
9. **`qin/build/` 删除操作** —— H.10.3 的 `rm -rf` 为建议，**本次未执行**（避免破坏其他 subagent 的取证环境）。

---

### 附：本文档所有事实的一键复核命令集

```bash
cd /Users/qinchao/Downloads/designcode-swiftui

# 工程
grep -n "isa = PBXNativeTarget" -A 12 qin/DesignCode.xcodeproj/project.pbxproj
grep -n "SDKROOT\|IPHONEOS_DEPLOYMENT_TARGET\|SWIFT_VERSION\|PRODUCT_BUNDLE_IDENTIFIER\|DEVELOPMENT_TEAM\|CODE_SIGN" qin/DesignCode.xcodeproj/project.pbxproj
grep -n "OTHER_SWIFT_FLAGS\|INFOPLIST_FILE\|CODE_SIGN_ENTITLEMENTS" qin/DesignCode.xcodeproj/project.pbxproj
grep -c "fileSystemSynchronized" qin/DesignCode.xcodeproj/project.pbxproj      # 期望 0
grep -n "PBXShellScriptBuildPhase" -A 20 qin/DesignCode.xcodeproj/project.pbxproj
xcodebuild -project qin/DesignCode.xcodeproj -list

# 配置
plutil -p qin/DesignCode/Info.plist
plutil -p qin/DesignCode/DesignCode.entitlements
plutil -p qin/ExportOptions.plist
plutil -p qin/Frameworks/WechatOpenSDK.xcframework/Info.plist
head -3 qin/Frameworks/WechatOpenSDK.xcframework/README.txt          # SDK2.0.8

# 测试
cd qin/DesignCodeTests && grep -c 'func test' *.swift | awk -F: '{s+=$2; print} END {print "TOTAL="s}'
grep -n "https://gwqietap" *.swift
grep -n "isRunningTests\|persistsToDisk" ../DesignCode/LogManager.swift

# 脚本
ls -la qin/Scripts/
cd qin && python3 Scripts/display_coverage_guard.py; echo "exit=$?"

# 运维
git remote -v && git rev-parse --abbrev-ref HEAD && git tag
cat .gitignore
du -sh qin/build/*/
grep -h "Executed [0-9]* tests, with 0 failures" qin/build/verify/device_tests_*.log | tail -3
```
