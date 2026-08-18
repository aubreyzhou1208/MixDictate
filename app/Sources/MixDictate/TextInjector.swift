import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// 注入结果。不用 Bool 是因为失败有两种完全不同的原因，
/// 需要告诉用户的话也完全不同。
enum InjectionResult {
    case inserted
    /// 没有辅助功能权限
    case needsAccessibility
    /// 某个 App 开启了安全输入模式，系统拦截了所有合成按键
    case blockedBySecureInput
}

/// 把文字送进当前光标所在的输入框。
///
/// 走剪贴板 + 合成 Cmd+V，而不是逐字符合成键盘事件 —— 后者对中文输入法
/// 极不可靠，而且长文本会非常慢。用完把剪贴板还原回去。
enum TextInjector {
    private static let vKeyCode: CGKeyCode = 9

    /// 注入前必须逐项复查。这两个条件都会让系统**静默丢弃**合成的按键 ——
    /// 不报错、不弹窗，用户看到的就是"按了没反应"：
    ///
    ///   · 没有辅助功能权限（可能在运行期间被撤销，重新编译后也会失效）
    ///   · 有 App 开着安全输入模式（密码框、某些终端）
    ///
    /// 两种情况下文字都已经在剪贴板里，用户至少能自己按 Cmd+V。
    @discardableResult
    static func insert(_ text: String) -> InjectionResult {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            return .needsAccessibility
        }
        guard !IsSecureEventInputEnabled() else {
            return .blockedBySecureInput
        }

        // 给一点时间：用户刚松开说话键，修饰键状态需要先落定，
        // 否则合成的 Cmd+V 可能被残留的 Option 污染成别的快捷键。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            postPaste()

            // 粘贴是异步的，等目标 App 真正读完剪贴板再还原
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                if let previous {
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
        return .inserted
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        // 投递到 HID 层。用 .cgAnnotatedSessionEventTap 的话，不少 App
        // 根本收不到合成事件 —— 表现又是"按了没反应"。
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 哪个 App 开着安全输入模式查不出来（系统不提供接口），
    /// 但至少能告诉用户是这件事挡住了。
    static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
