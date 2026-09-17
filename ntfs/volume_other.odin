#+build !windows
package ntfs

// Raw volume access is only implemented for Windows. The parsing code above this
// layer is portable, so an image file reader for other platforms can slot in here.
Volume :: struct {
	_: int,
}

volume_open :: proc(path: string) -> (v: Volume, err: Error) {
	_ = path
	return {}, .Unsupported_Platform
}

volume_close :: proc(v: ^Volume) {
	_ = v
}

volume_read_at :: proc(v: ^Volume, buf: []byte, offset: u64) -> Error {
	_, _, _ = v, buf, offset
	return .Unsupported_Platform
}
