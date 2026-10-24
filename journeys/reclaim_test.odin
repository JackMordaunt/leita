package journeys

import "core:encoding/json"
import "core:strings"
import "core:testing"

// A person asks what can be deleted and made again, and gets it in the report.
@(test)
reclaim_lists_what_can_be_made_again_and_only_when_asked :: proc(t: ^testing.T) {
	h := home(t, "reclaim")
	defer leave(h)

	r := run(t, h, 0, "--no-history", "--report", "-", "--format", "json", "/Users/alex")
	expect_code(t, r, 0)
	_, plain := report(t, r.out)["reclaim"].(json.Null)
	testing.expect(t, plain, "a report not asked for reclaim carries it")

	r = run(
		t,
		h,
		0,
		"--no-history",
		"--reclaim",
		"--report",
		"-",
		"--format",
		"json",
		"/Users/alex",
	)
	expect_code(t, r, 0)
	reclaim := member(report(t, r.out), "reclaim")
	total := whole(reclaim, "bytes")
	testing.expect(t, total > 0, "the made-up disk has dependencies and caches to reclaim")

	groups, _ := reclaim["groups"].(json.Array)
	testing.expect(t, len(groups) > 0, "no group of what can be reclaimed")
	sum, seen: i64
	for g in groups {
		group, _ := g.(json.Object)
		sum += whole(group, "bytes")
		if text(group, "category") == "dependencies" {
			seen += 1
			items, _ := group["items"].(json.Array)
			testing.expect(t, len(items) > 0, "dependencies without an item")
			first, _ := items[0].(json.Object)
			path := text(first, "path")
			testing.expectf(
				t,
				strings.has_suffix(path, "/node_modules"),
				"a dependency at %q",
				path,
			)
			testing.expect(t, strings.has_prefix(path, "/Users/alex/"), path)
		}
		testing.expectf(
			t,
			text(group, "reason") != "",
			"group %q has no reason",
			text(group, "name"),
		)
	}
	testing.expect_value(t, seen, 1)
	testing.expect_value(t, sum, total)
	testing.expect(
		t,
		total < whole(member(report(t, r.out), "totals"), "bytes"),
		"more to reclaim than there is",
	)
}
