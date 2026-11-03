#import "CodecDisconnectPause.h"
#include <signal.h>

@implementation CodecDisconnectPause {
    NSTask *_process;
    NSPipe *_output;
    NSTimeInterval _deadline;
}
- (instancetype)initWithExecutable:(NSURL *)executable arguments:(NSArray<NSString *> *)arguments {
    if ((self = [super init])) {
        _process = [NSTask new]; _process.executableURL = executable; _process.arguments = arguments;
        _process.standardInput = NSFileHandle.fileHandleWithNullDevice;
        _process.standardError = NSFileHandle.fileHandleWithNullDevice;
        _output = [NSPipe pipe]; _process.standardOutput = _output;
        _status = @"notRequested";
    }
    return self;
}
+ (instancetype)bundled {
    NSString *contents = [NSProcessInfo.processInfo.arguments[0] stringByDeletingLastPathComponent].stringByDeletingLastPathComponent;
    return [[self alloc] initWithExecutable:[NSURL fileURLWithPath:@"/usr/bin/perl"] arguments:@[
        [contents stringByAppendingPathComponent:@"Resources/mediaremote-adapter.pl"],
        [contents stringByAppendingPathComponent:@"Frameworks/MediaRemoteAdapter.framework"], @"pause_disconnect"]];
}
- (BOOL)pending { return [_status isEqual:@"checking"]; }
- (BOOL)allowsRecovery { return [@[@"notRequested", @"paused", @"alreadyPaused", @"noPlayer", @"otherOutput", @"cancelled"] containsObject:_status]; }
- (void)startAt:(NSTimeInterval)now {
    if (![_status isEqual:@"notRequested"]) return;
    _status = @"checking"; _deadline = now + 5;
    if (![_process launchAndReturnError:nil]) _status = @"unavailable";
    [_output.fileHandleForWriting closeFile];
}
- (void)pollAt:(NSTimeInterval)now {
    if (!self.pending) return;
    if (_process.running) {
        if (now < _deadline) return;
        // The private API can hang. A timed-out child must never send a late
        // command after recovery or after a user chooses another output.
        kill(_process.processIdentifier, SIGKILL); _status = @"unconfirmed"; return;
    }
    NSData *data = [_output.fileHandleForReading readDataToEndOfFile];
    NSDictionary *result = data.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *status = [result isKindOfClass:NSDictionary.class] ? result[@"status"] : nil;
    NSArray *valid = @[@"paused", @"alreadyPaused", @"noPlayer", @"otherOutput", @"cancelled", @"unavailable", @"unconfirmed"];
    _status = _process.terminationStatus == 0 && [valid containsObject:status ?: @""] ? status : @"unconfirmed";
}
- (void)cancel {
    if (_process.running) kill(_process.processIdentifier, SIGKILL);
    _status = @"cancelled";
}
- (void)dealloc {
    if (_process.running) kill(_process.processIdentifier, SIGKILL);
    [_output.fileHandleForReading closeFile]; [_output.fileHandleForWriting closeFile];
}
@end
