package leita_notices

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// third_party_matches_the_notices renders THIRD_PARTY.md from ALL and WINDOWS
// and requires the committed file to be that rendering. LEITA_WRITE_THIRD_PARTY=1
// rewrites the file, which is how it is regenerated after a notice changes.
@(test)
third_party_matches_the_notices :: proc(t: ^testing.T) {
	root, found := repo_root()
	testing.expect(t, found, "the working directory is inside a leita checkout")

	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	defer strings.builder_destroy(&b)
	write_third_party(&b)
	got := strings.to_string(b)

	for n in ALL {
		testing.expect(t, len(n.text) > 0)
		testing.expectf(t, strings.contains(got, n.name), "the rendering omits %s", n.name)
		testing.expectf(
			t,
			strings.contains(got, n.licence),
			"the rendering omits the licence of %s",
			n.name,
		)
		testing.expectf(
			t,
			strings.contains(got, n.text),
			"the rendering omits the notice of %s",
			n.name,
		)
		if n.version != "" {
			testing.expectf(
				t,
				strings.contains(got, n.version),
				"the rendering omits %s %s",
				n.name,
				n.version,
			)
		}
	}
	for n in WINDOWS {
		testing.expectf(t, strings.contains(got, n.name), "the rendering omits %s", n.name)
		testing.expectf(
			t,
			strings.contains(got, n.text),
			"the rendering omits the notice of %s",
			n.name,
		)
	}
	for f in PDF_FONTS {
		testing.expectf(t, strings.contains(got, f.name), "the rendering omits %s", f.name)
		testing.expectf(
			t,
			strings.contains(got, f.licence),
			"the rendering omits the licence of %s",
			f.name,
		)
	}
	testing.expect_value(t, strings.count(got, "SIL OPEN FONT LICENSE Version 1.1"), 1)
	testing.expect(
		t,
		strings.contains(got, "Card 543"),
		"the place for the fallback sans is marked",
	)
	testing.expect(t, strings.contains(got, "leita never distributes them"))

	path := fmt.tprintf("%s/THIRD_PARTY.md", root)
	if os.get_env("LEITA_WRITE_THIRD_PARTY", context.temp_allocator) != "" {
		testing.expectf(t, os.write_entire_file(path, got) == nil, "could not write %s", path)
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(
		t,
		err == nil,
		"no %s; LEITA_WRITE_THIRD_PARTY=1 writes it from the notices",
		path,
	)
	testing.expect(
		t,
		string(data) == got,
		"THIRD_PARTY.md differs from the notices; LEITA_WRITE_THIRD_PARTY=1 rewrites it",
	)
}

// repo_root is the checkout that holds gui/notices, found by walking up from
// the working directory. just runs the test at the repository root, and a
// test started in the package directory still finds it.
@(private)
repo_root :: proc() -> (string, bool) {
	dir, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		return "", false
	}
	marker := "/gui/notices/notices.odin"
	buf: [1024]byte
	for _ in 0 ..< 12 {
		if len(dir) + len(marker) > len(buf) {
			return "", false
		}
		n := len(dir)
		copy(buf[:n], dir)
		copy(buf[n:], marker)
		if os.exists(string(buf[:n + len(marker)])) {
			return dir, true
		}
		next := os.dir(dir)
		if next == dir || next == "" || next == "." {
			return "", false
		}
		dir = next
	}
	return "", false
}
