package leita_app

import "base:runtime"

import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:testing"
import "core:time"

import "jm:debug"
import "jm:stream"
import "jm:ui"
import bl "jm:ui/blend2d"

import "../../scan"
import netfault "../../faults/net"
import "../command"
import "../msg"
import "../query"

// The host on its own, asked as the frame loop asks: a need made from a query,
// its answers taken out of the inbox and decoded.

@(private = "file")
ask :: proc(h: ^Host, q: $Q, added := true) -> ui.Need_Key {
	bytes, err := cbor.marshal_into_bytes(
		q,
		allocator = context.temp_allocator,
		temp_allocator = context.temp_allocator,
	)
	assert(err == nil)
	named := type_info_of(Q).variant.(runtime.Type_Info_Named)
	kind := fmt.tprintf("%s.%s", named.pkg, named.name)
	need := ui.Need {
		key   = ui.need_key(kind, bytes),
		kind  = kind,
		query = bytes,
	}
	on_need(h, need, added)
	return need.key
}

// answer_to waits for the next answer to key that ok says is the one wanted,
// decoding each, and gives it; false if none comes in time.
@(private = "file")
answer_to :: proc(
	h: ^Host,
	key: ui.Need_Key,
	$R: typeid,
	ok: proc(r: ^R) -> bool,
	within := 30 * time.Second,
) -> (
	r: R,
	found: bool,
) {
	deadline := time.tick_now()._nsec + i64(within)
	for time.tick_now()._nsec < deadline {
		for d in ui.inbox_take(&h.inbox) {
			if d.key != key {
				continue
			}
			got: R
			if cbor.unmarshal_from_bytes(d.data, &got, allocator = context.temp_allocator) ==
				   nil &&
			   ok(&got) {
				return got, true
			}
		}
		time.sleep(time.Millisecond)
	}
	return {}, false
}

@(private = "file")
progress_done :: proc(r: ^query.Progress_Result) -> bool {
	return r.state == .Done
}

@(private = "file")
complete :: proc(r: ^query.Search_Result) -> bool {
	return r.complete
}

/*
	<root>/src/main.odin
	<root>/src/domain.c
	<root>/main/notes.txt
	<root>/readme
*/
@(private = "file")
search_fixture :: proc(t: ^testing.T, name: string) -> string {
	dir, _ := os.temp_directory(context.temp_allocator)
	info, _ := os.stat(dir, context.temp_allocator)
	root := fmt.tprintf("%s/leita_search_%s_%d", info.fullpath, name, os.get_pid())
	os.remove_all(root)
	for d in ([]string{"", "/src", "/main"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s%s", root, d)) == nil)
	}
	for f in ([]string{"/src/main.odin", "/src/domain.c", "/main/notes.txt", "/readme"}) {
		body := make([]byte, 1024 * (1 + len(f)), context.temp_allocator)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s%s", root, f), body) == nil)
	}
	return stored_path(root)
}

// A search of a finished scan answers its best hits first, each with its
// path, where its name starts and what matched, and a need that goes calls
// its search off.
@(test)
a_search_answers_ranked_hits_with_what_matched :: proc(t: ^testing.T) {
	// Heap copies: the temp drop below is the frame freeing its allocator,
	// and the fixture path has to outlive that.
	root := strings.clone(search_fixture(t, "ranked"))
	defer delete(root)
	defer os.remove_all(root)
	thumbs := strings.clone(fmt.tprintf("%s-thumbs", root))
	defer delete(thumbs)
	defer os.remove_all(thumbs)
	h: Host
	init(&h, root, thumbs = thumbs)
	defer stop(&h)

	prog, done := answer_to(&h, ask(&h, query.Progress{}), query.Progress_Result, progress_done)
	testing.expect(t, done, "the scan finished")
	generation := prog.generation

	key := ask(&h, query.Search{generation = generation, term = "main"})
	// on_need unmarshals the term into the frame's temp allocator, and the
	// frame frees that before the desk reads it. Drop it before waiting.
	free_all(context.temp_allocator)
	r, ok := answer_to(&h, key, query.Search_Result, complete)
	testing.expect(t, ok, "the search was answered, complete")
	testing.expect_value(t, r.term, "main")
	names := make([dynamic]string, context.temp_allocator)
	for hit in r.hits {
		append(&names, hit.path[hit.name_at:])
	}
	testing.expectf(
		t,
		slice.equal(names[:], []string{"main", "main.odin", "domain.c", "notes.txt"}),
		"hits %v",
		names,
	)
	testing.expect_value(t, r.total, 4)
	if len(r.hits) == 4 {
		notes := r.hits[3]
		// The tree spells a path with scan.SEPARATOR throughout, the root's own
		// separators included, where the fixture joined with a slash.
		S :: scan.SEPARATOR
		want := fmt.tprintf("%s%smain%snotes.txt", root, S, S)
		want, _ = strings.replace_all(want, "/", S, context.temp_allocator)
		testing.expect_value(t, notes.path, want)
		testing.expect_value(t, len(notes.marks), 1)
		testing.expect_value(t, notes.path[notes.marks[0].from:notes.marks[0].to], "main")
		testing.expect(t, r.hits[0].directory)
		testing.expect(t, notes.bytes > 0, "a file's size")
		testing.expect_value(t, r.hits[0].bytes, notes.bytes) // main/ holds only notes.txt
	}

	// A term of another scan's generation is answered empty, and complete.
	stale, stale_ok := answer_to(
		&h,
		ask(&h, query.Search{generation = generation + 1, term = "main"}),
		query.Search_Result,
		complete,
	)
	testing.expect(t, stale_ok && len(stale.hits) == 0, "another generation finds nothing")

	ask(&h, query.Search{generation = generation, term = "main"}, added = false)
	time.sleep(50 * time.Millisecond)
	testing.expect_value(t, len(h.desk.findings), 1)
}

// A need that cannot enter the pipeline retains no owned term at the sender.
@(test)
a_search_refused_by_a_closed_port_keeps_no_term :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	context.allocator = debug.allocator(&da)
	thumbs := strings.clone(search_fixture(t, "closed-search-port"))
	defer delete(thumbs)
	defer os.remove_all(thumbs)
	h: Host
	init(&h, "", thumbs = thumbs)
	stream.port_close(h.need_port)
	before := debug.snapshot(&da)
	ask(&h, query.Search{term = "main"})
	stop(&h)
	testing.expect(t, debug.expect_released(&da, before), "a refused need frees its sender-owned term")
	testing.expect_value(t, debug.issue_count(&da), 0)
}

// Stop the pool before adding needs so their ownership is still in the raw
// inlet when shutdown begins. Add/drop ordering and a term still live at exit
// must both release their copies, even after the frame storage has been reset.
@(test)
queued_search_terms_are_freed_when_the_host_stops :: proc(t: ^testing.T) {
	da: debug.Allocator
	debug.init(&da, context.allocator)
	defer debug.destroy(&da)
	frame_heap: debug.Allocator
	debug.init(&frame_heap, context.allocator)
	defer debug.destroy(&frame_heap)
	context.allocator = debug.allocator(&da)
	thumbs := strings.clone(search_fixture(t, "queued-search-stop"))
	defer delete(thumbs)
	defer os.remove_all(thumbs)
	h: Host
	init(&h, "", thumbs = thumbs)
	stream.stop(h.p)
	began := time.tick_now()
	for !thread.is_done(h.pool) && time.tick_since(began) < 5 * time.Second {
		thread.yield()
	}
	if !testing.expect(t, thread.is_done(h.pool), "the pool stopped before the queued needs") {
		stop(&h)
		return
	}
	before := debug.snapshot(&da)
	// The frame's heap may differ from the desk's: needs must use the host's
	// persistent allocator, not whichever allocator the current frame has.
	context.allocator = debug.allocator(&frame_heap)
	ask(&h, query.Search{term = "main"})
	ask(&h, query.Search{term = "notes"})
	ask(&h, query.Search{term = "main"}, added = false)
	context.allocator = debug.allocator(&da)
	free_all(context.temp_allocator)
	stop(&h)
	testing.expect(t, debug.expect_released(&da, before), "queued, dropped and live-at-exit terms are released")
	testing.expect_value(t, debug.issue_count(&da), 0)
	testing.expect_value(t, debug.issue_count(&frame_heap), 0)
}

// The final ownership drain must not start new work after its clients were
// stopped. Keep the callback's fixture port alive independently, so a restarted
// client can be detected and joined without using the destroyed host pipeline.
@(test)
stopping_with_queued_searches_does_not_start_an_activation :: proc(t: ^testing.T) {
	srv := netfault.start(.Stall_Head)
	defer netfault.stop(srv)
	replies := stream.make_pipeline(context.allocator)
	defer stream.destroy(replies)
	_, reply_port := stream.port(replies, Activated, cap = 4)
	thumbs := strings.clone(search_fixture(t, "search-stop-command"))
	defer delete(thumbs)
	defer os.remove_all(thumbs)
	h: Host
	init(&h, "", thumbs = thumbs, activate_url = netfault.url(srv, "/activate"))
	stream.stop(h.p)
	began := time.tick_now()
	for !thread.is_done(h.pool) && time.tick_since(began) < 5 * time.Second {
		thread.yield()
	}
	if !testing.expect(t, thread.is_done(h.pool), "the pool stopped before queued input") {
		stop(&h)
		return
	}
	h.desk.activations = &reply_port
	ask(&h, query.Search{term = "main"})
	send(&h, command.Command(command.Add_Licence{text = command.text_make("queued-at-close")}))
	stop(&h)
	restarted := h.desk.client != nil
	licence_stop(&h.desk)
	testing.expect(t, !restarted, "the ownership drain must not restart the activation client")
}

// A picture's thumbnail is made off the desk, kept by its path and time, and
// made once.
@(test)
a_thumbnail_is_made_once_and_kept :: proc(t: ^testing.T) {
	root := search_fixture(t, "thumbs")
	defer os.remove_all(root)
	thumbs := fmt.tprintf("%s-thumbs", root)
	defer os.remove_all(thumbs)

	picture := fmt.tprintf("%s/wide.png", root)
	img: bl.ImageCore
	bl.image_init(&img)
	testing.expect(t, bl.image_create(&img, 64, 32, .PRGB32) == 0)
	cpath := fmt.ctprintf("%s", picture)
	testing.expect(t, bl.image_write_to_file(&img, cpath, nil) == 0)
	bl.image_destroy(&img)

	h: Host
	init(&h, root, thumbs = thumbs)
	defer stop(&h)
	has_image :: proc(r: ^query.Thumb_Result) -> bool {return r.image != ""}
	r, ok := answer_to(
		&h,
		ask(&h, query.Thumb{path = picture, px = 16}),
		query.Thumb_Result,
		has_image,
	)
	testing.expect(t, ok, "a thumbnail was made")
	testing.expect(t, strings.has_prefix(r.image, thumbs), "in the thumbnail folder")
	square: bl.ImageCore
	bl.image_init(&square)
	testing.expect(t, bl.image_read_from_file(&square, fmt.ctprintf("%s", r.image), nil) == 0)
	size: bl.ImageData
	bl.image_get_data(&square, &size)
	testing.expect_value(t, size.size.w, 16)
	testing.expect_value(t, size.size.h, 16)
	bl.image_destroy(&square)
	made, _ := os.stat(r.image, context.temp_allocator)

	// Asked again in another need, it is the same file, not made again - only
	// touched, so thumbs_prune reads the hit as just used rather than stale.
	ask(&h, query.Thumb{path = picture, px = 16}, added = false)
	time.sleep(20 * time.Millisecond)
	again, again_ok := answer_to(
		&h,
		ask(&h, query.Thumb{path = picture, px = 16}),
		query.Thumb_Result,
		has_image,
	)
	testing.expect(t, again_ok)
	testing.expect_value(t, again.image, r.image)
	kept, _ := os.stat(again.image, context.temp_allocator)
	testing.expect(
		t,
		time.diff(made.modification_time, kept.modification_time) > 0,
		"a hit touches the file forward",
	)

	// What is not a picture has none.
	none :: proc(r: ^query.Thumb_Result) -> bool {return r.image == ""}
	_, empty := answer_to(
		&h,
		ask(&h, query.Thumb{path = fmt.tprintf("%s/readme", root), px = 16}),
		query.Thumb_Result,
		none,
	)
	testing.expect(t, empty, "a file that is not a picture has no thumbnail")
}

// An entry the system would not open comes back from its worker as a notice,
// in the window's language.
@(test)
an_entry_not_opened_is_said_in_a_notice :: proc(t: ^testing.T) {
	words := new(msg.Strings)
	defer free(words)
	msg.init(words, .German)
	d := Desk {
		words = words,
	}
	defer delete(d.notice.text)
	desk_step(&d, Open_Failure{name = command.text_make("Urlaub.mov")})
	testing.expect(t, d.notice.failed)
	testing.expect_value(t, d.notice.text, "Urlaub.mov konnte nicht geöffnet werden")
}
