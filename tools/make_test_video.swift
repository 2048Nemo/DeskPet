#!/usr/bin/env swift
// make_test_video.swift — 用 PNG 帧序列合成测试视频（带透明通道）
// 用法: swift make_test_video.swift <帧目录> <输出.mov> [fps] [帧数] [--greenscreen R,G,B]
//
// 默认: 用 ~/Pictures/BoringPet/walk 的帧合成 24fps 6 秒 ProRes 4444（带 alpha）
// --greenscreen: 额外输出一个绿幕背景版本（模拟用户导出的不透明 MP4）

import AVFoundation
import AppKit

let framesDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "\(NSHomeDirectory())/Pictures/BoringPet/walk"
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/pet_test_alpha.mov"
let fps: Int32 = CommandLine.arguments.count > 3 ? Int32(CommandLine.arguments[3])! : 24
let totalFrames = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 144

var greenKey: (CGFloat, CGFloat, CGFloat)?
if let idx = CommandLine.arguments.firstIndex(of: "--greenscreen"), idx + 1 < CommandLine.arguments.count {
    let parts = CommandLine.arguments[idx + 1].split(separator: ",").compactMap { Double($0) }
    if parts.count == 3 {
        greenKey = (CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2]))
    }
}

let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: framesDir), includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
guard let urls = urls, !urls.isEmpty else { fatalError("no frames in \(framesDir)") }
let images = urls.compactMap { NSImage(contentsOf: $0) }
guard !images.isEmpty else { fatalError("failed to load frames") }
print("loaded \(images.count) frames from \(framesDir)")

let W = 256, H = 256

func pixelBuffer(from image: NSImage, green: (CGFloat, CGFloat, CGFloat)? = nil) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32ARGB,
        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
    guard let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )!
    if let green = green {
        ctx.setFillColor(CGColor(red: green.0 / 255, green: green.1 / 255, blue: green.2 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    if let cg = rep.cgImage {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

func writeVideo(path: String, green: (CGFloat, CGFloat, CGFloat)? = nil) {
    let outputURL = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: outputURL)
    let writer = try! AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.proRes4444,
        AVVideoWidthKey: W,
        AVVideoHeightKey: H,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: W,
        kCVPixelBufferHeightKey as String: H,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var frameIndex = 0
    while frameIndex < totalFrames {
        if input.isReadyForMoreMediaData {
            let image = images[frameIndex % images.count]
            if let pb = pixelBuffer(from: image, green: green) {
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                adaptor.append(pb, withPresentationTime: time)
            }
            frameIndex += 1
        } else {
            usleep(5000)
        }
    }
    input.markAsFinished()
    let sema = DispatchSemaphore(value: 0)
    writer.finishWriting { sema.signal() }
    sema.wait()
    print("\(green == nil ? "alpha" : "greenscreen") video: \(path) (\(totalFrames) frames @ \(fps)fps, status=\(writer.status.rawValue))")
}

writeVideo(path: outputPath)
if let green = greenKey {
    let greenPath = (outputPath as NSString).deletingPathExtension + "_green.mov"
    writeVideo(path: greenPath, green: green)
}
