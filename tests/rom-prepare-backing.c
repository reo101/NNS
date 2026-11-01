#include "nns-backing.h"
#include <stdio.h>
#include <sys/stat.h>

/* Native test adapter only. Production calls from Android init with make_dir. */
int main(void)
{
    if (nns_prepare_backing(mkdir) < 0) {
        perror("nns_prepare_backing");
        return 1;
    }
    return 0;
}
