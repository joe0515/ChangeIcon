import SwiftUI

// MARK: - macOS 26+ Liquid Glass 兼容封装
//
// 项目最低支持 macOS 14，而 Liquid Glass 设计 API（`glassEffect`、
// `.buttonStyle(.glass)` 等）仅 macOS 26+ 可用。这里通过 `#available`
// 条件编译统一封装：macOS 26+ 呈现液态玻璃效果，旧系统自动降级为
// 毛玻璃材质（`.regularMaterial`）与 `.bordered` 按钮。

extension View {
    /// 玻璃卡片背景。
    /// - Parameter cornerRadius: 卡片圆角半径
    /// - Returns: macOS 26+ 用液态玻璃，否则用毛玻璃材质
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
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
