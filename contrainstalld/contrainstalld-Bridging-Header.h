#import <rootless.h>

#import "zip.h"
#import "ContraInstallerProtocol.h"

#ifdef __cplusplus
extern "C" {
#endif

const char *libroot_get_jbroot_prefix(void);
const char *libroot_get_root_prefix(void);

#ifdef __cplusplus
}
#endif