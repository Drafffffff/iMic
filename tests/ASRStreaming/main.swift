import Foundation
import XCTest

private final class RecognitionTransport: ASRMessageTransport {
    private var receiver: ((Result<Data, Error>) -> Void)?
    private(set) var taskID = ""
    func resume() {}
    func send(_ message: ASRWireMessage, completion: @escaping (Error?) -> Void) {
        if case .text(let text) = message,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let header = object["header"] as? [String: Any],
           let id = header["task_id"] as? String { taskID = id }
        completion(nil)
    }
    func receive(completion: @escaping (Result<Data, Error>) -> Void) { receiver = completion }
    // Retain a queued receive so cancellation is exercised against an in-flight callback.
    func cancel() {}
    func event(_ event: String, sentence: [String: Any]? = nil, task: String? = nil) throws {
        var object: [String: Any] = ["header": ["task_id": task ?? taskID, "event": event]]
        if let sentence { object["payload"] = ["output": ["sentence": sentence]] }
        let data = try JSONSerialization.data(withJSONObject: object)
        let callback = receiver
        receiver = nil
        callback?(.success(data))
    }
    func fail(_ error: Error) { let callback = receiver; receiver = nil; callback?(.failure(error)) }
    func serviceFailure(_ code: String) throws {
        let value: [String: Any] = ["header": ["task_id": taskID, "event": "task-failed", "error_code": code,
            "error_message": "sensitive service detail must not reach UI"]]
        let callback = receiver; receiver = nil
        callback?(.success(try JSONSerialization.data(withJSONObject: value)))
    }
    func sentence(_ id: Int, _ text: String, ended: Bool, heartbeat: Bool = false, task: String? = nil) throws {
        try event("result-generated", sentence: ["sentence_id": id, "text": text, "sentence_end": ended, "heartbeat": heartbeat], task: task)
    }
}

final class ASRStreamingTests: XCTestCase {
    private var transport: RecognitionTransport!
    private var recognizer: BailianASR!
    private var confirmed: [String] = []
    private var previews: [String] = []
    private var finals: [String] = []
    private var failures: [String] = []

    override func setUpWithError() throws {
        transport = RecognitionTransport()
        recognizer = BailianASR(transportFactory: { [transport = transport!] _ in transport })
        recognizer.previewEnabled = true
        recognizer.onConfirmed = { [weak self] in self?.confirmed.append($0) }
        recognizer.onPreview = { [weak self] in self?.previews.append($0) }
        recognizer.onFinal = { [weak self] text, _ in self?.finals.append(text) }
        recognizer.onError = { [weak self] in self?.failures.append($0) }
        recognizer.start(key: "sk-isolated-test", endpoint: "wss://dashscope.aliyuncs.com/api-ws/v1/inference", model: ASRConfiguration.model)
        try transport.event("task-started")
        guard failures.isEmpty else {
            throw NSError(domain: "ASRStreamingFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }
    override func tearDown() { recognizer.cancel() }
    private func finish() throws {
        recognizer.end()
        try transport.event("task-finished")
    }

    func testTransportFailuresCarryActionableReasonsWithoutServiceBody() throws {
        var issue: CloudFailure?
        recognizer.onFailure = { issue = $0 }
        transport.fail(NSError(domain: "iMic.ASR.HTTP", code: 401))
        XCTAssertEqual(issue, .key)
        XCTAssertEqual(failures, [BailianIssue.invalidKey.message])
        XCTAssertTrue(finals.isEmpty)
    }
    func testNetworkFailureIsRetryableWithoutRetainingAudio() throws {
        var issue: CloudFailure?
        recognizer.onFailure = { issue = $0 }
        transport.fail(URLError(.notConnectedToInternet))
        XCTAssertEqual(issue, .network)
        XCTAssertEqual(failures, [BailianIssue.network.message])
        XCTAssertTrue(finals.isEmpty)
    }
    func testRegionOrModelFailureOffersAddressCheckAndRedactsBody() throws {
        var issue: CloudFailure?
        recognizer.onFailure = { issue = $0 }
        try transport.serviceFailure("ModelNotFound")
        XCTAssertEqual(issue, .bailian(.permission))
        XCTAssertFalse(failures.joined().contains("sensitive"))
    }
    func testRuntimeCodesShareOnboardingMessages() throws {
        // Each test fixture owns an injected transport; these never open a socket.
        for (code, expected) in [("Arrearage", BailianIssue.billing), ("AccessDenied.IPRestriction", .ip),
                                 ("Model.AccessDenied", .permission), ("AllocationQuota.FreeTierOnly", .billing),
                                 ("Workspace.AccessDenied", .workspace)] {
            let fake = RecognitionTransport()
            let asr = BailianASR(transportFactory: { _ in fake })
            var reason = ""
            asr.onError = { reason = $0 }
            asr.start(key: "sk-isolated-test", endpoint: ASRConfiguration.defaultEndpoint, model: ASRConfiguration.model)
            try fake.serviceFailure(code)
            XCTAssertEqual(reason, expected.message)
        }
    }
    func testUnsafeRecognitionEndpointsNeverCreateTransport() {
        for endpoint in ["wss://evil.example/api-ws/v1/inference", "wss://token-plan.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference", "wss://dashscope.aliyuncs.com:444/api-ws/v1/inference", "wss://user@dashscope.aliyuncs.com/api-ws/v1/inference"] {
            let asr = BailianASR(transportFactory: { _ in XCTFail("Must not send Key to unsafe host"); return RecognitionTransport() })
            asr.start(key: "sk-isolated-test", endpoint: endpoint, model: ASRConfiguration.model)
        }
    }
    func testInterimCorrectionsStayDisplayOnlyUntilSentenceEnds() throws {
        try transport.sentence(1, "明天上午", ended: false)
        try transport.sentence(1, "明天下午三点开会", ended: false)
        XCTAssertEqual(previews, ["明天上午", "明天下午三点开会"])
        XCTAssertEqual(confirmed, [])
        XCTAssertEqual(finals, [])
        try transport.sentence(1, "明天下午三点开会。", ended: true)
        XCTAssertEqual(confirmed, ["明天下午三点开会。"])
        XCTAssertEqual(finals, [])
        try finish()
        XCTAssertEqual(finals, ["明天下午三点开会。"])
    }
    func testMissingSentenceHoldsLaterCompletionAndFlushesInOrder() throws {
        try transport.sentence(3, "第三句。", ended: true)
        XCTAssertEqual(confirmed, [])
        try transport.sentence(1, "第一句。", ended: true)
        try transport.sentence(3, "迟到临时第三句", ended: false)
        XCTAssertEqual(confirmed, ["第一句。"])
        XCTAssertEqual(previews.last, "第一句。")
        try transport.sentence(2, "第二句。", ended: true)
        try transport.sentence(2, "第二句。", ended: true)
        XCTAssertEqual(confirmed, ["第一句。", "第一句。第二句。第三句。"])
        try finish()
        XCTAssertEqual(finals, ["第一句。第二句。第三句。"])
    }
    func testCompletedCorrectionRebuildsPrefixWithoutReplayingOldInterim() throws {
        try transport.sentence(1, "明天上午，", ended: true)
        try transport.sentence(2, "三点开会。", ended: true)
        try transport.sentence(1, "已经过期的临时文字", ended: false)
        try transport.sentence(1, "明天下午，", ended: true)
        XCTAssertEqual(confirmed, ["明天上午，", "明天上午，三点开会。", "明天下午，三点开会。"])
        XCTAssertEqual(previews.last, "明天下午，三点开会。")
        try finish()
        XCTAssertEqual(finals, ["明天下午，三点开会。"])
    }
    func testOtherTasksAndHeartbeatsNeverReachCurrentTranscript() throws {
        try transport.sentence(1, "别的会话", ended: true, task: "obsolete-task")
        try transport.sentence(1, "心跳内容", ended: true, heartbeat: true)
        try transport.sentence(1, "当前会话。", ended: true)
        XCTAssertEqual(confirmed, ["当前会话。"])
        try finish()
        XCTAssertEqual(finals, ["当前会话。"])
    }
    func testCancellationRejectsQueuedCompletion() throws {
        try transport.sentence(1, "未完成文字", ended: false)
        recognizer.cancel()
        try transport.sentence(1, "取消后的迟到句子。", ended: true)
        XCTAssertEqual(previews, ["未完成文字"])
        XCTAssertEqual(confirmed, [])
        XCTAssertEqual(finals, [])
        XCTAssertEqual(failures, [])
    }
    func testOversizedCompletionFailsBeforeAnyTextCanBeCommitted() throws {
        try transport.sentence(1, String(repeating: "字", count: 24_001), ended: true)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(confirmed, [])
        XCTAssertEqual(finals, [])
    }
}

let suite = XCTestSuite(forTestCaseClass: ASRStreamingTests.self)
suite.run()
guard let result = suite.testRun, result.executionCount > 0 else { fatalError("未发现识别流行为测试") }
exit(result.totalFailureCount == 0 ? 0 : 1)
