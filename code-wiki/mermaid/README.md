# Mermaid 时序图源码索引

> 本目录存放 [06-接口契约与调用链](../06-接口契约与调用链.md) §6.4「函数级调用链时序」的独立 Mermaid 源码文件，逐字提取自该分册，可直接粘贴到 [mermaid.live](https://mermaid.live) 或任意 Mermaid 渲染器。
>
> 基线：Git 提交 `215ea30`（2026-10-02）。行号为当前源码行号，源码改动后请以符号名检索（[07-附录-类型与符号索引](../07-附录-类型与符号索引.md)）为准。

## 文件清单

| 文件 | 链路 | 内容概要 |
|---|---|---|
| [chain-A-coldstart-sync.mmd](chain-A-coldstart-sync.mmd) | A 冷启动 → 数据同步 | 三层降级（远程 → 缓存 → 兜底）、串行 home2/head/foot、`safeFetchArticles` 5 栏目分页、图片预热 |
| [chain-B-notification-deeplink.mmd](chain-B-notification-deeplink.mmd) | B 通知点击 → 深链展示 | 完成回调立即回执、5 路分发优先级、≤3s 轮询等待前台/解锁、350ms 让出 runloop 周期 |
| [chain-C-org-detail-load.mmd](chain-C-org-detail-load.mmd) | C 机构详情加载与降级 | 重试循环 5xx 短路、九形态分派注记、`fetchArticleDetailWithFallback` 先早退再取最长 |
| [chain-D-bookmark-update.mmd](chain-D-bookmark-update.mmd) | D 收藏更新检测（第 6 条通道） | 1h Timer、12/10 条取样、`isMeaningfulUpdate`、`ingest(.bookmarkUpdate)` 入盒 |
| [chain-E-image-loading.mmd](chain-E-image-loading.mmd) | E 图片加载 | init 同步查缓存首帧直出、并发闸 ≤4、协议层 Referer/缓存头注入、降采样解码 |
| [chain-F-org-deeplink-sheet.mmd](chain-F-org-deeplink-sheet.mmd) | F 机构动态深链 → 单状态 sheet | 冷启动白屏修复：`messageCenterGone()` 退场判据、550ms 错峰、`sheet(item:)` 快照必非 nil |
| [chain-G-org-column-nine-forms.mmd](chain-G-org-column-nine-forms.mmd) | G 机构栏目九形态壳加载 | `selectColumn` 九路分派：list/content、teacher、video、recruit、calendar/opinion、link、webFallback |
| [chain-H-webview-tabs.mmd](chain-H-webview-tabs.mmd) | H 外链 WebView 标签页导航 | 跨站自动开新页签（`referenceHost`）、`window.open` 委托、同站导航留历史、外部切链重置会话 |
| [chain-I-total-pagination.mmd](chain-I-total-pagination.mmd) | I total 驱动全量翻页 | 招生网/机构检索按服务端 total 翻页到取满、100/200 页安全上限、fallback 语义 |

## 渲染方式

```bash
# 单个文件（以链路 A 为例）
open chain-A-coldstart-sync.mmd          # 或用任意 Mermaid 工具打开
```

或将文件内容粘贴到 [mermaid.live](https://mermaid.live)（语言选 `sequenceDiagram`）。

## 维护约定

1. 本目录与 [06-接口契约与调用链](../06-接口契约与调用链.md) §6.4 保持同步：修改链路图时，两处必须一并更新。
2. 新增链路按 `chain-<字母>-<短名>.mmd` 命名，字母随 §6.4 章节顺序续排（当前 A–I）。
3. 行号标注与 07 索引一致，使用 `符号名:行号` 形式，禁止裸行号。
