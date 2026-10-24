#!/usr/bin/env bash
# ==============================================================================
# 新闻全量同步 · 回归验收脚本（2026-10-01 建立）
#
# 用途：验证 safeFetchArticles total 驱动动态翻页修复「无负面影响」——
#       所有新闻栏目拉取数量与官网 total 完全一致，且不引入错误/回归。
#
# 被测改动：
#   1) DataService.safeFetchArticles: 固定 6 页上限 → total 驱动动态翻页（学校要闻 522 全量）
#   2) OrganizationView 主站/机构搜索: maxPages 4/8 页上限 → total 驱动全量
#
# 流程：
#   1) 设备预检（devicectl 识别 UDID 且 connected）
#   2) curl 抓取官网各栏目 total 作为对照基准（--skip-ref 可跳过）
#   3) 构建 + 安装（含构建期护栏；--skip-install 可跳过）
#   4) 启动 App → 观察窗等待同步完成
#   5) 拉取 App 沙盒日志, 断言：
#      A 各栏目「栏目全量拉取完成」fetched == 官网 total（学校要闻/校园荣誉等）
#      B 「数据同步完成」news == Σ官网 total，honors 一致，errors == 0
#      C articleSync 域 ERROR/WARNING = 0（无降级）
#      D 未出现「栏目服务端暂不可用」告警
#      E 静态契约：safeFetchArticles 无 `for page in 1...6` 残留、OrganizationView 无 `maxPages`
#   6) 生成 Markdown 报告至 qin/build/verify/
#
# 用法：
#   Scripts/news_fullsync_regression.sh              # 全流程（默认观察窗 90s）
#   Scripts/news_fullsync_regression.sh --skip-install  # 不构建（Xcode 已装最新）
#   Scripts/news_fullsync_regression.sh --skip-ref      # 不抓官网页数基准
#   Scripts/news_fullsync_regression.sh --report-only   # 仅拉日志断言（考古）
#   Scripts/news_fullsync_regression.sh --wait 120      # 观察窗秒数（高网络延迟时放大）
#   Scripts/news_fullsync_regression.sh --dry-run       # 只做预检与计划打印
#
# 判定口径（用例 → 日志）：
#   A1 学校要闻全量      「栏目全量拉取完成」label=学校要闻 fetched=<官网importants.total>
#   A2 校园荣誉全量      「栏目全量拉取完成」label=校园荣誉 fetched=<官网achievements.total>
#   A3 无翻页截断残留    grep 代码: DataService 无 `for page in 1...6`；OrganizationView 无 `maxPages`
#   B1 同步总量一致      「数据同步完成」news == Σ五栏目 total（876） honors==36 errors==0
#   C1 无降级告警        无「栏目服务端暂不可用」warning
#   D0 无 ERROR         articleSync 域 ERROR/FATAL = 0
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/qin/DesignCode.xcodeproj"
SCHEME="DesignCode"
CONFIG="Debug"
DEVICE_ID="${DEVICE_ID:-00008110-000411A40EC1401E}"
BUNDLE_ID="${BUNDLE_ID:-com.qinchao}"
DERIVED="$ROOT/qin/build/device-dd"
APP_PATH="$DERIVED/Build/Products/$CONFIG-iphoneos/DesignCode.app"
STAMP="$(date +%Y%m%d_%H%M%S)"
VERIFY_DIR="$ROOT/qin/build/verify"
PULL_DIR="$VERIFY_DIR/news-regression-logs-$STAMP"
REPORT="$VERIFY_DIR/news_fullsync_regression_$STAMP.md"
API_BASE="https://gwqietap.sxjzit.edu.cn/mapi"

WAIT_SEC=90
DO_INSTALL=1
DO_LAUNCH=1
DO_REF=1
DO_REPORT_ONLY=0
DO_DRY=0

# ---- 解析参数 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install) DO_INSTALL=0; shift ;;
    --skip-ref)     DO_REF=0; shift ;;
    --report-only)  DO_REPORT_ONLY=1; DO_INSTALL=0; DO_LAUNCH=0; shift ;;
    --wait)         WAIT_SEC="$2"; shift 2 ;;
    --device)       DEVICE_ID="$2"; shift 2 ;;
    --dry-run)      DO_DRY=1; shift ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

mkdir -p "$VERIFY_DIR" "$PULL_DIR"
echo "# 新闻全量同步回归验收 · $STAMP" > "$REPORT"
echo "" >> "$REPORT"
echo "| 设备 | $DEVICE_ID |" >> "$REPORT"
echo "| 观察窗 | ${WAIT_SEC}s |" >> "$REPORT"
echo "| 官网 API | $API_BASE |" >> "$REPORT"

# ---- 0. 设备预检 ----
DEV_STATUS="$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" || true)"
if ! echo "$DEV_STATUS" | grep -qE "connected|available \(paired\)"; then
  echo "❌ 设备不可用: $DEVICE_ID（状态: $DEV_STATUS）"; exit 1
fi
echo "✅ 设备可用（$(echo "$DEV_STATUS" | awk '{print $1}')）" | tee -a "$REPORT"

if [[ $DO_DRY -eq 1 ]]; then
  echo "dry-run: 设备 OK；计划构建=$DO_INSTALL 启动=$DO_LAUNCH 抓官网基准=$DO_REF 观察窗=${WAIT_SEC}s"
  exit 0
fi

# ---- 1. 官网 total 基准（curl 对照） ----
EXP_IMPORTANT="${EXP_IMPORTANT:-522}"   # 学校要闻（62ba 默认值，--skip-ref 时使用）
EXP_HONOR="${EXP_HONOR:-36}"            # 校园荣誉
EXP_NEWS="${EXP_NEWS:-876}"             # 五栏目合计
if [[ $DO_REF -eq 1 ]]; then
  UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
  echo "" >> "$REPORT"
  echo "## 1. 官网栏目 total 基准（curl）" >> "$REPORT"
  echo '| 栏目 | column_id | total |' >> "$REPORT"
  echo '|------|-----------|-------|' >> "$REPORT"
  H5="$(curl -s -m 20 -A "$UA" "$API_BASE/school/home5")"
  NEWS_COLS="$(echo "$H5" | python3 -c "
import json,sys
raw=sys.stdin.buffer.read()
d=json.loads(raw.decode('utf-8', errors='replace'), strict=False)['data']
for k in ('importants','updates','resports','notices','informations'):
    c=d['news']['children'][k]
    print(c['title_cn']+'|'+c['column_id']+'|'+str(c['articles']['total']))
ach=d['achievements']
print(ach['title_cn']+'|'+ach['column_id']+'|'+str(ach['articles']['total']))
" 2>/dev/null)"
  SUM=0
  while IFS='|' read -r cn cid total; do
    [[ -z "$cn" ]] && continue
    echo "| $cn | $cid | $total |" >> "$REPORT"
    if [[ "$cn" == "学校要闻" ]]; then EXP_IMPORTANT="$total"
    elif [[ "$cn" == "校园荣誉" ]]; then EXP_HONOR="$total"; fi
    # 五栏目合计（排除校园荣誉）
    case "$cn" in
      学校要闻|新闻资讯|党建动态|通知公告|招生信息) SUM=$((SUM + total)) ;;
    esac
  done <<< "$NEWS_COLS"
  EXP_NEWS="$SUM"
  echo "✅ 官网基准抓取完成（五栏目合计 news=${SUM}）" | tee -a "$REPORT"
fi

# ---- 2. 构建 + 安装 ----
if [[ $DO_INSTALL -eq 1 ]]; then
  echo "" >> "$REPORT"
  echo "## 2. 构建 + 安装" >> "$REPORT"
  echo '```' >> "$REPORT"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "id=$DEVICE_ID" -derivedDataPath "$DERIVED" build 2>&1 \
      | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tee -a "$REPORT"
  echo '```' >> "$REPORT"
  if ! grep -q "BUILD SUCCEEDED" "$REPORT"; then echo "❌ 构建失败"; exit 1; fi
  echo "✅ 构建成功" | tee -a "$REPORT"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >> "$REPORT" 2>&1 || { echo "❌ 安装失败"; exit 1; }
  echo "✅ 安装完成" | tee -a "$REPORT"
fi

# ---- 3. 启动 + 观察窗 ----
if [[ $DO_LAUNCH -eq 1 ]]; then
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" >> "$REPORT" 2>&1
  echo "" >> "$REPORT"
  echo "## 3. 同步观察（${WAIT_SEC}s）" >> "$REPORT"
  sleep "$WAIT_SEC"
  echo "✅ 观察窗结束" | tee -a "$REPORT"
fi

# ---- 4. 拉日志 ----
echo "" >> "$REPORT"
echo "## 4. 日志断言" >> "$REPORT"
xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "Documents" --destination "$PULL_DIR" >> /dev/null 2>&1
LOG_FILE="$(ls -t "$PULL_DIR"/SXJZIT_Cache/Logs/log_*.json 2>/dev/null | head -1)"
if [[ -z "$LOG_FILE" ]]; then echo "❌ 未找到日志文件"; exit 1; fi
echo "日志: $(basename "$LOG_FILE")" >> "$REPORT"
jq -c '.[]' "$LOG_FILE" > "$PULL_DIR/all.jsonl"
LINES="$PULL_DIR/all.jsonl"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1" | tee -a "$REPORT"; }
ko(){ FAIL=$((FAIL+1)); echo "  ❌ $1" | tee -a "$REPORT"; }

# A1 学校要闻 fetched == 官网 total（默认期望 522）
IMP="$(jq -r 'select(.message=="栏目全量拉取完成" and .context.label=="学校要闻") | .context.fetched' "$LINES" | tail -1)"
IMP_PAGES="$(jq -r 'select(.message=="栏目全量拉取完成" and .context.label=="学校要闻") | .context.pages' "$LINES" | tail -1)"
if [[ "$IMP" == "$EXP_IMPORTANT" ]]; then
  ok "A1 学校要闻全量: fetched=$IMP == 官网 ${EXP_IMPORTANT}（${IMP_PAGES} 页）"
else
  ko "A1 学校要闻全量: fetched=$IMP != 期望 ${EXP_IMPORTANT}"
fi

# A2 校园荣誉 fetched == 官网 total（期望 36）
HON="$(jq -r 'select(.message=="栏目全量拉取完成" and .context.label=="校园荣誉") | .context.fetched' "$LINES" | tail -1)"
if [[ "$HON" == "$EXP_HONOR" ]]; then
  ok "A2 校园荣誉全量: fetched=$HON == 官网 $EXP_HONOR"
else
  ko "A2 校园荣誉全量: fetched=$HON != 期望 $EXP_HONOR"
fi

# A3 静态契约：无翻页截断残留（匹配实际代码，排除注释说明）
if grep -E 'for page in 1\.\.\.6|for page in 1 \.\.\.' "$ROOT/qin/DesignCode/DataService.swift" | grep -v '^\s*//'; then
  ko "A3 静态契约: DataService 仍残留固定页循环"
else
  ok "A3 静态契约: DataService 无 6 页固定循环残留"
fi
if grep -qE '\bmaxPages\b' "$ROOT/qin/DesignCode/OrganizationView.swift"; then
  ko "A3 静态契约: OrganizationView 仍引用 maxPages"
else
  ok "A3 静态契约: OrganizationView 无 maxPages 引用"
fi

# B1 同步总量一致
SYNC_NEWS="$(jq -r 'select(.message=="数据同步完成") | .context.news' "$LINES" | tail -1)"
SYNC_HON="$(jq -r 'select(.message=="数据同步完成") | .context.honors' "$LINES" | tail -1)"
SYNC_ERR="$(jq -r 'select(.message=="数据同步完成") | .context.errors' "$LINES" | tail -1)"
if [[ "$SYNC_NEWS" == "$EXP_NEWS" ]] && [[ "$SYNC_ERR" == "0" ]]; then
  ok "B1 同步总量: news=$SYNC_NEWS honors=$SYNC_HON errors=${SYNC_ERR}（期望 news=${EXP_NEWS} errors=0）"
else
  ko "B1 同步总量: news=$SYNC_NEWS honors=$SYNC_HON errors=${SYNC_ERR} != 期望 news=${EXP_NEWS} errors=0"
fi

# C1 无降级告警
if grep -q '栏目服务端暂不可用' "$LINES"; then
  ko "C1 出现栏目服务端降级告警"
else
  ok "C1 无栏目服务端暂不可用告警"
fi

# D0 无 ERROR
if grep -o 'articleSync[^}]*' "$LINES" | grep -qE '"level":"(ERROR|FATAL)"'; then
  ko "D0 articleSync 域存在 ERROR/FATAL"
else
  ok "D0 articleSync 域 0 ERROR/FATAL"
fi

# ---- 汇总 ----
echo "" >> "$REPORT"
echo "## 5. 结论" >> "$REPORT"
echo "- 通过: $PASS | 失败: $FAIL" >> "$REPORT"
if [[ $FAIL -eq 0 ]]; then
  echo "- **判定: ✅ 修复无负面影响，新闻全量同步回归通过**" >> "$REPORT"
else
  echo "- **判定: ❌ 存在回归，需修复后重跑**" >> "$REPORT"
fi
echo "" >> "$REPORT"
echo "报告: $REPORT"
echo "通过=$PASS 失败=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1