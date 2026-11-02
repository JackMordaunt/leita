#+build freebsd
package survey

// FreeBSD has no persistent change source implemented yet, so fill reads whole.
fixture_requires_full :: proc(root: string) -> bool {
	return true
}
