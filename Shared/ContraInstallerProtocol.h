#ifndef CONTRA_INSTALLER_PROTOCOL_H
#define CONTRA_INSTALLER_PROTOCOL_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Key macros for ContraStore path mappings
#define CSBundleIDKey @"bundleID"
#define CSFakeBundlePathKey @"fakeBundlePath"
#define CSSystemBundlePathKey @"systemBundlePath"
#define CSFakeDataPathKey @"fakeDataPath"
#define CSSystemDataPathKey @"systemDataPath"

@protocol ContraInstallerProtocol <NSObject>

- (void)installIpaAtPath:(NSString *)ipaPath bundleId:(NSString *)bundleId withReply:(void (^)(NSError * _Nullable error))reply;
- (nullable NSDictionary<NSString *, NSString *> *)getPaths:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END

#endif /* CONTRA_INSTALLER_PROTOCOL_H */
