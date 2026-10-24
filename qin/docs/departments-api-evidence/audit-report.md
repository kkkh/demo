# 机构接口摸查交付物 · 独立审计报告（fresh-eyes）

- 审计员：独立子代理（未参与执行，不依赖执行者结论）
- 审计日期：2026-09-30
- 被审计对象：`departments-api-inventory.md`（1047 行 / 14 节）、`departments-api-evidence/`（README + network-capture + agentB/C/D + raw/ 311 文件）、规格 `spec.md` / `tasks.md` / `checklist.md`
- 审计方式：**全部结论均以独立重算 + curl 直连重测 + grep 源码 + 机械比对**得出；下表每条均附本次实际执行的命令/证据，未采信文档自述数字。

---

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| 结构完整性（checklist 逐项） | **通过 24 / 部分 3 / 失败 0**（"部分"集中在 HAR/截图缺失两项，且 HAR 缺失已被文档诚实标注） |
| 数量核算（独立重算） | **全部吻合**：叶子 34 ✔、唯一 site_key 22 ✔、站点 22 ✔、子栏目 178 ✔、翻底 22/22 ✔、矩阵 34×6=204 格 ✔ |
| 抽样重测（2 站点列表 + 2 详情 + 搜索 + 日历 + §12 curl） | **全部吻合**（见 §2） |
| 文档内部一致性 | **发现 2 处实质不一致**（`article/page` 参数、日历"正确网址"） |
| App 对照表真实性（grep） | **逐条命中，真实**（3 条核心均验证；1 处行号小差异） |
| 黑天鹅 | 无未覆盖的关键机构行为；2 处需补注 |

**总体判定：交付物质量高，核心契约、数量、覆盖矩阵、App 对照均经得起独立复核。发现 6 个问题（无阻塞级）：中等 2、轻微 4。**

---

## 1. checklist 逐项判定表

### 一、实机摸查与捕获

| # | 检查点 | 判定 | 证据 |
|---|---|---|---|
| 1 | 实机打开并完成 Network 全量捕获（HAR 已导出） | **部分** | 实机取证台账 `network-capture.md` 存在且细节充分（步骤 1–7）；但**无 HAR 文件**（`find . -iname '*.har'` 空），扩展不支持导出，文档 §13「HAR 说明」已**诚实标注**并以等效证据链替代。见问题 P3。 |
| 2 | 机构树契约记录且直连复验通过 | **PASS** | 本次 `curl /school/org` → 200，结构/字段与 §2.1–2.3 一致；`school_org.json` 重算 40 节点。 |
| 3 | 层级 + id/名称/类型/排序字段逐项记录且与页面核对 | **PASS** | 3 层（根/分组/机构）；字段表 §2.3 完整且**未臆造** `sort`（实测确无 sort 字段，展示序按 id，§2.5 已说明）。 |
| 4 | 全部机构/站点枚举为清单（数量与页面一致） | **PASS** | 独立重算叶子 = 34，与 §2.5 表 34 行、§8 矩阵 34 行一致。 |
| 5 | 每站点穷举（子栏目/翻页到底/详情/搜索）并全量捕获 | **PASS** | agentB 22 站点 178 栏目全部有 `column_id` + live 响应；首页板块独有栏目亦被捕获。 |
| 6 | 每条请求已归类定论，0 未归类 | **PASS** | §1「20 端点」与 endpoints.txt 基线逐条对应；`/article/videos` 明确 404 非 API。 |
| 7 | 覆盖矩阵产出，每格有结论 | **PASS** | §8 = 34 行 × 6 列，204 格全为 ✅/N/A，无空格（脚本校验）。 |
| 8 | 完整性核算通过 | **PASS** | 34=34；178=178；§13 raw 文件被引用者全部存在（29 个显式引用 0 缺失）。 |

### 二、接口契约

| # | 检查点 | 判定 | 证据 |
|---|---|---|---|
| 1 | 每机构文章列表接口逐机构确认 | **PASS** | §3.4 178 行 column_id 经机械比对与 agentB json **逐格一致**。 |
| 2 | 分页机制确认且可翻到底 | **PASS** | 本次实测 dzbgs p2/p3、jwc p19/p20、xcdsj p20/p21、tw p11/p12：末页实取数 = total−(last−1)·size，last+1 空且 total 不变。 |
| 3 | 列表项逐字段列出 | **PASS** | §3.5 8 字段；本次实取列表项 `id/title/description/image_url/create_time/update_time/tag/sort` 一致。 |
| 4 | 子栏目全量枚举表 + 切换机制 | **PASS** | §3.4 22 站点全量表 + §4.1 切换机制（同接口不同 column_id）。 |
| 5 | 特殊板块存在性结论（含证据） | **PASS** | §4.3 机构页无置顶/推荐/轮播，附 DOM 证据（network-capture 步骤 7）。 |
| 6 | 详情接口契约 + 正文形式 | **PASS** | 本次 2 篇详情 `data` 恰为 5 字段，与 §5.2 一致。 |
| 7 | 资源前缀/拼接规则 + 直连验证 | **PASS** | 本次实测 http→302 丢端口、https 带/不带端口均 200 image/webp、中文名 200，与 §5.3 一致。 |
| 8 | 搜索接口确认并直连复验 | **PASS** | 本次 `key_words=考试&p=1&s=10`→total 49/10 条、`p=2&s=5`→49/5、无参→400，与 §6 一致。 |
| 9 | 校园日历正确网址 + 数据接口 | **部分** | `/school/events` 契约正确（本次实测 200、任意 site_id、无参返回空结构）；但 §7.1 给出的"正确网址 `...&page=calendar`"与其自身证据 `network-capture.md` 步骤 5 **矛盾**。见问题 P2。 |
| 10 | 关联接口逐项「存在/不存在」 | **PASS** | §7.4 四项均"不存在"，且 bundle 枚举 + 响应全字段 + DOM 三重取证；本次抽查详情仅 5 字段佐证"无访问量字段"。 |
| 11 | 站点映射表与 App 一致 | **PASS** | §9 22 行；本次 curl 复核 dwbwb/dzbgs/dwxsgzb 的 home2 `site_id` 与 §9 完全一致。 |
| 12 | 健壮性记录 → 坑位清单 | **PASS** | §11 26 条；本次实测 page=0→500、坏 site_key→500、缺参→400、teacher 校验顺序、oneTwo 传子栏目→500，全部一致。 |

### 三、复现与证据

| # | 检查点 | 判定 | 证据 |
|---|---|---|---|
| 1 | 每接口 curl 复现命令，实测通过 | **PASS** | 本次执行 §12 中 14 条（含 4 反例），输出与文档描述**逐条一致**（见 §2.6）。 |
| 2 | HAR（脱敏）+ 响应样本 + **截图** 已归档 | **部分** | 响应样本齐全（raw/ 311 文件）；**无 HAR、无任何截图**（`ls -R | grep -iE '\.(png|jpg|...)'` 空）。HAR 已诚实标注，**截图缺失未被文档提及**。见问题 P3。 |
| 3 | 证据索引可用（结论→文件→请求） | **PASS** | 文档显式引用的 29 个 raw 文件全部存在；README/§13 索引可定位。 |

### 四、交付物

| # | 检查点 | 判定 | 证据 |
|---|---|---|---|
| 1 | 清单文档按六范围组织，含样例/字段表/分页/拼接/curl/坑位 | **PASS** | 14 节结构完整，§0—§14 齐备。 |
| 2 | 每机构/站点均有条目，六范围 0 遗漏 | **PASS** | §2.5 34 机构、§3.4 22 站点 178 栏目、§9 22 行映射。 |
| 3 | 覆盖矩阵 + 映射表 + App 对照表 + 核算结论随清单交付 | **PASS** | §8/§9/§10 + §8 核算段。 |
| 4 | App 现有实现对照表（已接入/未接入/待接入 + 差异） | **PASS** | §10 23 行；本次 grep 验证 3+ 条核心接入项真实（见 §4）。 |

### 五、复核

| # | 检查点 | 判定 | 证据 |
|---|---|---|---|
| 1 | 执行侧自检抽样重测通过 | **PASS** | §14 记录 + 本次独立复测印证。 |
| 2 | 独立 fresh-eyes 审计完成、无未决问题 | **本次执行** | 发现 6 条问题（无阻塞），详见 §3；修复后建议重测。 |
| 3 | 与 App 实现交叉核对无冲突 | **PASS** | §10 与源码 grep 一致；未发现冲突。 |

---

## 2. 抽样重测明细（本次实际执行）

> 基址 `B=https://gwqietap.sxjzit.edu.cn/mapi`；所有 curl 均为裸调（无 Referer/UA/Cookie）。

### 2.1 机构树（独立重算，非读文档）
```
python3 解析 school_org.json：总节点 40 = 1 根 + 5 分组 + 34 机构
分组：党委 8 / 群团 5 / 行政 9 / 教学 10 / 知识拓展 2 = 34 ✔
唯一非空 site_key = 22（重复 dzbgs、dwxsgzb）✔
article_id 非空 11 = 单文章 10 + 双配 1 ✔；仅 site_key 3 ✔；空串 2 ✔；未配置 0 ✔
```
→ 与 §2.2/§2.4/§2.5 完全一致。

### 2.2 两站点列表分页（自选 kyc、sxy，先自测后比对）
| 站点 | 栏目 | 文档(total/页@20) | 实测 |
|---|---|---|---|
| kyc | 科研动态 `4192b11b…` | 30 / 2 | **total=30**，p1 取 20、p2 取 10 ✔ |
| kyc | 通知公告 `6a38de1f…` | 72 / 4 | **total=72** ✔ |
| sxy | 通知公告 `817cb932…` | 149 / 8 | **total=149** ✔ |
| sxy | 学院新闻 `817dfdcb…` | 97 / 5 | **total=97** ✔ |

### 2.3 两篇单文章机构详情（§5 五字段 + 资源规则）
`article_id=697c6771…`（党委组织部）：`data` 键恰为 `[title,update_time,content,href,image_url]`；content_len **1738**（文档 1738 ✔）；正文 `<img src="http://www2.sxjzit.edu.cn:8082/...">`。
`article_id=0bde63d0…`（思政党支部）：update_time **2026-08-25**（文档 ✔）、content_len **1745** ✔。
资源规则复测：

| 断言（§5.3） | 实测 |
|---|---|
| 图片域唯一 `www2.sxjzit.edu.cn:8082` | ✔ |
| `https://…:8082/…` → 200 image/webp | ✔ (67822B) |
| `http://…:8082/…` → 302，Location **去掉 :8082** | ✔ |
| `https://www2.sxjzit.edu.cn/…`（无端口）→ 200 | ✔ |
| 中文文件名 → 200 image/webp | ✔ |
| 正文图 http/https 混用 | ✔（697c 为 http） |

### 2.4 搜索契约（§6）
`/common/search?key_words=考试&p=1&s=10` → code 200，`total=49`，10 条，`<em>` 高亮 ✔
`p=2&s=5` → `total=49`，5 条 ✔；无参 → `code 400 参数[key_words]为必填项` ✔

### 2.5 日历契约（§7.2）
`/school/events?year=2026&month=9&site_id=<jwc>` → 200，`data.{rest_work:{rest[],work[]},schedule:[]}` ✔
无参 → 200 空结构 ✔；`site_id=dzbgs`、`site_id=1` → 均 200 ✔

### 2.6 §12 curl 逐条执行（任取覆盖面广的 14 条）
| # | 命令要点 | 期望（文档） | 实测 |
|---|---|---|---|
| 2 | `dept/home2?site_key=jwc` | 200 | 200 ✔ |
| 3 | `college/home?site_key=xcdsj` / `mkszy` | 200 / 500 | 200 / 500 ✔ |
| 4 | `column/articles page=1/99999/0` | 200 / 200空 / 500 | 一致 ✔ |
| 5 | `oneTwoArticles` 传根栏目 | 200 | 200 ✔ |
| 7/8 | `column/head`、`foot` | 200 | 200 ✔ |
| 9 | `teacher/page` | 200 | 200 ✔ |
| 12 | `msg/detail?site_id=1&msg_id=179` | 200 | 200 ✔ |
| 14 | GET `recruit/query` | HTTP 405 | 405 ✔ |
| 16—18 | `school/intro`/`cooperate`/`home5` | 200 | 200 ✔ |
| 19 | `short/create` | `msg`/`datas` 键 | `{"code":200,"msg":"成功","datas":"…/s/Og"}` ✔ |
| 20 | `/article/videos` | HTTP 404 | 404 ✔ |
| 补充 | `school/home2` / `article/page` | 200 / total=62 | 200 / total=62 ✔ |

**附加全量复测**：22 个 `dept/home2` **全部 200** ✔；22 个 `college/home` 恰 **6 个 200（xcdsj/znzzcl/sxy/clhj/wfxy/ysxy）其余 500（含 mkszy）** ✔；`size=1000` jwc 通知公告返回 **378** 条 ✔；列表项 `id` 直送详情 → 200 ✔。

---

## 3. 发现的问题清单

### P1【中等】§1.1 `/common/article/page` 参数名与默认值与实测不符
- **文档**：参数写为 `pageNo`（默认1）、`pageSize`（默认20），并注"`page`/`size` 也兼容"。
- **实测**：`pageNo` 被服务端**完全忽略**，真正生效的是 `page`/`size`，且**默认 size=10（非 20）**。
  - `?pageNo=1&pageSize=3` → 返回 **10** 条（默认页大小）；`?page=1&size=3` → 3 条；`?page=2&size=3` → 第 2 页不同数据；`?pageNo=2&pageSize=3` → 仍是**第 1 页**前 10 条。
- **影响**：开发者照 §1.1 用 `pageNo/pageSize` 会得到**永远第 1 页、固定 10 条**的假分页。App 自身（`NetworkService.swift:760-761`）正是用 `pageNo/pageSize`，其招生网分页实为**失效**。
- **建议修法**：§1.1 参数列改为 `site_id`、`column_id`、`page`（默认1）、`size`（默认10），并明确「`pageNo/pageSize` 会被忽略，勿使用」；在 §11 坑位清单增补一条。

### P2【中等】§7.1 日历"正确网址"与其自身证据互相矛盾
- **文档 §7.1**：给出"**正确网址** `https://www.sxjzit.edu.cn/#/departments/page?site_key=jwc&page=calendar`"。
- **同项目证据 `network-capture.md` 步骤 5**：明确记载 `…&page=calendar` "路由可加载但**无日历内容（tables=0）**，说明 **page=calendar 不是有效子栏目名**"；且 §3.4 显示 jwc「校园日历」来源为"首页板块"（**不在 nav**）。
- **影响**：自相矛盾；按"正确网址"访问会得到空页。
- **建议修法**：改为"正确入口 = `#/departments/page?site_key=jwc&page=home` 内的「校园日历」板块（componentType=calendar）"，删除或降级 `&page=calendar` 为"无效路由反例"。

### P3【轻微】证据链缺 HAR 与截图；HAR 已诚实标注、截图未提
- `find . -iname '*.har'` 为空、`ls -R` 无任何图片。文档 §13「HAR 说明」**如实标注**了扩展无法导出 HAR ✔（符合本次审计要求 E），但 spec 交付物二与 checklist「关键截图已归档」**未满足且未在文中说明缺截图**。
- **建议修法**：在 §13 证据索引补一句"本次未采集页面截图，DOM 结论以 network-capture.md 文本为准"，避免读者误以为截图存在。

### P4【轻微】raw/ 明细计数错：`detail_art_` 文档写 5，实际 6
- 实际 `detail_art_*.json` = 6（01223003、046e6ed4、162、71e607e5、a94feef0、b8821e95）；文档 §13 与 README §二均写 5。
- raw 总数自洽：**311 文件 = 310 JSON + 1 img_check.txt**（README 的"311/310"对；但明细分项相加仅 309，因该项少 1）。
- **建议修法**：两处 `detail_art_<前8>.json` 的"5"改为"6"。

### P5【轻微】同一 App 行号在 §1.1 与 §10 不一致
- §1.1 写 `NetworkService.swift:759`，§10 写 `NetworkService.swift:760`；实际调用在 **760**（`try await get("/common/article/page",…` 于 760，函数声明于 758）。
- **建议修法**：统一为 760。

### P6【轻微】§10「未接入/待接入 8 个」口径略欠严谨
- §10 汇总"未接入/待接入 8 个（college/home…short/create）"，但表中 `/dept/home` 亦标 ⚠️ 未接入，未被计入；实际"未接入"为 **9** 项。
- **建议修法**：总结句注明"（另有旧版 `/dept/home` 亦未接入，功能已被 home2 覆盖）"。

---

## 4. App 对照表真实性核验（grep 源码，含文件与行号）

| §10 端点 | §10 声称 | grep 实测 | 判定 |
|---|---|---|---|
| `/dept/home2` | 已接入 `NetworkService.swift:755,962,1020,1086`、`NotificationManager.swift:638` | 命中 755/962/1020/1086 + 638 | ✔ 完全属实 |
| `/common/column/articles` | 已接入 `NetworkService.swift:193`；测试 `NetworkServiceDTOTests.swift:445` | 命中 193 + 445 | ✔ |
| `/school/org` | `NetworkService.swift:983`、`OrganizationView.swift:1887,2030` | 全部命中 | ✔ |
| `/common/article/page` | 已接入 `NetworkService.swift:760` | 命中 760（§1.1 写 759 → 见 P5） | ✔（行号小差异） |
| `/common/search` | 未接入 | grep 无命中 | ✔ |
| `/school/events` | 未接入 | grep 无命中 | ✔ |
| `/college/home`、`/common/teacher/page`、`/school/home5`、`/common/msg/send`、`/common/recruit/query`、`/common/short/create` | 未接入 | 均无命中 | ✔ |
| `/school/home2` `/school/intro` `/school/cooperate` `/school/msg` `/common/msg/detail` `/common/foot` `/common/column/head` `/common/column/oneTwoArticles` `/common/article/detail` | 已接入 | 均命中（178/282/629/1249/1336/188/183/888/201…） | ✔ |

**结论：§10 对照表真实，未发现虚报接入。**

---

## 5. 黑天鹅搜索结论

1. **机构树是否有第三层**：无。实测 34 个机构节点 `children` 恒为 `[]`，仅 3 层（根/分组/机构）——文档 §2.2 正确。
2. **机构页搜索浮层**：§6/§11.3 已覆盖"浮层回车不发请求、须走 `#/list/search`"。
3. **未记录的参数要求（新发现）**：`/common/article/page` 的真参数问题（P1）；另发现 **`/common/article/page` 与 `/common/column/articles` 非同源等价**——同一 jwc 通知公告列，`article/page` 返回 `total=125`，而 `column/articles` 返回 `total=378`。二者是不同数据集，文档称之为"招生网专用变体"但**未提示 total 不一致**，建议补注以免误用。
4. **`/school/home2` 未记录参数**：无参（与 home5 同结构，实测 data 键完全一致）；`/school/home` 为旧版 `top_banners:{total,list[]}`，文档 §1 备注正确。
5. **疑似遗漏端点探测**：`/school/org/search`、`/dept/list`、`/school/departments`、`/dept/search`、`/school/calendar`、`/common/search/suggest`、`/school/event` 均 **HTTP 404**，确无遗漏的机构相关端点。
6. **`dept/home2?site_id=`（以 id 充当 key）** → `code 400`，佐证该接口只认 `site_key`，文档契约正确。

---

## 6. 审计范围声明

- 本次未采信文档任何自述数字：机构数、site_key、站点数、子栏目数、翻底数、矩阵格数、raw 文件数、App 行号**均独立重算/重测**。
- 未执行的操作：hash 路由前端行为（如 bfcache、浮层回车）因属浏览器副作用，沿用 `network-capture.md` 实机台账，未独立复现；`POST /common/recruit/query`（需 RSA 加密）与 `POST /common/msg/send` 仅做 GET/契约层验证（与文档"未发起提交"口径一致）。
- 本报告不修改任何 App 源码与被审文档。

---

## 7. 修复回执（文档作者，2026-09-30）

> 仅修改**交付文档** `departments-api-inventory.md` 与**证据目录说明**（本目录 `README.md`）；**未改动任何 App 源码**（`qin/DesignCode`、`qin/DesignCodeTests` 只读）。

| 条目 | 修改位置 | 复核方式 |
|---|---|---|
| **P1** `/common/article/page` 参数错误 | §1.1 端点表行 + 新增「参数实测」表；§3.5 补充注；§11.1 新增坑位 10b/10c；§12 补充 curl 段 | 亲测：`page=1`→10 条、`page=1&size=20`→20 条、`page=2&size=3`→3 条（第 2 页）、`pageNo=2&pageSize=3`→仍 10 条第 1 页、`pageNo=5`→仍第 1 页；确认 `pageNo/pageSize` 被忽略、**默认 size=10**；同栏目 `/common/article/page` total=**125** vs `/common/column/articles` total=**378**，已写入「不等价」注；保留 App `NetworkService.swift:762` 误用 `pageNo/pageSize` 备注 |
| **P2** 日历"正确网址"自相矛盾 | §7.1 整节重写（标题改为「正确入口结论」；落地页改为 `#/departments/page?site_key=jwc`；`&page=calendar` 降级为**无效路由反例**并引 network-capture 步骤 5 佐证）；§7.2 新增「日历入口」行；§12 curl 第 10 条加注；§11.3 新增坑位 27 | 与 `network-capture.md` 步骤 5（`&page=calendar` tables=0 无内容）逐句对齐，全文不再出现"正确网址 `&page=calendar`" |
| **P3** 截图缺失未说明 | §0 新增「证据形态说明」行；§13「HAR 说明」扩为「HAR / 截图说明」并明写"本次未归档任何页面截图"；§14 新增「证据形态」行；证据目录 `README.md` §四同步补注 | 全文检索"截图"确认已声明；保留 HAR 不可导出说明 |
| **P4** `detail_art_*` 计数 5→6 | §13 raw 明细表；证据目录 `README.md` §二 raw 明细表 | `ls raw/detail_art_*` = 6 个（01223003/046e6ed4/162/71e607e5/a94feef0/b8821e95），两处已改为 6 |
| **P5** App 行号不一致 | §1.1 表行、§10 `/common/article/page` 行统一为调用点 **760**（并注明函数 759、`pageNo/pageSize` 在 762） | `grep -n "article/page\|pageNo\|pageSize" NetworkService.swift` → 759 函数声明 / **760 调用** / 762 传参；全文已无 `NetworkService.swift:759` 单指调用点 |
| **P6** 未接入计数 8→9 | §10 汇总句改为「**未接入 9 个**」并补 `/dept/home`（功能被 home2 覆盖）；另加 `/common/article/page` 应视为"待修复" | 核对 §10 表中 ⚠️/❌ 行：`college/home`、`teacher/page`、`search`、`school/events`、`school/home5`、`msg/send`、`recruit/query`、`short/create`、`dept/home` = 9 项 |

**修复后自检**（脚本机械检索 `departments-api-inventory.md`）：
- 34 机构名 **34/34** 可检索 ✅
- 22 个 site_key **22/22** 可检索 ✅
- 178 个 column_id **178/178** 可检索 ✅
- 20 个端点路径 **20/20** 可检索 ✅
- 全文无 `TODO`／`待补` ✅

---

## 8. 二次全面复核（2026-10-01，独立子代理 fresh-eyes 机械重算）

> 在首轮审计（§1~§7）完成并修复后，为满足「臻至完美、0 遗漏」验收，再次引入**未参与任何执行环节**的独立子代理对全部交付物做机械重算，并对全部指控经源码 grep / 直连复验核实后修订文档。完整记录与实机补抽见 `../departments-api-verify-20261001.md` §8。

**本轮独立重算结论**：
- 机构树 40 节点（1 根 + 5 分组 + 34 叶子）、site_key 24→唯一 22、article_id 11（10 单文 + 1 双配）、仅 key 3、空串 2、未配置 0 —— 与 §2.1/§2.4/§2.5 **一致** ✅
- agentB 22 站 / 178 栏目与清单 §3.4 逐站求和 **一致** ✅
- §8 覆盖矩阵 34×6 = 204 格全非空、§2.5 = 34 行 **一致** ✅
- §4.2 栏目类型统计 178 栏全量复核 **一致** ✅
- endpoints.txt 21 路径行（含非 API 的 `/article/videos`）与 §1(20)+§1.1(2) 对应 **一致** ✅

**本轮新发现且已修复的问题（1 阻塞 + 2 中等 + 3 轻微）**：
| # | 严重度 | 问题 | 修复 |
|---|---|---|---|
| Q1 | **阻塞** | inventory §1.1/§10/§11.1-10b/§14 反复断言「App 仍传 `pageNo/pageSize`、分页失效、待修复」——**源码已修复**（`NetworkService.swift:763-766` 已用 `page/size`），照文档会误"修"已修好代码 | 全部改为「已修复（2026-09-30）」 |
| Q2 | 中等 | §10 行号大面积过期（Offset +3；`OrganizationView:1887,2030` 引错；`NotificationManager:638` 过期）；「已接入 14」实为 13 | §10 全表按实测更新 |
| Q3 | 中等 | raw 计数三口径（310/310/311）均与实 312 不符；`raw_cal_list.json` 未入 §13/README 分类表 | 统一 312（311 JSON+1 txt）并补行 |
| Q4 | 轻微 | checklist 行数「1079」、audit「1047」、实际 1086 | checklist 改 1086 |
| Q5 | 轻微 | verify §0「29 条」与台账编号不符 | 修正为 32 条/台账 24 条 |
| Q6 | 轻微 | §2.4「仅 site_key 3 个均需 home2 补 site_id」夸大 | 细化：仅保卫处真需补；校办/学工处为共用键 |

**实机补抽（本轮新增）**：双配型财资处（前端点击优先文章详情、站点/文章两端均可用）、图书馆 tsg（干净复现首页仅 3 请求，排除一次会话残留）、招生网 zsw（正常）——均与清单一致。

**最终判定**：核心契约（端点/参数/响应/34·22·178·204 格/资源规则/坑位）经独立机械重算 + 源码 grep + 实机补抽三重交叉验证**全部自洽真实，可直接用于客户端开发**。

---

*（二次复核记录结束，Q1–Q6 全部闭环）*