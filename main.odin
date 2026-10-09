/*
estoile: find out what is using the disk.

Usage:
	estoile [drive-or-image] [flags]     -h lists the flags

Reads the volume's MFT directly and prints the largest files and directories. Reading
a live volume needs an elevated prompt.
*/
package main

import "core:debug/trace"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:time"

import "human"
@(require) import "jm:debug"
import "ntfs"
import "scan"
import "survey"
import "walk"

// Largest N files/folders to print.
TOP_N :: 20

PROGRAM :: "estoile"

/*
What the command line can set.

Read in UNIX style, so `--flag`, `--flag=value` and `--flag value` all work, and `-h`
prints this. A count left at zero means the reader chooses its own, rather than
having a second set of defaults to keep in step here.
*/
Options :: struct {
	target:       string `args:"pos=0" usage:"Drive, device, image or directory to scan. Defaults to your home directory."`,
	live:         bool `usage:"Draw the answer as it is found rather than once at the end."`,
	buffered:     bool `usage:"Read the volume through the system cache rather than around it."`,
	no_skip:      bool `usage:"Read runs of dead MFT records rather than jumping over them."`,
	min_skip:     int `usage:"Shortest run of dead records worth jumping over, in bytes."`,
	workers:      int `usage:"MFT readers to run at once."`,
	walk_workers: int `usage:"Directory readers to run at once."`,
	gentle:       bool `usage:"Leave the disk and cores to other work by reading with fewer threads."`,
	chunk:        int `usage:"Bytes per volume read."`,
}

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

	context.assertion_failure_proc = trace.assertion_failure_proc

	opt: Options
	if err := flags.parse(&opt, os.args[1:], .Unix); err != nil {
		// print_errors writes usage for a help request and the reason for anything
		// else, so the only decision left here is what to exit with.
		flags.print_errors(Options, err, PROGRAM, .Unix)
		_, asked_for_help := err.(flags.Help_Request)
		return 0 if asked_for_help else 1
	}

	target_str := opt.target
	if target_str == "" {
		target_str = os.user_home_dir(context.temp_allocator) or_else "/"
	}
	opts := ntfs.Read_Options {
		chunk_size = opt.chunk,
		io_mode    = .Buffered if opt.buffered else .Unbuffered,
		// Negative reads every record; zero leaves the reader its own default.
		min_skip   = -1 if opt.no_skip else opt.min_skip,
		workers    = opt.workers,
	}

	target, engine, resolve_err := scan.resolve(target_str)
	if resolve_err != nil {
		fmt.eprintfln("error: cannot scan %s: %v", target_str, resolve_err)
		return 1
	}
	defer scan.target_destroy(&target)
	wcfg := walk.Config {
		workers = opt.walk_workers,
		media   = target.media,
		pace    = .Gentle if opt.gentle else .Full,
	}

	fmt.printfln(
		"estoile: %s on %s (%v, %v media, %v engine, %v io)",
		scan.location(target, context.temp_allocator),
		target.volume,
		target.fs,
		target.media,
		engine.engine,
		opts.io_mode,
	)
	if engine.engine == .Walk {
		fmt.printfln("walk: %d readers at %v pace", walk.width(wcfg), wcfg.pace)
	}

	if engine.permission_would_help {
		when ODIN_OS == .Windows {
			fmt.eprintln("note: this volume reads far faster from an administrator prompt")
		} else {
			fmt.eprintfln(
				"note: this volume reads far faster with permission to open %s directly",
				target.volume,
			)
		}
	}

	if engine.engine == .None {
		fmt.eprintfln("error: nothing here can be scanned")
		return 1
	}

	t: scan.Tree
	if err := scan.tree_init(&t, walk.width(wcfg)); err != nil {
		fmt.eprintfln("error: %v", err)
		return 1
	}
	defer scan.tree_destroy(&t)

	// The table outlives the tree, whose names are borrowed from it.
	f := survey.Fill {
		target = target,
		engine = engine.engine,
		opts   = opts,
		wcfg   = wcfg,
		tree   = &t,
	}
	defer survey.fill_destroy(&f)

	if opt.live {
		return run_live(&f)
	}

	start := time.tick_now()
	survey.fill_run(&f)
	if fill_report(&f) {
		return 1
	}
	elapsed := time.tick_since(start)

	if engine.engine == .Mft {
		print_native(&f.table, elapsed)
	}
	fmt.println()
	fmt.printfln(
		"tree       %d slots, %d used, read in %.0f ms",
		t.count,
		t.nodes_done,
		time.duration_milliseconds(elapsed),
	)

	// The same charging the live scan does, run once over a tree nobody is still
	// filling. A node left uncharged here has an ancestor that never resolved, and
	// another pass would not change that.
	roll: survey.Rollup
	defer survey.rollup_destroy(&roll)
	survey.rollup_advance(&roll, &t)

	print_largest(&t, &roll, .files)
	print_largest(&t, &roll, .directories)
	return 0
}

// Say what went wrong, if anything did.
fill_report :: proc(f: ^survey.Fill) -> bool {
	if msg := survey.problem(f); msg != "" {
		fmt.eprintfln("error: %s", msg)
		return true
	}
	return false
}

Kind :: enum {
	files,
	directories,
}

// The directories that hold the most, largest first.
rank :: proc(t: ^scan.Tree, roll: ^survey.Rollup, top: []Sized) -> int {
	count := 0
	// Bounded by what the rollup has seen rather than the tree: a reader may hand out
	// more slots while this runs, and those have not been charged yet.
	for i in 0 ..< roll.seen {
		f := scan.node_flags(scan.node(t, i))
		if .Used not_in f || .Directory not_in f {
			continue
		}
		bytes := survey.total(roll, i)
		if bytes == 0 {
			continue
		}
		top_n(top, &count, Sized{bytes = bytes, record = i})
	}
	return count
}

print_largest :: proc(t: ^scan.Tree, roll: ^survey.Rollup, kind: Kind) {
	top: [TOP_N]Sized
	count := 0
	for i in 0 ..< roll.seen {
		n := scan.node(t, i)
		flags := scan.node_flags(n)
		if .Used not_in flags {
			continue
		}
		bytes: u64
		switch kind {
		case .files:
			if .Directory in flags || .Extra_Name in flags {
				continue
			}
			bytes = n.disk
		case .directories:
			if .Directory not_in flags {
				continue
			}
			bytes = survey.total(roll, i)
		}
		if bytes == 0 {
			continue
		}
		top_n(top[:], &count, Sized{bytes = bytes, record = i})
	}
	fmt.println()
	fmt.printfln("largest %v (%d)", kind, count)
	for s in top[:count] {
		fmt.printfln(
			"  %10s  %s",
			human.bytes(s.bytes),
			scan.path(t, s.record, context.temp_allocator),
		)
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
		human.bytes(volume_bytes),
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
	fmt.printfln("attributed %s summed from every file run list", human.bytes(allocated))

	/*
	$Bitmap counts allocated clusters without consulting a single file, so comparing it
	against the sum above checks the run list decoding. The two should agree closely;
	a wide gap means clusters are allocated that no file claims, which is a parsing bug
	rather than missing disk space.
	*/
	on_disk := m.stats.allocated_clusters * u64(m.boot.bytes_per_cluster)
	if on_disk > 0 {
		fmt.printfln("on disk    %s marked allocated in $Bitmap", human.bytes(on_disk))
		if on_disk >= allocated {
			gap := on_disk - allocated
			fmt.printfln(
				"unclaimed  %s (%.2f%%) allocated but charged to no file",
				human.bytes(gap),
				100 * f64(gap) / f64(on_disk),
			)
		} else {
			fmt.printfln(
				"overcount  %s more attributed than $Bitmap reports allocated",
				human.bytes(allocated - on_disk),
			)
		}
	}
	if m.stats.resident_files > 0 {
		fmt.printfln(
			"resident   %d files hold %s inside their MFT records, charged to $MFT",
			m.stats.resident_files,
			human.bytes(m.stats.resident_bytes),
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
