//
//  AppIOS.swift
//  人机中国象棋 · iOS 应用入口
//
//  macOS 的入口在 App/main.swift (NSApplication 顶层语句), iOS 走 @main。
//  两个文件都以平台守卫包裹, 所以同一份源码树可以同时编出两个平台的 App。
//
#if canImport(UIKit)
import UIKit

@main
final class AppIOS: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        diag("didFinishLaunching 到达; bundle=OK")
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = GameViewController()
        window?.makeKeyAndVisible()
        diag("window.makeKeyAndVisible 完毕; root=\(String(describing: window?.rootViewController))")
        return true
    }
}

#endif
