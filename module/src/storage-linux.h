#include <linux/btrfs.h>
#include <linux/errno.h>
#include <linux/fscrypt.h>
#include <linux/loop.h>
#include <linux/magic.h>
#include <linux/stat.h>
#include <asm/statfs.h>

/* Fold the array-type ioctl macro before zig translate-c processes it. */
enum { NNS_FS_IOC_GET_ENCRYPTION_POLICY_EX = FS_IOC_GET_ENCRYPTION_POLICY_EX };
