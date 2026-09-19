import AppKit
import SwiftUI

/// 强制滚动视图使用 overlay 滚动条：不滚动时自动隐藏，滚动时才显示。
///
/// SwiftUI 的 `.scrollIndicators()` 无法强制该行为（`.visible` 在 macOS 上
/// 仍尊重系统偏好），且 SwiftUI 的 List/ScrollView 底层 NSScrollView 埋在
/// 很深的私有视图层级中，局部探针难以定位。因此这里**遍历整个窗口视图树**，
/// 找到全部 `NSScrollView` 并把 `scrollerStyle` 设为 `.overlay`。
@MainActor
enum OverlayScrollerStyle {
    /// 应用到当前应用的所有窗口。
    static func applyToAllWindows() {
        for window in NSApp.windows {
            apply(window.contentView)
        }
    }

    /// 深度优先遍历视图树。
    static func apply(_ root: NSView?) {
        guard let root else { return }
        if let scrollView = root as? NSScrollView {
            scrollView.scrollerStyle = .overlay
        }
        for subview in root.subviews {
            apply(subview)
        }
    }
}

private struct OverlayScrollerProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 挂载时立即应用，并延迟兜底（覆盖 SwiftUI 延迟创建的滚动视图）
        DispatchQueue.main.async {
            OverlayScrollerStyle.applyToAllWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            OverlayScrollerStyle.applyToAllWindows()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// 让滚动条在不滚动时隐藏、滚动时显示（overlay 样式）。
    func overlayScrollers() -> some View {
        background(OverlayScrollerProbe())
    }
}
