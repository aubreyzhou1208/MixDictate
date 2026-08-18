import AppKit

/// 直接跳到具体的系统设置页面。
/// 让用户自己在系统设置里翻，很多人翻两下就放弃了。
enum SystemSettings {
    static func openAccessibility() {
        open("com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophone() {
        open("com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:" + pane) else { return }
        NSWorkspace.shared.open(url)
    }
}
