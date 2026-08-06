#!/bin/bash
# frames_from_video.sh — 把视频（如 seeDance 生成的二创动画）抽帧为宠物素材
#
# 用法:
#   ./tools/frames_from_video.sh <video.mp4> <action> [fps] [--mirror]
#
# 示例:
#   # 把 dance.mp4 变成 music 动作，12 fps
#   ./tools/frames_from_video.sh dance.mp4 music 12
#
#   # 视频里宠物面朝左，镜像成面朝右
#   ./tools/frames_from_video.sh dance.mp4 music 12 --mirror
#
# 输出: ~/Pictures/BoringPet/<action>/1.png 2.png ...
#
# 依赖: ffmpeg (brew install ffmpeg)
#
# 动作目录: idle walk sleep eat happy hurt drag music home
# 建议: idle 4-8 帧循环; walk 4-8 帧循环; 一次性动作 (eat/happy/hurt) 3-6 帧;
#       所有帧尺寸保持一致 (建议 256x256 ~ 512x512, 背景透明 PNG)。

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "用法: $0 <video.mp4> <action> [fps] [--mirror]" >&2
    exit 1
fi

VIDEO="$1"
ACTION="$2"
FPS="${3:-10}"
MIRROR=""
for arg in "$@"; do
    if [ "$arg" = "--mirror" ]; then
        MIRROR="-vf hflip"
    fi
done

OUT_DIR="${HOME}/Pictures/BoringPet/${ACTION}"

if [ ! -f "$VIDEO" ]; then
    echo "错误: 找不到视频 $VIDEO" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo "抽帧: $VIDEO → $OUT_DIR/ (${FPS} fps)"

# 1. 自动裁剪掉黑边 (cropdetect 会输出最大有效区域)
CROP=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=s=x:p=0 "$VIDEO" | head -1)

# 2. 抽帧: 统一缩放到 512 宽，保持透明通道 (视频一般无 alpha，需自行抠图/绿幕)
ffmpeg -y -i "$VIDEO" -vf "fps=${FPS},scale='min(512,iw)':-2:flags=lanczos${MIRROR}" \
    -start_number 1 "$OUT_DIR/%d.png"

COUNT=$(ls "$OUT_DIR" | wc -l | tr -d ' ')
echo "完成: ${COUNT} 帧已写入 ${OUT_DIR}/"

# 3. 提示更新 config.json
echo ""
echo "提示: 如需调整该动作帧率，编辑 ${HOME}/Pictures/BoringPet/config.json:"
echo "  { \"actions\": { \"${ACTION}\": { \"fps\": ${FPS} } } }"
echo "然后在 设置 → Pet → Re-load skin 生效。"
