//
//  SpriteAnimator.swift
//  boringNotch
//
//  Desktop pet sequence-frame animation engine.
//  素材目录规范（PET.md）：
//  <skinDirectory>/
//    config.json          可选：{ "fps": 10, "scale": 1.0, "actions": { "idle": { "fps": 8, "loops": -1 } } }
//    idle/1.png 2.png ... 待机循环
//    walk/...   sleep/...  eat/...  happy/...  hurt/...  drag/...  music/...  home/...
//
//  内存策略（重要）：
//   - 帧全部用 ImageIO thumbnail 降采样解码（按显示尺寸，约 582px），避免 832x832 全尺寸位图
//   - 按需加载 + 淘汰：只保留 idle/home/当前动作的帧，其余动作加载后即释放
//   - 后台解码不阻塞主线程；加载期间动画保持上一帧（不闪占位）

import AppKit
import Defaults
import Foundation
import ImageIO

/// 安全下标：越界返回 nil（用于变体数组访问）
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// config.json 结构（可选）
struct PetSkinConfig: Codable {
    var fps: Double?
    var scale: Double?
    var actions: [String: PetActionConfig]?
}

struct PetActionConfig: Codable {
    var fps: Double?
    /// -1 表示无限循环；>= 1 表示播放 N 遍后停在最后一帧
    var loops: Int?
}

/// 宠物皮肤：从素材目录加载所有动作的帧序列
@MainActor
final class PetSkin {
    /// 每个动作的变体帧序列（idle_0/idle_1/... 都归到 .idle 的变体集合）
    private let variantURLs: [PetAction: [[URL]]]
    /// 已解码帧缓存（按需加载；淘汰策略：只保留 idle/home/当前动作）
    /// 缓存粒度：[动作: [变体索引: 帧]]；当前播放的变体索引由 PetManager 通过 currentVariant 维护
    private var cache: [PetAction: [[NSImage]]] = [:]
    /// 帧签名缓存（动作 → 变体 → 帧 → 签名），随帧一起入缓存；用于组内无缝循环
    private var signatures: [PetAction: [[[Float]]]] = [:]
    /// 组内循环衔接点（动作 → 变体 → loopPoint）：循环绕回时从该帧续接，避免跳变
    private var loopPoints: [PetAction: [Int]] = [:]
    /// 正在后台加载的（动作, 变体索引）对
    private var loading: Set<String> = []
    /// 已播放（物化）过的动作：物化占大内存，预取完成后受淘汰约束；
    /// 未播放的预取动作只是解码产物（便宜），可常驻备用
    private var played: Set<PetAction> = []
    /// 当前预取集合（由 prefetch() 设置）：这些动作是 idle 后的候选，必须常驻。
    /// 解决循环淘汰 bug：播放过的 walk/yawn 等高频动作在预取时会被 storeLoaded 的
    /// 淘汰逻辑错误排除（因为它们在 played 里），导致每次切换都重新加载（1.4-2s 延迟）。
    /// 修复：预取列表里的动作无论是否播放过，都纳入 keep 集合保留。
    private var prefetched: Set<PetAction> = []
    /// 回窝节能模式标志：trimToHomeOnly() 置 true，出窝时（prefetch）置 false。
    /// storeLoaded 检查此标志：回窝期间后台预取陆续完成时，拒绝非 [home, fall] 的动作入缓存，
    /// 否则 trim 清完后预取又把帧填回来（实测内存不降）。
    private var homeOnlyMode = false

    // MARK: 部分帧预缓存 + 流式补齐
    /// 预缓存时每个动作只解码的前导帧数（位图）。
    /// 按一秒播放量缓存：24fps × 1秒 = 24 帧（缓冲 1 秒），后台解码 7-10ms/帧，
    /// 这段时间能解码 100-140 帧，远超播放消耗，触发动作时零感知延迟、零卡顿。
    private let trailerFrameCount = 24
    /// 流式补齐的批量大小：每次后台解码追加多少帧。
    /// 24 帧 × ~8ms = 192ms 解码，而播放完 24 帧需 1 秒，解码远快于播放。
    private let backfillBatch = 24
    /// 标记"部分加载"的动作变体（"action_variant"）：位图不完整，需要流式补齐。
    private var partialLoaded: Set<String> = []
    /// 正在后台补齐的动作变体（防重复触发）。
    private var backfilling: Set<String> = []
    /// 降采样解码的最大边长（按显示尺寸计算，视网膜 2x）
    let maxPixelSize: Int
    /// 每个动作的帧率
    let fps: [PetAction: Double]
    /// 每个动作的循环次数（-1 无限）
    let loops: [PetAction: Int]
    /// 每个动作的音效文件（<动作目录>/sound.m4a|mp3|wav，可选）
    let sounds: [PetAction: URL]
    /// 皮肤 scale（config.json 可覆盖全局默认 1.0）
    let scale: CGFloat
    /// 首帧原始像素尺寸（point 尺寸 = 原始像素，用于窗口布局；渲染用降采样位图）
    let baseFrameSize: CGSize?
    /// 素材来源目录
    let sourceURL: URL

    /// 可用动作数 / 总帧数（设置页显示用）
    var availableActions: [PetAction] { Array(variantURLs.keys) }
    var totalFrameCount: Int { variantURLs.values.flatMap { $0.flatMap { $0 } }.count }
    /// 某动作的变体数（用于 PetManager 随机选变体）
    func variantCount(_ action: PetAction) -> Int { variantURLs[action]?.count ?? 0 }

    /// 某动作指定变体的**总帧数**（素材全集，不受部分缓存影响）。
    /// 用于 animTick 判断"一次性动作是否播完"——部分帧缓存时 frames.count 只有 trailer 数，
    /// 不能用它判断播完，否则 happy 还没播完就回 idle 了。
    func totalFrameCount(_ action: PetAction, variant: Int) -> Int {
        variantURLs[action]?[safe: variant]?.count ?? 0
    }

    /// 是否有真实素材（不含兜底动作）：没有真实素材的动作不应激活
    /// （如无跳舞素材时 music 联动会退化成 idle 帧 + 冻结行为 AI，应直接跳过）
    func hasRealMaterial(_ action: PetAction) -> Bool {
        if let v = variantURLs[action], !v.isEmpty, !v[0].isEmpty { return true }
        return false
    }

    /// 组内循环衔接点：循环绕回时从该帧续接（0 表示无衔接点，用原始 % count 行为）
    func loopPoint(for action: PetAction, variant: Int) -> Int {
        loopPoints[action]?[safe: variant] ?? 0
    }

    private init(
        variantURLs: [PetAction: [[URL]]],
        maxPixelSize: Int,
        fps: [PetAction: Double],
        loops: [PetAction: Int],
        sounds: [PetAction: URL],
        scale: CGFloat,
        baseFrameSize: CGSize?,
        sourceURL: URL
    ) {
        self.variantURLs = variantURLs
        self.maxPixelSize = maxPixelSize
        self.fps = fps
        self.loops = loops
        self.sounds = sounds
        self.scale = scale
        self.baseFrameSize = baseFrameSize
        self.sourceURL = sourceURL
    }

    /// 该动作是否有可用素材（含兜底动作）
    func hasMaterial(_ action: PetAction) -> Bool {
        if let v = variantURLs[action], !v.isEmpty, !v[0].isEmpty { return true }
        switch action {
        case .music, .hang, .dizzy, .yawn:
            return variantURLs[.idle] != nil
        case .climb:
            return variantURLs[.walk] != nil || variantURLs[.idle] != nil
        case .fall:
            return variantURLs[.drag] != nil || variantURLs[.idle] != nil
        case .home:
            return variantURLs[.sleep] != nil || variantURLs[.idle] != nil
        default:
            return false
        }
    }

    /// 获取动作指定变体的帧：
    ///  - 已缓存：直接返回
    ///  - 有素材未加载：后台解码（本次返回 nil，加载完成后自动可用，动画保持上一帧）
    ///  - 无素材：返回兜底动作帧
    ///  - variant < 0 或越界：随机选一个变体
    func frames(for action: PetAction, variant: Int = -1) -> [NSImage]? {
        let v = resolveVariant(action, requested: variant)
        // 注意：必须排除空数组占位（index 对齐用），否则会"命中空缓存"导致永久卡帧
        if let cached = cache[action]?[safe: v], !cached.isEmpty { return cached }
        if let urls = variantURLs[action]?[safe: v], !urls.isEmpty {
            let key = "\(action.rawValue)_\(v)"
            if !loading.contains(key) {
                loading.insert(key)
                startLoad(action, variant: v, urls: urls, isPrefetch: false)
            }
            // 过渡：目标变体加载期间，先用同动作已缓存的变体顶替
            // （避免每次变体切换都卡 0.8s；同动作变体帧数接近，切换无感）
            if let variants = cache[action], let existing = variants.first(where: { !$0.isEmpty }) {
                return existing
            }
            return nil
        }
        return fallbackFrames(for: action)
    }

    /// 预取动作帧（部分帧预缓存策略）。
    /// 每个动作只解码前 trailerFrameCount 帧位图（贵，1.14MB/帧）+ 全部帧签名（便宜，2KB/帧）。
    /// 签名全量计算保证 loopPoint 正确；位图部分缓存让触发瞬间有帧可播，后续流式补齐。
    /// 内存：7 动作 × 10 帧 ≈ 80帧 ≈ 92MB（vs 全量预取 813帧 ≈ 490MB）。
    /// 单变体加载（preferredVariant 优先选已缓存变体），多变体省内存。
    func prefetch(_ actions: [PetAction]) {
        prefetched = Set(actions)
        // 出窝恢复活动：清除回窝节能标志（出窝后 setAction(.idle) 会触发此预取）
        homeOnlyMode = false
        for action in actions {
            guard let variants = variantURLs[action], !variants.isEmpty else { continue }
            if action == .idle {
                // idle 是常驻待机，需要变体轮换：预取**全部变体**的 trailer 帧，
                // preferredVariant 就能在已缓存变体间随机切换（避免一直播同一套待机）。
                // 内存：4 变体 × 24 帧 × 0.38MB ≈ 36MB，可接受。
                for (vi, urls) in variants.enumerated() where !urls.isEmpty {
                    // 已有 trailer 帧（markPlayed 截断后保留的）就跳过，不重复加载
                    if let existing = cache[action]?[safe: vi], !existing.isEmpty { continue }
                    let key = "\(action.rawValue)_\(vi)"
                    if !loading.contains(key) {
                        loading.insert(key)
                        startPartialLoad(action, variant: vi, urls: urls, trailer: trailerFrameCount)
                    }
                }
            } else {
                // 其他动作：只加载第一个变体。已有 trailer 帧（markPlayed 截断后保留的）就跳过。
                if let urls = variants.first(where: { !$0.isEmpty }),
                   cache[action]?[safe: 0]?.isEmpty != false  // 无缓存或空才加载
                {
                    let key = "\(action.rawValue)_0"
                    if !loading.contains(key) {
                        loading.insert(key)
                        startPartialLoad(action, variant: 0, urls: urls, trailer: trailerFrameCount)
                    }
                }
            }
        }
    }

    /// 部分帧加载：后台计算全部帧签名 + 解码前 trailer 帧位图。
    /// 签名（32px）便宜全量计算；位图（640px）只取前几帧，触发后由 backfillIfNeeded 流式补齐。
    private func startPartialLoad(_ action: PetAction, variant: Int, urls: [URL], trailer: Int) {
        let maxPixel = maxPixelSize
        let key = "\(action.rawValue)_\(variant)"
        let trailerCount = min(trailer, urls.count)
        Task.detached(priority: .userInitiated) { [weak self] in
            // 1. 全部帧算签名（32px，便宜）
            let allSigs = urls.map { PetSkin.frameSignature(from: $0) }
            // 2. 前 trailer 帧解码位图（640px，贵）
            let trailerUrls = Array(urls.prefix(trailerCount))
            let trailerImages = trailerUrls.compactMap { PetSkin.decodeDownscaled($0, maxPixel: maxPixel) }
            guard let self else { return }
            await MainActor.run {
                self.storePartialLoaded(action, variant: variant,
                                        trailerImages: trailerImages,
                                        allSignatures: allSigs,
                                        totalFrames: urls.count, key: key)
            }
        }
    }

    /// 存储部分帧预缓存结果：前 trailer 帧位图 + 全量签名 + 标记 partialLoaded。
    private func storePartialLoaded(_ action: PetAction, variant: Int,
                                     trailerImages: [NSImage], allSignatures: [[Float]],
                                     totalFrames: Int, key: String) {
        loading.remove(key)
        guard !trailerImages.isEmpty else { return }
        // 回窝节能模式：拒绝非 [home, fall] 入缓存
        if homeOnlyMode, action != .home, action != .fall {
            Logger.log("storePartialLoaded \(action.rawValue)_\(variant) dropped — homeOnlyMode", category: .memory)
            return
        }
        // 淘汰非预取/非核心动作，保留空间
        let keep = Self.coreActions.union(prefetched).union([action])
        cache = cache.filter { keep.contains($0.key) }
        self.signatures = self.signatures.filter { keep.contains($0.key) }

        // 存入部分帧位图（前 trailer 帧）
        var variants = cache[action] ?? []
        while variants.count <= variant { variants.append([]) }
        variants[variant] = trailerImages
        cache[action] = variants

        // 存入全量签名（用于 loopPoint 计算）
        var sigs = self.signatures[action] ?? []
        while sigs.count <= variant { sigs.append([]) }
        sigs[variant] = allSignatures
        self.signatures[action] = sigs

        // 预计算 loopPoint（签名全量，loopPoint 正确）
        var loopPts = loopPoints[action] ?? []
        while loopPts.count <= variant { loopPts.append(0) }
        loopPts[variant] = Self.computeLoopPoint(allSignatures)
        loopPoints[action] = loopPts

        // 标记需要流式补齐（位图不完整）
        if trailerImages.count < totalFrames {
            partialLoaded.insert("\(action.rawValue)_\(variant)")
        }
        Logger.log("partial loaded \(action.rawValue)_\(variant): \(trailerImages.count)/\(totalFrames) frames (loopPoint=\(loopPts[variant]))", category: .debug)
    }

    /// 变体选择：优先已缓存变体（避免播放加载延迟），全部未缓存时随机
    func preferredVariant(for action: PetAction) -> Int? {
        guard let variants = variantURLs[action], !variants.isEmpty else { return nil }
        let cached = variants.indices.filter { cache[action]?[safe: $0]?.isEmpty == false }
        if !cached.isEmpty { return cached.randomElement() }
        return Int.random(in: 0..<variants.count)
    }

    /// 核心常驻动作：idle/home/drag 为默认态与拖拽交互；happy/hurt 为点击即时响应；
    /// fall 为出窝即时触发（点刘海头像瞬间需要掉落动画）。
    /// 这些动作不能被淘汰，否则每次触发都要重新加载（动画冻结/延迟）
    private static let coreActions: Set<PetAction> = [.idle, .home, .drag, .happy, .hurt, .fall]

    /// 标记动作已播放（物化）——播放会物化位图（~1.3MB/帧），
    /// 物化后的动作立即受淘汰约束：只保留核心集 + 当前动作，
    /// 其他已物化动作的位图释放（否则播放过的动作无限累积物化内存）。
    /// 被淘汰的动作在回到 idle 时会被重新预取（0.8s 后台），AI 决策在 6s 后才发生，无感知延迟。
    ///
    /// 优化（2026-08-09）：非核心动作不再直接删除（cache[action]=nil），而是**截断到 trailerFrameCount**。
    /// 原因：删除后 prefetch 会重新加载 trailer + 流式补齐到全量，淘汰无效，内存反复累积。
    /// 截断保留前导帧，prefetch 看到有 trailer 就跳过不重新加载，下次播放时流式补齐。
    /// 同时清理 loopPoints/partialLoaded/backfilling 里的孤儿条目。
    func markPlayed(_ action: PetAction) {
        played.insert(action)
        let keep = Self.coreActions.union([action])
        // 非核心非当前动作：截断到 trailer（释放全量补齐的尾部帧）
        for a in cache.keys where !keep.contains(a) {
            if var variants = cache[a] {
                for vi in variants.indices where !variants[vi].isEmpty {
                    let trailer = min(trailerFrameCount, variants[vi].count)
                    variants[vi] = Array(variants[vi].prefix(trailer))
                }
                cache[a] = variants
            }
            // 截断后帧不完整，重新标记为 partialLoaded（下次播放时流式补齐）
            for vi in 0..<(variantURLs[a]?.count ?? 0) {
                partialLoaded.insert("\(a.rawValue)_\(vi)")
            }
        }
        // 清理被淘汰动作的孤儿数据（signatures 不截断——签名全量保留，loopPoint 仍可用）
        let evicted = Set(cache.keys).subtracting(keep)
        for a in evicted {
            let prefix = "\(a.rawValue)_"
            partialLoaded = partialLoaded.filter { !$0.hasPrefix(prefix) }
            backfilling = backfilling.filter { !$0.hasPrefix(prefix) }
        }
    }

    // MARK: - 流式补齐

    /// 当播放进度接近已缓存帧末尾时，后台解码下一批帧追加到缓存。
    /// 由 PetManager.animTick 每帧调用检查。只在 partialLoaded 动作上有开销。
    /// 解码 7-10ms/帧 vs 播放 41.7ms/帧，解码远快于播放，永远不会追不上。
    func backfillIfNeeded(action: PetAction, variant: Int, currentIndex: Int) {
        let key = "\(action.rawValue)_\(variant)"
        guard partialLoaded.contains(key) else { return }
        guard backfilling.contains(key) == false else { return }
        guard let cached = cache[action]?[safe: variant], !cached.isEmpty else { return }
        guard let urls = variantURLs[action]?[safe: variant], !urls.isEmpty else { return }
        // 已全部加载 → 标记完成，不再补齐
        if cached.count >= urls.count {
            partialLoaded.remove(key)
            return
        }
        // 距末尾 > 8 帧 → 不急着补（还有 ~330ms 缓冲，够后台解码追上）
        if cached.count - currentIndex > 8 { return }
        // 开始后台补齐下一批
        backfilling.insert(key)
        let maxPixel = maxPixelSize
        let fromIdx = cached.count
        let batch = Array(urls.suffix(from: fromIdx).prefix(backfillBatch))
        Task.detached(priority: .userInitiated) { [weak self] in
            let images = batch.compactMap { PetSkin.decodeDownscaled($0, maxPixel: maxPixel) }
            await MainActor.run {
                self?.appendFrames(action, variant: variant, images: images, key: key, totalUrls: urls.count)
            }
        }
    }

    /// 追加流式补齐的帧到缓存数组。
    private func appendFrames(_ action: PetAction, variant: Int, images: [NSImage], key: String, totalUrls: Int) {
        backfilling.remove(key)
        guard !images.isEmpty else { return }
        // 回窝节能模式：补齐也拒绝（动作已被 trim 淘汰）
        if homeOnlyMode, action != .home, action != .fall { return }
        guard var variants = cache[action], var frames = variants[safe: variant] else { return }
        frames.append(contentsOf: images)
        variants[variant] = frames
        cache[action] = variants
        // 检查是否已全部加载
        if frames.count >= totalUrls {
            partialLoaded.remove(key)
            Logger.log("backfill \(action.rawValue)_\(variant) complete: \(frames.count) frames", category: .debug)
        } else {
            Logger.log("backfill \(action.rawValue)_\(variant): +\(images.count) → \(frames.count)/\(totalUrls)", category: .debug)
        }
    }

    /// 回窝节能模式：清空所有活动动作的缓存（idle/walk/yawn/drag/happy/hurt/sleep），
    /// 只保留 .home（在窝显示的 1 帧睡眠姿势）+ .fall（出窝掉落动画，用户点出窝时需即时播放）。
    /// 同时清空预取集合与播放记录，避免 setAction(.idle) 触发的预取把刚卸载的动作填回来。
    /// 内存收益：757MB → ~140MB（fall 105 帧 + home 1 帧），出窝零延迟。
    /// 出窝落地后 setAction(.idle) 会重新预取活动动作（lifeState 已是 roaming）。
    func trimToHomeOnly() {
        let keep: Set<PetAction> = [.home, .fall]
        cache = cache.filter { keep.contains($0.key) }
        signatures = signatures.filter { keep.contains($0.key) }
        loopPoints = loopPoints.filter { keep.contains($0.key) }
        prefetched = []
        played = []
        partialLoaded = []
        backfilling = []
        // 置节能标志：正在后台解码的预取陆续完成时，storeLoaded/storePartialLoaded/appendFrames 会拒绝它们
        homeOnlyMode = true
        Logger.log("trimToHomeOnly — evicted activity actions, kept: \(cache.keys.map { $0.rawValue }.sorted())", category: .memory)
    }

    private func resolveVariant(_ action: PetAction, requested: Int) -> Int {
        guard let variants = variantURLs[action], !variants.isEmpty else { return 0 }
        if requested >= 0 && requested < variants.count { return requested }
        return Int.random(in: 0..<variants.count)
    }

    // MARK: - 加载

    private func startLoad(_ action: PetAction, variant: Int, urls: [URL], isPrefetch: Bool) {
        let maxPixel = maxPixelSize
        let key = "\(action.rawValue)_\(variant)"
        Task.detached(priority: .userInitiated) { [weak self] in
            // 后台解码（帧保持懒物化）+ 用 32px 缩略图算签名（不物化帧位图）
            let images = urls.compactMap { PetSkin.decodeDownscaled($0, maxPixel: maxPixel) }
            let sigs = urls.map { PetSkin.frameSignature(from: $0) }
            guard let self else { return }
            await MainActor.run {
                self.storeLoaded(action, variant: variant, images: images, signatures: sigs, isPrefetch: isPrefetch, key: key)
            }
        }
    }

    private func storeLoaded(_ action: PetAction, variant: Int, images: [NSImage], signatures: [[Float]], isPrefetch: Bool, key: String) {
        loading.remove(key)
        guard !images.isEmpty else { return }
        // 回窝节能模式：拒绝非 [home, fall] 的任何加载（含播放加载）入缓存。
        // 回窝前 roaming 时启动的后台预取，或 animTick 请求当前 action 帧触发的播放加载，
        // 若放它们入缓存，trim 清空的内存会被重新填回（实测回窝后仍 470MB）。
        if homeOnlyMode, action != .home, action != .fall {
            Logger.log("storeLoaded \(action.rawValue)_\(variant) dropped — homeOnlyMode active", category: .memory)
            return
        }
        // 确保该动作的变体数组存在并足够长（cache 与 signatures 同步补齐，防止历史不同步越界）
        var variants = cache[action] ?? []
        var sigs = self.signatures[action] ?? []
        var loopPts = loopPoints[action] ?? []
        let target = max(variants.count, sigs.count)
        while variants.count < target { variants.append([]) }
        while sigs.count < target { sigs.append([]) }
        while loopPts.count < target { loopPts.append(0) }
        while variants.count <= variant {
            variants.append([])
            sigs.append([])
            loopPts.append(0)
        }
        variants[variant] = images
        sigs[variant] = signatures
        // 预计算组内循环衔接点（与末帧姿势最接近、且不吞掉开头起步段的帧）
        loopPts[variant] = Self.computeLoopPoint(signatures)

        if isPrefetch {
            // 预取淘汰：保留 coreActions + 当前预取集合 + 当前正在 storeLoaded 的动作。
            // 关键修复：旧逻辑用 "!played" 判断保留集，导致播放过的 walk/yawn 等高频动作
            // 被排除出 keep —— 同批次预取的其他动作 storeLoaded 时会把刚预取的 walk 挤掉
            // （循环淘汰 bug），下次切换时重新解码 1.4-2s。
            // 预取列表（prefetched）是 idle 后的候选动作，无论是否播放过都应保留。
            // 内存：预取动作位图虽已物化（~1.3MB/帧），但配合"降低活动频率"（30s 档），
            // AI 决策间隔远大于预取时间，切换时命中缓存零延迟；markPlayed 淘汰仍会释放
            // 非当前播放的动作，控制峰值内存。
            let keep = Self.coreActions.union(prefetched).union([action])
            cache = cache.filter { keep.contains($0.key) }
            cache[action] = variants
            self.signatures = self.signatures.filter { keep.contains($0.key) }
            self.signatures[action] = sigs
            loopPoints[action] = loopPts
        } else {
            // 播放加载：淘汰其他动作的位图，只保留核心集 + 当前动作
            let keep = Self.coreActions.union([action])
            cache = cache.filter { keep.contains($0.key) }
            cache[action] = variants
            self.signatures = self.signatures.filter { keep.contains($0.key) }
            self.signatures[action] = sigs
            loopPoints[action] = loopPts
            // 多变体动作特判：只保留当前播放的这一个变体（idle 有 4 个、happy/hurt 有 2 个，
            // 全部常驻会把内存撑爆）。保持"index=变体号"的数组结构，否则 frames(for: variant:) 永远 miss
            if action == .idle || action == .happy || action == .hurt {
                var only = [[NSImage]](repeating: [], count: variant + 1)
                only[variant] = images
                cache[action] = only
                var onlySigs = [[[Float]]](repeating: [], count: variant + 1)
                onlySigs[variant] = signatures
                self.signatures[action] = onlySigs
                var onlyLoop = [Int](repeating: 0, count: variant + 1)
                onlyLoop[variant] = loopPts[variant]
                loopPoints[action] = onlyLoop
            }
        }
        Logger.log("Skin loaded \(action.rawValue)_\(variant) (\(images.count) frames, loopPoint=\(loopPts[variant])) — cache: \(cache.keys.map { $0.rawValue }.sorted())", category: .debug)
    }

    /// 计算组内循环衔接点：在 [0, 帧数×0.7) 内找与末帧签名距离最小的帧。
    /// 语义：第一轮播完整 0..末帧（含"站立→起步"段），之后从 loopPoint 续接无缝循环。
    /// 仅当该帧明显优于默认绕回点 0（距离 < 帧0↔末帧距离的一半）时才启用，
    /// 避免素材质量差时硬接反而更怪。返回 0 表示无合适衔接点（原始 % count 循环）。
    nonisolated static func computeLoopPoint(_ signatures: [[Float]]) -> Int {
        guard signatures.count > 3 else { return 0 }
        let last = signatures.count - 1
        let limit = max(1, Int(Double(signatures.count) * 0.7))
        var best = 0
        var bestDist = Float.greatestFiniteMagnitude
        for s in 0..<limit {
            let d = signatureDistance(signatures[s], signatures[last])
            if d < bestDist {
                bestDist = d
                best = s
            }
        }
        // 相对阈值：衔接点必须明显优于默认绕回点（第 0 帧）
        let defaultDist = signatureDistance(signatures[0], signatures[last])
        return bestDist < defaultDist * 0.5 ? best : 0
    }

    /// 帧签名（从 URL 直接解码 32px 缩略图采样，物化仅 ~4KB/帧）：
    /// 16×16 网格，每格亮度 + alpha，共 512 floats（姿势轮廓为主，忽略背景）。
    /// 注意：不能用大图签名——那会强制物化帧位图，把内存从 ~150MB 撑到 ~700MB。
    nonisolated static func frameSignature(from url: URL) -> [Float] {
        let grid = 16
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return [Float](repeating: 0, count: grid * grid * 2)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return [Float](repeating: 0, count: grid * grid * 2)
        }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return [Float](repeating: 0, count: grid * grid * 2) }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return [Float](repeating: 0, count: grid * grid * 2)
        }
        ctx.setBlendMode(.copy)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sig = [Float](repeating: 0, count: grid * grid * 2)
        for gy in 0..<grid {
            for gx in 0..<grid {
                var lum: Float = 0
                var alpha: Float = 0
                var cnt: Float = 0
                for sy in 0..<max(1, h / grid) {
                    for sx in 0..<max(1, w / grid) {
                        let x = min(w - 1, gx * (w / grid) + sx)
                        let y = min(h - 1, gy * (h / grid) + sy)
                        let i = (y * w + x) * 4
                        let a = Float(data[i + 3]) / 255
                        if a > 0.05 {
                            lum += (Float(data[i]) + Float(data[i + 1]) + Float(data[i + 2])) / 3 / 255 * a
                            alpha += a
                            cnt += 1
                        }
                    }
                }
                let n = Float(max(1, h / grid) * max(1, w / grid))
                sig[gy * grid + gx] = cnt > 0 ? lum / n : 0
                sig[grid * grid + gy * grid + gx] = alpha / n
            }
        }
        return sig
    }

    /// 签名欧氏距离
    nonisolated static func signatureDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .greatestFiniteMagnitude }
        var d: Float = 0
        for i in 0..<a.count {
            let diff = a[i] - b[i]
            d += diff * diff
        }
        return d
    }

    /// 兜底动作帧：home 用 sleep 最后一帧（回窝后显示"睡着了"），其余用 idle/walk/drag
    private func fallbackFrames(for action: PetAction) -> [NSImage]? {
        if action == .home {
            if let sleepFrames = frames(for: .sleep), let last = sleepFrames.last {
                var homeVariants = cache[.home] ?? []
                while homeVariants.count < 1 { homeVariants.append([]) }
                homeVariants[0] = [last]
                cache[.home] = homeVariants
                return homeVariants[0]
            }
            if let idleFrames = frames(for: .idle), let first = idleFrames.first {
                var homeVariants = cache[.home] ?? []
                while homeVariants.count < 1 { homeVariants.append([]) }
                homeVariants[0] = [first]
                cache[.home] = homeVariants
                return homeVariants[0]
            }
            return nil
        }
        switch action {
        case .music:
            return frames(for: .idle)
        case .climb:
            return frames(for: .walk) ?? frames(for: .idle)
        case .hang, .dizzy, .yawn:
            return frames(for: .idle)
        case .fall:
            return frames(for: .drag) ?? frames(for: .idle)
        default:
            return nil
        }
    }

    /// 降采样解码：ImageIO thumbnail 直接从 PNG 解码到目标尺寸（无全尺寸中间态）。
    /// ShouldCacheImmediately: true —— 显式立即解码，避免 ImageIO 懒缓存累积导致内存只增不减。
    /// nonisolated：纯函数，可在后台线程解码。
    nonisolated static func decodeDownscaled(_ url: URL, maxPixel: Int) -> NSImage? {
        autoreleasepool {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            // point 尺寸保持原始像素尺寸（窗口布局不变；渲染时用降采样位图）
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? cg.width
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? cg.height
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
    }

    // MARK: - 皮肤加载

    /// 按优先级查找素材目录：自定义目录 > 默认目录（~/Pictures/BoringPet）> 内置素材（BoringPet.bundle）
    static func locateSkinDirectory() -> URL? {
        let fileManager = FileManager.default

        let custom = Defaults[.petSkinDirectory]
        if !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/BoringPet", isDirectory: true)
        if fileManager.fileExists(atPath: defaultDir.path) {
            return defaultDir
        }

        if let builtIn = Bundle.main.url(forResource: "BoringPet", withExtension: nil) {
            return builtIn
        }

        return nil
    }

    /// 加载皮肤；目录不存在或没有任何帧时返回 nil
    static func load() -> PetSkin? {
        guard let dir = locateSkinDirectory() else { return nil }

        var config = PetSkinConfig()
        if let configURL = dir.appendingPathComponent("config.json") as URL?,
           let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONDecoder().decode(PetSkinConfig.self, from: data) {
            config = parsed
        }

        // 1. 扫描目录：识别变体（idle_0/idle_1/... 归到 .idle）和单一动作（idle 归到 .idle）
        var variantURLs: [PetAction: [[URL]]] = [:]
        var fps: [PetAction: Double] = [:]
        var loops: [PetAction: Int] = [:]
        var sounds: [PetAction: URL] = [:]

        let allFolders = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.filter { $0.hasDirectoryPath } ?? []

        // 先收集变体目录（idle_0, idle_1, happy_0...）
        var variantFolders: [PetAction: [(idx: Int, url: URL)]] = [:]
        for folder in allFolders {
            let name = folder.lastPathComponent
            // 匹配 "动作_数字" 形式（如 idle_0、happy_1）
            if let underscore = name.lastIndex(of: "_"),
               let idx = Int(name[name.index(after: underscore)...]) {
                let base = String(name[..<underscore])
                if let action = PetAction.allCases.first(where: { $0.folderName == base }) {
                    variantFolders[action, default: []].append((idx, folder))
                }
            }
        }

        for (action, variants) in variantFolders {
            let sorted = variants.sorted { $0.idx < $1.idx }
            var urlsList: [[URL]] = []
            for (_, folder) in sorted {
                let urls = scanPNGs(in: folder)
                if !urls.isEmpty { urlsList.append(urls) }
                // 音效（取第一个变体的）
                if sounds[action] == nil, let s = scanSound(in: folder) { sounds[action] = s }
            }
            if !urlsList.isEmpty {
                variantURLs[action] = urlsList
                applyConfig(&fps, &loops, for: action, config: config)
            }
        }

        // 再扫描无变体的单一动作目录（idle、walk...，跳过已有变体的）
        for action in PetAction.allCases where variantURLs[action] == nil {
            let folder = dir.appendingPathComponent(action.folderName, isDirectory: true)
            let urls = scanPNGs(in: folder)
            guard !urls.isEmpty else { continue }
            variantURLs[action] = [urls]
            applyConfig(&fps, &loops, for: action, config: config)
            if let s = scanSound(in: folder) { sounds[action] = s }
        }

        guard !variantURLs.isEmpty else { return nil }

        // 2. 读取原始像素尺寸（只读属性不解码）：baseFrameSize + 降采样目标尺寸
        let scale = CGFloat(config.scale ?? 1.0)
        var widest: Int = 0
        var baseSize: CGSize?
        for (action, variants) in variantURLs {
            guard let first = variants.first?.first,
                  let src = CGImageSourceCreateWithURL(first as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { continue }
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            widest = max(widest, w)
            if action == .idle && w > 0 && h > 0 {
                baseSize = CGSize(width: w, height: h)
            }
        }
        // 降采样目标 = 最宽帧 × 用户缩放 × 皮肤缩放 × 视网膜 2x，限制在 320...640
        let targetPixel = Int(Double(max(widest, 1)) * Double(Defaults[.petScale]) * Double(scale) * 2.0)
        // 上限 300px：宠物显示尺寸 90pt（视网膜 180px），300px 是 1.7 倍采样，清晰度足够。
        // 每帧从 1.14MB(640px) → ~0.38MB(300px)，整体内存降 ~70%。
        // 下限 256 保证极小缩放时仍可识别。
        let maxPixelSize = min(300, max(256, targetPixel))

        let skin = PetSkin(
            variantURLs: variantURLs,
            maxPixelSize: maxPixelSize,
            fps: fps,
            loops: loops,
            sounds: sounds,
            scale: scale,
            baseFrameSize: baseSize,
            sourceURL: dir
        )

        // 3. 启动即同步加载 idle 变体 0 的前几帧（动画立刻可用），后续帧流式补齐。
        // 同步加载保证启动瞬间有帧显示（不闪占位），但只取 trailer 帧省内存
        // （全量 170帧≈194MB → 前24帧≈9MB，剩余靠 backfill 在 idle 循环播放时补齐）。
        // 其余 idle 变体（1/2/3）由下方 prefetch 异步加载 trailer 帧，实现待机变体轮换。
        if let idleVariants = variantURLs[.idle], let firstVariant = idleVariants.first {
            let allSigs = firstVariant.map { frameSignature(from: $0) }
            let trailerCount = min(skin.trailerFrameCount, firstVariant.count)
            let images = Array(firstVariant.prefix(trailerCount))
                .compactMap { decodeDownscaled($0, maxPixel: maxPixelSize) }
            if !images.isEmpty {
                skin.cache[.idle] = [images]
                skin.signatures[.idle] = [allSigs]
                skin.loopPoints[.idle] = [computeLoopPoint(allSigs)]
                if images.count < firstVariant.count {
                    skin.partialLoaded.insert("idle_0")
                }
            }
        }
        // idle 加入预取：加载全部变体的 trailer 帧（变体轮换）；其他动作单变体
        skin.prefetch([.idle, .walk, .yawn, .drag, .happy, .hurt, .fall])

        return skin
    }

    /// 扫描目录内的 PNG/JPG（自然排序）
    private static func scanPNGs(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "png" || $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) ?? []
    }

    /// 扫描目录内的音效
    private static func scanSound(in folder: URL) -> URL? {
        for ext in ["m4a", "mp3", "wav", "aiff"] {
            let url = folder.appendingPathComponent("sound.\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 应用 config.json 的 fps/loops 到动作
    private static func applyConfig(_ fps: inout [PetAction: Double], _ loops: inout [PetAction: Int], for action: PetAction, config: PetSkinConfig) {
        let actionConfig = config.actions?[action.rawValue]
        fps[action] = actionConfig?.fps ?? config.fps ?? action.defaultFPS
        loops[action] = actionConfig?.loops ?? (action.loopsByDefault ? -1 : 1)
    }
}
