package synth

import "core:fmt"

/*
The disk's shape: the directories laid out by name, what fills each, and the
themes the rest of it is made after. Sizes are in GiB. A name with slashes is a
path, whose directories on the way hold only what it names. grow is the share a
directory gains each day.
*/

@(private)
Spec :: struct {
	name:  string,
	kind:  Kind,
	gib:   f64,
	theme: Theme_Id,
	n:     u16, // the layout, for .Layout; the list, for .Items
	grow:  f64,
}

@(private)
Layout :: enum u16 {
	Root,
	System,
	System_Library,
	Library,
	Users,
	Home,
	User_Library,
	Containers,
	App_Support,
	Caches,
	Developer,
	Xcode,
	Core_Simulator,
	Pictures,
	Photos_Library,
	Music,
	Dot_Cache,
	Cargo,
	Opt,
	Homebrew,
	Private,
	Var,
	Vm,
	Usr,
}

// layout fills a directory from its table.
@(private)
layout :: proc(g: ^Gen) {
	for s in LAYOUTS[Layout(g.at.n)] {
		place(g, s)
	}
}

@(private)
place :: proc(g: ^Gen, s: Spec) {
	bytes := s.gib * GiB * (1 + s.grow * f64(g.cfg.day))
	// The Compare capture's earlier scan contains a larger system asset folder.
	// Its day-7 scan uses the ordinary synthetic disk, so this produces a real
	// shrinking directory without changing the hero's day-7 scan or its film.
	if g.cfg.compare_baseline && g.at.n == u16(Layout.System_Library) && s.name == "AssetsV2" {
		bytes += 12 * GiB
	}
	parent := g.at.index
	defer g.at.index = parent
	name, ok := descend(g, s.name)
	if !ok {
		return
	}
	#partial switch s.kind {
	case .File:
		add_file(g, name, bytes)
	case .Link:
		add(g, name, {.Reparse}, 0)
	case:
		add_dir(g, name, s.kind, bytes, s.theme, s.n)
	}
}

@(private)
LAYOUTS := [Layout][]Spec {
	.Root           = {
		{name = "Applications", kind = .Apps},
		{name = "System", kind = .Layout, n = u16(Layout.System)},
		{name = "Library", kind = .Layout, n = u16(Layout.Library)},
		{name = "Users", kind = .Layout, n = u16(Layout.Users)},
		{name = "opt", kind = .Layout, n = u16(Layout.Opt)},
		{name = "private", kind = .Layout, n = u16(Layout.Private)},
		{name = "usr", kind = .Layout, n = u16(Layout.Usr)},
		{name = "bin", kind = .Folder, gib = 0.004, theme = .Binaries},
		{name = "sbin", kind = .Folder, gib = 0.002, theme = .Binaries},
		{name = "Volumes", kind = .Folder},
		{name = "cores", kind = .Folder},
		{name = "dev", kind = .Folder},
		{name = "etc", kind = .Link},
		{name = "tmp", kind = .Link},
		{name = "var", kind = .Link},
		{name = ".VolumeIcon.icns", kind = .File},
		{name = ".file", kind = .File},
	},
	.System         = {
		{name = "Library", kind = .Layout, n = u16(Layout.System_Library)},
		{name = "Applications", kind = .Folder, gib = 1.1, theme = .Bundles},
		{name = "iOSSupport", kind = .Folder, gib = 0.9, theme = .Frameworks},
		{name = "DriverKit", kind = .Folder, gib = 0.05, theme = .Libraries},
		{name = "Volumes", kind = .Folder},
		{name = "Cryptexes", kind = .Folder},
	},
	.System_Library = {
		{name = "AssetsV2", kind = .Folder, gib = 17.6, theme = .Assets},
		{name = "Frameworks", kind = .Folder, gib = 6.2, theme = .Frameworks},
		{name = "PrivateFrameworks", kind = .Folder, gib = 4.4, theme = .Frameworks},
		{name = "CoreServices", kind = .Folder, gib = 3.1, theme = .Bundles},
		{name = "Speech", kind = .Folder, gib = 1.2, theme = .Resources},
		{name = "Extensions", kind = .Folder, gib = 0.9, theme = .Libraries},
		{name = "LinguisticData", kind = .Folder, gib = 0.8, theme = .Resources},
		{name = "Fonts", kind = .Folder, gib = 0.6, theme = .Fonts},
		{name = "Caches", kind = .Folder, gib = 0.4, theme = .Cache},
	},
	.Library        = {
		{name = "Developer", kind = .Folder, gib = 5.6, theme = .Libraries},
		{name = "Application Support", kind = .Folder, gib = 3.2, theme = .Support},
		{name = "Audio/Apple Loops", kind = .Folder, gib = 2.6, theme = .Loops},
		{name = "Updates", kind = .Folder, gib = 1.0, theme = .Assets},
		{name = "Caches", kind = .Folder, gib = 0.6, theme = .Cache},
		{name = "Fonts", kind = .Folder, gib = 0.4, theme = .Fonts},
		{name = "Logs", kind = .Folder, gib = 0.3, theme = .Logs},
		{name = "Frameworks", kind = .Folder, gib = 0.2, theme = .Frameworks},
		{name = "Preferences", kind = .Folder, gib = 0.01, theme = .Share},
	},
	.Users          = {
		{name = "alex", kind = .Layout, n = u16(Layout.Home)},
		{name = "Shared", kind = .Folder, gib = 0.8, theme = .Docs},
		{name = ".localized", kind = .File},
	},
	.Home           = {
		{name = "Library", kind = .Layout, n = u16(Layout.User_Library)},
		{name = "Pictures", kind = .Layout, n = u16(Layout.Pictures)},
		{name = "Movies", kind = .Items, n = u16(List.Movies)},
		{name = "Music", kind = .Layout, n = u16(Layout.Music)},
		{name = "Source", kind = .Projects},
		{name = "Downloads", kind = .Items, n = u16(List.Downloads)},
		{name = "Documents", kind = .Folder, gib = 4.8, theme = .Docs, grow = 0.002},
		{name = "Desktop", kind = .Folder, gib = 0.8, theme = .Screens, grow = 0.01},
		{name = ".cache", kind = .Layout, n = u16(Layout.Dot_Cache)},
		{name = ".cargo", kind = .Layout, n = u16(Layout.Cargo)},
		{name = ".npm/_cacache", kind = .Folder, gib = 1.4, theme = .Cache, grow = 0.01},
		{name = "go/pkg/mod", kind = .Folder, gib = 1.1, theme = .Source},
		{name = ".rustup/toolchains", kind = .Folder, gib = 2.1, theme = .Libraries},
		{name = ".Trash", kind = .Folder, gib = 0.7, theme = .Docs, grow = 0.02},
		{name = ".vscode/extensions", kind = .Folder, gib = 0.9, theme = .Scripts},
		{name = ".bun/install/cache", kind = .Folder, gib = 0.6, theme = .Scripts},
		{name = ".local/share", kind = .Folder, gib = 0.3, theme = .Share},
		{name = ".docker", kind = .Folder, gib = 0.05, theme = .Share},
		{name = ".zshrc", kind = .File, gib = 0.000004},
		{name = ".gitconfig", kind = .File, gib = 0.000001},
	},
	.User_Library   = {
		{name = "Containers", kind = .Layout, n = u16(Layout.Containers)},
		{name = "Developer", kind = .Layout, n = u16(Layout.Developer)},
		{name = "Application Support", kind = .Layout, n = u16(Layout.App_Support)},
		{name = "Caches", kind = .Layout, n = u16(Layout.Caches)},
		{name = "Group Containers", kind = .Folder, gib = 1.5, theme = .Support},
		{name = "Mail", kind = .Folder, gib = 1.2, theme = .Mail},
		{name = "Messages/Attachments", kind = .Folder, gib = 0.9, theme = .Photos},
		{name = "Logs", kind = .Folder, gib = 0.3, theme = .Logs, grow = 0.01},
		{name = "Safari", kind = .Folder, gib = 0.2, theme = .Cache},
		{name = "Fonts", kind = .Folder, gib = 0.1, theme = .Fonts},
		{name = "Preferences", kind = .Folder, gib = 0.02, theme = .Share},
	},
	.Containers     = {
		{
			name = "com.docker.docker/Data/vms/0/data/Docker.raw",
			kind = .File,
			gib = 30.5,
			grow = 0.008,
		},
		{name = "com.apple.mail", kind = .Folder, gib = 0.9, theme = .Mail},
		{name = "com.apple.mediaanalysisd", kind = .Folder, gib = 0.7, theme = .Cache},
		{name = "com.apple.photoanalysisd", kind = .Folder, gib = 0.6, theme = .Cache},
		{name = "com.apple.news", kind = .Folder, gib = 0.5, theme = .Cache},
		{name = "com.apple.Notes", kind = .Folder, gib = 0.4, theme = .Sim_Data},
		{name = "com.apple.Safari", kind = .Folder, gib = 0.3, theme = .Cache},
		{name = "com.apple.Maps", kind = .Folder, gib = 0.2, theme = .Cache},
	},
	.App_Support    = {
		{name = "MobileSync/Backup", kind = .Folder, gib = 6.5, theme = .Backup},
		{name = "Google/Chrome", kind = .Folder, gib = 2.4, theme = .Support, grow = 0.005},
		{name = "Code", kind = .Folder, gib = 1.8, theme = .Support},
		{name = "JetBrains", kind = .Folder, gib = 1.4, theme = .Support},
		{name = "Slack", kind = .Folder, gib = 1.1, theme = .Support, grow = 0.005},
		{name = "Firefox", kind = .Folder, gib = 0.6, theme = .Support},
		{name = "discord", kind = .Folder, gib = 0.5, theme = .Support},
		{name = "Spotify", kind = .Folder, gib = 0.4, theme = .Support},
		{name = "Figma", kind = .Folder, gib = 0.3, theme = .Support},
	},
	.Caches         = {
		{name = "Homebrew", kind = .Folder, gib = 1.6, theme = .Cache, grow = 0.01},
		{name = "com.spotify.client", kind = .Folder, gib = 1.2, theme = .Cache, grow = 0.01},
		{name = "Google", kind = .Folder, gib = 1.1, theme = .Cache, grow = 0.01},
		{name = "JetBrains", kind = .Folder, gib = 1.0, theme = .Cache},
		{name = "Yarn", kind = .Folder, gib = 0.8, theme = .Scripts},
		{name = "com.apple.Safari", kind = .Folder, gib = 0.4, theme = .Cache},
		{name = "pip", kind = .Folder, gib = 0.4, theme = .Cache},
		{name = "CloudKit", kind = .Folder, gib = 0.4, theme = .Cache},
		{name = "com.microsoft.VSCode.ShipIt", kind = .Folder, gib = 0.3, theme = .Cache},
		{name = "typescript", kind = .Folder, gib = 0.2, theme = .Scripts},
	},
	.Developer      = {
		{name = "Xcode", kind = .Layout, n = u16(Layout.Xcode)},
		{name = "CoreSimulator", kind = .Layout, n = u16(Layout.Core_Simulator)},
	},
	.Xcode          = {
		{name = "DerivedData", kind = .Folder, gib = 7.8, theme = .Derived, grow = 0.02},
		{name = "iOS DeviceSupport", kind = .Folder, gib = 4.1, theme = .Libraries},
		{name = "Archives", kind = .Folder, gib = 1.2, theme = .Libraries},
		{name = "UserData", kind = .Folder, gib = 0.01, theme = .Share},
	},
	.Core_Simulator = {
		{name = "Devices", kind = .Folder, gib = 8.7, theme = .Devices, grow = 0.006},
		{name = "Caches", kind = .Folder, gib = 1.3, theme = .Cache},
	},
	.Pictures       = {
		{name = "Photos Library.photoslibrary", kind = .Layout, n = u16(Layout.Photos_Library)},
		{name = "Screenshots", kind = .Folder, gib = 1.1, theme = .Screens, grow = 0.01},
		{name = "Exports", kind = .Folder, gib = 0.9, theme = .Photos},
	},
	.Photos_Library = {
		{name = "originals", kind = .Folder, gib = 25.6, theme = .Buckets, grow = 0.004},
		{name = "resources/derivatives", kind = .Folder, gib = 3.1, theme = .Thumbs, grow = 0.004},
		{name = "database/Photos.sqlite", kind = .File, gib = 0.45},
		{name = "private", kind = .Folder, gib = 0.2, theme = .Cache},
		{name = "scopes", kind = .Folder, gib = 0.1, theme = .Cache},
	},
	.Music          = {
		{name = "Media.localized/Music", kind = .Folder, gib = 7.4, theme = .Artists},
		{name = "Logic", kind = .Folder, gib = 1.3, theme = .Loops},
		{name = "GarageBand", kind = .Folder, gib = 0.3, theme = .Loops},
	},
	.Dot_Cache      = {
		{name = "huggingface", kind = .Folder, gib = 1.6, theme = .Models},
		{name = "uv", kind = .Folder, gib = 0.9, theme = .Python},
		{name = "puppeteer", kind = .Folder, gib = 0.4, theme = .Libraries},
		{name = "pre-commit", kind = .Folder, gib = 0.2, theme = .Source},
		{name = "node", kind = .Folder, gib = 0.1, theme = .Scripts},
	},
	.Cargo          = {
		{name = "registry/src", kind = .Folder, gib = 1.0, theme = .Source},
		{name = "git", kind = .Folder, gib = 0.4, theme = .Source},
		{name = "bin", kind = .Folder, gib = 0.1, theme = .Binaries},
	},
	.Opt            = {{name = "homebrew", kind = .Layout, n = u16(Layout.Homebrew)}},
	.Homebrew       = {
		{name = "Cellar", kind = .Cellar},
		{name = "share", kind = .Folder, gib = 0.6, theme = .Share},
		{name = "Caskroom", kind = .Folder, gib = 0.5, theme = .Binaries},
		{name = "lib", kind = .Folder, gib = 0.4, theme = .Libraries},
		{name = "Library", kind = .Folder, gib = 0.3, theme = .Source},
		{name = "var", kind = .Folder, gib = 0.1, theme = .Logs},
		{name = "bin", kind = .Folder, gib = 0.02, theme = .Binaries},
	},
	.Private        = {
		{name = "var", kind = .Layout, n = u16(Layout.Var)},
		{name = "tmp", kind = .Folder, gib = 0.05, theme = .Cache},
		{name = "etc", kind = .Folder, gib = 0.004, theme = .Share},
	},
	.Var            = {
		{name = "vm", kind = .Layout, n = u16(Layout.Vm)},
		{name = "folders", kind = .Folder, gib = 2.2, theme = .Cache, grow = 0.01},
		{name = "db", kind = .Folder, gib = 1.1, theme = .Sim_Data},
		{name = "log", kind = .Folder, gib = 0.6, theme = .Logs},
		{name = "MobileSoftwareUpdate", kind = .Folder, gib = 0.5, theme = .Assets},
	},
	.Vm             = {
		{name = "swapfile0", kind = .File, gib = 2.0},
		{name = "sleepimage", kind = .File, gib = 1.0},
		{name = "swapfile1", kind = .File, gib = 1.0},
	},
	.Usr            = {
		{name = "share", kind = .Folder, gib = 0.5, theme = .Share},
		{name = "lib", kind = .Folder, gib = 0.4, theme = .Libraries},
		{name = "bin", kind = .Folder, gib = 0.25, theme = .Binaries},
		{name = "libexec", kind = .Folder, gib = 0.2, theme = .Binaries},
		{name = "sbin", kind = .Folder, gib = 0.05, theme = .Binaries},
		{name = "standalone", kind = .Folder, gib = 0.02, theme = .Libraries},
	},
}

// --- applications --------------------------------------------------------------

@(private)
App :: struct {
	name: string,
	gib:  f64,
}

@(private)
APPS := [?]App {
	{"Xcode", 11.8},
	{"Final Cut Pro", 5.9},
	{"iMovie", 3.1},
	{"Logic Pro", 2.3},
	{"Docker", 2.0},
	{"Blender", 1.7},
	{"Google Chrome", 1.4},
	{"GarageBand", 1.2},
	{"Keynote", 0.72},
	{"Visual Studio Code", 0.62},
	{"Pages", 0.61},
	{"Arc", 0.6},
	{"Numbers", 0.58},
	{"Slack", 0.52},
	{"Postman", 0.49},
	{"Figma", 0.48},
	{"Firefox", 0.42},
	{"Discord", 0.41},
	{"OBS", 0.38},
	{"Notion", 0.33},
	{"Spotify", 0.32},
	{"zoom.us", 0.31},
	{"Obsidian", 0.29},
	{"1Password", 0.27},
	{"Raycast", 0.21},
	{"Steam", 0.09},
	{"Transmit", 0.07},
	{"Ghostty", 0.06},
}

@(private)
apps :: proc(g: ^Gen) {
	buf: [96]u8
	for a, i in APPS {
		add_dir(g, fmt.bprintf(buf[:], "%s.app", a.name), .App, a.gib * GiB, n = u16(i))
	}
	add_dir(g, "Utilities", .Folder, 0.2 * GiB, .Bundles)
	add_file(g, ".localized", 0)
}

// app fills a bundle: its one Contents directory, filled in the same visit.
@(private)
app :: proc(g: ^Gen) {
	a := APPS[g.at.n]
	b := f64(g.at.budget)
	contents, ok := add(g, "Contents", {.Directory}, 0)
	if !ok {
		return
	}
	g.at.index = contents
	buf: [96]u8
	add_file(g, "Info.plist", 6 * KiB)
	add_file(g, "PkgInfo", 8)
	put(g, "_CodeSignature/CodeResources", 40 * KiB + b * 0.0004)
	put(g, fmt.bprintf(buf[:], "MacOS/%s", a.name), b * 0.12)
	add_dir(g, "Resources", .Folder, b * 0.33, .Resources)
	add_dir(g, "Frameworks", .Folder, b * 0.55, .Frameworks)
}

// --- projects ------------------------------------------------------------------

@(private)
Lang :: enum u8 {
	JS,
	Rust,
	Go,
	Python,
}

@(private)
Project :: struct {
	name: string,
	lang: Lang,
	gib:  f64,
}

@(private)
PROJECTS := [?]Project {
	{"pixel-forge", .Rust, 3.1},
	{"nimbus", .Rust, 2.4},
	{"quill", .Rust, 1.8},
	{"tidepool", .Python, 1.6},
	{"atlas-web", .JS, 1.4},
	{"sketchpad", .JS, 1.2},
	{"orbit", .JS, 1.1},
	{"ledger", .JS, 0.9},
	{"cartograph", .Python, 0.9},
	{"lumen-docs", .JS, 0.7},
	{"talks", .JS, 0.5},
	{"harbor-api", .Go, 0.25},
	{"beacon-cli", .Go, 0.15},
	{"dotfiles", .Go, 0.01},
}

@(private)
projects :: proc(g: ^Gen) {
	for p, i in PROJECTS {
		add_dir(g, p.name, .Project, p.gib * GiB, n = u16(i))
	}
}

// project fills a repository, with what its language's tools leave in it.
@(private)
project :: proc(g: ^Gen) {
	b := f64(g.at.budget)
	add_file(g, "README.md", 6 * KiB)
	add_file(g, ".gitignore", 300)
	add_file(g, "LICENSE", 1100)
	add_dir(g, ".git", .Git, b * 0.05)
	switch PROJECTS[g.at.n].lang {
	case .JS:
		add_file(g, "package.json", 2.2 * KiB)
		add_file(g, "bun.lock", 180 * KiB)
		add_file(g, "tsconfig.json", 700)
		add_dir(g, "src", .Folder, b * 0.02, .Source)
		add_dir(g, "node_modules", .Node_Modules, b * 0.8)
		add_dir(g, ".next", .Folder, b * 0.12, .Scripts)
	case .Rust:
		add_file(g, "Cargo.toml", 1.4 * KiB)
		add_file(g, "Cargo.lock", 90 * KiB)
		add_dir(g, "src", .Folder, b * 0.01, .Source)
		add_dir(g, "target", .Folder, b * 0.93, .Rust_Target)
	case .Go:
		add_file(g, "go.mod", 900)
		add_file(g, "go.sum", 24 * KiB)
		add_dir(g, "cmd", .Folder, b * 0.3, .Source)
		add_dir(g, "internal", .Folder, b * 0.64, .Source)
	case .Python:
		add_file(g, "pyproject.toml", 1.8 * KiB)
		add_file(g, "uv.lock", 300 * KiB)
		add_dir(g, "src", .Folder, b * 0.04, .Source)
		add_dir(g, "tests", .Folder, b * 0.03, .Source)
		add_dir(g, ".venv", .Folder, b * 0.86, .Python)
		add_dir(g, ".pytest_cache", .Folder, b * 0.01, .Cache)
	}
}

// node_modules fills a node_modules with packages, the most of them small.
@(private)
node_modules :: proc(g: ^Gen) {
	b := f64(g.at.budget)
	count := clamp(int(b / (420 * KiB)), 3, len(NPM) * len(NPM_SUFFIXES))
	total: f64
	for i in 0 ..< count {
		r := Rng{mix(g.at.seed + u64(i))}
		total += spread(&r, 1.2)
	}
	add_file(g, ".package-lock.json", f64(count) * 900)
	add_dir(g, ".bin", .Folder, f64(count) * 300, .Scripts, depth = 9)
	buf: [96]u8
	for i in 0 ..< count {
		r := Rng{mix(g.at.seed + u64(i))}
		share := spread(&r, 1.2) / total
		add_dir(g, package_name(buf[:], i), .Package, b * share)
	}
}

// package_name is the i-th package: the common ones first, then ones made of them.
@(private)
package_name :: proc(buf: []u8, i: int) -> string {
	if i < len(NPM) {
		return NPM[i]
	}
	j := i - len(NPM)
	return fmt.bprintf(
		buf,
		"%s-%s",
		NPM[j % len(NPM)],
		NPM_SUFFIXES[j / len(NPM) % len(NPM_SUFFIXES)],
	)
}

@(private)
package_dir :: proc(g: ^Gen) {
	b := f64(g.at.budget)
	r := Rng{g.at.seed}
	add_file(g, "package.json", 1.8 * KiB)
	add_file(g, "README.md", 3 * KiB + b * 0.02)
	add_file(g, "LICENSE", 1.1 * KiB)
	code := b * 0.9
	if unit(&r) < 0.06 && b > 600 * KiB {
		add_dir(g, "node_modules", .Node_Modules, b * 0.3)
		code = b * 0.6
	}
	add_dir(g, PACKAGE_DIRS[next(&r) % len(PACKAGE_DIRS)], .Folder, code, .Scripts, depth = 1)
}

@(private)
PACKAGE_DIRS := [?]string{"dist", "lib", "esm", "cjs", "src"}

// git fills a .git directory: its loose objects, and the files beside them.
@(private)
git :: proc(g: ^Gen) {
	b := f64(g.at.budget)
	add_file(g, "HEAD", 23)
	add_file(g, "config", 400)
	add_file(g, "description", 73)
	add_file(g, "index", b * 0.04)
	add_file(g, "packed-refs", 2 * KiB)
	put(g, "refs/heads/main", 41)
	put(g, "logs/HEAD", 20 * KiB)
	add_dir(g, "hooks", .Folder, 60 * KiB, .Hooks)
	add_dir(g, "objects", .Folder, b * 0.95, .Objects)
}

// --- lists of files ------------------------------------------------------------

@(private)
List :: enum u16 {
	Movies,
	Downloads,
}

@(private)
Item :: struct {
	name: string,
	mib:  f64,
}

// items fills a directory from its list: the first `shown` of it, and one more
// every third day after.
@(private)
items :: proc(g: ^Gen) {
	list, shown := ITEMS[List(g.at.n)], ITEMS_SHOWN[List(g.at.n)]
	count := min(len(list), shown + g.cfg.day / 3)
	for it in list[:count] {
		add_file(g, it.name, it.mib * MiB)
	}
}

@(private)
ITEMS_SHOWN := [List]int {
	.Movies    = 8,
	.Downloads = 22,
}

@(private)
ITEMS := [List][]Item {
	.Movies    = {
		{"Lisbon 2025.mov", 6300},
		{"Interview raw.mov", 5400},
		{"Drone flight 04.mov", 4700},
		{"Recital.mov", 3900},
		{"Conference talk.mp4", 1450},
		{"Family dinner.mp4", 1120},
		{"Screen recording 2026-08-14.mov", 930},
		{"Timelapse sunset.mp4", 610},
	},
	.Downloads = {
		{"ubuntu-24.04-live-server-arm64.iso", 2600},
		{"photos-export.zip", 1400},
		{"android-studio-2025.dmg", 1300},
		{"minecraft-world-backup.zip", 900},
		{"Docker.dmg", 640},
		{"wallpaper-pack.zip", 520},
		{"Blender-4.5-macos-arm64.dmg", 420},
		{"PostgreSQL-17.dmg", 420},
		{"dataset-cities.csv.zip", 380},
		{"LibreOffice_25.2_MacOS_aarch64.dmg", 330},
		{"design-review.mp4", 240},
		{"Arc-latest.dmg", 230},
		{"OBS-Studio-31.1.dmg", 210},
		{"Figma.dmg", 190},
		{"VirtualBox-7.1.dmg", 160},
		{"Godot_v4.4.app.zip", 150},
		{"zoom-installer.pkg", 110},
		{"node-v24.4.0.pkg", 85},
		{"Raycast.dmg", 70},
		{"talk-slides.key", 64},
		{"podcast-ep42.mp3", 58},
		{"unicode-15.zip", 45},
		{"font-inter-4.1.zip", 37},
		{"terraform_1.12_darwin_arm64.zip", 28},
		{"rust-book.pdf", 9},
		{"Steam.dmg", 4},
		{"IMG_4471.HEIC", 3.1},
		{"Screenshot 2026-09-30 at 14.02.11.png", 1.4},
		{"lease-agreement.pdf", 1.2},
		{"budget-2026.xlsx", 0.6},
		{"tax-summary-2025.pdf", 0.4},
		{"keyboard-firmware.hex", 0.3},
		{"boarding-pass.pdf", 0.3},
		{"invoice-2026-07.pdf", 0.2},
		{"receipt-0832.pdf", 0.1},
		{"notes.txt", 0.01},
	},
}

// --- homebrew ------------------------------------------------------------------

@(private)
Formula :: struct {
	name: string,
	mib:  f64,
}

@(private)
cellar :: proc(g: ^Gen) {
	for f, i in FORMULAE {
		add_dir(g, f.name, .Keg, f.mib * MiB, n = u16(i))
	}
}

// keg fills a formula's directory: one version, laid out as a prefix.
@(private)
keg :: proc(g: ^Gen) {
	b := f64(g.at.budget)
	r := Rng{g.at.seed}
	buf: [32]u8
	version := fmt.bprintf(buf[:], "%d.%d.%d", 1 + next(&r) % 24, next(&r) % 20, next(&r) % 12)
	index, ok := add(g, version, {.Directory}, 0)
	if !ok {
		return
	}
	g.at.index = index
	add_file(g, "INSTALL_RECEIPT.json", 2 * KiB)
	add_file(g, "LICENSE", 1.1 * KiB)
	add_file(g, "README.md", 4 * KiB)
	add_dir(g, "bin", .Folder, b * 0.25, .Binaries, depth = 9)
	add_dir(g, "lib", .Folder, b * 0.55, .Libraries)
	add_dir(g, "share", .Folder, b * 0.17, .Share)
	add_dir(g, "include", .Folder, b * 0.03, .Headers)
}

@(private)
FORMULAE := [?]Formula {
	{"llvm", 1900},
	{"rust", 950},
	{"gcc", 820},
	{"ollama", 450},
	{"zig", 300},
	{"python@3.13", 280},
	{"go", 230},
	{"odin", 160},
	{"deno", 140},
	{"ffmpeg", 120},
	{"postgresql@17", 90},
	{"cmake", 90},
	{"icu4c@77", 80},
	{"node", 75},
	{"ruby", 70},
	{"imagemagick", 70},
	{"shellcheck", 70},
	{"git", 60},
	{"bun", 60},
	{"gh", 50},
	{"openssl@3", 40},
	{"glib", 40},
	{"uv", 35},
	{"neovim", 30},
	{"ast-grep", 30},
	{"gettext", 25},
	{"gnupg", 25},
	{"jpeg-xl", 18},
	{"protobuf", 15},
	{"redis", 12},
	{"x265", 12},
	{"sdl3", 12},
	{"sqlite", 10},
	{"harfbuzz", 10},
	{"aom", 9},
	{"prek", 9},
	{"ripgrep", 6},
	{"cairo", 6},
	{"curl", 6},
	{"x264", 5},
	{"just", 5},
	{"fd", 4},
	{"wget", 4},
	{"pango", 4},
	{"zstd", 3},
	{"fontconfig", 3},
	{"shfmt", 3},
	{"tmux", 2},
	{"dav1d", 2},
	{"freetype", 2},
	{"lame", 2},
	{"xz", 2},
	{"jq", 1.5},
	{"libpng", 1.4},
	{"opus", 1},
	{"lz4", 1},
}
