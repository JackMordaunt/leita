package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

/*
The command line asked for a JSON report of a directory writes one that reads
back, counting what the directory holds:

	<root>/a.txt           100 bytes
	<root>/sub/b.mp4       5000 bytes
	<root>/sub/c,"d".txt   1 byte
*/
@(test)
a_report_of_a_directory_reads_back :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/estoile_report_cli", dir)
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", root)) == nil)
	write :: proc(t: ^testing.T, path: string, size: int) {
		body := make([]byte, size, context.temp_allocator)
		testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
	}
	write(t, fmt.tprintf("%s/a.txt", root), 100)
	write(t, fmt.tprintf("%s/sub/b.mp4", root), 5000)
	write(t, fmt.tprintf("%s/sub/c,\"d\".txt", root), 1)
	out := fmt.tprintf("%s.json", root)
	defer os.remove(out)

	testing.expect_value(t, scan_and_say({target = root, report = out}), 0)

	data, read_err := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, read_err == nil, "no report written")
	v, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	top, is_object := v.(json.Object)
	testing.expect(t, is_object, "a report is one object")
	if !is_object {
		return
	}
	testing.expect_value(t, top["schema"].(json.String), "estoile.report/1")
	totals := top["totals"].(json.Object)
	testing.expect_value(t, totals["files"].(json.Integer), 3)
	testing.expect_value(t, totals["directories"].(json.Integer), 1)
	files := top["largest_files"].(json.Array)
	testing.expect_value(t, len(files), 3)
	testing.expect_value(
		t,
		files[0].(json.Object)["path"].(json.String),
		fmt.tprintf("%s/sub/b.mp4", root),
	)
	testing.expect(t, top["compared"].(json.Null) == nil, "the command line keeps no scans")
}

// A report the command line cannot write is refused before anything is read.
@(test)
a_report_it_cannot_write_is_refused :: proc(t: ^testing.T) {
	cases := [?]Options {
		{report = "out.pdf"},
		{report = "out.txt"},
		{report = "-"},
		{report = "out.json", format = "xml"},
		{format = "csv"},
		{top = 10},
		{report = "out.json", live = true},
	}
	for c in cases {
		testing.expectf(t, scan_and_say(c) == 1, "%v was not refused", c)
	}
}
