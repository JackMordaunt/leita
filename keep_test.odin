package main

import "base:runtime"

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:http/loopback"

import "history"
import "scan"
import "schedule"

// fixture makes a directory under a fresh temporary one, named for the test so
// no two tests share it, holding files big enough to be kept.
@(private)
fixture :: proc(t: ^testing.T, name: string) -> (root, dir: string) {
	err: os.Error
	root, err = os.make_directory_temp(
		"",
		strings.concatenate({"sonar-", name, "-*"}, context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	dir, _ = filepath.join({root, "data"}, context.temp_allocator)
	sub, _ := filepath.join({dir, "sub"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(sub) == nil)
	data := make([]byte, 3 << 20, context.temp_allocator)
	for &b, i in data {
		b = byte(i * 7 + 1)
	}
	big, _ := filepath.join({dir, "big.bin"}, context.temp_allocator)
	deep, _ := filepath.join({sub, "deep.bin"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(big, data) == nil)
	testing.expect(t, os.write_entire_file(deep, data[:2 << 20]) == nil)
	return
}

// run_sonar runs the command line args as main does, with a temporary allocator
// of its own: run frees its temporary allocator on the way out, and the test's
// paths live in the test's.
@(private)
run_sonar :: proc(args: ..string) -> int {
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	context.temp_allocator = runtime.arena_allocator(&arena)
	return run(args)
}

// kept is the snapshots of dir in the history at db, newest first.
@(private)
kept :: proc(t: ^testing.T, db, dir: string) -> []history.Snapshot {
	target, _, err := scan.resolve(dir)
	testing.expect(t, err == nil)
	defer scan.target_destroy(&target)
	st: history.Store
	testing.expect(t, history.open(&st, db) == nil)
	defer history.close(&st)
	snaps, _ := history.list(&st, scan.location(target, context.temp_allocator))
	return snaps
}

@(test)
a_kept_scan_lands_in_the_history_with_its_disk :: proc(t: ^testing.T) {
	root, dir := fixture(t, "keep-twice")
	defer os.remove_all(root)
	db, _ := filepath.join({root, "history.db"}, context.temp_allocator)

	testing.expect_value(t, run_sonar(dir, "--keep", "--history", db), schedule.EXIT_OK)
	testing.expect_value(t, run_sonar(dir, "--keep", "--history", db), schedule.EXIT_OK)

	snaps := kept(t, db, dir)
	testing.expect_value(t, len(snaps), 2)
	for s in snaps {
		testing.expect(t, s.disk.total > 0, "the disk's size is kept")
		testing.expect(t, s.disk.free <= s.disk.total, "no more is free than there is")
		testing.expect(t, s.bytes >= 5 << 20, "the top holds both files")
	}
	st: history.Store
	testing.expect(t, history.open(&st, db) == nil)
	defer history.close(&st)
	entries, _ := history.load(&st, snaps[0].id, context.temp_allocator)
	testing.expectf(t, entries["big.bin"] >= 3 << 20, "a big file is kept: %v", entries["big.bin"])
	testing.expectf(
		t,
		entries["sub/deep.bin"] >= 2 << 20,
		"a big file deeper down is kept by its path: %v",
		entries["sub/deep.bin"],
	)
	testing.expect_value(t, entries[""], snaps[0].bytes)
}

@(test)
a_kept_scan_stands_aside_for_one_running :: proc(t: ^testing.T) {
	root, dir := fixture(t, "keep-locked")
	defer os.remove_all(root)
	db, _ := filepath.join({root, "history.db"}, context.temp_allocator)

	target, _, _ := scan.resolve(dir)
	place := scan.location(target, context.temp_allocator)
	scan.target_destroy(&target)
	lock := history.lock_path(db, place, context.temp_allocator)
	held, taken := history.lock(lock)
	testing.expect_value(t, taken, history.Lock_Result.Taken)
	testing.expect_value(t, run_sonar(dir, "--keep", "--history", db), schedule.EXIT_OK)
	testing.expect_value(t, len(kept(t, db, dir)), 0)
	history.unlock(&held)
	testing.expect(t, unlocked_soon(lock), "the lock is let go")
	testing.expect_value(t, run_sonar(dir, "--keep", "--history", db), schedule.EXIT_OK)
	testing.expect_value(t, len(kept(t, db, dir)), 1)
}

/*
unlocked_soon says whether the lock at path can be taken within a second, and lets
it go again. A lock lasts as long as any copy of its open file, and a process
another test forks while it is held keeps a copy until it runs its program.
*/
@(private)
unlocked_soon :: proc(path: string) -> bool {
	for _ in 0 ..< 100 {
		l, result := history.lock(path)
		if result == .Taken {
			history.unlock(&l)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
an_alert_with_nowhere_to_go_fails_the_run :: proc(t: ^testing.T) {
	root, dir := fixture(t, "keep-alert")
	defer os.remove_all(root)
	db, _ := filepath.join({root, "history.db"}, context.temp_allocator)

	// A disk holding the fixture is never all free, so this fires.
	testing.expect_value(
		t,
		run_sonar(dir, "--keep", "--history", db, "--alert-free", "100"),
		schedule.EXIT_ALERT,
	)
	testing.expect_value(
		t,
		run_sonar(dir, "--keep", "--history", db, "--alert-free", "0.0001"),
		schedule.EXIT_OK,
	)
	testing.expect_value(t, len(kept(t, db, dir)), 2)
	testing.expect_value(t, run_sonar(dir, "--alert-free", "5"), 1)
}

// Listener is what the test webhook heard, and how it answers.
@(private)
Listener :: struct {
	mutex:  sync.Mutex,
	bodies: [dynamic]string,
	answer: string,
}

@(private)
listen :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	h := (^Listener)(conn.server.user)
	sync.guard(&h.mutex)
	append(&h.bodies, strings.clone(req.body, runtime.heap_allocator()))
	loopback.send(conn, h.answer)
}

@(test)
an_alert_goes_to_the_webhook :: proc(t: ^testing.T) {
	root, dir := fixture(t, "keep-webhook")
	defer os.remove_all(root)
	db, _ := filepath.join({root, "history.db"}, context.temp_allocator)

	h := Listener {
		bodies = make([dynamic]string, runtime.heap_allocator()),
		answer = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
	}
	srv, ok := loopback.start(listen, &h, runtime.heap_allocator())
	testing.expect(t, ok)
	defer {
		loopback.stop(srv)
		for b in h.bodies {
			delete(b, runtime.heap_allocator())
		}
		delete(h.bodies)
	}
	url := loopback.url(srv, "/hook")

	testing.expect_value(
		t,
		run_sonar(dir, "--keep", "--history", db, "--alert-free", "100", "--webhook", url),
		schedule.EXIT_OK,
	)
	sync.lock(&h.mutex)
	testing.expect_value(t, len(h.bodies), 1)
	if len(h.bodies) == 1 {
		testing.expect(t, strings.contains(h.bodies[0], `"alerts":["low_free"]`), h.bodies[0])
		testing.expect(t, strings.contains(h.bodies[0], `"forecast_days":null`), h.bodies[0])
	}
	h.answer = "HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n"
	sync.unlock(&h.mutex)

	// A webhook that refuses fails the run, but the scan stays kept.
	testing.expect_value(
		t,
		run_sonar(dir, "--keep", "--history", db, "--alert-free", "100", "--webhook", url),
		schedule.EXIT_FAILED,
	)
	testing.expect_value(t, len(kept(t, db, dir)), 2)
}
