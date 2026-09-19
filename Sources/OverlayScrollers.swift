import AppKit
import SwiftUI

/// 强制滚动视图使用 overlay 滚动条：不滚动时自动隐藏，滚动时才显示。
///
/// SwiftUI 的 `.scrollIndicators()` 无法强制该行为（`.visible` 在 macOS 上
/// 仍尊重系统偏好，`.automatic` 跟随系统设置）。这里通过向滚动内容注入一个
/// 配置探针，在其挂载到窗口后找到所在的 `NSScrollView`，把 `scrollerStyle`
/// 设为 `.overlay`。
struct OverlayScrollersModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(OverlayScrollerConfigurator())
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollerStyleProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 透明探针视图：加入窗口后找到所在滚动视图并应用 overlay 样式。
private final class ScrollerStyleProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyOverlayStyle()

        // 兜底：SwiftUI 可能在稍后重建滚动视图，延迟再确认一次
        DispatchQueue.main.async { [weak self] in
            self?.applyOverlayStyle()
        }
    }

    private func applyOverlayStyle() {
        if let scroll = enclosingScrollView {
            scroll.scrollerStyle = .overlay
        } else if let scroll = findScrollViewUpwards() {
            scroll.scrollerStyle = .overlay
        }
    }

    /// 向上遍历 superview 链查找 `NSScrollView`（`enclosingScrollView` 失效时兜底）。
    private func findScrollViewUpwards() -> NSScrollView? {
        var current: NSView? = self
        while let view = current {
            if let scroll = view as? NSScrollView { return scroll }
            current = view.superview
        }
        return nil
    }
}

extension View {
    /// 让滚动条在不滚动时隐藏、滚动时显示（overlay 样式）。
    func overlayScrollers() -> some View {
        modifier(OverlayScrollersModifier())
    }
}
