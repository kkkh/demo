#!/usr/bin/env bash
#
# 园枢 · 三远端一键推送（origin=GitHub / gitee=Gitee / cnb=腾讯 CNB 云原生构建）
#
# 用法：
#   bash qin/Scripts/push_all.sh                  # 推送当前分支 + 全部 tags 到三远端
#   bash qin/Scripts/push_all.sh --dry-run        # 演练（含逐远端可达性/认证预检，不实际推送）
#   bash qin/Scripts/push_all.sh --only cnb       # 只推单个远端（部分失败后重试用）
#   bash qin/Scripts/push_all.sh --branch main --no-tags
#   bash qin/Scripts/push_all.sh --help
#
# 行为约定：
#   · 逐远端「预检 → 推送分支 → 推送 tags」，任一远端失败不中断其余远端；
#   · 结束时打印逐远端结果与远端 short-hash 一致性核验；
#   · 永不 force push；分支以 HEAD:refs/heads/<branch> 显式推送，防误推。
#
# 前提：origin / gitee / cnb 三个 remote 已配置（gitee 走 SSH；cnb 走 HTTPS +
#       个人访问令牌，用户名固定为 cnb，凭据存 macOS Keychain）。
#
# 退出码：0=全部成功 ｜ 1=存在失败（逐远端列出） ｜ 2=用法或环境错误

set -uo pipefail

REMOTES=(origin gitee cnb)
ALLOWED=" origin gitee cnb "

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
PUSH_TAGS=1
DRY=0
ONLY=""

usage() {
  # 打印文件头部的完整注释块（第 3 行起的连续 # 块）
  awk 'NR>=3 && /^#/ {print} NR>=3 && !/^#/ {exit}' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-tags) PUSH_TAGS=0 ;;
    --only)    shift; ONLY="${1:-}" ;;
    --branch)  shift; BRANCH="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "✗ 未知参数：$1（--help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ 当前目录不是 Git 仓库" >&2; exit 2; }
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { echo "✗ 无法确定分支（detached HEAD？可用 --branch 指定）" >&2; exit 2; }

TARGETS=()
if [ -n "$ONLY" ]; then
  case "$ALLOWED" in
    *" $ONLY "*) TARGETS=("$ONLY") ;;
    *) echo "✗ 未知远端：$ONLY（可选：origin / gitee / cnb）" >&2; exit 2 ;;
  esac
else
  TARGETS=("${REMOTES[@]}")
fi

echo "════════ 三远端一键推送 ════════"
echo "分支：$BRANCH ｜ tags：$([ "$PUSH_TAGS" -eq 1 ] && echo 推送 || echo 跳过) ｜ 模式：$([ "$DRY" -eq 1 ] && echo 演练 || echo 实际推送)"
echo "本地 HEAD：$(git rev-parse --short HEAD)  $(git log -1 --format=%s 2>/dev/null | cut -c1-64)"
echo ""

FAILED=()

for R in "${TARGETS[@]}"; do
  URL="$(git remote get-url "$R" 2>/dev/null || true)"
  if [ -z "$URL" ]; then
    echo "✗ [$R] remote 未配置（git remote add $R <url>）"
    FAILED+=("$R(未配置)")
    continue
  fi

  # 预检：可达性与认证（空仓同样返回 0；--dry-run 下也执行，用于只验证凭据链路）
  if ! git ls-remote "$R" >/dev/null 2>&1; then
    echo "✗ [$R] 预检失败（网络或认证）→ $URL"
    FAILED+=("$R(预检)")
    continue
  fi

  if [ "$DRY" -eq 1 ]; then
    echo "· [$R] 演练通过 → 将执行：git push $R HEAD:refs/heads/$BRANCH$([ "$PUSH_TAGS" -eq 1 ] && echo ' 然后 git push '"$R"' --tags')"
    continue
  fi

  echo "→ [$R] 推送 $BRANCH …"
  if git push "$R" "HEAD:refs/heads/$BRANCH"; then
    if [ "$PUSH_TAGS" -eq 1 ]; then
      if ! git push "$R" --tags >/dev/null 2>&1; then
        echo "  ⚠ [$R] 分支成功，但 tags 推送失败"
        FAILED+=("$R(tags)")
        continue
      fi
    fi
    SHA="$(git ls-remote "$R" "refs/heads/$BRANCH" | awk '{print substr($1,1,8)}')"
    echo "  ✓ [$R] 完成（远端 @ $SHA）"
  else
    echo "  ✗ [$R] 推送失败"
    FAILED+=("$R")
  fi
done

echo ""
echo "════════ 汇总 ════════"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "✓ 全部成功（${TARGETS[*]}）"
  if [ "$DRY" -eq 0 ]; then
    printf '远端一致性核验：'
    for R in "${TARGETS[@]}"; do
      printf '%s=%s ' "$R" "$(git ls-remote "$R" "refs/heads/$BRANCH" | awk '{print substr($1,1,8)}')"
    done
    echo ""
  fi
  exit 0
else
  echo "✗ 失败：${FAILED[*]}"
  echo "提示：gitee 需 SSH 密钥（~/.ssh/id_ed25519_gitee）；cnb 需 Keychain 令牌（用户名 cnb）。"
  echo "      令牌失效时重新写入（替换 <新令牌> 后执行）："
  echo "      printf \"protocol=https\\\\nhost=cnb.cool\\\\nusername=cnb\\\\npassword=<新令牌>\\\\n\\\\n\" | git credential-osxkeychain store"
  exit 1
fi