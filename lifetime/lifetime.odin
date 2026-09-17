/*
Lifetime allocator: a debug-build allocator whose report is written for a reader
(human or LLM) who has never seen the program before.

It is a thin layer over `core:debug/trace.Tracking_Allocator`, which already does
the hard parts (leak map, bad-free detection, stats, backtrace capture). This layer
adds what the core allocator lacks:

  1. Phases.  Call `lifetime.set_phase(&la, "scan")` at the boundaries of your
     program's stages. Every allocation remembers the phase it was born in, so a
     leak reads as "allocated during 'scan', still live at exit" instead of a bare
     address.
  2. A grouped report.  Ten thousand leaks from one `make` call become one line:
     count, total bytes, phase, site, and a single representative call chain.
     Groups are sorted by total bytes so the biggest problem is on top.
  3. Noise removal.  Frames inside this package and inside Odin's `base/runtime`
     are dropped, the chain stops at the first frame outside the project and the
     Odin tree (CRT and OS startup code), and paths are shown relative to the
     directory of the file that called `init`. Code that lives outside the project
     directory and outside the Odin root is therefore not shown; keep third-party
     packages under the project.

Usage (debug builds only, compile with `-debug` so backtraces symbolize):

	import "core:debug/trace"
	import "lifetime"

	main :: proc() {
		when ODIN_DEBUG {
			la: lifetime.Allocator
			lifetime.init(&la, context.allocator)
			defer lifetime.destroy(&la)
			defer lifetime.report(&la)
			context.allocator = lifetime.allocator(&la)
			context.assertion_failure_proc = trace.assertion_failure_proc
		}
		run()
	}

Phase names must outlive the allocator. String literals are the intended input.
*/
package lifetime

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

Allocator :: struct {
	track:     trace.Tracking_Allocator,
	// pointer -> phase name active when the allocation was made
	phases:    map[rawptr]string,
	// pointer -> monotonically increasing allocation sequence number
	seqs:      map[rawptr]u64,
	seq:       u64,
	phase:     string,
	mutex:     sync.Mutex,
	// allocator used for this struct's own bookkeeping; never the tracked one
	internals: mem.Allocator,
	// directory of the file that called init; paths under it print relative
	root:      string,
}

init :: proc(la: ^Allocator, backing: mem.Allocator, internals := context.allocator, loc := #caller_location) {
	trace.tracking_allocator_init(&la.track, backing, internals)
	// Record bad frees instead of panicking so the report can show all of them at once.
	la.track.bad_free_callback = trace.tracking_allocator_bad_free_callback_add_to_array
	la.phases.allocator = internals
	la.seqs.allocator = internals
	la.phase = "startup"
	la.internals = internals
	la.root = normalize(filepath.dir(loc.file_path), internals)
}

destroy :: proc(la: ^Allocator) {
	trace.tracking_allocator_destroy(&la.track)
	delete(la.phases)
	delete(la.seqs)
	delete(la.root, la.internals)
	la.phases = {}
	la.seqs = {}
	la.root = ""
}

allocator :: proc(la: ^Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = allocator_proc, data = la}
}

// Mark the start of a program stage. Pass a string literal.
set_phase :: proc(la: ^Allocator, name: string) {
	sync.guard(&la.mutex)
	la.phase = name
}

allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (result: []byte, err: mem.Allocator_Error) {
	la := (^Allocator)(data)
	result, err = trace.tracking_allocator_proc(&la.track, mode, size, alignment, old_memory, old_size, loc)

	sync.guard(&la.mutex)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if err == nil && result != nil {
			la.seq += 1
			p := rawptr(raw_data(result))
			la.phases[p] = la.phase
			la.seqs[p] = la.seq
		}
	case .Free:
		delete_key(&la.phases, old_memory)
		delete_key(&la.seqs, old_memory)
	case .Free_All:
		clear(&la.phases)
		clear(&la.seqs)
	case .Resize, .Resize_Non_Zeroed:
		if err == nil {
			// A resized block keeps the identity of its original allocation.
			phase, had := la.phases[old_memory]
			seq := la.seqs[old_memory]
			if !had {
				phase = la.phase
				la.seq += 1
				seq = la.seq
			}
			delete_key(&la.phases, old_memory)
			delete_key(&la.seqs, old_memory)
			if result != nil {
				p := rawptr(raw_data(result))
				la.phases[p] = phase
				la.seqs[p] = seq
			}
		}
	}
	return
}

@(private)
Group :: struct {
	loc:       runtime.Source_Code_Location,
	phase:     string,
	count:     int,
	bytes:     int,
	min_size:  int,
	max_size:  int,
	first_seq: u64,
	example:   trace.Capture_Const,
}

/*
Print the report to stderr. Safe to call via `defer` after swapping `context.allocator`
to this allocator: the report switches back to the internals allocator so it never
recurses into itself.

Report shape:

	== lifetime report ==
	allocs=111 frees=5 live=106 live_bytes=3544 peak_bytes=3568 bad_frees=1
	LEAK  101 allocs, 3424 b total (sizes 24..1024 b)  phase=scan  site=main.odin:29  proc=main  first_seq=2
	      <- main::main  main.odin:29
	LEAK  5 x 24 b = 120 b  phase=scan  site=main.odin:23  proc=main  first_seq=1
	      <- main::main  main.odin:23
	BAD_FREE  ptr=0x220FC50F648  site=main.odin:35  proc=main
	      <- main::main  main.odin:35
*/
report :: proc(la: ^Allocator, max_groups := 20, max_frames := 8) {
	context.allocator = la.internals
	sync.guard(&la.mutex)
	t := &la.track

	fmt.eprintln("== lifetime report ==")
	fmt.eprintfln(
		"allocs=%d frees=%d live=%d live_bytes=%d peak_bytes=%d bad_frees=%d",
		t.total_allocation_count,
		t.total_free_count,
		len(t.allocation_map),
		t.current_memory_allocated,
		t.peak_memory_allocated,
		len(t.bad_free_array),
	)
	if len(t.allocation_map) == 0 && len(t.bad_free_array) == 0 {
		fmt.eprintln("ok: no leaks, no bad frees")
		return
	}

	groups := make(map[string]Group, la.internals)
	defer delete(groups)

	for ptr, entry in t.allocation_map {
		phase := la.phases[ptr] or_else "unknown"
		key := fmt.tprintf("%s:%d|%s", entry.location.file_path, entry.location.line, phase)
		g, exists := &groups[key]
		if !exists {
			groups[key] = Group{
				loc       = entry.location,
				phase     = phase,
				min_size  = entry.size,
				max_size  = entry.size,
				first_seq = la.seqs[ptr] or_else 0,
				example   = entry.backtrace,
			}
			g = &groups[key]
		}
		g.count += 1
		g.bytes += entry.size
		g.min_size = min(g.min_size, entry.size)
		g.max_size = max(g.max_size, entry.size)
		seq := la.seqs[ptr] or_else 0
		if seq != 0 && (g.first_seq == 0 || seq < g.first_seq) {
			g.first_seq = seq
			g.example = entry.backtrace
		}
	}

	list := make([dynamic]Group, 0, len(groups), la.internals)
	defer delete(list)
	for _, g in groups {
		append(&list, g)
	}
	slice.sort_by(list[:], proc(a, b: Group) -> bool {
		return a.bytes > b.bytes
	})

	for g, i in list {
		if i >= max_groups {
			fmt.eprintfln("... %d more leak groups omitted (raise max_groups to see them)", len(list) - i)
			break
		}
		if g.min_size == g.max_size {
			fmt.eprintf("LEAK  %d x %d b = %d b", g.count, g.min_size, g.bytes)
		} else {
			fmt.eprintf("LEAK  %d allocs, %d b total (sizes %d..%d b)", g.count, g.bytes, g.min_size, g.max_size)
		}
		fmt.eprintfln(
			"  phase=%s  site=%s:%d  proc=%s  first_seq=%d",
			g.phase,
			display_path(la, g.loc.file_path),
			g.loc.line,
			g.loc.procedure,
			g.first_seq,
		)
		print_frames(la, g.example, max_frames)
	}

	for bf in t.bad_free_array {
		fmt.eprintfln(
			"BAD_FREE  ptr=%p  site=%s:%d  proc=%s",
			bf.memory,
			display_path(la, bf.location.file_path),
			bf.location.line,
			bf.location.procedure,
		)
		print_frames(la, bf.backtrace, max_frames)
	}
}

// Directory of this source file, used to drop this package's own frames.
@(private)
SELF_DIR :: #directory

// Frames from Odin's runtime are plumbing between the user's call and this allocator.
@(private)
RUNTIME_DIR :: ODIN_ROOT + "base"

@(private)
print_frames :: proc(la: ^Allocator, bt: trace.Capture_Const, max_frames: int) {
	locs, err := trace.resolve(bt, la.internals, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("      (backtrace unavailable: %s; build with -debug)", trace.resolve_err_string(err))
		return
	}
	defer trace.locations_destroy(locs, la.internals)

	self_dir := normalize(SELF_DIR, context.temp_allocator)
	runtime_dir := normalize(RUNTIME_DIR, context.temp_allocator)
	odin_root := normalize(ODIN_ROOT, context.temp_allocator)

	shown := 0
	for l in locs {
		// Frames with no line number are OS or CRT entry code; nothing useful follows them.
		if l.line == 0 {
			break
		}
		path := normalize(l.file_path, context.temp_allocator)
		if strings.has_prefix(path, self_dir) || strings.has_prefix(path, runtime_dir) {
			continue
		}
		// Anything outside the project and outside Odin's own tree is CRT or OS startup code.
		if !strings.has_prefix(path, la.root) && !strings.has_prefix(path, odin_root) {
			break
		}
		if shown >= max_frames {
			fmt.eprintln("      <- ...")
			break
		}
		fmt.eprintfln("      <- %s  %s:%d", short_proc(l.procedure), display_path(la, l.file_path), l.line)
		shown += 1
	}
}

// Polymorphic procs symbolize with their full signature appended; keep only the name.
@(private)
short_proc :: proc(p: string) -> string {
	if i := strings.index_byte(p, ':'); i >= 0 && i + 1 < len(p) && p[i + 1] == 'p' {
		return p[:i]
	}
	return p
}

@(private)
display_path :: proc(la: ^Allocator, path: string) -> string {
	n := normalize(path, context.temp_allocator)
	if la.root != "" && strings.has_prefix(n, la.root) {
		rest := n[len(la.root):]
		if len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
		return rest
	}
	return n
}

// Lowercase with forward slashes so Windows paths from different sources compare equal.
@(private)
normalize :: proc(path: string, allocator: mem.Allocator) -> string {
	fwd, _ := strings.replace_all(path, "\\", "/", allocator)
	return strings.to_lower(fwd, allocator)
}
