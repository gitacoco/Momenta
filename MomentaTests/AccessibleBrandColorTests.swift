import Testing
@testable import Momenta

struct AccessibleBrandColorTests {
    @Test func compliantBrandColorIsPreservedExactly() throws {
        let source = try #require(SRGBColor(hex: "#FFFFFF"))
        let background = try #require(SRGBColor(hex: "#1E1E1E"))

        let adjusted = AccessibleColorAdjustment.adjusted(
            source,
            against: [background],
            minimumContrast: 4.5
        )

        #expect(adjusted == source)
    }

    @Test func darkAppearanceLightensLowContrastBrandColor() throws {
        let source = try #require(SRGBColor(hex: "#00785F"))
        let background = try #require(SRGBColor(hex: "#1E1E1E"))

        let adjusted = AccessibleColorAdjustment.adjusted(
            source,
            against: [background],
            minimumContrast: 4.5
        )

        #expect(adjusted.contrastRatio(against: background) >= 4.5)
        #expect(adjusted.relativeLuminance > source.relativeLuminance)
    }

    @Test func lightAppearanceDarkensLowContrastBrandColor() throws {
        let source = try #require(SRGBColor(hex: "#77AAFF"))
        let background = try #require(SRGBColor(hex: "#FFFFFF"))

        let adjusted = AccessibleColorAdjustment.adjusted(
            source,
            against: [background],
            minimumContrast: 4.5
        )

        #expect(adjusted.contrastRatio(against: background) >= 4.5)
        #expect(adjusted.relativeLuminance < source.relativeLuminance)
    }

    @Test func adjustmentPassesEveryAdjacentBackground() throws {
        let source = try #require(SRGBColor(hex: "#005CAA"))
        let card = try #require(SRGBColor(hex: "#1E1E1E"))
        let statusTint = try #require(SRGBColor(hex: "#FA4D56"))
            .composited(over: card, opacity: 0.1)

        let adjusted = AccessibleColorAdjustment.adjusted(
            source,
            against: [card, statusTint],
            minimumContrast: 4.5
        )

        #expect(adjusted.contrastRatio(against: card) >= 4.5)
        #expect(adjusted.contrastRatio(against: statusTint) >= 4.5)
    }

    @Test func increasedContrastTargetReachesSevenToOne() throws {
        let source = try #require(SRGBColor(hex: "#00785F"))
        let background = try #require(SRGBColor(hex: "#1E1E1E"))

        let adjusted = AccessibleColorAdjustment.adjusted(
            source,
            against: [background],
            minimumContrast: 7
        )

        #expect(adjusted.contrastRatio(against: background) >= 7)
    }
}
