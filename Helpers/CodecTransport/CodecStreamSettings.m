#import "CodecStreamSettings.h"
#include <math.h>

static BOOL IntegerNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && isfinite([value doubleValue]) && [value doubleValue] == [value integerValue];
}
@implementation CodecStreamSettings
+ (instancetype)defaults {
    return [self fromDictionary:@{@"revision": @0, @"ldacQuality": @(-1), @"sampleRate": @0, @"fastRecovery": @NO}];
}
+ (instancetype)fromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *revision = dictionary[@"revision"], *quality = dictionary[@"ldacQuality"], *rate = dictionary[@"sampleRate"], *fast = dictionary[@"fastRecovery"];
    if (!IntegerNumber(revision) || revision.integerValue < 0 || revision.integerValue > INT32_MAX ||
        !IntegerNumber(quality) || quality.integerValue < -1 || quality.integerValue > 2 ||
        !IntegerNumber(rate) || ![@[@0, @44100, @48000] containsObject:rate] ||
        ![fast isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)fast) != CFBooleanGetTypeID()) return nil;
    CodecStreamSettings *value = [self new];
    value->_revision = revision.integerValue; value->_ldacQuality = quality.integerValue;
    value->_sampleRate = rate.doubleValue; value->_fastRecovery = fast.boolValue;
    return value;
}
- (CodecOptions *)optionsForCodec:(NSString *)codec {
    CodecOptions *options = [CodecOptions new];
    options.preferredCodec = codec; options.priority = @[codec];
    options.presets = @{CodecIDLDAC: @(_ldacQuality)};
    options.ldacFastRecovery = _fastRecovery;
    options.maxSampleRate = 48000;
    return options;
}
- (BOOL)matchesConfiguration:(CodecConfiguration *)configuration codec:(NSString *)codec {
    if (!configuration || ![configuration.codec isEqual:codec]) return NO;
    if (_sampleRate && configuration.sampleRate != _sampleRate) return NO;
    if ([codec isEqual:CodecIDLDAC]) {
        if (!configuration.parameters[@"quality"] || [configuration.parameters[@"quality"] integerValue] != _ldacQuality) return NO;
        if (_ldacQuality == -1 && [configuration.parameters[@"fastRecovery"] boolValue] != _fastRecovery) return NO;
    }
    return YES;
}
@end
