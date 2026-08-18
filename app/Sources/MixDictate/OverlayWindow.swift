import AppKit

/// 录音时显示实时转写结果的浮层。
///
/// 关键约束：这个窗口**绝对不能抢焦点**。用 .nonactivatingPanel + 手动
/// orderFrontRegardless()，一旦焦点跑到浮层上，"插入到当前光标处"就废了 ——
/// 粘贴会粘到一个不存在的输入框里。
@MainActor
final class OverlayWindow {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    private let width: CGFloat = 560
    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 16

    // MARK: - 显示

    func show(placeholder: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let panel = existingPanel()
        label?.stringValue = placeholder
        label?.textColor = .secondaryLabelColor
        layout()

        // 不用 makeKeyAndOrderFront —— 那会抢焦点
        panel.orderFrontRegardless()
    }

    func update(_ text: String, isFinal: Bool) {
        guard panel != nil else { return }
        label?.stringValue = text.isEmpty ? "…" : text
        label?.textColor = isFinal ? .labelColor : .secondaryLabelColor
        layout()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()

        guard delay > 0 else {
            panel?.orderOut(nil)
            return
        }

        // 松手后让最终结果在屏幕上停一下，用户才看得清改成了什么
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 构建

    private func existingPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        // 切到别的桌面 / 全屏 App 时浮层要跟过去
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 圆角必须用 maskImage 而不是 layer.cornerRadius。
        // NSVisualEffectView 的材质是系统在图层之外合成的，cornerRadius +
        // masksToBounds 裁不干净，四角会露出一圈没被裁掉的白边。
        effect.maskImage = Self.roundedMask(radius: 14)

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 17)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.backgroundColor = .clear
        label.isBezeled = false

        effect.addSubview(label)
        panel.contentView = effect

        self.panel = panel
        self.label = label
        return panel
    }

    /// 可拉伸的圆角遮罩。capInsets 让四角保持原样、只拉伸中间，
    /// 这样同一张图能适配任意尺寸的浮层。
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let diameter = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: diameter, height: diameter),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius, bottom: radius, right: radius
        )
        image.resizingMode = .stretch
        return image
    }

    private func layout() {
        guard let panel, let label, let screen = NSScreen.main else { return }

        let textWidth = width - horizontalPadding * 2
        let textHeight = max(
            22,
            label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        )
        let panelHeight = textHeight + verticalPadding * 2

        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.minY + 120  // 抬离屏幕底部，别压住 Dock
        )

        panel.setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: panelHeight)),
            display: true
        )
        label.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textWidth,
            height: textHeight
        )
    }
}
