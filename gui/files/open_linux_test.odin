#+build linux
package leita_files

import "core:fmt"
import "core:os"
import "core:testing"

// stand_in writes a program called name into bin that writes its arguments,
// one a line, to bin/given and exits with the number in bin/exit.
@(private = "file")
stand_in :: proc(t: ^testing.T, bin, name: string) {
	script := fmt.tprintf(
		"#!/bin/sh\nprintf '%%s\\n' \"$@\" > '%s/given'\nread code < '%s/exit'\nexit \"$code\"\n",
		bin,
		bin,
	)
	at := fmt.tprintf("%s/%s", bin, name)
	testing.expect(t, os.write_entire_file(at, script) == nil)
	testing.expect(t, os.chmod(at, {.Read_User, .Write_User, .Execute_User}) == nil)
}

@(private = "file")
bin_fixture :: proc(t: ^testing.T, name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	bin := fmt.tprintf("%s/leita_open_%s_%d", base, name, os.get_pid())
	os.remove_all(bin)
	testing.expect(t, os.make_directory(bin) == nil)
	return bin
}

// open_default hands the path to gio open whole, spaces and all, and says
// whether it went well: a stand-in gio, first on PATH, writes down what it was
// given and exits as told.
@(test)
open_hands_the_path_to_gio :: proc(t: ^testing.T) {
	bin := bin_fixture(t, "gio")
	defer os.remove_all(bin)
	stand_in(t, bin, "gio")
	path := os.get_env("PATH", context.temp_allocator)
	testing.expect(t, os.set_env("PATH", fmt.tprintf("%s:%s", bin, path)) == nil)
	defer os.set_env("PATH", path)

	opened := "/home/someone/Pictures/a photo.jpg"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/exit", bin), "0") == nil)
	testing.expect(t, open_default(opened), "gio went well")
	got, _ := os.read_entire_file(fmt.tprintf("%s/given", bin), context.temp_allocator)
	testing.expect_value(t, string(got), fmt.tprintf("open\n%s\n", opened))

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/exit", bin), "2") == nil)
	testing.expect(t, !open_default(opened), "gio failed")
}
