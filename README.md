# 园枢 — 山西晋中理工学院 App

「园枢」是山西晋中理工学院第三方 iOS 应用，基于 SwiftUI 开发，为师生和访客提供校园资讯、通知公告、机构导航、校长信箱等一站式服务。
本项目仅供测试和交流
## 功能特性

### 📱 核心模块
- **首页** - 轮播 banner、校园统计、快捷入口、校园亮点等
- **资讯** - 重要新闻、通知公告、招生信息等分类浏览
- **校园** - 校园日历、活动、风光、设施、师资力量展示
- **机构** - 院系部门组织架构，支持文章深度搜索
- **我的** - 个人中心、收藏管理、消息中心、设置

### 🆕 新增功能 (2026-09-24)
- **消息中心** - App 内通知盒子，统一管理各类推送消息
- **校园日历** - 原生模块，展示校园日历文章
- **使用帮助** - 首页「校园亮点」入口替换为使用帮助锚点
- **校长信箱** - 原生模块，支持查看留言及回复
- **党建专题** - 党建文章聚合浏览
- **学校概况** - 学校介绍、领导团队、风光相册、对外合作

### ⚙️ 设置与个性化
- **显示设置** - 外观模式（浅色/深色/跟随系统）、主题风格、字体大小、行间距、字间距、文章文字颜色、阅读统计等
- **缓存模式** - 智能缓存、数据节省模式、图片免流量
- **通知管理** - 推送权限、轮询间隔、自定义通知
- **生物识别** - Face ID / Touch ID 应用锁
- **应用图标** - 支持多套图标切换

### 🌐 网络与调试
- **网络监测** - 实时网络状态、流量统计、延迟分析、网络体检、测速

## 技术架构

### 目录结构
```
qin/
├── DesignCode/                 # 主源码目录
│   ├── DesignCodeApp.swift     # App 入口
│   ├── TabBar.swift            # 主导航 (9107行，60+视图)
│   ├── DataService.swift       # 数据枢纽
│   ├── NetworkService.swift    # 网络层
│   ├── Models.swift            # 数据模型
│   └── [其他模块文件]
├── DesignCodeTests/            # 单元测试
├── ARCHITECTURE.md             # 架构文档
├── CODE_WIKI.md                # 代码百科
└── docs/                       # 流程图文档
```

### 技术栈
- **UI 框架**: SwiftUI
- **目标 iOS**: iOS 17+
- **架构模式**: MVVM + 单例 Store
- **状态管理**: @Published / @ObservedObject / @AppStorage
- **网络**: URLSession + async/await
- **持久化**: UserDefaults + 文件存储 + NSCache

### 关键设计
- **数据降级**: 三层降级策略（内存 → 磁盘 → 静态兜底）
- **统一图片加载**: SJZCachedImage 组件，零闪烁核心
- **日志系统**: LogManager，支持文件持久化与崩溃捕获
- **深度链接**: 五类 DeepLink 防崩溃设计

## 构建与运行

### 环境要求
- macOS + Xcode 15+
- iOS 17+ 设备或模拟器

### 构建设置
- **SDKROOT**: iphoneos
- **Code Sign**: 需要 Apple Developer 团队签名
- **Deployment Target**: iOS 17.0

### 运行方式

**真机构建**（需要签名）:
```bash
# Xcode 中选择目标设备并运行
```

**模拟器验证**:
```bash
# Xcode 中选择模拟器并运行
```

**单元测试**:
```bash
# 建议在真机上运行，当前 54 用例全绿
```

## 项目结构

### 核心 Manager/Store 概览
| 模块 | 文件 | 说明 |
|------|------|------|
| 数据枢纽 | DataService.swift | 统一数据同步与缓存 |
| 网络层 | NetworkService.swift | API 请求封装 |
| 日志 | LogManager.swift | 统一日志输出 |
| 显示设置 | DisplaySettingsManager.swift | 视觉个性化 |
| 缓存模式 | CacheModeManager.swift | 数据与图片缓存 |
| 生物识别 | BiometricSecurityManager.swift | Face ID/Touch ID |
| 首页模块 | HomeModuleManager.swift | 模块可见性管理 |
| 通知系统 | NotificationManager.swift | 推送与轮询 |
| 收藏 | BookmarkManager.swift | 收藏文章管理 |
| 已读状态 | ReadStatusManager.swift | 已读标记 |
| 机构模块 | OrganizationManager.swift | 院系数据 |
| 网络监测 | SJZNetworkMonitor.swift | 实时网络状态 |

### 数据模型
- `NewsItem` - 新闻文章
- `Banner` - 轮播图
- `Department` - 院系专业
- `CampusActivity` - 校园活动
- `CampusVideo` - 校园视频
- `Facility` - 校园设施
- `BookmarkItem` - 收藏项

## 文档

- [ARCHITECTURE.md](qin/ARCHITECTURE.md) - 完整架构文档
- [CODE_WIKI.md](qin/CODE_WIKI.md) - 代码百科与模块详解
- [DEBUG_REPORT.md](qin/DEBUG_REPORT.md) - 数据同步故障排查报告
- `.trae/documents/` - 各类实施计划与规格书（**本地保留、不入库**）

## 注意事项

### 工程约束
1. 禁止硬编码线上 API 域名外的地址
2. 所有网络请求必须经过 NetworkService 统一封装
3. 图片加载必须使用 SJZCachedImage 组件
4. 新增日志必须接入 LogManager
5. 推送消息必须支持静默处理

### 已知风险
- 部分第三方接口可能存在不稳定性
- 弱网环境下需做好离线兜底

## 许可证

项目所涉及到的任何部分包括但不限于代码，所有内容仅供学习与内部使用。

---

*更多技术细节请参阅 [CODE_WIKI.md](qin/CODE_WIKI.md) 和 [ARCHITECTURE.md](qin/ARCHITECTURE.md)*