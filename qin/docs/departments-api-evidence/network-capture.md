# AgentA 外部浏览器实机取证 - 山西晋中理工学院
开始时间: 2026-09-30 10:57:58


## 步骤 1：jwc 教务处子栏目穷举（真机点击）
site_id(jwc) = 222fa53591a3494e9c860390039b0844

| 子栏目 | 路由 &page=xxx | 实际请求 URL（含 column_id） |
|---|---|---|
| 首页 | page=home | dept/home2?site_key=jwc + school/events?year=2026&month=9&site_id=222fa53591a3494e9c860390039b0844（首页各板块数据来自 home2 聚合，无独立 column 请求） |
| 部门概况 | page=introduction | common/article/detail?article_id=97a6d8d724984e28b16924feb1f56e10（部门概况是一篇文章详情！） |
| 教务动态 | page=news | common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=1e5c01825020441191c57a1d2ee4a06d&page=1&size=8 |
| 通知公告 | page=notice | common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=94511e8fcb8c49b4a1ade5d2fda8a03b&page=1&size=8（共 48 页） |
| 规章制度 | page=regulations | common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=4f0ffb3878b64411ba559295b411cf1c&page=1&size=8 |
| 资料下载 | page=download | common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=8f56d6aedede4101b2aa9e8f81cc6ce6&page=1&size=8 |
| 联系我们 | page=contact-us | 无新增 XHR（数据来自 dept/home2 聚合或静态渲染） |

原始网络输出（节选，一次点击触发两条相同请求，疑为 Vue 组件重复挂载）：
- GET https://gwqietap.sxjzit.edu.cn/mapi/dept/home2?site_key=jwc (xhr) → 200
- GET https://gwqietap.sxjzit.edu.cn/mapi/school/events?year=2026&month=9&site_id=222fa53591a3494e9c860390039b0844 (xhr) → 200
- GET https://gwqietap.sxjzit.edu.cn/mapi/common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=94511e8fcb8c49b4a1ade5d2fda8a03b&page=1&size=8 (xhr) → 200
- GET https://gwqietap.sxjzit.edu.cn/mapi/common/article/detail?article_id=97a6d8d724984e28b16924feb1f56e10 (xhr) → 200（部门概况页）

## 步骤 2：通知公告翻到底（jwc）
- 点击分页 listitem「第 48 页」（e794）→ 请求：GET https://gwqietap.sxjzit.edu.cn/mapi/common/column/articles?site_id=222fa53591a3494e9c860390039b0844&column_id=94511e8fcb8c49b4a1ade5d2fda8a03b&page=48&size=8 → 200
- 末页列表非空，共 2 条（最早记录）：「关于进行2020-2021学年第2学期期初教学检查的通知」「关于2021年英语专业四、八级考试的报名通知」
- 结论：翻页参数即 page=<N>&size=8，URL 中 hash 路由不变（仍为 page=notice），纯 XHR 翻页。
- 注意：同 URL 重新 navigate 时浏览器 bfcache 恢复 DOM，列表仍停留在第 48 页（Vue hash 路由对相同 hash 不触发重载）。

## 步骤 3：文章详情（jwc 通知公告）
- 点击标题「关于开展2020-2021学年第2学期期初教学检查的通知」→ 请求 GET https://gwqietap.sxjzit.edu.cn/mapi/common/article/detail?article_id=2305 → 200
- 点击标题「关于开展2026-2027学年第一学期新生开课课堂专项督导的通知」→ 请求 GET https://gwqietap.sxjzit.edu.cn/mapi/common/article/detail?article_id=046e6ed45ce64980a67f471b8efc157b → 200
- 详情页路由形状：`https://www.sxjzit.edu.cn/#/list/article?id=<article_id>`
  - article_id 既可能是纯数字（旧文章如 2305），也可能是 32 位十六进制字符串（新文章如 046e6ed45ce64980a67f471b8efc157b）→ 参数必须按字符串透传，勿做数字强转
  - 详情页额外请求：GET https://gwqietap.sxjzit.edu.cn/mapi/school/home5 → 200
- 详情页 DOM：`.base-article` / `.base-article-content`（富文本 p/span，带 inline style）
- 正文图片 URL 形态（取自 jwc 部门概况正文插图）：
  `https://www2.sxjzit.edu.cn:8082/zhglxt/profile/upload/2025/03/30/图层 733_20250330201837A001.webp`
  → 即：图片 CDN/资源域 = www2.sxjzit.edu.cn:8082，路径 /zhglxt/profile/upload/<年>/<月>/<日>/<原名>_<时间戳>A00N.<webp|png|jpg>（注意可能含中文与空格）
- 部门概况（page=introduction）正文请求：GET .../common/article/detail?article_id=97a6d8d724984e28b16924feb1f56e10 → 200，同样用 UUID 型 article_id

## 步骤 4：站内搜索（真机）
- 顶部搜索图标（img nav-search-img）点击后弹出搜索浮层（textbox + 提示「搜索课程、活动或主要关键词」），但直接在该浮层输入「考试」并回车 **不触发请求**（浮层内无提交按钮、无联想请求）→ 该浮层疑似仅装饰/未绑定。
- 等效完成方式（路由直访）：进入 `https://www.sxjzit.edu.cn/#/list/search`（搜索结果页自带输入框 textbox「搜索您想要的内容」），在该页输入「考试」并回车 →
  实际请求：`GET https://gwqietap.sxjzit.edu.cn/mapi/common/search?key_words=%E8%80%83%E8%AF%95&p=1&s=10` → 200
- 搜索页 URL 形状：`https://www.sxjzit.edu.cn/#/list/search?key_words=<urlencode(关键词)>`
- 参数名结论：**key_words**（关键词）/ **p**（页码，默认 1）/ **s**（每页条数，默认 10）；注意不是 keyword/q/page
- 结果页渲染：标题 + 摘要列表（摘要中命中词以 <em> 高亮）
- 附注：带 `?key_words=考试` 直接访问 #/list/search 时**不会自动发请求**（仅显示「搜索历史」），必须在该页输入端提交才触发。

## 步骤 5：校园日历（jwc 部门页内板块）
- 【结论】**不存在独立的校园日历页面**。校园日历是「部门页 #/departments/page?site_key=xxx」**首页内的一个板块**（数据由 /dept/home2 返回的 calendar.componentType 决定），无自己的一级路由。
- 真机验证（路由直访 404）：
  - `https://www.sxjzit.edu.cn/#/departments/calendar` → 页面显示「哎呀，打不开页面了呢！／返回首页」（NotFound）
  - `https://www.sxjzit.edu.cn/#/campus/calendar` → 同样 NotFound
  - `https://www.sxjzit.edu.cn/#/departments/page?site_key=jwc&page=calendar` → 路由可加载但无日历内容（tables=0，仅渲染部门头/菜单），说明 page=calendar **不是**有效子栏目名
- 日历板块入口：page=home 内「校园日历 CALENDAR」标题右侧有 `more-arrow`（更多）与 `campus_calendar_download`（下载图标）
  - 点击「更多」→ URL 不变，**不导航**，仅重新触发一次 `GET /mapi/school/events?year=2026&month=9&site_id=222fa53591a3494e9c860390039b0844`（相当于刷新当月）
  - 点击「下载」图标 → 无任何新 XHR（客户端本地导出，无后端接口）
- 日历真实数据请求（真机确认）：
  `GET https://gwqietap.sxjzit.edu.cn/mapi/school/events?year=2026&month=9&site_id=222fa53591a3494e9c860390039b0844` → 200
  响应：`{"code":200,"message":"success","data":{"rest_work":{"rest":[],"work":[]},"schedule":[]},...}`
  另一验证：`?year=2026&month=10&site_id=222f...` → 同样 200（月份为 1-based；当日 2026-09-30 对应 month=9）
- 板块内另有 select-arrow ×2（切月），切换会再次调用同一 /school/events 接口。

## 步骤 6：学院页抽查（sxy 商学院）
- 路由：`https://www.sxjzit.edu.cn/#/college?site_key=sxy` → 自动补为 `#/college?site_key=sxy&page=home`
- 学院页首屏请求（真机）：
  - `GET https://gwqietap.sxjzit.edu.cn/mapi/college/home?site_key=sxy` → 200  **（注意：学院页用 /college/home，不是部门页的 /dept/home2）**
  - 另有全局：`GET /mapi/dept/home2`（无参）、`GET /mapi/school/org`
- 学院页子栏目菜单（9 项）：首页 / 学院概况 / 党群工作 / 最新动态 / 通知公告 / 学院新闻 / 专题中心 / 师生风采 / 联系我们
- 真机点击子栏目：
  | 子栏目 | 路由 | 请求 |
  |---|---|---|
  | 通知公告 | page=notification-announcement | `common/column/articles?site_id=c85524251e1b4ca19d7f4c7b0de482bb&column_id=817cb932097911f08df500163e031f40&page=1&size=8` |
  | 学院新闻 | page=news | `common/column/articles?site_id=c85524251e1b4ca19d7f4c7b0de482bb&column_id=817dfdcb097911f08df500163e031f40&page=1&size=8` |
- site_id(sxy) = `c85524251e1b4ca19d7f4c7b0de482bb`
- **与部门页的同构/差异**：
  - 同构：列表接口与参数完全一致（common/column/articles?site_id&column_id&page&size），子栏目路由形式一致（&page=xxx），分页/详情路由共用（#/list/article?id=…）。
  - 差异 1：首页聚合接口不同 —— 部门=`dept/home2?site_key=`，学院=`college/home?site_key=`。
  - 差异 2：学院首页板块更多（学院新闻置顶大图、学院概况 tab+轮播「学院发展/专业介绍」、最新动态 4 个 tab、专题中心 4 个 tab），部门首页板块更少。
  - 差异 3：学院页子栏目更多（9 项），且命名不同（notification-announcement、专题中心、师生风采）。
  - 差异 4：学院页存在 carousel 轮播（college-tab-carousel-mask-card-img ×N），部门页未发现轮播。

## 步骤 7：机构设置页 #/departments/list 特殊板块
- 真机 DOM 检查：`carouselEls=0`，`main h2 = 39 个`（5 个分组标题 + 34 个机构），正文关键词「置顶/推荐/轮播/热点」**均不存在**。
- 图片仅：departments-banner-img、departments-banner-mask、departments-logo-img ×4（分组图标）。
- 请求：仅 `GET /mapi/dept/home2`（无 site_key）与 `GET /mapi/school/org`。
- **结论：机构设置页无置顶/推荐/轮播板块**，纯静态分组卡片列表。
- 页面 5 组 34 个机构（实测）：党委机构(8)、群团机构(5)、行政机构(9)、教学机构(10)、知识拓展·技能转换(2)。
