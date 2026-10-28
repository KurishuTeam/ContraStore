#import <Foundation/Foundation.h>

@interface AppResigner : NSObject

+ (BOOL)resignAppBundleAtPath:(NSString *)bundlePath withEntitlements:(NSString *)entitlementsPath error:(NSError **)error;

@end
