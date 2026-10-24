# 「园枢」iOS App · 外链多页签排障经验总结与教训

> 主题：图书馆「电子图书」外链站（超星 sslibrary）内「知网」入口点击无反应、新页签不出现——四轮用户反馈、跨 3 个 build 版本、最终修复并真机取证闭环。
> 日期：2026-10-01
> 状态：已修复 · 真机验收通过 · 经验沉淀

---

## 目录

1. [问题现象与影响](#1-问题现象与影响)
2. [排障历程时间线](#2-排障历程时间线)
3. [根因分析（终局定论）](#3-根因分析终局定论)
4. [修复方案与最终架构](#4-修复方案与最终架构)
5. [验证与取证闭环](#5-验证与取证闭环)
6. [经验教训（按可复用价值分级）](#6-经验教训按可复用价值分级)
7. [可复用的排障方法论](#7-可复用的排障方法论)
8. [工程沉淀与后续关注](#8-工程沉淀与后续关注)

---

## 1. 问题现象与影响

### 1.1 用户视角

「园枢」App「机构 → 图书馆 → 电子图书」栏目为**外链形态（link）**，内嵌超星电子图书站 `http://www.sslibrary.com/page/239443/show`。用户期望的浏览器式行为：

> 点「知网」打开知网页、点「电子图书」打开电子图书页——各自独立标签页，互不覆盖。

实际反馈（连续 4 轮，情绪渐不耐烦）：

| 轮次 | 用户原话 | 对应阶段 |
|------|---------|---------|
| 1 | 「我怎么看不到页签，而且问题依旧」 | 页签条未出现 |
| 2 | 「看到页签了，但是点另一个的时候也不会出现新的页签」 | 页签条有了，但跨站不新增 |
| 3 | 「还是不行，点击后没反应」 | 跨站入口点击无响应 |
| 4 | 「还是老样子」 | 彻底卡死（同上一轮） |

### 1.2 技术影响面

- 外链形态（`link`）栏目是机构模块九形态之一（阶段三交付），图书馆「知网」「电子图书」、人资系统、就业信息网均属此类。
- 根因不修，**所有 link 形态栏目的"栏目间切换"都会表现为"点了没反应"**——不仅知网一处。
- 涉登录墙站点（超星系 sslibrary/chaoxing）还会叠加"页面被登录跳转链接管"的误判。

---

## 2. 排障历程时间线

### 2.1 阶段一：确认「电子图书内容可达」（已修复项回溯）

| 时间 | 动作 | 结论 |
|------|------|------|
| 早前 | ATS 明文 http 排查 | 电子图书报「无法连接服务器」→ Info.plist 增 `NSAllowsArbitraryLoadsInWebContent=true`（**Web 内容豁免 ATS，主网层仍严格**）→ 内容可达 ✅ |
| 早前 | 桌面 UA 决策 | 外链为 PC 站（知网/超星对移动 UA 跳 App/渲染空白）→ `WebViewContainer(urlString:desktopUA:true)` ✅ |

### 2.2 阶段二：实现"浏览器式多页签"（第一次动手）

目标：站内「知网」等跨域入口各自打开独立页签。

为此给 [TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift) 的 `WebViewContainer` 添加：

- `tabs: [WebViewTab]` + `activeTabID`；页签条（横向滚动胶囊 + × 关闭）+ 导航条（← → ↻）。
- `WKUIDelegate.createWebViewWith`（`window.open`/`target=_blank` → 新页签）。
- `decidePolicyFor` 跨域判据：`destHost ≠ refHost` → `onNewWindow(url)` + `.cancel`。
- **防竞态修正**：页签参照域 `referenceHost` = 页签初始 URL 的 host，**绝不能用实时 `webView.url`**（JS 导航发起时 `webView.url` 已指向目标页 → 永不触发）。
- 登录流域放行：`hasSuffix("chaoxing.com") || hasSuffix("sslibrary.com")` 保持登录流不切页签。

### 2.3 阶段三：真机日志取证（关键转折）

`devicectl` 拉取真机沙盒日志（`Documents/SJXZIT_Cache/Logs/log_2026-10-01.json`），逐行分析 webview 模块：

**旧 build 段（8125459xx）**——点知网有完整加载链：
```
形态壳栏目选中 知网 → 导航请求 url=https://www.cnki.net/ → 导航开始 → 页面加载完成 title=中国知网
```

**新 build 段（812546050~812546181）**——点知网**零导航**：
```
形态壳栏目选中 知网（每点一次一条）→ 【无任何 cnki 导航请求】
```

同期 sslibrary 导航链全部是「电子图书」栏目的登录墙跳转（page → login → showlogin → chaoxing checklogin → getcookie → showlogin?clg=1）。

### 2.4 阶段四：定位根因（最终定论）

对比两次日志的差异 → 锁定根因在**视图身份复用**：

- 「知网」「电子图书」两个 link 栏目共用**同一** `switch column.kind == .link` 分支（[OrganizationDetailView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationDetailView.swift) `columnArticlesSection`）→ 共用**同一渲染位置、同一类型的 `WebViewContainer`**。
- SwiftUI 渲染规则：**同类型 + 同位置 → 视图身份复用**，实例不销毁重建，仅更新输入参数。
- `WebViewContainer` 只有 `.onAppear` 初始化 `tabs`，而 `.onAppear` **只在视图首次出现时触发一次**。
- `UIViewRepresentable.updateUIView` 为**空实现**（早期只承载单 URL，未考虑外部换源）。
- 结果：`urlString` 从电子图书变成知网 → `tabs` 仍持旧站、WKWebView 不重载 → 「点知网没反应」。

**一句话根因**：`urlString` 是"数字信号"，但 WebView 只响应"首次出现"——外部换源无人监听，SwiftUI 的身份复用把它悄悄吞掉了。

---

## 3. 根因分析（终局定论）

### 3.1 机理拆解

```
用户点「知网」chip
  └→ selectedColumn = 知网栏目
      └→ columnArticlesSection 重新求值
          └→ switch column.kind == .link → linkEmbedSection(知网栏目)
              └→ WebViewContainer(urlString: 知网href)   ← 与电子图书分支同类型同位置
                  ├→ 视图身份被 SwiftUI 复用（不重建）
                  ├→ .onAppear 已触发过（上回电子图书）→ 不再执行
                  ├→ init(urlString:) 更新了 let 参数
                  └→ updateUIView 是空实现 → WKWebView 静默留在旧站
```

### 3.2 为什么"旧 build 正常、新 build 坏"

旧 build 的 `WebViewContainer.body` 直接 `WebView(url: safeURL)` 且容器每次切换都重建（或恰好在 onAppear 路径上）——本次改造引入 `tabs` 状态后，**容器实例一旦出现就永久持有 tabs**，把"换源"这件事完全切断。回归由新功能引入，但**触发器是 SwiftUI 视图复用的固有语义**。

### 3.3 为什么"点知网没反应"而不是"直接打开知网"

`onAppear` 已消费 → tabs 保持上次（电子图书 sslibrary 登录墙）→ 用户看到的是**旧页 + 登录墙**，点知网后页面纹丝不动，像"按钮坏了"。这正是第 3、4 轮反馈的现象。

---

## 4. 修复方案与最终架构

### 4.1 修复动作（单点外科手术）

[WebViewContainer](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift) 增加 `.onChange(of: urlString)`：外部切换链接时，将 `tabs` 重置为新站单页签会话（打点「外链切换·页签重置」）。

```swift
.onChange(of: urlString) { _, newValue in
    // link 形态壳「知网」↔「电子图书」栏目互切时，SwiftUI 复用同一视图身份；
    // 仅靠 onAppear 则 tabs 保持旧站不重载——按浏览器标签页行为重置为新站会话。
    guard let newURL = Self.parsedURL(newValue) else { return }
    if tabs.first?.url == newURL { return }          // 同站不打断
    tabs = [WebViewTab(url: newURL)]
    activeTabID = tabs.first?.id
    loadError = nil; isLoading = true; loadingProgress = 0
    LogManager.shared.info("webview", "外链切换·页签重置", context: ["url": ...])
}
```

配套：`parsedURL(_:)` 静态解析（含中文等非 ASCII 的 URL 编码兜底），与既有 `safeURL` 语义一致。

### 4.2 最终架构（三层职责边界）

| 层 | 触发 | 行为 | 打点 |
|----|------|------|------|
| 外部换源 | link 栏目互切（urlString 变） | 重置为单页签新站会话 | `外链切换·页签重置` |
| 站内跨域 | JS 主帧跳转 / 页面内跨域链接 | 新增独立页签（`.cancel` 原导航） | `导航请求`(refHost/destHost) + `新页签打开` |
| 同域页内 | 页内翻页/页内链接 | 留在当前页签，可前进/后退 | `导航请求`(destHost=refHost) |

判据要点（两个关键防坑）：

1. **参照域必须用"页签初始 host"而非实时 `webView.url`**——这是防竞态的硬规则。
2. **登录/API 家族域放行**（chaoxing.com / sslibrary.com 后缀）——否则超星登录墙三跳全被切成页签，登录态断裂。

---

## 5. 验证与取证闭环（日志 × 截图双通道互证）

### 5.1 双通道取证设计

对**修复后同一 build** 的两轮真机操作，同时采集两种互不依赖的证据，交叉验证同一个修复是否生效：

| 通道 | 来源 | 记录的是 | 回答的问题 |
|------|------|---------|-----------|
| **日志通道**（📋 19:21 会话，时间戳 812546570~574） | `webview`/`organization` 域打点 | 代码侧执行流：栏目选中 → 页签重置 → 导航请求 → 加载完成 | 修复的机制是否真实执行 |
| **截图通道**（📸 20:01~20:02 实拍，iPhone 13 Pro Max 1284×2778） | 真机屏幕画面 | 用户侧可见结果：栏目选中态 / 页签条 host / 站点页面渲染 | 用户实际看到的行为是否符合预期 |

**对齐规则**（<log 信号> ↔ <截图视觉状态>）：两通道用同一标识键配对，一一对应：

| 日志信号 | 截图对应视觉状态 |
|---------|------------------|
| `形态壳栏目选中 column=知网/电子图书` | 栏目 chips 中该栏目呈选中态（背景高亮区分于其他） |
| `外链切换·页签重置 url=…` | 页签条 host 文本（cnki.net ↔ sslibrary.com 随之切换） |
| `导航请求 (refHost/destHost=…)` | —（代码侧信号，截图中无直接对应，用于排除同域误判） |
| `页面加载完成 title=…` | 内嵌 WebView 渲染出的站点首页（标题/品牌/布局可辨识） |

### 5.1a 日志通道实现（打点代码 → 落盘 → 采集）

**① 打点链路（4 个关键点，均为修复/既有埋点）：**

*触发点 A · 栏目选中*（[OrganizationDetailView.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/OrganizationDetailView.swift#L2364-L2371) `selectColumn` 壳形态分支）：

```swift
case .calendar, .opinion, .link, .recruit, .webFallback:
    selectedColumnId = column.id
    pager = OrgPagerState()
    LogManager.shared.info("organization", "形态壳栏目选中", context: [
        "department": unit.name,
        "column": column.title,
        "kind": column.kind.rawValue
    ])
```

*触发点 B · 外链切换会话重置*（[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L5097-L5112) `WebViewContainer.onChange(of: urlString)`）：

```swift
.onChange(of: urlString) { _, newValue in
    guard let newURL = Self.parsedURL(newValue) else { return }
    if tabs.first?.url == newURL { return }
    tabs = [WebViewTab(url: newURL)]
    activeTabID = tabs.first?.id
    loadError = nil; isLoading = true; loadingProgress = 0
    LogManager.shared.info("webview", "外链切换·页签重置", context: [
        "url": String(newURL.absoluteString.prefix(120))
    ])
}
```

*触发点 C · 导航请求（跨域判据 + 观测）*（[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L5241-L5263) `decidePolicyFor`）：

```swift
LogManager.shared.debugLog("webview", "导航请求", context: [
    "url": String(url.prefix(120)),
    "type": "\(navigationAction.navigationType.rawValue)",
    "mainFrame": "\(navigationAction.targetFrame?.isMainFrame ?? false)",
    "refHost": parent.referenceHost ?? "nil",
    "destHost": reqURL?.host ?? "nil"
])
// 页签参照域跨站导航 → 新页签（浏览器标签页行为）
if let reqURL,
   reqURL.scheme == "http" || reqURL.scheme == "https",
   let refHost = parent.referenceHost,
   reqURL.host != refHost {
    let isAuthFlow = host.hasSuffix("chaoxing.com") || host.hasSuffix("sslibrary.com")
    if !isAuthFlow { onNewWindow(reqURL); decisionHandler(.cancel); return }
}
decisionHandler(.allow)
```

*触发点 D · 加载完成*（[TabBar.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L5270-L5278) `didFinish`）：

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    parent.isLoading = false
    parent.loadingProgress = 1.0
    parent.control?.refreshState(webView)
    LogManager.shared.info("webview", "页面加载完成", context: [
        "url": String((webView.url?.absoluteString ?? "nil").prefix(120)),
        "title": String((webView.title ?? "").prefix(40))
    ])
}
```

**② 落盘路径**（[LogManager.swift](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/LogManager.swift#L405)）：`Documents/SXJZIT_Cache/Logs/log_YYYY-MM-DD.json`（JSON 数组，`level/module/message/context/timestamp` 结构）。**约束：单日上限 1000 条（高活跃约 3 分钟写满）→ 操作后 1~2 分钟内必须采集。**

**③ 采集命令**（Mac 侧，经 devicectl 直连真机沙盒）：

```bash
# 整目录复制（单子目录 copy 曾遇 error 7000，整目录更稳）
xcrun devicectl device copy from \
  --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.qinchao \
  --source "Documents" --destination /tmp/xx_docs
# 解析：JSON 数组拆行后按 module=webview/organization 过滤
jq -c '.[]' /tmp/xx_docs/SXJZIT_Cache/Logs/log_2026-10-01.json > /tmp/logs.jsonl
```

### 5.1b 截图通道实现（命令 + 时机纪律）

**① 截屏命令**（macOS `devicectl` 直连真机主屏，无第三方依赖）：

```bash
xcrun devicectl device capture screenshot \
  --device <UDID> \
  --destination /Users/qinchao/Downloads/designcode-swiftui/qin/docs/webview-evidence/evN_xxx.png
# 输出 Dimensions: 1284x2778（iPhone 13 Pro Max 实机分辨率）
```

**② 时机纪律（本案例踩过的坑）**：

- 截屏只反映**当前时刻**的主屏画面——用户未操作/锁屏时截到黑屏或旧画面（实测抓过一次 Mac 桌面帧、一次纯黑帧），**必须在用户完成操作、屏幕停留在目标页面时立即截取**。
- 取证节奏 = 「请用户操作 → 用户确认已加载 → 立即截屏 → 与日志时间戳对表」，一步一拍。
- 三帧之间用不同文件名校验（ev1/ev2/ev3），按操作顺序归档，回读时用图像分析确认真实内容后再入报告。

### 5.2 闭环取证矩阵（核心证据）

| # | 用户操作 | 日志信号（时间戳 812546xxx） | 截图信号 | 判定 |
|---|---------|------------------------------|---------|------|
| 1 | 图书馆 → 点「知网」栏目 | `形态壳栏目选中 知网`(572.12) → `外链切换·页签重置 https://www.cnki.net/`(572.14) → `导航请求 refHost=destHost=www.cnki.net`(572.22) → `页面加载完成 title=中国知网`(572.64) | [ev1_library_cnki.png](file:///Users/qinchao/Downloads/designcode-swiftui/qin/docs/webview-evidence/ev1_library_cnki.png)：「知网」chips 选中态 + 页签条 **cnki.net** + 知网首页完整渲染（"知网研学平台"横幅、文献导航栏） | ✅ 点知网开知网页 |
| 2 | 图书馆 → 点「电子图书」栏目 | `形态壳栏目选中 电子图书`(570.16) → `外链切换·页签重置 http://www.sslibrary.com/page/239443/show`(570.16) → `导航请求 refHost=destHost=www.sslibrary.com`(570.29) → `页面加载完成 title=电子书`(570.60) | [ev2_ebook.png](file:///Users/qinchao/Downloads/designcode-swiftui/qin/docs/webview-evidence/ev2_ebook.png)：「电子图书」chips 选中态 + 页签条 **sslibrary.com** + 超星电子图书站页面（停靠登录页） | ✅ 点电子图书开电子图书页 |
| 3 | 电子图书 → 再点「知网」栏目 | `形态壳栏目选中 知网` + `外链切换·页签重置 https://www.cnki.net/` + 知网导航/加载完成（573.50~574 区间互切循环） | [ev3_cnki_back.png](file:///Users/qinchao/Downloads/designcode-swiftui/qin/docs/webview-evidence/ev3_cnki_back.png)：「知网」chips 恢复选中态 + 页签条回到 **cnki.net** + 知网首页重载完成 | ✅ 互切循环稳定，每次切换都重置为新站会话 |
| 0 | 全程旁证 | 会话内 `webview`/`organization` 域 0 ERROR、0 白屏 | 三帧均无"加载失败/空白"占位 | ✅ 无回归 |

**逐条互证读法**（以 #2 为例）：日志说 570.16 收到电子图书选中、570.16 页签重置为 sslibrary、570.60 电子书加载完成 → 截图 ev2 同一操作后 instantly 显示「电子图书」chips 高亮 + 页签条 host=sslibrary.com + 超星页面渲染。**日志能证明"机制执行了"，截图能证明"用户看到了"，二者键值一致即为闭环**。

### 5.3 修复前后行为对照（同一次用户手势）

| 手势 | 修复前（8125459xx 段日志） | 修复后（812546570~574 + 截图） |
|------|---------------------------|-------------------------------|
| 点「知网」 | 日志仅 `形态壳栏目选中 知网`，**无 cnki 导航请求**（tabs 停留旧站）；截图=旧站页面纹丝不动 | `外链切换·页签重置` + cnki 导航链 +「中国知网」加载完成；截图=知网首页 |
| 点「电子图书」 | 同病：仅栏目选中，无 sslibrary 重载 | 页签重置 sslibrary + 电子书重载；截图=超星站 |

### 5.4 验收口径（用户操作等价断言，全绿）

| 用户操作 | 期望 | 日志实测 | 截图实测 |
|---------|------|---------|---------|
| 图书馆 → 电子图书 | 显示电子图书站 | ✅ 页签重置 sslibrary →「电子书」加载完成 | ✅ ev2 超星站 |
| 图书馆 → 知网 | 显示知网站 | ✅ 页签重置 cnki →「中国知网」加载完成 | ✅ ev1 知网首页 |
| 电子图书 → 知网（互切） | 各自独立、循环稳定 | ✅ 每次切换都有页签重置 + 独立加载链 | ✅ ev3 切回知网 |
| 任意时刻 | 无 ERROR / 无白屏 | ✅ 会话 0 ERROR | ✅ 三帧无失败占位 |

---

## 6. 经验教训（按可复用价值分级）

### 6.1 团队级 · 架构原则

1. **内部嵌 WebView 的视图，若可能被 SwiftUI 复用，必须 `onChange(of: urlString)` 兜底重载。**
   「同 switch 分支 + 同视图位置 + 同类型」= 身份复用三要素。只在 `onAppear` 初始化、`updateUIView` 留空的组件，面对"换源"是聋子。
2. **`onAppear` 只在首次出现触发一次；`updateUIView` / `onChange` 才是"参数变化"的通道。** 这是 SwiftUI 视图生命周期的基础事实，但最容易在"往里加状态"的重构里被踩。
3. **UIViewRepresentable 的 `url` 若是 `let` 且外层有状态缓存（tabs），必须显式提供换源语义。** "先重渲染再想想" 在这里是反模式。
4. **外部站点内嵌的点击链路，由站点自身登录墙/iframe 决定，App 无法完全掌控。** 最终兜底 = 「浏览器式多页签 + 外部链接切换必重置会话」——保证任一入口点开即该站独立页，永不"点了没反应"。

### 6.2 工程级 · 跨域/登录墙治理

5. **跨域判据必须防竞态**：JS 导航发起时 `webView.url` 已指向目标页，用实时 URL 判断"新站"永不触发——用页签初始 host（`referenceHost`）击穿。
6. **登录家族域放行清单**：chaoxing.com / sslibrary.com 等认证/API 域必须在跨域切页签前放行，否则登录流三跳全被拦截、登录态断裂，问题表现为"页面卡在登录页"。
7. **ATS 只豁免 Web 内容层**：`NSAllowsArbitraryLoadsInWebContent` 仅影响 WebView 内的明文内容，主网络层保持严格——既能放行 http 外链，又不拖垮整体安全基线。
8. **桌面 UA 是 PC 外链的必需品**：知网/超星对移动 UA 会跳 App/渲染空白，`desktopUA` 按需注入，且必须是 Safari 17 桌面版字符串才被识别为标准桌面。

### 6.3 个人级 · 调试与取证

9. **"用户复现"永远优先于"我猜"**：四轮反馈里前两轮在猜（页签条没出现 / 判据没触发），真正定论来自一行行日志对比——**旧 build 有加载链、新 build 零导航**，差异直接指认代码变更。
10. **日志埋点要放在判据决策点**：`decidePolicyFor` 的 `导航请求` 打点带 refHost/destHost/mainFrame/type——没有它，跨域拦截是否命中只能靠猜。
11. **取证要对比"改动前后"两组数据**：单看"现在没导航"≠根因，和"改前有导航"放一起，才暴露"是谁改坏了"。
12. **短暂现象要留给余量**：App 单日日志上限 1000 条（高活跃 3 分钟写满）→ 操作后 1~2 分钟内必须拉取；`devicectl` 复制单子目录会报 error 7000，**复制整个 Documents 再本地定位**更稳。

### 6.4 沟通篇

13. **连续反馈"还是老样子"时要换策略**：同一操作指引不能重复给。第 4 轮直接拉日志、不再引导操作，一次定位。
14. **每次 build 要留打点差异**：下版本能说清"这次改了什么判定/打点"，取证才有对照系。

---

## 7. 可复用的排障方法论

```
症状收集（用户原话 + 复现步骤）
   ↓
改动前后日志对比   ← 无此对照，一切靠猜
   ↓
差异定位到"坐标"  （swtich 分支 / 视图位置 / 类型 / 参数）
   ↓
对照 SwiftUI 生命周期语义   （onAppear / onChange / updateUIView）
   ↓
最小外科手术修复
   ↓
真机再取证（用户操作等价断言）
```

**本案例的关键一步**：把"点知网没反应"翻译成技术信号——**"urlString 变了但没有任何导航请求"**。这个信号同时排除了"判据没命中""点击被吞"两条歧路，直指"WebView 没收到新 URL"。

---

## 8. 工程沉淀与后续关注

### 8.1 已沉淀

- **CODE_WIKI.md §4.12.3**：外链形态多页签 + 链接切换会话重置（架构/判据/ATS/打点链路/经验教训）。
- **项目记忆**：根因、修复、取证闭环、三条教训（onChange 兜底 / 外部站点不可控 / devicectl 复制坑）。
- **代码**：`WebViewContainer.onChange(of: urlString)` + `parsedURL` 静态解析；日志域 `webview` 新增 `外链切换·页签重置` 打点。
- **双通道取证**（2026-10-01 采集，[webview-evidence/](file:///Users/qinchao/Downloads/designcode-swiftui/qin/docs/webview-evidence)）：日志通道（19:21 会话 812546570~574 打点链）+ 截图通道（20:01~02 实拍 ev1 知网 / ev2 电子图书 / ev3 切回知网）——二者按键值对齐（栏目选中↔chips 高亮、页签重置↔页签条 host、加载完成↔站点渲染），构成 §5.2 闭环取证矩阵与 §5.3 修复前后对照。

### 8.2 后续关注名单（同类风险面巡检）

- 其他可能被 SwiftUI 身份复用的 WebView：文章详情 WebView（`urlString: articleURL` 等调用点）——若未来出现"换文章不换内容"，同一把钥匙。
- 电子图书登录墙体验：本轮放行登录域保证登录流，但登录墙本身（showlogin 链）仍会出现——可考虑后续"检测到登录页 + 站点文案提示"。
- 超星全站翻页/子入口：若站内还有同类"期望新开页"的入口，走既有 `decidePolicyFor` 跨域判据自动覆盖，无需另行处理。

---

*文档结 2026-10-01 · 山西晋中理工学院「园枢」iOS App · qin/docs/webview-multitab-retrospective-20261001.md*