#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ContraInstallerProtocol <NSObject>

- (void)installIpaAtPath:(NSString *)ipaPath bundleId:(NSString *)bundleId withReply:(void (^)(NSError * _Nullable error))reply;

@end

NS_ASSUME_NONNULL_END
