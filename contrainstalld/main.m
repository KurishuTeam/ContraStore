#import <Foundation/Foundation.h>
#import "ContraInstallerProtocol.h"
#import "contrainstalld-Swift.h"

@interface NSXPCListener (ServiceName)
- (instancetype)initWithMachServiceName:(NSString *)name;
@end

@interface ServiceDelegate : NSObject <NSXPCListenerDelegate>
@end

@implementation ServiceDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    NSLog(@"[contrainstalld] Accepting new connection from PID: %d", newConnection.processIdentifier);
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ContraInstallerProtocol)];
    newConnection.exportedObject = [ContraInstaller new];
    [newConnection resume];
    return YES;
}
@end

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        NSLog(@"[contrainstalld] Starting daemon (PID: %d)...", getpid());
        ServiceDelegate *delegate = [ServiceDelegate new];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.kurishu.contrainstalld"];
        if (!listener) {
            NSLog(@"[contrainstalld] Error: Failed to create NSXPCListener!");
            return 1;
        }
        listener.delegate = delegate;
        [listener resume];
        NSLog(@"[contrainstalld] Listening on Mach service: com.kurishu.contrainstalld");
        
        dispatch_main();
    }
    return 0;
}
