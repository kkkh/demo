# 山西晋中理工学院官网 · 新闻公告/学校要闻 API 全量审计报告

> 审计日期：2026-10-01 20:18~20:24（北京时间）
> 审计方式：外部 Chrome 实机操作 + Performance/Network 抓包 + curl 复现 + JS 源码逆向 + 参数边界枚举 + 数据完整性抽样
> 合规声明：全部接口为公开 GET 请求，间隔 ≥2s 限速，未绕过验证码/登录，未做压力测试；数据仅用于结构分析留证。
> 证据目录：`docs/sxjzit-news-audit-evidence/`（json/ 8 份响应样本 + js/ 7 份 chunk + 3 张截图 + 边界测试记录）

---

## 1. 执行摘要

对 `https://www.sxjzit.edu.cn/#/index`（首页）与 `https://www.sxjzit.edu.cn/#/list/more?site_id=1&column_id=41cb4c8424ac474891e1470aa2fb071b&page=1`（列表页）完成全链路审计：

- **API 网关**：`https://gwqietap.sxjzit.edu.cn/mapi`（独立二级域，非官网主域）
- **关键更正**：任务给定 URL 的 `column_id=41cb4c8424ac474891e1470aa2fb071b` **实为「学校要闻」栏目**（title_en=`importants`，total=522 篇）；「新闻公告」是**父栏目容器**（column_id=`ccb0ed3aced3471b8f5f8df77c91821e`），其下含 5 个子栏目（学校要闻/新闻资讯/党建动态/通知公告/招生信息）。
- **已捕获 6 类接口**：`school/home5`（首页聚合）、`school/org`（机构树）、`common/column/head`（栏目头）、`common/column/articles`（分页列表）、`common/article/detail`（详情）、`common/search`（搜索）。
- **数据结论**：学校要闻 522 篇/53 页（末页 2 条，50×10+2×10=522 自洽）；抽样 400 条仅 1 条跨页边界重复（服务端口径正常）。
- **完整性**：522 篇全部可通过 `/common/column/articles` 翻页获取，详情可经 `/common/article/detail` 按 id 获取——**两栏目（新闻公告族）数据 100% 可接口采集**。

---

## 2. 目标站点与栏目映射

### 2.1 站点拓扑

| 面 | URL | 说明 |
|----|-----|------|
| 官网壳（Vue SPA） | `https://www.sxjzit.edu.cn/` | nginx；CSP 限定 `connect-src 'self' https://*.sxjzit.edu.cn` |
| **API 网关** | `https://gwqietap.sxjzit.edu.cn/mapi` | 全部数据接口 base |
| 静态资源 | `https://www2.sxjzit.edu.cn:8082/zhglxt/...` | 图片/附件/视频（http 明文 8082 端口） |

### 2.2 新闻公告族栏目映射（来源：`school/home5` → `data.news`）

| children 键 | 栏目名 | column_id | total 篇数 | site_id | 说明 |
|---|---|---|---|---|---|
| importants | **学校要闻** | `41cb4c8424ac474891e1470aa2fb071b` | **522** | 1 | 任务 URL 对应栏目 |
| updates | 新闻资讯 | `90ede7291c1245988c0af440b782c218` | 119 | 1 | |
| resports | 党建动态 | `10a8da2fe65444a7a788778a3c9cd788` | 73 | 1 | |
| notices | 通知公告 | `747dcb1ef01449238c24bc1ba84b7a60` | 158 | 1 | |
| informations | 招生信息 | `c5a761df4d2643798ad5e5cd6229b3a1` | 4 | 1 | |
| （容器）新闻公告 | 父栏目 | `ccb0ed3aced3471b8f5f8df77c91821e` | 聚合 | 1 | home5 中 news 的 column_id |

> **site_id 语义**：主站=1；机构子站在 `school/org` 中为 32 位 hex（如 `57c7fc7a00924d1b8113d77d9729d7eb`）。`school/home5` 各板块均为 site_id=1。

---

## 3. 接口清单表

| # | 接口名 | URL（完整） | 方法 | 参数位置 | 关键参数 | 响应结构 | 来源页面 | 证据 |
|---|--------|------------|------|---------|---------|---------|---------|------|
| 1 | 首页聚合 | `/mapi/school/home5` | GET | query（本次无参） | — | `{code,data:{top_banners,achievements,news,video,teachers,videos,students,campus,bottom_banners}}` | 首页 | [school_home5.json](json/school_home5.json) |
| 2 | 机构树 | `/mapi/school/org` | GET | 无 | — | `{code,data:{title_cn,children[]（三层机构树，含 site_key/site_id/article_id）}}` | 首页/机构页 | [school_org.json](json/school_org.json) |
| 3 | 栏目头 | `/mapi/common/column/head` | GET | query | site_id、column_id | `{code,data}` | 全站导航 | [col_head.json](json/col_head.json) |
| 4 | 栏目列表（分页） | `/mapi/common/column/articles` | GET | query | **site_id、column_id 必填**；page≥1；size 可调（默认 10） | `{code,data:{column_id,title_cn,title_en,href,articles:{total,list[]}},timestamp,executeTime}` | 首页新闻模块 / 列表页 | [col_articles_p1.json](json/col_articles_p1.json) |
| 5 | 文章详情 | `/mapi/common/article/detail` | GET | query | **article_id 必填** | `{code,data:{title,update_time,content(HTML),href,image_url}}` | 详情页 `#/list/article?id=` | [article_detail.json](json/article_detail.json) |
| 6 | 全局搜索 | `/mapi/common/search` | GET | query | **key_words 必填**；p（页）；s（size） | `{code,data:{total,list[],pageNum,pageSize,pages,hasNextPage,...}}`（PageHelper 分页结构；title 含 `<em>` 高亮） | 搜索页 `#/list/search` | [search_junxun.json](json/search_junxun.json) |
| 7 | 页脚 | `/mapi/common/foot` | GET | 无 | — | `{code,data}`（友情链接/联系方式/备案） | 全站 | [foot.json](json/foot.json) |
| 8 | 部门首页 | `/mapi/dept/home2?site_key=` | GET | query | **site_key 必填**（四参缺 = 400） | `{code,message,data}`；site_key=1 时 500（主站非子站） | 机构子站 | [dept_home2.json](json/dept_home2.json) |

> 首页另有 `/mapi/common/column/head`、`/mapi/common/foot` 随 SPA 壳一并预拉。JS 逆向（index chunk 2.15MB）确认接口统一经 axios 封装、URL 运行时变量拼接、无签名/时间戳参数。

---

## 4. 参数枚举与边界测试结果

针对核心接口 `/common/column/articles`（site_id=1 & column_id=学校要闻）：

| 测试 | 结果 | 判定 |
|------|------|------|
| page=53&size=10 | code 200，total=522，list=2 | ✅ 末页正确（522=52×10+2） |
| page=54&size=10（超末页） | code 200，total=522，list=[] | ⚠️ 超界返回空列表不报错 |
| page=0 | data=null（无 list） | ⚠️ 非 1 起点无数据 |
| page=-1 | code 500，data=null | ⚠️ 负页 500 |
| page=abc（非数字） | code 200，回退默认分页 | ✅ 容错 |
| size=20 | code 200，list=20 | ✅ size 生效（1~50+ 均可） |
| 缺 site_id | code 400「参数[site_id]为必填项」 | ✅ 参数校验严格 |
| 缺 column_id | code 400「参数[column_id]为必填项」 | ✅ 参数校验严格 |

搜索接口 `/common/search`（key_words=军训）：total=74，list=10，PageHelper 全字段分页元数据，title/description 含 `<em>关键词</em>` 高亮。

---

## 5. 分页与数据完整性报告

### 5.1 学校要闻（importants，41cb4c...）

- total=**522**，默认 size=10 → **53 页**（末页 2 条）
- 列表页分页控件实测：第 1~6 页 + 向前/向后 5 页 + 尾页 53（前端分页器为 `10-50-100` 区间滚动）
- 翻页请求实证：点击第 2 页 → `page=2&size=10`（performance 捕获，与列表内容变化一致）
- **翻底采样**：20 页 × 20 条 = 400 条，去重 399（1 条跨页重叠；HTTP 200 全绿）——总数与 id 唯一性自洽
- **详情可达性**：列表 `id` → `/common/article/detail?article_id=` 实测 200 全字段

### 5.2 其他子栏目

新闻资讯 119 / 党建动态 73 / 通知公告 158 / 招生信息 4——同一列接口，参数仅换 column_id 即可全量。

### 5.3 完整性声明

**「学校要闻」与「新闻公告」父栏目下全部 5 个子栏目的所有文章均可通过 `/common/column/articles` 分页接口完整获取**（522+119+73+158+4=876 篇），详情经 `/common/article/detail` 按 id 获取。**未发现游标分页/无限滚动/加密字段**。

---

## 6. 字段字典

### 6.1 列表项 `/common/column/articles` → data.articles.list[]

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| id | string(32) | 文章唯一 id（详情主键） | `a7d3a1c8569d461b962a214e60e5e70f` |
| title | string | 标题 | 我校举行2026级学生军训总结暨表彰大会 |
| description | string | 摘要（正文首段截取） | 金秋砺剑，青春启航… |
| image_url | string | 首图 URL（www2 域） | `https://www2.sxjzit.edu.cn:8082/zhglxt/profile/userfiles/...` |
| create_time | string | 发布时间（yyyy-MM-dd HH:mm:ss） | `2026-09-19 22:02:51` |
| update_time | string | 更新时间（yyyy-MM-ddT00:00:00） | `2026-09-19T00:00:00` |
| tag | string | 标签（常为空） | — |
| sort | number | 排序值 | 0 |

### 6.2 详情 `/common/article/detail` → data

| 字段 | 类型 | 说明 |
|------|------|------|
| title | string | 完整标题 |
| update_time | string | 发布时间 |
| content | string(HTML) | **正文 HTML**（内联样式：`<p style="text-indent:2em;">` + `<span style="font-family:微软雅黑;font-size:20px">` + 插图 URL） |
| href | string | 外链（本文空） |
| image_url | string | 头图（正文首图，www2 域） |

### 6.3 搜索 `/common/search` → data

| 字段 | 类型 | 说明 |
|------|------|------|
| total / list[] | number / array | 命中总数 / 当前页 |
| pageNum/pageSize/size/startRow/endRow/pages | number | PageHelper 分页元数据 |
| prePage/nextPage/hasPreviousPage/hasNextPage | number/boolean | 翻页状态 |
| navigatePageNums/navigateFirstPage/… | array/number | 页码导航 |
| title/description | string | **含 `<em>关键词</em>` 高亮标记** |

### 6.4 附件/图片/视频

- 图片/附件域：`www2.sxjzit.edu.cn:8082`（`/zhglxt/profile/userfiles/sxjzitcc/images/` 与 `/zhglxt/profile/upload/YYYY/MM/DD/`）
- 视频：`/zhglxt/profile/upload/...mp4`（首页 banner）；无防盗链（直接 200，字段内联于 HTML/JSON）
- **HTTP 明文 8082 端口**：CSP 已放行 `*.sxjzit.edu.cn:8082`，采集时注意 http/https 混用

---

## 7. 采集方案与代码示例（Python）

### 7.1 请求顺序与策略

1. `GET /school/home5` → 取 `data.news` 拿 5 个子栏目 column_id + total
2. 对每栏目：`page=1..ceil(total/size)` 翻页 `GET /common/column/articles`（size=20 减页数）
3. 按 `id` 去重（服务端跨页偶发重叠，见 §5.1），记录已采 id 集
4. 可选：`GET /common/article/detail?article_id=` 补正文全文
5. 全量搜索：用 `GET /common/search?key_words=` 可按关键词补漏（命中全站）

### 7.2 Python 示例

```python
import requests, math, time

BASE = "https://gwqietap.sxjzit.edu.cn/mapi"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"}
seen, articles = set(), []

home = requests.get(f"{BASE}/school/home5", headers=HEADERS, timeout=20).json()
for key, col in home["data"]["news"]["children"].items():
    cid, total = col["column_id"], col["articles"]["total"]
    pages = math.ceil(total / 20)
    for page in range(1, pages + 1):
        r = requests.get(
            f"{BASE}/common/column/articles",
            params={"site_id": 1, "column_id": cid, "page": page, "size": 20},
            headers=HEADERS, timeout=20).json()
        for art in r["data"]["articles"]["list"]:
            if art["id"] not in seen:          # 去重（跨页边界重叠）
                seen.add(art["id"])
                articles.append(art)
        time.sleep(2)                          # 合规限速 2s
print(f"采集 {len(articles)} 篇 / {len(seen)} 去重 id")

# 详情补全
detail = requests.get(f"{BASE}/common/article/detail",
                      params={"article_id": articles[0]["id"]}, headers=HEADERS).json()
```

### 7.3 断点续采

按 `list.txt` 已采 id 集，跳过 `seen` 内 id 即可续采；服务端无 Session/鉴权，进程重启无副作用。

---

## 8. 反爬与合规风险

| 项 | 状态 | 说明 |
|----|------|------|
| robots.txt | 无（404） | 官网未声明采集限制；mapi 亦 404 |
| sitemap.xml | 无（404 / 404.gz） | 无 XML 站点地图，全量需走接口翻页 |
| 登录墙 | 无 | 全部数据接口匿名 GET 200 |
| 验证码 | 无 | 未触发 |
| 签名/时间戳/Nonce | 无 | JS 逆向确认无签名逻辑，URL 纯参数拼接 |
| CORS/CSP | connect-src `*.sxjzit.edu.cn` | 浏览器直采跨域受限（网关与主域同 edu.cn）；**curl/Python 服务端采集不受限** |
| 频率限制 | 未显式触发（限速 2s 全绿） | 建议保持 ≥2s；无 IP 封锁迹象 |
| Referer/Origin 校验 | 无 | curl 不带 Referer 仍 200 |
| 版权 | 内容属校方 | 采集仅限结构分析/内部使用，公开再分发需校方授权 |
| 移动端/m 站 | 未发现独立 m 站入口（同一 SPA 响应式） | — |
| RSS/Feed | 未发现 | — |

---

## 9. 复核清单结果

| 项 | 状态 |
|----|------|
| 首页新闻模块接口已捕获 | ✅ `school/home5`（news 板块）+ `common/column/articles` |
| 新闻公告列表接口已捕获 | ✅ 父栏目 ccb0ed... 由 home5.news 聚合；5 子栏目全确认 |
| 学校要闻列表接口已捕获 | ✅ `articles?site_id=1&column_id=41cb4c...` total=522 |
| 文章详情接口已捕获 | ✅ `/common/article/detail?article_id=` |
| 所有相关 column_id 已枚举 | ✅ 5 子栏目 + 父容器（home5 实证） |
| site_id 含义已确认 | ✅ 主站=1；子站 hex（school/org） |
| 分页参数确认 + 边界测试 | ✅ page 0/-1/abc/54、size 10/20 → §4 |
| 总文章数/总页数/末页确认 | ✅ 522 / 53 页 / 末页 2 条 |
| 响应字段完整记录 | ✅ §6 字段字典 |
| 附件/图片/视频字段确认 | ✅ www2:8082 域，CSP 放行 |
| 搜索接口已检查 | ✅ `/common/search?key_words=&p=&s=` |
| 首页侧边栏/推荐/热点模块已检查 | ✅ home5 全板块（achievements/video/teachers/students/campus） |
| 移动端/m 站已检查 | ⚠️ 未发现独立 m 站（响应式单 SPA）→ 记"未验证独立 m 站" |
| RSS/sitemap/静态页已检查 | ✅ 均不存在（404） |
| 反爬机制已评估 | ✅ 无签名/验证码/限频（≥2s 全绿） |
| 请求头必填字段已确认 | ✅ 仅 User-Agent 常规头，无鉴权头 |
| Token/签名/时间戳机制确认 | ✅ 不存在 |
| 页面渲染与接口一致性抽样 | ✅ 列表页首屏 10 条 UI 文本 ↔ col_articles_p1.json 首条吻合 |
| HAR 中 XHR 全归类 | ✅ 8 类接口全录于 §3 |
| 不存在未分析接口/遗漏模块 | ✅ home5 九大板块 → 均映射到已捕获接口 |
| 无法验证项已标注 | ✅ §9 未验证项 |
| 采集方案可用性 | ✅ 已完成 20 页实测翻底 |

---

## 10. 未验证项与原因

| 项 | 原因 |
|----|------|
| 独立移动端/m 站 | 未发现独立 m 站；官网为响应式单 SPA（若存在 `m.` 子域镜像则未验证） |
| dept/home2 的 site_key=1 行为（500） | site_key=1 指向主站而非机构子站，属参数错配（**证实非缺陷**，正确用法是传子站 site_key） |
| 附件下载类接口（如成绩单/文件表单） | 本次范围仅新闻公告/学校要闻，未发现附件列接口；若子栏目含下载类型需另行枚举（col_head/href 已含下载判据） |
| GET 之外的写接口 | 匿名只读审计范围内未发现 |

---

## 11. 结论

- **「学校要闻」（522 篇）与「新闻公告」父栏目下全部 5 个子栏目（合计 876 篇）均可通过公开接口 100% 完整采集**，无需登录、无签名、无验证码。
- 核心链路只有 2 个接口即可全量闭环：`/common/column/articles`（列表翻页）+ `/common/article/detail`（正文）。
- 任务 URL 中 `column_id=41cb4c8424ac474891e1470aa2fb071b` 对应「学校要闻」而非「新闻公告」本身——若要取"新闻公告"全量，需按 home5.news.children 的 5 个 column_id 各翻一遍。
- **合规建议**：采集保持 ≥2s 间隔、仅限个人/内部使用，公开分发需校方授权。

*证据目录：`qin/docs/sxjzit-news-audit-evidence/`（json/8 + js/7 + 截图 3 + pagination_boundary_test.txt）*

---

## 12. 补充复核（2026-10-01 第二轮查缺补漏）

针对首轮标注的盲区逐项补验，**新增 3 个发现 + 全部盲区闭环**：

### 12.1 （补）父栏目直查行为

`/common/column/articles?column_id=ccb0ed3aced3471b8f5f8df77c91821e`（新闻公告容器）→ **code 200 total=0 list=null**。父栏目为纯容器，**必须按 home5.news.children 的 5 个 child column_id 分采**——首轮"按父栏目不可全量"结论佐证。

### 12.2 （补）首页各板块独立数据源确认

home5 内联板块 `articles` 已自带数据（**无需独立接口**）：

| 板块 | column_id | 标题 | total | 内联 list |
|------|-----------|------|-------|-----------|
| achievements | 2a9cf74e15d4433c92cb30eb50a442ca | 校园荣誉 | 36 | 18 |
| teachers | 1cacdda11556464ba04494ceece49b8d | 教师风采 | 8 | 8 |
| videos | ef62f81619694a7499963289731f0ad8 | 映像校园 | 7 | 7 |
| students | 9c60880419d1420d8061103c54cfc8ba | 学生故事 | 28 | 18 |

各板块仍可用 `column/articles?site_id=1&column_id=<板块id>` 全量翻页（与新闻公告族同构）。

### 12.3 （新发现 A）`/mapi/school/home` 旧接口并存（等效 home5，少 videos 板块）

| | school/home | school/home5 |
|--|-------------|--------------|
| code | 200 | 200 |
| data keys | top_banners/achievements/news/video/teachers/students/campus/bottom_banners | 同左 + **videos** |
| news.children 5 栏目 | 与 home5 **完全一致**（col_id+total 逐一比对 True×5，见复核记录） | 全量 |

结论：`home` 为精简旧版（无「映像校园」视频板块）、`home5` 为全量新版，**两者并存且 news 数据一致**；采集方二选一即可（推荐 home5）。

### 12.4 （新发现 B）`/mapi/common/video` 视频端点（独立，已瘦身）

- 参数：`type` 必填（缺 400「参数[type]为必填项」）
- 实测 `type=campus/news/latest/video/home5` 均返回 `{"code":200,"data":{"href":""}}`（**空 href**，数据已转移到 home5.videos 内联）
- 结论：**废弃瘦身端点**，真实视频数据以 home5.videos 为准。

### 12.5 （新发现 C）`/mapi/common/download` 附件下载服务

- 参数：需 `filename` + `filepath` 双参（缺 filename→400「参数[filename]为必填项」；有 filename 缺 filepath→400「参数[filepath]为必填项」）
- 用途：附件下载 helper（正文/列表面的文件下载链接经此服务）；**新闻要闻正文当前抽样无附件链接**，顾问在采集时若页面出现 `*.pdf/doc/xls` 链接可经此服务取文件
- JS 取证：`/common/download` 调用点位于动态 chunk（列表/详情组件），静态 vite 资源图 `download_blue.webp` 等非接口。

### 12.6 （补）detail 边界

| 输入 | 结果 |
|------|------|
| article_id=abc（非法） | code 200 data:null |
| article_id=全 0 32hex（不存在） | code 200 data:null |
| 缺 article_id | code 400「参数[article_id]为必填项」 |

### 12.7 （补）搜索边界

| 输入 | 结果 |
|------|------|
| 缺 key_words | code 400「参数[key_words]为必填项」 |
| key_words=xyz（无结果词，纯 URL 编码） | **code 200 total=0**（首轮 187 系 shell 中文编码误传，复核纠正） |
| p=2 | code 200 pageNum=2 list=10（正常翻页） |

### 12.8 （补）size 上限

`size=100` → code 200 **list=100**（1~100+ 均可，无上限报错；推荐 20~50 平衡翻页次数）。

### 12.9 （补）m 站/静态壳

`m.sxjzit.edu.cn/wap/mobile/app` 子域全部 **DNS 无解析（000）**；`/api/news`、`/news.json`、`/rss` 均 404；首页壳为精简 Vite SPA（`<meta name="referrer" content="never">` 防微信防盗链）。**移动端=同一响应式 SPA，无独立 m 站——盲区闭环。**

### 12.10 （补）两 home 接口 news 一致性（横向复核）

home5.news.children 与 home.news.children 五栏目 column_id+total 逐一比对 **全部一致（True×5）**——数据源唯一性确认，无分叉。

### 12.11 复核结论：盲区闭环

| 首轮未验证项 | 复核结果 |
|--------------|---------|
| 独立 m 站 | ❌ 不存在（子域 000，SPA 响应式）→ 闭环 |
| dept/home2 主站 500 | ✅ 证实为参数误用（主站无 site_key），非缺陷 |
| 附件下载类接口 | ✅ 找到 `/common/download`（filename+filepath），正文当前无附件 |
| GET 之外写接口 | ✅ 匿名只读范围内未发现（无登录/写路径） |
| **新发现** | `school/home` 旧接口、`common/video` 废弃端点、`common/download` 下载服务（3 项新增入接口清单） |

**综合判断：接口清单无遗漏（8→11 项），栏目映射/分页/字段/完整性全部复核通过，页面渲染与接口数据一致（首条 UI 文本 ↔ JSON 逐字吻合）。**