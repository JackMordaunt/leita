package journeys_gui

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:http/loopback"
import "jm:ui"

import "../../gui/view"

/*
Shop stands in for the licence server: it sells one key, LEITA-SOLD, whose
licence is line, signed by the test key the journeys are built with; any other
key it never sold. It counts what it was asked.
*/
Shop :: struct {
	line:  string, // in the heap, for the server's thread
	asked: int, // atomic
}

answer_shop :: proc(conn: ^loopback.Conn, req: loopback.Request) {
	s := (^Shop)(conn.server.user)
	sync.atomic_add(&s.asked, 1)
	switch {
	case req.method == "POST" &&
	     req.path == "/activate" &&
	     strings.contains(req.body, `"key":"LEITA-SOLD"`):
		body := strings.concatenate({`{"licence":"`, s.line, `"}`}, context.temp_allocator)
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
				len(body),
				body,
			),
		)
	case req.method == "POST" && req.path == "/activate":
		refusal := `{"error":"unknown","message":"This licence key is not one the shop sold."}`
		loopback.send(
			conn,
			fmt.tprintf(
				"HTTP/1.1 404 Not Found\r\nContent-Length: %d\r\n\r\n%s",
				len(refusal),
				refusal,
			),
		)
	case:
		loopback.send(conn, "HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n")
	}
}


/*
Story: a person on the 30-day evaluation keeps Pro by buying a licence. During
the evaluation the licence dialog says the days left. A month on the window says
it has ended, and a PDF report is refused while a JSON one is still free. Buy a
licence opens the shop's page; the key from the receipt is exchanged at the shop
(a local stand-in, never the real one), a key it never sold is refused with its
reason, and the window says who it is licensed to. The PDF is written, and the
next run is still licensed without asking the shop again.
*/
@(test)
a_trial_is_bought_and_activated :: proc(t: ^testing.T) {
	budget(t, 240)
	line := os.get_env("LEITA_TEST_LICENCE", context.temp_allocator)
	if !testing.expect(
		t,
		line != "",
		"just journeys passes LEITA_TEST_LICENCE, the line the test key signed",
	) {
		return
	}
	shop := Shop {
		line = strings.clone(line),
	}
	defer delete(shop.line)

	srv, up := loopback.start(answer_shop, &shop)
	if !testing.expect(t, up, "the shop's stand-in started") {
		return
	}
	defer loopback.stop(srv)

	activate := loopback.url(srv, "/activate")
	dir := folder("licence")
	defer forget(dir)

	{
		w: Window
		open(&w, t, "trial", 0, dir = dir, activate_url = activate)
		defer close(&w, keep = true)

		testing.expect(t, settle(&w, "Done"))
		open_licence(t, &w)
		testing.expectf(
			t,
			settle(&w, "You can try Pro for 30 more days."),
			"the evaluation says its days:\n%s",
			show(&w),
		)
		keep(&w, "evaluating")
	}

	// A month later.
	month := time.to_unix_seconds(time.now()) - 31 * 24 * 60 * 60
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/first-use", dir), fmt.tprintf("%d\n", month)) == nil,
	)
	{
		w: Window
		open(&w, t, "trial-ended", 0, dir = dir, activate_url = activate)
		defer close(&w, keep = true)

		testing.expect(t, settle(&w, "Done"))
		testing.expectf(
			t,
			settle(&w, tr(&w, .Trial_Ended_Title)),
			"the window says the evaluation ended:\n%s",
			show(&w),
		)
		keep(&w, "ended")

		// Contents is answered again once the banner has moved it.
		testing.expectf(
			t,
			settle_said(&w, `text "320.8 GB in 17 items"`, seconds = 15),
			"Contents says the whole scan:\n%s",
			show(&w),
		)

		// A JSON of this scan is still free.
		free, saved := export_json(t, &w, "free.json")
		if saved {
			note, _ := free["generated_by"].(json.String)
			testing.expectf(
				t,
				strings.contains(note, "Free export"),
				"the JSON says it is the free one: %s",
				note,
			)
		}

		// A PDF asks for a licence: the licence dialog opens and says why.
		testing.expect(t, click(&w, "Settings"))
		testing.expect(t, click_top(&w, "Export"), "the menu offers Export")
		frames(&w, 10)
		testing.expect(t, click(&w, "PDF"))
		testing.expect(t, click_top(&w, "Export"), "the dialog's Export")
		frames(&w, 20)
		_, asked_where := ui.probe_picking(&w.p)
		testing.expect(t, !asked_where, "no save dialog for a locked PDF")
		testing.expectf(
			t,
			settle_said(&w, `dialog "Licence" modal`, seconds = 10) &&
			settle(&w, tr(&w, .Reports_Locked), seconds = 10),
			"the licence dialog says a PDF needs a licence:\n%s",
			show(&w),
		)
		keep(&w, "pdf-locked")

		testing.expect(t, click_top(&w, "Buy a licence"))
		frames(&w, 2)
		testing.expect_value(t, ui.probe_opened_url(&w.p), view.BUY_URL)

		offer(t, &w, "LEITA-NEVER-SOLD")
		testing.expectf(
			t,
			settle(&w, "This licence key is not one the shop sold."),
			"a key the shop never sold is refused with its reason:\n%s",
			show(&w),
		)
		offer(t, &w, "LEITA-SOLD")
		testing.expectf(
			t,
			settle(&w, "Licensed to test@leita.example"),
			"the key brings its licence:\n%s",
			show(&w),
		)
		keep(&w, "licensed")
		ui.probe_key(&w.p, .Escape)
		frames(&w, 20)
		testing.expectf(
			t,
			settle(&w, tr(&w, .Trial_Ended_Title), present = false),
			"the banner goes:\n%s",
			show(&w),
		)

		pdf := fmt.tprintf("%s/report.pdf", dir)
		testing.expect(t, click(&w, "Settings"))
		testing.expect(t, click_top(&w, "Export"), "the menu offers Export")
		frames(&w, 10)
		testing.expect(t, click(&w, "PDF"))
		testing.expect(t, click_top(&w, "Export"), "the dialog's Export")
		_, asked_where = ui.probe_picking(&w.p)
		testing.expect(t, asked_where, "licensed, the PDF asks where to save")
		testing.expect(t, ui.probe_pick(&w.p, pdf))
		frames(&w, 2)
		testing.expectf(
			t,
			settle(&w, fmt.tprintf("Saved report to %s", pdf)),
			"the PDF is saved:\n%s",
			show(&w),
		)
		body, _ := os.read_entire_file(pdf, context.temp_allocator)
		testing.expect(t, strings.has_prefix(string(body), "%PDF-"), "and is a PDF")
	}
	asked := sync.atomic_load(&shop.asked)

	w: Window
	open(&w, t, "licensed", 0, dir = dir, activate_url = activate)
	defer close(&w, keep = true)

	testing.expect(t, settle(&w, "Done"))
	testing.expectf(
		t,
		settle(&w, tr(&w, .Trial_Ended_Title), present = false),
		"no banner:\n%s",
		show(&w),
	)
	open_licence(t, &w)
	testing.expectf(
		t,
		settle(&w, "Licensed to test@leita.example"),
		"still licensed:\n%s",
		show(&w),
	)
	testing.expect_value(t, sync.atomic_load(&shop.asked), asked)
}

// open_licence opens the licence dialog from the settings menu. The item asks
// the host for the licence as the menu opens, so the click waits for its answer.
open_licence :: proc(t: ^testing.T, w: ^Window) {
	testing.expect(t, click(w, "Settings"))
	frames(w, 10)
	testing.expectf(
		t,
		settle(w, "Licence", seconds = 10),
		"the menu offers the licence:\n%s",
		show(w),
	)
	testing.expect(t, click_top(w, "Licence"))
	frames(w, 20)
}

// offer types text into the licence dialog's field and adds it.
offer :: proc(t: ^testing.T, w: ^Window, text: string) {
	ui.text_set(&w.m.licence_text, "")
	testing.expect(t, click(w, "Licence to add"))
	ui.probe_type(&w.p, text)
	frames(w, 2)
	testing.expect(t, click_top(w, "Add licence"))
}
