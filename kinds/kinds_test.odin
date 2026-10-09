package kinds

import "core:testing"

@(test)
a_name_says_what_kind_of_file_it_is :: proc(t: ^testing.T) {
	testing.expect_value(t, of("holiday.MKV", false), Kind.Multimedia)
	testing.expect_value(t, of("libssl.so.3", false), Kind.Binary)
	testing.expect_value(t, of("notes.txt", false), Kind.Text)
	testing.expect_value(t, of("backup.tar.gz", false), Kind.Archive)
	testing.expect_value(t, of("win11.iso", false), Kind.Archive)
	testing.expect_value(t, of("README", false), Kind.Other)
	testing.expect_value(t, of(".bashrc", false), Kind.Other)
	testing.expect_value(t, of("node_modules", true), Kind.Cache)
	testing.expect_value(t, of("photos", true), Kind.Folder)
}
