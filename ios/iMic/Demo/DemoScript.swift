#if DEBUG
import Foundation

/// DEBUG-only scripted content for landing-page demo recordings (`--demo-script=<scene>`
/// together with `--ui-preview=idle`). Gestures still come from real touches; this only
/// supplies what a microphone and a Mac would: live words while holding, the final text
/// after release, and a timestamped event log the Mac demo window replays in sync.
@MainActor
final class DemoScript {
    static let shared = DemoScript()

    struct Utterance {
        let live: String     // what the live preview shows while holding
        let final: String    // what lands on the Mac after release (polished when different)
    }

    let scene: String?
    private var utterances: [Utterance] = []
    private var next = 0
    /// 16 kHz mono PCM of each utterance, spoken by the system voice. Fed through the same
    /// analyzer as the microphone so the waveform follows real speech.
    private(set) var speech: [Int: Data] = [:]
    var currentIndex: Int { min(next, max(0, utterances.count - 1)) }
    private let log: FileHandle?

    var active: Bool { scene != nil }
    /// Scenes that show the Mac polish sweep keep the phone in POLISH until it lands.
    var polishes: Bool { scene == "hero" || scene == "polish" }

    private init() {
        scene = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--demo-script=") }
            .map { String($0.dropFirst("--demo-script=".count)) }
        if let scene {
            utterances = Self.script(for: scene)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("demo-events.jsonl")
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            log = try? FileHandle(forWritingTo: url)
        } else {
            log = nil
        }
        record("launch", ["scene": scene ?? ""])
        if let scene { loadSpeech(scene) }
        if scene != nil {
            LinkClient.demoInputObserver = { action in
                Task { @MainActor in DemoScript.shared.record("input", ["action": action]) }
            }
        }
    }

    /// The utterance for the session that is starting.
    func beginUtterance() -> Utterance {
        let item = utterances.isEmpty ? Utterance(live: "示例文字", final: "示例文字。")
            : utterances[min(next, utterances.count - 1)]
        record("hold", [:])
        return item
    }

    func finishUtterance() -> Utterance {
        let item = utterances.isEmpty ? Utterance(live: "示例文字", final: "示例文字。")
            : utterances[min(next, utterances.count - 1)]
        next += 1
        return item
    }

    /// Wall-clock seconds so the capture script can align these with the recording start.
    /// Number of events so far; drawn as a tiny binary code in the screen corner so the
    /// capture can find each event's frame even though simulator recordings drift.
    private(set) var count = 0
    var onCount: ((Int) -> Void)?

    func record(_ event: String, _ fields: [String: String]) {
        guard let log else { return }
        count += 1
        onCount?(count)
        var object: [String: Any] = ["t": Date().timeIntervalSince1970, "event": event, "n": count]
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        log.write(Data((line + "\n").utf8))
    }

    /// Speech prepared on the Mac (tools/site-demo-speech.swift) and copied into
    /// Documents/demo-speech by the capture script; synthesize on device only as a fallback.
    private func loadSpeech(_ scene: String) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("demo-speech")
        var missing = false
        for index in utterances.indices {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("\(scene)-\(index).pcm")), data.count > 640 {
                speech[index] = data
                record("speech", ["index": "\(index)", "seconds": String(format: "%.2f", Double(data.count) / 32_000)])
            } else {
                missing = true
            }
        }
        if missing { synthesize(0) }
    }

    private func synthesize(_ index: Int) {
        guard index < utterances.count else { return }
        DebugSpeech.shared.synthesize(utterances[index].live, rate: 0.56) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data, self.speech[index] == nil { self.speech[index] = data }
                self.record("speech", ["index": "\(index)", "seconds": String(format: "%.2f", Double(data?.count ?? 0) / 32_000)])
                self.synthesize(index + 1)
            }
        }
    }

    private static func script(for scene: String) -> [Utterance] {
        switch scene {
        case "hero":
            return [Utterance(live: "嗯明天下午三点开会然后记得把原型带上",
                              final: "明天下午三点开会，记得带上原型。")]
        case "hold":
            return [Utterance(live: "把这周的设计稿整理一下发给我",
                              final: "把这周的设计稿整理一下发给我。")]
        case "string":
            return [Utterance(live: "今天下午三点开会讨论动画细节",
                              final: "今天下午三点开会，讨论动画细节。"),
                    Utterance(live: "好的收到", final: "好的，收到。")]
        case "live":
            return [Utterance(live: "我们先把首页的动效定下来然后周五之前给出两个方案",
                              final: "我们先把首页的动效定下来，然后周五之前给出两个方案。")]
        case "polish":
            return [Utterance(live: "嗯那个我想说一下下午三点开会然后讨论一下动画细节吧",
                              final: "下午三点开会，讨论动画细节。")]
        case "sound":
            return [Utterance(live: "这是一条测试消息", final: "这是一条测试消息。")]
        default:
            return []
        }
    }
}
#endif
