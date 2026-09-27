# -*- coding: utf-8 -*-
"""园枢 App 运营业务流程图生成器：输出 10 张自包含 HTML（随后由 Chrome headless 渲染为 PNG）"""

import os

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "_html")
os.makedirs(OUT, exist_ok=True)

CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: linear-gradient(160deg, #EEF2FA 0%, #E7ECF7 60%, #EFF3FB 100%);
       font-family: "PingFang SC", "Hiragino Sans GB", sans-serif; color: #1E293B; }
.page { margin: 34px 40px; background: #FFFFFF; border-radius: 26px; padding: 30px 34px 26px;
        box-shadow: 0 18px 46px rgba(11,31,75,.10); }
.head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 6px; }
.h-no { font-size: 15px; font-weight: 700; color: #C9A227; letter-spacing: 2px; }
.h-cn { font-size: 30px; font-weight: 800; color: #0B1F4B; }
.h-en { font-size: 13px; color: #8A97B1; letter-spacing: 1.4px; text-transform: uppercase; }
.h-intro { font-size: 14.5px; color: #5A6B8C; margin: 8px 0 20px; line-height: 1.55; }
.flow { display: flex; flex-direction: column; gap: 0; }
.row { display: flex; gap: 12px; align-items: stretch; }
.row.center { justify-content: center; }
.col { flex: 1; display: flex; flex-direction: column; gap: 10px; }
.node { background: #F8FAFE; border: 1.5px solid #E2E8F4; border-top: 4px solid var(--c, #2B5BD7);
        border-radius: 14px; padding: 11px 14px; display: flex; gap: 12px; align-items: center; }
.node .ic { width: 42px; height: 42px; flex: 0 0 42px; border-radius: 12px; display: flex; align-items: center;
           justify-content: center; font-size: 21px; background: var(--cb, #EAF1FE); }
.node .t { font-size: 16px; font-weight: 700; color: #172A4D; line-height: 1.3; }
.node .s { font-size: 12.5px; color: #64748B; margin-top: 3px; line-height: 1.45; }
.ar { display: flex; align-items: center; justify-content: center; color: #C9A227; font-size: 26px;
      font-weight: 800; height: 34px; }
.ar.x { flex-direction: row; flex: 0 0 44px; font-size: 22px; height: auto; }
.ar small { font-size: 12px; color: #8A97B1; font-weight: 600; margin: 0 6px; }
.lane { border: 1.5px solid #E2E8F4; border-left: 6px solid var(--c, #2B5BD7); border-radius: 14px;
        padding: 12px 14px; background: #FBFCFE; flex: 1; }
.lane .lt { font-size: 14.5px; font-weight: 800; color: var(--c, #2B5BD7); margin-bottom: 9px; }
.branch { display: grid; grid-template-columns: 1fr .12fr 1fr .12fr 1fr; gap: 8px; align-items: stretch; }
.tag { align-self: center; text-align: center; font-size: 12px; font-weight: 800; color: #FFFFFF;
       background: #64748B; border-radius: 999px; padding: 5px 8px; margin: 0 2px; }
.tag.yes { background: #16A34A; } .tag.no { background: #C8102E; }
.legend { margin-top: 18px; background: #F4F7FC; border: 1px dashed #C7D2E8; border-radius: 12px;
          padding: 10px 16px; font-size: 12.5px; color: #5A6B8C; line-height: 1.6; }
.legend b { color: #0B1F4B; }
.hint { margin-top: 10px; background: #FFF9E8; border: 1px solid #F1DFA6; border-radius: 12px;
        padding: 10px 16px; font-size: 12.5px; color: #8A6D1B; line-height: 1.6; }
.mini { display:flex; gap:6px; flex-wrap:wrap; margin-top:6px; }
.mini span { font-size: 11.5px; background:#EAF1FE; color:#2B5BD7; border-radius:999px; padding:3px 9px; font-weight:600; }
"""

DEEP, GOLD, BLUE, TEAL, ORANGE, PURPLE, RED, GREEN, GRAY = "#0B1F4B", "#C9A227", "#2B5BD7", "#0D9488", "#EA7B2C", "#7C3AED", "#C8102E", "#16A34A", "#64748B"

def node(t, s="", c=BLUE, ic=""):
    return (f'<div class="node" style="--c:{c};--cb:{c}18"><div class="ic">{ic}</div><div><div class="t">{t}</div>'
            + (f'<div class="s">{s}</div>' if s else "") + "</div></div>")

def down(lbl=""):
    return f'<div class="ar">{("<small>"+lbl+"</small>") if lbl else ""}↓</div>'

def right(lbl=""):
    return f'<div class="ar x">{("<small>"+lbl+"</small>") if lbl else ""}→</div>'

def lane(title, inner, c=BLUE):
    return f'<div class="lane" style="--c:{c}"><div class="lt">{title}</div>{inner}</div>'

def page(no, cn, en, intro, body, legend, hint=""):
    html = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>{CSS}</style></head>
<body><div class="page">
<div class="head"><div><span class="h-no">FIG {no} / 10</span> &nbsp;·&nbsp; <span class="h-cn">{cn}</span></div>
<span class="h-en">{en}</span></div>
<div class="h-intro">{intro}</div>
{body}
<div class="legend">{legend}</div>
{hint}
</div></body></html>"""
    with open(os.path.join(OUT, f"fig{no:02d}.html"), "w", encoding="utf-8") as f:
        f.write(html)

# ============ FIG 1 系统总体架构与数据流 ============
body = f"""
<div class="flow">
{lane("① 数据源层 · 山西晋中理工学院官方网站群", f'<div class="row">'
  + node("官网主站 API", "gwqietap.sxjzit.edu.cn/mapi<br>首页/栏目/文章/概况/信箱 等 20+ 接口", BLUE, "🌐")
  + right("HTTPS") + node("机构子站群", "各院系 site_key 子站<br>党建工作/思政专题/招生网", TEAL, "🏛️")
  + right("HTTPS") + node("静态素材与镜像", "www2.sxjzit.edu.cn:8082<br>校园图片/视频/校徽素材", ORANGE, "🖼️") + "</div>", DEEP)}
<div class="ar"></div>
{lane("② 网络与协议层", f'<div class="row">'
  + node("NetworkService", "重试退避 · 双 Session ·<br>DTO 容错解码 · 7 类错误模型", BLUE, "🔌")
  + right() + node("Referer 防盗链协议", "全局 URLProtocol 注入引流标头<br>贯穿网络监测埋点", GOLD, "🛡️")
  + right() + node("缓存模式引擎", "即时刷新 / 缓存模式<br>无图模式 · 命中率统计", GREEN, "⚡") + "</div>", BLUE)}
<div class="ar"></div>
{lane("③ 服务层 · 12 大中枢（全部单例 + 日志联动）", '<div class="mini">'
  + "".join("<span>%s</span>" % x for x in ["DataService 数据聚合","HomeModuleManager 14 模块","NotificationManager 四通道轮询","SchoolProfileStore 概况","PartySubjectStore 党建","PrincipalMailboxStore 信箱","OrganizationManager 机构","BookmarkManager 收藏","DisplaySettingsManager 显示","BiometricSecurityManager 安全锁","LogManager 日志","SJZNetworkMonitor 网络遥测"]) + "</div>", GOLD)}
<div class="ar"></div>
{lane("④ 视图层 · 五大 Tab + 三大业务模块", f'<div class="row">'
  + node("首页", "14 内容模块 · 入口卡<br>滚动追踪 · 骨架屏", BLUE, "🏠")
  + node("院系", "机构树 · 子站搜索", TEAL, "🏛️")
  + node("资讯", "四栏目资讯流", BLUE, "📰")
  + node("校园", "校园功能集合", GREEN, "🏫")
  + node("我的", "设置/日志/收藏", GRAY, "👤")
  + '</div><div class="row" style="margin-top:8px">'
  + node("学校概况", "七板块 · 图集画廊 · 全文搜索", PURPLE, "🎓")
  + node("党建专题", "双子站 · 300 篇聚合", RED, "🚩")
  + node("校长信箱", "分页 · 增量提醒", ORANGE, "📮") + "</div>", PURPLE)}
<div class="ar"><small>右侧贯穿：统一接入 LogManager 日志系统（24 个域）与 SJZNetworkMonitor 网络遥测</small>↓</div>
{node("统一运行底座", "零第三方依赖 · SwiftUI + UIKit/WebKit/AVKit · 真机 iPhone · iOS 26+", DEEP, "📱")}
</div>"""
page(1, "园枢 App 系统总体架构与数据流", "SYSTEM ARCHITECTURE & DATA FLOW",
     "一句话总览：园枢是山西晋中理工学院的校园信息聚合 App——从官网 20+ 接口采集数据，经协议层与 12 个服务中枢加工，在五大 Tab 与三大业务模块中呈现，全程日志留痕、可监测可诊断。",
     body, "<b>读图方式：</b>自上而下四层；箭头=数据流向；<b>金色</b>=协议与中枢、<b>蓝色</b>=数据域、<b>紫色</b>=三大业务模块。数据单向流动：官网 → 网络 → 服务 → 视图。")

# ============ FIG 2 冷启动与安全门 ============
body = f"""
<div class="flow">
{node("用户点击 App 图标 / 点按通知", "", DEEP, "🚀")}
{down()}
{node("LaunchScreen 静态启动页", "校徽 · 校名 · 校训 · SINCE 2002 · 与 SplashView 视觉对齐", BLUE, "🌟")}
{down()}
<div class="branch">
  {node("未同意隐私协议", "弹出 PrivacyConsentView<br>不同意 → 受限模式 RestrictedModeView", ORANGE, "📜")}
  <div class="tag no">否</div>
  {node("首次启动判定", "本地标记<br>是否已同意隐私协议", GOLD, "🔑")}
  <div class="tag yes">是</div>
  {node("已同意 · 进入主流程", "", GREEN, "✅")}
</div>
{down("可选安全门（用户已开启时）")}
{node("生物识别安全锁", "Face ID 验证 · 锁定策略（即时/1分钟）· 失败记日志<br>验证通过或未启用 → 放行主界面", PURPLE, "🔐")}
{down()}
<div class="row">
{lane("主线任务", f'<div class="flow">'
  + node("主界面渲染", "五大 Tab · 主题/字体即时应用", BLUE, "🏗️")
  + down() + node("DataService 首轮同步", "首页/栏目/资讯全拉 · 失败三级降级", TEAL, "🔄")
  + down() + node("首页骨架 → 内容渐进揭示", "Apple News 式闪烁骨架 · SJZRevealOnce 错峰入场", GOLD, "✨") + "</div>", BLUE)}
{lane("并行支线", f'<div class="flow">'
  + node("通知轮询启动", "四通道首查 + 周期轮询（15-120 分钟）", PURPLE, "🔔")
  + down() + node("热点图片预热", "缓存模式预取 · SJZImagePrefetcher ≤20 张", ORANGE, "🖼️")
  + down() + node("网络监测中枢初始化", "链路/吞吐采样器启动", GRAY, "📡") + "</div>", PURPLE)}
</div>
{down()}
{node("首页就绪", "模块区可见 · 同步状态胶囊提示 · 全程启动日志留痕", GREEN, "🏁")}
</div>"""
page(2, "冷启动与安全门流程", "COLD START & SECURITY GATE",
     "覆盖：启动 → 隐私同意门 → 可选 Face ID 安全锁 → 主界面 → 同步/轮询/预热三段并行 → 首页就绪的全过程与分支判定。",
     body, "<b>读图方式：</b>黄=判定点（是/否分支）；<b>并行支线</b>与主线同时开工，任一失败不影响主界面呈现。",
     "⚠️ 设计要点：隐私协议为红线区域；通知点击深链在「让出系统回调同步链」后才弹窗（防闪退原则）。")

# ============ FIG 3 首页运营模块 ============
body = f"""
<div class="flow">
<div class="row">
{lane("配置层", node("HomeModuleManager", "14 个内容模块<br>显隐开关 · 排序 · 主题色 · 单位", GOLD, "🎛️") + '<div class="mini"><span>要闻/荣誉/公告/招生/教师/映像/故事/风光/活动/合作/历程/信箱/党建/概况</span></div>', GOLD)}
{lane("渲染策略", f'<div class="flow">'
  + node("冷启动无数据", "骨架屏（标题栏+闪烁卡片列）", GRAY, "💤")
  + down() + node("数据就绪", "SJZRevealOnce 错峰揭示<br>0.07s×序号弹簧动画", GREEN, "🎬") + "</div>", GREEN)}
</div>
{down()}
<div class="row">
{node("校长信箱入口卡", "渐变信封 · 最近一封预览 · 「N 封回复」徽章<br>数据懒加载到卡后再呈现", ORANGE, "📮")}
{node("党建专题入口卡", "红色旗帜 · 实时文章总数徽章<br>常显入口（恒 hasContent）", RED, "🚩")}
{node("学校概况入口卡", "蓝金卡 · 七板块预览<br>常显入口（恒 hasContent）", PURPLE, "🎓")}
</div>
{down("用户行为链条")}
<div class="row">
{node("下拉刷新", "refreshable → DataService 强制同步", TEAL, "↻")}
{node("滚动浏览", "方向变化 3s 节流日志 · 触底 10s 哨兵", BLUE, "📜")}
{node("模块位次调整", "设置页拖拽排序 · 即时生效", GOLD, "🔀")}
</div>
{down()}
<div class="row">
{lane("内容承载", node("文章列表/详情", "SJZCachedImage 缩略图 · 阅读时长徽章（四色分档）", BLUE, "📰"), BLUE)}
{lane("状态反馈", node("同步状态胶囊", "Liquid Glass 渐变进度环 + 高亮描边", GREEN, "💊") + node("离线缓存徽章", "数据来自本地缓存时提示", GRAY, "💾"), GREEN)}
</div>
</div>"""
page(3, "首页内容运营模块链路", "HOME MODULE OPERATION PIPELINE",
     "首页运营：14 个内容模块可配置、三张常显入口卡、骨架屏与错峰动画、滚动追踪、双刷新通道与全状态反馈。",
     body, "<b>读图方式：</b>上=配置与渲染策略；中=三入口卡与用户行为；下=内容承载与状态反馈。紫/红/橙为三大常显业务入口。",
     "⚠️ 约束：常显入口模块（信箱/党建/概况）必须从首页骨架屏条件中排除，否则冷启动骨架永不显示。")

# ============ FIG 4 四通道通知轮询 ============
body = f"""
<div class="flow">
{node("轮询调度器", "启动即首查 · 之后按间隔（15/30/60/120 分钟）周期触发<br>isChecking 防重入 · 开关+权限双闸门", DEEP, "⏱️")}
{down("四通道顺序执行 · 各自独立容错（一通道失败不影响其余）")}
<div class="row">
{lane("通道 1 · 新闻", f'<div class="flow">'
  + node("fetchHome2 取 4 栏目", "要闻/资讯/党建/通知", BLUE, "📰")
  + down() + node("并行拉各栏第一页", "withTaskGroup 并发", TEAL, "⚡")
  + down() + node("对比 notifiedArticleIds", "上限 2000 · 首次免打扰", GOLD, "🧾")
  + down() + node("每次 ≤5 条 · 错开 1s 推送", "", GREEN, "📤") + "</div>", BLUE)}
{lane("通道 2 · 校长信箱", f'<div class="flow">'
  + node("/school/msg 第一页", "total 基线检测", ORANGE, "📮")
  + down() + node("新增信件 → 推送", "携带 mailboxId 深链", GREEN, "📤")
  + down() + node("首次仅建基线不推", "", GRAY, "🤫") + "</div>", ORANGE)}
{lane("通道 3 · 学校概况", f'<div class="flow">'
  + node("/school/intro+cooperate", "三段基线：领导|风光|合作交流", PURPLE, "🎓")
  + down() + node("逐段对比变化", "文案精确到变化板块", GOLD, "🔍")
  + down() + node("变化 → 推送", "旧两段基线静默升级", GREEN, "📤") + "</div>", PURPLE)}
{lane("通道 4 · 党建专题", f'<div class="flow">'
  + node("/dept/home2 双子站指纹", "总数+最新3篇签名 · 按 id 去重", RED, "🚩")
  + down() + node("四段基线对比", "djgz|top3|mkszy|top3", GOLD, "🔍")
  + down() + node("变化 → 推送", "文案精确到子站", GREEN, "📤") + "</div>", RED)}
</div>
{down("系统本地通知：横幅 · 声音 · 图标角标")}
{node("用户点按通知", "UNUserNotificationCenter didReceive 回执后进入处理", BLUE, "👆")}
{down()}
<div class="row">
{node("文章详情", "pendingDeepLink → EnhancedNewsDetailView", BLUE, "📄")}
{node("信件详情", "pendingMailboxDeepLink → MailboxSheetRoot 直达", ORANGE, "✉️")}
{node("学校概况", "pendingSchoolProfileDeepLink → Sheet", PURPLE, "🎓")}
{node("党建专题", "pendingPartySubjectDeepLink → Sheet", RED, "🚩")}
</div>
{down("安全调度：让出系统回调同步链（延迟 350-400ms）→ 等场景活跃+Face ID 解锁 → 再弹详情｜测试闭环：通知测试中心五分区 + deepLinkOutcome 回显")}
</div>"""
page(4, "四通道通知轮询与点击深链", "NOTIFICATION POLLING & DEEP LINK",
     "官网一有更新：四条轮询通道各按基线检测 → 本地推送 → 点击即达四种目的地；通知测试中心可随时全链路自检。",
     body, "<b>读图方式：</b>四条并行通道各自维护基线（UserDefaults），首次仅建基、变化才推送，杜绝历史轰炸。",
     "✅ 已实测：学校概况与党建专题通道均经真机基线变更验证推送成功。")

# ============ FIG 5 学校概况七板块引擎 ============
body = f"""
<div class="flow">
{node("入口：首页卡片 / 通知深链 / 我的-AboutUs", "", DEEP, "🎓")}
{down("懒加载：hasLoaded 后跳过；手动刷新必经真实全量重拉")}
<div class="row">
{lane("① /school/intro 六板块", f'<div class="flow">'
  + node("学校简介", "统计数字滚动 · 学科竞赛 · 办学特色", BLUE, "📖")
  + node("现任领导 7 位", "头像 · 职务 · 简介全文", BLUE, "🧑‍💼")
  + node("识别系统", "校徽/校名规范图 · 释义", BLUE, "🖋️")
  + node("宣传片 + 校歌", "内联 AVKit 出现即播 · 离开即停", BLUE, "🎬") + "</div>", BLUE)}
{lane("② 校园风光", f'<div class="flow">'
  + node("栏目分页全量", "4 页 × 50 覆盖", TEAL, "🌄")
  + down() + node("图集详情预热", "并发 ≤4 拉全部正文图片<br>画廊秒开 · 搜索纳全文", GOLD, "🗂️") + "</div>", TEAL)}
{lane("③ 合作交流", f'<div class="flow">'
  + node("/school/cooperate 三组", "国际交流 8 · 继续教育 2", PURPLE, "🌍")
  + node("校企合作 19 篇", "栏目文章接口分页取全", PURPLE, "🏢")
  + down() + node("详情预热", "正文+图集 · 并发 ≤4", GOLD, "🗂️") + "</div>", PURPLE)}
</div>
{down("统一检索与消费")}
<div class="row">
{node("全文本地搜索", "七类条目 AND 分词加权（标题5/正文2/分类1）<br>预热后校企正文全文可命中", BLUE, "🔍")}
{node("图集画廊", "轮播 + 3 列网格 + 页码胶囊 + 全屏", TEAL, "🖼️")}
{node("图片长按菜单", "保存到相册（addOnly）/ 系统分享", GREEN, "💾")}
</div>
{down("刷新状态机：工具栏三态 / 顶部横幅 / 下拉刷新 / 失败重试 —— 手动刷新清空详情缓存+代际校验，与官网绝对同步")}
</div>"""
page(5, "学校概况七板块数据引擎", "SCHOOL PROFILE 7-SECTION ENGINE",
     "数据来源、拉取路线、预热策略、全文搜索、画廊消费与刷新同步语义——学校概况模块的全生命周期。",
     body, "<b>读图方式：</b>三路数据并行拉取 → 汇总为七类可搜索条目；金色=预热增强（秒开+全文）。",
     "✅ 手动刷新会清空风光/合作详情缓存并推进缓存代际，官网改正文也能同步下来。")

# ============ FIG 6 党建专题双子站聚合 ============
body = f"""
<div class="flow">
{node("入口：首页党建卡 / 通知深链 Sheet", "", RED, "🚩")}
{down()}
<div class="row">
{lane("党建工作 · djgz", f'<div class="flow">'
  + node("站点索引解析", "/dept/home2?site_key=djgz<br>双通道栏目收集（column_id + 内容页节点）", RED, "🏛️")
  + down() + node("4 栏目并发分页", "每栏常规 4 页×50=200 上限", TEAL, "📚")
  + down() + node("139 篇文章聚合", "容器栏 500 单栏容错隔离", GREEN, "📦") + "</div>", RED)}
{lane("思政专题 · mkszy", f'<div class="flow">'
  + node("站点索引解析", "/dept/home2?site_key=mkszy<br>嵌套子块 + tabs-sub 子页全收集", RED, "🏛️")
  + down() + node("12 栏目并发分页", "深度检索 400 条上限", TEAL, "📚")
  + down() + node("161 篇文章聚合", "空栏优雅降级", GREEN, "📦") + "</div>", RED)}
</div>
{down("全量 300 篇合并进入本地库")}
<div class="row">
{node("多词 AND 语义搜索", "分词（空格/全角）· 标题权重5 · 描述权重2 · 标签权重1<br>按相关度总分 → 时间排序", BLUE, "🔍")}
{node("两站命中分布徽章", "「党建工作 N 篇 · 思政专题 M 篇」站点色圆点", GOLD, "🏷️")}
{node("行为埋点", "输入开始/聚焦失焦/防抖/提交/历史/滑向/触底", GRAY, "📊")}
</div>
{down("刷新四来源状态机：工具栏按钮三态 → 顶部横幅 → 下拉刷新 → 失败重试；深度搜索自动补充至 400 条/栏")}
</div>"""
page(6, "党建专题双子站聚合引擎", "PARTY SUBJECT DUAL-SITE AGGREGATION",
     "党建工作（djgz）与思政专题（mkszy）两站索引解析 → 16 栏目并发分页 → 300 篇全量聚合 → 加权全文搜索。",
     body, "<b>读图方式：</b>两站完全对称处理；红色=党建域、青色=取数、绿色=聚合结果。",
     "⚠️ 服务端稳定 500 的容器型栏目（首页/师资队伍类）单栏容错隔离，绝不拖垮全站。")

# ============ FIG 7 校长信箱业务闭环 ============
body = f"""
<div class="flow">
<div class="row">
{node("首页入口卡", "渐变信封 · 最近一封预览<br>「N 封回复」徽章", ORANGE, "📮")}
{right()} {node("通知深链", "邮件通知点击 → 信件 ID<br>直达详情（Sheet 根容器）", GOLD, "🔔")}
</div>
{down()}
{node("信件列表 · 分页拉取", "/school/msg 双层 data 解析 · 逐页加载 · 「成功但 0 条」落 warning 防误判", ORANGE, "📋")}
{down()}
<div class="row">
{node("信件详情", "/common/msg/detail 三参数<br>article_id + site_id + msg_id", BLUE, "✉️")}
{node("一键拨号", "校长信箱服务电话", GREEN, "📞")}
{node("复制 / 发信", "复制邮箱地址 · 跳官网 #/opinion 在线写信", TEAL, "📝")}
</div>
{down("刷新体系：下拉（手势与本体解耦防误报）· 工具栏三态 · 顶部状态横幅 · 失败重试 —— 手动刷新必定真实拉取")}
<div class="row">
{lane("通知联动", node("增量基线检测", "total 变化 → 推送新回复<br>点击直达对应信件", GOLD, "🔔"), GOLD)}
{lane("体验细节", node("搜索+历史", "全文/标题匹配 · 10 条历史持久化 · 500ms 防抖埋点", BLUE, "🔍") + node("空态引导", "无信件时的指引文案", GRAY, "💬"), BLUE)}
</div>
</div>"""
page(7, "校长信箱业务闭环", "PRESIDENT MAILBOX BUSINESS LOOP",
     "从首页入口到信件详情、拨号/复制/官网写信，再到通知增量提醒——用户与校方沟通的完整闭环。",
     body, "<b>读图方式：</b>左→右为用户入口，中段为信件操作，底段为刷新与通知联动。",
     "⚠️ 详情接口为 /common/msg/detail（非 /school/msg/detail），必填三参数；下拉刷新本体与手势任务解耦，避免误报取消。")

# ============ FIG 8 机构子站全域搜索 ============
body = f"""
<div class="flow">
{node("机构设置 → 查看全部机构", "5 分类卡片 · 官网 /school/org 机构树动态解析（约 34 节点）", TEAL, "🏛️")}
{down()}
{node("站点匹配引擎", "OrganizationManager · site_key 四级匹配<br>机构树缓存带 version+TTL", GOLD, "🔗")}
{down()}
<div class="row">
{lane("常规搜索", f'<div class="flow">'
  + node("双通道栏目收集", "column_id 直收 + 内容页节点（title_cn+id）", BLUE, "🧭")
  + down() + node("常规 4 页 × 50 = 200 条/站", "", TEAL, "📄") + "</div>", BLUE)}
{lane("深度搜索", f'<div class="flow">'
  + node("深度 8 页 × 50 = 400 条/站", "老旧文章全覆盖", PURPLE, "📚")
  + down() + node("覆盖所有子栏目", "含仅 id 无 column_id 的小栏目", PURPLE, "🕳️") + "</div>", PURPLE)}
{lane("执行策略", f'<div class="flow">'
  + node("并发批处理", "每批 8 个机构并行", GREEN, "⚡")
  + down() + node("结果流式合入", "实时检索进度胶囊", GREEN, "🌊")
  + down() + node("查询结果缓存", "命中秒回 · 索引 ≤60 站", GOLD, "💾") + "</div>", GREEN)}
</div>
{down("命中文章详情")}
{node("文章详情 siteId 智能降级", "并行尝试 siteId / sectionSiteId / ZSW / 主站 / 空 —— 取内容最长者", ORANGE, "🎯")}
{down()}
{node("收藏 · 已读状态 · 阅读统计 · 长按保存分享", "", GRAY, "🏷️")}
</div>"""
page(8, "机构子站全域搜索流水线", "ORGANIZATION SUB-SITE SEARCH PIPELINE",
     "从机构树解析到站点匹配、常规/深度两级检索、并发批处理与详情降级——机构资讯的全域可搜。",
     body, "<b>读图方式：</b>左右两路=常规/深度检索策略，右中=执行引擎，底部=命中后的消费。",
     "⚠️ 主站栏目 ID 硬编码（要闻/资讯/党建/通知）用于机构详情降级搜索，官网换 ID 需同步。")

# ============ FIG 9 图片系统与三级缓存 ============
body = f"""
<div class="flow">
{node("图片入口（全 App 统一下发）", "新闻/机构/风光/领导/合作交流/首页卡 —— 一律 SJZCachedImage", DEEP, "🖼️")}
{down()}
<div class="row">
{node("同步内存缓存直出", "初始化期同步检查 NSCache<br>命中即渲染，无占位帧", GREEN, "⚡")}
{node("未命中 → 无图模式短路", "无图模式跳过加载计数", GRAY, "🚫")}
{node("未命中 → 网络加载", "RefererHeaderURLProtocol 注入引流标头", BLUE, "🌐")}
</div>
{down("解码与降采样")}
<div class="row">
{node("列表缩略图 720px", "防长列表内存驱逐", TEAL, "🪶")}
{node("详情主图 1440px", "高质量呈现", PURPLE, "💎")}
{node("平均色计算", "8×8 采样 → 平均色占位 blur-up", GOLD, "🎨")}
</div>
{down()}
<div class="row">
{lane("内存缓存", node("NSCache 双限制模式", "96MB / 40MB 像素计费<br>OSAllocatedUnfairLock", BLUE, "🧠"), BLUE)}
{lane("磁盘缓存", node("cachedSession URLCache", "10MB 内存 / 50MB 磁盘<br>article_detail_cache", TEAL, "💽"), TEAL)}
{lane("消费端", node("点击全屏 · 长按保存相册（addOnly）· 系统分享", "ProfileImageSaveShare 全链路日志", GREEN, "📤"), GREEN)}
</div>
{down("缓存命中日志按 URL 首现节流 · 7 天缓存策略（除非 no-store）· 协议层拦截全 sxjzit 域")}
</div>"""
page(9, "图片系统与三级缓存流水线", "IMAGE PIPELINE & CACHE",
     "从统一入口到缓存直出、降采样解码、平均色占位、双限内存缓存与磁盘缓存——以及保存/分享的出口。",
     body, "<b>读图方式：</b>自上而下=加载路径；底部三格=存储与消费。金=增强体验，绿=出口。",
     "✅ 缩略图 720px 下采样是解决长列表滚动闪图的关键；图片内存缓存按像素计费双限。")

# ============ FIG 10 显示与个性化设置 ============
body = f"""
<div class="flow">
{node("入口：我的 → 应用设置 → 显示设置（DisplaySettingsManager 中枢 · 全实时生效）", "", DEEP, "⚙️")}
{down()}
<div class="row">
{lane("外观与排版", f'<div class="flow">'
  + node("外观模式", "浅色/深色/跟随系统", BLUE, "🌗")
  + node("主题色 · 字体", "主题风格 · 6 档字号 · 粗体 · 行距字距 · 按钮形状", BLUE, "🔤") + "</div>", BLUE)}
{lane("屏幕", f'<div class="flow">'
  + node("亮度接管", "手动接管 / 自动亮度 · -1 哨兵", GOLD, "🔆")
  + node("自动锁定 7 档", "「永不」→ 真实禁息屏", ORANGE, "⏲️")
  + node("屏幕常亮开关", "isIdleTimerDisabled 取或联动<br>低电量提示 · 熄屏诊断卡", ORANGE, "💡") + "</div>", ORANGE)}
{lane("内容与阅读", f'<div class="flow">'
  + node("文章文字颜色", "预设 + 自定义十六进制 · 全渲染点即时生效", PURPLE, "🎨")
  + node("阅读统计", "字数/时长/列表徽章 · 速度档位 · FIFO 缓存 500", GREEN, "📊") + "</div>", PURPLE)}
</div>
{down()}
<div class="row">
{node("实时桥接", "SwiftUI 环境覆盖 + UIKit 亮度/锁屏/idleTimer 桥接", GOLD, "🔗")}
{node("系统联动监听", "减弱动态/透明度/对比度 · 低电量模式", TEAL, "👂")}
{node("恢复默认", "resetAll 全量复位 + applyRuntimeEffects 校准", GRAY, "♻️")}
</div>
{down("每次变更：UserDefaults 持久化 + display 日志域完整埋点（含值、来源、联动状态与空闲计时器上下文）")}
</div>"""
page(10, "显示与个性化设置全景", "DISPLAY & PERSONALIZATION PANORAMA",
     "外观/排版/屏幕/内容/阅读五大域、实时生效的底层桥接、系统联动监听与恢复默认——个性化中枢全貌。",
     body, "<b>读图方式：</b>上三分区=设置域；中行=生效机制；底行说明持久化与日志。",
     "✅ 屏幕常亮独立开关与自动锁定「永不」取或联动，统一经 applyIdleTimer() 三入口生效；滚动停止自动重断言修复 iOS 27 Beta 手势卡死。")

print("generated", len(os.listdir(OUT)), "html files in", OUT)