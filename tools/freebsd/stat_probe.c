/* Independent native-header oracle for the pinned Odin POSIX stat binding. */
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>

#if defined(__APPLE__)
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif

static void
print_stat(const char *label, const struct stat *st)
{
    printf("%s %llu %llu %llu %llu %lld %lld\n", label,
        (unsigned long long)st->st_dev, (unsigned long long)st->st_ino,
        (unsigned long long)st->st_nlink, (unsigned long long)st->st_mode,
        (long long)st->st_size, (long long)st->st_blocks);
}

int
main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    printf("abi %zu %zu %zu %zu %zu %zu %zu %zu %zu %zu %zu %zu\n",
        sizeof(struct stat), sizeof(mode_t), offsetof(struct stat, st_dev),
        offsetof(struct stat, st_ino), offsetof(struct stat, st_nlink),
        offsetof(struct stat, st_mode), offsetof(struct stat, st_rdev),
        offsetof(struct stat, st_atim), offsetof(struct stat, st_mtim),
        offsetof(struct stat, st_ctim), offsetof(struct stat, st_size),
        offsetof(struct stat, st_blocks));
    struct stat st;
    if (lstat(argv[1], &st) != 0) {
        perror("lstat");
        return 1;
    }
    print_stat("lstat", &st);
    if (fstatat(AT_FDCWD, argv[1], &st, AT_SYMLINK_NOFOLLOW) != 0) {
        perror("fstatat");
        return 1;
    }
    print_stat("fstatat", &st);
    return 0;
}
