/*
Package alert is what a kept scan checks once it is kept: whether the disk it was
on has too little free, and whether, at the rate it has been filling, it will be
full too soon. The rate is a forecast drawn from the scans of the same place that
history kept. What fired is said in a Report, which a webhook can carry (webhook.odin).

Everything here but deliver is pure, so the tests need neither a disk nor a network.
*/
package sonar_alert

import "../history"

// FORECAST_MOST is how many of the newest snapshots a forecast draws its line through.
FORECAST_MOST :: 10

// FORECAST_LEAST is how few snapshots a forecast will draw a line through.
FORECAST_LEAST :: 3

// FORECAST_SPAN is the least time, in seconds, the snapshots must span: points
// minutes apart say more about one busy hour than about the disk.
FORECAST_SPAN :: 60 * 60

// DAY is a day in seconds.
DAY :: 24 * 60 * 60

// Rules is which alerts to check, each off at zero.
Rules :: struct {
	// Fire when less than this percent of the disk is free.
	free_below:  f64,
	// Fire when the forecast says the disk is full within this many days.
	full_within: f64,
}

// Alert is one thing a kept scan can find wrong.
Alert :: enum {
	Low_Free, // less is free than Rules.free_below
	Filling, // the forecast is full within Rules.full_within
}

Alerts :: bit_set[Alert]

// NAMES is each alert as a webhook names it.
NAMES := [Alert]string {
	.Low_Free = "low_free",
	.Filling  = "filling",
}

/*
forecast is how many days from the newest snapshot until its disk is full, at the
rate it has been filling: the least-squares line through used space (total less
free) against time, over the newest FORECAST_MOST snapshots that carry the disk.
snapshots is newest first, as history.list gives it. There is none when fewer than
FORECAST_LEAST carry the disk, when they span less than FORECAST_SPAN, or when used
space is flat or falling. Zero when the line says the disk is already full.
*/
forecast :: proc(snapshots: []history.Snapshot) -> (days: f64, ok: bool) {
	points: [FORECAST_MOST][2]f64 // seconds before the newest, bytes used
	n := 0
	newest: history.Snapshot
	for s in snapshots {
		if n == FORECAST_MOST {
			break
		}
		if s.disk.total == 0 || s.disk.free > s.disk.total {
			continue
		}
		if n == 0 {
			newest = s
		}
		points[n] = {f64(s.taken - newest.taken), f64(s.disk.total - s.disk.free)}
		n += 1
	}
	if n < FORECAST_LEAST || -points[n - 1][0] < FORECAST_SPAN {
		return 0, false
	}
	mean_t, mean_u: f64
	for p in points[:n] {
		mean_t += p[0]
		mean_u += p[1]
	}
	mean_t /= f64(n)
	mean_u /= f64(n)
	spread, together: f64
	for p in points[:n] {
		spread += (p[0] - mean_t) * (p[0] - mean_t)
		together += (p[0] - mean_t) * (p[1] - mean_u)
	}
	slope := together / spread // bytes a second
	if slope <= 0 {
		return 0, false
	}
	used_now := mean_u + slope * (0 - mean_t)
	left := f64(newest.disk.total) - used_now
	return max(left / slope / DAY, 0), true
}

// Reading is what the alerts are checked against: the disk as the scan found it,
// and the forecast, nil when there is none.
Reading :: struct {
	disk:     history.Disk,
	forecast: Maybe(f64),
}

// reading is the reading of a scan just kept: its disk, and the forecast from the
// snapshots of its place, newest first, the one just kept among them.
reading :: proc(disk: history.Disk, snapshots: []history.Snapshot) -> Reading {
	r := Reading {
		disk = disk,
	}
	if days, ok := forecast(snapshots); ok {
		r.forecast = days
	}
	return r
}

// evaluate is the alerts that rules fire on reading. A disk of unknown size
// fires nothing: there is nothing to measure free space against.
evaluate :: proc(rules: Rules, reading: Reading) -> (fired: Alerts) {
	d := reading.disk
	if rules.free_below > 0 && d.total > 0 && free_percent(d) < rules.free_below {
		fired += {.Low_Free}
	}
	if days, ok := reading.forecast.?; ok && rules.full_within > 0 && days <= rules.full_within {
		fired += {.Filling}
	}
	return
}

// free_percent is how much of the disk is free, out of 100; 0 for a disk of
// unknown size.
free_percent :: proc(d: history.Disk) -> f64 {
	if d.total == 0 {
		return 0
	}
	return 100 * f64(d.free) / f64(d.total)
}
