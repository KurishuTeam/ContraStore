#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <stdio.h>
#include <sys/stat.h>

#import "Common.h"

#pragma mark - Phase 1: Helper Function

static NSString *get_real_path(NSString *fakePath) {
    if (!fakePath || ![fakePath isKindOfClass:[NSString class]]) {
        return fakePath;
    }

    // Optimization: if not inside the fake sandbox container, return original immediately
    if (![fakePath hasPrefix:@"/var/mobile/Containers/Data/Application/"]) {
        return fakePath;
    }

    NSString *realPath = send_xpc_get_paths([fakePath UTF8String]);
    return realPath ?: fakePath;
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
