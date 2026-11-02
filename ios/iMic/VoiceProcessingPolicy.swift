import Foundation

/// A new key intentionally ignores the diagnostic build's micDebug.voiceProcessing.
enum VoiceProcessingPreference {
    static let key = "imic.audio.voiceProcessing.enabled"
    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

enum CaptureLevel: String {
    case unavailable, allZero, lowLevel, normal
    static func classify(_ meter: CaptureMeter) -> Self {
        guard meter.hasSamples, meter.callbacks > 0 else { return .unavailable }
        if meter.allZero { return .allZero }
        return meter.rms < 0.001 && meter.peak < 0.003 ? .lowLevel : .normal
    }
}

/// Uses only time belonging to the current hold. Once speech-level input has
/// appeared, a later pause cannot trigger the low-level fallback in that hold.
struct CaptureLowLevelWatchdog {
    private var heardNormal = false
    private var duration: TimeInterval = 0
    mutating func observe(_ meter: CaptureMeter, interval: TimeInterval) -> Bool {
        switch CaptureLevel.classify(meter) {
        case .normal: heardNormal = true; duration = 0
        case .lowLevel, .allZero: duration += max(0, interval)
        case .unavailable: duration = 0
        }
        return !heardNormal && duration >= 1.5
    }
    mutating func restartMeasurement() { duration = 0 }
}

enum CaptureSessionMode { case voiceChat, measurement }

struct CaptureProcessingConfiguration {
    let voiceProcessing: Bool
    var mode: CaptureSessionMode { voiceProcessing ? .voiceChat : .measurement }
    // Keep the existing speaker route policy. Bluetooth options aren't added.
    let defaultToSpeaker = true
    let automaticGain = true
    let bypass = false
    let advancedDucking = false
}

/// Production startup uses this sequence too: VPIO can change native format, so
/// enabling it and setting its policies MUST precede reading/connecting format.
enum CaptureStartup {
    static func prepare<Format>(voiceProcessing: Bool,
        configureSession: (CaptureProcessingConfiguration) throws -> Void, activate: () throws -> Void,
        enableVoiceProcessing: () throws -> Void, configureProcessing: (CaptureProcessingConfiguration) -> Void,
        readFormat: () throws -> Format) throws -> Format {
        let configuration = CaptureProcessingConfiguration(voiceProcessing: voiceProcessing)
        try configureSession(configuration)
        try activate()
        if voiceProcessing {
            try enableVoiceProcessing()
            configureProcessing(configuration)
        }
        return try readFormat()
    }
}

/// View-local comparison state. It reads the preference once and never writes it.
struct MicrophoneTestProcessing {
    var enabled: Bool
    init(defaults: UserDefaults = .standard) { enabled = VoiceProcessingPreference.enabled(in: defaults) }
    mutating func toggle() { enabled.toggle() }
}
