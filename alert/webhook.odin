package sonar_alert

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "jm:http"
import "jm:timefmt"

import "../human"

// DELIVERY_TIMEOUT is how long a webhook has to take a report.
DELIVERY_TIMEOUT :: 10 * time.Second

/*
Report is what a webhook is told when an alert fires. text is for a person, and
is the field Slack and Microsoft Teams incoming webhooks show; the rest is for a
program. taken is the scan's time in UTC, RFC 3339; forecast_days is null when
there is no forecast.
*/
Report :: struct {
	text:          string,
	host:          string,
	target:        string,
	free:          u64,
	total:         u64,
	forecast_days: Maybe(f64),
	alerts:        []string,
	taken:         string,
}

// report is what fired on target's scan at taken, on this host, in allocator.
report :: proc(
	host, target: string,
	taken: time.Time,
	reading: Reading,
	fired: Alerts,
	allocator := context.temp_allocator,
) -> Report {
	names := make([dynamic]string, allocator)
	for a in fired {
		append(&names, NAMES[a])
	}
	return Report {
		text = describe(host, target, reading, allocator),
		host = host,
		target = target,
		free = reading.disk.free,
		total = reading.disk.total,
		forecast_days = reading.forecast,
		alerts = names[:],
		taken = timefmt.iso(taken, allocator),
	}
}

// describe says in a line how full target's disk is and how soon it fills.
describe :: proc(
	host, target: string,
	reading: Reading,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	d := reading.disk
	fmt.sbprintf(
		&b,
		"sonar on %s: %s has %.1f%% free (%s of %s)",
		host,
		target,
		free_percent(d),
		human.bytes(d.free),
		human.bytes(d.total),
	)
	if days, ok := reading.forecast.?; ok {
		fmt.sbprintf(&b, "; at this rate it is full in %.0f days", days)
	}
	strings.write_byte(&b, '.')
	return strings.to_string(b)
}

// body is r as the JSON a webhook is sent, in allocator.
body :: proc(r: Report, allocator := context.temp_allocator) -> (string, bool) {
	data, err := json.marshal(r, {}, allocator)
	return string(data), err == nil
}

// deliver posts r to url as JSON, and says why it was not taken, or "".
deliver :: proc(url: string, r: Report, timeout := DELIVERY_TIMEOUT) -> string {
	data, ok := body(r)
	if !ok {
		return "the report could not be written as JSON"
	}
	res, err := http.post(
		url,
		data,
		"application/json",
		{timeout = timeout, user_agent = "sonar"},
		context.temp_allocator,
	)
	if err != .None {
		return fmt.tprintf("%v", err)
	}
	if !res.ok {
		return fmt.tprintf("HTTP %d", res.status)
	}
	return ""
}

// host_name is this machine's name, or "" when it cannot be found.
host_name :: proc(allocator := context.temp_allocator) -> string {
	when ODIN_OS == .Windows {
		return os.get_env("COMPUTERNAME", allocator)
	} else {
		data, err := os.read_entire_file("/proc/sys/kernel/hostname", context.temp_allocator)
		if err != nil {
			return ""
		}
		return strings.clone(strings.trim_space(string(data)), allocator)
	}
}
