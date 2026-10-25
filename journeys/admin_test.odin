package journeys

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "../settings"

/*
Story: an admin watches a server's disk and is warned before it fills. They
watch two places, one with a warning at 60% used and one at 80%, and send alerts
to a webhook. A monitoring run, the one the scheduler starts each hour, finds the
disk 69% used: the first place raises an alert, shown in the list and sent to the
webhook, signed and naming the place and its measure; the second stays quiet. A
second run raises the same alert no more.

Each place is scanned as the made-up disk (LEITA_SYNTHETIC), whose use is known.
Monitoring is turned on in the settings store directly: monitor on hands the run
to the system's scheduler, which a journey must not change.
*/
@(test)
a_server_is_watched_and_warned_before_it_fills :: proc(t: ^testing.T) {
	h := home(t, "admin")
	defer leave(h)
	server := start_receiver(t)
	defer stop_receiver(server)

	tight := file_in(h, "var")
	loose := file_in(h, "srv")
	for place in ([]string{tight, loose}) {
		testing.expect(t, os.make_directory(place) == nil, "could not make the place to watch")
	}
	expect_code(t, run(t, h, -1, "monitor", "add", tight, "--warn-used", "60"), 0)
	expect_code(t, run(t, h, -1, "monitor", "add", loose, "--warn-used", "80"), 0)
	url := address(server, "/alerts")
	expect_code(t, run(t, h, -1, "monitor", "webhook", "add", url), 0)
	turn_monitoring_on(t, h)

	r := run(t, h, 0, "monitor", "run", "--all")
	expect_code(t, r, 0)
	testing.expectf(
		t,
		strings.contains(r.out, "var: alert: The disk under ") &&
		strings.contains(r.out, " is 69.5% used, past the warning at 60%."),
		"the place watched at 60%% is warned:\n%s",
		r.out,
	)
	testing.expectf(
		t,
		!strings.contains(r.out, "srv: alert"),
		"the place at 80%% is not:\n%s",
		r.out,
	)
	testing.expectf(
		t,
		strings.contains(r.out, "webhooks: 1 delivered, 0 to try again, 0 dropped"),
		"the alert went to the webhook:\n%s",
		r.out,
	)

	r = run(t, h, 0, "monitor", "list")
	expect_code(t, r, 0)
	testing.expectf(
		t,
		strings.contains(r.out, "alerts on 60% used") &&
		strings.contains(r.out, "alerts on 80% used"),
		"the list says each place's limit:\n%s",
		r.out,
	)
	testing.expectf(
		t,
		strings.count(r.out, "alert: The disk under ") == 1,
		"the list keeps the one alert:\n%s",
		r.out,
	)

	sent := requests(server)
	if testing.expect_value(t, len(sent), 1) {
		head, body := sent[0].head, sent[0].body
		testing.expect(t, strings.has_prefix(head, "POST /alerts "), head)
		testing.expect_value(t, header(head, "X-Leita-Event"), "warn_used")
		testing.expect(t, strings.has_prefix(header(head, "X-Leita-Signature"), "sha256="), head)
		event := report(t, body)
		testing.expect_value(t, text(event, "event"), "warn_used")
		testing.expect(t, strings.has_suffix(text(event, "place"), "var"), body)
		measure := member(event, "measure")
		used, _ := measure["used_percent"].(json.Float)
		limit, _ := measure["limit"].(json.Float)
		testing.expectf(t, used > 69.4 && used < 69.5, "the measure says 69.5%% used: %v", used)
		testing.expect_value(t, limit, 60)
		summary := member(event, "summary")
		testing.expect_value(t, whole(member(summary, "totals"), "bytes"), 320838590464)
	}

	// The next hour's run scans again, and raises the same alert no more.
	r = run(t, h, 0, "monitor", "run", "--all")
	expect_code(t, r, 0)
	testing.expectf(t, !strings.contains(r.out, "alert:"), "nothing new is raised:\n%s", r.out)
	testing.expect_value(t, len(requests(server)), 1)
}

// turn_monitoring_on keeps monitoring on in h's settings, as monitor on does
// once the scheduler has taken the run.
turn_monitoring_on :: proc(t: ^testing.T, h: Home) {
	st: settings.Store
	path := strings.concatenate({data(h), "/", settings.FILE}, context.temp_allocator)
	if !testing.expectf(t, settings.open(&st, path) == nil, "could not open %s", path) {
		return
	}
	defer settings.close(&st)

	testing.expect(t, settings.set_monitoring(&st, true) == nil, "could not turn monitoring on")
}
