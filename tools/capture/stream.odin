package main

import "../../gui/query"
import "../../gui/view"
import "../../scan"
import "../../synth"
import "core:fmt"
import "core:sync"
import "core:time"
import "jm:ui"
import "jm:ui/render"

Stream_Clock  :: struct {
	enabled:         bool,
	total:           time.Duration,
	allowed, parked: i64,
	elapsed:         i64,
	nodes:           u64,
}
STREAM_FRAMES :: 840
stream_clock: Stream_Clock
current_model: ^view.Model
folder_node: u32
//review:ignore noun-for-type observed is a variable holding the latest progress record, not a type declaration.
observed: struct {
	nodes, bytes: u64,
	state:        query.State,
	seconds:      f64,
}

capture_view :: proc(gtx: ^ui.Ctx, user: rawptr) {
	view.view(gtx, user)
	current_model = (^view.Model)(user)
	if stream_clock.enabled {
		if r, _ := ui.need(
			gtx,
			query.Rings{generation = current_model.generation, dir = current_model.dir},
			query.Rings_Result,
		); r != nil {
			for a in r.arcs {if a.depth == 1 && a.directory && a.name == "Users" {folder_node = a.node}}
		}
	}
	if p, _ := ui.need(gtx, query.Progress{}, query.Progress_Result); p != nil {
		observed = {p.nodes, p.bytes, p.state, p.seconds}
	}
}

// The preflight measures the same walk's virtual cost, without opening any file.
stream_prepare :: proc() {
	cfg, on := synth.from_env()
	if !on {fail("-stream requires LEITA_SYNTHETIC")}
	tree: scan.Tree
	if scan.tree_init(&tree) != nil {fail("stream preflight allocation failed")}
	defer scan.tree_destroy(&tree)
	cfg.pace = false
	cfg.clock.wait = proc(_: ^scan.Tree, elapsed: time.Duration) {stream_clock.total = elapsed}
	if synth.read("/", &tree, cfg) != .None {fail("stream preflight failed")}
	stream_clock.enabled = true
	synth.clock_override = {
		wait    = stream_gate,
		elapsed = stream_elapsed,
	}
}

// Publish a completed directory, then wait for the film clock or cancellation.
stream_gate :: proc(tree: ^scan.Tree, elapsed: time.Duration) {
	sync.atomic_store(&stream_clock.nodes, sync.atomic_load(&tree.nodes_done))
	sync.atomic_store(&stream_clock.parked, i64(elapsed))
	for i64(elapsed) > sync.atomic_load(&stream_clock.allowed) && !scan.cancelled(tree) {
		time.sleep(time.Millisecond)
	}
}

// Release identical directory batches every three frames. The UI still receives
// the real host's progress and layout answers; zero-dt pumping waits for them
// without advancing animations or dropping any of their 30 fps movie frames.
stream_frame :: proc(m: ^Movie, h: ^render.Headless) {
	sync.atomic_store(
		&stream_clock.elapsed,
		i64(min(m.frame, STREAM_FRAMES)) * i64(time.Second) / 30,
	)
	if m.frame % 3 != 0 {return}
	target := i64(stream_clock.total) * i64(min(m.frame, STREAM_FRAMES)) / STREAM_FRAMES
	sync.atomic_store(&stream_clock.allowed, target)
	deadline := time.tick_now()._nsec + i64(30 * time.Second)
	for sync.atomic_load(&stream_clock.parked) <= target && m.frame < STREAM_FRAMES {
		if time.tick_now()._nsec >= deadline {fail("synthetic clock did not advance")}
		time.sleep(time.Millisecond)
	}
	nodes := sync.atomic_load(&stream_clock.nodes)
	ui.probe_set_dt(&h.p, 0)
	for observed.nodes < nodes || (m.frame >= STREAM_FRAMES && observed.state != .Done) {
		ui.probe_frame(&h.p)
		if time.tick_now()._nsec >= deadline {fail("synthetic view did not receive progress")}
		time.sleep(time.Millisecond)
	}
	fmt.printfln(
		"PROGRESS\t%d\t%d\t%d\t%v\t%.3f",
		m.frame,
		observed.nodes,
		observed.bytes,
		observed.state,
		observed.seconds,
	)
}

stream_elapsed :: proc() -> time.Duration {return time.Duration(
		sync.atomic_load(&stream_clock.elapsed),
	)}
