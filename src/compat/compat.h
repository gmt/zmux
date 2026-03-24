/*
 * compat.h – minimal compatibility shim for zmux's C bridges.
 *
 * The imsg.c / imsg-buffer.c sources from tmux compat/ include this header.
 * On Linux/glibc we provide only the essentials they need.
 */
#ifndef COMPAT_H
#define COMPAT_H

#define _DEFAULT_SOURCE 1
#define _XOPEN_SOURCE 600

#include <sys/types.h>
#include <sys/uio.h>
#include <sys/socket.h>

#include <limits.h>
#include <stdint.h>

/* IOV_MAX may not be defined on all systems */
#ifndef IOV_MAX
#include <sys/uio.h>
#ifndef IOV_MAX
#define IOV_MAX 1024
#endif
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Attribute macros (GCC/Clang) */
#ifndef __unused
#define __unused __attribute__((__unused__))
#endif
#ifndef __dead
#define __dead __attribute__((__noreturn__))
#endif
#ifndef __packed
#define __packed __attribute__((__packed__))
#endif
#ifndef __weak
#define __weak __attribute__((__weak__))
#endif

/* sys/queue.h for TAILQ / SLIST macros */
#include "queue.h"

/* libevent2 (event.h pulled in via build flags, not here) */

/* Provide recallocarray if needed */
#ifndef HAVE_RECALLOCARRAY
void *recallocarray(void *, size_t, size_t, size_t);
#endif

/* Provide reallocarray if needed */
#ifndef HAVE_REALLOCARRAY
void *reallocarray(void *, size_t, size_t);
#endif

/* Provide freezero if needed */
#ifndef HAVE_FREEZERO
void freezero(void *, size_t);
#endif

/* Compat: explicit_bzero */
#ifndef HAVE_EXPLICIT_BZERO
void explicit_bzero(void *, size_t);
#endif

/* Endian conversion (provides htobe64, be64toh) */
#include <endian.h>
#include <arpa/inet.h>
#include <stdint.h>

/* htonll / ntohll: required by imsg-buffer.c */
static inline uint64_t htonll(uint64_t v) {
    return htobe64(v);
}
static inline uint64_t ntohll(uint64_t v) {
    return be64toh(v);
}

/* err.h */
#include <err.h>

#endif /* COMPAT_H */
