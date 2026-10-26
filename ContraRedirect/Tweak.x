#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <rootless.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <stdarg.h>

#import "Common.h"
#import "ContraInstallerProtocol.h"

#pragma mark - Path Mapping Cache & Resolution

static NSDictionary<NSString *, NSString *> *g_pathMapping = nil;
static dispatch_once_t g_pathMappingOnce;

static NSDictionary<NSString *, NSString *> *get_app_path_mapping(void) {
    dispatch_once(&g_pathMappingOnce, ^{
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleId || [bundleId hasPrefix:@"com.apple."]) {
            return;
        }

        // Query path mappings via ContraInstallerProtocol
        id<ContraInstallerProtocol> installer = [ContraInstallerClient sharedClient];
        g_pathMapping = [installer getPaths:bundleId];
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
    if (!normPath || !fakePrefix || !realPrefix || fakePrefix.length == 0 || realPrefix.length == 0) {
        return nil;
    }

    NSString *normFake = normalize_path(fakePrefix);
    NSString *normReal = normalize_path(realPrefix);

    // Exact match for container root
    if ([normPath isEqualToString:normFake]) {
        return normReal;
    }

    // Match child paths with boundary slash
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

    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (!mapping) {
        return fakePath;
    }

    NSString *normFakePath = normalize_path(fakePath);

    // 1. App-specific Data Path Redirection
    NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
    NSString *systemData = mapping[CSSystemDataPathKey] ?: mapping[@"real_data_path"];
    NSString *redirected = replace_prefix_if_matching(normFakePath, fakeData, systemData);
    if (redirected) {
        return redirected;
    }

    // 2. App-specific Bundle Path Redirection
    NSString *fakeBundle = mapping[CSFakeBundlePathKey] ?: mapping[@"fake_bundle_path"];
    NSString *systemBundle = mapping[CSSystemBundlePathKey] ?: mapping[@"real_bundle_path"];
    redirected = replace_prefix_if_matching(normFakePath, fakeBundle, systemBundle);
    if (redirected) {
        return redirected;
    }

    // 3. Generic prefix replacement (/var/mobile/Containers/Data/Application/ -> ROOT_PATH("/Data/Application/"))
    static NSString *fakeContainerDataPrefix = @"/var/mobile/Containers/Data/Application";
    static NSString *realContainerDataPrefix = nil;
    static dispatch_once_t oncePrefix;
    dispatch_once(&oncePrefix, ^{
        const char *jbRoot = ROOT_PATH("/Data/Application");
        realContainerDataPrefix = [NSString stringWithUTF8String:jbRoot];
        if (![[NSFileManager defaultManager] fileExistsAtPath:realContainerDataPrefix]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:realContainerDataPrefix withIntermediateDirectories:YES attributes:nil error:nil];
        }
    });

    redirected = replace_prefix_if_matching(normFakePath, fakeContainerDataPrefix, realContainerDataPrefix);
    if (redirected) {
        return redirected;
    }

    return fakePath;
}

static NSString *convert_real_to_fake_path(NSString *realPath) {
    if (!realPath || ![realPath isKindOfClass:[NSString class]] || realPath.length == 0) {
        return realPath;
    }

    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (!mapping) {
        return realPath;
    }

    NSString *normRealPath = normalize_path(realPath);

    // 1. If path matches systemData, convert to fakeData
    NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
    NSString *systemData = mapping[CSSystemDataPathKey] ?: mapping[@"real_data_path"];
    NSString *fake = replace_prefix_if_matching(normRealPath, systemData, fakeData);
    if (fake) {
        return fake;
    }

    // 2. If path matches systemBundle, convert to fakeBundle
    NSString *fakeBundle = mapping[CSFakeBundlePathKey] ?: mapping[@"fake_bundle_path"];
    NSString *systemBundle = mapping[CSSystemBundlePathKey] ?: mapping[@"real_bundle_path"];
    fake = replace_prefix_if_matching(normRealPath, systemBundle, fakeBundle);
    if (fake) {
        return fake;
    }

    return realPath;
}

static NSURL *convert_real_url_to_fake(NSURL *url) {
    if (!url || !url.isFileURL) {
        return url;
    }
    NSString *fakePath = convert_real_to_fake_path(url.path);
    if (![fakePath isEqualToString:url.path]) {
        return [NSURL fileURLWithPath:fakePath isDirectory:url.hasDirectoryPath];
    }
    return url;
}

#pragma mark - NSFileManager Hooks (Returning Fake Paths)

%hook NSFileManager

- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domainMask {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (!mapping) {
        return %orig(directory, domainMask);
    }

    NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
    if (fakeData && (domainMask & NSUserDomainMask)) {
        NSString *subpath = nil;
        switch (directory) {
            case NSDocumentDirectory:
                subpath = @"Documents";
                break;
            case NSApplicationSupportDirectory:
                subpath = @"Library/Application Support";
                break;
            case NSCachesDirectory:
                subpath = @"Library/Caches";
                break;
            case NSLibraryDirectory:
                subpath = @"Library";
                break;
            default:
                break;
        }

        if (subpath) {
            NSString *fakePath = [fakeData stringByAppendingPathComponent:subpath];
            // Ensure real underlying directory exists on filesystem
            NSString *realPath = get_real_path(fakePath);
            if (![[NSFileManager defaultManager] fileExistsAtPath:realPath]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:realPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
            return @[[NSURL fileURLWithPath:fakePath isDirectory:YES]];
        }
    }

    NSArray<NSURL *> *urls = %orig(directory, domainMask);
    if (!urls || urls.count == 0) {
        return urls;
    }

    NSMutableArray<NSURL *> *fakeUrls = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) {
        [fakeUrls addObject:convert_real_url_to_fake(u)];
    }
    return fakeUrls;
}

- (NSURL *)URLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain appropriateForURL:(NSURL *)url create:(BOOL)shouldCreate error:(NSError **)error {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (!mapping) {
        return %orig(directory, domain, url, shouldCreate, error);
    }

    NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
    if (fakeData && (domain & NSUserDomainMask)) {
        NSString *subpath = nil;
        switch (directory) {
            case NSDocumentDirectory:
                subpath = @"Documents";
                break;
            case NSApplicationSupportDirectory:
                subpath = @"Library/Application Support";
                break;
            case NSCachesDirectory:
                subpath = @"Library/Caches";
                break;
            case NSLibraryDirectory:
                subpath = @"Library";
                break;
            default:
                break;
        }

        if (subpath) {
            NSString *fakePath = [fakeData stringByAppendingPathComponent:subpath];
            NSString *realPath = get_real_path(fakePath);
            if (shouldCreate) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:realPath]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:realPath withIntermediateDirectories:YES attributes:nil error:error];
                }
            }
            return [NSURL fileURLWithPath:fakePath isDirectory:YES];
        }
    }

    NSURL *origURL = %orig(directory, domain, url, shouldCreate, error);
    return convert_real_url_to_fake(origURL);
}

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (mapping) {
        NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
        if (fakeData) {
            return [NSURL fileURLWithPath:fakeData isDirectory:YES];
        }
    }
    return %orig(groupIdentifier);
}

- (NSURL *)homeDirectoryForCurrentUser {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (mapping) {
        NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
        if (fakeData && fakeData.length > 0) {
            return [NSURL fileURLWithPath:fakeData isDirectory:YES];
        }
    }
    return %orig;
}

- (NSURL *)temporaryDirectory {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (mapping) {
        NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
        if (fakeData && fakeData.length > 0) {
            return [NSURL fileURLWithPath:[fakeData stringByAppendingPathComponent:@"tmp"] isDirectory:YES];
        }
    }
    return %orig;
}

- (NSString *)currentDirectoryPath {
    NSString *origPath = %orig;
    return convert_real_to_fake_path(origPath);
}

- (BOOL)fileExistsAtPath:(NSString *)path {
    NSString *realPath = get_real_path(path);
    return %orig(realPath);
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, isDirectory);
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attr {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, data, attr);
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, createIntermediates, attributes, error);
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, error);
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    NSString *realPath = get_real_path(path);
    return %orig(realPath, error);
}

%end

#pragma mark - NSBundle Hooks (Returning Fake Bundle Paths)

%hook NSBundle

- (NSString *)bundlePath {
    NSString *orig = %orig;
    if (self == [NSBundle mainBundle]) {
        NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
        if (mapping) {
            NSString *fakeBundle = mapping[CSFakeBundlePathKey] ?: mapping[@"fake_bundle_path"];
            if (fakeBundle && fakeBundle.length > 0) {
                return fakeBundle;
            }
        }
    }
    return orig;
}

- (NSString *)resourcePath {
    NSString *orig = %orig;
    if (self == [NSBundle mainBundle]) {
        NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
        if (mapping) {
            NSString *fakeBundle = mapping[CSFakeBundlePathKey] ?: mapping[@"fake_bundle_path"];
            if (fakeBundle && fakeBundle.length > 0) {
                return fakeBundle;
            }
        }
    }
    return orig;
}

- (NSURL *)bundleURL {
    if (self == [NSBundle mainBundle]) {
        NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
        if (mapping) {
            NSString *fakeBundle = mapping[CSFakeBundlePathKey] ?: mapping[@"fake_bundle_path"];
            if (fakeBundle && fakeBundle.length > 0) {
                return [NSURL fileURLWithPath:fakeBundle isDirectory:YES];
            }
        }
    }
    return %orig;
}

- (NSURL *)resourceURL {
    if (self == [NSBundle mainBundle]) {
        NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
        if (mapping) {
            NSString *fakeBundle = mapping[CSFakeBundlePathKey] ?: mapping[@"fake_bundle_path"];
            if (fakeBundle && fakeBundle.length > 0) {
                return [NSURL fileURLWithPath:fakeBundle isDirectory:YES];
            }
        }
    }
    return %orig;
}

%end

#pragma mark - Foundation Functions Hooks

static NSString *(*orig_NSHomeDirectory)(void) = NULL;
static NSString *new_NSHomeDirectory(void) {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (mapping) {
        NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
        if (fakeData && fakeData.length > 0) {
            return fakeData;
        }
    }
    return orig_NSHomeDirectory ? orig_NSHomeDirectory() : @"/var/mobile";
}

static NSString *(*orig_NSTemporaryDirectory)(void) = NULL;
static NSString *new_NSTemporaryDirectory(void) {
    NSDictionary<NSString *, NSString *> *mapping = get_app_path_mapping();
    if (mapping) {
        NSString *fakeData = mapping[CSFakeDataPathKey] ?: mapping[@"fake_data_path"];
        if (fakeData && fakeData.length > 0) {
            return [fakeData stringByAppendingPathComponent:@"tmp/"];
        }
    }
    return orig_NSTemporaryDirectory ? orig_NSTemporaryDirectory() : @"/tmp/";
}

#pragma mark - C File API Hooks (Redirecting to Real Paths)

static FILE *(*orig_fopen)(const char *path, const char *mode) = NULL;
static int (*orig_stat)(const char *path, struct stat *buf) = NULL;
static int (*orig_lstat)(const char *path, struct stat *buf) = NULL;
static int (*orig_access)(const char *path, int amode) = NULL;
static int (*orig_open)(const char *path, int oflag, ...) = NULL;
static DIR *(*orig_opendir)(const char *name) = NULL;

static FILE *new_fopen(const char *path, const char *mode) {
    if (!path) {
        return orig_fopen ? orig_fopen(path, mode) : NULL;
    }

    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_fopen ? orig_fopen(path, mode) : NULL;
    }

    if (!get_app_path_mapping()) {
        return orig_fopen ? orig_fopen(path, mode) : NULL;
    }

    FILE *fp = NULL;
    @autoreleasepool {
        NSString *origPath = [NSString stringWithUTF8String:path];
        NSString *realPath = get_real_path(origPath);
        const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;
        fp = orig_fopen ? orig_fopen(finalPath, mode) : NULL;
    }
    return fp;
}

static int new_stat(const char *path, struct stat *buf) {
    if (!path) {
        return orig_stat ? orig_stat(path, buf) : -1;
    }

    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_stat ? orig_stat(path, buf) : -1;
    }

    if (!get_app_path_mapping()) {
        return orig_stat ? orig_stat(path, buf) : -1;
    }

    int ret = -1;
    @autoreleasepool {
        NSString *origPath = [NSString stringWithUTF8String:path];
        NSString *realPath = get_real_path(origPath);
        const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;
        ret = orig_stat ? orig_stat(finalPath, buf) : -1;
    }
    return ret;
}

static int new_lstat(const char *path, struct stat *buf) {
    if (!path) {
        return orig_lstat ? orig_lstat(path, buf) : -1;
    }

    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_lstat ? orig_lstat(path, buf) : -1;
    }

    if (!get_app_path_mapping()) {
        return orig_lstat ? orig_lstat(path, buf) : -1;
    }

    int ret = -1;
    @autoreleasepool {
        NSString *origPath = [NSString stringWithUTF8String:path];
        NSString *realPath = get_real_path(origPath);
        const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;
        ret = orig_lstat ? orig_lstat(finalPath, buf) : -1;
    }
    return ret;
}

static int new_access(const char *path, int amode) {
    if (!path) {
        return orig_access ? orig_access(path, amode) : -1;
    }

    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return orig_access ? orig_access(path, amode) : -1;
    }

    if (!get_app_path_mapping()) {
        return orig_access ? orig_access(path, amode) : -1;
    }

    int ret = -1;
    @autoreleasepool {
        NSString *origPath = [NSString stringWithUTF8String:path];
        NSString *realPath = get_real_path(origPath);
        const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;
        ret = orig_access ? orig_access(finalPath, amode) : -1;
    }
    return ret;
}

static int new_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }

    if (!path) {
        return (oflag & O_CREAT) ? (orig_open ? orig_open(path, oflag, mode) : -1) : (orig_open ? orig_open(path, oflag) : -1);
    }

    if (strncmp(path, "/var/", 5) != 0 && strncmp(path, "/private/var/", 13) != 0) {
        return (oflag & O_CREAT) ? (orig_open ? orig_open(path, oflag, mode) : -1) : (orig_open ? orig_open(path, oflag) : -1);
    }

    if (!get_app_path_mapping()) {
        return (oflag & O_CREAT) ? (orig_open ? orig_open(path, oflag, mode) : -1) : (orig_open ? orig_open(path, oflag) : -1);
    }

    int ret = -1;
    @autoreleasepool {
        NSString *origPath = [NSString stringWithUTF8String:path];
        NSString *realPath = get_real_path(origPath);
        const char *finalPath = realPath ? [realPath fileSystemRepresentation] : path;
        if (oflag & O_CREAT) {
            ret = orig_open ? orig_open(finalPath, oflag, mode) : -1;
        } else {
            ret = orig_open ? orig_open(finalPath, oflag) : -1;
        }
    }
    return ret;
}

static DIR *new_opendir(const char *name) {
    if (!name) {
        return orig_opendir ? orig_opendir(name) : NULL;
    }

    if (strncmp(name, "/var/", 5) != 0 && strncmp(name, "/private/var/", 13) != 0) {
        return orig_opendir ? orig_opendir(name) : NULL;
    }

    if (!get_app_path_mapping()) {
        return orig_opendir ? orig_opendir(name) : NULL;
    }

    DIR *dir = NULL;
    @autoreleasepool {
        NSString *origPath = [NSString stringWithUTF8String:name];
        NSString *realPath = get_real_path(origPath);
        const char *finalPath = realPath ? [realPath fileSystemRepresentation] : name;
        dir = orig_opendir ? orig_opendir(finalPath) : NULL;
    }
    return dir;
}

#pragma mark - Initialization (%ctor)

%ctor {
    @autoreleasepool {
        NSLog(@"[ContraRedirect] Initializing ContraRedirect hook engine...");

        MSHookFunction((void *)fopen, (void *)new_fopen, (void **)&orig_fopen);
        MSHookFunction((void *)stat, (void *)new_stat, (void **)&orig_stat);
        MSHookFunction((void *)lstat, (void *)new_lstat, (void **)&orig_lstat);
        MSHookFunction((void *)access, (void *)new_access, (void **)&orig_access);
        MSHookFunction((void *)open, (void *)new_open, (void **)&orig_open);
        MSHookFunction((void *)opendir, (void *)new_opendir, (void **)&orig_opendir);
        MSHookFunction((void *)NSHomeDirectory, (void *)new_NSHomeDirectory, (void **)&orig_NSHomeDirectory);
        MSHookFunction((void *)NSTemporaryDirectory, (void *)new_NSTemporaryDirectory, (void **)&orig_NSTemporaryDirectory);

        NSLog(@"[ContraRedirect] Hooks installed successfully.");
    }
}
