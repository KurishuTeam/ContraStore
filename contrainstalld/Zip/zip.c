#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>

extern char **environ;

int unzip(const char *zip_path, const char *dest_dir) {
    pid_t pid;
    
    char *args[] = {"unzip", (char *)zip_path, "-d", (char *)dest_dir, NULL};
    
    int status = posix_spawnp(&pid, "unzip", NULL, NULL, args, environ);
    if (status != 0) {
        perror("posix_spawnp failed");
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
