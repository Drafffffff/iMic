import SwiftUI
import UIKit

/// Lives at the application root; the window recognizer also observes sheets/navigation.
struct IdleScreenObserver: UIViewRepresentable {
    var busy: Bool
    var onActivity: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> IdleScreenProbe { IdleScreenProbe() }

    func updateUIView(_ view: IdleScreenProbe, context: Context) {
        view.busy = busy
        view.active = scenePhase == .active
        view.onActivity = onActivity
        view.configure()
    }

    static func dismantleUIView(_ view: IdleScreenProbe, coordinator: ()) { view.detach() }
}

final class IdleScreenProbe: UIView {
    var busy = false
    var active = false
    var onActivity: (() -> Void)?
    private weak var observedWindow: UIWindow?
    private var shade: CALayer?
    private var dimming: IdleScreenDimming?
    private var observer: IdleActivityRecognizer?
    private var tokens: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateShadeFrame()
    }

    private func updateShadeFrame() {
        guard let shade, let window = observedWindow, shade.frame != window.bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = window.bounds
        CATransaction.commit()
    }

    func configure() {
        if observedWindow !== window {
            detach()
            if let window {
                observedWindow = window
                // A drawing layer cannot join hit testing or change UIKit's touch routing.
                let shade = CALayer()
                shade.frame = window.bounds
                shade.backgroundColor = UIColor.black.cgColor
                shade.opacity = 0
                shade.zPosition = 1_000
                window.layer.addSublayer(shade)
                self.shade = shade
                let controller = IdleScreenDimming(
                    write: { [weak shade] opacity in
                        guard let shade else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        shade.opacity = Float(opacity)
                        CATransaction.commit()
                    },
                    onState: { [weak shade] state in
                        IMicLog.write("iphone.power", String(format: "screen idle %@ shade=%.3f", state.rawValue, Double(shade?.opacity ?? 0)))
                    })
                dimming = controller
                let activity = IdleActivityRecognizer()
                activity.onTouching = { [weak controller, weak self] touching in
                    controller?.setTouching(touching)
                    if touching { self?.onActivity?() }
                }
                observer = activity
                window.addGestureRecognizer(activity)
                let center = NotificationCenter.default
                tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                    object: nil, queue: .main) { [weak controller] _ in
                        MainActor.assumeIsolated { controller?.setActive(false) }
                    })
                for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
                    tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak controller, weak self] _ in
                        MainActor.assumeIsolated {
                            controller?.noteActivity()
                            self?.onActivity?()
                        }
                    })
                }
            }
        }
        updateShadeFrame()
        dimming?.setBusy(busy)
        dimming?.setActive(active && UIApplication.shared.applicationState == .active)
    }

    func detach() {
        dimming?.setActive(false)
        shade?.removeFromSuperlayer()
        shade = nil
        if let observer { observedWindow?.removeGestureRecognizer(observer) }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        observer = nil
        observedWindow = nil
        dimming = nil
    }
}

/// Always observes, never recognizes/steals/cancels a button or drag gesture.
private final class IdleActivityRecognizer: UIGestureRecognizer {
    var onTouching: ((Bool) -> Void)?
    private var contacts = Set<UITouch>()

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.formUnion(touches)
        onTouching?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { onTouching?(true) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        contacts.subtract(touches)
        onTouching?(!contacts.isEmpty)
        if contacts.isEmpty { state = .failed }
    }

    override func reset() {
        let hadContacts = !contacts.isEmpty
        super.reset()
        contacts.removeAll()
        if hadContacts { onTouching?(false) }
    }
}
