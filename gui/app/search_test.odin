package leita_app

import "base:runtime"

import "core:encoding/cbor"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "jm:ui"
import bl "jm:ui/blend2d"

import "../../scan"
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
	root := search_fixture(t, "ranked")
	defer os.remove_all(root)
	h: Host
	init(&h, root, thumbs = fmt.tprintf("%s-thumbs", root))
	defer stop(&h)
	defer os.remove_all(fmt.tprintf("%s-thumbs", root))

	prog, done := answer_to(&h, ask(&h, query.Progress{}), query.Progress_Result, progress_done)
	testing.expect(t, done, "the scan finished")

	key := ask(&h, query.Search{generation = prog.generation, term = "main"})
	r, ok := answer_to(&h, key, query.Search_Result, complete)
	testing.expect(t, ok, "the search was answered, complete")
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
		ask(&h, query.Search{generation = prog.generation + 1, term = "main"}),
		query.Search_Result,
		complete,
	)
	testing.expect(t, stale_ok && len(stale.hits) == 0, "another generation finds nothing")

	ask(&h, query.Search{generation = prog.generation, term = "main"}, added = false)
	time.sleep(50 * time.Millisecond)
	testing.expect_value(t, len(h.desk.findings), 1)
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
