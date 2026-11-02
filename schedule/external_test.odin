package leita_schedule

import "core:strings"
import "core:testing"

import "jm:sh"

@(test)
external_scheduler_never_touches_the_hosts_scheduler :: proc(t: ^testing.T) {
	called := 0
	h := Host {
		system = .External,
		run = proc(argv: []string, user: rawptr) -> Outcome {
			(^int)(user)^ += 1
			return {ok = true}
		},
		user = &called,
	}
	problem, state := install(h, {"/usr/local/bin/leita", "monitor", "run"})
	testing.expect(t, problem != "", "there is no automatic installation")
	testing.expect_value(t, state, Linger.Unknown)
	testing.expect_value(t, linger(h), Linger.Unknown)
	testing.expect_value(t, remove(h), "")
	testing.expect(t, !installed(h) && !loaded(h), "no installed job is claimed")
	testing.expect_value(t, program(h), "")
	testing.expect_value(t, called, 0)
}

@(test)
external_cron_guidance_preserves_arguments_through_cron_and_the_shell :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {return}
	args := []string {
		"/usr/bin/printf",
		"%s\n",
		"a'b",
		`a\%b`,
		`a\\%b`,
		`\q`,
		"100%",
		"$HOME $(echo unsafe); *",
		"`printf unsafe`",
		" space\ttab ",
		"日本語",
	}
	// A literal newline cannot appear in a crontab command; printf's format is
	// written as backslash+n, which the shell and printf interpret in turn.
	args[1] = `%s\n`
	line, problem := external_cron_line(args)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(line, "0 * * * * "), line)
	command := strings.trim_prefix(line, "0 * * * * ")
	// FreeBSD cron's documented input transform: \% and \\ become literals
	// before /bin/sh sees the command; any unescaped % would feed stdin.
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(command); i += 1 {
		if command[i] == '\\' &&
		   i + 1 < len(command) &&
		   (command[i + 1] == '%' || command[i + 1] == '\\') {
			i += 1
		} else {
			testing.expect(t, command[i] != '%', "cron must not split this command into stdin")
		}
		strings.write_byte(&b, command[i])
	}
	r := sh.exec({"/bin/sh", "-c", strings.to_string(b)}, {}, context.temp_allocator)
	testing.expect(t, r.ok, sh.error(r, context.temp_allocator))
	testing.expect_value(
		t,
		r.stdout,
		"a'b\na\\%b\na\\\\%b\n\\q\n100%\n$HOME $(echo unsafe); *\n`printf unsafe`\n space\ttab \n日本語\n",
	)
}

@(test)
external_cron_guidance_refuses_unrepresentable_arguments :: proc(t: ^testing.T) {
	for args in ([][]string{nil, {"leita", "monitor", "run"}, {"/bin/leita", "line\nbreak"}, {"/bin/leita", "nul\x00byte"}}) {
		_, problem := external_cron_line(args)
		testing.expect(t, problem != "", "a bad command must not be offered for pasting")
	}
}
