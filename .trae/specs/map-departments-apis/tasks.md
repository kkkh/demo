# Tasks

- [x] Task 1: 站点侦察与网络捕获基线
  - [x] SubTask 1.1: 外部 Chrome 实机打开 `https://www.sxjzit.edu.cn/#/departments/list`
  - [x] SubTask 1.2: DevTools/扩展网络捕获，首屏 4 个 XHR 全量记录（dept/home2、school/org、common/column/head、common/foot）
  - [x] SubTask 1.3: 标注首屏来源接口与静态/冗余请求（含 SPA 主包 + 62 分包下载与端点静态枚举）

- [x] Task 2: 机构树/机构列表接口摸清
  - [x] SubTask 2.1: 机构树接口 `/school/org` 契约（URL/方法/参数/响应结构）记录
  - [x] SubTask 2.2: 逐字段记录 id/parent_id/title_cn/title_en/site_key/site_id/article_id/path/children，梳理三层结构（根→5 分组→34 机构）
  - [x] SubTask 2.3: 与页面展示逐项核对（5 组 34 机构，名称/层级一致）
  - [x] SubTask 2.4: 站点映射表产出（机构 ↔ site_key ↔ site_id ↔ 页面路由），与 App OrganizationManager 交叉核对

- [x] Task 3: 每机构每个站点内容接口摸查（逐站点穷举 + 全量捕获）
  - [x] SubTask 3.1: 34 机构叶子清单（24 site 型 → 22 唯一 site_key；10 单文章型）
  - [x] SubTask 3.2: 逐站点穷举（子栏目切换 + 翻页到底 + 详情 + 搜索）+ 全量捕获（实机点击取证 network-capture.md + 直连 310 份原始响应）
  - [x] SubTask 3.3: 捕获请求逐条归类（22 站 home2 + 178 子栏目列表 + 10 详情 + 20 端点 + 10 健壮性探测），0 未归类
  - [x] SubTask 3.4: 每机构列表接口契约（column/articles 参数/分页/total）与列表项字段表（id/title/description/image_url/create_time/update_time/tag/sort）
  - [x] SubTask 3.5: 跨机构差异标注（dzbgs/dwxsgzb 共用 key、dwbwb site_id 仅 home2 可获、16→11 站「首页板块独有栏目」、tabs/content 类型等）

- [x] Task 4: 子栏目与特殊板块摸查
  - [x] SubTask 4.1: 子栏目全量枚举（178 栏目：名称/column_id/条数/页数）与切换机制（路由 `&page=` + 同接口不同 column_id）
  - [x] SubTask 4.2: 特殊板块结论（机构页无置顶/推荐/轮播——含证据；学院页含轮播；oneTwoArticles 板块接口需站点根栏目 id）

- [x] Task 5: 文章详情接口与资源拼接规则
  - [x] SubTask 5.1: `/common/article/detail?article_id=` 契约（5 字段：title/update_time/content/href/image_url）
  - [x] SubTask 5.2: 正文 HTML 形态记录（含 inline `<a href>` 附件、`file:///C:\` 残留过滤项）
  - [x] SubTask 5.3: 资源规则（绝对 URL、host `www2.sxjzit.edu.cn:8082`、路径前缀 `/zhglxt/profile/(cms)upload/…`、http→https 修正；直连验证 200）

- [x] Task 6: 搜索接口摸查
  - [x] SubTask 6.1: 实关键词捕获（`/common/search?key_words=考试&p=1&s=10`；页面路由 `#/list/search?key_words=…`）
  - [x] SubTask 6.2: 参数与返回结构记录 + 直连复验通过

- [x] Task 7: 关联接口摸查（校园日历/访问量/点赞/标签/相关推荐）
  - [x] SubTask 7.1: 校园日历结论：**无独立页面**；落地页 `#/departments/page?site_key=jwc`（首页板块）；数据 = dept/home2 内嵌 calendar.events + `GET /school/events?year&month&site_id`（month 1-based）；`&page=calendar` 为无效路由反例
  - [x] SubTask 7.2: 关联接口逐项结论（访问量/点赞/标签/相关推荐 = 不存在，含取证；短链 `/common/short/create` 记录）

- [x] Task 8: 接口健壮性与边界探测
  - [x] SubTask 8.1: 空/非法/超界探测（page=0→body code 500；page=last+1→空数组；size 无上限 size=1000 全量返回；site_key 不存在→500）
  - [x] SubTask 8.2: 错误语义（**HTTP 恒 200、业务码在 body `code` 400/500**）、字段缺失/类型、特殊头结论（**无需任何特殊头**）→ 坑位清单（§11）

- [x] Task 9: 逐接口直连复验与 curl 复现
  - [x] SubTask 9.1: 20 端点全部直连复验（原始响应留档 310 份）
  - [x] SubTask 9.2: 20 条 curl 复现命令（§12，实测可粘贴执行）
  - [x] SubTask 9.3: 22/22 站点翻到底校验（page=last 非空、last+1 空、total 不变）
  - [x] SubTask 9.4: 抽样与页面展示核对一致（实机点击 + 列表条数比对）
  - [x] SubTask 9.5: 完整性核算：捕获请求全部归类（0 未归类）；覆盖矩阵 34 行 = 机构树叶子数 34

- [x] Task 10: 证据留档
  - [x] SubTask 10.1: 证据归档 `qin/docs/departments-api-evidence/`（raw/ 311 + 根目录 11：README/network-capture/agentB·C·D/leaves/school_org/endpoints/img_check/audit-report）
  - [x] SubTask 10.2: 文档 §13/§14 证据索引（结论 → 证据文件 → 命名规则）；HAR 不可导出与截图未归档均已如实注明

- [x] Task 11: 输出接口清单文档
  - [x] SubTask 11.1: `qin/docs/departments-api-inventory.md`（1079 行 / 14 节：契约 + 样例 + 字段表 + 分页/拼接 + curl + 坑位）
  - [x] SubTask 11.2: 「机构 × 接口」覆盖矩阵（34×6=204 格全三态）+ 机构-站点映射表
  - [x] SubTask 11.3: App 现有实现对照表（已接入 / 未接入 9 / 待接入 + 行号证据）
  - [x] SubTask 11.4: 验证记录 + 完整性核算 + 证据索引

- [x] Task 12: 复核（自检 + 独立交叉审计）
  - [x] SubTask 12.1: 执行侧自检（检索核算 34/22/178/20 全通过；抽样重测通过）
  - [x] SubTask 12.2: 独立子代理 fresh-eyes 审计（audit-report.md：24 通过 / 3 部分 / 0 失败；6 项问题已全部修复并有修复回执）
  - [x] SubTask 12.3: 与 App 现有实现交叉核对（§10 经 grep 验证真实无虚报；/dept/home 计数已修正）

# Task Dependencies
- Task 2 depends on Task 1
- Task 3 depends on Task 2
- Task 4 / Task 5 / Task 6 / Task 7 depend on Task 3（彼此可并行）
- Task 8 / Task 9 depend on Tasks 2–7
- Task 10 depends on Tasks 1–9（证据随摸查同步归档，最终补齐索引）
- Task 11 depends on Tasks 2–10
- Task 12 depends on Task 11（审计发现问题 → 修复回执 → 复核通过）