#+build linux
package leita_app

import "core:strings"

import "jm:sh"
import "jm:stream"

import "../../journal"
import "../command"
import "../query"

/*
set_recording turns the recorder of changes on or off as c asks, by running this
binary's `journal on` or `journal off` under pkexec, which asks for the
administrator's rights it needs. It runs on a worker of its own, as open_entry runs
the opener: the person may take as long as they like over the password, and the
desk, which answers the scan and every request, must not wait on them. The
change settles when pkexec returns (finish_recording); until then the dialog's
switch holds what it was set to, and a second change is not started.
*/
set_recording :: proc(d: ^Desk, c: command.Recording) {
	mo := &d.monitoring
	if mo.toggling {
		return
	}
	mo.toggling = true
	elevate := mo.elevate if mo.elevate != "" else "pkexec"
	run := new(Recording_Run)
	run^ = {
		argv   = {
			command.text_make(elevate),
			command.text_make(mo.argv[0]),
			command.text_make("journal"),
			command.text_make("on" if c.on else "off"),
		},
		answer = d.recordings,
	}
	if !errand_start(d.errands, run, recording_main) {
		free(run)
		mo.toggling = false
		monitor_settle(d, say(d, .Record_Changes_Failed, "no thread to run it on"))
	}
}

// Recording_Run is a change of the recorder on a worker.
@(private = "file")
Recording_Run :: struct {
	argv:   [4]command.Text,
	answer: ^stream.Port(Recorder_Change),
}

@(private = "file")
recording_main :: proc(data: rawptr) {
	defer release_temp()
	run := (^Recording_Run)(data)
	argv := make([]string, len(run.argv), context.temp_allocator)
	for &a, i in run.argv {
		argv[i] = command.text_of(&a)
	}
	r := sh.exec(argv, {}, context.temp_allocator)
	out := Recorder_Change {
		how    = outcome_of(r),
		status = recorder_status(),
	}
	switch out.how {
	case .Said:
		out.text = command.text_make(strings.trim_space(r.stdout))
	case .Failed:
		out.text = command.text_make(sh.error(r, context.temp_allocator))
	case .Done, .Dismissed, .Refused:
	}
	stream.port_send(run.answer^, out)
	free(run)
}

// outcome_of is how the change of the recorder that ran as r ended.
@(private = "file")
outcome_of :: proc(r: sh.Result) -> Recorder_Outcome {
	switch {
	case r.ok:
		return .Done
	case r.err == nil && r.code == PKEXEC_DISMISSED:
		return .Dismissed
	case r.err == nil && r.code == PKEXEC_REFUSED:
		return .Refused
	case strings.trim_space(r.stdout) != "":
		return .Said
	}
	return .Failed
}

// pkexec's exit codes when the rights it asked for were not given (pkexec(1)).
@(private = "file")
PKEXEC_DISMISSED :: 126
@(private = "file")
PKEXEC_REFUSED :: 127

// recorder_refresh asks the system whether the recorder is installed and running,
// and keeps the answer for recorder_answer.
@(private)
recorder_refresh :: proc(d: ^Desk) {
	d.monitoring.recorder = recorder_status()
}

// recorder_status asks the system whether the recorder is installed and running.
@(private)
recorder_status :: proc() -> Recorder_Status {
	installed := journal.installed()
	return {installed, installed && journal.active()}
}

// recorder_answer says in r what recorder_refresh last found.
@(private)
recorder_answer :: proc(d: ^Desk, r: ^query.Monitor_Result) {
	r.recorder_shown = true
	r.recorder_on = d.monitoring.recorder.installed
	r.recorder_running = d.monitoring.recorder.running
}
