//
//  PetState.swift
//  boringNotch
//
//  Created for the desktop pet feature.
//

import Foundation
import Defaults

/// 宠物的动画动作。每个动作对应素材目录下的一个子文件夹（如 `idle/1.png`、`idle/2.png` ...）。
enum PetAction: String, CaseIterable, Identifiable {
    /// 待机循环
    case idle
    /// 走路循环（配合镜像实现左右转向）
    case walk
    /// 睡觉（打瞌睡）
    case sleep
    /// 吃食物（非循环，播完回到 idle）
    case eat
    /// 开心/被抚摸（非循环）
    case happy
    /// 受伤/饥饿（非循环）
    case hurt
    /// 被拎起挣扎（循环，拖拽期间播放）
    case drag
    /// 音乐舞动（循环，音乐播放时使用；素材缺失时自动退化为 idle）
    case music
    /// 垂直爬墙（沿屏幕左右边缘向上爬；素材缺失时用 walk 帧旋转 90° 兜底）
    case climb
    /// 顶部倒挂（爬到屏顶后倒挂摆动；素材缺失时用 idle 帧垂直翻转兜底）
    case hang
    /// 掉落（被打断/松手后重力下落；素材缺失时用 drag 帧翻转兜底）
    case fall
    /// 晕眩（落地后原地转圈，配合 dizzyAngle 旋转）
    case dizzy
    /// 打哈欠（待机时随机出现，一次性）
    case yawn
    /// 回窝后显示的小头像（可选，缺省用 idle 首帧）
    case home

    var id: String { rawValue }

    /// 素材目录名（基础名；变体用 idle_0/idle_1 等，扫描时按前缀归并到同一动作）
    var folderName: String { rawValue }

    /// 缺省帧率（可被 config.json 覆盖）
    var defaultFPS: Double {
        switch self {
        case .walk: return 12
        case .music, .drag: return 14
        case .climb: return 10
        case .hang: return 5
        case .fall: return 20
        case .dizzy, .yawn: return 8
        case .idle, .sleep: return 6
        case .eat, .happy, .hurt, .home: return 10
        }
    }

    /// 是否循环播放
    var loopsByDefault: Bool {
        switch self {
        case .eat, .fall, .happy, .hurt, .yawn: return false
        default: return true
        }
    }
}

/// 宠物的生命周期状态：在桌面活动 / 回窝（藏在刘海后）。
enum PetLifeState: String, Defaults.Serializable {
    /// 在桌面自由活动
    case roaming
    /// 已回窝（窗口隐藏，在刘海关闭态显示小头像）
    case atHome
}
