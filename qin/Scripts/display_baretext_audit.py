#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
显示排版「裸文本」审计（2026-09-29 建立；Phase 0 定位 + Phase 3 护栏共用）

目的：找出所有「文本构造但附近无 display* 排版链」的位置。
裸文本会固定使用系统字体，不随显示设置（字体家族/字号档/粗体/行距/字距）变化——
这是「显示设置无法影响全局」的根因类别（护栏规则一/二均检测不到）。

已排除：注释、系统弹窗（.alert / .confirmationDialog，文案由系统渲染，平台限制）。

判定口径（2026-09-29 语句级精确化）：以「构造语句自身」为范围——
  1) 构造同行/其后「. 起始修饰链行」的 display* 链（如换行书写的 .displayFont(13)）；
  2) 构造自带的闭包内容（Toggle/Button/Picker 的 label、Menu 项等）；
  3) 祖先容器语句挂链时，其后代文本自动视为已覆盖（SwiftUI 环境字体沿视图树向下传播）。
姊妹视图的修饰行不再互相「遮罩」——修复早期窗口判定造成的漏报。
空串构造（如 Toggle("", isOn:)）无可见文字，直接排除。

用法：
  python3 qin/Scripts/display_baretext_audit.py            # 汇总报告
  python3 qin/Scripts/display_baretext_audit.py --list     # 附带逐处清单（用于 Phase 2 补链）
  python3 qin/Scripts/display_baretext_audit.py --baseline # 护栏模式：与基线快照比对，新增位置即失败（exit 1）
"""
import os
import re
import sys
import glob
import json

SRCROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(SRCROOT, 'DesignCode')
BASELINE_PATH = os.path.join(SRCROOT, 'Scripts', 'display_baretext_baseline.json')

CONSTRUCT = re.compile(r'\b(Text|Label|Button|TextField|SecureField|Toggle|Picker|Menu|Link|LabeledContent)\(')
NAV_TITLE = re.compile(r'\bnavigationTitle\(')
CHAIN = re.compile(r'displayText\(|displayFont\(|displayLabelFont\(|displaySymbolFont\(|DisplayFontFactory|displayTypography')
SYSTEM_CTX = re.compile(r'\.(alert|confirmationDialog)\(')
EMPTY_FIRST = re.compile(r'^\w+\(\s*""')
STRING_LIT = re.compile(r'"(?:[^"\\]|\\.)*"')
FUNC_DEF = re.compile(r'\bfunc\s+(\w+)')
TYPE_DEF = re.compile(r'\b(struct|class|enum|extension|protocol)\s+\w+')


def enclosing_function(lines, i):
    """向上找最近的函数定义（遇类型定义则停）：返回 (定义行, 函数名)"""
    for j in range(i, -1, -1):
        s = lines[j].lstrip()
        if TYPE_DEF.search(code_of(lines[j])) and j != i:
            return None, None
        m = FUNC_DEF.search(code_of(lines[j]))
        if m:
            return j, m.group(1)
    return None, None


def call_site_covered(lines, func_name, def_line):
    """函数级调用点覆盖：该函数在文件内所有调用点的语句区间都含 display 链 →
    其返回值内部文本已由调用点环境字体覆盖（搜索高亮 helper 范式）"""
    pat = re.compile(r'(?<![\w.])' + re.escape(func_name) + r'\s*\(')
    sites = []
    for k, line in enumerate(lines):
        if k == def_line or line.lstrip().startswith('//'):
            continue
        if pat.search(code_of(line)):
            sites.append(k)
    if not sites:
        return False
    for k in sites:
        region = '\n'.join(lines[k: statement_end(lines, k) + 1])
        if not CHAIN.search(region):
            return False
    return True


def code_of(line):
    """去掉字符串字面量与行注释后的代码文本（用于括号配平，避免串内括号干扰）"""
    return STRING_LIT.sub('""', line).split('//')[0]


def compute_depths(lines):
    """每行行首的括号深度（花括号 + 圆括号）"""
    depths = []
    depth = 0
    for line in lines:
        depths.append(depth)
        for ch in code_of(line):
            if ch == '{' or ch == '(':
                depth += 1
            elif ch == '}' or ch == ')':
                depth -= 1
        if depth < 0:
            depth = 0
    return depths


def system_block_end(lines, start_idx):
    """粗略花括号配平，返回系统弹窗闭包的结束行（含）"""
    depth = 0
    started = False
    for i in range(start_idx, len(lines)):
        for ch in lines[i]:
            if ch == '{':
                depth += 1
                started = True
            elif ch == '}':
                depth -= 1
        if started and depth <= 0:
            return i
    return len(lines) - 1


def statement_end(lines, start_idx):
    """返回构造语句的结束行（含）：括号配平 + 吞并后续「.」起始的修饰链行（跳过注释/空行）"""
    depth = 0
    j = start_idx
    n = len(lines)
    while j < n:
        for ch in code_of(lines[j]):
            if ch == '{' or ch == '(':
                depth += 1
            elif ch == '}' or ch == ')':
                depth -= 1
        if depth <= 0:
            k = j + 1
            while k < n and (not lines[k].strip() or lines[k].strip().startswith('//')):
                k += 1
            if k < n and lines[k].lstrip().startswith('.'):
                j = k
                continue
            return j
        j += 1
    return n - 1


def covered_ranges(lines, depths):
    """所有 display 链所归属语句的行区间 [head, statement_end(head)]：
    head = 链行向上最近的「同深度」行；容器语句的区间含其闭包内容 → 后代自动覆盖"""
    ranges = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith('//') or not CHAIN.search(line):
            continue
        d = depths[i]
        h = i
        j = i - 1
        while j >= 0:
            s = lines[j].strip()
            if not s or s.startswith('//') or lines[j].lstrip().startswith('.'):
                # 空行 / 注释 / 修饰链行均跳过：要找的是语句头（如 Picker(...) { 而非 .pickerStyle(...)）
                j -= 1
                continue
            if depths[j] == d:
                h = j
                break
            j -= 1
        ranges.append((h, statement_end(lines, h)))
    return ranges


def audit_file(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    depths = compute_depths(lines)
    covered = covered_ranges(lines, depths)
    sys_ranges = [(i, system_block_end(lines, i)) for i, l in enumerate(lines) if SYSTEM_CTX.search(l)]

    def in_sys(i):
        return any(a <= i <= b for a, b in sys_ranges)

    def is_covered(i):
        return any(a <= i <= b for a, b in covered)

    hits = []
    nav_titles = []
    for i, line in enumerate(lines):
        s = line.lstrip()
        if s.startswith('//') or s.startswith('///') or s.startswith('*'):
            continue
        if in_sys(i) or is_covered(i):
            continue
        if NAV_TITLE.search(line):
            # navigationTitle 由系统导航栏绘制：已由 UIKit Appearance 桥全局接管（P1，2026-09-29），不计缺口
            nav_titles.append(i + 1)
            continue
        m = CONSTRUCT.search(line)
        if not m:
            continue
        if m.group(1) == 'Label' and '.tabItem' in '\n'.join(lines[max(0, i - 3): i + 4]):
            # 系统 Tab 项标签：由 UITabBarAppearance 全局接管（P1），不计缺口
            continue
        if EMPTY_FIRST.match(line[m.start():].lstrip()):
            # 空串构造（Toggle("", isOn:) 等）无可见文字
            continue
        region = '\n'.join(lines[i: statement_end(lines, i) + 1])
        if CHAIN.search(region):
            continue
        fdef, fname = enclosing_function(lines, i)
        if fname and call_site_covered(lines, fname, fdef):
            # 辅助函数内部文本：由所有调用点的 display 链环境化覆盖（如 highlightedText helper）
            continue
        hits.append({'line': i + 1, 'kind': m.group(1), 'text': line.strip()[:100]})
    return hits, len(nav_titles)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    all_hits = {}
    nav_total = 0
    for f in sorted(glob.glob(os.path.join(SOURCE_DIR, '*.swift'))):
        h, nav = audit_file(f)
        nav_total += nav
        if h:
            all_hits[os.path.basename(f)] = h
    total = sum(len(v) for v in all_hits.values())

    if mode == '--baseline':
        old = {}
        if os.path.exists(BASELINE_PATH):
            old = json.load(open(BASELINE_PATH, encoding='utf-8'))
        regressions = {}
        for f, items in all_hits.items():
            old_lines = {x['line'] for x in old.get(f, [])}
            fresh = [x for x in items if not any(abs(x['line'] - ol) <= 3 for ol in old_lines)]
            if fresh:
                regressions[f] = fresh
        if regressions:
            n = sum(len(v) for v in regressions.values())
            print('❌ 裸文本回归：%d 处新增文本未接入显示排版链（裸文本=系统字体，设置将无法影响）' % n)
            print('   修复：为文本挂 displayText / displayFont / displayLabelFont / displaySymbolFont')
            for f, items in sorted(regressions.items()):
                for x in items:
                    print('   %s:%d [%s] %s' % (f, x['line'], x['kind'], x['text']))
            return 1
        print('✅ 裸文本基线通过（当前存量 %d 处，无新增）' % total)
        return 0

    print('【裸文本审计】未接显示排版链的文本构造：%d 处（注释与系统弹窗文案已排除；navigationTitle %d 处已由 Appearance 桥接管，不计缺口）' % (total, nav_total))
    for f, items in sorted(all_hits.items(), key=lambda kv: -len(kv[1])):
        print('\n=== %s: %d 处 ===' % (f, len(items)))
        if mode == '--list':
            for x in items:
                print('  L%d [%s] %s' % (x['line'], x['kind'], x['text']))
    return 0


if __name__ == '__main__':
    sys.exit(main())