//
//  PetWindow.swift
//  boringNotch
//
//  桌面宠物窗口：无边框、非激活面板，订阅 PetManager 的位置/透明度驱动。
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class PetWindowController {
    static let shared = PetWindowController()

    private var window: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var petEnabledObservation: Defaults.Observation?

    var currentOrigin: CGPoint? {
        window?.frame.origin
    }

    func show() {
        guard window == nil else { return }

        let size = PetManager.shared.windowSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PetContentView())
        panel.orderFrontRegardless()
        window = panel

        PetManager.shared.$windowPosition
            .compactMap { $0 }
            .sink { [weak self] point in
                self?.window?.setFrameOrigin(point)
            }
            .store(in: &cancellables)

        PetManager.shared.$windowAlpha
            .sink { [weak self] alpha in
                guard let self = self, let window = self.window else { return }
                if alpha <= 0 {
                    // 完全隐藏：避免透明窗口仍占屏幕、拦截鼠标事件
                    window.alphaValue = 0
                    window.orderOut(nil)
                } else {
                    if !window.isVisible {
                        window.orderFrontRegardless()
                    }
                    window.alphaValue = alpha
                }
            }
            .store(in: &cancellables)

        PetManager.shared.start()

        // 设置页切换总开关时动态显示/隐藏
        petEnabledObservation = Defaults.observe(.petEnabled) { [weak self] change in
            Task { @MainActor in
                if change.newValue {
                    self?.show()
                } else {
                    self?.hide()
                }
            }
        }
    }

    func hide() {
        petEnabledObservation?.invalidate()
        petEnabledObservation = nil
        PetManager.shared.stop()
        window?.orderOut(nil)
        window = nil
        cancellables.removeAll()
    }

    /// 拖拽期间直接移动窗口
    func moveWindow(to point: CGPoint) {
        window?.setFrameOrigin(point)
    }

    /// 临时把宠物窗口提到刘海窗口（level = .mainMenu + 3）之上。
    /// 用途：拖宠物进入刘海展开区时，避免宠物被刘海窗口遮挡（拖拽全程可见自己在拖什么）。
    /// 必须在拖拽结束/离开区域时配对调用 restoreLevel()。
    func elevateLevel() {
        window?.level = .mainMenu + 4
    }

    /// 恢复宠物窗口默认层级（与 elevateLevel 配对）。
    func restoreLevel() {
        window?.level = .floating
    }

    /// 调整窗口内容尺寸（保持左下角 origin 不变 → 宠物视觉位置不动，面板向上展开）
    func setContentSize(_ size: NSSize) {
        guard let window else { return }
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: true)
    }
}
