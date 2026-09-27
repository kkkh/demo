# 网络监测模块改造工程规格书 v7（终版）（我的 → 应用设置 → 网络调试 → 网络监测）

## 1. Context

根因（代码级已定位）：① 埋点仅 [RefererHeaderURLProtocol L81-108](file:///Users/qinchao/Downloads/designcode-swiftui/qin/DesignCode/RefererHeaderURLProtocol.swift#L81-L108) 纯被动、仅 sxjzit 域 URLSession，冷启动空窗；② WKWebView/AVPlayer 系统组件盲区（诚实标注不伪造）；③ 1s 桶稀释速率、无归因/峰值/历史；④ 图表无查值、诊断无历史、断线无记录、目标硬编码；⑤ iOS26 `NWPath.LinkQuality`（good/moderate/minimal/unknown）/`isUltraConstrained`/IPv4/IPv6/DNS 未接入；⑥ 入口行永续快照。

依据：iOS 26 官方文档；Apple DTS Quinn 指导（性能估计靠实际请求表现；linkQuality 仅调参）。v7 经两轮独立评审（fresh eyes）+ 功能完整性缺口审计（§2.2 八项）+ 工程正确性终审（§3 裁决），全部修正并入。

**文件组织（维持）**：不新增 Swift 文件（工程「同文件避免 pbxproj 注册」惯例 + pbxproj 手动维护风险 + git 已失效）。

范围（5 文件）：SJZNetworkMonitor.swift（+950）/ NetworkMonitorView.swift（重写 2200）/ TabBar.swift L8917-9459（入口行 +30）/ **RefererHeaderURLProtocol.swift（仅 startLoading +12 行上行触点，绝不动缓存/防盗链逻辑）**/ MessageCenterStoreTests.swift 文末追加离线测试（+170）。
红线：iOS26 API `if #available`；日志域 `netmon`；红线 #16 统一编译验证；改前 5 文件手工备份至 `DesignCode_backup_20260926_netmon/`。

## 2. 功能总清单

### 2.1 保留（v5）+ 完整性审计新增（v6 §2.2 八项）
iOS26 链路指标 · 心跳实时采样 · EMA 瞬时吞吐 · 并发 · 峰值 · 慢主机 TOP3 · 流量域分布 · 链路时间线 · 双目标诊断 · 诊断历史（内存3+持久1）· 健康分 · 复制报告/导出快照 · 网络身份卡 · 协议版本 · 趋势指示器 · 覆盖度仪表 · 异常预警横幅 · 优化建议生成器 · 缓存模式联动卡 · 会话元信息 · **上行/下行双指标 · 一键测速 · 小时历史卡 · 今日累计流量 · 工具栏手动刷新 · 窗口偏好记忆 · 预警入时间线 · 信号强度诚实声明**。

### 2.2 v7 终审修正（并入 2.1 的实现口径）

| 功能 | 终审裁决后的最终实现口径 |
|---|---|
| 上行分流 | 只测 `httpBody`（内存 body）；持流式上行未计量，UI 如实标注「上行按请求体估算」；本项目纯 GET 拉取上行≈0，影响可忽略 |
| 一键测速 | **不挑图**：候选池 = `data.banners`（真实服务器数据）图片 → `data.news` 最大 imageUrl → 已缓存 sxjzit 域图；先 **HEAD 取 Content-Length 剔除小于 200KB** 的缩略图并排序；对胜出真实资源**循环下载至 8MB 或 10s**（干净会话 + 手工 Referer + **手工 UA** + host 必须含 sxjzit 域名校验；内存丢弃不落盘）；1s 滑动窗口峰值 = 结果（MB/s + 分级）；与心跳/诊断 `setSuspended(true)` 互斥；失败如实提示 |
| 心跳引擎 | **热连接语义**：复用单个干净会话（含 UA/Referer 无需——目标无防盗链，实测时按需）；间隔 = 页面可见 5s 起步，2min 无业务流量→10s、5min→30s 三档；**scenePhase 前台门控：退后台立即暂停**（防 iOS 挂起误判离线）；冷连接语义专属于诊断 5 轮独立会话 |
| 持久化策略 | 时间线：内存持有 + **变化或退后台才 flush**（非 2s 批写）；今日流量：1s 内存累计 + 10s 批写 + 退后台 flush；**日历键翻转后清理过期 key（仅保留最近 3 天）**；窗口偏好 @AppStorage 即时 |
| 图表 | 自动跟随仅在无手势时生效；用户 selection/拖拽即挂起跟随与每秒动画；reduceMotion 下停用 withAnimation（改瞬时更新）；固定 chartXScale domain；双卡共享选择时间戳 |

## 3. 数据模型/状态机/算法（v4-v6 全部保留，改动以 §2.2 裁决为准）

心跳状态机最终版：`暂定（scenePhase 非前台）→ live 5s（可见且无流量 2min 内）→ saving 10s（≥2min 无流量）→ deepSaving 30s（≥5min）`；任一业务桶>0 或诊断/测速开始 → 暂停/回 live；开关与 endLiveSampling 即停。健康分 `cq35+p90m30+loss20+tp15`；EMA α=0.35；趋势最小二乘 |slope|<0.5 平稳；测速分级 ≥4/≥1.5/≥0.5 MB/s；分钟摘要 60 槽环形；时间线 30 条含 outage/recovery/anomaly 三 kind。

## 4. 逐卡视觉与动效规格（v5 §4 全保留 + v6 增量，v7 修正项）

- 测速卡：按钮雷电 capsule；进度环渐变（accent→teal）+ 「正在测量（已下载 x MB）」副文案；完成数字滚动 + 分级 badge 弹入 + 结果常驻「最近测速」徽章；失败红字如实原因。
- 双曲线卡：下行 LineMark accent + 上行 LineMark teal 虚线 + 图例双色点 + 浮签双值 + 「上行按请求体估算」脚注。
- ReduceMotion：全局关扫动/呼吸/脉冲仅 0.25s 淡入（保留 v5 §4 全规格）。

## 5. 日志事件规格（29 类，v4-v6 全保留；终审补充）

- 新增强制项：测速 HEAD 探测与资源选择（debug，候选数与最终 URL 大小）、心跳后台暂停/恢复（info，scenePhase 触发）、时间线 flush（debug，条数与触发源）、过期日键清理（info）。
- 全部遵循既有节流：30s/50 条/2s/10s/状态沿。

## 6. 修改边界（v6 §6 全保留；RefererHeaderURLProtocol 增量 = `tapUpload(token:bytes:)` 单点 +12 行）

## 7. 验证矩阵（v6 §7 的 20 项全保留，v7 增补）

- ⑳+ 测速资源选择正确性（日志可见 HEAD 挑选过程、结果分级合理、缓存图片不干扰——干净会话验证）· 退后台心跳暂停（日志见暂停/恢复事件、无「离线」误判）· 今日流量重启 App 数值保持且第 4 天旧键被清理 · 上行曲线随带 body 请求正确计入。
- 编译 xcodebuild（真机 id=00008110-000411A40EC1401E）；测试 54+新增离线用例全绿；日志核验 29+ 类齐全节流生效；回滚 = 5 文件备份还原。

## 8. 完美验收清单（DoD——逐项勾选，未达即修，修完复验）

1. 冷启动进页 5s 内曲线有数据（心跳可见性门控生效）。
2. 浏览文章/图片 → 下行曲线抬升、上行可见但≈0 并如实标注。
3. 测速：HEAD 挑选日志完整、进度环平滑、结果分级稳定可复现、缓存不干扰。
4. 诊断：双目标 5 轮动画、健康分、一致性提示、建议列表、复制报告、历史对比与跨启动漂移齐全。
5. 飞行模式：红卡、曲线归零、时间线 outage 条目、恢复 recovery 条目、重启后时间线仍在、联动卡出现。
6. 后台切换：心跳暂停/恢复日志完整、无离线误判。
7. iOS26 与低版本降级文案、深色模式、reduceMotion、VoiceOver 逐项通过。
8. 节能三档徽章随 2min/5min 边界切换。
9. 入口行 5s 刷新四要素（接口/状态/健康分/linkQuality/吞吐）。
10. 图表：查值/平移/窗口/回到实时全链路无抖、无手势冲突。
11. netmon 域 29+ 类事件齐全、节流生效、零刷屏、零 print 残留。
12. xcodebuild 通过、54+离线用例全绿、StyleCheck 自检（新代码无 @AppStorage+didSet、无强制解包、无未用变量警告）。

## 9. 实施顺序

备份（5 文件）→ 中枢扩建 → URLProtocol 上行触点 → View 重写 → 入口行 → 测试追加 → 统一编译 → DoD 12 项逐条核验 → 复验修复 → 记忆归档。