#ifndef BLUETTIBAR_POSIX_H
#define BLUETTIBAR_POSIX_H

#include <sys/file.h>

// A distinct C function name avoids Swift's collision with struct flock.
// Clang imports the real system declaration and preserves its C calling convention.
static inline int bluetti_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}

#endif
