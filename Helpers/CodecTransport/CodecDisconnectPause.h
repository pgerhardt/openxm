#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Owns one bounded invocation of the bundled media adapter. Called on the main
// queue; teardown and route recovery continue while it checks/pause-verifies.
@interface CodecDisconnectPause : NSObject
@property (nonatomic, readonly) NSString *status;
@property (nonatomic, readonly) BOOL pending;
@property (nonatomic, readonly) BOOL allowsRecovery;
- (instancetype)initWithExecutable:(NSURL *)executable arguments:(NSArray<NSString *> *)arguments;
+ (instancetype)bundled;
- (void)startAt:(NSTimeInterval)now;
- (void)pollAt:(NSTimeInterval)now;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
