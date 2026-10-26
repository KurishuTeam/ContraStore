#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>

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
        g_pathMapping = send_xpc_get_paths_sync(bundleId);
        if (g_pathMapping) {
            NSLog(@"[ContraRedirect] Loaded path mapping for %@: %@", bundleId, g_pathMapping);
        }
    });
    return g_pathMapping;
}

static NSString *normalize_path(NSString *path) {
    if (!path || path.length == 0) {
        return path;
    }
    // Strip /private prefix if present
    NSString *norm = [path hasPrefix:@"/private"] ? [path substringFromIndex:8] : path;
    // Strip trailing slash for uniform boundary matching
    if (norm.length > 1 && [norm hasSuffix:@"/"]) {
        norm = [norm substringToIndex:norm.length - 1];
    }
    return norm;
}

static NSString *replace_prefix_if_matching(NSString *normPath, NSString *fakePrefix, NSString *realPrefix) {
    if (!fakePrefix || !realPrefix || fakePrefix.length == 0 || realPrefix.length == 0) {
        return nil;
    }

    NSString *normFake = normalize_path(fakePrefix);
    NSString *normReal = normalize_path(realPrefix);

    // Exact match for the container directory itself
    if ([normPath isEqualToString:normFake]) {
        return normReal;
    }

    // Match child path strictly with path component boundary '/'
    NSString *boundary = [normFake stringByAppendingString:@"/"];
    if ([normPath hasPrefix:boundary]) {
        NSString *subpath = [normPath substringFromIndex:boundary.length];
        return [normReal stringByAppendingPathComponent:subpath];
    }

    return nil;
}

static NSString *get_real_path(NSString *fakePath) {
    if (!fakePath || ![fakePath isKindOfClass:[NSString class]] || fakePath.length == 0) {
        return fakePath;
    }

    NSDictionary *mapping = get_app_path_mapping();
    if (!mapping) {
        return fakePath;
    }

    NSString *normFakePath = normalize_path(fakePath);

    // 1. Data Path Redirection
    NSString *fakeData = mapping[@"fake_data_path"];
    NSString *systemData = mapping[@"real_data_path"];
    NSString *redirected = replace_prefix_if_matching(normFakePath, fakeData, systemData);
    if (redirected) {
        NSLog(@"[ContraRedirect] Redirected Data: %@ -> %@", fakePath, redirected);
        return redirected;
    }

    // 2. Bundle Path Redirection
    NSString *fakeBundle = mapping[@"fake_bundle_path"];
    NSString *systemBundle = mapping[@"real_bundle_path"];
    redirected = replace_prefix_if_matching(normFakePath, fakeBundle, systemBundle);
    if (redirected) {
        NSLog(@"[ContraRedirect] Redirected Bundle: %@ -> %@", fakePath, redirected);
        return redirected;
    }

    return fakePath;
}

#pragma mark - Phase 2: Hook Objective-C (NSFileManager)

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    NSString *realPath = get_real_path(path);
    return %orig(realPath);
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attr {
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

    // Fast-path: immediately bypass non-/var paths without objective-c overhead
    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_fopen ? orig_fopen(path, mode) : NULL;
    }

    if (!get_app_path_mapping()) {
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

    // Fast-path: immediately bypass non-/var paths without objective-c overhead
    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_stat ? orig_stat(path, buf) : -1;
    }

    if (!get_app_path_mapping()) {
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

    // Fast-path: immediately bypass non-/var paths without objective-c overhead
    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_lstat ? orig_lstat(path, buf) : -1;
    }

    if (!get_app_path_mapping()) {
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

        MSHookFunction((void *)fopen, (void *)new_fopen, (void **)&orig_fopen);
        MSHookFunction((void *)stat, (void *)new_stat, (void **)&orig_stat);
        MSHookFunction((void *)lstat, (void *)new_lstat, (void **)&orig_lstat);

        NSLog(@"[ContraRedirect] Hooks installed successfully.");
    }
}
