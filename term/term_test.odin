#+feature dynamic-literals
package term

import "core:strings"
import "core:terminal"
import "core:testing"

// Env is a fake environment: only the keys it holds are set.
Env :: map[string]string

env_lookup :: proc(key: string, data: rawptr) -> string {
	return (^Env)(data)[key]
}

style_of :: proc(tty: bool, env: Env, mode := Mode.Auto) -> Style {
	env := env
	defer delete(env)
	return detect(tty, mode, env_lookup, &env)
}

@(test)
a_terminal_is_styled :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		style_of(true, {"TERM" = "xterm-256color"}).depth,
		terminal.Color_Depth.Eight_Bit,
	)
	testing.expect_value(
		t,
		style_of(true, {"TERM" = "xterm", "COLORTERM" = "truecolor"}).depth,
		terminal.Color_Depth.True_Color,
	)
}

@(test)
a_pipe_is_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, style_of(false, {"TERM" = "xterm-256color"}), Style{})
}

@(test)
an_agent_in_a_terminal_is_plain :: proc(t: ^testing.T) {
	for k in AGENT_VARS {
		testing.expect_value(t, style_of(true, {"TERM" = "xterm-256color", k = "1"}), Style{})
	}
}

@(test)
no_color_and_dumb_are_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, style_of(true, {"TERM" = "xterm", "NO_COLOR" = "1"}), Style{})
	testing.expect_value(t, style_of(true, {"TERM" = "dumb"}), Style{})
	// With nothing in the environment, Unix has no terminal to speak of. On
	// Windows detect also reads terminal.color_depth, the console's own
	// answer, so there the case is the console's to decide.
	when ODIN_OS == .Windows {
		testing.expect_value(t, style_of(true, {}), Style{depth = terminal.color_depth})
	} else {
		testing.expect_value(t, style_of(true, {}), Style{})
	}
	testing.expect(
		t,
		styled(style_of(true, {"TERM" = "xterm-256color"})),
		"a 256-colour terminal is styled",
	)
}

@(test)
an_explicit_mode_wins :: proc(t: ^testing.T) {
	testing.expect(t, styled(style_of(false, {"AI_AGENT" = "x", "NO_COLOR" = "1"}, .Always)))
	testing.expect_value(t, style_of(true, {"TERM" = "xterm"}, .Never), Style{})
	testing.expect(t, styled(style_of(false, {"CLICOLOR_FORCE" = "1"})))
	testing.expect_value(t, style_of(false, {"CLICOLOR_FORCE" = "0"}), Style{})
}

@(test)
paint_writes_codes_only_when_styled :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	paint(&b, {}, {.Bold}, "Ask")
	testing.expect_value(t, strings.to_string(b), "Ask")
	strings.builder_reset(&b)
	paint(&b, {depth = .Three_Bit}, {.Bold, .Dim}, "Ask")
	testing.expect_value(t, strings.to_string(b), "\x1b[1;2mAsk\x1b[0m")
	testing.expect_value(t, painted({}, {.Bold}, "Ask"), "Ask")
	testing.expect_value(t, painted({depth = .Three_Bit}, {.Dim}, "Ask"), "\x1b[2mAsk\x1b[0m")
}

@(test)
parse_mode_reads_the_three_words :: proc(t: ^testing.T) {
	for word, want in ([Mode]string{.Auto = "auto", .Always = "always", .Never = "never"}) {
		m, ok := parse_mode(word)
		testing.expect(t, ok && m == want, word)
	}
	_, ok := parse_mode("sometimes")
	testing.expect(t, !ok)
}

HELP :: `tool kit — does a thing.

Do
  tool run [DIR]      run it on DIR, which continues
                      on the next line
  tool                run it here
  --flag N            a flag
      --deep N        a flag indented further
  rest

A closing note.
`

// Plain, the text is written byte for byte; styled, each line carries the
// weight its shape says.
@(test)
write_usage_stresses_the_shape :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	write_usage(&b, {}, "tool", HELP)
	testing.expect_value(t, strings.to_string(b), HELP)
	strings.builder_reset(&b)
	write_usage(&b, {depth = .Three_Bit}, "tool", HELP)
	B :: "\x1b[1m"
	D :: "\x1b[2m"
	R :: "\x1b[0m"
	testing.expect_value(
		t,
		strings.to_string(b),
		B + "tool kit" + R + " — does a thing.\n" +
		"\n" +
		B + "Do" + R + "\n" +
		"  " + D + "tool" + R + " " + B + "run" + R + " [DIR]      run it on DIR, which continues\n" +
		"                      on the next line\n" +
		"  " + D + "tool" + R + "                run it here\n" +
		"  " + B + "--flag" + R + " N            a flag\n" +
		"      " + B + "--deep" + R + " N        a flag indented further\n" +
		"  " + B + "rest" + R + "\n" +
		"\n" +
		D + "A closing note." + R + "\n",
	)
}

// HOSTILE is a name that tries a terminal: an OSC 52 write to the clipboard,
// a CSI colour, a line break, a right-to-left override, markup and a formula.
HOSTILE :: "=\x1b]52;c;ZXZpbA==\x07\x1b[31m\nname\u202E<img src=x>"

// Text painted holds no escape of its own, plain or styled: the codes around it
// are the only ones, and a name cannot end them early or add to them.
@(test)
paint_neutralises_the_text_it_writes :: proc(t: ^testing.T) {
	SAFE :: "=\u241B]52;c;ZXZpbA==\u2407\u241B[31m\u240Aname\uFFFD<img src=x>"
	b := strings.builder_make(context.temp_allocator)
	paint(&b, {}, {.Bold}, HOSTILE)
	testing.expect_value(t, strings.to_string(b), SAFE)
	strings.builder_reset(&b)
	paint(&b, {depth = .Three_Bit}, {.Bold}, HOSTILE)
	testing.expect_value(t, strings.to_string(b), "\x1b[1m" + SAFE + "\x1b[0m")
	testing.expect_value(t, painted({}, {.Dim}, HOSTILE), SAFE)
	testing.expect_value(t, painted({}, {}, HOSTILE), SAFE)
	testing.expect_value(
		t,
		painted({depth = .Three_Bit}, {.Dim}, HOSTILE),
		"\x1b[2m" + SAFE + "\x1b[0m",
	)
}
