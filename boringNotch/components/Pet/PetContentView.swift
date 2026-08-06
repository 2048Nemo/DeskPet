//
//  PetContentView.swift
//  boringNotch
//
//  宠物视图与交互：序列帧渲染、单击戳、双击回窝/出窝、拖拽拎起、右键菜单。
//

import AppKit
import Defaults
import SwiftUI

/// 序列帧渲染视图（素材即动画，不做程序化旋转/翻转变换）
struct PetSpriteView: View {
    @ObservedObject var pet = PetManager.shared

    var body: some View {
        Group {
            if let frame = pet.currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: pet.facingLeft ? -1 : 1, y: 1, anchor: .center)
            } else {
                // 无素材时的占位（默认皮肤未安装）
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: 72, height: 72)
                    Image(systemName: "cat.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
        }
    }
}

/// 宠物主视图（窗口内容）
struct PetContentView: View {
    @ObservedObject var pet = PetManager.shared
    @State private var showActionPanel = false
    /// 单击/双击判定：SwiftUI 的 onTapGesture(count:1)+count:2 并存时，
    /// 单击要等双击判定窗口（~0.4s）才触发——点击响应被延迟。
    /// 改用统一 DragGesture + 时间戳自行判定，单击立即响应。
    @State private var lastClickTime = Date.distantPast
    /// 操作面板在宠物上方的展开高度（窗口临时增高，宠物保持底部不动）
    private static let panelHeight: CGFloat = 78

    var body: some View {
        ZStack(alignment: .bottom) {
            PetSpriteView()

            // 操作面板：自绘 SwiftUI（nonactivating 面板上的 NSMenu 子菜单会闪退，
            // 因此不用 contextMenu，改用窗口内浮层）。
            // 面板放在宠物上方（窗口增高部分），不遮挡宠物动画。
            if showActionPanel, pet.lifeState == .roaming {
                PetActionPanel(pet: pet) {
                    withAnimation(.spring(duration: 0.2)) {
                        showActionPanel = false
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .frame(width: pet.windowSize.width, height: contentHeight)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .gesture(
            // 统一手势：不移动=点击（单击立即响应/双击回窝），移动=拖拽拎起
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pet.isDragging, hypot(value.translation.width, value.translation.height) > 3 {
                        pet.startDrag()
                        withAnimation(.spring(duration: 0.2)) {
                            showActionPanel = false
                        }
                    }
                    if pet.isDragging {
                        let mouse = NSEvent.mouseLocation
                        let size = pet.windowSize
                        PetWindowController.shared.moveWindow(
                            to: CGPoint(
                                x: mouse.x - size.width / 2,
                                y: mouse.y - size.height / 2
                            )
                        )
                    }
                }
                .onEnded { value in
                    if pet.isDragging {
                        pet.endDrag()
                        // 拖拽结束后同步内部位置，避免继续走动时跳回旧位置
                        pet.syncWindowPosition(PetWindowController.shared.currentOrigin)
                    } else if hypot(value.translation.width, value.translation.height) < 3 {
                        handleClick()
                    } else {
                        Logger.log("Pet drag ended without start (translation \(String(format: "%.0f,%.0f", value.translation.width, value.translation.height)))", category: .debug)
                    }
                }
        )
        .onChange(of: showActionPanel) { _, showing in
            // 面板展开/收起时增高/恢复窗口（origin 不变 → 宠物视觉位置不动）
            PetWindowController.shared.setContentSize(
                NSSize(width: pet.windowSize.width, height: contentHeight)
            )
        }
        .onAppear {
            if pet.skin == nil {
                Logger.log("Pet skin missing — placeholder shown. See PET.md for skin setup.", category: .warning)
            }
        }
    }

    /// 单击/双击判定（时间戳，单击零延迟）
    private func handleClick() {
        let now = Date()
        if now.timeIntervalSince(lastClickTime) < 0.4 {
            // 双击：回窝 / 出窝
            lastClickTime = .distantPast
            withAnimation(.spring(duration: 0.2)) {
                showActionPanel = false
            }
            if pet.lifeState == .atHome {
                pet.leaveHome()
            } else {
                pet.goHome()
            }
            Logger.log("Pet double-click (\(pet.lifeState == .atHome ? "leave" : "go") home)", category: .debug)
        } else {
            // 单击：立即响应（戳一下 + 弹出操作面板）
            lastClickTime = now
            if showActionPanel {
                withAnimation(.spring(duration: 0.2)) {
                    showActionPanel = false
                }
            } else {
                pet.poke()
                withAnimation(.spring(duration: 0.2)) {
                    showActionPanel = true
                }
            }
        }
    }

    /// 窗口内容高度：宠物高度 + 面板展开高度
    private var contentHeight: CGFloat {
        pet.windowSize.height + (showActionPanel ? Self.panelHeight : 0)
    }

    /// 根据状态生成情绪 emoji
    private var statusEmoji: String {
        let mood = pet.happiness
        if mood > 70 { return "😺" }
        if mood > 40 { return "🙂" }
        if mood > 20 { return "😿" }
        return "😾"
    }
}

/// 宠物操作面板（单击宠物弹出）：状态 + 抚摸 + 回窝
struct PetActionPanel: View {
    @ObservedObject var pet: PetManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("\(statusEmoji) \(moodEmoji) \(Int(pet.happiness))%  ✨ \(Int(pet.cleanliness))%")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                Button {
                    pet.pet()
                    onClose()
                } label: {
                    Label("Pet", systemImage: "hand.wave.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button {
                    pet.goHome()
                    onClose()
                } label: {
                    Label("Home", systemImage: "house.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    private var statusEmoji: String {
        let mood = pet.happiness
        if mood > 70 { return "😺" }
        if mood > 40 { return "🙂" }
        if mood > 20 { return "😿" }
        return "😾"
    }

    private var moodEmoji: String {
        switch Int(pet.happiness) {
        case 80...100: return "❤️"
        case 50..<80: return "💛"
        case 20..<50: return "🧡"
        default: return "💔"
        }
    }
}

/// 回窝状态时在刘海关闭态显示：睡着的猫趴在黑色刘海条上（点击可出窝）。
/// 黑色条是刘海本体（保留 hover/点击区域）。
/// 无刘海屏：猫 + 💤 居中趴在条上；
/// 真刘海屏：刘海区域物理无像素，猫 + 💤 移到刘海右侧的可见区（auxiliary 区域）。
struct PetHomeView: View {
    @ObservedObject var pet = PetManager.shared
    /// 刘海关闭态条宽/高（由 ContentView 传入，与其他关闭态分支保持一致）
    var barWidth: CGFloat = 154
    var barHeight: CGFloat = 34
    @State private var hovering = false
    @State private var zzzPulse = false

    /// 当前 Notch 所在屏是否为真刘海屏（safeAreaInsets.top > 0）
    private var hasRealNotch: Bool {
        let uuid = BoringViewCoordinator.shared.selectedScreenUUID
        let screen = uuid.isEmpty ? NSScreen.main : NSScreen.screen(withUUID: uuid)
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }

    var body: some View {
        // 设计：假刘海不显示任何宠物内容（与真刘海等大，不拓宽、不占辅助区）。
        // 宠物回家后关闭态按原版 notch 规则渲染；宠物内容只在打开态 Pet 页展示。
        Rectangle()
            .fill(.black)
            .frame(width: barWidth, height: barHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                pet.leaveHome()
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("Click to let your pet out")
    }

    /// 睡猫 + 💤（可点击出窝的视觉主体）
    private var catAndZzz: some View {
        HStack(spacing: 3) {
            if let frame = pet.skin?.frames(for: .home)?.first {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(height: barHeight)
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }

            Text("💤")
                .font(.system(size: 13))
                .offset(y: -barHeight * 0.28)
                .scaleEffect(zzzPulse ? 1.0 : 0.7)
                .opacity(zzzPulse ? 1 : 0.4)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: zzzPulse)
        }
        .scaleEffect(hovering ? 1.15 : 1)
        .shadow(color: hovering ? .white.opacity(0.5) : .clear, radius: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .onAppear { zzzPulse = true }
    }
}
