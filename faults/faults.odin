/*
Package faults is the seam between leita's durable writes and the file layer, so a
test can make a disk misbehave where it never does on its own: an open, write, sync,
rename or delete that fails with a full disk, an I/O error, a read-only volume or a
denied permission, a write that stops short, or the process killed outright at that
call.

Each wrapper does what the core:os call of its name does. Only a test build checks
for a fault (ODIN_TEST): elsewhere every wrapper is that call and nothing more.

A plan is armed per thread, so tests running side by side in one binary never see
each other's faults, and the code under test must make its calls on the thread that
armed it. Each call the seam sees is a crossing; crossings counts them, so a test
can run an operation once to learn how many it makes and then fault each in turn.
*/
package leita_faults

import "core:os"
import "core:strings"

// Only a test build matches a path.
_ :: strings

// Op is the kind of call a fault is put on.
Op :: enum u8 {
	Open, // a file opened to write, or made
	Write,
	Sync,
	Rename,
	Remove, // a file or directory deleted
}

// Fault is what the call does instead of its work.
Fault :: enum u8 {
	None,
	No_Space, // ENOSPC, ERROR_DISK_FULL
	IO, // EIO, ERROR_CRC
	Read_Only, // EROFS, ERROR_WRITE_PROTECT
	Denied, // EACCES, ERROR_ACCESS_DENIED
	Short, // a write takes half of what it is given, and the next part fails No_Space
	Kill, // the process is killed by SIGKILL, or TerminateProcess, before the call
}

/*
Rule puts fault on the calls of op whose path holds path ("" for any). nth is which
of those calls, from 1, counted since arm; 0 is every one. any puts it on the nth
crossing of whatever op instead, for a harness that kills at each point in turn.
*/
Rule :: struct {
	op:    Op,
	fault: Fault,
	nth:   int,
	path:  string,
	any:   bool,
}

@(private)
Plan :: struct {
	rules:     [8]Rule,
	count:     int,
	matched:   [8]int, // the calls each rule's op and path have matched
	crossings: int,
	hits:      int,
	short:     bool, // a Short write was given: the next write on the thread fails
}

when ODIN_TEST {
	@(private, thread_local)
	plan: Plan
}

// arm replaces this thread's plan with rules and starts its counts again. The paths
// rules name must outlive the plan.
arm :: proc(rules: ..Rule) {
	when ODIN_TEST {
		assert(len(rules) <= len(plan.rules), "too many fault rules")
		plan = {}
		copy(plan.rules[:], rules)
		plan.count = len(rules)
	}
}

// disarm clears this thread's plan; its counts are kept for crossings and hits.
disarm :: proc() {
	when ODIN_TEST {
		plan.count = 0
	}
}

// crossings is how many calls this thread made through the seam since arm.
crossings :: proc() -> int {
	when ODIN_TEST {
		return plan.crossings
	}
	return 0
}

// hits is how many faults this thread's plan has put on a call since arm.
hits :: proc() -> int {
	when ODIN_TEST {
		return plan.hits
	}
	return 0
}

/*
check counts a call of op on path and says the fault the plan puts on it, killing the
process here for Kill. For code that makes its own system calls: it acts on the
answer itself, error_of saying what to report.
*/
check :: proc(op: Op, path: string) -> Fault {
	when ODIN_TEST {
		plan.crossings += 1
		for r, i in plan.rules[:plan.count] {
			hit := false
			if r.any {
				hit = r.nth == plan.crossings
			} else if r.op == op && (r.path == "" || strings.contains(path, r.path)) {
				plan.matched[i] += 1
				hit = r.nth == 0 || r.nth == plan.matched[i]
			}
			if hit && r.fault != .None {
				plan.hits += 1
				if r.fault == .Kill {
					kill_self()
				}
				return r.fault
			}
		}
	}
	return .None
}

// error_of is the error a call that met f returns, as the platform says it.
error_of :: proc(f: Fault) -> os.Error {
	if f == .None {
		return nil
	}
	return platform_error(f)
}

// open is os.open, for a file opened to write or made.
open :: proc(
	name: string,
	flags := os.File_Flags{.Read},
	perm := os.Permissions_Default,
) -> (
	^os.File,
	os.Error,
) {
	if f := check(.Open, name); f != .None {
		return nil, error_of(f)
	}
	return os.open(name, flags, perm)
}

// write is os.write. A Short write writes half of p and says so, without error.
write :: proc(f: ^os.File, p: []byte) -> (n: int, err: os.Error) {
	when ODIN_TEST {
		if plan.short {
			plan.short = false
			return 0, error_of(.No_Space)
		}
	}

	switch fault := check(.Write, os.name(f)); fault {
	case .None:
	case .Short:
		when ODIN_TEST {
			plan.short = true
		}
		if len(p) > 1 {
			return os.write(f, p[:len(p) / 2])
		}
		return 0, error_of(.No_Space)
	case .No_Space, .IO, .Read_Only, .Denied, .Kill:
		return 0, error_of(fault)
	}
	return os.write(f, p)
}

// sync is os.sync.
sync :: proc(f: ^os.File) -> os.Error {
	if fault := check(.Sync, os.name(f)); fault != .None {
		return error_of(fault)
	}
	return os.sync(f)
}

// rename is os.rename; old_path is the one a rule's path is matched against.
rename :: proc(old_path, new_path: string) -> os.Error {
	if f := check(.Rename, old_path); f != .None {
		return error_of(f)
	}
	return os.rename(old_path, new_path)
}

// remove is os.remove.
remove :: proc(name: string) -> os.Error {
	if f := check(.Remove, name); f != .None {
		return error_of(f)
	}
	return os.remove(name)
}

/*
write_entire_file is os.write_entire_file: an open, then a write, then a close. A
Short write leaves half of data in the file and fails No_Space, as a disk that fills
part way does.
*/
write_entire_file :: proc(
	name: string,
	data: []byte,
	perm := os.Permissions_Read_All + {.Write_User},
) -> os.Error {
	f := open(name, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, perm) or_return
	rest := data
	err: os.Error
	for len(rest) > 0 && err == nil {
		n: int
		n, err = write(f, rest)
		rest = rest[n:]
	}
	if cerr := os.close(f); cerr != nil && err == nil {
		err = cerr
	}
	return err
}
