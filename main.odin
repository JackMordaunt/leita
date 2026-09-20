/*
sonar: find out what is using the disk.

Usage:
	sonar [drive-or-image]        default C:

Reads the volume's MFT directly and prints the largest files and directories. Reading
a live volume needs an elevated prompt.
*/
package main

import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

@(require) import "debug"
import "ntfs"
import "scan"
import "walk"

TOP_N :: 20

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}

	defer free_all(context.temp_allocator)

	// Assertion failures print a call chain in every build; symbols need -debug.
	context.assertion_failure_proc = trace.assertion_failure_proc

	target := os.user_home_dir(context.allocator) or_else "/"
	opts: ntfs.Read_Options
	wcfg: walk.Config
	live := false

	for arg in os.args[1:] {
		switch arg {
		case "-h", "--help", "/?":
			fmt.println(
				"usage: sonar [drive] [--live] [--buffered] [--no-skip] [--min-skip=N] [--workers=N] [--walk-workers=N] [--chunk=N]",
			)
			return 0
		case "--live":
			live = true
		case "--buffered":
			opts.io_mode = .Buffered
		case "--no-skip":
			opts.min_skip = -1
		case:
			// --min-skip=<bytes> tunes how long a run of dead records must be before
			// breaking the sequential read to jump over it pays for itself.
			ok := true
			switch {
			case strings.has_prefix(arg, "--min-skip="):
				opts.min_skip, ok = number(arg)
			case strings.has_prefix(arg, "--workers="):
				opts.workers, ok = number(arg)
			case strings.has_prefix(arg, "--walk-workers="):
				wcfg.workers, ok = number(arg)
			case strings.has_prefix(arg, "--chunk="):
				opts.chunk_size, ok = number(arg)
			case strings.has_prefix(arg, "-"):
				// Anything else starting with a dash is a mistyped option. Taking it
				// for the target would report that the volume cannot be found.
				fmt.eprintfln("error: unknown option %s", arg)
				return 1
			case:
				target = arg
			}
			if !ok {
				fmt.eprintfln("error: %s needs a number", arg)
				return 1
			}
		}
	}

	// Resolve once, so the reader is chosen from what the OS says rather than from
	// the shape of the string.
	resolved, resolve_err := scan.resolve(target)
	if resolve_err != nil {
		fmt.eprintfln("error: cannot scan %s: %v", target, resolve_err)
		return 1
	}
	defer scan.target_destroy(&resolved)

	choice := scan.choose(resolved, scan.elevated())
	fmt.printfln(
		"sonar: %s on %s (%v, %v engine, %v io)",
		scan.location(resolved, context.temp_allocator),
		resolved.volume,
		resolved.fs,
		choice.engine,
		opts.io_mode,
	)
	if choice.elevation_would_help {
		fmt.eprintln("note: this volume reads far faster from an administrator prompt")
	}
	if choice.engine == .None {
		fmt.eprintfln("error: nothing here can be scanned")
		return 1
	}

	if live {
		if choice.engine != .Mft {
			fmt.eprintln("error: live mode needs the MFT reader")
			return 1
		}
		return run_live(resolved.volume, scan.top(resolved), opts)
	}

	t: scan.Tree
	if err := scan.tree_init(&t, 8); err != nil {
		fmt.eprintfln("error: %v", err)
		return 1
	}
	defer scan.tree_destroy(&t)

	start := time.tick_now()
	// The one place a reader is chosen. Each fills the same tree; the MFT reader also
	// keeps its own table, which carries what only NTFS knows.
	m: ntfs.Mft
	have_mft := false
	// Registered before the read, not after the switch: projecting the table can fail,
	// and a defer below that point never covers the return it takes.
	defer if have_mft {
		ntfs.mft_destroy(&m)
	}
	switch choice.engine {
	case .Mft:
		err := ntfs.read_mft(resolved.volume, &m, opts)
		if err != nil {
			#partial switch err {
			case .Access_Denied:
				fmt.eprintln(
					"error: access denied. Reading a raw volume needs an administrator prompt.",
				)
			case .Not_Ntfs:
				fmt.eprintln("error: not an NTFS volume")
			case .Open_Failed:
				fmt.eprintfln("error: could not open %s", resolved.volume)
			case:
				fmt.eprintfln("error: %v", err)
			}
			return 1
		}
		have_mft = true
		projection: ntfs.Projection
		defer ntfs.projection_destroy(&projection)
		if err := ntfs.to_tree(&m, &t, &projection); err != nil {
			fmt.eprintfln("error: %v", err)
			return 1
		}
		// The table calls its root ".", so paths would lose the volume it came from.
		rw := scan.writer(&t, 0)
		scan.node(&t, t.root).name = scan.intern(&rw, scan.top(resolved))
	case .Walk:
		root := scan.location(resolved, context.temp_allocator)
		if err := walk.scan(root, &t, wcfg); err != nil {
			fmt.eprintfln("error: walking %s: %v", root, err)
			return 1
		}
	case .None:
	}
	elapsed := time.tick_since(start)

	if have_mft {
		print_native(&m, elapsed)
	}
	fmt.println()
	fmt.printfln(
		"tree       %d slots, %d used, read in %.0f ms",
		t.count,
		t.nodes_done,
		time.duration_milliseconds(elapsed),
	)

	totals := make([]u64, t.count)
	defer delete(totals)
	roll_up(&t, totals)

	print_largest(&t, totals, .files)
	print_largest(&t, totals, .directories)
	return 0
}

// The value of a `--name=value` option.
@(private = "file")
number :: proc(arg: string) -> (int, bool) {
	i := strings.index_byte(arg, '=')
	if i < 0 {
		return 0, false
	}
	return strconv.parse_int(arg[i + 1:])
}

/*
Credit every node's bytes to each of its ancestors.

An extra name for a file counted elsewhere is skipped, or the file would be charged
to every directory it is linked into. The depth cap guards against a cycle that a
corrupt source could produce.
*/
roll_up :: proc(t: ^scan.Tree, totals: []u64) {
	for i in 0 ..< t.count {
		n := scan.node(t, i)
		if .Used not_in n.flags || .Extra_Name in n.flags {
			continue
		}
		if .Directory in n.flags {
			totals[i] += n.disk
		}
		cur := i
		for depth := 0; depth < 64; depth += 1 {
			p := scan.node(t, cur).parent
			if p == cur || p >= t.count {
				break
			}
			totals[p] += n.disk
			cur = p
		}
	}
}

Kind :: enum {
	files,
	directories,
}

// The directories that hold the most, largest first.
rank :: proc(t: ^scan.Tree, totals: []u64, top: []Sized) -> int {
	count := 0
	for i in 0 ..< t.count {
		n := scan.node(t, i)
		if .Used not_in n.flags || .Directory not_in n.flags {
			continue
		}
		if totals[i] == 0 {
			continue
		}
		top_n(top, &count, Sized{bytes = totals[i], record = i})
	}
	return count
}

print_largest :: proc(t: ^scan.Tree, totals: []u64, kind: Kind) {
	top: [TOP_N]Sized
	count := 0
	for i in 0 ..< t.count {
		n := scan.node(t, i)
		if .Used not_in n.flags {
			continue
		}
		bytes: u64
		switch kind {
		case .files:
			if .Directory in n.flags || .Extra_Name in n.flags {
				continue
			}
			bytes = n.disk
		case .directories:
			if .Directory not_in n.flags {
				continue
			}
			bytes = totals[i]
		}
		if bytes == 0 {
			continue
		}
		top_n(top[:], &count, Sized{bytes = bytes, record = i})
	}
	fmt.println()
	fmt.printfln("largest %v (%d)", kind, count)
	for s in top[:count] {
		fmt.printfln("  %10s  %s", human(s.bytes), scan.path(t, s.record, context.temp_allocator))
	}
}

// What only the NTFS reader knows, kept because the tree cannot carry it.
print_native :: proc(m: ^ntfs.Mft, elapsed: time.Duration) {

	files: u64
	allocated: u64
	for e in m.entries {
		if .In_Use not_in e.flags {
			continue
		}
		allocated += e.allocated
		if .Directory not_in e.flags {
			files += 1
		}
	}
	volume_bytes := m.boot.total_sectors * u64(m.boot.bytes_per_sector)
	fmt.println()
	fmt.printfln(
		"volume     %s, %d B clusters, %d B records",
		human(volume_bytes),
		m.boot.bytes_per_cluster,
		m.boot.record_size,
	)
	fmt.printfln(
		"mft        %d slots, %d records, %d unreadable, read in %.0f ms",
		m.stats.records,
		m.stats.records_read,
		m.stats.records_bad,
		time.duration_milliseconds(elapsed),
	)
	fmt.printfln(
		"in use     %d files, %d directories, %d extra hard links",
		files,
		m.stats.directories,
		len(m.links),
	)
	fmt.printfln("attributed %s summed from every file run list", human(allocated))

	/*
	$Bitmap counts allocated clusters without consulting a single file, so comparing it
	against the sum above checks the run list decoding. The two should agree closely;
	a wide gap means clusters are allocated that no file claims, which is a parsing bug
	rather than missing disk space.
	*/
	on_disk := m.stats.allocated_clusters * u64(m.boot.bytes_per_cluster)
	if on_disk > 0 {
		fmt.printfln("on disk    %s marked allocated in $Bitmap", human(on_disk))
		if on_disk >= allocated {
			gap := on_disk - allocated
			fmt.printfln(
				"unclaimed  %s (%.2f%%) allocated but charged to no file",
				human(gap),
				100 * f64(gap) / f64(on_disk),
			)
		} else {
			fmt.printfln(
				"overcount  %s more attributed than $Bitmap reports allocated",
				human(allocated - on_disk),
			)
		}
	}
	if m.stats.resident_files > 0 {
		fmt.printfln(
			"resident   %d files hold %s inside their MFT records, charged to $MFT",
			m.stats.resident_files,
			human(m.stats.resident_bytes),
		)
	}
}

Sized :: struct {
	bytes:  u64,
	record: u32,
}

// Keep the N largest candidates in descending order without sorting the whole table.
// Most candidates fail the first comparison, so the scan stays linear.
@(private = "file")
top_n :: proc(top: []Sized, count: ^int, cand: Sized) {
	if count^ == len(top) && cand.bytes <= top[len(top) - 1].bytes {
		return
	}
	i := count^ if count^ < len(top) else len(top) - 1
	for i > 0 && top[i - 1].bytes < cand.bytes {
		top[i] = top[i - 1]
		i -= 1
	}
	top[i] = cand
	if count^ < len(top) {
		count^ += 1
	}
}

human :: proc(n: u64) -> string {
	units := [?]string{"B", "KiB", "MiB", "GiB", "TiB"}
	v := f64(n)
	i := 0
	for v >= 1024 && i < len(units) - 1 {
		v /= 1024
		i += 1
	}
	if i == 0 {
		return fmt.tprintf("%d B", n)
	}
	return fmt.tprintf("%.1f %s", v, units[i])
}
