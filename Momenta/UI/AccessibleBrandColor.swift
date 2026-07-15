import AppKit
import SwiftUI

/// An sRGB color used for deterministic WCAG contrast calculations.
struct SRGBColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red.clamped(to: 0...1)
        self.green = green.clamped(to: 0...1)
        self.blue = blue.clamped(to: 0...1)
    }

    init?(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    func contrastRatio(against other: SRGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func composited(over background: SRGBColor, opacity: Double) -> SRGBColor {
        let alpha = opacity.clamped(to: 0...1)
        return SRGBColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    fileprivate var okLab: OKLab {
        let r = Self.linearized(red)
        let g = Self.linearized(green)
        let b = Self.linearized(blue)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)

        return OKLab(
            lightness: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
            a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
            b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
        )
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    fileprivate static func encoded(_ component: Double) -> Double {
        component <= 0.0031308
            ? 12.92 * component
            : 1.055 * pow(component, 1 / 2.4) - 0.055
    }
}

/// Pure color math separated from the AppKit appearance resolver so it can be
/// exhaustively tested without a window or current drawing appearance.
enum AccessibleColorAdjustment {
    /// Returns the perceptually nearest hue-preserving color that meets the
    /// requested contrast against every adjacent background.
    static func adjusted(
        _ source: SRGBColor,
        against backgrounds: [SRGBColor],
        minimumContrast: Double
    ) -> SRGBColor {
        guard !backgrounds.isEmpty else { return source }
        let target = max(1, minimumContrast)
        if meetsContrast(source, backgrounds: backgrounds, target: target) {
            return source
        }

        let sourceLab = source.okLab
        let sourceLCH = sourceLab.okLCH
        var best: Candidate?

        // Search the full lightness range while holding hue and chroma. When
        // that chroma falls outside sRGB, gamut-map by reducing chroma only.
        for index in 0...1024 {
            consider(
                lightness: Double(index) / 1024,
                sourceLab: sourceLab,
                sourceLCH: sourceLCH,
                backgrounds: backgrounds,
                target: target,
                best: &best
            )
        }

        // Refine around the best sampled lightness so the result sits close
        // to the contrast boundary instead of visibly overshooting it.
        if best != nil {
            var radius = 1.0 / 1024
            for _ in 0..<4 {
                let center = best!.lightness
                for offset in -10...10 {
                    consider(
                        lightness: center + Double(offset) * radius / 10,
                        sourceLab: sourceLab,
                        sourceLCH: sourceLCH,
                        backgrounds: backgrounds,
                        target: target,
                        best: &best
                    )
                }
                radius /= 10
            }
            return best!.color
        }

        // With the card and its tint being close in luminance, one endpoint
        // will normally pass. This fallback also makes unusual custom
        // appearances deterministic.
        let endpoints = [
            SRGBColor(red: 0, green: 0, blue: 0),
            SRGBColor(red: 1, green: 1, blue: 1),
        ]
        return endpoints
            .filter { meetsContrast($0, backgrounds: backgrounds, target: target) }
            .min { $0.okLab.distance(to: sourceLab) < $1.okLab.distance(to: sourceLab) }
            ?? endpoints.max {
                worstContrast($0, backgrounds: backgrounds) < worstContrast($1, backgrounds: backgrounds)
            }!
    }

    static func meetsContrast(
        _ color: SRGBColor,
        backgrounds: [SRGBColor],
        target: Double
    ) -> Bool {
        backgrounds.allSatisfy { color.contrastRatio(against: $0) >= target }
    }

    private static func consider(
        lightness: Double,
        sourceLab: OKLab,
        sourceLCH: OKLCH,
        backgrounds: [SRGBColor],
        target: Double,
        best: inout Candidate?
    ) {
        guard (0...1).contains(lightness) else { return }
        let color = SRGBColor.gamutMapped(
            lightness: lightness,
            chroma: sourceLCH.chroma,
            hue: sourceLCH.hue
        )
        guard meetsContrast(color, backgrounds: backgrounds, target: target) else { return }
        let candidate = Candidate(
            color: color,
            lightness: lightness,
            distance: color.okLab.distance(to: sourceLab)
        )
        if best == nil || candidate.distance < best!.distance {
            best = candidate
        }
    }

    private static func worstContrast(_ color: SRGBColor, backgrounds: [SRGBColor]) -> Double {
        backgrounds.map { color.contrastRatio(against: $0) }.min() ?? 1
    }

    private struct Candidate {
        var color: SRGBColor
        var lightness: Double
        var distance: Double
    }
}

/// Resolves semantic AppKit colors for the active appearance, then caches the
/// accessible presentation color used by chart strokes, points, and labels.
@MainActor
enum AccessibleBrandColor {
    private struct CacheKey: Hashable {
        var source: SRGBColor
        var backgrounds: [SRGBColor]
        var minimumContrast: Double
    }

    private static var cache: [CacheKey: SRGBColor] = [:]

    static func color(
        hex: String,
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast,
        isAhead: Bool
    ) -> Color {
        let appearanceName: NSAppearance.Name
        switch (colorScheme, colorSchemeContrast) {
        case (.dark, .increased):
            appearanceName = .accessibilityHighContrastDarkAqua
        case (.dark, _):
            appearanceName = .darkAqua
        case (_, .increased):
            appearanceName = .accessibilityHighContrastAqua
        default:
            appearanceName = .aqua
        }
        guard let appearance = NSAppearance(named: appearanceName) else {
            return Color(hex: hex)
        }

        let background = resolved(.controlBackgroundColor, appearance: appearance)
        // Keep this in sync with ClientCardView's status palette: the brand
        // stroke and label sit directly on this 10% variance fill.
        let tint = statusTint(isAhead: isAhead, colorScheme: colorScheme)
        let source = SRGBColor(hex: hex)
            ?? resolved(.controlAccentColor, appearance: appearance)
        guard let background, let tint, let source else {
            return Color(hex: hex)
        }

        let tintedBackground = tint.composited(over: background, opacity: 0.1)
        let minimumContrast = colorSchemeContrast == .increased ? 7.0 : 4.5
        let backgrounds = [background, tintedBackground]
        let key = CacheKey(
            source: source,
            backgrounds: backgrounds,
            minimumContrast: minimumContrast
        )
        if let cached = cache[key] {
            return cached.color
        }

        let adjusted = AccessibleColorAdjustment.adjusted(
            source,
            against: backgrounds,
            minimumContrast: minimumContrast
        )
        cache[key] = adjusted
        return adjusted.color
    }

    private static func resolved(_ color: NSColor, appearance: NSAppearance) -> SRGBColor? {
        var resolved: SRGBColor?
        appearance.performAsCurrentDrawingAppearance {
            guard let converted = color.usingColorSpace(.sRGB) else { return }
            resolved = SRGBColor(
                red: converted.redComponent,
                green: converted.greenComponent,
                blue: converted.blueComponent
            )
        }
        return resolved
    }

    private static func statusTint(isAhead: Bool, colorScheme: ColorScheme) -> SRGBColor? {
        let hex: String
        switch (isAhead, colorScheme) {
        case (true, .light): hex = "#24A148"
        case (true, .dark): hex = "#42BE65"
        case (false, .light): hex = "#DA1E28"
        case (false, .dark): hex = "#FA4D56"
        @unknown default: hex = isAhead ? "#24A148" : "#DA1E28"
        }
        return SRGBColor(hex: hex)
    }
}

private struct OKLab {
    var lightness: Double
    var a: Double
    var b: Double

    var okLCH: OKLCH {
        OKLCH(
            lightness: lightness,
            chroma: hypot(a, b),
            hue: atan2(b, a)
        )
    }

    func distance(to other: OKLab) -> Double {
        sqrt(
            pow(lightness - other.lightness, 2)
                + pow(a - other.a, 2)
                + pow(b - other.b, 2)
        )
    }
}

private struct OKLCH {
    var lightness: Double
    var chroma: Double
    var hue: Double
}

private struct LinearRGB {
    var red: Double
    var green: Double
    var blue: Double

    var isInGamut: Bool {
        let tolerance = 0.000_000_1
        return red >= -tolerance && red <= 1 + tolerance
            && green >= -tolerance && green <= 1 + tolerance
            && blue >= -tolerance && blue <= 1 + tolerance
    }

    var sRGB: SRGBColor {
        SRGBColor(
            red: SRGBColor.encoded(red),
            green: SRGBColor.encoded(green),
            blue: SRGBColor.encoded(blue)
        )
    }
}

private extension SRGBColor {
    static func gamutMapped(lightness: Double, chroma: Double, hue: Double) -> SRGBColor {
        var lowerChroma = 0.0
        var upperChroma = chroma
        var best = linearRGB(lightness: lightness, chroma: 0, hue: hue)

        for _ in 0..<24 {
            let candidateChroma = (lowerChroma + upperChroma) / 2
            let candidate = linearRGB(
                lightness: lightness,
                chroma: candidateChroma,
                hue: hue
            )
            if candidate.isInGamut {
                lowerChroma = candidateChroma
                best = candidate
            } else {
                upperChroma = candidateChroma
            }
        }
        return best.sRGB
    }

    static func linearRGB(lightness: Double, chroma: Double, hue: Double) -> LinearRGB {
        let a = chroma * cos(hue)
        let b = chroma * sin(hue)
        let lRoot = lightness + 0.3963377774 * a + 0.2158037573 * b
        let mRoot = lightness - 0.1055613458 * a - 0.0638541728 * b
        let sRoot = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l = pow(lRoot, 3)
        let m = pow(mRoot, 3)
        let s = pow(sRoot, 3)

        return LinearRGB(
            red: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            green: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            blue: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
