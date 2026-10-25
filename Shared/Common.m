#import "Common.h"
#import <libroot.h>
#import <rootless.h>
#import <xpc/xpc.h>

static xpc_connection_t g_xpc_connection = NULL;
static dispatch_once_t g_xpc_init_once;

xpc_connection_t get_contrainstalld_xpc_connection(void) {
    dispatch_once(&g_xpc_init_once, ^{
        dispatch_queue_t queue = dispatch_queue_create("com.kurishu.contrastore.xpc_client", DISPATCH_QUEUE_SERIAL);
        g_xpc_connection = xpc_connection_create_mach_service(
            CONTRA_XPC_SERVICE_NAME,
            queue,
            0
        );

        if (!g_xpc_connection) {
            NSLog(@"[ContraStore:SharedXPC] Failed to connect to Mach service %s", CONTRA_XPC_SERVICE_NAME);
            return;
        }

        xpc_connection_set_event_handler(g_xpc_connection, ^(xpc_object_t event) {
            xpc_type_t type = xpc_get_type(event);
            if (type == XPC_TYPE_ERROR) {
                if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
                    NSLog(@"[ContraStore:SharedXPC] Connection interrupted");
                } else if (event == XPC_ERROR_CONNECTION_INVALID) {
                    NSLog(@"[ContraStore:SharedXPC] Connection invalid");
                    g_xpc_connection = NULL;
                } else {
                    const char *desc = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
                    NSLog(@"[ContraStore:SharedXPC] Connection error: %s", desc ? desc : "unknown");
                }
            } else if (type == XPC_TYPE_DICTIONARY) {
                const char *action = xpc_dictionary_get_string(event, "action");
                NSLog(@"[ContraStore:SharedXPC] Daemon event received: action=%s", action ? action : "(null)");
            }
        });

        xpc_connection_resume(g_xpc_connection);
        NSLog(@"[ContraStore:SharedXPC] Connection active for service: %s", CONTRA_XPC_SERVICE_NAME);
    });

    return g_xpc_connection;
}

void send_xpc_ping(void) {
    xpc_connection_t conn = get_contrainstalld_xpc_connection();
    if (!conn) {
        NSLog(@"[ContraStore:SharedXPC] Cannot send ping: XPC connection is NULL");
        return;
    }

    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "action", "ping");

    NSLog(@"[ContraStore:SharedXPC] Dispatching ping to daemon...");
    xpc_connection_send_message_with_reply(conn, msg, dispatch_get_main_queue(), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            const char *err = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            NSLog(@"[ContraStore:SharedXPC] Ping error response: %s", err ? err : "unknown error");
        } else {
            const char *status = xpc_dictionary_get_string(reply, "status");
            NSLog(@"[ContraStore:SharedXPC] Ping response received: %s", status ? status : "ok");
        }
    });
}

void send_xpc_install(const char *ipaPath) {
    if (!ipaPath) {
        NSLog(@"[ContraStore:SharedXPC] send_xpc_install received NULL path");
        return;
    }

    xpc_connection_t conn = get_contrainstalld_xpc_connection();
    if (!conn) {
        NSLog(@"[ContraStore:SharedXPC] Cannot send install: XPC connection is NULL");
        return;
    }

    const char *resolvedIpaPath = ROOT_PATH(ipaPath);

    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "action", "install");
    xpc_dictionary_set_string(msg, "path", resolvedIpaPath);

    NSLog(@"[ContraStore:SharedXPC] Requesting install for IPA: %s", resolvedIpaPath);
    xpc_connection_send_message_with_reply(conn, msg, dispatch_get_main_queue(), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            const char *err = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            NSLog(@"[ContraStore:SharedXPC] Install error response: %s", err ? err : "unknown error");
        } else {
            int64_t code = xpc_dictionary_get_int64(reply, "code");
            const char *msgText = xpc_dictionary_get_string(reply, "message");
            NSLog(@"[ContraStore:SharedXPC] Install response: code=%lld, message=%s", code, msgText ? msgText : "completed");
        }
    });
}

void send_xpc_get_paths(const char *bundleId) {
    if (!bundleId) {
        NSLog(@"[ContraStore:SharedXPC] send_xpc_get_paths received NULL bundleId");
        return;
    }

    xpc_connection_t conn = get_contrainstalld_xpc_connection();
    if (!conn) {
        NSLog(@"[ContraStore:SharedXPC] Cannot send get_paths: XPC connection is NULL");
        return;
    }

    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "action", "get_paths");
    xpc_dictionary_set_string(msg, "bundle_id", bundleId);

    NSLog(@"[ContraStore:SharedXPC] Requesting paths for bundle ID: %s", bundleId);
    xpc_connection_send_message_with_reply(conn, msg, dispatch_get_main_queue(), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            const char *err = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            NSLog(@"[ContraStore:SharedXPC] get_paths error response: %s", err ? err : "unknown error");
        } else {
            const char *appPath = xpc_dictionary_get_string(reply, "app_path");
            const char *dataPath = xpc_dictionary_get_string(reply, "data_path");
            NSLog(@"[ContraStore:SharedXPC] get_paths response: app=%s, data=%s",
                  appPath ? appPath : "(null)",
                  dataPath ? dataPath : "(null)");
        }
    });
}

const char *contra_root_path(const char *path) {
    if (!path) {
        return NULL;
    }
    return ROOT_PATH(path);
}
