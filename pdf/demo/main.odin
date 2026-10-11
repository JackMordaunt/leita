/*
Demo writes a two-page sample disk report with package pdf, in this machine's
fonts, to the path it is given:

	odin run pdf/demo -collection:jm=jm -- /tmp/report.pdf
	pdftotext /tmp/report.pdf -

Its rows are made up: names in several scripts, sizes falling away, each with
a bar to its share of the largest.
*/
package demo

import pdf ".."
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"

Row :: struct {
	name: string,
	size: u64,
}

ROWS := [?]Row {
	{"Videos/2025 holiday.mov", 48_318_382_080},
	{"日本語のファイル.txt", 21_474_836_480},
	{"Photos/Ærøskøbing/IMG_0412.HEIC", 9_663_676_416},
	{"文档/年度报告-最终版.pdf", 6_442_450_944},
	{"Музыка/плейлист.m3u", 3_221_225_472},
	{"사진/가족 여행.zip", 2_147_483_648},
	{"café/menu — résumé.docx", 1_073_741_824},
	{"Ελληνικά/σημειώσεις.md", 805_306_368},
	{"emoji 😀 📁 notes.txt", 536_870_912},
	{
		"node_modules/.cache/a-very-long-directory-name-that-will-not-fit-in-its-column/bundle.js",
		268_435_456,
	},
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: demo out.pdf")
		os.exit(2)
	}
	doc: pdf.Document
	pdf.init(&doc)
	defer pdf.destroy(&doc)
	pdf.set_info(
		&doc,
		{
			title = "Disk report: /home/jfm",
			producer = "leita pdf demo",
			created = time.unix(1791547200, 0),
		},
	)
	sans, ok := pdf.add_system_fonts(&doc)
	if !ok {
		fmt.eprintln("demo: no system font found")
		os.exit(1)
	}

	ink := pdf.Color{0.13, 0.15, 0.18}
	muted := pdf.Color{0.45, 0.48, 0.52}
	bar := pdf.Color{0.22, 0.47, 0.85}
	rule := pdf.Color{0.85, 0.87, 0.9}
	left, right: f32 = 48, pdf.A4.x - 48
	size_col := right
	bar_col := right - 170
	name_width := bar_col - left - 90

	rows_per_page := 10
	for i := 0; i < len(ROWS) * 2; i += 1 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if i % rows_per_page == 0 {
			pdf.add_page(&doc, pdf.A4)
			pdf.draw_text(&doc, left, 64, "Disk report", sans, 22, ink)
			pdf.draw_text(
				&doc,
				left,
				84,
				"/home/jfm · scanned 2026-10-09 12:00 UTC",
				sans,
				10,
				muted,
			)
			pdf.add_link(&doc, right - 120, 74, 120, 12, "https://mordaunt.dev/code/leita")
			pdf.draw_text(&doc, right, 84, "mordaunt.dev/code/leita", sans, 10, bar, .Right)
			pdf.draw_text(&doc, left, 120, "Name", sans, 9, muted)
			pdf.draw_text(&doc, size_col, 120, "Size", sans, 9, muted, .Right)
			pdf.stroke_line(&doc, left, 126, right, 126, ink, 0.75)
		}
		row := ROWS[i % len(ROWS)]
		y := 146 + f32(i % rows_per_page) * 24
		pdf.draw_text_fit(&doc, left, y, row.name, sans, 10, name_width, ink)
		share := f32(f64(row.size) / f64(ROWS[0].size))
		pdf.fill_rect(&doc, bar_col, y - 8, 100 * share, 8, bar)
		pdf.stroke_rect(&doc, bar_col, y - 8, 100, 8, rule, 0.5)
		pdf.draw_text(
			&doc,
			size_col,
			y,
			fmt.tprintf("%.1f GiB", f64(row.size) / (1 << 30)),
			sans,
			10,
			ink,
			.Right,
		)
		pdf.stroke_line(&doc, left, y + 8, right, y + 8, rule, 0.5)
	}
	for p in 0 ..< pdf.page_count(&doc) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		pdf.set_page(&doc, p)
		footer := fmt.tprintf("Page %d of %d", p + 1, pdf.page_count(&doc))
		size := pdf.page_size(&doc)
		pdf.draw_text(&doc, size.x / 2, size.y - 36, footer, sans, 9, muted, .Center)
	}

	f, err := os.open(os.args[1], {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if err != nil {
		fmt.eprintln("demo:", err)
		os.exit(1)
	}
	defer os.close(f)
	if werr := pdf.write(&doc, os.to_stream(f)); werr != nil {
		fmt.eprintln("demo:", werr)
		os.exit(1)
	}
}
