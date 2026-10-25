#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ContraInstallerProtocol <NSObject>

- (void)installIpaAtPath:(NSString *)path withReply:(void (^)(NSError * _Nullable error))reply;

- (void)getPathsForBundleId:(NSString *)bundleId withReply:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable paths))reply;

@end

NS_ASSUME_NONNULL_END
