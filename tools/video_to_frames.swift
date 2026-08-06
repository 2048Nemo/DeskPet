#!/usr/bin/env swift
// video_to_frames.swift v3 — 视频抽帧为透明 PNG 序列（无 ffmpeg 依赖，原生 AVFoundation）
//
// 用法: swift video_to_frames.swift <视频> <输出目录> [fps] [--trim] [--key R,G,B,tolerance] [--scale N]
//
// 背景知识（重要）：
//   很多"扣背景"导出的视频其实没有 alpha 通道（Premiere 导出未勾选 alpha 时，
//   ProRes 4444 为 24-bit，背景是纯黑实底）。本工具自动检测：
//   - 有真 alpha（如 HEVC with Alpha / 带 alpha 的 4444）：直接用原生 alpha
//   - 无 alpha + 纯色背景：按背景色做"软边缘抠图"，再对内部空洞回填
//     （保住眼睛、深色描边等被背景色误杀的内部特征）
//
// 抠图参数（可用 --key 指定颜色，默认黑）：
//   keyLo / keyHi：像素到背景色距离 < keyLo → alpha=0；> keyHi → alpha=255；中间线性过渡（软边缘）
//
// - AVAssetReader 直接读 CVPixelBuffer（AVAssetImageGenerator 会丢 alpha，不可用）
// - --trim  自动裁剪：统计全部帧的不透明像素统一包围盒（+边距），裁掉画布空白
// - --scale N 输出前缩放到宽 N（保持比例；需与 --trim 配合效果最好）
// - 输出 1.png 2.png 3.png ...（自然排序，直接进宠物素材目录）

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// 用 ImageIO 写 PNG（NSBitmapImageRep 的 PNG 编码在 macOS 26 上会丢 alpha，不可用）
func writePNG(_ cg: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, cg, nil)
    return CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: swift video_to_frames.swift <视频> <输出目录> [fps] [--key R,G,B,tolerance] [--trim] [--scale N]")
    exit(1)
}
let videoPath = args[1]
let outDir = args[2]
var fps = 24
var keyColor: (r: Int, g: Int, b: Int, tol: Int)? = nil
var keyLo = 15, keyHi = 90
var doTrim = false
var scaleW: Int? = nil

var idx = 3
while idx < args.count {
    switch args[idx] {
    case "--trim": doTrim = true
    case "--key":
        let parts = args[idx + 1].split(separator: ",").compactMap { Int($0) }
        if parts.count >= 3 {
            keyColor = (parts[0], parts[1], parts[2], parts.count > 3 ? parts[3] : 60)
            keyLo = max(1, keyColor!.tol / 4)
            keyHi = keyColor!.tol
        }
        idx += 1
    case "--scale":
        scaleW = Int(args[idx + 1]); idx += 1
    default:
        if let f = Int(args[idx]) { fps = f }
    }
    idx += 1
}

let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
let duration = CMTimeGetSeconds(asset.duration)
let totalFrames = max(1, Int(duration * Double(fps)))
try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir), withIntermediateDirectories: true)

guard let track = asset.tracks(withMediaType: .video).first else {
    print("⚠️  视频没有视频轨道")
    exit(1)
}
let nativeW = Int(track.naturalSize.width)
let nativeH = Int(track.naturalSize.height)

/// 像素到抠图颜色的距离（曼哈顿距离）
func colorDist(_ r: Int, _ g: Int, _ b: Int) -> Int {
    if let k = keyColor {
        return abs(r - k.r) + abs(g - k.g) + abs(b - k.b)
    }
    return r + g + b  // 默认抠黑
}

/// 核心：32ARGB 像素缓冲 → straight RGBA CGImage
/// 内存布局（32ARGB）：byte0=alpha, byte1=R, byte2=G, byte3=B
/// - nativeAlpha=true：直接用 byte0（真 alpha 视频），仅做 >230→255 去噪
/// - false：软边缘抠图 + 内部空洞回填
func processBuffer(_ pb: CVPixelBuffer, nativeAlpha: Bool,
                   trim: (minX: Int, minY: Int, maxX: Int, maxY: Int)?) -> (CGImage?, Bool) {
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    var out = [UInt8](repeating: 0, count: w * h * 4)

    CVPixelBufferLockBaseAddress(pb, [])
    guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
        CVPixelBufferUnlockBaseAddress(pb, [])
        return (nil, false)
    }

    var hasAlpha = false
    let lo = keyLo, hi = keyHi

    if nativeAlpha {
        // 真 alpha：直接用 + 去噪
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let o = (y * w + x) * 4
                var a = Int(base[i])  // byte0 = alpha
                if a > 230 { a = 255 }
                if a < 250 { hasAlpha = true }
                out[o] = base[i + 1]; out[o + 1] = base[i + 2]; out[o + 2] = base[i + 3]
                out[o + 3] = UInt8(a)
            }
        }
    } else {
        // 软边缘抠图
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let o = (y * w + x) * 4
                let r = Int(base[i + 1]), g = Int(base[i + 2]), b = Int(base[i + 3])
                let d = colorDist(r, g, b)
                let a: Int = d <= lo ? 0 : (d >= hi ? 255 : (d - lo) * 255 / (hi - lo))
                if a < 250 { hasAlpha = true }
                out[o] = UInt8(r); out[o + 1] = UInt8(g); out[o + 2] = UInt8(b)
                out[o + 3] = UInt8(a)
            }
        }
        // 空洞回填（≤2 遍，读旧写新避免级联）：全邻不透明的深色像素（眼睛/内部描边）恢复不透明
        var buf = out
        for _ in 0..<2 {
            var filled = false
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let o = (y * w + x) * 4
                    if buf[o + 3] >= 128 { continue }
                    let n = buf[o - w * 4 + 3] >= 128
                    let s = buf[o + w * 4 + 3] >= 128
                    let e = buf[o + 4 + 3] >= 128
                    let ww = buf[o - 4 + 3] >= 128
                    if n && s && e && ww {
                        buf[o + 3] = 255
                        filled = true
                    }
                }
            }
            out = buf
            if !filled { break }
        }
        // 锐化：边缘 alpha 提升（去掉抠图留下的半透明发丝感）
        for i in stride(from: 3, to: out.count, by: 4) where out[i] >= 235 {
            out[i] = 255
        }
    }

    CVPixelBufferUnlockBaseAddress(pb, [])

    // trim 裁剪（在输出坐标空间）
    var imgW = w, imgH = h
    var useRect: CGRect? = nil
    if let t = trim {
        useRect = CGRect(x: t.minX, y: t.minY, width: t.maxX - t.minX + 1, height: t.maxY - t.minY + 1)
        imgW = t.maxX - t.minX + 1
        imgH = t.maxY - t.minY + 1
    }
    // 缩放
    var targetW = imgW
    if let sw = scaleW { targetW = sw }
    let targetH = imgH * targetW / max(1, imgW)

    // 从 RGBA 数组构建 CGImage（straight alpha）
    var final = [UInt8]()
    if useRect != nil || targetW != imgW {
        final = [UInt8](repeating: 0, count: targetW * targetH * 4)
        let sy0 = useRect.map { Int($0.origin.y) } ?? 0
        let sx0 = useRect.map { Int($0.origin.x) } ?? 0
        for yy in 0..<targetH {
            let sy = min(sy0 + yy * imgH / targetH, h - 1)
            for xx in 0..<targetW {
                let sx = min(sx0 + xx * imgW / targetW, w - 1)
                let si = (sy * w + sx) * 4
                let oi = (yy * targetW + xx) * 4
                final[oi] = out[si]; final[oi + 1] = out[si + 1]; final[oi + 2] = out[si + 2]; final[oi + 3] = out[si + 3]
            }
        }
    } else {
        final = out
    }

    let provider = CGDataProvider(data: Data(final) as CFData)!
    let img = CGImage(width: targetW, height: targetH, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: targetW * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    return (img, hasAlpha)
}

// ── 自动检测：视频是否有真 alpha（看第一帧 byte0 是否有 <250 的像素）──
var nativeAlpha = false
do {
    let probe = try! AVAssetReader(asset: asset)
    let pOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    ])
    probe.add(pOut)
    probe.startReading()
    if let s = pOut.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        CVPixelBufferLockBaseAddress(pb, [])
        var seenAlpha = false
        if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
            outer: for y in stride(from: 0, to: h, by: 3) {
                for x in stride(from: 0, to: w, by: 3) {
                    if base[y * bpr + x * 4] < 250 { seenAlpha = true; break outer }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        nativeAlpha = seenAlpha
    }
    probe.cancelReading()
} catch {}
if nativeAlpha {
    print("ℹ️  视频含真 alpha 通道，直接使用")
} else {
    let kd = keyColor.map { "抠 \($0.r),\($0.g),\($0.b) tol=\($0.tol)（软边缘 \(keyLo)-\(keyHi)）" } ?? "抠黑（软边缘 \(keyLo)-\(keyHi)）"
    print("ℹ️  视频无 alpha 通道 → \(kd)")
}

// ── 第一遍（--trim）：统计不透明像素统一包围盒（+24px 边距）──
var trimBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
if doTrim {
    let reader = try! AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    while let sample = output.copyNextSampleBuffer(),
          let pb = CMSampleBufferGetImageBuffer(sample) {
        CVPixelBufferLockBaseAddress(pb, [])
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    // 抠图后的 alpha 判定：距离 > keyHi 或 原生 alpha > 230 视为不透明
                    let opaque: Bool
                    if nativeAlpha {
                        opaque = base[y * bpr + x * 4] > 230
                    } else {
                        let r = Int(base[y * bpr + x * 4 + 1]), g = Int(base[y * bpr + x * 4 + 2]), b = Int(base[y * bpr + x * 4 + 3])
                        opaque = colorDist(r, g, b) >= keyHi
                    }
                    if opaque {
                        if trimBox == nil {
                            trimBox = (x, y, x, y)
                        } else if var b = trimBox {
                            b.minX = min(b.minX, x); b.minY = min(b.minY, y)
                            b.maxX = max(b.maxX, x); b.maxY = max(b.maxY, y)
                            trimBox = b
                        }
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
    }
    reader.cancelReading()
    if var b = trimBox {
        let pad = 24
        b.minX = max(0, b.minX - pad); b.minY = max(0, b.minY - pad)
        b.maxX = min(nativeW - 1, b.maxX + pad)
        b.maxY = min(nativeH - 1, b.maxY + pad)
        trimBox = b
        print("--trim 包围盒: x[\(b.minX)-\(b.maxX)] y[\(b.minY)-\(b.maxY)]")
    }
}

// ── 第二遍：抽帧输出 ──
let reader2 = try! AVAssetReader(asset: asset)
let output2 = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
])
output2.alwaysCopiesSampleData = false
reader2.add(output2)
reader2.startReading()

var written = 0
var lastTargetIndex = -1
var hasAlpha = false
let frameDuration = 1.0 / Double(fps)

while let sample = output2.copyNextSampleBuffer() {
    let time = CMTimeGetSeconds(sample.presentationTimeStamp)
    let targetIndex = Int(time / frameDuration + 0.5)
    guard targetIndex > lastTargetIndex,
          let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
    lastTargetIndex = targetIndex

    let (cg, frameAlpha) = processBuffer(pb, nativeAlpha: nativeAlpha, trim: trimBox)
    if frameAlpha { hasAlpha = true }
    guard let cg = cg else { continue }

    let url = URL(fileURLWithPath: "\(outDir)/\(targetIndex + 1).png")
    if writePNG(cg, to: url) {
        written += 1
    }
}
reader2.cancelReading()

let alphaStatus = hasAlpha ? "含 alpha 通道（透明背景）" : "无 alpha 通道（不透明）"
if !hasAlpha && keyColor == nil {
    print("⚠️  输出 \(alphaStatus) —— 帧会带实底背景！")
    print("   方案1: 用 --key R,G,B,tolerance 做纯色抠图（绿幕/蓝幕）")
    print("   方案2: 重新导出带透明通道的视频（Premiere 勾选 Include Alpha / 导出为 HEVC with Alpha）")
} else {
    print("✅ 抽出 \(written)/\(totalFrames) 帧 → \(outDir)/  (\(alphaStatus)\(keyColor != nil ? "，已抠图" : "")\(nativeAlpha ? "，原生 alpha" : "，黑底抠图")\(doTrim ? "，已裁剪" : ""))")
}
