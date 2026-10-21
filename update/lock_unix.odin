#+build linux, darwin, freebsd, openbsd, netbsd
package update

import "core:c"
import "core:strings"
import "core:time"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

// flock(2): the operations are the same on Linux, macOS and the BSDs.
@(private)
foreign libc {
	flock :: proc "c" (fd: posix.FD, operation: c.int) -> c.int ---
}

@(private)
LOCK_EX :: 2
@(private)
LOCK_NB :: 4

// Install_Lock is the lock taken, held until unlock or the process ends.
Install_Lock :: struct {
	fd: posix.FD,
}

// lock_install takes an exclusive lock on exe + LOCK_SUFFIX without waiting
// out another update. The lock belongs to this open file, so the system
// drops it when the process ends, as flock(2) has it. The file stays.
lock_install :: proc(exe: string, allocator := context.temp_allocator) -> (l: Install_Lock, result: Lock_Result) {
	path := strings.concatenate({exe, LOCK_SUFFIX}, allocator)
	fd := posix.open(
		strings.clone_to_cstring(path, allocator),
		// Close on exec: a process started meanwhile would otherwise hold
		// the open file, and the lock, past unlock.
		{.RDWR, .CREAT, .CLOEXEC},
		{.IRUSR, .IWUSR},
	)
	if fd < 0 {
		return {fd = -1}, .Failed
	}
	// A process being started by a thread beside this one holds a copy of
	// every open file from its fork until its exec closes the close-on-exec
	// ones. A few short retries outlast that window. An update that is
	// truly still going holds the lock for far longer, and is Held.
	errno: posix.Errno
	for _ in 0 ..< HELD_RETRIES {
		if flock(fd, LOCK_EX | LOCK_NB) == 0 {
			return {fd}, .Taken
		}
		errno = posix.errno()
		if errno != .EWOULDBLOCK {
			break
		}
		time.sleep(HELD_RETRY_WAIT)
	}
	posix.close(fd)
	return {fd = -1}, .Held if errno == .EWOULDBLOCK else .Failed
}

// HELD_RETRIES and HELD_RETRY_WAIT bound how long lock_install waits out a
// fork window before reporting the lock held: 100 ms in all.
@(private = "file")
HELD_RETRIES :: 10
@(private = "file")
HELD_RETRY_WAIT :: 10 * time.Millisecond

// unlock_install lets the lock go. The file is left in place.
unlock_install :: proc(l: ^Install_Lock) {
	if l.fd >= 0 {
		posix.close(l.fd)
	}
	l.fd = -1
}

// block_on_lock waits until path can be locked exclusively. The file must
// already exist: this is the test gate, not the install lock, and a missing
// gate fails closed instead of creating one and continuing.
block_on_lock :: proc(path: string, allocator := context.temp_allocator) -> bool {
	fd := posix.open(
		strings.clone_to_cstring(path, allocator),
		{.RDWR, .CLOEXEC},
		{},
	)
	if fd < 0 {
		return false
	}
	ok := flock(fd, LOCK_EX) == 0
	posix.close(fd)
	return ok
}
