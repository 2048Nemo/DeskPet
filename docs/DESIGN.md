# Boring Notch 桌面宠物功能 — 设计与改动文档

> 项目：boring.notch（macOS 刘海动态岛应用）
> 功能：在原有 Notch 基础上实现「桌面养宠」（desktop pet）
> 日期：2026-08-03（初稿） / 2026-08-07（迭代修订）
> 说明：本文档记录所有新增模块、对原项目的修改、关键技术决策与调试过程。
> 注意：早期章节（§3-§7）描述的是初版实现；自 2026-08-07 起多次迭代后，缓存策略、掉落动画、
> 交互入口等已有重大变更，**以 §9「迭代修订记录」为最新实现依据**。

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

---

## 9. 迭代修订记录（2026-08-07 起，以本节为最新实现依据）

### 9.1 待机变体轮换（idle 4 套动画循环播放）

**问题**：`prefetch` 只加载每个动作的第一个变体（省内存），导致 `preferredVariant` 永远从「已缓存」中选 → 只返回变体 0 → 一直播同一套待机动画。

**修复**（`SpriteAnimator.swift`）：
- `prefetch` 对 `.idle` 特判：加载**全部变体**的 trailer 帧（4 变体 × 24 帧 ≈ 36MB，可接受）；
- 其余动作仍只加载单变体（省内存，`preferredVariant` 优先已缓存保证零延迟）；
- 启动时同步加载 idle 变体 0（立刻可显示），其余变体由 prefetch 异步补齐；
- `setAction(.idle)` 的预取列表也加入 `.idle`，保证轮换素材常驻。

**效果**：待机时 4 套动画随机轮换，不再单调。

### 9.2 动作朝向（facing）机制

**不分析素材内容**，约定所有素材默认朝右，运行时按目标方向镜像：
- `updateFacing(toward:)`：`facingLeft = target.x < position.x`（目标在左→朝左）；
- 渲染时 `scaleEffect(x: facingLeft ? -1 : 1)` 水平镜像（`PetContentView.swift`）；
- 走路 / 回窝都会先调用 `updateFacing`。素材只需画一个方向，向左走自动翻转。

### 9.3 掉落动画（fall）完善

**问题演进**：
1. 物理掉落（gravity=1600）~1 秒就落地，fall 动画 105 帧（4.4s）只播 1/4 被切断；
2. `land()` 落地立即 `setAction(.idle)`，掉落动画后半段（落地→站立）永远播不出来；
3. `loopsByDefault` 里 fall 未列入一次性动作 → **被当成循环动画**，出窝后一直播掉落。

**修复**（`PetManager.swift` / `enums/PetState.swift`）：
- `gravity` 1600 → 500（掉落 ~1.8s，动画能播到 ~40%）；
- `land()` 落地只停止物理运动，**不切 idle**——fall 动画继续播完剩余帧（站立姿态），由 animTick 一次性动作播完逻辑自然衔接 idle；
- `loopsByDefault` 的 false 列表加入 `.fall`（一次性动作，播完回 idle）；
- 弹跳阈值 220→300、衰减 35%→25%（低重力下避免多次弹跳）。

**最终效果**：出窝 = 掉落 → 物理落地 → 站立 → 自然衔接待机。

### 9.4 出窝初始位置（用户多轮调试确认）

`leaveHome()` 初始 y：`maxY - inset - size.height + 200`（**200pt 为最终确认值**）。
宠物顶部超出屏幕顶 200pt，从屏幕顶端「探出」再掉落，有完整入画效果。
真刘海屏仍下移 `inset` 避开物理遮挡。

### 9.5 部分帧预缓存 + 流式补齐（内存优化核心）

**背景**：全量预取 813 帧 ≈ 490MB（实测），内存过高。

**方案**（`SpriteAnimator.swift`）：
- **位图/签名分离**：预缓存时每动作只解码前 `trailerFrameCount`（24 帧 = 1 秒 @24fps）位图（贵，0.38MB/帧）；
  全部帧签名（32px，2KB/帧）全量计算——保证 `loopPoint` 无缝循环正确；
- **流式补齐** `backfillIfNeeded`：播放进度距缓存末尾 ≤8 帧时，后台解码下一批（24 帧）追加到缓存数组；
  解码 7-10ms/帧 vs 播放 41.7ms/帧，解码比播放快 4-6 倍，永不卡顿；
- **启动同步加载** idle 变体 0 的 trailer 帧（立刻可显示），剩余异步补齐；
- 一次性动作播完判断改用 `totalFrameCount`（素材总帧数），不能用缓存帧数（否则 happy 没播完就回 idle）。

### 9.6 降采样精度（640 → 300px）

`maxPixelSize = min(300, max(256, targetPixel))`：
- 宠物显示 90pt（视网膜 180px），300px 是 1.7 倍采样，清晰度足够；
- 单帧 1.14MB → 0.38MB，整体内存降 ~70%。

### 9.7 skip-unchanged-frame（CPU 优化）

**问题**：24fps 动画 + 60fps tick，每 tick 都赋值 `currentFrame`（同一帧）→ 触发 60 次/秒 SwiftUI 重绘。

**修复**（`PetManager.swift` animTick）：`if idx != lastFrameIndex` 才赋值 `currentFrame`。
**效果**：CPU 8-12% → ~0%（实测）。

### 9.8 回窝节能（trimToHomeOnly）

**问题**：回窝后活动动作帧仍常驻，且 trim 后迟到的后台预取把帧填回（实测回窝后仍 500MB）。

**修复**：
- `trimToHomeOnly()`：回窝（fadeout 完成 → atHome）时清空所有活动动作缓存，只保留 `.home` + `.fall`（出窝动画），内存 → ~120MB；
- **homeOnlyMode 标志**：storeLoaded/storePartialLoaded/appendFrames 都检查，回窝期间拒绝非 [home, fall] 入缓存（含播放加载）；
- fadeout 完成后 `setAction(.home)` 而非 `.idle`（否则 animTick 每帧请求 idle 帧触发播放加载绕过拦截）；
- `setAction(.idle)` 预取加 `lifeState == .roaming` 守卫（atHome 不预取）。

### 9.9 循环淘汰 bug 修复（walk 切换延迟根因）

**问题**：`storeLoaded` 预取淘汰用 `!played` 判断 keep 集，播放过的 walk/yawn 被排除 → 同批次预取互相挤掉 → 下次切换重新解码（1.4-2s 延迟，窗口已动动画未开始）。

**修复**：新增 `prefetched` 集合记录当前预取列表，淘汰时 `keep = coreActions ∪ prefetched ∪ [action]`——预取列表内的动作无论是否播放过都保留。

### 9.10 拖拽投放刘海（拖宠物到刘海 → 打开 Pet 页）

**交互**（用户确认）：
- 触发区 = 刘海展开区（`openNotchSize` 640×190，屏幕顶部居中）；
- 拖拽悬停进入区域 → 刘海立即展开到 **Pet 页**（与拖文件到刘海打开 Shelf 同语义）；
- 松手在区域 → 瞬间进窝（`snapHome`，无走回动画，直接定位+淡出）。

**实现**：
- `PetManager.evaluateNotchDropHover(at:)`：DragGesture.onChanged 每帧调用，命中区域（首次）发 `.openNotchToPet` 通知 + `elevateLevel()`（宠物窗口提到 `.mainMenu+4`，盖在刘海 `.mainMenu+3` 之上，拖拽全程可见）；
- `AppDelegate` 监听通知 → `vm.open()` + `coordinator.currentView = .pet`；
- 松手 `exitNotchDropHover()` → `snapHome()` + `restoreLevel()`；
- ContentView 4 处关闭逻辑加 `!petManager.isHoveringNotchDropZone` 抑制——拖拽悬停期间刘海不被自动关闭（宠物遮挡 hover 也不怕）；
- 窗口层级：`PetWindowController.elevateLevel()/restoreLevel()`。

### 9.11 音效音量滑块（Pet 页内）

- 新增 `Defaults[.petSoundVolume]`（0-1，默认 0.7），独立于系统音量；
- `playSound` 用设置值替代硬编码 0.7；`updateSoundVolume()` 拖动时实时生效；
- PetNotchView 右侧面板底部加 🔊 滑块（step 0.05，百分比显示）。

### 9.12 活动频率自定义

- 预设档：Hyper(5s) / Normal(10s) / Calm(15s) / Chill(30s)；
- **Custom…**：枚举 `RoamPreset` 驱动 Picker（修复动态 tag 选不中的 bug），选 Custom 展开滑块 3-60s 精确调节；
- footer 说明：频率越低越省内存/CPU，越高越活泼。

### 9.13 音效重复播放 bug 修复（早期）

- idle 变体切换（forceReshuffle）不重播音效；
- idle/home 循环动作静音（素材带背景音乐，循环重播会一直响）；
- 切到无声动作时总是先 `stopSound()`；
- `playSound` 异步创建 NSSound（首载阻塞主线程 ~0.4s）。

### 9.14 音乐联动冻结 bug（宠物不走动根因）

**问题**：`petMusicDance`（默认开）+ 系统任意播放（如 Edge 直播）→ 宠物切 `.music` 动作；无 music 素材时兜底显示 idle 帧，但 `action == .music ≠ .idle` → 行为 AI 永不决策 → **宠物永久站桩**。

**修复**：`PetSkin.hasRealMaterial(.music)`（区分真实素材与兜底），无跳舞素材时不进入 music 动作。加状态日志（`[Pet]` 每 5s）便于诊断。

### 9.15 Pet 页布局

- 与 Home/Shelf 同布局：`HStack(alignment: .top, spacing: 15)`，左侧 90×90 宠物卡片 + 右侧 215 信息面板；
- **不加** `frame(maxWidth/maxHeight: .infinity)`（曾导致贴左上角）——父容器 VStack 自然水平居中、内容靠上；
- 打开态容器 `mainLayout.frame(height: notchSize.height)` 固定高度（ContentView.swift:122）。

---

## 10. 当前性能指标（2026-08-07 实测）

| 指标 | 优化前 | 优化后 |
|------|--------|--------|
| 内存（roaming 稳定） | ~484MB | **~190MB** |
| 内存（启动） | ~339MB | **~150MB** |
| 内存（回窝 atHome） | ~470MB | **~120MB** |
| CPU | 8-12% | **~0%** |
| 单帧位图 | 1.14MB (640px) | **0.38MB (300px)** |

关键组合：300px 降采样 + 24 帧/动作部分预缓存 + 流式补齐 + skip-unchanged-frame + 回窝 trim。

