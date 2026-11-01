#define _GNU_SOURCE
#include "nns-backing.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int nns_prepare_backing(int (*create_directory)(const char *, mode_t))
{
    if (geteuid() != 0 || getegid() != 0) {
        errno = EPERM;
        return -1;
    }
    int target = open("/nix", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (target < 0)
        return -1;
    FILE *stream = fopen("/proc/self/mountinfo", "re");
    if (!stream) {
        int error = errno;
        close(target);
        errno = error;
        return -1;
    }
    char *line = NULL;
    size_t capacity = 0;
    unsigned count = 0;
    int error = 0;
    while (getline(&line, &capacity, stream) >= 0) {
        char path[4096];
        if (sscanf(line, "%*u %*u %*s %*s %4095s", path) != 1) {
            error = EINVAL;
            break;
        }
        if (!strcmp(path, "/nix"))
            count++;
    }
    if (ferror(stream))
        error = EIO;
    free(line);
    fclose(stream);
    if (count > 1)
        error = EBUSY;
    if (!error && !count) {
        DIR *directory = fdopendir(dup(target));
        if (!directory) {
            error = errno;
        } else {
            errno = 0;
            struct dirent *entry;
            while ((entry = readdir(directory))) {
                if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
                    error = EBUSY;
                    break;
                }
            }
            if (!error && errno)
                error = errno;
            closedir(directory);
        }
    }
    close(target);
    if (error) {
        errno = error;
        return -1;
    }
    int source = open("/data/nix", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (source >= 0) {
        close(source);
        return 0;
    }
    if (errno != ENOENT || !create_directory)
        return -1;
    struct stat status;
    if (lstat("/data/nix", &status) == 0) {
        errno = ENOTDIR;
        return -1;
    }
    if (errno != ENOENT)
        return -1;
    if (count) {
        errno = EBUSY;
        return -1;
    }
    /* Native creation inherits the parent encryption policy. Never touch an
     * existing inode, including one created concurrently after lstat. */
    mode_t mask = umask(0022);
    int result = create_directory("/data/nix", 0755);
    error = errno;
    umask(mask);
    if (result < 0 && error != EEXIST) {
        errno = error;
        return -1;
    }
    source = open("/data/nix", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (source < 0)
        return -1;
    close(source);
    return 0;
}
