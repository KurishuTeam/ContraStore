#import "Common.h"

#define CONTRA_SERVICE_NAME @"com.kurishu.contrainstalld.service"

NSDictionary *send_xpc_ping_sync(void) {
    // Acquire messaging center for the contrainstalld service
    SandyXpcMessagingCenter *center = [SandyXpcMessagingCenter centerNamed:CONTRA_SERVICE_NAME];
    if (!center) {
        NSLog(@"[ContraStore:XPC] Failed to get messaging center for %@", CONTRA_SERVICE_NAME);
        return nil;
    }

    NSLog(@"[ContraStore:XPC] Sending synchronous ping to daemon...");
    NSError *error = nil;
    NSDictionary *reply = [center sendMessageAndReceiveReplyName:@"ping" userInfo:@{} error:&error];
    if (error) {
        NSLog(@"[ContraStore:XPC] Ping failed with error: %@", error);
        return nil;
    }

    NSLog(@"[ContraStore:XPC] Ping reply received: %@", reply);
    return reply;
}

NSDictionary *send_xpc_get_paths_sync(NSString *bundleId) {
    // Guard against nil input to avoid invalid dictionary creation or unnecessary IPC
    if (!bundleId) {
        NSLog(@"[ContraStore:XPC] send_xpc_get_paths_sync called with nil bundleId");
        return nil;
    }

    SandyXpcMessagingCenter *center = [SandyXpcMessagingCenter centerNamed:CONTRA_SERVICE_NAME];
    if (!center) {
        NSLog(@"[ContraStore:XPC] Failed to get messaging center for %@", CONTRA_SERVICE_NAME);
        return nil;
    }

    NSLog(@"[ContraStore:XPC] Requesting paths for bundleId: %@", bundleId);
    NSDictionary *userInfo = @{
        CSBundleIDKey: bundleId,
        @"bundle_id": bundleId
    };
    NSError *error = nil;
    NSDictionary *reply = [center sendMessageAndReceiveReplyName:@"get_paths" userInfo:userInfo error:&error];
    if (error) {
        NSLog(@"[ContraStore:XPC] get_paths failed for %@ with error: %@", bundleId, error);
        return nil;
    }

    NSLog(@"[ContraStore:XPC] get_paths reply received for %@: %@", bundleId, reply);
    return reply;
}

@implementation ContraInstallerClient

+ (instancetype)sharedClient {
    static ContraInstallerClient *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[ContraInstallerClient alloc] init];
    });
    return sharedInstance;
}

- (nullable NSDictionary<NSString *, NSString *> *)getPaths:(NSString *)bundleId {
    return (NSDictionary<NSString *, NSString *> *)send_xpc_get_paths_sync(bundleId);
}

- (void)installIpaAtPath:(NSString *)ipaPath bundleId:(NSString *)bundleId withReply:(void (^)(NSError * _Nullable error))reply {
    if (!ipaPath || !bundleId) {
        if (reply) {
            NSError *error = [NSError errorWithDomain:@"com.kurishu.contrainstalld"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Missing ipaPath or bundleId"}];
            reply(error);
        }
        return;
    }

    SandyXpcMessagingCenter *center = [SandyXpcMessagingCenter centerNamed:CONTRA_SERVICE_NAME];
    if (!center) {
        if (reply) {
            NSError *error = [NSError errorWithDomain:@"com.kurishu.contrainstalld"
                                                 code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to connect to contrainstalld service"}];
            reply(error);
        }
        return;
    }

    NSDictionary *userInfo = @{
        @"path": ipaPath,
        @"bundle_id": bundleId,
        CSBundleIDKey: bundleId
    };
    [center sendMessageName:@"install" userInfo:userInfo];
    if (reply) {
        reply(nil);
    }
}

@end
