import SwiftUI

// Liquid Glass：在 macOS 26 及以上使用系统原生的 glassEffect / 玻璃按钮样式，
// 在较早的系统上退回到半透明材质（Material），保证仍可运行。

extension View {
    /// 普通玻璃按钮
    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
        #else
        self.buttonStyle(.bordered).buttonBorderShape(.capsule)
        #endif
    }

    /// 强调色玻璃按钮（主要操作）
    @ViewBuilder
    func glassProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
        #else
        self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        #endif
    }
}
