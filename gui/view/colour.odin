package sonar_view

import "core:path/filepath"
import "core:strings"

import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"

import "../query"

/*
What the colour of an arc or a box says. Which layout draws the directory is the
mode; what the colours mean is chosen apart from it, so each way of colouring
works in each layout.

By folder, every entry of the first ring keeps a hue and everything under it is
that hue, lighter each level: where the space went. By type, a file is coloured by
what it is, from its name, and everything under a build or cache directory by
that: what kind of thing the space went on, and how much of it is safe to clear.
Directories are left neutral by type, so the files they hold stand out.
*/

Colouring :: enum u8 {
	Folder,
	Type,
}

// Kind is what an entry is, for colouring by type.
Kind :: enum u8 {
	Folder, // a directory, neither build nor cache
	Multimedia, // video and audio
	Image,
	Archive, // archives, packages and disk images
	Document,
	Text, // source code and text
	Binary,
	Cache, // a build or cache directory, and all it holds
	Other,
}

KIND_NAMES := [Kind]string {
	.Folder     = "Folder",
	.Multimedia = "Multimedia",
	.Image      = "Image",
	.Archive    = "Archive",
	.Document   = "Document",
	.Text       = "Text",
	.Binary     = "Binary",
	.Cache      = "Cache",
	.Other      = "Other",
}

/*
KIND_COLOURS are the kinds' colours: seven, every pair of which can be told apart
wherever they meet, as a treemap or a sunburst puts any two side by side. Each is
used as it is, never lightened, which would undo the separation.

They were checked with the dataviz skill's validator over all pairs, on Primer's
white and its dark ground, where it reported normal-vision ΔE at least 15.1,
protan and deutan ΔE at least 8.2 (OKLab ×100), and contrast at least 3:1 on
white but 2.96:1 for the berry on dark, which the legend and labels relieve:

	node validate_palette.js "#984260,#5b6c00,#2e64a6,#b07a20,#249c74,#bb76b5,#4693f1" \
		--mode light --surface "#ffffff" --pairs all
	node validate_palette.js "#984260,#5b6c00,#2e64a6,#b07a20,#249c74,#bb76b5,#4693f1" \
		--mode dark --surface "#0d1117" --pairs all

Run it again after any change here; the_kinds_colours_stay_apart checks the
normal-vision floor alone. The seven came from a max-clique search over colours
generated in both lightness bands, which found no eighth to add, so the kinds are
seven and what is not a kind is grey.
*/
@(rodata)
KIND_COLOURS := [Kind]ops.Color {
	.Folder     = {},
	.Multimedia = {0xbb, 0x76, 0xb5, 255}, // orchid
	.Image      = {0x24, 0x9c, 0x74, 255}, // green
	.Archive    = {0x98, 0x42, 0x60, 255}, // berry
	.Document   = {0x46, 0x93, 0xf1, 255}, // light blue
	.Text       = {0x2e, 0x64, 0xa6, 255}, // blue
	.Binary     = {0x5b, 0x6c, 0x00, 255}, // olive
	.Cache      = {0xb0, 0x7a, 0x20, 255}, // ochre
	.Other      = {},
}

// kind_colour is a kind's colour; what is not a kind of content is a grey set
// on the page's ground, far lighter (or darker) than any of the seven.
kind_colour :: proc(kind: Kind) -> ops.Color {
	if kind == .Folder || kind == .Other {
		// Neutral muted is translucent; set it on the page's ground.
		return mix(primer.color(.Fg_Color_Muted), primer.color(.Bg_Color_Default), 0.7)
	}
	return KIND_COLOURS[kind]
}

// BUILD_CACHE are directory names that hold what a tool made and will make again.
@(rodata)
BUILD_CACHE := [?]string {
	"node_modules",
	"target",
	"build",
	"dist",
	"out",
	".cache",
	"cache",
	"Cache",
	"__pycache__",
	".gradle",
	".m2",
	".venv",
	"venv",
	".tox",
	".next",
	".nuxt",
	".parcel-cache",
	".turbo",
	"DerivedData",
	".zig-cache",
	"zig-cache",
	".odin-cache",
}

@(private)
EXTENSIONS := [?]struct {
	ext:  string,
	kind: Kind,
} {
	{"mp4", .Multimedia},
	{"mkv", .Multimedia},
	{"mov", .Multimedia},
	{"avi", .Multimedia},
	{"webm", .Multimedia},
	{"m4v", .Multimedia},
	{"wmv", .Multimedia},
	{"mp3", .Multimedia},
	{"flac", .Multimedia},
	{"wav", .Multimedia},
	{"ogg", .Multimedia},
	{"opus", .Multimedia},
	{"m4a", .Multimedia},
	{"aac", .Multimedia},
	{"png", .Image},
	{"jpg", .Image},
	{"jpeg", .Image},
	{"gif", .Image},
	{"webp", .Image},
	{"heic", .Image},
	{"raw", .Image},
	{"cr2", .Image},
	{"nef", .Image},
	{"tif", .Image},
	{"tiff", .Image},
	{"bmp", .Image},
	{"svg", .Image},
	{"psd", .Image},
	{"zip", .Archive},
	{"tar", .Archive},
	{"gz", .Archive},
	{"tgz", .Archive},
	{"xz", .Archive},
	{"zst", .Archive},
	{"bz2", .Archive},
	{"7z", .Archive},
	{"rar", .Archive},
	{"pack", .Archive},
	{"deb", .Archive},
	{"rpm", .Archive},
	{"jar", .Archive},
	{"iso", .Archive},
	{"img", .Archive},
	{"qcow2", .Archive},
	{"vdi", .Archive},
	{"vmdk", .Archive},
	{"vhd", .Archive},
	{"vhdx", .Archive},
	{"dmg", .Archive},
	{"pdf", .Document},
	{"doc", .Document},
	{"docx", .Document},
	{"odt", .Document},
	{"xls", .Document},
	{"xlsx", .Document},
	{"ods", .Document},
	{"ppt", .Document},
	{"pptx", .Document},
	{"odp", .Document},
	{"epub", .Document},
	{"txt", .Text},
	{"md", .Text},
	{"json", .Text},
	{"yaml", .Text},
	{"yml", .Text},
	{"toml", .Text},
	{"xml", .Text},
	{"csv", .Text},
	{"sql", .Text},
	{"log", .Text},
	{"odin", .Text},
	{"c", .Text},
	{"h", .Text},
	{"cc", .Text},
	{"cpp", .Text},
	{"hpp", .Text},
	{"go", .Text},
	{"rs", .Text},
	{"py", .Text},
	{"js", .Text},
	{"ts", .Text},
	{"tsx", .Text},
	{"jsx", .Text},
	{"java", .Text},
	{"kt", .Text},
	{"swift", .Text},
	{"rb", .Text},
	{"php", .Text},
	{"sh", .Text},
	{"lua", .Text},
	{"zig", .Text},
	{"css", .Text},
	{"html", .Text},
	{"exe", .Binary},
	{"dll", .Binary},
	{"so", .Binary},
	{"a", .Binary},
	{"o", .Binary},
	{"lib", .Binary},
	{"bin", .Binary},
	{"wasm", .Binary},
	{"class", .Binary},
	{"pyc", .Binary},
	{"gguf", .Binary},
	{"safetensors", .Binary},
}

// kind_of is what a file is, by its name's extension, or what a directory is, by
// its name.
kind_of :: proc(name: string, directory: bool) -> Kind {
	if directory {
		for n in BUILD_CACHE {
			if name == n {
				return .Cache
			}
		}
		return .Folder
	}
	ext := filepath.ext(name)
	if len(ext) < 2 {
		return .Other
	}
	ext = ext[1:]
	// A shared library's version follows its extension: libfoo.so.1.2.
	if strings.contains(name, ".so.") {
		return .Binary
	}
	for e in EXTENSIONS {
		if strings.equal_fold(ext, e.ext) {
			return e.kind
		}
	}
	return .Other
}

// kind_in is what the arc at stands for is, by type: Cache if it or a
// directory it lies in is a build or cache directory, else its own kind.
kind_in :: proc(r: ^query.Rings_Result, at: int) -> Kind {
	for up := at; up >= 0; up = int(r.arcs[up].up) {
		a := r.arcs[up]
		if a.directory && kind_of(a.name, true) == .Cache {
			return .Cache
		}
	}
	a := r.arcs[at]
	return kind_of(a.name, a.directory)
}

/*
fill_of is the colour of the arc at, by the colouring chosen. framed is for a
layout in which a directory is the frame its contents sit in, the treemap, which
lightens it so its contents stand out.

A lit entry is its own colour taken toward the ink, darker on a light ground and
lighter on a dark one, whatever its colour was: an arc of the first ring is drawn
at its hue's full strength, so a lit colour that was only that would not show.
*/
@(private)
fill_of :: proc(m: ^Model, r: ^query.Rings_Result, at: int, lit, framed: bool) -> ops.Color {
	a := r.arcs[at]
	bg := primer.color(.Bg_Color_Default)
	fill: ops.Color
	switch m.colour {
	case .Folder:
		fill = primer.color(BRANCHES[int(a.branch) % len(BRANCHES)])
		fade := FADE * f32(a.depth - 1) + (a.directory ? (framed ? 0.45 : 0) : FILE_FADE)
		fill = mix(fill, bg, min(fade, 0.85))
	case .Type:
		// The seven are used as they are; a framed directory alone is lightened.
		fill = kind_colour(kind_in(r, at))
		if framed && a.directory {
			fill = mix(fill, bg, 0.45)
		}
	}
	if lit {
		fill = mix(fill, primer.color(.Fg_Color_Default), LIT)
	}
	return fill
}

// LIT is how far a lit entry's colour goes toward the ink.
LIT :: f32(0.3)

// LEGEND_DOT is a legend swatch's diameter, LEGEND_GAP the space between two
// chips, LEGEND_INSET the space between a chip's swatch and its name, and
// LEGEND_LINE_GAP the space between two lines of chips.
LEGEND_DOT      :: f32(8)
LEGEND_GAP      :: f32(10)
LEGEND_INSET    :: f32(4)
LEGEND_LINE_GAP :: f32(2)

// legend_shown is whether a kind has a chip: the kinds of content, not a plain
// folder or what is none of them.
@(private)
legend_shown :: proc(kind: Kind) -> bool {
	return kind != .Folder && kind != .Other
}

// legend_line_count is how many lines the chips take across width, wrapped as the
// legend wraps them.
@(private)
legend_line_count :: proc(gtx: ^ui.Ctx, width: f32) -> int {
	if !ui.is_finite(width) {
		return 1
	}
	st := primer.text_style(.Small)
	font := primer.font_for(gtx, st.weight)
	lines, x := 1, f32(0)
	for kind in Kind {
		if !legend_shown(kind) {
			continue
		}
		w := LEGEND_DOT + LEGEND_INSET + design.layout_style(gtx, KIND_NAMES[kind], st, font).width
		switch {
		case x == 0:
			x = w
		case x + LEGEND_GAP + w > width - 1:
			lines += 1
			x = w
		case:
			x += LEGEND_GAP + w
		}
	}
	return lines
}

/*
legend_row is the line under the switches that says what the colours mean: by
type, a chip for each kind; by folder, that the colours follow the folders. Its
height is what the chips take at this width, in either colouring, so switching
colouring never moves the chart below it.
*/
@(private)
legend_row :: proc(gtx: ^ui.Ctx, m: ^Model) {
	lines := legend_line_count(gtx, gtx.constraints.max.x)
	line := primer.text_style(.Small).line_height
	height := f32(lines) * line + f32(lines - 1) * LEGEND_LINE_GAP
	ui.sized(gtx, {min = {0, height}, max = {ui.INF, height}})
	switch m.colour {
	case .Type:
		legend(gtx)
	case .Folder:
		primer.text(
			gtx,
			"Coloured by top-level folder",
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
	}
}

// legend names the colours of colouring by type, the kinds of content in turn,
// wrapping onto more lines where the panel is narrow.
@(private)
legend :: proc(gtx: ^ui.Ctx) {
	if ui.wrap(gtx, gap = LEGEND_GAP, line_gap = LEGEND_LINE_GAP, align = .Center) {
		for kind in Kind {
			if !legend_shown(kind) {
				continue
			}
			sc := ui.scope_open(gtx, kind)
			if ui.row(gtx, gap = LEGEND_INSET, align = .Center) {
				swatch(gtx, kind_colour(kind))
				primer.text(gtx, KIND_NAMES[kind], .Small, color = primer.color(.Fg_Color_Muted))
			}
			ui.scope_close(&sc)
		}
	}
}

// swatch is a legend's dot of colour c.
@(private)
swatch :: proc(gtx: ^ui.Ctx, c: ops.Color, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	ops.fill(gtx.scene, ui.circle({LEGEND_DOT / 2, LEGEND_DOT / 2}, LEGEND_DOT / 2), c)
	ui.widget_close(gtx, &p, {size = {LEGEND_DOT, LEGEND_DOT}})
}
