import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pressing = false
    @State private var cancelArmed = false
    @State private var showPairing = false
    @State private var interactionStart = false
    @State private var showCopied = false
    @State private var showResult = false
    @State private var connectionAnnounced = false
    @State private var stringAxis: StringAxis?
    @State private var stringHint: String?
    @State private var cursorStep = 0
    @GestureState private var stringTouchActive = false

    private enum StringAxis: Equatable { case vertical, horizontal }
    private let contentInset: CGFloat = 22

    private var linkReady: Bool { link.phase.isReady }
    private var canRecordNow: Bool {
        linkReady || (link.hasPairedMac && link.phase.allowsBufferedRecording)
    }

    private var stringMotion: StringMotionStore { session.spectrumStore.stringMotion }
    private var canUseString: Bool {
        linkReady && scenePhase == .active && !showPairing && !showResult
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TechBackground()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 14)
                    statusBlock(width: geometry.size.width - 44)
                    Spacer(minLength: 14)
                    GeometryReader { torus in
                        TorusView(
                            store: session.spectrumStore,
                            dimmed: session.phase == .idle && !canRecordNow
                        )
                        .contentShape(Rectangle())
                        .gesture(stringGesture(width: torus.size.width, height: torus.size.height))
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onChanged { _ in
                                // A fresh touch cancels a shot even before the
                                // directional gesture reaches its 6pt threshold.
                                stringMotion.cancelPendingReturn()
                            }
                        )
                    }
                    .frame(height: min(360, geometry.size.height * 0.40))

                    // 固定高度的不可见留白：即使出现结果或提示，主图与底栏也不移动。
                    Color.clear.frame(height: 38)

                    Spacer(minLength: 16)

                    holdBar(width: geometry.size.width - contentInset * 2)
                    footer
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, contentInset)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    if cancelArmed {
                        Text("松开取消")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ivory)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.panel)
                            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                            .padding(.bottom, 106)
                            .transition(.opacity)
                    } else if let notice = session.notice {
                        Text(notice)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.panel)
                            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                            .padding(.bottom, 106)
                            .transition(.opacity)
                    } else if let hint = stringHint {
                        Text(hint)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.panel)
                            .overlay(Rectangle().stroke(Theme.orange.opacity(0.7), lineWidth: 1))
                            .padding(.bottom, 106)
                            .transition(.opacity)
                    }
                }

                if showResult {
                    resultOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.22), value: showResult)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showPairing) {
            PairingSheet()
                .environmentObject(link)
                .environmentObject(session)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.prepareHaptics()
            link.start()
            session.activateAudio()
            stringMotion.reduceMotion = reduceMotion
            BowReleaseSound.shared.prepare()
            stringMotion.onFireReturn = { [weak session, weak link] in
                guard let session, let link, link.phase.isReady,
                      session.snapReturnEnabled, !showPairing, !showResult,
                      UIApplication.shared.applicationState == .active,
                      session.sendInput("return") else { return false }
                session.showGestureNotice("回车")
                return true
            }
            stringMotion.onRepeatDelete = { [weak session, weak link] in
                guard let session, let link, link.phase.isReady,
                      session.pullDeleteEnabled,
                      UIApplication.shared.applicationState == .active else { return false }
                session.sendInput("delete")
                return true
            }
            if case .needsCode = link.phase {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showPairing = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-preview=pairing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPairing = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-result") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showResult = true }
            }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--debug-buffer-tone") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    session.startDebugBufferTone()
                }
            } else if arguments.contains(where: { $0.hasPrefix("--debug-buffer-tts=") }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    session.startDebugBufferTest()
                }
            }
            #endif
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            stringMotion.cancel()
            stringMotion.onRepeatDelete = nil
            stringMotion.onFireReturn = nil
            session.deactivateAudio()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stringMotion.cancel() }
            if phase == .active {
                session.handleForeground()
            } else if phase == .background {
                session.handleBackground()
            }
        }
        .onChange(of: link.phase) { _, phase in
            if !phase.isReady { stringMotion.cancel() }
            switch phase {
            case .needsCode:
                connectionAnnounced = false
                Haptics.shared.play(.pairingRequired)
                showPairing = true
            case .ready:
                if !connectionAnnounced {
                    Haptics.shared.play(showPairing ? .pairingSuccess : .connected)
                    connectionAnnounced = true
                }
            case .searching, .failed:
                if connectionAnnounced {
                    Haptics.shared.play(.connectionLost)
                    connectionAnnounced = false
                }
            case .idle, .connecting:
                break
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .listening || phase == .idle {
                showResult = false
            }
        }
        .onChange(of: showPairing) { _, presented in
            if presented { stringMotion.cancel() }
        }
        .onChange(of: showResult) { _, presented in
            if presented { stringMotion.cancel() }
        }
        .onChange(of: session.pullDeleteEnabled) { _, enabled in
            if !enabled { stringMotion.cancel() }
        }
        .onChange(of: session.snapReturnEnabled) { _, enabled in
            if !enabled { stringMotion.cancel() }
        }
        .onChange(of: reduceMotion) { _, reduced in
            stringMotion.reduceMotion = reduced
        }
        .onReceive(stringMotion.$hint.removeDuplicates()) { hint in
            stringHint = hint
        }
        .onChange(of: stringTouchActive) { _, active in
            // SwiftUI can cancel a drag without delivering onEnded (sheet/background).
            if !active, stringAxis != nil {
                stringMotion.cancel()
                stringAxis = nil
                cursorStep = 0
                stringHint = nil
            }
        }
        .onChange(of: showCopied) { _, value in
            guard value else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                showCopied = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            PixelText(text: "IMIC", cell: 2.3, color: Theme.ivory, tracking: 1.4)
            Rectangle()
                .fill(Theme.orange)
                .frame(width: 3, height: 12)
            MetaLabel(text: "SYS 01", color: Theme.orange)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 5, height: 5)
                MetaLabel(text: connectionLabel, color: linkReady ? Theme.ivory : Theme.muted)
                    .lineLimit(1)
            }
            Button {
                Haptics.shared.play(.tap)
                showPairing = true
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("连接 Mac")
        }
        .frame(height: 30)
    }

    // MARK: - Status

    private func statusBlock(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                MetaLabel(text: "VOICE / LINK", color: Theme.muted)
                Spacer()
                MetaLabel(
                    text: linkReady ? "CH 01 · ENCRYPTED" : (canRecordNow ? "BUFFERING" : "NO CHANNEL"),
                    color: Theme.orange
                )
            }
            PixelText(
                text: statusWord,
                cell: statusCell(width: width),
                color: statusColor,
                tracking: 3
            )
            .frame(height: 7 * statusCell(width: width), alignment: .leading)
            Text(statusLine)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .frame(minHeight: 38, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Result

    /// 结果不再参与主布局，浮在当前界面之上。
    private var resultOverlay: some View {
        ZStack {
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture {
                    Haptics.shared.play(.overlayClose)
                    showResult = false
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    PixelText(text: "RESULT", cell: 2.1, color: Theme.orange, tracking: 1.6)
                    Spacer()
                    MetaLabel(
                        text: showCopied ? "COPIED" : (session.pasted ? "PASTED" : "ON PHONE"),
                        color: Theme.orange
                    )
                    Button {
                        Haptics.shared.play(.overlayClose)
                        showResult = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭结果")
                }

                Text(session.transcript)
                    .font(.system(size: 16, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ivory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack {
                    MetaLabel(text: (session.target ?? "MAC").uppercased())
                    Spacer()
                    Button {
                        session.copyTranscript()
                        showCopied = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text(showCopied ? "已复制" : "复制")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.ivory)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    }
                }
            }
            .padding(18)
            .background(Theme.panel)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.orange).frame(width: 3)
            }
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, contentInset)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Hold bar

    private func holdBar(width: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(barFill)
                .overlay(
                    Rectangle().stroke(
                        canRecordNow ? Color.clear : Theme.orange.opacity(0.8),
                        lineWidth: 1
                    )
                )
            HStack(spacing: 12) {
                PixelText(
                    text: barLabel,
                    cell: barCell(width: width),
                    color: barTextColor,
                    tracking: 2.2
                )
                Spacer(minLength: 6)
                if session.phase == .listening {
                    Text(String(format: "%.1f s", session.elapsed))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(barTextColor.opacity(0.8))
                } else {
                    Image(systemName: canRecordNow ? "mic.fill" : "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(barTextColor.opacity(0.9))
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(width: width, height: 70)
        .contentShape(Rectangle())
        .scaleEffect(pressing && session.phase == .listening ? 0.986 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.7), value: pressing)
        .overlay {
            HoldControl(
                onBegan: {
                    pressing = true
                    beginInteraction()
                },
                onMoved: { translation in
                    guard session.phase == .listening else { return }
                    let armed = translation < -64
                    if armed != cancelArmed {
                        cancelArmed = armed
                        Haptics.shared.play(armed ? .cancelArmed : .cancelDisarmed)
                    }
                },
                onEnded: { cancelled in
                    pressing = false
                    cancelArmed = false
                    interactionStart = false
                    if session.phase == .listening {
                        session.endListening(cancelled: cancelled)
                    }
                }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(barLabel)
        .accessibilityHint(statusLine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if session.phase == .listening {
                session.endListening(cancelled: false)
            } else {
                beginInteraction()
            }
        }
    }

    /// 中心弦：竖向拨弦（下=回车，上=删除），横向滑动移动光标。
    private func stringGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($stringTouchActive) { _, active, _ in active = true }
            .onChanged { value in
                guard canUseString else {
                    stringMotion.cancel()
                    return
                }
                if stringAxis == nil {
                    stringMotion.cancelPendingReturn()
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    stringAxis = dx > dy * 1.35 ? .horizontal : .vertical
                    if stringAxis == .vertical {
                        stringMotion.begin(anchor: value.startLocation.x / max(1, width), height: height)
                    }
                }
                switch stringAxis {
                case .vertical:
                    stringMotion.drag(
                        translation: value.translation.height,
                        velocity: value.velocity.height,
                        returnEnabled: session.snapReturnEnabled,
                        deleteEnabled: session.pullDeleteEnabled
                    )
                case .horizontal:
                    let step = Int(value.translation.width / 30)
                    if step != cursorStep {
                        let delta = step - cursorStep
                        let direction = delta > 0 ? "right" : "left"
                        if session.swipeCursorEnabled {
                            for _ in 0..<min(4, abs(delta)) {
                                session.sendInput(direction)
                            }
                            Haptics.shared.play(.selection)
                            stringHint = direction == "right" ? "光标 →" : "光标 ←"
                        } else {
                            stringHint = "光标已在 Mac 关闭"
                        }
                        cursorStep = step
                    }
                case .none:
                    break
                }
            }
            .onEnded { value in
                if stringAxis == .vertical {
                    let command = stringMotion.finish(
                        translation: value.translation.height,
                        velocity: value.velocity.height,
                        returnEnabled: canUseString && session.snapReturnEnabled,
                        deleteEnabled: canUseString && session.pullDeleteEnabled
                    )
                    if let command {
                        session.sendInput(command)
                        session.showGestureNotice("删除")
                        Haptics.shared.play(.warning)
                    }
                }
                stringHint = nil
                stringAxis = nil
                cursorStep = 0
            }
    }

    private func beginInteraction() {
        guard !interactionStart else { return }
        interactionStart = true
        if !canRecordNow {
            Haptics.shared.play(.pairingRequired)
            showPairing = true
            return
        }
        if session.micDenied {
            Haptics.shared.play(.warning)
            session.openMicrophoneSettings()
            return
        }
        if session.phase == .transcribing {
            return
        }
        if session.phase == .error || session.phase == .result {
            session.reset()
        }
        session.beginListening()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            MetaLabel(text: "AES-256 · BONJOUR")
            Spacer()
            ZStack(alignment: .trailing) {
                MetaLabel(text: "16 kHz · PCM")
                    .opacity(session.phase == .result && !session.transcript.isEmpty ? 0 : 1)
                Text("查看结果  ›")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Theme.orange)
                    .opacity(session.phase == .result && !session.transcript.isEmpty ? 1 : 0)
                    .allowsHitTesting(session.phase == .result && !session.transcript.isEmpty)
                    .onTapGesture {
                        Haptics.shared.play(.overlayOpen)
                        showResult = true
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("查看识别结果")
            }
            .frame(width: 98, alignment: .trailing)
        }
        .padding(.top, 12)
    }

    // MARK: - Derived copy

    private var connectionColor: Color {
        switch link.phase {
        case .ready: return Theme.orange
        case .connecting, .needsCode: return Theme.ivory
        case .searching, .idle, .failed: return Theme.muted
        }
    }

    private var connectionLabel: String {
        switch link.phase {
        case .ready(let name): return name.uppercased()
        case .connecting(let name): return "LINKING \(name)".uppercased()
        case .needsCode(let name): return "PAIR \(name)".uppercased()
        case .searching: return "SEARCHING"
        case .failed: return "OFFLINE"
        case .idle: return "STANDBY"
        }
    }

    private func statusCell(width: CGFloat) -> CGFloat {
        min(14, PixelFont.fittedCell(for: "SENDING", width: width, tracking: 3))
    }

    private var statusWord: String {
        switch session.phase {
        case .listening: return "LISTEN"
        case .transcribing: return "SENDING"
        case .result: return "DONE"
        case .error: return "ERROR"
        case .idle: break
        }
        if !canRecordNow {
            switch link.phase {
            case .needsCode: return "PAIR"
            case .connecting: return "LINK"
            case .failed: return "ERROR"
            default: return "NO LINK"
            }
        }
        return "READY"
    }

    private var statusColor: Color {
        if session.phase != .idle { return Theme.orange }
        return canRecordNow ? Theme.orange : Theme.muted
    }

    private var statusLine: String {
        switch session.phase {
        case .listening:
            if !linkReady { return "正在连接 Mac · 先说着，连上即发送" }
            return "松开即发送 · 上滑取消"
        case .transcribing:
            if !linkReady { return "正在连接 Mac，连接后立即发送" }
            return "正在把语音变成文字"
        case .result:
            if session.pasted, let target = session.target {
                return "已填入 \(target)"
            }
            return "文字已回传到 iPhone"
        case .error:
            return session.message ?? "请再试一次"
        case .idle:
            break
        }
        if !linkReady {
            if canRecordNow { return "按住先说着，连上即发送" }
            switch link.phase {
            case .searching: return link.macs.isEmpty ? "正在寻找你的 Mac" : "找到多台 Mac，点右上角选择"
            case .connecting(let name): return "正在连接 \(name)"
            case .needsCode: return "输入 Mac 上显示的配对码"
            case .failed: return "链路不可用，点右上角重试"
            case .idle: return "在 Mac 上打开 iMic"
            case .ready: return ""
            }
        }
        return "按住底部横条开始说话"
    }

    private var barFill: Color {
        switch session.phase {
        case .transcribing: return Theme.orangeDeep
        case .listening: return cancelArmed ? Theme.ivory : Theme.orange
        default: return canRecordNow ? Theme.orange : Theme.ink
        }
    }

    private var barTextColor: Color {
        if session.phase == .listening || session.phase == .transcribing {
            return session.phase == .transcribing ? Theme.ivory : Theme.ink
        }
        return canRecordNow ? Theme.ink : Theme.orange
    }

    private var barLabel: String {
        if session.micDenied { return "ENABLE MIC" }
        switch session.phase {
        case .listening: return cancelArmed ? "RELEASE TO CANCEL" : "RELEASE TO SEND"
        case .transcribing: return "TRANSCRIBING"
        case .result: return "HOLD TO SPEAK AGAIN"
        case .error: return "TRY AGAIN"
        case .idle: break
        }
        return canRecordNow ? "HOLD TO SPEAK" : "LINK TO MAC"
    }

    private func barCell(width: CGFloat) -> CGFloat {
        let length = CGFloat(barLabel.count)
        // 给左右 padding、麦克风图标和计时/提示留出空间，再拟合像素字。
        let available = max(120, width - 36 - 13 - 12 - 8)
        return max(1.8, min(2.7, available / max(1, length * 5 + (length - 1) * 0.8)))
    }
}
