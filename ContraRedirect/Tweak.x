#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <stdio.h>
#include <sys/stat.h>

#import "Common.h"

#pragma mark - Phase 1: Helper Function & Prefix Replacement

static NSDictionary *g_pathMapping = nil;
static dispatch_once_t g_pathMappingOnce;

static NSDictionary *get_app_path_mapping(void) {
    dispatch_once(&g_pathMappingOnce, ^{
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleId || [bundleId hasPrefix:@"com.apple."]) {
            return;
        }
        g_pathMapping = send_xpc_get_paths_sync([bundleId UTF8String]);
        if (g_pathMapping) {
            NSLog(@"[ContraRedirect] Loaded path mapping for %@: %@", bundleId, g_pathMapping);
        }
    });
    return g_pathMapping;
}

static NSString *get_real_path(NSString *fakePath) {
    if (!fakePath || ![fakePath isKindOfClass:[NSString class]]) {
        return fakePath;
    }

    NSDictionary *mapping = get_app_path_mapping();
    if (!mapping) {
        return fakePath;
    }

    NSString *fakeData = mapping[@"fakeDataPath"];
    NSString *systemData = mapping[@"systemDataPath"];
    if (fakeData.length > 0 && systemData.length > 0) {
        NSString *normFakePath = [fakePath hasPrefix:@"/private"] ? [fakePath substringFromIndex:8] : fakePath;
        NSString *normFakeData = [fakeData hasPrefix:@"/private"] ? [fakeData substringFromIndex:8] : fakeData;

        if ([normFakePath hasPrefix:normFakeData]) {
            NSString *subpath = [normFakePath substringFromIndex:normFakeData.length];
            return [systemData stringByAppendingPathComponent:subpath];
        }
    }

    NSString *fakeBundle = mapping[@"fakeBundlePath"];
    NSString *systemBundle = mapping[@"systemBundlePath"];
    if (fakeBundle.length > 0 && systemBundle.length > 0) {
        NSString *normFakePath = [fakePath hasPrefix:@"/private"] ? [fakePath substringFromIndex:8] : fakePath;
        NSString *normFakeBundle = [fakeBundle hasPrefix:@"/private"] ? [fakeBundle substringFromIndex:8] : fakeBundle;

        if ([normFakePath hasPrefix:normFakeBundle]) {
            NSString *subpath = [normFakePath substringFromIndex:normFakeBundle.length];
            return [systemBundle stringByAppendingPathComponent:subpath];
        }
    }

    return fakePath;
}

#pragma mark - Phase 2: Hook Objective-C (NSFileManager)

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    NSLog(@"[ContraRedirect] NSFileManager fileExistsAtPath original: %@", path);
    NSString *realPath = get_real_path(path);
    return %orig(realPath);
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSLog(@"[ContraRedirect] NSFileManager contentsOfDirectoryAtPath original: %@", path);
    NSString *realPath = get_real_path(path);
    return %orig(realPath, error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attr {
    NSLog(@"[ContraRedirect] NSFileManager createFileAtPath original: %@", path);
    NSString *realPath = get_real_path(path);
    return %orig(realPath, data, attr);
}

%end

#pragma mark - Phase 3: Hook C Functions

static FILE *(*orig_fopen)(const char *path, const char *mode) = NULL;
static int (*orig_stat)(const char *path, struct stat *buf) = NULL;
static int (*orig_lstat)(const char *path, struct stat *buf) = NULL;

static FILE *new_fopen(const char *path, const char *mode) {
    if (!path) {
        return orig_fopen ? orig_fopen(path, mode) : NULL;
    }

    NSString *origPath = [NSString stringWithUTF8String:path];
    NSString *realPath = get_real_path(origPath);
    const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;

    return orig_fopen ? orig_fopen(finalPath, mode) : NULL;
}

static int new_stat(const char *path, struct stat *buf) {
    if (!path) {
        return orig_stat ? orig_stat(path, buf) : -1;
    }

    NSString *origPath = [NSString stringWithUTF8String:path];
    NSString *realPath = get_real_path(origPath);
    const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;

    return orig_stat ? orig_stat(finalPath, buf) : -1;
}

static int new_lstat(const char *path, struct stat *buf) {
    if (!path) {
        return orig_lstat ? orig_lstat(path, buf) : -1;
    }

    NSString *origPath = [NSString stringWithUTF8String:path];
    NSString *realPath = get_real_path(origPath);
    const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;

    return orig_lstat ? orig_lstat(finalPath, buf) : -1;
}

#pragma mark - Phase 4: Initialization (%ctor)

%ctor {
    @autoreleasepool {
        NSLog(@"[ContraRedirect] Initializing ContraRedirect hook engine...");

        get_sandy_center();

        MSHookFunction((void *)fopen, (void *)new_fopen, (void **)&orig_fopen);
        MSHookFunction((void *)stat, (void *)new_stat, (void **)&orig_stat);
        MSHookFunction((void *)lstat, (void *)new_lstat, (void **)&orig_lstat);

        NSLog(@"[ContraRedirect] Hooks installed successfully.");
    }
}
