#!/bin/bash
# spm_build.sh — 无 Xcode（仅 Command Line Tools）环境下用 SwiftPM 做验证构建。
#
# 背景: CLT 缺少 PreviewsMacros 宏插件，#Preview 宏无法解析。
# 本脚本会:
#   1. 剥离源码副本中的 #Preview 块（仅影响 Xcode canvas 预览）
#   2. 对 KeyboardShortcuts 依赖做同样处理
#   3. 在临时目录生成 Package.swift 并构建
#
# 注意: 这只是验证手段，正式构建请用 Xcode 打开 boringNotch.xcodeproj。
#
# 用法: ./tools/spm_build.sh [--run]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/boringNotch-spm"
PYTHON="${PYTHON:-python3}"

# 只清理预处理产物，保留 .build/checkouts 依赖缓存（避免网络波动时反复全量拉取）
rm -rf "$WORK/sources" "$WORK/pkgs"
mkdir -p "$WORK/sources" "$WORK/pkgs"

echo "==> 1/3 剥离源码 #Preview 块"
"$PYTHON" "$ROOT/tools/strip_previews.py" "$ROOT/boringNotch" "$WORK/sources"
# XPC 协议单独目录（SwiftPM 要求 target path 在包内）
mkdir -p "$WORK/xpc"
cp "$ROOT/BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift" "$WORK/xpc/"
# Assets.xcassets 生成的 ImageResource 成员 stub（SPM 不编译 xcassets；仅验证构建用）
cat > "$WORK/sources/ImageResourceStubs.swift" <<'EOF'
import SwiftUI

// SPM 验证构建专用：完整 Xcode 构建中这些成员由 Assets.xcassets 生成
extension ImageResource {
    static let chrome = ImageResource(name: "chrome", bundle: .main)
    static let github = ImageResource(name: "github", bundle: .main)
}
EOF
# 禁用 Sparkle 自动更新：SPM 无 Info.plist 环境下自动更新检查会死循环占满主线程
# （完整 Xcode 构建不受影响）
sed -i '' 's/startingUpdater: true/startingUpdater: false/' "$WORK/sources/boringNotchApp.swift"
echo "    + Sparkle autoupdater disabled (SPM verification only)"

echo "==> 2/3 处理 KeyboardShortcuts 依赖"
KS_SRC="$ROOT/.build/checkouts/KeyboardShortcuts"
if [ ! -d "$KS_SRC" ]; then
    git clone --depth 1 --branch 2.4.0 https://github.com/sindresorhus/KeyboardShortcuts "$KS_SRC"
fi
"$PYTHON" "$ROOT/tools/strip_previews.py" "$KS_SRC/Sources" "$WORK/pkgs/KeyboardShortcuts/Sources" 2>/dev/null || true
cp "$KS_SRC/Package.swift" "$WORK/pkgs/KeyboardShortcuts/"

echo "==> 3/3 生成 Package.swift 并构建"
"$PYTHON" - "$ROOT" "$WORK" <<'PYEOF'
import sys
root, work = sys.argv[1], sys.argv[2]
template = open(f"{root}/Package.swift", encoding="utf-8").read()
# 指向预处理后的源码（相对临时包根）
template = template.replace('path: "boringNotch"', 'path: "sources"')
# XPC 协议 target 指向包内副本
template = template.replace('path: "BoringNotchXPCHelper"', 'path: "xpc"')
# 预处理目录中不存在这些资源，移除 exclude（否则 SwiftPM 报错）
template = template.replace('''            exclude: [
                "Localizable.xcstrings",
                "metal",
                "Assets.xcassets",
            ],
''', '')
# KeyboardShortcuts 改用本地 patch 版
template = template.replace(
    '.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0")',
    f'.package(path: "{work}/pkgs/KeyboardShortcuts")',
)
open(f"{work}/Package.swift", "w", encoding="utf-8").write(template)
print(f"manifest written to {work}/Package.swift")
PYEOF

# 过滤 --run（swift build 不认识该参数），只把其余参数传给 swift build
# 注意：bash 3.2 + set -u 下空数组展开会报 unbound variable，用字符串拼接
RUN_MODE=0
EXTRA_ARGS=""
for arg in "$@"; do
    if [[ "$arg" == "--run" ]]; then
        RUN_MODE=1
    else
        EXTRA_ARGS="$EXTRA_ARGS $arg"
    fi
done

swift build -c release --package-path "$WORK" $EXTRA_ARGS

BIN="$WORK/.build/release/boringNotch"
echo ""
echo "构建成功: $BIN"
if [[ $RUN_MODE == 1 ]]; then
    echo "启动验证…（Ctrl-C 退出）"
    "$BIN"
fi
