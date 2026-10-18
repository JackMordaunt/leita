package leita_alert

import "core:strings"
import "core:testing"

import "../gui/msg"
import "../history"

@(private = "file")
GIB :: u64(1 << 30)

@(private = "file")
HOUR :: i64(60 * 60)

// MIB100 is a tenth of a GiB, near enough: 100 MiB.
@(private = "file")
MIB100 :: u64(100 << 20)

// day_by_day is a place scanned once a day for len(bytes) days, newest first as
// history.list gives them: its own size each day, on a 100 GiB disk whose used
// space is used[i], or 0 for a disk not known.
@(private = "file")
day_by_day :: proc(bytes: []u64, used: []u64 = nil) -> []history.Snapshot {
	out := make([]history.Snapshot, len(bytes), context.temp_allocator)
	for b, i in bytes {
		out[i] = {
			id    = i64(len(bytes) - i),
			taken = 1_800_000_000 - i64(i) * 24 * HOUR,
			bytes = b,
		}
		if used != nil {
			out[i].disk = {100 * GIB, 100 * GIB - used[i]}
		}
	}
	return out
}

@(test)
each_limit_crossed_is_an_alert_of_its_own :: proc(t: ^testing.T) {
	snaps := day_by_day({10 * GIB}, {92 * GIB})
	alerts := check({warn_used = 80, fail_used = 95, min_free = 10 * GIB}, snaps)
	testing.expect_value(t, conditions(alerts), Conditions{.Warn_Used, .Low_Free})
	testing.expect_value(t, alerts[0].used_percent, 92)
	testing.expect_value(t, alerts[0].limit, 80)
	testing.expect_value(t, alerts[1].free, 8 * GIB)
	testing.expect_value(t, alerts[1].limit, f64(10 * GIB))

	// Past the fail line is Fail_Used, not Warn_Used as well.
	snaps = day_by_day({10 * GIB}, {96 * GIB})
	testing.expect_value(
		t,
		conditions(check({warn_used = 80, fail_used = 95}, snaps)),
		Conditions{.Fail_Used},
	)
	testing.expect_value(t, conditions(check({}, snaps)), Conditions{}) // no limits, no alerts
	testing.expect_value(t, conditions(check({warn_used = 97}, snaps)), Conditions{})
	// A disk of unknown size is past no limit.
	testing.expect_value(
		t,
		conditions(check({warn_used = 1}, day_by_day({10 * GIB}))),
		Conditions{},
	)
}

@(test)
a_disk_filling_steadily_is_forecast_to_be_full :: proc(t: ^testing.T) {
	// 2 GiB more used each day, 90 GiB used now: 5 days left.
	used := []u64{90 * GIB, 88 * GIB, 86 * GIB, 84 * GIB}
	snaps := day_by_day({1, 1, 1, 1}, used)
	days, ok := forecast(snaps)
	testing.expect(t, ok)
	testing.expectf(t, days > 4.99 && days < 5.01, "%v days", days)
	alerts := check({full_within = 7}, snaps)
	testing.expect_value(t, conditions(alerts), Conditions{.Filling})
	testing.expect_value(t, alerts[0].limit, 7)
	testing.expect_value(t, conditions(check({full_within = 3}, snaps)), Conditions{})

	// Flat, falling, too few or too close together: no forecast.
	_, ok = forecast(day_by_day({1, 1, 1}, {50 * GIB, 50 * GIB, 50 * GIB}))
	testing.expect(t, !ok, "flat")
	_, ok = forecast(day_by_day({1, 1, 1}, {40 * GIB, 50 * GIB, 60 * GIB}))
	testing.expect(t, !ok, "falling")
	_, ok = forecast(day_by_day({1, 1}, {60 * GIB, 50 * GIB}))
	testing.expect(t, !ok, "two points")
	close := day_by_day({1, 1, 1}, {60 * GIB, 55 * GIB, 50 * GIB})
	for &s, i in close {
		s.taken = 1_800_000_000 - i64(i) * 60
	}
	_, ok = forecast(close)
	testing.expect(t, !ok, "minutes apart")
	// Snapshots that do not know their disk are left out.
	_, ok = forecast(day_by_day({1, 1, 1, 1}))
	testing.expect(t, !ok)
}

@(test)
growth_far_faster_than_usual_is_unusual :: proc(t: ^testing.T) {
	// 0.1 GiB a day for days, then 5 GiB in one.
	snaps := day_by_day(
		{
			25 * GIB + 4 * MIB100,
			20 * GIB + 4 * MIB100,
			20 * GIB + 3 * MIB100,
			20 * GIB + 2 * MIB100,
			20 * GIB + 1 * MIB100,
			20 * GIB,
		},
	)
	grew, unusual := unusual_growth(snaps)
	testing.expect(t, unusual)
	testing.expect_value(t, grew, 5 * GIB)
	alerts := check({growth = true}, snaps)
	testing.expect_value(t, conditions(alerts), Conditions{.Growth})
	testing.expect_value(t, conditions(check({}, snaps)), Conditions{}) // growth not asked for

	// The same 5 GiB on a place that grows 4 GiB a day is usual.
	steady := day_by_day({25 * GIB, 20 * GIB, 16 * GIB, 12 * GIB, 8 * GIB, 4 * GIB})
	_, unusual = unusual_growth(steady)
	testing.expect(t, !unusual)

	// Under the floor is never unusual, however fast.
	small := day_by_day({20 * GIB + 900 << 20, 20 * GIB, 20 * GIB, 20 * GIB, 20 * GIB})
	_, unusual = unusual_growth(small)
	testing.expect(t, !unusual, "under 1 GiB")

	// Too little history says nothing of what is usual.
	_, unusual = unusual_growth(day_by_day({30 * GIB, 20 * GIB, 20 * GIB, 20 * GIB}))
	testing.expect(t, !unusual, "three intervals, two of them earlier")
}

@(test)
what_fired_reads_back_from_the_run_log :: proc(t: ^testing.T) {
	ks := Conditions{.Warn_Used, .Filling, .Scan_Failed}
	testing.expect_value(t, keys(ks), "warn_used,filling,scan_failed")
	testing.expect_value(t, conditions_of(keys(ks)), ks)
	testing.expect_value(t, conditions_of(""), Conditions{})
	testing.expect_value(t, conditions_of("warn_used,someday"), Conditions{.Warn_Used})
}

@(test)
an_alert_is_said_in_the_language_asked_for :: proc(t: ^testing.T) {
	s := new(msg.Strings)
	defer free(s)
	msg.init(s, .English)
	a := Alert {
		kind         = .Warn_Used,
		used_percent = 91.24,
		limit        = 80,
	}
	testing.expect_value(
		t,
		say(s, a, "/srv"),
		"The disk under /srv is 91.2% used, past the warning at 80%.",
	)
	testing.expect_value(
		t,
		say(s, {kind = .Filling, days = 1.2}, "/srv"),
		"At this rate the disk under /srv is full in about 1 day.",
	)
	testing.expect_value(
		t,
		say(s, {kind = .Filling, days = 0.3}, "/srv"),
		"At this rate the disk under /srv is full within a day.",
	)
	testing.expect_value(
		t,
		say(s, {kind = .Scan_Failed}, "/srv", "cannot scan /srv: Not_Exist"),
		"The scan of /srv failed: cannot scan /srv: Not_Exist",
	)
	msg.use(s, .German)
	testing.expect_value(
		t,
		say(s, a, "/srv"),
		"Der Datenträger unter /srv ist zu 91.2% belegt, über der Warnschwelle von 80%.",
	)
}

@(test)
a_notification_reaches_each_desktop_with_nothing_in_it_run :: proc(t: ^testing.T) {
	title, body := "leita", `it's "full" \ $(rm -rf /)`

	linux := commands(.Freedesktop, title, body)
	testing.expect_value(t, len(linux), 2)
	testing.expect_value(t, linux[0][0], "notify-send")
	testing.expect_value(t, linux[0][len(linux[0]) - 1], body) // an argument, not a shell word
	testing.expect_value(t, linux[1][0], "gdbus")

	mac := commands(.Macos, title, body)
	testing.expect_value(
		t,
		mac[0][2],
		`display notification "it's \"full\" \\ $(rm -rf /)" with title "leita"`,
	)

	windows := commands(.Windows, title, `it's ‘it’`)
	script := windows[0][len(windows[0]) - 1]
	testing.expect(t, strings.contains(script, `CreateTextNode('it''s ‘‘it’’')`), script)
	// Leita's own id when the shell lists it, PowerShell's when it does not.
	testing.expect(t, strings.contains(script, `$app = '{1AC14E77`), script)
	testing.expect(t, strings.contains(script, `$_.AppID -eq 'Librium.Leita' }) { $app = 'Librium.Leita' }`), script)
	testing.expect(t, strings.contains(script, `CreateToastNotifier($app)`), script)

	// The next way is tried only when one does not run.
	Tried :: struct {
		n:  int,
		ok: int, // the try that runs
	}
	run   :: proc(argv: []string, user: rawptr) -> bool {
		tried := (^Tried)(user)
		tried.n += 1
		return tried.n == tried.ok
	}
	tried := Tried {
		ok = 2,
	}
	testing.expect(t, notify(.Freedesktop, title, body, run, &tried))
	testing.expect_value(t, tried.n, 2)
	tried = {
		ok = 0,
	}
	testing.expect(t, !notify(.Freedesktop, title, body, run, &tried), "neither ran")
}

// HOSTILE is a place that tries a notification: an OSC 52 write, a CSI colour, a
// line break, a right-to-left override, markup, an ampersand and a formula.
@(private = "file")
HOSTILE :: "=\x1b]52;c;ZXZpbA==\x07\x1b[31m\nname\u202E<img src=x> & \"q\" \\"

@(test)
a_notification_body_is_text_on_every_desktop :: proc(t: ^testing.T) {
	escaped :: "=\u241B]52;c;ZXZpbA==\u2407\u241B[31m\u240Aname\uFFFD&lt;img src=x&gt; &amp; \"q\" \\"

	// Freedesktop servers read the body as markup: notify-send's last argument and
	// gdbus's, the body ahead of its actions, hints and timeout.
	linux := commands(.Freedesktop, "leita", HOSTILE)
	testing.expect_value(t, linux[0][len(linux[0]) - 1], escaped)
	testing.expect_value(t, linux[1][len(linux[1]) - 4], escaped)
	for argv in linux {
		for arg in argv {
			testing.expect(t, !strings.contains_any(arg, "\x1b\x07\n\u202E"), arg)
		}
	}
	testing.expect_value(t, commands(.Freedesktop, "a", "a & b")[0][4], "a &amp; b")

	// AppleScript: the string has no line break to end it, and no control.
	mac := commands(.Macos, "leita", HOSTILE)[0][2]
	testing.expect_value(
		t,
		mac,
		"display notification \"=\u241B]52;c;ZXZpbA==\u2407\u241B[31m\\nname\uFFFD<img src=x> & \\\"q\\\" \\\\\" with title \"leita\"",
	)
	testing.expect(t, !strings.contains_any(mac, "\x1b\x07\n\r\u202E"), mac)

	// PowerShell: a single-quoted string expands nothing, and CreateTextNode takes
	// the markup as text; the control is pictured so the toast's XML stays valid.
	windows := commands(.Windows, "leita", HOSTILE)
	script := windows[0][len(windows[0]) - 1]
	testing.expect(
		t,
		strings.contains(
			script,
			"CreateTextNode('=\u241B]52;c;ZXZpbA==\u2407\u241B[31m\u240Aname\uFFFD<img src=x> & \"q\" \\')",
		),
		script,
	)
	testing.expect(t, !strings.contains_any(script, "\x1b\x07\n\u202E"), script)
}

@(test)
apple_quote_ends_no_string_early :: proc(t: ^testing.T) {
	testing.expect_value(t, apple_quote("a\nb\rc\td"), `"a\nb\rc\td"`)
	testing.expect_value(t, apple_quote("\x1b\x7f\x00"), "\"\u241B\u2421\u2400\"")
	testing.expect_value(t, apple_quote("a\xffb\u009b"), "\"a\uFFFDb\uFFFD\"")
	testing.expect_value(t, apple_quote(`"\`), `"\"\\"`)
}
