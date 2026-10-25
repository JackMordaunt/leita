package synth

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import "../scan"

// A path of the made-up disk on a Windows host, built with \ under a root called /,
// is the Mac's with / alone; on any other host it is left as it is.
@(test)
the_made_up_disks_paths_use_only_slashes :: proc(t: ^testing.T) {
	want := "/Users/alex/Library/Caches"
	mixed := mac_path(`/\Users\alex\Library\Caches`, context.temp_allocator, true)
	testing.expect_value(t, mixed, want)
	testing.expect_value(t, mac_path(want, context.temp_allocator, true), want)
	testing.expect_value(t, mac_path(`\Users\alex`, context.temp_allocator, true), "/Users/alex")
	testing.expect_value(t, mac_path("/", context.temp_allocator, true), "/")
	testing.expect_value(t, mac_path(`/a\b`, context.temp_allocator, false), `/a\b`)
}

// Made_Up_Disk is what a test reads off a made-up tree.
@(private = "file")
Made_Up_Disk :: struct {
	tree:  scan.Tree,
	nodes: u32,
	bytes: u64,
}

@(private = "file")
make_up :: proc(t: ^testing.T, m: ^Made_Up_Disk, day: int) -> bool {
	testing.expect(t, scan.tree_init(&m.tree) == nil) or_return
	err := read("/", &m.tree, {day = day})
	testing.expect_value(t, err, Error.None) or_return
	m.nodes = m.tree.count
	for i in 0 ..< m.nodes {
		m.bytes += scan.node(&m.tree, i).disk
	}
	return true
}

// child is the node named name directly under dir, or false.
@(private = "file")
child :: proc(tr: ^scan.Tree, dir: u32, name: string) -> (u32, bool) {
	for i in 0 ..< tr.count {
		if i != dir && scan.node(tr, i).parent == dir && scan.name_of(tr, i) == name {
			return i, true
		}
	}
	return 0, false
}

@(private = "file")
find :: proc(tr: ^scan.Tree, path: string) -> (node: u32, ok: bool) {
	node = tr.root
	for part in strings.split(path, "/", context.temp_allocator) {
		node = child(tr, node, part) or_return
	}
	return node, true
}

@(test)
a_disk_looks_like_a_mac :: proc(t: ^testing.T) {
	m: Made_Up_Disk
	defer scan.tree_destroy(&m.tree)
	if !make_up(t, &m, 30) {
		return
	}

	for top in ([]string{"Applications", "System", "Library", "Users", "opt", "private", "usr"}) {
		_, found := child(&m.tree, m.tree.root, top)
		testing.expectf(t, found, "/%s is there", top)
	}
	gib := f64(m.bytes) / GiB
	testing.expectf(t, gib > 200 && gib < 360, "%.1f GiB is a well-used disk", gib)
	testing.expectf(t, m.nodes > 300_000 && m.nodes < 3_000_000, "%d entries", m.nodes)
	total, free := space(30)
	testing.expect(t, free < total && m.bytes < total - free)
}

@(test)
the_same_day_makes_the_same_disk :: proc(t: ^testing.T) {
	a, b: Made_Up_Disk
	defer scan.tree_destroy(&a.tree)
	defer scan.tree_destroy(&b.tree)
	if !make_up(t, &a, 12) {
		return
	}
	if !make_up(t, &b, 12) {
		return
	}
	testing.expect_value(t, b.nodes, a.nodes)
	testing.expect_value(t, b.bytes, a.bytes)
}

// A week later the disk holds everything it held, and more: what grows has grown,
// and nothing that does not grow has changed.
@(test)
a_later_day_has_grown :: proc(t: ^testing.T) {
	before, after: Made_Up_Disk
	defer scan.tree_destroy(&before.tree)
	defer scan.tree_destroy(&after.tree)
	if !make_up(t, &before, 30) {
		return
	}
	if !make_up(t, &after, 37) {
		return
	}
	testing.expect(t, after.bytes > before.bytes)

	was, _ := find(&before.tree, "Users/alex/Downloads")
	now, _ := find(&after.tree, "Users/alex/Downloads")
	for i in 0 ..< before.tree.count {
		if scan.node(&before.tree, i).parent == was && i != was {
			_, kept := child(&after.tree, now, scan.name_of(&before.tree, i))
			testing.expectf(t, kept, "%s is still downloaded", scan.name_of(&before.tree, i))
		}
	}
	dock, _ := find(&before.tree, "Applications/Xcode.app/Contents/Info.plist")
	dock_later, _ := find(&after.tree, "Applications/Xcode.app/Contents/Info.plist")
	testing.expect_value(
		t,
		scan.node(&after.tree, dock_later).disk,
		scan.node(&before.tree, dock).disk,
	)
}

@(test)
no_directory_holds_a_name_twice :: proc(t: ^testing.T) {
	m: Made_Up_Disk
	defer scan.tree_destroy(&m.tree)
	if !make_up(t, &m, 0) {
		return
	}
	seen := make(map[string]bool, int(m.nodes))
	defer delete(seen)
	for i in 0 ..< m.nodes {
		key := fmt.tprintf("%d/%s", scan.node(&m.tree, i).parent, scan.name_of(&m.tree, i))
		if !testing.expectf(
			t,
			!seen[key],
			"%s twice",
			scan.path(&m.tree, i, context.temp_allocator),
		) {
			return
		}
		seen[strings.clone(key, context.temp_allocator)] = true
	}
}

// What Reclaim offers needs its proof beside it: a node_modules its package.json,
// a target its Cargo.toml, a .venv its pyproject.toml.
@(test)
build_output_sits_beside_its_manifest :: proc(t: ^testing.T) {
	m: Made_Up_Disk
	defer scan.tree_destroy(&m.tree)
	if !make_up(t, &m, 0) {
		return
	}
	pairs := [?][2]string {
		{"Users/alex/Source/atlas-web/node_modules", "Users/alex/Source/atlas-web/package.json"},
		{"Users/alex/Source/quill/target", "Users/alex/Source/quill/Cargo.toml"},
		{"Users/alex/Source/tidepool/.venv", "Users/alex/Source/tidepool/pyproject.toml"},
	}
	for p in pairs {
		_, made := find(&m.tree, p[0])
		_, proof := find(&m.tree, p[1])
		testing.expectf(t, made && proof, "%s beside %s", p[0], p[1])
	}
}

@(test)
a_cancelled_scan_stops :: proc(t: ^testing.T) {
	tr: scan.Tree
	if !testing.expect(t, scan.tree_init(&tr) == nil) {
		return
	}
	defer scan.tree_destroy(&tr)
	scan.cancel(&tr)
	testing.expect_value(t, read("/", &tr, {}), Error.Cancelled)
}

@(test)
a_clock_preserves_generated_entries :: proc(t: ^testing.T) {
	plain, clocked: scan.Tree
	if !testing.expect(t, scan.tree_init(&plain) == nil) {return}
	defer scan.tree_destroy(&plain)
	if !testing.expect(t, scan.tree_init(&clocked) == nil) {return}
	defer scan.tree_destroy(&clocked)
	testing.expect_value(t, read("/", &plain, {day = 7}), Error.None)
	testing.expect_value(
		t,
		read("/", &clocked, {day = 7, clock = {wait = proc(_: ^scan.Tree, _: time.Duration) {}}}),
		Error.None,
	)
	testing.expect(t, plain.count > 300_000)
	file, found := find(&plain, "private/var/vm/sleepimage")
	if !testing.expect(t, found) {return}
	testing.expect_value(t, scan.name_of(&plain, file), "sleepimage")
	testing.expect_value(t, scan.node(&plain, file).disk, u64(1 << 30))
	testing.expect_value(t, clocked.count, plain.count)
	for i in 0 ..< plain.count {
		testing.expect_value(t, scan.node(&clocked, i).disk, scan.node(&plain, i).disk)
		testing.expect_value(t, scan.name_of(&clocked, i), scan.name_of(&plain, i))
	}
}

// Names are written without fmt, and each is the one fmt.bprintf wrote for it
// before: the same day's disk keeps the names it had.
@(test)
names_are_those_fmt_wrote :: proc(t: ^testing.T) {
	words := []string{"notes", "Écrits", "a"}
	exts := []string{"", "txt", "photoslibrary"}
	got_buf, want_buf: [192]u8
	for style in Style {
		for i in 0 ..< 1100 {
			for ext in exts {
				seed := mix(u64(i) * 31 + u64(style))
				start := int(seed % 997)
				r1, r2 := Rng{seed}, Rng{seed}
				got := entry_name(got_buf[:], style, words, start, i, &r1, ext)
				want := name_by_fmt(want_buf[:], style, words, start, i, &r2, ext)
				if !testing.expectf(t, got == want, "%v %d %q: %q, want %q", style, i, ext, got, want) {
					return
				}
				testing.expect_value(t, r1.s, r2.s)
			}
		}
	}
	// What does not fit the buffer is left off, as fmt.bprintf leaves it.
	small: [6]u8
	r1, r2 := Rng{7}, Rng{7}
	testing.expect_value(
		t,
		entry_name(small[:], .Crate, words, 0, 0, &r1, "txt"),
		name_by_fmt(want_buf[:6], .Crate, words, 0, 0, &r2, "txt"),
	)
}

// name_by_fmt is entry_name as it was written with fmt.bprintf.
@(private = "file")
name_by_fmt :: proc(
	buf: []u8,
	style: Style,
	words: []string,
	start, i: int,
	r: ^Rng,
	ext: string,
) -> string {
	dot := "." if ext != "" else ""
	#partial switch style {
	case .Track:
		return fmt.bprintf(buf, "%02d %s%s%s", i + 1, words[(start + i) % len(words)], dot, ext)
	case .Words, .Crate:
		word, round := words[(start + i) % len(words)], i / len(words)
		if style == .Crate {
			return fmt.bprintf(buf, "lib%s-%016x%s%s", word, next(r), dot, ext)
		}
		if round == 0 {
			return fmt.bprintf(buf, "%s%s%s", word, dot, ext)
		}
		return fmt.bprintf(buf, "%s %d%s%s", word, round + 1, dot, ext)
	}
	a, b := next(r), next(r)
	#partial switch style {
	case .Hex2:
		return fmt.bprintf(buf, "%02x%s%s", (start + i) % 256, dot, ext)
	case .Digit:
		return fmt.bprintf(buf, "%X%s%s", i % 16, dot, ext)
	case .Uuid:
		return fmt.bprintf(
			buf,
			"%08X-%04X-%04X-%04X-%012X%s%s",
			u32(a >> 32),
			u16(a >> 16),
			u16(a),
			u16(b >> 48),
			b & 0xFFFF_FFFF_FFFF,
			dot,
			ext,
		)
	case .Part:
		return fmt.bprintf(buf, "%03d-%05d-%03d%s%s", a % 100, b % 100_000, i % 1000, dot, ext)
	case .Screenshot:
		return fmt.bprintf(
			buf,
			"Screenshot 2026-%02d-%02d at %02d.%02d.%02d%s%s",
			a % 9 + 1,
			a / 9 % 28 + 1,
			b % 24,
			b / 24 % 60,
			i % 60,
			dot,
			ext,
		)
	}
	return fmt.bprintf(buf, "%016x%s%s", a, dot, ext)
}
