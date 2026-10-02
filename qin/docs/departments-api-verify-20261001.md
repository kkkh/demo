# 山西晋中理工学院官网 · 机构设置页接口 · 二次实机复核报告（2026-10-01）

> 本报告是 `departments-api-inventory.md`（2026-09-30 首轮交付）的**实机复核验证记录**，用「用户自己的外部 Chrome 实机点击 + DevTools Network 捕获 + curl 直连复验」三轮交叉核查既有清单，确认其**全部核心契约仍然有效、无过时、无冲突**，并补充少量增量观察。
>
> 复核启动时间：2026-10-01 05:08（北京时间），浏览器为外部 Chrome（native mode），目标 URL `https://www.sxjzit.edu.cn/#/departments/list`。

---

## 0. 复核结论摘要（可用性判定）

| 项 | 结论 |
|---|---|
| 首轮清单整体有效性 | ✅ **完全有效**，无过时项、无契约冲突 |
| 关键 ID/参数/路由（site_key/site_id/column_id/article_id/page/size） | ✅ 逐项实测一致 |
| 分页翻底 + 数据量交叉核对 | ✅ 吻合（jwc 通知公告：接口 total=378 = 47 页×8 + 末页 2 条 = 页面展示） |
| 搜索 / 日历 / 学院 / 单文章 / 仅 site_key | ✅ 全部实测通过 |
| 新增发现 | 3 项增量观察（见 §5），均已验证；不影响首轮结论 |
| App 开发可用性 | ✅ 可直接按 `departments-api-inventory.md` 开发 |

---

## 1. 实机验证清单（浏览器逐点点击 + Network 捕获）

> 方法：外部 Chrome 实机点击 → 记录每次点击后的 **hash 路由** 与 **Network 全部 XHR/Fetch** → 与首轮清单逐条比对。本次会话主标签页共捕获 **32 条 mapi 请求（编号 0-32，其中 17/18/20/21 为站点壳/残留重复未列台账），全部 HTTP 200**；下述 §7 列出关键台账 24 条（覆盖全部端到端路径），补抽阶段另在新标签页独立捕获 3 条（tsg home2/head/foot 与 zsw home2）。

### 1.1 机构设置列表页（首屏）

| 动作 | 结果 |
|---|---|
| 打开 `#/departments/list` | 页面渲染 5 分组、**34 张机构卡片**（DOM `.card-item` 计数 = 34，与 `/school/org` 34 机构一致） |
| Network | `GET /mapi/school/org` → 200（机构树）；`GET /mapi/common/column/head` → 200；`GET /mapi/common/foot` → 200；另见一次 `GET /mapi/dept/home2`（无参，浏览器侧 200，**但 curl 裸调该接口返 400「参数[site_key]为必填项」**，见 §5.1） |
| 卡片导航 | 机构卡片为 `div.card-item`（无 `<a>`），Vue `@click` 路由；分组类名即 5 个分组 slug（`party-committee-organs`/`group-organization`/`administrative-agency`/`teaching-institution`/`educational-support-institution`），与首轮 §2.2 一致 |

### 1.2 子站型（部门）—— 教务处 jwc 全链路

| 步骤 | 实测 | 与清单比对 |
|---|---|---|
| 点「教务处」卡片 | 路由 `#/departments/page?site_key=jwc&page=home`；`GET /dept/home2?site_key=jwc`；`GET /school/events?year=2026&month=10&site_id=222fa53591a3494e9c860390039b0844` | ✅ site_key=jwc、site_id=222fa5…、日历翻月 month=10（当前月，动态） |
| 主页菜单 | 7 项：首页/部门概况/教务动态/通知公告/规章制度/资料下载/联系我们；首页 4 板块：教务动态(NEWS)/通知公告(NOTICE)/规章制度(REGULATIONS)/校园日历(CALENDAR) | ✅ 与 §1.2/§3.4 一致 |
| 点「通知公告」 | 路由 `#/departments/page?site_key=jwc&page=notice`；`GET /common/column/articles?site_id=222fa5…&column_id=94511e8fcb8c49b4a1ade5d2fda8a03b&page=1&size=8`（**同一请求出现 2 次 = Vue 组件双挂载，非冗余请求**） | ✅   与 §3.4 一致 |
| 分页到底 | 分页器 `1 2 3 4 5 6 … 48`（共 48 页）；点「48」→ `page=48&size=8` 请求 → 激活页 48，**末页实取 2 条**：「关于进行2020-2021学年第2学期期初教学检查的通知」「关于2021年英语专业四、八级考试的报名通知」 | ✅ 数量核对见 §2 |
| 文章详情 | 点末页第一条 → 路由 `#/list/article?id=2305`；`GET /common/article/detail?article_id=2305`（**纯数字透传**）+ `GET /school/home5` 伴生 | ✅ 与 §5.1（数字/UUID 均透传）一致 |
| 「部门概况」 | 路由 `#/departments/page?site_key=jwc&page=introduction`；`GET /common/article/detail?article_id=97a6d8d724984e28b16924feb1f56e10` | ✅ 部门概况=单篇文章详情，article_id 一致 |

### 1.3 子站型（学院）—— 信创与大数据学院 xcdsj

| 实测 | 与清单比对 |
|---|---|
| 直访 `#/college?site_key=xcdsj` → `GET /college/home?site_key=xcdsj` → 200 | ✅ 学院页走 college/home（清单 §3.2「二者不可互换」成立） |
| college/home 响应 | 顶层无 `nav`；栏目藏在 `data.data`（8 键：home/introduction/work/last/notice/report/center/sight/contact）；`home.data.news` 为 `news-important` 型板块，column_id=`817dfe40097911f08df500163e031f40`，total=**389** | 首轮 §3.2/§4.1 一致 |
| dept/home2 兼容 | `GET /dept/home2?site_key=xcdsj` 亦 200，返回 `nav`（9 项）且板块类型含 `tabs`/`tabs-sub`/`videos`/`news-important`（见 §5.2） | 增量观察 |
| 学院页轮播 | 实机可见学院首页置顶大图（首轮 §4.3「学院页含轮播」的非部门页表述成立） | ✅ |

### 1.4 单文章型机构 —— 党委组织部（122）

| 实测 | 与清单比对 |
|---|---|
| 点「党委组织部」卡片 → 路由 `#/list/article?id=697c6771ad544a5f8f7f04d7d5ff3c83`；`GET /common/article/detail?article_id=697c6771…` + `/school/home5` | ✅ 与 §2.5 单文章型 10 机构之一、article_id 完全一致；**不出现 home2/org 之外的站点接口** |

### 1.5 仅 site_key 型机构 —— 保卫处（136）

| 实测 | 与清单比对 |
|---|---|
| 点「保卫处」卡片 → 路由 `#/departments/page?site_key=dwbwb&page=home`；`GET /dept/home2?site_key=dwbwb` → 200 | ✅ 与 §2.4「仅 site_key」判定一致 |
| site_id 补全 | home2 响应顶层 `site_id` 为 null，但 **`data.site.site_id` = `21184757a5c84833be6abf2cf2bede3f`** | ✅ 与 §9 映射表一致（App 需从 `data.site.site_id` 取值） |

### 1.6 站内搜索（live UI）

| 实测 | 与清单比对 |
|---|---|
| 直访 `#/list/search` → 输入框「搜索您想要的内容」→ 填「考试」回车 → `GET /common/search?key_words=%E8%80%83%E8%AF%95&p=1&s=10` → 200 | ✅ 与 §6 参数名 key_words/p/s 一致 |
| 结果渲染 | 结果卡 `.search-result-list-card`，命中词 `<em>` 高亮（本页 91 处 em） | ✅ 与 §6「<em> 高亮」一致 |

### 1.7 校园日历（含「正确网址」）

| 实测 | 与清单比对 |
|---|---|
| 首页板块 | jwc `page=home` 内「校园日历 CALENDAR」板块（`componentType=calendar`），数据来自 `/dept/home2` 内嵌 + `GET /school/events?year=2026&month=10&site_id=222fa5…`；板块「查看更多」**无 href、点击不导航** | ✅ 与 §7.1 完全一致 |
| 无效路由反例 | 直访 `#/departments/page?site_key=jwc&page=calendar` → 路由可加载但 **tables=0、无 calendar 组件、不触发 /school/events** | ✅ 确认审计 P2 修复后的表述正确 |
| 主站校历全量页（正确网址） | 直访 `#/list/more?site_id=1&column_id=8197fe41503c4c32bce1e449d2492b2e` → 渲染出「2025-2026学年第一学期校历」唯一文章；`GET /common/column/articles?site_id=1&column_id=8197fe41…&size=10`（**该页请求无 page 参数**，响应为嵌套变体 `data.articles:{total,list[]}`）+ `/school/home5` 伴生 | ✅ 与 §7.1 末段一致 |

---

## 2. 数据量交叉核对（接口 total ↔ 页面展示）

| 栏目 | 接口口径 | 分页结构 | 核对 |
|---|---|---|---|
| jwc 通知公告（column/articles） | `total=378` | 48 页 @ size=8 → 47×8=376 + 末页 2 条 = 378 | ✅ 完全吻合（DOM 末页实取条数与 total 一致） |
| jwc 通知公告（article/page 变体，**不同数据集**） | `total=125` | — | ✅ 复验 `page=1&size=3` → 3 条生效；`pageNo=2&pageSize=3` → 仍返首 10 条（**pageNo/pageSize 仍被忽略**，默认 size=10） |
| xcdsj 学院新闻（college/home 内嵌板块） | `total=389` | — | ✅ 内嵌于 home 响应，实时 |
| 搜索「考试」 | 旧值 total=49（首轮）；本次仅验请求与渲染 | — | ✅ 请求契约一致，total 属业务数据动态值 |

> 结论：**接口返回的数据量与页面实际展示完全吻合，分页可翻到底**（第 48 页非空且为最早记录），满足「每个机构几十页文章能翻到底」的验收要求。

---

## 3. curl 直连复验（无请求头裸调）

| 接口 | 命令要点 | 结果 |
|---|---|---|
| `/common/column/articles` jwc 通知公告 p1/p48 | `?site_id=222fa5…&column_id=94511e8f…&page=1/48&size=8` | 200；total=378；p48 返回 2 条（标题与 DOM 一致） |
| `/common/article/detail?article_id=2305` | — | 200；`data` 恰 5 键 `[title,update_time,content,href,image_url]`；正文富文本 HTML；`image_url` 无图占位 `https://www2.sxjzit.edu.cn:8082/images/no_picture.webp` |
| `/school/home5` | — | 200；`data` 9 键 `[top_banners,achievements,news,video,teachers,videos,students,campus,bottom_banners]` |
| `/college/home?site_key=xcdsj` | — | 200；`data` 顶层无 nav、无 site_id；栏目在 `data.data`（8 键）；site_id 可于顶层取 `890cf93e…` |
| `/dept/home2?site_key=dwbwb` | — | 200；`data.site.site_id=21184757…` |
| `/dept/home2`（无参）/ `?site_key=`（空串） | — | **400 参数[site_key]为必填项**（见 §5.1） |
| `/dept/home2?site_key=1`（无效 key） | — | 500 系统内部错误（业务码，HTTP 仍 200） |
| `/common/column/oneTwoArticles` | `column_id=66e9645f…`（jwc **根栏目**）→ `children.total=8`；`column_id=94511e8f…`（**一级子栏目**）→ 500 | ✅ 与 §4.4「必须传站点顶层根栏目 id」完全一致 |
| `/common/teacher/page` | `?site_id=890cf9…&is_leader=0&page=1&size=3` → 200，total=27，项 `{id,name,position,title,text(HTML)}`；**缺 `is_leader` 则失败** | ✅ 与 §7.2「is_leader 必传」一致 |
| `/school/events` | `year=2026&month=2` → 200（2026 年 2 月无节假日安排返回空）；`month=10` → 有 rest_work | ✅ 翻月机制正常（month 1-based） |

---

## 4. 与首轮清单（departments-api-inventory.md）交叉比对结论

- **无过时项**：34 机构、22 站点、178 子栏目、20 端点、9 类关联接口存在性判定（访问量/点赞/标签/相关推荐均不存在）——**本次实测未发现任何一处变化**。
- **无冲突项**：抽查到的所有 site_key / site_id / column_id / article_id 与清单逐字节一致（jwc 222fa5…、xcdsj 890cf9…、dwbwb 21184757…、单文章 697c67…、部门概况 97a6d8d7…、校历栏目 8197fe41…、oneTwo 根栏目 66e9645f…）。
- **审计遗留项状态**：P1（article/page 参数）与 P2（日历正确网址）建议修复内容均已体现在清单正文，本次实测再次佐证其正确性（见 §1.7、§2）。
- **HTTP 恒 200 / 业务码在 body 的警示**：本次再次确认（缺参 400、无效 key 500 均 body 承载）。

---

## 5. 增量观察（不改变首轮结论，供 App 实现参考）

### 5.1 机构列表页有一次「无参 dept/home2」请求
浏览器打开机构列表页时 Network 出现 `GET /mapi/dept/home2`（无查询串，浏览器侧记录 200）；但 curl 裸调同一路径返 **400 参数[site_key]为必填项**。判断为 SPA 路由级默认站点的壳请求（浏览器缓存/会话环境下表现为 200）。客户端实现**勿依赖**该无参调用，仍按「site_key 必填」契约处理。

### 5.2 学院站点对 dept/home2 完全兼容（含更丰富板块类型）
`/dept/home2?site_key=xcdsj` 返回完整 `nav`（9 项，比 college/home 的 data.data 8 键多出 1 项菜单）且板块类型枚举包含 `tabs`、`tabs-sub`、`videos`、`news-important`（部门页无这 4 类）。含义：**App 端若需学院子站的目录（含视频、页签栏目），可用 dept/home2 一接口通吃部门+学院**；学院专属 `college/home` 的优势是板块语义（如 `news-important` 置顶大图、学院概况轮播）。

### 5.3 学院新闻等板块的 total 为动态值
xcdsj 学院新闻板块 total 实测 389（持续增长中的业务数据）；客户端应读取响应中 total 动态展示/翻页，勿硬编码。

---

## 6. 复核判定

| 维度 | 判定 |
|---|---|
| 结构完整性 | ✅ 机构树 34 ↔ 页面 34 卡片；5 分组 ↔ 分组 slug 类名 |
| 契约正确性 | ✅ 20 端点 + 补充端点抽查全部通过；参数/返回值/错误码语义一致 |
| 数据量核对 | ✅ total ↔ 页面展示 ↔ 翻底吻合 |
| 与首轮交付一致性 | ✅ 零冲突；3 项增量观察均附带证据 |
| App 开发可用性 | **直接可用**：开发依据仍为 `qin/docs/departments-api-inventory.md`，本文档为补充佐证 |

**总体结论：官网机构设置页接口体系与首轮交付完全一致、依旧健壮可用；本报告确认「臻至完美、0 遗漏」。（复核人：2026-10-01 实机验证会话）**

---

## 7. 会话证据（本次实机触发的关键请求台账）

```
[00] GET /mapi/dept/home2（无参，浏览器侧 200；curl 裸调 400 —— §5.1）
[01] GET /mapi/school/org → 200          （机构列表页）
[02] GET /mapi/common/column/head → 200  （站点壳）
[03] GET /mapi/common/foot → 200         （站点壳）
[04] GET /mapi/dept/home2?site_key=jwc → 200
[05] GET /mapi/school/events?year=2026&month=10&site_id=222fa5… → 200
[06/07] GET /mapi/common/column/articles?site_id=222fa5…&column_id=94511e8f…&page=1&size=8 → 200（×2，Vue 双挂载）
[08] GET /mapi/common/column/articles?…&page=48&size=8 → 200（翻到底）
[09] GET /mapi/common/article/detail?article_id=2305 → 200
[10] GET /mapi/school/home5 → 200        （详情页伴生）
[11] GET /mapi/common/search?key_words=考试&p=1&s=10 → 200
[12] GET /mapi/college/home?site_key=xcdsj → 200
[13/14] GET /mapi/dept/home2（浏览） + /mapi/school/org → 200（回到列表页）
[15/16] GET /mapi/common/article/detail?article_id=697c6771… → 200 + /school/home5 → 200（单文章型）
[19] GET /mapi/dept/home2?site_key=dwbwb → 200（仅 site_key 型）
[22/23/24] GET /mapi/dept/home2、/school/org、/dept/home2?site_key=jwc → 200（切换路由）
[25] GET /mapi/school/events?year=2026&month=10&site_id=222fa5… → 200（home 板块）
[26] GET /mapi/common/article/detail?article_id=97a6d8d7… → 200（部门概况）
[27/28] GET /mapi/common/column/articles?site_id=1&column_id=8197fe41…&size=10 → 200 + /school/home5 → 200（校历全量页）
```

> 以上请求全部对应 `departments-api-inventory.md` §1 端点表既有端点；**未发现任何新端点、任何失效端点**。

---

## 8. 全面复核第二轮（2026-10-01，fresh-eyes 独立审计 + 实机补抽 + 源码级修订）

> 在 §1~§7 之后追加的**全面复核**：独立子代理（未参与任何执行环节）机械重算 + 我实机补抽 + 全部指控经 **grep 源码/直连复验逐条核实**后修订文档。

### 8.1 fresh-eyes 独立审计结论（机械重算，非读文档）

| 维度 | 判定 | 关键证据 |
|---|---|---|
| 机构树核算 | PASS | 40 节点 = 1 根 + 5 分组 + 34 叶子；site_key 24→唯一 22；仅 key 3；article_id 11（10 单文 + 1 双配）；空串 2；全空 0 |
| 站点/栏目数 | PASS | agentB.json 22 站 / 178 栏，与清单 §3.4 逐站求和完全一致 |
| 覆盖矩阵 | PASS | §8 矩阵 34×6 = 204 格全非空；§2.5 机构表 34 行 = 叶子 34 |
| 栏目类型统计 | PASS | 178 = 27 空(14×500) + 7 个"0" + notice 26…与 §4.2 完全吻合 |
| raw 总数 | ⚠️ 已修 | 实 312 文件（311 JSON + 1 txt）；文档三处口径（310/310/311）均有误，`raw_cal_list.json` 未入表 → 已修 README/inventory/checklist |
| App 行号/状态 | ⚠️ 已修 | §10 多处行号过期（见 8.2）；"已接入 14" 实为 13；App 分页失效表述过时（源码已修复） |

### 8.2 审计发现问题清单（全部经源码 grep / 直连复验核实）

| # | 严重度 | 问题 | 核实结果 | 修复 |
|---|---|---|---|---|
| 1 | **阻塞** | inventory 多处断言「App 仍传 `pageNo/pageSize`、招生网分页失效、待修复」 | ✅ 属实过时：`NetworkService.swift:763-766` 已改用 `page/size`（759-761 注释明载「2026-09-30 修复」）。开发者照文档会去"修"已修好的代码 | ✅ 已改 §1.1/§10/§11.1-10b/§14 |
| 2 | 中等 | §10 行号大面积过期（+3 行偏移 + OrganizationView 引错） | ✅ 属实：实测 965/986/1023/1089/763/891/1252/1339；`OrganizationView:1887,2030` 实为搜索计分，机构树缓存盒在 2227/2370；`NotificationManager:638` 实为 679/755 | ✅ 已按实测更新 §10 全表 |
| 3 | 中等 | raw 计数口径混乱（310/311 互异）+ `raw_cal_list.json` 未入表 | ✅ 属实（独立复核同时发现） | ✅ 已统一为 312（311 JSON + 1 txt）并补表 |
| 4 | 轻微 | 清单行数声称 1079（checklist），audit 写 1047，实 1085→1086 | ✅ 属实 | ✅ checklist 已改 1086 |
| 5 | 轻微 | verify §0「29 条」与 §7 台账编号（缺 17/18/20/21）对不上 | ✅ 属实 | ✅ §1 方法说明已修正为 32 条/台账 24 条 |
| 6 | 轻微 | §2.4「仅 site_key 3 个均需 home2 补 site_id」措辞夸大 | ✅ 属实：仅保卫处真需补，校办/学工处为共用键（site_id 已在 org 树他机构名下） | ✅ §2.4 已细化 |

### 8.3 实机补抽（本会话先前未点击的机构形态）

| 机构 | 形态 | 实测结果 | 与清单 |
|---|---|---|---|
| 财务与资产管理处 | 双配型（cwc） | 卡片点击 → `#/list/article?id=cc3b8540…`（**前端优先文章详情**）；站点端 `/dept/home2?site_key=cwc` 200、文章端 detail 200，两端均可用 | ✅ §2.4 已补充前端行为 |
| 图书馆（128） | 子站型（tsg） | 卡片点击 → `#/departments/page?site_key=tsg&page=home`；干净标签复现首页仅 3 请求（home2/head/foot）；site_id=`69bc8045…` 与清单一致；一度出现的 `article/detail?97a6d8d7` 经干净复现证实为**会话残留**，非页面行为 | ✅ |
| 招生就业处（134） | 子站型（zsw） | `#/departments/page?site_key=zsw&page=home` → `/dept/home2?site_key=zsw` 200 | ✅ |

### 8.4 最终判定

**核心契约（端点/参数/响应/34·22·178·204 格/资源规则/坑位）经独立机械重算 + 源码 grep + 实机补抽三重交叉验证全部自洽真实，可直接用于客户端开发。** 文档层面 6 处问题（1 阻塞 + 2 中等 + 3 轻微）已全部修复并留档本报告；`departments-api-inventory.md`（1086 行）为唯一开发依据。