#!/usr/bin/env bash
# ==============================================================================
# 真机显示排版覆盖 · 自动化验证脚本（2026-09-29 建立）
#
# 用途：一条命令完成「真机安装 → 启动 → 日志取证 → 结构化校验 → 报告」闭环，
#       验证显示设置（字体家族/字号档/粗体/行距/字距/外观/灰度）全局覆盖。
#
# 流程：
#   1) 设备预检（devicectl 识别 UDID 且 connected）
#   2) 真机构建（xcodebuild -destination platform=iOS,id=<UDID>；含构建期四规则护栏）
#   3) 安装 App（devicectl device install app）
#   4) 启动 App（--terminate-existing，捕获启动期接管日志）
#   5) 观察窗（默认 30s；期间请现场切换字体家族/字号/粗体，并打开一篇文章）
#   6) 拉取 App 沙盒日志（Documents/SXJZIT_Cache/Logs/log_*.json）
#   7) 结构化校验（接管刷新 / 防抖跳过 / WebView 实时重注入 / 异常级别）
#   8) 生成 Markdown 报告至 qin/build/verify/
#
# 用法：
#   Scripts/device_display_verify.sh                 # 全流程（默认观察窗 30s）
#   Scripts/device_display_verify.sh --wait 90       # 观察窗 90s（现场切换字体取证）
#   Scripts/device_display_verify.sh --skip-install  # 不构建安装（Xcode 已装好），仅启动+取证
#   Scripts/device_display_verify.sh --no-launch     # 仅拉取日志并校验（不启动 App）
#   Scripts/device_display_verify.sh --tests         # 追加：真机运行 DesignCodeTests 全量单元测试
#   Scripts/device_display_verify.sh --dry-run       # 只做设备预检与计划打印（不触碰设备）
#
# 判定口径：
#   [硬性] A. 存在「系统渲染面字体接管已刷新」（导航栏/标签栏 Appearance 桥）
#   [硬性] B. display 域 ERROR/FATAL = 0
#   [信息] C. 观察窗内发生过设置切换 → 存在对应 reason 的接管刷新
#   [信息] D. 打开过 WebView 文章 → 存在「WebView 排版已实时重注入」
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
PULL_DIR="$VERIFY_DIR/device-logs-$STAMP"
REPORT="$VERIFY_DIR/device_display_verify_$STAMP.md"
SESSION_START="$(date +%s)"

WAIT_SEC=30
DO_INSTALL=1
DO_LAUNCH=1
DO_TESTS=0
DRY_RUN=0
INSTALL_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE_ID="$2"; shift 2 ;;
    --wait)         WAIT_SEC="$2"; shift 2 ;;
    --skip-install) DO_INSTALL=0; shift ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    --no-launch)    DO_LAUNCH=0; shift ;;
    --tests)        DO_TESTS=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（-h 查看用法）"; exit 2 ;;
  esac
done

info()  { printf '\033[1;36m[显示验证]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[显示验证]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[显示验证]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[显示验证]\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------ 1) 设备预检
info "设备预检：$DEVICE_ID"
if ! DEV_LINE="$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE_ID" || true)"; then :; fi
if [[ -z "$DEV_LINE" ]]; then
  fail "未找到设备 ${DEVICE_ID}。请确认：数据线已连接 / 已在设备上「信任此电脑」/ 设备已解锁。"
  exit 2
fi
echo "    $DEV_LINE"
if ! grep -q "connected" <<<"$DEV_LINE"; then
  fail "设备未处于 connected 状态（当前：$(awk '{print $NF}' <<<"$DEV_LINE")）。请解锁设备后重试。"
  exit 2
fi
ok "设备在线。"

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  info "--dry-run 计划（不执行）："
  echo "    构建：xcodebuild -project $PROJECT -scheme $SCHEME -configuration $CONFIG \\"
  echo "          -destination 'platform=iOS,id=$DEVICE_ID' -derivedDataPath $DERIVED build"
  echo "    安装：xcrun devicectl device install app --device $DEVICE_ID $APP_PATH"
  echo "    启动：xcrun devicectl device process launch --device $DEVICE_ID --terminate-existing $BUNDLE_ID"
  echo "    取证：xcrun devicectl device copy from --device $DEVICE_ID \\"
  echo "          --domain-type appDataContainer --domain-identifier $BUNDLE_ID \\"
  echo "          --source Documents/SXJZIT_Cache/Logs --destination $PULL_DIR"
  echo "    报告：$REPORT"
  [[ "$DO_TESTS" == "1" ]] && echo "    测试：xcodebuild test -destination 'platform=iOS,id=$DEVICE_ID' -only-testing:DesignCodeTests"
  exit 0
fi

# ------------------------------------------------------------------ 2) 构建 + 3) 安装
if [[ "$DO_INSTALL" == "1" ]]; then
  info "真机构建（${CONFIG}，含构建期四规则护栏）……"
  BUILD_LOG="$VERIFY_DIR/device_build_$STAMP.log"
  mkdir -p "$VERIFY_DIR"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates build \
        > "$BUILD_LOG" 2>&1; then
    fail "构建失败。完整日志：$BUILD_LOG"
    grep -E "error: |显示设置覆盖护栏|❌" "$BUILD_LOG" | tail -30 || true
    echo "    提示：若为签名问题，请确认 DEVELOPMENT_TEAM=F2JL9GNLCC 下自动签名可用（Xcode 打开工程一次即可刷新）。"
    exit 1
  fi
  if ! grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
    fail "构建未产出 SUCCEEDED 标记，请查看 $BUILD_LOG"; exit 1
  fi
  ok "构建通过（日志：${BUILD_LOG}）"

  [[ -d "$APP_PATH" ]] || { fail "未找到产物：$APP_PATH"; exit 1; }
  info "安装到设备……"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" | tail -5 || {
    fail "安装失败（常见原因：设备锁定 / 信任失效 / 描述文件过期）。"; exit 1; }
  ok "安装完成。"
fi

if [[ "$INSTALL_ONLY" == "1" ]]; then
  ok "阶段一完成（--install-only）：已构建并安装最新构建；跳过启动与取证。"
  echo "    下一步：在手机上完成显示设置切换与文章浏览后，运行："
  echo "      $0 --skip-install --no-launch"
  exit 0
fi

# ------------------------------------------------------------------ 4) 启动 + 5) 观察窗
if [[ "$DO_LAUNCH" == "1" ]]; then
  info "启动 App（--terminate-existing，捕获启动期接管日志）……"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" >/dev/null || {
    fail "启动失败：${BUNDLE_ID}（App 未安装？可去掉 --skip-install 重跑）。"; exit 1; }
  echo
  echo "  ── 观察窗 ${WAIT_SEC}s：请在 iPhone 上完成以下动作（用于取证）──"
  echo "  1. 设置 → 显示设置 → 文字排版：切换 1 次字体家族、1 次字号档、开关 1 次粗体"
  echo "  2. 观察导航栏标题 / 底部标签栏 / 设置页所有行 是否即时变化"
  echo "  3. 打开任一文章详情（新闻或机构设置文章，验证 WebView 实时重注入）"
  echo "  4. 返回本终端等待计时结束"
  echo
  for ((i = WAIT_SEC; i > 0; i--)); do printf "\r  剩余 %2ds …" "$i"; sleep 1; done
  printf "\r  观察窗结束。      \n"
fi

# ------------------------------------------------------------------ 6) 拉取日志
mkdir -p "$PULL_DIR"
info "拉取 App 沙盒日志 → $PULL_DIR"
if ! xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/SXJZIT_Cache/Logs" --destination "$PULL_DIR" > /dev/null 2>&1; then
  fail "日志拉取失败。可能原因：App 尚未运行过（日志目录未生成）/ 设备锁定。"
  exit 1
fi
LOG_COUNT="$(find "$PULL_DIR" -name 'log_*.json' | wc -l | tr -d ' ')"
info "已获取日志文件：$LOG_COUNT 个"

# ------------------------------------------------------------------ 7) 结构化校验 + 8) 报告
python3 - "$PULL_DIR" "$REPORT" "$SESSION_START" "$DEVICE_ID" "$BUNDLE_ID" "$DO_LAUNCH" <<'PY'
# -*- coding: utf-8 -*-
"""真机日志结构化校验：显示排版覆盖取证（display_baretext_audit 的运行时对偶）"""
import datetime
import glob
import json
import os
import sys

logdir, report_path, since, device_id, bundle_id, launched = sys.argv[1:7]
since = float(since)
launched = launched == "1"
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
# 关键：日志文件按「最新在前」落盘 → 必须先按时间升序排序，否则"最近一次"会取到最旧记录（2026-09-29 修正）
entries.sort(key=lambda e: e["_ts"])

# 拉取窗口 = 本次拉回的全部条目（App 单日日志上限 1000 条 → 文件即天然"最近窗口"；
# 高活跃约 3 分钟写满，故操作完成后应尽快拉取）
session = entries
_launch_marks = [e["_ts"] for e in entries if e.get("message") == "显示设置初始化完成"]
last_launch = max(_launch_marks) if _launch_marks else None
display_all = [e for e in entries if e.get("module") == "display"]
display_sess = [e for e in session if e.get("module") == "display"]
refresh = [e for e in session if e.get("message") == "系统渲染面字体接管已刷新"]
debounce = [e for e in session if e.get("message") == "系统渲染面字体无变化，跳过重刷"]
latepass = [e for e in session if e.get("message") == "系统渲染面字体延迟补刷完成"]
webview = [e for e in session if e.get("message") == "WebView 排版已实时重注入"]
issues_all = [e for e in session if str(e.get("level")) in ("WARNING", "ERROR", "FATAL")]
issues_display = [e for e in session if e.get("module") == "display" and str(e.get("level")) in ("WARNING", "ERROR", "FATAL")]
hard = [e for e in session if e.get("module") == "display" and str(e.get("level")) in ("ERROR", "FATAL")]

switch_refresh = [e for e in refresh if (e.get("context") or {}).get("reason", "startup") != "startup"]

checks = []  # (硬性?, 名称, 通过?, 详情)


def add(hard_check, name, passed, detail):
    checks.append((hard_check, name, passed, detail))


add(True, "日志文件可解析", len(entries) > 0 and bad_files == 0,
    "文件 %d 个，条目 %d 条（损坏文件 %d）" % (len(glob.glob(os.path.join(logdir, "**", "log_*.json"), recursive=True)), len(entries), bad_files))
refresh_all = [e for e in display_all if e.get("message") == "系统渲染面字体接管已刷新"]
if refresh:
    _rc = refresh[-1].get("context") or {}
    _a_detail = "拉取窗口内 %d 条；最近一条 reason=%s family=%s navBars=%s tabBars=%s" % (
        len(refresh), _rc.get("reason", "-"), _rc.get("family", "-"), _rc.get("navBars", "-"), _rc.get("tabBars", "-"))
else:
    _a_detail = "拉取窗口内 0 条（日志单日上限 1000 条，可能已被写满挤出；请在操作完成后 1~2 分钟内拉取）"
add(True, "Appearance 桥接管刷新（导航栏/标签栏）", len(refresh) > 0, _a_detail)
# 接管字体回退检测（2026-09-29 真机日志驱动新增）：family 非 system 却落到系统字体（.SFUI-* 形式）
# → 说明字体资产未就绪/映射失败，导航栏/标签栏停留在系统字体（旧版签名门控曾误判「无变化」跳过重刷）
_last = (refresh[-1] if refresh else (refresh_all[-1] if refresh_all else None))
if _last:
    _c = _last.get("context") or {}
    _fam, _tf = _c.get("family", "system"), _c.get("titleFont", "")
    _fallback = _fam not in ("system", "") and _tf.startswith(".")
    add(True, "接管字体为目标家族（非系统回退）", not _fallback,
        "最近一次刷新：family=%s titleFont=%s" % (_fam, _tf or "-"))
else:
    add(True, "接管字体为目标家族（非系统回退）", False, "无任何接管刷新记录可判定")
add(False, "现场切换生效（非启动触发）", len(switch_refresh) > 0,
    "切换触发刷新 %d 条（防抖跳过 %d 条）" % (len(switch_refresh), len(debounce)))
add(False, "WebView 文章实时重注入", len(webview) > 0,
    "拉取窗口内 %d 条" % len(webview))
add(True, "display 域无 ERROR/FATAL", len(hard) == 0,
    "display 域异常 %d 条（其中 ERROR/FATAL %d 条）；其它域异常 %d 条（信息性，不参与判定）" % (len(issues_display), len(hard), len(issues_all)))

lines = []
lines.append("# 真机显示排版覆盖 · 自动化验证报告")
lines.append("")
lines.append("- 设备：`%s`" % device_id)
lines.append("- Bundle：`%s`" % bundle_id)
lines.append("- 拉取窗口：%s → %s（%d 条）" % (fmt(entries[0]["_ts"]), fmt(entries[-1]["_ts"]), len(entries)))
if last_launch:
    lines.append("- 最近一次 App 启动（日志标记）：%s" % datetime.datetime.fromtimestamp(last_launch).strftime("%H:%M:%S"))
lines.append("- 日志目录：`%s`（%d 个文件 / %d 条）" % (logdir, len(glob.glob(os.path.join(logdir, "**", "log_*.json"), recursive=True)), len(entries)))
lines.append("")
lines.append("## 校验结果")
lines.append("")
lines.append("| 类型 | 项 | 结果 | 详情 |")
lines.append("|---|---|---|---|")
for hard_check, name, passed, detail in checks:
    kind = "硬性" if hard_check else "信息"
    mark = "✅" if passed else ("❌" if hard_check else "⚠️ 未触发")
    lines.append("| %s | %s | %s | %s |" % (kind, name, mark, detail))

lines.append("")
lines.append("## 接管刷新明细（最近 10 条%s）" % ("" if launched else "；考古模式取历史"))
lines.append("")
lines.append("| 时间 | reason | family | scale | bold | navBars | tabBars | titleFont |")
lines.append("|---|---|---|---|---|---|---|---|")
for e in (refresh[-10:] if launched else refresh_all[-10:]):
    c = e.get("context") or {}
    lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
        fmt(e["_ts"]), c.get("reason", "-"), c.get("family", "-"), c.get("scale", "-"),
        c.get("bold", "-"), c.get("navBars", "-"), c.get("tabBars", "-"), c.get("titleFont", "-")))

if display_sess:
    lines.append("")
    lines.append("## display 域时间线（本次会话，最近 20 条）")
    lines.append("")
    for e in display_sess[-20:]:
        c = e.get("context") or {}
        brief = " ".join("%s=%s" % (k, v) for k, v in list(c.items())[:4])
        lines.append("- `%s` [%s] %s  %s" % (fmt(e["_ts"]), e.get("level"), e.get("message"), brief))

if issues_display or issues_all:
    lines.append("")
    lines.append("## 会话内异常级别条目（display 域优先；最多 20 条）")
    lines.append("")
    for e in (issues_display + [x for x in issues_all if x not in issues_display])[:20]:
        lines.append("- `%s` [%s|%s] %s" % (fmt(e["_ts"]), e.get("level"), e.get("module"), e.get("message")))

open(report_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")

print("")
print("════════════════ 校验结果 ════════════════")
hard_failed = 0
for hard_check, name, passed, detail in checks:
    mark = "✅" if passed else ("❌" if hard_check else "⚠️ ")
    if not passed and hard_check:
        hard_failed += 1
    print("%s %s —— %s" % (mark, name, detail))

print("")
print("报告：%s" % report_path)
if hard_failed:
    print("结论：❌ 硬性项未通过（%d 项），请修复后重跑。" % hard_failed)
    sys.exit(1)
if not switch_refresh or not webview:
    print("结论：✅ 硬性项全通过；信息项有未触发项 ⚠️——如需完整取证，请在 --wait 观察窗内切换字体/字号/粗体并打开一篇文章后重跑。")
else:
    print("结论：✅ 全部通过（含现场切换与 WebView 实时重注入取证）。")
PY
VERIFY_EXIT=$?

# ------------------------------------------------------------------ 9) 可选：真机单元测试
if [[ "$DO_TESTS" == "1" ]]; then
  echo
  info "真机运行 DesignCodeTests 全量单元测试……"
  TEST_LOG="$VERIFY_DIR/device_tests_$STAMP.log"
  xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
      -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates \
      -only-testing:DesignCodeTests > "$TEST_LOG" 2>&1 || true
  SUMMARY="$(grep -E "Executed [0-9]+ tests" "$TEST_LOG" | tail -1 || true)"
  if grep -q "TEST SUCCEEDED" "$TEST_LOG"; then
    ok "单元测试通过：${SUMMARY:-见日志}"
  else
    fail "单元测试失败：${SUMMARY:-见日志}（完整日志：${TEST_LOG}）"
    grep -E "error: |failed|XCTAssert" "$TEST_LOG" | tail -20 || true
    VERIFY_EXIT=1
  fi
fi

exit "$VERIFY_EXIT"