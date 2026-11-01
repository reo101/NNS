#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <linux/fscrypt.h>
#include <selinux/selinux.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/system_properties.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>
#include <openssl/sha.h>

#define BACKING "/data/nix"
#define TARGET "/nix"
#define REPORT_DIR "/data/nns-fixture"
#define FIXTURE "nns-fixture.bin"
#define MARKER "nns-fixture-v1"
#define DOMAIN "u:r:nns_fixture:s0"
#define MAX_XATTR 256
#define MAX_FILE 4096
#define MAX_JSON 16384

static void fail(const char *what)
{
    fprintf(stderr, "nns-fixture: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void reject(const char *what)
{
    fprintf(stderr, "nns-fixture: %s\n", what);
    exit(1);
}

static void add(char *out, size_t cap, size_t *used, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int n = vsnprintf(out + *used, cap - *used, format, args);
    va_end(args);
    if (n < 0 || (size_t)n >= cap - *used)
        reject("report buffer overflow");
    *used += (size_t)n;
}

static void hex(char *out, size_t cap, size_t *used, const void *data, size_t len)
{
    const unsigned char *p = data;
    for (size_t i = 0; i < len; i++)
        add(out, cap, used, "%02x", p[i]);
}

static size_t xattr_hex(int fd, const char *name, char *out, size_t cap, bool optional)
{
    unsigned char value[MAX_XATTR];
    ssize_t n = fgetxattr(fd, name, value, sizeof(value));
    if (n < 0) {
        if (optional && errno == ENODATA) return 0;
        fail(name);
    }
    size_t used = 0;
    hex(out, cap, &used, value, (size_t)n);
    out[used] = '\0';
    return (size_t)n;
}

static size_t policy(int fd, unsigned char *bytes, bool optional)
{
    struct fscrypt_get_policy_ex_arg arg = { .policy_size = sizeof(arg.policy) };
    if (ioctl(fd, FS_IOC_GET_ENCRYPTION_POLICY_EX, &arg) < 0) {
        if (optional && errno == ENODATA) return 0;
        fail("get fscrypt policy");
    }
    if (!arg.policy_size || arg.policy_size > sizeof(arg.policy))
        reject("invalid fscrypt policy size");
    memcpy(bytes, &arg.policy, (size_t)arg.policy_size);
    return (size_t)arg.policy_size;
}

static void stat_json(char *out, size_t cap, size_t *used, const struct stat *s)
{
    add(out, cap, used,
        "\"uid\":%u,\"gid\":%u,\"mode\":\"%04o\",\"device\":%llu,\"inode\":%llu,"
        "\"atime_ns\":%lld,\"mtime_ns\":%lld,\"ctime_ns\":%lld",
        (unsigned)s->st_uid, (unsigned)s->st_gid, (unsigned)(s->st_mode & 07777),
        (unsigned long long)s->st_dev, (unsigned long long)s->st_ino,
        (long long)s->st_atim.tv_sec * 1000000000LL + s->st_atim.tv_nsec,
        (long long)s->st_mtim.tv_sec * 1000000000LL + s->st_mtim.tv_nsec,
        (long long)s->st_ctim.tv_sec * 1000000000LL + s->st_ctim.tv_nsec);
}

static unsigned mount_count(void)
{
    FILE *f = fopen("/proc/self/mountinfo", "re");
    if (!f) fail("open mountinfo");
    char *line = NULL;
    size_t size = 0;
    unsigned count = 0;
    while (getline(&line, &size, f) >= 0) {
        char path[4096];
        if (sscanf(line, "%*u %*u %*s %*s %4095s", path) != 1)
            reject("invalid mountinfo record");
        if (!strcmp(path, TARGET)) count++;
    }
    if (ferror(f)) fail("read mountinfo");
    free(line);
    fclose(f);
    return count;
}

static int directory(const char *path)
{
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NOATIME);
    if (fd < 0) fail(path);
    return fd;
}

static void observe(char *out, size_t cap, size_t *used, const char *name, int fd)
{
    struct stat s;
    struct statvfs v;
    char label[MAX_XATTR * 2 + 1], marker[MAX_XATTR * 2 + 1], policy_hex[sizeof(((struct fscrypt_get_policy_ex_arg *)0)->policy) * 2 + 1];
    unsigned char policy_bytes[sizeof(((struct fscrypt_get_policy_ex_arg *)0)->policy)];
    size_t label_len = xattr_hex(fd, "security.selinux", label, sizeof(label), false);
    size_t marker_len = xattr_hex(fd, "user.nns_fixture", marker, sizeof(marker), true);
    size_t policy_len = policy(fd, policy_bytes, true), policy_used = 0;
    hex(policy_hex, sizeof(policy_hex), &policy_used, policy_bytes, policy_len);
    if (fstat(fd, &s) < 0 || !S_ISDIR(s.st_mode)) reject("expected directory");
    if (fstatvfs(fd, &v) < 0) fail("stat mount flags");
    add(out, cap, used, "\"%s\":{", name);
    stat_json(out, cap, used, &s);
    add(out, cap, used, ",\"label_hex\":\"%.*s\",\"user_xattr_hex\":", (int)(label_len * 2), label);
    if (marker_len) add(out, cap, used, "\"%.*s\"", (int)(marker_len * 2), marker);
    else add(out, cap, used, "null");
    add(out, cap, used, ",\"fscrypt_policy_hex\":");
    if (policy_len) add(out, cap, used, "\"%.*s\"", (int)policy_used, policy_hex);
    else add(out, cap, used, "null");
    add(out, cap, used, ",\"mount_flags\":%llu}",
        (unsigned long long)(v.f_flag & (ST_RDONLY | ST_NOSUID | ST_NODEV | ST_NOEXEC)));
}

static bool empty_directory(int fd)
{
    int copy = dup(fd);
    if (copy < 0) fail("duplicate backing descriptor");
    DIR *d = fdopendir(copy);
    if (!d) fail("read backing directory");
    struct dirent *e;
    errno = 0;
    while ((e = readdir(d))) {
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) {
            closedir(d);
            return false;
        }
    }
    if (errno) fail("read backing directory");
    closedir(d);
    return true;
}

static void read_fixture(int dirfd, char *out, size_t cap, size_t *used)
{
    int fd = openat(dirfd, FIXTURE, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NOATIME);
    if (fd < 0) {
        if (errno == ENOENT) { add(out, cap, used, "null"); return; }
        fail("open fixture");
    }
    struct stat s;
    unsigned char data[MAX_FILE + 1], digest[SHA256_DIGEST_LENGTH];
    ssize_t n;
    if (fstat(fd, &s) < 0 || !S_ISREG(s.st_mode)) reject("fixture is not a regular file");
    size_t total = 0;
    while ((n = read(fd, data + total, sizeof(data) - total)) > 0) {
        total += (size_t)n;
        if (total == sizeof(data)) reject("fixture file exceeds limit");
    }
    if (n < 0) fail("read fixture");
    if (SHA256(data, total, digest) == NULL) reject("SHA-256 failed");
    char label[MAX_XATTR * 2 + 1], marker[MAX_XATTR * 2 + 1];
    size_t ll = xattr_hex(fd, "security.selinux", label, sizeof(label), false);
    size_t ml = xattr_hex(fd, "user.nns_fixture", marker, sizeof(marker), true);
    add(out, cap, used, "{\"size\":%lld,", (long long)s.st_size);
    stat_json(out, cap, used, &s);
    add(out, cap, used, ",\"label_hex\":\"%.*s\",\"user_xattr_hex\":", (int)(ll * 2), label);
    if (ml) add(out, cap, used, "\"%.*s\"", (int)(ml * 2), marker); else add(out, cap, used, "null");
    add(out, cap, used, ",\"sha256\":\"");
    hex(out, cap, used, digest, sizeof(digest));
    add(out, cap, used, "\"}");
    close(fd);
}

static void save_report(const char *json, size_t len)
{
    int dir = directory(REPORT_DIR);
    struct stat s;
    if (fstat(dir, &s) < 0) fail("stat report directory");
    if (s.st_uid != 0 || s.st_gid != 1000 || (s.st_mode & 07777) != 0775)
        reject("report directory ownership or mode mismatch");
    char temp[80];
    snprintf(temp, sizeof(temp), ".report.%ld.tmp", (long)getpid());
    int fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) fail("create temporary report");
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, json + done, len - done);
        if (n < 0) fail("write report");
        done += (size_t)n;
    }
    if (fchmod(fd, 0644) < 0) fail("set report permissions");
    if (fsync(fd) < 0) fail("sync report");
    if (close(fd) < 0) fail("close report");
    if (renameat(dir, temp, dir, "report.json") < 0) fail("publish report");
    if (fsync(dir) < 0) fail("sync report directory");
    close(dir);
}

static void validate_empty_backing(int backing)
{
    struct stat s;
    if (fstat(backing, &s) < 0) fail("stat backing");
    if (s.st_uid != 0 || s.st_gid != 0 || (s.st_mode & 07777) != 0755)
        reject("backing must initially be root-owned with mode 0755");
    if (!empty_directory(backing)) reject("backing directory is not empty");
}

static void prepare(int backing)
{
    validate_empty_backing(backing);
    struct fscrypt_get_policy_ex_arg get = { .policy_size = sizeof(get.policy) };
    size_t len = policy(backing, (unsigned char *)&get.policy, false);
    if (get.policy.version != FSCRYPT_POLICY_V1 && get.policy.version != FSCRYPT_POLICY_V2)
        reject("unsupported encryption policy version");
    size_t expected = get.policy.version == FSCRYPT_POLICY_V1 ?
        sizeof(struct fscrypt_policy_v1) : sizeof(struct fscrypt_policy_v2);
    if (len != expected) reject("invalid encryption policy size");
    static const char content[] = "NNS encrypted backing fixture v1\n";
    int fd = openat(backing, FIXTURE, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) fail("create fixture");
    size_t done = 0;
    while (done < sizeof(content) - 1) {
        ssize_t n = write(fd, content + done, sizeof(content) - 1 - done);
        if (n < 0) fail("write fixture");
        done += (size_t)n;
    }
    if (fsync(fd) < 0) fail("sync fixture");
    const struct timespec old[2] = { { .tv_sec = 946684800 }, { .tv_sec = 946684800 } };
    if (fsetxattr(fd, "user.nns_fixture", MARKER, sizeof(MARKER) - 1, 0) < 0 ||
        fchown(fd, 12345, 12345) < 0 || fchmod(fd, 0715) < 0 || futimens(fd, old) < 0)
        fail("set fixture metadata");
    if (fsync(fd) < 0) fail("sync fixture metadata");
    if (close(fd) < 0) fail("close fixture");
    if (fsetxattr(backing, "user.nns_fixture", MARKER, sizeof(MARKER) - 1, 0) < 0 ||
        fchown(backing, 12345, 12345) < 0 || fchmod(backing, 0715) < 0 || futimens(backing, old) < 0)
        fail("set backing metadata");
    if (fsync(backing) < 0) fail("sync backing metadata");
}

static void run(const char *action)
{
    if (security_getenforce() != 1) reject("SELinux enforcing mode is required");
    char *domain = NULL;
    if (getcon(&domain) < 0) fail("get SELinux context");
    if (strcmp(domain, DOMAIN)) reject("unexpected SELinux domain");
    freecon(domain);
    if (!strcmp(action, "prepare-invalid")) {
        struct stat status;
        if (lstat(BACKING, &status) == 0) reject("backing move did not complete");
        if (errno != ENOENT) fail("check moved backing");
        int saved = directory("/data/nns-fixture/saved-backing");
        if (empty_directory(saved)) reject("saved backing fixture is empty");
        close(saved);
        if (__system_property_set("sys.nns.fixture.moved", "1") < 0)
            fail("request invalid backing fixture");
        return;
    }
    int backing = directory(BACKING), target = directory(TARGET);
    if (!strcmp(action, "prepare-encrypted")) {
        validate_empty_backing(backing);
        struct stat source_status, target_status;
        if (fstat(backing, &source_status) < 0 || fstat(target, &target_status) < 0)
            fail("stat bind identity");
        if (mount_count() != 1 || source_status.st_dev != target_status.st_dev ||
            source_status.st_ino != target_status.st_ino)
            reject("a valid existing bind is required for preparation");
        if (__system_property_set("sys.nns.fixture.ready", "1") < 0)
            fail("request init encryption preparation");
        close(target);
        close(backing);
        return;
    }
    if (!strcmp(action, "complete-encrypted")) {
        prepare(backing);
        action = "prepare-encrypted";
    }
    char json[MAX_JSON];
    size_t used = 0;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) fail("read monotonic clock");
    add(json, sizeof(json), &used,
        "{\"action\":\"%s\",\"record_time_ns\":%lld,\"selinux_enforcing\":true,\"domain\":\"%s\",\"mount_count\":%u,",
        action, (long long)now.tv_sec * 1000000000LL + now.tv_nsec, DOMAIN, mount_count());
    observe(json, sizeof(json), &used, "backing", backing);
    add(json, sizeof(json), &used, ",");
    observe(json, sizeof(json), &used, "target", target);
    add(json, sizeof(json), &used, ",\"fixture_file\":");
    read_fixture(backing, json, sizeof(json), &used);
    add(json, sizeof(json), &used, "}\n");
    save_report(json, used);
    close(target);
    close(backing);
}

int main(int argc, char **argv)
{
    if (geteuid() != 0 || getegid() != 0) reject("effective uid and gid must be root");
    struct __user_cap_header_struct header = { .version = _LINUX_CAPABILITY_VERSION_3 };
    struct __user_cap_data_struct caps[2] = {{0}};
    if (syscall(SYS_capget, &header, caps) < 0) fail("read capabilities");
    const uint32_t expected = (1U << CAP_CHOWN) | (1U << CAP_FOWNER);
    if (caps[0].effective != expected || caps[0].permitted != expected ||
        (caps[0].inheritable & ~expected) ||
        caps[1].effective || caps[1].permitted || caps[1].inheritable)
        reject("capabilities must be limited to CHOWN and FOWNER");
    gid_t groups[1];
    int count = getgroups(1, groups);
    if (count != 1 || groups[0] != 1000)
        reject("supplementary group must be system");
    if (argc != 2 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "prepare-encrypted") &&
                      strcmp(argv[1], "complete-encrypted") && strcmp(argv[1], "restart-mount") &&
                      strcmp(argv[1], "prepare-invalid")))
        reject("usage: fixture inspect|prepare-encrypted|complete-encrypted|restart-mount|prepare-invalid");
    run(argv[1]);
    return 0;
}
