#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package schema
volume_state :: proc(_: string) -> (full, readonly: bool) {return false, false}
