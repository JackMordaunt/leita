package journeys

import "core:os"
import "core:strings"
import "core:testing"

// Once the evaluation has ended a licence is what keeps Pro: it is checked, kept
// beside the data, shown, found by the next run, and forgotten when removed.
@(test)
a_licence_added_keeps_pro_until_it_is_removed :: proc(t: ^testing.T) {
	if licence_line() == "" {
		testing.fail_now(
			t,
			"no licence to add: run the journeys with just journeys, which builds the binary to take it",
		)
	}
	h := home(t, "licence")
	defer leave(h)

	end_evaluation(t, h)

	r := run(t, h, 0, "licence")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)
	r = run(t, h, -1, "monitor", "add", h.dir)
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.out, "need a licence"), r.out)

	// What is not a licence is refused, and nothing is kept.
	r = run(t, h, 0, "licence", "add", "leita.garbage")
	expect_code(t, r, 1)
	testing.expect(t, strings.contains(r.err, "not a leita licence"), r.err)
	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)

	r = run(t, h, 0, "licence", "add", licence_line())
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "added the licence"), r.out)
	testing.expect(t, strings.contains(r.out, "test@leita.example"), r.out)

	r = run(t, h, 0, "licence")
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "licensed   to test@leita.example"), r.out)
	testing.expect(t, strings.contains(r.out, "tier       Personal"), r.out)
	testing.expect(t, strings.contains(r.out, "paid       9999-12-31T23:59:59Z"), r.out)
	testing.expect(t, strings.contains(r.out, "pro        this release is included"), r.out)

	// Pro works again: a scheduled scan may be set up and an html report written.
	r = run(t, h, -1, "monitor", "add", h.dir)
	expect_code(t, r, 0)
	r = run(t, h, 0, "--no-history", "--report", file_in(h, "r.html"), "/Users/alex")
	expect_code(t, r, 0)
	testing.expect(t, os.exists(file_in(h, "r.html")), "the html report was not written")

	r = run(t, h, 0, "licence", "remove")
	expect_code(t, r, 0)
	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)
	r = run(t, h, -1, "monitor", "add", h.dir)
	expect_code(t, r, 1)
}

// A licence held for one run through LEITA_LICENCE is used for that run and kept
// nowhere.
@(test)
a_licence_in_the_environment_serves_one_run :: proc(t: ^testing.T) {
	if licence_line() == "" {
		testing.fail_now(
			t,
			"no licence to add: run the journeys with just journeys, which builds the binary to take it",
		)
	}
	h := home(t, "licence_env")
	defer leave(h)

	end_evaluation(t, h)

	given := []string {
		strings.concatenate({"LEITA_LICENCE=", licence_line()}, context.temp_allocator),
	}
	r := run(t, h, 0, "licence", extra = given)
	expect_code(t, r, 0)
	testing.expect(t, strings.contains(r.out, "licensed   to test@leita.example"), r.out)
	r = run(t, h, -1, "monitor", "add", h.dir, extra = given)
	expect_code(t, r, 0)

	r = run(t, h, 0, "licence")
	testing.expect(t, strings.contains(r.out, "evaluation has ended"), r.out)
}
