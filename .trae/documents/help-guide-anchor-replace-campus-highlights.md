# 首页「校园亮点」替换为「使用帮助」锚点横卡 — 实施计划

> 修订记录：V2 修复无障碍合并范围、补开关过渡动画、进度环开场动效、呼吸光点；V3 亲自核验 NavigationStack 结构（TabBar L147 Home tab 独立 NavigationStack ✓、HomeView 无既有 sheet/destination ✓、hiddenModules 为 Set<HomeModule> 可作 animation value ✓、测试无 mediaLinks/HomeModule 引用 ✓），补推送系统技术结论声明，卡片改为标题行带未读徽章 + 副标题行带已读百分比的双行布局；V4 全工程 grep「校园亮点」发现第三条引用（HomeModuleManager.swift L13 注释），补入改动清单。

## Context（背景与目标）

用户反馈：首页「校园亮点」模块（campusHighlightsSection，TabBar.swift L785-830）没有多大作用、很多入口打不开。已核实属实：

- 该区块 5 个入口（学校宣传片/晋理校歌/抖音平台/VR校园/校园风光）全部是 WebView 外链（Models.swift L752-766 mediaLinks）；
- 其中 3 个入口（宣传片/VR校园/校园风光）URL 完全相同（`https://www.sxjzit.edu.cn/#/campus`），内容与标题不对应（VR 内容官网不存在）；
- 抖音主站 WebView 在移动端基本不可用（引导下载 App/验证）；curl 实测官网 200、抖音 200（可达不等于可用）。
- App 内宣传片/校歌本有原生能力（SchoolProfileStore.promoVideoURL/songVideoURL，学校概况模块内嵌 AVKit 播放）；校园风光有原生模块（学校概况风光 tab + 首页 campusSceneries 模块）——替换不造成信息丢失。

**目标**：删除「校园亮点」区块，原位置渲染「使用帮助」升级横卡（用户已确认：保留「首页管理」开关 + 升级横卡形态，"越完美越好"）。

设计依据（iOS 26 Liquid Glass 官方资料）：WWDC25《Build a SwiftUI app with the new design》《Adopting Liquid Glass》《Applying Liquid Glass to custom views》、Apple HIG——内容优先、玻璃材质层叠、动效平滑、深浅模式自适应；工程已有 `.glassEffect()`/`.ultraThinMaterial` + SJZDesignTokens.capsuleStroke 惯例（TabBar L540-542）。

**推送系统声明**：使用帮助为纯本地内置内容（无服务端更新源），没有可轮询的"变化"事件，不接入现有四通道推送轮询（避免无意义请求）；与推送系统无冲突、互不影响——此为技术结论，非遗漏。未来若帮助库改为远端下发，可复用 NotificationManager 四通道模式扩展。

## 决策（已与用户确认）

1. 校园亮点区块整体删除；替换为使用帮助升级横卡（helpGuideAnchorSection），位置=原固定区块位置（heroBanner→statsRow→quickActions 之后、模块循环之前）。
2. 「我的→应用设置→首页管理」保留「使用帮助」开关：新卡渲染条件 `homeModules.isVisible(.helpGuide)`；模块循环 ForEach 排除 .helpGuide 避免双份渲染；HomeModuleManager 零改动。
3. 卡片形态：升级横卡（渐变图标块 + 标题 + N 篇指南·未读徽章 + 最近阅读一键续读 + 阅读进度环 + 玻璃质感 + 入场动效 + 完整日志）。
4. Models.swift 删除 MediaLink/mediaLinks 死数据（全工程仅 TabBar L799 一处引用，删除后无引用）。

## 文件级改动

### 1. TabBar.swift（主要改动）

- **body L501**：`campusHighlightsSection` → `helpGuideAnchorSection`。
- **ForEach L509**：`.filter { hasContent($0) && $0 != .helpGuide }`（SJZRevealOnce 的 index delay 自动前移，无需改）。
- **删除 L785-830** campusHighlightsSection 整段。
- **moduleSection case .helpGuide（L978-980）**：`case .helpGuide: EmptyView() // 渲染已提升为固定区锚点卡（helpGuideAnchorSection），此处为防御死码`（switch 穷举必须保留 case）。
- **删除 L1425-1489 旧 helpGuideSection**，原位写新 `helpGuideAnchorSection` + `cardMain` + `continueRow` + 两个动作函数。
- **新增 @State（L490 附近）**：`@State private var showHelpCenter = false`、`@State private var selectedHelpArticle: HelpArticle?`。
- **body 顶层挂载（.refreshable 修饰链上，不放新卡内部——条件分支内挂 destination 会在卡隐藏时失效）**：
  - `.navigationDestination(isPresented: $showHelpCenter) { HelpGuideView() }`
  - `.sheet(item: $selectedHelpArticle) { article in NavigationStack { HelpArticleDetailView(article: article) } }`

新卡骨架（草稿，实现时按工程风格精修）：

```swift
private var helpGuideAnchorSection: some View {
    if homeModules.isVisible(.helpGuide) {
        VStack(spacing: 10) {
            Button { openHelpCenter() } label: { cardMain }   // 卡主体
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)    // 只在卡主体上合并，
                .accessibilityAddTraits(.isButton)           // 保证「继续阅读」是独立可激活元素
                .accessibilityAction { openHelpCenter() }
            if let recent = helpGuideStore.recentArticles.first {
                Button { openContinueReading(recent) } label: { continueRow(recent.title) }
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SJZDesignTokens.capsuleStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
        .padding(.horizontal, 16).padding(.top, 28)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))   // 开关切换时的出入场
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: homeModules.hiddenModules)
        .scaleEffect(sectionsAppear ? 1 : 0.92)
        .opacity(sectionsAppear ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.12), value: sectionsAppear)
        .onAppear {
            // 进度环开场：0 → 真实进度的一次性弹簧动画（锚点卡专属动效）
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) {
                anchorRingProgress = helpGuideStore.readProgress
            }
            LogManager.shared.info("helpGuide", "首页使用帮助锚点卡展示", context: [
                "total": "\(helpGuideStore.totalArticles)",
                "unread": "\(helpGuideStore.unreadCount)",
                "progress": "\(Int(helpGuideStore.readProgress * 100))",
                "visible": "\(homeModules.isVisible(.helpGuide))"
            ])
        }
        .onChange(of: helpGuideStore.readProgress) { _, newValue in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { anchorRingProgress = newValue }
        }
    }
}
```

- **新增 @State（L490 附近）**：`@State private var anchorRingProgress: Double = 0`（进度环开场/联动动画源，展示值取自 helpGuideStore.readProgress）。
- **cardMain**：HStack = 左 52×52 渐变问号图标块（sjzAccent→4F8EF7，白色 questionmark.circle.fill 20pt，shadow accent 0.35）+ 中部 VStack 两行：
  - 行 1（标题行）：Text「使用帮助」17 bold primary + Spacer + 未读>0 时徽章（5pt sjzOrange 呼吸光点（1s 周期 opacity 呼吸）+「未读 N」白字 10 bold 于 sjzOrange→sjzRed 渐变胶囊内，出现时 `.transition(.scale.combined(with: .opacity))`）；
  - 行 2（副标题行）：`\(totalArticles) 篇指南 · 已读 \(Int(readProgress*100))%` 11 secondary lineLimit(1)，`.animation(.spring(response: 0.4, dampingFraction: 0.85), value: helpGuideStore.unreadCount)` 联动；
  - + Spacer(minLength: 8) + 右侧 30pt 进度环（accent 0.15 底环 + `trim(from: 0, to: anchorRingProgress <= 0 ? 0 : max(0.02, anchorRingProgress))` 进度环 stroke lineCap round）+ chevron.right 11pt tertiary。全部 displayFont/displaySymbolFont；不固定高度（大字号安全）；副标题 truncationMode 默认 tail。
- **continueRow**：紧凑条（clock.arrow.circlepath 12 + 「继续阅读：《title》」12 secondary lineLimit(1) + Spacer + arrow.up.left 9），`.padding(.horizontal, 12).padding(.vertical, 9)`，背景 RoundedRectangle(12) 填 `colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)`，`.contentShape(Rectangle())`，`.accessibilityLabel("继续阅读：\(title)")`。

动作函数（触觉 + helpGuide 日志 + recordOpen 语义与帮助页一致）：

```swift
private func openHelpCenter() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    LogManager.shared.info("helpGuide", "首页使用帮助锚点卡点击", context: [
        "source": "home_anchor",
        "total": "\(helpGuideStore.totalArticles)", "unread": "\(helpGuideStore.unreadCount)"])
    showHelpCenter = true
}
private func openContinueReading(_ article: HelpArticle) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    helpGuideStore.recordOpen(article)   // 已读 + 写入最近阅读（与 HelpGuideView.openArticle 同语义）
    LogManager.shared.info("helpGuide", "首页使用帮助最近阅读直达", context: [
        "articleId": article.id, "source": "home_anchor_continue"])
    selectedHelpArticle = article
}
```

### 2. Models.swift

- 删除 L749-765：`// MARK: - 特色媒体链接` + `struct MediaLink` + `let mediaLinks`（删除前再 grep 全工程确认无其他引用，含 DesignCodeTests）。

### 3. HomeModuleManager.swift

- L13 头注释：`固定区块（顶部 Banner、数据统计、快捷入口、校园亮点）` → `固定区块（顶部 Banner、数据统计、快捷入口）`（仅注释措辞，无逻辑改动；使用帮助仍在可管理列表中）。

### 4. HomeModuleSettingsView.swift

- L29 footer 文案：`…快捷入口与校园亮点为固定区域…` → `…快捷入口为固定区域…`（使用帮助仍可开关，不能写成固定区域）。

## 日志埋点清单（helpGuide 域，接入现有 LogManager）

1. 锚点卡展示（onAppear）：total / unread / progress / visible。
2. 锚点卡主体点击：source=home_anchor（替代原入口卡点击日志）。
3. 最近阅读直达：source=home_anchor_continue，含 articleId。
4. 详情 sheet 关闭 debugLog（沿用 HelpGuideView 惯例，可选加）。
5. HomeModuleSettingsView 的 helpGuide 开关切换日志已有（home_modules 域），不动。

## 工程红线（必须遵守）

- 文本 .displayFont / 符号 .displaySymbolFont；所有可点视图 .contentShape(Rectangle())。
- 禁 @AppStorage+didSet；不动 HomeModuleManager / HelpGuideStore 逻辑。
- navigationDestination(isPresented:) 官方推荐（工程红线：禁用 NavigationStack(path:) 编程 push）；destination/sheet 挂 HomeView body 顶层锚点，不挂条件分支内部。
- 不动 pbxproj；不新增文件；46/46 测试必须保持全绿。
- sf symbol 全部使用已存在符号；新卡不改 HelpContent 内容。

## 验证（真机 UDID 00008110-000411A40EC1401E）

1. `set -o pipefail; xcodebuild test ... | grep ...` → ** TEST SUCCEEDED ** + 46/46 + 0 错误 0 代码警告。
2. 手动验收点：
   - 首页固定区新卡显示：徽章/进度环/最近阅读三态（无未读、有未读、无最近阅读不显示续读行；未读=0 时显示「已读 NN%」）；
   - 进场动效：进度环从 0 弹簧滚到真实进度、卡入场 scale+opacity、未读光点呼吸；
   - 卡主体点击 → 进帮助中心；续读行点击 → 直达文章详情，返回后进度环/最近阅读更新；
   - 「应用设置→首页管理」关「使用帮助」→ 固定区卡经过渡动画消失；再开 → 恢复（卡隐藏时 navigationDestination 仍有效——挂在 body 顶层）；
   - 模块循环中无重复帮助卡；排序/隐藏其他模块不受影响；
   - VoiceOver：卡主体与「继续阅读」为两个独立可激活元素；
   - 深色模式、大字号（Dynamic Type 中档放大）不裁切；
   - 冷启动骨架屏场景：新卡即时显示（helpGuideStore 本地即时）；
   - 通知 sheet / 消息中心弹窗无冲突（HomeView 本身新增 sheet 仅 item 型、互不干扰）。