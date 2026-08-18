import AppKit
import ApplicationServices
import CoreGraphics

/// 把文字送进当前光标所在的输入框。
///
/// 走剪贴板 + 合成 Cmd+V，而不是逐字符合成键盘事件 —— 后者对中文输入法
/// 极不可靠，而且长文本会非常慢。用完把剪贴板还原回去。
enum TextInjector {
    private static let vKeyCode: CGKeyCode = 9

    /// 没有辅助功能权限时，系统会**静默丢弃**合成的按键事件 —— 不报错、
    /// 不弹窗，用户看到的就是"按了没反应"。所以每次注入前都要复查：
    /// 权限可能在 App 运行期间被撤销，也可能重新编译后失效。
    /// 返回 false 表示没注入成功，调用方要告诉用户。
    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            // 文字已经在剪贴板里了，用户至少能自己 Cmd+V —— 不还原剪贴板
            return false
        }

        // 给一点时间：用户刚松开说话键，修饰键状态需要先落定，
        // 否则合成的 Cmd+V 可能被残留的 Option 污染成别的快捷键。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postPaste()

            // 粘贴是异步的，等目标 App 真正读完剪贴板再还原
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                if let previous {
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
        return true
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

}
