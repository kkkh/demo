# 机构动态详情：双状态 → 单状态改造总结报告

- **日期**：2026-10-02
- **提交**：`73aaa8d`（fix(org-module): 机构动态消息冷启动白屏修复）
- **范围**：仅机构动态通道（orgUpdate）——`TabBar.swift` / `MessageCenterStore.swift` / `NotificationManager.swift`
- **验收**：10/10 自动用例全绿 + 6/6 真机视觉项人工确认 + 三远端哈希逐字节一致

---

## 1. 背景与问题

App「我的 → 消息中心」中，仅 **【信创与大数据学院】** 这条 `orgUpdate` 型消息，在 **App 冷启动后首次点击**时：

- 详情页空白，划一下/点一下、等待数秒后才加载出文章
- 返回再次点击，或点击其他任意消息，完全正常

**"为什么只有这一条"**——经排查，`orgUpdate` 是消息中心中**唯一**走独立 sheet 通道（`consumePendingOrgArticleDeepLink`）的类型；`news`/`bookmarkUpdate` 走另一条有等待+错峰的通路，因此只有它踩中缺陷。数据与网络层均正常（1853 字 + 3 图，文章接口 200）。

## 2. 根因分析（机制级）

机构动态详情 sheet 原为**双状态驱动**：

```swift
@State private var showOrgArticleFromNotification = false   // 触发信号
@State private var pendingOrgArticle: PendingOrgArticleDeepLink?  // 数据
```

`.sheet(isPresented: $showOrgArticleFromNotification)` 由 bool 触发呈现，内容由 item 决定。两个变量**无法原子同步**，存在呈现竞态窗口：

> bool=true 触发呈现的瞬间，item 可能仍为 nil（或已被 onDismiss 清空但 UI 周期未传导）→ 视图落入 `if let` 的 else 分支（空/占位）→ **详情视图未创建 → `.task` 不执行** → 白屏；直到用户交互触发视图重建后才加载。

**证据链**（`/tmp/org_logs_v2/log_2026-10-02.json`）：

- 修复前旧版：直达打点（`机构动态通知 → 直达机构文章详情`）之后出现详情打点（`文章详情页打开`）要 **8.0s**（12:41:13→12:41:21）
- 更早版本：直达打点后**无任何详情打点**（`.task` 从未执行，纯白屏）——与"划一下点一下才加载"表现吻合

**连带隐患**：原"等待消息中心 sheet 关闭"的判据引用了 `ProfileView` 的私有 `@State showMessageCenter`——跨 struct 引用，**静态编译即失败**，该段代码从未成功构建。

## 3. 改造方案：双状态 → 单状态

### 3.1 核心：`sheet(item:)` 单状态驱动

[TabBar.swift L416](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L416-L431)

```swift
@State private var pendingOrgArticle: PendingOrgArticleDeepLink?   // L40 唯一状态
...
.sheet(item: $pendingOrgArticle, onDismiss: { ... }) { request in
    NavigationStack {
        OrganizationArticleDetailView(article: OrgArticle(...), siteId: request.siteId, ...)
    }
    .sjzPresentationChrome()
}
```

**契约变化**：

| | 双状态（旧） | 单状态（新） |
|---|---|---|
| 呈现触发 | bool=true | item != nil |
| 内容来源 | 单独读取 item（可能脱钩） | closure 入参快照（非可选） |
| 关闭路径 | onDismiss 手动置 nil 同步 | 系统置 nil 驱动，无手动同步 |
| 竞态窗口 | 存在（bool 与 item 脱钩） | 物理上不存在 |
| 兜底分支 | 需要 `if-let else` 空/占位 | 不需要（nil 不可呈现） |

closure 拿到 non-optional 快照：无论后续状态如何变化，**渲染期间内容稳定**；`sheet(item:)` 的呈现与内容由同一个值原子绑定。

### 3.2 配套改动（局部隔离，零全局影响）

1. **[TabBar.swift L90](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L90-L122) 消费逻辑**：删除 `showOrgArticleFromNotification = true` 赋值，只设 `pendingOrgArticle`，由 item 单一驱动呈现。错峰窗口（消息中心 550ms / 其他 300ms）与"等场景激活+解锁"逻辑原样保留。
2. **[TabBar.swift L10286](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L10286) + [MessageCenterStore.swift L186](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/MessageCenterStore.swift#L183-L186)**："等待消息中心 sheet 完全退场"改为**共享时间戳** `messageCenterDismissedAt`（ProfileView 的 sheet onDismiss 写入）；[TabBar.swift L106](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/TabBar.swift#L106-L116) 轮询该时间戳（仅认 3s 内新鲜退场，40 轮超时兜底）。顺带修复了 §2 的潜伏编译错误。
3. **[NotificationManager.swift L53](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/NotificationManager.swift#L53)**：`PendingOrgArticleDeepLink` 补 `Identifiable`（复用已有 `id: UUID`），满足 `sheet(item:)` 要求。

### 3.3 为什么是"更好"而非"换皮"

- **消除病根**：nil 与呈现不再共存，"先弹空 sheet 再填内容"的状态在类型上不可表达
- **代码更少更简单**：删掉双状态与死分支兜底，减少一份永远不会走但必须维护的分支
- **渲染契约更稳**：快照入参隔离了"呈现期间状态被外部清空"的悬挂引用问题

## 4. 验收证据

### 4.1 自动断言（10/10 全绿）

验收脚本：[org_article_sheet_acceptance.sh](file:///Users/qinchao/Downloads/designcode-swiftui/qin/Scripts/org_article_sheet_acceptance.sh)（一条命令闭环：构建安装 → 冷启动引导 → 日志断言 → Markdown 报告）；报告：[org_article_sheet_acceptance_20261002_130037.md](file:///Users/qinchao/Downloads/designcode-swiftui/qin/build/verify/org_article_sheet_acceptance_20261002_130037.md)

**核心判定：直达打点 → 详情打点间隔 δ ≤ 3.0s**

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 首次点击详情 δ | 8.0s（旧版）/ 无打点（更早） | **0.06s** |
| 8 次组织直达 → 详情 | — | 全部 δ≈0.04s |

- A1 冷启动首次 ✓ · A2 二次点击 ✓ · A3 其他消息通道（8 次）✓ · B1 快速连点（投递 17 次）✓
- C0 零 ERROR/FATAL ✓ · S1~S4 静态契约 ✓ · P1 持久化旁证（`messageCenterEvents.json` 目标条目 `isRead=true`，真机点开详情直接证据）✓

### 4.2 人工视觉确认（6/6）

报告末尾 6 项清单（首次立即出全文 / 二次点击 / 其他消息 / 快速连点 / 下滑收起与返回手势 / 角标未读更新）**全部通过**。

### 4.3 三远端同步

`origin`(GitHub) / `cnb` / `gitee` 服务器实际 HEAD = `73aaa8d00a1752ffb10789205ca1928c701bce34`，哈希**逐字节一致**（`git ls-remote` 直查服务器，非本地跟踪引用）。

## 5. 影响面与残余风险（诚实检查）

| 维度 | 评估 |
|---|---|
| 变更范围 | 仅机构动态通道，news/bookmark/全局路由/通用组件零改动 |
| 行为变化 | "先空 sheet 再填内容"过渡消失——原为 bug；详情页自身 `loadingView` 覆盖内容加载态，不依赖外层占位 |
| 新增约束 | `sheet(item:)` 要求 `Identifiable`——复用已有 `id`，无连带改动 |
| 残余风险 | 轮询共享时间戳（3s 新鲜窗口 + 超时兜底）——若未来时序变化可能早弹，最坏回落旧行为，不会更糟 |

## 6. 经验沉淀

1. **呈现用 item 驱动，别用裸 bool**：当"呈现"与"数据"语义正交时，宁可把触发信号合并进数据值本身；`sheet(isPresented:)` + 外部读取数据是竞态高发组合。
2. **`.task` 是关于"视图是否创建"的真相**：白屏类问题排查时，"打点缺失 = 视图未创建"是强力的分诊信号。
3. **跨视图共享判据必须走共享状态**：跨 struct 引用私有 `@State` 是编译错误，也是静默失效的温床；等待"前置 sheet 退场"这类跨页面状态用共享时间戳/共享 store。
4. **兜底分支是症状不是方案**：`if let ... else 占位` 掩盖了"本不该存在"的状态；修复应让该状态在类型上不可表达，而不是为它写 UI。

## 7. 产物清单

- 代码：`73aaa8d`（4 文件，+565/−27）
- 验收脚本：`qin/Scripts/org_article_sheet_acceptance.sh`
- 验收报告：`qin/build/verify/org_article_sheet_acceptance_20261002_130037.md`
- 本报告：`qin/docs/org-article-sheet-refactor-20261002.md`
- 三远端：已同步且核验一致