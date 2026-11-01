#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fscrypt.h>
#include <linux/magic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/system_properties.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>

#define STORAGE "/data/nns-storage"
#define RESULTS "/data/nns-storage-results"
#define UUID "68937ab5-bd17-4fb5-8a7c-6a9a6985e28d"

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static void read_text(const char *path, char *buffer, size_t capacity)
{
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) fail(path);
    ssize_t count = read(descriptor, buffer, capacity - 1);
    if (count < 0) fail(path);
    buffer[count] = 0;
    buffer[strcspn(buffer, "\n")] = 0;
    close(descriptor);
}

struct encryption {
    char policy[2 * sizeof(struct fscrypt_policy_v2) + 1];
    int error;
    int version;
};

static struct encryption encryption(const char *path)
{
    struct encryption result = {.version = -1};
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        result.error = errno;
        return result;
    }
    struct fscrypt_get_policy_ex_arg policy = {.policy_size = sizeof(policy.policy)};
    if (ioctl(descriptor, FS_IOC_GET_ENCRYPTION_POLICY_EX, &policy) < 0) {
        result.error = errno;
    } else {
        if (policy.policy_size > sizeof(policy.policy)) abort();
        for (size_t index = 0; index < policy.policy_size; index++)
            snprintf(result.policy + 2 * index, 3, "%02x", ((unsigned char *)&policy.policy)[index]);
        result.version = policy.policy.version;
    }
    close(descriptor);
    return result;
}

static void create_text(const char *path, const char *text)
{
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) fail(path);
    size_t length = strlen(text);
    if (write(descriptor, text, length) != (ssize_t)length || fsync(descriptor)) fail(path);
    close(descriptor);
}

static unsigned mount_count(const char *target)
{
    FILE *stream = fopen("/proc/self/mountinfo", "re");
    if (!stream) fail("mountinfo");
    char *line = NULL;
    size_t capacity = 0;
    unsigned count = 0;
    while (getline(&line, &capacity, stream) >= 0) {
        char path[4096];
        if (sscanf(line, "%*u %*u %*s %*s %4095s", path) != 1) abort();
        count += !strcmp(path, target);
    }
    free(line);
    fclose(stream);
    return count;
}

static int marker_matches(const char *path, const char *expected)
{
    char buffer[128];
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return 0;
    ssize_t count = read(descriptor, buffer, sizeof(buffer));
    close(descriptor);
    return count == (ssize_t)strlen(expected) && !memcmp(buffer, expected, strlen(expected));
}

static void prepare(void)
{
    struct encryption policy = encryption(STORAGE);
    if (policy.error || policy.version != FSCRYPT_POLICY_V2) {
        fprintf(stderr, "A v2 fscrypt policy is required: error=%d version=%d\n", policy.error, policy.version);
        exit(EXIT_FAILURE);
    }
    int source = open("/system/etc/nns-storage-fixture/nix.btrfs", O_RDONLY | O_CLOEXEC);
    if (source < 0) fail("open prepared fixture image");
    int destination = open(STORAGE "/nix.btrfs", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (destination < 0) fail("create encrypted fixture image");
    char buffer[65536];
    ssize_t count;
    while ((count = read(source, buffer, sizeof(buffer))) > 0) {
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(destination, buffer + offset, count - offset);
            if (written <= 0) fail("copy encrypted fixture image");
            offset += written;
        }
    }
    if (count < 0 || fsync(destination)) fail("sync encrypted fixture image");
    close(source);
    close(destination);
    create_text(STORAGE "/backing.conf", "image=nix.btrfs\nuuid=" UUID "\nsubvolume_id=256\n");
}

int main(int argc, char **argv)
{
    char identity[PROP_VALUE_MAX], context[256], enforcing[16], boot[64];
    __system_property_get("ro.product.device", identity);
    if (strcmp(identity, "vsoc_x86_64") || geteuid() || getegid() || argc != 2) return EXIT_FAILURE;
    __system_property_get("ro.nns.storage.fixture", identity);
    if (strcmp(identity, "1")) return EXIT_FAILURE;
    read_text("/proc/self/attr/current", context, sizeof(context));
    read_text("/sys/fs/selinux/enforce", enforcing, sizeof(enforcing));
    if (strcmp(context, "u:r:nns_storage_fixture:s0") || strcmp(enforcing, "1")) return EXIT_FAILURE;
    struct statfs outer;
    if (statfs(STORAGE, &outer) || outer.f_type != F2FS_SUPER_MAGIC) return EXIT_FAILURE;
    read_text("/proc/sys/kernel/random/boot_id", boot, sizeof(boot));
    if (!strcmp(argv[1], "prepare")) {
        prepare();
    } else if (!strcmp(argv[1], "write")) {
        struct statfs filesystem;
        if (statfs("/data/nix", &filesystem) || filesystem.f_type != BTRFS_SUPER_MAGIC) return EXIT_FAILURE;
        create_text("/data/nix/persistence-marker", "nns-storage-encrypted-persistence\n");
    } else if (!strcmp(argv[1], "runtime")) {
        struct stat source, target;
        struct statfs filesystem;
        if (stat("/data/nix", &source) || stat("/nix", &target) ||
            source.st_dev != target.st_dev || source.st_ino != target.st_ino ||
            statfs("/nix", &filesystem) || filesystem.f_type != BTRFS_SUPER_MAGIC)
            return EXIT_FAILURE;
        int descriptor = open("/nix/boot-marker", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (descriptor < 0 || write(descriptor, boot, strlen(boot)) != (ssize_t)strlen(boot) || fsync(descriptor))
            fail("write runtime boot marker");
        close(descriptor);
    } else if (strcmp(argv[1], "inspect") && strcmp(argv[1], "mount") && strcmp(argv[1], "unmount")) {
        return EXIT_FAILURE;
    }
    struct encryption directory = encryption(STORAGE), image = encryption(STORAGE "/nix.btrfs");
    struct stat backing = {0}, target = {0};
    struct statfs filesystem = {0};
    struct statvfs flags = {0};
    if (stat("/data/nix", &backing) || stat("/nix", &target) || statfs("/data/nix", &filesystem) || statvfs("/data/nix", &flags)) fail("inspect backing");
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now)) fail("read time");
    __system_property_get("sys.nns.storage.ready", identity);
    FILE *report = fopen(RESULTS "/report.json", "we");
    if (!report || fchmod(fileno(report), 0644)) fail("create report");
    fprintf(report, "{\"action\":\"%s\",\"record_time_ns\":%" PRIu64 ",\"boot_id\":\"%s\",\"domain\":\"%s\",\"selinux_enforcing\":true,\"ready\":\"%s\",", argv[1], (uint64_t)now.tv_sec * 1000000000 + now.tv_nsec, boot, context, identity);
    fprintf(report, "\"directory_policy\":\"%s\",\"directory_policy_error\":%d,\"image_policy\":\"%s\",\"image_policy_error\":%d,", directory.policy, directory.error, image.policy, image.error);
    fprintf(report, "\"backing_device\":%" PRIu64 ",\"backing_inode\":%" PRIu64 ",\"target_device\":%" PRIu64 ",\"target_inode\":%" PRIu64 ",\"filesystem\":%lu,\"mount_flags\":%lu,", (uint64_t)backing.st_dev, (uint64_t)backing.st_ino, (uint64_t)target.st_dev, (uint64_t)target.st_ino, (unsigned long)filesystem.f_type, flags.f_flag);
    fprintf(report, "\"backing_mounts\":%u,\"bind_mounts\":%u,\"marker_matches\":%s,\"persistence_matches\":%s,\"runtime_marker_matches\":%s}\n", mount_count("/data/nix"), mount_count("/nix"), marker_matches("/data/nix/marker", "nns-storage-vm-fixture\n") ? "true" : "false", marker_matches("/data/nix/persistence-marker", "nns-storage-encrypted-persistence\n") ? "true" : "false", marker_matches("/data/nix/boot-marker", boot) ? "true" : "false");
    if (fflush(report) || fsync(fileno(report)) || fclose(report)) fail("sync report");
    return EXIT_SUCCESS;
}
