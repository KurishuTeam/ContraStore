#ifndef CONTRA_SHARED_COMMON_H
#define CONTRA_SHARED_COMMON_H

#import <Foundation/Foundation.h>
#import <libroot.h>
#import <rootless.h>
#import <xpc/xpc.h>

#define CONTRA_XPC_SERVICE_NAME "com.kurishu.contrainstalld.service"

#ifdef __cplusplus
extern "C" {
#endif

/// Returns a shared, active C-level XPC connection to contrainstalld daemon
xpc_connection_t get_contrainstalld_xpc_connection(void);

/// Sends an XPC ping message to the daemon to verify connectivity
void send_xpc_ping(void);

/// Sends an XPC install request to the daemon with the specified IPA path
void send_xpc_install(const char *ipaPath);

/// Requests redirected and real paths for the specified bundle ID
void send_xpc_get_paths(const char *bundleId);

/// Helper to resolve rootless path using ROOT_PATH macro
const char *contra_root_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* CONTRA_SHARED_COMMON_H */
