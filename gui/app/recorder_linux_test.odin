#+build linux
package leita_app

import "core:testing"

import "jm:ui"

import "../../journal"
import "../query"

/*
The Monitoring dialog's answers, given every MONITOR_FRESH while it is open, say
what the recorder's status was when last asked rather than fork systemctl each
time; opening the dialog asks again. The status kept is made the opposite of the
system's, so an answer that asked the system would show it.
*/
@(test)
recorder_status_is_asked_when_monitoring_opens_and_kept :: proc(t: ^testing.T) {
	inbox: ui.Inbox
	ui.inbox_init(&inbox)
	defer ui.inbox_destroy(&inbox)
	d := Desk {
		inbox = &inbox,
	}
	defer delete(d.live)
	d.monitoring.asked = true
	// Unknown is the zero linger, and it would word a note this desk has no
	// language for. Always is the answer that says nothing.
	d.monitoring.linger = .Always
	installed := journal.installed()
	truth := Recorder_Status{installed, installed && journal.active()}
	stale := Recorder_Status{!truth.installed, !truth.installed}

	d.monitoring.recorder = stale
	r := monitor_answer(&d)
	testing.expect(t, r.recorder_shown, "the recorder's switch is not offered")
	testing.expect_value(t, Recorder_Status{r.recorder_on, r.recorder_running}, stale)

	desk_step(&d, Need_Event{added = true, key = 1, q = query.Monitor{}})
	testing.expect_value(t, d.monitoring.recorder, truth)
}
