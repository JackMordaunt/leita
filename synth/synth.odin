/*
Package synth is a reader that makes its tree up: the disk of a Mac belonging to
someone who writes software, with not one real file in it. It stands in for walk
where real names must not be shown, a demo or a screenshot, and paces itself like
a walk of a flash disk, so a watched scan fills the way a real one does.

The same day always makes the same tree. A later day has grown what grows on a
real disk, downloads, caches, build output, photos, so two scans a week apart have
a change to show. Every directory's contents follow from a seed made of its
parent's and its own name, so what one directory holds does not depend on how
many entries came before it: a day that adds a file adds only that file.

It is chosen by scan.SYNTHETIC_ENV, which names the day, read once by the
command line and the window and resolved onto the target. Nothing it names is on
disk, so whatever acts on the disk must refuse a synthetic scan's paths.
*/
package synth

import "core:math"
import "core:strings"
import "core:sync"
import "core:time"

import "../scan"

KiB :: f64(1 << 10)
MiB :: f64(1 << 20)
GiB :: f64(1 << 30)

// HOME is the home directory of the disk's made-up owner.
HOME :: "/Users/alex"

Config :: struct {
	day:              int, // which day's disk: a later one has grown
	pace:             bool, // take as long as walking a real disk would
	clock:            Clock, // optional directory-boundary clock; must return when the tree is cancelled
	compare_baseline: bool, // capture-only baseline with a larger AssetsV2 folder
}

// Clock replaces wall-clock sleeping, without changing generated entries.
Clock :: struct {
	wait:    proc(tree: ^scan.Tree, elapsed: time.Duration),
	elapsed: proc() -> time.Duration, // optional display clock for a controlled scan
}

// Set before starting readers, and leave unchanged until they have stopped.
// Capture tools use this to pace config readers by their rendered timeline.
clock_override: Clock

// Set before starting readers, as clock_override is: the capture tool sets it
// from LEITA_SYNTHETIC_COMPARE_BASELINE at startup, for its Compare baseline.
compare_baseline_override: bool

Error :: enum {
	None,
	Out_Of_Memory,
	Cancelled,
}

// config is how a fill reads the made-up disk of day, as scan.resolve gave it on
// the target: at the pace of a walk, by clock_override when one is set, and as
// the larger baseline when compare_baseline_override is.
config :: proc(day: int) -> Config {
	return {
		day = max(day, 0),
		pace = true,
		clock = clock_override,
		compare_baseline = compare_baseline_override,
	}
}

// space is the size of the made-up disk and what is free on it on day.
space :: proc(day: int) -> (total, free: u64) {
	total = 494_384_795_648
	free = u64(max(151e9 - f64(day) * 0.4e9, 1e9))
	return
}

/*
mac_path is path, which scan.path built for the made-up disk, as the Mac it plays
writes it: names joined by "/" and never "\". On Windows scan.path joins a root
called "/" to its names with "\", which leaves "/\Users\alex", and a Reclaim
opened below the top would carry both separators into every path it offered.
Only a Windows host (windows, by default) joins with "\"; elsewhere path is
copied as it is. The copy is the caller's, in allocator.
*/
mac_path :: proc(
	path: string,
	allocator := context.allocator,
	windows := ODIN_OS == .Windows,
) -> string {
	if !windows {
		return strings.clone(path, allocator)
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< len(path) {
		c := path[i]
		if c == '\\' {
			c = '/'
		}
		if c == '/' && strings.has_suffix(strings.to_string(b), "/") {
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// modified is when the directory at path was last changed, as Unix seconds: some
// time in the last 40 days, the same each time it is asked.
modified :: proc(path: string) -> i64 {
	ago := i64(mix(hash_name(path)) % (40 * 24 * 60 * 60))
	return time.time_to_unix(time.now()) - ago
}

/*
read makes the disk under root up into t, a directory at a time, breadth first as
a walk's workers take them. root names the top; what lies under it is the same
whatever it is called.
*/
read :: proc(root: string, t: ^scan.Tree, cfg: Config) -> Error {
	g := Gen {
		tree    = t,
		w       = scan.writer(t, 0),
		cfg     = cfg,
		started = time.tick_now(),
		queue   = make([dynamic]Dir, context.allocator),
	}
	defer delete(g.queue)

	first, err := scan.claim(&g.w, 1)
	if err != nil {
		return .Out_Of_Memory
	}
	n := scan.node(t, first)
	n.parent = first // a root holds itself
	n.name = scan.intern(&g.w, root)
	scan.node_publish(n, {.Used, .Settled, .Directory})
	sync.atomic_store(&t.root, first)
	append(&g.queue, Dir{index = first, seed = ROOT_SEED, kind = .Layout, n = u16(Layout.Root)})

	for head := 0; head < len(g.queue); head += 1 {
		if scan.cancelled(t) {
			return .Cancelled
		}
		g.at = g.queue[head]
		g.nodes, g.bytes = 0, 0
		FILLERS[g.at.kind](&g)
		if g.err != .None {
			return g.err
		}
		scan.progress(t, g.nodes, g.bytes)
		pace(&g)
	}
	return .None
}

@(private)
ROOT_SEED :: 0x50_4E_41_52

// What a directory holds is made by its kind.
@(private)
Kind :: enum u8 {
	File,
	Link,
	Folder, // files and folders after a theme
	Layout, // named entries, from a table
	Apps,
	App,
	Projects,
	Project,
	Node_Modules,
	Package,
	Git,
	Items, // named files, from a list
	Cellar,
	Keg,
}

// A directory found and not yet filled.
@(private)
Dir :: struct {
	index:  u32,
	seed:   u64,
	budget: u64, // the bytes it holds, all told
	kind:   Kind,
	theme:  Theme_Id,
	depth:  u8, // how many folders of its theme lie above it
	n:      u16, // which layout, app, project, list or formula
}

@(private)
Gen :: struct {
	tree:         ^scan.Tree,
	w:            scan.Writer,
	cfg:          Config,
	queue:        [dynamic]Dir,
	at:           Dir, // the directory being filled
	nodes, bytes: u64, // what it holds so far
	err:          Error,
	started:      time.Tick,
	owed:         time.Duration, // how long a real walk would have taken so far
}

@(private)
FILLERS := [Kind]proc(g: ^Gen) {
	.File = proc(g: ^Gen) {},
	.Link = proc(g: ^Gen) {},
	.Folder = fill_folder,
	.Layout = layout,
	.Apps = apps,
	.App = app,
	.Projects = projects,
	.Project = project,
	.Node_Modules = node_modules,
	.Package = package_dir,
	.Git = git,
	.Items = items,
	.Cellar = cellar,
	.Keg = keg,
}

/*
The time a walk of a flash disk takes: a cost for each directory opened and each
entry read, varied by directory, as some are cold and some cached. It sleeps once
it is more than 2 ms ahead of that, so the tree fills at a walk's pace rather than
in bursts.
*/
@(private)
DIR_COST :: 70 * time.Microsecond
@(private)
ENTRY_COST :: 9 * time.Microsecond

@(private)
pace :: proc(g: ^Gen) {
	if !g.cfg.pace && g.cfg.clock.wait == nil {
		return
	}
	r := Rng{g.at.seed ~ 0xA5A5_A5A5}
	cost := f64(DIR_COST + time.Duration(g.nodes) * ENTRY_COST) * (0.3 + 1.4 * unit(&r))
	g.owed += time.Duration(cost)
	if g.cfg.clock.wait != nil {
		g.cfg.clock.wait(g.tree, g.owed)
		return
	}
	ahead := g.owed - time.tick_since(g.started)
	if ahead > 2 * time.Millisecond {
		time.sleep(ahead)
	}
}

// --- entries -------------------------------------------------------------------

// add records an entry in the directory being filled.
@(private)
add :: proc(g: ^Gen, name: string, flags: scan.Node_Flags, disk: u64) -> (index: u32, ok: bool) {
	slot, err := scan.claim(&g.w, 1)
	if err != nil {
		g.err = .Out_Of_Memory
		return 0, false
	}
	n := scan.node(g.tree, slot)
	n.parent = g.at.index
	n.name = scan.intern(&g.w, name)
	n.disk = disk
	// Last, so a builder watching the tree never sees a node before its size.
	scan.node_publish(n, flags | {.Used, .Settled})
	g.nodes += 1
	g.bytes += disk
	return slot, true
}

// add_file records a file of about bytes, as the 4 KiB blocks it takes.
@(private)
add_file :: proc(g: ^Gen, name: string, bytes: f64) {
	add(g, name, {}, blocks(bytes))
}

@(private)
blocks :: proc(bytes: f64) -> u64 {
	if bytes <= 0 {
		return 0
	}
	return u64(math.ceil(bytes / 4096)) * 4096
}

// add_dir records a directory and queues it to be filled as kind, with bytes in all.
@(private)
add_dir :: proc(
	g: ^Gen,
	name: string,
	kind: Kind,
	bytes: f64,
	theme := Theme_Id.Same,
	n: u16 = 0,
	depth: u8 = 0,
) {
	index, ok := add(g, name, {.Directory}, 0)
	if !ok {
		return
	}
	append(
		&g.queue,
		Dir {
			index = index,
			seed = mix(g.at.seed ~ hash_name(name)),
			budget = u64(max(bytes, 0)),
			kind = kind,
			theme = theme,
			depth = depth,
			n = n,
		},
	)
}

/*
descend records the directories path passes through, under the one being filled,
and makes the last of them the one being filled; it returns the name left at the
end of path. Those directories hold only what follows, so they are never queued.
*/
@(private)
descend :: proc(g: ^Gen, path: string) -> (leaf: string, ok: bool) {
	leaf = path
	for {
		slash := strings.index_byte(leaf, '/')
		if slash < 0 {
			return leaf, true
		}
		g.at.index = add(g, leaf[:slash], {.Directory}, 0) or_return
		leaf = leaf[slash + 1:]
	}
}

// put records a file at path under the directory being filled.
@(private)
put :: proc(g: ^Gen, path: string, bytes: f64) {
	parent := g.at.index
	defer g.at.index = parent
	if leaf, ok := descend(g, path); ok {
		add_file(g, leaf, bytes)
	}
}

// --- folders after a theme -----------------------------------------------------

/*
fill_folder fills a directory after its theme: a share of its bytes in files of the
theme's sizes, the rest in subfolders, until the theme's depth, below which it
holds files alone.
*/
@(private)
fill_folder :: proc(g: ^Gen) {
	th := THEMES[g.at.theme]
	r := Rng{g.at.seed}
	budget := f64(g.at.budget)
	kept := budget
	if int(g.at.depth) < th.depth && th.subs[1] > 0 && budget > th.typical * 150 {
		kept = budget * (th.share[0] + (th.share[1] - th.share[0]) * unit(&r))
		add_subfolders(g, &r, th, budget - kept)
	}
	add_files(g, th, kept)
}

@(private)
add_subfolders :: proc(g: ^Gen, r: ^Rng, th: ^Theme, bytes: f64) {
	weights: [64]f64
	count := th.subs[0] + int(next(r) % u64(th.subs[1] - th.subs[0] + 1))
	count = min(count, len(weights))
	total: f64
	for i in 0 ..< count {
		weights[i] = spread(r, 0.9)
		total += weights[i]
	}
	child := th.child if th.child != .Same else g.at.theme
	start := int(next(r) % 997)
	buf: [192]u8
	for i in 0 ..< count {
		name := entry_name(buf[:], th.folder_style, th.folders, start, i, r, th.folder_ext)
		add_dir(g, name, .Folder, bytes * weights[i] / total, child, depth = g.at.depth + 1)
	}
}

// add_files records bytes in files after th, each its own seed, so a folder that
// grows keeps the files it had and adds more after them.
@(private)
add_files :: proc(g: ^Gen, th: ^Theme, bytes: f64) {
	if bytes <= 0 || th.most == 0 {
		return
	}
	count := clamp(int(bytes / th.typical), 1, th.most)
	total: f64
	for i in 0 ..< count {
		r := Rng{mix(g.at.seed + u64(i))}
		total += spread(&r, th.sigma)
	}
	start := int(mix(g.at.seed) % 997)
	buf: [192]u8
	for i in 0 ..< count {
		r := Rng{mix(g.at.seed + u64(i))}
		share := spread(&r, th.sigma) / total
		ext := th.exts[next(&r) % u64(len(th.exts))] if len(th.exts) > 0 else ""
		add_file(g, entry_name(buf[:], th.style, th.words, start, i, &r, ext), bytes * share)
	}
}

// --- names ---------------------------------------------------------------------

@(private)
Style :: enum u8 {
	Words, // a word from the list, then "word 2" once they run out
	Track, // "07 word"
	Crate, // "libword-<16 hex>"
	Hex, // 16 hex digits
	Hex2, // two hex digits, as git's objects are kept
	Digit, // one hex digit, as the Photos library's originals are kept
	Uuid,
	Part, // "043-18670-100", as Apple names an asset
	Screenshot,
}

/*
entry_name is the i-th name of a folder's entries in style, with ext after a dot
when there is one. A list of words is entered at start, a seeded place, so two
folders of a theme do not begin alike; no two of a folder's names are the same.

A scan makes one name for each of the disk's files, so they are written a piece
at a time into buf rather than by fmt. Under AddressSanitizer fmt.bprintf here
was 53% of a debug scan's CPU time, 5.5 s of it, by perf record on 2026-10-25;
written this way the names take 7% of 2.9 s.
*/
@(private)
entry_name :: proc(
	buf: []u8,
	style: Style,
	words: []string,
	start, i: int,
	r: ^Rng,
	ext: string,
) -> string {
	#partial switch style {
	case .Track:
		n := Name{buf = buf}
		write_number(&n, u64(i + 1), 10, 2)
		write(&n, " ")
		write(&n, words[(start + i) % len(words)])
		return write_ext(&n, ext)
	case .Words, .Crate:
		return word_name(buf, style, words[(start + i) % len(words)], i / len(words), r, ext)
	}
	return made_name(buf, style, start, i, r, ext)
}

// word_name is a name made of word, on its round-th time through the list.
@(private)
word_name :: proc(
	buf: []u8,
	style: Style,
	word: string,
	round: int,
	r: ^Rng,
	ext: string,
) -> string {
	n := Name{buf = buf}
	#partial switch style {
	case .Crate:
		write(&n, "lib")
		write(&n, word)
		write(&n, "-")
		write_number(&n, next(r), 16, 16)
		return write_ext(&n, ext)
	}
	write(&n, word)
	if round != 0 {
		write(&n, " ")
		write_number(&n, u64(round + 1), 10, 1)
	}
	return write_ext(&n, ext)
}

@(private)
made_name :: proc(buf: []u8, style: Style, start, i: int, r: ^Rng, ext: string) -> string {
	n := Name{buf = buf}
	a, b := next(r), next(r)
	#partial switch style {
	case .Hex2:
		write_number(&n, u64((start + i) % 256), 16, 2)
	case .Digit:
		write_number(&n, u64(i % 16), 16, 1, upper = true)
	case .Uuid:
		write_number(&n, u64(u32(a >> 32)), 16, 8, upper = true)
		write(&n, "-")
		write_number(&n, u64(u16(a >> 16)), 16, 4, upper = true)
		write(&n, "-")
		write_number(&n, u64(u16(a)), 16, 4, upper = true)
		write(&n, "-")
		write_number(&n, u64(u16(b >> 48)), 16, 4, upper = true)
		write(&n, "-")
		write_number(&n, b & 0xFFFF_FFFF_FFFF, 16, 12, upper = true)
	case .Part:
		write_number(&n, a % 100, 10, 3)
		write(&n, "-")
		write_number(&n, b % 100_000, 10, 5)
		write(&n, "-")
		write_number(&n, u64(i % 1000), 10, 3)
	case .Screenshot:
		write(&n, "Screenshot 2026-")
		write_number(&n, a % 9 + 1, 10, 2)
		write(&n, "-")
		write_number(&n, a / 9 % 28 + 1, 10, 2)
		write(&n, " at ")
		write_number(&n, b % 24, 10, 2)
		write(&n, ".")
		write_number(&n, b / 24 % 60, 10, 2)
		write(&n, ".")
		write_number(&n, u64(i % 60), 10, 2)
	case:
		write_number(&n, a, 16, 16)
	}
	return write_ext(&n, ext)
}

// Name is a name being written into buf. What does not fit is left off, as
// fmt.bprintf leaves it.
@(private)
Name :: struct {
	buf: []u8,
	len: int,
}

@(private)
write :: proc(n: ^Name, s: string) {
	n.len += copy(n.buf[n.len:], s)
}

// write_number writes v in base 10 or 16, in at least width digits, as %0*d,
// %0*x or %0*X does.
@(private)
write_number :: proc(n: ^Name, v: u64, base: u64, width: int, upper := false) {
	set: string = "0123456789ABCDEF" if upper else "0123456789abcdef"
	digits: [20]u8
	at := len(digits)
	for v := v; at == len(digits) || v > 0; v /= base {
		at -= 1
		digits[at] = set[v % base]
	}

	for len(digits) - at < width {
		at -= 1
		digits[at] = '0'
	}
	n.len += copy(n.buf[n.len:], digits[at:])
}

// write_ext ends the name with a dot and ext when there is an ext, and is the name.
@(private)
write_ext :: proc(n: ^Name, ext: string) -> string {
	if ext != "" {
		write(n, ".")
		write(n, ext)
	}
	return string(n.buf[:n.len])
}

// --- randomness ----------------------------------------------------------------

// Rng is splitmix64: small, fast, and the same everywhere.
@(private)
Rng :: struct {
	s: u64,
}

@(private)
mix :: proc(x: u64) -> u64 {
	z := x
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

@(private)
next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E37_79B9_7F4A_7C15
	return mix(r.s)
}

// unit is a number in [0, 1).
@(private)
unit :: proc(r: ^Rng) -> f64 {
	return f64(next(r) >> 11) / f64(u64(1) << 53)
}

// spread is a weight around 1, log-normal with sigma, as file sizes are.
@(private)
spread :: proc(r: ^Rng, sigma: f64) -> f64 {
	u1 := max(unit(r), 1e-12)
	u2 := unit(r)
	z := math.sqrt(-2 * math.ln(u1)) * math.cos(2 * math.PI * u2)
	return math.exp(sigma * clamp(z, -3, 3))
}

// hash_name is FNV-1a.
@(private)
hash_name :: proc(s: string) -> u64 {
	h: u64 = 0xcbf2_9ce4_8422_2325
	for b in transmute([]u8)s {
		h = (h ~ u64(b)) * 0x100_0000_01b3
	}
	return h
}
