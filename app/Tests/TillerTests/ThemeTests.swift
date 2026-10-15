import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
struct ThemeTests {
    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    @Test func eachThemePicksItsPaletteForLightAndDark() {
        #expect(Palette.of(.tiller, dark: false) == nil)
        #expect(Palette.of(.tiller, dark: true) == nil)
        #expect(Palette.of(.claude, dark: false)?.chrome == Palette.claudeLight.chrome)
        #expect(Palette.of(.claude, dark: true)?.chrome == Palette.claudeDark.chrome)
        #expect(Palette.of(.qoder, dark: false)?.chrome == Palette.qoderLight.chrome)
        #expect(Palette.of(.qoder, dark: true)?.chrome == Palette.qoderDark.chrome)
    }

    /// Tiller's own theme keeps the system's colors; another takes its
    /// palette's, in the appearance it is drawn in.
    @Test func colorsFollowTheTheme() {
        let saved = Settings.theme
        defer { Settings.theme = saved }

        Settings.theme = .tiller
        #expect(resolved(Theme.text, in: dark) == resolved(.labelColor, in: dark))
        #expect(resolved(Theme.hairline, in: light) == resolved(.separatorColor, in: light))
        #expect(resolved(Theme.accentColor, in: light) == resolved(Settings.accentTheme.color, in: light))

        Settings.theme = .claude
        #expect(resolved(Theme.chrome, in: light) == resolved(Palette.claudeLight.chrome, in: light))
        #expect(resolved(Theme.text, in: dark) == resolved(Palette.claudeDark.text, in: dark))
        #expect(resolved(Theme.accentColor, in: dark) == resolved(Palette.claudeDark.accent, in: dark))
        #expect(resolved(Theme.selectionColor, in: light) == resolved(Palette.claudeLight.fill, in: light))

        Settings.theme = .qoder
        #expect(resolved(Theme.background, in: dark) == resolved(Palette.qoderDark.background, in: dark))
        #expect(resolved(Theme.accentFillText, in: dark) == resolved(Palette.qoderDark.fillText, in: dark))
    }

    /// A button's label, and text, read on every palette.
    @Test func paletteContrast() {
        for palette in [Palette.claudeLight, .claudeDark, .qoderLight, .qoderDark] {
            #expect(contrast(palette.fillText, palette.fill) >= 4.5)
            #expect(contrast(palette.text, palette.chrome) >= 7)
            #expect(contrast(palette.text, palette.background) >= 7)
            #expect(contrast(palette.muted, palette.chrome) >= 4.5)
        }
    }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> [CGFloat] {
        var components: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            components = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
                .map { ($0 * 255).rounded() }
        }
        return components
    }

    /// WCAG's contrast ratio of two opaque colors.
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
