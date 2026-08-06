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

    /// 预取动作帧（后台解码，不阻塞主线程）。
    /// 加载该动作的**全部变体**——变体选择是随机的，只预取 variant 0 会让
    /// 随机到其他变体时延迟（窗口已动、动画未就绪）。预取未物化时内存极小
    /// （855 帧解码产物约 +74MB，物化只发生在播放时）。
    func prefetch(_ actions: [PetAction]) {
        for action in actions {
            guard let variants = variantURLs[action], !variants.isEmpty else { continue }
            for (vi, urls) in variants.enumerated() where !urls.isEmpty {
                if cache[action]?[safe: vi]?.isEmpty == false { continue }
                let key = "\(action.rawValue)_\(vi)"
                if loading.contains(key) { continue }
                loading.insert(key)
                startLoad(action, variant: vi, urls: urls, isPrefetch: true)
            }
        }
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
    func markPlayed(_ action: PetAction) {
        played.insert(action)
        let keep = Self.coreActions.union([action])
        cache = cache.filter { keep.contains($0.key) }
        self.signatures = self.signatures.filter { keep.contains($0.key) }
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
            // 预取：直接入缓存。淘汰"已播放（物化）过且非核心"的动作——
            // 否则预取覆盖所有高频动作后，播放全命中缓存、播放加载永不触发，
            // 淘汰机制失效，物化内存无限累积（实测 1.3GB）。
            // 未播放的预取动作只是解码产物（便宜，855 帧约 +74MB），可常驻。
            let keep = Self.coreActions.union(variantURLs.keys.filter { !played.contains($0) }).union([action])
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
        let maxPixelSize = min(640, max(320, targetPixel))

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

        // 3. 启动即同步加载 idle 第一个变体（动画立刻可用），并后台预取高频动作
        if let idleVariants = variantURLs[.idle], let firstVariant = idleVariants.first {
            let images = firstVariant.compactMap { decodeDownscaled($0, maxPixel: maxPixelSize) }
            let sigs = firstVariant.map { frameSignature(from: $0) }
            if !images.isEmpty {
                skin.cache[.idle] = [images]
                skin.signatures[.idle] = [sigs]
                skin.loopPoints[.idle] = [computeLoopPoint(sigs)]
            }
        }
        skin.prefetch([.walk, .yawn, .drag, .happy, .hurt, .fall])

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
