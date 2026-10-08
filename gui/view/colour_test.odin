package sonar_view

import "core:testing"

import "../query"

@(test)
a_name_says_what_kind_of_file_it_is :: proc(t: ^testing.T) {
	testing.expect_value(t, kind_of("holiday.MKV", false), Kind.Video)
	testing.expect_value(t, kind_of("libssl.so.3", false), Kind.Binary)
	testing.expect_value(t, kind_of("notes.txt", false), Kind.Code)
	testing.expect_value(t, kind_of("backup.tar.gz", false), Kind.Archive)
	testing.expect_value(t, kind_of("win11.iso", false), Kind.Disk_Image)
	testing.expect_value(t, kind_of("README", false), Kind.Other)
	testing.expect_value(t, kind_of(".bashrc", false), Kind.Other)
	testing.expect_value(t, kind_of("node_modules", true), Kind.Build_Cache)
	testing.expect_value(t, kind_of("photos", true), Kind.Folder)
}

// What a build or cache directory holds is build and cache, whatever it is.
@(test)
a_file_under_a_cache_is_cache :: proc(t: ^testing.T) {
	arcs := []query.Arc {
		{name = "project", directory = true, depth = 1, up = -1},
		{name = "node_modules", directory = true, depth = 2, up = 0},
		{name = "logo.png", depth = 3, up = 1},
		{name = "photo.png", depth = 2, up = 0},
	}
	r := query.Rings_Result {
		arcs = arcs,
	}
	testing.expect_value(t, kind_in(&r, 2), Kind.Build_Cache)
	testing.expect_value(t, kind_in(&r, 3), Kind.Image)
	testing.expect_value(t, kind_in(&r, 0), Kind.Folder)
}
