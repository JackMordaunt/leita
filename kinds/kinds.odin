/*
Package kinds says what an entry is from its name alone: what a file holds, by its
extension, and whether a directory is one a build or a tool made and will make
again. The window colours by it; it lives apart from the window so that anything
else that describes a scan by kind says what the window does of the same name.
*/
package kinds

import "core:path/filepath"
import "core:strings"

// Kind is what an entry is: what a file holds, by its name, or whether a
// directory is a build or cache one.
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

// NAMES are the kinds as a person reads them, a word each.
NAMES := [Kind]string {
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

// of is what a file is, by its name's extension, or what a directory is, by
// its name.
of :: proc(name: string, directory: bool) -> Kind {
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
