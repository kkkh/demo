# 山西晋中理工学院官网 · 机构相关「其余端点」契约摸查（子代理 D）

- API 基址：`https://gwqietap.sxjzit.edu.cn/mapi`（axios baseURL，见 `chunks/index-Bg2ZeZgM.js`；timeout 5s）
- 官网 SPA：`https://www.sxjzit.edu.cn/`（hash 路由）
- 结论前置：**全部端点均可无请求头直接 curl**（无需 Referer / UA）。唯一注意点：POST 需 `Content-Type: application/json`。
- 服务端错误约定：**HTTP 状态恒为 200**，业务错误写在 body 的 `code` 字段（400=缺参数，500=内部错误/数据不存在）；仅「路径不存在」才返回 HTTP 404，方法不匹配返回 405。
- 原始 JSON 全部保存在 `/tmp/dept_api/raw/ep_*.json`、`rob_*.json`。
- 端点定义出处：`chunks/index-Bg2ZeZgM.js` 的 `export{p as a,d as b,r as c,f as d,s as e,g as f,h as g,a as h,c as i,b as j,j as k,D as l,m,l as n,u as o,S as p,q,w as r,i as s}`（全部 API 包装函数集中在这一个 chunk）。

---

## ① 端点契约总表

| # | 方法 | 路径 | 参数（名:类型/必填/规则） | 关键响应字段 | HTTP | 样例（裁剪） | raw |
|---|------|------|--------------------------|--------------|------|--------------|-----|
| 1 | GET | `/school/home5` | 无参 | `data.{top_banners[],news,achievements,students,teachers,campus,videos,...}` | 200 | `{"code":200,"data":{"top_banners":[{"title_cn":"热烈欢迎2026级新同学","videoSrc":"...mp4"}]}}` | `ep_school_home5.json` |
| 2 | GET | `/school/intro` | 无参 | `data.<key>.{title_cn,title_en,statistics{dynamicDigit{total,list[]}}}` | 200 | `{"data":{"school-introduction":{"title_cn":"学校简介","statistics":{"dynamicDigit":{"total":4,"list":[{"text":"学校现拥有44个本科专业","endNumber":"44"}]}}}}}` | `ep_school_intro.json` |
| 3 | GET | `/school/cooperate` | 无参 | `data.{column_id,title_cn,title_en,href,site_id,data[{id,title_cn,title_en,is_out,href,image_url}]}` | 200 | `{"data":{"column_id":"e302af2c...","title_cn":"合作交流","data":[{"title_cn":"国际交流","href":"/collaboration?name=exchange"}]}}` | `ep_school_cooperate.json` |
| 4 | GET | `/school/msg` | 无参（页面直接空参调用） | `data.data.message_list.data{total,list[{id,title,show_title,message_time}]}` | 200 | `{"data":{"title_en":"voices+opinion","data":{"message_list":{"data":{"total":12,"list":[{"id":179}]}}}}}` | `ep_school_msg.json` |
| 5 | GET | `/dept/home2` | `site_key:String/必填` | `data.{top_banners,nav[{column_id,parent_id,site_id,title_cn,title_en,path,componentType,children[],data{}}]}` | 200 | `?site_key=jwc → 200, 35KB`；缺参 → `{"code":400,"message":"参数[site_key]为必填项"}` | `ep_dept_home2_jwc.json` |
| 6 | GET | `/dept/home` | `site_key:String/必填` | `data.{nav[]...}`（旧版部门首页） | 200 | `?site_key=jwc → 200, 33KB` | `ep_dept_home_jwc.json` |
| 7 | GET | `/college/home` | `site_key:String/必填` | `data.{site_id,title_cn,title_en,domain,logo,description,nav[]}` | 200 | `?site_key=xcdsj → 200`；`?site_key=sxy → 200`；**`?site_key=mkszy → code 500`（反直觉，见注）** | `ep_college_home_xcdsj.json` |
| 8 | GET | `/common/column/head` | 无参 | `data.{site{site_id,title_cn,title_en,domain,logo,description,keywords},menus[]}` | 200 | `{"code":200,"message":"success","data":{"site":{"site_id":"1","title_cn":"山西晋中理工学院官网"}}}` | `ep_column_head.json` |
| 9 | GET | `/common/foot` | 无参 | `data.{site{},邮箱/联系方式}` | 200 | 同上结构（页脚） | `ep_foot.json` |
| 10 | GET | `/common/article/detail` | `article_id:String/必填` | `data.{title,update_time,content(HTML)}` | 200 | 缺参 → `{"code":400,"message":"参数[article_id]为必填项"}` | `ep_article_detail.json` |
| 11 | GET | `/common/msg/detail` | `site_id:String/必填`、`msg_id:Int/必填` | `data.{show_title,content,is_show_content,message_time,is_replied,reply_content}` | 200 | `?site_id=1&msg_id=179 → {"data":{"show_title":"关于企业招聘的回复","is_show_content":"0"}}` | `ep_msg_detail.json` |
| 12 | GET | `/common/column/articles` | `site_id/必填`、`column_id/必填`、`page:Int(默认1,≥1)`、`size:Int(默认10,无上限)` | `data.{column_id,title_cn,title_en,href,articles{total,list[{id,title,description,image_url,update_time,tag,sort}]}}` | 200 | `?site_id=222f...&column_id=9451...&page=1&size=8 → total 378` | `ep_column_articles.json` |
| 13 | GET | `/school/events` | `year:Int`、`month:Int`、`site_id:String`（**均非强校验**，缺参也不报错） | `data.{rest_work{rest[],work[]},schedule[]}` | 200 | `?year=2026&month=9&site_id=222f... → {"data":{"rest_work":{"rest":[],"work":[]},"schedule":[]}}` | `ep_school_events.json` |
| 14 | GET | `/common/column/oneTwoArticles` | `site_id/必填`、`column_id/必填`（**必须是含子栏目的父栏目**） | `data.{column_id,title_cn,title_en,is_out,href,site_id,children{}}` | 200 | `column_id=817cc143...`（学院概况 tabs）→ 200；叶子栏目 → `code 500` | `ep_oneTwo_tabs.json` |
| 15 | GET | `/common/teacher/page` | `site_id/必填`、`is_leader:0/1/必填`、`page:Int`、`size:Int` | `data.{total,list[{id,name,position,title,text(HTML)}]}` | 200 | `site_id=xcdsj → total 27`；`mkszy&is_leader=0 → 23`；`is_leader=1 → 5`；缺 `is_leader` → `参数[is_leader]为必填项` | `ep_teacher_xcdsj.json` / `ep_teacher_mkszy_leader.json` |
| 16 | GET | `/common/search` | `key_words:String/必填`、`p:Int(页码,默认1)`、`s:Int(页大小,默认10)` | `data.{total,list[{id,title,description}]}`；命中词包 `<em>` 高亮 | 200 | `?key_words=考试&p=2&s=5 → total 49, 返回5条`；无参 → `{"code":400,"message":"参数[key_words]为必填项"}` | `ep_search_kaoshi.json` / `ep_search_ks_p2s5.json` |
| 17 | **POST** | `/common/recruit/query` | body(JSON)：`name:String`、`idcard:String`（**RSA 加密串**，非明文） | 命中：`data.{name,major}`；未命中：`data:null` | 200 | 假数据 → `{"code":500,"message":"系统内部出现错误"}`；GET → **405** | `ep_recruit_query.json` / `rob_recruit_get.json` |
| 18 | GET | `/common/short/create` | query：`url:String`（原始 URL，需 encodeURIComponent） | **`{code,msg,datas}`（键名与其它端点不同：`msg`/`datas`）** | 200 | `?url=https://www.sxjzit.edu.cn/ → {"code":200,"msg":"成功","datas":"https://www.sxjzit.edu.cn/s/Of"}` | `ep_short_create.json` |
| 19 | POST | `/common/msg/send` | body(JSON)：留言表单 `{site_id,name,phone,title,textarea,captcha}` | 成功 `code 200`（**未发起提交，仅静态契约**） | — | 由 `Opinion-CUoCMawn.js`/`College-B_stGeN4.js` 调用，字段见 `CustomOpinionForm-C5biDd2v.js` | — |
| 20 | GET | `/article/videos` | — | **该路径不是 API！** | **404** | `{"status":404,"error":"Not Found","path":"/mapi/article/videos"}`（仅为前端路由 `/article/videos`） | `ep_article_videos.json` |

> 注：`/college/home?site_key=mkszy` 返回 500，但 `xcdsj/sxy` 均正常（疑似该学院未配置 college 首页数据），而 `dept/home2?site_key=mkszy` 正常。**学院页调 /college/home，部门页调 /dept/home2，二者不可互换。**

---

## ② 健壮性边界探测结果

### `/common/column/articles`（jwc site_id/column_id）

| 探测 | 请求 | HTTP | body.code | 结果 | raw |
|------|------|------|-----------|------|-----|
| 不传 column_id | `?site_id=S&page=1&size=8` | 200 | **400** | `参数[column_id]为必填项` | `rob_articles_nocolumn.json` |
| 不传 site_id | `?column_id=C&page=1&size=8` | 200 | **400** | `参数[site_id]为必填项` | `rob_articles_nosite.json` |
| column_id 不存在 | `column_id=deadbeef…` | 200 | **500** | `系统内部出现错误` | `rob_articles_badcolumn.json` |
| page=0 | `?page=0&size=8` | 200 | **500** | 内部错误（**page 必须 ≥1**） | `rob_articles_page0.json` |
| page=1&size=1000 | `?page=1&size=1000` | 200 | 200 | **一次返回全部 378 条，服务端无上限截断** | `rob_articles_size1000.json` |
| page=99999 | `?page=99999&size=8` | 200 | 200 | **不报错**，`list:[]`（空数组），`total` 仍 378 | `rob_articles_page99999.json` |
| 不传 page | `?size=3` | 200 | 200 | page 默认 1 | — |
| 不传 size | `?page=1` | 200 | 200 | size 默认 10 | — |

### `/dept/home2` site_key 边界

| 探测 | HTTP | body.code | 结果 | raw |
|------|------|-----------|------|-----|
| `site_key=zzz_not_exist` | 200 | **500** | `系统内部出现错误`（不存在 → 500，非 400/空） | `rob_home2_badkey.json` |
| 不传 site_key | 200 | **400** | `参数[site_key]为必填项` | `rob_home2_nokey.json` |

### 其它必填校验（顺手验证）

- `/common/article/detail` 缺 `article_id` → `400 参数[article_id]为必填项`
- `/common/msg/detail` 缺 `msg_id` → `400 参数[msg_id]为必填项`；缺 `site_id` → `400 参数[site_id]为必填项`
- `/common/teacher/page` 缺 `is_leader`（连 site_id 也没传）→ `400 参数[is_leader]为必填项`（校验顺序 is_leader 先于 site_id）
- `/common/recruit/query` GET → `405 Method Not Allowed`；`{}` 空 body → `500`

---

## ③ 各端点可粘贴 curl 复现命令

```bash
B=https://gwqietap.sxjzit.edu.cn/mapi
SID=222fa53591a3494e9c860390039b0844          # jwc site_id
CID=94511e8fcb8c49b4a1ade5d2fda8a03b          # jwc 通知公告 column_id

# 1) 首页/学校概况（无参，无需任何请求头）
curl -s "$B/school/home5"                        # 200
curl -s "$B/school/intro"                        # 200
curl -s "$B/school/cooperate"                    # 200
curl -s "$B/school/msg"                          # 200（校长信箱列表）

# 2) 部门 / 学院首页聚合
curl -s "$B/dept/home2?site_key=jwc"             # 200
curl -s "$B/dept/home?site_key=jwc"              # 200（旧版）
curl -s "$B/college/home?site_key=xcdsj"         # 200（注意：mkszy 会 500）

# 3) 导航 / 页脚
curl -s "$B/common/column/head"                  # 200
curl -s "$B/common/foot"                         # 200

# 4) 文章列表 / 详情
curl -s "$B/common/column/articles?site_id=$SID&column_id=$CID&page=1&size=8"      # 200
curl -s "$B/common/column/articles?site_id=$SID&column_id=$CID&page=99999&size=8"  # 200 空列表
curl -s "$B/common/column/oneTwoArticles?site_id=890cf93e62aa47a0983aa5f551c92e4a&column_id=817cc143097911f08df500163e031f40"  # 200（父栏目）
curl -s "$B/common/article/detail?article_id=046e6ed45ce64980a67f471b8efc157b"      # 200

# 5) 校长信箱
curl -s "$B/common/msg/detail?site_id=1&msg_id=179"   # 200

# 6) 师资分页（is_leader 必填：0=全部 1=领导）
curl -s "$B/common/teacher/page?site_id=890cf93e62aa47a0983aa5f551c92e4a&is_leader=0&page=1&size=10"  # 200

# 7) 校园日历月历
curl -s "$B/school/events?year=2026&month=9&site_id=$SID"    # 200

# 8) 站内搜索（key_words 必填，p=页码，s=页大小）
curl -s "$B/common/search?key_words=%E8%80%83%E8%AF%95&p=1&s=10"   # 200（关键词「考试」）
curl -s "$B/common/search?key_words=%E8%80%83%E8%AF%95&p=2&s=5"    # 200

# 9) 招生查询（POST，JSON body；idcard 需 RSA 加密，下面仅探测契约）
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"张三","idcard":"000000000000000000"}' "$B/common/recruit/query"   # code 500（假数据未命中）

# 10) 短链（GET ?url=；响应体键为 msg/datas）
curl -s "$B/common/short/create?url=https%3A%2F%2Fwww.sxjzit.edu.cn%2F"   # {"code":200,"msg":"成功","datas":"..."}

# 11) 反例：/article/videos 不是 API
curl -s "$B/article/videos"                      # 404 Not Found
```

**是否需要特殊请求头**：不需要。上述命令全部在**不带任何 Header** 下拿到预期响应（含 200/400/404/405）。仅「POST + JSON body」（recruit/query、msg/send）需带 `Content-Type: application/json`；`/common/short/create` 前端由 `BaseArticle-*` chunk 用原生 `fetch(...,{credentials:"include"})` 直调（非 axios），实测不带 cookie/头同样可用。

---

## ④ 页面 ↔ 接口映射表

路由表来源：`app.js`（`path` 定义集中区，偏移 125900 起）+ 各页面 chunk 的 import/调用点。

| 页面路由 | 页面 chunk（证据） | 使用的接口 | 证据（chunk 调用点） |
|----------|-------------------|-----------|----------------------|
| `#/index` | `Home-B7ipYR8F.js` | `/school/home5`、`/common/article/detail` | `import{b as de,c as Ee}` |
| `#/aboutUs` | `AboutUs-4uQBLfht.js` | `/school/intro`、`/common/article/detail` | `import{d as it,e as lt}` |
| `#/departments` → `#/departments/list` | `Departments-T73TY7Fq.js` / `DepartmentsList-DiyVdGSk.js` | `/dept/home2`、`/dept/home`（父页）；`/school/org`（列表页） | `U({params:{site_key:a}})`(home2)、`w({params:{site_key:a}})`(home)；`DepartmentsList` `T()`=school/org |
| `#/departments/page?site_key=jwc&page=notice` | `DepartmentsPage-CeXqjfye.js` | `/common/column/articles`、`/common/article/detail`、`/common/teacher/page`、`/common/column/oneTwoArticles`、`/school/events` | `st({params:{site_id,column_id,page,size}})`；`At({params:{article_id}})`；`Gt({params:{site_id,is_leader,page,size}})`；`Xt({params:{site_id,column_id}})`；`Jt({params:{year,month,site_id}})` |
| `#/college?site_key=xcdsj` | `College-B_stGeN4.js` | `/college/home`、`/common/column/articles`、`/school/intro`、`/common/msg/send` | `Bt({params:{site_key:p}})`；`G({...})`；`Mt`=school/intro；`Y(s.value)`=msg/send |
| `#/opinion`（校长信箱） | `Opinion-CUoCMawn.js` | `/school/msg`、`/common/msg/send`、`/common/column/articles` | `j()`=school/msg；`Y(s.value)`=msg/send；`j({params:{site_id,column_id,page,size}})` |
| `#/collaboration` | `Collaboration-DGo-cW7s.js` | `/school/cooperate`、`/common/column/articles` | `import{d as lt,n as nt}` |
| `#/article/videos` | `ArticleListContainer-CImViQF-.js` | `/common/column/articles` | `import{d as b}` |
| `#/list/article` | `ArticleContainer-CwpPJKmv.js` | `/common/article/detail` | `import{b as A}` |
| `#/list/message` | `MessageContainer-1bNkXpsc.js` | `/common/msg/detail` | `x({params:{site_id,msg_id}})` |
| `#/list/search` | `SearchContainer-B9GpWzIS.js` | `/common/search` | `Z({params:{key_words,p,s}})` |
| `#/list/more` | `ListContainer-DhHIWNOX.js` | `/common/column/oneTwoArticles`、`/common/column/articles` | `import{l as K,d as I}` |
| `#/list/videos` | `VideoListContainer-C5MTZ8GX.js` | 无 API import（数据来自路由 query） | 该 chunk 未 import 任何 API |
| `#/miniPage` | `MiniPage-B7JzfHPw.js` | `/school/msg`、`/school/intro` | `import{o as M,e as v}` |
| `#/zsw-query`（招生查询） | `zsw-query-C7gnNmpf.js` | **POST** `/common/recruit/query` | `On({name,idcard:Mn(idcard)})`，`Mn` 来自 `crypto-BC68fZNF.js` |
| 全站头部 | `Main-th6b8-8U.js` | `/common/column/head` | `Ce()`=column/head |
| 全站页脚 | `Main-th6b8-8U.js` | `/common/foot` | `Ae()`=foot |

> 补充：`#/college/*` 子路由（Home-B0t5THTG / Introduction / Working / LatestNews / Announcement / News / Thematic / ElegantDemeanour / DataDownload / ContactUs）均在 `College` 容器内，共享 `/college/home` 数据 + 各自 `/common/column/articles`。

### ★ 校园日历路由结论（重点）

**不存在独立路由**（`app.js` 中无 `/departments/calendar`，也无 `/campus/...` 路由；`/:catchAll(.*)*` 会兜底 NotFound）。校园日历是**部门/学院页 `#/departments/page` 内的一种 tab 面板**，由 `/dept/home2` 返回数据的 `componentType` 决定：

- 证据 1（componentType=calendar）：`dept/home2?site_key=jwc` 返回 `"calendar":{"column_id":"d0fb6bbd281144eebd8f817bb38c12b0","site_id":"222fa53591a3494e9c860390039b0844","title_cn":"校园日历","title_en":"calendar","href":"/","componentType":"calendar","events":{"rest_work":{...}}}`（`raw/ep_dept_home2_jwc.json`）。
- 证据 2（分发表）：`DepartmentsPage-CeXqjfye.js` 中 `s={...,calendar:Ua,recruit:Ga,...}`，由 `componentType` 分发到 `TabCalendar/CalendarContainer`（`__name:"TabCalendar"`）。
- 证据 3（路由拼装）：`Departments-T73TY7Fq.js` 用 `page=<栏目 title_en>` 选择面板，面包屑 `path:/departments/page?site_key=<key>&page=<title_en>`。

**校园日历 URL：**
```
https://www.sxjzit.edu.cn/#/departments/page?site_key=jwc&page=calendar
```
（通式 `#/departments/page?site_key=<site_key>&page=<该栏目 title_en>`。）

- 数据来源：**首屏**用 `/dept/home2` 内嵌的 `calendar.events`；**翻月**由 `TabCalendar` 调 `/school/events?year=&month=&site_id=`（`Jt`）。
- 「下载完整日历」按钮指向 `https://www.sxjzit.edu.cn/#/list/more?site_id=1&column_id=8197fe41503c4c32bce1e449d2492b2e`（主站 site_id=1 的日历列表栏目，走 `/common/column/articles`）。
- `Main-th6b8-8U.js` 里出现的 `"/campus"` 只是**头部导航菜单项 path 分割逻辑**（`path.split("--")`），并非 vue-router 路由，切勿混淆。
