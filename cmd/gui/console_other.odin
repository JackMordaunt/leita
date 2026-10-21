#+build !windows
package main

// attach_console does nothing off Windows, where the window is no GUI-subsystem
// program and keeps the terminal it was started from.
attach_console :: proc() {}
