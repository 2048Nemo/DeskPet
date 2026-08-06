# Boring Notch 桌面宠物功能 — 设计与改动文档

> 项目：boring.notch（macOS 刘海动态岛应用）
> 功能：在原有 Notch 基础上实现「桌面养宠」（desktop pet）
> 日期：2026-08-03
> 说明：本文档记录所有新增模块、对原项目的修改、关键技术决策与调试过程。

---

## 1. 需求与目标

**用户需求**：克隆 boring.notch，实现桌面养宠功能。

**关键约束（用户明确选择）**：
- 宠物动画核心实现为**序列帧**（frame-by-frame PNG），而不是程序化绘制或 Lottie —— 因为用户计划使用 seeDance 等 AI 生成的萌宠二创视频，抽帧后作为素材。
- 活动区域为**两者结合**：宠物在桌面自由走动，也能「回窝」缩入刘海。
- 玩法包含：状态系统（饱食/心情/清洁）、互动玩法、音乐联动。

**设计原则**：
1. 对原项目侵入最小：新功能全部独立成文件（`components/Pet/`、`managers/PetManager.swift`、`enums/PetState.swift`），只对原文件做少量点状修改。
2. 复用项目既有模式：单例 `ObservableObject` + `@Published`（同 MusicManager/CalendarManager）、`Defaults` 键值存储、`NSPanel` 窗口（同 BoringNotchSkyLightWindow）。
3. 素材可替换：皮肤目录规范 + 工具脚本，用户随时换肤。

---

## 2. 总体架构

```
┌──────────────────────────────────────────────────────────────┐
│ PetManager (singleton @MainActor ObservableObject)            │
│   · 动画状态机：action / facingLeft / currentFrame            │
│   · 宠物属性：hunger / happiness / cleanliness (0-100)        │
│   · 生命周期：lifeState (roaming / atHome) / isDragging       │
│   · 行为 AI：随机走动、打瞌睡、饿了闹脾气                      │
│   · 音乐联动：订阅 MusicManager.isPlaying（轮询）             │
│   · 窗口控制输出：windowPosition / windowAlpha（@Published）  │
│   · 60fps Timer 驱动（animTick）＋ 60s 属性衰减（statTick）    │
└──────────────────┬───────────────────────────────────────────┘
                   │ @Published 订阅
┌──────────────────▼───────────────────────────────────────────┐
│ PetWindowController (singleton)                               │
│   · NSPanel：borderless + nonactivatingPanel，level .floating │
│   · 订阅 windowPosition → setFrameOrigin（每帧跟随）          │
│   · 订阅 windowAlpha → alpha 渐变；归零时 orderOut 彻底隐藏   │
│   · 拖拽时直接 moveWindow（跟随 NSEvent.mouseLocation）       │
└──────────────────┬───────────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────────┐
│ PetContentView (窗口内容，SwiftUI)                            │
│   · PetSpriteView：当前帧 Image + 镜像（facingLeft）          │
│   · 交互：单击（戳+操作面板）/ 双击（回窝/出窝）/ 拖拽（拎起） │
│   · PetActionPanel：自绘操作面板（喂食/抚摸/回窝/状态）       │
└──────────────────────────────────────────────────────────────┘

另外：
· PetHomeView —— 回窝后显示在刘海关闭态的小头像（点击可出窝）
· PetSkin / SpriteAnimator —— 序列帧加载与播放引擎
· tools/ —— 素材生成、抽帧、SPM 验证构建脚本
```

### 数据流示例（完整闭环）

```
用户双击宠物
  → PetContentView.onTapGesture(count:2)
  → PetManager.goHome()
      → movingHome = true; walkTarget = 屏幕顶部中央
  → animTick 每帧：窗口位置向目标移动（walk 动画）
  → 到达 → beginHomeFadeout()（alpha 1→0 渐变）
  → alpha ≤ 0 → lifeState = .atHome
  → PetWindowController sink：orderOut 隐藏窗口
  → ContentView 关闭态分支切换：显示 PetHomeView（刘海头像）
```

---

## 3. 模块设计

### 3.1 `boringNotch/enums/PetState.swift`（新增）

- `PetAction`：`idle / walk / sleep / eat / happy / hurt / drag / music / home` 九种动作，每种带默认帧率与是否循环（`eat/happy/hurt` 一次性播完回 idle，其余循环）。
- `PetLifeState`：`roaming`（桌面活动）/ `atHome`（回窝）。
- `PetFood`：喂食项（🐟鱼/🥛奶/🍪零食/🍰蛋糕），各带饱食/心情恢复值。

### 3.2 `boringNotch/components/Pet/SpriteAnimator.swift`（新增）— 序列帧引擎

- `PetSkinConfig`：解析可选 `config.json`（全局 fps / scale / 每动作 fps 与 loops）。
- `PetSkin`：
  - `locateSkinDirectory()` 三级查找：自定义目录（设置）→ `~/Pictures/BoringPet` → 内置资源。
  - 每个动作扫描子目录 `1.png, 2.png, ...`（`localizedStandardCompare` 自然排序），加载 `NSImage` 帧数组。
  - `home` 动作缺省用 `idle` 首帧兜底；动作缺帧自动跳过（只显示存在的动作）。
- 帧率策略：动作默认值（walk 12fps / music 14fps / idle 6fps 等）可被 config.json 覆盖。

### 3.3 `boringNotch/managers/PetManager.swift`（新增）— 状态中枢

**动画推进（animTick，60fps Timer）**，每帧依次处理：
1. **音乐联动**：`MusicManager.isPlaying` 为真且设置开启 → 切 `music` 动作（素材缺失自动退化为 idle 帧），停止后恢复；
2. **走动/回窝移动**：有 `walkTarget` 时按 70pt/s 向目标推进，逐帧更新 `windowPosition`；到达后回 idle 或进入回窝淡出；
3. **透明度渐变**：回窝淡出（-0.06/帧）/ 出窝淡入（+0.06/帧）；
4. **帧推进**：按动作 fps 推进 `frameProgress`，一次性动作播完回 idle；
5. **行为 AI**（仅 roaming 且无覆盖状态）：`idleCounter` 倒计时结束后按概率决策 —— 走动 55% / 打瞌睡 10% / 待机 35%；**饱食或心情 < 25 时**加权：更容易闹脾气（hurt）、打瞌睡。

**属性系统（statTick，60s）**：
- 饱食度 -1.5/分、清洁度 -0.8/分（受 `petStatDecaySpeed` 倍率影响）；
- 心情缓慢向 50 回归（长时间不理会会低落，被抚摸/喂食拉回）。

**互动 API**：`poke()`（饿了委屈 hurt，否则开心 happy）、`pet()`（+12 心情）、`feed(_:)`（恢复属性 + eat 动画）、`startDrag()/endDrag()`（drag 动画 + 位置同步）、`goHome()/leaveHome()`（含 `movingHome` 防重入 guard）。

**回窝/出窝语义**（经过一次迭代修正）：
- `goHome()`：走回**屏幕顶部中央（刘海正下方）**→ 淡出 → `atHome`；
- `leaveHome()`：**在屏幕下部桌面区**淡入出现（v1 曾放在顶部贴刘海，导致"卡在菜单栏下面"的观感问题，已改为与初始位置一致的桌面区）。

### 3.4 `boringNotch/components/Pet/PetWindow.swift`（新增）— 窗口控制器

- `NSPanel`：`[.borderless, .nonactivatingPanel]`、`level = .floating`、透明背景、无阴影、`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`（全屏可见）。
- 订阅 PetManager 两个 @Published：位置（`setFrameOrigin`，60fps 平滑跟随）与透明度（**alpha ≤ 0 时 `orderOut` 彻底隐藏**，避免透明窗口拦截鼠标；> 0 时 `orderFrontRegardless`）。
- 订阅 `Defaults[.petEnabled]` 变化：设置页开关即时显示/隐藏。
- 窗口尺寸 = 皮肤首帧尺寸 × 用户缩放 × 皮肤 scale（如默认皮肤 256×256）。

### 3.5 `boringNotch/components/Pet/PetContentView.swift`（新增）— 交互层

**交互方案演进**（关键决策）：
- v1 用 SwiftUI `contextMenu`（右键菜单含 Feed 子菜单）→ **实测在 nonactivating 面板上子菜单"闪一下"即消失**（NSMenu 需要窗口激活才能保持，非激活面板无法满足）。
- v2 改为**自绘操作面板**（窗口内 SwiftUI 浮层，完全不涉及 NSMenu）：单击宠物 → 戳一下 + 头顶弹出面板，含 **状态行（😺饱食/💛心情/✨清洁）+ 4 个喂食按钮 + 抚摸 + 回窝**；点面板外关闭。已验证喂食触发 eat 动画。

**完整手势表**：

| 操作 | 行为 |
|---|---|
| 单击 | poke（饿→hurt / 开心→happy）+ 弹出操作面板 |
| 双击 | goHome（回窝）/ leaveHome（出窝） |
| 拖拽（≥3pt） | 拎起挣扎动画，松手放下并同步位置 |
| 点击刘海头像（回窝后） | leaveHome 出窝 |
| 菜单栏 Pet 菜单 | Let pet out / Send pet home |

**PetHomeView**（刘海关闭态头像）：24×24 圆形头像 + 24×24 黑块，**必须固定高度**（曾用 `maxHeight: .infinity` 导致被 640×210 窗口容器拉成 210pt 长条 —— 已修复）。

---

## 4. 素材系统（核心交付）

### 目录规范（详见 `PET.md`）

```
~/Pictures/BoringPet/
├── config.json      可选：{ fps, scale, actions: { idle: { fps, loops } } }
├── idle/1.png ...   待机循环（必备）
├── walk/...         走路循环（必备；只需画一个方向，程序自动镜像）
├── sleep/ eat/ happy/ hurt/ drag/ music/ home/   （可选，缺失用 idle 兜底）
```

### 配套工具

| 工具 | 用途 |
|---|---|
| `tools/frames_from_video.sh` | ffmpeg 视频抽帧：`./tools/frames_from_video.sh dance.mp4 music 12 [--mirror]`，输出到 `~/Pictures/BoringPet/<action>/`。用户用 seeDance 生成的视频经此转换即可换肤 |

---

## 5. 对原项目的修改

### 5.1 功能接入

| 文件 | 修改 |
|---|---|
| `boringNotch/boringNotchApp.swift` | ① AppDelegate 启动时创建宠物窗口（`Defaults[.petEnabled]`），退出时清理；② 菜单栏新增 Pet 菜单项（Let pet out / Send pet home，按 lifeState 动态显示） |
| `boringNotch/models/Constants.swift` | 新增 6 个 Defaults keys：`petEnabled`（默认 true）、`petSkinDirectory`、`petScale`、`petStatDecaySpeed`、`petMusicDance`、`petRoamInterval` |
| `boringNotch/components/Settings/SettingsView.swift` | 新增 "Pet" 设置 tab：启用开关、音乐跳舞开关、尺寸/衰减速度/活动频率选择、皮肤目录选择与重置、皮肤加载状态显示、Re-load skin 按钮 |
| `boringNotch/ContentView.swift` | ① 关闭态显示链新增分支：无音乐 + 宠物回窝 → `PetHomeView`；② 宠物在窝时 hover **不自动打开** notch（否则头像点不到）；③ 订阅 `PetManager.shared` |

### 5.2 顺带修复的原项目缺陷（无 Xcode 验证环境下发现）

| 文件 | 问题 | 修复 |
|---|---|---|
| `helpers/AudioPlayer.swift` | `Bundle.main.url(...)!` 强制解包，资源缺失时 crash | guard 安全解包 |
| `models/Constants.swift` | `Bundle.main.bundleIdentifier!` 强制解包（无 Info.plist 环境 crash） | `?? "theboringteam.boringnotch"` |
| `menu/StatusBarMenu.swift` | 遗留死代码：`override init()` 签名错误（macOS 26 SDK 下 NSMenu 的 `init()` 非 designated）、`#selector` 引用不存在的实例方法 → 新工具链编译失败 | 改为 `init(title:)`、补 `required init(coder:)`、补 `@objc showMenu/quitAction` 自洽实现 |
| `utils/Logger.swift` | `print` 到 stdout，重定向时全缓冲导致日志不可见 | 改输出 stderr（FileHandle，无缓冲） |

---

## 6. 构建与验证方案（本机无 Xcode 的应对）

**环境**：本机仅 Command Line Tools（Swift 6.3），无完整 Xcode → 无法 `xcodebuild`。
**方案**：SwiftPM 包装验证构建（`Package.swift` + `tools/spm_build.sh`），产出可运行的可执行文件。

### 三个环境级障碍与解法

1. **`#Preview` 宏不可用**：CLT 缺少 PreviewsMacros 宏插件，任何含 `#Preview` 的模块编译失败（项目 25 个文件 + KeyboardShortcuts 依赖均含）→ `tools/strip_previews.py` 预处理剥离（`#Preview` 仅影响 Xcode canvas 预览，不影响功能），依赖同样处理。
2. **Sparkle 自动更新死循环**：`SPUStandardUpdaterController(startingUpdater: true)` 在无 Info.plist 环境下陷入死循环**占满主线程**（用 `sample` 采样定位），导致整个 app 冻结、宠物不动、交互失灵（用户最初看到的"9:6 长条"根因之一）→ 验证构建时 `startingUpdater: false`（Xcode 构建不受影响）。
3. **Assets.xcassets 不可编译**：SPM 不生成 `ImageResource` 成员（`.chrome`/`.github` 两处引用）→ 预处理副本中注入 `ImageResourceStubs.swift`。

另外：SwiftPM target path 必须相对包根、`KeyboardShortcuts` 全版本含 `#Preview`（不能简单降版本）、`MainActor.assumeIsolated` 可用等坑均已记录在脚本注释中。

**验证手段**：`CGWindowListCopyWindowInfo` 枚举窗口（layer/alpha/bounds）+ CGEvent 模拟点击 + stderr 日志断言状态机 —— 已在双屏（内置 1512×982 + 外接 4K 1080p 悬挂屏）环境下完整跑通。

---

## 7. 测试结果（实测日志实录）

```
✅ 启动：PetManager init skin=loaded(9 actions) → start
✅ 行为 AI：idle → walk / sleep 循环（窗口位置持续变化）
✅ 双击回窝：goHome → walk 走回屏顶 → 淡出 → 窗口 orderOut 彻底消失
✅ 回窝显示：刘海关闭态出现 24×24 头像（不再有长条）
✅ 点头像出窝：leaveHome → 桌面区淡入 → 恢复走动
✅ 单击 + 面板喂食：poke(happy) → 面板弹出 → 点 🐟 → "Pet action → eat"
✅ 拖拽：drag → idle（位置同步无跳变）
✅ 设置开关：petEnabled=false 时窗口消失
```

---

## 8. 已知问题与未来展望

**已知问题**
1. **多屏不一致**：回窝目的地（宠物所在屏顶部）与 PetHomeView 显示位置（刘海窗口所在屏）可能不同屏（验证机为双屏悬挂布局）。单屏无此问题。改进方向：回窝目标改为刘海窗口所在屏。
2. **音乐联动未实机验证**：代码已就绪（订阅 `MusicManager.isPlaying`），但验证环境无播放器实测；素材 `music/` 缺帧时自动退化为 idle。
3. **AI 视频素材需抠图**：seeDance 视频抽帧后通常是不透明背景，需绿幕/抠图处理成透明 PNG（PET.md 已注明）。
4. **Xcode 构建未实测**：本机无 Xcode。代码按 Xcode 工程兼容性编写（资源引用均为可选、无新依赖），但建议在 Xcode 26 上完整构建一次确认。
5. 属性衰减无常驻 HUD（当前只在操作面板显示）。

**未来展望**
- 宠物属性影响外观/动作频率的深度绑定（胖瘦变化）
- 多宠物/多皮肤切换（素材目录即皮肤包）
- 宠物与系统事件联动（充电时开心、下载完成时好奇张望）
- 序列帧 → 直接支持 GIF/APNG 素材
- 回窝后刘海内宠物小动画（非静态头像）
