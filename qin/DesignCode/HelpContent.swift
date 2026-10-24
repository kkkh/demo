//
//  HelpContent.swift
//  DesignCode
//
//  使用帮助内容目录：全部指南文章内置于 App（无后端约束下的静态内容方案），
//  分类/文章/步骤三级结构，供 HelpGuideStore 与 HelpGuideView 使用。
//

import SwiftUI

// MARK: - 内容模型

/// 帮助分类（5 个分组，覆盖 App 全部核心能力）
struct HelpCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    /// 分类主题色（与全 App sjz 色板体系一致）
    let accent: Color
}

/// 单条操作步骤（详情页以编号圆徽章逐步渲染）
struct HelpStep: Identifiable, Hashable {
    let id: String
    let title: String
    let text: String

    init(_ title: String, _ text: String) {
        self.id = title
        self.title = title
        self.text = text
    }
}

/// 指南文章：标题/摘要/标签/步骤/相关文章，阅读时长按中文 300 字/分钟口径估算
struct HelpArticle: Identifiable, Hashable {
    let id: String
    let categoryId: String
    let title: String
    let summary: String
    let icon: String
    let tags: [String]
    let steps: [HelpStep]
    let relatedIDs: [String]

    /// 估算阅读分钟数（与全 App 阅读统计口径一致：正文+标题 300 字/分钟，向上取整，至少 1 分钟）
    var readingMinutes: Int {
        let charCount = steps.reduce(0) { $0 + $1.title.count + $1.text.count } + title.count + summary.count
        return max(1, Int(ceil(Double(charCount) / 300.0)))
    }
}

// MARK: - 内容目录

/// 帮助内容总目录（唯一内容事实源：类别 + 32 篇文章）
enum HelpCatalog {

    // MARK: 分类

    static let categories: [HelpCategory] = [
        HelpCategory(id: "gettingStarted", title: "快速上手", subtitle: "第一次使用？从这里开始", icon: "bolt.fill", accent: .sjzAccent),
        HelpCategory(id: "homeReading", title: "首页与阅读", subtitle: "新闻、收藏与分享", icon: "newspaper.fill", accent: .sjzOrange),
        HelpCategory(id: "features", title: "特色功能", subtitle: "消息、推送与专题", icon: "sparkles", accent: .sjzPurple),
        HelpCategory(id: "settings", title: "设置与个性化", subtitle: "让 App 更符合你的习惯", icon: "slider.horizontal.3", accent: .sjzTeal),
        HelpCategory(id: "faq", title: "常见问题", subtitle: "遇到问题先看这里", icon: "questionmark.bubble.fill", accent: .sjzPink)
    ]

    // MARK: 文章

    static let articles: [HelpArticle] = [
        // ========== 快速上手（6） ==========
        HelpArticle(
            id: "gs-welcome",
            categoryId: "gettingStarted",
            title: "欢迎使用「园枢」",
            summary: "一分钟了解园枢是什么、能做什么，以及它的数据从哪来。",
            icon: "hand.wave.fill",
            tags: ["园枢", "简介", "数据来源"],
            steps: [
                HelpStep("园枢是什么", "「园枢」是山西晋中理工学院的校园信息聚合 App，把学校官网的新闻、通知、院系、招生、党建、校长信箱等内容整合到一个界面里，师生和访客都能免费使用。"),
                HelpStep("完全无广告、无账号", "App 不需要注册或登录，也不会收集个人信息。所有数据都来自学校公开网站，离线时也能查看缓存和内置内容。"),
                HelpStep("数据从哪里来", "启动后 App 会自动从学校官网接口同步最新数据；网络不可用时自动降级为本地缓存，仍能看到内容。"),
                HelpStep("五个底部标签", "首页、院系、资讯、校园、我的——底部五个标签对应五大板块，点击即可切换。")
            ],
            relatedIDs: ["gs-first-launch", "fr-news", "fq-offline"]
        ),
        HelpArticle(
            id: "gs-first-launch",
            categoryId: "gettingStarted",
            title: "第一次打开怎么做",
            summary: "首次启动的隐私确认、数据同步流程说明。",
            icon: "sparkles",
            tags: ["首次启动", "隐私", "同步"],
            steps: [
                HelpStep("阅读隐私提示", "首次启动会弹出隐私说明，请阅读后选择「同意并开始使用」。同意后 App 才会联网同步数据。"),
                HelpStep("等待首次同步", "进入首页后 App 自动开始同步，约 1-5 秒完成。同步期间会显示骨架占位与顶部进度胶囊。"),
                HelpStep("拒绝后怎么办", "若选择了拒绝，App 进入受限模式不联网；之后可随时点击「查看并同意」恢复完整功能。"),
                HelpStep("建议开启通知", "同步完成后，前往「我的 → 应用设置 → 官网上新通知」开启推送，第一时间收到校园新动态。")
            ],
            relatedIDs: ["gs-privacy", "se-notification", "fq-restricted"]
        ),
        HelpArticle(
            id: "gs-privacy",
            categoryId: "gettingStarted",
            title: "隐私与数据安全",
            summary: "园枢如何处理你的数据：不注册、不追踪、不上传。",
            icon: "lock.shield.fill",
            tags: ["隐私", "安全", "本地存储"],
            steps: [
                HelpStep("不收集个人信息", "园枢不要求注册账号，不采集姓名、位置、通讯录、相册等任何个人信息。"),
                HelpStep("数据只存本地", "新闻、收藏、已读记录、日志等全部保存在你的设备上，不会上传到任何服务器。"),
                HelpStep("网络请求只读", "App 仅向学校官网发起读取请求（获取公开内容），不发送你的任何数据。"),
                HelpStep("查看完整协议", "完整版用户协议与隐私政策在「我的 → 隐私与协议」中可随时查阅。")
            ],
            relatedIDs: ["gs-first-launch", "se-biometric"]
        ),
        HelpArticle(
            id: "gs-permission",
            categoryId: "gettingStarted",
            title: "通知与相册权限说明",
            summary: "两个可选权限各自有什么用、如何开启或关闭。",
            icon: "bell.badge.fill",
            tags: ["权限", "通知", "相册"],
            steps: [
                HelpStep("通知权限（可选）", "用于「官网上新」推送与消息角标。开启方式：「我的 → 应用设置 → 官网上新通知」。不开也不影响浏览。"),
                HelpStep("相册权限（仅写入）", "仅在保存校园图片时请求「添加照片」权限，App 不会读取你的相册内容。"),
                HelpStep("如何撤销权限", "在系统「设置 → 园枢」中可随时关闭通知或相册权限，App 内会显示对应状态提示。"),
                HelpStep("测试推送是否正常", "「我的 → 应用设置 → 官网上新通知 → 通知测试」提供横幅、后台送达、角标等自测，不用等真实推送。")
            ],
            relatedIDs: ["se-notification", "se-log", "fq-notify"]
        ),
        HelpArticle(
            id: "gs-home-modules",
            categoryId: "gettingStarted",
            title: "定制首页模块",
            summary: "按自己的喜好排序、显示或隐藏首页内容卡片。",
            icon: "square.grid.2x2.fill",
            tags: ["首页", "模块", "排序"],
            steps: [
                HelpStep("打开模块管理", "进入「我的 → 应用设置 → 首页管理」，会看到全部 12 个内容模块。"),
                HelpStep("隐藏模块", "关闭某个模块的开关后，首页立即不再展示该卡片；数据不会丢失，重新打开即恢复。"),
                HelpStep("调整顺序", "点右上角「编辑」进入编辑模式，拖动右侧把手即可调整模块在首页的先后顺序。"),
                HelpStep("一键恢复", "页面下方「恢复默认设置」可回到初始顺序与显示状态（已是默认状态时按钮不可点）。")
            ],
            relatedIDs: ["fr-news", "fr-read", "fs-message-center"]
        ),
        HelpArticle(
            id: "gs-app-icon",
            categoryId: "gettingStarted",
            title: "更换 App 图标",
            summary: "五款图标随心切换，让主屏更有个人风格。",
            icon: "app.badge.fill",
            tags: ["图标", "个性化"],
            steps: [
                HelpStep("进入图标设置", "打开「我的 → 应用设置 → 应用图标」，能看到默认与四款备用图标的三列预览网格。"),
                HelpStep("选择图标", "点击喜欢的图标，系统会弹出确认框，点「更改」即生效；主屏图标立即更新。"),
                HelpStep("可随时换回", "任何时候都能切回默认图标，无需重启 App。"),
                HelpStep("图标不生效？", "若系统弹窗被取消或更换失败，页面会显示错误提示，重新点击即可再试。")
            ],
            relatedIDs: ["se-display", "gs-home-modules"]
        ),

        // ========== 首页与阅读（7） ==========
        HelpArticle(
            id: "fr-news",
            categoryId: "homeReading",
            title: "新闻与通知怎么读",
            summary: "资讯 Tab 的分类筛选、搜索与详情页操作一览。",
            icon: "text.document.fill",
            tags: ["新闻", "资讯", "分类"],
            steps: [
                HelpStep("浏览分类", "「资讯」Tab 顶部分类条可筛选要闻、更新、党建、通知、录取、校园等栏目，点「全部」查看完整列表。"),
                HelpStep("点开详情", "点击任意标题进入详情页：正文、图片、阅读时长、字体排版一目了然，右上角支持收藏与分享。"),
                HelpStep("复制与分享", "详情页工具栏可复制正文，或分享为链接、Markdown、纯文本与精美长图四种格式。"),
                HelpStep("回到未读位置", "已读过的文章标题变灰；未读的带蓝色小圆点，方便继续阅读。")
            ],
            relatedIDs: ["fr-read", "fr-share", "fr-search"]
        ),
        HelpArticle(
            id: "fr-read",
            categoryId: "homeReading",
            title: "阅读体验的贴心细节",
            summary: "阅读时间估算、已读标记与护眼排版。",
            icon: "book.fill",
            tags: ["阅读", "时间估算", "已读"],
            steps: [
                HelpStep("阅读时间徽章", "文章卡片与详情页顶部的彩色徽章是估算阅读时长：绿色 4 分钟内、蓝色 5-9 分钟、橙色 10-19 分钟、紫色更久。"),
                HelpStep("已读自动标记", "打开文章即自动标记为已读；也可在「我的 → 文章管理」中一键全部标记已读。"),
                HelpStep("护眼排版", "「我的 → 应用设置 → 显示设置」可调整字号、字重、行距、字体与正文颜色，让阅读更舒适。"),
                HelpStep("阅读统计", "开启阅读统计后，详情页会显示字数与预计阅读时间，辅助你安排时间。")
            ],
            relatedIDs: ["se-display", "fr-news", "fr-share"]
        ),
        HelpArticle(
            id: "fr-share",
            categoryId: "homeReading",
            title: "分享文章与长图",
            summary: "分享到微信与五种分享格式、精美长图生成指南。",
            icon: "square.and.arrow.up.fill",
            tags: ["分享", "长图", "微信"],
            steps: [
                HelpStep("分享到微信", "详情页分享按钮 →「分享到微信」，选择发送到好友 / 朋友圈 / 收藏；App 自动生成带缩略图的网页卡片，标题与摘要按微信限制自动裁剪。"),
                HelpStep("五种分享格式", "分享按钮提供五种格式：微信卡片、链接（最简）、Markdown（带来源）、纯文本（全正文）、精美长图（推荐）。"),
                HelpStep("生成长图", "选择长图后 App 自动排版生成品牌风格长图（标题、正文、每三段配一张图、来源脚注），可直接存到相册；图片较多的文章会自动控制画布尺寸以确保生成成功（极端情况会省略插图并在图尾注明）。"),
                HelpStep("长图发送到微信", "两种方式：「长图分享到微信」在 App 内直接选择好友 / 朋友圈 / 收藏；系统分享面板中的微信则以文件形式发送。长图过大时会自动压缩以符合微信图片限制。"),
                HelpStep("长图提示", "生成需要几秒，期间请勿关闭页面；完成后自动弹出对应的分享面板（微信场景菜单或系统面板）。")
            ],
            relatedIDs: ["fr-wechat", "fr-news", "fr-gallery"]
        ),
        HelpArticle(
            id: "fr-wechat",
            categoryId: "homeReading",
            title: "分享到微信与微信登录",
            summary: "把校园资讯发到微信好友 / 朋友圈 / 收藏，以及微信授权的隐私说明。",
            icon: "bubble.left.and.bubble.right.fill",
            tags: ["微信", "分享", "登录", "隐私"],
            steps: [
                HelpStep("分享到微信", "在文章详情页点击右上角分享按钮 →「分享到微信」，选择微信好友、朋友圈或微信收藏，即可发送带缩略图的网页卡片。"),
                HelpStep("分享结果提示", "发送后返回本 App 会看到结果横幅（成功 / 已取消 / 失败），同时在「我的 → 应用设置 → 日志」的 wechat 域留有完整记录。"),
                HelpStep("需要安装微信", "未安装微信或微信版本过低时，分享菜单会给出说明与安装入口，不影响链接、Markdown、长图等其他分享方式。"),
                HelpStep("微信登录说明", "「我的 → 应用设置 → 微信集成」可发起微信登录获取授权码；园枢不保存你的微信昵称、头像等个人信息。"),
                HelpStep("隐私保护", "微信相关能力仅在你主动点击时触发；隐私政策「四、信息的共享与披露」列有第三方 SDK 清单与数据处理说明。")
            ],
            relatedIDs: ["fr-share", "gs-privacy", "fq-offline"]
        ),
        HelpArticle(
            id: "fr-gallery",
            categoryId: "homeReading",
            title: "图片查看与保存",
            summary: "全屏浏览、缩放、保存校园图片到相册。",
            icon: "photo.on.rectangle.angled",
            tags: ["图片", "全屏", "保存"],
            steps: [
                HelpStep("查看大图", "点击文章内任意图片进入全屏查看，支持双指缩放与拖拽；图集模式还能左右轮播、切换网格视图。"),
                HelpStep("保存到相册", "长按图片（或图集内保存按钮）选择「保存图片」，App 申请仅写入权限后存入系统相册。"),
                HelpStep("分享图片", "长按菜单中选择「分享」可通过系统面板发送到微信、QQ 或备忘录。"),
                HelpStep("图片不显示？", "校园图片托管在校方服务器，偶尔加载慢请耐心等待；若持续失败可看「图片加载不出来」帮助条目。")
            ],
            relatedIDs: ["fr-share", "fq-image", "fr-news"]
        ),
        HelpArticle(
            id: "fr-search",
            categoryId: "homeReading",
            title: "搜索要找的内容",
            summary: "资讯搜索、机构全站搜索与专题搜索三种入口。",
            icon: "sparkle.magnifyingglass",
            tags: ["搜索", "全站", "机构"],
            steps: [
                HelpStep("资讯内搜索", "「资讯」Tab 点搜索图标，输入关键词即实时过滤当前列表的标题与摘要。"),
                HelpStep("机构全站搜索", "「院系」页切换到搜索模式，可跨主站与全部机构子站检索文章，深度搜索能翻到更久远的内容。"),
                HelpStep("党建专题搜索", "党建专题内支持多关键词组合搜索，标题、描述、标签综合匹配并显示两站命中分布。"),
                HelpStep("校长信箱搜索", "想找某封历史来信？信箱页搜索框支持按信件与回复标题全文匹配。")
            ],
            relatedIDs: ["fs-party", "fs-org", "fs-mailbox"]
        ),
        HelpArticle(
            id: "fr-admission",
            categoryId: "homeReading",
            title: "招生信息去哪看",
            summary: "招生网入口与录取相关内容的查看路径。",
            icon: "graduationcap.fill",
            tags: ["招生", "录取", "专业"],
            steps: [
                HelpStep("招生网入口", "底部「资讯」Tab 顶部分类条点「招生」，直达招生网首页（仅在招生数据可用时显示该分类）。"),
                HelpStep("招生栏目", "招生网包含快捷入口（录取查询、历年分数线、专业介绍）、招生计划、招生公告、报考指南、招生动态等栏目，数据与学校招生官网同步。"),
                HelpStep("专业介绍", "「院系」中的各学院详情页内含专业介绍入口，可查看培养方向与就业去向。"),
                HelpStep("录取查询", "招生网内的录取查询会跳转到学校官方查询页，请以官网信息为准。")
            ],
            relatedIDs: ["fr-search", "fr-news"]
        ),

        // ========== 特色功能（7） ==========
        HelpArticle(
            id: "fs-message-center",
            categoryId: "features",
            title: "消息中心完全指南",
            summary: "五类站内消息怎么看、怎么清理、怎么直达原文。",
            icon: "bell.badge.fill",
            tags: ["消息中心", "站内信", "角标"],
            steps: [
                HelpStep("入口在哪", "「我的」页面第一张卡就是消息中心；列表标题旁的徽标数字是未读条数。"),
                HelpStep("五类消息", "消息分为新闻、校长信箱、学校概况、党建专题、收藏更新五个通道，可点顶部筛选分类查看。"),
                HelpStep("快捷操作", "右滑消息可标记已读/未读；左滑删除；长按弹出复制、分享与阅读状态菜单。"),
                HelpStep("点击直达", "点击消息会自动消除未读并打开对应内容：新闻直达文章、信箱直达信件、概况与党建直达专题页。"),
                HelpStep("清理与角标", "右上角铃铛可全部已读；设置面板可按范围清空历史，并可关闭桌面角标联动。")
            ],
            relatedIDs: ["se-notification", "fs-search-help", "fq-notify"]
        ),
        HelpArticle(
            id: "se-notification",
            categoryId: "features",
            title: "官网上新推送怎么开",
            summary: "开启推送、设置轮询频率、理解推送逻辑。",
            icon: "dot.radiowaves.left.and.right",
            tags: ["通知", "推送", "轮询"],
            steps: [
                HelpStep("开启开关", "「我的 → 应用设置 → 官网上新通知」打开总开关，并按提示允许系统通知权限。"),
                HelpStep("选择检查频率", "支持 15 / 30 / 60 / 120 分钟四档检查间隔，默认 30 分钟；频率越高越及时、耗电略增。"),
                HelpStep("推送什么内容", "新闻更新、校长信箱新回复、学校概况变化、党建专题更新、收藏文章更新五类，点击通知直达对应内容。"),
                HelpStep("不推送的原因", "请在「常见问题 › 收不到推送通知」中排查：总开关、系统权限、低电量模式与隐私同意状态。")
            ],
            relatedIDs: ["fq-notify", "fs-message-center", "gs-permission"]
        ),
        HelpArticle(
            id: "fs-mailbox",
            categoryId: "features",
            title: "校长信箱使用说明",
            summary: "查看公开来信、搜索历史信件、联系反馈。",
            icon: "envelope.open.fill",
            tags: ["校长信箱", "来信", "反馈"],
            steps: [
                HelpStep("查看来信", "首页「校长信箱」卡或专题页可浏览师生来信与校方回复，数据与官网信箱同步。"),
                HelpStep("搜索历史信件", "页面顶部搜索框支持按来信与回复标题全文检索，最多保留 10 条搜索历史。"),
                HelpStep("写信与电话", "页面提供监督电话、邮箱与官网来信入口，点击即可拨号或跳转官网发信。"),
                HelpStep("新回复提醒", "开启推送后，信箱出现新回复会收到系统通知，点击直达对应信件。")
            ],
            relatedIDs: ["fs-message-center", "fr-search", "se-notification"]
        ),
        HelpArticle(
            id: "fs-profile",
            categoryId: "features",
            title: "学校概况看什么",
            summary: "七个标签页查询学校简介、领导信息与校园风光。",
            icon: "building.columns.fill",
            tags: ["学校概况", "风光", "校园"],
            steps: [
                HelpStep("七个标签页", "学校概况包含学校简介、现任领导、识别系统、学校宣传片、校歌、校园风光、合作交流七个标签页，顶部 tab 切换。"),
                HelpStep("统计数字", "在校生、专业、机构等数据带滚动展示动效，数据来自学校官网并定期刷新。"),
                HelpStep("风光图集", "风光图片可全屏浏览、保存到相册或分享；图集支持轮播与网格两种模式。"),
                HelpStep("手动刷新", "下拉或点工具栏刷新会强制拉取最新数据并更新详情缓存。")
            ],
            relatedIDs: ["fs-party", "fr-gallery", "gs-first-launch"]
        ),
        HelpArticle(
            id: "fs-party",
            categoryId: "features",
            title: "党建专题怎么用",
            summary: "党建工作与思政专题的双站聚合、搜索与深读。",
            icon: "flag.fill",
            tags: ["党建", "思政", "专题"],
            steps: [
                HelpStep("两个站点", "党建专题聚合「党建工作」与「思政专题」两个子站，顶部切换或浏览全部内容。"),
                HelpStep("组合搜索", "支持按空格分词的多关键词组合检索（词与词为「与」关系），按相关度排序并显示两站命中徽章。"),
                HelpStep("深度搜索", "常规结果不足时点「深度搜索」会继续翻取更多历史文章。"),
                HelpStep("进入入口", "首页「党建专题」卡与底部通知直达都能进入，内容与站点实时同步。")
            ],
            relatedIDs: ["fs-profile", "fr-search", "fs-org"]
        ),
        HelpArticle(
            id: "fs-org",
            categoryId: "features",
            title: "机构与全站搜索",
            summary: "按部门分类找机构、跨全站搜资料。",
            icon: "building.2.fill",
            tags: ["机构", "部门", "全站搜索"],
            steps: [
                HelpStep("浏览机构", "「院系」页按党委机构、群团机构、行政机构、教学机构、教辅机构五类展示全部机构，点卡片进入机构主页。"),
                HelpStep("机构主页", "机构主页展示该部门的最新文章、通知与子栏目，数据实时同步官网。"),
                HelpStep("全站搜索", "切换到搜索模式输入关键词，会同时检索主站与全部机构子站，边搜边出结果并显示进度。"),
                HelpStep("深度检索", "常规结果不含你要的内容时，点「深度检索」翻取更多页，覆盖更久远的历史文章。")
            ],
            relatedIDs: ["fr-search", "fs-party", "fq-search"]
        ),

        // ========== 设置与个性化（6） ==========
        HelpArticle(
            id: "se-display",
            categoryId: "settings",
            title: "显示设置全攻略",
            summary: "字体、字号、主题色、正文颜色一站式调整。",
            icon: "textformat.size",
            tags: ["显示", "字体", "主题"],
            steps: [
                HelpStep("全局字号", "「我的 → 应用设置 → 显示设置」提供六档字号与加粗开关，全 App 即时生效。"),
                HelpStep("字体家族", "苹方、宋体、楷体、圆体、行楷、隶变、魏碑七款中文全字形家族可选；书法字体首次使用需联网下载一次（单款约 17–55 MB），进度环实时可见，下载后离线可用、即刻全 App 生效。"),
                HelpStep("主题色", "五种主题色实时切换按钮、图标等强调色；支持跟随系统深浅色模式。"),
                HelpStep("正文颜色", "阅读页正文提供 8 套配色 + 自定义取色，护眼常在。"),
                HelpStep("全链一致", "以上字号、字体、行距、字距、配色与外观模式在全 App 每一处生效：文章详情、列表卡片、机构子站原文页、各类弹出面板与专注灰度均保持一致。")
            ],
            relatedIDs: ["se-awake", "fr-read", "gs-app-icon"]
        ),
        HelpArticle(
            id: "se-awake",
            categoryId: "settings",
            title: "屏幕常亮功能",
            summary: "阅读与查看时保持屏幕不熄灭。",
            icon: "sun.max.fill",
            tags: ["常亮", "屏幕", "低电量"],
            steps: [
                HelpStep("开启常亮", "「我的 → 应用设置 → 显示设置 → 屏幕常亮」打开开关，呼吸绿点表示正在生效。"),
                HelpStep("原理", "开启后与系统「自动锁定＝永不」取或逻辑，App 会主动维护熄屏计时，向下滚动停顿时自动修复。"),
                HelpStep("低电量注意", "低电量模式下系统可能强制熄屏，页面会显示橙色提示；建议此时关闭常亮以省电。"),
                HelpStep("关闭后", "关闭开关会显式复位系统计时器，恢复你原有的自动锁定设置。")
            ],
            relatedIDs: ["se-display", "se-cache"]
        ),
        HelpArticle(
            id: "se-cache",
            categoryId: "settings",
            title: "缓存模式与流量",
            summary: "缓存策略与流量统计怎么看。",
            icon: "internaldrive.fill",
            tags: ["缓存", "流量", "省流"],
            steps: [
                HelpStep("两种模式", "「我的 → 应用设置 → 缓存模式」提供两种模式：开启缓存模式后已浏览内容自动缓存、再次访问秒开省流量；即时刷新则每次实时加载最新内容。"),
                HelpStep("无图模式", "开启「无图模式」后所有图片位置显示占位图标，极大节省流量，可随时关闭。"),
                HelpStep("流量统计", "页面内可查看命中率、节流字节数与图片缓存用量，数据实时累计。"),
                HelpStep("清空缓存", "「图片缓存中心」与「数据管理」可一键清空缓存，释放存储空间；清空后重新加载需要联网。")
            ],
            relatedIDs: ["fq-offline", "fq-image", "se-network"]
        ),
        HelpArticle(
            id: "se-network",
            categoryId: "settings",
            title: "网络监测面板",
            summary: "实时链路状态、吞吐与主动探测。",
            icon: "wave.3.right",
            tags: ["网络", "监测", "探测"],
            steps: [
                HelpStep("打开面板", "「我的 → 应用设置 → 网络监测」展示当前网络类型与链路质量。"),
                HelpStep("仪表盘", "吞吐速率、延迟直方图、请求统计、流量级别一屏掌握。"),
                HelpStep("主动探测", "点「探测」按钮对学校服务器做冷连接测试，分阶段展示 DNS / TCP / TLS / 首字节耗时。"),
                HelpStep("什么时候用", "页面加载异常时可先到这里看链路状态：延迟高或探测失败大概率是网络或学校服务器问题。")
            ],
            relatedIDs: ["se-cache", "fq-offline"]
        ),
        HelpArticle(
            id: "se-biometric",
            categoryId: "settings",
            title: "生物识别隐私锁",
            summary: "用 Face ID / Touch ID 守护隐私页面。",
            icon: "faceid",
            tags: ["安全", "Face ID", "隐私"],
            steps: [
                HelpStep("开启安全锁", "「我的 → 应用设置 → 安全中心」打开生物识别开关，录入过程调用系统 Face ID / Touch ID。"),
                HelpStep("锁定时机", "开启后退到后台立即锁定（可按策略延迟 1/5 分钟），回到前台需验证；多任务切换器中的预览也会被遮挡。"),
                HelpStep("手动锁定", "设置页的「立即锁定」可随时手动上锁；锁屏遮罩支持指纹图标验证。"),
                HelpStep("生物数据安全", "验证完全由系统安全芯片完成，App 不接触也不存储任何生物特征，仅保存一枚本地令牌。")
            ],
            relatedIDs: ["gs-privacy", "fq-faceid"]
        ),
        HelpArticle(
            id: "se-log",
            categoryId: "settings",
            title: "应用日志是什么",
            summary: "开发者视角的运行记录、筛选与导出。",
            icon: "list.bullet.rectangle.fill",
            tags: ["日志", "调试", "导出"],
            steps: [
                HelpStep("打开日志", "「我的 → 应用日志」按日期列出全部运行记录，支持按模块、级别、关键词筛选。"),
                HelpStep("看懂级别", "绿＝信息、蓝＝调试、黄＝警告、红＝错误；每个模块用短名标记（如 sync＝同步、notification＝通知）。"),
                HelpStep("导出反馈", "遇到问题时点「导出」生成文本文件，配合问题描述一起反馈，能大幅加速定位。"),
                HelpStep("存储策略", "日志只保存在本机，按时间自动清理；可在日志设置中开关调试日志与崩溃捕获。")
            ],
            relatedIDs: ["se-network", "fq-notify", "gs-permission"]
        ),

        // ========== 常见问题（6） ==========
        HelpArticle(
            id: "fq-offline",
            categoryId: "faq",
            title: "内容不更新 / 显示旧数据",
            summary: "按顺序排查：网络、同步节流、缓存模式与服务器状态。",
            icon: "arrow.triangle.2.circlepath",
            tags: ["不更新", "同步", "缓存"],
            steps: [
                HelpStep("第一步：下拉刷新", "首页或列表向下拉即可强制同步（跳过 10 分钟节流），看顶部进度胶囊是否转起来。"),
                HelpStep("第二步：检查缓存模式", "若开启了「缓存模式」，已浏览页面可能优先展示本地缓存的旧内容；切回「即时刷新」再试。"),
                HelpStep("第三步：看网络监测", "「我的 → 应用设置 → 网络监测」点探测：若学校服务器不通，耐心等待几小时再试。"),
                HelpStep("仍是旧数据？", "「我的 → 应用设置 → 数据管理」可清空缓存并恢复预置数据，重新启动即会全量同步。")
            ],
            relatedIDs: ["se-cache", "se-network", "se-log"]
        ),
        HelpArticle(
            id: "fq-notify",
            categoryId: "faq",
            title: "收不到推送通知",
            summary: "六个常见原因逐个排除。",
            icon: "bell.slash.fill",
            tags: ["推送", "通知", "排查"],
            steps: [
                HelpStep("总开关没开", "「我的 → 应用设置 → 官网上新通知」确认总开关已打开（默认关闭）。"),
                HelpStep("系统权限", "系统「设置 → 园枢 → 通知」确认允许通知；App 内授权状态一栏会实时显示。"),
                HelpStep("隐私未同意", "拒绝过隐私协议时数据采集与推送会停止，重新同意后恢复。"),
                HelpStep("检查频率太慢", "轮询间隔默认 30 分钟，可改为 15 分钟；也可以点「立即检查更新」手动触发。"),
                HelpStep("低电量模式", "系统低电量模式会限制后台行为，但仍可在前台正常接收。"),
                HelpStep("用测试中心自测", "「我的 → 应用设置 → 官网上新通知 → 通知测试」可逐项验证横幅、送达、角标，哪项失败就定位到哪。")
            ],
            relatedIDs: ["se-notification", "gs-permission", "se-log"]
        ),
        HelpArticle(
            id: "fq-image",
            categoryId: "faq",
            title: "图片加载不出来",
            summary: "从无图模式到网络链路的分层排查。",
            icon: "photo.badge.exclamationmark",
            tags: ["图片", "加载失败", "排查"],
            steps: [
                HelpStep("检查无图模式", "缓存模式中若开启「无图模式」，所有图片会显示占位图标——关闭即可恢复。"),
                HelpStep("检查网络", "图片托管在校方服务器，移动网络可能较慢；用网络监测面板确认链路。"),
                HelpStep("重试轻点", "图片区出现闪电图标时可轻点重试，App 会自动带三次退避重试。"),
                HelpStep("清理后重载", "「缓存模式 → 图片缓存中心」清空图片缓存后回到页面重新加载。")
            ],
            relatedIDs: ["se-cache", "se-network", "fr-gallery"]
        ),
        HelpArticle(
            id: "fq-search",
            categoryId: "faq",
            title: "搜索不出结果",
            summary: "关键词技巧与深度搜索的正确姿势。",
            icon: "magnifyingglass",
            tags: ["搜索", "关键词"],
            steps: [
                HelpStep("精简关键词", "先试 2-4 字的短词（如「奖学金」），避免整句输入；多词会按「全部命中」求交集。"),
                HelpStep("试试深度搜索", "机构与党建搜索提供「深度搜索/深度检索」按钮，会翻取 8 页历史数据。"),
                HelpStep("换范围", "机构搜索可按栏目范围过滤（全部/要闻/资讯/党建/通知），范围越小命中越快。"),
                HelpStep("内容可能不存在", "学校官网本身没有的内容 App 也无法搜索到，可在官网确认后再试。")
            ],
            relatedIDs: ["fr-search", "fs-org", "fs-party"]
        ),
        HelpArticle(
            id: "fq-faceid",
            categoryId: "faq",
            title: "Face ID 验证不通过",
            summary: "锁死、连续失败与设备密码降级的处理。",
            icon: "faceid",
            tags: ["Face ID", "锁定", "降级"],
            steps: [
                HelpStep("连续失败保护", "连续失败 5 次后会自动降级为设备密码验证，避免生物识别误锁。"),
                HelpStep("系统生物识别锁定", "若系统 Face ID 被锁（需密码解锁），App 会提示前往系统设置处理。"),
                HelpStep("换设备后", "生物令牌绑定本机安全芯片，卸载重装或更换设备后需要重新开启安全锁。"),
                HelpStep("不想用了", "「安全中心」关闭开关需再验证一次身份，成功后立即解除所有锁定。")
            ],
            relatedIDs: ["se-biometric", "gs-privacy"]
        ),
        HelpArticle(
            id: "fq-restricted",
            categoryId: "faq",
            title: "受限模式与退出",
            summary: "拒绝隐私协议后的状态说明与恢复方法。",
            icon: "nosign",
            tags: ["受限模式", "隐私", "恢复"],
            steps: [
                HelpStep("为什么会受限", "首次启动选择「不同意」后进入受限模式：不联网、不同步、不推送，仅保留内置内容。"),
                HelpStep("如何恢复", "受限页点击「查看并同意」，重新同意后即可恢复完整功能。"),
                HelpStep("退出应用", "受限模式提供「退出应用」按钮（请理解：iOS 惯例是回到主屏关闭，App 不会常驻后台）。"),
                HelpStep("数据会保留吗", "恢复后设置、收藏与缓存均完好，无需重新配置。")
            ],
            relatedIDs: ["gs-first-launch", "gs-privacy"]
        ),

        // ========== 帮助中心自身说明 ==========
        HelpArticle(
            id: "fs-search-help",
            categoryId: "features",
            title: "使用帮助怎么搜",
            summary: "帮助中心自身的搜索技巧与已读管理。",
            icon: "text.magnifyingglass",
            tags: ["帮助", "搜索", "已读"],
            steps: [
                HelpStep("搜索所有条目", "帮助中心顶部搜索框覆盖全部分类与文章：标题权重最高，其次是摘要、标签与正文步骤。"),
                HelpStep("多词组合", "按空格分词的多关键词组合为「与」关系，例如输入「通知 推送」能同时定位推送开启与排查两篇。"),
                HelpStep("常用关键词高亮", "结果中命中的关键词以橙色高亮显示，方便快速定位。"),
                HelpStep("管理阅读状态", "读过的文章显示为已读；列表右上角可一键全部标记已读。")
            ],
            relatedIDs: ["fs-message-center", "fr-search"]
        )
    ]

    // MARK: 查询

    /// 按 id 取文章
    static func article(_ id: String) -> HelpArticle? {
        articles.first { $0.id == id }
    }

    /// 分类下的文章（保持目录顺序）
    static func articles(inCategory categoryId: String) -> [HelpArticle] {
        articles.filter { $0.categoryId == categoryId }
    }

    /// 文章所属分类
    static func category(of article: HelpArticle) -> HelpCategory? {
        categories.first { $0.id == article.categoryId }
    }

    /// 相关文章
    static func related(to article: HelpArticle) -> [HelpArticle] {
        article.relatedIDs.compactMap { Self.article($0) }
    }
}