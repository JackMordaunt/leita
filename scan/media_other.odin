#+build !darwin
#+build !linux
#+build !windows
package scan

// Nothing here asks other systems what stores a device.
@(private)
media_of :: proc(device: string) -> Media {
	return .Unknown
}
