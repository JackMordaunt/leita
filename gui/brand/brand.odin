// Package brand is the window's marks. png(false) is the dark-ink mark, for
// a light window. png(true) is the cream mark, for a dark window. The
// slice lives as long as the process.
package brand

@(private)
light := #load("../../branding/mark-light.png")

@(private)
dark := #load("../../branding/mark-dark.png")

png :: proc(dark_window: bool) -> []byte {
	if dark_window {
		return dark[:]
	}
	return light[:]
}
