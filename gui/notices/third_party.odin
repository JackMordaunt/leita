package leita_notices

import "core:fmt"
import "core:strings"

// Font_Family is one family a PDF may embed from the machine it is written
// on. pdf/system.odin names the files; this names the family and its licence.
Font_Family :: struct {
	name:    string,
	role:    string,
	licence: string,
}

// PDF_FONTS are the families pdf/system.odin searches, in the order that
// file tries the sans-serif and then its fallbacks. None of these files is
// in this repository.
PDF_FONTS := [?]Font_Family {
	{"Liberation Sans", "sans-serif, when installed", "SIL Open Font License 1.1"},
	{
		"Noto Sans, Noto Sans CJK, Noto Sans Arabic, Noto Sans Hebrew, " +
		"Noto Sans Devanagari, Noto Sans Thai, Noto Sans Symbols 2",
		"sans-serif or a fallback",
		"SIL Open Font License 1.1",
	},
	{"DejaVu Sans", "sans-serif", "Bitstream Vera licence"},
	{"Droid Sans Fallback", "CJK fallback", "Apache-2.0"},
	{"WenQuanYi Micro Hei", "CJK fallback", "GPL-3.0 with a font embedding exception"},
	{
		"Arial, Arial Unicode, Segoe UI, Segoe UI Symbol, MS Gothic, Microsoft YaHei",
		"sans-serif or a fallback, from the user's own Windows or macOS install",
		"Microsoft",
	},
}

// write_third_party renders THIRD_PARTY.md into b: every notice, then the
// fonts a PDF may embed. One procedure, so the committed file and the window's
// list are the same text or the test fails.
write_third_party :: proc(b: ^strings.Builder) {
	strings.write_string(
		b,
		`# Third-party notices

Components by other authors that are included with leita remain under their
own licences. Those licences govern those components. leita's licence
(LICENSE.md, section 9) points here. This file travels with the program,
because several of those licences require their notice to.

This file is rendered from the notices the window's About shows, the list
ALL in gui/notices/notices.odin, plus WINDOWS, which only a Windows build
links (the libcurl Odin bundles, carrying Mbed TLS and zlib). The test in
gui/notices fails when the committed file is not that rendering. To
regenerate it, run that test with LEITA_WRITE_THIRD_PARTY=1.

## Components

`,
	)
	write_notices(b, ALL[:])
	strings.write_string(
		b,
		`## Linked on Windows only

A Windows build links the libcurl Odin bundles in place of a system curl,
and that library carries these. Other builds link the system's curl and do
not ship them.

`,
	)
	write_notices(b, WINDOWS[:])
	write_fonts(b)
}

// write_notices writes each component's name, version where one is recorded,
// licence and the notice text its licence asks to travel with the program.
@(private)
write_notices :: proc(b: ^strings.Builder, list: []Notice) {
	for n in list {
		if n.version != "" {
			fmt.sbprintf(b, "### %s %s\n\n", n.name, n.version)
		} else {
			fmt.sbprintf(b, "### %s\n\n", n.name)
		}
		fmt.sbprintf(b, "Licence: %s\n%s\n\n", n.licence, n.url)
		strings.write_string(b, n.text)
		if !strings.has_suffix(n.text, "\n") {
			strings.write_byte(b, '\n')
		}
		strings.write_byte(b, '\n')
	}
}

// write_fonts says which faces a PDF may embed. The one leita ships, Liberation
// Sans, is a component above with its licence text, the SIL Open Font License
// 1.1, written once there. The rest come from the machine, so they are named
// with their licences and nothing more.
@(private)
write_fonts :: proc(b: ^strings.Builder) {
	strings.write_string(
		b,
		`## Fonts

A PDF embeds a font from the machine it is written on (pdf/system.odin), and
only a face whose OS/2 fsType allows embedding. The one font leita ships is
Liberation Sans, listed under Components above with its licence text, the SIL
Open Font License 1.1. That text is written once, there; the table below
names the licence of each family and does not repeat it.

leita does not ship the families below. This table names each with its
licence.

Arial, Arial Unicode, Segoe UI, Segoe UI Symbol, MS Gothic and Microsoft
YaHei are Microsoft fonts. A PDF may embed one from the user's own Windows
or macOS install. leita never distributes them.

| Family | A PDF may embed it as | Licence |
| --- | --- | --- |
`,
	)
	for f in PDF_FONTS {
		fmt.sbprintf(b, "| %s | %s | %s |\n", f.name, f.role, f.licence)
	}
}
