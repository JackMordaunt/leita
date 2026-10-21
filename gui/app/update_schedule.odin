package leita_app

import "core:fmt"
import "core:sync"
import "core:time"

import "../../licence"
import "../../settings"
import "../../update"
import "../query"

/*
Automatic release checks. Off until the person opts in, and an upgrade does
not opt them in: the setting is absent until they choose it. While it is on,
one check runs at startup and one a day for as long as this window stays
open. A check never installs. Two windows share one settings file, and the
one that records the check owns it.

Sleep and the wall clock are bounded. A sleep or a jump of several days
schedules one check, not one for each missed day, because the next decision
is measured from the time that check was recorded. A clock set backward does
not schedule a check until a monotonic day has passed, so it cannot spin.
*/

// DAY_SEC is one day on the wall clock. DAY_NS is one day of monotonic time.
DAY_SEC :: i64(24 * 60 * 60)
DAY_NS  :: DAY_SEC * i64(1_000_000_000)

// COALESCE_SEC is how recently another window's check counts as this
// window's startup check.
COALESCE_SEC :: i64(2 * 60)

// SKEW_SEC is how far ahead of this window another window's clock may be and
// still count as the same startup check.
SKEW_SEC :: i64(2 * 60)

// Due_Check is the automatic check that is due, if one is.
Due_Check :: enum u8 {
	None, // not due
	Startup, // this window's one startup check
	Daily, // the one check for this day
	Peer, // another window just checked; do not check, and count startup done
}

// Update_Time is a test clock: wall is Unix seconds, mono is a monotonic
// nanosecond count. The desk reads both with atomics. Nil means the real
// clocks. A test sets them before the window starts.
Update_Time :: struct {
	wall: i64,
	mono: i64,
}

// Moment is one decision. last_wall is 0 when no automatic check has been
// recorded. has_last_mono is whether last_mono is this window's own last
// automatic check; a zero last_mono is then a real value.
Moment :: struct {
	enabled:       bool,
	startup_done:  bool,
	last_wall:     i64,
	now_wall:      i64,
	has_last_mono: bool,
	last_mono:     i64,
	now_mono:      i64,
	opened_mono:   i64,
}

// due is the check to run at this moment. It does not record one: the caller
// does, and the next call sees that record, which is what keeps a long sleep
// or a clock jump to a single check.
due :: proc(m: Moment) -> Due_Check {
	if !m.enabled || m.now_wall <= 0 {
		return .None
	}
	if !m.startup_done {
		if m.last_wall > 0 {
			delta := m.now_wall - m.last_wall
			if delta >= 0 && delta < COALESCE_SEC {
				return .Peer
			}
			if delta < 0 && -delta < SKEW_SEC {
				return .Peer
			}
		}
		return .Startup
	}
	mono_base := m.last_mono if m.has_last_mono else m.opened_mono
	mono_since := m.now_mono - mono_base
	if m.last_wall <= 0 {
		if mono_since >= DAY_NS {
			return .Daily
		}
		return .None
	}
	wall_since := m.now_wall - m.last_wall
	if wall_since >= DAY_SEC {
		return .Daily
	}
	// The clock moved backward. Wait for a monotonic day so the same jump
	// cannot schedule a check on every tick.
	if wall_since < 0 && mono_since >= DAY_NS {
		return .Daily
	}
	return .None
}

// update_clock is the wall time, in Unix seconds, and a monotonic
// nanosecond count. The test clock wins when the desk has one.
update_clock :: proc(d: ^Desk) -> (wall, mono: i64) {
	if d.update_time != nil {
		return sync.atomic_load(&d.update_time.wall), sync.atomic_load(&d.update_time.mono)
	}
	return time.to_unix_seconds(time.now()), time.tick_now()._nsec
}

// update_consider runs the startup or daily check when one is due. It never
// installs. A check already running is left to finish. Returns whether the
// window's answers changed.
update_consider :: proc(d: ^Desk) -> bool {
	if d.update_state == .Checking || d.update_state == .Applying {
		return false
	}
	wall, mono := update_clock(d)
	if !d.update_opened_set {
		d.update_opened_mono = mono
		d.update_opened_set = true
	}
	m := Moment {
		enabled       = update_enabled(d),
		startup_done  = d.update_startup_done,
		last_wall     = d.update_checked,
		now_wall      = wall,
		has_last_mono = d.update_has_mono,
		last_mono     = d.update_last_mono,
		now_mono      = mono,
		opened_mono   = d.update_opened_mono,
	}
	switch due(m) {
	case .None:
		return false
	case .Peer:
		d.update_startup_done = true
		return false
	case .Startup, .Daily:
		if !update_claim(d, wall) {
			d.update_startup_done = true
			d.update_checked = update_checked_load(d)
			d.update_has_mono = true
			d.update_last_mono = mono
			return false
		}
		d.update_startup_done = true
		d.update_checked = wall
		d.update_has_mono = true
		d.update_last_mono = mono
		sync.atomic_add(&d.update_auto_count, 1)
		// A desk with no answer port is a schedule test: the check is
		// counted and not started, so nothing is asked of the network.
		if d.updates != nil {
			update_begin(d, false)
		}
		return true
	}
	return false
}

// update_enabled is the opted-in setting. Absent is off, which is how a
// store written before the setting, and a window that cannot keep one,
// stay off.
update_enabled :: proc(d: ^Desk, allocator := context.temp_allocator) -> bool {
	if d.settings == nil {
		return false
	}
	value, found := settings.get(d.settings, settings.UPDATES, allocator)
	return found && value == "on"
}

// update_claim records now as the automatic check, and only if the stored
// instant is still the one this window decided from. The other window's
// claim wins and this one does not check.
update_claim :: proc(d: ^Desk, now_wall: i64, allocator := context.temp_allocator) -> bool {
	if d.settings == nil || now_wall <= 0 {
		return false
	}
	previous := update_checked_text(d.update_checked, allocator)
	next := fmt.aprintf("%d", now_wall, allocator = allocator)
	won, err := settings.replace_if(d.settings, settings.UPDATE_CHECKED, previous, next)
	if err != nil {
		fmt.eprintln("leita: could not record the update check:", err)
		return false
	}
	return won
}

update_checked_load :: proc(d: ^Desk, allocator := context.temp_allocator) -> i64 {
	if d.settings == nil {
		return 0
	}
	value, found := settings.get(d.settings, settings.UPDATE_CHECKED, allocator)
	if !found {
		return 0
	}
	n, ok := strconv_parse_i64(value)
	if !ok || n <= 0 {
		return 0
	}
	return n
}

update_checked_text :: proc(unix: i64, allocator := context.temp_allocator) -> string {
	if unix <= 0 {
		return ""
	}
	return fmt.aprintf("%d", unix, allocator = allocator)
}

// update_dismissed_load is the version whose notice was dismissed, "" when
// none was. Owned by the caller.
update_dismissed_load :: proc(d: ^Desk, allocator := context.allocator) -> string {
	if d.settings == nil {
		return ""
	}
	value, found := settings.get(d.settings, settings.UPDATE_DISMISSED, allocator)
	if !found {
		return ""
	}
	return value
}

// strconv_parse_i64 reads a positive decimal. A stray value does not count
// as a check.
@(private)
strconv_parse_i64 :: proc(s: string) -> (n: i64, ok: bool) {
	if s == "" {
		return 0, false
	}
	n = 0
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + i64(c - '0')
	}
	return n, true
}

// coverage_of is whether a retained Pro installation may take the candidate.
// retained is licence.pro_for_this_build: a trial and a build with no release
// stamp are not retained, and a candidate is not refused for them. ineligible
// is the updater's own refusal, which wins.
coverage_of :: proc(
	retained: bool,
	paid_through, released: string,
	released_ok, ineligible: bool,
) -> query.Update_Coverage {
	if ineligible {
		if !released_ok {
			return .Unstamped
		}
		return .Later
	}
	if !retained {
		return .None
	}
	if !released_ok || !licence.instant_ok(paid_through) {
		return .Unstamped
	}
	if released <= paid_through {
		return .Covered
	}
	return .Later
}

// coverage_allows is whether Apply may replace this copy. Later and
// Unstamped stay on the installed build; the window points at the release
// instead of installing.
coverage_allows :: proc(c: query.Update_Coverage) -> bool {
	return c != .Later && c != .Unstamped
}

// update_retained is this desk's retained Pro, the same test the updater
// uses before it replaces a build.
update_retained :: proc(d: ^Desk) -> bool {
	return d.licensed && licence.pro_for_this_build(d.licence)
}

// update_coverage is the candidate's eligibility for the licence in use.
update_coverage :: proc(d: ^Desk) -> query.Update_Coverage {
	at, stamped := update.released(&d.update_result)
	return coverage_of(
		update_retained(d),
		d.licence.paid_through,
		at,
		stamped,
		d.update_result.reason == .Ineligible,
	)
}
