# 机构接口摸查 · 证据目录 README

本目录为交付文档 [`../departments-api-inventory.md`](../departments-api-inventory.md) 的**证据仓库**。文档中的每条结论都能在此找到对应的原始证据与复验方法。

摸查日期：2026-09-30 ｜ API 基址：`https://gwqietap.sxjzit.edu.cn/mapi`

---

## 一、文件清单

| 文件 | 是什么 | 覆盖文档哪些结论 | 如何复验 |
|---|---|---|---|
| `network-capture.md` | 外部 Chrome **实机点击**取证台账（子栏目穷举 / 翻到底 / 详情 / 搜索 / 日历 / 学院页 / 特殊板块），含 network 原始请求片段与 DOM 检查结论 | §3.4 子栏目发现、§4.2 栏目类型、§4.3 无置顶/轮播、§5.3 图片形态、§6 搜索、§7.1 日历路由、§11.3 前端行为坑 | 对照台账中的请求 URL，用 `curl` 直连 `raw/` 中同名响应；或重访官网路由复现点击 |
| `agentB_sites.md` | 22 站点 × **178 子栏目**验证报告（逐站点栏目表、翻底校验、列表项字段表、契约要点） | §3.1~§3.6 | `curl "$B/dept/home2?site_key=<key>"` + `curl "$B/common/column/articles?site_id&column_id&page&size"` |
| `agentB_sites.json` | 上表的结构化原始数据（22 站点全量栏目、端点契约、componentType 统计） | §3.4 逐站点表格、§4.2 类型统计 | `python3 -m json.tool agentB_sites.json` 读取 |
| `agentC_detail.md` | 文章详情契约、**资源拼接规则**、10 单文章机构验证表、oneTwoArticles、`school/org` 字段表 | §2、§5、§4.4 | `curl "$B/common/article/detail?article_id=..."`；图片 https 复测见 `img_check.txt` |
| `agentD_endpoints.md` | **20 端点契约总表**、健壮性边界探测、可粘贴 curl 复现命令、页面↔接口映射、校园日历路由结论 | §1、§7、§11、§12 | 直接复制文中的 curl 命令执行 |
| `leaves.json` | 34 个机构叶子清单（group / id / name / site_key / site_id / article_id / path / en） | §2.5 34 机构全量对照表、§8 矩阵、§9 映射 | 与 `school_org.json` 叶子节点比对 |
| `school_org.json` | `/school/org` **机构树原始响应**（3 层 / 5 分组 / 34 机构） | §2.1~§2.5 | `curl -s "$B/school/org"`（应与本文件一致） |
| `endpoints.txt` | SPA bundle 端点**枚举基线**（全量 API 路径清单） | §1 端点总表、§7.4 "访问量/点赞/标签/相关推荐不存在"的取证依据 | 对照该清单确认无相关路径 |
| `img_check.txt` | 10 篇单文章机构正文图 + `image_url` 的 https 复测日志 | §5.3 http→https / 无防盗链结论 | 复制其中的 URL 用 `curl -I` 复验 |
| `raw/` | **310 个原始响应 JSON**（+1 个日志），全部证据的最终来源 | 全篇 | 见下命名规则 |

---

## 二、`raw/` 命名规则与数量

| 前缀 / 文件名 | 数量 | 含义 |
|---|---|---|
| `home2_<site_key>.json` | 22 | `/dept/home2` 各站点首页聚合原始响应 |
| `list_<site_key>_<column_id>.json` | 222 | `/common/column/articles` 各栏目列表原始响应；其中 `_lastp<N>.json` / `_lastp<N+1>.json` 为**翻到底校验**样本（末页非空 / 末页+1 空） |
| `detail_<前8>.json` | 10 | 10 个**单文章型机构**详情原始响应 |
| `detail_art_<前8>.json` | 6 | 普通列表文章详情（含 `file:///C:\` 残留、kdocs 外链、数字型 article_id 旧数据等坑位样本） |
| `ep_<name>.json` | 31 | 各端点契约样例（含 200 / 400 / 500 各类样本） |
| `rob_<name>.json` | 10 | **健壮性反例**（缺参 / 坏 column_id / page=0 / page 超界 / size=1000 / GET 405 等） |
| `oneTwo_*.json` | 6 | `oneTwoArticles` 成功样例与 500 反例（根栏目 / 子栏目 / 无参） |
| `probe_id.json` | 1 | `id=` 参数无效证据（body code 400） |
| `school_org.json` | 1 | 机构树原始响应（与上级目录同源） |
| `dept_home2_jwc.json` | 1 | jwc nav 栏目树（用于取站点根栏目 id `66e9645f4eee4f2ead37a8fe1223d7fb`） |
| `raw_cal_list.json` | 1 | 校园日历完整列表页 `#/list/more?site_id=1&column_id=8197fe41…` 响应（**结构变体** `data.articles:{total,list[]}`；2026-09-30 补充实测） |
| `img_check.txt` | 1 | 图片复测日志（非 JSON） |

> 目录内共 **312 个文件** = 311 个 JSON + 1 个 `img_check.txt`（2026-10-01 复核修正：此前误计 310/311，`raw_cal_list.json` 未入表）。

---

## 三、关键结论 → 证据直达

| 结论 | 证据 |
|---|---|
| 机构树 3 层 / 5 分组 / 34 机构 | `school_org.json`、`leaves.json` |
| 22 站点 178 子栏目全量表 | `agentB_sites.json` + `raw/home2_*.json` + `raw/list_*.json` |
| 学院首页用 `/college/home`（仅 6 学院 200，mkszy 500） | `raw/ep_college_home_xcdsj.json`、`raw/ep_college_home_sxy.json`、`raw/ep_college_home_mkszy.json` |
| 列表翻到底：末页非空、last+1 空 | `raw/list_*_lastp<N>.json` / `_lastp<N+1>.json` |
| `page=0`→500、`size` 无上限、超界返回空数组 | `raw/rob_articles_page0.json`、`raw/rob_articles_size1000.json`、`raw/rob_articles_page99999.json` |
| 详情仅 5 字段、正文 HTML | `raw/detail_*.json`、`raw/ep_article_detail.json` |
| 图片 http→https 丢端口、无防盗链 | `img_check.txt`、`raw/detail_*.json` 内 `<img src>` |
| 附件 href 前导空格 / `file://` 残留 | `raw/detail_art_a94feef0.json`、`raw/detail_art_01223003.json` |
| oneTwoArticles 须传根栏目 id | `raw/oneTwo_66e9645f4eee4f2ead37a8fe1223d7fb.json`（成功）、`raw/oneTwo_jwc.json`（500） |
| 搜索参数为 `key_words/p/s` | `raw/ep_search_kaoshi.json`、`raw/ep_search_ks_p2s5.json` |
| 校园日历无独立页面；`/school/events` 翻月 | `network-capture.md` 步骤 5、`raw/ep_school_events.json`、`raw/ep_dept_home2_jwc.json`（calendar 键） |
| `/article/videos` 是前端路由非 API（404） | `raw/ep_article_videos.json` |
| 机构页无置顶/推荐/轮播 | `network-capture.md` 步骤 7 |

---

## 四、取证方式说明（重要）

- **HAR 无法直接导出**：本次使用的浏览器扩展不支持 HAR 导出，因此以「**network 捕获台账 `network-capture.md`**（记录实机请求 URL / 时序 / DOM 结论）+ **直连原始响应 `raw/`**」构成**等效证据链**：台账给出"实机确实发起了什么请求"，`raw/` 给出"该请求的完整原始响应"，二者可相互印证。
- **本次未归档页面截图**：浏览器扩展截图未在本任务归档；所有 DOM / 交互类结论（机构页无轮播、无置顶、搜索浮层不发请求、日历「更多」/「下载」行为等）均以 `network-capture.md` 的文本记录为准。
- **所有 `raw/` 响应均由 `curl -s` 直连官网 API 获得**，不带任何请求头（无 Referer / UA / Cookie）。
- 若要完整复验，可直接执行文档 §12 的 20 条 curl 命令，或按上表"如何复验"逐项执行。
- **审计后修订**：本目录证据结论已通过独立审计复核（`audit-report.md`），并据此修正了交付文档的 6 处问题（`article/page` 参数、日历入口表述、截图缺失说明、`detail_art_*` 计数、App 行号、未接入计数）；详见 `audit-report.md` 末尾「修复回执」。
- **第三轮全量复核（2026-10-01）**：`sweep_columns.py` + `sweep_result_20261001.json` 对 22 站 × 178 栏目现网逐一重扫（约 240 请求），结果与 agentB 基线**完全一致**（code 零差异、site_id 零差异、翻底 22/22、列表型文章总量 4310 篇）；完整结论见 `../departments-columns-sweep-20261001.md`。
- `raw/raw_cal_list.json`：主站「校园日历」单栏目列表页（#/list/more?site_id=1&column_id=8197fe41…）真实响应——含**结构变体** `data.{column_id,title_cn,title_en,href,articles:{total,list[]}}`（2026-09-30 补充实测）
