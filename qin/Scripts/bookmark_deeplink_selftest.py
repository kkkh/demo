#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
收藏更新深链「触发 + 验证」自动化脚本（2026-09-29）

一条命令跑完整链路（无人值守）：
  构建(DEBUG) → 安装真机 → 带 `-uiTestBookmarkDeepLink` 启动 App
  → App 内自测钩子：重建自测收藏 → 注入哨兵旧基线 → 真实更新检测（通知+入盒）
    → 模拟系统通知点击 + 消息中心条目点击 → 回执落盘
  → 宿主机取回执 + 拉取设备日志 → 复用 deeplink_forensics 判定证据链 → 出报告

用法：
  python3 qin/Scripts/bookmark_deeplink_selftest.py               # 全流程（含构建+安装）
  python3 qin/Scripts/bookmark_deeplink_selftest.py --skip-build  # 跳过构建安装，仅触发+验证
  python3 qin/Scripts/bookmark_deeplink_selftest.py --timeout 180 # 回执等待上限（秒）

前置：
  · 真机已连接且已解锁（锁屏时 devicectl 启动会静默不生效）；
  · Xcode 自动签名可用（构建带 -allowProvisioningUpdates）；
  · 设备网络可访问学校 API（更新检测要真实拉取正文）。

产物（均在 qin/build/verify/，已被 .gitignore 覆盖）：
  · bookmark_deeplink_selftest_marker.json  —— App 回执原文（证据）
  · bookmark_deeplink_selftest_report.txt   —— 回执摘要 + 日志证据链判定报告

退出码：0=触发成功且 A/B 双路径 PASS ｜ 1=存在 FAIL/回执失败 ｜ 2=触发成功但证据链不全 ｜ 3=构建/安装/启动失败
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import deeplink_forensics as f  # noqa: E402  复用拉取/解析/判定/渲染

REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
PROJECT = os.path.join(REPO_ROOT, "qin", "DesignCode.xcodeproj")
DD_PATH = os.path.join(REPO_ROOT, "qin", "build", "DerivedData-selftest")
VERIFY_DIR = os.path.join(REPO_ROOT, "qin", "build", "verify")
MARKER_DIR = os.path.join(VERIFY_DIR, "selftest_marker")
MARKER_NAME = "bookmark_deeplink_selftest_done.json"
MARKER_REPORT = os.path.join(VERIFY_DIR, "bookmark_deeplink_selftest_marker.json")
REPORT_PATH = os.path.join(VERIFY_DIR, "bookmark_deeplink_selftest_report.txt")
LAUNCH_ARG = "-uiTestBookmarkDeepLink"


def run(cmd, timeout=600, label="", quiet=False):
    if label:
        print(f"{label} $ {' '.join(cmd)}")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0 and not quiet:
        print(r.stdout[-2000:], file=sys.stderr)
        print(r.stderr[-2000:], file=sys.stderr)
    return r


def build_and_install():
    print("[1/6] 构建 DEBUG（真机 destination，自动签名）…")
    app_path = os.path.join(DD_PATH, "Build", "Products", "Debug-iphoneos", "DesignCode.app")
    r = run([
        "xcodebuild", "-project", PROJECT, "-scheme", "DesignCode",
        "-destination", f"platform=iOS,id={f.DEVICE_UDID}",
        "-derivedDataPath", DD_PATH, "-allowProvisioningUpdates", "build",
    ], timeout=900)
    if r.returncode != 0 or not os.path.isdir(app_path):
        print("[error] 构建失败", file=sys.stderr)
        sys.exit(3)
    print(f"[2/6] 安装到真机：{app_path}")
    r = run(["xcrun", "devicectl", "device", "install", "app",
             "--device", f.DEVICE_UDID, app_path], timeout=300)
    if r.returncode != 0:
        print("[error] 安装失败", file=sys.stderr)
        sys.exit(3)


def launch_app():
    print(f"[3/6] 启动 App（带 {LAUNCH_ARG}）…")
    r = run(["xcrun", "devicectl", "device", "process", "launch",
             "--device", f.DEVICE_UDID, "--terminate-existing",
             f.BUNDLE_ID, "--", LAUNCH_ARG], timeout=120)
    if r.returncode != 0:
        print("[error] 启动失败（设备是否已解锁？）", file=sys.stderr)
        sys.exit(3)
    return time.time()


def poll_marker(launch_ts, timeout):
    print(f"[4/6] 等待 App 回执（上限 {timeout}s；App 内检测需拉取真实正文）…")
    os.makedirs(MARKER_DIR, exist_ok=True)
    local_marker = os.path.join(MARKER_DIR, MARKER_NAME)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(local_marker):
            os.remove(local_marker)
        r = run(["xcrun", "devicectl", "device", "copy", "from",
                 "--device", f.DEVICE_UDID,
                 "--domain-type", "appDataContainer",
                 "--domain-identifier", f.BUNDLE_ID,
                 "--source", f"Documents/{MARKER_NAME}",
                 "--destination", local_marker], timeout=60, quiet=True)   # 单文件拷贝：destination 必须是文件路径（目录会报 Is a directory）
        if r.returncode == 0 and os.path.exists(local_marker):
            try:
                data = json.load(open(local_marker, encoding="utf-8"))
            except Exception:
                data = None
            # 新鲜度校验：仅接受本次启动之后产生的回执（防上一轮残留）
            if data and float(data.get("finishedAt", 0)) >= launch_ts - 10:
                shutil.copyfile(local_marker, MARKER_REPORT)
                return data
        time.sleep(3)
    return None


def main():
    ap = argparse.ArgumentParser(description="收藏更新深链触发+验证（真机无人值守）")
    ap.add_argument("--skip-build", action="store_true", help="跳过构建与安装（设备上需已是目标构建）")
    ap.add_argument("--timeout", type=int, default=150, help="回执等待上限秒数（默认 150）")
    args = ap.parse_args()

    os.makedirs(VERIFY_DIR, exist_ok=True)

    if args.skip_build:
        print("[1/6] 跳过构建；[2/6] 跳过安装（--skip-build）")
        launch_ts = time.time()
    else:
        build_and_install()
        launch_ts = launch_app()
    if args.skip_build:
        print(f"[3/6] 启动 App（带 {LAUNCH_ARG}）…")
        r = run(["xcrun", "devicectl", "device", "process", "launch",
                 "--device", f.DEVICE_UDID, "--terminate-existing",
                 f.BUNDLE_ID, "--", LAUNCH_ARG], timeout=120)
        if r.returncode != 0:
            print("[error] 启动失败（设备是否已解锁？）", file=sys.stderr)
            sys.exit(3)
        launch_ts = time.time()

    marker = poll_marker(launch_ts, args.timeout)
    if marker:
        print(f"[5/6] 回执：OK | status={marker.get('status')} updated={marker.get('updated')} "
              f"checked={marker.get('checked')} articleId={str(marker.get('articleId', ''))[:12]}…")
        if marker.get("status") != "ok":
            print(f"      reason={marker.get('reason')}")
    else:
        print(f"[5/6] 回执：MISS —— 未取到 {MARKER_NAME}（尝试日志回退判定）")

    print("[6/6] 拉取设备日志并判定证据链…")
    f.pull_logs(f.DEFAULT_DEST)
    entries, files = f.load_entries(f.DEFAULT_DEST)
    if not entries:
        print("[error] 未拉到日志", file=sys.stderr)
        sys.exit(3)
    newest = entries[-1]["ts"]
    since = max(entries[0]["ts"], launch_ts - 60)
    res = f.run_checks(entries, since)
    # 日志回退判定：回执文件不可达时，以 App 侧「完成」日志作为触发成功证据
    marker_log_ok = any(
        "收藏深链自测：完成" in e["message"] and e["ts"] >= launch_ts - 10 for e in entries)
    if marker is None:
        print(f"      （回退判定）App 日志完成标记：{'有' if marker_log_ok else '无'}")

    f.render(res, files, since, newest, out=REPORT_PATH)

    a_ok = len(res["a_pass"]) >= 1
    b_ok = len(res["b_pass"]) >= 1
    fails = len(res["a_fail"]) + len(res["b_fail"]) + len(res["c_warn"])
    trigger_ok = (marker is not None and marker.get("status") == "ok") or marker_log_ok

    with open(REPORT_PATH, "a", encoding="utf-8") as fh:
        fh.write(f"\n[回执] {'OK' if (marker and marker.get('status') == 'ok') else ('日志回退判定' if marker_log_ok else 'MISS')}"
                 + (f" updated={marker.get('updated')} checked={marker.get('checked')} "
                    f"messageItemId={marker.get('messageItemId')}" if marker else "")
                 + "\n")
        fh.write(f"[综合判定] 触发={'OK' if trigger_ok else 'FAIL'} | A(消息中心)={'PASS' if a_ok else 'MISS'} | "
                 f"B(系统通知)={'PASS' if b_ok else 'MISS'} | FAIL/WARN={fails}\n")

    if trigger_ok and a_ok and b_ok and fails == 0:
        suffix = "（回执经日志回退判定）" if marker is None else ""
        print(f"\n★ 综合判定：PASS —— 触发成功，双路径深链归因证据链完整{suffix}"
              "（报告：qin/build/verify/bookmark_deeplink_selftest_report.txt）")
        sys.exit(0)
    if fails or (marker is not None and marker.get("status") != "ok"):
        print("\n★ 综合判定：FAIL —— 见上方 FAIL/WARN 明细与回执 reason（报告同上）")
        sys.exit(1)
    print("\n★ 综合判定：INCOMPLETE —— 未确认触发成功或证据链不全（检查设备解锁/网络/日志 DEBUG 开关）")
    sys.exit(2)


if __name__ == "__main__":
    main()