import Foundation

/// App-local sleep shade. Owns only its opacity, never the system's brightness.
/// One sleeping deadline plus finite fades; no callbacks while fully asleep.
@MainActor
final class IdleScreenDimming {
    enum State: String { case inactive, armed, blocked, dimming, dimmed, restoring }

    private let write: (Double) -> Void
    private let now: () -> Double
    private let idleDelay: Double
    private let fadeDuration: Double
    private let restoreDuration: Double
    private let onState: (State) -> Void
    private var deadline: Task<Void, Never>?
    private var fade: Task<Void, Never>?
    private var active = false
    private var busy = false
    private var touching = false
    private var lastActivity: Double = 0
    private(set) var opacity: Double = 0
    private(set) var state: State = .inactive

    init(idleDelay: Double = 60, fadeDuration: Double = 2, restoreDuration: Double = 0.16,
         write: @escaping (Double) -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         onState: @escaping (State) -> Void = { _ in }) {
        self.idleDelay = idleDelay
        self.fadeDuration = fadeDuration
        self.restoreDuration = restoreDuration
        self.write = write
        self.now = now
        self.onState = onState
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value {
            noteActivity()
        } else {
            deadline?.cancel(); deadline = nil
            touching = false
            restore(animated: false)
            transition(.inactive)
        }
    }

    func setBusy(_ value: Bool) {
        guard busy != value else { return }
        busy = value
        noteActivity()
    }

    func setTouching(_ value: Bool) {
        touching = value
        // Finish waking before UIKit forwards this same touch to its control.
        if value { restore(animated: false) }
        noteActivity()
    }

    func noteActivity() {
        lastActivity = now()
        guard active else { return }
        restore(animated: true)
        if busy || touching {
            deadline?.cancel(); deadline = nil
            if opacity == 0 { transition(.blocked) }
        } else {
            arm()
        }
    }

    private func transition(_ next: State) {
        guard state != next else { return }
        state = next
        onState(next)
    }

    private func arm() {
        guard active, !busy, !touching, deadline == nil else { return }
        if opacity == 0 { transition(.armed) }
        deadline = Task { [weak self] in
            while let self, !Task.isCancelled {
                let remaining = self.idleDelay - (self.now() - self.lastActivity)
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                } else {
                    self.deadline = nil
                    guard self.active, !self.busy, !self.touching else { return }
                    self.transition(.dimming)
                    self.animate(to: 0.75, duration: self.fadeDuration, restoring: false)
                    return
                }
            }
        }
    }

    private func restore(animated: Bool) {
        // Move/end events must not keep restarting the short wake-up transition.
        if animated, state == .restoring { return }
        fade?.cancel(); fade = nil
        guard opacity > 0 else { return }
        if animated {
            transition(.restoring)
            animate(to: 0, duration: restoreDuration, restoring: true)
        } else {
            opacity = 0
            write(0)
        }
    }

    private func animate(to target: Double, duration: Double, restoring: Bool) {
        fade?.cancel()
        let start = opacity, began = now()
        fade = Task { [weak self] in
            while let self, !Task.isCancelled {
                let t = min(1, max(0, (self.now() - began) / max(0.001, duration)))
                let eased = t * t * (3 - 2 * t)
                self.opacity = start + (target - start) * eased
                self.write(self.opacity)
                if t >= 1 {
                    self.fade = nil
                    self.transition(restoring
                        ? (self.active ? (self.busy || self.touching ? .blocked : .armed) : .inactive)
                        : .dimmed)
                    return
                }
                do { try await Task.sleep(for: .seconds(1.0 / 30)) } catch { return }
            }
        }
    }
}
