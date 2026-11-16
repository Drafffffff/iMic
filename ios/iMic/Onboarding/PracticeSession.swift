import Foundation
import SwiftUI

/// Local data source for the real HomeView. Owns no audio, transport or gesture physics.
@MainActor
final class PracticeSession {
    struct Snapshot {
        var phase: SessionModel.Phase = .idle
        var elapsed: TimeInterval = 0
        var text = ""
        var live = ""
        var cursor = 0
    }
    private(set) var state = Snapshot()
    var changed: ((Snapshot) -> Void)?
    var performed: ((String) -> Void)?
    private var playback: Task<Void, Never>?
    private var began: Date?
    private var heldEnough = false
    var cancelGestureArmed = false
    var measuredHoldDuration: TimeInterval = 0
    private var generation = 0
    private var phrase: String { L10n.text("Meeting tomorrow at three") }

    func reset(seed: Bool = false) {
        generation += 1
        playback?.cancel(); playback = nil; began = nil; heldEnough = false
        state = Snapshot()
        cancelGestureArmed = false
        measuredHoldDuration = 0
        if seed { state.text = phrase; state.live = phrase; state.cursor = phrase.count; state.phase = .result }
        changed?(state)
    }
    func begin(spectrum: SpectrumStore) {
        reset()
        began = Date()
        state.phase = .listening
        changed?(state)
        Haptics.shared.play(.press)
        Haptics.shared.play(.recordingStarted)
        let words = Array(phrase)
        playback = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let began = self.began else { return }
                self.state.elapsed = Date().timeIntervalSince(began)
                let count = min(words.count, Int(self.state.elapsed / 0.09))
                self.state.live = String(words.prefix(count))
                self.changed?(self.state)
                let t = self.state.elapsed
                spectrum.set((0..<44).map { i in
                    CGFloat(0.08 + 0.65 * abs(sin(t * 5 + Double(i) * 0.21)) * abs(cos(t * 2 + Double(i) * 0.07)))
                }, level: CGFloat(0.3 + 0.4 * abs(sin(t * 4))))
                if t >= 0.5, !self.heldEnough {
                    self.heldEnough = true
                    self.performed?("hold")
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }
    func end(cancelled: Bool, spectrum: SpectrumStore) {
        guard state.phase == .listening else { return }
        let duration = max(measuredHoldDuration, began.map { Date().timeIntervalSince($0) } ?? 0)
        if duration >= 0.5, !cancelled, !heldEnough {
            heldEnough = true
            performed?("hold")
        }
        playback?.cancel(); began = nil
        spectrum.set([], level: 0)
        if cancelled || duration < 0.5 {
            let gesture = cancelGestureArmed
            reset()
            Haptics.shared.play(cancelled ? .cancelled : .tooShort)
            performed?(cancelled ? (gesture ? "cancel" : "interrupt") : "short")
            return
        }
        Haptics.shared.play(.release)
        state.phase = .transcribing
        changed?(state)
        let stamp = generation
        playback = Task { [weak self] in
            guard let self else { return }
            // Any remaining glyphs enter the same receiver stream, one at a time.
            let words = Array(self.phrase)
            var count = self.state.live.count
            while count < words.count {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, self.generation == stamp else { return }
                count += 1; self.state.live = String(words.prefix(count)); self.changed?(self.state)
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self.generation == stamp else { return }
            self.state.text = self.phrase; self.state.cursor = self.state.text.count
            self.state.phase = .result; self.changed?(self.state)
            Haptics.shared.play(.result)
            self.performed?("release")
        }
    }
    @discardableResult
    func input(_ action: String) -> Bool {
        guard state.phase != .listening, state.phase != .transcribing else { return false }
        switch action {
        case "return": break // The real receiver fires; the result stays available, as in normal use.
        case "delete":
            if state.cursor > 0 {
                state.text.remove(at: state.text.index(state.text.startIndex, offsetBy: state.cursor - 1))
                state.cursor -= 1
            }
        case "left", "right": state.cursor = min(state.text.count, max(0, state.cursor + (action == "left" ? -1 : 1)))
        case "clear": state.text = ""; state.cursor = 0; state.phase = .idle
        default: return false
        }
        state.live = state.text
        changed?(state)
        IMicLog.write("iphone.practice", "input=\(action) cursor=\(state.cursor) text=\(state.text.count)")
        performed?(action)
        return true
    }
    var cursorText: String {
        var text = state.text
        text.insert("│", at: text.index(text.startIndex, offsetBy: min(state.cursor, text.count)))
        return text
    }
}
