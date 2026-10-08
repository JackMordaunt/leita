#+build linux
package sonar_history

import "core:os"
import "core:sys/linux"

// Lock is a lock taken on a file, held until unlock or the process ends.
Lock :: struct {
	file: ^os.File,
}

// lock takes an exclusive lock on the file at path, making it if it is missing,
// without waiting: flock, which the kernel drops when the last descriptor of
// the open file closes, so with the process, as flock(2) has it.
lock :: proc(path: string) -> (l: Lock, result: Lock_Result) {
	f, err := os.open(path, {.Read, .Write, .Create}, os.Permissions_Read_Write_All)
	if err != nil {
		return {}, .Failed
	}
	errno := linux.flock(linux.Fd(os.fd(f)), {.EX, .NB})
	if errno == .NONE {
		return {f}, .Taken
	}
	os.close(f)
	return {}, .Held if errno == .EWOULDBLOCK else .Failed
}

// unlock lets the lock go.
unlock :: proc(l: ^Lock) {
	if l.file != nil {
		os.close(l.file)
	}
	l^ = {}
}
