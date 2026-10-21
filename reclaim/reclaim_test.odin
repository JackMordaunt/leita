package reclaim

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "../home"

// ANN is the made-up user the trees below belong to.
@(private)
ANN :: home.User{"/home/ann", "1000"}

// A tree made in memory: each entry's parent is its index's slot in the tree.
@(private)
Fake :: struct {
	name:      [dynamic]string,
	directory: [dynamic]bool,
	bytes:     [dynamic]u64,
	parent:    [dynamic]u32,
}

@(private)
fake_add :: proc(t: ^Fake, parent: u32, name: string, directory: bool, bytes: u64 = 0) -> u32 {
	append(&t.name, name)
	append(&t.directory, directory)
	append(&t.bytes, bytes)
	append(&t.parent, parent)
	return u32(len(t.name) - 1)
}

// fake_path makes each directory along path under from, returning the last.
@(private)
fake_path :: proc(t: ^Fake, from: u32, path: string) -> u32 {
	at := from
	for name in strings.split(path, "/", context.temp_allocator) {
		found := false
		for p, ii in t.parent {
			if p == at && u32(ii) != at && t.name[ii] == name {
				at, found = u32(ii), true
				break
			}
		}
		if !found {
			at = fake_add(t, at, name, true)
		}
	}
	return at
}

// fake_has is whether every directory along path exists under from.
@(private)
fake_has :: proc(t: ^Fake, from: u32, path: string) -> bool {
	at := from
	for name in strings.split(path, "/", context.temp_allocator) {
		found := false
		for p, ii in t.parent {
			if p == at && u32(ii) != at && t.name[ii] == name {
				at, found = u32(ii), true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

@(private)
fake_source :: proc(t: ^Fake) -> Source {
	return {
		data = t,
		name = proc(data: rawptr, node: u32) -> string {return (^Fake)(data).name[node]},
		directory = proc(data: rawptr, node: u32) -> bool {return (^Fake)(data).directory[node]},
		bytes = proc(data: rawptr, node: u32) -> u64 {return (^Fake)(data).bytes[node]},
		children = proc(data: rawptr, node: u32, into: ^[dynamic]u32) {
			t := (^Fake)(data)
			for p, ii in t.parent {
				if p == node && u32(ii) != node {
					append(into, u32(ii))
				}
			}
		},
	}
}

@(private)
fake_destroy :: proc(t: ^Fake) {
	delete(t.name)
	delete(t.directory)
	delete(t.bytes)
	delete(t.parent)
}

@(private)
found_paths :: proc(found: []Candidate) -> []string {
	out := make([]string, len(found), context.temp_allocator)
	for c, ii in found {
		out[ii] = c.path
	}
	slice.sort(out)
	return out
}

@(private)
candidates_destroy :: proc(found: []Candidate) {
	for c in found {
		delete(c.path)
	}
	delete(found)
}

// The home of a made-up user, scanned from the root of the filesystem.
@(private)
home_tree :: proc(t: ^Fake) -> (root: u32) {
	root = fake_add(t, 0, "/", true)
	home := fake_path(t, root, "home/ann")

	// Proved by a marker beside them.
	web := fake_path(t, home, "src/web")
	fake_add(t, web, "package.json", false, 1)
	fake_add(t, fake_path(t, web, "node_modules"), "left-pad.js", false, 100)
	rust := fake_path(t, home, "src/tool")
	fake_add(t, rust, "Cargo.toml", false, 1)
	fake_add(t, fake_path(t, rust, "target"), "CACHEDIR.TAG", false, 1)
	fake_path(t, rust, "target/debug")
	fake_path(t, home, "src/py/pkg/__pycache__")

	// Named like build output, without the proof.
	fake_path(t, home, "src/notes/build")
	fake_path(t, home, "photos/target")
	dist := fake_path(t, home, "src/site")
	fake_add(t, dist, "package.json", false, 1)
	fake_path(t, dist, "dist")
	fake_path(t, home, "src/lone/.venv")

	// A match is not looked inside: the nested node_modules is part of it.
	fake_path(t, web, "node_modules/react/node_modules")

	// Never inside .git or a system directory.
	fake_path(t, home, "src/web/.git/node_modules")
	fake_path(t, home, "src/web/.git/hooks/__pycache__")
	fake_path(t, root, "usr/lib/python3/__pycache__")

	// Where they are under home.
	fake_path(t, home, ".cache/chromium")
	fake_path(t, home, ".cache/pip")
	fake_add(t, fake_path(t, home, ".cache"), "a-file-in-cache", false, 5)
	fake_path(t, home, "go/pkg/mod/github.com")
	fake_path(t, home, TRASH + "/files")

	// The macOS places, looked for on a Mac.
	fake_path(t, home, "Library/Caches/com.apple.Safari")
	fake_path(t, home, "Library/Caches/Homebrew/downloads")
	fake_add(t, fake_path(t, home, "Library/Caches"), "a-file-in-caches", false, 5)
	fake_path(t, home, "Library/Developer/Xcode/DerivedData/App-abc/Build")
	fake_path(t, home, "Library/Developer/Xcode/iOS DeviceSupport/17.0")
	fake_path(t, home, "Library/Developer/Xcode/watchOS DeviceSupport/10.0")
	fake_path(t, home, "Library/Developer/CoreSimulator/Caches/dyld")
	swift := fake_path(t, home, "src/swift")
	fake_add(t, swift, "Package.swift", false, 1)
	fake_path(t, swift, ".build/debug")
	fake_path(t, home, "src/odin/.odin-cache/abc")

	// What Reclaim must leave alone under a macOS home, whatever its size: iOS
	// backups, Xcode archives, the simulators' disks, applications' sandboxed data
	// and Docker's or OrbStack's virtual disks.
	fake_path(t, home, "Library/Application Support/MobileSync/Backup/dev1")
	fake_path(t, home, "Library/Developer/Xcode/Archives/2025")
	fake_path(t, home, "Library/Developer/CoreSimulator/Devices/ABC/data")
	fake_path(t, home, "Library/Containers/com.apple.mail/Data/Library/Caches")
	docker := fake_path(t, home, "Library/Containers/com.docker.docker/Data/vms/0/data")
	fake_add(t, docker, "Docker.raw", false, 1 << 30)
	fake_path(t, home, "Library/Group Containers/group.com.apple.notes/Caches")
	fake_path(t, home, ".orbstack/data")
	// A .build without its manifest is someone's work.
	fake_path(t, home, "src/notes/.build")
	return
}

@(test)
only_what_proves_itself_regenerable_is_found :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := home_tree(&tree)
	found := find(fake_source(&tree), root, "/", ANN, platform = .Darwin)
	defer candidates_destroy(found)

	want := []string {
		"/home/ann/.cache/chromium",
		"/home/ann/.cache/pip",
		"/home/ann/" + TRASH,
		"/home/ann/Library/Caches/Homebrew",
		"/home/ann/Library/Caches/com.apple.Safari",
		"/home/ann/Library/Developer/CoreSimulator/Caches",
		"/home/ann/Library/Developer/Xcode/DerivedData",
		"/home/ann/Library/Developer/Xcode/iOS DeviceSupport",
		"/home/ann/Library/Developer/Xcode/watchOS DeviceSupport",
		"/home/ann/go/pkg/mod",
		"/home/ann/src/odin/.odin-cache",
		"/home/ann/src/py/pkg/__pycache__",
		"/home/ann/src/swift/.build",
		"/home/ann/src/tool/target",
		"/home/ann/src/web/node_modules",
	}
	slice.sort(want)
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
}

@(test)
each_candidate_says_what_it_is :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := home_tree(&tree)
	found := find(fake_source(&tree), root, "/", ANN, platform = .Darwin)
	defer candidates_destroy(found)
	testing.expect_value(t, len(found), 15)
	for c in found {
		want: Category
		switch {
		case strings.has_suffix(c.path, "node_modules"):
			want = .Dependencies
		case strings.has_suffix(c.path, "target"),
		     strings.has_suffix(c.path, ".build"),
		     strings.has_suffix(c.path, ".odin-cache"),
		     strings.has_suffix(c.path, "DerivedData"):
			want = .Build_Output
		case strings.has_suffix(c.path, "__pycache__"):
			want = .Python
		case strings.has_suffix(c.path, ".cache/pip"),
		     strings.has_suffix(c.path, "Caches/Homebrew"):
			want = .Package_Cache
		case strings.contains(c.path, ".cache/"), strings.contains(c.path, "Caches"):
			want = .App_Cache
		case strings.has_suffix(c.path, "DeviceSupport"):
			want = .Device_Support
		case strings.has_suffix(c.path, "go/pkg/mod"):
			want = .Package_Cache
		case strings.has_suffix(c.path, "Trash"):
			want = .Trash
		}
		testing.expectf(t, c.category == want, "%s is %v, not %v", c.path, c.category, want)
	}
}

// Scanning a project directly, below home, still finds its output, and the home
// places are only where home is.
@(test)
a_scan_below_home_finds_by_rule_alone :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	web := fake_add(&tree, 0, "web", true)
	fake_add(&tree, web, "package.json", false, 1)
	fake_path(&tree, web, "node_modules")
	fake_path(&tree, web, ".cache/x")
	found := find(fake_source(&tree), web, "/home/ann/src/web", ANN, platform = .Unix)
	defer candidates_destroy(found)
	testing.expect(t, slice.equal(found_paths(found), []string{"/home/ann/src/web/node_modules"}))
}

@(test)
nothing_under_a_system_directory_even_from_its_top :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	lib := fake_add(&tree, 0, "lib", true)
	fake_path(&tree, lib, "python3/__pycache__")
	found := find(fake_source(&tree), lib, "/usr/lib", ANN, platform = .Unix)
	defer candidates_destroy(found)
	testing.expect_value(t, len(found), 0)
	f := Finder {
		platform = .Unix,
		system   = system_dirs(.Unix, context.temp_allocator),
	}
	testing.expect(t, under_system(&f, "/usr"))
	testing.expect(t, under_system(&f, "/usr/lib"))
	testing.expect(t, !under_system(&f, "/usrdata"))
	testing.expect(t, !under_system(&f, "/home/ann"))
}

// What macOS keeps under home that is not made again is never offered, whatever
// it holds: a sandboxed application's own Caches is not the user's.
@(test)
nothing_macos_keeps_for_good_is_offered :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := home_tree(&tree)
	found := find(fake_source(&tree), root, "/", ANN, platform = .Darwin)
	defer candidates_destroy(found)
	testing.expect_value(t, len(found), 15)
	kept := []string {
		"Library/Application Support",
		"Library/Developer/Xcode/Archives",
		"Library/Developer/CoreSimulator/Devices",
		"Library/Containers",
		"Library/Group Containers",
		".orbstack",
		"src/notes/.build",
	}
	home := fake_path(&tree, root, "home/ann")
	for k in kept {
		testing.expectf(t, fake_has(&tree, home, k), "%s is in the tree to be kept", k)
		full := strings.concatenate({"/home/ann/", k}, context.temp_allocator)
		for c in found {
			testing.expectf(t, !strings.has_prefix(c.path, full), "%s offered under %s", c.path, k)
		}
	}
}

// The user's Trash on another volume is theirs by id; the other users' and the
// volume's own files are not, and a scan of the volume itself reaches it.
@(test)
the_users_trash_on_another_volume_is_found :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	fake_path(&tree, root, "Volumes/Backup/.Trashes/1000/old")
	fake_path(&tree, root, "Volumes/Backup/.Trashes/501/theirs")
	fake_path(&tree, root, "Volumes/Backup/Photos/1000")
	fake_path(&tree, root, "Volumes/.Trashes/1000")
	found := find(fake_source(&tree), root, "/", ANN, platform = .Darwin)
	defer candidates_destroy(found)
	want := []string{"/Volumes/Backup/.Trashes/1000"}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
	if len(found) == 1 {
		testing.expect_value(t, found[0].category, Category.Trash)
	}

	volume := fake_path(&tree, root, "Volumes/Backup")
	below := find(fake_source(&tree), volume, "/Volumes/Backup", ANN, platform = .Darwin)
	defer candidates_destroy(below)
	testing.expect(t, slice.equal(found_paths(below), want))

	none := find(fake_source(&tree), root, "/", home.User{"/home/ann", ""}, platform = .Darwin)
	defer candidates_destroy(none)
	testing.expect_value(t, len(none), 0)
}

SID :: "S-1-5-21-1-2-3-1001"

// The Recycle Bin is this user's folder on each volume, not the freedesktop.org
// Trash under home, and not another account's folder beside it.
@(test)
the_recycle_bin_on_each_volume_is_this_users :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, `C:\`, true)
	fake_path(&tree, root, "$Recycle.Bin/" + SID + "/$R0")
	fake_path(&tree, root, "$Recycle.Bin/S-1-5-18/system")
	fake_path(&tree, root, "Users/ann/.local/share/Trash/files")
	make_output(&tree, root, "Users/ann/src/web", "package.json", "node_modules")
	ann := home.User{`C:\Users\ann`, SID}
	found := find(fake_source(&tree), root, `C:\`, ann, platform = .Windows)
	defer candidates_destroy(found)
	want := []string{`C:\$Recycle.Bin\` + SID, `C:\Users\ann\src\web\node_modules`}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
	for c in found {
		if strings.contains(c.path, RECYCLE_DIR) {
			testing.expect_value(t, c.category, Category.Trash)
		}
	}

	home_dir := fake_path(&tree, root, "Users/ann")
	below := find(fake_source(&tree), home_dir, `C:\Users\ann`, ann, platform = .Windows)
	defer candidates_destroy(below)
	testing.expect(
		t,
		slice.equal(found_paths(below), []string{`C:\Users\ann\src\web\node_modules`}),
		"the Recycle Bin is not under home",
	)

	none := find(
		fake_source(&tree),
		root,
		`C:\`,
		home.User{`C:\Users\ann`, ""},
		platform = .Windows,
	)
	defer candidates_destroy(none)
	testing.expect(
		t,
		slice.equal(found_paths(none), []string{`C:\Users\ann\src\web\node_modules`}),
	)
}

@(test)
recycle_bin_paths_are_the_sid_folder_on_the_volume :: proc(t: ^testing.T) {
	testing.expect(t, is_recycle_bin(`C:\$Recycle.Bin\` + SID, SID))
	testing.expect(t, is_recycle_bin(`c:/$recycle.bin/` + SID, SID))
	testing.expect(t, !is_recycle_bin(`C:\$Recycle.Bin\` + SID + `\old`, SID), "a file inside")
	testing.expect(t, !is_recycle_bin(`C:\$Recycle.Bin\S-1-5-18`, SID), "another account")
	testing.expect(t, !is_recycle_bin(`C:\$Recycle.Bin`, SID), "the bin itself")
	testing.expect(t, !is_recycle_bin(`C:\Users\ann\` + SID, SID), "the SID as a name")
	testing.expect(t, !is_recycle_bin(`C:\$Recycle.Bin\` + SID, ""), "no SID")
	testing.expect_value(
		t,
		recycle_bin_path(`C:\`, SID, context.temp_allocator),
		`C:\$Recycle.Bin\` + SID,
	)
	testing.expect_value(
		t,
		recycle_bin_volume(`C:\$Recycle.Bin\` + SID, context.temp_allocator),
		`C:\`,
	)
	testing.expect_value(t, recycle_bin_node(`C:\`), max(u32) - u32('c' - 'a'))
	testing.expect_value(t, recycle_bin_node(`D:`), max(u32) - u32('d' - 'a'))
}

// A Recycle Bin find did not visit is still offered, at the shell's size; one it
// did visit takes that size in place of the tree's.
@(test)
a_recycle_bin_outside_the_scan_is_still_offered :: proc(t: ^testing.T) {
	found := []Candidate{{1, strings.clone(`C:\Users\ann\web\node_modules`), 100, .Dependencies}}
	bins := []Recycle_Bin{{`C:\`, recycle_bin_path(`C:\`, SID, context.temp_allocator), 4096}}
	got := overlay_recycle_bins(found, bins, SID, recycle_bin_node)
	defer candidates_destroy(got)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[1].path, `C:\$Recycle.Bin\` + SID)
	testing.expect_value(t, got[1].bytes, 4096)
	testing.expect_value(t, got[1].category, Category.Trash)
	testing.expect_value(t, got[1].node, recycle_bin_node(`C:\`))

	seen := make([]Candidate, 1)
	seen[0] = {7, strings.clone(`C:\$Recycle.Bin\` + SID), 12, .Trash}
	sized := overlay_recycle_bins(seen, bins, SID, recycle_bin_node)
	defer candidates_destroy(sized)
	testing.expect_value(t, len(sized), 1)
	testing.expect_value(t, sized[0].node, 7)
	testing.expect_value(t, sized[0].bytes, 4096)

	empty := make([]Candidate, 1)
	empty[0] = {1, strings.clone(`C:\web\node_modules`), 100, .Dependencies}
	none := overlay_recycle_bins(
		empty,
		{{`C:\`, `C:\$Recycle.Bin\` + SID, 0}},
		SID,
		recycle_bin_node,
	)
	defer candidates_destroy(none)
	testing.expect_value(t, len(none), 1)
	testing.expect_value(t, none[0].node, 1)
	testing.expect_value(t, none[0].path, `C:\web\node_modules`)
	testing.expect_value(t, none[0].bytes, 100)
	testing.expect_value(t, none[0].category, Category.Dependencies)
	for c in none {
		testing.expect(t, !is_recycle_bin(c.path, SID), "a zero-byte bin is not injected")
	}
}

// project makes a directory at path under from holding the file marker, as a
// project's manifest, and returns it.
@(private)
project :: proc(t: ^Fake, from: u32, path, marker: string) -> u32 {
	dir := fake_path(t, from, path)
	fake_add(t, dir, marker, false, 1)
	return dir
}

// make_output makes the directory out in a project at path under from whose
// manifest is marker, holding the file inside unless that is "".
@(private)
make_output :: proc(t: ^Fake, from: u32, path, marker, out: string, inside := "") {
	dir := fake_path(t, project(t, from, path, marker), out)
	if inside != "" {
		fake_add(t, dir, inside, false, 1)
	}
}

// What Windows and its programs installed, node_modules beside a package.json
// or a __pycache__, is never offered, wherever the environment puts Windows, in
// whatever case and with either slash.
@(test)
nothing_under_windows_or_its_programs :: proc(t: ^testing.T) {
	// The environment of the Windows runner CI tests on.
	RUNNER :: [?][2]string {
		{"SystemRoot", `C:\Windows`},
		{"windir", `C:\Windows`},
		{"ProgramFiles", `C:\Program Files`},
		{"ProgramFiles(x86)", `C:\Program Files (x86)`},
		{"ProgramW6432", `C:\Program Files`},
		{"ProgramData", `C:\ProgramData`},
	}
	was: [len(RUNNER)]string
	for v, i in RUNNER {
		was[i] = strings.clone(os.get_env(v[0], context.temp_allocator), context.temp_allocator)
		testing.expect(t, os.set_env(v[0], v[1]) == nil)
	}
	defer for v, i in RUNNER {
		if was[i] != "" {
			os.set_env(v[0], was[i])
		} else {
			os.unset_env(v[0])
		}
	}

	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, `C:\`, true)
	make_output(&tree, root, "Program Files/nodejs", "package.json", "node_modules")
	make_output(&tree, root, "Program Files (x86)/app", "package.json", "node_modules")
	fake_path(&tree, root, "PROGRAMDATA/tool/__pycache__")
	fake_path(&tree, root, "windows/System32/__pycache__")
	make_output(&tree, root, "Users/ann/src/web", "package.json", "node_modules")
	ann := home.User{"C:/Users/ann/", ""}
	found := find(fake_source(&tree), root, `C:\`, ann, platform = .Windows)
	defer candidates_destroy(found)
	want := []string{`C:\Users\ann\src\web\node_modules`}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)

	// From below a system directory, by either slash, nothing.
	nodejs := fake_path(&tree, root, "Program Files/nodejs")
	below := find(fake_source(&tree), nodejs, "c:/program files/nodejs", ann, platform = .Windows)
	defer candidates_destroy(below)
	testing.expect_value(t, len(below), 0)

	// The runner's temporary directory, by its short name, is no program's.
	temp := fake_path(&tree, root, "Users/RUNNER~1/AppData/Local/Temp/leita_gui_reclaim")
	make_output(&tree, temp, "web", "package.json", "node_modules")
	make_output(&tree, temp, "rust", "Cargo.toml", "target", "CACHEDIR.TAG")
	runner := home.User{`C:\Users\runneradmin`, ""}
	TEMP :: `C:\Users\RUNNER~1\AppData\Local\Temp\leita_gui_reclaim`
	fixture := find(fake_source(&tree), temp, TEMP, runner, platform = .Windows)
	defer candidates_destroy(fixture)
	want = []string{TEMP + `\rust\target`, TEMP + `\web\node_modules`}
	got = found_paths(fixture)
	testing.expectf(
		t,
		slice.equal(got, want),
		"in the runner's temp found\n%v\nwant\n%v",
		got,
		want,
	)

	// Windows where the environment says it is, not only at C:\Windows.
	testing.expect(t, os.set_env("SystemRoot", `D:\WinNT\`) == nil)
	other := fake_add(&tree, 0, `D:\`, true)
	fake_path(&tree, other, "WinNT/x/__pycache__")
	fake_path(&tree, other, "WinNTdata/x/__pycache__")
	moved := find(fake_source(&tree), other, `D:\`, ann, platform = .Windows)
	defer candidates_destroy(moved)
	testing.expect(t, slice.equal(found_paths(moved), []string{`D:\WinNTdata\x\__pycache__`}))
}

// /opt, /mnt, /media, /srv, /snap, /nix and root's home are not the user's to
// clear, whatever proof stands beside what they hold.
@(test)
nothing_under_what_unix_installs_or_mounts :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	installed := []string {
		"opt/app",
		"mnt/backup/x",
		"media/ann/disk/web",
		"srv/www",
		"snap/code/1/app",
		"nix/store/abc-web",
		"root/web",
		"var/lib/app",
	}
	for dir in installed {
		make_output(&tree, root, dir, "package.json", "node_modules")
	}
	make_output(&tree, root, "home/ann/web", "package.json", "node_modules")
	found := find(fake_source(&tree), root, "/", ANN, platform = .Unix)
	defer candidates_destroy(found)
	want := []string{"/home/ann/web/node_modules"}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)

	opt := fake_path(&tree, root, "opt")
	below := find(fake_source(&tree), opt, "/opt", ANN, platform = .Unix)
	defer candidates_destroy(below)
	testing.expect_value(t, len(below), 0)
}

// A Library under a Linux home is someone's own folder: none of macOS's places
// is looked for there, and a Mac's own system directories are a Mac's.
@(test)
macos_places_only_on_a_mac :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	home := fake_path(&tree, root, "home/ann")
	fake_path(&tree, home, "Library/Caches/Homebrew")
	fake_path(&tree, home, "Library/Caches/x")
	fake_path(&tree, home, "Library/Developer/Xcode/DerivedData")
	make_output(&tree, root, "Library/App", "package.json", "node_modules")

	linux := find(fake_source(&tree), root, "/", ANN, platform = .Unix)
	defer candidates_destroy(linux)
	want := []string{"/Library/App/node_modules"}
	got := found_paths(linux)
	testing.expectf(t, slice.equal(got, want), "on Linux found\n%v\nwant\n%v", got, want)

	mac := find(fake_source(&tree), root, "/", ANN, platform = .Darwin)
	defer candidates_destroy(mac)
	want = []string {
		"/home/ann/Library/Caches/Homebrew",
		"/home/ann/Library/Developer/Xcode/DerivedData",
	}
	got = found_paths(mac)
	testing.expectf(t, slice.equal(got, want), "on a Mac found\n%v\nwant\n%v", got, want)
}

// Only the caches known to be made again are offered from ~/.cache; one with a
// name nobody checked is looked in like any other folder, and Hugging Face's
// models are offered without the login token beside them.
@(test)
only_known_caches_are_offered :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	home := fake_path(&tree, root, "home/ann")
	fake_path(&tree, home, ".cache/pip/wheels")
	fake_path(&tree, home, ".cache/unknown/saves")
	fake_path(&tree, home, ".cache/go-build/00")
	hf := fake_path(&tree, home, ".cache/huggingface")
	fake_add(&tree, hf, "token", false, 1)
	fake_path(&tree, hf, "hub/models--x")
	make_output(&tree, home, ".cache/unknown/app", "package.json", "node_modules")
	found := find(fake_source(&tree), root, "/", ANN, platform = .Unix)
	defer candidates_destroy(found)
	want := []string {
		"/home/ann/.cache/go-build",
		"/home/ann/.cache/huggingface/hub",
		"/home/ann/.cache/pip",
		"/home/ann/.cache/unknown/app/node_modules",
	}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
}

// build, target and a virtual environment beside their project's file are its
// tool's only when they hold the file the tool writes into them.
@(test)
output_holds_what_its_tool_wrote :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	src := fake_path(&tree, root, "home/ann/src")
	make_output(&tree, src, "notes", "CMakeLists.txt", "build")
	make_output(&tree, src, "cmake", "CMakeLists.txt", "build", "CMakeCache.txt")
	make_output(&tree, src, "meson-docs", "meson.build", "build")
	make_output(&tree, src, "meson", "meson.build", "build", "build.ninja")
	make_output(&tree, src, "rust-old", "Cargo.toml", "target")
	make_output(&tree, src, "rust", "Cargo.toml", "target", "CACHEDIR.TAG")
	make_output(&tree, src, "pydata", "requirements.txt", "venv")
	make_output(&tree, src, "py", "requirements.txt", "venv", "pyvenv.cfg")
	make_output(&tree, src, "uv", "pyproject.toml", ".venv", "pyvenv.cfg")
	// The file must be a file: a folder of that name proves nothing.
	fake_path(&tree, project(&tree, src, "odd", "Cargo.toml"), "target/CACHEDIR.TAG")
	found := find(fake_source(&tree), root, "/", ANN, platform = .Unix)
	defer candidates_destroy(found)
	want := []string {
		"/home/ann/src/cmake/build",
		"/home/ann/src/meson/build",
		"/home/ann/src/py/venv",
		"/home/ann/src/rust/target",
		"/home/ann/src/uv/.venv",
	}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
}

// within compares on the platform's separator and case, never part of a name.
@(test)
within_compares_as_the_platform_does :: proc(t: ^testing.T) {
	rel, ok := within(`c:/program files/nodejs`, `C:\Program Files`, .Windows)
	testing.expect(t, ok && rel == "nodejs")
	_, ok = within(`C:\Program Filesystem`, `C:\Program Files`, .Windows)
	testing.expect(t, !ok)
	_, ok = within("/Opt/app", "/opt", .Unix)
	testing.expect(t, !ok, "case counts on Linux")
	_, ok = within(`/opt\app`, "/opt", .Unix)
	testing.expect(t, !ok, "a backslash is part of a name on Linux")
	rel, ok = within("/opt", "/opt", .Unix)
	testing.expect(t, ok && rel == "")
}

// As root, Reclaim deletes only what the person sudo ran it for could: a folder
// under their home that they own. Run as anyone else, the system decides.
@(test)
root_deletes_only_the_invokers_own_under_their_home :: proc(t: ^testing.T) {
	ann := home.User{"/home/ann/", "1000"}
	mine := "/home/ann/src/web/node_modules"
	testing.expect(t, root_may_delete(mine, 1000, ann, 0, .Unix))
	testing.expect(
		t,
		!root_may_delete(mine, 1001, ann, 0, .Unix),
		"another's folder in ann's home",
	)
	testing.expect(t, !root_may_delete(mine, 0, ann, 0, .Unix), "root's folder in ann's home")
	bobs := "/home/bob/proj/node_modules"
	testing.expect(t, !root_may_delete(bobs, 1001, ann, 0, .Unix), "bob's, under his home")
	testing.expect(t, !root_may_delete(bobs, 1000, ann, 0, .Unix), "ann's, outside her home")
	testing.expect(
		t,
		!root_may_delete("/home/annex/x", 1000, ann, 0, .Unix),
		"a name that starts alike",
	)
	testing.expect(t, !root_may_delete("/home/ann", 1000, ann, 0, .Unix), "the home itself")
	testing.expect(t, !root_may_delete(mine, 1000, home.User{"/home/ann", ""}, 0, .Unix), "no id")
	testing.expect(t, !root_may_delete(mine, 1000, home.User{"", "1000"}, 0, .Unix), "no home")

	// Not root: the system's permissions decide, whoever owns it.
	testing.expect(t, root_may_delete(bobs, 1001, ann, 1000, .Unix))

	// ".." is the parent, so the text of the path is not where it lies. Root must
	// not follow it out of the home. The Windows rules treat either slash as a
	// separator.
	testing.expect(
		t,
		!root_may_delete("/home/ann/../bob/node_modules", 1000, ann, 0, .Unix),
		"a .. component leaves the home",
	)
	testing.expect(
		t,
		!root_may_delete("/home/ann/../../etc/node_modules", 1000, ann, 0, .Unix),
		"a .. component reaches a system directory",
	)
	testing.expect(
		t,
		root_may_delete("/home/ann/./src/../src/web/node_modules", 1000, ann, 0, .Unix),
		"dots that stay inside the home",
	)
	win := home.User{`C:\Users\ann`, "1000"}
	testing.expect(
		t,
		!root_may_delete(`C:\Users\ann\..\bob\node_modules`, 1000, win, 0, .Windows),
		"a .. component leaves the home on Windows",
	)
	testing.expect(
		t,
		!root_may_delete(`C:/Users/ann/../../Windows/Temp/node_modules`, 1000, win, 0, .Windows),
		"either slash, out to a system directory",
	)
	testing.expect(
		t,
		root_may_delete(`C:/Users/ann/./src/node_modules`, 1000, win, 0, .Windows),
		"dots that stay inside the home on Windows",
	)
	// Windows, and any path judged as another platform, collapses ".." in the
	// text. A Unix host refuses this shape when the component is a real file
	// (reclaim_root_unix_test.odin); this judge does not ask the filesystem.
	testing.expect(
		t,
		root_may_delete(`C:\Users\ann\file\..\proj\node_modules`, 1000, win, 0, .Windows),
		"Windows text cancels .. through a component name",
	)
}

// Cargo's target and CMake's build are candidates only with the file the tool
// writes inside them. A second manifest for a looser rule of the same name, a
// pom.xml or a Gradle file, does not put back a directory that proof was missing
// from. The looser rule still applies when it is the only one whose marker is there.
@(test)
a_stricter_rule_is_not_overruled_by_a_looser_one :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	src := fake_path(&tree, root, "home/ann/src")

	both := project(&tree, src, "both", "Cargo.toml")
	fake_add(&tree, both, "pom.xml", false, 1)
	fake_path(&tree, both, "target/debug")

	proved := project(&tree, src, "proved", "Cargo.toml")
	fake_add(&tree, proved, "pom.xml", false, 1)
	fake_add(&tree, fake_path(&tree, proved, "target"), "CACHEDIR.TAG", false, 1)

	maven := project(&tree, src, "maven", "pom.xml")
	fake_path(&tree, maven, "target")

	cmake := project(&tree, src, "cmake-gradle", "CMakeLists.txt")
	fake_add(&tree, cmake, "build.gradle", false, 1)
	fake_path(&tree, cmake, "build/docs")

	gradle := project(&tree, src, "gradle", "build.gradle")
	fake_path(&tree, gradle, "build")

	ready := project(&tree, src, "ready", "CMakeLists.txt")
	fake_add(&tree, ready, "settings.gradle", false, 1)
	fake_add(&tree, fake_path(&tree, ready, "build"), "CMakeCache.txt", false, 1)

	meson := project(&tree, src, "meson-gradle", "meson.build")
	fake_add(&tree, meson, "build.gradle", false, 1)
	fake_path(&tree, meson, "build")

	found := find(fake_source(&tree), root, "/", ANN, platform = .Unix)
	defer candidates_destroy(found)
	want := []string {
		"/home/ann/src/gradle/build",
		"/home/ann/src/maven/target",
		"/home/ann/src/proved/target",
		"/home/ann/src/ready/build",
	}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
}

// macOS keeps each user's temporary directory under /private/var/folders, which a
// test's fixtures and a person's downloads land in: it is theirs, though the rest
// of /private/var and /var is the system's.
@(test)
a_macs_temporary_directory_is_the_users :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	temp := fake_path(&tree, root, "private/var/folders/xx/abc/T/leita_gui_reclaim")
	make_output(&tree, temp, "web", "package.json", "node_modules")
	make_output(&tree, root, "private/var/db/app", "package.json", "node_modules")
	make_output(&tree, root, "private/etc/app", "package.json", "node_modules")
	make_output(&tree, root, "private/tmp/web", "package.json", "node_modules")
	make_output(&tree, root, "Library/App", "package.json", "node_modules")
	make_output(&tree, root, "Users/runner/Library/web", "package.json", "node_modules")
	runner := home.User{"/Users/runner", "501"}
	found := find(fake_source(&tree), root, "/", runner, platform = .Darwin)
	defer candidates_destroy(found)
	want := []string {
		"/Users/runner/Library/web/node_modules",
		"/private/tmp/web/node_modules",
		"/private/var/folders/xx/abc/T/leita_gui_reclaim/web/node_modules",
	}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)

	// From the fixture itself, by its real path and through the /var link.
	for top in ([]string{"/private/var/folders/xx/abc/T/leita_gui_reclaim", "/var/folders/xx/abc/T/leita_gui_reclaim"}) {
		below := find(fake_source(&tree), temp, top, runner, platform = .Darwin)
		defer candidates_destroy(below)
		testing.expectf(t, len(below) == 1, "%d found from %s", len(below), top)
	}
	db := fake_path(&tree, root, "private/var/db")
	none := find(fake_source(&tree), db, "/private/var/db", runner, platform = .Darwin)
	defer candidates_destroy(none)
	testing.expect_value(t, len(none), 0)
}

// A home is the user's wherever it lies, as Fedora Silverblue keeps it under
// /var/home; the rest of /var, other users' homes there among it, is not. A home
// at the top, as root's is, is the system's.
@(test)
a_home_under_a_system_directory_is_the_users :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	make_output(&tree, root, "var/home/ann/web", "package.json", "node_modules")
	fake_path(&tree, root, "var/home/ann/.cache/pip")
	make_output(&tree, root, "var/home/bob/web", "package.json", "node_modules")
	make_output(&tree, root, "var/lib/app", "package.json", "node_modules")
	make_output(&tree, root, "root/web", "package.json", "node_modules")
	ann := home.User{"/var/home/ann", "1000"}
	found := find(fake_source(&tree), root, "/", ann, platform = .Unix)
	defer candidates_destroy(found)
	want := []string{"/var/home/ann/.cache/pip", "/var/home/ann/web/node_modules"}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)

	as_root := find(fake_source(&tree), root, "/", home.User{"/root", "0"}, platform = .Unix)
	defer candidates_destroy(as_root)
	testing.expect_value(t, len(as_root), 0)
}
