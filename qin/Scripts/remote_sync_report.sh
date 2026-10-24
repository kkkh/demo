#!/usr/bin/env bash
#
# 园枢 · 三远端推送验证报告生成器（可复跑）
#
# 用法：
#   bash qin/Scripts/remote_sync_report.sh              # 只读采集 + push_all.sh --dry-run（不推送）
#   bash qin/Scripts/remote_sync_report.sh --push       # 额外执行一次实际推送并纳入证据（幂等）
#   bash qin/Scripts/remote_sync_report.sh --out <file> # 自定义输出路径
#   bash qin/Scripts/remote_sync_report.sh --help
#
# 输出（默认）：qin/docs/remote-sync/remote_sync_verification_<YYYYMMDD>.md（同日重跑覆盖）
# 判定：三远端 refs/heads/main == 本地 HEAD 且 dry-run 预检全通过 → PASS；任一不符 → FAIL
# 退出码：0=PASS ｜ 1=FAIL ｜ 2=用法或环境错误
#
# 说明：报告为「生成时快照」；随后若有新提交/推送，远端哈希会领先于报告页记录，属预期。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || { echo "✗ 无法进入仓库根目录" >&2; exit 2; }

REMOTES=(origin gitee cnb)
DO_PUSH=0
OUT=""
DATE_TAG="$(date +%Y%m%d)"
DEFAULT_OUT="qin/docs/remote-sync/remote_sync_verification_${DATE_TAG}.md"

usage() {
  awk 'NR>=3 && /^#/ {print} NR>=3 && !/^#/ {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --push) DO_PUSH=1 ;;
    --out)  shift; OUT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "✗ 未知参数：$1（--help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ 当前目录不是 Git 仓库" >&2; exit 2; }
[ -n "${OUT}" ] || OUT="${DEFAULT_OUT}"

# ── 采集 ──────────────────────────────────────────────────────────────
NOW="$(date '+%F %T %Z')"
GIT_VERSION="$(git --version)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
HEAD_FULL="$(git rev-parse HEAD)"
HEAD_SHORT="$(git rev-parse --short HEAD)"
STATUS_HEAD="$(git status -sb 2>/dev/null | head -1)"
LAST_COMMIT="$(git log -1 --format='%h %ad %s' --date=format:'%F %T')"
REMOTE_TABLE="$(git remote -v | awk '{printf "| `%s` | `%s` |\n", $1, $2}' | sort -u)"
CRED_HELPER="$(git config --system --get credential.helper 2>/dev/null || true)"
[ -n "${CRED_HELPER}" ] || CRED_HELPER="$(git config --get credential.helper 2>/dev/null || true)"
[ -n "${CRED_HELPER}" ] || CRED_HELPER="（未配置）"
if [ -f "${HOME}/.ssh/id_ed25519_gitee" ]; then SSH_KEY="存在（~/.ssh/id_ed25519_gitee）"; else SSH_KEY="缺失"; fi
TAGS_COUNT="$(git tag | wc -l | tr -d ' ')"

LSR_BLOCK=""
VERDICT_OK=1
for R in "${REMOTES[@]}"; do
  if git ls-remote "${R}" >/dev/null 2>&1; then
    RAW="$(git ls-remote "${R}" 2>/dev/null | head -6)"
    MAIN_SHA="$(git ls-remote "${R}" refs/heads/main 2>/dev/null | awk '{print $1}')"
    [ "${MAIN_SHA}" = "${HEAD_FULL}" ] || VERDICT_OK=0
  else
    RAW="（ls-remote 失败：网络或认证不可达）"
    VERDICT_OK=0
  fi
  LSR_BLOCK="${LSR_BLOCK}--- ${R} ---
${RAW}

"
done

DRY_OUT="$(bash qin/Scripts/push_all.sh --dry-run 2>&1)"
DRY_EXIT=$?
[ "${DRY_EXIT}" -eq 0 ] || VERDICT_OK=0

PUSH_SECTION=""
if [ "${DO_PUSH}" -eq 1 ]; then
  PUSH_OUT="$(bash qin/Scripts/push_all.sh 2>&1)"
  PUSH_EXIT=$?
  [ "${PUSH_EXIT}" -eq 0 ] || VERDICT_OK=0
  PUSH_SECTION="### 3.4 \`push_all.sh\` 实际推送（--push 取证）

\`\`\`
${PUSH_OUT}
\`\`\`
"
fi

if [ "${VERDICT_OK}" -eq 1 ]; then VERDICT="PASS"; VERDICT_ICON="✅"; else VERDICT="FAIL"; VERDICT_ICON="❌"; fi

# ── 生成报告 ──────────────────────────────────────────────────────────
mkdir -p "$(dirname "${OUT}")"
cat > "${OUT}" <<EOF
# 三远端推送验证报告（origin / gitee / cnb）

- **生成时间**：${NOW}（脚本实时采集，非手写）
- **生成脚本**：\`qin/Scripts/remote_sync_report.sh\`（可复跑；同日重跑覆盖本文件）
- **仓库**：\`${REPO_ROOT}\` ｜ 分支 \`${BRANCH}\` ｜ HEAD \`${HEAD_SHORT}\`
- **判定**：${VERDICT_ICON} **${VERDICT}**（三远端 \`refs/heads/main\` 与本地 HEAD 一致，且 dry-run 预检通过）
- 说明：本报告为「生成时快照」；其后若有新提交/推送，远端哈希会领先于下表记录，属预期。

---

## 1. 结论

| # | 检查项 | 结果 |
|---|---|---|
| 1 | 三远端 \`refs/heads/main\` 与本地 HEAD 一致 | ${VERDICT_ICON} 本地 \`${HEAD_SHORT}\`（详见 §3.2） |
| 2 | 本地工作区行 | \`${STATUS_HEAD}\` |
| 3 | 凭据链路 | GitHub = Keychain（\`${CRED_HELPER}\`）｜ Gitee = SSH（${SSH_KEY}）｜ CNB = HTTPS 令牌（用户名 \`cnb\`，存 Keychain） |
| 4 | \`push_all.sh --dry-run\` | 退出码 ${DRY_EXIT} |
| 5 | tags | 本地 ${TAGS_COUNT} 个（脚本含 --tags 通道） |

## 2. 远端配置（git remote -v）

| remote | URL |
|---|---|
${REMOTE_TABLE}
## 3. 原始证据

### 3.1 本地状态

\`\`\`
${STATUS_HEAD}
HEAD: ${HEAD_FULL}
分支: ${BRANCH}
最近提交: ${LAST_COMMIT}
${GIT_VERSION}
\`\`\`

### 3.2 各远端 ls-remote

\`\`\`
${LSR_BLOCK}\`\`\`

> 注：\`refs/pull/*\` 等附加 ref 为平台 PR 产物，不参与 main 一致性判定。

### 3.3 \`push_all.sh --dry-run\`（预检，不推送）

\`\`\`
${DRY_OUT}
\`\`\`

${PUSH_SECTION}---

## 4. 复现命令

\`\`\`bash
bash qin/Scripts/remote_sync_report.sh            # 重新生成（同日覆盖）
bash qin/Scripts/remote_sync_report.sh --push     # 附带实际推送取证
bash qin/Scripts/push_all.sh --dry-run            # 仅验证链路与凭据
\`\`\`
EOF

echo "════════ 三远端验证报告 ════════"
echo "判定：${VERDICT_ICON} ${VERDICT} ｜ 本地 HEAD ${HEAD_SHORT} ｜ dry-run 退出码 ${DRY_EXIT}$([ "${DO_PUSH}" -eq 1 ] && echo " ｜ 实推退出码 ${PUSH_EXIT}")"
echo "报告：${OUT}"
if [ "${VERDICT_OK}" -eq 1 ]; then exit 0; else exit 1; fi