import AppKit
import SwiftUI

/// Better Voice brand accent — the purple from the marketing site (docs/styles.css).
///
/// Appearance-aware for WCAG AA on both light and dark: the site's bright purple
/// (#8b7cff) is only ~3.3:1 on white, so light mode uses the deep #5847d6 (--v-deep,
/// 6.4:1 on white); dark mode uses #8b7cff, which reads well on dark backgrounds and
/// muddies on light. White-on-#5847d6 = 6.4:1, so filled buttons stay legible.
extension Color {
    static let brandAccent = Color(nsColor: .brandAccent)
}

extension NSColor {
    static let brandAccent = NSColor(name: "BrandAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x8b / 255, green: 0x7c / 255, blue: 0xff / 255, alpha: 1)   // #8b7cff
            : NSColor(srgbRed: 0x58 / 255, green: 0x47 / 255, blue: 0xd6 / 255, alpha: 1)   // #5847d6
    }
}

/// The brand's 5-bar waveform (site height ratios 6/13/9/16/7) as a scalable SwiftUI
/// view — colored, for in-app use (e.g. the onboarding header). The monochrome menu-bar
/// glyph lives in `NSImage.menuBarWaveform()`.
struct BrandWaveform: View {
    var height: CGFloat = 34
    var color: Color = .brandAccent

    private static let ratios: [CGFloat] = [6, 13, 9, 16, 7]

    var body: some View {
        let maxRatio = Self.ratios.max() ?? 16
        let barWidth = height * 0.16
        HStack(alignment: .center, spacing: barWidth * 0.78) {
            ForEach(Array(Self.ratios.enumerated()), id: \.offset) { _, ratio in
                Capsule().fill(color)
                    .frame(width: barWidth, height: height * (ratio / maxRatio))
            }
        }
        .frame(height: height)
    }
}

extension NSImage {
    /// The brand's 5-bar waveform (site heights 6/13/9/16/7) as a monochrome **template**
    /// image, so the menu bar tints it for light/dark automatically. Not colored — a
    /// menu-bar glyph must adapt, so brand purple lives in the app icon, not here.
    static func menuBarWaveform() -> NSImage {
        let heights: [CGFloat] = [6, 13, 9, 16, 7]
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2.5
        let maxHeight = heights.max() ?? 16
        let width = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap

        let image = NSImage(size: NSSize(width: width, height: maxHeight), flipped: false) { _ in
            NSColor.black.setFill()   // template: only alpha matters, tint applied by AppKit
            for (i, h) in heights.enumerated() {
                let x = CGFloat(i) * (barWidth + gap)
                let bar = NSRect(x: x, y: 0, width: barWidth, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
