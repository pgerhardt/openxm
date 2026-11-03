// Uses a fake HAL and fake AVRCP replies. Never opens Bluetooth or changes audio.
#import "CodecVolumeSync.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Volume sync test failed at line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)

@interface FakeVolumeDevice : NSObject <CodecVolumeDevice>
@property (nonatomic) float value;
@property BOOL hardware;
@property BOOL failHardware;
@property BOOL failWrite;
@property (copy) void (^changed)(void);
@end
@implementation FakeVolumeDevice
- (BOOL)attachWithChangeHandler:(void (^)(void))handler { self.changed = handler; return YES; }
- (BOOL)readScalar:(float *)value { *value = self.value; return YES; }
- (BOOL)setScalar:(float)value {
    if (self.failWrite) return NO;
    self.value = value;
    if (self.changed) self.changed(); // Also catches feedback loops with synchronous delivery.
    return YES;
}
- (BOOL)setHardwareMode:(BOOL)enabled {
    if (enabled && self.failHardware) return NO;
    self.hardware = enabled; return YES;
}
- (void)detach { self.changed = nil; }
@end

static void HeadphoneLevelWinsAndNoFeedback(void) {
    FakeVolumeDevice *device = [FakeVolumeDevice new]; device.value = 1;
    CodecVolumeSync *sync = [[CodecVolumeSync alloc] initWithDevice:device];
    __block int sends = 0;
    sync.sendVolumeHandler = ^BOOL(int volume, CodecVolumeReply reply) { sends++; reply(YES, volume); return YES; };
    CHECK([sync start]); CHECK(!sync.ready && !device.hardware);
    [sync remoteVolumeChanged:34];
    CHECK(sync.ready && device.hardware && sync.confirmedVolume == 34);
    CHECK(fabs(device.value - 34 / 127.0f) < 0.00001 && sends == 0);
    // A physical headset button changes only the display; it is not echoed back.
    [sync remoteVolumeChanged:29];
    CHECK(fabs(device.value - 29 / 127.0f) < 0.00001 && sends == 0);
    [device setScalar:0.5];
    CHECK(sends == 1 && sync.confirmedVolume == 64);
    [sync stop]; CHECK(!device.hardware && !sync.ready);
}

static void CoalescesAndUsesAcceptedValue(void) {
    FakeVolumeDevice *device = [FakeVolumeDevice new];
    CodecVolumeSync *sync = [[CodecVolumeSync alloc] initWithDevice:device];
    NSMutableArray<NSNumber *> *sent = [NSMutableArray array];
    __block CodecVolumeReply pending;
    sync.sendVolumeHandler = ^BOOL(int volume, CodecVolumeReply reply) {
        [sent addObject:@(volume)]; pending = [reply copy]; return YES;
    };
    CHECK([sync start]); [sync remoteVolumeChanged:34];
    [device setScalar:0.4]; [device setScalar:0.5]; [device setScalar:0.6];
    CHECK(sent.count == 1 && sent[0].intValue == 51);
    CHECK(sync.confirmedVolume == 34); // Sending alone is not acceptance.
    [sync remoteVolumeChanged:51]; // A notification must not overwrite the later drag.
    CHECK(fabs(device.value - 0.6) < 0.00001);
    CodecVolumeReply first = pending; first(YES, 50);
    CHECK(sent.count == 2 && sent[1].intValue == 76);
    CodecVolumeReply second = pending; second(YES, 75); // Headset quantizes the requested value.
    CHECK(sync.confirmedVolume == 75 && fabs(device.value - 75 / 127.0f) < 0.00001);
    CHECK(sent.count == 2);
    [sync stop];
}

static void FailureAndLateReplyCannotReenableSync(void) {
    FakeVolumeDevice *device = [FakeVolumeDevice new];
    CodecVolumeSync *sync = [[CodecVolumeSync alloc] initWithDevice:device];
    __block CodecVolumeReply pending;
    __block int failures = 0;
    sync.failureHandler = ^(NSString *message) { failures++; };
    sync.sendVolumeHandler = ^BOOL(int volume, CodecVolumeReply reply) { pending = [reply copy]; return YES; };
    CHECK([sync start]); [sync remoteVolumeChanged:34]; [device setScalar:0.4];
    CodecVolumeReply stale = pending;
    [sync stop]; stale(YES, 51);
    CHECK(!sync.ready && !device.hardware && sync.confirmedVolume == -1);
    CHECK([sync start]); [sync remoteVolumeChanged:34]; [device setScalar:0.4];
    pending(NO, -1);
    CHECK(failures == 1 && !sync.ready && !device.hardware);
    CHECK([sync start]); [sync remoteVolumeChanged:34]; [sync remoteVolumeChanged:-1];
    CHECK(failures == 2 && !sync.ready && !device.hardware);
}

static void HardwareAndPropertyFailuresAreNotSuccess(void) {
    FakeVolumeDevice *device = [FakeVolumeDevice new];
    CodecVolumeSync *sync = [[CodecVolumeSync alloc] initWithDevice:device];
    __block int failures = 0;
    sync.failureHandler = ^(NSString *message) { failures++; };
    CHECK([sync start]); device.failHardware = YES; [sync remoteVolumeChanged:34];
    CHECK(failures == 1 && !sync.ready && !device.hardware);
    device.failHardware = NO;
    CHECK([sync start]); [sync remoteVolumeChanged:34];
    device.value = NAN; device.changed();
    CHECK(failures == 2 && !sync.ready && !device.hardware);
    device.failWrite = YES; CHECK(![sync start]);
}

static void AppVolumeUsesAcknowledgedMacPath(void) {
    FakeVolumeDevice *device = [FakeVolumeDevice new];
    CodecVolumeSync *sync = [[CodecVolumeSync alloc] initWithDevice:device];
    __block CodecVolumeReply pending;
    __block int sends = 0;
    sync.sendVolumeHandler = ^BOOL(int volume, CodecVolumeReply reply) {
        CHECK(volume == 25); sends++; pending = [reply copy]; return YES;
    };
    CHECK(![sync setLocalVolume:25]);
    CHECK([sync start]); [sync remoteVolumeChanged:56];
    CHECK(![sync setLocalVolume:128]);
    CHECK([sync setLocalVolume:25]);
    CHECK(sends == 1 && sync.confirmedVolume == 56); // No optimistic confirmation.
    pending(YES, 25);
    CHECK(sync.confirmedVolume == 25 && fabs(device.value - 25 / 127.0f) < 0.00001);
    [sync stop];
    CHECK(![sync setLocalVolume:25]);
}

int main(void) {
    @autoreleasepool {
        HeadphoneLevelWinsAndNoFeedback();
        CoalescesAndUsesAcceptedValue();
        FailureAndLateReplyCannotReenableSync();
        HardwareAndPropertyFailuresAreNotSuccess();
        AppVolumeUsesAcknowledgedMacPath();
        puts("5 volume synchronization tests passed (fake audio device, no live changes).");
    }
    return 0;
}
