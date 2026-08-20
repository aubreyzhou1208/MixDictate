// 最小状态栏探针。用来把"菜单栏不收 MixDictate"和"这台机器现在不收任何
// 新的状态栏项"分开 —— 这两件事的解法完全相反。
//
//   swift scripts/menubar_probe.swift
//
// 菜单栏上出现 PROBE 就说明 AppKit 和菜单栏本身是好的，问题是 MixDictate
// 独有的；什么都不出现，说明这个用户会话现在不给任何新进程状态栏槽位，
// 那跟 MixDictate 的代码无关。
//
// Ctrl+C 结束。

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        // 只用文字，不用图标 —— 少一个可能画不出来的东西
        item.button?.title = "PROBE"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "探针在运行", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu

        let placed = item.button?.window != nil
        print("状态栏项已创建：button=\(item.button != nil) window=\(placed) "
              + "width=\(item.button?.frame.width ?? -1)")
        print("现在看菜单栏上有没有 PROBE。Ctrl+C 结束。")
    }
}

let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
