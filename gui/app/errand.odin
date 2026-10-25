package leita_app

import "core:thread"

/*
Errands are the threads the desk starts for work it does not wait on: an entry
being opened or located, a change of the recorder, a test sent to a webhook.
Each is joined, by the desk when it starts the next or by stop, and none cleans
up after itself: a self-cleaning thread frees its own Thread through the
allocator it was made with after its last word to the desk, and once stop had
returned the window's debug allocator, or a test's, was gone (a
heap-use-after-free under ASan). The desk alone starts and reaps them; stop
joins what is left once the desk has stopped.
*/
Errands :: struct {
	threads: [dynamic]^thread.Thread,
}

// errand_start runs work with data on a thread of its own, joined later; false
// when there is no thread to run it on.
errand_start :: proc(e: ^Errands, data: rawptr, work: proc(data: rawptr)) -> bool {
	errands_reap(e)
	t := thread.create_and_start_with_data(data, work, context)
	if t == nil {
		return false
	}
	append(&e.threads, t)
	return true
}

// errand_keep takes t, a thread started elsewhere, to join as an errand; nil
// is none.
errand_keep :: proc(e: ^Errands, t: ^thread.Thread) {
	errands_reap(e)
	if t != nil {
		append(&e.threads, t)
	}
}

// errands_reap joins and frees the errands that have finished.
errands_reap :: proc(e: ^Errands) {
	n := 0
	for t in e.threads {
		if thread.is_done(t) {
			thread.join(t)
			thread.destroy(t)
			continue
		}
		e.threads[n] = t
		n += 1
	}
	resize(&e.threads, n)
}

// errands_join waits for every errand still out and frees them all.
errands_join :: proc(e: ^Errands) {
	for t in e.threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(e.threads)
	e.threads = nil
}
