#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
显示设置覆盖护栏（构建期强制，2026-09-27 全链审计固化）

规则一（排版链）：DesignCode/*.swift 中不允许出现绕过显示设置的原始字体写法。
    必须使用：displayFont / displayText / displaySymbolFont / displayLabelFont / DisplayFontFactory.font
    （字形图标用 displaySymbolFont、Label 用 displayLabelFont、正文段落用 displayText）
    例外：Scripts/display_coverage_allowlist.txt 中登记的「文件|匹配片段 # 理由」

规则二（弹出层）：每个 .sheet / .fullScreenCover 内容必须挂载 .sjzPresentationChrome()
    （外观模式 + 专注灰度跨 presentation 注入；系统分享面板 ShareSheet 自带豁免）

失败即中断构建，并打印修复指引。新增功能必须接入显示设置链，禁止悄悄绕过。
"""
import re
import sys
import glob
import os

SRCROOT = os.environ.get('SRCROOT', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE_DIR = os.path.join(SRCROOT, 'DesignCode')
ALLOWLIST_PATH = os.path.join(SRCROOT, 'Scripts', 'display_coverage_allowlist.txt')

FONT_CHAIN = re.compile(r'displayFont|displayText|displaySymbolFont|displayLabelFont|DisplayFontFactory|resolvedFont')


def load_allowlist():
    allow_font, allow_presentation = [], []
    if os.path.exists(ALLOWLIST_PATH):
        for raw in open(ALLOWLIST_PATH, encoding='utf-8'):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            body, _, _reason = line.partition('#')
            body = body.strip()
            if body.startswith('font:'):
                allow_font.append(body[len('font:'):].strip())
            elif body.startswith('presentation:'):
                allow_presentation.append(body[len('presentation:'):].strip())
    return allow_font, allow_presentation


def is_comment(line):
    s = line.lstrip()
    return s.startswith('//') or s.startswith('///') or s.startswith('*')


def font_allowed_for(file_name, line, allow_font):
    if FONT_CHAIN.search(line):
        return True
    for rule in allow_font:
        fname, _, frag = rule.partition('|')
        if fname.strip() == file_name and frag.strip() and frag.strip() in line:
            return True
    return False


def presentation_allowed_for(file_name, line_no, window, allow_presentation):
    if 'sjzPresentationChrome' in window:
        return True
    # 系统分享面板：UIActivityViewController 包装，属系统 UI，自带豁免
    if 'ShareSheet(' in window:
        return True
    for rule in allow_presentation:
        fname, _, frag = rule.partition('|')
        if fname.strip() == file_name and frag.strip() and frag.strip() in window:
            return True
    return False


def main():
    allow_font, allow_presentation = load_allowlist()
    violations = []

    for path in sorted(glob.glob(os.path.join(SOURCE_DIR, '*.swift'))):
        name = os.path.basename(path)
        lines = open(path, encoding='utf-8').read().split('\n')
        for i, line in enumerate(lines):
            if is_comment(line):
                continue
            # 规则一：原始字体
            if '.font(' in line and not font_allowed_for(name, line, allow_font):
                violations.append(
                    f'[排版链缺口] {name}:{i + 1}\n    {line.strip()[:110]}\n'
                    f'    → 请改用 displayFont / displayText / displaySymbolFont / displayLabelFont / DisplayFontFactory.font'
                )
            # 规则二：弹出层呈现链
            m = re.search(r'\.(sheet|fullScreenCover)\(', line)
            if m:
                # 判定窗口剔除注释行：防止注释中提及 sjzPresentationChrome()/ShareSheet 稀释真实缺口（2026-09-29 硬化）
                window = '\n'.join(l for l in lines[i:i + 80] if not is_comment(l))
                if not presentation_allowed_for(name, i + 1, window, allow_presentation):
                    violations.append(
                        f'[弹出层缺口] {name}:{i + 1} .{m.group(1)}(...)\n'
                        f'    → 内容根必须挂载 .sjzPresentationChrome()（外观模式 + 专注灰度；系统分享面板 ShareSheet 自带豁免）'
                    )

    if violations:
        print('')
        print('❌ 显示设置覆盖护栏未通过：发现 %d 处绕过显示设置的写法' % len(violations))
        print('   显示设置必须覆盖全 App（字号/家族/粗体/行距/字距/外观/灰度）——新增功能不得绕过。')
        print('   唯一合法出路：接入 display* 排版链 / sjzPresentationChrome()，')
        print('   或在 %s 登记例外并写明理由（如系统组件限制）。' % os.path.relpath(ALLOWLIST_PATH, SRCROOT))
        print('-' * 72)
        for v in violations:
            print(v)
        print('-' * 72)
        return 1

    print('✅ 显示设置覆盖护栏通过：排版链 0 缺口、弹出层呈现链 0 缺口')
    return 0


if __name__ == '__main__':
    sys.exit(main())