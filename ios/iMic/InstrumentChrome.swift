import SwiftUI

/// Small, consistent captions keep the instrument and its primary action in focus.
struct HUDLabel: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .regular, design: .monospaced))
            .tracking(0.35)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct InstrumentHint: ViewModifier {
    var color: Color = Theme.muted
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .regular))
            .tracking(0.2)
            .foregroundStyle(color)
    }
}

struct PixelSymbol: View {
    enum Kind { case settings, microphone, computer, check, up, sideways, clear, cancel }
    let kind: Kind
    var color: Color = Theme.ivory

    private static let settings = [
        "000001111100000", "000001111100000", "001110111011100",
        "001111111111100", "000111000111000", "111110000011111",
        "111100000001111", "111100000001111", "111100000001111",
        "111110000011111", "000111000111000", "001111111111100",
        "001110111011100", "000001111100000", "000001111100000"
    ]
    private static let microphone = [
        "0011100", "0100010", "0100010", "0100010", "0100010", "0100010",
        "0011100", "1000001", "0100010", "0011100", "0001000", "0011100"
    ]

    var body: some View {
        Canvas { context, size in
            let rows: [String]
            switch kind {
            case .settings: rows = Self.settings
            case .microphone: rows = Self.microphone
            case .computer: rows = ["111111111", "100000001", "100000001", "100000001", "111111111", "000010000", "001111100"]
            case .check: rows = ["0000001", "0000010", "1000100", "0101000", "0010000"]
            case .up: rows = ["0001000", "0011100", "0101010", "1001001", "0001000", "0001000", "0001000"]
            case .sideways: rows = ["0010100", "0100010", "1111111", "0100010", "0010100"]
            case .clear: rows = ["1111111", "0000000", "0001000", "0011100", "0101010", "0001000", "0001000"]
            case .cancel: rows = ["1000001", "0100010", "0010100", "0001000", "0010100", "0100010", "1000001"]
            }
            let columns = rows.first?.count ?? 1
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows.count))
            let left = (size.width - CGFloat(columns) * cell) / 2
            let top = (size.height - CGFloat(rows.count) * cell) / 2
            var pixels = Path()
            for (row, bits) in rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit == "1" {
                    pixels.addRect(CGRect(x: left + CGFloat(column) * cell,
                                          y: top + CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(pixels, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// One layout for the hold bar, shared by the Metal artwork and the native fallback.
/// The accessory (microphone, link or elapsed time) owns a fixed zone on the right whose
/// left edge carries the separator, so neither the label nor the timer can cross it.
enum HoldBarLayout {
    static let height: CGFloat = 68
    static let leading: CGFloat = 28
    static let accessoryWidth: CGFloat = 60
    static let labelGap: CGFloat = 16
    static let labelTracking: CGFloat = 1.8
    static let separatorHeight: CGFloat = 24
    static let tickHeight: CGFloat = 20
    static let wordmark = CGSize(width: 76, height: 22)

    static func labelWidth(barWidth: CGFloat) -> CGFloat {
        max(80, barWidth - leading - accessoryWidth - labelGap)
    }
}

/// The line above the bar: label, a rule that keeps clear of both ends, and a right slot
/// that shows a transient notice in place of the hint instead of a box floating over it.
struct HoldBarRail: View {
    var notice: String?
    var noticeColor: Color = Theme.muted

    var body: some View {
        HStack(spacing: 10) {
            HUDLabel(text: "TX / VOICE")
            Rectangle().fill(Theme.line).frame(height: 0.5).frame(maxWidth: .infinity)
            if let notice {
                Text(notice).font(.system(size: 10, weight: .regular)).foregroundStyle(noticeColor)
                    .lineLimit(1).fixedSize()
            } else {
                HUDLabel(text: "PRESS + HOLD", color: Theme.orange.opacity(0.7))
            }
        }
        .frame(height: 12)
    }
}

struct RecordingBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch: CGFloat = 8
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + notch))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + notch, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - notch))
            path.closeSubpath()
        }
    }
}

/// Observes the existing activity-driven clock; it never starts a timer of its own.
struct HUDDivider: View {
    @ObservedObject var store: SpectrumStore
    var connected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let width = size.width
            var line = Path()
            line.move(to: CGPoint(x: 0, y: 9))
            line.addLine(to: CGPoint(x: width * 0.27, y: 9))
            line.addLine(to: CGPoint(x: width * 0.29, y: 3))
            line.addLine(to: CGPoint(x: width, y: 3))
            context.stroke(line, with: .color(Theme.line), lineWidth: 0.65)
            let opacity = reduceMotion ? 0.3
                : 0.24 + 0.12 * sin(store.frame.time * .pi / 3) * store.frame.ambientIntensity
            var signal = Path()
            signal.move(to: CGPoint(x: width * 0.67, y: 3))
            signal.addLine(to: CGPoint(x: width * 0.90, y: 3))
            context.stroke(signal, with: .color((connected ? Theme.orange : Theme.muted).opacity(opacity)), lineWidth: 0.7)
            context.fill(Path(CGRect(x: width - 4, y: 1, width: 4, height: 4)),
                         with: .color((connected ? Theme.orange : Theme.muted).opacity(0.7)))
        }
        .accessibilityHidden(true)
    }
}

/// The instrument's identity and status are shared by native UI and Metal artwork.
struct InstrumentIdentity: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image("Wordmark").renderingMode(.original).resizable().scaledToFit()
                .frame(width: HoldBarLayout.wordmark.width, height: HoldBarLayout.wordmark.height, alignment: .leading)
                .blendMode(.screen).accessibilityLabel("iMic")
            HUDLabel(text: "SYS 01")
        }
    }
}

struct InstrumentStatus: View {
    var label = "VOICE / INPUT"
    let word: String
    let description: String
    var detail: String? = nil
    var cell: CGFloat = 4.2
    var color: Color = Theme.orange
    var teaching = false
    var celebrating = false
    var body: some View {
        VStack(spacing: 0) {
            HUDLabel(text: label).padding(.bottom, 13)
            PixelText(text: word, cell: cell, color: color, tracking: 2.8)
                .modifier(PhosphorReadout(color: color)).frame(height: 30)
                .accessibilityElement(children: .ignore).accessibilityLabel(word)
            Text(description).modifier(InstrumentHint(color: teaching ? Theme.ivory : Theme.muted))
                .multilineTextAlignment(.center).lineSpacing(3)
                .frame(minHeight: 34, alignment: .top).fixedSize(horizontal: false, vertical: true).padding(.top, 13)
                .accessibilityIdentifier(teaching ? (celebrating ? "onboarding.complete" : "onboarding.prompt") : "home.status")
            if let detail {
                Text(detail).modifier(InstrumentHint()).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Square scan indicators use motion only while this loading state is visible.
struct PixelScan: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: reduceMotion || scenePhase != .active)) { timeline in
            let active = Int(timeline.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Rectangle().fill(Theme.orange.opacity(reduceMotion || index == active ? 1 : 0.25)).frame(width: 4, height: 4)
                }
            }
        }.accessibilityHidden(true)
    }
}
