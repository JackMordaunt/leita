package leita_settings

import "core:testing"

@(test)
a_webhook_added_again_keeps_its_secret :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	id, err := hook_add(&st, "https://a.example/", "first", false, 10)
	testing.expect(t, err == nil && id > 0)
	again, _ := hook_add(&st, "https://a.example/", "second", true, 20)
	testing.expect_value(t, again, id)
	hs, _ := hooks(&st, context.temp_allocator)
	testing.expect_value(t, len(hs), 1)
	testing.expect_value(t, hs[0].secret, "first")
	testing.expect(t, hs[0].paths, "paths follow the last asked")

	testing.expect(t, note_delivery(&st, id, 30, "") == nil)
	testing.expect(t, note_delivery(&st, id, 40, "HTTP 503") == nil)
	hs, _ = hooks(&st, context.temp_allocator)
	testing.expect_value(t, hs[0].last_sent, 30)
	testing.expect_value(t, hs[0].last_problem, "HTTP 503")
}

@(test)
deliveries_wait_until_due_and_go_with_their_webhook :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	a, _ := hook_add(&st, "https://a.example/", "x", false, 1)
	b, _ := hook_add(&st, "https://b.example/", "y", false, 1)
	first, _ := enqueue(&st, a, "test", "{1}", 100)
	_, _ = enqueue(&st, a, "warn_used", "{2}", 200)
	_, _ = enqueue(&st, b, "test", "{3}", 150)
	testing.expect_value(t, waiting(&st, a), 2)

	ready, err := due(&st, 160, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(ready), 2)
	testing.expect_value(t, ready[0].body, "{1}")
	testing.expect_value(t, ready[1].body, "{3}")
	only_a, _ := due(&st, 1000, a, context.temp_allocator)
	testing.expect_value(t, len(only_a), 2)

	testing.expect(t, retry(&st, first, 1, 400, "HTTP 503") == nil)
	ready, _ = due(&st, 300, a, context.temp_allocator)
	testing.expect_value(t, len(ready), 1)
	testing.expect_value(t, ready[0].event, "warn_used")
	ready, _ = due(&st, 400, a, context.temp_allocator)
	testing.expect_value(t, ready[0].attempts, 1)
	testing.expect_value(t, ready[0].problem, "HTTP 503")

	testing.expect(t, forget_delivery(&st, first) == nil)
	testing.expect_value(t, waiting(&st, a), 1)
	found, _ := hook_remove(&st, "https://a.example/")
	testing.expect(t, found)
	testing.expect_value(t, waiting(&st, a), 0)
	testing.expect_value(t, waiting(&st, b), 1)
	found, _ = hook_remove(&st, "https://a.example/")
	testing.expect(t, !found)
}
