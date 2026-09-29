# 三远端推送验证报告（origin / gitee / cnb）

- **生成时间**：2026-09-29 11:24:39 CST（脚本实时采集，非手写）
- **生成脚本**：`qin/Scripts/remote_sync_report.sh`（可复跑；同日重跑覆盖本文件）
- **仓库**：`/Users/qinchao/Downloads/designcode-swiftui` ｜ 分支 `main` ｜ HEAD `9424d31`
- **判定**：✅ **PASS**（三远端 `refs/heads/main` 与本地 HEAD 一致，且 dry-run 预检通过）
- 说明：本报告为「生成时快照」；其后若有新提交/推送，远端哈希会领先于下表记录，属预期。

---

## 1. 结论

| # | 检查项 | 结果 |
|---|---|---|
| 1 | 三远端 `refs/heads/main` 与本地 HEAD 一致 | ✅ 本地 `9424d31`（详见 §3.2） |
| 2 | 本地工作区行 | `## main...origin/main` |
| 3 | 凭据链路 | GitHub = Keychain（`osxkeychain`）｜ Gitee = SSH（存在（~/.ssh/id_ed25519_gitee））｜ CNB = HTTPS 令牌（用户名 `cnb`，存 Keychain） |
| 4 | `push_all.sh --dry-run` | 退出码 0 |
| 5 | tags | 本地 0 个（脚本含 --tags 通道） |

## 2. 远端配置（git remote -v）

| remote | URL |
|---|---|
| `cnb` | `https://cnb.cool/43322/Garden-iOS.git` |
| `gitee` | `git@gitee.com:oai/garden-ios.git` |
| `origin` | `https://github.com/kkkh/Garden-iOS.git` |

## 3. 原始证据

### 3.1 本地状态

```
## main...origin/main
HEAD: 9424d31a47676259663f52b8166e4f0c6b13b611
分支: main
最近提交: 9424d31 2026-09-29 11:23:41 docs(tools): 三远端验证报告入库 qin/docs/remote-sync/ + 可复跑生成器
git version 2.55.0
```

### 3.2 各远端 ls-remote

```
--- origin ---
9424d31a47676259663f52b8166e4f0c6b13b611	HEAD
9424d31a47676259663f52b8166e4f0c6b13b611	refs/heads/main

--- gitee ---
9424d31a47676259663f52b8166e4f0c6b13b611	HEAD
9424d31a47676259663f52b8166e4f0c6b13b611	refs/heads/main
3d3159adc07f994ee4ed80320d0da73ae5663389	refs/pull/1/MERGE
9834413459766c85d03d167b426f971889976142	refs/pull/1/head

--- cnb ---
9424d31a47676259663f52b8166e4f0c6b13b611	HEAD
9424d31a47676259663f52b8166e4f0c6b13b611	refs/heads/main

```

> 注：`refs/pull/*` 等附加 ref 为平台 PR 产物，不参与 main 一致性判定。

### 3.3 `push_all.sh --dry-run`（预检，不推送）

```
════════ 三远端一键推送 ════════
分支：main ｜ tags：推送 ｜ 模式：演练
本地 HEAD：9424d31  docs(tools): 三远端验证报告入库 qin/docs/remote-sync/ + 可复跑生成器

· [origin] 演练通过 → 将执行：git push origin HEAD:refs/heads/main 然后 git push origin --tags
· [gitee] 演练通过 → 将执行：git push gitee HEAD:refs/heads/main 然后 git push gitee --tags
· [cnb] 演练通过 → 将执行：git push cnb HEAD:refs/heads/main 然后 git push cnb --tags

════════ 汇总 ════════
✓ 全部成功（origin gitee cnb）
```

### 3.4 `push_all.sh` 实际推送（--push 取证）

```
════════ 三远端一键推送 ════════
分支：main ｜ tags：推送 ｜ 模式：实际推送
本地 HEAD：9424d31  docs(tools): 三远端验证报告入库 qin/docs/remote-sync/ + 可复跑生成器

→ [origin] 推送 main …
Everything up-to-date
  ✓ [origin] 完成（远端 @ 9424d31a）
→ [gitee] 推送 main …
Everything up-to-date
  ✓ [gitee] 完成（远端 @ 9424d31a）
→ [cnb] 推送 main …
Everything up-to-date
  ✓ [cnb] 完成（远端 @ 9424d31a）

════════ 汇总 ════════
✓ 全部成功（origin gitee cnb）
远端一致性核验：origin=9424d31a gitee=9424d31a cnb=9424d31a 
```
---

## 4. 复现命令

```bash
bash qin/Scripts/remote_sync_report.sh            # 重新生成（同日覆盖）
bash qin/Scripts/remote_sync_report.sh --push     # 附带实际推送取证
bash qin/Scripts/push_all.sh --dry-run            # 仅验证链路与凭据
```
