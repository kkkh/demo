# C · 可观测性与显示设置（深度分析草稿）

> 分析范围：`qin/DesignCode/LogManager.swift`、`DisplaySettingsManager.swift`、`CacheModeManager.swift`、`SJZNetworkMonitor.swift`
> 行数实测（`wc -l`，2026-10-01 于仓库根执行）：
> `LogManager.swift` = **1073**（read 工具报 1074 行，末行无换行符，尾部为 `}`）、`DisplaySettingsManager.swift` = **2959**（read 报 2960）、`CacheModeManager.swift` = **455**（read 报 456）、`SJZNetworkMonitor.swift` = **1917**（read 报 1918）。
> 本文所有行号均来自 `read` / `grep -n` 实测，未经验证的推断一律在文末「未验证」清单中标注。

---

## 0. 一句话结论

这四个文件构成 App 的**四条横向基础设施**：

| 文件 | 角色 | 关键设计一句话 |
|---|---|---|
| `LogManager.swift` | 全链路本地可观测性 | `@MainActor` 单例 + 异步 ioQueue 追加合并落盘 + 「同键折叠 / 全局限速」双防线抑制自反馈日志风暴 |
| `DisplaySettingsManager.swift` | 全局显示/排版/阅读统计单一状态源 | 21 个设置键 + 2 个历史键（共 23 个 UserDefaults 键）+ 6 个自定义 `EnvironmentKey` + 根视图单点注入 + UIKit 系统渲染面接管 + 跨 presentation 二次注入 |
| `CacheModeManager.swift` | 缓存策略单一状态源 | 2 个互斥枚举模式 + 1 个正交「无图模式」开关；`@MainActor` 状态经 `CacheModeMirror`（NSLock）暴露给 URLProtocol 后台线程 |
| `SJZNetworkMonitor.swift` | 网络可观测性中枢 | `@MainActor` 单例 + 独立 `NetworkMonitorLedger`（NSLock 记账）+ NWPathMonitor + 每请求 TTFB 埋点 + 宿主归因慢请求告警 |

三者通过 `LogManager.shared` 埋点强耦合（本组 4 文件自身共 **125** 处日志埋点：LogManager 22 / DisplaySettingsManager 49 / CacheModeManager 12 / SJZNetworkMonitor 42，见 §6）。

---

## 1. LogManager（1073 行）— 全功能本地日志系统

### 1.1 定位与硬约束（源码注释明确写出）

文件头注释（1–10 行）声明 4 条设计契约：

1. **完全本地存储，隐私优先，不自动上传任何日志**；
2. **异步后台写入，绝对不阻塞主线程**；
3. **追加合并式落盘**——「新增条目按日合并进既有文件，杜绝历史『内存裁剪截断磁盘』缺陷」；
4. 配套：损坏条目逐条抢救 + 单日文件轮转 + 保留天数自动清理 + 崩溃同步落盘（本地日键一致）。

以及一条自我观测契约：**「本模块自身全链路埋点：日志域 log（页面/筛选/搜索/导出/清空/删除/设置/存储统计/落盘）」**（第 9 行）。实测该域在生产代码 61 处（§6）。

### 1.2 数据模型

| 类型 | 行号 | 要点 |
|---|---|---|
| `LogLevel` | 18–60 | 5 级：`info/debug/warning/error/fatal`；`color`(25)、`icon`(35)、`displayName` 中文名(46)、`isIssue`(57，warning/error/fatal) |
| `LogEntry` | 64–211 | `id/timestamp/level/module/message/context`；`Codable + Equatable + Identifiable` |
| └ 静态格式化器缓存 | 83–118 | 5 个 `DateFormatter` 静态复用——注释：「列表数千行渲染不再逐行新建 DateFormatter」 |
| └ `dayKeyFormatter` | 114–118 | `yyyy-MM-dd`，**与落盘文件名 `log_<yyyy-MM-dd>.json` 共用同一口径**（113 行注释） |
| └ `relativeTime` / `displayTime` | 136 / 149 | 列表时间；今天 `HH:mm:ss.SSS`，往日 `MM-dd HH:mm:ss`（配合日期分组消除歧义，148 行注释） |
| └ `formattedLine` / `detailText` / `jsonObject` / `jsonText` | 160 / 170 / 187 / 203 | 导出与复制三态（行文本 / 详情文本 / 结构化 JSON） |
| `LogStorageSnapshot` | 215–230 | 磁盘维度：文件数、占用、日键列表（最新在前）、KB/MB 自适应文案 |
| `LogStats` | 234–243 | 内存维度：总数 / 今日 / 今日异常 / 各级计数 / 最早最新 |
| `LogExportFormat` | 247–266 | `text` / `json` 两格式，含标题与扩展名 |

### 1.3 单例与测试宿主隔离（本文件最「反直觉」的设计之一）

```swift
static let shared = LogManager(persistsToDisk: !LogManager.isRunningTests)   // 276
nonisolated static let isRunningTests: Bool = {                              // 279-282
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}()
```

- **为什么**（272–275 行注释原文）：测试宿主中自动切换为「仅驻内存」——不读/不写真实日志文件，杜绝单元用例故意构造的错误路径（损坏存储 / 超限 / 空 id 等）污染用户在「应用日志」里看到的真实日志内容。
- 注释还给出实证依据：「2026-09-28 真机日志复核实证：日志页 4 条 ERROR 的字节数与测试夹具逐一吻合，真实存储完好」。
- 契约由单测锚定：`LogManagerTests.swift:494 testSharedInstanceRunsEphemeralUnderXCTest`（断言 `shared.persistsToDisk == false`，而注入实例仍为 `true`）。
- **可注入构造**（395–400）：`defaults / storageDirectory / defaultRetentionDays(7) / defaultMaxEntries(3000) / maxEntriesPerFile(1000) / persistsToDisk`。存储目录默认 `Documents/SXJZIT_Cache/Logs`（405）。

### 1.4 持久化设置项（4 项，`@Published` + `didSet` 即持久化即留痕）

| 设置 | 键（293–298） | 默认 | 声明行 | 副作用 |
|---|---|---|---|---|
| `debugEnabled` | `logDebugEnabled` | `true` | 306–312 | 关闭后 `log(level:.debug)` 直接 return（443） |
| `crashCaptureEnabled` | `logCrashCaptureEnabled` | `true` | 315–322 | 同步写 `crashCaptureEnabledSnapshot`（即时生效，无需重启） |
| `maxEntries` | `logMaxEntries` | `3000` | 325–332 | `applyMaxEntriesLimit()` 立即裁剪 |
| `retentionDays` | `logRetentionDays` | `7` | 335–342 | `applyRetention(reason:"设置变更")` 立即清理 |

**为什么要「刻意不在声明处给默认值」**（302–303 行注释原文）：Swift 中「声明处有初值的属性在 init 再赋值」会触发 `didSet`，导致每次启动误写设置并留下「设置变更」伪日志；因此统一在 `init` 末尾集中赋值（赋值不触发观察器）。这是本文件避免日志自噪声的关键细节。

### 1.5 写入链路（输入 → 处理 → 输出）

```
调用方 LogManager.shared.info/debugLog/warning/error/fatal(module, message, context)   // 553-567 便捷方法
        │
        ▼  log(level:module:message:context:)                     // 441
   ① DEBUG 门控：level == .debug && !debugEnabled → return         // 443
   ② 构造 LogEntry（UUID + Date 打点）                              // 445
   ③ 风暴防线：shouldFold(entry) == true → return                  // 448
   ④ appendDirect(entry)                                          // 454
        ├─ entries.insert(entry, at: 0)            // 最新在前      // 456
        ├─ FIFO 淘汰：entries.count > maxEntries → prefix(maxEntries) // 459-461
        ├─ pendingBox.items.append(entry)（NSLock 保护）           // 464-466
        └─ scheduleFlush()                                        // 467
                └─ ioQueue.asyncAfter(0.5s, execute: work)         // 870（防抖合并）
                        └─ flush(box:dir:maxPerFile:)              // 874：抽干缓冲
                                └─ mergeWrite(batch:dir:maxPerFile:) // 885
```

- `scheduleFlush`（853–871）：`saveWorkItem?.cancel()` 后重建 → **0.5s 防抖**，同一窗口内多次写入只落一次盘；落盘失败会在主线程补一条 `WARNING 日志落盘部分失败`（861–867）。
- **pendingBox 是 `@unchecked Sendable` 的锁盒**（355–359）：主线程写、ioQueue 抽干，注释明确「待落盘缓冲（主线程写入；ioQueue 抽干）——线程安全盒」。
- `flushPendingNow()`（572–584）：走 `ioQueue.sync` **同步**执行。注释说明动机：「与删除/清理任务严格串行，杜绝『先删后写』竞态导致已清日志复活」。调用点在 App 退后台：`DesignCodeApp.swift:131（case .background）→ :134 flushPendingNow()`，落盘成功时补 `DEBUG(log) 退后台日志落盘完成`。

### 1.6 追加合并落盘 `mergeWrite`（883–909）：本文件的核心算法

```
输入：batch（待写条目）、dir、maxPerFile
处理：
  grouped = Dictionary(grouping: batch, by: \.dayKey)      // 887 按本地日键分组
  for (dayKey, newEntries) in grouped:
      fileURL = dir/"log_<dayKey>.json"                     // 889
      logFileLock.lock() … defer unlock                     // 890-891（跨线程读-改-写互斥）
      existing = decodeEntries(读既有文件).entries ?? []     // 893-895
      merged   = newEntries.filter { 其 id 不在 existing 中 } // 897（按 id 去重）
      merged.append(contentsOf: existing)                   // 898
      merged.sort { $0.timestamp > $1.timestamp }            // 899 倒序
      capped   = merged.prefix(maxPerFile)                  // 900 单文件上限
      JSONEncoder().encode(capped).write(.atomic)           // 902-903 原子写
输出：失败文件数（>0 时由调用方补 WARNING 日志）
```

设计要点（884 行注释原文）：**「内存 FIFO 不影响磁盘既有条目（修复历史『重写截断』缺陷）；仅写有新条目的日文件（消除全量重写放大）」**。即内存上限只裁剪内存，磁盘条目靠「单文件上限 + 保留天数」治理。

对应的回归测试锚点（`DesignCodeTests/LogManagerTests.swift`）：
`testAppendMergePreservesExistingDiskEntries:234`、`testMemoryTrimDoesNotTruncateDisk:252`、`testSingleFileCapKeepsNewest:275`。

### 1.7 文件锁体系（三把锁，职责分明）

| 锁 | 行号 | 保护对象 | 说明 |
|---|---|---|---|
| `logFileLock`（`nonisolated static NSLock`） | 363 | 日文件的读-改-写 | 注释：统一保护「合并落盘 / 删除剔除 / 崩溃同步写入」三类操作，避免崩溃写入与防抖落盘并发交错导致条目丢失（2026-09-28 复核加固） |
| `PendingBox.lock`（`NSLock`） | 356 | 待落盘缓冲 `items` | 主线程 append / ioQueue 抽干 / 删除剔除（722–727） |
| `crashFlagLock`（`nonisolated static NSLock`） | 378 | `crashFlag` 快照 | 供信号/异常回调线程读取崩溃捕获开关（382–391） |

`ioQueue` 本身是串行队列：`DispatchQueue(label: "com.sxjzit.log.io", qos: .utility)`（351）。

### 1.8 日志风暴抑制（自反馈风暴的根因与解法）★

**根因（447 行注释原文）**：「自反馈防线：同 module+message 1 秒内高频重复 → 折叠（**防止「展示日志 → 写日志 → 再展示」递归风暴拖死主线程**）」。
即：日志页渲染时若自身产生日志（筛选/搜索/滚动埋点），新日志又会触发列表刷新，刷新又产生日志 —— 指数级自反馈，主线程被拖死。真机卡死现场被记录在测试注释中（`LogManagerTests.swift:431`「自反馈风暴抑制（2026-09-28 现场卡死防线）」）。

**两道防线（shouldFold，487–529）**：

| 防线 | 常量 | 阈值 | 行号 | 触发行为 |
|---|---|---|---|---|
| ① 全局速率防线（跨键） | `globalStormLimit` | **300 条 / 秒** | 475 | 超出即丢；窗口内首次超限补一条 `WARNING 日志全局限流：日志产生速率异常已限速折叠`（501–506） |
| ② 同键防线 | `stormFoldLimit` | **50 条 / 秒**（同 `module+message`） | 473 | 超出即丢；第 51 条补一条 `WARNING 日志风暴抑制：短时间内大量重复日志已折叠`（522–526） |
| 窗口 | `stormWindow` | 1.0 s | 476 | 两条防线共用 1s 窗口 |

**结算留痕**（窗口切换时输出折叠统计，避免"静默丢日志"不可审计）：
- `settleStormIfNeeded()`（532–540）→ `INFO 日志风暴抑制结束：重复日志已折叠`（context: key, folded）
- `settleGlobalIfNeeded()`（543–550）→ `INFO 日志全局限流结束：超速日志已折叠`（context: folded, limitPerSecond）

**为什么需要①**：475 行注释原文——「跨键防线：防『多键交替』型自反馈绕过同键折叠」。即自反馈若每轮换 message/context（例如带 index、时间戳），防线②永远命中不了，必须靠全局速率兜底。

**自留痕机制**：两条防线的留痕都走 `appendDirect`（不做折叠判定）而非 `log`，注释 453–454：「直接追加条目（不做折叠判定；供折叠器自身留痕，避免递归）」。

**契约测试**：`testStormFoldSuppressesRepeatedIdenticalLogs:433`、`testGlobalStormFoldCapsTotalRate:453`（用 `stormFoldLimit` / `globalStormLimit` 常量断言，不写死数字）。

### 1.9 日轮转与保留策略

| 机制 | 实现 | 行号 |
|---|---|---|
| 单日文件轮转 | 文件名 `log_<yyyy-MM-dd>.json`；单文件条数上限 `maxEntriesPerFile`（默认 **1000**） | 889 / 399/406 / 900 |
| 保留天数清理 | `applyRetention(reason:)`：`cutoff = startOfDay(今天) - (retentionDays - 1) 天`，逐文件解析日键 `date < cutoff` 即删 | 821–849（cutoff 828–829） |
| 触发时机 | 启动（427 `reason:"启动"`）、保留天数变更（340 `reason:"设置变更"`） | — |
| 执行线程 | `ioQueue.async` 后台扫描；完成后回主线程留痕 `INFO 过期日志已清理`（context: removedFiles/retentionDays/reason） | 825 / 842–847 |
| 目录扫描快照 | `storageSnapshot()`：`Task.detached(priority:.utility)` 统计文件数/字节/日键，`dayKeys.sort(by: >)` | 660–679 |
| 内存上限裁剪 | `applyMaxEntriesLimit()`：`entries = prefix(maxEntries)` + `WARNING 日志超上限已裁剪` | 811–818 |

### 1.10 删除路径与「复活」竞态修复

| 方法 | 行号 | 关键点 |
|---|---|---|
| `removeEntry(id:)` | 685–696 | 内存删除 → `discardPending` → `purgeFromDisk([dayKey: [id]])` → 留痕 `INFO 删除单条日志`（记录被删条目的级别/模块/内容前 60 字） |
| `removeEntries(level:module:query:dayKey:)` | 700–718 | 组合条件删除（「清空当前筛选」「清空今日」），先 `filtered(...)` 再按 `dayKey` 二筛；返回删除数 |
| `discardPending(ids:)` | 722–727 | **从待落盘缓冲剔除**：注释原文「防止『删除后 0.5s 防抖落盘又把该条写回磁盘』的复活竞态（2026-09-28 复核修复）」 |
| `purgeFromDisk(_:)` | 912–938 | ioQueue 后台按日文件重写；`remaining.isEmpty` 则直接删文件；完成后 `DEBUG 磁盘条目剔除完成` |
| `clearAll()` | 730–746 | 清内存 + 清缓冲 + 后台删全部 `log_*.json` + 自留痕 `INFO 清空全部日志` |

测试锚点：`testDeletePendingEntryDoesNotResurrect:473`（注释明确标为「复核修复」）。

### 1.11 损坏条目逐条抢救 `decodeEntries`（996–1015）

```
输入：Data
① 整段解码 [LogEntry] 成功 → (entries, rescued = 0)          // 998
② 否则 JSONSerialization 取 [Any]；失败 → (nil, 0) 表示整体不可解析 // 1001-1003
③ 逐元素 JSONSerialization.data → JSONDecoder.decode
      成功 → append；失败 → rescued += 1 并跳过               // 1006-1013
输出：(entries?, rescued)
```
调用点：`loadFromDisk`（961–964，累加 rescued / corruptedFiles 并在有损坏时发 `WARNING 日志加载完成（含损坏条目抢救）`）、`mergeWrite`（894）、`purgeFromDisk`（923）、`crashWrite`（1063）。
测试锚点：`testCorruptedFileRescuesValidEntries:290`、`testFullyCorruptedFileDoesNotBlockStartup:304`。

### 1.12 崩溃捕获（同步落盘 · 本地日键 · 开关即时生效）

| 步骤 | 实现 | 行号 |
|---|---|---|
| nonisolated 崩溃上下文 | `struct CrashContext { dir, maxPerFile }` + `nonisolated(unsafe) static var crashContext` | 371–376 |
| 开关快照（线程安全） | `crashCaptureEnabledSnapshot` get/set 走 `crashFlagLock` | 382–391 |
| 安装（初始化时始终安装） | `setupCrashCapture()`：`NSSetUncaughtExceptionHandler`（1021–1031）+ 6 个信号 `SIGABRT/SIGILL/SIGSEGV/SIGFPE/SIGBUS/SIGTRAP`（1034–1039） | 1019–1040 |
| **为什么始终安装** | 423 行注释：「崩溃捕获始终安装处理器（写入门由线程安全快照控制）→ 开关运行中即时生效」 | — |
| 信号入口 | `handleCrashSignal(_:)`：先查快照，再 `crashWrite(LogEntry(level:.fatal, module:"crashCapture", …))` | 1043–1051 |
| 同步写入 | `crashWrite(_:)`：**不依赖主线程、不依赖异步队列**；`logFileLock` + 读既有 → 去重 → 倒序 → `prefix(maxPerFile)` → 原子写 | 1054–1073 |
| 日键一致性 | 文件名同样为 `log_\(entry.dayKey).json`（1056），因此崩溃日志可被常规 `loadFromDisk` 直接加载 | — |

域：崩溃日志固定落在 `crashCapture` 域（3 处字面量：LogManager 2 + 测试 1）。
测试锚点：`testCrashWriteUsesLocalDayKeyAndPersists:319`、`testCrashCaptureToggleSnapshotTakesEffect:330`。

### 1.13 查询 / 筛选 / 实时统计记忆化

| 方法 | 行号 | 说明 |
|---|---|---|
| `search(query:in:)` | 589–604 | 空格分隔多关键词 **AND**；命中面 = message + module + 级别英文名 + 级别中文名 + 两种时间格式 + 上下文字段 |
| `filtered(level:module:query:)` | 607–616 | 级别 × 模块 × 关键词组合；注释：「视图与导出共用，纯函数」 |
| `moduleFacets()` | 620–631 | 模块聚合（按次数降序，次数相同按名字升序）；**记忆化键 = 首条 id + 总数**（`facetsCache`，366–367） |
| `stats()` | 635–657 | 总数/今日/今日异常/各级计数/最早最新；同样记忆化（`statsCache`） |

**为什么这样记忆化**（619、634 行注释原文）：视图一帧内多次取用不重复分组/不重复逐条日历判定——**「日志洪峰期保持丝滑」**。键用「首条 id + 总数」而不是内容哈希，是因为列表最新在前，首条 id 变化即代表有新写入，成本 O(1)。
测试锚点：`testModuleFacetsSortedByCount:149`、`testStatsCountsTodayAndIssues:161`。

### 1.14 导出（TXT / JSON）

| 方法 | 行号 | 要点 |
|---|---|---|
| `exportAsText()` | 751–753 | 兼容旧入口，导出全部 |
| `exportText(entries:title:)` | 756–768 | 头部元信息：App 名、范围标题、导出时间、日志总数、最早、最新；正文逐条 `formattedLine` |
| `exportJSON(entries:title:)` | 771–785 | payload: `app / scope / exportedAt(ISO8601) / count / entries[]`；`prettyPrinted + sortedKeys + withoutEscapingSlashes`；失败返回 `"{}"` |
| `export(entries:title:format:)` | 788–793 | 按 `LogExportFormat` 分派 |
| `exportFileName(tag:format:)` | 796–806 | 标签净化（空格→`_`，剔除字母数字与 `_-` 之外字符）+ `yyyyMMdd_HHmmss`；空标签回退 `all`；命名 `sxjzit_logs_<tag>_<stamp>.<ext>` |

`LogEntry.jsonObject`（187–200）字段：`id / timestamp(可读全文) / timestampUnix / level / module / message / context?`——注释说明 `timestampUnix` 是「供脚本分析」而 `timestamp` 面向人读。

### 1.15 「跟随最新」不打断翻阅 —— 机制在 LogListView.swift（跨文件）

本逻辑**不在** LogManager.swift 内（已 grep 确认），而在 `qin/DesignCode/LogListView.swift`：

| 机制 | 行号 | 说明 |
|---|---|---|
| `followLatest` / `pendingNewCount` / `lastSeenTopID` 状态 | 45–47 | 顶部开关 + 累计新日志数 + 上次可见首条 id |
| `isAtTop`（滚动几何判定） | 50（注释 48–49） | 注释原文：「跟随最新仅在此状态下自动滚顶，避免『向上翻阅历史时被新日志反复拽回顶部』的体验侵害（2026-09-28 复核修复）」 |
| 滚顶节流 | 52（注释 51） | 每 0.25s 最多一次，「防动画排队导致抖动」 |
| 新日志到达时的计数器维护 | 252–272 | `onChange(of: logManager.entries.first?.id)`：`if followLatest && isAtTop { pendingNewCount = 0 }`（258–260）否则累加/清零（263–265、270–272） |
| 开关 UI 与留痕 | 318–341 | `INFO 日志域 log「跟随最新切换」`（328）；恢复跟随时 `scrollToTopRequest += 1`（325） |
| 自动滚顶条件 | 567–580 | `onScrollGeometryChange`（567）判定 `contentOffset.y <= 60`（注释说明 12pt 曾误判导致开页即出现胶囊）；`onChange(entries.first?.id)`（572）内 `guard followLatest, isAtTop`（574） |
| 「N 条新日志」胶囊 | 345+ | 暂停/翻阅中累计，点按恢复跟随并滚顶 |
| 帮助文档口径 | `HelpContent.swift:454` | 「跟随与暂停」条目的用户侧说明 |

即：**LogManager 只负责"最新在前 + entries 首元素驱动"，UI 侧用 `isAtTop` 判定把「自动跟随」降级为「只累计提示」**，两者职责分离。

### 1.16 DEBUG 自测钩子（跨文件，实测存在）

| 钩子 | 位置 | 内容 |
|---|---|---|
| `-uiTestOpenLogs` 启动参数 | `TabBar.swift:9995–10019`（`#if DEBUG`(9995) … `#endif`(10019)） | 自动打开日志页（9999）→ 3s/6s 各截一张图（`a_open`/`b_settled`）→ **注入 55 条同内容风暴样本**（10008，`debugLog("log","自测风暴样本")`，55 > `stormFoldLimit`=50，用于验证防线②）→ 2.5s 后截 `c_afterStorm` → 3 次心跳日志（10015）验证主线程持续存活 |
| 自测截图实现 | `TabBar.swift:9905–9951` | 把主窗口画面写入 Documents，全链路留痕（开始/成功/四类失败分支） |
| 截图模式跳过锁屏 | `LogListView.swift:978` | 「DEBUG 自测截图模式（启动参数 `-uiTestOpenLogs`）跳过上锁——避免系统 Face ID 弹窗遮挡取证画面」 |

注意：这四个文件中**没有** `#if DEBUG` 代码块（已 grep 确认 `LogManager/DisplaySettingsManager/CacheModeManager/SJZNetworkMonitor` 均为 0 处）——自测钩子全部落在视图层。

### 1.17 `cleanEmptyFiles` 的归属（与任务前提不符）

`cleanEmptyFiles` **在当前 `LogManager.swift` 中不存在**（全文 grep：0 命中）。它只存在于历史备份：
`qin/DesignCode_backup_20260922/LogManager.swift:236`（调用）与 `:266`（定义 `nonisolated private func cleanEmptyFiles(activeDates:)`）。
历史语义：旧版落盘是「按内存分组**全量重写**每日文件」，重写后把不在 `activeDates` 中的日文件当空文件删除；同时还存在 `performAutoCleanup` 按 `creationDate` 清理。当前版本已改为**追加合并 + 保留天数 + 单文件上限**（§1.6/1.9），因此不再需要「删空文件」，这是对历史缺陷的正面替代，而非遗漏。

### 1.18 LogManager 关键方法行号速查

| 方法 / 属性 | 行号 |
|---|---|
| `shared` / `isRunningTests` / `persistsToDisk` | 276 / 279 / 285 |
| `SettingsKeys` 四键 | 293–298 |
| `entries`（@Published） | 347 |
| `ioQueue` / `saveWorkItem` / `PendingBox` | 351 / 352 / 355–359 |
| `logFileLock` | 363 |
| `statsCache` / `facetsCache` | 366–367 |
| `init(...)` | 395–436 |
| `log(level:module:message:context:)` | 441–451 |
| `appendDirect` | 454–468 |
| `stormFoldLimit` / `globalStormLimit` / `stormWindow` | 473 / 475 / 476 |
| `shouldFold` | 487–529 |
| `settleStormIfNeeded` / `settleGlobalIfNeeded` | 532 / 543 |
| 便捷方法 info/debugLog/warning/error/fatal | 553 / 556 / 559 / 562 / 565 |
| `flushPendingNow` | 572–584 |
| `search` / `filtered` / `moduleFacets` / `stats` | 589 / 607 / 620 / 635 |
| `storageSnapshot` | 660–679 |
| `removeEntry` / `removeEntries` / `discardPending` / `clearAll` | 685 / 700 / 722 / 730 |
| `exportAsText` / `exportText` / `exportJSON` / `export` / `exportFileName` | 751 / 756 / 771 / 788 / 796 |
| `applyMaxEntriesLimit` / `applyRetention` | 811 / 821 |
| `scheduleFlush` / `flush` / `mergeWrite` / `purgeFromDisk` | 853 / 874 / 885 / 912 |
| `loadFromDisk` / `decodeEntries` | 942 / 996 |
| `setupCrashCapture` / `handleCrashSignal` / `crashWrite` | 1019 / 1043 / 1054 |

---

## 2. DisplaySettingsManager（2959 行）— 显示设置单一状态源

### 2.1 全局架构：一个 `@MainActor` 单例 + 三套出口

```
DisplaySettingsManager.shared  (@MainActor, ObservableObject)          // 568-571
   ├─ 出口① 环境值注入（SwiftUI 主链路）
   │     DesignCodeApp.swift:121  .displayTypography(displaySettings)
   │        └─ 写入 6 个自定义 EnvironmentKey + sizeCategory + buttonStyle + saturation
   │     DesignCodeApp.swift:120  .tint(displaySettings.themeStyle.color)
   │     TabBar.swift:283         .preferredColorScheme(resolvedColorScheme)   ← 呈现修饰器，根视图
   ├─ 出口② UIKit 系统渲染面接管（导航栏 / 标签栏）
   │     applySystemChromeAppearance(reason:)  → UINavigationBar/UITabBar 的 appearance 代理 + 既有实例就地刷新
   └─ 出口③ 非隔离快照（后台线程/长图渲染器/WebView）
         typographySnapshot() / articleBodyLightHexSnapshot()  ← 直读 UserDefaults（线程安全）
```

### 2.2 全部设置项清单（存储键 / 默认值 / 行号）★

存储键集中在 573–600；默认值集中在 `init`（852–894）。**共 23 个存储键：21 个设置项 + 2 个历史键**（实测 `grep -c "static let .*Key"` 于 573–600 区间 = 23）；其中 **8 个标 `nonisolated`** 供非主线程直读（579–584、591–592）。另有 `ReadingStatsCache` 的 3 个独立键（2427–2429，见 §2.15.2）。

| # | 设置项 | 存储键 | 键声明行 | 默认值 | 默认值行 | `@Published` 声明行 |
|---|---|---|---|---|---|---|
| 1 | 外观模式 `appearanceMode` | `colorSchemePreference`（复用既有键） | 576 | `.system` 跟随系统 | 857 | 605–607 |
| 2 | 主题色 `themeStyle` | `displayAccentStyle` | 577 | `.blue` 品牌蓝 | 858 | 610–612 |
| 3 | 字体大小档 `fontSizeTier` | `displayFontSizeTier` | 579 | `.medium` 中 | 859 | 615–621 |
| 4 | 粗体文本 `boldTextEnabled` | `displayBoldText` | 580 | `false` | 860 | 624–633 |
| 5 | 使用系统字体 `useSystemFont` | `displayUseSystemFont` | 581 | `true` | 861 | 636–642 |
| 6 | 字体家族 `fontFamily` | `displayFontFamily` | 582 | `.system` 苹方黑体（含历史值迁移） | 862–869 | 645–651 |
| 7 | 行距系数 `lineSpacingFactor` | `displayLineSpacing` | 583 | `1.0` | 870 | 654–656 |
| 8 | 字间距 `letterSpacingValue` | `displayLetterSpacing` | 584 | `0` | 871 | 659–661 |
| 9 | 按钮形状 `buttonShapesEnabled` | `displayButtonShapes` | 585 | `false` | 872 | 664–666 |
| 10 | 屏幕亮度 `brightnessValue` | `displayBrightness` | 586 | `-1`（=未接管，系统自动亮度） | 874–875 | 669–676 |
| 11 | 自动亮度 `autoBrightnessEnabled` | `displayAutoBrightness` | 587 | `true` | 876 | 679–696 |
| 12 | 自动锁定 `autoLockOption` | `displayAutoLock` | 588 | `.m1` 1 分钟 | 877 | 699–709 |
| 13 | 屏幕常亮 `keepAwakeEnabled` | `displayKeepAwake` | 589 | `false` | 878 | 714–727 |
| 14 | 正文文字色预设 `articleTextColorPreset` | `displayArticleTextColorPreset` | 591 | `.system` 跟随系统 | 879 | 738–749 |
| 15 | 自定义正文色 `articleTextCustomHex` | `displayArticleTextCustomHex` | 592 | `"1A1A1A"` 墨黑 | 880 | 752–757 |
| 16 | 阅读统计总开关 `readingStatsEnabled` | `displayReadingStatsEnabled` | 593 | `true` | 881 | 774–776 |
| 17 | 正文字数开关 `readingCharCountEnabled` | `displayReadingCharCountEnabled` | 594 | `true` | 882 | 779–781 |
| 18 | 阅读时长开关 `readingTimeEnabled` | `displayReadingTimeEnabled` | 595 | `true` | 883 | 784–786 |
| 19 | 列表徽标开关 `readingListBadgeEnabled` | `displayReadingListBadgeEnabled` | 596 | `true` | 884 | 789–791 |
| 20 | 阅读速度档 `readingSpeedTier` | `displayReadingSpeedTier` | 597 | `.standard` 标准 | 885 | 794–796 |
| 21 | 专注灰度 `grayScaleEnabled` | `displayGrayScaleMode` | 598 | `false` | 886 | 799–808 |
| 22 | 自定义色历史 `customColorHistory` | `displayCustomColorHistory` | 599 | `[]`（JSON 解码） | 887–890 | 827 |
| 23 | 变更时间轴 `changeHistory` | `displayChangeHistory` | 600 | `[]`（JSON 解码） | 891–894 | 829 |

**只读监听（不持久化）**：`systemReduceMotion` / `systemReduceTransparency` / `systemDarkerColors` / `systemVoiceOverRunning`（818–822），由 `refreshSystemAccessibilityState()`（962–967）+ 5 个系统通知监听（970–984，含 `didBecomeActive` 校准）+ 低电量模式通知（982–983、987–993）刷新。

**派生量**：
- `nonDefaultChangeCount`（1146–1168）= 与默认值不同的项计数，**19 项**（不含 `brightnessValue`/`articleTextCustomHex`/两个历史），供 Hero 徽章与设置入口摘要徽标；
- `isDefault`（1171–1191）= 同 19 条件的与运算，注释明确「清单与 isDefault 严格一致」；
- `resetAll()`（1194–1221）= 22 项回落 + 清空两个历史 + `applyIdleTimer()` + 留痕 `INFO 恢复默认显示设置`。

### 2.3 枚举体系（“设置项取值域”）

| 枚举 | 行号 | 取值数 | 备注 |
|---|---|---|---|
| `DisplayAppearanceMode` | 33–55 | 3（system/light/dark） | `resolvedColorScheme` 返回 `ColorScheme?`（48） |
| `DisplayThemeStyle` | 60–85 | 5 | 每色给「浅/深」双 hex（76–84），与全校品牌色系一致 |
| `ArticleTextColorPreset` | 91–151 | 9（system + 7 预设 + custom） | 浅色/深色双 hex 表（125/139）；「跟随系统」= 不覆盖（90 行注释） |
| `ReadingSpeedTier` | 156–194 | 3 | 中文 200/300/450 字/分（178）、英文 150/220/300 词/分（187） |
| `DisplaySchemePreset` | 199–286 | 3（阅读舒适/紧凑高效/护眼大字） | 一键套用 **6 项**排版值：字号档(239)/行距(247)/字距(255)/粗体(263)/系统字体(271)/家族(279)，注释标「测试断言依据」 |
| `DisplayFontSizeTier` | 368–407 | 6（tiny…max） | `scale` 0.85/0.94/1.0/1.12/1.26/1.40（385）；`contentSizeCategory` 中档返回 nil（397，不覆盖系统 Dynamic Type） |
| `DisplayFontFamily` | 414–525 | 7（system/songti/kaiti/yuanti/xingkai/libian/weibei） | 见 §2.5 |
| `DisplayFontAvailability` | 532–542 | 3 态 | `ready` / `downloading(percent: Double?)`（nil=不确定态）/ `unavailable`；`isReady`（538） |
| `DisplayAutoLockOption` | 547–563 | 7（30s/1m/2m/5m/10m/15m/永不） | 「永不」经 `isIdleTimerDisabled` 真实生效 |
| `DisplayHistoryOperator` | 303–316 | — | 纯算子：`pushColor`（规范化→置顶去重→截断 6）、`appendChange`（新在前→截断 20） |
| `DisplayContrastChecker` | 322–363 | — | WCAG 2.x：sRGB 线性化亮度（340）、对比度 (L亮+.05)/(L暗+.05)（349）、分级 ≥4.5 合规 / ≥2.5 建议 / 否则不合格（358） |

### 2.4 存储键的线程安全读取（非隔离快照）

- 8 个键标 `nonisolated private static let`（579–584、591–592），注释（578、590）说明「非隔离排版快照函数直读（UserDefaults 线程安全；2026-09-29 全局覆盖）」。
- `typographySnapshot()`（1814–1831）：返回 `TypographySnapshot{family, scale, bold, lineSpacingFactor, letterSpacing}`，供**长图等后台渲染上下文**使用，注释（1804–1805）明确动机：「避免跨 actor 访问 @MainActor 单例；与 `articleBodyLightHexSnapshot` 同范式」。
- `articleBodyLightHexSnapshot()`（1126–1141）：返回 `(presetRaw, hex)`，非法/未知值回退 `1a1a1a`。

### 2.5 字体家族契约（`DisplayFontFamily`，7 家族）

| 维度 | 行号 | 内容要点 |
|---|---|---|
| 可选中文字体集 | 411–415 | 注释原文：全部为 iOS 内置**中文全字形**家族——「西文字体不含中文字形会导致中文全部回退苹方、切换毫无变化——历史教训」 |
| `fontName`（PostScript 字面名） | 446–461 | `PingFang SC` / `STSongti-SC-Regular` / `STKaitiSC-Regular` / `STYuanti-SC-Regular` / `STXingkaiSC-Light` / `STLibianSC-Regular` / `WeibeiSC-Bold`。**关键契约**（447–450 注释）：系统按需下载的匹配引擎**只认 PostScript 字面名**，传家族名（如 `"Songti SC"`）会「`didBegin → didFinish` 静默完成且不下载任何资产」，表现为界面永远停在「下载中」直到看门狗复位（2026-09-27 真机 A/B 实证） |
| `boldFontName` | 464–474 | 真实粗体字面表；`libian`/`weibei`/`system` 为 nil → 回退主字面合成加粗 |
| `cssFamilyName` / `cssLocalizedFamilyName` | 478–501 | CSS 按**家族名**匹配（476–477 注释：2026-09-29 真机反馈修复——WebView 正文此前永远默认，根因即只给字面名）；另备中文本地化名候选 |
| `downloadFaceNames(includeBold:)` | 504–511 | 主字面 +（需粗体时）粗体字面，去重；`system` 返回 `[]` |
| `normalized(rawValue:)` | 514–524 | 历史值迁移：`serif/georgia→宋体`、`rounded→圆体`、`palatino→楷体`、`avenir→系统`，未知回退系统 |

### 2.6 `DisplayFontFactory` / `DisplayUIFontFactory` — 字体工厂

| 工厂 | 行号 | 策略 |
|---|---|---|
| `DisplayFontFactory.font(size:weight:scale:family:bold:)` | 1745–1765 | `resolvedSize = size * scale`；`system` → `.system(size:weight:)`；自定义家族：**若开启粗体且真实粗体字面已就绪 → 直接用粗体字面**（1744 行注释：「中式字形合成加粗观感差」），否则 `.custom(fontName, size:).weight(...)` 回退 |
| `DisplayUIFontFactory.uiFont(size:weight:scale:family:bold:)` | 1772–1799 | 同源策略但产出 `UIFont`，供 **UIKit 绘制的系统渲染面**（导航栏标题 / Tab 标签）；字面不可用时回退 `systemFont`（1788–1791）；`weight >= semibold` 也按粗体处理（1792–1794）。注释（1769–1771）：SwiftUI 的 `display*` 修饰器**物理上无法触及** UIKit 绘制的栏；系统弹窗遵循 HIG 不接管 |

### 2.7 字体按需下载 + 60s 无进展看门狗 ★

```
ensureFontFamily(_:reason:)                                       // 1253
  ├─ refreshFontAvailability()                                    // 1255
  ├─ wanted  = family.downloadFaceNames(includeBold: boldTextEnabled)   // 1256
  ├─ missing = wanted.filter { UIFont(name: $0, size: 17) == nil }      // 1257（实查，不信系统回调）
  ├─ 无缺失 → DEBUG「字体家族已就绪」并返回                        // 1258-1265
  ├─ 在途防重入（inFlightFontDownloads）→ DEBUG「已在途，忽略重复触发」 // 1266-1272
  ├─ 令牌：fontDownloadTokens[family] = UUID()                     // 1273-1274
  ├─ fontDownloadLastProgress[family] = now；清进度分档            // 1276-1277
  ├─ 状态置 .downloading(percent: nil)                             // 1278
  ├─ INFO「字体按需下载开始」(family/faces/includeBold/reason)      // 1279-1285
  ├─ CTFontDescriptorMatchFontDescriptorsWithProgressHandler       // 1287-1297（一次调用合并多字面）
  └─ 看门狗 Task（每 5s 轮询）                                      // 1299-1308
```

**看门狗语义（本文件最精细的设计之一）**：

| 参数 | 值 | 行号 |
|---|---|---|
| `fontDownloadStallSeconds` | **60 s** | 1247 |
| `fontDownloadWatchdogTickSeconds` | **5 s** | 1249 |
| 判定基准 | **「最近一次系统进度回调时间」**而非起跑时间 | 1244–1246 注释原文 |
| 为什么 | 「系统仍在报进度就不判超时（**行楷-简实测资产 54.7MB，慢网耗时远超 60s**）；连续无进展才复位为『未下载·可重试』」；「2026-09-27 由绝对时长语义升级为『无进展』语义」 | 1244–1246 |
| 令牌校验 | `fontDownloadTokens[family] == attemptToken` 才生效——「超时与迟到回调只作用于同一次尝试，杜绝误伤重试中的新下载」 | 843、1302 |

**进度回调状态机 `handleFontMatchingCallback`（1332–1392）**：

| 系统状态 | 处理 | 行号 |
|---|---|---|
| `.didBegin` | DEBUG「字体匹配开始」 | 1343–1347 |
| `.willBeginQuerying` | **break（不记日志）**——注释：「瞬时态，无用户可感信息，避免日志噪声」 | 1348–1349 |
| `.willBeginDownloading` | INFO「字体资产开始下载」+ 本地化家族名/资产数/总字节 | 1350–1356 |
| `.downloading` / `.stalled` | 取 `CTFontDescriptorMatchingPercentage`；**进度变化 <1% 不刷新 UI（防高频重渲染）**（1361–1363）；日志 **每 25% 一档**（`fontDownloadProgressBucket`，1365–1376）。注释：`.stalled` 是系统分块间隙的正常回传，**不视为异常**（1358） | 1357–1376 |
| `.didFinishDownloading` | INFO「字体资产传输完成，等待系统安装生效」 | 1377–1381 |
| `.didMatch` | INFO「字体字面匹配成功」 | 1382–1383 |
| `.didFailWithError` | `finalize(..., outcome: .failed)` | 1384–1385 |
| `.didFinish` | `finalize(..., outcome: .finished)`——注释：**「didFinish 在『匹配成功』与『无匹配静默完成（历史家族名缺陷形态）』两种情形都会回传——必须以实查判定成败」** | 1386–1388 |

**终态收尾 `finalizeFontDownload`（1402–1472）** 三种 outcome 共用一条「实查自愈」路径：

```
清令牌 / 在途 / 进度基准 / 进度分档                                  // 1408-1412
primaryReady = UIFont(name: family.fontName, size: 17) != nil        // 1415（实查自愈：覆盖"下载完成与终态回调之间的空窗"）
boldReady    = boldFace.map { UIFont(name: $0, size: 17) != nil }    // 1416-1417
.stalled : primaryReady → .ready + typographyRevision += 1 + INFO「停滞但实查已就绪（自愈）」
           否则 → .unavailable + INFO「字体下载停滞超时，已转为可重试状态」
                  （注释 1430-1431：状态流转而非待处理异常；警告栏只留真异常，用户入口由橙色徽章呈现）
.failed  : primaryReady ? (.ready + revision+1) : .unavailable，WARNING「字体按需下载失败（可点击重试）」
.finished: primaryReady → .ready + revision+1 + INFO「字体按需下载完成并已全局生效」
           否则 → .unavailable + WARNING「字体匹配结束但未取得字面（可点击重试）」
                  （hint：PostScript 字面名或系统目录不匹配；已复位为可重试）
```

诊断信息 `fontMatchingDiagnostic`（1475–1485）：取 `CTFontDescriptorMatchingError` / `...Result`，`NSError` 格式化为 `[domain code] desc`，文本截断 300 字符。
批量入口 `ensureAllFontFamilies(reason:)`（1312–1329）：对全部未就绪家族各发起一次（独立进度与独立重试）；调用点 `DisplaySettingsView.swift:696`（画廊「全部下载」）。
**全局生效链**：`typographyRevision`（838–840，`didSet` 触发 `applySystemChromeAppearance`）→ 写入环境值（2076）→ 所有 `display*` 修饰器读取建立依赖（1993、2045）→ 全文重算字体。

### 2.8 `applyRuntimeEffects`（948–959）与其「全局生效」真实边界

```swift
func applyRuntimeEffects() {                                       // 948
    if !autoBrightnessEnabled && brightnessValue >= 0 {
        activeScreen?.brightness = CGFloat(brightnessValue)        // 950 亮度接管
    }
    applyIdleTimer()                                               // 952 防息屏
    LogManager.shared.debugLog("display", "运行时效果应用（亮度/inidle timer）", context: [...])
}
private func applyIdleTimer() {                                     // 730-732
    UIApplication.shared.isIdleTimerDisabled = keepAwakeEnabled || autoLockOption == .never
}
```

- `activeScreen`（940–945）：替代已弃用的 `UIScreen.main` —— 优先 `foregroundActive` 场景 → 任意非 `unattached` 场景 → 首个场景。
- **调用点唯一**：`init` 第 900 行「启动即恢复运行时效果（亮度接管 / 防息屏）」（已 grep 确认全仓无第二个调用点）。
- 变更时**不**走 `applyRuntimeEffects`，而是各 `didSet` 直接生效：`brightnessValue.didSet`（672–674 直接写 `activeScreen?.brightness`）、`autoBrightnessEnabled.didSet`（682–693：开启=交还系统并记 `-1`，关闭=以当前系统亮度为起点；找不到屏幕时 `WARNING 手动接管亮度时未找到可用场景屏幕`）、`autoLockOption`/`keepAwakeEnabled` 各自调用 `applyIdleTimer()`。
- 因此「applyRuntimeEffects 的全局生效机制」准确表述是：**它是启动期的一次性补偿入口，运行期生效靠属性 `didSet` 单点直写**；而排版/外观的全局生效靠环境值注入（§2.9），两者不是同一条链。

### 2.9 全局排版注入：6 个 `EnvironmentKey` + 根修饰器

| 环境键 | 定义行 | 默认值 | 写入点 |
|---|---|---|---|
| `displayFontScale` | 1684–1686 / 1709 | 1.0 | 2071 |
| `displayBold` | 1688–1690 / 1714 | false | 2072 |
| `displayFontFamily` | 1692–1694 / 1719 | `.system` | 2073 |
| `displayLetterSpacing` | 1696–1698 / 1724 | 0 | 2074 |
| `displayLineSpacing` | 1700–1702 / 1729 | 1.0 | 2075 |
| `displayTypographyRevision` | 1704–1706 / 1734 | 0 | 2076 |

`DisplayTypographyModifier.body`（2065–2083）一次注入：

```
.environment(\.displayFontScale,   manager.fontSizeTier.scale)
.environment(\.displayBold,        manager.boldTextEnabled)
.environment(\.displayFontFamily,  manager.useSystemFont ? .system : manager.fontFamily)
.environment(\.displayLetterSpacing, manager.letterSpacingValue)
.environment(\.displayLineSpacing, manager.lineSpacingFactor)
.environment(\.displayTypographyRevision, manager.typographyRevision)
.environment(\.sizeCategory, manager.fontSizeTier.contentSizeCategory ?? systemSizeCategory)   // 2077
.shapedButtonStyle(enabled: manager.buttonShapesEnabled)                                        // 2078
.saturation(manager.grayScaleEnabled ? 0 : 1)                                                   // 2080
.animation(.easeInOut(duration: 0.4), value: manager.grayScaleEnabled)                          // 2081
```

挂载点**唯一**：`DesignCodeApp.swift:121`（`.displayTypography(displaySettings)`，紧跟 `120: .tint(displaySettings.themeStyle.color)`）。
`shapedButtonStyle`（2087–2096）用 `@ViewBuilder` 分支而非 `AnyButtonStyle` 类型擦除（2085 行注释说明原因）。

### 2.10 `displayText` 文本处理管线（含 5 个修饰器族）

| 修饰器 | 定义行 | 对外 API | 作用 |
|---|---|---|---|
| `DisplayTextModifier` | 1979–1999 | `View.displayText(size:weight:baseLineSpacing:)`（2003–2005） | 字号 × 档位缩放 + 粗体 + 家族 + `.tracking` + **动态行距**：`lineSpacing(baseLineSpacing + (lineSpacing - 1.0) * size * scale)`（1997） |
| `DisplayScaledFontModifier` | 2029–2062 | `displayFont`（2013，三态 text）、`displaySymbolFont`（2018，symbol）、`displayLabelFont`（2023，label） | **三种应用策略分离**：文本→家族+粗体；SF Symbol→仅缩放（「不应用家族，保证图标正常渲染」，2017）；Label→缩放+粗体但不用自定义家族（「保护 systemImage 图标」，2022） |
| `DisplayTypographyModifier` | 2065–2083 | `displayTypography(manager)`（2008） | 全局环境注入（§2.9） |
| `SJZPresentationChromeModifier` | 2105–2114 | `sjzPresentationChrome()`（2118） | 跨 presentation 双注入（§2.11） |
| `DisplayShapedButtonStyle` | 2125–2141 | 由 `shapedButtonStyle` 条件挂载 | 胶囊边框 + `.ultraThinMaterial` + 按压 0.6 / 禁用 0.45 透明度 |

修订号依赖：两个修饰器都在 `body` 内 `_ = revision`（1993、2045），注释：「读取修订号建立依赖：字体按需下载完成后 revision 变化 → 重算字体即时全局生效」。

**使用规模（grep 实测，`qin/DesignCode/` 生产代码；含定义行各 1 处）**：
`displayFont(` **1281** 处（→ 1280 调用点）、`displaySymbolFont(` **554**（→ 553）、`displayLabelFont(` **226**（→ 225）、`displayText(` **20**（→ 19）、`displayTypography(` **2**（→ 1 调用点）。
`displayText` 调用文件分布：DisplaySettingsView 9、WeChatIntegrationViews 6、TabBar 1、PrivacyPolicyView 1、AnnouncementDetailView 1。

### 2.11 跨 presentation 注入：`sjzPresentationChrome()` 与「专注灰度双注入」★

**为什么必须二次注入**（2100–2104 行注释原文）：`.preferredColorScheme` 与 `.saturation` 属「**呈现/渲染修饰器**」而非环境值；根视图（MainTabView）上的注入链**不会作用于 presentation 内容**。其余设置均为环境值（`.tint`、6 个自定义键、`.buttonStyle`）会自动传播进弹出层，无需重复挂载。系统分享面板属系统 UI，不在承诺范围。

| 注入点 | 位置 | 注入内容 |
|---|---|---|
| 根（主链路） | `TabBar.swift:283` | `.preferredColorScheme(resolvedColorScheme)` |
| 根（灰度 + 排版） | `DesignCodeApp.swift:121` → 2080 | `.saturation(grayScaleEnabled ? 0 : 1)` |
| 每个 sheet / fullScreenCover 内容根 | `sjzPresentationChrome()`，**67 处调用点 / 13 个视图文件**（定义在 2118） | `.preferredColorScheme(...)` + `.saturation(...)` + 同一 0.4s 动画 |

调用点分布（`grep -rc` 行数，含定义 1）：TabBar 32、OrganizationDetailView 8、SchoolProfileView 7、PrivacyPolicyView 3、PartySubjectView 3、MessageCenterView 3、LogListView 3、WeChatIntegrationViews 2、BookmarkListView 2、OrganizationView 1、LogSettingsView 1、HelpGuideView 1、CampusCalendarView 1（+ 定义文件 DisplaySettingsManager 1）。
注释标注为「**每个内容级 sheet / fullScreenCover 内容根都必须挂载本修饰器**（2026-09-27 全链审计固化）」——即这是一个**强制项**，遗漏即灰度为 0 的层会逃逸。部分 sheet 另叠加显式 `.preferredColorScheme(resolvedColorScheme)`（例：`TabBar.swift:9970–9984`）。

### 2.12 文章正文色解析与 WebView CSS 注入

| 成员 | 行号 | 说明 |
|---|---|---|
| `articleCustomHexNormalized` | 1013–1017 | 去杂字符、校验 6 位 hex，非法回退 `1A1A1A` |
| `articleBodyColor: Color?` | 1021–1030 | `nil` = 跟随系统（各渲染点保持原有语义色，「现状不变」）；预设色自动适配明暗；自定义色单色直用（「所见即所得」） |
| `articleCSSTextLightHex` / `…DarkHex` | 1033–1048 | WebView CSS 用；注释 1032：长图为白底渲染，同样使用浅色值 |
| `articleCSSFontFamily` | 1060–1066 | **家族名优先 + 字面名 + 本地化名 + 系统栈兜底**的 CSS 字体栈 |
| `articleCSSCurrentFamilyName` | 1069–1071 | `document.fonts.check` 探针用（与栈首候选一致） |
| `articleCSSFontSize` | 1074 | `16 × fontSizeTier.scale`（与 SwiftUI `.displayText(size: 16)` 同口径） |
| `articleCSSLineHeight` | 1077 | `0.85 + lineSpacingFactor`（系数 1.0 → 1.85） |
| `articleCSSLetterSpacing` / `articleCSSFontWeight` | 1080 / 1083 | 与 `.tracking` 同值同单位 / 粗体 700 否则 400 |
| `articleCSSTypographyDeclaration` | 1087–1096 | 一行式 5 属性，**每项 `!important`** |
| `articleCSSTypographyRuleBlock` | 1100–1102 | `body, body * { … }` —— 注释：官网原文把字体写在元素内联 style / `<font>` 上，**继承不敌直接声明**，必须后代全选 + `!important` |
| `articleCSSLiveInjectionPayload` | 1106–1108 | 追加 `/* r<typographyRevision> */` 注释：revision 变化 → 载荷变化 → `updateUIView` 重注入并强制重绘 |
| `articleCSSTypographyLogContext` | 1111–1121 | 两处注入模板共用的完整埋点字典 |

WebView 侧注入实现与埋点（**跨文件**）：`OrganizationDetailView.swift:5013`（首注，logTag `机构文章`）、`:5029 injectTypography(...)`、`:5433`（实时重注）、`:5561`（logTag `原文浏览`）、`:5718`（实时重注）。

### 2.13 变更时间轴与自定义色历史

| 机制 | 行号 | 说明 |
|---|---|---|
| `recordChange(field:fieldTitle:value:)` | 1504–1508 | 新记录插头部 → `DisplayHistoryOperator.appendChange` 截断 **20** |
| `scheduleHistorySave()` | 1511–1518 | `DispatchWorkItem` **0.5s 防抖**（「避免滑块等高频输入刷盘」，仿 LogManager） |
| `persistHistories()` | 1520–1527 | 两个 history 各 JSONEncoder → UserDefaults |
| `log(_:_:)`（私有统一入口） | 1674–1679 | 先 `DEBUG「显示设置变更」`，再按 `changeDescription` 映射决定是否入时间轴 |
| `changeDescription(field:rawValue:)` | 1631–1672 | 15 个字段键 → 中文(标题, 文案)：appearance/theme_style/font_size_tier/bold_text/use_system_font/font_family/button_shapes/auto_lock/reading_stats/reading_char_count/reading_time/reading_list_badge/reading_speed/auto_brightness/gray_scale（未知键返回 nil 不入轴） |
| 自定义色历史 | `pushColor` 1572–1581 / `clearCustomColorHistory` 1583–1589 / `clearChangeHistory` 1591–1597 | 最近 6 色 / 清空留痕 |
| 摘要分享 | `shareSummaryText()` 1600–1622 | 14 行中文配置摘要（含亮度、常亮、灰度） |
| 滑块留痕 | `logSliderSettled(_:_:)` 1487–1499 | `DEBUG「滑块调整完成」` + 按字段（line_spacing / letter_spacing / brightness）入时间轴 |
| 自定义色节流 | 760–769 | 拖动色盘 **0.5s 节流**（`lastCustomColorLogAt`）——「避免日志刷屏」 |

一键套用 `applyScheme(_:)`（1533–1569）：记录 6 项 before/after 全量 context（1548–1563）→ 若引入的新家族未就绪则 `ensureFontFamily(reason:"scheme_apply")` → 返回 Toast 文案。

### 2.14 系统渲染面接管（导航栏 / 标签栏）

| 成员 | 行号 | 说明 |
|---|---|---|
| `lastChromeSignature` | 1838 | 签名门控：家族/档位/粗体三要素未变化时跳过重刷（「防启动期重复调用刷屏」） |
| `applySystemChromeAppearance(reason:)` | 1844–1891 | ① 先**解析字体**再生成签名——注释（1849–1852）：字体资产按需下载期间工厂回退系统字体，旧签名（仅家族\|档位\|粗体）对「就绪态变化」不敏感，会把下载完成后的重刷误判为无变化；签名纳入解析后字体名/字号即可感知。② `applyChromeToProxies`（1894–1914，覆盖之后**新建**的栏）③ `applyChromeToExistingBars`（1918–1973，场景内**既有**实例：复制现外观后仅重写字体属性，「不动背景/材质，规避视觉回归」）④ **延迟补刷** 0.35s + 0.85s 各一次（1879–1890，注释：SwiftUI 会在屏幕更新周期重设栏外观） |
| 遍历方式 | 1960–1971 | 递归 `walk(rootViewController)`：`UINavigationController` / `UITabBarController` + `children` + `presentedViewController`，返回 `(nav, tab)` 计数并埋点 |
| 接管规模（注释口径） | 1840 | 「导航栏标题 **62 处** + Tab 标签 **5 枚**，一处生效」 |
| 字体规格 | 1853–1855 | 标题 17 semibold / 大标题 34 bold / Tab 项 10 medium（均乘档位系数） |

### 2.15 阅读统计域（字数 + 阅读时长）：计算 → 缓存 → 服务 → 视图 ★

#### 2.15.1 口径（`ReadingStatsCalculator`，2157–2384）

**字数口径 A（全程一致，2146–2150 注释）**：展示「全文共 X 字」= 中文字符数 + 英文单词数之和。
- 中文按「字」计（Unicode 范围见 `isCJK` 2211–2222：CJK 统一表意 `0x4E00-0x9FFF`、扩展 A `0x3400-0x4DBF`、假名 `0x3040-0x30FF`、韩文 `0xAC00-0xD7A3`、兼容表意 `0xF900-0xFAFF`），**已剔除全部中英文标点与空白**；
- 英文按「词」计：CJK 字符替换为空格后切分，保证「你会说English吗」= 4 字 + 1 词**不粘连**；
- 词内标点 `'`、`-`、`_` 仅延续已有词，孤立出现不构词（2230–2234）；
- 单趟 `unicodeScalars` 扫描（2187–2208）；
- **公示自洽**：展示字数 ÷ 对应速度 ≈ 展示分钟（高估取向，保守取值）。

**时长口径（2152–2156 注释）**：`分钟 = 中文字数/速度 + 英文词数/速度 + 图片耗时 + 代码块耗时`

| 参数 | 值 | 行号 |
|---|---|---|
| 中文默认速度 | 300 字/分（「成人默读 300–500，取保守值，宁可高估」） | 2173 |
| 英文默认速度 | 220 词/分（Medium 265 / Substack 200 之间取偏保守） | 2175 |
| 首张图片 | +12 s | 2177 |
| 图片递减步长 | −1 s/张，最低 **3 s** | 2179 / 2181 |
| 每个代码块 | +30 s（「代码阅读速度约为正文一半」） | 2183 |
| 取整 | `max(1, Int(ceil(raw)))`；**正文非空时至少 1 分钟** | 2283 |
| 空文本 | 返回 `nil`（不展示），**优先级高于「不低于 1 分钟」兜底** | 2246–2250 |
| ≥70 分钟 | 转「约 X/Y 小时」（0.5 步进，「避免过度精确」） | 2297–2307 |
| 列表角标 | ≥60 分钟转「X 小时」（0.5 步进） | 2310–2316 |

**预处理**：
- `stripMarkdown`（2321–2362）：① 围栏代码块 ```` ```[\s\S]*?``` ```` 计数并替换 ② 图片 `!\[…\]\(…\)` 计数并替换 ③ 链接 `[text](url)` → `text` ④ 行首引用/列表符 ⑤ `# * _ \`` 直接替换为空格。
- `stripHTML`（2367–2383）：`<img`、`<pre`（无 `<pre>` 时回退独立 `<code`）正则计数 + `html.strippingHTMLTagsFast()` 剥离。**诚实口径注释**（2365–2366）：「富文本附件在 SwiftUI 的 AttributedString 中难以可靠枚举，采用源码正则统计；若原始 HTML 不可得，调用方应传 nil / 纯文本并接受图片数、代码块数为 0」。
- 输入类型 `ArticleReadingTextSource`（2682–2686）：`.plain(text, imageCount, codeBlockCount)` / `.markdown(text)` / `.html(html, knownImageCount:)`。

#### 2.15.2 持久化缓存（`ReadingStatsCache`，2392–2551）

| 项 | 值 | 行号 |
|---|---|---|
| 持久化键 | `readingStatsCache`（分量表）/ `readingStatsLastResolved`（最近快照）/ `readingStatsDiag`（诊断计数） | 2427 / 2428 / 2429 |
| 容量 | **500** 条 | 2430 |
| 条目结构 | `Entry{chineseChars, englishWords, imageCount, codeBlockCount}` + `totalCount` | 2395–2401 |
| **关键设计** | 缓存按**原始分量**存储（字数/图片/代码块），速度档位变化时**按分量重算分钟**，因此「档位切换不会导致旧缓存失真」（2390–2391 注释） | — |
| 淘汰 | **真 FIFO**：`insertionOrder` 队列 + 「修复原实现依赖 Dictionary 无序键集的缺陷」（2433、2523–2530） | — |
| 惰性加载 | `loadIfNeeded()`（2444–2463），首次访问才解码，`isLoaded` 门控 | — |
| 最近快照 | `LastResolved{id,totalCount,minutes,at}`（2404–2409）；`lastResolvedDescription`（2466–2471）供设置页状态胶囊 | — |
| 诊断计数 | `Diagnostics{mounted, resolveAttempts, lastMountedAt, lastResolveAt, badgeMounted, lastBadgeMountedAt, badgeComputed, lastBadgeComputedAt}`（2412–2423），4 个 `record*` 方法（2474/2481/2489/2497）**即时持久化**，注释：跨启动/覆盖安装保留，仅卸载重装清零 | — |
| 快照分钟近似 | `guessMinutes`（2543–2550）按**标准速度**近似，「仅供状态展示，精确值由展示组件重算」 | — |

#### 2.15.3 业务入口（`ReadingStatsService.resolve`，2565–2678）

```
recordResolveAttempt() + DEBUG「统计计算请求开始」(id/startedAt/attempt)   // 2570-2576
guard settings.readingStatsEnabled else { return nil }                     // 2578（总开关，先于一切计算）
① 缓存命中（cachedID 非空且 entry 存在）：用缓存分量 + 当前档位速度重算分钟 → DEBUG「阅读统计缓存命中」→ return   // 2583-2606
② 预处理：plain / markdown / html（html 时 knownImageCount 优先，否则 <img 正则）  // 2609-2620
③ 超长文本（> 50_000 字符）→ Task.detached(priority: .utility) 计算 + DEBUG「超长正文转入后台统计」；否则同步  // 2629-2650
④ 写缓存（仅当有 id）+ INFO「阅读统计计算完成」(chars/words/images/codeBlocks/minutes/startedAt/finishedAt/elapsedMs)
```

`backgroundThreshold = 50_000`（2559），注释：「10 万字符级正文不阻塞 UI」。
毫秒级埋点由 `ReadingStatsClock`（19–28）提供（`HH:mm:ss.SSS`，与 `LogEntry.formattedTime` 同格式）；另有一条 **`os.Logger` 系统控制台直出**（15 行 `Logger(subsystem: "com.qinchao.designcode", category: "ReadingStats")`，在 2768 调用，注释：可在 Xcode Console 按 category 过滤实时观测）。

#### 2.15.4 展示组件（两个「恒存锚点容器」教训）

| 组件 | 行号 | 要点 |
|---|---|---|
| `ArticleReadingStatsText` | 2694–2810 | 详情页 meta 行；`ZStack` + `Color.clear.frame(0,0)` **恒存锚点**（2713–2716 注释：生命周期修饰符若挂在条件 `Group` 上，条件为假时修饰符永不触发 → `result` 恒 nil → 「永不显示」死锁）。渲染条件：总开关 && result && （字数 || 时长）（2720–2722）；`.task(id: cachedID)`（2746）+ `.onChange(readingSpeedTier)` 重算（2749）；VoiceOver 合并为单标签（2742–2743、`accessibilityText` 2799–2809） |
| └ 渲染路径留痕 | 2764–2797 | 计算后落「统计行即将渲染」或 `WARNING 统计已计算但字数/时长开关均关闭，行不渲染` 或 `WARNING 统计结果为空`（含 sourceLength/statsEnabled）——「与 UI 表现逐一对应」 |
| `ReadingDurationTier` | 2815–2852 | 4 档：quick ≤4 / standard 5–9 / longRead 10–19 / deepRead ≥20 分钟；配色 绿/蓝/橙/紫（sjzGreen/sjzAccent/sjzOrange/sjzPurple） |
| `ReadingTimeBadgeView` | 2860–2960 | 缩略图角标「⏱ 9分钟」；**两级数据源**：① 全文缓存优先（详情页写入，最准确）② 无缓存时用列表摘要**同步估算**（微秒级，不写缓存不落盘）③ 皆无则不显示——「列表滚动零异步任务、零卡顿」（2855–2857 注释）；同样恒存锚点（2872–2876）；挂载采样日志每 20 次一条（2901）；刷新日志按 `source:minutes` 变化去重（2944–2959） |
| 规范 | 2858–2859 | 图标 8pt · 字号 10 · 圆角 Capsule · 内边距 H5.5/V2 · 实心分级色底 · 白字 · 高光描边 · 柔和阴影 |

---

## 3. CacheModeManager（455 行）— 缓存模式管理器

### 3.1 三种「用户可感知模式」的真实结构（与任务前提的差异）

任务描述为「三种缓存模式（智能缓存/数据节省/图片免流量）」。源码实际结构是 **2 个互斥枚举 + 1 个正交布尔开关**：

```
enum CacheMode { case instant = "instant"; case cached = "cached" }      // 51-52
@Published var mode: CacheMode                                           // 179
@Published var imageFreeModeEnabled: Bool                                // 192  ← 独立开关，非枚举成员
```

`CacheModeSettingsView.swift:148` 明确其优先级：「**无图模式优先于缓存模式生效：图片请求完全不起网络**」。
因此 Wiki 应表述为：**"即时刷新 / 缓存模式" 二选一 × "无图模式" 可叠加**，共 4 种组合、3 种典型用户态。**该前提需在 Wiki 中修正**。

| 模式 | rawValue | 标题/图标 | 语义（源码文案） | 行号 |
|---|---|---|---|---|
| 即时刷新 | `instant` | 即时刷新 / `bolt.fill` | 「每次浏览实时加载最新内容，确保数据始终是最新的。适合网络畅通时使用。」/「实时加载 · 始终最新」 | 57–85 |
| 缓存模式 | `cached` | 缓存模式 / `archivebox.fill` | 「已浏览的内容将自动缓存到本地，再次访问时无需网络加载，秒开呈现。节省流量，提速明显。」/「智能缓存 · 省流量 · 秒开」 | 57–85 |
| 无图模式（独立） | — | `leaf.fill`/`photo.fill` | 「开启后全局跳过静态图片加载（正文/列表/画廊统一渲染优雅占位），**视频播放与正文文字不受影响**」 | 190–191 |

### 3.2 存储键（165–175）

| 键 | 常量 | 用途 | 加载行 | 持久化行 |
|---|---|---|---|---|
| `cacheMode` | `modeKey` | 模式（默认 `instant`） | 226 | 181 |
| `cacheImageFreeMode` | `imgFreeModeKey` | 无图模式（默认 `false`） | 227 | 194 |
| `cacheImageFreeSkippedCount` | `imgFreeSkipKey` | 累计跳过图片数 | 228 | 204 |
| `cacheHitCount` | `hitCountKey` | 文章命中数 | 229 | 208 |
| `cacheMissCount` | `missCountKey` | 文章未命中数 | 230 | 211 |
| `cacheImageHitCount` | `imgHitCountKey` | 图片命中数 | 231 | 214 |
| `cacheImageMissCount` | `imgMissCountKey` | 图片未命中数 | 232 | 217 |
| `cacheSessionStart` | `sessionStartKey` | 会话起点（Date） | 238–243 | 242/382 |
| `cacheSavedTrafficBytes` | `savedTrafficKey` | 累计节省流量（Int64，按 Int 存） | 233 | 370/383 |

### 3.3 线程安全镜像 `CacheModeMirror`（12–47）★

**问题**：`CacheModeManager` 是 `@MainActor`，而 `RefererHeaderURLProtocol` 的回调在后台线程，不能直接访问。
**解法**：`final class CacheModeMirror: @unchecked Sendable` 单例 + `NSLock`，持有 `_cacheEnabled` / `_imageFreeEnabled` 两个 Bool 镜像；`mode.didSet` → `Self.syncMirror(mode)`（184、279–281），`imageFreeModeEnabled.didSet` → 直接写镜像（195）。
**读取入口**：
- `CacheModeManager.isCacheEnabledFromAnyThread`（264–266）
- `CacheModeManager.isImageFreeModeFromAnyThread`（269–271），并包装为 `SJZImageKit.isImageFreeModeFromAnyThread`（`TabBar.swift:12376–12377`）
注释（14–16、234）明确：「由 mode 变化时同步写入本镜像，读取走 NSLock」「镜像同步须在所有存储属性初始化完成后执行」。

### 3.4 与 DataService / 图片缓存 / SJZNetworkMonitor 的联动

| 联动对象 | 触发点 | 效果 | 行号 |
|---|---|---|---|
| `DataService.shared.refreshCacheLimits()` | `mode.didSet` | 文章详情 NSCache 限额随模式切换 | `CacheModeManager.swift:183` |
| └ `configureNSCacheLimits` | — | 缓存模式 `countLimit 200 / 80MB`；即时刷新 `50 / 20MB` | `DataService.swift:117–125` |
| └ `refreshCacheLimits()` | — | 重配 + `INFO(data) 缓存限制已刷新` | `DataService.swift:127–133` |
| `SJZDecodedImageCache.shared.refreshLimits(cacheEnabled:)` | `mode.didSet` | 解码图内存缓存：缓存模式 `600 张 / 96MB`；否则 `200 / 40MB` | `CacheModeManager.swift:186`；实现 `TabBar.swift:12626–12637` |
| `DataService` 文章详情读写 | 命中/未命中/写缓存 | `recordHit(articleId:cacheAge:)`（`DataService.swift:749`、`847`）、`recordMiss`（`759`、`857`）、`recordSavedTraffic`（`774`、`871`） | — |
| 招生网（ZSW）路径 | 仅缓存模式下读写缓存 | `DataService.swift:844` 判 `isCacheEnabled` 才命中；`:868` 才写入 | — |
| `RefererHeaderURLProtocol` 图片请求策略 | `startLoading` | 图片请求 `cachePolicy = isCacheEnabledFromAnyThread ? .returnCacheDataElseLoad : .useProtocolCachePolicy`；日志 context 含 `cacheMode` | `RefererHeaderURLProtocol.swift:74–78`、`:224` |
| 图片命中/未命中/省流量统计 | 图片加载路径 | `recordImageHit`（`TabBar.swift:4796`）、`recordSavedTraffic`（`4797`、`12339`）、`recordImageMiss`（`4845`）、`recordImageSkipped`（`12195`、`12203`） | — |
| 无图模式跳过渲染 | 图片组件 | `if SJZImageKit.isImageFreeModeFromAnyThread`（`TabBar.swift:12137`、`12166` task id、`12189`）→ 占位 + 计数 + 节流日志 | — |
| 与 `SJZNetworkMonitor` 的关系 | — | **无直接代码依赖**（grep 确认 netmon 不引用 CacheModeManager）。二者是**消费同一网络事实的两条并行链**：netmon 提供 `isExpensive`/`isConstrained`/`pathStatus` 事实用于 UI 提示（如 `NetworkMonitorView.swift:1470` 断网缓存联动卡），缓存策略本身不自动随链路变化——即"省流"决策仍由用户手动切换 | — |

### 3.5 统计与重置

| 成员 | 行号 | 说明 |
|---|---|---|
| `CacheStatsSnapshot` | 104–156 | 命中/未命中/图片命中/缓存文章数/内存估算 + `hitRate`、`hitRatePercent`、`imageHitRatePercent`、`formattedMemory`(B/KB/MB)、`efficiencyRating`（≥0.8 极佳 / ≥0.6 良好 / ≥0.4 一般 / 无数据 / 偏低）、`efficiencyColor` |
| `snapshot` | 300–311 | 组合 `DataService.cachedArticleCount` / `estimatedCacheMemoryBytes` |
| `sessionDuration` | 313–318 | 秒 / 分钟 / 小时三段文案 |
| `recordHit/recordMiss` | 326–338 | 计数 + `DEBUG(cache)` 日志（命中带 `cacheAge`） |
| `recordImageHit/recordImageMiss` | 340–355 | 计数 + **按 URL 首次记录节流**（357–366：`imageStatLoggedURLs` Set + 600 上限 `removeFirst`）——注释：「同一 URL 仅首次记录（计数始终累加，滚动不刷日志）」 |
| `recordSavedTraffic(bytes:)` | 368–371 | 累加 + 立即持久化 |
| `resetStats()` / `resetAll()` | 375–393 | 清 4 个计数 + 省流量 + 会话起点重置；`resetAll` 额外 `mode = .instant` |
| 图片缓存占用/清理 | 398–420 | `URLCache.shared.currentDiskUsage/diskCapacity`；`clearImageCache()` = URLCache + `SJZDecodedImageCache.removeAll()` + `DataService.clearArticleDetailCache()` + 归零图片计数 + `INFO 图片缓存已清理`（含 freed/diskUsage） |
| 内存警告降载 | 425–441 | `didReceiveMemoryWarningNotification` → 主线程三处清理 + `WARNING 收到内存警告，已降载图片缓存`；注释（430）：「闭包位于非隔离上下文，投递主线程后调用 MainActor 单例（E9）」 |

---

## 4. SJZNetworkMonitor（1917 行）— 网络监测中枢

### 4.1 文件自述的 8 项能力（5–14 行注释）

1. 链路感知（`NWPathMonitor`）+ iOS 26 `linkQuality` / `isUltraConstrained` / IPv4/IPv6/DNS；
2. 链路事件时间线（断网/恢复/异常，持久化最近 **30** 条）；
3. 全 App 实时流量统计（URLProtocol 埋点，含上行 `httpBody` 估算）；
4. 主动心跳实时采样（页面可见 5s 起步，三档智能省电 5s/10s/30s，后台暂停）；
5. EMA 瞬时吞吐 / 并发 / 峰值 / 慢主机 TOP3 / 分钟级小时历史 / 今日流量（跨启动）；
6. 双目标网络诊断（网关 API + 官网门户，**5 轮冷连接**）+ 诊断历史（内存 3 + 持久 1）；
7. 校园网健康分（0–100）+ 优化建议生成器 + 诊断报告文本；
8. 一键带宽测速（HEAD 挑源 + 循环下载真实资源）。
   日志域 `netmon`（50 处生产埋点）。

### 4.2 并发标注（本文件的架构核心）

| 组件 | 隔离/并发标注 | 行号 | 职责 |
|---|---|---|---|
| `SJZNetworkMonitor` | `@MainActor final class : ObservableObject` | 339–340 | 全部 `@Published` 状态与 UI 派生指标 |
| `NetworkMonitorLedger` | `private final class : @unchecked Sendable` + `NSLock` | 35–36 | URLProtocol 任意线程调用的记账槽（在飞请求、字节桶、延迟桶、静默开关） |
| `ProbeMetricsCollector` | `private final class : NSObject, URLSessionTaskDelegate, @unchecked Sendable` + `NSLock` | 313 | 收集 `URLSessionTaskMetrics` 与 `remoteAddress` |
| `tap*` 接口 | `nonisolated static func` | 1135–1168 | 任意线程安全的埋点入口（内部只碰 Ledger） |
| 纯函数 | `nonisolated static func` | 461–490、1457–1519 | `isMediaHost` / `isObservationalSlowRequest` / `classifySlowStreak` / `healthScore` / `gradeText` / `advice` / `resolvableSchoolURL` / `currentIPv4Address` |
| 常量 | `nonisolated static let` | 449、451、468、511 | 跨隔离域常量（注释 510：允许 Task 内嵌套函数等非隔离上下文安全引用，消除 Swift 6 模式警告） |

**跨域回主线程的模式**：`tapComplete`（1157–1162）→ `DispatchQueue.main.async { SJZNetworkMonitor.shared.absorbCompletion(...) }`；`PathMonitor` 回调（557–560）→ `Task { @MainActor in self?.apply(path:) }`；`Timer` tick（741–745）→ 同样投主线程。`NetworkMonitorLedger` 溢出保护（63–72）：在飞 > 256 条即 `removeAll` 并回主线程 `WARNING(netmon) 请求台账溢出，已重置`。

### 4.3 持久化键（`NetmonKey`，25–31）

| 键 | 用途 | 备注 |
|---|---|---|
| `netmonLiveSamplingEnabled` | 心跳采样总开关 | `@AppStorage`-like：`UserDefaults.object(forKey:) as? Bool ?? true`（530、540–543） |
| `netmonChartWindowSeconds` | 图表窗口 | `@AppStorage` + `@Published chartWindow`（513–515），`setChartWindow`（518–524）clamp 1…120 |
| `netmonTimelineJSON` | 链路事件时间线 | JSON + ISO8601 编解码器（504–509） |
| `netmonLastProbeJSON` | 最近一次诊断摘要（持久 1 条） | 1803–1814 |
| `netmonTraffic_<yyyyMMdd>` | 今日流量 `[down, up] as [Double]` | 动态日键（30），保留最近 3 天（1858–1880） |

### 4.4 链路感知（NWPathMonitor）

| 步骤 | 行号 | 说明 |
|---|---|---|
| 启动 | 556–563 | `pathUpdateHandler` → 主线程 `apply(path:)`；`pathQueue` 为 utility 私有队列（424） |
| 状态/原因/接口映射 | 566–592 | 已连接/无网络/等待连接/未知；`unsatisfiedReason` 5 分支；Wi-Fi/蜂窝/有线/回环/未知 |
| iOS 26 指标 | 594–608 | `path.linkQuality`（优秀/良好/一般/未知，低版本一律「系统未提供」）、`path.isUltraConstrained` |
| 网关地址 | 610–617 | `path.gateways` 首个 IPv4 网关（去 `%` 后缀） |
| **去抖（changed 判定）** | 619–631 | 仅当 9 个字段之一实质变化才写状态——注释：「NWPath 事件可能高频重复，避免无效 View 失效与身份快照刷屏」 |
| 状态写入 | 633–644 | 12 个 `@Published` 赋值 + `interfaceCount` + `gatewayAddress` |
| 断网/恢复事件 | 646–658 | 无网络 → `appendLinkEvent(.outage)` + `WARNING 链路断开`；由离线转在线 → `.recovery` + `INFO 链路恢复` |
| 实质变化明细日志 | 660–672 | `DEBUG 链路状态发生实质变化`（11 项 context） |
| 网络身份快照 | 675–702 | 链路变化时取本机 IPv4；`isCampusLAN` = `10.` / `172.16–31.` / `192.168.`；**30s 节流**日志（694–701） |
| IPv4 取值 | 704–730 | `getifaddrs` 正规 API（零权限）；排除 `127.0.0.1` 与 `169.254.`；优先 `en*`/`pdp*`，VPN（utun）场景回退任一生效网卡 |

事件时间线：`linkTimeline` 插入头部 + 截断 **30**（1781–1787）+ `flushTimeline` 落盘（1789–1795）+ `restoreTimeline` 恢复（1797–1801）。

### 4.5 每请求埋点采集（与 `RefererHeaderURLProtocol` 协作）★

**埋点契约（`tap` 系列，1135–1168）**：

| 事件 | 方法 | Ledger 行为 | 行号 |
|---|---|---|---|
| 请求开始 | `tapRequestStart(host:) -> UInt64`（token） | 记 `(start, bytes=0, host, firstByte=nil)`；静默期不记账 | 54–74 |
| 上行估算 | `tapUploadEstimate(for:token:)` | 仅 `request.httpBody` 非空时计（**流式上行不计量，诚实口径**，1164） | 1165–1168 |
| 响应数据 | `tapData(token:bytes:)` | 累加下行字节 + 桶字节 | 77–84 |
| 首字节 | `tapFirstByte(token:)` | 记 `firstByte`（幂等：已有则不覆盖） | 95–100 |
| 完成 | `tapComplete(token:success:)` | 出队算 `latency` / `ttfb` / bytes / host，延迟桶统一记 **TTFB（无响应头则回退总时长）**；回主线程 `absorbCompletion` | 102–112、1157–1162 |
| 放弃 | `tapAbandon(token:)` | 出队丢弃（取消类终止不计失败） | 114–117 |
| 静默 | `setSuspended(_:)` | 诊断/测速期间挂起业务采集，清空在飞与桶 | 119–129 |

**URLProtocol 侧调用序**（`RefererHeaderURLProtocol.swift`，实测行号）：
`85` start（token 含 host）→ `88` 上行估算 → 成功路径：`108` firstByte → `117` data → `120` complete(success) / 失败路径：`101` complete(false)，取消路径 `99`/`131` abandon。

**主线程归并 `absorbCompletion`（1170–1254）**：

```
totalRequests += 1；success/failedRequests                                    // 1171-1172
effectiveLatency = ttfb ?? latency                                            // 1174（注释：避免大图下载时长被误判为「链路慢」）
lastLatencyMs / latencySumMs / totalBytes / todayDownBytes 累加               // 1175-1178
延迟直方图 4 档：<100 / <300 / <1000 / ≥1000 ms                                // 1179-1184
宿主归因 perHostStats[host] = (bytes, latSum, count, failures)                // 1186-1194
registerBusinessLatency(...)  ← 慢请求告警主入口                              // 1196
失败 → 10s 节流 WARNING「请求失败（协议层观测）」                              // 1198-1211
慢（≥1s）→ 分级（见 §4.6）                                                     // 1213-1238
正常成功 → 批量统计：每 50 条一条 DEBUG「成功请求批量统计」                    // 1240-1253
```

其它埋点节奏（均为节流，防刷屏）：

| 聚合日志 | 周期 | 行号 |
|---|---|---|
| 吞吐周期聚合（current/EMA/avg30s/peak30s/up/concurrent/coverage） | 30 s | 823–837 |
| 主机归因汇总（慢主机 TOP3 + 流量域 TOP5） | 30 s | 840–843、1256–1272 |
| 心跳聚合统计（ok/fail/lastRtt/tier/sceneActive） | 30 s | 1057–1065 |
| 今日流量批写 | 10 s | 815–818、1831–1834 |
| 失败请求告警 | 10 s | 1201 |
| 慢请求 WARNING（小负载非媒体宿主） | 10 s | 1228 |
| 慢请求 INFO 观测（媒体宿主/大负载） | 60 s | 1218 |
| 媒体宿主慢观测 INFO | 60 s（`slowWindow`） | 1083 |

### 4.6 慢请求告警：宿主归因 + 时间窗 + 冷却 ★

**三级判定纯函数（契约测试锚点）**：

| 函数 | 行号 | 语义 |
|---|---|---|
| `isMediaHost(_:)` | 461–465 | `www2.` 前缀 或含 `img`/`pic`/`image`/`cdn` —— 注释：「图片镜像 / CDN 类宿主的大图 TTFB 天然偏高（实测 www2 3.99MB 图 ≈2.55s），单宿主慢属正常观测，不得升级为『链路异常』横幅」 |
| `bulkBytesThreshold` | 468 | **1 MB** —— 注释：「镜像站大图 / 附件类传输的 TTFB 天然偏高（现场样本 www2 9.8MB ≈ 2.08s）」 |
| `isObservationalSlowRequest(host:bytes:)` | 473–477 | 大负载 或 媒体宿主 → 观测（INFO）；**无宿主按异常处理（fail-closed）** |
| `classifySlowStreak(hosts:)` | 482–490 | ① ≥2 个不同宿主 → `.linkWide`；② 非媒体宿主累计 ≥3 条 → `.hostService`；③ 仅单一媒体宿主 → `.mediaObservation`（≥3 才输出，否则 `.none`） |

**时间窗与冷却**：

| 机制 | 值 | 行号 | 注释依据 |
|---|---|---|---|
| `slowWindow` | **60 s** | 449 | 「仅窗口内的慢请求参与判定——跨小时累积会把正常的外部慢误判为持续异常」（446–447） |
| 窗口清理 | 1073 | — | `slowRecords.removeAll { now - $0.date > slowWindow }` |
| 慢阈值 | `latency >= 1000 ms` | 1074 | — |
| `bannerCooldown` | **300 s** | 451 | 「同一异常不重复打扰（冷却期内再次命中只留 INFO）」 |
| 冷却命中 | 1093–1098 | — | `INFO 高延迟横幅冷却中（不重复打扰）` |
| 横幅出现 | 1099–1110 | — | `anomalyKind = .highLatency` + `appendLinkEvent(.anomaly)` + `WARNING 异常横幅出现：延迟持续偏高`（context 含 host/streak/verdict/hosts 数） |
| 恢复解除 | 1112–1121 | — | 成功且 `< 500 ms` → `INFO 延迟恢复，异常解除` + 清窗口 + `clearAnomalyIfResolved()` |
| 心跳连败横幅 | 1046–1053 | — | 连败 ≥3 → `.unstableLink` + `WARNING 异常横幅出现：心跳连续失败` |
| 横幅消失 | 1124–1131 | — | 心跳连败为 0 且慢窗口为 0 → 清 nil + `INFO 异常横幅消失` |

**现场分级样例**（源码注释 1215–1216）：「www2 9.8MB 大图 TTFB 2.08s 被记为 WARNING」→ 现改为媒体宿主/大负载走 INFO 观测，小负载非媒体宿主慢才 WARNING。

### 4.7 流量统计与采样聚合

| 机制 | 实现 | 行号 |
|---|---|---|
| 1s 聚合定时器 | `Timer.scheduledTimer(1.0s, repeats)` + `tolerance 0.2`（省电）+ 主线程 tick | 740–747 |
| tick 主流程 | 抽干桶 → 下行/上行 KBps → 平均延迟 → 上行总量累计 → EMA → 峰值 → 采样点 → 趋势 → 分钟摘要 → 心跳调度 → 档位迁移 → 今日流量批写 → 午夜滚动 → 三类周期日志 | 749–844 |
| EMA 吞吐 | `0.35*current + 0.65*ema`；无流量时 `*= 0.8` 指数衰减 | 762–769（注释：「杜绝『停表冻结』误导」） |
| 环形采样 | `samples` 上限 **120**（`removeFirst(count-120)`），`withAnimation(.easeOut(0.3))` | 786–791 |
| 覆盖度 | `coveragePercent = samples.count / 120`（注意：749–844 中在 773 与 794 计算两次，第二次为重复赋值——**疑似冗余**，见 §7） | 773、794 |
| 趋势 | 最近 10 个有效延迟采样的**最小二乘斜率**；`|slope| > 0.8` 判升/降，需 ≥4 个有效点 | 846–869 |
| 分钟摘要 | 60 槽环形；分钟切换时结算上一槽（avg/peak） | 871–898 |
| 智能省电档位 | 零流量 ≥**120 s** → `.saving`（10 s）；≥**300 s** → `.deepSaving`（30 s）；有流量 → `.live`（5 s）；切档重置 tick 计数并 `INFO 智能节能档位切换` | 900–920（枚举 181–193） |
| 今日流量 | `todayDownBytes/todayUpBytes`；**总额快照覆盖（非增量叠加，防重复累加）**（1830）；日切先以旧键落盘再归零 + `INFO 今日流量日切重置`；过期键清理每天最多一次、保留最近 3 天 | 1831–1880 |
| 会话/今日上行 | 审计修复注释（757）：「此前仅曲线有值、总量恒 0」 | 757–759 |

**心跳引擎**：

| 项 | 值/行号 |
|---|---|
| 引用计数门控 `beginLiveSampling` / `endLiveSampling` | 924–944（token 计数 + 启停日志） |
| 场景门控 `setSceneActive(_:)` | 947–960：退后台暂停发射（注释：防 iOS 挂起误判离线）+ 落盘；回前台清零连败 |
| 干净会话 | `URLSessionConfiguration.ephemeral`、超时 5s、`waitsForConnectivity = false`、**`protocolClasses = nil`**（不经过 RefererHeaderURLProtocol，避免自埋点递归） | 968–975 |
| 心跳请求 | GET 网关 API + `Accept: application/json` + 统一 UA；成功判定 `2xx || 403 || 404` | 983–1010（999） |
| 成败都落采样点 | 失败 `throughput = 0`（「断网曲线归零而非冻结」）；成功点吞吐 = 字节/耗时 | 1024–1043 |
| 一次性心跳（手动刷新） | `performOneOffHeartbeat` 建临时会话，不落采样点、只累计成败 | 1743–1777 |

### 4.8 一键网络诊断（双目标 + 5 轮冷连接）

| 步骤 | 行号 | 说明 |
|---|---|---|
| 单飞锁 | 1307（`guard !probeIsRunning, !speedTestIsRunning`）、1524（反向） | 诊断与测速互斥 |
| 静默采集 | 1318–1319 | `NetworkMonitorLedger.setSuspended(true)` … `defer false`（避免自身流量污染统计） |
| 主目标 | 1321–1326 | 网关 API 全部超时 → `.failed("无法连接学校服务器，请检查网络")` + `WARNING` |
| 副目标 | 1328 | 官网门户（**失败不阻断**） |
| 单轮实现 | 1374–1452 | 每轮**全新 ephemeral 会话**（`protocolClasses = nil`，超时 10s）+ 独立 `ProbeMetricsCollector`；从 `transactionMetrics` 提取 DNS/TCP/TLS/TTFB 四阶段耗时与 `networkProtocolName`、`remoteAddress`（IPv6 判定）；每轮 `DEBUG 诊断探测轮次完成/失败`；最终 `median` 聚合各阶段 |
| 健康分/建议 | 1330–1343 | 见 §4.9 |
| 历史 | 1346–1352 | 内存 `probeHistoryStorage` 容量 **3**（插入头部、`removeLast` 截断）+ 持久 1 条 `lastProbe`；`healthScore` 更新 |
| 完成日志 | 1355–1369 | gatewayP50/P90、portalP50、loss、dns/tcp/tls/ttfb、protocol、healthScore、grade、adviceCount |

### 4.9 健康分与建议（纯函数）

`healthScore(linkQualityText:p90:lossRate:throughputKBps:)`（1457–1481），满分 100 = **链路质量 35 + P90 30 + 丢包 20 + 吞吐 15**：

| 维度 | 分档 | 行号 |
|---|---|---|
| 链路质量 | 优秀 35 / 良好 22 / 一般 10 / 未知 15（中性分） | 1458–1465 |
| P90 | <100 → 30 / <250 → 22 / <500 → 12 / <1000 → 5 / 其余 0 | 1466–1473 |
| 丢包 | 0 → 20 / ≤0.2 → 14 / ≤0.5 → 6 / 其余 0 | 1474–1478 |
| 吞吐 | `min(KBps/300, 1) * 15` | 1479 |

`gradeText`（1483–1490）：≥85 优秀 / ≥70 良好 / ≥50 一般 / 其余 较差。
`advice(for:healthScore:)`（1493–1519）规则映射：丢包 >20%（靠近路由器/切网）、P90 >500 且 DNS <50 ms（校园网出口拥塞 → 错峰/5G）、TLS >150 ms（网关防护正常开销，可忽略）；无规则命中时按分数给正向或泛化建议。

### 4.10 一键带宽测速（HEAD 挑源 + 循环下载）

| 阶段 | 行号 | 说明 |
|---|---|---|
| 单飞 + 静默 | 1524–1533 | 同诊断 |
| 候选池 | 1536–1559 | 学校域真实图片：banner 封面 → 新闻图，**host 必须含 `sxjzit.edu.cn`**；上限 6 个；无候选 → `.failed("当前无可测资源（尚未加载学校数据）")` |
| HEAD 挑源 | 1562–1583 | 取 `expectedContentLength` 最大者；<500 KB 提示「资源样本较小，结果仅供参考」；`INFO 带宽测速资源选择` |
| 循环下载 | 1585–1657 | 干净 ephemeral 会话 + `reloadIgnoringLocalAndRemoteCacheData`；目标 **8 MB** 或 **10 s** 先到即止；内存丢弃不落盘；0.5s 滑动窗口计峰值；进度每 10% 一条 `DEBUG 带宽测速进度`；失败轮换候选 + 300 ms 退避；**连续失败 3 次提前止损** |
| 快网兜底 | 1659–1663 | 首窗口未触发即下完 → 用总字节/总耗时兜底 |
| 结果分级 | 1674–1684 | ≥4 Mbps 优秀 / ≥1.5 良好 / ≥0.5 可用 / 其余 较差；样本小再加 note |
| 完成/失败日志 | 1685–1691 / 1666–1672 | `INFO 带宽测速完成`（mbps/grade/downloadedMB/elapsedS/note） |

**重要修正**：**测速只测下载，不包含上传测速**。上传仅以「请求体字节估算」参与流量统计（`tapUpload`，1144–1146；`totalUpBytes` 374–375）。任务前提中的「测速（上传/下载）」在源码中**未实现上传分支**（grep `上传|upload|测速` 全部命中均为上行字节/曲线，无 upload 测速流程）。
`resolvableSchoolURL`（1696–1705）：相对 URL → 绝对；`http://` 强制升级 `https://`（注释：干净会话受 ATS 约束，明文必失败）；仅放行学校域。

### 4.11 历史序列保留策略汇总

| 序列 | 容量 | 位置/行号 |
|---|---|---|
| 采样点 `samples` | 120（1s 粒度 ≈ 2 分钟） | 788–790 |
| 分钟摘要 `minuteSummaries` | 60（≈1 小时） | 884–886 |
| 链路事件 `linkTimeline` | 30 条（持久化） | 1783–1785 |
| 诊断历史 `probeHistoryStorage` | 3 条（内存） | 1347–1349 |
| 最近诊断 `lastPersistedProbe` | 1 条（持久化） | 1803–1807 |
| 今日流量日键 | 保留最近 3 天 | 1867、1872 |
| 在飞台账 `inFlight` | 256（溢出整体重置 + 告警） | 63–72 |
| 延迟直方图 `latencyHistogram` | 4 桶（会话累计，不淘汰） | 378、1179–1184 |

### 4.12 `@Published` 字段清单（全部 `private(set)`，共 46 个）

| 分组 | 字段（行号） |
|---|---|
| 链路状态（13） | `pathStatus`346、`unsatisfiedReason`347、`interfaceName`348、`isExpensive`349、`isConstrained`350、`linkQualityText`352、`isUltraConstrained`354、`supportsIPv4`355、`supportsIPv6`356、`supportsDNS`357、`interfaceCount`358、`gatewayAddress`359、`ipv4Address`360、`isCampusLAN`361（**14 个**，含 `ipv4Address`） |
| 时间线（1） | `linkTimeline`365 |
| 流量指标（13） | `samples`369、`totalRequests`370、`successRequests`371、`failedRequests`372、`totalBytes`373、`totalUpBytes`375、`lastLatencyMs`376、`latencySumMs`377、`latencyHistogram`378、`instantaneousKBps`380、`peakKBps`382、`inFlightCount`384、`trendDirection`386、`coveragePercent`388、`minuteSummaries`390（**15 个**） |
| 心跳（7） | `samplingTier`394、`heartbeatEnabled`395、`liveSamplingActive`396、`heartbeatSucceeded`397、`heartbeatFailed`398、`heartbeatLastRTTMs`399、`anomalyKind`401 |
| 探针/测速/健康（5） | `probeState`405、`probeHistory`406、`lastPersistedProbe`407、`speedTestState`408、`healthScore`410 |
| 今日流量（2） | `todayDownBytes`414、`todayUpBytes`415 |
| 会话（1） | `sessionStartAt`419 |
| 图表窗口（1） | `chartWindow`515 |

**精确计数 = `grep -c "@Published" SJZNetworkMonitor.swift` 得 47 行，其中 1 行是文档注释内的提及（514），故实际发布属性 = **46 个**（14+1+15+7+5+2+1+1）。另有 `@AppStorage private var storedChartWindow` 与多个普通 `private var` 不发布。派生只读属性：`successRate`1276、`averageLatencyMs`1280、`currentThroughputKBps`1284、`slowHostsTop3`1287、`domainDistribution`1297、`heartbeatConsecutiveFailuresPublic`1721、`diagnosticReportText`1884。

### 4.13 诊断报告与手动刷新

| 成员 | 行号 | 说明 |
|---|---|---|
| `setSamplingEnabledForSession(_:)` | 1710–1718 | 会话内开关（View 层 `@AppStorage` 联动）；关闭即拆会话 |
| `refreshNetworkIdentityPublic()` | 1724–1726 | 页面打开即刷新身份快照 |
| `refreshNow()` | 1729–1741 | 采样中 → 立即一次心跳；否则 → 一次性心跳；均刷新身份 + `INFO 手动刷新触发` |
| `diagnosticReportText` | 1884–1911 | 10 行中文报告：生成时间/链路/健康分/成功率+平均延迟/会话流量↓↑/今日流量↓↑/最近诊断（P50/P90/丢包/门户 P90/DNS-TCP-TLS-TTFB/建议）/最近链路事件/尾注 |
| 尾注口径 | 1909 | 「—— 由『园枢』App 网络监测生成（**统计口径：App 数据层 HTTP**）」；`NetworkMonitorView` 脚注进一步说明「网页与视频由系统组件加载，不在此统计。健康分为估算值，仅供参考」 |

---

## 5. 日志域总表（module 短名埋点处数）★

### 5.1 统计口径（可复现）

- 扫描根：`qin/`；包含 `DesignCode/`（生产）与 `DesignCodeTests/`（测试）；**排除** `DesignCode_backup_*`（历史备份）与 `build/`。
- 匹配两类字面量（Python `re`，全文件扫描，跨行安全）：
  1. `(LogManager\.shared|manager|first|second|writer|\blog)\.(info|debugLog|warning|error|fatal)\(\s*"([^"]+)"`
  2. `module:\s*"([^"]+)"`（覆盖 `log(level:module:)` 调用式）
- 校验：`grep` 交叉核对 —— 模式①（仅 `LogManager.shared.*`，排除备份）= 1331，模式② = 31，测试内的 `manager./first./second./writer.` 接收者 = 44 → 1331 + 31 + 44 = **1406 = Python 计数**，两者一致。
- **注意**：本表只统计**字符串字面量**域。生产代码另有 **35 处动态域**调用（见 §5.4）。

**总计：1406 处埋点 / 53 个字面量域**（生产 **1354 处 / 40 域**；测试 **52 处 / 13 个测试专用域**）。

### 5.2 生产日志域（40 个，按埋点数降序）

| # | 日志域 | 处数 | 主要来源文件（冒号后为该文件内处数） |
|---|---|---|---|
| 1 | `organization` | 244 | OrganizationDetailView.swift:170, OrganizationManager.swift:34, OrganizationView.swift:32 |
| 2 | `favorite` | 91 | BookmarkManager.swift:56, BookmarkListView.swift:34 |
| 3 | `ui` | 70 | TabBar.swift:69, DesignCodeApp.swift:1 |
| 4 | `party` | 69 | PartySubjectView.swift:67, TabBar.swift:2 |
| 5 | `profile` | 68 | SchoolProfileView.swift:66, TabBar.swift:2 |
| 6 | `wechat` | 67 | WeChatService.swift:59, WeChatIntegrationViews.swift:6 |
| 7 | `campusCalendar` | 61 | CampusCalendarStore.swift:33, CampusCalendarView.swift:27 |
| 8 | `log` | 61 | LogListView.swift:21, LogManager.swift:20, TabBar.swift:12 |
| 9 | `messageCenter` | 59 | MessageCenterStore.swift:34, MessageCenterView.swift:22 |
| 10 | `longimage` | 54 | TabBar.swift:41, OrganizationDetailView.swift:13 |
| 11 | `display` | 53 | DisplaySettingsManager.swift:37, DisplaySettingsView.swift:16 |
| 12 | `netmon` | 50 | SJZNetworkMonitor.swift:42, NetworkMonitorView.swift:7, TabBar.swift:1 |
| 13 | `mailbox` | 43 | PrincipalMailboxView.swift:41 |
| 14 | `notification` | 36 | NotificationManager.swift:36 |
| 15 | `biometric` | 30 | BiometricSecurityManager.swift:28 |
| 16 | `helpGuide` | 28 | HelpGuideView.swift:18, HelpGuideStore.swift:6 |
| 17 | `collaboration` | 28 | SchoolProfileView.swift:28 |
| 18 | `notificationTest` | 27 | NotificationManager.swift:16, NotificationTestView.swift:11 |
| 19 | `privacy` | 26 | PrivacyPolicyView.swift:18, DesignCodeApp.swift:8 |
| 20 | `imageViewer` | 23 | TabBar.swift:23 |
| 21 | `cache` | 22 | CacheModeManager.swift:12, TabBar.swift:4, CacheModeSettingsView.swift:3 |
| 22 | `imageCache` | 21 | TabBar.swift:21 |
| 23 | `home_modules` | 20 | HomeModuleManager.swift:14, HomeModuleSettingsView.swift:6 |
| 24 | `data` | 17 | DataService.swift:17 |
| 25 | `announcement` | 12 | AnnouncementManager.swift:12 |
| 26 | `reading` | 12 | DisplaySettingsManager.swift:12 |
| 27 | `network` | 10 | NetworkService.swift:10 |
| 28 | `facility` | 10 | TabBar.swift:10 |
| 29 | `schoolInfo` | 8 | TabBar.swift:8 |
| 30 | `appicon` | 8 | TabBar.swift:8 |
| 31 | `articleSync` | 4 | DataService.swift:4 |
| 32 | `campusService` | 4 | TabBar.swift:4 |
| 33 | `socialFollow` | 4 | TabBar.swift:4 |
| 34 | `about` | 4 | TabBar.swift:4 |
| 35 | `departments` | 3 | TabBar.swift:3 |
| 36 | `crashCapture` | 2 | LogManager.swift:2（崩溃写入固定域） |
| 37 | `campusLinks` | 2 | TabBar.swift:2 |
| 38 | `startup` | 1 | DataService.swift:1 |
| 39 | `urlProtocol` | 1 | RefererHeaderURLProtocol.swift:1 |
| 40 | `settings` | 1 | TabBar.swift:1 |

**观察**：
- 埋点最密集的是**内容/机构模块**（organization 244 + longimage 54 + collaboration 28 + schoolInfo 8 + departments 3 = 337 处），反映机构子站抓取/渲染链路的排查成本最高；
- `ui` 域（70 处）集中在 TabBar，说明 Tab 切换/深链/长图等外壳行为也是观测重点；
- 基础设施四文件的「自观测」分布：`log` 61（其中 LogManager 自身 20）、`display` 53（自身 37）、`netmon` 50（自身 42）、`cache` 22（自身 12）、`reading` 12（DisplaySettingsManager 自身，属 display 文件的阅读统计链）——即**四个文件都遵守"自身全链路埋点"契约**。
- **本组 4 文件内部埋点总量 = 125**（实测）：LogManager.swift 22（`log` 20 + `crashCapture` 2）、DisplaySettingsManager.swift 49（`display` 37 + `reading` 12）、CacheModeManager.swift 12（`cache`）、SJZNetworkMonitor.swift 42（`netmon`）。

### 5.3 测试专用域（13 个，共 52 处，全部在 `DesignCodeTests/LogManagerTests.swift`）

| 域 | 处数 | 用途 |
|---|---|---|
| `test` | 22 | 通用断言（列表/开关/FIFO/搜索/筛选/统计/删除/清空/导出） |
| `netmon` | 9 | 慢请求告警日志上下文回归（`LogManagerTests.swift:119`） |
| `log` | 8 | 日志自身链路测试（保留/落盘/裁剪/导出） |
| `wechat` | 4 | 导出用例上下文 |
| `alpha` / `beta` | 2 / 1 | 多 manager 隔离（`first`/`second` 实例） |
| `trim` | 2 | `maxEntriesPerFile` 裁剪契约 |
| `storm` | 2 | 同键风暴折叠 + 结算留痕 |
| `floodGlobal` | 2 | 跨键交替型自反馈 → 全局速率防线 |
| `flood` | 1 | 高频写入（FIFO 裁剪） |
| `sync` / `cap` / `ghost` / `rescue` / `old` / `recent` | 各 1 | 落盘同步 / 单文件上限 / 删除不复活 / 损坏抢救 / 保留期边界 |

### 5.4 动态域修正（重要，Wiki 引用时须加注）

生产代码存在 **35 处**以变量传域的调用（`grep -E "LogManager\.shared\.(info|debugLog|warning|error|fatal)\([a-zA-Z_]+,"`）：

| 变量 | 处数 | 定义/取值 | 归属域 |
|---|---|---|---|
| `moduleName` | 17 | `PrivacyManager.swift:100` → `"privacy"` | 实际计入 `privacy`（26 + 17 = **43**） |
| `logTag` | 11 | `SchoolProfileView.swift:2709 static func saveToPhotos(urlString:logTag:)` 的入参 | 由调用方传入 `"profile"`/`"collaboration"`/`"party"`/`"socialFollow"`（`:9018`、`PartySubjectView.swift:2213`、`SchoolProfileView.swift:1995/2015/2633/3140/3533`） |
| `logDomain` | 7 | `TabBar.swift:2192 static let logDomain = "longimage"` | 实际计入 `longimage`（54 + 7 = **61**） |

其余节流/调试动态度：`SchoolProfileView.swift:73 static func reassert(logTag: String = "display")`（默认域 `display`，与 `:78` 的 `debugLog(logTag, …)` 配合）。
因此上表某些域（尤其 `longimage`、`privacy`）的"有效埋点数"高于字面量计数；本表口径已在 5.1 声明。

---

## 6. 本组 4 文件的横向关系图

```
                         ┌──────────────────────────────┐
                         │ LogManager.shared (MainActor)│◄────── 全部埋点入口
                         └───────▲──────────┬───────────┘   （4 文件自身共 125 处：22/49/12/42）
             display 53/37 处    │          │  cache 22/12 处
   ┌─────────────────────────────┴──┐   ┌───┴───────────────────────────┐
   │ DisplaySettingsManager         │   │ CacheModeManager              │
   │  · 22 设置键 + 6 环境键         │   │  · mode / imageFreeMode       │
   │  · 根注入(DesignCodeApp:121)    │   │  · CacheModeMirror(NSLock)    │
   │  · 67 处 sjzPresentationChrome  │   │      ↓ 任意线程读              │
   └────────────────────────────────┘   │  RefererHeaderURLProtocol:76  │
                                        │  TabBar.swift:12376 SJZImageKit│
                                        └───────────┬───────────────────┘
                                                    │ 图片缓存/详情缓存限额
                                        ┌───────────▼───────────────────┐
                                        │ DataService (NSCache 限额)     │
                                        │  · refreshCacheLimits:127      │
                                        │  · SJZDecodedImageCache:12596  │
                                        └───────────────────────────────┘
   ┌────────────────────────────────────┐  tap* 接口（非隔离）
   │ SJZNetworkMonitor (MainActor)      │◄───────────────────────────────
   │  · NetworkMonitorLedger(NSLock)    │   RefererHeaderURLProtocol:85/88/99/101/108/117/120/131
   │  · netmon 50 处埋点                 │
   └────────────────────────────────────┘
```
（箭头只表示已核实的代码调用/读取关系；`CacheModeManager` 与 `SJZNetworkMonitor` 之间**无直接依赖**，仅在 UI 层共同呈现，见 §3.4。）

---

## 7. 未验证 / 与任务前提不符的点（Wiki 引用须知）

| # | 事项 | 状态 |
|---|---|---|
| 1 | **`cleanEmptyFiles`** | **当前 `LogManager.swift` 中不存在**（全文 0 命中）。仅存于历史备份 `qin/DesignCode_backup_20260922/LogManager.swift:236/266`，语义为旧版「全量重写后删除非活跃日文件」。当前版已由「追加合并 + 单文件上限 + 保留天数」替代 |
| 2 | **「三种缓存模式」** | **不准确**。代码是 `enum CacheMode` 两例（`instant`/`cached`）+ 独立 `imageFreeModeEnabled` 布尔；无图模式优先于缓存模式（`CacheModeSettingsView.swift:148`） |
| 3 | **「测速（上传/下载）」** | **上传测速未实现**。`runSpeedTest()`（1523–1693）只做下载；上传仅以 `httpBody` 字节估算参与流量统计（1144–1146、374–375） |
| 4 | **「日轮转」** | 命名上无「轮转文件」动作，实为**按日一文件**（`log_<yyyy-MM-dd>.json`）+ 单文件条数上限（1000）。保留策略按**日键日期**判定（非文件创建时间），旧的按 `creationDate` 清理实现只在备份中 |
| 5 | **`import os`（LogManager.swift:14）** | 该文件内 `grep` 未发现 `os.*` / `Logger` / `OSLog` 任何使用，**疑似冗余 import**（DisplaySettingsManager.swift:12–15 的 `Logger` 是有实际使用的对照）。未做编译验证，故不断言 |
| 6 | **SJZNetworkMonitor 覆盖度重复赋值** | 第 773 行与第 794 行均为 `coveragePercent = Double(samples.count) / 120.0`，两次之间仅执行了 `append`/`removeFirst` 与 `inFlightCount` 赋值；数值上等价 → **疑似冗余**（未做运行时验证，可能是刻意保持顺序可读性） |
| 7 | **`applyRuntimeEffects` 的调用点** | 全仓仅 `init`（第 900 行）一处（grep 确认）；回前台/场景切换**不会**重新应用亮度与防息屏。若用户在其他 App 改过亮度，本 App 回前台不会重写——**这是当前实现事实，是否为预期未从注释确认** |
| 8 | **`sjzPresentationChrome()` 覆盖完整性** | 实测 67 处调用点 / 13 个视图文件；但「是否存在未挂载的内容级 sheet」需与视图层分析（设置类视图/TabBar 负责的 subagent）交叉核对，**本文件无法单独证明完备** |
| 9 | **域计数口径的非字面量部分** | §5.2 表为**字面量**计数；35 处动态域（§5.4）未摊入，故 `longimage`/`privacy`/`profile` 等域的真实埋点数被低估 |
| 10 | **健康分与建议的阈值合理性** | 阈值为源码硬编码常量（35/30/20/15 权重、85/70/50 分档），**无注释说明取值依据**，属经验值（对比：阅读统计的 300 字/分有明确注释依据） |
| 11 | **`logSliderSettled` 的调用点** | 定义在 DisplaySettingsManager.swift:1487，但调用点在设置视图中（本次未逐一核对行号，属视图层 subagent 范围） |
| 12 | 行数差异 | `wc -l` 与 read 工具总数相差 1，原因是**文件末行无换行符**（已用 `xxd` 核对 `LogManager.swift` 尾部字节 `…}.  }\n}`），引用行号时以 read/`grep -n` 为准 |

---

## 8. 参考：本次分析用到的验证命令（便于 Wiki 复核）

```bash
# 行数
wc -l qin/DesignCode/{LogManager,DisplaySettingsManager,CacheModeManager,SJZNetworkMonitor}.swift

# 崩溃捕获 / 风暴防线锚点
grep -n "stormFoldLimit\|globalStormLimit\|crashWrite\|logFileLock" qin/DesignCode/LogManager.swift

# 显示设置键与默认值
grep -n "private static let .*Key" qin/DesignCode/DisplaySettingsManager.swift
grep -n "d.object(forKey:\|d.string(forKey:\|d.bool(forKey:" qin/DesignCode/DisplaySettingsManager.swift

# 字体下载看门狗
grep -n "fontDownloadStallSeconds\|WatchdogTick\|finalizeFontDownload\|typographyRevision" qin/DesignCode/DisplaySettingsManager.swift

# 跨 presentation 注入点数
grep -rc "sjzPresentationChrome()" --include='*.swift' qin/DesignCode/

# 日志域统计（口径见 §5.1；等价一行版）
grep -rhoE 'LogManager\.shared\.(info|debugLog|warning|error|fatal)\("[a-zA-Z]+"' --include='*.swift' qin/DesignCode qin/DesignCodeTests \
  | sed 's/.*("//' | sort | uniq -c | sort -rn

# 缓存模式与图片缓存联动
grep -n "refreshCacheLimits\|isCacheEnabled\|isCacheEnabledFromAnyThread" qin/DesignCode/{CacheModeManager,DataService,RefererHeaderURLProtocol}.swift

# netmon 埋点契约
grep -n "tapRequestStart\|tapFirstByte\|tapComplete\|tapAbandon\|setSuspended" qin/DesignCode/{SJZNetworkMonitor,RefererHeaderURLProtocol}.swift
```
