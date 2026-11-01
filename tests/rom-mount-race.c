/* Compile-time syscall fixture. Never package this in an Android image. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

int nns_test_mount(const char *source, const char *target, const char *filesystem,
                 unsigned long flags, const void *data)
{
    if (flags != MS_BIND) {
        errno = EINVAL;
        return -1;
    }
    /* Replace the pathname after validation, immediately before the syscall. */
    if (rename("/data/nix", "/data/nix-validated") < 0 || mkdir("/data/nix", 0755) < 0)
        return -1;
    int descriptor = open("/data/nix/replacement", O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (descriptor < 0)
        return -1;
    close(descriptor);
    return mount(source, target, filesystem, flags, data);
}
