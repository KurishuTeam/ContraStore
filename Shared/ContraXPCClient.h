#import <Foundation/Foundation.h>
#import "ContraInstallerProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface ContraXPCClient : NSObject

+ (instancetype)sharedClient;

// async for UI
- (void)installIPA:(NSString *)ipaPath completion:(void (^)(NSError * _Nullable error))completion;
- (void)fetchPathsForBundleID:(NSString *)bundleID completion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable info))completion;

// sync for redirect
- (nullable NSDictionary<NSString *, NSString *> *)fetchPathsSynchronouslyForBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
