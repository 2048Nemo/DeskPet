#!/usr/bin/env python3
"""strip_previews.py — 复制 Swift 源码树并移除 #Preview {...} 宏块。

无 Xcode 的 Command Line Tools 环境缺少 PreviewsMacros 宏插件，
任何包含 #Preview 的模块都无法用 SwiftPM 编译。本脚本用于生成
验证构建用的源码副本（#Preview 仅影响 Xcode canvas 预览，不影响功能）。

用法:
  strip_previews.py <src_dir> <dst_dir>
"""

import os
import re
import sys


def strip_previews(text: str) -> str:
    """删除顶层 #Preview { ... } 块（支持跨行与嵌套括号）。"""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        # 匹配 #Preview 开头的行（#Preview 或 #Preview(...) {）
        if stripped.startswith("#Preview"):
            j = i
            buf = stripped
            # 合并后续行直到出现 '{'
            brace_pos = buf.find("{")
            while brace_pos == -1 and j + 1 < len(lines):
                j += 1
                buf += "\n" + lines[j]
                brace_pos = buf.find("{")
            if brace_pos == -1:
                # 没有 '{'，奇怪的写法，保守地保留
                out.append(line)
                i += 1
                continue
            # 从 brace_pos 之后做括号深度匹配，不足则继续并入后续行
            depth = 0
            started = False
            done = False
            k = brace_pos
            while not done:
                while k < len(buf):
                    ch = buf[k]
                    if ch == "{":
                        depth += 1
                        started = True
                    elif ch == "}":
                        depth -= 1
                        if started and depth == 0:
                            done = True
                            break
                    k += 1
                if done or j + 1 >= len(lines):
                    break
                j += 1
                buf += "\n" + lines[j]
            if done:
                i = j + 1
                continue
            # 未找到闭合括号，保守保留原行
            out.append(line)
            i += 1
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    count = 0
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in (".git", ".build")]
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            dest = os.path.join(dst, rel)
            if name.endswith(".swift"):
                text = open(full, encoding="utf-8").read()
                cleaned = strip_previews(text)
                if cleaned != text:
                    count += 1
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                open(dest, "w", encoding="utf-8").write(cleaned)
            else:
                # 非源码文件（资源、本地化等）原样复制，保证 Bundle.module 等可用
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                import shutil
                shutil.copy2(full, dest)
    print(f"stripped previews in {count} file(s) → {dst}")


if __name__ == "__main__":
    main()
