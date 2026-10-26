#import <UIKit/UIKit.h>

%ctor {
   // file hooks
}

 
%hook NSFileManager

- (NSArray *)URLsForDirectory:(NSSearchPathDirectory)directory
                    inDomains:(NSSearchPathDomainMask)domainMask {
    NSArray *result = %orig;
    NSLog(@"[ContraRedirect] URLsForDirectory: %@", result);
    return result;
}

%end