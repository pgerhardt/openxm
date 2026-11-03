#import "DisconnectPause.h"
#import "CodecDisconnectPause.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "Disconnect pause test failed at line %d: %s\n", __LINE__, #__VA_ARGS__); exit(1); } } while (0)

@interface FakePlayback : NSObject <DisconnectPlayback>
@property BOOL owned;
@property BOOL accepted;
@property NSTimeInterval time;
@property NSTimeInterval readDuration;
@property NSUInteger reads;
@property NSUInteger pauses;
@property NSArray *snapshots;
@property DisconnectPlayerRoute route;
@property (copy) void (^onRead)(NSUInteger);
@end
@implementation FakePlayback
- (instancetype)init {
    if ((self = [super init])) { _owned = YES; _accepted = YES; _time = 100; _readDuration = 0.1; _route = DisconnectRouteHeadphones; }
    return self;
}
- (NSTimeInterval)now { return self.time; }
- (void)waitForUpdate { self.time += 0.1; }
- (BOOL)ownsOutput { return self.owned; }
- (DisconnectPlayer *)readPlayerBefore:(NSTimeInterval)deadline {
    self.time += self.readDuration;
    id value = self.snapshots[MIN(self.reads, self.snapshots.count - 1)];
    self.reads++;
    if (self.onRead) self.onRead(self.reads);
    return value == NSNull.null ? nil : value;
}
- (DisconnectPlayerRoute)routeForPlayer:(DisconnectPlayer *)player { return self.route; }
- (BOOL)sendPause { self.pauses++; return self.accepted; }
@end
static DisconnectPlayer *Player(pid_t pid, BOOL playing) {
    DisconnectPlayer *player = [DisconnectPlayer new]; player.pid = pid;
    player.bundleID = pid ? [NSString stringWithFormat:@"player.%d", pid] : @""; player.playing = playing; return player;
}
static FakePlayback *Playback(NSArray *snapshots) { FakePlayback *p = [FakePlayback new]; p.snapshots = snapshots; return p; }

static void ConfirmsPauseOnlyAfterPlayerStateChanges(void) {
    FakePlayback *p = Playback(@[Player(1, YES), Player(1, YES), Player(1, YES), Player(1, NO)]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"paused"] && p.pauses == 1 && p.reads == 4);
}
static void PausedAndAbsentPlayersAreNeverStarted(void) {
    for (NSNumber *pid in @[@0, @1]) {
        FakePlayback *p = Playback(@[Player(pid.intValue, NO)]);
        CHECK([PauseMediaOnDisconnect(p) isEqual:pid.intValue ? @"alreadyPaused" : @"noPlayer"] && p.pauses == 0);
    }
    FakePlayback *p = Playback(@[Player(1, YES), Player(1, NO)]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"alreadyPaused"] && p.pauses == 0);
}
static void UnrelatedAndChangedRoutesAreLeftAlone(void) {
    FakePlayback *p = Playback(@[Player(1, YES)]); p.route = DisconnectRouteElsewhere;
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"otherOutput"] && p.pauses == 0);
    p = Playback(@[Player(1, YES)]); __weak FakePlayback *weak = p;
    p.onRead = ^(NSUInteger reads) { if (reads == 2) weak.route = DisconnectRouteElsewhere; };
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"otherOutput"] && p.pauses == 0);
}
static void ChangedPlayerIsNeverPausedOrMistakenForConfirmation(void) {
    FakePlayback *p = Playback(@[Player(1, YES), Player(2, YES)]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 0);
    p = Playback(@[Player(1, YES), Player(1, YES), Player(2, NO)]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 1);
    DisconnectPlayer *reused = Player(1, YES); reused.bundleID = @"different.bundle";
    p = Playback(@[Player(1, YES), reused]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 0);
}
static void ManualOutputChoiceCancelsPendingWork(void) {
    for (NSUInteger when = 0; when <= 3; when++) {
        FakePlayback *p = Playback(@[Player(1, YES)]); __weak FakePlayback *weak = p;
        if (!when) p.owned = NO;
        p.onRead = ^(NSUInteger reads) { if (reads == when) weak.owned = NO; };
        CHECK([PauseMediaOnDisconnect(p) isEqual:@"cancelled"] && p.pauses == (when == 3 ? 1 : 0));
    }
}
static void UnknownStateAndRoutingDoNotClaimPause(void) {
    FakePlayback *p = Playback(@[NSNull.null]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unavailable"] && p.pauses == 0);
    p = Playback(@[Player(1, YES)]); p.route = DisconnectRouteUnknown;
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unavailable"] && p.pauses == 0);
    p = Playback(@[Player(1, YES), NSNull.null]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 0);
}
static void RejectedOrIgnoredPauseIsBoundedAndNeverRetried(void) {
    FakePlayback *p = Playback(@[Player(1, YES)]); p.accepted = NO;
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 1);
    p = Playback(@[Player(1, YES)]);
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 1 && p.time < 104.3);
    p = Playback(@[Player(1, YES)]); p.readDuration = 3;
    CHECK([PauseMediaOnDisconnect(p) isEqual:@"unconfirmed"] && p.pauses == 0);
}
static CodecDisconnectPause *Runner(NSString *command) {
    return [[CodecDisconnectPause alloc] initWithExecutable:[NSURL fileURLWithPath:@"/bin/sh"] arguments:@[@"-c", command]];
}
static void Finish(CodecDisconnectPause *runner) {
    for (int i = 0; i < 200 && runner.pending; i++) { [NSThread sleepForTimeInterval:0.005]; [runner pollAt:100]; }
    CHECK(!runner.pending);
}
static void RunnerRequiresValidSuccessfulReply(void) {
    for (NSString *status in @[@"paused", @"alreadyPaused", @"noPlayer", @"otherOutput", @"cancelled", @"unavailable", @"unconfirmed"]) {
        CodecDisconnectPause *runner = Runner([NSString stringWithFormat:@"printf '{\"status\":\"%@\"}'", status]);
        [runner startAt:100]; Finish(runner);
        CHECK([runner.status isEqual:status]);
        CHECK(runner.allowsRecovery == ![@[@"unavailable", @"unconfirmed"] containsObject:status]);
    }
    for (NSString *command in @[@"printf 'broken'", @"printf '[]'", @"printf '{\"status\":\"paused\"}'; exit 1", @"printf '{\"status\":\"unknown\"}'"]) {
        CodecDisconnectPause *runner = Runner(command); [runner startAt:100]; Finish(runner);
        CHECK(!runner.allowsRecovery && [runner.status isEqual:@"unconfirmed"]);
    }
}
static void RunnerTimeoutAndCancellationCannotProduceLateSuccess(void) {
    CodecDisconnectPause *runner = Runner(@"exec sleep 10"); [runner startAt:100]; [runner pollAt:106];
    CHECK(!runner.pending && !runner.allowsRecovery && [runner.status isEqual:@"unconfirmed"]);
    [runner pollAt:110]; CHECK(!runner.allowsRecovery);
    runner = Runner(@"exec sleep 10"); [runner startAt:100]; [runner cancel]; [runner pollAt:110];
    CHECK(!runner.pending && runner.allowsRecovery && [runner.status isEqual:@"cancelled"]);
    runner = [[CodecDisconnectPause alloc] initWithExecutable:[NSURL fileURLWithPath:@"/does/not/exist"] arguments:@[]];
    [runner startAt:100]; CHECK(!runner.pending && !runner.allowsRecovery);
}
int main(void) {
    @autoreleasepool {
        ConfirmsPauseOnlyAfterPlayerStateChanges(); PausedAndAbsentPlayersAreNeverStarted();
        UnrelatedAndChangedRoutesAreLeftAlone(); ChangedPlayerIsNeverPausedOrMistakenForConfirmation();
        ManualOutputChoiceCancelsPendingWork(); UnknownStateAndRoutingDoNotClaimPause();
        RejectedOrIgnoredPauseIsBoundedAndNeverRetried(); RunnerRequiresValidSuccessfulReply();
        RunnerTimeoutAndCancellationCannotProduceLateSuccess();
        puts("9 disconnect pause tests passed (fake players and child processes; no live playback commands).");
    }
    return 0;
}
