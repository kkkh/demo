# 山西晋中理工学院 子站型机构 内容接口契约验证报告（子代理 B）

- API 基址：`https://gwqietap.sxjzit.edu.cn/mapi`
- 覆盖：leaves.json 中 site_key 非空的 **24 条机构条目**，去重后 **22 个唯一 site_key**（`dzbgs`、`dwxsgzb` 各被 2 条机构共用）
- 全部请求仅用 `curl -s`，**无需任何特殊请求头**（无 Referer/UA 亦可，全部返回 HTTP 200）
- 共探测 178 个子栏目，列表页统一 `size=20`

## 一、机构条目 → site_key 映射（24 条）

| 分组 | 机构名称 | site_key | 机构树 site_id |
|---|---|---|---|
| 党委机构 | 党委办公室 | `dzbgs` | 57c7fc7a00924d1b8113d77d9729d7eb |
| 党委机构 | 党委学生工作部(武装部) | `dwxsgzb` | 9fbfe21fde4e4620af51382cd893be6f |
| 群团机构 | 团委 | `tw` | e1acf637f93242bbbc1426c04f14145c |
| 行政机构 | 校长办公室 | `dzbgs` | （空，需从 home2 取） |
| 行政机构 | 人力资源处 | `rlzyc` | 571d4b7547804e2397a12a4f0503a571 |
| 行政机构 | 财务与资产管理处 | `cwc` | 9725697bdad041d38a0246cbbbd89b20 |
| 行政机构 | 教务处 | `jwc` | 222fa53591a3494e9c860390039b0844 |
| 行政机构 | 学生工作处 | `dwxsgzb` | （空，需从 home2 取） |
| 行政机构 | 招生就业处 | `zsw` | cb3b1fe4fcdf40999b0c162015c3326d |
| 行政机构 | 后勤管理处 | `hqglc` | 27c4a698e7fc4abea886eb4610f374e3 |
| 行政机构 | 科研处 | `kyc` | 6030fbf696d543f3a93bf537ca0af899 |
| 行政机构 | 保卫处 | `dwbwb` | （空，需从 home2 取） |
| 教学机构 | 信创与大数据学院 | `xcdsj` | 890cf93e62aa47a0983aa5f551c92e4a |
| 教学机构 | 智能制造与车辆学院 | `znzzcl` | 6fe4387f78ba4b42b9807ff86ca0df1f |
| 教学机构 | 商学院 | `sxy` | c85524251e1b4ca19d7f4c7b0de482bb |
| 教学机构 | 材料与环境学院 | `clhj` | 7575582d988949a0a3d70fcceba26cb5 |
| 教学机构 | 文法学院 | `wfxy` | e684aa6d75c340559aa4f7a2668cf3e4 |
| 教学机构 | 艺术学院 | `ysxy` | cdd28a001afc418bb2b77ad704ed12a6 |
| 教学机构 | 马克思主义学院 | `mkszy` | 93ef50506d1f4e2a92477a21ecc8b52f |
| 教学机构 | 通识教育学院 | `tsxuey` | e62a313fe40746438fdaea3cfc33123f |
| 教学机构 | 国际交流与继续教育学院 | `gjjljxjy` | 4b9a6b4591ef4e23aa4dd5fc54aebd84 |
| 教学机构 | 创新创业学院 | `scxy` | 1e4acf8fff9148ce933f47610a87ca48 |
| 知识拓展·技能转换 | 图书馆 | `tsg` | 69bc8045bfdb4ff5bb442e04bad86986 |
| 知识拓展·技能转换 | 实践教学管理中心 | `sjjxglzx` | d99e0d78612149ce99b9f00edf45ca4f |

## 二、逐站点验证结果表

> 「可取文章子栏目」= 返回 `code:200` 且含 `articles` 的栏目数；「非文章栏目(500)」= 首页/联系我们/link/teacher/calendar 等结构性栏目（对该接口返回 body `code:500`）。

| site_key | site_id | site_id 来源 | 采集子栏目 | 可取文章 | 非文章(500) | 最大栏目条数 | 翻到底结论 | 异常备注 |
|---|---|---|---|---|---|---|---|---|
| `dzbgs` | `57c7fc7a00924d1b8113d77d9729d7eb` | home2 | 8 | 6 | 2 | 23（通知公告） | ✅ 通知公告 total=23 末页p2取3/3，p3空数组 | 2个非文章栏目(500)：首页、联系我们 |
| `dwxsgzb` | `9fbfe21fde4e4620af51382cd893be6f` | home2 | 9 | 7 | 2 | 187（通知公告） | ✅ 通知公告 total=187 末页p10取7/7，p11空数组 | 2个非文章栏目(500)：首页、联系我们 |
| `tw` | `e1acf637f93242bbbc1426c04f14145c` | home2 | 11 | 9 | 2 | 205（校园活动） | ✅ 校园活动 total=205 末页p11取5/5，p12空数组 | 2个非文章栏目(500)：首页、联系我们 |
| `rlzyc` | `571d4b7547804e2397a12a4f0503a571` | home2 | 9 | 6 | 3 | 25（通知公告） | ✅ 通知公告 total=25 末页p2取5/5，p3空数组 | 3个非文章栏目(500)：首页、人资系统、联系我们 |
| `cwc` | `9725697bdad041d38a0246cbbbd89b20` | home2 | 7 | 5 | 2 | 1（部门概况） | ✅ 部门概况 total=1 末页p1取1/1，p2空数组 | 2个非文章栏目(500)：首页、联系我们 |
| `jwc` | `222fa53591a3494e9c860390039b0844` | home2 | 8 | 5 | 3 | 378（通知公告） | ✅ 通知公告 total=378 末页p19取18/18，p20空数组 | 3个非文章栏目(500)：首页、校园日历、联系我们 |
| `zsw` | `cb3b1fe4fcdf40999b0c162015c3326d` | home2 | 7 | 5 | 2 | 108（招生动态） | ✅ 招生动态 total=108 末页p6取8/8，p7空数组 | 2个非文章栏目(500)：首页一屏3栏目、就业信息网 |
| `hqglc` | `27c4a698e7fc4abea886eb4610f374e3` | home2 | 4 | 3 | 1 | 28（工作动态） | ✅ 工作动态 total=28 末页p2取8/8，p3空数组 | 1个非文章栏目(500)：首页 |
| `kyc` | `6030fbf696d543f3a93bf537ca0af899` | home2 | 8 | 7 | 1 | 72（通知公告） | ✅ 通知公告 total=72 末页p4取12/12，p5空数组 | 1个非文章栏目(500)：首页 |
| `dwbwb` | `21184757a5c84833be6abf2cf2bede3f` | home2 | 5 | 4 | 1 | 10（工作动态） | ✅ 工作动态 total=10 末页p1取10/10，p2空数组 | org树该 site_key 的 site_id 为空，site_id 仅能从 home2 响应取得；1个非文章栏目(500)：首页 |
| `xcdsj` | `890cf93e62aa47a0983aa5f551c92e4a` | home2 | 10 | 9 | 1 | 389（学院新闻） | ✅ 学院新闻 total=389 末页p20取9/9，p21空数组 | 1个非文章栏目(500)：联系我们 |
| `znzzcl` | `6fe4387f78ba4b42b9807ff86ca0df1f` | home2 | 9 | 8 | 1 | 226（学院新闻） | ✅ 学院新闻 total=226 末页p12取6/6，p13空数组 | 1个非文章栏目(500)：联系我们 |
| `sxy` | `c85524251e1b4ca19d7f4c7b0de482bb` | home2 | 9 | 8 | 1 | 149（通知公告） | ✅ 通知公告 total=149 末页p8取9/9，p9空数组 | 1个非文章栏目(500)：联系我们 |
| `clhj` | `7575582d988949a0a3d70fcceba26cb5` | home2 | 9 | 8 | 1 | 306（学院新闻） | ✅ 学院新闻 total=306 末页p16取6/6，p17空数组 | 1个非文章栏目(500)：联系我们 |
| `wfxy` | `e684aa6d75c340559aa4f7a2668cf3e4` | home2 | 9 | 8 | 1 | 215（学院新闻） | ✅ 学院新闻 total=215 末页p11取15/15，p12空数组 | 1个非文章栏目(500)：联系我们 |
| `ysxy` | `cdd28a001afc418bb2b77ad704ed12a6` | home2 | 9 | 8 | 1 | 127（学院新闻） | ✅ 学院新闻 total=127 末页p7取7/7，p8空数组 | 1个非文章栏目(500)：联系我们 |
| `mkszy` | `93ef50506d1f4e2a92477a21ecc8b52f` | home2 | 8 | 6 | 2 | 59（新闻动态） | ✅ 新闻动态 total=59 末页p3取19/19，p4空数组 | 2个非文章栏目(500)：首页、师资队伍 |
| `tsxuey` | `e62a313fe40746438fdaea3cfc33123f` | home2 | 8 | 5 | 3 | 40（学院新闻） | ✅ 学院新闻 total=40 末页p2取20/20，p3空数组 | 3个非文章栏目(500)：首页、师资队伍、联系我们 |
| `gjjljxjy` | `4b9a6b4591ef4e23aa4dd5fc54aebd84` | home2 | 8 | 6 | 2 | 6（通知公告） | ✅ 通知公告 total=6 末页p1取6/6，p2空数组 | 2个非文章栏目(500)：首页、联系我们 |
| `scxy` | `1e4acf8fff9148ce933f47610a87ca48` | home2 | 7 | 6 | 1 | 7（竞赛天地） | ✅ 竞赛天地 total=7 末页p1取7/7，p2空数组 | 1个非文章栏目(500)：首页 |
| `tsg` | `69bc8045bfdb4ff5bb442e04bad86986` | home2 | 9 | 5 | 4 | 11（通知公告） | ✅ 通知公告 total=11 末页p1取11/11，p2空数组 | 4个非文章栏目(500)：首页、知网、电子图书、联系我们 |
| `sjjxglzx` | `d99e0d78612149ce99b9f00edf45ca4f` | home2 | 7 | 6 | 1 | 69（工作动态） | ✅ 工作动态 total=69 末页p4取9/9，p5空数组 | 1个非文章栏目(500)：首页 |

### 关键说明
- **site_id 来源**：仅 `dwbwb`（保卫处）在机构树里 site_id 为空，其 site_id=`21184757a5c84833be6abf2cf2bede3f` 只能从 `/dept/home2` 响应的 `data.site.site_id` 取得。其余站点 org 树与 home2 完全一致。
- **共用站点**：`dzbgs`（党委办公室=57c7fc7a… 与 校长办公室 共用同一站点）、`dwxsgzb`（党委学生工作部 与 学生工作处 共用 9fbfe21f…）。
- **home2 内含栏目 ≠ 顶部菜单栏目**：如 kyc/dzbgs/tsg/tw/tsxuey 的「通知公告」只出现在 home2 的首页板块里，未出现在 `nav` 菜单中，但其 `column_id` 仍可直接用于列表接口。

## 三、列表项「全字段表」

以下 88 条抽样条目字段完全一致，字段集稳定：

| 字段名 | 含义 | 示例值 |
|---|---|---|
| `id` | 文章唯一 ID（文章详情接口入参） | `046e6ed45ce64980a67f471b8efc157b` |
| `title` | 标题 | `关于开展2026-2027学年第一学期新生开课课堂专项督导的通知` |
| `description` | 摘要/正文纯文本预览（含 `\r\n`） | `各学院：为进一步强化本科教学过程管理…` |
| `image_url` | 封面图 URL（无图时为占位图） | `https://www2.sxjzit.edu.cn:8082/images/no_picture.webp` |
| `create_time` | 创建/发布时间 `YYYY-MM-DD HH:mm:ss` | `2026-09-26 14:22:35` |
| `update_time` | 更新时间（ISO，仅日期有效） | `2026-09-26T00:00:00` |
| `tag` | 标签（未见有值，恒为空串） | `` |
| `sort` | 排序权重（未见有值，恒为 0） | `0` |

> 列表项**不含**正文全文；正文需另走文章详情接口（`/common/article/detail`，参数名待验证，不在本次契约范围内）。

## 四、接口契约要点（可复用）

1. `GET /dept/home2?site_key=<key>` — 站点首页聚合。返回 `data.site`（含 `site_id`/logo/主题色/联系方式）、`data.nav[]`（每个含 `column_id,title_cn,title_en,path,componentType,children[],data`）。栏目在 `nav` 与 `nav[0].data` 板块中重复出现，按 `column_id` 去重。
2. `GET /common/column/articles?site_id=<sid>&column_id=<cid>&page=<n>&size=<m>` — 栏目文章分页。响应体恒为 `{"code":…,"data":{"column_id","title_cn","title_en","href","articles":{"total","list"}}}`。
3. **业务状态在 body 的 `code`**：HTTP 状态码恒为 200；`code=200` 成功，`code=500`=“系统内部出现错误”。非法 `page`（0/负）与非文章栏目（首页/联系我们/link/teacher/calendar/recruit/componentType=0）均返回 `code=500`。
4. 分页：`page` 从 **1** 起；`pages = ceil(total/size)`；`page=last+1` 返回 `articles.list=[]`（total 保持不变），不报错。
5. `size` 无服务端上限（size=500 可一次取回全部 378 条）。
6. 纯文本表格类栏目（`tabs`/`tabs-sub`）与 `content` 类：`tabs` 返回 `total=0`（无文章，二级内容挂在子组件里），`content` 返回 `total=1`（单篇，如“部门概况”）。
7. `componentType=thematic-center`（如 tw 校园活动）、`news-important`、`electronic-book` 均为**正常文章栏目**，可返回大 total。

## 五、原始响应文件

- 首页聚合：`/tmp/dept_api/raw/home2_<site_key>.json`（22 个）
- 栏目列表首页：`/tmp/dept_api/raw/list_<site_key>_<column_id>.json`
- 翻底：`list_<site_key>_<column_id>_lastp<N>.json` 与 `_lastp<N+1>.json`