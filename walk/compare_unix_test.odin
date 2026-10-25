#+build linux, darwin
package walk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// A tree and what it is for.
Case :: struct {
	name:  string,
	build: proc(t: ^testing.T, root: string),
	// The tree holds more than one name of a file, which du -l counts again.
	linked: bool,
}

BODY_LEN :: 1 << 20

put :: proc(t: ^testing.T, path: string, length: int) {
	body := make([]byte, length, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

dir :: proc(t: ^testing.T, path: string) {
	testing.expectf(t, os.make_directory_all(path) == nil, "could not make %s", path)
}

common_cases := [?]Case {
	{name = "empty tree", build = proc(t: ^testing.T, root: string) {}},
	{name = "empty files", build = proc(t: ^testing.T, root: string) {
			put(t, fmt.tprintf("%s/empty", root), 0)
			put(t, fmt.tprintf("%s/also empty", root), 0)
		}},
	// One byte, a page, a page and a byte, a megabyte: the rounding to blocks.
	{name = "sizes around a block", build = proc(t: ^testing.T, root: string) {
			for size in ([?]int{1, 511, 512, 4095, 4096, 4097, 8192, 65_537, BODY_LEN}) {
				put(t, fmt.tprintf("%s/f%d", root, size), size)
			}
		}},
	{name = "hole only", build = proc(t: ^testing.T, root: string) {
			f, err := os.open(fmt.tprintf("%s/hole", root), {.Write, .Create, .Trunc})
			testing.expect(t, err == nil)
			testing.expect(t, os.truncate(f, BODY_LEN) == nil)
			os.close(f)
		}},
	{name = "data between holes", build = proc(t: ^testing.T, root: string) {
			f, err := os.open(fmt.tprintf("%s/scatter", root), {.Write, .Create, .Trunc})
			testing.expect(t, err == nil)
			one := []byte{'x'}
			for at in ([?]i64{0, 100_000, 300_001, BODY_LEN - 1}) {
				_, werr := os.write_at(f, one, at)
				testing.expect(t, werr == nil)
			}
			os.close(f)
		}},
	{name = "hard links", linked = true, build = proc(t: ^testing.T, root: string) {
			dir(t, fmt.tprintf("%s/a", root))
			dir(t, fmt.tprintf("%s/b", root))
			put(t, fmt.tprintf("%s/a/one", root), 100_000)
			testing.expect(t, os.link(fmt.tprintf("%s/a/one", root), fmt.tprintf("%s/b/two", root)) == nil)
			testing.expect(t, os.link(fmt.tprintf("%s/a/one", root), fmt.tprintf("%s/three", root)) == nil)
			put(t, fmt.tprintf("%s/lone", root), 100_000)
		}},
	{name = "symlinks", build = proc(t: ^testing.T, root: string) {
			put(t, fmt.tprintf("%s/target", root), 70_000)
			testing.expect(t, os.symlink("target", fmt.tprintf("%s/short", root)) == nil)
			long := strings.repeat("d/", 40, context.temp_allocator)
			testing.expect(t, os.symlink(long, fmt.tprintf("%s/long", root)) == nil)
			testing.expect(t, os.symlink("nowhere at all", fmt.tprintf("%s/dangling", root)) == nil)
			testing.expect(t, os.symlink(".", fmt.tprintf("%s/loop", root)) == nil)
		}},
	{name = "unicode names", build = proc(t: ^testing.T, root: string) {
			names := [?]string {
				"héllo", // NFC
				"héllo", // the same name in NFD: a different file here
				"日本語", // Japanese
				"\U0001F600 emoji.txt",
				"line\nbreak",
				"-dash",
				"tab\tname",
				"‮right-to-left",
			}
			for name, i in names {
				put(t, fmt.tprintf("%s/%s", root, name), 1000 * (i + 1))
			}
			dir(t, fmt.tprintf("%s/über 目录", root))
			put(t, fmt.tprintf("%s/über 目录/å", root), 5000)
		}},
	// Names of 255 bytes, the longest one component takes.
	{name = "longest names", build = proc(t: ^testing.T, root: string) {
			put(t, fmt.tprintf("%s/%s", root, strings.repeat("n", 255, context.temp_allocator)), 4097)
			dir(t, fmt.tprintf("%s/%s", root, strings.repeat("é", 127, context.temp_allocator)))
		}},
	{name = "many small files", build = proc(t: ^testing.T, root: string) {
			seed: u32 = 12345
			for d in 0 ..< 20 {
				sub := fmt.tprintf("%s/d%02d", root, d)
				dir(t, sub)
				for i in 0 ..< 60 {
					seed = seed * 1664525 + 1013904223
					put(t, fmt.tprintf("%s/f%02d", sub, i), int(seed >> 16) % 9000)
				}
			}
		}},
}
