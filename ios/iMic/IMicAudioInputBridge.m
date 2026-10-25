#import "IMicAudioInputBridge.h"
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>

// Fixed allocation covers a 170ms callback at 48kHz and 64 outstanding callbacks.
// Bounds are failures, not permission to truncate or silently drop PCM.
enum { IMicSlotCount = 64, IMicMaxFrames = 8192 };
typedef NS_ENUM(int, IMicInputFailure) {
    IMicInputFailureNone, IMicInputFailureFormat, IMicInputFailureCapacity,
    IMicInputFailureOverflow, IMicInputFailureConversion
};
typedef struct {
    AudioBufferList *storage; // Owned by the corresponding preallocated AVAudioPCMBuffer.
    uint32_t frames;
} IMicInputSlot;
typedef struct {
    _Atomic(uint64_t) writeIndex;
    _Atomic(uint64_t) readIndex;
    _Atomic(bool) accepting;
    _Atomic(int) failure;
    _Atomic(uint64_t) callbacks;
    _Atomic(uint64_t) frames;
    _Atomic(uint64_t) maxGapTicks;
    uint64_t lastIOTicks; // Single producer only.
    uint32_t bufferCount;
    uint32_t channelsPerBuffer;
    uint32_t bytesPerFrame;
    void *notification; // Non-owning dispatch source; bridge outlives stopped IO.
    IMicInputSlot slots[IMicSlotCount];
} IMicInputState;

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2,
               "The input callback requires lock-free atomics");

static OSStatus IMicRejectInput(IMicInputState *state, IMicInputFailure reason) {
    int expected = IMicInputFailureNone;
    atomic_compare_exchange_strong_explicit(&state->failure, &expected, reason,
                                           memory_order_relaxed, memory_order_relaxed);
    atomic_store_explicit(&state->accepting, false, memory_order_release);
    dispatch_source_merge_data((__bridge dispatch_source_t)state->notification, 1);
    return -50;
}

// Called by the sink block, or by the single-producer DEBUG harness. No Objective-C
// messages, object ownership operations, allocations, locks, logging or Swift here.
static OSStatus IMicEnqueueInput(IMicInputState *state, uint32_t frames, const AudioBufferList *input) {
    if (!atomic_load_explicit(&state->accepting, memory_order_acquire)) return -50;
    uint64_t now = mach_absolute_time();
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&state->frames, frames, memory_order_relaxed);
    if (state->lastIOTicks) {
        uint64_t gap = now - state->lastIOTicks;
        uint64_t maximum = atomic_load_explicit(&state->maxGapTicks, memory_order_relaxed);
        while (gap > maximum && !atomic_compare_exchange_weak_explicit(
                   &state->maxGapTicks, &maximum, gap, memory_order_relaxed, memory_order_relaxed)) {}
    }
    state->lastIOTicks = now;
    if (frames > IMicMaxFrames) return IMicRejectInput(state, IMicInputFailureCapacity);
    if (!input || input->mNumberBuffers != state->bufferCount)
        return IMicRejectInput(state, IMicInputFailureFormat);
    uint32_t byteCount = frames * state->bytesPerFrame;
    for (uint32_t b = 0; b < state->bufferCount; b++) {
        if (input->mBuffers[b].mNumberChannels != state->channelsPerBuffer ||
            input->mBuffers[b].mDataByteSize != byteCount ||
            (byteCount && !input->mBuffers[b].mData))
            return IMicRejectInput(state, IMicInputFailureFormat);
    }
    if (!frames) return noErr;
    uint64_t write = atomic_load_explicit(&state->writeIndex, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&state->readIndex, memory_order_acquire);
    if (write - read >= IMicSlotCount) return IMicRejectInput(state, IMicInputFailureOverflow);
    IMicInputSlot *slot = &state->slots[write % IMicSlotCount];
    for (uint32_t b = 0; b < state->bufferCount; b++)
        memcpy(slot->storage->mBuffers[b].mData, input->mBuffers[b].mData, byteCount);
    slot->frames = frames;
    atomic_store_explicit(&state->writeIndex, write + 1, memory_order_release);
    dispatch_source_merge_data((__bridge dispatch_source_t)state->notification, 1);
    return noErr;
}

static NSError *IMicBridgeError(NSString *message) {
    return [NSError errorWithDomain:@"com.drafffffff.imic.audio-input" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation IMicAudioInputBridge {
    IMicInputState *_state;
    AVAudioSinkNode *_sinkNode;
    NSArray<AVAudioPCMBuffer *> *_buffers;
    AVAudioConverter *_converter;
    AVAudioPCMBuffer *_output;
    dispatch_queue_t _worker;
    dispatch_source_t _notification;
    dispatch_source_t _timer;
    void (^_onChunk)(NSData *);
    void (^_onBuffer)(AVAudioPCMBuffer *);
    void (^_onFailure)(NSString *);
    void (^_onLog)(NSString *);
    BOOL _finished;
    BOOL _failureReported;
    double _ticksToMilliseconds;
    double _sampleRate;
    uint64_t _lastReportTicks;
    uint64_t _workerCallbacks;
    uint64_t _workerFrames;
    uint64_t _lastWorkerTicks;
    uint64_t _maxWorkerGapTicks;
}

- (instancetype)initWithFormat:(AVAudioFormat *)format
                      onChunk:(void (^)(NSData *))onChunk
                     onBuffer:(void (^)(AVAudioPCMBuffer *))onBuffer
                    onFailure:(void (^)(NSString *))onFailure
                        onLog:(void (^)(NSString *))onLog
                        error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    if (format.sampleRate <= 0 || format.channelCount == 0 || format.channelCount > 32 ||
        asbd->mFormatID != kAudioFormatLinearPCM || asbd->mBytesPerFrame == 0 ||
        asbd->mBytesPerFrame > 256 || asbd->mFramesPerPacket != 1) {
        if (error) *error = IMicBridgeError(@"麦克风 PCM 格式不可用");
        return nil;
    }
    _state = calloc(1, sizeof(IMicInputState));
    if (!_state) {
        if (error) *error = IMicBridgeError(@"麦克风缓冲区分配失败");
        return nil;
    }
    atomic_init(&_state->writeIndex, 0);
    atomic_init(&_state->readIndex, 0);
    atomic_init(&_state->accepting, false);
    atomic_init(&_state->failure, IMicInputFailureNone);
    atomic_init(&_state->callbacks, 0);
    atomic_init(&_state->frames, 0);
    atomic_init(&_state->maxGapTicks, 0);
    _state->bufferCount = format.isInterleaved ? 1 : format.channelCount;
    _state->channelsPerBuffer = format.isInterleaved ? format.channelCount : 1;
    _state->bytesPerFrame = asbd->mBytesPerFrame;
    NSMutableArray<AVAudioPCMBuffer *> *buffers = [NSMutableArray arrayWithCapacity:IMicSlotCount];
    for (uint32_t i = 0; i < IMicSlotCount; i++) {
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:IMicMaxFrames];
        if (!buffer) {
            if (error) *error = IMicBridgeError(@"麦克风缓冲区分配失败");
            return nil;
        }
        [buffers addObject:buffer];
        _state->slots[i].storage = buffer.mutableAudioBufferList;
        // Touch every allocated page before IO starts; no first-use page faults in memcpy.
        for (uint32_t b = 0; b < _state->bufferCount; b++)
            memset(buffer.mutableAudioBufferList->mBuffers[b].mData, 0, IMicMaxFrames * asbd->mBytesPerFrame);
    }
    _buffers = [buffers copy];
    AVAudioFormat *target = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                          sampleRate:16000 channels:1 interleaved:YES];
    _converter = [[AVAudioConverter alloc] initFromFormat:format toFormat:target];
    _output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target
                                          frameCapacity:(AVAudioFrameCount)ceil(IMicMaxFrames * 16000.0 / format.sampleRate) + 1024];
    if (!_converter || !_output) {
        if (error) *error = IMicBridgeError(@"麦克风重采样器创建失败");
        return nil;
    }
    _onChunk = [onChunk copy];
    _onBuffer = [onBuffer copy];
    _onFailure = [onFailure copy];
    _onLog = [onLog copy];
    _sampleRate = format.sampleRate;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    _ticksToMilliseconds = (double)timebase.numer / timebase.denom / 1000000.0;
    _lastReportTicks = mach_absolute_time();
    _worker = dispatch_queue_create("imic.audio.input-worker", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _notification = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _worker);
    _state->notification = (__bridge void *)_notification;
    // Weak handlers avoid a bridge/source retain cycle. Each handler keeps the bridge
    // alive for its complete worker operation, and finish fences this queue.
    __weak IMicAudioInputBridge *weakSelf = self;
    dispatch_source_set_event_handler(_notification, ^{
        IMicAudioInputBridge *bridge = weakSelf;
        [bridge drain];
    });
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _worker);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{
        IMicAudioInputBridge *bridge = weakSelf;
        [bridge reportCadence];
    });
    dispatch_resume(_notification);
    dispatch_resume(_timer);
    IMicInputState *state = _state;
    _sinkNode = [[AVAudioSinkNode alloc] initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp, AVAudioFrameCount frames, const AudioBufferList *input) {
        return IMicEnqueueInput(state, frames, input);
    }];
    atomic_store_explicit(&_state->accepting, true, memory_order_release);
    return self;
}

- (AVAudioSinkNode *)sinkNode { return _sinkNode; }

- (void)reportFailure {
    int reason = atomic_load_explicit(&_state->failure, memory_order_acquire);
    if (_failureReported || reason == IMicInputFailureNone) return;
    _failureReported = YES;
    NSString *message;
    switch (reason) {
        case IMicInputFailureFormat: message = @"麦克风输入格式发生变化，录音已停止"; break;
        case IMicInputFailureCapacity: message = @"麦克风单次输入超过 8192 帧，录音已停止"; break;
        case IMicInputFailureOverflow: message = @"麦克风处理队列已满（64 槽），录音已停止以避免缺失内容"; break;
        default: message = @"麦克风重采样失败，录音已停止"; break;
    }
    _onLog([NSString stringWithFormat:@"input failure code=%d read=%llu write=%llu", reason,
            (unsigned long long)atomic_load(&_state->readIndex), (unsigned long long)atomic_load(&_state->writeIndex)]);
    _onFailure(message);
}

- (BOOL)convertBuffer:(AVAudioPCMBuffer *)input endOfStream:(BOOL)endOfStream {
    __block BOOL supplied = NO;
    AVAudioConverterOutputStatus status;
    do {
        _output.frameLength = 0;
        NSError *error = nil;
        status = [_converter convertToBuffer:_output error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount packets, AVAudioConverterInputStatus *inputStatus) {
            if (input && !supplied) {
                supplied = YES;
                *inputStatus = AVAudioConverterInputStatus_HaveData;
                return input;
            }
            *inputStatus = endOfStream ? AVAudioConverterInputStatus_EndOfStream : AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }];
        if (status == AVAudioConverterOutputStatus_Error || error) {
            // Do not generate silence or skip a failed buffer and continue a corrupt utterance.
            int expected = IMicInputFailureNone;
            atomic_compare_exchange_strong(&_state->failure, &expected, IMicInputFailureConversion);
            atomic_store_explicit(&_state->accepting, false, memory_order_release);
            _onLog([NSString stringWithFormat:@"converter error=%@", error.localizedDescription ?: @"unknown"]);
            return NO;
        }
        if (_output.frameLength) {
            NSData *ownedPCM = [NSData dataWithBytes:_output.int16ChannelData[0] length:_output.frameLength * sizeof(int16_t)];
            _onChunk(ownedPCM);
        }
    } while (status == AVAudioConverterOutputStatus_HaveData);
    return YES;
}

- (void)drain {
    if (_finished) return;
    uint64_t read = atomic_load_explicit(&_state->readIndex, memory_order_relaxed);
    while (read < atomic_load_explicit(&_state->writeIndex, memory_order_acquire)) {
        @autoreleasepool {
            uint64_t now = mach_absolute_time();
            if (_lastWorkerTicks) _maxWorkerGapTicks = MAX(_maxWorkerGapTicks, now - _lastWorkerTicks);
            _lastWorkerTicks = now;
            IMicInputSlot *slot = &_state->slots[read % IMicSlotCount];
            AVAudioPCMBuffer *buffer = _buffers[read % IMicSlotCount];
            buffer.frameLength = slot->frames;
            _workerCallbacks++;
            _workerFrames += slot->frames;
            if (_onBuffer) _onBuffer(buffer);
            if (atomic_load_explicit(&_state->failure, memory_order_acquire) != IMicInputFailureConversion)
                [self convertBuffer:buffer endOfStream:NO];
            // Only now may the producer reuse this memory, including after a conversion failure.
            read++;
            atomic_store_explicit(&_state->readIndex, read, memory_order_release);
        }
    }
    [self reportFailure];
}

- (void)reportCadence {
    if (_finished) return;
    uint64_t now = mach_absolute_time();
    double elapsed = (now - _lastReportTicks) * _ticksToMilliseconds / 1000.0;
    uint64_t callbacks = atomic_exchange_explicit(&_state->callbacks, 0, memory_order_relaxed);
    uint64_t frames = atomic_exchange_explicit(&_state->frames, 0, memory_order_relaxed);
    uint64_t gap = atomic_exchange_explicit(&_state->maxGapTicks, 0, memory_order_relaxed);
    uint64_t pending = atomic_load(&_state->writeIndex) - atomic_load(&_state->readIndex);
    _onLog([NSString stringWithFormat:@"cadence elapsed=%.3fs ioCallbacks=%llu ioFrames=%llu ioMaxGap=%.2fms workerCallbacks=%llu workerFrames=%llu workerMaxGap=%.2fms pending=%llu sampleRate=%.0f IOBufferDuration=%.5fs", elapsed,
            (unsigned long long)callbacks, (unsigned long long)frames, gap * _ticksToMilliseconds,
            (unsigned long long)_workerCallbacks, (unsigned long long)_workerFrames,
            _maxWorkerGapTicks * _ticksToMilliseconds, (unsigned long long)pending,
            _sampleRate, AVAudioSession.sharedInstance.IOBufferDuration]);
    _lastReportTicks = now;
    _workerCallbacks = 0;
    _workerFrames = 0;
    _maxWorkerGapTicks = 0;
    [self reportFailure];
}

- (void)finish {
    if (!_worker || _finished) return;
    atomic_store_explicit(&_state->accepting, false, memory_order_release);
    // Non-owning capture also permits the defensive dealloc path without retaining
    // an object whose deallocation has begun. dispatch_sync bounds its lifetime.
    __unsafe_unretained IMicAudioInputBridge *bridge = self;
    dispatch_sync(_worker, ^{
        if (bridge->_finished) return;
        [bridge drain];
        if (atomic_load(&bridge->_state->failure) != IMicInputFailureConversion)
            [bridge convertBuffer:nil endOfStream:YES];
        [bridge reportFailure];
        [bridge reportCadence];
        bridge->_finished = YES;
        dispatch_source_cancel(bridge->_timer);
        dispatch_source_cancel(bridge->_notification);
    });
}

- (void)dealloc {
    // The owner has stopped IO; finish also makes partially initialized instances safe.
    [self finish];
    _sinkNode = nil;
    free(_state);
}
@end
