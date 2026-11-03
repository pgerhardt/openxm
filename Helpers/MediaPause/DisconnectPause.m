#import "DisconnectPause.h"
@implementation DisconnectPlayer
- (BOOL)samePlayer:(DisconnectPlayer *)other {
    return other && self.pid > 0 && self.pid == other.pid && self.bundleID.length && [self.bundleID isEqual:other.bundleID];
}
@end

NSString *PauseMediaOnDisconnect(id<DisconnectPlayback> playback) {
    NSTimeInterval deadline = playback.now + 4;
    if (!playback.ownsOutput) return @"cancelled";
    DisconnectPlayer *initial = [playback readPlayerBefore:deadline];
    if (!playback.ownsOutput) return @"cancelled";
    if (!initial) return @"unavailable";
    if (!initial.playing) return initial.pid > 0 ? @"alreadyPaused" : @"noPlayer";
    if (initial.pid <= 0 || !initial.bundleID.length) return @"unavailable";
    DisconnectPlayerRoute route = [playback routeForPlayer:initial];
    if (route == DisconnectRouteElsewhere) return @"otherOutput";
    if (route != DisconnectRouteHeadphones) return @"unavailable";
    // Re-read immediately before the command. Do not use a cached UI snapshot
    // or pause whatever happens to be current after an asynchronous app switch.
    DisconnectPlayer *fresh = [playback readPlayerBefore:deadline];
    if (!playback.ownsOutput) return @"cancelled";
    if (![initial samePlayer:fresh]) return @"unconfirmed";
    if (!fresh.playing) return @"alreadyPaused";
    route = [playback routeForPlayer:fresh];
    if (route == DisconnectRouteElsewhere) return @"otherOutput";
    if (route != DisconnectRouteHeadphones || playback.now >= deadline) return @"unconfirmed";
    if (!playback.ownsOutput) return @"cancelled";
    if (![playback sendPause]) return @"unconfirmed";
    // Command acceptance is not proof of paused playback. Never send Play on
    // reconnect, and never retry Pause against a newly selected player.
    while (playback.now < deadline) {
        if (!playback.ownsOutput) return @"cancelled";
        DisconnectPlayer *after = [playback readPlayerBefore:deadline];
        if (!playback.ownsOutput) return @"cancelled";
        if (![initial samePlayer:after]) return @"unconfirmed";
        if (!after.playing) return @"paused";
        [playback waitForUpdate];
    }
    return @"unconfirmed";
}
