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

NSString *send_xpc_get_paths(const char *pathOrBundleId) {
    if (!pathOrBundleId) {
        NSLog(@"[ContraStore:SandyXPC] send_xpc_get_paths received NULL pathOrBundleId");
        return nil;
    }

    SandyXpcMessagingCenter *center = get_sandy_center();
    if (!center) {
        NSLog(@"[ContraStore:SandyXPC] Cannot send get_paths: center is nil");
        return [NSString stringWithUTF8String:pathOrBundleId];
    }

    NSString *inputStr = [NSString stringWithUTF8String:pathOrBundleId];
    NSDictionary *userInfo = @{
        @"path": inputStr ?: @"",
        @"bundle_id": [[NSBundle mainBundle] bundleIdentifier] ?: @""
    };

    NSLog(@"[ContraStore:SandyXPC] Sending get_paths for input: %@", inputStr);
    NSError *error = nil;
    NSDictionary *reply = [center sendMessageAndReceiveReplyName:@"get_paths" userInfo:userInfo error:&error];
    if (error || !reply) {
        NSLog(@"[ContraStore:SandyXPC] get_paths error: %@", error);
        return inputStr;
    }

    NSString *realPath = reply[@"real_path"] ?: reply[@"systemDataPath"] ?: reply[@"path"];
    if (realPath.length > 0) {
        return realPath;
    }

    return inputStr;
}

const char *contra_root_path(const char *path) {
    if (!path) {
        return NULL;
    }
    return ROOT_PATH(path);
}
