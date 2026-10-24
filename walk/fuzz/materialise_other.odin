#+build !linux
#+build !darwin
#+build !windows
package walk_fuzz

// probe says why no tree can be made here. Mounts are Linux's, macOS's and Windows'.
probe :: proc(allocator := context.temp_allocator) -> (reason: string) {
	return "the materialiser makes mounts, which only Linux, macOS and Windows do here"
}

fit :: proc(spec: Spec, allocator := context.temp_allocator) -> Spec {
	return spec
}

aliases :: proc(fx: ^Fixture, start: int, allocator := context.temp_allocator) -> []string {
	return nil
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

@(private)
do_op :: proc(m: ^Churn, op: Op) -> string {
	return probe()
}
