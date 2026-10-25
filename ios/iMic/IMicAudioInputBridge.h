#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns a bounded native-PCM queue and a serial, non-realtime conversion worker.
/// Create a fresh bridge for every engine. The owner MUST stop and detach the engine
/// before calling finish; no producer may run after finish begins.
@interface IMicAudioInputBridge : NSObject
@property (nonatomic, readonly) AVAudioSinkNode *sinkNode;

/// Callbacks run serially on the worker. PCM16 NSData owns its bytes. nativeBuffer is
/// borrowed only until the callback returns; copy it before retaining asynchronously.
- (nullable instancetype)initWithFormat:(AVAudioFormat *)format
                              onChunk:(void (^)(NSData *pcm16))onChunk
                             onBuffer:(void (^ _Nullable)(AVAudioPCMBuffer *nativeBuffer))onBuffer
                            onFailure:(void (^)(NSString *message))onFailure
                                onLog:(void (^)(NSString *message))onLog
                                error:(NSError * _Nullable * _Nullable)error;

/// After IO stops, synchronously drain accepted slots and converter tail, then close.
/// Never call from a worker callback. Safe to call more than once.
- (void)finish;
@end

NS_ASSUME_NONNULL_END
