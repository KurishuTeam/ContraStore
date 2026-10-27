#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <signal.h>
#import <sys/stat.h>
#import <limits.h>

#import "ContraXPCClient.h"

#define CT_VERSION "0.1.0"

#pragma mark - Terminal Colors & Styling

static BOOL gIsTTY = NO;

static inline const char *colReset(void)  { return gIsTTY ? "\033[0m" : ""; }
static inline const char *colBold(void)   { return gIsTTY ? "\033[1m" : ""; }
static inline const char *colRed(void)    { return gIsTTY ? "\033[1;31m" : ""; }
static inline const char *colGreen(void)  { return gIsTTY ? "\033[1;32m" : ""; }
static inline const char *colYellow(void) { return gIsTTY ? "\033[1;33m" : ""; }
static inline const char *colCyan(void)   { return gIsTTY ? "\033[1;36m" : ""; }
static inline const char *colGray(void)   { return gIsTTY ? "\033[90m" : ""; }

#pragma mark - Signal Handling

static volatile sig_atomic_t gInterrupted = 0;

static void handleSignal(int sig) {
    (void)sig;
    gInterrupted = 1;
    if (gIsTTY) {
        fprintf(stderr, "\r\033[K\n%s[!] Operation interrupted by user.%s\n", colYellow(), colReset());
    } else {
        fprintf(stderr, "\nOperation interrupted by user.\n");
    }
    _exit(130);
}

static void setupSignalHandlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handleSignal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

#pragma mark - RunLoop Event Pump (Async XPC Execution)

// Pump main runloop to process XPC reply handlers dispatched to main queue
typedef void (^CTAsyncWorkBlock)(void (^doneBlock)(int exitCode));

static int runAsyncWithSpinner(NSString *message, NSTimeInterval timeout, CTAsyncWorkBlock work) {
    __block BOOL isDone = NO;
    __block int resultExitCode = 0;

    const char *spinnerChars[] = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"};
    const int spinnerCount = sizeof(spinnerChars) / sizeof(spinnerChars[0]);
    int frame = 0;

    if (!gIsTTY && message) {
        printf("[*] %s\n", message.UTF8String);
        fflush(stdout);
    }

    work(^(int code) {
        resultExitCode = code;
        isDone = YES;
    });

    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];

    while (!isDone && !gInterrupted) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
        }

        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - startTime;

        if (timeout > 0 && elapsed > timeout) {
            if (gIsTTY) {
                printf("\r\033[K");
            }
            fprintf(stderr, "%s[-] Error:%s Operation timed out after %.0fs.\n", colRed(), colReset(), timeout);
            return 1;
        }

        if (gIsTTY && message && !isDone) {
            printf("\r\033[K%s[%s]%s %s %s(%.1fs)%s",
                   colCyan(),
                   spinnerChars[frame % spinnerCount],
                   colReset(),
                   message.UTF8String,
                   colGray(),
                   elapsed,
                   colReset());
            fflush(stdout);
            frame++;
        }
    }

    if (gIsTTY && message) {
        printf("\r\033[K");
        fflush(stdout);
    }

    return resultExitCode;
}

#pragma mark - Commands Implementation

static void printUsage(const char *progName) {
    printf("%s%sContraStore CLI (ct)%s - Rootless App Management Tool\n\n", colBold(), colCyan(), colReset());
    printf("%sUSAGE:%s\n", colBold(), colReset());
    printf("  %s <command> [options] [arguments]\n\n", progName);
    printf("%sCOMMANDS:%s\n", colBold(), colReset());
    printf("  %sinstall%s <path.ipa> [more.ipa...]  Install one or more IPA packages\n", colGreen(), colReset());
    printf("  %slist%s, %sls%s                           List all applications managed by ContraStore\n", colGreen(), colReset(), colGreen(), colReset());
    printf("  %sinfo%s, %spaths%s <bundle-id>            Inspect container and redirect paths for an app\n", colGreen(), colReset(), colGreen(), colReset());
    printf("  %sversion%s, %s-v%s, %s--version%s          Show version information\n", colGreen(), colReset(), colGreen(), colReset(), colGreen(), colReset());
    printf("  %shelp%s, %s-h%s, %s--help%s                Show this help message\n\n", colGreen(), colReset(), colGreen(), colReset(), colGreen(), colReset());
    printf("%sEXAMPLES:%s\n", colBold(), colReset());
    printf("  %s install MyApp.ipa\n", progName);
    printf("  %s install *.ipa\n", progName);
    printf("  %s list\n", progName);
    printf("  %s info com.example.app\n\n", progName);
}

static void printVersion(void) {
    printf("%sct (ContraStore CLI)%s version %s\n", colBold(), colReset(), CT_VERSION);
    printf("Target Architecture: arm64 / arm64e (iOS Rootless)\n");
}

static int cmdInstall(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "%s[-] Error:%s Missing IPA path.\n", colRed(), colReset());
        fprintf(stderr, "Usage: %s install <path.ipa> [more.ipa...]\n", argv[0]);
        return 1;
    }

    int totalFiles = argc - 2;
    int successCount = 0;
    int failureCount = 0;

    for (int i = 2; i < argc; i++) {
        NSString *rawPath = [NSString stringWithUTF8String:argv[i]];
        NSString *expandedPath = [rawPath stringByExpandingTildeInPath];

        char resolvedBuffer[PATH_MAX];
        NSString *canonicalPath = nil;
        if (realpath(expandedPath.fileSystemRepresentation, resolvedBuffer) != NULL) {
            canonicalPath = [NSString stringWithUTF8String:resolvedBuffer];
        } else {
            canonicalPath = expandedPath.stringByStandardizingPath;
        }

        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:canonicalPath isDirectory:&isDir] || isDir) {
            fprintf(stderr, "%s[-] Error:%s IPA file not found at: '%s'\n", colRed(), colReset(), argv[i]);
            failureCount++;
            continue;
        }

        if (![canonicalPath.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
            fprintf(stderr, "%s[-] Error:%s '%s' is not an .ipa file package.\n", colRed(), colReset(), argv[i]);
            failureCount++;
            continue;
        }

        NSString *filename = canonicalPath.lastPathComponent;
        NSString *spinnerText = [NSString stringWithFormat:@"Installing %@", filename];

        if (totalFiles > 1) {
            printf("%s[%d/%d]%s %s%s%s\n", colBold(), (i - 1), totalFiles, colReset(), colCyan(), filename.UTF8String, colReset());
        }

        int status = runAsyncWithSpinner(spinnerText, 300.0, ^(void (^done)(int code)) {
            [[ContraXPCClient sharedClient] installIPA:canonicalPath completion:^(NSError * _Nullable error) {
                if (error) {
                    fprintf(stderr, "%s[-] Failed to install %s:%s %s (code %ld)\n",
                            colRed(),
                            filename.UTF8String,
                            colReset(),
                            error.localizedDescription.UTF8String ?: "Unknown error",
                            (long)error.code);
                    done(1);
                } else {
                    printf("%s[+] Successfully installed:%s %s\n",
                           colGreen(),
                           colReset(),
                           filename.UTF8String);
                    done(0);
                }
            }];
        });

        if (status == 0) {
            successCount++;
        } else {
            failureCount++;
        }
    }

    if (totalFiles > 1) {
        printf("\n%sSummary:%s %d succeeded, %d failed.\n",
               colBold(),
               colReset(),
               successCount,
               failureCount);
    }

    return (failureCount == 0) ? 0 : 1;
}

static int cmdList(void) {
    return runAsyncWithSpinner(@"Fetching installed applications...", 30.0, ^(void (^done)(int code)) {
        [[ContraXPCClient sharedClient] fetchAllInstalledAppsWithCompletion:^(NSArray<NSDictionary<NSString *,NSString *> *> * _Nullable apps) {
            if (!apps) {
                fprintf(stderr, "%s[-] Error:%s Failed to communicate with contrainstalld daemon.\n", colRed(), colReset());
                fprintf(stderr, "    Please verify that 'com.kurishu.contrainstalld' is active.\n");
                done(1);
                return;
            }

            if (apps.count == 0) {
                printf("%s[!] No applications installed via ContraStore.%s\n", colYellow(), colReset());
                done(0);
                return;
            }

            printf("%sInstalled Applications (%lu):%s\n", colBold(), (unsigned long)apps.count, colReset());
            printf("%s────────────────────────────────────────────────────────────%s\n", colGray(), colReset());

            NSUInteger idx = 1;
            for (NSDictionary<NSString *, NSString *> *app in apps) {
                NSString *bundleID = app[@"bundleID"] ?: @"(Unknown)";
                NSString *systemBundle = app[@"systemBundlePath"] ?: @"";
                NSString *systemData = app[@"systemDataPath"] ?: @"";
                NSString *fakeBundle = app[@"fakeBundlePath"] ?: @"";
                NSString *fakeData = app[@"fakeDataPath"] ?: @"";

                printf("%s[%lu]%s %s%s%s\n", colBold(), (unsigned long)idx++, colReset(), colCyan(), bundleID.UTF8String, colReset());
                if (systemBundle.length > 0) printf("    %sSystem Bundle:%s %s\n", colGray(), colReset(), systemBundle.UTF8String);
                if (systemData.length > 0)   printf("    %sSystem Data:  %s %s\n", colGray(), colReset(), systemData.UTF8String);
                if (fakeBundle.length > 0)   printf("    %sFake Bundle:  %s %s\n", colGray(), colReset(), fakeBundle.UTF8String);
                if (fakeData.length > 0)     printf("    %sFake Data:    %s %s\n", colGray(), colReset(), fakeData.UTF8String);
                printf("\n");
            }

            done(0);
        }];
    });
}

static int cmdInfo(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "%s[-] Error:%s Missing bundle identifier.\n", colRed(), colReset());
        fprintf(stderr, "Usage: %s info <bundle-id>\n", argv[0]);
        return 1;
    }

    NSString *bundleId = [NSString stringWithUTF8String:argv[2]];

    return runAsyncWithSpinner([NSString stringWithFormat:@"Querying info for %@...", bundleId], 15.0, ^(void (^done)(int code)) {
        [[ContraXPCClient sharedClient] fetchPathsForBundleID:bundleId completion:^(NSDictionary<NSString *,NSString *> * _Nullable info) {
            if (!info || info.count == 0) {
                fprintf(stderr, "%s[!] No record found for bundle identifier: '%s'%s\n",
                        colYellow(),
                        bundleId.UTF8String,
                        colReset());
                done(1);
                return;
            }

            printf("%sApplication Details:%s %s%s%s\n", colBold(), colReset(), colCyan(), bundleId.UTF8String, colReset());
            printf("%s────────────────────────────────────────────────────────────%s\n", colGray(), colReset());

            NSArray<NSString *> *orderedKeys = @[
                @"bundleID",
                @"systemBundlePath",
                @"systemDataPath",
                @"fakeBundlePath",
                @"fakeDataPath"
            ];

            for (NSString *key in orderedKeys) {
                NSString *value = info[key];
                if (value) {
                    printf("  %-18s: %s\n", key.UTF8String, value.UTF8String);
                }
            }

            for (NSString *key in info) {
                if (![orderedKeys containsObject:key]) {
                    printf("  %-18s: %s\n", key.UTF8String, info[key].UTF8String);
                }
            }

            done(0);
        }];
    });
}

#pragma mark - Main Entrypoint

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gIsTTY = isatty(STDOUT_FILENO) && isatty(STDERR_FILENO);
        setupSignalHandlers();

        const char *progName = (argc > 0 && argv[0]) ? argv[0] : "ct";

        if (argc < 2) {
            printUsage(progName);
            return 0;
        }

        NSString *subcommand = [NSString stringWithUTF8String:argv[1]].lowercaseString;

        if ([subcommand isEqualToString:@"install"]) {
            return cmdInstall(argc, argv);
        } else if ([subcommand isEqualToString:@"list"] || [subcommand isEqualToString:@"ls"]) {
            return cmdList();
        } else if ([subcommand isEqualToString:@"info"] || [subcommand isEqualToString:@"paths"]) {
            return cmdInfo(argc, argv);
        } else if ([subcommand isEqualToString:@"version"] || [subcommand isEqualToString:@"-v"] || [subcommand isEqualToString:@"--version"]) {
            printVersion();
            return 0;
        } else if ([subcommand isEqualToString:@"help"] || [subcommand isEqualToString:@"-h"] || [subcommand isEqualToString:@"--help"]) {
            printUsage(progName);
            return 0;
        } else {
            fprintf(stderr, "%s[-] Unknown command:%s '%s'\n\n", colRed(), colReset(), argv[1]);
            printUsage(progName);
            return 1;
        }
    }
}
