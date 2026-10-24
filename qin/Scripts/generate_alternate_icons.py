#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
园枢 App —— 备选应用图标生成器
================================
以主图标（AppIcon.appiconset/AppIcon~ios-marketing.png）为基准，
按 HSV 像素分类（背景 / 蓝柱 / 青描边发光 / 白色高光），
对每类做参数化重着色，生成 4 套「同构异色」备选图标：

  AppIconAlt1 星夜（Neo Night）  —— 深蓝 → 紫罗兰，更加深邃神秘
  AppIconAlt2 晨曦（Sunrise）    —— 暖橙金渐变，呼应品牌金色 #C9A84C
  AppIconAlt3 极简（Frost）      —— 冰感浅底 + 藏蓝柱，浅色壁纸友好
  AppIconAlt4 金典（Gold）       —— 深邃黑蓝底 + 品牌金柱 + 白金箭头

自检：输出 RGB（无 alpha）、直角、1024×1024、主体居中不贴边（构图继承主图标）。
可重复执行：修改 PALETTES 配色参数后重跑即可。
用法：python3 generate_alternate_icons.py [--preview /tmp/out]
"""

import os
import sys
import math
import colorsys

import numpy as np
from PIL import Image

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # qin/
ASSETS = os.path.join(ROOT, "DesignCode", "Assets.xcassets")
SOURCE = os.path.join(ASSETS, "AppIcon.appiconset", "AppIcon~ios-marketing.png")

OUT_DIR = os.path.join(ASSETS)   # 默认直接写入 xcassets；--preview 时改为临时目录

# ----------------------------------------------------------------------------
# 色调映射：pixel → (H, S, V)
# ----------------------------------------------------------------------------
def rgb_to_hsv(arr_rgb_01):
    r, g, b = arr_rgb_01[..., 0], arr_rgb_01[..., 1], arr_rgb_01[..., 2]
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    d = mx - mn
    safe = d > 1e-6
    h_r = np.where(safe, ((g - b) / np.maximum(d, 1e-6)) % 6, 0)
    h_g = np.where(safe, ((b - r) / np.maximum(d, 1e-6)) + 2, 0)
    h_b = np.where(safe, ((r - g) / np.maximum(d, 1e-6)) + 4, 0)
    h = np.where(mx == r, h_r, np.where(mx == g, h_g, h_b))
    h = (h / 6.0) % 1.0                       # 0..1
    s = np.where(mx > 1e-6, d / np.maximum(mx, 1e-6), 0)
    v = mx
    return h, s, v


def hsv_to_rgb(h, s, v):
    """向量化 HSV(0-1) → RGB(0-1)（colorsys 算法的 numpy 版）"""
    h6 = (h * 6.0) % 6.0
    i = h6.astype(np.int32)
    f = h6 - i
    p = v * (1.0 - s)
    q = v * (1.0 - f * s)
    t = v * (1.0 - (1.0 - f) * s)
    r = np.where((i == 0) | (i == 5), v, np.where(i == 1, q, np.where(i == 2, p, np.where(i == 3, p, t))))
    g = np.where(i == 0, t, np.where((i == 1) | (i == 2), v, np.where(i == 3, q, p)))
    b = np.where((i == 2) | (i == 3), v, np.where(i == 4, t, np.where(i == 5, q, p)))
    return np.stack([np.clip(r, 0, 1), np.clip(g, 0, 1), np.clip(b, 0, 1)], axis=-1)


# ----------------------------------------------------------------------------
# 像素分类
# ----------------------------------------------------------------------------
def classify(h, s, v):
    """返回 0=background, 1=blue, 2=cyan, 3=white 的分类图。
    白色高光（箭头/星芒核心）优先；再按明度切背景；前景按色相切蓝/青。"""
    cls = np.zeros_like(v, dtype=np.int8)
    white = (v > 0.86) & (s < 0.30)
    bg = (~white) & (v < 0.42)
    fg = (~white) & (~bg)
    cls[white] = 3
    cls[bg] = 0
    cls[fg & (h >= 0.425) & (h <= 0.555)] = 2     # 青描边 / 发光 / 星芒
    cls[fg & ((h < 0.425) | (h > 0.555))] = 1     # 蓝柱
    return cls


# ----------------------------------------------------------------------------
# 每套配色的类别映射参数
#   每类: {"h": 目标色相(0-1), "s": 饱和度系数/基准, "dv": 明度增量, "invert": 是否反相明度}
# ----------------------------------------------------------------------------
PALETTES = {
    "AppIconAlt1": {  # 星夜 Neo Night：深蓝 → 紫罗兰，与原版明显拉开紫调
        "bg":    {"h": 0.705, "s": 0.68, "dv": -0.050},
        "blue":  {"h": 0.675, "s": 0.95, "dv": 0.000},
        "cyan":  {"h": 0.560, "s": 0.95, "dv": 0.015},
        "white": {"h": 0.640, "s": 0.10, "dv": 0.000},
    },
    "AppIconAlt2": {  # 晨曦 Sunrise：暖橙金，smooth 重建渐变杜绝 banding，暖白箭头
        "bg":    {"h": 0.066, "s": 0.58, "dv": -0.020},
        "blue":  {"h": 0.080, "s": 0.80, "dv": 0.015, "smooth": 18},
        "cyan":  {"h": 0.102, "s": 0.82, "dv": 0.055, "smooth": 18},
        "white": {"h": 0.100, "s": 0.20, "dv": -0.010},
    },
    "AppIconAlt3": {  # 极简 Frost：浅蓝灰底 + 藏蓝柱 + 铜金箭头（暖白描边与柱体物理分离）
        "bg":    {"h": 0.610, "s": 0.08, "dv": 0, "mode": "invert_f", "v_lo": 0.760, "v_hi": 0.850},
        "blue":  {"h": 0.600, "s": 0.66, "dv": 0, "mode": "depth", "v_lo": 0.420, "v_hi": 0.780},
        "cyan":  {"h": 0.520, "s": 0.58, "dv": 0, "mode": "depth", "v_lo": 0.450, "v_hi": 0.820},
        "white": {"h": 0.115, "s": 0.92, "dv": 0, "mode": "flat", "v_out": 0.420},
        "arrowOutline": {"h": 0.120, "s": 0.28, "v": 0.965},
    },
    "AppIconAlt4": {  # 金典 Gold：深邃黑蓝底 + 品牌金柱 + 白金箭头
        "bg":    {"h": 0.645, "s": 0.58, "dv": -0.065},
        "blue":  {"h": 0.120, "s": 0.80, "dv": 0.000, "smooth": 18},
        "cyan":  {"h": 0.125, "s": 0.80, "dv": 0, "smooth": 18, "mode": "depth", "v_lo": 0.500, "v_hi": 0.800},
        "white": {"h": 0.122, "s": 0.10, "dv": 0.000},
    },
}

# 类别 → 说明
CLASS_NAMES = {0: "bg", 1: "blue", 2: "cyan", 3: "white"}


def remap_pixel(h, s, v, params):
    """按类别参数重映射 HSV，保留类内渐变层次"""
    out_h = np.full_like(h, params["h"])
    base_s = params.get("s", 1.0)

    mode = params.get("mode", "keep")

    if mode == "keep":
        # 保留原始明度走势与饱和度层次，仅微调
        out_s = np.clip(s * base_s, 0.05, 1.0)
        out_v = np.clip(v + params.get("dv", 0), 0.0, 1.0)
    elif mode in ("invert_f", "depth"):
        # 将原始 V 压缩映射到 [v_lo, v_hi]（正向或反相均可表达）
        v_lo, v_hi = params["v_lo"], params["v_hi"]
        rng = float(np.percentile(v, 98) - np.percentile(v, 2))
        if rng < 1e-3:
            rng = 1.0
        norm = np.clip((v - float(np.percentile(v, 2))) / rng, 0.0, 1.0)
        if mode == "invert_f":
            norm = 1.0 - norm
        out_v = v_lo + norm * (v_hi - v_lo)
        out_s = np.clip(s * base_s + 0.10, 0.0, 1.0)
    else:  # flat
        out_v = np.full_like(v, params["v_out"])
        out_s = np.full_like(s, base_s)

    return out_h, out_s, out_v


def render_palette(src_h, src_s, src_v, cls, params):
    h_out = np.zeros_like(src_h)
    s_out = np.zeros_like(src_s)
    v_out = np.zeros_like(src_v)
    label_to_idx = {"bg": 0, "blue": 1, "cyan": 2, "white": 3}
    # 整图明度高斯平滑：供标记 smooth 的类别重建平滑渐变，根治 8bit banding
    from PIL import ImageFilter
    v_img = Image.fromarray((np.clip(src_v, 0, 1) * 255).astype(np.uint8), "L")
    v_smooth = np.asarray(
        v_img.filter(ImageFilter.GaussianBlur(radius=18))
    ).astype(np.float32) / 255.0
    for cname, p in params.items():
        if cname not in label_to_idx:
            continue   # 跳过非类别配置键（如 arrowOutline）
        cidx = label_to_idx[cname]
        mask = cls == cidx
        if not np.any(mask):
            continue
        base_v = v_smooth[mask] if "smooth" in p else src_v[mask]
        hh, ss, vv = remap_pixel(src_h[mask], src_s[mask], base_v, p)
        if "smooth" in p:
            # 回填局部高光 / 纹理细节（幅度受原图结构约束）
            vv = np.clip(vv + (src_v[mask] - base_v), 0.0, 1.0)
        h_out[mask] = hh
        s_out[mask] = ss
        v_out[mask] = vv
    # 抗锯齿边缘软化：RGB 域混合不好做，直接 HSV 输出即可（类内已保留渐变）
    rgb = hsv_to_rgb(h_out, s_out, v_out)
    # 可选：给箭头（白色高光类）加亮色描边，与柱体物理分离（arrowOutline）
    outline = params.get("arrowOutline")
    if outline is not None:
        from PIL import ImageFilter
        m = (cls == 3).astype(np.uint8) * 255
        dilated = np.asarray(Image.fromarray(m, "L").filter(ImageFilter.MaxFilter(5))) > 128
        core = m > 128
        ring = dilated & (~core)
        if np.any(ring):
            oh = np.full(rgb.shape[0] * rgb.shape[1], outline["h"]).reshape(rgb.shape[:2])
            os_ = np.full_like(oh, outline["s"])
            ov = np.full_like(oh, outline["v"])
            ring_rgb = hsv_to_rgb(oh, os_, ov)
            rgb[ring] = ring_rgb[ring]
    # 固定种子 film grain：打散渐变色带（banding），幅度 3.2/255，裸眼不可察
    rng = np.random.default_rng(42)
    grain = rng.normal(0, 3.2 / 255.0, rgb.shape)
    arr = (np.clip(rgb + grain, 0, 1) * 255).astype(np.uint8)
    img = Image.fromarray(arr, "RGB").filter(ImageFilter.GaussianBlur(radius=0.6))
    return img


# ----------------------------------------------------------------------------
# 全套尺寸定义（与主图标 Contents.json 完全一致）
# ----------------------------------------------------------------------------
IPHONE_SIZES = [
    ("iphone", "2x", "20x20", 40), ("iphone", "3x", "20x20", 60),
    ("iphone", "1x", "29x29", 29), ("iphone", "2x", "29x29", 58), ("iphone", "3x", "29x29", 87),
    ("iphone", "2x", "40x40", 80), ("iphone", "3x", "40x40", 120),
    ("iphone", "2x", "60x60", 120), ("iphone", "3x", "60x60", 180),
]
IPAD_SIZES = [
    ("ipad", "1x", "20x20", 20), ("ipad", "2x", "20x20", 40),
    ("ipad", "1x", "29x29", 29), ("ipad", "2x", "29x29", 58),
    ("ipad", "1x", "40x40", 40), ("ipad", "2x", "40x40", 80),
    ("ipad", "1x", "76x76", 76), ("ipad", "2x", "76x76", 152),
    ("ipad", "2x", "83.5x83.5", 167),
]
MARKETING = ("ios-marketing", "1x", "1024x1024", 1024)


def filename_for(idiom, scale, size):
    base = "AppIcon" if False else "Icon"
    return None


def write_appiconset(set_name, master, contents_json):
    """按主图标结构输出一个 appiconset"""
    out_root = os.path.join(OUT_DIR, set_name + ".appiconset")
    os.makedirs(out_root, exist_ok=True)
    for idiom, scale, size, px in IPHONE_SIZES + IPAD_SIZES:
        name = f"{size.replace('x', '-')}"
        suffix = f"@{scale.replace('@', '')}" if scale != "1x" else ""
        # 参照主图标命名规则
        label = size.split("x")[0]
        if scale == "1x":
            fn = f"{label}.png"
        else:
            fn = f"{label}@{int(float(scale[0]))}x.png"
        if idiom == "ipad":
            fn = fn.replace(".png", "~ipad.png")
        resized = master.resize((px, px), Image.LANCZOS)
        resized.save(os.path.join(out_root, fn))
    marketing = master.resize((1024, 1024), Image.LANCZOS)
    marketing.save(os.path.join(out_root, "Icon~ios-marketing.png"))
    with open(os.path.join(out_root, "Contents.json"), "w") as f:
        f.write(contents_json)


def contents_json_body(set_name):
    entries = []
    for idiom, scale, size, px in IPHONE_SIZES:
        label = size.split("x")[0]
        fn = f"{label}.png" if scale == "1x" else f"{label}@{int(float(scale[0]))}x.png"
        entries.append((fn, idiom, scale, size))
    for idiom, scale, size, px in IPAD_SIZES:
        label = size.split("x")[0]
        fn = f"{label}.png" if scale == "1x" else f"{label}@{int(float(scale[0]))}x.png"
        fn = fn.replace(".png", "~ipad.png")
        entries.append((fn, idiom, scale, size))
    entries.append(("Icon~ios-marketing.png", "ios-marketing", "1x", "1024x1024"))

    imgs = []
    for fn, idiom, scale, size in entries:
        imgs.append(
            '    {\n'
            f'      "filename" : "{fn}",\n'
            f'      "idiom" : "{idiom}",\n'
            f'      "scale" : "{scale}",\n'
            f'      "size" : "{size}"\n'
            '    }'
        )
    body = ",\n".join(imgs)
    return (
        '{\n'
        '  "images" : [\n'
        f'{body}\n'
        '  ],\n'
        '  "info" : {\n'
        '    "author" : "xcode",\n'
        '    "version" : 1\n'
        '  }\n'
        '}'
    )


# ----------------------------------------------------------------------------
# 预览缩略图（设置页 3 列网格 60pt 显示）
# ----------------------------------------------------------------------------
def write_preview_imageset(name, master):
    out_root = os.path.join(OUT_DIR, name + ".imageset")
    os.makedirs(out_root, exist_ok=True)
    preview = master.resize((180, 180), Image.LANCZOS)
    preview.save(os.path.join(out_root, f"{name}_preview@3x.png"))
    small = master.resize((120, 120), Image.LANCZOS)
    small.save(os.path.join(out_root, f"{name}_preview@2x.png"))
    with open(os.path.join(out_root, "Contents.json"), "w") as f:
        f.write(
            '{\n'
            '  "images" : [\n'
            f'    {{\n      "filename" : "{name}_preview@2x.png",\n'
            '      "idiom" : "universal",\n'
            '      "scale" : "2x"\n'
            '    },\n'
            f'    {{\n      "filename" : "{name}_preview@3x.png",\n'
            '      "idiom" : "universal",\n'
            '      "scale" : "3x"\n'
            '    }\n'
            '  ],\n'
            '  "info" : {\n'
            '    "author" : "xcode",\n'
            '    "version" : 1\n'
            '  }\n'
            '}'
        )


def main():
    preview_only = "--preview" in sys.argv
    if preview_only:
        global OUT_DIR
        out_idx = sys.argv.index("--preview")
        OUT_DIR = sys.argv[out_idx + 1] if out_idx + 1 < len(sys.argv) else "/tmp/icon_preview"
        os.makedirs(OUT_DIR, exist_ok=True)

    print(f"[1/4] 读取主图标: {SOURCE}")
    src = Image.open(SOURCE).convert("RGB")
    print(f"     源尺寸 {src.size}, 模式 {src.mode}")
    arr = np.asarray(src).astype(np.float32) / 255.0
    h, s, v = rgb_to_hsv(arr)
    cls = classify(h, s, v)

    for name, params in PALETTES.items():
        print(f"[2/4] 渲染 {name} ...")
        master = render_palette(h, s, v, cls, params)

        if preview_only:
            path = os.path.join(OUT_DIR, f"{name}.png")
            master.save(path)
            print(f"     预览输出: {path}")
            continue

        write_appiconset(name, master, contents_json_body(name))
        print(f"     已写出全套尺寸到 {name}.appiconset")

    if preview_only:
        print("[3/4] 预览模式：仅输出 4 张 1024 主图")
        return

    # 预览缩略图（主图标 + 4 备选），用于设置页网格
    print("[3/4] 生成设置页预览缩略图 ...")
    previews = {
        "IconPreviewPrimary": src,
    }
    for name in PALETTES:
        p = Image.open(os.path.join(OUT_DIR, name + ".appiconset", "Icon~ios-marketing.png")).convert("RGB")
        previews["IconPreview" + name.replace("AppIconAlt", "Alt")] = p
    for pname, pmaster in previews.items():
        write_preview_imageset(pname, pmaster)
    print("[4/4] 全部完成")


if __name__ == "__main__":
    main()