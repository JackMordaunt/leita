/* FreeBSD's mount ABI stays inside C compiled against the native headers. */
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(((struct statfs *)0)->f_fsid) == 2 * sizeof(int32_t),
    "the mount identity must fit two 32-bit words");

static int
copy_field(const char *source, size_t bound, char *out, size_t capacity)
{
    size_t length = strnlen(source, bound);
    if (length == bound)
        return EIO;
    if (length >= capacity)
        return ENAMETOOLONG;
    memcpy(out, source, length + 1);
    return 0;
}

int
leita_freebsd_mount_id(int fd, int32_t out[2])
{
    struct statfs st;
    if (fstatfs(fd, &st) != 0)
        return errno;
    memcpy(out, &st.f_fsid, sizeof(st.f_fsid));
    return 0;
}

int
leita_freebsd_mount_path(const char *path, char *point, size_t point_capacity,
    char *source, size_t source_capacity, char *kind, size_t kind_capacity)
{
    struct statfs st;
    int error;
    if (statfs(path, &st) != 0)
        return errno;
    error = copy_field(st.f_mntonname, sizeof(st.f_mntonname), point, point_capacity);
    if (error != 0)
        return error;
    error = copy_field(st.f_mntfromname, sizeof(st.f_mntfromname), source, source_capacity);
    if (error != 0)
        return error;
    return copy_field(st.f_fstypename, sizeof(st.f_fstypename), kind, kind_capacity);
}

/* A NUL-separated snapshot. A changed table or short output buffer fails rather
 * than returning a partial list that could miss an alias mount boundary. */
int
leita_freebsd_mounts(char *out, size_t capacity, size_t *needed)
{
    int count = getfsstat(NULL, 0, MNT_NOWAIT);
    if (count < 0)
        return errno;
    if ((size_t)count > SIZE_MAX / sizeof(struct statfs) - 16)
        return EOVERFLOW;
    size_t slots = (size_t)count + 16;
    size_t bytes = slots * sizeof(struct statfs);
    if (bytes > LONG_MAX)
        return EOVERFLOW;
    struct statfs *mounts = malloc(bytes);
    if (mounts == NULL)
        return ENOMEM;
    int found = getfsstat(mounts, (long)bytes, MNT_NOWAIT);
    if (found < 0) {
        int error = errno;
        free(mounts);
        return error;
    }
    if ((size_t)found >= slots) {
        free(mounts);
        return EAGAIN;
    }
    size_t used = 0;
    int error = 0;
    for (int i = 0; i < found; ++i) {
        size_t length = strnlen(mounts[i].f_mntonname, sizeof(mounts[i].f_mntonname));
        if (length == sizeof(mounts[i].f_mntonname) || length == 0 ||
            mounts[i].f_mntonname[0] != '/') {
            error = EIO;
            break;
        }
        if (length + 1 > SIZE_MAX - used) {
            error = EOVERFLOW;
            break;
        }
        if (out != NULL && used + length + 1 <= capacity)
            memcpy(out + used, mounts[i].f_mntonname, length + 1);
        used += length + 1;
    }
    free(mounts);
    *needed = used;
    if (error != 0)
        return error;
    if (out != NULL && used > capacity)
        return ERANGE;
    return 0;
}
