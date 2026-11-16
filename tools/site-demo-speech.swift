import AVFoundation
import Foundation

// Speak each demo utterance with the zh-CN system voice and write 16 kHz mono 16-bit PCM,
// the format the app's SpectrumAnalyzer reads from the microphone path.
//
//   site-demo-speech <DemoScript.swift> <out-dir>
//
// Sentences are read from DemoScript.swift (single source of truth), one file per
// utterance: <scene>-<index>.pcm. The capture script copies them into the app container.

let args = CommandLine.arguments
guard args.count >= 3, let source = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: site-demo-speech <DemoScript.swift> <out-dir>\n".utf8)); exit(2)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// case "scene": return [Utterance(live: "...", final: "..."), ...]
var scenes: [(String, [String])] = []
let casePattern = try! NSRegularExpression(pattern: #"case "([a-z]+)":\s*return \[(.*?)\]\s*\n"#, options: [.dotMatchesLineSeparators])
let livePattern = try! NSRegularExpression(pattern: #"live: "([^"]+)""#)
let ns = source as NSString
for match in casePattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
    let scene = ns.substring(with: match.range(at: 1))
    let body = ns.substring(with: match.range(at: 2)) as NSString
    let lives = livePattern.matches(in: body as String, range: NSRange(location: 0, length: body.length))
        .map { body.substring(with: $0.range(at: 1)) }
    scenes.append((scene, lives))
}

let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
for (scene, lives) in scenes {
    for (index, text) in lives.enumerated() {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.56
        var output = Data()
        var converter: AVAudioConverter?
        var finished = false
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finished = true; return }
            if converter == nil { converter = AVAudioConverter(from: pcm.format, to: target) }
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * 16_000 / pcm.format.sampleRate) + 32
            guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            converter.convert(to: converted, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return pcm
            }
            if let samples = converted.int16ChannelData {
                output.append(Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while !finished, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let url = outDir.appendingPathComponent("\(scene)-\(index).pcm")
        try? output.write(to: url)
        print(String(format: "%@-%d: %.2fs %@", scene, index, Double(output.count) / 32_000, text))
    }
}
