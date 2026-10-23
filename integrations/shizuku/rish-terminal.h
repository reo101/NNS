// SPDX-License-Identifier: Apache-2.0
#define _GNU_SOURCE 1
#define BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD 1
#define _Nonnull
#define _Nullable
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
