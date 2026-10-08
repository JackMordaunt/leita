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
	Video,
	Audio,
	Image,
	Archive,
	Disk_Image,
	Document,
	Code,
	Binary,
	Build_Cache, // a build or cache directory, and all it holds
	Other,
}

KIND_NAMES := [Kind]string {
	.Folder      = "Folder",
	.Video       = "Video",
	.Audio       = "Audio",
	.Image       = "Image",
	.Archive     = "Archive",
	.Disk_Image  = "Disk image",
	.Document    = "Document",
	.Code        = "Code and text",
	.Binary      = "Binary",
	.Build_Cache = "Build and cache",
	.Other       = "Other",
}

// kind_colour is a kind's colour, from Primer's emphasis colours as BRANCHES are.
// The build and cache is the one most worth finding, so it takes the boldest; its
// two purples are one colour in Primer's themes (done and upsell emphasis are
// both #8250df light and #8957e5 dark, primer/tokens), so a document is a mix of two
// others; and what is not a kind of content is grey.
kind_colour :: proc(kind: Kind) -> ops.Color {
	switch kind {
	case .Video:
		return primer.color(.Bg_Color_Done_Emphasis)
	case .Audio:
		return primer.color(.Bg_Color_Sponsors_Emphasis)
	case .Image:
		return primer.color(.Bg_Color_Success_Emphasis)
	case .Archive:
		return primer.color(.Bg_Color_Attention_Emphasis)
	case .Disk_Image:
		return primer.color(.Bg_Color_Danger_Emphasis)
	case .Document:
		return mix(
			primer.color(.Bg_Color_Accent_Emphasis),
			primer.color(.Bg_Color_Success_Emphasis),
			0.5,
		)
	case .Code:
		return primer.color(.Bg_Color_Accent_Emphasis)
	case .Binary:
		return primer.color(.Bg_Color_Neutral_Emphasis)
	case .Build_Cache:
		return primer.color(.Bg_Color_Severe_Emphasis)
	case .Folder, .Other:
	}
	// Neutral muted is translucent; set it on the page's ground.
	return mix(primer.color(.Fg_Color_Muted), primer.color(.Bg_Color_Default), 0.7)
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
	{"mp4", .Video},
	{"mkv", .Video},
	{"mov", .Video},
	{"avi", .Video},
	{"webm", .Video},
	{"m4v", .Video},
	{"wmv", .Video},
	{"mp3", .Audio},
	{"flac", .Audio},
	{"wav", .Audio},
	{"ogg", .Audio},
	{"opus", .Audio},
	{"m4a", .Audio},
	{"aac", .Audio},
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
	{"iso", .Disk_Image},
	{"img", .Disk_Image},
	{"qcow2", .Disk_Image},
	{"vdi", .Disk_Image},
	{"vmdk", .Disk_Image},
	{"vhd", .Disk_Image},
	{"vhdx", .Disk_Image},
	{"dmg", .Disk_Image},
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
			return fill
		}
		return mix(fill, bg, 0.45 if framed && a.directory else 0.15)
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
