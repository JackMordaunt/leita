/*
Package term decides how much decoration an output stream can take, and
writes it. A command that is read by scripts and agents as often as by
people prints plain text unless a person is plainly watching: the stream is
a terminal, no agent announced itself, and neither NO_COLOR nor TERM=dumb
asks otherwise. Plain is the zero value, so a Style nobody set writes no
escape codes, which is what every test gets.

	style := term.detect(terminal.is_terminal(os.stdout))
	term.paint(&b, style, {.Bold}, "largest files")  // bold on a terminal, the words in a pipe
	fmt.println(term.painted(style, {.Dim}, "(20)"))
	term.write_usage(&b, style, "leita", USAGE)            // a help text with weight

Taken from brainfold's package of the same name (2026-09-30), which the two
tools keep in step until it moves to jm. Importing it imports core:terminal,
whose init turns on virtual terminal processing for a Windows console
(core/terminal/terminal_windows.odin), so the codes it writes render there too.
*/
package term

import "core:os"
import "core:strings"
import "core:terminal"

import "../human"

// Style is what one stream may carry. depth .None means plain: no escape
// codes at all, which is what a pipe, a file and an agent get.
Style :: struct {
	depth: terminal.Color_Depth,
}

// Mode is a person's explicit choice, from a --color flag or a setting.
// Auto leaves the decision to detect.
Mode :: enum {
	Auto,
	Always,
	Never,
}

// Lookup reads an environment variable, "" when unset. data is passed
// through, so a caller can consult its own overrides before the process
// environment.
Lookup :: #type proc(key: string, data: rawptr) -> string

// AGENT_VARS are what coding agents set in the environment of the commands
// they run: Claude Code 2.1.281 sets AI_AGENT=claude-code_2-1-281_agent and
// CLAUDECODE=1, and the Codex 0.154.0 binary names CODEX_SANDBOX and
// CODEX_SANDBOX_NETWORK_DISABLED (both seen 2026-09-30). Claude Code also
// pipes stdout, which detect catches without any of these; the variables
// cover an agent that runs commands in a pseudo-terminal.
AGENT_VARS :: [?]string {
	"AI_AGENT",
	"CLAUDECODE",
	"CODEX_SANDBOX",
	"CODEX_SANDBOX_NETWORK_DISABLED",
}

// parse_mode reads auto, always or never.
parse_mode :: proc(s: string) -> (Mode, bool) {
	switch s {
	case "auto":
		return .Auto, true
	case "always":
		return .Always, true
	case "never":
		return .Never, true
	}
	return .Auto, false
}

// agent names the first agent variable set, "" when none is.
agent :: proc(lookup: Lookup = os_lookup, data: rawptr = nil) -> string {
	for k in AGENT_VARS {
		if lookup(k, data) != "" {
			return k
		}
	}
	return ""
}

// detect decides the style for a stream. An explicit mode wins; after that
// NO_COLOR and TERM=dumb mean plain and CLICOLOR_FORCE means styled; in Auto
// the stream must be a terminal and no agent may have announced itself.
detect :: proc(
	tty: bool,
	mode := Mode.Auto,
	lookup: Lookup = os_lookup,
	data: rawptr = nil,
) -> Style {
	switch mode {
	case .Never:
		return {}
	case .Always:
		return {depth = max(env_depth(lookup, data), terminal.Color_Depth.Three_Bit)}
	case .Auto:
	}
	if lookup("NO_COLOR", data) != "" || lookup("TERM", data) == "dumb" {
		return {}
	}
	if f := lookup("CLICOLOR_FORCE", data); f != "" && f != "0" {
		return {depth = max(env_depth(lookup, data), terminal.Color_Depth.Three_Bit)}
	}
	if !tty || agent(lookup, data) != "" {
		return {}
	}
	depth := env_depth(lookup, data)
	when ODIN_OS == .Windows {
		// core:terminal found out whether this console took virtual
		// terminal processing, which no variable says.
		depth = max(depth, terminal.color_depth)
	}
	return {depth = depth}
}

// env_depth is the colour depth the environment advertises. It assumes any
// TERM other than dumb takes the SGR attributes and the eight base colours,
// which is all bold and dim need.
env_depth :: proc(lookup: Lookup, data: rawptr) -> terminal.Color_Depth {
	ct := lookup("COLORTERM", data)
	if ct == "truecolor" || ct == "24bit" || lookup("WT_SESSION", data) != "" {
		return .True_Color
	}
	t := lookup("TERM", data)
	switch {
	case t == "" || t == "dumb":
		return .None
	case strings.contains(t, "-truecolor") || strings.contains(t, "-direct"):
		return .True_Color
	case strings.contains(t, "-256color"):
		return .Eight_Bit
	}
	return .Three_Bit
}

os_lookup :: proc(key: string, _: rawptr) -> string {
	v, _ := os.lookup_env(key, context.temp_allocator)
	return v
}

// styled reports whether the style carries escape codes at all.
styled :: proc(s: Style) -> bool {
	return s.depth != .None
}

Attr :: enum {
	Bold,
	Dim,
	Italic,
	Underline,
}

Attrs :: bit_set[Attr]

/*
paint writes text with the attributes set, then resets them. A plain style
writes the text alone. Either way the text is made safe first (human.shown): an
escape sequence in a name from a disk would otherwise run in the terminal, or
end the attributes early, so what paint writes holds no escape of text's own.
*/
paint :: proc(b: ^strings.Builder, s: Style, attrs: Attrs, text: string) {
	safe := human.shown(text)
	if !styled(s) || attrs == {} || safe == "" {
		strings.write_string(b, safe)
		return
	}
	strings.write_string(b, "\x1b[")
	first := true
	for a in attrs {
		if !first {
			strings.write_byte(b, ';')
		}
		first = false
		switch a {
		case .Bold:
			strings.write_byte(b, '1')
		case .Dim:
			strings.write_byte(b, '2')
		case .Italic:
			strings.write_byte(b, '3')
		case .Underline:
			strings.write_byte(b, '4')
		}
	}
	strings.write_byte(b, 'm')
	strings.write_string(b, safe)
	strings.write_string(b, "\x1b[0m")
}

// painted is paint as a string, for a format argument: text made safe when the
// style is plain, else a copy with the codes around it in allocator.
painted :: proc(
	s: Style,
	attrs: Attrs,
	text: string,
	allocator := context.temp_allocator,
) -> string {
	if !styled(s) || attrs == {} || text == "" {
		return human.shown(text, allocator)
	}
	b := strings.builder_make(allocator)
	paint(&b, s, attrs, text)
	return strings.to_string(b)
}

/*
write_usage writes a help text with weight. Plain, it is text byte for byte, which
is what an agent or a pipe reads. Styled, the text's shape says what to
stress; it is written for a person in the form

	program — what it is for.

	Heading
	  program verb ARGS   what the verb does, in a column that
	                      continues on lines indented further
	  --flag VALUE        what the flag does

	Closing notes, which are dim.

The first line's name, what comes before the dash, is bold, as is every
heading, a line at the left edge.
A line indented one to eight columns names a command or flag, in the column
before its first run of two spaces: program, when it opens the column, is
dim and the word after it bold; otherwise the first word is bold. Everything
after the second blank line is dim.
*/
write_usage :: proc(b: ^strings.Builder, s: Style, program, text: string) {
	if !styled(s) {
		strings.write_string(b, text)
		return
	}
	text := text
	blanks := 0
	first := true
	for line in strings.split_lines_iterator(&text) {
		switch {
		case first:
			// The name is what comes before the dash, or the first word.
			first = false
			name, sp, rest := strings.partition(line, " — ")
			if sp == "" {
				name, sp, rest = strings.partition(line, " ")
			}
			paint(b, s, {.Bold}, name)
			strings.write_string(b, sp)
			strings.write_string(b, rest)
		case line == "":
			blanks += 1
		case blanks >= 2:
			paint(b, s, {.Dim}, line)
		case line[0] != ' ':
			paint(b, s, {.Bold}, line)
		case:
			body := strings.trim_left(line, " ")
			indent := len(line) - len(body)
			if indent > 8 {
				strings.write_string(b, line)
				break
			}
			column, desc := body, ""
			if i := strings.index(body, "  "); i >= 0 {
				column, desc = body[:i], body[i:]
			}
			strings.write_string(b, line[:indent])
			if strings.has_prefix(column, program) &&
			   (len(column) == len(program) || column[len(program)] == ' ') {
				paint(b, s, {.Dim}, program)
				_, sp, rest := strings.partition(column[len(program):], " ")
				strings.write_string(b, sp)
				column = rest
			}
			word, sp, rest := strings.partition(column, " ")
			paint(b, s, {.Bold}, word)
			strings.write_string(b, sp)
			strings.write_string(b, rest)
			strings.write_string(b, desc)
		}
		strings.write_byte(b, '\n')
	}
}
