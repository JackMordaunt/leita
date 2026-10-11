#+build !windows
package ntfs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

// A volume is a block device or a file holding an image of one, and both open the
// same way, so a file standing in for an image exercises every path here without a
// device to read or the rights to read it.
@(private = "file")
image :: proc(t: ^testing.T, size: int) -> (path: string, content: []byte) {
	content = make([]byte, size, context.temp_allocator)
	for i in 0 ..< size {
		content[i] = byte(i * 7 + 1)
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	path = fmt.tprintf("%s/leita_volume_%d.img", dir, size)
	testing.expect(t, os.write_entire_file(path, content) == nil, "could not write the image")
	return
}

@(private = "file")
discard :: proc(path: string) {
	_ = os.remove(path)
}

@(test)
test_volume_read_at_offsets :: proc(t: ^testing.T) {
	path, content := image(t, 8192)
	defer discard(path)

	v, err := volume_open(path)
	testing.expect_value(t, err, Error.None)
	defer volume_close(&v)

	// A whole read, a tail read, an aligned middle and a single byte: the reader
	// works in whole clusters, so every offset it asks for is one of these shapes.
	spans := [][2]int{{0, 8192}, {4096, 4096}, {512, 1024}, {8191, 1}}
	for span in spans {
		off, size := span[0], span[1]
		buf := make([]byte, size, context.temp_allocator)
		testing.expect_value(t, volume_read_at(&v, buf, u64(off)), Error.None)
		testing.expectf(
			t,
			slice.equal(buf, content[off:off + size]),
			"wrong bytes at %d for %d",
			off,
			size,
		)
	}
}

@(test)
test_volume_read_past_the_end_is_short :: proc(t: ^testing.T) {
	path, _ := image(t, 1024)
	defer discard(path)

	v, err := volume_open(path)
	testing.expect_value(t, err, Error.None)
	defer volume_close(&v)

	// Asking for more than is there has to say so, or the tail of the buffer would
	// parse as records that were never read.
	buf := make([]byte, 4096, context.temp_allocator)
	testing.expect_value(t, volume_read_at(&v, buf, 0), Error.Short_Read)
	testing.expect_value(t, volume_read_at(&v, buf[:1], 1024), Error.Short_Read)
}

@(test)
test_volume_clone_reads_independently :: proc(t: ^testing.T) {
	path, content := image(t, 2048)
	defer discard(path)

	v, err := volume_open(path)
	testing.expect_value(t, err, Error.None)
	defer volume_close(&v)

	c, clone_err := volume_clone(&v)
	testing.expect_value(t, clone_err, Error.None)

	buf := make([]byte, 16, context.temp_allocator)
	testing.expect_value(t, volume_read_at(&c, buf, 100), Error.None)
	testing.expect_value(t, buf[0], content[100])

	// Closing a clone must leave the handle it was made from readable, or the first
	// worker to finish would take the rest of them with it.
	volume_close(&c)
	testing.expect(t, c.file == nil, "a closed volume still holds a handle")
	testing.expect_value(t, volume_read_at(&v, buf, 100), Error.None)
	testing.expect_value(t, buf[0], content[100])
}

@(test)
test_volume_open_missing_path :: proc(t: ^testing.T) {
	v, err := volume_open("/nonexistent/leita/volume.img")
	testing.expect_value(t, err, Error.Open_Failed)
	testing.expect(t, v.file == nil, "a failed open returned a handle")
}
