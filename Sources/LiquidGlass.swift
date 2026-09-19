import SwiftUI

// MARK: - macOS 26+ Liquid Glass 兼容封装
//
// 依据 Apple Liquid Glass 设计规范：`glassEffect`（液态玻璃）应仅用于
// **导航层**（侧边栏、工具栏、浮动控件），而**内容层的卡片**应使用
// `.regularMaterial`（毛玻璃材质）。因此：
//
// - `materialCard`：内容卡片背景，统一用 `.regularMaterial`。
// - `glassButtonStyle`：按钮使用液态玻璃按钮样式（macOS 26+）或降级为
//   `.bordered`（旧系统）。

extension View {
    /// 内容卡片背景：毛玻璃材质。
    /// - Parameter cornerRadius: 卡片圆角半径
    @ViewBuilder
    func materialCard(cornerRadius: CGFloat = 14) -> some View {
        self.background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// 兼容别名：早期实现命名为 `glassCard`，现语义为内容卡片毛玻璃背景。
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        materialCard(cornerRadius: cornerRadius)
    }

    /// 玻璃按钮样式。
    /// - Parameter primary: `true` 使用突出玻璃样式（主操作），否则使用次级玻璃样式
    @ViewBuilder
    func glassButtonStyle(primary: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if primary {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if primary {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Window glass background

/// 让窗口背景透明，以便侧边栏玻璃（NavigationSplitView 自动）与毛玻璃材质
/// 能折射桌面与背后窗口，呈现 macOS 26/27 的液态玻璃观感。
private struct WindowGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
    }
}

extension View {
    /// 将窗口背景设为透明，启用玻璃折射。
    func windowGlassBackground() -> some View {
        background(WindowGlassBackground())
    }
}

