import SwiftUI

/// Applies only to SwiftUI-rendered surfaces, before UIKit/Metal overlays.
/// In particular, the glyph CAMetalLayer and the native status bar stay separate.
struct PhosphorSurface: ViewModifier {
    @AppStorage(PhosphorEffect.preferenceKey) private var material = PhosphorEffect.crt.rawValue
    var strength: Float = 0.7
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.colorEffect(
            ShaderLibrary.imicPhosphorCRT(.float(Float(displayScale)), .float(strength)),
            isEnabled: !reduceTransparency && material == PhosphorEffect.crt.rawValue
        )
    }
}

/// Two small halos around the unchanged pixel core; Chinese copy stays unfiltered.
struct PhosphorReadout: ViewModifier {
    @AppStorage(PhosphorEffect.preferenceKey) private var material = PhosphorEffect.crt.rawValue
    var color: Color = Theme.orange
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(reduceTransparency || material == "clean" ? 0 : 0.28), radius: 1.5)
            .shadow(color: color.opacity(reduceTransparency || material == "clean" ? 0 : 0.12), radius: 5)
            .modifier(PhosphorSurface(strength: 0.55))
    }
}
