/* Read-only fixture probe. Never sets or removes an encryption policy. */
#include <errno.h>
#include <fcntl.h>
#include <linux/fscrypt.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc > 2) {
        fprintf(stderr, "usage: fscrypt-policy [directory]\n");
        return 2;
    }
    int descriptor = open(argc == 2 ? argv[1] : "/data/nix", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (descriptor < 0) {
        perror("open backing directory");
        return 1;
    }
    struct fscrypt_get_policy_ex_arg policy = { .policy_size = sizeof(policy.policy) };
    if (ioctl(descriptor, FS_IOC_GET_ENCRYPTION_POLICY_EX, &policy) < 0) {
        if (errno == ENODATA) {
            puts("none");
            close(descriptor);
            return 0;
        }
        perror("get fscrypt policy");
        close(descriptor);
        return 1;
    }
    const unsigned char *bytes = (const unsigned char *)&policy.policy;
    for (unsigned long long index = 0; index < policy.policy_size; index++)
        printf("%02x", bytes[index]);
    putchar('\n');
    close(descriptor);
    return 0;
}
