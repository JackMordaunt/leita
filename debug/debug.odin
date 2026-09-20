/*
Debug allocator: finds allocation bugs and reports them so that a reader with no
context, human or AI agent, can locate and fix them from the output alone.

What it detects, and when:

  OVERFLOW / UNDERFLOW   guard bytes around every block are checked on free, on
                         resize, at every phase change, at every checkpoint, and at
                         exit. The report says how many bytes past which end were
                         clobbered and what was written there.
  DOUBLE_FREE            freed blocks sit in a quarantine instead of returning to the
                         backing allocator, so a second free is recognised and both
                         free sites are reported.
  WRITE_AFTER_FREE       freed memory is poisoned; when a block leaves quarantine, at
                         a phase change, at a checkpoint, or at exit, the poison is
                         verified.
  BAD_FREE / BAD_RESIZE  the pointer was never handed out by this allocator.
  SIZE_MISMATCH          delete() called with a length that differs from the one
                         allocated, the usual sign of a re-sliced slice.
  stale after resize     a resize always moves the block; the old address is
                         quarantined and poisoned, so a pointer kept across an append
                         surfaces as WRITE_AFTER_FREE or DOUBLE_FREE naming the resize.
  LEAK                   blocks still live at exit, grouped by allocation site.

Every issue is printed in full the moment it is detected, because a corrupted heap
may crash the program before any exit report. The exit report indexes the issues,
lists leak groups, and prints per-site lifetime statistics: how many allocations a
site made, how long they lived (in allocation ticks, so the number is the same from
run to run), and whether they died in the phase they were born in.

Fresh non-zeroed memory is filled with 0xCD, freed memory with 0xDD, and guards with
0xFD. Seeing 0xCDCDCDCD or 0xDDDDDDDD in a value tells you which kind of bug you are
looking at.

With -sanitize:address the allocator also poisons its guards and every freed block
through base:sanitizer, so an instrumented read or write into them traps at the
faulting instruction instead of being noticed at the next check. That closes the gap
a pure allocator has: reads past the end and reads after free. On Windows this is the
only way ASan sees Odin heap blocks at all, because the default allocator uses
HeapAlloc rather than the libc malloc that ASan intercepts. When ASan reports, a
death callback appends which block the address belongs to, where it was allocated,
and where it was freed, since ASan itself only knows the address is poisoned.

Usage (debug builds only, compile with -debug so call chains symbolize):

	import "core:debug/trace"
	import "debug"

	main :: proc() {
		when ODIN_DEBUG {
			da: debug.Allocator
			debug.init(&da, context.allocator)
			defer debug.destroy(&da)
			defer debug.report(&da)
			context.allocator = debug.allocator(&da)
			context.assertion_failure_proc = trace.assertion_failure_proc
		}
		run()
	}

	debug.set_phase(&da, "scan")     // label program stages; each change is a checkpoint
	debug.check(&da)                 // verify every live and quarantined block right now

Compile-time knobs:

	-define:DEBUG_ALLOC_FAIL_FAST=true     panic at the first issue, after printing it
	-define:DEBUG_ALLOC_QUARANTINE=<bytes> freed memory held back (default 16 MiB)
	-define:DEBUG_ALLOC_GUARD=<bytes>      guard size each side of a block (default 16)
	-define:DEBUG_ALLOC_BACKTRACES=false   skip call-chain capture in allocation-heavy programs

Phase names must outlive the allocator; pass string literals.
*/
package debug

import "base:runtime"
import "base:sanitizer"
import "core:debug/trace"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

GUARD            :: #config(DEBUG_ALLOC_GUARD, 16)
QUARANTINE_BYTES :: #config(DEBUG_ALLOC_QUARANTINE, 16 * 1024 * 1024)
FAIL_FAST        :: #config(DEBUG_ALLOC_FAIL_FAST, false)
BACKTRACES       :: #config(DEBUG_ALLOC_BACKTRACES, true)

// True when the program was built with -sanitize:address.
ASAN :: .Address in ODIN_SANITIZER_FLAGS

PATTERN_GUARD :: 0xFD
PATTERN_DEAD  :: 0xDD
PATTERN_FRESH :: 0xCD

#assert(
	GUARD >= 8 && (GUARD & (GUARD - 1)) == 0,
	"DEBUG_ALLOC_GUARD must be a power of two of at least 8",
)

Issue_Kind :: enum {
	Overflow,
	Underflow,
	Double_Free,
	Write_After_Free,
	Bad_Free,
	Bad_Resize,
	Size_Mismatch,
}

// Where and when something happened to a block.
Site :: struct {
	loc:   runtime.Source_Code_Location,
	phase: string,
	seq:   u64, // allocation tick at the time
	bt:    trace.Capture_Const,
}

@(private)
Live :: struct {
	raw:         rawptr, // start of the front guard
	total:       int, // front + size + GUARD
	front:       int, // front guard size; at least GUARD, grows to satisfy alignment
	size:        int,
	alignment:   int,
	alloc:       Site,
	resizes:     int,
	last_resize: runtime.Source_Code_Location,
}

@(private)
Dead :: struct {
	raw:       rawptr,
	total:     int,
	front:     int,
	size:      int,
	alloc:     Site,
	free:      Site,
	by_resize: bool, // freed because a resize moved the block
}

Corruption :: struct {
	offset: int, // first bad byte relative to the start of the user block; negative for underflow
	count:  int,
	sample: [8]byte,
}

Issue :: struct {
	id:             int,
	kind:           Issue_Kind,
	ptr:            rawptr,
	size:           int,
	alloc:          Site,
	has_alloc:      bool,
	first_free:     Site,
	has_first_free: bool,
	by_resize:      bool,
	op:             Site, // the operation during which the issue was detected
	stage:          string, // "free", "resize", "phase change", "checkpoint", "quarantine", "exit"
	corruption:     Corruption,
	given_size:     int, // Size_Mismatch
}

@(private)
Site_Key :: struct {
	file: string,
	line: i32,
}

Site_Stats :: struct {
	loc:             runtime.Source_Code_Location,
	allocs:          int,
	frees:           int,
	resizes:         int,
	bytes:           int, // total bytes ever allocated here
	live:            int,
	live_bytes:      int,
	peak_live_bytes: int,
	lifetime_min:    u64,
	lifetime_max:    u64,
	lifetime_sum:    u64,
	cross_phase:     int, // frees that happened in a different phase than the allocation
	last_death:      string, // phase of the most recent free
}

Allocator :: struct {
	backing:      mem.Allocator,
	internals:    mem.Allocator, // bookkeeping; never the tracked allocator itself
	live:         map[rawptr]Live,
	dead:         map[rawptr]Dead,
	dead_queue:   [dynamic]rawptr, // FIFO for quarantine eviction
	dead_head:    int,
	dead_bytes:   int,
	sites:        map[Site_Key]Site_Stats,
	issues:       [dynamic]Issue,
	phases:       [dynamic]string,
	phase:        string,
	seq:          u64,
	total_allocs: int,
	total_frees:  int,
	live_bytes:   int,
	peak_bytes:   int,
	fail_fast:    bool,
	mutex:        sync.Mutex,
	root:         string, // directory of the file that called init; paths print relative to it
}

init :: proc(
	da: ^Allocator,
	backing: mem.Allocator,
	internals := context.allocator,
	loc := #caller_location,
) {
	da.backing = backing
	da.internals = internals
	da.live.allocator = internals
	da.dead.allocator = internals
	da.dead_queue.allocator = internals
	da.sites.allocator = internals
	da.issues.allocator = internals
	da.phases.allocator = internals
	da.phase = "startup"
	append(&da.phases, da.phase)
	da.fail_fast = FAIL_FAST
	da.root = normalize(filepath.dir(loc.file_path), internals)
	when ASAN {
		asan_owner = da
		sanitizer.address_set_death_callback(asan_death)
	}
}

// Release everything, including blocks the program never freed. Call report first.
destroy :: proc(da: ^Allocator) {
	sync.guard(&da.mutex)
	for _, l in da.live {
		backing_free(da, l.raw, l.total)
	}
	for _, d in da.dead {
		backing_free(da, d.raw, d.total)
	}
	when ASAN {
		if asan_owner == da {
			asan_owner = nil
		}
	}
	delete(da.live)
	delete(da.dead)
	delete(da.dead_queue)
	delete(da.sites)
	delete(da.issues)
	delete(da.phases)
	delete(da.root, da.internals)
	da^ = {}
}

allocator :: proc(da: ^Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = allocator_proc, data = da}
}

// Mark the start of a program stage. Every live and quarantined block is verified
// first, so corruption is pinned to the stage it happened in. Pass a string literal.
set_phase :: proc(da: ^Allocator, name: string, loc := #caller_location) {
	context.allocator = da.internals
	sync.guard(&da.mutex)
	verify_all(da, "phase change", loc)
	da.phase = name
	append(&da.phases, name)
}

// Verify every live and quarantined block right now. Sprinkle calls to narrow down
// where a corruption happens.
check :: proc(da: ^Allocator, loc := #caller_location) {
	context.allocator = da.internals
	sync.guard(&da.mutex)
	verify_all(da, "checkpoint", loc)
}

issue_count :: proc(da: ^Allocator) -> int {
	sync.guard(&da.mutex)
	return len(da.issues)
}

// ---- allocator ------------------------------------------------------------------

allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	result: []byte,
	err: mem.Allocator_Error,
) {
	da := (^Allocator)(data)
	// Anything this allocator does internally must not come back through itself.
	context.allocator = da.internals
	sync.guard(&da.mutex)

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return do_alloc(da, size, alignment, mode == .Alloc, loc)
	case .Free:
		return nil, do_free(da, old_memory, old_size, loc)
	case .Free_All:
		do_free_all(da, loc)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		return do_resize(da, old_memory, old_size, size, alignment, mode == .Resize, loc)
	case .Query_Features:
		if set := (^mem.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {
				.Alloc,
				.Alloc_Non_Zeroed,
				.Free,
				.Free_All,
				.Resize,
				.Resize_Non_Zeroed,
				.Query_Features,
			}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

// Obtain a guarded block from the backing allocator. No bookkeeping.
@(private)
raw_alloc :: proc(
	da: ^Allocator,
	size, alignment: int,
	zeroed: bool,
	loc: runtime.Source_Code_Location,
) -> (
	l: Live,
	user: []byte,
	err: mem.Allocator_Error,
) {
	if size < 0 {
		return {}, nil, .Invalid_Argument
	}
	align := max(alignment, 1)
	// The front guard doubles as alignment padding: the backing block is aligned to
	// max(align, GUARD) and the user block starts `front` bytes in, where `front` is a
	// multiple of `align`.
	front := max(GUARD, align)
	total := front + size + GUARD
	raw, alloc_err := mem.alloc_bytes_non_zeroed(total, max(align, GUARD), da.backing, loc)
	if alloc_err != nil {
		return {}, nil, alloc_err
	}
	mem.set(raw_data(raw), PATTERN_GUARD, front)
	user = raw[front:front + size]
	mem.set(raw_data(raw[front + size:]), PATTERN_GUARD, GUARD)
	if zeroed {
		mem.zero_slice(user)
	} else {
		mem.set(raw_data(user), PATTERN_FRESH, size)
	}
	sanitizer.address_poison(raw[:front])
	sanitizer.address_poison(raw[front + size:])
	l = Live {
		raw       = raw_data(raw),
		total     = total,
		front     = front,
		size      = size,
		alignment = align,
	}
	return l, user, nil
}

@(private)
do_alloc :: proc(
	da: ^Allocator,
	size, alignment: int,
	zeroed: bool,
	loc: runtime.Source_Code_Location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	l, user, alloc_err := raw_alloc(da, size, alignment, zeroed, loc)
	if alloc_err != nil {
		return nil, alloc_err
	}
	da.seq += 1
	l.alloc = make_site(da, loc)
	da.live[raw_data(user)] = l
	da.total_allocs += 1
	da.live_bytes += size
	da.peak_bytes = max(da.peak_bytes, da.live_bytes)

	st := site_stats(da, loc)
	st.allocs += 1
	st.bytes += size
	st.live += 1
	st.live_bytes += size
	st.peak_live_bytes = max(st.peak_live_bytes, st.live_bytes)
	return user, nil
}

@(private)
do_free :: proc(
	da: ^Allocator,
	ptr: rawptr,
	given_size: int,
	loc: runtime.Source_Code_Location,
) -> mem.Allocator_Error {
	if ptr == nil {
		return nil
	}
	l, ok := da.live[ptr]
	if !ok {
		op := make_site(da, loc)
		if d, dead_ok := da.dead[ptr]; dead_ok {
			raise(
				da,
				Issue {
					kind = .Double_Free,
					ptr = ptr,
					size = d.size,
					alloc = d.alloc,
					has_alloc = true,
					first_free = d.free,
					has_first_free = true,
					by_resize = d.by_resize,
					op = op,
					stage = "free",
				},
			)
		} else {
			raise(da, Issue{kind = .Bad_Free, ptr = ptr, op = op, stage = "free"})
		}
		return .Invalid_Pointer
	}
	if given_size != 0 && given_size != l.size {
		raise(
			da,
			Issue {
				kind = .Size_Mismatch,
				ptr = ptr,
				size = l.size,
				given_size = given_size,
				alloc = l.alloc,
				has_alloc = true,
				op = make_site(da, loc),
				stage = "free",
			},
		)
	}
	verify_guards(da, l, "free", loc)
	retire(da, l, ptr, loc, false)
	return nil
}

@(private)
do_free_all :: proc(da: ^Allocator, loc: runtime.Source_Code_Location) {
	for _, l in da.live {
		verify_guards(da, l, "free_all", loc)
		st := site_stats(da, l.alloc.loc)
		st.frees += 1
		st.live -= 1
		st.live_bytes -= l.size
		backing_free(da, l.raw, l.total)
	}
	da.total_frees += len(da.live)
	da.live_bytes = 0
	clear(&da.live)
	flush_quarantine(da, "free_all", loc)
}

@(private)
do_resize :: proc(
	da: ^Allocator,
	ptr: rawptr,
	old_size, size, alignment: int,
	zeroed: bool,
	loc: runtime.Source_Code_Location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	if ptr == nil {
		return do_alloc(da, size, alignment, zeroed, loc)
	}
	if size == 0 {
		return nil, do_free(da, ptr, old_size, loc)
	}
	l, ok := da.live[ptr]
	if !ok {
		op := make_site(da, loc)
		if d, dead_ok := da.dead[ptr]; dead_ok {
			raise(
				da,
				Issue {
					kind = .Double_Free,
					ptr = ptr,
					size = d.size,
					alloc = d.alloc,
					has_alloc = true,
					first_free = d.free,
					has_first_free = true,
					by_resize = d.by_resize,
					op = op,
					stage = "resize",
				},
			)
		} else {
			raise(da, Issue{kind = .Bad_Resize, ptr = ptr, op = op, stage = "resize"})
		}
		return nil, .Invalid_Pointer
	}
	if old_size != 0 && old_size != l.size {
		raise(
			da,
			Issue {
				kind = .Size_Mismatch,
				ptr = ptr,
				size = l.size,
				given_size = old_size,
				alloc = l.alloc,
				has_alloc = true,
				op = make_site(da, loc),
				stage = "resize",
			},
		)
	}
	verify_guards(da, l, "resize", loc)

	// Always move. A stale pointer into the old block then shows up as a
	// write-after-free or double-free that names this resize.
	nl, user, alloc_err := raw_alloc(da, size, max(alignment, l.alignment), false, loc)
	if alloc_err != nil {
		return nil, alloc_err
	}
	copy(user, mem.byte_slice(ptr, min(size, l.size)))
	if size > l.size {
		tail := user[l.size:]
		if zeroed {
			mem.zero_slice(tail)
		} else {
			mem.set(raw_data(tail), PATTERN_FRESH, len(tail))
		}
	}
	// The new block inherits the identity of the original allocation so leak and
	// lifetime reports point at where the object was created, not where it last grew.
	nl.alloc = l.alloc
	nl.resizes = l.resizes + 1
	nl.last_resize = loc
	da.live[raw_data(user)] = nl
	da.live_bytes += size
	da.peak_bytes = max(da.peak_bytes, da.live_bytes)
	orig := site_stats(da, l.alloc.loc)
	orig.resizes += 1
	orig.bytes += size - l.size
	orig.live_bytes += size
	orig.peak_live_bytes = max(orig.peak_live_bytes, orig.live_bytes)

	retire(da, l, ptr, loc, true)
	return user, nil
}

// Move a live block into quarantine: poison it, record when and where it died.
@(private)
retire :: proc(
	da: ^Allocator,
	l: Live,
	ptr: rawptr,
	loc: runtime.Source_Code_Location,
	by_resize: bool,
) {
	mem.set(ptr, PATTERN_DEAD, l.size)
	// From the user block to the end of the backing allocation is now off limits.
	sanitizer.address_poison(ptr, l.total - l.front)
	delete_key(&da.live, ptr)
	da.live_bytes -= l.size
	free_site := make_site(da, loc)

	st := site_stats(da, l.alloc.loc)
	st.live_bytes -= l.size
	if !by_resize {
		da.total_frees += 1
		st.frees += 1
		st.live -= 1
		age := da.seq - l.alloc.seq
		if st.frees == 1 || age < st.lifetime_min {
			st.lifetime_min = age
		}
		st.lifetime_max = max(st.lifetime_max, age)
		st.lifetime_sum += age
		if da.phase != l.alloc.phase {
			st.cross_phase += 1
		}
		st.last_death = da.phase
	}

	da.dead[ptr] = Dead {
		raw       = l.raw,
		total     = l.total,
		front     = l.front,
		size      = l.size,
		alloc     = l.alloc,
		free      = free_site,
		by_resize = by_resize,
	}
	append(&da.dead_queue, ptr)
	da.dead_bytes += l.total

	for da.dead_bytes > QUARANTINE_BYTES && da.dead_head < len(da.dead_queue) {
		evict_oldest(da, "quarantine", loc)
	}
	// Compact the queue once the consumed prefix dominates.
	if da.dead_head > 1024 && da.dead_head * 2 > len(da.dead_queue) {
		n := copy(da.dead_queue[:], da.dead_queue[da.dead_head:])
		resize(&da.dead_queue, n)
		da.dead_head = 0
	}
}

@(private)
evict_oldest :: proc(da: ^Allocator, stage: string, loc: runtime.Source_Code_Location) {
	ptr := da.dead_queue[da.dead_head]
	da.dead_head += 1
	d, ok := da.dead[ptr]
	if !ok {
		return
	}
	verify_poison(da, d, ptr, stage, loc)
	backing_free(da, d.raw, d.total)
	da.dead_bytes -= d.total
	delete_key(&da.dead, ptr)
}

@(private)
flush_quarantine :: proc(da: ^Allocator, stage: string, loc: runtime.Source_Code_Location) {
	for da.dead_head < len(da.dead_queue) {
		evict_oldest(da, stage, loc)
	}
	clear(&da.dead_queue)
	da.dead_head = 0
	da.dead_bytes = 0
}

// The backing allocator will hand this memory out again to code that is not ours,
// so every trace of poison must be gone before it goes back.
@(private)
backing_free :: proc(da: ^Allocator, raw: rawptr, total: int) {
	sanitizer.address_unpoison(raw, total)
	da.backing.procedure(da.backing.data, .Free, 0, 0, raw, total)
}

// Overwrite a poisoned region without tripping the sanitizer, then re-poison it.
@(private)
refill :: proc(ptr: rawptr, len: int, pattern: byte) {
	sanitizer.address_unpoison(ptr, len)
	mem.set(ptr, pattern, len)
	sanitizer.address_poison(ptr, len)
}

// ---- verification ---------------------------------------------------------------

@(private)
verify_all :: proc(da: ^Allocator, stage: string, loc: runtime.Source_Code_Location) {
	for _, l in da.live {
		verify_guards(da, l, stage, loc)
	}
	for ptr, d in da.dead {
		verify_poison(da, d, ptr, stage, loc)
	}
}

@(private)
verify_guards :: proc(da: ^Allocator, l: Live, stage: string, loc: runtime.Source_Code_Location) {
	block := mem.byte_slice(l.raw, l.total)
	user_ptr := rawptr(uintptr(l.raw) + uintptr(l.front))
	if c, bad := scan(block[:l.front], PATTERN_GUARD); bad {
		c.offset -= l.front
		raise(
			da,
			Issue {
				kind = .Underflow,
				ptr = user_ptr,
				size = l.size,
				alloc = l.alloc,
				has_alloc = true,
				op = make_site(da, loc),
				stage = stage,
				corruption = c,
			},
		)
		refill(l.raw, l.front, PATTERN_GUARD) // report each corruption once
	}
	if c, bad := scan(block[l.front + l.size:], PATTERN_GUARD); bad {
		c.offset += l.size
		raise(
			da,
			Issue {
				kind = .Overflow,
				ptr = user_ptr,
				size = l.size,
				alloc = l.alloc,
				has_alloc = true,
				op = make_site(da, loc),
				stage = stage,
				corruption = c,
			},
		)
		refill(raw_data(block[l.front + l.size:]), GUARD, PATTERN_GUARD)
	}
}

@(private)
verify_poison :: proc(
	da: ^Allocator,
	d: Dead,
	ptr: rawptr,
	stage: string,
	loc: runtime.Source_Code_Location,
) {
	if c, bad := scan(mem.byte_slice(ptr, d.size), PATTERN_DEAD); bad {
		raise(
			da,
			Issue {
				kind = .Write_After_Free,
				ptr = ptr,
				size = d.size,
				alloc = d.alloc,
				has_alloc = true,
				first_free = d.free,
				has_first_free = true,
				by_resize = d.by_resize,
				op = make_site(da, loc),
				stage = stage,
				corruption = c,
			},
		)
		refill(ptr, d.size, PATTERN_DEAD)
	}
}

// Find bytes that differ from `pattern`. Returns the first offset, how many differ,
// and up to eight of the offending values.
@(private, no_sanitize_address)
scan :: proc(b: []byte, pattern: byte) -> (c: Corruption, bad: bool) {
	first := -1
	for x, i in b {
		if x == pattern {
			continue
		}
		if first < 0 {
			first = i
		}
		if c.count < len(c.sample) {
			c.sample[c.count] = x
		}
		c.count += 1
	}
	if first < 0 {
		return {}, false
	}
	c.offset = first
	return c, true
}

// ---- bookkeeping helpers --------------------------------------------------------

@(private)
make_site :: proc(da: ^Allocator, loc: runtime.Source_Code_Location) -> Site {
	s := Site {
		loc   = loc,
		phase = da.phase,
		seq   = da.seq,
	}
	when BACKTRACES {
		s.bt = trace.capture()
	}
	return s
}

@(private)
site_stats :: proc(da: ^Allocator, loc: runtime.Source_Code_Location) -> ^Site_Stats {
	key := Site_Key {
		file = loc.file_path,
		line = loc.line,
	}
	st, ok := &da.sites[key]
	if !ok {
		da.sites[key] = Site_Stats {
			loc = loc,
		}
		st = &da.sites[key]
	}
	return st
}

@(private)
raise :: proc(da: ^Allocator, issue: Issue) {
	iss := issue
	iss.id = len(da.issues) + 1
	append(&da.issues, iss)
	print_issue(da, iss)
	if da.fail_fast {
		panic("debug allocator: allocation bug detected, see the issue printed above")
	}
}

// ---- address sanitizer ----------------------------------------------------------

// The allocator whose blocks the death callback describes. One debug allocator per
// process is the intended use.
@(private)
asan_owner: ^Allocator

/*
Runs while ASan is printing its report, before the process aborts. ASan knows the
address is poisoned but not what it was; this adds the block, its allocation site,
and its free site, which is what the reader needs to fix the bug.
*/
@(private)
asan_death :: proc "c" (
	pc, bp, sp, addr_unused: rawptr,
	is_write_unused: i32,
	access_size_unused: uint,
) {
	// The runtime invokes this without arguments; the parameters hold whatever was in
	// the registers. The report accessors are the reliable source.
	_, _, _, _, _, _ = pc, bp, sp, addr_unused, is_write_unused, access_size_unused
	context = runtime.default_context()
	da := asan_owner
	if da == nil || !sanitizer.address_report_present() {
		return
	}
	addr := sanitizer.address_get_report_address()
	is_write := sanitizer.address_get_report_access_type() == .write
	access_size := sanitizer.address_get_report_access_size()
	context.allocator = da.internals
	// The fault may have happened inside the allocator with the mutex held; describing
	// the address is worth more than strict locking in a process that is about to die.
	locked := sync.mutex_try_lock(&da.mutex)
	defer if locked {
		sync.mutex_unlock(&da.mutex)
	}

	fmt.eprintln()
	fmt.eprintfln(
		"== debug allocator: about the faulting address %p (%s of %d byte(s)) ==",
		addr,
		"write" if is_write else "read",
		access_size,
	)
	a := uintptr(addr)
	for user, l in da.live {
		lo := uintptr(l.raw)
		if a < lo || a >= lo + uintptr(l.total) {
			continue
		}
		describe_offset(a, uintptr(user), l.size)
		fmt.eprintln("   the block is still live")
		print_site(da, "allocated ", l.alloc)
		if l.resizes > 0 {
			fmt.eprintfln(
				"   resized    %d time(s), last at %s:%d",
				l.resizes,
				display_path(da, l.last_resize.file_path),
				l.last_resize.line,
			)
		}
		fmt.eprintln(
			"   meaning    an access outside a live block's bounds. Check the index or length used for this access against the allocation size above.",
		)
		return
	}
	for user, d in da.dead {
		lo := uintptr(d.raw)
		if a < lo || a >= lo + uintptr(d.total) {
			continue
		}
		describe_offset(a, uintptr(user), d.size)
		print_site(da, "allocated ", d.alloc)
		print_site(da, "moved by  " if d.by_resize else "freed     ", d.free)
		if d.by_resize {
			fmt.eprintln(
				"   meaning    the block was moved by a resize and this access used the old address. A pointer or slice into a dynamic array was kept across an append; re-fetch it after growing.",
			)
		} else {
			fmt.eprintln(
				"   meaning    use after free. The accessor holds a dangling pointer to a block freed at the site above.",
			)
		}
		return
	}
	fmt.eprintln(
		"   not inside any block this allocator has handed out or is holding in quarantine",
	)
	fmt.eprintfln("   phase=%s  tick=%d  issues so far=%d", da.phase, da.seq, len(da.issues))
}

@(private)
describe_offset :: proc(a, user: uintptr, size: int) {
	switch {
	case a < user:
		fmt.eprintfln("   %d byte(s) before the start of a %d-byte block", user - a, size)
	case a >= user + uintptr(size):
		fmt.eprintfln(
			"   %d byte(s) past the end of a %d-byte block",
			a - (user + uintptr(size)),
			size,
		)
	case:
		fmt.eprintfln("   %d byte(s) into a %d-byte block", a - user, size)
	}
}

// ---- reporting ------------------------------------------------------------------

@(private)
kind_name :: proc(k: Issue_Kind) -> string {
	switch k {
	case .Overflow:
		return "OVERFLOW"
	case .Underflow:
		return "UNDERFLOW"
	case .Double_Free:
		return "DOUBLE_FREE"
	case .Write_After_Free:
		return "WRITE_AFTER_FREE"
	case .Bad_Free:
		return "BAD_FREE"
	case .Bad_Resize:
		return "BAD_RESIZE"
	case .Size_Mismatch:
		return "SIZE_MISMATCH"
	}
	return "UNKNOWN"
}

@(private)
print_issue :: proc(da: ^Allocator, iss: Issue) {
	fmt.eprintfln(
		"!! ALLOCATION ISSUE #%d: %s  ptr=%p  size=%d b  detected during %s",
		iss.id,
		kind_name(iss.kind),
		iss.ptr,
		iss.size,
		iss.stage,
	)
	if iss.has_alloc {
		print_site(da, "allocated ", iss.alloc)
	}
	if iss.has_first_free {
		label := "moved by  " if iss.by_resize else "freed     "
		print_site(da, label, iss.first_free)
	}
	op_label := "detected  "
	#partial switch iss.kind {
	case .Double_Free, .Bad_Free:
		op_label = "this free "
	case .Bad_Resize:
		op_label = "this resize"
	case .Size_Mismatch:
		op_label = "freed at  "
	}
	print_site(da, op_label, iss.op)

	c := iss.corruption
	switch iss.kind {
	case .Overflow:
		fmt.eprintfln(
			"   damage     %d byte(s) written starting %d byte(s) past the end of the block: %s (guard bytes should read %02x)",
			c.count,
			c.offset - iss.size,
			hex(c),
			PATTERN_GUARD,
		)
		fmt.eprintln(
			"   meaning    something wrote beyond the allocation's last byte between allocation and this check. Look for an off-by-one in a loop bound or a length computed from the wrong variable.",
		)
	case .Underflow:
		fmt.eprintfln(
			"   damage     %d byte(s) written starting %d byte(s) before the block: %s (guard bytes should read %02x)",
			c.count,
			-c.offset,
			hex(c),
			PATTERN_GUARD,
		)
		fmt.eprintln(
			"   meaning    something wrote before the allocation's first byte. Look for a negative index or pointer arithmetic that steps back past the start.",
		)
	case .Double_Free:
		if iss.by_resize {
			fmt.eprintln(
				"   meaning    this address was invalidated when the block was resized (see 'moved by' above); the caller kept the old address across an append or resize. Re-fetch the pointer after growing the container, or reserve capacity up front.",
			)
		} else {
			fmt.eprintln(
				"   meaning    the block was already freed. Remove one of the two frees, or set the pointer to nil after the first so a second free is a no-op.",
			)
		}
	case .Write_After_Free:
		fmt.eprintfln(
			"   damage     %d byte(s) written at offset %d after the block was freed: %s (freed memory should read %02x)",
			c.count,
			c.offset,
			hex(c),
			PATTERN_DEAD,
		)
		if iss.by_resize {
			fmt.eprintln(
				"   meaning    the block was moved by a resize (see 'moved by' above) and the old address was written afterwards. A pointer or slice into a dynamic array was kept across an append.",
			)
		} else {
			fmt.eprintln(
				"   meaning    memory was written after it was freed. The writer holds a dangling pointer; find who still references this block after the free above.",
			)
		}
	case .Bad_Free, .Bad_Resize:
		fmt.eprintln(
			"   meaning    this pointer was never returned by this allocator. Common causes: freeing memory from an arena or temp allocator with the context allocator, freeing a pointer into the middle of a block, or freeing an uninitialised pointer.",
		)
	case .Size_Mismatch:
		fmt.eprintfln(
			"   damage     freed with size %d b but %d b were allocated",
			iss.given_size,
			iss.size,
		)
		fmt.eprintln(
			"   meaning    delete() was given a slice whose length differs from the allocation, usually a re-sliced or truncated slice. Delete the original slice, or keep the original length.",
		)
	}
}

@(private)
hex :: proc(c: Corruption) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< min(c.count, len(c.sample)) {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		fmt.sbprintf(&sb, "%02x", c.sample[i])
	}
	if c.count > len(c.sample) {
		strings.write_string(&sb, " ...")
	}
	return strings.to_string(sb)
}

@(private)
print_site :: proc(da: ^Allocator, label: string, s: Site) {
	fmt.eprintfln(
		"   %s %s:%d  proc=%s  phase=%s  tick=%d",
		label,
		display_path(da, s.loc.file_path),
		s.loc.line,
		s.loc.procedure,
		s.phase,
		s.seq,
	)
	when BACKTRACES {
		print_frames(da, s.bt, 8)
	}
}

@(private)
Leak_Group :: struct {
	loc:         runtime.Source_Code_Location,
	phase:       string,
	count:       int,
	bytes:       int,
	min_size:    int,
	max_size:    int,
	first_seq:   u64,
	example:     trace.Capture_Const,
	resizes:     int,
	last_resize: runtime.Source_Code_Location,
}

/*
Print the exit report to stderr. Safe to call via defer after swapping
context.allocator to this allocator. Verifies every block first, so corruption that
happened after the last free or phase change is still caught.
*/
report :: proc(
	da: ^Allocator,
	max_groups := 20,
	max_sites := 15,
	max_frames := 8,
	loc := #caller_location,
) {
	context.allocator = da.internals
	sync.guard(&da.mutex)
	verify_all(da, "exit", loc)

	leaks := len(da.live)
	fmt.eprintln("== debug allocator report ==")
	if len(da.issues) == 0 && leaks == 0 {
		fmt.eprintln("verdict: clean (no issues, no leaks)")
	} else {
		fmt.eprintfln(
			"verdict: %d issue(s), %d leaked block(s) totalling %d b",
			len(da.issues),
			leaks,
			da.live_bytes,
		)
	}
	fmt.eprintfln(
		"allocs=%d frees=%d live=%d live_bytes=%d peak_bytes=%d quarantined=%d issues=%d",
		da.total_allocs,
		da.total_frees,
		leaks,
		da.live_bytes,
		da.peak_bytes,
		len(da.dead),
		len(da.issues),
	)
	fmt.eprint("phases=")
	for p, i in da.phases {
		if i > 0 {
			fmt.eprint(" > ")
		}
		fmt.eprint(p)
	}
	fmt.eprintln()

	if len(da.issues) > 0 {
		fmt.eprintfln(
			"-- issues (%d, each printed in full where it was detected) --",
			len(da.issues),
		)
		for iss in da.issues {
			fmt.eprintf("#%d %s  ptr=%p", iss.id, kind_name(iss.kind), iss.ptr)
			if iss.has_alloc {
				fmt.eprintf(
					"  alloc %s:%d",
					display_path(da, iss.alloc.loc.file_path),
					iss.alloc.loc.line,
				)
			}
			if iss.has_first_free {
				fmt.eprintf(
					"  %s %s:%d",
					"resize" if iss.by_resize else "free",
					display_path(da, iss.first_free.loc.file_path),
					iss.first_free.loc.line,
				)
			}
			fmt.eprintfln(
				"  detected %s:%d (%s)",
				display_path(da, iss.op.loc.file_path),
				iss.op.loc.line,
				iss.stage,
			)
		}
	}

	if leaks > 0 {
		print_leaks(da, max_groups, max_frames)
	}
	print_sites(da, max_sites)
}

@(private)
print_leaks :: proc(da: ^Allocator, max_groups, max_frames: int) {
	groups := make(map[Site_Key]Leak_Group, da.internals)
	defer delete(groups)
	for _, l in da.live {
		key := Site_Key {
			file = l.alloc.loc.file_path,
			line = l.alloc.loc.line,
		}
		g, exists := &groups[key]
		if !exists {
			groups[key] = Leak_Group {
				loc       = l.alloc.loc,
				phase     = l.alloc.phase,
				min_size  = l.size,
				max_size  = l.size,
				first_seq = l.alloc.seq,
				example   = l.alloc.bt,
			}
			g = &groups[key]
		}
		g.count += 1
		g.bytes += l.size
		g.min_size = min(g.min_size, l.size)
		g.max_size = max(g.max_size, l.size)
		g.resizes += l.resizes
		if l.resizes > 0 {
			g.last_resize = l.last_resize
		}
		if l.alloc.seq < g.first_seq {
			g.first_seq = l.alloc.seq
			g.example = l.alloc.bt
			g.phase = l.alloc.phase
		}
	}

	list := make([dynamic]Leak_Group, 0, len(groups), da.internals)
	defer delete(list)
	for _, g in groups {
		append(&list, g)
	}
	slice.sort_by(list[:], proc(a, b: Leak_Group) -> bool {
		return a.bytes > b.bytes
	})

	fmt.eprintfln("-- leaks (%d group(s), %d block(s)) --", len(list), len(da.live))
	for g, i in list {
		if i >= max_groups {
			fmt.eprintfln(
				"... %d more leak groups omitted (raise max_groups to see them)",
				len(list) - i,
			)
			break
		}
		if g.min_size == g.max_size {
			fmt.eprintf("LEAK  %d x %d b = %d b", g.count, g.min_size, g.bytes)
		} else {
			fmt.eprintf(
				"LEAK  %d block(s), %d b total (sizes %d..%d b)",
				g.count,
				g.bytes,
				g.min_size,
				g.max_size,
			)
		}
		fmt.eprintf(
			"  phase=%s  site=%s:%d  proc=%s  first_tick=%d",
			g.phase,
			display_path(da, g.loc.file_path),
			g.loc.line,
			g.loc.procedure,
			g.first_seq,
		)
		if g.resizes > 0 {
			fmt.eprintf(
				"  resized=%d (last at %s:%d)",
				g.resizes,
				display_path(da, g.last_resize.file_path),
				g.last_resize.line,
			)
		}
		fmt.eprintln()
		when BACKTRACES {
			print_frames(da, g.example, max_frames)
		}
	}
}

@(private)
print_sites :: proc(da: ^Allocator, max_sites: int) {
	list := make([dynamic]Site_Stats, 0, len(da.sites), da.internals)
	defer delete(list)
	for _, st in da.sites {
		if st.allocs == 0 && st.resizes == 0 {
			continue
		}
		append(&list, st)
	}
	if len(list) == 0 {
		return
	}
	slice.sort_by(list[:], proc(a, b: Site_Stats) -> bool {
		return a.bytes > b.bytes
	})
	fmt.eprintfln(
		"-- lifetimes by allocation site (top %d of %d by bytes; lifetime in allocation ticks) --",
		min(max_sites, len(list)),
		len(list),
	)
	for st, i in list {
		if i >= max_sites {
			break
		}
		fmt.eprintf(
			"SITE  %s:%d  proc=%s  allocs=%d frees=%d live=%d bytes=%d peak_live=%d",
			display_path(da, st.loc.file_path),
			st.loc.line,
			st.loc.procedure,
			st.allocs,
			st.frees,
			st.live,
			st.bytes,
			st.peak_live_bytes,
		)
		if st.resizes > 0 {
			fmt.eprintf(" resizes=%d", st.resizes)
		}
		if st.frees > 0 {
			fmt.eprintf(
				"  lifetime=%d..%d avg %d",
				st.lifetime_min,
				st.lifetime_max,
				st.lifetime_sum / u64(st.frees),
			)
			if st.cross_phase > 0 {
				fmt.eprintf("  cross_phase=%d (last died in %s)", st.cross_phase, st.last_death)
			}
		}
		fmt.eprintln()
	}
}

// ---- paths and frames -----------------------------------------------------------

// Directory of this source file, used to drop this package's own frames.
@(private)
SELF_DIR :: #directory

// Frames from Odin's runtime are plumbing between the user's call and this allocator.
@(private)
RUNTIME_DIR :: ODIN_ROOT + "base"

@(private)
print_frames :: proc(da: ^Allocator, bt: trace.Capture_Const, max_frames: int) {
	if bt.len == 0 {
		return
	}
	locs, err := trace.resolve(bt, da.internals, context.temp_allocator)
	if err != nil {
		fmt.eprintfln(
			"      (call chain unavailable: %s; build with -debug)",
			trace.resolve_err_string(err),
		)
		return
	}
	defer trace.locations_destroy(locs, da.internals)

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
		if !strings.has_prefix(path, da.root) && !strings.has_prefix(path, odin_root) {
			break
		}
		if shown >= max_frames {
			fmt.eprintln("      <- ...")
			break
		}
		fmt.eprintfln(
			"      <- %s  %s:%d",
			short_proc(l.procedure),
			display_path(da, l.file_path),
			l.line,
		)
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
display_path :: proc(da: ^Allocator, path: string) -> string {
	n := normalize(path, context.temp_allocator)
	if da.root != "" && strings.has_prefix(n, da.root) {
		rest := n[len(da.root):]
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
