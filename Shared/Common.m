#import "Common.h"
#import <SandyXpc/SandyXpc.h>
#import <libroot.h>
#import <rootless.h>

SandyXpcMessagingCenter *get_sandy_center(void) {
    static SandyXpcMessagingCenter *center = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        center = [SandyXpcMessagingCenter centerNamed:@CONTRA_XPC_SERVICE_NAME];
        NSLog(@"[ContraStore:SandyXPC] Initialized messaging center for %s", CONTRA_XPC_SERVICE_NAME);
    });
    return center;
}

void send_xpc_ping(void) {
    SandyXpcMessagingCenter *center = get_sandy_center();
    if (!center) {
        NSLog(@"[ContraStore:SandyXPC] Cannot send ping: center is nil");
        return;
    }

    NSLog(@"[ContraStore:SandyXPC] Sending ping to daemon...");
    BOOL sent = [center sendMessageName:@"ping" userInfo:@{}];
    NSLog(@"[ContraStore:SandyXPC] Ping message sent result: %d", sent);
}

void send_xpc_install(const char *ipaPath) {
    if (!ipaPath) {
        NSLog(@"[ContraStore:SandyXPC] send_xpc_install received NULL path");
        return;
    }

    SandyXpcMessagingCenter *center = get_sandy_center();
    if (!center) {
        NSLog(@"[ContraStore:SandyXPC] Cannot send install: center is nil");
        return;
    }

    const char *resolvedPath = ROOT_PATH(ipaPath);
    NSString *pathStr = [NSString stringWithUTF8String:resolvedPath];
    NSDictionary *userInfo = @{
        @"path": pathStr ?: @""
    };

    NSLog(@"[ContraStore:SandyXPC] Sending install for path: %@", pathStr);
    BOOL sent = [center sendMessageName:@"install" userInfo:userInfo];
    NSLog(@"[ContraStore:SandyXPC] Install message sent result: %d", sent);
}

NSDictionary *send_xpc_get_paths_sync(const char *bundleId) {
    if (!bundleId) {
        return nil;
    }

    SandyXpcMessagingCenter *center = get_sandy_center();
    if (!center) {
        NSLog(@"[ContraStore:SandyXPC] Cannot send get_paths: center is nil");
        return nil;
    }

    NSString *bundleStr = [NSString stringWithUTF8String:bundleId];
    NSDictionary *dict = @{
        @"bundle_id": bundleStr ?: @""
    };

    NSLog(@"[ContraStore:SandyXPC] Requesting paths for bundle: %@", bundleStr);
    NSError *error = nil;
    NSDictionary *reply = [center sendMessageAndReceiveReplyName:@"get_paths" userInfo:dict error:&error];
    if (error || !reply) {
        NSLog(@"[ContraStore:SandyXPC] get_paths error: %@", error);
        return nil;
    }

    return reply;
}

const char *contra_root_path(const char *path) {
    if (!path) {
        return NULL;
    }
    return ROOT_PATH(path);
}
