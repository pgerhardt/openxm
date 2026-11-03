// Runs inside the existing bundled MediaRemote Adapter/Perl host. It reads only
// player identity/state and HAL routing, not titles, artwork or audio samples.
#import "DisconnectPause.h"
#import "adapter/globals.h"
#import "VirtualDeviceProtocol.h"
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#include <unistd.h>

static NSArray<NSNumber *> *PauseIntegers(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress property = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &property, 0, NULL, &size) != noErr || size % 4 || size > 65536) return nil;
    if (!size) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size]; UInt32 capacity = size;
    if (AudioObjectGetPropertyData(object, &property, 0, NULL, &size, data.mutableBytes) != noErr || size > capacity || size % 4) return nil;
    NSMutableArray *values = [NSMutableArray new]; const UInt32 *items = data.bytes;
    for (NSUInteger i = 0; i < size / 4; i++) [values addObject:@(items[i])];
    return values;
}
static NSString *PauseString(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress property = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef value = NULL; UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object, &property, 0, NULL, &size, &value) != noErr || !value) return nil;
    return CFBridgingRelease(value);
}

@interface DisconnectMediaRemote : NSObject <DisconnectPlayback>
@property pid_t owner;
@end
@implementation DisconnectMediaRemote
- (NSTimeInterval)now { return NSProcessInfo.processInfo.systemUptime; }
- (void)waitForUpdate { [NSThread sleepForTimeInterval:0.1]; }
- (BOOL)ownsOutput {
    // A child orphaned by a helper crash must not issue a late playback command.
    if (self.owner <= 1 || getppid() != self.owner) return NO;
    NSArray *ids = PauseIntegers(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    return ids.count == 1 && [PauseString([ids.firstObject unsignedIntValue], kAudioDevicePropertyDeviceUID) isEqual:@kBBDeviceUID];
}
- (DisconnectPlayer *)readPlayerBefore:(NSTimeInterval)deadline {
    if (!g_mediaRemote.getNowPlayingApplicationPID || !g_mediaRemote.getNowPlayingApplicationIsPlaying) return nil;
    // The callback chain brackets playback state with PID reads so an app switch
    // cannot combine one player's identity with another player's playback state.
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block DisconnectPlayer *result = nil;
    g_mediaRemote.getNowPlayingApplicationPID(g_serialdispatchQueue, ^(int firstPID) {
        g_mediaRemote.getNowPlayingApplicationIsPlaying(g_serialdispatchQueue, ^(bool playing) {
            g_mediaRemote.getNowPlayingApplicationPID(g_serialdispatchQueue, ^(int lastPID) {
                if (firstPID == lastPID) {
                    DisconnectPlayer *player = [DisconnectPlayer new];
                    player.pid = firstPID; player.playing = playing;
                    player.bundleID = firstPID > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:firstPID].bundleIdentifier ?: @"" : @"";
                    result = player;
                }
                dispatch_semaphore_signal(ready);
            });
        });
    });
    NSTimeInterval remaining = MIN(0.8, MAX(0, deadline - self.now));
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC))) != 0) return nil;
    return result;
}
- (DisconnectPlayerRoute)routeForPlayer:(DisconnectPlayer *)player {
    NSArray *processes = PauseIntegers(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal);
    if (!processes) return DisconnectRouteUnknown;
    NSMutableArray *matches = [NSMutableArray new];
    for (NSNumber *process in processes) {
        NSArray *pids = PauseIntegers(process.unsignedIntValue, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal);
        if (pids.count == 1 && [pids.firstObject intValue] == player.pid &&
            [PauseString(process.unsignedIntValue, kAudioProcessPropertyBundleID) isEqual:player.bundleID]) [matches addObject:process];
    }
    // A player may delegate audio to a helper process. Missing its exact PID is
    // uncertainty, not evidence that it is safely routed to another output.
    if (matches.count != 1) return DisconnectRouteUnknown;
    AudioObjectID process = [matches.firstObject unsignedIntValue];
    NSArray *running = PauseIntegers(process, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal);
    NSArray *devices = PauseIntegers(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput);
    if (running.count != 1 || !devices) return DisconnectRouteUnknown;
    if ([running isEqual:@[@0]]) return DisconnectRouteElsewhere;
    if (![running isEqual:@[@1]] || devices.count != 1) return DisconnectRouteUnknown;
    NSString *uid = PauseString([devices.firstObject unsignedIntValue], kAudioDevicePropertyDeviceUID);
    if (!uid) return DisconnectRouteUnknown;
    return [uid isEqual:@kBBDeviceUID] ? DisconnectRouteHeadphones : DisconnectRouteElsewhere;
}
- (BOOL)sendPause {
    // macOS directs this to its current Now Playing player. There is no reliable
    // public arbitrary-player command API; identity/routing are checked directly
    // before this call and identity/state are verified after it.
    return self.ownsOutput && g_mediaRemote.sendCommand && g_mediaRemote.sendCommand(kMRPause,
        @{@"kMRMediaRemoteOptionDisableImplicitAppLaunchBehaviors": @YES});
}
@end

void adapter_pause_disconnect(void) {
    @autoreleasepool {
        DisconnectMediaRemote *playback = [DisconnectMediaRemote new]; playback.owner = getppid();
        NSString *status = PauseMediaOnDisconnect(playback);
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"status": status} options:0 error:nil];
        fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
    }
}
