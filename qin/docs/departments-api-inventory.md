# 山西晋中理工学院官网 · 机构接口摸查交付文档

> 本文档面向客户端开发（iOS App），把官网「机构设置 / 各机构子站」相关的全部接口契约、字段、路由规则、坑位一次性固化，可直接照着开发。

---

## 0. 文档头

| 项 | 值 |
|---|---|
| 摸查日期 | 2026-09-30 |
| 摸查方法 | ① 外部 Chrome **实机点击穷举**（子栏目逐个点开、翻到最后一页、点开详情、搜索、日历、学院页、特殊板块）② DevTools / 浏览器扩展 **网络捕获**（记录真实请求 URL 与响应）③ **curl 直连复验**（无请求头裸调，逐接口验证契约与边界） |
| 证据形态说明 | **本次未归档页面截图**（浏览器扩展截图未在本任务归档）；关键交互结论一律以「**network 捕获台账（`network-capture.md`）+ 直连原始响应（`raw/`）**」为准，HAR 亦因扩展不支持导出而不可得（详见 §13）。 |
| API 基址（axios baseURL） | `https://gwqietap.sxjzit.edu.cn/mapi` |
| 官网 SPA | `https://www.sxjzit.edu.cn/`（hash 路由，Vue 3 + vue-router） |
| SPA 主包版本 | `index-CGZNp-gN.js`（API 包装函数集中在 `chunks/index-Bg2ZeZgM.js`，axios `timeout=5s`） |
| 资源/图片域 | `www2.sxjzit.edu.cn:8082`（路径前缀 `/zhglxt/profile/...`） |
| 机构设置页 URL | `https://www.sxjzit.edu.cn/#/departments/list` |
| **HTTP 语义警示** | **服务器 HTTP 状态码恒为 200**：业务错误（缺参/不存在/内部错误）全部写在响应体 `code` 字段里（`400`=缺参数、`500`=内部错误/数据不存在）。只有「路径不存在」才返 HTTP 404、「方法不匹配」才返 405。**客户端必须判断 body.code，不能只判断 HTTP 状态码。** |
| 统一响应外壳 | `{"code":200,"message":"success","data":{...},"timestamp":<ms>,"executeTime":<ms>}` |
| 请求头要求 | 结论：**全部接口无需任何特殊请求头**（无 Referer / 无 UA / 无 Cookie 亦可）。仅 POST + JSON body 需带 `Content-Type: application/json`。 |

---

## 1. 端点总表（20 个）

| # | 方法 | 路径 | 用途 | 机构相关 | 验证状态 |
|---|---|---|---|---|---|
| 1 | GET | `/school/org` | 机构树（5 分组 / 34 机构全字段） | ✅ 核心 | 已验证 200，契约完整 |
| 2 | GET | `/dept/home2` | 部门首页聚合（子栏目菜单 + 各板块文章 + 日历） | ✅ 核心 | 已验证 200（22 站） |
| 3 | GET | `/dept/home` | 部门首页聚合·旧版 | ✅ 相关 | 已验证 200（旧版，功能被 home2 覆盖） |
| 4 | GET | `/college/home` | 学院首页聚合（仅 6 个学院 site_key 可用） | ✅ 核心 | 已验证 200×6 / 500×其余 |
| 5 | GET | `/common/column/articles` | 栏目文章分页（子栏目内容） | ✅ 核心 | 已验证 200，边界已探 |
| 6 | GET | `/common/column/oneTwoArticles` | 一二级栏目混合文章（板块预览用） | ✅ 核心 | 已验证 200（须传根栏目 id） |
| 7 | GET | `/common/article/detail` | 文章详情（含单文章型机构详情） | ✅ 核心 | 已验证 200 |
| 8 | GET | `/common/column/head` | 全站顶部导航栏目 | 间接（站点壳） | 已验证 200 |
| 9 | GET | `/common/foot` | 全站页脚（联系方式/友链） | 间接（站点壳） | 已验证 200 |
| 10 | GET | `/common/teacher/page` | 师资分页（师资队伍栏目） | ✅ 相关 | 已验证 200 |
| 11 | GET | `/school/events` | 校园日历月历 | ✅ 相关 | 已验证 200 |
| 12 | GET | `/common/search` | 站内搜索（全站文章） | ✅ 相关 | 已验证 200 |
| 13 | GET | `/common/msg/detail` | 校长信箱来信详情 | ✖ 不相关 | 已验证 200 |
| 14 | POST | `/common/msg/send` | 校长信箱提交 | ✖ 不相关 | 仅静态契约（未提交） |
| 15 | POST | `/common/recruit/query` | 招生录取查询（idcard 需 RSA 加密） | ✖ 不相关 | 已验证 405(GET)/500(假数据) |
| 16 | GET | `/school/msg` | 校长信箱列表 | ✖ 不相关 | 已验证 200 |
| 17 | GET | `/school/intro` | 学校概况六板块 | ✖ 不相关 | 已验证 200 |
| 18 | GET | `/school/cooperate` | 合作交流 | ✖ 不相关 | 已验证 200 |
| 19 | GET | `/school/home5` | 官网首页聚合 | ✖ 不相关 | 已验证 200 |
| 20 | GET | `/common/short/create` | 短链创建（响应键名特例 `msg`/`datas`） | ✖ 不相关 | 已验证 200 |

> **`/article/videos` 不是 API**：`GET /mapi/article/videos` 返回 **HTTP 404** `{"status":404,"error":"Not Found","path":"/mapi/article/videos"}`。它只是前端路由 `#/article/videos`（视频列表页），其数据实际来自 `/common/column/articles`。原始证据：`raw/ep_article_videos.json`。

### 1.1 端点补充（App 源码中发现、不在 SPA 枚举的 2 个）

摸查 SPA bundle 时被列为"待验证"的两条，经 App 源码与直连复核后确认**均为真实存在的端点**，一并记录：

| 方法 | 路径 | 参数 | 说明 | 验证 |
|---|---|---|---|---|
| GET | `/school/home2` | 无参 | 官网首页聚合（新版；与 `/school/home5` 结构一致，`data.top_banners/news/...`） | 直连 200，App 使用中（`NetworkService.swift:178`） |
| GET | `/common/article/page` | `site_id`、`column_id`、**`page`（默认 1）**、**`size`（默认 10）** | 栏目文章分页（**招生网专用变体**；响应 `data.{total,list[]}`，列表项含 `out_link`/`source` 字段） | 直连 200（zsw 招生动态 total=62）。**⚠️ 真实参数是 `page`/`size`；`pageNo`/`pageSize` 会被服务端完全忽略（默认 size=10，非 20）——详见下方实测** |

> 备注：`/school/home`（无参）亦返回 200，但结构为 `data.top_banners:{total,list[]}`（与 home2/home5 的纯数组不同），属旧版，未纳入上表。

**`/common/article/page` 参数实测（2026-09-30 直连复核，jwc 通知公告 `site_id=222fa535…&column_id=94511e8f…`）**：

| 请求 | body.code | total | 返回条数 | 首页首条 id(前8) | 结论 |
|---|---|---|---|---|---|
| `?page=1`（不传 size） | 200 | 125 | **10** | 03893dae | **默认 size = 10** |
| `?page=1&size=20` | 200 | 125 | 20 | 1909b49a | `size` 生效 |
| `?page=2&size=3` | 200 | 125 | 3 | 086bce65 | `page` 生效（第 2 页数据不同） |
| `?pageNo=2&pageSize=3` | 200 | 125 | **10** | **03893dae** | **`pageNo/pageSize` 被完全忽略**，仍返回第 1 页、默认 10 条 |
| `?pageNo=5` | 200 | 125 | **10** | **03893dae** | 再次佐证 `pageNo` 被忽略 |

- **正确用法**：`GET /common/article/page?site_id=<sid>&column_id=<cid>&page=<≥1>&size=<n>`；**勿使用 `pageNo`/`pageSize`**。
- **⚠️ 与 `/common/column/articles` 不等价**：**同一 jwc 通知公告栏目**，`/common/article/page` 返回 `total=125`，而 `/common/column/articles` 返回 `total=378`——二者是**不同数据集**（口径不同），**不可互相替代**，客户端选接口时须明确目的。
- **App 现状备注（已修复，2026-09-30）**：`qin/DesignCode/NetworkService.swift:759-766` 的 `fetchZSWArticlePage` **已改用 `page`/`size` 传参**（第 765 行 `"page": …, "size": …`；第 759-761 行注释明确「服务端只认 `page`/`size`——旧版传 `pageNo`/`pageSize` 会被静默忽略」）。**曾**处于分页失效状态（旧传参与见上方实测表），现已修复，勿再按"失效分页"处理。

---

## 2. §1 机构列表

### 2.1 `/school/org` 契约

| 项 | 值 |
|---|---|
| URL | `https://gwqietap.sxjzit.edu.cn/mapi/school/org` |
| 方法 | GET |
| 参数 | **无参** |
| 请求头 | 无需任何请求头 |
| 响应外壳 | `{"code":200,"message":"ok","data":{...}}` |
| 原始证据 | `raw/school_org.json`（同 `departments-api-evidence/school_org.json`） |

### 2.2 层级结构（3 层）

```
data（第 1 层：根节点，title_cn="机构设置"，title_en="Schools & Departments"，**无 id 字段**；子节点 parent_id=100 → 反推根 id=100）
 ├─ 116 党委机构            party-committee-organs
 ├─ 117 群团机构            group-organization
 ├─ 118 行政机构            administrative-agency
 ├─ 119 教学机构            teaching-institution
 └─ 120 知识拓展·技能转换    educational-support-institution
        └─ 第 3 层：叶子=具体机构（id 121–157，共 34 个，children 恒为 []）
```

- 仅 3 层，无更深嵌套；共 40 个节点（1 根 + 5 分组 + 34 机构）。**34 = 机构树叶子数**，与 `leaves.json` 完全一致。
- **只有叶子是「机构」，中间 5 个是分组标题**（客户端渲染分组卡片即取这 5 个节点）。

### 2.3 节点字段表（全字段）

| 字段 | 类型 | 含义 / 用途 |
|---|---|---|
| `id` | int | 机构/分组数字 id（分组 116–120，机构 121–157）；**仅用于树内定位，不是接口参数** |
| `parent_id` | int | 父节点 id；分组=100（根），机构=所属分组 id |
| `title_cn` | string | 中文名 |
| `title_en` | string | 英文 slug；**大量为占位符 `"temp_name"`**（后台未维护），少数是真 slug |
| `site_key` | string\|null | 部门站点 key，用于 `/dept/home2?site_key=`、`/college/home?site_key=`；**单文章型机构为 `null` 或 `""`** |
| `site_id` | string\|null | CMS 站点 id（32 位 hex），用于 `/common/column/*`、`/school/events`；**单文章型机构为 `null`；保卫处为 `null`（需从 home2 取）** |
| `article_id` | string\|null | 单文章型机构的唯一文章 id，送 `/common/article/detail?article_id=`；正常站点型机构为 `null` |
| `path` | string\|null | 前端路由覆盖，如 `/college?site_key=xcdsj`；**空串 `""` 表示走默认路由**（`#/departments/page?site_key=<key>`），`null` 多见于未配置 |
| `children` | array | 子节点数组；叶子恒为 `[]` |

### 2.4 机构三态（决定前端如何路由）

| 形态 | 判定 | 数量 | 渲染方式 |
|---|---|---|---|
| **子站型** | `site_key` 非空 + `site_id` 非空，`article_id=null` | 20 条（含共用/重复） | 打开机构主页，走 `/dept/home2`（部门）或 `/college/home`（学院） |
| **单文章型** | `article_id` 非空、`site_id=null` | **10 个** | 直接渲染一篇文章详情（`/common/article/detail`） |
| **双配型** | 同时有 `site_id` 与 `article_id` | 1 个（财资处 130） | 站点端 `/dept/home2?site_key=cwc` 与文章端 `/common/article/detail?article_id=cc3b8540…` **均可用**（2026-10-01 实测）；**机构列表页点击时前端优先走文章详情**（`#/list/article?id=cc3b8540…`），客户端可按需任选一端 |
| **仅 site_key** | 有 `site_key` 但 `site_id=null` | 3 个（校长办公室 124 / 学生工作处 133 / 保卫处 136） | **仅保卫处 136 真正需要**从 `/dept/home2` 响应 `data.site.site_id` 补取（实测 `21184757…`）；校长办公室 124、学生工作处 133 为**共用键**（分别与党委办公室 121、党委学工部 146 共用 `dzbgs`/`dwxsgzb`），其 site_id 已存在于机构树内另一条目名下 |
| **未配置** | 三者皆空 | 0 个 | — |

单文章型 10 个明细：党委组织部 122、党委宣传部 142、党委统战部 143、纪检监察办公室 144、党委教师工作部 145、妇联 139、科协 140、关心下一代工作委员会 141（此 8 个 `site_key=null`）；思想政治教育工作部党支部 148、工会 138（此 2 个 `site_key=""` **空串，注意与 null 区分**）。

### 2.5 34 机构全量对照表

> `site_key`/`site_id`/`article_id`/`path` 中的 `—` 表示 JSON 里为 `null`，`(空串)` 表示 `""`。按官网机构设置页展示顺序（分组内按机构 id）排列。

| 分组 | 机构 id | 机构名称 | site_key | site_id | article_id | path | 类型 |
|---|---|---|---|---|---|---|---|
| 党委机构 | 121 | 党委办公室 | `dzbgs` | `57c7fc7a00924d1b8113d77d9729d7eb` | — | (空串) | 子站型 |
| 党委机构 | 122 | 党委组织部 | — | — | `697c6771ad544a5f8f7f04d7d5ff3c83` | — | 单文章 |
| 党委机构 | 142 | 党委宣传部 | — | — | `27a40b0a485f45ab942e516c9d8614c7` | — | 单文章 |
| 党委机构 | 143 | 党委统战部 | — | — | `20768d27930d47cbaceb608b9e2bbde5` | — | 单文章 |
| 党委机构 | 144 | 纪检监察办公室 | — | — | `e8c51530b2484e73a9892cefa864eb8d` | — | 单文章 |
| 党委机构 | 145 | 党委教师工作部 | — | — | `c94f0d88ae0d461ea353b4ff1336da93` | — | 单文章 |
| 党委机构 | 146 | 党委学生工作部(武装部) | `dwxsgzb` | `9fbfe21fde4e4620af51382cd893be6f` | — | (空串) | 子站型 |
| 党委机构 | 148 | 思想政治教育工作部党支部 | (空串) | — | `0bde63d0f02f4ecb8201bf3c235d34dd` | — | 单文章 |
| 群团机构 | 123 | 团委 | `tw` | `e1acf637f93242bbbc1426c04f14145c` | — | (空串) | 子站型 |
| 群团机构 | 138 | 工会 | (空串) | — | `0fc43da1b5de47eaadd624cbb37bfeb4` | — | 单文章 |
| 群团机构 | 139 | 妇联 | — | — | `5efa8bd8457b458381fd94ed9fd31e45` | — | 单文章 |
| 群团机构 | 140 | 科协 | — | — | `743ed5d2ab0a45499f33314b42a8cb70` | — | 单文章 |
| 群团机构 | 141 | 关心下一代工作委员会 | — | — | `56ad9602d65d48cc8508b8c5ec201dff` | — | 单文章 |
| 行政机构 | 124 | 校长办公室 | `dzbgs` | — | — | — | 仅site_key(与党委办公室共用 dzbgs) |
| 行政机构 | 125 | 人力资源处 | `rlzyc` | `571d4b7547804e2397a12a4f0503a571` | — | (空串) | 子站型 |
| 行政机构 | 130 | 财务与资产管理处 | `cwc` | `9725697bdad041d38a0246cbbbd89b20` | `cc3b8540920541b4a75627527584b398` | (空串) | 双配型(站点+单文章) |
| 行政机构 | 131 | 教务处 | `jwc` | `222fa53591a3494e9c860390039b0844` | — | (空串) | 子站型 |
| 行政机构 | 133 | 学生工作处 | `dwxsgzb` | — | — | — | 仅site_key(与党委学工部共用 dwxsgzb) |
| 行政机构 | 134 | 招生就业处 | `zsw` | `cb3b1fe4fcdf40999b0c162015c3326d` | — | (空串) | 子站型 |
| 行政机构 | 135 | 后勤管理处 | `hqglc` | `27c4a698e7fc4abea886eb4610f374e3` | — | (空串) | 子站型 |
| 行政机构 | 136 | 保卫处 | `dwbwb` | — | — | — | 仅site_key(无site_id，需从 home2 取) |
| 行政机构 | 137 | 科研处 | `kyc` | `6030fbf696d543f3a93bf537ca0af899` | — | (空串) | 子站型 |
| 教学机构 | 126 | 智能制造与车辆学院 | `znzzcl` | `6fe4387f78ba4b42b9807ff86ca0df1f` | — | `/college?site_key=znzzcl` | 子站型 |
| 教学机构 | 127 | 信创与大数据学院 | `xcdsj` | `890cf93e62aa47a0983aa5f551c92e4a` | — | `/college?site_key=xcdsj` | 子站型 |
| 教学机构 | 149 | 材料与环境学院 | `clhj` | `7575582d988949a0a3d70fcceba26cb5` | — | `/college?site_key=clhj` | 子站型 |
| 教学机构 | 150 | 商学院 | `sxy` | `c85524251e1b4ca19d7f4c7b0de482bb` | — | `/college?site_key=sxy` | 子站型 |
| 教学机构 | 151 | 文法学院 | `wfxy` | `e684aa6d75c340559aa4f7a2668cf3e4` | — | `/college?site_key=wfxy` | 子站型 |
| 教学机构 | 152 | 艺术学院 | `ysxy` | `cdd28a001afc418bb2b77ad704ed12a6` | — | `/college?site_key=ysxy` | 子站型 |
| 教学机构 | 153 | 通识教育学院 | `tsxuey` | `e62a313fe40746438fdaea3cfc33123f` | — | `/departments/page?site_key=tsxuey` | 子站型 |
| 教学机构 | 154 | 国际交流与继续教育学院 | `gjjljxjy` | `4b9a6b4591ef4e23aa4dd5fc54aebd84` | — | `/departments/page?site_key=gjjljxjy` | 子站型 |
| 教学机构 | 155 | 马克思主义学院 | `mkszy` | `93ef50506d1f4e2a92477a21ecc8b52f` | — | `/departments/page?site_key=mkszy` | 子站型 |
| 教学机构 | 157 | 创新创业学院 | `scxy` | `1e4acf8fff9148ce933f47610a87ca48` | — | `/departments/page?site_key=scxy&page=home` | 子站型 |
| 知识拓展·技能转换 | 128 | 图书馆 | `tsg` | `69bc8045bfdb4ff5bb442e04bad86986` | — | (空串) | 子站型 |
| 知识拓展·技能转换 | 129 | 实践教学管理中心 | `sjjxglzx` | `d99e0d78612149ce99b9f00edf45ca4f` | — | (空串) | 子站型 |

**核算**：34 行 = 机构树叶子数 34 ✅ ｜ 分组 8+5+9+10+2 = 34 ✅ ｜ 其中子站型站点 22 个唯一 `site_key`（24 条机构条目去重，`dzbgs`、`dwxsgzb` 各被 2 条机构共用）。

---

## 3. §2 每机构内容接口

### 3.1 站点首页聚合 `/dept/home2`

| 项 | 值 |
|---|---|
| URL | `GET https://gwqietap.sxjzit.edu.cn/mapi/dept/home2?site_key=<site_key>` |
| 参数 | `site_key`：String / **必填**。缺参 → `{"code":400,"message":"参数[site_key]为必填项"}`；`site_key` 不存在 → `{"code":500,"message":"系统内部出现错误"}` |
| 请求头 | 无需 |
| 响应结构 | `data.{ site{site_id,title_cn,logo,主题色,联系方式}, nav[ {...}, ... ], <各首页板块>: {...} }` |
| `nav[]` 元素字段 | `column_id`、`parent_id`、`site_id`、`title_cn`、`title_en`、`path`、`componentType`、`children[]`、`data{}` |
| 首页板块字段 | 以「板块英文 slug」为 key（如 `notice`/`news`/`calendar`/`college-introduction`/`latest-news`/`thematic-center`/`classic`/`ebook`…），值为一个栏目对象，内含其 `articles`（板块预览文章，约 10 条） |
| 日历板块 | `calendar`：`{column_id, site_id, title_cn:"校园日历", title_en:"calendar", href:"/", componentType:"calendar", events:{rest_work:{...}, schedule:[]}}`——**首屏日历数据内嵌于此** |
| 词藻要点 | 同一栏目会在 `nav[]` 与 `nav[0].data` 板块里**重复出现**，客户端应按 `column_id` 去重 |
| 原始证据 | `raw/home2_<site_key>.json` × 22；缺参/坏 key 反例 `raw/rob_home2_nokey.json` / `raw/rob_home2_badkey.json` |

### 3.2 学院首页聚合 `/college/home`

| 项 | 值 |
|---|---|
| URL | `GET https://gwqietap.sxjzit.edu.cn/mapi/college/home?site_key=<site_key>` |
| 参数 | `site_key`：String / 必填 |
| 响应结构 | `data.{site_id, title_cn, title_en, domain, logo, description, nav[]}` |
| **适用范围（实测）** | **仅 6 个学院 site_key 返回 200**：`xcdsj`、`znzzcl`、`sxy`、`clhj`、`wfxy`、`ysxy`（正好是 `school/org` 中 `path=/college?site_key=...` 的 6 个） |
| mkszy 特例 | **`site_key=mkszy` 返回 `code 500`（反常：mkszy 是学院却无 college 首页数据）；同时 tsxuey/gjjljxjy/scxy/jwc/tsg/dwbwb 等亦 500** |
| 关键准则 | **学院页调 `/college/home`，部门页调 `/dept/home2`，二者不可互换**。学院型站点（上述 6 个）用 college/home；其余 16 个站点全部用 dept/home2 |
| 原始证据 | `raw/ep_college_home_xcdsj.json`、`raw/ep_college_home_sxy.json`、`raw/ep_college_home_mkszy.json`（500） |

### 3.3 栏目文章分页 `/common/column/articles`（完整契约）

| 项 | 值 |
|---|---|
| URL | `GET https://gwqietap.sxjzit.edu.cn/mapi/common/column/articles?site_id=<sid>&column_id=<cid>&page=<n>&size=<m>` |
| 参数 | `site_id`：String / **必填**（缺→400）；`column_id`：String / **必填**（缺→400）；`page`：Int / 默认 1，**必须 ≥1**（`page=0` → body code 500）；`size`：Int / 默认 10，**服务端无上限** |
| 响应结构 | `{"code":200,"data":{"column_id","title_cn","title_en","href","articles":{"total","list":[...]}}}` |
| 不存在 column_id | `column_id=deadbeef…` → body `code 500`（非空、非 400） |
| 超界 | `page=last+1`（如 `page=99999`）→ **不报错**，`articles.list=[]`（空数组），`total` 保持原值 |
| `size` 无上限 | `page=1&size=1000` 可一次返回全部（示例：jwc 通知公告一次返回全部 378 条） |
| 分页公式 | `pages = ceil(total/size)` |
| 原始证据 | `raw/ep_column_articles.json`；边界反例 `raw/rob_articles_{nocolumn,nosite,badcolumn,page0,size1000,page99999}.json` |

### 3.4 22 站点 × 178 子栏目总表

> 数据来源：`departments-api-evidence/agentB_sites.json`（探测时统一 `size=20`）。「来源」列：`首页板块`=该栏目出现在 `/dept/home2` 的首页板块里；`+nav菜单`=同时出现在 `nav` 菜单里。「条数」为该栏目 `articles.total`，`—(code 500)` 表示该栏目对列表接口返回业务错误（非文章栏目，见 §3.2）。
> **合计 178 个子栏目，22 个站点**（下方逐站点表格严格对齐 agentB 采集结果，全量不漏）。

#### dzbgs（党政办公室）· 8 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `548b325c3c5a429399993f149afcf9eb` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `5975850f3b8b43aa9ad9e8114def1178` | notice | 23 | 2 | 首页板块 |
| 党建工作 | `68b3567f6b404d08a09a1421636fddf9` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 行政工作 | `10094dafff844c939dcb0cc6133bee0c` | notice-small | 21 | 2 | 首页板块+nav菜单 |
| 资料下载 | `be80c27b1b724afebb53bde65d212917` | download | 10 | 1 | 首页板块+nav菜单 |
| 部门概况 | `aacdf30bfd184b28829176c9317c1e13` | content | 1 | 1 | +nav菜单 |
| 规章制度 | `9ff9d81c8a974d30b1ad6165e42d9d69` | notice-small | 5 | 1 | +nav菜单 |
| 联系我们 | `b4651b925328422a88b45a25c62a3c91` | opinion | —(code 500) | — | +nav菜单 |

#### dwxsgzb（党委学生工作部(武装部)）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `0d1465a0513849478c548011f79d2627` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `5e5ccfadac6141d29528c277d282d989` | notice | 187 | 10 | 首页板块+nav菜单 |
| 学工动态 | `96860085dd1343fe943695b3fd32ae4e` | news | 131 | 7 | 首页板块+nav菜单 |
| 学生事务 | `6aa596bc755e42bab6533741123499b6` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 心理健康 | `07e58186827f41359eca42c0534f1ea6` | notice-small | 160 | 8 | 首页板块+nav菜单 |
| 部门概况 | `3e79dec310144d7c9a9219a1bcf2dc78` | content | 2 | 1 | +nav菜单 |
| 一站式学生社区 | `ef48b3ce3bdc48289e30bfdfd211e6e3` | news | 3 | 1 | +nav菜单 |
| 资料下载 | `5004cc34130044858bf7cc0c1006928a` | download | 12 | 1 | +nav菜单 |
| 联系我们 | `abb5b948056542609cda4afdb1f39382` | opinion | —(code 500) | — | +nav菜单 |

#### tw（团委）· 11 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `f923d5cbb7bf48e2b6f403ab0ac9f834` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `48f73004e7e146459b6ee9f8921113d7` | notice | 76 | 4 | 首页板块 |
| 团学动态 | `24b1083a1a1045cf8d2d98ae8ea251d6` | news | 121 | 7 | 首页板块 |
| 校园活动 | `97fd831b59694b62bba10bb688dd8094` | thematic-center | 205 | 11 | 首页板块 |
| 部门概况 | `9f8db6310f0944ae924c9311c7b4aedd` | content | 1 | 1 | +nav菜单 |
| 学生组织 | `232c84eb2cea4c92880da467b5881dce` | news | 33 | 2 | +nav菜单 |
| 志愿服务 | `9c15af2f31df416f8b60b4abe07bd1e2` | news | 60 | 3 | +nav菜单 |
| 多彩社团 | `1a318b23eb3d46de9c23da2c7cc56e09` | news | 82 | 5 | +nav菜单 |
| 第二课堂 | `1eea07ac3f7d4b3389bf7d68353a76c6` | news | 12 | 1 | +nav菜单 |
| 资料下载 | `b93624fb9bba4309b58df6f7e224ad3c` | download | 6 | 1 | +nav菜单 |
| 联系我们 | `97f9f2567eeb4594ba25c87cd45edeaf` | opinion | —(code 500) | — | +nav菜单 |

#### rlzyc（人力资源处）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `afc5b542ca2f4d919f216ed614036522` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `b646b227cbe84406b675188b45afadc8` | notice | 25 | 2 | 首页板块+nav菜单 |
| 新闻动态 | `89fbe7b24be740aca916256fa9520e83` | news | 22 | 2 | 首页板块+nav菜单 |
| 人才招聘 | `903c9ab0163943a3948c0790deac9a1e` | notice-small | 8 | 1 | 首页板块+nav菜单 |
| 教师发展 | `9d2c8e793a3f4f4b9cf669b0fc16b87c` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 部门概况 | `a78ee97e57564182b7abe50e207aacc2` | tabs-sub | 0 | 0 | +nav菜单 |
| 规章制度 | `72940768ecdc4b7b9bd5f7f87b5b115f` | notice-small | 4 | 1 | +nav菜单 |
| 人资系统 | `dd61f79263ad494880fd152b6dc1d32b` | link | —(code 500) | — | +nav菜单 |
| 联系我们 | `1fb8ff4c6a77483a99236e2638e019e2` | opinion | —(code 500) | — | +nav菜单 |

#### cwc（财务资产管理处）· 7 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `5a72681e559541d290feb043b51bebdf` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `6b257fbc0dd54177ba6d4bb76029dbe0` | notice | 0 | 0 | 首页板块+nav菜单 |
| 规章制度 | `51442a773f204e06b619f33f3e5c6ad5` | notice-small | 0 | 0 | 首页板块+nav菜单 |
| 管理流程 | `89f1f57c3af340e68b962738d98beb46` | notice-small | 0 | 0 | 首页板块+nav菜单 |
| 部门概况 | `9415e1ec55a84824b1065dea7a7a7e16` | content | 1 | 1 | +nav菜单 |
| 资料下载 | `d5fad86747284ce59f58321c1171867d` | download | 0 | 0 | +nav菜单 |
| 联系我们 | `728fc8fbd2324cd6ba5ff1ecfb07b9d1` | opinion | —(code 500) | — | +nav菜单 |

#### jwc（教务处）· 8 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `e754bb10580140d5bedf530b7db5518e` | (空) | —(code 500) | — | +nav菜单 |
| 教务动态 | `1e5c01825020441191c57a1d2ee4a06d` | news | 245 | 13 | 首页板块+nav菜单 |
| 通知公告 | `94511e8fcb8c49b4a1ade5d2fda8a03b` | notice | 378 | 19 | 首页板块+nav菜单 |
| 规章制度 | `4f0ffb3878b64411ba559295b411cf1c` | notice-small | 12 | 1 | 首页板块+nav菜单 |
| 校园日历 | `d0fb6bbd281144eebd8f817bb38c12b0` | calendar | —(code 500) | — | 首页板块 |
| 部门概况 | `56452645823242098c7c1a8f6773c691` | content | 1 | 1 | +nav菜单 |
| 资料下载 | `8f56d6aedede4101b2aa9e8f81cc6ce6` | download | 17 | 1 | +nav菜单 |
| 联系我们 | `5a7abcce286d4596bd98519e3d22072a` | opinion | —(code 500) | — | +nav菜单 |

> jwc 通知公告 total=378，**size=20 时 19 页**；实机点击默认 `size=8` 时展示为 **48 页**（浏览器实捕），两者一致（ceil(378/8)=48）。

#### zsw（招生网）· 7 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 招生网 | `558d002ca3be4640afec80d1ab0fb4e2` | (空) | 0 | 0 | +nav菜单 |
| 首页一屏3栏目 | `0f51c32c9a8f43af99cf1fc2522be3d9` | recruit | —(code 500) | — | 首页板块 |
| 招生计划 | `3dcb7a8714cb48bc9067531ce7382f7c` | news | 6 | 1 | 首页板块 |
| 招生公告 | `544db2a75af445be89ce777b834fbcac` | notice | 21 | 2 | 首页板块 |
| 报考指南 | `d11f4653ed8a4b50a43565c288f54074` | tabs | 0 | 0 | 首页板块 |
| 招生动态 | `35f6a01d451f4cc1b0f5704fab71dfcb` | notice | 108 | 6 | 首页板块 |
| 就业信息网 | `bad9100e431544e489c5829dfd98270a` | link | —(code 500) | — | +nav菜单 |

#### hqglc（后勤管理处）· 4 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `744f25fe88f24669a26f97cf12809a03` | (空) | —(code 500) | — | +nav菜单 |
| 工作动态 | `2761dde1e81a4807b4615892bacd3374` | news | 28 | 2 | 首页板块+nav菜单 |
| 通知公告 | `ad045d9f41344e8a80bc3ef85faf13e4` | notice | 5 | 1 | 首页板块+nav菜单 |
| 部门概况 | `c17ec145e1ce42b0afa77da55bc3d030` | tabs-sub | 0 | 0 | +nav菜单 |

#### kyc（科研处）· 8 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `7b7ecc65868a4962845ab96ad4104b4a` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `6a38de1f30d2418b98caab5a82e55383` | notice | 72 | 4 | 首页板块 |
| 科研动态 | `4192b11be03d404b9c7eef81bfc675ac` | news | 30 | 2 | 首页板块+nav菜单 |
| 资料下载 | `a0e87750c04441b29a58c9dbb392d0de` | download | 2 | 1 | 首页板块+nav菜单 |
| 部门概况 | `05550caf30594ff186dc71d64987e29e` | content | 1 | 1 | +nav菜单 |
| 科研政策 | `6cfbb5241f434d5e8b2801ba77993ba3` | notice-small | 4 | 1 | +nav菜单 |
| 科研项目 | `f4689b4b63b44855a2daae9944ed00d4` | notice-small | 5 | 1 | +nav菜单 |
| 科协工作 | `b550d64b6e0d4cfe9e3b0e27f396cea0` | notice-small | 3 | 1 | +nav菜单 |

#### dwbwb（保卫处）· 5 栏（site_id 特例站点）
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `026e017e53274c76aede09d23d5dae9b` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `9bdbe332e48c4384b7dcace91e43c8ac` | notice | 6 | 1 | 首页板块 |
| 工作动态 | `b0405cff28ad4e069f602b5fc81d3c51` | news | 10 | 1 | 首页板块+nav菜单 |
| 管理流程 | `75a4b94d309b4e58822be98c6f89bd3d` | notice-small | 2 | 1 | 首页板块+nav菜单 |
| 部门概况 | `87faa749da6b42a9876c8ce33d46cd6b` | content | 1 | 1 | +nav菜单 |

> **保卫处 site_id 特例**：`school/org` 中保卫处 `site_id=null`，其真实 `site_id=21184757a5c84833be6abf2cf2bede3f` **只能从 `/dept/home2?site_key=dwbwb` 响应的 `data.site.site_id` 取得**。同类特例还有校长办公室（124）、学生工作处（133）。其余站点 org 树 site_id 与 home2 完全一致。

#### xcdsj（信创与大数据学院）· 10 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `817df509097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 学院概况 | `817cc143097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院映像 | `f08f4cbb5cbe44cea57899cf39d2b3f1` | videos | 0 | 0 | 首页板块 |
| 最新动态 | `817d943f097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院新闻 | `817dfe40097911f08df500163e031f40` | news-important | 389 | 20 | 首页板块+nav菜单 |
| 专题中心 | `817d9787097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 党群工作 | `817ccbd5097911f08df500163e031f40` | news | 6 | 1 | +nav菜单 |
| 通知公告 | `817cb9ee097911f08df500163e031f40` | notice | 53 | 3 | +nav菜单 |
| 师生风采 | `817e0afe097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 联系我们 | `817cb724097911f08df500163e031f40` | 0 | —(code 500) | — | +nav菜单 |

#### znzzcl（智能制造与车辆学院）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `878d24aef10f4c4a9e6a11354ae2893c` | (空) | 0 | 0 | +nav菜单 |
| 学院概况 | `1e11ad33de934843a9300c2192d50c95` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 最新动态 | `7e169361226d48b2b0a4eba762efc1ab` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院新闻 | `ae829fc3e34b4224accb377c8137d32e` | news-important | 226 | 12 | 首页板块+nav菜单 |
| 专题中心 | `8567ad37b89d4e88b69f30d3d63ce01a` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 党群工作 | `490043875e184ad49f86f909fdd2c839` | news | 12 | 1 | +nav菜单 |
| 通知公告 | `03b20b47f4c14686b4339adcb350d18d` | notice | 30 | 2 | +nav菜单 |
| 师生风采 | `e7edea826c1c4664896392608104cf17` | (空) | 0 | 0 | +nav菜单 |
| 联系我们 | `03a0427287244c1fabd49c5185ed0be9` | (空) | —(code 500) | — | +nav菜单 |

#### sxy（商学院）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `817d98fb097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 学院概况 | `817cc08f097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 最新动态 | `817d93c4097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院新闻 | `817dfdcb097911f08df500163e031f40` | news-important | 97 | 5 | 首页板块+nav菜单 |
| 专题中心 | `817d96db097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 党群工作 | `817ccb21097911f08df500163e031f40` | news | 12 | 1 | +nav菜单 |
| 通知公告 | `817cb932097911f08df500163e031f40` | notice | 149 | 8 | +nav菜单 |
| 师生风采 | `817e0a91097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 联系我们 | `817cb66c097911f08df500163e031f40` | 0 | —(code 500) | — | +nav菜单 |

#### clhj（材料与环境学院）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `817d994d097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 学院概况 | `817cc0ea097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 最新动态 | `817d9403097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院新闻 | `817dfe08097911f08df500163e031f40` | news-important | 306 | 16 | 首页板块+nav菜单 |
| 专题中心 | `817d9733097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 党群工作 | `817ccb79097911f08df500163e031f40` | news | 6 | 1 | +nav菜单 |
| 通知公告 | `817cb997097911f08df500163e031f40` | notice | 103 | 6 | +nav菜单 |
| 师生风采 | `817e0ac8097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 联系我们 | `817cb6c7097911f08df500163e031f40` | 0 | —(code 500) | — | +nav菜单 |

#### wfxy（文法学院）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `817d98ac097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 学院概况 | `817cc037097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 最新动态 | `817d9342097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院新闻 | `817dfd93097911f08df500163e031f40` | news-important | 215 | 11 | 首页板块+nav菜单 |
| 专题中心 | `817d9692097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 党群工作 | `817ccacc097911f08df500163e031f40` | news | 9 | 1 | +nav菜单 |
| 通知公告 | `817cb8d7097911f08df500163e031f40` | notice | 75 | 4 | +nav菜单 |
| 师生风采 | `817e0a59097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 联系我们 | `817cb611097911f08df500163e031f40` | 0 | —(code 500) | — | +nav菜单 |

#### ysxy（艺术学院）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `817d9857097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 学院概况 | `817cbfdb097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 最新动态 | `817d9305097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院新闻 | `817dfd56097911f08df500163e031f40` | news-important | 127 | 7 | 首页板块+nav菜单 |
| 专题中心 | `817d9655097911f08df500163e031f40` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 党群工作 | `817cca70097911f08df500163e031f40` | news | 4 | 1 | +nav菜单 |
| 通知公告 | `817cb876097911f08df500163e031f40` | notice | 22 | 2 | +nav菜单 |
| 师生风采 | `817e0a20097911f08df500163e031f40` | (空) | 0 | 0 | +nav菜单 |
| 联系我们 | `817cb53e097911f08df500163e031f40` | 0 | —(code 500) | — | +nav菜单 |

#### mkszy（马克思主义学院(思想政治教育工作部)）· 8 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `54923a7f067044da8f2bcefcacadc5db` | (空) | —(code 500) | — | +nav菜单 |
| 新闻动态 | `43d355952eb94dfc8a67a0b8ee40c34c` | news | 59 | 3 | 首页板块 |
| 经典著作 | `5785fab012ae4a5089c38d9b12833b24` | electronic-book | 11 | 1 | 首页板块 |
| 学院概况 | `e2739752a3054783acd80336b1ea9c11` | tabs-sub | 0 | 0 | +nav菜单 |
| 师资队伍 | `9ff7638840154505bb071c5bcd42642c` | teacher | —(code 500) | — | +nav菜单 |
| 党建工作 | `0fa97cdc3ca8487bbfc9a17107e81bd1` | notice | 10 | 1 | +nav菜单 |
| 课程建设 | `9124486758c24e38b1404cce45814c5b` | tabs | 0 | 0 | +nav菜单 |
| 制度文件 | `dbb405efccc3474e84cf11ab77550fd3` | notice-small | 3 | 1 | +nav菜单 |

#### tsxuey（通识教育学院）· 8 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `841e96272eab4e6b9bee701a97afd88e` | 0 | —(code 500) | — | 首页板块+nav菜单 |
| 学院新闻 | `e5db7a5e4a6f458a99e24f62a08f32e5` | news | 40 | 2 | 首页板块 |
| 通知公告 | `9cd27c1fc1894163abf2d14d9ef5eaf2` | notice | 4 | 1 | 首页板块 |
| 学院概况 | `30d23c1da1794a52b9a23a71ecebed41` | tabs-sub | 0 | 0 | +nav菜单 |
| 师资队伍 | `d3eae7704cbb4a1493fa9903b2e7042b` | teacher | —(code 500) | — | +nav菜单 |
| 课程建设 | `24b75b6a6b9841139d6d4918c4b92ea6` | tabs | 0 | 0 | +nav菜单 |
| 制度文件 | `0390899b565042c78926a70ddd69f7e7` | notice-small | 3 | 1 | +nav菜单 |
| 联系我们 | `4e344db05a9f49ab941e8795ca1fb77c` | opinion | —(code 500) | — | +nav菜单 |

#### gjjljxjy（国际交流与继续教育学院）· 8 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `1f2b9c8c5c8b4327837bb8adca0c32e8` | (空) | —(code 500) | — | +nav菜单 |
| 学院新闻 | `8510bec9f574408d96a34a4a01b6623c` | news-important | 4 | 1 | 首页板块+nav菜单 |
| 国际交流 | `a9929c515c544f6e8c000f4aabb18c14` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 继续教育 | `eeb3fec84daa4915a652e65a29573ee0` | tabs | 0 | 0 | 首页板块+nav菜单 |
| 学院概况 | `38b815924f894ec8a147a012a2b4ce88` | content | 1 | 1 | +nav菜单 |
| 党群工作 | `911308fbb056441c8d0f789096972653` | news | 3 | 1 | +nav菜单 |
| 通知公告 | `294a3bd5970d4e1896c461abade2c643` | notice | 6 | 1 | +nav菜单 |
| 联系我们 | `05939b4157884eed9a718276fa7fc00d` | opinion | —(code 500) | — | +nav菜单 |

#### scxy（创新创业学院）· 7 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `d92ed0da3ca9444db7dd86b22822df4e` | 0 | —(code 500) | — | +nav菜单 |
| 学院概况 | `4f79f3c5b3504e3db88c6fffc7b5f9cf` | content | 0 | 0 | +nav菜单 |
| 竞赛天地 | `3ae5f7606d37411a86109d60662e35cf` | notice | 7 | 1 | +nav菜单 |
| 实践平台 | `db326e7522d64df4a247fed00cee1af5` | notice | 0 | 0 | +nav菜单 |
| 双创教育 | `23c1ea42e4b94cd39f26cae179916345` | notice | 5 | 1 | +nav菜单 |
| 产教融合 | `40a53c709a2b4ed88356a6f108d15523` | notice | 2 | 1 | +nav菜单 |
| 资料下载 | `648b32aedb0f4bf497a1887f0c67adc6` | download | 0 | 0 | +nav菜单 |

#### tsg（图书馆）· 9 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `782e7aab012e4ea8b631f0a43344d516` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `9f5b28bb82a1432dad295a382953f0ca` | notice | 11 | 1 | 首页板块+nav菜单 |
| 最新动态 | `f32bf05a5c5448fbb37c95fe13d211bc` | news | 11 | 1 | 首页板块 |
| 规章制度 | `267438ef0d884f559b2eb24c0a0cb3e2` | notice-small | 10 | 1 | 首页板块 |
| 电子图书 | `b5d75a637d31451bb2472b519711de34` | electronic-book | 3 | 1 | 首页板块 |
| 图书馆介绍 | `b8668183e46f45628df026fabc4670bb` | content | 1 | 1 | +nav菜单 |
| 知网 | `164a84cc8c88424d9f27380b21df13c8` | link | —(code 500) | — | +nav菜单 |
| 电子图书 | `54e4fae1805845cb9a32c456ef82dea8` | link | —(code 500) | — | +nav菜单 |
| 联系我们 | `756d9a65752f4b3e96cd2b5559bec4a0` | opinion | —(code 500) | — | +nav菜单 |

#### sjjxglzx（实践教学管理中心）· 7 栏
| 子栏目 | column_id | componentType | 条数(total) | 页数 | 来源 |
|---|---|---|---|---|---|
| 首页 | `1a58e8798b304d189f5c27e64b54b683` | (空) | —(code 500) | — | +nav菜单 |
| 通知公告 | `e10d0710922243d796f673cc6a449cf3` | notice | 5 | 1 | 首页板块 |
| 工作动态 | `954556fb3009474e82a94956267f49f7` | news | 69 | 4 | 首页板块+nav菜单 |
| 实验室建设 | `aa2dad41960140f1a060192adf255715` | news | 8 | 1 | 首页板块+nav菜单 |
| 规章制度 | `3067b8225d6741829d765cb8f35a29ba` | notice-small | 24 | 2 | 首页板块+nav菜单 |
| 部门概况 | `1dbf6bddc0f44b57a59e45d1ad86456b` | content | 1 | 1 | +nav菜单 |
| 联系我们 | `2beb02df103c4dc4b5796a2d1f8d4e86` | opinion | 0 | 0 | +nav菜单 |

**逐站点栏目数核算**：8+9+11+9+7+8+7+4+8+5+10+9+9+9+9+9+8+8+8+7+9+7 = **178** ✅（与 agentB 采集总数一致）。

#### 首页板块独有栏目（不在 nav 菜单、仅在 home2 首页板块出现）

> 判定口径：`/dept/home2` 中该栏目出现于「首页板块」但**未**出现在 `nav` 菜单里——此类栏目没有菜单入口，但 `column_id` 仍可直接用于 `/common/column/articles`。

| site_key | 首页板块独有栏目 | 个数 |
|---|---|---|
| dzbgs | 通知公告 | 1 |
| tw | 通知公告、团学动态、校园活动 | 3 |
| jwc | 校园日历 | 1 |
| zsw | 首页一屏3栏目、招生计划、招生公告、报考指南、招生动态 | 5 |
| kyc | 通知公告 | 1 |
| dwbwb | 通知公告 | 1 |
| xcdsj | 学院映像 | 1 |
| mkszy | 新闻动态、经典著作 | 2 |
| tsxuey | 学院新闻、通知公告 | 2 |
| tsg | 最新动态、规章制度、电子图书 | 3 |
| sjjxglzx | 通知公告 | 1 |
| **合计** | **11 个站点 / 21 个栏目** | 21 |

> **差异标注**：任务描述预期「16 站点」，实测（两种口径均验证：①某栏目 sources 仅含 `home-block` 不含 `nav`；②站点 `columns` 数 > `nav_count`）结果均为 **11 个站点**。以实测 11 为准，此处如实记录该差异，未按 16 强行凑数。

### 3.5 列表项字段表（`/common/column/articles` 的 `articles.list[]`）

> 88 条抽样条目字段集完全一致、稳定。

| 字段名 | 类型 | 含义 | 示例值 |
|---|---|---|---|
| `id` | string | 文章唯一 ID（**即 `article_id`，直接送详情接口**） | `046e6ed45ce64980a67f471b8efc157b` |
| `title` | string | 标题 | `关于开展2026-2027学年第一学期新生开课课堂专项督导的通知` |
| `description` | string | 摘要/正文纯文本预览（含 `\r\n`） | `各学院：为进一步强化本科教学过程管理…` |
| `image_url` | string | 封面图 URL；**无图时为占位图** | `https://www2.sxjzit.edu.cn:8082/images/no_picture.webp` |
| `create_time` | string | 创建/发布时间 `YYYY-MM-DD HH:mm:ss` | `2026-09-26 14:22:35` |
| `update_time` | string | 更新时间（ISO，仅日期有效） | `2026-09-26T00:00:00` |
| `tag` | string | 标签（列表接口未见有值，恒为空串） | `` |
| `sort` | int | 排序权重（列表接口未见有值，恒为 0） | `0` |

> 列表项**不含正文全文**；正文需另走 `/common/article/detail`。
> 补充：`/common/article/page`（App 招生网用）的列表项额外含 `out_link`、`source` 字段；该接口**正确参数是 `page`/`size`（默认 size=10）**，且**与 `/common/column/articles` 非同源等价**（同栏目 total 不同，见 §1.1 实测）。

### 3.6 翻到底验证结论

对每个站点「最大栏目」执行翻底校验（`size=20`）：

- `page=last` → 列表**非空**，条数 = `total - (last-1)*size`（末页实取数）✅
- `page=last+1` → **空数组 `list:[]`**，不报错，`total` 保持不变 ✅
- 抽样（22 站全覆盖，明细见 `agentB_sites.md`），例：dzbgs 通知公告 total=23 → p2 取 3/3、p3 空；jwc 通知公告 total=378 → p19 取 18/18、p20 空；xcdsj 学院新闻 total=389 → p20 取 9/9、p21 空；tw 校园活动 total=205 → p11 取 5/5、p12 空。
- 原始证据：`raw/list_<site_key>_<column_id>_lastp<N>.json` 与 `_lastp<N+1>.json`。

---

## 4. §3 内容分类与板块

### 4.1 子栏目机制

- 一个「子栏目」= 部门/学院页 `#/departments/page?site_key=<key>&page=<该栏目 title_en>` 下的一个 tab 面板；路由切换只是前端行为，**数据都走同一个接口、不同 `column_id`**：
  - 列表型栏目（news/notice/download 等）→ `/common/column/articles?site_id&column_id&page&size`
  - 板块预览型 → `/common/column/oneTwoArticles?site_id&column_id`（须传根栏目 id）
  - **「部门概况」不是列表**，是文章详情：`page=introduction` 直接调 `/common/article/detail?article_id=<该栏目文章 id>`（jwc 为 `97a6d8d724984e28b16924feb1f56e10`），部分站点（rlzyc/hqglc/mkszy/tsxuey）的「部门概况」是 `tabs-sub` 型（二级 tab，`total=0`）
- 首页（`page=home`）**不调列表接口**：全部板块数据由 `/dept/home2`（或 `/college/home`）一次聚合返回；仅当板块点击「更多」时才用 `column/articles`/`oneTwoArticles` 分页。

### 4.2 栏目类型（`componentType`）语义 → 对列表接口的行为

| componentType | 出现次数 | 对 `/common/column/articles` 的行为 | 含义 |
|---|---|---|---|
| `(空)` / `0` | 27+7 | `code 500`（14/27）+ `ok`（13/27，多为学院「首页」「师生风采」total=0） | 结构性栏目（首页/师生风采等），无列表文章 |
| `notice` | 26 | ✅ 全 ok | 通知公告类（大 total，如 378） |
| `news` | 25 | ✅ 全 ok | 新闻动态类 |
| `tabs` | 26 | ✅ 全 ok，`total=0` | tab 型栏目，文章挂在子组件（二级 tab），列表接口无文章 |
| `tabs-sub` | 4 | ✅ 全 ok，`total=0` | 二级 tab（如「部门概况」的再分栏） |
| `notice-small` | 16 | ✅ 全 ok | 小型通知（规章制度/管理流程等） |
| `content` | 11 | ✅ 全 ok，`total=1`（单篇，如部门概况/图书馆介绍）；**例外：dwxsgzb「部门概况」`total=2`**（2026-10-01 全量扫描确认，稳定值——前端取首篇即可） | content 型单页（个别站点多篇） |
| `opinion` | 10 | 9 个 `code 500`，1 个 ok(total=0) | 联系我们（校长信箱表单），无列表文章 |
| `download` | 7 | ✅ 全 ok | 资料下载 |
| `news-important` | 7 | ✅ 全 ok（学院新闻，大 total） | 重要新闻（学院置顶大图） |
| `link` | 4 | 全 `code 500` | 外链栏目（人资系统/就业信息网/知网），不提供列表 |
| `electronic-book` | 2 | ✅ 全 ok（11/3） | 电子图书（经典著作） |
| `teacher` | 2 | 全 `code 500` | 师资队伍（走 `/common/teacher/page`，不走列表接口） |
| `thematic-center` | 1 | ✅ ok（205） | 专题中心（tw 校园活动） |
| `calendar` | 1 | `code 500` | 校园日历（走 `/school/events`，不走列表接口） |
| `recruit` | 1 | `code 500` | 招生查询（走 POST `/common/recruit/query`） |
| `videos` | 1 | ✅ ok（total=0） | 学院映像 |

> 统计口径来自 agentB 的 178 个子栏目；「`code 500`」= body 里业务错误（**HTTP 仍 200**）。**`total=0/1` 与 `code 500` 都是"正常业务结果"，不是网络错误**——客户端要按栏目类型分发，别把 code 500 当失败弹出。

### 4.3 特殊板块结论

**机构设置页（`#/departments/list`）无置顶/推荐/轮播板块**（含证据）：
- 实机 DOM 检查：`carouselEls=0`；`main h2 = 39 个`（5 个分组标题 + 34 个机构）；正文关键词「置顶/推荐/轮播/热点」**均不存在**。
- 图片仅：`departments-banner-img`、`departments-banner-mask`、`departments-logo-img ×4`（分组图标）。
- 网络面板仅两个请求：`GET /mapi/dept/home2`（无 site_key，父页壳）+ `GET /mapi/school/org`（列表数据）。
- **结论：机构设置页是纯静态分组卡片列表**，无任何置顶/推荐/轮播接口。证据：`network-capture.md` 步骤 7。

**学院页含轮播**：`#/college?site_key=xxx` 存在 `college-tab-carousel-mask-card-img ×N`（学院首页置顶大图 + 学院概况 tab 轮播「学院发展/专业介绍」）；数据来自 `/college/home` 返回的板块（`college-introduction` 等）。部门页未发现轮播。

### 4.4 一二级栏目混合文章 `/common/column/oneTwoArticles`

| 项 | 值 |
|---|---|
| URL | `GET https://gwqietap.sxjzit.edu.cn/mapi/common/column/oneTwoArticles?site_id=<sid>&column_id=<cid>` |
| 参数 | `site_id` 必填、`column_id` 必填 |
| **关键坑** | `column_id` **必须传该站点的顶层根栏目 id**（`parent_id` 指向站点外的那个），传一级子栏目 id 会 `code 500` |
| jwc 根栏目 id | `66e9645f4eee4f2ead37a8fe1223d7fb`（jwc nav 下所有栏目 parent_id 都是它；自 `/dept/home2?site_key=jwc` 的 nav 取根） |
| 响应结构 | `data = {column_id, title_cn:"栏目", title_en, is_out, href, site_id, children:{total:8, list:[column,...]}}` |
| 每个 column | `{id, title_cn, title_en, is_out, href, image_url, site_id, componentType(""/content/news/notice/notice-small/download/opinion/calendar), articles:{total,list}}` |
| `articles.list[]` | 字段同 §3.5（`id` 即 article_id），但 `tag` 为**空格分隔关键词**、`sort` 数字越大越靠前、`create_time` 为空格分隔本地时间；`articles.list` 可能为 `null`（total=0，如联系我们/校园日历） |
| 与 column/articles 关系 | **互补**：oneTwoArticles 每栏目固定返回约 10 条（板块预览），column/articles 负责翻页/全量 |
| 原始证据 | `raw/oneTwo_66e9645f4eee4f2ead37a8fe1223d7fb.json`（成功）；`raw/oneTwo_jwc.json` / `raw/oneTwo_jwc_nocol.json` / `raw/oneTwo_noparam.json` / `raw/oneTwo_e754bb10580140d5bedf530b7db5518e.json`（500 反例） |

---

## 5. §4 文章详情

### 5.1 `/common/article/detail` 契约

| 项 | 值 |
|---|---|
| URL | `GET https://gwqietap.sxjzit.edu.cn/mapi/common/article/detail?article_id=<id>` |
| 参数 | `article_id`：String / **必填**（`id=` 无效 → `400 参数[article_id]为必填项`；无参同样 400） |
| 响应 | `{"code":200,"data":{...}}`；HTTP 恒 200 |
| article_id 形态 | **按字符串透传**：既可能是纯数字（旧文章 `162`、`2305`），也可能是 32 位十六进制（新文章 `046e6ed45ce64980a67f471b8efc157b`），**勿做数字强转** |
| 请求头 | 无需（无 token/鉴权；axios 只配 baseURL+timeout，request 拦截器为空） |
| 详情页路由 | `https://www.sxjzit.edu.cn/#/list/article?id=<article_id>` |
| 原始证据 | `raw/ep_article_detail.json`、`raw/probe_id.json`（id= 无效证据） |

### 5.2 `data` 字段表（仅 5 个，无作者/来源/发布时间/附件数组字段）

| 字段 | 类型 | 示例 | 说明 |
|---|---|---|---|
| `title` | string | `党委组织部` | 文章标题（纯文本） |
| `update_time` | string | `2025-04-24T00:00:00` | ISO 无时区；**前端即用它当"发布时间"**（渲染 `2025/04/24 发布`） |
| `content` | string(HTML) | `<p style="text-indent: 24pt;..."><img src="...">...` | 正文 HTML 片段（内联 style/img/a，**无外层 html/body 包裹**） |
| `href` | string | `""` | 外链跳转地址；**为空即普通文章**，非空时前端 `window.open(href)` |
| `image_url` | string | `https://www2.sxjzit.edu.cn:8082/zhglxt/profile/upload/2025/04/24/zzb_20250424112131A957.webp` | 封面图绝对 URL |

> 前端渲染（`chunks/BaseArticle-BPh4Iu2U.js`）：`h2.title` ← `title`；时间 ← `getHandleTime(update_time,"/")`；正文 ← `<article class="base-article-content" innerHTML={content}>`。"来源/作者"如存在只会出现在 content 正文里。

### 5.3 资源拼接规则

- **正文图片全部是绝对 URL，无需拼前缀**（10 篇抽样 10/10 绝对地址，0 相对路径）。
- host 唯一：**`www2.sxjzit.edu.cn:8082`**（无多域名/无 CDN）。
- 路径前缀两类：
  - 正文图：`/zhglxt/profile/cms/upload/YYYY/MM/DD/<名>_<时间戳>A<n>.webp|jpg`
  - 封面图 `image_url`：`/zhglxt/profile/upload/YYYY/MM/DD/...` 或 `/zhglxt/profile/userfiles/system/images/...`
  - 占位图：`https://www2.sxjzit.edu.cn:8082/images/no_picture.webp`（列表无图时）
  - 文件名**可能含中文与空格**（如 `图层 733_20250330201837A001.webp`）→ URL 必须做 percent-encode。
- **协议混用**：10 条正文图 9 条 `http://`、1 条 `https://`；`image_url` 字段 10/10 为 `https://`。消费方应把 `http://` 修正为 `https://`。
- **http→https 跳变丢端口**：`http://www2.sxjzit.edu.cn:8082/...` 返回 **302**，`Location` **去掉 `:8082` 端口**；`https://www2.sxjzit.edu.cn:8082/...` 与 `https://www2.sxjzit.edu.cn/...`（无端口）均直接 **200 image/webp**。结论：消费方把 http→https 即可，端口保留/去掉均可访问。
- **无防盗链**：加不加 `Referer: https://www.sxjzit.edu.cn/` 结果一致，无需 Referer。
- SPA 自身**不做任何 URL 重写**（bundle 无 `replace("http://"...)`），直接 innerHTML 注入，依赖浏览器跟随 302。
- 原始证据：`raw/img_check.txt`（10 篇正文图 https 复测日志）、`departments-api-evidence/img_check.txt`。

### 5.4 附件坑位

- **详情接口没有独立附件字段/数组**；附件以正文内联 `<a href>` 形式出现（前端靠后缀正则 `\.(pdf|doc|docx|xls|xlsx|ppt|pptx|zip|rar|txt)$` 嗅探接管下载）。
- 附件多为**第三方金山文档（kdocs.cn）外链**，不落在 `www2.sxjzit.edu.cn` 上（例：`a94feef0…` 正文 `https://www.kdocs.cn/l/cuzyYzCoXEd0`；`缓考申请表` 正文 `&lt;a href=" https://www.kdocs.cn/l/cs9qWedsSF0X" target="_blank"&gt;`）。
- **坑 1**：href 值带**前导空格**（`" https://…"`），消费方必须 `trim()`，否则 URL 非法。
- **坑 2**：真实文章正文发现**残留本地绝对路径** `<img src="file:///C:\Users\XX\AppData\Local\Temp\ksohtml28180\wps1.png">`（WPS 粘贴残留），消费方需过滤 `file://` / 非 http(s) 的 src。
- 原始证据：`raw/detail_art_01223003.json`（file:// 残留）、`raw/detail_art_a94feef0.json`（kdocs 外链）、`raw/detail_art_162.json`（数字 id 旧数据）。

### 5.5 10 个单文章机构验证表

请求：`GET /common/article/detail?article_id=<id>`；10/10 全部 HTTP 200 / body.code 200 / message=success，`title` 与机构名一致，正文均为「一张机构职责图 + 简短说明」型 HTML（1.2–2.7 KB），`href` 10/10 为空。

| article_id(前8) | 机构 | title | update_time | 正文长度 | HTML | 正文图 https 复测 |
|---|---|---|---|---|---|---|
| `697c6771` | 党委组织部 | 党委组织部 | 2025-04-24 | 1738 | 是 | 200 image/webp |
| `27a40b0a` | 党委宣传部 | 党委宣传部 | 2025-04-24 | 1691 | 是 | 200 image/webp |
| `20768d27` | 党委统战部 | 党委统战部 | 2025-04-24 | 1740 | 是 | 200 image/webp |
| `e8c51530` | 纪检监察办公室 | 纪检监察办公室 | 2025-04-24 | 1864 | 是 | 200 image/webp |
| `c94f0d88` | 党委教师工作部 | 党委教师工作部 | 2025-04-24 | 1245 | 是 | 200 image/webp |
| `0bde63d0` | 思想政治教育工作部党支部 | 思想政治教育工作部党支部 | **2026-08-25** | 1745 | 是 | 200 image/webp |
| `0fc43da1` | 工会 | 工会 | 2025-04-24 | 2652 | 是 | 200 image/webp |
| `5efa8bd8` | 妇联 | 妇联 | 2025-04-24 | 1670 | 是 | 200 image/webp |
| `743ed5d2` | 科协 | 科协 | 2025-04-24 | 2292 | 是 | 200 image/webp |
| `56ad9602` | 关心下一代工作委员会 | 关心下一代工作委员会 | 2025-04-24 | 1810 | 是 | 200 image/webp |

> 9 篇 update_time 为 2025-04-24（同批录入），仅思政党支部为 2026-08-25。原始文件：`raw/detail_<前8>.json` × 10。

---

## 6. §5 搜索

| 项 | 值 |
|---|---|
| URL | `GET https://gwqietap.sxjzit.edu.cn/mapi/common/search?key_words=<urlencode(关键词)>&p=<页码>&s=<每页条数>` |
| 参数 | `key_words`：String / **必填**（无参 → `400 参数[key_words]为必填项`）；`p`：Int / 默认 1；`s`：Int / 默认 10。**参数名不是 keyword/q/page** |
| 响应结构 | `data.{total, list[{id, title, description}]}`；命中词在 title/description 中以 `<em>` 包裹高亮 |
| 页面路由 | 搜索结果页 `https://www.sxjzit.edu.cn/#/list/search?key_words=<urlencode(关键词)>`（页面自带输入框「搜索您想要的内容」） |
| 已验证样例 | `key_words=考试&p=1&s=10` → 200；`key_words=考试&p=2&s=5` → total 49、返回 5 条 |
| 实机要点 | 顶部搜索浮层输入后回车**不触发请求**（浮层无提交/无联想，疑似仅装饰）；等效做法是**直接访问 `#/list/search` 路由**并在页内输入框提交。另：带 `?key_words=考试` 直访搜索页**不会自动发请求**（仅显示搜索历史），必须页面内提交 |
| 原始证据 | `raw/ep_search_kaoshi.json`、`raw/ep_search_ks_p2s5.json`、`raw/ep_search_nokw.json` |

---

## 7. §6 其他关联接口

### 7.1 校园日历正确入口结论（重点）

- **不存在独立的校园日历页面**。校园日历是「部门页首页」内的一个板块（tab 面板），无自己的一级路由。
- 实机反证：`#/departments/calendar` → NotFound（「哎呀，打不开页面了呢！」）；`#/campus/calendar` → NotFound。
- `app.js` 中**无 `/departments/calendar`、无 `/campus/...` 路由**（`/:catchAll(.*)*` 兜底 NotFound）。`Main-*.js` 里的 `"/campus"` 只是头部菜单 path 的 `split("--")` 分割逻辑，**不是 vue-router 路由**，勿混淆。
- **可访问的落地页（正确入口）**：
  ```
  https://www.sxjzit.edu.cn/#/departments/page?site_key=jwc
  ```
  日历即该部门页**首页（`page=home`）内的「校园日历 CALENDAR」板块**（`componentType=calendar`）。
- **`&page=calendar` 是无效路由（反例）**：实测 `https://www.sxjzit.edu.cn/#/departments/page?site_key=jwc&page=calendar` **路由可加载但无日历内容（tables=0，仅渲染部门头/菜单）**，说明 **`page=calendar` 不是有效子栏目名**——该栏目只存在于首页板块，**不在 `nav` 菜单**（与 §3.4 中 jwc「校园日历」来源=「首页板块」一致）。因此**不要**把 `&page=calendar` 当作日历网址使用。
- **数据来源**：
  - **首屏**：日历数据内嵌于 `/dept/home2?site_key=jwc` 返回的 `calendar.events`（`{rest_work:{rest[],work[]}, schedule:[]}`），`componentType=calendar` 决定渲染日历面板。
  - **翻月**：`GET /school/events?year=<Y>&month=<M>&site_id=<sid>`，`month` 为 **1-based**。
- 板块入口：`page=home` 内「校园日历 CALENDAR」右侧 `more-arrow`（点击**不导航**，仅刷新当月）与 `campus_calendar_download`（点击**无 XHR**，客户端本地导出）。
- **「校园日历」完整列表页（主站单栏目；2026-09-30 补充实测）**：
  ```
  https://www.sxjzit.edu.cn/#/list/more?site_id=1&column_id=8197fe41503c4c32bce1e449d2492b2e
  ```
  该页标题即栏目唯一文章「2025-2026学年第一学期校历」；数据经 `GET /common/column/articles?site_id=1&column_id=8197fe41…&size=10`。
  ⚠️ **响应结构变体**：该栏目返回 `data = {column_id, title_cn:"校园日历", title_en:"calendar", href:<本页 URL>, articles:{total, list[]}}`（**嵌套 `articles`**，区别于常规扁平 `{total, list[]}`；当前 total=1）——消费方须按响应形状判别（有无顶层 `articles`）。
- 现状：22 个站点中**仅 jwc 的 `/dept/home2` 含 `calendar` 板块**（其余站点 home2 无 calendar 键）。
- 原始证据：`network-capture.md` 步骤 5（含 `&page=calendar` 无内容的反证）；`raw/ep_dept_home2_jwc.json`（含 calendar 键）、`raw/ep_school_events.json`、`raw/raw_cal_list.json`（主站日历栏目变体结构）。

### 7.2 `/school/events` 参数与响应

| 项 | 值 |
|---|---|
| URL | `GET /school/events?year=<Y>&month=<M>&site_id=<sid>` |
| 参数 | `year`、`month`、`site_id` **均非强校验**（缺参也不报错，返回空结构） |
| 响应 | `data.{rest_work:{rest:[],work:[]}, schedule:[]}` |
| 适用性 | **任意 site_id 均可调用**（实测 jwc/xcdsj/sxy/dzbgs/dwbwb/主站 1 全 200） |
| 日历入口 | 无独立路由页面；部门页落地 `#/departments/page?site_key=jwc`（首页板块）；**完整列表页** `#/list/more?site_id=1&column_id=8197fe41…`（主站单栏目，见 §7.1）；`&page=calendar` 为无效路由反例 |
| 原始证据 | `raw/ep_school_events.json`、`raw/home2_jwc.json` |

### 7.3 其余端点契约表

| 方法 | 路径 | 参数（名:类型/必填） | 关键响应字段 | 说明 | raw |
|---|---|---|---|---|---|
| GET | `/common/column/head` | 无参 | `data.{site{site_id,title_cn,title_en,domain,logo,description,keywords}, menus[]}` | 全站顶部导航 | `ep_column_head.json` |
| GET | `/common/foot` | 无参 | `data.{site{}, 联系方式/友情链接}` | 全站页脚 | `ep_foot.json` |
| GET | `/dept/home` | `site_key` 必填 | `data.{nav[]...}` | 部门首页·旧版 | `ep_dept_home_jwc.json` |
| GET | `/school/home5` | 无参 | `data.{top_banners[],news,achievements,students,teachers,campus,videos,...}` | 官网首页聚合 | `ep_school_home5.json` |
| GET | `/school/intro` | 无参 | `data.<key>.{title_cn,title_en,statistics{dynamicDigit{total,list[]}}}` | 学校概况六板块 | `ep_school_intro.json` |
| GET | `/school/cooperate` | 无参 | `data.{column_id,title_cn,href,site_id,data[{id,title_cn,is_out,href,image_url}]}` | 合作交流 | `ep_school_cooperate.json` |
| GET | `/school/msg` | 无参（页面空参调用） | `data.data.message_list.data{total,list[{id,title,show_title,message_time}]}` | 校长信箱列表 | `ep_school_msg.json` |
| GET | `/common/msg/detail` | `site_id` 必填、`msg_id` Int 必填 | `data.{show_title,content,is_show_content,message_time,is_replied,reply_content}` | 来信详情；缺参 → 400 | `ep_msg_detail.json` |
| POST | `/common/msg/send` | body(JSON)：`{site_id,name,phone,title,textarea,captcha}` | 成功 `code 200` | 校长信箱提交（**仅静态契约，未发起提交**） | —（调用点 `CustomOpinionForm-C5biDd2v.js`） |
| GET | `/common/teacher/page` | `site_id` 必填、`is_leader`(0/1) 必填、`page`、`size` | `data.{total,list[{id,name,position,title,text(HTML)}]}` | 师资分页（**校验顺序：is_leader 先于 site_id**）；缺 `is_leader` → 400 | `ep_teacher_xcdsj.json` 等 |
| POST | `/common/recruit/query` | body(JSON)：`{name,idcard}`（**idcard 为 RSA 加密串，非明文**） | 命中 `data.{name,major}`；未命中 `data:null` | 招生查询；假数据 → 500；**GET → 405**；`{}` → 500 | `ep_recruit_query.json`、`rob_recruit_get.json` |
| GET | `/common/short/create` | query `url`（需 encodeURIComponent） | **响应键名特例：`{code,msg,datas}`** | 短链创建；前端用原生 `fetch(credentials:"include")` 直调 | `ep_short_create.json` |

> **`/common/short/create` 键名特例**：返回 `{"code":200,"msg":"成功","datas":"https://www.sxjzit.edu.cn/s/Of"}`——**不是 `message`/`data`**，客户端解析需单独适配。

### 7.4 「访问量统计 / 点赞 / 标签 / 相关推荐」→ 均不存在

| 能力 | 结论 | 取证方式与证据 |
|---|---|---|
| 访问量统计（views/read count） | ✗ 不存在 | ① 详情接口 `data` 仅 5 字段（title/update_time/content/href/image_url），无任何计数；② `/common/article/detail` 与列表接口响应全文未见 `view`/`count`/`hits` 字段；③ bundle 内无相关 API 调用点 |
| 点赞（like/praise） | ✗ 不存在 | ① SPA bundle 全部 API 枚举（`endpoints.txt`）中无 like/praise/thumb 类路径；② 详情页 DOM 无点赞按钮；③ 直连推测路径返回 404 |
| 标签（tag 作为独立接口） | ✗ 不存在 | `tag` 字段在列表项中恒为空串（`/common/column/articles`），仅在 oneTwoArticles 中作"空格分隔关键词"出现，**无独立标签接口**；bundle 无 `/common/tag*` 之类路径 |
| 相关推荐（related/recommend） | ✗ 不存在 | ① bundle 无 related/recommend 路径；② 详情页 DOM 无"相关文章"区域；③ 列表接口响应无相关推荐字段 |

> 说明：以上四项均以「**bundle 全量 API 枚举（`endpoints.txt`）+ 各接口响应全字段核对 + 详情页 DOM 实机检查**」三者交叉取证，结论为**服务端不提供**。客户端如需这些能力须本地计算或自建。

---

## 8. 「机构 × 接口」覆盖矩阵（34 行 × 6 列）

三态说明：**✅ 已验证契约** ｜ **N/A 不适用**（该机构无此形态/入口） ｜ **✗ 不存在**（含证据，本矩阵无此态）。

| 机构（id） | school/org | dept/home2 或 college/home | column/articles | article/detail | search | calendar |
|---|---|---|---|---|---|---|
| 党委办公室(121) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 党委组织部(122) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 党委宣传部(142) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 党委统战部(143) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 纪检监察办公室(144) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 党委教师工作部(145) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 党委学生工作部(武装部)(146) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 思想政治教育工作部党支部(148) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 团委(123) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 工会(138) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 妇联(139) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 科协(140) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 关心下一代工作委员会(141) | ✅ | N/A | N/A | ✅ | ✅ | N/A |
| 校长办公室(124) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 人力资源处(125) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 财务与资产管理处(130) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 教务处(131) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | ✅ |
| 学生工作处(133) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 招生就业处(134) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 后勤管理处(135) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 保卫处(136) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 科研处(137) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 智能制造与车辆学院(126) | ✅ | ✅ college/home | ✅ | ✅ | ✅ | N/A |
| 信创与大数据学院(127) | ✅ | ✅ college/home | ✅ | ✅ | ✅ | N/A |
| 材料与环境学院(149) | ✅ | ✅ college/home | ✅ | ✅ | ✅ | N/A |
| 商学院(150) | ✅ | ✅ college/home | ✅ | ✅ | ✅ | N/A |
| 文法学院(151) | ✅ | ✅ college/home | ✅ | ✅ | ✅ | N/A |
| 艺术学院(152) | ✅ | ✅ college/home | ✅ | ✅ | ✅ | N/A |
| 通识教育学院(153) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 国际交流与继续教育学院(154) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 马克思主义学院(155) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 创新创业学院(157) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 图书馆(128) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |
| 实践教学管理中心(129) | ✅ | ✅ dept/home2 | ✅ | ✅ | ✅ | N/A |

**矩阵说明与核算**：
- **行数 34 = 机构树叶子数 34**（`school/org` 第 3 层节点数）✅。
- `school/org` 列全 ✅：34 个机构全部出现在机构树中。
- `article/detail` 列全 ✅：子站型机构的列表项 `id` 即 `article_id` 可直接送详情；单文章型机构直接用自身 `article_id`。
- `search` 列全 ✅：站内搜索为**全站级**接口（不区分机构），对全部机构适用。
- `calendar` 列：**仅 jwc ✅**（唯一含 calendar 板块的站点）。其余子站型标 N/A 指「该站首页无日历面板」；**注意 `/school/events` 接口本身接受任意 `site_id`（实测 200）**，故客户端如需独立日历视图仍可调用，只是官网未给这些站点提供面板入口。单文章型机构标 N/A（无站点、无面板）。
- `dept/home2 或 college/home` 列：6 个学院用 college/home，其余 16 个站点用 dept/home2；单文章型 10 个标 N/A。
- **完整性核算**：本次捕获的请求**全部已归类（0 未归类）**——SPA 侧 20 条（含 `/article/videos` 明确为前端路由 404）+ App 侧新增 2 条（`/school/home2`、`/common/article/page`）均在 §1、§1.1、§7 中给出归属。

---

## 9. 站点映射表（机构 ↔ site_key ↔ site_id ↔ 页面路由）

| 机构 | site_key | site_id | 页面路由类型 |
|---|---|---|---|
| 党委办公室 / 校长办公室 | `dzbgs` | `57c7fc7a00924d1b8113d77d9729d7eb` | `#/departments/page?site_key=dzbgs` |
| 党委学生工作部(武装部) / 学生工作处 | `dwxsgzb` | `9fbfe21fde4e4620af51382cd893be6f` | `#/departments/page?site_key=dwxsgzb` |
| 团委 | `tw` | `e1acf637f93242bbbc1426c04f14145c` | `#/departments/page?site_key=tw` |
| 人力资源处 | `rlzyc` | `571d4b7547804e2397a12a4f0503a571` | `#/departments/page?site_key=rlzyc` |
| 财务与资产管理处 | `cwc` | `9725697bdad041d38a0246cbbbd89b20` | `#/departments/page?site_key=cwc` |
| 教务处 | `jwc` | `222fa53591a3494e9c860390039b0844` | `#/departments/page?site_key=jwc` |
| 招生就业处 | `zsw` | `cb3b1fe4fcdf40999b0c162015c3326d` | `#/departments/page?site_key=zsw` |
| 后勤管理处 | `hqglc` | `27c4a698e7fc4abea886eb4610f374e3` | `#/departments/page?site_key=hqglc` |
| 科研处 | `kyc` | `6030fbf696d543f3a93bf537ca0af899` | `#/departments/page?site_key=kyc` |
| 保卫处 | `dwbwb` | `21184757a5c84833be6abf2cf2bede3f`（**须从 home2 取**） | `#/departments/page?site_key=dwbwb` |
| 图书馆 | `tsg` | `69bc8045bfdb4ff5bb442e04bad86986` | `#/departments/page?site_key=tsg` |
| 实践教学管理中心 | `sjjxglzx` | `d99e0d78612149ce99b9f00edf45ca4f` | `#/departments/page?site_key=sjjxglzx` |
| 马克思主义学院 | `mkszy` | `93ef50506d1f4e2a92477a21ecc8b52f` | `#/departments/page?site_key=mkszy`（**学院型却走 departments 路由**） |
| 通识教育学院 | `tsxuey` | `e62a313fe40746438fdaea3cfc33123f` | `#/departments/page?site_key=tsxuey`（学院型却走 departments 路由） |
| 国际交流与继续教育学院 | `gjjljxjy` | `4b9a6b4591ef4e23aa4dd5fc54aebd84` | `#/departments/page?site_key=gjjljxjy`（学院型却走 departments 路由） |
| 创新创业学院 | `scxy` | `1e4acf8fff9148ce933f47610a87ca48` | `#/departments/page?site_key=scxy&page=home` |
| 信创与大数据学院 | `xcdsj` | `890cf93e62aa47a0983aa5f551c92e4a` | **`#/college?site_key=xcdsj`** |
| 智能制造与车辆学院 | `znzzcl` | `6fe4387f78ba4b42b9807ff86ca0df1f` | **`#/college?site_key=znzzcl`** |
| 商学院 | `sxy` | `c85524251e1b4ca19d7f4c7b0de482bb` | **`#/college?site_key=sxy`** |
| 材料与环境学院 | `clhj` | `7575582d988949a0a3d70fcceba26cb5` | **`#/college?site_key=clhj`** |
| 文法学院 | `wfxy` | `e684aa6d75c340559aa4f7a2668cf3e4` | **`#/college?site_key=wfxy`** |
| 艺术学院 | `ysxy` | `cdd28a001afc418bb2b77ad704ed12a6` | **`#/college?site_key=ysxy`** |

**两类路由**：
- `#/college?site_key=<key>`（6 个学院，首页接口 = `/college/home`）：`xcdsj`、`znzzcl`、`sxy`、`clhj`、`wfxy`、`ysxy`
- `#/departments/page?site_key=<key>`（16 个站点，首页接口 = `/dept/home2`）：其余全部（含 mkszy/tsxuey/gjjljxjy/scxy 这 4 个"学院"因 org 树 `path` 指定走 departments）
- 子栏目页：在路由后追加 `&page=<该栏目 title_en>`。

---

## 10. App 现有实现对照表（已接入 / 未接入 / 待接入）

> 证据方法：`grep -rn "dept/home2\|common/column/articles\|common/search\|school/events\|school/intro\|school/msg" qin/DesignCode qin/DesignCodeTests` + 全量端点正则枚举 + 直连复验。

| 端点 | App 状态 | 证据（文件:行号） |
|---|---|---|
| `/school/org` | ✅ 已接入 | `NetworkService.swift:986`（`getRaw("/school/org")`）、`OrganizationView.swift:2227,2370`（单文章型频道/机构树缓存盒） |
| `/dept/home2` | ✅ 已接入 | `NetworkService.swift:755(zsw),965(部门),1023(buildURL),1089(党建指纹)`；`NotificationManager.swift:679(党建),755(机构动态)` |
| `/college/home` | ❌ 未接入 | 全仓库无该路径调用 |
| `/common/column/articles` | ✅ 已接入 | `NetworkService.swift:193`；测试 `DesignCodeTests/NetworkServiceDTOTests.swift:445` |
| `/common/column/oneTwoArticles` | ✅ 已接入 | `NetworkService.swift:891`（专业介绍/栏目板块） |
| `/common/article/detail` | ✅ 已接入 | `NetworkService.swift:201,882,1163`；测试 `NetworkServiceDTOTests.swift:467` |
| `/common/article/page` | ✅ 已接入（App 发现）· ✅ 已修复 | `NetworkService.swift:763-766`（调用点 **763**；已改用 `page/size` 传参，见 §1.1） |
| `/common/column/head` | ✅ 已接入 | `NetworkService.swift:183`；`SJZNetworkMonitor.swift:231` |
| `/common/foot` | ✅ 已接入 | `NetworkService.swift:188` |
| `/school/home2` | ✅ 已接入 | `NetworkService.swift:178` |
| `/school/intro` | ✅ 已接入 | `NetworkService.swift:282`、`SchoolProfileView.swift:404`、`NotificationManager.swift:535` |
| `/school/cooperate` | ✅ 已接入 | `SchoolProfileView.swift:629`、`NotificationManager.swift:560` |
| `/school/msg` | ✅ 已接入 | `NetworkService.swift:1252`；`PrincipalMailboxView.swift:6` |
| `/common/msg/detail` | ✅ 已接入 | `NetworkService.swift:1339` |
| `/dept/home` | ⚠️ 未接入 | 全仓库无该路径调用（旧版，功能被 home2 覆盖，无需接入） |
| `/common/teacher/page` | ❌ 未接入 | 全仓库无该路径调用（**待接入**：师资队伍栏目当前无实现） |
| `/common/search` | ❌ 未接入 | `grep "common/search"` 无命中（**待接入**：站内搜索） |
| `/school/events` | ❌ 未接入 | `grep "school/events"` 无命中（**待接入**：校园日历/校历） |
| `/school/home5` | ❌ 未接入 | 无调用（App 用 `/school/home2` 替代） |
| `/common/msg/send` | ❌ 未接入 | 无调用（校长信箱仅读取，未实现提交） |
| `/common/recruit/query` | ❌ 未接入 | 无调用（招生查询，需 RSA 加密） |
| `/common/short/create` | ❌ 未接入 | 无调用（短链，非必要） |
| `/article/videos` | N/A | 非 API（前端路由），无需接入 |

**汇总**：已接入 **13** 个（含 App 发现的 `/school/home2`、`/common/article/page`）；**未接入 9 个**（`college/home`、`teacher/page`、`search`、`school/events`、`school/home5`、`msg/send`、`recruit/query`、`short/create`，**另有旧版 `/dept/home` 亦未接入**——其功能已被 `/dept/home2` 覆盖，无需接入）；其中 **机构相关且建议优先待接入**：`/college/home`（学院型机构首页，6 个学院必接）、`/common/search`（站内搜索）、`/school/events`（日历）。
> 注：`/common/article/page` 曾存在"App 传 `pageNo/pageSize` 导致分页失效"问题，**已于 2026-09-30 修复**（改用 `page/size`，见 §1.1、§11.1 第 10b 条），当前无需再修。

---

## 11. 健壮性与坑位清单

### 11.1 服务端语义坑

| # | 坑位 | 表现 | 应对 |
|---|---|---|---|
| 1 | **HTTP 恒 200，状态在 body.code** | 缺参/不存在/内部错误 HTTP 都是 200 | 必须解析 body `code`，不能只看 HTTP 状态 |
| 2 | `code` 语义 | `200`=成功；`400`=缺参数（message 形如 `参数[x]为必填项`）；`500`=内部错误/数据不存在；HTTP `404`=路径不存在（如 `/article/videos`）；HTTP `405`=方法不匹配（如 GET `/common/recruit/query`） | 按 code 分支处理；400/500 均属"业务结果" |
| 3 | `page=0` | `/common/column/articles?page=0` → body `code 500` | **page 必须 ≥1** |
| 4 | `size` 无服务端上限 | `size=1000` 一次返回全部（jwc 378 条） | 客户端自行限制页大小，避免超大响应 |
| 5 | `site_key` 不存在 | `/dept/home2?site_key=zzz_not_exist` → body `code 500`（**非 400、非空**） | 对未知 site_key 需容错 |
| 6 | `column_id` 不存在 | `/common/column/articles?column_id=deadbeef` → body `code 500` | 同上 |
| 7 | 非文章栏目 | 首页/opinion/link/teacher/calendar/recruit/componentType=0 对列表接口返 `code 500` | 按 `componentType` 分发，勿当错误 |
| 8 | `tabs`/`content` 型 | `total=0`（tabs）/`total=1`（content） | tab 内容在子组件；content 是单篇 |
| 9 | `oneTwoArticles` 根栏目要求 | 传一级子栏目 id → `code 500` | **必须传站点顶层根栏目 id** |
| 10 | `teacher/page` 校验顺序 | 缺 `is_leader` 时先报 `参数[is_leader]为必填项`（即使 site_id 也没传） | is_leader 必传（0=全部，1=领导） |
| 10b | **`/common/article/page` 参数名/默认值** | 参数是 **`page`/`size`（默认 size=10）**；传 `pageNo`/`pageSize` **被完全忽略**（恒返回第 1 页、10 条） | 用 `page`/`size`；勿用 `pageNo`/`pageSize`（App 曾误用 `NetworkService.swift:762` 致分页失效，**已于 2026-09-30 修复**为 763-766 行 `page/size`） |
| 10c | **`/common/article/page` ≠ `/common/column/articles`** | 同一 jwc 通知公告栏目：前者 `total=125`、后者 `total=378`，**不同数据集** | 两者不可互相替代，按目的选接口 |

### 11.2 资源/内容坑

| # | 坑位 | 表现 | 应对 |
|---|---|---|---|
| 11 | **http→https 跳变丢端口** | 正文图 `http://www2.sxjzit.edu.cn:8082/...` → 302，`Location` **去掉 `:8082`** | 把 `http://` 替换为 `https://`；端口保留/去掉均可 |
| 12 | 协议混用 | 正文图 9/10 是 http，`image_url` 10/10 是 https | 统一升级为 https |
| 13 | 文件名含中文/空格 | 如 `图层 733_20250330201837A001.webp` | URL 必须 percent-encode |
| 14 | 无防盗链 | 加不加 `Referer` 结果一致 | 无需 Referer |
| 15 | 附件 href 前导空格 | 正文 `<a href=" https://…">` 值带前导空格 | 必须 `trim()` |
| 16 | `file:///C:\` 本地残留 | WPS 粘贴残留 `<img src="file:///C:/Users/.../wps1.png">` | 过滤 `file://` 与非 http(s) 的 src |
| 17 | 无独立附件字段 | 详情 `data` 仅 5 字段，附件内联在 content | 从正文 `<a href>` 嗅探后缀 |
| 18 | `article_id` 混合形态 | 数字型（162/2305）与 32 位 hex 并存 | 按字符串透传，勿数字强转 |
| 19 | 列表 `id` 即 `article_id` | 列表项 `id` 直接可送详情 | 直接透传 |
| 20 | 占位图 | 无封面时 `image_url` 为 `no_picture.webp` | 识别占位图避免误显示 |

### 11.3 浏览器/前端行为坑（实机捕获）

| # | 坑位 | 表现 | 应对 |
|---|---|---|---|
| 21 | 顶部搜索浮层回车不触发 | 浮层输入「考试」回车**无请求**（无提交/无联想，疑似仅装饰） | 走等效路由 `#/list/search` |
| 22 | 搜索页直访不发请求 | `#/list/search?key_words=考试` 直接访问**不自动发请求**（仅显示搜索历史） | 必须在页内输入框提交才触发 `/common/search` |
| 23 | bfcache 同 hash 不重载 | 同 URL 重新 navigate 时浏览器 bfcache 恢复 DOM，列表仍停留原页（Vue hash 路由对相同 hash 不重载） | 翻页/刷新用不同 hash 或强制重载 |
| 24 | 点击一次触发两条相同请求 | 点击子栏目时偶发两条相同 XHR（疑为 Vue 组件重复挂载） | 客户端去重 |
| 25 | 日历「更多」不导航 | 点击 calendar `more-arrow` URL 不变，仅重发一次 `/school/events` | 按"刷新当月"处理 |
| 26 | 日历「下载」无接口 | 点击下载图标无任何 XHR（客户端本地导出） | 无需后端接口 |
| 27 | **`&page=calendar` 是无效路由** | `#/departments/page?site_key=jwc&page=calendar` 可加载但无日历内容（tables=0） | 日历用落地页 `#/departments/page?site_key=jwc`（首页板块）；勿用 `&page=calendar`（详见 §7.1） |

### 11.4 site_key 特例清单

- **site_id 为 null（须从 home2 取）**：保卫处 `dwbwb`（`21184757a5c84833be6abf2cf2bede3f`）、校长办公室 `dzbgs`（与党委办公室同站）、学生工作处 `dwxsgzb`（与党委学工部同站）。
- **共用同一站点**：`dzbgs`（党委办公室 121 + 校长办公室 124）、`dwxsgzb`（党委学工部 146 + 学生工作处 133）—— 两条机构条目 → 1 个 site_key。
- **单文章型（site_key 为 `null` 或 `""`）**：10 个，其中 `""` 空串 2 个（工会 138、思政党支部 148）务必与 `null` 区分。
- **双配型**：财资处 `cwc`（同时有 site_id `9725697b…` 与 article_id `cc3b8540…`）。
- **home2 独有栏目**：11 个站点（见 §3.4），其部分栏目无 nav 菜单入口但 column_id 可用。

---

## 12. 每接口 curl 复现命令（20 个，可直接粘贴执行）

> **全部命令无需任何特殊请求头**（无 Referer/UA/Cookie）。仅 POST + JSON body 需 `Content-Type: application/json`。

```bash
B=https://gwqietap.sxjzit.edu.cn/mapi
SID=222fa53591a3494e9c860390039b0844          # jwc site_id
CID=94511e8fcb8c49b4a1ade5d2fda8a03b          # jwc 通知公告 column_id

# 1) 机构树
curl -s "$B/school/org"

# 2) 部门首页聚合（22 站均 200）
curl -s "$B/dept/home2?site_key=jwc"

# 3) 学院首页聚合（仅 6 学院 200；mkszy 会 500）
curl -s "$B/college/home?site_key=xcdsj"
curl -s "$B/college/home?site_key=mkszy"        # 500 反例

# 4) 栏目文章分页
curl -s "$B/common/column/articles?site_id=$SID&column_id=$CID&page=1&size=8"      # 200
curl -s "$B/common/column/articles?site_id=$SID&column_id=$CID&page=99999&size=8"  # 200 空列表
curl -s "$B/common/column/articles?site_id=$SID&column_id=$CID&page=0&size=8"      # code 500（page 必须 ≥1）

# 5) 一二级栏目混合文章（须传站点根栏目 id）
curl -s "$B/common/column/oneTwoArticles?site_id=$SID&column_id=66e9645f4eee4f2ead37a8fe1223d7fb"  # 200

# 6) 文章详情（article_id 字符串透传）
curl -s "$B/common/article/detail?article_id=046e6ed45ce64980a67f471b8efc157b"      # 200

# 7) 顶部导航
curl -s "$B/common/column/head"

# 8) 页脚
curl -s "$B/common/foot"

# 9) 师资分页（is_leader 必填：0=全部 1=领导）
curl -s "$B/common/teacher/page?site_id=890cf93e62aa47a0983aa5f551c92e4a&is_leader=0&page=1&size=10"

# 10) 校园日历月历（month 为 1-based；任意 site_id 均可）
#     注意：校园日历无独立页面，落地页为 #/departments/page?site_key=jwc（日历为其首页板块）；
#     &page=calendar 是无效路由（见 §7.1）
curl -s "$B/school/events?year=2026&month=9&site_id=$SID"

# 11) 站内搜索（key_words 必填，p=页码，s=页大小）
curl -s "$B/common/search?key_words=%E8%80%83%E8%AF%95&p=1&s=10"   # 关键词「考试」
curl -s "$B/common/search?key_words=%E8%80%83%E8%AF%95&p=2&s=5"

# 12) 校长信箱来信详情
curl -s "$B/common/msg/detail?site_id=1&msg_id=179"

# 13) 校长信箱提交（POST，JSON body；仅探测契约）
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"site_id":1,"name":"张三","phone":"13800000000","title":"测试","textarea":"测试","captcha":"1234"}' \
  "$B/common/msg/send"

# 14) 招生查询（POST，JSON body；idcard 需 RSA 加密）
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"张三","idcard":"000000000000000000"}' "$B/common/recruit/query"   # code 500（假数据未命中）

# 15) 校长信箱列表
curl -s "$B/school/msg"

# 16) 学校概况
curl -s "$B/school/intro"

# 17) 合作交流
curl -s "$B/school/cooperate"

# 18) 官网首页聚合
curl -s "$B/school/home5"

# 19) 短链（GET ?url=；响应体键为 msg/datas）
curl -s "$B/common/short/create?url=https%3A%2F%2Fwww.sxjzit.edu.cn%2F"

# 20) 反例：/article/videos 不是 API
curl -s "$B/article/videos"                      # HTTP 404 Not Found

# 补充（App 源码发现、不在 SPA 枚举的 2 个）
curl -s "$B/school/home2"                        # 200
# /common/article/page：真实参数是 page/size（默认 size=10）；pageNo/pageSize 会被忽略
curl -s "$B/common/article/page?site_id=cb3b1fe4fcdf40999b0c162015c3326d&column_id=35f6a01d451f4cc1b0f5704fab71dfcb&page=1&size=3"   # 200，返回 3 条
curl -s "$B/common/article/page?site_id=cb3b1fe4fcdf40999b0c162015c3326d&column_id=35f6a01d451f4cc1b0f5704fab71dfcb&pageNo=2&pageSize=3" # 200，但=第1页10条（参数被忽略）
# 对照：同栏目 /common/column/articles 的 total 与 article/page 不同（不等价）
curl -s "$B/common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=94511e8fcb8c49b4a1ade5d2fda8a03b&page=1&size=8"  # total=378
curl -s "$B/common/article/page?site_id=222fa53591a3494e9c860390039b0844&column_id=94511e8fcb8c49b4a1ade5d2fda8a03b&page=1"            # total=125
```

> 说明：`/common/short/create` 前端由 `BaseArticle-*` chunk 用原生 `fetch(...,{credentials:"include"})` 直调（非 axios），实测不带 cookie/头同样可用。

---

## 13. 证据索引

证据目录：`/Users/qinchao/Downloads/designcode-swiftui/qin/docs/departments-api-evidence/`

| 文件 | 内容 | 覆盖结论 |
|---|---|---|
| `README.md` | 证据目录索引（本目录说明） | 如何复验每个结论 |
| `network-capture.md` | 原 `agentA_browser.md`：外部 Chrome 实机点击取证台账（子栏目穷举/翻到底/详情/搜索/日历/学院页/特殊板块，含 network 原始片段） | §3.4、§4.2、§4.3、§5.3、§6、§7.1、§11.3 |
| `agentB_sites.md` | 22 站点 × 178 子栏目验证、翻底校验、列表项字段表、契约要点 | §3.1~§3.6 |
| `agentB_sites.json` | agentB 结构化原始数据（22 站点全量栏目 + 端点契约 + componentType 统计） | §3.4、§4.2 |
| `agentC_detail.md` | 详情接口契约、资源拼接规则、10 单文章机构表、oneTwoArticles、school/org 字段表 | §2、§5、§4.4 |
| `agentD_endpoints.md` | 20 端点契约总表、健壮性探测、curl 复现、页面↔接口映射、校园日历路由结论 | §1、§7、§11、§12 |
| `leaves.json` | 34 机构清单（group/id/name/site_key/site_id/article_id/path/en） | §2.5、§8、§9 |
| `school_org.json` | 机构树原始响应 | §2.1~§2.5 |
| `endpoints.txt` | SPA bundle 端点枚举基线 | §1、§7.4（"不存在"取证） |
| `img_check.txt` | 10 篇正文图 https 复测日志 | §5.3 |
| `raw/` | **311 个原始响应 JSON + 1 个日志 txt（共 312 文件）**（见下命名规则） | 全篇 |

### raw/ 命名规则

| 前缀 | 数量 | 含义 |
|---|---|---|
| `home2_<site_key>.json` | 22 | `/dept/home2` 各站点首页聚合原始响应 |
| `list_<site_key>_<column_id>.json` | 222 | `/common/column/articles` 各栏目列表原始响应（含 `_lastp<N>.json` / `_lastp<N+1>.json` 翻底样本） |
| `detail_<前8>.json` | 10 | 10 个单文章型机构详情原始响应 |
| `detail_art_<前8>.json` | 6 | 普通列表文章详情（含 file:// 残留、kdocs 外链、数字 id 旧数据等） |
| `ep_<name>.json` | 31 | 端点契约样例（各端点 200/400/500 样本） |
| `rob_<name>.json` | 10 | 健壮性反例（缺参/坏 id/page=0/超界/405 等） |
| `oneTwo_*.json` | 6 | oneTwoArticles 成功样例与 500 反例 |
| `probe_id.json` | 1 | `id=` 参数无效证据（code 400） |
| `school_org.json` | 1 | 机构树原始响应（同上级目录） |
| `dept_home2_jwc.json` | 1 | jwc nav 栏目树（用于取根栏目 id） |
| `raw_cal_list.json` | 1 | 校园日历完整列表页 `#/list/more?site_id=1&column_id=8197fe41…` 响应（校历文章；结构变体 `data.articles:{total,list[]}`，见 §7.1） |
| `img_check.txt` | 1 | 图片复测日志（非 JSON） |

> **HAR / 截图说明**：
> ① 本次网络取证所用浏览器扩展**无法直接导出 HAR**，故以「**network 捕获台账（`network-capture.md`）+ 直连原始响应（`raw/`）**」为等效证据链：台账记录实机请求 URL/时序/DOM 结论，`raw/` 保存 curl 直连的同接口原始响应，两者可相互印证。
> ② **本次未归档任何页面截图**（浏览器扩展截图未在本任务归档）；所有 DOM/交互类结论（无轮播、无置顶、浮层不发请求、日历更多/下载等）均以 `network-capture.md` 的文本记录为准。

---

## 14. 验证记录

| 项 | 内容 |
|---|---|
| 验证时间 | 2026-09-30 |
| 验证方式 | ① 外部 Chrome 实机点击穷举 + DevTools/扩展网络捕获（agentA）；② curl 直连复验契约与边界（agentB/C/D）；③ SPA bundle 静态枚举交叉核对（endpoints.txt）；④ App 源码 grep 对照（本文档 §10） |
| agentB 抽样重测 | 22 站点 × 178 子栏目全量请求（`size=20`），逐站点对"最大栏目"翻底：末页非空、last+1 空、total 不变，**22/22 全部通过** |
| agentD 边界抽测 | `/common/column/articles` 的缺参/坏 column/page=0/size=1000/page=99999 六项边界 + `/dept/home2` 缺参/坏 key 两项，结论均与预期一致 |
| agentC 资源验证 | 10 篇单文章机构详情 10/10 成功；10 条正文图 + 10 个 `image_url` 用 https 逐个复测 **全部 200 image/webp**（含中文名文件）；加/不加 Referer 结果一致 |
| agentA 实机验证 | 子栏目穷举（jwc 8 项 + 学院 9 项）、翻到第 48 页、详情页 article_id 形态、搜索路由等效、日历更多/下载、机构页无轮播——全部实机确认 |
| 本次组装复验 | 直连复测 `/college/home` ×13 site_key（确认仅 6 学院 200）、`/school/events` ×6 site_id（全 200）、`/school/home2`、`/common/article/page`（zsw total=62）、`/school/home5`/`/school/home`；App 端点 grep 全量核对 |
| 审计后修复复验 | 直连复测 `/common/article/page` 参数（`page=1`→10 条、`page=1&size=20`→20 条、`pageNo=2&pageSize=3`→仍第 1 页 10 条，确认 `pageNo/pageSize` 被忽略、默认 size=10）；同栏目 `/common/article/page` total=125 vs `/common/column/articles` total=378（不等价）；grep 确认 App 调用点当时在 `NetworkService.swift:760`（`pageNo/pageSize` 在 762 行，**随后当日已修复**，现 763-766 行为 `page/size`）；raw `detail_art_*` 计 6 个 |
| 证据形态 | **无 HAR、无截图归档**（扩展不支持 HAR 导出；截图未在本任务归档）；以 network 捕获台账 + 直连原始响应为等效证据（已在 §0、§13 注明） |
| 关键差异标注 | 「首页板块独有栏目」实测 **11 站点**（两种口径一致），与任务预期「16 站点」不同，已按实测记录并标注（见 §3.4） |
| 结论口径 | 全文结论均以**实机/直连可复现证据**为准；凡未能复现者一律标注，未做推测填充 |

---

*文档结束。全文 0 遗漏检查：34 机构 ✅、22 站点 ✅、178 子栏目 ✅、20 端点 ✅ 均可在本文档检索到。*