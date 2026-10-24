# Checklist

## 一、实机摸查与捕获
- [x] 已实机打开 `https://www.sxjzit.edu.cn/#/departments/list` 并完成网络全量捕获（首屏 4 XHR + 逐页点击网络台账 `network-capture.md`；HAR 不可由浏览器扩展导出，已以等效台账 + 310 份直连原始响应留档并注明）
- [x] 机构树/机构列表接口契约（URL/方法/参数/响应结构）已记录且直连复验通过
- [x] 机构树层级（根→5 分组→34 机构叶子）与 id/parent_id/title_cn/title_en/site_key/site_id/article_id/path 字段逐项记录，且与页面展示核对一致
- [x] 机构树全部机构/站点已枚举为清单（34/34 = 机构树叶子数；site_key 去重 22）
- [x] 每个机构站点均已穷举操作（全部子栏目切换 + 翻页到底 + 打开详情 + 站点内搜索）并全量捕获 XHR/Fetch（22 站 home2 + 178 子栏目 + 翻底 22/22）
- [x] 捕获的每一条请求均已归类定论（数据/配置/统计/静态；含 20 端点 + 10 健壮性探测），0 未归类
- [x] 「机构 × 接口」覆盖矩阵已产出：34 行 × 6 列 = 204 格全三态（✅已验证契约 / N/A 不适用 / ✗不存在含证据）
- [x] 完整性核算通过：捕获请求总数 = 已归类数；矩阵行数 34 = 机构树站点数 34

## 二、接口契约
- [x] 每个机构的文章列表接口已逐机构确认（`/dept/home2?site_key=` 或 `/college/home?site_key=`；列表 `/common/column/articles?site_id&column_id&page&size`）
- [x] 分页机制已确认（page 从 1 起、size 无服务端上限、total 字段；page=0→body code 500、超界→空数组），且每机构可翻到底（22/22 累计条数与 total 吻合）
- [x] 列表项字段已逐字段列出（id/title/description/image_url/create_time/update_time/tag/sort + 招生网变体 out_link/source）
- [x] 子栏目全量枚举表已产出（178 栏目：名称/column_id/条数/页数）+ 切换机制已确认（路由 `&page=xxx` + 同接口不同 column_id）
- [x] 特殊板块（置顶/推荐/轮播）存在性已给结论：机构页无（含证据）；学院页含轮播；板块接口 `/common/column/oneTwoArticles` 需站点根栏目 id
- [x] 文章详情接口契约已记录（`/common/article/detail?article_id=`，5 字段），正文 HTML 形态已说明
- [x] 资源真实地址前缀与拼接规则已给出（绝对 URL、host `www2.sxjzit.edu.cn:8082`、前缀 `/zhglxt/profile/(cms)upload/…`、http→https 修正），直连验证可访问（200）
- [x] 搜索接口（`/common/search?key_words&p&s` + 路由 `#/list/search?key_words=`）已确认并直连复验
- [x] 校园日历正确网址结论已记录：无独立页面；落地页 `#/departments/page?site_key=jwc`（首页板块）；数据 = dept/home2 内嵌 calendar.events + `/school/events?year&month&site_id`；`&page=calendar` 为无效路由反例
- [x] 关联接口逐项结论（访问量/点赞/标签/相关推荐 = 不存在，含取证方式；短链 `/common/short/create` 契约记录，响应键名 msg/datas 特例）
- [x] 站点映射表（机构 ↔ site_key ↔ site_id ↔ 页面路由）已产出且与 App 实现一致
- [x] 接口健壮性已记录（HTTP 恒 200 + body code；page=0→500；size 无上限；site_key 不存在→500；`/common/article/page` 的 pageNo 失效陷阱；`/college/home?mkszy` 无数据特例）→ 坑位清单 §11

## 三、复现与证据
- [x] 每个接口均有可直接粘贴执行的 curl 复现命令（20 条，含必需请求头结论「无需特殊头」），且实测通过
- [x] 证据已归档至 `qin/docs/departments-api-evidence/`（raw/ 311 份原始响应 + network-capture 台账 + 代理取证文档 + 审计报告；HAR 不可导出处与截图未归档均已如实注明）
- [x] 清单内证据索引可用（结论 → 证据文件 → 命名规则：home2_/list_/detail_/ep_/rob_）

## 四、交付物
- [x] 接口清单文档 `qin/docs/departments-api-inventory.md` 已产出（1079 行 / 14 节：六范围组织、样例与字段表、分页与拼接规则、curl、坑位）
- [x] 清单中每个机构/站点均有条目，六范围 0 遗漏（检索核算：34 机构 / 22 site_key / 178 column_id / 20 端点 全部可检索）
- [x] 覆盖矩阵 + 站点映射表 + App 对照表 + 完整性核算结论均已随清单交付
- [x] App 现有实现对照表已完成（已接入 / 未接入 9 / 待接入 + 行号证据；`/common/article/page` 分页失效已标注）

## 五、复核
- [x] 执行侧自检通过：抽样重测（机构树 + 22 站 home2/college + 178 栏目翻底 + 详情 + 搜索 + 日历 + 14 条 curl）全部通过
- [x] 独立子代理 fresh-eyes 交叉审计完成（audit-report.md：24 通过 / 3 部分 / 0 失败；6 项问题——2 中等 + 4 轻微——已全部修复并附修复回执 §7）
- [x] 与 App 现有实现（OrganizationManager.site_key / NetworkService / code-wiki 06-接口契约）交叉核对无冲突（§10 经 grep 验证真实无虚报）