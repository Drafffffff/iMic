import SwiftUI

/// A small interactive strip at the screen top, lit by the actual upward extension.
struct ClearDropZone: View {
    @ObservedObject var motion: StringMotionStore
    let distance: CGFloat
    let enabled: Bool

    var body: some View {
        let progress = motion.clearPreview(distance: distance, enabled: enabled)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                PixelText(text: "CLEAR", cell: 1.5, color: Theme.orange, tracking: 1)
                Spacer()
                Text("拉入清空输入框").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.orange)
            .padding(.horizontal, 24)
            .padding(.top, 46)
            .padding(.bottom, 12)
            .frame(height: 84)
            .background(Theme.orange.opacity(0.04 + Double(progress) * 0.20))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.orange.opacity(progress)).frame(height: 1) }
            .opacity(progress > 0.06 ? 0.25 + Double(progress) * 0.75 : 0)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
