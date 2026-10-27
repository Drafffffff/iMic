import SwiftUI
import UIKit

/// Lives at the application root; the window recognizer also observes sheets/navigation.
struct IdleScreenObserver: UIViewRepresentable {
    var busy: Bool
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> IdleScreenProbe { IdleScreenProbe() }

    func updateUIView(_ view: IdleScreenProbe, context: Context) {
        view.busy = busy
        view.active = scenePhase == .active
        view.configure()
    }

    static func dismantleUIView(_ view: IdleScreenProbe, coordinator: ()) { view.detach() }
}

final class IdleScreenProbe: UIView {
    var busy = false
    var active = false
    private weak var observedWindow: UIWindow?
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

    func configure() {
        if observedWindow !== window {
            detach()
            if let window, let screen = window.windowScene?.screen {
                observedWindow = window
                let controller = IdleScreenDimming(
                    read: { Double(screen.brightness) },
                    write: { screen.brightness = CGFloat($0) },
                    onState: {
                        IMicLog.write("iphone.power", String(format: "screen idle %@ brightness=%.3f", $0.rawValue, Double(screen.brightness)))
                    })
                dimming = controller
                let activity = IdleActivityRecognizer()
                activity.onTouching = { [weak controller] in controller?.setTouching($0) }
                observer = activity
                window.addGestureRecognizer(activity)
                let center = NotificationCenter.default
                tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                    object: nil, queue: .main) { [weak controller] _ in
                        MainActor.assumeIsolated { controller?.setActive(false) }
                    })
                tokens.append(center.addObserver(forName: UIScreen.brightnessDidChangeNotification,
                    object: screen, queue: .main) { [weak controller] _ in
                        MainActor.assumeIsolated { controller?.brightnessChanged() }
                    })
                for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
                    tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak controller] _ in
                        MainActor.assumeIsolated { controller?.noteActivity() }
                    })
                }
            }
        }
        dimming?.setBusy(busy)
        dimming?.setActive(active && UIApplication.shared.applicationState == .active)
    }

    func detach() {
        dimming?.setActive(false)
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
