import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
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
    @State private var showMicrophoneTest = false
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
        session.practiceActive || linkReady || (link.hasPairedMac && link.phase.allowsBufferedRecording)
    }

    private var stringMotion: StringMotionStore { session.spectrumStore.stringMotion }
    private var canUseString: Bool {
        (session.practiceActive || (linkReady && link.gestureSupported && link.gestureReady && !link.clearPending))
            && session.phase != .listening && session.phase != .transcribing && !session.isUploading
            && scenePhase == .active && !showPairing && !showResult && !showDevices
            && !onboardingConnection && !showMicrophoneTest
    }

    private var onboardingConnection: Bool { onboarding.presented && [.mac, .link, .pair].contains(onboarding.step) }

    var body: some View {
        NavigationStack {
        GeometryReader { geometry in
            ZStack {
                TechBackground()
                let width = max(1, geometry.size.width - contentInset * 2)
                let height = geometry.size.height
                let instrumentHeight = moreGestures ? min(90, height * (height < 700 ? 0.085 : 0.12)) : dynamicType.isAccessibilitySize ? min(80, height * 0.11) : min(300, height * 0.40)
                // Large teaching copy keeps the real instrument compact and below the status block.
                let instrumentCenter = height * (moreGestures ? (height < 700 ? 0.75 : 0.77) : dynamicType.isAccessibilitySize ? 0.75 : 0.52)
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
                    .accessibilityLabel(L10n.text("String controls"))
                    .accessibilityIdentifier("home.string")
                    .accessibilityHint("\(stringControlHint)。\(secondaryGestureHint)")
                    .accessibilityValue(stringHint ?? "")
                    .anchorPreference(key: ReceiverAnchorsKey.self, value: .bounds) {
                        ReceiverAnchors(torus: $0)
                    }
                    .position(x: geometry.size.width / 2, y: instrumentCenter)
                    VStack(spacing: 0) {
                        HoldBarRail(notice: cancelArmed ? L10n.text("Release to cancel") : session.notice,
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
                                      channelLabel: session.practiceActive ? "PRACTICE" : linkReady ? "CH 01" : (canRecordNow ? "BUFFER" : "NO LINK"),
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
                                             recordingElapsed: session.recordingVisualElapsed,
                                             recordingEnding: session.recordingVisualEnding,
                                             processing: stringProcessing || debugStringStatus == 1,
                                             ready: stringReady || debugStringStatus == 2,
                                             attach: PhosphorAttachStyle(rawValue: attachStyle) ?? .flow)
                            if !receiver.unifiedAvailable {
                            ClearDropZone(motion: stringMotion, distance: max(1, proxy[torus].midY - 84),
                                          enabled: canUseString && session.pullDeleteEnabled)
                            }
                        }
                        .allowsHitTesting(false)
                        // A real first-use failure must leave the existing MIC TEST
                        // and recovery controls available, just like normal HomeView.
                        if onboarding.presented && !onboardingConnection
                            && !(onboarding.step == .ready && session.phase == .error) {
                            OnboardingView(source: proxy[source], torus: proxy[torus], size: proxy.size,
                                topInset: anchors.content.map { proxy[$0].minY } ?? 62)
                        }
                    }
                }
                .ignoresSafeArea()
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
        .sheet(isPresented: $showPairing) {
            PairingSheet()
                .environmentObject(link)
                .environmentObject(session)
        }
        .fullScreenCover(isPresented: Binding(get: { onboardingConnection }, set: { _ in })) {
            NavigationStack { DeviceSelectionView(onboardingMode: true) }
        }
        .sheet(isPresented: $showMicrophoneTest) {
            MicrophoneTestView().environmentObject(session)
        }
        .overlay(alignment: .top) {
            #if DEBUG
            if !onboarding.presented { OnboardingAudit().padding(.top, 100) }
            #endif
            if !onboarding.presented && onboarding.unfinished && !link.phase.isReady {
                Button(L10n.text("No Mac connected · Continue setup")) { onboarding.resume() }
                    .font(.callout).foregroundStyle(Theme.orange)
                    .padding(12).background(Theme.ink).padding(.top, 84)
            }
        }
        .onAppear {
            session.spectrumStore.configureAmbientMotion(enabled: true, reducedMotion: reduceMotion)
            session.spectrumStore.setVisible(scenePhase == .active && !showPairing && !showResult && !showDevices && !showMicrophoneTest)
            UIApplication.shared.isIdleTimerDisabled = true
            session.prepareHaptics()
            configureOnboarding()
            if !onboarding.localHome { link.start(); session.activateAudio() }
            warmUpSounds()
            stringMotion.reduceMotion = reduceMotion
            stringMotion.onFireReturn = { [weak session = session, weak link = link, weak receiver = receiver] in
                guard let session, let link, (session.practiceActive || link.phase.isReady),
                      session.snapReturnEnabled, !showPairing, !showResult, !showDevices,
                      UIApplication.shared.applicationState == .active,
                      session.sendInput("return") else { return false }
                session.showGestureNotice(L10n.text("Launch text"))
                receiver?.fire()
                loadSpent = true
                return true
            }
            stringMotion.onRepeatDelete = { [weak session = session, weak link = link] in
                guard let session, let link, (session.practiceActive || link.phase.isReady),
                      session.pullDeleteEnabled,
                      UIApplication.shared.applicationState == .active else { return false }
                guard session.sendInput("delete") else { return false }
                SoundDesign.shared.play(.delete)
                return true
            }
            if case .needsCode = link.phase, !showDevices {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !showDevices && !onboarding.presented { showPairing = true }
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview=pairing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPairing = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--show-result") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showResult = true }
            }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-preview=mic-test") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showMicrophoneTest = true }
            }
            if arguments.contains("--ui-preview=settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPairing = true }
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
            DemoTouchOverlay.installIfNeeded()
            if ProcessInfo.processInfo.arguments.contains(where: { $0 == "--ui-preview=devices" || $0.hasPrefix("--ui-preview=devices-manage") }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showDevices = true }
            }
            #endif
        }
        .onChange(of: onboarding.localHome) { _, _ in configureOnboarding() }
        .onChange(of: onboarding.step) { _, _ in configureOnboarding() }
        .onChange(of: onboarding.presented) { _, _ in configureOnboarding() }
        .onChange(of: onboarding.action) { _, action in
            guard session.practiceActive else { return }
            // Skips can happen mid-hold; discard local timers and seed the next lesson.
            if (action == .cancel && !stringMotion.isClearing) || ((action == .send || action == .delete) && (session.phase != .result || session.transcript.isEmpty)) {
                session.practice.reset(seed: action != .cancel)
                loadSpent = false
                stringMotion.cancel()
                receiver.reset()
                receiver.update(text: session.liveTranscript)
            }
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
                let phrase = L10n.text("Turn today's discussion about interaction details into a one-page brief. Keep the rhythm of hold to speak, release to type.")
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
            session.spectrumStore.setVisible(phase == .active && !showPairing && !showResult && !showDevices && !showMicrophoneTest)
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
                if !showDevices && !onboarding.presented { showPairing = true }
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
            if phase == .result {
                onboarding.receivedFirstResult(pasted: session.pasted)
            }
            if phase == .listening { loadSpent = false }
            if phase != .listening && !pressing && !session.isRecordingRequested {
                interactionStart = false
            }
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
        .onChange(of: showMicrophoneTest) { _, presented in
            if presented { stringMotion.cancel(); receiver.cancelFlight() }
            session.spectrumStore.setVisible(!presented && scenePhase == .active && !showPairing && !showResult && !showDevices)
        }
        .onChange(of: showPairing) { _, presented in
            if presented { stringMotion.cancel() }
            session.spectrumStore.setVisible(!presented && scenePhase == .active && !showResult && !showDevices && !showMicrophoneTest)
        }
        .onChange(of: showResult) { _, presented in
            if presented { stringMotion.cancel() }
            session.spectrumStore.setVisible(!presented && scenePhase == .active && !showPairing && !showDevices && !showMicrophoneTest)
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
            // GestureState may reset before onEnded in optimized builds. Let the
            // real release finish first; still clean up gestures canceled by the OS.
            if !active {
                Task { @MainActor in
                    await Task.yield()
                    guard !stringTouchActive else { return }
                    stringGestureBlocked = false; clearTriggeredThisGesture = false
                    if stringAxis != nil {
                        stringMotion.cancel(preserveClear: true)
                        stringAxis = nil; cursorStep = 0; stringHint = nil
                    }
                }
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

    private func configureOnboarding() {
        if onboarding.localHome {
            showPairing = false; showDevices = false; showResult = false
            if !session.practiceActive {
                link.suspendForPractice()
                session.setPracticeActive(true)
                if onboarding.step == .practice && ![.hold, .release, .cancel].contains(onboarding.action) {
                    session.practice.reset(seed: true)
                    receiver.update(text: session.liveTranscript)
                }
            }
            session.practice.performed = { event in onboarding.performed(event) }
            #if DEBUG
            if onboarding.preview == "release", session.phase == .idle { session.beginListening() }
            #endif
        } else {
            let wasPractice = session.practiceActive
            if wasPractice {
                session.setPracticeActive(false)
                pressing = false; cancelArmed = false; interactionStart = false
                loadSpent = false; stringAxis = nil; cursorStep = 0; stringHint = nil
                clearTriggeredThisGesture = false; stringGestureBlocked = false
                stringMotion.cancel(); receiver.reset()
            }
            if onboarding.connectionDeferred && onboarding.preview == nil {
                link.suspendForPractice()
            } else {
                link.startDeferred = false
                link.start()
            }
        }
    }

    private func startConnection() {
        onboarding.connectNow()
        link.startDeferred = false
        link.start()
    }

    // MARK: - Header

    private func artwork(size: CGSize, content: CGRect, torus: CGRect) -> PhosphorArtworkState {
        let width=max(1,size.width-contentInset*2)
        return PhosphorArtworkState(size:size,content:content,torus:torus,
            connection:connectionLabel,connectionColor:connectionColor,
            channel:session.practiceActive ? "PRACTICE" : linkReady ? "CH 01" : (canRecordNow ? "BUFFER" : "NO LINK"),
            status:statusWord,statusLine:statusLine,statusCell:statusCell(width:width),statusColor:statusColor,
            barLabel:barLabel,barCell:barCell(width:width),barFill:barFill,barText:barTextColor,
            canRecord:canRecordNow,listening:session.phase == .listening,
            elapsed:String(format: "%.1f s", locale: L10n.locale,session.elapsed),hasResult:hasResultText,
            notice:cancelArmed ? L10n.text("Release to cancel"):session.notice,
            noticeColor:cancelArmed ? Theme.ivory:Theme.muted,
            teaching:guideStatus, guideHeader:guideHeader, statusDetail:statusDetail,
            celebrating:onboarding.celebrating, dynamicType:dynamicType)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            InstrumentIdentity()
            Spacer(minLength: 12)
            if guideStatus {
                Button {
                    if onboarding.step == .welcome { onboarding.go(.link) } else { onboarding.skip() }
                } label: {
                    HUDLabel(text: guideHeader ?? "GUIDE", color: Theme.ivory).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).offset(y: -9)
                .accessibilityIdentifier(onboarding.step == .welcome ? "onboarding.existing" : "onboarding.skip")
            } else {
            HStack(spacing: 5) {
                Button {
                    Haptics.shared.play(.tap)
                    startConnection()
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
                .accessibilityLabel(L10n.text("Connect to a computer, %@, tap to switch Macs", L10n.argument(connectionLabel)))
                Button {
                    Haptics.shared.play(.tap)
                    startConnection()
                    showPairing = true
                } label: {
                    PixelSymbol(kind: .settings, color: Theme.ivory.opacity(0.72))
                        .frame(width: 19.5, height: 19.5)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.text("Settings"))
            }
            .buttonStyle(.plain)
            .disabled(onboarding.localHome)
            // Align the visible glyph, rather than its 44pt touch target, to the content edge.
            .padding(.trailing, -12)
            .offset(y: -9)
            }
        }
    }

    // MARK: - Status

    private func statusBlock(width: CGFloat) -> some View {
        InstrumentStatus(word: statusWord, description: statusLine, detail: statusDetail,
                         cell: statusCell(width: width), color: statusColor, teaching: guideStatus,
                         celebrating: onboarding.celebrating)
            .frame(width: width)
    }

    private var moreGestures: Bool { onboarding.localHome && onboarding.step == .practice && onboarding.action == .more }
    private var guideStatus: Bool {
        onboarding.presented && !onboardingConnection && !(onboarding.step == .ready && session.phase == .error)
    }
    private var guideHeader: String? {
        guard guideStatus else { return nil }
        if onboarding.step == .welcome { return "GUIDE · " + L10n.text("Used VoxChord") }
        let progress = onboarding.step == .practice ? onboarding.action.progress.replacingOccurrences(of: " / ", with: "/0") : "3/03"
        return "GUIDE 0" + progress + " · " + L10n.text("Skip")
    }
    private var statusDetail: String? {
        guideStatus && onboarding.step == .ready && !onboarding.celebrating
            ? L10n.text("Microphone access is needed when you speak") : nil
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
                    .accessibilityLabel(L10n.text("Close result"))
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
                            Text(showCopied ? L10n.text("Copied") : L10n.text("Copy"))
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
                        Text(String(format: "%.1f s", locale: L10n.locale, session.elapsed))
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
                        if session.practiceActive { session.practice.cancelGestureArmed = armed }
                        Haptics.shared.play(armed ? .cancelArmed : .cancelDisarmed)
                    }
                },
                onEnded: { cancelled in
                    pressing = false
                    cancelArmed = false
                    interactionStart = false
                    if session.phase == .listening || session.isRecordingRequested {
                        session.endListening(cancelled: cancelled)
                    }
                },
                onPositionChanged: { fraction in
                    receiver.updateTouch(xFraction: fraction)
                },
                onDurationMeasured: { duration in
                    if session.practiceActive { session.practice.measuredHoldDuration = duration }
                }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(barLabel)
        .accessibilityIdentifier("home.hold")
        .accessibilityHint(statusLine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if session.phase == .listening || session.isRecordingRequested {
                interactionStart = false
                session.endListening(cancelled: false)
            } else {
                receiver.updateTouch(xFraction: 0.5)
                beginInteraction()
                if session.phase != .listening && !session.isRecordingRequested {
                    interactionStart = false
                }
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
                    stringHint = link.gestureSupported ? L10n.text("Wait for your Mac to finish before pulling the string") : L10n.text("Update VoxChord on your Mac to enable string controls")
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
                            stringHint = direction == "right" ? L10n.text("Cursor →") : L10n.text("Cursor ←")
                        } else {
                            stringHint = L10n.text("Cursor movement is disabled on your Mac")
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
                        session.showGestureNotice(L10n.text("Delete"))
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
            session.showGestureNotice(L10n.text("Clearing the text field…"))
            Haptics.shared.play(.cancelArmed)
        }
    }

    private func beginInteraction() {
        guard !interactionStart else { return }
        if onboarding.localHome && onboarding.step == .practice && !onboarding.action.bar { return }
        if onboarding.presented && onboarding.step == .welcome { onboarding.startPractice() }
        if !session.practiceActive && onboarding.connectionDeferred { startConnection() }
        if !canRecordNow {
            Haptics.shared.play(.pairingRequired)
            showPairing = true
            return
        }
        if !session.practiceActive && session.micDenied {
            Haptics.shared.play(.warning)
            session.openMicrophoneSettings()
            return
        }
        if stringProcessing {
            return
        }
        interactionStart = true
        if session.phase == .error || session.phase == .result {
            session.reset()
        }
        session.beginListening()
        if session.phase != .listening && !session.isRecordingRequested {
            interactionStart = false
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if session.phase == .error {
                Button(L10n.text("Open microphone test")) { showMicrophoneTest = true }
                    .font(.caption).foregroundStyle(Theme.orange).frame(minHeight: 44)
                Spacer()
            }
            ZStack(alignment: .trailing) {
                if hasResultText {
                    Button {
                        Haptics.shared.play(.overlayOpen)
                        showResult = true
                    } label: {
                        Text(L10n.text("View result  ›"))
                            .modifier(InstrumentHint())
                            .frame(minWidth: 74, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("View recognition result"))
                } else {
                    HUDLabel(text: "PCM / 16K")
                }
            }
            .frame(width: 98, height: 32, alignment: .trailing)
        }
        .frame(height: 32)
        .padding(.top, 3)
        .accessibilityHidden(onboarding.localHome)
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
        (!session.practiceActive && session.phase == .result && linkReady && link.gestureSupported && !link.gestureReady)
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
        if session.practiceActive { return "PRACTICE" }
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
        if guideStatus {
            if onboarding.celebrating { return "DONE" }
            if onboarding.step == .welcome { return "READY" }
            if onboarding.step == .practice {
                if session.phase == .transcribing { return "POLISH" }
                switch onboarding.action {
                case .hold: return "HOLD"
                case .release: return "RELEASE"
                case .send: return "PULL"
                case .more: return "DONE"
                case .delete: return "DELETE"
                case .cursor: return "SLIDE"
                case .clear: return "CLEAR"
                case .cancel: return "CANCEL"
                }
            }
        }
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
        if guideStatus {
            if onboarding.celebrating { return L10n.text("That's it.") }
            if onboarding.step == .welcome { return L10n.text("One phone. Every input.") }
            if onboarding.step == .practice { return onboarding.action.prompt }
            if session.phase == .idle { return L10n.text("Click your Mac's input, then hold to speak") }
        }
        if session.practiceActive {
            if session.phase == .result {
                if [.delete, .cursor, .clear].contains(onboarding.action) { return session.practice.cursorText }
                return L10n.text("Typed in practice")
            }
            return ""
        }
        if canUseString, session.snapReturnEnabled, stringMotion.armed, stringMotion.chargeTension > 0 {
            return L10n.text("Release to launch your idea")
        }
        switch session.phase {
        case .listening:
            if !linkReady { return L10n.text("Connecting to Mac · Speak now, send when connected") }
            return L10n.text("Release to send · Slide up to cancel")
        case .transcribing:
            if !linkReady { return L10n.text("Connecting to Mac. Your audio will send as soon as it connects.") }
            return session.message ?? (session.isUploading ? L10n.text("Uploading audio…") : L10n.text("Turning your voice into text"))
        case .result:
            if macFinishing { return L10n.text("Waiting for your Mac to finish polishing and typing") }
            let done = session.pasted ? session.target.map { L10n.text("Typed into %@", L10n.argument($0)) } : nil
            if stringReady { return (done.map { $0 + " · " } ?? "") + L10n.text("Pull down and release to launch") }
            return done ?? L10n.text("Text sent back to your iPhone")
        case .error:
            return session.message ?? L10n.text("Please try again")
        case .idle:
            break
        }
        if !linkReady {
            if canRecordNow { return L10n.text("Hold to speak now. Send when connected.") }
            switch link.phase {
            case .searching: return link.macs.isEmpty ? L10n.text("Looking for your Mac") : L10n.text("Multiple Macs found. Choose one at the top right.")
            case .connecting(let name): return L10n.text("Connecting to %@", L10n.argument(name))
            case .needsCode: return L10n.text("Enter the pairing code shown on your Mac")
            case .failed: return L10n.text("Connection unavailable. Tap the top right to retry.")
            case .idle: return L10n.text("Open VoxChord on your Mac")
            case .ready: return ""
            }
        }
        return L10n.text("Hold the bottom bar to speak")
    }

    private var barFill: Color {
        if guideStatus { return Theme.orange }
        if macFinishing { return Theme.orangeDeep }
        switch session.phase {
        case .transcribing: return Theme.orangeDeep
        case .listening: return cancelArmed ? Theme.ivory : Theme.orange
        default: return canRecordNow ? Theme.orange : Theme.ink
        }
    }

    private var barTextColor: Color {
        if guideStatus { return Theme.ink }
        if session.phase == .listening || stringProcessing {
            return stringProcessing ? Theme.ivory : Theme.ink
        }
        return canRecordNow ? Theme.ink : Theme.orange
    }

    private var barLabel: String {
        if guideStatus && onboarding.step == .welcome { return "HOLD TO START" }
        if !session.practiceActive && session.micDenied { return "ENABLE MIC" }
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
        if session.practiceActive { return onboarding.action.prompt }
        guard linkReady else { return L10n.text("Connect to a Mac to use the string") }
        guard link.gestureSupported else { return L10n.text("Update VoxChord on your Mac to enable string controls") }
        if link.clearPending { return L10n.text("Clearing the text field…") }
        if session.phase == .listening { return L10n.text("Finish recording and typing before pulling the string") }
        guard link.gestureReady, session.phase != .transcribing, !session.isUploading else {
            return L10n.text("Waiting for polishing, animation, and typing on your Mac")
        }
        return session.snapReturnEnabled ? L10n.text("Pull down and release to launch text") : L10n.text("Text launch is disabled on your Mac")
    }

    private var secondaryGestureHint: String {
        guard linkReady else { return L10n.text("Voice and keystrokes go to the selected Mac") }
        var actions: [String] = []
        if session.pullDeleteEnabled { actions.append(L10n.text("Pull up to delete / Pull to the top to clear")) }
        if session.swipeCursorEnabled { actions.append(L10n.text("Slide left or right to move the cursor")) }
        return actions.isEmpty ? L10n.text("String gestures are disabled on your Mac") : actions.joined(separator: " · ")
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
