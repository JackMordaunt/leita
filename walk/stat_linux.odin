#+build linux
package walk

import "core:sync"
import "core:sys/linux"

/*
statx where the kernel has it, fstatat where it does not.

statx is Linux 4.11, and a kernel without it answers the raw call with ENOSYS. The
libc a binary is linked against does not matter: the call is made here by number.
Only ENOSYS means the call is missing, so only ENOSYS falls back. Any other errno
is statx's answer about the entry, and means what it did before the fallback
existed: kind_of calls the entry Unknown, left out, its directory marked unread.
The fallback is never a way past a refusal.

fstatat fills in everything the walk reads from statx except two things, the
mount-root flag and the mount id (Linux 5.8). Those are left out of the answer's
mask and attributes, so the walk sees what it sees on a kernel between 4.11 and
5.8: a bind mount is walked as a directory (walked_elsewhere), which the tree
records as a gap (scan.Gap.Mount_Id). A size is never guessed: an entry fstatat
cannot answer is Unknown as before, never a file of 0 bytes.

Once statx has answered ENOSYS it is not asked again by this process; a kernel does
not gain a system call.
*/
@(private)
statx_missing: b32

@(private)
statx_compat :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	return stat_with(linux.statx, dir, name, flags, mask, st)
}

// statx_compat with the kernel's statx replaced by `ask`, so a test can stand in
// for a kernel that lacks it.
@(private)
stat_with :: proc "contextless" (
	ask: Statx_Call,
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	mask: linux.Statx_Mask,
	st: ^linux.Statx,
) -> linux.Errno {
	if !sync.atomic_load(&statx_missing) {
		errno := ask(dir, name, flags, mask, st)
		if errno != .ENOSYS {
			return errno
		}
		sync.atomic_store(&statx_missing, true)
	}
	return stat_fallback(dir, name, flags, st)
}

// Statx's answer built from fstatat's, with only the fields fstatat gives named in
// the mask.
@(private)
stat_fallback :: proc "contextless" (
	dir: linux.Fd,
	name: cstring,
	flags: linux.FD_Flags,
	st: ^linux.Statx,
) -> linux.Errno {
	when size_of(int) != 8 {
		// fstatat64's layout is not the one Stat has here; there is no fallback.
		return .ENOSYS
	} else {
		old: linux.Stat
		// AT_EMPTY_PATH, AT_SYMLINK_NOFOLLOW and AT_NO_AUTOMOUNT mean the same to both.
		if errno := linux.fstatat(dir, name, &old, flags); errno != .NONE {
			return errno
		}
		st^ = {}
		st.mask = {.TYPE, .MODE, .NLINK, .INO, .SIZE, .BLOCKS}
		st.mode = old.mode
		st.nlink = u32(old.nlink)
		st.ino = old.ino
		st.size = u64(old.size)
		st.blocks = u64(old.blocks)
		st.blksize = u32(old.blksize)
		st.dev_major, st.dev_minor = dev_split(u64(old.dev))
		st.rdev_major, st.rdev_minor = dev_split(u64(old.rdev))
		return .NONE
	}
}

// major and minor of a dev_t as the kernel packs it (glibc's gnu_dev_major and
// gnu_dev_minor).
@(private)
dev_split :: proc "contextless" (dev: u64) -> (major, minor: u32) {
	major = u32((dev >> 8) & 0xfff | (dev >> 32) & ~u64(0xfff))
	minor = u32(dev & 0xff | (dev >> 12) & ~u64(0xff))
	return
}
