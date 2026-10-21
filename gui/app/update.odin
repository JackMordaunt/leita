package leita_app

import "core:strings"
import "core:thread"
import "core:time"

import "jm:stream"

import "../../update"
import "../../version"
import "../query"

/*
Updates, on the desk: About's Check for updates, and the one startup check
and one daily check when the person has opted in. Nothing installs unless
they click Update, and an ineligible release is not that click.

A check or an update waits on the network and the disk, so it runs on a thread
of its own, one at a time, and comes back through a port as Updated, as a
licence key's exchange does. The thread calls package update, as `Leita update`
does, so what the window does is what the command line does: the same release
files, the same signature and sha256 checks, the User-Agent leita/<version>
and no other request. An update replaces this window's own file (the release's
leita-window-<os>-<arch>), only when update.why_not says it can be replaced in
place; otherwise the window sends the person to the release page.

A check waits at most CHECK_TIMEOUT for each file. Closing the window while one
is under way waits for it to end, and for an update to finish, rather than
leave a half-written file beside the program.
*/

// CHECK_TIMEOUT bounds each file a check asks for; a person is watching.
CHECK_TIMEOUT :: 20 * time.Second

// Updated is how a check or an update ended, as its thread hands it to the desk.
//review:ignore noun-for-type the desk already names that value as a past participle: Activated for a licence, so Updated for an update
Updated :: struct {
	result:    update.Result,
	applied:   bool, // an update was asked for, not a check
	can_apply: bool, // for a check that found a newer release
}

// Update_Job is what the thread works from, heap allocated for it.
@(private = "file")
Update_Job :: struct {
	base:    string, // owned; "" for the release update names
	apply:   bool,
	port:    ^stream.Port(Updated),
	key:     [32]byte, // the test fixture's public key, when has_key
	has_key: bool,
	exe:     string, // owned; "" for this process
}

// update_open keeps base as the release to ask, "" for update.default_config's
// (update.RELEASE_BASE, or LEITA_RELEASE_BASE).
update_open :: proc(d: ^Desk, base: string) {
	d.update_base = strings.clone(base)
}

// update_apply installs only what a check found, what can be replaced in
// place, and what this copy's paid-through date allows. Anything else is
// left on the installed build.
update_apply :: proc(d: ^Desk) {
	if d.update_state != .Available || !d.update_can_apply {
		return
	}
	if !coverage_allows(update_coverage(d)) {
		return
	}
	if d.updates == nil {
		return
	}
	update_begin(d, true)
}

// update_begin starts a check, or an update when apply is set, unless one is
// already under way.
update_begin :: proc(d: ^Desk, apply: bool) {
	if d.update_state == .Checking || d.update_state == .Applying {
		return
	}
	job := new(Update_Job)
	job^ = {
		base    = strings.clone(d.update_base),
		apply   = apply,
		port    = d.updates,
		has_key = d.update_key_set,
		exe     = strings.clone(d.update_exe),
	}
	if d.update_key_set {
		job.key = d.update_key
	}
	d.update_state = .Applying if apply else .Checking
	d.update_thread = thread.create_and_start_with_poly_data(
		job,
		update_main,
		init_context = context,
	)
}

@(private = "file")
update_main :: proc(job: ^Update_Job) {
	defer release_temp()
	cfg := update.default_config(.Window, version.VERSION)
	if job.base != "" {
		cfg.base = job.base
	}
	// A 32-byte key is the fixture's. Anything else keeps the compiled key,
	// and a build with neither fails the signature check closed.
	if job.has_key {
		cfg.public_key = job.key[:]
	}
	if job.exe != "" {
		cfg.exe = job.exe
	}
	u := Updated {
		applied = job.apply,
	}
	if job.apply {
		u.result = update.apply(cfg)
	} else {
		cfg.timeout = CHECK_TIMEOUT
		u.result = update.check(cfg)
		u.can_apply = u.result.outcome == .Available && update.why_not(cfg) == .None
	}
	port := job.port
	delete(job.base)
	delete(job.exe)
	free(job)
	stream.port_send(port^, u)
}

// take_update is the desk's half: what the check or the update found.
take_update :: proc(d: ^Desk, u: ^Updated) {
	if d.update_thread != nil {
		thread.join(d.update_thread)
		thread.destroy(d.update_thread)
		d.update_thread = nil
	}
	d.update_result = u.result
	d.update_can_apply = u.can_apply
	switch u.result.outcome {
	case .Current:
		d.update_state = .Current
	case .Available:
		d.update_state = .Available
	case .Applied:
		d.update_state = .Applied
	case .Refused, .Failed:
		d.update_state = .Failed
	}
}

// update_stop waits for the thread, if there is one, so nothing answers after
// the port is gone and nothing is half written.
update_stop :: proc(d: ^Desk) {
	if d.update_thread != nil {
		thread.join(d.update_thread)
		thread.destroy(d.update_thread)
		d.update_thread = nil
	}
}

update_close :: proc(d: ^Desk, allocator := context.allocator) {
	delete(d.update_base, allocator)
	delete(d.update_dismissed, allocator)
	d.update_dismissed = ""
}

update_answer :: proc(d: ^Desk) -> query.Update_Result {
	coverage := update_coverage(d)
	at, stamped := update.released(&d.update_result)
	r := query.Update_Result {
		state     = d.update_state,
		can_apply = d.update_can_apply && coverage_allows(coverage),
		page      = update.RELEASE_PAGE,
		coverage  = coverage,
	}
	if coverage != .None {
		r.paid_through = d.licence.paid_through
	}
	if stamped {
		r.released = at
	}
	switch d.update_state {
	case .Idle, .Checking, .Applying:
		return r
	case .Current, .Available, .Applied, .Failed:
	}
	r.latest = update.latest(&d.update_result)
	if d.update_state == .Available || d.update_result.reason == .Ineligible {
		r.guidance = update_guidance(d)
	}
	r.notice = update_notice_due(d, r.latest, coverage)
	if d.update_state != .Failed {
		return r
	}
	switch d.update_result.reason {
	case .No_Library:
		r.problem = .No_Library
	case .Unreachable:
		r.problem = .Unreachable
	case .Not_Published:
		r.problem = .Not_Published
	case .Ineligible:
		r.problem = .Ineligible
		r.detail = update.message(&d.update_result)
	case .None,
	     .Dev_Build,
	     .Link,
	     .Bundle,
	     .Package,
	     .App_Image,
	     .Installer,
	     .Unsupported,
	     .Bad_Signature,
	     .Bad_Download,
	     .Cannot_Replace,
	     .Journal,
	     .Scoop:
		r.problem = .Other
		r.detail = update.message(&d.update_result)
	}
	return r
}

// update_notice_due is the quiet banner: a release we can name, not the one
// whose notice was dismissed. About still shows that release.
@(private)
update_notice_due :: proc(d: ^Desk, latest: string, coverage: query.Update_Coverage) -> bool {
	if latest == "" || latest == d.update_dismissed {
		return false
	}
	switch d.update_state {
	case .Available:
		return true
	case .Failed:
		return(
			coverage == .Later ||
			coverage == .Unstamped ||
			d.update_result.reason == .Ineligible \
		)
	case .Idle, .Checking, .Current, .Applying, .Applied:
		return false
	}
	return false
}

// update_guidance is why this copy is not replaced in place.
@(private)
update_guidance :: proc(d: ^Desk) -> query.Update_Guidance {
	cfg := update.default_config(.Window, version.VERSION)
	if d.update_exe != "" {
		cfg.exe = d.update_exe
	}
	switch update.why_not(cfg) {
	case .None,
	     .Unsupported,
	     .No_Library,
	     .Unreachable,
	     .Not_Published,
	     .Bad_Signature,
	     .Bad_Download,
	     .Cannot_Replace,
	     .Ineligible:
		return .None
	case .Dev_Build:
		return .Dev
	case .Link:
		return .Link
	case .Bundle:
		return .Bundle
	case .Package:
		return .Package
	case .App_Image:
		return .App_Image
	case .Installer:
		return .Installer
	case .Journal:
		return .Journal
	case .Scoop:
		return .Scoop
	}
	return .None
}
