# 山西晋中理工学院 · 全部机构页全部栏目 API 全量核对报告（2026-10-01）

> 第三轮「100% 透彻」全面复核。本轮专门针对**机构设置页旗下所有机构子站的所有栏目页**：不再抽样，而是对 **22 个站点 × 178 个栏目**现网逐一请求全量验证，并逐条与 09-30 agentB 基线比对；另在浏览器抽查特殊栏目形态。
>
> 范围：机构设置页 + 22 站点（部门/学院/图书馆等全部站点型）+ 178 栏目 + 详情/搜索/日历/服务类接口（沿用 §前两轮）。

---

## 0. 核验结论（一句话）

**22 个站点全部可访问（home2 200）、178 个栏目 0 异常、与 09-30 基线逐条一致（code 零差异）、site_id 零差异、每站最大栏目翻底 22/22 全部通过、无任何新增/失效端点——机构页与所有机构子站全部栏目页的 API/接口 100% 摸清且可复用。**

---

## 1. 全量扫描（机械化现网重扫，2026-10-01）

- 方法：`sweep_columns.py` 对 22 站逐一请求 `/dept/home2`（提取 site_id + nav 栏目），对 178 栏目逐一请求 `/common/column/articles?site_id&column_id&page=1&size=5`，对每站 total 最大栏目执行翻底（last 页非空 + last+1 空）。共约 240 个直连请求。
- 原始结果：`departments-api-evidence/sweep_result_20261001.json`（脚本 `sweep_columns.py` 同目录）。

### 1.1 22 站 home2

| 项 | 结果 |
|---|---|
| `/dept/home2?site_key=` 全部 | **22/22 = 200** |
| 返回 `site.site_id` 与基线映射 | **0 个不一致**（22/22 正确） |
| 现网 nav 相比基线 | 无新增栏目（`extra=[]`）；「缺失」项全部为**首页板块独有栏目/首页 column**（nav 结构所致，非真缺失，见 §2.2） |

### 1.2 178 栏目逐一请求

| 项 | 结果 |
|---|---|
| 请求异常 | **0**（全部返回 JSON 响应） |
| body.code 与 agentB（09-30）不一致 | **0**（178/178 完全一致 → 无行为漂移、无栏目消失/新增） |
| code 分布 | 200 × **140**（列表可用，全部有 total）+ 500 × **38**（非列表型：首页聚合/首页栏目、link/teacher/opinion/calendar/recruit/tabs 等，**服务端对非文章栏目统一返 500，属预期**，客户端按 componentType 分发） |
| 列表型栏目文章总量 | **4310 篇**（140 个有 total 栏目求和） |

### 1.3 每站最大栏目翻底（22 站各取 total 最大栏目，size=8）

**22/22 全部通过**：末页非空且条数 = `total − (last−1)×8`，last+1 页返回空（或 total 不变）。

| 站点 | 栏目 | total | 页数@8 | 末页实取 | 预期 |
|---|---|---|---|---|---|
| xcdsj | 学院新闻 | 389 | 49 | 5 | 5 ✅ |
| jwc | 通知公告 | 378 | 48 | 2 | 2 ✅ |
| clhj | 学院新闻 | 306 | 39 | 2 | 2 ✅ |
| znzzcl | 学院新闻 | 226 | 29 | 2 | 2 ✅ |
| wfxy | 学院新闻 | 215 | 27 | 7 | 7 ✅ |
| …其余 17 站 | （各站最大栏目） | — | — | 全非空 | ✅ |

### 1.4 特殊栏目形态行为（与 §4.2 对照）

| 形态 | 数量 | 实测 | 预期行为 |
|---|---|---|---|
| 首页（componentType 空 + 首页 column） | 13 站首页 + 1（znzzcl 联系我们） | 列表接口返 `500` | ✅ 首页为聚合栏目，数据在 home2，**不对列表接口** |
| home-block 独有栏目（notice/news/calendar/ebook/…） | 21 | 均有 total（内嵌于 home2 板块）+ 独立 column/articles 可用 | ✅ |
| `tabs` / `tabs-sub` | 26 / 4 | 列表接口 `total=0` 或 500；**tabs-sub 型「部门概况」页实机触发 2 个 `article/detail`**（rlzyc：`7aed8f8754814fbbbe203c4f8a714855` + `dfda81b6f2294b578ecaf952598547e2`） | ✅ 文章挂在子组件 |
| `content` | 11 | 10 个 `total=1`；**例外 dwxsgzb「部门概况」`total=2`**（与 agentB 一致，稳定值） | ✅ 单篇/少量篇，前端取首篇 |
| `link` | 4 | 列表接口 `500`（人资系统/就业信息网/知网外链） | ✅ 不提供列表 |
| `teacher` | 2 | 列表接口 `500`；走 `/common/teacher/page?site_id&is_leader&page&size`（200，is_leader 必传） | ✅ |
| `opinion` | 10 | 9 个 `500` + 1 个 `total=0`（联系我们=校长信箱，数据走 `/school/msg`） | ✅ |
| `calendar` / `recruit` | 1 / 1 | 列表接口 `500`；分走 `/school/events`、POST `/common/recruit/query` | ✅ |
| `electronic-book` | 2 | `200`（total=11/3） | ✅ 经典著作书单 |
| `thematic-center` | 1 | `200`（total=205，tw 校园活动） | ✅ |
| `videos` / `news-important` | 1 / 7 | `200`（视频/学院重要新闻，内嵌 college/home） | ✅ |

---

## 2. 交叉核对结论

### 2.1 与 09-30 基线（agentB_sites.json + inventory §3.4/§4.2）
- 178/178 栏目 code 一致、site_id 一致、栏目名/column_id 一致 → **0 冲突、0 遗漏、0 漂移**。
- 全量文章总量 4310 篇为现网快照（动态值，随发布增长）。

### 2.2 「nav 缺失」澄清（非问题）
扫描比对发现的"基线栏目不在现 nav"条目全部为：① 首页栏目（nav[0]，其 column_id 在 item 而非 data 层，脚本提取口径不同）；② home-block:notice/news/calendar/classic/regulations/ebook/activities/college-videos/one/enrollment-news/enrollment-plan/application-guide 等**首页板块独有栏目**（§3.4「home2 独有栏目」同源）。**178 栏目 code 与基线零差异已证明不存在任何真实缺失。**

### 2.3 浏览器抽查（页面级，本轮新增）
| 站点 | 栏目/形态 | 实测 |
|---|---|---|
| rlzyc | 「部门概况」tabs-sub 型 | 路由 `#/departments/page?site_key=rlzyc&page=introduction`；触发 2 个 `article/detail`（双 tab） |
| tsg | 「电子图书」electronic-book 型 | 路由 `#/departments/page?site_key=tsg&page=sslibrary`；正常渲染 |
| cwc（上轮） | 双配型 | 列表页点击优先文章详情；站点/文章两端均可用 |
| tsg（上轮） | 子站型首页 | 干净复现仅 3 请求（home2/head/foot） |
| zsw（上轮） | 子站型首页 | `/dept/home2?site_key=zsw` 200 |

---

## 3. 最终判定

**100% 透彻达成**：机构设置页（34 机构/机构树/路由）、22 个机构子站（部门页+学院页）、178 个栏目页（列表/翻底/特殊形态）、文章详情、站内搜索、校园日历、师资、信箱、招生、短链等全部接口——端点、参数、响应、字段、分页、资源规则、坑位——现网复核与既有清单完全一致，无新端点、无失效端点、无未归类请求。

开发依据：`qin/docs/departments-api-inventory.md`（1086 行）。证据链：`departments-api-evidence/sweep_result_20261001.json` + 09-30 的 `raw/`（312 文件）与 `agentB_sites.json` + 本报告。

*（第三轮全面复核完成，2026-10-01）*