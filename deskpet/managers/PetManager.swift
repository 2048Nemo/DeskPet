//
//  PetManager.swift
//  boringNotch
//
//  桌面宠物状态中枢：动画状态机、属性系统、行为 AI、互动 API、音乐联动。
//  窗口控制器（PetWindowController）订阅 windowPosition / windowAlpha 来驱动窗口。
//

import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

/// 宠物运动模式（小把戏状态机）
enum PetMovementMode {
    /// 地面活动（idle/walk/sleep/music）
    case floor
    /// 走向屏幕边缘（准备爬墙）
    case approachingEdge
    /// 垂直爬墙（沿屏幕左右边缘向上）
    case climbing
    /// 顶部倒挂
    case hanging
    /// 自由落体（被打断/松手）
    case falling
    /// 走向 Dock（准备上 Dock 玩）
    case goingToDock
    /// 在 Dock 表面左右爬行（"阶梯"上往复）
    case dockCrawl
    /// 走向目标 APP 窗口边缘（准备攀爬）
    case goingToWindow
    /// 沿 APP 窗口边缘垂直攀爬
    case windowClimb
    /// 窗口顶边倒挂
    case windowHang
}

@MainActor
final class PetManager: ObservableObject {
    static let shared = PetManager()

    // MARK: - 动画状态（PetSpriteView 订阅）
    @Published private(set) var action: PetAction = .idle
    @Published private(set) var facingLeft = false
    @Published private(set) var currentFrame: NSImage?
    /// 晕眩时的旋转角（0-360，animTick 逐帧累加，让宠物原地转圈）
    @Published private(set) var dizzyAngle: Double = 0

    // MARK: - 宠物属性（0-100）
    @Published private(set) var happiness: Double = 100
    @Published private(set) var cleanliness: Double = 100

    // MARK: - 生命周期
    @Published private(set) var lifeState: PetLifeState = .roaming
    @Published private(set) var isDragging = false

    // MARK: - 窗口控制（PetWindowController 订阅）
    @Published var windowPosition: CGPoint?
    @Published var windowAlpha: Double = 1

    /// 当前是否正悬停在"刘海投放区"（拖拽中）。用于去重 + 决定松手后是否保持刘海打开。
    /// 由 PetContentView 拖拽时每帧调用 evaluateNotchDropHover 更新。
    @Published private(set) var isHoveringNotchDropZone = false

    // MARK: - 皮肤
    private(set) var skin: PetSkin?

    /// 窗口尺寸 = 首帧尺寸 × 用户缩放 × 皮肤 scale
    var windowSize: CGSize {
        guard let base = skin?.baseFrameSize else { return CGSize(width: 120, height: 120) }
        let scale = Defaults[.petScale] * (skin?.scale ?? 1)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    /// 是否正在回窝途中（走回/淡出阶段，供外部判断：此时也不该被 hover 打开 notch）
    var isHomeTransitioning: Bool {
        movingHome
    }

    // MARK: - 拖拽投放刘海（拖宠物到刘海展开区 → 打开 Pet 页）

    /// 刘海展开区（与 DragDetector 的 notchRegion 同算法）：homeScreen 顶部居中的
    /// openNotchSize（640×190）矩形。拖宠物进入该区域即触发"打开刘海到 Pet 页"。
    private func notchDropRegion() -> CGRect? {
        guard let screen = homeScreen() else { return nil }
        let f = screen.frame
        return CGRect(
            x: f.midX - openNotchSize.width / 2,
            y: f.maxY - openNotchSize.height,
            width: openNotchSize.width,
            height: openNotchSize.height
        )
    }

    /// 拖拽期间每帧调用：判定鼠标是否进入刘海展开区。
    /// - 进入（首次）：提级宠物窗口（盖在刘海之上，拖拽全程可见）+ 发 .openNotchToPet 通知
    ///   （AppDelegate 打开刘海 + 切 Pet 页）。
    /// - 离开：恢复宠物窗口层级。刘海的关闭由 ContentView 读取 isHoveringNotchDropZone
    ///   统一抑制（拖拽悬停期间不关闭），避免提级遮挡 hover 导致的"打开后立即关闭"。
    func evaluateNotchDropHover(at point: CGPoint) {
        let inside = notchDropRegion()?.contains(point) ?? false
        if inside, !isHoveringNotchDropZone {
            isHoveringNotchDropZone = true
            // 提级：宠物盖在刘海窗口（.mainMenu+3）之上，拖拽全程可见
            PetWindowController.shared.elevateLevel()
            // 通知 AppDelegate 打开刘海并切到 Pet 页（携带屏幕 UUID 支持多屏）
            let uuid = BoringViewCoordinator.shared.selectedScreenUUID
            NotificationCenter.default.post(name: .openNotchToPet, object: uuid.isEmpty ? nil : uuid)
            Logger.log("Pet drag entered notch drop zone — opening Pet view", category: .ui)
        } else if !inside, isHoveringNotchDropZone {
            isHoveringNotchDropZone = false
            PetWindowController.shared.restoreLevel()
            Logger.log("Pet drag left notch drop zone", category: .ui)
        }
    }

    /// 拖拽松手后调用。
    /// - 若松手时仍在刘海投放区内：瞬间进窝（snapHome，无走回动画），刘海保持打开。
    /// - 否则：仅恢复窗口层级，宠物在松手位置落地。
    /// 返回 true 表示触发了进窝（调用方据此决定后续，如不再做落地动画）。
    @discardableResult
    func exitNotchDropHover() -> Bool {
        guard isHoveringNotchDropZone else { return false }
        isHoveringNotchDropZone = false
        // 进窝前先恢复窗口层级：宠物即将淡出消失，不再需要盖在刘海之上；
        // 且层级恢复后刘海窗口能正常接收 hover，松手后鼠标在刘海区域内 → 刘海保持打开，
        // 鼠标移出 → 由 ContentView 现有 hover 逻辑自动关闭。
        PetWindowController.shared.restoreLevel()
        // 松手在刘海区域内 → 瞬间归位进窝（跳过走回动画）
        snapHome()
        Logger.log("Pet dropped on notch — snapped home", category: .lifecycle)
        return true
    }

    /// 回窝/出窝目标屏：优先刘海窗口所在屏（selectedScreenUUID），保证宠物与刘海头像同屏；
    /// 兜底用宠物当前所在屏 / 主屏。
    private func homeScreen() -> NSScreen? {
        let uuid = BoringViewCoordinator.shared.selectedScreenUUID
        if !uuid.isEmpty, let screen = NSScreen.screen(withUUID: uuid) {
            return screen
        }
        return currentScreen
    }

    /// 目标屏的顶部物理遮挡（真刘海高度；无刘海屏为 0）。
    /// 真刘海屏上宠物回窝/出窝必须下移到该高度之下，否则会被物理刘海遮挡。
    private func notchTopInset(_ screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }

    /// 某动作可用帧（由 PetSkin 处理：缓存/后台加载/兜底动作）
    /// 当前动作的选定变体索引（setAction 时随机一次并固定，动画循环中不重抽）
    private var currentVariant: Int = 0
    /// 最近一帧的帧索引（记录供未来跨动作过渡使用）
    private var lastFrameIndex: Int = 0

    /// 某动作可用帧（由 PetSkin 处理：缓存/后台加载/兜底动作）
    private func frames(for action: PetAction) -> [NSImage]? {
        skin?.frames(for: action, variant: currentVariant)
    }

    // MARK: - 内部状态
    private var animTimer: Timer?
    private var statTimer: Timer?
    private var frameProgress: Double = 0
    private var tickCount: Int = 0
    private var idleCounter: Double = 4
    private var walkTarget: CGPoint?
    private var movingHome = false
    private var fading = false
    private var wasMusicPlaying = false
    /// 睡觉编排：先打哈欠，哈欠播完后置位 → 自动进入睡眠（自然过渡）
    private var pendingSleep = false
    /// 睡眠维持剩余秒数：睡眠动画播完后保持睡着（冻结末帧）再醒来
    private var sleepHoldRemaining: Double = 0
    private let walkSpeed: CGFloat = 70
    private let tick: Double = 1.0 / 60.0

    // MARK: 小把戏（爬墙/倒挂/掉落）
    private var movementMode: PetMovementMode = .floor
    /// 爬墙速度（pt/s）
    private let climbSpeed: CGFloat = 42
    /// 重力加速度（pt/s²）。
    /// 调低以匹配 fall 动画时长：fall 素材 105 帧 × 24fps = 4.4 秒，
    /// gravity=1600 时掉落仅 ~1 秒就落地，动画只播 1/4 就被切断。
    /// gravity=500 时掉落 ~1.8 秒，fall 动画能播到 ~40%，体感自然不仓促。
    private let gravity: CGFloat = 500
    /// 掉落当前速度（pt/s，向上为正）
    private var fallVelocity: CGFloat = 0
    /// 倒挂剩余秒数
    private var hangTimer: Double = 0
    /// 晕眩剩余秒数
    private var dizzyTimer: Double = 0

    private init() {
        skin = PetSkin.load()
        if skin == nil {
            Logger.log("Pet skin not found — falling back to placeholder rendering", category: .warning)
        }
        Logger.log("PetManager init done, skin=\(skin != nil ? "loaded(\(skin!.availableActions.count) actions)" : "nil")", category: .lifecycle)
    }

    // MARK: - 生命周期

    func start() {
        guard animTimer == nil else { return }
        Logger.log("PetManager start (skin=\(skin != nil ? "ok" : "nil"))", category: .lifecycle)
        if windowPosition == nil {
            windowPosition = initialRoamingPosition()
        }
        animTimer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animTick() }
        }
        // 关键：必须挂到 .common 模式。NSPanel 拖拽期间主线程运行在 .eventTracking 模式，
        // 只挂 .default 的定时器会被完全暂停 —— 表现为"拖拽时动画不切换"
        RunLoop.main.add(animTimer!, forMode: .common)
        statTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statTick() }
        }
    }

    func stop() {
        animTimer?.invalidate()
        animTimer = nil
        statTimer?.invalidate()
        statTimer = nil
    }

    /// 重新扫描素材目录（设置页手动触发）
    func reloadSkin() {
        skin = PetSkin.load()
        action = .idle
        frameProgress = 0
        currentFrame = nil
        if skin == nil {
            Logger.log("Pet skin not found — falling back to placeholder rendering", category: .warning)
        }
    }

    /// 随机重置待机计时（走动频率基于设置）
    private func resetIdleCounter() {
        let base = max(1.5, Defaults[.petRoamInterval])
        idleCounter = Double.random(in: base * 0.6...base)
    }

    // MARK: - 每帧动画推进（60fps tick）

    private func animTick() {
        tickCount += 1

        // 1. 音乐联动：仅地面活动时跳舞（爬墙/倒挂/掉落/晕眩期间不打断小把戏）
        // 必须有真实跳舞素材才激活——否则切到 .music 只会显示 idle 兜底帧，
        // 且 AI 决策（要求 action == .idle）被冻结，宠物会一直站着不走动
        if Defaults[.petMusicDance] && (skin?.hasRealMaterial(.music) ?? false)
            && MusicManager.shared.isPlaying && movementMode == .floor {
            if !wasMusicPlaying {
                wasMusicPlaying = true
                walkTarget = nil
                setAction(.music)
            }
        } else if wasMusicPlaying {
            wasMusicPlaying = false
            if !isDragging && !movingHome {
                setAction(.idle)
                resetIdleCounter()
            }
        }

        // 2. 移动：走路 / 掉落（按运动模式分发）
        // 兜底：回窝途中目标丢失（被任何路径打断）→ 复位回窝状态，避免 movingHome 永久卡死
        if movingHome && walkTarget == nil && !fading {
            movingHome = false
            Logger.log("Pet home-trip interrupted — reset", category: .warning)
        }
        switch movementMode {
        case .floor:
            if let target = walkTarget, !isDragging, !wasMusicPlaying, (lifeState == .roaming || movingHome) {
                var position = windowPosition ?? initialRoamingPosition()
                let dx = target.x - position.x
                let dy = target.y - position.y
                let distance = hypot(dx, dy)
                let step = walkSpeed * (1.0 / 60.0)

                if distance <= step {
                    windowPosition = target
                    walkTarget = nil
                    if movingHome {
                        Logger.log("walk arrived at home target → fadeout", category: .debug)
                        beginHomeFadeout()
                    } else {
                        setAction(.idle)
                        resetIdleCounter()
                    }
                } else {
                    position.x += dx / distance * step
                    position.y += dy / distance * step
                    windowPosition = position
                }
            }
        case .falling:
            // 重力自由落体（被打断掉落 / 出窝从刘海掉下来）
            fallVelocity += gravity * CGFloat(tick)
            var position = windowPosition ?? initialRoamingPosition()
            position.y -= fallVelocity * CGFloat(tick)
            // 落地上限用 visibleFrame（排除 Dock/菜单栏区域）：
            // frame.minY 位于 Dock 后面，宠物会掉进 Dock 区域被盖住、无法拖出（issue #10）
            let floorY = (currentScreen?.visibleFrame.minY ?? 0) + windowSize.height * 0.06
            if position.y <= floorY {
                position.y = floorY
                windowPosition = position
                land()
            } else {
                windowPosition = position
            }
        case .approachingEdge, .climbing, .hanging, .goingToDock, .dockCrawl, .goingToWindow, .windowClimb, .windowHang:
            // 遗留模式（不再触发），安全回落到地面状态
            movementMode = .floor
            setAction(.idle)
            resetIdleCounter()
        }

        // 3. 透明度渐变（回窝淡出 / 出窝淡入）
        if fading {
            let next = windowAlpha + (movingHome ? -0.06 : 0.06)
            if movingHome, next <= 0 {
                windowAlpha = 0
                fading = false
                lifeState = .atHome
                movingHome = false
                Logger.log("fadeout done → atHome", category: .debug)
                // 回窝后切 .home（显示睡眠姿势），不是 .idle。
                // 若用 .idle，animTick 每帧请求 idle 帧会触发播放加载（isPrefetch=false），
                // 绕过 homeOnlyMode 拦截，把刚 trim 清掉的 idle（170帧≈194MB）又加载回来。
                // .home 仅 1 帧，且 homeOnlyMode 允许加载，内存可控。
                setAction(.home)
                // 回窝节能：卸载所有活动动作帧，只保留 .home + .fall（出窝动画）。
                skin?.trimToHomeOnly()
            } else if !movingHome, next >= 1 {
                windowAlpha = 1
                fading = false
                lifeState = .roaming
                Logger.log("fadeout aborted → roaming (movingHome cleared during fade)", category: .warning)
                setAction(.idle)
                resetIdleCounter()
            } else {
                windowAlpha = next
            }
        }

        // 4. 帧推进
        guard let frames = frames(for: action), !frames.isEmpty else {
            // 素材在后台加载中（hasMaterial=true）时保持上一帧，不闪占位；
            // 真正缺素材才显示占位
            if skin?.hasMaterial(action) != true {
                if tickCount % 120 == 0 {
                    Logger.log("animTick: no frames for action=\(action.rawValue), skin=\(skin != nil ? "ok" : "nil")", category: .debug)
                }
                currentFrame = nil
            }
            return
        }
        let count = frames.count
        let total = skin?.totalFrameCount(action, variant: currentVariant) ?? count
        let fps = skin?.fps[action] ?? action.defaultFPS
        let isLoop = (skin?.loops[action] ?? (action.loopsByDefault ? -1 : 1)) < 0
        frameProgress += tick * fps

        if isLoop {
            // 组内无缝循环：第一轮播完整 0..末帧（含"站立→起步"段），
            // 之后在 [loopPoint, 末帧] 区间循环——loopPoint 是签名匹配出的
            // "与末帧姿势最接近的帧"，绕回时不再跳回第 0 帧。
            // 注意：部分帧缓存时 count 可能 < total，循环用 count（已缓存帧），
            // 流式补齐会持续追加，count 会增长到 total。
            let loopPoint = skin?.loopPoint(for: action, variant: currentVariant) ?? 0
            // 部分帧缓存时（count < total）不用 loopPoint——loopPoint 是用全量签名算的，
            // 可能 > count，直接用会越界。等流式补齐全（count == total）后才启用无缝循环。
            let idx: Int
            if count >= total, loopPoint > 0, frameProgress >= Double(count) {
                idx = loopPoint + Int(frameProgress - Double(count)) % (count - loopPoint)
            } else {
                idx = Int(frameProgress) % count
            }
            // 只在帧真正变化时赋值（24fps 动画 + 60fps tick，2/3 的 tick 帧不变）。
            // 避免每帧都触发 @Published → SwiftUI 重绘，节省 ~60% 的渲染 CPU。
            if idx != lastFrameIndex {
                currentFrame = frames[idx]
                lastFrameIndex = idx
            }
            // 流式补齐：播放接近缓存末尾时，后台解码下一批帧追加
            skin?.backfillIfNeeded(action: action, variant: currentVariant, currentIndex: idx)
        } else {
            // 一次性动作：idx 不超过已缓存帧数（count），用 total 判断是否真正播完
            let idx = min(Int(frameProgress), count - 1)
            if idx != lastFrameIndex {
                currentFrame = frames[idx]
                lastFrameIndex = idx
            }
            // 流式补齐：播放接近缓存末尾时，后台解码下一批帧追加
            skin?.backfillIfNeeded(action: action, variant: currentVariant, currentIndex: idx)
            // 一次性动作播完 → 按动作编排自然过渡：
            //   打哈欠 → 睡觉（先打哈欠再入睡，不直接跳）
            //   睡觉 → 保持睡着数秒（冻结在末帧）→ 醒来回 idle
            //   其他一次性动作 → 直接回 idle
            // 注意：用 total（素材总帧数）判断播完，不是 count（缓存帧数）。
            // 部分帧缓存时 count < total，必须等流式补齐全全部帧后才算播完。
            if Int(frameProgress) >= total - 1 {
                if action == .yawn && pendingSleep {
                    pendingSleep = false
                    frameProgress = 0
                    setAction(.sleep)
                    sleepHoldRemaining = Double.random(in: 5...15)
                } else if action == .sleep && sleepHoldRemaining > 0 {
                    sleepHoldRemaining -= tick
                    frameProgress = Double(count - 1)
                } else {
                    frameProgress = 0
                    if !isDragging {
                        setAction(.idle)
                        resetIdleCounter()
                    }
                }
            }
        }

        // 5. 行为 AI：仅在站立待机（idle）时决策 —— 走路/睡眠/哈欠/一次性动画期间都不打断
        if lifeState == .roaming, !isDragging, !wasMusicPlaying, !movingHome, movementMode == .floor, action == .idle {
            idleCounter -= tick
            if idleCounter <= 0 {
                decideNextBehavior()
            }
        }

        // 状态诊断日志（每 5 秒一条，观察走动逻辑：action/lifeState 是否正常流转）
        if tickCount % 300 == 0 {
            NSLog("[Pet] action=%@ lifeState=%@ musicPlaying=%d dragging=%d movingHome=%d fading=%d floor=%d alpha=%.2f walkTarget=%@ idleCounter=%.1f",
                  action.rawValue, lifeState.rawValue, wasMusicPlaying, isDragging, movingHome, fading,
                  movementMode == .floor, windowAlpha, walkTarget != nil ? "set" : "nil", idleCounter)
        }
    }

    // MARK: - 行为 AI

    private func decideNextBehavior() {
        let sad = happiness < 25
        let roll = Double.random(in: 0..<1)

        if sad {
            // 心情差时：更容易打瞌睡 / 闹脾气
            if roll < 0.30 {
                startSleeping()
            } else if roll < 0.50 {
                setAction(.hurt)
            } else if roll < 0.70 {
                startWalking()
            } else {
                resetIdleCounter()
            }
        } else {
            // 心情好：丰富多样的随机行为
            // 0.20 走路（随机选活泼/慢悠悠变体由 frames(for:) 决定）
            // 0.12 睡觉（经过打哈欠过渡）
            // 0.10 一次性小动作（打哈欠 / 开心蹦 / 受惊吓）—— 让待机不单调
            // 0.58 继续待机（换一个 idle 变体）
            if roll < 0.20 {
                startWalking()
            } else if roll < 0.32 {
                startSleeping()
            } else if roll < 0.42 {
                // 随机小动作：让站立期间偶尔有"小情绪"
                let mini = Double.random(in: 0..<1)
                if mini < 0.50 {
                    setAction(.yawn)              // 单独打哈欠（不入睡）
                } else if mini < 0.80 {
                    setAction(.happy)             // 突然开心一下
                } else {
                    setAction(.hurt)              // 突然一惊
                }
                resetIdleCounter()
            } else {
                resetIdleCounter()
                // 继续待机：强制换一个 idle 变体（避免一直同一个姿势）
                if skin?.variantCount(.idle) ?? 0 > 1 {
                    setAction(.idle, forceReshuffle: true)
                }
            }
        }
    }

    private func startWalking() {
        guard let target = randomWalkTarget() else {
            resetIdleCounter()
            return
        }
        walkTarget = target
        updateFacing(toward: target)
        setAction(.walk)
    }

    /// 睡觉：先打哈欠，哈欠播完后自动进入睡眠（避免"站 → 睡"直接跳变）
    private func startSleeping() {
        walkTarget = nil
        pendingSleep = true
        setAction(.yawn)
        idleCounter = Double.random(in: 6...14)
    }

    /// 在当前屏内随机选一个走动目标（避开顶部刘海区与底部 Dock 区）。
    /// 强制目标至少离当前位置 20% 屏宽，避免"刚走两步就停下"的短促切换。
    /// Y 范围基于 visibleFrame（排除 Dock/菜单栏），避免走到底部被 Dock 盖住（issue #10）。
    private func randomWalkTarget() -> CGPoint? {
        guard let screen = currentScreen else { return nil }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let size = windowSize
        let minX = frame.minX + frame.width * 0.06
        let maxX = frame.maxX - frame.width * 0.06 - size.width
        let minY = visible.minY + visible.height * 0.10
        let maxY = visible.minY + visible.height * 0.60
        guard maxX > minX, maxY > minY else { return nil }

        let current = windowPosition ?? CGPoint(x: frame.midX, y: frame.midY)
        let minDistance = frame.width * 0.20

        var best = CGPoint(x: maxX, y: maxY)
        var bestDistance: CGFloat = 0
        for _ in 0..<10 {
            let candidate = CGPoint(
                x: CGFloat.random(in: minX...maxX),
                y: CGFloat.random(in: minY...maxY)
            )
            let d = hypot(candidate.x - current.x, candidate.y - current.y)
            if d > bestDistance {
                best = candidate
                bestDistance = d
            }
            if d >= minDistance {
                return candidate
            }
        }
        // 10 次都没够远（屏太小），用最远的候选
        return best
    }

    private func updateFacing(toward target: CGPoint) {
        if let position = windowPosition {
            facingLeft = target.x < position.x
        }
    }

    /// 当前所在屏幕（含窗口的屏优先，否则主屏）
    private var currentScreen: NSScreen? {
        if let position = windowPosition {
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(position) }) {
                return screen
            }
        }
        return NSScreen.main
    }

    private func initialRoamingPosition() -> CGPoint {
        let screen = currentScreen ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = windowSize
        return CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.22
        )
    }

    // MARK: - 小把戏：掉落（出场 / 打断）

    /// 被打断 → 立刻掉下来
    private func interruptToFall() {
        walkTarget = nil
        movementMode = .falling
        fallVelocity = 0
        movingHome = false
        fading = false
        setAction(.fall)
        Logger.log("Pet interrupted — falling", category: .debug)
    }

    /// 落地：速度快则弹跳一次，慢则停止物理运动，但**不立即切 idle**。
    /// 让 fall 动画继续播完剩余帧（落地→站起来的完整序列），由 animTick 的一次性播完逻辑
    /// 自然衔接到 idle。这样用户能看到完整的"掉落→落地→站立→待机"过渡，而不是物理一落地就 cut。
    private func land() {
        if abs(fallVelocity) > 300 {
            // 弹跳：反弹 25% 速度，再落一次（衰减更狠，避免低重力下多次弹跳拖长）
            fallVelocity = -fallVelocity * 0.25
        } else {
            fallVelocity = 0
            movementMode = .floor
            lifeState = .roaming
            // 不切 idle！保持 action = .fall，让 fall 动画继续播完剩余帧（站立姿态），
            // 播完后 animTick 一次性动作逻辑会自动切 idle。
            Logger.log("Pet landed — fall animation continuing to completion", category: .debug)
        }
    }

    // MARK: - 回窝 / 出窝

    /// 宠物走回屏幕顶部中央（刘海正下方），随后淡出并进入 atHome 状态。
    func goHome() {
        guard lifeState == .roaming, !isDragging, !movingHome else {
            Logger.log("goHome rejected: roaming=\(lifeState == .roaming) dragging=\(isDragging) movingHome=\(movingHome)", category: .warning)
            return
        }
        guard let screen = homeScreen() else {
            Logger.log("goHome rejected: no target screen", category: .warning)
            return
        }
        Logger.log("Pet going home", category: .lifecycle)
        walkTarget = nil
        movingHome = true
        fading = false
        movementMode = .floor
        dizzyAngle = 0
        let size = windowSize
        // 真刘海屏：目标下移到刘海下方（刘海区域物理无像素，走上去会被遮挡）
        let inset = notchTopInset(screen)
        let target = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - inset - size.height - 4
        )
        updateFacing(toward: target)
        walkTarget = target
        setAction(.walk)
    }

    /// 瞬间进窝：跳过"走回"动画，直接定位到刘海正下方并淡出。
    /// 用于拖拽投放场景——用户已经把宠物拖到刘海区域，松手即归位，不需要再走回去。
    func snapHome() {
        guard lifeState == .roaming, !movingHome else {
            Logger.log("snapHome rejected: roaming=\(lifeState == .roaming) movingHome=\(movingHome)", category: .warning)
            return
        }
        guard let screen = homeScreen() else {
            Logger.log("snapHome rejected: no target screen", category: .warning)
            return
        }
        Logger.log("Pet snapped home (no walk)", category: .lifecycle)
        walkTarget = nil
        movingHome = true
        movementMode = .floor
        dizzyAngle = 0
        let size = windowSize
        let inset = notchTopInset(screen)
        // 瞬间定位到回窝目标点（与 goHome 同一坐标），随后由 fading 机制淡出
        windowPosition = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - inset - size.height - 4
        )
        // 直接进入淡出（不经走路），beginHomeFadeout 会设 fading=true + 切 idle
        beginHomeFadeout()
    }


    /// 从刘海出窝：以「从刘海掉落出场」的方式回到桌面 —— 出现在屏幕顶部（真刘海下方），
    /// 播放下落素材（fall）并自由落体到地面，落地后恢复活动。
    func leaveHome() {
        guard lifeState == .atHome, !movingHome, let screen = homeScreen() else { return }
        Logger.log("Pet leaving home — dropping from notch", category: .lifecycle)
        let size = windowSize
        movementMode = .floor
        // 出窝初始位置：宠物顶部大幅超出屏幕顶（200pt 探出，最终确认值），
        // 视觉上像从屏幕顶端"探出来"再掉落，有完整的上半程入画效果。
        // 真刘海屏则下移避开物理遮挡（刘海区域物理无像素）。
        let inset = notchTopInset(screen)
        windowPosition = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - inset - size.height + 200
        )
        windowAlpha = 1
        movingHome = false
        fading = false
        lifeState = .roaming
        // 自由落体出场
        movementMode = .falling
        fallVelocity = 0
        // 出窝：清除回窝节能模式，并确保 fall 动画能流式补齐。
        // trimToHomeOnly 清空了 partialLoaded（包括 fall_0），
        // 如果不重新标记，backfillIfNeeded 会因 partialLoaded 不含 fall_0 而不补齐，
        // 导致 fall 只有 24 帧 trailer，出窝动画卡住。
        skin?.exitHomeOnlyMode()
        setAction(.fall)
    }

    private func beginHomeFadeout() {
        fading = true
        setAction(.idle)
    }

    // MARK: - 互动 API

    /// 单击：戳一下。心情差会委屈，否则开心地蹦一下（掉落/出窝中不响应）。
    func poke() {
        guard lifeState == .roaming, !isDragging, movementMode == .floor else { return }
        if happiness < 30 {
            setAction(.hurt)
        } else {
            setAction(.happy)
            happiness = max(0, happiness - 1)
        }
    }

    /// 抚摸
    func pet() {
        guard lifeState == .roaming, !isDragging else { return }
        happiness = min(100, happiness + 12)
        setAction(.happy)
    }

    /// 拎起（打断任何小把戏，包括回窝）
    func startDrag() {
        guard lifeState == .roaming else { return }
        isDragging = true
        walkTarget = nil
        movementMode = .floor
        dizzyAngle = 0
        // 若正在回窝途中被拎起，必须复位回窝状态，否则 movingHome 永远卡住
        movingHome = false
        fading = false
        setAction(.drag)
    }

    /// 放下
    func endDrag() {
        isDragging = false
        setAction(.idle)
        resetIdleCounter()
    }

    /// 拖拽结束后把内部位置与窗口实际位置对齐
    func syncWindowPosition(_ point: CGPoint?) {
        if let point = point {
            windowPosition = point
        }
    }

    // MARK: - 属性衰减

    private func statTick() {
        let speed = Defaults[.petStatDecaySpeed]
        cleanliness = max(0, cleanliness - 0.8 * speed)
        // 心情缓慢趋向 50（长时间不理会低落）
        happiness = min(100, max(0, happiness + (50 - happiness) * 0.04))
    }

    // MARK: - 动作切换

    /// 当前动作音效播放器（NSSound，动作切换时播放对应 sound.m4a）
    private var soundPlayer: NSSound?

    private func setAction(_ newAction: PetAction, forceReshuffle: Bool = false) {
        // forceReshuffle=true 时即使同动作也重新进入（用于切换 idle 变体）
        guard forceReshuffle || action != newAction else { return }
        // 非哈欠/睡眠动作打断时，清除睡觉编排状态（否则下次哈欠会误入睡眠）
        if newAction != .yawn && newAction != .sleep {
            pendingSleep = false
            sleepHoldRemaining = 0
        }
        action = newAction
        frameProgress = 0
        // 标记已播放（物化）：该动作的位图将物化，预取淘汰时会释放
        skin?.markPlayed(newAction)
        // 进入动作时选一个变体并固定（动画循环中不重抽）：
        // 优先已缓存变体（避免播放加载延迟导致"窗口动了动画还没开始"），
        // 全部未缓存才随机（配合预取覆盖全部变体，正常情况零延迟）
        currentVariant = skin?.preferredVariant(for: newAction) ?? 0
        // 音效策略：
        //  - 变体切换（forceReshuffle）不重播音效（否则 idle 变体每几秒重播背景音乐）
        //  - idle/home 是循环待机/睡眠动作，不播音效（idle 素材带背景音乐，循环重播会一直响）
        //  - 其他一次性动作（walk/happy/hurt/yawn/sleep/fall/drag）进入时播一次
        //  - 无论是否有新声音，切换动作都先停掉旧声音（避免旧音乐一直放完）
        if forceReshuffle || newAction == .idle || newAction == .home {
            stopSound()
        } else {
            playSound(for: newAction)
        }
        // 预取下一个很可能用到的动作（后台解码，避免切换时卡顿）
        switch newAction {
        case .idle:
            // 回窝后不预取活动动作（已由 trimToHomeOnly 卸载，预取会把它们填回来）。
            // idle 预取只在 roaming 状态下有意义（为下一次行为 AI 决策准备）。
            // idle 也在列表里：加载全部变体的 trailer 帧，实现待机变体轮换。
            if lifeState == .roaming {
                skin?.prefetch([.idle, .walk, .yawn, .drag, .happy, .hurt, .fall])
            }
        case .yawn where pendingSleep:
            skin?.prefetch([.sleep])
        default:
            break
        }
        Logger.log("Pet action → \(newAction.rawValue) (lifeState=\(lifeState.rawValue))", category: .debug)
    }

    /// 停止当前音效（动作切换/变体切换时调用，避免旧声音一直放完）。
    private func stopSound() {
        DispatchQueue.main.async { [weak self] in
            self?.soundPlayer?.stop()
            self?.soundPlayer = nil
        }
    }

    /// 播放动作音效（素材目录 <动作>/sound.m4a，可选）。
    /// NSSound 首次加载/初始化会阻塞主线程（音频系统初始化可到 ~0.4s），
    /// 而 setAction 在主线程执行——必须异步创建，否则面板/动画响应被延迟。
    private func playSound(for action: PetAction) {
        // 新动作没有音效文件时也要停掉旧声音（如 idle 音乐 → 睡觉）
        guard let url = skin?.sounds[action] else {
            stopSound()
            return
        }
        stopSound()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sound = NSSound(contentsOf: url, byReference: true)
            DispatchQueue.main.async {
                guard let self, let sound else { return }
                self.soundPlayer?.stop()
                self.soundPlayer = sound
                // 音量由设置项控制（0.0–1.0），独立于系统音量
                sound.volume = Float(Defaults[.petSoundVolume])
                sound.play()
            }
        }
    }

    /// 实时调节当前播放音效的音量（设置滑块拖动时调用，无需等下次播放）。
    /// 若当前无音效播放，下次 playSound 时会用新音量。
    func updateSoundVolume() {
        soundPlayer?.volume = Float(Defaults[.petSoundVolume])
    }
}
