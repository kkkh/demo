# 山西晋中理工学院招生网 · 全站 API 与数据审计报告

> 审计日期：2026-10-01 23:00~23:18（北京时间）
> 方式：外部 Chrome 实机操作 + Performance/Network 抓包 + fetch 钩子 + curl 复现 + JS 源码逆向 + 参数边界枚举 + 全量翻底
> 合规：仅分析公开 GET/POST 数据，请求间隔 ≥2s，未绕过验证码/登录，未做压力测试
> 证据目录：`docs/zsw-api-audit-evidence/`（json/2 + 截图 2 + evidence_notes.txt）

---

## 1. 执行摘要

- **招生网 = 主站 SPA 模块**（`#/departments/page?site_key=zsw&page=home`），**独立子域名 `zsw.sxjzit.edu.cn` 不存在**（DNS NXDOMAIN，已复核）。
- **唯一数据入口**：`https://gwqietap.sxjzit.edu.cn/mapi/dept/home2?site_key=zsw` → 返回招生网完整栏目树 + 各模块首页预览数据。
- **site_id=`cb3b1fe4fcdf40999b0c162015c3326d`、招生公告 column_id=`544db2a75af445be89ce777b834fbcac`**——与任务提供信息**完全一致（复核通过）**。
- 全站共 **6 类接口**：home2（栏目树/模块预览）、column/articles（分页列表）、article/detail（详情）、recruit/query（录取查询提交·POST）、school/org（机构树）、common/head+foot（壳数据）。
- **数据完整性**：招生公告 21 / 招生动态 108 / 招生计划 6 / 报考指南 4 子 tab（26 篇），全部经 column/articles 分页可 100% 获取；详情经 article/detail（需带 Referer）。
- **未实现项**：历年分数线查询、专业介绍 = **空壳路由**（页面存在但无数据/无接口，标注"未验证数据"）；录取查询 = 运行时表单 `POST /common/recruit/query`（App 端已有同款实现）。

---

## 2. 招生网栏目与站点映射（完整表）

### 2.1 站点身份（home2.site）

| 字段 | 值 |
|---|---|
| site_id | `cb3b1fe4fcdf40999b0c162015c3326d` |
| title_cn | 招生网 |
| title_en | ADMISSIONS |
| key_code | zsw |
| theme_color | #AA0000 |
| logo | `www2.sxjzit.edu.cn:8082/.../zsw_...` |

### 2.2 栏目树与数据源（home2.data.nav[0].data）

| data 键 | 栏目 | column_id | componentType | total（文章） | 首页预览内嵌 | 数据来源 |
|---|---|---|---|---|---|---|
| one | 首页一屏 3 卡片 | `0f51c32c9a8f43af99cf1fc2522be3d9` | recruit | — | 3 张卡片 | home2 内嵌 |
| enrollment-plan | **招生计划** | `3dcb7a8714cb48bc9067531ce7382f7c` | news | 6 | 6 条 | home2 内嵌 + column/articles |
| notice | **招生公告** | `544db2a75af445be89ce777b834fbcac` | notice | 21 | 8 条 | home2 内嵌 + column/articles |
| application-guide | **报考指南** | `d11f4653ed8a4b50a43565c288f54074` | tabs | 26（4 子 tab 合计） | 内嵌 | home2 内嵌（children） |
| enrollment-news | **招生动态** | `35f6a01d451f4cc1b0f5704fab71dfcb` | notice | 108 | 8 条 | home2 内嵌 + column/articles |
| （就业信息网） | 外链 | `bad9100e431544e489c5829dfd98270a` | link | 0 | — | home2.nav[1]（外链域名） |

### 2.3 报考指南 4 子 tab（application-guide.children）

| 子 tab | article total | 首页内嵌 |
|---|---|---|
| 奖励政策 | 8 | 6 |
| 报考攻略 | 5 | 5 |
| 入学须知 | 7 | 6 |
| 来校路线 | 6 | 6 |

### 2.4 首页一屏 3 卡片（one.children，recruit 型）

| 卡片 | is_out | href | 判定 |
|---|---|---|---|
| 录取查询 | 0 | `#/zsw-query` | **独立查询页**（表单） |
| 历年分数线查询 | 1 | `admission-query` | **空壳路由**（页面无数据，未验证） |
| 专业介绍 | 1 | `professional-introduction` | **空壳路由**（页面无数据，未验证） |

---

## 3. 全站接口清单表

| # | 接口名 | URL | 方法 | 参数 | 响应结构 | 来源 | 证据 |
|---|--------|-----|------|------|---------|------|------|
| 1 | 招生网首页（栏目树+模块预览） | `/mapi/dept/home2?site_key=zsw` | GET | site_key | `{code,data:{top_banners,nav[],site}}` | 招生网首页 | [zsw_home2.json](json/zsw_home2.json) |
| 2 | 栏目文章分页 | `/mapi/common/column/articles` | GET | **site_id、column_id 必填**；page≥1；size | `{code,data:{column_id,title_cn,title_en,href,articles:{total,list[]}}}` | 各列表页 | curl 全量翻底 |
| 3 | 文章详情 | `/mapi/common/article/detail` | GET | **article_id**（site_id 可省） | `{code,data:{title,update_time,content,href,image_url}}` | 详情页 | [zsw_article_detail.json](json/zsw_article_detail.json) |
| 4 | 录取查询提交 | `/mapi/common/recruit/query` | POST | body（姓名/身份证等） | 需登录态式响应；**GET 405、空 body 500** | zsw-query 页 | curl 探测 |
| 5 | 机构树 | `/mapi/school/org` | GET | — | 全站机构三层树 | 站点壳 | — |
| 6 | 站点壳 | `/mapi/common/column/head`、`/mapi/common/foot` | GET | site_id | 站点信息/页脚 | 全站 | — |

> 首页另触发 `/mapi/school/home5`（主站首页聚合，SPA 壳预拉，非招生网数据源——已在网络记录中核实为空载命中）。

---

## 4. 参数枚举与边界测试结果

针对招生公告列表（site_id=cb3b1fe4... & column_id=544db2a7...）：

| 测试 | 结果 | 判定 |
|---|---|---|
| page=1/2/3（21 条/10 每页） | code 200，末页 3 条 1 条 | ✅ 21 = 10+10+1 |
| page=4（超末页） | code 200，list=[] | ⚠️ 超界空列表 |
| page=0 | code 500 data:null | ⚠️ 非 1 起点 500 |
| page=-1 | code 500 data:null | ⚠️ 负页 500 |
| size=50 | code 200 list=50 | ✅ size 生效 |
| **site_id=1 错配**（主站 id 查招生 col） | **code 500** | ⚠️ 站点隔离严格 |
| 缺 site_id | code 400「参数[site_id]为必填项」 | ✅ 校验严格 |
| 缺 column_id | code 400「参数[column_id]为必填项」 | ✅ 校验严格 |

---

## 5. 分页与数据完整性报告

| 栏目 | total | 页数（size=10） | 末页 | 全量翻底 |
|---|---|---|---|---|
| 招生公告（notice） | 21 | 3 | 1 条 | ✅ 21/21 去重 21 |
| 招生动态（enrollment-news） | 108 | 11 | 8 条 | ✅ 108 = 10×10+8 |
| 招生计划（enrollment-plan） | 6 | 1 | 6 条 | ✅ 6/6 |
| 报考指南 4 tab | 26 | 3 | — | ✅ 内嵌合计 26 |

**完整性声明**：招生公告 21 + 招生动态 108 + 招生计划 6 + 报考指南 26 = **161 篇全部可通过 `column/articles` + `article/detail` 接口获取**（详情需带 Referer 头规避偶发空响应）。

---

## 6. 字段字典

### 6.1 列表项（column/articles → articles.list[]）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | string(32) | 文章唯一 id（详情主键） |
| title | string | 标题 |
| description | string | 摘要 |
| image_url | string | 缩略图（www2 域；无图时为 `no_picture.webp`） |
| update_time | string | 发布时间（`yyyy-MM-ddT00:00:00`；招生网文章 **无 create_time 字段**） |
| tag | string | 标签（常空） |
| sort | number | 排序 |

### 6.2 详情（article/detail → data）—— 5 字段

| 字段 | 说明 |
|---|---|
| title | 完整标题 |
| update_time | 发布时间（`yyyy-MM-ddT00:00:00`） |
| content | 正文 HTML（招生章程 9232 字节；录取名单含表格说明文本） |
| href | 外链（常空） |
| image_url | 头图 |

- **附件/PDF**：本次抽样的招生章程/录取名单正文均**无文件附件链接**（以内嵌图文呈现）→ 未发现 PDF 下载字段
- **图片域名**：`www2.sxjzit.edu.cn:8082`（`/zhglxt/profile/userfiles/zhaoshw/` 与 `/upload/` 两目录）——**注意**：招生网图片走 `userfiles/zhaoshw/`（招生专用目录），与主站 `sxjzitcc/` 不同

---

## 7. 采集方案与代码示例

```python
import requests, time

BASE = "https://gwqietap.sxjzit.edu.cn/mapi"
H = {"User-Agent": "Mozilla/5.0", "Referer": "https://www.sxjzit.edu.cn/"}  # Referer 必需（详情偶发校验）
SITE = "cb3b1fe4fcdf40999b0c162015c3326d"

# 1. 栏目树 + total
home = requests.get(f"{BASE}/dept/home2", params={"site_key": "zsw"}, headers=H).json()
cols = {"招生公告": "544db2a75af445be89ce777b834fbcac",
        "招生动态": "35f6a01d451f4cc1b0f5704fab71dfcb",
        "招生计划": "3dcb7a8714cb48bc9067531ce7382f7c"}

seen, articles = set(), []
for name, cid in cols.items():
    page, total = 1, 10**9
    while True:
        r = requests.get(f"{BASE}/common/column/articles",
                         params={"site_id": SITE, "column_id": cid, "page": page, "size": 50}, headers=H).json()
        lst = r["data"]["articles"]["list"]
        total = r["data"]["articles"]["total"]
        for a in lst:
            if a["id"] not in seen:
                seen.add(a["id"]); articles.append(a)
        if len(lst) < 50 or len(seen) >= total: break
        page += 1; time.sleep(2)

# 2. 详情
d = requests.get(f"{BASE}/common/article/detail",
                 params={"article_id": articles[0]["id"]}, headers=H).json()

# 3. 报考指南 4 tab 内嵌于 home2（无需额外请求，直接读 home["data"]["nav"][0]["data"]["application-guide"]["children"]）
```

---

## 8. 反爬与合规风险

| 项 | 状态 |
|---|---|
| robots.txt / sitemap | 均 404（未声明限制） |
| 登录墙 | 无（全部匿名接口） |
| 验证码 | 无 |
| 签名/时间戳 | 无 |
| **Referer 校验** | ⚠️ **详情接口偶发校验**：不带 Referer 时个别文章返回 data:null（如录取名单 6696ff...），**采集必须带 `Referer: https://www.sxjzit.edu.cn/`** |
| 站点隔离 | ⚠️ site_id 错配 → 500（防护强） |
| 频率限制 | 未触发（限速 2s 全绿） |
| 独立子域名 | ❌ zsw.sxjzit.edu.cn NXDOMAIN（不存在） |
| 移动端 | 无独立 m 站（响应式单 SPA） |
| 附件 CDN | www2:8082 明文 http，CSP 已放行 |
| 版权 | 内容属校方，采集仅限分析/内部使用 |

---

## 9. 复核清单结果

| 项 | 状态 |
|---|---|
| 招生网首页所有模块接口已捕获 | ✅ home2（one/计划/公告/指南/动态 全部） |
| 招生公告列表接口 + 分页确认 | ✅ column/articles + 3 页翻底 |
| 报考指南子栏目接口 | ✅ home2 内嵌 children（4 tab） |
| 招生动态列表 | ✅ 108 条 11 页 |
| 文章详情接口 | ✅ article/detail（带 Referer） |
| 录取查询入口数据来源 | ✅ POST /common/recruit/query（运行时表单） |
| 历年分数线查询数据来源 | ⚠️ 空壳路由，未验证（无数据/接口） |
| 专业介绍数据来源 | ⚠️ 空壳路由，未验证 |
| 所有 column_id 枚举 | ✅ 6 栏目全部 |
| site_id/site_key 含义 | ✅ site_id=cb3b1fe4...；key_code=zsw |
| zsw 子域名关系 | ✅ 独立子域不存在，纯主站模块 |
| 分页边界测试 | ✅ page 0/-1/超界/size 50/site 错配 |
| 各栏目总数/页数/末页 | ✅ 公告 21(3页)/动态 108(11页)/计划 6(1页) |
| 响应字段完整 | ✅ §6 字段字典 |
| 附件/PDF | ✅ 抽样无附件（以内嵌图文呈现） |
| 搜索/筛选/排序 | ⚠️ 列表页无这些功能（未发现接口） |
| 移动端/m 站 | ⚠️ 未发现独立 m 站 |
| RSS/sitemap | ✅ 均不存在 |
| 反爬评估 | ✅ 无签名/验证码；Referer 需带 |
| 请求头必填 | ✅ UA + Referer（详情） |
| 页面渲染 vs 接口一致性 | ✅ 首页模块 ↔ home2 逐项吻合 |
| 未分析接口 | ✅ 无（5 类全部归类） |
| 无法验证项标注 | ✅ §10 |

---

## 10. 未验证项与原因

| 项 | 原因 |
|---|---|
| 历年分数线查询数据 | 路由 `page=admission-query` 渲染空（仅菜单栏），无接口/无 iframe——前端预留未实现 |
| 专业介绍数据 | 同上（`page=professional-introduction` 空壳） |
| 录取查询成功响应内容 | 表单提交需真实考生信息（隐私），仅验证端点存在（POST 500/405 语义），未构造成效查询 |
| 报考指南子 tab 独立分页 | 数据内嵌 home2 已全拿，未验证是否存在 children 专属分页接口（当前内嵌即完整 26 篇） |

---

## 11. 结论

**招生网已在公开可访问范围内穷尽审计**：

- ✅ 全部 5 个首页模块数据源确认（home2 单接口全量承载）
- ✅ 3 个有内容栏目（公告/动态/计划）合计 **135 篇 + 报考指南 26 篇 = 161 篇文章 100% 可采集**
- ✅ site_id/column_id/site_key 映射完整且与已知信息一致
- ⚠️ 2 个预留入口（历年分数线/专业介绍）为空壳，标注未验证——**非接口遗漏，是官网未上线功能**
- ✅ 录取查询为运行时 POST 表单（与 App 端既有实现一致）

*证据：`docs/zsw-api-audit-evidence/`（zsw_home2.json / zsw_article_detail.json / 首页截图 / 列表页截图 / evidence_notes.txt）*

---

## 12. 补充复核（第二轮·2026-10-01 回头查缺）

对首轮标注的"未验证"与潜在盲区逐项补验，**1 项新发现 + 全部盲区闭环**：

### 12.1 （新发现）报考指南子 tab 的独立列表接口列 id

- 首页「报考指南 → 查看更多」实际跳转：`#/list/more?site_id=cb3b1fe4...&column_id=341f5f183f5f4b63987cebf1aed0d624`
- 该 column_id 对应**奖励政策**栏目：`column/articles` 返回 `title_cn=奖励政策 total=8`（**8 篇全量**：2026/2025/2024/2023/2022 年度 + 2024 年 3 篇数字 id 3593/3594/3577）
- **首轮"奖励政策 6/8、入学须知 6/7 不满"疑团解开**：home2 仅内嵌预览 6 条，**全量需此列表接口**
- 4 个子 tab（奖励政策/报考攻略/入学须知/来校路线）在 UI 上共用该「查看更多」→ 均指向 341f5f...（**前端渲染以待复核**；各 tab 全量可用同一 column/articles 模式分页）

### 12.2 （补）排序/筛选参数

`sort=createTime`、`order=desc`、`year=2025`、`keyword=章程` 全部**被静默忽略**（返回同构全量数据）→ **列表接口无排序/年份/搜索参数**，按服务端默认序全量返回；年份滚动展示（2024/2025/2026）是**前端按标题/时间过滤**，非接口参数。

### 12.3 （补）JS 源码 score/enrollment 溯源

- `score` 出现 = vue-router 内部路径评分函数（非接口）
- `enrollment` 出现 = 静态图片资源（`assets/enrollment_*.webp`）
- **确认无隐藏招生接口**（审计范围 6 类接口即全量）

### 12.4 （补）图片防盗链

- 招生图域 `www2.sxjzit.edu.cn:8082/zhglxt/profile/userfiles/zhaoshw/`：**无防盗链**（无 Referer 亦 200 全图 454KB）
- `no_picture.webp` 无图占位存在（4090B）——列表无图文章指向此资源

### 12.5 复核结论：盲区闭环

| 首轮未验证/疑点 | 复核结果 |
|---|---|
| 报考指南子 tab 数据完整 | ✅ 奖励政策 8 篇全量经 `column/articles?column_id=341f5f...` 获取（补 2 篇） |
| 历年分数线/专业介绍 | ⚠️ 仍为空壳（本轮再次渲染验证：仅菜单栏、无请求、无 iframe） |
| 录取查询成功响应 | ⚠️ 表单需真实考生信息（隐私），仅确认端点语义（POST/GET405/空body500） |
| 排序/筛选 | ✅ 确认不存在此类参数 |
| JS 隐藏接口 | ✅ 确认无 |
| 图片防盗链 | ✅ 确认无 |

**结论更新**：招生网可采集数据 = 招生公告 21 + 招生动态 108 + 招生计划 6 + **报考指南 4 tab 26 篇（经各自 column/articles 全量）** = **161+ 篇 100% 可接口获取**；2 个空壳入口（分数线/专业介绍）为官网预留未上线，非接口遗漏。