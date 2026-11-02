package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

print_stat :: proc(label: string, st: posix.stat_t) {
	fmt.printfln("%s %d %d %d %d %d %d", label, u64(st.st_dev), u64(st.st_ino), u64(st.st_nlink), u64(transmute(u16)st.st_mode), i64(st.st_size), i64(st.st_blocks))
}

main :: proc() {
	if len(os.args) != 2 {os.exit(2)}
	fmt.printfln("abi %d %d %d %d %d %d %d %d %d %d %d %d", size_of(posix.stat_t), size_of(posix.mode_t), offset_of(posix.stat_t, st_dev), offset_of(posix.stat_t, st_ino), offset_of(posix.stat_t, st_nlink), offset_of(posix.stat_t, st_mode), offset_of(posix.stat_t, st_rdev), offset_of(posix.stat_t, st_atim), offset_of(posix.stat_t, st_mtim), offset_of(posix.stat_t, st_ctim), offset_of(posix.stat_t, st_size), offset_of(posix.stat_t, st_blocks))
	path := strings.clone_to_cstring(os.args[1], context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(path, &st) != .OK {os.exit(1)}
	print_stat("lstat", st)
	if posix.fstatat(posix.AT_FDCWD, path, &st, {.SYMLINK_NOFOLLOW}) != .OK {os.exit(1)}
	print_stat("fstatat", st)
}
