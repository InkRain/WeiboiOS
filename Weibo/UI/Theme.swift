import SwiftUI

// MARK: - 颜色与尺寸

enum Theme {
    /// 卡片背景：跟随系统分组背景，深色下不会刺眼。
    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.11) : .white
    }

    static func pageBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.05) : Color(white: 0.96)
    }

    /// 转发引用的浅灰卡片（原版用浅灰而不是描边）。
    static func quoteBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.16) : Color(white: 0.955)
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.22) : Color(white: 0.90)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.62) : Color(white: 0.45)
    }

    static func tertiaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.45) : Color(white: 0.58)
    }

    static let cardRadius: CGFloat = 16
    static let cardSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 14
}

// MARK: - 玻璃质感容器

struct GlassBar: ViewModifier {
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
            }
    }
}

extension View {
    func glassBar(cornerRadius: CGFloat = 26) -> some View {
        modifier(GlassBar(cornerRadius: cornerRadius))
    }

    /// 卡片容器：白色圆角 + 极轻阴影，和原版的「纸片」观感一致。
    func cardSurface(_ scheme: ColorScheme, radius: CGFloat = Theme.cardRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.cardBackground(scheme))
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.separator(scheme).opacity(0.55), lineWidth: 0.5)
        }
    }
}
