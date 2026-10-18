package report

import "core:strings"
import "core:testing"
import "core:time"

// A machine with no font installed still exports a PDF, set in the face pdf
// carries, accented and Cyrillic names and all.
@(test)
a_pdf_needs_no_installed_font :: proc(t: ^testing.T) {
	files := []Entry {
		{path = "/data/Größe/café.bin", bytes = 2 << 20},
		{path = "/data/Привет.txt", bytes = 1 << 20},
	}
	r := Report {
		version       = "test",
		target        = "/data",
		bytes         = 3 << 20,
		files         = 2,
		largest_files = files,
	}
	sb := strings.builder_make(context.temp_allocator)
	err := write_pdf(strings.to_writer(&sb), &r, .A4, installed = false)
	if !testing.expect_value(t, err, Error.None) {
		return
	}
	one := strings.to_string(sb)
	testing.expect(t, strings.has_prefix(one, "%PDF-1.7") && strings.has_suffix(one, "%%EOF\n"))
	testing.expect(t, strings.contains(one, "LiberationSans"), "not set in the carried face")
}

// The line under a PDF's target says a made-up disk is one in place of naming
// the engine, and names the engine of a real disk.
@(test)
a_pdf_header_says_when_the_disk_is_made_up :: proc(t: ^testing.T) {
	r := Report {
		version  = "test",
		duration = 1500 * time.Millisecond,
		engine   = .Walk,
	}
	testing.expect(t, strings.contains(header_line(&r), " by walk."))
	testing.expect(t, !strings.contains(header_line(&r), "made-up"))

	r.engine = .Synthetic
	line := header_line(&r)
	testing.expect(t, strings.contains(line, "This report is of a made-up disk: LEITA_SYNTHETIC was set."))
	testing.expect(t, !strings.contains(line, "by synthetic"))
	testing.expect(t, strings.contains(line, ". This report is of"), line)
}
