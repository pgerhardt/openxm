// Real AVRCP parsing/transactions over an in-memory socket; no Bluetooth access.
#import "AvrcpController.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "AVRCP volume test failed at line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)

@interface FakeSocket : NSObject
@property (copy) void (^packetHandler)(NSData *packet);
@property (copy) void (^closedHandler)(void);
@property NSMutableArray<NSData *> *sent;
- (BOOL)send:(NSData *)packet;
- (void)close;
@end
@implementation FakeSocket
- (instancetype)init { if ((self = [super init])) _sent = [NSMutableArray array]; return self; }
- (BOOL)send:(NSData *)packet { [self.sent addObject:packet]; return YES; }
- (void)close {}
@end

static void Reply(FakeSocket *socket, NSData *request, uint8_t ctype, uint8_t pdu, const uint8_t *values, size_t count) {
    const uint8_t *sent = request.bytes;
    uint8_t header[] = {(uint8_t)((sent[0] & 0xF0) | 2), 0x11, 0x0E, ctype, 0x48, 0,
                         0, 0x19, 0x58, pdu, 0, (uint8_t)(count >> 8), (uint8_t)count};
    NSMutableData *response = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [response appendBytes:values length:count];
    socket.packetHandler(response);
}

static AvrcpController *Start(FakeSocket *socket) {
    AvrcpController *controller = [[AvrcpController alloc] initWithSocket:(L2CAPSocket *)socket];
    [controller start];
    const uint8_t capabilities[] = {3, 1, 0x0D};
    Reply(socket, socket.sent.lastObject, 0xC, 0x10, capabilities, sizeof(capabilities));
    CHECK(controller.absoluteVolumeSupported);
    return controller;
}

static void NotificationsSurviveRepeatedVolumeWrites(void) {
    FakeSocket *socket = [FakeSocket new];
    AvrcpController *controller = Start(socket);
    __block int remote = -1;
    controller.volumeHandler = ^(int volume) { remote = volume; };
    NSData *subscription = socket.sent.lastObject;
    const uint8_t initial[] = {0x0D, 34};
    Reply(socket, subscription, 0xF, 0x31, initial, sizeof(initial));
    CHECK(remote == 34);
    for (int i = 0; i < 40; i++) {
        __block int accepted = -1;
        [controller setAbsoluteVolume:40 + i completion:^(BOOL success, int actual) { CHECK(success); accepted = actual; }];
        NSData *request = socket.sent.lastObject;
        CHECK((((const uint8_t *)request.bytes)[0] >> 4) != (((const uint8_t *)subscription.bytes)[0] >> 4));
        uint8_t actual = (uint8_t)(39 + i);
        Reply(socket, request, 0x9, 0x50, &actual, 1);
        CHECK(accepted == actual);
    }
    const uint8_t changed[] = {0x0D, 29};
    Reply(socket, subscription, 0xD, 0x31, changed, sizeof(changed));
    CHECK(remote == 29);
    CHECK(((const uint8_t *)socket.sent.lastObject.bytes)[9] == 0x31);
    [controller close];
}

static void ReplyValidationAndTimeout(void) {
    FakeSocket *socket = [FakeSocket new];
    AvrcpController *controller = Start(socket);
    __block int replies = 0;
    [controller setAbsoluteVolume:42 completion:^(BOOL success, int actual) { CHECK(!success && actual == -1); replies++; }];
    NSData *request = socket.sent.lastObject;
    uint8_t value = 42;
    Reply(socket, request, 0x9, 0x31, &value, 1); // Same label, wrong command is not an acknowledgement.
    CHECK(replies == 0);
    Reply(socket, request, 0xA, 0x50, &value, 1);
    CHECK(replies == 1);
    [controller setAbsoluteVolume:43 completion:^(BOOL success, int actual) { CHECK(!success && actual == -1); replies++; }];
    value = 128;
    Reply(socket, socket.sent.lastObject, 0x9, 0x50, &value, 1);
    CHECK(replies == 2);
    [controller setAbsoluteVolume:44 completion:^(BOOL success, int actual) { CHECK(!success && actual == -1); replies++; }];
    request = socket.sent.lastObject;
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.1]];
    CHECK(replies == 3);
    value = 44; Reply(socket, request, 0x9, 0x50, &value, 1);
    CHECK(replies == 3); // A late reply cannot turn failure into success.
    [controller close];
}

int main(void) {
    @autoreleasepool {
        NotificationsSurviveRepeatedVolumeWrites();
        ReplyValidationAndTimeout();
        puts("2 AVRCP volume tests passed (in-memory socket, no live changes).");
    }
    return 0;
}
