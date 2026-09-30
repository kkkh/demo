#!/usr/bin/env bash
# ==============================================================================
# 机构设置模块（阶段一~三）· 真机验收测试用例脚本（2026-09-30 建立）
#
# 用途：一条命令完成「构建安装 → 启动 → 引导操作取证 → 拉日志 → 用例断言 → 报告」闭环，
#       覆盖阶段三设施接入的 12 条验收用例（看图器 / 已读 / 关注制推送 / 显示联动）。
#
# 流程：
#   1) 设备预检（devicectl 识别 UDID 且 connected）
#   2) 真机构建 + 安装（含构建期四规则护栏；--skip-install 可跳过）
#   3) 启动 App（--terminate-existing），进入观察窗并逐步引导操作
#   4) 拉取 App 沙盒日志（Documents/SXJZIT_Cache/Logs/log_*.json）
#   5) 结构化断言（用例级：桥接/看图/已读/关注/入盒/推送/深链/无 ERROR/显示联动 + 代码静态契约）
#   6) 生成 Markdown 报告至 qin/build/verify/
#
# 用法：
#   Scripts/org_module_acceptance.sh                  # 全流程（默认观察窗 180s）
#   Scripts/org_module_acceptance.sh --guided         # 逐步模式：每步回车确认（逐条核对推荐）
#   Scripts/org_module_acceptance.sh --bridge-selftest # 自动看图桥自测：启动参数 -uiTestOrgImageBridge
#                                                     # （自动派发正文首图点击 → A1 全自动判定，窗口缩至 45s）
#   Scripts/org_module_acceptance.sh --skip-install   # 不构建安装（Xcode 已装最新构建）
#   Scripts/org_module_acceptance.sh --report-only    # 仅拉日志断言（考古模式，不启动）
#   Scripts/org_module_acceptance.sh --only A1,B1,C1  # 只跑指定用例（引导与断言同步收敛）
#   Scripts/org_module_acceptance.sh --org tw         # 关注用例目标机构 siteKey（默认 kyc 科研处）
#   Scripts/org_module_acceptance.sh --wait 300       # 观察窗秒数
#   Scripts/org_module_acceptance.sh --list           # 列出用例后退出
#   Scripts/org_module_acceptance.sh --dry-run        # 只做设备预检与计划打印
#
# 判定口径（用例 → 关键日志，均为 organization/notification/messageCenter/ui/reading/display 域）：
#   A1 正文图片 → 看图器   「正文图片点击桥接到 Swift」+「正文图片打开查看器」(page=n/m)
#                          分级判定：桥就绪探针 bridge=1 且无点击 → ⬜ 未点（非缺陷）；bridge=0 → ❌ 真缺陷
#                          `--bridge-selftest` 时由 App 自动派发点击（「图片桥自测：模拟点击已派发」）
#   A2 缩略图条 → 看图器   「画廊缩略图打开查看器」
#   A3 正文链接 → 内浏览器 「正文链接点击（App 内打开）」
#   A4 视频零预载          「机构文章网页原文配色与排版注入」context 含 videos（该文章含视频时）
#   B1 进入文章 → 已读     「文章标记已读」
#   B2 阅读时长角标        reading 域「列表徽标刷新」（受显示设置三重开关）
#   C1 关注 → 基线播种     「关注机构」+「关注机构基线播种完成（只登记不推送）」
#   C2 取关                「取消关注机构」
#   C3 静默检测 → 入盒     messageCenter「新消息入盒」kind=orgUpdate（官网有新文时）
#   C4 系统通知 → 深链     「机构动态检测到更新并推送」+「机构动态通知 → 直达机构文章详情」
#   C5 消息中心条目 → 深链 「收到机构动态通知打开指令」+「机构动态通知 → 直达机构文章详情」
#   D0 模块无 ERROR        organization 域 ERROR/FATAL = 0
#   D1 显示设置联动        「系统渲染面字体接管已刷新」或「WebView 排版已实时重注入」
#   S1~S4 代码静态契约     看图桥注册/卸载、链接拦截、视频零预载、单轮全局推送上限
#
# 状态型旁证（2026-09-30 新增，抗日志窗口）：
#   App 日志单日上限 1000 条（高活跃约 3 分钟写满）→ 关注/入盒/点击等证据会被挤出。
#   脚本额外拉取并解析两处持久化数据作为铁证（即使日志缺失也可判定）：
#     · Library/Preferences/<bundle>.plist → orgFollowedOrgs（关注清单）/ orgFollowBaselineEstablished / notifiedOrgArticleIds
#     · Documents/MessageCenter/messageCenterEvents.json → kind=orgUpdate 条目（含 isRead ⇒ 用户点击过）
#   判定优先级：日志命中优先（含时间戳），否则回落持久化旁证并在报告中标注「持久化旁证」。
#
# 已知约束（踩坑沉淀，勿改）：
#   - App 日志单日上限 1000 条（高活跃约 3 分钟写满）→ 操作完成后应尽快拉取，脚本已在窗口结束立即拉取
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
PULL_DIR="$VERIFY_DIR/org-acceptance-logs-$STAMP"
REPORT="$VERIFY_DIR/org_acceptance_$STAMP.md"
REF_FILE="$VERIFY_DIR/org_acceptance_ref_$STAMP.json"
API_BASE="https://gwqietap.sxjzit.edu.cn/mapi"

WAIT_SEC=180
DO_INSTALL=1
DO_LAUNCH=1
DO_GUIDED=0
DO_BRIDGE_SELFTEST=0
INSTALL_ONLY=0
DRY_RUN=0
LIST_ONLY=0
ONLY=""
ORG_KEY="kyc"          # 关注用例目标机构（科研处；--org 可覆盖）
SESSION_START="$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE_ID="$2"; shift 2 ;;
    --wait)         WAIT_SEC="$2"; shift 2 ;;
    --org)          ORG_KEY="$2"; shift 2 ;;
    --only)         ONLY="$2"; shift 2 ;;
    --skip-install) DO_INSTALL=0; shift ;;
    --install-only) DO_INSTALL=1; INSTALL_ONLY=1; shift ;;
    --no-launch|--report-only) DO_LAUNCH=0; DO_INSTALL=0; shift ;;
    --guided)       DO_GUIDED=1; shift ;;
    --bridge-selftest) DO_BRIDGE_SELFTEST=1; [[ "$WAIT_SEC" == "180" ]] && WAIT_SEC=45; shift ;;
    --list)         LIST_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）"; exit 2 ;;
  esac
done

ok()   { echo "✅ $*"; }
info() { echo "[验收] $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; }

# ------------------------------------------------------------------ 用例清单
# 格式：ID|名称|类型(hard/soft/cond)|操作指引|判定关键词
CASES=$(cat <<'CASES'
A1|正文图片→全屏看图器|hard|打开含图文章，点正文中的大图（渲染≥60pt）|正文图片点击桥接到 Swift + 正文图片打开查看器
A2|缩略图条→全屏看图器|soft|若文章下方有缩略图条，点其中一张|画廊缩略图打开查看器
A3|正文链接→App内浏览器|soft|正文中若有超链接，点一次（应在 App 内打开官网链接页）|正文链接点击（App 内打开）
A4|视频零预载|cond|打开含视频的文章（官网部分文章内嵌 video）|注入日志 context 含 videos
B1|进入文章→标记已读|hard|打开任一机构文章后返回列表|文章标记已读
B2|阅读时长角标|soft|列表行 / 详情统计行观察角标与统计|reading 域列表徽标刷新
C1|关注机构→基线播种|hard|机构详情页身份头点「关注」（应出现 Toast 并变「已关注」）|关注机构 + 关注机构基线播种完成
C2|取关机构|soft|再点一次「已关注」（可选）|取消关注机构
C3|静默检测→机构动态入盒|cond|我的→消息中心→下拉刷新（官网该机构有新文时）|新消息入盒 kind=orgUpdate
C4|系统通知→冷启动深链|cond|（有新文且通知已授权）收到横幅→点开|机构动态检测到更新并推送 + 至文章详情
C5|消息中心条目→深链|cond|消息中心筛选「机构动态」→点任一条|收到机构动态通知打开指令 + 至文章详情
D0|模块无 ERROR|hard|自动（不需操作）|organization 域 ERROR/FATAL=0
D1|显示设置联动|soft|设置→显示设置→切字体家族/字号档→返回看正文|系统渲染面字体接管已刷新 或 WebView 排版已实时重注入
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
  echo "机构模块真机验收 · 用例清单（共 $(echo "$CASES" | grep -c '|') 条）"
  echo "──────────────────────────────────────────────"
  echo "$CASES" | while IFS='|' read -r id name kind guide expect; do
    printf "  %-3s %-26s [%s]  %s\n" "$id" "$name" "$kind" "$guide"
  done
  exit 0
fi

# ------------------------------------------------------------------ 1) 设备预检
info "设备预检：${DEVICE_ID}"
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
  fail "未找到设备 ${DEVICE_ID}（请连接 iPhone 并解锁）。"
  exit 1
fi
DEV_LINE="$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | head -1)"
echo "    ${DEV_LINE}"
echo "$DEV_LINE" | grep -q "connected" || { fail "设备未连接（请解锁并信任本机）。"; exit 1; }
ok "设备在线。"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "计划：构建=$DO_INSTALL 启动=$DO_LAUNCH 引导=$DO_GUIDED 观察窗=${WAIT_SEC}s 组织=${ORG_KEY} 仅用例=${ONLY:-全部}"
  echo "参照数据：curl -s ${API_BASE}/dept/home2?site_key=${ORG_KEY}"
  echo "报告：${REPORT}"
  exit 0
fi

# ------------------------------------------------------------------ 2) 构建 + 安装
mkdir -p "$VERIFY_DIR"
if [[ "$DO_INSTALL" == "1" ]]; then
  info "真机构建（${CONFIG}，含构建期四规则护栏）……"
  BUILD_LOG="$VERIFY_DIR/org_build_$STAMP.log"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates build > "$BUILD_LOG" 2>&1; then
    fail "构建失败。完整日志：$BUILD_LOG"
    grep -E "error: |护栏|❌" "$BUILD_LOG" | tail -30 || true
    exit 1
  fi
  grep -q "BUILD SUCCEEDED" "$BUILD_LOG" || { fail "构建未产出 SUCCEEDED（看 $BUILD_LOG）"; exit 1; }
  grep -q "显示设置覆盖护栏通过" "$BUILD_LOG" && ok "构建通过（护栏四规则 0 缺口）" || warn "构建通过，但未捕获护栏通过标记（请核对构建日志）"
  [[ -d "$APP_PATH" ]] || { fail "未找到产物：$APP_PATH"; exit 1; }
  info "安装到设备……"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null || {
    fail "安装失败（常见原因：设备锁定 / 描述文件过期）。"; exit 1; }
  ok "安装完成。"
fi

if [[ "$INSTALL_ONLY" == "1" ]]; then
  ok "（--install-only）已构建并安装最新构建；跳过启动与取证。"
  echo "    下一步（自测模式，devicectl 用环境变量传参最稳）："
  echo "      xcrun devicectl device process launch --device ${DEVICE_ID} --terminate-existing -e '{\"SJZ_ORG_IMAGE_BRIDGE_SELFTEST\":\"1\"}' ${BUNDLE_ID}"
  echo "    或直接用本脚本：bash $0 --skip-install --bridge-selftest"
  echo "    仅判定：      bash $0 --report-only"
  exit 0
fi

# ------------------------------------------------------------------ 3) 启动 + 引导取证
if [[ "$DO_LAUNCH" == "1" ]]; then
  SESSION_START="$(date +%s)"
  if [[ "$DO_BRIDGE_SELFTEST" == "1" ]]; then
    info "启动 App（自测模式：环境变量 SJZ_ORG_IMAGE_BRIDGE_SELFTEST=1，将自动派发一次正文图片点击）……"
    xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
      -e '{"SJZ_ORG_IMAGE_BRIDGE_SELFTEST":"1"}' "$BUNDLE_ID" >/dev/null || {
      fail "启动失败：${BUNDLE_ID}（App 未安装？去掉 --skip-install 重跑）。"; exit 1; }
  else
    info "启动 App（--terminate-existing）……"
    xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" >/dev/null || {
      fail "启动失败：${BUNDLE_ID}（App 未安装？去掉 --skip-install 重跑）。"; exit 1; }
  fi

  echo
  echo "════════════ 操作引导（本次启用用例）════════════"
  echo "$CASES" | while IFS='|' read -r id name kind guide expect; do
    case_enabled "$id" && printf "  %-3s %-24s → %s\n          判定：%s\n" "$id" "$name" "$guide" "$expect"
  done
  echo
  echo "  推荐操作路径："
  echo "   1) 校园 → 查看全部机构 → 科研处 → 栏目「科研动态」→ 打开一篇文章"
  echo "   2) 点正文中的大图 → 全屏看图器（双指缩放 / 左右翻页 / 右上 n/N）→ 关闭"
  echo "   3) 若有缩略图条 → 点一张缩略图（同样打开查看器）"
  echo "   4) 正文内若有超链接 → 点一次（App 内打开官网链接页，可关闭）"
  echo "   5) 返回列表：该文章未读光点应已消散、标题略淡"
  echo "   6) 进入任一机构详情页 → 身份头点「关注」→ 出现 Toast「已关注…」"
  echo "   7) 我的 → 消息中心 → 下拉刷新（静默检测）→ 观察「机构动态」条目"
  echo "   8) 消息中心筛选「机构动态」→ 点任一条 → 应弹出该文章详情"
  echo "   9) 设置 → 显示设置 → 切一次字体家族/字号档 → 返回机构文章正文看联动"
  if [[ "$DO_BRIDGE_SELFTEST" == "1" ]]; then
    echo
    echo "  ▶ 自测模式已开启：打开任一含图文章后，App 会在 1.5s 后自动点击正文首图"
    echo "    （全屏查看器会自行弹出——即 A1 通过的直接视觉证据；可手动关闭）"
  fi
  echo

  if [[ "$DO_GUIDED" == "1" ]]; then
    echo "  ── 逐步模式：每完成一步按回车继续（q 直接进入判定）──"
    echo "$CASES" | while IFS='|' read -r id name kind guide expect; do
      case_enabled "$id" || continue
      printf "  ▶ ${id} ${name}：${guide}\n    完成后按回车（q 跳过并进入判定）："
      read -r _ans || true
      [[ "$_ans" == "q" ]] && break
    done
  else
    echo "  ── 观察窗 ${WAIT_SEC}s：请按上述路径操作（期间保持 App 在前台）──"
    for ((i = WAIT_SEC; i > 0; i--)); do printf "\r  剩余 %3ds …" "$i"; sleep 1; done
    printf "\r  观察窗结束。      \n"
  fi
else
  warn "考古模式（--report-only）：不启动 App，按「全部日志窗口」判定。"
fi

# ------------------------------------------------------------------ 3.5) 参照数据（官网该机构最新文章，供 C 用例判定前提）
info "抓取参照数据：${ORG_KEY} 最新文章（供「是否有新文」判定参照）"
if curl -s --max-time 25 "${API_BASE}/dept/home2?site_key=${ORG_KEY}" -o "$REF_FILE"; then
  python3 - "$REF_FILE" <<'PY' || warn "参照数据解析失败（不影响其他用例判定）"
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("   解析失败：%s" % e); raise SystemExit(1)
rows = []
for item in ((d.get("data") or {}).get("nav") or []):
    blocks = item.get("data") if isinstance(item.get("data"), dict) else {}
    for _, sec in (blocks or {}).items():
        if not isinstance(sec, dict):
            continue
        for a in (((sec.get("articles") or {}).get("list")) or []):
            if a.get("id"):
                rows.append((a.get("update_time") or "", a["id"], (a.get("title") or "")[:34]))
    for a in (((item.get("articles") or {}).get("list")) or []):
        if a.get("id"):
            rows.append((a.get("update_time") or "", a["id"], (a.get("title") or "")[:34]))
rows.sort(reverse=True)
print("   官网 %s 最新 5 条：" % sys.argv[1].split("home2")[0].split("site_key=")[-1])
for t, i, ti in rows[:5]:
    print("     %s  %s  %s" % (t, i[:12], ti))
if not rows:
    print("   ⚠️ 未取到文章列表（该机构可能为单文章型/接口变动）")
PY
else
  warn "参照数据抓取失败（网络受限？），C 用例将按日志判定。"
fi

# ------------------------------------------------------------------ 4) 拉取日志
mkdir -p "$PULL_DIR"
info "拉取 App 沙盒日志 → ${PULL_DIR}"
if ! xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/SXJZIT_Cache/Logs" --destination "$PULL_DIR" > /dev/null 2>&1; then
  fail "日志拉取失败。可能原因：App 尚未运行过（日志目录未生成）/ 设备锁定。"
  exit 1
fi
LOG_COUNT="$(find "$PULL_DIR" -name 'log_*.json' | wc -l | tr -d ' ')"
info "已获取日志文件：${LOG_COUNT} 个"

# ------------------------------------------------------------------ 4.5) 拉取状态型旁证
# App 日志单日上限 1000 条（高活跃约 3 分钟写满）→ 关注/入盒/点击等「状态型」证据会被挤出窗口。
# 因此额外拉取持久化数据作为铁证：偏好设置（关注清单 / 基线标记 / 去重集）+ 消息中心条目。
STATE_DIR="$PULL_DIR/state"
mkdir -p "$STATE_DIR"
info "拉取状态型旁证（偏好设置 / 消息中心条目）……"
if xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Library/Preferences/${BUNDLE_ID}.plist" \
      --destination "$STATE_DIR/prefs.plist" >/dev/null 2>&1; then
  ok "已获取偏好设置 plist（关注清单 / 基线标记）"
else
  warn "偏好设置 plist 拉取失败（关注用例将仅按日志判定）"
fi
if xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/MessageCenter/messageCenterEvents.json" \
      --destination "$STATE_DIR/messageCenterEvents.json" >/dev/null 2>&1; then
  ok "已获取消息中心条目（机构动态入盒 / 点击旁证）"
else
  warn "消息中心条目拉取失败（入盒用例将仅按日志判定）"
fi

# ------------------------------------------------------------------ 5) 用例断言 + 6) 报告
python3 - "$PULL_DIR" "$REPORT" "$SESSION_START" "$DEVICE_ID" "$BUNDLE_ID" "$DO_LAUNCH" "$ONLY" "$ORG_KEY" "$ROOT" "$REF_FILE" "$DO_BRIDGE_SELFTEST" "$STATE_DIR" <<'PY'
# -*- coding: utf-8 -*-
"""机构模块真机验收：用例级日志断言（阶段三设施接入）+ 状态型持久化旁证"""
import datetime
import glob
import json
import os
import plistlib
import re
import sys

(logdir, report_path, since, device_id, bundle_id, launched, only_raw,
 org_key, root, ref_file, selftest_raw, state_dir) = sys.argv[1:13]
since = float(since)
launched = launched == "1"
selftest_mode = selftest_raw == "1"
REF = 978307200  # Apple 参考日期 2001-01-01 → Unix

ONLY = {x.strip().upper() for x in only_raw.split(",") if x.strip()} if only_raw else set()


def enabled(cid):
    return (not ONLY) or (cid in ONLY)


# ---- 状态型持久化旁证（不受日志 1000 条上限影响） ---------------------------
followed_orgs, baseline_flag, notified_count = None, None, None
try:
    _pf = os.path.join(state_dir, "prefs.plist")
    if os.path.exists(_pf):
        _pl = plistlib.load(open(_pf, "rb"))
        _raw = _pl.get("orgFollowedOrgs")
        if isinstance(_raw, str):
            followed_orgs = json.loads(_raw)
        elif isinstance(_raw, list):
            followed_orgs = _raw
        baseline_flag = bool(_pl.get("orgFollowBaselineEstablished"))
        _ids = _pl.get("notifiedOrgArticleIds")
        notified_count = len(_ids) if isinstance(_ids, list) else None
except Exception as _e:
    followed_orgs = None

mc_items, mc_org = None, []
try:
    _mf = os.path.join(state_dir, "messageCenterEvents.json")
    if os.path.exists(_mf):
        mc_items = json.load(open(_mf, encoding="utf-8"))
        mc_org = [m for m in mc_items if m.get("kind") == "orgUpdate"]
except Exception:
    mc_items = None

mc_org_read = [m for m in mc_org if m.get("isRead")]


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
# 关键：日志文件按「最新在前」落盘 → 必须先按时间升序排序（2026-09-29 修正）
entries.sort(key=lambda e: e["_ts"])

# 会话窗口：启动模式用启动时刻过滤；考古模式用全窗口
session = [e for e in entries if e["_ts"] >= since] if launched else entries
if launched and not session:
    session = entries  # 兜底：时区/时钟偏差

def find(mod, msg, **ctx):
    out = []
    for e in session:
        if e.get("module") != mod or e.get("message") != msg:
            continue
        c = e.get("context") or {}
        if all(str(c.get(k, "")) == str(v) for k, v in ctx.items()):
            out.append(e)
    return out


checks = []  # (硬性?, 用例, 名称, 通过?, 详情)


def add(hard, cid, name, passed, detail):
    checks.append((hard, cid, name, passed, detail))


def skip(cid, name, reason="未在选择范围 / 未触发（前提不满足）"):
    checks.append((False, cid, name, None, reason))


# ---- S1~S4 代码静态契约（不依赖交互，始终判定） -------------------------------
SRC = os.path.join(root, "qin", "DesignCode")
def read_src(name):
    try:
        return open(os.path.join(SRC, name), encoding="utf-8").read()
    except Exception:
        return ""

detail_src = read_src("OrganizationDetailView.swift")
notif_src = read_src("NotificationManager.swift")
follow_src = read_src("OrgFollowStore.swift")

s1 = ('imageTapHandlerName = "sjzOrgImageTap"' in detail_src
      and "removeScriptMessageHandler(forName: imageTapHandlerName)" in detail_src
      and "userContentController.add(context.coordinator, name: Self.imageTapHandlerName)" in detail_src)
add(True, "S1", "看图桥注册 + 卸载（防 Coordinator 泄漏）", s1,
    "sjzOrgImageTap 注册/移除成对存在" if s1 else "未找到注册或卸载代码")
s2 = ("decidePolicyFor navigationAction" in detail_src and "navigationType == .linkActivated" in detail_src)
add(True, "S2", "正文链接拦截（.linkActivated）", s2,
    "http(s) 进 App 内浏览器，非 http(s) 分流" if s2 else "未拦截 .linkActivated")
s3 = ("video.setAttribute('preload', 'none')" in detail_src
      or "preload','none'" in detail_src or "preload', 'none'" in detail_src)
add(True, "S3", "视频零预载（preload=none）", s3, "JS 统一 playsinline + preload=none" if s3 else "未找到 preload=none")
s4 = ("guard pushed < maxNotificationsPerCheck else { break }" in notif_src
      and "notifiedOrgArticleIds.union(known)" in notif_src)
add(True, "S4", "第五通道：单轮全局上限 + 并集写回", s4,
    "≤5 条/轮 + 去重集并集合并" if s4 else "未找到上限或并集写回")
s5 = ('var readKey: String { articleId.isEmpty ? title + updateTime : articleId }' in detail_src)
add(False, "S5", "已读键唯一口径（OrgArticle.readKey）", s5, "articleId 优先，空则 title+updateTime" if s5 else "未找到 readKey")

# ---- A1 正文图片 → 看图器（分级判定：桥就绪探针 → 区分「未点」与「真缺陷」） ----
bridge = find("organization", "正文图片点击桥接到 Swift")
viewer = find("organization", "正文图片打开查看器")
probe = find("organization", "正文看图桥就绪探针")
selftest = find("organization", "图片桥自测：模拟点击已派发")
page_ok = any(re.match(r"^\d+/\d+$", str(((e.get("context") or {}).get("page")) or "")) for e in viewer)

probe_bound, probe_viewable, probe_total, probe_raw = None, None, None, "-"
# 探针可能多次采样（每篇文章一次，且 didFinish 早期采样可能读到 0）→
# 优先取「可查看图数 > 0」的最后一条作为代表，避免误报「该文章无图」
probe_candidates = []
for _e in probe:
    _raw = str((_e.get("context") or {}).get("result", "-"))
    _parts = _raw.split("|")
    if len(_parts) == 3:
        try:
            probe_candidates.append((_parts[0].strip().lower() == "true", int(_parts[1]), int(_parts[2]), _raw))
        except ValueError:
            continue
_with_images = [c for c in probe_candidates if c[1] > 0]
_chosen = _with_images[-1] if _with_images else (probe_candidates[-1] if probe_candidates else None)
if _chosen:
    probe_bound, probe_viewable, probe_total, probe_raw = _chosen

if enabled("A1"):
    if bridge:
        c = bridge[-1].get("context") or {}
        add(True, "A1", "A1a 正文图片点击桥接到 Swift", True,
            "index=%s count=%s（%s）" % (c.get("index", "-"), c.get("count", "-"), fmt(bridge[-1]["_ts"])))
    elif probe_bound is False:
        add(True, "A1", "A1a 正文图片点击桥接到 Swift", False,
            "桥未绑定（探针 result=%s）——JS 处理器注册异常，属真缺陷" % probe_raw)
    elif probe and probe_viewable == 0:
        add(False, "A1", "A1a 正文图片点击桥接到 Swift", None,
            "未触发：探针 %s 显示该文章无 ≥60pt 可查看图（点小图标/表格图不触发属预期）" % probe_raw)
    elif probe:
        add(False, "A1", "A1a 正文图片点击桥接到 Swift", None,
            "未触发：桥就绪（探针 %s）但未捕获点击 → 请点正文大图，或用 --bridge-selftest 自动派发" % probe_raw)
    else:
        add(False, "A1", "A1a 正文图片点击桥接到 Swift", None,
            "未触发：无桥探针记录（可能文章为纯文本 / WebView 未渲染完成）")
    if selftest:
        sc = selftest[-1].get("context") or {}
        st_ok = str(sc.get("result", "")).startswith("clicked")
        add(True, "A1", "A1a′ 自测点击已派发（-uiTestOrgImageBridge）", st_ok,
            "result=%s（%s）" % (sc.get("result", "-"), fmt(selftest[-1]["_ts"])))
    elif selftest_mode:
        add(True, "A1", "A1a′ 自测点击已派发（-uiTestOrgImageBridge）", False,
            "自测模式已启用但未派发：请先打开任一含图文章（打开后 1.5s 自动点击）")
    if viewer:
        c = viewer[-1].get("context") or {}
        add(True, "A1", "A1b 正文图片打开查看器（含页码）", page_ok,
            "page=%s total=%s source=%s（%s）" % (c.get("page", "-"), c.get("total", "-"), c.get("source", "-"), fmt(viewer[-1]["_ts"])))
    elif bridge:
        add(True, "A1", "A1b 正文图片打开查看器（含页码）", False, "点击已桥接但未打开查看器（载荷构造失败？）")
    else:
        add(False, "A1", "A1b 正文图片打开查看器（含页码）", None, "未触发（无点击）")
else:
    skip("A1", "正文图片 → 看图器")

# ---- A2 缩略图条 → 看图器 ---------------------------------------------------
if enabled("A2"):
    strip = find("organization", "画廊缩略图打开查看器")
    add(False, "A2", "A2 缩略图条打开查看器", bool(strip) or None,
        ("page=%s（%s）" % (((strip[-1].get("context") or {}).get("page", "-")), fmt(strip[-1]["_ts"]))) if strip
        else "未触发（该文章无缩略图条或未点击）")
else:
    skip("A2", "缩略图条 → 看图器")

# ---- A3 正文链接 → App 内浏览器 ---------------------------------------------
if enabled("A3"):
    link = find("organization", "正文链接点击（App 内打开）")
    add(False, "A3", "A3 正文链接拦截 → App 内浏览器", bool(link) or None,
        ("url=%s" % str((link[-1].get("context") or {}).get("url", "-"))[:60]) if link
        else "未触发（该文章正文无超链接或未点击）")
else:
    skip("A3", "正文链接 → App 内浏览器")

# ---- A4 视频零预载（含视频文章） --------------------------------------------
if enabled("A4"):
    inject = [e for e in session if e.get("module") == "organization"
              and e.get("message") == "机构文章网页原文配色与排版注入"]
    with_video = [e for e in inject if (e.get("context") or {}).get("videos")]
    add(False, "A4", "A4 含视频文章渲染（零预载契约见 S3）", bool(with_video) or None,
        ("videos=%s（%s）" % ((with_video[-1].get("context") or {}).get("videos"), fmt(with_video[-1]["_ts"]))) if with_video
        else "未触发（本次打开的文章均不含 video；契约由 S3 静态保障）")
else:
    skip("A4", "视频零预载")

# ---- B1 进入文章 → 已读 -----------------------------------------------------
if enabled("B1"):
    readm = find("organization", "文章标记已读")
    ok_b1 = bool(readm)
    c = (readm[-1].get("context") or {}) if readm else {}
    add(True, "B1", "B1 进入文章即标记已读", ok_b1,
        "articleId=%s（%s）" % (str(c.get("articleId", "-"))[:14], fmt(readm[-1]["_ts"]) if readm else "-")
        if ok_b1 else "未捕获：请打开任一机构文章后返回")
else:
    skip("B1", "进入文章 → 标记已读")

# ---- B2 阅读时长角标（受设置三重开关） --------------------------------------
if enabled("B2"):
    badge = [e for e in session if e.get("module") == "reading"
             and e.get("message") in ("列表徽标刷新", "统计行即将渲染")]
    c = (badge[-1].get("context") or {}) if badge else {}
    add(False, "B2", "B2 阅读时长角标 / 统计渲染", bool(badge) or None,
        ("id=%s（%s）" % (str(c.get("id", "-"))[:14], fmt(badge[-1]["_ts"]))) if badge
        else "未触发（需进入机构文章列表/详情）")
else:
    skip("B2", "阅读时长角标")

# ---- C1 关注 → 基线播种（日志优先，plist 状态型旁证兜底） --------------------
if enabled("C1"):
    follow = find("organization", "关注机构")
    seed = find("notification", "关注机构基线播种完成（只登记不推送）")
    baseline = find("notification", "机构动态通道基线建立（不推送历史）")
    if follow:
        c = follow[-1].get("context") or {}
        add(True, "C1", "C1a 关注动作落库", True,
            "日志：siteKey=%s name=%s total=%s（%s）" % (c.get("siteKey", "-"), c.get("name", "-"), c.get("total", "-"), fmt(follow[-1]["_ts"])))
    elif followed_orgs:
        _names = "、".join("%s(%s)" % (o.get("name", "?"), o.get("siteKey", "?")) for o in followed_orgs[:4])
        add(True, "C1", "C1a 关注动作落库（plist 旁证）", True,
            "关注清单 %d 个：%s（日志已被 1000 条上限挤出，采用持久化旁证）" % (len(followed_orgs), _names))
    elif followed_orgs == []:
        add(True, "C1", "C1a 关注动作落库", False, "关注清单为空且日志未命中：请在机构详情页身份头点「关注」")
    else:
        add(True, "C1", "C1a 关注动作落库", False, "未捕获：日志未命中且 plist 不可读（请在详情页点「关注」后重跑）")
    if seed:
        sc = seed[-1].get("context") or {}
        add(True, "C1", "C1b 关注基线播种 / 建立", True,
            "日志：播种 siteKey=%s articles=%s（%s）" % (sc.get("siteKey", "-"), sc.get("articles", "-"), fmt(seed[-1]["_ts"])))
    elif baseline:
        bc = baseline[-1].get("context") or {}
        add(True, "C1", "C1b 关注基线播种 / 建立", True,
            "日志：基线建立 orgs=%s articles=%s（%s）" % (bc.get("orgs", "-"), bc.get("articles", "-"), fmt(baseline[-1]["_ts"])))
    elif baseline_flag or (notified_count or 0) > 0:
        add(True, "C1", "C1b 关注基线播种 / 建立（plist 旁证）", True,
            "orgFollowBaselineEstablished=true，去重集 %s 条（日志已挤出，采用持久化旁证）" % (notified_count if notified_count is not None else "-"))
    else:
        add(True, "C1", "C1b 关注基线播种 / 建立", False, "未捕获：关注成功后应触发基线播种（防历史轰炸）")
else:
    skip("C1", "关注 → 基线播种")

# ---- C2 取关（日志；plist 旁证：清单空 + 去重集非空 ⇒ 曾关注现已取关） -------
if enabled("C2"):
    unfollow = find("organization", "取消关注机构")
    if unfollow:
        add(False, "C2", "C2 取关动作", True,
            "日志：siteKey=%s remaining=%s" % (((unfollow[-1].get("context") or {}).get("siteKey", "-")),
                                               ((unfollow[-1].get("context") or {}).get("remaining", "-"))))
    elif followed_orgs == [] and (notified_count or 0) > 0:
        add(False, "C2", "C2 取关动作（plist 旁证）", True,
            "关注清单为空且去重集 %s 条 ⇒ 曾关注、现已全部取关" % notified_count)
    else:
        add(False, "C2", "C2 取关动作", None, "未触发（可选用例：再点一次「已关注」）")
else:
    skip("C2", "取关")

# ---- C3 静默检测 → 机构动态入盒（消息中心条目为状态型铁证） ------------------
if enabled("C3"):
    inbox = [e for e in session if e.get("module") == "messageCenter"
             and e.get("message") == "新消息入盒"
             and str((e.get("context") or {}).get("kind", "")) == "orgUpdate"]
    if inbox:
        add(False, "C3", "C3 机构动态静默入盒（orgUpdate）", True,
            "日志：id=%s unread=%s（%s）" % (((inbox[-1].get("context") or {}).get("id", "-")),
                                             ((inbox[-1].get("context") or {}).get("unread", "-")), fmt(inbox[-1]["_ts"])))
    elif mc_org:
        m = mc_org[-1]
        add(False, "C3", "C3 机构动态静默入盒（orgUpdate，持久化旁证）", True,
            "消息中心存在 orgUpdate 条目：%s（%s）" % (str(m.get("title", "-")), str(m.get("id", "-"))[:24]))
    else:
        add(False, "C3", "C3 机构动态静默入盒（orgUpdate）", None,
            "未触发：官网「%s」在该机构去重集之外暂无新文（见参照数据）" % org_key)
else:
    skip("C3", "静默检测 → 机构动态入盒")

# ---- C4 系统通知 + 冷启动深链 ----------------------------------------------
push = find("notification", "机构动态检测到更新并推送")
deep = find("ui", "机构动态通知 → 直达机构文章详情")
if enabled("C4"):
    if push:
        c = push[-1].get("context") or {}
        add(False, "C4", "C4a 第五通道系统通知已推送", True,
            "日志：pushed=%s orgs=%s silent=%s（%s）" % (c.get("pushed", "-"), c.get("orgs", "-"), c.get("silent", "-"), fmt(push[-1]["_ts"])))
    elif mc_org:
        add(False, "C4", "C4a 第五通道系统通知已推送（持久化旁证）", True,
            "orgUpdate 条目已产出（%d 条）⇒ 该通道已完成推送/入盒（推送日志被窗口挤出，采用持久化旁证）" % len(mc_org))
    else:
        add(False, "C4", "C4a 第五通道系统通知已推送", None,
            "未触发：依赖「官网该机构有新文」+ 通知轮询（下拉消息中心或等待轮询周期）")
    if deep:
        add(False, "C4", "C4b 通知点击 → 冷启动直达文章详情", True,
            "日志：articleId=%s org=%s（%s）" % (((deep[-1].get("context") or {}).get("articleId", "-")),
                                                ((deep[-1].get("context") or {}).get("org", "-")), fmt(deep[-1]["_ts"])))
    elif mc_org_read:
        m = mc_org_read[-1]
        add(False, "C4", "C4b 通知点击 → 冷启动直达文章详情（持久化旁证）", True,
            "orgUpdate 条目已读 ⇒ 用户点击并完成深链（日志已挤出，采用持久化旁证）：%s" % str(m.get("id", "-"))[:24])
    else:
        add(False, "C4", "C4b 通知点击 → 冷启动直达文章详情", None, "未触发：点击「【机构名】有新内容」横幅后应弹出文章详情")
else:
    skip("C4", "系统通知 → 冷启动深链")

# ---- C5 消息中心条目 → 深链 -------------------------------------------------
if enabled("C5"):
    instr = find("ui", "收到机构动态通知打开指令")
    if instr and deep:
        add(False, "C5", "C5 消息中心「机构动态」条目 → 深链", True,
            "日志：指令 %d 条、落地 %d 条（%s）" % (len(instr), len(deep), fmt(deep[-1]["_ts"])))
    elif deep:
        add(False, "C5", "C5 消息中心「机构动态」条目 → 深链", True,
            "日志：落地 %d 条（指令日志已被窗口挤出）（%s）" % (len(deep), fmt(deep[-1]["_ts"])))
    elif instr:
        add(False, "C5", "C5 消息中心「机构动态」条目 → 深链", None,
            "指令已收到 %d 条但未见落地记录：文章详情可能未成功弹出" % len(instr))
    elif mc_org_read:
        m = mc_org_read[-1]
        add(False, "C5", "C5 消息中心「机构动态」条目 → 深链（持久化旁证）", True,
            "orgUpdate 条目已读 ⇒ 点击已触发深链投递（日志已挤出，采用持久化旁证）：%s" % str(m.get("title", "-")))
    elif mc_org:
        add(False, "C5", "C5 消息中心「机构动态」条目 → 深链", None, "存在条目但未见点击痕迹：消息中心筛选「机构动态」并点任一条")
    else:
        add(False, "C5", "C5 消息中心「机构动态」条目 → 深链", None, "未触发：消息中心暂无 orgUpdate 条目（先满足 C3 前提）")
else:
    skip("C5", "消息中心条目 → 深链")

# ---- D0 organization 域无 ERROR --------------------------------------------
if enabled("D0"):
    org_err = [e for e in session if e.get("module") == "organization"
               and str(e.get("level")) in ("ERROR", "FATAL")]
    all_err = [e for e in session if str(e.get("level")) in ("ERROR", "FATAL")]
    add(True, "D0", "D0 organization 域无 ERROR/FATAL", len(org_err) == 0,
        "模块异常 %d 条；全 App 异常 %d 条（%s）" % (len(org_err), len(all_err),
        ("首条：" + str(org_err[0].get("message"))) if org_err else "无"))
else:
    skip("D0", "模块无 ERROR")

# ---- D1 显示设置联动 -------------------------------------------------------
if enabled("D1"):
    refresh = [e for e in session if e.get("message") == "系统渲染面字体接管已刷新"]
    webview = [e for e in session if e.get("message") == "WebView 排版已实时重注入"]
    add(False, "D1", "D1 显示设置联动（接管刷新 / WebView 重注入）", bool(refresh) or bool(webview) or None,
        "接管刷新 %d 条、WebView 重注入 %d 条（%s）" % (len(refresh), len(webview),
        fmt((refresh + webview)[-1]["_ts"])) if (refresh or webview) else "未触发：切换字体家族/字号后应即时生效")
else:
    skip("D1", "显示设置联动")

# ---- 报告 ------------------------------------------------------------------
hard_failed, soft_gap, skipped = 0, 0, 0
for hard, cid, name, passed, _ in checks:
    if passed is None:
        skipped += 1
    elif not passed:
        if hard:
            hard_failed += 1
        else:
            soft_gap += 1

lines = []
lines.append("# 机构设置模块 · 真机验收报告（阶段三设施接入）")
lines.append("")
lines.append("- 设备：`%s`" % device_id)
lines.append("- Bundle：`%s`" % bundle_id)
lines.append("- 模式：%s" % (("启动取证" if launched else "考古（仅拉日志）")
                             + (" + 看图桥自测（-uiTestOrgImageBridge）" if selftest_mode else "")))
if probe:
    lines.append("- 看图桥就绪探针（最近）：`%s`（绑定|可查看图数|总图数）" % probe_raw)
lines.append("- 拉取窗口：%s → %s（%d 条；文件 %d 个，损坏 %d）" % (
    fmt(entries[0]["_ts"]) if entries else "-", fmt(entries[-1]["_ts"]) if entries else "-",
    len(entries), len(glob.glob(os.path.join(logdir, "**", "log_*.json"), recursive=True)), bad_files))
lines.append("- 会话判定窗口：%d 条" % len(session))
lines.append("- 关注用例目标机构：`%s`" % org_key)
lines.append("- 日志目录：`%s`" % logdir)
lines.append("")
lines.append("## 用例结果")
lines.append("")
lines.append("| 用例 | 类型 | 项 | 结果 | 详情 |")
lines.append("|---|---|---|---|---|")
CASE_KIND = {}
for hard, cid, name, passed, detail in checks:
    kind = "静态契约" if cid.startswith("S") else ("硬性" if hard else "信息")
    CASE_KIND[cid] = kind
    mark = "✅ 通过" if passed else ("⬜ 未触发" if passed is None else "❌ 未通过")
    lines.append("| %s | %s | %s | %s | %s |" % (cid, kind, name, mark, detail))

lines.append("")
lines.append("## 状态型旁证（持久化数据；不受日志 1000 条上限影响）")
lines.append("")
if followed_orgs is None:
    lines.append("- 关注清单：**plist 未获取**（关注用例仅按日志判定）")
elif not followed_orgs:
    lines.append("- 关注清单：空（尚未关注任何机构）")
else:
    lines.append("- 关注清单：**%d 个** ｜ 基线标记 `orgFollowBaselineEstablished`=%s ｜ 去重集 `notifiedOrgArticleIds`=%s 条" % (
        len(followed_orgs), "true" if baseline_flag else "false",
        notified_count if notified_count is not None else "-"))
    lines.append("")
    lines.append("| siteKey | 机构名 | 分类 | siteId |")
    lines.append("|---|---|---|---|")
    for o in followed_orgs:
        lines.append("| `%s` | %s | %s | `%s…` |" % (o.get("siteKey", "-"), o.get("name", "-"),
                                                     o.get("categoryRaw", "-"), str(o.get("siteId", "-"))[:10]))
if mc_items is not None:
    lines.append("")
    lines.append("- 消息中心条目：共 **%d 条**，其中「机构动态」(orgUpdate) **%d 条**（已读 %d 条）" % (
        len(mc_items), len(mc_org), len(mc_org_read)))
    if mc_org:
        lines.append("")
        lines.append("| id | 标题 | 副标题 | 已读 |")
        lines.append("|---|---|---|---|")
        for m in mc_org[:8]:
            lines.append("| `%s…` | %s | %s | %s |" % (str(m.get("id", "-"))[:22], m.get("title", "-"),
                                                       str(m.get("subtitle", "-"))[:34], "是" if m.get("isRead") else "否"))
else:
    lines.append("- 消息中心条目：**未获取**（入盒用例仅按日志判定）")

lines.append("")
lines.append("## 人工确认项（脚本不判定，请在真机上目视核对）")
lines.append("")
lines.append("| 项 | 期望 |")
lines.append("|---|---|")
lines.append("| 未读光点消散 | 打开文章返回后，该行 6pt 蓝点弹簧收敛消失、标题略淡（其余行不受影响） |")
lines.append("| 关注按钮状态 | 「关注」↔「已关注」铜金态切换、Toast 文案正确、列表该机构卡出现铜金铃铛 |")
lines.append("| 看图器手势 | 双指缩放跟手、1x 横滑翻页、页码 n/N、关闭后回到原文位置 |")
lines.append("| 视频（若有） | 未点播不加载（无进度条走动）、点播内联播放、圆角与底色占位 |")
lines.append("| 消息中心筛选 | 出现「机构动态」筛选项，条目图标为 building.2.fill / 青色系 |")

# 时间线：organization / notification / messageCenter / ui（≤25 条）
lines.append("")
lines.append("## 关键时间线（organization / notification / messageCenter / ui，最近 25 条）")
lines.append("")
hot_mods = {"organization", "notification", "messageCenter", "ui"}
hot = [e for e in session if e.get("module") in hot_mods]
for e in hot[-25:]:
    c = e.get("context") or {}
    brief = " ".join("%s=%s" % (k, v) for k, v in list(c.items())[:4])
    lines.append("- `%s` [%s|%s] %s  %s" % (fmt(e["_ts"]), e.get("level"), e.get("module"), e.get("message"), brief))

# 异常条目
issues = [e for e in session if str(e.get("level")) in ("WARNING", "ERROR", "FATAL")]
if issues:
    lines.append("")
    lines.append("## 会话内异常级别条目（最多 15 条）")
    lines.append("")
    for e in issues[:15]:
        lines.append("- `%s` [%s|%s] %s" % (fmt(e["_ts"]), e.get("level"), e.get("module"), e.get("message")))

# 参照数据
try:
    ref = json.load(open(ref_file, encoding="utf-8"))
    rows = []
    for item in ((ref.get("data") or {}).get("nav") or []):
        blocks = item.get("data") if isinstance(item.get("data"), dict) else {}
        for _, sec in (blocks or {}).items():
            if isinstance(sec, dict):
                for a in (((sec.get("articles") or {}).get("list")) or []):
                    if a.get("id"):
                        rows.append((a.get("update_time") or "", a["id"], (a.get("title") or "")[:30]))
        for a in (((item.get("articles") or {}).get("list")) or []):
            if a.get("id"):
                rows.append((a.get("update_time") or "", a["id"], (a.get("title") or "")[:30]))
    rows.sort(reverse=True)
    if rows:
        lines.append("")
        lines.append("## 参照数据：官网 `%s` 最新 5 条（C 用例前提核对）" % org_key)
        lines.append("")
        lines.append("| 更新时间 | articleId | 标题 |")
        lines.append("|---|---|---|")
        for t, i, ti in rows[:5]:
            lines.append("| %s | `%s…` | %s |" % (t, i[:10], ti))
except Exception:
    pass

open(report_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")

print("")
print("════════════════ 用例结果 ════════════════")
for hard, cid, name, passed, detail in checks:
    mark = "✅" if passed else ("⬜" if passed is None else "❌")
    print("%s %-3s %s —— %s" % (mark, cid, name, detail))

print("")
print("报告：%s" % report_path)
if hard_failed:
    print("结论：❌ 硬性用例未通过（%d 项），请按详情修复后重跑。" % hard_failed)
    sys.exit(1)
if skipped or soft_gap:
    print("结论：✅ 硬性用例全部通过；信息项未通过 %d 项、未触发 %d 项（多为「官网暂无新文」等外部前提）。" % (soft_gap, skipped))
else:
    print("结论：✅ 全部通过。")
PY
STATUS=$?

echo
echo "════════════════ 人工确认清单 ════════════════"
echo "  □ 未读光点消散（打开文章返回后该行光点收敛）"
echo "  □ 关注按钮「关注↔已关注」状态与 Toast 文案"
echo "  □ 列表该机构卡出现铜金铃铛角标"
echo "  □ 看图器：缩放跟手 / 1x 横滑翻页 / 页码 n/N"
echo "  □ 视频（若有）：未点播不加载、点播内联播放"
echo "  □ 消息中心出现「机构动态」筛选项与条目"
echo
echo "报告：$REPORT"
exit $STATUS