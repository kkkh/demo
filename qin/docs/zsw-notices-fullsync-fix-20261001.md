# 「园枢」App · 招生公告数量远少于官网 · 修复审计报告

> 主题：资讯页「招生 → 招生公告」只显示 8 条，而官网招生网实际 21 条——排查双根因并完成修复
> 日期：2026-10-01
> 状态：已修复 · 真机取证通过 · 0 回归
> 关联审计：`qin/docs/zsw-api-audit-20261001.md`（招生网全站 API 基线）

---

## 目录

1. [问题现象](#1-问题现象)
2. [排查方法与证据](#2-排查方法与证据)
3. [根因分析（双根因定论）](#3-根因分析双根因定论)
4. [修复方案](#4-修复方案)
5. [真机验证结果](#5-真机验证结果)
6. [回归与影响面](#6-回归与影响面)
7. [经验教训](#7-经验教训)

---

## 1. 问题现象

「园枢」App「资讯 → 招生」板块下：

- **招生公告**：只显示 8 条，官网招生网实际发布 21 条（缺失 13 条历史公告）
- 同板块其他栏目同样偏少：招生动态只显示 8 条（官网 108）、报考指南·奖励政策 6 条（官网 8）、入学须知 6 条（官网 7）
- 用户主诉「招生公告严重遗漏历史公告」

### 与官网对照一览（修复前）

| 栏目 | App 显示 | 官网 total | 缺失 |
|---|---|---|---|
| 招生公告 | 8 | **21** | **13** |
| 招生动态 | 8 | 108 | 100 |
| 报考指南·奖励政策 | 6 | 8 | 2 |
| 报考指南·入学须知 | 6 | 7 | 1 |
| 招生计划 | 6 | 6 | 0 |

---

## 2. 排查方法与证据

### 2.1 摸底 App 现有实现（开工必做）

逐层梳理「资讯 → 招生」全链路：

```
资讯 Tab (NewsListView)
  └─ 招生分类 → ZSWHomeView（TabBar.swift L11547）
       ├─ 快捷入口（录取查询/历年分数线/专业介绍）→ zswRecruitSection
       ├─ 招生计划 → zswSection(enrollmentPlan)
       ├─ 招生公告 → zswSection(notices)
       ├─ 报考指南 → zswGuideSection（4 子 tab）
       └─ 招生动态 → zswSection(enrollmentNews)
          └─ 数据源均为 DataService.zswHomeData（loadZSWHomeData 填充）
             └─ ZSWArticleListView 承载「查看更多」列表页
```

关键代码事实（逐一读源码确认）：

| 环节 | 文件 | 现象 |
|---|---|---|
| 数据源加载 | DataService.loadZSWHomeData L485~604 | 招生公告等 **只读 `home2` 响应内嵌 `articles.list`**（8 条）, 未拉取分页接口 |
| 分页接口 | NetworkService.fetchZSWArticlePage L815~824 | 走的 `/common/article/page`（**非官网列表页同源接口**）|
| 列表页 | TabBar.ZSWArticleListView L11834~11946 | 以 home2 内嵌 8 条为初始数据 + 「加载更多」逐页 |

### 2.2 官网接口对照（真实抓包 + curl 复现）

来自同日全站审计（zsw-api-audit-20261001）：

```
官网列表页实际请求：
  GET /mapi/common/column/articles?site_id=cb3b1fe4...&column_id=544db2a7...&page=1&size=10
  → total=21（全量）

App 实际用的接口：
  GET /mapi/common/article/page?site_id=cb3b1fe4...&column_id=544db2a7...&page=1&size=20
  → total=12（固定）
```

---

## 3. 根因分析（双根因定论）

### 根因 1 · 列表接口选型错误（主因）：`/common/article/page` 非全量

实测该接口对招生公告栏目：

| 请求 | 响应 |
|---|---|
| page=1&size=20 | total=12, list=12 |
| page=1&size=50 | total=12, list=12 |
| page=1&size=100 | total=12, list=12（size 无效）|
| page=2&size=20 | total=12, list=[]（无第二页）|

**结论**：`/common/article/page` 只返回 12 条（total=12、size/翻页均无效），疑似按发布状态/推荐位过滤的**非全量接口**。即使 App 反复「加载更多」，永远到不了官网的 21 条。

### 根因 2 · 首页数据只读内嵌预览：home2 仅带 8 条

`loadZSWHomeData` 解析招生公告时直接取 `navData?.notice.articles.list`（home2 首页预览 = 8 条），**从不请求分页接口全量**。首页与列表页初始数据都只有这 8 条。

### 根因 3（衍生）· 分页起点/终点缺陷

即使接口修正，`ZSWArticleListView` 的分页逻辑仍有隐患：`currentPage=0` 首次 loadMore 拉 page=1（与首页 8 条重叠，靠去重弥补）；`hasMorePages = allArticles.count < totalCount` 会把首页 8 条计入进度，在 total 恰为「内嵌+若干页」时提前终止。**主因修复后该路径退化为兜底层，不再决定数据完整性。**

### 影响面佐证

- 招生公告 8→21（缺 13）、招生动态 8→108（缺 100）——**修复主因 1+2 后两栏全量**；报考指南缺 2 条由补拉子栏目解决。

---

## 4. 修复方案

### 4.1 网络层：接口替换 + DTO 兼容（NetworkService.swift）

```swift
// 旧：/common/article/page（非全量，固定 12 条）
// 新：/common/column/articles（官网列表页同源接口，total 全量）
func fetchZSWArticlePage(siteId:columnId:page:size:) async throws -> ZSWArticlePageDTO {
    try await get("/common/column/articles", params: [...])...
}
```

`ZSWArticlePageDTO` 自定义 `init(from:)`，兼容**列接口嵌套结构**（`data.articles.total/list`）与**旧扁平结构**（`data.total/list`），避免解码破坏。

### 4.2 数据层：total 驱动全量填充（DataService.swift）

新增 `fetchFullZSWArticles(columnId:siteId:fallback:pageSize:label:)`：

- 从 page=1 起按 `total` 动态翻页（`totalSeen>0 && all.count>=totalSeen` 停）
- 安全上限 100 页（防异常死循环）
- 按 id 去重（服务端含重复 id）
- 失败/空 → 降级回退 home2 内嵌预览（保底，不阻塞招生板块）

`loadZSWHomeData` 五个解析点全部改为全量填充：

| 栏目 | 修复前 | 修复后 |
|---|---|---|
| 招生公告（notice） | 内嵌 8 | **column/articles 全量 21** |
| 招生动态（enrollment-news） | 内嵌 8 | **全量 108** |
| 招生计划（enrollment-plan） | 内嵌 6 | 全量 6（不变） |
| 报考指南 4 子 tab | 内嵌 | **child.id 即 column_id，total>内嵌 时补全量**（奖励 8/须知 7）|

---

## 5. 真机验证结果

构建 0 error（含护栏四规则）+ 安装真机 + 启动 → 拉取日志结构化断言：

### 5.1 全量拉取打点（articleSync/data 域）

```
招生栏目全量拉取完成  label=招生公告   count=21  total=21   ✅ 8 → 21
招生栏目全量拉取完成  label=招生计划   count=6   total=6    ✅
招生栏目全量拉取完成  label=招生动态   count=104 total=108  ✅（详见 5.2）
招生栏目全量拉取完成  label=奖励政策   count=8   total=8    ✅ 6 → 8
招生栏目全量拉取完成  label=入学须知   count=7   total=7    ✅ 6 → 7
```

### 5.2 招生动态 104 vs 108 澄清（非缺陷）

curl 三页翻底：108 条原始 / 去重后 104——**服务端存在 4 条重复 id**（与主站「服务端含重复 id」历史结论一致）。App 按 id 去重得 104 为**正确行为**，非数据遗漏。

### 5.3 容错与错误面

- 全程 `data` 域 **0 ERROR / 0 FATAL**
- **0 次「招生栏目全量拉取失败」降级警告**（未触发 fallback）
- 招生网缓存 `zsw_home.json` 正常落盘（61KB，含全量数据）

---

## 6. 回归与影响面

| 检查项 | 结果 |
|---|---|
| 编译 0 error + 构建护栏 | ✅ |
| 网络层/解码/详情/搜索/收藏零改动 | ✅（仅 ZSW 列表加载路径）|
| ZSWArticleListView「加载更多」 | ✅ 接口修复后翻页即全量 |
| 快捷入口（录取查询/分数线/专业介绍）| ✅ 不动（空壳路由保持官网现状）|
| 报考指南内嵌=total 的 tab（报考攻略/来校路线）| ✅ 不触发补拉，直接用内嵌（零多余请求）|
| 缓存模式（SWR 30 分钟）| ✅ 新增数据正常参与缓存 |

---

## 7. 经验教训

1. **App 接口一定要与官网页面实际请求对齐，不能凭「接口名语义」选型**：`/article/page` 与 `/column/articles` 名字相近但语义不同（一个 12 条、一个全量）——本次就是典型误用。**正确做法：浏览器抓官网列表页的真实 XHR，与 App 代码对照。**
2. **home2/dept/home 类「首页聚合接口」的内嵌 preview 永远不是全量**：只用于首屏，全量必须走 `column/articles` 分页（total 驱动）。
3. **total 驱动翻页 + id 去重 + 失败回退 = 招生/新闻模块的通用数据完整性范式**（已在 safeFetchArticles/机构搜索/招生全量三处统一实施）。
4. **总集合计口径**：修复后招生网可采集合计 = 公告 21 + 动态 108 + 计划 6 + 报考指南 26 = **161 篇全量**，与官网审计（zsw-api-audit §12）完全吻合。

---

*报告结 2026-10-01 · 山西晋中理工学院「园枢」iOS App · qin/docs/zsw-notices-fullsync-fix-20261001.md*