#ifndef NNS_BACKING_H
#define NNS_BACKING_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Validate the target, then create only absent backing. Returns 0 or -1/errno.
 * The callback must perform mkdir only, without metadata repair or fscrypt calls.
 * Android init supplies its label-aware make_dir; tests supply native mkdir.
 * A NULL callback validates existing backing only, for the mount service. */
int nns_prepare_backing(int (*create_directory)(const char *, mode_t));

#ifdef __cplusplus
}
#endif

#endif
