import AVFoundation
import CoreMediaIO
import Foundation

// Record a USB-connected iPhone's screen (the same source QuickTime uses) to a movie file.
//
//   site-demo-iphone-capture <out.mov> [--list]
//
// Prints "Recording started" once frames are being written. Stops on SIGINT or SIGTERM.
// macOS treats the iPhone screen as a camera source, so the first run asks for camera
// access; only the user can grant it.

let arguments = CommandLine.arguments
var property = CMIOObjectPropertyAddress(
    mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
var allow: UInt32 = 1
CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil,
                          UInt32(MemoryLayout<UInt32>.size), &allow)

func screenDevice() -> AVCaptureDevice? {
    // Screen capture devices are muxed (screen + audio); Continuity Camera is video-only.
    AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        .devices.first
}

var device: AVCaptureDevice?
// The screen source shows up only after the run loop processes device notifications.
for _ in 0..<80 {
    device = screenDevice()
    if device != nil { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}
if arguments.contains("--list") {
    print(device.map { "\($0.localizedName) | \($0.modelID)" } ?? "no iPhone screen device (connect it with a USB cable and unlock it)")
    exit(device == nil ? 1 : 0)
}
guard arguments.count >= 2, let device else {
    FileHandle.standardError.write(Data("no iPhone screen device: connect it with a USB cable and unlock it\n".utf8))
    exit(2)
}

let semaphore = DispatchSemaphore(value: 0)
var granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
if !granted {
    AVCaptureDevice.requestAccess(for: .video) { ok in granted = ok; semaphore.signal() }
    semaphore.wait()
}
guard granted else {
    FileHandle.standardError.write(Data("camera access was not granted\n".utf8))
    exit(3)
}

/// Writes every arriving frame stamped with the Mac's host clock at arrival. The capture
/// source's own timestamps skip stretches where the iPhone screen does not change, which
/// would squeeze the timeline unevenly; arrival time keeps it real.
final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let queue = DispatchQueue(label: "capture")
    let url: URL
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    var stopping = false
    var frames = 0
    init(url: URL) { self.url = url }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopping, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if writer == nil {
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000,
                                                  AVVideoAllowFrameReorderingKey: false,
                                                  AVVideoExpectedSourceFrameRateKey: 60]])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.startWriting()
            writer.startSession(atSourceTime: now)
            self.writer = writer; self.input = input
            print("Recording started \(String(format: "%.6f", Date().timeIntervalSince1970)) \(width)x\(height)")
            fflush(stdout)
        }
        if input?.isReadyForMoreMediaData == true, adaptor?.append(pixels, withPresentationTime: now) == true {
            frames += 1
        }
    }

    func stop() {
        queue.async {
            self.stopping = true
            self.session.stopRunning()
            guard let writer = self.writer else { exit(0) }
            self.input?.markAsFinished()
            writer.finishWriting {
                FileHandle.standardError.write(Data("wrote \(self.frames) frames\n".utf8))
                exit(writer.status == .completed ? 0 : 5)
            }
        }
    }
}

let recorder = Recorder(url: URL(fileURLWithPath: arguments[1]))
try? FileManager.default.removeItem(at: recorder.url)
do {
    let input = try AVCaptureDeviceInput(device: device)
    recorder.session.beginConfiguration()
    recorder.output.alwaysDiscardsLateVideoFrames = false
    recorder.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    recorder.output.setSampleBufferDelegate(recorder, queue: recorder.queue)
    guard recorder.session.canAddInput(input), recorder.session.canAddOutput(recorder.output) else { exit(4) }
    recorder.session.addInput(input)
    recorder.session.addOutput(recorder.output)
    recorder.session.commitConfiguration()
} catch {
    FileHandle.standardError.write(Data("cannot open \(device.localizedName): \(error)\n".utf8)); exit(4)
}
recorder.session.startRunning()
// Frames only arrive when the iPhone screen changes; report readiness as soon as the
// session runs so the caller does not wait on a still screen.
print("Capture ready \(String(format: "%.6f", Date().timeIntervalSince1970))")
fflush(stdout)

var signalSources: [DispatchSourceSignal] = []   // kept alive for the whole run
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { recorder.stop() }
    source.resume()
    signalSources.append(source)
}
dispatchMain()
