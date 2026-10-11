/*
Package reclaim finds what can be deleted to free space without losing anything:
what a build or a tool made and will make again. It is the safety-critical half of
leita's Reclaim mode, so it errs one way only: a candidate must prove what it is.

A directory is a candidate when a rule names it and, for every name that could
also be someone's work (target, build, .venv), when the directory holding it also
holds the file that shows which tool made it: node_modules beside package.json,
target beside Cargo.toml. Names nothing else uses (__pycache__) need no proof.
Bare build, dist and out are never candidates. Under the user's home, the
per-application directories of the XDG cache, a few package managers' download
caches, and the Trash are candidates by where they are.

A match is not looked inside: what it holds goes with it. Nothing inside a .git
directory, and nothing under a system directory, is ever a candidate.

The package knows the scan only through a Source, so it is tested over trees
made in memory.
*/
package reclaim

import "core:mem"
import "core:slice"
import "core:strings"

Category :: enum u8 {
	Dependencies, // installed packages a manifest names
	Build_Output, // what a build made
	Python, // byte code, virtual environments, tool caches
	Package_Cache, // packages a manager downloaded
	App_Cache, // an application's XDG cache
	Trash,
}

CATEGORY_NAMES := [Category]string {
	.Dependencies  = "Installed dependencies",
	.Build_Output  = "Build output",
	.Python        = "Python caches and environments",
	.Package_Cache = "Package downloads",
	.App_Cache     = "Application caches",
	.Trash         = "Trash",
}

// CATEGORY_REASONS say why a category is safe to delete, to the person deciding.
CATEGORY_REASONS := [Category]string {
	.Dependencies  = "Installed again from the project's manifest by its package manager.",
	.Build_Output  = "Made again by the project's next build.",
	.Python        = "Made again by Python and its tools; a virtual environment is created again from the project's requirements.",
	.Package_Cache = "Downloaded again when a package is next needed.",
	.App_Cache     = "Applications keep only what they can make again in their cache.",
	.Trash         = "Already deleted; emptying it frees the space for good.",
}

// Rule is a directory name that is a candidate, beside one of markers in the
// directory holding it; with no markers, anywhere.
Rule :: struct {
	name:     string,
	markers:  []string,
	category: Category,
}

@(rodata)
JS_MARK := [?]string{"package.json"}
@(rodata)
PY_MARK := [?]string {
	"pyproject.toml",
	"setup.py",
	"setup.cfg",
	"requirements.txt",
	"Pipfile",
	"poetry.lock",
}
@(rodata)
GRADLE_MARK := [?]string {
	"build.gradle",
	"build.gradle.kts",
	"settings.gradle",
	"settings.gradle.kts",
}
@(rodata)
CMAKE_MARK := [?]string{"CMakeLists.txt", "meson.build"}
@(rodata)
ZIG_MARK := [?]string{"build.zig"}

RULES := [?]Rule {
	{"node_modules", JS_MARK[:], .Dependencies},
	{".next", JS_MARK[:], .Build_Output},
	{".nuxt", JS_MARK[:], .Build_Output},
	{".svelte-kit", JS_MARK[:], .Build_Output},
	{".parcel-cache", JS_MARK[:], .Build_Output},
	{".turbo", JS_MARK[:], .Build_Output},
	{"target", {"Cargo.toml"}, .Build_Output},
	{"target", {"pom.xml"}, .Build_Output},
	{".gradle", GRADLE_MARK[:], .Build_Output},
	{"build", GRADLE_MARK[:], .Build_Output},
	{"build", CMAKE_MARK[:], .Build_Output},
	{"zig-cache", ZIG_MARK[:], .Build_Output},
	{".zig-cache", ZIG_MARK[:], .Build_Output},
	{"__pycache__", nil, .Python},
	{".pytest_cache", nil, .Python},
	{".mypy_cache", nil, .Python},
	{".ruff_cache", nil, .Python},
	{".tox", PY_MARK[:], .Python},
	{".venv", PY_MARK[:], .Python},
	{"venv", PY_MARK[:], .Python},
}

// TRASH is the user's Trash, relative to the home directory: the Finder's on
// macOS, the freedesktop.org one elsewhere.
when ODIN_OS == .Darwin {
	TRASH :: ".Trash"
} else {
	TRASH :: ".local/share/Trash"
}

// HOME_PLACES are candidates by where they are, relative to the home directory.
// A place ending in /* makes each directory it holds a candidate of its own.
HOME_PLACES := [?]struct {
	path:     string,
	category: Category,
} {
	{".cache/*", .App_Cache},
	{".npm/_cacache", .Package_Cache},
	{".cargo/registry/cache", .Package_Cache},
	{".cargo/registry/src", .Package_Cache},
	{"go/pkg/mod", .Package_Cache},
	{".gradle/caches", .Package_Cache},
	{".m2/repository", .Package_Cache},
	{TRASH, .Trash},
}

// SYSTEM are directories nothing under is ever a candidate.
SYSTEM := [?]string {
	"/bin",
	"/boot",
	"/dev",
	"/etc",
	"/lib",
	"/lib32",
	"/lib64",
	"/proc",
	"/run",
	"/sbin",
	"/sys",
	"/usr",
	"/var",
}

// Source is the scan as the finder sees it.
Source :: struct {
	data:      rawptr,
	name:      proc(data: rawptr, node: u32) -> string,
	directory: proc(data: rawptr, node: u32) -> bool,
	bytes:     proc(data: rawptr, node: u32) -> u64,
	children:  proc(data: rawptr, node: u32, into: ^[dynamic]u32),
}

Candidate :: struct {
	node:     u32,
	path:     string,
	bytes:    u64,
	category: Category,
}

// Finder is a search under way: the path it is at, and what it has found.
@(private)
Finder :: struct {
	src:       Source,
	home:      string,
	path:      strings.Builder,
	found:     [dynamic]Candidate,
	allocator: mem.Allocator,
}

/*
find searches the directory top, whose path is top_path, for candidates, the
largest first, their paths in allocator. home is the user's home directory, for
the candidates that are where they are; "" leaves those out.
*/
find :: proc(
	src: Source,
	top: u32,
	top_path, home: string,
	allocator := context.allocator,
) -> []Candidate {
	f := Finder {
		src       = src,
		home      = strings.trim_right(home, "/"),
		path      = strings.builder_make(context.temp_allocator),
		found     = make([dynamic]Candidate, allocator),
		allocator = allocator,
	}
	// The path is kept without a trailing slash, so the root is "".
	strings.write_string(&f.path, strings.trim_right(top_path, "/"))
	if !under_system(strings.to_string(f.path)) {
		visit(&f, top)
	}
	// Largest first, as the person deciding reads them.
	slice.sort_by(f.found[:], proc(a, b: Candidate) -> bool {return a.bytes > b.bytes})
	return f.found[:]
}

// visit looks through directory dir, whose path is the finder's, for candidates.
@(private)
visit :: proc(f: ^Finder, dir: u32) {
	kids := make([dynamic]u32, context.temp_allocator)
	f.src.children(f.src.data, dir, &kids)
	each, every := place_each(f, strings.to_string(f.path))
	for kid in kids {
		if !f.src.directory(f.src.data, kid) {
			continue
		}
		name := f.src.name(f.src.data, kid)
		if name == ".git" {
			continue
		}
		mark := len(f.path.buf)
		strings.write_byte(&f.path, '/')
		strings.write_string(&f.path, name)
		path := strings.to_string(f.path)
		category, matched := each, every
		if !matched {
			category, matched = place_of(f, path)
		}
		if !matched {
			category, matched = rule_for(f, name, kids[:])
		}
		switch {
		case matched:
			append(
				&f.found,
				Candidate {
					kid,
					strings.clone(path, f.allocator),
					f.src.bytes(f.src.data, kid),
					category,
				},
			)
		case !under_system(path):
			visit(f, kid)
		}
		resize(&f.path.buf, mark)
	}
}

// rule_for is the category of a directory called name in a directory holding
// siblings, if a rule makes it a candidate there.
@(private)
rule_for :: proc(f: ^Finder, name: string, siblings: []u32) -> (Category, bool) {
	for rule in RULES {
		if rule.name != name {
			continue
		}
		if len(rule.markers) == 0 {
			return rule.category, true
		}
		for sib in siblings {
			if f.src.directory(f.src.data, sib) {
				continue
			}
			sname := f.src.name(f.src.data, sib)
			for marker in rule.markers {
				if sname == marker {
					return rule.category, true
				}
			}
		}
	}
	return {}, false
}

// place_of is the category of path if it is a whole place under home.
@(private)
place_of :: proc(f: ^Finder, path: string) -> (Category, bool) {
	rel, ok := under_home(f, path)
	if !ok {
		return {}, false
	}
	for place in HOME_PLACES {
		if !strings.has_suffix(place.path, "/*") && rel == place.path {
			return place.category, true
		}
	}
	return {}, false
}

// place_each is the category every directory held by path has, if path is a
// place under home whose directories are candidates each.
@(private)
place_each :: proc(f: ^Finder, path: string) -> (Category, bool) {
	rel, ok := under_home(f, path)
	if !ok {
		return {}, false
	}
	for place in HOME_PLACES {
		if strings.has_suffix(place.path, "/*") && rel == place.path[:len(place.path) - 2] {
			return place.category, true
		}
	}
	return {}, false
}

// under_home is path relative to home, if it lies under it.
@(private)
under_home :: proc(f: ^Finder, path: string) -> (string, bool) {
	if f.home == "" ||
	   len(path) <= len(f.home) + 1 ||
	   !strings.has_prefix(path, f.home) ||
	   path[len(f.home)] != '/' {
		return "", false
	}
	return path[len(f.home) + 1:], true
}

// under_system is whether path is a system directory or under one.
under_system :: proc(path: string) -> bool {
	for dir in SYSTEM {
		if path == dir ||
		   strings.has_prefix(path, dir) && len(path) > len(dir) && path[len(dir)] == '/' {
			return true
		}
	}
	return false
}
