#!/usr/bin/env python3
"""把官方微博 Logo（红眼 + 橙色信号纹）合成为 iOS App 图标：橙底白眼。
处理流程：
  1. 官方 Logo PNG 抠掉白底 -> 透明
  2. 红眼轮廓 / 橙色信号纹 -> 改白，得到「白眼 + 黑瞳」标记
  3. 合成到官方橙底（顶部偏亮、底部偏暖）圆角方形
  4. 以 1024 为基准渲染，再降采样到各所需尺寸
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw

SRC = "/tmp/weibo_icon_src/sina2.png"
OUT_DIR = os.path.dirname(os.path.abspath(__file__))


def _is_white(p):
    r, g, b, a = p
    return a > 0 and r > 225 and g > 225 and b > 225


def remove_white_bg(img: Image.Image) -> Image.Image:
    """从边界做 BFS，只把「与边界连通的白色像素」变透明。
    眼睛内部白区被红色轮廓包围，不与边界连通，因此被保留。"""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    visited = [[False] * w for _ in range(h)]
    from collections import deque
    dq = deque()
    # 以四周边界的白色像素为种子
    for x in range(w):
        for y in (0, h - 1):
            if _is_white(px[x, y]):
                visited[y][x] = True
                dq.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if _is_white(px[x, y]):
                visited[y][x] = True
                dq.append((x, y))
    while dq:
        x, y = dq.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not visited[ny][nx] and _is_white(px[nx, ny]):
                visited[ny][nx] = True
                dq.append((nx, ny))
    for y in range(h):
        for x in range(w):
            if visited[y][x]:
                px[x, y] = (0, 0, 0, 0)
    return img


def recolor_mark(img: Image.Image) -> Image.Image:
    """红眼轮廓、橙色信号纹 -> 白色；白色内区/高光保留；黑瞳保留。"""
    img = img.convert("RGBA")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            # 红眼轮廓 #D52C2B 附近
            if r > 150 and g < 95 and b < 115 and (r - g) > 55:
                px[x, y] = (255, 255, 255, 255)
            # 橙色信号纹 #FF9933 附近
            elif r > 200 and g > 95 and b < 125 and (r - b) > 80:
                px[x, y] = (255, 255, 255, 255)
            # 其余（白色内区、白色高光、黑色瞳孔）保持不变
    return img


def rounded_square(size, top, bottom):
    """官方微博橙底：竖直渐变 + 圆角（iOS 会再套用超椭圆遮罩，这里圆角仅作兜底）。"""
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = base.load()
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(size):
            px[x, y] = (r, g, b, 255)
    # 圆角遮罩
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * 0.225), fill=255
    )
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out


def build_1024(mark: Image.Image) -> Image.Image:
    size = 1024
    icon = rounded_square(size, top=(255, 138, 0), bottom=(255, 77, 0))
    # 裁剪标记到内容边界
    bbox = mark.getbbox()
    mark_cropped = mark.crop(bbox) if bbox else mark
    mw, mh = mark_cropped.size
    # 标记约占方形 60% 宽
    target_w = int(size * 0.60)
    scale = target_w / mw
    target_h = int(mh * scale)
    # 限制高度不超过 72%
    max_h = int(size * 0.72)
    if target_h > max_h:
        scale = max_h / mh
        target_w = int(mw * scale)
        target_h = int(mh * scale)
    mark_resized = mark_cropped.resize((target_w, target_h), Image.LANCZOS)
    # 居中放置（官方 Logo 的眼偏中下，整体视觉居中即可）
    x = (size - target_w) // 2
    y = (size - target_h) // 2
    icon.paste(mark_resized, (x, y), mark_resized)
    return icon


def main():
    if not os.path.exists(SRC):
        sys.stderr.write(f"source missing: {SRC}\n")
        return 1
    src = Image.open(SRC).convert("RGBA")
    # 超采样标记以提高清晰度
    big = src.resize((src.width * 2, src.height * 2), Image.LANCZOS)
    nobg = remove_white_bg(big)
    mark = recolor_mark(nobg)
    icon1024 = build_1024(mark)
    icon1024.save(os.path.join(OUT_DIR, "icon-1024.png"))

    sizes = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]
    for s in sizes:
        if s == 1024:
            continue
        im = icon1024.resize((s, s), Image.LANCZOS)
        im.save(os.path.join(OUT_DIR, f"icon-{s}.png"))
    print("icon generated:", sizes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
