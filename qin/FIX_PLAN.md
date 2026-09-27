# 修复方案：机构独立子站「子标签下拉刷新」显示「加载失败，请稍后重试」

> 状态：待确认（确认后执行）
> 关联文档：`DEBUG_REPORT.md`（历史排查）、`ARCHITECTURE.md`（架构全景）
> 修复文件：`DesignCode/OrganizationDetailView.swift`（`ChildSectionDetailView`）

---

## 1. 背景与根因回顾

**现象**：校园机构设置中，有独立子站的机构，其子标签（如「理论学习」）下拉刷新时报「加载失败，请稍后重试」。

**根因**：`.refreshable` 被绑定在「条件分支生成」的 `ScrollView` 上。刷新动作先把 `articles` 清空、并把 `isLoadingMore` 置为 `true`，导致 `body` 立即从「文章列表 ScrollView」切换到「加载中视图」，承载 `.refreshable` 的 ScrollView 被移除，SwiftUI 取消正在执行的刷新 Task，网络请求抛出 `CancellationError`，最终落入兜底 else 分支被误报为「加载失败」。

**证据**（日志）：`error=cancelled` / `CancellationError`、`elapsed≈15ms`（秒失败）、`attempts=3`（重试循环内立即因取消抛错）。

**关键代码位置**：
- `ChildSectionDetailView` 定义：`OrganizationDetailView.swift:4394`
- `.refreshable` 绑定在 `articleListView` 内：`OrganizationDetailView.swift:4611`
- `loadArticles` 清空文章：`OrganizationDetailView.swift:4771`
- 通用错误兜底（误报处）：`OrganizationDetailView.swift:4987-4997`

---

## 2. 修复目标与原则

1. 下拉刷新**不再自我取消**（核心）。
2. 刷新过程中**保留已有数据**，不出现列表闪烁/空白。
3. 取消（用户关闭页面 / 快速重复刷新）时**静默处理**，不误报错误。
4. **最小改动**，不影响其他机构 / 详情页功能。

---

## 3. 修复方案

### 改动 A（核心）：刷新路径不清空已有文章

**位置**：`OrganizationDetailView.swift:4768-4794`（`loadArticles()`）

**现状**：

```swift
private func loadArticles() async {
    // 先使用已有的文章（从初始数据解析的）
    let initialArticles = child.articles
    if !initialArticles.isEmpty {
        articles = initialArticles            // ← 刷新时会把已加载列表重置，触发分支切换
    }
    guard let columnId = child.columnId, !columnId.isEmpty else { ... }
    await loadMoreArticles(startPage: 1)
}
```

**改为**：仅当 `articles` 为空（首次加载）时才用 `child.articles` 初始化；刷新时保留已有列表。

```swift
private func loadArticles() async {
    if articles.isEmpty {
        articles = child.articles            // 仅首次加载时初始化，刷新时不清空
    }
    guard let columnId = child.columnId, !columnId.isEmpty else { ... }
    await loadMoreArticles(startPage: 1)
}
```

> 说明：`loadMoreArticles(startPage: 1)` 在 `page == 1` 时仍会用新拉取的首页结果整体替换 `articles`（`OrganizationDetailView.swift:4891-4894`），因此刷新语义不变，只是「拉取期间」不再出现空列表 → 不会再触发 `body` 分支切换 → 不再自我取消。

### 改动 B（防御）：吞掉「取消」，不误报错误

**位置**：`OrganizationDetailView.swift:4825-5001`（`loadMoreArticles()` 的循环与兜底）

**现状**：`CancellationError` / `URLError.cancelled` 未单独处理，落到通用 else（`:4987`）显示「加载失败」。

**改为**：在循环结束后、判断 `bestResult` 之前，先判断任务是否被取消，取消则静默返回，不设 `loadError`。

```swift
// 循环结束、进入 if let result = bestResult 之前插入：
if Task.isCancelled {
    isLoadingMore = false
    return
}
```

同时，在 `catch` 分支识别取消类错误并跳过（可选加固）：

```swift
} catch is CancellationError {
    // 任务被取消，不记录为失败，交由上方 Task.isCancelled 处理
} catch let e as URLError where e.code == .cancelled {
    // 同上
} catch {
    lastError = error
    LogManager.shared.warning(...)
}
```

> 说明：即使改动 A 已消除本 bug 的触发条件，此处仍有必要——例如用户关闭子标签页（sheet dismiss）时，`.task` 会被取消，须静默退出而非写入 `loadError` 并污染日志。

### 改动 C（可选加固）：统一外层 ScrollView

**位置**：`ChildSectionDetailView` 的 `body`（`OrganizationDetailView.swift:4416-4425`）

**现状**：`.refreshable` 只在 `articleListView` 分支（`articleListView` 自带 ScrollView，`:4549`）。

**加固**：将 `.refreshable` 挂到一个「始终存在」的外层 ScrollView 上，`loadingView`/`emptyView` 去掉各自内层 ScrollView，统一由外层承载。这样从结构上杜绝「承载 refreshable 的视图被移除」的可能，且空态/加载态也能下拉刷新。

> 说明：本改动偏重构，**非修复所必需**（改动 A + B 已能根治并将误报消除）。若你倾向纯最小改动，可只做 A + B；若追求长期稳健，建议三者一起做。

---

## 4. 验证方案

在真机 / 模拟器上复现原路径：

1. 进入「机构设置」→ 选一个有独立子站的机构（如含「理论学习」子标签的机构）。
2. 进入该子标签详情页，等待文章列表加载完成。
3. **下拉刷新**，观察：
   - 不再出现「加载失败，请稍后重试」；
   - 刷新期间列表不消失、不跳空；
   - 刷新完成后列表更新。
4. **边界验证**：
   - 首次进入子标签（空态 → 加载）正常；
   - 加载中途快速返回（点击左上角关闭）不崩溃、日志无 `子标签分页加载异常` 报错；
   - 连续多次下拉刷新不误报；
   - 普通机构（非独立子站）子标签刷新仍正常。

预期日志：无 `[ERROR] [network] 请求最终失败 ... error=cancelled`、无 `[ERROR] [organization] 子标签分页加载异常`。

---

## 5. 影响面与风险

| 项 | 说明 |
|---|---|
| 影响文件 | 仅 `DesignCode/OrganizationDetailView.swift`（`ChildSectionDetailView` 内部） |
| 影响功能 | 仅「机构子标签详情页」的加载/刷新逻辑 |
| 对其他功能 | 无侵入（不触碰 `DataService` / `NetworkService` / 其他 View） |
| 主要风险 | 改动 C（若做）涉及视图结构调整，需回归空态/加载态/列表态三种展示 |

---

## 6. 待你确认

请确认执行范围（二选一）：

- **方案一（最小改动）**：仅执行「改动 A + 改动 B」。
- **方案二（最小改动 + 结构加固）**：执行「改动 A + B + C」。

确认后我立即修改并给出改动要点摘要。