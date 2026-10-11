/*
Package leaks tells LeakSanitizer what not to report in a window built under
-sanitize:address. A binary that opens the window imports it for its side effect:
`@(require) import "leaks"`.
*/
package leita_leaks

/*
What LeakSanitizer is not to report in a build under -sanitize:address: the one
allocation the system's EGL makes, through pthread_once, when SDL loads it for the
window's renderer, and keeps for the life of the process. It is the driver's, not
leita's; reported, it would bury a real leak under one nobody can fix here.
*/
@(export, link_name = "__lsan_default_suppressions")
lsan_default_suppressions :: proc "c" () -> cstring {
	return "leak:SDL_EGL_LoadLibrary\n"
}
