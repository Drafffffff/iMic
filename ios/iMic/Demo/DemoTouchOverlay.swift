#if DEBUG
import UIKit

/// DEBUG-only touch indicator for demo recordings: a soft dot with a short trail drawn
/// above the window. It observes touches through a recognizer that never recognizes and
/// never cancels or delays them, so every real gesture behaves exactly as in the app.
enum DemoTouchOverlay {
    private static var installed = false

    @MainActor
    static func installIfNeeded() {
        guard DemoScript.shared.active, !installed else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { installIfNeeded() }
            return
        }
        installed = true
        let observer = TouchObserver(window: window)
        window.addGestureRecognizer(observer)
        installTimecode(on: window)
    }
}

extension DemoTouchOverlay {
    /// 12-bit event counter as 2×6 cells of 3pt in the top-left corner. The composer masks
    /// the phone's rounded corners, so these pixels never appear in a finished video.
    @MainActor
    static func installTimecode(on window: UIWindow) {
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: 20, height: 8)
        host.backgroundColor = UIColor.black.cgColor
        host.zPosition = 30_000
        var cells: [CALayer] = []
        for bit in 0..<12 {
            let cell = CALayer()
            cell.frame = CGRect(x: 1 + CGFloat(bit % 6) * 3, y: 1 + CGFloat(bit / 6) * 3, width: 3, height: 3)
            cell.backgroundColor = UIColor.black.cgColor
            host.addSublayer(cell)
            cells.append(cell)
        }
        window.layer.addSublayer(host)
        DemoScript.shared.onCount = { count in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (bit, cell) in cells.enumerated() {
                cell.backgroundColor = (count >> bit) & 1 == 1 ? UIColor.white.cgColor : UIColor.black.cgColor
            }
            CATransaction.commit()
        }
    }
}

private final class TouchObserver: UIGestureRecognizer {
    private weak var host: UIWindow?
    private let layer = CALayer()
    private var dots: [ObjectIdentifier: CAShapeLayer] = [:]
    private var trails: [ObjectIdentifier: (layer: CAShapeLayer, points: [CGPoint])] = [:]

    init(window: UIWindow) {
        host = window
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        layer.zPosition = 10_000
        layer.frame = window.bounds
        window.layer.addSublayer(layer)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { begin(touch) }
        DemoScript.shared.record("touch.down", [:])
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { move(touch) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { end(touch) }
        DemoScript.shared.record("touch.up", [:])
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { end(touch) }
        state = .failed
    }
    override func reset() { /* keep layers; individual touches clean themselves up */ }

    private func begin(_ touch: UITouch) {
        guard let host else { return }
        layer.frame = host.bounds
        let id = ObjectIdentifier(touch)
        let point = touch.location(in: host)
        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: CGRect(x: -22, y: -22, width: 44, height: 44)).cgPath
        dot.fillColor = UIColor(white: 1, alpha: 0.22).cgColor
        dot.strokeColor = UIColor(white: 1, alpha: 0.75).cgColor
        dot.lineWidth = 2
        dot.position = point
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.addSublayer(dot)
        CATransaction.commit()
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.5; pop.toValue = 1; pop.duration = 0.12
        dot.add(pop, forKey: "down")
        dots[id] = dot
        let trail = CAShapeLayer()
        trail.fillColor = nil
        trail.strokeColor = UIColor(white: 1, alpha: 0.28).cgColor
        trail.lineWidth = 10
        trail.lineCap = .round
        trail.lineJoin = .round
        layer.insertSublayer(trail, below: dot)
        trails[id] = (trail, [point])
    }

    private func move(_ touch: UITouch) {
        guard let host else { return }
        let id = ObjectIdentifier(touch)
        let point = touch.location(in: host)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dots[id]?.position = point
        if var entry = trails[id] {
            entry.points.append(point)
            entry.points = Array(entry.points.suffix(14))
            let path = UIBezierPath()
            path.move(to: entry.points[0])
            for p in entry.points.dropFirst() { path.addLine(to: p) }
            entry.layer.path = path.cgPath
            trails[id] = entry
        }
        CATransaction.commit()
    }

    private func end(_ touch: UITouch) {
        let id = ObjectIdentifier(touch)
        for node in [dots.removeValue(forKey: id), trails.removeValue(forKey: id)?.layer].compactMap({ $0 }) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = node.opacity; fade.toValue = 0; fade.duration = 0.18
            node.opacity = 0
            node.add(fade, forKey: "up")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { node.removeFromSuperlayer() }
        }
    }
}
#endif
