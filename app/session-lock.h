#pragma once

#include <errno.h>
#include <sys/file.h>
#include <sys/stat.h>

// The caller keeps the descriptor open until this operation completes.
static inline int trySessionLock(int fd) {
    struct stat info;
    if (fstat(fd, &info) != 0) return errno;
    if (!S_ISREG(info.st_mode)) return EINVAL;

    int result;
    do { result = flock(fd, LOCK_EX | LOCK_NB); } while (result != 0 && errno == EINTR);
    return result == 0 ? 0 : errno;
}
