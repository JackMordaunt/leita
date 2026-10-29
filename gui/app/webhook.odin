package leita_app

import "core:mem"
import "core:strings"
import "core:time"

import "jm:stream"

import "../../settings"
import "../../webhook"
import "../command"
import "../query"

/*
Webhooks, on the desk: the person's own servers each new alert is sent to,
added, removed and tested from the Monitoring dialog. Adding one makes its
secret, which the dialog lets the person copy for their server. A test is
queued like any delivery and delivered at once on a thread of its own, through
a connection of its own to settings.db, since a server may take its time and
the desk must not wait; how it went comes back through a port as Test_Done, and
the dialog shows it as the webhook's last delivery.
*/

// Test_Done is a test delivery ended, back from the thread that sent it.
Test_Done :: struct {}

test_done_in :: proc(_: Test_Done) -> Desk_In {
	return Test_Done{}
}

// Test_Run is a test being sent on a thread of its own, in the allocator it
// was made in.
@(private = "file")
Test_Run :: struct {
	settings: string,
	hook:     i64,
	answer:   ^stream.Port(Test_Done),
	made_in:  mem.Allocator,
}

// add_webhook keeps the webhook c names, with a new secret, or says why not.
add_webhook :: proc(d: ^Desk, c: ^command.Add_Webhook, allocator := context.temp_allocator) {
	if d.settings == nil || d.settings.read_only {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if !unlocked(d) {
		monitor_settle(d, say(d, .Monitoring_Locked))
		return
	}
	url := strings.trim_space(command.text_of(&c.url))
	if webhook.check_url(url) != .None {
		monitor_settle(d, say(d, .Webhook_Not_Https))
		return
	}
	secret := webhook.make_secret(allocator)
	if _, err := settings.hook_add(
		d.settings,
		url,
		secret,
		c.paths,
		time.to_unix_seconds(time.now()),
	); err != nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "")
}

// remove_webhook forgets the webhook c names and what waits for it.
remove_webhook :: proc(d: ^Desk, c: ^command.Remove_Webhook) {
	if d.settings == nil || d.settings.read_only {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if _, err := settings.hook_remove(d.settings, command.text_of(&c.url)); err != nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "")
}

// test_webhook sends a test to the webhook c names, on a thread of its own;
// one test at a time.
test_webhook :: proc(
	d: ^Desk,
	c: ^command.Test_Webhook,
	allocator := context.allocator,
	temp := context.temp_allocator,
) {
	mo := &d.monitoring
	if d.settings == nil || d.settings.read_only || mo.testing || !unlocked(d) {
		return
	}
	url := command.text_of(&c.url)
	hooks, _ := settings.hooks(d.settings, temp)
	for h in hooks {
		if h.url != url {
			continue
		}
		if problem := webhook.queue_test(d.settings, h.id, time.to_unix_seconds(time.now()));
		   problem != "" {
			monitor_settle(d, say(d, .Monitor_Unkept))
			return
		}
		mo.testing = true
		job := new(Test_Run, allocator)
		job^ = {
			settings = strings.clone(mo.paths.settings, allocator),
			hook     = h.id,
			answer   = d.tested,
			made_in  = allocator,
		}
		started := errand_start(d.errands, job, proc(data: rawptr) {
				job := (^Test_Run)(data)
				st: settings.Store
				if settings.open(&st, job.settings) == nil {
					defer settings.close(&st)
					if !st.read_only {
						webhook.deliver(
							&st,
							time.to_unix_seconds(time.now()),
							webhook.post,
							nil,
							job.hook,
						)
					}
				}
				stream.port_send(job.answer^, Test_Done{})
				delete(job.settings, job.made_in)
				free(job, job.made_in)
			})
		if !started {
			delete(job.settings, allocator)
			free(job, allocator)
			mo.testing = false
			monitor_settle(d, say(d, .Monitor_Unkept))
		}
		return
	}
}

// hooks_answer is the webhooks as the store has them now, in the temp
// allocator.
hooks_answer :: proc(d: ^Desk, allocator := context.temp_allocator) -> []query.Hook {
	hooks, err := settings.hooks(d.settings, allocator)
	if err != nil {
		return nil
	}
	out := make([]query.Hook, len(hooks), allocator)
	for h, i in hooks {
		out[i] = {
			url       = h.url,
			secret    = h.secret,
			paths     = h.paths,
			last_sent = h.last_sent,
			problem   = h.last_problem,
			waiting   = settings.waiting(d.settings, h.id),
		}
	}
	return out
}
