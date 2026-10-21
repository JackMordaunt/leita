/*
Package reclaim finds what can be deleted to free space without losing anything:
what a build or a tool made and will make again. It is the safety-critical half of
leita's Reclaim mode, so it errs one way only: a candidate must prove what it is.

A directory is a candidate when a rule names it and, for every name that could
also be someone's work (target, build, .venv), when the directory holding it also
holds the file that shows which tool made it: node_modules beside package.json.
Where a project could keep a folder of that name of its own, the directory must
also hold the file the rule names: a Cargo target its CACHEDIR.TAG, a CMake
build its CMakeCache.txt, a virtual environment its pyvenv.cfg. A rule that
finds its marker but not that file has ruled the directory out, and a looser
rule for the same name does not put it back. A name with no marker and no file
inside, such as __pycache__, needs no proof. Bare build, dist and out are never
candidates.

Under the user's home, the caches of tools known to make them again, a few package
managers' download caches, Xcode's build output and device symbols, the
simulator's cache, and the Trash are candidates by where they are, as is the
user's Trash on an external volume and, on Windows, a folder this package
matches as `<drive>\$Recycle.Bin\<SID>`. A cache is offered by its name,
from a list: anything can write under ~/.cache, so a name not on the list proves
nothing. macOS's places, those under Library, are looked for only on a Mac: a
Library under a Linux home is someone's own folder.

A match is not looked inside: what it holds goes with it. Nothing inside a .git
directory, and nothing under a directory of the system or its programs, is ever a
candidate. Which directories those are, what separates a path's names and whether
case counts are the scan's platform's.

The package knows the scan only through a Source, so it is tested over trees
made in memory.
*/
package reclaim

import "base:runtime"

import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../home"

Category :: enum u8 {
	Dependencies, // installed packages a manifest names
	Build_Output, // what a build made
	Python, // byte code, virtual environments, tool caches
	Package_Cache, // packages a manager downloaded
	App_Cache, // an application's XDG cache
	Device_Support, // symbols Xcode copied from a device
	Trash,
}

CATEGORY_NAMES := [Category]string {
	.Dependencies   = "Installed dependencies",
	.Build_Output   = "Build output",
	.Python         = "Python caches and environments",
	.Package_Cache  = "Package downloads",
	.App_Cache      = "Application caches",
	.Device_Support = "Xcode device support",
	.Trash          = "Trash",
}

// CATEGORY_REASONS say why a category is safe to delete, to the person deciding.
CATEGORY_REASONS := [Category]string {
	.Dependencies   = "Installed again from the project's manifest by its package manager.",
	.Build_Output   = "Made again by the project's next build.",
	.Python         = "Made again by Python and its tools; a virtual environment is created again from the project's requirements.",
	.Package_Cache  = "Downloaded again when a package is next needed.",
	.App_Cache      = "Applications keep only what they can make again in their cache.",
	.Device_Support = "Copied again from the device the next time Xcode connects to it.",
	.Trash          = "Already deleted; emptying it frees the space for good.",
}

// Platform is the system a scan's paths are of, which says what separates their
// names, whether case counts, which directories are the system's, and whether
// macOS's places are looked for.
Platform :: enum u8 {
	Unix,
	Darwin,
	Windows,
}

// HOST is the platform leita runs on, whose disks it scans.
when ODIN_OS == .Windows {
	HOST :: Platform.Windows
} else when ODIN_OS == .Darwin {
	HOST :: Platform.Darwin
} else {
	HOST :: Platform.Unix
}

// Rule is a directory name that is a candidate, beside one of markers in the
// directory holding it; with no markers, anywhere. With inside, the directory
// must also hold that file, which its tool writes there and a folder of
// someone's own work of the same name would not.
Rule :: struct {
	name:     string,
	markers:  []string,
	category: Category,
	inside:   string,
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
ZIG_MARK := [?]string{"build.zig"}

RULES := [?]Rule {
	{"node_modules", JS_MARK[:], .Dependencies, ""},
	{".next", JS_MARK[:], .Build_Output, ""},
	{".nuxt", JS_MARK[:], .Build_Output, ""},
	{".svelte-kit", JS_MARK[:], .Build_Output, ""},
	{".parcel-cache", JS_MARK[:], .Build_Output, ""},
	{".turbo", JS_MARK[:], .Build_Output, ""},
	// cargo writes a CACHEDIR.TAG into the target directory it makes ("a cache
	// directory tag created by cargo", seen in a target on 2026-10-17); a target
	// beside Cargo.toml without one is not known to be cargo's.
	{"target", {"Cargo.toml"}, .Build_Output, "CACHEDIR.TAG"},
	{"target", {"pom.xml"}, .Build_Output, ""},
	{".gradle", GRADLE_MARK[:], .Build_Output, ""},
	{"build", GRADLE_MARK[:], .Build_Output, ""},
	// A C or C++ project keeps folders called build of its own (scripts, docs), so
	// only the one CMake configured, which holds its CMakeCache.txt, or the one
	// Meson set up, which holds its build.ninja, is the build's (CMake 4.4.3 and
	// Meson 1.12.1, checked 2026-10-17).
	{"build", {"CMakeLists.txt"}, .Build_Output, "CMakeCache.txt"},
	{"build", {"meson.build"}, .Build_Output, "build.ninja"},
	{"zig-cache", ZIG_MARK[:], .Build_Output, ""},
	{".zig-cache", ZIG_MARK[:], .Build_Output, ""},
	{".build", {"Package.swift"}, .Build_Output, ""},
	// Odin's compiler makes .odin-cache beside the binary it builds, and keeps in
	// it only manifests of the build and the binary itself (try_cached_build in
	// its src/cached.cpp, as of dev-2026-09).
	{".odin-cache", nil, .Build_Output, ""},
	{"__pycache__", nil, .Python, ""},
	{".pytest_cache", nil, .Python, ""},
	{".mypy_cache", nil, .Python, ""},
	{".ruff_cache", nil, .Python, ""},
	{".tox", PY_MARK[:], .Python, ""},
	// python -m venv and virtualenv write pyvenv.cfg into every environment they
	// make (Python 3.14.7 and virtualenv 21.14.10, checked 2026-10-17); a folder
	// of these names without one is not an environment.
	{".venv", PY_MARK[:], .Python, "pyvenv.cfg"},
	{"venv", PY_MARK[:], .Python, "pyvenv.cfg"},
}

// TRASH is the user's Trash, relative to the home directory: the Finder's on
// macOS, the freedesktop.org one elsewhere. On Windows this package does not
// look under home for it; volume_trash matches `$Recycle.Bin\<SID>`.
when ODIN_OS == .Darwin {
	TRASH :: ".Trash"
} else {
	TRASH :: ".local/share/Trash"
}

// RECYCLE_DIR is the folder name this package matches on a Windows volume.
RECYCLE_DIR :: "$Recycle.Bin"

// HOME_PLACES are candidates by where they are, relative to the home directory.
// A place for darwin is looked for only on a Mac.
HOME_PLACES := [?]struct {
	path:     string,
	category: Category,
	darwin:   bool,
} {
	{".npm/_cacache", .Package_Cache, false},
	{".cargo/registry/cache", .Package_Cache, false},
	{".cargo/registry/src", .Package_Cache, false},
	{".cargo/git/db", .Package_Cache, false},
	{".cargo/git/checkouts", .Package_Cache, false},
	{"go/pkg/mod", .Package_Cache, false},
	{".gradle/caches", .Package_Cache, false},
	{".m2/repository", .Package_Cache, false},
	{".nuget/packages", .Package_Cache, false},
	// Hugging Face's downloaded models; its login token, beside them, is kept.
	{".cache/huggingface/hub", .Package_Cache, false},
	{"Library/Caches/Google/Chrome", .App_Cache, true},
	{"Library/Developer/Xcode/DerivedData", .Build_Output, true},
	{"Library/Developer/Xcode/iOS DeviceSupport", .Device_Support, true},
	{"Library/Developer/Xcode/watchOS DeviceSupport", .Device_Support, true},
	{"Library/Developer/Xcode/tvOS DeviceSupport", .Device_Support, true},
	{"Library/Developer/Xcode/visionOS DeviceSupport", .Device_Support, true},
	{"Library/Developer/CoreSimulator/Caches", .App_Cache, true},
	{TRASH, .Trash, false},
}

// Cache is a directory of a cache home whose tool is known to make again what it
// holds.
Cache :: struct {
	name:     string,
	category: Category,
}

/*
XDG_CACHES are the directories of ~/.cache that are candidates, each by name.
No other is: anything can write under ~/.cache, and not everything there is made
again, so a name nobody has checked proves nothing. Hugging Face keeps its login
token in ~/.cache/huggingface (HF_HOME's default, by huggingface_hub's
documentation), and poetry its virtual environments in
~/.cache/pypoetry/virtualenvs (virtualenvs.path's default on Linux, by
poetry's).
*/
@(rodata)
XDG_CACHES := [?]Cache {
	{"pip", .Package_Cache}, // wheels and downloads, fetched again
	{"uv", .Package_Cache}, // uv's packages; its tools and Pythons live elsewhere
	{"npm", .Package_Cache}, // npm's cache where it is pointed under XDG
	{"yarn", .Package_Cache}, // Yarn 1's packages
	{"pnpm", .Package_Cache}, // pnpm's metadata; its store lives elsewhere
	{"composer", .Package_Cache}, // Composer's downloads
	{"pre-commit", .Package_Cache}, // hook environments, made again on the next commit
	{"go-build", .Build_Output}, // go's build cache, GOCACHE
	{"mesa_shader_cache", .App_Cache}, // compiled shaders, compiled again when drawn
	{"mesa_shader_cache_db", .App_Cache}, // the same, as newer Mesa keeps it
	{"fontconfig", .App_Cache}, // font lists, made again by the next program
	{"thumbnails", .App_Cache}, // thumbnails, drawn again when shown
	{"mozilla", .App_Cache}, // Firefox's web cache; the profile is elsewhere
	{"chromium", .App_Cache}, // the browser's web cache; the profile is in ~/.config
	{"google-chrome", .App_Cache}, // the same, for Chrome
}

/*
MACOS_CACHES are the directories of ~/Library/Caches that are candidates, each by
name, as XDG_CACHES are of ~/.cache: what an application keeps there is offered
once someone has checked that it makes it again.
*/
@(rodata)
MACOS_CACHES := [?]Cache {
	{"Homebrew", .Package_Cache}, // bottles and downloads, fetched again
	{"pip", .Package_Cache},
	{"Yarn", .Package_Cache},
	{"pnpm", .Package_Cache},
	{"composer", .Package_Cache},
	{"CocoaPods", .Package_Cache}, // pod specs and downloads
	{"node-gyp", .Package_Cache}, // Node's headers, fetched for the next native build
	{"typescript", .Package_Cache}, // type definitions the editor fetches again
	{"go-build", .Build_Output},
	{"JetBrains", .App_Cache}, // the IDEs' indexes, built again on opening a project
	{"com.apple.Safari", .App_Cache}, // Safari's web cache
	{"Firefox", .App_Cache},
	{"Chromium", .App_Cache},
}

// CACHE_HOMES are the directories under home whose listed directories are
// candidates each; one for darwin is looked for only on a Mac.
CACHE_HOMES := [?]struct {
	path:   string,
	caches: []Cache,
	darwin: bool,
}{{".cache", XDG_CACHES[:], false}, {"Library/Caches", MACOS_CACHES[:], true}}

// VOLUMES is where macOS mounts other volumes. The Trash matched on one is the
// path <volume>/.Trashes/<uid>, the user's by id, which is the layout assumed of
// the Finder; no external volume was at hand to observe it, so a test holds it.
VOLUMES :: "/Volumes/"

/*
UNIX_SYSTEM are the directories nothing under is ever a candidate on Linux and the
other Unixes: the system's own, where packages and installers put programs (/opt,
/snap, /nix), root's home, what a server serves (/srv), and where other disks are
mounted (/mnt, /media), whose trees are not the user's to judge.
*/
@(rodata)
UNIX_SYSTEM := [?]string {
	"/bin",
	"/boot",
	"/dev",
	"/etc",
	"/lib",
	"/lib32",
	"/lib64",
	"/media",
	"/mnt",
	"/nix",
	"/opt",
	"/proc",
	"/root",
	"/run",
	"/sbin",
	"/snap",
	"/srv",
	"/sys",
	"/usr",
	"/var",
}

/*
DARWIN_SYSTEM are macOS's own besides UNIX_SYSTEM. Its /etc and /var are links
into /private, so those are denied there too; /private/tmp, which /tmp links to,
is not, as /tmp is not on Linux. /private whole is not: DARWIN_OWN lies under it.
*/
@(rodata)
DARWIN_SYSTEM := [?]string {
	"/Applications",
	"/Library",
	"/System",
	"/cores",
	"/private/etc",
	"/private/var",
}

/*
DARWIN_OWN are the directories under DARWIN_SYSTEM and UNIX_SYSTEM that hold each
user's own: macOS gives every user a temporary directory (TMPDIR) and a cache
directory under /var/folders, which is /private/var/folders through the link. It
is no more the system's than /tmp is on Linux, and a test's fixtures are there.
*/
@(rodata)
DARWIN_OWN := [?]string{"/private/var/folders", "/var/folders"}

// WINDOWS_SYSTEM are Windows's own and its programs' where it is installed as
// usual; WINDOWS_SYSTEM_ENV name them where it is installed elsewhere.
@(rodata)
WINDOWS_SYSTEM := [?]string {
	`C:\Windows`,
	`C:\Program Files`,
	`C:\Program Files (x86)`,
	`C:\ProgramData`,
}
@(rodata)
WINDOWS_SYSTEM_ENV := [?]string {
	"SystemRoot",
	"windir",
	"ProgramFiles",
	"ProgramFiles(x86)",
	"ProgramW6432",
	"ProgramData",
}

// Source is the scan as the finder sees it.
Source :: struct {
	data:      rawptr,
	name:      proc(data: rawptr, node: u32) -> string,
	// directory is whether node is a directory of the volume scanned: false for
	// a mount point, so another disk or a bind of somewhere else mounted at
	// node_modules is never a candidate, nor looked in.
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
	uid:       string,
	platform:  Platform,
	system:    []string,
	own:       []string, // the user's own, which outrank system (own_dirs)
	path:      strings.Builder,
	held:      [dynamic]u32, // what a directory a rule names holds, as rule_for reads it
	found:     [dynamic]Candidate,
	allocator: mem.Allocator,
}

/*
find searches the directory top, whose path is top_path, for candidates, the
largest first, their paths in allocator. user is whose home directory and user id
the candidates that are where they are belong to; an empty home or id leaves
those out. platform is the system the scan's paths are of.
*/
find :: proc(
	src: Source,
	top: u32,
	top_path: string,
	user: home.User,
	allocator := context.allocator,
	platform := HOST,
) -> []Candidate {
	f := Finder {
		src       = src,
		home      = strings.trim_right(user.dir, separators(platform)),
		uid       = user.uid,
		platform  = platform,
		system    = system_dirs(platform, context.temp_allocator),
		path      = strings.builder_make(context.temp_allocator),
		held      = make([dynamic]u32, context.temp_allocator),
		found     = make([dynamic]Candidate, allocator),
		allocator = allocator,
	}
	f.own = own_dirs(f.home, platform, context.temp_allocator)
	// The path is kept without a trailing separator, so the root is "" (or C:).
	strings.write_string(&f.path, strings.trim_right(top_path, separators(platform)))
	if at := strings.to_string(f.path); !under_system(&f, at) || leads_to_own(&f, at) {
		visit(&f, top)
	}
	// Largest first, as the person deciding reads them.
	slice.sort_by(f.found[:], proc(a, b: Candidate) -> bool {return a.bytes > b.bytes})
	return f.found[:]
}

// Confinement is where host_confine says the path leads, and whether that is known.
// A missing tail is kept on the last directory that resolved. A symlink loop, a
// realpath failure other than a missing component, or a path the buffer cannot
// hold is not known.
@(private)
Confinement :: struct {
	path:  string,
	known: bool,
}

/*
root_may_delete is whether Reclaim, acting as user id euid, may delete the
directory at path, whose owner is owner, for user. As root it may delete anything
the system holds, another user's work among it (sudo leita on /home would offer
and delete /home/bob/proj/node_modules), so it keeps to what user could delete
themself: a directory under their home that is theirs. On this machine the
original path is resolved before ".." is collapsed. A symlink is followed, and
a ".." after one is the parent of where it led, which the symlink test records.
A missing tail stays on the last directory that resolved, so a path that is not
on disk is still judged and a ".." in the text cannot cancel that symlink. When
realpath fails for any reason other than a missing component, this refuses. A
path of another platform is judged on its text alone, as is Windows, where the
window does not ask this (gui/app/act.odin). Any other user id is left
to the system's permission checks; a capability short of root is not looked for.
*/
root_may_delete :: proc(
	path: string,
	owner: u32,
	user: home.User,
	euid: u32,
	platform := HOST,
) -> bool {
	if euid != 0 {
		return true
	}
	uid, ok := strconv.parse_u64_of_base(user.uid, 10)
	if !ok || uid != u64(owner) {
		return false
	}
	home_dir := lexical_clean(
		strings.trim_right(user.dir, separators(platform)),
		platform,
		context.temp_allocator,
	)
	// A made-up path of another platform is not on this machine to resolve.
	if platform != HOST {
		cleaned := lexical_clean(path, platform, context.temp_allocator)
		rel, inside := within(cleaned, home_dir, platform)
		return inside && rel != ""
	}
	judged := host_confine(path)
	base := host_confine(home_dir)
	if !judged.known || !base.known {
		return false
	}
	rel, inside := within(judged.path, base.path, platform)
	return inside && rel != ""
}

/*
visit looks through directory dir, whose path is the finder's, for candidates. A
system directory is neither one nor looked in, unless one of the user's own lies
under it: then it is gone through to reach that, and nothing else in it is looked
at, so /var/home/ann is searched and /var/lib is not.
*/
@(private)
visit :: proc(f: ^Finder, dir: u32) {
	kids := make([dynamic]u32, context.temp_allocator)
	f.src.children(f.src.data, dir, &kids)
	caches := caches_in(f, strings.to_string(f.path))
	for kid in kids {
		if !f.src.directory(f.src.data, kid) {
			continue
		}
		name := f.src.name(f.src.data, kid)
		if name == ".git" {
			continue
		}
		mark := len(f.path.buf)
		strings.write_byte(&f.path, separator(f.platform))
		strings.write_string(&f.path, name)
		path := strings.to_string(f.path)
		system := under_system(f, path)
		switch {
		case system && !leads_to_own(f, path):
		// Neither a candidate nor looked in.
		case system:
			visit(f, kid)
		case:
			if category, matched := match(f, name, path, kid, kids[:], caches); matched {
				append(
					&f.found,
					Candidate {
						kid,
						strings.clone(path, f.allocator),
						f.src.bytes(f.src.data, kid),
						category,
					},
				)
			} else {
				visit(f, kid)
			}
		}
		resize(&f.path.buf, mark)
	}
}

// match is the category of directory dir, called name at path, in a directory
// holding siblings that may hold caches, if it is a candidate.
@(private)
match :: proc(
	f: ^Finder,
	name, path: string,
	dir: u32,
	siblings: []u32,
	caches: []Cache,
) -> (
	Category,
	bool,
) {
	if category, ok := cache_for(f, caches, name); ok {
		return category, true
	}
	if category, ok := place_of(f, path); ok {
		return category, true
	}
	if volume_trash(f, path) {
		return .Trash, true
	}
	return rule_for(f, name, dir, siblings)
}

// rule_for is the category of directory dir, called name, in a directory holding
// siblings, if a rule makes it a candidate there. A rule whose marker is present
// and whose inside file is missing has claimed the name: a looser rule for that
// name, one that asks for no file inside, does not override it. Cargo's target
// without CACHEDIR.TAG stays out even beside a pom.xml, and a CMake build without
// CMakeCache.txt stays out even beside a Gradle file. The looser rule still
// applies when no stricter rule's marker is there.
@(private)
rule_for :: proc(f: ^Finder, name: string, dir: u32, siblings: []u32) -> (Category, bool) {
	loose: Category
	loose_ok := false
	strict_failed := false
	for rule in RULES {
		if rule.name != name {
			continue
		}
		if len(rule.markers) > 0 && !holds_file(f, siblings, ..rule.markers) {
			continue
		}
		if rule.inside != "" {
			clear(&f.held)
			f.src.children(f.src.data, dir, &f.held)
			if !holds_file(f, f.held[:], rule.inside) {
				strict_failed = true
				continue
			}
			return rule.category, true
		}
		if !loose_ok {
			loose, loose_ok = rule.category, true
		}
	}
	if strict_failed {
		return {}, false
	}
	return loose, loose_ok
}

// holds_file is whether one of nodes is a file called one of names.
@(private)
holds_file :: proc(f: ^Finder, nodes: []u32, names: ..string) -> bool {
	for node in nodes {
		if f.src.directory(f.src.data, node) {
			continue
		}
		got := f.src.name(f.src.data, node)
		for name in names {
			if got == name {
				return true
			}
		}
	}
	return false
}

// place_of is the category of path if it is a whole place under home.
@(private)
place_of :: proc(f: ^Finder, path: string) -> (Category, bool) {
	rel, ok := under_home(f, path)
	if !ok {
		return {}, false
	}
	for place in HOME_PLACES {
		if place.darwin && f.platform != .Darwin {
			continue
		}
		// HOME_PLACES TRASH is skipped on Windows; volume_trash matches the bin.
		if f.platform == .Windows && same(place.path, TRASH, f.platform) {
			continue
		}
		if same(rel, place.path, f.platform) {
			return place.category, true
		}
	}
	return {}, false
}

// caches_in is the caches the directory at path may hold, if it is a cache home
// under home.
@(private)
caches_in :: proc(f: ^Finder, path: string) -> []Cache {
	rel, ok := under_home(f, path)
	if !ok {
		return nil
	}
	for place in CACHE_HOMES {
		if (!place.darwin || f.platform == .Darwin) && same(rel, place.path, f.platform) {
			return place.caches
		}
	}
	return nil
}

// cache_for is the category of the directory called name in a cache home that
// may hold caches, if it is one of them.
@(private)
cache_for :: proc(f: ^Finder, caches: []Cache, name: string) -> (Category, bool) {
	for c in caches {
		if same(name, c.name, f.platform) {
			return c.category, true
		}
	}
	return {}, false
}

// Recycle_Bin is one volume's Recycle Bin as the caller named it: the volume
// root (`C:\`), the user's folder there, and what it holds.
Recycle_Bin :: struct {
	volume: string,
	path:   string,
	bytes:  u64,
}

/*
overlay_recycle_bins takes find's candidates and the Recycle Bins the shell named,
overlays each found Recycle Bin's size with the shell's, and appends a Bin that
find did not see, so a scan of a home still offers the Recycle Bin. node_for
numbers a Bin that was not in the tree. found is kept when nothing is appended;
injected paths are cloned into allocator.
*/
overlay_recycle_bins :: proc(
	found: []Candidate,
	bins: []Recycle_Bin,
	uid: string,
	node_for: proc(volume: string) -> u32,
	allocator := context.allocator,
) -> []Candidate {
	if len(bins) == 0 {
		return found
	}
	for &c in found {
		if !is_recycle_bin(c.path, uid) {
			continue
		}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		vol := recycle_bin_volume(c.path, context.temp_allocator)
		for b in bins {
			if same_drive(vol, b.volume) {
				c.bytes = b.bytes
				break
			}
		}
	}
	out := make([dynamic]Candidate, allocator)
	append(&out, ..found)
	added := false
	for b in bins {
		if b.bytes == 0 {
			continue
		}
		already := false
		for c in found {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			if is_recycle_bin(c.path, uid) &&
			   same_drive(recycle_bin_volume(c.path, context.temp_allocator), b.volume) {
				already = true
				break
			}
		}
		if already {
			continue
		}
		append(
			&out,
			Candidate{node_for(b.volume), strings.clone(b.path, allocator), b.bytes, .Trash},
		)
		added = true
	}
	if !added {
		delete(out)
		return found
	}
	return out[:]
}

// recycle_bin_path is the user's Recycle Bin on volume: `C:\$Recycle.Bin\<SID>`.
recycle_bin_path :: proc(volume, sid: string, allocator := context.allocator) -> string {
	vol := strings.trim_right(volume, `\/`)
	return strings.concatenate({vol, `\`, RECYCLE_DIR, `\`, sid}, allocator)
}

// recycle_bin_volume is the `X:\` root of a Recycle Bin path, or "".
recycle_bin_volume :: proc(path: string, allocator := context.allocator) -> string {
	p := strings.trim_right(path, `\/`)
	start := 0
	for i in 0 ..= len(p) {
		at_end := i == len(p)
		if !at_end && strings.index_byte(`\/`, p[i]) < 0 {
			continue
		}
		if same(p[start:i], RECYCLE_DIR, .Windows) {
			vol := p[:start]
			if vol == "" {
				return ""
			}
			if strings.index_byte(`\/`, vol[len(vol) - 1]) < 0 {
				return strings.concatenate({vol, `\`}, allocator)
			}
			return strings.clone(vol, allocator)
		}
		start = i + 1
	}
	return ""
}

// same_drive is whether a and b name the same Windows volume, trailing slash or not.
@(private)
same_drive :: proc(a, b: string) -> bool {
	return same(strings.trim_right(a, `\/`), strings.trim_right(b, `\/`), .Windows)
}

// recycle_bin_node is a node id for a Recycle Bin that is not in the scan tree,
// one per drive letter, above any tree's.
recycle_bin_node :: proc(volume: string) -> u32 {
	letter: byte = 'c'
	for i in 0 ..< len(volume) {
		c := fold(volume[i])
		if c >= 'a' && c <= 'z' {
			letter = c
			break
		}
	}
	return max(u32) - u32(letter - 'a')
}

// is_recycle_bin is whether path is this user's Recycle Bin folder on a volume:
// `<drive>\$Recycle.Bin\<sid>`, and not a file inside it.
is_recycle_bin :: proc(path, sid: string) -> bool {
	if sid == "" || path == "" {
		return false
	}
	p := strings.trim_right(path, `\/`)
	if len(p) < len(sid) + 1 {
		return false
	}
	if !same(p[len(p) - len(sid):], sid, .Windows) {
		return false
	}
	if strings.index_byte(`\/`, p[len(p) - len(sid) - 1]) < 0 {
		return false
	}
	head := p[:len(p) - len(sid) - 1]
	if len(head) < len(RECYCLE_DIR) + 1 {
		return false
	}
	if !same(head[len(head) - len(RECYCLE_DIR):], RECYCLE_DIR, .Windows) {
		return false
	}
	return strings.index_byte(`\/`, head[len(head) - len(RECYCLE_DIR) - 1]) >= 0
}

// volume_trash is whether path is the user's Trash on another volume:
// /Volumes/<volume>/.Trashes/<uid> on a Mac, <drive>\$Recycle.Bin\<SID> on Windows.
@(private)
volume_trash :: proc(f: ^Finder, path: string) -> bool {
	if f.uid == "" {
		return false
	}
	if f.platform == .Windows {
		return is_recycle_bin(path, f.uid)
	}
	if !strings.has_prefix(path, VOLUMES) {
		return false
	}
	rest := path[len(VOLUMES):]
	slash := strings.index_byte(rest, '/')
	if slash <= 0 {
		return false
	}
	TRASHES :: ".Trashes/"
	rest = rest[slash + 1:]
	return strings.has_prefix(rest, TRASHES) && rest[len(TRASHES):] == f.uid
}

// under_home is path relative to home, if it lies under it.
@(private)
under_home :: proc(f: ^Finder, path: string) -> (string, bool) {
	rel, ok := within(path, f.home, f.platform)
	return rel, ok && rel != ""
}

// under_system is whether path is a system directory or under one, and not one of
// the user's own or under it.
@(private)
under_system :: proc(f: ^Finder, path: string) -> bool {
	for dir in f.own {
		if _, ok := within(path, dir, f.platform); ok {
			return false
		}
	}
	for dir in f.system {
		if _, ok := within(path, dir, f.platform); ok {
			return true
		}
	}
	return false
}

// leads_to_own is whether one of the user's own directories lies under path.
@(private)
leads_to_own :: proc(f: ^Finder, path: string) -> bool {
	for dir in f.own {
		if _, ok := within(dir, path, f.platform); ok {
			return true
		}
	}
	return false
}

/*
own_dirs are the directories that are the user's own wherever they lie, in
allocator, which a system directory holding them does not take: the home, and
on a Mac the users' temporary directories (DARWIN_OWN). A home is the user's
under /var too, where Fedora Silverblue keeps it (/home is a link to /var/home,
by its documentation's Technical Information); but a home that is a root or a
directory at the top, such as /root, is the system's.
*/
@(private)
own_dirs :: proc(home: string, platform: Platform, allocator := context.allocator) -> []string {
	dirs := make([dynamic]string, allocator)
	if platform == .Darwin {
		append(&dirs, ..DARWIN_OWN[:])
	}
	if len(home) > 1 && strings.index_any(home[1:], separators(platform)) >= 0 {
		append(&dirs, home)
	}
	return dirs[:]
}

// system_dirs are the directories nothing under is ever a candidate on platform,
// in allocator: on Windows the usual ones and wherever the environment says
// Windows and its programs are instead.
@(private)
system_dirs :: proc(platform: Platform, allocator := context.allocator) -> []string {
	dirs := make([dynamic]string, allocator)
	switch platform {
	case .Windows:
		append(&dirs, ..WINDOWS_SYSTEM[:])
		for name in WINDOWS_SYSTEM_ENV {
			dir := strings.trim_right(os.get_env(name, allocator), separators(platform))
			if dir != "" {
				append(&dirs, dir)
			}
		}
	case .Darwin:
		append(&dirs, ..UNIX_SYSTEM[:])
		append(&dirs, ..DARWIN_SYSTEM[:])
	case .Unix:
		append(&dirs, ..UNIX_SYSTEM[:])
	}
	return dirs[:]
}

// separator is what a scan's paths on platform join names with, as
// scan.SEPARATOR is for the host's.
@(private)
separator :: proc(platform: Platform) -> byte {
	return '\\' if platform == .Windows else '/'
}

// separators are what may separate names in a path on platform: Windows takes
// either slash, and a path typed, passed in or built by hand may carry /.
@(private)
separators :: proc(platform: Platform) -> string {
	return `\/` if platform == .Windows else "/"
}

// lexical_clean is path with "." and ".." collapsed and repeated separators
// folded to the platform's, in allocator. ".." above the root is dropped. It
// does not follow a symlink: that is host_confine, and only for a path that is
// on this machine.
@(private)
lexical_clean :: proc(
	path: string,
	platform: Platform,
	allocator := context.temp_allocator,
) -> string {
	if path == "" {
		return path
	}
	seps := separators(platform)
	parts := make([dynamic]string, allocator)
	start := 0
	absolute := false
	prefix := ""
	if platform == .Windows && len(path) >= 2 && path[1] == ':' {
		prefix = path[:2]
		start = 2
		if len(path) == 2 || strings.index_byte(seps, path[2]) >= 0 {
			absolute = true
		}
	} else if strings.index_byte(seps, path[0]) >= 0 {
		absolute = true
	}
	i := start
	for i <= len(path) {
		if i < len(path) && strings.index_byte(seps, path[i]) < 0 {
			i += 1
			continue
		}
		elem := path[start:i]
		start = i + 1
		i += 1
		switch elem {
		case "", ".":
		case "..":
			if len(parts) > 0 {
				pop(&parts)
			}
		case:
			append(&parts, elem)
		}
	}
	b := strings.builder_make(allocator)
	if prefix != "" {
		strings.write_string(&b, prefix)
	}
	if absolute {
		strings.write_byte(&b, separator(platform))
	}
	for elem, n in parts {
		if n > 0 {
			strings.write_byte(&b, separator(platform))
		}
		strings.write_string(&b, elem)
	}
	return strings.to_string(b)
}

// within is path relative to dir, if path is dir or lies under it on platform.
@(private)
within :: proc(path, dir: string, platform: Platform) -> (rel: string, ok: bool) {
	n := len(dir)
	if n == 0 || len(path) < n || !same(path[:n], dir, platform) {
		return "", false
	}
	if len(path) == n {
		return "", true
	}
	if strings.index_byte(separators(platform), path[n]) < 0 {
		return "", false
	}
	return path[n + 1:], true
}

// same is whether a and b name the same path on platform. On Windows either slash
// separates and case does not count, as NTFS does not count it; a name there is
// compared by its ASCII letters alone, which every system directory's is.
@(private)
same :: proc(a, b: string, platform: Platform) -> bool {
	if platform != .Windows {
		return a == b
	}
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if fold(a[i]) != fold(b[i]) {
			return false
		}
	}
	return true
}

// fold is c as same compares it on Windows: / as \, a capital as its small letter.
@(private)
fold :: proc(c: byte) -> byte {
	switch c {
	case '/':
		return '\\'
	case 'A' ..= 'Z':
		return c + ('a' - 'A')
	}
	return c
}
