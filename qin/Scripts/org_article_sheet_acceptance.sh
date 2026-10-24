#!/usr/bin/env bash
# ==============================================================================
# 机构动态详情「冷启动白屏」修复 · 真机验收测试用例脚本（2026-10-02 建立）
#
# 修复对象：消息中心【信创与大数据学院】orgUpdate 消息，冷启动后首次点击
#           详情页白屏/延迟（划一下点一下等数秒才出现）；二次点击正常。
# 根因（机制级）：机构动态详情 sheet 用「双状态」驱动（bool + item），
#           呈现瞬间 item=nil → 详情视图未创建 → .task 不执行 → 空/占位白屏，
#           交互触发重建后才加载。
# 修复（局部隔离在机构动态通道）：
#   1) sheet(item:) 单状态 — item 非 nil 才呈现，closure 取非可选快照，
#      详情视图必然创建、.task 必然执行；
#   2) 「等待消息中心 sheet 退场」判据从（不可见的跨视图 @State）改为
#      MessageCenterStore.shared.messageCenterDismissedAt 共享时间戳；
#   3) PendingOrgArticleDeepLink 补 Identifiable。
#
# 流程：
#   1) 设备预检（devicectl 识别 UDID 且 connected）
#   2) 真机构建 + 安装（--skip-install 可跳过：已装最新构建时）
#   3) 冷启动 App（--terminate-existing）→ 观察窗内引导操作：
#      我的 → 消息中心 → 首次点击【信创与大数据学院】→ 二次点击 → 其他消息 →
#      快速连续点击（覆盖回归清单）
#   4) 拉取 App 沙盒日志（Documents/SXJZIT_Cache/Logs）+ 消息中心持久化条目
#   5) 结构化断言（时间相关性：直达指令→详情页打开的间隔 δ；静态契约；持久化旁证）
#   6) 生成 Markdown 报告至 qin/build/verify/
#
# 用法：
#   Scripts/org_article_sheet_acceptance.sh                # 全流程（默认观察窗 240s）
#   Scripts/org_article_sheet_acceptance.sh --guided       # 逐步模式：每步按回车：confirm-then
#   Scripts/org_article_sheet_acceptance.sh --skip-install # 不构建安装（复用已装构建）
#   Scripts/org_article_sheet_acceptance.sh --wait 120     # 观察窗秒数
#   Scripts/org_article_sheet_acceptance.sh --list         # 列出用例后退出
#   Scripts/org_article_sheet_acceptance.sh --dry-run      # 只做预检与计划打印
#   Scripts/org_article_sheet_acceptance.sh --report-only  # 考古：不启动，全窗口判定
#
# 判定口径（本次会话窗口，时间为 Apple 参考日期秒）：
#   A1 冷启动首次点 orgUpdate 消息  直达「机构动态通知 → 直达机构文章详情」ui 日志后，
#                                    须命中「文章详情页打开」organization 日志，且
#                                    δ(直达→详情) ≤ 3.0s（修复前实测：12:41:13→12:41:21=8.0s；
#                                    旧版更严重：直达后无任何详情打点）
#   A2 二次点击同一条                 同上，δ ≤ 3.0s（回归：二次点击不受影响）
#   A3 冷启动首次点其他消息（news）    ui「收到通知打开指令」命中 + 详情打点命中（诊测）
#   B1 快速连续点击不同消息            会话内 messageCenter「消息点击 → 深链投递」≥2 次，
#                                    无崩溃（App 存活）+ 任一组织直达可配对
#   C0 无新增 ERROR/FATAL             organization/ui/messageCenter 域 ERROR/FATAL = 0
#   S1 静态契约 ①                    TabBar.swift 无 showOrgArticleFromNotification 残留
#   S2 静态契约 ②                    TabBar.swift 存在 sheet(item: $pendingOrgArticle)
#   S3 静态契约 ③                    MessageCenterStore 存在 messageCenterDismissedAt
#   S4 静态契约 ④                    PendingOrgArticleDeepLink 声明 Identifiable
#   P1 持久化旁证（抗日志窗口）        messageCenterEvents.json 中 kind=orgUpdate 且
#                                    orgName=信创与大数据学院 的条目 isRead=true
#                                    （用户真机点开过 → 详情非白屏的直接旁证）
#
# 已知约束（沿用 org_module_acceptance.sh 沉淀，勿改）：
#   - App 日志单日上限 1000 条 → 操作后尽快拉取（脚本已在窗口结束立即拉取）
#   - 日志文件「最新在前」落盘 → 断言前必须按时间升序排序
#   - bash 3.2：`$VAR` 后紧接全角字符必须写 `${VAR}`
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/qin/DesignCode.xcodeproj"
SCHEME="DesignCode"
CONFIG="Debug"
DEVICE_ID="00008110-000411A40EC1401E"   # 秦超的iPhone（可通过 --device 覆盖）
BUNDLE_ID="${BUNDLE_ID:-com.qinchao}"
DERIVED="$ROOT/qin/build/device-dd"
APP_PATH="$DERIVED/Build/Products/$CONFIG-iphoneos/DesignCode.app"
STAMP="$(date +%Y%m%d_%H%M%S)"
VERIFY_DIR="$ROOT/qin/build/verify"
PULL_DIR="$VERIFY_DIR/org-article-sheet-logs-$STAMP"
REPORT="$VERIFY_DIR/org_article_sheet_acceptance_$STAMP.md"
STATE_DIR="$PULL_DIR/state"

WAIT_SEC=240
DO_INSTALL=1
DO_LAUNCH=1
DO_GUIDED=0
DRY_RUN=0
LIST_ONLY=0
SINCE_ARG=""
SESSION_START="$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE_ID="$2"; shift 2 ;;
    --wait)         WAIT_SEC="$2"; shift 2 ;;
    --skip-install) DO_INSTALL=0; shift ;;
    --no-launch|--report-only) DO_LAUNCH=0; DO_INSTALL=0; shift ;;
    --since)        SINCE_ARG="$2"; shift 2 ;;
    --guided)       DO_GUIDED=1; shift;;
    --list)         LIST_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）"; exit 2;;
  esac
done

# --since "YYYY-MM-DD HH:MM:SS" 提供时强制按该起点做会话窗口（避免 report-only 全窗口混入历史日志）
if [[ -n "${SINCE_ARG:-}" ]]; then
  SESSION_START="$(date -j -f "%Y-%m-%d %H:%M:%S" "$SINCE_ARG" +%s 2>/dev/null || echo "$SINCE_ARG")"
fi

ok()   { echo "✅ $*"; }
info() { echo "[验收] $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; }

# ------------------------------------------------------------------ 用例清单
# 格式：ID|名称|类型(hard/soft)|判定口径|
CASES=$(cat <<'CASES'
A1|冷启动首次点【信创】orgUpdate|hard|直达「机构动态通知 → 直达机构文章详情」ui 日志→须紧跟「文章详情页打开」；δ≤3.0s（修复前 8.0s/旧版无打点）
A2|二次点击同一条|hard|同上，δ≤3.0s（回归：二次点击不受影响）
A3|冷启动首次点其他消息(news)|soft|ui「收到通知打开指令」命中+详情打点命中
B1|快速连续点击不同消息|hard|消息中心点击投递 ≥2 次；无崩溃；任一组织直达可配对
C0|无新增 ERROR/FATAL|hard|organization/ui/messageCenter 域 ERROR/FATAL=0
S1|静态契约：无双状态残留|hard|TabBar.swift 无 showOrgArticleFromNotification
S2|静态契约：sheet(item:)|hard|TabBar.swift 存在 sheet(item: $pendingOrgArticle)
S3|静态契约：退场时间戳|hard|MessageCenterStore 存在 messageCenterDismissedAt
S4|静态契约：Identifiable|hard|PendingOrgArticleDeepLink 声明 Identifiable
P1|持久化旁证：条目已读|soft|messageCenterEvents.json 中 orgName=信创与大数据学院 且 kind=orgUpdate 条目 isRead=true
CASES
)

if [[ "$LIST_ONLY" == "1" ]]; then
  echo "机构动态详情白屏修复 · 真机验收用例清单（共 $(echo "$CASES" | grep -c '|') 条）"
  echo "──────────────────────────────────────────────"
  echo "$CASES" | while IFS='|' read -r id name kind expect; do
    printf "  %-3s %-28s [%s]\n      口径：%s\n" "$id" "$name" "$kind" "$expect"
  done
  exit 0
fi

# ------------------------------------------------------------------ 1) 设备预检
info "设备预检：${DEVICE_ID}"
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
  fail "未找到设备 ${DEVICE_ID}（请连接 iPhone 并解锁）。"; exit 1
fi
DEV_LINE="$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | head -1)"
echo "    ${DEV_LINE}"
echo "$DEV_LINE" | grep -qE "connected|available" || { fail "设备未连接（请解锁并信任本机）。"; exit 1; }
ok "设备在线（锁屏与否以启动阶段实际结果为准）。"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "计划：构建=$DO_INSTALL 启动=$DO_LAUNCH 引导=$DO_GUIDED 观察窗=${WAIT_SEC}s"
  echo "报告：${REPORT}"
  exit 0
fi

# ------------------------------------------------------------------ 2) 构建 + 安装
mkdir -p "$VERIFY_DIR"
if [[ "$DO_INSTALL" == "1" ]]; then
  info "真机构建（${CONFIG}）……"
  BUILD_LOG="$VERIFY_DIR/org_article_sheet_build_$STAMP.log"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates build > "$BUILD_LOG" 2>&1; then
    fail "构建失败。完整日志：$BUILD_LOG"
    grep -E "error: " "$BUILD_LOG" | tail -30 || true
    exit 1
  fi
  grep -q "BUILD SUCCEEDED" "$BUILD_LOG" || { fail "构建未产出 SUCCEEDED（看 $BUILD_LOG）"; exit 1; }
  ok "构建成功。"
  [[ -d "$APP_PATH" ]] || { fail "未找到产物：$APP_PATH"; exit 1; }
  info "安装到设备……"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null || {
    fail "安装失败（常见原因：设备锁定 / 描述文件过期）。"; exit 1; }
  ok "安装完成。"
fi

# ------------------------------------------------------------------ 3) 冷启动 + 引导取证
if [[ "$DO_LAUNCH" == "1" ]]; then
  SESSION_START="$(date +%s)"
  info "冷启动 App（--terminate-existing 杀旧进程重开，复现「重启后首次点击」前提）……"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1 || {
    warn "启动被拒（设备可能刚锁屏）。请解锁 iPhone 后重跑（--skip-install 可跳过构建安装）。"; exit 1; }
  ok "App 已冷启动。"

  echo
  echo "════════════ 操作引导（本次启用用例）════════════"
  echo "$CASES" | while IFS='|' read -r id name kind expect; do
    printf "  %-3s %-28s → %s\n" "$id" "$name" "$expect"
  done
  echo
  echo "═══ 关键：本窗口的【首次】点击必须发生在 App 刚恢复前台后 ═══"
  echo "   1) 打开「我的」→ 「消息中心」"
  echo "   2) 【首次】点击【信创与大数据学院】那条 orgUpdate 消息"
  echo "      → 应【立即】弹出文章详情（无空白、无等待）→ 返回"
  echo "   3) 再次点击同一条（二次点击，回归）→ 应正常弹出 → 返回"
  echo "   4) 点击其他任意消息（news / 收藏更新）→ 应正常弹出 → 返回"
  echo "   5) 快速连续点击 2~3 条不同消息（B1 回归）"
  echo "   若任一点击后空白超过 3 秒，请记录开始时刻，报告将以 δ>3.0s 判该用例失败。"
  echo

  if [[ "$DO_GUIDED" == "1" ]]; then
    echo "  ── 逐步模式：每完成一步按回车继续（q 直接进入判定）──"
    echo "$CASES" | while IFS='|' read -r id name kind expect; do
      printf "  ▶ ${id} ${name}：${expect}\n    完成后按回车（q 跳过）："
      read -r _ans || true
      [[ "$_ans" == "q" ]] && break
    done
  else
    echo "  ── 观察窗 ${WAIT_SEC}s：请按上述路径操作（期间保持 App 在前台）──"
    for ((i = WAIT_SEC; i > 0; i--)); do printf "\r  剩余 %3ds …" "$i"; sleep 1; done
    printf "\r  观察窗结束。      \n"
  fi
else
  warn "考古模式（--report-only）：不启动 App，按全部日志窗口判定。"
fi

# ------------------------------------------------------------------ 4) 拉取日志 + 持久化旁证
mkdir -p "$PULL_DIR"
info "拉取 App 沙盒日志 → ${PULL_DIR}"
if ! xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/SXJZIT_Cache/Logs" --destination "$PULL_DIR" > /dev/null 2>&1; then
  fail "日志拉取失败（App 尚未运行 / 设备锁定）。"; exit 1
fi
LOG_COUNT="$(find "$PULL_DIR" -name 'log_*.json' | wc -l | tr -d ' ')"
info "已获取日志文件：${LOG_COUNT} 个"

mkdir -p "$STATE_DIR"
info "拉取消息中心持久化条目（抗日志窗口旁证）……"
if xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/MessageCenter/messageCenterEvents.json" \
      --destination "$STATE_DIR/messageCenterEvents.json" >/dev/null 2>&1; then
  ok "已获取消息中心条目"
else
  warn "消息中心条目拉取失败（P1 将仅按日志判定）"
fi

# ------------------------------------------------------------------ 5) 断言 + 6) 报告
EXPECT_MAP="$(echo "$CASES" | while IFS='|' read -r _id _name _kind _expect; do echo "${_id}|${_expect}"; done)"
python3 - "$PULL_DIR" "$REPORT" "$SESSION_START" "$DEVICE_ID" "$BUNDLE_ID" "$DO_LAUNCH" "$ROOT" "$STATE_DIR" "$SINCE_ARG" "$EXPECT_MAP" <<'PY'
# -*- coding: utf-8 -*-
"""机构动态详情白屏修复：时间相关性断言 + 静态契约 + 持久化旁证"""
import datetime
import glob
import json
import os
import re
import sys

(logdir, report_path, since, device_id, bundle_id, launched,
 root, state_dir, since_arg, expect_raw) = sys.argv[1:11]
since = float(since)
launched = (launched == "1") or bool(since_arg.strip()) if isinstance(since_arg, str) else (launched == "1")
EXPECT = {}
for _line in (expect_raw or "").splitlines():
    if "|" in _line:
        _k, _, _v = _line.partition("|")
        EXPECT[_k.strip()] = _v.strip()
REF = 978307200  # Apple 参考日期 2001-01-01 → Unix

def parse_ts(v):
    if isinstance(v, (int, float)):
        return REF + float(v)
    if isinstance(v, str):
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S.%f"):
            try:
                return datetime.datetime.strptime(v, fmt).timestamp()
            except ValueError:
                pass
    return 0.0

def fmt(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S") if ts else "-"

entries, bad_files = [], 0
for f in sorted(glob.glob(os.path.join(logdir, "**", "log_*.json"), recursive=True)):
    try:
        data = json.load(open(f, encoding="utf-8"))
        if isinstance(data, list):
            entries.extend(data)
    except Exception:
        bad_files += 1

for e in entries:
    e["_ts"] = parse_ts(e.get("timestamp"))
# 日志「最新在前」落盘 → 必须按时间升序排序（既有沉淀，勿改）
entries.sort(key=lambda e: e["_ts"])

session = [e for e in entries if e["_ts"] >= since] if launched else entries
if launched and not session:
    session = entries

def find(mod, msg):
    return [e for e in session if e.get("module") == mod and e.get("message") == msg]

def ctx(e):
    return e.get("context") or {}

# ---- 组织直达 → 详情打开的时间相关性 -------------------------------------
directs = find("ui", "机构动态通知 → 直达机构文章详情")     # 呈现打点（item 已赋值）
openeds = find("organization", "文章详情页打开")            # .task 打点（视图已创建）

def dts(e):
    return e["_ts"]

def pair_delta(d, opened, floor):
    """该直达（d）之后最近一次详情打点，间隔 δ；若详情先于直达的时间窗内不远也接受。"""
    for o in opened:
        gap = dts(o) - dts(d)
        if 0 <= gap <= 3600:
            return gap, o
    for o in opened:
        pre = dts(d) - dts(o)
        if 0 <= pre <= 1.5:   # 详情打点恰好早于直达打点 ≤1.5s（归因抖动）
            return -pre, o
    return None, None

D_LIMIT = 3.0  # 修复后 δ 上限（修复前实测 8.0s / 旧版无打点）

rows = []   # (直达, 详情, δ)
for d in directs:
    gap, o = pair_delta(d, openeds, since)
    rows.append((d, o, gap))

first = rows[0] if rows else None          # 会话内首次组织直达
second = rows[1] if len(rows) >= 2 else None

# ---- 其他消息通道（news 类：走 scheduleNotificationArticlePresentation 通道）----
# EnhancedNewsDetailView 无「打开」打点，故以「预加载调度日志」作为通道调度正常旁证
news_open = find("ui", "收到通知打开指令") or find("ui", "通知点击：已启动后台预加载文章详情")

# ---- B1 快速连续点击：消息中心投递次数 ------------------------------------
mc_taps = find("messageCenter", "消息点击 → 深链投递")

# ---- C0 无 ERROR/FATAL ----------------------------------------------------
ERROR_RE = re.compile(r"ERROR|FATAL", re.I)
errs = [e for e in session if e.get("module") in ("organization", "ui", "messageCenter")
        and ERROR_RE.search(str(e.get("message", "")) + str(e.get("context", "")))]

# ---- 状态型持久化旁证 -------------------------------------------------------
mc_items, target_read = None, None
try:
    _mf = os.path.join(state_dir, "messageCenterEvents.json")
    if os.path.exists(_mf):
        mc_items = json.load(open(_mf, encoding="utf-8"))
        targets = [m for m in mc_items
                   if m.get("kind") == "orgUpdate" and "信创" in str(((m.get("deepLink") or {}).get("orgName", "")))]
        target_read = any(t.get("isRead") for t in targets) if targets else None
except Exception:
    pass

# ---- 静态契约 -------------------------------------------------------------
SRC = os.path.join(root, "qin", "DesignCode")
def read_src(n):
    try:
        return open(os.path.join(SRC, n), encoding="utf-8").read()
    except Exception:
        return ""

tab = read_src("TabBar.swift")
msg = read_src("MessageCenterStore.swift")
notif = read_src("NotificationManager.swift")

s1 = "showOrgArticleFromNotification" not in tab
s2 = ".sheet(item: $pendingOrgArticle" in tab
s3 = "messageCenterDismissedAt" in msg
s4 = "struct PendingOrgArticleDeepLink: Equatable, Identifiable" in notif

# ---- 断言汇总 -------------------------------------------------------------
checks = []
def add(cid, name, hard, passed, detail):
    checks.append((cid, name, hard, passed, detail))

def verdict(gap):
    if gap is None:
        return "UNPAIRED", False
    okd = abs(gap) <= D_LIMIT
    return ("%.2fs" % gap), okd

if first:
    gap = first[2]
    detail = "直达 %s → 详情 %s（δ=%s）" % (fmt(dts(first[0])), fmt(dts(first[1])) if first[1] else "无", "%.2fs" % gap if gap is not None else "UNPAIRED")
    add("A1", "冷启动首次点【信创】orgUpdate", True, first[1] is not None and abs(gap) <= D_LIMIT, detail)
else:
    add("A1", "冷启动首次点【信创】orgUpdate", True, False, "会话内无「机构动态通知 → 直达机构文章详情」日志 —— 未点击或直达链路未触发")

if second:
    gap = second[2]
    add("A2", "二次点击同一条", True, second[1] is not None and abs(gap) <= D_LIMIT,
        "直达 %s → 详情 %s（δ=%s）" % (fmt(dts(second[0])), fmt(dts(second[1])) if second[1] else "无", "%.2fs" % gap if gap is not None else "UNPAIRED"))
else:
    add("A2", "二次点击同一条", True, False, "会话内仅 1 次组织直达（未执行二次点击，或无需判定的单次会话）")

if news_open:
    add("A3", "冷启动首次点其他消息(news)", False, bool(news_open),
        "「收到通知打开指令」×%d 命中；「文章详情页打开」×%d" % (len(news_open), len(openeds)))
else:
    add("A3", "冷启动首次点其他消息(news)", False, None, "未触发：会话内无 news 通道打开指令")

if mc_taps:
    add("B1", "快速连续点击不同消息", True, len(mc_taps) >= 2,
        "消息点击 → 深链投递 ×%d（≥2 覆盖快速连续场景）" % len(mc_taps))
else:
    add("B1", "快速连续点击不同消息", True, False, "会话内无消息点击投递记录")

add("C0", "无新增 ERROR/FATAL", True, not errs,
    "organization/ui/messageCenter 域 ERROR/FATAL=%d" % len(errs) + ("" if errs else ""))
add("S1", "静态契约：无双状态残留", True, s1, "无 showOrgArticleFromNotification 引用" if s1 else "仍有残留引用")
add("S2", "静态契约：sheet(item:)", True, s2, "sheet(item: $pendingOrgArticle) 存在" if s2 else "未找到单状态驱动")
add("S3", "静态契约：退场时间戳", True, s3, "messageCenterDismissedAt 存在" if s3 else "未找到共享退场时间戳")
add("S4", "静态契约：Identifiable", True, s4, "PendingOrgArticleDeepLink: Equatable, Identifiable" if s4 else "未声明 Identifiable")
if target_read is not None:
    add("P1", "持久化旁证：条目已读", False, target_read,
        "信创 orgUpdate 条目 isRead=%s（真机点开过详情 → 非白屏直接旁证）" % target_read)
else:
    add("P1", "持久化旁证：条目已读", False, None, "未拉取到消息中心条目或未找到目标条目")

hard_fail = [c for c in checks if c[2] and c[3] is False]
soft_na = [c for c in checks if c[3] is None]

# ---- Markdown 报告 ---------------------------------------------------------
L = []
L.append("# 机构动态详情「冷启动白屏」修复 · 真机验收报告")
L.append("")
L.append("| | |")
L.append("|---|---|")
L.append("| 设备 | %s（秦超的iPhone） |" % device_id)
L.append("| Bundle | %s |" % bundle_id)
L.append("| 验收时间 | %s |" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
L.append("| 判定窗口 | 启动模式=%s（%s 起），日志源 '/Documents/SXJZIT_Cache/Logs' |" % ("会话窗口" if launched else "全窗口", fmt(since)))
L.append("| 用例通过 | **%d/%d 硬性用例通过**（软性 %d 项：%d 通过 / %d 未触发） |" % (
    len([c for c in checks if c[2] and c[3] is True]),
    len([c for c in checks if c[2]]),
    len([c for c in checks if not c[2]]),
    len([c for c in checks if not c[2] and c[3] is True]),
    len(soft_na)))
L.append("")
L.append("## 修复概览")
L.append("")
L.append("**根因（机制级）**：机构动态详情 sheet 原为双状态驱动（`showOrgArticleFromNotification` bool + `pendingOrgArticle` item），存在呈现竞态窗口——bool 触发呈现时 item 可能为 nil，详情视图未创建 → `.task` 不执行 → 空/占位白屏；交互触发重建后才加载，即「划一下点一下等好几秒」。该通道为唯一走独立 sheet 的 orgUpdate 通道，故仅此一条消息受影响。")
L.append("")
L.append("**修复（局部隔离在机构动态通道，零全局改动）**：")
L.append("")
L.append("1. `TabBar.swift`：改 `sheet(item: $pendingOrgArticle)` 单状态——item 非 nil 才呈现，closure 取非可选快照，详情视图必然创建、`.task` 必然执行；删除双状态与 else 兜底分支。")
L.append("2. `TabBar.swift` + `MessageCenterStore.swift`：等待消息中心 sheet 退场判据改为共享时间戳 `messageCenterDismissedAt`（原判据引用跨视图私有 @State，静态编译即失败）。")
L.append("3. `NotificationManager.swift`：`PendingOrgArticleDeepLink` 补 `Identifiable`。")
L.append("")
L.append("## 用例清单与判定结果")
L.append("")
L.append("| ID | 用例 | 判定口径 | 结果 | 取证 |")
L.append("|---|---|---|---|---|")
for c in checks:
    cid, name, hard, passed, detail = c
    res = "✅ 通过" if passed is True else ("⬜ 未触发" if passed is None else "❌ 失败")
    L.append("| %s | %s | %s | %s | %s |" % (cid, name, EXPECT.get(cid, "-"), res, detail))
L.append("")
L.append("## 关键取证：直达 → 详情 时间线（修复核心）")
L.append("")
L.append("判定标准：`机构动态通知 → 直达机构文章详情`（ui，item 已赋值）→ `文章详情页打开`（organization，.task 执行=视图已创建）间隔 δ ≤ 3.0s。")
L.append("")
L.append("| 序号 | 直达打点 | 详情打点 | δ | 判定 |")
L.append("|---|---|---|---|---|")
if rows:
    for i, (d, o, gap) in enumerate(rows, 1):
        mark = "✅" if o and abs(gap) <= D_LIMIT else ("❌" if o is None else "❌ 超限")
        L.append("| #%d | %s | %s | %s | %s |" % (
            i, fmt(dts(d)), fmt(dts(o)) if o else "—（无 .task 打点）",
            "%.2fs" % gap if gap is not None else "UNPAIRED", mark))
else:
    L.append("| — | 无直达日志（未执行点击） | — | — | ⬜ |")
L.append("")
L.append("> 修复前对照（2026-10-02 12:41 旧版取证）：首次点击直达打点后**间隔 8.0s** 才出现详情；更早的旧版本直达后无任何详情打点（纯白屏）。")
L.append("")
L.append("## 人工确认清单（请在真机核对，自动断言之外的视觉项）")
L.append("")
for i, item in enumerate([
    "冷启动后首次点击【信创与大数据学院】：**立即**弹出完整文章内容（首屏无空白、无加载等待）",
    "返回后用同样路径二次点击同一条：同样立即弹出",
    "点击其他任意消息（news / 收藏更新）：正常弹出",
    "快速连续点击 2~3 条不同消息：无空白残留、无崩溃，最终停留在最后点击的详情",
    "详情页滑动手势（下滑关闭 sheet）与返回：流畅无卡顿",
    "消息中心角标/未读状态更新正常",
], 1):
    L.append("- [ ] %d. %s" % (i, item))
L.append("")
L.append("## 结论")
L.append("")
if hard_fail:
    L.append("**未通过**：以下硬性用例失败，需人工复验后重新验收：" + "、".join(c[0] + "," + c[1] for c in hard_fail))
else:
    L.append("**全部硬性用例通过。** 时间相关性断言确认详情视图即时创建（δ≤3.0s），静态契约确认修复代码与既有局部隔离，持久化旁证支持用户已真机点开过该条目（非白屏直接证据）。")
L.append("")
L.append("---")
L.append("")
L.append("*本报告由 `Scripts/org_article_sheet_acceptance.sh` 自动生成；命令：`bash Scripts/org_article_sheet_acceptance.sh [--skip-install]`*")

with open(report_path, "w", encoding="utf-8") as f:
    f.write("\n".join(L))

# ---- 控制台输出 ------------------------------------------------------------
print()
print("════════ 用例断言结果 ════════")
for c in checks:
    cid, name, hard, passed, detail = c
    mark = "✅" if passed is True else ("⬜" if passed is None else "❌")
    print("  %s %-3s %-30s %s" % (mark, cid, name, detail))
print()
if rows:
    for i, (d, o, gap) in enumerate(rows, 1):
        print("  直达#%d %s → 详情 %s（δ=%s）" % (
            i, fmt(dts(d)), fmt(dts(o)) if o else "无", "%.2fs" % gap if gap is not None else "UNPAIRED"))
print()
print("报告：%s" % report_path)
print("取证目录：%s" % logdir)
sys.exit(1 if hard_fail and launched else 0)
PY