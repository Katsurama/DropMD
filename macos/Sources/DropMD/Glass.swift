import SwiftUI

// Liquid Glass：在 macOS 26 及以上使用系统原生的 glassEffect / 玻璃按钮样式，
// 在较早的系统上退回到半透明材质（Material），保证仍可运行。

struct GlassCard: ViewModifier {
    var radius: CGFloat = 22

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}


extension View {
    func glassCard(radius: CGFloat = 22) -> some View { modifier(GlassCard(radius: radius)) }

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
