#import <Foundation/Foundation.h>
#import <libSandy.h>
#import "ContraXPCClient.h"
#import "ContraInstaller.h"

static NSDictionary<NSString *, NSString *> *registeredPaths = nil;

static NSString *dataPathAppendingPathComponent(NSString *component) {
    @autoreleasepool {
        if (registeredPaths) { // Fixed: changed registeredPath to registeredPaths
            NSString *dataPath = registeredPaths[CSFakeDataPathKey];
            NSString *path = [dataPath stringByAppendingPathComponent:component];
            return path;
        } else {
            return nil;
        }
    } 
}   

%group RedirectionHooks

%hookf(NSString *, NSHomeDirectory) {
    NSString *fakeDataPath = registeredPaths[CSFakeDataPathKey];
    return fakeDataPath;
} 

%hookf(NSString *, NSTemporaryDirectory) {
    NSString *tmp = dataPathAppendingComponent(@"tmp");
    return tmp;
} 

%hook NSFileManager

- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory
                             inDomains:(NSSearchPathDomainMask)domainMask {
    if (domainMask != NSUserDomainMask) {
        return %orig;
    } 

    switch (directory) {
        case NSDocumentDirectory: {
            NSString *docPath = dataPathAppendingPathComponent(@"Documents");
            return docPath ? @[[NSURL fileURLWithPath:docPath]] : @[];
        }
        case NSLibraryDirectory: {
            NSString *libPath = dataPathAppendingPathComponent(@"Library");
            return libPath ? @[[NSURL fileURLWithPath:libPath]] : @[];
        }
        case NSCachesDirectory: {
            NSString *cachePath = dataPathAppendingPathComponent(@"Library/Caches");
            return cachePath ? @[[NSURL fileURLWithPath:cachePath]] : @[];
        }
        case NSApplicationSupportDirectory: {
            NSString *appSupportPath = dataPathAppendingPathComponent(@"Library/Application Support");
            return appSupportPath ? @[[NSURL fileURLWithPath:appSupportPath]] : @[];
        }
        default:
            return %orig;
    }
}

%end // %hook NSFileManager

%end // %group RedirectionHooks

static void setupClient() {
    NSDictionary *infoPlist = [[NSBundle mainBundle] infoDictionary];
    if (!infoPlist || infoPlist[@"NSExtension"] != nil) {
        return;
    }

    NSString *execPath = [[NSBundle mainBundle] executablePath];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!execPath || !bundleID) {
        return;
    }

    BOOL isApp = [execPath containsString:@"/Applications/"] || 
                [execPath containsString:@"/Containers/Bundle/Application/"];
    if (!isApp) {
        return;
    }

    if ([bundleID isEqualToString:@"com.kurishu.contrastore"] ||
        [bundleID isEqualToString:@"com.apple.springboard"]) {
        return;
    }

    int sandyres = libSandy_applyProfile("com.kurishu.contrainstalld");
    if (sandyres != kLibSandyErrorSuccess) {
        NSLog(@"[ContraRedirect] libSandy failed with code: %d", sandyres);
    }

    registeredPaths = [[ContraXPCClient sharedClient] fetchPathsSynchronouslyForBundleID:bundleID];

    if (registeredPaths && registeredPaths.count > 0) {
        NSLog(@"[ContraRedirect] Activating redirection for %@ -> %@", bundleID, registeredPaths);
        %init(RedirectionHooks);
    }
}

%ctor {
    @autoreleasepool {
        setupClient();
    } 
}

