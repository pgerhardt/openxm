// Exercises actual route ownership/journal policy with fake devices and a fake
// clock. Does not enumerate hardware, change volume or open Bluetooth.
#import "CodecAudioRoute.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "Audio route test failed at line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

@interface FakeOutputs : NSObject <CodecAudioOutputs>
@property NSString *current;
@property NSArray<CodecAudioOutput *> *devices;
@property NSMutableArray<NSString *> *writes;
@property NSSet<NSString *> *refused;
@property (copy) void (^duringDiscovery)(void);
@property (copy) void (^duringSelection)(void);
@end
@implementation FakeOutputs
- (NSString *)currentOutputUID { return self.current; }
- (NSArray *)availableOutputs {
    if (self.duringDiscovery) { void (^action)(void) = self.duringDiscovery; self.duringDiscovery = nil; action(); }
    return self.devices;
}
- (BOOL)selectOutput:(NSString *)uid {
    [self.writes addObject:uid];
    if (self.duringSelection) { self.duringSelection(); return NO; }
    if ([self.refused containsObject:uid]) return NO;
    self.current = uid; return YES;
}
@end

static CodecAudioOutput *Output(NSString *uid, BOOL physical, BOOL bluetooth, BOOL builtIn) {
    CodecAudioOutput *output = [CodecAudioOutput new]; output.uid = uid; output.name = uid;
    output.physical = physical; output.wireless = bluetooth; output.builtIn = builtIn;
    return output;
}
static NSArray *Devices(BOOL headphones) {
    NSMutableArray *devices = [@[
        Output(@"virtual", NO, NO, NO), Output(@"USB speakers", YES, NO, NO),
        Output(@"Other Bluetooth", YES, YES, NO), Output(@"Other virtual", NO, NO, NO),
        Output(@"Mac speakers", YES, NO, YES)] mutableCopy];
    if (headphones) [devices addObject:Output(@"headphones", YES, YES, NO)];
    return devices;
}
@interface Fixture : NSObject
@property FakeOutputs *outputs;
@property CodecAudioRoute *route;
@property NSString *directory;
@property NSString *journal;
@end
@implementation Fixture
- (instancetype)init {
    if ((self = [super init])) {
        _directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        CHECK([[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil]);
        _journal = [_directory stringByAppendingPathComponent:@"route.plist"];
        _outputs = [FakeOutputs new]; _outputs.current = @"headphones"; _outputs.devices = Devices(YES); _outputs.writes = [NSMutableArray new];
        _route = [[CodecAudioRoute alloc] initWithOutputs:_outputs journal:_journal virtualUID:@"virtual"];
    }
    return self;
}
- (void)dealloc { [[NSFileManager defaultManager] removeItemAtPath:_directory error:nil]; }
@end
static void Take(Fixture *f) { CHECK([f.route prepare]); CHECK([f.route take]); [f.outputs.writes removeAllObjects]; }
static BOOL Journal(Fixture *f) { return [[NSFileManager defaultManager] fileExistsAtPath:f.journal]; }
static CodecAudioRoute *Recovered(Fixture *f) {
    CodecAudioRoute *route = [[CodecAudioRoute alloc] initWithOutputs:f.outputs journal:f.journal virtualUID:@"virtual"];
    [route beginRecoveryAt:100 grace:0 waitForOriginal:0]; return route;
}

static void PowerOffFallsBackAfterGrace(void) {
    Fixture *f = [Fixture new]; Take(f); [f.route confirmReady]; f.outputs.devices = Devices(NO);
    [f.route beginRecoveryAt:100 grace:3 waitForOriginal:3];
    CHECK([f.route recoverAt:102.99] == CodecRoutePending && f.outputs.writes.count == 0 && Journal(f));
    CHECK([f.route recoverAt:103] == CodecRouteRestored && [f.outputs.current isEqual:@"Mac speakers"]);
    CHECK(f.route.usedFallback && [f.route.restoredOutputName isEqual:@"Mac speakers"] && !Journal(f));
}
static void ReconnectedHeadphonesWin(void) {
    Fixture *f = [Fixture new]; Take(f); f.outputs.devices = Devices(NO);
    [f.route beginRecoveryAt:100 grace:3 waitForOriginal:3];
    CHECK([f.route recoverAt:101] == CodecRoutePending);
    f.outputs.devices = Devices(YES);
    CHECK([f.route recoverAt:103] == CodecRouteRestored && [f.outputs.current isEqual:@"headphones"] && !f.route.usedFallback);
}
static void CodecSwitchKeepsSilenceAndHasFixedDeadline(void) {
    Fixture *f = [Fixture new]; Take(f); f.outputs.devices = Devices(NO);
    [f.route beginTransitionAt:100 timeout:35];
    [f.route beginTransitionAt:120 timeout:35]; // Repeated connecting reports cannot extend the deadline.
    CHECK(![f.route transitionExpiredAt:134.99]);
    CHECK([f.route transitionExpiredAt:135]);
    CHECK([f.route recoverAt:200] == CodecRoutePending && f.outputs.writes.count == 0);
    [f.route confirmReady]; CHECK(![f.route transitionExpiredAt:200]);
    [f.route beginTransitionAt:200 timeout:35];
    CHECK([f.route transitionExpiredAt:235]);
    [f.route beginRecoveryAt:235 grace:3 waitForOriginal:3];
    CHECK([f.route recoverAt:237] == CodecRoutePending);
    CHECK([f.route recoverAt:238] == CodecRouteRestored);
}
static void NativeHandbackWaitsForOriginal(void) {
    Fixture *f = [Fixture new]; Take(f); f.outputs.devices = Devices(NO);
    [f.route beginRecoveryAt:100 grace:0 waitForOriginal:10];
    CHECK([f.route recoverAt:103] == CodecRoutePending && f.outputs.writes.count == 0);
    f.outputs.devices = Devices(YES);
    CHECK([f.route recoverAt:104] == CodecRouteRestored && [f.outputs.current isEqual:@"headphones"]);
    Fixture *missing = [Fixture new]; Take(missing); missing.outputs.devices = Devices(NO);
    [missing.route beginRecoveryAt:100 grace:0 waitForOriginal:10];
    CHECK([missing.route recoverAt:109.99] == CodecRoutePending);
    CHECK([missing.route recoverAt:110] == CodecRouteRestored && missing.route.usedFallback);
}
static void UserChoiceWinsAndCannotBeReacquired(void) {
    Fixture *f = [Fixture new]; Take(f); [f.route beginTransitionAt:100 timeout:35];
    f.outputs.current = @"USB speakers";
    CHECK([f.route observeOutputChange] && !Journal(f));
    f.outputs.current = @"virtual"; // Late callbacks must not undo a later explicit choice either.
    CHECK(![f.route take]);
    [f.route beginRecoveryAt:100 grace:3 waitForOriginal:3];
    CHECK([f.route recoverAt:104] == CodecRoutePreserved && f.outputs.writes.count == 0);
    Fixture *duringGrace = [Fixture new]; Take(duringGrace);
    [duringGrace.route beginRecoveryAt:100 grace:3 waitForOriginal:3];
    duringGrace.outputs.current = @"USB speakers";
    CHECK([duringGrace.route recoverAt:101] == CodecRoutePreserved && duringGrace.outputs.writes.count == 0);
}
static void RemembersWiredOutputAcrossSessions(void) {
    Fixture *f = [Fixture new]; f.outputs.current = @"USB speakers"; Take(f);
    [f.route beginRecoveryAt:100 grace:0 waitForOriginal:10];
    CHECK([f.route recoverAt:100] == CodecRouteRestored && [f.outputs.current isEqual:@"USB speakers"]);
    f.outputs.current = @"headphones";
    f.route = [[CodecAudioRoute alloc] initWithOutputs:f.outputs journal:f.journal virtualUID:@"virtual"];
    Take(f); f.outputs.devices = Devices(NO);
    CHECK([Recovered(f) recoverAt:100] == CodecRouteRestored && [f.outputs.current isEqual:@"USB speakers"]);
}
static void UnavailableRememberedOutputUsesSpeakers(void) {
    Fixture *f = [Fixture new]; f.outputs.current = @"USB speakers"; Take(f);
    f.outputs.devices = @[Output(@"virtual", NO, NO, NO), Output(@"Mac speakers", YES, NO, YES)];
    CHECK([Recovered(f) recoverAt:100] == CodecRouteRestored && [f.outputs.current isEqual:@"Mac speakers"]);
}
static void NoPhysicalOutputRetainsRecoveryJournal(void) {
    Fixture *f = [Fixture new]; Take(f);
    f.outputs.devices = @[Output(@"virtual", NO, NO, NO), Output(@"Other virtual", NO, NO, NO), Output(@"Other Bluetooth", YES, YES, NO)];
    CodecAudioRoute *recovery = Recovered(f);
    CHECK([recovery recoverAt:100] == CodecRouteFailed && Journal(f) && f.outputs.writes.count == 0);
    f.outputs.devices = Devices(NO);
    CHECK([Recovered(f) recoverAt:101] == CodecRouteRestored && !Journal(f));
}
static void FailedSelectionUsesNextAvailableOutput(void) {
    Fixture *f = [Fixture new]; Take(f);
    f.outputs.refused = [NSSet setWithArray:@[@"headphones", @"Mac speakers"]];
    CHECK([Recovered(f) recoverAt:100] == CodecRouteRestored && [f.outputs.current isEqual:@"USB speakers"]);
    CHECK(([f.outputs.writes isEqual:@[@"headphones", @"Mac speakers", @"USB speakers"]]));
}
static void CrashRecoveryPreservesUserChoiceAndRejectsLiveOwner(void) {
    Fixture *f = [Fixture new]; Take(f); f.outputs.current = @"USB speakers";
    CHECK([Recovered(f) recoverAt:100] == CodecRoutePreserved && f.outputs.writes.count == 0 && !Journal(f));
    Fixture *live = [Fixture new]; Take(live);
    NSMutableDictionary *record = [[NSDictionary dictionaryWithContentsOfFile:live.journal] mutableCopy];
    record[@"pid"] = @(getppid()); CHECK([record writeToFile:live.journal atomically:YES]);
    CHECK([Recovered(live) recoverAt:100] == CodecRouteFailed && Journal(live) && live.outputs.writes.count == 0);
}
static void UserSelectionDuringDiscoveryOrFailedWriteWins(void) {
    Fixture *f = [Fixture new]; Take(f);
    __weak FakeOutputs *outputs = f.outputs;
    f.outputs.duringDiscovery = ^{ outputs.current = @"USB speakers"; };
    CHECK([Recovered(f) recoverAt:100] == CodecRoutePreserved && f.outputs.writes.count == 0);
    Fixture *write = [Fixture new]; Take(write);
    __weak FakeOutputs *other = write.outputs;
    write.outputs.duringSelection = ^{ other.current = @"USB speakers"; };
    CHECK([Recovered(write) recoverAt:100] == CodecRoutePreserved && [write.outputs.writes isEqual:@[@"headphones"]]);
}
static void UnknownDefaultOrCorruptJournalNeverChangesOutput(void) {
    Fixture *f = [Fixture new]; Take(f); f.outputs.current = nil;
    CHECK([Recovered(f) recoverAt:100] == CodecRouteFailed && Journal(f) && f.outputs.writes.count == 0);
    NSDictionary *invalid = @{@"virtualUID": @"virtual", @"previousUID": @"headphones", @"pid": @[]};
    CHECK([invalid writeToFile:f.journal atomically:YES]);
    CHECK([Recovered(f) recoverAt:100] == CodecRouteFailed && Journal(f) && f.outputs.writes.count == 0);
    f.outputs.current = @"virtual";
    CHECK([@"broken" writeToFile:f.journal atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    CHECK([Recovered(f) recoverAt:100] == CodecRouteFailed && Journal(f) && f.outputs.writes.count == 0);
}
static void InitialTakeoverIsJournaledAndProtected(void) {
    Fixture *f = [Fixture new]; CHECK([f.route prepare]);
    [f.route beginTransitionAt:100 timeout:45]; CHECK([f.route take]);
    CHECK(Journal(f) && [f.outputs.current isEqual:@"virtual"] && ![f.route transitionExpiredAt:144]);
    f.outputs.devices = Devices(NO);
    CHECK([f.route recoverAt:120] == CodecRoutePending); // Negotiation alone never triggers fallback.
    CHECK([f.route transitionExpiredAt:145]);
    [f.route beginRecoveryAt:145 grace:3 waitForOriginal:3];
    CHECK([f.route recoverAt:148] == CodecRouteRestored);
    Fixture *changed = [Fixture new]; CHECK([changed.route prepare]);
    changed.outputs.current = @"USB speakers";
    CHECK(![changed.route take] && changed.outputs.writes.count == 0 && !Journal(changed));
}
static void PendingOrFailedPauseSurvivesCrashRecovery(void) {
    Fixture *f = [Fixture new]; Take(f); f.outputs.devices = Devices(NO);
    CHECK([f.route setPlaybackProtection:YES]);
    [f.route beginRecoveryAt:100 grace:3 waitForOriginal:3];
    CHECK([f.route recoverAt:105] == CodecRouteFailed && f.route.playbackBlocked && f.outputs.writes.count == 0);
    CodecAudioRoute *recovery = Recovered(f);
    CHECK([recovery recoverAt:110] == CodecRouteFailed && recovery.playbackBlocked && Journal(f));
    recovery.allowsUnpausedPlayback = YES;
    CHECK([recovery recoverAt:111] == CodecRouteRestored && !recovery.playbackBlocked && !Journal(f));
}
static void ConfirmedPauseOrManualChoiceReleasesProtection(void) {
    Fixture *f = [Fixture new]; Take(f); CHECK([f.route setPlaybackProtection:YES]);
    CHECK([f.route setPlaybackProtection:NO]);
    CHECK([Recovered(f) recoverAt:100] == CodecRouteRestored && !Journal(f));
    Fixture *manual = [Fixture new]; Take(manual); CHECK([manual.route setPlaybackProtection:YES]);
    manual.outputs.current = @"USB speakers";
    CodecAudioRoute *recovery = Recovered(manual);
    CHECK([recovery recoverAt:100] == CodecRoutePreserved && !recovery.playbackBlocked && manual.outputs.writes.count == 0 && !Journal(manual));
}
int main(void) {
    @autoreleasepool {
        PowerOffFallsBackAfterGrace(); ReconnectedHeadphonesWin(); CodecSwitchKeepsSilenceAndHasFixedDeadline();
        NativeHandbackWaitsForOriginal(); UserChoiceWinsAndCannotBeReacquired(); RemembersWiredOutputAcrossSessions();
        UnavailableRememberedOutputUsesSpeakers(); NoPhysicalOutputRetainsRecoveryJournal(); FailedSelectionUsesNextAvailableOutput();
        CrashRecoveryPreservesUserChoiceAndRejectsLiveOwner(); UserSelectionDuringDiscoveryOrFailedWriteWins();
        UnknownDefaultOrCorruptJournalNeverChangesOutput(); InitialTakeoverIsJournaledAndProtected();
        PendingOrFailedPauseSurvivesCrashRecovery(); ConfirmedPauseOrManualChoiceReleasesProtection();
        puts("15 audio route tests passed (fake devices/clock; no live audio changes).");
    }
    return 0;
}
