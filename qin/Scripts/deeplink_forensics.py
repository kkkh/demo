#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
收藏更新深链取证脚本 —— 手动验收步骤 7 的自动化核对（2026-09-29，对应提交 d8914ee）

用途：
  从真机拉取 LogManager 日文件（Documents/SXJZIT_Cache/Logs/log_*.json）并按固定证据链判定
  「收藏更新深链归因」两路径是否生效，输出 PASS/FAIL/N-A 报告。

用法：
  # 1) 默认：拉取真机日志 + 分析（设备=秦超的iPhone，bundle=com.qinchao）
  python3 Scripts/deeplink_forensics.py

  # 2) 只分析本地已拉取目录（不触发 devicectl）
  python3 Scripts/deeplink_forensics.py --dir qin/build/verify/forensics_pull

  # 3) 时间窗调节（默认最近 180 分钟；--all 全量）
  python3 Scripts/deeplink_forensics.py --last-minutes 600
  python3 Scripts/deeplink_forensics.py --all

  # 4) 自检：内置合成样本验证判定逻辑（无需设备/无需日志）
  python3 Scripts/deeplink_forensics.py --selftest

前置：真机「日志设置」需打开 DEBUG 记录（kind 分支日志为 debug 级，否则 A/B 项无法取证）。

判定信号（逐条对应源码日志原文）：
  A 消息中心路径  messageCenter「消息点击 → 深链投递」(kind=bookmarkUpdate)
                    → notification「通知点击响应」(source=message_center)
                    → messageCenter「消息已标记已读（kind+articleId 匹配）」或「按 kind+articleId 未匹配到未读消息（保持现状）」(kind=bookmarkUpdate)
  B 系统通知路径  notification「通知点击响应」(source=system_tap，与 favorite「收藏更新通知已发送」标题互证)
                    → 同上 kind 分支日志
  C 误标哨戒      bookmark 点击后 5s 内出现 news- 前缀的「消息已标记已读」→ WARN（修复前的跨消息误标面）

退出码：0=通过（至少一条 PASS 且无 FAIL/WARN）｜1=存在 FAIL/WARN｜2=窗口内无可判定事件｜3=执行错误
"""

import argparse
import glob
import json
import os
import subprocess
import sys
from datetime import datetime

DEVICE_UDID = "00008110-000411A40EC1401E"
BUNDLE_ID = "com.qinchao"
DEVICE_LOGS_PATH = "Documents/SXJZIT_Cache/Logs"
REF_EPOCH_OFFSET = 978307200.0  # JSONEncoder 默认 Date 策略（2001 参考秒）→ Unix 秒
LINK_WINDOW_SEC = 5.0           # 证据链相邻环节的最大间隔
DEFAULT_WINDOW_MIN = 180.0      # 默认分析最近 180 分钟

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_DEST = os.path.join(REPO_ROOT, "qin", "build", "verify", "forensics_pull")  # 取证产物统一落 qin/build/verify（已被 .gitignore 覆盖）


# ---------------------------------------------------------------- 拉取

def pull_logs(dest):
    os.makedirs(dest, exist_ok=True)
    cmd = [
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", DEVICE_UDID,
        "--domain-type", "appDataContainer",
        "--domain-identifier", BUNDLE_ID,
        "--source", DEVICE_LOGS_PATH,
        "--destination", dest,
    ]
    print("[pull] " + " ".join(cmd))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except Exception as e:
        print(f"[error] devicectl 执行失败：{e}", file=sys.stderr)
        sys.exit(3)
    if r.returncode != 0:
        print(r.stdout.strip(), file=sys.stderr)
        print(r.stderr.strip(), file=sys.stderr)
        print("[error] 拉取失败：请确认设备已连接/解锁（devicectl list devices 应显示 connected）", file=sys.stderr)
        sys.exit(3)


# ---------------------------------------------------------------- 加载

def load_entries(root):
    files = sorted(glob.glob(os.path.join(root, "**", "log_*.json"), recursive=True))
    entries = []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                arr = json.load(fh)
        except Exception as e:
            print(f"[warn] 无法解析 {os.path.basename(f)}：{e}")
            continue
        for e in arr:
            ts = float(e.get("timestamp", 0))
            if ts < 1_000_000_000:          # 参考日期秒 → Unix
                ts += REF_EPOCH_OFFSET
            entries.append({
                "ts": ts,
                "module": e.get("module", ""),
                "level": e.get("level", ""),
                "message": e.get("message", ""),
                "context": e.get("context") or {},
                "file": os.path.basename(f),
            })
    entries.sort(key=lambda x: x["ts"])
    return entries, files


# ---------------------------------------------------------------- 事件分类

def is_send(e):       return e["module"] == "favorite" and "收藏更新通知已发送" in e["message"]
def is_mc_click(e):   return (e["module"] == "messageCenter"
                              and "消息点击 → 深链投递" in e["message"]
                              and e["context"].get("kind") == "bookmarkUpdate")
def is_tap(e):        return e["module"] == "notification" and "通知点击响应" in e["message"]
def is_mark_id(e):    return e["module"] == "messageCenter" and e["message"].strip() == "消息已标记已读"
def is_mark_kind(e):  return e["module"] == "messageCenter" and "消息已标记已读（kind+articleId 匹配）" in e["message"]
def is_no_match(e):   return e["module"] == "messageCenter" and "未匹配到未读消息" in e["message"]
def is_no_article(e): return e["module"] == "notification" and "未携带 articleId" in e["message"]

def kind_log(e):      return (is_mark_kind(e) or is_no_match(e)) and e["context"].get("kind") == "bookmarkUpdate"
def fmt_ts(ts):       return datetime.fromtimestamp(ts).strftime("%m-%d %H:%M:%S.%f")[:-3]


# ---------------------------------------------------------------- 判定

def run_checks(entries, since_ts):
    """返回判定结果字典（与文件 IO 解耦，供 --selftest 复用）。"""
    work = [e for e in entries if e["ts"] >= since_ts]
    sends, clicks, taps = [], [], []
    for e in work:
        if is_send(e):      sends.append(e)
        if is_mc_click(e):  clicks.append(e)
        if is_tap(e):       taps.append(e)

    res = {
        "window_entries": len(work),
        "sends": sends,
        "a_pass": [], "a_fail": [], "a_incomplete": [],
        "b_pass": [], "b_fail": [],
        "c_warn": [],
        "debug_level_present": any(e["level"] == "DEBUG" for e in work),
    }

    # A. 消息中心路径
    for c in clicks:
        tap = next((t for t in taps
                    if LINK_WINDOW_SEC >= t["ts"] - c["ts"] >= 0
                    and "message_center" in str(t["context"].get("source", ""))), None)
        if tap is None:
            res["a_incomplete"].append({"click": c, "tap": None})
            continue
        mark = next((m for m in work
                     if LINK_WINDOW_SEC >= m["ts"] - tap["ts"] >= 0 and kind_log(m)), None)
        mark_before = next((m for m in work if is_mark_id(m)
                            and -2.0 <= m["ts"] - c["ts"] <= 0.5
                            and str(m["context"].get("id", "")).startswith("bookmark-update-")), None)
        chain = {"click": c, "tap": tap, "mark": mark, "mark_before": mark_before}
        (res["a_pass"] if mark else res["a_fail"]).append(chain)

    # B. 系统通知路径（以 favorite「已发送」标题与点击标题互证归属）
    send_titles = [str(s["context"].get("title", "")) for s in sends if s["context"].get("title")]
    for t in taps:
        if "message_center" in str(t["context"].get("source", "")):
            continue
        mark = next((m for m in work
                     if LINK_WINDOW_SEC >= m["ts"] - t["ts"] >= 0 and kind_log(m)), None)
        tap_title = str(t["context"].get("articleTitle", ""))
        related = bool(mark) or any(
            tt and tap_title and (tt == tap_title or tt in tap_title or tap_title in tt)
            for tt in send_titles)
        if mark:
            res["b_pass"].append({"tap": t, "mark": mark})
        elif related:
            res["b_fail"].append({"tap": t, "mark": None})

    # C. 误标哨戒（bookmark 点击 ±5s 内出现 news- 前缀按 id 标已读）
    for c in clicks:
        for m in work:
            if is_mark_id(m) and str(m["context"].get("id", "")).startswith("news-") \
                    and -2.0 <= m["ts"] - c["ts"] <= LINK_WINDOW_SEC:
                res["c_warn"].append({"click": c, "mark": m})

    return res


# ---------------------------------------------------------------- 报告

def render(res, files, since_ts, newest_ts, out=None):
    lines = []
    def w(s=""): lines.append(s)

    w("=" * 62)
    w("收藏更新深链取证报告（deeplink_forensics.py）")
    w("=" * 62)
    if newest_ts:
        w(f"窗口：{fmt_ts(since_ts)} ~ {fmt_ts(newest_ts)}（最近 {int((newest_ts - since_ts) / 60)} 分钟内 "
          f"{res['window_entries']} 条；文件 {len(files)} 个）")
    w(f"收藏更新通知发出：{len(res['sends'])} 次")
    if not res["debug_level_present"]:
        w("⚠️ 窗口内无 DEBUG 级日志：请在「我的 → 应用日志 → 日志设置」打开 DEBUG 记录后重试（kind 分支日志为 debug 级）")

    def chain_lines(title, chains, ok):
        w(f"\n【{title}】 { 'PASS' if ok else 'FAIL'}（{len(chains)} 次）")
        for i, ch in enumerate(chains, 1):
            w(f"  证据链 #{i}：")
            c, t, m = ch["click"], ch["tap"], ch.get("mark")
            if ch.get("mark_before"):
                mb = ch["mark_before"]
                w(f"    [{fmt_ts(mb['ts'])}] {mb['module']:>13}  消息已标记已读(id={mb['context'].get('id', '')})  ← 条目按 id 消未读")
            w(f"    [{fmt_ts(c['ts'])}] {c['module']:>13}  消息点击 → 深链投递(kind={c['context'].get('kind', '')})")
            if t:
                w(f"    [{fmt_ts(t['ts'])}] {t['module']:>13}  通知点击响应(source={t['context'].get('source', '')})")
            if m:
                w(f"    [{fmt_ts(m['ts'])}] {m['module']:>13}  {m['message']}(kind={m['context'].get('kind', '')})  ← 归因生效")
            else:
                w("    —— 未见 kind 分支日志（疑似旧构建/回退），归因未生效 ——")

    if res["a_pass"] or res["a_fail"]:
        chain_lines("检查 A · 消息中心路径", res["a_pass"] + res["a_fail"], ok=bool(res["a_pass"]) and not res["a_fail"])
    elif res["a_incomplete"]:
        w(f"\n【检查 A · 消息中心路径】 INCOMPLETE（{len(res['a_incomplete'])} 次点击未见分发日志——"
          "请确认应用在前台且未被生物锁拦截）")
    else:
        w("\n【检查 A · 消息中心路径】 N/A（窗口内无 kind=bookmarkUpdate 的消息中心点击——先执行验收步骤 4）")

    if res["b_pass"] or res["b_fail"]:
        w(f"\n【检查 B · 系统通知路径】 {'PASS' if not res['b_fail'] else 'FAIL'}"
          f"（命中归因 {len(res['b_pass'])} 次 / 可疑未归因 {len(res['b_fail'])} 次）")
        for ch in res["b_pass"] + res["b_fail"]:
            t, m = ch["tap"], ch["mark"]
            w(f"    [{fmt_ts(t['ts'])}] 通知点击响应(source={t['context'].get('source', '')}, "
              f"articleId={t['context'].get('articleId', '')})")
            if m:
                w(f"    [{fmt_ts(m['ts'])}] {m['message']}(kind={m['context'].get('kind', '')})  ← 归因生效")
            else:
                w("    —— 与收藏更新通知标题互证但未见 kind 分支日志 ——")
    else:
        w("\n【检查 B · 系统通知路径】 N/A（窗口内无系统通知点击——先执行验收步骤 3）")

    w(f"\n【检查 C · 跨消息误标哨戒】 {'PASS（无 news- 误标）' if not res['c_warn'] else 'WARN'}")
    for ch in res["c_warn"]:
        c, m = ch["click"], ch["mark"]
        w(f"    [{fmt_ts(m['ts'])}] 收藏点击后出现 消息已标记已读(id={m['context'].get('id', '')})  ← 疑似跨消息误标")

    fails = len(res["a_fail"]) + len(res["b_fail"]) + len(res["c_warn"])
    passes = len(res["a_pass"]) + len(res["b_pass"])
    if fails:
        w(f"\n结论：存在 {fails} 项 FAIL/WARN —— 请把本报告与原始日志（{files[0] if files else '—'} 所在目录）一并留档")
        code = 1
    elif passes:
        w(f"\n结论：PASS（{passes} 条证据链）——收藏更新深链归因两路径均生效")
        code = 0
    else:
        w("\n结论：无可判定事件（N/A）——请先按验收清单步骤 3/4 产生一次收藏更新点击后重跑")
        code = 2

    text = "\n".join(lines)
    print(text)
    if out:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"\n[报告已写入] {out}")
    return code


# ---------------------------------------------------------------- 自检

def selftest():
    now = datetime.now().timestamp()
    def E(offset, module, message, **ctx):
        return {"ts": now + offset, "module": module, "level": "DEBUG", "message": message,
                "context": {k: str(v) for k, v in ctx.items()}, "file": "selftest"}
    cases = []

    # 1) 修复后：View 按 id 消未读 → 点击 → 分发 → kind 分支「保持现状」（条目已读）⇒ A PASS/C PASS
    fixed = [
        E(-1, "messageCenter", "消息已标记已读", id="bookmark-update-rk1"),
        E(0, "messageCenter", "消息点击 → 深链投递", kind="bookmarkUpdate"),
        E(0.45, "notification", "通知点击响应", source="message_center", articleId="a9"),
        E(0.46, "messageCenter", "按 kind+articleId 未匹配到未读消息（保持现状）", kind="bookmarkUpdate"),
    ]
    r = run_checks(fixed, now - 60)
    cases.append(("修复后-消息中心", len(r["a_pass"]) == 1 and not r["a_fail"] and not r["c_warn"], r))

    # 2) 修复前：无 kind 分支日志 ⇒ A FAIL
    old = [
        E(0, "messageCenter", "消息点击 → 深链投递", kind="bookmarkUpdate"),
        E(0.45, "notification", "通知点击响应", source="message_center", articleId="a9"),
    ]
    r = run_checks(old, now - 60)
    cases.append(("修复前-消息中心", len(r["a_fail"]) == 1, r))

    # 3) 系统通知路径：favorite 已发送 + 系统点击 + kind 匹配 ⇒ B PASS
    sys_case = [
        E(-60, "favorite", "收藏更新通知已发送", readKey="a9", title="测试文章"),
        E(0, "notification", "通知点击响应", source="system_tap", articleId="a9", articleTitle="测试文章"),
        E(0.01, "messageCenter", "消息已标记已读（kind+articleId 匹配）", kind="bookmarkUpdate", articleId="a9"),
    ]
    r = run_checks(sys_case, now - 300)
    cases.append(("系统通知路径", len(r["b_pass"]) == 1 and not r["b_fail"], r))

    # 4) 误标哨戒：收藏点击后出现 news- 标已读 ⇒ C WARN
    warn = [
        E(0, "messageCenter", "消息点击 → 深链投递", kind="bookmarkUpdate"),
        E(0.45, "notification", "通知点击响应", source="message_center", articleId="a9"),
        E(0.46, "messageCenter", "消息已标记已读", id="news-a9"),
    ]
    r = run_checks(warn, now - 60)
    cases.append(("误标哨戒", len(r["c_warn"]) == 1, r))

    ok = True
    for name, passed, _ in cases:
        print(f"[selftest] {name}: {'OK' if passed else 'FAILED'}")
        ok = ok and passed
    print("[selftest] 全部通过" if ok else "[selftest] 存在失败")
    return 0 if ok else 1


# ---------------------------------------------------------------- 入口

def main():
    ap = argparse.ArgumentParser(description="收藏更新深链取证（手动验收步骤 7）")
    ap.add_argument("--dir", help="本地日志目录（给定时跳过 devicectl 拉取）")
    ap.add_argument("--dest", default=DEFAULT_DEST, help=f"拉取目标目录（默认 {DEFAULT_DEST}）")
    ap.add_argument("--last-minutes", type=float, default=DEFAULT_WINDOW_MIN, help="分析最近 N 分钟（默认 180）")
    ap.add_argument("--all", action="store_true", help="分析全部日志（忽略时间窗）")
    ap.add_argument("--out", help="报告另存路径（默认仅打印）")
    ap.add_argument("--selftest", action="store_true", help="运行内置自检")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    root = args.dir if args.dir else args.dest
    if not args.dir:
        pull_logs(args.dest)

    entries, files = load_entries(root)
    if not entries:
        print(f"[error] 未在 {root} 找到 log_*.json —— 确认拉取成功或真机至少产生过一条日志", file=sys.stderr)
        sys.exit(3)

    newest = entries[-1]["ts"]
    since = entries[0]["ts"] if args.all else max(entries[0]["ts"], newest - args.last_minutes * 60)
    res = run_checks(entries, since)
    sys.exit(render(res, files, since, newest, out=args.out))


if __name__ == "__main__":
    main()