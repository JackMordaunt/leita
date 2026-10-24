#+build !linux
package walk_fuzz

import "base:runtime"

// probe says why no tree can be made here. Mounts are Linux's.
probe :: proc(allocator := context.temp_allocator) -> (reason: string) {
	return "the materialiser makes mounts, which only Linux does here"
}

build :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	return probe(allocator)
}

destroy :: proc(fx: ^Fixture) {}

deny :: proc(fx: ^Fixture) -> (restore: proc(), ok: bool) {
	return nil, false
}

// allocated is what the files named by `nodes` occupy.
allocated :: proc(fx: ^Fixture, nodes: []int, allocator := context.temp_allocator) -> (bytes: u64, err: string) {
	return 0, probe(allocator)
}

// sizes_match is "" when each file is the size the spec says.
sizes_match :: proc(spec: Spec, fx: ^Fixture, allocator := context.temp_allocator) -> string {
	return ""
}

Churn :: struct {}

start_churn :: proc(fx: ^Fixture, ops: []Op, allocator: runtime.Allocator) -> ^Churn {
	return nil
}

release_churn :: proc(c: ^Churn) {}

churn_finished :: proc(c: ^Churn) -> bool {
	return true
}

finish_churn :: proc(fx: ^Fixture, c: ^Churn, allocator: runtime.Allocator) -> string {
	return probe(allocator)
}
