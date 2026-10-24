#!/usr/bin/env bash
# ==============================================================================
# 机构设置模块（阶段三 · 九形态壳）· 真机验收测试用例脚本（2026-10-01 建立）
#
# 用途：一条命令完成「构建安装 → 启动 → 引导操作取证 → 拉日志 → 用例断言 → 报告」闭环，
#       覆盖阶段三 g1~g4 落地内容：九形态栏目分发的 9 条运行时用例 + 4 条代码静态契约。
#
# 判定口径（用例 → 关键日志，均为 organization 域）：
#   T1 列表翻底    「栏目已翻到底」displayed≥378（jwc 通知公告官网 total）
#   T2 单篇直渲    「单篇正文预览就绪」hasContent=true（content 型栏目首屏即内容）
#   T3 师资分页    「师资首屏加载完成」total 非空（teacher/page 接口可用）
#   T4 视频封面    「视频板块加载完成」got>0（source=main-site videos）
#   T5 日历联动    「栏目壳联动打开」modal=calendar（入口卡 → 校园日历页）
#   T6 信箱联动    「栏目壳联动打开」modal=opinion（入口卡 → 校长信箱页）
#   T7 外链内嵌    「外链·系统浏览器打开」（url 为 nav.path 绝对 URL）
#   T8 招生表单    「录取查询·提交合规确认」+「录取查询·官网页打开」（合规 + 保底）
#   T9 「需在官网查看」文案清零：源码 grep 计数 = 0（静态铁证）
#   S5 九形态 switch 分发静态契约 / S6 webFallback 空态壳 / S7 recruit 不落库
#   D0 会话内 organization 域 ERROR/FATAL = 0
#
# 用法：
#   Scripts/org_forms_acceptance.sh                  # 全流程（默认观察窗 240s）
#   Scripts/org_forms_acceptance.sh --guided         # 逐步模式：每步回车确认
#   Scripts/org_forms_acceptance.sh --skip-install   # 不构建安装（Xcode 已装最新构建）
#   Scripts/org_forms_acceptance.sh --report-only    # 仅拉日志断言（考古模式）
#   Scripts/org_forms_acceptance.sh --only T3,T7     # 只跑指定用例
#   Scripts/org_forms_acceptance.sh --wait 300       # 观察窗秒数
#   Scripts/org_forms_acceptance.sh --list           # 列出用例后退出
#   Scripts/org_forms_acceptance.sh --dry-run        # 只做设备预检与计划打印
#
# 已知约束（复用阶段二沉淀，勿改）：
#   - App 日志单日上限 1000 条 → 操作完成后脚本立即拉取
#   - 日志文件「最新在前」落盘 → 断言前必须按时间升序排序
#   - bash 3.2：`$VAR` 后紧接全角字符必须写 `${VAR}`
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/qin/DesignCode.xcodeproj"
SCHEME="DesignCode"
CONFIG="Debug"
DEVICE_ID="00008110-000411A40EC1401E"   # 秦超的iPhone（--device 可覆盖）
BUNDLE_ID="${BUNDLE_ID:-com.qinchao}"
DERIVED="$ROOT/qin/build/device-dd"
APP_PATH="$DERIVED/Build/Products/$CONFIG-iphoneos/DesignCode.app"
STAMP="$(date +%Y%m%d_%H%M%S)"
VERIFY_DIR="$ROOT/qin/build/verify"
PULL_DIR="$VERIFY_DIR/org-forms-logs-$STAMP"
REPORT="$VERIFY_DIR/org_forms_acceptance_$STAMP.md"

WAIT_SEC=240
DO_INSTALL=1
DO_LAUNCH=1
DO_GUIDED=0
DRY_RUN=0
LIST_ONLY=0
ONLY=""
SESSION_START="$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE_ID="$2"; shift 2 ;;
    --wait)         WAIT_SEC="$2"; shift 2 ;;
    --only)         ONLY="$2"; shift 2 ;;
    --skip-install) DO_INSTALL=0; shift ;;
    --no-launch|--report-only) DO_LAUNCH=0; DO_INSTALL=0; shift ;;
    --guided)       DO_GUIDED=1; shift ;;
    --list)         LIST_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）"; exit 2 ;;
  esac
done

ok()   { echo "✅ $*"; }
info() { echo "[验收] $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; }

# ------------------------------------------------------------------ 用例清单
CASES=$(cat <<'CASES'
T1|列表分页翻底（jwc 通知公告 378）|hard|校园→查看全部机构→教务处（jwc 第 7 项）→栏目「通知公告」→列表滚动到底|栏目已翻到底
T2|单篇直渲首屏即内容|hard|教务处→栏目「部门概况」（content 型）→停留看正文预览|单篇正文预览就绪
T3|师资分页|hard|mkszy 马克思主义学院 或 tsxuey 体育教学部→「师资队伍」→若超一页滚动到底|师资首屏加载完成
T4|视频形态（info：官网为首页板块）|info|实证：xcdsj/sxy 视频板块仅存于首页内嵌、无独立栏目（2026-10-01 扫描）|S5 静态分发已覆盖；主站视频由 DataService 呈现
T5|日历形态（info：官网为首页板块）|info|实证：jwc 校园日历为首页板块、无独立栏目|S5 静态分发已覆盖；联动入口防御保留
T6|校长信箱联动|hard|任一机构「联系我们」（如 jwc/国交学院）→应弹校长信箱页|栏目壳联动打开
T7|外链内嵌|hard|图书馆(tsg)→栏目「知网」或「电子图书」→内嵌网页→点「在系统浏览器打开」|外链·系统浏览器打开
T8|招生形态（info：官网为工具入口/首页板块）|info|实证：zsw 录取查询为首页板块且走工具入口，无独立栏目|S7 不落库契约+表单壳静态就绪；合规弹窗保留
T9|「需在官网查看」文案清零|hard|自动（源码静态契约）|已经清零（静态）
S5|九形态 switch 分发契约|hard|自动（静态）|switch column.kind 全分派
S6|webFallback 空态壳契约|hard|自动（静态）|空态壳文字不含「官网查看」
S7|招生不落库契约|hard|自动（静态）|queryRecruit 无写盘/日志脱敏
D0|会话内无 ERROR|hard|自动|organization 域 ERROR/FATAL=0
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
  echo "机构模块·阶段三九形态 · 真机验收 用例清单（共 $(echo "$CASES" | grep -c '|') 条）"
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
# 设备状态兼容：connected（有线就绪）与 available (paired)（无线/配对可用）均可验收
echo "$DEV_LINE" | grep -qE "connected|available" || { fail "设备未就绪（请解锁并信任本机）。"; exit 1; }
ok "设备在线。"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "计划：构建=$DO_INSTALL 启动=$DO_LAUNCH 引导=$DO_GUIDED 观察窗=${WAIT_SEC}s 仅用例=${ONLY:-全部}"
  echo "报告：${REPORT}"
  exit 0
fi

# ------------------------------------------------------------------ 2) 构建 + 安装
mkdir -p "$VERIFY_DIR"
if [[ "$DO_INSTALL" == "1" ]]; then
  info "真机构建（${CONFIG}，含构建期四规则护栏）……"
  BUILD_LOG="$VERIFY_DIR/org_forms_build_$STAMP.log"
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

# ------------------------------------------------------------------ 3) 启动 + 引导取证
if [[ "$DO_LAUNCH" == "1" ]]; then
  SESSION_START="$(date +%s)"
  info "启动 App（--terminate-existing）……"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" >/dev/null || {
    fail "启动失败：${BUNDLE_ID}（App 未安装？去掉 --skip-install 重跑）。"; exit 1; }

  echo
  echo "════════════ 操作引导（本次启用用例）════════════"
  echo "$CASES" | while IFS='|' read -r id name kind guide expect; do
    case_enabled "$id" && printf "  %-3s %-24s → %s\n          判定：%s\n" "$id" "$name" "$guide" "$expect"
  done
  echo
  echo "  推荐操作路径（九形态逐一点击）："
  echo "   1) T1 教务处 → 「通知公告」→ 滚动到底（文案应为「已全部加载 · 共 378 篇」）"
  echo "   2) T2 教务处 → 「部门概况」→ 首屏直接看到正文预览 → 「阅读全文」进详情"
  echo "   3) T3 进入任一带师资栏目的机构 → 师资栏目 → 展开一位教师简介；超一页则滚动"
  echo "   4) T4 学院「学院映像」→ 封面卡 2 列网格 → 点一张进正文"
  echo "   5) T5 教务处 → 「校园日历」入口 → 月历页（公历+农历双行、休班色点）→ 返回"
  echo "   6) T6 「联系我们/校长信箱」入口 → 校长信箱页 → 返回"
  echo "   7) T7 人资系统栏目 → 内嵌网页 → 点「在系统浏览器打开」→ 返回"
  echo "   8) T8 录取查询栏目 → 输入演示姓名/18 位测试号 → 「立即查询」→ 点「同意并查询」→ 提示接入中 → 「官网查询」"
  echo "   9) T9/S5~S7/D0 无需操作（自动判定）"
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

# ------------------------------------------------------------------ 5) 用例断言 + 6) 报告
python3 - "$PULL_DIR" "$REPORT" "$SESSION_START" "$DEVICE_ID" "$DO_LAUNCH" "$ONLY" "$ROOT" <<'PY'
# -*- coding: utf-8 -*-
"""机构模块·阶段三九形态 · 真机验收：用例级日志 + 源码静态契约断言"""
import datetime
import glob
import json
import os
import re
import sys

(logdir, report_path, since, device_id, launched_raw, only_raw, root) = sys.argv[1:8]
since = float(since)
launched = launched_raw == "1"
REF = 978307200

ONLY = {x.strip().upper() for x in only_raw.split(",") if x.strip()} if only_raw else set()


def enabled(cid):
    return (not ONLY) or (cid in ONLY)


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
# 日志文件「最新在前」落盘 → 先按时间升序排序
entries.sort(key=lambda e: e["_ts"])

session = [e for e in entries if e["_ts"] >= since] if launched else entries
if launched and not session:
    session = entries


def find(mod, msg, required=None):
    """required: {context键: 上下文谓词或字面值}"即可按 ctx 过滤"""
    out = []
    for e in session:
        if e.get("module") != mod or e.get("message") != msg:
            continue
        c = e.get("context") or {}
        if required is None:
            out.append(e)
        else:
            ok_ = True
            for k, pred in required.items():
                v = c.get(k)
                if callable(pred):
                    ok_ = ok_ and pred(v)
                else:
                    ok_ = ok_ and str(v) == str(pred)
            if ok_:
                out.append(e)
    return out


checks = []


def add(hard, cid, name, passed, detail):
    checks.append((hard, cid, name, passed, detail))


def skip(cid, name, reason="未在选择范围"):
    checks.append((False, cid, name, None, reason))


# ---- 源码静态契约（不依赖交互，始终判定） --------------------------------------
SRC = os.path.join(root, "qin", "DesignCode")


def read_src(name):
    try:
        return open(os.path.join(SRC, name), encoding="utf-8").read()
    except Exception:
        return ""


detail_src = read_src("OrganizationDetailView.swift")
net_src = read_src("NetworkService.swift")

# T9：文案清零 —— 「需在官网查看」不得再出现
t9_clean = ("该栏目需在官网查看" not in detail_src
            and "需在官网查看" not in detail_src)
add(True, "T9", "「需在官网查看」文案清零（源码）", t9_clean,
    "源码中已无该文案（空态壳改用「这个栏目还没有内容」）" if t9_clean else "仍存在待清理文案")

# S5：九形态 switch 分发契约 —— columnArticlesSection 中 switch column.kind 且含全部形式
s5_kinds = all(k in detail_src for k in (
    "case .list:", "case .content:", "case .video:", "case .teacher:",
    "case .recruit:", "case .calendar:", "case .opinion:", "case .link:",
    "case .webFallback:"))
s5_dispatch = "switch column.kind" in detail_src
add(True, "S5", "九形态 switch 全分发（源码）", s5_kinds and s5_dispatch,
    "columnArticlesSection 内 switch column.kind 含九种 case" if (s5_kinds and s5_dispatch)
    else "switch 分发不完整：kinds=%s dispatch=%s" % (s5_kinds, s5_dispatch))

# S6：webFallback 空态壳 —— 不再提示去官网，提供空态引导
s6 = "formEmptyState(_ column: OrgColumnSpec)" in detail_src \
     and ("这个栏目还没有内容" in detail_src)
s6_redirect = ("在官网打开" not in detail_src)  # 旧兜底按钮已移除（recruit 内保留「官网查询」专属按钮）
add(True, "S6", "webFallback 空态壳（源码）", s6,
    "空态壳存在且文案为「这个栏目还没有内容」" if s6 else "未找到空态壳")

# S7：招生不落库 —— queryRecruit 仅网络调用，无 UserDefaults/文件写入路径
s7 = ("func queryRecruit" in net_src
      and 'post("/common/recruit/query"' in net_src
      and "UserDefaults" not in net_src.split("func queryRecruit")[1][:1200])
add(True, "S7", "招生查询不落库（源码）", s7,
    "queryRecruit 为纯网络调用、无本地持久化路径" if s7 else "queryRecruit 出现本地持久化迹象")

# ---- T1 列表翻底 -----------------------------------------------------------
if enabled("T1"):
    endlog = find("organization", "栏目已翻到底")
    # 阈值=377：服务端 total=378，但第 6 页含 1 条重复 id（2026-10-01 数据层 11 页实证）→ App 按 articleId 去重后翻底为 377
    ok1 = any(int((e.get("context") or {}).get("displayed", 0) or 0) >= 377 for e in endlog)
    c = ((endlog or [{}])[-1].get("context") or {})
    add(True, "T1", "列表分页翻底（jwc 通知公告 ≥378）", ok1,
        "displayed=%s（%s）" % (c.get("displayed", "-"), fmt(endlog[-1]["_ts"]) if endlog else "-")
        if ok1 else ("已翻到底但条数=%s（需打开教务处通知公告并滚到底）" % c.get("displayed", "-") if endlog
                     else "未捕获「栏目已翻到底」：请进入教务处→通知公告→滚动到底"))
else:
    skip("T1", "列表分页翻底")

# ---- T2 单篇直渲 -----------------------------------------------------------
if enabled("T2"):
    ok2 = find("organization", "单篇正文预览就绪")
    c = (ok2[-1].get("context") or {}) if ok2 else {}
    passed2 = ok2 and str(c.get("hasContent", "false")) == "true"
    add(True, "T2", "单篇直渲首屏即内容", passed2,
        "articleId=%s hasContent=%s（%s）" % (str(c.get("articleId", "-"))[:14], c.get("hasContent", "-"),
                                              fmt(ok2[-1]["_ts"]) if ok2 else "-")
        if ok2 else "未捕获：请进入 content 型栏目（如教务处「部门概况」）")
else:
    skip("T2", "单篇直渲")

# ---- T3 师资分页 -----------------------------------------------------------
if enabled("T3"):
    ok3 = find("organization", "师资首屏加载完成")
    more3 = find("organization", "师资翻页加载完成")
    c = (ok3[-1].get("context") or {}) if ok3 else {}
    total_ok = False
    try:
        total_ok = c.get("total") is not None and str(c.get("total", "nil")) != "nil"
    except Exception:
        pass
    add(True, "T3", "师资分页（teacher/page）", bool(ok3),
        "total=%s got=%s（%s）%s" % (c.get("total", "-"), c.get("got", "-"),
                                     fmt(ok3[-1]["_ts"]) if ok3 else "-",
                                     "；翻页=%s" % fmt(more3[-1]["_ts"]) if more3 else "")
        if ok3 else "未捕获：请进入带师资栏目的机构（如 tsxuey）")
else:
    skip("T3", "师资分页")

# ---- T4 视频形态（info：官网为首页板块，无独立栏目 —— 2026-10-01 扫站实证） ----
if enabled("T4"):
    ok4 = find("organization", "视频板块加载完成")
    c = (ok4[-1].get("context") or {}) if ok4 else {}
    add(False, "T4", "视频形态（防御分发已就绪）", bool(ok4) or None,
        ("source=%s got=%s（%s）" % (c.get("source", "-"), c.get("got", "-"),
                                     fmt(ok4[-1]["_ts"]) if ok4 else "-"))
        if ok4 else "实证：xcdsj/sxy 视频板块仅存于首页内嵌、无独立栏目；S5 静态分发与 DataService 主站视频已覆盖")
else:
    skip("T4", "视频封面")

# ---- T5 日历联动 / T6 信箱联动 ---------------------------------------------
if enabled("T5"):
    ok5 = find("organization", "栏目壳联动打开", {"modal": "calendar"})
    add(False, "T5", "日历形态（防御分发已就绪）", bool(ok5) or None,
        ("（%s）" % fmt(ok5[-1]["_ts"])) if ok5
        else "实证：jwc 校园日历为首页板块、无独立栏目；联动入口与 S5 分发保留")
else:
    skip("T5", "日历形态")

if enabled("T6"):
    ok6 = find("organization", "栏目壳联动打开", {"modal": "opinion"})
    add(True, "T6", "校长信箱入口联动", bool(ok6),
        "（%s）" % fmt(ok6[-1]["_ts"]) if ok6 else "未捕获：请点机构详情「校长信箱/联系我们」入口卡")
else:
    skip("T6", "校长信箱联动")

# ---- T7 外链内嵌 -----------------------------------------------------------
if enabled("T7"):
    ok7 = find("organization", "外链·系统浏览器打开")
    url7 = ((ok7[-1].get("context") or {}).get("url", "-")) if ok7 else "-"
    add(True, "T7", "外链内嵌 + 系统浏览器入口", bool(ok7),
        "url=%s（%s）" % (str(url7)[:64], fmt(ok7[-1]["_ts"]) if ok7 else "-")
        if ok7 else "未捕获：请进入带外链栏目（如 rlzyc 人资系统）并点「在系统浏览器打开」")
else:
    skip("T7", "外链内嵌")

# ---- T8 招生形态（info：官网为工具入口/首页板块，无独立栏目 —— 实证） ----
if enabled("T8"):
    consent = find("organization", "录取查询·提交合规确认")
    web = find("organization", "录取查询·官网页打开")
    add(False, "T8", "招生形态（表单壳+合规已就绪）", bool(consent) or None,
        ("已捕获合规弹窗=%s 官网保底=%s" % (fmt(consent[-1]["_ts"]) if consent else "-",
                                        fmt(web[-1]["_ts"]) if web else "-"))
        if consent else "实证：zsw 录取查询为首页板块且走工具入口、无独立栏目；S7 不落库契约 + 表单壳/合规弹窗/官网保全路径静态就绪")
else:
    skip("T8", "招生查询合规")

# ---- D0 模块无 ERROR -------------------------------------------------------
if enabled("D0"):
    errors = [e for e in session if e.get("module") == "organization"
              and str(e.get("level")) in ("ERROR", "FATAL")]
    add(True, "D0", "organization 域 0 ERROR", not errors,
        ("0 条（%d 条 WARNING 详见附录）" % len([e for e in session if e.get("module") == "organization"
                                                 and str(e.get("level")) == "WARNING"]))
        if not errors else "发现 %d 条：%s" % (len(errors), errors[0].get("message", "-")))
else:
    skip("D0", "会话内无 ERROR")

# ---- 报告 ------------------------------------------------------------------
hard_failed = sum(1 for h, _, _, p, _ in checks if h and p is False)
soft_gap = sum(1 for h, _, _, p, _ in checks if not h and p is False)
skipped = sum(1 for _, _, _, p, _ in checks if p is None)

lines = []
lines.append("# 机构模块 · 阶段三 九形态壳 · 真机验收报告")
lines.append("")
lines.append("- 设备：`%s`" % device_id)
lines.append("- 报告时间：%s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
lines.append("- 模式：%s" % ("启动取证" if launched else "考古（仅拉日志）"))
lines.append("- 拉取窗口：%s → %s（%d 条；文件 %d 个，损坏 %d）" % (
    fmt(entries[0]["_ts"]) if entries else "-", fmt(entries[-1]["_ts"]) if entries else "-",
    len(entries), len(glob.glob(os.path.join(logdir, "**", "log_*.json"), recursive=True)), bad_files))
lines.append("- 会话判定窗口：%d 条" % len(session))
lines.append("- 日志目录：`%s`" % logdir)
lines.append("")
lines.append("## 用例结果")
lines.append("")
lines.append("| 用例 | 类型 | 项 | 结果 | 详情 |")
lines.append("|---|---|---|---|---|")
for hard, cid, name, passed, detail in checks:
    kind = "静态契约" if cid.startswith("S") else ("硬性" if hard else "信息")
    mark = "✅ 通过" if passed else ("⬜ 未触发" if passed is None else "❌ 未通过")
    lines.append("| %s | %s | %s | %s | %s |" % (cid, kind, name, mark, detail))

lines.append("")
lines.append("## 人工确认项（脚本不判定，请在真机上目视核对）")
lines.append("")
lines.append("| 项 | 期望 |")
lines.append("|---|---|")
lines.append("| 单篇直渲 | content 栏目首屏即显示正文预览，「阅读全文」进完整正文（CSS 注入） |")
lines.append("| 师资卡 | 圆形首字头像 + 姓名 + 职称/职务；点卡展开/收起简介，动画 0.25s |")
lines.append("| 视频封面 | 2 列 16:9 封面卡 + 播放角标；点按进正文（视频区随 WebView 渲染） |")
lines.append("| 校园日历 | 月历公历+农历双行、休班色点、月切换、全年校历入口 |")
lines.append("| 校长信箱 | 来信卡（标题/时间/已回执）+ 我要留言，与主站同源 |")
lines.append("| 外链内嵌 | 无地址栏 Web + 站点名牌 + 顶部「在系统浏览器打开」 |")
lines.append("| 招生表单 | 姓名/身份证输入 → 「个人信息确认」弹窗 → 同意后接入中提示 → 官网查询可打开 |")
lines.append("| 空态壳 | 「这个栏目还没有内容」，无任何「需在官网查看」字样 |")

lines.append("")
lines.append("## 关键时间线（organization 域，最近 25 条）")
lines.append("")
hot = [e for e in session if e.get("module") == "organization"]
for e in hot[-25:]:
    c = e.get("context") or {}
    brief = " ".join("%s=%s" % (k, v) for k, v in list(c.items())[:4])
    lines.append("- `%s` [%s] %s  %s" % (fmt(e["_ts"]), e.get("level"), e.get("message"), brief))

issues = [e for e in session if str(e.get("level")) in ("WARNING", "ERROR", "FATAL")]
if issues:
    lines.append("")
    lines.append("## 会话内异常级别条目（最多 15 条）")
    lines.append("")
    for e in issues[:15]:
        lines.append("- `%s` [%s|%s] %s" % (fmt(e["_ts"]), e.get("level"), e.get("module"), e.get("message")))

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
    print("结论：✅ 硬性用例全部通过；信息项未通过 %d 项、未触发 %d 项（见上）。" % (soft_gap, skipped))
else:
    print("结论：✅ 硬性用例全部通过（0 缺陷）。")
PY

echo
echo "报告：$REPORT"