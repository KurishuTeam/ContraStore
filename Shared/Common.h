#ifndef COMMON_H
#define COMMON_H

#import <Foundation/Foundation.h>
#import <SandyXpc/SandyXpc.h>
#import "ContraInstallerProtocol.h"

#ifdef __cplusplus
extern "C" {
#endif

// Synchronously pings the daemon to verify communication and health
NSDictionary *send_xpc_ping_sync(void);

// Synchronously retrieves path mappings for the given bundle identifier
NSDictionary *send_xpc_get_paths_sync(NSString *bundleId);

#ifdef __cplusplus
}
#endif

// Client adapter implementing ContraInstallerProtocol via SandyXpc
@interface ContraInstallerClient : NSObject <ContraInstallerProtocol>

+ (instancetype)sharedClient;

- (nullable NSDictionary<NSString *, NSString *> *)getPaths:(NSString *)bundleId;
- (void)installIpaAtPath:(NSString *)ipaPath bundleId:(NSString *)bundleId withReply:(void (^)(NSError * _Nullable error))reply;

@end

#endif /* COMMON_H */
