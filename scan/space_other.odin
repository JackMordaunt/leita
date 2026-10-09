#+build !darwin
#+build !linux
#+build !windows
package scan

// Nothing here asks other systems how large a filesystem is.
space :: proc(path: string) -> (total, free: u64, ok: bool) {
	return 0, 0, false
}
