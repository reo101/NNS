#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

/* No writes. Establish the actual caller identity and executable filesystem. */
int main(void)
{
    int executable = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
    struct statfs filesystem;
    if (executable < 0 || fstatfs(executable, &filesystem)) {
        perror("inspect executable filesystem");
        return 1;
    }
    close(executable);
    char context[256];
    int descriptor = open("/proc/self/attr/current", O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        perror("read caller SELinux context");
        return 1;
    }
    ssize_t count = read(descriptor, context, sizeof(context) - 1);
    close(descriptor);
    if (count < 0) {
        perror("read caller SELinux context");
        return 1;
    }
    context[count] = '\0';
    struct stat namespace;
    /* Android app domains can deny namespace metadata without denying execution. */
    int namespace_available = stat("/proc/self/ns/mnt", &namespace) == 0;
    printf("uid=%u gid=%u context=%s filesystem=%lx namespace=%llu\n",
           (unsigned)getuid(), (unsigned)getgid(), context,
           (unsigned long)filesystem.f_type,
           namespace_available ? (unsigned long long)namespace.st_ino : 0);
    return filesystem.f_type != BTRFS_SUPER_MAGIC;
}
