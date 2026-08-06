#!/usr/bin/env swift
// extract_audio.swift — 从视频提取音轨为 m4a（动作音效用）
// 用法: swift extract_audio.swift <视频> <输出.m4a>

import AVFoundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: swift extract_audio.swift <视频> <输出.m4a>")
    exit(1)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

let asset = AVURLAsset(url: inputURL)
guard let track = asset.tracks(withMediaType: .audio).first else {
    print("⚠️  视频没有音轨")
    exit(1)
}

try? FileManager.default.removeItem(at: outputURL)
guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
    print("无法创建导出会话")
    exit(1)
}
session.outputURL = outputURL
session.outputFileType = .m4a
session.exportAsynchronously {
    switch session.status {
    case .completed:
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("✅ 音轨 → \(outputURL.lastPathComponent) (\(size / 1024)KB, \(track.estimatedDataRate / 1000)kbps)")
    case .failed:
        print("❌ 导出失败: \(session.error?.localizedDescription ?? "?")")
    default:
        print("状态: \(session.status.rawValue)")
    }
}

while session.status == .waiting || session.status == .exporting || session.status == .unknown {
    usleep(50_000)
}
