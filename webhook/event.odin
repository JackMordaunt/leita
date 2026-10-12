package leita_webhook

import "core:fmt"
import "core:strings"
import "core:time"

import "../alert"
import "../report"

/*
An event is what one delivery tells: an alert a scheduled scan raised, or a
test the person asked for. Its body is one JSON object:

	schema    "leita.event/1"
	event     the alert's condition (alert.CONDITION_KEYS: "warn_used",
	          "fail_used", "low_free", "growth", "filling", "scan_failed"),
	          or "test"
	raised    when, ISO 8601 in UTC
	host      the machine's name, or null
	place     the place watched, as the person gave it; null for a test
	text      the alert in a sentence, in English, for a person
	measure   {"used_percent", "free", "total", "days", "grew", "limit"}:
	          what the alert measured, each 0 where it does not apply
	problem   why the scan failed, for scan_failed; else null
	summary   the scan, in the report schema (report/SCHEMA.md), or null for
	          a test or a failed scan. Its largest_directories and
	          largest_files are empty unless the webhook may carry folder
	          paths; the place itself is always named.
*/

// SCHEMA names what body writes; a change a reader of the last one would
// misread takes a new number.
SCHEMA :: "leita.event/1"

// TEST is the event a test delivery tells of.
TEST :: "test"

// Event is what one delivery tells.
Event :: struct {
	event:   string,
	raised:  time.Time,
	host:    string,
	place:   string,
	text:    string,
	measure: alert.Alert,
	problem: string,
	summary: string, // a report written as JSON, or "" for none
}

// body is e as the JSON a webhook is sent, in the temp allocator.
body :: proc(e: Event) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "{{\n  \"schema\": %q,\n  \"event\": ", SCHEMA)
	report.json_string(&sb, e.event)
	strings.write_string(&sb, ",\n  \"raised\": ")
	report.json_time(&sb, e.raised)
	strings.write_string(&sb, ",\n  \"host\": ")
	report.json_string_or_null(&sb, e.host)
	strings.write_string(&sb, ",\n  \"place\": ")
	report.json_string_or_null(&sb, e.place)
	strings.write_string(&sb, ",\n  \"text\": ")
	report.json_string(&sb, e.text)
	m := e.measure
	fmt.sbprintf(
		&sb,
		",\n  \"measure\": {{\"used_percent\": %.3f, \"free\": %d, \"total\": %d, \"days\": %.3f, \"grew\": %d, \"limit\": %.3f}}",
		m.used_percent,
		m.free,
		m.total,
		m.days,
		m.grew,
		m.limit,
	)
	strings.write_string(&sb, ",\n  \"problem\": ")
	report.json_string_or_null(&sb, e.problem)
	strings.write_string(&sb, ",\n  \"summary\": ")
	if e.summary == "" {
		strings.write_string(&sb, "null")
	} else {
		strings.write_string(&sb, strings.trim_space(e.summary))
	}
	strings.write_string(&sb, "\n}\n")
	return strings.to_string(sb)
}

/*
summary is a finished scan in the report schema, as an event carries it, in
the temp allocator: r with its largest directories and files left out unless
paths, so no folder path but the place's own leaves the machine without the
person's say.
*/
summary :: proc(r: ^report.Report, paths: bool) -> string {
	shown := r^
	if !paths {
		shown.largest_directories = nil
		shown.largest_files = nil
		shown.reclaim = nil
	}
	sb := strings.builder_make(context.temp_allocator)
	report.write_json(&sb, &shown)
	return strings.to_string(sb)
}
