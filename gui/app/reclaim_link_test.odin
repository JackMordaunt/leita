package leita_app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

/*
A directory link is not a directory newest_modification will offer. On Windows
the link is a junction: lstat calls it a directory, and files.is_link is what
refuses it. The real directory beside it still counts. Nothing is deleted, and
the file the link names is still there.
*/
@(test)
newest_modification_rejects_a_directory_link :: proc(t: ^testing.T) {
	base, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_reclaim_link_mod", strings.trim_right(base, `/\`))
	outside := fmt.tprintf("%s-outside", root)
	link := fmt.tprintf("%s/link", root)
	keep := fmt.tprintf("%s/keep", outside)
	// remove_all on Windows follows a junction left by a failed run.
	os.remove(link)
	os.remove_all(root)
	os.remove_all(outside)
	defer {
		os.remove(link)
		os.remove_all(root)
		os.remove_all(outside)
	}
	testing.expect(t, os.make_directory(root) == nil)
	testing.expect(t, os.make_directory(outside) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/real", root)) == nil)
	testing.expect(t, os.write_entire_file(keep, "keep") == nil)
	testing.expect(t, link_directory(outside, link), "could not make a directory link")

	_, linked := newest_modification(link)
	testing.expect(t, !linked, "a directory link is not offered")
	_, real := newest_modification(fmt.tprintf("%s/real", root))
	testing.expect(t, real, "a real directory still is")
	_, missing := newest_modification(fmt.tprintf("%s/missing", root))
	testing.expect(t, !missing, "a missing path is not a directory")
	data, read_err := os.read_entire_file(keep, context.temp_allocator)
	testing.expect(t, read_err == nil && string(data) == "keep", "the target was not touched")
}
