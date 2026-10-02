#!/usr/bin/env bash
# ==============================================================================
# 机构模块 · 阶段四 视觉打磨 · 真机验收用例脚本（2026-10-01 建立）
#
# 用途：一条命令完成「构建安装 → 启动 → 引导逐屏核对 → 拉日志 → 断言 → 报告」，
#       覆盖 v2.2 §1/§3.5/§4 视觉落地项（令牌/列表节奏/形态壳/动效/深浅模式）。
#
# 用例：
#   V1 题头档案纸感  1px line + 铜金 2pt 饰线 + 「更新到 HH:mm」呼吸角标
#   V2 列表节奏      逢 4 行 16:9 大图卡，其余文字卡左列铜金 MM.DD 日期徽章
#   V3 形态壳统一    九形态卡 = surface + 1px line + 18 圆角（无玻璃、无阴影）
#   V4 栏目切换动效  chips 旧淡出/新淡入 + 列表 y 6pt 上移涌入（0.25s spring）
#   V5 深浅双模式    切换 系统外观→深色：铜金保持亮度、无死黑、玻璃描边正常
#   V6 触觉分级      下拉刷新 soft→success；翻到底 rigid；切栏目 selection
#   D0 会话无 ERROR  organization 域 ERROR/FATAL = 0（自动）
#   S8 视觉静态契约  形态卡 surface+1px line（源码断言）
#
# 用法：
#   Scripts/org_visual_acceptance.sh                # 全流程（默认观察窗 300s）
#   Scripts/org_visual_acceptance.sh --guided       # 逐步回车核对
#   Scripts/org_visual_acceptance.sh --skip-install # 不构建安装
#   Scripts/org_visual_acceptance.sh --report-only  # 考古
#   Scripts/org_visual_acceptance.sh --dark-switch  # 引导中加入深色切换步骤
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/qin/DesignCode.xcodeproj"
SCHEME="DesignCode"
CONFIG="Debug"
DEVICE_ID="00008110-000411A40EC1401E"
BUNDLE_ID="${BUNDLE_ID:-com.qinchao}"
DERIVED="$ROOT/qin/build/device-dd"
APP_PATH="$DERIVED/Build/Products/$CONFIG-iphoneos/DesignCode.app"
STAMP="$(date +%Y%m%d_%H%M%S)"
VERIFY_DIR="$ROOT/qin/build/verify"
PULL_DIR="$VERIFY_DIR/org-visual-logs-$STAMP"
REPORT="$VERIFY_DIR/org_visual_acceptance_$STAMP.md"

WAIT_SEC=300
DO_INSTALL=1
DO_LAUNCH=1
DO_GUIDED=0
DO_DARK=0
LIST_ONLY=0
ONLY=""
SESSION_START="$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE_ID="$2"; shift 2 ;;
    --wait)         WAIT_SEC="$2"; shift 2 ;;
    --dark-switch)  DO_DARK=1; shift ;;
    --only)         ONLY="$2"; shift 2 ;;
    --skip-install) DO_INSTALL=0; shift ;;
    --no-launch|--report-only) DO_LAUNCH=0; DO_INSTALL=0; shift ;;
    --guided)       DO_GUIDED=1; shift ;;
    --list)         LIST_ONLY=1; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

ok()   { echo "✅ $*"; }
info() { echo "[验收] $*"; }
fail() { echo "❌ $*"; }

CASES=$(cat <<'CASES'
V1|题头档案纸感（饰线+同步角标）|hard|进入教务处详情→题头观察 1px line + 铜金 2pt 饰线 + 更新到 HH:mm 角标|人工目视
V2|列表节奏（大图卡↔日期徽章文字卡）|hard|通知公告栏目滚动→逢 4 行大图卡；文字卡左列铜金 MM.DD|人工目视
V3|形态壳统一外观|hard|进入 content/师资/联系我们等栏目→卡=surface+1px 描边 18 圆角、非玻璃|人工目视
V4|栏目切换动效|hard|连续切换栏目→旧 chip 淡出/新淡入 + 内容 6pt 上移涌入|人工目视
V5|深浅双模式|hard|系统设置切深色外观→逐屏核对（铜金亮度/无死黑/描边）|人工目视
V6|触觉分级|soft|下拉刷新、翻到底、切栏目→对应触觉|人工手测
D0|会话无 ERROR|hard|自动|organization 域 ERROR/FATAL=0
S8|形态壳 surface+1px 静态契约|hard|自动（源码）|OrgTheme.surface + separator 描边
CASES
)

case_enabled() {
  [[ -z "$ONLY" ]] && return 0
  local id="$1" want
  IFS=',' read -r -a __want <<< "$ONLY"
  for want in "${__want[@]}"; do
    [[ "$(echo "$want" | tr -d ' ' | tr '[:lower:]' '[:upper:]')" == "$id" ]] && return 0
  done
  return 1
}

if [[ "$LIST_ONLY" == "1" ]]; then
  echo "$CASES" | while IFS='|' read -r id name kind guide expect; do
    printf "  %-4s %-30s [%s]\n" "$id" "$name" "$kind"
  done
  exit 0
fi

# ------------------------------------------------------------------ 1) 设备预检
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
  fail "未找到设备 ${DEVICE_ID}（请连接 iPhone 并解锁）。"; exit 1
fi
DEV_LINE="$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | head -1)"
echo "$DEV_LINE" | grep -qE "connected|available" || { fail "设备未就绪。"; exit 1; }
ok "设备在线。"

# ------------------------------------------------------------------ 2) 构建 + 安装
if [[ "$DO_INSTALL" == "1" ]]; then
  info "真机构建（含护栏）……"
  BUILD_LOG="$VERIFY_DIR/org_visual_build_$STAMP.log"
  mkdir -p "$VERIFY_DIR"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates build > "$BUILD_LOG" 2>&1; then
    fail "构建失败。日志：$BUILD_LOG"; exit 1
  fi
  grep -q "显示设置覆盖护栏通过" "$BUILD_LOG" && ok "构建通过（护栏四规则 0 缺口）" || warn "未捕获护栏通过标记"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null || { fail "安装失败"; exit 1; }
  ok "安装完成。"
fi

# ------------------------------------------------------------------ 3) 启动 + 引导
if [[ "$DO_LAUNCH" == "1" ]]; then
  SESSION_START="$(date +%s)"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" >/dev/null || {
    fail "启动失败（App 未安装？去掉 --skip-install 重跑）。"; exit 1; }
  echo
  echo "════════════ 操作引导（V1~V6，本次启用）════════════"
  echo "  1) 校园 → 查看全部机构 → 教务处 → 详情"
  echo "     · 题头：1px 细线 + 铜金 2pt 饰线 + 「更新到 HH:mm」呼吸角标（V1）"
  echo "  2) 栏目「通知公告」→ 向下滚动"
  echo "     · 逢 4 行一张 16:9 大图卡，其余文字卡左列铜金 MM/DD 日期徽章（V2）"
  echo "  3) 切到「部门概况」「联系我们」等栏目"
  echo "     · 形态卡为 surface 面 + 1px 描边 + 18 圆角（无玻璃感）（V3）"
  echo "  4) 连续快速切换栏目"
  echo "     · chips 旧淡出/新淡入 + 列表内容 6pt 上移涌入（V4）"
  echo "  5) 下拉刷新 → 正常弹回；滚动到通知公告底（触底 rigid）；切栏目（selection）（V6）"
  if [[ "$DO_DARK" == "1" ]]; then
    echo "  6) 系统设置 → 显示与亮度 → 深色 → 返回机构模块逐屏核对"
    echo "     · 铜金保持亮度、无死黑阴影、卡片描边正常（V5）"
  fi
  echo
  if [[ "$DO_GUIDED" == "1" ]]; then
    echo "  ── 逐步模式（完成后回车继续；q 进入判定）──"
    echo "$CASES" | while IFS='|' read -r id name kind guide expect; do
      case_enabled "$id" || continue
      printf "  ▶ ${id} ${name}：${guide}\n    完成后按回车（q 跳过）："
      read -r _ans || true
      [[ "$_ans" == "q" ]] && break
    done
  else
    echo "  ── 观察窗 ${WAIT_SEC}s：按上述路径操作（保持 App 前台）──"
    for ((i = WAIT_SEC; i > 0; i--)); do printf "\r  剩余 %3ds …" "$i"; sleep 1; done
    printf "\r  观察窗结束。      \n"
  fi
else
  warn "考古模式（--report-only）。"
fi

# ------------------------------------------------------------------ 4) 拉日志 + 5) 断言 + 报告
mkdir -p "$PULL_DIR"
if ! xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/SXJZIT_Cache/Logs" --destination "$PULL_DIR" > /dev/null 2>&1; then
  fail "日志拉取失败。"; exit 1
fi

python3 - "$PULL_DIR" "$REPORT" "$SESSION_START" "$DEVICE_ID" "$DO_LAUNCH" "$ONLY" "$ROOT" "$DO_DARK" <<'PY'
# -*- coding: utf-8 -*-
"""机构模块·阶段四视觉 · 真机验收：0 ERROR + 静态契约 + 人工清单报告"""
import datetime, glob, json, os, sys
(logdir, report_path, since, device_id, launched_raw, only_raw, root, dark_raw) = sys.argv[1:9]
since = float(since)
launched = launched_raw == "1"
dark = dark_raw == "1"
REF = 978307200
ONLY = {x.strip().upper() for x in only_raw.split(",") if x.strip()} if only_raw else set()

def enabled(cid): return (not ONLY) or (cid in ONLY)

def parse_ts(v):
    if isinstance(v, (int, float)): return REF + float(v)
    if isinstance(v, str):
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S.%f"):
            try: return datetime.datetime.strptime(v, fmt).timestamp()
            except ValueError: pass
    return 0.0

def fmt(ts): return datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S") if ts else "-"

entries = []
for f in sorted(glob.glob(os.path.join(logdir, "**", "log_*.json"), recursive=True)):
    try:
        d = json.load(open(f, encoding="utf-8"))
        if isinstance(d, list): entries.extend(d)
    except Exception: pass
for e in entries: e["_ts"] = parse_ts(e.get("timestamp"))
entries.sort(key=lambda e: e["_ts"])
session = [e for e in entries if e["_ts"] >= since] if launched else entries
if launched and not session: session = entries

checks = []
def add(hard, cid, name, passed, detail): checks.append((hard, cid, name, passed, detail))
def skip(cid, name, reason="未在选择范围"): checks.append((False, cid, name, None, reason))

# S8 静态契约：形态壳 surface + 1px separator 描边（org 视觉核心）
src = open(os.path.join(root, "qin", "DesignCode", "OrganizationDetailView.swift"), encoding="utf-8").read()
s8 = (src.count("OrgTheme.surface, in: RoundedRectangle(cornerRadius: OrgTheme.Radius.shell)") >= 4
      and ".stroke(OrgTheme.separator, lineWidth: 1)" in src
      and "OrgTheme.surface, in: RoundedRectangle(cornerRadius: OrgTheme.Radius.shell)" in src)
add(True, "S8", "形态壳 surface+1px 描边（源码）", s8,
    "content/teacher/recruit/入口卡 ≥4 处统一 shell 18 + separator 描边" if s8 else "形态壳描边不完整")
# 令牌契约：Motion / Shadow / symbol 探测存在（OrgTheme.swift 内）
theme_src = open(os.path.join(root, "qin", "DesignCode", "OrgTheme.swift"), encoding="utf-8").read()
s8b = ("enum Motion" in theme_src
       and "static func symbol(_ preferred: String, fallback: String) -> String" in theme_src
       and "static func kindSymbol(" in theme_src
       and "floatShadowColor" in theme_src)
add(True, "S8b", "令牌/图标单点（Motion+symbol 探测）", s8b,
    "Motion 令牌 + symbol() 兜底 + 阴影组已落地" if s8b else "令牌不完整（OrgTheme 缺 Motion/symbol/Shadow）")

# D0 会话无 ERROR
if enabled("D0"):
    errors = [e for e in session if e.get("module") == "organization"
              and str(e.get("level")) in ("ERROR", "FATAL")]
    add(True, "D0", "organization 域 0 ERROR", not errors,
        "0 条" if not errors else "%d 条：%s" % (len(errors), errors[0].get("message", "-")))
else:
    skip("D0", "会话 0 ERROR")

# 报告
hard_failed = sum(1 for h, _, _, p, _ in checks if h and p is False)
soft_gap = sum(1 for h, _, _, p, _ in checks if not h and p is False)
skipped = sum(1 for _, _, _, p, _ in checks if p is None)

lines = []
lines.append("# 机构模块 · 阶段四 视觉打磨 · 真机验收报告")
lines.append("")
lines.append("- 设备：`%s` ｜ 报告：%s" % (device_id, datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
lines.append("- 模式：%s%s" % ("启动取证" if launched else "考古", " + 深色核对" if dark else ""))
lines.append("- 会话窗口：%d 条" % len(session))
lines.append("")
lines.append("## 自动判定")
lines.append("")
lines.append("| 用例 | 类型 | 项 | 结果 | 详情 |")
lines.append("|---|---|---|---|---|")
for hard, cid, name, passed, detail in checks:
    kind = "静态契约" if cid.startswith("S") else ("硬性" if hard else "信息")
    mark = "✅ 通过" if passed else ("⬜ 未触发" if passed is None else "❌ 未通过")
    lines.append("| %s | %s | %s | %s | %s |" % (cid, kind, name, mark, detail))

lines.append("")
lines.append("## 人工确认清单（请在真机上逐项核对，勾选后签名）")
lines.append("")
lines.append("| 项 | 期望 | 浅色 | 深色 |")
lines.append("|---|---|---|---|")
lines.append("| V1 题头 | 1px line + 铜金 2pt 饰线 + 「更新到 HH:mm」呼吸角标 | ☐ | ☐ |")
lines.append("| V2 列表节奏 | 逢 4 行 16:9 大图卡；文字卡左列铜金 MM/DD 竖排徽章 | ☐ | ☐ |")
lines.append("| V3 形态壳 | surface 面 + 1px 描边 + 18 圆角（无玻璃/无阴影） | ☐ | ☐ |")
lines.append("| V4 切换动效 | chips 旧淡出新淡入 + 内容 6pt 上移涌入（0.25s spring） | ☐ | ☐ |")
lines.append("| V6 触觉 | 刷新 soft→success / 翻底 rigid / 切栏目 selection | ☐ | — |")
lines.append("| V5 深色专修 | 铜金保持亮度、阴影非死黑、玻璃描边可见 | — | ☐ |")
lines.append("")
lines.append("## 关键时间线（organization 域，最近 20 条）")
lines.append("")
hot = [e for e in session if e.get("module") == "organization"]
for e in hot[-20:]:
    c = e.get("context") or {}
    brief = " ".join("%s=%s" % (k, v) for k, v in list(c.items())[:4])
    lines.append("- `%s` [%s] %s  %s" % (fmt(e["_ts"]), e.get("level"), e.get("message"), brief))

open(report_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")

print("")
print("════════════════ 自动判定 ════════════════")
for hard, cid, name, passed, detail in checks:
    mark = "✅" if passed else ("⬜" if passed is None else "❌")
    print("%s %-5s %s —— %s" % (mark, cid, name, detail))
print("")
print("报告：%s" % report_path)
if hard_failed:
    print("结论：❌ 自动硬性用例未通过（%d），请修复。%s" % (hard_failed, "（V 系列以人工清单为准）"))
    sys.exit(1)
print("结论：✅ 自动判定全绿；V 系列视觉项请在真机按人工清单逐项核对、深浅各一遍。")
PY

echo
echo "报告：$REPORT"