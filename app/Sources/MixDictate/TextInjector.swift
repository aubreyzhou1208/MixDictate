import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// 文字送进去用的方式。三种各有盲区，所以要按顺序降级。
enum InsertionMethod: String, CaseIterable {
    /// 剪贴板 + 合成 Cmd+V。最快，长文本也是一瞬间，绝大多数 App 都支持。
    case paste
    /// 合成 Unicode 按键，等价于"把字一个个敲进去"。
    /// 少数拦截粘贴的 App 只认这个。
    case typing

    var label: String {
        switch self {
        case .paste:  return "粘贴（快，推荐）"
        case .typing: return "逐字输入（慢，兼容性更好）"
        }
    }
}

enum InjectionResult {
    case inserted(InsertionMethod)
    /// 通过辅助功能接口直接写进了输入框（安全输入模式下唯一能用的路）
    case insertedViaAccessibility
    /// 没有辅助功能权限
    case needsAccessibility
    /// 安全输入模式挡着，而且辅助功能接口也写不进去
    case blockedBySecureInput
}

/// 把文字送进当前光标所在的输入框。
///
/// 单一机制做不到"任何地方都能输入"，所以按顺序降级：
///
///   1. 安全输入模式开着时 —— 系统会拦截**一切**合成按键，
///      这时唯一的路是辅助功能接口，直接往聚焦的控件里写。
///   2. 正常情况 —— 剪贴板 + 合成 Cmd+V。最快，长文本也是一瞬间。
///   3. 用户在设置里选了逐字输入 —— 合成 Unicode 按键。
///      少数拦截粘贴的 App 只认这个。
enum TextInjector {
    private static let vKeyCode: CGKeyCode = 9
    private static let deleteKeyCode: CGKeyCode = 51

    @discardableResult
    static func insert(_ text: String, method: InsertionMethod = .paste) -> InjectionResult {
        guard AXIsProcessTrusted() else {
            // 权限缺失时也先把文字放进剪贴板，用户至少能自己 Cmd+V
            copyToPasteboard(text)
            return .needsAccessibility
        }

        // 安全输入模式下合成按键一律无效，先走辅助功能接口
        if IsSecureEventInputEnabled() {
            if insertViaAccessibility(text) {
                return .insertedViaAccessibility
            }
            copyToPasteboard(text)
            return .blockedBySecureInput
        }

        switch method {
        case .paste:
            pasteViaClipboard(text)
        case .typing:
            typeUnicode(text)
        }
        return .inserted(method)
    }

    // MARK: - 剪贴板 + Cmd+V

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        copyToPasteboard(text)

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
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        // 投递到 HID 层。用 .cgAnnotatedSessionEventTap 的话不少 App
        // 收不到合成事件 —— 表现又是"按了没反应"。
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 逐字输入

    /// 合成携带 Unicode 字符的按键事件，等价于把字敲进去。
    /// 不碰剪贴板，也不依赖目标 App 支持粘贴。
    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)

        // 一次事件塞太多字符有的 App 会截断，切成小块更稳
        let chunkSize = 16
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])
            index = end

            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// 直接敲字，不碰剪贴板。实时写入用这个 —— 剪贴板方案没法做增量修改。
    static func typeText(_ text: String) {
        typeUnicode(text)
    }

    /// 连发退格。实时写入时用来抹掉被模型改写掉的那一段。
    static func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        for _ in 0..<count {
            guard
                let down = CGEvent(
                    keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true
                ),
                let up = CGEvent(
                    keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false
                )
            else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 辅助功能接口直写

    /// 直接把文字写进当前聚焦的控件，不经过任何按键事件 ——
    /// 所以安全输入模式拦不住它。
    ///
    /// 代价是覆盖面比粘贴窄：终端、部分 Electron App 的文本视图
    /// 不支持这个属性。所以只在合成按键行不通时才用。
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .success,
            let element = focused,
            CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }

        // 设置"选中的文字"等价于在光标处插入：没有选区时就是纯插入，
        // 有选区时替换掉它 —— 跟真的敲字行为一致。
        let target = element as! AXUIElement
        let status = AXUIElementSetAttributeValue(
            target, kAXSelectedTextAttribute as CFString, text as CFString
        )
        return status == .success
    }

    // MARK: - 杂项

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
