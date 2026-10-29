import SwiftUI

/// A local command sink. No AudioCapture, SpeechPreview or transport is owned here.
@MainActor
final class PracticeSession: ObservableObject {
    let spectrum = SpectrumStore()
    @Published var card = 0
    @Published var completed = false
    @Published var passed = false
    @Published var deleted = false
    @Published var moved = false
    @Published var holding = false
    @Published var cancelArmed = false
    @Published var text = ""
    @Published var cursor = 0
    private var beganAt: Date?
    private var horizontal: Bool?
    private var cursorStep = 0
    private var cleared = false
    let phrase = "今天下午三点开会"
    var motion: StringMotionStore { spectrum.stringMotion }
    static let titles = ["HOLD", "CANCEL", "RETURN", "EDIT", "CLEAR"]
    static let instructions = ["按住下方横条，至少说半秒，松手发送", "按住横条向上滑，松手取消，不会发送", "向下拉弦再松手，弹射时发送回车", "向上拉弦删除；左右滑动移动光标", "把弦一直拉到屏幕顶部，清空当前输入"]

    init() {
        motion.onFireReturn = { [weak self] in self?.apply("return") ?? false }
        motion.onRepeatDelete = { [weak self] in
            let applied = self?.apply("delete") ?? false
            if applied { SoundDesign.shared.play(.delete) }
            return applied
        }
    }
    func configure(reducedMotion: Bool) {
        motion.reduceMotion = reducedMotion
        spectrum.configureAmbientMotion(enabled: true, reducedMotion: reducedMotion)
        spectrum.setVisible(true)
    }
    func prepareCard() {
        motion.cancel()
        passed = false; deleted = false; moved = false; horizontal = nil; cursorStep = 0; cleared = false
        text = card >= 2 ? phrase : ""
        cursor = text.count
    }
    func beginHold() {
        holding = true; beganAt = Date()
        Haptics.shared.play(.press)
        Haptics.shared.play(.recordingStarted)
    }
    func moveHold(_ dy: CGFloat) {
        let armed = dy < -64
        if armed != cancelArmed {
            cancelArmed = armed
            Haptics.shared.play(armed ? .cancelArmed : .cancelDisarmed)
        }
    }
    func endHold(cancelled: Bool) {
        guard holding else { return }
        let wasArmed = cancelArmed
        holding = false; cancelArmed = false
        let duration = beganAt.map { Date().timeIntervalSince($0) } ?? 0
        if cancelled {
            Haptics.shared.play(.cancelled)
            if card == 1, wasArmed { succeed() }
        } else if duration >= 0.6 {
            Haptics.shared.play(.release)
            text = phrase; cursor = text.count
            if card == 0 { succeed() }
        } else { Haptics.shared.play(.tooShort) }
    }
    @discardableResult
    func apply(_ action: String) -> Bool {
        switch action {
        case "return": text += " ↵"; cursor = text.count; if card == 2 { succeed() }
        case "delete":
            if cursor > 0, cursor <= text.count {
                text.remove(at: text.index(text.startIndex, offsetBy: cursor - 1)); cursor -= 1
            }
            deleted = true
        case "left", "right": cursor = min(text.count, max(0, cursor + (action == "left" ? -1 : 1))); moved = true
        case "clear": text = ""; cursor = 0; if card == 4 { succeed() }
        default: return false
        }
        if card == 3, deleted, moved { succeed() }
        return true
    }
    func succeed() {
        guard !passed else { return }
        passed = true
        Haptics.shared.play(.selection)
    }
    func next() {
        if card == 4 { completed = true; motion.cancel() }
        else { card += 1; prepareCard() }
    }
    func drag(_ value: DragGesture.Value, frame: CGRect, returnEnabled: Bool, deleteEnabled: Bool, cursorEnabled: Bool) {
        guard !cleared, !motion.isClearing else { return }
        if horizontal == nil {
            motion.cancelPendingReturn()
            horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.35
            if horizontal == false {
                motion.begin(anchor: TorusGeometry.touchAnchor(x: value.startLocation.x, width: frame.width), height: frame.height,
                    clearStretch: deleteEnabled ? StringClearStretch(distance: frame.minY + value.startLocation.y - 84, depth: frame.midY - 84) : nil)
            }
        }
        if horizontal == true {
            let step = Int(value.translation.width / 30)
            if step != cursorStep, cursorEnabled {
                let delta = step - cursorStep
                for _ in 0..<min(4, abs(delta)) { apply(delta > 0 ? "right" : "left") }
                Haptics.shared.play(.selection)
            }
            cursorStep = step
        } else {
            motion.moveAnchor(to: TorusGeometry.touchAnchor(x: value.location.x, width: frame.width))
            if deleteEnabled, value.translation.height < -80, frame.minY + value.location.y <= 84 {
                cleared = true; motion.completeClearContact(); apply("clear"); Haptics.shared.play(.cancelArmed)
            } else {
                motion.drag(translation: value.translation.height, velocity: value.velocity.height,
                            returnEnabled: returnEnabled, deleteEnabled: deleteEnabled)
            }
        }
    }
    func endDrag(_ value: DragGesture.Value, returnEnabled: Bool, deleteEnabled: Bool) {
        if horizontal == false, !cleared {
            if let action = motion.finish(translation: value.translation.height, velocity: value.velocity.height,
                                           returnEnabled: returnEnabled, deleteEnabled: deleteEnabled) {
                apply(action); Haptics.shared.play(.deleteChar)
            }
        }
        horizontal = nil; cursorStep = 0; cleared = false
    }
}

struct PracticeView: View {
    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var practice = PracticeSession()
    var preview: String? = nil
    var onInteractionChanged: (Bool) -> Void = { _ in }
    var onComplete: () -> Void
    private var disabled: Bool {
        switch practice.card {
        case 2: return !session.snapReturnEnabled
        case 3: return !session.pullDeleteEnabled || !session.swipeCursorEnabled
        case 4: return !session.pullDeleteEnabled
        default: return false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if practice.completed {
                GuideTitle(text: "PRACTICE COMPLETE", cell: 1.7, color: Theme.orange)
                    .accessibilityLabel("练习完成")
                Text("✓ 你已经了解核心手势。练习没有录音，也没有向 Mac 发送内容。")
                GuideButton(title: "完成练习", action: onComplete)
            } else {
                HStack {
                    GuideTitle(text: PracticeSession.titles[practice.card], cell: 3, color: Theme.ivory)
                    Spacer()
                    Text("\(practice.card + 1) / 5").foregroundStyle(Theme.muted)
                }
                Text(PracticeSession.instructions[practice.card])
                if disabled { Text("部分手势已在设置中关闭，可以直接跳过。恢复开关需在 Mac 设置中操作。") .foregroundStyle(Theme.muted) }
                GestureDemonstration(card: practice.card)
                VStack(alignment: .leading, spacing: 8) {
                    MetaLabel(text: "MAC / PRACTICE ONLY")
                    Text(practice.text.isEmpty ? "等待你的操作…" : practice.text)
                        .foregroundStyle(practice.text.isEmpty ? Theme.muted : Theme.ivory)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .accessibilityIdentifier("practice.text")
                    Text("光标位置 \(practice.cursor)").font(.caption).foregroundStyle(Theme.muted)
                }.padding(14).background(Theme.panel).overlay(Rectangle().stroke(Theme.line))
                if practice.card == 3 {
                    Text("\(practice.deleted ? "✓" : "○") 删除    \(practice.moved ? "✓" : "○") 移动光标")
                        .foregroundStyle(Theme.orange).accessibilityIdentifier("practice.edit-checks")
                }
                GeometryReader { geometry in
                    ZStack {
                        TorusView(store: practice.spectrum, instrumentHUD: true, channelLabel: "PRACTICE")
                            .allowsHitTesting(false)
                        Color.clear.contentShape(Rectangle())
                            .highPriorityGesture(DragGesture(minimumDistance: 6)
                                .onChanged { onInteractionChanged(true); practice.drag($0, frame: geometry.frame(in: .global), returnEnabled: session.snapReturnEnabled,
                                                          deleteEnabled: session.pullDeleteEnabled, cursorEnabled: session.swipeCursorEnabled) }
                                .onEnded { practice.endDrag($0, returnEnabled: session.snapReturnEnabled, deleteEnabled: session.pullDeleteEnabled); onInteractionChanged(false) })
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("练习弦控制")
                    .accessibilityIdentifier("practice.string")
                }.frame(height: 170)
                ZStack {
                    RecordingBarShape().fill(practice.holding ? Theme.orange : Theme.panelRaised)
                    PixelText(text: practice.cancelArmed ? "CANCEL" : "HOLD TO SPEAK", cell: 1.8,
                              color: practice.holding ? Theme.ink : Theme.ivory)
                    HoldControl(onBegan: { onInteractionChanged(true); practice.beginHold() }, onMoved: practice.moveHold,
                                onEnded: { practice.endHold(cancelled: $0); onInteractionChanged(false) })
                }
                .frame(height: HoldBarLayout.height)
                .accessibilityElement(children: .ignore).accessibilityLabel("练习录音横条")
                .accessibilityIdentifier("practice.hold")
                if practice.passed {
                    Text("✓ 已完成").foregroundStyle(Theme.orange).accessibilityIdentifier("practice.passed")
                    GuideButton(title: "下一张") { practice.next() }
                }
                if voiceOver {
                    Button("标记为已了解") { practice.succeed() }
                }
                Button("跳过") { practice.next() }.frame(minHeight: 44)
            }
        }
        .font(.body).foregroundStyle(Theme.ivory)
        .onAppear {
            link.setPracticeActive(true)
            if let preview {
                if preview == "practice-complete" { practice.completed = true }
                else if let number = Int(preview.suffix(1)), (1...5).contains(number) { practice.card = number - 1 }
            }
            practice.prepareCard(); practice.configure(reducedMotion: reduceMotion)
        }
        .onChange(of: practice.completed) { _, complete in
            if complete { UserDefaults.standard.set(1, forKey: OnboardingCoordinator.tutorialKey) }
        }
        .onDisappear { onInteractionChanged(false); practice.motion.cancel(); practice.spectrum.setVisible(false); link.setPracticeActive(false) }
        .onChange(of: reduceMotion) { _, value in practice.configure(reducedMotion: value) }
        .onChange(of: scenePhase) { _, value in
            if value != .active { onInteractionChanged(false); practice.endHold(cancelled: true); practice.motion.cancel() }
            practice.spectrum.setVisible(value == .active)
        }
        .task(id: practice.holding && !reduceMotion) {
            while !Task.isCancelled, practice.holding, !reduceMotion {
                let t = Date().timeIntervalSinceReferenceDate
                practice.spectrum.set((0..<44).map { CGFloat(0.2 + 0.5 * abs(sin(t * 2 + Double($0) * 0.2))) }, level: 0.6)
                try? await Task.sleep(for: .milliseconds(40))
            }
            practice.spectrum.set([], level: 0)
        }
    }
}

struct GestureDemonstration: View {
    let card: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { timeline in
            let progress = reduceMotion ? 0.65 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            let travel = CGFloat(sin(progress * .pi))
            HStack(spacing: 16) {
                Text(card == 0 ? "↓  ·  ↑" : (card == 2 ? "↓  ↵" : (card == 3 ? "↑  ← →" : "↑")))
                    .font(.system(.title2, design: .monospaced))
                Canvas { context, _ in
                    let rows = ["00110000", "00110000", "00110000", "00111110", "11111111", "11111111", "01111110", "01111110", "00111100"]
                    for (y, row) in rows.enumerated() {
                        for (x, cell) in row.enumerated() where cell == "1" {
                            context.fill(Path(CGRect(x: x * 3, y: y * 3, width: 3, height: 3)), with: .color(Theme.orange))
                        }
                    }
                }.frame(width: 24, height: 27)
                    .offset(x: card == 3 ? travel * 24 : 0, y: (card == 2 ? 1 : -1) * travel * 14)
                Spacer()
                MetaLabel(text: "TRY IT BELOW")
            }
        }
        .foregroundStyle(Theme.orange).frame(height: 42)
        .accessibilityElement(children: .ignore).accessibilityLabel(PracticeSession.instructions[card])
    }
}
