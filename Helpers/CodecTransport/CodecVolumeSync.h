// OpenXM: one volume control, seeded from the headphones rather than the Mac's
// remembered virtual-output level. All methods/callbacks run on the main queue.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^CodecVolumeReply)(BOOL accepted, int actualVolume);

@protocol CodecVolumeDevice <NSObject>
- (BOOL)attachWithChangeHandler:(void (^)(void))handler;
- (BOOL)readScalar:(float *)value;
- (BOOL)setScalar:(float)value;
- (BOOL)setHardwareMode:(BOOL)enabled;
- (void)detach;
@end

@interface CodecVolumeSync : NSObject
@property (nonatomic, copy, nullable) BOOL (^sendVolumeHandler)(int volume, CodecVolumeReply reply);
@property (nonatomic, copy, nullable) void (^changedHandler)(void);
@property (nonatomic, copy, nullable) void (^failureHandler)(NSString *message);
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly) int confirmedVolume;
- (instancetype)initWithDevice:(id<CodecVolumeDevice>)device;
- (BOOL)start;
- (void)remoteVolumeChanged:(int)volume;
- (BOOL)setLocalVolume:(int)volume;
- (void)stepVolume:(int)direction;
- (void)stop;
@end

// HAL adapter. Discovery/property patterns adapted from Blue Bloom VolumeSync
// (MIT); see Vendor/BlueBloom/OPENXM-PROVENANCE.md.
@interface CodecHALVolumeDevice : NSObject <CodecVolumeDevice>
@end
NS_ASSUME_NONNULL_END
