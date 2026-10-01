# B · 数据层与网络层核心（深度分析草稿）

> 分析批次：B（数据层与网络层）
> 分析范围（仅此 4 个文件，不越界）：
> - `qin/DesignCode/NetworkService.swift`（1603 行，read 口径；`wc -l` = 1602，文件末无换行）
> - `qin/DesignCode/DataService.swift`（1247 行；`wc -l` = 1246）
> - `qin/DesignCode/Models.swift`（1609 行；`wc -l` = 1608）
> - `qin/DesignCode/RefererHeaderURLProtocol.swift`（235 行）
>
> 行号全部来自 `grep -n` / `read` 实测（基准：工作区当前 HEAD 未提交状态）。
> 结论中凡属静态推导而未经运行验证者，在 §8「未验证点清单」集中标注。

---

## 0. 一句话架构

```
SwiftUI 视图（@ObservedObject data = DataService.shared，13 个文件引用）
        │  只读 @Published 状态；远程刷新只能经 syncIfNeeded()
        ▼
DataService（@MainActor 单例 / ObservableObject）
  ├─ 三层降级：远程 API → 沙盒 JSON 缓存 → 编译期 default* 静态数据
  ├─ 文章详情 NSCache（按 CacheModeManager 双档限额）
  └─ 21+2 个 JSON 文件（Documents/SXJZIT_Cache/*.json）
        │  await / try（永不向上抛：doFullSync、safeFetchArticles）
        ▼
NetworkService（@unchecked Sendable 单例，非 @MainActor）
  ├─ session         … .reloadIgnoringLocalAndRemoteCacheData（列表实时）
  ├─ cachedSession   … .useProtocolCachePolicy + 专属 URLCache（详情可缓存）
  ├─ 统一重试 3 次 + 线性退避；统一 APIResponse<T> 解包
  └─ String.strippingHTMLTags()（纯正则，规避 NSHTMLReader 主线程挂起）
        │  URLSession.data(for:)（async/await）
        ▼
URLSession ──[config.protocolClasses 显式注册]──► RefererHeaderURLProtocol
  ├─ 注入 Referer / Safari UA（绕过防盗链）
  ├─ 图片响应注入 Cache-Control: max-age=604800
  └─ SJZNetworkMonitor 埋点（token 生命周期）
        ▼
https://gwqietap.sxjzit.edu.cn/mapi  （唯一网关，无鉴权头）
```

---

## 1. NetworkService 深度分析

### 1.1 单例形态与并发标注

| 项 | 值 | 行号 |
|---|---|---|
| 声明 | `final class NetworkService: @unchecked Sendable` | 44 |
| 单例 | `static let shared = NetworkService()` | 45 |
| 构造器 | `private init()`（纯配置装配，无 I/O） | 51–75 |
| 是否 `@MainActor` | **否**（与 DataService 相反；可被任意线程/任务调用） | — |
| 持有的非 Sendable 状态 | `session` / `cachedSession` / `decoder` 三个 `let` | 47–49 |

**`@unchecked Sendable` 的实质**：编译器被要求跳过检查，正确性由作者保证。三类状态的线程安全性并不等价：

- `URLSession` 本身线程安全（Apple 文档保证），可跨任务共享；
- `JSONDecoder` **未承诺线程安全**，而这里是所有并发请求共用的同一实例（97 / 145）；实践中 `decode(_:from:)` 不改内部状态，但这是本文件最典型的"未验证并发假设"（见 §8-9）；
- 无任何可变共享属性（无缓存、无计数器），因此"无状态服务 + 两个会话"是本设计的并发模型。

**与 LogManager 的关系**：日志调用全部写成 `await LogManager.shared.info(...)`（93/103/110/116/141/151/158/164/267/274），而 `LogManager` 是 `@MainActor`（LogManager.swift:270–271）。即**每个请求成功/失败路径至少一次主线程跳转**——这是网络层对主线程的唯一触碰点，也是主线程负载的潜在来源（未做量化验证）。

### 1.2 NetworkConfig 常量（10–15）

| 常量 | 值 | 用途 |
|---|---|---|
| `baseURL` | `https://gwqietap.sxjzit.edu.cn/mapi` | 唯一网关前缀（buildURL 392 拼接） |
| `requestTimeout` | 15 s | 同时用于 config（53/63）与每个 `URLRequest.timeoutInterval`（88/136/249/302/1027） |
| `resourceTimeout` | 30 s | `timeoutIntervalForResource`（54/64） |
| `maxRetries` | 2 | 语义是"额外重试次数"→ 总尝试次数 3（`for attempt in 0...maxRetries`） |

### 1.3 双 URLSession 设计（核心设计决策）

| 维度 | `session`（默认会话） | `cachedSession`（缓存会话） | 行号 |
|---|---|---|---|
| Config 基类 | `URLSessionConfiguration.default` | 同 | 52 / 62 |
| `timeoutIntervalForRequest` | 15 s | 15 s | 53 / 63 |
| `timeoutIntervalForResource` | 30 s | 30 s | 54 / 64 |
| `requestCachePolicy` | `.reloadIgnoringLocalAndRemoteCacheData` | `.useProtocolCachePolicy` | **55 / 65** |
| `urlCache` | 未指定（继承 `URLCache.shared`） | 专属 `URLCache(memory 10MB, disk 50MB, diskPath: "article_detail_cache")` | — / **66–69** |
| `waitsForConnectivity` | `false` | `false` | 56 / 70 |
| `protocolClasses` | `[RefererHeaderURLProtocol.self]` | 同 | 59 / 71 |

**为什么要两个会话（可从代码与语义严格推出）**：

1. **列表必须实时**。首页/栏目的 `home2`、`head`、`foot`、`column/articles` 走 `get()` → `session`，策略是"忽略本地与远端缓存"，从而保证下拉刷新、同步一定拿到服务端最新列表，不会因 URLCache 命中而展示旧列表。
2. **详情值钱且更新少**。文章详情正文体积大（HTML + 图片清单）、变更频率低，最值得做 HTTP 缓存。`cachedSession` 用 `.useProtocolCachePolicy` 尊重服务端 `Cache-Control`，并配独立 URLCache 与磁盘目录，避免与列表请求互相污染、也便于按体积单独限额。
3. **默认值体现取舍**：`fetchArticleDetail(articleId:siteId:useCache:)` 的 `useCache` 默认 `false`（199），即"实时为默认、缓存需显式 opt-in"。实测调用点：`DataService.loadArticleFullDetail`(764)、`preloadArticleDetail`(806)、`OrganizationDetailView`(1863) 传 `true`；`DataService.loadArticleDetail`(736)、`fetchVideoUrl`(911)、`fetchSceneryAlbumDetail`(1165)、`PartySubjectView`、`CampusCalendarStore`、`BookmarkManager` 保持默认（实时）。
4. 两个会话都显式注册 `RefererHeaderURLProtocol`，注释（57–58）解释了原因：**不能依赖 `URLProtocol.registerClass` 的全局时序**（App.init 属性初始化早于 init 体，会漏注册，历史上导致埋点恒为 0）。App 层仍保留了 `URLProtocol.registerClass`（DesignCodeApp.swift:29）作为兜底。

### 1.4 核心方法逐个（准确签名 + 行号 + 行为）

#### 基础设施方法

| # | 签名 | 行号 | 行为 |
|---|---|---|---|
| 1 | `func get<T: Decodable>(_ path: String, params: [String: String]? = nil, as type: T.Type) async throws -> T` | 79–124 | 主 GET 通道。每轮：buildURL → `URLRequest`（GET / `Accept: application/json` / timeout 15s）→ `session.data(for:)` → `validate` → 计时 → 成功日志 → `decoder.decode`。`URLError.cancelled` 立即抛出（不重试、不记 ERROR）。失败重试见 §1.6。兜底 `throw lastError ?? NetworkError.timeout` |
| 2 | `private func getWithSession<T: Decodable>(_ path: String, params: [String: String]? = nil, as type: T.Type, session: URLSession) async throws -> T` | 127–172 | 与 #1 逻辑逐行同构（含重试/退避/取消语义），唯一差别是**会话可注入**；日志文案带"(缓存策略)"后缀（141）。存在的意义就是让 `fetchArticleDetail` 能切会话 |
| 3 | `private func getRaw(_ path: String) async throws -> Data` | 244–253 | 单次原始 GET（**无重试**、无解码），仍走 `session` + `validate`。用于 `/school/org` 与 href 透传 |
| 4 | `private func getRawData(path: String, params: [String: String]?) async throws -> Data` | 297–306 | `getRaw` 的带参通用化（同样无重试），供 `fetchJSONDict` 使用 |
| 5 | `func fetchJSONDict(path: String) async throws -> [String: Any]` | 283–285 | 转调带参版（params: nil） |
| 6 | `func fetchJSONDict(path: String, params: [String: String]?) async throws -> [String: Any]` | 288–294 | 拉取并 `JSONSerialization` 解析为顶层字典；失败抛 `NetworkError.decodeFailed("响应非 JSON 对象")`。**返回未解包的完整响应体**（含 code/message/data），data 层解包由调用方做 |
| 7 | `private func buildURL(path: String, params: [String: String]?) throws -> URL` | 387–404 | URL 构造，详见 §1.7 |
| 8 | `private func validate(_ response: URLResponse, _ data: Data) throws` | 406–413 | 非 `HTTPURLResponse` → `badResponse(0)`；状态码不在 200...299 → `badResponse(code)`。**注意：只校验 HTTP 状态，不校验 JSON 的 `code` 字段**，`data` 参数实际未使用 |
| 9 | `private func safeImageURL(from string: String) -> String` | 356–383 | 图片 URL 规整，详见 §1.9 |
| 10 | `private func parseImages(from dict: [String: Any]) -> [ImageDTO]` | 309–323 | 优先 `dict["images"]`（`url` ?? `src`，`alt` ?? `description`）；否则回退 `content` 的 `extractImagesFromHTML` |
| 11 | `private func extractImagesFromHTML(_ html: String) -> [ImageDTO]` | 326–353 | 正则提图（详见 §1.9） |
| 12 | `func resolveShortLinkFinalURL(_ shortURL: URL) async -> URL?` | 258–280 | **HEAD** 请求跟随 302，取 `resp.url` 为最终地址；仅接受 200...399；失败返回 `nil`（不抛）。用于党建/思政子站短链 `#/list/article?id=…` 中还原真实文章 id |

#### 业务端点方法（17 个 `fetch*` + 2 个 `fetchJSONDict` 重载）

完整清单见 §2 端点表；此处只列签名与行号的紧凑索引：

```
fetchHome2() -> Home2DTO                                        177–179
fetchHead() -> HeadDTO                                          182–184
fetchFoot() -> FootDTO                                          187–189
fetchArticles(columnId:siteId="1":page=1:size=20) -> ColumnDTO   192–196
fetchArticleDetail(articleId:siteId="1":useCache=false) -> ArticleDetailDTO   199–204
fetchArticleDetailWithHref(_ href:) -> NewsDetailDTO             207–241
fetchZSWHome2() -> ZSWHome2DTO                                   754–756
fetchZSWArticlePage(siteId:columnId:page=1:size=20) -> ZSWArticlePageDTO  762–767
fetchZSWArticleDetail(articleId:siteId="cb3b1fe4…326d") -> ArticleDetailDTO  881–885
fetchSpecialtyData(siteId:columnId:) -> SpecialtyData            890–911
fetchDeptHome2(siteKey:) -> DeptHome2DTO                         964–966
fetchSchoolOrgTree() -> [SchoolOrgNode]                          985–1016
fetchDeptSiteIndex(siteKey:) -> (siteId: String, columns: [DeptColumnRef])  1022–1069
fetchPartySubjectFingerprint(siteKey:) -> PartySubjectFingerprint 1088–1106
fetchSceneryAlbumDetail(articleId:siteId="1") -> SceneryAlbumDetail  1164–1178
fetchPrincipalMailbox(page:size:) -> MailboxPageData             1250–1284
fetchMessageDetail(msgId: Int) -> MailboxMessageDetail           1337–1358
```

**值得单独说明的 4 个方法行为**：

- **`fetchArticleDetailWithHref`（207–241）**：先 `getRaw(href)`，再尝试 `JSONSerialization` → `data` 字典 → 取 title/content/author/source/create_time → `parseImages` → `content.strippingHTMLTags()` 组 `NewsDetailDTO`；若响应不是 `{data:{…}}` 结构，则**兜底把整段 bytes 当 UTF-8 HTML** 处理（title/时间/作者为空、`images: []`，230–240）。⚠️ grep 全仓库**无任何调用点** → 疑似 dead code（见 §8-4）。
- **`fetchSchoolOrgTree`（985–1016）**：`getRaw("/school/org")` + 手写递归 `walk`，收集**叶子节点**（`children` 为空或缺失）且 name 非空且（site_key / article_id / path 至少一个存在）→ `SchoolOrgNode`，空串归一为 `nil`。设计意图（注释 974–976）：机构三形态（子站型 / 单文章型 / 外链型），组织形态会变更故运行时解析、禁止硬编码。
- **`fetchDeptSiteIndex`（1022–1069）**：同样手写递归，但**刻意跳过 `articles` 子树**（其中的 id 是文章 id 不是栏目 id，1060）；同时收集两类栏目 id：`column_id` 与"仅 `id`+`title_cn` 的子页/tab 节点"（实测其 `id` 可直接当 `column_id` 查询文章，1020–1021、1051–1057）；`seen` 去重。返回 `(siteId, columns)` 供机构页文章搜索运行时复用。
- **`fetchPartySubjectFingerprint`（1088–1106）**：单次 `/dept/home2` → `collectFingerprint`（1110–1148）深度递归累加所有 `articles.total`、收集所有 list 条目的 `(id, update_time ?? create_time ?? updateTime)` → 按 id 去重保留更晚时间 → 升序 → 取末尾 3 条。`topSignature`（1080–1083）拼 `"id|updateTime"` 逗号串供通知轮询比对，无文章时为 `"-"`。零额外请求是明确设计目标。
- **`fetchPrincipalMailbox`（1250–1284）**：⚠️ 注意双层 data 嵌套（`data.data.message_list` / `data.data.leave_message_now`），注释 1206–1208 明确记录"多建模一层会把 message_list 静默解码为 nil（表现为 0 条）"；文本清洗把 `\r\n`→`\n`、去掉每行前导 `\t`。
- **`fetchMessageDetail`（1337–1358）**：**不使用 `requireData()`**，而是自己判空并抛 `NetworkError.dataMissing("该信件详情暂不可用（可能已下架或超出展示期）")`，原因是服务端对不存在留言返回 `code=200 + data=null + message="success"`，`requireData` 会抛出令人困惑的「服务器错误：success」（注释 1343–1344）。

### 1.5 错误类型与"错误码"

`enum NetworkError: LocalizedError`（19–40），7 个 case：

| case | 关联值 | `errorDescription` | 触发位置 |
|---|---|---|---|
| `.badURL` | — | 无效的请求地址 | buildURL 395 / 401 |
| `.badResponse(Int)` | HTTP 状态码；**非 HTTP 响应时为 0** | 服务器响应异常（状态码：N） | validate 408 / 411 |
| `.decodeFailed(String)` | 解析器原始描述 | 数据解析失败：msg | 291、989、1032、1091 + `decoder.decode` 抛出的 `DecodingError`（**未包装，直接向上冒泡**） |
| `.timeout` | — | 网络请求超时… | get 123 / getWithSession 171 的 `lastError ?? .timeout` 兜底 |
| `.noData` | — | 服务器未返回数据… | `APIResponse.requireData()` 426–431 |
| `.dataMissing(String)` | 完整可读文案 | 直接返回 msg | fetchMessageDetail 1346 |
| `.serverError(String)` | 服务端 `message` | 服务器错误：msg | requireData 428（`data == nil` 且 message 非空） |

**两层错误语义**（重要，易误读）：HTTP 层由 `validate` 拦截（非 2xx → `badResponse`）；业务层由调用方决定是否 `requireData()`——`data == nil` 时若 `message` 非空则抛 `.serverError(message)`，否则 `.noData`。因此**服务端 `code` 字段从未被读取**（`APIResponse.code` 419 声明了却无人使用），HTTP 200 + 业务失败完全依赖 `data` 是否为空来判定。

**重试语义与取消语义的耦合**：`URLError.cancelled` 直接抛出且只记 debug（102–107 / 150–155）——注释明确这是"编排接管（下拉刷新取代/页面离开/任务切换）非失败语义"。

### 1.6 超时 / 重试 / 退避策略

```text
get / getWithSession（同构）:
  startTime = now; lastError = nil
  for attempt in 0...2:                       # maxRetries=2 → 最多 3 次
      do:
          url  = buildURL(path, params)
          req  = GET + Accept: application/json + timeout 15s
          (data, resp) = await session.data(for: req)          # 资源超时 30s
          validate(resp, data)                                  # 非 2xx 抛错
          log info(成功, elapsed, attempt+1)
          return decoder.decode(T.self, from: data)             # 解码失败也进 catch
      catch:
          lastError = error
          if error is URLError && code == .cancelled:
              log debug("请求已取消（跳过重试）"); throw error   # 立即冒泡
          if attempt < 2:
              log warning("请求失败，准备重试")
              try? await Task.sleep(500ms * (attempt+1))        # 线性退避 0.5s → 1.0s
          else:
              log error("请求最终失败", attempts=3, elapsed)
  throw lastError ?? NetworkError.timeout
```

要点与风险：

- **退避是线性而非指数**（`500_000_000 * UInt64(attempt+1)`，114 / 162），总退避上限 1.5 s；最坏总耗时 ≈ 3×15 s + 1.5 s ≈ 46.5 s。
- **`try? await Task.sleep` 吞掉 `CancellationError`**（114 / 162 / DataService 634）：任务被取消时不会中断退避循环，最多再等 1.5 s 才因 `URLSession` 立刻抛 `.cancelled` 而退出（见 §8-6）。
- **解码失败也会重试**（`decoder.decode` 在 do 块内），语义上把"服务端返回了畸形 JSON"当作可重试故障，会额外消耗 2 次请求。
- `getRaw` / `getRawData` / `resolveShortLinkFinalURL` **完全无重试**（单次），与 `get` 的重试语义不一致。
- 无并发限流、无请求去重（同一 path 并发调用会各自发出 3 次尝试）。

### 1.7 URL 构造与 query 编码（buildURL，387–404）

```text
full = path.hasPrefix("http") ? path                       # ① 透传绝对 URL
                              : baseURL + ("/" + path)     # ② 拼网关（自动补前导 /）
comps = URLComponents(string: full) ?? 抛 .badURL          # ③ 解析失败 → badURL
if params 非空:
    comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }   # ④
return comps.url ?? 抛 .badURL
```

- **编码交给 `URLComponents`**：中文/特殊字符由 `queryItems` 赋值时自动 percent-encode；网络层不做手工转义（与 `safeImageURL` 的手工编码形成对比）。
- **`[String: String]` 字典无序遍历** → query 参数顺序不确定。对当前服务端无影响，但**不利于 HTTP 缓存键的稳定复现**（同参数不同顺序 = 不同 URL = 不同缓存条目；对 `session` 无影响，对 `cachedSession` 是轻微缓存击穿风险，未实测）。
- 判断用 `hasPrefix("http")` 而非 `hasPrefix("http://")/("https://")`：`"httpfoo…"` 这类字符串也会被当成绝对地址透传（当前无实际调用面，属潜在字符匹配瑕疵）。
- 无条件 `guard let comps = URLComponents(...)` → 传入含非法字符的 href 时会抛 `.badURL`，不致命。

**无鉴权**：本文件不注入任何 `Authorization` / `Cookie` / 自定义业务头，仅 `Accept: application/json`（87 / 135 / 248 / 301 / 1026）+ `Referer`/`User-Agent`（由协议层注入，见 §7）。

### 1.8 Referer 需求处理（在 NetworkService 侧的实际形态）

- **NetworkService 自己完全不设置 Referer**；防盗链所需的 `Referer`/`User-Agent` 由 `RefererHeaderURLProtocol.startLoading` 统一注入（68–72）。
- 但 NetworkService 通过 **`config.protocolClasses = [RefererHeaderURLProtocol.self]`（59 / 71）** 把自己的两个会话显式纳入拦截，因此**本服务的所有请求同样带上 Referer/UA 并获得埋点**；注释（57–58）记录了不依赖全局注册的原因。
- 设计上这一层是"全局网络拦截"而非"网络层内注入"，覆盖面包含 `AVPlayer`、`AsyncImage`、`WKWebView 之外`的第三方会话——正是注释 6 所述"解决 AVPlayer 等场景防盗链校验失败"。

### 1.9 图片 URL 规整与提图算法

**`safeImageURL(from:)`（356–383）三阶段**：

```text
① 协议相对："//host/path"      → "https:" + s          # 363（强制 https）
② 站点相对："/uploads/x.jpg"   → SchoolInfo.website + s  # 365 = https://www.sxjzit.edu.cn
③ 无 scheme："uploads/x.jpg"    → SchoolInfo.website + "/" + s   # 369
④ 若 URL(string:) 可解析 → 原样返回                        # 373
⑤ 否则 percent-encode：urlPathAllowed ∪ urlHostAllowed ∪ urlQueryAllowed ∪ urlFragmentAllowed
   ∪ {"%"}（379，显式保留百分号以免二次编码）→ 失败则原样返回  # 380–382
```

⚠️ **重要事实修正**：本批 4 个文件中**不存在 `http://` → `https://` 的强制改写**。唯一涉及协议的是"`//` 协议相对 URL 补 `https:`"与"相对路径补 `https://www.sxjzit.edu.cn`"。也就是说若服务端在正文 HTML 里给出 `http://…` 的图片绝对地址，代码会**原样保留**（随后能否加载取决于 ATS 配置，见 §8-3）。唯一的 http/https 判定出现在 `warmUpHotImagesIfNeeded`（218），它**只接受 http/https 前缀的 banner 图**，目的是杜绝把 `"video_poster"` 这种键名当 URL 构造（注释 215–216 记录了 NSURLError -1002 的历史）。

**`extractImagesFromHTML`（326–353）与 `DataService.extractImages`（935–965）使用完全相同的正则**：

```regex
<img[^>]+src=["']([^"']+)["'][^>]*(?:alt=["']([^"']*)["'])?[^>]*>     # 大小写不敏感
```

要点：① `src` 必须带引号（无引号属性漏抓）；② `alt` 分组是可选的、且必须出现在 `src` 之后（`alt` 前置时抓不到）；③ 过滤 `file://` 前缀（Word/WPS 粘贴产生的本地路径，`print` 后跳过）；④ 每张图都过 `safeImageURL`；⑤ 用 `enumerateMatches` 保序；⑥ 无去重（HTML 中同一图重复出现会重复入列）；⑦ `DataService` 版本**每张图打印 3 行 `print`**（953/954/981/985/992/1002/963）——生产环境的控制台噪音与轻微性能损耗（离线缓存页也会触发）。

### 1.10 缓存策略汇总（URLRequestCachePolicy 视角）

| 层 | 策略 | 位置 | 语义 |
|---|---|---|---|
| 列表/同步请求 | `.reloadIgnoringLocalAndRemoteCacheData` | 55 | 忽略本地缓存且不使用远端缓存指令 → 永远回源，保证列表实时 |
| 详情请求（opt-in） | `.useProtocolCachePolicy` | 65 | 遵循服务端 `Cache-Control`/`Expires`，命中 URLCache 则秒开 |
| 详情 URLCache | memory 10 MB / disk 50 MB / diskPath `article_detail_cache` | 66–69 | 与 `URLCache.shared` 分离，独立限额 |
| 图片请求（协议层改写） | 缓存模式 `.returnCacheDataElseLoad`；即时模式 `.useProtocolCachePolicy` | Referer 75–79 | 与前台的"缓存模式 / 即时模式"开关联动 |
| 图片响应存储 | `cacheStoragePolicy: .allowed` | Referer 113 | 允许按 HTTP 语义入缓存（配合注入的 7 天头） |
| 应用层 NSCache | 文章详情内存缓存（200/80MB 或 50/20MB） | DataService 111–125 | 见 §3.9 |

三层缓存（URLCache → NSCache → 沙盒 JSON）彼此独立，无统一失效链路：`clearCache()`（DataService 1083）只删 JSON 文件，**既不删 URLCache 也不清 NSCache**（见 §3.7 / §7-7）。

### 1.11 DTO 层规模

- `extension NetworkService` 内共 **45 个 `*DTO` 结构体**（450 → 1510），另有 `APIResponse<T>`（419）、`AnyCodable`（618）、以及 6 个 private 校长信箱 DTO（1209–1247）+ `SchoolMsgDetailDTO`（1316）→ **解码用类型合计 52 个**。
- 28 处 `enum CodingKeys`（grep 计数），把 snake_case / camelCase 混排的服务端字段统一映射为 Swift 驼峰命名。
- 容错策略（与 Models.swift 的对比见 §5.5）：**远端解码路径以"字段全 Optional"为主**（如 `ArticleDTO` 450–472 仅 `resolvedTitle` 为计算属性），只有 3 处使用真正的"结构容错"：
  - `AnyCodable`（618–644）：任意 JSON 值的万能包裹，解码支持 nil/Bool/Int/Double/String/数组/字典；**编码固定写 `nil`（640–643）→ 不可逆，仅能用于"忽略该字段"**（当前用于 `VideoBlockDTO.dynamicDigit`，611–615）。
  - `DeptNavItemDTO.init(from:)`（1407–1431）+ `DynamicCodingKeys`（1449–1454）：`data` 字典内混有对象与字符串元数据，逐键 `try?` 解码、失败即跳过，全空则归一为 `nil`。
  - `BannerDTO` / `DeptBannerDTO` 显式 `CodingKeys` 把 `videoSrc`/`imgSrc`/`maskSrc` 这类**服务端本身即为驼峰的键名**原样映射（559–563 / 1377–1382）。

---

## 2. 全量 API 端点清单（关键产出）

**网关**：`https://gwqietap.sxjzit.edu.cn/mapi`（NetworkConfig.baseURL，11）
**统一响应包装**：`APIResponse<T> = { code: Int?, message: String?, data: T? }`（419–434）；除 `fetchJSONDict`/`fetchSchoolOrgTree`/`fetchDeptSiteIndex`/`fetchArticleDetailWithHref` 外，全部经 `requireData()` 解包。
**鉴权**：无（仅 `Accept: application/json`）。

### 2.1 NetworkService 内定义的固定端点（11 个路径）

| # | 方法（行号） | HTTP 路径 | 关键参数 | 返回 DTO | 备注 |
|---|---|---|---|---|---|
| 1 | `fetchHome2()` 177 | `GET /school/home2` | — | `Home2DTO` | 首页聚合（banner/荣誉/新闻/视频/师生/校园） |
| 2 | `fetchHead()` 182 | `GET /common/column/head` | — | `HeadDTO` | 站点信息 `site` + 导航 `menus`（院系 site_key 来源） |
| 3 | `fetchFoot()` 187 | `GET /common/foot` | — | `FootDTO` | 招生电话 + 友情链接 + 社交平台 |
| 4 | `fetchArticles(columnId:siteId:page:size:)` 192 | `GET /common/column/articles` | `site_id`(默认 "1")、`column_id`、`page`、`size`(默认 20) | `ColumnDTO` | 栏目文章列表（含 `articles.total/list`、`children` 字典） |
| 5 | `fetchArticleDetail(articleId:siteId:useCache:)` 199 | `GET /common/article/detail` | `site_id`(默认 "1")、`article_id`；`useCache` 仅决定会话 | `ArticleDetailDTO` | **唯一双会话分流点**；`useCache=true` → cachedSession |
| 6 | `fetchZSWHome2()` 754 | `GET /dept/home2` | `site_key=zsw` | `ZSWHome2DTO` | 招生网首页（nav.data 五个区块，键名含连字符 `enrollment-plan` 等） |
| 7 | `fetchZSWArticlePage(siteId:columnId:page:size:)` 762 | `GET /common/article/page` | `site_id`、`column_id`、`page`、`size`(默认 20) | `ZSWArticlePageDTO` | ⚠️ 注释 759–761：服务端只认 `page`/`size`，旧版 `pageNo`/`pageSize` 被静默忽略（恒返回第 1 页 10 条） |
| 8 | `fetchZSWArticleDetail(articleId:siteId:)` 881 | `GET /common/article/detail` | `site_id` 默认 `cb3b1fe4fcdf40999b0c162015c3326d`、`article_id` | `ArticleDetailDTO` | 与 #5 同路径，默认 siteId 不同（招生网站点） |
| 9 | `fetchSpecialtyData(siteId:columnId:)` 890 | `GET /common/column/oneTwoArticles` | `site_id`、`column_id` | `SpecialtyColumnDTO` → **`SpecialtyData`（业务模型）** | 唯一直接返回 Models.swift 业务模型的端点；内部把 children.list×articles.list 拍平为 学院→专业 |
| 10 | `fetchDeptHome2(siteKey:)` 964 | `GET /dept/home2` | `site_key` | `DeptHome2DTO` | 机构子站首页（top_banners + nav 树，含 `data` 动态区块） |
| 11 | `fetchPrincipalMailbox(page:size:)` 1250 | `GET /school/msg` | `page`、`size` | `SchoolMsgDTO` → `MailboxPageData` | 校长信箱列表 + 使用说明（双层 data 嵌套） |
| 12 | `fetchMessageDetail(msgId:)` 1337 | `GET /common/msg/detail` | `article_id`、`site_id=1`、`msg_id`（三参同时传同一 id） | `SchoolMsgDetailDTO` → `MailboxMessageDetail` | data=null 时抛 `dataMissing` 可读文案 |
| 13 | `fetchSchoolOrgTree()` 985 | `GET /school/org` | — | 原始 JSON → `[SchoolOrgNode]` | 官网权威机构树；手写递归、禁硬编码 |
| 14 | `fetchDeptSiteIndex(siteKey:)` 1022 | `GET /dept/home2` | `site_key` | 原始 JSON → `(siteId, [DeptColumnRef])` | 与 #10 同路径，但绕过 DTO 手写解析（跳过 `articles` 子树） |
| 15 | `fetchPartySubjectFingerprint(siteKey:)` 1088 | `GET /dept/home2` | `site_key` | 原始 JSON → `PartySubjectFingerprint` | 指纹（total + 最新 3 篇）供通知轮询；单请求零额外开销 |
| 16 | `fetchSceneryAlbumDetail(articleId:siteId:)` 1164 | 复用 #5 `/common/article/detail` | `site_id`(默认 "1")、`article_id` | `ArticleDetailDTO` → `SceneryAlbumDetail` | 从 content HTML 提图；无图时回退 `imageUrl` 封面单图 |
| 17 | `fetchJSONDict(path:)` / `fetchJSONDict(path:params:)` 283/288 | **任意 path** | 任意 params | `[String: Any]`（未解包） | 通用逃生舱 |

> 说明：#6/#10/#14/#15 命中同一路径 `/dept/home2`，仅解析策略不同（DTO / 手写递归 / 指纹），是"一个端点多视图"设计。
> `fetchArticleDetailWithHref`（207）走 `getRaw(href)` —— href 是**服务端下发的绝对 URL**，不经过 `baseURL`，属任意路径透传（无调用点，见 §8-4）。
> `resolveShortLinkFinalURL`（258）对**任意传入短链**发 HEAD。

### 2.2 经 `fetchJSONDict` 透传、由其他模块声明的端点（2 个，跨文件索引）

| 路径 | 调用点（非本批文件） | 用途 |
|---|---|---|
| `GET /school/intro` | `NotificationManager.swift:535`、`SchoolProfileView.swift:404` | 学校概况（简介类动态数据） |
| `GET /school/cooperate` | `NotificationManager.swift:560`、`SchoolProfileView.swift:629` | 校企合作/合作单位 |

→ **已知 HTTP 路径合计 13 个**（11 个 NetworkService 内定义 + 2 个透传），另有 2 条"任意 URL"通道（文章 href、短链 HEAD）。

### 2.3 站点 / 栏目 ID 常量（散落但必须汇总）

| 常量 | 值 | 位置 | 用途 |
|---|---|---|---|
| 主站 site_id | `"1"` | 192 / 199 / 1164 / 1340 | 默认站点的字面量，**未集中定义为常量** |
| 招生网站点 | `cb3b1fe4fcdf40999b0c162015c3326d` | 881（默认参数）、DataService 500 / 611 / 839 / 862 | 招生网 site_id |
| 专业介绍栏目 | `25d7bd39e49a468880356e302b9ccf1d` | DataService 612（硬编码） | ⚠️ 与文件内"严禁硬编码"注释（30 / 649 / 985 / 1019）自相矛盾 |
| 校园日历栏目 | `8197fe41503c4c32bce1e449d2492b2e` | NetworkService 441（`static let campusCalendarColumnId`） | 唯一被正式定义为常量的栏目 ID |
| 新闻 5 栏目 column_id | 运行时从 home2 解析 | DataService 304–316 / 666–679 | 写入 `newsColumnIds`，供机构页搜索复用 |

---

## 3. DataService 深度分析

### 3.1 单例形态与并发标注

| 项 | 值 | 行号 |
|---|---|---|
| 类型标注 | `@MainActor final class DataService: ObservableObject` | 8–9 |
| 单例 | `static let shared = DataService()` | 10 |
| 通知名 | `static let syncDidCompleteNotification = Notification.Name("DataServiceSyncDidComplete")` | 13 |
| 构造器 | `private init()`：建目录 → `loadCache()` → `loadZSWCache()` → `loadSpecialtyCache()` | 160–172 |
| 注入方式 | 视图侧 `@ObservedObject private var data = DataService.shared`（TabBar.swift 等 13 个文件），**非 EnvironmentObject** | — |

`@MainActor` 的后果：`doFullSync` 内所有 `compactMap` 映射、状态赋值、`formatDate` 都在主线程执行；仅 `parseArticleDetail` / `extractImages` / `safeImageURL` 被显式标注 `nonisolated`（884 / 935 / 968）以允许后台并行。网络等待期间的挂起点让出主线程，但**解析与数组构造仍是主线程工作**（风险点，未量化）。

### 3.2 `@Published` 状态字段清单（35 个）

分组 A · 同步过程状态（17–22）

| 字段 | 类型 / 初值 | 写入点 | 含义 |
|---|---|---|---|
| `isLoading` | `Bool = false` | 197 / 204 | 同步门闸（181 的 guard 依据） |
| `lastError` | `String?` | 198 / 254 / 463 / 465 / 1116 | 首页失败或"部分栏目失败"汇总文案 |
| `syncErrors` | `[String] = []` | 199 / 1117 | 逐栏目失败明细（`safeFetchArticles` 716） |
| `syncWarnings` | `[String] = []` | 200 | 服务端 500/data:null 级降级（714） |
| `dataSource` | `String = "预置数据"` | 166 / 271 / 461 / 1115 | 三层降级指示器：`预置数据` / `缓存` / `服务器` |
| `syncLog` | `[String] = []` | 244（`syncLog = []` 后逐条 append） | 同步过程人类可读流水 |

分组 B · 首页内容（24–39，初值即静态兜底）

| 字段 | 初值 | 远程写入 | 缓存读写 |
|---|---|---|---|
| `banners` | `[]` | 280 | 1050 / 1096 |
| `bottomBanners` | `[]` | **无远程写入点** | 1051 / 1097（仅缓存往返） |
| `stats` | `defaultStats` | **无任何写入点** → 纯静态 | 不参与缓存 |
| `honors` | `defaultHonors` | 288 | 1048 / 1094 |
| `departments` | `defaultDepartments` | 420 | 1049 / 1095 |
| `news` | `defaultNews` | 357（五通道合并） | 1047 / 1093 |
| `newsColumnIds` | `[:]`，`private(set)` | 315 / 676（下标写入） | 不落盘（每次同步重建） |
| `videos` | `[]` | 388 | 1052 / 1098 |
| `studentStories` | `[]` | 391 | 1053 / 1099 |
| `teacherProfiles` | `[]` | 397 | 1054 / 1100 |
| `campusActivities` | `[]` | 407 | 1056 / 1102 |
| `campusSceneries` | `[]` | **无远程写入点**（404 注释：首页校园风光模块 2026-09-24 退役，字段保留兼容展示） | 1055 / 1101 |
| `services` | `defaultServices` | 无 | 不参与缓存 |
| `facilities` | `defaultFacilities` | 无 | 不参与缓存 |
| `timeline` | `defaultTimeline` | 无 | 不参与缓存 |

分组 C · 新闻五通道 + 3 个遗留通道（41–48）

| 字段 | 远程写入 | 来源 |
|---|---|---|
| `importantNews` / `updateNews` / `partyNews` / `notices` | 344 / 345 / 346 / 347 | home2.news.children 的 importants / updates / resports（实为党建）/ notices |
| `admissionNews` | 328（来自 home2 自带 articles，**articleId 被置 nil**）或 348 | informations（实为招生，服务端 API 返回 500） |
| `campusNews` / `researchReports` / `informationNews` | **无远程写入点** | 仅缓存读（1065–1067）与清空（1108–1110）→ 遗留在途通道 |

分组 D · 站点/底部（50–53）：`siteInfo`（431，唯一写入）、`recruitPhones`（438）、`footerLinks`（440）、`socialPlatforms`（446）。

分组 E · 招生网（57–60）：`zswHomeData`（595 / 1129）、`zswIsLoading`（486–487）、`private lastZSWFetchTime`（60，SWR 依据）。
分组 F · 专业介绍（64–65）：`specialtyData`（623 / 1141）、`specialtyIsLoading`（608–609）。

### 3.3 三层降级策略（远程 → 本地 JSON → 静态兜底）

| 层 | 触发条件 | 实现 | `dataSource` |
|---|---|---|---|
| L1 远程 | `syncIfNeeded` 未被门闸/冷却拦截 → `doFullSync()` | 逐接口 `do/catch`，各接口独立成功/失败 | 全部走完 → `"服务器"`（461） |
| L2 本地 JSON | ① 冷启动 `init` 时 `loadCache()` 返回 true（165–167）；② `doFullSync` 中 home2/head/foot **三者全失败** → `loadCache()`（270–273） | `Documents/SXJZIT_Cache/{key}.json`，`JSONDecoder` 解码 | `"缓存"`（166 / 271） |
| L3 静态兜底 | 属性初值本身（26–39）与 `clearCache()` 的重置（1093–1115） | Models.swift 的 `default*` 常量 | `"预置数据"`（21 初值 / 1115） |

**关键实现细节**：① `loadCache()` 只在 `news` / `honors` / `departments` 三者之一非空时才把 `loaded` 置 true（1047–1049、1068）——其余 18 个键即使读到数据也不算"加载成功"，因此 `dataSource` 不会因为"只有 banners 缓存"而从 `预置数据` 变成 `缓存`；② 远程赋值普遍带 `!isEmpty` 前置判断（279 / 287 / 319 / 438 / 439 / 445），**空响应不会覆盖已有数据**，这是"逐栏目降级而非整体失败"的关键；③ 三层之间没有版本号/时间戳校验，缓存永远被信任（无 TTL，除 ZSW 的 30 分钟 SWR）。

### 3.4 `syncIfNeeded` 完整流程（180–209）

```text
syncIfNeeded(force = false):
  guard !isLoading else return                              # 181 并发门闸（唯一的"重入保护"）
  if !force && now - lastSyncTime < 10s: return              # 183 syncCooldown=10s（177）
  if !force && CacheModeManager.shared.isCacheEnabled
            && now - lastSyncTime < 600s:                    # 188–195 缓存模式 10 分钟 SWR
      log("缓存模式：10分钟内已同步，跳过远程全量同步"); return
  isLoading = true; lastError = nil; syncErrors = []; syncWarnings = []
  lastSyncTime = now                                          # 201 先记时（失败也进入冷却）
  Task {                                                      # 202 未持有句柄 → 不可取消
      await doFullSync()                                      # 永不抛
      isLoading = false
      NotificationCenter.post(syncDidCompleteNotification)     # 205 同步完成广播
      await warmUpHotImagesIfNeeded()                          # 207 启动图片预热
  }
```

`warmUpHotImagesIfNeeded`（212–240）：banner 前 6 张（仅接受 http/https 绝对地址，218）+ 缓存模式下五大新闻通道各前 5 条缩略图（224–231）→ `Set` 去重 → 最多 20 个 URL（233）→ `await SJZImagePrefetcher.prefetch(urls:maxConcurrent:4)`（TabBar.swift:12685/12689）。

### 3.5 `doFullSync` 完整流程（243–480，13 步）

| 步 | 行号 | 行为 | 失败处理 |
|---|---|---|---|
| 0 | 244–246 | 清空 `syncLog`、写入开始时刻、`LogManager.info("articleSync")` | — |
| 1 | 249–267 | **串行** await `fetchHome2` / `fetchHead` / `fetchFoot`（三个独立 do/catch） | home2 失败 → `lastError`；head/foot 失败 → `syncErrors` |
| 1' | 270–273 | 三者全 nil → `loadCache()` 后 **return**（不进第 2 步，不写缓存、不置"服务器"） | — |
| 2 | 278–282 | `banners = h2.topBanners.map{…}` | 非空才覆盖 |
| 3 | 285–294 | 荣誉：`safeFetchArticles(achievements.columnId, 50)` → `honors`（icon 固定 `trophy.fill`） | 空则保留原值 |
| 4 | 296–353 | 新闻五通道：先在 312–316 记录真实 `newsColumnIds`；招生信息优先用 home2 自带 articles 且 `articleId = nil`（318–332）；其余逐栏目 `safeFetchArticles(50)` → `toNewsItem` → switch 分派 | 单栏目失败记 `syncWarnings`/`syncErrors`，不阻塞其他栏目 |
| 5 | 356–358 | `anyNewsUpdated` 为真 → `news = 五通道相加` | 保证失败时不把 news 清空 |
| 6 | 361–413 | 视频：`withTaskGroup(of: (Int, String?).self)` **并行**拉各文章详情提取视频 URL；师生/校园活动串行映射 | 单条失败 → url 为空串 |
| 7 | 416–427 | 院系：`extractDepartments(head.menus)` → 与 `defaultDepartments` 按名称模糊匹配合并（`findMatchingDefaultDept`），命中则用**预置完整数据**、未命中保留 API 新院系 | API 为空则不动 |
| 8 | 430–434 | `siteInfo = SiteInfo(…)`（缺省回退 `SchoolInfo.name` / `englishName`） | — |
| 9 | 437–451 | `recruitPhones` / `footerLinks` / `socialPlatforms`（均非空才覆盖） | — |
| 10 | 454–457 | `OrganizationManager.shared.updateSiteKeys(from: menus)`（跨模块副作用） | — |
| 11 | 460–470 | `saveCache()` → `dataSource = "服务器"` → `lastError` 汇总（`部分栏目同步失败（N项）`）→ 追加 warning → 收尾日志 | — |
| 12 | 477 | `Task { await loadZSWHomeData() }`（不阻塞） | 内部 catch |
| 13 | 479 | `Task { await loadSpecialtyData() }`（独立于招生网成功与否） | 内部重试 2 次 |

**两个结构性观察**：① 三个基础接口是**串行**的（253–267），最坏情况下顺序等待 3 次超时（各含 3 次重试）→ 首屏同步延迟上限很高；真正的并行只出现在视频详情（364）。② `doFullSync` 声明"永不抛出"（242），所有错误都被折叠成 `lastError`/`syncErrors`/`syncWarnings`，因此调用方无从获知失败原因类型。

**新闻栏目 key 与业务名的对照表**（源码注释 296–302 原样记录，含两处命名误导）：

| API key | title_cn | 映射字段 | 备注 |
|---|---|---|---|
| `importants` | 学校要闻 | `importantNews` | — |
| `updates` | 新闻资讯 | `updateNews` | — |
| `resports` | 党建动态 | `partyNews` | key 名误导（应为 reports） |
| `notices` | 通知公告 | `notices` | — |
| `informations` | 招生信息 | `admissionNews` | key 名误导；服务端 API 返回 500，故优先用 home2 内联 articles |

### 3.6 并行 TaskGroup 与分页

**视频并行（364–388）**：

```text
withTaskGroup(of: (Int, String?).self) { group
    for (index, a) in list.enumerated() where a.id 非空:
        group.addTask { (index, await Self.fetchVideoUrl(articleId: a.id)) }   # 366–370
    收集 → videoUrls: [Int: String]（按 index 回填，忽略 nil/空）              # 372–377
    for (index, a) in list.enumerated(): 按原顺序组装 CampusVideo              # 378–386
}
videos = videoItems.sorted(by: { $0.0 < $1.0 }).map(\.1)                      # 388
```

设计意图：并发结果按 **index 回填再按 index 排序**，抵消 TaskGroup 完成顺序不确定，保持服务端下发顺序。并发度无上限（`list` 有多少条就有多少个子任务）→ 首屏可能瞬时并发 N 个文章详情请求（风险：无 `maxConcurrent` 限制，与预取器的 4 并发形成对比）。

**分页（`safeFetchArticles`，695–722）**：

```text
all = []; seen = Set()
for page in 1...6:                                    # 硬上限 6 页
    do:
        result = try await fetchArticles(columnId, page, size: pageSize=50)
        guard let list = result.articles?.list, !list.isEmpty else break
        for a in list: key = a.id ?? a.title ?? ""; 非空且未见过 → 追加        # 按 id/title 去重
        if list.count < pageSize: break                # 末页判定
    catch:
        if NetworkError.serverError → syncWarnings.append("「label」栏目服务端暂不可用，已跳过")
        else → syncErrors.append("「label」第 page 页加载失败：…")
        break                                          # 不翻页、不重试（get 内部已重试 3 次）
return all
```

要点：单栏目最多 6×50 = 300 条；去重键 `id ?? title`；服务端业务错误（`serverError`）与网络错误被区分为 warning / error 两档，这是 UI 上"黄色警告 vs 红色错误"的数据来源。

### 3.7 缓存文件清单（JSON 键名 → 文件 → 含义）

**物理位置**：`FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! + "/SXJZIT_Cache/"`（157、161–163）；`cacheURL(key)` 拼 `"\(key).json"`（1008–1010）；写入用 `JSONEncoder().encode` + `Data.write(options: .atomic)`（1039–1042）；读取用 `JSONDecoder()`（1076–1081）。

**A. `saveCache()` 的 21 个键（1012–1037）**：

| # | 键名 | 落盘类型 | 含义 |
|---|---|---|---|
| 1 | `news` | `[NewsItem]` | 五通道合并后的全部新闻 |
| 2 | `honors` | `[Honor]` | 校园荣誉 |
| 3 | `departments` | `[Department]` | 院系（API 合并预置数据后的结果） |
| 4 | `banners` | `[Banner]` | 首页轮播（视频+海报+标题图） |
| 5 | `bottom_banners` | `[Banner]` | 底部轮播（当前无远程写入点） |
| 6 | `videos` | `[CampusVideo]` | 校园视频（含从文章正文提取的 videoUrl） |
| 7 | `student_stories` | `[StudentStory]` | 学生故事 |
| 8 | `teacher_profiles` | `[TeacherProfile]` | 教师风采 |
| 9 | `campus_sceneries` | `[CampusScenery]` | 校园风光（首页模块已退役，仅兼容展示） |
| 10 | `campus_activities` | `[CampusActivity]` | 校园活动 |
| 11 | `footer_links` | `[FooterLink]` | 底部友情链接 |
| 12 | `social_platforms` | `[SocialPlatform]` | 社交平台 |
| 13 | `recruit_phones` | `[String]` | 招生咨询电话 |
| 14 | `important_news` | `[NewsItem]` | 学校要闻 |
| 15 | `update_news` | `[NewsItem]` | 新闻资讯 |
| 16 | `party_news` | `[NewsItem]` | 党建动态 |
| 17 | `notices` | `[NewsItem]` | 通知公告 |
| 18 | `admission_news` | `[NewsItem]` | 招生信息 |
| 19 | `campus_news` | `[NewsItem]` | 校园新闻（无远程写入点，遗留） |
| 20 | `research_reports` | `[NewsItem]` | 科研报告（同上） |
| 21 | `information_news` | `[NewsItem]` | 信息公告（同上） |

**B. 另 2 个键（不在 `saveCache()` 内）**：

| # | 键名 | 写入 / 读取 | 含义 |
|---|---|---|---|
| 22 | `zsw_home` | `saveZSWCache` 1123–1125 / `loadZSWCache` 1127–1131 | 招生网首页聚合数据 `ZSWHomeData` |
| 23 | `specialty` | `saveSpecialtyCache` 1135–1137 / `loadSpecialtyCache` 1139–1143 | 专业介绍 `SpecialtyData` |

→ **合计 23 个 JSON 文件**（任务描述中的"21 个"对应 `saveCache()` 的 21 个核心键）。

**C. 三个集合的差异（实测）**：

| 操作 | 覆盖键数 | 差异 |
|---|---|---|
| `saveCache()` 1012–1037 | 21 | 不写 zsw_home / specialty（各有独立写入口） |
| `loadCache()` 1044–1074 | 21（读取）；仅 3 个影响 `loaded` | 不读 zsw_home / specialty（由 init 169/171 单独加载） |
| `clearCache()` 1083–1119 | **22**（21 + `zsw_home`） | ⚠️ **遗漏 `specialty`** → 清缓存后 `specialty.json` 残留、下次启动 `loadSpecialtyCache()` 仍会读回旧数据（与 `dataSource = "预置数据"` 的语义不一致）；同时**不清 NSCache、不重置 `cachedArticleCount` / `estimatedCacheMemoryBytes`、不删 URLCache** |

### 3.8 文章详情缓存链路

**NSCache 与限额（111–125）**：

| 缓存模式 | `countLimit` | `totalCostLimit` | 依据 |
|---|---|---|---|
| 缓存模式（`CacheModeManager.isCacheEnabled`） | 200 | 80 MB | 118–120 |
| 即时模式 | 50 | 20 MB | 121–124 |

`refreshCacheLimits()`（127–133）：重新套用限额并记日志（含 `ByteCountFormatter` 格式化），供设置页在模式切换后调用。
键空间约定：主站详情用 `articleId`（744），招生网详情用 `"zsw_\(articleId)"`（841）——`isArticleDetailCached`（135）与 `isZSWArticleCached`（139）分别对应。
`incrementCacheEstimate`（146–153）与 `cachedArticleCount` / `estimatedCacheMemoryBytes`（143–144）是**只增不减的估算计数器**：NSCache 自行淘汰时不回调、`clearArticleDetailCache()`（833–836）也不重置 → 统计面板数字会随会话单调上升（数据准确性风险）。

**`loadArticleFullDetail(articleId:)`（742–785）**：

```text
start = now; key = articleId as NSString
if let cached = articleDetailCache.object(forKey: key):        # 746 命中
    CacheModeManager.recordHit(articleId, cacheAge)             # 749
    log("文章详情缓存命中，秒开呈现", cacheAge/lookupTime/mode)   # 750–755
    return cached.detail                                       # 零网络
CacheModeManager.recordMiss(articleId)                          # 759
detail = try await fetchArticleDetail(articleId, useCache: true) # 764 → cachedSession
result = parseArticleDetail(detail, articleId)                  # 766 nonisolated
cost   = plainText.utf8.count + content.utf8.count + images.count * 512   # 769
cache.setObject(entry, forKey: key, cost: cost); incrementCacheEstimate(…) # 770–771
CacheModeManager.recordSavedTraffic(content+plainText 字节数)     # 774
return result
```

**`loadZSWArticleFullDetail(articleId:siteId:)`（839–881）** 三点差异：① 读缓存前先判 `CacheModeManager.shared.isCacheEnabled`（843）——即时模式下**不读** zsw 缓存；② 只有缓存模式才写缓存（865）；③ 命中/未命中统计用 `"zsw_" + id` 记账。命中返回前同样 `recordHit`。

**`preloadArticleDetail(articleId:)`（789–830）**：通知点击场景的预热。命中即返回（791–796）；否则 `Task.detached`（799，**非结构化、无句柄**）→ fetch(useCache: true) → `parseArticleDetail` → `await MainActor.run` 写 NSCache（812–814，仅写缓存、**不计 cost、不更新估算计数器**——与主路径不一致）。无 in-flight 去重：同一 id 并发预加载会重复请求（风险）。

**`loadArticleDetail(articleId:)`（735–738）**：轻量版，`fetchArticleDetail`（默认 `useCache: false` → 实时会话）后返回 `content ?? description ?? ""`（不解析、不缓存）。

### 3.9 `parseArticleDetail` / `extractImages` 算法要点

**`nonisolated private func parseArticleDetail(_:articleId:) -> ArticleFullDetail`（884–906）**：

```text
rawContent = detail.content ?? detail.description ?? ""        # 885 content 优先
plainText  = rawContent.strippingHTMLTags()                    # 纯正则（见 §4.4）
images     = extractImages(from: rawContent)                   # 887 注意：从 rawContent 提图
displayContent = rawContent.isEmpty ? (detail.description ?? "") : rawContent   # 889–894
plainTextContent = plainText.isEmpty ? (detail.description ?? "").strippingHTMLTags() : plainText  # 899 二级兜底
return ArticleFullDetail(title/author/source/createTime 均 ?? "", images, articleId)
```

要点：① `content` 字段是**原始 HTML**（含标签），`displayContent` 直接给富文本视图用；② **图片只从 `rawContent` 提取**——若 `content` 为空而图片信息在 `description`/`imageUrl` 中，则 `images` 为空（封面兜底只在 `fetchSceneryAlbumDetail` 1168–1171 实现）；③ 全部字段空值归一为空串而非 nil。

**`nonisolated private func extractImages(from html:) -> [ArticleImage]`（935–965）**：正则与 `NetworkService.extractImagesFromHTML` 完全一致（见 §1.9），差异是产出 `ArticleImage(url:alt:)`（`Identifiable`，id = url）且带 3 处 `print` 调试输出。

**`extractVideoUrlFromHTML`（920–932）**：`#"<source\s+src="([^"]+)""#`（大小写不敏感，**仅双引号**、**只取第一个匹配**）→ 供 `fetchVideoUrl`（909–917，内部 catch 返回 nil）并行调用。

**`safeImageURL`（968–1004）**：`nonisolated`，逻辑与 NetworkService 版本逐行等价（三阶段 + percent 白名单含 `%`），差别是编码失败时返回原串而非带 `print` 的兜底链。**两个实现完全重复**（同一算法在两处维护，属明确的技术债；任何一侧修复都需同步另一侧）。

### 3.10 招生网 / 专业介绍加载与 SWR

**`loadZSWHomeData()`（485–604）**：`zswIsLoading` + `defer` 复位；SWR 条件（490–496）：缓存模式 ∧ 已有 `zswHomeData` ∧ 距 `lastZSWFetchTime` < 1800 s → 直接用缓存跳过远程；否则 `fetchZSWHome2` → 解析 5 个区块：

| 区块 | 来源 | 产出 | 缺省兜底标题 |
|---|---|---|---|
| 首页三栏目 | `nav[0].data.one.children.list` | `[ZSWRecruitItem]`（含 `isOut == 1` 判定） | — |
| 招生计划 | `data.enrollment-plan` | `ZSWSection` | "招生计划" / `enrollment-plan` / componentType "news" |
| 招生公告 | `data.notice` | `ZSWSection` | "招生公告" / `notice` |
| 报考指南 | `data.application-guide.children.list` | `[ZSWGuideChild]`（columnId = id） | — |
| 招生动态 | `data.enrollment-news` | `ZSWSection` | "招生动态" / `enrollment-news` / componentType "notice" |

成功后：`zswHomeData = homeData` → `lastZSWFetchTime = now` → `saveZSWCache` → 追加 syncLog → **再次触发** `Task { await loadSpecialtyData() }`（600，与 doFullSync 479 形成双触发）。失败只记 syncLog 警告（601–603）——**不写 lastError**。

**`loadSpecialtyData()`（607–644）**：siteId 取 `zswHomeData?.siteId ?? "cb3b…"`（611）；**columnId 硬编码** `25d7bd39e49a468880356e302b9ccf1d`（612，注释与"严禁硬编码"原则冲突）；自带重试 2 次、每次间隔 1 s（615–637）；成功后写 `specialtyData` + `saveSpecialtyCache` + syncLog（含学院数/专业总数）；最终失败记 error 日志。注意：**它自带重试，而 `NetworkService.get` 内部已有 3 次尝试** → 最坏 3×3=9 次请求。

### 3.11 文章搜索栏目服务与日期/院系工具

- `articleSearchColumnEntries()`（650–659）：按固定顺序 `[学校要闻, 新闻资讯, 党建动态, 通知公告]` 输出 `(名称, column_id)` 快照，缺 ID 的跳过（招生信息**不参与**搜索）。
- `refreshNewsColumnIdsFromHome2()`（662–692）：现场拉 home2 刷新 5 个栏目 ID（含招生信息），成功返回 `!entries.isEmpty`；失败返回 false，供机构页搜索在缓存缺失时兜底。
- `formatDate`（1173–1193）：依次尝试 `yyyy-MM-dd HH:mm:ss`、`yyyy-MM-dd`、`yyyy-MM-dd'T'HH:mm:ss`，再退回 `ISO8601DateFormatter`，最后截前 10 字符；输出统一 `yyyy.MM.dd`。⚠️ 每次调用**新建 4 个 DateFormatter**（无缓存）→ 在 300 条 × 多栏目的循环里是可观的重复开销（风险，未量化）。
- `findMatchingDefaultDept`（1196–1207）：先忽略首尾空格精确匹配，再双向 `contains` 模糊匹配；命中即用预置 `Department`（保留专业/子部门等详细信息），未命中保留 API 名称。
- `extractDepartments`（1209–1222）：在 `head.menus` 中找 `titleCn.contains("教学")` 或 `titleEn == "academics"` 的父节点，取其 children 映射为 `Department`（`intro` 固定空串、`icon` 由 `pickIcon` 按名称关键词猜、`siteKey` 由 `extractSiteKey` 解析）。
- `extractSiteKey(from:)`（1224–1231）：从 `path` 中截取 `site_key=` 到 `&` 之间的值（简单的字符串切割，不解析 URL）。
- `pickIcon(for:)`（1233–1246）：11 条关键词 → SF Symbol 的 `if contains` 规则表，兜底 `building.2.fill`。

### 3.12 Task 与取消处理（现状与本任务预期的差异）

**实测结论：本批 4 个文件中不存在任何 `Task.isCancelled` / `Task.checkCancellation` / `CancellationError` / `withTaskCancellationHandler` 判断**（`grep -n "isCancelled\|CancellationError\|Task.checkCancellation\|withTaskCancellationHandler"` 对这 4 个文件返回空）。全仓库的 `Task.isCancelled` 全部位于视图层（TabBar.swift 12 处、NetworkMonitorView、HelpGuideView 等），属"视图任务取消"，**不覆盖数据层**。

数据层实际的"取消/并发"处理只有 3 种形态：

| 形态 | 实现 | 行号 | 局限 |
|---|---|---|---|
| 取消语义下传 | `URLError.cancelled` → 不重试、不记 ERROR、直接 rethrow | NetworkService 102–107 / 150–155 | 这是**对取消的正确响应**，但发起方无法取消（见下） |
| 门闸式互斥 | `guard !isLoading` + `lastSyncTime` 冷却 10 s / 600 s | DataService 181 / 183 / 188 | 只能"拒绝新同步"，不能"中断旧同步" |
| 非结构化后台任务 | `Task { doFullSync() }`（202）、`Task.detached`（799）、`Task { await loadZSWHomeData() }`（477/479/600） | — | **不保存句柄 → 无取消路径**；`preloadArticleDetail` 的 detached 任务还可能在视图销毁后继续（有 `[weak self]` 但在 `guard let self` 之后即强持有至结束，803–808） |

附带风险：`try? await Task.sleep(...)`（NetworkService 114/162、DataService 634）会**吞掉 CancellationError**，因此任务被取消后不会立即退出退避，而是继续下一轮。

---

## 4. RefererHeaderURLProtocol 深度分析

### 4.1 全局拦截实现原理（18–135）

```text
canInit(with:)                                        # 47–55
  条件 = url.scheme.hasPrefix("http")                  # ① 同时匹配 http / https
       ∧ url.host.contains("sxjzit.edu.cn")            # ② 子串匹配（非后缀/等值匹配）
       ∧ URLProtocol.property(handledKey) == nil        # ③ 防自递归标记
startLoading()                                        # 61–126
  ① 复制可变请求；setProperty(true, handledKey)          # 62–65 打标记
  ② setValue("https://www.sxjzit.edu.cn/", "Referer")   # 68 硬编码防盗链 Referer
     setValue(Safari 17 / iPhone UA, "User-Agent")      # 69–72
  ③ 若判定为图片请求：cachePolicy = 缓存模式 ? .returnCacheDataElseLoad : .useProtocolCachePolicy  # 75–79
  ④ SJZNetworkMonitor: tapRequestStart(host) → token    # 84–86
                        tapUploadEstimate(req, token)   # 88（仅内存 httpBody，流式不计量）
  ⑤ sharedSession.dataTask(with: original) { … }        # 90
        error?  cancelled → tapAbandon(幂等)；其他 → tapComplete(success:false) → didFailWithError   # 96–105
        response → tapFirstByte → didReceive(enhancedResponse, cacheStoragePolicy: .allowed)          # 106–115
        data     → tapData(bytes) → didLoad                                                           # 116–119
        完成     → tapComplete(success:true) → urlProtocolDidFinishLoading                             # 120–121
        logImageResponseIfNeeded（每 URL 首见节流）                                                     # 123
stopLoading()                                         # 128–135
  monitorToken 非空 → tapAbandon；dataTask.cancel()；置 nil
```

**共享会话（28–34）**：`static let sharedSession`——`timeoutIntervalForResource = 120`、`waitsForConnectivity = false`、`protocolClasses = [self]`。注释（26–27）说明意图：连接复用 + 统一走 `URLCache.shared`，替代历史上"每请求新建会话 + `.notAllowed` 禁止一切缓存"的写法（文件头 7–13 记录了这次修复的动机）。

### 4.2 白名单 / 黑名单规则（实际规则，非配置化）

| 维度 | 规则 | 行号 |
|---|---|---|
| scheme 白名单 | `scheme?.hasPrefix("http") == true`（等价 http/https，含 `https`） | 49 |
| host 白名单 | `host.contains("sxjzit.edu.cn")`（**子串**匹配） | 50 |
| 递归黑名单 | 请求上已带 `handledKey` 属性 → 不拦截（自己发出的请求不再被拦） | 54 / 65 |
| 图片扩展名白名单 | `jpg, jpeg, png, gif, webp, bmp, heic, jfif, svg, ico`（10 个） | 37–39 |
| 图片路径兜底标记 | `uploads, upload, images, image, img, pics, pic, media, attach, attachments, file, files, photos, picture`（14 个 pathComponent） | 156–159 |
| Accept 头兜底 | `Accept` 含 `image/` | 146–149 |
| no-store 尊重 | 响应头 `Cache-Control` 含 `no-store` → 不注入 | 182 |

**没有集中式白/黑名单配置**：所有规则以字面量内联，第三方 CDN 若域名恰含 `sxjzit.edu.cn` 亦会被改写 UA（见风险 R1）。

### 4.3 图片判定与缓存头注入算法

```text
isLikelyImageRequest(req):                        # 140–153（按 URL 特征"预判"）
    扩展名 ∈ imageExtensions                      → true
    Accept 含 "image/"                            → true
    pathComponents ∩ mediaPathMarkers ≠ ∅         → true
    else false

isImageResponse(resp, req):                       # 162–167（按响应"确认"）
    resp.mimeType.hasPrefix("image/")             → true
    else isLikelyImageRequest(req)                # 回落到请求预判

enhancedResponse(resp, req):                      # 172–201
    guard HTTPURLResponse ∧ 状态码 200...299 ∧ isImageResponse else 原样返回
    existing = allHeaderFields["Cache-Control"] ?? ["cache-control"] ?? ""
    guard !existing.lowercased().contains("no-store") else 原样返回      # 180–182 尊重隐私指令
    fields = allHeaderFields 中 key/value 均为 String 的项（非 String 丢弃）  # 185–190
    fields["Cache-Control"] = "public, max-age=604800"                   # 191（7 天）
    return HTTPURLResponse(同 url/statusCode/httpVersion "HTTP/1.1"/fields) ?? 原响应  # 192–199
```

设计取舍（注释 180–181 明示）：除 `no-store` 外，即便是 `no-cache` / `max-age=0` 这类"过弱指令"也会被 7 天覆盖——目的是让滚动往返真正不再复连。

### 4.4 埋点与日志

- `SJZNetworkMonitor` token 生命周期覆盖全部终止路径：成功（120）、失败（101）、取消（99 与 stopLoading 131 双保险，注释 21 说明"防取消路径台账滞留"）；TTFB 用 `tapFirstByte`（108），口径注释 107 说明"慢请求判定不受大文件下载时长拖累"。
- 上行估算只计 `httpBody`（88，注释 87 自称"诚实口径"）。
- 日志节流：`loggedURLs`（静态 `Set<String>` + `NSLock`，42–43）保证**每个 URL 只记一次**，用 `Task { @MainActor in LogManager.shared.debugLog("urlProtocol", …) }`（225–233）跨线程写入；字段含 url 文件名、status、`fromCache`（用 `URLCache.shared.cachedResponse` 反查 211–214）、contentType、cacheMode。
- ⚠️ `loggedURLs` **无上限、无淘汰**（216–219）→ 长会话下随浏览图片数单调增长（内存漂移风险）。

### 4.5 与 NetworkService 的关系

| 关系 | 事实 | 位置 |
|---|---|---|
| 会话注册 | NetworkService 的两个会话都 `protocolClasses = [RefererHeaderURLProtocol.self]` | NetworkService 59 / 71 |
| 全局注册 | App 启动仍调用 `URLProtocol.registerClass(RefererHeaderURLProtocol.self)` | DesignCodeApp.swift:29 |
| 其它自建会话 | TabBar.swift:12400、AnnouncementManager.swift:62、SchoolProfileView.swift:2681、OrganizationManager.swift:184 各自注册 | 跨文件（仅索引） |
| 主动排除 | SJZNetworkMonitor 的探测会话显式 `config.protocolClasses = nil`（4 处） | SJZNetworkMonitor 972 / 1398 / 1592 / 1747 |
| 模式联动 | 协议层从 `CacheModeManager.isCacheEnabledFromAnyThread` 读缓存开关（非主线程安全入口） | Referer 76 / 224 |
| 依赖方向 | NetworkService → 协议层（注册）；协议层 → CacheModeManager / SJZNetworkMonitor / LogManager（**无反向依赖 NetworkService**，无循环） | — |

### 4.6 风险点清单

| ID | 风险 | 证据 | 影响 |
|---|---|---|---|
| R1 | host 用 `contains` 子串匹配 → `https://sxjzit.edu.cn.attacker.com/…` 会被拦截并改写 UA/Referer | 50 | 请求指纹被改成 Safari、带宽上行走代理层；不泄露 Authorization（本 App 不注入凭据），但属明确的规则缺陷 |
| R2 | 无条件覆盖 `Referer` / `User-Agent`（`setValue` 覆盖调用方已设值） | 68–72 | 调用方无法自定义 UA；第三方接口若校验 UA 会收到伪装值 |
| R3 | `cacheStoragePolicy` 恒为 `.allowed`，即使响应带 `no-store`（只是不注入缓存头） | 113 / 182 | 与 `no-store` 语义存在偏差（URLCache 仍可能存储） |
| R4 | 重建 `HTTPURLResponse` 时非 String 头值被丢弃；`httpVersion` 硬编码 "HTTP/1.1" | 185–197 | 极端情况下头部信息丢失（字段名大小写、多值头） |
| R5 | `loggedURLs` 无界增长 | 42–43 / 216–219 | 长会话内存漂移 |
| R6 | scheme 判定 `hasPrefix("http")` 且未限制端口/重定向 | 49 | 概念上匹配任何 http* 前缀 scheme；重定向目标不再复核 |
| R7 | 无法覆盖 WKWebView（其网络栈不走 URLProtocol）；对 AVPlayer 的 Range/分段请求无特殊处理 | — | 防盗链对 WebView 内资源无效；视频拖动行为未验证（§8-2） |
| R8 | 拦截层为**所有** https 会话引入额外一跳（协议层转发 + 埋点 + 主线程日志投递） | 90 / 225 | 每个请求的固定开销；主线程日志洪泛时可能影响滚动（未量化） |

---

## 5. Models.swift 深度分析

### 5.1 `enum SchoolInfo`（10–40）——编译期常量集中点

23 个 `static let` 字符串 + 1 个多行 `description`（33–39）。**被代码实际引用的关键项**：`website`（`safeImageURL` 拼相对路径：NetworkService 365、DataService 979/984；`NewsItem.originalArticleURL` 415/419；`BookmarkItem.originalArticleURL` 1510/1513）、`name` / `englishName`（`siteInfo` 缺省回退：DataService 431）。

| 分组 | 常量（值） |
|---|---|
| 标识 | `name` 山西晋中理工学院、`englishName`、`motto` 谨信博学 · 经世致用 |
| 沿革 | `foundedYear` 2002、`convertedYear` 2021、`anniversary` 10月9日、`predecessor` 中北大学信息商务学院、`type` 民办全日制普通本科、`affiliation` 山西省教育厅 |
| 联系 | `address`、`phone` 0351-3624911、`recruitPhones` 3 个号码、`email`、`postalCode` 030600 |
| 规模 | `campusArea` 1000余亩、`buildingArea` 33万平方米、`libraryBooks` 120余万册、`teachingInstruments` 总值9000余万元、`studentCount` 16945、`majorCount` 44、`departmentCount` 10 |
| 网络 | `website` = `https://www.sxjzit.edu.cn`（相对路径解析基准） |
| 简介 | `description`（3 段多行文本，33–39） |

### 5.2 全部业务模型清单（28 struct + 1 enum）

| # | 模型 | 行号 | 字段 | 用途 / 兜底常量 |
|---|---|---|---|---|
| 1 | `SchoolInfo`(enum) | 10–40 | 23 常量 + description | 学校静态信息 |
| 2 | `Banner` | 44–49 | videoSrc, posterImgSrc, videoTitleImgSrc；id = videoSrc | 首页轮播；`defaultBanners` 51–61（3 条，**无引用**） |
| 3 | `StatItem` | 65–70 | value, label, icon；id = value+label | 数据概览；`defaultStats` 72–77（4 条，被 DataService 26 使用） |
| 4 | `Honor` | 81–95 | title, detail, icon, imageUrl?, tag?, date?, **var articleId?**；id = articleId ?? title | 校园荣誉；`defaultHonors` 97–110（12 条） |
| 5 | `Department` | 114–129 | name, englishName, icon, intro, siteKey?, **var subDepartments**, **var majors**；id = name | 院系；`defaultDepartments` 140–373（**11 条**院系，含内嵌 `Major` 明细，体量最大的兜底常量） |
| 6 | `Major` | 131–138 | name, category, duration, intro, career；id = name | 专业 |
| 7 | `NewsItem` | 377–424 | title, date, category, summary, content, imageUrl?, columnId?, **var articleId?**, href?, author?, source?；id = title+date；`readKey` = articleId ?? id；`originalArticleURL` 四级构造 | 全部新闻通道的统一模型；`defaultNews` 426–487（12 条） |
| 8 | `StudentStory` | 491–498 | title, summary, imageUrl?, date?, **var articleId?**；id = articleId ?? title | 学生故事；`defaultStudentStories` 500–521（5 条，**无引用**） |
| 9 | `TeacherProfile` | 525–532 | 同上结构 | 教师风采；`defaultTeacherProfiles` 534–555（5 条，**无引用**） |
| 10 | `CampusVideo` | 559–565 | title, videoUrl, thumbnailUrl?, description?；id = title+videoUrl | 校园视频；`defaultVideos` 567–588（5 条，**无引用**） |
| 11 | `CampusActivity` | 592–600 | title, summary, imageUrl?, date?, englishTitle?, **var articleId?**；id = articleId ?? title | 校园活动；`defaultCampusActivities` 602–627（6 条） |
| 12 | `CampusScenery` | 631–636 | title, imageUrl?, description?；id = title | 校园风光（首页模块已退役）；`defaultCampusSceneries` 638–669（10 条） |
| 13 | `CampusService` | 673–678 | name, icon, url；id = name | 校园服务入口（含 `sxjzit://` 深链）；`defaultServices` 680–688（7 条） |
| 14 | `FacilityInfoPair` | 693–697 | label, value；id = label | 设施"标签—数值"行 |
| 15 | `FacilitySection` | 700–732 | title, subtitle?, desc, highlights[], infoPairs?, accentHex?；**自定义 Codable** | 设施分区卡片 |
| 16 | `Facility` | 734–758 | name, icon, desc, details[], sections?；**自定义 Codable** | 校园设施；`defaultFacilities` 760–1351（5 个设施，约 590 行，最大常量块） |
| 17 | `TimelineEvent` | 1355–1359 | year, event；id = year+event | 发展历程；`defaultTimeline` 1361–1368（6 条） |
| 18 | `QuickLink` | 1372–1380 | **`let id = UUID()`**, title, icon；CodingKeys 排除 id | 快捷链接；`quickLinks` 1382–1389（6 条，被 TabBar 使用） |
| 19 | `FooterLink` | 1393–1397 | name, href；id = name | 友情链接（远程） |
| 20 | `SocialPlatform` | 1401–1405 | title, img；id = title | 社交平台（远程） |
| 21 | `ZSWArticle` | 1410–1425 | articleId(CodingKey "id"), title, description, imageUrl?, updateTime?, tag?；id = articleId ?? **UUID()** | 招生网文章 |
| 22 | `ZSWSection` | 1428–1435 | id, columnId, titleCn, titleEn, componentType, articles[] | 招生网栏目 |
| 23 | `ZSWGuideChild` | 1438–1444 | id, columnId, titleCn, titleEn, articles[] | 报考指南子栏目 |
| 24 | `ZSWRecruitItem` | 1447–1455 | id, titleCn, titleEn, href, imageUrl?, isOut(→Bool), articles[] | 首页三栏目 |
| 25 | `ZSWHomeData` | 1458–1465 | siteId, recruitItems[], enrollmentPlan?, notices?, guideChildren[], enrollmentNews? | 招生网聚合根（缓存键 `zsw_home`） |
| 26 | `BookmarkItem` | 1470–1564 | title, date, category, summary, imageUrl?, articleId?, href?, author?, source?, columnId?, bookmarkDate, cachedContent?, contentCached, lastViewedAt?, updateDetectedAt?；`hasPendingUpdate` / `hasCachedContent` / `readKey` / `originalArticleURL`；`init(from: NewsItem)`、`toNewsItem()` | 收藏（**归属"通知与收藏"章节**，此处仅登记） |
| 27 | `SpecialtyMajor` | 1569–1581 | articleId(CodingKey "id"), title, description, imageUrl? | 专业介绍条目 |
| 28 | `SpecialtyCollege` | 1584–1596 | id, titleCn, titleEn, majors[] | 学院分组 |
| 29 | `SpecialtyData` | 1599–1609 | columnId, titleCn, colleges[] | 专业介绍根（缓存键 `specialty`） |

**id 稳定性风险（SwiftUI diff 语义）**：`ZSWArticle.id` 用 `UUID().uuidString` 作兜底（1411）→ articleId 为 nil 时**每次访问都产生新 id**，`ForEach` 会认为全部元素变更；`QuickLink` 的 `id = UUID()` 在 `CodingKeys` 中被排除（1377–1379）→ 解码后 id 不稳定；`NewsItem.id = title + date`（378）→ 同标题同日期的不同文章会撞 id。

### 5.3 静态兜底数据 `default*` 常量清单与真实引用情况

| 常量 | 行号 | 项数规模 | 被引用 | 引用点 |
|---|---|---|---|---|
| `defaultBanners` | 51–61 | 3 | ❌ **0 引用**（`banners` 初值为 `[]`） | — |
| `defaultStats` | 72–77 | 4 | ✅ | DataService 26 |
| `defaultHonors` | 97–110 | 12 | ✅ | DataService 27 / 1094 / 1199 / 1203 |
| `defaultDepartments` | 140–373 | 11 个院系（内嵌 majors） | ✅ | DataService 28 / 1095 / 1199 / 1203 |
| `defaultNews` | 426–487 | 12 | ✅ | DataService 29 / 1093 |
| `defaultStudentStories` | 500–521 | 5 | ❌ **0 引用** | — |
| `defaultTeacherProfiles` | 534–555 | 5 | ❌ **0 引用** | — |
| `defaultVideos` | 567–588 | 5 | ❌ **0 引用** | — |
| `defaultCampusActivities` | 602–627 | 6 | ❌ **0 引用** | — |
| `defaultCampusSceneries` | 638–669 | 10 | ❌ **0 引用** | — |
| `defaultServices` | 680–688 | 7 | ✅ | DataService 37 |
| `defaultFacilities` | 760–1351 | 5 个设施（含 sections 详情） | ✅ | DataService 38 |
| `defaultTimeline` | 1361–1368 | 6 | ✅ | DataService 39 |
| `quickLinks`（非 default 前缀） | 1382–1389 | 6 | ✅ | TabBar（跨文件） |

结论：**13 个 `default*` 常量中仅 7 个被引用，6 个栏目型兜底完全无引用**（另有 `quickLinks` 被 TabBar 使用）；这 6 个栏目型兜底（banners/videos/studentStories/teacherProfiles/campusActivities/campusSceneries）对应的 `@Published` 初值均为 `[]`，其兜底数据在代码中**无路径可达** → 属"死兜底"（若设计意图是"断网时也有内容可看"，则 Intent 与实现不一致；见 §8-8）。

### 5.4 DTO → 业务模型的映射关系

| 端点 / DTO | 映射函数（行号） | 业务模型 | 映射中丢失/产生的信息 |
|---|---|---|---|
| `Home2DTO.topBanners: [BannerDTO]` | DataService 280 | `[Banner]` | `?? ""` 空串归一 |
| `Home2DTO.achievements → articles.list: [ArticleDTO]` | 288–292 | `[Honor]` | icon 固定 `trophy.fill`；`createTime` → `formatDate` |
| `ArticleDTO` | `toNewsItem` 725–731 | `NewsItem` | title 用 `resolvedTitle`（title ?? title_cn）；`content = description`；保留 columnId/articleId/href |
| `ArticleDTO`（招生信息） | 321–325 | `NewsItem`（articleId 置 nil） | 招生信息无详情页 |
| `Home2DTO.videos.articles.list` + 详情 HTML | 362–388 | `[CampusVideo]` | videoUrl 从 `<source src>` 提取，失败为空串 |
| `Home2DTO.students/teachers/campus.children.activites` | 390–411 | `StudentStory` / `TeacherProfile` / `CampusActivity` | `tag` → `englishTitle` |
| `HeadDTO.menus` + `defaultDepartments` | `extractDepartments` 1209 → `findMatchingDefaultDept` 1196 | `[Department]` | 命中预置则**丢弃 API 名称以外的信息**（用预置完整数据） |
| `HeadDTO.site` | 431–433 | `DataService.SiteInfo` | 缺省回退 SchoolInfo |
| `FootDTO` | 438–449 | `[String]` / `[FooterLink]` / `[SocialPlatform]` | 空名过滤 |
| `ArticleDetailDTO` | `parseArticleDetail` 884–906 | `ArticleFullDetail` + `[ArticleImage]` | HTML → 纯文本 + 图片清单 |
| `ArticleDetailDTO`（图集） | `fetchSceneryAlbumDetail` 1164–1178 | `SceneryAlbumDetail` | content 无图时回退 `imageUrl` 封面 |
| `SpecialtyColumnDTO` | `fetchSpecialtyData` 895–910 | `SpecialtyData` / `SpecialtyCollege` / `SpecialtyMajor` | 缺 id/title 的学院与专业被 **compactMap 丢弃** |
| `ZSWHome2DTO` | `loadZSWHomeData` 501–594 | `ZSWHomeData` / `ZSWRecruitItem` / `ZSWSection` / `ZSWGuideChild` / `ZSWArticle` | `isOut == 1` → Bool；缺 columnId 的区块整体跳过 |
| `SchoolMsgDTO` | `fetchPrincipalMailbox` 1270–1283 | `MailboxMessage` / `MailboxPageData` | 缺 title **或** 缺 showTitle 的留言被丢弃 |
| `SchoolMsgDetailDTO` | `fetchMessageDetail` 1349–1357 | `MailboxMessageDetail` | `is_show_content == "1"` → Bool（**字符串比较**，1319/1352） |
| `SchoolOrgNode` / `DeptColumnRef` | `fetchSchoolOrgTree` 1002 / `fetchDeptSiteIndex` 1049 | 同名值类型（可直接 Codable 落盘） | 空串 → nil 归一 |

### 5.5 Codable 容错解码策略（三层，实测）

| 层 | 策略 | 位置 | 评估 |
|---|---|---|---|
| L1 远端 DTO | **字段几乎全 Optional**；28 处 `CodingKeys` 桥接 snake_case；仅 3 处自定义解码 | NetworkService 450–1524 | 缺字段/类型为 null 容错好；**类型变化（Int↔String）不容错**，会抛 `DecodingError` 并经 `get` 重试 3 次后向上冒泡 |
| L2 结构异质 | `try?` 逐键解码跳过非法节点（`DeptNavItemDTO.init(from:)` 1407–1431 + `DynamicCodingKeys` 1449–1454）；`AnyCodable` 618–644 吞任意值 | NetworkService | 明确针对"data 字典混入字符串元数据"的服务端行为 |
| L3 本地缓存 | 新增字段用 `decodeIfPresent`（`Facility.init(from:)` 749–757 的 `sections`、`FacilitySection.init(from:)` 723–731 的 `subtitle`/`accentHex`/`infoPairs`）；模型内联默认值 `var articleId: String? = nil` | Models.swift | 保证**旧版本缓存文件在新版本可读**；未加版本号/迁移机制，字段删除仍会导致整文件解码失败 → 退回 L3 静态兜底（这是"静默降级"而非崩溃，属可接受设计） |

**编码方向的非对称**：`AnyCodable.encode` 固定写 nil（640–643）；`DeptNavItemDTO.encode` 只做 `encodeIfPresent`（1434–1445，注释 1433 明示"仅用于缓存"）。即"解码宽容、编码收窄"，对本地缓存往返是自洽的。

---

## 6. 持久化位置与键名汇总

### 6.1 沙盒文件（唯一由本层直接管理的持久化）

| 项 | 值 | 位置 |
|---|---|---|
| 根目录 | `…/Documents/SXJZIT_Cache/`（`createDirectory(withIntermediateDirectories: true)`，失败静默） | DataService 157 / 161–163 |
| 文件名规则 | `"\(key).json"` | `cacheURL` 1008–1010 |
| 编码/解码 | `JSONEncoder()`（默认日期策略）/ `JSONDecoder()`（每次新建实例） | 1039–1042 / 1076–1081 |
| 写入原子性 | `Data.write(to:options:.atomic)` | 1041 |
| 文件数 | **23**（21 + `zsw_home` + `specialty`） | §3.7 |
| 清理 | `clearCache()` 删 22 个（**漏 `specialty`**）+ 重置内存状态 | 1083–1119 |

### 6.2 `URLCache`

| 实例 | 配置 | 位置 |
|---|---|---|
| `cachedSession` 专属 | memory 10 MB / disk 50 MB / diskPath `article_detail_cache` | NetworkService 66–69 |
| `URLCache.shared` | 由系统默认提供；`session`（列表会话）隐式使用；协议层读写它做图片缓存与命中判定 | NetworkService 55（未指定 urlCache）；Referer 8 / 211 |
| 清理 | **本批 4 个文件均无 `removeAllCachedResponses()` 调用** → URLCache 无失效入口（`clearCache()` 不管它） | — |

### 6.3 `NSCache`

| 项 | 值 | 位置 |
|---|---|---|
| 实例 | `articleDetailCache: NSCache<NSString, ArticleDetailCacheEntry>` | DataService 111–115 |
| 键空间 | 主站 `articleId`；招生网 `"zsw_\(articleId)"` | 744 / 841 |
| 限额（缓存模式） | count 200 / cost 80 MB | 118–120 |
| 限额（即时模式） | count 50 / cost 20 MB | 121–124 |
| cost 口径 | `plainText.utf8.count + content.utf8.count + images.count * 512` | 769（主路径） |
| 刷新入口 | `refreshCacheLimits()` | 127–133 |
| 清空入口 | `clearArticleDetailCache()`（不清估算计数器） | 833–836 |

### 6.4 `UserDefaults`（跨文件索引；**本批 4 文件内 0 处**）

| 键 | 归属文件（非本批） | 与数据层的关系 |
|---|---|---|
| `cacheMode` | CacheModeManager 167 | **直接决定** `session` 缓存策略、图片请求 cachePolicy、NSCache 限额、SWR 跳过逻辑 |
| `cacheHitCount` / `cacheMissCount` | 168 / 169 | `loadArticleFullDetail` 每次读写记账（749 / 759） |
| `cacheImageHitCount` / `cacheImageMissCount` | 170 / 171 | 图片命中（协议层/图片组件侧） |
| `cacheSessionStart` / `cacheSavedTrafficBytes` | 172 / 173 | `recordSavedTraffic`（774 / 871）累计 |
| `cacheImageFreeMode` / `cacheImageFreeSkippedCount` | 174 / 175 | 无图模式（`SJZCachedImage`） |
| `colorSchemePreference` / `notificationPermissionRequested` | TabBar 22 / 10560 | 与数据层无关（仅登记） |

> 说明：数据层**不直接使用 UserDefaults**；缓存模式的持久化由 `CacheModeManager`（`@AppStorage`/`UserDefaults` + `CacheModeMirror` 线程安全镜像，CacheModeManager 18–43 / 264–272）承担，`RefererHeaderURLProtocol` 通过 `nonisolated static` 入口跨线程读取（Referer 76 / 224）。

---

## 7. 关键结论（10 条）

1. **网络层是"无状态单例 + 双会话"结构**：`NetworkService` 非 `@MainActor`、`@unchecked Sendable`，靠"无共享可变状态"而非锁来保证并发安全；唯一可疑点是被并发共享的 `JSONDecoder`（§8-9）。
2. **双会话的唯一分流入口是 `fetchArticleDetail(useCache:)`**：列表走"忽略缓存"的实时会话，详情走"遵循 HTTP 语义"的缓存会话 + 独立 10 MB/50 MB URLCache；默认 `false` 意味着"实时是默认语义"。
3. **重试是 3 次 + 线性退避（0.5 s → 1.0 s）**，取消（`URLError.cancelled`）不重试、不记 ERROR；`try? await Task.sleep` 会吞掉 `CancellationError`（退避期间取消不即时生效）。
4. **端点清单：已知 HTTP 路径 13 个**（11 个在 NetworkService 内定义 + 2 个经 `fetchJSONDict` 透传的 `/school/intro`、`/school/cooperate`），另有 2 条任意 URL 通道（文章 `href`、短链 HEAD）；`/dept/home2` 被 4 个方法以 4 种解析策略复用；`fetchArticleDetailWithHref` 无调用点。
5. **DTO 规模 45 个（解码类型 52 个）**，远端容错主要靠"字段全 Optional + CodingKeys"，只有 `AnyCodable`、`DeptNavItemDTO` 两处做真结构容错；HTTP 层只校验状态码，**JSON `code` 字段从未被读取**。
6. **DataService 是唯一的业务状态中心**（35 个 `@Published`），三层降级（远程 → 沙盒 JSON → 静态兜底）通过 `dataSource` 字符串对外可见；逐栏目 `!isEmpty` 前置判断保证"部分失败不清空已有数据"。
7. **缓存落盘 23 个 JSON 键**（21 + `zsw_home` + `specialty`）；`clearCache()` **漏删 `specialty.json`**，且完全不管 NSCache 与 URLCache。
8. **不存在数据层取消机制**：本批 4 文件无任何 `Task.isCancelled`（全仓库 0 处），并发控制只有 `isLoading` 门闸 + 10 s/600 s 冷却；`doFullSync` 的 Task 与 `preloadArticleDetail` 的 `Task.detached` 均未保存句柄。
9. **`RefererHeaderURLProtocol` 是全局副作用层**：以 `host.contains("sxjzit.edu.cn")` 的宽松规则拦截所有 http/https 请求，改写 UA/Referer、注入 7 天图片缓存头、恒用 `.allowed` 存储策略，并承担埋点；宽松匹配与无界 `loggedURLs` 是主要缺陷。
10. **可维护性债务集中在"重复实现"与"死代码"**：`safeImageURL` 与提图正则在两处逐字重复；6/14 个 `default*` 兜底常量无任何引用；`fetchArticleDetailWithHref`、`bottomBanners`、`campusNews`/`researchReports`/`informationNews`（`campusSceneries` 例外，已明确退役）均为无远程写入点的遗留通道。

---

## 8. 未验证点清单

| # | 未验证内容 | 为什么未验证 | 建议验证方式 |
|---|---|---|---|
| 1 | 服务端真实响应与 45 个 DTO 的逐字段一致性 | 本次只做静态分析，未发请求 | 对照 `qin/docs/departments-api-evidence/raw/*.json` 或抓包 |
| 2 | `RefererHeaderURLProtocol` 对 AVPlayer 流式/Range 请求的实际行为 | 需真机运行 | 真机播放 + netmon 台账 |
| 3 | ATS 是否放行 `http://` 图片（本批 4 文件**无 http→https 改写**） | 需读 Info.plist 且需运行验证 | 检查 `NSAppTransportSecurity`；构造 http 图片 Demo |
| 4 | `fetchArticleDetailWithHref`（207）是否真为 dead code | grep 无调用点，但可能存在动态调用 | 全局搜索 + 运行期断点 |
| 5 | `JSONDecoder` 共享实例的线程安全性 | 需并发压测 | 高并发 decode 压测 / Instruments Thread Sanitizer |
| 6 | 退避期间取消的实际延迟（`try?` 吞 CancellationError） | 需运行时观测 | 单元测试：取消后测量耗时 |
| 7 | `SXJZIT_Cache` 目录运行期实际文件数（静态推导 23） | 需运行 App | 真机沙盒导出 |
| 8 | `clearCache()` 漏删 `specialty.json` 的实际影响（是否造成"清缓存后仍显示旧专业数据"） | 静态推导 | 运行验证：清缓存 → 重启 → 观察专业介绍 |
| 9 | `dataSource` 三个取值在 UI 的消费点与文案 | 属其他章节范围 | 见"应用外壳/TabBar"章节 |
| 10 | 主线程负载（`doFullSync` 内 compactMap、`formatDate` 每次新建 4 个 DateFormatter、每请求一次主线程日志跳转） | 未做性能度量 | Instruments Time Profiler / 主线程 hang 检测 |
| 11 | `networkMonitor` 的 `/dept/home2` 指纹轮询在真实服务端的去重效果 | 需真实数据 | 对照党建子站真实响应 |
| 12 | `loggedURLs` 无界增长的量级（单次会话图片数） | 未运行 | Instruments Allocations |

---

## 9. 附：本批文件内部的依赖（仅列被本批文件直接调用的外部符号）

| 外部符号 | 被调位置 | 归属章节（他人负责） |
|---|---|---|
| `LogManager.shared.{info,debugLog,warning,error}`（@MainActor） | NetworkService 93/103/110/116/141/151/158/164/267/274；DataService 129/149/190/235/246/471/492/598/602/625/630/640/681/687/750/760/777/792/802/816/823/835/848/858/872/1034/1069/1118 | 日志与显示设置 |
| `CacheModeManager.shared.{isCacheEnabled,recordHit,recordMiss,recordSavedTraffic,mode}` + `CacheModeMirror.isCacheEnabledFromAnyThread` | DataService 118/188/223/237/490/749/754/759/762/774/782/843/847/857/865/871；Referer 76/224 | 日志与显示设置 |
| `OrganizationManager.shared.updateSiteKeys(from:)` | DataService 455 | 机构模块 |
| `SJZImagePrefetcher.prefetch(urls:maxConcurrent:)`（TabBar.swift 12685/12689） | DataService 239 | 应用外壳/TabBar |
| `SJZNetworkMonitor.tap*` 系列 | Referer 85/88/99/101/108/117/120/131 | 日志与显示设置（网络监测） |
| `SchoolInfo.website` / `.name` / `.englishName` | NetworkService 365；DataService 431/979/984 | 本文件（Models.swift） |
| `URLProtocol.registerClass`（App 启动） | DesignCodeApp.swift:29 | 应用外壳 |

---

*草稿完 · 仅覆盖 NetworkService / DataService / Models / RefererHeaderURLProtocol 四个文件；未涉及的相邻模块（TabBar、LogManager、CacheModeManager、NotificationManager、OrganizationManager、BookmarkManager、SchoolProfileView 等）仅作依赖索引，不做分析结论。*
