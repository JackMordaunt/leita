package leita_app

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "jm:stream"

import "../../licence"
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

// Testing is a test being sent on a thread of its own.
@(private = "file")
Testing :: struct {
	settings: string,
	hook:     i64,
	answer:   ^stream.Port(Test_Done),
	done:     ^sync.Wait_Group,
}

// add_webhook keeps the webhook c names, with a new secret, or says why not.
add_webhook :: proc(d: ^Desk, c: ^command.Add_Webhook) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if !licence.unlocked(d.licensed, d.first_use) {
		monitor_settle(d, say(d, .Monitoring_Locked))
		return
	}
	url := strings.trim_space(command.text_of(&c.url))
	if webhook.check_url(url) != .None {
		monitor_settle(d, say(d, .Webhook_Not_Https))
		return
	}
	secret := webhook.make_secret(context.temp_allocator)
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
	if d.settings == nil {
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
test_webhook :: proc(d: ^Desk, c: ^command.Test_Webhook) {
	mo := &d.monitoring
	if d.settings == nil || mo.testing || !licence.unlocked(d.licensed, d.first_use) {
		return
	}
	url := command.text_of(&c.url)
	hooks, _ := settings.hooks(d.settings, context.temp_allocator)
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
		job := new(Testing)
		job^ = {
			settings = strings.clone(mo.paths.settings),
			hook     = h.id,
			answer   = d.tested,
			done     = d.testing_wg,
		}
		sync.wait_group_add(d.testing_wg, 1)
		thread.create_and_start_with_data(job, proc(data: rawptr) {
				job := (^Testing)(data)
				st: settings.Store
				if settings.open(&st, job.settings) == nil {
					webhook.deliver(
						&st,
						time.to_unix_seconds(time.now()),
						webhook.post,
						nil,
						job.hook,
					)
					settings.close(&st)
				}
				stream.port_send(job.answer^, Test_Done{})
				done := job.done
				delete(job.settings)
				free(job)
				free_all(context.temp_allocator)
				sync.wait_group_done(done)
			}, context, self_cleanup = true)
		return
	}
}

// hooks_answer is the webhooks as the store has them now, in the temp
// allocator.
hooks_answer :: proc(d: ^Desk) -> []query.Hook {
	hooks, err := settings.hooks(d.settings, context.temp_allocator)
	if err != nil {
		return nil
	}
	out := make([]query.Hook, len(hooks), context.temp_allocator)
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
