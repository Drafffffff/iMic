import SwiftUI
import UIKit

/// 原生 touchDown/touchUp 控件。放在横条上方作为透明命中层，
/// 避免 SwiftUI DragGesture 的识别延迟，按下即回调。
struct HoldControl: UIViewRepresentable {
    var onBegan: () -> Void
    var onMoved: (CGFloat) -> Void
    var onEnded: (Bool) -> Void
    var onPositionChanged: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> Control {
        let view = Control()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = false
        view.isExclusiveTouch = true
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onPositionChanged = onPositionChanged
        return view
    }

    func updateUIView(_ view: Control, context: Context) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onPositionChanged = onPositionChanged
    }

    final class Control: UIView {
        var onBegan: (() -> Void)?
        var onMoved: ((CGFloat) -> Void)?
        var onEnded: ((Bool) -> Void)?
        var onPositionChanged: ((CGFloat) -> Void)?
        private var startPoint: CGPoint?
        private var translation: CGFloat = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard let touch = touches.first else { return }
            startPoint = touch.location(in: self)
            translation = 0
            updatePosition(touch)
            onBegan?()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let touch = touches.first, let startPoint = startPoint else { return }
            translation = touch.location(in: self).y - startPoint.y
            updatePosition(touch)
            onMoved?(translation)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            let cancelled = translation < -64
            if let touch = touches.first { updatePosition(touch) }
            startPoint = nil
            onEnded?(cancelled)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            startPoint = nil
            onEnded?(true)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.contains(point)
        }

        private func updatePosition(_ touch: UITouch) {
            guard bounds.width > 0 else { return }
            let fraction = (touch.location(in: self).x - bounds.minX) / bounds.width
            onPositionChanged?(min(1, max(0, fraction)))
        }
    }
}
