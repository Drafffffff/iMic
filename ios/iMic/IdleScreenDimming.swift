import Foundation

/// A single sleeping deadline plus finite fades. No polling/display link while dimmed.
/// Brightness access is injected so ownership, cancellation and restoration can be tested.
@MainActor
final class IdleScreenDimming {
    enum State: String { case inactive, armed, blocked, dimming, dimmed, restoring }

    private let read: () -> Double
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
    private var original: Double?
    private var lastWritten: Double?
    private(set) var state: State = .inactive

    init(idleDelay: Double = 60, fadeDuration: Double = 2, restoreDuration: Double = 0.16,
         read: @escaping () -> Double, write: @escaping (Double) -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         onState: @escaping (State) -> Void = { _ in }) {
        self.idleDelay = idleDelay
        self.fadeDuration = fadeDuration
        self.restoreDuration = restoreDuration
        self.read = read
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
        noteActivity()
    }

    func noteActivity() {
        lastActivity = now()
        guard active else { return }
        restore(animated: true)
        if busy || touching {
            deadline?.cancel(); deadline = nil
            if original == nil { transition(.blocked) }
        } else {
            arm()
        }
    }

    /// Treat a manual brightness change as a new preference, never overwrite it.
    func brightnessChanged() {
        guard original != nil, let lastWritten, Self.takenOver(read(), written: lastWritten) else { return }
        fade?.cancel(); fade = nil
        original = nil
        self.lastWritten = nil
        noteActivity()
    }

    /// Auto-brightness keeps nudging the panel while it is dimmed (0.091 read back as 0.096
    /// on device). Mistaking that drift for a manual change dropped the saved brightness, so
    /// the screen stayed dark and the next round dimmed from the dark value. A real manual
    /// change goes through Control Center, which deactivates the app and restores first, so
    /// only a large departure from the written value counts as the user taking over.
    nonisolated static func takenOver(_ current: Double, written: Double) -> Bool {
        abs(current - written) > max(0.08, written * 0.5)
    }

    private func transition(_ next: State) {
        guard state != next else { return }
        state = next
        onState(next)
    }

    private func arm() {
        guard active, !busy, !touching, deadline == nil else { return }
        if original == nil { transition(.armed) }
        deadline = Task { [weak self] in
            while let self, !Task.isCancelled {
                let remaining = self.idleDelay - (self.now() - self.lastActivity)
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                } else {
                    self.deadline = nil
                    guard self.active, !self.busy, !self.touching else { return }
                    self.dim()
                    return
                }
            }
        }
    }

    private func dim() {
        fade?.cancel()
        let baseline = min(1, max(0, read()))
        // Never brighten an already very dark display in the name of saving power.
        let target = min(baseline, max(0.02, baseline * 0.25))
        guard baseline - target > 0.001 else { transition(.dimmed); return }
        original = baseline
        lastWritten = baseline
        transition(.dimming)
        animate(to: target, duration: fadeDuration, restoring: false)
    }

    private func restore(animated: Bool) {
        guard let original else { return }
        // Repeated move/end events must not keep restarting the short restoration.
        if animated, state == .restoring { return }
        fade?.cancel(); fade = nil
        guard let lastWritten, !Self.takenOver(read(), written: lastWritten) else {
            self.original = nil; self.lastWritten = nil
            return
        }
        if animated {
            transition(.restoring)
            animate(to: original, duration: restoreDuration, restoring: true)
        } else {
            self.lastWritten = original
            write(original)
            self.original = nil; self.lastWritten = nil
        }
    }

    private func animate(to target: Double, duration: Double, restoring: Bool) {
        let start = read(), began = now()
        fade = Task { [weak self] in
            while let self, !Task.isCancelled {
                let t = min(1, max(0, (self.now() - began) / max(0.001, duration)))
                let eased = t * t * (3 - 2 * t)
                let value = start + (target - start) * eased
                self.lastWritten = value
                self.write(value)
                if t >= 1 {
                    self.fade = nil
                    if restoring {
                        self.original = nil; self.lastWritten = nil
                        self.transition(self.active ? (self.busy || self.touching ? .blocked : .armed) : .inactive)
                    } else { self.transition(.dimmed) }
                    return
                }
                do { try await Task.sleep(for: .seconds(1.0 / 30)) } catch { return }
            }
        }
    }
}
