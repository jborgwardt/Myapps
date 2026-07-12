import SwiftUI

/// Cursor-inspired monochrome dark theme + Liquid Glass helpers.
/// Glass APIs are iOS 26+; every helper degrades to materials on iOS 17–25.
enum CursorTheme {
    /// Near-black app backdrop (Cursor uses ~#0A0A0B).
    static let background = Color(red: 0.039, green: 0.039, blue: 0.045)
    /// Raised card/surface tone.
    static let surface = Color(red: 0.086, green: 0.086, blue: 0.094)
    /// Higher-elevation surface (user chat bubble, chips).
    static let surfaceHigh = Color(red: 0.125, green: 0.125, blue: 0.137)
    /// Hairline borders.
    static let border = Color.white.opacity(0.08)
    /// Monochrome accent — white-on-black primary actions like Cursor's send button.
    static let accent = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let secondaryText = Color(white: 0.62)
}

extension View {
    /// Dark Cursor-like backdrop for List/Form screens.
    func cursorScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(CursorTheme.background.ignoresSafeArea())
    }

    /// Card-style row background for List/Form sections.
    func cursorRows() -> some View {
        listRowBackground(CursorTheme.surface)
    }

    /// Liquid Glass on a custom shape (26+), ultra-thin material + hairline fallback.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(CursorTheme.border, lineWidth: 1))
        }
    }

    /// Prominent action button — Cursor's white-pill-with-dark-text look.
    /// Liquid Glass prominent on 26+, bordered otherwise.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .foregroundStyle(CursorTheme.background)
        } else {
            self.buttonStyle(.borderedProminent)
                .foregroundStyle(CursorTheme.background)
        }
    }

    /// Secondary button — Liquid Glass on 26+, bordered otherwise.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// iOS 26 tab bar minimizes on scroll like Cursor; no-op earlier.
    @ViewBuilder
    func cursorTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
