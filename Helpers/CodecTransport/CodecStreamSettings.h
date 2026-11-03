#import <Foundation/Foundation.h>
#import "A2DPCodec.h"

@interface CodecStreamSettings : NSObject
@property (nonatomic, readonly) NSInteger revision;
@property (nonatomic, readonly) NSInteger ldacQuality;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) BOOL fastRecovery;
+ (instancetype)defaults;
+ (instancetype)fromDictionary:(NSDictionary *)dictionary;
- (CodecOptions *)optionsForCodec:(NSString *)codec;
- (BOOL)matchesConfiguration:(CodecConfiguration *)configuration codec:(NSString *)codec;
@end
