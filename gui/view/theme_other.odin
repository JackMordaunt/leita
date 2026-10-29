#+build !windows
#+build !darwin
#+build !linux
package leita_view

// system_dark is light where the OS theme is not read.
system_dark :: proc() -> bool {
	return false
}
