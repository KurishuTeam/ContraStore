#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <libroot.h>
#include <rootless.h>

extern char **environ;

int uicache(const char *app_path) {
    pid_t pid;
    char *args[] = {"uicache", "-p", (char *)app_path, NULL};

    int status = posix_spawn(&pid, ROOT_PATH("/usr/bin/uicache"), NULL, NULL, args, environ);
    if (status != 0) {
        perror("posix_spawn uicache failed");
        return -1;
    }

    int child_status;
    if (waitpid(pid, &child_status, 0) == -1) {
        perror("waitpid uicache failed");
        return -1;
    }

    if (WIFEXITED(child_status)) {
        return WEXITSTATUS(child_status) == 0 ? 0 : -1;
    }

    return -1;
}
