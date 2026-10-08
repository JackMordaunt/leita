package sonar_view

import "core:path/filepath"
import "core:strings"

import "jm:ui"
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
	Media, // video and audio
	Image,
	Archive, // archives, packages and disk images
	Document,
	Code,
	Binary,
	Build_Cache, // a build or cache directory, and all it holds
	Other,
}

KIND_NAMES := [Kind]string {
	.Folder      = "Folder",
	.Media       = "Video and audio",
	.Image       = "Image",
	.Archive     = "Archive and disk image",
	.Document    = "Document",
	.Code        = "Code and text",
	.Binary      = "Binary",
	.Build_Cache = "Build and cache",
	.Other       = "Other",
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
	.Folder      = {},
	.Media       = {0xbb, 0x76, 0xb5, 255}, // orchid
	.Image       = {0x24, 0x9c, 0x74, 255}, // green
	.Archive     = {0x98, 0x42, 0x60, 255}, // berry
	.Document    = {0x46, 0x93, 0xf1, 255}, // light blue
	.Code        = {0x2e, 0x64, 0xa6, 255}, // blue
	.Binary      = {0x5b, 0x6c, 0x00, 255}, // olive
	.Build_Cache = {0xb0, 0x7a, 0x20, 255}, // ochre
	.Other       = {},
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
	{"mp4", .Media},
	{"mkv", .Media},
	{"mov", .Media},
	{"avi", .Media},
	{"webm", .Media},
	{"m4v", .Media},
	{"wmv", .Media},
	{"mp3", .Media},
	{"flac", .Media},
	{"wav", .Media},
	{"ogg", .Media},
	{"opus", .Media},
	{"m4a", .Media},
	{"aac", .Media},
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
	{"txt", .Code},
	{"md", .Code},
	{"json", .Code},
	{"yaml", .Code},
	{"yml", .Code},
	{"toml", .Code},
	{"xml", .Code},
	{"csv", .Code},
	{"sql", .Code},
	{"log", .Code},
	{"odin", .Code},
	{"c", .Code},
	{"h", .Code},
	{"cc", .Code},
	{"cpp", .Code},
	{"hpp", .Code},
	{"go", .Code},
	{"rs", .Code},
	{"py", .Code},
	{"js", .Code},
	{"ts", .Code},
	{"tsx", .Code},
	{"jsx", .Code},
	{"java", .Code},
	{"kt", .Code},
	{"swift", .Code},
	{"rb", .Code},
	{"php", .Code},
	{"sh", .Code},
	{"lua", .Code},
	{"zig", .Code},
	{"css", .Code},
	{"html", .Code},
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
				return .Build_Cache
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

// kind_in is what the arc at stands for is, by type: Build_Cache if it or a
// directory it lies in is a build or cache directory, else its own kind.
kind_in :: proc(r: ^query.Rings_Result, at: int) -> Kind {
	for up := at; up >= 0; up = int(r.arcs[up].up) {
		a := r.arcs[up]
		if a.directory && kind_of(a.name, true) == .Build_Cache {
			return .Build_Cache
		}
	}
	a := r.arcs[at]
	return kind_of(a.name, a.directory)
}

/*
fill_of is the colour of the arc at, by the colouring chosen: full when lit, lighter
otherwise, by its depth when coloured by folder. framed is for a layout in which a
directory is the frame its contents sit in, the treemap, which lightens it further
so its contents stand out.
*/
@(private)
fill_of :: proc(m: ^Model, r: ^query.Rings_Result, at: int, lit, framed: bool) -> ops.Color {
	a := r.arcs[at]
	bg := primer.color(.Bg_Color_Default)
	switch m.colour {
	case .Folder:
		fill := primer.color(BRANCHES[int(a.branch) % len(BRANCHES)])
		if lit {
			return fill
		}
		fade := FADE * f32(a.depth - 1) + (a.directory ? (framed ? 0.45 : 0) : FILE_FADE)
		return mix(fill, bg, min(fade, 0.85))
	case .Type:
		fill := kind_colour(kind_in(r, at))
		if lit {
			// Darker, not lighter: the seven are used as they are, so a lit one
			// stands apart by going toward the ink.
			return mix(fill, primer.color(.Fg_Color_Default), 0.3)
		}
		// A framed directory is lightened so its contents stand out; its contents,
		// the files, keep their colour exactly.
		return mix(fill, bg, 0.45) if framed && a.directory else fill
	}
	return bg
}

// LEGEND_DOT is a legend swatch's diameter.
LEGEND_DOT :: f32(8)

// legend names the colours of colouring by type, the kinds of content in turn,
// wrapping onto more lines where the panel is narrow.
@(private)
legend :: proc(gtx: ^ui.Ctx) {
	if ui.wrap(gtx, gap = 10, align = .Center) {
		for kind in Kind {
			if kind == .Folder || kind == .Other {
				continue
			}
			sc := ui.scope_open(gtx, kind)
			if ui.row(gtx, gap = 4, align = .Center) {
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
