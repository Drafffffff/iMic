import Foundation

enum ASRConfiguration {
    static let model="qwen-audio-3.1-asr-flash-message"
    static let defaultEndpoint="wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    private static let migrationKey="asrMessageProtocolVersion"
    static let finalResultTimeout: TimeInterval = 60
    static func uploadTimeout(audioSeconds: TimeInterval) -> TimeInterval {
        max(30, min(Double(IMicLink.maxSessionSeconds), max(0, audioSeconds)) * 2 + 15)
    }
    static var resourceTimeout: TimeInterval {
        Double(IMicLink.maxSessionSeconds) + 2 * uploadTimeout(audioSeconds: Double(IMicLink.maxSessionSeconds)) + finalResultTimeout + 15
    }

    // Preserve the configured region/workspace host and credentials. Message ASR
    // uses a different WebSocket path and a run-task payload, not ?model=.
    static func inferenceEndpoint(_ endpoint:String)->String {
        guard var parts=URLComponents(string:endpoint),parts.scheme=="wss",parts.host != nil else{return endpoint}
        if parts.path=="/api-ws/v1/realtime" {parts.path="/api-ws/v1/inference"}
        parts.queryItems=parts.queryItems?.filter{$0.name != "model"}
        if parts.queryItems?.isEmpty==true {parts.queryItems=nil}
        return parts.url?.absoluteString ?? endpoint
    }
    static func migrateDefaults(_ defaults:UserDefaults = .standard) {
        guard defaults.integer(forKey:migrationKey)<1 else{return}
        defaults.set(model,forKey:"asrModel")
        let endpoint=defaults.string(forKey:"asrEndpoint") ?? defaultEndpoint
        defaults.set(inferenceEndpoint(endpoint),forKey:"asrEndpoint")
        defaults.set(1,forKey:migrationKey)
    }
    static func current(_ defaults:UserDefaults = .standard)->(model:String,endpoint:String) {
        let endpoint=defaults.string(forKey:"asrEndpoint") ?? defaultEndpoint
        if defaults.integer(forKey:migrationKey)<1{return (model,inferenceEndpoint(endpoint))}
        return (defaults.string(forKey:"asrModel") ?? model,endpoint)
    }
}

struct ASRMetrics {
    var connectionMS:Double
    var queuedAtEndMS:Double
    var uploadTailMS:Double
    var serverFinalMS:Double
    var endToFinalMS:Double
    var previews:Int
}

enum ASRWireMessage {
    case text(String)
    case audio(Data)
}
protocol ASRMessageTransport:AnyObject {
    func resume()
    func send(_ message:ASRWireMessage,completion:@escaping (Error?)->Void)
    func receive(completion:@escaping (Result<Data,Error>)->Void)
    func cancel()
}
private final class ASRWebSocketTransport:ASRMessageTransport {
    private let session:URLSession
    private let socket:URLSessionWebSocketTask
    init(_ request:URLRequest) {
        let config=URLSessionConfiguration.ephemeral
        // WebSocket 可能长时间只上传音频；不能把单次 HTTP 的 15/90 秒用于整段任务。
        config.timeoutIntervalForRequest=ASRConfiguration.resourceTimeout
        config.timeoutIntervalForResource=ASRConfiguration.resourceTimeout
        session=URLSession(configuration:config)
        socket=session.webSocketTask(with:request)
    }
    func resume(){socket.resume()}
    func send(_ message:ASRWireMessage,completion:@escaping (Error?)->Void) {
        let frame:URLSessionWebSocketTask.Message
        switch message {case .text(let text):frame = .string(text);case .audio(let pcm):frame = .data(pcm)}
        socket.send(frame){error in DispatchQueue.main.async{completion(error)}}
    }
    func receive(completion:@escaping (Result<Data,Error>)->Void) {
        socket.receive{result in DispatchQueue.main.async {
            switch result {
            case .failure(let error):completion(.failure(error))
            case .success(let message):
                switch message {
                case .string(let text):completion(.success(Data(text.utf8)))
                case .data(let data):completion(.success(data))
                @unknown default:completion(.failure(NSError(domain:"iMic.ASR",code:1)))
                }
            }
        }}
    }
    func cancel(){socket.cancel(with:.normalClosure,reason:nil);session.invalidateAndCancel()}
}

final class BailianASR {
    // Interim hypotheses and confirmed prefixes are separate callbacks; the caller
    // chooses its preview/input policy. onFinal represents the complete utterance.
    var onPreview: ((String)->Void)?
    var onConfirmed: ((String)->Void)?
    var previewEnabled = false
    var onFinal: ((String,Double)->Void)?
    var onError: ((String)->Void)?
    var onMetrics: ((ASRMetrics)->Void)?
    private let transportFactory:(URLRequest)->ASRMessageTransport
    private var taskID=UUID().uuidString
    private var started=false
    private var startedAt=Date()
    private var readyAt:Date?
    private var finishAt:Date?
    private var queuedAtEndMS=0.0
    private var transport:ASRMessageTransport?
    private var queue: [Data] = []
    private var queueHead=0
    private var queueOffset=0
    private var queuedBytes=0
    private var sending=false
    private var ready=false
    private var ended=false
    private var cancelled=false
    private var finishSent=false
    private var endAt:Date?
    private var results:[Int:String]=[:]
    private var confirmedThrough = 0
    private var confirmedText = ""
    private var previewCount = 0
    private var timer:Timer?
    private var startupTimer:Timer?
    private var totalBytes=0
    /// audio.end 后先等上传，finish-task 送达后才进入最终识别期限。
    private(set) var completionDeadline:Date?

    // manual remains source-compatible with the old benchmark entry point.
    // Message ASR always aggregates VAD sentences until explicit end().
    init(manual:Bool=true,transportFactory:@escaping (URLRequest)->ASRMessageTransport = {ASRWebSocketTransport($0)}) {
        self.transportFactory=transportFactory
    }
    func start(key:String,endpoint:String,model:String) {
        guard !started,!cancelled else{return}
        started=true;startedAt=Date()
        guard !key.isEmpty else{fail("请先配置百炼 API Key");return}
        guard model==ASRConfiguration.model else{fail("识别模型请设置为 \(ASRConfiguration.model)");return}
        IMicLog.write("mac.asr", "start model=\(model)")
        guard let components=URLComponents(string:ASRConfiguration.inferenceEndpoint(endpoint)),
              components.scheme=="wss",components.host?.isEmpty==false,
              components.path=="/api-ws/v1/inference",let url=components.url else{
            fail("识别地址应为 wss:// 服务域名/api-ws/v1/inference");return
        }
        var request=URLRequest(url:url);request.timeoutInterval=ASRConfiguration.resourceTimeout
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        request.setValue("iMic/1.0",forHTTPHeaderField:"User-Agent")
        let transport=transportFactory(request);self.transport=transport
        transport.resume();receive()
        sending=true
        sendJSON(["header":header("run-task"),"payload":["task_group":"audio","task":"asr",
            "function":"recognition","model":model,"input":[:],
            "parameters":["format":"pcm","sample_rate":16000,"intermediate_result_enabled":false,
                "vad_model":"near_meeting_16k","heartbeat":true]]]){[weak self] error in
            guard let self=self,!self.cancelled else{return}
            self.sending=false
            if error != nil{self.fail("识别任务启动失败")}else{self.pump()}
        }
        if !cancelled && !ready {
            startupTimer=Timer.scheduledTimer(withTimeInterval:10,repeats:false){[weak self] _ in
                if self?.ready != true{self?.fail("百炼连接超时，请检查网络、Key、地域和模型")}
            }
        }
    }
    private func header(_ action:String)->[String:Any]{["action":action,"task_id":taskID,"streaming":"duplex"]}
    private func sendJSON(_ value:[String:Any],completion:@escaping (Error?)->Void) {
        guard let transport=transport,!cancelled else{return}
        guard let data=try? JSONSerialization.data(withJSONObject:value),let text=String(data:data,encoding:.utf8) else{
            fail("识别请求编码失败");return
        }
        transport.send(.text(text),completion:completion)
    }
    func append(_ pcm:Data) {
        guard started,!cancelled,!ended,!pcm.isEmpty else{return}
        guard pcm.count%2==0 else{fail("录音数据格式错误");return}
        // 累计音频与共享会话上限一致，队列只是尚未上传的子集，不能靠排空绕过上限。
        let limit = IMicLink.maxSessionSeconds * IMicLink.sampleRate * 2
        guard pcm.count<=limit-totalBytes else{
            IMicLog.write("mac.asr", "audio overflow total=\(totalBytes) incoming=\(pcm.count) limit=\(limit)")
            fail("录音超过单次时长上限，本次输入已停止");return
        }
        totalBytes+=pcm.count
        queue.append(pcm);queuedBytes+=pcm.count
        if queuedBytes > 320_000 && queuedBytes % 64_000 < pcm.count {
            IMicLog.write("mac.asr", "queue high queued=\(queuedBytes)")
        }
        pump()
    }
    func end() {
        guard started,!cancelled,!ended else{return}
        ended=true;endAt=Date();queuedAtEndMS=Double(queuedBytes)/32
        let wait=ASRConfiguration.uploadTimeout(audioSeconds:Double(queuedBytes)/Double(IMicLink.sampleRate*2))
        armDeadline(wait,message:"百炼音频上传超时")
        IMicLog.write("mac.asr", "end queued=\(queuedBytes) at=\(String(format: "%.1f", queuedAtEndMS))ms upload_timeout=\(Int(wait))")
        pump()
    }
    private func armDeadline(_ interval:TimeInterval,message:String) {
        timer?.invalidate()
        completionDeadline=Date().addingTimeInterval(interval)
        timer=Timer.scheduledTimer(withTimeInterval:interval,repeats:false){[weak self] _ in
            self?.fail(message)
        }
    }
    private func pump() {
        guard ready,!sending,!cancelled,let transport=transport else{return}
        if queueHead<queue.count {
            // Binary PCM, not base64 JSON. Avoid repeatedly shifting a long
            // recording's frame array; compact only after a substantial prefix.
            var pcm=Data(capacity:3200)
            while queueHead<queue.count && pcm.count<3200 {
                let count=min(3200-pcm.count,queue[queueHead].count-queueOffset)
                pcm.append(queue[queueHead].dropFirst(queueOffset).prefix(count))
                queuedBytes-=count;queueOffset+=count
                if queueOffset==queue[queueHead].count {
                    queue[queueHead]=Data();queueHead+=1;queueOffset=0
                }
            }
            if queueHead==queue.count {
                queue.removeAll(keepingCapacity:true);queueHead=0
            } else if queueHead>=128 && queueHead>=queue.count/2 {
                queue.removeFirst(queueHead);queueHead=0
            }
            sending=true
            transport.send(.audio(pcm)){[weak self] error in
                guard let self=self,!self.cancelled else{return};self.sending=false
                if error != nil{self.fail("百炼音频上传失败")}else{self.pump()}
            }
        }else if ended && !finishSent {
            finishSent=true;finishAt=Date();sending=true
            sendJSON(["header":header("finish-task"),"payload":["input":[:]]]){[weak self] error in
                guard let self=self,!self.cancelled else{return};self.sending=false
                if error != nil{self.fail("结束识别失败")}else{
                    self.finishAt=Date()
                    self.armDeadline(ASRConfiguration.finalResultTimeout,message:"等待最终识别结果超时")
                    IMicLog.write("mac.asr", "finish-task drained final_timeout=\(Int(ASRConfiguration.finalResultTimeout))")
                }
            }
        }
    }
    private func receive() {
        transport?.receive{[weak self] result in
            guard let self=self,!self.cancelled else{return}
            switch result {
            case .failure:self.fail("百炼连接中断，请检查 Key、网络、地域和模型")
            case .success(let data):
                guard data.count<=1_000_000,let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{
                    self.fail("百炼返回了无效的识别事件");return
                }
                self.handle(object)
                if !self.cancelled{self.receive()}
            }
        }
    }
    private func handle(_ value:[String:Any]) {
        guard let header=value["header"] as? [String:Any],header["task_id"] as? String==taskID else{return}
        switch header["event"] as? String ?? "" {
        case "task-started":
            guard !ready else{return};ready=true;readyAt=Date()
            startupTimer?.invalidate();startupTimer=nil
            IMicLog.write("mac.asr", "task started after_ms=\(Int((readyAt ?? Date()).timeIntervalSince(startedAt)*1000)) queued=\(queuedBytes)")
            pump()
        case "result-generated":
            guard ready,let payload=value["payload"] as? [String:Any],let output=payload["output"] as? [String:Any],
                  let sentence=output["sentence"] as? [String:Any],sentence["heartbeat"] as? Bool != true,
                  let text=sentence["text"] as? String else{return}
            let ended=sentence["sentence_end"] as? Bool==true
            IMicLog.write("mac.asr", "sentence ended=\(ended) chars=\(text.count)")
            if ended {
                guard let id=sentence["sentence_id"] as? Int,id>0 else{return}
                guard id<=4096,text.count<=24000 else{fail("识别结果过长，请缩短本次录音");return}
                guard results[id] != text else { return }
                let previous = confirmedText
                results[id]=text
                guard results.values.reduce(0,{$0+$1.count})<=24000 else{fail("识别结果过长，请缩短本次录音");return}
                if id <= confirmedThrough {
                    confirmedText = (1...confirmedThrough).compactMap { results[$0] }.joined()
                }
                while let next = results[confirmedThrough + 1] {
                    confirmedThrough += 1
                    confirmedText += next
                }
                if !confirmedText.isEmpty, confirmedText != previous {
                    onConfirmed?(confirmedText.trimmingCharacters(in:.whitespacesAndNewlines))
                    guard !cancelled else { return }
                    if previewEnabled {
                        previewCount += 1
                        onPreview?(confirmedText.trimmingCharacters(in:.whitespacesAndNewlines))
                    }
                }
            } else if previewEnabled {
                if let id = sentence["sentence_id"] as? Int, id != confirmedThrough + 1 { return }
                previewCount += 1
                onPreview?((confirmedText+text).trimmingCharacters(in:.whitespacesAndNewlines))
            }
        case "task-finished":
            guard finishSent else{fail("识别任务提前结束，请重试");return}
            let text=results.keys.sorted().compactMap{results[$0]}.joined(),now=Date()
            IMicLog.write("mac.asr", "task finished chars=\(text.count) sentences=\(results.count) queued=\(queuedBytes)")
            let latency=endAt.map{now.timeIntervalSince($0)*1000} ?? 0
            onMetrics?(ASRMetrics(connectionMS:readyAt.map{$0.timeIntervalSince(startedAt)*1000} ?? 0,
                queuedAtEndMS:queuedAtEndMS,uploadTailMS:finishAt.flatMap{finish in endAt.map{finish.timeIntervalSince($0)*1000}} ?? 0,
                serverFinalMS:finishAt.map{now.timeIntervalSince($0)*1000} ?? 0,endToFinalMS:latency,previews:previewCount))
            cancel();onFinal?(text,latency)
        case "task-failed":
            // Display bounded code identifiers only; never echo error_message
            // or request payloads, which can contain credential/audio data.
            let raw=header["error_code"] as? String ?? "unknown"
            let code=String(raw.prefix(64).filter{$0.isASCII && ($0.isLetter || $0.isNumber || $0=="_" || $0=="-" || $0==".")})
            IMicLog.write("mac.asr", "task failed code=\(code) queued=\(queuedBytes)")
            fail("百炼识别失败（\(code.isEmpty ? "unknown":code)）")
        default:break
        }
    }
    func cancel() {
        cancelled=true;timer?.invalidate();timer=nil;startupTimer?.invalidate();startupTimer=nil
        completionDeadline=nil;queue.removeAll();queueHead=0;queueOffset=0;queuedBytes=0
        transport?.cancel();transport=nil
    }
    private func fail(_ message:String){guard !cancelled else{return};IMicLog.write("mac.asr", "fail reason=\(message) queued=\(queuedBytes)");cancel();onError?(message)}
}
