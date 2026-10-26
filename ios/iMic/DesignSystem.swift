import SwiftUI

enum Theme {
    static let ink = Color(red: 0.019, green: 0.019, blue: 0.019)
    static let panel = Color(red: 0.043, green: 0.043, blue: 0.043)
    static let panelRaised = Color(red: 0.065, green: 0.065, blue: 0.065)
    static let orange = Color(red: 1.0, green: 0.29, blue: 0.0)
    static let orangeDeep = Color(red: 0.48, green: 0.14, blue: 0.0)
    static let ivory = Color(red: 0.95, green: 0.94, blue: 0.90)
    static let muted = Color(red: 0.55, green: 0.53, blue: 0.50)
    static let line = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.06)
}

struct MetaLabel: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct Hairline: View {
    var color: Color = Theme.hairline
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

/// 黑底与轻量网格。静止背景不参与动画。
struct TechBackground: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            Canvas { context, size in
                let pixel = 1 / displayScale
                let offset = pixel / 2
                var grid = Path()
                for x in stride(from: 0.0, through: size.width, by: 26.0) {
                    grid.move(to: CGPoint(x: x + offset, y: 0))
                    grid.addLine(to: CGPoint(x: x + offset, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 26.0) {
                    grid.move(to: CGPoint(x: 0, y: y + offset))
                    grid.addLine(to: CGPoint(x: size.width, y: y + offset))
                }
                context.stroke(grid, with: .color(Color.white.opacity(0.065)), lineWidth: pixel)

            }
            .ignoresSafeArea()
        }
    }
}

/// 无 SwiftUI/显示时钟依赖的主图模型，可用缓存 bands 和合成频谱直接验证。
enum TorusGeometry {
    static let ringCount = 44

    static func clampedAnchor(_ anchor: CGFloat) -> CGFloat {
        anchor.isFinite ? min(0.94, max(0.06, anchor)) : 0.5
    }

    /// Touches use the view's coordinates; tension uses the span between fixed rails.
    static func touchAnchor(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite, x.isFinite else { return 0.5 }
        let bar = max(0, min(width * 0.88, width - 32))
        let left = width / 2 - bar / 2 - 12
        return clampedAnchor((x - left) / max(1, bar + 24))
    }

    struct RingPosition {
        let progress: CGFloat
        let envelope: CGFloat
    }

    static let positions: [RingPosition] = (0..<ringCount).map { index in
        let t = CGFloat(index) / CGFloat(ringCount - 1)
        return RingPosition(progress: t, envelope: pow(max(0, sin(t * .pi)), 0.7))
    }

    static let orbitSamples: [CGPoint] = (0..<96).map { index in
        let angle = Double(index) * 2 * .pi / 96
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    struct SpectrumRelief {
        let floor: CGFloat
        let span: CGFloat
        let presence: CGFloat

        init(bands: [CGFloat]) {
            var sum: CGFloat = 0
            var peak: CGFloat = 0
            for band in bands {
                let value = min(1, max(0, band))
                sum += value
                peak = max(peak, value)
            }
            let mean = bands.isEmpty ? 0 : sum / CGFloat(bands.count)
            // 扩开旧缓存的窄动态范围；新 FFT 的零谷保持为零。0.38 下限
            // 和绝对 presence 防止把静音/微小浮动再次归一成满幅形变。
            floor = max(0, mean - 0.24)
            span = max(0.38, peak - floor)
            presence = min(1, peak * 2)
        }

        func shape(energy: CGFloat) -> CGFloat {
            let relative = min(1, max(0, (energy - floor) / span))
            // 保留绝对包络，不能让逐帧归一化抵消声音的起落缓动。
            return relative * relative * (3 - 2 * relative) * (0.35 + 0.65 * min(1, max(0, energy)))
        }
    }

    struct RingProfile {
        let radius: CGFloat
        let opacity: CGFloat
    }

    static func ringProfile(energy: CGFloat, relief: SpectrumRelief, level: CGFloat,
                            breath: CGFloat, texture: CGFloat,
                            envelope: CGFloat) -> RingProfile {
        let shape = relief.shape(energy: energy)
        let idle = 0.46 + 0.08 * breath + texture * 0.018
        // Give the resting string more body. Fade this extra fill continuously with
        // the already-smoothed spectrum, reaching zero with zero slope at full presence.
        // The original voiced peak/valley response is then unchanged.
        let quietFill = 0.16 * pow(1 - relief.presence, 2)
        let body = min(0.98, max(0.16,
            idle + quietFill - 0.15 * relief.presence + 0.59 * shape + 0.025 * level))
        return RingProfile(
            radius: (0.30 + 0.70 * envelope) * body,
            opacity: min(1, 0.30 + 0.07 * breath + 0.12 * level + 0.35 * shape)
        )
    }

    /// 与 Canvas 使用相同的局部椭圆及旋转；文字可直接附着到真实描边。
    struct Ring {
        let center: CGPoint
        let radiusX: CGFloat
        let radiusY: CGFloat
        let rotation: CGFloat
        let opacity: CGFloat

        func point(at angle: CGFloat) -> CGPoint {
            let x = cos(angle) * radiusX
            let y = sin(angle) * radiusY
            let c = cos(rotation)
            let s = sin(rotation)
            return CGPoint(x: center.x + x * c - y * s,
                           y: center.y + x * s + y * c)
        }
    }

    /// 一帧只解析一次全频谱；圆环、轨道和文字共用固定端弦的投影预算。
    struct Layout {
        let size: CGSize
        let frame: SpectrumFrame
        let anchor: CGFloat
        let motion: CGFloat
        let breath: CGFloat
        let level: CGFloat
        let relief: SpectrumRelief
        let cx: CGFloat
        let cy: CGFloat
        let bar: CGFloat
        let baseRy: CGFloat
        let leftRail: CGFloat
        let rightRail: CGFloat
        let rulerTop: CGFloat
        let rulerBottom: CGFloat
        let orbitHeight: CGFloat
        let effectivePull: CGFloat
        let tension: CGFloat
        let longStretch: CGFloat
        let upwardAlignment: CGFloat

        init(size: CGSize, frame: SpectrumFrame, pull: CGFloat,
             anchor: CGFloat, reducedMotion: Bool, extendedUpward: Bool = false,
             upwardTravel: CGFloat? = nil) {
            self.size = size
            self.frame = frame
            self.anchor = anchor
            motion = reducedMotion ? 0 : 1
            breath = 0.5 + (frame.breath - 0.5) * motion
            level = min(1, max(0, frame.level))
            relief = SpectrumRelief(bands: frame.bands)
            cx = size.width / 2
            cy = size.height / 2
            bar = max(0, min(size.width * 0.88, size.width - 32))
            baseRy = min(size.height * 0.23, max(0, cy - 16))
            leftRail = cx - bar / 2 - 12
            rightRail = cx + bar / 2 + 12
            rulerTop = cy - baseRy * 1.42
            rulerBottom = cy + baseRy * 1.42
            orbitHeight = size.height * (0.05 + 0.018 * relief.presence)
            effectivePull = extendedUpward && pull < 0 ? pull : TorusGeometry.projectedPull(
                pull, height: size.height, baseRadius: baseRy * 1.12)
            tension = min(1, abs(effectivePull) / max(1, size.height * 0.20))
            // Use the full trip to the screen-top zone, not the small waveform's height.
            // Shrink slowly at first and keep a substantial coil even at full extension.
            let travel = max(1, upwardTravel ?? size.height * 1.5)
            let extended = extendedUpward ? min(1, max(0, -effectivePull / travel)) : 0
            longStretch = extended * extended * extended * (3 - 2 * extended)
            let alignment = extendedUpward ? min(1, max(0, -effectivePull / max(1, size.height * 0.30))) : 0
            upwardAlignment = alignment * alignment * (3 - 2 * alignment)
        }

        func stringY(at x: CGFloat) -> CGFloat {
            let progress = (x - leftRail) / max(1, rightRail - leftRail)
            let bend = TorusGeometry.stringDisplacement(
                progress: progress, anchor: anchor, pull: effectivePull)
            let texture = CGFloat(BreathingNoise.value(Double(progress) * 2.6 + frame.time * 0.20))
            let pinnedEnvelope = max(0, 4 * progress * (1 - progress))
            let contour = texture * (0.35 + level * 1.3) * motion * pinnedEnvelope
            return cy + bend + contour
        }

        func ring(at index: Int) -> Ring {
            let index = min(TorusGeometry.ringCount - 1, max(0, index))
            let position = TorusGeometry.positions[index]
            let energy = min(1, max(0, index < frame.bands.count ? frame.bands[index] : 0))
            let texture = CGFloat(BreathingNoise.value(frame.time * 0.16 + Double(index) * 0.085)) * motion
            let profile = TorusGeometry.ringProfile(
                energy: energy, relief: relief, level: level, breath: breath,
                texture: texture, envelope: position.envelope)
            let stretch: CGFloat = effectivePull < 0 && upwardAlignment > 0
                ? 1 : 1 + 0.10 * tension * position.envelope
            let x = cx + (position.progress - 0.5) * bar
            let progress = (x - leftRail) / max(1, rightRail - leftRail)
            let slope = TorusGeometry.stringSlope(
                progress: progress, anchor: anchor,
                pull: effectivePull, width: rightRail - leftRail)
            return Ring(
                center: CGPoint(x: x, y: stringY(at: x)),
                radiusX: min(size.width * (0.011 + 0.009 * position.envelope) / stretch,
                             bar / CGFloat(TorusGeometry.ringCount - 1) * (1 - longStretch * 0.60)),
                radiusY: baseRy * profile.radius * stretch * (1 - longStretch * 0.68),
                rotation: min(0.50, max(-0.50, atan(slope))) * (1 - upwardAlignment) + atan(slope) * upwardAlignment,
                opacity: profile.opacity
            )
        }
    }

    static func projectedPull(_ pull: CGFloat, height: CGFloat, baseRadius: CGFloat) -> CGFloat {
        // 留足完整环半径、纹理与描边预算；高速弹簧过冲也不能越过 Canvas。
        let budget = max(1, height / 2 - baseRadius - 12)
        return budget * tanh(pull / budget)
    }

    static func stringDisplacement(progress: CGFloat, anchor: CGFloat, pull: CGFloat) -> CGFloat {
        guard progress > 0, progress < 1 else { return 0 }
        let anchor = clampedAnchor(anchor)
        let distance = progress <= anchor ? progress / anchor : (1 - progress) / (1 - anchor)
        // 两端固定，受力点两侧连续光滑展开，而不是局部凹陷或整体平移。
        return pull * sin(distance * .pi / 2)
    }

    static func stringSlope(progress: CGFloat, anchor: CGFloat, pull: CGFloat, width: CGFloat) -> CGFloat {
        let anchor = clampedAnchor(anchor)
        let left = progress <= anchor
        let span = left ? anchor : 1 - anchor
        let distance = left ? progress / span : (1 - progress) / span
        let direction: CGFloat = left ? 1 : -1
        return direction * pull * .pi / (2 * span * max(1, width)) * cos(distance * .pi / 2)
    }
}

/// 中心主图：一条会随声音振动、也能被手指拨动的弦，44 个圆环穿在弦上。
/// 频段塑形，响度仅增加少量 presence/亮度；手势与解析弹簧共用显示时钟。
struct TorusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: SpectrumStore
    @ObservedObject private var motionStore: StringMotionStore
    var dimmed: Bool
    var instrumentHUD: Bool
    var channelLabel: String
    var viewportFrame: CGRect?

    init(store: SpectrumStore, dimmed: Bool = false,
         instrumentHUD: Bool = false, channelLabel: String = "CH 01", viewportFrame: CGRect? = nil) {
        self.store = store
        self.motionStore = store.stringMotion
        self.dimmed = dimmed
        self.instrumentHUD = instrumentHUD
        self.channelLabel = channelLabel
        self.viewportFrame = viewportFrame
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            var drawingContext = context
            if let frame = viewportFrame {
                drawingContext.translateBy(x: frame.minX, y: frame.minY)
                draw(context: drawingContext, size: frame.size)
            } else { draw(context: drawingContext, size: size) }
        }
        .accessibilityHidden(true)
        .onAppear {
            store.configureAmbientMotion(enabled: instrumentHUD, reducedMotion: reduceMotion)
            store.setVisible(scenePhase == .active)
        }
        .onDisappear { store.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in store.setVisible(phase == .active) }
        .onChange(of: reduceMotion) { _, reduced in
            store.configureAmbientMotion(enabled: instrumentHUD, reducedMotion: reduced)
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let layout = TorusGeometry.Layout(
            size: size, frame: store.frame, pull: motionStore.pull,
            anchor: motionStore.anchor, reducedMotion: reduceMotion, extendedUpward: viewportFrame != nil,
            upwardTravel: motionStore.upwardTravel ?? viewportFrame.map { max(1, $0.midY - 84) })
        let cx = layout.cx
        let cy = layout.cy
        let level = layout.level
        let relief = layout.relief
        let bar = layout.bar
        let baseRy = layout.baseRy
        // Align both rails and every tick to physical pixels, including the canvas offset.
        let origin = viewportFrame?.origin ?? .zero
        func snap(_ value: CGFloat, origin: CGFloat) -> CGFloat {
            ((value + origin) * displayScale).rounded() / displayScale - origin
        }
        let leftRail = snap(layout.leftRail, origin: origin.x)
        let rightRail = snap(layout.rightRail, origin: origin.x)
        let rulerTop = snap(layout.rulerTop, origin: origin.y)
        let rulerBottom = snap(layout.rulerBottom, origin: origin.y)
        let railWidth = 2 / displayScale
        let color = dimmed ? Theme.muted : Theme.orange
        let charge = dimmed ? 0 : store.ink.chargeGlow
        // The ambient clock slows to rest after the idle hold; actual gestures stay live.
        let phase = reduceMotion ? CGFloat(0.28)
            : CGFloat(store.frame.time.truncatingRemainder(dividingBy: 6) / 6)
        let hudMotion = instrumentHUD && !reduceMotion && !dimmed
        let ambient = hudMotion ? store.frame.ambientIntensity : 0

        // 左右标尺，不再画中间横线；横线由真正的弦代替。
        var ruler = Path()
        for x in [leftRail, rightRail] {
            ruler.move(to: CGPoint(x: x, y: rulerTop))
            ruler.addLine(to: CGPoint(x: x, y: rulerBottom))
            for y in [rulerTop, rulerBottom] {
                ruler.move(to: CGPoint(x: x - 2.5, y: y))
                ruler.addLine(to: CGPoint(x: x + 2.5, y: y))
            }
        }
        context.stroke(ruler, with: .color(color.opacity(0.48)), lineWidth: railWidth)
        if instrumentHUD {
            for side in 0..<2 {
                let x = side == 0 ? leftRail : rightRail
                let center = snap(cy, origin: origin.y)
                let count = Int(floor(min(center - rulerTop, rulerBottom - center) / 10))
                for ordinal in -count...count where ordinal != 0 {
                    let y = center + CGFloat(ordinal) * 10
                    guard y > rulerTop + 5, y < rulerBottom - 5 else { continue }
                    let major = abs(ordinal) % 5 == 0
                    let length: CGFloat = major ? 7 : 4
                    let left = side == 0 ? x : x - length
                    // Filled two-pixel marks have identical coverage, avoiding varying blur.
                    context.fill(Path(CGRect(x: left, y: y - railWidth / 2,
                                             width: length, height: railWidth)),
                                 with: .color(color.opacity(major ? 0.48 : 0.30)))
                }
            }
        }

        // 上下轨道沿同一固定端弦形弯曲，不能再整块平移。
        var context = context
        context.opacity *= motionStore.clearOpacity
        let orbitHeight = layout.orbitHeight * (1 - layout.longStretch * 0.94)
        for offset in [CGFloat(-0.62), CGFloat(0.62)] {
            let separation = offset * baseRy * (0.72 + 0.28 * relief.presence) * (1 - layout.longStretch * 0.94)
            var path = Path()
            for (index, sample) in TorusGeometry.orbitSamples.enumerated() {
                let x = cx + sample.x * bar / 2
                let point = CGPoint(x: x, y: layout.stringY(at: x) + separation + sample.y * orbitHeight / 2)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.stroke(path, with: .color(color.opacity(0.26)), lineWidth: 0.7)
            if ambient > 0 {
                let angle = phase * .pi * 2 * (offset < 0 ? 1 : -1)
                var glint = Path()
                for sample in 0...9 {
                    let a = angle + CGFloat(sample) * 0.006
                    let x = cx + cos(a) * bar / 2
                    let point = CGPoint(x: x, y: layout.stringY(at: x) + separation + sin(a) * orbitHeight / 2)
                    if sample == 0 { glint.move(to: point) } else { glint.addLine(to: point) }
                }
                context.stroke(glint, with: .color(Theme.orange.opacity(0.72 * ambient)), lineWidth: 1.25)
            }
        }

        // 圆环展示当前频谱，峰谷控制半径；线宽永远固定 1.3pt。
        for index in 0..<TorusGeometry.ringCount {
            let ring = layout.ring(at: index)
            let ink = dimmed ? 0 : store.ink.intensity(at: index)
            let distance = CGFloat(index) / CGFloat(TorusGeometry.ringCount - 1) - phase
            let scan = exp(-distance * distance / 0.004) * 0.20 * ambient
            let opacity = min(1, ring.opacity + (instrumentHUD ? 0.12 : 0)
                              + (1 - ring.opacity) * ink * 0.82 + scan)
            var ringContext = context
            ringContext.translateBy(x: ring.center.x, y: ring.center.y)
            ringContext.rotate(by: .radians(Double(ring.rotation)))
            let path = Path(ellipseIn: CGRect(
                x: -ring.radiusX, y: -ring.radiusY,
                width: ring.radiusX * 2, height: ring.radiusY * 2))
            ringContext.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 1.3)

            // 暖白只落在短弧上；不把蓄力扩成整图泛白或背景辉光。
            let accent = reduceMotion || dimmed ? 0 : store.ink.accent(at: index)
            if accent > 0.01 {
                var highlight = Path()
                for sample in 0...8 {
                    let angle = -CGFloat.pi / 2 - 0.28 + CGFloat(sample) * 0.07
                    let point = CGPoint(x: cos(angle) * ring.radiusX, y: sin(angle) * ring.radiusY)
                    if sample == 0 { highlight.move(to: point) } else { highlight.addLine(to: point) }
                }
                ringContext.stroke(
                    highlight, with: .color(Theme.ivory.opacity(accent * 0.68)), lineWidth: 1.3)
            }

            // Reawaken every retained landing, not the three short-lived impact slots.
            // One batched path per ring keeps dense transcripts from stacking white flashes.
            if charge > 0.001, store.ink.contactCount(at: index) > 0 {
                var chargedContacts = Path()
                for slot in 0..<store.ink.contactCount(at: index) {
                    guard let contact = store.ink.contact(at: index, slot: slot) else { continue }
                    chargedContacts.move(to: CGPoint(
                        x: contact.start.x * ring.radiusX, y: contact.start.y * ring.radiusY))
                    chargedContacts.addQuadCurve(
                        to: CGPoint(x: contact.end.x * ring.radiusX, y: contact.end.y * ring.radiusY),
                        control: CGPoint(x: contact.control.x * ring.radiusX, y: contact.control.y * ring.radiusY))
                }
                ringContext.stroke(chargedContacts, with: .color(Theme.orange.opacity(charge * 0.18)),
                                   style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                ringContext.stroke(chargedContacts, with: .color(Theme.ivory.opacity(charge * 0.62)),
                                   style: StrokeStyle(lineWidth: 1.45, lineCap: .round))
            }

            if !reduceMotion, !dimmed {
                for slot in 0..<WaveformInkStore.impactSlotsPerRing {
                    guard let impact = store.ink.impact(at: index, slot: slot) else { continue }
                    let intensity = impact.intensity
                    var contact = Path()
                    for sample in 0...8 {
                        let angle = impact.angle - impact.halfWidth
                            + CGFloat(sample) * impact.halfWidth / 4
                        let point = CGPoint(x: cos(angle) * ring.radiusX, y: sin(angle) * ring.radiusY)
                        if sample == 0 { contact.move(to: point) } else { contact.addLine(to: point) }
                    }
                    ringContext.stroke(contact, with: .color(Theme.orange.opacity(intensity * 0.32)),
                                       style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    ringContext.stroke(contact, with: .color(Theme.ivory.opacity(intensity * 0.95)),
                                       style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                    let progress = min(1, impact.age / WaveformInkStore.impactLifetime)
                    let reach = 3 + 10 * progress * (2 - progress)
                    let center = CGPoint(x: impact.unit.dx * ring.radiusX, y: impact.unit.dy * ring.radiusY)
                    var sparks = Path()
                    for side in 0..<2 {
                        let direction: CGFloat = side == 0 ? -1 : 1
                        sparks.move(to: CGPoint(
                            x: center.x + impact.unit.dx * direction * (2 + progress * 4),
                            y: center.y + impact.unit.dy * direction * (2 + progress * 4)))
                        sparks.addLine(to: CGPoint(
                            x: center.x + impact.unit.dx * direction * reach,
                            y: center.y + impact.unit.dy * direction * reach))
                    }
                    ringContext.stroke(sparks, with: .color(Theme.ivory.opacity(intensity * 0.8)),
                                       style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            }
        }

        // A fine structural spine; the rings, not a glowing travelling wave, are the hero.
        var stringPath = Path()
        var first = true
        var x = leftRail
        while x < rightRail {
            let point = CGPoint(x: x, y: layout.stringY(at: x))
            if first {
                stringPath.move(to: point)
                first = false
            } else {
                stringPath.addLine(to: point)
            }
            x += 2
        }
        stringPath.addLine(to: CGPoint(x: rightRail, y: layout.stringY(at: rightRail)))
        let stringBoost = motionStore.armed ? 1.0 : (0.35 + 0.65 * level)
        context.stroke(stringPath, with: .color(color.opacity(0.08 + 0.10 * stringBoost)), lineWidth: 3)
        context.stroke(stringPath, with: .color(color.opacity(0.38 + 0.40 * stringBoost)), lineWidth: 0.8)

        // 两个连接点始终钉在标尺中线，不随声音、拖动或弹簧余振移动。
        for point in [
            CGPoint(x: leftRail, y: cy),
            CGPoint(x: rightRail, y: cy)
        ] {
            context.fill(
                Path(CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)),
                with: .color(color)
            )
        }
        for point in [
            CGPoint(x: leftRail, y: rulerTop),
            CGPoint(x: rightRail, y: rulerTop),
            CGPoint(x: leftRail, y: rulerBottom),
            CGPoint(x: rightRail, y: rulerBottom)
        ] {
            context.fill(
                Path(CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)),
                with: .color(color)
            )
        }

        if instrumentHUD {
            let labelColor = Theme.muted.opacity(dimmed ? 0.5 : 1)
            for (label, x, y, anchor) in [
                ("RX / 01", leftRail + 10, rulerTop - 14, UnitPoint.leading),
                (channelLabel, rightRail - 10, rulerTop - 14, UnitPoint.trailing),
                ("44 BANDS", leftRail + 10, rulerBottom + 14, UnitPoint.leading),
                ("16 kHz", rightRail - 10, rulerBottom + 14, UnitPoint.trailing)
            ] {
                context.draw(Text(label).font(.system(size: 8, weight: .regular, design: .monospaced))
                    .foregroundStyle(label == channelLabel && !dimmed ? Theme.orange.opacity(0.7) : labelColor),
                             at: CGPoint(x: x, y: y), anchor: anchor)
            }
        } else {
            context.draw(
                Text("FFT · 44 BANDS · 16 kHz")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.muted.opacity(dimmed ? 0.5 : 1)),
                at: CGPoint(x: cx, y: rulerBottom + 14),
                anchor: .center
            )
            context.draw(
                Text("RX 01")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.muted.opacity(dimmed ? 0.5 : 1)),
                at: CGPoint(x: cx, y: rulerTop - 12),
                anchor: .center
            )
        }
    }
}

