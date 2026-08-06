# 桌面宠物素材规范（PET.md）

Boring Notch 的桌面宠物使用**序列帧动画**：每个动作是一组编号 PNG 帧，按帧率循环播放。
这套规范让你可以用任何方式制作素材 —— 包括用 seeDance 等 AI 工具生成萌宠视频后抽帧。

## 素材目录

应用按以下优先级查找素材：

1. **自定义目录**（设置 → Pet → Skin folder）
2. **默认目录** `~/Pictures/BoringPet/`
3. 应用内置素材（`BoringPet` 资源）

```
~/Pictures/BoringPet/
├── config.json            ← 可选，全局/按动作配置
├── idle_0/  1.png 2.png … 待机循环变体 0（多个变体时随机切换，让待机不单调）
├── idle_1/  …             待机循环变体 1
├── idle_2/  …             待机循环变体 2（变体数任意）
├── walk_0/  …             走路变体 0
├── walk_1/  …             走路变体 1（活泼/慢悠悠等不同风格）
├── happy_0/ …             开心变体 0（如开心的笑）
├── happy_1/ …             开心变体 1（如被抚摸哼哼）
├── hurt_0/  …             受惊吓变体 0
├── hurt_1/  …             受惊吓变体 1（如耳朵竖起）
├── sleep/   …             睡觉/打瞌睡（循环）
├── drag/    …             被拎起挣扎（循环，拖拽期间）
├── fall/    …             掉落/出场（一次性；缺失时用 drag 帧兜底）
└── home/    …             回窝后刘海里的头像（可选，缺省用 sleep 最后一帧，睡着的样子）
```

> **变体目录命名**：`<动作>_<数字>`（如 `idle_0`、`idle_1`、`walk_0`），引擎自动归并到同一动作。
> 同一动作播放时随机选一个变体；待机每隔一段时间会主动切换变体。
> 至少需要 `idle_0/`（或 `idle/`）和 `walk_0/`（或 `walk/`），其他动作缺失时宠物会用兜底帧表现。

## config.json

```json
{
  "fps": 8,                        // 全局默认帧率
  "scale": 1.0,                    // 皮肤整体缩放
  "actions": {
    "idle":  { "fps": 6 },
    "eat":   { "fps": 10, "loops": 1 },
    "walk":  { "fps": 12 }
  }
}
```

- `fps`：每秒帧数（默认：idle/sleep 6，walk 12，music/drag 14，其余 10）
- `loops`：`-1` 无限循环（默认）；`>=1` 播放 N 遍后停在最后一帧
- 一次性动作（eat/happy/hurt）播完自动回到 idle

## 素材要求

- **PNG**，一个动作的所有帧尺寸必须一致（推荐 256×256 ~ 512×512）
- **透明背景**（PNG RGBA）
- 帧文件按名称自然排序（`1.png, 2.png, …, 10.png`）
- 走路动画只需画一个方向（如朝右），宠物向左走时应用会自动镜像

## ⚠️ 视频导出必须带 Alpha 通道（重要）

`tools/video_to_frames.swift` 会自动检测视频有没有 alpha：

- **有真 alpha**（如 HEVC with Alpha、带 alpha 的 ProRes 4444）→ 直接用，质量最佳
- **没有 alpha**（很多 Premiere 导出是这种情况！）→ 自动按背景色做**软边缘抠图 + 空洞回填**（可接受，但边缘不如真 alpha 干净）

**Premiere 导出带透明的正确姿势：**

1. 序列本身是透明背景（如在透明背景上做的动画/抠好的素材）
2. 导出 → Media → Format 选 **QuickTime** → Video Codec 选 **Apple ProRes 4444**（或 HEVC + Alpha）
3. **必须勾选 "Include Alpha"（渲染 Alpha 通道）** —— 不勾选时 4444 是 24-bit 实底，背景被压成黑
4. 导出后可用 `tools/check_alpha.swift`（或 Finder 预览）确认：
   - 导出文件属性里显示 32-bit 而不是 24-bit
   - 背景在播放器里显示棋盘格

> 判断技巧：无 alpha 的 4444 文件在格式描述里 `Depth = 24`；带 alpha 的是 32。
> 如果视频已经是黑底实底，不需要重新导出 —— 工具会自动抠黑底（默认）或 `--key R,G,B,tol` 抠其他纯色。

## 从视频生成素材（seeDance 等 AI 视频）

```bash
# 1. 安装 ffmpeg
brew install ffmpeg

# 2. 把 AI 生成的舞蹈视频转成 music 动作（12 fps）
./tools/frames_from_video.sh dance.mp4 music 12

# 3. 视频里宠物朝左，需要镜像
./tools/frames_from_video.sh dance.mp4 walk 10 --mirror

# 4. 在 设置 → Pet → Re-load skin 生效（或重启应用）
```

> 注意：AI 视频通常背景不透明，需要先用绿幕/抠图工具（如 Remove.bg、剪映）处理成透明 PNG 序列，
> 或用同色背景视频让宠物看起来像"贴纸"。透明通道直接用会显示方框背景。

## 动作触发时机

| 动作 | 触发条件 |
|---|---|
| idle | 默认状态 |
| walk | 行为 AI 随机走动 / 走向目标点（双击回窝路上） |
| sleep | 行为 AI（心情低时更频繁） |
| happy | 单击戳（心情好时）/ 操作面板 → 抚摸 |
| hurt | 单击戳（心情差时） |
| drag | 按住拖拽 |
| music | 音乐播放中（地面活动时；设置 → Pet → Dance while music is playing） |
| fall | 出场（从刘海出窝掉落）/ 被打断掉落（落地弹跳） |
| home | 回窝后，刘海关闭态的小头像 |

## 交互说明

- **单击**：戳一下（心情好开心蹦一下，心情差委屈）并弹出操作面板（状态/抚摸/回窝）
- **双击**：回窝（走回刘海并淡入） / 出窝（从刘海掉落回桌面）
- **拖拽**：拎起来（挣扎动画），松手放下
- 宠物会随时间脏（清洁度），心情会缓慢回落；操作面板 → 抚摸可恢复心情
- 操作面板顶部实时显示属性（😺 心情 / ✨ 清洁度）
