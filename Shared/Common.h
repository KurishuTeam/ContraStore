#ifndef CONTRA_SHARED_COMMON_H
#define CONTRA_SHARED_COMMON_H

#import <Foundation/Foundation.h>
#import <libroot.h>
#import <rootless.h>
#import <SandyXpc/SandyXpc.h>

#define CONTRA_XPC_SERVICE_NAME "com.kurishu.contrainstalld.service"

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the SandyXpcMessagingCenter instance for contrainstalld
SandyXpcMessagingCenter *get_sandy_center(void);

/// Sends an XPC ping message to the daemon using SandyXpc
void send_xpc_ping(void);

/// Sends an XPC install request to the daemon using SandyXpc with the specified IPA path
void send_xpc_install(const char *ipaPath);

/// Requests synchronous path resolution for fakePath from daemon via SandyXpc.
/// Returns a heap-allocated (strdup) C string which caller must free, or strdup(fakePath) if not mapped.
const char *send_xpc_get_paths_sync(const char *fakePath);

/// Requests paths for a bundle ID or fake path from the daemon using SandyXpc
NSString *send_xpc_get_paths(const char *pathOrBundleId);

/// Helper to resolve rootless path using ROOT_PATH macro
const char *contra_root_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* CONTRA_SHARED_COMMON_H */
