# Agent C 摸查报告：单文章型机构详情接口 + 资源拼接规则 + oneTwoArticles + school/org 字段

API 基址：`https://gwqietap.sxjzit.edu.cn/mapi`
探测时间：2026-09-30 ｜ 原始 JSON：`/tmp/dept_api/raw/`

---

## ① 文章详情接口契约 `/common/article/detail`

### 调用点（bundle 实证）
`chunks/index-Bg2ZeZgM.js` 中 axios 封装：`d=e=>t.get("/common/article/detail",e)`；
真实调用方 `chunks/ArticleContainer-CwpPJKmv.js`：

```js
i = t => { A({ params:{ article_id: t } }).then(a=>{ a.data.code===200 && (r.value=a.data.data) }) }
```

→ **参数名确认为 `article_id`**（`params` 即 query string）。

### 参数验证结果

| 请求 | HTTP | body.code | message |
|---|---|---|---|
| `?article_id=697c6771...` | 200 | 200 | success |
| `?id=697c6771...` | 200 | **400** | `参数[article_id]为必填项` |
| 无参数 | 200 | **400** | `参数[article_id]为必填项` |

> 注意：**HTTP 状态恒为 200，业务状态在 body 的 `code`**。`id=` 不生效，只认 `article_id`。
> 旧数据存在数字型 article_id（如 `?article_id=162`），同样 200 返回，说明 id 是字符串透传、不限于 32 位 uuid。
> 无 token / 无鉴权头要求（axios 只配了 baseURL+timeout，request 拦截器为空）。

### 响应结构

```
{ code, message, data, timestamp, executeTime }
```

`data` 全部字段（**仅 5 个**，无作者/来源/发布时间/附件数组字段）：

| 字段 | 类型 | 示例 | 说明 |
|---|---|---|---|
| `title` | string | `党委组织部` | 文章标题（纯文本） |
| `update_time` | string | `2025-04-24T00:00:00` | 时间，ISO 无时区；**前端即用它当“发布时间”** |
| `content` | string(HTML) | `<p style="text-indent: 24pt; ..."><img src="...">...` | 正文 HTML 片段（内联 style、img、a，无外层 html/body） |
| `href` | string | `""` | 外链跳转地址；为空即普通文章，非空时前端 `window.open(href)` |
| `image_url` | string | `https://www2.sxjzit.edu.cn:8082/zhglxt/profile/upload/2025/04/24/zzb_20250424112131A957.webp` | 封面图绝对 URL |

前端渲染（`chunks/BaseArticle-BPh4Iu2U.js`）：
- `h2.title` ← `data.title`
- 时间 ← `<span>${getHandleTime(data.update_time,"/").date} 发布</span>` → 显示为 `2025/04/24 发布`
- 正文 ← `<article class="base-article-content" innerHTML={data.content}>`

**无 author / source / publish_time / images / attachments 等字段**；“来源/作者”信息如存在只会出现在 `content` 正文里。

---

## ② 图片/附件资源地址拼接规则

### 结论：正文图片全部是绝对 URL，无需拼前缀；但存在 http/https 混用，需要升级为 https

抽取 10 篇单文章机构正文中全部 `<img src>`：

- 命中 10 条，**全部为绝对 URL，无一条相对路径**；
- host 唯一：`www2.sxjzit.edu.cn:8082`（无多域名 / 无 CDN）；
- 路径前缀两种：
  - 正文图：`/zhglxt/profile/cms/upload/YYYY/MM/DD/<名>_<时间戳>A<n>.webp|jpg`
  - 封面图 `image_url`：`/zhglxt/profile/upload/YYYY/MM/DD/...` 或 `/zhglxt/profile/userfiles/system/images/...`
  - 占位图：`https://www2.sxjzit.edu.cn:8082/images/no_picture.webp`（列表无图时）
- **协议混用**：10 条正文图里 9 条是 `http://`、1 条是 `https://`；`image_url` 字段 10/10 都是 `https://`。

### 可访问性验证（真实图片抽样，含中文文件名）

| URL（原样） | 结果 |
|---|---|
| `http://www2.sxjzit.edu.cn:8082/zhglxt/profile/cms/upload/2025/04/24/zzb_20250424112430A958.webp` | **302** text/html，`Location: https://www2.sxjzit.edu.cn/zhglxt/profile/cms/upload/.../zzb_...A958.webp`（**跳转后去掉了 :8082 端口**） |
| `https://www2.sxjzit.edu.cn:8082/zhglxt/profile/cms/upload/2025/04/24/zzb_20250424112430A958.webp` | **200 image/webp**（67.8 KB） |
| `https://www2.sxjzit.edu.cn/zhglxt/profile/cms/upload/2025/04/24/zzb_...A958.webp`（即 302 目标，无端口） | **200 image/webp** |
| `http://.../profile/upload/2025/04/24/gh_20250424113146A968.webp`（封面图） | 302 → https |
| 10 篇正文图 / 10 个 `image_url` 逐个用 https 复测 | **全部 200 image/webp**（含中文名 `思想政治教育工作部党支部_20260825161710A887.webp`） |

- 加 `-H "Referer: https://www.sxjzit.edu.cn/"` 与不加**结果一致** → **不需要 Referer，无防盗链 403**。
- 结论：消费方只需把 `http://` 替换为 `https://`（端口 `:8082` 保留或去掉均可访问），无需 Referer、无需拼接任何前缀。
- SPA 自身在 `BaseArticle` 里**不做任何 URL 重写**（bundle 内无 `replace("http://"…)` 逻辑），直接 innerHTML 注入，依赖浏览器跟随 302。

### 附件规则

- **详情接口没有独立附件字段/数组**，附件以正文内联 `<a href>` 形式出现（前端靠后缀正则 `\.(pdf|doc|docx|xls|xlsx|ppt|pptx|zip|rar|txt)$` 嗅探并接管下载）。
- 实例：`a94feef0…` 正文外链 `https://www.kdocs.cn/l/cuzyYzCoXEd0`；`缓考申请表` 正文 `&lt;a href=" https://www.kdocs.cn/l/cs9qWedsSF0X" target="_blank"&gt;`。
- **坑 1**：该 href 值带**前导空格**（`" https://…"`），消费方必须 `trim()`，否则 URL 非法。
- **坑 2**：真实文章正文里发现残留的本地绝对路径 `<img src="file:///C:\Users\XX\AppData\Local\Temp\ksohtml28180\wps1.png">`（WPS 粘贴残留），消费方需过滤 `file://` / 非 http(s) 的 src。
- 附件多为第三方金山文档（kdocs.cn）外链，不落在 `www2.sxjzit.edu.cn` 上。

---

## ③ 10 个「单文章型」机构详情验证表

请求：`GET /common/article/detail?article_id=<id>`；全部 HTTP 200 / body.code 200 / message=success。

| article_id(前8) | 机构 | title | update_time | 正文长度 | HTML | 正文图 https 复测 |
|---|---|---|---|---|---|---|
| 697c6771 | 党委组织部 | 党委组织部 | 2025-04-24T00:00:00 | 1738 | 是 | 200 image/webp |
| 27a40b0a | 党委宣传部 | 党委宣传部 | 2025-04-24T00:00:00 | 1691 | 是 | 200 image/webp |
| 20768d27 | 党委统战部 | 党委统战部 | 2025-04-24T00:00:00 | 1740 | 是 | 200 image/webp |
| e8c51530 | 纪检监察办公室 | 纪检监察办公室 | 2025-04-24T00:00:00 | 1864 | 是 | 200 image/webp |
| c94f0d88 | 党委教师工作部 | 党委教师工作部 | 2025-04-24T00:00:00 | 1245 | 是 | 200 image/webp |
| 0bde63d0 | 思想政治教育工作部党支部 | 思想政治教育工作部党支部 | **2026-08-25**T00:00:00 | 1745 | 是 | 200 image/webp |
| 0fc43da1 | 工会 | 工会 | 2025-04-24T00:00:00 | 2652 | 是 | 200 image/webp |
| 5efa8bd8 | 妇联 | 妇联 | 2025-04-24T00:00:00 | 1670 | 是 | 200 image/webp |
| 743ed5d2 | 科协 | 科协 | 2025-04-24T00:00:00 | 2292 | 是 | 200 image/webp |
| 56ad9602 | 关心下一代工作委员会 | 关心下一代工作委员会 | 2025-04-24T00:00:00 | 1810 | 是 | 200 image/webp |

- 10/10 全部成功，`title` 与机构名一致；正文均为「一张机构职责图片 + 简短说明」型 HTML，长度 1.2–2.7 KB。
- 9 篇 `update_time` 为 2025-04-24（同批录入），仅思政党支部为 2026-08-25。
- `href` 10/10 为空；`image_url` 10/10 为 https 封面图，均可访问。
- 原始文件：`raw/detail_697c6771.json` … `raw/detail_56ad9602.json`。

---

## ④ 一二级栏目混合文章接口 `/common/column/oneTwoArticles`

### 调用点（bundle 实证）
`chunks/DepartmentsPage-CeXqjfye.js`：

```js
Xt({ params:{ site_id: b, column_id: u } }).then(i=>{ i.data.code===200 && (s.value=i.data.data) })
// b = e.value.site_id, u = e.value.id（栏目 id）
```

### 参数验证结果

| 请求 | HTTP | body.code | 结果 |
|---|---|---|---|
| `?site_id=222fa5…&column_id=66e9645f4eee4f2ead37a8fe1223d7fb`（**站点根栏目**） | 200 | **200** | success，返回 8 个子栏目 + 各自文章 |
| `?site_id=222fa5…&column_id=94511e8f…`（通知公告，一级子栏目） | 200 | **500** | `系统内部出现错误` |
| `?site_id=222fa5…&column_id=e754bb10…`（首页，一级子栏目） | 200 | **500** | 同上 |
| 不传 column_id / 不传任何参 | 200 | 500 | 同上 |

> **关键坑**：`column_id` 必须传**该站点的顶层根栏目 id**（即 `parent_id` 指向站点外的那一个），传一级子栏目 id 会 500。
> 教务处(site_id=222fa535…jwc) 根栏目 id = `66e9645f4eee4f2ead37a8fe1223d7fb`（其 nav 下所有栏目 parent_id 都是它）。

### 响应结构

```
data = { column_id, title_cn:"栏目", title_en:"", is_out:1, href:"", site_id,
         children:{ total:8, list:[ column, ... ] } }
```

每个 `column`：
| 字段 | 说明 |
|---|---|
| `id` | 栏目 id |
| `title_cn` / `title_en` | 栏目名 / 英文 slug |
| `is_out` | 0/1，是否外链栏目 |
| `href` | SPA 路由串，如 `home` / `introduction` / `?toIndex:home=news` / `contact-us` / `/` |
| `image_url` | 栏目图（多为 `images/no_picture.webp`） |
| `site_id` | 站点 id |
| `componentType` | 板块类型：`""`/`content`/`news`/`notice`/`notice-small`/`download`/`opinion`/`calendar` |
| `articles` | `{ total, list }`，list 可能为 `null`（total=0，如“联系我们”“校园日历”） |

`articles.list[]` 文章项字段：
| 字段 | 示例 |
|---|---|
| `id` | `01223003117b4163981d3123a110a678`（**即 article_id，可直接送详情接口**） |
| `title` | 标题纯文本 |
| `description` | 纯文本摘要（可空串；即列表页摘要/导语） |
| `image_url` | 封面图，无图时为 `images/no_picture.webp` |
| `create_time` | `2026-08-25 16:27:23`（有**空格分隔的本地时间**，部分旧数据为空串） |
| `update_time` | `2026-08-25T00:00:00`（ISO） |
| `tag` | 关键词，**空格分隔**，可空 |
| `sort` | 数字，越大越靠前（旧数据 10000） |

- 每个栏目返回固定约 10 条（jwc 教务动态 total=245 只给 10 条），**与 `/common/column/articles` 分页接口互补**：板块预览用 oneTwoArticles，翻页/全量用 column/articles。
- 原始文件：`raw/oneTwo_66e9645f4eee4f2ead37a8fe1223d7fb.json`（成功）、`raw/oneTwo_jwc.json` / `raw/oneTwo_jwc_nocol.json` / `raw/oneTwo_noparam.json`（500 反例）。

---

## ⑤ `/school/org` 字段表与层级结构

原始：`/tmp/dept_api/school_org.json`（`{"code":200,"message":"ok","data":…}`）

### 层级：树为 **3 层**，根节点不带 id

```
data(根=机构设置/"Schools & Departments"，无 id 字段，子节点的 parent_id=100 反推根 id=100)
 ├─ 116 党委机构        party-committee-organs
 ├─ 117 群团机构        group-organization
 ├─ 118 行政机构        administrative-agency
 ├─ 119 教学机构        teaching-institution
 └─ 120 知识拓展·技能转换 educational-support-institution
        └─ 叶子=具体机构（121…157，children 恒为 []）
```

- 第 1 层：`data` 自身（根，`title_cn="机构设置"`，**无 id**）
- 第 2 层：5 个分组（id 116–120，`parent_id=100`）
- 第 3 层：34 个机构叶子（id 121–157，`parent_id=分组 id`，`children=[]`）→ 与 `leaves.json` 的 34 条一致
- 共 40 个节点（含根与 5 分组）；**只有 3 层，无更深嵌套**。

### 字段含义

| 字段 | 类型 | 含义 / 用途 |
|---|---|---|
| `id` | int | 机构/分组数字 id（116–157）；仅用于树内定位，**不是**接口参数 |
| `parent_id` | int | 父节点 id；分组=100（根），机构=所属分组 id |
| `title_cn` | string | 中文名 |
| `title_en` | string | 英文 slug；**大量为占位符 `"temp_name"`**（未维护），少数是真 slug |
| `site_key` | string\|null | 部门站点 key，用于 `/dept/home2?site_key=`、`/college/home?site_key=`；**单文章型机构为 `null` 或 `""`** |
| `site_id` | string\|null | CMS 站点 id（32 位 hex），用于 `/common/column/*`、`/school/events` 等；单文章型机构为 `null` |
| `article_id` | string\|null | 单文章型机构的唯一文章 id，送 `/common/article/detail?article_id=`；正常站点型机构为 `null` |
| `path` | string\|null | 前端路由覆盖，如 `/college?site_key=xcdsj`、`/departments/page?site_key=mkszy&page=home`；**空串 `""` 表示走默认路由**，`null` 多见于未配置 |
| `children` | array | 子节点数组；叶子为 `[]` |

### 机构三态（决定前端如何路由）

1. **站点型**（`site_key` 非空 + `site_id` 非空、`article_id=null`）：如教务处 `site_key=jwc`、`site_id=222fa5…` → 打开部门主页，走 `dept/home2` 等。
2. **单文章型**（`site_key` 空 + `article_id` 非空、`site_id=null`）：**10 个**，直接渲染一篇文章详情。
   - `site_key=null` 的 8 个：党委组织部122、党委宣传部142、党委统战部143、纪检监察办公室144、党委教师工作部145、妇联139、科协140、关心下一代工作委员会141
   - `site_key=""`（空串，注意与 null 区分）的 2 个：思想政治教育工作部党支部148、工会138
3. **双配型 / 未配置**：财资处130 同时有 `site_id` 与 `article_id`（既可站点又可单文章）；校长办公室124 仅 `site_key="dzbgs"`（与党委办公室121 重复）、其余全 null；学生工作处133、保卫处136 仅 `site_key`、无 `site_id`。

> 备注：`leaves.json` 由 school_org.json 的叶子派生，两者数据一致；`leaves.json` 用 `en` 字段记录英文 slug，`null`/`""` 语义与原 JSON 相同。

---

## 原始文件索引（/tmp/dept_api/raw/）

- `detail_<前8>.json` × 10：单文章机构详情原文
- `detail_art_<前8>.json`：普通列表文章详情（`01223003` 含 file:// 残留、`a94feef0` 含 kdocs 外链、`046e6ed4` 长正文、`162` 数字 id 旧数据、`71e607e5`/`b8821e95` 附件型）
- `probe_id.json`：`id=` 参数无效证据（code 400）
- `oneTwo_66e9645f….json`：oneTwoArticles 成功样例；`oneTwo_jwc.json`/`oneTwo_jwc_nocol.json`/`oneTwo_noparam.json`：500 反例
- `dept_home2_jwc.json`：教务处 nav 栏目树（用于取根栏目 id）
- `img_check.txt`：10 篇正文图 https 复测日志
