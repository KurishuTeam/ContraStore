#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <libroot.h>
#include <rootless.h>

extern char **environ;

int unzip(const char *zip_path, const char *dest_dir) {
    pid_t pid;
    
    char *args[] = {"unzip", (char *)zip_path, "-d", (char *)dest_dir, NULL};
    
    // Resolve rootless binary path so launchd environment can execute unzip
    int status = posix_spawn(&pid, ROOT_PATH("/usr/bin/unzip"), NULL, NULL, args, environ);
    if (status != 0) {
        perror("posix_spawn unzip failed");
        return -1;
    }

    int child_status;
    if (waitpid(pid, &child_status, 0) == -1) {
        perror("waitpid failed");
        return -1;
    }

    if (WIFEXITED(child_status)) {
        return WEXITSTATUS(child_status) == 0 ? 0 : -1;
    }
    
    return -1;
}
