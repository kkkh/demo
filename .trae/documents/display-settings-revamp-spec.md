# 显示设置模块 — 艺术级全面改造规格书 v4（终极复核版）

## Context（背景与意图）

「园枢」App「我的 → 应用设置 → 显示设置」模块（DisplaySettingsManager.swift 1786 行 + DisplaySettingsView.swift 1091 行）是全局显示中枢。用户要求：全面艺术级升级——最豪华设计、极致动效、顶级配色、功能越完整越好、100% 可用、完整日志埋点、不影响其他功能、复核到完美。

**既有成果冻结**：阅读统计引擎与 idle timer 逻辑；全部持久化键与消费点签名；消费方（长图分享器、SchoolInfoCard、PartySubjectView、OrganizationDetailView、SchoolProfileView）零影响。

**联动链复核结论**：appearanceKey 与 TabBar @AppStorage 同键联动；BookmarkListView/SplashView 的 preferredColorScheme 仅为 #Preview 宏（误报排除）。

## 〇、设计依据（全网搜集）

**HIG 硬指标（本规格宪法）**：iOS 最小字号 11pt（审计：最小渲染 11.9pt 合规）；对比度 WCAG AA ≤17pt 文本 4.5:1；文案放大 ≥200% 支持；避免 Light 字重；最小化字体种数；重要内容优先缩放；不单独依赖颜色传达；Accessibility Inspector 纳入验证。
**2026 Apple Design Awards**：grug 极简不堆砌；Guitar Wiz 无障碍三件套；Pine Hearts 可调动效；Is This Seat Taken 处处细节。

## 一、现状定位（用户视角痛点）

1. 视觉叙事弱：10 Section 平铺、无 Hero、主题色仅 5 圆点
2. 动效贫乏：仅 checkmark 过渡
3. 功能缺口：无排版方案套装、字体家族无真实字貌、行距/字距无 A/B 对照与**标尺可视化**、亮度无快捷预设、正文色无纸面预览/历史/**对比度校验**、systemDarkerColors 已监听未展示、无变更历史、**无全局专注模式（灰度）**
4. 埋点缺口：无页面停留、无 Section 曝光

## 二、功能维度清单（19 项新增，全部真实可用）

| # | 功能 | 说明 |
|---|---|---|
| F1 | 艺术级 Hero 头卡 | aurora 渐变 + Liquid Glass + 呼吸 + 慢扫光；8 维设置全景实时预览；非默认项计数徽章 |
| F2 | 外观模式卡式选择器 | 3 模式横排卡 + glassEffect 选中态 + symbolEffect(bounce) + 涟漪 |
| F3 | 主题图鉴 | 5 主题色渐变圆徽章 + 色名 + 选中描边 + 涟漪扩散 |
| F4 | 排版方案套装 | 3 套一键方案（阅读舒适 1.12/1.25/0.2、紧凑高效 0.94/0.95/0、护眼大字 1.26/1.45/0.5）；套用动画 + toast + 日志 |
| F5 | 字体家族真实字貌预览 | 家族名以自身字体渲染 + 选中描边 |
| F6 | 行距/字距 A/B 对照卡 | 同段落当前 vs 默认左右对照，实时滑动渲染 |
| F7 | 字号滑动刻度卡 | 6 档滑块 + 档位名 + 缩放系数读数 |
| F8 | 正文色纸面预览 | 白纸/深纸双面模拟（报纸阅读场景） |
| F9 | 自定义色历史 | 最近 6 色 ring buffer（去重置顶） |
| F10 | 随机和谐色骰子 | 固定 HSL 同明度随机相邻色 |
| F11 | 亮度快捷预设 | 25/50/75/100% 四档胶囊 + 光感太阳随亮度缩放 |
| F12 | 辅助功能补全 | 「更深颜色」+ VoiceOver 运行状态行（新增监听） |
| F13 | 变更历史时间轴 | 最近 20 条 ring buffer + 错峰入场 + 清空 |
| F14 | 页面停留/曝光埋点 | onAppear/onDisappear 停留时长 + Section 首曝（session 去重） |
| F15 | 分享排版摘要 | ShareLink 生成当前显示配置文本 |
| F16 | SettingsView 摘要行升级 | 「外观 · 字号 · 主题色」+ 非默认计数徽章（TabBar L9029-9036，≤10 行） |
| F17 | 正文色对比度自检 | 白纸/深纸双环境 WCAG AA 实时计算 + 绿/橙/红徽章 + 建议（纯函数可测） |
| F18 | **专注灰度模式** | App 内全局去饱和开关：根视图注入 `.saturation(0/1)`（displayTypography 链上单点添加，关闭即 100% 恢复）；辅助功能 Section 开关 + 状态胶囊 + 日志；说明文案「图片与配色将转为灰度，专注文字阅读」 |
| F19 | **排版标尺可视化** | A/B 对照卡与 Hero 预览段落叠加「字距刻度尺」（当前字距下字符位点标记）与「行距基线网格」（当前行距下基线横线），随滑块实时位移——把抽象数值变成可丈量的艺术细节 |

## 三、组件级动效明细表

| 组件 | 入场 | 选中/按压 | 持续态 | 时长/节奏 |
|---|---|---|---|---|
| Hero 头卡 | SJZRevealOnce 淡入+上移 8pt | 无 | 呼吸亮度 1.0↔1.06；扫光 mask 平移 | 呼吸 2.4s；扫光 3.2s 单次 |
| 模式选择卡 | 错峰 60ms×序 | 按压 scale 0.97 spring(0.4,0.75) | 玻璃 tint 随主题色 | 0.32s |
| 选中玻璃 | opacity+scale 合入 | symbolEffect(.bounce) | — | 0.35s |
| 主题图鉴徽章 | 错峰 60ms×序 | 白色涟漪 0→60pt | 选中呼吸微光 | 涟漪 0.35s |
| 排版方案卡 | 错峰 | 按压 border 泛光 | — | 0.3s |
| A/B 对照卡 | RevealOnce | — | 左卡随滑块即时重排 | 直接跟随 |
| **排版标尺** | 随卡 RevealOnce | — | 刻度/基线随滑块垂直位移 | 直接跟随（无独立动画） |
| 字号刻度 | RevealOnce | 档位 snap spring(0.32,0.8) | — | — |
| 状态胶囊 | scale 0.85 合入 | — | 已生效绿点脉动 | 0.8s 往复 |
| 时间轴条目 | 顶部插入 move+opacity | — | — | 0.35s |
| 灰度切换 | 全页 saturation 过渡 | — | — | 0.4s easeInOut |
| 数值读数 | contentTransition(.numericText()) | — | — | 系统默认 |
| Toast | 底部滑入 | — | 1.8s 自动消失 | — |

**门控**：systemReduceMotion 时全部降级 opacity 0.15 直切（灰度切换保持 0.4s 无位移，安全）；背景态不跑；离屏即停。

## 四、无障碍矩阵（Guitar Wiz 三件套标准）

- 全部新控件 accessibilityLabel + accessibilityHint；模式卡合并单一标签；色徽章读「品牌蓝，当前选中」
- A/B 对照卡合并标签；标尺装饰 accessibilityHidden；对比度徽章读「对比度 4.9:1，符合标准」
- 灰度开关读「专注灰度模式，开启后全 App 转为灰色显示」
- 全部文本 ≥11pt；大字号下预览可滚动不截断；颜色不单独传达状态（徽章配文字、选中配勾）
- Reduce Motion 全降级；Accessibility Inspector 四场景过检

## 五、对比度算法规格（F17）

WCAG 相对亮度 L = Σ(0.2126R+0.7152G+0.0722B)，sRGB 线性化后；对比度 = (L亮+0.05)/(L暗+0.05)；≥4.5 合规绿 · 2.5–4.49 建议橙 · <2.5 不合格红；双环境（白纸 #FFFFFF / 深纸 #262626，深纸用 darkHex）；纯函数 DisplayContrastChecker；8 预设双环境达标断言入测试。

## 六、iOS 版本回退矩阵（deployment iOS 17）

| 能力 | iOS 17/18 回退 | iOS 26+ 原生 |
|---|---|---|
| 玻璃质感 | ultraThinMaterial | glassEffect(.regular.tint().interactive()) |
| symbolEffect | spring scale 0.95 | symbolEffect(.bounce, value:) |
| phaseAnimator | TimelineView 低帧 | phaseAnimator |
| contentTransition(.numericText) | opacity | 原生 |
| saturation（灰度） | 原生支持（iOS 17 起 .saturation 全版本可用） | 原生 |

## 七、性能预算与节流

Hero 呼吸 2.4s 低频；扫光单次；骰子防连点 0.3s；历史持久化 0.5s 防抖；时间轴 LazyVStack 截断 20 条；对比度颜色变更时单次计算；标尺为纯 SwiftUI 布局层（无每帧驱动）；**灰度 saturation(0) 由系统合成器硬件处理，零额外动画开销**。

## 八、评审排除项（保证 100% 真实可用）

| 候选 | 排除原因 |
|---|---|
| App 内全局背景氛围壁纸 | 侵入全部页面根视图背景层，风险失控 |
| 色彩滤镜（仿系统） | UIAccessibility 只读，无 App 内设置 API |
| 夜览/True Tone 直达 | 无公开 API |
| 屏幕方向锁定 | 非显示设置范畴 |
| 阅读页纸张底色（豆沙绿等） | 需联动多个文章详情页背景渲染点，超出本模块范围且与现有正文色功能重叠，评审暂缓 |

## 九、数据模型签名（Manager 扩展）

```swift
enum DisplaySchemePreset: String, CaseIterable, Identifiable {
    case comfortable, compact, eyeCare
    // title/subtitle/icon/shortBadgeText；func apply(to:) 设置 6 项排版值
}

struct DisplayChangeRecord: Codable, Equatable, Identifiable {
    let id: UUID; let field: String; let fieldTitle: String; let value: String; let at: Date
}

enum DisplayContrastChecker {  // 纯函数：luminance/contrast/judgment
    static func luminance(hex: String) -> Double
    static func contrast(foregroundHex: String, backgroundHex: String) -> Double
    static func judgment(_ ratio: Double) -> ContrastJudgment
    enum ContrastJudgment { case pass, suggest, fail }
}

// 新密钥
customColorHistoryKey / changeHistoryKey / grayScaleKey("displayGrayScaleMode")

// 新 @Published
@Published private(set) var customColorHistory: [String]
@Published private(set) var changeHistory: [DisplayChangeRecord]
@Published private(set) var systemVoiceOverRunning = false
@Published var grayScaleEnabled: Bool { didSet { persist; log("gray_scale", ...) } }

// 新方法
applyScheme(_:) / pushCustomColor(_:) / clearCustomColorHistory() / clearChangeHistory()
recordChange(field:fieldTitle:value:) / persistHistories()（0.5s 防抖）/ shareSummaryText()
```

**灰度注入点**：DisplayTypographyModifier body 内 `.saturation(manager.grayScaleEnabled ? 0 : 1)`（单一注入点全局生效，DesignCodeApp L116 链上已挂该 modifier，零新增调用点）。

约束：didSet 结构不动（log 内加 recordChange 一行）；isDefault/resetAll 语义不变（resetAll 追加清历史 + 关灰度）；brightness/autoLock/阅读统计引擎零改动。

## 十、日志事件表（display 域 + contrast 子域）

页面打开/关闭（停留时长）、Section 首曝、方案套用（info，6 项前后值）、亮度预设、随机色（0.5s 节流）、入史/历史点击、历史清空（info）、VoiceOver/更深颜色状态变化（系统通知）、分享摘要（info）、对比度判定（fgHex/bgHex/ratio/judgment）、**灰度开关 on/off（info，含 saturation 值）**、既有 didSet log 保留并联动 recordChange。

## 十一、执行步序与保障（工程严谨性）

1. **备份**：DesignCode_backup_20260926_display/ 五文件（Manager/View/TabBar/测试/app 文件）
2. **基线快照**：先跑真机测试记基线（当前 64 例 0 失败），改造后必须 ≥ 基线
3. **实施顺序**：Manager 扩展（编译点 A）→ View 重写（编译点 B）→ TabBar 摘要行 → 测试追加 → 全量编译 → 真机测试 → 审计 → 归档
4. **回滚策略**：每编译点失败即回退该文件到备份 diff 修复；git 不可用，备份目录为唯一回滚源
5. **SettingsView 执行注意**：升级摘要行前确认 SettingsView 已声明 displaySettings 观察对象（L8917 起），若无则摘要行升级时补 @ObservedObject（与既有 @AppStorage 并存不冲突）

## 十二、验证矩阵（手测剧本编号化）

1. 编译零错误（generic/iOS，CODE_SIGNING_ALLOWED=NO）
2. 真机全量测试全绿（≥ 64 + 新增例）
3. fresh-eyes 审计 2 轮 + diff 终审
4. **手测剧本**：S1 外观三模式全局即时切换（含 sheet 内 SettingsView）· S2 主题色全局 tint 即时变色 · S3 字号/粗体/家族/行距/字距联动 Hero 预览与全 App · S4 方案套用一次改 6 项 + toast + 时间轴记录 · S5 按钮形状全局胶囊化 · S6 正文色改色 → 详情页/网页/长图同步 · S7 对比度徽章随色实时绿橙红 · S8 历史六色速选用 · S9 亮度预设真实改屏亮度（自动亮度关闭后）· S10 自动锁定/常亮 idle timer 真实状态保留 · S11 VoiceOver/更深颜色行随系统开关实时变化 · S12 灰度开关全 App 变灰/恢复 · S13 恢复默认全复位 + 历史清空 · S14 reduceMotion 下全程静态
5. Accessibility Inspector 四场景过检
6. iOS 17 回退路径编译通过

## 十三、DoD（完成定义）

- 19 项新功能真实生效、旧功能零回归、≥64 测试全绿、零 print/零强制解包/零新警告
- 全部新交互完整日志埋点（含节流）、LogManager 联通验证
- 动效三态齐全；对比度自检与灰度模式真实生效且可逆
- 备份先行、记忆归档、评审记录入档