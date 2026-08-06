//
//  PetNotchView.swift
//  boringNotch
//
//  "宠物的家"：刘海展开后的宠物页面（与 Home / Shelf 并列的第三个标签页）。
//  布局与主页/文件页一致：左右两栏 —— 左侧宠物卡片（与专辑图同尺寸 90×90），
//  右侧信息面板（与日历同宽 215），交互元素保持靠上。
//

import SwiftUI

struct PetNotchView: View {
    @ObservedObject var pet = PetManager.shared
    @State private var zzzPulse = false

    var body: some View {
        // 与 NotchHomeView.mainContent 相同的布局：HStack(alignment: .top, spacing: 15)
        HStack(alignment: .top, spacing: 15) {
            // 左侧：宠物卡片（90×90、圆角 13 —— 与专辑图 AlbumArtView 打开态一致）
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )

                if let frame = pet.lifeState == .atHome
                    ? pet.skin?.frames(for: .home)?.first
                    : pet.currentFrame
                {
                    Image(nsImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 82, height: 82)
                } else {
                    Image(systemName: "cat.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                }

                // 在窝时右上角 💤
                if pet.lifeState == .atHome {
                    Text("💤")
                        .font(.system(size: 16))
                        .offset(x: 32, y: -32)
                        .scaleEffect(zzzPulse ? 1.0 : 0.65)
                        .opacity(zzzPulse ? 1 : 0.45)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: zzzPulse)
                        .onAppear { zzzPulse = true }
                }
            }
            .frame(width: 90, height: 90)

            // 右侧：信息面板（宽 215 —— 与日历 CalendarView 一致）
            VStack(alignment: .leading, spacing: 10) {
                // 标题行
                HStack(spacing: 6) {
                    Image(systemName: "pawprint.fill")
                        .foregroundStyle(.white)
                    Text(pet.lifeState == .atHome ? "宠物的家" : "宠物")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(pet.lifeState == .atHome ? "💤 睡觉中" : "🏃 桌面上")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // 属性胶囊
                HStack(spacing: 10) {
                    Label("\(Int(pet.happiness))%", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    Label("\(Int(pet.cleanliness))%", systemImage: "sparkles")
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .font(.system(size: 11, weight: .medium))

                // 操作按钮（保持靠上，不超出 hover 范围）
                HStack(spacing: 8) {
                    if pet.lifeState == .atHome {
                        Button {
                            pet.leaveHome()
                        } label: {
                            Label("出窝", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button {
                            pet.goHome()
                        } label: {
                            Label("召回", systemImage: "house.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        pet.pet()
                    } label: {
                        Label("抚摸", systemImage: "hand.wave.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
                .font(.system(size: 12))
                .controlSize(.small)

                Spacer(minLength: 0)
            }
            .frame(width: 215, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 与主页（NotchHomeView）一致的页面切换动画：淡入淡出
        .transition(.opacity)
    }
}