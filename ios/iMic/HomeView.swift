import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PhosphorEffect.preferenceKey) private var displayMaterial = PhosphorEffect.crt.rawValue
    @AppStorage(PhosphorAttachStyle.preferenceKey) private var attachStyle = PhosphorAttachStyle.flow.rawValue

    @State private var pressing = false
    /// The current load has been shot or cleared: nothing is left to fire until the next take.
    @State private var loadSpent = false
    /// DEBUG flight preview only: 1 simulates polishing, 2 the armed state.
    @State private var debugStringStatus = 0
    @State private var cancelArmed = false
    @State private var showPairing = false
    @State private var interactionStart = false
    @State private var showCopied = false
    @State private var showResult = false
    @State private var showDevices = false
    @StateObject private var receiver = ReceiverFlowStore()
    @State private var connectionAnnounced = false
    @State private var stringAxis: StringAxis?
    @State private var stringHint: String?
    @State private var cursorStep = 0
    @State private var clearTriggeredThisGesture = false
    @State private var stringGestureBlocked = false
    @GestureState private var stringTouchActive = false

    private enum StringAxis: Equatable { case vertical, horizontal }
    private let contentInset: CGFloat = 24

    private var linkReady: Bool { link.phase.isReady }
    private var canRecordNow: Bool {
        linkReady || (link.hasPairedMac && link.phase.allowsBufferedRecording)
    }

    private var stringMotion: StringMotionStore { session.spectrumStore.stringMotion }
    private var canUseString: Bool {
        linkReady && link.gestureSupported && link.gestureReady && !link.clearPending
            && session.phase != .listening && session.phase != .transcribing && !session.isUploading
            && scenePhase == .active && !showPairing && !showResult && !showDevices
    }

    var body: some View {
        NavigationStack {
        GeometryReader { geometry in
            ZStack {
                TechBackground()
                let width = max(1, geometry.size.width - contentInset * 2)
                let height = geometry.size.height
                let instrumentHeight = min(300, height * 0.40)
                // Keep the entire interaction area together and about 24pt lower than the draft.
                let instrumentCenter = height * 0.52
                Group {
                    header
                        .frame(width: width, height: 62, alignment: .top)
                        .position(x: geometry.size.width / 2, y: 45)
                    HUDDivider(store: session.spectrumStore, connected: linkReady)
                        .frame(width: width, height: 10)
                        .position(x: geometry.size.width / 2, y: 87)
                    statusBlock(width: width)
                        .frame(height: 108, alignment: .top)
                        .position(x: geometry.size.width / 2, y: height * 0.145 + 74)
                    GeometryReader { torus in
                        Color.clear
                        .contentShape(WaveformHitArea())
                        .gesture(stringGesture(width: torus.size.width, height: torus.size.height,
                            frame: torus.frame(in: .global)))
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onChanged { _ in
                                // A fresh touch cancels a shot even before the
                                // directional gesture reaches its 6pt threshold.
                                stringMotion.cancelPendingReturn()
                            }
                        )
                    }
                    .frame(width: width, height: instrumentHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("弦控制")
                    .accessibilityHint("\(stringControlHint)。\(secondaryGestureHint)")
                    .accessibilityValue(stringHint ?? "")
                    .anchorPreference(key: ReceiverAnchorsKey.self, value: .bounds) {
                        ReceiverAnchors(torus: $0)
                    }
                    .position(x: geometry.size.width / 2, y: instrumentCenter)
                    VStack(spacing: 0) {
                        HoldBarRail(notice: cancelArmed ? "松开取消" : session.notice,
                                    noticeColor: cancelArmed ? Theme.ivory : Theme.muted)
                            .animation(.easeOut(duration: 0.18), value: session.notice)
                        holdBar(width: width)
                            .anchorPreference(key: ReceiverAnchorsKey.self, value: .bounds) {
                                ReceiverAnchors(source: $0)
                            }
                            .padding(.top, 10)
                        footer
                    }
                    .frame(width: width, height: 116, alignment: .top)
                    .position(x: geometry.size.width / 2, y: height - 64)
                }
                .frame(width: geometry.size.width, height: height)
                .transformAnchorPreference(key: ReceiverAnchorsKey.self, value: .bounds) { value, anchor in
                    value.content = anchor
                }

                if showResult {
                    resultOverlay
                        .modifier(PhosphorNativeGlass())
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(10)
                }
            }
            .coordinateSpace(name: "home")
            .animation(.easeOut(duration: 0.22), value: showResult)
            .overlayPreferenceValue(ReceiverAnchorsKey.self) { anchors in
                GeometryReader { proxy in
                    if !showResult, let torus = anchors.torus, let source = anchors.source {
                        ZStack {
                            if !receiver.unifiedAvailable {
                            TorusView(store: session.spectrumStore, dimmed: session.phase == .idle && !canRecordNow,
                                      instrumentHUD: true,
                                      channelLabel: linkReady ? "CH 01" : (canRecordNow ? "BUFFER" : "NO LINK"),
                                      viewportFrame: proxy[torus])
                            }
                            ReceiverFlowView(store: receiver, spectrum: session.spectrumStore,
                                             torusFrame: proxy[torus], sourceFrame: proxy[source],
                                             artwork: receiver.unifiedAvailable ? artwork(size: proxy.size,
                                                content: anchors.content.map { proxy[$0] } ?? CGRect(origin:.zero,size:proxy.size),
                                                torus: proxy[torus]) : nil,
                                             dimmed: session.phase == .idle && !canRecordNow,
                                             effect: PhosphorEffect(rawValue: displayMaterial) ?? .crt,
                                             clearEnabled: canUseString && session.pullDeleteEnabled,
                                             pressed: pressing && session.phase == .listening,
                                             processing: stringProcessing || debugStringStatus == 1,
                                             ready: stringReady || debugStringStatus == 2,
                                             attach: PhosphorAttachStyle(rawValue: attachStyle) ?? .flow)
                            if !receiver.unifiedAvailable {
                            ClearDropZone(motion: stringMotion, distance: max(1, proxy[torus].midY - 84),
                                          enabled: canUseString && session.pullDeleteEnabled)
                            }
                        }
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showDevices) {
            DeviceSelectionView()
                .environmentObject(link)
                .environmentObject(session)
                .toolbar(.visible, for: .navigationBar)
        }
        }
        .statusBarHidden(false)
        .simultaneousGesture(TapGesture().onEnded { session.spectrumStore.wake() })
        .sheet(isPresented: $showPairing) {
            PairingSheet()
                .environmentObject(link)
                .environmentObject(session)
        }
        .onAppear {
            session.spectrumStore.configureAmbientMotion(enabled: true, reducedMotion: reduceMotion)
            session.spectrumStore.setVisible(scenePhase == .active && !showPairing && !showResult && !showDevices)
            UIApplication.shared.isIdleTimerDisabled = true
            session.prepareHaptics()
            link.start()
            session.activateAudio()
            warmUpSounds()
            stringMotion.reduceMotion = reduceMotion
            stringMotion.onFireReturn = { [weak session = session, weak link = link, weak receiver = receiver] in
                guard let session, let link, link.phase.isReady,
                      session.snapReturnEnabled, !showPairing, !showResult, !showDevices,
                      UIApplication.shared.applicationState == .active,
                      session.sendInput("return") else { return false }
                session.showGestureNotice("发射文字")
                receiver?.fire()
                loadSpent = true
                return true
            }
            stringMotion.onRepeatDelete = { [weak session = session, weak link = link] in
                guard let session, let link, link.phase.isReady,
                      session.pullDeleteEnabled,
                      UIApplication.shared.applicationState == .active else { return false }
                guard session.sendInput("delete") else { return false }
                SoundDesign.shared.play(.delete)
                return true
            }
            if case .needsCode = link.phase, !showDevices {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !showDevices { showPairing = true }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-preview=pairing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPairing = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-result") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showResult = true }
            }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-preview=settings") {
                showPairing = true
            }
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview=devices") {
                showDevices = true
            }
            #endif
        }
        .onDisappear {
            session.spectrumStore.setVisible(false)
            UIApplication.shared.isIdleTimerDisabled = false
            stringMotion.cancel()
            receiver.cancelFlight()
            stringMotion.onRepeatDelete = nil
            stringMotion.onFireReturn = nil
            session.deactivateAudio()
        }
        .task {
            #if DEBUG
            // Standalone visual regression preview: no Mac, audio or input commands.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--debug-standby-check") {
                await StandbyDiagnostics.run(spectrum: session.spectrumStore, receiver: receiver)
            }
            if arguments.contains("--debug-standby-audio-check") {
                try? await Task.sleep(for: .seconds(2))
                await session.verifyStandbyAudio()
            }
            if arguments.contains("--ui-preview=flight") {
                let requested = arguments.first { $0.hasPrefix("--debug-flight-count=") }
                    .flatMap { Int($0.replacingOccurrences(of: "--debug-flight-count=", with: "")) } ?? 120
                let count = min(5000, max(1, requested))
                let phrase = "把今天讨论的交互细节整理成一页说明重点保留按住说话松开即输入的节奏"
                let delay = arguments.first { $0.hasPrefix("--debug-flight-delay=") }
                    .flatMap { Double($0.replacingOccurrences(of: "--debug-flight-delay=", with: "")) } ?? 0.4
                try? await Task.sleep(for: .seconds(min(10, max(0, delay))))
                guard !Task.isCancelled else { return }
                if let value = arguments.first(where: { $0.hasPrefix("--debug-flight-origin=") }),
                   let fraction = Double(value.replacingOccurrences(of: "--debug-flight-origin=", with: "")) {
                    receiver.updateTouch(xFraction: CGFloat(fraction))
                }
                receiver.update(text: String(String(repeating: phrase, count: count / phrase.count + 1).prefix(count)))
                if arguments.contains("--debug-flight-status") {
                    try? await Task.sleep(for: .seconds(1))
                    debugStringStatus = 1
                    try? await Task.sleep(for: .seconds(2.5))
                    debugStringStatus = 2
                    try? await Task.sleep(for: .seconds(2.5))
                } else {
                    try? await Task.sleep(for: .seconds(3))
                }
                guard !Task.isCancelled else { return }
                receiver.fire()
                debugStringStatus = 0
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            session.spectrumStore.setVisible(phase == .active && !showPairing && !showResult && !showDevices)
            if phase != .active {
                stringMotion.cancel()
                receiver.cancelFlight()
            }
            if phase == .active {
                session.handleForeground()
                warmUpSounds()
            } else if phase == .background {
                session.handleBackground()
            }
        }
        .onChange(of: canUseString) { _, allowed in
            if !allowed {
                if stringAxis != nil || stringTouchActive { stringGestureBlocked = true }
                stringMotion.cancel(preserveClear: true)
            }
        }
        .onChange(of: session.clearGeneration) { _, generation in
            Task { @MainActor in
                if stringMotion.isClearing { try? await Task.sleep(for: .milliseconds(300)) }
                guard session.clearGeneration == generation else { return }
                receiver.reset()
                loadSpent = true
            }
        }
        .onChange(of: link.phase) { _, phase in
            if !phase.isReady {
                stringMotion.cancel()
                receiver.cancelFlight()
            }
            switch phase {
            case .needsCode:
                connectionAnnounced = false
                Haptics.shared.play(.pairingRequired)
                if !showDevices { showPairing = true }
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
            if phase == .listening { loadSpent = false }
            if phase == .listening || phase == .idle {
                if !stringMotion.isClearing { receiver.reset() }
                showResult = false
            }
        }
        .onChange(of: stringReady) { _, ready in
            // Polished and typed on the Mac: the moment the load can be shot.
            if ready { Haptics.shared.play(.polishReady) }
        }
        .onChange(of: session.liveTranscript) { _, text in
            receiver.update(text: text)
        }
        .onChange(of: showDevices) { _, presented in
            if presented {
                showPairing = false
                stringMotion.cancel()
                receiver.cancelFlight()
            }
        }
        .onChange(of: showPairing) { _, presented in
            if presented { stringMotion.cancel() }
            session.spectrumStore.setVisible(!presented && scenePhase == .active && !showResult && !showDevices)
        }
        .onChange(of: showResult) { _, presented in
            if presented { stringMotion.cancel() }
            session.spectrumStore.setVisible(!presented && scenePhase == .active && !showPairing && !showDevices)
        }
        .onChange(of: session.pullDeleteEnabled) { _, enabled in
            if !enabled { stringMotion.cancel() }
        }
        .onChange(of: session.snapReturnEnabled) { _, enabled in
            if !enabled { stringMotion.cancel() }
        }
        .onChange(of: reduceMotion) { _, reduced in
            session.spectrumStore.configureAmbientMotion(enabled: true, reducedMotion: reduced)
            stringMotion.reduceMotion = reduced
        }
        .onReceive(stringMotion.$hint.removeDuplicates()) { hint in
            stringHint = hint
        }
        .onChange(of: stringTouchActive) { _, active in
            if !active { stringGestureBlocked = false; clearTriggeredThisGesture = false }
            // SwiftUI can cancel a drag without delivering onEnded (sheet/background).
            if !active, stringAxis != nil {
                stringMotion.cancel(preserveClear: true)
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

    private func artwork(size: CGSize, content: CGRect, torus: CGRect) -> PhosphorArtworkState {
        let width=max(1,size.width-contentInset*2)
        return PhosphorArtworkState(size:size,content:content,torus:torus,
            connection:connectionLabel,connectionColor:connectionColor,
            channel:linkReady ? "CH 01" : (canRecordNow ? "BUFFER" : "NO LINK"),
            status:statusWord,statusLine:statusLine,statusCell:statusCell(width:width),statusColor:statusColor,
            barLabel:barLabel,barCell:barCell(width:width),barFill:barFill,barText:barTextColor,
            canRecord:canRecordNow,listening:session.phase == .listening,
            elapsed:String(format:"%.1f s",session.elapsed),hasResult:hasResultText,
            notice:cancelArmed ? "松开取消":session.notice,
            noticeColor:cancelArmed ? Theme.ivory:Theme.muted)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image("Wordmark")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: HoldBarLayout.wordmark.width, height: HoldBarLayout.wordmark.height,
                           alignment: .leading)
                    .blendMode(.screen)
                    .accessibilityLabel("iMic")
                HUDLabel(text: "SYS 01")
            }
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Button {
                    Haptics.shared.play(.tap)
                    showPairing = false
                    showDevices = true
                } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(connectionColor).frame(width: 3.5, height: 3.5)
                        Text(connectionLabel)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .frame(maxWidth: 150, alignment: .trailing)
                .accessibilityLabel("连接电脑，\(connectionLabel)，点击切换 Mac")
                Button {
                    Haptics.shared.play(.tap)
                    showPairing = true
                } label: {
                    PixelSymbol(kind: .settings, color: Theme.ivory.opacity(0.72))
                        .frame(width: 19.5, height: 19.5)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("设置")
            }
            .buttonStyle(.plain)
            // Align the visible glyph, rather than its 44pt touch target, to the content edge.
            .padding(.trailing, -12)
            .offset(y: -9)
        }
    }

    // MARK: - Status

    private func statusBlock(width: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 0) {
            HUDLabel(text: "VOICE / INPUT")
                .padding(.bottom, 13)
            PixelText(text: statusWord, cell: statusCell(width: width),
                      color: statusColor, tracking: 2.8)
                .modifier(PhosphorReadout(color: statusColor))
                .frame(height: 30, alignment: .center)
            Text(statusLine)
                .modifier(InstrumentHint())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(minHeight: 34, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)
        }
        .frame(width: width, alignment: .center)
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

                ScrollView {
                    Text(session.transcript)
                        .font(.system(size: 16, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.ivory)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 280)

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
            RecordingBarShape()
                .fill(barFill)
                .overlay(
                    RecordingBarShape().stroke(
                        canRecordNow ? Color.clear : Theme.orange.opacity(0.8),
                        lineWidth: 1
                    )
                )
                .overlay(alignment: .leading) {
                    Rectangle().fill(barTextColor.opacity(0.32))
                        .frame(width: 2, height: HoldBarLayout.tickHeight).padding(.leading, 11)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(barTextColor.opacity(0.18))
                        .frame(width: 0.7, height: HoldBarLayout.separatorHeight)
                        .padding(.trailing, HoldBarLayout.accessoryWidth)
                }
            HStack(spacing: 0) {
                PixelText(
                    text: barLabel,
                    cell: barCell(width: width),
                    color: barTextColor,
                    tracking: HoldBarLayout.labelTracking
                )
                Spacer(minLength: HoldBarLayout.labelGap)
                ZStack {
                    if session.phase == .listening {
                        Text(String(format: "%.1f s", session.elapsed))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(barTextColor.opacity(0.8))
                            .minimumScaleFactor(0.8)
                    } else if canRecordNow {
                        PixelSymbol(kind: .microphone, color: barTextColor)
                            .frame(width: 14, height: 24)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(barTextColor.opacity(0.9))
                    }
                }
                .frame(width: HoldBarLayout.accessoryWidth)
            }
            .padding(.leading, HoldBarLayout.leading)
        }
        .frame(width: width, height: HoldBarLayout.height)
        .modifier(PhosphorSurface(strength: 0.8))
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
                },
                onPositionChanged: { fraction in
                    receiver.updateTouch(xFraction: fraction)
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
                receiver.updateTouch(xFraction: 0.5)
                beginInteraction()
            }
        }
    }

    /// 中心弦：竖向拨弦（下=回车，上=删除），横向滑动移动光标。
    private func stringGesture(width: CGFloat, height: CGFloat, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($stringTouchActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !stringMotion.isClearing else { return }
                guard !stringGestureBlocked else { return }
                guard canUseString else {
                    stringGestureBlocked = true
                    stringMotion.cancel()
                    stringHint = link.gestureSupported ? "等待电脑完成处理后再拉弦" : "请更新 Mac 端启用弦控制"
                    return
                }
                guard !clearTriggeredThisGesture else { return }
                if stringAxis == nil {
                    stringMotion.cancelPendingReturn()
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    stringAxis = dx > dy * 1.35 ? .horizontal : .vertical
                    if stringAxis == .vertical {
                        let stretch = session.pullDeleteEnabled ? StringClearStretch(
                            distance: frame.minY + value.startLocation.y - 84, depth: frame.midY - 84) : nil
                        stringMotion.begin(anchor: TorusGeometry.touchAnchor(x: value.startLocation.x, width: width),
                                           height: height, clearStretch: stretch)
                    }
                }
                switch stringAxis {
                case .vertical:
                    stringMotion.moveAnchor(to: TorusGeometry.touchAnchor(x: value.location.x, width: width))
                    if session.pullDeleteEnabled, value.translation.height < -80,
                       frame.minY + value.location.y <= 84 {
                        requestClear()
                        return
                    }
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
                if stringAxis == .vertical, canUseString, !stringGestureBlocked, !clearTriggeredThisGesture {
                    stringMotion.moveAnchor(to: TorusGeometry.touchAnchor(x: value.location.x, width: width))
                }
                if stringAxis == .vertical, canUseString, !stringGestureBlocked, !clearTriggeredThisGesture,
                   session.pullDeleteEnabled, value.translation.height < -80, frame.minY + value.location.y <= 84 {
                    requestClear()
                } else if stringAxis == .vertical {
                    let command = stringMotion.finish(
                        translation: value.translation.height,
                        velocity: value.velocity.height,
                        returnEnabled: canUseString && session.snapReturnEnabled,
                        deleteEnabled: canUseString && session.pullDeleteEnabled
                    )
                    if let command {
                        session.sendInput(command)
                        session.showGestureNotice("删除")
                        Haptics.shared.play(.deleteChar)
                    }
                }
                stringHint = nil
                stringAxis = nil
                cursorStep = 0
                clearTriggeredThisGesture = false
                stringGestureBlocked = false
            }
    }

    private func requestClear() {
        clearTriggeredThisGesture = true
        stringMotion.completeClearContact()
        if session.sendInput("clear") {
            session.showGestureNotice("正在清空输入框…")
            Haptics.shared.play(.cancelArmed)
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
        if stringProcessing {
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
            Spacer()
            ZStack(alignment: .trailing) {
                HUDLabel(text: "PCM / 16K")
                    .opacity(hasResultText ? 0 : 1)
                Button {
                    Haptics.shared.play(.overlayOpen)
                    showResult = true
                } label: {
                    Text("查看结果  ›")
                        .modifier(InstrumentHint())
                        .frame(minWidth: 74, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hasResultText ? 1 : 0)
                .allowsHitTesting(hasResultText)
                .accessibilityHidden(!hasResultText)
                .accessibilityLabel("查看识别结果")
            }
            .frame(width: 98, height: 32, alignment: .trailing)
        }
        .frame(height: 32)
        .padding(.top, 3)
    }

    /// After audio activation settles and outside a gesture, never on the first pull.
    private func warmUpSounds(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard scenePhase == .active else { return }
            guard !stringTouchActive, !pressing else {
                // Busy: try again shortly rather than stall the gesture in progress.
                if attempt < 5 { warmUpSounds(attempt: attempt + 1) }
                return
            }
            SoundDesign.shared.warmUp()
        }
    }

    /// The result is back on the phone but the Mac is still polishing, animating or typing it.
    /// The Mac rejects a new session until it reports ready, so the bar waits with it.
    private var macFinishing: Bool {
        (session.phase == .result && linkReady && link.gestureSupported && !link.gestureReady)
            || debugStringStatus == 1
    }

    /// From release until the Mac has received, polished and typed the load. The bar's
    /// disabled state, the coil's reading sweep and the status word all follow this one value.
    private var stringProcessing: Bool {
        session.phase == .transcribing || macFinishing
    }

    /// Polished and typed: pulling the string now shoots it. Not after the load has gone.
    private var stringReady: Bool {
        session.phase == .result && canUseString && session.snapReturnEnabled && !loadSpent
    }

    private var hasResultText: Bool {
        !session.transcript.isEmpty && session.phase != .listening
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
        case .ready(let name): return name
        case .connecting(let name): return "LINKING \(name)".uppercased()
        case .needsCode(let name): return "PAIR \(name)".uppercased()
        case .searching: return "SEARCHING"
        case .failed: return "OFFLINE"
        case .idle: return "STANDBY"
        }
    }

    private func statusCell(width: CGFloat) -> CGFloat {
        min(4.2, PixelFont.fittedCell(for: statusWord, width: width, tracking: 2.8))
    }

    private var statusWord: String {
        switch session.phase {
        case .listening: return "LISTEN"
        case .transcribing: return session.isUploading ? "SENDING" : "POLISH"
        case .result: return macFinishing ? "POLISH" : "DONE"
        case .error: return "ERROR"
        case .idle: if debugStringStatus == 1 { return "POLISH" }
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
        if canUseString, session.snapReturnEnabled, stringMotion.armed, stringMotion.chargeTension > 0 {
            return "松手弹射想法"
        }
        switch session.phase {
        case .listening:
            if !linkReady { return "正在连接 Mac · 先说着，连上即发送" }
            return "松开即发送 · 上滑取消"
        case .transcribing:
            if !linkReady { return "正在连接 Mac，连接后立即发送" }
            return session.message ?? (session.isUploading ? "正在上传音频…" : "正在把语音变成文字")
        case .result:
            if macFinishing { return "等待电脑完成润色与输入" }
            let done = session.pasted ? session.target.map { "已填入 \($0)" } : nil
            if stringReady { return (done.map { $0 + " · " } ?? "") + "下拉松手发射" }
            return done ?? "文字已回传到 iPhone"
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
        if macFinishing { return Theme.orangeDeep }
        switch session.phase {
        case .transcribing: return Theme.orangeDeep
        case .listening: return cancelArmed ? Theme.ivory : Theme.orange
        default: return canRecordNow ? Theme.orange : Theme.ink
        }
    }

    private var barTextColor: Color {
        if session.phase == .listening || stringProcessing {
            return stringProcessing ? Theme.ivory : Theme.ink
        }
        return canRecordNow ? Theme.ink : Theme.orange
    }

    private var barLabel: String {
        if session.micDenied { return "ENABLE MIC" }
        switch session.phase {
        case .listening: return cancelArmed ? "RELEASE TO CANCEL" : "RELEASE TO SEND"
        case .transcribing: return "TRANSCRIBING"
        case .result: return macFinishing ? "POLISHING" : "HOLD TO SPEAK AGAIN"
        case .error: return "TRY AGAIN"
        case .idle: if macFinishing { return "POLISHING" }
        }
        return canRecordNow ? "HOLD TO SPEAK" : "LINK TO MAC"
    }

    private func barCell(width: CGFloat) -> CGFloat {
        min(2.3, PixelFont.fittedCell(for: barLabel, width: HoldBarLayout.labelWidth(barWidth: width), tracking: HoldBarLayout.labelTracking))
    }

    private var stringControlHint: String {
        guard linkReady else { return "连接 Mac 后可拨弦" }
        guard link.gestureSupported else { return "请更新 Mac 端启用弦控制" }
        if link.clearPending { return "正在清空输入框…" }
        if session.phase == .listening { return "录音结束并完成输入后可拉弦" }
        guard link.gestureReady, session.phase != .transcribing, !session.isUploading else {
            return "等待电脑完成润色、动画与输入"
        }
        return session.snapReturnEnabled ? "下拉松手发射文字" : "发射已在 Mac 关闭"
    }

    private var secondaryGestureHint: String {
        guard linkReady else { return "语音和按键发送到当前选择的 Mac" }
        var actions: [String] = []
        if session.pullDeleteEnabled { actions.append("上拉删除／顶部清空") }
        if session.swipeCursorEnabled { actions.append("左右移动光标") }
        return actions.isEmpty ? "弦手势已在 Mac 关闭" : actions.joined(separator: " · ")
    }
}

/// Only a touch that starts on the waveform grabs the string: the band between the ruler
/// ends, not the empty instrument space above it or the gap down to the hold bar.
/// Mirrors `TorusGeometry.Layout`'s `baseRy` and ruler extent.
private struct WaveformHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        let half = min(rect.height * 0.23, max(0, rect.height / 2 - 16)) * 1.42
        return Path(CGRect(x: rect.minX, y: rect.midY - half, width: rect.width, height: half * 2))
    }
}

private struct ReceiverAnchors {
    var content: Anchor<CGRect>?
    var torus: Anchor<CGRect>?
    var source: Anchor<CGRect>?
}

private struct ReceiverAnchorsKey: PreferenceKey {
    static var defaultValue = ReceiverAnchors()
    static func reduce(value: inout ReceiverAnchors, nextValue: () -> ReceiverAnchors) {
        let next = nextValue()
        if let content = next.content { value.content = content }
        if let torus = next.torus { value.torus = torus }
        if let source = next.source { value.source = source }
    }
}
