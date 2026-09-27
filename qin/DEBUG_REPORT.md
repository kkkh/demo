# 山西晋中理工学院 APP — 数据同步故障排查与修复报告

## 一、问题现象

用户反馈：资讯页面始终只显示几条新闻，刷新无效，数据同步功能完全不可用。

## 二、排查过程

### 第一步：添加调试面板

由于无法直接查看设备日志，在 `MainTabView` 中嵌入了一个可视化 DEBUG 面板，实时显示：

- `news.count` — 新闻条数
- `dataSource` — 数据来源（服务器/缓存/预置数据）
- `loading` — 加载状态
- `syncLog` — 同步日志（每个 API 调用结果）
- `syncErrors` — 错误列表

面板入口为右上角的 `ant.fill` 图标按钮，点击展开。

### 第二步：获取调试输出

用户在真机上打开 DEBUG 面板，返回关键信息：

```
news=5 src=服务器 loading=false
开始同步 22:08:38
✕ home2 失败：The data couldn't be read because it is missing.
✅ head 成功
✅ foot 成功
```

**关键发现**：`head` 和 `foot` 接口正常，但 `home2` 接口解码失败。错误信息 `"The data couldn't be read because it is missing"` 表明 Swift `Codable` 解码时遇到了 JSON 中不存在的字段。

### 第三步：编写本地 Swift 脚本模拟解码

为了精确定位哪个字段导致解码崩溃，编写了一个独立的 Swift 脚本，直接调用 API 并用当前的 `Home2DTO` 定义尝试解码：

```swift
// test_decode.swift — 本地独立运行，不需要 Xcode 工程
import Foundation

// 复制 NetworkService 中的 DTO 定义...
// 调用真实 API...
// 尝试解码并捕获错误...
```

运行结果：

```
Got 44732 bytes
❌ Decode FAILED: DecodingError.typeMismatch:
   Expected value of type Array<Any>.
   Path: data.bottom_banners.
   Debug description: Expected to decode Array<Any> but found a dictionary instead.
```

### 第四步：深入探查 API 实际结构

第一个错误找到后，编写了第二个脚本来检查 `home2` 返回 JSON 中每个字段的实际类型：

```swift
// test_decode2.swift — 检查每个字段的真实类型
for key in ["top_banners", "bottom_banners", "news", "campus", ...] {
    if let val = d[key] {
        print("\(key): \(type(of: val))")
        // 如果是字典，打印 keys
        // 如果是数组，打印 count 和首个元素 keys
    }
}
```

输出结果揭示了 **7 处结构不匹配**：

```
top_banners:      __NSArrayI        → 5 个 Banner 对象
bottom_banners:   __NSDictionaryI   → keys: [list, total]  ← 不是数组！
news.children:    keys: [importants, updates, notices, informations, resports]
resports:         NOT PRESENT       → 不在顶层，在 news.children 里
notices:          NOT PRESENT       → 不在顶层，在 news.children 里
informations:     NOT PRESENT       → 不在顶层，在 news.children 里
video:            keys: [dynamicDigit, videoSrc]  ← dynamicDigit 是数组不是字符串
campus.children:  keys: [activites, calendar]     ← 没有直接的 articles
```

### 第五步：逐一修复后再次验证

修复所有不匹配后，第三次运行解码脚本验证：

```
Got 44732 bytes
✅ Decode SUCCESS!
  topBanners: 5
  bottomBanners total: 4, list: 4
  achievements: 2a9cf74e15d4433c92cb30eb50a442ca
  news.importants: 516 total
  news.updates: 107 total
  news.notices: 155 total
  news.informations: 4 total
  news.resports: 69 total
  videos: 7 total
  students: 28 total
  teachers: 8 total
  campus.activites: 4 total
  video.dynamicDigit: 4 items
```

### 第六步：编写单元测试

为了防止接口再次变更时悄无声息地崩溃，创建了 `DesignCodeTests` 测试 target，包含 11 个测试用例，全部通过：

```
Executed 11 tests, with 0 failures (0 unexpected) in 0.718 seconds
```

## 三、根因分析

| # | 问题 | 代码中的定义 | API 实际返回 | 修复方案 |
|---|------|-------------|-------------|---------|
| 1 | `bottom_banners` 解码崩溃 | `[BannerDTO]?`（数组） | `{list, total}`（对象） | 改为 `ArticleListDTO?` |
| 2 | `BannerDTO` 字段缺失崩溃 | 3 个 `String`（必选） | 字段值可能为 null | 改为 `String?`（可选） |
| 3 | `BannerDTO` CodingKeys 错误 | `video_src`（snake_case） | `videoSrc`（camelCase） | 修正 CodingKeys |
| 4 | `notices/informations/resports` 为空 | 从 `home2.notices` 等顶层取 | 实际在 `home2.news.children` 里 | 从 `news.children` 取 columnId |
| 5 | `NewsChildrenDTO` 缺少子栏目 | 只有 `importants`/`updates` | 实际有 5 个子栏目 | 增加 `notices`/`informations`/`resports` |
| 6 | `video` 字段解码崩溃 | `ColumnDTO?` | `{dynamicDigit: [...], videoSrc: "..."}` | 新建 `VideoBlockDTO`，`dynamicDigit` 用 `AnyCodable` |
| 7 | `campus` 无数据 | 直接取 `campus.articles` | 无直接 articles，在 `children.activites` 里 | 新建 `CampusBlockDTO`，从 children 取 |

### 崩溃连锁效应

由于 `home2` 解码失败是 `throws` 错误，导致整个 `syncFromAPI()` 函数异常退出。所有后续的新闻拉取逻辑都不会执行，App 只能显示预置的 5 条离线数据。

```
home2 解码失败
  → syncFromAPI() 抛出异常
    → 进入 catch 分支
      → 回退到缓存/预置数据（仅 5 条）
        → 用户看到 "只有几条"
```

## 四、修复方案

### 4.1 NetworkService.swift — DTO 修正

```swift
// 修复前
struct Home2DTO: Codable {
    let topBanners: [BannerDTO]?
    let bottomBanners: [BannerDTO]?        // ❌ 实际是对象不是数组
    let notices: ColumnDTO?                // ❌ 不在顶层
    let informations: ColumnDTO?           // ❌ 不在顶层
    let resports: ColumnDTO?               // ❌ 不在顶层
    let video: ColumnDTO?                  // ❌ 结构完全不同
    let campus: ColumnDTO?                 // ❌ 没有直接的 articles
}

struct BannerDTO: Codable {
    let videoSrc: String                   // ❌ 非 optional，null 会崩溃
    let posterImgSrc: String               // ❌ 非 optional
    let videoTitleImgSrc: String           // ❌ 非 optional
    enum CodingKeys: String, CodingKey {
        case videoSrc = "video_src"        // ❌ API 返回的是 videoSrc 不是 video_src
    }
}

// 修复后
struct Home2DTO: Codable {
    let topBanners: [BannerDTO]?
    let bottomBanners: ArticleListDTO?     // ✅ 匹配实际结构
    let achievements: ColumnDTO?
    let news: NewsColumnDTO?               // ✅ 子栏目从这里取
    let video: VideoBlockDTO?              // ✅ 专用 DTO
    let teachers: ColumnDTO?
    let videos: ColumnDTO?
    let students: ColumnDTO?
    let campus: CampusBlockDTO?            // ✅ 专用 DTO
}

struct BannerDTO: Codable {
    let videoSrc: String?                  // ✅ 可选
    let posterImgSrc: String?              // ✅ 可选
    let videoTitleImgSrc: String?          // ✅ 可选
    enum CodingKeys: String, CodingKey {
        case videoSrc = "videoSrc"         // ✅ 匹配 API
        case posterImgSrc = "posterImgSrc"
        case videoTitleImgSrc = "videoTitleImgSrc"
    }
}

struct VideoBlockDTO: Codable {
    let videoSrc: String?
    let dynamicDigit: [AnyCodable]?        // ✅ 万能解码
}

struct CampusBlockDTO: Codable {
    let columnId: String?
    let children: CampusChildrenDTO?       // ✅ 从 children 取数据
}

struct CampusChildrenDTO: Codable {
    let activites: ColumnDTO?
    let calendar: ColumnDTO?
}

struct NewsChildrenDTO: Codable {
    let importants: ColumnDTO?
    let updates: ColumnDTO?
    let notices: ColumnDTO?                // ✅ 新增
    let informations: ColumnDTO?           // ✅ 新增
    let resports: ColumnDTO?               // ✅ 新增
}
```

### 4.2 NetworkService.swift — AnyCodable 万能解码器

```swift
struct AnyCodable: Codable {
    let value: Any?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil()       { value = nil }
        else if let b = try? container.decode(Bool.self)   { value = b }
        else if let i = try? container.decode(Int.self)    { value = i }
        else if let d = try? container.decode(Double.self)  { value = d }
        else if let s = try? container.decode(String.self)  { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let d = try? container.decode([String: AnyCodable].self) { value = d.mapValues(\.value) }
        else { value = nil }
    }
}
```

### 4.3 DataService.swift — 同步逻辑重写

- `syncFromAPI()` 改为 `doFullSync()`（非 throws），永不向上抛出异常
- 每个 API 调用独立 do-catch，一个失败不影响其他
- 新闻栏目的 columnId 从 `news.children` 取

### 4.4 DataService.swift — safeFetchArticles

```swift
private func safeFetchArticles(_ columnId: String, pageSize: Int = 50, label: String) async -> [NetworkService.ArticleDTO] {
    var all: [NetworkService.ArticleDTO] = []
    var seen = Set<String>()
    for page in 1...6 {
        do {
            let result = try await NetworkService.shared.fetchArticles(...)
            guard let list = result.articles?.list, !list.isEmpty else { break }
            // 去重添加...
            if list.count < pageSize { break }
        } catch {
            syncErrors.append("「\(label)」第\(page)页加载失败")
            break
        }
    }
    return all
}
```

## 五、单元测试

创建了 `DesignCodeTests/NetworkServiceDTOTests.swift`，包含 11 个测试：

### 离线测试（本地 JSON）
| 测试方法 | 验证内容 |
|---------|---------|
| `testHome2DTODecodesFromRealAPI` | 完整 home2 结构解码 |
| `testBannerDTODecodesWithMissingFields` | Banner null 字段不崩溃 |
| `testArticleDTODecodesWithOldAndNewFormat` | 新旧文章格式兼容 |
| `testColumnDTODecodesWithChildren` | 栏目嵌套字典解码 |
| `testCampusBlockDTODecodesWithActivites` | campus.children 结构 |
| `testVideoBlockDTODecodesWithComplexDynamicDigit` | video 复杂结构 |
| `testAnyCodableHandlesAllTypes` | AnyCodable 全类型 |
| `testAPIResponseRequireDataThrowsOnNilData` | 错误响应处理 |

### 在线测试（真实 API）
| 测试方法 | 验证内容 |
|---------|---------|
| `testRealAPIHome2Decoding` | home2 接口 + 关键数据存在性 |
| `testRealAPIArticlesDecoding` | 文章列表接口 + 字段完整性 |
| `testRealAPIArticleDetailDecoding` | 文章详情接口 + content 长度 |

### 运行方式

```bash
xcodebuild -project DesignCode.xcodeproj -scheme DesignCode \
  -destination 'platform=iOS,id=<设备ID>' test
```

### 测试结果

```
Test Case 'testAnyCodableHandlesAllTypes' passed (0.002 seconds).
Test Case 'testAPIResponseRequireDataThrowsOnNilData' passed (0.001 seconds).
Test Case 'testArticleDTODecodesWithOldAndNewFormat' passed (0.000 seconds).
Test Case 'testBannerDTODecodesWithMissingFields' passed (0.000 seconds).
Test Case 'testCampusBlockDTODecodesWithActivites' passed (0.001 seconds).
Test Case 'testColumnDTODecodesWithChildren' passed (0.000 seconds).
Test Case 'testHome2DTODecodesFromRealAPI' passed (0.001 seconds).
Test Case 'testRealAPIArticleDetailDecoding' passed (0.278 seconds).
Test Case 'testRealAPIArticlesDecoding' passed (0.101 seconds).
Test Case 'testRealAPIHome2Decoding' passed (0.331 seconds).
Test Case 'testVideoBlockDTODecodesWithComplexDynamicDigit' passed (0.002 seconds).

Executed 11 tests, with 0 failures (0 unexpected) in 0.718 seconds
```

## 六、修复后数据量

| 栏目 | 文章数 |
|------|--------|
| 学校要闻 | 516 条 |
| 通知公告 | 155 条 |
| 新闻资讯 | 107 条 |
| 科研报告 | 69 条 |
| 校园荣誉 | 35 条 |
| 学生故事 | 28 条 |
| 教师风采 | 8 条 |
| 校园视频 | 7 条 |
| 信息公告 | 4 条 |
| 校园活动 | 4 条 |

## 七、经验总结

1. **DTO 字段全部用 Optional**：第三方 API 随时可能返回 null，非 optional 字段一旦缺失会导致整个解码链路崩溃
2. **不要假设 API 结构**：用脚本实际请求并打印 JSON，而不是猜测字段名和类型
3. **独立解码脚本**：编写不依赖 Xcode 工程的 Swift 脚本，快速迭代验证 DTO 定义
4. **`DecodingError` 路径信息**：Swift 的 `DecodingError.typeMismatch` 会精确告诉你是哪个路径、期望什么类型、实际是什么类型，善用这个信息
5. **单元测试防回归**：为每个 DTO 写解码测试，接口变更时测试会立即失败，快速定位问题
6. **全容错同步**：每个 API 调用独立 do-catch，一个失败不影响其他数据的加载
