#import "CodecAudioRoute.h"
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

@implementation CodecAudioOutput
@end

@implementation CodecAudioRoute {
    id<CodecAudioOutputs> _outputs;
    NSString *_journal;
    NSString *_virtualUID;
    NSString *_previousUID;
    NSString *_fallbackUID;
    NSTimeInterval _transitionDeadline;
    NSTimeInterval _restoreAfter;
    NSTimeInterval _fallbackAfter;
    BOOL _recovering;
    BOOL _playbackProtection;
}
- (instancetype)initWithOutputs:(id<CodecAudioOutputs>)outputs journal:(NSString *)journal virtualUID:(NSString *)virtualUID {
    if ((self = [super init])) { _outputs = outputs; _journal = journal; _virtualUID = virtualUID; }
    return self;
}
- (NSString *)memoryPath { return [[_journal stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fallback.plist"]; }
- (CodecAudioOutput *)output:(NSString *)uid in:(NSArray<CodecAudioOutput *> *)outputs {
    if (![uid isKindOfClass:NSString.class]) return nil;
    for (CodecAudioOutput *output in outputs) if ([output.uid isEqual:uid]) return output;
    return nil;
}
- (void)remember:(CodecAudioOutput *)output {
    if (output.physical && !output.wireless) [@{@"uid": output.uid} writeToFile:self.memoryPath atomically:YES];
}
- (NSArray<CodecAudioOutput *> *)fallbacks:(NSArray<CodecAudioOutput *> *)outputs preferred:(NSString *)uid {
    NSMutableArray *choices = [NSMutableArray new];
    CodecAudioOutput *remembered = [self output:uid in:outputs];
    if (remembered.physical && !remembered.wireless) [choices addObject:remembered];
    // Never automatically send audio to an unrelated wireless device, aggregate
    // device or virtual sink. Built-in speakers precede other physical outputs.
    for (int builtIn = 1; builtIn >= 0; builtIn--)
        for (CodecAudioOutput *output in outputs)
            if (output.physical && !output.wireless && output.builtIn == builtIn && ![choices containsObject:output]) [choices addObject:output];
    return choices;
}
- (BOOL)prepare {
    _previousUID = [_outputs currentOutputUID];
    if (!_previousUID.length || [_previousUID isEqual:_virtualUID] || [[NSFileManager defaultManager] fileExistsAtPath:_journal]) return NO;
    NSArray *outputs = [_outputs availableOutputs];
    if (![self output:_virtualUID in:outputs]) return NO;
    [self remember:[self output:_previousUID in:outputs]];
    NSString *remembered = [NSDictionary dictionaryWithContentsOfFile:self.memoryPath][@"uid"];
    _fallbackUID = [self fallbacks:outputs preferred:remembered].firstObject.uid;
    return YES;
}
- (BOOL)take {
    if (_relinquished || _recovering) return NO;
    if (_taken) return YES;
    if (!_previousUID.length) return NO;
    // Initial takeover now precedes the Bluetooth disconnect, so there is no
    // reason to overwrite a different output chosen since prepare.
    if (![[_outputs currentOutputUID] isEqual:_previousUID]) { _relinquished = YES; return NO; }
    NSMutableDictionary *record = [@{@"virtualUID": _virtualUID, @"previousUID": _previousUID,
                                     @"pid": @(getpid()), @"created": [NSDate date]} mutableCopy];
    if (_fallbackUID) record[@"fallbackUID"] = _fallbackUID;
    if (![record writeToFile:_journal atomically:YES]) return NO;
    _taken = YES; // Journal precedes the write, including an ambiguous HAL failure.
    return [_outputs selectOutput:_virtualUID];
}
- (BOOL)observeOutputChange {
    if (_relinquished) return YES;
    NSString *current = [_outputs currentOutputUID];
    if (_taken && current.length && ![current isEqual:_virtualUID]) {
        _relinquished = YES;
        [self remember:[self output:current in:[_outputs availableOutputs]]];
        // There is no longer an owned route for a later crash recovery to change.
        [[NSFileManager defaultManager] removeItemAtPath:_journal error:nil];
    }
    return _relinquished;
}
- (void)beginTransitionAt:(NSTimeInterval)now timeout:(NSTimeInterval)timeout {
    if (!_recovering && !_transitionDeadline) _transitionDeadline = now + timeout;
}
- (void)confirmReady { _transitionDeadline = 0; }
- (BOOL)transitionExpiredAt:(NSTimeInterval)now { return !_recovering && _transitionDeadline > 0 && now >= _transitionDeadline; }
- (void)beginRecoveryAt:(NSTimeInterval)now grace:(NSTimeInterval)grace waitForOriginal:(NSTimeInterval)wait {
    if (_recovering) return;
    _recovering = YES; _transitionDeadline = 0;
    _restoreAfter = now + grace; _fallbackAfter = now + MAX(grace, wait);
}
- (CodecRouteResult)finish:(CodecRouteResult)result {
    if ([[NSFileManager defaultManager] fileExistsAtPath:_journal] &&
        ![[NSFileManager defaultManager] removeItemAtPath:_journal error:nil]) return CodecRouteFailed;
    return result;
}
- (BOOL)setPlaybackProtection:(BOOL)required {
    _playbackProtection = required;
    NSMutableDictionary *record = [[NSDictionary dictionaryWithContentsOfFile:_journal] mutableCopy];
    if (!record) return !_taken || _relinquished;
    if (required) record[@"playbackProtection"] = @YES;
    else [record removeObjectForKey:@"playbackProtection"];
    return [record writeToFile:_journal atomically:YES];
}
- (CodecRouteResult)recoverAt:(NSTimeInterval)now {
    _playbackBlocked = NO;
    if (!_recovering) return CodecRoutePending;
    NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:_journal];
    if (!record) return [[NSFileManager defaultManager] fileExistsAtPath:_journal] ? CodecRouteFailed : CodecRoutePreserved;
    if (![record[@"virtualUID"] isEqual:_virtualUID]) return CodecRouteFailed;
    NSNumber *pid = record[@"pid"];
    if (![pid isKindOfClass:NSNumber.class] || pid.longLongValue <= 0 || pid.longLongValue > INT_MAX ||
        ![record[@"previousUID"] isKindOfClass:NSString.class]) return CodecRouteFailed;
    pid_t owner = pid.intValue;
    if (owner > 0 && owner != getpid() && (kill(owner, 0) == 0 || errno == EPERM)) return CodecRouteFailed;
    NSString *current = [_outputs currentOutputUID];
    if (_relinquished || (current.length && ![current isEqual:_virtualUID])) return [self finish:CodecRoutePreserved];
    // A failed HAL read does not establish ownership or authorize a route change.
    if (!current.length) return now < _fallbackAfter ? CodecRoutePending : CodecRouteFailed;
    if (!self.allowsUnpausedPlayback && (_playbackProtection || [record[@"playbackProtection"] isEqual:@YES])) {
        _playbackBlocked = YES; return CodecRouteFailed;
    }
    if (now < _restoreAfter) return CodecRoutePending;
    NSArray *outputs = [_outputs availableOutputs];
    NSMutableArray<CodecAudioOutput *> *choices = [NSMutableArray new];
    CodecAudioOutput *previous = [self output:record[@"previousUID"] in:outputs];
    if (previous.physical) [choices addObject:previous];
    if (now >= _fallbackAfter) {
        NSString *remembered = record[@"fallbackUID"] ?: [NSDictionary dictionaryWithContentsOfFile:self.memoryPath][@"uid"];
        for (CodecAudioOutput *output in [self fallbacks:outputs preferred:remembered])
            if (![choices containsObject:output]) [choices addObject:output];
    }
    for (CodecAudioOutput *output in choices) {
        // Recheck immediately before each write. A user selection during the
        // grace period, device discovery, or a failed write always wins.
        NSString *latest = [_outputs currentOutputUID];
        if (!latest.length) return CodecRouteFailed;
        if (![latest isEqual:_virtualUID]) return [self finish:CodecRoutePreserved];
        if ([_outputs selectOutput:output.uid]) {
            _usedFallback = ![output.uid isEqual:record[@"previousUID"]];
            _restoredOutputName = output.name;
            [self remember:output];
            return [self finish:CodecRouteRestored];
        }
    }
    return now < _fallbackAfter ? CodecRoutePending : CodecRouteFailed;
}
@end
