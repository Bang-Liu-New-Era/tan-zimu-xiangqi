//
//  MenuBuilder.swift
//  人机中国象棋 · 主菜单构建
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

func buildMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem(title: "象棋", action: nil, keyEquivalent: "")
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "关于人机中国象棋",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu; main.addItem(appItem)

    // 「特技」菜单: 走子轨迹 / 缓动 / 天气 / 裂痕 / 演员。勾选项即时生效并被记到 UserDefaults。
    let fxItem = NSMenuItem(title: "特技", action: nil, keyEquivalent: "")
    let fxMenu = NSMenu()
    func submenu(_ title: String, _ sel: Selector, _ labels: [String]) -> NSMenu {
        let m = NSMenu()
        for (i, lb) in labels.enumerated() {
            let it = NSMenuItem(title: lb, action: sel, keyEquivalent: "")
            it.target = delegate; it.tag = i
            m.addItem(it)
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        fxMenu.addItem(holder)
        return m
    }
    let trajMenu = submenu("走子轨迹", #selector(AppDelegate.pickTrajectory(_:)),
                           Trajectory.Shape.allCases.map { $0.label })
    let easeMenu = submenu("缓动曲线", #selector(AppDelegate.pickEase(_:)),
                           Ease.allCases.map { $0.label })
    let weatherMenu = submenu("天气", #selector(AppDelegate.pickWeather(_:)),
                              Weather.Kind.allCases.map { $0.label })
    fxMenu.addItem(.separator())
    let crackIt = NSMenuItem(title: "吃子留裂痕", action: #selector(AppDelegate.toggleCrack), keyEquivalent: "")
    crackIt.target = delegate; fxMenu.addItem(crackIt)
    delegate.crackMenuItem = crackIt
    let clearIt = NSMenuItem(title: "清除棋盘裂痕", action: #selector(AppDelegate.doClearDecals), keyEquivalent: "")
    clearIt.target = delegate; fxMenu.addItem(clearIt)
    fxMenu.addItem(.separator())
    let horseIt = NSMenuItem(title: "马跑过画面", action: #selector(AppDelegate.doRunHorse), keyEquivalent: "")
    horseIt.target = delegate; fxMenu.addItem(horseIt)
    fxItem.submenu = fxMenu; main.addItem(fxItem)
    delegate.fxMenus = [trajMenu, easeMenu, weatherMenu]
    delegate.refreshFXMenu()

    let winItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
    let winMenu = NSMenu()
    let show = NSMenuItem(title: "显示主窗口", action: #selector(AppDelegate.showMainWindow), keyEquivalent: "0")
    show.target = delegate
    winMenu.addItem(show)
    winMenu.addItem(.separator())
    winMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    winItem.submenu = winMenu; main.addItem(winItem)
    return main
}
