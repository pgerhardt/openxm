// Output ownership and bounded recovery. The policy is testable without Core Audio
// or Bluetooth; the HAL adapter below supplies fresh device availability.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CodecAudioOutput : NSObject
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL physical;
@property (nonatomic) BOOL wireless;
@property (nonatomic) BOOL builtIn;
@end

@protocol CodecAudioOutputs <NSObject>
- (nullable NSString *)currentOutputUID;
// Only alive, output-capable devices eligible to be the default output.
- (NSArray<CodecAudioOutput *> *)availableOutputs;
- (BOOL)selectOutput:(NSString *)uid;
@end

typedef NS_ENUM(NSInteger, CodecRouteResult) {
    CodecRoutePending, CodecRouteRestored, CodecRoutePreserved, CodecRouteFailed
};

@interface CodecAudioRoute : NSObject
@property (nonatomic, readonly) BOOL taken;
@property (nonatomic, readonly) BOOL relinquished;
@property (nonatomic, readonly) BOOL usedFallback;
@property (nonatomic, readonly) BOOL playbackBlocked;
// Only set by an explicit user request to restore output without confirmed pause.
@property (nonatomic) BOOL allowsUnpausedPlayback;
@property (nonatomic, readonly, nullable) NSString *restoredOutputName;
- (instancetype)initWithOutputs:(id<CodecAudioOutputs>)outputs journal:(NSString *)journal virtualUID:(NSString *)virtualUID;
- (BOOL)prepare;
- (BOOL)take;
// Returns YES once a different output has been observed. Ownership cannot be
// reacquired by a late callback, even if the user subsequently selects virtual.
- (BOOL)observeOutputChange;
- (void)beginTransitionAt:(NSTimeInterval)now timeout:(NSTimeInterval)timeout;
- (void)confirmReady;
- (BOOL)transitionExpiredAt:(NSTimeInterval)now;
// Only terminal shutdown enters recovery. Codec reconfiguration keeps the route.
- (void)beginRecoveryAt:(NSTimeInterval)now grace:(NSTimeInterval)grace waitForOriginal:(NSTimeInterval)wait;
- (BOOL)setPlaybackProtection:(BOOL)required;
- (CodecRouteResult)recoverAt:(NSTimeInterval)now;
@end

@interface CodecHALAudioOutputs : NSObject <CodecAudioOutputs>
- (BOOL)startObserving:(void (^)(void))handler;
- (void)stopObserving;
@end
NS_ASSUME_NONNULL_END
