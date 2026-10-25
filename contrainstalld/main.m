#import <Foundation/Foundation.h>
#import <SandyXpc/SandyXpc.h>
#import "ContraInstallerProtocol.h"
#import "contrainstalld-Swift.h"

#define SERVICE_NAME @"com.kurishu.contrainstalld.service"

@interface DaemonMessageHandler : NSObject
- (void)handlePing:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
- (void)handleInstall:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)handleGetPaths:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
@end

@implementation DaemonMessageHandler

- (void)handlePing:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
    NSLog(@"[contrainstalld] Received ping from Client. (messageName=%@)", messageName);
}

- (void)handleInstall:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
    NSString *path = userInfo[@"path"];
    NSLog(@"[contrainstalld] Received install request for path: %@", path);
    if (path.length > 0) {
        ContraInstaller *installer = [ContraInstaller new];
        [installer installIpaAtPath:path withReply:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[contrainstalld] Installation failed with error: %@", error);
            } else {
                NSLog(@"[contrainstalld] Installation completed successfully for path: %@", path);
            }
        }];
    }
}

- (NSDictionary *)handleGetPaths:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
    NSString *fakePath = userInfo[@"fake_path"] ?: userInfo[@"path"];
    NSLog(@"[contrainstalld] Received get_paths for fake_path: %@", fakePath);

    if (fakePath.length > 0) {
        return @{
            @"real_path": fakePath,
            @"status": @"ok"
        };
    }

    return @{@"status": @"ok"};
}

@end

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        NSLog(@"[contrainstalld] Starting SandyXpc daemon for %@...", SERVICE_NAME);

        DaemonMessageHandler *handler = [DaemonMessageHandler new];
        SandyXpcMessagingCenter *center = [SandyXpcMessagingCenter centerNamed:SERVICE_NAME];

        [center registerForMessageName:@"ping" target:handler selector:@selector(handlePing:userInfo:)];
        [center registerForMessageName:@"install" target:handler selector:@selector(handleInstall:userInfo:)];
        [center registerForMessageName:@"get_paths" target:handler selector:@selector(handleGetPaths:userInfo:)];

        [center runServer];
        NSLog(@"[contrainstalld] SandyXpc daemon is listening for messages.");

        dispatch_main();
    }
    return 0;
}
