package leita_cli

import "core:fmt"
import "core:io"
import "core:time"

import "../history"
import "../monitor"
import "../settings"
import "../webhook"

// monitor_webhook carries out leita monitor webhook ..., saying how it went on
// w, and returns the exit code.
@(private)
monitor_webhook :: proc(
	c: Monitor_Context,
	args: []string,
	w: io.Writer,
	allocator := context.temp_allocator,
) -> int {
	verb := args[0] if len(args) > 0 else "list"
	rest := args[1:] if len(args) > 0 else nil
	st: settings.Store
	if !monitor_open_settings(c, &st, w) {
		return monitor.EXIT_FAILED
	}
	defer settings.close(&st)
	now := time.to_unix_seconds(c.now)
	switch verb {
	case "add":
		Hook_Flags :: struct {
			url:   string `args:"pos=0,required" usage:"Where to send each alert: an https URL."`,
			paths: bool `usage:"Let it carry the folder paths inside a place."`,
		}
		f: Hook_Flags
		if code, ok := monitor_parse(c, &f, rest, w); !ok {
			return code
		}
		if !c.unlocked {
			monitor_errorf(c, w, MONITOR_LOCKED)
			return monitor.EXIT_FAILED
		}
		switch webhook.check_url(f.url) {
		case .None:
		case .Not_Https:
			fmt.wprintfln(w, "error: %s is not https; plain http is only for this machine", f.url)
			return monitor.EXIT_FAILED
		case .No_Host:
			fmt.wprintfln(w, "error: %s names no server", f.url)
			return monitor.EXIT_FAILED
		}
		if _, err := settings.hook_add(&st, f.url, webhook.make_secret(allocator), f.paths, now);
		   err != nil {
			fmt.wprintfln(w, "error: cannot keep the webhook: %s", history.describe(err))
			return monitor.EXIT_FAILED
		}
		fmt.wprintfln(
			w,
			"sending each new alert to %s%s",
			f.url,
			", folder paths included" if f.paths else "",
		)
		monitor_print_secret(&st, f.url, w, allocator)
		return 0
	case "remove":
		Remove_Hook :: struct {
			url: string `args:"pos=0,required" usage:"The webhook to stop sending to."`,
		}
		f: Remove_Hook
		if code, ok := monitor_parse(c, &f, rest, w); !ok {
			return code
		}
		found, err := settings.hook_remove(&st, f.url)
		switch {
		case err != nil:
			fmt.wprintfln(w, "error: cannot remove the webhook: %s", history.describe(err))
			return monitor.EXIT_FAILED
		case !found:
			fmt.wprintfln(w, "error: no webhook to %s", f.url)
			return monitor.EXIT_FAILED
		}
		fmt.wprintfln(w, "no longer sending to %s", f.url)
		return 0
	case "list":
		hooks, err := settings.hooks(&st, allocator)
		if err != nil {
			fmt.wprintfln(w, "error: cannot read the webhooks: %s", history.describe(err))
			return monitor.EXIT_FAILED
		}
		if len(hooks) == 0 {
			fmt.wprintln(w, "no webhook; nothing is sent anywhere")
		}
		for h in hooks {
			fmt.wprintfln(w, "%s%s", h.url, "  (folder paths included)" if h.paths else "")
			fmt.wprintfln(w, "  secret %s", h.secret)
			switch {
			case h.last_problem != "":
				fmt.wprintfln(w, "  last try failed: %s", h.last_problem)
			case h.last_sent > 0:
				fmt.wprintfln(w, "  last delivered %s", monitor_when_(h.last_sent))
			case:
				fmt.wprintln(w, "  nothing delivered yet")
			}
			if n := settings.waiting(&st, h.id); n > 0 {
				fmt.wprintfln(w, "  %d waiting to be taken", n)
			}
		}
		return 0
	case "test":
		Test_Hook :: struct {
			url: string `args:"pos=0" usage:"The webhook to test; every one unless given."`,
		}
		f: Test_Hook
		if code, ok := monitor_parse(c, &f, rest, w); !ok {
			return code
		}
		if !c.unlocked {
			monitor_errorf(c, w, MONITOR_LOCKED)
			return monitor.EXIT_FAILED
		}
		return monitor_test_hooks(c, &st, f.url, now, w, allocator)
	}
	fmt.wprintf(w, "error: no webhook command %q\n\n", verb)
	monitor_print_usage(c, w)
	return monitor.EXIT_FAILED
}

// monitor_print_secret says the secret of the webhook to url, for its server to check
// each request with.
@(private)
monitor_print_secret :: proc(
	st: ^settings.Store,
	url: string,
	w: io.Writer,
	allocator := context.temp_allocator,
) {
	hooks, _ := settings.hooks(st, allocator)
	for h in hooks {
		if h.url == url {
			fmt.wprintfln(
				w,
				"its secret, for checking X-Leita-Signature on each request: %s",
				h.secret,
			)
		}
	}
}

// monitor_test_hooks sends a test to the webhook to url, or to every one for "", now,
// and says how each went on w.
@(private)
monitor_test_hooks :: proc(
	c: Monitor_Context,
	st: ^settings.Store,
	url: string,
	now: i64,
	w: io.Writer,
	allocator := context.temp_allocator,
) -> int {
	hooks, _ := settings.hooks(st, allocator)
	tested := 0
	for h in hooks {
		if url != "" && h.url != url {
			continue
		}
		tested += 1
		if problem := webhook.queue_test(st, h.id, now); problem != "" {
			fmt.wprintfln(w, "error: %s", problem)
			return monitor.EXIT_FAILED
		}
		if c.post == nil {
			continue
		}
		tally, problem := webhook.deliver(st, now, c.post, c.posted, h.id)
		switch {
		case problem != "":
			fmt.wprintfln(w, "error: %s", problem)
			return monitor.EXIT_FAILED
		case tally.taken > 0:
			fmt.wprintfln(w, "%s took the test", h.url)
		case:
			heard, _ := settings.hooks(st, allocator)
			why := ""
			for g in heard {
				if g.id == h.id {
					why = g.last_problem
				}
			}
			fmt.wprintfln(
				w,
				"%s did not take the test: %s%s",
				h.url,
				why,
				"; it is tried again on later runs" if tally.later > 0 else "",
			)
		}
	}
	if tested == 0 {
		fmt.wprintln(w, "error: no webhook to test; leita monitor webhook add URL adds one")
		return monitor.EXIT_FAILED
	}
	return 0
}
