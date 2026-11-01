#define _GNU_SOURCE
#include "nns-backing.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#define SOURCE "/data/nix"
#define TARGET "/nix"

static void fail(const char *message)
{
    fprintf(stderr, "nns-mount: %s\n", message);
    exit(EXIT_FAILURE);
}

static void fail_errno(const char *operation)
{
    fprintf(stderr, "nns-mount: %s: %s\n", operation, strerror(errno));
    exit(EXIT_FAILURE);
}

static unsigned mount_count(void)
{
    FILE *stream = fopen("/proc/self/mountinfo", "re");
    if (!stream)
        fail_errno("open mountinfo");
    char *line = NULL;
    size_t capacity = 0;
    unsigned count = 0;
    while (getline(&line, &capacity, stream) >= 0) {
        char target[4096];
        if (sscanf(line, "%*u %*u %*s %*s %4095s", target) != 1)
            fail("invalid mountinfo record");
        if (!strcmp(target, TARGET))
            count++;
    }
    if (ferror(stream))
        fail_errno("read mountinfo");
    free(line);
    fclose(stream);
    return count;
}

static int open_directory(const char *path)
{
    return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static void require_empty(int descriptor)
{
    DIR *directory = fdopendir(dup(descriptor));
    if (!directory)
        fail_errno("read mountpoint");
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, ".."))
            fail("refusing to cover a nonempty mountpoint");
    }
    if (errno)
        fail_errno("read mountpoint");
    closedir(directory);
}

int main(int argc, char **argv)
{
    int check_only = argc == 2 && !strcmp(argv[1], "--check");
    if (argc != 1 && !check_only)
        fail("usage: nns-mount [--check]");
    if (geteuid() != 0)
        fail("root is required");
    umask(0022);

    /* Init alone creates backing; this service only validates and mounts. */
    if (nns_prepare_backing(NULL) < 0)
        fail_errno("validate backing and mountpoint");
    int source = open_directory(SOURCE);
    if (source < 0)
        fail_errno("open " SOURCE);

    /* Serialize concurrent starts without creating a lock file in the store. */
    if (flock(source, LOCK_EX) < 0)
        fail_errno("lock backing directory");
    int target = open_directory(TARGET);
    if (target < 0)
        fail_errno("open " TARGET);
    unsigned count = mount_count();
    struct stat source_status, target_status;
    if (fstat(source, &source_status) < 0 || fstat(target, &target_status) < 0)
        fail_errno("stat directories");
    if (count) {
        if (count != 1 || source_status.st_dev != target_status.st_dev ||
            source_status.st_ino != target_status.st_ino)
            fail("refusing a conflicting mount");
        struct statvfs source_filesystem, target_filesystem;
        if (fstatvfs(source, &source_filesystem) < 0 ||
            fstatvfs(target, &target_filesystem) < 0)
            fail_errno("stat mount flags");
        const unsigned long flags = ST_RDONLY | ST_NOSUID | ST_NODEV | ST_NOEXEC;
        if ((source_filesystem.f_flag & flags) != (target_filesystem.f_flag & flags))
            fail("refusing conflicting mount flags");
        puts("nns-mount: existing bind retained");
    } else {
        if (check_only)
            fail("required bind mount is absent");
        require_empty(target);
        char source_path[64], target_path[64];
        snprintf(source_path, sizeof(source_path), "/proc/self/fd/%d", source);
        snprintf(target_path, sizeof(target_path), "/proc/self/fd/%d", target);
        if (mount(source_path, target_path, NULL, MS_BIND, NULL) < 0)
            fail_errno("bind " SOURCE " onto " TARGET);
        puts("nns-mount: backing directory mounted");
    }
    close(target);
    close(source);
    return EXIT_SUCCESS;
}
