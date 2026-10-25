#import <Foundation/Foundation.h>
#import <SandyXpc/SandyXpc.h>
#import <rootless.h>
#import "Installer/ContraInstallerProtocol.h"
#import "contrainstalld-Swift.h"

#define CONTRA_SERVICE_NAME @"com.kurishu.contrainstalld.service"

@interface DaemonMessageHandler : NSObject
- (NSDictionary *)handlePing:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)handleGetPaths:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
- (void)handleInstall:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
@end

@implementation DaemonMessageHandler

- (NSDictionary *)handlePing:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
    NSLog(@"[contrainstalld] Received ping request");
    return @{@"status": @"ok", @"message": @"pong"};
}

- (NSDictionary *)handleGetPaths:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
    NSString *bundleId = userInfo[@"bundle_id"] ?: @"";
    NSLog(@"[contrainstalld] Received get_paths request for bundle_id: %@", bundleId);
    return @{
        @"bundle_id": bundleId,
        @"real_data": @"/var/mobile/",
        @"fake_data": @"/var/mobile/"
    };
}

- (void)handleInstall:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
    NSString *path = userInfo[@"path"];
    NSString *bundleId = userInfo[@"bundle_id"];
    NSLog(@"[contrainstalld] Received install request for path: %@, bundle_id: %@", path, bundleId);

    if (path.length > 0 && bundleId.length > 0) {
        ContraInstaller *installer = [[ContraInstaller alloc] init];
        [installer installIpaAtPath:path bundleId:bundleId withReply:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[contrainstalld] Installation failed for %@ with error: %@", bundleId, error);
            } else {
                NSLog(@"[contrainstalld] Installation succeeded for %@", bundleId);
            }
        }];
    } else {
        NSLog(@"[contrainstalld] Install request rejected: missing path or bundle_id");
    }
}

@end

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        NSLog(@"[contrainstalld] Starting daemon for %@", CONTRA_SERVICE_NAME);

        DaemonMessageHandler *handler = [[DaemonMessageHandler alloc] init];
        SandyXpcMessagingCenter *center = [SandyXpcMessagingCenter centerNamed:CONTRA_SERVICE_NAME];

        [center registerForMessageName:@"ping" target:handler selector:@selector(handlePing:userInfo:)];
        [center registerForMessageName:@"get_paths" target:handler selector:@selector(handleGetPaths:userInfo:)];
        [center registerForMessageName:@"install" target:handler selector:@selector(handleInstall:userInfo:)];

        [center runServer];
        NSLog(@"[contrainstalld] Server running");

        dispatch_main();
    }
    return 0;
}
