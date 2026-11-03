// No media metadata is needed or saved. Pause applies only to the current player
// with freshly verified identity and exclusive output through OpenXM.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DisconnectPlayer : NSObject
@property pid_t pid;
@property (copy) NSString *bundleID;
@property BOOL playing;
- (BOOL)samePlayer:(DisconnectPlayer *)other;
@end
typedef NS_ENUM(NSInteger, DisconnectPlayerRoute) {
    DisconnectRouteUnknown = -1, DisconnectRouteElsewhere = 0, DisconnectRouteHeadphones = 1
};
@protocol DisconnectPlayback <NSObject>
- (BOOL)ownsOutput;
- (nullable DisconnectPlayer *)readPlayerBefore:(NSTimeInterval)deadline;
- (DisconnectPlayerRoute)routeForPlayer:(DisconnectPlayer *)player;
- (BOOL)sendPause; // Explicit Pause, never Toggle or Play.
- (NSTimeInterval)now;
- (void)waitForUpdate;
@end
// paused / alreadyPaused / noPlayer / otherOutput permit recovery. The caller
// handles cancelled by relinquishing to an observed user output choice.
// unavailable / unconfirmed retain silence and require an explicit output choice.
NSString *PauseMediaOnDisconnect(id<DisconnectPlayback> playback);
NS_ASSUME_NONNULL_END
